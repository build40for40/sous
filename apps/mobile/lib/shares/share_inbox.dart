import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'pending_shares.dart';
import 'screenshot.dart';
import 'share.dart';
import 'share_receiver.dart';
import 'shares_client.dart';

/// What the screens show about sharing into Sous.
class ShareInboxState {
  const ShareInboxState({
    this.shares = const [],
    this.pending = 0,
    this.error,
    this.loaded = false,
  });

  /// The cook's shares, newest first. A `saved` one points at its recipe.
  final List<Share> shares;

  /// Shares waiting to reach the server (signed out, offline, or busy).
  final int pending;

  /// The last thing that went wrong, for a short message. Cleared by the next
  /// success.
  final ShareException? error;

  /// Whether the share list has been fetched at least once.
  final bool loaded;

  bool get anyReading => shares.any((s) => s.status.isPending);

  ShareInboxState copyWith({
    List<Share>? shares,
    int? pending,
    ShareException? error,
    bool clearError = false,
    bool? loaded,
  }) => ShareInboxState(
    shares: shares ?? this.shares,
    pending: pending ?? this.pending,
    error: clearError ? null : error ?? this.error,
    loaded: loaded ?? this.loaded,
  );
}

/// The headless side of sharing into Sous: takes what other apps share,
/// keeps it until it reaches `workers/extract` (across sign-out and restarts),
/// follows each share while it's `reading`, and streams the result.
class ShareInbox {
  ShareInbox({
    required this._client,
    required this._store,
    this.pollEvery = const Duration(seconds: 3),
    this.pollFor = const Duration(minutes: 5),
    Future<Uint8List> Function(String path)? readFile,
    Future<PreparedScreenshot> Function(Uint8List bytes)? prepare,
    DateTime Function()? now,
  }) : _readFile = readFile ?? ((path) => File(path).readAsBytes()),
       _prepare = prepare ?? prepareScreenshot,
       _now = now ?? DateTime.now;

  final SharesClient _client;
  final PendingShareStore _store;
  final Future<Uint8List> Function(String path) _readFile;
  final Future<PreparedScreenshot> Function(Uint8List bytes) _prepare;
  final DateTime Function() _now;

  /// How often to check on shares that are `reading`.
  final Duration pollEvery;

  /// Stop checking after this long without a change; the next refresh picks
  /// it up again.
  final Duration pollFor;

  final _states = StreamController<ShareInboxState>.broadcast();
  var _state = const ShareInboxState();
  var _pending = <PendingShare>[];
  var _loaded = false;
  Future<void>? _flushing;
  Timer? _poll;
  DateTime? _lastChange;
  var _counter = 0;
  StreamSubscription<IncomingShare>? _receiving;
  var _disposed = false;

  ShareInboxState get state => _state;
  Stream<ShareInboxState> get states => _states.stream;

  /// Loads shares left over from last time and starts taking new ones from
  /// [receiver]. Call once at start-up; then [flush] when signed in.
  Future<void> start(ShareReceiver receiver) async {
    await _load();
    _receiving = receiver.shares().listen((share) => unawaited(receive(share)));
  }

  /// Keeps a share from another app and sends it if it can.
  Future<void> receive(IncomingShare share) async {
    await _load();
    final id = _newId();
    final pending = switch (share) {
      IncomingText(:final text) => PendingShare(
        id: id,
        addedAt: _now(),
        text: text,
      ),
      IncomingImage(:final path) => PendingShare(
        id: id,
        addedAt: _now(),
        imagePath: await _store.keepImage(path, id),
      ),
    };
    await _setPending([..._pending, pending]);
    await flush();
  }

  /// Sends a screenshot for a share that came back `needs_screenshot`.
  Future<void> addScreenshot(String shareId, String imagePath) async {
    await _load();
    final id = _newId();
    await _setPending([
      ..._pending,
      PendingShare(
        id: id,
        addedAt: _now(),
        imagePath: await _store.keepImage(imagePath, id),
        forShareId: shareId,
      ),
    ]);
    await flush();
  }

  /// Shares a `needs_screenshot` link again so the server reads it afresh.
  Future<void> retry(Share share) async {
    if (!share.canRetry) return;
    await receive(IncomingText(share.url!));
  }

  /// Sends whatever is waiting, oldest first. Stops at the first failure that
  /// might pass (signed out, offline, server busy, daily limit) and keeps the
  /// rest; drops a share the server will never take.
  Future<void> flush() => _flushing ??= _flush().whenComplete(() {
    _flushing = null;
  });

  Future<void> _flush() async {
    await _load();
    while (_pending.isNotEmpty && !_disposed) {
      final next = _pending.first;
      try {
        final share = await _send(next);
        await _done(next);
        _upsert(share, clearError: true);
      } on ShareException catch (e) {
        _emit(_state.copyWith(error: e));
        if (e.error.isTemporary || e.error == ShareError.dailyLimit) return;
        await _done(next); // the server won't ever take this one
      } on ScreenshotException {
        _emit(_state.copyWith(error: const ShareException(ShareError.invalid)));
        await _done(next);
      } on FileSystemException {
        await _done(next); // the shared file has gone
      }
    }
  }

  Future<Share> _send(PendingShare pending) async {
    if (pending.text != null) return _client.shareLink(pending.text!);
    final image = await _prepare(await _readFile(pending.imagePath!));
    return pending.forShareId != null
        ? _client.addScreenshot(
            pending.forShareId!,
            image.bytes,
            image.mediaType,
          )
        : _client.shareScreenshot(image.bytes, image.mediaType);
  }

  Future<void> _done(PendingShare pending) async {
    if (pending.imagePath != null) {
      await _store.discardImage(pending.imagePath!);
    }
    await _setPending([
      for (final p in _pending)
        if (p.id != pending.id) p,
    ]);
  }

  /// Fetches the cook's shares.
  Future<void> refresh() async {
    try {
      final shares = await _client.listShares();
      _emit(_state.copyWith(shares: shares, loaded: true, clearError: true));
      _lastChange = _now();
      _schedulePoll();
    } on ShareException catch (e) {
      _emit(_state.copyWith(error: e));
    }
  }

  /// Forgets one share. A recipe it saved stays in the cook's recipes.
  Future<void> delete(String shareId) async {
    await _client.deleteShare(shareId);
    _emit(
      _state.copyWith(
        shares: [
          for (final s in _state.shares)
            if (s.id != shareId) s,
        ],
      ),
    );
  }

  /// The extraction half of deleting the account: forgets every share on the
  /// server and anything still waiting here. Call it before the brain's
  /// `deleteMe`, which ends the session this needs.
  Future<void> deleteAll() async {
    await _client.deleteAllShares();
    await _load();
    for (final p in _pending) {
      if (p.imagePath != null) await _store.discardImage(p.imagePath!);
    }
    await _setPending([]);
    _poll?.cancel();
    _emit(const ShareInboxState(loaded: true));
  }

  void dispose() {
    _disposed = true;
    _poll?.cancel();
    unawaited(_receiving?.cancel());
    unawaited(_states.close());
  }

  void _upsert(Share share, {bool clearError = false}) {
    final shares = [
      share,
      for (final s in _state.shares)
        if (s.id != share.id) s,
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    _emit(_state.copyWith(shares: shares, clearError: clearError));
    _lastChange = _now();
    _schedulePoll();
  }

  void _schedulePoll() {
    if (_disposed || !_state.anyReading) {
      _poll?.cancel();
      _poll = null;
      return;
    }
    _poll ??= Timer.periodic(pollEvery, (_) => unawaited(_pollOnce()));
  }

  Future<void> _pollOnce() async {
    final since = _lastChange;
    if (since != null && _now().difference(since) > pollFor) {
      _poll?.cancel();
      _poll = null;
      return;
    }
    for (final share in _state.shares.where((s) => s.status.isPending)) {
      try {
        final fresh = await _client.getShare(share.id);
        if (fresh.status != share.status) {
          _upsert(fresh);
        }
      } on ShareException catch (e) {
        if (e.error == ShareError.notFound) {
          _emit(
            _state.copyWith(
              shares: [
                for (final s in _state.shares)
                  if (s.id != share.id) s,
              ],
            ),
          );
        } else {
          return; // offline or signed out: try again next tick
        }
      }
    }
    _schedulePoll();
  }

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    _pending = await _store.load();
    _emit(_state.copyWith(pending: _pending.length));
  }

  Future<void> _setPending(List<PendingShare> pending) async {
    _pending = pending;
    await _store.save(pending);
    _emit(_state.copyWith(pending: pending.length));
  }

  void _emit(ShareInboxState state) {
    _state = state;
    if (!_states.isClosed) _states.add(state);
  }

  String _newId() =>
      '${_now().microsecondsSinceEpoch.toRadixString(36)}-${(_counter++).toRadixString(36)}';
}

import 'dart:async';

import '../api/brain_client.dart';
import 'auth_browser.dart';
import 'pkce.dart';
import 'session_tokens.dart';
import 'token_store.dart';
import 'workos_client.dart';

sealed class AuthState {
  const AuthState();
}

/// Before [AuthController.restore] has read secure storage.
class AuthRestoring extends AuthState {
  const AuthRestoring();
}

class SignedOut extends AuthState {
  const SignedOut({this.error});

  /// Why the last sign-in attempt failed, if it did. Null after a plain
  /// sign-out, a cancelled browser, or an expired session.
  final AuthError? error;
}

class SigningIn extends AuthState {
  const SigningIn();
}

class SignedIn extends AuthState {
  const SignedIn(this.user);

  final AuthUser user;
}

enum AuthError {
  /// The browser came back with an error, a mismatched state or no code.
  callbackRejected,

  /// WorkOS refused the code.
  exchangeRejected,

  /// No network, or WorkOS is having a moment. Trying again may work.
  network,
}

/// Owns the AuthKit session: hosted sign-in with PKCE, tokens in secure
/// storage, refreshing before they expire, and sign-out.
class AuthController implements AccessTokenSource {
  AuthController({
    required this._workos,
    required this._browser,
    required this._store,
    required this._callbackScheme,
    DateTime Function()? clock,
    this.refreshMargin = const Duration(seconds: 60),
  }) : _clock = clock ?? DateTime.now;

  final WorkosClient _workos;
  final AuthBrowser _browser;
  final TokenStore _store;
  final String _callbackScheme;
  final DateTime Function() _clock;

  /// Refresh when the access token has less than this left.
  final Duration refreshMargin;

  final _states = StreamController<AuthState>.broadcast();
  AuthState _state = const AuthRestoring();
  SessionTokens? _tokens;
  Future<String?>? _refreshing;
  int _generation = 0;

  AuthState get state => _state;

  /// Every change to [state], starting after the current one.
  Stream<AuthState> get states => _states.stream;

  AuthUser? get user => _tokens?.user;

  /// Loads a saved session. Call once at start-up.
  Future<void> restore() async {
    final tokens = await _store.read();
    _tokens = tokens;
    _emit(tokens == null ? const SignedOut() : SignedIn(tokens.user));
  }

  /// Opens hosted AuthKit in the system browser and waits for the cook to
  /// come back signed in. Returns true when they did.
  Future<bool> signIn({bool signUp = false}) async {
    if (_state is SigningIn) return false;
    final generation = ++_generation;
    _emit(const SigningIn());
    final pkce = Pkce.generate();

    final Uri? callback;
    try {
      callback = await _browser.authenticate(
        _workos.authorizationUrl(pkce, signUp: signUp),
        _callbackScheme,
      );
    } on Object {
      return _failSignIn(generation, AuthError.callbackRejected);
    }
    if (callback == null) return _failSignIn(generation, null);

    final code = callback.queryParameters['code'];
    if (callback.queryParameters['state'] != pkce.state ||
        code == null ||
        code.isEmpty) {
      return _failSignIn(generation, AuthError.callbackRejected);
    }

    try {
      final tokens = await _workos.authenticateWithCode(code, pkce.verifier);
      if (generation != _generation) return false;
      await _save(tokens);
      return true;
    } on WorkosException catch (e) {
      return _failSignIn(
        generation,
        e.failure == WorkosFailure.transient
            ? AuthError.network
            : AuthError.exchangeRejected,
      );
    }
  }

  /// Forgets the session on this phone.
  Future<void> signOut() async {
    _generation++;
    _tokens = null;
    _refreshing = null;
    await _store.clear();
    _emit(const SignedOut());
  }

  /// A fresh access token, refreshed first if it's about to expire. Null when
  /// signed out. Throws [WorkosException] with [WorkosFailure.transient] if a
  /// needed refresh couldn't reach WorkOS; the session is kept for a retry.
  @override
  Future<String?> accessToken() async {
    final tokens = _tokens;
    if (tokens == null) return null;
    if (!tokens.expiresWithin(refreshMargin, _clock().toUtc())) {
      return tokens.accessToken;
    }
    return refresh();
  }

  /// Swaps the refresh token for new tokens. Concurrent callers share one
  /// request, because each refresh token works only once.
  @override
  Future<String?> refresh() {
    if (_tokens == null) return Future.value(null);
    return _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  }

  /// The brain rejected a token that refreshing couldn't fix.
  @override
  Future<void> rejected() => signOut();

  Future<String?> _refresh() async {
    final generation = _generation;
    final current = _tokens!;
    try {
      final tokens = await _workos.authenticateWithRefreshToken(
        current.refreshToken,
      );
      if (generation != _generation) return null;
      await _save(tokens);
      return tokens.accessToken;
    } on WorkosException catch (e) {
      if (e.failure == WorkosFailure.transient) rethrow;
      if (generation == _generation) await signOut();
      return null;
    }
  }

  Future<void> _save(SessionTokens tokens) async {
    _tokens = tokens;
    await _store.write(tokens);
    if (_state is! SignedIn) _emit(SignedIn(tokens.user));
  }

  bool _failSignIn(int generation, AuthError? error) {
    if (generation != _generation) return false;
    final tokens = _tokens;
    _emit(tokens == null ? SignedOut(error: error) : SignedIn(tokens.user));
    return false;
  }

  void _emit(AuthState state) {
    _state = state;
    _states.add(state);
  }

  Future<void> dispose() => _states.close();
}

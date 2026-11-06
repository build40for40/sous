import 'dart:async';

import 'package:http/http.dart' as http;

import 'api/brain_client.dart';
import 'auth/auth_browser.dart';
import 'auth/auth_controller.dart';
import 'auth/token_store.dart';
import 'auth/workos_client.dart';
import 'config.dart';
import 'cooking/cooking_session.dart';
import 'cooking/cooking_tools.dart';
import 'shares/pending_shares.dart';
import 'shares/share_inbox.dart';
import 'shares/share_receiver.dart';
import 'shares/shares_client.dart';
import 'voice/voice.dart';

/// Everything the screens and the voice layer need to reach the brain.
class SousServices {
  factory SousServices({
    http.Client? httpClient,
    TokenStore? store,
    AuthBrowser? browser,
    PendingShareStore? pendingShares,
    Voice? voice,
  }) {
    final client = httpClient ?? http.Client();
    final auth = AuthController(
      workos: WorkosClient(
        clientId: workosClientId,
        redirectUri: authRedirectUri,
        apiBase: workosApiBase,
        httpClient: client,
      ),
      browser: browser ?? const SystemAuthBrowser(),
      store: store ?? SecureTokenStore(),
      callbackScheme: authCallbackScheme,
    );
    final shares = SharesClient(
      baseUri: brainApiBase,
      httpClient: client,
      tokens: auth,
    );
    return SousServices._(
      auth,
      BrainClient(baseUri: brainApiBase, httpClient: client, tokens: auth),
      shares,
      ShareInbox(
        client: shares,
        store: pendingShares ?? FilePendingShareStore(),
      ),
      voice ??
          Voice.fromConfig(VoiceConfig.fromEnvironment(), httpClient: client),
    );
  }

  SousServices._(this.auth, this.brain, this.shares, this.inbox, this.voice);

  final AuthController auth;
  final BrainClient brain;

  /// Speech for the cook screen: download the models with [Voice.prepare],
  /// then `voice.loopFor(session)` gives a loop to start and stop.
  final Voice voice;

  /// `workers/extract`: links and screenshots shared into Sous.
  final SharesClient shares;

  /// What the screens read for shares: each one's status, and anything still
  /// waiting to be sent.
  final ShareInbox inbox;

  StreamSubscription<AuthState>? _auth;

  /// Takes shares from other apps (Instagram's Share → Sous) and sends them
  /// whenever the cook is signed in. Shares made while signed out wait.
  Future<void> startSharing(ShareReceiver receiver) async {
    await inbox.start(receiver);
    void onAuth(AuthState state) {
      if (state is SignedIn) {
        unawaited(inbox.flush());
        unawaited(inbox.refresh());
      }
    }

    onAuth(auth.state);
    _auth = auth.states.listen(onAuth);
  }

  /// Deletes the account in the order the servers need: the cook's shares
  /// first (that needs a valid session), then the brain and the WorkOS user,
  /// then signs out.
  Future<void> deleteAccount() async {
    await inbox.deleteAll();
    await brain.deleteMe();
    await auth.signOut();
  }

  void dispose() {
    unawaited(_auth?.cancel());
    inbox.dispose();
  }

  /// A new cook, with [tools] running Sou's timers and screen changes.
  CookingSession cookingSession(CookingTools tools) =>
      CookingSession(brain: brain, tools: tools);
}

import 'package:http/http.dart' as http;

import 'api/brain_client.dart';
import 'auth/auth_browser.dart';
import 'auth/auth_controller.dart';
import 'auth/token_store.dart';
import 'auth/workos_client.dart';
import 'config.dart';
import 'cooking/cooking_session.dart';
import 'cooking/cooking_tools.dart';

/// Everything the screens and the voice layer need to reach the brain.
class SousServices {
  factory SousServices({
    http.Client? httpClient,
    TokenStore? store,
    AuthBrowser? browser,
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
    return SousServices._(
      auth,
      BrainClient(baseUri: brainApiBase, httpClient: client, tokens: auth),
    );
  }

  SousServices._(this.auth, this.brain);

  final AuthController auth;
  final BrainClient brain;

  /// A new cook, with [tools] running Sou's timers and screen changes.
  CookingSession cookingSession(CookingTools tools) =>
      CookingSession(brain: brain, tools: tools);
}

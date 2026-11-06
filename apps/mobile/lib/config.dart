/// The shared build40for40 AuthKit application, production environment.
/// A public client id: PKCE means no secret ships in the app.
const workosClientId = 'client_01M6E5ZDQ9XBYYE28XYN7H3XTJ';

const authCallbackScheme = 'sous';
final authRedirectUri = Uri.parse('$authCallbackScheme://auth/callback');

final workosApiBase = Uri.parse('https://api.workos.com');
final brainApiBase = Uri.parse('https://build40for40.com/sous/api/v1');

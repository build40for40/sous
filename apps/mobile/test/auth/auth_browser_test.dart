import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sous/auth/auth_browser.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_web_auth_2');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('opens the URL and returns the callback', () async {
    late MethodCall call;
    messenger.setMockMethodCallHandler(channel, (c) async {
      call = c;
      return 'sous://auth/callback?code=c&state=s';
    });

    final callback = await const SystemAuthBrowser().authenticate(
      Uri.parse('https://api.workos.test/user_management/authorize'),
      'sous',
    );

    expect(call.method, 'authenticate');
    expect((call.arguments as Map)['callbackUrlScheme'], 'sous');
    expect(callback!.queryParameters['code'], 'c');
  });

  test('returns null when the cook closes the browser', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'CANCELED'),
    );

    expect(
      await const SystemAuthBrowser().authenticate(
        Uri.parse('https://x.test'),
        'sous',
      ),
      isNull,
    );
  });
}

import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

/// Opens the hosted sign-in page and waits for the redirect back to the app.
abstract interface class AuthBrowser {
  /// The callback URL, or null if the cook closed the browser.
  Future<Uri?> authenticate(Uri url, String callbackScheme);
}

/// ASWebAuthenticationSession on iOS, Auth Tab or Custom Tabs on Android.
class SystemAuthBrowser implements AuthBrowser {
  const SystemAuthBrowser();

  @override
  Future<Uri?> authenticate(Uri url, String callbackScheme) async {
    try {
      final result = await FlutterWebAuth2.authenticate(
        url: url.toString(),
        callbackUrlScheme: callbackScheme,
      );
      return Uri.parse(result);
    } on PlatformException catch (e) {
      if (e.code == 'CANCELED') return null;
      rethrow;
    }
  }
}

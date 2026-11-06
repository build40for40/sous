import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sous/auth/token_store.dart';

import '../support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('writes, reads back and clears the session', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final store = SecureTokenStore();
    final tokens = fakeTokens(expiresAt: DateTime.utc(2026, 11, 6, 18));

    expect(await store.read(), isNull);
    await store.write(tokens);
    expect((await store.read())!.refreshToken, tokens.refreshToken);
    await store.clear();
    expect(await store.read(), isNull);
  });

  test('drops a corrupt entry instead of crashing', () async {
    FlutterSecureStorage.setMockInitialValues({'sous.session': '{oops'});
    final store = SecureTokenStore();

    expect(await store.read(), isNull);
    expect(
      await const FlutterSecureStorage().read(key: 'sous.session'),
      isNull,
    );
  });
}

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/shared_prefs_sdk_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/sdk_session_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes/memory_shared_prefs_sdk_store.dart';

void main() {
  group('SdkSessionStore', () {
    test('does not persist the unused refresh token on new writes', () async {
      final localStore = MemorySharedPrefsSdkStore();
      final store = SdkSessionStore(localStore: localStore);

      await store.save(
        const EixamSession.signed(
          appId: 'app-1',
          externalUserId: 'user-1',
          userHash: 'signed-user-hash',
          sdkUserId: 'sdk-user-1',
          canonicalExternalUserId: 'canonical-user-1',
          refreshToken: 'sdk-refresh-token',
        ),
      );

      final persisted =
          localStore.jsonValues[SharedPrefsSdkStore.sdkSessionKey];

      expect(persisted, isNotNull);
      expect(persisted, isNot(containsPair('refreshToken', anything)));
      expect(persisted?['userHash'], 'signed-user-hash');
    });

    test('continues to read legacy sessions that contain a refresh token',
        () async {
      final localStore = MemorySharedPrefsSdkStore()
        ..jsonValues[SharedPrefsSdkStore.sdkSessionKey] = <String, dynamic>{
          'appId': 'app-1',
          'externalUserId': 'user-1',
          'userHash': 'signed-user-hash',
          'sdkUserId': 'sdk-user-1',
          'canonicalExternalUserId': 'canonical-user-1',
          'refreshToken': 'legacy-sdk-refresh-token',
        };
      final store = SdkSessionStore(localStore: localStore);

      final session = await store.load();

      expect(session, isNotNull);
      expect(session?.refreshToken, 'legacy-sdk-refresh-token');
      expect(session?.userHash, 'signed-user-hash');
    });
  });
}

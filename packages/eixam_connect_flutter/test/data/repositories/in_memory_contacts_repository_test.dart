import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/shared_prefs_sdk_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes/memory_shared_prefs_sdk_store.dart';

void main() {
  group('InMemoryContactsRepository', () {
    test('adds, sorts, updates, and persists contacts', () async {
      final store = MemorySharedPrefsSdkStore();
      final repository = InMemoryContactsRepository(localStore: store);

      final second = await repository.addEmergencyContact(
        name: 'Zoe',
        priority: 2,
      );
      final first = await repository.addEmergencyContact(
        name: 'Alice',
        priority: 1,
      );

      final contacts = await repository.listEmergencyContacts();
      expect(contacts.map((contact) => contact.name), <String>['Alice', 'Zoe']);

      await repository.updateEmergencyContact(
        second.copyWith(name: 'Bruno', priority: 1),
      );

      final updated = await repository.listEmergencyContacts();
      expect(
          updated.map((contact) => contact.name), <String>['Alice', 'Bruno']);

      final persisted =
          store.jsonValues[SharedPrefsSdkStore.emergencyContactsKey];
      expect(persisted, isNotNull);
      expect((persisted!['items'] as List).length, 2);
      expect(first.active, isTrue);
    });

    test('restores and sorts contacts from local storage', () async {
      final store = MemorySharedPrefsSdkStore()
        ..jsonValues[SharedPrefsSdkStore.emergencyContactsKey] =
            <String, dynamic>{
          'items': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'contact-2',
              'name': 'Zoe',
              'priority': 2,
              'active': true,
            },
            <String, dynamic>{
              'id': 'contact-1',
              'name': 'Alice',
              'priority': 1,
              'active': true,
            },
          ],
        };
      final repository = InMemoryContactsRepository(localStore: store);

      await repository.restoreState();

      final contacts = await repository.listEmergencyContacts();
      expect(contacts.map((contact) => contact.id),
          <String>['contact-1', 'contact-2']);
    });

    test('toggles active flag and removes contacts safely', () async {
      final repository = InMemoryContactsRepository(
        localStore: MemorySharedPrefsSdkStore(),
      );
      final contact = await repository.addEmergencyContact(name: 'Alice');

      await repository.setEmergencyContactActive(contact.id, false);
      expect((await repository.listEmergencyContacts()).single.active, isFalse);

      await repository.removeEmergencyContact(contact.id);
      expect(await repository.listEmergencyContacts(), isEmpty);
    });
  });
}

import 'package:eixam_connect_flutter/src/data/datasources_local/shared_prefs_sdk_store.dart';
import 'package:eixam_connect_flutter/src/data/repositories/in_memory_contacts_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes/memory_shared_prefs_sdk_store.dart';

void main() {
  group('InMemoryContactsRepository', () {
    test('adds, sorts, updates, and persists contacts', () async {
      final store = MemorySharedPrefsSdkStore();
      final repository = InMemoryContactsRepository(localStore: store);

      final second = await repository.addEmergencyContact(
        name: 'Zoe',
        phone: '+34999999999',
        email: 'zoe@example.com',
        priority: 2,
      );
      final first = await repository.addEmergencyContact(
        name: 'Alice',
        phone: '+34123456789',
        email: 'alice@example.com',
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
      expect(first.createdAt, isNotNull);
    });

    test('restores and sorts contacts from local storage', () async {
      final store = MemorySharedPrefsSdkStore()
        ..jsonValues[SharedPrefsSdkStore.emergencyContactsKey] =
            <String, dynamic>{
          'items': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'contact-2',
              'name': 'Zoe',
              'phone': '+34999999999',
              'email': 'zoe@example.com',
              'priority': 2,
              'createdAt': DateTime.utc(2026, 1, 1, 12, 1).toIso8601String(),
              'updatedAt': DateTime.utc(2026, 1, 1, 12, 1).toIso8601String(),
            },
            <String, dynamic>{
              'id': 'contact-1',
              'name': 'Alice',
              'phone': '+34123456789',
              'email': 'alice@example.com',
              'priority': 1,
              'createdAt': DateTime.utc(2026, 1, 1, 12).toIso8601String(),
              'updatedAt': DateTime.utc(2026, 1, 1, 12).toIso8601String(),
            },
          ],
        };
      final repository = InMemoryContactsRepository(localStore: store);

      await repository.restoreState();

      final contacts = await repository.listEmergencyContacts();
      expect(contacts.map((contact) => contact.id),
          <String>['contact-1', 'contact-2']);
    });

    test('removes contacts safely', () async {
      final repository = InMemoryContactsRepository(
        localStore: MemorySharedPrefsSdkStore(),
      );
      final contact = await repository.addEmergencyContact(
        name: 'Alice',
        phone: '+34123456789',
        email: 'alice@example.com',
      );

      await repository.removeEmergencyContact(contact.id);
      expect(await repository.listEmergencyContacts(), isEmpty);
    });
  });
}

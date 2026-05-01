import 'package:eixam_connect_flutter/src/data/repositories/in_memory_contacts_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('InMemoryContactsRepository', () {
    test('adds, sorts, updates, and reorders contacts', () async {
      final repository = InMemoryContactsRepository();

      final second = await repository.addEmergencyContact(
        name: 'Zoe',
        phone: '+34999999999',
        email: 'zoe@example.com',
        priority: 2,
        language: 'en',
      );
      final first = await repository.addEmergencyContact(
        name: 'Alice',
        phone: '+34123456789',
        email: 'alice@example.com',
        priority: 1,
        language: 'ca',
      );

      final contacts = await repository.listEmergencyContacts();
      expect(contacts.map((c) => c.name), <String>['Alice', 'Zoe']);

      await repository.updateEmergencyContact(
        second.copyWith(name: 'Bruno', priority: 1),
      );

      var updated = await repository.listEmergencyContacts();
      expect(updated.map((c) => c.name), <String>['Alice', 'Bruno']);

      await repository.reorderEmergencyContacts(
        <String>[second.id, first.id],
      );
      updated = await repository.listEmergencyContacts();
      expect(updated.first.id, second.id);
      expect(updated.first.priority, 1);
      expect(updated.last.priority, 2);
      expect(first.language, 'ca');
    });

    test('removes contacts safely', () async {
      final repository = InMemoryContactsRepository();
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

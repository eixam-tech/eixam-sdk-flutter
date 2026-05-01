import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';

/// In-memory contacts store for tests and isolated harnesses.
///
/// Emergency contacts are backend-owned in production; this repository does
/// not persist to disk.
class InMemoryContactsRepository implements ContactsRepository {
  InMemoryContactsRepository();

  final List<EmergencyContact> _contacts = [];
  final StreamController<List<EmergencyContact>> _contactsController =
      StreamController<List<EmergencyContact>>.broadcast();

  /// No-op: contacts are not restored from local storage.
  Future<void> restoreState() async {}

  @override
  Future<EmergencyContact> addEmergencyContact({
    required String name,
    required String phone,
    required String email,
    int priority = 1,
    String language = 'en',
  }) async {
    final now = DateTime.now().toUtc();
    final contact = EmergencyContact(
      id: 'contact-${DateTime.now().microsecondsSinceEpoch}',
      name: name.trim(),
      phone: phone.trim(),
      email: email.trim(),
      priority: priority,
      language: _normalizeLanguage(language),
      createdAt: now,
      updatedAt: now,
    );
    _contacts.add(contact);
    _contacts.sort(_compareByPriorityThenName);
    _emit();
    return contact;
  }

  @override
  Future<List<EmergencyContact>> listEmergencyContacts() async =>
      List.unmodifiable(_contacts);

  @override
  Stream<List<EmergencyContact>> watchEmergencyContacts() async* {
    yield List.unmodifiable(_contacts);
    yield* _contactsController.stream;
  }

  @override
  Future<EmergencyContact> updateEmergencyContact(
      EmergencyContact contact) async {
    final index = _contacts.indexWhere((item) => item.id == contact.id);
    if (index == -1) {
      throw StateError('Emergency contact not found: ${contact.id}');
    }
    _contacts[index] = contact.copyWith(
      name: contact.name.trim(),
      phone: contact.phone.trim(),
      email: contact.email.trim(),
      language: _normalizeLanguage(contact.language),
      updatedAt: DateTime.now().toUtc(),
    );
    _contacts.sort(_compareByPriorityThenName);
    _emit();
    return _contacts[index];
  }

  @override
  Future<void> removeEmergencyContact(String contactId) async {
    _contacts.removeWhere((c) => c.id == contactId);
    _emit();
  }

  @override
  Future<void> reorderEmergencyContacts(List<String> orderedContactIds) async {
    final byId = {for (final c in _contacts) c.id: c};
    if (orderedContactIds.length != _contacts.length) {
      throw StateError(
        'reorderEmergencyContacts: expected ${_contacts.length} ids, '
        'got ${orderedContactIds.length}',
      );
    }
    for (var i = 0; i < orderedContactIds.length; i++) {
      final id = orderedContactIds[i];
      final existing = byId[id];
      if (existing == null) {
        throw StateError('reorderEmergencyContacts: unknown id $id');
      }
      byId[id] = existing.copyWith(
        priority: i + 1,
        updatedAt: DateTime.now().toUtc(),
      );
    }
    _contacts
      ..clear()
      ..addAll(byId.values);
    _contacts.sort(_compareByPriorityThenName);
    _emit();
  }

  void _emit() => _contactsController.add(List.unmodifiable(_contacts));

  String _normalizeLanguage(String language) {
    final trimmed = language.trim();
    return trimmed.isEmpty ? 'en' : trimmed;
  }

  int _compareByPriorityThenName(EmergencyContact a, EmergencyContact b) {
    final byPriority = a.priority.compareTo(b.priority);
    if (byPriority != 0) return byPriority;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }
}

import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../datasources_local/shared_prefs_sdk_store.dart';
import '../../mappers/local_state_serializers.dart';

/// Local contacts repository used by the starter project.
///
/// It persists the contact list to shared preferences so host apps can restore
/// emergency escalation targets between launches.
class InMemoryContactsRepository implements ContactsRepository {
  InMemoryContactsRepository({SharedPrefsSdkStore? localStore})
      : _localStore = localStore;

  final SharedPrefsSdkStore? _localStore;
  final List<EmergencyContact> _contacts = [];
  final StreamController<List<EmergencyContact>> _contactsController =
      StreamController<List<EmergencyContact>>.broadcast();

  Future<void> restoreState() async {
    final raw =
        await _localStore?.readJson(SharedPrefsSdkStore.emergencyContactsKey);
    final items = raw?['items'];
    if (items is List) {
      _contacts
        ..clear()
        ..addAll(LocalStateSerializers.emergencyContactsFromJson(items))
        ..sort(_compareByPriorityThenName);
      _emit();
    }
  }

  @override
  Future<EmergencyContact> addEmergencyContact({
    required String name,
    required String phone,
    required String email,
    int priority = 1,
  }) async {
    final now = DateTime.now().toUtc();
    final contact = EmergencyContact(
      id: 'contact-${DateTime.now().microsecondsSinceEpoch}',
      name: name.trim(),
      phone: phone.trim(),
      email: email.trim(),
      priority: priority,
      createdAt: now,
      updatedAt: now,
    );
    _contacts.add(contact);
    _contacts.sort(_compareByPriorityThenName);
    await _persistAndEmit();
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
    _contacts[index] = contact.copyWith(updatedAt: DateTime.now().toUtc());
    _contacts.sort(_compareByPriorityThenName);
    await _persistAndEmit();
    return contact;
  }

  @override
  Future<void> removeEmergencyContact(String contactId) async {
    _contacts.removeWhere((c) => c.id == contactId);
    await _persistAndEmit();
  }

  Future<void> _persistAndEmit() async {
    await _localStore?.saveJson(
      SharedPrefsSdkStore.emergencyContactsKey,
      {'items': LocalStateSerializers.emergencyContactsToJson(_contacts)},
    );
    _emit();
  }

  void _emit() => _contactsController.add(List.unmodifiable(_contacts));

  int _compareByPriorityThenName(EmergencyContact a, EmergencyContact b) {
    final byPriority = a.priority.compareTo(b.priority);
    if (byPriority != 0) return byPriority;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }
}

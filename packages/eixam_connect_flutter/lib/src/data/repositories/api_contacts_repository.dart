import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../../mappers/sdk_contact_mapper.dart';
import '../datasources_remote/sdk_contacts_remote_data_source.dart';

class ApiContactsRepository implements ContactsRepository {
  ApiContactsRepository({
    required this.remoteDataSource,
    this.mapper = const SdkContactMapper(),
  });

  final SdkContactsRemoteDataSource remoteDataSource;
  final SdkContactMapper mapper;
  final StreamController<List<EmergencyContact>> _controller =
      StreamController<List<EmergencyContact>>.broadcast();

  List<EmergencyContact> _contacts = const <EmergencyContact>[];

  @override
  Future<EmergencyContact> addEmergencyContact({
    required String name,
    required String phone,
    required String email,
    int priority = 1,
    String language = 'en',
  }) async {
    final normalizedLanguage = _normalizeLanguage(language);
    final created = mapper.toDomain(
      await remoteDataSource.createContact(
        name: name.trim(),
        phone: phone.trim(),
        email: email.trim(),
        priority: priority,
        language: normalizedLanguage,
      ),
    );
    _contacts = _merge(created);
    _emit();
    return created;
  }

  @override
  Future<List<EmergencyContact>> listEmergencyContacts() async {
    final items = await remoteDataSource.listContacts();
    _contacts = items.map(mapper.toDomain).toList(growable: false);
    _emit();
    return _contacts;
  }

  @override
  Future<void> removeEmergencyContact(String contactId) async {
    await remoteDataSource.deleteContact(contactId);
    _contacts = _contacts.where((contact) => contact.id != contactId).toList(
          growable: false,
        );
    _emit();
  }

  @override
  Future<EmergencyContact> updateEmergencyContact(
      EmergencyContact contact) async {
    final normalizedLanguage = _normalizeLanguage(contact.language);
    final updated = mapper.toDomain(
      await remoteDataSource.replaceContact(
        id: contact.id,
        name: contact.name.trim(),
        phone: contact.phone.trim(),
        email: contact.email.trim(),
        priority: contact.priority,
        language: normalizedLanguage,
      ),
    );
    _contacts = _merge(updated);
    _emit();
    return updated;
  }

  @override
  Future<void> reorderEmergencyContacts(List<String> orderedContactIds) async {
    await remoteDataSource.reorderContacts(orderedContactIds);
    final byId = {for (final contact in _contacts) contact.id: contact};
    final canApplyLocally = byId.length == orderedContactIds.length &&
        orderedContactIds.every(byId.containsKey);
    if (!canApplyLocally) {
      await listEmergencyContacts();
      return;
    }
    _contacts = List<EmergencyContact>.unmodifiable([
      for (var index = 0; index < orderedContactIds.length; index++)
        byId[orderedContactIds[index]]!.copyWith(priority: index + 1),
    ]);
    _emit();
  }

  @override
  Stream<List<EmergencyContact>> watchEmergencyContacts() async* {
    yield _contacts;
    yield* _controller.stream;
  }

  Future<void> dispose() async {
    await _controller.close();
  }

  List<EmergencyContact> _merge(EmergencyContact contact) {
    final next = <EmergencyContact>[
      for (final existing in _contacts)
        if (existing.id != contact.id) existing,
      contact,
    ];
    next.sort(_compareByPriorityThenName);
    return List<EmergencyContact>.unmodifiable(next);
  }

  void _emit() =>
      _controller.add(List<EmergencyContact>.unmodifiable(_contacts));

  String _normalizeLanguage(String language) {
    final trimmed = language.trim();
    return trimmed.isEmpty ? 'en' : trimmed;
  }

  int _compareByPriorityThenName(EmergencyContact a, EmergencyContact b) {
    final byPriority = a.priority.compareTo(b.priority);
    if (byPriority != 0) {
      return byPriority;
    }
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }
}

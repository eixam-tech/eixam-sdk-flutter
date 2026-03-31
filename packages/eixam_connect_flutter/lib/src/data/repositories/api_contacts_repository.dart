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
  }) async {
    final created = mapper.toDomain(
      await remoteDataSource.createContact(
        name: name,
        phone: phone,
        email: email,
        priority: priority,
      ),
    );
    _contacts = _merge(created);
    _emit();
    return created;
  }

  @override
  Future<List<EmergencyContact>> listEmergencyContacts() async {
    final items = await remoteDataSource.listContacts();
    _contacts =
        items.map(mapper.toDomain).toList(growable: false);
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
  Future<EmergencyContact> updateEmergencyContact(EmergencyContact contact) async {
    final updated = mapper.toDomain(
      await remoteDataSource.replaceContact(
        id: contact.id,
        name: contact.name,
        phone: contact.phone,
        email: contact.email,
        priority: contact.priority,
      ),
    );
    _contacts = _merge(updated);
    _emit();
    return updated;
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
    next.sort((a, b) => a.priority.compareTo(b.priority));
    return List<EmergencyContact>.unmodifiable(next);
  }

  void _emit() => _controller.add(List<EmergencyContact>.unmodifiable(_contacts));
}

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_contacts_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/data/dtos/sdk_contact_dto.dart';
import 'package:eixam_connect_flutter/src/data/repositories/api_contacts_repository.dart';
import 'package:eixam_connect_flutter/src/mappers/eixam_contact_phone.dart';
import 'package:eixam_connect_flutter/src/mappers/sdk_contact_mapper.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes/memory_shared_prefs_sdk_store.dart';

void main() {
  test('strips spaces from E.164 phones', () {
    expect(EixamContactPhone.normalize('+34 600 000 001'), '+34600000001');
    expect(EixamContactPhone.normalize('+34600000001'), '+34600000001');
  });

  test('maps contacts without timestamps', () {
    const mapper = SdkContactMapper();
    final now = DateTime.utc(2026, 9, 1, 12);
    final contact = mapper.toDomain(
      const SdkContactDto(
        id: 'c1',
        name: 'Anna',
        phone: '+34600000001',
        email: 'anna@eixam.test',
        priority: 1,
      ),
      now: now,
    );
    expect(contact.createdAt, now);
    expect(contact.updatedAt, now);
  });

  test('create strips phone spaces, keeps cache, and survives a restart',
      () async {
    final remote = _FakeContactsRemote();
    final store = MemorySharedPrefsSdkStore();
    final repository = ApiContactsRepository(
      remoteDataSource: remote,
      localStore: store,
    );

    final created = await repository.addEmergencyContact(
      name: 'Anna',
      phone: '+34 600 000 001',
      email: 'anna@eixam.test',
    );
    expect(remote.lastCreatePhone, '+34600000001');
    expect(repository.peekEmergencyContacts().single.id, created.id);

    final restored = ApiContactsRepository(
      remoteDataSource: _FakeContactsRemote(),
      localStore: store,
    );
    await restored.restoreState();
    expect(restored.peekEmergencyContacts().single.name, 'Anna');
    expect(restored.peekEmergencyContacts().single.phone, '+34600000001');
  });
}

class _FakeContactsRemote implements SdkContactsRemoteDataSource {
  String? lastCreatePhone;

  @override
  Future<SdkContactDto> createContact({
    required String name,
    required String phone,
    required String email,
    required int priority,
    String language = 'en',
  }) async {
    lastCreatePhone = phone;
    return SdkContactDto(
      id: 'c1',
      name: name,
      phone: phone,
      email: email,
      priority: priority,
      language: language,
    );
  }

  @override
  Future<void> deleteContact(String id) async {}

  @override
  Future<List<SdkContactDto>> listContacts() async => const <SdkContactDto>[];

  @override
  Future<void> reorderContacts(List<String> orderedIds) async {}

  @override
  Future<SdkContactDto> replaceContact({
    required String id,
    required String name,
    required String phone,
    required String email,
    required int priority,
    String language = 'en',
  }) async {
    return SdkContactDto(
      id: id,
      name: name,
      phone: phone,
      email: email,
      priority: priority,
      language: language,
    );
  }
}

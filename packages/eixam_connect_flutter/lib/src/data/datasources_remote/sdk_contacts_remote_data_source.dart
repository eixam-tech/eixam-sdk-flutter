import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../dtos/sdk_contact_dto.dart';
import 'sdk_http_transport.dart';

abstract class SdkContactsRemoteDataSource {
  Future<List<SdkContactDto>> listContacts();
  Future<SdkContactDto> createContact({
    required String name,
    required String phone,
    required String email,
    required int priority,
  });
  Future<SdkContactDto> replaceContact({
    required String id,
    required String name,
    required String phone,
    required String email,
    required int priority,
  });
  Future<void> deleteContact(String id);
}

class HttpSdkContactsRemoteDataSource implements SdkContactsRemoteDataSource {
  HttpSdkContactsRemoteDataSource({required this.transport});

  final SdkHttpTransport transport;

  @override
  Future<List<SdkContactDto>> listContacts() async {
    final response = await transport.get('/v1/sdk/contacts');
    if (response.statusCode != 200) {
      throw ContactsException('E_HTTP_CONTACTS_LIST_FAILED', response.body);
    }
    final payload =
        _decode(response.body, errorCode: 'E_HTTP_CONTACTS_LIST_FAILED');
    final contacts = payload['contacts'];
    if (contacts is! List) {
      throw const ContactsException(
        'E_HTTP_CONTACTS_LIST_FAILED',
        'The backend did not return a valid contacts list.',
      );
    }
    return contacts
        .whereType<Map<String, dynamic>>()
        .map(SdkContactDto.fromJson)
        .toList(growable: false);
  }

  @override
  Future<SdkContactDto> createContact({
    required String name,
    required String phone,
    required String email,
    required int priority,
  }) async {
    final response = await transport.post(
      '/v1/sdk/contacts',
      body: jsonEncode(_bodyFor(
        name: name,
        phone: phone,
        email: email,
        priority: priority,
      )),
    );
    if (response.statusCode != 201) {
      throw ContactsException('E_HTTP_CONTACT_CREATE_FAILED', response.body);
    }
    return _contactFromResponse(
      response.body,
      errorCode: 'E_HTTP_CONTACT_CREATE_FAILED',
    );
  }

  @override
  Future<SdkContactDto> replaceContact({
    required String id,
    required String name,
    required String phone,
    required String email,
    required int priority,
  }) async {
    final response = await transport.client.put(
      Uri.parse('${transport.config.apiBaseUrl}/v1/sdk/contacts/$id'),
      headers: transport.headersForCurrentSession(),
      body: jsonEncode(_bodyFor(
        name: name,
        phone: phone,
        email: email,
        priority: priority,
      )),
    );
    if (response.statusCode != 200) {
      throw ContactsException('E_HTTP_CONTACT_UPDATE_FAILED', response.body);
    }
    return _contactFromResponse(
      response.body,
      errorCode: 'E_HTTP_CONTACT_UPDATE_FAILED',
    );
  }

  @override
  Future<void> deleteContact(String id) async {
    final response = await transport.client.delete(
      Uri.parse('${transport.config.apiBaseUrl}/v1/sdk/contacts/$id'),
      headers: transport.headersForCurrentSession(),
    );
    if (response.statusCode != 204) {
      throw ContactsException('E_HTTP_CONTACT_DELETE_FAILED', response.body);
    }
  }

  Map<String, dynamic> _bodyFor({
    required String name,
    required String phone,
    required String email,
    required int priority,
  }) {
    return <String, dynamic>{
      'name': name,
      'phone': phone,
      'email': email,
      'priority': priority,
    };
  }

  SdkContactDto _contactFromResponse(
    String body, {
    required String errorCode,
  }) {
    final payload = _decode(body, errorCode: errorCode);
    final contact = payload['contact'];
    if (contact is! Map<String, dynamic>) {
      throw ContactsException(
        errorCode,
        'The backend did not return a valid contact payload.',
      );
    }
    return SdkContactDto.fromJson(contact);
  }

  Map<String, dynamic> _decode(
    String body, {
    required String errorCode,
  }) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {}
    throw ContactsException(errorCode, 'The backend returned invalid JSON.');
  }
}

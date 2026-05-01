import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:http/http.dart' as http;

import '../dtos/sdk_contact_dto.dart';
import 'sdk_contacts_http_support.dart';
import 'sdk_http_transport.dart';

abstract class SdkContactsRemoteDataSource {
  Future<List<SdkContactDto>> listContacts();
  Future<SdkContactDto> createContact({
    required String name,
    required String phone,
    required String email,
    required int priority,
    String language = 'en',
  });
  Future<SdkContactDto> replaceContact({
    required String id,
    required String name,
    required String phone,
    required String email,
    required int priority,
    String language = 'en',
  });
  Future<void> deleteContact(String id);
  Future<void> reorderContacts(List<String> orderedIds);
}

class HttpSdkContactsRemoteDataSource implements SdkContactsRemoteDataSource {
  HttpSdkContactsRemoteDataSource({required this.transport});

  final SdkHttpTransport transport;

  @override
  Future<List<SdkContactDto>> listContacts() async {
    final response = await transport.get(
      '/v1/sdk/contacts',
      headers: const {'Accept': 'application/json'},
    );
    _ensureStatus(
      response,
      expectedStatusCode: 200,
      defaultCode: 'E_HTTP_CONTACTS_LIST_FAILED',
    );
    final payload =
        _decode(response.body, errorCode: 'E_HTTP_CONTACTS_LIST_FAILED');
    final contacts = payload['contacts'];
    if (contacts is! List) {
      throw const ContactsException(
        'E_HTTP_CONTACTS_LIST_FAILED',
        'The backend did not return a valid contacts list.',
      );
    }
    return [
      for (final contact in contacts)
        if (contact is Map<String, dynamic>)
          SdkContactDto.fromJson(contact)
        else
          throw const ContactsException(
            'E_HTTP_CONTACTS_LIST_FAILED',
            'The backend returned an invalid contact payload.',
          ),
    ];
  }

  @override
  Future<SdkContactDto> createContact({
    required String name,
    required String phone,
    required String email,
    required int priority,
    String language = 'en',
  }) async {
    final response = await transport.post(
      '/v1/sdk/contacts',
      headers: const {'Accept': 'application/json'},
      body: jsonEncode(_bodyFor(
        name: name,
        phone: phone,
        email: email,
        priority: priority,
        language: language,
      )),
    );
    _ensureStatus(
      response,
      expectedStatusCode: 201,
      defaultCode: 'E_HTTP_CONTACT_CREATE_FAILED',
    );
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
    String language = 'en',
  }) async {
    final response = await transport.put(
      '/v1/sdk/contacts/$id',
      headers: const {'Accept': 'application/json'},
      body: jsonEncode(_bodyFor(
        name: name,
        phone: phone,
        email: email,
        priority: priority,
        language: language,
      )),
    );
    _ensureStatus(
      response,
      expectedStatusCode: 200,
      defaultCode: 'E_HTTP_CONTACT_UPDATE_FAILED',
    );
    return _contactFromResponse(
      response.body,
      errorCode: 'E_HTTP_CONTACT_UPDATE_FAILED',
    );
  }

  @override
  Future<void> deleteContact(String id) async {
    final response = await transport.delete('/v1/sdk/contacts/$id');
    _ensureStatus(
      response,
      expectedStatusCode: 204,
      defaultCode: 'E_HTTP_CONTACT_DELETE_FAILED',
    );
  }

  @override
  Future<void> reorderContacts(List<String> orderedIds) async {
    final response = await transport.put(
      '/v1/sdk/contacts/reorder',
      headers: const {'Accept': 'application/json'},
      body: jsonEncode(<String, dynamic>{'order': orderedIds}),
    );
    _ensureStatus(
      response,
      expectedStatusCode: 204,
      defaultCode: 'E_HTTP_CONTACTS_REORDER_FAILED',
    );
  }

  Map<String, dynamic> _bodyFor({
    required String name,
    required String phone,
    required String email,
    required int priority,
    String language = 'en',
  }) {
    return <String, dynamic>{
      'name': name,
      'phone': phone,
      'email': email,
      'priority': priority,
      'language': language,
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
    late final dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw ContactsException(errorCode, 'The backend returned invalid JSON.');
    }
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    throw ContactsException(errorCode, 'The backend returned invalid JSON.');
  }

  void _ensureStatus(
    http.Response response, {
    required int expectedStatusCode,
    required String defaultCode,
  }) {
    final err = SdkContactsHttpSupport.tryMapHttpFailure(
      response,
      defaultCode: defaultCode,
    );
    if (err != null) {
      throw err;
    }
    if (response.statusCode != expectedStatusCode) {
      throw ContactsException(defaultCode, response.body);
    }
  }
}

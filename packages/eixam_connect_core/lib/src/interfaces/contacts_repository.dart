import '../entities/emergency_contact.dart';

/// Repository contract for emergency contacts managed by the SDK.
abstract class ContactsRepository {
  Future<List<EmergencyContact>> listEmergencyContacts();
  Stream<List<EmergencyContact>> watchEmergencyContacts();

  Future<EmergencyContact> addEmergencyContact({
    required String name,
    required String phone,
    required String email,
    int priority,
  });

  Future<EmergencyContact> updateEmergencyContact(EmergencyContact contact);
  Future<void> removeEmergencyContact(String contactId);
}

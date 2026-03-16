import '../entities/emergency_contact.dart';

/// Repository contract for emergency contacts managed by the SDK.
abstract class ContactsRepository {
  Future<List<EmergencyContact>> listEmergencyContacts();
  Stream<List<EmergencyContact>> watchEmergencyContacts();

  Future<EmergencyContact> addEmergencyContact({
    required String name,
    String? phone,
    String? email,
    int priority,
    bool active,
  });

  Future<EmergencyContact> updateEmergencyContact(EmergencyContact contact);
  Future<void> setEmergencyContactActive(String contactId, bool active);
  Future<void> removeEmergencyContact(String contactId);
}

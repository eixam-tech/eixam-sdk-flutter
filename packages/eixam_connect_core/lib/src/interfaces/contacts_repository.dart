import '../entities/emergency_contact.dart';

/// Repository contract for emergency contacts managed by the SDK.
abstract class ContactsRepository {
  Future<List<EmergencyContact>> listEmergencyContacts();

  /// Last known contacts, including disk cache after restore. Never hits the network.
  List<EmergencyContact> peekEmergencyContacts();

  Stream<List<EmergencyContact>> watchEmergencyContacts();

  Future<EmergencyContact> addEmergencyContact({
    required String name,
    required String phone,
    required String email,
    int priority = 1,
    String language = 'en',
  });

  Future<EmergencyContact> updateEmergencyContact(EmergencyContact contact);
  Future<void> removeEmergencyContact(String contactId);

  /// Sets priorities from the ordered list of contact ids (index + 1).
  ///
  /// Backend requires every contact id exactly once.
  Future<void> reorderEmergencyContacts(List<String> orderedContactIds);
}

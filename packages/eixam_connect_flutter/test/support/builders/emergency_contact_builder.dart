import 'package:eixam_connect_core/eixam_connect_core.dart';

EmergencyContact buildEmergencyContact({
  String id = 'contact-1',
  String name = 'Alice',
  String? phone = '+34123456789',
  String? email = 'alice@example.com',
  int priority = 1,
  bool active = true,
}) {
  return EmergencyContact(
    id: id,
    name: name,
    phone: phone,
    email: email,
    priority: priority,
    active: active,
  );
}

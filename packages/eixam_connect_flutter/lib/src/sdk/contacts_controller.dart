import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/foundation.dart';

/// Presentation-friendly controller for emergency contacts.
class ContactsController extends ChangeNotifier {
  ContactsController({required this.sdk});

  final EixamConnectSdk sdk;

  List<EmergencyContact> contacts = const [];
  bool isBusy = false;
  String? lastError;

  StreamSubscription<List<EmergencyContact>>? _contactsSubscription;

  /// Loads the initial contact list and keeps it in sync with the SDK stream.
  Future<void> initialize() async {
    contacts = await sdk.listEmergencyContacts();
    notifyListeners();
    _contactsSubscription = sdk.watchEmergencyContacts().listen((items) {
      contacts = items;
      notifyListeners();
    });
  }

  /// Adds a new emergency contact to the SDK store.
  Future<void> add({
    required String name,
    required String phone,
    required String email,
    int priority = 1,
  }) async {
    await _run(() => sdk.addEmergencyContact(
          name: name,
          phone: phone,
          email: email,
          priority: priority,
        ));
  }

  /// Removes an emergency contact from the SDK store.
  Future<void> remove(String contactId) async {
    await _run(() => sdk.removeEmergencyContact(contactId));
  }

  Future<void> _run(Future<dynamic> Function() action) async {
    isBusy = true;
    lastError = null;
    notifyListeners();
    try {
      await action();
    } catch (error) {
      lastError = error.toString();
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _contactsSubscription?.cancel();
    super.dispose();
  }
}

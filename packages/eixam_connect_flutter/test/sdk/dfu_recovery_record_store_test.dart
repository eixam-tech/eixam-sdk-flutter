import 'package:eixam_connect_flutter/src/sdk/dfu_recovery_record_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('record round-trips and an empty record removes the key', () async {
    final store = SharedPrefsDfuRecoveryRecordStore();
    expect((await store.load()).isEmpty, isTrue);
    final at = DateTime.utc(2026, 1, 2, 3);
    await store.save(
      DfuRecoveryRecord(
        sessionId: 's',
        firstMissAt: at,
        cablePreparedAt: at,
        staleLinkDeviceId: 'tag',
        staleLinkAt: at,
      ),
    );
    final loaded = await SharedPrefsDfuRecoveryRecordStore().load();
    expect(loaded.sessionId, 's');
    expect(loaded.firstMissAt, at);
    expect(loaded.cablePreparedAt, at);
    expect(loaded.staleLinkDeviceId, 'tag');
    await store.save(const DfuRecoveryRecord());
    expect((await store.load()).isEmpty, isTrue);
  });
}

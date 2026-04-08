import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'is covered by the SDK package adapter mapping suite',
    () {},
    skip: 'Direct control-app focused execution for this adapter file is not '
        'reliable in the current headless Windows runner. Equivalent Android '
        'adapter mapping coverage now lives in '
        'packages/eixam_connect_flutter/test/sdk/android_protection_platform_adapter_test.dart.',
  );
}

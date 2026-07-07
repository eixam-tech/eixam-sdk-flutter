import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_ui/eixam_connect_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

DeviceCountryConfigStatus _status(DeviceCountryConfigOutcome outcome) =>
    DeviceCountryConfigStatus(outcome: outcome, updatedAt: DateTime(2026));

Widget _host(Stream<DeviceCountryConfigStatus> stream) => MaterialApp(
      home: EixamUiScope(
        localeCode: 'en',
        child: DeviceCountryConfigModalHost(
          statusStream: stream,
          successAutoDismiss: const Duration(milliseconds: 50),
          child: const Scaffold(body: Text('APP')),
        ),
      ),
    );

void main() {
  testWidgets('loading on applying, success on applied, then auto-dismiss',
      (tester) async {
    final controller = StreamController<DeviceCountryConfigStatus>();
    await tester.pumpWidget(_host(controller.stream));
    expect(find.text('APP'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    controller.add(_status(DeviceCountryConfigOutcome.applying));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    controller.add(_status(DeviceCountryConfigOutcome.applied));
    await tester.pump();
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 60)); // auto-dismiss fires
    expect(find.byIcon(Icons.check_circle_outline), findsNothing);
    await controller.close();
  });

  testWidgets('error with a manual dismiss on failure', (tester) async {
    final controller = StreamController<DeviceCountryConfigStatus>();
    await tester.pumpWidget(_host(controller.stream));

    controller.add(_status(DeviceCountryConfigOutcome.applying));
    await tester.pump();
    controller.add(_status(DeviceCountryConfigOutcome.failed));
    await tester.pump();

    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.text('OK'), findsOneWidget);

    await tester.tap(find.text('OK'));
    await tester.pump();
    expect(find.byIcon(Icons.error_outline), findsNothing);
    await controller.close();
  });

  testWidgets('stays transparent for a terminal status without a prior apply',
      (tester) async {
    final controller = StreamController<DeviceCountryConfigStatus>();
    await tester.pumpWidget(_host(controller.stream));

    // A stale "applied" (e.g. from a previous session) must NOT pop a modal.
    controller.add(_status(DeviceCountryConfigOutcome.applied));
    await tester.pump();
    expect(find.byIcon(Icons.check_circle_outline), findsNothing);

    // Skip outcomes stay transparent too.
    controller.add(_status(DeviceCountryConfigOutcome.skippedUpToDate));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await controller.close();
  });
}

import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_ui/eixam_connect_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

DeviceCountryConfigStatus _status(
  DeviceCountryConfigOutcome outcome, {
  bool? applyAttempted,
  bool canRetry = false,
}) => DeviceCountryConfigStatus(
  outcome: outcome,
  updatedAt: DateTime(2026),
  applyAttempted:
      applyAttempted ??
      <DeviceCountryConfigOutcome>{
        DeviceCountryConfigOutcome.applying,
        DeviceCountryConfigOutcome.applied,
        DeviceCountryConfigOutcome.failed,
        DeviceCountryConfigOutcome.skippedFirmwareUnsupported,
      }.contains(outcome),
  canRetry: canRetry,
);

Widget _host(
  Stream<DeviceCountryConfigStatus> stream, {
  Stream<DeviceCountryConfigStatus>? supplementalStatusStream,
  Future<DeviceCountryConfigStatus> Function()? onConfirm,
}) => MaterialApp(
  theme: ThemeData(splashFactory: NoSplash.splashFactory),
  home: EixamUiScope(
    localeCode: 'en',
    child: DeviceCountryConfigModalHost(
      statusStream: stream,
      supplementalStatusStream: supplementalStatusStream,
      onConfirm:
          onConfirm ?? () async => _status(DeviceCountryConfigOutcome.applied),
      successAutoDismiss: const Duration(milliseconds: 50),
      child: const Scaffold(body: Text('APP')),
    ),
  ),
);

void main() {
  testWidgets('asks before applying and switches to loading on confirmation', (
    tester,
  ) async {
    final controller = StreamController<DeviceCountryConfigStatus>();
    final result = Completer<DeviceCountryConfigStatus>();
    var confirmCalls = 0;
    await tester.pumpWidget(
      _host(
        controller.stream,
        onConfirm: () {
          confirmCalls += 1;
          return result.future;
        },
      ),
    );

    controller.add(_status(DeviceCountryConfigOutcome.updateAvailable));
    await tester.pump();

    expect(find.text('Device region update required'), findsOneWidget);
    expect(find.textContaining('radio regulations'), findsOneWidget);
    expect(find.textContaining('to continue'), findsOneWidget);
    expect(find.text('Update'), findsOneWidget);
    expect(find.text('Not now'), findsNothing);
    expect(find.text('OK'), findsNothing);
    expect(find.textContaining('LoRa'), findsNothing);

    final barrier = tester.widget<ModalBarrier>(
      find.byWidgetPredicate(
        (widget) =>
            widget is ModalBarrier && widget.color == const Color(0xCC000000),
      ),
    );
    expect(barrier.dismissible, isFalse);
    expect(barrier.color, const Color(0xCC000000));

    await tester.tap(find.text('Update'));
    await tester.pump();
    expect(confirmCalls, 1);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    result.complete(_status(DeviceCountryConfigOutcome.applied));
    await tester.pump();
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    await controller.close();
  });

  testWidgets('confirmation cannot be dismissed without updating', (
    tester,
  ) async {
    final controller = StreamController<DeviceCountryConfigStatus>();
    var confirmCalls = 0;
    await tester.pumpWidget(
      _host(
        controller.stream,
        onConfirm: () async {
          confirmCalls += 1;
          return _status(DeviceCountryConfigOutcome.applied);
        },
      ),
    );

    controller.add(_status(DeviceCountryConfigOutcome.updateAvailable));
    await tester.pump();

    expect(find.text('Not now'), findsNothing);
    expect(find.text('OK'), findsNothing);
    await tester.tapAt(const Offset(4, 4));
    await tester.pump();

    expect(find.text('Device region update required'), findsOneWidget);
    expect(confirmCalls, 0);
    await controller.close();
  });

  testWidgets('loading on applying, success on applied, then auto-dismiss', (
    tester,
  ) async {
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

  testWidgets('supplemental preview stream drives the real failure modal', (
    tester,
  ) async {
    final production = StreamController<DeviceCountryConfigStatus>();
    final preview = StreamController<DeviceCountryConfigStatus>();
    await tester.pumpWidget(
      _host(production.stream, supplementalStatusStream: preview.stream),
    );

    preview.add(_status(DeviceCountryConfigOutcome.applying));
    await tester.pump();
    preview.add(_status(DeviceCountryConfigOutcome.failed));
    await tester.pump();

    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.text('OK'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pump();
    expect(find.byIcon(Icons.error_outline), findsNothing);

    await production.close();
    await preview.close();
  });

  testWidgets('stays transparent for a terminal status without a prior apply', (
    tester,
  ) async {
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

  testWidgets('a detection skip closes an invalidated confirmation', (
    tester,
  ) async {
    final controller = StreamController<DeviceCountryConfigStatus>();
    await tester.pumpWidget(_host(controller.stream));

    controller.add(_status(DeviceCountryConfigOutcome.updateAvailable));
    await tester.pump();
    expect(find.text('Device region update required'), findsOneWidget);

    controller.add(
      _status(
        DeviceCountryConfigOutcome.skippedNoLocation,
        applyAttempted: false,
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Device region update required'), findsNothing);
    expect(find.byIcon(Icons.error_outline), findsNothing);
    await controller.close();
  });

  testWidgets('idle confirmation result becomes a terminal error', (
    tester,
  ) async {
    final controller = StreamController<DeviceCountryConfigStatus>();
    await tester.pumpWidget(
      _host(
        controller.stream,
        onConfirm: () async => _status(DeviceCountryConfigOutcome.idle),
      ),
    );

    controller.add(_status(DeviceCountryConfigOutcome.updateAvailable));
    await tester.pump();
    await tester.tap(find.text('Update'));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.text('OK'), findsOneWidget);
    await controller.close();
  });

  testWidgets('retryable apply error can retry the same pending plan', (
    tester,
  ) async {
    final controller = StreamController<DeviceCountryConfigStatus>();
    var attempts = 0;
    await tester.pumpWidget(
      _host(
        controller.stream,
        onConfirm: () async {
          attempts += 1;
          return attempts == 1
              ? _status(
                  DeviceCountryConfigOutcome.skippedSafetyActive,
                  applyAttempted: true,
                  canRetry: true,
                )
              : _status(DeviceCountryConfigOutcome.applied);
        },
      ),
    );

    controller.add(_status(DeviceCountryConfigOutcome.updateAvailable));
    await tester.pump();
    await tester.tap(find.text('Update'));
    await tester.pump();
    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('OK'), findsOneWidget);

    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(attempts, 2);
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    await controller.close();
  });
}

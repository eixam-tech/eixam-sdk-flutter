import 'package:flutter_test/flutter_test.dart';

import 'package:eixam_control_app/src/bootstrap/bootstrap_app.dart';

void main() {
  testWidgets('Bootstrap screen renders', (WidgetTester tester) async {
    await tester.pumpWidget(const BootstrapApp());

    expect(find.text('EIXAM SDK bootstrap diagnostic'), findsOneWidget);
    expect(find.text('Start SDK'), findsOneWidget);
  });
}

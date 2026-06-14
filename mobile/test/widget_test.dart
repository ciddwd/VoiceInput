import 'package:flutter_test/flutter_test.dart';

import 'package:mobile/main.dart';

void main() {
  testWidgets('App boots without crashing', (WidgetTester tester) async {
    await tester.pumpWidget(const VoiceInputApp());
    expect(find.text('VoiceInput'), findsOneWidget);
  });
}

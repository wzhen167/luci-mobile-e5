import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:luci_mobile/screens/insights_screen.dart';

/// Insights moved out of the bottom bar and into Settings. That makes it a
/// pushed route in every case, and a pushed route has to take a back button —
/// the shell's drawer menu would open a drawer the page cannot reach.
void main() {
  testWidgets('insights offers a back button, not the drawer menu', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: InsightsScreen())),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.arrow_back_ios_new_rounded), findsOneWidget);
    expect(find.byIcon(Icons.menu), findsNothing);
  });

  testWidgets('the four insight pages are all still here', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: InsightsScreen())),
    );
    await tester.pumpAndSettle();

    // Moved as a whole: the group kept its entries instead of being reduced to
    // a link to the old screen.
    for (final label in [
      'Activity',
      'System log',
      'Traffic history',
      'Diagnostics',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
  });
}

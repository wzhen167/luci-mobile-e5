import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:luci_mobile/navigation/app_drawer.dart';
import 'package:luci_mobile/navigation/luci_tab.dart';

Widget _wrap(
  ValueChanged<LuciTab> onSelect, {
  LuciTab selected = LuciTab.dashboard,
}) => MaterialApp(
  home: Scaffold(
    body: AppDrawer(
      selected: selected,
      routerLabel: '192.168.1.1',
      onSelect: onSelect,
    ),
  ),
);

void main() {
  testWidgets('every destination is reachable from the drawer', (tester) async {
    await tester.pumpWidget(_wrap((_) {}));
    await tester.pumpAndSettle();

    for (final label in [
      'Dashboard',
      'Network',
      'Clients',
      'Cellular',
      'Settings',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
  });

  // Services moved into Settings, and Insights moved there before it. Either
  // one back in the drawer would give the same page two doors and rebuild the
  // "More" problem this change removed.
  testWidgets('drawer-only sections are gone', (tester) async {
    await tester.pumpWidget(_wrap((_) {}));
    await tester.pumpAndSettle();

    expect(find.text('Services'), findsNothing);
    expect(find.text('Insights'), findsNothing);
    expect(LuciTab.values.length, 5);
  });

  testWidgets('the active section is marked as selected', (tester) async {
    await tester.pumpWidget(_wrap((_) {}, selected: LuciTab.cellular));
    await tester.pumpAndSettle();

    final cellular = tester.widget<ListTile>(
      find.ancestor(of: find.text('Cellular'), matching: find.byType(ListTile)),
    );
    final dashboard = tester.widget<ListTile>(
      find.ancestor(
        of: find.text('Dashboard'),
        matching: find.byType(ListTile),
      ),
    );

    expect(cellular.selected, isTrue);
    expect(dashboard.selected, isFalse);
  });

  testWidgets('tapping an entry reports the destination', (tester) async {
    LuciTab? picked;
    await tester.pumpWidget(_wrap((tab) => picked = tab));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    expect(picked, LuciTab.settings);
  });

  testWidgets('the drawer says which router it is configuring', (tester) async {
    await tester.pumpWidget(_wrap((_) {}));
    await tester.pumpAndSettle();

    expect(find.text('192.168.1.1'), findsOneWidget);
  });
}

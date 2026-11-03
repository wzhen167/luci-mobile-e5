import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:luci_mobile/models/cellular.dart';
import 'package:luci_mobile/models/cellular_radio.dart';
import 'package:luci_mobile/models/router_capabilities.dart';
import 'package:luci_mobile/screens/cellular_radio_tab.dart';
import 'package:luci_mobile/screens/cellular_screen.dart';
import 'package:luci_mobile/services/cellular_service.dart';
import 'package:luci_mobile/services/sms_inbox.dart';
import 'package:luci_mobile/state/cellular_providers.dart';
import 'package:luci_mobile/state/cellular_radio_providers.dart';
import 'package:luci_mobile/state/feature_providers.dart';

const _radio = CellularRadioState(
  mode: '5g4g',
  lteLocked: [1, 3, 5],
  nrLocked: [28],
  lteCaps: [1, 3, 5, 8, 41],
  nrCaps: [1, 28, 41, 78],
  autoApply: true,
  dataUp: true,
  dataSim: 0,
  radioEnabled: [true, false],
  serving: ServingCell(rat: 'nr', channel: 152890, pci: 669, band: 28),
);

Widget _tab(CellularRadioState state, {List<Object> overrides = const []}) =>
    ProviderScope(
      // `Override` is not exported by flutter_riverpod in this version; the
      // cast keeps the helper typed at the call site.
      overrides: overrides.cast(),
      child: MaterialApp(
        home: Scaffold(body: CellularRadioTab(state: state)),
      ),
    );

/// A mutations provider that accepts every write without a router.
class _InstantMutations extends CellularRadioMutations {
  _InstantMutations(super.ref);

  @override
  Future<void> setDataUp(bool up) async {}
}

const _snapshot = CellularSnapshot(
  interfaces: [
    CellularInterface(
      section: 'wwan',
      proto: 'modemmanager',
      device: 'unisoc-sipc',
      apn: 'cmnet',
      up: true,
    ),
  ],
);

Widget _screen({required bool supported}) => ProviderScope(
  overrides: [
    cellularProvider.overrideWith((ref) async => _snapshot),
    cellularRadioProvider.overrideWith(
      (ref) async => supported ? _radio : null,
    ),
    featureProvider.overrideWith(
      (ref, feature) => const FeatureAvailability.available(),
    ),
    smsInboxProvider.overrideWith(
      (ref) async =>
          const SmsInboxSnapshot(backend: SmsBackend.vendor, messages: []),
    ),
  ],
  child: const MaterialApp(home: CellularScreen()),
);

void main() {
  testWidgets('the tab shows the switches and the current locks', (
    tester,
  ) async {
    await tester.pumpWidget(_tab(_radio));
    await tester.pumpAndSettle();

    expect(find.text('Mobile data'), findsNWidgets(2));
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('SIM 1 radio'), findsOneWidget);
    expect(find.text('SIM 2 radio'), findsOneWidget);

    expect(find.text('Network mode'), findsOneWidget);
    expect(find.text('5G + 4G'), findsOneWidget);
    expect(find.text('Band lock'), findsOneWidget);
    expect(find.text('LTE 1,3,5 · NR 28'), findsOneWidget);
    expect(find.text('Cell lock'), findsOneWidget);
    // No cell lock yet, so the row says so and the sheet offers to add one.
    expect(find.text('Automatic'), findsOneWidget);
  });

  // An unlocked modem has no band restriction, and saying "LTE — · NR —"
  // would read as "nothing works".
  testWidgets('no band lock reads as every band', (tester) async {
    const state = CellularRadioState(mode: 'auto', dataUp: true);
    await tester.pumpWidget(_tab(state));
    await tester.pumpAndSettle();

    expect(find.text('All supported bands'), findsOneWidget);
    expect(find.text('Automatic'), findsOneWidget);
    expect(find.text('Automatic (5G/4G/3G/2G)'), findsOneWidget);
  });

  testWidgets('the band sheet offers the bands the modem knows', (
    tester,
  ) async {
    await tester.pumpWidget(_tab(_radio));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Band lock'));
    await tester.pumpAndSettle();

    expect(find.text('All bands'), findsWidgets);
    // B41 and n41 are the same number on different RATs, and the sheet has to
    // distinguish them: 5G bands are written with a lowercase n.
    expect(find.text('B41'), findsOneWidget);
    expect(find.text('n41'), findsOneWidget);
    expect(find.text('n78'), findsOneWidget);
    // Only the union of locked and supported bands, never a made-up one.
    expect(find.text('B7'), findsNothing);
  });

  testWidgets('the cell sheet locks to what is serving now', (tester) async {
    await tester.pumpWidget(_tab(_radio));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cell lock'));
    await tester.pumpAndSettle();

    expect(find.text('Lock to the current cell'), findsOneWidget);
    expect(find.text('Remove the lock'), findsOneWidget);
    expect(find.text('NR 152890 · PCI 669'), findsWidgets);
  });

  testWidgets('a modem without a serving cell cannot be pinned', (
    tester,
  ) async {
    const state = CellularRadioState(mode: 'auto', dataUp: true);
    await tester.pumpWidget(_tab(state));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cell lock'));
    await tester.pumpAndSettle();

    expect(
      find.text('The modem has not reported a serving cell yet.'),
      findsOneWidget,
    );
    final tile = tester.widget<ListTile>(
      find.ancestor(
        of: find.text('Lock to the current cell'),
        matching: find.byType(ListTile),
      ),
    );
    expect(tile.enabled, isFalse);
  });

  // Turning data off drops the connection the user may be reading this over,
  // so it asks first — and the default answer is "no".
  testWidgets('turning data off asks before it acts', (tester) async {
    await tester.pumpWidget(_tab(_radio));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Turn off mobile data? The router will lose its internet connection.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.widget<Switch>(find.byType(Switch).first).value, isTrue);
  });

  // `ifup` returns before the bearer is back, so an immediate re-read says
  // "down" on a command that is working. The switch has to keep showing what
  // was asked for, and fall back to the router's answer when nothing changes.
  testWidgets('the data switch holds the requested state until it settles', (
    tester,
  ) async {
    await tester.pumpWidget(
      _tab(
        const CellularRadioState(mode: 'auto', dataUp: false),
        overrides: [
          cellularRadioMutationsProvider.overrideWith(_InstantMutations.new),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Disconnected'), findsOneWidget);

    await tester.tap(find.byType(Switch).first);
    await tester.pump();
    expect(find.text('Connected'), findsOneWidget);

    // After the settle window the router is believed again.
    await tester.pump(const Duration(seconds: 13));
    await tester.pumpAndSettle();
    expect(find.text('Disconnected'), findsOneWidget);
  });

  testWidgets('the radio tab appears only on a router that has the backend', (
    tester,
  ) async {
    await tester.pumpWidget(_screen(supported: true));
    await tester.pumpAndSettle();

    expect(find.text('Radio'), findsOneWidget);
    expect(find.text('Messages'), findsOneWidget);
  });

  testWidgets('a router without the backend keeps three tabs', (tester) async {
    await tester.pumpWidget(_screen(supported: false));
    await tester.pumpAndSettle();

    expect(find.text('Radio'), findsNothing);
    expect(find.text('Messages'), findsOneWidget);
  });
}

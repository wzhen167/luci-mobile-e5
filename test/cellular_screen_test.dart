import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:luci_mobile/models/cellular.dart';
import 'package:luci_mobile/models/router_capabilities.dart';
import 'package:luci_mobile/screens/cellular_screen.dart';
import 'package:luci_mobile/services/cellular_service.dart';
import 'package:luci_mobile/services/sms_inbox.dart';
import 'package:luci_mobile/state/cellular_providers.dart';
import 'package:luci_mobile/state/cellular_radio_providers.dart';
import 'package:luci_mobile/state/feature_providers.dart';

/// A router with one connected QMI modem, as the section should render it.
const _snapshot = CellularSnapshot(
  interfaces: [
    CellularInterface(
      section: 'wwan',
      proto: 'qmi',
      device: '/dev/cdc-wdm0',
      apn: 'internet.telekom',
      up: true,
      uptimeSeconds: 3600,
      l3Device: 'wwan0',
      ipv4: ['10.20.30.40'],
      dns: ['10.20.30.1'],
      rxBytes: 1024 * 1024,
      txBytes: 2048,
    ),
  ],
  telemetry: CellularTelemetry(
    operatorName: 'Telekom.de',
    technology: 'lte',
    signalPercent: 62,
    imei: '861107037891430',
  ),
);

Widget _wrap(Widget child, {CellularSnapshot? snapshot}) => ProviderScope(
  overrides: [
    cellularProvider.overrideWith((ref) async => snapshot ?? _snapshot),
    // This harness has no router behind it, so the radio tab is pinned off:
    // its provider would otherwise reach for the real session, and mounting
    // the app state is what these tests are deliberately not doing.
    cellularRadioProvider.overrideWith((ref) async => null),
    featureProvider.overrideWith(
      (ref, feature) => const FeatureAvailability.available(),
    ),
    smsInboxProvider.overrideWith(
      (ref) async => const SmsInboxSnapshot(
        backend: SmsBackend.vendor,
        messages: [
          SmsMessage(
            index: 1,
            sender: '+4917012345',
            body: 'Your code is 1234',
          ),
        ],
      ),
    ),
  ],
  child: MaterialApp(home: child),
);

void main() {
  // The section is the only place this data is rendered, and a widget test is
  // what catches a tab that cannot lay out — analysis cannot see that.
  testWidgets('the overview shows the live state of the modem', (tester) async {
    await tester.pumpWidget(_wrap(const CellularScreen()));
    await tester.pumpAndSettle();

    // Twice: the card title is the APN, and the detail rows repeat it.
    expect(find.text('internet.telekom'), findsWidgets);
    expect(find.text('Connected'), findsOneWidget);
    // Operator, technology and signal on one line.
    expect(find.textContaining('Telekom.de'), findsOneWidget);
    expect(find.textContaining('62%'), findsOneWidget);
    expect(find.textContaining('10.20.30.40'), findsOneWidget);
  });

  testWidgets('the configuration tab offers the APN for editing', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(const CellularScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Configuration'));
    await tester.pumpAndSettle();

    expect(find.textContaining('APN internet.telekom'), findsOneWidget);

    await tester.tap(find.text('internet.telekom'));
    await tester.pumpAndSettle();

    expect(find.text('Edit APN'), findsOneWidget);
    expect(find.text('Access point name (APN)'), findsOneWidget);
  });

  testWidgets('the messages tab lists what the SIM holds', (tester) async {
    await tester.pumpWidget(_wrap(const CellularScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Messages'));
    await tester.pumpAndSettle();

    expect(find.text('+4917012345'), findsOneWidget);
    expect(find.text('Your code is 1234'), findsOneWidget);
  });

  // A router with no modem must say so, not render an empty tab set.
  testWidgets('no cellular interface is explained, not hidden', (tester) async {
    await tester.pumpWidget(
      _wrap(const CellularScreen(), snapshot: const CellularSnapshot()),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('no cellular interface'), findsOneWidget);
  });

  // Without ModemManager the interface still renders; the missing part is
  // named rather than shown as zero bars.
  testWidgets('missing telemetry is explained instead of faked', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const CellularScreen(),
        snapshot: const CellularSnapshot(
          interfaces: [
            CellularInterface(section: 'wwan', proto: 'qmi', up: true),
          ],
          telemetryUnavailable: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('modemmanager'), findsOneWidget);
  });
}

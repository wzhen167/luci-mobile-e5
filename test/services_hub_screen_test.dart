import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:luci_mobile/models/router_capabilities.dart';
import 'package:luci_mobile/models/service_status.dart';
import 'package:luci_mobile/screens/services_hub_screen.dart';
import 'package:luci_mobile/state/feature_providers.dart';
import 'package:luci_mobile/state/service_providers.dart';

const _services = [
  ServiceStatus(name: 'uhttpd', enabled: true, running: true),
  ServiceStatus(name: 'dnsmasq', enabled: true, running: true),
  ServiceStatus(name: 'dropped', enabled: false, running: false),
  // A one-shot boot script: no daemon, so no running state at all.
  ServiceStatus(name: 'boot', enabled: true, running: null),
];

Widget _wrap({
  FeatureAvailability gate = const FeatureAvailability.available(),
}) => ProviderScope(
  overrides: [
    servicesProvider.overrideWith((ref) async => _services),
    featureProvider.overrideWith((ref, feature) => gate),
  ],
  child: const MaterialApp(home: ServicesHubScreen()),
);

void main() {
  testWidgets('the daemon tab leads with live state', (tester) async {
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    // Two of four running, three of four starting at boot.
    expect(
      find.text('2 of 4 services running, 3 start at boot'),
      findsOneWidget,
    );
    expect(find.text('uhttpd'), findsOneWidget);
  });

  testWidgets('every service is listed with its state', (tester) async {
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    expect(find.text('uhttpd'), findsOneWidget);
    expect(find.text('dropped'), findsOneWidget);
    // A one-shot script reads as "starts at boot" with no running state
    // invented for it; only the stopped service says "Stopped".
    expect(find.textContaining('starts at boot'), findsWidgets);
    expect(find.textContaining('Stopped'), findsOneWidget);
  });

  // The add-ons live in their own tab, so the daemon list is not pushed off
  // the screen by four entries that are used far less often.
  testWidgets('the add-on tab holds the optional service packages', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Service add-ons'));
    await tester.pumpAndSettle();

    expect(find.text('SQM / QoS'), findsOneWidget);
    expect(find.text('Ad blocking'), findsOneWidget);
  });

  // An unavailable add-on stays visible with the package name: hiding it would
  // read as the app not supporting it at all.
  testWidgets('gated add-ons say which package is missing', (tester) async {
    await tester.pumpWidget(
      _wrap(
        gate: const FeatureAvailability.unavailable(
          UnavailableReason.missingPackage,
          requiredPackage: 'sqm-scripts',
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Service add-ons'));
    await tester.pumpAndSettle();

    expect(find.textContaining('sqm-scripts'), findsWidgets);
  });

  // Without rc.init the list is still worth showing, but the actions are not.
  testWidgets('a denied service gate disables the row menus', (tester) async {
    await tester.pumpWidget(
      _wrap(
        gate: const FeatureAvailability.unavailable(
          UnavailableReason.noPermission,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('uhttpd'), findsOneWidget);
    final menus = tester.widgetList<PopupMenuButton<String>>(
      find.byType(PopupMenuButton<String>),
    );
    expect(menus, isNotEmpty);
    expect(menus.every((m) => m.enabled == false), isTrue);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:luci_mobile/models/openclash.dart';
import 'package:luci_mobile/screens/openclash_screen.dart';
import 'package:luci_mobile/state/openclash_providers.dart';

/// Records what the screen asked for, without a router behind it.
class _FakeActions implements OpenClashActions {
  final List<String> controls = [];
  final List<({String group, String node})> switches = [];
  final List<String> modes = [];

  @override
  Future<bool> control(String action) async {
    controls.add(action);
    return true;
  }

  @override
  Future<void> selectNode(String group, String node) async {
    switches.add((group: group, node: node));
  }

  @override
  Future<void> setMode(String mode) async {
    modes.add(mode);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

const _config = OpenClashConfig(
  installed: true,
  apiPort: 9090,
  configPath: '/etc/openclash/config/liangxin.yaml',
  configuredMode: 'rule',
);

const _groups = [
  OpenClashGroup(
    name: '良心云',
    type: 'Selector',
    members: ['🇭🇰香港高速01|BGP|CMCU', '🇭🇰香港高速04|BGP|CMCU', 'DIRECT'],
    now: '🇭🇰香港高速04|BGP|CMCU',
  ),
  OpenClashGroup(
    name: '自动选择',
    type: 'URLTest',
    members: ['🇭🇰香港高速01|BGP|CMCU'],
    now: '🇭🇰香港高速01|BGP|CMCU',
  ),
];

Widget _wrap(OpenClashSnapshot snapshot, _FakeActions actions) =>
    ProviderScope(
      overrides: [
        openClashProvider.overrideWith((ref) async => snapshot),
        openClashActionsProvider.overrideWithValue(actions),
      ],
      child: const MaterialApp(home: OpenClashScreen()),
    );

void _bigScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('a running core shows its version, mode and groups', (
    tester,
  ) async {
    _bigScreen(tester);
    await tester.pumpWidget(
      _wrap(
        const OpenClashSnapshot(
          config: _config,
          running: true,
          enabled: true,
          version: 'alpha-gbc76c13',
          coreName: 'Mihomo',
          mode: 'rule',
          mixedPort: 7893,
          uploadTotal: 7850481,
          downloadTotal: 3477340069,
          activeConnections: 2,
          groups: _groups,
        ),
        _FakeActions(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Running'), findsOneWidget);
    expect(find.text('Mihomo alpha-gbc76c13'), findsOneWidget);
    expect(find.text('liangxin.yaml'), findsOneWidget);
    expect(find.text('Proxy groups'), findsOneWidget);
    expect(find.text('良心云'), findsOneWidget);
    expect(find.text('🇭🇰香港高速04|BGP|CMCU'), findsOneWidget);
    expect(find.text('2'), findsOneWidget, reason: 'active connections');
  });

  testWidgets('a stopped core offers Start and hides the live sections', (
    tester,
  ) async {
    _bigScreen(tester);
    await tester.pumpWidget(
      _wrap(
        const OpenClashSnapshot(config: _config, enabled: true),
        _FakeActions(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Stopped'), findsOneWidget);
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Proxy groups'), findsNothing);
    expect(find.text('Traffic'), findsNothing);
  });

  // Stopping the proxy core cuts the connection the user may be relying on,
  // so the button must reach the service with the exact init action.
  testWidgets('the primary button stops a running core', (tester) async {
    _bigScreen(tester);
    final actions = _FakeActions();
    await tester.pumpWidget(
      _wrap(
        const OpenClashSnapshot(
          config: _config,
          running: true,
          enabled: true,
          version: 'alpha',
        ),
        actions,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();

    expect(actions.controls, ['stop']);
  });

  testWidgets('picking a node reaches the controller with the group name', (
    tester,
  ) async {
    _bigScreen(tester);
    final actions = _FakeActions();
    await tester.pumpWidget(
      _wrap(
        const OpenClashSnapshot(
          config: _config,
          running: true,
          enabled: true,
          version: 'alpha',
          mode: 'rule',
          groups: _groups,
        ),
        actions,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('良心云'));
    await tester.pumpAndSettle();

    expect(find.text('Select a node'), findsOneWidget);

    await tester.tap(find.text('DIRECT'));
    await tester.pumpAndSettle();

    expect(actions.switches.single.group, '良心云');
    expect(actions.switches.single.node, 'DIRECT');
  });

  testWidgets('the mode selector sends the chosen mode', (tester) async {
    _bigScreen(tester);
    final actions = _FakeActions();
    await tester.pumpWidget(
      _wrap(
        const OpenClashSnapshot(
          config: _config,
          running: true,
          enabled: true,
          version: 'alpha',
          mode: 'rule',
          groups: _groups,
        ),
        actions,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Global'));
    await tester.pumpAndSettle();

    expect(actions.modes, ['global']);
  });

  testWidgets('an uninstalled router says so instead of showing controls', (
    tester,
  ) async {
    _bigScreen(tester);
    await tester.pumpWidget(
      _wrap(const OpenClashSnapshot(), _FakeActions()),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('OpenClash is not installed on this router.'),
      findsOneWidget,
    );
    expect(find.text('Start'), findsNothing);
  });

  // A running core whose dashboard refuses the password is still running: the
  // screen has to say what is wrong with the panel, not pretend the service is
  // down.
  testWidgets('a dashboard that cannot be read is explained', (tester) async {
    _bigScreen(tester);
    await tester.pumpWidget(
      _wrap(
        const OpenClashSnapshot(
          config: _config,
          running: true,
          enabled: true,
          apiError: 'unauthorized',
        ),
        _FakeActions(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Running'), findsOneWidget);
    expect(
      find.text('The dashboard did not answer: unauthorized'),
      findsOneWidget,
    );
    expect(find.text('Proxy groups'), findsNothing);
  });
}

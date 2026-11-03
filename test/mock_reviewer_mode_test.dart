import 'package:flutter_test/flutter_test.dart';

import 'package:luci_mobile/utils/uci_values.dart';
import 'package:luci_mobile/models/openclash.dart';
import 'package:luci_mobile/services/cellular_planner.dart';
import 'package:luci_mobile/services/cellular_service.dart';
import 'package:luci_mobile/services/client_config_planner.dart';
import 'package:luci_mobile/services/mock_api_service.dart';
import 'package:luci_mobile/services/sms_inbox.dart';
import 'package:luci_mobile/services/sms_tool.dart';
import 'package:luci_mobile/state/router_session.dart';

/// Reviewer mode is what App Store review sees. Every gap here ships as an
/// empty screen or a control that snaps back, so these are checked as
/// carefully as the real paths.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Map<String, dynamic>> uciValues(
    MockApiService api,
    String config,
  ) async {
    final raw = await api.uciGetAll('h', 't', false, config: config);
    return Map<String, dynamic>.from((raw as List)[1]['values'] as Map);
  }

  group('fixtures are params-aware', () {
    // The lookup used to key on object.method alone, so uci.get for *any*
    // config handed back the wireless one.
    test('uci.get serves the config that was asked for', () async {
      final api = MockApiService();

      final dhcp = await uciValues(api, 'dhcp');
      expect(dhcp.keys, contains('lan'));
      expect(
        uciSections(dhcp, 'host'),
        isNotEmpty,
        reason: 'dhcp fixture should contain static leases',
      );

      final firewall = await uciValues(api, 'firewall');
      expect(uciSections(firewall, 'zone'), isNotEmpty);
      expect(dhcp.keys, isNot(contains('radio0')));
    });

    // file.exec was mapped to the DHCP lease fixture, so every shell-out came
    // back as lease text.
    test(
      'file.exec does not return lease text for an unrelated command',
      () async {
        final api = MockApiService();
        final result = await api.call(
          'h',
          't',
          false,
          object: 'file',
          method: 'exec',
          params: {'command': '/sbin/logread'},
        );
        final data = (result as List)[1];
        final asText = data.toString();
        expect(asText, isNot(contains('192.168.1.100')));
      },
    );
  });

  group('station fixtures line up with the client list', () {
    // Previously the assoclist fixture used MACs that appeared in no DHCP
    // lease, so every client showed "no signal data".
    test('every associated station matches a real lease', () async {
      final api = MockApiService();

      final leaseResult = await api.call(
        'h',
        't',
        false,
        object: 'luci-rpc',
        method: 'getDHCPLeases',
      );
      final leases = ((leaseResult as List)[1]['dhcp_leases'] as List)
          .map((l) => (l['macaddr'] as String).toUpperCase())
          .toSet();
      expect(leases, isNotEmpty);

      var seen = 0;
      for (final device in ['wlan0', 'wlan1']) {
        final stations = await api.fetchStationDetails(
          'h',
          't',
          false,
          device: device,
        );
        expect(stations, isNotEmpty, reason: device);
        for (final mac in stations.keys) {
          expect(leases, contains(mac), reason: '$mac has no DHCP lease');
          seen++;
        }
      }
      expect(seen, greaterThan(10));
    });

    test('station rows carry the fields the detail page renders', () async {
      final api = MockApiService();
      final stations = await api.fetchStationDetails(
        'h',
        't',
        false,
        device: 'wlan1',
      );
      final s = stations.values.first;
      expect(s.signal, isNotNull);
      expect(s.noise, isNotNull);
      expect(s.snr, isNotNull);
      expect(s.rxRateKbps, isNotNull);
      expect(s.txBytes, isNotNull);
      expect(s.connectedSeconds, isNotNull);
      expect(s.qualityPercent, inInclusiveRange(0, 100));
    });

    test('host hints cover the leases', () async {
      final api = MockApiService();
      final hints = await api.fetchHostHints('h', 't', false);
      expect(hints, isNotEmpty);
      expect(hints.keys.first, matches(RegExp(r'^[0-9A-F:]{17}$')));
    });

    // Not every mock client is wireless, so the wired path is demoable too.
    test('some clients are wired', () async {
      final api = MockApiService();
      final wireless = <String>{};
      for (final macs in (await api.fetchAssociatedStations()).values) {
        wireless.addAll(macs.map((m) => m.toUpperCase()));
      }
      final leaseResult = await api.call(
        'h',
        't',
        false,
        object: 'luci-rpc',
        method: 'getDHCPLeases',
      );
      final leases = ((leaseResult as List)[1]['dhcp_leases'] as List)
          .map((l) => (l['macaddr'] as String).toUpperCase())
          .toSet();
      expect(leases.difference(wireless), isNotEmpty);
    });
  });

  group('writes round-trip through the overlay', () {
    // Without this a reviewer taps Block and watches the switch snap back.
    test('a set is visible on the next get', () async {
      final api = MockApiService();
      await uciValues(api, 'dhcp'); // seed

      await api.uciSet(
        'h',
        't',
        false,
        config: 'dhcp',
        section: 'lan',
        values: {'leasetime': '24h'},
      );

      final after = await uciValues(api, 'dhcp');
      expect((after['lan'] as Map)['leasetime'], '24h');
    });

    test('an add creates a readable section and reports its name', () async {
      final api = MockApiService();
      final result = await api.uciAdd(
        'h',
        't',
        false,
        config: 'dhcp',
        type: 'host',
        values: {'mac': 'AA:BB:CC:11:22:33', 'ip': '192.168.1.77'},
      );
      final section = (result as List)[1] as String;

      final after = await uciValues(api, 'dhcp');
      expect(after[section], isNotNull);
      final host = ClientConfigPlanner.findHost(after, 'aa:bb:cc:11:22:33');
      expect(host, isNotNull);
      expect(host!.ip, '192.168.1.77');
    });

    test('a delete removes the section', () async {
      final api = MockApiService();
      final before = await uciValues(api, 'firewall');
      final rule = ClientConfigPlanner.findBlockRule(
        before,
        'CC:DD:EE:98:76:54',
      );
      expect(rule, isNotNull, reason: 'fixture should ship one block rule');

      await api.uciDelete(
        'h',
        't',
        false,
        config: 'firewall',
        section: rule!.section,
      );

      final after = await uciValues(api, 'firewall');
      expect(
        ClientConfigPlanner.findBlockRule(after, 'CC:DD:EE:98:76:54'),
        isNull,
      );
    });

    test('revert restores the pre-write state', () async {
      final api = MockApiService();
      await uciValues(api, 'dhcp');
      await api.uciSet(
        'h',
        't',
        false,
        config: 'dhcp',
        section: 'lan',
        values: {'leasetime': '1h'},
      );
      await api.uciRevert('h', 't', false, config: 'dhcp');

      final after = await uciValues(api, 'dhcp');
      expect((after['lan'] as Map)['leasetime'], '12h');
    });

    test('staged changes are reported, then cleared by confirm', () async {
      final api = MockApiService();
      await uciValues(api, 'dhcp');
      await api.uciSet(
        'h',
        't',
        false,
        config: 'dhcp',
        section: 'lan',
        values: {'leasetime': '6h'},
      );

      expect(await api.uciChanges('h', 't', false), isNotEmpty);

      await api.uciApply('h', 't', false, rollback: true, timeoutSeconds: 90);
      expect(api.applyAwaitingConfirm, isTrue);

      await api.uciConfirm('h', 't', false);
      expect(api.applyAwaitingConfirm, isFalse);
      expect(await api.uciChanges('h', 't', false), isEmpty);
      // Confirm makes it the new baseline, so the value survives.
      final after = await uciValues(api, 'dhcp');
      expect((after['lan'] as Map)['leasetime'], '6h');
    });
  });

  // The Cellular section reads three sources; the mock answered none of them,
  // so reviewer mode showed the empty state for a modem feature it exists to
  // demonstrate. Each source is checked, because each one failing on its own
  // produces a different message on screen.
  group('cellular fixtures reach the modem screens', () {
    const session = RouterSession(
      routerId: 'r',
      ipAddress: 'h',
      sysauth: 't',
      useHttps: false,
      token: 1,
      reviewerMode: true,
    );

    test('the config lists both modems with their APN', () async {
      final network = await uciValues(MockApiService(), 'network');
      final modems = CellularPlanner.parse(network);

      expect(modems.map((m) => m.section), ['wwan', 'wwan2']);
      final primary = modems.first;
      expect(primary.apn, 'internet.telekom');
      expect(primary.pdpType, 'ipv4v6');
      expect(primary.hasPassword, isTrue);
      expect(primary.pinSet, isTrue);
      expect(primary.disabled, isFalse);
      // The backup SIM is configured but off: the screen has to render that
      // state, not only an active link.
      expect(modems.last.disabled, isTrue);
    });

    test('runtime state and radio telemetry are both present', () async {
      final snapshot = await CellularService(MockApiService()).read(session);

      expect(snapshot.isEmpty, isFalse);
      final primary = snapshot.interfaces.first;
      expect(primary.up, isTrue);
      expect(primary.l3Device, 'wwan0');
      expect(primary.ipv4, ['10.64.12.33']);
      expect(primary.rxBytes, greaterThan(0));

      // A silent ModemManager shows "install modemmanager" instead, so the
      // fixture has to answer it too.
      expect(snapshot.telemetryUnavailable, isFalse);
      expect(snapshot.telemetry?.operatorName, 'Telekom.de');
      expect(snapshot.telemetry?.signalPercent, 68);
    });

    test('sms-tool lists, sends and deletes', () async {
      final tool = SmsTool(MockApiService());
      const device = CellularSnapshot.defaultSmsDevice;

      final before = await tool.list(session, device);
      expect(before, hasLength(3));
      expect(before.first.unread, isTrue);
      // This body contains a semicolon; the column split must rejoin it
      // rather than truncate the message.
      expect(before.last.body, contains('bestaetigt; Details'));

      await tool.send(session, device, '+491700000001', 'Hallo');
      final sent = await tool.list(session, device);
      expect(sent, hasLength(4));
      expect(sent.last.sender, '+491700000001');
      expect(sent.last.body, 'Hallo');

      await tool.delete(session, device, sent.last.index);
      expect(await tool.list(session, device), hasLength(3));
    });

    test('an AT command answers the modem', () async {
      final answer = await SmsTool(
        MockApiService(),
      ).at(session, CellularSnapshot.defaultSmsDevice, 'AT+CSQ');
      expect(answer, contains('+CSQ: 24,99'));
    });

    // A field unit (E5 mobile router) answers none of the above: it has the
    // vendor objects instead, and reviewer mode has to look like that unit
    // rather than like the fixtures this app was first written against.
    test('the vendor SMS service is preferred over sms-tool', () async {
      final inbox = await SmsInbox(MockApiService()).read(session);

      expect(inbox.backend, SmsBackend.vendor);
      expect(inbox.messages, hasLength(3));
      expect(inbox.messages.first.sim, 'SIM1');
      expect(inbox.messages.first.id, isNotNull);
    });

    test('a vendor delete goes by id and sticks', () async {
      final api = MockApiService();
      final inbox = SmsInbox(api);
      final read = await inbox.read(session);

      await inbox.delete(
        session,
        backend: SmsBackend.vendor,
        message: read.messages.first,
      );

      final after = await inbox.read(session);
      expect(after.messages, hasLength(2));
      expect(
        after.messages.map((m) => m.id),
        isNot(contains(read.messages.first.id)),
      );
    });

    test('the quota card has data to render', () async {
      final snapshot = await CellularService(MockApiService()).read(session);

      expect(snapshot.quota, isNotNull);
      expect(snapshot.quota!.limitBytes, greaterThan(0));
      expect(snapshot.quota!.usedFraction, greaterThan(0));
      expect(snapshot.sims, hasLength(2));
      expect(snapshot.dataSim, 0);
      expect(snapshot.runtimeApn, isNotNull);
    });
  });

  // Settings → OpenClash has to open on a running service with a controller:
  // a fixture that is installed but stopped would only ever exercise the
  // "stopped" card, and the node picker would be unreachable in review.
  group('openclash fixtures reach the settings tile', () {
    test('the config is installed and names its controller', () async {
      final values = await uciValues(MockApiService(), 'openclash');
      final config = OpenClashConfig.fromUci(values);

      expect(config.installed, isTrue);
      expect(config.apiPort, 9090);
      expect(config.configName, 'liangxin.yaml');
      expect(config.configuredMode, 'rule');
      expect(config.secret, 'reviewer');
    });

    test('the service is listed as running and enabled', () async {
      final services = await MockApiService().rcList('h', 't', false);
      final openclash = services['openclash'];

      expect(openclash, isNotNull);
      expect(openclash!.running, isTrue);
      expect(openclash.enabled, isTrue);
    });

    test('the mock controller has groups to switch between', () async {
      final groups = OpenClashGroup.listFrom({
        'proxies': {
          'GLOBAL': {
            'all': ['DIRECT'],
            'type': 'Selector',
          },
          '良心云': {
            'type': 'Selector',
            'now': 'DIRECT',
            'all': ['DIRECT'],
          },
        },
      });

      expect(groups.map((g) => g.name), ['良心云']);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';

import 'package:luci_mobile/models/cellular.dart';
import 'package:luci_mobile/models/uci_change.dart';
import 'package:luci_mobile/services/cellular_planner.dart';

/// A `uci.get network` body, as rpcd returns it: `.type` plus options.
Map<String, dynamic> networkConfig(
  Map<String, Map<String, dynamic>> sections,
) => sections.map(
  (name, section) => MapEntry(name, {'.type': 'interface', ...section}),
);

void main() {
  group('parse', () {
    test('keeps cellular protocols and drops everything else', () {
      final parsed = CellularPlanner.parse(
        networkConfig({
          'lan': {'proto': 'static', 'device': 'br-lan'},
          'wan': {'proto': 'pppoe', 'device': 'eth0.2'},
          'wwan': {
            'proto': 'qmi',
            'device': '/dev/cdc-wdm0',
            'apn': 'internet',
          },
          'lte': {'proto': 'mbim', 'device': '/dev/cdc-wdm1'},
        }),
      );

      expect(parsed.map((i) => i.section), ['wwan', 'lte']);
      expect(parsed.first.proto, 'qmi');
      expect(parsed.first.apn, 'internet');
    });

    test('ppp is not cellular', () {
      // PPPoE is the ordinary DSL protocol; listing it would show every wired
      // WAN as a modem.
      final parsed = CellularPlanner.parse(
        networkConfig({
          'wan': {'proto': 'ppp', 'device': 'eth0'},
        }),
      );
      expect(parsed, isEmpty);
    });

    test('credentials are recorded as presence, never as values', () {
      final parsed = CellularPlanner.parse(
        networkConfig({
          'wwan': {'proto': 'qmi', 'password': 'secret', 'pincode': '1234'},
        }),
      );
      expect(parsed.single.hasPassword, isTrue);
      expect(parsed.single.pinSet, isTrue);
      // Nothing on the model carries the value itself.
      expect(parsed.single.toString(), isNot(contains('secret')));
      expect(parsed.single.toString(), isNot(contains('1234')));
    });

    test('a disabled interface is marked disabled, not down', () {
      final parsed = CellularPlanner.parse(
        networkConfig({
          'wwan': {'proto': 'qmi', 'disabled': '1'},
        }),
      );
      expect(parsed.single.disabled, isTrue);
      expect(parsed.single.idle, isFalse);
    });
  });

  group('mergeRuntime', () {
    final configured = CellularPlanner.parse(
      networkConfig({
        'wwan': {'proto': 'qmi', 'apn': 'internet'},
        'lte': {'proto': 'mbim'},
      }),
    );

    test('matches on the UCI section name', () {
      final merged = CellularPlanner.mergeRuntime(configured, {
        'interface': [
          {
            'interface': 'wwan',
            'up': true,
            'uptime': 90,
            'l3_device': 'wwan0',
            'ipv4-address': [
              {'address': '10.1.2.3', 'mask': 30},
            ],
            'dns-server': ['10.1.2.1'],
            'data': {'rx_bytes': 100, 'tx_bytes': 200},
          },
        ],
      });

      final wwan = merged.first;
      expect(wwan.up, isTrue);
      expect(wwan.uptimeSeconds, 90);
      expect(wwan.l3Device, 'wwan0');
      expect(wwan.ipv4, ['10.1.2.3']);
      expect(wwan.dns, ['10.1.2.1']);
      expect(wwan.rxBytes, 100);
      expect(wwan.txBytes, 200);
    });

    test('an interface the dump does not know is configured but down', () {
      final merged = CellularPlanner.mergeRuntime(configured, {
        'interface': <dynamic>[],
      });
      expect(merged.every((i) => !i.up), isTrue);
      expect(merged.every((i) => i.idle), isTrue);
    });

    test('a missing dump leaves the configuration intact', () {
      final merged = CellularPlanner.mergeRuntime(configured, null);
      expect(merged, configured);
    });
  });

  group('planApn', () {
    const existing = CellularInterface(
      section: 'wwan',
      proto: 'qmi',
      apn: 'old',
      username: 'user',
      hasPassword: true,
      pinSet: false,
      pdpType: 'ipv4',
      mtu: '1500',
    );

    test('writes only what changed', () {
      final ops = CellularPlanner.planApn(
        existing: existing,
        apn: 'new',
        username: 'user',
        pdpType: 'ipv4v6',
      );

      expect(ops, hasLength(1));
      final set = ops.single as UciSet;
      expect(set.config, 'network');
      expect(set.section, 'wwan');
      expect(set.values, {'apn': 'new', 'pdptype': 'ipv4v6'});
    });

    test('an unchanged value produces no operation at all', () {
      final ops = CellularPlanner.planApn(existing: existing, apn: 'old');
      expect(ops, isEmpty);
    });

    test('null means untouched, empty means removed', () {
      // APN cleared: there is a current value, so it is removed.
      final cleared = CellularPlanner.planApn(existing: existing, apn: '');
      expect(cleared.single, isA<UciRemove>());
      expect((cleared.single as UciRemove).option, 'apn');

      // MTU untouched by a call that only edits the APN.
      final untouched = CellularPlanner.planApn(existing: existing, apn: 'x');
      expect((untouched.single as UciSet).values.containsKey('mtu'), isFalse);
    });

    test('clearing a credential removes it, since it is never read back', () {
      final ops = CellularPlanner.planApn(existing: existing, password: '');
      expect(ops.single, isA<UciRemove>());
      expect((ops.single as UciRemove).option, 'password');
    });

    test('clearing a credential that is not set is a no-op', () {
      final ops = CellularPlanner.planApn(existing: existing, pin: '');
      expect(ops, isEmpty);
    });

    test('a new credential replaces the old one', () {
      final ops = CellularPlanner.planApn(existing: existing, password: 'new');
      expect((ops.single as UciSet).values, {'password': 'new'});
    });

    test('disabling writes the uci boolean', () {
      final ops = CellularPlanner.planApn(existing: existing, disabled: true);
      expect((ops.single as UciSet).values, {'disabled': '1'});
    });

    test('re-enabling an interface that is already enabled is a no-op', () {
      expect(
        CellularPlanner.planApn(existing: existing, disabled: false),
        isEmpty,
      );
    });
  });

  group('isValidApn', () {
    test('empty is legal — the carrier may derive it', () {
      expect(CellularPlanner.isValidApn(''), isTrue);
    });

    test('a plain APN is legal', () {
      expect(CellularPlanner.isValidApn('internet.telekom'), isTrue);
    });

    test('whitespace is refused', () {
      // netifd passes it to the modem verbatim and the modem fails with an
      // error that never mentions the space.
      expect(CellularPlanner.isValidApn('inter net'), isFalse);
      expect(CellularPlanner.isValidApn('internet '), isFalse);
    });
  });

  // Measured on an E5 mobile router (OpenWrt 25.12.5, Unisoc UMS9621): the
  // cellular WAN is `proto modemmanager` with `iptype` and `apn_auto`, not the
  // qmi/mbim `pdptype` + `apn` pair this app was first written against.
  group('the modemmanager/Unisoc dialect', () {
    Map<String, dynamic> unisoc() => networkConfig({
      'wan': {
        'proto': 'modemmanager',
        'device': 'unisoc-sipc',
        'iptype': 'ipv4v6',
        'metric': '10',
        'apn_auto': '1',
        'signalrate': '30',
      },
    });

    test('iptype is read as the PDP type and remembered as the option', () {
      final wan = CellularPlanner.parse(unisoc()).single;

      expect(wan.proto, 'modemmanager');
      expect(wan.device, 'unisoc-sipc');
      expect(wan.pdpType, 'ipv4v6');
      expect(wan.pdpOption, 'iptype');
      // No `apn` option: the carrier supplies one while `apn_auto` is on.
      expect(wan.apn, isNull);
      expect(wan.apnAuto, isTrue);
    });

    test('a section without either option reports no pdp option', () {
      final wan = CellularPlanner.parse(
        networkConfig({
          'wwan': {'proto': 'qmi', 'apn': 'internet'},
        }),
      ).single;

      expect(wan.pdpOption, isNull);
      expect(wan.apnAuto, isNull, reason: 'absent, not false');
    });

    test('a manual APN clears apn_auto and keeps iptype', () {
      final ops = CellularPlanner.planApn(
        existing: CellularPlanner.parse(unisoc()).single,
        apn: 'cmnet',
        pdpType: 'ipv6',
      );

      final set = ops.single as UciSet;
      expect(set.values, {
        'apn': 'cmnet',
        // Without this the interface keeps deriving its APN and ignores the
        // value above — a save that appears to work and changes nothing.
        'apn_auto': '0',
        'iptype': 'ipv6',
      });
      expect(
        set.values.containsKey('pdptype'),
        isFalse,
        reason: 'a second, ignored option would be written',
      );
    });

    test('clearing the APN turns automatic back on', () {
      final manual = CellularPlanner.parse(
        networkConfig({
          'wwan': {
            'proto': 'qmi',
            'apn': 'cmnet',
            'apn_auto': '0',
            'pdptype': 'ipv4',
          },
        }),
      ).single;

      final ops = CellularPlanner.planApn(existing: manual, apn: '');

      final set = ops.whereType<UciSet>().single;
      expect(set.values, {'apn_auto': '1'});
      expect(ops.whereType<UciRemove>().map((r) => r.option), ['apn']);
    });

    test('a qmi section still writes pdptype', () {
      final qmi = CellularPlanner.parse(
        networkConfig({
          'wwan': {'proto': 'qmi', 'apn': 'internet', 'pdptype': 'ipv4'},
        }),
      ).single;

      final ops = CellularPlanner.planApn(existing: qmi, pdpType: 'ipv4v6');
      expect((ops.single as UciSet).values, {'pdptype': 'ipv4v6'});
    });
  });
}

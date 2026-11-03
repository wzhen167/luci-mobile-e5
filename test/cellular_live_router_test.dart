import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:luci_mobile/models/cellular.dart';
import 'package:luci_mobile/services/cellular_service.dart';
import 'package:luci_mobile/services/interfaces/api_service_interface.dart';
import 'package:luci_mobile/state/router_session.dart';

/// What an E5 mobile router actually answers.
///
/// Every payload below was captured from a live OpenWrt 25.12.5 / Unisoc
/// UMS9621 box. They are written out verbatim because the point of these tests
/// is that the shapes are *not* the ones this app was first written against:
/// `data` is empty in the interface dump, the PDP option is `iptype`, the
/// telemetry says `5gnr`, and the accounting lives in a vendor object.
class _FakeApi implements IApiService {
  _FakeApi(this.answers);

  final Map<String, Object?> answers;
  final List<({String object, String method, Map<String, dynamic>? params})>
  calls = [];

  @override
  Future<dynamic> uciGetAll(
    String ipAddress,
    String sysauth,
    bool useHttps, {
    required String config,
    BuildContext? context,
  }) async {
    calls.add((object: 'uci', method: 'get', params: {'config': config}));
    return answers['uci:$config'];
  }

  @override
  Future<dynamic> call(
    String ipAddress,
    String sysauth,
    bool useHttps, {
    required String object,
    required String method,
    Map<String, dynamic>? params,
    BuildContext? context,
  }) async {
    calls.add((object: object, method: method, params: params));
    final answer = answers['$object.$method'];
    // An object the router does not have: ubus answers status 4.
    return answer ?? [4, 'Not found'];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

const _session = RouterSession(
  routerId: 'r',
  ipAddress: '192.168.9.1',
  sysauth: 'tok',
  useHttps: false,
  token: 1,
);

Map<String, Object?> _liveAnswers({Object? status}) => {
  'uci:network': [
    0,
    {
      'values': {
        'wan': {
          '.type': 'interface',
          '.name': 'wan',
          'proto': 'modemmanager',
          'device': 'unisoc-sipc',
          'iptype': 'ipv4v6',
          'metric': '10',
          'apn_auto': '1',
          'signalrate': '30',
        },
      },
    },
  ],
  'network.interface.dump': [
    0,
    {
      'interface': [
        {
          'interface': 'wan',
          'up': true,
          'uptime': 263,
          'l3_device': 'sipa_eth0',
          'device': 'unisoc-sipc',
          'proto': 'modemmanager',
          'ipv4-address': [
            {'address': '10.186.3.204', 'mask': 8},
          ],
          'ipv6-address': [],
          'dns-server': ['211.137.191.27', '218.201.96.131'],
          // Empty on this firmware — the traffic counters are elsewhere.
          'data': <String, dynamic>{},
        },
      ],
    },
  ],
  'modemmanager.info': [
    0,
    {
      'modem': [
        {
          'imsi': '460071198554359',
          'operator': '中国移动',
          'technology': '5gnr',
          'device': 'unisoc-sipc',
          'iccid': '898607A11526D0014359',
          'imei': '867306061428465',
          'signal': '87',
        },
      ],
    },
  ],
  // `ubus call e5status cells {"slot":"0"}` — verbatim apart from the
  // timestamp, which changes every second on the router.
  'e5status.cells': [
    0,
    {
      'info': null,
      'cell': {
        'ts': 1793718600,
        'card': 0,
        'cfun': 1,
        'reg': {'stat': 1, 'tac': '680619', 'cid': '04BCB001', 'act': 11},
        'reg5g': {'stat': 1, 'tac': '680619', 'cid': '284BCB001', 'act': 11},
        'operator': {'name': '中国移动', 'plmn': null, 'act': 11},
        'sig_src': 'nr',
        'sig': {
          'band': 28,
          'arfcn': 152890,
          'pci': 669,
          'rsrp': -82.8,
          'rsrq': -12.8,
          'sinr': 2.4,
          'bw_mhz': 30,
        },
      },
    },
  ],
  'e5status.status':
      status ??
      [
        0,
        {
          'info': {
            'wan': {'up': 1, 'apn': 'cmnet', 'ip4': '10.186.3.204'},
            'modem': {
              'data_sim': 0,
              'sims': [
                {'slot': 0, 'state': 'ready'},
                {'slot': 1, 'state': 'absent'},
              ],
            },
            'traffic': {
              'today': {'rx': 23786237343, 'tx': 2329884923},
              'month': {'rx': 72250911577, 'tx': 8166865793},
              'today_used': 26116122266,
              'cycle_used': 80417777370,
              'cycle_start': '2026-11-01',
              'cycle_end': '2026-12-01',
              'monthly_limit': 390000000000,
              'remaining': 309582222630,
              'over_limit': false,
            },
          },
        },
      ],
};

void main() {
  group('CellularService reads a live mobile router', () {
    late _FakeApi api;
    late CellularSnapshot snapshot;

    setUp(() async {
      api = _FakeApi(_liveAnswers());
      snapshot = await CellularService(api).read(_session);
    });

    test('the interface is matched to its runtime state by section name', () {
      final wan = snapshot.interfaces.single;
      expect(wan.section, 'wan');
      expect(wan.proto, 'modemmanager');
      expect(wan.up, isTrue);
      expect(wan.uptimeSeconds, 263);
      expect(wan.l3Device, 'sipa_eth0');
      expect(wan.ipv4, ['10.186.3.204']);
      expect(wan.dns, contains('211.137.191.27'));
      // Empty `data` on this firmware: unknown traffic, not zero traffic.
      expect(wan.rxBytes, isNull);
    });

    test('radio telemetry survives the vendor spelling of the technology', () {
      expect(snapshot.telemetryUnavailable, isFalse);
      expect(snapshot.telemetry?.operatorName, '中国移动');
      expect(snapshot.telemetry?.signalPercent, 87);
      expect(snapshot.telemetry?.technology, '5gnr');
      expect(snapshot.telemetry?.technologyLabel, '5G NR');
    });

    test('the quota comes from the vendor accounting, not the dump', () {
      final quota = snapshot.quota;
      expect(quota, isNotNull);
      expect(quota!.usedBytes, 80417777370);
      expect(quota.limitBytes, 390000000000);
      expect(quota.remainingBytes, 309582222630);
      expect(quota.todayBytes, 26116122266);
      expect(quota.cycleStart, '2026-11-01');
      expect(quota.cycleEnd, '2026-12-01');
      expect(quota.overLimit, isFalse);
      expect(quota.usedFraction, closeTo(0.2062, 0.001));
    });

    test('both SIM slots are reported, the empty one included', () {
      expect(snapshot.sims, hasLength(2));
      expect(snapshot.sims.first.present, isTrue);
      expect(snapshot.sims.last.state, 'absent');
      expect(snapshot.sims.last.present, isFalse);
      expect(snapshot.dataSim, 0);
    });

    test(
      'the carrier-supplied APN is available without being in the config',
      () {
        // The config has `apn_auto '1'` and no `apn`; showing "not set" there
        // would be a lie about a connection that is working.
        expect(snapshot.interfaces.single.apn, isNull);
        expect(snapshot.interfaces.single.apnAuto, isTrue);
        expect(snapshot.runtimeApn, 'cmnet');
      },
    );
  });

  test('a router without the vendor objects still renders the modem', () async {
    // `e5status` is a vendor object; everything it feeds must degrade to
    // "unknown" rather than failing the read.
    final api = _FakeApi({
      ..._liveAnswers(),
      'e5status.status': [4, 'Not found'],
    });
    final snapshot = await CellularService(api).read(_session);

    expect(snapshot.interfaces.single.up, isTrue);
    expect(snapshot.quota, isNull);
    expect(snapshot.sims, isEmpty);
    expect(snapshot.runtimeApn, isNull);
  });

  test('a dual-SIM router is read for the slot carrying data', () async {
    // The first answer names slot 1 as active; the numbers for slot 0 would be
    // the wrong card's usage, so the service asks again.
    var asked = <String>[];
    final api = _FakeApi({
      ..._liveAnswers(),
      'e5status.status': [
        0,
        {
          'info': {
            'modem': {
              'data_sim': 1,
              'sims': [
                {'slot': 0, 'state': 'ready'},
                {'slot': 1, 'state': 'ready'},
              ],
            },
          },
        },
      ],
    });
    await CellularService(api).read(_session);

    asked = [
      for (final call in api.calls)
        if (call.object == 'e5status') '${call.params?['slot']}',
    ];
    expect(asked, ['0', '1']);
  });

  group('CellularTelemetry.technologyLabel', () {
    test('maps the generations carriers advertise', () {
      String? label(String? raw) =>
          CellularTelemetry(technology: raw).technologyLabel;

      expect(label('5gnr'), '5G NR');
      expect(label('nr5g'), '5G NR');
      expect(label('lte'), '4G LTE');
      expect(label('umts'), '3G');
      expect(label('gsm'), '2G');
      expect(label(null), isNull);
    });

    test('an unknown technology shows as itself, uppercased', () {
      // A new generation should appear as itself rather than as a blank.
      expect(CellularTelemetry(technology: '6gtest').technologyLabel, '6GTEST');
    });
  });

  // On this firmware the `modemmanager` ubus object exists but its `info`
  // method is not in the ACL, so the call comes back as an error. The radio
  // facts live in the vendor object instead; without this fallback the
  // Overview claimed the package was missing while the router sat on a
  // perfectly good 5G cell.
  group('vendor cell telemetry when ModemManager refuses', () {
    late _FakeApi api;
    late CellularSnapshot snapshot;

    setUp(() async {
      final answers = _liveAnswers()..remove('modemmanager.info');
      api = _FakeApi(answers);
      snapshot = await CellularService(api).read(_session);
    });

    test('the error answer does not read as "nothing to report"', () {
      expect(snapshot.telemetryUnavailable, isFalse);
      expect(snapshot.telemetry, isNotNull);
    });

    test('operator, generation and measured signal come through', () {
      final telemetry = snapshot.telemetry!;
      expect(telemetry.operatorName, '中国移动');
      expect(telemetry.technologyLabel, '5G NR');
      // RSRP -82.8 dBm on the -140..-44 ladder.
      expect(telemetry.measuredDbm, -83);
      expect(telemetry.signalPercent, 60);
      expect(telemetry.band, 28);
      expect(telemetry.sinr, 2.4);
      expect(telemetry.hasMeasuredSignal, isTrue);
      // A measurement must not be presented as the derived figure.
      expect(telemetry.approximateDbm, -83);
    });

    test('the cells call names the slot carrying data', () {
      final asked = [
        for (final call in api.calls)
          if (call.object == 'e5status' && call.method == 'cells')
            call.params?['slot'],
      ];
      expect(asked, ['0']);
    });

    test('a modem that is not camped on a cell reports no telemetry', () {
      // `info: null` is what the object answers with the radio off.
      final empty = CellularTelemetry.fromE5Cell({'info': null});
      expect(empty, isNull);
    });
  });

  group('CellularTelemetry.fromE5Cell', () {
    test('maps 3GPP access-technology codes onto the labels the UI uses', () {
      String? tech(int act) {
        final telemetry = CellularTelemetry.fromE5Cell({
          'cell': {
            'operator': {'name': 'x', 'act': act},
            'sig': {'rsrp': -90},
          },
        });
        return telemetry?.technologyLabel;
      }

      expect(tech(11), '5G NR');
      expect(tech(12), '5G NSA');
      expect(tech(8), '4G LTE');
      expect(tech(3), '3G');
      expect(tech(1), '2G');
      // An unknown code is not guessed at.
      expect(tech(99), isNull);
    });

    test('bars follow the RSRP ladder, not the percentage one', () {
      int bars(int rsrp) => CellularTelemetry.fromE5Cell({
        'cell': {
          'operator': {'name': 'x'},
          'sig': {'rsrp': rsrp},
        },
      })!.bars;

      // -44 dBm is next to the mast, -140 dBm is no service at all.
      expect(bars(-44), 4);
      expect(bars(-90), 3);
      expect(bars(-120), 1);
      expect(bars(-140), 0);
    });

    test(
      'a quality percentage still works when no measurement is reported',
      () {
        final telemetry = CellularTelemetry(signalPercent: 60);
        expect(telemetry.hasMeasuredSignal, isFalse);
        // The old -113 + 2p ladder is unchanged for backends that report
        // quality only.
        expect(telemetry.approximateDbm, 7);
        expect(telemetry.bars, 3);
      },
    );
  });
}

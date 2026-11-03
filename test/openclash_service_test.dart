import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:luci_mobile/models/openclash.dart';
import 'package:luci_mobile/models/service_status.dart';
import 'package:luci_mobile/services/interfaces/api_service_interface.dart';
import 'package:luci_mobile/services/openclash_service.dart';
import 'package:luci_mobile/state/router_session.dart';

/// A ubus surface that answers `uci.get` and `rc.list` from maps.
class _FakeApi implements IApiService {
  _FakeApi({
    this.uci = const {},
    this.services = const {},
    this.rcListThrows = false,
  });

  final Map<String, Map<String, dynamic>> uci;
  final Map<String, ServiceStatus> services;
  final bool rcListThrows;

  @override
  Future<dynamic> uciGetAll(
    String ipAddress,
    String sysauth,
    bool useHttps, {
    required String config,
    BuildContext? context,
  }) async {
    final sections = uci[config];
    if (sections == null) return [4, 'Not found'];
    return [
      0,
      {'values': sections},
    ];
  }

  @override
  Future<Map<String, ServiceStatus>> rcList(
    String ipAddress,
    String sysauth,
    bool useHttps, {
    BuildContext? context,
  }) async {
    if (rcListThrows) throw Exception('rc.list denied');
    return services;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _FakeClash implements ClashApi {
  _FakeClash({
    this.responses = const {},
    this.failures = const {},
  });

  final Map<String, Map<String, dynamic>> responses;
  final Map<String, Object> failures;

  final List<String> requested = [];

  @override
  Future<Map<String, dynamic>> get(String path) async {
    requested.add(path);
    final failure = failures[path];
    if (failure != null) throw failure;
    final body = responses[path];
    if (body == null) throw const ClashUnreachableException('HTTP 404');
    return body;
  }

  @override
  Future<void> send(
    String method,
    String path,
    Map<String, dynamic> body,
  ) async {}
}

const _session = RouterSession(
  routerId: 'r',
  ipAddress: '192.168.9.1:80',
  sysauth: 'tok',
  useHttps: false,
  token: 1,
);

const Map<String, Map<String, dynamic>> _openClashConfig = {
  'config': {
    '.type': 'openclash',
    '.name': 'config',
    'enable': '1',
    'cn_port': '9090',
    'config_path': '/etc/openclash/config/liangxin.yaml',
    'dashboard_password': 'lan-secret-placeholder',
    'proxy_mode': 'rule',
  },
};

OpenClashService _service(
  _FakeApi api,
  _FakeClash clash, {
  List<({String host, int port, String? secret})>? seen,
}) => OpenClashService(
  api,
  clients: ({required host, required port, secret}) {
    seen?.add((host: host, port: port, secret: secret));
    return clash;
  },
);

void main() {
  group('OpenClashConfig.fromUci', () {
    test('reads the section the router actually has', () {
      final config = OpenClashConfig.fromUci(_openClashConfig);

      expect(config.installed, isTrue);
      expect(config.apiPort, 9090);
      expect(config.secret, 'lan-secret-placeholder');
      expect(config.configName, 'liangxin.yaml');
      expect(config.configuredMode, 'rule');
      expect(config.hasApi, isTrue);
    });

    test('a missing section reads as not installed', () {
      expect(OpenClashConfig.fromUci(const {}).installed, isFalse);
      expect(OpenClashConfig.fromUci(const {'lan': {}}).installed, isFalse);
    });

    test('a section with no controller port still counts as installed', () {
      final config = OpenClashConfig.fromUci({
        'config': {'.type': 'openclash', 'cn_port': '0'},
      });
      expect(config.installed, isTrue);
      expect(config.apiPort, OpenClashConfig.defaultApiPort);
    });
  });

  group('OpenClashGroup.listFrom', () {
    test('keeps the config order and drops the built-in GLOBAL group', () {
      final groups = OpenClashGroup.listFrom({
        'proxies': {
          'GLOBAL': {
            'type': 'Selector',
            'now': 'DIRECT',
            'all': ['DIRECT'],
          },
          '自动选择': {
            'type': 'URLTest',
            'now': '🇯🇵日本高速01',
            'all': ['🇯🇵日本高速01', '🇭🇰香港高速01'],
          },
          '良心云': {
            'type': 'Selector',
            'now': '🇭🇰香港高速01',
            'all': ['🇭🇰香港高速01', 'DIRECT'],
          },
          'DIRECT': {'type': 'Direct'},
        },
      });

      expect(groups.map((g) => g.name), ['自动选择', '良心云']);
      expect(groups.last.now, '🇭🇰香港高速01');
      expect(groups.last.isManual, isTrue);
      expect(groups.first.isManual, isFalse);
      expect(groups.first.members, ['🇯🇵日本高速01', '🇭🇰香港高速01']);
    });

    test('a payload without proxy groups reads as none', () {
      expect(OpenClashGroup.listFrom(null), isEmpty);
      expect(OpenClashGroup.listFrom(const {'proxies': {}}), isEmpty);
    });
  });

  group('OpenClashService.read', () {
    test('not installed is an answer, not a failure', () async {
      final snapshot = await _service(
        _FakeApi(),
        _FakeClash(),
      ).read(_session);

      expect(snapshot.installed, isFalse);
      expect(snapshot.running, isFalse);
      expect(snapshot.apiError, isNull);
    });

    test('a stopped service does not probe the controller', () async {
      final clash = _FakeClash();
      final snapshot = await _service(
        _FakeApi(
          uci: {'openclash': _openClashConfig},
          services: const {
            'openclash': ServiceStatus(
              name: 'openclash',
              enabled: true,
              running: false,
            ),
          },
        ),
        clash,
      ).read(_session);

      expect(snapshot.running, isFalse);
      expect(snapshot.enabled, isTrue);
      expect(clash.requested, isEmpty);
      expect(snapshot.apiError, isNull, reason: 'stopped is not an outage');
    });

    test('a running service reports the live core, not the config', () async {
      final seen = <({String host, int port, String? secret})>[];
      final snapshot = await _service(
        _FakeApi(
          uci: {'openclash': _openClashConfig},
          services: const {
            'openclash': ServiceStatus(
              name: 'openclash',
              enabled: true,
              running: true,
            ),
          },
        ),
        _FakeClash(
          responses: {
            '/version': {'meta': true, 'version': 'alpha-gbc76c13'},
            '/configs': {'mode': 'global', 'mixed-port': 7893},
            '/proxies': {
              'proxies': {
                '良心云': {
                  'type': 'Selector',
                  'now': '🇭🇰香港高速04',
                  'all': ['🇭🇰香港高速04'],
                },
              },
            },
            '/connections': {
              'uploadTotal': 7850481,
              'downloadTotal': 3477340069,
              'connections': [
                {'id': 'a'},
                {'id': 'b'},
              ],
            },
          },
        ),
        seen: seen,
      ).read(_session);

      expect(snapshot.installed, isTrue);
      expect(snapshot.running, isTrue);
      expect(snapshot.coreLabel, 'Mihomo alpha-gbc76c13');
      expect(snapshot.effectiveMode, 'global');
      expect(snapshot.mixedPort, 7893);
      expect(snapshot.uploadTotal, 7850481);
      expect(snapshot.downloadTotal, 3477340069);
      expect(snapshot.activeConnections, 2);
      expect(snapshot.groups.single.name, '良心云');

      // The host is stripped of the LuCI port and the UCI password is used as
      // the controller secret.
      expect(seen.single.host, '192.168.9.1');
      expect(seen.single.port, 9090);
      expect(seen.single.secret, 'lan-secret-placeholder');
    });

    test('the core running is enough when rc.list is refused', () async {
      final snapshot = await _service(
        _FakeApi(
          uci: {'openclash': _openClashConfig},
          rcListThrows: true,
        ),
        _FakeClash(
          responses: {
            '/version': {'meta': true, 'version': 'v1.19.0'},
          },
        ),
      ).read(_session);

      expect(snapshot.running, isTrue);
      expect(snapshot.coreName, 'Mihomo');
      expect(snapshot.apiError, isNull);
    });

    test('a rejected password is reported without hiding the service', () async {
      final snapshot = await _service(
        _FakeApi(
          uci: {'openclash': _openClashConfig},
          services: const {
            'openclash': ServiceStatus(
              name: 'openclash',
              enabled: true,
              running: true,
            ),
          },
        ),
        _FakeClash(failures: {'/version': const ClashAuthException()}),
      ).read(_session);

      expect(snapshot.running, isTrue);
      expect(snapshot.version, isNull);
      expect(snapshot.dashboardLive, isFalse);
      expect(snapshot.apiError, 'unauthorized');
    });

    test('one missing endpoint does not discard the rest', () async {
      final snapshot = await _service(
        _FakeApi(
          uci: {'openclash': _openClashConfig},
          services: const {
            'openclash': ServiceStatus(
              name: 'openclash',
              enabled: true,
              running: true,
            ),
          },
        ),
        _FakeClash(
          responses: {
            '/version': {'meta': true, 'version': 'alpha'},
            '/configs': {'mode': 'rule'},
            // /proxies is missing entirely.
            '/connections': {'uploadTotal': 1, 'downloadTotal': 2},
          },
        ),
      ).read(_session);

      expect(snapshot.groups, isEmpty);
      expect(snapshot.activeConnections, 0);
      expect(snapshot.downloadTotal, 2);
    });
  });

  group('clashHost', () {
    test('strips a LuCI port', () {
      expect(clashHost('192.168.9.1:80'), '192.168.9.1');
      expect(clashHost('192.168.9.1'), '192.168.9.1');
    });

    test('keeps an IPv6 literal intact', () {
      expect(clashHost('fd00::1'), 'fd00::1');
      expect(clashHost('[fd00::1]:80'), 'fd00::1');
    });
  });
}

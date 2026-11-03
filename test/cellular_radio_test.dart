import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:luci_mobile/models/cellular_radio.dart';
import 'package:luci_mobile/services/cellular_radio.dart';
import 'package:luci_mobile/services/interfaces/api_service_interface.dart';
import 'package:luci_mobile/state/router_session.dart';

const _session = RouterSession(
  routerId: 'e5',
  ipAddress: '192.168.9.1',
  sysauth: 'sid',
  useHttps: false,
  token: 1,
);

/// The `lock_get` answer measured on an E5 (OpenWrt 25.12, Unisoc UMS9621).
///
/// Kept verbatim because the interesting parts are the ones that do not agree
/// with each other: LTE is locked to b7 and b20, which the capability list
/// does not contain.
Map<String, dynamic> _lock() => {
  'ts': 1793721602,
  'mode': {'label': 'sa', 'work': '128', 'gran': '1', 'card': 0},
  'endc': '1',
  'lte': {
    'locked': '1,3,5,7,8,20,28,34,38,39,40,41',
    'raw': '0,482,2056,213,0',
  },
  'nr': {'locked': '28', 'raw': '512,0,0,0'},
  'cells': ['nr:152890,669'],
  'caps': {
    'lte': '1,3,5,8,34,38,39,40,41',
    'nr': '1,3,5,8,20,28,40,41,75,77,78,79,80,81,83,84',
  },
  'volte': {'enabled': true},
  'vonr': {'enabled': true},
  'cell': 'nr:152890,669',
  'auto_apply': 1,
};

Map<String, dynamic> _sim() => {
  'ok': true,
  'data_sim': 1,
  'saved_sim': 1,
  'data_up': false,
  'radio_enabled': [true, false],
};

Map<String, dynamic> _cells() => {
  'cell': {
    'sig_src': 'nr',
    'lte': {'band': 3, 'arfcn': 1650, 'pci': 101},
    'nr': {'band': 28, 'arfcn': 152890, 'pci': 669, 'rsrp': -86},
    'sig': {'band': 28, 'arfcn': 152890, 'pci': 669},
  },
};

class _FakeApi implements IApiService {
  _FakeApi(this.handler);

  final dynamic Function(
    String object,
    String method,
    Map<String, dynamic> params,
  )
  handler;

  final List<String> calls = [];
  final List<Map<String, dynamic>> params = [];

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
    calls.add('$object.$method');
    this.params.add(params ?? const {});
    return handler(object, method, params ?? const {});
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

CellularRadioService _service(_FakeApi api) =>
    CellularRadioService(api, wait: (_) async {});

void main() {
  group('the model', () {
    test('reads the modem state out of the vendor payload', () {
      final state = CellularRadioState.fromPayload(
        lock: _lock(),
        sim: _sim(),
        cells: _cells(),
      );

      expect(state.mode, 'sa');
      expect(state.lteLocked, [1, 3, 5, 7, 8, 20, 28, 34, 38, 39, 40, 41]);
      expect(state.nrLocked, [28]);
      expect(state.lockedCells, ['nr:152890,669']);
      expect(state.autoApply, isTrue);
      expect(state.dataUp, isFalse);
      expect(state.dataSim, 1);
      expect(state.radioEnabled, [true, false]);
    });

    test('offers locked bands the capability list omits', () {
      // b7 and b20 are locked but absent from `caps`. Offering only `caps`
      // would render them unchecked, and saving anything would drop them.
      final state = CellularRadioState.fromPayload(lock: _lock());

      expect(state.lteChoices, [1, 3, 5, 7, 8, 20, 28, 34, 38, 39, 40, 41]);
      expect(state.nrChoices, containsAll([1, 28, 41, 84]));
      expect(state.hasBandLock, isTrue);
      expect(state.hasCellLock, isTrue);
    });

    test('reads the serving cell from the block the signal came from', () {
      final state = CellularRadioState.fromPayload(
        lock: _lock(),
        cells: _cells(),
      );

      expect(state.serving?.rat, 'nr');
      expect(state.serving?.channel, 152890);
      expect(state.serving?.pci, 669);
      expect(state.serving?.lockValue, 'nr:152890,669');
    });

    test('an incomplete payload does not invent state', () {
      final state = CellularRadioState.fromPayload(
        lock: {
          'mode': {'label': 'unknown'},
        },
      );

      expect(state.mode, 'unknown');
      expect(state.hasBandLock, isFalse);
      expect(state.dataUp, isNull);
      expect(state.radioEnabled, isEmpty);
      expect(state.serving, isNull);
      // Absent means "the router did not say", which is not "off".
      expect(state.autoApply, isTrue);
    });
  });

  group('the service', () {
    test('returns null when the router has no lock service', () async {
      final api = _FakeApi((o, m, p) => [1, 'Access denied']);
      expect(await _service(api).read(_session), isNull);
    });

    test('asks for the slot the router says is carrying data', () async {
      final api = _FakeApi((object, method, params) {
        return switch ('$object.$method') {
          'mu300dash.lock_get' => [0, _lock()],
          'mu300dash.sim_get' => [0, _sim()],
          'e5status.cells' => [0, _cells()],
          _ => [1, 'unexpected'],
        };
      });

      final state = await _service(api).read(_session);

      expect(state!.serving?.pci, 669);
      expect(api.params.last['slot'], '1');
    });

    test('a plain read uses the cached modem state', () async {
      final api = _FakeApi((object, method, params) {
        return switch ('$object.$method') {
          'mu300dash.lock_get' => [0, _lock()],
          _ => [0, <String, dynamic>{}],
        };
      });

      await _service(api).read(_session);
      expect(api.params.first.containsKey('fresh'), isFalse);
    });

    test('a refresh asks the modem instead of the cache', () async {
      final api = _FakeApi((object, method, params) {
        return switch ('$object.$method') {
          'mu300dash.lock_get' => [0, _lock()],
          _ => [0, <String, dynamic>{}],
        };
      });

      await _service(api).read(_session, fresh: true);
      expect(api.params.first['fresh'], '1');
    });

    test('a band change is queued and followed to its result', () async {
      var polls = 0;
      final api = _FakeApi((object, method, params) {
        return switch ('$object.$method') {
          'mu300dash.lock_set' => [
            0,
            {'ok': 1, 'started': 1, 'id': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'},
          ],
          'mu300dash.lock_status' => [
            0,
            ++polls < 2 ? {'state': 'running'} : {'state': 'done', 'ok': 1},
          ],
          _ => [1, 'unexpected'],
        };
      });

      await _service(api).setBands(_session, rat: 'lte', bands: [1, 3, 5]);

      expect(api.calls, [
        'mu300dash.lock_set',
        'mu300dash.lock_status',
        'mu300dash.lock_status',
      ]);
      expect(api.params.first, {'kind': 'lte', 'val': '1,3,5'});
      expect(polls, 2);
    });

    test('a band change with no bands is refused before it is sent', () async {
      final api = _FakeApi((o, m, p) => [0, <String, dynamic>{}]);

      expect(
        () => _service(api).setBands(_session, rat: 'nr', bands: const []),
        throwsA(isA<CellularRadioException>()),
      );
      expect(api.calls, isEmpty);
    });

    test('the modem reason reaches the caller', () async {
      final api = _FakeApi((object, method, params) {
        return switch ('$object.$method') {
          'mu300dash.lock_set' => [
            0,
            {'ok': 1, 'started': 1, 'id': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'},
          ],
          'mu300dash.lock_status' => [
            0,
            {'state': 'error', 'ok': 0, 'error': 'Unsupported band requested'},
          ],
          _ => [1, 'unexpected'],
        };
      });

      await expectLater(
        _service(api).setBands(_session, rat: 'nr', bands: [78]),
        throwsA(
          isA<CellularRadioException>().having(
            (e) => e.message,
            'message',
            'Unsupported band requested',
          ),
        ),
      );
    });

    test('restoring the defaults sends the backend its own verb', () async {
      final api = _FakeApi((object, method, params) {
        return switch ('$object.$method') {
          'mu300dash.lock_set' => [
            0,
            {'ok': 1},
          ],
          _ => [1, 'unexpected'],
        };
      });

      await _service(api).restoreBands(_session);
      expect(api.params.single, {'kind': 'bands_default', 'val': ''});
    });

    test('locking the current cell is `auto`, not an empty value', () async {
      final api = _FakeApi((object, method, params) {
        return switch ('$object.$method') {
          'mu300dash.lock_set' => [
            0,
            {'ok': 1},
          ],
          _ => [1, 'unexpected'],
        };
      });

      await _service(api).setCellLock(_session, lock: true);
      expect(api.params.single['val'], 'auto');

      await _service(api).setCellLock(_session, lock: false);
      expect(api.params.last['val'], 'off');
    });

    test('the data switch drives the interface, not the radio', () async {
      final api = _FakeApi((object, method, params) {
        return switch ('$object.$method') {
          'mu300dash.act' => [
            0,
            {'ok': 1, 'op': 'data down'},
          ],
          _ => [1, 'unexpected'],
        };
      });

      await _service(api).setDataUp(_session, false);
      expect(api.params.single, {'op': 'data', 'arg': 'down'});
    });

    test('the RF switch names the slot and confirms', () async {
      final api = _FakeApi((object, method, params) {
        return switch ('$object.$method') {
          'mu300dash.sim_radio_set' => [
            0,
            {'ok': 1},
          ],
          _ => [1, 'unexpected'],
        };
      });

      await _service(api).setRadioEnabled(_session, slot: 1, enabled: false);
      expect(api.params.single, {
        'slot': '1',
        'enabled': false,
        'confirm': true,
      });
    });

    test('a refused radio change is an error, not a silent no-op', () async {
      final api = _FakeApi((object, method, params) {
        return switch ('$object.$method') {
          'mu300dash.sim_radio_set' => [
            0,
            {'ok': 0, 'error': 'This SIM radio is disabled by the user'},
          ],
          _ => [1, 'unexpected'],
        };
      });

      await expectLater(
        _service(api).setRadioEnabled(_session, slot: 0, enabled: true),
        throwsA(isA<CellularRadioException>()),
      );
    });
  });
}

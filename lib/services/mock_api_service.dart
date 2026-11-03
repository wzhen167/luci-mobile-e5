import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:luci_mobile/services/interfaces/api_service_interface.dart';
import 'package:luci_mobile/config/app_config.dart';
import 'package:luci_mobile/models/cellular.dart';
import 'package:luci_mobile/models/service_status.dart';
import 'package:luci_mobile/models/station_info.dart';
import 'package:luci_mobile/services/sms_tool.dart';

class MockApiService implements IApiService {
  static final Random _random = Random();
  static int _baseUptime = 86400; // Base uptime of 1 day
  static int _baseRxBytes = 1234567890;
  static int _baseTxBytes = 987654321;
  static int _baseRxPackets = 12345;
  static int _baseTxPackets = 9876;
  // Scan cancellation token — incremented by cancelScan().
  int _scanToken = 0;

  // Staged-but-unapplied UCI changes, config -> rows of
  // [op, section, option?, value?]. Mutated by uciSet/uciAdd/uciDelete and
  // drained by uciApply/uciCommit/uciRevert, so that the unsaved-changes
  // affordance and the apply flow are exercisable in reviewer mode.
  final Map<String, List<List<String>>> _stagedChanges = {};

  // Set between uciApply(rollback: true) and uciConfirm.
  bool _applyAwaitingConfirm = false;

  /// Whether a rollback-protected apply is still waiting for a confirm.
  @visibleForTesting
  bool get applyAwaitingConfirm => _applyAwaitingConfirm;

  int _mockSectionCounter = 0;

  void _stage(String config, List<String> row) {
    _stagedChanges.putIfAbsent(config, () => <List<String>>[]).add(row);
  }

  // An in-memory UCI store: config -> section -> {option: value}. Seeded
  // lazily from the fixtures, then mutated by uciSet/uciAdd/uciDelete and read
  // back by uci.get. Without this a reviewer taps a toggle and watches it snap
  // straight back, because every write would be forgotten.
  final Map<String, Map<String, Map<String, dynamic>>> _uciOverlay = {};

  // Pre-write snapshots so uci.revert can restore.
  final Map<String, Map<String, Map<String, dynamic>>> _uciSnapshots = {};

  static Map<String, Map<String, dynamic>> _deepCopyConfig(
    Map<String, Map<String, dynamic>> src,
  ) => {
    for (final entry in src.entries)
      entry.key: Map<String, dynamic>.from(entry.value),
  };

  /// Loads [config] into the overlay on first touch, from its fixture.
  Future<Map<String, Map<String, dynamic>>?> _loadUciConfig(
    String config,
  ) async {
    final existing = _uciOverlay[config];
    if (existing != null) return existing;

    final file = _getMockDataFile('uci', 'get', {'config': config});
    if (file == null) return null;
    try {
      final raw = jsonDecode(
        await rootBundle.loadString('${AppConfig.mockDataPath}$file'),
      );
      final values = raw is Map ? raw['values'] : null;
      final sections = <String, Map<String, dynamic>>{};
      if (values is Map) {
        for (final entry in values.entries) {
          if (entry.value is Map) {
            sections[entry.key.toString()] = Map<String, dynamic>.from(
              entry.value as Map,
            );
          }
        }
      }
      _uciOverlay[config] = sections;
      return sections;
    } catch (e) {
      debugPrint('MockApiService: failed to seed uci overlay for $config: $e');
      return null;
    }
  }

  /// Captures [config] before its first staged write so revert can undo it.
  void _snapshotUci(String config) {
    final current = _uciOverlay[config];
    if (current == null) return;
    _uciSnapshots.putIfAbsent(config, () => _deepCopyConfig(current));
  }

  void _restoreUci(String config) {
    final snap = _uciSnapshots.remove(config);
    if (snap != null) _uciOverlay[config] = snap;
  }

  /// Serves `uci.get` out of the overlay, or null when this is not a
  /// config-scoped uci.get.
  Future<dynamic> _uciGetFromOverlay(
    String object,
    String method,
    Map<String, dynamic>? params,
  ) async {
    if (object != 'uci' || method != 'get') return null;
    final config = params?['config']?.toString();
    if (config == null) return null;
    final sections = await _loadUciConfig(config);
    if (sections == null) return null;
    return [
      0,
      {
        'values': {
          for (final entry in sections.entries)
            entry.key: Map<String, dynamic>.from(entry.value),
        },
      },
    ];
  }

  static int _baseLanRxBytes = 2345678901;
  static int _baseLanTxBytes = 1876543210;
  static int _baseLanRxPackets = 23456;
  static int _baseLanTxPackets = 18765;
  @override
  Future<String> login(
    String ipAddress,
    String username,
    String password,
    bool useHttps, {
    BuildContext? context,
  }) async {
    // Simulate a short delay for realism
    await Future.delayed(const Duration(milliseconds: 500));

    // Always return a mock sysauth token
    return 'mock_sysauth_token_12345';
  }

  /// Answers `file.exec` for nlbwmon's accounting helper, so the traffic
  /// screen has real-shaped rows in reviewer mode instead of an empty table.
  dynamic _mockNlbwmon(Map<String, dynamic>? params) {
    final args = params?['params'];
    final list = args is List
        ? [for (final a in args) a.toString()]
        : <String>[];
    if (list.isEmpty) return null;
    if (list.first == 'periods') {
      return [
        0,
        {'code': 0, 'stdout': '{ "periods": [ "2026-09-01" ] }'},
      ];
    }
    if (list.first != 'download') return null;
    return [
      0,
      {
        'code': 0,
        'stdout':
            '{"columns":["mac","ip","conns","rx_bytes","rx_pkts","tx_bytes",'
            '"tx_pkts"],"data":['
            '["a4:83:e7:2b:11:04","192.168.1.115",412,8402334721,6120044,'
            '412883912,2904113],'
            '["3c:22:fb:91:aa:17","192.168.1.132",188,2140998233,1704221,'
            '98221044,812004],'
            '["dc:a6:32:7f:0c:52","192.168.1.148",76,318442901,264118,'
            '44219883,318442]]}',
      },
    ];
  }

  /// The one `file.exec` hook: every shell-out reviewer mode has to fake.
  ///
  /// Split from the call sites so `call` and `callSimple` cannot drift — they
  /// are two copies of the same body, and a mock that answers differently
  /// depending on which entry point a screen happens to use is a bug that
  /// only shows up in the demo.
  dynamic _mockFileExec(Map<String, dynamic>? params) {
    final command = params?['command']?.toString() ?? '';
    if (command.contains('nlbwmon-action')) return _mockNlbwmon(params);
    if (command == SmsTool.binary) return _mockSmsTool(params);
    return null;
  }

  /// The vendor objects an E5-class mobile router answers.
  ///
  /// These are what the Cellular section actually reads in the field: the
  /// standard `network.interface dump` has no traffic counters and no APN on
  /// this firmware, and OpenWrt ships no SMS service at all. Modelling them
  /// here is the difference between a demo that shows the feature and one that
  /// shows an empty screen.
  dynamic _mockVendor(
    String object,
    String method,
    Map<String, dynamic>? params,
  ) {
    if (object == 'e5status' && method == 'status') {
      return [
        0,
        {
          'info': {
            'wan': {'up': 1, 'proto': 'modemmanager', 'apn': 'cmnet'},
            'modem': {
              'data_sim': 0,
              'sims': [
                {'slot': 0, 'state': 'ready'},
                {'slot': 1, 'state': 'absent'},
              ],
            },
            'traffic': {
              'today_used': 26116122266,
              'cycle_used': 80417777370,
              'cycle_start': '2026-11-01',
              'cycle_end': '2026-12-01',
              'monthly_limit': 390000000000,
              'remaining': 309582222630,
              'over_limit': false,
              'slot': 0,
            },
          },
        },
      ];
    }

    if (object == 'e5status' && method == 'cells') {
      // What "lock to the current cell" reads before it writes anything.
      return [
        0,
        {
          'cell': {
            'sig_src': 'nr',
            'lte': null,
            'nr': {'band': 28, 'arfcn': 152890, 'pci': 669, 'rsrp': -86},
            'sig': {'band': 28, 'arfcn': 152890, 'pci': 669, 'rsrp': -86},
          },
        },
      ];
    }

    if (object == 'mu300dash') {
      return _mockVendorLock(method, params);
    }

    if (object != 'e5-sms') return null;
    switch (method) {
      case 'list':
        return [
          0,
          {
            'messages': [for (final m in _mockMessages) _smsVendorRow(m)],
          },
        ];
      case 'sim':
        return [
          0,
          {'card': 0, 'name': 'SIM1', 'operator': '中国移动', 'state': 'connected'},
        ];
      case 'send':
        final number = params?['number']?.toString() ?? '';
        final text = params?['text']?.toString() ?? '';
        if (number.isEmpty || text.isEmpty) return null;
        final next = _nextSmsIndex();
        _mockMessages.add(
          SmsMessage(
            index: next,
            id: '${_smsVendorIdBase + next}',
            card: 0,
            sim: 'SIM1',
            sender: number,
            timestamp: _smsTimestamp(),
            body: text,
          ),
        );
        return [0, <String, dynamic>{}];
      case 'delete':
        final id = params?['id'];
        _mockMessages.removeWhere(
          (m) => m.id == '$id' || _smsVendorIdBase + m.index == id,
        );
        return [0, <String, dynamic>{}];
    }
    return null;
  }

  /// The vendor's `mu300dash` object: network lock, data and RF switches.
  ///
  /// Answers in the same shapes the real backend does, jobs included — the
  /// lock writes are queued and polled there, and a mock that completed
  /// inline would let a polling bug through unnoticed.
  dynamic _mockVendorLock(String method, Map<String, dynamic>? params) {
    switch (method) {
      case 'lock_get':
        return [0, _mockLock];
      case 'sim_get':
        return [
          0,
          {
            'ok': true,
            'data_sim': 0,
            'saved_sim': 0,
            'data_up': _mockDataUp,
            'radio_enabled': [..._mockRadioEnabled],
          },
        ];
      case 'lock_set':
        final kind = params?['kind']?.toString() ?? '';
        _applyMockLock(kind, params?['val']?.toString() ?? '');
        return [
          0,
          {
            'ok': 1,
            'started': 1,
            'id': 'mocksettingjob000000000000000000',
            'op': kind,
          },
        ];
      case 'lock_status':
        return [
          0,
          {'state': 'done', 'ok': 1, 'id': params?['id']},
        ];
      case 'sim_radio_set':
        final slot = int.tryParse(params?['slot']?.toString() ?? '0') ?? 0;
        final enabled = params?['enabled'] == true;
        if (slot >= 0 && slot < _mockRadioEnabled.length) {
          _mockRadioEnabled[slot] = enabled;
        }
        return [
          0,
          {'ok': 1, 'slot': '$slot', 'enabled': enabled},
        ];
      case 'act':
        final arg = params?['arg']?.toString() ?? '';
        if (params?['op'] == 'data') _mockDataUp = arg == 'up';
        return [
          0,
          {'ok': 1, 'op': '${params?['op']} $arg'},
        ];
    }
    return null;
  }

  void _applyMockLock(String kind, String value) {
    if (kind == 'mode') {
      (_mockLock['mode'] as Map)['label'] = value;
    } else if (kind == 'lte' || kind == 'nr') {
      (_mockLock[kind] as Map)['locked'] = value;
    } else if (kind == 'bands_default') {
      (_mockLock['lte'] as Map)['locked'] = (_mockLock['caps'] as Map)['lte'];
      (_mockLock['nr'] as Map)['locked'] = '';
    } else if (kind == 'cell') {
      final cells = _mockLock['cells'] as List;
      cells.clear();
      if (value != 'off') {
        cells.add('nr:152890,669');
      }
      _mockLock['cell'] = cells.isEmpty ? '' : cells.first;
    } else if (kind == 'auto_apply') {
      _mockLock['auto_apply'] = value == 'on' ? 1 : 0;
    }
  }

  /// The first id the vendor counter hands out in this mock.
  static const int _smsVendorIdBase = 1000000000;

  int _nextSmsIndex() => _mockMessages.isEmpty
      ? 1
      : _mockMessages.map((m) => m.index).reduce(max) + 1;

  /// A message in the vendor's shape: `id` is the address, `card` the slot.
  static Map<String, dynamic> _smsVendorRow(SmsMessage message) => {
    'id': int.tryParse(message.id ?? '') ?? _smsVendorIdBase + message.index,
    'card': message.card ?? 0,
    'sim': message.sim ?? 'SIM1',
    'number': message.sender ?? '',
    'text': message.body,
    'time': message.timestamp ?? '',
    'state': 'received',
    'direction': 'in',
    'unread': message.unread,
  };

  /// Answers `sms-tool` for the Cellular section's Messages tab.
  ///
  /// Stateful on purpose: a reviewer sends a message and expects it in the
  /// list, deletes one and expects it gone. Same reason the UCI overlay
  /// exists — a control that snaps back reads as broken, not as a mock.
  dynamic _mockSmsTool(Map<String, dynamic>? params) {
    final args = params?['params'];
    final list = args is List
        ? [for (final a in args) a.toString()]
        : <String>[];
    // [device, subcommand, …args]; a shorter call is not one this can answer.
    if (list.length < 2) return null;

    switch (list[1]) {
      case 'list':
        return _execOk([for (final m in _mockMessages) _smsRow(m)].join('\n'));

      case 'send':
        if (list.length < 4) {
          return _execOk('', code: 2, stderr: 'sms-tool: missing argument');
        }
        final next = _nextSmsIndex();
        _mockMessages.add(
          SmsMessage(
            index: next,
            id: '${_smsVendorIdBase + next}',
            sender: list[2],
            timestamp: _smsTimestamp(),
            body: list.sublist(3).join(' '),
          ),
        );
        return _execOk('OK');

      case 'delete':
        if (list.length < 3) {
          return _execOk('', code: 2, stderr: 'sms-tool: missing argument');
        }
        _mockMessages.removeWhere((m) => m.index.toString() == list[2]);
        return _execOk('OK');

      case 'at':
        return _execOk(_mockAtAnswer(list.length > 2 ? list[2] : ''));
    }
    return null;
  }

  /// The modem's storage, mutated by send/delete above.
  ///
  /// One row carries a semicolon inside the body: the shell-out path ships
  /// text verbatim, and the parser has to rejoin those columns rather than
  /// truncate the message. Timestamps are RFC 3339 because that is what the
  /// vendor backend reports; `sms-tool` passes whatever its firmware prints,
  /// so the model keeps the string it was given.
  /// The vendor network-lock backend, mutated in place so a change made in
  /// reviewer mode is visible on the next read.
  final Map<String, dynamic> _mockLock = {
    'mode': {'label': '5g4g', 'work': '131', 'gran': '1'},
    'lte': {'locked': '1,3,5,8'},
    'nr': {'locked': '28'},
    'cells': <String>[],
    'caps': {'lte': '1,3,5,8,34,38,39,40,41', 'nr': '1,28,41,78'},
    'volte': {'enabled': true},
    'vonr': {'enabled': true},
    'cell': '',
    'auto_apply': 1,
  };
  bool _mockDataUp = true;
  final List<bool> _mockRadioEnabled = [true, false];

  final List<SmsMessage> _mockMessages = [
    const SmsMessage(
      index: 1,
      id: '1000000017',
      sim: 'SIM1',
      card: 0,
      sender: '+491701234567',
      timestamp: '2026-11-02T09:14:22+08:00',
      unread: true,
      body: 'Ihr Einmalcode lautet 481920. Er ist 10 Minuten gueltig.',
    ),
    const SmsMessage(
      index: 2,
      id: '1000000016',
      sim: 'SIM1',
      card: 0,
      sender: 'Telekom',
      timestamp: '2026-11-01T18:02:41+08:00',
      body: 'Ihr Datenvolumen ist zu 80% verbraucht. Restvolumen: 3,2 GB.',
    ),
    const SmsMessage(
      index: 3,
      id: '1000000015',
      sim: 'SIM1',
      card: 0,
      sender: '+493012345678',
      timestamp: '2026-10-30T11:47:05+08:00',
      body: 'Termin bestaetigt; Details folgen per E-Mail.',
    ),
  ];

  static String _smsRow(SmsMessage message) => [
    '${message.index}',
    message.sender ?? '',
    message.timestamp ?? '',
    message.unread ? 'REC UNREAD' : 'REC READ',
    message.body,
  ].join(';');

  /// A timestamp in the RFC 3339 shape the vendor backend reports.
  static String _smsTimestamp() {
    String two(int v) => v.toString().padLeft(2, '0');
    final now = DateTime.now();
    return '${now.year}-${two(now.month)}-${two(now.day)}T'
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)}+08:00';
  }

  /// Answers the AT commands the app actually sends; anything else gets a
  /// bare `OK`, which is what a module does for a command it understands.
  static String _mockAtAnswer(String command) {
    final upper = command.toUpperCase();
    if (upper.startsWith('AT+CSQ')) return '+CSQ: 24,99\r\n\r\nOK';
    if (upper.startsWith('AT+COPS')) {
      return '+COPS: 0,0,"Telekom.de",7\r\n\r\nOK';
    }
    if (upper.startsWith('AT+CREG') || upper.startsWith('AT+CEREG')) {
      return '+CREG: 0,1\r\n\r\nOK';
    }
    if (upper.startsWith('AT+CGSN')) return '861107037891430\r\n\r\nOK';
    return '\r\nOK';
  }

  /// The `file.exec` envelope rpcd returns.
  static List<Object> _execOk(
    String stdout, {
    int code = 0,
    String stderr = '',
  }) => [
    0,
    {'code': code, 'stdout': stdout, 'stderr': stderr},
  ];

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
    // Simulate a short delay for realism
    await Future.delayed(const Duration(milliseconds: 200));

    final endpointKey = '$object.$method';

    try {
      // uci.get must reflect writes made this session, so it is served from
      // the overlay rather than straight off the fixture.
      final overlaid = await _uciGetFromOverlay(object, method, params);
      if (overlaid != null) return overlaid;

      final vendor = _mockVendor(object, method, params);
      if (vendor != null) return vendor;

      final exec = object == 'file' && method == 'exec'
          ? _mockFileExec(params)
          : null;
      if (exec != null) return exec;

      // Return appropriate mock data based on object and method
      final mockDataFile = _getMockDataFile(object, method, params);

      if (mockDataFile != null) {
        try {
          final jsonString = await rootBundle.loadString(
            '${AppConfig.mockDataPath}$mockDataFile',
          );
          final jsonData = jsonDecode(jsonString);
          return [0, _formatMockData(endpointKey, jsonData)];
        } catch (e) {
          // Log file loading error and fall back to default data
          debugPrint(
            'MockApiService: Failed to load mock data file "$mockDataFile" for endpoint "$endpointKey": $e',
          );
          return _getDefaultMockData(object, method);
        }
      }

      // No mock file mapped, use default data
      final defaultData = _getDefaultMockData(object, method);
      if (defaultData[1] is Map && (defaultData[1] as Map).isEmpty) {
        debugPrint(
          'MockApiService: No mock data available for endpoint "$endpointKey", returning empty response',
        );
      }
      return defaultData;
    } catch (e) {
      // Catch-all error handler
      debugPrint(
        'MockApiService: Unexpected error for endpoint "$endpointKey": $e',
      );
      return [1, 'Mock service error: $e']; // Return error response
    }
  }

  // Simplified call method for reviewer mode
  @override
  Future<dynamic> callSimple(
    String object,
    String method,
    Map<String, dynamic> params,
  ) async {
    // Simulate a short delay for realism
    await Future.delayed(const Duration(milliseconds: 200));

    final endpointKey = '$object.$method';

    try {
      // uci.get must reflect writes made this session, so it is served from
      // the overlay rather than straight off the fixture.
      final overlaid = await _uciGetFromOverlay(object, method, params);
      if (overlaid != null) return overlaid;

      final vendor = _mockVendor(object, method, params);
      if (vendor != null) return vendor;

      final exec = object == 'file' && method == 'exec'
          ? _mockFileExec(params)
          : null;
      if (exec != null) return exec;

      // Return appropriate mock data based on object and method
      final mockDataFile = _getMockDataFile(object, method, params);

      if (mockDataFile != null) {
        try {
          final jsonString = await rootBundle.loadString(
            '${AppConfig.mockDataPath}$mockDataFile',
          );
          final jsonData = jsonDecode(jsonString);
          return [0, _formatMockData(endpointKey, jsonData)];
        } catch (e) {
          // Log file loading error and fall back to default data
          debugPrint(
            'MockApiService: Failed to load mock data file "$mockDataFile" for endpoint "$endpointKey": $e',
          );
          return _getDefaultMockData(object, method);
        }
      }

      // No mock file mapped, use default data
      final defaultData = _getDefaultMockData(object, method);
      if (defaultData[1] is Map && (defaultData[1] as Map).isEmpty) {
        debugPrint(
          'MockApiService: No mock data available for endpoint "$endpointKey", returning empty response',
        );
      }
      return defaultData;
    } catch (e) {
      // Catch-all error handler
      debugPrint(
        'MockApiService: Unexpected error for endpoint "$endpointKey": $e',
      );
      return [1, 'Mock service error: $e']; // Return error response
    }
  }

  @override
  Future<bool> reboot(
    String ipAddress,
    String sysauth,
    bool useHttps, {
    BuildContext? context,
  }) async {
    // Simulate a short delay for realism
    await Future.delayed(const Duration(seconds: 1));
    // Mock reboot always succeeds
    return true;
  }

  @override
  Future<Map<String, Set<String>>> fetchAssociatedStations() async {
    // Simulate a short delay for realism
    await Future.delayed(const Duration(milliseconds: 300));

    try {
      final jsonString = await rootBundle.loadString(
        '${AppConfig.mockDataPath}associated_stations.json',
      );
      final jsonData = jsonDecode(jsonString);

      final result = <String, Set<String>>{};
      if (jsonData is Map<String, dynamic>) {
        jsonData.forEach((interface, stations) {
          if (stations is List) {
            result[interface] = stations.map((s) => s.toString()).toSet();
          }
        });
      }
      return result;
    } catch (e) {
      // Log error and return comprehensive default mock data
      // Make sure these MAC addresses match some of the DHCP lease MAC addresses
      debugPrint('MockApiService: Failed to load associated stations data: $e');
      return {
        'wlan0': {
          'aa:bb:cc:11:22:33',
          'aa:bb:cc:44:55:66',
          'aa:bb:cc:77:88:99',
          'bb:cc:dd:11:22:33',
          'bb:cc:dd:44:55:66',
          'bb:cc:dd:77:88:99',
        },
        'wlan1': {
          'aa:bb:cc:aa:bb:cc',
          'aa:bb:cc:dd:ee:ff',
          'aa:bb:cc:12:34:56',
          'bb:cc:dd:aa:bb:cc',
          'bb:cc:dd:dd:ee:ff',
          'aa:bb:cc:65:43:21',
        },
      };
    }
  }

  @override
  Future<Map<String, dynamic>?> fetchWireGuardPeers({
    required String ipAddress,
    required String sysauth,
    required bool useHttps,
    required String interface,
    BuildContext? context,
  }) async {
    // Simulate a short delay for realism
    await Future.delayed(const Duration(milliseconds: 300));

    try {
      final jsonString = await rootBundle.loadString(
        '${AppConfig.mockDataPath}wireguard_peers.json',
      );
      final jsonData = jsonDecode(jsonString);
      return jsonData as Map<String, dynamic>;
    } catch (e) {
      // Log error and return comprehensive default mock data
      debugPrint('MockApiService: Failed to load WireGuard peers data: $e');
      return {
        interface: {
          'interface': interface,
          'peers': {
            'peer_public_key_1': {
              'public_key': 'peer_public_key_1',
              'endpoint': '192.168.1.100:51820',
              'last_handshake':
                  _getVariedTimestamp() - _random.nextInt(300) - 30,
              'transfer_rx': _random.nextInt(1000000),
              'transfer_tx': _random.nextInt(500000),
              'persistent_keepalive': 25,
            },
            'peer_public_key_2': {
              'public_key': 'peer_public_key_2',
              'endpoint': '192.168.1.101:51820',
              'last_handshake':
                  _getVariedTimestamp() - _random.nextInt(600) - 60,
              'transfer_rx': _random.nextInt(2000000),
              'transfer_tx': _random.nextInt(1000000),
              'persistent_keepalive': 0,
            },
          },
        },
      };
    }
  }

  // No HTTP client creation required for mock service when using Dio

  /// Resolves an endpoint to a fixture file.
  ///
  /// [params] matters: `uci.get` and `file.exec` serve completely different
  /// data depending on the config or command asked for, and ignoring that
  /// hands callers the wrong fixture entirely.
  String? _getMockDataFile(
    String object,
    String method,
    Map<String, dynamic>? params,
  ) {
    switch ('$object.$method') {
      case 'uci.get':
        switch (params?['config']) {
          case 'wireless':
            return 'uci_wireless.json';
          case 'dhcp':
            return 'uci_dhcp.json';
          case 'firewall':
            return 'uci_firewall.json';
          case 'system':
            return 'uci_system.json';
          case 'sqm':
            return 'uci_sqm.json';
          case 'adblock':
            return 'uci_adblock.json';
          case 'upnpd':
            return 'uci_upnpd.json';
          case 'ddns':
            return 'uci_ddns.json';
          case 'network':
            return 'uci_network.json';
          case 'openclash':
            return 'uci_openclash.json';
          default:
            return null;
        }
      case 'iwinfo.assoclist':
        final device = params?['device']?.toString();
        if (device == null) return null;
        return 'assoclist_$device.json';
      case 'file.exec':
        final command = params?['command']?.toString() ?? '';
        // Only the DHCP-lease shell-out is fixture-backed; everything else
        // must fall through rather than be handed lease text.
        if (command.contains('dnsmasq') || command.contains('dhcp')) {
          return 'dhcp_leases.json';
        }
        return null;
    }

    const mockFileMap = {
      'system.board': 'system_board.json',
      'system.info': 'system_info.json',
      // 'network.device': 'network_devices.json', // Use dynamic data for throughput
      'network.interface': 'interface_dump.json',
      'network.interface.dump': 'interface_dump.json',
      'wireless.devices': 'wireless_devices.json',
      'luci.wireguard.getWgInstances': 'wireguard_peers.json',
      'luci-rpc.getNetworkDevices': 'network_devices.json',
      'luci-rpc.getWirelessDevices': 'wireless_devices.json',
      'luci-rpc.getDHCPLeases': 'dhcp_leases.json',
      'luci-rpc.getHostHints': 'host_hints.json',
    };

    return mockFileMap['$object.$method'];
  }

  dynamic _formatMockData(String endpoint, dynamic data) {
    if (endpoint != 'luci-rpc.getDHCPLeases' || data is! Map) return data;

    final leases = <Map<String, dynamic>>[];
    for (final line in (data['stdout'] as String? ?? '').split('\n')) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 4) continue;
      leases.add({
        'expires': int.tryParse(parts[0]) ?? 0,
        'macaddr': parts[1],
        'ipaddr': parts[2],
        'hostname': parts[3],
        'activetime': 0,
        'leasetime': int.tryParse(parts[0]) ?? 0,
      });
    }
    return {'dhcp_leases': leases};
  }

  dynamic _getDefaultMockData(String object, String method) {
    // Return default mock data based on object and method
    switch ('$object.$method') {
      case 'system.board':
        return [
          0,
          {
            'hostname': 'MockRouter',
            'model': 'Mock Router Model X',
            'release': {
              'distribution': 'OpenWrt',
              'version': '23.05.0',
              'revision': 'r23497-6637af95aa',
              'target': 'mock/generic',
              'description': 'OpenWrt 23.05.0 Mock',
            },
            'kernel': '5.15.134',
            'board_name': 'mock-router-x',
            'system': 'Mock System',
          },
        ];

      case 'system.info':
        final memory = _getVariedMemory();
        return [
          0,
          {
            'uptime': _getVariedUptime(),
            'load': _getVariedLoadAverages(),
            'memory': memory,
            'localtime': _getVariedTimestamp(),
          },
        ];

      case 'network.device':
        final wanStats = _getVariedNetworkStats('eth0');
        final lanStats = _getVariedNetworkStats('br-lan');
        return [
          0,
          {
            'eth0': {'device': 'eth0', 'up': true, 'stats': wanStats},
            'br-lan': {'device': 'br-lan', 'up': true, 'stats': lanStats},
          },
        ];

      case 'network.interface':
        return [
          0,
          [
            {
              'interface': 'wan',
              'up': true,
              'proto': 'dhcp',
              'ipv4-address': [
                {'address': '192.168.1.100', 'mask': 24},
              ],
              'ipv6-address': [],
              'device': 'eth0',
              'dns-server': ['8.8.8.8', '8.8.4.4'],
              'route': [
                {'target': '0.0.0.0', 'mask': 0, 'nexthop': '192.168.1.1'},
              ],
            },
            {
              'interface': 'lan',
              'up': true,
              'proto': 'static',
              'ipv4-address': [
                {'address': '192.168.10.1', 'mask': 24},
              ],
              'ipv6-address': [],
              'device': 'br-lan',
              'dns-server': [],
              'route': [],
            },
          ],
        ];

      case 'wireless.devices':
        return [
          0,
          {
            'radio0': {
              'up': true,
              'channel': 6,
              'frequency': 2437,
              'txpower': 20,
              'country': 'US',
              'interfaces': [
                {
                  'ifname': 'wlan0',
                  'ssid': 'MockWiFi',
                  'encryption': 'psk2',
                  'key': '********',
                  'network': 'lan',
                },
              ],
            },
          },
        ];

      case 'modemmanager.info':
        // `ubus call modemmanager info` on a Quectel EC25: the backend
        // reports signal as a percentage, not dBm, and keeps the SIM
        // identifiers flat next to the operator.
        return [
          0,
          {
            'modem': [
              {
                'device': 'wwan0',
                'model': 'Quectel EC25-E',
                'operator': 'Telekom.de',
                'technology': 'lte',
                'signal': '68',
                'state': 'registered',
                'imsi': '262019876543210',
                'iccid': '89490123456789012345',
                'imei': '861107037891430',
              },
            ],
          },
        ];

      case 'file.exec':
        // A generic successful exec. Lease-reading commands are routed to the
        // lease fixture by _getMockDataFile; everything else must not be
        // handed lease text.
        return [
          0,
          {'stdout': '', 'stderr': '', 'code': 0},
        ];

      case 'luci-rpc.getDHCPLeases':
        // DHCP leases data
        return [
          0,
          {'stdout': _getVariedDhcpLeases(), 'stderr': '', 'code': 0},
        ];

      case 'network.interface.dump':
        // Network interface dump - returns flat map of interfaces with names as keys
        return [
          0,
          {
            'interface': [
              {
                'interface': 'wan',
                'up': true,
                'pending': false,
                'available': true,
                'autostart': true,
                'dynamic': false,
                'proto': 'dhcp',
                'device': 'eth0',
                'metric': 0,
                'dns_metric': 0,
                'delegation': true,
                'ipv4-address': [
                  {'address': '100.64.0.123', 'mask': 24, 'ptpaddress': ''},
                ],
                'ipv6-address': [],
                'ipv6-prefix': [],
                'ipv6-prefix-assignment': [],
                'route': [
                  {
                    'target': '0.0.0.0',
                    'mask': 0,
                    'nexthop': '100.64.0.1',
                    'source': '',
                  },
                ],
                'dns-server': ['8.8.8.8', '8.8.4.4'],
                'dns-search': [],
                'inactive': {
                  'ipv4-address': [],
                  'ipv6-address': [],
                  'route': [],
                  'dns-server': [],
                  'dns-search': [],
                },
              },
              {
                'interface': 'wan6',
                'up': true,
                'pending': false,
                'available': true,
                'autostart': true,
                'dynamic': false,
                'proto': 'dhcpv6',
                'device': 'eth0',
                'metric': 0,
                'dns_metric': 0,
                'delegation': true,
                'ipv4-address': [],
                'ipv6-address': [
                  {'address': '2001:db8::1', 'mask': 64, 'ptpaddress': ''},
                ],
                'ipv6-prefix': [],
                'ipv6-prefix-assignment': [],
                'route': [],
                'dns-server': ['2001:4860:4860::8888'],
                'dns-search': [],
                'inactive': {
                  'ipv4-address': [],
                  'ipv6-address': [],
                  'route': [],
                  'dns-server': [],
                  'dns-search': [],
                },
              },
              {
                'interface': 'wanb',
                'up': false,
                'pending': false,
                'available': false,
                'autostart': true,
                'dynamic': false,
                'proto': 'pppoe',
                'device': 'eth1',
                'metric': 0,
                'dns_metric': 0,
                'delegation': true,
                'ipv4-address': [],
                'ipv6-address': [],
                'ipv6-prefix': [],
                'ipv6-prefix-assignment': [],
                'route': [],
                'dns-server': [],
                'dns-search': [],
                'inactive': {
                  'ipv4-address': [],
                  'ipv6-address': [],
                  'route': [],
                  'dns-server': [],
                  'dns-search': [],
                },
              },
              {
                'interface': 'lan',
                'up': true,
                'pending': false,
                'available': true,
                'autostart': true,
                'dynamic': false,
                'proto': 'static',
                'device': 'br-lan',
                'metric': 0,
                'dns_metric': 0,
                'delegation': true,
                'ipv4-address': [
                  {'address': '192.168.1.1', 'mask': 24, 'ptpaddress': ''},
                ],
                'ipv6-address': [],
                'ipv6-prefix': [],
                'ipv6-prefix-assignment': [],
                'route': [],
                'dns-server': [],
                'dns-search': [],
                'inactive': {
                  'ipv4-address': [],
                  'ipv6-address': [],
                  'route': [],
                  'dns-server': [],
                  'dns-search': [],
                },
              },
            ],
          },
        ];

      case 'luci-rpc.getNetworkDevices':
        // Network devices data (same structure as network.device)
        final wanStats = _getVariedNetworkStats('eth0');
        final lanStats = _getVariedNetworkStats('br-lan');
        return [
          0,
          {
            'eth0': {'device': 'eth0', 'up': true, 'stats': wanStats},
            'br-lan': {'device': 'br-lan', 'up': true, 'stats': lanStats},
          },
        ];

      case 'luci-rpc.getWirelessDevices':
        // Wireless devices data (same structure as wireless.devices)
        return [
          0,
          {
            'radio0': {
              'up': true,
              'channel': 6,
              'frequency': 2437,
              'txpower': 20,
              'country': 'US',
              'interfaces': [
                {
                  'ifname': 'wlan0',
                  'ssid': 'MockWiFi',
                  'encryption': 'psk2',
                  'key': '********',
                  'network': 'lan',
                },
              ],
            },
            'radio1': {
              'up': true,
              'channel': 36,
              'frequency': 5180,
              'txpower': 23,
              'country': 'US',
              'interfaces': [
                {
                  'ifname': 'wlan1',
                  'ssid': 'MockWiFi_5G',
                  'encryption': 'psk2',
                  'key': '********',
                  'network': 'lan',
                },
              ],
            },
          },
        ];

      case 'luci.wireguard.getWgInstances':
        // WireGuard instances data
        return [
          0,
          {
            'wg0': {
              'interface': 'wg0',
              'peers': {
                'peer_public_key_1': {
                  'public_key': 'peer_public_key_1',
                  'endpoint': '192.168.1.100:51820',
                  'last_handshake':
                      _getVariedTimestamp() - _random.nextInt(300) - 30,
                  'transfer_rx': _random.nextInt(1000000),
                  'transfer_tx': _random.nextInt(500000),
                  'persistent_keepalive': 25,
                },
                'peer_public_key_2': {
                  'public_key': 'peer_public_key_2',
                  'endpoint': '192.168.1.101:51820',
                  'last_handshake':
                      _getVariedTimestamp() - _random.nextInt(600) - 60,
                  'transfer_rx': _random.nextInt(2000000),
                  'transfer_tx': _random.nextInt(1000000),
                  'persistent_keepalive': 0,
                },
              },
            },
          },
        ];

      case 'iwinfo.assoclist':
        // Associated stations data
        return [
          0,
          {
            'wlan0': {
              'aa:bb:cc:dd:ee:01': {
                'signal': -40 - _random.nextInt(20),
                'noise': -95 - _random.nextInt(5),
                'inactive': _random.nextInt(300),
                'rx_packets': _random.nextInt(10000),
                'tx_packets': _random.nextInt(8000),
                'rx_rate': 144000 + _random.nextInt(100000),
                'tx_rate': 72000 + _random.nextInt(50000),
              },
              'aa:bb:cc:dd:ee:02': {
                'signal': -50 - _random.nextInt(15),
                'noise': -92 - _random.nextInt(8),
                'inactive': _random.nextInt(180),
                'rx_packets': _random.nextInt(15000),
                'tx_packets': _random.nextInt(12000),
                'rx_rate': 108000 + _random.nextInt(80000),
                'tx_rate': 54000 + _random.nextInt(30000),
              },
            },
            'wlan1': {
              'aa:bb:cc:dd:ee:03': {
                'signal': -35 - _random.nextInt(10),
                'noise': -98 - _random.nextInt(3),
                'inactive': _random.nextInt(120),
                'rx_packets': _random.nextInt(20000),
                'tx_packets': _random.nextInt(18000),
                'rx_rate': 200000 + _random.nextInt(200000),
                'tx_rate': 150000 + _random.nextInt(100000),
              },
            },
          },
        ];

      case 'uci.get':
        // UCI configuration data (generic response for various configs)
        return [
          0,
          {
            'wireless': {
              'radio0': {
                '.type': 'wifi-device',
                'type': 'mac80211',
                'channel': '6',
                'hwmode': '11g',
                'path': 'platform/10180000.wmac',
                'htmode': 'HT20',
                'disabled': '0',
              },
              'default_radio0': {
                '.type': 'wifi-iface',
                'device': 'radio0',
                'network': 'lan',
                'mode': 'ap',
                'ssid': 'MockWiFi',
                'encryption': 'psk2',
                'key': 'mock_password',
              },
            },
          },
        ];

      case 'system.exec':
        // System execution results
        return [
          0,
          {'stdout': '', 'stderr': '', 'code': 0},
        ];

      default:
        // Return generic success response for unknown endpoints
        return [0, {}];
    }
  }

  // Helper methods for generating dynamic values
  static int _getVariedUptime() {
    _baseUptime += _random.nextInt(30) + 1; // Increment by 1-30 seconds
    return _baseUptime;
  }

  static List<int> _getVariedLoadAverages() {
    return [
      1000 + _random.nextInt(1000), // 1-2 range
      2000 + _random.nextInt(1000), // 2-3 range
      1500 + _random.nextInt(500), // 1.5-2 range
    ];
  }

  static Map<String, int> _getVariedMemory() {
    const int totalMemory = 268435456; // 256MB fixed
    final int usedVariation = _random.nextInt(20971520); // Up to 20MB variation
    final int freeMemory =
        134217728 - usedVariation; // Base 128MB minus variation

    return {
      'total': totalMemory,
      'free': freeMemory,
      'shared': 1048576 + _random.nextInt(524288), // 1-1.5MB
      'buffered': 10485760 + _random.nextInt(2097152), // 10-12MB
      'cached': 20971520 + _random.nextInt(5242880), // 20-25MB
      'available':
          freeMemory +
          20971520 +
          _random.nextInt(10485760), // Free + some cache
    };
  }

  static Map<String, int> _getVariedNetworkStats(String device) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final seconds =
        (now ~/ 1000) % 3600; // Reset every hour for predictable patterns

    if (device == 'eth0') {
      // Create realistic throughput patterns with sine waves and random noise
      final timeBasedMultiplier =
          1.0 + 0.5 * sin(seconds * 2 * pi / 300); // 5-minute cycles
      final burstMultiplier = _random.nextBool()
          ? (1.0 + _random.nextDouble() * 2)
          : 1.0; // Random bursts

      // Base rates: 50-500 KB/s for download, 10-100 KB/s for upload
      final rxIncrement =
          ((50000 + _random.nextInt(450000)) *
                  timeBasedMultiplier *
                  burstMultiplier)
              .round();
      final txIncrement =
          ((10000 + _random.nextInt(90000)) *
                  timeBasedMultiplier *
                  burstMultiplier *
                  0.3)
              .round();

      _baseRxBytes += rxIncrement;
      _baseTxBytes += txIncrement;
      _baseRxPackets +=
          (rxIncrement / 1500).round() +
          _random.nextInt(50); // ~1500 bytes per packet
      _baseTxPackets += (txIncrement / 1500).round() + _random.nextInt(20);

      return {
        'rx_bytes': _baseRxBytes,
        'tx_bytes': _baseTxBytes,
        'rx_packets': _baseRxPackets,
        'tx_packets': _baseTxPackets,
        'rx_dropped': _random.nextInt(3),
        'tx_dropped': _random.nextInt(2),
        'rx_errors': _random.nextInt(2),
        'tx_errors': _random.nextInt(2),
      };
    } else {
      // For br-lan (LAN interface), simulate local network activity
      final timeBasedMultiplier =
          1.0 + 0.3 * sin(seconds * 2 * pi / 180); // 3-minute cycles
      final localActivity = _random.nextBool()
          ? (1.0 + _random.nextDouble())
          : 0.5;

      // LAN typically has lower but more consistent throughput
      final rxIncrement =
          ((20000 + _random.nextInt(100000)) *
                  timeBasedMultiplier *
                  localActivity)
              .round();
      final txIncrement =
          ((15000 + _random.nextInt(80000)) *
                  timeBasedMultiplier *
                  localActivity)
              .round();

      _baseLanRxBytes += rxIncrement;
      _baseLanTxBytes += txIncrement;
      _baseLanRxPackets += (rxIncrement / 1500).round() + _random.nextInt(20);
      _baseLanTxPackets += (txIncrement / 1500).round() + _random.nextInt(15);

      return {
        'rx_bytes': _baseLanRxBytes,
        'tx_bytes': _baseLanTxBytes,
        'rx_packets': _baseLanRxPackets,
        'tx_packets': _baseLanTxPackets,
        'rx_dropped': _random.nextInt(2),
        'tx_dropped': _random.nextInt(2),
        'rx_errors': _random.nextInt(2),
        'tx_errors': _random.nextInt(2),
      };
    }
  }

  static int _getVariedTimestamp() {
    return DateTime.now().millisecondsSinceEpoch ~/ 1000;
  }

  static String _getVariedDhcpLeases() {
    final now = _getVariedTimestamp();
    final devices = [
      'iPhone-John',
      'MacBook-Pro',
      'Smart-TV-Living-Room',
      'Gaming-PC',
      'Nest-Thermostat',
      'iPad-Sarah',
      'Amazon-Echo',
      'Samsung-Galaxy-S23',
      'Dell-Laptop-Work',
      'Ring-Doorbell',
      'Nintendo-Switch',
      'Philips-Hue-Bridge',
    ];
    final macAddresses = [
      'aa:bb:cc:11:22:33',
      'aa:bb:cc:44:55:66',
      'aa:bb:cc:77:88:99',
      'aa:bb:cc:aa:bb:cc',
      'aa:bb:cc:dd:ee:ff',
      'aa:bb:cc:12:34:56',
      'aa:bb:cc:65:43:21',
      'bb:cc:dd:11:22:33',
      'bb:cc:dd:44:55:66',
      'bb:cc:dd:77:88:99',
      'bb:cc:dd:aa:bb:cc',
      'bb:cc:dd:dd:ee:ff',
    ];
    final ipAddresses = [
      '192.168.1.100',
      '192.168.1.101',
      '192.168.1.102',
      '192.168.1.103',
      '192.168.1.104',
      '192.168.1.105',
      '192.168.1.106',
      '192.168.1.108',
      '192.168.1.109',
      '192.168.1.110',
      '192.168.1.111',
      '192.168.1.112',
    ];

    String leases = '';
    for (int i = 0; i < devices.length; i++) {
      // Vary lease time slightly
      final leaseTime = now + _random.nextInt(3600); // +0 to 1 hour variation
      leases +=
          '$leaseTime ${macAddresses[i]} ${ipAddresses[i]} ${devices[i]} 01:${macAddresses[i]}\n';
    }

    return leases;
  }

  @override
  Future<List<String>> fetchAssociatedStationsWithContext({
    required String ipAddress,
    required String sysauth,
    required bool useHttps,
    required String interface,
    BuildContext? context,
  }) async {
    await Future.delayed(const Duration(milliseconds: 200));
    // Return mock associated stations
    return ['aa:bb:cc:dd:ee:01', 'aa:bb:cc:dd:ee:02', 'aa:bb:cc:dd:ee:03'];
  }

  @override
  Future<dynamic> uciSet(
    String ipAddress,
    String sysauth,
    bool useHttps, {
    required String config,
    required String section,
    required Map<String, Object> values,
    BuildContext? context,
  }) async {
    await Future.delayed(const Duration(milliseconds: 200));
    final sections = await _loadUciConfig(config);
    if (sections != null) {
      _snapshotUci(config);
      final target = sections.putIfAbsent(section, () => <String, dynamic>{});
      target.addAll(values);
    }
    for (final entry in values.entries) {
      final v = entry.value;
      _stage(config, [
        'set',
        section,
        entry.key,
        v is List ? v.join(' ') : v.toString(),
      ]);
    }
    return [0, 'success'];
  }

  @override
  Future<dynamic> uciCommit(
    String ipAddress,
    String sysauth,
    bool useHttps, {
    required String config,
    BuildContext? context,
  }) async {
    await Future.delayed(const Duration(milliseconds: 200));
    _uciSnapshots.remove(config);
    _stagedChanges.remove(config);
    return [0, 'success'];
  }

  @override
  Future<dynamic> systemExec(
    String ipAddress,
    String sysauth,
    bool useHttps, {
    required String command,
    List<String> params = const [],
    BuildContext? context,
  }) async {
    await Future.delayed(const Duration(milliseconds: 500));
    // Return success response for mock system exec operation
    return [0, 'success'];
  }

  @override
  Future<Map<String, Set<String>>> fetchAllAssociatedWirelessMacsWithContext({
    required String ipAddress,
    required String sysauth,
    required bool useHttps,
    BuildContext? context,
  }) async {
    // For mock service, just delegate to fetchAssociatedStations
    return await fetchAssociatedStations();
  }

  @override
  Future<List<Map<String, dynamic>>> scanWirelessNetworks({
    required String ipAddress,
    required String sysauth,
    required bool useHttps,
    required String device,
    BuildContext? context,
  }) async {
    final token = _scanToken;
    await Future.delayed(const Duration(seconds: 2)); // Simulate scan time
    // Return empty list if scan was cancelled before completion.
    if (_scanToken != token) return [];
    return [
      {
        'ssid': 'Neighbor-WiFi',
        'bssid': 'AA:BB:CC:11:22:33',
        'mode': 'Master',
        'channel': 1,
        'signal': -45,
        'quality': 65,
        'quality_max': 70,
        'encryption': {
          'enabled': true,
          'description': 'WPA2 PSK (CCMP)',
          'wep': false,
          'wpa': 2,
          'auth_suites': ['PSK'],
          'pair_ciphers': ['CCMP'],
          'group_ciphers': ['CCMP'],
        },
      },
      {
        'ssid': 'CoffeeShop-Free',
        'bssid': 'DD:EE:FF:44:55:66',
        'mode': 'Master',
        'channel': 6,
        'signal': -62,
        'quality': 48,
        'quality_max': 70,
        'encryption': {
          'enabled': false,
          'description': 'None',
          'wep': false,
          'wpa': 0,
          'auth_suites': <String>[],
          'pair_ciphers': <String>[],
          'group_ciphers': <String>[],
        },
      },
      {
        'ssid': 'Office-5G',
        'bssid': '11:22:33:AA:BB:CC',
        'mode': 'Master',
        'channel': 36,
        'signal': -55,
        'quality': 55,
        'quality_max': 70,
        'encryption': {
          'enabled': true,
          'description': 'WPA2 PSK (CCMP)',
          'wep': false,
          'wpa': 2,
          'auth_suites': ['PSK'],
          'pair_ciphers': ['CCMP'],
          'group_ciphers': ['CCMP'],
        },
      },
      {
        'ssid': 'SmartHome-IoT',
        'bssid': '77:88:99:DD:EE:FF',
        'mode': 'Master',
        'channel': 11,
        'signal': -71,
        'quality': 35,
        'quality_max': 70,
        'encryption': {
          'enabled': true,
          'description': 'WPA3 SAE (CCMP)',
          'wep': false,
          'wpa': 3,
          'auth_suites': ['SAE'],
          'pair_ciphers': ['CCMP'],
          'group_ciphers': ['CCMP'],
        },
      },
      {
        'ssid': 'NETGEAR-Guest',
        'bssid': 'CC:DD:EE:11:22:33',
        'mode': 'Master',
        'channel': 44,
        'signal': -78,
        'quality': 22,
        'quality_max': 70,
        'encryption': {
          'enabled': true,
          'description': 'WPA2 PSK (CCMP)',
          'wep': false,
          'wpa': 2,
          'auth_suites': ['PSK'],
          'pair_ciphers': ['CCMP'],
          'group_ciphers': ['CCMP'],
        },
      },
      {
        'ssid': '',
        'bssid': 'FF:00:11:22:33:44',
        'mode': 'Master',
        'channel': 3,
        'signal': -82,
        'quality': 15,
        'quality_max': 70,
        'encryption': {
          'enabled': true,
          'description': 'WPA2 PSK (CCMP)',
          'wep': false,
          'wpa': 2,
          'auth_suites': ['PSK'],
          'pair_ciphers': ['CCMP'],
          'group_ciphers': ['CCMP'],
        },
      },
    ];
  }

  @override
  Future<dynamic> uciAdd(
    String ipAddress,
    String sysauth,
    bool useHttps, {
    required String config,
    required String type,
    required Map<String, dynamic> values,
    String? name,
    BuildContext? context,
  }) async {
    await Future.delayed(const Duration(milliseconds: 300));
    final generated = (++_mockSectionCounter).toString().padLeft(6, '0');
    final section = name ?? 'cfg$generated';
    final sections = await _loadUciConfig(config);
    if (sections != null) {
      _snapshotUci(config);
      sections[section] = <String, dynamic>{
        '.type': type,
        '.name': section,
        '.anonymous': name == null,
        ...values,
      };
    }
    _stage(config, ['add', section, type]);
    for (final entry in values.entries) {
      _stage(config, ['set', section, entry.key, entry.value.toString()]);
    }
    return [0, section];
  }

  @override
  Future<dynamic> uciDelete(
    String ipAddress,
    String sysauth,
    bool useHttps, {
    required String config,
    required String section,
    String? option,
    BuildContext? context,
  }) async {
    await Future.delayed(const Duration(milliseconds: 200));
    final sections = await _loadUciConfig(config);
    if (sections != null) {
      _snapshotUci(config);
      if (option == null) {
        sections.remove(section);
      } else {
        sections[section]?.remove(option);
      }
    }
    _stage(
      config,
      option == null ? ['remove', section] : ['remove', section, option],
    );
    return [0, 'success'];
  }

  @override
  Future<dynamic> uciGetAll(
    String ipAddress,
    String sysauth,
    bool useHttps, {
    required String config,
    BuildContext? context,
  }) async {
    await Future.delayed(const Duration(milliseconds: 200));
    // Just reuse the call method for uci.get
    return await call(
      ipAddress,
      sysauth,
      useHttps,
      object: 'uci',
      method: 'get',
      params: {'config': config},
      context: context?.mounted == true ? context : null,
    );
  }

  @override
  void cancelScan() {
    _scanToken++; // invalidates any in-flight scan
  }

  @override
  Future<List<String>> uciConfigs(
    String ipAddress,
    String sysauth,
    bool useHttps, {
    BuildContext? context,
  }) async {
    await Future.delayed(const Duration(milliseconds: 150));
    // A plausible OpenWrt set with a few add-ons installed. Some are
    // deliberately absent (`ddns`) so reviewer mode walks the "feature
    // unavailable" path too — but enough are present that the add-ons hub
    // is not a screen of greyed-out rows, which reads as broken.
    return const [
      'adblock',
      'dhcp',
      'dropbear',
      'firewall',
      'luci',
      'network',
      'nlbwmon',
      'openclash',
      'rpcd',
      'sqm',
      'system',
      'ucitrack',
      'uhttpd',
      'upnpd',
      'wireless',
    ];
  }

  @override
  Future<Map<String, List<List<String>>>> uciChanges(
    String ipAddress,
    String sysauth,
    bool useHttps, {
    String? config,
    BuildContext? context,
  }) async {
    await Future.delayed(const Duration(milliseconds: 150));
    if (config == null) {
      return {
        for (final entry in _stagedChanges.entries)
          entry.key: List<List<String>>.from(entry.value),
      };
    }
    final rows = _stagedChanges[config];
    if (rows == null || rows.isEmpty) return const {};
    return {config: List<List<String>>.from(rows)};
  }

  @override
  Future<dynamic> uciRevert(
    String ipAddress,
    String sysauth,
    bool useHttps, {
    required String config,
    BuildContext? context,
  }) async {
    await Future.delayed(const Duration(milliseconds: 150));
    _restoreUci(config);
    _stagedChanges.remove(config);
    return [0, 'success'];
  }

  @override
  Future<dynamic> uciApply(
    String ipAddress,
    String sysauth,
    bool useHttps, {
    required bool rollback,
    required int timeoutSeconds,
    BuildContext? context,
  }) async {
    await Future.delayed(const Duration(milliseconds: 300));
    if (rollback) {
      _applyAwaitingConfirm = true;
    } else {
      _uciSnapshots.clear();
      _stagedChanges.clear();
    }
    return [0, 'success'];
  }

  @override
  Future<dynamic> uciConfirm(
    String ipAddress,
    String sysauth,
    bool useHttps, {
    BuildContext? context,
  }) async {
    await Future.delayed(const Duration(milliseconds: 150));
    _applyAwaitingConfirm = false;
    _uciSnapshots.clear();
    _stagedChanges.clear();
    return [0, 'success'];
  }

  @override
  Future<dynamic> uciRollback(
    String ipAddress,
    String sysauth,
    bool useHttps, {
    BuildContext? context,
  }) async {
    await Future.delayed(const Duration(milliseconds: 150));
    _applyAwaitingConfirm = false;
    for (final config in _uciSnapshots.keys.toList()) {
      _restoreUci(config);
    }
    _stagedChanges.clear();
    return [0, 'success'];
  }

  @override
  Future<Map<String, dynamic>> luciGetFeatures(
    String ipAddress,
    String sysauth,
    bool useHttps, {
    BuildContext? context,
  }) async {
    await Future.delayed(const Duration(milliseconds: 150));
    // A modern stock build: fw4, apk, IPv6, wifi present; no swconfig.
    return const {
      'firewall4': true,
      'firewall': false,
      'apk': true,
      'opkg': false,
      'ipv6': true,
      'wifi': true,
      'swconfig': false,
      'offloading': true,
      'dropbear': true,
      'relayd': false,
      'zram': false,
      'sysntpd': true,
      'cabundle': true,
    };
  }

  @override
  Future<Map<String, Set<String>>?> fetchSessionAcl(
    String ipAddress,
    String sysauth,
    bool useHttps, {
    BuildContext? context,
  }) async {
    await Future.delayed(const Duration(milliseconds: 150));
    // Reviewer mode stands in for a full-access (root) login.
    return const {
      'uci': {'*'},
      'iwinfo': {'*'},
      'luci-rpc': {'*'},
      'luci': {'*'},
      'system': {'*'},
      'file': {'*'},
      'rc': {'*'},
      'network.interface': {'*'},
      'modemmanager': {'*'},
      'session': {'*'},
    };
  }

  @override
  Future<Map<String, StationInfo>> fetchStationDetails(
    String ipAddress,
    String sysauth,
    bool useHttps, {
    required String device,
    BuildContext? context,
  }) async {
    await Future.delayed(const Duration(milliseconds: 250));
    try {
      final raw = jsonDecode(
        await rootBundle.loadString(
          '${AppConfig.mockDataPath}assoclist_$device.json',
        ),
      );
      final results = raw is Map ? raw['results'] : null;
      if (results is! List) return const <String, StationInfo>{};
      final out = <String, StationInfo>{};
      for (final row in results) {
        if (row is! Map) continue;
        final station = StationInfo.fromJson(
          Map<String, dynamic>.from(row),
          interface: device,
        );
        if (station != null) out[station.macAddress] = station;
      }
      return out;
    } catch (e) {
      debugPrint('MockApiService: no assoclist fixture for $device: $e');
      return const <String, StationInfo>{};
    }
  }

  @override
  Future<Map<String, dynamic>> fetchHostHints(
    String ipAddress,
    String sysauth,
    bool useHttps, {
    BuildContext? context,
  }) async {
    await Future.delayed(const Duration(milliseconds: 200));
    try {
      final raw = jsonDecode(
        await rootBundle.loadString('${AppConfig.mockDataPath}host_hints.json'),
      );
      if (raw is! Map) return const <String, dynamic>{};
      return {
        for (final entry in raw.entries)
          StationInfo.normalizeMac(entry.key.toString()): entry.value,
      };
    } catch (e) {
      debugPrint('MockApiService: failed to load host hints: $e');
      return const <String, dynamic>{};
    }
  }

  @override
  Future<List<List<num>>> luciRealtimeStats(
    String ipAddress,
    String sysauth,
    bool useHttps, {
    required String mode,
    String? device,
    BuildContext? context,
  }) async {
    await Future.delayed(const Duration(milliseconds: 200));
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // 60 samples at 1 Hz, shaped like the mode the caller asked for.
    return [
      for (var i = 59; i >= 0; i--)
        switch (mode) {
          // load: [time, 1min, 5min, 15min] in 1/100 units
          'load' => [
            now - i,
            30 + _random.nextInt(120),
            40 + _random.nextInt(80),
            50 + _random.nextInt(40),
          ],
          // conntrack: [time, count]
          'conntrack' => [now - i, 40 + _random.nextInt(60)],
          // interface: [time, rx_bytes, rx_pkts, tx_bytes, tx_pkts]
          _ => [
            now - i,
            _baseRxBytes + i * 1200,
            _baseRxPackets + i * 8,
            _baseTxBytes + i * 700,
            _baseTxPackets + i * 5,
          ],
        },
    ];
  }

  @override
  Future<Map<String, ServiceStatus>> rcList(
    String ipAddress,
    String sysauth,
    bool useHttps, {
    BuildContext? context,
  }) async {
    await Future.delayed(const Duration(milliseconds: 200));
    return {
      for (final e in _mockServices.entries)
        e.key: ServiceStatus(
          name: e.key,
          enabled: e.value.$1,
          running: e.value.$2,
        ),
    };
  }

  // name -> (enabled, running); mutated so a toggle sticks in reviewer mode.
  final Map<String, (bool, bool)> _mockServices = {
    'dnsmasq': (true, true),
    'dropbear': (true, true),
    'firewall': (true, true),
    'network': (true, true),
    'odhcpd': (true, true),
    'uhttpd': (true, true),
    'cron': (true, false),
    'sysntpd': (true, true),
    // Present and running so the Settings → OpenClash screen has a service to
    // talk to; without it reviewer mode would open straight onto "not
    // installed" and never exercise the status or node paths.
    'openclash': (true, true),
  };

  @override
  Future<bool> rcInit(
    String ipAddress,
    String sysauth,
    bool useHttps, {
    required String name,
    required String action,
    BuildContext? context,
  }) async {
    await Future.delayed(const Duration(milliseconds: 400));
    final current = _mockServices[name];
    if (current == null) return true;
    _mockServices[name] = switch (action) {
      'start' || 'restart' || 'reload' => (current.$1, true),
      'stop' => (current.$1, false),
      'enable' => (true, current.$2),
      'disable' => (false, current.$2),
      _ => current,
    };
    return true;
  }

  @override
  Future<bool> luciSetPassword(
    String ipAddress,
    String sysauth,
    bool useHttps, {
    required String username,
    required String password,
    BuildContext? context,
  }) async {
    await Future.delayed(const Duration(milliseconds: 300));
    return true;
  }

  @override
  Future<Map<String, String>> luciTimezones(
    String ipAddress,
    String sysauth,
    bool useHttps, {
    BuildContext? context,
  }) async {
    await Future.delayed(const Duration(milliseconds: 200));
    return const {
      'UTC': 'UTC',
      'Europe/Berlin': 'CET-1CEST,M3.5.0,M10.5.0/3',
      'Europe/London': 'GMT0BST,M3.5.0/1,M10.5.0',
      'America/New_York': 'EST5EDT,M3.2.0,M11.1.0',
      'Asia/Tokyo': 'JST-9',
    };
  }

  @override
  Future<bool?> checkUbusAccess(
    String ipAddress,
    String sysauth,
    bool useHttps, {
    required String object,
    required String function,
    BuildContext? context,
  }) async {
    await Future.delayed(const Duration(milliseconds: 100));
    return true;
  }
}

import 'package:luci_mobile/services/openclash_service.dart';

/// The Clash controller as reviewer mode sees it.
///
/// Shaped exactly like the real `/version`, `/configs`, `/proxies` and
/// `/connections` payloads measured against OpenClash 0.46 on Mihomo: the same
/// field names, the same nested `all` lists, the same byte counters. Reviewer
/// mode is what App Store review sees, and a fixture that only *looks* right
/// hides parsing bugs that would ship.
class MockClashApi implements ClashApi {
  MockClashApi({
    this.version = 'alpha-gbc76c13',
    String mode = 'rule',
    int mixedPort = 7893,
    List<({String name, String type, List<String> members, String now})>
    groups = defaultGroups,
  }) : _mode = mode,
       _mixedPort = mixedPort,
       _groups = [
         for (final group in groups)
           (
             name: group.name,
             type: group.type,
             members: [...group.members],
             now: group.now,
           ),
       ];

  final String version;
  String _mode;
  final int _mixedPort;
  final List<({String name, String type, List<String> members, String now})>
  _groups;

  /// A rule-mode config with three switchable groups and a mix of node types,
  /// including the emoji-prefixed names real subscription converters emit.
  static const List<
    ({String name, String type, List<String> members, String now})
  >
  defaultGroups = [
    (
      name: '良心云',
      type: 'Selector',
      members: [
        '🇭🇰香港高速01|BGP|CMCU',
        '🇭🇰香港高速04|BGP|CMCU',
        '🇸🇬新加坡高速01|BGP|CTCUCM',
        '🇯🇵日本高速01|BGP|CTCUCM',
        'DIRECT',
      ],
      now: '🇭🇰香港高速04|BGP|CMCU',
    ),
    (
      name: '自动选择',
      type: 'URLTest',
      members: [
        '🇭🇰香港高速01|BGP|CMCU',
        '🇭🇰香港高速04|BGP|CMCU',
        '🇸🇬新加坡高速01|BGP|CTCUCM',
      ],
      now: '🇭🇰香港高速01|BGP|CMCU',
    ),
    (
      name: '故障转移',
      type: 'Fallback',
      members: ['🇭🇰香港高速01|BGP|CMCU', '🇯🇵日本高速01|BGP|CTCUCM'],
      now: '🇭🇰香港高速01|BGP|CMCU',
    ),
  ];

  @override
  Future<Map<String, dynamic>> get(String path) async {
    await Future<void>.delayed(const Duration(milliseconds: 120));
    switch (path) {
      case '/version':
        return {'meta': true, 'version': version};
      case '/configs':
        return {
          'mode': _mode,
          'mixed-port': _mixedPort,
          'allow-lan': true,
          'log-level': 'info',
        };
      case '/proxies':
        return {
          'proxies': {
            // Built-in entries, included so the parser is exercised on the
            // real shape rather than on a list that already excludes them.
            'GLOBAL': {
              'type': 'Selector',
              'now': 'DIRECT',
              'all': ['DIRECT', 'REJECT', '良心云'],
            },
            'DIRECT': {'type': 'Direct'},
            'REJECT': {'type': 'Reject'},
            for (final group in _groups)
              group.name: {
                'type': group.type,
                'now': group.now,
                'all': group.members,
              },
          },
        };
      case '/connections':
        return {
          'uploadTotal': 7850481,
          'downloadTotal': 3477340069,
          'connections': [
            {
              'id': 'a',
              'metadata': {
                'host': 'log.tailscale.com',
                'network': 'tcp',
                'destinationPort': '443',
              },
              'chains': ['良心云'],
              'rule': 'Match',
            },
            {
              'id': 'b',
              'metadata': {
                'host': 'github.com',
                'network': 'tcp',
                'destinationPort': '443',
              },
              'chains': ['良心云'],
              'rule': 'DomainSuffix',
            },
          ],
        };
    }
    throw ClashUnreachableException('HTTP 404 ($path)');
  }

  @override
  Future<void> send(
    String method,
    String path,
    Map<String, dynamic> body,
  ) async {
    await Future<void>.delayed(const Duration(milliseconds: 150));

    if (method == 'PATCH' && path == '/configs') {
      _mode = body['mode']?.toString() ?? _mode;
      return;
    }

    if (method == 'PUT' && path.startsWith('/proxies/')) {
      final name = Uri.decodeComponent(path.substring('/proxies/'.length));
      final index = _groups.indexWhere((group) => group.name == name);
      final node = body['name']?.toString();
      if (index < 0 || node == null) {
        throw const ClashUnreachableException('HTTP 404');
      }
      _groups[index] = (
        name: _groups[index].name,
        type: _groups[index].type,
        members: _groups[index].members,
        now: node,
      );
      return;
    }

    throw const ClashUnreachableException('HTTP 404');
  }
}

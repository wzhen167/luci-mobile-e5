import 'package:flutter/foundation.dart';

import 'package:luci_mobile/utils/uci_values.dart';

/// The `openclash` UCI config, as much of it as this app needs.
///
/// Read once per snapshot and kept apart from the live dashboard data: the
/// config is what the router will do on the next start, while
/// [OpenClashSnapshot] also carries what the running core is doing now. They
/// disagree whenever a change was saved but not applied, and showing the
/// config's idea of the mode as if it were the live one would be a lie.
@immutable
class OpenClashConfig {
  const OpenClashConfig({
    required this.installed,
    this.enabledInConfig = false,
    this.apiPort = defaultApiPort,
    this.configPath,
    this.secret,
    this.configuredMode,
    this.operationMode,
  });

  /// The router has no `openclash` UCI config at all.
  static const OpenClashConfig absent = OpenClashConfig(installed: false);

  /// The port LuCI's dashboard talks to: `cn_port`, 9090 unless changed.
  static const int defaultApiPort = 9090;

  final bool installed;

  /// `openclash.config.enable` — whether the service starts with a boot.
  final bool enabledInConfig;

  /// The Clash external-controller port (`cn_port`).
  final int apiPort;

  /// The YAML in use, e.g. `/etc/openclash/config/liangxin.yaml`.
  final String? configPath;

  /// The dashboard password, which OpenClash writes into the YAML as the
  /// API `secret`.
  ///
  /// Kept as-is rather than trimmed: a password with a leading space is
  /// unlikely but a silent trim would turn "no secret" into "wrong secret".
  final String? secret;

  /// `proxy_mode` — what the config asks for, not what the core reports.
  final String? configuredMode;

  /// `operation_mode` — fake-ip, redir-host, tun, and so on.
  final String? operationMode;

  /// The file name alone, for a card that has no room for the full path.
  String? get configName {
    final path = configPath;
    if (path == null || path.isEmpty) return null;
    final slash = path.lastIndexOf('/');
    return slash < 0 ? path : path.substring(slash + 1);
  }

  /// Whether the dashboard can be asked anything. A core with no controller
  /// port is running fine but has nothing to answer with.
  bool get hasApi => installed && apiPort > 0;

  /// Reads the `openclash` config out of a `uci.get` values map.
  ///
  /// The section is normally named `config` (`openclash.config=openclash`),
  /// but a renamed section, an anonymous one, or a firmware that shipped the
  /// package differently all read the same way: the first section of type
  /// `openclash`.
  factory OpenClashConfig.fromUci(Map<String, dynamic> values) {
    final section = uciSections(values, 'openclash').firstOrNull?.value;
    if (section == null) return absent;

    final port = int.tryParse(uciText(section['cn_port']) ?? '');
    return OpenClashConfig(
      installed: true,
      enabledInConfig: uciBool(section['enable']),
      apiPort: port != null && port > 0 ? port : defaultApiPort,
      configPath: uciText(section['config_path']),
      secret: uciText(section['dashboard_password']),
      configuredMode: uciText(section['proxy_mode']),
      operationMode: uciText(section['operation_mode']),
    );
  }
}

/// One entry of the Clash `/proxies` map that groups other proxies.
///
/// `Selector`, `URLTest`, `Fallback` and `LoadBalance` all accept a `PUT`
/// naming the member to use; the type only decides how the default member is
/// chosen. Kept as the raw type string so the UI can say what it is without a
/// second mapping table that would drift from the core's.
@immutable
class OpenClashGroup {
  const OpenClashGroup({
    required this.name,
    required this.type,
    required this.members,
    this.now,
  });

  final String name;
  final String type;
  final List<String> members;

  /// The member currently selected or chosen by the strategy.
  final String? now;

  bool get isManual => type == 'Selector';

  /// Groups the core builds for itself. `GLOBAL` lists every proxy in the
  /// config and is not the group users mean when they switch nodes.
  static const Set<String> builtIn = {'GLOBAL', 'COMPATIBLE'};

  /// Parses the `/proxies` payload into the groups worth showing.
  ///
  /// Order is the core's, which is the config's: a user who arranged their
  /// groups deliberately should see that arrangement, not an alphabetical
  /// list that scrambles it.
  static List<OpenClashGroup> listFrom(Object? payload) {
    final proxies = payload is Map ? payload['proxies'] : null;
    if (proxies is! Map) return const [];

    final groups = <OpenClashGroup>[];
    for (final entry in proxies.entries) {
      final name = entry.key.toString();
      if (builtIn.contains(name)) continue;
      final value = entry.value;
      if (value is! Map) continue;
      final all = value['all'];
      if (all is! List || all.isEmpty) continue;

      groups.add(
        OpenClashGroup(
          name: name,
          type: value['type']?.toString() ?? '',
          members: [for (final member in all) member.toString()],
          now: value['now']?.toString(),
        ),
      );
    }
    return groups;
  }
}

/// Everything the OpenClash screen renders in one read.
@immutable
class OpenClashSnapshot {
  const OpenClashSnapshot({
    this.config = OpenClashConfig.absent,
    this.running = false,
    this.enabled = false,
    this.version,
    this.coreName,
    this.mode,
    this.mixedPort,
    this.uploadTotal = 0,
    this.downloadTotal = 0,
    this.activeConnections = 0,
    this.groups = const [],
    this.apiError,
  });

  final OpenClashConfig config;

  /// The core process is up, as the router's init system reports it.
  final bool running;

  /// The service starts at boot.
  final bool enabled;

  /// The core's own version, e.g. `alpha-gbc76c13`.
  final String? version;

  /// `Mihomo` or `Clash` — which core is installed. Null when unread.
  final String? coreName;

  /// The live mode: `rule`, `global` or `direct`.
  final String? mode;

  /// The live mixed port, when the core reports one.
  final int? mixedPort;

  final int uploadTotal;
  final int downloadTotal;
  final int activeConnections;
  final List<OpenClashGroup> groups;

  /// Why the dashboard could not be read, when the core is running but its
  /// API did not answer. Distinct from "stopped": a stopped core has no API
  /// to read, and saying "could not connect" there would be noise.
  final String? apiError;

  bool get installed => config.installed;

  /// The core is up and its API answered at least the version call.
  bool get dashboardLive => running && version != null;

  /// The mode to show: the live one, or the config's when the core is down.
  String? get effectiveMode => mode ?? config.configuredMode;

  /// A label for the core, e.g. `Mihomo alpha-gbc76c13`.
  String? get coreLabel {
    if (version == null) return null;
    return coreName == null ? version : '$coreName $version';
  }

  OpenClashSnapshot copyWith({
    bool? running,
    bool? enabled,
    String? mode,
    List<OpenClashGroup>? groups,
    String? apiError,
  }) => OpenClashSnapshot(
    config: config,
    running: running ?? this.running,
    enabled: enabled ?? this.enabled,
    version: version,
    coreName: coreName,
    mode: mode ?? this.mode,
    mixedPort: mixedPort,
    uploadTotal: uploadTotal,
    downloadTotal: downloadTotal,
    activeConnections: activeConnections,
    groups: groups ?? this.groups,
    apiError: apiError ?? this.apiError,
  );
}

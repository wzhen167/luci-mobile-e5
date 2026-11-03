import 'package:luci_mobile/models/cellular.dart';
import 'package:luci_mobile/models/uci_change.dart';
import 'package:luci_mobile/utils/uci_values.dart';

/// Reads and edits the cellular side of `/etc/config/network`.
///
/// Pure functions of already-fetched data, so the rules — which protocols
/// count as cellular, how a configured section is matched to its runtime
/// state, what an empty APN field means — are testable without a modem.
class CellularPlanner {
  const CellularPlanner._();

  /// The `proto` values that mean "this interface is a cellular modem".
  ///
  /// `ppp` is deliberately absent: PPPoE is the common DSL/dial-up protocol
  /// and would list every WAN connection as a modem. `3g` covers the legacy
  /// chat-based setup, `modemmanager` the newer stack, and the rest are the
  /// kernel-mode drivers.
  static const Set<String> cellularProtos = {
    'qmi',
    'mbim',
    '3g',
    'modemmanager',
    'ncm',
    'ndis',
    'rmnet',
    'wwan',
  };

  /// The `network` sections that are cellular interfaces, in config order.
  static List<CellularInterface> parse(Map<String, dynamic> network) {
    final out = <CellularInterface>[];
    for (final entry in uciSections(network, 'interface')) {
      final section = entry.value;
      final proto = uciText(section['proto']);
      if (proto == null || !cellularProtos.contains(proto)) continue;

      // `device`/`apn` are config-level; modemmanager keeps the APN 1:1 under
      // a `modemmanager` section in the same file, which this app does not
      // edit, so it stays null there rather than being guessed.
      //
      // The PDP type has two spellings in the wild: netifd's qmi/mbim protos
      // read `pdptype`, the Unisoc stack on mobile routers reads `iptype`.
      // Whichever the section already uses is remembered, so a save edits that
      // option instead of adding a second one that nothing reads.
      final ipType = uciText(section['iptype']);
      final pdpType = uciText(section['pdptype']);

      out.add(
        CellularInterface(
          section: entry.key,
          proto: proto,
          device: uciText(section['device']),
          apn: uciText(section['apn']),
          // Null when the option is absent — see [CellularInterface.apnAuto].
          apnAuto: section['apn_auto'] == null
              ? null
              : uciBool(section['apn_auto']),
          username: uciText(section['username']),
          hasPassword: uciText(section['password']) != null,
          pinSet: uciText(section['pincode']) != null,
          auth: uciText(section['auth']),
          pdpType: ipType ?? pdpType,
          pdpOption: ipType != null
              ? 'iptype'
              : pdpType != null
              ? 'pdptype'
              : null,
          metric: uciText(section['metric']),
          mtu: uciText(section['mtu']),
          disabled: uciBool(section['disabled']),
          defaultRoute: uciBool(section['defaultroute'], orElse: true),
        ),
      );
    }
    return out;
  }

  /// Attaches `network.interface dump` to the configured interfaces.
  ///
  /// Matched on the UCI section name, which is what `dump` reports as
  /// `interface`. A section the dump does not know about keeps its runtime
  /// fields empty and shows as configured-but-down; that is a real state, not
  /// an error.
  static List<CellularInterface> mergeRuntime(
    List<CellularInterface> configured,
    Map<String, dynamic>? dump,
  ) {
    final raw = dump?['interface'];
    if (raw is! List) return configured;

    final byName = <String, Map>{};
    for (final item in raw) {
      if (item is Map && item['interface'] != null) {
        byName[item['interface'].toString()] = item;
      }
    }

    return [
      for (final iface in configured) _mergeOne(iface, byName[iface.section]),
    ];
  }

  static CellularInterface _mergeOne(CellularInterface iface, Map? raw) {
    if (raw == null) return iface;

    List<String> addresses(Object? list) {
      if (list is! List) return const [];
      return [
        for (final entry in list)
          if (entry is Map && entry['address'] != null)
            entry['address'].toString(),
      ];
    }

    final data = raw['data'] is Map ? raw['data'] as Map : const {};
    final stats = raw['statistics'] is Map
        ? raw['statistics'] as Map
        : const {};
    int? bytes(Object? value) => value is num ? value.toInt() : null;

    return iface.copyWith(
      up: raw['up'] == true,
      uptimeSeconds: (raw['uptime'] as num?)?.toInt(),
      l3Device: raw['l3_device']?.toString() ?? raw['device']?.toString(),
      ipv4: addresses(raw['ipv4-address']),
      ipv6: addresses(raw['ipv6-address']),
      dns: [
        if (raw['dns-server'] is List)
          for (final s in raw['dns-server'] as List) s.toString(),
      ],
      rxBytes: bytes(data['rx_bytes']) ?? bytes(stats['rx_bytes']),
      txBytes: bytes(data['tx_bytes']) ?? bytes(stats['tx_bytes']),
    );
  }

  // -------------------------------------------------------------- planning

  /// The edits an APN form can make.
  ///
  /// A null field is untouched; an empty string removes the option. That
  /// distinction matters for `password` and `pincode`: leaving a stale
  /// credential in the config after the user cleared the field would keep
  /// authenticating with a password they believe they removed.
  static List<UciOperation> planApn({
    required CellularInterface existing,
    String? apn,
    String? username,
    String? password,
    String? pin,
    String? pdpType,
    String? mtu,
    String? metric,
    bool? disabled,
  }) {
    final values = <String, String>{};
    final removals = <String>[];

    void edit(String option, String? next, {String? current}) {
      if (next == null) return;
      if (next.isEmpty) {
        if (current != null) removals.add(option);
        return;
      }
      if (next != current) values[option] = next;
    }

    edit('apn', apn, current: existing.apn);
    edit('username', username, current: existing.username);
    // Written where it was read from: adding `pdptype` next to an existing
    // `iptype` produces a config the stack ignores, with no error anywhere.
    edit(existing.pdpOption ?? 'pdptype', pdpType, current: existing.pdpType);
    edit('mtu', mtu, current: existing.mtu);
    edit('metric', metric, current: existing.metric);

    // A section carrying `apn_auto` derives its APN from the SIM card and
    // ignores a configured one while the flag is still set. So a manual APN
    // has to clear the flag, and clearing the field is how the user asks for
    // auto back.
    if (existing.apnAuto != null) {
      if (apn != null && apn.isNotEmpty && existing.apnAuto == true) {
        values['apn_auto'] = '0';
      } else if (apn == '') {
        values['apn_auto'] = '1';
      }
    }

    // Credentials: the current value is never read back, so any non-null
    // input is treated as a replacement rather than compared.
    if (password != null) {
      if (password.isEmpty) {
        if (existing.hasPassword) removals.add('password');
      } else {
        values['password'] = password;
      }
    }
    if (pin != null) {
      if (pin.isEmpty) {
        if (existing.pinSet) removals.add('pincode');
      } else {
        values['pincode'] = pin;
      }
    }
    if (disabled != null && disabled != existing.disabled) {
      values['disabled'] = disabled ? '1' : '0';
    }

    return [
      if (values.isNotEmpty)
        UciSet('network', section: existing.section, values: values),
      for (final option in removals)
        UciRemove('network', section: existing.section, option: option),
    ];
  }

  /// Validation for the APN field.
  ///
  /// An empty APN is legal — some carriers derive it from the IMSI — but a
  /// value with whitespace is not, and netifd hands it to the modem verbatim
  /// where it fails with an error that says nothing about the space.
  static bool isValidApn(String value) =>
      value.isEmpty || value.trim() == value && !value.contains(RegExp(r'\s'));

  /// The PDP type values worth offering. `ipv4v6` first: it is what carriers
  /// increasingly require, and a v4-only setting silently loses IPv6.
  static const List<String> pdpTypes = ['ipv4v6', 'ipv4', 'ipv6'];
}

import 'package:luci_mobile/models/cellular.dart';
import 'package:luci_mobile/services/cellular_planner.dart';
import 'package:luci_mobile/services/interfaces/api_service_interface.dart';
import 'package:luci_mobile/services/sms_tool.dart';
import 'package:luci_mobile/state/router_session.dart';
import 'package:luci_mobile/utils/uci_values.dart';

/// Everything the Cellular section renders in one read.
class CellularSnapshot {
  const CellularSnapshot({
    this.interfaces = const [],
    this.telemetry,
    this.telemetryUnavailable = false,
    this.quota,
    this.sims = const [],
    this.dataSim,
    this.runtimeApn,
  });

  final List<CellularInterface> interfaces;

  /// Operator, technology and signal, when ModemManager answered.
  final CellularTelemetry? telemetry;

  /// The telemetry probe ran and produced nothing. Distinct from "not probed
  /// yet": the screen must say "install modemmanager" rather than showing a
  /// blank signal that reads as no reception.
  final bool telemetryUnavailable;

  /// Metered usage for the billing cycle, when the firmware keeps books.
  final CellularQuota? quota;

  /// The SIM slots the modem reports, in slot order.
  final List<SimSlot> sims;

  /// The slot currently carrying data.
  final int? dataSim;

  /// The APN the interface actually came up with, when the router knows it.
  ///
  /// A section with `apn_auto` set has no `apn` option at all — the carrier
  /// supplies one — so reading the config alone would show "APN not set" on a
  /// connection that is working fine. This is the runtime answer, kept
  /// separate from the config so that saving the form cannot silently turn a
  /// carrier-chosen APN into a hard-coded one.
  final String? runtimeApn;

  bool get isEmpty => interfaces.isEmpty;

  /// The device to hand to `sms-tool`.
  ///
  /// The conventional AT port on a Quectel-style module is
  /// [SmsTool.defaultDevice]; the SMS tab lets the user change it when the
  /// module numbers its ports differently (a Unisoc router uses
  /// `/dev/wwan0at0`, and its own vendor SMS service instead of this tool).
  String get suggestedSmsDevice {
    for (final iface in interfaces) {
      final device = iface.device;
      if (device != null && device.startsWith('/dev/tty')) return device;
    }
    return defaultSmsDevice;
  }

  static const String defaultSmsDevice = SmsTool.defaultDevice;
}

/// Reads cellular state from the router.
///
/// Three sources, each optional on its own: the `network` config (always
/// readable), `network.interface dump` (the runtime state), and ModemManager's
/// ubus backend (radio telemetry). None of them is required for the section to
/// render — a router with a modem but no ModemManager still lists and
/// configures its interface, and says plainly which part it could not read.
class CellularService {
  CellularService(this._api);

  final IApiService _api;

  Future<CellularSnapshot> read(RouterSession session) async {
    final network = await uciConfigValues(_api, session, 'network');
    final configured = CellularPlanner.parse(network);
    if (configured.isEmpty) {
      return const CellularSnapshot();
    }

    Map<String, dynamic>? dump;
    try {
      dump = await _interfaceDump(session);
    } catch (_) {
      // A missing dump only means "up/down unknown"; the configured APN is
      // still worth showing.
      dump = null;
    }

    // Status first: it names the slot carrying data, and the vendor telemetry
    // below has to be asked for that same slot.
    final status = await _e5Status(session);
    final telemetry = await _telemetry(session, slot: _activeSim(status) ?? 0);

    return CellularSnapshot(
      interfaces: CellularPlanner.mergeRuntime(configured, dump),
      telemetry: telemetry.value,
      telemetryUnavailable: telemetry.probed && telemetry.value == null,
      quota: CellularQuota.fromE5Traffic(_info(status)?['traffic']),
      sims: SimSlot.listFrom(_modemStatus(status)?['sims']),
      dataSim: _activeSim(status),
      runtimeApn: _wan(status)?['apn']?.toString(),
    );
  }

  Future<Map<String, dynamic>?> _interfaceDump(RouterSession session) =>
      _callUbus(session, 'network.interface', 'dump');

  /// `ubus call e5status status`, the vendor status object on E5-class mobile
  /// routers.
  ///
  /// Answers three things no standard interface does: the metered data
  /// accounting for the billing cycle, the physical SIM slots, and the APN the
  /// carrier supplied. Absent on anything else — then every field it feeds
  /// stays null and the section shows what the standard objects report.
  Future<Map<String, dynamic>?> _e5Status(RouterSession session) async {
    Map<String, dynamic>? data;
    var slot = 0;
    // The answer for any slot still names the slot carrying data, so on a
    // dual-SIM router one follow-up call gets the numbers that matter.
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        data = await _callUbus(session, 'e5status', 'status', {
          'slot': '$slot',
        });
      } catch (_) {
        return null;
      }
      if (data == null) return null;
      final active = _activeSim(data);
      if (active == null || active == slot) break;
      slot = active;
    }
    return data;
  }

  static Map? _info(Map<String, dynamic>? status) {
    final info = status?['info'];
    return info is Map ? info : null;
  }

  static Map? _modemStatus(Map<String, dynamic>? status) {
    final modem = _info(status)?['modem'];
    return modem is Map ? modem : null;
  }

  static Map? _wan(Map<String, dynamic>? status) {
    final wan = _info(status)?['wan'];
    return wan is Map ? wan : null;
  }

  static int? _activeSim(Map<String, dynamic>? status) {
    final sim = _modemStatus(status)?['data_sim'];
    return sim is num ? sim.toInt() : null;
  }

  /// One ubus call, or null when the object answers with an error status.
  ///
  /// Throws on transport failure so each caller decides whether "could not
  /// ask" or "answered with nothing" is the more useful reading.
  Future<Map<String, dynamic>?> _callUbus(
    RouterSession session,
    String object,
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    final result = await _api.call(
      session.ipAddress,
      session.sysauth,
      session.useHttps,
      object: object,
      method: method,
      params: params,
    );
    if (result is! List || result.isEmpty || result.first != 0) return null;
    final data = result.length > 1 ? result[1] : null;
    return data is Map ? Map<String, dynamic>.from(data) : null;
  }

  /// Radio telemetry, from ModemManager or from the vendor status object.
  ///
  /// The backend ships inside the `modemmanager` package (OpenWrt 23.05+), but
  /// reading it also needs an ACL grant, so both "not installed" and "not
  /// permitted" arrive here as the same unusable answer. Mobile-router
  /// firmware commonly has the package without granting its `info` method,
  /// which is why the vendor object is tried as a second source rather than
  /// treated as a fallback for exotic hardware.
  ///
  /// [probed] records that the attempt was made, which is what lets the UI
  /// distinguish "couldn't read" from "not asked" — and it is false only when
  /// nothing was attempted, never when both sources came back empty.
  Future<({bool probed, CellularTelemetry? value})> _telemetry(
    RouterSession session, {
    int slot = 0,
  }) async {
    CellularTelemetry? value;
    try {
      value = telemetryFrom(await _callUbus(session, 'modemmanager', 'info'));
    } catch (_) {
      value = null;
    }

    if (value == null) {
      try {
        value = CellularTelemetry.fromE5Cell(
          await _callUbus(session, 'e5status', 'cells', {'slot': '$slot'}),
        );
      } catch (_) {
        // Neither source answered; the UI says so plainly.
      }
    }

    return (probed: true, value: value);
  }

  /// Pulls the first modem out of an `info` or `dump` payload.
  ///
  /// `info` answers `{"modem": [{...}]}`; `dump` nests the same fields under
  /// `generic`, and older builds answer a bare object. All three are accepted
  /// because the backend has changed shape between package releases.
  static CellularTelemetry? telemetryFrom(Object? payload) {
    if (payload is! Map) return null;
    final raw = payload['modem'];
    Map? first;
    if (raw is List) {
      first = raw.whereType<Map>().firstOrNull;
    } else if (raw is Map) {
      first = raw;
    } else if (payload['generic'] is Map) {
      first = payload;
    }
    if (first == null) return null;

    final generic = first['generic'] is Map
        ? Map<String, dynamic>.from(first['generic'] as Map)
        : <String, dynamic>{};

    // `dump` keeps signal under `generic.signal-quality.value`; `info` puts a
    // flat `signal` next to the operator.
    final quality = generic['signal-quality'] is Map
        ? (generic['signal-quality'] as Map)['value']
        : null;

    final merged = <String, dynamic>{
      ...generic,
      ...Map<String, dynamic>.from(first),
      'signal': ?quality,
    };

    final telemetry = CellularTelemetry.fromModemManager(merged);
    return telemetry.isEmpty ? null : telemetry;
  }
}

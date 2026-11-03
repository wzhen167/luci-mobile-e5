import 'package:flutter/foundation.dart';

/// One `network` interface whose protocol is a cellular one.
///
/// The model merges two sources, because neither answers on its own: the UCI
/// section holds the configuration (APN, PIN, device) and `network.interface
/// dump` holds whether it is up, for how long, and how much it moved. A
/// section with no runtime counterpart is a configured-but-down modem, which
/// is a state worth showing rather than hiding.
@immutable
class CellularInterface {
  const CellularInterface({
    required this.section,
    required this.proto,
    this.device,
    this.apn,
    this.apnAuto,
    this.username,
    this.hasPassword = false,
    this.pinSet = false,
    this.auth,
    this.pdpType,
    this.pdpOption,
    this.metric,
    this.mtu,
    this.disabled = false,
    this.defaultRoute = false,
    this.up = false,
    this.uptimeSeconds,
    this.l3Device,
    this.ipv4 = const [],
    this.ipv6 = const [],
    this.dns = const [],
    this.rxBytes,
    this.txBytes,
  });

  /// The UCI section name, e.g. `wwan`.
  final String section;

  /// `qmi`, `mbim`, `3g`, `modemmanager`, `ncm`, `ndis` or `rmnet`.
  final String proto;

  /// The control device, e.g. `/dev/cdc-wdm0` or `/dev/ttyUSB2`.
  final String? device;

  final String? apn;

  /// The `apn_auto` option, when the section has one.
  ///
  /// Null means the option is absent, which is not the same as false: on a
  /// vendor stack (Unisoc/modemmanager) the APN is filled in by the carrier,
  /// and writing an `apn` without clearing `apn_auto` leaves the interface
  /// still ignoring it. The distinction is what lets [CellularPlanner.planApn]
  /// clear the flag instead of writing into a void.
  final bool? apnAuto;

  final String? username;

  /// Whether a password is configured. The value itself is never carried into
  /// the UI: it is a carrier credential, and showing it on a phone screen adds
  /// nothing to the task of editing an APN.
  final bool hasPassword;

  /// Whether a SIM PIN is configured — likewise without the value.
  final bool pinSet;

  final String? auth;

  final String? pdpType;

  /// The UCI option [pdpType] was read from: `iptype` or `pdptype`.
  ///
  /// Both spellings exist in the wild — netifd's qmi/mbim protos read
  /// `pdptype`, while the Unisoc stack used by mobile routers reads `iptype`
  /// — and writing the other one silently does nothing. Null when the section
  /// carries neither, in which case the writer falls back to `pdptype`.
  final String? pdpOption;

  final String? metric;
  final String? mtu;
  final bool disabled;
  final bool defaultRoute;

  /// Runtime state, from `network.interface dump`.
  final bool up;
  final int? uptimeSeconds;
  final String? l3Device;
  final List<String> ipv4;
  final List<String> ipv6;
  final List<String> dns;
  final int? rxBytes;
  final int? txBytes;

  /// What to call this interface in a list: the APN is what a user recognises,
  /// the section name is what a fallback has to be.
  String get label => apn?.isNotEmpty == true ? apn! : section;

  /// A modem that is configured but not connected. Distinct from a disabled
  /// one, which the user turned off on purpose.
  bool get idle => !up && !disabled;

  CellularInterface copyWith({
    bool? up,
    int? uptimeSeconds,
    String? l3Device,
    List<String>? ipv4,
    List<String>? ipv6,
    List<String>? dns,
    int? rxBytes,
    int? txBytes,
  }) => CellularInterface(
    section: section,
    proto: proto,
    device: device,
    apn: apn,
    apnAuto: apnAuto,
    username: username,
    hasPassword: hasPassword,
    pinSet: pinSet,
    auth: auth,
    pdpType: pdpType,
    pdpOption: pdpOption,
    metric: metric,
    mtu: mtu,
    disabled: disabled,
    defaultRoute: defaultRoute,
    up: up ?? this.up,
    uptimeSeconds: uptimeSeconds ?? this.uptimeSeconds,
    l3Device: l3Device ?? this.l3Device,
    ipv4: ipv4 ?? this.ipv4,
    ipv6: ipv6 ?? this.ipv6,
    dns: dns ?? this.dns,
    rxBytes: rxBytes ?? this.rxBytes,
    txBytes: txBytes ?? this.txBytes,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CellularInterface &&
          other.section == section &&
          other.proto == proto &&
          other.device == device &&
          other.apn == apn &&
          other.apnAuto == apnAuto &&
          other.username == username &&
          other.hasPassword == hasPassword &&
          other.pinSet == pinSet &&
          other.auth == auth &&
          other.pdpType == pdpType &&
          other.pdpOption == pdpOption &&
          other.metric == metric &&
          other.mtu == mtu &&
          other.disabled == disabled &&
          other.defaultRoute == defaultRoute &&
          other.up == up &&
          other.uptimeSeconds == uptimeSeconds &&
          other.l3Device == l3Device &&
          listEquals(other.ipv4, ipv4) &&
          listEquals(other.ipv6, ipv6) &&
          listEquals(other.dns, dns) &&
          other.rxBytes == rxBytes &&
          other.txBytes == txBytes;

  @override
  int get hashCode => Object.hash(
    // Object.hash takes at most 20 arguments, and this model has more
    // fields than that; the two halves are combined rather than dropped.
    Object.hash(
      section,
      proto,
      device,
      apn,
      apnAuto,
      username,
      hasPassword,
      pinSet,
      auth,
      pdpType,
      pdpOption,
      metric,
    ),
    Object.hash(
      mtu,
      disabled,
      defaultRoute,
      up,
      uptimeSeconds,
      l3Device,
      ipv4.join(','),
      ipv6.join(','),
      dns.join(','),
      rxBytes,
      txBytes,
    ),
  );

  @override
  String toString() =>
      'CellularInterface($section, proto: $proto, up: $up, apn: $apn)';
}

/// Radio-level facts that no UCI config and no netifd dump can answer:
/// operator, access technology and signal.
///
/// Read from ModemManager's ubus backend (`ubus call modemmanager info`),
/// which is part of the `modemmanager` package from OpenWrt 23.05 on. When
/// that backend is absent the interface list still works and these fields
/// stay null — the screen says "not available" rather than "no signal",
/// because the two are different problems with different fixes.
@immutable
class CellularTelemetry {
  const CellularTelemetry({
    this.modem,
    this.operatorName,
    this.technology,
    this.signalPercent,
    this.measuredDbm,
    this.sinr,
    this.band,
    this.model,
    this.imei,
    this.iccid,
    this.imsi,
    this.registrationState,
  });

  /// ModemManager's own id (`Modem1` / `/org/.../Modem/0`), as reported.
  final String? modem;

  final String? operatorName;

  /// `lte`, `nr5g`, `umts`, `gsm`, … — ModemManager's spelling, shown as-is
  /// uppercased because every carrier calls these something else.
  final String? technology;

  /// Signal quality 0-100, as ModemManager reports it.
  final int? signalPercent;

  /// The receiver's own measurement, in dBm, when the backend reports one.
  ///
  /// ModemManager only reports quality; vendor backends (Unisoc's `e5status`)
  /// report RSRP directly. A measured figure beats a derived one, so this
  /// takes precedence in [approximateDbm] and is labelled as measured
  /// wherever it is shown.
  final int? measuredDbm;

  /// Signal-to-noise ratio in dB, when reported. Negative values are normal
  /// and still usable; this is a measurement, not a percentage.
  final double? sinr;

  /// The radio band the modem is camped on (LTE/NR band number).
  final int? band;

  final String? model;
  final String? imei;
  final String? iccid;
  final String? imsi;
  final String? registrationState;

  /// An approximate dBm for the quality percentage.
  ///
  /// ModemManager reports quality, not dBm, and the 3GPP mapping onto the
  /// -113..-51 dBm ladder is a convention rather than a measurement. It is
  /// labelled approximate wherever it is shown, so nobody reads it as a
  /// measured RSSI. When [measuredDbm] is present that value is returned
  /// instead, and [hasMeasuredSignal] tells the UI which of the two it got.
  int? get approximateDbm {
    final measured = measuredDbm;
    if (measured != null) return measured;
    final percent = signalPercent;
    if (percent == null) return null;
    return -113 + (2 * percent.clamp(0, 100));
  }

  /// Whether [approximateDbm] came from a receiver measurement rather than
  /// from the quality percentage.
  bool get hasMeasuredSignal => measuredDbm != null;

  /// The bars to draw, 0-4.
  ///
  /// Measured dBm wins when present, on the RSRP ladder the modem itself
  /// uses: -44 dBm is a perfect cell, -140 dBm is no service. The percentage
  /// path is the same convention as [approximateDbm].
  int get bars {
    final measured = measuredDbm;
    if (measured != null) {
      final strength = ((measured + 140) / 96 * 4).ceil();
      return strength.clamp(0, 4);
    }
    final percent = signalPercent;
    if (percent == null) return 0;
    return (percent.clamp(0, 100) / 25).ceil();
  }

  /// [technology] as a user-facing generation label.
  ///
  /// ModemManager reports `5gnr`, `lte`, `umts`, … — accurate, and meaningless
  /// to most people staring at a signal bar. Unknown values fall through to
  /// the raw string uppercased, which is still better than hiding them: a new
  /// generation should show up as itself, not as a blank.
  String? get technologyLabel {
    final raw = technology?.toLowerCase();
    if (raw == null || raw.isEmpty) return null;
    return switch (raw) {
      '5gnr' || 'nr5g' || 'nr' || '5g' => '5G NR',
      '5gnsa' || '5g-nsa' => '5G NSA',
      'lte' || 'lte-a' || '4g' => '4G LTE',
      'umts' || 'hspa' || 'hsdpa' || 'hsupa' || '3g' => '3G',
      'edge' || 'gprs' || 'gsm' || '2g' => '2G',
      _ => raw.toUpperCase(),
    };
  }

  bool get isEmpty =>
      operatorName == null &&
      technology == null &&
      signalPercent == null &&
      measuredDbm == null &&
      model == null &&
      imei == null &&
      iccid == null &&
      imsi == null &&
      registrationState == null;

  static CellularTelemetry fromModemManager(Map<String, dynamic> modem) {
    int? percent(dynamic raw) {
      if (raw is num) return raw.toInt();
      if (raw is String) {
        // `info` reports the quality as a string ("47"); `dump` nests it as
        // `signal-quality.value`, also a string.
        return int.tryParse(raw.trim());
      }
      return null;
    }

    String? text(dynamic raw) {
      final value = raw?.toString().trim();
      if (value == null || value.isEmpty || value == '--') return null;
      return value;
    }

    return CellularTelemetry(
      modem: text(modem['device']),
      operatorName: text(modem['operator']),
      technology: text(modem['technology']),
      signalPercent: percent(modem['signal']),
      model: text(modem['model']) ?? text(modem['manufacturer']),
      imei: text(modem['imei']),
      iccid: text(modem['iccid']),
      imsi: text(modem['imsi']),
      registrationState:
          text(modem['registration-state']) ?? text(modem['state']),
    );
  }

  /// Reads Unisoc's `e5status cells` answer, the telemetry source on E5-class
  /// mobile routers.
  ///
  /// Such a router ships ModemManager as the *protocol* but not the `info`
  /// ubus backend — `modemmanager info` answers "Access denied" there while
  /// this object carries the same facts, and better ones: RSRP/RSRQ/SINR are
  /// receiver measurements rather than a derived quality percentage, and the
  /// operator arrives in the SIM's own language.
  ///
  /// Returns null when the payload holds no cell — an empty `info: null`
  /// answer means the modem is not camped on anything.
  static CellularTelemetry? fromE5Cell(Object? payload) {
    if (payload is! Map) return null;
    final cell = payload['cell'];
    if (cell is! Map) return null;

    final operator = cell['operator'] is Map
        ? cell['operator'] as Map
        : const <dynamic, dynamic>{};
    final sig = cell['sig'] is Map ? cell['sig'] as Map : const {};
    // `reg` is the serving cell; `reg5g` repeats it for the NR leg of an
    // NSA connection and carries the 5G access-technology code.
    final reg = cell['sig_src'] == 'nr' && cell['reg5g'] is Map
        ? cell['reg5g'] as Map
        : (cell['reg'] is Map ? cell['reg'] as Map : const {});

    String? text(Object? raw) {
      final value = raw?.toString().trim();
      if (value == null || value.isEmpty || value == '--') return null;
      return value;
    }

    double? number(Object? raw) {
      if (raw is num) return raw.toDouble();
      if (raw is String) return double.tryParse(raw.trim());
      return null;
    }

    final rsrp = number(sig['rsrp']);
    final act = number(reg['act']) ?? number(operator['act']);
    final band = number(sig['band']);

    final telemetry = CellularTelemetry(
      operatorName: text(operator['name']),
      technology: _technologyForAct(act),
      // The same -44..-140 dBm RSRP ladder the bars use, as a percentage, so
      // that a backend reporting RSRP and one reporting quality produce
      // comparable numbers on the same screen.
      signalPercent: rsrp == null
          ? null
          : ((rsrp + 140) / 96 * 100).round().clamp(0, 100),
      measuredDbm: rsrp?.round(),
      sinr: number(sig['sinr']),
      band: band?.round(),
    );
    return telemetry.isEmpty ? null : telemetry;
  }

  /// 3GPP TS 27.007 `AcT` code -> the spelling [technologyLabel] understands.
  ///
  /// Left null for codes this app does not know, which renders as "no
  /// generation" rather than as an invented one.
  static String? _technologyForAct(double? act) {
    if (act == null) return null;
    return switch (act.round()) {
      1 || 2 || 4 => 'gsm',
      3 || 5 || 6 || 7 => 'umts',
      8 || 9 || 10 => 'lte',
      11 => 'nr5g',
      12 || 13 => '5gnsa',
      _ => null,
    };
  }
}

/// The monthly data allowance, as the router's own accounting reports it.
///
/// A mobile router is metered, so "how much is left" is the single most useful
/// number on the screen — more so than a live rate. Not every firmware does
/// this bookkeeping; when it does not, the section simply omits the card
/// instead of inventing a zero.
@immutable
class CellularQuota {
  const CellularQuota({
    this.usedBytes,
    this.limitBytes,
    this.remainingBytes,
    this.todayBytes,
    this.cycleStart,
    this.cycleEnd,
    this.overLimit = false,
  });

  /// Usage in the current billing cycle.
  final int? usedBytes;

  /// The plan's allowance, when one is configured on the router.
  final int? limitBytes;

  final int? remainingBytes;
  final int? todayBytes;

  /// `YYYY-MM-DD` strings, exactly as reported — the cycle is the carrier's,
  /// not a calendar month, so it is shown rather than assumed.
  final String? cycleStart;
  final String? cycleEnd;

  final bool overLimit;

  bool get isEmpty =>
      usedBytes == null && limitBytes == null && todayBytes == null;

  /// Used / allowance, 0-1, for a progress bar. Null when there is no limit.
  double? get usedFraction {
    final used = usedBytes;
    final limit = limitBytes;
    if (used == null || limit == null || limit <= 0) return null;
    return (used / limit).clamp(0.0, 1.0);
  }

  /// Reads `info.traffic` out of an `e5status status` answer.
  ///
  /// Measured shape:
  /// `{today:{rx,tx}, month:{rx,tx}, today_used, cycle_used, monthly_limit,
  /// remaining, cycle_start, cycle_end, over_limit}`.
  static CellularQuota? fromE5Traffic(Object? traffic) {
    if (traffic is! Map) return null;
    int? bytes(Object? value) {
      if (value is num) return value.toInt();
      return int.tryParse(value?.toString() ?? '');
    }

    final quota = CellularQuota(
      usedBytes: bytes(traffic['cycle_used']) ?? bytes(traffic['month_used']),
      limitBytes: bytes(traffic['monthly_limit']),
      remainingBytes: bytes(traffic['remaining']),
      todayBytes: bytes(traffic['today_used']),
      cycleStart: traffic['cycle_start']?.toString(),
      cycleEnd: traffic['cycle_end']?.toString(),
      overLimit: traffic['over_limit'] == true,
    );
    return quota.isEmpty ? null : quota;
  }
}

/// One physical SIM slot, as the modem reports it.
///
/// A dual-SIM router needs this to answer "which card is carrying my data" —
/// and `absent` is a normal state (an empty second slot), not an error.
@immutable
class SimSlot {
  const SimSlot({required this.slot, required this.state});

  final int slot;

  /// `ready`, `absent`, … — the firmware's own word.
  final String state;

  bool get present => state != 'absent';

  static List<SimSlot> listFrom(Object? sims) {
    if (sims is! List) return const [];
    return [
      for (final entry in sims)
        if (entry is Map && entry['slot'] is num)
          SimSlot(
            slot: (entry['slot'] as num).toInt(),
            state: entry['state']?.toString() ?? 'unknown',
          ),
    ];
  }
}

/// One message in the modem's storage, as the router reports it.
///
/// Two services answer here and they address messages differently: `sms-tool`
/// by storage index, the vendor `e5-sms` object by an opaque 64-bit id. Both
/// are carried — [index] for the tool, [id] for the vendor — so a delete goes
/// to the right one without the screen having to know which backend it is
/// talking to.
@immutable
class SmsMessage {
  const SmsMessage({
    required this.index,
    this.id,
    this.sim,
    this.card,
    this.sender,
    this.timestamp,
    this.body = '',
    this.unread = false,
  });

  /// Storage index — what `sms-tool` read/delete take.
  ///
  /// For a vendor backend there is no such index, so this holds the id parsed
  /// as a number; [id] stays authoritative there.
  final int index;

  /// The vendor backend's message id, when it has one.
  final String? id;

  /// SIM name the message sits on (`SIM1`), when the router reports it.
  final String? sim;

  /// SIM slot number, when the router reports it.
  final int? card;

  final String? sender;

  /// The modem's own timestamp string. Not parsed into a [DateTime]: the
  /// formats differ per firmware and a wrong parse is worse than the original
  /// text, which the user can still read.
  final String? timestamp;

  final String body;

  final bool unread;

  /// [timestamp] in a shape a phone screen can hold.
  ///
  /// The vendor backend reports RFC 3339 (`2026-11-03T10:04:23+08:00`), which
  /// is 25 characters of noise in a list row; `sms-tool` reports its own
  /// `26/11/02,09:14:22+04`, which is left alone because re-formatting a
  /// string we did not parse would be guessing.
  String? get displayTime {
    final raw = timestamp;
    if (raw == null || raw.isEmpty) return null;
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return raw;
    final local = parsed.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  /// One entry of `ubus call e5-sms list` → `messages[]`.
  ///
  /// Measured shape: `{id, card, sim, number, text, time, state, direction,
  /// unread}`. `id` is a 64-bit counter shared with the router's own SMS app,
  /// which is why it is kept as a string rather than assumed to fit a small
  /// number.
  static SmsMessage fromE5(Map<String, dynamic> raw) {
    final id = raw['id']?.toString();
    final card = raw['card'] is num ? (raw['card'] as num).toInt() : null;
    return SmsMessage(
      index: int.tryParse(id ?? '') ?? 0,
      id: id,
      card: card,
      sim: raw['sim']?.toString(),
      sender: raw['number']?.toString(),
      timestamp: raw['time']?.toString(),
      body: raw['text']?.toString() ?? '',
      unread: raw['unread'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SmsMessage &&
          other.index == index &&
          other.id == id &&
          other.sim == sim &&
          other.card == card &&
          other.sender == sender &&
          other.timestamp == timestamp &&
          other.body == body &&
          other.unread == unread;

  @override
  int get hashCode =>
      Object.hash(index, id, sim, card, sender, timestamp, body, unread);

  @override
  String toString() => 'SmsMessage($index, $sender, unread: $unread)';
}

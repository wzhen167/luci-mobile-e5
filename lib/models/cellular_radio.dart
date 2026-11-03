import 'package:flutter/foundation.dart';

/// The cell the modem is camped on, as `e5status cells` reports it.
///
/// A cell lock needs the pair the modem itself uses — channel and physical
/// cell id — not a name. Reading them from the live signal means the lock is
/// "stay where I am", which is what the user actually wants; asking them to
/// type an ARFCN and a PCI would be asking them to copy numbers off the same
/// screen.
@immutable
class ServingCell {
  const ServingCell({
    required this.rat,
    required this.channel,
    required this.pci,
    this.band,
  });

  /// `nr` or `lte`.
  final String rat;

  /// ARFCN on 5G, EARFCN on LTE.
  final int channel;

  /// Physical cell identity.
  final int pci;

  final int? band;

  /// The `val` the vendor's `cell` lock expects.
  String get lockValue => '$rat:$channel,$pci';

  bool get isNr => rat == 'nr';

  /// From an `e5status cells` answer.
  ///
  /// The object carries one block per RAT plus `sig_src`, which names the one
  /// the signal figures came from — so the pair to lock to is the block that
  /// produced the numbers on screen, not whichever one happens to be first.
  static ServingCell? fromE5Cells(Object? payload) {
    if (payload is! Map) return null;
    final cell = payload['cell'];
    if (cell is! Map) return null;

    final source = cell['sig_src']?.toString();
    final order = source == 'lte' ? const ['lte', 'nr'] : const ['nr', 'lte'];
    for (final rat in order) {
      final block = cell[rat];
      if (block is! Map) continue;
      final parsed = _parse(rat, block);
      if (parsed != null) return parsed;
    }
    // Older firmware answers a single flat `sig` with no per-RAT blocks.
    final flat = cell['sig'];
    if (flat is Map) {
      return _parse(source == 'lte' ? 'lte' : 'nr', flat);
    }
    return null;
  }

  static ServingCell? _parse(String rat, Map block) {
    final channel = _asInt(block['arfcn'] ?? block['earfcn']);
    final pci = _asInt(block['pci']);
    if (channel == null || pci == null) return null;
    return ServingCell(
      rat: rat,
      channel: channel,
      pci: pci,
      band: _asInt(block['band']),
    );
  }
}

/// Live network-lock state plus the two switches beside it.
///
/// All of it comes from the vendor's `mu300dash` ubus object, which is the
/// same backend the router's own dashboard drives. Reading it here rather
/// than issuing AT commands means the app sees the modem's verified state,
/// not what the last write hoped for.
@immutable
class CellularRadioState {
  const CellularRadioState({
    this.mode = '',
    this.lteLocked = const [],
    this.nrLocked = const [],
    this.lteCaps = const [],
    this.nrCaps = const [],
    this.lockedCells = const [],
    this.autoApply = true,
    this.dataUp,
    this.dataSim,
    this.radioEnabled = const [],
    this.serving,
  });

  /// The vendor's mode label: `auto`, `5g4g`, `4g`, `sa`, `nsa`, `auto-nsa`,
  /// `4g-nsa`, `sa-nsa`, or `unknown` when the readback matched no entry.
  final String mode;

  /// Bands the modem is currently restricted to. Empty means no LTE lock.
  final List<int> lteLocked;

  /// Same for 5G. Empty means no NR lock.
  final List<int> nrLocked;

  /// Bands this modem can tune, from its own capability readback.
  final List<int> lteCaps;
  final List<int> nrCaps;

  /// Locked cells, in the vendor's `lte:earfcn,pci` / `nr:arfcn,pci` form.
  final List<String> lockedCells;

  /// Whether the router reapplies saved locks when the modem comes back up.
  final bool autoApply;

  /// Whether the data interface is up. Null when the router would not say.
  final bool? dataUp;

  /// The slot carrying data.
  final int? dataSim;

  /// Per-slot RF policy, in slot order.
  final List<bool> radioEnabled;

  /// What "lock to the current cell" would lock to.
  final ServingCell? serving;

  /// The eight modes the vendor modem distinguishes.
  static const List<String> modes = [
    'auto',
    '5g4g',
    '4g',
    'sa',
    'nsa',
    'auto-nsa',
    '4g-nsa',
    'sa-nsa',
  ];

  bool get hasBandLock => lteLocked.isNotEmpty || nrLocked.isNotEmpty;

  bool get hasCellLock => lockedCells.isNotEmpty;

  /// Bands to offer as chips: what the modem supports, plus anything it is
  /// currently locked to.
  ///
  /// The two are not the same set. A profile can lock a band the capability
  /// list omits — this E5 reports LTE b7 and b20 as locked while its configured
  /// support list stops at b41 — and showing only the capability list would
  /// render those locks as unchecked, so saving any other change would
  /// silently drop them.
  List<int> get lteChoices => _union(lteCaps, lteLocked);

  List<int> get nrChoices => _union(nrCaps, nrLocked);

  bool radioEnabledFor(int slot) =>
      slot >= 0 && slot < radioEnabled.length && radioEnabled[slot];

  static List<int> _union(List<int> a, List<int> b) =>
      ({...a, ...b}.toList()..sort());

  /// From `mu300dash lock_get`, plus `sim_get` and `e5status cells`.
  ///
  /// The last two are optional: a lock readback without them still fills the
  /// lock rows, and the switches simply report "unknown" rather than a
  /// default that could be wrong.
  factory CellularRadioState.fromPayload({
    required Map<String, dynamic> lock,
    Map<String, dynamic>? sim,
    Map<String, dynamic>? cells,
  }) {
    final mode = lock['mode'];
    final lte = lock['lte'];
    final nr = lock['nr'];
    final caps = lock['caps'];

    return CellularRadioState(
      mode: mode is Map ? (mode['label']?.toString() ?? '') : '',
      lteLocked: _bands(lte),
      nrLocked: _bands(nr),
      lteCaps: _bands(caps, key: 'lte'),
      nrCaps: _bands(caps, key: 'nr'),
      lockedCells: _strings(lock['cells']),
      autoApply: _bool(lock['auto_apply']) ?? true,
      dataUp: _bool(sim?['data_up']),
      dataSim: _asInt(sim?['data_sim']),
      radioEnabled: [
        for (final value in _list(sim?['radio_enabled'])) _bool(value) ?? false,
      ],
      serving: ServingCell.fromE5Cells(cells),
    );
  }

  static List<dynamic> _list(Object? value) =>
      value is List ? value : const <dynamic>[];

  static List<int> _bands(Object? value, {String? key}) {
    final source = key == null ? value : (value is Map ? value[key] : null);
    final raw = source is Map ? source['locked'] : source;
    if (raw is List) {
      return [for (final band in raw) ?_asInt(band)]..sort();
    }
    if (raw is String) {
      return [for (final part in raw.split(',')) ?_asInt(part)]..sort();
    }
    return const [];
  }

  static List<String> _strings(Object? value) => [
    for (final entry in _list(value))
      if (entry is String && entry.isNotEmpty) entry,
  ];

  static bool? _bool(Object? value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      if (value == 'true' || value == '1') return true;
      if (value == 'false' || value == '0') return false;
    }
    return null;
  }
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

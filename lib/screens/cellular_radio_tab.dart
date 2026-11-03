import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:luci_mobile/design/luci_design_system.dart';
import 'package:luci_mobile/l10n/failure_text.dart';
import 'package:luci_mobile/l10n/luci_localizations.dart';
import 'package:luci_mobile/models/cellular_radio.dart';
import 'package:luci_mobile/services/cellular_radio.dart';
import 'package:luci_mobile/state/cellular_providers.dart';
import 'package:luci_mobile/state/cellular_radio_providers.dart';

/// Everything about the radio that is not the APN: whether it transmits, what
/// it is allowed to register on, and whether data flows.
///
/// These controls live together because they are the same decision seen from
/// different sides. Locking to one band on a weak cell, turning the radio off
/// to save power, and bringing data back up are the three moves a mobile-router
/// user makes in that order, and a lock change restarts the radio — so the
/// switch that says whether the radio is even on belongs on the same page.
class CellularRadioTab extends ConsumerStatefulWidget {
  const CellularRadioTab({required this.state, super.key});

  final CellularRadioState state;

  @override
  ConsumerState<CellularRadioTab> createState() => _CellularRadioTabState();
}

class _CellularRadioTabState extends ConsumerState<CellularRadioTab> {
  bool _busy = false;

  /// The data state the user just asked for, held until the router agrees.
  ///
  /// `ifup` returns as soon as netifd accepts it, while the bearer takes tens
  /// of seconds to come up — so an immediate re-read still says "down" and
  /// would flip the switch back under the user's finger on a command that is
  /// in fact working.
  bool? _requestedData;

  @override
  void didUpdateWidget(covariant CellularRadioTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_requestedData != null && widget.state.dataUp == _requestedData) {
      _requestedData = null;
    }
  }

  Future<bool> _run(
    Future<void> Function() action, {
    String? done,
    bool reconnects = false,
  }) async {
    if (_busy) return false;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    var succeeded = true;
    try {
      await action();
      if (done != null && mounted) {
        messenger.showSnackBar(SnackBar(content: Text(done)));
      }
      if (reconnects) _settle();
    } catch (error) {
      succeeded = false;
      // A rejected write is reported here rather than rethrown: the tap that
      // started it is gone, so an unhandled error would surface as a red
      // screen instead of the sentence the modem sent back.
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text(_explain(error))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    return succeeded;
  }

  /// Reads the router once more after a radio cycle.
  ///
  /// A lock change restarts the modem. The backend reports the job done as
  /// soon as the AT write is verified, while netifd is still bringing the
  /// data interface back — so the immediate re-read catches the gap and the
  /// switch says "disconnected" on a connection that is reconnecting. One
  /// later read closes that gap without the user having to pull.
  void _settle() {
    Future<void>.delayed(const Duration(seconds: 12), () {
      if (!mounted) return;
      // The router has had long enough to agree or not; from here the read
      // decides, so a switch that is still off is telling the truth.
      setState(() => _requestedData = null);
      ref.invalidate(cellularRadioProvider);
      ref.invalidate(cellularProvider);
    });
  }

  Future<void> _reload() async {
    ref.invalidate(cellularRadioProvider);
    ref.invalidate(cellularProvider);
    await ref.read(cellularRadioProvider.future);
  }

  String _explain(Object error) {
    if (error is CellularRadioException) {
      return context.l10n.cellularLockFailed(error.message);
    }
    return apiErrorText(context, error);
  }

  Future<bool> _confirm(String question) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: Text(question),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(context.l10n.continueAnyway),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _setData(bool up) async {
    if (_busy) return;
    final l10n = context.l10n;
    if (!up && !await _confirm(l10n.cellularRadioDataOffConfirm)) return;
    if (!mounted) return;

    setState(() => _requestedData = up);
    final ok = await _run(
      () => ref.read(cellularRadioMutationsProvider).setDataUp(up),
      reconnects: true,
    );
    if (!ok && mounted) setState(() => _requestedData = null);
  }

  Future<void> _setRadio(int slot, bool enabled) async {
    final l10n = context.l10n;
    if (!enabled &&
        !await _confirm(l10n.cellularRadioRfOffConfirm('${slot + 1}'))) {
      return;
    }
    if (!mounted) return;
    await _run(
      () => ref
          .read(cellularRadioMutationsProvider)
          .setRadioEnabled(slot: slot, enabled: enabled),
    );
  }

  Future<void> _pickMode() async {
    final current = widget.state.mode;
    final choice = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ModeSheet(current: current),
    );
    if (choice == null || choice == current || !mounted) return;
    await _run(
      () => ref.read(cellularRadioMutationsProvider).setMode(choice),
      done: context.l10n.cellularLockApplied,
      reconnects: true,
    );
  }

  Future<void> _pickBands() async {
    final choice = await showModalBottomSheet<_BandChoice>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _BandSheet(state: widget.state),
    );
    if (choice == null || !mounted) return;

    final l10n = context.l10n;
    await _run(
      () async {
        final mutations = ref.read(cellularRadioMutationsProvider);
        if (choice.restore) {
          await mutations.restoreBands();
          return;
        }
        // Two jobs, in sequence: the backend restarts and verifies the radio
        // once per RAT, so firing both at once would have the second rejected
        // while the first still holds the apply lock.
        if (choice.lte case final lte?) {
          await mutations.setBands(rat: 'lte', bands: lte);
        }
        if (choice.nr case final nr?) {
          await mutations.setBands(rat: 'nr', bands: nr);
        }
      },
      done: l10n.cellularLockApplied,
      reconnects: true,
    );
  }

  Future<void> _pickCell() async {
    final l10n = context.l10n;
    final action = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (_) => _CellSheet(state: widget.state),
    );
    if (action == null || !mounted) return;
    await _run(
      () => ref.read(cellularRadioMutationsProvider).setCellLock(lock: action),
      done: l10n.cellularLockApplied,
      reconnects: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = widget.state;
    final scheme = Theme.of(context).colorScheme;
    final dataUp = _requestedData ?? state.dataUp;

    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: LuciSpacing.xl),
        children: [
          if (_busy)
            Card(
              margin: const EdgeInsets.fromLTRB(
                LuciSpacing.md,
                LuciSpacing.md,
                LuciSpacing.md,
                0,
              ),
              elevation: 0,
              color: scheme.secondaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(LuciSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.cellularLockApplying,
                      style: LuciTextStyles.detailValue(context),
                    ),
                    const SizedBox(height: LuciSpacing.sm),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: const LinearProgressIndicator(minHeight: 4),
                    ),
                  ],
                ),
              ),
            ),
          _Card(
            icon: Icons.router_outlined,
            title: l10n.cellularRadioData,
            children: [
              SwitchListTile(
                secondary: Icon(
                  dataUp == false ? Icons.wifi_off : Icons.wifi,
                  color: scheme.primary,
                ),
                title: Text(l10n.cellularRadioData),
                subtitle: Text(switch (dataUp) {
                  true => l10n.cellularRadioDataOn,
                  false => l10n.cellularRadioDataOff,
                  null => l10n.cellularRadioDataUnknown,
                }),
                value: dataUp ?? false,
                onChanged: _busy || dataUp == null
                    ? null
                    : (value) => _setData(value),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  LuciSpacing.lg,
                  0,
                  LuciSpacing.lg,
                  LuciSpacing.md,
                ),
                child: Text(
                  l10n.cellularRadioDataHelp,
                  style: LuciTextStyles.cardSubtitle(context),
                ),
              ),
              if (state.radioEnabled.isNotEmpty) ...[
                const Divider(height: 1),
                for (var slot = 0; slot < state.radioEnabled.length; slot++)
                  SwitchListTile(
                    secondary: Icon(
                      state.radioEnabled[slot]
                          ? Icons.cell_tower
                          : Icons.cell_tower_outlined,
                      color: state.radioEnabled[slot]
                          ? scheme.primary
                          : scheme.outline,
                    ),
                    title: Text(l10n.cellularRadioRf('${slot + 1}')),
                    subtitle: Text(
                      l10n.cellularRadioRfHelp,
                      style: LuciTextStyles.cardSubtitle(context),
                    ),
                    value: state.radioEnabled[slot],
                    onChanged: _busy ? null : (value) => _setRadio(slot, value),
                  ),
              ],
            ],
          ),
          _Card(
            icon: Icons.lock_outline,
            title: l10n.cellularLockTitle,
            children: [
              ListTile(
                leading: Icon(Icons.network_cell, color: scheme.primary),
                title: Text(l10n.cellularLockMode),
                subtitle: Text(_modeLabel(context, state.mode)),
                trailing: const Icon(Icons.chevron_right),
                onTap: _busy ? null : _pickMode,
              ),
              const Divider(height: 1),
              ListTile(
                leading: Icon(Icons.tune, color: scheme.primary),
                title: Text(l10n.cellularLockBands),
                subtitle: Text(_bandSummary(context, state)),
                trailing: const Icon(Icons.chevron_right),
                onTap: _busy ? null : _pickBands,
              ),
              const Divider(height: 1),
              ListTile(
                leading: Icon(Icons.pin_drop_outlined, color: scheme.primary),
                title: Text(l10n.cellularLockCell),
                subtitle: Text(_cellSummary(context, state)),
                trailing: const Icon(Icons.chevron_right),
                onTap: _busy ? null : _pickCell,
              ),
              const Divider(height: 1),
              SwitchListTile(
                secondary: Icon(Icons.restart_alt, color: scheme.primary),
                title: Text(l10n.cellularLockAutoApply),
                subtitle: Text(
                  l10n.cellularLockAutoApplyHelp,
                  style: LuciTextStyles.cardSubtitle(context),
                ),
                value: state.autoApply,
                onChanged: _busy
                    ? null
                    : (value) => _run(
                        () => ref
                            .read(cellularRadioMutationsProvider)
                            .setAutoApply(value),
                        done: l10n.cellularLockApplied,
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

String _modeLabel(BuildContext context, String mode) {
  final l10n = context.l10n;
  return switch (mode) {
    'auto' => l10n.cellularModeAuto,
    '5g4g' => l10n.cellularMode5g4g,
    '4g' => l10n.cellularMode4g,
    'sa' => l10n.cellularModeSa,
    'nsa' => l10n.cellularModeNsa,
    'auto-nsa' => l10n.cellularModeAutoNsa,
    '4g-nsa' => l10n.cellularMode4gNsa,
    'sa-nsa' => l10n.cellularModeSaNsa,
    _ => l10n.cellularModeUnknown(mode.isEmpty ? '—' : mode),
  };
}

String _bandSummary(BuildContext context, CellularRadioState state) {
  if (!state.hasBandLock) return context.l10n.cellularLockBandsAll;
  return context.l10n.cellularLockBandsValue(
    state.lteLocked.isEmpty ? '—' : state.lteLocked.join(','),
    state.nrLocked.isEmpty ? '—' : state.nrLocked.join(','),
  );
}

String _cellSummary(BuildContext context, CellularRadioState state) {
  final l10n = context.l10n;
  if (!state.hasCellLock) return l10n.cellularLockCellNone;
  return _cellLabel(context, state.lockedCells.first);
}

/// `nr:152890,669` -> "NR 152890 · PCI 669".
String _cellLabel(BuildContext context, String raw) {
  final parts = raw.split(':');
  if (parts.length != 2) return raw;
  final pair = parts[1].split(',');
  if (pair.length != 2) return raw;
  return context.l10n.cellularLockCellValue(
    parts[0].toUpperCase(),
    pair[0],
    pair[1],
  );
}

/// A titled card, so the tab reads as two groups rather than nine rows.
class _Card extends StatelessWidget {
  const _Card({
    required this.icon,
    required this.title,
    required this.children,
  });

  final IconData icon;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(
        LuciSpacing.md,
        LuciSpacing.md,
        LuciSpacing.md,
        0,
      ),
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: LuciCardStyles.standardRadius,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              LuciSpacing.lg,
              LuciSpacing.md,
              LuciSpacing.lg,
              LuciSpacing.sm,
            ),
            child: Row(
              children: [
                Icon(icon, color: scheme.primary, size: 20),
                const SizedBox(width: LuciSpacing.sm),
                Expanded(
                  child: Text(
                    title,
                    style: LuciTextStyles.sectionHeader(context),
                  ),
                ),
              ],
            ),
          ),
          ...children,
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------- sheets

class _ModeSheet extends StatelessWidget {
  const _ModeSheet({required this.current});

  final String current;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: LuciSpacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                LuciSpacing.lg,
                0,
                LuciSpacing.lg,
                LuciSpacing.sm,
              ),
              child: Text(
                context.l10n.cellularLockMode,
                style: LuciTextStyles.cardTitle(context),
              ),
            ),
            Flexible(
              child: RadioGroup<String>(
                groupValue: current,
                onChanged: (value) {
                  if (value == null) return;
                  Navigator.of(context).pop(value);
                },
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final mode in CellularRadioState.modes)
                      RadioListTile<String>(
                        value: mode,
                        dense: true,
                        activeColor: scheme.primary,
                        title: Text(_modeLabel(context, mode)),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What the band sheet decided: the new selection per RAT, unchanged ones
/// left null, or "restore the defaults".
class _BandChoice {
  const _BandChoice({this.lte, this.nr, this.restore = false});

  final List<int>? lte;
  final List<int>? nr;
  final bool restore;
}

class _BandSheet extends StatefulWidget {
  const _BandSheet({required this.state});

  final CellularRadioState state;

  @override
  State<_BandSheet> createState() => _BandSheetState();
}

class _BandSheetState extends State<_BandSheet> {
  late final Set<int> _lte = {...widget.state.lteLocked};
  late final Set<int> _nr = {...widget.state.nrLocked};

  void _toggle(Set<int> target, int band, bool selected) {
    setState(() {
      if (selected) {
        target.add(band);
      } else {
        target.remove(band);
      }
    });
  }

  void _save() {
    final current = widget.state;
    final lte = _lte.isEmpty || _sameBands(_lte, current.lteLocked)
        ? null
        : (_lte.toList()..sort());
    final nr = _nr.isEmpty || _sameBands(_nr, current.nrLocked)
        ? null
        : (_nr.toList()..sort());
    if (lte == null && nr == null) {
      Navigator.of(context).pop();
      return;
    }
    Navigator.of(context).pop(_BandChoice(lte: lte, nr: nr));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: LuciSpacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: LuciSpacing.lg),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.cellularLockBands,
                      style: LuciTextStyles.cardTitle(context),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(
                      context,
                    ).pop(const _BandChoice(restore: true)),
                    child: Text(l10n.cellularLockRestore),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(horizontal: LuciSpacing.lg),
                children: [
                  _bandGroup(
                    context,
                    label: 'LTE',
                    prefix: 'B',
                    bands: widget.state.lteChoices,
                    selected: _lte,
                  ),
                  const SizedBox(height: LuciSpacing.md),
                  _bandGroup(
                    context,
                    label: '5G NR',
                    // 5G bands are written n28, not B28 — the same number,
                    // a different band.
                    prefix: 'n',
                    bands: widget.state.nrChoices,
                    selected: _nr,
                  ),
                  const SizedBox(height: LuciSpacing.lg),
                  FilledButton(onPressed: _save, child: Text(l10n.save)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bandGroup(
    BuildContext context, {
    required String label,
    required String prefix,
    required List<int> bands,
    required Set<int> selected,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: LuciTextStyles.sectionHeader(context)),
        const SizedBox(height: LuciSpacing.sm),
        Wrap(
          spacing: LuciSpacing.sm,
          runSpacing: LuciSpacing.xs,
          children: [
            for (final band in bands)
              FilterChip(
                label: Text('$prefix$band'),
                selected: selected.contains(band),
                selectedColor: scheme.primaryContainer,
                onSelected: (value) => _toggle(selected, band, value),
              ),
          ],
        ),
      ],
    );
  }
}

/// True when both hold the same bands. Order is not part of the selection, and
/// the backend sorts its readback.
bool _sameBands(Set<int> a, List<int> b) =>
    a.length == b.length && a.containsAll(b);

class _CellSheet extends StatelessWidget {
  const _CellSheet({required this.state});

  final CellularRadioState state;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final serving = state.serving;

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              LuciSpacing.lg,
              0,
              LuciSpacing.lg,
              LuciSpacing.sm,
            ),
            child: Text(
              l10n.cellularLockCell,
              style: LuciTextStyles.cardTitle(context),
            ),
          ),
          ListTile(
            enabled: serving != null && !state.hasCellLock,
            leading: Icon(Icons.gps_fixed, color: scheme.primary),
            title: Text(l10n.cellularLockLockCurrentCell),
            subtitle: Text(
              serving == null
                  ? l10n.cellularLockNoServingCell
                  : l10n.cellularLockCellValue(
                      serving.rat.toUpperCase(),
                      '${serving.channel}',
                      '${serving.pci}',
                    ),
            ),
            onTap: serving == null || state.hasCellLock
                ? null
                : () => Navigator.of(context).pop(true),
          ),
          ListTile(
            enabled: state.hasCellLock,
            leading: Icon(Icons.lock_open, color: scheme.primary),
            title: Text(l10n.cellularLockClearCell),
            onTap: state.hasCellLock
                ? () => Navigator.of(context).pop(false)
                : null,
          ),
          const SizedBox(height: LuciSpacing.sm),
        ],
      ),
    );
  }
}

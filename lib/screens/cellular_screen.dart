import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:luci_mobile/design/luci_design_system.dart';
import 'package:luci_mobile/l10n/failure_text.dart';
import 'package:luci_mobile/l10n/luci_localizations.dart';
import 'package:luci_mobile/models/cellular.dart';
import 'package:luci_mobile/models/router_capabilities.dart';
import 'package:luci_mobile/models/uci_change.dart';
import 'package:luci_mobile/services/cellular_planner.dart';
import 'package:luci_mobile/services/cellular_service.dart';
import 'package:luci_mobile/state/cellular_providers.dart';
import 'package:luci_mobile/state/feature_providers.dart';
import 'package:luci_mobile/utils/format_bytes.dart';
import 'package:luci_mobile/widgets/luci_app_bar.dart';
import 'package:luci_mobile/widgets/luci_apply_progress.dart';
import 'package:luci_mobile/widgets/luci_feature_gate.dart';
import 'package:luci_mobile/widgets/luci_loading_states.dart';

/// 4G/5G modem control: what the interface is doing, what it is configured to
/// do, and the messages on the SIM.
///
/// Three tabs rather than three screens because they are read together — a
/// failed connection sends you from the overview to the APN, and a provider
/// text arrives while you are looking at the signal.
class CellularScreen extends ConsumerStatefulWidget {
  const CellularScreen({super.key});

  @override
  ConsumerState<CellularScreen> createState() => _CellularScreenState();
}

class _CellularScreenState extends ConsumerState<CellularScreen> {
  bool _busy = false;

  Future<void> _editApn(CellularInterface existing) async {
    if (_busy) return;
    final ops = await showModalBottomSheet<List<UciOperation>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ApnSheet(existing: existing),
    );
    if (ops == null || ops.isEmpty) return;
    await _apply(ops);
  }

  Future<void> _apply(List<UciOperation> ops) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await runApply(
        context,
        work: (progress) => ref
            .read(cellularMutationsProvider)
            .apply(ops, onPhase: progress.update),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final async = ref.watch(cellularProvider);

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: LuciAppBar(
          title: l10n.cellular,
          showMenu: true,
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: l10n.retry,
              onPressed: () {
                ref.invalidate(cellularProvider);
                ref.invalidate(smsInboxProvider);
              },
            ),
          ],
          bottom: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: l10n.cellularOverview),
              Tab(text: l10n.cellularConfig),
              Tab(text: l10n.cellularMessages),
            ],
          ),
        ),
        body: async.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(LuciSpacing.md),
            child: LuciCardSkeleton(contentLines: 5),
          ),
          error: (error, _) => LuciMessageState(
            scrollable: false,
            icon: Icons.error_outline,
            message: apiErrorText(context, error),
            action: l10n.retry,
            onAction: () => ref.invalidate(cellularProvider),
          ),
          data: (snapshot) => snapshot.isEmpty
              ? LuciMessageState(
                  scrollable: false,
                  icon: Icons.signal_cellular_off,
                  message: l10n.cellularEmptyBody,
                  action: l10n.retry,
                  onAction: () => ref.invalidate(cellularProvider),
                )
              : TabBarView(
                  children: [
                    _OverviewTab(snapshot: snapshot),
                    _ConfigTab(
                      snapshot: snapshot,
                      busy: _busy,
                      onEdit: _editApn,
                    ),
                    _SmsTab(snapshot: snapshot),
                  ],
                ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ overview

class _OverviewTab extends StatelessWidget {
  const _OverviewTab({required this.snapshot});

  final CellularSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListView(
      padding: const EdgeInsets.only(bottom: LuciSpacing.xl),
      children: [
        for (final iface in snapshot.interfaces)
          _InterfaceCard(
            iface: iface,
            telemetry: snapshot.telemetry,
            // A carrier-supplied APN is only worth showing for the interface
            // that is actually up; a down one has no runtime answer of its own.
            runtimeApn: iface.up ? snapshot.runtimeApn : null,
          ),
        if (snapshot.quota != null || snapshot.sims.isNotEmpty)
          _QuotaCard(
            quota: snapshot.quota,
            sims: snapshot.sims,
            dataSim: snapshot.dataSim,
          ),
        if (snapshot.telemetryUnavailable)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: LuciSpacing.md),
            child: _Hint(
              icon: Icons.info_outline,
              text: l10n.cellularNoTelemetry,
            ),
          ),
      ],
    );
  }
}

/// Metered usage and the SIM slots, from the router's own accounting.
///
/// On a mobile router this is the most-read card on the screen: the signal
/// tells you whether you can work, this tells you for how long.
class _QuotaCard extends StatelessWidget {
  const _QuotaCard({this.quota, required this.sims, this.dataSim});

  final CellularQuota? quota;
  final List<SimSlot> sims;
  final int? dataSim;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final quota = this.quota;
    final fraction = quota?.usedFraction;
    final used = quota?.usedBytes;
    final limit = quota?.limitBytes;

    String stateLabel(String state) => switch (state) {
      'ready' => l10n.cellularSimStateReady,
      'absent' => l10n.cellularSimStateAbsent,
      _ => state,
    };

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
      child: Padding(
        padding: const EdgeInsets.all(LuciSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (quota != null) ...[
              Row(
                children: [
                  Icon(Icons.data_usage, color: scheme.primary),
                  const SizedBox(width: LuciSpacing.md),
                  Expanded(
                    child: Text(
                      l10n.cellularQuotaTitle,
                      style: LuciTextStyles.cardTitle(context),
                    ),
                  ),
                  if (quota.overLimit)
                    Text(
                      l10n.cellularQuotaOver,
                      style: LuciTextStyles.detailValue(
                        context,
                      ).copyWith(color: scheme.error),
                    ),
                ],
              ),
              const SizedBox(height: LuciSpacing.md),
              Text(
                limit == null || used == null
                    ? '—'
                    : l10n.cellularQuotaUsage(
                        formatBytes(used),
                        formatBytes(limit),
                      ),
                style: LuciTextStyles.cardTitle(context),
              ),
              if (fraction != null) ...[
                const SizedBox(height: LuciSpacing.sm),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: fraction,
                    minHeight: 6,
                    backgroundColor: scheme.surfaceContainerHighest,
                    color: quota.overLimit ? scheme.error : scheme.primary,
                  ),
                ),
              ],
              const SizedBox(height: LuciSpacing.md),
              _DetailRows(
                rows: [
                  if (quota.remainingBytes != null)
                    (
                      l10n.cellularQuotaRemainingLabel,
                      formatBytes(quota.remainingBytes!),
                    ),
                  if (quota.todayBytes != null)
                    (l10n.cellularQuotaToday, formatBytes(quota.todayBytes!)),
                  if (quota.cycleStart != null && quota.cycleEnd != null)
                    (
                      l10n.cellularQuotaCycleLabel,
                      l10n.cellularQuotaCycle(
                        quota.cycleStart!,
                        quota.cycleEnd!,
                      ),
                    ),
                ],
              ),
            ],
            if (quota != null && sims.isNotEmpty)
              const Divider(height: LuciSpacing.xl),
            if (sims.isNotEmpty)
              _DetailRows(
                rows: [
                  for (final sim in sims)
                    (
                      l10n.cellularSimSlot(sim.slot + 1),
                      sim.slot == dataSim
                          ? '${stateLabel(sim.state)} · ${l10n.cellularSimData}'
                          : stateLabel(sim.state),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _InterfaceCard extends StatelessWidget {
  const _InterfaceCard({required this.iface, this.telemetry, this.runtimeApn});

  final CellularInterface iface;
  final CellularTelemetry? telemetry;

  /// The APN the interface came up with, when the config does not carry one.
  final String? runtimeApn;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final state = iface.disabled
        ? (label: l10n.cellularDisabled, color: scheme.outline)
        : iface.up
        ? (label: l10n.cellularConnected, color: scheme.primary)
        : (label: l10n.cellularDisconnected, color: scheme.error);

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
      child: Padding(
        padding: const EdgeInsets.all(LuciSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _signalIcon(telemetry?.bars ?? 0),
                  color: iface.up ? scheme.primary : scheme.outline,
                ),
                const SizedBox(width: LuciSpacing.md),
                Expanded(
                  child: Text(
                    iface.label,
                    style: LuciTextStyles.cardTitle(context),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: LuciSpacing.md,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: state.color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    state.label,
                    style: LuciTextStyles.detailValue(
                      context,
                    ).copyWith(color: state.color),
                  ),
                ),
              ],
            ),
            if (telemetry != null) ...[
              const SizedBox(height: LuciSpacing.md),
              Text(
                [
                  ?telemetry!.operatorName,
                  ?telemetry!.technologyLabel,
                  if (telemetry!.signalPercent != null)
                    l10n.cellularSignalPercent(telemetry!.signalPercent!),
                  // A receiver measurement and a quality percentage inverted
                  // onto the dBm ladder are different claims; only one of them
                  // is allowed to be shown without the "≈".
                  if (telemetry!.approximateDbm != null)
                    telemetry!.hasMeasuredSignal
                        ? l10n.cellularSignalRsrp(telemetry!.approximateDbm!)
                        : l10n.cellularSignalApprox(telemetry!.approximateDbm!),
                ].join(' · '),
                style: LuciTextStyles.cardSubtitle(context),
              ),
              if (telemetry!.band != null || telemetry!.sinr != null)
                Text(
                  [
                    if (telemetry!.band != null)
                      l10n.cellularBand(telemetry!.band!),
                    if (telemetry!.sinr != null)
                      l10n.cellularSinr(telemetry!.sinr!.toStringAsFixed(1)),
                  ].join(' · '),
                  style: LuciTextStyles.cardSubtitle(context),
                ),
            ],
            const SizedBox(height: LuciSpacing.md),
            _DetailRows(
              rows: [
                (l10n.cellularProtocol, iface.proto.toUpperCase()),
                if (iface.device != null) (l10n.cellularDevice, iface.device!),
                // The config's APN, or the one the carrier supplied when the
                // interface is on `apn_auto` — labelled, so the two are never
                // confused for each other.
                if (iface.apn != null)
                  (l10n.cellularApnLabel, iface.apn!)
                else if (runtimeApn != null)
                  (
                    l10n.cellularApnLabel,
                    '${runtimeApn!} · ${l10n.cellularApnAuto}',
                  ),
                if (iface.up && iface.uptimeSeconds != null)
                  (l10n.cellularUptime, _formatUptime(iface.uptimeSeconds!)),
                if (iface.ipv4.isNotEmpty) ('IPv4', iface.ipv4.join(', ')),
                if (iface.ipv6.isNotEmpty) ('IPv6', iface.ipv6.join(', ')),
                if (iface.dns.isNotEmpty) ('DNS', iface.dns.join(', ')),
                if (iface.rxBytes != null && iface.txBytes != null)
                  (
                    l10n.cellularTraffic,
                    '↓ ${formatBytes(iface.rxBytes!)}  ↑ ${formatBytes(iface.txBytes!)}',
                  ),
                if (telemetry?.imei != null) ('IMEI', telemetry!.imei!),
                if (telemetry?.iccid != null) ('ICCID', telemetry!.iccid!),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static IconData _signalIcon(int bars) => switch (bars) {
    0 => Icons.signal_cellular_off,
    1 => Icons.signal_cellular_alt_1_bar,
    2 => Icons.signal_cellular_alt_2_bar,
    _ => Icons.signal_cellular_alt,
  };

  static String _formatUptime(int seconds) {
    final d = Duration(seconds: seconds);
    if (d.inDays > 0) return '${d.inDays}d ${d.inHours % 24}h';
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
    return '${d.inMinutes}m';
  }
}

class _DetailRows extends StatelessWidget {
  const _DetailRows({required this.rows});

  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 92,
                  child: Text(
                    label,
                    style: LuciTextStyles.cardSubtitle(
                      context,
                    ).copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
                Expanded(
                  child: SelectableText(
                    value,
                    style: LuciTextStyles.detailValue(context),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: LuciSpacing.md),
      padding: const EdgeInsets.all(LuciSpacing.lg),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: scheme.onSurfaceVariant),
          const SizedBox(width: LuciSpacing.md),
          Expanded(
            child: Text(text, style: LuciTextStyles.cardSubtitle(context)),
          ),
        ],
      ),
    );
  }
}

// -------------------------------------------------------------------- config

class _ConfigTab extends ConsumerWidget {
  const _ConfigTab({
    required this.snapshot,
    required this.busy,
    required this.onEdit,
  });

  final CellularSnapshot snapshot;
  final bool busy;
  final Future<void> Function(CellularInterface iface) onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final gate = ref.watch(featureProvider(RouterFeature.cellularApn));

    return ListView(
      padding: const EdgeInsets.only(bottom: LuciSpacing.xl),
      children: [
        for (final iface in snapshot.interfaces)
          Card(
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
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.settings_input_antenna),
                  title: Text(iface.label),
                  subtitle: Text(
                    [
                      iface.proto.toUpperCase(),
                      iface.apn != null
                          ? l10n.cellularApnValue(iface.apn!)
                          // "not set" and "chosen by the carrier" are
                          // different states, and only one of them needs the
                          // user to do something.
                          : iface.apnAuto == true
                          ? l10n.cellularApnAuto
                          : l10n.cellularApnUnset,
                    ].join(' · '),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  // Says why it is disabled instead of silently doing nothing.
                  onTap: gate.available && !busy ? () => onEdit(iface) : null,
                  enabled: gate.available && !busy,
                ),
                if (gate.explain(context) case final reason?)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      LuciSpacing.lg,
                      0,
                      LuciSpacing.lg,
                      LuciSpacing.md,
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        reason,
                        style: LuciTextStyles.cardSubtitle(context),
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The APN form.
///
/// Returned as [UciOperation]s rather than applied here: the screen owns the
/// apply ceremony (progress dialog, rollback countdown, outcome message), and
/// a sheet that committed by itself would bypass all three.
class _ApnSheet extends StatefulWidget {
  const _ApnSheet({required this.existing});

  final CellularInterface existing;

  @override
  State<_ApnSheet> createState() => _ApnSheetState();
}

class _ApnSheetState extends State<_ApnSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _apn = TextEditingController(
    text: widget.existing.apn ?? '',
  );
  late final TextEditingController _username = TextEditingController(
    text: widget.existing.username ?? '',
  );
  final TextEditingController _password = TextEditingController();
  final TextEditingController _pin = TextEditingController();
  late final TextEditingController _mtu = TextEditingController(
    text: widget.existing.mtu ?? '',
  );
  late String _pdpType = widget.existing.pdpType ?? 'ipv4v6';
  late bool _disabled = widget.existing.disabled;

  @override
  void dispose() {
    _apn.dispose();
    _username.dispose();
    _password.dispose();
    _pin.dispose();
    _mtu.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final ops = CellularPlanner.planApn(
      existing: widget.existing,
      apn: _apn.text.trim(),
      username: _username.text.trim(),
      // Left empty, the field means "unchanged" rather than "clear": neither
      // the current password nor the current PIN is ever read back, so
      // treating an untouched field as a deletion would wipe a working
      // credential the user never saw.
      password: _password.text,
      pin: _pin.text,
      pdpType: _pdpType,
      mtu: _mtu.text.trim(),
      disabled: _disabled,
    );
    Navigator.of(context).pop(ops);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Padding(
      padding: EdgeInsets.only(
        left: LuciSpacing.lg,
        right: LuciSpacing.lg,
        top: LuciSpacing.sm,
        bottom: MediaQuery.viewInsetsOf(context).bottom + LuciSpacing.lg,
      ),
      child: Form(
        key: _formKey,
        child: ListView(
          shrinkWrap: true,
          children: [
            Text(
              l10n.cellularEditApn,
              style: LuciTextStyles.cardTitle(context),
            ),
            const SizedBox(height: LuciSpacing.lg),
            TextFormField(
              controller: _apn,
              decoration: InputDecoration(
                labelText: l10n.cellularApnLabel,
                // On a section with `apn_auto`, an empty field means "keep
                // letting the carrier choose", and typing one clears the flag.
                helperText: widget.existing.apnAuto == true
                    ? l10n.cellularApnAutoHelp
                    : l10n.cellularApnHelp,
              ),
              autocorrect: false,
              validator: (value) => CellularPlanner.isValidApn(value ?? '')
                  ? null
                  : l10n.cellularApnInvalid,
            ),
            const SizedBox(height: LuciSpacing.md),
            TextFormField(
              controller: _username,
              decoration: InputDecoration(labelText: l10n.cellularUsername),
              autocorrect: false,
            ),
            const SizedBox(height: LuciSpacing.md),
            TextFormField(
              controller: _password,
              obscureText: true,
              decoration: InputDecoration(
                labelText: l10n.cellularPassword,
                helperText: l10n.cellularPasswordKeep,
              ),
              autocorrect: false,
            ),
            const SizedBox(height: LuciSpacing.md),
            TextFormField(
              controller: _pin,
              obscureText: true,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: l10n.cellularPin,
                helperText: l10n.cellularPinKeep,
              ),
            ),
            const SizedBox(height: LuciSpacing.md),
            DropdownButtonFormField<String>(
              initialValue: _pdpType,
              decoration: InputDecoration(labelText: l10n.cellularPdpType),
              items: [
                for (final type in CellularPlanner.pdpTypes)
                  DropdownMenuItem(value: type, child: Text(type)),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _pdpType = value);
              },
            ),
            const SizedBox(height: LuciSpacing.md),
            TextFormField(
              controller: _mtu,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: l10n.cellularMtu),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.cellularDisable),
              value: _disabled,
              onChanged: (value) => setState(() => _disabled = value),
            ),
            const SizedBox(height: LuciSpacing.md),
            FilledButton(onPressed: _submit, child: Text(l10n.save)),
          ],
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------------- sms

class _SmsTab extends ConsumerStatefulWidget {
  const _SmsTab({required this.snapshot});

  final CellularSnapshot snapshot;

  @override
  ConsumerState<_SmsTab> createState() => _SmsTabState();
}

class _SmsTabState extends ConsumerState<_SmsTab> {
  bool _busy = false;

  Future<void> _compose() async {
    final result = await showModalBottomSheet<(String, String)>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _ComposeSheet(),
    );
    if (result == null || !mounted) return;

    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    try {
      await ref.read(cellularMutationsProvider).sendSms(result.$1, result.$2);
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(l10n.cellularSent)));
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(apiErrorText(context, e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(SmsMessage message) async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(cellularMutationsProvider).deleteSms(message);
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(apiErrorText(context, e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editDevice() async {
    final controller = TextEditingController(
      text: ref.read(smsDeviceProvider) ?? widget.snapshot.suggestedSmsDevice,
    );
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.l10n.cellularSmsDevice),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              autocorrect: false,
              decoration: const InputDecoration(hintText: '/dev/ttyUSB2'),
            ),
            const SizedBox(height: LuciSpacing.md),
            Text(
              context.l10n.cellularSmsDeviceHelp,
              style: LuciTextStyles.cardSubtitle(context),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: Text(context.l10n.save),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || value.isEmpty) return;
    ref.read(smsDeviceProvider.notifier).select(value);
    ref.invalidate(smsInboxProvider);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final async = ref.watch(smsInboxProvider);
    final inbox = async.value;
    final backend = inbox?.backend;
    final device =
        ref.watch(smsDeviceProvider) ?? widget.snapshot.suggestedSmsDevice;

    return Scaffold(
      floatingActionButton: backend == null
          ? null
          : FloatingActionButton(
              onPressed: _busy ? null : _compose,
              tooltip: l10n.cellularCompose,
              child: const Icon(Icons.edit_outlined),
            ),
      body: Column(
        children: [
          // The AT port only means something to `sms-tool`. A vendor backend
          // addresses the modem itself, so showing the field there would be a
          // control that changes nothing.
          if (backend != null && backend.needsDevice) ...[
            ListTile(
              dense: true,
              leading: const Icon(Icons.usb),
              title: Text(l10n.cellularSmsDevice),
              subtitle: Text(device),
              trailing: const Icon(Icons.edit_outlined, size: 18),
              onTap: _busy ? null : _editDevice,
            ),
            const Divider(height: 1),
          ],
          if (backend != null && !backend.needsDevice)
            ListTile(
              dense: true,
              leading: const Icon(Icons.sms_outlined),
              title: Text(l10n.cellularSmsService),
              subtitle: Text(backend.label),
            ),
          if (inbox != null && !inbox.available)
            Padding(
              padding: const EdgeInsets.all(LuciSpacing.md),
              child: _Hint(
                icon: Icons.info_outline,
                text: inbox.detail == null
                    ? l10n.cellularSmsNoService
                    : '${l10n.cellularSmsNoService}\n${inbox.detail}',
              ),
            ),
          Expanded(
            child: async.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(LuciSpacing.md),
                child: LuciCardSkeleton(contentLines: 4),
              ),
              error: (error, _) => LuciMessageState(
                scrollable: false,
                icon: Icons.sms_failed_outlined,
                message: apiErrorText(context, error),
                action: l10n.retry,
                onAction: () => ref.invalidate(smsInboxProvider),
              ),
              data: (inbox) => !inbox.available
                  ? const SizedBox.shrink()
                  : inbox.messages.isEmpty
                  ? LuciMessageState(
                      scrollable: false,
                      icon: Icons.sms_outlined,
                      message: l10n.cellularNoMessages,
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.only(bottom: 96),
                      itemCount: inbox.messages.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final message = inbox.messages[i];
                        return _MessageRow(
                          message: message,
                          enabled: !_busy,
                          onDelete: () => _delete(message),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageRow extends StatelessWidget {
  const _MessageRow({
    required this.message,
    required this.enabled,
    required this.onDelete,
  });

  final SmsMessage message;
  final bool enabled;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Time and SIM on one quiet line: which card received a message matters on
    // a dual-SIM router, and both are secondary to the text itself.
    final meta = [?message.displayTime, ?message.sim].join(' · ');
    return ListTile(
      leading: Icon(
        message.unread ? Icons.mark_email_unread : Icons.mail_outline,
        color: message.unread ? scheme.primary : scheme.outline,
      ),
      title: Text(message.sender ?? '—'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (message.body.isNotEmpty) Text(message.body),
          if (meta.isNotEmpty)
            Text(meta, style: LuciTextStyles.cardSubtitle(context)),
        ],
      ),
      isThreeLine: message.body.isNotEmpty && meta.isNotEmpty,
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: context.l10n.cellularDeleteMessage,
        onPressed: enabled ? onDelete : null,
      ),
    );
  }
}

class _ComposeSheet extends StatefulWidget {
  const _ComposeSheet();

  @override
  State<_ComposeSheet> createState() => _ComposeSheetState();
}

class _ComposeSheetState extends State<_ComposeSheet> {
  final _formKey = GlobalKey<FormState>();
  final _to = TextEditingController();
  final _body = TextEditingController();

  @override
  void dispose() {
    _to.dispose();
    _body.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.of(context).pop((_to.text.trim(), _body.text));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Padding(
      padding: EdgeInsets.only(
        left: LuciSpacing.lg,
        right: LuciSpacing.lg,
        top: LuciSpacing.sm,
        bottom: MediaQuery.viewInsetsOf(context).bottom + LuciSpacing.lg,
      ),
      child: Form(
        key: _formKey,
        child: ListView(
          shrinkWrap: true,
          children: [
            Text(
              l10n.cellularCompose,
              style: LuciTextStyles.cardTitle(context),
            ),
            const SizedBox(height: LuciSpacing.lg),
            TextFormField(
              controller: _to,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(labelText: l10n.cellularRecipient),
              validator: (value) => (value ?? '').trim().isEmpty
                  ? l10n.cellularRecipientRequired
                  : null,
            ),
            const SizedBox(height: LuciSpacing.md),
            TextFormField(
              controller: _body,
              maxLines: 4,
              decoration: InputDecoration(labelText: l10n.cellularMessageBody),
              validator: (value) => (value ?? '').trim().isEmpty
                  ? l10n.cellularBodyRequired
                  : null,
            ),
            const SizedBox(height: LuciSpacing.lg),
            FilledButton.icon(
              onPressed: _submit,
              icon: const Icon(Icons.send),
              label: Text(l10n.cellularSend),
            ),
          ],
        ),
      ),
    );
  }
}

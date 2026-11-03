import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:luci_mobile/design/luci_design_system.dart';
import 'package:luci_mobile/l10n/failure_text.dart';
import 'package:luci_mobile/l10n/luci_localizations.dart';
import 'package:luci_mobile/models/openclash.dart';
import 'package:luci_mobile/services/openclash_service.dart';
import 'package:luci_mobile/state/openclash_providers.dart';
import 'package:luci_mobile/utils/format_bytes.dart';
import 'package:luci_mobile/widgets/luci_app_bar.dart';
import 'package:luci_mobile/widgets/luci_loading_states.dart';

/// OpenClash: whether its core is up, what it is doing, and the two controls
/// people actually open it for — a different node, or a different mode.
///
/// The screen is reached from Settings. It is not a top-level section: the
/// router's proxy stack is something a user configures occasionally and then
/// leaves alone, which is the definition of a Settings tile rather than a bar
/// slot next to Clients.
///
/// Everything shown here comes from the running core (its external
/// controller), not from the UCI config. The config is what the next start
/// will use; showing it in place of live state would report a mode the user
/// changed but did not apply.
class OpenClashScreen extends ConsumerStatefulWidget {
  const OpenClashScreen({super.key});

  @override
  ConsumerState<OpenClashScreen> createState() => _OpenClashScreenState();
}

class _OpenClashScreenState extends ConsumerState<OpenClashScreen> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action, {String? done}) async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action();
      if (done != null && mounted) {
        messenger.showSnackBar(SnackBar(content: Text(done)));
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text(_explain(context, e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _explain(BuildContext context, Object error) {
    if (error is ClashAuthException) return context.l10n.openClashAuthFailed;
    if (error is ClashApiException) {
      return context.l10n.openClashDashboardUnavailable(error.message);
    }
    return apiErrorText(context, error);
  }

  Future<void> _control(String action) async {
    final l10n = context.l10n;
    final ok = await ref.read(openClashActionsProvider).control(action);
    if (!mounted || ok) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l10n.openClashActionFailed)));
  }

  Future<void> _pickNode(OpenClashGroup group) async {
    final l10n = context.l10n;
    final choice = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => _NodeSheet(
        group: group,
        title: l10n.openClashSelectNode,
      ),
    );
    if (choice == null || !mounted || choice == group.now) return;

    await _run(
      () => ref.read(openClashActionsProvider).selectNode(group.name, choice),
      done: l10n.openClashSwitched(group.name, choice),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final async = ref.watch(openClashProvider);

    return Scaffold(
      appBar: LuciAppBar(title: l10n.openClash, showBack: true),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(openClashProvider),
        child: async.when(
          loading: () => ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(LuciSpacing.md),
            children: const [LuciCardSkeleton(contentLines: 3)],
          ),
          error: (error, _) => LuciMessageState(
            icon: Icons.shield_outlined,
            message: apiErrorText(context, error),
            action: l10n.retry,
            onAction: () => ref.invalidate(openClashProvider),
          ),
          data: (snapshot) => !snapshot.installed
              ? LuciMessageState(
                  icon: Icons.shield_outlined,
                  message: l10n.openClashNotInstalled,
                )
              : _Body(
                  snapshot: snapshot,
                  busy: _busy,
                  onControl: (action) => _run(() => _control(action)),
                  onMode: (mode) => _run(
                    () => ref
                        .read(openClashActionsProvider)
                        .setMode(mode),
                    done: l10n.openClashModeSet(_modeLabel(context, mode)),
                  ),
                  onPickNode: _pickNode,
                ),
        ),
      ),
    );
  }

  static String _modeLabel(BuildContext context, String mode) =>
      switch (mode) {
        'rule' => context.l10n.openClashModeRule,
        'global' => context.l10n.openClashModeGlobal,
        'direct' => context.l10n.openClashModeDirect,
        _ => mode,
      };
}

class _Body extends StatelessWidget {
  const _Body({
    required this.snapshot,
    required this.busy,
    required this.onControl,
    required this.onMode,
    required this.onPickNode,
  });

  final OpenClashSnapshot snapshot;
  final bool busy;
  final ValueChanged<String> onControl;
  final ValueChanged<String> onMode;
  final ValueChanged<OpenClashGroup> onPickNode;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final mode = snapshot.effectiveMode;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        LuciSpacing.md,
        LuciSpacing.md,
        LuciSpacing.md,
        LuciSpacing.xl,
      ),
      children: [
        _StatusCard(snapshot: snapshot),
        const SizedBox(height: LuciSpacing.md),
        _Controls(snapshot: snapshot, busy: busy, onControl: onControl),
        if (snapshot.running && snapshot.apiError != null) ...[
          const SizedBox(height: LuciSpacing.md),
          _Note(
            icon: Icons.link_off,
            text: l10n.openClashDashboardUnavailable(snapshot.apiError!),
          ),
        ],
        if (snapshot.dashboardLive) ...[
          const SizedBox(height: LuciSpacing.lg),
          _SectionHeader(l10n.openClashMode),
          _ModeSelector(mode: mode, busy: busy, onMode: onMode),
          const SizedBox(height: LuciSpacing.lg),
          _SectionHeader(l10n.openClashGroups),
          if (snapshot.groups.isEmpty)
            _Note(icon: Icons.hub_outlined, text: l10n.openClashNoGroups)
          else
            _GroupList(
              groups: snapshot.groups,
              enabled: !busy,
              onPick: onPickNode,
            ),
          const SizedBox(height: LuciSpacing.lg),
          _SectionHeader(l10n.openClashTraffic),
          _TrafficCard(snapshot: snapshot),
        ],
      ],
    );
  }
}

/// The answer to "is it on, and what is it running?".
class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.snapshot});

  final OpenClashSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final running = snapshot.running;
    final accent = running ? scheme.primary : scheme.onSurfaceVariant;

    return Container(
      decoration: LuciCardStyles.standardCard(context),
      padding: const EdgeInsets.all(LuciSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(LuciSpacing.sm),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  running ? Icons.shield : Icons.shield_outlined,
                  color: accent,
                ),
              ),
              const SizedBox(width: LuciSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      running ? l10n.openClashRunning : l10n.openClashStopped,
                      style: LuciTextStyles.cardTitle(context).copyWith(
                        color: running ? scheme.primary : scheme.onSurface,
                      ),
                    ),
                    if (snapshot.coreLabel != null)
                      Text(
                        snapshot.coreLabel!,
                        style: LuciTextStyles.cardSubtitle(context),
                      ),
                  ],
                ),
              ),
              if (!snapshot.enabled)
                _Pill(
                  text: l10n.openClashDisabledAtBoot,
                  color: scheme.onSurfaceVariant,
                ),
            ],
          ),
          const SizedBox(height: LuciSpacing.md),
          const Divider(height: 1),
          const SizedBox(height: LuciSpacing.sm),
          if (snapshot.config.configName != null)
            _Kv(
              label: l10n.openClashConfig,
              value: snapshot.config.configName!,
            ),
          if (snapshot.effectiveMode != null)
            _Kv(
              label: l10n.openClashMode,
              value: _OpenClashScreenState._modeLabel(
                context,
                snapshot.effectiveMode!,
              ),
            ),
          if (snapshot.mixedPort != null)
            _Kv(label: l10n.openClashMixedPort, value: '${snapshot.mixedPort}'),
          _Kv(
            label: l10n.openClashApiPort,
            value: '${snapshot.config.apiPort}',
          ),
        ],
      ),
    );
  }
}

class _Kv extends StatelessWidget {
  const _Kv({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: LuciSpacing.xs),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: LuciTextStyles.cardSubtitle(context),
            ),
          ),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: scheme.onSurface,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.snapshot,
    required this.busy,
    required this.onControl,
  });

  final OpenClashSnapshot snapshot;
  final bool busy;
  final ValueChanged<String> onControl;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final running = snapshot.running;

    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: busy
                ? null
                : () => onControl(running ? 'stop' : 'start'),
            icon: busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(running ? Icons.stop : Icons.play_arrow),
            label: Text(running ? l10n.openClashStop : l10n.openClashStart),
          ),
        ),
        const SizedBox(width: LuciSpacing.sm),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: busy ? null : () => onControl('restart'),
            icon: const Icon(Icons.restart_alt),
            label: Text(l10n.openClashRestart),
          ),
        ),
      ],
    );
  }
}

class _ModeSelector extends StatelessWidget {
  const _ModeSelector({
    required this.mode,
    required this.busy,
    required this.onMode,
  });

  final String? mode;
  final bool busy;
  final ValueChanged<String> onMode;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final selected = const {'rule', 'global', 'direct'}.contains(mode)
        ? mode!
        : 'rule';

    return SegmentedButton<String>(
      segments: [
        ButtonSegment(value: 'rule', label: Text(l10n.openClashModeRule)),
        ButtonSegment(value: 'global', label: Text(l10n.openClashModeGlobal)),
        ButtonSegment(value: 'direct', label: Text(l10n.openClashModeDirect)),
      ],
      selected: {selected},
      showSelectedIcon: false,
      onSelectionChanged: busy
          ? null
          : (choice) {
              if (choice.first == mode) return;
              onMode(choice.first);
            },
    );
  }
}

class _GroupList extends StatelessWidget {
  const _GroupList({
    required this.groups,
    required this.enabled,
    required this.onPick,
  });

  final List<OpenClashGroup> groups;
  final bool enabled;
  final ValueChanged<OpenClashGroup> onPick;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // A Card rather than a decorated Container: ListTile paints its ink on the
    // nearest Material, and a plain coloured box in between would hide both
    // the splash and the tile's own background.
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: LuciCardStyles.standardRadius,
        side: BorderSide(
          color: scheme.outlineVariant.withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        children: ListTile.divideTiles(
          context: context,
          tiles: [
            for (final group in groups)
              ListTile(
                enabled: enabled,
                leading: Icon(
                  group.isManual ? Icons.hub_outlined : Icons.auto_awesome,
                  color: scheme.primary,
                ),
                title: Text(group.name),
                subtitle: Text(
                  group.now ?? '—',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Icon(
                  Icons.chevron_right,
                  color: scheme.onSurfaceVariant,
                ),
                onTap: enabled ? () => onPick(group) : null,
              ),
          ],
        ).toList(),
      ),
    );
  }
}

class _NodeSheet extends StatelessWidget {
  const _NodeSheet({required this.group, required this.title});

  final OpenClashGroup group;
  final String title;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(group.name, style: LuciTextStyles.cardTitle(context)),
                Text(title, style: LuciTextStyles.cardSubtitle(context)),
              ],
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: RadioGroup<String>(
              groupValue: group.now,
              onChanged: (value) {
                if (value == null) return;
                Navigator.of(context).pop(value);
              },
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final member in group.members)
                    RadioListTile<String>(
                      value: member,
                      dense: true,
                      title: Text(
                        member,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      activeColor: scheme.primary,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TrafficCard extends StatelessWidget {
  const _TrafficCard({required this.snapshot});

  final OpenClashSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Container(
      decoration: LuciCardStyles.standardCard(context),
      padding: const EdgeInsets.symmetric(
        horizontal: LuciSpacing.lg,
        vertical: LuciSpacing.md,
      ),
      child: Row(
        children: [
          _Metric(
            icon: Icons.arrow_upward,
            label: l10n.openClashUpload,
            value: formatBytes(snapshot.uploadTotal),
          ),
          _Metric(
            icon: Icons.arrow_downward,
            label: l10n.openClashDownload,
            value: formatBytes(snapshot.downloadTotal),
          ),
          _Metric(
            icon: Icons.bolt,
            label: l10n.openClashConnections,
            value: '${snapshot.activeConnections}',
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: scheme.onSurfaceVariant),
              const SizedBox(width: LuciSpacing.xs),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: LuciTextStyles.cardSubtitle(context),
                ),
              ),
            ],
          ),
          const SizedBox(height: LuciSpacing.xs),
          Text(
            value,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      LuciSpacing.xs,
      0,
      LuciSpacing.xs,
      LuciSpacing.sm,
    ),
    child: Text(text, style: LuciTextStyles.sectionHeader(context)),
  );
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: LuciSpacing.sm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: LuciCardStyles.standardCard(context),
      padding: const EdgeInsets.all(LuciSpacing.md),
      child: Row(
        children: [
          Icon(icon, color: scheme.onSurfaceVariant),
          const SizedBox(width: LuciSpacing.md),
          Expanded(
            child: Text(text, style: LuciTextStyles.cardSubtitle(context)),
          ),
        ],
      ),
    );
  }
}

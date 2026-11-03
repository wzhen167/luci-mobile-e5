import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:luci_mobile/design/luci_design_system.dart';
import 'package:luci_mobile/l10n/addon_strings.dart';
import 'package:luci_mobile/l10n/failure_text.dart';
import 'package:luci_mobile/l10n/luci_localizations.dart';
import 'package:luci_mobile/models/router_capabilities.dart';
import 'package:luci_mobile/models/service_status.dart';
import 'package:luci_mobile/screens/addon_screen.dart';
import 'package:luci_mobile/services/addon_catalog.dart';
import 'package:luci_mobile/state/feature_providers.dart';
import 'package:luci_mobile/state/service_providers.dart';
import 'package:luci_mobile/widgets/addon_hub_tile.dart';
import 'package:luci_mobile/widgets/luci_app_bar.dart';
import 'package:luci_mobile/widgets/luci_feature_gate.dart';
import 'package:luci_mobile/widgets/luci_hub_tile.dart';
import 'package:luci_mobile/widgets/luci_loading_states.dart';
import 'package:luci_mobile/widgets/service_row.dart';

/// The Services section: the router's init.d daemons, and the optional
/// service packages that have their own configuration.
///
/// Two tabs rather than one list. The daemons are what the section is named
/// after and there are twenty-odd of them; the add-ons are four entries that
/// would be pushed off the first screen by that list and would push the list
/// off if they came first. In tabs, both are one tap away and neither buries
/// the other.
class ServicesHubScreen extends ConsumerStatefulWidget {
  const ServicesHubScreen({super.key});

  @override
  ConsumerState<ServicesHubScreen> createState() => _ServicesHubScreenState();
}

class _ServicesHubScreenState extends ConsumerState<ServicesHubScreen> {
  String? _busyService;

  Future<void> _act(ServiceStatus service, String action) async {
    final actions = ref.read(serviceActionsProvider);
    if (!await actions.confirmIfSelfCritical(context, service, action)) return;
    if (!mounted) return;

    setState(() => _busyService = service.name);
    try {
      await actions.act(context, service, action);
    } finally {
      if (mounted) setState(() => _busyService = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: LuciAppBar(
          title: l10n.services,
          showBack: true,
          bottom: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: l10n.serviceSystemServices),
              Tab(text: l10n.servicePlugins),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _DaemonsTab(busyService: _busyService, onAct: _act),
            const _AddonsTab(),
          ],
        ),
      ),
    );
  }
}

/// Live state plus the daemon list.
class _DaemonsTab extends ConsumerWidget {
  const _DaemonsTab({required this.busyService, required this.onAct});

  final String? busyService;
  final Future<void> Function(ServiceStatus service, String action) onAct;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final gate = ref.watch(featureProvider(RouterFeature.serviceControl));
    final async = ref.watch(servicesProvider);

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(servicesProvider),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: LuciSpacing.xl),
        children: [
          async.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(LuciSpacing.md),
              child: LuciCardSkeleton(contentLines: 2),
            ),
            error: (error, _) => _Note(
              icon: Icons.error_outline,
              text: gate.explain(context) ?? apiErrorText(context, error),
              action: l10n.retry,
              onAction: () => ref.invalidate(servicesProvider),
            ),
            data: (services) => services.isEmpty
                ? _Note(
                    icon: Icons.miscellaneous_services_outlined,
                    text: gate.explain(context) ?? l10n.noServices,
                  )
                : _Summary(
                    total: services.length,
                    running: services.where((s) => s.running == true).length,
                    enabled: services.where((s) => s.enabled).length,
                  ),
          ),
          ...async.when(
            loading: () => const <Widget>[],
            error: (_, _) => const <Widget>[],
            data: (services) => services.isEmpty
                ? const <Widget>[]
                : [
                    _ServiceListCard(
                      services: services,
                      busyService: busyService,
                      enabled: gate.available && busyService == null,
                      onAction: onAct,
                    ),
                  ],
          ),
        ],
      ),
    );
  }
}

class _AddonsTab extends ConsumerWidget {
  const _AddonsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    return ListView(
      padding: const EdgeInsets.only(bottom: LuciSpacing.xl),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            LuciSpacing.md,
            LuciSpacing.md,
            LuciSpacing.md,
            0,
          ),
          child: Text(
            l10n.addonsSubtitle,
            style: LuciTextStyles.cardSubtitle(context),
          ),
        ),
        LuciHubSection(
          tiles: [
            for (final spec in AddonCatalog.all)
              buildAddonTile(
                context,
                ref,
                addon: spec.addon,
                title: l10n.string(spec.titleKey),
                subtitle: l10n.string(spec.subtitleKey),
                open: () => AddonScreen(spec: spec),
              ),
          ],
        ),
      ],
    );
  }
}

/// Live state at the top, so the section answers "is anything down?" before
/// the user scrolls into the list.
class _Summary extends StatelessWidget {
  const _Summary({
    required this.total,
    required this.running,
    required this.enabled,
  });

  final int total;
  final int running;
  final int enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        LuciSpacing.md,
        LuciSpacing.md,
        LuciSpacing.md,
        0,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: LuciSpacing.lg,
          vertical: LuciSpacing.md,
        ),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Icon(Icons.miscellaneous_services_outlined, color: scheme.primary),
            const SizedBox(width: LuciSpacing.md),
            Expanded(
              child: Text(
                // Argument order follows the ARB placeholders
                // (`{running} of {total}`), not this widget's fields.
                context.l10n.servicesSummary(running, total, enabled),
                style: LuciTextStyles.cardSubtitle(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ServiceListCard extends StatelessWidget {
  const _ServiceListCard({
    required this.services,
    required this.busyService,
    required this.enabled,
    required this.onAction,
  });

  final List<ServiceStatus> services;
  final String? busyService;
  final bool enabled;
  final Future<void> Function(ServiceStatus service, String action) onAction;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      margin: const EdgeInsets.symmetric(
        horizontal: LuciSpacing.md,
        vertical: LuciSpacing.sm,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: LuciCardStyles.standardRadius,
      ),
      child: Column(
        children: ListTile.divideTiles(
          context: context,
          tiles: [
            for (final service in services)
              ServiceRow(
                service: service,
                busy: busyService == service.name,
                enabled: enabled,
                onAction: (action) => onAction(service, action),
              ),
          ],
        ).toList(),
      ),
    );
  }
}

/// One line of explanation where a list would be.
class _Note extends StatelessWidget {
  const _Note({
    required this.icon,
    required this.text,
    this.action,
    this.onAction,
  });

  final IconData icon;
  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(LuciSpacing.md),
      child: Container(
        padding: const EdgeInsets.all(LuciSpacing.lg),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Icon(icon, color: scheme.onSurfaceVariant),
            const SizedBox(width: LuciSpacing.md),
            Expanded(
              child: Text(text, style: LuciTextStyles.cardSubtitle(context)),
            ),
            if (action != null)
              TextButton(onPressed: onAction, child: Text(action!)),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:luci_mobile/design/luci_design_system.dart';
import 'package:luci_mobile/l10n/addon_strings.dart';
import 'package:luci_mobile/l10n/luci_localizations.dart';
import 'package:luci_mobile/models/addon_spec.dart';
import 'package:luci_mobile/screens/addon_screen.dart';
import 'package:luci_mobile/screens/traffic_screen.dart';
import 'package:luci_mobile/services/addon_catalog.dart';
import 'package:luci_mobile/widgets/addon_hub_tile.dart';
import 'package:luci_mobile/widgets/luci_app_bar.dart';
import 'package:luci_mobile/widgets/luci_hub_tile.dart';

/// The add-on packages this router has, and what to do about the ones it
/// does not.
class AddonsScreen extends ConsumerWidget {
  const AddonsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;

    return Scaffold(
      appBar: LuciAppBar(title: l10n.addons, showBack: true),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: LuciSpacing.sm),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              LuciSpacing.md,
              LuciSpacing.sm,
              LuciSpacing.md,
              LuciSpacing.md,
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
              // Traffic history is a read-only view, not a form, so it has
              // no spec — but it belongs in the same list.
              buildAddonTile(
                context,
                ref,
                addon: Addon.nlbwmon,
                title: l10n.trafficHistory,
                subtitle: l10n.trafficHistorySubtitle,
                open: () => const TrafficScreen(),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

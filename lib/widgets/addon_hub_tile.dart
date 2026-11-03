import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:luci_mobile/models/addon_spec.dart';
import 'package:luci_mobile/services/addon_catalog.dart';
import 'package:luci_mobile/state/feature_providers.dart';
import 'package:luci_mobile/widgets/luci_feature_gate.dart';
import 'package:luci_mobile/widgets/luci_hub_tile.dart';

/// The icon each add-on's entry uses.
const Map<Addon, IconData> addonIcons = {
  Addon.sqm: Icons.speed,
  Addon.adblock: Icons.block,
  Addon.upnp: Icons.settings_input_antenna,
  Addon.ddns: Icons.dns_outlined,
  Addon.nlbwmon: Icons.data_usage,
};

/// One add-on entry, gated on the package this router actually has.
///
/// Shared by the add-ons screen and the Services section. The gating is the
/// part worth sharing: an unavailable add-on must stay visible with the
/// package name in its subtitle — vanishing would read as the app not
/// supporting it — and that rule was easy to lose when each list rewrote it.
LuciHubTile buildAddonTile(
  BuildContext context,
  WidgetRef ref, {
  required Addon addon,
  required String title,
  required String subtitle,
  required Widget Function() open,
}) {
  final scheme = Theme.of(context).colorScheme;
  final gate = ref.watch(featureProvider(AddonCatalog.feature(addon)));
  return LuciHubTile(
    icon: gate.available
        ? (addonIcons[addon] ?? Icons.extension_outlined)
        : Icons.download_outlined,
    iconColor: gate.available ? scheme.primary : scheme.outline,
    title: title,
    subtitle: gate.explain(context) ?? subtitle,
    enabled: gate.available,
    onTap: gate.available
        ? () => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => open()))
        : null,
  );
}

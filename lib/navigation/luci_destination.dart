import 'package:flutter/material.dart';

import 'package:luci_mobile/l10n/luci_localizations.dart';
import 'package:luci_mobile/navigation/luci_tab.dart';

/// The icon pair and label for one destination.
typedef LuciDestination = ({IconData filled, IconData outlined, String label});

/// One description of a destination, shared by the bottom bar and the drawer.
///
/// Two lists that each name their own icons drift: the bar gains a filled icon
/// and the drawer keeps the outline, and the same destination looks like two.
/// The switch is exhaustive, so a new [LuciTab] fails to compile until it has
/// a label.
LuciDestination luciDestination(LuciTab tab, BuildContext context) {
  final l10n = context.l10n;
  return switch (tab) {
    LuciTab.dashboard => (
      filled: Icons.dashboard,
      outlined: Icons.dashboard_outlined,
      label: l10n.dashboard,
    ),
    LuciTab.network => (
      filled: Icons.lan,
      outlined: Icons.lan_outlined,
      label: l10n.network,
    ),
    LuciTab.clients => (
      filled: Icons.people,
      outlined: Icons.people_outline,
      label: l10n.clients,
    ),
    LuciTab.cellular => (
      filled: Icons.signal_cellular_alt,
      outlined: Icons.signal_cellular_alt_2_bar,
      label: l10n.cellular,
    ),
    LuciTab.settings => (
      filled: Icons.settings,
      outlined: Icons.settings_outlined,
      label: l10n.settings,
    ),
  };
}

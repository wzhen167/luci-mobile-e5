import 'package:flutter/material.dart';

import 'package:luci_mobile/design/luci_design_system.dart';
import 'package:luci_mobile/l10n/luci_localizations.dart';
import 'package:luci_mobile/navigation/luci_destination.dart';
import 'package:luci_mobile/navigation/luci_tab.dart';

/// Every top-level destination, in the same order as the bottom bar.
///
/// The drawer stays as a second, thumb-reachable way to switch sections and as
/// the only navigation surface on wide layouts. It lists exactly the bar's
/// destinations — Services is a Settings tile, not a top-level entry, so it is
/// deliberately absent here too.
///
/// A plain drawer rather than Material's `NavigationDrawer`: the shell already
/// needs a header (which router am I configuring?) and a divider before the
/// app-level destination, and `NavigationDrawer.onDestinationSelected`
/// reports the index among *all* children, so a header or divider in the list
/// silently shifts every index after it.
class AppDrawer extends StatelessWidget {
  const AppDrawer({
    super.key,
    required this.selected,
    required this.onSelect,
    this.routerLabel,
  });

  final LuciTab selected;
  final ValueChanged<LuciTab> onSelect;

  /// The active router's address, so the drawer says which one this is.
  final String? routerLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;

    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: LuciSpacing.sm),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                LuciSpacing.lg,
                LuciSpacing.md,
                LuciSpacing.lg,
                LuciSpacing.md,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.appTitle,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  if (routerLabel != null && routerLabel!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      routerLabel!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const Divider(height: 1),
            const SizedBox(height: LuciSpacing.sm),
            for (final tab in LuciTab.values) ...[
              if (tab == LuciTab.settings) const Divider(height: 1),
              _DrawerTile(
                tab: tab,
                selected: tab == selected,
                onTap: () => onSelect(tab),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DrawerTile extends StatelessWidget {
  const _DrawerTile({
    required this.tab,
    required this.selected,
    required this.onTap,
  });

  final LuciTab tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final destination = luciDestination(tab, context);

    return ListTile(
      // A drawer only ever shows "where am I" or "where could I go", so the
      // filled icon is the one that belongs here.
      leading: Icon(
        selected ? destination.filled : destination.outlined,
        color: selected ? scheme.primary : scheme.onSurfaceVariant,
      ),
      title: Text(
        destination.label,
        style: theme.textTheme.bodyLarge?.copyWith(
          color: selected ? scheme.primary : scheme.onSurface,
          fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      selected: selected,
      selectedTileColor: scheme.primary.withValues(alpha: 0.08),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      contentPadding: const EdgeInsets.symmetric(horizontal: LuciSpacing.lg),
      onTap: () {
        // Closes the drawer before switching: the shell rebuilds its body on
        // selection, and a drawer left open over the new section reads as the
        // tap having only half worked.
        Navigator.of(context).maybePop();
        onTap();
      },
    );
  }
}

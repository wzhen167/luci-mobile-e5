import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:luci_mobile/l10n/luci_localizations.dart';
import 'package:luci_mobile/main.dart';
import 'package:luci_mobile/navigation/app_drawer.dart';
import 'package:luci_mobile/navigation/luci_destination.dart';
import 'package:luci_mobile/navigation/luci_shell_scope.dart';
import 'package:luci_mobile/navigation/luci_tab.dart';
import 'package:luci_mobile/screens/cellular_screen.dart';
import 'package:luci_mobile/screens/clients_screen.dart';
import 'package:luci_mobile/screens/dashboard_screen.dart';
import 'package:luci_mobile/screens/network_screen.dart';
import 'package:luci_mobile/screens/settings_screen.dart';
import 'package:luci_mobile/widgets/luci_navigation_enhancements.dart';

class MainScreen extends ConsumerStatefulWidget {
  const MainScreen({super.key, this.initialTab, this.interfaceToScroll});

  final LuciTab? initialTab;
  final String? interfaceToScroll;

  @override
  ConsumerState<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends ConsumerState<MainScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  LuciTab _selected = LuciTab.dashboard;
  String? _pendingInterface;

  @override
  void initState() {
    super.initState();
    if (widget.initialTab != null) _selected = widget.initialTab!;
    _pendingInterface = widget.interfaceToScroll;
  }

  @override
  void didUpdateWidget(MainScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.interfaceToScroll != oldWidget.interfaceToScroll) {
      _pendingInterface = widget.interfaceToScroll;
    }
    if (widget.initialTab != oldWidget.initialTab &&
        widget.initialTab != null) {
      _selected = widget.initialTab!;
    }
  }

  void _clearPendingInterface() {
    if (_pendingInterface == null) return;
    setState(() => _pendingInterface = null);
  }

  Widget _bodyFor(LuciTab tab) => switch (tab) {
    LuciTab.dashboard => const DashboardScreen(),
    LuciTab.network => NetworkScreen(
      pendingInterface: _pendingInterface,
      onConsumed: _clearPendingInterface,
    ),
    LuciTab.clients => const ClientsScreen(),
    LuciTab.cellular => const CellularScreen(),
    LuciTab.settings => const SettingsScreen(),
  };

  void _select(LuciTab tab) {
    if (tab == _selected) return;
    setState(() => _selected = tab);
    if (tab != LuciTab.network) _clearPendingInterface();
  }

  /// Drawer selection goes through the same reboot lockout as the bottom bar:
  /// the drawer must not be a way around a disabled destination.
  void _selectFromDrawer(LuciTab tab, {required bool isRebooting}) {
    if (isRebooting && !tab.allowedDuringReboot) return;
    _select(tab);
  }

  @override
  Widget build(BuildContext context) {
    final appState = ref.watch(appStateProvider);

    // The dashboard asks for a tab by name; honour it after this frame so the
    // request can be cleared without rebuilding mid-build.
    if (appState.requestedTab != null) {
      final requested = appState.requestedTab!;
      final requestedInterface = appState.requestedInterfaceToScroll;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // Cleared whatever happens: a request left standing replays on the
        // next mount, jumping the user to a tab they asked for before
        // logging out - or latches when it names the tab already showing.
        appState.requestedTab = null;
        appState.requestedInterfaceToScroll = null;
        if (!mounted || requested == _selected) return;
        setState(() {
          _selected = requested;
          if (requestedInterface != null) {
            _pendingInterface = requestedInterface;
          }
        });
      });
    }

    final isRebooting = appState.isRebooting;
    final routerLabel = appState.currentSession?.ipAddress;

    return LuciShellScope(
      openDrawer: () => _scaffoldKey.currentState?.openDrawer(),
      child: Scaffold(
        key: _scaffoldKey,
        drawer: AppDrawer(
          selected: _selected,
          routerLabel: routerLabel,
          onSelect: (tab) => _selectFromDrawer(tab, isRebooting: isRebooting),
        ),
        body: LuciTabTransition(
          transitionKey: 'tab_${_selected.name}',
          child: _bodyFor(_selected),
        ),
        bottomNavigationBar: Builder(
          builder: (context) {
            final scheme = Theme.of(context).colorScheme;

            return NavigationBar(
              // Five labels overflow in German and Russian at narrow widths;
              // showing only the selected one keeps them readable without
              // truncating.
              labelBehavior: MediaQuery.sizeOf(context).width < 400
                  ? NavigationDestinationLabelBehavior.onlyShowSelected
                  : NavigationDestinationLabelBehavior.alwaysShow,
              // Every destination is in the bar, so there is always a bar
              // position: the fallback only guards a build whose tab is not in
              // `bottomBar`, which would be a programming error, not a state.
              selectedIndex: _selected.bottomBarIndex ?? 0,
              onDestinationSelected: (index) {
                final tab = LuciTab.fromBottomIndex(index);
                if (tab == null) return;
                if (isRebooting && !tab.allowedDuringReboot) return;
                _select(tab);
              },
              destinations: [
                for (final tab in LuciTab.bottomBar)
                  _buildDestination(context, tab, isRebooting, scheme),
              ],
            );
          },
        ),
      ),
    );
  }

  NavigationDestination _buildDestination(
    BuildContext context,
    LuciTab tab,
    bool isRebooting,
    ColorScheme scheme,
  ) {
    final d = luciDestination(tab, context);
    final locked = isRebooting && !tab.allowedDuringReboot;
    // Grey is only correct in a light theme; the disabled tone has to come
    // from the scheme or the bar looks broken in dark mode.
    final lockedColor = scheme.onSurface.withValues(alpha: 0.38);

    Widget wrap(IconData icon) => Opacity(
      opacity: locked ? 0.5 : 1.0,
      child: Icon(icon, color: locked ? lockedColor : null),
    );

    return NavigationDestination(
      selectedIcon: wrap(d.filled),
      icon: wrap(d.outlined),
      label: d.label,
      tooltip: locked ? context.l10n.rebootingConnectionInterrupted : d.label,
    );
  }
}

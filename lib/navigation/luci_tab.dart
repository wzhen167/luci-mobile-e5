/// The shell's top-level destinations.
///
/// Deliberately an enum rather than an `int`. Tab positions moved when the
/// shell went from four destinations to five, and every hardcoded index
/// (`requestTab(2)` for Interfaces, `index != 3` for the reboot lockout)
/// silently pointed somewhere else. Naming them makes that a compile error.
///
/// Five destinations, all five in the bar. Services used to be a sixth entry
/// reachable only through a "More" button that opened the drawer — but the one
/// section behind that button is also a tile in Settings, so the button was a
/// second door to a room the user already knew how to find. It cost a bar slot
/// and a whole extra state (a tab with no bar position) to offer nothing.
/// Services is now a Settings tile only, and the bar holds exactly the
/// destinations the user navigates between.
///
/// Insights is likewise absent: it is a read-only group of four pages, so it
/// lives as a hub tile inside Settings rather than occupying a top-level slot
/// that Cellular — a section users open far more often — can use.
enum LuciTab {
  dashboard,
  network,
  clients,
  cellular,
  settings;

  /// The destinations the bottom bar renders, in bar order.
  ///
  /// Every destination is here; [bottomBarIndex] is therefore never null.
  /// Reordering this list moves every bar position, so keep it in sync with
  /// the enum order the drawer renders.
  static const List<LuciTab> bottomBar = <LuciTab>[
    dashboard,
    network,
    clients,
    cellular,
    settings,
  ];

  /// Whether the bottom bar offers this destination.
  bool get inBottomBar => bottomBar.contains(this);

  /// This destination's position in [bottomBar].
  ///
  /// Still nullable: the bar indexes into this list, and an unrecognised
  /// destination should show no selection rather than throw.
  int? get bottomBarIndex {
    final index = bottomBar.indexOf(this);
    return index < 0 ? null : index;
  }

  /// Whether this destination stays usable while the router is rebooting.
  ///
  /// Everything else reads live router state, so it has nothing to show —
  /// but Settings is where the reboot was started and where the user waits.
  bool get allowedDuringReboot => this == LuciTab.settings;

  /// Enums already expose `.index`; this is the inverse.
  static LuciTab fromIndex(int index) =>
      index >= 0 && index < LuciTab.values.length
      ? LuciTab.values[index]
      : LuciTab.dashboard;

  /// The destination at [index] in [bottomBar], or null when the bar hands
  /// back an index it does not have an entry for.
  static LuciTab? fromBottomIndex(int index) =>
      index >= 0 && index < bottomBar.length ? bottomBar[index] : null;
}

import 'package:flutter_test/flutter_test.dart';

import 'package:luci_mobile/navigation/luci_tab.dart';

/// The shell went from four destinations to five, which silently re-pointed
/// every hardcoded index. These pin the contract the enum replaced them with.
///
/// It has also lost one: Services used to be a sixth entry reachable only via
/// a "More" button, which duplicated the Settings tile for the same section.
/// The bar now holds every destination, and these tests say so — a future
/// change that adds a destination *without* adding it to the bar should fail
/// here rather than ship a tab nobody can reach.
void main() {
  test('the enum order is the one the drawer renders', () {
    expect(LuciTab.values, [
      LuciTab.dashboard,
      LuciTab.network,
      LuciTab.clients,
      LuciTab.cellular,
      LuciTab.settings,
    ]);
  });

  // The drawer and the bar must not disagree about the destinations they
  // share: two different orders for the same set reads as two different apps.
  test('the drawer order agrees with the bar order', () {
    final shared = [
      for (final tab in LuciTab.values)
        if (tab.inBottomBar) tab,
    ];
    expect(shared, LuciTab.bottomBar);
  });

  test('the bottom bar is the four original slots plus Cellular', () {
    expect(LuciTab.bottomBar, [
      LuciTab.dashboard,
      LuciTab.network,
      LuciTab.clients,
      LuciTab.cellular,
      LuciTab.settings,
    ]);
  });

  // Insights used to sit at bar position 3. Cellular took that exact slot, so
  // the three destinations to its left and Settings to its right did not move.
  test('Cellular occupies the slot Insights gave up', () {
    expect(LuciTab.bottomBar.indexOf(LuciTab.cellular), 3);
    expect(LuciTab.bottomBar.first, LuciTab.dashboard);
    expect(LuciTab.bottomBar.last, LuciTab.settings);
  });

  // Every destination in the bar, none behind a "More" button: the bar no
  // longer renders more entries than it has destinations, so a bar index can
  // never name a destination that does not exist.
  test('every destination is in the bar', () {
    expect(LuciTab.bottomBar, hasLength(LuciTab.values.length));
    expect(LuciTab.bottomBar.toSet(), hasLength(LuciTab.values.length));
    for (final tab in LuciTab.values) {
      expect(tab.inBottomBar, isTrue, reason: tab.name);
      expect(tab.bottomBarIndex, isNotNull, reason: tab.name);
    }
  });

  // Services is a Settings tile now. Re-adding it as a top-level destination
  // would bring the extra bar slot and the unreachable-tab problem back.
  test('Services is not a top-level destination', () {
    expect(
      LuciTab.values.map((tab) => tab.name),
      isNot(contains('services')),
    );
  });

  test('index and fromIndex round-trip', () {
    for (final tab in LuciTab.values) {
      expect(LuciTab.fromIndex(tab.index), tab);
    }
  });

  test('bar positions round-trip through the bar list', () {
    for (final tab in LuciTab.bottomBar) {
      final index = tab.bottomBarIndex;
      expect(index, isNotNull, reason: tab.name);
      expect(LuciTab.fromBottomIndex(index!), tab);
      expect(tab.inBottomBar, isTrue);
    }
  });

  // A NavigationBar can hand back any index; falling back to a real tab beats
  // a range error in the shell.
  test('an out-of-range index falls back rather than throwing', () {
    expect(LuciTab.fromIndex(-1), LuciTab.dashboard);
    expect(LuciTab.fromIndex(99), LuciTab.dashboard);
    expect(LuciTab.fromBottomIndex(-1), isNull);
    expect(LuciTab.fromBottomIndex(LuciTab.bottomBar.length), isNull);
    expect(LuciTab.fromBottomIndex(99), isNull);
  });

  // Everything else reads live router state and has nothing to show mid-reboot;
  // Settings is where the reboot was started and where the user waits it out.
  test('only Settings stays reachable during a reboot', () {
    expect(LuciTab.settings.allowedDuringReboot, isTrue);
    for (final tab in LuciTab.values.where((t) => t != LuciTab.settings)) {
      expect(tab.allowedDuringReboot, isFalse, reason: tab.name);
    }
  });
}

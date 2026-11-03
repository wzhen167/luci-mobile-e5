import 'package:flutter/widgets.dart';

/// Opens the shell's navigation drawer from inside a section.
///
/// Each section owns its own `Scaffold` and app bar, so the drawer lives one
/// Scaffold further up. `Scaffold.of(context)` from an app bar finds the
/// section's Scaffold — which has no drawer — and `openDrawer` then asserts.
/// This passes the shell's opener down instead, so a section never has to
/// know whether it is mounted in the shell or pushed onto its own route.
///
/// A pushed route is *not* a descendant of the shell's body, so
/// [maybeOf] returns null there and detail screens keep their back button.
class LuciShellScope extends InheritedWidget {
  const LuciShellScope({
    super.key,
    required this.openDrawer,
    required super.child,
  });

  final VoidCallback openDrawer;

  static LuciShellScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LuciShellScope>();

  @override
  bool updateShouldNotify(LuciShellScope oldWidget) =>
      openDrawer != oldWidget.openDrawer;
}

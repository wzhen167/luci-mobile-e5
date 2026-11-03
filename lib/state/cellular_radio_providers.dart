import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:luci_mobile/models/cellular_radio.dart';
import 'package:luci_mobile/services/cellular_radio.dart';
import 'package:luci_mobile/state/app_state_provider.dart';
import 'package:luci_mobile/state/cellular_providers.dart';
import 'package:luci_mobile/state/router_session.dart';

final cellularRadioServiceProvider = Provider<CellularRadioService?>((ref) {
  final api = ref.watch(apiServiceProvider);
  return api == null ? null : CellularRadioService(api);
});

/// Network lock and RF state, or null on a router without `mu300dash`.
///
/// Null is the honest answer for the routers that do not ship the vendor
/// backend: the section is then not offered at all, rather than shown empty
/// with controls that cannot work.
final cellularRadioProvider = FutureProvider<CellularRadioState?>((ref) async {
  final session = ref.watch(sessionProvider);
  final service = ref.watch(cellularRadioServiceProvider);
  if (session == null || service == null) return null;
  return service.read(session);
}, retry: (_, _) => null);

final cellularRadioMutationsProvider = Provider<CellularRadioMutations>(
  CellularRadioMutations.new,
);

/// Every write the radio tab can perform, with the refresh that follows it.
///
/// A lock change moves the modem: after it, both the radio state and the
/// interface list are stale, and re-reading only one of them leaves the
/// screen disagreeing with itself.
class CellularRadioMutations {
  CellularRadioMutations(this.ref);

  final Ref ref;

  Future<void> setMode(String mode) =>
      _run((service, session) => service.setMode(session, mode));

  Future<void> setBands({required String rat, required List<int> bands}) =>
      _run(
        (service, session) => service.setBands(session, rat: rat, bands: bands),
      );

  Future<void> restoreBands() =>
      _run((service, session) => service.restoreBands(session));

  Future<void> setCellLock({required bool lock}) =>
      _run((service, session) => service.setCellLock(session, lock: lock));

  Future<void> setAutoApply(bool enabled) =>
      _run((service, session) => service.setAutoApply(session, enabled));

  Future<void> setDataUp(bool up) =>
      _run((service, session) => service.setDataUp(session, up));

  Future<void> setRadioEnabled({required int slot, required bool enabled}) =>
      _run(
        (service, session) =>
            service.setRadioEnabled(session, slot: slot, enabled: enabled),
      );

  Future<void> _run(
    Future<void> Function(CellularRadioService service, RouterSession session)
    work,
  ) async {
    final service = ref.read(cellularRadioServiceProvider);
    final session = ref.read(sessionProvider);
    if (service == null || session == null) {
      throw StateError('no router session');
    }
    await work(service, session);
    if (!ref.mounted) return;
    ref.invalidate(cellularRadioProvider);
    ref.invalidate(cellularProvider);
  }
}

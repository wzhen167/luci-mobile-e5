import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:luci_mobile/models/cellular.dart';
import 'package:luci_mobile/models/uci_change.dart';
import 'package:luci_mobile/services/cellular_service.dart';
import 'package:luci_mobile/services/sms_inbox.dart';
import 'package:luci_mobile/services/uci_changeset_service.dart';
import 'package:luci_mobile/state/app_state_provider.dart';
import 'package:luci_mobile/state/uci_mutation.dart';

final cellularServiceProvider = Provider<CellularService?>((ref) {
  final api = ref.watch(apiServiceProvider);
  return api == null ? null : CellularService(api);
});

/// Configured cellular interfaces plus whatever telemetry the router offers.
final cellularProvider = FutureProvider<CellularSnapshot>((ref) async {
  final session = ref.watch(sessionProvider);
  final service = ref.watch(cellularServiceProvider);
  if (session == null || service == null) return const CellularSnapshot();
  return service.read(session);
}, retry: (_, _) => null);

/// The AT port to hand to `sms-tool`.
///
/// Null means "use the guessed default". It is a stored preference rather than
/// a per-read argument because a module with unusual port numbering needs the
/// choice to survive a refresh — otherwise every reload returns to a port that
/// does not work and the SMS tab looks permanently broken.
class SmsDeviceNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String device) => state = device;
}

final smsDeviceProvider = NotifierProvider<SmsDeviceNotifier, String?>(
  SmsDeviceNotifier.new,
);

/// The inbox, over whichever SMS service this router has.
///
/// The backend is discovered by asking, not by reading the ACL: a router whose
/// ACL probe failed would otherwise hide a working feature, and a router that
/// grants `file.exec` for its own scripts would advertise one that fails on
/// first use.
final smsInboxProvider = FutureProvider<SmsInboxSnapshot>((ref) async {
  final session = ref.watch(sessionProvider);
  final api = ref.watch(apiServiceProvider);
  if (session == null || api == null) return SmsInboxSnapshot.none;

  final snapshot = await ref.watch(cellularProvider.future);
  final device = ref.watch(smsDeviceProvider) ?? snapshot.suggestedSmsDevice;
  return SmsInbox(api).read(session, device: device);
}, retry: (_, _) => null);

final cellularMutationsProvider = Provider<CellularMutations>(
  CellularMutations.new,
);

class CellularMutations {
  CellularMutations(this.ref);

  final Ref ref;

  /// Stages and applies APN edits, then re-reads the interface list.
  ///
  /// `refreshDashboard` is true because a cellular interface is usually the
  /// WAN: its address and state appear on the dashboard, and leaving those
  /// stale after a reconnect is the most visible possible bug.
  Future<ApplyOutcome?> apply(
    List<UciOperation> ops, {
    BuildContext? context,
    void Function(ApplyPhase phase, Duration remaining)? onPhase,
  }) async {
    final outcome = await applyUciOperations(
      ref,
      ops,
      describe: 'cellular change',
      context: context,
      onPhase: onPhase,
      refreshDashboard: true,
    );
    if (ref.mounted) ref.invalidate(cellularProvider);
    return outcome;
  }

  Future<void> sendSms(String number, String body) async {
    final session = ref.read(sessionProvider);
    final api = ref.read(apiServiceProvider);
    if (session == null || api == null) return;
    final backend = (await ref.read(smsInboxProvider.future)).backend;
    if (backend == null) {
      throw StateError('no SMS service answered');
    }
    final snapshot = await ref.read(cellularProvider.future);
    await SmsInbox(api).send(
      session,
      backend: backend,
      number: number,
      body: body,
      device: ref.read(smsDeviceProvider) ?? snapshot.suggestedSmsDevice,
      // The card to send from: a dual-SIM router needs the active slot, and
      // sending from the wrong one silently uses the other subscription.
      card: snapshot.dataSim,
    );
    if (ref.mounted) ref.invalidate(smsInboxProvider);
  }

  Future<void> deleteSms(SmsMessage message) async {
    final session = ref.read(sessionProvider);
    final api = ref.read(apiServiceProvider);
    if (session == null || api == null) return;
    final backend = (await ref.read(smsInboxProvider.future)).backend;
    if (backend == null) return;
    final snapshot = await ref.read(cellularProvider.future);
    await SmsInbox(api).delete(
      session,
      backend: backend,
      message: message,
      device: ref.read(smsDeviceProvider) ?? snapshot.suggestedSmsDevice,
    );
    if (ref.mounted) ref.invalidate(smsInboxProvider);
  }
}

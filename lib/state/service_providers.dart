import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:luci_mobile/l10n/failure_text.dart';
import 'package:luci_mobile/l10n/luci_localizations.dart';
import 'package:luci_mobile/models/service_status.dart';
import 'package:luci_mobile/state/app_state_provider.dart';

/// Every init.d service the router reports, sorted by name.
///
/// One provider for both the Services section and the push-based screen the
/// Settings hub still opens: two providers would mean two RPCs for the same
/// list and two sources of truth about a service that was just restarted.
final servicesProvider = FutureProvider<List<ServiceStatus>>((ref) async {
  final session = ref.watch(sessionProvider);
  final api = ref.watch(apiServiceProvider);
  if (session == null || api == null) return const [];
  final map = await api.rcList(
    session.ipAddress,
    session.sysauth,
    session.useHttps,
  );
  final list = map.values.toList()..sort((a, b) => a.name.compareTo(b.name));
  return list;
}, retry: (_, _) => null);

final serviceActionsProvider = Provider<ServiceActions>(ServiceActions.new);

/// Start/stop/enable/disable, and the confirmations that must precede them.
///
/// Lives outside the widgets because both service views need exactly the same
/// rules — including which services are dangerous to stop, which is the part
/// that must not be reimplemented per screen.
class ServiceActions {
  ServiceActions(this.ref);

  final Ref ref;

  /// Stopping these cuts the connection the app itself is talking through, so
  /// the request is confirmed first. `network` and `firewall` take the whole
  /// router's connectivity with them; `uhttpd` and `rpcd` are the RPC path.
  static const Set<String> selfCritical = {
    'uhttpd',
    'rpcd',
    'network',
    'firewall',
  };

  /// Asks before an action that would most likely strand this app.
  Future<bool> confirmIfSelfCritical(
    BuildContext context,
    ServiceStatus service,
    String action,
  ) async {
    if (!selfCritical.contains(service.name)) return true;
    if (action != 'stop' && action != 'disable' && action != 'restart') {
      return true;
    }
    final l10n = context.l10n;
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(l10n.serviceCriticalTitle),
            content: Text(l10n.serviceCriticalBody(service.name)),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(l10n.cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(l10n.continueAnyway),
              ),
            ],
          ),
        ) ??
        false;
  }

  /// Runs one init.d action and reports the result.
  ///
  /// Returns true when the router accepted it, so a caller can decide whether
  /// to refresh. The list is invalidated here: `rc.list` is the only way to
  /// know the new state, and the row the user just tapped is on screen.
  Future<bool> act(
    BuildContext context,
    ServiceStatus service,
    String action,
  ) async {
    final session = ref.read(sessionProvider);
    final api = ref.read(apiServiceProvider);
    if (session == null || api == null) return false;

    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    try {
      final ok = await api.rcInit(
        session.ipAddress,
        session.sysauth,
        session.useHttps,
        name: service.name,
        action: action,
      );
      ref.invalidate(servicesProvider);
      if (!context.mounted) return ok;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            // `rc.init` reports a script that exited non-zero as status 0 with
            // `result: false`; claiming success there would be a lie about a
            // service the user is about to rely on.
            ok
                ? l10n.serviceActionDone(service.name)
                : l10n.serviceActionFailed,
          ),
        ),
      );
      return ok;
    } catch (e) {
      ref.invalidate(servicesProvider);
      if (!context.mounted) return false;
      messenger.showSnackBar(SnackBar(content: Text(apiErrorText(context, e))));
      return false;
    }
  }
}

import 'package:flutter/material.dart';

import 'package:luci_mobile/l10n/luci_localizations.dart';
import 'package:luci_mobile/models/service_status.dart';

/// One init.d service: state, what starts it at boot, and the actions.
///
/// Shared by the Services section and the pushed all-services screen. The
/// three-state [ServiceStatus.running] is why this is a widget and not a
/// `ListTile` written inline: a one-shot boot script has no daemon, and
/// rendering that as "stopped" is untrue.
class ServiceRow extends StatelessWidget {
  const ServiceRow({
    super.key,
    required this.service,
    required this.onAction,
    this.busy = false,
    this.enabled = true,
  });

  final ServiceStatus service;
  final Future<void> Function(String action) onAction;

  /// An action is in flight for this row.
  final bool busy;

  /// False while another row's action runs or the capability gate is closed.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;

    return ListTile(
      leading: busy
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            )
          : Icon(
              switch (service.running) {
                true => Icons.play_circle,
                false => Icons.stop_circle_outlined,
                // A one-shot script has no daemon to be up or down.
                null => Icons.task_alt,
              },
              color: service.running == true ? scheme.primary : scheme.outline,
            ),
      title: Text(service.name),
      subtitle: Text(
        [
          // Omitted entirely when the router did not report it: saying
          // "Stopped" about a boot script that ran fine is simply untrue.
          ?switch (service.running) {
            true => l10n.serviceRunning,
            false => l10n.serviceStopped,
            null => null,
          },
          service.enabled ? l10n.serviceStartsAtBoot : l10n.serviceNotAtBoot,
        ].join(' · '),
      ),
      trailing: PopupMenuButton<String>(
        enabled: enabled,
        onSelected: onAction,
        itemBuilder: (context) => [
          PopupMenuItem(value: 'start', child: Text(l10n.serviceStart)),
          PopupMenuItem(value: 'restart', child: Text(l10n.serviceRestart)),
          PopupMenuItem(value: 'stop', child: Text(l10n.serviceStop)),
          const PopupMenuDivider(),
          PopupMenuItem(
            value: service.enabled ? 'disable' : 'enable',
            child: Text(
              service.enabled ? l10n.serviceDisable : l10n.serviceEnable,
            ),
          ),
        ],
      ),
    );
  }
}

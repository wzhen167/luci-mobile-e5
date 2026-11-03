import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:luci_mobile/models/openclash.dart';
import 'package:luci_mobile/services/mock_clash_api.dart';
import 'package:luci_mobile/services/openclash_service.dart';
import 'package:luci_mobile/state/app_state_provider.dart';

/// Builds the controller client for the active router.
///
/// Reviewer mode returns one long-lived [MockClashApi]: a fresh stub per call
/// would forget the node the user just picked and snap every switch back,
/// which is exactly the "control that does not work" impression reviewer mode
/// must not give.
final clashApiFactoryProvider = Provider<ClashApiFactory>((ref) {
  final reviewerMode = ref.watch(
    appStateProvider.select((state) => state.reviewerModeEnabled),
  );
  if (reviewerMode) {
    final mock = MockClashApi();
    return ({
      required String host,
      required int port,
      String? secret,
    }) => mock;
  }
  return ({
    required String host,
    required int port,
    String? secret,
  }) => HttpClashApi(host: host, port: port, secret: secret);
});

final openClashServiceProvider = Provider<OpenClashService?>((ref) {
  final api = ref.watch(apiServiceProvider);
  if (api == null) return null;
  return OpenClashService(api, clients: ref.watch(clashApiFactoryProvider));
});

/// The OpenClash service and, when its core is up, the live controller state.
final openClashProvider = FutureProvider<OpenClashSnapshot>((ref) async {
  final session = ref.watch(sessionProvider);
  final service = ref.watch(openClashServiceProvider);
  if (session == null || service == null) return const OpenClashSnapshot();
  return service.read(session);
}, retry: (_, _) => null);

final openClashActionsProvider = Provider<OpenClashActions>(
  OpenClashActions.new,
);

/// Start/stop/restart, node switching and mode switching.
///
/// Every action re-reads the snapshot afterwards. The controller is a separate
/// source of truth from the router's config, and a screen that keeps its own
/// guess about what just happened drifts the moment a watchdog restarts the
/// core or a subscription update rewrites the groups.
class OpenClashActions {
  OpenClashActions(this.ref);

  final Ref ref;

  /// Runs one init.d action on the service. Returns whether the router
  /// accepted it — `rc.init` reports a non-zero exit as `result: false`.
  Future<bool> control(String action) async {
    final session = ref.read(sessionProvider);
    final api = ref.read(apiServiceProvider);
    if (session == null || api == null) return false;
    try {
      return await api.rcInit(
        session.ipAddress,
        session.sysauth,
        session.useHttps,
        name: 'openclash',
        action: action,
      );
    } finally {
      ref.invalidate(openClashProvider);
    }
  }

  /// Points [group] at [node].
  ///
  /// A `URLTest` or `Fallback` group accepts this too: the controller keeps
  /// the manual pick until the group's own strategy runs again, which is the
  /// same behaviour LuCI's dashboard has.
  Future<void> selectNode(String group, String node) async {
    final client = await _client();
    await client.send(
      'PUT',
      '/proxies/${Uri.encodeComponent(group)}',
      {'name': node},
    );
    ref.invalidate(openClashProvider);
  }

  /// Switches the live mode (`rule`, `global`, `direct`).
  Future<void> setMode(String mode) async {
    final client = await _client();
    await client.send('PATCH', '/configs', {'mode': mode});
    ref.invalidate(openClashProvider);
  }

  Future<ClashApi> _client() async {
    final session = ref.read(sessionProvider);
    if (session == null) {
      throw const ClashUnreachableException('no session');
    }
    final snapshot = await ref.read(openClashProvider.future);
    if (!snapshot.config.hasApi) {
      throw const ClashUnreachableException('no controller port');
    }
    return ref.read(clashApiFactoryProvider)(
      host: clashHost(session.ipAddress),
      port: snapshot.config.apiPort,
      secret: snapshot.config.secret,
    );
  }
}

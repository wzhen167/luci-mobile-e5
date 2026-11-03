import 'package:luci_mobile/models/cellular_radio.dart';
import 'package:luci_mobile/services/interfaces/api_service_interface.dart';
import 'package:luci_mobile/state/router_session.dart';

/// The router's answer when it refuses or fails a network change.
///
/// The vendor backend verifies every write against the modem and reports the
/// reason it could not ("Unsupported band requested", "Another network
/// operation is still running"). Passing that through is more useful than a
/// generic failure, so the text is kept as-is and the screen frames it.
class CellularRadioException implements Exception {
  const CellularRadioException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Network lock, data connection and per-SIM RF control.
///
/// Everything here goes through the vendor's `mu300dash` ubus object — the
/// same backend the router's own control centre drives. That matters for more
/// than convenience: a lock write sends AT commands, reads them back, restarts
/// the radio and verifies the setting survived, which a JSON-RPC client cannot
/// reproduce from the outside.
///
/// Writes are asynchronous on the router: `lock_set` queues a job and returns
/// its id, and progress is polled through `lock_status`. A band change
/// restarts the radio, so "done" routinely takes a minute.
class CellularRadioService {
  CellularRadioService(
    this._api, {
    this.pollInterval = const Duration(milliseconds: 1200),
    this.maxPolls = 160,
    this.wait,
  });

  final IApiService _api;

  /// How long to wait between job polls.
  final Duration pollInterval;

  /// Polls before giving up, so a wedged job cannot hold the screen forever.
  /// The backend abandons a job after 240 s; 160 × 1.2 s covers that, and the
  /// tail of the window only ever sees the backend's own error.
  final int maxPolls;

  /// Injected in tests so a job can be observed without real waiting.
  final Future<void> Function(Duration)? wait;

  /// The radio state, or null when this router has no `mu300dash`.
  ///
  /// `fresh` asks the backend to interrogate the modem instead of answering
  /// from its cache. That takes seconds of AT traffic, so it is reserved for
  /// an explicit refresh rather than every screen open.
  Future<CellularRadioState?> read(
    RouterSession session, {
    bool fresh = false,
  }) async {
    final lock = await _call(session, 'mu300dash', 'lock_get', {
      if (fresh) 'fresh': '1',
    });
    if (lock == null) return null;

    final sim = await _optional(session, 'mu300dash', 'sim_get');
    // Telemetry is asked for the slot the router says is carrying data; a
    // dormant slot answers with nothing and has no serving cell of its own.
    final slot = CellularRadioState.fromPayload(lock: lock, sim: sim).dataSim;
    final cells = await _optional(session, 'e5status', 'cells', {
      'slot': '${slot ?? 0}',
    });

    return CellularRadioState.fromPayload(lock: lock, sim: sim, cells: cells);
  }

  /// Switches the network mode (`auto`, `5g4g`, `4g`, `sa`, …).
  Future<void> setMode(RouterSession session, String mode) =>
      _apply(session, 'mode', mode);

  /// Restricts one RAT to [bands].
  ///
  /// One RAT per call because that is the backend's unit of work: the job
  /// restarts the radio and verifies the mask it wrote. Locking LTE and NR in
  /// the same visit therefore takes two jobs, in sequence.
  Future<void> setBands(
    RouterSession session, {
    required String rat,
    required List<int> bands,
  }) {
    if (bands.isEmpty) {
      throw const CellularRadioException(
        'At least one band has to stay locked',
      );
    }
    return _apply(session, rat, bands.join(','));
  }

  /// Puts both RATs back to every band the modem supports.
  Future<void> restoreBands(RouterSession session) =>
      _apply(session, 'bands_default', '');

  /// Locks to the cell that is serving right now, or removes the lock.
  ///
  /// `auto` means "lock to whatever is serving at this moment" in the vendor
  /// protocol — the opposite of what the word suggests. Removing the lock is
  /// `off`, so the two are never the same request.
  Future<void> setCellLock(RouterSession session, {required bool lock}) =>
      _apply(session, 'cell', lock ? 'auto' : 'off');

  Future<void> setAutoApply(RouterSession session, bool enabled) =>
      _apply(session, 'auto_apply', enabled ? 'on' : 'off');

  /// Brings the data interface up or down. The radio stays on.
  Future<void> setDataUp(RouterSession session, bool up) async {
    final answer = await _call(session, 'mu300dash', 'act', {
      'op': 'data',
      'arg': up ? 'up' : 'down',
    });
    if (answer == null) {
      throw CellularRadioException(
        'The router refused to bring mobile data ${up ? 'up' : 'down'}',
      );
    }
    _ensureOk(answer, 'data ${up ? 'up' : 'down'}');
  }

  /// Turns one SIM's radio on or off. The policy is persistent per slot.
  Future<void> setRadioEnabled(
    RouterSession session, {
    required int slot,
    required bool enabled,
  }) async {
    final answer = await _call(session, 'mu300dash', 'sim_radio_set', {
      'slot': '$slot',
      'enabled': enabled,
      'confirm': true,
    });
    if (answer == null) {
      throw CellularRadioException(
        'The router did not accept the radio change for SIM ${slot + 1}',
      );
    }
    await _finish(session, answer, 'radio');
  }

  Future<void> _apply(RouterSession session, String kind, String value) async {
    final answer = await _call(session, 'mu300dash', 'lock_set', {
      'kind': kind,
      'val': value,
    });
    if (answer == null) {
      throw CellularRadioException('The router refused the $kind change');
    }
    await _finish(session, answer, kind);
  }

  /// Follows a queued job to its result, or accepts an inline one.
  Future<void> _finish(
    RouterSession session,
    Map<String, dynamic> answer,
    String what,
  ) async {
    final id = answer['id']?.toString();
    if (id == null || id.isEmpty) {
      _ensureOk(answer, what);
      return;
    }

    for (var attempt = 0; attempt < maxPolls; attempt++) {
      final status = await _call(session, 'mu300dash', 'lock_status', {
        'id': id,
      });
      final state = status?['state']?.toString();
      if (state == 'done') {
        _ensureOk(status, what);
        return;
      }
      if (state == 'error') {
        throw CellularRadioException(
          status?['error']?.toString() ?? 'The modem rejected the $what change',
        );
      }
      await (wait?.call(pollInterval) ?? Future<void>.delayed(pollInterval));
    }
    throw CellularRadioException('The $what change did not finish in time');
  }

  void _ensureOk(Map<String, dynamic>? answer, String what) {
    final ok = answer?['ok'];
    if (ok == null) return;
    if (ok == true || ok == 1 || ok == '1') return;
    final message = answer?['error']?.toString();
    throw CellularRadioException(
      message == null || message.isEmpty
          ? 'The modem rejected the $what setting'
          : message,
    );
  }

  /// One ubus call, or null when the object answered with an error status.
  /// Throws on transport failure so "could not ask" stays distinguishable.
  Future<Map<String, dynamic>?> _call(
    RouterSession session,
    String object,
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    final result = await _api.call(
      session.ipAddress,
      session.sysauth,
      session.useHttps,
      object: object,
      method: method,
      params: params,
    );
    if (result is! List || result.isEmpty || result.first != 0) return null;
    final data = result.length > 1 ? result[1] : null;
    return data is Map ? Map<String, dynamic>.from(data) : null;
  }

  Future<Map<String, dynamic>?> _optional(
    RouterSession session,
    String object,
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    try {
      return await _call(session, object, method, params);
    } catch (_) {
      return null;
    }
  }
}

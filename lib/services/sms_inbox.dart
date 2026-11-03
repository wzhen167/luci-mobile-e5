import 'package:luci_mobile/models/cellular.dart';
import 'package:luci_mobile/services/interfaces/api_service_interface.dart';
import 'package:luci_mobile/services/sms_tool.dart';
import 'package:luci_mobile/state/router_session.dart';

/// Which SMS service a router actually offers.
///
/// There is no standard here: OpenWrt itself ships none, so every mobile
/// router vendor picks one. Two are supported, and they are not variants of
/// each other — different transports, different addressing, different
/// permissions:
///
/// * [vendor] — a ubus object (`e5-sms` on E5-class routers) that the
///   vendor's own LuCI app talks to. Messages are addressed by an opaque id.
/// * [tool] — `/usr/bin/sms-tool` through rpcd's `file.exec`, the
///   `luci-app-sms-tool` package. Messages are addressed by storage index.
///
/// The distinction reaches the UI in exactly one place: the AT-port field is
/// meaningless for a vendor backend, so it is hidden rather than shown and
/// ignored.
enum SmsBackend {
  vendor('e5-sms'),
  tool('sms-tool');

  const SmsBackend(this.label);

  /// What to call this backend in the UI. The name of the service, not a
  /// translated label: a user debugging a router needs the literal string
  /// they can look up in the system log.
  final String label;

  /// Whether [SmsTool]'s device argument applies.
  bool get needsDevice => this == SmsBackend.tool;
}

/// One read of the inbox: which backend answered, and what it said.
///
/// [backend] null is a real answer — "this router has no SMS service" — and is
/// distinct from an empty inbox, which [messages] being empty with a non-null
/// backend expresses.
class SmsInboxSnapshot {
  const SmsInboxSnapshot({this.backend, this.messages = const [], this.detail});

  final SmsBackend? backend;
  final List<SmsMessage> messages;

  /// The failure text from the last backend that was tried. Kept for the hint
  /// under the empty state: "no SMS service" without a reason is unactionable.
  final String? detail;

  bool get available => backend != null;

  static const SmsInboxSnapshot none = SmsInboxSnapshot();
}

/// Reads and writes the inbox, over whichever service the router has.
///
/// Each backend is probed rather than assumed: asking the capability layer
/// would mean trusting an ACL map that is itself best-effort, and a failed
/// probe there would hide a working feature. Here the probe *is* the first
/// read, so "available" means "it answered", which is the only claim worth
/// making.
class SmsInbox {
  const SmsInbox(this._api);

  final IApiService _api;

  Future<SmsInboxSnapshot> read(RouterSession session, {String? device}) async {
    final vendor = await _vendorMessages(session);
    if (vendor != null) {
      return SmsInboxSnapshot(backend: SmsBackend.vendor, messages: vendor);
    }

    try {
      final messages = await SmsTool(
        _api,
      ).list(session, device ?? SmsTool.defaultDevice);
      return SmsInboxSnapshot(backend: SmsBackend.tool, messages: messages);
    } catch (e) {
      // Neither service answered. Reporting the tool's error here would name
      // a binary the router does not have, so the message is the caller's,
      // and this only carries the detail for the hint.
      return SmsInboxSnapshot(detail: e.toString());
    }
  }

  Future<void> send(
    RouterSession session, {
    required SmsBackend backend,
    required String number,
    required String body,
    String? device,
    int? card,
  }) async {
    switch (backend) {
      case SmsBackend.vendor:
        // `card` is the SIM slot to send from; a dual-SIM router needs it and
        // a single-SIM one ignores it, so it is always sent.
        final answer = await _callE5(session, 'send', {
          'number': number,
          'text': body,
          'card': '${card ?? 0}',
        });
        if (answer == null) {
          throw StateError('${SmsBackend.vendor.label}: send was refused');
        }
      case SmsBackend.tool:
        await SmsTool(
          _api,
        ).send(session, device ?? SmsTool.defaultDevice, number, body);
    }
  }

  Future<void> delete(
    RouterSession session, {
    required SmsBackend backend,
    required SmsMessage message,
    String? device,
  }) async {
    switch (backend) {
      case SmsBackend.vendor:
        final id = int.tryParse(message.id ?? '${message.index}');
        if (id == null) {
          throw StateError('${SmsBackend.vendor.label}: message has no id');
        }
        final answer = await _callE5(session, 'delete', {'id': id});
        if (answer == null) {
          throw StateError('${SmsBackend.vendor.label}: delete was refused');
        }
      case SmsBackend.tool:
        await SmsTool(
          _api,
        ).delete(session, device ?? SmsTool.defaultDevice, message.index);
    }
  }

  /// `ubus call e5-sms list`, or null when that object is not there.
  Future<List<SmsMessage>?> _vendorMessages(RouterSession session) async {
    final data = await _callE5(session, 'list', const {});
    if (data == null) return null;
    final raw = data['messages'];
    if (raw is! List) return const [];
    return [
      for (final entry in raw)
        if (entry is Map) SmsMessage.fromE5(Map<String, dynamic>.from(entry)),
    ];
  }

  /// One `e5-sms` call. Null means "this router cannot answer", whether the
  /// object is missing, the ACL refuses it, or the reply is a ubus error.
  Future<Map<String, dynamic>?> _callE5(
    RouterSession session,
    String method,
    Map<String, dynamic> params,
  ) async {
    try {
      final result = await _api.call(
        session.ipAddress,
        session.sysauth,
        session.useHttps,
        object: SmsBackend.vendor.label,
        method: method,
        params: params,
      );
      if (result is! List || result.isEmpty || result.first != 0) return null;
      final data = result.length > 1 ? result[1] : null;
      if (data is! Map) return <String, dynamic>{};
      return Map<String, dynamic>.from(data);
    } catch (_) {
      return null;
    }
  }
}

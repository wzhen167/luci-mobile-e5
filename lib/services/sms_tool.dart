import 'package:flutter/foundation.dart';

import 'package:luci_mobile/models/cellular.dart';
import 'package:luci_mobile/services/interfaces/api_service_interface.dart';
import 'package:luci_mobile/state/router_session.dart';

/// SMS over the `sms-tool` helper, through rpcd's `file.exec`.
///
/// Every command lives here and nowhere else. `sms-tool` is packaged by
/// several projects (obsy's original, the LuCI app variants, router-vendor
/// forks) and their sub-command syntax is not identical: `list`, `read`,
/// `send` and `delete` are the shared core, but a fork that spells them
/// differently is fixed by editing this one class rather than the screen.
///
/// Nothing here guesses. A listing that cannot be parsed is reported as a
/// failure to the caller, not as "no messages" — an empty inbox and an
/// unreadable one look the same to a user and mean opposite things.
class SmsTool {
  const SmsTool(this._api);

  final IApiService _api;

  /// The path `luci-app-sms-tool` grants `file.exec` on.
  static const String binary = '/usr/bin/sms-tool';

  /// The conventional AT port on a Quectel-style module.
  ///
  /// Used when neither the config nor the user names one. A QMI/MBIM device
  /// such as `/dev/cdc-wdm0` is a control device and takes no AT commands, so
  /// it is never a candidate; `/dev/wwan0at0` is the AT port on Unisoc-based
  /// mobile routers, and the SMS tab lets the user correct this when the
  /// module numbers its ports differently.
  static const String defaultDevice = '/dev/ttyUSB2';

  /// Messages in the modem's storage, oldest index first.
  Future<List<SmsMessage>> list(RouterSession session, String device) async {
    final out = await _exec(session, [device, 'list']);
    return parseList(out);
  }

  /// Sends [body] to [number] and returns the tool's own output, for a
  /// "sent" confirmation the router itself produced.
  Future<String> send(
    RouterSession session,
    String device,
    String number,
    String body,
  ) => _exec(session, [device, 'send', number, body]);

  /// Removes one message by storage index.
  Future<String> delete(RouterSession session, String device, int index) =>
      _exec(session, [device, 'delete', '$index']);

  /// The AT answer to one command, for the signal/SIM fallback.
  ///
  /// Kept generic because the exact command a modem needs differs: `AT+CSQ`
  /// answers signal on every 3GPP module, `AT+COPS?` the operator. The caller
  /// decides which to ask and what the reply means.
  Future<String> at(RouterSession session, String device, String command) =>
      _exec(session, [device, 'at', command]);

  Future<String> _exec(RouterSession session, List<String> params) async {
    final result = await _api.call(
      session.ipAddress,
      session.sysauth,
      session.useHttps,
      object: 'file',
      method: 'exec',
      params: {'command': binary, 'params': params},
    );
    if (result is! List || result.isEmpty) return '';
    if (result.first != 0) {
      throw StateError('sms-tool refused: ubus status ${result.first}');
    }
    final data = result.length > 1 ? result[1] : null;
    if (data is! Map) return '';

    // rpcd answers `code` for the process exit status. A non-zero exit is a
    // failure even when ubus itself succeeded — the usual cause is that the
    // router's ACL grants `file.exec` but not this exact path.
    final code = data['code'];
    if (code is num && code != 0) {
      final stderr = data['stderr']?.toString().trim();
      throw StateError(
        stderr == null || stderr.isEmpty
            ? 'sms-tool exited with $code'
            : 'sms-tool: $stderr',
      );
    }
    return data['stdout']?.toString() ?? '';
  }

  /// Parses `sms-tool … list`.
  ///
  /// The observed shapes, all of which this accepts:
  /// - `1;+4917012345;24/05/06,12:00:00+32;REC READ;body`
  /// - tab-separated, same five columns
  /// - the same with the fields quoted
  ///
  /// A line that yields fewer than five columns keeps its index and its raw
  /// text as the body, so a firmware with a sixth column or a differently
  /// ordered one still shows something recognisable instead of dropping the
  /// message.
  @visibleForTesting
  static List<SmsMessage> parseList(String raw) {
    final messages = <SmsMessage>[];
    for (final line in raw.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      // Header lines from some forks ("Index;Number;Date;State;Text").
      final first = trimmed.split(RegExp(r'[;\t]')).first.trim();
      if (int.tryParse(_unquote(first)) == null) continue;

      final fields = _split(trimmed);
      if (fields.isEmpty) continue;
      final index = int.tryParse(_unquote(fields.first));
      if (index == null) continue;

      if (fields.length < 5) {
        messages.add(
          SmsMessage(index: index, body: fields.skip(1).join(' ').trim()),
        );
        continue;
      }

      final state = _unquote(fields[3]).toUpperCase();
      messages.add(
        SmsMessage(
          index: index,
          sender: _nullIfEmpty(_unquote(fields[1])),
          timestamp: _nullIfEmpty(_unquote(fields[2])),
          unread: state.contains('UNREAD'),
          body: _unquote(fields.sublist(4).join(';')),
        ),
      );
    }
    messages.sort((a, b) => a.index.compareTo(b.index));
    return messages;
  }

  static List<String> _split(String line) {
    if (line.contains(';')) return line.split(';');
    if (line.contains('\t')) return line.split('\t');
    return line.split(RegExp(r'\s{2,}'));
  }

  static String _unquote(String value) {
    var out = value.trim();
    if (out.length >= 2 &&
        ((out.startsWith('"') && out.endsWith('"')) ||
            (out.startsWith("'") && out.endsWith("'")))) {
      out = out.substring(1, out.length - 1);
    }
    return out;
  }

  static String? _nullIfEmpty(String value) => value.isEmpty ? null : value;
}

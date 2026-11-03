import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:luci_mobile/models/cellular.dart';
import 'package:luci_mobile/services/interfaces/api_service_interface.dart';
import 'package:luci_mobile/services/sms_inbox.dart';
import 'package:luci_mobile/state/router_session.dart';

/// A ubus surface that records what was asked of it.
class _FakeApi implements IApiService {
  _FakeApi(this.answers);

  final Map<String, Object?> answers;
  final List<({String object, String method, Map<String, dynamic>? params})>
  calls = [];

  @override
  Future<dynamic> call(
    String ipAddress,
    String sysauth,
    bool useHttps, {
    required String object,
    required String method,
    Map<String, dynamic>? params,
    BuildContext? context,
  }) async {
    calls.add((object: object, method: method, params: params));
    return answers['$object.$method'] ?? [4, 'Not found'];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

const _session = RouterSession(
  routerId: 'r',
  ipAddress: '192.168.9.1',
  sysauth: 'tok',
  useHttps: false,
  token: 1,
);

/// Verbatim from `ubus call e5-sms list` on an E5 mobile router.
const _vendorList = [
  0,
  {
    'messages': [
      {
        'id': 1000000017,
        'card': 0,
        'sim': 'SIM1',
        'number': '10086',
        'text': '【充值提醒】您于 2026-11-03 使用移动商城为本机充值 0.50 元。',
        'time': '2026-11-03T10:04:23+08:00',
        'state': 'received',
        'direction': 'in',
        'unread': true,
      },
      {
        'id': 1000000016,
        'card': 0,
        'sim': 'SIM1',
        'number': '106589665200',
        'text': '验证码 845189',
        'time': '2026-11-03T10:03:24+08:00',
        'state': 'received',
        'direction': 'in',
        'unread': false,
      },
    ],
  },
];

List<Object> _exec(String stdout) => [
  0,
  {'code': 0, 'stdout': stdout, 'stderr': ''},
];

void main() {
  group('backend discovery', () {
    test('the vendor object wins when it answers', () async {
      final api = _FakeApi({'e5-sms.list': _vendorList});
      final inbox = await SmsInbox(api).read(_session);

      expect(inbox.backend, SmsBackend.vendor);
      expect(inbox.available, isTrue);
      expect(inbox.messages, hasLength(2));
      // No AT port was needed, so no `file.exec` was attempted.
      expect(api.calls.where((c) => c.object == 'file'), isEmpty);
    });

    test('a message carries the SIM and the vendor id', () async {
      final api = _FakeApi({'e5-sms.list': _vendorList});
      final message = (await SmsInbox(api).read(_session)).messages.first;

      expect(message.id, '1000000017');
      expect(message.index, 1000000017, reason: 'id, as a number');
      expect(message.card, 0);
      expect(message.sim, 'SIM1');
      expect(message.sender, '10086');
      expect(message.unread, isTrue);
      expect(message.displayTime, isNotNull);
      expect(
        message.displayTime,
        isNot(contains('T')),
        reason: 'RFC 3339 is too long for a list row',
      );
    });

    test('sms-tool is used when the vendor object is missing', () async {
      final api = _FakeApi({
        'file.exec': _exec('1;+4917012345;26/11/02,09:14:22+04;REC READ;hi'),
      });
      final inbox = await SmsInbox(api).read(_session, device: '/dev/ttyUSB2');

      expect(inbox.backend, SmsBackend.tool);
      expect(inbox.messages.single.body, 'hi');
      final exec = api.calls.firstWhere((c) => c.object == 'file');
      expect(exec.params?['params'], ['/dev/ttyUSB2', 'list']);
    });

    test('an empty listing is an empty inbox, not a failure', () async {
      // `sms-tool` answering with nothing means "no messages on the SIM",
      // which is a different thing from a backend that is not there.
      final api = _FakeApi({'file.exec': _exec('')});
      final inbox = await SmsInbox(api).read(_session);

      expect(inbox.backend, SmsBackend.tool);
      expect(inbox.available, isTrue);
      expect(inbox.messages, isEmpty);
    });

    test('neither answering is unavailable, with the reason kept', () async {
      // The binary is missing: rpcd reports the shell's exit status, and
      // the screen needs that text to explain itself.
      final api = _FakeApi({
        'file.exec': [
          0,
          {
            'code': 127,
            'stdout': '',
            'stderr': 'sh: /usr/bin/sms-tool: not found',
          },
        ],
      });
      final inbox = await SmsInbox(api).read(_session);

      expect(inbox.available, isFalse);
      expect(inbox.messages, isEmpty);
      expect(inbox.detail, contains('sms-tool'));
    });
  });

  group('writes address the message the way the backend expects', () {
    test('a vendor delete uses the id, not a storage index', () async {
      final api = _FakeApi({
        'e5-sms.list': _vendorList,
        'e5-sms.delete': [0, {}],
      });
      final inbox = SmsInbox(api);
      final read = await inbox.read(_session);

      await inbox.delete(
        _session,
        backend: SmsBackend.vendor,
        message: read.messages.last,
      );

      final delete = api.calls.lastWhere((c) => c.method == 'delete');
      expect(delete.params, {'id': 1000000016});
    });

    test('a vendor send names the SIM slot', () async {
      final api = _FakeApi({
        'e5-sms.send': [0, {}],
      });
      await SmsInbox(api).send(
        _session,
        backend: SmsBackend.vendor,
        number: '10086',
        body: 'hello',
        card: 1,
      );

      final send = api.calls.single;
      expect(send.params, {'number': '10086', 'text': 'hello', 'card': '1'});
    });

    test('a vendor refusal is an error, not a silent success', () async {
      // `e5-sms` answers a ubus error status when the ACL forbids the write.
      final api = _FakeApi({});
      expect(
        () => SmsInbox(
          api,
        ).send(_session, backend: SmsBackend.vendor, number: '1', body: 'x'),
        throwsA(isA<StateError>()),
      );
    });

    test('a tool delete uses the storage index and the device', () async {
      final api = _FakeApi({'file.exec': _exec('OK')});
      await SmsInbox(api).delete(
        _session,
        backend: SmsBackend.tool,
        message: const SmsMessage(index: 7),
        device: '/dev/wwan0at0',
      );

      final exec = api.calls.single;
      expect(exec.params?['params'], ['/dev/wwan0at0', 'delete', '7']);
    });
  });

  test('only the tool backend needs an AT port', () {
    expect(SmsBackend.vendor.needsDevice, isFalse);
    expect(SmsBackend.tool.needsDevice, isTrue);
    expect(SmsBackend.vendor.label, 'e5-sms');
    expect(SmsBackend.tool.label, 'sms-tool');
  });
}

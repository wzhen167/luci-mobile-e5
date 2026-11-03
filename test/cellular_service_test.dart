import 'package:flutter_test/flutter_test.dart';

import 'package:luci_mobile/models/cellular.dart';
import 'package:luci_mobile/services/cellular_service.dart';
import 'package:luci_mobile/services/sms_tool.dart';

void main() {
  group('CellularTelemetry.fromModemManager', () {
    test('reads the flat `info` shape', () {
      // Measured shape of `ubus call modemmanager info` on OpenWrt.
      final telemetry = CellularTelemetry.fromModemManager({
        'imsi': '262029915879434',
        'operator': 'Vodafone.de',
        'technology': 'lte',
        'device': 'Modem1',
        'iccid': '89492099166029838939',
        'imei': '861107037891430',
        'signal': '47',
      });

      expect(telemetry.operatorName, 'Vodafone.de');
      expect(telemetry.technology, 'lte');
      expect(telemetry.signalPercent, 47);
      expect(telemetry.imei, '861107037891430');
      expect(telemetry.isEmpty, isFalse);
    });

    test('a numeric signal is accepted as well as a string', () {
      final telemetry = CellularTelemetry.fromModemManager({'signal': 80});
      expect(telemetry.signalPercent, 80);
    });

    test('placeholder values read as absent, not as data', () {
      final telemetry = CellularTelemetry.fromModemManager({
        'operator': '--',
        'signal': '--',
      });
      expect(telemetry.operatorName, isNull);
      expect(telemetry.signalPercent, isNull);
      expect(telemetry.isEmpty, isTrue);
    });

    test('dBm and bars are derived and clamped', () {
      CellularTelemetry at(int percent) =>
          CellularTelemetry(signalPercent: percent);

      expect(at(0).approximateDbm, -113);
      expect(at(100).approximateDbm, 87);
      expect(at(150).approximateDbm, 87, reason: 'clamped');
      expect(at(0).bars, 0);
      expect(at(10).bars, 1);
      expect(at(50).bars, 2);
      expect(at(100).bars, 4);
      expect(const CellularTelemetry().approximateDbm, isNull);
    });
  });

  group('CellularService.telemetryFrom', () {
    test('unwraps the `modem` list', () {
      final telemetry = CellularService.telemetryFrom({
        'modem': [
          {'operator': 'Telekom', 'signal': '30'},
        ],
      });
      expect(telemetry?.operatorName, 'Telekom');
      expect(telemetry?.signalPercent, 30);
    });

    test('reads the nested `dump` shape, where signal lives under generic', () {
      final telemetry = CellularService.telemetryFrom({
        'modem': [
          {
            'generic': {
              'device': 'Modem1',
              'manufacturer': 'QUECL',
              'signal-quality': {'recent': 'yes', 'value': '62'},
            },
          },
        ],
      });
      expect(telemetry?.signalPercent, 62);
      expect(telemetry?.model, 'QUECL');
    });

    test(
      'an empty or shapeless payload yields null, not a zero-signal modem',
      () {
        expect(CellularService.telemetryFrom(null), isNull);
        expect(CellularService.telemetryFrom({'modem': <dynamic>[]}), isNull);
        expect(CellularService.telemetryFrom({'modem': 'nonsense'}), isNull);
      },
    );
  });

  group('SmsTool.parseList', () {
    test('parses the semicolon shape', () {
      final messages = SmsTool.parseList(
        '1;+4917012345;24/05/06,12:00:00+32;REC READ;Hello there\n'
        '2;+4917099999;24/05/06,13:10:00+32;REC UNREAD;Second',
      );

      expect(messages, hasLength(2));
      expect(messages.first.index, 1);
      expect(messages.first.sender, '+4917012345');
      expect(messages.first.timestamp, '24/05/06,12:00:00+32');
      expect(messages.first.body, 'Hello there');
      expect(messages.first.unread, isFalse);
      expect(messages.last.unread, isTrue);
    });

    test('parses tab-separated and quoted output', () {
      final messages = SmsTool.parseList(
        '"3"\t"+123"\t"24/05/07,08:00:00+32"\t"REC UNREAD"\t"Body text"',
      );
      expect(messages.single.index, 3);
      expect(messages.single.sender, '+123');
      expect(messages.single.body, 'Body text');
      expect(messages.single.unread, isTrue);
    });

    test('keeps a message it cannot split rather than dropping it', () {
      // A firmware with an extra column still shows something recognisable.
      final messages = SmsTool.parseList('7;+111');
      expect(messages.single.index, 7);
      expect(messages.single.body, '+111');
    });

    test('skips header lines and blank lines', () {
      final messages = SmsTool.parseList(
        'Index;Number;Date;State;Text\n'
        '\n'
        '1;+1;now;REC READ;one',
      );
      expect(messages, hasLength(1));
      expect(messages.single.index, 1);
    });

    test('an empty listing is empty, not a parse failure', () {
      expect(SmsTool.parseList(''), isEmpty);
      expect(SmsTool.parseList('\n\n'), isEmpty);
    });

    test('results are ordered by storage index', () {
      final messages = SmsTool.parseList('2;a;t;REC READ;b\n1;c;t;REC READ;d');
      expect(messages.map((m) => m.index), [1, 2]);
    });

    test('a body containing semicolons survives', () {
      final messages = SmsTool.parseList('1;+1;t;REC READ;part one;part two');
      expect(messages.single.body, 'part one;part two');
    });
  });
}

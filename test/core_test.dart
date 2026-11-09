import 'dart:typed_data';

import 'package:boxster_srs/core/clear.dart';
import 'package:boxster_srs/core/elm327.dart';
import 'package:boxster_srs/core/mock_adapter.dart';
import 'package:boxster_srs/core/module.dart';
import 'package:boxster_srs/core/obd_pids.dart';
import 'package:boxster_srs/core/scanner.dart';
import 'package:boxster_srs/core/transport.dart';
import 'package:boxster_srs/core/uds.dart';
import 'package:boxster_srs/core/units.dart';
import 'package:boxster_srs/core/known_modules.dart';
import 'package:flutter_test/flutter_test.dart';

/// The fake adapter from the Python test, ported verbatim.
String fakeAdapter(String cmd) {
  final c = cmd.trim().toUpperCase();
  if (c.startsWith('AT')) return 'OK\r>';
  if (c.startsWith('02 3E 00')) return '77F 02 7E 00 00 00 00 00 00\r>';
  if (c.startsWith('03 19 02 FF')) {
    return '77F 10 0E 59 02 FF 80 01 04 2F 80 02\r'
        '77F 21 05 09 90 10 00 08 00 00\r>';
  }
  if (c.startsWith('03 22 F1 97')) {
    return '77F 10 0B 62 F1 97 41 49 52 42\r'
        '77F 21 41 47 20 20 00 00 00 00\r>';
  }
  return 'NO DATA\r>';
}

Future<(Elm327, Uds, MockTransport)> connectFake() async {
  final t = MockTransport(fakeAdapter, latency: Duration.zero);
  final elm = Elm327(t);
  await elm.open();
  await elm.setBits(11);
  await elm.setTarget(0x715, resp: 0x77F);
  return (elm, Uds(elm), t);
}

void main() {
  group('fake adapter (ported Python test)', () {
    test('TesterPresent answers 7E 00', () async {
      final (_, uds, _) = await connectFake();
      final r = await uds.single([sidTesterPresent, 0x00]);
      expect(r, equals(Uint8List.fromList([0x7E, 0x00])));
    });

    test('F197 system name decodes to AIRBAG', () async {
      final (_, uds, _) = await connectFake();
      final v = await uds.readDid(0xF197);
      expect(String.fromCharCodes(v).trim(), equals('AIRBAG'));
    });

    test('ReadDTC 19 02 FF yields two DTCs with correct status', () async {
      final (_, uds, _) = await connectFake();
      final dtcs = await uds.readDtcs();
      expect(dtcs.length, equals(2));
      expect(dtcs[0].raw, equals('800104'));
      expect(dtcs[0].status, equals(0x2F));
      expect(dtcs[0].sae, equals('B0001-04'));
      expect(dtcs[0].statusNames,
          equals('testFailed,testFailedThisCycle,pending,confirmed,failedSinceClear'));
      expect(dtcs[1].raw, equals('800205'));
      expect(dtcs[1].status, equals(0x09));
      expect(dtcs[1].sae, equals('B0002-05'));
      expect(dtcs[1].statusNames, equals('testFailed,confirmed'));
    });

    test('identify + looksLikeAirbag', () async {
      final (_, uds, _) = await connectFake();
      final info = await uds.identify();
      expect(info['system name'], equals('AIRBAG'));
      final dtcs = await uds.readDtcs();
      expect(looksLikeAirbag(info, dtcs), isTrue);
      expect(looksLikeAirbag(<String, String>{}, dtcs), isTrue,
          reason: 'fresh B-code with testFailed is enough');
      expect(looksLikeAirbag(<String, String>{'system name': 'PDK'}, const []),
          isFalse);
      expect(
          looksLikeAirbag(
              <String, String>{'spare part number': '991 618 001 07'}, const []),
          isTrue,
          reason: 'Porsche 9xx 618 xxx family');
    });

    test('requests are single-frame and padded to 8 bytes', () async {
      final (_, uds, t) = await connectFake();
      await uds.single([sidTesterPresent, 0x00]);
      expect(t.sent.last, equals('02 3E 00 00 00 00 00 00'));
      await uds.readDid(0xF197);
      expect(t.sent.last, equals('03 22 F1 97 00 00 00 00'));
    });

    test('init sequence is verbatim', () async {
      final t = MockTransport((c) {
        if (c == 'ATI') return 'ELM327 v1.5\r>';
        if (c == 'ATRV') return '11.8V\r>';
        return 'OK\r>';
      }, latency: Duration.zero);
      final elm = Elm327(t);
      await elm.open();
      await elm.init();
      expect(
          t.sent,
          equals([
            'ATZ',
            'ATE0',
            'ATL0',
            'ATS1',
            'ATH1',
            'ATCAF0',
            'ATCFC1',
            'ATAT0',
            'ATAL',
            'ATI',
            'ATRV',
          ]));
      expect(elm.adapterId, equals('ELM327 v1.5'));
      expect(elm.batteryVolts, closeTo(11.8, 0.001));
      expect(elm.batteryLow, isTrue);
    });
  });

  group('Uds.request allow-list', () {
    test('refuses SecurityAccess 0x27', () async {
      final (_, uds, t) = await connectFake();
      final before = t.sent.length;
      await expectLater(uds.request([0x27, 0x01]), throwsA(isA<UdsException>()));
      expect(t.sent.length, equals(before), reason: 'nothing transmitted');
    });

    test('refuses WriteDataByIdentifier 0x2E', () async {
      final (_, uds, t) = await connectFake();
      final before = t.sent.length;
      await expectLater(uds.request([0x2E, 0xF1, 0x90, 0x00]),
          throwsA(isA<UdsException>()));
      expect(t.sent.length, equals(before));
    });

    test('refuses RoutineControl 0x31, ECUReset 0x11, download 0x34-0x38',
        () async {
      final (_, uds, t) = await connectFake();
      final before = t.sent.length;
      for (final sid in [0x31, 0x11, 0x34, 0x35, 0x36, 0x37, 0x38]) {
        await expectLater(uds.request([sid, 0x01]), throwsA(isA<UdsException>()),
            reason: 'SID 0x${sid.toRadixString(16)}');
      }
      expect(t.sent.length, equals(before));
    });

    test('refuses programming session 0x10 0x02', () async {
      final (_, uds, _) = await connectFake();
      await expectLater(uds.request([sidSession, 0x02]),
          throwsA(isA<UdsException>()));
      await expectLater(uds.request([sidSession, 0x82]),
          throwsA(isA<UdsException>()));
    });

    test('refuses 0x14 to functional 0x7DF', () async {
      final (elm, uds, t) = await connectFake();
      await elm.setTarget(0x7DF);
      final before = t.sent.length;
      await expectLater(uds.request([sidClearDtc, 0xFF, 0xFF, 0xFF]),
          throwsA(isA<UdsException>()));
      expect(t.sent.length, equals(before));
    });

    test('refuses 0x14 to 29-bit functional 0x18DB33F1', () async {
      final (elm, uds, _) = await connectFake();
      await elm.setBits(29);
      await elm.setTarget(0x18DB33F1);
      await expectLater(uds.request([sidClearDtc, 0xFF, 0xFF, 0xFF]),
          throwsA(isA<UdsException>()));
    });

    test('0x14 to powertrain 0x7E0 refused by default, allowed with flag',
        () async {
      final (elm, uds, t) = await connectFake();
      await elm.setTarget(0x7E0);
      await expectLater(uds.request([sidClearDtc, 0xFF, 0xFF, 0xFF]),
          throwsA(isA<UdsException>()));
      final before = t.sent.length;
      await uds.request([sidClearDtc, 0xFF, 0xFF, 0xFF],
          allowPowertrainClear: true);
      expect(t.sent.length, equals(before + 1));
      expect(t.sent.last, equals('04 14 FF FF FF 00 00 00'));
    });

    test('Mode 01 only towards the DME 0x7E0', () async {
      final (elm, uds, _) = await connectFake();
      await expectLater(uds.request([sidObdMode01, 0x0C]),
          throwsA(isA<UdsException>()),
          reason: 'target is 0x715');
      await elm.setTarget(0x7E0, resp: 0x7E8);
      await uds.request([sidObdMode01, 0x0C]); // allowed, mock says NO DATA
    });
  });

  group('ISO-TP parsing', () {
    test('11-bit single + multi frame', () {
      final r = Elm327.parseFrames(
          '77F 10 0B 62 F1 97 41 49 52 42\n77F 21 41 47 20 20 00 00 00 00', 11);
      expect(r.length, equals(1));
      expect(r[0x77F],
          equals(Uint8List.fromList([0x62, 0xF1, 0x97, 0x41, 0x49, 0x52, 0x42, 0x41, 0x47, 0x20, 0x20])));
    });

    test('29-bit header is 8 hex chars', () {
      final r = Elm327.parseFrames(
          '18 DA F1 15 10 0B 59 02 FF 80 01 04\n18 DA F1 15 21 2F 80 02 05 09 00 00 00', 29);
      expect(r.keys.single, equals(0x18DAF115));
      expect(r[0x18DAF115],
          equals(Uint8List.fromList([0x59, 0x02, 0xFF, 0x80, 0x01, 0x04, 0x2F, 0x80, 0x02, 0x05, 0x09])));
    });

    test('29-bit single frame without spaces', () {
      final r = Elm327.parseFrames('18DAF115027E000000000000', 29);
      expect(r[0x18DAF115], equals(Uint8List.fromList([0x7E, 0x00])));
    });

    test('noise lines and flow control are ignored', () {
      final r = Elm327.parseFrames(
          'SEARCHING...\nNO DATA\n77F 30 00 00 00 00 00 00 00\nCAN ERROR\n7E8 03 7F 19 78 00 00 00 00', 11);
      expect(r.length, equals(1));
      expect(r[0x7E8], equals(Uint8List.fromList([0x7F, 0x19, 0x78])));
      expect(Uds.isPending(r[0x7E8]!), isTrue);
    });

    test('multiple responders on a wide filter', () {
      final r = Elm327.parseFrames(
          '77F 02 7E 00 00 00 00 00 00\n7A5 02 7E 00 00 00 00 00 00', 11);
      expect(r.keys.toList(), equals([0x77F, 0x7A5]));
    });
  });

  group('addressing', () {
    test('11-bit exact and wide', () async {
      final t = MockTransport((_) => 'OK\r>', latency: Duration.zero);
      final elm = Elm327(t);
      await elm.open();
      await elm.setBits(11);
      await elm.setTarget(0x715);
      expect(elm.respId, equals(0x71D));
      expect(t.sent.sublist(1), equals(['ATSH715', 'ATCRA71D']));
      t.sent.clear();
      await elm.setTarget(0x715, wideFilter: true);
      expect(elm.respId, isNull);
      expect(t.sent, equals(['ATSH715', 'ATCF700', 'ATCM700']));
    });

    test('29-bit exact and wide', () async {
      final t = MockTransport((_) => 'OK\r>', latency: Duration.zero);
      final elm = Elm327(t);
      await elm.open();
      await elm.setBits(29);
      t.sent.clear();
      await elm.setTarget(0x18DA15F1);
      expect(elm.respId, equals(0x18DAF115));
      expect(t.sent, equals(['ATCP18', 'ATSHDA15F1', 'ATCRA18DAF115']));
      t.sent.clear();
      await elm.setTarget(0x18DA15F1, wideFilter: true);
      expect(t.sent, equals(['ATCP18', 'ATSHDA15F1', 'ATCF18DAF100', 'ATCM1FFFFF00']));
    });

    test('ATST units of 4 ms, clamped', () {
      expect(Elm327.stValue(60), equals(15));
      expect(Elm327.stValue(400), equals(100));
      expect(Elm327.stValue(1020), equals(255));
      expect(Elm327.stValue(5000), equals(255));
      expect(Elm327.stValue(1), equals(1));
    });
  });

  group('Mode 01 PID decoding', () {
    test('0C rpm = (A*256+B)/4', () {
      final p = pidByNumber(0x0C)!;
      expect(decodeMode01(p, Uint8List.fromList([0x41, 0x0C, 0x0C, 0xD0])),
          closeTo(820.0, 0.001));
    });

    test('05 coolant = A-40', () {
      final p = pidByNumber(0x05)!;
      expect(decodeMode01(p, Uint8List.fromList([0x41, 0x05, 0x80])),
          closeTo(88.0, 0.001));
    });

    test('06 STFT = (A-128)*100/128', () {
      final p = pidByNumber(0x06)!;
      expect(decodeMode01(p, Uint8List.fromList([0x41, 0x06, 0x80])),
          closeTo(0.0, 0.001));
      expect(decodeMode01(p, Uint8List.fromList([0x41, 0x06, 0x90])),
          closeTo(12.5, 0.001));
      expect(decodeMode01(p, Uint8List.fromList([0x41, 0x06, 0x00])),
          closeTo(-100.0, 0.001));
    });

    test('0D speed, 04 load, 42 voltage', () {
      expect(decodeMode01(pidByNumber(0x0D)!, Uint8List.fromList([0x41, 0x0D, 0x3C])),
          closeTo(60, 0.001));
      expect(decodeMode01(pidByNumber(0x04)!, Uint8List.fromList([0x41, 0x04, 0xFF])),
          closeTo(100, 0.001));
      expect(decodeMode01(pidByNumber(0x42)!, Uint8List.fromList([0x41, 0x42, 0x36, 0xB0])),
          closeTo(14.0, 0.001));
    });

    test('mismatched pid or short payload -> null', () {
      final p = pidByNumber(0x0C)!;
      expect(decodeMode01(p, Uint8List.fromList([0x41, 0x0D, 0x00, 0x00])), isNull);
      expect(decodeMode01(p, Uint8List.fromList([0x41, 0x0C, 0x00])), isNull);
    });
  });

  group('NRC decoding', () {
    test('check() throws with NRC name', () {
      expect(
        () => Uds.check(Uint8List.fromList([0x7F, 0x14, 0x22]), sidClearDtc),
        throwsA(predicate((e) =>
            e is UdsException &&
            e.nrc == 0x22 &&
            e.message.contains('conditionsNotCorrect'))),
      );
      expect(
        () => Uds.check(Uint8List.fromList([0x7F, 0x14, 0x33]), sidClearDtc),
        throwsA(predicate((e) =>
            e is UdsException && e.message.contains('securityAccessDenied'))),
      );
    });

    test('check() strips positive SID', () {
      expect(Uds.check(Uint8List.fromList([0x54]), sidClearDtc), isEmpty);
      expect(Uds.check(Uint8List.fromList([0x7E, 0x00]), sidTesterPresent),
          equals(Uint8List.fromList([0x00])));
    });
  });

  group('MockAdapter end to end', () {
    test('scan finds the airbag module and the 29-bit gateway', () async {
      final mock = MockAdapter(latency: Duration.zero);
      final t = mock.transport();
      final elm = Elm327(t);
      await elm.open();
      await elm.init();
      final uds = Uds(elm);
      final scanner = Scanner(elm, uds);
      List<Module> found = const [];
      await for (final p in scanner.run()) {
        if (p.phase == 'done') found = p.found!;
      }
      expect(found.map((m) => m.address).toList(),
          containsAll(['715', '7A5', '18DA40F1']));
      expect(found.where((m) => m.address == '7E0'), isEmpty,
          reason: 'powertrain skipped by default');
      final airbag = found.firstWhere((m) => m.address == '715');
      expect(airbag.isAirbag, isTrue);
      expect(airbag.systemName, equals('AIRBAG'));
      expect(airbag.dtcs.length, equals(2));
      expect(found.where((m) => m.isAirbag).length, equals(1));
    });

    test('clear handles 0x78 pending and reports still-failed fault', () async {
      final mock = MockAdapter(latency: Duration.zero);
      final elm = Elm327(mock.transport());
      await elm.open();
      await elm.init();
      final uds = Uds(elm);
      final m = Module(bits: 11, reqId: 0x715, respId: 0x77F);
      await Scanner(elm, uds).refreshModule(m);
      expect(m.dtcs.length, equals(2));

      final r1 = await clearModule(elm, uds, m);
      expect(r1.positive, isTrue);
      expect(r1.explicit54, isTrue, reason: '0x54 captured on the TP poll');
      expect(r1.lines.any((l) => l.contains('pending')), isTrue);
      expect(r1.stillFailed, isTrue, reason: 'squib still unplugged');
      expect(r1.dtcsAfter.length, equals(1));

      final r2 = await clearModule(elm, uds, m);
      expect(r2.positive, isTrue);
      expect(r2.stillFailed, isFalse);
      expect(r2.dtcsAfter, isEmpty);
    });

    test('clear refuses 0x7DF before transmitting', () async {
      final mock = MockAdapter(latency: Duration.zero);
      final t = mock.transport();
      final elm = Elm327(t);
      await elm.open();
      final uds = Uds(elm);
      final m = Module(bits: 11, reqId: 0x7DF, respId: 0x7E8);
      await expectLater(clearModule(elm, uds, m, allowPowertrain: true),
          throwsA(isA<UdsException>()));
      expect(t.sent.where((c) => c.startsWith('04 14')), isEmpty);
    });

    test('Mode 01 live read', () async {
      final mock = MockAdapter(latency: Duration.zero);
      final elm = Elm327(mock.transport());
      await elm.open();
      await elm.init();
      final live = ObdLive(elm, Uds(elm));
      await live.prepare();
      final rpm = await live.read(pidByNumber(0x0C)!);
      expect(rpm, isNotNull);
      expect(rpm!, inInclusiveRange(700, 950));
      final v = await live.read(pidByNumber(0x42)!);
      expect(v!, inInclusiveRange(13.5, 14.5));
    });
  });
}

// ---------------------------------------------------------------------------
// Units (display conversion; raw values stay SI)
// ---------------------------------------------------------------------------
void _unitsTests() {
  group('Units', () {
    final speed = pidByNumber(0x0D)!;
    final coolant = pidByNumber(0x05)!;
    final rpm = pidByNumber(0x0C)!;

    test('US converts km/h -> mph and °C -> °F', () {
      const u = Units(UnitSystem.us);
      expect(u.convert(speed, 100), closeTo(62.137, 0.01));
      expect(u.label(speed), 'mph');
      expect(u.convert(coolant, 100), 212);
      expect(u.label(coolant), '°F');
      expect(u.format(coolant, 102), '216');
    });

    test('metric leaves values alone', () {
      const u = Units(UnitSystem.metric);
      expect(u.convert(speed, 100), 100);
      expect(u.label(speed), 'km/h');
      expect(u.label(coolant), '°C');
    });

    test('non-dimensional PIDs are never converted', () {
      const u = Units(UnitSystem.us);
      expect(u.convert(rpm, 1325), 1325);
      expect(u.label(rpm), 'rpm');
    });

    test('string round trip, default US', () {
      expect(unitSystemFromString(null), UnitSystem.us);
      expect(unitSystemFromString('metric'), UnitSystem.metric);
      expect(unitSystemToString(UnitSystem.metric), 'metric');
    });
  });
}

// ---------------------------------------------------------------------------
// Make-agnostic labelling: SAE DTC text, known addresses, airbag recognition
// ---------------------------------------------------------------------------
void _makeAgnosticTests() {
  group('SAE DTC dictionary', () {
    test('generic codes resolve', () {
      expect(dtcDescription('P0301'), 'Cylinder 1 Misfire Detected');
      expect(dtcDescription('U0100'), startsWith('Lost Communication With ECM/PCM'));
      expect(dtcDescription('p0420'), isNotNull);
    });
    test('manufacturer codes do not', () {
      expect(dtcDescription('P1000'), isNull);
      expect(dtcDescription('B0001'), isNull);
    });
    test('Dtc.description uses the 5-char base', () {
      final d = Dtc(Uint8List.fromList([0x03, 0x01, 0x04]), 0x2F); // P0301-04
      expect(d.sae, 'P0301-04');
      expect(d.saeBase, 'P0301');
      expect(d.description, 'Cylinder 1 Misfire Detected');
    });
  });

  group('known module addresses', () {
    test('Ford RCM at 0x737 is airbag, BCM at 0x726 is not', () {
      expect(knownModule11(0x737)!.airbag, isTrue);
      expect(knownModule11(0x726)!.airbag, isFalse);
      expect(knownModule11(0x7D0)!.abbr, 'APIM');
      expect(knownModule11(0x7A0), isNull);
    });
    test('module with no identification falls back to the address label', () {
      final m = Module(bits: 11, reqId: 0x726, respId: 0x72E);
      expect(m.displayName, startsWith('BCM'));
      expect(m.displayHint, contains('Ford'));
      expect(m.isAirbag, isFalse);
    });
    test('unidentified module at a known airbag address is flagged by address', () {
      final m = Module(bits: 11, reqId: 0x737, respId: 0x73F);
      expect(m.isAirbag, isTrue);
      expect(m.airbagByAddressOnly, isTrue);
    });
    test('identified non-airbag module at 0x737 is NOT flagged', () {
      final m = Module(
          bits: 11, reqId: 0x737, respId: 0x73F, info: {'system name': 'GATEWAY'});
      expect(m.isAirbag, isFalse);
    });
    test('29-bit modules get no address hint', () {
      expect(Module(bits: 29, reqId: 0x18DA37F1, respId: 0x18DAF137).known, isNull);
    });
  });

  group('airbag recognition across makes', () {
    test('Ford part number base 14B321', () {
      expect(looksLikeAirbag({'core part number': 'FL3T-14B321-AB'}, []), isTrue);
    });
    test('abbreviations are whole-word', () {
      expect(looksLikeAirbag({'system name': 'RCM'}, []), isTrue);
      expect(looksLikeAirbag({'system name': 'SDM'}, []), isTrue);
      expect(looksLikeAirbag({'system name': 'ORC'}, []), isTrue);
      expect(looksLikeAirbag({'system name': 'ACM audio'}, []), isFalse);
      expect(looksLikeAirbag({'system name': 'FORCMODULE'}, []), isFalse);
    });
  });
}

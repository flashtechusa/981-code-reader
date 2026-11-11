import 'dart:typed_data';

import 'package:boxster_srs/core/clear.dart';
import 'package:boxster_srs/core/dtc_text.dart';
import 'package:boxster_srs/core/ford_dtc_table.dart';
import 'package:boxster_srs/core/verified_generic_dtc.dart';
import 'package:boxster_srs/core/elm327.dart';
import 'package:boxster_srs/core/mock_adapter.dart';
import 'package:boxster_srs/core/module.dart';
import 'package:boxster_srs/core/obd_pids.dart';
import 'package:boxster_srs/core/scanner.dart';
import 'package:boxster_srs/core/transport.dart';
import 'package:boxster_srs/core/uds.dart';
import 'package:boxster_srs/core/vin.dart';
import 'package:boxster_srs/core/units.dart';
import 'package:boxster_srs/core/known_modules.dart';
import 'package:boxster_srs/core/legacy_obd.dart';
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
  _unitsTests();
  _makeAgnosticTests();
  _legacyTests();
  _fordCodeTextTests();
  _vinFirstScanTests();

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
      // ATSH715 is already set: only the receive filter changes.
      expect(t.sent, equals(['ATCF700', 'ATCM700']));
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
      // ATCP18 and ATSHDA15F1 are already set: only the filter changes.
      expect(t.sent, equals(['ATCF18DAF100', 'ATCM1FFFFF00']));
    });

    test('unchanged addressing is not re-sent while sweeping', () async {
      final t = MockTransport((_) => 'OK\r>', latency: Duration.zero);
      final elm = Elm327(t);
      await elm.open();
      await elm.setBits(11);
      t.sent.clear();
      await elm.setTarget(0x726, wideFilter: true);
      expect(t.sent, equals(['ATSH726', 'ATCF700', 'ATCM700']));
      t.sent.clear();
      await elm.setTarget(0x727, wideFilter: true);
      expect(t.sent, equals(['ATSH727']), reason: 'filter unchanged');
      t.sent.clear();
      await elm.setTarget(0x727, wideFilter: true);
      expect(t.sent, isEmpty, reason: 'nothing changed');
      // A protocol change forgets everything: all of it is sent again.
      await elm.setBits(11);
      t.sent.clear();
      await elm.setTarget(0x727, wideFilter: true);
      expect(t.sent, equals(['ATSH727', 'ATCF700', 'ATCM700']));
      // 29-bit sweep: only the header changes per target.
      await elm.setBits(29);
      t.sent.clear();
      await elm.setTarget(0x18DA40F1, wideFilter: true);
      await elm.setTarget(0x18DA41F1, wideFilter: true);
      expect(t.sent, equals(['ATCP18', 'ATSHDA40F1', 'ATCF18DAF100',
          'ATCM1FFFFF00', 'ATSHDA41F1']));
    });

    test('a command the adapter did not OK is sent again next time', () async {
      var first = true;
      final t = MockTransport((c) {
        if (c == 'ATSH726' && first) {
          first = false;
          return 'NO DATA\r>'; // late answer of the previous probe
        }
        return 'OK\r>';
      }, latency: Duration.zero);
      final elm = Elm327(t);
      await elm.open();
      await elm.setBits(11);
      await elm.setTarget(0x726, wideFilter: true);
      t.sent.clear();
      await elm.setTarget(0x726, wideFilter: true);
      expect(t.sent, equals(['ATSH726']));
    });

    test('exact filter after wide (and back) is always re-sent', () async {
      final t = MockTransport((_) => 'OK\r>', latency: Duration.zero);
      final elm = Elm327(t);
      await elm.open();
      await elm.setBits(11);
      await elm.setTarget(0x726, wideFilter: true);
      t.sent.clear();
      await elm.setTarget(0x726, resp: 0x72E);
      expect(t.sent, equals(['ATCRA72E']));
      t.sent.clear();
      await elm.setTarget(0x726, wideFilter: true);
      expect(t.sent, equals(['ATCF700', 'ATCM700']));
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
    test('known non-airbag address is never flagged by active B-codes', () {
      // Ford APIM (SYNC) at 0x7D0 throwing an active B-code: NOT airbag.
      final m = Module(
          bits: 11,
          reqId: 0x7D0,
          respId: 0x7D8,
          dtcs: [Dtc(Uint8List.fromList([0x92, 0x15, 0x00]), 0x2B)]);
      expect(m.isAirbag, isFalse);
      // ... but identification text still wins over the address table.
      final m2 = Module(
          bits: 11, reqId: 0x7D0, respId: 0x7D8, info: {'system name': 'AIRBAG'});
      expect(m2.isAirbag, isTrue);
    });
    test('unknown address with active B-code keeps the Porsche fallback', () {
      final m = Module(
          bits: 11,
          reqId: 0x7A5,
          respId: 0x7AD,
          dtcs: [Dtc(Uint8List.fromList([0x80, 0x01, 0x04]), 0x2F)]);
      expect(m.isAirbag, isTrue);
    });
    test('active vs inactive DTCs', () {
      final m = Module(bits: 11, reqId: 0x726, respId: 0x72E, dtcs: [
        Dtc(Uint8List.fromList([0xD0, 0x18, 0x00]), 0x50), // not completed
        Dtc(Uint8List.fromList([0x92, 0x15, 0x00]), 0x2B), // failed
        Dtc(Uint8List.fromList([0x01, 0x71, 0x00]), 0x04), // pending
      ]);
      expect(m.activeDtcs.length, 2);
      expect(m.inactiveCount, 1);
    });
    test('identified non-airbag module at 0x737 is NOT flagged', () {
      final m = Module(
          bits: 11, reqId: 0x737, respId: 0x73F, info: {'system name': 'GATEWAY'});
      expect(m.isAirbag, isFalse);
    });
    test('MS-CAN module labels and address suffix', () {
      final m = Module(bits: 11, reqId: 0x733, respId: 0x73B, bus: CanBus.ms);
      expect(m.address, '733 MS');
      expect(m.displayName, startsWith('HVAC'));
      expect(m.copyWith(dtcs: []).bus, CanBus.ms);
    });
    test('MS-CAN selects ELM protocol B at 125 kbps', () async {
      final (elm, _, t) = await connectFake();
      elm.bus = CanBus.ms;
      await elm.setBits(29); // MS is 11-bit only
      expect(elm.bits, 11);
      expect(t.sent.map((x) => x.trim()).toList(),
          containsAllInOrder(['ATPB E0 04', 'ATSPB']));
      elm.bus = CanBus.hs;
      await elm.setBits(11);
      expect(t.sent.last.trim(), 'ATSP6');
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

// ---------------------------------------------------------------------------
// Legacy OBD-II (K-line) mode
// ---------------------------------------------------------------------------
void _legacyTests() {
  group('legacy OBD-II parsing', () {
    test('formatted lines, noise and CAN frame indices are handled', () {
      final lines = Elm327.parseLegacyLines(
          'SEARCHING...\n41 0C 11 DE\n0: 49 02 01 57 50 30\nNO DATA\n>');
      expect(lines.length, 2);
      expect(lines[0], Uint8List.fromList([0x41, 0x0C, 0x11, 0xDE]));
      expect(lines[1][0], 0x49);
    });
    test('K-line Mode 03 has no count byte', () {
      final d = LegacyObd.decodeDtcLine(
          Uint8List.fromList([0x43, 0x03, 0x01, 0x01, 0x71, 0x00, 0x00]),
          sidObdReadStored,
          false);
      expect(d.map((x) => x.sae).toList(), ['P0301-00', 'P0171-00']);
      expect(d.first.description, 'Cylinder 1 Misfire Detected');
      expect(d.first.testFailed, isTrue);
    });
    test('CAN Mode 03 carries a count byte; Mode 07 is pending', () {
      final d = LegacyObd.decodeDtcLine(
          Uint8List.fromList([0x47, 0x01, 0x04, 0x20]), sidObdReadPending, true);
      expect(d.single.sae, 'P0420-00');
      expect(d.single.testFailed, isFalse);
      expect(d.single.status, 0x04);
    });
    test('wrong-mode line is ignored', () {
      expect(
          LegacyObd.decodeDtcLine(
              Uint8List.fromList([0x41, 0x00]), sidObdReadStored, false),
          isEmpty);
    });
    test('legacyIsCan from ATDPN', () {
      final e = Elm327(MockTransport((_) => '>'));
      e.legacyProtocol = 'A5';
      expect(e.legacyIsCan, isFalse);
      e.legacyProtocol = 'A6';
      expect(e.legacyIsCan, isTrue);
      e.legacyProtocol = '3';
      expect(e.legacyIsCan, isFalse);
    });
  });

  group('legacy allow-list', () {
    test('UDS services are refused in legacy mode; Mode 04 needs the flag',
        () async {
      final (elm, uds, t) = await connectFake();
      elm.legacy = true;
      final before = t.sent.length;
      await expectLater(uds.request([sidReadDtc, 0x02, 0xFF]), throwsA(isA<UdsException>()));
      await expectLater(uds.request([sidClearDtc, 0xFF, 0xFF, 0xFF]), throwsA(isA<UdsException>()));
      await expectLater(uds.request([0x27, 0x01]), throwsA(isA<UdsException>()));
      await expectLater(uds.request([sidObdClear]), throwsA(isA<UdsException>()));
      expect(t.sent.length, before, reason: 'nothing may reach the wire');
      elm.legacy = false;
    });
    test('legacy modes are refused when NOT in legacy mode', () async {
      final (_, uds, t) = await connectFake();
      final before = t.sent.length;
      await expectLater(uds.request([sidObdReadStored]), throwsA(isA<UdsException>()));
      await expectLater(uds.request([sidObdClear], allowObdClear: true), throwsA(isA<UdsException>()));
      expect(t.sent.length, before);
    });
  });
}

// ---------------------------------------------------------------------------
// Tony's Ford code list: decoding, precedence over SAE, per-vehicle gating
// ---------------------------------------------------------------------------
void _fordCodeTextTests() {
  const f150 = '1FTEW1EG5FFA12345';
  const boxster = 'WP0CA2A85EK100000';
  const maserati = 'ZAMBC38A040012345';
  const mazda = 'JM1BL1V75C1234567';

  group('Ford DTC table (generated)', () {
    test('keys are 5-char SAE codes, no placeholders', () {
      final key = RegExp(r'^[PCBU][0-3][0-9A-F]{3}$');
      expect(fordDtcText.length, greaterThan(15000));
      for (final e in fordDtcText.entries) {
        expect(key.hasMatch(e.key), isTrue, reason: e.key);
        expect(e.value, isNotEmpty, reason: e.key);
        for (final t in e.value) {
          expect(t.toLowerCase(), isNot(contains('refer to the workshop manual')));
          expect(t, isNot(contains(r'\x9')));
        }
      }
    });
    test('2-byte and 4-byte source keys decode to the right code', () {
      expect(fordDtcText['B1B7E'], ['Left Rear Temperature Control']); // 0x9B7E0000
      expect(fordDtcText['U0013'], ['Medium Speed CAN Communication Bus (+) Low']);
      expect(fordDtcText['U0151']!.first,
          'Lost Communication With Restraints Control Module');
      expect(fordDtcText['B0001'], contains('Driver Frontal Stage 1 Deployment Control'));
    });
  });

  group('describeDtcCode precedence', () {
    test('SAE generic text wins and is not mixed with Ford meanings', () {
      final t = describeDtcCode('P0420', ford: FordTextLevel.confirmed);
      expect(t.source, DtcTextSource.sae);
      expect(t.meanings, [dtcDescription('P0420')]);
      expect(t.label, isNull);
    });
    test('B0001: no silent pick of the Ford "ECU internal fault" entry', () {
      // B0001 is an SAE generic-range code. Tony's list has two meanings;
      // without a verified generic entry the most frequent one must not be
      // presented as THE meaning. Pass an empty verified table so this checks
      // the Ford-list fallback, whatever the shipped table contains.
      final t = describeDtcCode('B0001',
          ford: FordTextLevel.confirmed, verified: const {});
      expect(isManufacturerRange('B0001'), isFalse);
      expect(t.source, DtcTextSource.ford);
      expect(t.definitive, isFalse);
      expect(t.headline, isNull);
      expect(t.summary, isNot('ECU internal fault'));
      expect(t.summary, startsWith('2 possible meanings'));
      expect(t.meanings, containsAll(
          ['ECU internal fault', 'Driver Frontal Stage 1 Deployment Control']));
    });
    test('B0001: a verified generic entry wins over the Ford list', () {
      final t = describeDtcCode('B0001',
          ford: FordTextLevel.confirmed,
          verified: const {'B0001': 'Driver Frontal Stage 1 Deployment Control'});
      expect(t.source, DtcTextSource.verifiedGeneric);
      expect(t.headline, 'Driver Frontal Stage 1 Deployment Control');
      expect(t.meanings, hasLength(1)); // Ford meanings not mixed in
    });
    test('B0001: the shipped app shows the verified generic text', () {
      expect(verifiedGenericDtcText['B0001'],
          'Driver Frontal Stage 1 Deployment Control');
      final t = describeDtcCode('B0001', ford: FordTextLevel.confirmed);
      expect(t.source, DtcTextSource.verifiedGeneric);
      expect(t.headline, 'Driver Frontal Stage 1 Deployment Control');
      expect(t.summary, isNot('ECU internal fault'));
    });
    test('verified entry replaces a stale SAE "Reserved" entry', () {
      expect(dtcDescription('U0074'), startsWith('Reserved'));
      final t = describeDtcCode('U0074',
          verified: const {'U0074': 'Control Module Communication Bus B Off'});
      expect(t.headline, 'Control Module Communication Bus B Off');
    });
    test('verified table: generic-range codes with real text only', () {
      final key = RegExp(r'^[PCBU][0-3][0-9A-F]{3}$');
      for (final e in verifiedGenericDtcText.entries) {
        expect(key.hasMatch(e.key), isTrue, reason: e.key);
        expect(isManufacturerRange(e.key), isFalse, reason: e.key);
        expect(e.value.toLowerCase(), isNot(contains('reserved')), reason: e.key);
        expect(e.value.trim().length, greaterThan(8), reason: e.key);
      }
      // Until U0074 is verified, the app keeps showing its current text.
      if (!verifiedGenericDtcText.containsKey('U0074')) {
        expect(describeDtcCode('U0074').headline, startsWith('Reserved'));
      }
    });
    test('manufacturer-range code on a confirmed Ford is definitive', () {
      final t = describeDtcCode('b1b7e', ford: FordTextLevel.confirmed);
      expect(isManufacturerRange('B1B7E'), isTrue);
      expect(t.source, DtcTextSource.ford);
      expect(t.headline, 'Left Rear Temperature Control');
      expect(t.label, 'Ford list');
    });
    test('generic-range code with one Ford meaning: shown, marked unverified', () {
      final t = describeDtcCode('C0035', ford: FordTextLevel.confirmed);
      expect(isManufacturerRange('C0035'), isFalse);
      expect(fordDtcText['C0035'], hasLength(1));
      expect(t.headline, 'Right Front Wheel Speed Sensor Supply');
      expect(t.label, contains('not verified'));
    });
    test('Ford list off -> nothing for manufacturer codes', () {
      expect(describeDtcCode('B1B7E').isKnown, isFalse);
      expect(describeDtcCode('B1B7E').summary, 'Manufacturer-specific code');
    });
    test('unknown everywhere -> none', () {
      final t = describeDtcCode('C3FFF', ford: FordTextLevel.confirmed);
      expect(t.isKnown, isFalse);
      expect(t.headline, isNull);
    });
    test('manufacturer ranges per SAE J2012', () {
      for (final c in ['P1000', 'P3000', 'P3399', 'B1000', 'B2FFF', 'C1234',
          'C2000', 'U1000', 'U2FFF']) {
        expect(isManufacturerRange(c), isTrue, reason: c);
      }
      for (final c in ['P0001', 'P2000', 'P3400', 'B0001', 'B3000', 'C0035',
          'C3000', 'U0100', 'U3000']) {
        expect(isManufacturerRange(c), isFalse, reason: c);
      }
    });
  });

  group('Mazda is not a confirmed Ford match', () {
    test('Mazda VIN: Ford text only as unconfirmed, never a headline', () {
      expect(fordTextLevel(MakeCodeText.auto, vins: [mazda]),
          FordTextLevel.unconfirmed);
      final t = describeDtcCode('B1B7E', ford: FordTextLevel.unconfirmed);
      expect(t.makeConfirmed, isFalse);
      expect(t.headline, isNull);
      expect(t.summary, contains('not confirmed'));
      expect(t.label, contains('NOT confirmed'));
      expect(t.meanings, ['Left Rear Temperature Control']); // still viewable
    });
    test('forcing "Ford" does not confirm a Mazda VIN', () {
      expect(fordTextLevel(MakeCodeText.ford, vins: [mazda]),
          FordTextLevel.unconfirmed);
    });
    test('Mazda and Ford VIN sets are disjoint', () {
      expect(fordWmis.intersection(mazdaWmis), isEmpty);
      expect(isFordVin(mazda), isFalse);
      expect(isMazdaVin(mazda), isTrue);
    });
  });

  group('fordTextLevel', () {
    test('auto: Ford VIN confirmed, Porsche / Maserati VIN off', () {
      expect(fordTextLevel(MakeCodeText.auto, vins: [f150]),
          FordTextLevel.confirmed);
      expect(fordTextLevel(MakeCodeText.auto, vins: [boxster]),
          FordTextLevel.off);
      expect(fordTextLevel(MakeCodeText.auto, vins: [maserati]),
          FordTextLevel.off);
    });
    test('auto: a real non-Ford VIN beats the MS-CAN hint', () {
      expect(
          fordTextLevel(MakeCodeText.auto,
              vins: [boxster], hasMsCanModules: true),
          FordTextLevel.off);
    });
    test('auto: no usable VIN -> MS-CAN only gives unconfirmed', () {
      expect(fordTextLevel(MakeCodeText.auto), FordTextLevel.off);
      expect(fordTextLevel(MakeCodeText.auto, vins: ['0A1B2C']),
          FordTextLevel.off);
      expect(fordTextLevel(MakeCodeText.auto, hasMsCanModules: true),
          FordTextLevel.unconfirmed);
    });
    test('manual override', () {
      expect(fordTextLevel(MakeCodeText.ford), FordTextLevel.confirmed);
      expect(fordTextLevel(MakeCodeText.ford, vins: [boxster]),
          FordTextLevel.unconfirmed);
      expect(fordTextLevel(MakeCodeText.off, vins: [f150]), FordTextLevel.off);
    });
    test('setting round-trips through its stored string', () {
      for (final m in MakeCodeText.values) {
        expect(makeCodeTextFromString(makeCodeTextToString(m)), m);
      }
      expect(makeCodeTextFromString(null), MakeCodeText.auto);
    });
  });
}

// ---------------------------------------------------------------------------
// VIN first, then a targeted scan on Ford / Lincoln / Mercury
// ---------------------------------------------------------------------------
void _vinFirstScanTests() {
  group('decodeVin', () {
    test('F-150, Boxster, Maserati, Mazda', () {
      final f = decodeVin('1FTEW1EG5FFA12345')!;
      expect(f.make, 'Ford');
      expect(f.modelYear, 2015);
      expect(f.isFordGroup, isTrue);
      expect(f.summary, '2015 Ford');
      final p = decodeVin('wp0ca2a85ek100000')!;
      expect(p.make, 'Porsche');
      expect(p.modelYear, 2014);
      expect(p.isFordGroup, isFalse);
      final m = decodeVin('ZAMBC38A040012345')!; // 7th char numeric
      expect(m.make, 'Maserati');
      expect(m.modelYear, 2004);
      final z = decodeVin('JM1BL1V75C1234567')!;
      expect(z.make, 'Mazda');
      expect(z.isFordGroup, isFalse, reason: 'Mazda gets the full scan');
      expect(decodeVin('5LMJJ2LT0KEL12345')!.make, 'Lincoln');
      expect(decodeVin('2MEFM74W9XX123456')!.make, 'Mercury');
    });
    test('rejects junk; unknown WMI still decodes the year', () {
      expect(decodeVin(null), isNull);
      expect(decodeVin('NO DATA'), isNull);
      expect(decodeVin('1FTEW1EG5FFA1234'), isNull); // 16 chars
      expect(decodeVin('1FTEW1EG5FFA1234O'), isNull); // O not allowed
      final u = decodeVin('XXXAA1A11F1234567')!;
      expect(u.make, isNull);
      expect(u.summary, '2015 unknown make (WMI XXX)');
    });
  });

  group('targeted Ford scan', () {
    // Scripted F-150: PCM answers 22 F190 with a multi-frame VIN, the BCM
    // at 0x726 answers TesterPresent, everything else is silent.
    (MockTransport, Elm327, Uds) truck() {
      var sh = '';
      final t = MockTransport((cmd) {
        final c = cmd.trim().toUpperCase();
        if (c.startsWith('ATSH')) {
          sh = c.substring(4);
          return 'OK\r>';
        }
        if (c.startsWith('AT')) return 'OK\r>';
        if (sh == '7E0' && c.startsWith('03 22 F1 90')) {
          return '7E8 10 14 62 F1 90 31 46 54\r'
              '7E8 21 45 57 31 45 47 35 46\r'
              '7E8 22 46 41 31 32 33 34 35\r>';
        }
        if (sh == '726' && c.startsWith('02 3E 00')) {
          return '72E 02 7E 00 00 00 00 00 00\r>';
        }
        return 'NO DATA\r>';
      }, latency: Duration.zero);
      final elm = Elm327(t);
      return (t, elm, Uds(elm));
    }

    test('VIN is read from 0x7E0 with 22 F190 (read-only)', () async {
      final (t, elm, uds) = truck();
      await elm.open();
      final vin = await Scanner(elm, uds).readVin();
      expect(vin, '1FTEW1EG5FFA12345');
      expect(t.sent, contains('03 22 F1 90 00 00 00 00'));
      expect(t.sent, contains('ATSH7E0'));
    });

    test('Ford address list: known Ford + OBD-II entries only', () {
      final hs = Scanner.fordAddresses(CanBus.hs);
      expect(hs, containsAll([0x726, 0x737, 0x760, 0x7D0, 0x7E0]));
      expect(hs, isNot(contains(0x715)), reason: 'VW airbag address');
      expect(Scanner.fordAddresses(CanBus.ms), contains(0x744));
    });

    test('probes only the given addresses, no 29-bit sweep', () async {
      final (t, elm, uds) = truck();
      await elm.open();
      final scanner = Scanner(elm, uds);
      final addresses = Scanner.fordAddresses(CanBus.hs);
      List<Module> found = const [];
      await for (final p in scanner.run(addresses: addresses)) {
        if (p.phase == 'done') found = p.found!;
      }
      expect(found.map((m) => m.address).toList(), ['726']);
      expect(t.sent.where((c) => c.startsWith('ATCP')), isEmpty,
          reason: 'no 29-bit addressing at all');
      expect(t.sent, isNot(contains('ATSH700')),
          reason: 'no full 11-bit sweep');
      expect(t.sent, isNot(contains('ATSH7E0')),
          reason: 'powertrain still behind the setting');
      final probed = t.sent
          .where((c) => c.startsWith('ATSH'))
          .map((c) => int.parse(c.substring(4), radix: 16))
          .toSet();
      expect(probed.every(addresses.contains), isTrue);
    });
  });
}

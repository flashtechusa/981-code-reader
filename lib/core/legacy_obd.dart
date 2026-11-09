import 'dart:typed_data';

import 'elm327.dart';
import 'module.dart';
import 'obd_pids.dart';
import 'uds.dart';

/// Legacy OBD-II (SAE J1979 over K-line / any auto-detected protocol) for
/// pre-2008 cars such as a 2004 Maserati 4200. Engine ECU only: generic
/// Modes 01 (live data), 03/07 (stored / pending DTCs), 04 (clear), 09 (VIN).
///
/// Everything still goes through [Uds.request], which applies the legacy
/// allow-list. Other modules on these cars (gearbox, ABS, airbag, body
/// computer) sit on separate K-lines with proprietary protocols and are
/// out of scope for this app.
class LegacyObd {
  LegacyObd(this.elm, this.uds);
  final Elm327 elm;
  final Uds uds;

  /// Switch the adapter to legacy mode and perform the bus init with a
  /// Mode 01 PID 00 request. The first request can take 10+ seconds while
  /// the ELM tries each protocol (5-baud K-line init is slow). Returns the
  /// protocol the adapter settled on.
  Future<String> connect() async {
    await elm.enterLegacy();
    final r = await uds.request([sidObdMode01, 0x00],
        timeout: const Duration(seconds: 25));
    if (r.isEmpty) {
      throw UdsException(
          'no OBD-II response. Ignition ON? Engine ECU awake? Adapter must '
          'support K-line (pins 7/15) for pre-2008 cars.');
    }
    return elm.readLegacyProtocol();
  }

  /// Mode 03 (stored) + Mode 07 (pending) decoded to [Dtc]s. Stored codes get
  /// status 0x09 (testFailed|confirmed), pending 0x04, so the existing UI,
  /// SAE text lookup and "still failed" logic work unchanged.
  Future<List<Dtc>> readDtcs() async {
    final out = <Dtc>[];
    final seen = <String>{};
    for (final mode in [sidObdReadStored, sidObdReadPending]) {
      final lines =
          await uds.request([mode], timeout: const Duration(seconds: 4));
      for (final line in lines.values) {
        for (final d in decodeDtcLine(line, mode, elm.legacyIsCan)) {
          final key = '${d.raw}-${d.status}';
          if (seen.add(key)) out.add(d);
        }
      }
    }
    return out;
  }

  /// `43 [count] AA BB AA BB ...` -> Dtc(AA BB 00, status).
  /// On K-line there is no count byte; on CAN there is.
  static List<Dtc> decodeDtcLine(Uint8List line, int mode, bool isCan) {
    final out = <Dtc>[];
    if (line.isEmpty || line[0] != mode + 0x40) return out;
    var i = 1;
    if (isCan && line.length >= 2) i = 2;
    final status = mode == sidObdReadPending ? 0x04 : 0x09;
    for (; i + 1 < line.length; i += 2) {
      final a = line[i], b = line[i + 1];
      if (a == 0 && b == 0) continue;
      out.add(Dtc(Uint8List.fromList([a, b, 0x00]), status));
    }
    return out;
  }

  /// Mode 04: clear emission-related DTCs and freeze frame on all ECUs that
  /// listen. Returns true on a positive 0x44 response.
  Future<bool> clear() async {
    final r = await uds.request([sidObdClear],
        timeout: const Duration(seconds: 6), allowObdClear: true);
    return r.values.any((l) => l.isNotEmpty && l[0] == 0x44);
  }

  /// One Mode 01 PID; null when unsupported / no answer.
  Future<double?> readPid(ObdPid pid) async {
    final r = await uds.single([sidObdMode01, pid.pid],
        timeout: const Duration(milliseconds: 1200));
    if (r.isEmpty || r[0] == 0x7F) return null;
    return decodeMode01(pid, r);
  }

  /// Mode 09 PID 02 VIN (best effort; null when the ECU does not provide it).
  Future<String?> vin() async {
    final lines = await uds.request([sidObdVehicleInfo, 0x02],
        timeout: const Duration(seconds: 4));
    final chars = <int>[];
    for (final l in lines.values) {
      if (l.length < 3 || l[0] != 0x49 || l[1] != 0x02) continue;
      // K-line: 49 02 <msgIndex> <4 data bytes>; CAN: 49 02 <count> <17 bytes>
      chars.addAll(l.sublist(3).where((c) => c >= 0x30 && c <= 0x5A));
    }
    if (chars.length < 17) return null;
    return String.fromCharCodes(chars.sublist(chars.length - 17));
  }

  /// Synthesised [Module] representing the engine ECU so the Vehicle /
  /// Errors screens can show it exactly like a CAN module.
  Module engineModule({String? protocol, String? vin, List<Dtc>? dtcs}) {
    final info = <String, String>{
      'system name': 'Engine ECU (OBD-II legacy)',
      if (protocol != null && protocol.isNotEmpty)
        'protocol': protocolName(protocol),
      if (vin != null) 'VIN': vin,
    };
    return Module(
      bits: 11,
      reqId: dmeRequest11,
      respId: dmeResponse11,
      info: info,
      dtcs: dtcs ?? <Dtc>[],
    );
  }

  static String protocolName(String dpn) {
    final c = dpn.isEmpty ? '' : dpn[dpn.length - 1].toUpperCase();
    const names = {
      '1': 'SAE J1850 PWM',
      '2': 'SAE J1850 VPW',
      '3': 'ISO 9141-2 (K-line)',
      '4': 'ISO 14230-4 KWP2000 5-baud (K-line)',
      '5': 'ISO 14230-4 KWP2000 fast init (K-line)',
      '6': 'ISO 15765-4 CAN 11-bit 500k',
      '7': 'ISO 15765-4 CAN 29-bit 500k',
      '8': 'ISO 15765-4 CAN 11-bit 250k',
      '9': 'ISO 15765-4 CAN 29-bit 250k',
    };
    return '${names[c] ?? 'protocol $dpn'} ($dpn)';
  }
}

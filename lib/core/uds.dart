import 'dart:typed_data';

import 'elm327.dart';
import 'dtc_table.dart';
import 'hex.dart';

// ---------------------------------------------------------------------------
// UDS constants (port of porsche981_srs.py)
// ---------------------------------------------------------------------------

const int sidSession = 0x10;
const int sidClearDtc = 0x14;
const int sidReadDtc = 0x19;
const int sidReadDid = 0x22;
const int sidTesterPresent = 0x3E;

/// OBD-II Mode 01 (SAE J1979 current data). Permitted ONLY towards the
/// legislated DME request id 0x7E0.
const int sidObdMode01 = 0x01;

/// The ONLY services this app is permitted to transmit.
const Set<int> allowedSids = {
  sidObdMode01,
  sidSession,
  sidClearDtc,
  sidReadDtc,
  sidReadDid,
  sidTesterPresent,
};

/// DiagnosticSessionControl sub-functions permitted (never 0x02 programming).
const Set<int> allowedSessions = {0x01, 0x03};

const Map<int, String> nrcNames = {
  0x10: 'generalReject',
  0x11: 'serviceNotSupported',
  0x12: 'subFunctionNotSupported',
  0x13: 'incorrectMessageLengthOrInvalidFormat',
  0x14: 'responseTooLong',
  0x21: 'busyRepeatRequest',
  0x22: 'conditionsNotCorrect  (ignition on? engine off? speed 0? voltage ok?)',
  0x24: 'requestSequenceError',
  0x31: 'requestOutOfRange',
  0x33: 'securityAccessDenied  (this module wants SecurityAccess 0x27 - this tool will NOT do that)',
  0x35: 'invalidKey',
  0x36: 'exceedNumberOfAttempts',
  0x37: 'requiredTimeDelayNotExpired',
  0x72: 'generalProgrammingFailure',
  0x78: 'requestCorrectlyReceived-ResponsePending',
  0x7E: 'subFunctionNotSupportedInActiveSession',
  0x7F: 'serviceNotSupportedInActiveSession',
};

/// Data identifiers that are harmless to read and help label a module.
const Map<int, String> identDids = {
  // VW / Porsche style
  0xF187: 'spare part number',
  0xF191: 'ECU hardware number',
  0xF197: 'system name',
  0xF189: 'software version',
  0xF19E: 'ODX / ASAM file',
  // ISO 14229 standard + Ford style (Ford does not answer the F187/F197 set)
  0xF190: 'VIN',
  0xF111: 'core part number',
  0xF188: 'software part number',
  0xF18C: 'serial number',
};

/// 11-bit IDs we never clear on, and skip in the default scan.
const int functional11 = 0x7DF;
bool isPowertrain11(int id) => id >= 0x7E0 && id < 0x7E8;
bool isResponse11(int id) => id >= 0x7E8 && id < 0x7F0;

/// 29-bit normal-fixed: 0x18DA <target> <source>. Functional = 0x18DB33F1.
const int functional29 = 0x18DB33F1;
const Set<int> powertrain29Targets = {0x10, 0x18};

/// DME legislated request / response pair used for Mode 01 live data.
const int dmeRequest11 = 0x7E0;
const int dmeResponse11 = 0x7E8;

class UdsException implements Exception {
  UdsException(this.message, {this.nrc});
  final String message;
  final int? nrc;
  @override
  String toString() => message;
}

/// One stored DTC: 3-byte code + status byte.
class Dtc {
  const Dtc(this.bytes, this.status);
  final Uint8List bytes;
  final int status;

  /// "800104"
  String get raw => toHexCompact(bytes);

  /// "B0001-04"
  String get sae => dtcToSae(bytes);

  /// "testFailed,confirmed"
  String get statusNames => statusBits(status);

  bool get testFailed => (status & 0x01) != 0;
  bool get isBodyCode => (bytes[0] >> 6) == 2;

  /// "P0301" - the SAE code without the failure-type suffix.
  String get saeBase => sae.substring(0, 5);

  /// SAE J2012 generic text, or null for manufacturer-specific codes.
  String? get description => dtcDescription(saeBase);

  @override
  String toString() => '$raw ($sae) 0x${hexN(status, 2)} $statusNames';
}

/// B/C/P/U + 4 hex digits + '-' + failure type byte.
String dtcToSae(List<int> dtc) {
  final letter = 'PCBU'[dtc[0] >> 6];
  final d1 = (dtc[0] >> 4) & 0x3;
  final d2 = (dtc[0] & 0xF).toRadixString(16).toUpperCase();
  return '$letter$d1$d2${hexN(dtc[1], 2)}-${hexN(dtc[2], 2)}';
}

const List<String> dtcStatusNames = [
  'testFailed',
  'testFailedThisCycle',
  'pending',
  'confirmed',
  'notCompletedSinceClear',
  'failedSinceClear',
  'notCompletedThisCycle',
  'warningLamp',
];

String statusBits(int s) {
  final names = <String>[];
  for (var i = 0; i < dtcStatusNames.length; i++) {
    if (s & (1 << i) != 0) names.add(dtcStatusNames[i]);
  }
  return names.isEmpty ? '-' : names.join(',');
}

/// UDS layer with THE single transmit choke point.
class Uds {
  Uds(this.elm);
  final Elm327 elm;

  /// The single transmit path. Enforces:
  ///  - service ID allow-list
  ///  - Mode 01 only towards the DME request id 0x7E0 (11-bit)
  ///  - DiagnosticSessionControl only to default/extended
  ///  - 0x14 never to functional addresses, and never to powertrain
  ///    addresses unless [allowPowertrainClear] is set (per-module Clear
  ///    button only; the Clear SRS tile never sets it)
  /// Returns {canId: responseBytes}.
  Future<Map<int, Uint8List>> request(List<int> payload,
      {Duration timeout = const Duration(milliseconds: 1500),
      bool allowPowertrainClear = false}) async {
    if (payload.isEmpty) throw UdsException('empty request');
    final sid = payload[0];
    if (!allowedSids.contains(sid)) {
      throw UdsException(
          'refusing to send service 0x${hexN(sid, 2)} - not on the allow-list');
    }
    if (sid == sidObdMode01 &&
        !(elm.bits == 11 && elm.reqId == dmeRequest11)) {
      throw UdsException(
          'refusing to send OBD Mode 01 anywhere but the DME at 0x7E0');
    }
    if (sid == sidSession &&
        (payload.length < 2 || !allowedSessions.contains(payload[1] & 0x7F))) {
      throw UdsException(
          'refusing to send a non default/extended diagnostic session');
    }
    if (sid == sidClearDtc) {
      assertClearTargetOk(elm.bits, elm.reqId, allowPowertrainClear);
    }
    return elm.sendFramesAndCollect(payload, timeout: timeout);
  }

  static void assertClearTargetOk(int bits, int? reqId, bool allowPowertrain) {
    if (reqId == null) throw UdsException('no target address set');
    if (bits == 11) {
      if (reqId == functional11) {
        throw UdsException('refusing to clear via functional/broadcast ID 0x7DF');
      }
      if (isPowertrain11(reqId) && !allowPowertrain) {
        throw UdsException(
            'refusing to clear on powertrain ID 0x${hexN(reqId, 3)}');
      }
    } else {
      if (reqId == functional29) {
        throw UdsException('refusing to clear via functional 29-bit ID');
      }
      if (powertrain29Targets.contains((reqId >> 8) & 0xFF) && !allowPowertrain) {
        throw UdsException(
            'refusing to clear on powertrain 29-bit target 0x${hexN(reqId, 8)}');
      }
    }
  }

  // ---- helpers -----------------------------------------------------------

  /// Return payload after positive SID, or throw with decoded NRC.
  static Uint8List check(Uint8List resp, int sid) {
    if (resp.isEmpty) throw UdsException('no response');
    if (resp[0] == 0x7F) {
      final nrc = resp.length > 2 ? resp[2] : 0;
      final req = resp.length > 1 ? resp[1] : 0;
      throw UdsException(
          'negative response to 0x${hexN(req, 2)}: NRC 0x${hexN(nrc, 2)} '
          '${nrcNames[nrc] ?? 'unknown'}',
          nrc: nrc);
    }
    if (resp[0] != sid + 0x40) {
      throw UdsException('unexpected response ${toHex(resp)}');
    }
    return Uint8List.fromList(resp.sublist(1));
  }

  static bool isPending(Uint8List resp) =>
      resp.length >= 3 && resp[0] == 0x7F && resp[2] == 0x78;

  /// Request expecting exactly one responder (the configured target).
  Future<Uint8List> single(List<int> payload,
      {Duration timeout = const Duration(milliseconds: 1500),
      bool allowPowertrainClear = false}) async {
    final resps = await request(payload,
        timeout: timeout, allowPowertrainClear: allowPowertrainClear);
    if (resps.isEmpty) return Uint8List(0);
    final rid = elm.respId;
    if (rid != null && resps.containsKey(rid)) return resps[rid]!;
    if (resps.length == 1) return resps.values.first;
    throw UdsException(
        'multiple responders: ${resps.keys.map((k) => '0x${k.toRadixString(16).toUpperCase()}').join(', ')}');
  }

  /// TesterPresent with suppressPosRspMsgIndicationBit; errors swallowed.
  Future<void> testerPresent() async {
    try {
      await request([sidTesterPresent, 0x80],
          timeout: const Duration(milliseconds: 300));
    } on UdsException {
      // ignore
    }
  }

  Future<Uint8List> readDid(int did) async {
    final r = await single([sidReadDid, did >> 8, did & 0xFF]);
    if (r.isEmpty) return Uint8List(0);
    final body = check(r, sidReadDid);
    return Uint8List.fromList(body.length > 2 ? body.sublist(2) : <int>[]);
  }

  /// 19 02 <mask>: ReadDTCInformation / reportDTCByStatusMask.
  Future<List<Dtc>> readDtcs({int mask = 0xFF}) async {
    final r = await single([sidReadDtc, 0x02, mask],
        timeout: const Duration(seconds: 2));
    final body = check(r, sidReadDtc); // 02 <availMask> [dtc(3) status(1)]*
    if (body.length < 2 || body[0] != 0x02) {
      throw UdsException('unexpected ReadDTC body ${toHex(body)}');
    }
    return decodeDtcRecords(body.sublist(2));
  }

  /// Decodes [dtc(3) status(1)]* records.
  static List<Dtc> decodeDtcRecords(List<int> recs) {
    final out = <Dtc>[];
    for (var i = 0; i + 3 < recs.length; i += 4) {
      out.add(Dtc(Uint8List.fromList(recs.sublist(i, i + 3)), recs[i + 3]));
    }
    return out;
  }

  /// 19 04 <dtc> FF: reportDTCSnapshotRecordByDTCNumber (raw).
  Future<Uint8List> readDtcSnapshot(Dtc dtc) async {
    final r = await single([sidReadDtc, 0x04, ...dtc.bytes, 0xFF],
        timeout: const Duration(seconds: 2));
    if (r.isEmpty) return r;
    return check(r, sidReadDtc);
  }

  /// 19 06 <dtc> FF: reportDTCExtDataRecordByDTCNumber (raw).
  Future<Uint8List> readDtcExtendedData(Dtc dtc) async {
    final r = await single([sidReadDtc, 0x06, ...dtc.bytes, 0xFF],
        timeout: const Duration(seconds: 2));
    if (r.isEmpty) return r;
    return check(r, sidReadDtc);
  }

  /// Read the identification DIDs that answer. Read-only.
  Future<Map<String, String>> identify() async {
    final info = <String, String>{};
    for (final entry in identDids.entries) {
      try {
        final val = await readDid(entry.key);
        if (val.isNotEmpty) info[entry.value] = asciiOrHex(val).trim();
      } on UdsException {
        // module does not support this DID
      }
    }
    return info;
  }
}

final RegExp _porschePartRe = RegExp(r'9\d[0-9A-Z][\s.]?618[\s.]?\d{3}');

/// Ford restraints control modules carry the service base number 14B321
/// (e.g. "FL3T-14B321-AB").
final RegExp _fordRcmPartRe = RegExp(r'14B321');
final RegExp _abbrRe = RegExp(r'\b(RCM|SDM|ORC|ACU)\b');

/// Generic SAE J2012 description for a 5-character code such as "P0301".
/// Returns null for manufacturer-specific codes.
String? dtcDescription(String saeBase) => saeDtcText[saeBase.toUpperCase()];

/// Heuristic, identical to the Python `looks_like_airbag`.
bool looksLikeAirbag(Map<String, String> info, List<Dtc> dtcs) {
  final text = info.values.join(' ').toUpperCase();
  // Porsche/VW: AIRBAG, POSIP. Generic: SRS, RESTRAINT. Ford: RCM.
  // GM: SDM (Sensing & Diagnostic Module). Chrysler: ORC (Occupant Restraint
  // Controller). Whole-word match for the short ones so "ACM" (Ford audio) etc.
  // cannot match.
  for (final k in const ['AIRBAG', 'POSIP', 'SRS', 'RESTRAINT']) {
    if (text.contains(k)) return true;
  }
  if (_abbrRe.hasMatch(text)) return true;
  // Porsche airbag control units carry part numbers in the 9xx 618 xxx xx family.
  if (_porschePartRe.hasMatch(text)) return true;
  if (_fordRcmPartRe.hasMatch(text)) return true;
  // Body (B) codes freshly failed this cycle is the pattern an unplugged squib produces.
  return dtcs.any((d) => d.isBodyCode && d.testFailed);
}

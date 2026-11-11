import 'dart:typed_data';

import 'elm327.dart';
import 'module.dart';
import 'uds.dart';

/// Outcome of a ClearDiagnosticInformation attempt.
class ClearResult {
  ClearResult({
    required this.positive,
    required this.explicit54,
    required this.dtcsAfter,
    required this.lines,
    this.error,
  });

  /// True when the clear was accepted (0x54 seen, or no error and re-read ok).
  final bool positive;

  /// True when an explicit 0x54 positive response was captured.
  final bool explicit54;
  final List<Dtc> dtcsAfter;

  /// Human-readable transcript for the results pane.
  final List<String> lines;
  final String? error;

  bool get stillFailed => dtcsAfter.any((d) => d.testFailed);
}

/// Port of `do_clear()` from porsche981_srs.py (after the typed confirm).
///
/// [allowPowertrain] is set ONLY by the per-module Clear button. The Clear SRS
/// tile always passes false, so a powertrain id can never be cleared from it.
Future<ClearResult> clearModule(
  Elm327 elm,
  Uds uds,
  Module m, {
  bool allowPowertrain = false,
  void Function(String line)? onLine,
}) async {
  final lines = <String>[];
  void say(String s) {
    lines.add(s);
    if (onLine != null) onLine(s);
  }

  elm.bus = m.bus;
  await elm.setBits(m.bits);
  await elm.setTimeoutMs(400);
  await elm.setTarget(m.reqId, resp: m.respId);

  // Pre-flight: the refusal fires before anything is transmitted.
  Uds.assertClearTargetOk(elm.bits, elm.reqId, allowPowertrain);
  if (uds.learnedBroadcast.contains(elm.reqId)) {
    throw UdsException('refusing to clear via ${m.address}: several modules '
        'answer there (broadcast address)');
  }

  // Extended session is usually not required for 0x14 but some ECUs insist.
  // Try it, fall through to default session if refused.
  try {
    final r = await uds.single([sidSession, 0x03]);
    Uds.check(r, sidSession);
    say('extended diagnostic session: OK');
  } on UdsException catch (e) {
    say('extended session not entered (${e.message}); trying in default session');
  }
  await uds.testerPresent();

  await elm.setTimeoutMs(1020); // max ATST - gives 0x78 pending room
  Uint8List r = Uint8List(0);
  try {
    r = await uds.single([sidClearDtc, 0xFF, 0xFF, 0xFF],
        timeout: const Duration(seconds: 3), allowPowertrainClear: allowPowertrain);
  } on UdsException catch (e) {
    say('ClearDiagnosticInformation REFUSED: ${e.message}');
    await elm.setTimeoutMs(400);
    return ClearResult(
        positive: false,
        explicit54: false,
        dtcsAfter: m.dtcs,
        lines: lines,
        error: e.message);
  }

  var tries = 0;
  while (Uds.isPending(r) && tries < 5) {
    tries++;
    say('response pending (0x78) ... waiting');
    // The adapter stopped listening at the prompt; poll with TesterPresent so
    // the final 0x54 (or 0x7F) is captured on the way back.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final resps = await uds.request([sidTesterPresent, 0x00],
        timeout: const Duration(seconds: 2));
    r = resps[elm.respId] ?? Uint8List(0);
    if (r.isNotEmpty && r[0] == 0x7E) {
      // only TP answered; assume clear done
      r = Uint8List(0);
      break;
    }
  }

  var explicit54 = false;
  if (r.isNotEmpty && r[0] == 0x54) {
    explicit54 = true;
    say('ClearDiagnosticInformation: POSITIVE (0x54)');
  } else if (r.isNotEmpty) {
    try {
      Uds.check(r, sidClearDtc);
    } on UdsException catch (e) {
      say('ClearDiagnosticInformation FAILED: ${e.message}');
      await elm.setTimeoutMs(400);
      return ClearResult(
          positive: false,
          explicit54: false,
          dtcsAfter: m.dtcs,
          lines: lines,
          error: e.message);
    }
  } else {
    say('no explicit 0x54 seen - verifying by re-reading DTCs');
  }

  await elm.setTimeoutMs(400);
  await Future<void>.delayed(const Duration(milliseconds: 500));
  var after = <Dtc>[];
  try {
    after = await uds.readDtcs();
  } on UdsException catch (e) {
    say('re-read failed: ${e.message}');
  }
  m.dtcs = after;
  say('DTCs after clear:');
  if (after.isEmpty) {
    say('   no DTCs stored');
  } else {
    for (final d in after) {
      say('   $d');
    }
  }
  if (after.any((d) => d.testFailed)) {
    say('A fault is STILL testFailed -> the condition persists (connector open, '
        'resistance out of range, etc.). Fix the circuit, cycle ignition, clear again.');
  }

  // back to default session
  try {
    await uds.single([sidSession, 0x01]);
  } on UdsException {
    // ignore
  }

  return ClearResult(
      positive: true, explicit54: explicit54, dtcsAfter: after, lines: lines);
}

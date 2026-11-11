import 'dart:typed_data';

import 'dtc_text.dart';
import 'elm327.dart';
import 'hex.dart';
import 'known_modules.dart';
import 'module.dart';
import 'uds.dart';

/// Progress event emitted while scanning.
class ScanProgress {
  const ScanProgress({
    required this.phase,
    required this.message,
    required this.fraction,
    this.found,
  });

  /// 'probe11', 'probe29', 'identify', 'done'
  final String phase;
  final String message;

  /// 0.0 .. 1.0 overall progress.
  final double fraction;

  /// Emitted with the finished list on the 'done' event.
  final List<Module>? found;
}

/// Read-only discovery of every module on the diagnostic CAN.
/// Port of `do_scan()` from porsche981_srs.py.
class Scanner {
  Scanner(this.elm, this.uds);
  final Elm327 elm;
  final Uds uds;

  bool _cancel = false;
  void cancel() => _cancel = true;

  /// Response ids that answered one probe with one of [sids]. More than one
  /// means the probed id is a broadcast address on this car (0x700 on the
  /// 981 was answered by 11 modules): it is remembered in
  /// [Uds.learnedBroadcast] - so 0x14 is refused there - and never becomes a
  /// module of its own.
  static List<int> responders(Map<int, Uint8List> resps, Set<int> sids) => [
        for (final e in resps.entries)
          if (e.value.isNotEmpty && sids.contains(e.value[0])) e.key
      ];

  ScanProgress _broadcast(String id, int n, double fraction, String phase) =>
      ScanProgress(
        phase: phase,
        message: '$id is a broadcast address ($n modules answered) - not a '
            'module, skipped; each module is found at its own address',
        fraction: fraction,
      );

  /// Reads the VIN (UDS 22 F190, read-only, on the allow-list) from the
  /// engine computer at 0x7E0 on HS-CAN. Null when it does not answer with a
  /// plausible 17-character VIN. Used to plan the scan before probing.
  Future<String?> readVin() async {
    elm.bus = CanBus.hs;
    await elm.setBits(11);
    await elm.setTimeoutMs(400);
    await elm.setTarget(dmeRequest11, resp: dmeResponse11);
    try {
      final raw = await uds.readDid(0xF190);
      final vin = asciiOrHex(raw).trim().toUpperCase();
      return looksLikeVin(vin) ? vin : null;
    } on UdsException {
      return null;
    }
  }

  /// 11-bit addresses worth probing on a Ford / Lincoln / Mercury: the
  /// known-address table for that bus (lib/core/known_modules.dart).
  static List<int> fordAddresses(CanBus bus) => [
        ...(bus == CanBus.ms ? knownModulesMs : knownModules11)
            .entries
            .where((e) => e.value.make == 'Ford' || e.value.make == 'OBD-II')
            .map((e) => e.key),
      ]..sort();

  /// Runs the scan and emits progress. The final event has phase 'done' and
  /// carries the found modules (identified, with DTCs read).
  ///
  /// [addresses] null: full sweep (every 11-bit id, known-address second
  /// pass, then every 29-bit target on HS). Non-null: targeted scan - only
  /// those 11-bit ids, each given the second-pass treatment straight away,
  /// no 29-bit sweep (used when the VIN says the car is a Ford).
  Stream<ScanProgress> run(
      {bool includePowertrain = false,
      CanBus bus = CanBus.hs,
      List<int>? addresses}) async* {
    _cancel = false;
    final found = <Module>[];
    const probe = Duration(milliseconds: 400);
    final ms = bus == CanBus.ms;
    final targeted = addresses != null;
    String label(int rid) {
      final k = ms ? knownModulesMs[rid] : knownModules11[rid];
      return k == null ? '' : '  ${k.abbr} - ${k.name}';
    }

    // ---- 11-bit ---------------------------------------------------------
    elm.bus = bus;
    await elm.setBits(11);
    await elm.setTimeoutMs(100); // 60 in the Python; Ford modules need a little more
    final candidates11 = <int>[];
    for (final rid in addresses ??
        [for (var r = 0x700; r < 0x800; r++) r]) {
      if (rid < 0x700 || rid > 0x7FF) continue;
      if (broadcast11.contains(rid) || isResponse11(rid)) continue;
      if (isPowertrain11(rid) && !includePowertrain) continue;
      candidates11.add(rid);
    }
    final planned = candidates11.length + (targeted || ms ? 0 : 256);
    final total = planned == 0 ? 1 : planned;
    var step = 0;
    for (final rid in candidates11) {
      if (_cancel) break;
      await elm.setTarget(rid, wideFilter: true);
      final resps = await uds.request([sidTesterPresent, 0x00], timeout: probe);
      final who = responders(resps, const {0x7E, 0x7F});
      if (who.length > 1) {
        uds.learnedBroadcast.add(rid);
        yield _broadcast(
            '0x${hexN(rid, 3)}', who.length, 0.8 * step / total, 'probe11');
      } else if (who.length == 1) {
        found.add(Module(bits: 11, reqId: rid, respId: who.single, bus: bus));
        yield ScanProgress(
          phase: 'probe11',
          message:
              '0x${hexN(rid, 3)} -> 0x${hexN(who.single, 3)} answered${label(rid)}',
          fraction: 0.8 * step / total,
        );
      }
      step++;
      if (step % 4 == 0) {
        yield ScanProgress(
          phase: 'probe11',
          message: 'probing 0x${hexN(rid, 3)}',
          fraction: 0.8 * step / total,
        );
      }
    }

    // ---- second chance for well-known addresses ---------------------------
    // Some modules (Ford ABS / RCM / IPC / PSCM in particular) stay quiet on a
    // bare TesterPresent until they have seen a session request. Re-probe
    // only the known-address table with DiagnosticSessionControl default
    // (10 01 - read-only, on the allow-list), then TesterPresent again.
    if (!_cancel) {
      await elm.setTimeoutMs(250);
      final have = found.map((m) => m.reqId).toSet();
      for (final rid
          in targeted ? candidates11 : (ms ? knownModulesMs : knownModules11).keys) {
        if (_cancel) break;
        if (have.contains(rid) ||
            broadcast11.contains(rid) ||
            uds.learnedBroadcast.contains(rid)) {
          continue;
        }
        if (isPowertrain11(rid) && !includePowertrain) continue;
        await elm.setTarget(rid, wideFilter: true);
        var resps = await uds.request([sidSession, 0x01], timeout: probe);
        var who = responders(resps, const {0x50, 0x7F});
        if (who.isEmpty) {
          resps = await uds.request([sidTesterPresent, 0x00], timeout: probe);
          who = responders(resps, const {0x7E, 0x7F});
        }
        if (who.length > 1) {
          uds.learnedBroadcast.add(rid);
          yield _broadcast(
              '0x${hexN(rid, 3)}', who.length, 0.8 * step / total, 'probe11');
        } else if (who.length == 1) {
          found.add(Module(bits: 11, reqId: rid, respId: who.single, bus: bus));
          yield ScanProgress(
            phase: 'probe11',
            message:
                '0x${hexN(rid, 3)} -> 0x${hexN(who.single, 3)} answered (2nd pass)${label(rid)}',
            fraction: 0.8 * step / total,
          );
        }
      }
    }

    found.sort((a, b) => a.reqId.compareTo(b.reqId));

    // ---- 29-bit normal fixed (tester = 0xF1) - HS-CAN, full scan only ----
    if (!_cancel && !ms && !targeted) {
      await elm.setBits(29);
      await elm.setTimeoutMs(100); // 60 in the Python; Ford modules need a little more
      for (var ta = 0x00; ta < 0x100; ta++) {
        if (_cancel) break;
        step++;
        if (powertrain29Targets.contains(ta) && !includePowertrain) continue;
        final rid = 0x18DA0000 | (ta << 8) | 0xF1;
        await elm.setTarget(rid, wideFilter: true);
        final resps =
            await uds.request([sidTesterPresent, 0x00], timeout: probe);
        final who = responders(resps, const {0x7E, 0x7F});
        if (who.length > 1) {
          uds.learnedBroadcast.add(rid);
          yield _broadcast(
              '0x${hexN(rid, 8)}', who.length, 0.8 * step / total, 'probe29');
        } else if (who.length == 1) {
          found.add(Module(bits: 29, reqId: rid, respId: who.single));
          yield ScanProgress(
            phase: 'probe29',
            message: '0x${hexN(rid, 8)} -> 0x${hexN(who.single, 8)} answered',
            fraction: 0.8 * step / total,
          );
        }
        if (ta % 4 == 0) {
          yield ScanProgress(
            phase: 'probe29',
            message: 'probing 0x${hexN(rid, 8)}',
            fraction: 0.8 * step / total,
          );
        }
      }
    }

    // ---- label every responder (still read-only) ------------------------
    await elm.setTimeoutMs(400);
    for (var i = 0; i < found.length; i++) {
      if (_cancel) break;
      final m = found[i];
      yield ScanProgress(
        phase: 'identify',
        message: 'identifying ${m.address}',
        fraction: 0.8 + 0.2 * i / found.length,
      );
      await refreshModule(m);
      yield ScanProgress(
        phase: 'identified',
        message:
            '[${m.address}] ${m.displayName}${m.partNumber.isNotEmpty && m.systemName.isNotEmpty ? '  ${m.partNumber}' : ''}'
            '${m.isAirbag ? '  <== AIRBAG' : ''}  '
            '${m.note != null ? 'codes not read: ${m.note}' : m.activeDtcs.isEmpty ? 'no active faults' : '${m.activeDtcs.length} active fault(s)'}',
        fraction: 0.8 + 0.2 * (i + 1) / found.length,
      );
    }

    yield ScanProgress(
      phase: 'done',
      message: _cancel
          ? 'scan cancelled, ${found.length} module(s)'
          : '${found.length} module(s) found',
      fraction: 1.0,
      found: found,
    );
  }

  /// Re-reads identification + DTCs of one module (read-only).
  Future<void> refreshModule(Module m, {bool identify = true}) async {
    elm.bus = m.bus;
    await elm.setBits(m.bits);
    await elm.setTarget(m.reqId, resp: m.respId);
    try {
      if (identify) m.info = await uds.identify();
      m.dtcs = await uds.readDtcs();
      m.note = null;
    } on UdsException catch (e) {
      // Unknown, not empty: never leave old codes (or "no DTCs") standing
      // after a read that failed. The card shows "codes not read".
      m.dtcs = <Dtc>[];
      m.note = e.message;
    }
  }
}

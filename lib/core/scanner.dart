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

  /// Runs the scan and emits progress. The final event has phase 'done' and
  /// carries the found modules (identified, with DTCs read).
  Stream<ScanProgress> run({bool includePowertrain = false}) async* {
    _cancel = false;
    final found = <Module>[];
    const probe = Duration(milliseconds: 400);

    // ---- 11-bit ---------------------------------------------------------
    await elm.setBits(11);
    await elm.setTimeoutMs(100); // 60 in the Python; Ford modules need a little more
    final candidates11 = <int>[];
    for (var rid = 0x700; rid < 0x800; rid++) {
      if (rid == functional11 || isResponse11(rid)) continue;
      if (isPowertrain11(rid) && !includePowertrain) continue;
      candidates11.add(rid);
    }
    final total = candidates11.length + 256;
    var step = 0;
    for (final rid in candidates11) {
      if (_cancel) break;
      await elm.setTarget(rid, wideFilter: true);
      final resps = await uds.request([sidTesterPresent, 0x00], timeout: probe);
      for (final e in resps.entries) {
        if (e.value.isNotEmpty && (e.value[0] == 0x7E || e.value[0] == 0x7F)) {
          found.add(Module(bits: 11, reqId: rid, respId: e.key));
          yield ScanProgress(
            phase: 'probe11',
            message: '0x${hexN(rid, 3)} -> 0x${hexN(e.key, 3)} answered',
            fraction: 0.8 * step / total,
          );
        }
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
      for (final rid in knownModules11.keys) {
        if (_cancel) break;
        if (have.contains(rid) || rid == functional11) continue;
        if (isPowertrain11(rid) && !includePowertrain) continue;
        await elm.setTarget(rid, wideFilter: true);
        var resps = await uds.request([sidSession, 0x01], timeout: probe);
        var ok = resps.entries.where((e) =>
            e.value.isNotEmpty && (e.value[0] == 0x50 || e.value[0] == 0x7F));
        if (ok.isEmpty) {
          resps = await uds.request([sidTesterPresent, 0x00], timeout: probe);
          ok = resps.entries.where((e) =>
              e.value.isNotEmpty &&
              (e.value[0] == 0x7E || e.value[0] == 0x7F));
        }
        for (final e in ok) {
          found.add(Module(bits: 11, reqId: rid, respId: e.key));
          yield ScanProgress(
            phase: 'probe11',
            message:
                '0x${hexN(rid, 3)} -> 0x${hexN(e.key, 3)} answered (2nd pass)',
            fraction: 0.8 * step / total,
          );
          break;
        }
      }
    }

    found.sort((a, b) => a.reqId.compareTo(b.reqId));

    // ---- 29-bit normal fixed (tester = 0xF1) ----------------------------
    if (!_cancel) {
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
        for (final e in resps.entries) {
          if (e.value.isNotEmpty &&
              (e.value[0] == 0x7E || e.value[0] == 0x7F)) {
            found.add(Module(bits: 29, reqId: rid, respId: e.key));
            yield ScanProgress(
              phase: 'probe29',
              message: '0x${hexN(rid, 8)} -> 0x${hexN(e.key, 8)} answered',
              fraction: 0.8 * step / total,
            );
          }
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
    await elm.setBits(m.bits);
    await elm.setTarget(m.reqId, resp: m.respId);
    try {
      if (identify) m.info = await uds.identify();
      m.dtcs = await uds.readDtcs();
      m.note = null;
    } on UdsException catch (e) {
      m.note = e.message;
    }
  }
}

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/clear.dart';
import '../core/dtc_text.dart';
import '../core/elm327.dart';
import '../core/hex.dart';
import '../core/legacy_obd.dart';
import '../core/mock_adapter.dart';
import '../core/module.dart';
import '../core/obd_pids.dart';
import '../core/scanner.dart';
import '../core/transport.dart';
import '../core/uds.dart';
import '../core/vin.dart';
import 'settings.dart';

/// `--dart-define=MOCK=true` swaps the TCP socket for the scripted adapter.
const bool kMock = bool.fromEnvironment('MOCK', defaultValue: false);

enum ConnState { disconnected, connecting, connected }

/// One sample of live data.
class LiveSample {
  LiveSample(this.time, this.values);
  final DateTime time;
  final Map<int, double> values;
}

/// Application state: adapter connection, found modules, log, live data.
class Session extends ChangeNotifier {
  Session(this.settings);

  final Settings settings;

  ConnState state = ConnState.disconnected;
  String status = 'Not connected';
  bool statusIsError = false;
  bool busy = false;

  Elm327? _elm;
  Uds? _uds;
  Scanner? _scanner;
  LegacyObd? _legacy;

  /// True while connected to a pre-CAN car in legacy OBD-II mode.
  bool get legacyMode => _legacy != null;

  /// Which way the adapter's physical HS/MS switch is believed to be set.
  /// Updated only when the user confirms a flip in the UI.
  CanBus adapterBus = CanBus.hs;

  /// True when an HS scan has finished and MS-CAN has not been scanned yet.
  bool msScanOffered = false;

  void setAdapterBus(CanBus b) {
    adapterBus = b;
    notifyListeners();
  }

  /// A module on the other bus than the switch is set to cannot be reached.
  bool _busMismatch(Module m) {
    if (legacyMode || m.bus == adapterBus) return false;
    final want = m.bus == CanBus.ms ? 'MS-CAN' : 'HS-CAN';
    say('[${m.address}] is on ${m.bus == CanBus.ms ? 'MS' : 'HS'}-CAN - '
        'flip the adapter switch to $want first, then confirm in the app.');
    _setStatus('Flip switch to $want', error: true);
    return true;
  }
  String legacyProtocol = '';

  Elm327? get elm => _elm;
  Uds? get uds => _uds;

  final List<Module> modules = <Module>[];

  /// VIN-derived identity, read before the scan (null: not read / no answer).
  VehicleId? vehicle;

  /// Targeted (Ford known-address) scan instead of the full sweep?
  bool get _targetedScan =>
      !settings.fullScan && (vehicle?.isFordGroup ?? false);
  final List<LogEntry> log = <LogEntry>[];

  /// Lines shown in the monospace results pane of the home screen.
  final List<String> output = <String>[];

  /// Live data (Dashboard).
  final List<LiveSample> samples = <LiveSample>[];
  Map<int, double> latest = <int, double>{};
  Set<int> enabledPids = livePids.map((p) => p.pid).toSet();
  Timer? _liveTimer;
  bool liveRunning = false;
  bool _livePolling = false;

  bool get connected => state == ConnState.connected && _uds != null;

  List<Module> get airbagModules => modules.where((m) => m.isAirbag).toList();
  Module? get soleAirbagModule =>
      airbagModules.length == 1 ? airbagModules.first : null;

  /// How far Tony's Ford code list applies to the car on the bus: the
  /// Settings choice plus every VIN the modules reported (Ford / Lincoln /
  /// Mercury = confirmed; Mazda or MS-CAN-only = shown but NOT confirmed).
  FordTextLevel get fordLevel => fordTextLevel(settings.codeText,
      vins: [
        if (vehicle != null) vehicle!.vin,
        ...modules.map((m) => m.info['VIN']).whereType<String>(),
      ],
      hasMsCanModules: modules.any((m) => m.bus == CanBus.ms));

  /// Plain-English text for [d] on this vehicle.
  DtcText describe(Dtc d) => describeDtcCode(d.saeBase, ford: fordLevel);

  // ---- helpers -----------------------------------------------------------

  void _setStatus(String s, {bool error = false}) {
    status = s;
    statusIsError = error;
    notifyListeners();
  }

  void say(String line) {
    output.add(line);
    if (output.length > 2000) output.removeRange(0, 500);
    notifyListeners();
  }

  void clearOutput() {
    output.clear();
    notifyListeners();
  }

  Timer? _logNotify;

  void _onLog(LogEntry e) {
    log.add(e);
    if (log.length > 4000) log.removeRange(0, 1000);
    // Coalesce rebuilds: a scan produces many lines per second.
    _logNotify ??= Timer(const Duration(milliseconds: 150), () {
      _logNotify = null;
      notifyListeners();
    });
  }

  String get connectedLabel {
    final e = _elm;
    if (e == null) return 'Not connected';
    final v = e.batteryText.isEmpty ? '' : '   ${e.batteryText}';
    return '${e.adapterId.isEmpty ? 'adapter' : e.adapterId}$v';
  }

  // ---- connection --------------------------------------------------------

  Future<void> connect() async {
    if (state != ConnState.disconnected) return;
    state = ConnState.connecting;
    _setStatus('Connecting to ${settings.host}:${settings.port} ...');
    final Transport t = kMock
        ? MockAdapter().transport()
        : TcpTransport(settings.host, settings.port);
    final elm = Elm327(t, onLog: _onLog);
    try {
      await elm.open();
      await elm.init();
      _elm = elm;
      _uds = Uds(elm);
      _scanner = Scanner(elm, _uds!);
      state = ConnState.connected;
      say('Connected: ${elm.adapterId}  battery ${elm.batteryText}');
      if (settings.legacyBus) {
        _setStatus('Finding OBD-II protocol (K-line init, up to ~20 s) ...');
        final lg = LegacyObd(elm, _uds!);
        legacyProtocol = await lg.connect();
        _legacy = lg;
        say('Legacy OBD-II: ${LegacyObd.protocolName(legacyProtocol)}');
        say('Engine ECU only on this bus - gearbox / ABS / airbag need the '
            'factory tool on pre-CAN cars.');
      }
      if (elm.batteryLow) {
        say('WARNING: battery below 12.0 V. Low voltage is a classic cause of '
            'NRC 0x22 and of spurious airbag faults. Put a charger on it.');
      }
      _setStatus(connectedLabel);
      try {
        await WakelockPlus.enable();
      } catch (_) {}
    } catch (e) {
      await elm.close();
      _elm = null;
      _uds = null;
      _legacy = null;
      state = ConnState.disconnected;
      _setStatus('Not connected', error: true);
      say('Can\'t reach adapter: $e');
      say('Join Wi-Fi "WiFi_OBDII", tap Keep Trying Wi-Fi, switch on HS-CAN, ignition ON.');
    }
  }

  Future<void> disconnect() async {
    stopLive();
    _scanner?.cancel();
    final e = _elm;
    _elm = null;
    _uds = null;
    _scanner = null;
    _legacy = null;
    legacyProtocol = '';
    if (e != null) {
      try {
        await e.cmd('ATPC', timeout: const Duration(milliseconds: 800));
      } catch (_) {}
      await e.close();
    }
    modules.clear();
    vehicle = null;
    state = ConnState.disconnected;
    busy = false;
    try {
      await WakelockPlus.disable();
    } catch (_) {}
    say('Disconnected.');
    _setStatus('Not connected');
  }

  bool _guard() {
    if (!connected) {
      _setStatus('Tap CONNECT first', error: true);
      return false;
    }
    if (busy) {
      _setStatus('Still working ...', error: true);
      return false;
    }
    return true;
  }

  // ---- Vehicle (scan) ----------------------------------------------------

  Future<void> scan() async {
    if (!_guard()) return;
    if (legacyMode) return _legacyScan();
    busy = true;
    stopLive();
    clearOutput();
    try {
      _setStatus('reading VIN');
      say('Reading VIN from the engine computer (0x7E0, 22 F190) ...');
      final vin = await _scanner!.readVin();
      vehicle = decodeVin(vin);
      if (vehicle == null) {
        say('  no VIN answer - scanning every address.');
      } else {
        say('  VIN ${vehicle!.vin}  ->  ${vehicle!.summary}');
      }
      final addresses = _targetedScan
          ? Scanner.fordAddresses(CanBus.hs)
              .where((a) => settings.includePowertrain || !isPowertrain11(a))
              .toList()
          : null;
      if (addresses != null) {
        say('${vehicle!.make}: probing the ${addresses.length} known Ford '
            'module addresses only (Settings > Full address sweep to probe '
            'everything).');
      } else {
        say('Scanning diagnostic CAN, every address (read-only) ...');
      }
      final found = <Module>[];
      await for (final p in _scanner!.run(
          includePowertrain: settings.includePowertrain,
          addresses: addresses)) {
        if (p.phase == 'done') {
          found.addAll(p.found ?? const []);
        } else if (p.phase == 'identified') {
          say(p.message);
        } else if (p.message.contains('answered')) {
          say('  ${p.message}');
        }
        _setStatus(p.message);
      }
      modules
        ..clear()
        ..addAll(found);
      if (found.isEmpty) {
        say('Nothing answered. Ignition on? Switch on HS-CAN?');
      }
      msScanOffered = settings.hasMsSwitch && !legacyMode;
      _setStatus('${found.length} module(s) found on HS-CAN');
    } catch (e) {
      say('ERROR: $e');
      _setStatus('Error', error: true);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Second half of a Ford-style scan: the user has flipped the adapter to
  /// MS-CAN (pins 3/11, 125 kbps). Appends MS modules to the list; the
  /// switch must be flipped back before HS modules are touched again.
  Future<void> scanMs() async {
    if (!_guard()) return;
    busy = true;
    msScanOffered = false;
    adapterBus = CanBus.ms;
    stopLive();
    say('');
    final addresses = _targetedScan ? Scanner.fordAddresses(CanBus.ms) : null;
    say(addresses == null
        ? 'Scanning MS-CAN (125 kbps, read-only), every address ...'
        : 'Scanning MS-CAN (125 kbps, read-only), ${addresses.length} known '
            'Ford addresses ...');
    try {
      final found = <Module>[];
      await for (final p in _scanner!.run(
          includePowertrain: true, bus: CanBus.ms, addresses: addresses)) {
        if (p.phase == 'done') {
          found.addAll(p.found ?? const []);
        } else if (p.phase == 'identified') {
          say(p.message);
        } else if (p.message.contains('answered')) {
          say('  ${p.message}');
        }
        _setStatus(p.message);
      }
      modules.addAll(found);
      if (found.isEmpty) {
        say('Nothing answered on MS-CAN. Is the switch on MS? Not all cars '
            'have a second bus (the Porsche does not).');
      }
      _setStatus('${found.length} MS-CAN module(s); ${modules.length} total');
    } catch (e) {
      say('ERROR: $e');
      _setStatus('Error', error: true);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Legacy bus: there is no module scan - read the engine ECU's generic
  /// OBD-II data (VIN, stored + pending codes) and present it as one module.
  Future<void> _legacyScan() async {
    busy = true;
    stopLive();
    clearOutput();
    say('Legacy OBD-II (read-only): ${LegacyObd.protocolName(legacyProtocol)}');
    try {
      final lg = _legacy!;
      _setStatus('reading VIN');
      String? vin;
      try {
        vin = await lg.vin();
      } catch (_) {}
      _setStatus('reading stored + pending codes');
      final dtcs = await lg.readDtcs();
      final m = lg.engineModule(protocol: legacyProtocol, vin: vin, dtcs: dtcs);
      modules
        ..clear()
        ..add(m);
      say('');
      say('[${m.address}] ${m.displayName}');
      for (final e in m.info.entries) {
        say('   ${e.key}: ${e.value}');
      }
      _sayDtcs(dtcs);
      _setStatus('engine ECU read');
    } catch (e) {
      say('ERROR: $e');
      _setStatus('Error', error: true);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  void _sayDtcs(List<Dtc> dtcs) {
    if (dtcs.isEmpty) {
      say('   no DTCs stored');
      return;
    }
    for (final d in dtcs) {
      say('   $d');
    }
  }

  // ---- Errors (re-read DTCs) ---------------------------------------------

  Future<void> readAllDtcs() async {
    if (!_guard()) return;
    if (legacyMode) return _legacyScan();
    if (modules.isEmpty) {
      _setStatus('Run Vehicle first', error: true);
      return;
    }
    busy = true;
    stopLive();
    clearOutput();
    try {
      await _elm!.setTimeoutMs(400);
      var skipped = 0;
      for (final m in modules) {
        if (m.bus != adapterBus) {
          skipped++;
          continue;
        }
        _setStatus('reading ${m.address}');
        await _scanner!.refreshModule(m, identify: false);
        say('[${m.address}] ${m.displayName}${m.isAirbag ? '  (AIRBAG)' : ''}');
        if (m.note != null) {
          say('   ${m.note}');
          continue;
        }
        _sayDtcs(m.dtcs);
      }
      if (skipped > 0) {
        say('$skipped module(s) on the other CAN bus not re-read - flip the '
            'adapter switch and confirm to read those.');
      }
      _setStatus('DTC read complete');
    } catch (e) {
      say('ERROR: $e');
      _setStatus('Error', error: true);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// 19 04 + 19 06 raw dumps for one DTC of one module.
  Future<Map<String, String>> dtcDetail(Module m, Dtc d) async {
    final out = <String, String>{};
    if (!connected) return {'error': 'not connected'};
    if (legacyMode) {
      return {
        'note': 'Generic OBD-II has no per-code snapshot / extended data '
            '(UDS 19 04 / 19 06). Freeze frame (Mode 02) is not implemented.'
      };
    }
    if (_busMismatch(m)) return {'error': status};
    busy = true;
    notifyListeners();
    try {
      _elm!.bus = m.bus;
      await _elm!.setBits(m.bits);
      await _elm!.setTimeoutMs(400);
      await _elm!.setTarget(m.reqId, resp: m.respId);
      try {
        final s = await _uds!.readDtcSnapshot(d);
        out['19 04 snapshot'] = s.isEmpty ? '(no response)' : toHex(s);
      } on UdsException catch (e) {
        out['19 04 snapshot'] = e.message;
      }
      try {
        final x = await _uds!.readDtcExtendedData(d);
        out['19 06 extended data'] = x.isEmpty ? '(no response)' : toHex(x);
      } on UdsException catch (e) {
        out['19 06 extended data'] = e.message;
      }
    } catch (e) {
      out['error'] = '$e';
    } finally {
      busy = false;
      notifyListeners();
    }
    return out;
  }

  // ---- Clear -------------------------------------------------------------

  /// Clear SRS tile: airbag module only, never a powertrain id.
  Future<ClearResult?> clearSrs() async {
    final m = soleAirbagModule;
    if (m == null) {
      _setStatus('Exactly one airbag module must be flagged', error: true);
      return null;
    }
    return _clear(m, allowPowertrain: false);
  }

  /// Per-module Clear button. Powertrain ids are permitted ONLY here.
  Future<ClearResult?> clearModuleCodes(Module m) =>
      _clear(m, allowPowertrain: true);

  Future<ClearResult?> _clear(Module m, {required bool allowPowertrain}) async {
    if (!_guard()) return null;
    clearOutput();
    if (_busMismatch(m)) {
      notifyListeners();
      return null;
    }
    busy = true;
    stopLive();
    say('Clear codes on [${m.address}] ${m.displayName}');
    try {
      if (legacyMode) return await _legacyClear(m);
      final r = await clearModule(_elm!, _uds!, m,
          allowPowertrain: allowPowertrain, onLine: say);
      if (r.error != null) {
        _setStatus('Clear failed', error: true);
      } else if (r.stillFailed) {
        _setStatus('Cleared, but fault still present', error: true);
      } else {
        _setStatus(m.isAirbag ? 'SRS cleared' : 'Codes cleared');
      }
      return r;
    } on UdsException catch (e) {
      say('REFUSED: ${e.message}');
      _setStatus('Refused', error: true);
      return null;
    } catch (e) {
      say('ERROR: $e');
      _setStatus('Error', error: true);
      return null;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Legacy bus: Mode 04 clears emission DTCs + freeze frame on the engine
  /// ECU (and anything else listening on the K-line). Then re-read.
  Future<ClearResult?> _legacyClear(Module m) async {
    final lg = _legacy!;
    say('Mode 04 ClearDiagnosticInformation (generic OBD-II)');
    final ok = await lg.clear();
    say(ok ? 'Clear: POSITIVE (0x44)' : 'no 0x44 seen - verifying by re-read');
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final after = await lg.readDtcs();
    say('DTCs after clear:');
    _sayDtcs(after);
    final still = after.any((d) => d.testFailed);
    final idx = modules.indexOf(m);
    if (idx >= 0) modules[idx] = m.copyWith(dtcs: after);
    if (!ok && after.isNotEmpty) {
      _setStatus('Clear failed', error: true);
    } else if (still) {
      _setStatus('Cleared, but fault still present', error: true);
    } else {
      _setStatus('Codes cleared');
    }
    return ClearResult(
      positive: ok || after.isEmpty,
      explicit54: ok,
      dtcsAfter: after,
      lines: const [],
      error: ok || after.isEmpty ? null : 'no 0x44 response',
    );
  }

  // ---- Dashboard (Mode 01 live data) -------------------------------------

  ObdLive? _live;

  Future<void> startLive() async {
    if (!connected || liveRunning) return;
    if (busy) {
      _setStatus('Still working ...', error: true);
      return;
    }
    if (!legacyMode && adapterBus != CanBus.hs) {
      _setStatus('Flip switch to HS-CAN for live data', error: true);
      return;
    }
    busy = true;
    liveRunning = true;
    notifyListeners();
    try {
      _live = ObdLive(_elm!, _uds!);
      if (!legacyMode) await _live!.prepare(); // legacy: no CAN target to set
    } catch (e) {
      say('live data: $e');
      liveRunning = false;
      busy = false;
      notifyListeners();
      return;
    }
    _liveTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      _pollLive();
    });
    _setStatus('Live data running');
  }

  Future<void> _pollLive() async {
    final live = _live;
    if (_livePolling || !liveRunning || live == null) return;
    _livePolling = true;
    try {
      final values = <int, double>{};
      for (final p in livePids) {
        if (!liveRunning) break;
        if (!enabledPids.contains(p.pid)) continue;
        final v = await live.read(p);
        if (v != null) values[p.pid] = v;
      }
      if (!liveRunning) return;
      latest = {...latest, ...values};
      samples.add(LiveSample(DateTime.now(), Map<int, double>.from(latest)));
      if (samples.length > 600) samples.removeRange(0, 100);
      notifyListeners();
    } catch (e) {
      say('live data: $e');
      stopLive();
    } finally {
      _livePolling = false;
    }
  }

  void stopLive() {
    if (!liveRunning && _liveTimer == null) return;
    _liveTimer?.cancel();
    _liveTimer = null;
    liveRunning = false;
    _live = null;
    busy = false;
    if (connected) _setStatus(connectedLabel);
    notifyListeners();
  }

  void togglePid(int pid, bool on) {
    final s = Set<int>.from(enabledPids);
    if (on) {
      s.add(pid);
    } else {
      s.remove(pid);
    }
    enabledPids = s;
    notifyListeners();
  }

  void clearSamples() {
    samples.clear();
    latest = <int, double>{};
    notifyListeners();
  }

  /// Full transcript as text for sharing.
  String logText() {
    final b = StringBuffer();
    b.writeln('Boxster SRS log  ${DateTime.now().toIso8601String()}');
    b.writeln('adapter ${settings.host}:${settings.port}${kMock ? ' (MOCK)' : ''}');
    b.writeln();
    for (final e in log) {
      b.writeln(e.toString());
    }
    return b.toString();
  }

  @override
  void dispose() {
    _liveTimer?.cancel();
    _logNotify?.cancel();
    super.dispose();
  }
}

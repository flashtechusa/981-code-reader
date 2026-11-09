import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/clear.dart';
import '../core/elm327.dart';
import '../core/hex.dart';
import '../core/mock_adapter.dart';
import '../core/module.dart';
import '../core/obd_pids.dart';
import '../core/scanner.dart';
import '../core/transport.dart';
import '../core/uds.dart';
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

  Elm327? get elm => _elm;
  Uds? get uds => _uds;

  final List<Module> modules = <Module>[];
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
    if (e != null) {
      try {
        await e.cmd('ATPC', timeout: const Duration(milliseconds: 800));
      } catch (_) {}
      await e.close();
    }
    modules.clear();
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
    busy = true;
    stopLive();
    clearOutput();
    say('Scanning diagnostic CAN (read-only) ...');
    try {
      final found = <Module>[];
      await for (final p in _scanner!.run(
          includePowertrain: settings.includePowertrain)) {
        if (p.phase == 'done') {
          found.addAll(p.found ?? const []);
        } else if (p.message.contains('answered')) {
          say('  ${p.message}');
        }
        _setStatus(p.message);
      }
      modules
        ..clear()
        ..addAll(found);
      say('');
      for (final m in found) {
        say('[${m.address}]${m.isAirbag ? '  <== AIRBAG / POSIP' : ''}');
        for (final e in m.info.entries) {
          say('   ${e.key}: ${e.value}');
        }
        if (m.note != null) say('   note: ${m.note}');
        _sayDtcs(m.dtcs);
      }
      if (found.isEmpty) {
        say('Nothing answered. Ignition on? Switch on HS-CAN?');
      }
      _setStatus('${found.length} module(s) found');
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
    if (modules.isEmpty) {
      _setStatus('Run Vehicle first', error: true);
      return;
    }
    busy = true;
    stopLive();
    clearOutput();
    try {
      await _elm!.setTimeoutMs(400);
      for (final m in modules) {
        _setStatus('reading ${m.address}');
        await _scanner!.refreshModule(m, identify: false);
        say('[${m.address}] ${m.displayName}${m.isAirbag ? '  (AIRBAG)' : ''}');
        if (m.note != null) {
          say('   ${m.note}');
          continue;
        }
        _sayDtcs(m.dtcs);
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
    busy = true;
    notifyListeners();
    try {
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
    busy = true;
    stopLive();
    clearOutput();
    say('Clear codes on [${m.address}] ${m.displayName}');
    try {
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

  // ---- Dashboard (Mode 01 live data) -------------------------------------

  ObdLive? _live;

  Future<void> startLive() async {
    if (!connected || liveRunning) return;
    if (busy) {
      _setStatus('Still working ...', error: true);
      return;
    }
    busy = true;
    liveRunning = true;
    notifyListeners();
    try {
      _live = ObdLive(_elm!, _uds!);
      await _live!.prepare();
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

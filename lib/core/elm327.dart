import 'dart:async';
import 'dart:typed_data';

import 'hex.dart';
import 'module.dart' show CanBus;
import 'transport.dart';

class ElmException implements Exception {
  ElmException(this.message);
  final String message;
  @override
  String toString() => 'ElmException: $message';
}

/// One line of the raw transcript shown in the Log tile.
class LogEntry {
  LogEntry(this.time, this.direction, this.text);
  final DateTime time;

  /// '>>' for host->adapter, '<<' for adapter->host, '--' for notes.
  final String direction;
  final String text;

  @override
  String toString() {
    final t = time.toIso8601String().substring(11, 23);
    return '$t $direction $text';
  }
}

/// ELM327 command driver. Port of the Python `Elm327` class.
///
/// The adapter runs with `ATCAF0` (raw frames, PCI visible) and `ATCFC1`
/// (adapter still emits ISO-TP flow control). ISO-TP reassembly is done by
/// [parseFrames].
class Elm327 {
  Elm327(this.transport, {this.onLog});

  final Transport transport;

  /// Receives every exchange for the Log view.
  final void Function(LogEntry entry)? onLog;

  /// Current addressing width: 11 or 29.
  int bits = 11;

  /// Which CAN the adapter is configured for. HS = ISO 15765-4 500 kbps
  /// (ATSP6/7). MS = ELM "protocol B" user CAN: 11-bit, 125 kbps
  /// (`ATSPB` + `ATPB E0 04`: E0 = 11-bit id, fixed 8-byte DLC, ISO 15765
  /// formatting so the adapter still sends flow control; 04 = 500/4 kbps).
  /// The adapter's physical HS/MS switch must match - software cannot move
  /// pins.
  CanBus bus = CanBus.hs;

  /// Legacy OBD-II mode (pre-2008 cars: K-line ISO 9141-2 / KWP2000, or
  /// whatever the ELM auto-detects). The adapter then runs formatted
  /// (`ATCAF1 ATH0`) so responses arrive as plain `41 0C ..` lines with
  /// headers stripped and multi-frame messages already reassembled.
  bool legacy = false;

  /// `ATDPN` result while in legacy mode, e.g. "A5" (auto, KWP fast) or "3".
  String legacyProtocol = '';

  /// True when the auto-detected legacy protocol is actually CAN (6..C), in
  /// which case Mode 03/07 responses carry a DTC-count byte.
  bool get legacyIsCan {
    if (legacyProtocol.isEmpty) return false;
    final c = legacyProtocol[legacyProtocol.length - 1].toUpperCase();
    return '6789ABC'.contains(c);
  }
  int? reqId;
  int? respId;

  /// Last adapter identification (`ATI`) and voltage (`ATRV`).
  String adapterId = '';
  String batteryText = '';
  double? batteryVolts;

  StreamSubscription<Uint8List>? _sub;
  final StringBuffer _buf = StringBuffer();
  Completer<void>? _promptSeen;
  Future<void> _chain = Future<void>.value();

  void _log(String dir, String text) {
    final cb = onLog;
    if (cb != null) cb(LogEntry(DateTime.now(), dir, text));
  }

  /// Opens the transport and starts buffering received bytes.
  Future<void> open() async {
    await transport.connect();
    _sub = transport.readStream.listen((chunk) {
      _buf.write(String.fromCharCodes(chunk));
      if (_buf.toString().contains('>')) {
        final c = _promptSeen;
        if (c != null && !c.isCompleted) c.complete();
      }
    }, onError: (Object e) {
      _log('--', 'link error: $e');
      final c = _promptSeen;
      if (c != null && !c.isCompleted) c.complete();
    });
  }

  Future<void> close() async {
    await _sub?.cancel();
    _sub = null;
    await transport.close();
  }

  /// Send one line, return everything up to the '>' prompt (prompt stripped),
  /// exactly like `Elm327.cmd()` in the Python reference: CRs become newlines,
  /// all '>' are removed, result is trimmed. Commands are serialised so two
  /// callers cannot interleave on the wire.
  Future<String> cmd(String s,
      {Duration timeout = const Duration(seconds: 2)}) {
    final done = _chain.then((_) => _cmd(s, timeout));
    _chain = done.then((_) {}, onError: (_) {});
    return done;
  }

  Future<String> _cmd(String s, Duration timeout) async {
    if (!transport.isOpen) throw ElmException('adapter not connected');
    _log('>>', s);
    _buf.clear();
    final completer = Completer<void>();
    _promptSeen = completer;
    await transport.write(Uint8List.fromList('$s\r'.codeUnits));
    try {
      await completer.future.timeout(timeout);
    } on TimeoutException {
      // deadline: return whatever was buffered, like the Python loop.
    }
    _promptSeen = null;
    var text = _buf.toString().replaceAll('\r', '\n');
    _buf.clear();
    text = text.replaceAll('>', '').trim();
    // Strip an echoed command line if echo is still on (before ATE0 lands).
    if (text.startsWith(s)) {
      text = text.substring(s.length).trim();
    }
    for (final line in text.split('\n')) {
      if (line.trim().isNotEmpty) _log('<<', line.trim());
    }
    return text;
  }

  /// Init sequence, verbatim from the reference.
  Future<void> init() async {
    await cmd('ATZ', timeout: const Duration(seconds: 3));
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await cmd('ATE0');
    await cmd('ATL0');
    await cmd('ATS1');
    await cmd('ATH1');
    await cmd('ATCAF0');
    await cmd('ATCFC1');
    await cmd('ATAT0');
    await cmd('ATAL');
    adapterId = (await cmd('ATI')).split('\n').last.trim();
    batteryText = (await cmd('ATRV')).split('\n').last.trim();
    batteryVolts = parseVolts(batteryText);
  }

  /// "12.4V" -> 12.4; null when unparsable.
  static double? parseVolts(String s) {
    final cleaned = s.replaceAll(RegExp(r'[^\d.]'), '');
    if (cleaned.isEmpty) return null;
    return double.tryParse(cleaned);
  }

  bool get batteryLow => (batteryVolts ?? 99) < 12.0;

  /// ISO 15765-4 CAN 500 kbps: protocol 6 = 11-bit, 7 = 29-bit.
  Future<void> setBits(int b) async {
    if (legacy) await leaveLegacy();
    bits = b;
    if (bus == CanBus.ms) {
      // MS-CAN is 11-bit only on every Ford we know of.
      bits = 11;
      await cmd('ATPB E0 04');
      await cmd('ATSPB');
      return;
    }
    await cmd(b == 11 ? 'ATSP6' : 'ATSP7');
  }

  /// Select HS or MS CAN and (re)apply the protocol for the current width.
  Future<void> setBus(CanBus b) async {
    bus = b;
    await setBits(bits);
  }

  /// Switch to legacy OBD-II: protocol auto (`ATSP0`), formatted output,
  /// adaptive timing on (K-line inter-byte timing varies a lot).
  Future<void> enterLegacy() async {
    legacy = true;
    reqId = null;
    respId = null;
    await cmd('ATSP0');
    await cmd('ATCAF1');
    await cmd('ATH0');
    await cmd('ATAT1');
    legacyProtocol = '';
  }

  /// Back to the raw-frame CAN configuration used by the UDS code.
  Future<void> leaveLegacy() async {
    legacy = false;
    legacyProtocol = '';
    await cmd('ATCAF0');
    await cmd('ATH1');
    await cmd('ATAT0');
  }

  /// Ask the adapter which protocol it settled on (`ATDPN`).
  Future<String> readLegacyProtocol() async {
    final t = (await cmd('ATDPN')).split('\n').last.trim();
    legacyProtocol = t;
    return t;
  }

  /// Send a formatted (CAF1/H0) OBD-II request in legacy mode and return one
  /// byte list per response line (one line per responding ECU / frame).
  Future<List<Uint8List>> sendLegacy(List<int> payload,
      {Duration timeout = const Duration(seconds: 3)}) async {
    final text = await cmd(toHex(payload), timeout: timeout);
    return parseLegacyLines(text);
  }

  /// Parse formatted ELM output: keep hex-only lines, drop noise.
  static List<Uint8List> parseLegacyLines(String text) {
    final out = <Uint8List>[];
    final hexRe = RegExp(r'^[0-9A-Fa-f]+$');
    for (var line in text.split('\n')) {
      line = line.trim();
      if (line.isEmpty || _noise.any(line.contains)) continue;
      // ELM prefixes multi-frame CAN lines with "0:" / "1:" indices in CAF1
      // mode; strip that so the remainder is hex.
      final colon = line.indexOf(':');
      if (colon > 0 && colon <= 3) line = line.substring(colon + 1).trim();
      final hexstr = line.replaceAll(' ', '');
      if (!hexRe.hasMatch(hexstr) || hexstr.length.isOdd) continue;
      out.add(hexToBytes(hexstr));
    }
    return out;
  }

  /// ATST takes hex, units of 4 ms, max 0xFF (~1.02 s).
  Future<void> setTimeoutMs(int ms) async {
    await cmd('ATST${hexN(stValue(ms), 2)}');
  }

  static int stValue(int ms) {
    final v = ms ~/ 4;
    if (v < 1) return 1;
    if (v > 0xFF) return 0xFF;
    return v;
  }

  /// Point the adapter at one ECU. Port of `set_target()`.
  ///   11-bit: ATSH 7xx; receive filter exact (ATCRA) or wide (0x700-0x7FF)
  ///   29-bit: ATCP 18 + ATSH DAxxF1; receive 18DAF1xx or wide (any 18DAF1xx)
  Future<void> setTarget(int req, {int? resp, bool wideFilter = false}) async {
    reqId = req;
    if (bits == 11) {
      await cmd('ATSH${hexN(req, 3)}');
      if (wideFilter) {
        await cmd('ATCF700');
        await cmd('ATCM700');
        respId = null;
      } else {
        respId = resp ?? (req + 8);
        await cmd('ATCRA${hexN(respId!, 3)}');
      }
    } else {
      final prio = (req >> 24) & 0xFF;
      final lo = req & 0xFFFFFF;
      await cmd('ATCP${hexN(prio, 2)}');
      await cmd('ATSH${hexN(lo, 6)}');
      final target = (req >> 8) & 0xFF;
      final source = req & 0xFF;
      if (wideFilter) {
        await cmd('ATCF${hexN((prio << 24) | 0x00DA0000 | (source << 8), 8)}');
        await cmd('ATCM1FFFFF00');
        respId = null;
      } else {
        respId = (prio << 24) | 0x00DA0000 | (source << 8) | target;
        await cmd('ATCRA${hexN(respId!, 8)}');
      }
    }
  }

  /// Derived 29-bit response id for a request id (18DAttF1 -> 18DAF1tt).
  static int derivedResp29(int req) {
    final prio = (req >> 24) & 0xFF;
    final target = (req >> 8) & 0xFF;
    final source = req & 0xFF;
    return (prio << 24) | 0x00DA0000 | (source << 8) | target;
  }

  /// Send one single-frame ISO-TP request (payload <= 7 bytes), padded to
  /// 8 bytes, and return {responseCanId: reassembledUdsBytes}.
  Future<Map<int, Uint8List>> sendFramesAndCollect(List<int> payload,
      {Duration timeout = const Duration(milliseconds: 1500)}) async {
    if (payload.length > 7) {
      throw ElmException('multi-frame requests not supported (and not needed)');
    }
    final frame = <int>[payload.length, ...payload];
    while (frame.length < 8) {
      frame.add(0x00);
    }
    final text = await cmd(toHex(frame), timeout: timeout);
    return parseFrames(text, bits);
  }

  static const _noise = <String>[
    'NO DATA',
    'SEARCHING',
    'STOPPED',
    'BUS INIT',
    'CAN ERROR',
    'UNABLE',
    'ERROR',
    '?',
  ];

  /// Group raw frames by CAN ID and reassemble ISO-TP (SF / FF / CF).
  /// Port of `_parse_frames()`; header is 3 hex chars (11-bit) or 8 (29-bit)
  /// once spaces are removed.
  static Map<int, Uint8List> parseFrames(String text, int bits) {
    final hdrLen = bits == 11 ? 3 : 8;
    final lens = <int, int>{};
    final datas = <int, List<int>>{};
    final order = <int>[];
    final hexRe = RegExp(r'^[0-9A-Fa-f]+$');
    for (var line in text.split('\n')) {
      line = line.trim();
      if (line.isEmpty || _noise.any(line.contains)) continue;
      final hexstr = line.replaceAll(' ', '');
      if (!hexRe.hasMatch(hexstr) || hexstr.length <= hdrLen) continue;
      final canId = int.parse(hexstr.substring(0, hdrLen), radix: 16);
      final rest = hexstr.substring(hdrLen);
      if (rest.length.isOdd) continue;
      final data = hexToBytes(rest);
      if (data.isEmpty) continue;
      final pciType = data[0] >> 4;
      if (pciType == 0) {
        final n = data[0] & 0x0F;
        final end = (1 + n) > data.length ? data.length : 1 + n;
        lens[canId] = n;
        datas[canId] = data.sublist(1, end).toList();
        if (!order.contains(canId)) order.add(canId);
      } else if (pciType == 1) {
        if (data.length < 2) continue;
        final n = ((data[0] & 0x0F) << 8) | data[1];
        lens[canId] = n;
        datas[canId] = data.sublist(2).toList();
        if (!order.contains(canId)) order.add(canId);
      } else if (pciType == 2 && datas.containsKey(canId)) {
        datas[canId]!.addAll(data.sublist(1));
      }
      // pciType 3 = flow control from the ECU - ignore.
    }
    final out = <int, Uint8List>{};
    for (final id in order) {
      final d = datas[id]!;
      final n = lens[id]!;
      out[id] = Uint8List.fromList(d.length > n ? d.sublist(0, n) : d);
    }
    return out;
  }
}

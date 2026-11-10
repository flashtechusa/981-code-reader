import 'dart:typed_data';

import 'elm327.dart';
import 'module.dart';
import 'uds.dart';

/// SAE J1979 Mode 01 PID definition with decode formula.
class ObdPid {
  const ObdPid({
    required this.pid,
    required this.name,
    required this.shortName,
    required this.unit,
    required this.min,
    required this.max,
    required this.bytes,
    required this.decode,
  });

  final int pid;
  final String name;
  final String shortName;
  final String unit;
  final double min;
  final double max;
  final int bytes;
  final double Function(List<int> data) decode;

  String get hex => pid.toRadixString(16).toUpperCase().padLeft(2, '0');
}

double _a(List<int> d) => d[0].toDouble();
double _ab(List<int> d) => (d[0] * 256 + d[1]).toDouble();

/// The PIDs this app polls, in display order.
const List<ObdPid> livePids = [
  ObdPid(
    pid: 0x0C,
    name: 'Engine RPM',
    shortName: 'RPM',
    unit: 'rpm',
    min: 0,
    max: 8000,
    bytes: 2,
    decode: _rpm,
  ),
  ObdPid(
    pid: 0x0D,
    name: 'Vehicle speed',
    shortName: 'Speed',
    unit: 'km/h',
    min: 0,
    max: 255,
    bytes: 1,
    decode: _a,
  ),
  ObdPid(
    pid: 0x05,
    name: 'Coolant temperature',
    shortName: 'Coolant',
    unit: '°C',
    min: -40,
    max: 215,
    bytes: 1,
    decode: _tempA,
  ),
  ObdPid(
    pid: 0x0F,
    name: 'Intake air temperature',
    shortName: 'IAT',
    unit: '°C',
    min: -40,
    max: 215,
    bytes: 1,
    decode: _tempA,
  ),
  ObdPid(
    pid: 0x04,
    name: 'Calculated engine load',
    shortName: 'Load',
    unit: '%',
    min: 0,
    max: 100,
    bytes: 1,
    decode: _pct,
  ),
  ObdPid(
    pid: 0x06,
    name: 'Short term fuel trim B1',
    shortName: 'STFT1',
    unit: '%',
    min: -100,
    max: 99.2,
    bytes: 1,
    decode: _trim,
  ),
  ObdPid(
    pid: 0x07,
    name: 'Long term fuel trim B1',
    shortName: 'LTFT1',
    unit: '%',
    min: -100,
    max: 99.2,
    bytes: 1,
    decode: _trim,
  ),
  ObdPid(
    pid: 0x08,
    name: 'Short term fuel trim B2',
    shortName: 'STFT2',
    unit: '%',
    min: -100,
    max: 99.2,
    bytes: 1,
    decode: _trim,
  ),
  ObdPid(
    pid: 0x09,
    name: 'Long term fuel trim B2',
    shortName: 'LTFT2',
    unit: '%',
    min: -100,
    max: 99.2,
    bytes: 1,
    decode: _trim,
  ),
  ObdPid(
    pid: 0x11,
    name: 'Throttle position',
    shortName: 'Throttle',
    unit: '%',
    min: 0,
    max: 100,
    bytes: 1,
    decode: _pct,
  ),
  ObdPid(
    pid: 0x42,
    name: 'Control module voltage',
    shortName: 'Volts',
    unit: 'V',
    min: 0,
    max: 16,
    bytes: 2,
    decode: _volts,
  ),
];

double _rpm(List<int> d) => _ab(d) / 4.0;
double _tempA(List<int> d) => _a(d) - 40.0;
double _pct(List<int> d) => _a(d) * 100.0 / 255.0;
double _trim(List<int> d) => (_a(d) - 128.0) * 100.0 / 128.0;
double _volts(List<int> d) => _ab(d) / 1000.0;

ObdPid? pidByNumber(int pid) {
  for (final p in livePids) {
    if (p.pid == pid) return p;
  }
  return null;
}

/// Decodes a positive Mode 01 response `41 <pid> <data...>` for [pid].
/// Returns null when the response does not match or is too short.
double? decodeMode01(ObdPid pid, Uint8List resp) {
  if (resp.length < 2 + pid.bytes) return null;
  if (resp[0] != 0x41 || resp[1] != pid.pid) return null;
  return pid.decode(resp.sublist(2, 2 + pid.bytes));
}

/// Live-data reader for the DME at 0x7E0 / 0x7E8.
class ObdLive {
  ObdLive(this.elm, this.uds);
  final Elm327 elm;
  final Uds uds;

  /// Points the adapter at the DME. Must be called before [read].
  Future<void> prepare() async {
    elm.bus = CanBus.hs; // the PCM / DME is always on HS-CAN
    await elm.setBits(11);
    await elm.setTimeoutMs(200);
    await elm.setTarget(dmeRequest11, resp: dmeResponse11);
  }

  /// Reads one PID; null when unsupported / no answer.
  Future<double?> read(ObdPid pid) async {
    final r = await uds.single([sidObdMode01, pid.pid],
        timeout: const Duration(milliseconds: 600));
    if (r.isEmpty) return null;
    if (r[0] == 0x7F) return null;
    return decodeMode01(pid, r);
  }
}

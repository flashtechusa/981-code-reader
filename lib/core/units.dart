import 'obd_pids.dart';

/// Which unit system to DISPLAY in. Values from the ECU are always decoded in
/// SI (km/h, °C) by `obd_pids.dart`; conversion happens only at render time so
/// gauge fractions, graph scaling and tests keep using the raw values.
enum UnitSystem { us, metric }

UnitSystem unitSystemFromString(String? s) =>
    s == 'metric' ? UnitSystem.metric : UnitSystem.us;

String unitSystemToString(UnitSystem u) =>
    u == UnitSystem.metric ? 'metric' : 'us';

class Units {
  const Units(this.system);
  final UnitSystem system;

  bool get isUs => system == UnitSystem.us;

  /// Converts a raw SI value for display in the selected system.
  double convert(ObdPid pid, double v) {
    if (!isUs) return v;
    switch (pid.unit) {
      case 'km/h':
        return v * 0.621371;
      case '°C':
        return v * 9 / 5 + 32;
      default:
        return v;
    }
  }

  /// Unit label for display in the selected system.
  String label(ObdPid pid) {
    if (!isUs) return pid.unit;
    switch (pid.unit) {
      case 'km/h':
        return 'mph';
      case '°C':
        return '°F';
      default:
        return pid.unit;
    }
  }

  /// Formats a raw SI value, converted, with a sensible number of decimals.
  String format(ObdPid pid, double raw) {
    final v = convert(pid, raw);
    switch (pid.pid) {
      case 0x42:
        return v.toStringAsFixed(2);
      case 0x06:
      case 0x07:
      case 0x08:
      case 0x09:
      case 0x04:
      case 0x11:
        return v.toStringAsFixed(1);
      default:
        return v.round().toString();
    }
  }
}

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/units.dart';

/// Persisted user settings (adapter address, scan options).
class Settings extends ChangeNotifier {
  static const defaultHost = '192.168.0.10';
  static const defaultPort = 35000;

  String _host = defaultHost;
  int _port = defaultPort;
  bool _includePowertrain = false;
  UnitSystem _unitSystem = UnitSystem.us; // US default: mph / °F

  String get host => _host;
  int get port => _port;
  bool get includePowertrain => _includePowertrain;
  UnitSystem get unitSystem => _unitSystem;
  Units get units => Units(_unitSystem);

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      _host = p.getString('host') ?? defaultHost;
      _port = p.getInt('port') ?? defaultPort;
      _includePowertrain = p.getBool('includePowertrain') ?? false;
      _unitSystem = unitSystemFromString(p.getString('unitSystem'));
    } catch (_) {
      // keep defaults
    }
    notifyListeners();
  }

  Future<void> update({
    String? host,
    int? port,
    bool? includePowertrain,
    UnitSystem? unitSystem,
  }) async {
    if (host != null && host.trim().isNotEmpty) _host = host.trim();
    if (port != null && port > 0 && port < 65536) _port = port;
    if (includePowertrain != null) _includePowertrain = includePowertrain;
    if (unitSystem != null) _unitSystem = unitSystem;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('host', _host);
      await p.setInt('port', _port);
      await p.setBool('includePowertrain', _includePowertrain);
      await p.setString('unitSystem', unitSystemToString(_unitSystem));
    } catch (_) {
      // persistence is best-effort
    }
  }
}

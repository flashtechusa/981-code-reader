import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persisted user settings (adapter address, scan options).
class Settings extends ChangeNotifier {
  static const defaultHost = '192.168.0.10';
  static const defaultPort = 35000;

  String _host = defaultHost;
  int _port = defaultPort;
  bool _includePowertrain = false;

  String get host => _host;
  int get port => _port;
  bool get includePowertrain => _includePowertrain;

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      _host = p.getString('host') ?? defaultHost;
      _port = p.getInt('port') ?? defaultPort;
      _includePowertrain = p.getBool('includePowertrain') ?? false;
    } catch (_) {
      // keep defaults
    }
    notifyListeners();
  }

  Future<void> update({String? host, int? port, bool? includePowertrain}) async {
    if (host != null && host.trim().isNotEmpty) _host = host.trim();
    if (port != null && port > 0 && port < 65536) _port = port;
    if (includePowertrain != null) _includePowertrain = includePowertrain;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('host', _host);
      await p.setInt('port', _port);
      await p.setBool('includePowertrain', _includePowertrain);
    } catch (_) {
      // persistence is best-effort
    }
  }
}

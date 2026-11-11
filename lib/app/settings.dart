import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/dtc_text.dart';
import '../core/units.dart';

/// Which diagnostic bus the car has.
///  * can    - 2008+ (and most 2004+) cars: ISO 15765-4 CAN on pins 6/14, UDS
///             per module. Porsche 981, Ford F-150, etc.
///  * legacy - pre-CAN cars (K-line ISO 9141-2 / KWP2000 on pin 7), e.g. a
///             2004 Maserati 4200. Generic OBD-II engine data only.
enum VehicleBus { can, legacy }

/// Persisted user settings (adapter address, scan options).
class Settings extends ChangeNotifier {
  static const defaultHost = '192.168.0.10';
  static const defaultPort = 35000;

  String _host = defaultHost;
  int _port = defaultPort;
  bool _includePowertrain = false;
  UnitSystem _unitSystem = UnitSystem.us; // US default: mph / °F
  VehicleBus _bus = VehicleBus.can;
  bool _hasMsSwitch = true; // bbfly / OBDLink MX style HS/MS switch
  MakeCodeText _codeText = MakeCodeText.auto;
  bool _fullScan = false; // false: targeted scan when the VIN says Ford

  String get host => _host;
  int get port => _port;
  bool get includePowertrain => _includePowertrain;
  UnitSystem get unitSystem => _unitSystem;
  VehicleBus get bus => _bus;
  bool get legacyBus => _bus == VehicleBus.legacy;
  bool get hasMsSwitch => _hasMsSwitch;
  MakeCodeText get codeText => _codeText;
  bool get fullScan => _fullScan;
  Units get units => Units(_unitSystem);

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      _host = p.getString('host') ?? defaultHost;
      _port = p.getInt('port') ?? defaultPort;
      _includePowertrain = p.getBool('includePowertrain') ?? false;
      _unitSystem = unitSystemFromString(p.getString('unitSystem'));
      _bus = p.getString('bus') == 'legacy' ? VehicleBus.legacy : VehicleBus.can;
      _hasMsSwitch = p.getBool('hasMsSwitch') ?? true;
      _codeText = makeCodeTextFromString(p.getString('codeText'));
      _fullScan = p.getBool('fullScan') ?? false;
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
    VehicleBus? bus,
    bool? hasMsSwitch,
    MakeCodeText? codeText,
    bool? fullScan,
  }) async {
    if (host != null && host.trim().isNotEmpty) _host = host.trim();
    if (port != null && port > 0 && port < 65536) _port = port;
    if (includePowertrain != null) _includePowertrain = includePowertrain;
    if (unitSystem != null) _unitSystem = unitSystem;
    if (bus != null) _bus = bus;
    if (hasMsSwitch != null) _hasMsSwitch = hasMsSwitch;
    if (codeText != null) _codeText = codeText;
    if (fullScan != null) _fullScan = fullScan;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('host', _host);
      await p.setInt('port', _port);
      await p.setBool('includePowertrain', _includePowertrain);
      await p.setString('unitSystem', unitSystemToString(_unitSystem));
      await p.setString('bus', _bus == VehicleBus.legacy ? 'legacy' : 'can');
      await p.setBool('hasMsSwitch', _hasMsSwitch);
      await p.setString('codeText', makeCodeTextToString(_codeText));
      await p.setBool('fullScan', _fullScan);
    } catch (_) {
      // persistence is best-effort
    }
  }
}

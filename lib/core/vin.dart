import 'dtc_text.dart';

/// What can be read from a VIN offline: make (from the WMI, first 3
/// characters) and model year (10th character). The model itself needs a
/// manufacturer VIN database (e.g. NHTSA vPIC, online) and is not decoded.
class VehicleId {
  const VehicleId(this.vin, this.make, this.modelYear);

  final String vin;

  /// "Ford", "Porsche", ... or null when the WMI is not in [wmiMakes].
  final String? make;

  /// e.g. 2015; null when the 10th character is not a year code.
  final int? modelYear;

  String get wmi => vin.substring(0, 3);

  /// Ford / Lincoln / Mercury: their module addresses follow Ford's
  /// conventions (lib/core/known_modules.dart), so a targeted scan works.
  bool get isFordGroup => isFordVin(vin);

  /// "2015 Ford" / "Porsche" / "unknown make (WMI XYZ)".
  String get summary {
    final m = make ?? 'unknown make (WMI $wmi)';
    return modelYear == null ? m : '$modelYear $m';
  }
}

/// World manufacturer identifiers -> make, for display and scan planning.
/// Not exhaustive; an unknown WMI just means a full scan.
final Map<String, String> wmiMakes = {
  // Ford group (same sets as the code-text gating in dtc_text.dart)
  for (final w in fordWmis)
    w: w.startsWith('1L') || w.startsWith('2L') || w.startsWith('3L') ||
            w.startsWith('5L')
        ? 'Lincoln'
        : w.endsWith('ME') || w == '4M2'
            ? 'Mercury'
            : 'Ford',
  for (final w in mazdaWmis) w: 'Mazda',
  'WP0': 'Porsche', 'WP1': 'Porsche',
  'ZAM': 'Maserati',
  'WVW': 'Volkswagen', 'WVG': 'Volkswagen', 'WV1': 'Volkswagen',
  'WV2': 'Volkswagen', '1VW': 'Volkswagen', '3VW': 'Volkswagen',
  'WAU': 'Audi', 'WA1': 'Audi', 'WUA': 'Audi',
  'WBA': 'BMW', 'WBS': 'BMW', 'WBX': 'BMW', '5UX': 'BMW', '5UJ': 'BMW',
  'WDB': 'Mercedes-Benz', 'WDD': 'Mercedes-Benz', 'WDC': 'Mercedes-Benz',
  'W1K': 'Mercedes-Benz', 'W1N': 'Mercedes-Benz', '4JG': 'Mercedes-Benz',
  '1G1': 'Chevrolet', '1GC': 'Chevrolet', '2G1': 'Chevrolet',
  '3GC': 'Chevrolet', '1GT': 'GMC', '3GT': 'GMC', '1G6': 'Cadillac',
  '1C3': 'Chrysler', '2C3': 'Chrysler', '1C4': 'Jeep / Dodge',
  '1C6': 'Ram', '3C6': 'Ram', '1J4': 'Jeep', '1J8': 'Jeep',
  '4T1': 'Toyota', '5TD': 'Toyota', '5TF': 'Toyota', 'JTD': 'Toyota',
  '1HG': 'Honda', '2HG': 'Honda', 'JHM': 'Honda', '5FN': 'Honda',
  '5J6': 'Honda', '1N4': 'Nissan', '1N6': 'Nissan', 'JN1': 'Nissan',
  '5N1': 'Nissan', 'KMH': 'Hyundai', '5NP': 'Hyundai', 'KNA': 'Kia',
  'KND': 'Kia', '5XY': 'Kia', 'JF1': 'Subaru', 'JF2': 'Subaru',
  '4S3': 'Subaru', '4S4': 'Subaru', '5YJ': 'Tesla', '7SA': 'Tesla',
};

/// 10th-character year codes in order; the cycle repeats every 30 years.
const String _yearCodes = 'ABCDEFGHJKLMNPRSTVWXY123456789';

/// Model year from the 10th character. North-American rule for light
/// vehicles: a numeric 7th character means 1980-2009, a letter 2010-2039.
int? modelYearOf(String vin) {
  if (vin.length != 17) return null;
  final i = _yearCodes.indexOf(vin[9]);
  if (i < 0) return null;
  final numeric7 = '0123456789'.contains(vin[6]);
  return (numeric7 ? 1980 : 2010) + i;
}

/// Null unless [raw] is a plausible 17-character VIN.
VehicleId? decodeVin(String? raw) {
  if (!looksLikeVin(raw)) return null;
  final vin = raw!.trim().toUpperCase();
  return VehicleId(vin, wmiMakes[vin.substring(0, 3)], modelYearOf(vin));
}

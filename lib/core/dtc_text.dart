import 'dtc_table.dart';
import 'ford_dtc_table.dart';

/// Where the plain-English text for a DTC comes from.
enum DtcTextSource { sae, ford }

/// User setting: when to use the Ford-family code list.
///  * auto - only when a module reported a Ford / Lincoln / Mercury / Mazda VIN
///           (or Ford MS-CAN modules were found)
///  * ford - always (for a Ford-family car whose modules give no VIN)
///  * off  - SAE generic text only
enum MakeCodeText { auto, ford, off }

MakeCodeText makeCodeTextFromString(String? s) => switch (s) {
      'ford' => MakeCodeText.ford,
      'off' => MakeCodeText.off,
      _ => MakeCodeText.auto,
    };

String makeCodeTextToString(MakeCodeText m) => switch (m) {
      MakeCodeText.auto => 'auto',
      MakeCodeText.ford => 'ford',
      MakeCodeText.off => 'off',
    };

/// Plain-English text for one code.
class DtcText {
  const DtcText(this.meanings, this.source);

  static const none = DtcText([], null);

  /// Every candidate meaning, most likely first. Empty when unknown.
  /// A meaning may carry a second line "Possible causes: ...".
  final List<String> meanings;
  final DtcTextSource? source;

  bool get isKnown => meanings.isNotEmpty;

  /// First meaning, first line only - for one-line list rows.
  String? get headline => isKnown ? meanings.first.split('\n').first : null;

  /// How many other meanings the same code has in other modules.
  int get otherCount => isKnown ? meanings.length - 1 : 0;
}

/// World manufacturer identifiers (first 3 VIN characters) of Ford, Lincoln,
/// Mercury and Mazda. Not exhaustive - the Settings override covers the rest.
const Set<String> fordFamilyWmis = {
  // Ford
  '1FA', '1FB', '1FC', '1FD', '1FM', '1FT', '1ZV', '2FA', '2FM', '2FT',
  '3FA', '3FE', '3FM', '3FT', 'NM0', 'WF0', 'SFA', 'MAJ', '6FP', 'MNB',
  '8AF', '9BF', 'LVS',
  // Lincoln
  '1LN', '2LM', '3LN', '5LM', '5LT',
  // Mercury
  '1ME', '2ME', '3ME', '4M2',
  // Mazda
  'JM1', 'JM2', 'JM3', 'JMZ', '4F2', '4F4', '1YV', '3MZ', '3MV',
};

/// True when [vin] belongs to a Ford-family make. Null / short VINs: false.
bool isFordFamilyVin(String? vin) {
  if (vin == null) return false;
  final v = vin.trim().toUpperCase();
  if (v.length < 3) return false;
  return fordFamilyWmis.contains(v.substring(0, 3));
}

/// True when [vin] is a plausible 17-character VIN of some make.
bool looksLikeVin(String? vin) =>
    vin != null && _vinRe.hasMatch(vin.trim().toUpperCase());

final RegExp _vinRe = RegExp(r'^[A-HJ-NPR-Z0-9]{17}$');

/// Whether the Ford list applies to this vehicle.
///  [vins] - every VIN the modules reported (F190 / Mode 09).
///  [hasMsCanModules] - Ford MS-CAN modules answered (only Ford uses that bus
///  layout this app scans).
/// In auto mode a non-Ford VIN always wins, so a Porsche or Maserati never
/// gets Ford meanings for its manufacturer codes.
bool fordTextApplies(MakeCodeText mode,
    {Iterable<String> vins = const [], bool hasMsCanModules = false}) {
  if (mode == MakeCodeText.off) return false;
  if (mode == MakeCodeText.ford) return true;
  final real = vins.where(looksLikeVin).toList();
  if (real.isNotEmpty) return real.any(isFordFamilyVin);
  return hasMsCanModules;
}

/// Text for a 5-character SAE code ("B1B7E"). SAE generic text always wins
/// for the codes it covers; the Ford list only fills manufacturer-specific
/// codes, and only when [ford] is true.
DtcText describeDtcCode(String saeBase, {required bool ford}) {
  final key = saeBase.toUpperCase();
  final sae = saeDtcText[key];
  if (sae != null) return DtcText([sae], DtcTextSource.sae);
  if (ford) {
    final f = fordDtcText[key];
    if (f != null && f.isNotEmpty) return DtcText(f, DtcTextSource.ford);
  }
  return DtcText.none;
}

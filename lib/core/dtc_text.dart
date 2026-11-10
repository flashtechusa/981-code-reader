import 'dtc_table.dart';
import 'ford_dtc_table.dart';
import 'verified_generic_dtc.dart';

/// Where the plain-English text for a DTC comes from.
///  * verifiedGeneric - lib/core/verified_generic_dtc.dart (primary-source checked)
///  * sae             - lib/core/dtc_table.dart (python-OBD, SAE J2012 generic)
///  * ford            - lib/core/ford_dtc_table.dart (Tony's Ford list)
enum DtcTextSource { verifiedGeneric, sae, ford }

/// User setting: when to use the Ford code list.
///  * auto - when a module reports a Ford / Lincoln / Mercury VIN (shown as
///           confirmed), or a Mazda VIN / Ford-style MS-CAN modules with no VIN
///           (shown, marked NOT confirmed)
///  * ford - user says the car is a Ford (confirmed unless a module reports a
///           VIN of another make)
///  * off  - generic text only
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

/// How far the Ford list applies to the vehicle on the bus.
///  * off         - not used
///  * unconfirmed - shown only as "Ford meaning, not confirmed for this make"
///  * confirmed   - Ford / Lincoln / Mercury vehicle
enum FordTextLevel { off, unconfirmed, confirmed }

/// Plain-English text for one code, with how much it can be trusted here.
class DtcText {
  const DtcText(this.meanings, this.source,
      {this.definitive = true, this.label, this.makeConfirmed = true});

  static const none = DtcText([], null);

  /// Every candidate meaning, most likely first. Empty when unknown.
  /// A meaning may carry a second line "Possible causes: ...".
  final List<String> meanings;
  final DtcTextSource? source;

  /// True when the first meaning may be shown as THE meaning of the code.
  /// False when the app must not pick one silently: several Ford meanings for
  /// an SAE-generic-range code, or Ford text on a make it is not confirmed for.
  final bool definitive;

  /// Short provenance / caveat line for the UI, or null.
  final String? label;

  /// False when the Ford list is shown for a vehicle not confirmed as Ford.
  final bool makeConfirmed;

  bool get isKnown => meanings.isNotEmpty;

  /// First meaning, first line only - only when [definitive].
  String? get headline =>
      isKnown && definitive ? meanings.first.split('\n').first : null;

  /// One line for a list row. Never silently picks among several meanings.
  String get summary {
    if (headline != null) return headline!;
    if (!isKnown) return 'Manufacturer-specific code';
    if (!makeConfirmed) {
      return 'Ford meaning${meanings.length > 1 ? 's' : ''} not confirmed '
          'for this make - tap to see';
    }
    return '${meanings.length} possible meanings - tap to see';
  }

  /// How many other meanings the same code has in other modules.
  int get otherCount => isKnown ? meanings.length - 1 : 0;
}

/// World manufacturer identifiers (first 3 VIN characters). Not exhaustive -
/// the Settings override covers the rest.
const Set<String> fordWmis = {
  // Ford
  '1FA', '1FB', '1FC', '1FD', '1FM', '1FT', '1ZV', '2FA', '2FM', '2FT',
  '3FA', '3FE', '3FM', '3FT', 'NM0', 'WF0', 'SFA', 'MAJ', '6FP', 'MNB',
  '8AF', '9BF', 'LVS',
  // Lincoln
  '1LN', '2LM', '3LN', '5LM', '5LT',
  // Mercury
  '1ME', '2ME', '3ME', '4M2',
};

/// Mazda shares some Ford hardware but NOT Ford's code meanings: the audit of
/// a second database found 69 of 233 Mazda codes disagreeing with the Ford
/// list, so the Ford list is never treated as confirmed for Mazda.
const Set<String> mazdaWmis = {
  'JM1', 'JM2', 'JM3', 'JMZ', '4F2', '4F4', '1YV', '3MZ', '3MV',
};

String? _wmi(String? vin) {
  if (vin == null) return null;
  final v = vin.trim().toUpperCase();
  return v.length < 3 ? null : v.substring(0, 3);
}

/// Ford, Lincoln or Mercury.
bool isFordVin(String? vin) => fordWmis.contains(_wmi(vin));
bool isMazdaVin(String? vin) => mazdaWmis.contains(_wmi(vin));

/// True when [vin] is a plausible 17-character VIN of some make.
bool looksLikeVin(String? vin) =>
    vin != null && _vinRe.hasMatch(vin.trim().toUpperCase());

final RegExp _vinRe = RegExp(r'^[A-HJ-NPR-Z0-9]{17}$');

/// How far the Ford list applies to this vehicle.
///  [vins] - every VIN the modules reported (F190 / Mode 09).
///  [hasMsCanModules] - modules answered on MS-CAN (Ford, but also Mazda).
/// A real VIN always decides in auto mode; a Porsche or Maserati VIN turns the
/// Ford list off, a Mazda VIN makes it unconfirmed.
FordTextLevel fordTextLevel(MakeCodeText mode,
    {Iterable<String> vins = const [], bool hasMsCanModules = false}) {
  if (mode == MakeCodeText.off) return FordTextLevel.off;
  final real = vins.where(looksLikeVin).toList();
  if (real.isNotEmpty) {
    if (real.any(isFordVin)) return FordTextLevel.confirmed;
    if (mode == MakeCodeText.ford || real.any(isMazdaVin)) {
      return FordTextLevel.unconfirmed;
    }
    return FordTextLevel.off;
  }
  if (mode == MakeCodeText.ford) return FordTextLevel.confirmed;
  return hasMsCanModules ? FordTextLevel.unconfirmed : FordTextLevel.off;
}

/// SAE J2012 manufacturer-controlled ranges (P1xxx, P30xx-P33xx, B1/B2,
/// C1/C2, U1/U2). Everything else is SAE generic: its meaning is the same on
/// every make, so a make-specific list has no supported reason to override it.
bool isManufacturerRange(String code) {
  final c = code.toUpperCase();
  if (c.length < 3) return false;
  if (c[0] == 'P') return c[1] == '1' || (c[1] == '3' && '0123'.contains(c[2]));
  return c[1] == '1' || c[1] == '2';
}

/// Text for a 5-character SAE code ("B1B7E") on this vehicle.
/// Precedence: [verified] generic, SAE table, then the Ford list (never mixed
/// with generic text). Ford text is definitive only for a manufacturer-range
/// code on a confirmed Ford; for an SAE-generic-range code it is a single
/// unverified meaning at best, and several meanings are never silently
/// reduced to one.
DtcText describeDtcCode(String saeBase,
    {FordTextLevel ford = FordTextLevel.off,
    Map<String, String> verified = verifiedGenericDtcText}) {
  final key = saeBase.toUpperCase();
  final v = verified[key];
  if (v != null) return DtcText([v], DtcTextSource.verifiedGeneric);
  final sae = saeDtcText[key];
  if (sae != null) return DtcText([sae], DtcTextSource.sae);
  if (ford == FordTextLevel.off) return DtcText.none;
  final f = fordDtcText[key];
  if (f == null || f.isEmpty) return DtcText.none;
  final n = f.length;
  if (ford == FordTextLevel.unconfirmed) {
    return DtcText(f, DtcTextSource.ford,
        definitive: false,
        makeConfirmed: false,
        label: 'Ford list - NOT confirmed for this make');
  }
  if (!isManufacturerRange(key)) {
    return DtcText(f, DtcTextSource.ford,
        definitive: n == 1,
        label: n == 1
            ? 'Ford list - generic code, text not verified'
            : 'Ford list - $n meanings for a generic code, none verified');
  }
  return DtcText(f, DtcTextSource.ford,
      label: n == 1
          ? 'Ford list'
          : 'Ford list - +${n - 1} other meaning${n == 2 ? '' : 's'}, tap for all');
}

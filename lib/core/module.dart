import 'hex.dart';
import 'known_modules.dart';
import 'uds.dart';

/// One ECU found on the diagnostic CAN.
class Module {
  Module({
    required this.bits,
    required this.reqId,
    required this.respId,
    Map<String, String>? info,
    List<Dtc>? dtcs,
    this.note,
  })  : info = info ?? <String, String>{},
        dtcs = dtcs ?? <Dtc>[];

  final int bits;
  final int reqId;
  final int respId;
  Map<String, String> info;
  List<Dtc> dtcs;

  /// Error text from identification / DTC read, if any.
  String? note;

  /// Address-convention hint (Ford/VW tables), 11-bit only.
  KnownModule? get known => bits == 11 ? knownModule11(reqId) : null;

  /// True when identification text says airbag, OR the address is a known
  /// restraints-module address AND the module did not identify as something
  /// else by name.
  bool get isAirbag =>
      looksLikeAirbag(info, dtcs) ||
      (known?.airbag == true && systemName.isEmpty);

  /// Whether the airbag flag came only from the address table.
  bool get airbagByAddressOnly =>
      isAirbag && !looksLikeAirbag(info, dtcs);
  bool get isPowertrain => bits == 11
      ? isPowertrain11(reqId)
      : powertrain29Targets.contains((reqId >> 8) & 0xFF);

  /// "715" or "18DA15F1"
  String get address => bits == 11 ? hexN(reqId, 3) : hexN(reqId, 8);
  String get responseAddress => bits == 11 ? hexN(respId, 3) : hexN(respId, 8);

  String get systemName => info['system name'] ?? '';
  String get partNumber => info['spare part number'] ?? '';
  String get corePart => info['core part number'] ?? '';
  String get displayName {
    if (systemName.isNotEmpty) return systemName;
    final k = known;
    if (k != null) return '${k.abbr} - ${k.name}';
    if (partNumber.isNotEmpty) return partNumber;
    if (corePart.isNotEmpty) return corePart;
    return 'Unknown module';
  }

  /// Secondary line shown under the name: where the label came from.
  String? get displayHint {
    final k = known;
    if (systemName.isEmpty && k != null) return 'by address, ${k.make} convention';
    return null;
  }

  Module copyWith({Map<String, String>? info, List<Dtc>? dtcs, String? note}) =>
      Module(
        bits: bits,
        reqId: reqId,
        respId: respId,
        info: info ?? this.info,
        dtcs: dtcs ?? this.dtcs,
        note: note ?? this.note,
      );
}

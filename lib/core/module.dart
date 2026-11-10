import 'hex.dart';
import 'known_modules.dart';
import 'uds.dart';

/// Which physical CAN the module lives on. Ford (and some others) run two:
/// HS-CAN on OBD pins 6/14 at 500 kbps and MS-CAN on pins 3/11 at 125 kbps.
/// A single-channel ELM327 reaches MS-CAN only through the adapter's HS/MS
/// switch, so the user has to flip it - the UI prompts for that.
enum CanBus { hs, ms }

/// One ECU found on the diagnostic CAN.
class Module {
  Module({
    required this.bits,
    required this.reqId,
    required this.respId,
    this.bus = CanBus.hs,
    Map<String, String>? info,
    List<Dtc>? dtcs,
    this.note,
  })  : info = info ?? <String, String>{},
        dtcs = dtcs ?? <Dtc>[];

  final int bits;
  final int reqId;
  final int respId;
  final CanBus bus;
  Map<String, String> info;
  List<Dtc> dtcs;

  /// Error text from identification / DTC read, if any.
  String? note;

  /// Address-convention hint (Ford/VW tables), 11-bit only.
  KnownModule? get known {
    if (bits != 11) return null;
    if (bus == CanBus.ms) return knownModulesMs[reqId] ?? knownModule11(reqId);
    return knownModule11(reqId);
  }

  /// True when identification text says airbag, OR the address is a known
  /// restraints-module address AND the module did not identify as something
  /// else by name. A module whose address is KNOWN to be something else
  /// (Ford APIM, BCM ...) can only be flagged by identification text, never
  /// by the "active B-code" fallback - SYNC modules throw B-codes too.
  bool get isAirbag {
    final k = known;
    if (k != null && !k.airbag) return airbagByIdentification(info);
    return looksLikeAirbag(info, dtcs) ||
        (k?.airbag == true && systemName.isEmpty);
  }

  /// Whether the airbag flag came only from the address table.
  bool get airbagByAddressOnly =>
      isAirbag && !looksLikeAirbag(info, dtcs);

  List<Dtc> get activeDtcs => dtcs.where((d) => d.isActive).toList();
  int get inactiveCount => dtcs.length - activeDtcs.length;
  bool get isPowertrain => bits == 11
      ? isPowertrain11(reqId)
      : powertrain29Targets.contains((reqId >> 8) & 0xFF);

  /// "715" or "18DA15F1"
  String get address =>
      (bits == 11 ? hexN(reqId, 3) : hexN(reqId, 8)) +
      (bus == CanBus.ms ? ' MS' : '');
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
        bus: bus,
        info: info ?? this.info,
        dtcs: dtcs ?? this.dtcs,
        note: note ?? this.note,
      );
}

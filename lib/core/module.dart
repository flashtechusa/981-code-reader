import 'hex.dart';
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

  bool get isAirbag => looksLikeAirbag(info, dtcs);
  bool get isPowertrain => bits == 11
      ? isPowertrain11(reqId)
      : powertrain29Targets.contains((reqId >> 8) & 0xFF);

  /// "715" or "18DA15F1"
  String get address => bits == 11 ? hexN(reqId, 3) : hexN(reqId, 8);
  String get responseAddress => bits == 11 ? hexN(respId, 3) : hexN(respId, 8);

  String get systemName => info['system name'] ?? '';
  String get partNumber => info['spare part number'] ?? '';
  String get displayName => systemName.isNotEmpty
      ? systemName
      : (partNumber.isNotEmpty ? partNumber : 'Unknown module');

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

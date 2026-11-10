/// Generic (SAE-range) DTC text that has been checked against a primary
/// source: codes the python-OBD table (`dtc_table.dart`, generated - never
/// hand-edited) lacks, or where it still says "Reserved".
///
/// Candidate additions are staged in `tool/data/staged/`. An entry moves here
/// only when a reviewer has read a primary source (OEM service information,
/// a government document, or SAE J2012-DA) that gives the same meaning, and
/// the source is cited with the entry. See tool/data/staged/README.md.
///
/// Precedence (lib/core/dtc_text.dart): this table, then the SAE table, then
/// the Ford list. An entry here therefore replaces a stale "Reserved" SAE
/// entry, and replaces Ford-list guesses for the same code - e.g. B0001,
/// where the Ford list's most frequent meaning is "ECU internal fault" but the
/// SAE meaning is a deployment-loop fault.
const Map<String, String> verifiedGenericDtcText = {
  // NHTSA-hosted Jaguar/Land Rover TOPIx bulletin SSM71832 maps B0001:11,
  // :12, :1A and :1B to this base descriptor (failure subtype follows code).
  // https://static.nhtsa.gov/odi/tsbs/2014/MC-10231230-9999.pdf
  'B0001': 'Driver Frontal Stage 1 Deployment Control',

  // Saab 9-4X (2011) Workshop Information System, Control Module U Code List:
  // U0074 00 = Control Module Communication Bus B Off.
  // https://saabwisonline.com/9-4x/2011/3-electrical-system/bus-and-diagnostics-communication/fault-diagnosis-diagnostic-trouble-codes/control-module-u-code-list
  'U0074': 'Control Module Communication Bus B Off',
};

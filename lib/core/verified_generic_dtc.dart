/// Generic (SAE-range) DTC text that has been checked against a primary
/// source: codes the python-OBD table (`dtc_table.dart`, generated - never
/// hand-edited) lacks, or where it still says "Reserved".
///
/// Empty on purpose. Candidates are staged in `tool/data/staged/`
/// (dtc-database generic additions, the 41 "Reserved" replacements). An entry
/// moves here only when a reviewer has read a primary source - OEM service
/// information, a government document (e.g. an NHTSA investigation file) or
/// SAE J2012-DA - that gives the same meaning, and the source is cited in the
/// comment on the entry. See tool/data/staged/README.md.
///
/// Precedence (lib/core/dtc_text.dart): this table, then the SAE table, then
/// the Ford list. An entry here therefore replaces a stale "Reserved" SAE
/// entry, and replaces Ford-list guesses for the same code - e.g. B0001,
/// where the Ford list's most frequent meaning is "ECU internal fault" but the
/// SAE meaning is a deployment-loop fault.
const Map<String, String> verifiedGenericDtcText = {};

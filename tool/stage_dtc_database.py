#!/usr/bin/env python3
"""Stage candidate DTC text from Wal33D/dtc-database for review. NOT bundled.

    python3 tool/stage_dtc_database.py /path/to/dtc_codes.db

Reads the SQLite file read-only plus the app's two active tables
(lib/core/dtc_table.dart, lib/core/ford_dtc_table.dart) and writes:

  tool/data/staged/dtc_database_generic_additions.csv
      Generic records for codes the app's SAE table does not have, in SAE
      generic ranges only, with placeholders / code-as-text rows removed.
  tool/data/staged/reserved_replacements_review.csv
      The app's SAE entries that still say "Reserved", with the database's
      proposed text and the offline evidence for / against each one.

Nothing here is read by the app (not in pubspec assets, not imported).
Provenance of the database text is undocumented - see tool/data/staged/README.md.
"""
import csv
import hashlib
import os
import re
import sqlite3
import sys

UPSTREAM = "github.com/Wal33D/dtc-database"
UPSTREAM_COMMIT = "04c43d7"          # HEAD of main when audited (2026-11-10)
UPSTREAM_DB_SHA256 = "099a4ffd60398112a0540b0bbc93a5929e05e7f4e6d4988ca2a50858af01b743"
OUT = "tool/data/staged"

LIT = re.compile(r"'((?:[^'\\]|\\.)*)'")


def unesc(s):
    return re.sub(r"\\(.)", lambda m: {"n": "\n"}.get(m.group(1), m.group(1)), s)


def load_app():
    sae, ford = {}, {}
    for line in open("lib/core/dtc_table.dart", encoding="utf-8"):
        m = re.match(r"^  '([PCBU][0-9A-F]{4})': (.*),$", line)
        if m:
            sae[m.group(1)] = unesc(LIT.match(m.group(2)).group(1))
    for line in open("lib/core/ford_dtc_table.dart", encoding="utf-8"):
        m = re.match(r"^  '([PCBU][0-9A-F]{4})': \[(.*)\],$", line)
        if m:
            ford[m.group(1)] = [unesc(x).split("\n")[0] for x in LIT.findall(m.group(2))]
    return sae, ford


def mfr_range(code):
    """SAE J2012 manufacturer-controlled ranges."""
    if code[0] == "P":
        return code[1] == "1" or (code[1] == "3" and code[2] in "0123")
    return code[1] in "12"


def fold(s):
    return re.sub(r"[^a-z0-9]+", " ", s.lower()).strip()


def ford_agreement(desc, meanings):
    if not meanings:
        return "absent"
    if desc in meanings:
        return "identical"
    if fold(desc) in {fold(m) for m in meanings}:
        return "same apart from punctuation/case"
    return f"differs ({len(meanings)} Ford meaning{'s' if len(meanings) > 1 else ''})"


# Offline consistency check of each "Reserved" replacement against its
# already-defined neighbours in the app's SAE table. This is NOT verification.
PATTERN = {
    **{c: "consistent: continues U0073 'Control Module Communication Bus Off' "
          "(bus A) as buses B-G" for c in ["U0074", "U0075", "U0076", "U0077",
                                          "U0078", "U0079"]},
    **{c: "consistent: full 9-code block for bus F, same shape as buses A-E "
          "(U0028-U0072)" for c in [f"U00{n}" for n in range(80, 89)]},
    **{c: "ANOMALOUS: bus G gets only 3 codes (U0089-U0091), with (-) High at "
          "U0090 - every other bus has 8-9 in fixed order; numbering doubtful"
       for c in ["U0089", "U0090", "U0091"]},
    **{c: "consistent: 8-code block for bus H in the A-E order (no 'shorted' "
          "code - U0100 is taken)" for c in [f"U00{n}" for n in range(92, 100)]},
    **{c: "not checkable by pattern: module name in the 'Lost Communication "
          "With ...' series" for c in ["U0116", "U0117", "U0118", "U0119",
                                      "U0120", "U0133", "U0134", "U0135",
                                      "U0136", "U0137", "U0138", "U0139"]},
    "P0364": "ANOMALOUS: DC/AC converter text sits among camshaft / ignition "
             "codes (P0360-P0369); doubtful",
    "P0383": "consistent: follows glow plug codes P0380-P0382",
    "P0384": "consistent: follows glow plug codes P0380-P0382",
}
VERIFIED_RESERVED = {
    # Saab 9-4X (2011) WIS lists U0074 00 as Control Module Communication Bus B Off.
    "U0074": (
        "https://saabwisonline.com/9-4x/2011/3-electrical-system/bus-and-diagnostics-communication/fault-diagnosis-diagnostic-trouble-codes/control-module-u-code-list",
        "verified - Saab 9-4X WIS 2011",
        "added to verified_generic_dtc.dart",
    ),
}
PRIMARY = {
    "U": "OEM service info listing SAE U-codes (e.g. Saab/GM WIS 'Control "
         "Module U Code List'), or SAE J2012-DA",
    "P": "OEM service info for a diesel/hybrid vehicle using the code, or "
         "SAE J2012-DA",
}


def main(db_path):
    digest = hashlib.sha256(open(db_path, "rb").read()).hexdigest()
    if digest != UPSTREAM_DB_SHA256:
        print(f"warning: {db_path} sha256 {digest} differs from the audited "
              f"upstream file - update UPSTREAM_* and re-audit")
    sae, ford = load_app()
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    rows = con.execute(
        "select code, description from dtc_definitions "
        "where is_generic = 1 and locale = 'en' order by code").fetchall()
    os.makedirs(OUT, exist_ok=True)

    src = f"{UPSTREAM}@{UPSTREAM_COMMIT}"
    adds, reserved = [], []
    for code, desc in rows:
        if code in sae:
            if sae[code].startswith("Reserved"):
                reserved.append((code, desc))
            continue
        if mfr_range(code):
            continue                              # not generic by SAE J2012
        if re.fullmatch(r"[PCBU][0-9A-F]{4}", desc.strip()):
            continue                              # description is a code
        if re.search(r"(?i)manufacturer controlled dtc|iso/sae reserved", desc):
            continue                              # placeholder
        adds.append((code, desc))

    with open(f"{OUT}/dtc_database_generic_additions.csv", "w", newline="",
              encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["code", "description", "source", "source_license",
                    "provenance", "verification", "ford_list_agreement"])
        for code, desc in adds:
            w.writerow([code, desc, src, "MIT (repository)",
                        "undocumented", "unverified",
                        ford_agreement(desc, ford.get(code, []))])

    with open(f"{OUT}/reserved_replacements_review.csv", "w", newline="",
              encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["code", "current_app_text", "proposed_text", "source",
                    "ford_list_agreement", "pattern_check", "verification",
                    "primary_source_to_check", "decision"])
        for code, desc in reserved:
            evidence = VERIFIED_RESERVED.get(code)
            verification = evidence[1] if evidence else "unverified"
            primary_source = evidence[0] if evidence else PRIMARY[code[0]]
            decision = evidence[2] if evidence else "keep app text until verified"
            w.writerow([code, sae[code], desc, src,
                        ford_agreement(desc, ford.get(code, [])),
                        PATTERN.get(code, "not checked"), verification,
                        primary_source, decision])
    print(f"{len(adds)} generic additions, {len(reserved)} reserved "
          f"replacements staged in {OUT}/")
    return len(adds), len(reserved)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])

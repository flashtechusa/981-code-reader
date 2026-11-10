#!/usr/bin/env python3
"""Stage the "Porsche Diagnostic Trouble Codes" PDF (DME P-codes) for review.
NOT bundled - nothing in the app reads tool/data/staged/.

    pdftotext -layout tec_dtc_pcodes.pdf /tmp/pcodes.txt
    python3 tool/stage_porsche_pdf.py /tmp/pcodes.txt

Source PDF: "Porsche DTC P-Codes.doc" (Word export, author "Administrator",
created 2007-11-03, modified 2013-10-01). No publisher or copyright notice;
provenance undocumented. Sections: DME 5.2.2, DME 7.2, DME 7.8. The same code
often has different text in different DME versions, so every row keeps its
DME version. DME 7.8 rows carry Porsche's 3-digit fault-path number.
"""
import csv
import re
import sys

OUT = "tool/data/staged/porsche_dme_pcodes.csv"
LIT = re.compile(r"'((?:[^'\\]|\\.)*)'")


def load_sae():
    sae = {}
    for line in open("lib/core/dtc_table.dart", encoding="utf-8"):
        m = re.match(r"^  '([PCBU][0-9A-F]{4})': '((?:[^'\\]|\\.)*)',$", line)
        if m:
            sae[m.group(1)] = re.sub(r"\\(.)", r"\1", m.group(2))
    return sae


def mfr_range(code):
    return code[1] == "1" or (code[1] == "3" and code[2] in "0123")


def main(txt):
    sae = load_sae()
    recs, dme = [], None
    for raw in open(txt, encoding="utf-8"):
        s = raw.strip()
        if not s or s == "Porsche Diagnostic Trouble Codes":
            continue
        h = re.fullmatch(r"DME (\d+(?:\.\d+)+)", s)
        if h:
            dme = h.group(1)
            continue
        m = re.match(r"^(P[0-9A-F]{4})\s+(?:-\s+)?(.*)$", s)
        if m:
            text = m.group(2).strip()
            model = ""
            mm = re.match(r"^(911 Carrera)\s+(.*)$", text)
            if mm:
                model, text = mm.group(1), mm.group(2)
            fault_no = ""
            fm = re.match(r"^(\d{3})\s+(.*)$", text)
            if fm:
                fault_no, text = fm.group(1), fm.group(2)
            recs.append([dme, m.group(1), fault_no, model, text])
        elif recs:
            recs[-1][4] += " " + s           # wrapped continuation line
        else:
            sys.exit(f"unparsed line: {s!r}")
    assert all(r[0] for r in recs), "row before first DME heading"
    with open(OUT, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["dme_version", "code", "porsche_fault_no", "model_note",
                    "description", "code_range", "app_sae_text", "provenance",
                    "applies_to_981", "verification"])
        for dme, code, fno, model, text in recs:
            w.writerow([dme, code, fno, model, text,
                        "manufacturer" if mfr_range(code) else "generic",
                        sae.get(code, ""), "undocumented (2007 Word export)",
                        "unknown - 981 DME version not in this document",
                        "unverified"])
    codes = {r[1] for r in recs}
    print(f"{len(recs)} rows, {len(codes)} distinct codes, "
          f"sections {sorted({r[0] for r in recs})} -> {OUT}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])

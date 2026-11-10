#!/usr/bin/env python3
"""Regenerate lib/core/ford_dtc_table.dart from Tony's Ford DTC database.

Source: Tony's database (normalised spreadsheet, sheet "main", rows with
Record type == "diagnostic_trouble_code"). Only the DTC rows are kept in the
repo, as tool/data/ford_dtc_source.csv (columns: source_id, text_id,
description). Configuration-setting rows are deliberately NOT used - this app
does not do module coding.

    # refresh the committed CSV from a new copy of the spreadsheet, then generate
    pip install openpyxl
    python3 tool/gen_ford_dtc_table.py --from-xlsx Tony_database_cleaned.xlsx

    # regenerate from the committed CSV
    python3 tool/gen_ford_dtc_table.py

Key decoding: "source_id" is the DTC as a hex number. 2-byte keys (0x0420) are
the SAE two-byte form; 4-byte keys (0xC0130000) carry it in the top two bytes
with zero low bytes. Both give the 5-character SAE code (P0420, U0013). Keys
with non-zero low bytes (0x50123 ...) are a different, module-private
numbering and are skipped.

The same code often has several meanings (different modules / model years).
Every distinct meaning is kept, most frequent first. Placeholder rows
("Refer to the workshop manual", "Reserved" ...) are dropped.
"""
import csv
import re
import sys
from collections import OrderedDict

CSV_PATH = "tool/data/ford_dtc_source.csv"
OUT_PATH = "lib/core/ford_dtc_table.dart"

PLACEHOLDERS = {
    "refer to the workshop manual for details",
    "reserved",
    "unrecognized fault code",
    "no self diagnostic failure indicated",
    "system pass",
    "module identification",
}

ESCAPES = {"\\x96": "-", "\\x93": '"', "\\x94": '"', "\\xb5": "µ"}


def extract_csv(xlsx_path):
    import openpyxl  # only needed for this step

    wb = openpyxl.load_workbook(xlsx_path, read_only=True)
    ws = wb["main"]
    n = 0
    with open(CSV_PATH, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["source_id", "text_id", "description"])
        for i, r in enumerate(ws.iter_rows(values_only=True)):
            if i == 0 or r[0] != "diagnostic_trouble_code":
                continue
            w.writerow([r[1], r[2], r[3]])
            n += 1
    print(n, "DTC rows written to", CSV_PATH)


def sae_code(source_id):
    v = int(source_id, 16)
    if v > 0xFFFF:
        if v & 0xFFFF:
            return None  # module-private numbering
        v >>= 16
    if v == 0:
        return None
    return "PCBU"[v >> 14] + str((v >> 12) & 3) + format(v & 0xFFF, "03X")


def clean(text):
    """Return (description, [possible causes]) or None for placeholders."""
    for k, v in ESCAPES.items():
        text = text.replace(k, v)
    causes = []
    if "--Possible Causes--" in text:
        text, rest = text.split("--Possible Causes--", 1)
        for c in rest.split("|"):
            c = re.sub(r"\s+", " ", c).strip(" \t-.")
            if c:
                causes.append(c[0].upper() + c[1:])
    desc = re.sub(r"%[sxd]\s*-?\s*", "", text)
    desc = re.sub(r"\s+", " ", desc).strip(" .")
    if len(desc) < 3 or desc.lower() in PLACEHOLDERS:
        return None
    if desc[0].islower():
        desc = desc[0].upper() + desc[1:]
    return desc, causes


def dart_str(s):
    s = s.replace("\\", "\\\\").replace("'", "\\'").replace("$", "\\$")
    return "'" + s.replace("\n", "\\n") + "'"


def generate():
    # code -> fold(desc) -> {"count", "forms": {form: count}, "causes": [...], "first"}
    table = {}
    order = 0
    rows = skipped = 0
    with open(CSV_PATH, newline="", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            rows += 1
            code = sae_code(r["source_id"])
            c = clean(r["description"] or "") if code else None
            if c is None:
                skipped += 1
                continue
            desc, causes = c
            fold = re.sub(r"[^a-z0-9]+", " ", desc.lower()).strip()
            e = table.setdefault(code, OrderedDict()).get(fold)
            if e is None:
                order += 1
                e = {"count": 0, "forms": {}, "causes": [], "first": order}
                table[code][fold] = e
            e["count"] += 1
            e["forms"][desc] = e["forms"].get(desc, 0) + 1
            if causes and not e["causes"]:
                e["causes"] = causes

    out = [
        "// GENERATED from Tony's Ford DTC database (tool/data/ford_dtc_source.csv)",
        "// by tool/gen_ford_dtc_table.py. Do not edit by hand; regenerate.",
        "//",
        "// Ford / Lincoln / Mercury / Mazda meanings keyed by 5-character SAE code.",
        "// A code can mean different things in different modules, so each entry",
        "// lists every distinct meaning, most frequent first. Only shown for",
        "// Ford-family vehicles - see lib/core/dtc_text.dart.",
        "",
        "const Map<String, List<String>> fordDtcText = {",
    ]
    meanings = 0
    for code in sorted(table):
        entries = sorted(table[code].values(),
                         key=lambda e: (-e["count"], e["first"]))
        texts = []
        for e in entries:
            form = sorted(e["forms"].items(), key=lambda kv: (-kv[1], kv[0]))[0][0]
            if e["causes"]:
                form += "\nPossible causes: " + "; ".join(e["causes"])
            texts.append(form)
        meanings += len(texts)
        out.append(f"  '{code}': [{', '.join(dart_str(t) for t in texts)}],")
    out.append("};")
    with open(OUT_PATH, "w", encoding="utf-8") as f:
        f.write("\n".join(out) + "\n")
    print(f"{rows} rows read, {skipped} skipped, {len(table)} codes, "
          f"{meanings} meanings written to {OUT_PATH}")


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--from-xlsx":
        extract_csv(sys.argv[2])
    elif len(sys.argv) != 1:
        sys.exit(__doc__)
    generate()

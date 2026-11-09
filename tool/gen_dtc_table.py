#!/usr/bin/env python3
"""Regenerate lib/core/dtc_table.dart from python-OBD's SAE J2012 table.
    pip install obd && python3 tool/gen_dtc_table.py
"""
import obd.codes as c
d = c.DTC
out = ["// GENERATED from python-OBD (obd/codes.py), SAE J2012 generic DTC text.",
       "// Manufacturer-specific codes (P1xxx, P30xx-P33xx, most B/C/U) are not here.",
       "// Do not edit by hand; regenerate with tool/gen_dtc_table.py.", "",
       "const Map<String, String> saeDtcText = {"]
for k in sorted(d):
    v = d[k].replace("\\", "\\\\").replace("'", r"\'").replace("$", r"\$")
    out.append(f"  '{k}': '{v}',")
out.append("};")
open("lib/core/dtc_table.dart", "w").write("\n".join(out) + "\n")
print(len(d), "codes written")

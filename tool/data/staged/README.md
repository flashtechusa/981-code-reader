# Staged DTC text - NOT bundled

Nothing in this folder is read by the app: it is not in `pubspec.yaml` assets
and no Dart file imports it. These are candidates waiting for review. The app's
active tables are unchanged: `lib/core/dtc_table.dart` (2,066 SAE codes),
`lib/core/ford_dtc_table.dart` (Tony's Ford list) and
`lib/core/verified_generic_dtc.dart` (verified generic additions; empty until
an entry passes the bar below).

## Files

| File | Rows | Source | Regenerate |
|---|---|---|---|
| `dtc_database_generic_additions.csv` | 7,275 | Wal33D/dtc-database @ 04c43d7, `dtc_codes.db` sha256 `099a4ffd…b743` | `python3 tool/stage_dtc_database.py dtc_codes.db` |
| `reserved_replacements_review.csv` | 41 | same | same |
| `porsche_dme_pcodes.csv` | 647 (364 codes) | "Porsche DTC P-Codes.doc" PDF export (2007/2013) | `pdftotext -layout tec_dtc_pcodes.pdf x.txt && python3 tool/stage_porsche_pdf.py x.txt` |

## Why these are not bundled

**dtc-database provenance is undocumented.** The repository is MIT licensed
(© 2024 Wal33D / Waleed Judah), but the licence covers the repository; nothing
says where the descriptions came from. All 37 source files arrived complete in
the first commit (ea1a05c, 2025-09-21) with no attribution. An early README
said "Database compiled from various public sources and manufacturer
documentation" and thanked "SAE International for J2012 standard"; neither the
sources nor the documentation are named, and that sentence was later removed.
The generic text follows SAE J2012, a paid, copyrighted standard. Its generic
text matches Tony's list word for word (or apart from punctuation) for 6,980 of
the 7,275 staged codes, which suggests a shared upstream origin rather than
independent confirmation.

**The Porsche PDF has no publisher.** Word export, author "Administrator", no
copyright or source line. It covers DME 5.2.2, 7.2 and 7.8 only (986/996 and
987/997 era) - not the 981's DME - and gives different text for the same code
in different DME versions (178 of 364 codes), so it can only ever apply keyed
by DME version, which the app would read from the module's identification.

## Bar for moving an entry into the app

1. A primary source the reviewer has actually read (OEM service information,
   a government document such as an NHTSA investigation file, or SAE J2012-DA)
   gives the same meaning for the same code.
2. The source is recorded next to the entry in `verified_generic_dtc.dart`.
3. For the "Reserved" replacements: `pattern_check` must not say ANOMALOUS
   unless the primary source settles it.

Candidate primary sources found but not reachable from the build session (its
network blocks these hosts): NHTSA PE21-010 appendix (`static.nhtsa.gov`,
lists Ford RCM B0001 "Driver Frontal Stage 1 Deployment Control"), Saab/GM WIS
"Control Module U Code List" (`saabwisonline.com`).

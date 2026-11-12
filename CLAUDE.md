# Boxster SRS - notes for Claude Code sessions

Flutter iOS app (iOS 15+, iPhone portrait, Android later) that talks to a bbfly
Wi-Fi ELM327 clone at `192.168.0.10:35000` (raw TCP, CR-terminated AT commands,
`>` prompt) on a Porsche 981: ISO 15765-4 CAN 500k, 11-bit and 29-bit
(`0x18DAxxF1` normal-fixed). Reference implementation: `tool/reference/porsche981_srs.py`
- the Dart in `lib/core/` is a line-for-line port and must stay behaviourally identical.

## SAFETY RULES - do not relax these

1. **One transmit choke point.** Every CAN payload goes through `Uds.request()` in
   `lib/core/uds.dart`. Never add another call to `Elm327.sendFramesAndCollect`
   or `Elm327.cmd` with a hex payload outside that method.
2. **Allow-list only**: `0x01` (only when target is `0x7E0`, 11-bit), `0x10`,
   `0x14`, `0x19`, `0x22`, `0x3E`. Session sub-function only `0x01` / `0x03`.
3. **Never** `0x27` SecurityAccess, `0x2E` WriteDataByIdentifier, `0x31`
   RoutineControl, `0x11` ECUReset, `0x34`-`0x38` download/upload,
   `0x10 0x02` programming session. If a module answers NRC `0x33`, report it;
   do not try to satisfy it.
4. **ClearDiagnosticInformation (0x14)** is refused on `0x7DF`, `0x700` (the
   VW/Porsche broadcast id - 11 modules answered one TesterPresent there on
   the 981) and `0x18DB33F1` always (`broadcast11`), and on any id the scan
   saw answered by more than one module (`Uds.learnedBroadcast`; the scanner
   never makes a module of such an id, `Session._clear` refuses ids shared by
   several modules). Powertrain ids (`0x7E0-0x7E7`, 29-bit targets `0x10`/`0x18`) are
   refused unless `allowPowertrainClear: true`, which ONLY the per-module
   "Clear codes" button passes (`Session.clearModuleCodes`). The Clear SRS tile
   (`Session.clearSrs`) always passes `false`.
5. Clear SRS is enabled only when exactly one module is flagged airbag
   (`looksLikeAirbag`). Every clear needs the typed `CLEAR` confirmation sheet.
6. **Airbag coding / variant coding / crash-data reset is a PIWIS job.** This
   app only reads and clears.
7. Tests in `test/core_test.dart` assert the refusals. Keep them passing.

## Protocol facts to preserve

* Adapter init verbatim: `ATZ` (wait 0.5 s), `ATE0 ATL0 ATS1 ATH1 ATCAF0 ATCFC1
  ATAT0 ATAL`, then `ATI`, `ATRV`. Battery warning < 12.0 V.
* `ATCAF0` -> raw frames with PCI bytes; we reassemble ISO-TP in
  `Elm327.parseFrames` (SF/FF/CF per CAN id). The bbfly does NOT send ISO-TP
  flow control in CAF0 (981 log: only First Frames arrived), so
  `sendFramesAndCollect` sends `30 00 14` itself when exactly one physical
  target sent only its First Frame (transport frame, no service byte, inside
  the choke point). Still incomplete -> `ElmException` -> `UdsException`; a
  failed read shows "codes not read", never "no DTCs stored". Header is 3 hex chars (11-bit) or
  8 (29-bit) after removing spaces. Requests are single-frame, padded to 8 bytes.
* Addressing (`Elm327.setTarget`): 11-bit `ATSH` + `ATCRA req+8` or wide
  `ATCF700/ATCM700`; 29-bit `ATCP`/`ATSH` + `ATCRA 18DAF1xx` or wide
  `ATCF 18DAF100 / ATCM 1FFFFF00`. `ATST` = ms/4 hex, max `0xFF`.
* Scan starts by reading the VIN: `Scanner.readVin()` = UDS `22 F190` to
  `0x7E0`, then Ford BCM `0x726` and IPC `0x720` (read-only, already on the
  allow-list - Mode 09 stays off the CAN allow-list). A cut-short answer is
  re-read with `Elm327.setAutoFormatting(true)` (ATCAF1 for that one read:
  the adapter does flow control in time for ~75 ms ISO 15765-4 timers that a
  phone-side FC over Wi-Fi misses; bare payload in, same CAN frame; always
  switched back to ATCAF0). Every failed attempt and its reason goes to the
  scan output. No VIN + the 11-bit modules answer the Ford way (>= 2 known
  Ford addresses, all responses at req + 8) -> 29-bit sweep skipped unless
  "Full address sweep" is on. While scanning, CONNECT becomes STOP
  (`Session.stopScan`, keeps the connection and what was found); the MS-CAN
  offer only follows a finished scan on a live connection. `lib/core/vin.dart` decodes make (WMI) and model year (10th
  char) offline; the model is not decoded (needs an online VIN database).
  Ford / Lincoln / Mercury VIN and Settings "Full address sweep" off ->
  targeted scan: only `Scanner.fordAddresses(bus)` (known-address table,
  Ford + OBD-II entries), each with TesterPresent then the `10 01`/`3E 00`
  second chance, no 29-bit sweep; MS-CAN likewise. Any other make (Porsche,
  Mazda, Maserati), no VIN, or the setting on -> full sweep below.
* Full sweep: probe TesterPresent at 100 ms adapter timeout (Python used 60), 11-bit `0x700-0x7FF`
  minus `0x7DF`, `0x7E8-0x7EF` and (unless toggled) `0x7E0-0x7E7`; then 29-bit
  TA `0x00-0xFF`. Identify + ReadDTC each responder at 400 ms.
* `Elm327.setTarget` does not re-send addressing the adapter already holds
  (ATSH / ATCP / ATCF+ATCM / ATCRA cached; cleared by `init`, `setBits`,
  `setBus`, legacy enter/leave). Only adapter configuration is skipped - the
  CAN frames are identical to the Python reference. Halves each probe
  (~0.27 s -> ~0.17 s on the bbfly).
* ReadDTC `19 02 FF` -> `[dtc(3) status(1)]*`; SAE form via `dtcToSae`,
  status bit names via `statusBits`. Generic SAE J2012 text comes from
  `lib/core/dtc_table.dart` (GENERATED by `tool/gen_dtc_table.py` from
  python-OBD; regenerate, never hand-edit). Ford / Lincoln / Mercury
  manufacturer-code text comes from Tony's database: `lib/core/ford_dtc_table.dart`
  (GENERATED by `tool/gen_ford_dtc_table.py` from `tool/data/ford_dtc_source.csv`;
  regenerate, never hand-edit). Primary-source-verified generic additions go
  in `lib/core/verified_generic_dtc.dart` (hand-maintained, each entry cites
  its source; empty until one passes review).
  `describeDtcCode` in `lib/core/dtc_text.dart` - precedence: verified
  generic, then SAE table, then Ford list (never mixed). `fordTextLevel`:
  Ford/Lincoln/Mercury VIN = confirmed; Mazda VIN or MS-CAN with no VIN =
  unconfirmed (shown only as "not confirmed for this make", never as THE
  meaning - Mazda disagreed with the Ford list on 69 of 233 codes in an
  audit); Porsche/Maserati VIN = off. For SAE-generic-range codes
  (`isManufacturerRange` false, e.g. B0001) Ford text is never definitive
  when it has several meanings - the app shows "N possible meanings", never
  silently the most frequent one. Text is display only - it never affects
  airbag flagging or what is sent.
* Candidate code text waiting for review lives in `tool/data/staged/`
  (dtc-database generic additions, "Reserved" replacements, Porsche DME
  P-code PDF). NOT bundled - see its README for why and the bar for moving an
  entry into the app.
* Identification DIDs: VW/Porsche F187/F191/F197/F189/F19E plus standard/Ford
  F190 (VIN), F111 (core part), F188 (sw part), F18C (serial). Modules that
  answer none are labelled from `lib/core/known_modules.dart` (Ford HS-CAN /
  VW address conventions) and the UI says "by address".
* Airbag recognition (`looksLikeAirbag` + `Module.isAirbag`): text keywords
  AIRBAG/POSIP/SRS/RESTRAINT, whole-word RCM/SDM/ORC/ACU, Porsche 9xx.618 and
  Ford 14B321 part numbers, fresh B-codes; OR a known airbag address (0x737
  Ford, 0x715 VW) when the module gave no system name. A module at a KNOWN
  non-airbag address (Ford APIM/BCM/...) can only be flagged by identification
  text - never by the active-B-code fallback (SYNC throws B-codes). Clear SRS
  still needs exactly one flagged module and the typed CLEAR.
* DTC display: `Dtc.isActive` = status & 0x0F != 0. Errors screen hides
  inactive (0x50 "test not completed") entries by default with a toggle; Ford
  modules list every supportable DTC that way.
* Two CAN buses (`CanBus` in module.dart): HS = pins 6/14 500k (ATSP6/7);
  MS = Ford's pins 3/11 125k = ELM protocol B (`ATPB E0 04`, `ATSPB`), 11-bit
  only. The ELM reaches MS only via the adapter's physical switch, so
  `Session.adapterBus` tracks the user-confirmed switch position, the home
  screen offers an MS scan after the HS scan (`Settings.hasMsSwitch`), and
  every per-module action goes through `ensureBusFor()` first. Live data and
  Clear SRS are HS-only.
* Scan second pass: known-address table re-probed with `10 01` then `3E 00`
  at 250 ms (Ford ABS/RCM/IPC/PSCM often ignore a bare TesterPresent).
* Clear sequence (`lib/core/clear.dart`): `10 03` (fall back on refusal),
  TesterPresent, `ATST FF`, `14 FF FF FF`, on `0x78` poll with `3E 00` up to 5x,
  verify `0x54`, re-read DTCs, flag any `testFailed`, `10 01`.
* Mode 01 PIDs: `0C 0D 05 0F 04 06 07 08 09 11 42`, SAE J1979 formulas in
  `lib/core/obd_pids.dart`.

## Build / tooling

* Platform folders are generated, not committed: `flutter create --org
  com.flashtech --project-name boxster_srs --platforms=ios,android .` then
  `bash tool/patch_ios.sh`. Committed `ios/Runner/Info.plist` already has
  `NSLocalNetworkUsageDescription`, `UIRequiresPersistentWiFi`, portrait only.
* Bundle id `com.flashtech.boxstersrs`. Codemagic: `codemagic.yaml`
  (`test-only` on push, `ios-testflight` on `v*` tags or started manually, App
  Store Connect integration named "ColorChase", script-based signing via
  `app-store-connect fetch-signing-files --create` using the secret
  `CERTIFICATE_PRIVATE_KEY` from env group `code-signing`; nothing committed).
* Simulator: `flutter run --dart-define=MOCK=true` (scripted adapter in
  `lib/core/mock_adapter.dart`).
* Keep Dart conservative: Flutter 3.x stable, Dart 3, null-safe, no
  experimental APIs. State is `ChangeNotifier` + `provider`; do not add a
  bigger state framework.
* `flutter analyze` and `flutter test` must stay green (warnings are fatal; infos such as `prefer_const_constructors` are not).

## Legacy OBD-II (K-line) mode

Settings "Vehicle bus: K-line legacy" is for pre-CAN cars (2004 Maserati 4200).
`Elm327.enterLegacy()` -> `ATSP0 ATCAF1 ATH0 ATAT1` (formatted output, headers
stripped). `Uds.request()` then applies `legacyAllowedSids` = {01, 03, 04, 07,
09} ONLY and refuses every UDS service; Mode 04 needs `allowObdClear: true`,
set only by `Session._legacyClear` after the typed CLEAR. `LegacyObd`
(`lib/core/legacy_obd.dart`) synthesises one `Module` for the engine ECU
(2-byte DTCs become `[a, b, 0x00]` with status 0x09 stored / 0x04 pending).
Other modules on these cars (gearbox, ABS, airbag, NCR) are on separate
K-lines with proprietary protocols - out of scope, do not guess at them.

## Units

ECU values are decoded in SI (km/h, °C) and stay SI everywhere in `lib/core/`
and in tests. Display conversion happens only in the UI via
`Settings.units` (`lib/core/units.dart`): default is US (mph, °F); Metric is
selectable in the settings sheet. Never convert inside `obd_pids.dart`.

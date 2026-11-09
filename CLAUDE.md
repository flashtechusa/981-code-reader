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
4. **ClearDiagnosticInformation (0x14)** is refused on `0x7DF` and `0x18DB33F1`
   always. Powertrain ids (`0x7E0-0x7E7`, 29-bit targets `0x10`/`0x18`) are
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
  `Elm327.parseFrames` (SF/FF/CF per CAN id). Header is 3 hex chars (11-bit) or
  8 (29-bit) after removing spaces. Requests are single-frame, padded to 8 bytes.
* Addressing (`Elm327.setTarget`): 11-bit `ATSH` + `ATCRA req+8` or wide
  `ATCF700/ATCM700`; 29-bit `ATCP`/`ATSH` + `ATCRA 18DAF1xx` or wide
  `ATCF 18DAF100 / ATCM 1FFFFF00`. `ATST` = ms/4 hex, max `0xFF`.
* Scan: probe TesterPresent at 60 ms adapter timeout, 11-bit `0x700-0x7FF`
  minus `0x7DF`, `0x7E8-0x7EF` and (unless toggled) `0x7E0-0x7E7`; then 29-bit
  TA `0x00-0xFF`. Identify + ReadDTC each responder at 400 ms.
* ReadDTC `19 02 FF` -> `[dtc(3) status(1)]*`; SAE form via `dtcToSae`,
  status bit names via `statusBits`.
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
  (`test-only` on push, `ios-testflight` on `v*` tags, App Store Connect
  integration named "App Store Connect", automatic signing, nothing committed).
* Simulator: `flutter run --dart-define=MOCK=true` (scripted adapter in
  `lib/core/mock_adapter.dart`).
* Keep Dart conservative: Flutter 3.x stable, Dart 3, null-safe, no
  experimental APIs. State is `ChangeNotifier` + `provider`; do not add a
  bigger state framework.
* `flutter analyze` and `flutter test` must stay green (warnings are fatal; infos such as `prefer_const_constructors` are not).

# Boxster SRS

Flutter iOS app that reads and clears airbag (POSIP) fault codes on a Porsche 981
through a Wi-Fi ELM327 clone (bbfly, `192.168.0.10:35000`), shows OBD-II live data
from the DME, and keeps a raw AT/CAN transcript. It is a port of
`tool/reference/porsche981_srs.py` with the same safety allow-list: the app can
only ever transmit UDS `0x10` (default/extended session), `0x14`, `0x19`, `0x22`,
`0x3E` and OBD Mode `0x01` (DME only). No SecurityAccess, no writes, no routines,
no resets, no programming session - airbag coding is a PIWIS job.

## On-car use

1. Slide the switch on the bbfly adapter to **HS-CAN** and plug it into the OBD port.
2. **Ignition ON, engine OFF**, car parked. Battery above 12.0 V (put a charger on
   it if in doubt - low voltage causes NRC 0x22 and phantom SRS faults).
3. On the iPhone join the adapter's Wi-Fi, usually **`WiFi_OBDII`** (no password or
   the one printed on the dongle). When iOS warns there is no internet tap
   **Keep Trying Wi-Fi**. Turn **cellular data off** temporarily, otherwise iOS may
   route the socket out through LTE and the connect times out.
4. Open Boxster SRS, tap **CONNECT**. Allow the **Local Network** prompt the first
   time. The status line shows the adapter ID and battery voltage when connected.
5. **Vehicle** - scans 11-bit `0x700-0x7FF` (skipping `0x7DF`, `0x7E8-0x7EF` and,
   unless enabled in Settings, the powertrain range `0x7E0-0x7E7`) then 29-bit
   `18DAxxF1` for `xx = 00..FF`. Each responder is identified (DIDs F187, F191,
   F197, F189, F19E) and its DTCs read. The airbag module gets an
   **AIRBAG / POSIP** badge.
6. **Errors** - re-reads DTCs for every module, grouped per module. Tap a DTC for
   the `19 04` snapshot and `19 06` extended data hex. Each module card has a
   **Clear codes** button (typed `CLEAR` confirmation, `14 FF FF FF` to that module
   only, then re-read).
7. **Clear SRS** - enabled only when exactly one module is flagged as the airbag
   unit. Type `CLEAR`. The app tries `10 03`, falls back to the default session if
   refused, sends TesterPresent, `14 FF FF FF`, waits out `0x78` pending, verifies
   `0x54`, re-reads DTCs and tells you whether any fault is still `testFailed`.
   **If the seat airbag plug is still disconnected the lamp returns immediately** -
   clearing does not fix the circuit.
8. **Dashboard** - Mode 01 live data from the DME (`0x7E0/0x7E8`): gauges, table
   (toggle PIDs) and a scrolling graph. Polls at roughly 5 Hz.
9. **Log** (top-right icon) - every AT/CAN exchange; share as `.txt`.
10. **DISCONNECT** sends `ATPC` and closes the socket. The screen stays awake while
    connected.

Settings (gear icon, only while disconnected): adapter host, port and the
"include powertrain in scan" toggle. Persisted on the device.

## Simulator / no-car run

```sh
flutter run --dart-define=MOCK=true
```

The scripted adapter (`lib/core/mock_adapter.dart`) fakes an airbag module at
`0x715/0x77F` with two B-codes (one returns after the first clear, exactly like an
unplugged squib), a module at `0x7A5`, a 29-bit module at `18DA40F1` and a DME at
`0x7E0` with wobbling live data. The home screen shows a `MOCK` tag.

## Project layout

```
lib/core/      protocol layer, no Flutter imports
  transport.dart    Transport abstraction, TcpTransport (dart:io), MockTransport
  elm327.dart       ELM327 cmd(), init, addressing (setTarget), ISO-TP parseFrames
  uds.dart          Uds.request() choke point + allow-list, DTC decode, NRC table, identify
  scanner.dart      11-bit + 29-bit discovery with a progress Stream
  clear.dart        clearModule(): 10 03 -> 3E -> 14 FF FF FF -> 0x78 handling -> re-read
  obd_pids.dart     SAE J1979 Mode 01 PID table + decode, ObdLive reader
  mock_adapter.dart scripted bbfly for the simulator
lib/app/       Settings (shared_preferences) and Session (ChangeNotifier)
lib/ui/        home grid, vehicle, errors, dashboard, log, settings, sheets
test/core_test.dart  ported fake-adapter test + ISO-TP, PID, allow-list tests
tool/patch_ios.sh    applies Info.plist / bundle id / iOS 15 after flutter create
tool/reference/      the original Python tool, for provenance
```

## Building

This repo was authored without a Flutter SDK available, so the platform folders
are not committed (only `ios/Runner/Info.plist`). First step locally or in CI:

```sh
flutter create --org com.flashtech --project-name boxster_srs --platforms=ios,android .
bash tool/patch_ios.sh        # bundle id com.flashtech.boxstersrs, iOS 15.0, plist keys
flutter pub get
flutter analyze
flutter test
flutter run --dart-define=MOCK=true
```

`flutter create .` never overwrites existing files, so the committed
`Info.plist`, `pubspec.yaml`, `lib/` and `test/` are kept.

### Info.plist additions (already in `ios/Runner/Info.plist`)

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Boxster SRS talks to your OBD-II Wi-Fi adapter.</string>
<key>UIRequiresPersistentWiFi</key>
<true/>
<key>UISupportedInterfaceOrientations</key>
<array>
	<string>UIInterfaceOrientationPortrait</string>
</array>
```

## Codemagic

`codemagic.yaml` has two workflows:

* **test-only** - on every push / PR: `flutter pub get`, `flutter analyze`,
  `flutter test`.
* **ios-testflight** - on tags `v*`: generates the platform folders, patches iOS,
  analyze + test, automatic signing through the Codemagic App Store Connect
  integration named **"App Store Connect"** (distribution type `app_store`, bundle
  id `com.flashtech.boxstersrs`), `flutter build ipa --release`, upload to
  TestFlight. No certificates or profiles are committed.

Setup once in Codemagic: add the App Store Connect API key integration with that
exact name, and make sure the bundle id exists in the Apple Developer portal (the
`--create` flag in the signing step registers the profile if missing).

## Safety

See `CLAUDE.md`. Short version: one transmit path (`Uds.request`), fixed allow-list,
`0x14` never to `0x7DF` / `0x18DB33F1`, powertrain clear only from the per-module
button, Clear SRS only when exactly one module is flagged airbag, typed `CLEAR`
every time.

# EV6 Precondition: iPhone handover pack

Start with **HANDOVER.md**. Then use **FUNCTIONS.md** while porting, and **TESTS.md** to check your work.

```
HANDOVER.md        What the app does, the Kia Connect API (endpoints, headers, payloads, errors),
                   rule semantics, the engine's failure policy, iOS equivalents, screens,
                   milestones, open questions
FUNCTIONS.md       Every type and function in the shared logic: behaviour, edge cases,
                   Swift shape, priority (P1–P4 / skip)
TESTS.md           All 195 Android unit tests by file, marked port or skip
PreconditionKit/   The iOS app's Swift core: Kia client, budget, engine, stores, view model (swift test)
EV6Precondition/   The iOS app: SwiftUI screens, Keychain, notifications
project.yml        XcodeGen spec for the Xcode project
codemagic.yaml     Codemagic workflows: tests + simulator build, and TestFlight
fixtures/          rules-backup.json (import/export compatibility with the Android app),
                   Kia responses: vehicles, status (older protocol and CCS2), location/park,
                   token, device registration, PIN control token, climate payloads, errors;
                   Open-Meteo sample
screenshots/       The Android EV6 app's screens (light and dark)
reference-source/  The Android app's platform-free Kotlin core (rules/, engine/, weather/, api/, api/kia/),
                   its tests, and the Kia-specific Android files (android-kia/)
```

About the source:
- The Škoda files in `reference-source/api/` (`SkodaClient`, `SkodaApiService`, `ApiModels`, `VehicleMapper`, the HTTP part of `FakeCar`) are there only because shared types live next to them. They aren't needed for the Kia app.
- No credentials are included. The Kia IDs in `KiaConfig.kt` are the Kia app's public constants, as published in the open-source hyundai_kia_connect_api project.
- The full Android project is on GitHub at `Nikolai828/Skoda-Automation` (ask Nick for access).

## Building the iPhone app

The Xcode project is generated from `project.yml` by [XcodeGen](https://github.com/yonaskolb/XcodeGen), so it isn't committed.

- **Codemagic:** the `ios-ci` workflow runs on every push: PreconditionKit's tests, then an unsigned simulator build. `ios-testflight` builds a signed app and uploads it to TestFlight. The App Store Connect app (Apple ID 6817129603, bundle ID `com.luciusgee.ev6precondition`) and the `shopfair-asc-key` integration are already set.
- **On a Mac:** `brew install xcodegen && xcodegen generate`, then open `EV6Precondition.xcodeproj`.
- **Core logic only (any OS):** `swift test --package-path PreconditionKit`.

## What the app does

- **Dashboard:** a drawn 2022 EV6 GT-Line in your paint colour (charge port pulses while charging, the cabin glows while climate runs), charge and range, and control tiles for climate, locks, charging and charge limits. Vehicle health: odometer, 12 V battery, tyres, doors and windows, alerts.
- **Keep charger off:** when the car is plugged in but not charging (done, or waiting for off-peak), starting climate stops the charger first, so preconditioning never starts a peak-rate charge. Manual starts, rules and Siri all do this. A charge that's already running is left alone.
- **Climate extras:** windscreen defrost, heated wheel and mirrors.
- **Energy:** 30 days of the car's driving history (driving, climate, electronics, battery care, regen) in charts; mi/kWh or kWh/100 km.
- **Scanner tab (OBD, like Car Scanner):** dashboard gauges, live graphs with CSV recording, 50+ EV6 sensors, trouble codes from every module (meanings, freeze frame, clearing), modules and VIN, 0–60 / 0–100 / 50–70 / ¼-mile timing, trip computer. Connect remembers your adapter; Demo runs it all against a simulated EV6.
- **Battery Health (OBD):** with a Bluetooth LE or Wi-Fi ELM327 adapter: state of health, all 192 cell voltages and their spread, temperatures, lifetime energy, tyre pressures. Read-only. Works with the simulated adapter in fake-car mode.
- **Rules:** templates, the editor, Test now, and ✨ *Describe a rule*: plain English turned into a rule on the phone (Apple Intelligence rewords loose requests on iOS 26 devices that support it). Suggestions learned from your habits, e.g. "you start climate around 07:28 on weekdays".
- **Places:** a MapKit editor; leave/arrive rules run from iOS region monitoring, even with the app closed.
- **Siri and Shortcuts:** precondition (optionally at a temperature), check my EV6, lock/unlock, start/stop charging, set charge limit, stop climate, run scheduled rules.
- Activity log by day, fake-car mode for everything, no backend or analytics.

Not yet run against a real Kia account. Widgets and Control Center buttons need an App Group and a second App ID in the Apple Developer account first.

To ship: `git push origin main:release` builds and uploads to TestFlight. A GitHub Actions job also builds the app on macOS for every push, with readable compiler logs.

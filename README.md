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

- **Codemagic:** the `ios-ci` workflow runs on every push: PreconditionKit's tests, then an unsigned simulator build. `ios-testflight` builds a signed app and uploads it to TestFlight. Set `APP_STORE_APPLE_ID` in `codemagic.yaml` first (the app's Apple ID), and register the bundle ID `com.luciusgee.ev6precondition` (or change it in `project.yml` and `codemagic.yaml`).
- **On a Mac:** `brew install xcodegen && xcodegen generate`, then open `EV6Precondition.xcodeproj`.
- **Core logic only (any OS):** `swift test --package-path PreconditionKit`.

Status: milestone 1 (HANDOVER.md §7). Settings (token, PIN and VIN in the Keychain), the dashboard with manual Refresh/Start/Stop, the Activity log and fake-car mode. Not yet run against a real Kia account.

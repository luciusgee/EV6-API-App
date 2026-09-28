# EV6 Precondition: iPhone handover pack

Start with **HANDOVER.md**. Then use **FUNCTIONS.md** while porting, and **TESTS.md** to check your work.

```
HANDOVER.md        What the app does, the Kia Connect API (endpoints, headers, payloads, errors),
                   rule semantics, the engine's failure policy, iOS equivalents, screens,
                   milestones, open questions
FUNCTIONS.md       Every type and function in the shared logic: behaviour, edge cases,
                   Swift shape, priority (P1–P4 / skip)
TESTS.md           All 195 Android unit tests by file, marked port or skip
PreconditionKit/   The iOS app's Swift core, in progress (milestone 1: Kia client, budget, fake car); run swift test
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

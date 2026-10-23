# The Kia Connect app, archived

In October 2026 the app was refocused on being an OBD scanner for the EV6. Everything it did
through Kia Connect was taken out. This file says what that version did and where the code is,
so any of it can be brought back.

## Getting it back

- **Branch `archive/kia-connect-full`** (commit `3abf4a3`) is the complete app as it was: builds,
  tests and all. `git checkout archive/kia-connect-full` to look around, or
  `git checkout archive/kia-connect-full -- <path>` to bring a file back into `main`.
- The last TestFlight build of it was from that commit (guide release 16).
- `HANDOVER.md`, `FUNCTIONS.md` and `TESTS.md` describe the Android app it was ported from.

## What it did

**Car (Kia Connect, EU API, legacy cars with ccs2=0)**
- Read the car: cached status, or a forced read that wakes the car. Charge, range, plug, locks,
  climate, windows, tyres, 12 V, odometer, location.
- Commands: climate on/off (17–27 °C, defrost, heated wheel and mirrors), lock/unlock, start/stop
  charging, AC/DC charge limits, the car's off-peak window, sending destinations to the sat nav.
  Each command was confirmed from Kia's command list, or by reading the car when Kia didn't list it.
- Rate budget, so the 12 V and Kia's daily limit were never overused.
- `PreconditionKit/Sources/PreconditionKit/Kia/` (KiaClient, KiaMapper, KiaAccountLogin, FakeKia),
  `Engine/` (PreconditionEngine, CarCommands, Automation, VehicleRepository, RateBudget),
  `App/CarModel.swift`, `EV6Precondition/Views/CarView.swift`, `OffPeakView.swift`.

**Rules (automatic climate)**
- Triggers: a time on chosen days (through a Shortcuts automation), leaving or arriving at a
  place (geofences), approaching a place, walking up to the car.
- Conditions: temperature (forecast or now, Open-Meteo), plugged in, charge, place, phone near car.
- "Ask first" notifications (Start / In 15 min / Not today), per-rule heated extras.
- A four-step rule maker and a full editor, templates, suggestions from habits, import/export.
- `Rules/`, `Model/RuleAction.swift`, `Model/Places.swift`, `App/RulesModel.swift`,
  `Views/RuleBuilderView.swift`, `RuleEditorView.swift`, `RulesView.swift`, `PlacesView.swift`,
  `Platform/Geofencing.swift`, `AskCoordinator.swift`.

**Charging and costs**
- A charge ledger from readings, costed with the home tariff (cheapest half hours) or public rate;
  cost per mile vs petrol; smart charging (cheapest window to a target by a time).
- Alerts: plugged in, charging stopped, charge complete, low charge, left unlocked, windows, 12 V,
  tyres, not charging in the off-peak window, a 20:00 evening check with the expected charge.
- Off-peak estimate ("about 72% by 6:00 am"), Octopus Agile support (hidden).
- `Charging/` (ChargeLedger, Tariff, SmartCharging, Alerts, OffPeakForecast, Octopus),
  `App/ChargingModel.swift`, `Views/ChargingView.swift`, `AlertsSettingsView.swift`,
  `Platform/ChargingCoordinator.swift`, `LocalNotifier.swift`.

**Trips**
- Route planner: several places with stays, there and back, alternative routes to choose from,
  chargers along the way (Apple Maps, OpenStreetMap power and counts), charge stops planned on
  the EV6 charge curve, food chains at each stop, services on the main road, saved trips,
  send to the car's sat nav, Google Maps link.
- Commutes: routes from Google Maps links, traffic on each (Apple Maps), favourite with
  tolerance, ETA message (Messages/WhatsApp), quick check from where you are, checks on leaving
  or at a set time, the way back.
- Traffic ahead, time at places (from the car's trip log), chargers nearby.
- `Route/`, `Commute/`, `App/TripsModel.swift`, `App/CommuteModel.swift`, `App/PresenceModel.swift`,
  `Views/TripsView.swift`, `RoutePlannerView.swift`, `FoodViews.swift`, `CommuteView.swift`,
  `TrafficAheadView.swift`, `TimeAtPlacesView.swift`, `ChargersView.swift`, `ChargeSiteView.swift`,
  `Platform/RouteService.swift`, `FoodFinder.swift`, `AppleDriveTimer.swift`, `CommuteCoordinator.swift`.

**Around the edges**
- Widgets, Control Centre controls, Live Activities (climate and charging), Watch app and
  complications: `Widgets/`, `Watch/`, `WatchWidgets/`, `Shared/`, `Platform/GlanceSync.swift`,
  `LiveActivities.swift`.
- Siri/Shortcuts intents: `Platform/Intents.swift`.
- In-app tour and What's new: `Guide/Guide.swift`, `Views/GuideViews.swift`.
- Personality: launch splash, mood glow, energy bar (`Views/Personality.swift`).

## Lessons worth keeping

- Kia's EU servers give status and trip times in Central European time.
- Climate commands often never appear in Kia's command list; read the car to confirm.
- The legacy API has no outside temperature; use the weather at the parked position.
- App Store Connect caps uploads per day (ITMS-90382); batch releases.
- iOS can't run an app at an exact time; local notifications booked ahead plus background
  refresh, or a Shortcuts automation, are the options.

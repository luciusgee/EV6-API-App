# EV6 Precondition for iPhone: handover

For: Luke
From: Nick (via the Android build in `Nikolai828/Skoda-Automation`)
Status of the Android app: EV6 Precondition build #20 (0.2.20). CI builds it and its tests pass. It has **not yet been run against a real Kia account**.

This pack has everything needed to build an iPhone version of the Kia EV6 app without reading the Android code. The Android code is included anyway (in `reference-source/`), because it is the tested definition of how everything behaves. Where this document and the code disagree, the code wins, and please tell Nick.

## Contents of this pack

| File | What it's for |
| --- | --- |
| `HANDOVER.md` | This file. What the app does, how it's built, the Kia API, the rules semantics, the iOS mapping and a suggested plan |
| `FUNCTIONS.md` | Every type and function in the shared logic: what it does, its edge cases, what to port it to, and priority |
| `TESTS.md` | All 195 unit tests in the Android core, grouped by file, marked port or skip |
| `fixtures/` | Real-shaped JSON: rules backup, Kia responses (both protocols), climate payloads, errors, Open-Meteo |
| `screenshots/` | The Android Kia app's screens (light and dark), rendered by CI |
| `reference-source/` | The Android app's platform-free Kotlin core and its tests, plus the Kia-specific Android files |

---

## 1. What the app does

It preconditions (heats or cools) the car's cabin automatically. Each **rule** is one **trigger**, a list of **conditions** that must *all* pass, and one **action**. Global **guards** apply on top.

> "Weekdays, when I leave the office between 16:00 and 19:00, if it's below 5 °C at the car and my phone is near the car, heat to 21 °C."

- **Triggers:** leave or arrive at a place (geofence); approaching within X km of a place; a schedule (days plus a time); phone approaching the parked car.
- **Conditions:** time window, days of the week, temperature below, above or outside a range (from the car sensor, weather at the car, a forecast at a time, or the best available), SoC at least, plugged in or not, car at a place, phone near the car.
- **Actions:** start climate at a target temperature, or stop climate.
- **Guards** (never bypassed):
  - SoC at least the minimum (25 % by default), unless the car is plugged in
  - climate not already running (or, for stop, running)
  - rule cooldown and global cooldown
  - the rate budget
  - automation paused
  - holiday dates

Unknown inputs **fail** guards, always.

It also has manual start and stop, a dashboard with the car's state, a log that explains why each rule fired or didn't, "Test now" dry runs, a widget, rules import and export, and a fake-car mode for development.

Constraints carried over from the original spec. Please keep them:

- Credentials (refresh token, PIN, access tokens) are stored encrypted (on iOS, the Keychain), **never logged, never exported**.
- The VIN is masked everywhere except its last 4 characters.
- No analytics and no backend. The network is used only for Kia, Open-Meteo and map tiles.
- Single user, single car.

## 2. How it's built (and what to copy)

```
Triggers (geofence / schedule / widget / notification action)
        │  (receivers only enqueue work)
        ▼
PreconditionEngine ──► RuleEvaluator (pure) ──► EvaluationInputs (lazy, memoised per run)
        │                                            ├─ vehicle state: 10-min cache, else a Kia read
        │                                            ├─ weather: Open-Meteo with a 15-min cache
        │                                            └─ phone location: one fix per run
        ├─► VehicleApi (KiaClient) ──► RateBudget ──► Kia Connect EU
        └─► event log, notifications, cooldowns, failure counters (AutomationState)
```

The heart of the app is platform-free: `rules/`, `engine/`, `weather/`, `api/` and `api/kia/`, about 3,800 lines of Kotlin with 195 tests. Suggested iOS layout:

```
EV6Precondition.xcodeproj
PreconditionKit/            Swift package, no UIKit/SwiftUI: models, evaluator, validator, JSON,
                            budget, KiaClient, Open-Meteo, engine. Tested with XCTest.
EV6Precondition/            SwiftUI app: screens, Keychain, CoreLocation, notifications, App Intents
EV6Widget/                  WidgetKit (+ Control Center control on iOS 18)
```

Keep `PreconditionKit` free of UIKit, SwiftUI and CoreLocation, as the Android core is free of Android. That's what makes the whole decision path testable in plain XCTest. Protocols stand in for platform services, exactly like `engine/Ports.kt`: `RuleStore`, `PlaceStore`, `SettingsSource`, `AutomationStateStore`, `VehicleCacheStore`, `EventLog`, `Notifier`, `PhoneLocator`, `CabinSensor`.

## 3. The Kia Connect API (Europe)

**This API is unofficial.** It is the protocol the Kia Connect app itself uses, as documented by the open-source [hyundai_kia_connect_api](https://github.com/Hyundai-Kia-Connect/hyundai_kia_connect_api) Python project (v4.23.0, the version read for this build). Kia can change it at any time without notice. The reference implementation is `reference-source/api/kia/KiaClient.kt`, and `KiaClientTest.kt` shows every request and response shape.

### 3.1 Constants

| Name | Value |
| --- | --- |
| API base | `https://prd.eu-ccapi.kia.com:8080` (note the port) |
| IdP base | `https://idpconnect-eu.kia.com` |
| Service ID (client_id) | `fdc85c00-0a2f-4c64-bcb4-2cfb1500730a` |
| Service secret (client_secret) | `secret` (literally) |
| Application ID | `a2b8469b-30a3-4361-8e13-6fceea8fbe74` |
| CFB key (base64) | `wLTVxwidmH8CfJYBWSnHD6E0huk0ozdiuygB4hLkM5XCgzAL1Dk5sE36d/bx5PFMbZs=` |
| User-Agent | `okhttp/3.12.0` |
| Push type | `APNS` |

These are the Kia app's public constants, as published in the Python library. They aren't Nick's secrets.

### 3.2 The `Stamp` header

`Stamp` = base64( bytes("<appId>:<epochSeconds>") XOR cfbKeyBytes ). The XOR runs over the shorter of the two, which is the 47-byte plaintext. The epoch is the current Unix time in seconds, and the stamp is generated fresh on every request. Test vector: the unit test decodes a stamp for `1700000000` and expects `a2b8469b-30a3-4361-8e13-6fceea8fbe74:1700000000`.

### 3.3 Login: refresh token to access token

The user signs in to Kia Connect once in a browser and copies a **refresh token**: 48 characters, `[A-Z0-9]{48}`. The community guide is at <https://github.com/Hyundai-Kia-Connect/hyundai_kia_connect_api/discussions/987>. The app then does:

```
POST {IdP}/auth/api/v2/user/oauth2/token
Content-Type: application/x-www-form-urlencoded
grant_type=refresh_token&refresh_token=<token>&client_id=<serviceId>&client_secret=secret

200 {"token_type":"Bearer","access_token":"…","expires_in":3600, "refresh_token":"…"(optional)}
```

- The access token is `"<token_type> <access_token>"` and goes in `Authorization`.
- **If a new `refresh_token` comes back, persist it and use it from then on.** Kia may rotate tokens. Keep a fingerprint (SHA-256) of the token the user entered; if the user enters a different one, start a new session.
- Refresh 5 minutes before `expires_in` runs out.
- A 4xx, or no `access_token`, means the token was rejected (`LoginFailed`). That stops all automation and shows a banner (§5.4).

*Optional, later:* v4.23 of the library can also log in headless with username and password. The steps: GET the authorize page, GET `/auth/api/v1/accounts/certs` (a JWK), RSA-PKCS#1 v1.5-encrypt the password (hex), POST `/auth/account/signin` and expect a 302 carrying `code`, then exchange the code at the same token endpoint (`grant_type=authorization_code`). Consent pages and captchas can block this. The Android app only supports the refresh token.

### 3.4 Device registration

Once per session, and again whenever the server answers `4002`:

```
POST {API}/api/v1/spa/notifications/register
Headers: ccsp-service-id, ccsp-application-id, Stamp, Content-Type: application/json;charset=UTF-8, User-Agent
Body: {"pushRegId":"<64 random hex chars>","pushType":"APNS","uuid":"<random UUID>"}
200 {"retCode":"S","resCode":"0000","resMsg":{"deviceId":"…"}}
```

There is no Authorization header on this call.

### 3.5 Authenticated headers (every call below)

```
Authorization: <access token>
ccsp-service-id: <serviceId>
ccsp-application-id: <appId>
Stamp: <fresh stamp>
ccsp-device-id: <deviceId>
Ccuccs2protocolsupport: <0 or the vehicle's ccs2 value>
User-Agent: okhttp/3.12.0
```

### 3.6 Choosing the vehicle

```
GET {API}/api/v1/spa/vehicles
resMsg.vehicles[]: {vehicleId, nickname, vehicleName, vin, type ("EV","GN","PHEV","HV","PE"), ccuCCS2ProtocolSupport (0 or non-0), regDate}
```

If the user entered a VIN, pick that car (case-insensitive); an unknown VIN is `VehicleNotFound`. Otherwise pick the first `type == "EV"`, else the first car. Cache the `vehicleId` and `ccs2`, and pick again if the VIN setting changes.

### 3.7 Reading state (cached only: this never wakes the car)

| Protocol | Status call | Body location |
| --- | --- | --- |
| `ccs2 == 0` (older cars; a 2022 EV6 is expected to be here) | `GET /api/v1/spa/vehicles/{id}/status/latest` | `resMsg.vehicleStatusInfo` |
| `ccs2 != 0` (2024-on / newer software) | `GET /api/v1/spa/vehicles/{id}/ccs2/carstatus/latest` | `resMsg.state.Vehicle` |

After the status, also make one `GET /api/v1/spa/vehicles/{id}/location/park` (with `Ccuccs2protocolsupport: 0`). Its `resMsg.coord.lat/lon` is the current parked position and **wins** over the (possibly stale) position inside the status. If this call fails (for example with `5921`, no data), keep the status and carry on.

**Never call the "force refresh" endpoints** (`/status` without `latest`, or `/location`). They wake the car and drain its 12 V battery. The app trades freshness for battery safety, and the dashboard shows how old the data is.

Mapping to the snapshot (see `KiaMapper.kt`; the fixtures have full examples):

| Snapshot field | Older protocol (`vehicleStatusInfo`) | CCS2 (`state.Vehicle`) |
| --- | --- | --- |
| socPercent | `vehicleStatus.evStatus.batteryStatus` | `Green.BatteryManagement.BatteryRemain.Ratio` |
| pluggedIn | `evStatus.batteryPlugin != 0` | `Green.ChargingInformation.ConnectorFastening.State > 0` |
| charging | `evStatus.batteryCharge` (bool) | `Green.ChargingInformation.Charging.RemainTime > 0` (and plugged) |
| chargePowerKw (only while charging) | max(`evStatus.batteryPower.batteryStndChrgPower`, `…batteryFstChrgPower`) | `Green.Electric.SmartGrid.RealTimePower` |
| minutesToFull (only while charging) | `evStatus.remainTime2.atc.value` | `Green.ChargingInformation.Charging.RemainTime` |
| rangeKm | `evStatus.drvDistance[0].rangeByFuel.evModeRange{value,unit}` (else `totalAvailableRange`) | `Drivetrain.FuelSystem.DTE.Total` + `.Unit` |
| climate running | `vehicleStatus.airCtrlOn` | `Cabin.HVAC.Row1.Driver.Blower.SpeedLevel > 0` |
| targetTempC | `vehicleStatus.airTemp.value` as a hex code (below), when `unit == 0` | `Cabin.HVAC.Row1.Driver.Temperature.Value` (a string, may be `"OFF"`) + `.Unit` |
| outsideTempC | not reported | `Cabin.HVAC.OutsideTemperature.Value` + `.Unit` |
| parkingPosition | `vehicleLocation.coord.lat/lon` (overridden by `location/park`) | `Location.GeoCoord.Latitude/Longitude` (overridden) |
| parked | `!vehicleStatus.engine` | `!DrivingReady` |
| carCapturedAt | `vehicleStatus.time` `yyyyMMddHHmmss` in **Europe/Berlin** | `Date` `yyyyMMddHHmmss(.SSS)` in **UTC** |

- Units: distance units 1 = km, 2 or 3 = miles (× 1.609344). Temperature units 0 = °C, 1 = °F.
- Kia mixes `true`/`false` with `0`/`1`, and numbers with numeric strings. Parse leniently.
- A position of `0,0` means none.

Temperature codes (older protocol): an index into 14.0–29.5 °C in 0.5 °C steps, as upper-case hex plus `H`. So 21 °C is index 14, which is `"0EH"`; 14 °C is `"00H"`; 29.5 °C is `"1FH"`. Codes outside the range, or with `unit != 0`, mean unknown.

### 3.8 Climate commands

The target is rounded to 0.5 °C and clamped to 14–29.5 °C. Kia requires a duration; the Android app uses **10 minutes**.

**Older protocol:** `POST /api/v1/spa/vehicles/{id}/control/temperature` with the normal authenticated headers.

```json
{"action":"start","hvacType":0,"options":{"defrost":false,"heating1":0,"igniOnDuration":10},"tempCode":"0EH","unit":"C"}
{"action":"stop","hvacType":0,"options":{"defrost":true,"heating1":1},"tempCode":"10H","unit":"C"}
```

**CCS2:** `POST /api/v2/spa/vehicles/{id}/ccs2/control/temperature` (note **v2**). It needs a **control token**:

```
PUT {API}/api/v1/user/pin?token=
Authorization: <access token>   Content-Type: application/json
{"deviceId":"<deviceId>","pin":"<Kia Connect PIN>"}
200 {"controlToken":"…","expiresTime":600}      (no controlToken ⇒ PIN rejected ⇒ LoginFailed)
```

Then send the authenticated headers, but with `Authorization` and `AuthorizationCCSP` both set to `Bearer <controlToken>`. Reuse the control token until 30 s before it expires.

```json
{"command":"start","ignitionDuration":10,"strgWhlHeating":0,"hvacTempType":1,"hvacTemp":21.0,
 "sideRearMirrorHeating":1,"drvSeatLoc":"L",
 "seatClimateInfo":{"drvSeatClimateState":0,"psgSeatClimateState":0,"rrSeatClimateState":0,"rlSeatClimateState":0},
 "tempUnit":"C","windshieldFrontDefogState":false}
{"command":"stop"}
```

`drvSeatLoc` is `"L"` for left-hand drive. The Python library sends `"R"` for mile-based (right-hand-drive) markets; if Luke is in the UK, check this against a real car.

A successful command is `{"retCode":"S","resCode":"0000","resMsg":{…},"msgId":"…"}`. It is asynchronous: the car carries it out a little later.

### 3.9 Errors

Kia signals failure with `retCode: "F"` plus `resCode`, often on HTTP 200 or 400. It can also use an OAuth-style `{"error": "..."}`.

| Signal | Meaning | What the app does |
| --- | --- | --- |
| `7501`, HTTP 401, "Token is expired", "Received unexpected statusCode" | Access token expired | Refresh the login once and retry. If it fails again → `LoginFailed` (stops automation) |
| `4002` | Device ID dropped | Register again once and retry |
| `5091` | Daily request limit exceeded | `RateLimited(1 h)`: the budget is blocked for an hour |
| `5031`, `4081`, `9999`, `4004` | Remote control unavailable / timeout / duplicate | `VehicleNotAcceptingRequests`: retry once after 2 min |
| `4005` | Unsupported control | `OperationNotSupported`: the rule is disabled |
| `5921` (on location/park) | No data | Ignore; use the status position |
| HTTP 5xx | Server error | Counts as a failure (3 in a row pause automation) |
| No credentials | — | `NotConfigured`, no request made |

**Rate limit:** Kia allows roughly **200 requests per day per account** and sends no rate headers. A read costs 2 requests (status and park), plus occasional logins and device registrations. The Android Kia app budgets **80 operations per rolling 24 h, with 8 reserved for manual use** (both settable).

## 4. Rules

### 4.1 JSON format (must stay compatible with Android backups)

The same file imports on both platforms. `fixtures/rules-backup.json` is a complete example.

```json
{
  "version": 1,
  "places": [{"id":"office","name":"Office","centre":{"lat":50.087,"lon":14.421},"radiusM":200,"usualParkingSpot":null}],
  "rules": [{
    "id":"leave-work","name":"Leaving work","enabled":true,"priority":0,"cooldownMinutes":60,"proceedIfUnknown":false,
    "trigger":{"type":"geofenceExit","placeId":"office"},
    "conditions":[
      {"type":"daysOfWeek","days":["MON","TUE","WED","THU","FRI"]},
      {"type":"timeWindow","start":"16:00","end":"19:00"},
      {"type":"tempBelow","celsius":5.0,"source":{"type":"bestAvailable"}},
      {"type":"phoneNearCar","meters":1500}
    ],
    "action":{"type":"startClimate","targetC":21.0}
  }]
}
```

- **Discriminator:** `"type"`.
- **Triggers:**
  - `geofenceExit`, `geofenceEnter`: `placeId`
  - `approaching`: `placeId`, `km`
  - `schedule`: `days`, `time`
  - `nearCar`: `meters`
- **Conditions:**
  - `timeWindow`: `start`, `end`
  - `daysOfWeek`: `days`
  - `tempBelow`, `tempAbove`: `celsius`, `source`
  - `tempOutside`: `low`, `high`, `source`
  - `socAtLeast`: `percent`
  - `pluggedIn`: `expected`
  - `carAtPlace`: `placeId`
  - `phoneNearCar`: `meters`
- **Temperature sources:** `carOutside`, `weatherAtCar`, `forecastAt` (with a `time`), `cabinBle`, `bestAvailable`.
- **Actions:** `startClimate` (`targetC`), `stopClimate`.
- **Times** are `"HH:mm"`; accept `"H:mm"` on input.
- **Days** are `MON`…`SUN`; accept full names on input.
- **Defaults:** `enabled` true, `priority` 0, `cooldownMinutes` 60, `proceedIfUnknown` false, `conditions` [].
- **Unknown keys** are ignored.
- **Versions:** a file with a `version` above 1 is refused.
- **Import:** each place and rule is decoded and validated separately. Keep the good entries and report the bad ones by index and name. Duplicate rule IDs are errors. Rules may refer to places already on the phone.
- **Never** put credentials or the VIN in an export.

### 4.2 Validation (`RuleValidator`)

- **Identity:** `id` and `name` are non-blank; `cooldownMinutes` is at least 0.
- **Place references** must exist.
- **Triggers:**
  - `approaching.km` is in (0, 100]
  - a schedule has at least one day
  - `nearCar.meters` is between 100 and 5000
- **Conditions:**
  - a time window's `start` and `end` differ
  - `daysOfWeek` has at least one day
  - temperature thresholds are between -40 and 50
  - for `tempOutside`, `low < high`
  - `socAtLeast` is between 0 and 100
  - `phoneNearCar.meters` is between 50 and 20000
- **Contradictions:** `tempBelow X` together with `tempAbove Y ≥ X` on the same source is rejected. All conditions are AND, so it can never pass. The message tells the user to use `tempOutside`.
- **Actions:** `startClimate.targetC` is between 16 and 30.
- **Places:** radius between 100 and 2000 m, and valid coordinates.

### 4.3 Evaluation (`RuleEvaluator`, pure)

This is the part to get exactly right. Port the tests in `TESTS.md` (`RuleEvaluatorTest`, `NearCarTest`).

1. Skip everything if automation is paused, or today is a holiday date.
2. Candidates: enabled rules whose trigger matches the event. A schedule matches when the time is equal and today is in its days. Sort by priority (descending), then name, then id.
3. For each candidate, run the checks in this order and **stop at the first one that doesn't pass**. The order is cheapest first, so the car is only read when needed:
   1. rule cooldown (`lastFiredByRule + cooldownMinutes`)
   2. global cooldown (`lastAutomatedCommandAt + globalCooldown`, default 15 min)
   3. **FREE** conditions: `timeWindow` (inclusive start, exclusive end; wraps past midnight if start > end), `daysOfWeek`
   4. rate budget: needs 1 automation request if the vehicle state is already in hand, otherwise 2
   5. **NETWORK** conditions: weather-based temperatures when the car's location is free (cached position, or the place fallback); cabin
   6. **VEHICLE** conditions: SoC, plugged in, car at place, phone near car, car-sensor temperature
   7. vehicle guards: start → SoC guard (plugged in passes) and "not running"; stop → "running". A missing vehicle state fails.
4. The first rule that passes **wins**; only it acts.
5. **Unknown handling:** a condition whose input is unknown is `UNKNOWN`, which stops the rule, *unless* the rule has `proceedIfUnknown`, in which case it counts as passed. Guards never proceed on unknown.
6. **Temperature sources:**
   - `bestAvailable`: the car sensor if the car reports one (a cached snapshot with no outside temp means skip straight to weather), else weather at the car.
   - Car location for weather: cached parking position, else the place fallback (the `carAtPlace` condition's place, else the trigger's place: its `usualParkingSpot` or its centre), else a Kia read.
   - `forecastAt`: the next occurrence of that time (a time up to 1 h ago still counts as today), linearly interpolated between hourly points.
7. `phoneNearCar`: take one phone fix per run. Null → unknown. Then the car's parked position → distance ≤ meters.
8. Every rule evaluated gets a log entry with each check (`PASS`/`FAIL`/`UNKNOWN` name: detail) and the reason it stopped. Users rely on this to understand the app, so keep the wording.

### 4.4 The engine (`PreconditionEngine`)

- Runs are **serialised** (one at a time) so triggers never race on cooldowns or the budget. On iOS, use an `actor`.
- A trigger older than **30 min** is abandoned.
- Automation is blocked (skipped with a reason) after an auth failure, or after being paused by 3 failures.
- **Dedup:** the same geofence event (the `dedupKey`) within **5 min** is ignored. Schedule events are never deduplicated.
- **On success:** record the cooldowns, reset the failure count, log, and notify ("Preconditioning to 21.0 °C — left Office, 3.0 °C (Leaving work)") with a **Stop** action.
- **On failure:**
  - auth → stop, with no retry
  - unsupported → disable the rule, and notify
  - vehicle busy → retry once after 2 min
  - network → retry with backoff while attempts remain
  - budget or not configured → give up quietly
  - anything else → count it; **3 in a row pauses automation** (the user resumes it from the dashboard)
- **Manual start:** the SoC guard and the budget still apply; cooldowns and pause do not. Manual commands use the **manual** budget.
- **"Test now"** (dry run) evaluates one rule regardless of its trigger, never sends, and logs "would fire" or "would skip".
- **Near-car position refresh:** if any enabled rule has a `nearCar` trigger and the cached state is older than 3 h, read the car (automation budget, and only if at least 3 requests are left) so the fence around the car can move.
- **The first vehicle response** is logged once in full (VIN masked), so the available fields can be checked.

### 4.5 The rate budget (`RateBudget`)

A rolling window (Kia: 24 h). Each operation takes a ticket *before* the request and completes it after. Network errors still count; 401/403 don't. Automation may use at most `limit − reserve` in the window **and** must leave `reserve` untouched, so manual commands always work. A `RateLimited` error blocks both kinds until `max(retryAfter, reset)`. State is persisted. The Škoda header-parsing parts don't apply to Kia.

## 5. iOS mapping

| Android piece | iOS equivalent | Notes |
| --- | --- | --- |
| Play Services geofences | `CLLocationManager.startMonitoring(for: CLCircularRegion)`, or `CLMonitor` (iOS 17+) | **20 regions per app.** One region per place used by enter/exit rules, one per distinct "approaching X km", one per distinct near-car distance (`Geofences.required` computes this). In practice regions under ~100–150 m are unreliable. The app is relaunched in the background on a crossing with ~10 s; wrap the run in `beginBackgroundTask` |
| Exact alarms for schedules | **App Intent plus a Shortcuts personal automation** ("Time of Day", Run Immediately) | iOS has no exact background alarms, and `BGAppRefreshTask` is opportunistic. Expose `RunScheduledRulesIntent`; when it's run, evaluate schedule rules whose time is within a small window of now (for example −2/+10 min), deduplicated per rule per day. In the app, show "set up this automation" for each schedule rule. A fallback is a local notification at the time, which the user taps |
| WorkManager (retries, 2-min busy retry) | In-process `Task` with retries while the background task lasts; otherwise schedule a local notification or give up and log | The 2-min busy retry may not fit in a background wake. Acceptable: log "car busy" and notify |
| Fused location "one fix" | `CLLocationManager.requestLocation()` (needs **Always** for background) | Also used for `phoneNearCar` |
| DataStore / Room | JSON files in Application Support, or SwiftData | Rules, places, state, budget, log (30 days or 2,000 entries, whichever is smaller), vehicle cache |
| Android Keystore | **Keychain**, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` | Refresh token, PIN and the Kia session (access token, control token, device id). *AfterFirstUnlock* so background wakes can read them |
| Notifications with a Stop action | `UNUserNotificationCenter` + a category with a Stop action (or an App Intent) | |
| Widget + Quick Settings tile | WidgetKit interactive button (iOS 17 App Intent), plus a `ControlWidget` (iOS 18) | "Precondition now" and "Stop" |
| — (bonus) | App Intents / Siri: "Precondition now", "Stop climate", "Refresh car" | Nearly free once the intents exist for the schedules |
| osmdroid map picker | MapKit | Place centre, radius and usual parking spot |
| Rules backup to Downloads | `fileExporter`/`fileImporter`; optionally auto-save to the app's Documents (visible in the Files app) | Same JSON as Android, so Android backups import directly |
| Fake-car mode (debug) | `URLProtocol` subclass that answers Kia and Open-Meteo requests | Port `FakeKia.kt`; it drives the UI without a car and is great for SwiftUI previews and UI tests |

The iOS target version is Luke's call. iOS 17 gets interactive widgets and `CLMonitor`.

## 6. Screens (see `screenshots/`)

1. **Car** (dashboard):
   - "My EV6", with the data's age
   - SoC ring, range and plug/charge state
   - climate card with Start (target temperature) and Stop
   - automation card: pause switch, next scheduled check, last command, and the budget bar ("80 left of 80 · 72 for automation · 8 kept for you · resets 17:10")
   - banners: set-up needed, automation stopped (auth, with the fix), paused after failures (Resume), fake mode
2. **Rules:**
   - list with an on/off switch, a one-line description (`Describe.kt`) and the last result
   - editor with templates (Leaving work, Morning commute, Hot day)
   - trigger, condition and action pickers, with inline validation
   - Test now
3. **Places:** list, plus a map editor for centre, radius (100–2000 m) and usual parking spot.
4. **Activity** (the log): filterable by rule; each entry expands to show its checks; export as CSV.
5. **Settings:**
   - Kia Connect: refresh token, "How to get a token", PIN, optional VIN
   - Safety: minimum SoC, global cooldown, pause, holidays, °C/°F
   - Background permissions checklist
   - Rules backup: export, import, auto-backup
   - Rate limit: budget and reserve
   - Developer: fake car (SoC, plug, climate, scenario, outside temperature) and trigger simulator

## 7. Suggested milestones

1. **Kia and dashboard.** `PreconditionKit`: models, `KiaClient`, `KiaMapper`, `RateBudget`, `FakeKia` via `URLProtocol`. App: Settings (token, PIN, VIN in the Keychain), dashboard, manual Refresh/Start/Stop, log. *First real-car test:* check the protocol (`ccs2`), fields and timestamps against the first-response dump in the log.
2. **Rules.** Model, JSON import/export (test with `fixtures/rules-backup.json`), validator, evaluator, Open-Meteo, dry run, rules UI, schedule App Intent plus Shortcuts guidance.
3. **Location.** Places with MapKit, region monitoring, `phoneNearCar`, near-car fence and 3-hourly position refresh, "approaching" fences.
4. **Polish.** Notifications with Stop, widget, Control Center control, Siri intents, auto-backup, holidays, background-permission checklist.

## 8. Open questions and risks

- **Unverified against a real car.** Which protocol the 2022 EV6 reports (`ccs2`, expected 0, so no PIN), the real response fields, timestamp zones, and the exact daily limit are all unconfirmed. Log the first response.
- **Refresh token lifetime.** Unknown. If it expires, the user gets a new one from the browser flow (or you add the username/password login from §3.3).
- **Background time on iOS.** A cold wake may have to log in (token refresh), register a device, and make 2 reads plus a command: 4–6 HTTP calls. Keep the session persisted so a wake normally needs only 3, and use short timeouts (15 s connect, 30 s read on Android).
- **Stale cached state.** The car reports when it's driven or charged; parked for days, the data can be old. That is intentional (battery safety).
- **Right-hand drive** (`drvSeatLoc`) on CCS2 cars (§3.8).
- **The Kia API may break.** The Home Assistant `kia_uvo` integration and the Python library's issues are the best early warning.

## 9. Where to look in the Android code

| Topic | File |
| --- | --- |
| Rule model and JSON | `reference-source/rules/Model.kt`, `Serializers.kt`, `RuleJson.kt` |
| Evaluation order and wording | `rules/RuleEvaluator.kt`, `Guards.kt`, `Describe.kt` |
| Validation | `rules/RuleValidator.kt` |
| Geofence planning | `rules/Geofences.kt` |
| Schedules | `rules/ScheduleCalculator.kt` |
| Engine policy | `engine/PreconditionEngine.kt`, `engine/Ports.kt`, `engine/ApiMonitor.kt`, `engine/VehicleRepository.kt` |
| Budget | `api/RateBudget.kt` |
| Errors | `api/ApiError.kt` |
| Kia | `api/kia/KiaClient.kt`, `KiaMapper.kt`, `KiaConfig.kt`, `KiaSession.kt`, `FakeKia.kt` |
| Kia app wording and defaults | `android-kia/brand/CurrentBrand.kt`, `android-kia/ui/settings/CredentialsSection.kt` |
| Weather | `weather/OpenMeteo.kt` |

Luke can also get read access to the GitHub repo (`Nikolai828/Skoda-Automation`), if Nick adds him, to follow changes and fixes on the Android side.

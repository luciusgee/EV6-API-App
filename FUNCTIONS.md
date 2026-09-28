# Function breakdown

This covers every type and function in the Android app's platform-free core (`reference-source/`), grouped by module. It says what each does, the edge cases that matter, a suggested Swift shape, and a porting priority.

**Priority:**
- **P1**: needed for milestone 1 (Kia and dashboard)
- **P2**: rules (milestone 2)
- **P3**: location (milestone 3)
- **P4**: polish
- **Skip**: Android- or Škoda-only; the iOS equivalent is noted

Swift suggestions assume a `PreconditionKit` package (no UIKit or SwiftUI), `async`/`await`, `Codable`, and `actor` wherever the Kotlin uses a `Mutex`.

---

## 1. `rules/Model.kt`: the rule model (P2; `LatLon`/`Place` P1)

| Kotlin | What it is / does | Swift | Notes |
| --- | --- | --- | --- |
| `data class Rule(id, name, enabled=true, priority=0, trigger, conditions=[], action, cooldownMinutes=60, proceedIfUnknown=false)` | One rule | `struct Rule: Codable, Identifiable, Hashable` | Decode missing keys as the defaults (custom `init(from:)` or wrapper defaults) |
| `sealed interface Trigger`: `GeofenceExit(placeId)`, `GeofenceEnter(placeId)`, `Approaching(placeId, km)`, `Schedule(days: Set<DayOfWeek>, time: LocalTime)`, `NearCar(meters)` | What starts an evaluation | `enum Trigger: Codable` with associated values; discriminator key `"type"` = `geofenceExit`/`geofenceEnter`/`approaching`/`schedule`/`nearCar` | JSON must match exactly (see `fixtures/rules-backup.json`) |
| `sealed interface Condition`: `TimeWindow(start,end)`, `DaysOfWeek(days)`, `TempBelow(celsius, source)`, `TempAbove(celsius, source)`, `TempOutside(low, high, source)`, `SocAtLeast(percent)`, `PluggedIn(expected)`, `CarAtPlace(placeId)`, `PhoneNearCar(meters)` | AND-ed conditions | `enum Condition: Codable` | Discriminators: `timeWindow`, `daysOfWeek`, `tempBelow`, `tempAbove`, `tempOutside`, `socAtLeast`, `pluggedIn`, `carAtPlace`, `phoneNearCar` |
| `sealed interface TempSource`: `CarOutside`, `WeatherAtCar`, `ForecastAt(time)`, `CabinBle`, `BestAvailable` | Where a temperature comes from | `enum TempSource: Codable, Hashable` | Encoded as an object, e.g. `{"type":"bestAvailable"}` or `{"type":"forecastAt","time":"07:40"}` |
| `sealed interface Action`: `StartClimate(targetC)`, `StopClimate` | What to send | `enum RuleAction: Codable` | `{"type":"stopClimate"}` has no other fields |
| `data class LatLon(lat, lon)` + `distanceTo(other)` | Coordinate, great-circle (haversine) metres, R = 6 371 000 | `struct LatLon: Codable, Hashable` | Or use `CLLocation.distance(from:)` in the app layer, but keep a pure version in the kit for tests |
| `data class Place(id, name, centre, radiusM, usualParkingSpot?)`, `contains(point)`, `parkingSpotOrCentre`, `MIN_RADIUS_M=100`, `MAX_RADIUS_M=2000` | A named circle | `struct Place: Codable, Identifiable` | `usualParkingSpot` is encoded as `null` when absent |
| `sealed interface TriggerEvent`: `GeofenceExited(placeId)`, `GeofenceEntered(placeId)`, `Approached(placeId, km)`, `ScheduleFired(time)`, `ApproachedCar(meters)` + `dedupKey` | What actually happened | `enum TriggerEvent: Codable` | `dedupKey`: `exit:<id>`, `enter:<id>`, `approach:<id>:<km>`, `car:<m>`; nil for schedules |
| `Trigger.matches(event, today)` | Does this rule react to this event? | method on `Trigger` | A schedule needs time equality **and** today in its days. On iOS, consider a tolerance window for Shortcuts-driven schedules (HANDOVER §5) |
| `Trigger.syntheticEvent()` | The event a trigger would produce | method | Used by the "Test now" dry run |
| `Trigger.placeId` | The place a trigger refers to, if any | computed property | |

## 2. `rules/Serializers.kt` (P2)

| Kotlin | Does | Swift |
| --- | --- | --- |
| `LocalTimeSerializer` | Writes `"HH:mm"` and reads `"H:mm"` (lenient) | A `TimeOfDay` struct (hour, minute) with `Codable` as a string. Don't use `Date` for times of day |
| `DayOfWeekSerializer` | Writes `MON`..`SUN` and reads the 3-letter or full name, any case | `enum Weekday: String, Codable, CaseIterable` with a lenient decoder; map to `Calendar` weekday numbers (Sunday = 1!) in one place |

## 3. `rules/RuleJson.kt`: backup format (P2)

| Kotlin | Does | Notes |
| --- | --- | --- |
| `RuleBundle(version=1, places, rules)` | File root | `CURRENT_VERSION = 1` |
| `RuleJson.export(places, rules): String` | Pretty JSON, defaults included | Never includes credentials or the VIN |
| `RuleJson.import(text, existingPlaceIds): ImportResult` | Decodes **each** place and rule separately, validates, drops bad entries and reports them | Refuses `version > 1`; a non-object file is one issue; duplicate rule IDs are issues; rules may refer to existing places |
| `ImportIssue(section, index, name?, message)` / `toString()` | `"rule #3 \"Leaving work\": …"` (1-based index) | Show these to the user after an import |
| `ImportResult(places, rules, issues)`, `ok` | | |

Swift: decode the root as `[String: JSONValue]`, or decode arrays of raw JSON and each element separately, so one bad rule doesn't fail the whole file. `JSONDecoder` alone will throw on the first error.

## 4. `rules/RuleValidator.kt` (P2)

| Function | Rules enforced |
| --- | --- |
| `validate(rule, placeIds): List<String>` | Blank id or name; negative cooldown; unknown place refs (trigger or `carAtPlace`); `approaching.km` in (0, 100]; a schedule with no days; `nearCar.meters` 100–5000; a time window with start == end; `daysOfWeek` empty; temperatures -40..50; `tempOutside` low < high; SoC 0–100; `phoneNearCar` 50–20000; **below X plus above Y ≥ X on the same source is impossible** (the message suggests `tempOutside`); `startClimate.targetC` 16–30 |
| `validatePlace(place): List<String>` | Blank id or name; radius 100–2000; lat/lon valid |

The constants (`MIN_TARGET_C=16`, `MAX_TARGET_C=30`, `MIN/MAX_CAR_RADIUS_M=100/5000`, `MIN/MAX_PHONE_DISTANCE_M=50/20000`) are also used by the editor's sliders.

## 5. `rules/Inputs.kt`: the evaluator's inputs (P2)

| Kotlin | Does | Swift |
| --- | --- | --- |
| `enum ClimateState { OFF, RUNNING, UNKNOWN }` | | `enum` |
| `data class VehicleSnapshot(...)` | Car state; **every field optional** (nil = unknown). Fields: `socPercent`, `rangeKm`, `pluggedIn`, `chargePowerKw`, `minutesToFullyCharged`, `climate`, `climateRawState`, `targetTempC`, `targetReachedAtEpochMs`, `climateWithoutExternalPower`, `chargingState` (`CHARGING`/`PLUGGED_IN`/`UNPLUGGED` for Kia), `outsideTempC`, `parkingPosition`, `parked`, `carCapturedAtEpochMs`, `fetchedAtEpochMs` (required), `unavailable` | `struct VehicleSnapshot: Codable` (it's cached to disk) |
| `TempReading(celsius, source, at)` | A temperature and where it came from | struct |
| `interface EvaluationInputs`: `vehicleIfFree()`, `vehicle()`, `weatherNow(at)`, `forecastAt(at, time)`, `cabinTemp()`, `phoneLocation()` | Lazy inputs; `vehicleIfFree` never costs a request; implementations memoise within one run | `protocol EvaluationInputs` (async methods) |
| `fun interface BudgetView { automationAvailable() }` | | closure or protocol |
| `GuardSettings(minSocPercent=25, globalCooldown=15 min, automationPaused=false, holidays=[])` | | struct |
| `CooldownState(lastAutomatedCommandAt?, lastFiredByRule: Map<String, Instant>)` | | struct |

## 6. `rules/RuleEvaluator.kt`: the core decision (P2, most important)

| Kotlin | Does |
| --- | --- |
| `enum Tri { PASS, FAIL, UNKNOWN }`, `Check(name, result, detail)` | One check result; `toString` = `"name: detail"` |
| `RuleVerdict(ruleId, ruleName, fired, reason, checks, temperature?)` | Per-rule outcome; `reason` is the first failing check, or a summary of the passed conditions |
| `Evaluation(event, at, globalSkip?, verdicts, winner?)`, `winnerVerdict` | Whole-run outcome |
| `EvaluationRequest(event, now: ZonedDateTime, rules, places, guards, cooldowns, budget, inputs, requireTriggerMatch=true)` | Input. `now` carries the **time zone** used for time windows and days |
| `RuleEvaluator.evaluate(req)` | Pause/holiday skip → candidates (enabled, trigger matches unless a dry run) sorted by priority desc, name, id → run each until one fires |
| `RuleRun.run()` (private) | Order: rule cooldown → global cooldown → FREE conditions → budget check (needs 1 if the vehicle is in hand, else 2) → NETWORK conditions → VEHICLE conditions → vehicle guards. Stops at the first non-PASS |
| `tierOf(condition)` / `tierOf(source)` | `timeWindow`/`daysOfWeek` → FREE. SoC/plug/carAtPlace/phoneNearCar → VEHICLE. Temperature: `cabinBle` → NETWORK; `carOutside` → VEHICLE; `weatherAtCar`/`forecastAt` → NETWORK if the car location is free, else VEHICLE; `bestAvailable` → NETWORK only if the cached car is known to lack an outside temp **and** the location is free, else VEHICLE |
| `evalCondition(c)` | Evaluates one condition. UNKNOWN becomes PASS only if `rule.proceedIfUnknown` (detail gets "(unknown, proceeding as the rule allows)") |
| `timeWindow` | start == end → always inside; start < end → `[start, end)`; start > end → wraps midnight |
| `temperature(source, threshold, below)` / `temperatureOutside` | Strict `<` / `>`; `tempOutside` passes if `< low` or `> high` |
| `readTemp(source)` | `carOutside` → the snapshot's `outsideTempC`; `weatherAtCar` → Open-Meteo current at the car location; `forecastAt` → Open-Meteo at `forecastInstant`; `bestAvailable` → car, else weather |
| `forecastInstant(s)` | Today at `s.time`; if that is more than 1 h ago, tomorrow |
| `carAtPlace` | Unknown place → FAIL; no position → UNKNOWN; inside the radius → PASS |
| `phoneNearCar` | Phone fix (nil → UNKNOWN), then the car's position (nil → UNKNOWN); distance ≤ meters |
| `freeCarLocation()` / `carLocation()` / `placeFallback()` | Cached parking position → place fallback (the `carAtPlace`'s place, else the trigger's place; `usualParkingSpot` or centre) → a Kia read |
| `vehicleGuards()` | Start → `Guards.soc`, `Guards.notRunning`; stop → `Guards.running`; no vehicle → FAIL "vehicle state: unavailable" |

The log `details` format is `"<PASS|FAIL|UNKNOWN> <check name>: <detail>"`, one line per check. Condition check names are prefixed `"condition "`.

## 7. `rules/Guards.kt` (P1 for manual start, P2)

| Function | Logic |
| --- | --- |
| `soc(v, min)` | Plugged in → PASS; SoC nil → FAIL; SoC < min → FAIL "SoC 20% below minimum 25%"; else PASS |
| `notRunning(v)` | OFF → PASS; RUNNING → FAIL "already running (raw)"; UNKNOWN → FAIL |
| `running(v)` | RUNNING → PASS; OFF / UNKNOWN → FAIL |

## 8. `rules/Describe.kt`: wording (P2)

`time` (`HH:mm`), `temp` (`"%.1f °C"`), `days` ("every day", "Mon–Fri", "Sat–Sun", else "Mon,Wed"), `trigger`, `event`, `source`, `condition`, `distance` (m / km), `action`. These strings appear in the log, notifications and rule lists, and the tests assert on some of them. Port them verbatim so behaviour and tests line up. Localisation can come later.

## 9. `rules/Geofences.kt`: region planning (P3)

| Function | Does |
| --- | --- |
| `required(rules, places, carPosition?) -> [GeofenceSpec]` | Per place used by enabled enter/exit rules: one region `place:<id>` with the needed transitions. Per distinct `approaching` (place, km): an enter-only region `approach:<id>:<km>` with radius km × 1000. Per distinct `nearCar` distance, when the car position is known: enter-only `car:<m>` |
| `needsCarPosition(rules)` | Any enabled `nearCar` trigger |
| `eventFor(id, transition) -> TriggerEvent?` | Reverse mapping from a region identifier to an event. `approach:` ids split on the **last** `:` (place IDs may contain `:`) |

On iOS, use `CLCircularRegion(identifier:)` with the same identifiers. Watch the **20-region limit**: if `required` returns more, log it and register the first 20.

## 10. `rules/ScheduleCalculator.kt` (P2)

| Function | Does |
| --- | --- |
| `next(trigger, after)` | The next date-time strictly after `after` on one of the days at the time; checks up to 7 days ahead; a time in a DST gap moves forward |
| `nextCheck(rules, after)` | The soonest across enabled schedule rules (Android arms one exact alarm for it) |

On iOS, use it for the dashboard's "Next scheduled check" and, if you adopt it, the local-notification fallback. The Shortcuts automation drives the real trigger.

## 11. `rules/Templates.kt` (P2)

"Leaving work" (exit office; Mon–Fri; 16:00–19:00; best-available < 5 °C; phone ≤ 1500 m → 21 °C), "Morning commute" (Mon–Fri 07:20; car at Home; phone ≤ 500 m; forecast at 07:40 < 3 °C → 20 °C), "Hot day" (exit office; weather at car > 24 °C → 20 °C). `newId()` = UUID.

---

## 12. `api/`: shared API plumbing

| Kotlin | Does | Priority / Swift |
| --- | --- | --- |
| `Credentials(apiKey, vin, pin?)` | For Kia, `apiKey` is the **refresh token**; `vin` is optional; `pin` is the Kia Connect PIN | P1 `struct` |
| `CredentialsProvider.credentials()` | nil when not configured (no token) | P1 protocol; backed by the Keychain |
| `ApiMetaSink.onResponse(meta, error?)` | Every finished call reports here (→ `ApiMonitor`) | P1 |
| `ApiResult<T>`: `Success(value, meta)` / `Failure(error, meta?)` | `meta == nil` means no response arrived | P1: `Result<T, ApiError>` plus a meta, or a custom enum |
| `VehicleFetch(snapshot, rawJson)` | The raw JSON is logged once (VIN masked) | P1 |
| `interface VehicleApi { getVehicle(kind); startClimate(targetC, kind, withoutExternalPower); stopClimate(kind) }` | The engine's only view of the car | P1 `protocol VehicleAPI` |
| `enum RequestKind { AUTOMATION, MANUAL }` | Which budget pool | P1 |
| `ApiError` (sealed): `NotConfigured`, `BudgetExhausted(kind)`, `KeyExpired`, `KeyNotAuthorized`, `LoginFailed(reason)`, `VehicleNotFound`, `OperationNotSupported`, `OperationDisabled`, `RateLimited(retryAfter?)`, `VehicleNotAcceptingRequests(retryAfter?)`, `Server(code)`, `Http(code)`, `Network(cause)`, `BadResponse(code, cause)`; `isAuthFailure` = `KeyExpired`/`KeyNotAuthorized`/`LoginFailed` | Error vocabulary the engine switches on | P1 `enum ApiError: Error`. `KeyExpired`/`KeyNotAuthorized` are Škoda-only; Kia uses `LoginFailed` |
| `ResponseMeta(httpCode, receivedAt, rateLimit?, rateRemaining?, rateResetAt?, retryAfter?, apiKeyExpiresAt?)` | Per-response metadata | P1: for Kia only `httpCode`, `receivedAt`, `retryAfter` matter |
| `HeaderParser`, `ErrorMapper` | Škoda header and error parsing | **Skip** |
| `RateBudget` (`tryAcquire(kind) → ticket?`, `complete(ticket, meta?, error?)`, `snapshot()`, `available(kind)`, `compute(state, cfg, now)`) | Budget (HANDOVER §4.5). 401/403 are removed from the count; `RateLimited` blocks until `max(retryAfter, reset)`; history is pruned to 2 windows | P1 `actor RateBudget`. Port `RateBudgetTest` |
| `BudgetConfig(fallbackLimit, manualReserve, window)` | Kia: 80 / 8 / 24 h | P1 |
| `RateBudgetState` (persisted: limit, remaining, resetAt, observedAt, exhaustedUntil, sent[], nextId) | | P1 `Codable` |
| `BudgetSnapshot` | limit, remaining, automationAvailable, manualAvailable, automationUsedInWindow, manualReserve, resetAt, exhaustedUntil, fromServer | P1 (dashboard bar) |
| `maskVin(vin)`, `redactVin(text, vin)` | `***…0123`; masks anything VIN-shaped (`[A-HJ-NPR-Z0-9]{17}`) | P1 |
| `SkodaClient`, `SkodaApiService`, `ApiModels`, `VehicleMapper`, `FakeCar` HTTP handling | Škoda | **Skip** (but `FakeCarState` and `FakeScenario` are reused by `FakeKia`) |
| `FakeCarState(soc, pluggedIn, charging, climateState, targetTempC, lat, lon, scenario, limit)`, `FakeScenario { NONE, KEY_EXPIRED, KEY_NOT_AUTHORIZED, RATE_LIMITED, VEHICLE_BUSY, NOT_SUPPORTED, SERVER_ERROR, PARTIAL }` | State behind the fake car | P1 (debug) |
| `FakeRouter` | Routes Kia/Open-Meteo hosts to the fakes when fake mode is on | P1 (debug): a `URLProtocol` registered on the app's `URLSessionConfiguration` |

## 13. `api/kia/`: the Kia client (P1, most important)

### `KiaConfig`

| Member | Does |
| --- | --- |
| `apiBase`, `idpBase`, `serviceId`, `serviceSecret`, `appId`, `cfbBase64`, `climateMinutes=10` | Constants (HANDOVER §3.1); the bases can be overridden in tests |
| `spa`, `spaV2`, `user` | `{apiBase}/api/v1/spa`, `/api/v2/spa`, `/api/v1/user` |
| `stamp(epochSeconds)` | XOR stamp (§3.2) |
| `API_HOST`, `IDP_HOST`, `USER_AGENT`, `MIN_TEMP_C=14`, `MAX_TEMP_C=29.5` | |

### `KiaSession` (persist in the **Keychain**, since it holds tokens)

`enteredTokenHash` (SHA-256 hex of the token the user entered), `refreshToken` (current, may be rotated), `accessToken`, `accessExpiresAtMs`, `deviceId`, `vehicleId`, `vehicleVin`, `selectedFor` (the VIN setting the car was picked for; `""` = first EV), `ccs2`, `controlToken`, `controlExpiresAtMs`. `KiaSessionStore { load(); save(session?) }`, plus `InMemoryKiaSessionStore` for tests. Android keeps a separate slot for fake mode so the simulator can't overwrite a rotated real token; do the same.

### `KiaClient: VehicleApi`

| Function | Does |
| --- | --- |
| `getVehicle(kind)` | Status (`status/latest` or `ccs2/carstatus/latest`), then `location/park` (failures ignored); maps with `KiaMapper`; the raw JSON is `{"status":…, "park":…}` |
| `startClimate(targetC, kind, _)` | Round to 0.5, clamp 14–29.5; older protocol: v1 `control/temperature` with `tempCode`; CCS2: v2 `ccs2/control/temperature` with control headers. The third parameter is ignored for Kia |
| `stopClimate(kind)` | Stop payloads (§3.8) |
| `reset()` | Clears the session |
| `call(kind, op)` (private) | Serialised (mutex → `actor`). Credentials → budget ticket → `withSession` → complete the ticket and report meta. Catches mapped failures, Kia errors, network errors. Meta code: `LoginFailed` → 401 (not counted), `RateLimited` → 429 |
| `withSession(creds, op)` | Loop: `ensureSession` + `op`; login expired → clear the access token and retry **once**; `4002` → clear the device and retry **once**; otherwise rethrow |
| `ensureSession(creds)` | Load the session (a new one if the token fingerprint changed) → refresh the login if missing or within 5 min of expiry → register the device if missing → select the vehicle if missing or the VIN setting changed. Saves after each step |
| `refreshLogin(s)` | Token endpoint (§3.3); keeps a rotated refresh token; clears the control token; 5xx → `Server`, other failures → `LoginFailed("Kia rejected the refresh token")` |
| `registerDevice(s)` | §3.4; random 64-hex `pushRegId` and UUID |
| `selectVehicle(s, wantedVin)` | §3.6; not found → `VehicleNotFound` |
| `controlHeaders(s, creds)` | CCS2 only: no PIN → `LoginFailed("this car needs your Kia Connect PIN…")`; fetch or reuse the control token (30 s margin); `Authorization` and `AuthorizationCCSP` = the control token. A PIN call answering 401/7501 is treated as login expired (triggers the refresh retry) |
| `authHeaders(s, ccs2)` | §3.5 |
| `get` / `post` / `exchange` / `parse` | HTTP. `parse` throws on non-2xx, `retCode == "F"`, or login-expired markers; non-JSON 2xx → `BadResponse` |
| `map(KiaApiException)` | Error table (§3.9) |
| `roundToHalf(c)` | `round(c*2)/2` |

`KiaApiException(httpCode, resCode, detail)`: `isLoginExpired` (7501, 401, "token is expired"/"token has expired"/"unexpected statuscode"), `isDeviceRejected` (4002), `from(code, body)`. `KiaFailure(error, httpCode)`: already mapped.

### `KiaMapper`

| Function | Does |
| --- | --- |
| `toSnapshot(status, park?, ccs2, fetchedAt)` | Picks the legacy or CCS2 mapping; the park position overrides; sets `fetchedAt` |
| `fromLegacy(info)` / `fromCcs2(v)` (private) | The field table in HANDOVER §3.7 |
| `legacyTemp(hex, unit)` / `legacyTempCode(c)` | `"0EH"` ↔ 21.0; out of range or °F → nil; `legacyTempCode` clamps |
| `celsius`, `km`, `position`, `localTime` (Berlin), `utcTime`, `compactTime` (first 14 digits, separators tolerated) | Helpers |
| JSON helpers `path("a.b.0.c")`, `str()`, `num()` (strings too), `bool()` (true/false/0/1) | Kia's JSON is loosely typed; write equivalent helpers over `[String: Any]` or a small `JSONValue` enum |

### `FakeKia` (debug/test, P1)

Answers the IdP token call (`KEY_EXPIRED` → 400 `invalid_grant`), register, vehicles (one EV6, `ccs2 = 0`), `status/latest` (built from `FakeCarState`), `location/park` (`PARTIAL` → 5921), and `control/temperature` (updates the fake's climate state). Scenarios: `KEY_NOT_AUTHORIZED` → 401 token expired; `RATE_LIMITED` → 5091; `VEHICLE_BUSY` → 5031; `NOT_SUPPORTED` → 4005 on control; `SERVER_ERROR` → 503. Daily limit = `state.limit × 10`. On iOS: a `URLProtocol` subclass.

---

## 14. `weather/` (P2)

| Kotlin | Does | Swift |
| --- | --- | --- |
| `OpenMeteoService.forecast(lat, lon, current=temperature_2m, hourly=temperature_2m, forecast_days=2, timeformat=unixtime, timezone=GMT)` | `GET https://api.open-meteo.com/v1/forecast?...`, no key | URLSession |
| `OpenMeteoResponse{ current{time, temperature_2m}, hourly{time[], temperature_2m[]} }` | | Codable |
| `WeatherSource { current(at); forecastAt(at, time) }` | | protocol |
| `WeatherRepository` | 15-minute cache keyed by lat/lon to 3 decimals (~100 m); serialised; failures → nil plus `lastError` | `actor` |
| `forecastAt` | Linear interpolation between the hourly points around the time; before the first point → only if within 1 h; beyond the range → nil | Port `WeatherRepositoryTest` |
| `FakeWeather` | Returns a settable temperature in fake mode | debug |

## 15. `engine/` (P1 for manual and refresh, P2 for automation)

### `Ports.kt` (protocols the app implements)

| Kotlin | iOS implementation |
| --- | --- |
| `RuleStore { rules(); disableRule(id, reason) }` | JSON file / SwiftData |
| `PlaceStore { places() }` | same |
| `SettingsSource { guards(); defaultTargetC(); climateWithoutExternalPower() }` | UserDefaults (non-secret) |
| `PhoneLocator { locate() }` | `CLLocationManager.requestLocation` wrapped in a continuation, with a timeout |
| `CabinSensor { read() }` | Return nil (BLE deferred) |
| `VehicleCacheStore { load(); save(snapshot) }` | JSON file |
| `AutomationState` (persisted): `lastAutomatedCommandAtMs`, `lastFiredByRuleMs`, `lastTriggerAtMs` (dedup), `consecutiveFailures`, `pausedAfterFailures`, `authFailure`, `apiKeyExpiresAtMs`, `keyExpiryWarnedForMs`, `firstVehicleDumpDone`, `lastCommand`; `cooldowns()`, `automationBlockedReason` | Codable struct in a file |
| `AutomationStateStore { load(); update(transform) }` | actor-backed file |
| `LogKind { FIRED, SKIPPED, COMMAND, MANUAL, DRY_RUN, ERROR, INFO }`, `LogEntry(at, kind, decision, reason, trigger?, ruleId?, ruleName?, httpCode?, requestsUsed, details?)`, `EventLog.append` | Keep 30 days or 2,000 entries; CSV export |
| `Notifier { commandSent(title, text, canStop); problem(title, text, openSettings) }` | `UNUserNotificationCenter` |

### `VehicleRepository`

`cached()` (any age), `fresh()` (younger than 10 min), `fetch(kind)` (reads the car, caches it, logs the first response once with the VIN masked). `madeRequest` on `ApiResult` = a response arrived or a network error happened (both cost a request).

### `ApiMonitor: ApiMetaSink`

`onResponse(meta, error)`: an auth failure → `onAuthFailure`; a 2xx clears `authFailure` (logs "resumed"); stores the key expiry (Škoda only). `onAuthFailure(error)` sets `authFailure`, logs "stopped", and notifies "Automation stopped: <msg>. <authHelp>" once. Kia `authHelp`: "Get a new Kia Connect refresh token (and check your PIN) and paste it in Settings." `checkKeyExpiry()`: Škoda only, **skip**.

### `PreconditionEngine`

| Function | Does |
| --- | --- |
| `onTrigger(event, triggeredAt, attempt) → EngineOutcome` | Staleness (30 min) → blocked → dedup (5 min) → evaluate → log each verdict → an auth failure during the read stops → no winner (a failed state read is treated as a failure) → `execute` |
| `execute(rule, label, temp, attempt)` | Sends the action; success → cooldowns, reset failures, `lastCommand`, log `COMMAND`, notify with Stop; failure → log and `failure` |
| `failure(error, rule?, attempt, label)` | Policy (HANDOVER §4.4): auth → none; unsupported → disable the rule; busy → `Retry.VEHICLE_BUSY` once; network → `Retry.BACKOFF` if not the last attempt; budget/not configured → none; else count, and pause after 3 |
| `dryRun(ruleId)` / `dryRun(rule)` | Test now: ignores the trigger, reads the car on the **manual** budget, logs `DRY_RUN` "would fire/would skip" |
| `manualStart(targetC?)` / `manualStop()` | Budget (needs 2 if no fresh state) → read if needed → SoC guard (start only) → send → log `MANUAL` |
| `refreshVehicle()` | Dashboard refresh (manual budget) |
| `refreshCarPositionIfDue(maxAge=3h)` | For `nearCar` rules; needs ≥ 3 automation requests left |
| `resumeAutomation()` | Clears pause and failures |
| `EngineInputs` | Memoises the vehicle read and one phone fix per run; counts `requestsMade`; keeps `vehicleError` |
| Types: `Attempt(number, isLast, vehicleBusyRetry)`, `Retry { NONE, BACKOFF, VEHICLE_BUSY }`, `EngineOutcome { Skipped, Fired, Failed }`, `ManualOutcome { Sent, Refused, Failed }` | Constants: `STALE_AFTER=30 min`, `DEDUP_WINDOW=5 min`, `MAX_CONSECUTIVE_FAILURES=3`, `POSITION_MAX_AGE=3 h`, `POSITION_REFRESH_MIN_BUDGET=3` |

---

## 16. Android-only parts: what replaces them on iOS

| Android (`app/src/main`, not in the core) | Role | iOS |
| --- | --- | --- |
| `triggers/Workers.kt` (`PreconditionWorker`, `CommandWorker`, `ScheduleWorker`, `SyncTriggersWorker`, `CarPositionWorker`, `MaintenanceWorker`) | Background jobs | App Intents, region-monitoring callbacks, `BGAppRefreshTask` for maintenance and position refresh (best-effort) |
| `triggers/Registrars.kt`, `Receivers.kt`, `WorkScheduler.kt` | Register geofences and alarms; boot/update re-registration | `CLLocationManager` region sync after rules or places change and at launch (regions persist across launches) |
| `triggers/PhoneLocation.kt` | One-shot fused location | `requestLocation()` |
| `data/*` (Room, DataStore, `SecureKeyStore`, `RulesBackup`, `KiaSessionRepository`) | Storage | Files/SwiftData + Keychain + Files-app export |
| `notify/AppNotifier.kt` | Channels, Stop action | UN notification categories |
| `quick/Quick.kt` | Widget and QS tile | WidgetKit + ControlWidget |
| `ui/*` (Compose) | Screens | SwiftUI (see the screenshots) |
| `brand/*`, `src/kia/*` | Kia wording, defaults (80/8/24 h) and colours (Midnight `#05141F`, cyan `#5CE1E6`) | Constants in the app target |

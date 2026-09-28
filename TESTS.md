# Tests to port

These are all the unit tests in the Android core (`reference-source/tests/`), 195 in total. Each name says the behaviour it pins down. Porting the ones marked **port** to XCTest gives you an executable spec for the Swift core. **Skip** means the test is Škoda-only.

## `api/HeaderAndErrorTest.kt` — skip (Škoda), except the last one (VIN masking), which is port

- parses rate limit headers
- tolerates policy suffixes and epoch resets
- missing headers are null
- parses retry-after as seconds or date
- parses key expiry in several formats
- maps auth errors
- maps unsupported and disabled operations
- tells the two 429s apart
- maps everything else
- messages are readable
- masks all but the last four characters

## `api/RateBudgetTest.kt` — port

- fresh budget keeps four for manual commands
- automation never uses more than limit minus four in a window
- the cap holds with server headers too
- manual use eats into what automation may use
- server remaining wins over local counting
- requests sent after the last headers are subtracted
- window resets after the reset time
- rolling window without headers
- 401 and 403 do not count
- 5xx responses count
- 429 marks the budget exhausted until reset
- 429 without headers waits a full window
- vehicle busy 429 does not exhaust the budget
- limit comes from headers and the fallback is configurable
- old history is pruned
- ticket ids are unique
- compute is pure

## `api/SkodaClientTest.kt` — skip (Škoda)

- reads vehicle state and sends the key
- partial 200 marks missing sections unknown, not failed
- start sends target temperature rounded to half a degree
- stop posts to the stop command
- 401 key expired
- 403 key not authorised
- 422 operation not supported
- 429 rate limit honours retry-after and exhausts the budget
- 429 vehicle not accepting requests
- 5xx counts against the budget
- network failure is reported and still counted
- unreadable body is a bad response
- no credentials means no request
- exhausted automation budget refuses without a request

## `api/VehicleMapperTest.kt` — skip (Škoda)

- climate states
- plug state from charging state
- fahrenheit targets are converted
- finds an outside temperature field if the car ever reports one
- range and charging details
- parked or moving
- empty response is all unknown
- fake car behaves like the real API
- fake car scenarios produce the matching errors
- fake car enforces its own limit

## `api/kia/KiaClientTest.kt` — port

- first read logs in, registers, picks the EV and reads cached status and parked position
- later reads reuse the session and cost one budget slot each
- a rotated refresh token is kept and the access token is renewed before it expires
- entering a different token starts a new session
- a rejected refresh token stops automation and does not count against the budget
- an expired access token is refreshed once and the call retried
- a login that keeps failing after a refresh is an auth failure
- a dropped device id is re-registered once
- a VIN picks that car and an unknown VIN is reported
- missing credentials make no request
- Kia's request limit blocks the budget for an hour
- a busy car is reported as not accepting requests
- unsupported control and server errors are mapped
- a failed parked-position read still returns the status
- start and stop climate on an older car
- CCS2 cars map the new status format
- CCS2 climate needs the PIN and uses a control token
- a wrong PIN is an auth failure
- stamp is the app id and time XORed with the fixed key
- temperature codes round trip

## `engine/KiaEngineTest.kt` — port

- leaving the office on a cold evening heats the Kia
- guards still apply to the Kia
- the rule stays quiet when the phone is not with the car
- a rejected Kia login stops automation with Kia instructions
- a busy car is retried later rather than failing the rule
- manual stop reaches the car

## `engine/PreconditionEngineTest.kt` — port (runs against the fake Škoda; the rules and engine behaviour is the same for Kia — adapt it to FakeKia)

- leaving the office on a cold weekday evening starts heating
- first vehicle response is logged once with the VIN masked
- no command when SoC is below the minimum
- no command when climate is already on
- no command while a cooldown is active
- automation never uses more than limit minus four in a window
- an expired API key stops automation and notifies
- a key rejected on the command also stops automation
- unsupported operation disables the rule
- vehicle busy retries once then gives up
- network failure asks for a backoff retry until the last attempt
- network failure on the last attempt is final
- three consecutive failures pause automation
- repeated geofence events within five minutes are ignored
- stale triggers are abandoned
- skipped rules cost no requests when cheap checks fail
- fresh cache saves the state read
- test now evaluates without sending
- manual start ignores cooldowns but not the SoC guard
- manual commands respect the rate budget
- manual failures are reported
- stop rules stop climatisation
- leaving work is skipped when the phone is not with the car
- morning commute is skipped on holiday with the car at home
- car position is refreshed only when a near-car rule needs it
- position refresh leaves room for a precondition cycle and respects a stop
- failed position refresh is logged
- approaching the car fires its rule
- warns once when the key expires within seven days

## `rules/GeofencesTest.kt` — port

- registers only what enabled rules need
- maps fired geofences back to events
- round trip from rule to event matches the rule

## `rules/NearCarTest.kt` — port

- near-car rules register a fence around the parked car
- car fence events map back to the trigger
- describes, validates and serialises
- weather for a near-car rule uses the car's position
- passes when the phone is near the car
- fails when the phone is elsewhere
- unknown phone location fails without reading the car
- unknown car position is unknown
- describes and validates
- fires when cold or hot, not in between
- describes, validates and serialises
- below and above on the same source is rejected as impossible

## `rules/RuleEvaluatorTest.kt` — port

- leaving work fires on a cold weekday evening
- leaving work is skipped outside its time window without reading the car
- leaving work is skipped at the weekend
- leaving work is skipped when it is not cold
- morning commute uses the forecast at departure time
- forecast time more than an hour past means tomorrow
- morning commute is skipped when the car is not at home
- hot day cools when weather at the car is above 24
- low state of charge blocks start
- low state of charge is fine when plugged in
- unknown state of charge blocks start even when the rule proceeds on unknowns
- custom minimum SoC is respected
- already running blocks start
- unknown climate state blocks start
- unavailable vehicle state blocks every action
- stop needs climatisation to be running and ignores SoC
- rule cooldown blocks without reading the car
- rule cooldown expires
- global cooldown blocks every rule
- global cooldown uses the configured length
- rate budget must cover the read and the command
- a fresh cache means one request is enough
- paused automation skips everything
- holidays skip everything
- only enabled rules for this trigger are considered
- highest priority wins and lower rules are not evaluated
- a failing higher rule falls through to the next
- equal priorities are ordered by name
- approaching and entering triggers match their own events
- schedule triggers match only on their days
- dry runs can ignore the trigger
- unknown temperature fails unless the rule proceeds on unknowns
- weather is checked before the car is read when the place gives a location
- weather uses the cached car position when there is one
- place centre is used when the place has no usual parking spot
- schedule rules without a place read the car for its position
- schedule rules without any location have unknown weather
- best available prefers the car's own sensor
- best available falls back to weather
- best available skips the read when the cache shows no car sensor
- car outside temperature unknown when the car does not report it
- cabin sensor is used when in range
- soc and plug conditions
- car at place is unknown without a parking position and fails for a deleted place
- time windows can wrap past midnight
- a rule with no conditions fires on guards alone

## `rules/RuleJsonTest.kt` — port

- export and import round-trip
- export uses readable times and days
- hand-written rules accept full day names
- invalid rules are reported individually and the rest imported
- rules may refer to places already on the phone
- invalid places are reported
- broken files are reported
- templates are valid
- catches every kind of problem
- validates places
- next occurrence later today
- next occurrence skips the weekend
- exactly at the time means the next one
- one day a week wraps to next week
- no days never fires
- soonest check across enabled rules
- a time in the spring-forward gap moves forward
- describes triggers, events, conditions and actions
- trigger helpers
- distance and containment

## `weather/FakeWeatherTest.kt` — port

- fake weather serves the simulator temperature
- router routes by host and passes through when off

## `weather/WeatherRepositoryTest.kt` — port

- current temperature and request parameters
- forecast interpolates between hours
- cached for 15 minutes per location
- failures return null and are remembered
- missing values are unknown

Shared fixtures: `tests/rules/TestFixtures.kt` (Prague zone, a Wednesday clock, the Office and Home places, a `rule(...)` builder) and `tests/api/ApiTestSupport.kt` (a mutable clock, in-memory budget store, a recording meta sink).

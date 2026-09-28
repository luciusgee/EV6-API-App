# PreconditionKit

The iPhone app's platform-free core: the Swift package described in HANDOVER.md §2. It has no UIKit, SwiftUI or CoreLocation, so everything in it is tested with plain XCTest on a Mac or on Linux.

```
swift test            # from this folder; 69 tests
```

## What's here (milestone 1: Kia and dashboard)

| File | Ports | Notes |
| --- | --- | --- |
| `Kia/KiaClient.swift` | `api/kia/KiaClient.kt` | Login (refresh token), device registration, vehicle choice, cached status + parked position, climate start/stop for both protocols, CCS2 control token via PIN, the retry-once rules and the §3.9 error table |
| `Kia/KiaMapper.swift` | `api/kia/KiaMapper.kt` | Both status formats → `VehicleSnapshot`; temperature codes; Berlin/UTC timestamps |
| `Kia/KiaConfig.swift`, `KiaSession.swift` | same | Constants, `Stamp` header, the session (store it in the Keychain) |
| `Kia/FakeKia.swift` | `api/kia/FakeKia.kt`, `FakeRouter.kt` | Fake car for fake-car mode, previews and tests, with the same error scenarios |
| `API/RateBudget.swift` | `api/RateBudget.kt` | 80 per rolling 24 h, 8 kept for manual; `5091` blocks everything for an hour |
| `API/ApiError.swift`, `ApiTypes.swift` | `api/ApiError.kt`, `SkodaClient.kt` (shared types) | `VehicleAPI`, `ApiResult`, `Credentials`, `RequestKind` |
| `API/HTTP.swift` | — | `HTTPTransport` (see below), `URLSessionTransport`, `RoutingTransport` |
| `Model/` | `rules/Inputs.kt`, `Guards.kt`, `Model.kt` (`LatLon`, `Place`), `maskVin`/`redactVin` | |

The tests port `KiaClientTest` (all 20 cases) and `RateBudgetTest`, and check the client's climate payloads, the mapper and the `Place` JSON against the files in `../fixtures/`.

## Differences from the Android code

- **HTTP goes through `HTTPTransport`**, a one-method protocol, instead of OkHttp interceptors or a `URLProtocol`. The app passes `URLSessionTransport`, or `RoutingTransport.kia(live:fake:)` so a Developer switch can flip `fakeMode`. Tests pass a scripted transport.
- **Kia only.** The Škoda client, header parsing and error mapper aren't ported. `RateBudget` counts locally (Kia sends no rate headers), `ApiError` drops the Škoda-only cases, and `VehicleSnapshot` drops the Škoda-only fields.
- `Credentials.apiKey` is called `refreshToken`, and `startClimate` has no `withoutExternalPower` flag (Kia ignored it).
- Times are `Date`s rather than epoch milliseconds.

## Using it from the app

```swift
let fakeCar = FakeKia()
let transport = RoutingTransport.kia(live: URLSessionTransport(), fake: fakeCar)
let budget = RateBudget(store: budgetFileStore)            // your RateBudgetStore (a JSON file)
let kia = KiaClient(
    transport: transport,
    budget: budget,
    credentials: keychainCredentials,                     // your CredentialsProvider (Keychain)
    sessions: keychainSessions,                           // your KiaSessionStore (Keychain; a separate slot in fake mode)
    metaSink: apiMonitor
)
let result = await kia.getVehicle(.manual)
```

## Next

The app target itself (Settings with the token, PIN and VIN in the Keychain; the dashboard; manual Refresh/Start/Stop; the log) needs Xcode on a Mac. After that comes milestone 2: rules, JSON import/export, the validator and evaluator, and Open-Meteo.

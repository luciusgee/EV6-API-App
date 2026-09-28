# PreconditionKit

The iPhone app's platform-free core: the Swift package described in HANDOVER.md §2. It has no UIKit, SwiftUI or CoreLocation, so everything in it is tested with plain XCTest on a Mac or on Linux.

```
swift test            # from this folder; 102 tests
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
| `Engine/PreconditionEngine.swift` | `engine/PreconditionEngine.kt` (manual path) | Manual start/stop with the SoC guard and budget, dashboard refresh, resume. Rule evaluation joins it in milestone 2 |
| `Engine/VehicleRepository.swift` | `engine/VehicleRepository.kt`, `ApiMonitor.kt` | 10-minute cache, first response logged once (VIN masked); a rejected login stops automation, the next success resumes it |
| `Engine/Ports.swift`, `FileStores.swift`, `AppSettings.swift` | `engine/Ports.kt` | Log (30 days / 2,000 entries, CSV), automation state, JSON file stores, settings, fake-mode switching |
| `App/CarModel.swift`, `AppContainer.swift`, `DisplayText.swift` | the Android view models | The `@Observable` model behind the screens, the object graph, and the dashboard's texts |
| `Model/` | `rules/Inputs.kt`, `Guards.kt`, `Model.kt` (`LatLon`, `Place`), `maskVin`/`redactVin` | |

The tests port `KiaClientTest` (all 20 cases) and `RateBudgetTest`, and check the client's climate payloads, the mapper and the `Place` JSON against the files in `../fixtures/`.

## Differences from the Android code

- **HTTP goes through `HTTPTransport`**, a one-method protocol, instead of OkHttp interceptors or a `URLProtocol`. The app passes `URLSessionTransport`, or `RoutingTransport.kia(live:fake:)` so a Developer switch can flip `fakeMode`. Tests pass a scripted transport.
- **Kia only.** The Škoda client, header parsing and error mapper aren't ported. `RateBudget` counts locally (Kia sends no rate headers), `ApiError` drops the Škoda-only cases, and `VehicleSnapshot` drops the Škoda-only fields.
- `Credentials.apiKey` is called `refreshToken`, and `startClimate` has no `withoutExternalPower` flag (Kia ignored it).
- Times are `Date`s rather than epoch milliseconds.

## Using it from the app

```swift
let container = AppContainer(
    directory: applicationSupport,
    credentials: KeychainCredentialsStore(),               // CredentialsStore
    sessions: KeychainSessionStore(account: "kia-session"),
    fakeSessions: KeychainSessionStore(account: "kia-session-fake"),
    notifier: LocalNotifier()
)
let model = CarModel(container: container)                 // @Observable, for the SwiftUI environment
await model.load()
```

The app target (`../EV6Precondition`) adds only what needs iOS: the Keychain stores, notifications with a Stop action, and the SwiftUI views. See the root README for building it.

## Next

Milestone 2: rules, JSON import/export, the validator and evaluator, Open-Meteo, the dry run, and the schedule App Intent.

import Foundation

/// Where the app keeps the Kia Connect credentials: the Keychain on iOS.
public protocol CredentialsStore: CredentialsProvider {
    func save(_ credentials: Credentials?) async
}

public actor InMemoryCredentialsStore: CredentialsStore {
    public private(set) var value: Credentials?
    public init(_ value: Credentials? = nil) { self.value = value }
    public func credentials() -> Credentials? { value }
    public func save(_ credentials: Credentials?) { value = credentials }
}

/// Builds the object graph once. The app passes in the platform pieces (Keychain stores, notifications,
/// the network); everything else is the kit's.
public final class AppContainer: Sendable {
    public let stores: FileStores
    public let credentials: CredentialsStore
    public let fakeCar: FakeKia
    public let transport: RoutingTransport
    public let budget: RateBudget
    public let client: KiaClient
    public let vehicles: VehicleRepository
    public let engine: PreconditionEngine
    public let monitor: ApiMonitor
    public let time: TimeSource

    /// - Parameters:
    ///   - directory: for the non-secret JSON files, e.g. Application Support.
    ///   - sessions: the real Kia session (Keychain).
    ///   - fakeSessions: a separate slot for fake-car mode.
    public init(
        directory: URL,
        credentials: CredentialsStore,
        sessions: KiaSessionStore,
        fakeSessions: KiaSessionStore,
        notifier: Notifier,
        live: HTTPTransport = URLSessionTransport(),
        time: TimeSource = SystemTime(),
        config: KiaConfig = KiaConfig()
    ) {
        let stores = FileStores(directory: directory, time: time)
        let fakeCar = FakeKia(time: time, config: config)
        let transport = RoutingTransport.kia(live: live, fake: fakeCar, config: config)
        let isFake: @Sendable () -> Bool = { transport.fakeMode }
        let settings = stores.settings
        let budget = RateBudget(store: stores.budget, time: time, config: { await settings.load().budgetConfig })
        let modeCredentials = ModeAwareCredentials(real: credentials, isFake: isFake)
        let monitor = ApiMonitor(state: stores.automationState, notifier: notifier, log: stores.log, time: time)
        let client = KiaClient(
            transport: transport,
            budget: budget,
            credentials: modeCredentials,
            sessions: ModeAwareSessionStore(real: sessions, fake: fakeSessions, isFake: isFake),
            metaSink: monitor,
            time: time,
            config: config
        )
        let vehicles = VehicleRepository(
            client: client, cache: stores.vehicleCache, state: stores.automationState,
            credentials: modeCredentials, log: stores.log, time: time
        )
        self.stores = stores
        self.credentials = credentials
        self.fakeCar = fakeCar
        self.transport = transport
        self.budget = budget
        self.client = client
        self.vehicles = vehicles
        self.monitor = monitor
        self.time = time
        self.engine = PreconditionEngine(
            client: client, vehicles: vehicles, budget: budget, state: stores.automationState,
            settings: stores.settings, log: stores.log, notifier: notifier, time: time
        )
    }

    /// Call once at launch, before the first request.
    public func start() async {
        transport.fakeMode = await stores.settings.load().fakeMode
    }
}

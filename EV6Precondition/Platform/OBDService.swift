import Foundation
import PreconditionKit
import UIKit

/// One OBD connection for the whole app: the adapter (or the simulated car), the ELM327 session on top,
/// and a single live-data loop that the gauges, graphs, recording, trip computer, charge recorder and
/// timers all read.
@MainActor
@Observable
final class OBDService {
    enum CarState: Equatable {
        case disconnected
        case connecting
        case connected
        /// The adapter answers but the car doesn't (switched off, or no OBD-II).
        case noAnswer(String)
    }

    let link = OBDLink()
    private(set) var carState: CarState = .disconnected
    private(set) var adapterVersion: String?
    private(set) var elm: ELM327?

    // Live data
    private(set) var live = false
    private(set) var latest: [String: Double] = [:]
    /// Recent readings per sensor, oldest first (about 5 minutes at full speed).
    private(set) var history: [String: [(Date, Double)]] = [:]
    private(set) var samplesPerSecond: Double = 0
    private(set) var recording: DataRecording?
    private(set) var recordings: [URL] = []
    var trip: TripComputer?
    /// The performance run under way, fed every speed reading.
    var run: RunTimer?
    /// Feels the car pull away, for sharper standing starts.
    let motion = MotionLaunch()
    /// The simulated car, in demo mode.
    private(set) var demo: FakeOBDAdapter?
    /// What the car said about itself when it connected.
    private(set) var vin: VIN?
    /// Its battery answered like an E-GMP car.
    private(set) var answersEGMP = false
    /// Standard PIDs the car supports, for cars read with standard OBD-II.
    private(set) var supportedPIDs: Set<UInt8> = []
    /// The charge being recorded, while the car charges.
    private(set) var charge: ChargeSession?
    @ObservationIgnored private var notChargingSince: Date?
    private let prefs = Preferences.shared
    private var wanted: [String: Set<String>] = [:]
    private var loop: Task<Void, Never>?

    static let historyLimit = 1500

    init() {
        loadRecordings()
        link.onReady = { [weak self] in
            Task { await self?.adapterReady() }
        }
    }

    var adapterConnected: Bool { link.isReady || demo != nil }

    var adapterText: String {
        if demo != nil { return "Demo car" }
        switch link.state {
        case .idle: return "Disconnected"
        case .bluetoothOff: return "Bluetooth off"
        case .bluetoothDenied: return "Bluetooth not allowed"
        case .scanning: return "Searching…"
        case .connecting(let name): return "Connecting to \(name)…"
        case .ready(let name): return name
        case .failed(let reason): return reason
        }
    }

    var carText: String {
        switch carState {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .noAnswer(let why): return why
        }
    }

    // MARK: Connection

    /// Starts the ELM327 session once the adapter is up, and checks the car answers.
    func adapterReady() async {
        guard link.isReady else { return }
        demo = nil
        await start(transport: OBDLinkTransport(link: link))
    }

    private func start(transport: OBDTransport) async {
        let elm = ELM327(transport: transport)
        self.elm = elm
        carState = .connecting
        do {
            try await elm.initialise()
            adapterVersion = await elm.adapterVersion
            await identify(elm)
        } catch {
            carState = .noAnswer((error as? OBDError)?.description.capitalizingFirst ?? error.localizedDescription)
        }
    }

    /// Works out what the car is: an E-GMP battery, or standard OBD-II, and its VIN. With auto-detect on,
    /// switches the chosen car to match.
    private func identify(_ elm: ELM327) async {
        let diagnostics = Diagnostics(elm: elm)
        answersEGMP = await elm.ping(EGMP.bms)
        supportedPIDs = []
        if !answersEGMP { supportedPIDs = await diagnostics.supportedPIDs() }
        guard answersEGMP || !supportedPIDs.isEmpty else {
            carState = .noAnswer("No answer: switch the car on")
            return
        }
        vin = await diagnostics.vin().flatMap(VIN.init)
        if let vin { prefs.vin = vin.text }
        if prefs.autoDetect {
            let current = prefs.model
            let makeMatches = vin?.make == nil || current.make == vin?.make
            if current.platform != (answersEGMP ? .egmp : .generic) || !makeMatches {
                prefs.modelId = Vehicles.guess(vin: vin, egmp: answersEGMP, cells: nil).id
                prefs.packKWh = nil
            }
        }
        carState = .connected
        restartIfNeeded()
    }

    /// Checks again whether the car answers (after switching it on).
    func retryCar() async {
        guard let elm else { return await adapterReady() }
        carState = .connecting
        await identify(elm)
    }

    /// The sensors this car can be asked for.
    var sensors: [Sensor] {
        let all = prefs.platform.sensors
        guard prefs.platform == .generic, !supportedPIDs.isEmpty else { return all }
        return all.filter { GenericSensors.pidNumber($0).map(supportedPIDs.contains) ?? true }
    }

    func sensor(_ id: String) -> Sensor? { prefs.platform.sensor(id) }

    /// A simulated EV6 instead of a real car, to try everything without an adapter.
    func startDemo() {
        disconnect()
        let fake = FakeOBDAdapter()
        demo = fake
        Task { await start(transport: fake) }
    }

    /// In demo mode, drives the simulated car to suit the run.
    func demoDrive(for type: RunType?) {
        guard let demo else { return }
        guard let type else {
            demo.car.drive = .parked
            return
        }
        demo.car.drive = type.category == .braking ? .brakeTest(since: Date().addingTimeInterval(1)) : .launch(since: Date().addingTimeInterval(2))
    }

    func disconnect() {
        finishCharge()
        stopLive()
        demo = nil
        link.disconnect()
        elm = nil
        carState = .disconnected
    }

    /// The remembered adapter, else nothing (the caller shows the picker).
    func connect() -> Bool {
        return link.reconnect()
    }

    // MARK: Live data

    /// Screens say which sensors they need; the loop reads the union of everyone's wishes.
    func want(_ ids: [String], for screen: String) {
        wanted[screen] = Set(ids)
        restartIfNeeded()
    }

    func release(_ screen: String) {
        wanted[screen] = nil
        if wanted.isEmpty { stopLive() } else { restartIfNeeded() }
    }

    private var wantedSensors: [Sensor] {
        let ids = wanted.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        return sensors.filter { ids.contains($0.id) }
    }

    private func restartIfNeeded() {
        guard let elm, carState == .connected, !wantedSensors.isEmpty else { return }
        let sensors = wantedSensors
        if let loop, !loop.isCancelled {
            // Same loop, new sensor list.
            pollerSensors = sensors
            return
        }
        live = true
        UIApplication.shared.isIdleTimerDisabled = true
        let poller = LivePoller(elm: elm, sensors: sensors)
        pollerSensors = sensors
        loop = Task { [weak self] in
            var times: [Date] = []
            var applied: [Sensor] = sensors
            while !Task.isCancelled {
                guard let self else { return }
                if applied != self.pollerSensors {
                    applied = self.pollerSensors
                    await poller.setSensors(applied)
                }
                do {
                    let sample = try await poller.poll()
                    self.apply(sample)
                    times.append(sample.at)
                    times = times.filter { sample.at.timeIntervalSince($0) < 3 }
                    self.samplesPerSecond = Double(times.count) / 3
                } catch {
                    self.carState = .noAnswer((error as? OBDError)?.description.capitalizingFirst ?? "Connection lost")
                    self.stopLive()
                    return
                }
                // Leave a gap for other requests (trouble codes, identifiers).
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
    }

    @ObservationIgnored private var pollerSensors: [Sensor] = []

    func stopLive() {
        loop?.cancel()
        loop = nil
        live = false
        samplesPerSecond = 0
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func apply(_ sample: LiveSample) {
        latest.merge(sample.values) { $1 }
        for (id, v) in sample.values {
            var h = history[id, default: []]
            h.append((sample.at, v))
            if h.count > Self.historyLimit { h.removeFirst(h.count - Self.historyLimit) }
            history[id] = h
        }
        recording?.add(sample)
        if trip != nil {
            trip?.add(at: sample.at, kmh: sample.values["speed"], powerKW: sample.values["power"])
        }
        if run != nil, let kmh = sample.values["speed"] {
            run?.add(at: sample.at, kmh: kmh, powerKW: sample.values["power"] ?? latest["power"], launchedAt: motion.launchedAt)
        }
        recordCharge(sample)
    }

    /// Starts a charge session when the battery takes power standing still, and saves it a minute after
    /// the power stops.
    private func recordCharge(_ sample: LiveSample) {
        guard let packKW = sample.values["power"] else { return }
        if ChargeSession.isCharging(packKW: packKW, kmh: latest["speed"]) {
            notChargingSince = nil
            if charge == nil { charge = ChargeSession(started: sample.at) }
            charge?.add(at: sample.at, packKW: packKW, socPercent: latest["socBMS"], batteryMaxC: latest["battMax"], batteryMinC: latest["battMin"])
        } else if charge != nil {
            let since = notChargingSince ?? sample.at
            notChargingSince = since
            if sample.at.timeIntervalSince(since) > 60 { finishCharge() }
        }
    }

    func finishCharge() {
        if let charge, charge.energyKWh > 0.05 { ChargeStore.shared.add(charge) }
        charge = nil
        notChargingSince = nil
    }

    // MARK: Recording

    func startRecording(_ ids: [String]) {
        recording = DataRecording(started: Date(), sensorIds: ids)
        want(ids, for: "recording")
    }

    /// Saves the CSV and returns its file.
    @discardableResult
    func stopRecording() -> URL? {
        defer {
            recording = nil
            release("recording")
        }
        guard let recording, !recording.samples.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "yyyy-MM-dd HHmmss"
        let url = Self.recordingsFolder.appendingPathComponent("Recording \(f.string(from: recording.started)).csv")
        try? FileManager.default.createDirectory(at: Self.recordingsFolder, withIntermediateDirectories: true)
        try? recording.csv(sensors: sensors).write(to: url, atomically: true, encoding: .utf8)
        loadRecordings()
        return url
    }

    func deleteRecording(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        loadRecordings()
    }

    private func loadRecordings() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.recordingsFolder, includingPropertiesForKeys: nil)) ?? []
        recordings = files.filter { $0.pathExtension == "csv" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static let recordingsFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Recordings", isDirectory: true)
}

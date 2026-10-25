import Foundation
import Observation
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
    @ObservationIgnored private var chargeSavedAt: Date?
    /// A charge left unfinished when the app last stopped, until a car connects or the store is ready.
    @ObservationIgnored private var recoveredCharge: ChargeSession?
    /// The car stopped answering while the loop kept polling (the loop set `.noAnswer`).
    @ObservationIgnored private var quiet = false
    private let prefs = Preferences.shared
    private var wanted: [String: Set<String>] = [:]
    private var loop: Task<Void, Never>?
    /// Which loop is current, so a cancelled one can't write over a newer one.
    @ObservationIgnored private var loopToken = 0

    static let historyLimit = 1500
    /// No answer from any module for this long, while polling, means the car went to sleep.
    static let quietAfter: TimeInterval = 5
    /// A charge that resumes after a gap this long is a new session, whatever the car says. Shorter gaps
    /// (the phone locked, the adapter dropped) carry on with the same charge if the car's data agrees.
    static let chargeGap: TimeInterval = 3 * 3600

    init() {
        loadRecordings()
        // The app was stopped while the demo ran: put the user's own car back.
        restoreAfterDemo()
        recoveredCharge = Self.loadChargeInProgress()
        link.onReady = { [weak self] in
            Task { await self?.adapterReady() }
        }
        watchLink()
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.saveChargeInProgress(force: true)
                    self?.flushRecording(sync: true)
                }
            }
        }
    }

    /// Hears when the adapter goes (unplugged, out of range, or disconnected from the picker).
    private func watchLink() {
        withObservationTracking {
            _ = link.state
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.watchLink()
                if !self.link.isReady { self.linkLost() }
            }
        }
    }

    /// The adapter went away: end the session as if the user had disconnected, but keep a charge under
    /// way waiting for the car to come back.
    private func linkLost() {
        guard demo == nil, !link.isReady, elm != nil || carState != .disconnected else { return }
        endSession()
        carState = .disconnected
    }

    /// Stops everything the current session runs and forgets what that car said. A charge under way is
    /// kept on disk and carried on when the car next connects (see `recoverCharge`).
    private func endSession() {
        suspendCharge()
        stopLive()
        elm = nil
        latest = [:]
        history = [:]
        samplesPerSecond = 0
        vin = nil
        answersEGMP = false
        supportedPIDs = []
        adapterVersion = nil
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
        if demo != nil {
            endSession()
            restoreAfterDemo()
            demo = nil
        }
        await start(transport: OBDLinkTransport(link: link))
    }

    private func start(transport: OBDTransport) async {
        // Nothing from an earlier session (the demo car, or this adapter before) carries over.
        endSession()
        let elm = ELM327(transport: transport)
        self.elm = elm
        carState = .connecting
        do {
            try await elm.initialise()
            guard self.elm === elm else { return }
            adapterVersion = await elm.adapterVersion
            guard self.elm === elm else { return }
            await identify(elm)
        } catch {
            guard self.elm === elm else { return }
            carState = .noAnswer((error as? OBDError)?.description.capitalizingFirst ?? error.localizedDescription)
        }
    }

    /// What the battery management system said to 22 0101.
    private enum BMSAnswer { case egmp, other, silent }

    /// Makers with E-GMP cars.
    private static let egmpMakes = Set(Vehicles.all.filter { $0.platform == .egmp }.map(\.make))

    /// Reads the BMS's main page a few times (it can miss requests just after waking). E-GMP only when
    /// the answer is full length with an 800 V-class pack voltage: older Hyundai/Kia EVs and hybrids also
    /// have a BMS at 0x7E4, but refuse this request or answer with a lower voltage.
    private func probeBMS(_ elm: ELM327) async -> BMSAnswer {
        for _ in 0..<3 {
            do {
                let d = try await elm.read(EGMP.bmsMain)
                guard d.count >= 50 else { return .other }
                let volts = Double(Int(d[12]) << 8 | Int(d[13])) / 10
                return (420...900).contains(volts) ? .egmp : .other
            } catch OBDError.rejected(_) {
                return .other
            } catch OBDError.notConnected {
                return .silent
            } catch {
                continue
            }
        }
        return .silent
    }

    /// The VIN from mode 09, else from the modules' UDS identifier (some E-GMP cars don't answer 09 02).
    private func readVIN(_ elm: ELM327, _ diagnostics: Diagnostics) async -> VIN? {
        if let vin = await diagnostics.vin().flatMap(VIN.init) { return vin }
        for header: UInt16 in [EGMP.bms, 0x7E2, EGMP.bcm] {
            if let d = try? await elm.read(OBDRequest(header: header, did: 0xF190)),
               let vin = VIN(String(decoding: d, as: UTF8.self)) { return vin }
        }
        return nil
    }

    /// How many cells the BMS reports, to tell packs (and so models) apart.
    private func cellCount(_ elm: ELM327) async -> Int? {
        var n = 0
        for (request, _) in EGMP.cellBlocks {
            if let d = try? await elm.read(request) { n += EGMP.cells(d).count }
        }
        return n > 0 ? n : nil
    }

    /// Works out what the car is: an E-GMP battery, or standard OBD-II, and its VIN. With auto-detect on,
    /// switches the chosen car to match. `allowSearch` always tries the other OBD-II protocols when 11-bit
    /// 500k CAN is silent (an explicit retry, with the car switched on).
    private func identify(_ elm: ELM327, allowSearch: Bool = false) async {
        let diagnostics = Diagnostics(elm: elm)
        let bms = await probeBMS(elm)
        guard self.elm === elm else { return }
        answersEGMP = bms == .egmp
        supportedPIDs = []
        if !answersEGMP {
            supportedPIDs = await diagnostics.supportedPIDs()
            guard self.elm === elm else { return }
            // A BMS that answered (or refused) shows the 11-bit 500k bus is alive, so a search would only add
            // seconds. The saved car is no proof (it defaults to an EV6, and the adapter may have moved to
            // another car): it skips the search only with auto-detect off, and never on an explicit retry.
            let knownCAN = bms == .other
                || (!allowSearch && !prefs.autoDetect && prefs.model.platform == .egmp)
            if supportedPIDs.isEmpty, !knownCAN {
                // Not 11-bit 500k CAN: let the adapter search the other OBD-II protocols (ISO 9141, KWP2000,
                // J1850, 29-bit and 250k CAN). It can take ten seconds or more.
                do {
                    _ = try await elm.searchProtocol()
                    guard self.elm === elm else { return }
                    supportedPIDs = await diagnostics.supportedPIDs()
                    guard self.elm === elm else { return }
                } catch {
                    guard self.elm === elm else { return }
                    if self.demo == nil && !link.isReady { return linkLost() }
                    carState = .noAnswer((error as? OBDError)?.description.capitalizingFirst ?? error.localizedDescription)
                    return
                }
            }
        }
        guard answersEGMP || !supportedPIDs.isEmpty else {
            carState = .noAnswer("No answer: switch the car on")
            return
        }
        vin = await readVIN(elm, diagnostics)
        guard self.elm === elm else { return }
        if answersEGMP, let make = vin?.make, !Self.egmpMakes.contains(make) {
            // An E-GMP-looking battery in another maker's car: read it as standard OBD-II.
            answersEGMP = false
            supportedPIDs = await diagnostics.supportedPIDs()
            guard self.elm === elm else { return }
        }
        let storedVIN = prefs.vin
        // A car that gives no (valid) VIN doesn't keep the last car's VIN and year.
        prefs.vin = vin?.text
        if prefs.autoDetect {
            let current = prefs.model
            let detected: Platform = answersEGMP ? .egmp : .generic
            let makeMatches = vin?.make == nil || current.make == vin?.make
            // A battery that didn't answer at all is no proof: keep a chosen E-GMP car when the VIN says
            // it's this car or one of its makers.
            let keep = bms == .silent && current.platform == .egmp
                && (vin.map { Self.egmpMakes.contains($0.make ?? "") || $0.text == storedVIN } ?? false)
            if !keep, current.platform != detected || !makeMatches {
                var cells: Int?
                if answersEGMP { cells = await cellCount(elm) }
                guard self.elm === elm else { return }
                prefs.modelId = Vehicles.guess(vin: vin, egmp: answersEGMP, cells: cells).id
                prefs.packKWh = nil
            }
        }
        carState = .connected
        if demo == nil { recoverCharge() }
        restartIfNeeded()
    }

    /// Checks again whether the car answers (after switching it on).
    func retryCar() async {
        guard carState != .connecting else { return }
        guard let elm else { return await adapterReady() }
        // The adapter itself is gone: say so rather than blaming the car.
        guard demo != nil || link.isReady else { return linkLost() }
        carState = .connecting
        do {
            // A failed start leaves the adapter in its power-on settings.
            try await elm.initialiseIfNeeded()
        } catch {
            guard self.elm === elm else { return }
            carState = .noAnswer((error as? OBDError)?.description.capitalizingFirst ?? error.localizedDescription)
            return
        }
        guard self.elm === elm else { return }
        await identify(elm, allowSearch: true)
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
        saveForDemo()
        // The demo is an EV6 even with detection off and another car chosen (put back after).
        prefs.modelId = "kia.ev6"
        prefs.packKWh = nil
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
        // The user ended it: a charge under way is finished now, not kept for the next connection.
        finishCharge()
        endSession()
        if demo != nil { restoreAfterDemo() }
        demo = nil
        link.disconnect()
        carState = .disconnected
    }

    // MARK: Demo

    private static let demoRestoreKey = "demoRestorePrefs"

    /// The demo identifies as a Kia EV6 with its own VIN; remember the user's car to put back after.
    private func saveForDemo() {
        var saved: [String: Any] = ["modelId": prefs.modelId]
        if let pack = prefs.packKWh { saved["packKWh"] = pack }
        if let vin = prefs.vin { saved["vin"] = vin }
        UserDefaults.standard.set(saved, forKey: Self.demoRestoreKey)
    }

    private func restoreAfterDemo() {
        guard let saved = UserDefaults.standard.dictionary(forKey: Self.demoRestoreKey) else { return }
        UserDefaults.standard.removeObject(forKey: Self.demoRestoreKey)
        if let modelId = saved["modelId"] as? String { prefs.modelId = modelId }
        prefs.packKWh = saved["packKWh"] as? Double
        prefs.vin = saved["vin"] as? String
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
        let chosen = sensors.filter { ids.contains($0.id) }
        // Speed's request goes last, so a round's time is when the speed reading came in (runs and the
        // motion launch time from it), not one module's round trip later.
        guard let speed = chosen.first(where: { $0.id == "speed" })?.request else { return chosen }
        return chosen.filter { $0.request != speed } + chosen.filter { $0.request == speed }
    }

    private func restartIfNeeded() {
        let sensors = wantedSensors
        guard !sensors.isEmpty else { return }
        if let loop, !loop.isCancelled {
            // Same loop, new sensor list.
            pollerSensors = sensors
            return
        }
        guard let elm, carState == .connected else { return }
        live = true
        ScreenAwake.hold("live")
        let poller = LivePoller(elm: elm, sensors: sensors)
        pollerSensors = sensors
        loopToken += 1
        let token = loopToken
        loop = Task { [weak self] in
            var times: [Date] = []
            var applied: [Sensor] = sensors
            var lastAnswer = Date()
            while !Task.isCancelled {
                guard let self, self.loopToken == token else { return }
                if applied != self.pollerSensors {
                    applied = self.pollerSensors
                    await poller.setSensors(applied)
                }
                do {
                    let sample = try await poller.poll()
                    // Stopped while waiting for the car: this loop no longer speaks for it.
                    guard !Task.isCancelled, self.loopToken == token else { return }
                    self.apply(sample)
                    if sample.values.isEmpty {
                        if sample.at.timeIntervalSince(lastAnswer) > OBDService.quietAfter { self.carWentQuiet() }
                    } else {
                        lastAnswer = sample.at
                        times.append(sample.at)
                        if self.quiet {
                            self.quiet = false
                            if case .noAnswer = self.carState { self.carState = .connected }
                        }
                    }
                    times = times.filter { sample.at.timeIntervalSince($0) < 3 }
                    self.samplesPerSecond = Double(times.count) / 3
                } catch {
                    guard !Task.isCancelled, self.loopToken == token else { return }
                    if self.demo == nil && !self.link.isReady { return self.linkLost() }
                    self.carState = .noAnswer((error as? OBDError)?.description.capitalizingFirst ?? "Connection lost")
                    self.stopLive() // also ends a run under way
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
        loopToken += 1
        live = false
        quiet = false
        samplesPerSecond = 0
        ScreenAwake.release("live")
        // No more readings are coming: a run under way can't finish, so stop its clock.
        if case .running? = run?.state { run?.reset() }
    }

    /// Every module stopped answering (car switched off or asleep): stop showing old readings as live.
    /// The loop keeps asking and goes back to connected when the car answers again.
    private func carWentQuiet() {
        guard !quiet, carState == .connected else { return }
        quiet = true
        carState = .noAnswer("No answer: switch the car on")
        latest = [:]
        // No speed is coming: a run under way can't finish, so stop its clock.
        if case .running? = run?.state { run?.reset() }
    }

    private func apply(_ sample: LiveSample) {
        latest.merge(sample.values) { $1 }
        for (id, v) in sample.values {
            var h = history[id, default: []]
            h.append((sample.at, v))
            if h.count > Self.historyLimit { h.removeFirst(h.count - Self.historyLimit) }
            history[id] = h
        }
        if recording != nil {
            recording?.add(sample)
            if (recording?.pending.count ?? 0) >= Self.recordingFlushRows { flushRecording() }
        }
        if trip != nil {
            trip?.add(at: sample.at, kmh: sample.values["speed"], powerKW: sample.values["power"])
        }
        if run != nil, let kmh = sample.values["speed"] {
            // The time the speed reply itself came in, not the end of the round.
            run?.add(at: sample.time(of: "speed"), kmh: kmh, powerKW: sample.values["power"] ?? latest["power"], launchedAt: motion.launchedAt)
        } else if run != nil {
            // Speed has stopped coming (request backed off, module silent): abandon the attempt once it
            // couldn't be timed anyway, rather than leave the clock counting until a reading turns up.
            run?.tick(now: sample.at)
        }
        recordCharge(sample)
    }

    /// Starts a charge session when the battery takes power standing still, and saves it a minute after
    /// the power stops.
    private func recordCharge(_ sample: LiveSample) {
        let packKW = sample.values["power"]
        if let packKW, ChargeSession.isCharging(packKW: packKW, kmh: latest["speed"]) {
            notChargingSince = nil
            // Charging again after a gap (the app was away, or the car slept): a new charge only if the car
            // says so.
            if let charge, !continues(charge, at: sample.at, socPercent: latest["socBMS"], chargedKWh: sample.values["charged"]) {
                finishCharge()
            }
            if charge == nil { charge = ChargeSession(started: sample.at) }
            charge?.add(
                at: sample.at, packKW: packKW, socPercent: latest["socBMS"], batteryMaxC: latest["battMax"], batteryMinC: latest["battMin"],
                chargedKWh: sample.values["charged"]
            )
            saveChargeInProgress()
        } else if let charge {
            // Not charging, or the battery stopped answering (it sleeps once a charge ends): count from
            // the last charging reading.
            let since = notChargingSince ?? (packKW == nil ? charge.updated : sample.at)
            notChargingSince = since
            if sample.at.timeIntervalSince(since) > 60 { finishCharge() }
        }
    }

    /// Whether a charging reading after a gap belongs to the same charge: not too long after, the battery
    /// no emptier and the car's charged-energy counter not gone backwards.
    private func continues(_ charge: ChargeSession, at: Date, socPercent: Double?, chargedKWh: Double?) -> Bool {
        let gap = at.timeIntervalSince(charge.updated)
        if gap <= 60 { return true }
        if gap > Self.chargeGap { return false }
        if let soc = socPercent, let last = charge.endSoc, soc < last - 1 { return false }
        if let kWh = chargedKWh, kWh > 0, let last = charge.counterLatestKWh, kWh < last - 0.05 { return false }
        return true
    }

    func finishCharge() {
        // The demo car's charges are simulated: never saved as the user's.
        if demo == nil, let charge, charge.energyKWh > 0.05 { ChargeStore.shared.add(charge) }
        charge = nil
        notChargingSince = nil
        chargeSavedAt = nil
        // The file also holds a charge waiting to be recovered: keep it until that's dealt with.
        if recoveredCharge == nil { try? FileManager.default.removeItem(at: Self.chargeInProgressURL) }
    }

    /// The session ends with a charge under way (adapter dropped, new connection): saves it to disk and
    /// leaves it waiting, so the next connection carries on with it rather than starting another.
    private func suspendCharge() {
        guard demo == nil, let charge else { return finishCharge() }
        if let older = recoveredCharge, older.id != charge.id, older.energyKWh > 0.05 { ChargeStore.shared.add(older) }
        saveChargeInProgress(force: true)
        recoveredCharge = charge
        self.charge = nil
        notChargingSince = nil
        chargeSavedAt = nil
    }

    // MARK: Charge in progress

    static let chargeInProgressURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("EV6Precondition/charge-in-progress.json")

    /// Keeps the charge on disk as it goes (every 30 s, and when the app leaves the screen), so it
    /// survives the app being stopped.
    private func saveChargeInProgress(force: Bool = false) {
        guard demo == nil, let charge else { return }
        if !force, let chargeSavedAt, Date().timeIntervalSince(chargeSavedAt) < 30 { return }
        chargeSavedAt = Date()
        guard let data = try? JSONEncoder().encode(charge) else { return }
        let url = Self.chargeInProgressURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func loadChargeInProgress() -> ChargeSession? {
        guard let data = try? Data(contentsOf: chargeInProgressURL) else { return nil }
        return try? JSONDecoder().decode(ChargeSession.self, from: data)
    }

    /// Picks up a charge left unfinished when the app last stopped: carries on with it if it's recent,
    /// else saves it. Call once the charge store has loaded. With `resume` false (at launch, before any
    /// car is connected) a recent charge is left waiting for the car rather than resumed, since starting a
    /// session finishes whatever charge is under way.
    func recoverCharge(resume: Bool = true) {
        guard let recovered = recoveredCharge else { return }
        let recent = Date().timeIntervalSince(recovered.updated) < Self.chargeGap
        if recent && !resume { return }
        recoveredCharge = nil
        if charge == nil, recent {
            charge = recovered
            // Back on disk: it was only in memory while it waited.
            saveChargeInProgress(force: true)
        } else {
            if recovered.energyKWh > 0.05 { ChargeStore.shared.add(recovered) }
            if charge == nil { try? FileManager.default.removeItem(at: Self.chargeInProgressURL) }
        }
    }

    // MARK: Recording

    /// The open recording file. Rows are written as they come, every `recordingFlushRows`.
    @ObservationIgnored private var recordingFile: (url: URL, handle: FileHandle)?
    static let recordingFlushRows = 20

    func startRecording(_ ids: [String]) {
        if recording != nil { _ = stopRecording() }
        let started = Date()
        let recording = DataRecording(started: started, sensorIds: ids, sensors: sensors)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "yyyy-MM-dd HHmmss"
        let url = Self.recordingsFolder.appendingPathComponent("Recording \(f.string(from: started)).csv")
        try? FileManager.default.createDirectory(at: Self.recordingsFolder, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: Data(recording.header().utf8)),
              let handle = try? FileHandle(forWritingTo: url) else { return }
        _ = try? handle.seekToEnd()
        recordingFile = (url, handle)
        self.recording = recording
        want(ids, for: "recording")
    }

    /// Writes the rows waiting in memory to the file; `sync` also pushes them to storage (going to the
    /// background, or the app ending).
    func flushRecording(sync: Bool = false) {
        guard recording != nil, let file = recordingFile else { return }
        let text = recording?.drain() ?? ""
        if !text.isEmpty { try? file.handle.write(contentsOf: Data(text.utf8)) }
        if sync { try? file.handle.synchronize() }
    }

    /// Finishes the CSV and returns its file; nil when nothing was recorded.
    @discardableResult
    func stopRecording() -> URL? {
        defer {
            recording = nil
            recordingFile = nil
            release("recording")
        }
        guard let recording, let file = recordingFile else { return nil }
        flushRecording()
        try? file.handle.close()
        if recording.rows == 0 {
            try? FileManager.default.removeItem(at: file.url)
            loadRecordings()
            return nil
        }
        loadRecordings()
        return file.url
    }

    func deleteRecording(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        loadRecordings()
    }

    func loadRecordings() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.recordingsFolder, includingPropertiesForKeys: nil)) ?? []
        recordings = files.filter { $0.pathExtension == "csv" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static let recordingsFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Recordings", isDirectory: true)
}

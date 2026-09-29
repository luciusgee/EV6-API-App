import Foundation
import PreconditionKit
import UIKit

/// One OBD connection for the whole app: the adapter (or the simulated EV6), the ELM327 session on top,
/// and a single live-data loop that the gauges, graphs, recording, trip computer and timers all read.
@MainActor
@Observable
final class OBDService {
    enum CarState: Equatable {
        case disconnected
        case connecting
        case connected
        /// The adapter answers but the car doesn't (switched off, or not an E-GMP car).
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
    var timer: AccelerationTimer?
    private var wanted: [String: Set<String>] = [:]
    private var loop: Task<Void, Never>?

    static let historyLimit = 1500

    init() {
        loadRecordings()
        link.onReady = { [weak self] in
            Task { await self?.adapterReady() }
        }
    }

    var adapterConnected: Bool { link.isReady }

    var adapterText: String {
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
        guard adapterConnected else { return }
        let transport: OBDTransport = OBDLinkTransport(link: link)
        let elm = ELM327(transport: transport)
        self.elm = elm
        carState = .connecting
        do {
            try await elm.initialise()
            adapterVersion = await elm.adapterVersion
            if await elm.ping(EGMP.bms) {
                carState = .connected
                restartIfNeeded()
            } else {
                carState = .noAnswer("No answer: switch the car on")
            }
        } catch {
            carState = .noAnswer((error as? OBDError)?.description.capitalizingFirst ?? error.localizedDescription)
        }
    }

    /// Checks again whether the car answers (after switching it on).
    func retryCar() async {
        guard let elm else { return await adapterReady() }
        carState = .connecting
        carState = await elm.ping(EGMP.bms) ? .connected : .noAnswer("No answer: switch the car on")
        restartIfNeeded()
    }

    func disconnect() {
        stopLive()
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
        return EV6Sensors.all.filter { ids.contains($0.id) }
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
        if timer != nil, let kmh = sample.values["speed"] {
            timer?.add(at: sample.at, kmh: kmh, powerKW: sample.values["power"] ?? latest["power"])
        }
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
        let url = Self.recordingsFolder.appendingPathComponent("EV6 \(f.string(from: recording.started)).csv")
        try? FileManager.default.createDirectory(at: Self.recordingsFolder, withIntermediateDirectories: true)
        try? recording.csv().write(to: url, atomically: true, encoding: .utf8)
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

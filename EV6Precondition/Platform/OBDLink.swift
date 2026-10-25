import CoreBluetooth
import Foundation
import Network
import PreconditionKit

/// The OBD adapter: Bluetooth LE (most ELM327 clones, Vgate, vLinker, OBDLink CX) or Wi-Fi.
/// Classic-Bluetooth adapters can't talk to an iPhone.
@MainActor
@Observable
final class OBDLink: NSObject {
    enum State: Equatable {
        case idle
        case bluetoothOff
        case bluetoothDenied
        case scanning
        case connecting(String)
        case ready(String)
        case failed(String)
    }

    struct Adapter: Identifiable, Equatable {
        let id: UUID
        let name: String
        let rssi: Int
        let likelyOBD: Bool
    }

    private(set) var state: State = .idle
    /// Called once the adapter can take commands.
    @ObservationIgnored var onReady: (() -> Void)?
    private(set) var adapters: [Adapter] = []
    /// Kept apart from `state` so the picker can search while an adapter stays connected.
    private(set) var isScanning = false
    var showAllDevices = false

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripherals: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var writeCharacteristic: CBCharacteristic?
    @ObservationIgnored private var wifi: NWConnection?
    @ObservationIgnored private var buffer = ""
    @ObservationIgnored private var pending: CheckedContinuation<String, Error>?
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var wantsScan = false
    @ObservationIgnored private var pendingReconnect: UUID?
    @ObservationIgnored private var connectWatchdog: Task<Void, Never>?
    @ObservationIgnored private var erroredServices: Set<CBUUID> = []
    /// ATSP0 was sent: the next OBD request runs the protocol search.
    @ObservationIgnored private var searchPending = false

    private static let rememberedKey = "obdAdapterId"
    private static let rememberedNameKey = "obdAdapterName"

    /// The adapter connected last time, reconnected to directly. Stored so views update.
    private(set) var rememberedName: String? = UserDefaults.standard.string(forKey: OBDLink.rememberedNameKey)
    private var rememberedId: String? = UserDefaults.standard.string(forKey: OBDLink.rememberedKey)
    var hasRemembered: Bool { rememberedId != nil }

    func forgetAdapter() {
        UserDefaults.standard.removeObject(forKey: Self.rememberedKey)
        UserDefaults.standard.removeObject(forKey: Self.rememberedNameKey)
        rememberedId = nil
        rememberedName = nil
    }

    private func remember(id: String, name: String) {
        UserDefaults.standard.set(id, forKey: Self.rememberedKey)
        UserDefaults.standard.set(name, forKey: Self.rememberedNameKey)
        rememberedId = id
        rememberedName = name
    }

    /// Reconnects to the remembered adapter; false when there isn't one.
    @discardableResult
    func reconnect() -> Bool {
        guard let text = rememberedId else { return false }
        if text == "wifi" {
            connectWiFi()
            return true
        }
        guard let id = UUID(uuidString: text) else { return false }
        // Drop any earlier link or attempt so discovery chooses characteristics afresh.
        stopScan()
        disconnect()
        pendingReconnect = id
        state = .connecting(rememberedName ?? "OBD adapter")
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else {
            reconnectIfPossible()
        }
        return true
    }

    private func reconnectIfPossible() {
        guard let central, let id = pendingReconnect else { return }
        switch central.state {
        case .poweredOn:
            pendingReconnect = nil
            guard let p = central.retrievePeripherals(withIdentifiers: [id]).first else {
                state = .failed("Adapter not found. Is it plugged in?")
                return
            }
            peripherals[id] = p
            peripheral = p
            erroredServices = []
            p.delegate = self
            central.connect(p)
            startWatchdog()
        case .poweredOff: state = .bluetoothOff
        case .unauthorized: state = .bluetoothDenied
        default: break
        }
    }

    var isReady: Bool { if case .ready = state { return true } else { return false } }

    var visibleAdapters: [Adapter] {
        adapters.filter { showAllDevices || $0.likelyOBD }.sorted { ($0.likelyOBD ? 1 : 0, $0.rssi) > ($1.likelyOBD ? 1 : 0, $1.rssi) }
    }

    // MARK: Bluetooth

    func startScan() {
        wantsScan = true
        adapters = []
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else {
            beginScanIfPossible()
        }
    }

    func stopScan() {
        wantsScan = false
        isScanning = false
        central?.stopScan()
        if state == .scanning { state = .idle }
    }

    /// True while an adapter is connected or being connected; scanning leaves that state alone.
    private var isLinked: Bool {
        switch state {
        case .ready, .connecting: return true
        default: return false
        }
    }

    private func beginScanIfPossible() {
        guard let central, wantsScan else { return }
        switch central.state {
        case .poweredOn:
            isScanning = true
            if !isLinked { state = .scanning }
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        case .poweredOff: if !isLinked { state = .bluetoothOff }
        case .unauthorized: if !isLinked { state = .bluetoothDenied }
        default: break
        }
    }

    func connect(_ adapter: Adapter) {
        guard let central, let p = peripherals[adapter.id] else { return }
        stopScan()
        disconnect()
        peripheral = p
        erroredServices = []
        p.delegate = self
        state = .connecting(adapter.name)
        central.connect(p)
        startWatchdog()
    }

    /// CoreBluetooth and NWConnection connects never time out on their own.
    private func startWatchdog() {
        connectWatchdog?.cancel()
        connectWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, let self, case .connecting(let name) = self.state else { return }
            self.disconnect()
            self.state = .failed("Couldn't reach \(name). Is it plugged in and the car on?")
        }
    }

    /// Gives up on a Bluetooth peripheral, keeping the reason on screen.
    private func abandon(_ p: CBPeripheral, reason: String) {
        connectWatchdog?.cancel()
        // Cleared first so the disconnect callback for this cancel doesn't replace the reason with .idle.
        if peripheral === p { peripheral = nil }
        writeCharacteristic = nil
        central?.cancelPeripheralConnection(p)
        fail(OBDError.notConnected)
        state = .failed(reason)
    }

    // MARK: Wi-Fi

    /// Most Wi-Fi ELM327 adapters: join their network first, then 192.168.0.10:35000.
    func connectWiFi(host: String = "192.168.0.10", port: UInt16 = 35000) {
        stopScan()
        disconnect()
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 35000, using: .tcp)
        wifi = connection
        state = .connecting("Wi-Fi adapter")
        connection.stateUpdateHandler = { [weak self] s in
            Task { @MainActor in
                guard let self, self.wifi === connection else { return }
                switch s {
                case .ready:
                    self.connectWatchdog?.cancel()
                    self.state = .ready("Wi-Fi adapter")
                    self.remember(id: "wifi", name: "Wi-Fi adapter")
                    self.onReady?()
                    self.receiveWiFi(connection)
                case .failed(let error):
                    self.connectWatchdog?.cancel()
                    connection.cancel()
                    self.wifi = nil
                    self.state = .failed("Wi-Fi adapter: \(error.localizedDescription). Join the adapter's Wi-Fi network first.")
                    self.fail(OBDError.notConnected)
                case .waiting(let error):
                    self.state = .failed("Wi-Fi adapter: \(error.localizedDescription). Join the adapter's Wi-Fi network first.")
                    self.fail(OBDError.notConnected)
                case .cancelled:
                    // Cancelled by the system rather than by disconnect() (which lets go of it first).
                    self.wifiClosed(connection)
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
        startWatchdog()
    }

    private func receiveWiFi(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self, self.wifi === connection else { return }
                if let data, let text = String(data: data, encoding: .ascii) { self.received(text) }
                if error == nil && !done {
                    self.receiveWiFi(connection)
                } else {
                    // The adapter closed the socket (switched off, or out of Wi-Fi range).
                    self.wifiClosed(connection)
                }
            }
        }
    }

    /// The Wi-Fi socket ended without the user disconnecting: say so, so the service sees the link go.
    private func wifiClosed(_ connection: NWConnection) {
        guard wifi === connection else { return }
        connectWatchdog?.cancel()
        wifi = nil
        connection.cancel()
        fail(OBDError.notConnected)
        state = .failed("Wi-Fi adapter disconnected")
    }

    func disconnect() {
        connectWatchdog?.cancel()
        pendingReconnect = nil
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        writeCharacteristic = nil
        wifi?.cancel()
        wifi = nil
        fail(OBDError.notConnected)
        if isLinked { state = isScanning ? .scanning : .idle }
    }

    // MARK: Exchange

    func send(_ command: String) async throws -> String {
        guard isReady else { throw OBDError.notConnected }
        if pending != nil { throw OBDError.unexpected("busy") }
        buffer = ""
        let data = Data((command + "\r").utf8)
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            // After ATSP0 the next OBD request makes the adapter search every protocol, which on a K-line
            // car (5-baud init, then each protocol in turn) can take well over ten seconds.
            if command == "ATSP0" { searchPending = true }
            let searching = searchPending && !command.uppercased().hasPrefix("AT")
            if searching { searchPending = false }
            let limit: Duration = command == "ATZ" ? .seconds(5) : searching ? .seconds(20) : .seconds(8)
            timeout = Task { [weak self] in
                try? await Task.sleep(for: limit)
                guard !Task.isCancelled else { return }
                self?.fail(OBDError.timeout)
            }
            if let peripheral, let characteristic = writeCharacteristic {
                let type: CBCharacteristicWriteType = characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
                peripheral.writeValue(data, for: characteristic, type: type)
            } else if let wifi {
                wifi.send(content: data, completion: .contentProcessed { _ in })
            } else {
                fail(OBDError.notConnected)
            }
        }
    }

    private func received(_ text: String) {
        buffer += text
        guard buffer.contains(">"), let continuation = pending else { return }
        pending = nil
        timeout?.cancel()
        let reply = buffer
        buffer = ""
        continuation.resume(returning: reply)
    }

    private func fail(_ error: Error) {
        timeout?.cancel()
        guard let continuation = pending else { return }
        pending = nil
        continuation.resume(throwing: error)
    }

    // MARK: Characteristic choice

    /// Known adapter layouts, then any service with a notify and a write characteristic.
    nonisolated private static let knownPairs: [(service: String, notify: String, write: String)] = [
        ("FFF0", "FFF1", "FFF2"),
        ("FFE0", "FFE1", "FFE1"),
        ("18F0", "2AF0", "2AF1"),
        ("E7810A71-73AE-499D-8C15-FAA9AEF0C3F2", "BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F", "BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F"),
    ]
    nonisolated private static let ignoredServices: Set<String> = ["1800", "1801", "180A", "180F"]
    nonisolated private static let namePatterns = ["OBD", "ELM", "VLINK", "V-LINK", "VGATE", "ICAR", "KONNWEI", "VEEPEAK", "LELINK", "CARISTA", "SCAN", "VLINKER"]

    private func chooseCharacteristics(_ p: CBPeripheral) {
        let services = p.services ?? []
        for pair in Self.knownPairs {
            guard let service = services.first(where: { $0.uuid == CBUUID(string: pair.service) }),
                  let notify = service.characteristics?.first(where: { $0.uuid == CBUUID(string: pair.notify) }),
                  let write = service.characteristics?.first(where: { $0.uuid == CBUUID(string: pair.write) })
            else { continue }
            use(p, notify: notify, write: write)
            return
        }
        for service in services where !Self.ignoredServices.contains(service.uuid.uuidString) {
            let chars = service.characteristics ?? []
            if let notify = chars.first(where: { $0.properties.contains(.notify) || $0.properties.contains(.indicate) }),
               let write = chars.first(where: { $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse) }) {
                use(p, notify: notify, write: write)
                return
            }
        }
        abandon(p, reason: "\(p.name ?? "Adapter") doesn't look like an OBD adapter")
    }

    private func use(_ p: CBPeripheral, notify: CBCharacteristic, write: CBCharacteristic) {
        connectWatchdog?.cancel()
        writeCharacteristic = write
        p.setNotifyValue(true, for: notify)
        state = .ready(p.name ?? "OBD adapter")
        remember(id: p.identifier.uuidString, name: p.name ?? "OBD adapter")
        onReady?()
    }

    nonisolated private static func likelyOBD(name: String, advertisement: [String: Any]) -> Bool {
        let upper = name.uppercased()
        if namePatterns.contains(where: { upper.contains($0) }) { return true }
        let services = advertisement[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        return services.contains { uuid in knownPairs.contains { CBUUID(string: $0.service) == uuid } }
    }
}

extension OBDLink: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let power = central.state
        MainActor.assumeIsolated {
            if power != .poweredOn {
                // Below poweredOn CoreBluetooth invalidates peripherals without a disconnect callback.
                isScanning = false
                if peripheral != nil {
                    connectWatchdog?.cancel()
                    peripheral = nil
                    writeCharacteristic = nil
                    fail(OBDError.notConnected)
                    switch power {
                    case .poweredOff: state = .bluetoothOff
                    case .unauthorized: state = .bluetoothDenied
                    default: state = .idle
                    }
                }
            }
            reconnectIfPossible()
            beginScanIfPossible()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
        let likely = name.map { Self.likelyOBD(name: $0, advertisement: advertisementData) } ?? false
        let id = peripheral.identifier
        let rssi = RSSI.intValue
        MainActor.assumeIsolated {
            guard let name else { return }
            peripherals[id] = peripheral
            let adapter = Adapter(id: id, name: name, rssi: rssi, likelyOBD: likely)
            if let i = adapters.firstIndex(where: { $0.id == id }) { adapters[i] = adapter } else { adapters.append(adapter) }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let id = peripheral.identifier
        MainActor.assumeIsolated {
            // A stale attempt that finished after the user moved on.
            guard self.peripheral?.identifier == id else {
                central.cancelPeripheralConnection(peripheral)
                return
            }
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let message = error?.localizedDescription ?? "couldn't connect"
        let id = peripheral.identifier
        MainActor.assumeIsolated {
            guard self.peripheral?.identifier == id else { return }
            connectWatchdog?.cancel()
            self.peripheral = nil
            state = .failed(message)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let id = peripheral.identifier
        MainActor.assumeIsolated {
            guard self.peripheral?.identifier == id else { return }
            self.peripheral = nil
            writeCharacteristic = nil
            fail(OBDError.notConnected)
            state = error.map { State.failed("Disconnected: \($0.localizedDescription)") } ?? .idle
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let id = peripheral.identifier
        let failure = error?.localizedDescription
        MainActor.assumeIsolated {
            guard self.peripheral?.identifier == id else { return }
            let services = peripheral.services ?? []
            if let failure {
                abandon(peripheral, reason: "\(peripheral.name ?? "Adapter"): \(failure)")
            } else if services.isEmpty {
                abandon(peripheral, reason: "\(peripheral.name ?? "Adapter") doesn't look like an OBD adapter")
            } else {
                for service in services { peripheral.discoverCharacteristics(nil, for: service) }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let id = peripheral.identifier
        let failed = error != nil
        MainActor.assumeIsolated {
            guard self.peripheral?.identifier == id else { return }
            // A service whose discovery failed never gets characteristics; don't wait for it.
            if failed { erroredServices.insert(service.uuid) }
            // Choose once every service has reported its characteristics.
            guard writeCharacteristic == nil,
                  (peripheral.services ?? []).allSatisfy({ $0.characteristics != nil || erroredServices.contains($0.uuid) })
            else { return }
            chooseCharacteristics(peripheral)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, let text = String(data: data, encoding: .ascii) else { return }
        let id = peripheral.identifier
        MainActor.assumeIsolated {
            guard self.peripheral?.identifier == id else { return }
            received(text)
        }
    }
}

/// Lets the kit's `ELM327` talk through the link.
struct OBDLinkTransport: OBDTransport {
    let link: OBDLink

    func exchange(_ command: String) async throws -> String {
        try await link.send(command)
    }
}

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
    private(set) var adapters: [Adapter] = []
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
        central?.stopScan()
        if state == .scanning { state = .idle }
    }

    private func beginScanIfPossible() {
        guard let central, wantsScan else { return }
        switch central.state {
        case .poweredOn:
            state = .scanning
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        case .poweredOff: state = .bluetoothOff
        case .unauthorized: state = .bluetoothDenied
        default: break
        }
    }

    func connect(_ adapter: Adapter) {
        guard let central, let p = peripherals[adapter.id] else { return }
        stopScan()
        disconnect()
        peripheral = p
        p.delegate = self
        state = .connecting(adapter.name)
        central.connect(p)
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
                    self.state = .ready("Wi-Fi adapter")
                    self.receiveWiFi(connection)
                case .failed(let error), .waiting(let error):
                    self.state = .failed("Wi-Fi adapter: \(error.localizedDescription). Join the adapter's Wi-Fi network first.")
                    self.fail(OBDError.notConnected)
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func receiveWiFi(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self, self.wifi === connection else { return }
                if let data, let text = String(data: data, encoding: .ascii) { self.received(text) }
                if error == nil && !done { self.receiveWiFi(connection) }
            }
        }
    }

    func disconnect() {
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        writeCharacteristic = nil
        wifi?.cancel()
        wifi = nil
        fail(OBDError.notConnected)
        if case .ready = state { state = .idle }
        if case .connecting = state { state = .idle }
    }

    // MARK: Exchange

    func send(_ command: String) async throws -> String {
        guard isReady else { throw OBDError.notConnected }
        if pending != nil { throw OBDError.unexpected("busy") }
        buffer = ""
        let data = Data((command + "\r").utf8)
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            let limit: Duration = command == "ATZ" ? .seconds(5) : .seconds(8)
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
        state = .failed("\(p.name ?? "Adapter") doesn't look like an OBD adapter")
        central?.cancelPeripheralConnection(p)
    }

    private func use(_ p: CBPeripheral, notify: CBCharacteristic, write: CBCharacteristic) {
        writeCharacteristic = write
        p.setNotifyValue(true, for: notify)
        state = .ready(p.name ?? "OBD adapter")
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
        MainActor.assumeIsolated { beginScanIfPossible() }
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
        peripheral.discoverServices(nil)
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let message = error?.localizedDescription ?? "couldn't connect"
        MainActor.assumeIsolated { state = .failed(message) }
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
        for service in peripheral.services ?? [] { peripheral.discoverCharacteristics(nil, for: service) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            // Choose once every service has reported its characteristics.
            guard writeCharacteristic == nil, (peripheral.services ?? []).allSatisfy({ $0.characteristics != nil }) else { return }
            chooseCharacteristics(peripheral)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, let text = String(data: data, encoding: .ascii) else { return }
        MainActor.assumeIsolated { received(text) }
    }
}

/// Lets the kit's `ELM327` talk through the link.
struct OBDLinkTransport: OBDTransport {
    let link: OBDLink

    func exchange(_ command: String) async throws -> String {
        try await link.send(command)
    }
}

import Foundation
import CoreBluetooth

struct FoundDevice: Identifiable {
    let id: UUID
    let peripheral: CBPeripheral
    var name: String
    var rssi: Int
    var manufacturerData: [UInt8]
    var advertisedServices: [String]
}

struct LogEntry: Identifiable {
    enum Kind: String {
        case rx = "RX"
        case tx = "TX"
        case info = "--"
    }

    let id = UUID()
    let time: Date
    let kind: Kind
    let channel: String
    let bytes: [UInt8]
    let note: String

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var textLine: String {
        var line = LogEntry.timeFormatter.string(from: time) + " " + kind.rawValue + " " + channel
        if !bytes.isEmpty {
            line += "  " + J078.hex(bytes)
        }
        if !note.isEmpty {
            line += "\n    " + note.replacingOccurrences(of: "\n", with: "\n    ")
        }
        return line
    }
}

/// Owns Bluetooth. Read-only by design: the only thing it ever writes to the
/// scooter is the optional heartbeat (off by default).
final class BLEManager: NSObject, ObservableObject {
    @Published var bluetoothState = "Starting Bluetooth..."
    @Published var isScanning = false
    @Published var filterKnownServices = false {
        didSet {
            if isScanning { startScan() }
        }
    }
    @Published var devices: [FoundDevice] = []
    @Published var connected: CBPeripheral?
    @Published var connectionStatus = "Not connected"
    @Published var characteristicsInfo: [String] = []
    @Published var log: [LogEntry] = []
    @Published var heartbeatOn = false
    @Published var heartbeatsSent = 0
    @Published var logEachHeartbeat = false
    @Published var hasF1F1 = false

    private var central: CBCentralManager!
    private var pending: CBPeripheral?
    private var f1f1: CBCharacteristic?
    private var heartbeatTimer: Timer?
    private let maxLogEntries = 5000

    override init() {
        super.init()
        // queue nil = delegate callbacks arrive on the main thread.
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Scanning

    func startScan() {
        guard central.state == .poweredOn else {
            addInfo("Can't scan: " + bluetoothState)
            return
        }
        central.stopScan()
        devices.removeAll()
        let services: [CBUUID]? = filterKnownServices ? J078.scanServices : nil
        central.scanForPeripherals(withServices: services, options: nil)
        isScanning = true
        addInfo(filterKnownServices ? "Scanning (only F1F0/F2F0/6E400001)" : "Scanning (all devices)")
    }

    func stopScan() {
        central.stopScan()
        if isScanning { addInfo("Scan stopped") }
        isScanning = false
    }

    // MARK: - Connecting

    func connect(_ device: FoundDevice) {
        stopScan()
        if let old = pending {
            central.cancelPeripheralConnection(old)
        }
        pending = device.peripheral
        connectionStatus = "Connecting to " + device.name + "..."
        addInfo("Connecting to " + device.name + " (RSSI \(device.rssi))")
        central.connect(device.peripheral, options: nil)
    }

    func disconnect() {
        setHeartbeat(false)
        if let p = connected {
            central.cancelPeripheralConnection(p)
        }
        if let p = pending {
            central.cancelPeripheralConnection(p)
        }
        pending = nil
        if connected == nil {
            connectionStatus = "Not connected"
        }
    }

    // MARK: - Heartbeat (the only write in v1)

    func setHeartbeat(_ on: Bool) {
        let wasOn = heartbeatOn
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        heartbeatOn = false
        if !on {
            if wasOn { addInfo("Heartbeat off") }
            return
        }
        guard connected != nil, let c = f1f1 else {
            addInfo("Heartbeat not started: no F1F1 characteristic on this device")
            return
        }
        guard c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse) else {
            addInfo("Heartbeat not started: F1F1 is not writable")
            return
        }
        heartbeatOn = true
        addInfo("Heartbeat on: " + J078.hex(J078.heartbeat) + " to F1F1 every \(Int(J078.heartbeatInterval * 1000)) ms")
        let timer = Timer(timeInterval: J078.heartbeatInterval, repeats: true) { [weak self] _ in
            self?.sendHeartbeat()
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
        sendHeartbeat()
    }

    private func sendHeartbeat() {
        guard let p = connected, let c = f1f1 else {
            setHeartbeat(false)
            return
        }
        let type: CBCharacteristicWriteType = c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        p.writeValue(Data(J078.heartbeat), for: c, type: type)
        heartbeatsSent += 1
        if logEachHeartbeat {
            add(.tx, channel: "F1F1", bytes: J078.heartbeat, note: "heartbeat")
        }
    }

    // MARK: - Log

    func add(_ kind: LogEntry.Kind, channel: String, bytes: [UInt8], note: String) {
        log.append(LogEntry(time: Date(), kind: kind, channel: channel, bytes: bytes, note: note))
        if log.count > maxLogEntries {
            log.removeFirst(log.count - maxLogEntries)
        }
    }

    func addInfo(_ text: String) {
        add(.info, channel: "", bytes: [], note: text)
    }

    func clearLog() {
        log.removeAll()
    }

    func exportText() -> String {
        var out = "J078 packet log\n"
        out += "Exported: \(Date())\n"
        out += "Device: " + (connected?.name ?? "none") + "\n"
        out += "Decryption and labels are UNVERIFIED guesses from the vendor app.\n\n"
        for e in log {
            out += e.textLine + "\n"
        }
        return out
    }

    /// Writes the log to a .txt file for the share sheet.
    func exportLogFile() -> URL? {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("j078-log-" + f.string(from: Date()) + ".txt")
        do {
            try exportText().write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            addInfo("Export failed: " + error.localizedDescription)
            return nil
        }
    }

    // MARK: - Helpers

    static func describe(_ p: CBCharacteristicProperties) -> String {
        var parts: [String] = []
        if p.contains(.read) { parts.append("read") }
        if p.contains(.write) { parts.append("write") }
        if p.contains(.writeWithoutResponse) { parts.append("writeNoResp") }
        if p.contains(.notify) { parts.append("notify") }
        if p.contains(.indicate) { parts.append("indicate") }
        return parts.joined(separator: ",")
    }

    private func resetConnectionState() {
        setHeartbeat(false)
        connected = nil
        pending = nil
        f1f1 = nil
        hasF1F1 = false
        characteristicsInfo = []
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bluetoothState = "Bluetooth on"
        case .poweredOff:
            bluetoothState = "Bluetooth is off"
        case .unauthorized:
            bluetoothState = "No Bluetooth permission (Settings > J078 > Bluetooth)"
        case .unsupported:
            bluetoothState = "Bluetooth LE not supported"
        case .resetting:
            bluetoothState = "Bluetooth resetting"
        case .unknown:
            bluetoothState = "Bluetooth state unknown"
        @unknown default:
            bluetoothState = "Bluetooth state unknown"
        }
        if central.state != .poweredOn {
            isScanning = false
            if connected != nil || pending != nil {
                resetConnectionState()
                connectionStatus = "Not connected"
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advName ?? peripheral.name ?? "(no name)"
        var mfg: [UInt8] = []
        if let d = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
            mfg = [UInt8](d)
        }
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []).map { J078.name(for: $0) }
        let rssi = RSSI.intValue

        if let i = devices.firstIndex(where: { $0.id == peripheral.identifier }) {
            if name != "(no name)" { devices[i].name = name }
            if rssi != 127 { devices[i].rssi = rssi }
            if !mfg.isEmpty { devices[i].manufacturerData = mfg }
            if !services.isEmpty { devices[i].advertisedServices = services }
        } else {
            devices.append(FoundDevice(id: peripheral.identifier, peripheral: peripheral, name: name,
                                       rssi: rssi, manufacturerData: mfg, advertisedServices: services))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        pending = nil
        connected = peripheral
        f1f1 = nil
        hasF1F1 = false
        characteristicsInfo = []
        connectionStatus = "Connected to " + (peripheral.name ?? "device")
        addInfo("Connected. Discovering services...")
        peripheral.delegate = self
        // nil = discover every service, so nothing on the scooter is missed.
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        pending = nil
        connectionStatus = "Connect failed"
        addInfo("Connect failed: " + (error?.localizedDescription ?? "unknown error"))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        resetConnectionState()
        connectionStatus = "Disconnected"
        addInfo("Disconnected" + (error.map { ": " + $0.localizedDescription } ?? ""))
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            addInfo("Service discovery error: " + error.localizedDescription)
            return
        }
        let services = peripheral.services ?? []
        addInfo("Found \(services.count) services: " + services.map { J078.name(for: $0.uuid) }.joined(separator: ", "))
        for s in services {
            peripheral.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let serviceName = J078.name(for: service.uuid)
        if let error = error {
            addInfo("Characteristic discovery error on " + serviceName + ": " + error.localizedDescription)
            return
        }
        for c in service.characteristics ?? [] {
            let name = J078.name(for: c.uuid)
            let props = BLEManager.describe(c.properties)
            characteristicsInfo.append(serviceName + " / " + name + "  [" + props + "]")
            addInfo("Characteristic " + serviceName + " / " + name + " [" + props + "]")

            if name == "F1F1" {
                f1f1 = c
                hasF1F1 = true
            }
            // Subscribing only turns on notifications (a standard Bluetooth step).
            // It does not send any scooter command.
            if c.properties.contains(.notify) || c.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: c)
            }
            // One read of readable characteristics (read-only, safe).
            if c.properties.contains(.read) {
                peripheral.readValue(for: c)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let name = J078.name(for: characteristic.uuid)
        if let error = error {
            addInfo("Notify on " + name + " failed: " + error.localizedDescription)
        } else {
            addInfo("Listening on " + name + (characteristic.isNotifying ? "" : " (off)"))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let name = J078.name(for: characteristic.uuid)
        if let error = error {
            addInfo("Read error on " + name + ": " + error.localizedDescription)
            return
        }
        let bytes = [UInt8](characteristic.value ?? Data())
        add(.rx, channel: name, bytes: bytes, note: J078.describe(bytes, channel: name))
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            addInfo("Write error on " + J078.name(for: characteristic.uuid) + ": " + error.localizedDescription)
        }
    }
}

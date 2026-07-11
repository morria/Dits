// Morserino-32 BLE keyer (ported from Morserino-iOS). The device is a
// Nordic UART Service peripheral running the m32 serial protocol:
// newline-terminated ASCII commands written to the RX characteristic,
// interleaved JSON objects + raw keyed-character echo notified on TX.
//
// When connected and in CW Keyer mode, outgoing messages are keyed by
// the Morserino (PUT cw/play/<text>) instead of rendered as audio.

import CoreBluetooth
import Foundation

final class MorserinoKeyer: NSObject, ObservableObject {

    // MARK: - Types

    enum ConnectionState: Equatable {
        case idle
        case scanning
        case connecting
        /// Link dropped unexpectedly; a pending connect is armed and will
        /// reattach the moment the device is back in range.
        case reconnecting
        case ready
    }

    struct Device: Identifiable, Equatable {
        let id: UUID
        let name: String
        let rssi: Int
    }

    // MARK: - Nordic UART Service

    private static let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    /// App → device (write)
    private static let rxUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    /// Device → app (notify)
    private static let txUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    // MARK: - Published state

    @Published private(set) var connectionState: ConnectionState = .idle
    @Published private(set) var devices: [Device] = []
    @Published private(set) var deviceName: String?
    @Published private(set) var firmware: String?
    @Published private(set) var batteryStatus: String?
    @Published private(set) var inKeyerMode = false
    @Published private(set) var keyerMenuAvailable = false

    var isReady: Bool { connectionState == .ready }

    /// Raw keyed-character echo from the device (keying progress).
    var onKeyingEcho: ((String) -> Void)?
    /// Link dropped (unexpectedly or via disconnect()). Fired on main.
    var onDisconnect: (() -> Void)?

    // MARK: - Internals

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var connectingID: UUID?
    private var knownPeripherals: [UUID: CBPeripheral] = [:]
    private var rxCharacteristic: CBCharacteristic?
    private var writeType: CBCharacteristicWriteType = .withoutResponse
    private var pendingChunks: [Data] = []
    private var awaitingWriteResponse = false
    private var connectTimeout: DispatchWorkItem?
    private var keyerMenuNumber: Int?

    // MARK: - Auto-connect

    /// When armed, discovery may connect on its own: instantly to the
    /// remembered device, or to the only device in range after a short
    /// settle window. Cuts pairing to one tap (open the screen) and
    /// re-pairing to zero.
    private var autoConnectArmed = false
    private var singleDeviceTimer: DispatchWorkItem?
    private var scanStopTimer: DispatchWorkItem?
    /// An explicit Disconnect holds for the rest of the session — the
    /// quiet foreground reconnect must not undo the operator's choice.
    private var userDisconnected = false

    private static let rememberedDeviceKey = "morserino.lastDeviceID"

    private var rememberedDeviceID: UUID? {
        get { UserDefaults.standard.string(forKey: Self.rememberedDeviceKey).flatMap(UUID.init) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: Self.rememberedDeviceKey) }
    }

    // JSON/raw stream separation
    private var jsonBuffer = ""
    private var jsonDepth = 0
    private var inString = false
    private var escaped = false

    // MARK: - Scanning & connection

    /// Central is created lazily so the Bluetooth permission prompt
    /// appears on user action, not app launch.
    func startScanning(autoConnect: Bool = true) {
        autoConnectArmed = autoConnect
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
            connectionState = .scanning
            return   // scan starts in centralManagerDidUpdateState
        }
        beginScan()
    }

    func stopScanning() {
        singleDeviceTimer?.cancel()
        singleDeviceTimer = nil
        scanStopTimer?.cancel()
        scanStopTimer = nil
        autoConnectArmed = false
        if connectionState == .scanning {
            central?.stopScan()
            connectionState = peripheral == nil ? .idle : connectionState
        }
    }

    /// Zero-tap reconnect: if this phone has paired with a Morserino
    /// before, scan quietly on foreground and reattach when it appears.
    /// Gated on a remembered device so it can never be the thing that
    /// triggers the Bluetooth permission prompt.
    func reconnectIfRemembered() {
        guard rememberedDeviceID != nil, connectionState == .idle, !userDisconnected else { return }
        startScanning(autoConnect: true)
        let stop = DispatchWorkItem { [weak self] in
            guard let self, self.connectionState == .scanning else { return }
            self.stopScanning()
        }
        scanStopTimer?.cancel()
        scanStopTimer = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: stop)
    }

    func connect(_ device: Device) {
        guard let central, let target = knownPeripherals[device.id] else { return }
        userDisconnected = false
        singleDeviceTimer?.cancel()
        singleDeviceTimer = nil
        scanStopTimer?.cancel()
        scanStopTimer = nil
        autoConnectArmed = false
        central.stopScan()
        connectionState = .connecting
        connectingID = device.id
        deviceName = device.name
        central.connect(target)

        // CoreBluetooth never times out connect(_:) on its own; without
        // this, an unreachable device leaves a pending connect that hides
        // it from every scanner until Bluetooth is toggled.
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.connectionState == .connecting else { return }
            if let pending = self.connectingID, let p = self.knownPeripherals[pending] {
                central.cancelPeripheralConnection(p)
            }
            self.connectingID = nil
            self.connectionState = .idle
        }
        connectTimeout?.cancel()
        connectTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
    }

    func disconnect() {
        userDisconnected = true
        // Cancel a pending auto-reconnect (link already down).
        if connectionState == .reconnecting, let central,
           let id = connectingID, let pending = knownPeripherals[id] {
            central.cancelPeripheralConnection(pending)
            connectingID = nil
            connectionState = .idle
            return
        }
        guard let central, let p = peripheral else { return }
        send(line: "PUT device/protocol/off")
        // Give the goodbye a moment to flush before dropping the link.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            central.cancelPeripheralConnection(p)
        }
    }

    // MARK: - Keying commands

    /// Key `text` on the device. Uppercased, whitespace-collapsed.
    func sendKeying(_ text: String) {
        let cleaned = text.uppercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !cleaned.isEmpty else { return }
        send(line: "PUT cw/play/\(cleaned)")
    }

    func stopKeying() {
        send(line: "PUT cw/stop")
    }

    func setSpeed(_ wpm: Int) {
        send(line: "PUT control/speed/\(wpm)")
    }

    /// Switch the device into its CW Keyer menu so cw/play works.
    func startKeyerMode() {
        guard let number = keyerMenuNumber else { return }
        send(line: "PUT menu/stop")
        send(line: "PUT menu/start now/\(number)")
        send(line: "GET menu")
    }

    // MARK: - Transport

    private func beginScan() {
        guard let central, central.state == .poweredOn else { return }
        devices.removeAll()
        connectionState = .scanning
        central.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    private func send(line: String) {
        guard connectionState == .ready,
              let peripheral,
              rxCharacteristic != nil,
              let data = (line + "\n").data(using: .utf8) else { return }
        let mtu = peripheral.maximumWriteValueLength(for: writeType)
        var offset = 0
        while offset < data.count {
            let end = min(offset + max(mtu, 20), data.count)
            pendingChunks.append(data.subdata(in: offset..<end))
            offset = end
        }
        pumpWrites()
    }

    private func pumpWrites() {
        guard let peripheral, let rx = rxCharacteristic else { return }
        while !pendingChunks.isEmpty {
            if writeType == .withResponse {
                guard !awaitingWriteResponse else { return }
                awaitingWriteResponse = true
                peripheral.writeValue(pendingChunks.removeFirst(), for: rx, type: .withResponse)
                return
            } else {
                guard peripheral.canSendWriteWithoutResponse else { return }
                peripheral.writeValue(pendingChunks.removeFirst(), for: rx, type: .withoutResponse)
            }
        }
    }

    private func cleanupConnection(fireDisconnect: Bool) {
        connectTimeout?.cancel()
        connectTimeout = nil
        peripheral = nil
        rxCharacteristic = nil
        pendingChunks.removeAll()
        awaitingWriteResponse = false
        connectingID = nil
        connectionState = .idle
        deviceName = nil
        firmware = nil
        batteryStatus = nil
        inKeyerMode = false
        keyerMenuAvailable = false
        keyerMenuNumber = nil
        jsonBuffer = ""
        jsonDepth = 0
        inString = false
        escaped = false
        if fireDisconnect { onDisconnect?() }
    }

    // MARK: - m32 protocol

    private func startSession() {
        send(line: "PUT device/protocol/on")
        send(line: "GET device")
        send(line: "GET menus")
        send(line: "GET menu")
        send(line: "GET battery")
    }

    /// The device interleaves brace-balanced JSON objects with raw echoed
    /// CW characters on one stream, and BLE can split anywhere — parse
    /// byte-wise with persistent state.
    private func receive(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        var raw = ""
        for ch in text {
            if jsonDepth > 0 {
                jsonBuffer.append(ch)
                if inString {
                    if escaped { escaped = false }
                    else if ch == "\\" { escaped = true }
                    else if ch == "\"" { inString = false }
                } else if ch == "\"" { inString = true }
                else if ch == "{" { jsonDepth += 1 }
                else if ch == "}" {
                    jsonDepth -= 1
                    if jsonDepth == 0 {
                        handleJSON(jsonBuffer)
                        jsonBuffer = ""
                    }
                }
                if jsonBuffer.count > 65_536 {   // runaway guard
                    raw += jsonBuffer
                    jsonBuffer = ""
                    jsonDepth = 0
                    inString = false
                }
            } else if ch == "{" {
                jsonDepth = 1
                jsonBuffer = "{"
                inString = false
                escaped = false
            } else {
                raw.append(ch)
            }
        }
        let echo = raw.trimmingCharacters(in: .newlines)
        if !echo.isEmpty { onKeyingEcho?(echo) }
    }

    private func handleJSON(_ string: String) {
        guard let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let device = object["device"] as? [String: Any] {
            firmware = (device["firmware"] as? String) ?? (device["firmware"] as? Double).map { "\($0)" }
        }
        if let battery = object["battery"] as? [String: Any] {
            if let status = battery["status"] as? String {
                batteryStatus = status
            } else if let voltage = battery["voltage"] as? Double {
                batteryStatus = String(format: "%.2f V", voltage / 1000)
            }
        }
        if let menu = object["menu"] as? [String: Any],
           let content = (menu["content"] as? String)?.lowercased() {
            if content.contains("lora") || content.contains("wifi") {
                inKeyerMode = false
            } else if content.contains("keyer") || content.contains("trx") {
                inKeyerMode = true
            }
        }
        if let menus = object["menus"] as? [[String: Any]] {
            findKeyerMenu(in: menus)
        }
    }

    /// Find the CW Keyer menu without hardcoding its number: prefer an
    /// executable entry named exactly "cw keyer", else the first
    /// executable "keyer" that isn't a LoRa/WiFi mode.
    private func findKeyerMenu(in menus: [[String: Any]]) {
        var fallback: Int?
        for entry in menus {
            guard let content = (entry["content"] as? String)?.lowercased(),
                  let number = entry["menu number"] as? Int,
                  (entry["executable"] as? Bool ?? (entry["executable"] as? Int == 1)) else { continue }
            if content == "cw keyer" {
                keyerMenuNumber = number
                keyerMenuAvailable = true
                return
            }
            if fallback == nil, content.contains("keyer"),
               !content.contains("lora"), !content.contains("wifi") {
                fallback = number
            }
        }
        keyerMenuNumber = fallback
        keyerMenuAvailable = fallback != nil
    }
}

// MARK: - CBCentralManagerDelegate

extension MorserinoKeyer: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn, connectionState == .scanning {
            beginScan()
        } else if central.state != .poweredOn, peripheral != nil {
            cleanupConnection(fireDisconnect: true)
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        knownPeripherals[peripheral.identifier] = peripheral
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? "Morserino"
        let device = Device(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
        } else {
            devices.append(device)
        }
        devices.sort { $0.rssi > $1.rssi }

        guard autoConnectArmed else { return }
        if device.id == rememberedDeviceID {
            // The device we've used before — reattach immediately.
            connect(device)
        } else if singleDeviceTimer == nil {
            // Unknown device(s): give discovery a moment to settle, then
            // connect only if exactly one is in range (no ambiguity).
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.autoConnectArmed,
                      self.connectionState == .scanning,
                      self.devices.count == 1,
                      let only = self.devices.first else { return }
                self.connect(only)
            }
            singleDeviceTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral.identifier == connectingID else {
            // Late connect after timeout/abandon — drop it.
            central.cancelPeripheralConnection(peripheral)
            return
        }
        connectTimeout?.cancel()
        self.peripheral = peripheral
        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == connectingID else { return }
        cleanupConnection(fireDisconnect: false)
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        let unexpected = !userDisconnected
        cleanupConnection(fireDisconnect: true)
        if unexpected {
            // BLE links to the Morserino drop easily (range, sleep). A
            // pending connect on the same peripheral never times out at
            // the system level and reattaches the instant the device is
            // seen again — the canonical CoreBluetooth auto-reconnect.
            connectionState = .reconnecting
            connectingID = peripheral.identifier
            deviceName = peripheral.name ?? deviceName
            central.connect(peripheral)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension MorserinoKeyer: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else { return }
        peripheral.discoverCharacteristics([Self.rxUUID, Self.txUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == Self.rxUUID {
                rxCharacteristic = characteristic
                writeType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
            } else if characteristic.uuid == Self.txUUID {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.txUUID,
              characteristic.isNotifying,
              rxCharacteristic != nil else { return }
        connectionState = .ready
        rememberedDeviceID = peripheral.identifier
        startSession()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.txUUID, let data = characteristic.value else { return }
        receive(data)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        awaitingWriteResponse = false
        pumpWrites()
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        pumpWrites()
    }
}

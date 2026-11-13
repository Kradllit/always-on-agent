import CoreBluetooth
import Foundation

/// What the badge reports about itself (the "status" value of its Bluetooth service).
struct BadgeStatus: Decodable, Equatable {
    var battery: Int
    var charging: Bool
    var usb: Bool
    var ip: String?
    var mood: String
    var pets: Int
}

/// The Bluetooth link to the badge: finds it, keeps its status current and sends it text.
/// The badge takes any phone nearby, so there is nothing to pair. badge/src/ble.rs is the
/// other end.
final class BadgeLink: NSObject, ObservableObject {
    enum Phase: Equatable {
        case bluetoothOff, notAllowed, searching, connecting, ready
    }

    @Published private(set) var phase: Phase = .searching
    @Published private(set) var status: BadgeStatus?

    // BA5ECA3B-000x-4B1D-9E5A-0D1E2F3A4B5C: 1 the service, 2 status, 3 command.
    private static let service = CBUUID(string: "BA5ECA3B-0001-4B1D-9E5A-0D1E2F3A4B5C")
    private static let statusValue = CBUUID(string: "BA5ECA3B-0002-4B1D-9E5A-0D1E2F3A4B5C")
    private static let commandValue = CBUUID(string: "BA5ECA3B-0003-4B1D-9E5A-0D1E2F3A4B5C")

    private var central: CBCentralManager!
    private var badge: CBPeripheral?
    private var statusCharacteristic: CBCharacteristic?
    private var commandCharacteristic: CBCharacteristic?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    /// Whether a badge is there to take text.
    var connected: Bool { phase == .ready && commandCharacteristic != nil }

    /// Show a line of text under the badge's eyes. Returns whether a badge was there to take it.
    @discardableResult
    func say(_ text: String) -> Bool {
        guard connected, let badge, let commandCharacteristic else { return false }
        guard let data = Self.forBadge(text).data(using: .utf8), !data.isEmpty else { return false }
        badge.writeValue(data, for: commandCharacteristic, type: .withResponse)
        return true
    }

    /// The badge's screen font has Latin-1 only, and its caption holds two short lines.
    static func forBadge(_ text: String) -> String {
        let plain = text
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2014}", with: "-")
        let latin = plain.applyingTransform(.toLatin, reverse: false) ?? plain
        let shown = String(latin.unicodeScalars.filter { $0.value >= 0x20 && $0.value <= 0xFF }.map(Character.init))
        return String(shown.trimmingCharacters(in: .whitespaces).prefix(60))
    }

    // MARK: Finding the badge

    private func search() {
        guard central.state == .poweredOn, badge == nil else { return }
        phase = .searching
        // A badge the phone is already connected to doesn't advertise: ask for it first.
        if let known = central.retrieveConnectedPeripherals(withServices: [Self.service]).first {
            connect(known)
        } else {
            central.scanForPeripherals(withServices: [Self.service])
        }
    }

    private func connect(_ peripheral: CBPeripheral) {
        central.stopScan()
        badge = peripheral
        peripheral.delegate = self
        phase = .connecting
        central.connect(peripheral)
    }

    private func lost() {
        badge = nil
        statusCharacteristic = nil
        commandCharacteristic = nil
        status = nil
        search()
    }
}

extension BadgeLink: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            search()
        case .unauthorized:
            phase = .notAllowed
        default:
            badge = nil
            status = nil
            phase = .bluetoothOff
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if badge == nil { connect(peripheral) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        lost()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        lost()
    }
}

extension BadgeLink: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else { return }
        peripheral.discoverCharacteristics([Self.statusValue, Self.commandValue], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == Self.statusValue { statusCharacteristic = characteristic }
            if characteristic.uuid == Self.commandValue { commandCharacteristic = characteristic }
        }
        guard let statusCharacteristic, commandCharacteristic != nil else { return }
        phase = .ready
        peripheral.setNotifyValue(true, for: statusCharacteristic)
        peripheral.readValue(for: statusCharacteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.statusValue, error == nil, let data = characteristic.value else { return }
        if let decoded = try? JSONDecoder().decode(BadgeStatus.self, from: data) {
            status = decoded
        }
    }
}

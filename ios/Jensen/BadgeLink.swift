import CoreBluetooth
import Foundation
import OSLog

private let log = Logger(subsystem: "com.kradllit.jensen", category: "badge")

/// What the badge reports about itself (the "status" value of its Bluetooth service).
struct BadgeStatus: Decodable, Equatable {
    var battery: Int
    var charging: Bool
    var usb: Bool
    var ip: String?
    var mood: String
    var pets: Int
}

/// A badge seen while scanning.
struct FoundBadge: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int

    /// Signal strength in words.
    var nearness: String {
        switch rssi {
        case (-60)...: "Right here"
        case (-75)...: "Close"
        default: "Further away"
        }
    }
}

/// The Bluetooth link to the badge (badge/src/ble.rs is the other end).
///
/// Pairing is the app's: scan, list the badges found, pair with one, remember it. From then
/// on the phone keeps a standing connection request open for that badge only, so it
/// reconnects by itself whenever it is back in reach, also with the app in the background.
/// The hackathon firmware has no Bluetooth bonding, so the iPhone shows no "Pair" prompt.
final class BadgeLink: NSObject, ObservableObject {
    enum Phase: Equatable {
        /// `unpaired`: no badge remembered yet. `away`: a badge is remembered and the phone
        /// is waiting for it to come into reach.
        case bluetoothOff, notAllowed, unpaired, away, connecting, ready
    }

    @Published private(set) var phase: Phase = .unpaired
    @Published private(set) var status: BadgeStatus?
    /// Badges found by the current scan, nearest first.
    @Published private(set) var found: [FoundBadge] = []
    @Published private(set) var scanning = false
    /// The remembered badge, by the identifier this iPhone gave it.
    @Published private(set) var paired: UUID? {
        didSet {
            if let paired { UserDefaults.standard.set(paired.uuidString, forKey: Self.saved) }
            else { UserDefaults.standard.removeObject(forKey: Self.saved) }
        }
    }

    // BA5ECA3B-000x-4B1D-9E5A-0D1E2F3A4B5C: 1 the service, 2 status, 3 command.
    private static let service = CBUUID(string: "BA5ECA3B-0001-4B1D-9E5A-0D1E2F3A4B5C")
    private static let statusValue = CBUUID(string: "BA5ECA3B-0002-4B1D-9E5A-0D1E2F3A4B5C")
    private static let commandValue = CBUUID(string: "BA5ECA3B-0003-4B1D-9E5A-0D1E2F3A4B5C")
    private static let saved = "badge-id"

    private var central: CBCentralManager!
    /// The badge being connected to or connected (remembered, or being paired).
    private var badge: CBPeripheral?
    /// Peripherals seen by the scan, kept so one can be connected to.
    private var seen: [UUID: CBPeripheral] = [:]
    private var statusCharacteristic: CBCharacteristic?
    private var commandCharacteristic: CBCharacteristic?
    /// Lines waiting for the badge to be there, and the lines being shown one after another.
    private var paging: [String] = []
    private var pageTimer: Timer?

    override init() {
        super.init()
        paired = UserDefaults.standard.string(forKey: Self.saved).flatMap(UUID.init(uuidString:))
        central = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "jensen-badge",
        ])
    }

    /// Whether a badge is there to take text.
    var connected: Bool { phase == .ready && commandCharacteristic != nil }

    // MARK: Saying things

    /// Show a line of text under the badge's eyes. Returns whether a badge was there to take it.
    @discardableResult
    func say(_ text: String) -> Bool {
        stopPaging()
        return write(Self.forBadge(text))
    }

    /// Show a headline, then the rest a screenful at a time (the badge holds each line for
    /// six seconds and shows two short lines). Returns whether a badge was there.
    @discardableResult
    func show(_ headline: String, then more: String) -> Bool {
        stopPaging()
        guard write(Self.forBadge(headline)) else { return false }
        paging = Self.pages(of: more)
        pageTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] timer in
            guard let self, !self.paging.isEmpty, self.write(self.paging.removeFirst()) else {
                timer.invalidate()
                return
            }
        }
        return true
    }

    /// Blink and say hello: shows which badge this is.
    func wave() {
        write("blink")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.say("Hi, it's Jensen") }
    }

    private func stopPaging() {
        pageTimer?.invalidate()
        pageTimer = nil
        paging = []
    }

    @discardableResult
    private func write(_ text: String) -> Bool {
        guard connected, let badge, let commandCharacteristic,
              let data = text.data(using: .utf8), !data.isEmpty else { return false }
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

    /// Text cut at word boundaries into screenfuls of about 40 characters, at most five.
    static func pages(of text: String) -> [String] {
        var pages: [String] = []
        var page = ""
        for word in forBadgeLong(text).split(separator: " ") {
            if page.isEmpty { page = String(word) }
            else if page.count + 1 + word.count <= 40 { page += " " + word }
            else { pages.append(page); page = String(word) }
        }
        if !page.isEmpty { pages.append(page) }
        return Array(pages.prefix(5))
    }

    private static func forBadgeLong(_ text: String) -> String {
        text.split(separator: " ").map { forBadge(String($0)) }.joined(separator: " ")
    }

    // MARK: Pairing

    /// Look for badges nearby, to pick one to pair with.
    func startScan() {
        guard central.state == .poweredOn else { return }
        found = []
        seen = [:]
        scanning = true
        // A badge this iPhone is already connected to doesn't advertise: list it too.
        for peripheral in central.retrieveConnectedPeripherals(withServices: [Self.service]) {
            seen[peripheral.identifier] = peripheral
            found.append(FoundBadge(id: peripheral.identifier, name: peripheral.name ?? "Basecamp Badge", rssi: -50))
        }
        central.scanForPeripherals(withServices: [Self.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        log.info("scanning")
    }

    func stopScan() {
        guard scanning else { return }
        scanning = false
        if central.state == .poweredOn { central.stopScan() }
    }

    /// Pair with a badge from the scan: connect, and remember it once it answers.
    func pair(_ id: UUID) {
        guard let peripheral = seen[id] else { return }
        stopScan()
        if let badge, badge.identifier != id { central.cancelPeripheralConnection(badge) }
        paired = id
        connect(peripheral)
        phase = .connecting
        log.info("pairing with \(id)")
    }

    /// Forget the remembered badge.
    func forget() {
        stopPaging()
        if let badge { central.cancelPeripheralConnection(badge) }
        paired = nil
        clear()
        phase = central.state == .poweredOn ? .unpaired : phase
    }

    // MARK: Staying connected

    /// Ask for the remembered badge. The request stays open until it is in reach.
    private func reconnect() {
        guard central.state == .poweredOn, let paired else {
            if central.state == .poweredOn { phase = .unpaired }
            return
        }
        let peripheral = badge?.identifier == paired ? badge
            : central.retrievePeripherals(withIdentifiers: [paired]).first
        guard let peripheral else {
            // This iPhone no longer knows it (Bluetooth was reset): pair again.
            log.info("remembered badge unknown to this iPhone")
            self.paired = nil
            phase = .unpaired
            return
        }
        connect(peripheral)
    }

    private func connect(_ peripheral: CBPeripheral) {
        badge = peripheral
        peripheral.delegate = self
        phase = peripheral.state == .connected ? .connecting : .away
        if peripheral.state == .connected {
            peripheral.discoverServices([Self.service])
        } else {
            central.connect(peripheral)
        }
    }

    private func clear() {
        badge = nil
        statusCharacteristic = nil
        commandCharacteristic = nil
        status = nil
    }
}

extension BadgeLink: CBCentralManagerDelegate {
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // Woken in the background by the badge: carry on with the peripheral the system kept.
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let mine = peripherals.first(where: { $0.identifier == paired }) {
            badge = mine
            mine.delegate = self
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log.info("bluetooth state \(central.state.rawValue)")
        switch central.state {
        case .poweredOn:
            reconnect()
            if scanning { startScan() }
        case .unauthorized:
            phase = .notAllowed
        default:
            clear()
            phase = .bluetoothOff
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let rssi = RSSI.intValue
        guard rssi < 0 else { return }  // 127: not known
        seen[peripheral.identifier] = peripheral
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "Basecamp Badge"
        if let at = found.firstIndex(where: { $0.id == peripheral.identifier }) {
            // Smooth the signal so the list doesn't jump around.
            found[at].rssi = (found[at].rssi * 3 + rssi) / 4
        } else {
            found.append(FoundBadge(id: peripheral.identifier, name: name, rssi: rssi))
            log.info("found \(name) \(peripheral.identifier) \(rssi)")
        }
        found.sort { $0.rssi > $1.rssi }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log.info("connected \(peripheral.identifier)")
        guard peripheral.identifier == paired else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        phase = .connecting
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log.info("failed to connect: \(error?.localizedDescription ?? "-")")
        guard peripheral.identifier == paired else { return }
        clear()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.reconnect() }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log.info("disconnected: \(error?.localizedDescription ?? "-")")
        guard peripheral.identifier == paired else { return }
        stopPaging()
        clear()
        reconnect()
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
        let first = phase != .ready && UserDefaults.standard.string(forKey: "badge-greeted") != paired?.uuidString
        phase = .ready
        log.info("ready")
        peripheral.setNotifyValue(true, for: statusCharacteristic)
        peripheral.readValue(for: statusCharacteristic)
        if first {
            // Newly paired: show on the badge which one it is.
            UserDefaults.standard.set(paired?.uuidString, forKey: "badge-greeted")
            write("blink")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.say("Paired with Jensen") }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.statusValue, error == nil, let data = characteristic.value else { return }
        if let decoded = try? JSONDecoder().decode(BadgeStatus.self, from: data) {
            status = decoded
        }
    }
}

import CoreBluetooth
import Foundation
import OSLog
import UIKit

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
    /// The name this iPhone has cached for the board when it differs ("Concrete Badge" from
    /// older firmware): the advert has no room for the name, so iOS shows the old one.
    var cachedName: String?

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
    /// For the status line: what Bluetooth is doing, what it sees, what went wrong last.
    @Published private(set) var seenCount = 0
    @Published private(set) var lastError: String?
    @Published private(set) var power = "unknown"
    private var seenNames: [UUID: (name: String, rssi: Int)] = [:]
    private var connectTimer: Timer?
    private var timeouts = 0
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
    /// A JPEG for the card over the face, in pieces (badge firmware 9987073, src/ble.rs).
    private static let pictureValue = CBUUID(string: "BA5ECA3B-0004-4B1D-9E5A-0D1E2F3A4B5C")
    private static let saved = "badge-id"

    private var central: CBCentralManager!
    /// The badge being connected to or connected (remembered, or being paired).
    private var badge: CBPeripheral?
    /// Peripherals seen by the scan, kept so one can be connected to.
    private var seen: [UUID: CBPeripheral] = [:]
    private var statusCharacteristic: CBCharacteristic?
    private var commandCharacteristic: CBCharacteristic?
    private var pictureCharacteristic: CBCharacteristic?
    /// The picture's pieces still to send.
    private var pieces: [Data] = []
    /// A picture waiting for its line to arrive.
    private var afterLine: UIImage?
    @Published private(set) var lastPicture: String?
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

    /// A place the brain picked, as "headline|why" for the badge to show and read.
    @discardableResult
    func pick(headline: String, why: String, picture: UIImage? = nil) -> Bool {
        stopPaging()
        // The picture follows once the badge has the line (src/ble.rs: "Send it after the place's line").
        afterLine = picture
        let clean = { (text: String) in Self.latin(text).replacingOccurrences(of: "|", with: "/") }
        return write(String((clean(headline) + "|" + clean(why)).prefix(400)))
    }

    /// An answer to a question: a longer line, which the badge shows as a card of text.
    @discardableResult
    func answer(_ text: String) -> Bool {
        stopPaging()
        afterLine = nil
        return write(String(Self.latin(text).replacingOccurrences(of: "|", with: "/").prefix(400)))
    }

    /// Send a place's picture after its line: a JPEG of 234 x 182 (what the badge takes
    /// fastest), the first piece "JPG1" and the length (4 bytes, low byte first), then the
    /// bytes in as many writes as it takes, without waiting for each one.
    @discardableResult
    func sendPicture(_ image: UIImage) -> Bool {
        guard connected, let badge, pictureCharacteristic != nil,
              let jpeg = Self.cardJPEG(image) else { return false }
        var all = Data("JPG1".utf8)
        withUnsafeBytes(of: UInt32(jpeg.count).littleEndian) { all.append(contentsOf: $0) }
        all.append(jpeg)
        let size = max(20, badge.maximumWriteValueLength(for: .withoutResponse))
        pieces = stride(from: 0, to: all.count, by: size).map { all.subdata(in: $0..<min($0 + size, all.count)) }
        lastPicture = "\(jpeg.count) bytes in \(pieces.count) pieces"
        print("badge: picture \(jpeg.count) bytes, \(pieces.count) pieces of \(size)")
        sendPieces()
        return true
    }

    private func sendPieces() {
        guard let badge, let pictureCharacteristic else { pieces = []; return }
        while !pieces.isEmpty, badge.canSendWriteWithoutResponse {
            badge.writeValue(pieces.removeFirst(), for: pictureCharacteristic, type: .withoutResponse)
        }
    }

    /// The picture cropped to fill 234 x 182, as a JPEG.
    private static func cardJPEG(_ image: UIImage) -> Data? {
        let box = CGSize(width: 234, height: 182)
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = max(box.width / image.size.width, box.height / image.size.height)
        let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let card = UIGraphicsImageRenderer(size: box, format: format).image { _ in
            image.draw(in: CGRect(x: (box.width - drawn.width) / 2, y: (box.height - drawn.height) / 2,
                                  width: drawn.width, height: drawn.height))
        }
        return card.jpegData(compressionQuality: 0.75)
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
        String(latin(text).prefix(60))
    }

    /// Text in the badge font's letters (Latin-1), without line breaks.
    static func latin(_ text: String) -> String {
        let plain = text
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2014}", with: "-")
        let latin = plain.applyingTransform(.toLatin, reverse: false) ?? plain
        let shown = String(latin.unicodeScalars.filter { $0.value >= 0x20 && $0.value <= 0xFF }.map(Character.init))
        return shown.trimmingCharacters(in: .whitespaces)
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
        // No service filter: the advert may not carry the 128-bit service UUID (it doesn't fit
        // with the name in 31 bytes). Badges are matched by name or by service below.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        log.info("scanning")
    }

    func stopScan() {
        guard scanning, phase == .ready else { return }  // until connected: keep looking, for the status line
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
        // Not connected within 12 s (the badge busy with the laptop's bridge): start again.
        connectTimer?.invalidate()
        connectTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            guard let self, self.phase != .ready, self.paired == peripheral.identifier else { return }
            self.timeouts += 1
            self.lastError = "connect timed out \(self.timeouts)x, retrying (if this repeats: Settings, Bluetooth, Concrete Badge (i), Forget This Device)"
            self.central.cancelPeripheralConnection(peripheral)
            self.clear()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.reconnect() }
        }
        phase = peripheral.state == .connected ? .connecting : .away
        if peripheral.state == .connected {
            peripheral.discoverServices([Self.service])
        } else {
            central.connect(peripheral)
        }
    }

    private func clear() {
        pieces = []
        afterLine = nil
        pictureCharacteristic = nil
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
        power = switch central.state {
        case .poweredOn: "on"
        case .poweredOff: "OFF"
        case .unauthorized: "unauthorized"
        case .unsupported: "unsupported"
        case .resetting: "resetting"
        default: "unknown"
        }
        switch central.state {
        case .poweredOn:
            reconnect()
            startScan()
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
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            + (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
        if seenNames[peripheral.identifier] == nil { seenCount += 1 }
        seenNames[peripheral.identifier] = (name.isEmpty ? "?" : name, rssi)
        let isBadge = name.localizedCaseInsensitiveContains("basecamp") || services.contains(Self.service)
        guard isBadge, rssi < 0 else { return }  // 127: not known
        seen[peripheral.identifier] = peripheral
        // The remembered badge is advertising: connect now (the standing request may have lapsed).
        // (Only when no attempt is pending: adverts arrive many times a second.)
        if peripheral.identifier == paired, phase == .away, connectTimer?.isValid != true {
            connect(peripheral)
        }
        // Our service in the advert means the hackathon firmware, whatever name iOS remembers.
        let shown = services.contains(Self.service) || name.isEmpty ? "Basecamp Badge" : name
        let cached = (name.isEmpty || name == shown) ? nil : name
        if let at = found.firstIndex(where: { $0.id == peripheral.identifier }) {
            // Smooth the signal so the list doesn't jump around.
            found[at].rssi = (found[at].rssi * 3 + rssi) / 4
        } else {
            found.append(FoundBadge(id: peripheral.identifier, name: shown, rssi: rssi, cachedName: cached))
            log.info("found \(shown) \(peripheral.identifier) \(rssi)")
        }
        found.sort { $0.rssi > $1.rssi }
    }

    /// One line for the screen: authorization, power, scanning, badges and devices seen, last error.
    var statusLine: String {
        let auth: String = switch CBManager.authorization {
        case .allowedAlways: "allowed"
        case .denied: "DENIED"
        case .restricted: "restricted"
        case .notDetermined: "not asked"
        @unknown default: "?"
        }
        let badges = found.prefix(3).map { "\($0.name)\($0.cachedName.map { " (iOS: \($0))" } ?? "") \($0.rssi)\($0.id == paired ? " paired" : "")" }.joined(separator: ", ")
        var line = "BT \(auth) · \(power) · \(scanning ? "scanning" : "not scanning") · \(phaseWord)"
        line += " · badges: \(badges.isEmpty ? "none" : badges) · \(seenCount) devices"
        if let lastPicture { line += " · last picture: \(lastPicture)" }
        if let lastError { line += " · last error: \(lastError)" }
        return line
    }

    private var phaseWord: String {
        switch phase {
        case .ready: "connected"
        case .connecting: "connecting"
        case .away: "waiting for remembered badge (link: \(["disconnected", "connecting", "connected", "disconnecting"][min(badge?.state.rawValue ?? 0, 3)]))"
        case .unpaired: "not paired"
        case .bluetoothOff: "off"
        case .notAllowed: "not allowed"
        }
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
        if let error = error as? CBError, error.code == .peerRemovedPairingInformation || error.code == .encryptionTimedOut {
            lastError = "this iPhone still has the old Concrete pairing: Settings, Bluetooth, Concrete Badge (i), Forget This Device"
        } else {
            lastError = "connect failed: \(error?.localizedDescription ?? "unknown")"
        }
        guard peripheral.identifier == paired else { return }
        clear()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.reconnect() }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log.info("disconnected: \(error?.localizedDescription ?? "-")")
        if let error { lastError = "disconnected: \(error.localizedDescription)" }
        guard peripheral.identifier == paired else { return }
        stopPaging()
        clear()
        reconnect()
        startScan()
    }
}

extension BadgeLink: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            lastError = "badge service not found (\(error?.localizedDescription ?? "\(peripheral.services?.count ?? 0) services")): Settings, Bluetooth, Concrete Badge (i), Forget This Device, then Pair again"
            return
        }
        peripheral.discoverCharacteristics([Self.statusValue, Self.commandValue, Self.pictureValue], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == Self.statusValue { statusCharacteristic = characteristic }
            if characteristic.uuid == Self.commandValue { commandCharacteristic = characteristic }
            if characteristic.uuid == Self.pictureValue { pictureCharacteristic = characteristic }
        }
        guard let statusCharacteristic, commandCharacteristic != nil else { return }
        connectTimer?.invalidate()
        lastError = nil
        let first = phase != .ready && UserDefaults.standard.string(forKey: "badge-greeted") != paired?.uuidString
        defer { stopScan() }
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

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        sendPieces()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { lastError = "write failed: \(error.localizedDescription)" }
        if characteristic.uuid == Self.commandValue, let picture = afterLine {
            afterLine = nil
            if error == nil { sendPicture(picture) }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.statusValue, error == nil, let data = characteristic.value else { return }
        if let decoded = try? JSONDecoder().decode(BadgeStatus.self, from: data) {
            status = decoded
        }
    }
}

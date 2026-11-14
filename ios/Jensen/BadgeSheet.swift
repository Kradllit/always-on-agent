import SwiftUI

/// Pairing with the badge: scan, pick one, and from then on it is remembered and reconnects
/// by itself. Opened by tapping the badge line in the chat header.
struct BadgeSheet: View {
    @EnvironmentObject private var badge: BadgeLink
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if badge.paired != nil {
                    pairedSection
                }
                if badge.paired == nil || badge.phase != .ready {
                    scanSection
                }
            }
            .safeAreaInset(edge: .bottom) {
                // Bluetooth's details, for when the badge won't connect.
                Text(badge.statusLine)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.bar)
                    .textSelection(.enabled)
            }
            .navigationTitle("Badge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { if badge.phase != .ready { badge.startScan() } }
        .onDisappear { badge.stopScan() }
        .onChange(of: badge.paired) { if badge.paired == nil { badge.startScan() } }
    }

    private var pairedSection: some View {
        Group {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "circle.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(badge.phase == .ready ? Color.green : Color.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Basecamp Badge").font(.headline)
                        Text(state).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                if let status = badge.status {
                    LabeledContent("Battery", value: "\(status.battery)%\(status.charging ? ", charging" : "")")
                    LabeledContent("Mood", value: status.mood)
                }
            } footer: {
                Text(badge.phase == .ready
                     ? "Places Jensen finds show on this badge."
                     : "Remembered. It reconnects by itself when it is on and near this iPhone.")
            }
            Section {
                Button("Wave from the badge", systemImage: "hand.wave") { badge.wave() }
                    .disabled(badge.phase != .ready)
                Button("Forget this badge", systemImage: "xmark.circle", role: .destructive) { badge.forget() }
            }
        }
    }

    private var scanSection: some View {
        Section {
            if let problem = badge.lastError {
                Text(problem).font(.footnote).foregroundStyle(.orange)
            }
            if badge.found.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(scanText).foregroundStyle(.secondary)
                }
            }
            ForEach(badge.found) { found in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(found.name).font(.headline)
                        Text(found.nearness + (found.cachedName.map { " · this iPhone calls it \($0)" } ?? ""))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if found.id == badge.paired {
                        Text("Paired").foregroundStyle(.secondary)
                    } else {
                        Button("Pair") { badge.pair(found.id) }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        } header: {
            Text("Badges nearby")
        } footer: {
            Text("Turn the badge on and hold it near the iPhone. Badges running the hackathon firmware are listed, the nearest at the top, and the one you pair says \"Paired with Jensen\". If none shows up, another phone may be connected to it.")
        }
    }

    private var scanText: String {
        switch badge.phase {
        case .bluetoothOff: "Bluetooth is off. Turn it on in Control Center."
        case .notAllowed: "Allow Bluetooth for Jensen in Settings."
        default: "Looking for badges"
        }
    }

    private var state: String {
        switch badge.phase {
        case .ready: "Connected"
        case .connecting: "Connecting"
        case .away: "Out of reach, waiting for it"
        case .bluetoothOff: "Bluetooth off"
        case .notAllowed: "Bluetooth not allowed"
        case .unpaired: "Not paired"
        }
    }
}

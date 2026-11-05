import SwiftUI

struct ScooterView: View {
    @ObservedObject var ble: BLEManager

    var body: some View {
        NavigationStack {
            List {
                Section("Status") {
                    Text(ble.bluetoothState)
                    Text(ble.connectionStatus)
                }

                if ble.connected != nil {
                    connectedSection
                    Section("Services and characteristics") {
                        if ble.characteristicsInfo.isEmpty {
                            Text("Discovering...").foregroundColor(.secondary)
                        }
                        ForEach(Array(ble.characteristicsInfo.enumerated()), id: \.offset) { item in
                            Text(item.element)
                                .font(.caption.monospaced())
                        }
                    }
                } else {
                    scanSection
                    devicesSection
                }

                Section {
                    Text("Read-only v1. The only thing this app can send is the heartbeat, and it is off unless you turn it on. Packet meanings are guesses from the vendor app (UNVERIFIED).")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("J078")
        }
    }

    private var connectedSection: some View {
        Section("Connected") {
            Toggle("Heartbeat (A5 02 FD 5A on F1F1)", isOn: Binding(
                get: { ble.heartbeatOn },
                set: { ble.setHeartbeat($0) }
            ))
            .disabled(!ble.hasF1F1)
            if !ble.hasF1F1 {
                Text("No F1F1 characteristic found, heartbeat unavailable.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            Text("Heartbeats sent: \(ble.heartbeatsSent)")
            Toggle("Show each heartbeat in the log", isOn: $ble.logEachHeartbeat)
            Button("Disconnect", role: .destructive) {
                ble.disconnect()
            }
        }
    }

    private var scanSection: some View {
        Section("Scan") {
            Toggle("Only scooter services (F1F0 / F2F0 / 6E400001)", isOn: $ble.filterKnownServices)
            Button(ble.isScanning ? "Stop scan" : "Start scan") {
                if ble.isScanning {
                    ble.stopScan()
                } else {
                    ble.startScan()
                }
            }
            if ble.connectionStatus.hasPrefix("Connecting") {
                Button("Cancel connecting", role: .cancel) {
                    ble.disconnect()
                }
            }
        }
    }

    private var devicesSection: some View {
        Section("Devices (\(ble.devices.count))") {
            ForEach(ble.devices) { d in
                Button {
                    ble.connect(d)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(d.name).font(.headline)
                            Spacer()
                            Text("\(d.rssi) dBm").font(.caption).foregroundColor(.secondary)
                        }
                        if !d.advertisedServices.isEmpty {
                            Text("Services: " + d.advertisedServices.joined(separator: ", "))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        if !d.manufacturerData.isEmpty {
                            // The app checks the first 4 bytes of this (UNVERIFIED).
                            Text("Mfg data: " + J078.hex(Array(d.manufacturerData.prefix(12))))
                                .font(.caption.monospaced())
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .foregroundColor(.primary)
            }
        }
    }
}

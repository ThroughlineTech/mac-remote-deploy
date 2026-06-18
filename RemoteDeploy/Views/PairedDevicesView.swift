// Displays a list of paired companion devices with the ability to
// revoke access. Shown as a tab in the Settings window.
import SwiftUI
import RemoteDeployShared

/// Lists paired companion devices and provides management controls.
///
/// TKT-056 (Phase 3): the device list + revoke flow through the API client. The
/// "Pair New Device" QR flow stays local (the Mac mints a pending token via the
/// pairing handler -- there is no client API for that direction).
struct PairedDevicesTab: View {
    @EnvironmentObject var serviceContainer: ServiceContainer
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var menuBarClient: MenuBarClient

    /// Whether the pair device sheet is showing.
    @State private var showingPairSheet = false

    /// Paired devices (the menu bar's own loopback record is filtered out).
    private var devices: [PairedDevice] { menuBarClient.devices }

    var body: some View {
        VStack {
            if devices.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "iphone.slash")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No paired devices")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Pair a device to control builds from your phone.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(devices) { device in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(device.name)
                                    .font(.headline)
                                HStack(spacing: 8) {
                                    Text("Paired: \(device.pairedAt.formatted(date: .abbreviated, time: .shortened))")
                                    Text("Last seen: \(device.lastSeen.formatted(date: .abbreviated, time: .shortened))")
                                }
                                .font(.caption)
                                .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("Revoke") {
                                Task { await menuBarClient.revokeDevice(id: device.id) }
                            }
                            .buttonStyle(.borderless)
                            .foregroundColor(.red)
                        }
                    }
                }
            }

            HStack {
                Button {
                    showingPairSheet = true
                } label: {
                    Label("Pair New Device", systemImage: "qrcode")
                }
                .disabled(appState.serverURL.isEmpty)

                Spacer()

                Text("\(devices.count) device\(devices.count == 1 ? "" : "s") paired")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .task {
            await menuBarClient.refreshDevices()
        }
        .sheet(isPresented: $showingPairSheet) {
            PairDeviceView(onDismiss: {
                showingPairSheet = false
                Task { await menuBarClient.refreshDevices() }
            })
            .environmentObject(appState)
            .environmentObject(serviceContainer)
        }
    }
}

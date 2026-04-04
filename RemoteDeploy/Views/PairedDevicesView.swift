// Displays a list of paired companion devices with the ability to
// revoke access. Shown as a tab in the Settings window.
import SwiftUI
import RemoteDeployShared

/// Lists paired companion devices and provides management controls.
struct PairedDevicesTab: View {
    @EnvironmentObject var serviceContainer: ServiceContainer
    @EnvironmentObject var appState: AppState

    /// The list of currently paired devices.
    @State private var devices: [PairedDevice] = []
    /// Whether the pair device sheet is showing.
    @State private var showingPairSheet = false
    /// Error message for display.
    @State private var errorMessage: String?

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
                                revokeDevice(device)
                            }
                            .buttonStyle(.borderless)
                            .foregroundColor(.red)
                        }
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal)
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
        .onAppear {
            loadDevices()
        }
        .sheet(isPresented: $showingPairSheet) {
            PairDeviceView(onDismiss: {
                showingPairSheet = false
                loadDevices()
            })
            .environmentObject(appState)
            .environmentObject(serviceContainer)
        }
    }

    /// Loads the list of paired devices from the store.
    private func loadDevices() {
        do {
            devices = try serviceContainer.pairedDeviceStore.loadDevices()
            errorMessage = nil
        } catch {
            errorMessage = "Failed to load devices: \(error.localizedDescription)"
        }
    }

    /// Revokes a paired device's access.
    private func revokeDevice(_ device: PairedDevice) {
        do {
            try serviceContainer.pairedDeviceStore.delete(deviceID: device.id)
            loadDevices()
        } catch {
            errorMessage = "Failed to revoke device: \(error.localizedDescription)"
        }
    }
}

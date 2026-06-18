// Displays a list of paired companion devices with the ability to
// revoke access. Shown as a tab in the Settings window.
import SwiftUI
import RemoteDeployShared

/// Lists paired companion devices and provides management controls.
///
/// TKT-056 (Phase 3): the device list + revoke flow through the API client.
/// TKT-060 (Phase 6): the "Pair New/Browser" flows also go through the API --
/// the server mints the pending token (POST /api/v1/pair/pending).
struct PairedDevicesTab: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var menuBarClient: MenuBarClient

    /// Which pairing sheet is showing (device QR or browser code), if any.
    private enum PairSheet: Int, Identifiable {
        case device, browser
        var id: Int { rawValue }
    }
    @State private var activeSheet: PairSheet?

    /// Pairing needs HTTPS (the server rejects /api/v1/pair over plain HTTP), so
    /// gate the pairing actions on the server reporting HTTPS up. TKT-060.
    private var serverHTTPSReady: Bool { menuBarClient.status?.serverRunning ?? false }

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
                    activeSheet = .device
                } label: {
                    Label("Pair New Device", systemImage: "qrcode")
                }
                .disabled(!serverHTTPSReady)

                Button {
                    activeSheet = .browser
                } label: {
                    Label("Pair Browser", systemImage: "globe")
                }
                .disabled(!serverHTTPSReady)

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
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .device:
                PairDeviceView(onDismiss: {
                    activeSheet = nil
                    Task { await menuBarClient.refreshDevices() }
                })
                .environmentObject(appState)
                .environmentObject(menuBarClient)
            case .browser:
                PairBrowserView(onDismiss: {
                    activeSheet = nil
                    Task { await menuBarClient.refreshDevices() }
                })
                .environmentObject(appState)
                .environmentObject(menuBarClient)
            }
        }
    }
}

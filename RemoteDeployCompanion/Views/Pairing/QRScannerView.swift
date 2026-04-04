// Camera-based QR code scanner for pairing with a RemoteDeploy Mac.
// Uses AVFoundation to detect QR codes and parse the pairing JSON payload.
import SwiftUI
import AVFoundation

/// QR code scanner for pairing with a Mac server.
struct QRScannerView: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @Environment(\.dismiss) var dismiss

    @State private var isPairing = false
    @State private var error: String?
    @State private var scannedCode: String?

    var body: some View {
        NavigationStack {
            ZStack {
                QRCameraPreview(onCodeScanned: { code in
                    guard scannedCode == nil else { return }
                    scannedCode = code
                    handleScannedCode(code)
                })
                .ignoresSafeArea()

                VStack {
                    Spacer()

                    // Scanning guide overlay
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.white.opacity(0.7), lineWidth: 3)
                        .frame(width: 250, height: 250)
                        .shadow(radius: 8)

                    Spacer()

                    if isPairing {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Pairing with server...")
                                .font(.headline)
                                .foregroundColor(.white)
                        }
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                    }

                    if let error {
                        Text(error)
                            .font(.callout)
                            .foregroundColor(.white)
                            .padding()
                            .background(Color.red.opacity(0.8))
                            .cornerRadius(8)
                            .onTapGesture {
                                self.error = nil
                                scannedCode = nil
                            }
                    }

                    Spacer().frame(height: 60)
                }
            }
            .navigationTitle("Scan QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func handleScannedCode(_ code: String) {
        guard let data = code.data(using: .utf8) else {
            error = "Invalid QR code"
            return
        }

        struct PairingPayload: Codable {
            var url: String
            var token: String
            var serverName: String
            var localURL: String?
        }

        guard let payload = try? JSONDecoder().decode(PairingPayload.self, from: data) else {
            error = "Not a RemoteDeploy QR code"
            scannedCode = nil
            return
        }

        isPairing = true
        Task {
            // Try the primary URL (Tailscale) first, fall back to local URL
            do {
                try await connectionManager.pair(url: payload.url, token: payload.token, serverName: payload.serverName)
                dismiss()
                return
            } catch {
                print("Pairing via Tailscale URL failed: \(error.localizedDescription)")
            }

            // Fall back to local URL if available
            if let localURL = payload.localURL {
                do {
                    try await connectionManager.pair(url: localURL, token: payload.token, serverName: payload.serverName)
                    dismiss()
                    return
                } catch {
                    self.error = "Could not reach server.\nTried: \(payload.url)\nand: \(localURL)"
                    scannedCode = nil
                }
            } else {
                self.error = "Could not reach server at \(payload.url). Is Tailscale connected on this device?"
                scannedCode = nil
            }
            isPairing = false
        }
    }
}

/// UIViewControllerRepresentable wrapper for AVCaptureSession QR code scanning.
/// Using a view controller ensures proper lifecycle management and layout.
struct QRCameraPreview: UIViewControllerRepresentable {
    let onCodeScanned: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let vc = QRScannerViewController()
        vc.onCodeScanned = onCodeScanned
        return vc
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}
}

/// View controller that manages the AVCaptureSession and camera preview layer.
class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {

    var onCodeScanned: ((String) -> Void)?

    private let captureSession = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasScanned = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !captureSession.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.captureSession.startRunning()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if captureSession.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.captureSession.stopRunning()
            }
        }
    }

    private func setupCamera() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            showNoCameraLabel()
            return
        }

        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
        }

        let output = AVCaptureMetadataOutput()
        if captureSession.canAddOutput(output) {
            captureSession.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
        }

        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer
    }

    private func showNoCameraLabel() {
        let label = UILabel()
        label.text = "Camera not available"
        label.textColor = .white
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    // MARK: - AVCaptureMetadataOutputObjectsDelegate

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !hasScanned,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let value = object.stringValue else { return }
        hasScanned = true

        // Haptic feedback on successful scan
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)

        onCodeScanned?(value)
    }
}

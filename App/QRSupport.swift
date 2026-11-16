import SwiftUI
import UIKit
import VisionKit
import AVFoundation
import CoreImage.CIFilterBuiltins

enum QRCode {
    static func image(for string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "H"
        guard let output = filter.outputImage?
            .transformed(by: CGAffineTransform(scaleX: 20, y: 20)) else { return nil }
        guard let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }

        // 加白邊（quiet zone），印出來比較好掃
        let margin: CGFloat = 80
        let size = CGSize(width: CGFloat(cgImage.width) + margin * 2,
                          height: CGFloat(cgImage.height) + margin * 2)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIImage(cgImage: cgImage).draw(in: CGRect(x: margin, y: margin,
                                                      width: CGFloat(cgImage.width),
                                                      height: CGFloat(cgImage.height)))
        }
    }
}

/// VisionKit 的 QR 掃描器，掃到第一個 QR 就回傳內容。
/// 相機要等畫面真的出現（viewDidAppear）才能啟動；太早呼叫 startScanning 會失敗、只剩黑畫面。
/// 所以包一層容器，在 viewDidAppear 啟動，失敗就重試幾次。
struct QRScannerView: UIViewControllerRepresentable {
    let onFound: (String) -> Void

    static var isSupported: Bool { DataScannerViewController.isSupported }
    /// false = 相機權限被拒（還沒問過時不算，startScanning 會跳出詢問）
    static var isAvailable: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        return status != .denied && status != .restricted
    }

    func makeUIViewController(context: Context) -> ScannerHost {
        ScannerHost(onFound: onFound)
    }

    func updateUIViewController(_ host: ScannerHost, context: Context) {}

    final class ScannerHost: UIViewController, DataScannerViewControllerDelegate {
        private let onFound: (String) -> Void
        private var done = false
        private let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )

        init(onFound: @escaping (String) -> Void) {
            self.onFound = onFound
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            scanner.delegate = self
            addChild(scanner)
            scanner.view.frame = view.bounds
            scanner.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(scanner.view)
            scanner.didMove(toParent: self)
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            start(attempt: 1)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if scanner.isScanning { scanner.stopScanning() }
        }

        private func start(attempt: Int) {
            guard !done, !scanner.isScanning, view.window != nil else { return }
            do {
                try scanner.startScanning()
                Log.write("📷 QR 相機已啟動（第 \(attempt) 次）")
            } catch {
                Log.write("QR 掃描器啟動失敗（第 \(attempt) 次）：\(error)（可用：\(DataScannerViewController.isAvailable)）")
                guard attempt < 5 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.start(attempt: attempt + 1)
                }
            }
        }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in addedItems {
                if case .barcode(let code) = item, let payload = code.payloadStringValue {
                    done = true
                    dataScanner.stopScanning()
                    onFound(payload)
                    return
                }
            }
        }
    }
}

struct QRScannerSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Group {
                if !QRScannerView.isSupported {
                    Text("這台裝置不支援 QR 掃描").padding()
                } else if !QRScannerView.isAvailable {
                    VStack(spacing: 12) {
                        Image(systemName: "camera.fill").font(.largeTitle).foregroundStyle(.orange)
                        Text("相機不能用").font(.headline)
                        Text("到 設定 > 起床 > 相機 打開權限，再回來掃。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else {
                    QRScannerView { payload in model.handleQR(payload) }
                        .ignoresSafeArea()
                }
            }
            .navigationTitle("掃\(model.state.scanLocation)的 QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉") { model.showQRScanner = false }
                }
            }
        }
    }
}

struct QRCodeSheet: View {
    let token: String

    var body: some View {
        VStack(spacing: 20) {
            if let uiImage = QRCode.image(for: token) {
                let image = Image(uiImage: uiImage)
                image
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(.horizontal, 32)
                ShareLink(item: image, preview: SharePreview("起床 QR Code", image: image)) {
                    Label("儲存圖片（拿去 7-11 印）", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("QR Code 產生失敗")
            }
            Text("分享選單裡選「儲存影像」。印好之後，把相簿裡這張圖刪掉（連「最近刪除」也要清），不然清醒時的你可以用另一台裝置顯示它來作弊。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
        }
        .padding(.vertical, 32)
        .presentationDetents([.large])
    }
}

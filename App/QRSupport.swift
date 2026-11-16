import SwiftUI
import UIKit
import VisionKit
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
struct QRScannerView: UIViewControllerRepresentable {
    let onFound: (String) -> Void

    static var isSupported: Bool { DataScannerViewController.isSupported }

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        guard !scanner.isScanning, !context.coordinator.done else { return }
        do { try scanner.startScanning() }
        catch { Log.write("QR 掃描器啟動失敗：\(error)（相機權限？）") }
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onFound: (String) -> Void
        var done = false

        init(onFound: @escaping (String) -> Void) { self.onFound = onFound }

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
                if QRScannerView.isSupported {
                    QRScannerView { payload in model.handleQR(payload) }
                        .ignoresSafeArea()
                } else {
                    Text("這台裝置不支援 QR 掃描").padding()
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

import Foundation
import CoreNFC

/// 讀取 NFC 標籤的硬體 UID（不是 NDEF 內容），一般空白貼紙無法複製。
final class NFCScanner: NSObject, NFCTagReaderSessionDelegate {
    private var session: NFCTagReaderSession?
    private var completion: ((Result<String, Error>) -> Void)?

    struct ScanError: LocalizedError {
        let errorDescription: String?
    }

    func scan(completion: @escaping (Result<String, Error>) -> Void) {
        guard NFCTagReaderSession.readingAvailable else {
            completion(.failure(ScanError(errorDescription: "此裝置不支援 NFC 讀取")))
            return
        }
        self.completion = completion
        session = NFCTagReaderSession(pollingOption: [.iso14443, .iso15693], delegate: self, queue: nil)
        session?.alertMessage = "把手機靠近浴室的標籤"
        session?.begin()
    }

    private func finish(_ result: Result<String, Error>) {
        guard let completion else { return }
        self.completion = nil
        DispatchQueue.main.async { completion(result) }
    }

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        finish(.failure(error))
        self.session = nil
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard let tag = tags.first else { return }
        session.connect(to: tag) { [weak self] error in
            if let error {
                session.invalidate(errorMessage: "連線失敗，再試一次")
                self?.finish(.failure(error))
                return
            }
            var uid: Data?
            switch tag {
            case .miFare(let t): uid = t.identifier
            case .iso7816(let t): uid = t.identifier
            case .iso15693(let t): uid = t.identifier
            case .feliCa(let t): uid = t.currentIDm
            @unknown default: uid = nil
            }
            guard let uid else {
                session.invalidate(errorMessage: "讀不到 UID")
                self?.finish(.failure(ScanError(errorDescription: "讀不到 UID")))
                return
            }
            let hex = uid.map { String(format: "%02X", $0) }.joined()
            session.alertMessage = "讀取成功"
            self?.finish(.success(hex))
            session.invalidate()
        }
    }
}

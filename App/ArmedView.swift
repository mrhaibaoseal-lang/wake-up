import SwiftUI
import UIKit
import MediaPlayer

/// 用隱藏的 MPVolumeView 把媒體音量拉到最大（只有 App 在前景時有效；引導使用模式下 App 一直在前景）。
enum VolumeForcer {
    private static var volumeView: MPVolumeView?

    static func setMax() {
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first else { return }
        if volumeView == nil || volumeView?.window == nil {
            let view = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 100, height: 40))
            view.alpha = 0.01
            window.addSubview(view)
            volumeView = view
        }
        guard let slider = volumeView?.subviews.compactMap({ $0 as? UISlider }).first else { return }
        if slider.value < 0.99 {
            slider.setValue(1.0, animated: false)
            slider.sendActions(for: .valueChanged)
        }
    }
}

enum ScreenDimmer {
    private static var saved: CGFloat?

    private static var screen: UIScreen? {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen
    }

    static func set(_ level: CGFloat) {
        guard let screen else { return }
        if saved == nil { saved = screen.brightness }
        screen.brightness = level
    }

    static func restore() {
        guard let screen, let value = saved else { return }
        screen.brightness = value
        saved = nil
    }
}

/// 上膛中蓋住整個畫面：時間到之前是全黑夜間畫面，時間到之後是只有「掃描」的響鈴畫面。
struct ArmedView: View {
    @Environment(AppModel.self) private var model
    @State private var revealUntil = Date.distantPast

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let due = model.state.alarmDate.map { $0 <= now } ?? true
            let revealed = now < revealUntil || model.scanning
            ZStack {
                Color.black.ignoresSafeArea()
                if due {
                    ringing
                } else if revealed {
                    waiting(now: now)
                } else {
                    night(now: now)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { revealUntil = Date().addingTimeInterval(8) }
            .onChange(of: due ? 1.0 : (revealed ? 0.3 : 0.0), initial: true) { _, level in
                ScreenDimmer.set(level)
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = model.state.keepScreenOn
            // 剛上膛先亮 15 秒，提醒有沒有開引導使用模式；之後自己變全黑（避免烙印）
            revealUntil = Date().addingTimeInterval(15)
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            ScreenDimmer.restore()
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }

    /// 主要的解鎖方式（設定的那種；不能用就換另一種）
    private var primary: UnlockMethod {
        let set = model.state.unlockMethod
        if model.canUnlock(with: set) { return set }
        return set == .qr ? .nfc : .qr
    }

    private var secondary: UnlockMethod? {
        let other: UnlockMethod = primary == .qr ? .nfc : .qr
        return model.canUnlock(with: other) ? other : nil
    }

    private func name(_ method: UnlockMethod) -> String { method == .qr ? "QR Code" : "NFC 卡片" }
    private func icon(_ method: UnlockMethod) -> String { method == .qr ? "qrcode.viewfinder" : "wave.3.right" }
    private func action(_ method: UnlockMethod) -> String { method == .qr ? "掃描 QR Code" : "感應 NFC 卡片" }

    /// 感應中的畫面：引導使用模式下系統的 NFC 視窗不會出現，但感應有效
    private var nfcScanning: some View {
        VStack(spacing: 22) {
            Image(systemName: "wave.3.right")
                .font(.system(size: 72, weight: .semibold))
                .foregroundStyle(Color.wakeAccent)
                .symbolEffect(.pulse)
            Text("感應中…").font(.system(size: 40, weight: .heavy)).foregroundStyle(.white)
            Text("把手機背面上方（相機附近）\n貼近 NFC 卡片，停一兩秒")
                .font(.title3)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text("聲音暫停 \(model.state.bufferSeconds) 秒，時間到還沒感應到會繼續響")
                .font(.footnote)
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
            Button("取消") { model.cancelNFC() }
                .buttonStyle(.bordered)
                .tint(.white)
                .padding(.top, 8)
        }
        .padding(.horizontal, 32)
    }

    private var ringing: some View {
        if model.scanning {
            return AnyView(nfcScanning)
        }
        return AnyView(ringingButtons)
    }

    private var ringingButtons: some View {
        VStack(spacing: 24) {
            Text("起床！").font(.system(size: 64, weight: .heavy)).foregroundStyle(.white)
            Text("去\(model.state.scanLocation)\(primary == .qr ? "掃" : "感應")\(name(primary))才會停")
                .font(.title3)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Button {
                model.beginUnlock(method: primary)
            } label: {
                Label(action(primary), systemImage: icon(primary))
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .padding(.horizontal, 32)
            if let other = secondary {
                Button {
                    model.beginUnlock(method: other)
                } label: {
                    Label("改用\(name(other))", systemImage: icon(other))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .padding(.horizontal, 48)
            }
            if let error = model.unlockError {
                Text(error)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
    }

    private func waiting(now: Date) -> some View {
        if model.scanning {
            return AnyView(nfcScanning)
        }
        return AnyView(waitingInfo(now: now))
    }

    private func waitingInfo(now: Date) -> some View {
        VStack(spacing: 16) {
            Text(now, style: .time).font(.system(size: 56, weight: .light)).foregroundStyle(.white)
            if let date = model.state.alarmDate {
                Text("鬧鐘 \(date.formatted(date: .omitted, time: .shortened))").foregroundStyle(.gray)
            }
            Text(model.guidedAccessOn ? "引導使用模式 ✅" : "⚠️ 還沒開引導使用模式：連按三下側邊按鈕")
                .font(.footnote)
                .foregroundStyle(model.guidedAccessOn ? .gray : .orange)
            Text("要取消只能\(primary == .qr ? "掃 QR Code" : "感應 NFC 卡片")").font(.footnote).foregroundStyle(.gray)
            Button(action(primary) + "解除") { model.beginUnlock(method: primary) }
                .buttonStyle(.bordered)
                .padding(.top, 8)
            if let other = secondary {
                Button("改用\(name(other))") { model.beginUnlock(method: other) }
                    .font(.footnote)
            }
            if let error = model.unlockError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    /// 全黑：不畫任何東西，避免 OLED 烙印。點一下螢幕會顯示 8 秒資訊。
    private func night(now: Date) -> some View {
        Color.black
    }
}

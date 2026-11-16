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
            let revealed = now < revealUntil
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
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            ScreenDimmer.restore()
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }

    private var ringing: some View {
        VStack(spacing: 28) {
            Text("起床！").font(.system(size: 64, weight: .heavy)).foregroundStyle(.white)
            Text("去浴室掃 QR Code 才會停").font(.title3).foregroundStyle(.white)
            Button {
                model.beginUnlock()
            } label: {
                Label("掃描", systemImage: "qrcode.viewfinder")
                    .font(.title.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .padding(.horizontal, 32)
        }
    }

    private func waiting(now: Date) -> some View {
        VStack(spacing: 16) {
            Text(now, style: .time).font(.system(size: 56, weight: .light)).foregroundStyle(.white)
            if let date = model.state.alarmDate {
                Text("鬧鐘 \(date.formatted(date: .omitted, time: .shortened))").foregroundStyle(.gray)
            }
            Text(model.guidedAccessOn ? "引導使用模式 ✅" : "⚠️ 還沒開引導使用模式：連按三下側邊按鈕")
                .font(.footnote)
                .foregroundStyle(model.guidedAccessOn ? .gray : .orange)
            Text("要取消只能掃 QR").font(.footnote).foregroundStyle(.gray)
            Button("掃描 QR 解除") { model.beginUnlock() }
                .buttonStyle(.bordered)
                .padding(.top, 8)
        }
    }

    /// 全黑＋很暗的小時鐘；每分鐘換位置避免烙印
    private func night(now: Date) -> some View {
        let minute = Calendar.current.component(.minute, from: now)
        let dx = CGFloat((minute * 37) % 120) - 60
        let dy = CGFloat((minute * 53) % 300) - 150
        return VStack(spacing: 6) {
            Text(now, style: .time).font(.system(size: 28, weight: .light))
            if !model.guidedAccessOn {
                Text("⚠️ 連按三下側鍵開引導模式").font(.caption2)
            }
        }
        .foregroundStyle(Color(white: model.guidedAccessOn ? 0.18 : 0.5))
        .offset(x: dx, y: dy)
    }
}

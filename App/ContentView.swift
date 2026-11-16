import SwiftUI

// MARK: - 共用樣式

extension Color {
    static let wakeAccent = Color(red: 1.0, green: 0.45, blue: 0.22)
    static let wakeCard = Color(white: 0.11)
}

extension View {
    func card() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.wakeCard, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

struct RowLabel: View {
    let icon: String
    let title: String
    var detail: String? = nil
    var tint: Color = .wakeAccent
    var showChevron = true

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 28)
            Text(title).foregroundStyle(.primary)
            Spacer(minLength: 8)
            if let detail {
                Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            if showChevron {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

struct CheckRow: View {
    let title: String
    let detail: String
    let ok: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.title3)
                .foregroundStyle(ok ? .green : .orange)
                .frame(width: 28)
            Text(title)
            Spacer()
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}

struct StatusPill: View {
    let phase: Phase

    var body: some View {
        let (text, color): (String, Color) = {
            switch phase {
            case .idle: return ("未上膛", .gray)
            case .armed, .buffer: return ("已上膛", .wakeAccent)
            case .verified: return ("已解除", .green)
            }
        }()
        Text(text)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(color)
            .background(color.opacity(0.18), in: Capsule())
    }
}

// MARK: - 主畫面

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var alarmTime = Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var confirmRegenerate = false
    @State private var shownPasscode: String?
    @State private var tab = AppTab.alarm

    enum AppTab: Hashable { case alarm, sleep }

    var body: some View {
        ZStack {
            TabView(selection: $tab) {
                alarmTab
                    .toolbar(model.locked ? .hidden : .visible, for: .tabBar)
                    .tabItem { Label("鬧鐘", systemImage: "alarm.fill") }
                    .tag(AppTab.alarm)
                SleepView()
                    .toolbar(model.locked ? .hidden : .visible, for: .tabBar)
                    .tabItem { Label("睡眠", systemImage: "bed.double.fill") }
                    .tag(AppTab.sleep)
            }
            .tint(.wakeAccent)

            // 上膛／響鈴畫面蓋在分頁列之上：分頁列不能變成逃生口
            if model.locked && !model.showQRScanner {
                ArmedView()
                    .ignoresSafeArea()
                    .zIndex(1)
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: model.locked, initial: true) { _, locked in
            if locked { tab = .alarm }
        }
    }

    private var alarmTab: some View {
        @Bindable var model = model
        return NavigationStack {
                ScrollView {
                    VStack(spacing: 16) {
                        header
                        if model.state.phase == .verified, let code = model.state.guidedPasscode {
                            passcodeCard(code)
                        }
                        alarmCard
                        checklistCard
                        setupCard
                        NavigationLink {
                            AdvancedView()
                        } label: {
                            RowLabel(icon: "slider.horizontal.3", title: "進階設定與除錯")
                        }
                        .buttonStyle(.plain)
                        .card()
                    }
                    .padding(16)
                }
                .background(Color.black.ignoresSafeArea())
                .toolbar(.hidden, for: .navigationBar)
                .refreshable { model.refresh() }
                .alert("引導使用模式密碼", isPresented: Binding(get: { shownPasscode != nil }, set: { if !$0 { shownPasscode = nil } })) {
                    Button("我已經設定好了") { shownPasscode = nil }
                } message: {
                    Text("\(shownPasscode ?? "")\n\n到 設定 > 輔助使用 > 引導使用模式 > 密碼設定，改成這組（Face ID 要關）。不要背它，之後要掃 QR 才看得到。")
                }
                .sheet(isPresented: $model.showQRScanner, onDismiss: { model.scannerDismissed() }) {
                    QRScannerSheet()
                }
                .sheet(isPresented: $model.showQRCode) {
                    QRCodeSheet(token: model.state.qrToken ?? "")
                }
                .confirmationDialog("重新產生後，已經印出來的 QR Code 會失效。", isPresented: $confirmRegenerate, titleVisibility: .visible) {
                    Button("重新產生", role: .destructive) {
                        model.generateQRToken()
                        model.showQRCode = true
                    }
                }
            }
            .tint(.wakeAccent)
    }

    // MARK: 區塊

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("起床").font(.system(size: 34, weight: .bold))
                Text("走到\(model.state.scanLocation)掃 QR Code 才會停")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(phase: model.state.phase)
        }
        .padding(.top, 8)
    }

    private func passcodeCard(_ code: String) -> some View {
        VStack(spacing: 10) {
            Label("鬧鐘已解除", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.green)
            Text(code)
                .font(.system(size: 52, weight: .bold, design: .monospaced))
                .kerning(6)
            Text("連按三下側邊按鈕，輸入這組密碼，再按「結束」離開引導使用模式。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .card()
    }

    private var alarmCard: some View {
        VStack(spacing: 8) {
            DatePicker("", selection: $alarmTime, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .frame(height: 160)
                .clipped()
            Text(nextRingText)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button {
                model.arm(at: alarmTime)
            } label: {
                Label("上膛", systemImage: "alarm.fill")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 16))
            .disabled(model.state.qrToken == nil)
            .padding(.top, 4)
            if model.state.qrToken == nil {
                Text("請先在下方產生或恢復 QR Code")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .card()
    }

    private var nextRingText: String {
        let next = AppModel.nextOccurrence(of: alarmTime)
        let minutes = max(0, Int(next.timeIntervalSinceNow / 60))
        let day = Calendar.current.isDateInToday(next) ? "今天" : "明天"
        let time = next.formatted(date: .omitted, time: .shortened)
        return "\(day) \(time) 響 · \(minutes / 60) 小時 \(minutes % 60) 分鐘後"
    }

    private var checklistCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("睡前檢查").font(.headline).padding(.bottom, 4)
            CheckRow(title: "QR Code", detail: model.state.qrToken == nil ? "未設定" : "已設定",
                     ok: model.state.qrToken != nil)
            CheckRow(title: "引導模式密碼", detail: model.state.guidedPasscode == nil ? "未設定" : "已設定",
                     ok: model.state.guidedPasscode != nil)
            CheckRow(title: "鬧鐘權限", detail: model.authState == "authorized" ? "已允許" : model.authState,
                     ok: model.authState == "authorized")
            CheckRow(title: "憑證", detail: model.profileText, ok: !model.profileWarning)
            Text("上膛後：連按三下側邊按鈕 → 開始引導使用模式 → 插電")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
        .card()
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("設定").font(.headline).padding(.bottom, 8)

            HStack(spacing: 12) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.wakeAccent)
                    .frame(width: 28)
                Text("QR Code 貼在")
                Spacer()
                TextField("客廳", text: model.binding(\.scanLocation))
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 140)
            }
            .padding(.vertical, 10)
            .disabled(model.locked)

            Divider().padding(.leading, 40)

            if model.state.qrToken == nil {
                Button {
                    model.generateQRToken()
                    model.showQRCode = true
                } label: { RowLabel(icon: "qrcode", title: "產生我的 QR Code") }
                Divider().padding(.leading, 40)
                Button { model.showQRScanner = true } label: {
                    RowLabel(icon: "arrow.counterclockwise", title: "已經印好了？掃描恢復")
                }
            } else {
                Button { model.showQRCode = true } label: { RowLabel(icon: "qrcode", title: "顯示 QR Code（列印用）") }
                    .disabled(model.locked)
                Divider().padding(.leading, 40)
                Button { model.showQRScanner = true } label: { RowLabel(icon: "qrcode.viewfinder", title: "測試掃描") }
            }

            Divider().padding(.leading, 40)

            Button {
                shownPasscode = model.generateGuidedPasscode()
            } label: {
                RowLabel(icon: "lock.shield",
                         title: model.state.guidedPasscode == nil ? "產生引導模式密碼" : "換一組引導模式密碼")
            }
            .disabled(model.locked)

            if model.state.qrToken != nil {
                Divider().padding(.leading, 40)
                Button { confirmRegenerate = true } label: {
                    RowLabel(icon: "trash", title: "重新產生 QR Code", tint: .red)
                }
                .disabled(model.locked)
            }
        }
        .buttonStyle(.plain)
        .card()
    }
}

// MARK: - 進階

struct AdvancedView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                Button("30 秒後響") { model.arm(after: 30) }
                Button("2 分鐘後響（測鎖屏）") { model.arm(after: 120) }
            } header: {
                Text("快速測試")
            } footer: {
                Text("測試請在鎖屏或引導使用模式下進行；手機解鎖、螢幕亮著時，系統鬧鐘可能只震一下。")
            }

            Section("響鈴行為") {
                Toggle("App 警報聲（按鍵停不掉）", isOn: model.binding(\.sirenEnabled))
                Toggle("系統鬧鐘用刺耳警報音", isOn: model.binding(\.customSound))
                Stepper("按停止後 \(model.state.rearmSeconds) 秒重響",
                        value: model.binding(\.rearmSeconds), in: 1...120)
                Stepper(model.state.refreshSeconds == 0 ? "刷新：關閉" : "響 \(model.state.refreshSeconds) 秒沒解除就換新的",
                        value: model.binding(\.refreshSeconds), in: 0...60)
                Stepper("掃描緩衝 \(model.state.bufferSeconds) 秒",
                        value: model.binding(\.bufferSeconds), in: 5...300, step: 5)
                Stepper("保底鬧鐘每 \(model.state.chainSeconds) 秒一顆",
                        value: model.binding(\.chainSeconds), in: 3...600, step: 1)
                Stepper("保底鬧鐘 \(model.state.chainCount) 顆",
                        value: model.binding(\.chainCount), in: 1...300)
                Toggle("按停止會重排", isOn: model.binding(\.stopRearmEnabled))
                Toggle("stopIntent 內呼叫 stop()", isOn: model.binding(\.callStopInIntent))
            }
            .disabled(model.locked)

            Section {
                Toggle("上膛後保持螢幕亮著", isOn: model.binding(\.keepScreenOn))
            } header: {
                Text("螢幕")
            } footer: {
                Text("開：螢幕不會自動熄滅（全黑畫面）。關：跟隨系統或引導使用模式的「螢幕自動鎖定」時間熄滅。夜間畫面一律全黑，點一下螢幕顯示資訊 8 秒。")
            }
            .disabled(model.locked)

            Section {
                Picker("解鎖方式", selection: model.binding(\.unlockMethod)) {
                    Text("QR Code").tag(UnlockMethod.qr)
                    Text("NFC 標籤").tag(UnlockMethod.nfc)
                }
                .disabled(model.locked)
                Button(model.scanning ? "掃描中…" : "掃描 NFC 驗證") { model.startScan() }
                Button("登錄新的 NFC 標籤") { model.startScan(register: true) }
                    .disabled(model.locked)
                ForEach(model.state.nfcWhitelist, id: \.self) { uid in
                    Text(uid).font(.caption.monospaced())
                }
                .onDelete { offsets in
                    offsets.map { model.state.nfcWhitelist[$0] }.forEach(model.removeTag)
                }
            } header: {
                Text("解鎖方式")
            } footer: {
                Text("NFC 標籤到貨後可以改用 NFC。左滑可刪除標籤。")
            }

            Section("狀態") {
                LabeledContent("階段", value: model.state.phase.title)
                LabeledContent("引導使用模式", value: model.guidedAccessOn ? "已開啟" : "未開啟")
                LabeledContent("背景保活", value: model.keepAliveRunning ? "執行中" : "未啟動")
                LabeledContent("按停止被重排", value: "\(model.state.rearmCount) 次")
                LabeledContent("鬧鐘權限", value: model.authState)
                LabeledContent("App Group", value: model.appGroupText)
                LabeledContent("憑證", value: model.profileText)
                LabeledContent("系統內鬧鐘", value: AlarmController.summary(model.alarms))
                Button("重新整理") { model.refresh() }
            }

            Section {
                NavigationLink("記錄") { LogView() }
            }

            Section {
                Button("全部取消並重置", role: .destructive) { model.resetAll() }
                    .disabled(model.locked)
            } footer: {
                Text(model.locked ? "上膛中不能重置，只能掃 QR 解除。" : "測試時鬧鐘停不下來就按這裡。")
            }
        }
        .navigationTitle("進階")
        .toolbar(.visible, for: .navigationBar)
    }
}

// MARK: - 記錄

struct LogView: View {
    @State private var lines: [String] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if lines.isEmpty {
                    Text("（空）").foregroundStyle(.secondary)
                }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("記錄")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: Log.fileURL)
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button("清除", role: .destructive) {
                    Log.clear()
                    load()
                }
                Spacer()
                Button("重新載入") { load() }
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        lines = Log.tailLines(400)
    }
}

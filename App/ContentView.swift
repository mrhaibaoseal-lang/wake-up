import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var customTime = Date().addingTimeInterval(600)

    var body: some View {
        NavigationStack {
            List {
                Section("狀態") {
                    LabeledContent("階段", value: model.state.phase.title)
                    LabeledContent("按停止被重排", value: "\(model.state.rearmCount) 次")
                    LabeledContent("AlarmKit 權限", value: model.authState)
                    LabeledContent("App Group", value: model.appGroupText)
                    LabeledContent("憑證", value: model.profileText)
                        .foregroundStyle(model.profileWarning ? .red : .primary)
                }

                Section {
                    Button("30 秒後響") { model.arm(after: 30) }
                    Button("2 分鐘後響（測鎖屏）") { model.arm(after: 120) }
                    DatePicker("指定時間", selection: $customTime, displayedComponents: .hourAndMinute)
                    Button("在指定時間上膛") { model.arm(at: customTime) }
                } header: {
                    Text("上膛測試")
                } footer: {
                    Text("上膛後按鬧鐘的「停止」會在幾秒後重響；按「去掃描」會打開 App 開始掃 NFC。掃到白名單標籤才會真正解除。")
                }

                Section("實驗參數") {
                    Stepper("按停止後 \(model.state.rearmSeconds) 秒重響",
                            value: model.binding(\.rearmSeconds), in: 1...120)
                    Stepper("緩衝 \(model.state.bufferSeconds) 秒",
                            value: model.binding(\.bufferSeconds), in: 5...300, step: 5)
                    Toggle("按停止會重排", isOn: model.binding(\.stopRearmEnabled))
                    Toggle("stopIntent 內呼叫 stop()", isOn: model.binding(\.callStopInIntent))
                }

                Section {
                    Button(model.scanning ? "掃描中…" : "掃描驗證") { model.startScan() }
                    Button("登錄新標籤") { model.startScan(register: true) }
                    LabeledContent("上次讀到的 UID", value: model.lastUID)
                    ForEach(model.state.nfcWhitelist, id: \.self) { uid in
                        Text(uid).font(.caption.monospaced())
                    }
                    .onDelete { offsets in
                        offsets.map { model.state.nfcWhitelist[$0] }.forEach(model.removeTag)
                    }
                } header: {
                    Text("NFC 白名單")
                } footer: {
                    Text("左滑可刪除標籤。")
                }

                Section("系統內的鬧鐘（AlarmKit）") {
                    if model.alarms.isEmpty {
                        Text("無").foregroundStyle(.secondary)
                    }
                    ForEach(model.alarms, id: \.id) { alarm in
                        Text(AlarmController.describe(alarm)).font(.caption.monospaced())
                    }
                    Button("重新整理") { model.refresh() }
                }

                Section {
                    NavigationLink("記錄") { LogView() }
                }

                Section {
                    Button("全部取消並重置", role: .destructive) { model.resetAll() }
                } footer: {
                    Text("測試時鬧鐘停不下來就按這裡。最後手段：刪除 App 會清掉它的所有鬧鐘。")
                }
            }
            .navigationTitle("起床 PoC")
            .refreshable { model.refresh() }
        }
    }
}

struct LogView: View {
    @State private var text = ""

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "（空）" : text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("記錄")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: text)
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
        text = Log.readAll()
    }
}

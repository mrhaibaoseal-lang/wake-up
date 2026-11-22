import SwiftUI
import UniformTypeIdentifiers

/// 選鬧鐘聲音：內建、自己匯入（檔案 App／網址下載）、系統預設；每個都能試聽。
/// 上膛中跟其他設定一樣鎖住。
struct SoundPickerView: View {
    @Environment(AppModel.self) private var model
    @State private var library = SoundLibrary.shared
    @State private var showImporter = false
    @State private var urlText = ""
    @State private var boost = true
    @State private var busy = false
    @State private var message: String?
    @State private var renaming: SoundLibrary.Custom?
    @State private var newName = ""

    private var selected: String { model.state.alarmSound }

    var body: some View {
        List {
            Section {
                ForEach(SoundLibrary.builtIns) { sound in
                    row(choice: sound.file, title: sound.title, detail: sound.detail)
                }
            } header: {
                Text("內建（越上面越刺耳）")
            }

            Section {
                ForEach(library.customs) { custom in
                    row(choice: custom.file, title: custom.name, detail: nil)
                        .swipeActions {
                            Button("刪除", role: .destructive) { delete(custom) }
                            Button("改名") {
                                newName = custom.name
                                renaming = custom
                            }
                        }
                }
                Button {
                    showImporter = true
                } label: {
                    Label("從檔案匯入（mp3、m4a、wav…）", systemImage: "folder")
                }
                HStack {
                    TextField("貼上音檔網址 https://…", text: $urlText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("下載") { download() }
                        .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Toggle("匯入時加強音量（壓縮）", isOn: $boost)
                if busy {
                    HStack { ProgressView(); Text("處理中…") }
                }
                if let message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("自己的鈴聲")
            } footer: {
                Text("Safari 下載的音檔會在「檔案 → 下載項目」，用「從檔案匯入」選它。網址要是直接下載音檔的連結，不能是 YouTube 或網頁。匯入時會轉成單聲道、截到前 \(Int(SoundLibrary.maxSeconds)) 秒（系統鬧鐘最長 30 秒，App 警報聲會循環播）。左滑可改名或刪除。")
            }

            Section {
                row(choice: AlarmSound.systemDefault, title: "系統預設鈴聲",
                    detail: "系統鬧鐘用 iOS 內建鈴聲；App 警報聲仍用「極限尖叫」")
            } footer: {
                Text("系統鬧鐘的音量跟著「鈴聲音量」，App 警報聲跟著媒體音量（響鈴時自動拉到最大）。如果測出系統鬧鐘沒聲音或變成預設鈴聲，就改選內建的或系統預設。")
            }
        }
        .navigationTitle("鬧鐘聲音")
        .disabled(model.locked || busy)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio]) { result in
            switch result {
            case .success(let url): importFile(url)
            case .failure(let error): message = "❌ \(error.localizedDescription)"
            }
        }
        .alert("改名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名稱", text: $newName)
            Button("取消", role: .cancel) { renaming = nil }
            Button("儲存") {
                if let renaming { library.rename(renaming, to: newName) }
                renaming = nil
            }
        }
        .onDisappear { library.stopPreview() }
    }

    private func row(choice: String, title: String, detail: String?) -> some View {
        HStack(spacing: 12) {
            Button {
                library.togglePreview(choice)
            } label: {
                Image(systemName: library.previewing == choice ? "stop.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.wakeAccent)
            }
            .buttonStyle(.borderless)

            Button {
                select(choice)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).foregroundStyle(.primary)
                        if let detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if selected == choice {
                        Image(systemName: "checkmark").foregroundStyle(Color.wakeAccent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        }
    }

    private func select(_ choice: String) {
        guard !model.locked else { return }
        model.binding(\.alarmSound).wrappedValue = choice
        Log.write("🎵 鬧鐘聲音改成「\(library.title(for: choice))」")
    }

    private func delete(_ custom: SoundLibrary.Custom) {
        library.delete(custom)
        if selected == custom.file { select(AlarmSound.defaultChoice) }
    }

    private func importFile(_ url: URL) {
        run { try await library.importFile(at: url, boost: boost) }
    }

    private func download() {
        let text = urlText
        run {
            let custom = try await library.importURL(text, boost: boost)
            urlText = ""
            return custom
        }
    }

    private func run(_ work: @escaping () async throws -> SoundLibrary.Custom) {
        busy = true
        message = nil
        Task {
            do {
                let custom = try await work()
                select(custom.file)
                message = "✅ 已匯入「\(custom.name)」並設為鬧鐘聲音"
            } catch {
                message = "❌ \(error.localizedDescription)"
                Log.write("⚠️ 匯入鈴聲失敗：\(error.localizedDescription)")
            }
            busy = false
        }
    }
}

# AI 接手指南（AGENTS.md）

這份文件給接手這個專案的 AI 助理（Claude、Codex、Cursor、Gemini 等）。開始任何修改前請先讀完，再依序讀：

1. [`docs/HISTORY.md`](docs/HISTORY.md)：從第一天到現在的完整開發紀錄、每個決定的原因
2. [`docs/FINDINGS.md`](docs/FINDINGS.md)：已經實測或查證過的 iOS / AlarmKit 行為（**很多直覺做法已經證實行不通**）
3. [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)：目前的架構與每個檔案的職責
4. [`docs/SETTINGS.md`](docs/SETTINGS.md)：App 內每個設定的意義與建議值
5. [`docs/TODO.md`](docs/TODO.md)：還沒做的事與待測項目

## 專案一句話

自用的 iOS 防賴床鬧鐘（SwiftUI + AlarmKit）。鬧鐘響了之後，**唯一能讓它停的方法是走到客廳（可設定）掃一張印好的 QR Code**。配合 iOS「引導使用模式」讓實體按鍵失效、App 無法被滑掉。

## 使用者是誰、要什麼

- 大學生，賴床極度嚴重：設 5 個鬧鐘會在無意識狀態下全部關掉，影響早八必修課出缺席。
- **手機本來就放在離床很遠的地方，他還是會走過去關掉再回去睡。**所以「把手機放遠一點」不是解法，不要再建議。
- 目標：**響越久越好、越難停越好**。被靜音後要盡快恢復響鈴。
- 這個 App 是他的**主要鬧鐘**，不是備援。不要一直勸他「改用內建時鐘」或「先去睡覺」，他明確表示不想聽。可以在真正有風險時簡短提醒一次。
- 溝通語言：**繁體中文（台灣用語）**。App 介面也全部用繁體中文。
- 設備：**iPhone 16 Plus、iOS 27**；電腦只有 **Windows**（沒有 Mac）。

## 開發與部署環境（重要限制）

| 項目 | 內容 |
|---|---|
| 編譯 | **沒有 Mac**。只能 push 到 GitHub，由 GitHub Actions 的 `macos-26` runner 編譯**未簽名** IPA |
| 專案檔 | 用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 從 `project.yml` 產生，`*.xcodeproj`、`Info.plist`、`*.entitlements` 都不進版控 |
| 簽名安裝 | 使用者在手機上用 **Feather** 搭配向第三方（Flarestore）買的 `.p12` + `.mobileprovision` 簽名側載 |
| 發佈 | CI 把 IPA、`source.json`（Feather / AltStore 來源格式）、`icon.png` 上傳到 GitHub Release `poc-latest`（覆蓋上傳，不刪除） |
| 版本號 | `MARKETING_VERSION = 1.0.<run_number>`、`CFBundleVersion = <run_number>` |
| 分支 | `main` 是最新的穩定版；開發在 `claude/ios-alarm-anti-oversleep-arch-0kfw86` 或新分支，完成後合併回 `main`。兩者 push 都會觸發編譯 |
| Repo | **公開**：`mrhaibaoseal-lang/wake-up` |

### 固定網址

- Feather 來源：`https://github.com/mrhaibaoseal-lang/wake-up/releases/download/poc-latest/source.json`
- IPA 直接下載：`https://github.com/mrhaibaoseal-lang/wake-up/releases/download/poc-latest/WakeUp-unsigned.ipa`

### 憑證（Flarestore Ad Hoc profile）的限制

- **Bundle ID 必須是 `app.calcite3909.scorpio3556`**（明確 App ID），Widget 是 `app.calcite3909.scorpio3556.widget`（實測 Feather 重簽後 Widget 正常）。
- **有**：NFC（NDEF / TAG）、App Groups（`group.81c139ae9a27a7f8.1`～`.5`，程式在執行時自動挑第一個可讀寫的）、Time Sensitive 通知、HealthKit、HomeKit、Push（但沒有該帳號的 APNs 金鑰，等於不能用）。
- **沒有**：Family Controls（不能禁止刪除 App）、Critical Alerts（不能突破靜音鍵的通知）。
- 到期：2027-10-30。App 會讀自己的 `embedded.mobileprovision` 顯示剩餘天數。
- 未簽名 build 不嵌入 entitlements，Feather 會套用 profile 裡的全部 entitlements。

## 怎麼驗證修改

1. 在本機或雲端改程式（無法在 Linux / Windows 編譯 Swift）。
2. push 到開發分支 → 等 GitHub Actions「Build unsigned IPA」完成（通常排隊 1～6 分鐘、編譯約 1.5 分鐘）。
3. 編譯失敗就讀 job log 修正。成功後確認 `source.json` 的 `version` 變成新的 `1.0.<N>`。
4. 請使用者用 Feather 更新、照 [`docs/SETTINGS.md`](docs/SETTINGS.md) 的測試清單實測，並從 App「進階 → 記錄」分享 `poc.log` 回來分析。

**測試一律在「鎖屏」或「引導使用模式」下進行**：手機解鎖、螢幕亮著時 AlarmKit 鬧鐘可能只短震一下（見 FINDINGS）。

## 絕對不要做的事

- **不要把任何秘密 commit 進這個公開 repo**：`.p12`、密碼、`.mobileprovision`（含使用者手機 UDID）、Webhook 網址、API token、女友或朋友的聯絡方式、QR Code 的 token、引導模式密碼。QR token 和密碼都只存在手機的 App 裡。
- **不要重新開啟密集的保底鬧鐘**（例如 3 秒 × 300 顆）：AlarmKit 鬧鐘疊在一起會讓聲音消失只剩震動，而且一次排幾百顆會讓系統變慢、延遲響鈴。詳見 FINDINGS。
- 不要移除「上膛中鎖住設定與重置」的保護：半夢半醒的使用者會利用任何能關掉鬧鐘的按鈕。
- 不要假設「按停止不會停」：Apple 設計上實體按鍵和停止按鈕一定會停掉當下那顆 AlarmKit 鬧鐘，我們只能事後重排。

## Commit 慣例

- Commit 訊息用英文，第一行簡短描述，內文說明原因。
- 小步提交，每次 push 都會觸發編譯，順便當作驗證。

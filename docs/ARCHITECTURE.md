# 架構決策

## 核心原則：Fail-loud

任何時刻，系統層都預先排好一顆「會響、要 App 主動拆掉」的 AlarmKit 鬧鐘。
App 被殺、當機、重開機、憑證失效，結果都是「響」，不是「安靜」。

- 主引擎：**AlarmKit**（iOS 26+）。不受靜音鍵與專注模式影響，App 被殺也會響。
- 「停止」按鈕移不掉 → 掛 `stopIntent`，任務沒完成就立刻排「現在 + N 秒」的新鬧鐘。
- 「去掃描」= `secondaryIntent`：停掉這次響鈴、排 +45 秒緩衝鬧鐘、打開 App 自動開 NFC。
- 無聲音訊保活、音量 slider 技巧、60 發通知 → 降級成選配或刪除（通知會被靜音鍵消音、保活遇中斷就死）。

## 狀態機（目標版本）

| 狀態 | 系統層預埋 | 離開條件 |
|---|---|---|
| `armed` | 主鬧鐘 + 雲端截止時間 | 鬧鐘觸發 → `ringing` |
| `ringing` | 按停止 → 排 now+N 秒 | NFC 驗證 → `probation`；去掃描 → `buffer` |
| `buffer` | now+45 秒 | NFC 驗證 → `probation`；到時 → `ringing` |
| `probation` | 下一次隨機抽查時間 | 被動驗證（步數/活動）通過就往後推；離家或出門時間 → `done` |
| `done` | 全部取消 + 回報雲端 | — |

規則：任何狀態逾時，或任何預排鬧鐘觸發，都回到 `ringing`。
狀態存「事件 + 截止時間」，由 `reconcile()` 推算，並與 AlarmKit 現存鬧鐘對帳（不一致時以較吵的一方為準）。

## 解鎖：NFC UID 白名單

- 用 `NFCTagReaderSession` 讀硬體 UID，不只看 NDEF 內容。
- 2–3 顆標籤分散在不同房間，響鈴時才隨機指定今天要掃哪顆。
- 進階：NTAG 424 DNA 的 SUN（遞增計數器 + CMAC），無法複製也無法重放。

## 防回籠覺

- 驗證成功的同時就排好下一次抽查鬧鐘（預設失敗）。
- 被動驗證優先：`CMPedometer` 步數 + `CMMotionActivityManager` 非持續靜止 → 悄悄往後推。
- 被動沒過 → 要求再掃一次（另一顆）標籤，而不是按按鈕。
- 抽查次數與間隔隨機化。

## 憑證（Flarestore Ad Hoc profile）

- App ID：`app.calcite3909.scorpio3556`（明確 ID），到期 2027-10-30。
- 有：NFC（NDEF/TAG）、App Groups（`group.81c139ae9a27a7f8.1`–`.5`）、Time Sensitive、HealthKit。
- 沒有：Family Controls、Critical Alerts。
- App 啟動時從 `embedded.mobileprovision` 讀到期日，14 天內警告；App Group 不寫死，取第一個可讀寫的。
- 撤銷風險的兜底：雲端「沒收到解除就觸發」的死人開關 + 系統時鐘 App 一顆晚 10 分鐘的保險鬧鐘。

## 待辦（PoC 之後）

- 雲端死人開關（Cloudflare Worker cron，上膛時註冊截止時間）。
- `probation` 抽查 + CoreMotion 被動驗證。
- 上膛前檢查清單（音訊路由、充電、AlarmKit 授權）。
- App Intents 給捷徑自動化當 watchdog。

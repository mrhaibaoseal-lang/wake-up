# 架構

## 設計原則

1. **Fail-loud**：任何時候系統層都有一顆會響的 AlarmKit 鬧鐘在等著。App 死掉、被殺、重開機，結果都是「響」，不是「安靜」。
2. **唯一出口是掃 QR**：上膛後所有設定、重置、重新產生 QR 都鎖住。
3. **多層聲音，各補彼此的弱點**：

| 層 | 誰負責 | 能擋 | 弱點 |
|---|---|---|---|
| AlarmKit 系統鬧鐘 | iOS | App 被殺、靜音鍵、專注模式 | 實體按鍵一按就停；疊加只震動；螢幕亮時可能只震一下 |
| 按停止 N 秒重響 | `StopAlarmIntent` | 按「停止」 | 實體按鍵不會觸發它 |
| 刷新 | App（背景保活中） | 被按鍵靜音、疊加只震動 | App 被滑掉就失效 |
| App 警報聲 | App（背景保活中） | 實體按鍵 | 走媒體音量；App 被滑掉就失效 |
| 引導使用模式 | iOS（使用者手動開啟） | 實體按鍵、滑掉 App、刪除 App | 要使用者睡前自己開；強制重開機可以解除 |

## 狀態機

存在 App Group 的 `state.json`（`PoCState`），App、Widget、Intent 共用。

```
idle ──上膛──▶ armed ──打開掃描──▶ buffer ──掃到 QR──▶ verified
                ▲                     │
                └──關掉相機／緩衝到期──┘
```

| 狀態 | 意義 | 系統層預排 |
|---|---|---|
| `idle` | 未上膛 | 無 |
| `armed` | 已上膛（響鈴前、響鈴中都是） | 鬧鐘時間的那顆；響鈴中則由刷新／停止持續換新 |
| `buffer` | 掃描中，聲音暫停 | 緩衝秒數後的那顆 |
| `verified` | 掃 QR 成功，全部取消 | 無 |

`missionPending = armed || buffer`。

### 給小工具看的欄位

小工具讀不到 `embedded.mobileprovision`，也不該自己問 AlarmKit 權限，所以 App 在 `refresh()`（進前景、上膛後）把 `alarmAuthorized`、`profileExpiration` 寫進 `PoCState`（有變才寫）。`verifiedAt` 在掃碼成功時寫入，小工具用它判斷「今天起床了」。小工具的 timeline 另放一個 entry 在 `alarmDate`，到點自己變成橘色的響鈴中；即時動態的已響時間用 `WakeMetadata.ringingSince`（上膛時的 `alarmDate`），刷新換新鬧鐘也不會歸零。

### 睡眠紀錄

上膛時 `SleepStore.startNight`（`armedAt` = 按上膛的時間當作上床）；掃碼成功 `finishNight` 補 `verifiedAt` 與被關次數；手動重置刪掉沒驗證的那筆。時數 = `verifiedAt − armedAt`，1～16 小時之外不計（快速測試也就不會算進去，起床速度同樣只算有效的晚上）。歸屬到 `verifiedAt` 那天，一週從週一開始。

**安全底線**：小工具、即時動態、控制中心都只能看或打開 App（`wakeup://open`），不能停止、解除、延後。

### 天氣

- 位置：設定卡「天氣位置」用 CoreLocation 抓一次，四捨五入到小數 2 位存在 `PoCState.weatherLatitude/Longitude`（只在手機）。
- 什麼時候抓：上膛時（背景）、鬧鐘前 30 分鐘（`refreshTick`，整晚保活所以有網路）、掃碼／感應成功、起床後打開 App 且資料超過 30 分鐘、下拉重新整理。
- 建議：看「現在到 `weatherUntilHour`（預設 22）點」的逐小時資料。體感溫度加上體質修正（怕熱 +2）後，內層看最高、外套看最低；降雨機率 ≥ 50% 或雨量 ≥ 1 mm 要帶傘，≥ 30% 帶折疊傘。
- 天氣只顯示資訊，上膛中卡片不顯示、設定鎖住，不影響「唯一出口」。WeatherKit 不能用（憑證沒有權限）。

### 排程的關鍵機制

- `AlarmController.scheduleSequence(startIn:reason:)`：先取消全部，再排「第一顆在 +N 秒，之後每 `chainSeconds` 一顆，共 `chainCount` 顆」。預設 `chainCount = 1`。
- **世代編號** `sequenceGeneration`：每次重排或解除就 +1，還在跑的舊排程迴圈看到編號變了就停，避免解除後又冒出鬧鐘。
- `AlarmController.disarm`：解除時讓世代失效、取消全部，並在 1、3、6 秒後補清。

## 檔案職責

| 檔案 | 職責 |
|---|---|
| `project.yml` | XcodeGen 設定：Bundle ID、Info.plist、entitlements、背景音訊、圖示 |
| `.github/workflows/build-ipa.yml` | 編譯未簽名 IPA、產生 Feather `source.json`、上傳到 Release `poc-latest` |
| `Shared/Shared.swift` | `ProvisioningInfo`（讀 embedded.mobileprovision）、`AppGroup`（自動挑可用群組）、`Log`、`Phase`、`PoCState`（容錯解碼）、`Store`、`CrossProcess`（Darwin 通知） |
| `Shared/AlarmSupport.swift` | `AlarmController`（排程、取消、世代、解除）、`StopAlarmIntent`、`GoScanIntent` |
| `App/WakeUpApp.swift` | App 入口、`AppDelegate`、前景／背景切換 |
| `App/AppModel.swift` | 主要邏輯：上膛（`performArm` 給 App 與捷徑共用）、刷新迴圈（每 2 秒）、保活與警報聲開關、引導模式偵測、掃描緩衝、驗證、QR、NFC |
| `App/ContentView.swift` | 底部分頁（鬧鐘／睡眠）、主畫面（卡片式）、進階設定 `AdvancedView`、記錄 `LogView`。上膛中 `ArmedView` 蓋在分頁列之上、分頁列隱藏並切回鬧鐘頁 |
| `App/SleepStore.swift` | `NightRecord`、`SleepStore`（App Group 的 `nights.json`，留 60 天）、`SleepStats`（本週時數、每天長條、起床速度、連續天數） |
| `App/BedtimeReminder.swift` | 睡前提醒：一次排未來 7 天的 `bedtime-yyyyMMdd` 單次 Time Sensitive 通知；已上膛就跳過鬧鐘前那則。回前景、上膛、重置、驗證、改設定時重排（`NotificationBurst.clear()` 會清掉全部通知，所以要在它之後重排） |
| `App/WakeIntents.swift` | `ArmAlarmIntent`（捷徑／Siri 上膛，參數時、分；**missionPending 時拒絕**「鬧鐘進行中，不能改時間」；沒有 QR 也拒絕）、`WakeShortcuts`（片語「用起床設鬧鐘」「起床上膛」） |
| `Shared/Weather.swift` | 天氣：`WeatherService`（Open-Meteo，不用 API key；快取在 App Group `weather.json`；同時只抓一次、間隔至少 60 秒）、`WeatherAdvice`（穿衣與帶傘規則）、`HeatTolerance`、WMO 天氣代碼對照 |
| `App/LocationOnce.swift` | 只抓一次目前位置（設定天氣位置用），不持續定位 |
| `App/WeatherCard.swift` | 主畫面的天氣卡（未上膛時顯示；掃碼成功後在密碼卡下面） |
| `App/SleepView.swift` | 「睡眠」分頁（Swift Charts）。睡眠資料只在 App，不放小工具 |
| `App/ArmedView.swift` | 上膛後蓋住整個畫面：全黑夜間畫面／響鈴畫面；`VolumeForcer`、`ScreenDimmer` |
| `App/KeepAlive.swift` | 音訊引擎：無聲保活、警報聲播放（讀 `PoCState.alarmSound` 選的檔案）、響鈴時連續震動、中斷恢復 |
| `App/QRSupport.swift` | 產生 QR 圖片、VisionKit 掃描器、QR 顯示頁 |
| `App/NFCScanner.swift` | 讀 NFC 標籤 UID |
| `App/TerminationGuard.swift` | App 被滑掉時的備援（實測效果有限）、通知連發 |
| `App/Sounds/*.wav` | 內建鬧鐘音（AlarmKit 與 App 警報聲共用）。`wake_scream`／`wake_chaos`／`wake_klaxon` 由 `tools/make_sounds.py` 產生；`wake_alarm` 是舊版 |
| `App/SoundLibrary.swift` | 內建音清單、匯入（檔案／網址 → 44.1 kHz 單聲道 CAF、截 29 秒、正規化，存 `Library/Sounds`，名稱存 `Library/custom_sounds.json`）、試聽 |
| `App/SoundPickerView.swift` | 「鬧鐘聲音」頁：選擇、試聽、匯入、改名、刪除 |
| `App/Assets.xcassets` | App 圖示 |
| `Shared/OpenAppIntent.swift` | `OpenWakeAppIntent`：只打開 App（控制中心按鈕用，App 與 Widget 都編進去） |
| `Widget/WakeWidgets.swift` | 小工具 `StatusWidget`（黑／橘，未上膛／已上膛／響鈴中／今天起床了；小、中、鎖屏三種）、AlarmKit 即時動態與動態島、控制中心按鈕 `WakeControl` |

## 每天的流程

| 時間 | 使用者 | App |
|---|---|---|
| 睡前 | 選時間 → 上膛 → 連按三下側鍵開始引導模式 → 插電 | 排 AlarmKit 鬧鐘、開始無聲保活、顯示全黑畫面 |
| 鬧鐘時間 | — | AlarmKit 響＋App 警報聲；響鈴畫面亮度最高、媒體音量拉滿 |
| 響鈴中 | 走到客廳 | 每 5 秒左右刷新 AlarmKit 鬧鐘；按停止 1 秒後重響 |
| 按「掃描」 | 對著 QR | 全部暫停，緩衝 20 秒 |
| 掃到 QR／感應 NFC | 看到引導模式密碼 → 連按三下側鍵輸入 → 結束 | 全部取消、停止保活與警報聲、顯示密碼與今天的天氣、穿衣建議 |

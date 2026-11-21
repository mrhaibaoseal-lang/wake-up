# 已驗證的 iOS / AlarmKit 行為

在 iPhone 16 Plus（iOS 27）實測，或查 Apple 官方與開發者論壇得到的結論。**改架構前先看這份**，很多直覺做法已經證實行不通。

標記：🧪 = 使用者實測、📄 = 官方或論壇資料、❓ = 尚未確認

## AlarmKit

| 行為 | 來源 | 對設計的影響 |
|---|---|---|
| 鬧鐘會無視靜音鍵與專注模式，App 被殺也會響 | 🧪📄 | 主引擎用 AlarmKit |
| 按「停止」：鬧鐘一定會停（不論 `stopIntent` 裡有沒有呼叫 `stop()`），但 `stopIntent` 會被呼叫 | 🧪 | 只能在 `stopIntent` 裡重排下一顆，不能阻止停止 |
| **實體按鍵（音量鍵、側鍵）會停止所有正在響的鬧鐘，App 無法停用** | 🧪📄（Apple AlarmKit FAQ Q7、Q8） | 要靠引導使用模式讓按鍵失效 |
| 按音量鍵停止時，鬧鐘可能仍留在「響鈴中」狀態（沒聲音） | 🧪📄（論壇 800265） | 必須取消它，新的鬧鐘才會出聲 |
| **新鬧鐘在前一顆還在響時觸發，只會震動、沒有聲音** | 🧪（3 秒和 30 秒實驗）📄（論壇 845563） | 不能用密集保底鬧鐘；改用「刷新」（取消舊的再排新的） |
| 手機解鎖、螢幕亮著時，鬧鐘可能只短震一下 | 📄（論壇 808260）🧪（部分測試結果符合） | 測試要在鎖屏或引導模式下；另有 App 警報聲補強 |
| 鬧鐘音量是**鈴聲音量**，App 無法調整 | 📄（Apple DTS 回覆，論壇 813519） | 使用者已關「使用按鈕調整」，音量鍵改不到鈴聲音量 |
| 一次排幾百顆、一晚上反覆排兩千多顆後，曾出現排好卻延遲很久才響 | 🧪 | 不要大量排程；保底只排 1 顆 |
| `cancel(id:)` 對已經不存在的鬧鐘會丟 `Code=0` 錯誤（兩個取消動作同時跑） | 🧪 | 無害，但要避免同時重排 |
| 自訂鈴聲 `.named("wake_alarm.wav")` 能不能正常播放 | ❓ | build 17 起使用，待實測；不行就在「鬧鐘聲音」選系統預設 |
| `.named()` 要寫完整檔名含副檔名；檔案要在 App bundle 或 App 的 `Library/Sounds`，30 秒以內。論壇有人回報 Library/Sounds 的檔案會退回預設鈴聲（iOS 26 beta） | 📄（論壇 836432、798140、802620） | 匯入的鈴聲放 Library/Sounds，iOS 27 上能不能播待實測；不能的話 App 警報聲仍會播匯入的聲音 |

## 背景執行與音訊

| 行為 | 來源 | 對設計的影響 |
|---|---|---|
| 播放無聲音軌（`.playback` + `.mixWithOthers`）可以讓 App 在背景持續執行 | 🧪（記錄有持續的保活與刷新） | 刷新和 App 警報聲都依賴它 |
| **把 App 從切換器滑掉，保活和 App 警報聲就停了** | 🧪 | 要靠引導使用模式讓 App 滑不掉 |
| 刪除 App：App 警報聲消失，但 AlarmKit 鬧鐘還在 | 🧪 | — |
| App 被滑掉時 `applicationWillTerminate` 排的 Time Sensitive 通知：被靜音的鬧鐘還在響鈴中時，**通知沒聲音也沒震動** | 🧪 | 這層備援基本無效 |
| App 警報聲走媒體音量，實體音量鍵可以調小 | 推論 | 引導模式下音量鍵無效，所以沒問題；不開引導模式時是弱點 |
| `MPVolumeView` 調整系統音量只在 App 前景時有效 | 📄（一般已知） | 引導模式下 App 一直在前景，可以用 |

## 引導使用模式（Guided Access）

| 行為 | 來源 |
|---|---|
| 在選項中關掉「音量按鈕」「側邊按鈕」後，兩者完全沒作用；結束引導模式後恢復 | 🧪 |
| 開啟方式：設定 > 輔助使用 > 引導使用模式打開，再到 App 裡連按三下側鍵 | 🧪 |
| 一開始按三下沒反應，是引導使用模式的開關沒開 | 🧪 |
| 使用者手機的引導模式密碼是 **4 位數** | 🧪 |
| App 無法自己結束引導使用模式（需要受監管裝置） | 📄 |
| 引導模式設定中的「螢幕自動鎖定」：螢幕自動關掉後按鍵是否仍被鎖住 | ❓ 待測 |
| iOS 26.1 起有人回報：停用音量按鈕時音量會被調到最低 | 📄（Apple Community）❓ 使用者尚未遇到 |
| **引導使用模式下，系統的 NFC 感應視窗不會出現，但感應仍然有效**（貼近卡片就能解除）。不開引導模式時視窗正常出現。App 因此自己顯示「感應中…」畫面與取消按鈕 | 🧪（1.0.28） |
| 引導使用模式下要強制重開機：音量上、音量下快速各按一下，再長按側鍵 15～20 秒（按鍵看似失效但組合鍵仍有效） | 📄 |

## 其他

| 行為 | 來源 |
|---|---|
| 手機 Safari 無法直接下載 GitHub Actions Artifacts → 改用 Release 固定網址 | 🧪 |
| Feather 重簽後 Widget Extension 正常、App Group 共享資料正常 | 🧪 |
| GitHub Release 建立偶爾出現 403（一次性） | 🧪 |

## 參考資料

- [Apple AlarmKit FAQ（開發者論壇 797158）](https://developer.apple.com/forums/thread/797158)
- [AlarmKit: volume buttons for snoozing（810865）](https://developer.apple.com/forums/thread/810865)
- [AlarmKit volume buttons stop the alarm rather than snoozing（805937）](https://developer.apple.com/forums/thread/805937)
- [AlarmKit Volume and Volume Buttons（800265）](https://developer.apple.com/forums/thread/800265)
- [AlarmKit: supported audio handoff for staggered overlapping alarms?（845563）](https://developer.apple.com/forums/thread/845563)
- [AlarmKit only triggers a short vibration when the screen is on（808260）](https://developer.apple.com/forums/thread/808260)
- [Is there any way to control alarm volume independently when using AlarmKit?（813519）](https://developer.apple.com/forums/thread/813519)
- [Use Guided Access on iPhone or iPad（Apple Support）](https://support.apple.com/en-us/ht202612)

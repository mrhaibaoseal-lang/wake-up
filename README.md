# 起床（wake-up）

自用的 iOS 防賴床鬧鐘（SwiftUI + AlarmKit），側載安裝。

鬧鐘響了之後，**唯一能讓它停的方法是走到客廳（可設定）掃一張印好的 QR Code**。搭配 iOS「引導使用模式」讓音量鍵、側鍵失效，App 也滑不掉、刪不掉。

> 換 AI 或換人接手？先讀 [`AGENTS.md`](AGENTS.md)。

## 功能

- **系統級鬧鐘（AlarmKit）**：無視靜音鍵與專注模式，App 被殺也會響
- **刺耳警報音**：系統鬧鐘和 App 自己的警報聲共用程式合成的音檔
- **App 警報聲**：時間到後 App 自己播放，實體按鍵停不掉
- **按停止就重響**、**被靜音自動換新的一顆**（刷新）
- **QR Code 解鎖**：QR 在手機上隨機產生，紙本遺失可重印、App 重裝可掃紙本恢復
- **引導模式密碼**：App 保管，掃到 QR 才顯示
- **上膛後鎖住**所有設定與重置
- **全黑夜間畫面**（防 OLED 烙印）、時間到切換成響鈴畫面
- NFC 標籤解鎖（UID 白名單，標籤到貨後可改用）
- 桌面小工具、App 內記錄

## 安裝與更新

**推薦：Feather 來源（會自動提示更新）**

```
https://github.com/mrhaibaoseal-lang/wake-up/releases/download/poc-latest/source.json
```

**或直接下載 IPA（固定網址）**

https://github.com/mrhaibaoseal-lang/wake-up/releases/download/poc-latest/WakeUp-unsigned.ipa

用 Feather 選自己的 `.p12` + `.mobileprovision` 簽名安裝：

- **不要**勾「移除 PlugIns」（小工具要用）
- Bundle ID 保持 `app.calcite3909.scorpio3556`

每次 push 到開發分支，GitHub Actions 會重新編譯並更新上面兩個網址，版本號是 `1.0.<build>`。

## 第一次設定

1. 在「設定」填 **QR Code 貼在**哪裡（預設客廳）
2. **產生我的 QR Code** → 儲存影像 → 印出來（例如 7-11 ibon），貼好；把相簿裡的圖刪掉
3. **產生引導模式密碼** → 照畫面到 **設定 > 輔助使用 > 引導使用模式**：
   - 打開引導使用模式
   - 密碼設成 App 顯示的那組 4 位數
   - **Face ID 關掉**
4. 系統設定：
   - 設定 > 聲音與觸覺：鈴聲音量拉到最大，「使用按鈕調整」關閉
   - 設定 > 一般 > 軟體更新 > 自動更新：關閉
5. 照 [`docs/SETTINGS.md`](docs/SETTINGS.md) 設好「進階設定」並跑一次測試清單

## 每天的用法

| 時間 | 做什麼 |
|---|---|
| 睡前 | 選時間 → **上膛** → 連按三下側邊按鈕 → 選項關掉「側邊按鈕」「音量按鈕」→ **開始** → 插電 |
| 早上 | 鬧鐘和警報聲一起響 → 走到客廳 → 按「掃描」→ 掃 QR → 畫面顯示密碼 → 連按三下側鍵輸入密碼 → 結束 |

## 在電腦上取得專案

- 下載 zip：https://github.com/mrhaibaoseal-lang/wake-up/archive/refs/heads/main.zip
- 或用 Git：

  ```powershell
  git clone https://github.com/mrhaibaoseal-lang/wake-up.git
  ```

Windows 無法編譯 iOS App：改完程式後 push，由 GitHub Actions 編譯。

## 開發

- 專案由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 從 `project.yml` 產生，`*.xcodeproj` 不進版控
- 需要 Xcode 26 以上（AlarmKit），部署目標 iOS 26
- 編譯流程：`.github/workflows/build-ipa.yml`

## 文件

| 文件 | 內容 |
|---|---|
| [`AGENTS.md`](AGENTS.md) | 給 AI 的接手指南、限制、絕對不要做的事 |
| [`docs/HISTORY.md`](docs/HISTORY.md) | 完整開發紀錄與每個決定的原因 |
| [`docs/FINDINGS.md`](docs/FINDINGS.md) | 已驗證的 iOS / AlarmKit 行為 |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | 架構、狀態機、檔案職責 |
| [`docs/SETTINGS.md`](docs/SETTINGS.md) | 每個設定的意義、建議值、測試清單 |
| [`docs/TODO.md`](docs/TODO.md) | 待測項目與下一步功能 |

## 緊急停止

- 上膛中只能掃 QR 解除
- QR 遺失：引導模式下強制重開機（音量上、音量下、長按側鍵）→ 刪除 App 會清掉它所有的鬧鐘 → 重裝後掃紙本或重新產生

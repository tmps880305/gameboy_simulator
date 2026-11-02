# GB Emulator for iOS — 專案規格（給 Claude Code Agent）

> 個人自用、不上架的 iOS Game Boy / Game Boy Color 模擬器。
> 主要目標遊戲：寶可夢黃版（Pokémon Yellow，MBC5 + 電池 RAM，支援 GBC 調色）。
> 模擬核心使用開源的 **SameBoy**（MIT 授權）；本專案只負責前端（iOS App）。

---

## 0. Agent 工作守則（必讀）

1. **不要憑記憶使用 SameBoy API。** 實作任何核心呼叫前，先讀 `Vendor/SameBoy/Core/gb.h` 及相關 header（`apu.h`、`save_state.h` 等），以實際版本的函式名稱與簽名為準。本文件提到的 API 名稱僅供參考。
2. **不要下載或加入任何商業 ROM**，repo 內不得出現 `.gb`、`.gbc`、`.sav`、`.state` 檔案。測試請使用公開的測試 ROM（例如 Blargg、mooneye 測試集，需確認授權）或由使用者手動匯入。
3. 每個 Milestone 完成後必須能以 `xcodebuild` 編譯通過，再進入下一個。
4. 新增第三方依賴前先詢問使用者。除 SameBoy 外，預設只使用 Apple 原生框架。
5. 不確定的設計決策（例如 UI 版面、按鍵配置），先提出選項再實作。
6. 程式碼註解與 commit message 使用英文；與使用者溝通時使用繁體中文。

---

## 1. 技術選型

| 項目 | 選擇 |
|---|---|
| 語言 | Swift 5.9+（App）、C（SameBoy 核心） |
| UI | SwiftUI 為主；多點觸控虛擬按鍵使用 UIKit view，並以 `UIViewRepresentable` 包裝 |
| 最低版本 | iOS 17 |
| 畫面 | MetalKit `MTKView`，使用 nearest-neighbor 縮放（MVP 階段可先用 `CGImage` → `CALayer.contents`） |
| 音訊 | `AVAudioEngine` + `AVAudioSourceNode` |
| 輸入 | 觸控虛擬按鍵 + `GameController` framework（藍牙／MFi 手把） |
| 核心整合 | 以本地 Swift Package 包裝 SameBoy `Core/` 為 C target，透過 module map 給 Swift 使用 |
| 安裝方式 | Xcode 直接安裝（免費帳號，簽名 7 天）或付費開發者帳號，不上架 |

---

## 2. 目錄結構

```
GBEmu/
├── docs/SPEC.md                # 本文件
├── GBEmu.xcodeproj
├── Packages/
│   └── SameBoyCore/            # 本地 Swift Package
│       ├── Package.swift       # C target，編譯 Vendor/SameBoy/Core/*.c
│       └── Sources/SameBoyCore/include/module.modulemap
├── Vendor/
│   └── SameBoy/                # git submodule，固定在某個 release tag
├── GBEmu/
│   ├── App/
│   │   ├── GBEmuApp.swift
│   │   ├── AppState.swift            # 全域狀態：目前遊戲、設定
│   │   └── EmulatorSession.swift     # 一局遊戲：1–2 個 PlayerInstance、執行緒、音訊、輸入路由、存檔
│   ├── Core/
│   │   ├── EmulatorCore.swift        # 包裝 GB_gameboy_t，唯一直接呼叫 C API 的地方
│   │   ├── PlayerInstance.swift      # 每台模擬器各自的 core + FrameBuffer + ButtonState + 電池存檔位置
│   │   ├── EmulationLoop.swift       # 專用執行緒、時序、倍速控制
│   │   ├── SpeedController.swift     # 倍速模式狀態
│   │   └── FrameBuffer.swift         # triple buffer，供核心與畫面之間交換影格
│   ├── Video/
│   │   ├── ScreenView.swift          # MTKView / UIViewRepresentable
│   │   └── Shaders.metal
│   ├── Audio/
│   │   ├── AudioOutput.swift         # AVAudioEngine + source node
│   │   └── RingBuffer.swift          # 無鎖 SPSC ring buffer
│   ├── Input/
│   │   ├── ButtonState.swift         # 8 個按鍵的位元狀態
│   │   ├── TouchControlsView.swift   # UIKit 多點觸控按鍵
│   │   └── GameControllerInput.swift
│   ├── Persistence/
│   │   ├── ROMLibrary.swift          # 匯入、列出 ROM
│   │   ├── BatterySaveStore.swift    # .sav 讀寫
│   │   └── SaveStateStore.swift      # 即時存檔欄位
│   └── UI/
│       ├── LibraryView.swift
│       ├── GameView.swift            # 畫面 + 按鍵 + 倍速指示 + P1/P2 切換
│       ├── LinkSetupView.swift       # 連線模式：選擇 P2 遊戲與存檔
│       └── SettingsView.swift
└── .gitignore                  # 需包含 *.gb *.gbc *.sav *.state
```

---

## 3. 架構總覽

```
 EmulatorSession（主執行緒門面：生命週期、P1/P2 選擇、輸入路由、存檔）
   │  持有 1–2 個 PlayerInstance = EmulatorCore + FrameBuffer + ButtonState + BatterySlot
   ▼
          ┌──────────────────── Emulation Thread ─────────────────────┐
 Input ──▶│ ButtonState[P1/P2] ─▶ EmulatorCore P1 ◀─ serial bits ─▶ P2 │
 (只送往  │                         │ vblank callback ─▶ FrameBuffer[Pn]│──▶ Main/Render: ScreenView (每台一個)
  選中的) │                         │ sample callback ─▶ RingBuffer     │──▶ Audio Thread（只有選中的那台寫入）
          │ EmulationLoop（鎖步排程）◀─ SpeedController（整個 Session） │
          └────────────────────────────────────────────────────────────┘
```

- 單人模式＝只有一個 PlayerInstance 的 Session，與連線模式共用同一套流程。

**核心原則：模擬執行緒、畫面渲染、音訊播放三者解耦。**
- 模擬執行緒只負責「依倍速產生影格與音訊樣本」。
- 畫面依螢幕刷新率顯示 FrameBuffer 中「最新的一幀」。
- 音訊從 RingBuffer 拉取樣本；不足時補靜音，過多時丟棄。
- 時序**由 EmulationLoop 自己的計時器驅動**，不由音訊或螢幕驅動，這是倍速功能能乾淨實作的前提。

---

## 4. 模組規格

### 4.1 EmulatorCore
- 持有並管理 `GB_gameboy_t` 的生命週期（init / free）。
- 機型使用 CGB（例如 `GB_MODEL_CGB_E`，以 header 為準），讓黃版顯示 GBC 調色。
- Boot ROM 使用 SameBoy 自帶的開源 boot ROM（需確認建置流程，boot ROM 原始碼通常需要 `rgbds` 組譯；也可預先建置後放入 bundle）。**不得使用任天堂原版 boot ROM。**
- 設定 callback：
  - 像素輸出緩衝區（160×144，32-bit RGBA）與 RGB 編碼 callback
  - vblank callback：通知「一幀完成」
  - APU sample callback：輸出音訊樣本，取樣率與 AudioOutput 一致（建議 48000 Hz）
- 對外提供的介面（Swift，僅列職責）：
  - 載入 ROM、載入／儲存電池存檔、載入／儲存即時存檔（byte data 進出）
  - 設定按鍵狀態
  - 執行一幀（回傳是否完成一幀）
  - 設定「本幀是否需要輸出畫面」（倍速時中間幀可略過）
- **僅能在模擬執行緒上呼叫**。其他執行緒的操作（存檔、讀檔、重置）以指令佇列送入模擬執行緒執行。

### 4.2 EmulationLoop
- 專用 `Thread`，迴圈依目標時間間隔執行。
- GB 原生幀率約 **59.7275 fps**（每幀約 16.743 ms），以 `mach_absolute_time` 或 `DispatchTime` 計時，並累積時間誤差以避免漂移。
- 每次 tick：
  1. 處理指令佇列（存檔、讀檔、暫停等）
  2. 寫入最新的按鍵狀態
  3. 依 SpeedController 決定本 tick 要跑幾幀，只有最後一幀輸出到 FrameBuffer
  4. 依倍速決定音訊處理方式（見 4.4）
  5. 睡到下一個 tick
- 支援暫停／繼續；App 進入背景時自動暫停。

### 4.3 SpeedController（倍速）
- 模式：
  - `normal`：1x
  - `fixed(multiplier)`：2x / 4x / 8x
  - `unlimited`：在每個 tick 的時間預算內（例如 14 ms）盡量多跑幀
- 輸入方式：
  - **按住加速**：按住時進入使用者設定的加速倍率，放開後回到原本模式
  - **切換加速**：按鈕在 1x → 2x → 4x → unlimited 之間循環
- 設定項：按住加速倍率、加速時是否靜音（預設靜音）。
- 是否使用 SameBoy 自帶的 turbo／跳幀 API，需先閱讀 header 再決定。預設做法是由 EmulationLoop 自行控制每 tick 的幀數，不依賴核心內建的節流。

### 4.4 AudioOutput
- `AVAudioSession` category 設為 `.ambient`（不打斷使用者的音樂，可在設定中改成 `.playback`）。
- 核心 sample callback 將樣本寫入 SPSC ring buffer，`AVAudioSourceNode` 的 render block 從中讀取。
- 緩衝不足時補 0（靜音），過多時丟棄最舊的樣本，目標延遲約 50–80 ms。
- 倍速時預設**不寫入 ring buffer**（靜音），恢復 1x 時清空緩衝，避免延遲累積。
- Render block 內不得配置記憶體、加鎖或呼叫 Swift runtime 中可能阻塞的 API。

### 4.5 Video（ScreenView）
- `MTKView` 以螢幕刷新率重繪，每次從 FrameBuffer 取最新影格上傳為 160×144 texture。
- Sampler 使用 nearest 過濾，以整數倍縮放為優先，保持 10:9 比例。
- FrameBuffer 使用 triple buffering：模擬執行緒寫入、渲染端讀取，不可互相阻塞。

### 4.6 Input
- `ButtonState`：8 個按鍵（右、左、上、下、A、B、Select、Start）以原子值儲存，供模擬執行緒讀取。
- 觸控：自訂 UIKit view，處理多點觸控，十字鍵需支援滑動切換方向與斜向輸入。按下時觸發輕觸覺回饋（`UIImpactFeedbackGenerator`，可關閉）。
- 手把：`GCController` 連線通知，對應 extended gamepad；可將肩鍵對應「按住加速」。
- 有手把連線時，觸控按鍵自動隱藏（可設定）。

### 4.7 Persistence
- ROM 匯入：SwiftUI `fileImporter`，複製到 `Documents/ROMs/`。
- 電池存檔：`Documents/Saves/<rom名稱>.P1.sav` 與 `<rom名稱>.P2.sav`（P2 只在連線模式使用）。
  - 舊版的 `<rom名稱>.sav` 在沒有 `.P1.sav` 時作為 P1 的讀取來源；之後一律寫入 `.P1.sav`，舊檔不修改、不刪除。
  - 連線模式下 P2 執行與 P1 相同的 ROM 時用 `.P2.sav`；執行不同 ROM 時用該 ROM 的 P1 存檔。
  - 在下列時機寫入（每台各自寫入）：
  - App 進入背景
  - 暫停時
  - 遊戲執行中每 30 秒（只有在 SRAM 有變動時，若核心提供可判斷的方式）
- 即時存檔：`Documents/States/<rom名稱>.<slot>.state`，至少 4 個欄位，並附上縮圖。
- Info.plist 開啟 `UIFileSharingEnabled` 與 `LSSupportsOpeningDocumentsInPlace`，讓存檔能透過「檔案」App 備份（免費簽名過期需要重新安裝時，這點很重要）。
- 寫入時使用原子寫入（`Data.write(options: .atomic)`）。

### 4.8 UI
- `LibraryView`：ROM 列表、匯入按鈕。
- `GameView`：直式版面為上方畫面、下方按鍵；橫式版面為畫面置中、按鍵分列兩側。右上角選單提供存讀檔、設定、返回。
- 倍速時畫面角落顯示倍率標籤（例如 `▶▶ 4x`）。
- `SettingsView`：加速倍率、加速靜音、觸覺回饋、音訊 category、按鍵透明度。

---

## 5. Milestones 與驗收條件

| # | 內容 | 驗收條件 |
|---|---|---|
| M1 | 建立專案、SameBoy submodule、Swift Package 包裝 | `xcodebuild` 編譯通過；Swift 能呼叫核心的初始化函式 |
| M2 | 載入 ROM + 畫面輸出（無音訊、無輸入） | 匯入測試 ROM 後能看到正確畫面，以 1x 速度執行 |
| M3 | 觸控輸入 | 能操作遊戲選單；十字鍵可滑動切換方向 |
| M4 | 音訊 | 1x 時聲音穩定，沒有明顯爆音或累積延遲 |
| M5 | 電池存檔 | 遊戲內存檔後關閉並重開 App，存檔仍然存在 |
| M6 | 倍速 | 按住加速與切換加速都能正常運作；加速時靜音；恢復 1x 後音訊延遲沒有累積 |
| M7 | 即時存檔 | 4 個欄位可存讀並顯示縮圖 |
| M8 | 手把支援 + 設定頁 + 橫式版面 | 藍牙手把可完整操作；設定能持久保存 |
| M9 | 單機雙實例通信（Link Cable） | 見 5.1 |

### 5.1 M9：單機雙實例通信

同一支 iPhone 同時執行兩個核心，以模擬的序列埠互連（用於寶可夢交換）。

- 兩個核心在同一條模擬執行緒上鎖步執行：記錄各自累積的時脈數（`GB_run` 回傳的 8 MHz ticks），每次以 `GB_run` 推進落後的那一台；每台都完成一次 vblank 才算一幀。序列 bit 交換方式與 SameBoy 的 Cocoa／libretro 前端相同（`GB_set_serial_transfer_bit_start/end_callback` + `GB_serial_get/set_data_bit`）。
- 鎖步迴圈實作在 C（`Packages/SameBoyCore/Sources/SameBoyCore/GBEmuLockstep.c`），Swift 每幀只呼叫一次；逐指令的迴圈若寫在 Swift，Debug（`-Onone`）建置會慢到倍速無法生效。
- 核心固定設為 `GB_set_turbo_mode(true, true)`、`GB_set_turbo_cap(0)`，避免 SameBoy 內建的 timekeeping 在 `GB_run` 中 sleep（與 `GB_run_frame` 內部的暫時設定相同）。
- 倍速套用於整個 Session；只有最後一幀輸出畫面。
- 直式版面上下顯示兩台，橫式只顯示選中的那台；未顯示的那台持續執行。觸控、手把、音訊只跟隨選中的實例，切換時清空 ring buffer。
- 連線模式下停用即時存檔。App 進入背景時暫停整個 Session 並寫入兩份電池存檔；離開連線模式時先寫入 P2 存檔再釋放其核心。
- DEBUG 建置可用 `-autolink <ROM名稱>`（搭配 `-autoplay`）直接進入連線模式，並每秒在 console 印出兩台時脈的最大差距。

驗收條件：
- 單人模式行為與修改前完全一致，舊存檔（`<rom名稱>.sav`）可正常讀取。
- 連線模式下兩台可在遊戲內成功進入交換畫面並完成一次交換，兩邊存檔正確更新。
- 連線模式下倍速可正常運作，且通信不中斷。
- 切換 P1 / P2 時輸入、音訊正確跟著切換。
- 每個步驟皆以 `xcodebuild` 編譯通過。

---

## 6. 非目標（本階段不做）

- 上架 App Store、iCloud 同步、兩支裝置間的網路連線
- 金手指、倒帶（rewind）、濾鏡 shader（可列為之後的擴充）
- GBA 支援

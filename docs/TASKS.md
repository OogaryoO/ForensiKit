# 任務拆分

> 這是任務的**靜態定義**（做什麼、誰做、依賴誰）。**進度狀態以 GitHub Issues 為準**：
> PM 會為每個任務開一個 Issue（標題 `[T04] EVTX 時段匯出`），指派給負責人並掛上里程碑。
> 開工時把 Issue 的 label 改成 `in-progress`，PR 描述寫 `Closes #<issue 編號>`。

負責人代號：**G** = OogaryoO（PM＋開發）、**Y** = YuChenKUO（主力開發）、**W** = wangLJ1015（QA）

## 總覽

| ID | 任務 | 負責 | 週次 | 依賴 | 主要產出 |
|---|---|---|---|---|---|
| T01 | repo 骨架、模組載入、`Write-FKAction`、`Get-FKConfig`、CI | G | W10 | — | `src/ForensiKit/*.psd1/.psm1`、`Private/`、`.github/workflows/ci.yml` |
| T02 | VM 建置指南與建置腳本 | W | W10 | — | `docs/VM_SETUP.md`、`scripts/vm/Setup-TestVM.ps1` |
| T03 | 攻擊模擬腳本與「預期事件」清單 | W | W10–W11 | T02 | `tests/e2e/scenarios/*.ps1`、`tests/e2e/expected/*.json` |
| T04 | `Export-FKEventLog`（時段裁切＋vault） | Y | W11 | T01；vault 部分依 T06 的目錄格式（已定於契約） | `Public/Export-FKEventLog.ps1` |
| T05 | `Get-FKArtifact`（7 種 artifact） | Y | W11 | T01 | `Public/Get-FKArtifact.ps1` |
| T06 | 常駐保全：`Install/Uninstall/Get-FKPreservation*` | G | W11 | T01 | `Public/*Preservation*.ps1` |
| T07 | `New-FKManifest`、`Test-FKPackage`、監管鏈表單 | Y | W12 | T01 | `Public/New-FKManifest.ps1`、`Public/Test-FKPackage.ps1` |
| T08 | `Protect-/Unprotect-FKPackage`（AES-256） | Y | W12 | T07 | `Public/Protect-FKPackage.ps1` 等 |
| T09a | **最小端到端版本**：`Invoke-ForensiKit` 先只串 Security log 時段匯出＋簡易 manifest | Y | W11 | T01、T04 的最小可用版 | `Public/Invoke-ForensiKit.ps1`（初版） |
| T09 | `Invoke-ForensiKit` 完整主流程 CLI | Y | W12 | T09a、T04、T05、T07、T08 | `Public/Invoke-ForensiKit.ps1` |
| T10 | GUI：`Start-ForensiKitGui` | G | W12 | T09 的參數（已定於契約，可先用假資料開發） | `gui/ForensiKit.Gui.ps1` |
| T11 | 單元測試（各公開函式） | W | W11–W12 | 契約；不需等實作完成 | `tests/unit/*.Tests.ps1` |
| T12 | E2E 測試腳本與驗收量測 | W | W12–W13 | T03、T09 | `tests/e2e/Invoke-E2E.ps1` |
| T13 | 三人各自在 VM 跑完整 E2E 並回報 | G、Y、W | W13 | T12 | 每人在 Issue 貼上 E2E 結果 |
| T14 | Bug 修復 | 依模組負責人 | W13 | QA 回報 | 修正 PR |
| T15 | 測試報告 | W | W13–W14 | T13 | `docs/TEST_REPORT.md` |
| T16 | 操作 SOP、Demo 腳本與備援錄影、`v1.0.0` 發佈 | G | W14 | T15 | `docs/SOP.md`、`docs/DEMO.md`、release |
| T17 | 基準比較：手動整檔複製 vs KAPE vs ForensiKit（AC7） | W | W12–W13 | T03、T09 | `docs/TEST_REPORT.md` 中的比較表 |
| T18 | 市場規模與商業模式定稿（初稿已在 `docs/MARKET.md`）＋ 與 EDR 的定位說明 | G | W11–W12 | — | `docs/MARKET.md` |
| T19 | 外部專家審閱：把 VM 產生的範例證據包與 SOP 送講師審閱並整理回饋（AC8） | G | W12–W13 | T09 | T19 Issue 中的回饋紀錄 |

開發量分配：Y 負責 T04、T05、T07、T08、T09a、T09（約 70%）；G 負責 T01、T06、T10、T16（約 30%）並兼任 PM，另負責非開發的 T18、T19。

### 評分導向的優先順序

課程評分以 PoC（12 分）最重，所以發生時間衝突時依下列順序取捨：
1. **能 Demo 的端到端流程**（T09a → T09 → T10）與 log 被清除後仍能取回（AC5）
2. 量測與比較數據（T12、T17）
3. 市場與定位文件（T18）
4. 其他完整度（例如 artifact 種類、加密細節）

被砍的項目寫進 `docs/PROJECT_PLAN.md` 的「不做（列為延伸）」欄。

## 任務細節與完成條件

### T01 repo 骨架（G）
- 依 `ARCHITECTURE.md` 第 2 節建立目錄；`ForensiKit.psm1` 自動 dot-source `Public/`、`Private/` 下的 `.ps1`，並 `Export-ModuleMember` 只匯出 Public。
- `Write-FKAction`、`Get-FKConfig`、`config/default-profile.json`、管理員權限檢查的內部函式 `Assert-FKAdmin`。
- GitHub Actions（`windows-latest`）：安裝 Pester 5 與 PSScriptAnalyzer，跑 `tests/unit` 與分析。
- **完成條件**：`Import-Module ./src/ForensiKit` 不報錯；CI 綠燈。

### T02 VM 建置（W）
- 建 VM 指南：Windows 11（或 10）Enterprise 評估版 ISO、VirtualBox、建議 4 GB RAM／60 GB 磁碟、網路設 NAT。
- `Setup-TestVM.ps1`：安裝 Sysmon（SwiftOnSecurity 設定）、開啟「程序建立含命令列」稽核（4688）、PowerShell Script Block Logging（4104）、安裝 Pester 5 與 PSScriptAnalyzer、建立 `C:\FK-TEST-VM.marker` 標記檔。
- 寫明「建好後先做快照 `clean-baseline`」。
- **完成條件**：三人都依文件建好 VM 並在 T02 Issue 留言確認。

### T03 攻擊模擬與預期結果（W）
- 只用內建指令，詳見 `TEST_PLAN.md` 第 3 節的情境清單。
- 每個情境腳本開頭必須檢查標記檔 `C:\FK-TEST-VM.marker`，不存在就拒絕執行。
- 每個情境附預期事件清單 JSON：`[{ "channel": "Security", "eventId": 4625, "minCount": 5, "match": "TargetUserName=fk_victim" }]`。
- 腳本要記錄攻擊開始與結束的 UTC 時間到 `tests/e2e/run/<情境>.time.json`（此資料夾已被 gitignore），供 E2E 決定匯出時段。

### T04 Export-FKEventLog（Y）
- 用 `wevtutil epl <channel> <dest> /q:"*[System[TimeCreated[@SystemTime>='…' and @SystemTime<='…']]]"` 匯出，保留原生 EVTX 格式。
- channel 不存在（例如沒裝 Sysmon）回傳 `Skipped`，不得 throw。
- `-IncludeVault`：對 vault 中每個備份檔以相同時段條件匯出（`wevtutil epl <file> /lf:true …`），存到 `evtx/vault/`。
- 回傳的 `EventCount` 以 `Get-WinEvent -Path` 計算。
- **完成條件**：AC2（時段 100% 正確）在單元／VM 測試中通過。

### T05 Get-FKArtifact（Y）
- 七種 artifact 見契約。行程用 `Get-CimInstance Win32_Process`（含 CommandLine、ParentProcessId、CreationDate）；網路用 `Get-NetTCPConnection`／`Get-NetUDPEndpoint` 並對應行程名；DNS 用 `Get-DnsClientCache`；排程用 `Get-ScheduledTask` ＋ `Export-ScheduledTask`；自啟項至少涵蓋 HKLM/HKCU 的 Run、RunOnce 與兩個 Startup 資料夾。
- 可執行檔附 SHA-256（檔案不存在或無權限時填 `null`，不中斷）。

### T06 常駐保全（G）
- `wevtutil sl <channel> /ms:<bytes>` 依設定加大 log 上限。
- 註冊 SYSTEM 排程工作 `\ForensiKit\VaultBackup`，每小時以 `wevtutil epl` 把設定中的 channel 備份到 vault；超過 `vaultMaxTotalMB` 時刪最舊的備份。
- 設定 vault 的 ACL（見契約第 5 節）。
- `Uninstall` 要能還原：刪排程、可選擇保留 vault。

### T07 Manifest 與驗證（Y）
- 依契約格式產生 `manifest.json`；計算後把 manifest 自身的 SHA-256 寫進 `chain_of_custody.txt`。
- `chain_of_custody.txt` 內容：案號、操作者、電腦名稱、時段（UTC 與 +08:00 並列）、收集時間、工具版本、manifest SHA-256、移交紀錄空白欄（交付人／接收人／時間／簽名）。
- `Test-FKPackage` 重算所有雜湊，回報不一致、遺失、多出的檔案。
- **完成條件**：AC6 通過（QA 會刻意竄改檔案測試）。

### T08 加密（Y）
- 先 `Compress-Archive` 成 zip，再用 .NET `AesCryptoServiceProvider`（AES-256-CBC）＋ PBKDF2（`Rfc2898DeriveBytes`，≥ 100,000 次、隨機 salt）＋ HMAC-SHA256 驗證完整性。
- 檔頭格式寫進程式註解與 `ARCHITECTURE.md`（需走 `[contract]` PR 補上）。
- 密碼錯誤時 `Unprotect` 必須明確報錯，不得輸出損壞檔案。

### T09a 最小端到端版本（Y）
- 目的：證明技術可行、讓 QA 與 GUI 從 W11 起就有真東西可以接。
- 範圍：`Invoke-ForensiKit -CaseId -Operator -StartUtc -EndUtc -OutputRoot -NoEncrypt` 只匯出 Security log 的指定時段，再對輸出檔產生只含 SHA-256 的簡易 `manifest.json`；參數與回傳格式依契約，未實作的欄位先填 `$null`。
- **完成條件**：在 VM 中一行指令產出證據包，且 QA 確認 AC2（時段正確）成立。之後由 T09 逐步補齊。

### T09 Invoke-ForensiKit（Y）
- 流程：檢查管理員 → 建立證據包目錄 → 開始 action log → T04 → T05 → T07 → （除非 `-NoEncrypt`）T08 → 回傳結果。
- 任何步驟 `Failed` 時整體 `Status = 'Partial'`，仍要產出 manifest。
- 記錄總耗時 `DurationSec`（AC1 量測用）。

### T10 GUI（G）
- 單一視窗：案號、操作者、起訖時間（預設最近 7 天，以台灣時間輸入、內部轉 UTC）、輸出位置（自動偵測卸除式磁碟優先）、密碼（可勾選不加密）、「開始匯出」按鈕、進度與結果區。
- 完成後大字顯示 manifest SHA-256，提示操作者抄寫到監管鏈表單。
- 非管理員啟動時提示並以 UAC 重新啟動自己。
- **完成條件**：AC1（≤ 3 步）由 QA 實測通過。

### T11 單元測試（W）
- 依契約為每個公開函式寫 Pester 測試；需要系統資源的部分用 `Mock`（例如 mock `wevtutil` 呼叫）。
- 實作還沒合併時，測試可先標 `-Skip` 或放在 PR 中，等實作 PR 合併後再啟用。

### T12 E2E 與量測（W）
- `Invoke-E2E.ps1`：還原快照後的 VM 中 → 安裝保全 → 跑情境 → 呼叫 `Invoke-ForensiKit` → 解密 → `Test-FKPackage` → 比對預期事件 → 輸出 AC1–AC6 結果表。

### T13 三人各自 VM 實測（G、Y、W）
- 每人在自己的 VM 依 `TEST_PLAN.md` 第 5 節跑一次，並把 `Invoke-E2E.ps1` 的結果表貼到 T13 Issue。

### T14 Bug 修復
- QA 開 `bug` Issue 並指派給該模組負責人（依上表）；負責人修完由 QA 驗證後關閉。

### T16 SOP、Demo 與發佈（G）
- `docs/SOP.md`：給值班人員的一頁操作說明（隔離不關機 → 開 GUI → 匯出到 USB → 填監管鏈表單 → 交付）。
- `docs/DEMO.md`：5 分鐘 Demo 腳本，建議順序：攻擊情境（S1、S4）→ 清除 log（S6）→ 一鍵匯出 → 驗證雜湊 → 從 vault 取回被清除的事件 → 秀出 AC7 比較表。
- 在 VM 上完整錄一次 Demo 當備援（錄影檔不放 repo，放雲端硬碟並在 Issue 附連結）。

### T17 基準比較（W）
- 在同一個 VM 快照、同一組攻擊情境下，比較三種做法：
  1. **手動**：IT 人員把 `C:\Windows\System32\winevt\Logs` 整個資料夾複製到 USB。
  2. **KAPE**：使用 `KapeTriage` target（KAPE 對教育與研究用途免費，需在 Kroll 官網登記下載）。
  3. **ForensiKit**：GUI 一鍵匯出。
- 比較欄位：操作步驟數、耗時、輸出大小、AC4 關鍵事件命中率、時段外事件數、是否附雜湊與監管鏈、log 被清除後能否取回。
- 結果寫成 `docs/TEST_REPORT.md` 的一張表，期末簡報直接引用。

### T18 市場規模與定位（G）
- 以 `docs/MARKET.md` 初稿為基礎，補上課堂需要的 TAM／SAM／SOM 圖與假設說明。
- 寫清楚與 EDR 的差異：EDR 偵測與遙測依賴授權與雲端保存期限；ForensiKit 專注於事發當下的本機證據保全與交付格式，可與 EDR 並存。
- 假設數字（每院端點數、單價）要明確標示為假設，最好用 1–2 家醫院資訊室的訪談校正。

### T19 外部專家審閱（G）
- 只送 **VM 產生的範例證據包**（不含任何真實個資）與 SOP 給 week 7 講師。
- 問三件事：證據包內容是否足以支援初步調查？格式與監管鏈紀錄是否符合實務？缺什麼？
- 回饋整理在 T19 Issue，必要的調整由 PM 開新任務。

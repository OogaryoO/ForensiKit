# 架構與介面契約

> **這是三人（與三個 AI）平行開發的共同約定。** 開發者照這裡實作，QA 照這裡寫測試，兩邊不必互等。
> 修改本檔必須走 `[contract]` PR，由 PM 審核合併，並在 PR 中 @ 受影響的成員。

## 1. 技術選擇

- **PowerShell 5.1**（Windows 10/11 內建）＋ .NET Framework 類別；不依賴任何第三方執行檔。
- 測試：**Pester 5**（`Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck`）。
- 靜態檢查：**PSScriptAnalyzer**。
- GUI：WinForms（`System.Windows.Forms`）。
- 需要系統管理員權限才能執行蒐證與保全。

## 2. 目錄結構

```
ForensiKit/
├─ src/ForensiKit/
│  ├─ ForensiKit.psd1            # 模組 manifest（T01）
│  ├─ ForensiKit.psm1            # 載入 Public/Private 下所有 .ps1（T01）
│  ├─ Public/                    # 每個公開函式一個檔案，檔名＝函式名
│  ├─ Private/                   # 內部輔助函式
│  └─ config/default-profile.json
├─ gui/ForensiKit.Gui.ps1        # GUI 入口（T10）
├─ tests/
│  ├─ unit/<函式名>.Tests.ps1     # 單元測試（QA 主寫，開發者可補）
│  └─ e2e/                       # VM 端到端測試、攻擊模擬、預期結果
├─ scripts/vm/                   # VM 建置腳本
├─ docs/
└─ .github/
```

## 3. 共用約定

- **時間**：所有參數與輸出用 UTC `[datetime]`（`Kind = Utc`）。輸出字串一律 ISO 8601，例如 `2026-11-20T03:15:00Z`。
- **回傳值**：公開函式回傳 `[pscustomobject]`，不得只靠 `Write-Host` 輸出結果。
- **錯誤**：單一項目收集失敗**不得中斷整體流程**，回傳物件 `Status = 'Failed'` 並寫 action log；只有參數錯誤或無管理員權限才 `throw`。
- **Status 值**只能是：`'OK'`、`'Partial'`、`'Failed'`、`'Skipped'`。
- **Action log**：任何讀取、複製、寫入證據的動作都要呼叫 `Write-FKAction`。

## 4. 證據包結構（輸出格式）

```
FK_<CaseId>_<ComputerName>_<yyyyMMddTHHmmssZ>/
├─ manifest.json            # 所有檔案的清單與雜湊（T07）
├─ action_log.jsonl         # 工具自身每一個動作（T01 helper 產生）
├─ chain_of_custody.txt     # 監管鏈表單：案號、操作者、時間、manifest 雜湊、簽名欄（T07）
├─ evtx/
│  ├─ live/<Channel>.evtx   # 從現行 log 依時段匯出（Channel 名稱中的 / 改為 %4）
│  └─ vault/<Channel>/<備份時間>.evtx  # 從 vault 依時段匯出（T04）
└─ artifacts/
   ├─ prefetch/*.pf
   ├─ scheduled_tasks.json
   ├─ services.json
   ├─ autoruns.json
   ├─ processes.json
   ├─ network_connections.json
   └─ dns_cache.json
```

加密後成為單一檔案 `FK_..._<時間>.fkpkg`（T08，格式見下方「.fkpkg」小節）。

### manifest.json

```json
{
  "schemaVersion": "1.0",
  "tool": { "name": "ForensiKit", "version": "0.1.0" },
  "case": { "caseId": "2026-001", "operator": "王小明" },
  "host": { "computerName": "WIN11-TEST", "osVersion": "10.0.22631", "timeZone": "Taipei Standard Time" },
  "timeRange": { "startUtc": "2026-11-20T00:00:00Z", "endUtc": "2026-11-21T00:00:00Z" },
  "collectedAtUtc": "2026-11-21T02:03:04Z",
  "files": [
    { "path": "evtx/live/Security.evtx", "sha256": "…", "size": 1048576,
      "source": "Security", "collector": "Export-FKEventLog", "status": "OK" }
  ]
}
```

`files[].path` 一律用 `/` 分隔、相對於證據包根目錄。`manifest.json` 本身不列入 `files`；它的 SHA-256 寫在 `chain_of_custody.txt` 並顯示在 GUI 上。

- **不列入 `files` 的檔案**只有 `manifest.json` 與 `chain_of_custody.txt`（後者內含 manifest 雜湊，無法反過來列入）。`Test-FKPackage` 把這兩個檔案視為預期存在，不算 `Extra`。
- `action_log.jsonl` **有**列入 `files`。因此：
  - `New-FKManifest` 自己的 action log 必須在計算雜湊**之前**寫入。
  - 呼叫 `New-FKManifest` 之後，**不得再寫入該證據包的 action log**；`Invoke-ForensiKit` 在 `New-FKManifest` 之後立刻 `Close-FKActionLog`。
  - 加密（`Protect-FKPackage`）在 `Close-FKActionLog` 之後執行，不寫入證據包內的 action log。`Invoke-ForensiKit` 在產生 manifest 之前先寫一筆 `EncryptPackage`（`detail` 註明「將於 manifest 之後加密」）；加密結果只出現在回傳值（`PackagePath`、`Status`）與 GUI。
- `Test-FKPackage`：`manifest.json` 遺失時 `Missing` 含 `manifest.json`，不是合法 JSON 時 `Mismatched` 含 `manifest.json`，兩者都回傳 `IsValid = $false`、**不 throw**（只有 `PackageRoot` 不存在才 throw）。`chain_of_custody.txt` 中記錄的 manifest SHA-256 與實際不符時，`Mismatched` 含 `manifest.json`。

### action_log.jsonl（每行一個 JSON）

```json
{"timeUtc":"2026-11-21T02:03:04Z","action":"ExportEventLog","target":"Security","detail":"wevtutil epl ...","status":"OK"}
```

- 編碼：UTF-8 **無 BOM**、LF 換行，一行一個 JSON 物件，只附加不覆寫。
- **「目前證據包」的指定方式**（內部函式，位於 `Private/Open-FKActionLog.ps1`）：
  ```powershell
  # Invoke-ForensiKit 建立證據包目錄後
  Open-FKActionLog -PackageRoot $packageRoot | Out-Null   # 回傳 action_log.jsonl 完整路徑；目錄不存在時 throw
  try { ...各步驟呼叫 Write-FKAction... }
  finally { Close-FKActionLog }
  ```
  - `Get-FKActionLogPath` 回傳目前路徑，尚未 Open 時為 `$null`。
  - 尚未 Open 就呼叫 `Write-FKAction`（例如單獨執行 `Export-FKEventLog` 或單元測試）：**不寫檔、不 throw**，只輸出 Verbose 訊息。
  - 寫檔失敗：輸出 Warning，不中斷流程（第 3 節）。
  - 單元測試可用 `InModuleScope ForensiKit { Open-FKActionLog -PackageRoot $TestDrive }` 指定證據包。
  - 會暫時切換 action log 的函式（例如 `Install-FKPreservation` 改寫到 vault 根目錄）結束前必須還原成原本的路徑。
- `channel` 名稱轉成檔名（`/` → `%4`）一律使用內部函式 `ConvertTo-FKSafeChannelName`；ISO 8601 字串一律使用 `ConvertTo-FKIsoUtc`。

### .fkpkg（加密證據包，T08）

打包方式由 PM 於 #11 決定：**自訂串流格式**，打包、壓縮、加密、HMAC 一次串流完成，磁碟上不會出現未加密的副本，也沒有大小上限。`.fkpkg` 不是 zip，只能用 `Unprotect-FKPackage` 還原。

檔案結構（整數一律 little-endian）：

| offset | 長度 | 內容 |
|---|---|---|
| 0 | 5 | 魔術字 ASCII `FKPKG` |
| 5 | 1 | 格式版本，目前為 `1` |
| 6 | 1 | 金鑰推導演算法，`1` = PBKDF2-HMAC-SHA256 |
| 7 | 4 | PBKDF2 迭代次數（UInt32）。`Protect-FKPackage` 使用 200,000；`Unprotect-FKPackage` 只接受 100,000 – 10,000,000 |
| 11 | 16 | salt（每次隨機） |
| 27 | 16 | AES IV（每次隨機） |
| 43 | 32 | HMAC-SHA256，計算範圍是 **offset 0–42 的檔頭 ‖ offset 75 起的密文**（不含 HMAC 欄位本身） |
| 75 | 到檔尾 | 密文：AES-256-CBC、PKCS7 padding（長度為 16 的倍數） |

- **金鑰**：`PBKDF2-HMAC-SHA256(密碼的 UTF-8 位元組, salt, 迭代次數)` 推導 64 位元組；前 32 位元組為 AES 金鑰，後 32 位元組為 HMAC 金鑰。
- **明文**（解密後）是以 Deflate（`System.IO.Compression.DeflateStream`，無 zlib／gzip 標頭）壓縮的「記錄串流」：

  | 欄位 | 型別 | 說明 |
  |---|---|---|
  | 路徑長度 | UInt16 | 路徑的 UTF-8 位元組數（1–65535）；**0 表示結束記錄**，之後不得再有資料 |
  | 路徑 | UTF-8 | 相對於證據包根目錄，以 `/` 分隔，例如 `evtx/live/Security.evtx` |
  | 大小 | Int64 | 內容的位元組數（≥ 0） |
  | 內容 | 位元組 | 檔案原始內容 |

  證據包根目錄下所有檔案（含 `manifest.json`、`chain_of_custody.txt`、`action_log.jsonl`）各一筆，依完整路徑排序，最後一筆是結束記錄。空目錄不保留。
- **加密順序**（第 4 節 manifest 規則）：在 `New-FKManifest` 與 `Close-FKActionLog` 之後執行，不寫入證據包內的 action log。
- **解密**（`Unprotect-FKPackage`）：
  1. 先驗證 HMAC（固定時間比較）。不一致時 throw「密碼錯誤，或檔案已損毀／遭竄改」，**不在目的地建立任何檔案或目錄**。
  2. 驗證通過後才解密、解壓，逐筆寫到目的地下的暫存目錄，全部成功才改名為 `<目的地>\<.fkpkg 檔名去掉副檔名>`；任何錯誤都刪除暫存目錄並 throw。
  3. 逐筆檢查路徑：拒絕空字串、`..`、`.`、空的路徑片段、開頭的 `/`、反斜線、`:`（磁碟代號與 NTFS 替代資料流）、檔名不允許的字元與重複路徑，並確認完整路徑落在暫存目錄之內。
  4. 缺少結束記錄（內容被截斷）或結束記錄之後還有資料時 throw。
- 未來若要更改格式，必須遞增格式版本，並讓 `Unprotect-FKPackage` 拒絕不認得的版本。

## 5. Vault（常駐保全的備份位置）

- 路徑：`C:\ProgramData\ForensiKit\vault\<Channel 安全名稱>\<yyyyMMddTHHmmssZ>.evtx`；檔名時間是該次備份**開始**的 UTC 時間（同一次備份的所有 channel 共用），一律用內部函式 `ConvertFrom-FKVaultFileName`（`Private/ConvertFrom-FKVaultFileName.ps1`）解析，格式不符時回傳 `$null`。
  - 備份檔**可能含比檔名時間稍晚的事件**（同一次備份逐一匯出各 channel 需要時間）。依檔名時間判斷要不要略過某份備份時，必須保留安全邊界（`Export-FKEventLog` 使用 60 分鐘）。
- **vault 位置的來源**：已安裝常駐保全時以 `<安裝目錄>\preservation.json` 的 `preservation.vaultRoot` 為準，否則用 `Get-FKConfig` 的預設設定。需要 vault 設定的函式（`Export-FKEventLog -IncludeVault`、`Get-FKPreservationStatus` 等）一律透過內部函式 `Get-FKPreservationConfig` 取得，不得自行讀取設定檔。
- 權限：SYSTEM 完全控制、Administrators 唯讀，其他人無權限，不繼承上層權限。
- 由排程工作 `\ForensiKit\VaultBackup` 每 `vaultIntervalMinutes` 分鐘（預設 60）以 SYSTEM 身分執行一次，開機時與安裝完成時也各執行一次。
- **增量備份**：每個 channel 的第一份備份是整個 channel；之後每份只含「上一份備份時間往前 5 分鐘」之後的事件。因此：
  - 相鄰兩份備份可能有**重複事件**（重疊 5 分鐘）。`Export-FKEventLog -IncludeVault` 照時段條件分別匯出每一份，不需去重；分析時以 `EventRecordID` 判斷重複。
  - 要取回某時段的事件，必須掃描該 channel 目錄下的**所有**備份，不能只看最新一份。
- vault 根目錄另有 `action_log.jsonl`（備份動作紀錄）。列舉備份檔時只取 `<Channel 安全名稱>\*.evtx`。
- 容量上限：所有 `.evtx` 合計超過 `vaultMaxTotalMB` 時，從最舊的備份開始刪除，但每個 channel **至少保留最新一份**。
- 安裝目錄 `C:\ProgramData\ForensiKit\`（模組、`bin\`、`preservation.json`）只允許 SYSTEM 與 Administrators 寫入，避免一般使用者竄改 SYSTEM 排程執行的腳本。

## 6. 設定檔 `config/default-profile.json`

```json
{
  "channels": [
    "Security", "System", "Application",
    "Microsoft-Windows-Sysmon/Operational",
    "Microsoft-Windows-PowerShell/Operational",
    "Microsoft-Windows-TaskScheduler/Operational",
    "Microsoft-Windows-TerminalServices-LocalSessionManager/Operational"
  ],
  "defaultLookbackDays": 7,
  "preservation": {
    "logMaxSizeMB": { "Security": 512, "default": 128 },
    "vaultRoot": "C:\\ProgramData\\ForensiKit\\vault",
    "vaultIntervalMinutes": 60,
    "vaultMaxTotalMB": 2048
  }
}
```

## 7. 公開函式（契約）

| 函式 | 參數 | 回傳 | 負責任務 |
|---|---|---|---|
| `Write-FKAction` | `-Action <string> -Target <string> -Detail <string> -Status <string>` | 無（寫入目前證據包的 `action_log.jsonl`） | T01 |
| `Get-FKConfig` | `[-Path <string>]` | 設定物件 | T01 |
| `Export-FKEventLog` | `-StartUtc <datetime> -EndUtc <datetime> -Destination <string> [-Channels <string[]>] [-IncludeVault]` | 每個 channel 一筆 `{Channel, Source('Live'\|'Vault'), Path, EventCount, Status}` | T04 |
| `Get-FKArtifact` | `-StartUtc <datetime> -EndUtc <datetime> -Destination <string> [-Name <string[]>]` | 每種 artifact 一筆 `{Name, Path, ItemCount, Status}` | T05 |
| `Install-FKPreservation` | `[-ConfigPath <string>]` | `{LogSizesApplied, VaultRoot, TaskRegistered, Status}` | T06 |
| `Uninstall-FKPreservation` | `[-KeepVault]` | `{Status}` | T06 |
| `Get-FKPreservationStatus` | 無 | `{TaskRegistered, LastRunUtc, VaultSizeMB, LogSizes}` | T06 |
| `New-FKManifest` | `-PackageRoot <string> -CaseId <string> -Operator <string> -StartUtc <datetime> -EndUtc <datetime>` | `{ManifestPath, ManifestSha256, FileCount}` | T07 |
| `Test-FKPackage` | `-PackageRoot <string>` | `{IsValid <bool>, Mismatched <string[]>, Missing <string[]>, Extra <string[]>}` | T07 |
| `Protect-FKPackage` | `-PackageRoot <string> -Password <SecureString> [-RemovePlaintext]` | `{PackagePath, Sha256}` | T08 |
| `Unprotect-FKPackage` | `-Path <string> -Password <SecureString> -Destination <string>` | `{PackageRoot}` | T08 |
| `Invoke-ForensiKit` | `-CaseId <string> -Operator <string> -StartUtc <datetime> -EndUtc <datetime> -OutputRoot <string> [-Password <SecureString>] [-NoEncrypt]` | `{PackageRoot, PackagePath, ManifestSha256, Results, DurationSec, Status}` | T09 |
| `Start-ForensiKitGui` | 無 | 無 | T10 |

### Export-FKEventLog 的輸出與 vault 結果
- `-Destination` 是證據包中的 `evtx` 目錄（例如 `<PackageRoot>\evtx`），函式在底下建立 `live\` 與 `vault\`（第 4 節）。
- `Source = 'Live'`：每個 channel 一筆，`Path` 為 `live\<Channel 安全名稱>.evtx`。channel 不存在時 `Skipped`、`Path` 與 `EventCount` 為 `$null`。
- `Source = 'Vault'`（只在 `-IncludeVault` 時）：**每個 channel 一筆**，`Path` 為輸出目錄 `vault\<Channel 安全名稱>\`，`EventCount` 為各份備份匯出筆數的合計。
  - `Status`：全部成功 `OK`；部分失敗 `Partial`；全部失敗 `Failed`；vault 中沒有該 channel 的備份（或 vault 不存在）`Skipped`。
  - 有備份但全部依時間略過時為 `OK`、`EventCount = 0`、`Path = $null`。
  - 帶 `/` 的 channel 在 vault 與輸出中同樣以 `%4` 表示。

### 常駐保全回傳物件的子欄位
- `Install-FKPreservation` 的 `LogSizesApplied`：每個 channel 一筆 `{Channel, PreviousMB, TargetMB, Status}`。只加大不縮小；已達上限時 `Status = 'OK'` 且不變更；channel 不存在時 `Skipped`。
- `Get-FKPreservationStatus` 的 `LogSizes`：設定中每個 channel 一筆 `{Channel, MaxSizeMB, Exists <bool>}`；`LastRunUtc` 為 `Kind = Utc` 的 `[datetime]`，從未執行時為 `$null`；`VaultSizeMB` 只計算 `.evtx`。
- `Uninstall-FKPreservation` 不會把 log 上限改回原值（縮小可能使尚未匯出的事件被覆寫）；尚未安裝時回傳 `Skipped`。

`artifact` 的 `-Name` 可用值：`Prefetch`、`ScheduledTasks`、`Services`、`Autoruns`、`Processes`、`NetworkConnections`、`DnsCache`。

### Prefetch 的時間篩選規則
`LastWriteTimeUtc` 落在 `[StartUtc, EndUtc]` 內的 `.pf` 才複製（Prefetch 只記最後執行時間，報告中需註明此限制）。

### 排程、服務、自啟項、行程、網路、DNS
這些是「收集當下的狀態快照」，不依時段篩選；JSON 中每筆盡量附上可得的時間欄位（例如排程的註冊時間、行程啟動時間），並對可執行檔路徑附 SHA-256。

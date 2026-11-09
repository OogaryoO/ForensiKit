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

加密後成為單一檔案 `FK_..._<時間>.fkpkg`（T08）。

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

### action_log.jsonl（每行一個 JSON）

```json
{"timeUtc":"2026-11-21T02:03:04Z","action":"ExportEventLog","target":"Security","detail":"wevtutil epl ...","status":"OK"}
```

## 5. Vault（常駐保全的備份位置）

- 路徑：`C:\ProgramData\ForensiKit\vault\<Channel 安全名稱>\<yyyyMMddTHHmmssZ>.evtx`
- 權限：SYSTEM 完全控制、Administrators 唯讀，其他人無權限。
- 由排程工作 `\ForensiKit\VaultBackup` 每小時以 SYSTEM 身分執行一次，保留上限由設定檔決定。

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

`artifact` 的 `-Name` 可用值：`Prefetch`、`ScheduledTasks`、`Services`、`Autoruns`、`Processes`、`NetworkConnections`、`DnsCache`。

### Prefetch 的時間篩選規則
`LastWriteTimeUtc` 落在 `[StartUtc, EndUtc]` 內的 `.pf` 才複製（Prefetch 只記最後執行時間，報告中需註明此限制）。

### 排程、服務、自啟項、行程、網路、DNS
這些是「收集當下的狀態快照」，不依時段篩選；JSON 中每筆盡量附上可得的時間欄位（例如排程的註冊時間、行程啟動時間），並對可執行檔路徑附 SHA-256。

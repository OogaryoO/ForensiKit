# 單元測試（T11）

依 `docs/ARCHITECTURE.md` 的介面契約撰寫的 Pester 5 測試。**測試先於實作**：函式還沒合併時對應的測試會自動 Skip，實作合併後下次執行就會自動啟用，不必改測試檔。

## 執行

```powershell
# 需要 Pester 5（Windows 內建的是 3.4）
Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck -RequiredVersion 5.7.1
Import-Module Pester -RequiredVersion 5.7.1

Invoke-Pester ./tests/unit -Output Detailed
Invoke-Pester ./tests/unit -TagFilter T04        # 只跑某個任務
Invoke-Pester ./tests/unit -TagFilter Contract   # 只跑契約參數檢查
```

靜態分析（測試檔用專屬設定，排除 Pester 的已知誤報，原因寫在設定檔中）：

```powershell
Invoke-ScriptAnalyzer -Path ./tests/unit -Recurse -Settings ./tests/unit/PSScriptAnalyzerSettings.psd1
```

如果電腦上也裝了 Pester 6，請先 `Import-Module Pester -RequiredVersion 5.7.1`，否則 `Invoke-Pester` 會載入 6。

要測其他位置的模組（例如別的分支的 worktree）：

```powershell
$env:FK_MODULE_PATH = 'D:\other\src\ForensiKit\ForensiKit.psd1'
Invoke-Pester ./tests/unit
```

## 檔案

| 檔案 | 內容 | 依賴 |
|---|---|---|
| `_TestHelpers.ps1` | 共用輔助：匯入模組、是否可用、假證據包、SHA-256 參考實作、測試用 SecureString | 無 |
| `RepoConventions.Tests.ps1` | 所有 `.ps1/.psm1/.psd1`：UTF-8 BOM、CRLF、PS 5.1 可解析、不用 `Invoke-Expression`；`Public/` 的函式：檔名＝函式名、核准動詞、`[CmdletBinding()]`、comment-based help、有對應測試檔 | 無（現在就會執行） |
| `Contract.Parameters.Tests.ps1` | 契約第 7 節每個公開函式的參數名稱、型別、是否必填，且沒有契約以外的必填參數 | 各函式 |
| `<函式名>.Tests.ps1` | 各公開函式的行為測試 | 該函式 |

## Skip 的兩種情況

1. **函式尚未合併**：整個 `Describe` 以 `-Skip:$skip` 略過，條件由 `Test-FKCommandAvailable` 判斷，實作合併後自動啟用。
2. **需要實作細節或規格待確認**：個別 `It ... -Skip { }`，標題寫明要測什麼。實作合併、或 PM 回覆後，再補上 Mock 與斷言並拿掉 `-Skip`。目前包括：
   - `Write-FKAction` 寫檔：契約沒定義「目前證據包」怎麼指定
   - `Get-FKArtifact`、`*-FKPreservation*` 的行為：會讀寫系統狀態，要知道實作呼叫哪些 cmdlet 才能全部 Mock
   - 契約沒寫清楚的地方（各檔案「待確認」區塊）

## 安全規則

- 單元測試**不得碰觸真實系統**（事件記錄、排程、ACL、登錄檔）。外部指令一律 Mock，檔案只寫在 Pester 的 `$TestDrive`。真正的蒐證只在 VM 的 E2E（T12）中執行。
- 測試密碼由 `New-FKTestSecureString` 在記憶體中產生，不寫進任何檔案。

## 對實作的要求（為了能 Mock）

- 外部指令用名稱呼叫：`wevtutil ...` 或 `wevtutil.exe ...`，**不要**用 `& "$env:SystemRoot\System32\wevtutil.exe"` 這種完整路徑，否則 Mock 攔不到，測試會真的去讀系統事件記錄。
- 管理員檢查放在 Private 函式 `Assert-FKAdmin`（TASKS.md T01），`Invoke-ForensiKit` 的測試會 Mock 它。
- 公開函式內部呼叫其他公開函式時直接用函式名（例如 `Get-FKConfig`、`Write-FKAction`），測試會用 `Mock -ModuleName ForensiKit` 取代。

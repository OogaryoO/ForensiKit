# 測試計畫

負責人：wangLJ1015（QA）。所有成員在 T13 都要依第 5 節在自己的 VM 跑一次。

## 1. 安全規則（所有人與所有 AI 必須遵守）

1. **攻擊模擬、保全安裝、蒐證測試只能在 VM 內執行。** 不得在實體電腦、學校或公司的電腦上執行。
2. 每個攻擊模擬腳本開頭必須檢查 `C:\FK-TEST-VM.marker`，找不到就 `throw` 並結束。這個檔案只由 `scripts/vm/Setup-TestVM.ps1` 在 VM 中建立，**不要在實體電腦上手動建立它**。
3. 只用 Windows 內建指令產生「看起來像攻擊」的紀錄；不下載、不撰寫真正的惡意程式，也不關閉或繞過防毒。
4. 測試帳號一律以 `fk_` 開頭，密碼只存在 VM 內，不寫進 repo。
5. 證據包、EVTX、測試輸出一律放在 `output/` 或 `tests/e2e/run/`（已 gitignore），不得 commit。
6. 每次完整測試前先還原快照 `clean-baseline`，確保結果可重現。

## 2. 測試環境

| 項目 | 規格 |
|---|---|
| 虛擬化 | VirtualBox 7（Hyper-V 亦可） |
| 作業系統 | Windows 11 Enterprise 評估版（90 天免費；Windows 10 亦可） |
| 資源 | 2 vCPU、4 GB RAM、60 GB 磁碟、NAT 網路 |
| 預裝 | Sysmon（SwiftOnSecurity 設定）、4688 命令列稽核、PowerShell Script Block Logging、Pester 5、PSScriptAnalyzer、Git |
| 快照 | `clean-baseline`：完成上述設定、尚未安裝 ForensiKit |

建置步驟見 `docs/VM_SETUP.md`（T02 產出）。

## 3. 攻擊模擬情境（T03）

| 情境 | 做法（只用內建指令） | 應出現的關鍵事件 |
|---|---|---|
| S1 暴力破解登入 | 建立本機帳號 `fk_victim`，以錯誤密碼連 `\\localhost\IPC$` 多次，最後一次用正確密碼 | Security 4625 ×N、4624（LogonType 3） |
| S2 建立後門帳號 | `net user fk_backdoor … /add`，再加入 Administrators | Security 4720、4732 |
| S3 可疑 PowerShell | `powershell -EncodedCommand`（內容為 `whoami`） | Security 4688（含命令列）、PowerShell 4104、Sysmon 1 |
| S4 持久化 | `schtasks /create` 每分鐘執行 `C:\Users\Public\fk_updater.cmd`；另寫入 HKCU Run 機碼 | Security 4698、TaskScheduler 106、Sysmon 13；`scheduled_tasks.json`、`autoruns.json` 中出現該項 |
| S5 偵察與外連 | `whoami /all`、`net user`、`ipconfig /all`、`Resolve-DnsName example.com` | Sysmon 1、Sysmon 22；`dns_cache.json` 含 example.com |
| S6 清除紀錄 | 保全排程至少執行一次後，`wevtutil cl Security` | Security 1102；**vault 中仍可找回 S1–S4 的 Security 事件**（AC5） |
| S7 時段外雜訊 | 在指定時段開始**之前**先跑一次 S3 | 這些事件**不得**出現在證據包的 live 匯出中（AC2） |

每個情境結束後還原：刪除 `fk_` 帳號、排程與 Run 機碼（腳本需提供 `-Cleanup` 參數）。

## 4. 驗收量測方式（對應 PROJECT_PLAN.md 的 AC1–AC8）

| 編號 | 量測方式 | 通過門檻 |
|---|---|---|
| AC1 | 找一位沒看過 GUI 的人（可以是組員以外的同學）依 `SOP.md` 操作，計算點擊步驟與秒數；同時記錄 `DurationSec` | ≤ 3 步、≤ 600 秒 |
| AC2 | 對證據包中每個 live EVTX 用 `Get-WinEvent -Path` 檢查所有事件的 `TimeCreated` | 100% 落在 `[StartUtc, EndUtc]` |
| AC3 | 比較證據包內 `evtx/live` 總大小 與 直接複製 `C:\Windows\System32\winevt\Logs` 中相同 channel 的總大小 | 縮小 ≥ 50% |
| AC4 | 用 `tests/e2e/expected/*.json` 比對證據包 | 關鍵事件命中率 ≥ 90% |
| AC5 | S6 後檢查 `evtx/vault/` 是否含清除前的 4625／4720 | 可取回 |
| AC6 | `Test-FKPackage` 驗證通過；再隨機竄改 1 個檔案的 1 個位元組後重驗 | 竄改前全部一致、竄改後正確指出該檔 |
| AC7 | 依 `TASKS.md` T17，在同一快照與情境下比較手動複製、KAPE、ForensiKit | ForensiKit 步驟數與大小勝出，其餘欄位如實記錄 |
| AC8 | 講師審閱範例證據包（T19） | 取得書面或訊息回饋並記錄在 Issue |

量測時，「整檔複製」的基準一律指同一組 channel 的 `.evtx` 原檔；KAPE 的設定（target 名稱、版本）要寫進報告，讓結果可重現。

## 5. 每位成員的 VM 實測流程（T13）

> 三人都要做一次，各自請自己的 AI agent 協助，但**每個指令都在 VM 內執行**。

1. 依 `docs/VM_SETUP.md` 建好 VM，還原到 `clean-baseline` 快照。
2. 在 VM 內 `git clone` 本 repo 並切到 `main` 最新版。
3. 以系統管理員身分開 PowerShell：
   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass
   .\tests\e2e\Invoke-E2E.ps1 -Scenario All
   ```
4. 另外用 GUI 手動做一次匯出（模擬值班人員操作），記錄步驟數與時間。
5. 把 `Invoke-E2E.ps1` 輸出的結果表、GUI 實測紀錄、遇到的問題貼到 T13 Issue；有 bug 另開 `bug` Issue。
6. 還原快照。

## 6. Bug 回報格式

使用 `.github/ISSUE_TEMPLATE/bug.md`。必填：重現步驟、預期結果、實際結果、VM 的 OS 版本、使用的 commit SHA、相關 action log 片段（**不要貼整個證據包**）。

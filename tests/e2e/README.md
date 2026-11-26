# tests/e2e — 攻擊模擬情境與預期結果（T03）

這個資料夾是 QA（wangLJ1015）為 ForensiKit 準備的端到端測試素材。T12 的 `Invoke-E2E.ps1`
會以這裡的情境腳本產生事件、呼叫 `Invoke-ForensiKit` 匯出證據包，再用 `expected/` 的清單
算出 AC2／AC4／AC5 等驗收指標。

> **安全規則（務必遵守，見 `docs/TEST_PLAN.md` 第 1 節）**
> 這些腳本只能在 ForensiKit 測試 VM 內、以系統管理員身分執行。每支腳本開頭都會檢查
> `C:\FK-TEST-VM.marker`，找不到就拒絕執行。請勿在實體電腦上手動建立該標記檔。

## 目錄結構

```
tests/e2e/
├─ lib/FKScenario.Common.ps1   共用輔助函式（情境腳本以 dot-source 載入）
├─ scenarios/S1..S7-*.ps1       七個攻擊模擬情境（只用 Windows 內建指令）
├─ expected/S1..S6.json         每個情境的「預期事件」清單（AC4 命中率用）
├─ expected/artifacts.json      artifact 層級的預期（S4／S5）
└─ run/                         執行時產生的時間紀錄與暫存輸出（已 gitignore，不 commit）
```

## 情境總覽

| 情境 | 腳本 | 動作（只用內建指令） | 主要預期事件 |
|---|---|---|---|
| S1 | `S1-BruteForceLogon.ps1` | 對 `fk_victim` 連續錯誤密碼、最後一次成功 | Security 4625 ×N、4624（LogonType 3） |
| S2 | `S2-BackdoorAccount.ps1` | 新增 `fk_backdoor` 並加入 Administrators | Security 4720、4732 |
| S3 | `S3-SuspiciousPowerShell.ps1` | `powershell -EncodedCommand`（內容為無害的 whoami） | Security 4688、PowerShell 4104、Sysmon 1 |
| S4 | `S4-Persistence.ps1` | 每分鐘排程工作 ＋ HKCU Run 機碼 | Security 4698、TaskScheduler 106、Sysmon 13 |
| S5 | `S5-ReconAndDns.ps1` | `whoami /all`、`net user`、`ipconfig /all`、`Resolve-DnsName example.com` | Sysmon 1、Sysmon 22 |
| S6 | `S6-ClearSecurityLog.ps1` | `wevtutil cl Security`（破壞性） | Security 1102；vault 仍可取回 → AC5 |
| S7 | `S7-OutOfWindowNoise.ps1` | 時段「開始前」先跑一次 S3 的動作 | 這些事件**不得**出現在 live 匯出 → AC2 |

## 共同介面

每支情境腳本都是：

```powershell
.\scenarios\Sx-Name.ps1            # 執行情境，並把 UTC 起訖寫到 run\Sx.time.json
.\scenarios\Sx-Name.ps1 -Cleanup   # 還原該情境建立的帳號／排程／機碼（無副作用的情境則為 no-op）
```

- **S6** 另有 `-Force`（略過「vault 必須已有 Security 備份」檢查）與標準的 `-Confirm`／`-WhatIf`
  （`SupportsShouldProcess`，`ConfirmImpact = High`），因為清除 log 無法還原。跑完 S6 一定要把 VM
  還原到 `clean-baseline`：VirtualBox 是快照、Hyper-V 是檢查點、Azure 是 OS 磁碟快照，做法見 `docs/VM_SETUP.md`。
- 測試帳號一律以 `fk_` 開頭，密碼在執行時隨機產生、只存在記憶體，**不會**寫入 repo 或主控台。

## `run/<情境>.time.json`

每次執行產生，供 E2E 決定匯出時段：

```json
{
  "scenario": "S1",
  "title": "暴力破解登入",
  "host": "WIN11-TEST",
  "startUtc": "2026-11-20T03:15:02Z",
  "endUtc": "2026-11-20T03:15:48Z",
  "steps": ["建立本機帳號 fk_victim", "以錯誤密碼嘗試 6 次…", "以正確密碼成功登入一次…"],
  "note": "…"
}
```

## 預期事件清單 `expected/Sx.json`

格式為陣列，每筆是一個「至少要出現」的事件條件（沿用 `docs/TASKS.md` 約定，另加 `note`）：

```json
[
  { "channel": "Security", "eventId": 4625, "minCount": 5, "match": "TargetUserName=fk_victim", "note": "…" }
]
```

- `channel`：事件通道名稱。
- `eventId`：事件 ID。
- `minCount`：此條件在匯出時段內至少要命中的事件數。
- `match`：以 `;` 分隔的 `欄位=值` 條件，**全部**都要在事件的 XML／EventData 中（不分大小寫、子字串）找到；
  空字串表示只看數量、不比對欄位。例如 `TargetUserName=fk_victim;LogonType=3` 代表兩個條件都要成立。
  用 SID（如 `TargetSid=S-1-5-32-544`）比對可避免中英文版群組名稱差異。

**AC4 命中率** ＝（命中的條件數 ÷ 全部條件數）。門檻 ≥ 90%（`docs/TEST_PLAN.md` 第 4 節）。

### 為什麼 S7 沒有 `expected/S7.json`
S7 驗證的是 **AC2（時段裁切）**：匯出的每個 live 事件的 `TimeCreated` 都要落在 `[StartUtc, EndUtc]` 內。
這是純時間檢查，不需要「預期要出現的事件」清單——相反地，S7 刻意在時段外製造事件，E2E 只要確認
它們**沒有**出現在 `evtx/live` 即可。因此 S7 只產生 `run/S7.time.json`，不配對 expected 檔。

## artifact 層級預期 `expected/artifacts.json`
事件以外，S4／S5 還要檢查證據包 `artifacts/` 下的 JSON 是否含特定字串（如 `scheduled_tasks.json`
含 `fk_updater`、`dns_cache.json` 含 `example.com`）。schema 見該檔內的 `note`。

## 編碼
`.ps1` 為 UTF-8 with BOM、CRLF（PS 5.1 讀中文需要 BOM）。`.json` 為 UTF-8（無 BOM）；
讀取時請用 `Get-Content -Raw -Encoding UTF8 | ConvertFrom-Json`。

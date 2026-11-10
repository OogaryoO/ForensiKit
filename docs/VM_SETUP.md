# 測試 VM 建置指南（T02）

負責人：wangLJ1015（QA）。三位成員都依這份文件建一台 VM，之後的攻擊模擬、E2E 與 T13 實測都在這台 VM 裡進行。

> **安全規則（摘自 `docs/TEST_PLAN.md` 第 1 節）**
> - 攻擊模擬、保全安裝、蒐證測試**只能在 VM 內執行**，不要在自己的電腦、學校或公司的電腦上執行。
> - `C:\FK-TEST-VM.marker` 只由 `scripts/vm/Setup-TestVM.ps1` 在 VM 中建立，**不要在實體電腦上手動建立它**。腳本會先確認自己在虛擬機器裡，偵測不到就拒絕執行。
> - VM 裡的證據包、EVTX、測試輸出都不要 commit，也不要上傳到雲端。

整個流程約 1.5～2 小時，大部分時間在等 Windows 安裝與更新。

## 1. 主機需求

| 項目 | 建議 |
|---|---|
| 主機記憶體 | 16 GB 以上（VM 要分 4 GB） |
| 主機可用空間 | 100 GB 以上（VM 磁碟、ISO、快照） |
| CPU 虛擬化 | BIOS/UEFI 中已開啟 Intel VT-x 或 AMD-V |
| 虛擬化軟體 | VirtualBox 7.x（Hyper-V 亦可，步驟需自行對照） |

> 主機若開著 Hyper-V、WSL2 或「記憶體完整性」，VirtualBox 仍能執行，但會比較慢（VM 視窗右下角會出現綠色烏龜圖示）。慢一點沒關係，**不要為了這個關掉主機的安全功能**。

## 2. 下載

1. **VirtualBox 7**：<https://www.virtualbox.org/wiki/Downloads> → Windows hosts，安裝時全部用預設值；也可以用 `winget install --id Oracle.VirtualBox --exact`。
   - 已經裝了 VirtualBox 6 以前的版本，請先升級：舊版不支援 TPM 2.0 與安全開機，裝不了 Windows 11；主機開著 Hyper-V／VBS 時也常常無法啟動 VM。
2. **Windows 11 Enterprise 評估版 ISO**：<https://www.microsoft.com/en-us/evalcenter/evaluate-windows-11-enterprise>
   - 需要填表登記，「公司名稱」填學校即可（例如 National Taiwan University）。選 **ISO – Enterprise**、**64-bit**、語言選繁體中文或英文都可以。
   - 評估版從安裝當天起可用 **90 天**，過期後會定時自動關機。現在安裝可以用到明年 2 月初，足夠撐過本學期。
   - 用 Windows 10 Enterprise 評估版也可以，步驟相同。

## 3. 建立 VM（VirtualBox 7）

1. 開 VirtualBox → **新增（New）**。
2. 名稱：`FK-Win11`；ISO 映像檔：選剛下載的 ISO；類型會自動帶入 **Windows 11 (64-bit)**。
3. 勾選 **略過自動安裝（Skip Unattended Installation）**，這樣安裝時才能自己選語言與建立本機帳號。
4. 硬體：

   | 項目 | 設定 |
   |---|---|
   | 記憶體 | 4096 MB |
   | 處理器 | 2 顆 |
   | EFI | 開啟（選 Windows 11 時自動開啟） |

5. 硬碟：**80 GB，動態配置**（不要預先配置完整大小）。

   > `docs/TEST_PLAN.md` 原本寫 60 GB，但 **Windows 11 安裝程式要求至少 64 GB**，小於 64 GB 會無法安裝，所以這裡改成 80 GB。動態配置只會用掉實際寫入的空間。

6. 建立完成後，進入 **設定（Settings）** 確認：
   - **系統 → TPM**：v2.0；**安全開機（Secure Boot）**：開啟（選 Windows 11 時會自動設定）。
   - **網路 → 介面卡 1**：**NAT**。
   - **一般 → 進階**：共用剪貼簿可選「主機到客體」；**拖放：停用**。
   - **共用資料夾：不要設定**。VM 與主機隔離，測試輸出才不會跑到主機上。

## 4. 安裝 Windows

1. 啟動 VM，依畫面安裝 Windows。磁碟選唯一的那一顆，下一步即可。
2. 進入設定畫面（OOBE）後：
   - 地區：台灣；鍵盤依個人習慣。
   - 要求登入 Microsoft 帳戶時，選 **登入選項 → 改為加入網域（Domain join instead）**，改建本機帳號。
   - **帳號名稱不要用 `fk_` 開頭**（例如用 `analyst`）。`fk_` 開頭的帳號保留給攻擊模擬，情境腳本的 `-Cleanup` 會刪除它們。
   - 密碼自訂，**只存在 VM 裡，不要寫進 repo**。
   - 隱私權設定全部關閉。
3. 進入桌面後，VirtualBox 選單 **裝置 → 插入 Guest Additions CD 映像**，執行光碟中的 `VBoxWindowsAdditions.exe`，裝完重新開機（解析度與滑鼠會比較順）。
4. **設定 → Windows Update**：先把更新全部裝完並重新開機，再選 **暫停更新**（暫停最久的時間）。這樣基準快照比較穩定，測試期間不會被更新打斷或改變結果。

## 5. 執行建置腳本

在 VM 中：開始 → 搜尋 **Windows PowerShell** → 按右鍵 **以系統管理員身分執行**。

> 要用 **Windows PowerShell 5.1**（藍色視窗，`powershell.exe`），不要用 PowerShell 7（`pwsh`）或 PowerShell ISE。

```powershell
Set-ExecutionPolicy -Scope Process Bypass
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$url  = 'https://raw.githubusercontent.com/OogaryoO/ForensiKit/main/scripts/vm/Setup-TestVM.ps1'
$dest = "$env:USERPROFILE\Downloads\Setup-TestVM.ps1"
Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
& $dest
```

> - 這個 PR 合併進 `main` 之前，請把網址中的 `main` 換成分支名稱 `test/T02-vm-setup`。
> - 請用上面的方式下載，**不要**用記事本複製貼上存檔：記事本預設存成沒有 BOM 的 UTF-8，PowerShell 5.1 讀到中文會變成亂碼而無法執行。

腳本會依序做下列設定，已經設定好的步驟會直接跳過，所以**可以安心重跑**：

| 步驟 | 內容 | 對應情境／用途 |
|---|---|---|
| 時區 | 設為 `Taipei Standard Time` | 驗證 UTC 與 +08:00 的轉換與顯示 |
| 稽核原則 | 登入、使用者帳戶管理、安全性群組管理、程序建立、其他物件存取事件，全部設為「成功與失敗」 | S1 4624/4625、S2 4720/4732、S3 4688、S4 4698 |
| 4688 含命令列 | `ProcessCreationIncludeCmdLine_Enabled = 1` | S3 |
| Script Block Logging | `EnableScriptBlockLogging = 1` | S3 4104 |
| 事件記錄通道 | 啟用 PowerShell、TaskScheduler、TerminalServices-LocalSessionManager 的 Operational 通道（TaskScheduler 預設是關閉的） | S4 TaskScheduler 106 |
| Sysmon | 從 Sysinternals 官方下載、驗證 Microsoft 數位簽章後安裝，套用 [SwiftOnSecurity 設定](https://github.com/SwiftOnSecurity/sysmon-config) | S3 Sysmon 1、S4 Sysmon 13、S5 Sysmon 22 |
| Pester 5 | `Install-Module Pester -Scope CurrentUser`（限 5.x） | 單元測試、E2E |
| PSScriptAnalyzer | `Install-Module PSScriptAnalyzer -Scope CurrentUser` | 靜態檢查 |
| Git | 用 `winget` 安裝（選用；失敗不影響標記檔） | T13 在 VM 內 `git clone` |
| 標記檔 | 以上必要步驟都通過後才建立 `C:\FK-TEST-VM.marker` | 攻擊模擬腳本的執行前檢查 |

腳本**不會**安裝 ForensiKit 本身，也不會建立任何 `fk_` 測試帳號；基準快照必須是「尚未安裝 ForensiKit」的乾淨狀態。

最後會印出一張結果表，每一列的 Status 是 `OK`、`Failed` 或 `Skipped`。只要有必要步驟不是 `OK`，腳本就不會建立標記檔，並以 exit code 1 結束。

標記檔是 JSON，記錄 VM 平台、OS 版本與組建、時區、Sysmon 版本與設定檔 SHA-256、Pester 版本等資訊。之後的測試報告用它來說明測試環境，讓結果可以重現。

### 參數

| 參數 | 用途 |
|---|---|
| `-VerifyOnly` | 只檢查、不修改任何東西。還原快照後或回報 T02 時使用 |
| `-SkipGit` | 不安裝 Git |
| `-PassThru` | 把結果物件輸出到管線（給其他腳本使用） |
| `-SysmonConfigUrl` | 改用其他 Sysmon 設定檔，例如指向特定 commit 的 raw 網址 |

## 6. 重新開機並確認

1. 重新開機（Script Block Logging 只對新開的 PowerShell 生效）。
2. 再以系統管理員身分開 Windows PowerShell，執行：

   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass
   & "$env:USERPROFILE\Downloads\Setup-TestVM.ps1" -VerifyOnly
   ```

3. 確認結果表每一列都是 `OK`（Git 可以是 `Failed`，但建議手動裝好）。

## 7. 建立快照 `clean-baseline`

1. **先關機**（開始 → 電源 → 關機）。在關機狀態建快照，檔案比較小，還原後也是乾淨開機。
2. VirtualBox 主畫面選 `FK-Win11` → 右側 **快照（Snapshots）** → **拍攝（Take）**，名稱一定要是 **`clean-baseline`**。

也可以在主機的命令列操作：

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" snapshot FK-Win11 take clean-baseline
```

**每次完整測試前都要還原這個快照**（VM 須為關機狀態）：

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" snapshot FK-Win11 restore clean-baseline
```

> 不要在 `clean-baseline` 之上直接做測試再覆蓋快照。需要其他中間狀態時，另外取名（例如 `with-preservation`）。

## 8. 回報到 T02 Issue

三人都建好之後，T02 才算完成。請在 T02 Issue 留言，貼上下列內容（**不要貼密碼**）：

````markdown
VM 建置完成 ✅

- 主機：Windows 11 / VirtualBox 7.x.x
- 已建立快照：clean-baseline

`Setup-TestVM.ps1 -VerifyOnly` 結果：
```
（貼上結果表）
```

`Get-Content C:\FK-TEST-VM.marker` 內容：
```json
（貼上標記檔內容）
```
````

## 9. 常見問題

| 狀況 | 處理方式 |
|---|---|
| 安裝過程中重新開機後一直全黑、磁碟燈不動超過 10 分鐘 | 主機開著 Hyper-V／VBS 時，VirtualBox 的 UEFI 偶爾會在「重新開機」時卡住（`VBox.log` 最後停在 `EFI: debug point DXE_AP`，沒有出現 `bootmgfw.efi`）。在 VirtualBox 選單選 **機器 → 關閉電源**（強制關機），再重新啟動 VM 即可，Windows 安裝會從中斷的地方繼續。 |
| 「偵測不到虛擬機器，拒絕執行」 | 確認是在 VM 裡執行。如果確定是 VM，把錯誤訊息中的「硬體資訊」那一行貼到 T02 Issue，由 QA 補上偵測規則。**不要自己建立標記檔繞過。** |
| 「請以系統管理員身分開啟」 | 在 Windows PowerShell 圖示上按右鍵 → 以系統管理員身分執行。 |
| 中文亂碼、出現語法錯誤 | 檔案被存成沒有 BOM 的 UTF-8。刪掉後用第 5 節的 `Invoke-WebRequest` 重新下載。 |
| Pester 或 PSScriptAnalyzer 安裝失敗 | 先確認 VM 能上網（`Test-NetConnection www.powershellgallery.com -Port 443`），再重跑腳本。 |
| Sysmon 下載或安裝失敗 | 確認能連到 `download.sysinternals.com` 與 `raw.githubusercontent.com`；若顯示數位簽章驗證失敗，代表下載的檔案有問題，**不要手動略過**，回報到 T02 Issue。 |
| Git 顯示「找不到 winget」 | 新安裝的 Windows 有時要等幾分鐘 winget 才能用，或先到 Microsoft Store 更新「應用程式安裝程式」。也可以到 <https://git-scm.com/download/win> 手動安裝。 |
| 評估版還剩幾天？ | 在 VM 中執行 `slmgr /dlv` 查看。還原快照**不會**重置評估期限；過期就要重建 VM。 |
| Windows 11 安裝程式說這台電腦不符合需求 | 確認 VM 設定中 EFI、TPM 2.0、安全開機都已開啟，記憶體 ≥ 4 GB、磁碟 ≥ 64 GB、CPU ≥ 2 顆。 |

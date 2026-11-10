# 測試 VM 建置指南（T02）

負責人：wangLJ1015（QA）。三位成員都依這份文件建一台 VM，之後的攻擊模擬、E2E 與 T13 實測都在這台 VM 裡進行。

> **安全規則（摘自 `docs/TEST_PLAN.md` 第 1 節）**
> - 攻擊模擬、保全安裝、蒐證測試**只能在 VM 內執行**，不要在自己的電腦、學校或公司的電腦上執行。
> - `C:\FK-TEST-VM.marker` 只由 `scripts/vm/Setup-TestVM.ps1` 在 VM 中建立，**不要在實體電腦上手動建立它**。腳本會先確認自己在虛擬機器裡，偵測不到就拒絕執行。
> - VM 裡的證據包、EVTX、測試輸出都不要 commit，也不要上傳到雲端。

整個流程大部分時間在等 Windows 安裝與更新：主機沒開 Hyper-V／VBS 時約 1.5～2 小時；**主機開著 Hyper-V／VBS 時實測約 3 小時**（見第 10 節的實際建置紀錄）。建議一次預留一個晚上，安裝期間不要讓主機睡眠。

## 1. 主機需求

| 項目 | 建議 |
|---|---|
| 主機記憶體 | 16 GB 以上（VM 要分 4 GB） |
| 主機可用空間 | 100 GB 以上（VM 磁碟、ISO、快照） |
| CPU 虛擬化 | BIOS/UEFI 中已開啟 Intel VT-x 或 AMD-V |
| 虛擬化軟體 | VirtualBox 7.x（Hyper-V 亦可，步驟需自行對照） |

> 主機若開著 Hyper-V、WSL2 或「記憶體完整性」，VirtualBox 仍能執行，但會**慢很多**（VM 視窗右下角會出現綠色烏龜圖示）。慢一點沒關係，**不要為了這個關掉主機的安全功能**。
>
> 想知道自己的主機有沒有開 VBS，在主機的 PowerShell 執行下列指令，結果是 `2` 代表正在執行：
>
> ```powershell
> (Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard).VirtualizationBasedSecurityStatus
> ```

> **記憶體提醒**：16 GB 的主機在 VM 開著時通常只剩 2～3 GB 可用。VM 執行期間**不要同時開大型遊戲或其他吃記憶體的程式**，否則主機會大量使用分頁檔，VM 與程式都會卡頓，嚴重時 VM 可能被強制中止。要用電腦做別的事，先把 VM 關機（設定都存在虛擬硬碟裡，下次開機不必重做）。

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

### 3A.（選用）用指令建立 VM 並全自動安裝

不想一步步點畫面，可以在**主機**的 PowerShell 用 `VBoxManage` 一次建好 VM，並讓 Windows 全自動安裝（第 4 節的安裝與 OOBE 都會自動完成）。以下是實際使用過的指令，VM 放在 `D:\FK-VM`，可依自己的磁碟修改：

```powershell
$vbm  = 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'
$name = 'FK-Win11'
$base = 'D:\FK-VM'
$iso  = 'D:\FK-VM\iso\<你下載的 ISO 檔名>.iso'

& $vbm createvm --name $name --ostype Windows11_64 --basefolder $base --register
& $vbm modifyvm $name --memory 4096 --cpus 2 --firmware efi --tpm-type 2.0 --nic1 nat `
    --graphicscontroller vboxsvga --vram 128 --clipboard-mode hosttoguest --drag-and-drop disabled `
    --audio-enabled off --usb-ohci off --usb-xhci on
& $vbm modifynvram $name inituefivarstore
& $vbm modifynvram $name enrollmssignatures
& $vbm modifynvram $name enrollorclpk
& $vbm modifynvram $name secureboot --enable
$vdi = "$base\$name\$name.vdi"
& $vbm createmedium disk --filename $vdi --size 81920 --format VDI --variant Standard
& $vbm storagectl $name --name SATA --add sata --controller IntelAhci --portcount 2 --bootable on
& $vbm storageattach $name --storagectl SATA --port 0 --device 0 --type hdd --medium $vdi

# 先確認 ISO 能被辨識（應看到 OSFlavor="EnterpriseEval"、IsInstallSupported="on"）
& $vbm unattended detect --iso="$iso" --machine-readable

# 密碼放在 repo 以外的檔案（不要寫進 repo）；帳號名稱不要用 fk_ 開頭
& $vbm unattended install $name --iso="$iso" --user=analyst --password-file="$base\analyst-password.txt" `
    --full-user-name=analyst --image-index=1 --locale=zh_TW --country=TW --language=zh-TW `
    --time-zone="Taipei Standard Time" --hostname=fk-win11.local --install-additions --start-vm=gui
```

全自動安裝要注意：

- `unattended install` 會在輸出中**以明文印出密碼**。不要把這段輸出貼到 Issue 或聊天室；裝好後在 VM 裡改密碼最保險。
- 安裝完成後 VirtualBox 會問要不要刪除 VM 資料夾中的自動安裝檔（*Delete them now?*），**請按「刪除」**：那些檔案含有明文密碼，之後也用不到。
- 自動安裝會順便裝 Guest Additions，但**裝完不會自動重新開機**；要手動關機再開機一次，滑鼠整合與剪貼簿才會正常（見第 4 節第 3 點）。
- 安裝完成後把光碟退出，避免之後開機又讀到安裝光碟：

  ```powershell
  & $vbm storageattach FK-Win11 --storagectl SATA --port 1 --device 0 --type dvddrive --medium emptydrive
  ```

## 4. 安裝 Windows

1. 啟動 VM，依畫面安裝 Windows。磁碟選唯一的那一顆，下一步即可。

   > **安裝中畫面全黑是正常的**，尤其是第一次重新開機之後的「準備裝置」階段。判斷是「正常在跑」還是「卡住」，看的是**磁碟有沒有在動**，不是畫面：
   > - VM 視窗右下角的硬碟圖示有在閃，或主機上 `D:\FK-VM\FK-Win11\FK-Win11.vdi` 的大小持續變大 → 正常，繼續等。
   > - 全黑超過 10 分鐘、硬碟圖示完全不閃 → 多半是第 9 節「重新開機後卡在 UEFI」的狀況，依該處方式處理。
2. 進入設定畫面（OOBE）後：
   - 地區：台灣；鍵盤依個人習慣。
   - 要求登入 Microsoft 帳戶時，選 **登入選項 → 改為加入網域（Domain join instead）**，改建本機帳號。
   - **帳號名稱不要用 `fk_` 開頭**（例如用 `analyst`）。`fk_` 開頭的帳號保留給攻擊模擬，情境腳本的 `-Cleanup` 會刪除它們。
   - 密碼自訂，**只存在 VM 裡，不要寫進 repo**。
   - 隱私權設定全部關閉。
3. 進入桌面後，VirtualBox 選單 **裝置 → 插入 Guest Additions CD 映像**，執行光碟中的 `VBoxWindowsAdditions.exe`，裝完**一定要重新開機**（解析度與滑鼠會比較順）。

   > 重新開機之前，在 VM 畫面上點一下會跳出 VirtualBox 的「擷取滑鼠」說明視窗，而且滑鼠可能移不進 VM。這是因為 Guest Additions 的滑鼠驅動還沒生效：按 **取消** 即可，改用鍵盤操作（例如 `Win` 鍵開開始功能表），重新開機後就正常了。
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
> - VM 反應慢的時候，等視窗真的出現、游標在輸入框裡再開始打字；太早打字，前面的字會被吃掉（實際遇過「執行」對話框只收到後半段指令）。
> - 依主機速度，腳本跑完約 5～15 分鐘（主要是下載 Sysmon 與安裝模組）。

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

1. **先關機**（開始 → 電源 → 關機，或在 VM 中執行 `shutdown /s /t 0`）。在關機狀態建快照，檔案比較小，還原後也是乾淨開機。VirtualBox 選單的「ACPI 關機」實測會被 Windows 忽略，請用前面兩種方式。
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
| 安裝過程中重新開機後一直全黑、磁碟燈不動超過 10 分鐘 | 主機開著 Hyper-V／VBS 時，VirtualBox 的 UEFI 偶爾會在「重新開機」時卡住：`VM 資料夾\Logs\VBox.log` 最後停在 `EFI: debug point DXE_AP`，之後沒有出現 `bootmgfw.efi`。在 VirtualBox 選單選 **機器 → 關閉電源**（強制關機），再重新啟動 VM 即可，Windows 安裝會從中斷的地方繼續。實測卡住時 VM 還會偶爾送出網路封包、佔用一顆 CPU，看起來像在跑，其實沒有。 |
| 已經裝好 VirtualBox 5.x／6.x | 先升級到 7.x（`winget install --id Oracle.VirtualBox --exact`）。舊版不支援 TPM 2.0 與安全開機，裝不了 Windows 11；主機開著 VBS 時也常常根本開不了 VM。升級後原本的 VM 還能用，但第一次在 7.x 開啟後設定檔會升級，之後無法退回舊版。 |
| 評估中心的表單要填公司，但我是學生 | 「公司名稱」填學校（例如 National Taiwan University）即可，課程專題是正常的評估用途。 |
| 點 VM 畫面跳出「擷取滑鼠」說明，按「擷取」後滑鼠移不進去 | Guest Additions 裝好但還沒重新開機。按「取消」，用鍵盤操作，重新開機後滑鼠整合就會正常。要放開被擷取的滑鼠與鍵盤，按主機鍵（預設是右邊的 `Ctrl`）。 |
| VirtualBox 選單的「ACPI 關機」沒有反應 | Windows 會忽略它。改在 VM 中按開始 → 電源 → 關機，或執行 `shutdown /s /t 0`。 |
| VM 反應非常慢、按下去要等好幾秒才有反應 | 主機開著 Hyper-V／VBS 時的正常現象。操作後先等畫面有反應再做下一步；同時關掉主機上吃資源的程式（瀏覽器大量分頁、遊戲）。 |
| 「執行」對話框跳出「Windows 找不到 '…'」，名稱只有指令的後半段 | 對話框還沒準備好就開始打字，前半段被吃掉了。按「確定」關掉錯誤，等對話框完全出現後再輸入一次。 |
| 自動安裝完成後 VirtualBox 問 *Delete them now?* | 按「刪除」。那是自動安裝用的暫存檔，含有明文密碼。 |
| 「偵測不到虛擬機器，拒絕執行」 | 確認是在 VM 裡執行。如果確定是 VM，把錯誤訊息中的「硬體資訊」那一行貼到 T02 Issue，由 QA 補上偵測規則。**不要自己建立標記檔繞過。** |
| 「請以系統管理員身分開啟」 | 在 Windows PowerShell 圖示上按右鍵 → 以系統管理員身分執行。 |
| 中文亂碼、出現語法錯誤 | 檔案被存成沒有 BOM 的 UTF-8。刪掉後用第 5 節的 `Invoke-WebRequest` 重新下載。 |
| Pester 或 PSScriptAnalyzer 安裝失敗 | 先確認 VM 能上網（`Test-NetConnection www.powershellgallery.com -Port 443`），再重跑腳本。 |
| Sysmon 下載或安裝失敗 | 確認能連到 `download.sysinternals.com` 與 `raw.githubusercontent.com`；若顯示數位簽章驗證失敗，代表下載的檔案有問題，**不要手動略過**，回報到 T02 Issue。 |
| Git 顯示「找不到 winget」 | 新安裝的 Windows 有時要等幾分鐘 winget 才能用，或先到 Microsoft Store 更新「應用程式安裝程式」。也可以到 <https://git-scm.com/download/win> 手動安裝。 |
| 評估版還剩幾天？ | 在 VM 中執行 `slmgr /dlv` 查看。還原快照**不會**重置評估期限；過期就要重建 VM。 |
| Windows 11 安裝程式說這台電腦不符合需求 | 確認 VM 設定中 EFI、TPM 2.0、安全開機都已開啟，記憶體 ≥ 4 GB、磁碟 ≥ 64 GB、CPU ≥ 2 顆。 |

## 10. 實際建置紀錄（wangLJ1015，2026-11-09～10）

第一台 VM 的建置過程，給其他人估時間與對照狀況用。

- 主機：Windows 11 家用版、AMD Ryzen 5 7535HS、15 GB RAM、**VBS 開啟**；VM 放在 D 槽。
- VM：VirtualBox 7.2.22、Windows 11 企業評估版 26H2（組建 26300.9457，zh-TW）、4 GB／2 vCPU／80 GB，用第 3A 節的全自動安裝。

| 時間 | 經過 | 備註 |
|---|---|---|
| 11/09 約 17:10 | 檢查主機：VirtualBox 是舊的 5.2.44、VBS 開啟中 | 舊版裝不了 Win11，升級到 7.2.22（約 5 分鐘） |
| 之後 | 到評估中心下載 ISO（7.9 GB） | 表單「公司名稱」填學校 |
| 18:57 | 建立 VM、開始全自動安裝 | |
| 18:57～19:55 | 第一階段：複製與展開檔案 | 約 1 小時，畫面多半是黑的 |
| 19:55 | 第一次重新開機 → **卡在 UEFI**，畫面全黑、磁碟完全不動 | 等了 50 分鐘才發現，見第 9 節第一列 |
| 20:45 | 強制關閉電源後重新開機，安裝繼續 | 之後的重新開機都沒再卡住 |
| 20:46～21:14 | 第二階段：安裝驅動程式、OOBE、自動登入 | 約 30 分鐘 |
| 21:14～21:40 | Guest Additions 裝好但需要重新開機；VirtualBox 的 ACPI 關機被忽略，改用 `shutdown /s /t 0` | 重新開機前滑鼠移不進 VM，用鍵盤操作 |
| 21:47～21:57 | 以系統管理員身分執行 `Setup-TestVM.ps1`（約 10 分鐘） | 全部 OK |
| 11/10 19:15 | 開機後 `-VerifyOnly` 全部 OK | |
| 19:22 | 關機、建立快照 `clean-baseline` | |

從開始安裝到腳本跑完約 **3 小時**，其中約 50 分鐘浪費在 UEFI 卡住；主機沒開 VBS 應該會快很多。

試跑時找到並已修正的腳本問題：

- 全部成功時 exit code 卻是 128：腳本結尾沒有明確 `exit 0`，沿用了最後一個外部程式（git）的結束碼。已修正，現在全部通過時一定是 0。
- 不是從 git clone 執行時仍呼叫 `git rev-parse`，在紀錄中留下錯誤訊息。已改成只在 repo 內才呼叫。
- PSScriptAnalyzer 的兩個 `PSReviewUnusedParameter` 誤報（參數在 scriptblock 內使用，分析器追不到），已加上註明理由的 suppression。

## 11. 給 AI agent 的自動化附註

如果請自己的 AI agent 從主機操作 VM（像第一台 VM 的做法），下列是實際踩過的坑：

- **`VBoxManage guestcontrol` 拿不到系統管理員權限。** 以 VM 中的管理員帳號執行，得到的仍是 UAC 過濾後的一般權限（Medium integrity），所以不能直接跑 `Setup-TestVM.ps1`。做法：用 `guestcontrol copyto` 把腳本與一個很短的 `.cmd` 啟動檔放進 VM，再用 `controlvm keyboardputscancode` 按 `Win+R`、`keyboardputstring` 輸入 `.cmd` 路徑、按 `Ctrl+Shift+Enter` 以系統管理員身分執行，**UAC 視窗由人按「是」**。
- **用鍵盤輸入時只打短字串。** VM 反應慢，對話框還沒準備好時打的字會遺失；輸入後先截圖（`controlvm screenshotpng`）確認內容再按 Enter。
- **Guest Additions 裝好後要重新開機，`guestcontrol` 才能用**；之前會一直回報 *The guest execution service is not ready (yet)*。
- **`guestcontrol run` 要執行系統指令時，透過 `cmd.exe /c "…"`**（`--exe=C:\Windows\System32\cmd.exe -- cmd.exe /c "…"`）。直接指定 `shutdown.exe` 等程式時參數會錯位。
- **在 Git Bash 呼叫 `VBoxManage` 時加 `MSYS_NO_PATHCONV=1`**，否則 `cmd.exe /c` 的 `/c` 會被轉成 `C:/`，VM 裡的指令根本沒執行，只印出 cmd 的版本標題。在 PowerShell 呼叫則沒有這個問題。
- **密碼一律用 `--passwordfile` 傳入**，檔案放在 repo 以外；不要讓密碼出現在指令列或對話紀錄裡。
- **判斷 VM 是否卡住**：
  - 磁碟活動：`VBoxManage debugvm FK-Win11 statistics --pattern '*AHCI*Port0*Bytes*'`，隔幾十秒比較 `BytesWritten` 有沒有增加。
  - UEFI 卡住：`VBox.log` 中最後一次 `to 'RESETTING'` 之後沒有出現 `bootmgfw`。
  - `controlvm screenshotpng` 回傳全黑或 `E_FAIL`，可能只是 VM 螢幕進入省電；先送一個 Shift 鍵（`keyboardputscancode 2a aa`）再截圖。
- 長時間等待（安裝、腳本執行）用背景迴圈定期檢查，並把狀態回報給使用者；不要長時間無聲等待。

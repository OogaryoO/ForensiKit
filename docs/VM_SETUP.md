# 測試 VM 建置指南（T02）

負責人：wangLJ1015（QA）。三位成員都依這份文件建一台 VM，之後的攻擊模擬、E2E 與 T13 實測都在這台 VM 裡進行。

> **安全規則（摘自 `docs/TEST_PLAN.md` 第 1 節）**
> - 攻擊模擬、保全安裝、蒐證測試**只能在 VM 內執行**，不要在自己的電腦、學校或公司的電腦上執行。
> - `C:\FK-TEST-VM.marker` 只由 `scripts/vm/Setup-TestVM.ps1` 在 VM 中建立，**不要在實體電腦上手動建立它**。腳本會先確認自己在虛擬機器裡，偵測不到就拒絕執行。
> - VM 裡的證據包、EVTX、測試輸出都不要 commit，也不要複製到 VM 以外的地方（主機、雲端硬碟、聊天室）。用 Azure VM 時，這些檔案就留在那台 Azure VM 裡，不要另外上傳到 OneDrive、Google Drive 或 Azure Storage。

整個流程大部分時間在等 Windows 安裝與更新：主機沒開 Hyper-V／VBS 時約 1.5～2 小時；**主機開著 Hyper-V／VBS 時用 VirtualBox 實測約 3 小時**（見第 10 節的實際建置紀錄）。建議一次預留一個晚上，安裝期間不要讓主機睡眠。用 Azure 不必安裝 Windows，約 1 小時可以完成。

## 0. 先決定要用哪一種 VM

三種做法建出來的測試環境相同（同一支 `Setup-TestVM.ps1`、同一個快照名稱 `clean-baseline`），選一種即可：

| 你的主機 | 建議做法 | 章節 |
|---|---|---|
| 沒開 VBS／Hyper-V（第 1 節的指令結果不是 `2`） | VirtualBox 7 | 第 3 節（或 3A 全自動） |
| **開著 VBS**，Windows 是專業版／教育版／企業版 | **Hyper-V**（建議） | 第 3B 節 |
| 開著 VBS 且 VirtualBox 一直失敗，主機又是**家用版**；或主機記憶體不足 16 GB | **Azure 學生方案的雲端 VM** | 第 3C 節 |

為什麼主機開著 VBS 時建議改用 Hyper-V：VBS 本身就是靠 Hyper-V 的 hypervisor 運作，VirtualBox 這時只能透過「Windows Hypervisor Platform」間接執行，所以很慢，在 Intel CPU 上也比較容易開不了機或當掉。Hyper-V 是 Windows 內建、直接跑在同一個 hypervisor 上，不用關掉任何安全功能，速度也正常。

查主機的 Windows 版本（家用版沒有 Hyper-V）：

```powershell
(Get-CimInstance Win32_OperatingSystem).Caption
```

結果有「家用版」或「Home」，就不能用 Hyper-V，請用 VirtualBox 或 Azure。

## 1. 主機需求

| 項目 | 建議 |
|---|---|
| 主機記憶體 | 16 GB 以上（VM 要分 4 GB） |
| 主機可用空間 | 100 GB 以上（VM 磁碟、ISO、快照） |
| CPU 虛擬化 | BIOS/UEFI 中已開啟 Intel VT-x 或 AMD-V |
| 虛擬化軟體 | VirtualBox 7.x，或 Hyper-V（第 3B 節）；用 Azure（第 3C 節）就不需要本表的任何條件 |

> 主機若開著 Hyper-V、WSL2 或「記憶體完整性」，VirtualBox 仍能執行，但會**慢很多**（VM 視窗右下角會出現綠色烏龜圖示），在 Intel 主機上也比較常建立失敗。**不要為了這個關掉主機的安全功能**；改用 Hyper-V（第 3B 節）或 Azure（第 3C 節）。
>
> 想知道自己的主機有沒有開 VBS，在主機的 PowerShell 執行下列指令，結果是 `2` 代表正在執行：
>
> ```powershell
> (Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard).VirtualizationBasedSecurityStatus
> ```

> **記憶體提醒**：16 GB 的主機在 VM 開著時通常只剩 2～3 GB 可用。VM 執行期間**不要同時開大型遊戲或其他吃記憶體的程式**，否則主機會大量使用分頁檔，VM 與程式都會卡頓，嚴重時 VM 可能被強制中止。要用電腦做別的事，先把 VM 關機（設定都存在虛擬硬碟裡，下次開機不必重做）。

## 2. 下載

用 Azure 的人不用下載任何東西，直接看第 3C 節。用 Hyper-V 的人不用裝 VirtualBox，只要下載第 2 點的 ISO。

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

## 3B. 建立 VM（Hyper-V）

適合**主機開著 VBS** 且 Windows 是專業版／教育版／企業版的人。家用版沒有 Hyper-V，請改用第 3C 節。

> 本節依 Microsoft 官方文件與 cmdlet 撰寫，還沒有組員完整實測過。第一位照做的人，請把遇到的狀況與花費時間回報到 T02 Issue，QA 會補進第 9、10 節。

### 3B-1. 開啟 Hyper-V（主機，只需做一次）

在**主機**以系統管理員身分開 PowerShell：

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All
```

完成後依提示**重新開機**。也可以從「控制台 → 程式 → 開啟或關閉 Windows 功能」勾選 **Hyper-V**（底下兩項全勾）。

- 開了 Hyper-V 之後，原本的 VirtualBox VM 還是可以用（一樣慢），不必解除安裝 VirtualBox。
- 如果出現「無法安裝 Hyper-V：處理器沒有必要的虛擬化功能」，代表 BIOS/UEFI 裡的 Intel VT-x（Intel Virtualization Technology）沒開，要進 BIOS 開啟。
- Hyper-V 的指令都要用**系統管理員身分**執行。

### 3B-2. 建立 VM

在**主機**以系統管理員身分開 PowerShell，執行下列指令（VM 放在 `D:\FK-VM\Hyper-V`，可依自己的磁碟修改）：

```powershell
$name = 'FK-Win11'
$base = 'D:\FK-VM\Hyper-V'
$iso  = 'D:\FK-VM\iso\<你下載的 ISO 檔名>.iso'

New-Item -ItemType Directory -Force -Path $base | Out-Null

# 第 2 代 VM（UEFI）、4 GB、80 GB 動態擴充 VHDX、接到內建的 NAT 網路 Default Switch
New-VM -Name $name -Generation 2 -MemoryStartupBytes 4GB -Path $base `
    -NewVHDPath "$base\$name\$name.vhdx" -NewVHDSizeBytes 80GB -SwitchName 'Default Switch'

# 2 顆 vCPU、固定 4 GB 記憶體（動態記憶體會讓 Windows 11 安裝程式判定記憶體不足）、關閉自動檢查點
Set-VM -Name $name -ProcessorCount 2 -StaticMemory -CheckpointType Standard -AutomaticCheckpointsEnabled $false

# Windows 11 需要 TPM 2.0 與安全開機：先建立金鑰保護裝置，才能開啟虛擬 TPM
Set-VMKeyProtector -VMName $name -NewLocalKeyProtector
Enable-VMTPM -VMName $name

# 掛上 ISO，並設成第一個開機裝置
Add-VMDvdDrive -VMName $name -Path $iso
Set-VMFirmware -VMName $name -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows `
    -FirstBootDevice (Get-VMDvdDrive -VMName $name)

# 先打開 VM 視窗，再按視窗上的「啟動」
vmconnect.exe localhost $name
```

想用畫面操作也可以：開 **Hyper-V 管理員** → 右側 **新增 → 虛擬機器**，依序選「第 2 代」、啟動記憶體 4096 MB 並**取消勾選動態記憶體**、連線選 **Default Switch**、建立 80 GB 虛擬硬碟、從 ISO 安裝。建好後在 VM 的 **設定** 裡：**安全性** 勾選「啟用安全開機」（範本 Microsoft Windows）與「啟用信賴平台模組」；**處理器** 改成 2；**檢查點** 取消勾選「使用自動檢查點」。

設定說明：

- **Default Switch** 是 Hyper-V 內建的 NAT 網路，等同 VirtualBox 的 NAT，VM 可以上網但外部連不進來。不要改接「外部」虛擬交換器。
- **不要開「客體服務介面」**（VM 設定 → 整合服務，預設就是關閉），它可以從主機直接複製檔案進 VM，等同共用資料夾。
- 主機的記憶體一樣要留意第 1 節的提醒：Hyper-V 的 VM 開著時，主機就少了 4 GB。

### 3B-3. 安裝 Windows 時與 VirtualBox 不同的地方

接下來照第 4 節安裝 Windows，但注意：

1. 按「啟動」後畫面會出現 **Press any key to boot from CD or DVD...**，**要在幾秒內按任意鍵**。錯過的話會看到 *No operating system was loaded* 或網路開機（PXE）畫面：按工具列的 **重設** 再試一次，這次記得馬上按鍵。
2. Hyper-V **不用裝 Guest Additions**，Windows 內建 Hyper-V 的整合服務；第 4 節第 3 點跳過。
3. 安裝完成第一次登入時，VM 視窗會問解析度（增強的工作階段）。按 **顯示選項 → 本機資源 → 其他**，確認 **磁碟機沒有勾選**（不要把主機的磁碟分享給 VM）；剪貼簿可以保留。
4. 主機開著 VBS 也不會像 VirtualBox 那麼慢，安裝預計約 30～60 分鐘（尚待實測）。

### 3B-4. Hyper-V 的關機與檢查點（快照）

Hyper-V 的「快照」叫**檢查點（Checkpoint）**。第 7 節要建立的 `clean-baseline`，在 Hyper-V 用下列指令（主機、系統管理員 PowerShell）：

```powershell
# 關機（Hyper-V 會透過整合服務讓 Windows 正常關機，不會像 VirtualBox 的 ACPI 關機被忽略）
Stop-VM -Name FK-Win11

# 建立檢查點
Checkpoint-VM -Name FK-Win11 -SnapshotName clean-baseline

# 每次完整測試前還原（VM 須為關機狀態）
Restore-VMCheckpoint -VMName FK-Win11 -Name clean-baseline -Confirm:$false

# 查看目前有哪些檢查點
Get-VMCheckpoint -VMName FK-Win11
```

也可以在 Hyper-V 管理員選 VM → 右側 **檢查點**，名稱改成 `clean-baseline`。

## 3C. 建立 VM（Azure 學生方案的雲端 Windows 主機）

適合**本機跑不動 VM** 的人：家用版主機開著 VBS、VirtualBox 一直失敗，或主機記憶體不夠。Azure VM 本身就是 Hyper-V 虛擬機器，`Setup-TestVM.ps1` 會辨識為 `Azure (Hyper-V)`，可以正常建立標記檔。

> 本節依 Microsoft 官方文件撰寫，還沒有組員完整實測過。第一位照做的人，請把遇到的狀況、選的區域與大小、實際花費回報到 T02 Issue。

### 3C-1. 申請 Azure for Students

1. 到 <https://azure.microsoft.com/free/students/>，用**學校的電子郵件**驗證學生身分。
2. 學生方案**不需要信用卡**，會給一筆美金額度（目前為 US$100）、期限 12 個月；額度用完時資源會被停用，**不會從你的帳戶扣款**。實際額度與條款以申請頁面為準。
3. 授權：Windows 11 映像原本需要企業授權，但 Microsoft 文件註明**學生與免費試用帳戶可以為了開發或測試目的部署 Windows 11 映像**（[How to deploy Windows 11 on Azure](https://learn.microsoft.com/azure/virtual-machines/windows/windows-desktop-multitenant-hosting-deployment)）。本專題的測試 VM 符合這個用途；不要拿這台 VM 做其他正式用途。

### 3C-2. 查出可以用的區域

學生方案通常只允許部署到少數幾個區域，選錯區域會出現 `RequestDisallowedByAzure` 錯誤。先查清楚：

1. Azure 入口網站（<https://portal.azure.com>）上方搜尋 **原則（Policy）** → 左側 **指派（Assignments）**。
2. 點開名稱類似 **Allowed resource deployment regions**（允許的資源部署區域）的指派 → **參數**，就是你能用的區域清單。
3. 從清單中選離台灣最近的區域（例如 East Asia、Southeast Asia、Japan East，有哪個用哪個）。之後所有資源都建在**同一個區域**。

### 3C-3. 建立 VM

入口網站搜尋 **虛擬機器** → **建立 → Azure 虛擬機器**，依下表填寫，沒列到的用預設值：

| 分頁 | 欄位 | 填寫 |
|---|---|---|
| 基本 | 資源群組 | 新建 `fk-rg`（結束時整個群組一起刪除，最乾淨） |
| 基本 | 虛擬機器名稱 | `FK-Win11` |
| 基本 | 區域 | 第 3C-2 節查到的區域 |
| 基本 | 可用性選項 | 不需要基礎結構備援 |
| 基本 | 安全性類型 | **受信任的啟動虛擬機器**（Trusted launch，含安全開機與 vTPM） |
| 基本 | 映像 | **Windows 11 Enterprise**（最新版本，x64 Gen2）。找不到就按「查看所有映像」搜尋 Windows 11。**不要選 multi-session，也不要選 Windows Server**（腳本只支援用戶端版） |
| 基本 | 大小 | 2 vCPU、4 GiB，例如 `Standard_B2s` 或 `Standard_B2als_v2`；顯示無法使用就換一個同規格的大小 |
| 基本 | 系統管理員帳戶 | 使用者名稱 `analyst`（**不要用 `fk_` 開頭**，Azure 也不允許 `admin`、`administrator`）；密碼自訂並存在密碼管理員，**不要寫進 repo 或貼到聊天室** |
| 基本 | 公用輸入連接埠 | **無**（下一步再開放給自己的 IP，不要讓整個網際網路都能連 RDP） |
| 基本 | 授權 | 勾選「我確認擁有符合資格的 Windows 10/11 授權…」（依第 3C-1 節第 3 點，學生帳號的開發測試用途） |
| 磁碟 | OS 磁碟類型 | **標準 SSD**（進階 SSD 比較貴）；大小用預設 127 GiB 即可；勾選「與 VM 一起刪除」 |
| 管理 | 自動關機 | **開啟**，時間設在你不會用的時段（例如台北時間 02:00），避免忘記關機燒光額度 |

按 **檢閱 + 建立 → 建立**，約 5～10 分鐘完成。

### 3C-4. 只讓自己的 IP 連 RDP

1. VM 頁面左側 **網路設定 → 建立連接埠規則 → 輸入連接埠規則**。
2. 來源：**我的 IP 位址**；服務：**RDP**；動作：允許；名稱 `RDP-from-my-IP` → 新增。

> **為什麼一定要限制來源 IP**：RDP 開放給整個網際網路，幾分鐘內就會有人來暴力破解，Security log 會塞滿來自陌生 IP 的 4625。這除了危險，也會**污染 S1 暴力破解情境與時段篩選的測試結果**。如果在 VM 裡看到不是自己造成的 4625，代表規則沒設好：先修正規則，再還原快照。
>
> 換了網路（家裡、學校、手機熱點）IP 就會變，要回到這裡把來源改成新的「我的 IP 位址」才連得上。

### 3C-5. 連線與設定

1. VM 頁面 → **連線 → RDP → 下載 RDP 檔案**，開啟後用 `analyst` 登入。
2. 連線前在遠端桌面視窗按 **顯示選項 → 本機資源 → 其他**，確認 **磁碟機沒有勾選**（等同不設定共用資料夾）；剪貼簿可以保留，方便貼回結果表。
3. 登入後**不必做第 4 節的安裝**，直接做：
   - 第 4 節第 4 點：Windows Update 全部裝完並重新開機，再暫停更新。
   - 第 5、6 節：下載並執行 `Setup-TestVM.ps1`、重新開機後 `-VerifyOnly`。
4. Azure 的 Windows 11 映像預設是**英文介面、UTC 時區**。腳本會把時區改成台北；英文介面不影響測試（稽核設定以 GUID 指定）。要中文介面可自行安裝語言套件，非必要。

### 3C-6. 停止 VM 與費用

- **用完一定要在入口網站按「停止」**，狀態要變成「**已停止（已解除配置）**」才不會計算 VM 費用。在 Windows 裡按關機或 `shutdown /s`，狀態只會是「已停止」，**仍然持續計費**。
- 停止後仍會收磁碟、快照與公用 IP 的費用，但比開機時少很多。費用依區域與大小而異，請用 [Azure 定價計算機](https://azure.microsoft.com/pricing/calculator/) 估算，並在入口網站搜尋「教育」（Education）查看剩餘額度。
- 建議在 **成本管理 → 預算** 設一個小額預算（例如 US$20）並開啟通知。
- 學期結束、或確定不再使用時，刪除整個資源群組 `fk-rg`（VM、磁碟、快照、IP 一次刪光）。刪除後無法復原，請先確認裡面沒有要保留的東西。

### 3C-7. Azure 的快照 `clean-baseline` 與還原

Azure 沒有 VirtualBox 那種「一鍵還原」的 VM 快照，做法是**替 OS 磁碟拍快照，還原時用快照建一顆新磁碟，再把 VM 的 OS 磁碟換成它**。

**用入口網站：**

1. 建立：VM 按 **停止**（等到已解除配置）→ 左側 **磁碟** → 點 OS 磁碟 → **建立快照**：名稱 `clean-baseline`、快照類型 **增量**、儲存體類型 **標準 HDD**。
2. 還原：VM 按 **停止** → 開啟快照 `clean-baseline` → **建立磁碟**（名稱例如 `FK-Win11-os-20261111`、標準 SSD，安全性類型選**受信任的啟動**）→ 回到 VM 的 **磁碟** → **交換作業系統磁碟** → 選剛建立的磁碟 → 啟動 VM。確認開機正常後，刪除被換下來的舊 OS 磁碟（否則會繼續計費）。

**用指令**（入口網站右上角的 Cloud Shell 選 PowerShell，或在主機安裝 Azure CLI 後 `az login`）：

```powershell
$rg = 'fk-rg'
$vmName = 'FK-Win11'

# 建立快照 clean-baseline（VM 須已解除配置）
az vm deallocate -g $rg -n $vmName
$osDisk = az vm show -g $rg -n $vmName --query 'storageProfile.osDisk.managedDisk.id' -o tsv
az snapshot create -g $rg -n clean-baseline --source $osDisk --incremental true --sku Standard_LRS
```

```powershell
# 每次完整測試前還原
$rg = 'fk-rg'
$vmName = 'FK-Win11'
az vm deallocate -g $rg -n $vmName
$oldDisk = az vm show -g $rg -n $vmName --query 'storageProfile.osDisk.managedDisk.id' -o tsv
$newDisk = 'FK-Win11-os-' + (Get-Date -Format 'yyyyMMdd-HHmm')
az disk create -g $rg -n $newDisk --source clean-baseline --sku StandardSSD_LRS `
    --hyper-v-generation V2 --security-type TrustedLaunch
az vm update -g $rg -n $vmName --os-disk $newDisk
az vm start -g $rg -n $vmName
# 確認 VM 能正常登入、Setup-TestVM.ps1 -VerifyOnly 全部 OK 之後，再刪除舊磁碟：
# az disk delete --ids $oldDisk --yes
```

### 3C-8. 在 Azure 上測試要注意的事

- **RDP 登入本身會產生事件**：Security 4624（LogonType 10）、TerminalServices-LocalSessionManager 21/22/25 等。這些是你連線造成的正常紀錄，在證據包中看到不算誤判；S1 要驗證的是 LogonType 3 的 4624／4625。
- 攻擊模擬情境都只在這台 VM 內部用內建指令執行，符合 Microsoft 雲端「只測試自己的資源」的規定。**不要對其他主機或 IP 做掃描、登入嘗試或大量連線。**
- Microsoft Defender 可能對 S3 的 `-EncodedCommand` 等行為發出警示，這是預期的；依 `docs/TEST_PLAN.md` 安全規則第 3 條，**不要關閉防毒**。
- 證據包與測試輸出留在 VM 內檢查即可；需要放進測試報告的只有結果表、雜湊值等文字摘要，用剪貼簿貼出來，不要把整個證據包下載到主機或上傳雲端硬碟。

## 4. 安裝 Windows

> 用 Azure（第 3C 節）的人跳過本節的第 1～3 點，只做第 4 點。用 Hyper-V（第 3B 節）的人，請先看第 3B-3 節與 VirtualBox 不同的地方。

1. 啟動 VM，依畫面安裝 Windows。磁碟選唯一的那一顆，下一步即可。

   > **安裝中畫面全黑是正常的**，尤其是第一次重新開機之後的「準備裝置」階段。判斷是「正常在跑」還是「卡住」，看的是**磁碟有沒有在動**，不是畫面：
   > - VM 視窗右下角的硬碟圖示有在閃，或主機上 `D:\FK-VM\FK-Win11\FK-Win11.vdi` 的大小持續變大 → 正常，繼續等。
   > - 全黑超過 10 分鐘、硬碟圖示完全不閃 → 多半是第 9D 節「重新開機後卡在 UEFI」的狀況，依該處方式處理。
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

> 本節是 VirtualBox 的做法。Hyper-V 見第 3B-4 節（檢查點），Azure 見第 3C-7 節（磁碟快照）；快照名稱一律是 `clean-baseline`。

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

- 平台：VirtualBox 7.x.x ／ Hyper-V ／ Azure（區域、VM 大小）
- 主機：Windows 11 專業版、VBS 開啟（用 Azure 可省略）
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

### 9A. VirtualBox 建不起來（尤其是 Intel 主機＋VBS 開啟）

先把錯誤訊息與 `VM 資料夾\Logs\VBox.log` 最後 50 行貼到 T02 Issue，再依下表處理。**不要為了 VirtualBox 關掉主機的 VBS、記憶體完整性或 Windows Defender。**

| 狀況 | 處理方式 |
|---|---|
| 啟動 VM 時出現 `VERR_NEM_NOT_AVAILABLE`、`VERR_NEM_VM_CREATE_FAILED`、`VERR_VMX_NO_VMX` 或 *VT-x is not available* | 主機的 hypervisor 被 VBS 佔用，VirtualBox 需要透過「Windows Hypervisor Platform」才能執行。在主機以系統管理員身分執行 `Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform`，重新開機後再試。仍然失敗就改用 Hyper-V（第 3B 節）或 Azure（第 3C 節）。 |
| VM 一開機就 *Guru Meditation*、自己中止，或安裝到一半當掉，重試幾次都一樣 | VirtualBox 跑在 Hyper-V 之上時，Intel CPU 比較容易遇到這種不穩定。先升級到最新的 VirtualBox 7.x；還是不行就**不要再花時間重試**，改用 Hyper-V（專業版／教育版／企業版主機）或 Azure（家用版主機）。 |
| *Kernel driver not installed (rc=-1908)* 或驅動程式相關錯誤 | 以系統管理員身分重新安裝 VirtualBox 7.x 並重新開機。 |

### 9B. Hyper-V

| 狀況 | 處理方式 |
|---|---|
| 「開啟或關閉 Windows 功能」裡沒有 Hyper-V；`Enable-WindowsOptionalFeature` 說找不到功能 | 主機是家用版，沒有 Hyper-V。改用 Azure（第 3C 節）。 |
| 開機出現 *No operating system was loaded* 或網路開機（PXE）畫面 | 錯過了 *Press any key to boot from CD or DVD*。按工具列 **重設**，一出現提示就按任意鍵。也確認 `Set-VMFirmware -FirstBootDevice` 指向 DVD。 |
| `Enable-VMTPM` 出錯，提到金鑰保護裝置 | 先執行 `Set-VMKeyProtector -VMName FK-Win11 -NewLocalKeyProtector`，再執行 `Enable-VMTPM`。 |
| Windows 11 安裝程式說「這部電腦無法執行 Windows 11」 | 確認是**第 2 代** VM、已啟用 TPM 與安全開機、記憶體是**固定** 4 GB（`Set-VM -StaticMemory`）、2 顆 vCPU。第 1 代 VM 無法安裝 Windows 11，要刪掉重建。 |
| VM 連不上網路 | 確認網路介面卡接到 **Default Switch**（`Get-VMNetworkAdapter -VMName FK-Win11`）。主機重新開機後 Default Switch 的網段會改變，VM 重新開機即可。 |
| 增強的工作階段畫面全黑、一直要求重新登入 | 在 VM 視窗選 **檢視 → 取消勾選「增強的工作階段」**，改用基本工作階段。增強的工作階段需要用**密碼**登入（不是 PIN）。 |
| 執行 Hyper-V 指令時說權限不足 | 用系統管理員身分開 PowerShell。 |

### 9C. Azure

| 狀況 | 處理方式 |
|---|---|
| 建立時出現 `RequestDisallowedByAzure` 或 `RequestDisallowedByPolicy` | 選的區域不在學生方案允許的清單中。依第 3C-2 節查出允許的區域，資源群組與 VM 都建在那個區域。 |
| 選大小時顯示「無法使用」或 `SkuNotAvailable` | 換另一個 2 vCPU／4 GiB 的大小，或換到另一個允許的區域。 |
| 看不到 Windows 11 映像 | 在映像欄按「查看所有映像」，搜尋 *Windows 11*，發行者是 Microsoft（MicrosoftWindowsDesktop）。 |
| RDP 連不上 | 確認 VM 是「執行中」；你的 IP 可能變了，到 **網路設定** 把 RDP 規則的來源改成目前的「我的 IP 位址」。 |
| 交換 OS 磁碟時清單裡沒有新建的磁碟 | 新磁碟要和 VM 在同一個區域，且安全性類型為「受信任的啟動」、Hyper-V 世代 V2。重建磁碟時指定這兩項（第 3C-7 節的指令已包含）。 |
| 額度消耗比預期快 | 檢查 VM 是否真的是「已停止（已解除配置）」，而不是只在 Windows 裡關機；刪除用不到的舊 OS 磁碟與快照。 |

### 9D. 一般問題

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
| 19:55 | 第一次重新開機 → **卡在 UEFI**，畫面全黑、磁碟完全不動 | 等了 50 分鐘才發現，見第 9D 節第一列 |
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

**Hyper-V**（以下尚未實測，使用前請先驗證）：

- 從主機操作 VM 可以用 **PowerShell Direct**：`Enter-PSSession -VMName FK-Win11 -Credential analyst`（密碼由人在提示中輸入），不需要網路，也不需要開「客體服務介面」。
- 進入 session 後先執行 `whoami /groups | Select-String 'Mandatory Level'`，確認是 `High Mandatory Level` 才代表有系統管理員權限、可以跑 `Setup-TestVM.ps1`；如果是 Medium，就和 VirtualBox 一樣改由人在 VM 視窗中以系統管理員身分執行。
- 檔案用 `Copy-Item -ToSession` 透過 PowerShell Direct session 複製，不要為了傳檔案而開啟客體服務介面（`Copy-VMFile`）。

**Azure**：

- 用 Azure CLI 從主機執行 VM 內的指令：`az vm run-command invoke -g fk-rg -n FK-Win11 --command-id RunPowerShellScript --scripts '...'`。這個指令以 **SYSTEM** 身分執行，可以跑 `Setup-TestVM.ps1`，但 Pester、PSScriptAnalyzer 會裝到 SYSTEM 的使用者範圍，`analyst` 登入後看不到；建議仍由人透過 RDP 以系統管理員身分執行腳本。
- 不要把 VM 密碼放進 `az` 指令列；建立 VM 由人在入口網站完成。

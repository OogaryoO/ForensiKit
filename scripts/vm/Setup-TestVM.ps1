#Requires -Version 5.1
<#
.SYNOPSIS
    把一台全新安裝的 Windows 10/11 VM 設定成 ForensiKit 的標準測試環境（T02）。

.DESCRIPTION
    依 docs/TEST_PLAN.md 第 2 節的規格設定測試 VM。每一步都先檢查，已經設定好就跳過，所以可以重複執行：

      1. 時區設為台北標準時間（Taipei Standard Time）
      2. 稽核原則：登入、使用者帳戶管理、安全性群組管理、程序建立、其他物件存取事件（排程工作）
      3. 4688 程序建立事件包含命令列
      4. PowerShell Script Block Logging（4104）
      5. 啟用 PowerShell、TaskScheduler、TerminalServices-LocalSessionManager 的 Operational 通道
      6. 安裝 Sysmon 並套用 SwiftOnSecurity 設定
      7. 安裝 Pester 5
      8. 安裝 PSScriptAnalyzer
      9. 安裝 Git（使用 winget；這一步失敗不影響標記檔）

    所有必要步驟都通過後，才建立 C:\FK-TEST-VM.marker。攻擊模擬腳本會檢查這個檔案，確認自己在測試 VM 中。

    安全機制：腳本一開始會檢查硬體資訊，確認是在虛擬機器（VirtualBox、Hyper-V、Azure、VMware、QEMU/KVM、
    Parallels、Xen）內執行；偵測不到就拒絕執行，避免在實體電腦上建立標記檔。

.PARAMETER VerifyOnly
    只檢查、不修改任何設定，也不建立標記檔。用來確認 VM 是否符合規格，例如還原快照之後。

.PARAMETER SkipGit
    不安裝 Git。

.PARAMETER PassThru
    把每個步驟的結果物件（Step、Status、Required、Detail）輸出到管線。

.PARAMETER SysmonZipUrl
    Sysmon 的下載網址。預設為 Sysinternals 官方網址。

.PARAMETER SysmonConfigUrl
    Sysmon 設定檔的下載網址。預設為 SwiftOnSecurity/sysmon-config 的 master 版本。
    要固定版本時，可改成指向特定 commit 的 raw 網址。實際使用的設定檔 SHA-256 會記錄在標記檔中。

.EXAMPLE
    Set-ExecutionPolicy -Scope Process Bypass
    .\scripts\vm\Setup-TestVM.ps1

    在 VM 中以系統管理員身分執行完整設定。

.EXAMPLE
    .\scripts\vm\Setup-TestVM.ps1 -VerifyOnly

    只檢查目前的 VM 是否符合規格，不做任何修改。

.NOTES
    只能在測試 VM 內執行（docs/TEST_PLAN.md 安全規則第 1、2 條）。
    需要系統管理員權限與網際網路連線（VirtualBox NAT、Hyper-V Default Switch 或 Azure VM 的預設網路皆可）。
    Azure VM 會被辨識為「Azure (Hyper-V)」並記錄在標記檔的 vmPlatform。
    腳本以 -accepteula 安裝 Sysmon，執行即代表你同意 Sysinternals 的授權條款。
    執行紀錄與下載的檔案放在 C:\ProgramData\FK-TestVM\。
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = '互動式建置腳本，需要在主控台顯示進度與顏色')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'SysmonZipUrl', Justification = '在 Sysmon 步驟的 Apply scriptblock 中使用，分析器追不到')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'SysmonConfigUrl', Justification = '在 Sysmon 步驟的 Apply scriptblock 中使用，分析器追不到')]
[CmdletBinding()]
param(
    [switch]$VerifyOnly,

    [switch]$SkipGit,

    [switch]$PassThru,

    [ValidatePattern('^https://')]
    [string]$SysmonZipUrl = 'https://download.sysinternals.com/files/Sysmon.zip',

    [ValidatePattern('^https://')]
    [string]$SysmonConfigUrl = 'https://raw.githubusercontent.com/SwiftOnSecurity/sysmon-config/master/sysmonconfig-export.xml'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # PS 5.1 的 Invoke-WebRequest 顯示進度列會慢很多

$ScriptVersion = '0.2.0'
$MarkerPath    = 'C:\FK-TEST-VM.marker'
$WorkDir       = Join-Path -Path $env:ProgramData -ChildPath 'FK-TestVM'
$TimeZoneId    = 'Taipei Standard Time'

$LsaKey          = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
$CmdLineAuditKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit'
$ScriptBlockKey  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging'

# 攻擊模擬情境需要的稽核子類別。用 GUID 指定，中文版與英文版 Windows 都適用。
$AuditSubcategories = @(
    @{ Name = 'Logon';                      Guid = '{0CCE9215-69AE-11D9-BED3-505054503030}'; UsedBy = 'S1 4624/4625' }
    @{ Name = 'User Account Management';    Guid = '{0CCE9235-69AE-11D9-BED3-505054503030}'; UsedBy = 'S2 4720' }
    @{ Name = 'Security Group Management';  Guid = '{0CCE9237-69AE-11D9-BED3-505054503030}'; UsedBy = 'S2 4732' }
    @{ Name = 'Process Creation';           Guid = '{0CCE922B-69AE-11D9-BED3-505054503030}'; UsedBy = 'S3 4688' }
    @{ Name = 'Other Object Access Events'; Guid = '{0CCE9227-69AE-11D9-BED3-505054503030}'; UsedBy = 'S4 4698' }
)

# 預設蒐證設定（ARCHITECTURE.md 第 6 節）中、Windows 預設可能沒開的通道。Sysmon 通道另外檢查。
$RequiredChannels = @(
    'Microsoft-Windows-PowerShell/Operational',
    'Microsoft-Windows-TaskScheduler/Operational',
    'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational'
)

$script:SysmonInfo = $null

#region 輔助函式

function Write-Step {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )
    Write-Host $Message -ForegroundColor $Color
}

function Get-UtcTimestamp {
    return [datetime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-CheckResult {
    param(
        [Parameter(Mandatory = $true)][bool]$Ok,
        [string]$Detail = ''
    )
    return [pscustomobject]@{ Ok = $Ok; Detail = $Detail }
}

function Test-IsAdministrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object -TypeName Security.Principal.WindowsPrincipal -ArgumentList $identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-VMPlatform {
    <# 依硬體資訊判斷虛擬化平台；不是虛擬機器時 Platform 為 $null。 #>
    $cs   = Get-CimInstance -ClassName Win32_ComputerSystem
    $bios = Get-CimInstance -ClassName Win32_BIOS
    $evidence = @($cs.Manufacturer, $cs.Model, $bios.Manufacturer, $bios.SerialNumber, $bios.SMBIOSBIOSVersion) -join ' | '

    $signatures = [ordered]@{
        'VirtualBox' = 'VirtualBox|innotek'
        'VMware'     = 'VMware'
        'Hyper-V'    = 'Microsoft Corporation \| Virtual Machine|Hyper-V'
        'QEMU/KVM'   = 'QEMU|KVM|Bochs'
        'Parallels'  = 'Parallels'
        'Xen'        = '\bXen\b'
    }
    foreach ($name in $signatures.Keys) {
        if ($evidence -match $signatures[$name]) {
            $platform = $name
            if ($name -eq 'Hyper-V' -and (Test-IsAzureVM)) {
                # Azure 的 VM 也是 Hyper-V；另外標示，測試報告才分得出本機與雲端環境
                $platform = 'Azure (Hyper-V)'
            }
            return [pscustomobject]@{ Platform = $platform; Evidence = $evidence }
        }
    }
    return [pscustomobject]@{ Platform = $null; Evidence = $evidence }
}

function Test-IsAzureVM {
    <# Azure VM 的機殼資產標籤固定為下列字串；另以 Azure VM 代理程式服務作為備援判斷。 #>
    $azureAssetTag = '7783-7084-3265-9085-8269-3286-77'
    $enclosure = Get-CimInstance -ClassName Win32_SystemEnclosure | Select-Object -First 1
    if ($null -ne $enclosure -and [string]$enclosure.SMBIOSAssetTag -eq $azureAssetTag) {
        return $true
    }
    return $null -ne (Get-Service -Name 'WindowsAzureGuestAgent' -ErrorAction SilentlyContinue)
}

function Get-SnapshotHint {
    param([Parameter(Mandatory = $true)][string]$VMPlatform)
    switch -Regex ($VMPlatform) {
        '^Azure'      { return '在 Azure 停止（解除配置）VM 後，替 OS 磁碟建立快照 clean-baseline（見 docs/VM_SETUP.md 第 3C-7 節）。' }
        '^Hyper-V$'   { return '關機，在 Hyper-V 建立檢查點 clean-baseline（見 docs/VM_SETUP.md 第 3B 節）。' }
        '^VirtualBox' { return '關機，在 VirtualBox 建立快照 clean-baseline（見 docs/VM_SETUP.md 第 7 節）。' }
        default       { return '關機，用你的虛擬化軟體建立快照 clean-baseline（見 docs/VM_SETUP.md）。' }
    }
}

function Initialize-WorkDir {
    if (-not (Test-Path -Path $WorkDir)) {
        $null = New-Item -Path $WorkDir -ItemType Directory -Force
    }
}

function Invoke-NativeCommand {
    <# 執行外部程式；exit code 不是 0 時 throw，並附上輸出內容。 #>
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @()
    )
    $ErrorActionPreference = 'Continue'   # 避免外部程式寫到 stderr 就被當成例外
    $output = & $FilePath @ArgumentList 2>&1 | ForEach-Object { "$_" }
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw ('{0} {1} 失敗（exit code {2}）：{3}' -f $FilePath, ($ArgumentList -join ' '), $exitCode, (($output | Select-Object -Last 5) -join ' '))
    }
    return $output
}

function Test-RegistryDword {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int]$Expected
    )
    if (-not (Test-Path -Path $Path)) { return $false }
    $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $false }
    return ([int]$item.$Name -eq $Expected)
}

function Write-RegistryDword {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int]$Value
    )
    if (-not (Test-Path -Path $Path)) {
        $null = New-Item -Path $Path -Force
    }
    $null = New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force
}

function Get-AuditSettingMap {
    <# 回傳「子類別 GUID → 設定值」對照表（0 = 不稽核、1 = 成功、2 = 失敗、3 = 成功與失敗）。
       用 auditpol /backup 而不是 /get，因為 /get 的文字會依系統語言而不同。 #>
    $file = Join-Path -Path $env:TEMP -ChildPath ('fk-auditpol-{0}.csv' -f [guid]::NewGuid())
    try {
        $null = Invoke-NativeCommand -FilePath 'auditpol.exe' -ArgumentList @('/backup', "/file:$file")
        $map = @{}
        $rows = Get-Content -Path $file | Select-Object -Skip 1 |
            ConvertFrom-Csv -Header 'Machine', 'Target', 'Subcategory', 'Guid', 'Inclusion', 'Exclusion', 'Value'
        foreach ($row in $rows) {
            if ($row.Guid -and ($row.Guid -match '^\{[0-9A-Fa-f-]+\}$')) {
                $value = 0
                [void][int]::TryParse([string]$row.Value, [ref]$value)
                $map[$row.Guid.ToUpperInvariant()] = $value
            }
        }
        return $map
    }
    finally {
        if (Test-Path -Path $file) { Remove-Item -Path $file -Force }
    }
}

function Get-ChannelConfig {
    param([Parameter(Mandatory = $true)][string]$Name)
    try {
        return Get-WinEvent -ListLog $Name -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Get-SysmonService {
    return Get-Service -Name 'Sysmon64', 'Sysmon', 'Sysmon64a' -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Get-SysmonExePath {
    param([Parameter(Mandatory = $true)][string]$ServiceName)
    $svc = Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f $ServiceName)
    if ($null -eq $svc -or -not $svc.PathName) { return $null }
    return $svc.PathName.Trim('"')
}

function Get-LatestModule {
    param([Parameter(Mandatory = $true)][string]$Name)
    return Get-Module -ListAvailable -Name $Name | Sort-Object -Property Version -Descending | Select-Object -First 1
}

function Initialize-Tls12 {
    # PS 5.1 預設可能不用 TLS 1.2，PowerShell Gallery 與 GitHub 都要求 TLS 1.2
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

function Initialize-NuGetProvider {
    $provider = Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue |
        Where-Object { $_.Version -ge [version]'2.8.5.201' } | Select-Object -First 1
    if ($null -eq $provider) {
        $null = Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
    }
}

function Get-GitPath {
    $cmd = Get-Command -Name git.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd) { return $cmd.Path }
    $default = Join-Path -Path $env:ProgramFiles -ChildPath 'Git\cmd\git.exe'
    if (Test-Path -Path $default) { return $default }
    return $null
}

function Get-RepoCommit {
    <# 若腳本是從 git clone 下來的 repo 執行，回傳目前的 commit SHA；否則回傳 $null。 #>
    $git = Get-GitPath
    if ($null -eq $git) { return $null }
    # 腳本位於 <repo>\scripts\vm\；不是從 clone 的 repo 執行（例如單獨下載）就不呼叫 git，避免留下錯誤紀錄
    $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    if (-not $repoRoot -or -not (Test-Path -Path (Join-Path -Path $repoRoot -ChildPath '.git'))) { return $null }
    try {
        $sha = Invoke-NativeCommand -FilePath $git -ArgumentList @('-C', $repoRoot, 'rev-parse', 'HEAD')
        return ([string]($sha | Select-Object -First 1)).Trim()
    }
    catch {
        return $null
    }
}

function Get-OptionalProperty {
    param($InputObject, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $InputObject) { return $null }
    $prop = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Invoke-SetupStep {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Step,
        [switch]$VerifyOnly
    )
    $status = 'Failed'
    $detail = ''
    if ($Step.Skip) {
        $status = 'Skipped'
        $detail = $Step.SkipReason
    }
    else {
        try {
            $before = & $Step.Test
            if ($before.Ok) {
                $status = 'OK'
                $detail = $before.Detail
            }
            elseif ($VerifyOnly) {
                $detail = '未設定：' + $before.Detail
            }
            else {
                Write-Step ('  設定中：{0}' -f $Step.Name) -Color DarkGray
                $null = & $Step.Apply
                $after = & $Step.Test
                if ($after.Ok) {
                    $status = 'OK'
                    $detail = '已設定：' + $after.Detail
                }
                else {
                    $detail = '設定後仍未通過檢查：' + $after.Detail
                }
            }
        }
        catch {
            $detail = $_.Exception.Message
        }
    }

    $color = switch ($status) {
        'OK'      { [ConsoleColor]::Green }
        'Skipped' { [ConsoleColor]::Yellow }
        default   { if ($Step.Required) { [ConsoleColor]::Red } else { [ConsoleColor]::Yellow } }
    }
    Write-Step ('[{0,-7}] {1}：{2}' -f $status, $Step.Name, $detail) -Color $color

    return [pscustomobject]@{
        Step     = $Step.Name
        Status   = $status
        Required = [bool]$Step.Required
        Detail   = $detail
    }
}

function Write-TestVMMarker {
    param([Parameter(Mandatory = $true)][string]$VMPlatform)

    $now     = Get-UtcTimestamp
    $created = $now
    $oldSysmon = $null
    if (Test-Path -Path $MarkerPath) {
        try {
            $old = Get-Content -Path $MarkerPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $oldCreated = Get-OptionalProperty -InputObject $old -Name 'createdUtc'
            if ($oldCreated) { $created = [string]$oldCreated }
            $oldSysmon = Get-OptionalProperty -InputObject $old -Name 'sysmon'
        }
        catch {
            Write-Warning ('既有標記檔無法解析，將重新建立：{0}' -f $_.Exception.Message)
        }
    }

    $sysmonSvc = Get-SysmonService
    $sysmonExe = $null
    $sysmonVersion = $null
    if ($null -ne $sysmonSvc) {
        $sysmonExe = Get-SysmonExePath -ServiceName $sysmonSvc.Name
        if ($sysmonExe -and (Test-Path -Path $sysmonExe)) {
            $sysmonVersion = (Get-Item -Path $sysmonExe).VersionInfo.FileVersion
        }
    }
    $configUrl = Get-OptionalProperty -InputObject $oldSysmon -Name 'configUrl'
    $configSha = Get-OptionalProperty -InputObject $oldSysmon -Name 'configSha256'
    if ($null -ne $script:SysmonInfo) {
        $configUrl = $script:SysmonInfo.configUrl
        $configSha = $script:SysmonInfo.configSha256
    }

    $nt  = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $os  = Get-CimInstance -ClassName Win32_OperatingSystem
    $pester   = Get-LatestModule -Name Pester
    $analyzer = Get-LatestModule -Name PSScriptAnalyzer
    $git      = Get-GitPath
    $gitVersion = $null
    if ($null -ne $git) {
        try { $gitVersion = ([string](Invoke-NativeCommand -FilePath $git -ArgumentList @('--version') | Select-Object -First 1)).Trim() }
        catch { $gitVersion = $null }
    }

    $marker = [ordered]@{
        purpose      = 'ForensiKit 測試 VM 標記檔，由 scripts/vm/Setup-TestVM.ps1 建立。只能存在於測試 VM，不要複製到實體電腦。'
        createdUtc   = $created
        updatedUtc   = $now
        setupScript  = [ordered]@{ version = $ScriptVersion; repoCommit = (Get-RepoCommit) }
        computerName = $env:COMPUTERNAME
        vmPlatform   = $VMPlatform
        os           = [ordered]@{
            caption        = $os.Caption
            version        = $os.Version
            build          = ('{0}.{1}' -f (Get-OptionalProperty -InputObject $nt -Name 'CurrentBuild'), (Get-OptionalProperty -InputObject $nt -Name 'UBR'))
            displayVersion = (Get-OptionalProperty -InputObject $nt -Name 'DisplayVersion')
            uiLanguage     = (Get-UICulture).Name
        }
        timeZone     = (Get-TimeZone).Id
        sysmon       = [ordered]@{
            service      = $(if ($null -ne $sysmonSvc) { $sysmonSvc.Name } else { $null })
            version      = $sysmonVersion
            configUrl    = $configUrl
            configSha256 = $configSha
        }
        modules      = [ordered]@{
            pester           = $(if ($null -ne $pester) { $pester.Version.ToString() } else { $null })
            psScriptAnalyzer = $(if ($null -ne $analyzer) { $analyzer.Version.ToString() } else { $null })
        }
        git          = $gitVersion
    }
    Set-Content -Path $MarkerPath -Value ($marker | ConvertTo-Json -Depth 5) -Encoding UTF8
}

#endregion

#region 設定步驟（每一步：Test 回傳 {Ok, Detail}；Apply 進行設定）

$Steps = @(
    [pscustomobject]@{
        Name = '時區'; Required = $true; Skip = $false; SkipReason = ''
        Test = {
            $id = (Get-TimeZone).Id
            ConvertTo-CheckResult -Ok ($id -eq $TimeZoneId) -Detail $id
        }
        Apply = { Set-TimeZone -Id $TimeZoneId }
    }

    [pscustomobject]@{
        Name = '稽核原則'; Required = $true; Skip = $false; SkipReason = ''
        Test = {
            $map = Get-AuditSettingMap
            $missing = @()
            foreach ($sub in $AuditSubcategories) {
                $value = 0
                if ($map.ContainsKey($sub.Guid)) { $value = $map[$sub.Guid] }
                if (($value -band 3) -ne 3) { $missing += ('{0}（{1}）' -f $sub.Name, $sub.UsedBy) }
            }
            if (-not (Test-RegistryDword -Path $LsaKey -Name 'SCENoApplyLegacyAuditPolicy' -Expected 1)) {
                $missing += 'SCENoApplyLegacyAuditPolicy'
            }
            if ($missing.Count -eq 0) {
                ConvertTo-CheckResult -Ok $true -Detail ('{0} 個子類別皆為「成功與失敗」' -f $AuditSubcategories.Count)
            }
            else {
                ConvertTo-CheckResult -Ok $false -Detail ($missing -join '、')
            }
        }
        Apply = {
            # 讓「子類別」層級的稽核設定優先於舊式類別設定
            Write-RegistryDword -Path $LsaKey -Name 'SCENoApplyLegacyAuditPolicy' -Value 1
            foreach ($sub in $AuditSubcategories) {
                $null = Invoke-NativeCommand -FilePath 'auditpol.exe' -ArgumentList @('/set', ('/subcategory:{0}' -f $sub.Guid), '/success:enable', '/failure:enable')
            }
        }
    }

    [pscustomobject]@{
        Name = '4688 含命令列'; Required = $true; Skip = $false; SkipReason = ''
        Test = {
            $ok = Test-RegistryDword -Path $CmdLineAuditKey -Name 'ProcessCreationIncludeCmdLine_Enabled' -Expected 1
            ConvertTo-CheckResult -Ok $ok -Detail 'ProcessCreationIncludeCmdLine_Enabled = 1'
        }
        Apply = { Write-RegistryDword -Path $CmdLineAuditKey -Name 'ProcessCreationIncludeCmdLine_Enabled' -Value 1 }
    }

    [pscustomobject]@{
        Name = 'Script Block Logging'; Required = $true; Skip = $false; SkipReason = ''
        Test = {
            $ok = Test-RegistryDword -Path $ScriptBlockKey -Name 'EnableScriptBlockLogging' -Expected 1
            ConvertTo-CheckResult -Ok $ok -Detail 'EnableScriptBlockLogging = 1（新開的 PowerShell 才會生效）'
        }
        Apply = { Write-RegistryDword -Path $ScriptBlockKey -Name 'EnableScriptBlockLogging' -Value 1 }
    }

    [pscustomobject]@{
        Name = '事件記錄通道'; Required = $true; Skip = $false; SkipReason = ''
        Test = {
            $disabled = @()
            foreach ($name in $RequiredChannels) {
                $cfg = Get-ChannelConfig -Name $name
                if ($null -eq $cfg -or -not $cfg.IsEnabled) { $disabled += $name }
            }
            if ($disabled.Count -eq 0) {
                ConvertTo-CheckResult -Ok $true -Detail ('{0} 個 Operational 通道已啟用' -f $RequiredChannels.Count)
            }
            else {
                ConvertTo-CheckResult -Ok $false -Detail ('未啟用：' + ($disabled -join '、'))
            }
        }
        Apply = {
            foreach ($name in $RequiredChannels) {
                $cfg = New-Object -TypeName System.Diagnostics.Eventing.Reader.EventLogConfiguration -ArgumentList $name
                if (-not $cfg.IsEnabled) {
                    $cfg.IsEnabled = $true
                    $cfg.SaveChanges()
                }
            }
        }
    }

    [pscustomobject]@{
        Name = 'Sysmon'; Required = $true; Skip = $false; SkipReason = ''
        Test = {
            $svc = Get-SysmonService
            if ($null -eq $svc) { return (ConvertTo-CheckResult -Ok $false -Detail '未安裝') }
            $exe = Get-SysmonExePath -ServiceName $svc.Name
            $version = '未知'
            if ($exe -and (Test-Path -Path $exe)) { $version = (Get-Item -Path $exe).VersionInfo.FileVersion }
            $log = Get-ChannelConfig -Name 'Microsoft-Windows-Sysmon/Operational'
            $ok = ($svc.Status -eq 'Running') -and ($null -ne $log) -and $log.IsEnabled
            ConvertTo-CheckResult -Ok $ok -Detail ('服務 {0}（{1}），版本 {2}' -f $svc.Name, $svc.Status, $version)
        }
        Apply = {
            Initialize-WorkDir
            $zip     = Join-Path -Path $WorkDir -ChildPath 'Sysmon.zip'
            $extract = Join-Path -Path $WorkDir -ChildPath 'Sysmon'
            $config  = Join-Path -Path $WorkDir -ChildPath 'sysmonconfig-export.xml'

            Invoke-WebRequest -Uri $SysmonZipUrl -OutFile $zip -UseBasicParsing
            Invoke-WebRequest -Uri $SysmonConfigUrl -OutFile $config -UseBasicParsing
            try {
                $null = [xml](Get-Content -Path $config -Raw -Encoding UTF8)
            }
            catch {
                throw ('Sysmon 設定檔不是有效的 XML，請確認網址：{0}' -f $SysmonConfigUrl)
            }

            if (Test-Path -Path $extract) { Remove-Item -Path $extract -Recurse -Force }
            Expand-Archive -Path $zip -DestinationPath $extract -Force

            $exeName = switch ($env:PROCESSOR_ARCHITECTURE) {
                'AMD64' { 'Sysmon64.exe' }
                'ARM64' { 'Sysmon64a.exe' }
                default { 'Sysmon.exe' }
            }
            $exe = Join-Path -Path $extract -ChildPath $exeName
            if (-not (Test-Path -Path $exe)) { throw ('解壓縮後找不到 {0}' -f $exeName) }

            # 只執行有 Microsoft 有效數位簽章的 Sysmon
            $sig = Get-AuthenticodeSignature -FilePath $exe
            if ($sig.Status -ne 'Valid' -or $null -eq $sig.SignerCertificate -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
                throw ('{0} 的數位簽章驗證失敗（{1}），停止安裝' -f $exeName, $sig.Status)
            }

            $existing = Get-SysmonService
            if ($null -ne $existing) {
                # 已安裝但沒在執行：更新設定並啟動
                $installedExe = Get-SysmonExePath -ServiceName $existing.Name
                $null = Invoke-NativeCommand -FilePath $installedExe -ArgumentList @('-accepteula', '-c', $config)
                Start-Service -Name $existing.Name
            }
            else {
                $null = Invoke-NativeCommand -FilePath $exe -ArgumentList @('-accepteula', '-i', $config)
            }

            $script:SysmonInfo = [ordered]@{
                configUrl    = $SysmonConfigUrl
                configSha256 = (Get-FileHash -Path $config -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
    }

    [pscustomobject]@{
        Name = 'Pester 5'; Required = $true; Skip = $false; SkipReason = ''
        Test = {
            $m = Get-LatestModule -Name Pester
            if ($null -eq $m) { return (ConvertTo-CheckResult -Ok $false -Detail '未安裝') }
            ConvertTo-CheckResult -Ok ($m.Version.Major -eq 5) -Detail ('最新可用版本 {0}' -f $m.Version)
        }
        Apply = {
            Initialize-NuGetProvider
            Install-Module -Name Pester -MinimumVersion 5.0.0 -MaximumVersion 5.99.99 -Scope CurrentUser -Force -SkipPublisherCheck
        }
    }

    [pscustomobject]@{
        Name = 'PSScriptAnalyzer'; Required = $true; Skip = $false; SkipReason = ''
        Test = {
            $m = Get-LatestModule -Name PSScriptAnalyzer
            if ($null -eq $m) { return (ConvertTo-CheckResult -Ok $false -Detail '未安裝') }
            ConvertTo-CheckResult -Ok $true -Detail ('版本 {0}' -f $m.Version)
        }
        Apply = {
            Initialize-NuGetProvider
            Install-Module -Name PSScriptAnalyzer -MaximumVersion 1.99.99 -Scope CurrentUser -Force
        }
    }

    [pscustomobject]@{
        Name = 'Git'; Required = $false; Skip = [bool]$SkipGit; SkipReason = '使用 -SkipGit 略過'
        Test = {
            $git = Get-GitPath
            if ($null -eq $git) { return (ConvertTo-CheckResult -Ok $false -Detail '未安裝') }
            $version = ([string](Invoke-NativeCommand -FilePath $git -ArgumentList @('--version') | Select-Object -First 1)).Trim()
            ConvertTo-CheckResult -Ok $true -Detail $version
        }
        Apply = {
            $winget = Get-Command -Name winget.exe -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -eq $winget) {
                throw '找不到 winget。請到 https://git-scm.com/download/win 手動安裝 Git，或先到 Microsoft Store 更新「應用程式安裝程式」後重跑。'
            }
            $null = Invoke-NativeCommand -FilePath $winget.Path -ArgumentList @(
                'install', '--id', 'Git.Git', '--exact', '--source', 'winget', '--silent',
                '--accept-package-agreements', '--accept-source-agreements')
        }
    }
)

#endregion

#region 主流程

# ---- 前置檢查：任何一項不符就停止，不做任何修改 ----
if (-not (Test-IsAdministrator)) {
    throw '請以「系統管理員身分」開啟 Windows PowerShell 後再執行。'
}
if ($PSVersionTable.PSEdition -ne 'Desktop') {
    throw '請用 Windows PowerShell 5.1（powershell.exe）執行，不要用 PowerShell 7（pwsh.exe）。'
}
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    throw '請用 64 位元的 Windows PowerShell 執行（不要用 Windows PowerShell (x86)）。'
}
$osInfo = Get-CimInstance -ClassName Win32_OperatingSystem
if ($osInfo.ProductType -ne 1 -or -not $osInfo.Version.StartsWith('10.')) {
    throw ('只支援 Windows 10/11 用戶端版本，目前是：{0} {1}' -f $osInfo.Caption, $osInfo.Version)
}
$vm = Get-VMPlatform
if ($null -eq $vm.Platform) {
    $message = "偵測不到虛擬機器，拒絕執行。本腳本只能在測試 VM 內執行（docs/TEST_PLAN.md 安全規則第 1 條）。`n" +
               ("硬體資訊：{0}`n如果你確定這是 VM，請把上面這行硬體資訊貼到 T02 Issue。" -f $vm.Evidence)
    throw $message
}

Initialize-Tls12

$mode = if ($VerifyOnly) { '只檢查（-VerifyOnly）' } else { '設定' }
Write-Step ''
Write-Step ('ForensiKit 測試 VM 建置腳本 v{0}' -f $ScriptVersion) -Color Cyan
Write-Step ('  模式：{0}　平台：{1}　系統：{2} {3}' -f $mode, $vm.Platform, $osInfo.Caption, $osInfo.Version) -Color Cyan
Write-Step ''

$results = @()
foreach ($step in $Steps) {
    $results += Invoke-SetupStep -Step $step -VerifyOnly:$VerifyOnly
}

# ---- 標記檔：只有必要步驟全部通過才建立 ----
$requiredFailed = @($results | Where-Object { $_.Required -and $_.Status -ne 'OK' })
$markerStep = [pscustomobject]@{ Step = '標記檔'; Status = 'Failed'; Required = $true; Detail = '' }
if ($VerifyOnly) {
    if (Test-Path -Path $MarkerPath) {
        $markerStep.Status = 'OK'
        $markerStep.Detail = $MarkerPath
    }
    else {
        $markerStep.Detail = '不存在：' + $MarkerPath
    }
}
elseif ($requiredFailed.Count -gt 0) {
    $markerStep.Status = 'Skipped'
    $markerStep.Detail = ('有 {0} 個必要步驟未通過，不建立標記檔' -f $requiredFailed.Count)
}
else {
    try {
        Write-TestVMMarker -VMPlatform $vm.Platform
        $markerStep.Status = 'OK'
        $markerStep.Detail = '已寫入 ' + $MarkerPath
    }
    catch {
        $markerStep.Detail = $_.Exception.Message
    }
}
$markerColor = if ($markerStep.Status -eq 'OK') { [ConsoleColor]::Green } else { [ConsoleColor]::Red }
Write-Step ('[{0,-7}] {1}：{2}' -f $markerStep.Status, $markerStep.Step, $markerStep.Detail) -Color $markerColor
$results += $markerStep

# ---- 結果摘要 ----
$allOk = @($results | Where-Object { $_.Required -and $_.Status -ne 'OK' }).Count -eq 0
Write-Step ''
Write-Step (($results | Format-Table -Property Step, Status, Required, Detail -AutoSize -Wrap | Out-String -Width 160).TrimEnd())
Write-Step ''
if ($allOk -and $VerifyOnly) {
    Write-Step '這台 VM 符合 ForensiKit 測試環境規格。' -Color Green
}
elseif ($allOk) {
    Write-Step '設定完成。接下來：' -Color Green
    Write-Step '  1. 重新開機一次，讓所有設定在新的工作階段生效。'
    Write-Step '  2. 開機後以系統管理員身分再跑一次：.\Setup-TestVM.ps1 -VerifyOnly，確認全部 OK。'
    Write-Step ('  3. {0}' -f (Get-SnapshotHint -VMPlatform $vm.Platform))
}
else {
    Write-Step '有必要步驟未通過。請依上表的訊息處理後重跑本腳本；仍無法解決請把上表貼到 T02 Issue。' -Color Red
}

if ($PassThru) { $results }
# 一定要明確 exit：否則腳本的 exit code 會沿用最後一個外部程式（例如 git）的 $LASTEXITCODE
if ($allOk) { exit 0 } else { exit 1 }

#endregion

<#
.SYNOPSIS
    ForensiKit 單元測試共用輔助函式（T11）。

.DESCRIPTION
    每個 *.Tests.ps1 在 BeforeDiscovery 與 BeforeAll 都要 dot-source 本檔：

        BeforeDiscovery { . "$PSScriptRoot/_TestHelpers.ps1"; $skip = -not (Test-FKCommandAvailable 'Export-FKEventLog') }
        BeforeAll       { . "$PSScriptRoot/_TestHelpers.ps1"; Import-FKModuleUnderTest | Out-Null }

    設計原則：
    - 測試依 docs/ARCHITECTURE.md 的契約撰寫，不依賴實作細節；實作尚未合併時，
      Test-FKCommandAvailable 回傳 $false，整個 Describe 以 -Skip 略過，實作合併後自動啟用。
    - 單元測試不得碰觸真實系統（事件記錄、排程、ACL、登錄檔）。所有外部指令都以 Mock 取代，
      檔案只寫在 Pester 的 TestDrive。真正的蒐證只在 VM 的 E2E（T12）中執行。
    - 可用環境變數 FK_MODULE_PATH 指定要測試的模組 .psd1（例如測試別的分支），未設定時用
      src/ForensiKit/ForensiKit.psd1。
#>

Set-StrictMode -Version 2.0

$script:FKRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$script:FKStatusValues = @('OK', 'Partial', 'Failed', 'Skipped')
$script:FKArtifactNames = @('Prefetch', 'ScheduledTasks', 'Services', 'Autoruns', 'Processes', 'NetworkConnections', 'DnsCache')

function Get-FKModulePath {
    <#
    .SYNOPSIS
        回傳受測模組 manifest 的路徑（可用 $env:FK_MODULE_PATH 覆寫）。
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ($env:FK_MODULE_PATH) { return $env:FK_MODULE_PATH }
    return (Join-Path $script:FKRepoRoot 'src\ForensiKit\ForensiKit.psd1')
}

function Import-FKModuleUnderTest {
    <#
    .SYNOPSIS
        匯入受測模組；模組不存在時回傳 $false，不丟出錯誤。
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $path = Get-FKModulePath
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    Import-Module $path -Force -ErrorAction Stop
    return $true
}

function Test-FKCommandAvailable {
    <#
    .SYNOPSIS
        受測模組存在且匯出指定函式時回傳 $true。用於 Describe 的 -Skip 條件。
    .PARAMETER Name
        一個或多個公開函式名稱；全部存在才回傳 $true。
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string[]]$Name
    )

    if (-not (Import-FKModuleUnderTest)) { return $false }
    foreach ($n in $Name) {
        $cmd = Get-Command -Name $n -Module ForensiKit -ErrorAction SilentlyContinue
        if (-not $cmd) { return $false }
    }
    return $true
}

function Test-FKModuleCommand {
    <#
    .SYNOPSIS
        在受測模組內部查詢函式是否存在（含 Private 函式，例如 Assert-FKAdmin）。
        用來決定能不能 Mock 該函式。
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$Name)

    $mod = Get-Module -Name ForensiKit
    if (-not $mod) { return $false }
    return [bool](& $mod { param($n) Get-Command -Name $n -CommandType Function -ErrorAction SilentlyContinue } $Name)
}

function New-FKUtcDate {
    <#
    .SYNOPSIS
        建立 Kind = Utc 的 [datetime]，避免測試受本機時區影響。
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param(
        [Parameter(Mandatory)][int]$Year,
        [Parameter(Mandatory)][int]$Month,
        [Parameter(Mandatory)][int]$Day,
        [int]$Hour = 0,
        [int]$Minute = 0,
        [int]$Second = 0
    )

    return New-Object datetime -ArgumentList $Year, $Month, $Day, $Hour, $Minute, $Second, ([DateTimeKind]::Utc)
}

function ConvertTo-FKIsoUtc {
    <#
    .SYNOPSIS
        依契約第 3 節把 UTC 時間轉成 ISO 8601 字串（例如 2026-11-20T03:15:00Z）。
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][datetime]$Date)

    return $Date.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-FKChannelFileName {
    <#
    .SYNOPSIS
        依契約第 4 節把 channel 名稱轉成檔名：/ 改為 %4（與 Windows winevt\Logs 相同）。
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Channel)

    return ($Channel -replace '/', '%4')
}

function Get-FKTestSha256 {
    <#
    .SYNOPSIS
        獨立於受測模組的 SHA-256 參考實作（小寫十六進位）。
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $bytes = $sha.ComputeHash($stream)
    }
    finally {
        $stream.Dispose()
        $sha.Dispose()
    }
    return (-join ($bytes | ForEach-Object { $_.ToString('x2') }))
}

function Write-FKTestFile {
    <#
    .SYNOPSIS
        在證據包根目錄下以相對路徑（/ 分隔）寫入一個 UTF-8 檔案，必要時建立資料夾。
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )

    $full = Join-Path $Root ($RelativePath -replace '/', '\')
    $dir = Split-Path -Parent $full
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($full, $Content, (New-Object System.Text.UTF8Encoding($false)))
    return $full
}

function New-FKTestPackage {
    <#
    .SYNOPSIS
        在指定路徑建立一個假證據包，並依契約第 4 節格式寫出 manifest.json（不經過受測模組）。
    .DESCRIPTION
        用來測試 Test-FKPackage 等「讀取證據包」的函式，讓它們不必等 New-FKManifest 實作完成。
        回傳 { Root, ManifestPath, Files }，Files 為 manifest 中的相對路徑清單。
    .PARAMETER Root
        證據包根目錄（建議放在 $TestDrive 之下）。
    .PARAMETER Files
        hashtable：相對路徑（/ 分隔）→ 檔案內容。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [hashtable]$Files = @{
            'evtx/live/Security.evtx'                              = 'fake-security-evtx'
            'evtx/live/Microsoft-Windows-Sysmon%4Operational.evtx' = 'fake-sysmon-evtx'
            'artifacts/processes.json'                             = '[{"Name":"explorer.exe"}]'
            'action_log.jsonl'                                     = '{"timeUtc":"2026-11-21T02:03:04Z","action":"Test","target":"x","detail":"y","status":"OK"}'
        }
    )

    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    $entries = @()
    foreach ($rel in ($Files.Keys | Sort-Object)) {
        $full = Write-FKTestFile -Root $Root -RelativePath $rel -Content $Files[$rel]
        $entries += [ordered]@{
            path      = $rel
            sha256    = Get-FKTestSha256 -Path $full
            size      = (Get-Item -LiteralPath $full).Length
            source    = 'test'
            collector = 'New-FKTestPackage'
            status    = 'OK'
        }
    }

    $manifest = [ordered]@{
        schemaVersion  = '1.0'
        tool           = [ordered]@{ name = 'ForensiKit'; version = '0.0.0-test' }
        case           = [ordered]@{ caseId = 'TEST-001'; operator = '測試員' }
        host           = [ordered]@{ computerName = 'UNIT-TEST'; osVersion = '10.0.0'; timeZone = 'Taipei Standard Time' }
        timeRange      = [ordered]@{ startUtc = '2026-11-20T00:00:00Z'; endUtc = '2026-11-21T00:00:00Z' }
        collectedAtUtc = '2026-11-21T02:03:04Z'
        files          = $entries
    }
    $manifestPath = Join-Path $Root 'manifest.json'
    $json = ConvertTo-Json -InputObject $manifest -Depth 6
    [System.IO.File]::WriteAllText($manifestPath, $json, (New-Object System.Text.UTF8Encoding($false)))

    return [pscustomobject]@{
        Root         = $Root
        ManifestPath = $manifestPath
        Files        = @($Files.Keys | Sort-Object)
    }
}

function Invoke-FKFlipByte {
    <#
    .SYNOPSIS
        把檔案中指定位置的一個位元組反相（AC6 的竄改測試用）。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$Offset = 0
    )

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($Offset -lt 0) { $Offset = $bytes.Length + $Offset }
    $bytes[$Offset] = $bytes[$Offset] -bxor 0xFF
    [System.IO.File]::WriteAllBytes($Path, $bytes)
}

function New-FKTestSecureString {
    <#
    .SYNOPSIS
        產生只存在記憶體中的測試用 SecureString（不寫進任何檔案）。
    .PARAMETER Text
        指定內容；未指定時產生 24 字元的隨機字串。
    #>
    [CmdletBinding()]
    [OutputType([System.Security.SecureString])]
    param([string]$Text)

    if (-not $Text) {
        $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789'.ToCharArray()
        $rng = New-Object System.Random
        $Text = -join (1..24 | ForEach-Object { $chars[$rng.Next($chars.Length)] })
    }
    $secure = New-Object System.Security.SecureString
    foreach ($c in $Text.ToCharArray()) { $secure.AppendChar($c) }
    $secure.MakeReadOnly()
    return $secure
}

function New-FKTestConfig {
    <#
    .SYNOPSIS
        建立符合契約第 6 節結構的設定物件，供 Mock Get-FKConfig 使用。
    #>
    [CmdletBinding()]
    param(
        [string[]]$Channels = @('Security', 'Microsoft-Windows-Sysmon/Operational'),
        [string]$VaultRoot = 'C:\ProgramData\ForensiKit\vault'
    )

    return [pscustomobject]@{
        channels            = $Channels
        defaultLookbackDays = 7
        preservation        = [pscustomobject]@{
            logMaxSizeMB         = [pscustomobject]@{ Security = 512; default = 128 }
            vaultRoot            = $VaultRoot
            vaultIntervalMinutes = 60
            vaultMaxTotalMB      = 2048
        }
    }
}

function Get-FKParameterInfo {
    <#
    .SYNOPSIS
        取得指定函式某個參數的 { Exists, Mandatory, TypeName }，用於契約參數測試。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string]$Parameter
    )

    $cmd = Get-Command -Name $Command -Module ForensiKit -ErrorAction Stop
    if (-not $cmd.Parameters.ContainsKey($Parameter)) {
        return [pscustomobject]@{ Exists = $false; Mandatory = $false; TypeName = $null }
    }
    $p = $cmd.Parameters[$Parameter]
    $mandatory = [bool]($p.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory })
    return [pscustomobject]@{ Exists = $true; Mandatory = $mandatory; TypeName = $p.ParameterType.FullName }
}

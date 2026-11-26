function New-FKManifest {
    <#
    .SYNOPSIS
        為證據包產生 manifest.json（所有檔案的 SHA-256）與監管鏈表單 chain_of_custody.txt。

    .DESCRIPTION
        依 docs/ARCHITECTURE.md 第 4 節的格式，列出證據包根目錄下所有檔案的相對路徑（/ 分隔）、SHA-256（小寫十六進位）與大小，
        寫成 <PackageRoot>\manifest.json（UTF-8 無 BOM）。接著計算 manifest.json 本身的 SHA-256，
        連同案號、操作者、電腦名稱、時段（UTC 與台灣時間 +08:00 並列）、收集時間、工具版本寫進
        <PackageRoot>\chain_of_custody.txt（含移交紀錄空白欄，TASKS.md T07）。

        不列入 files 的檔案：manifest.json（雜湊寫在 chain_of_custody.txt）與 chain_of_custody.txt（內含 manifest 雜湊，無法反過來列入）。
        action_log.jsonl 會列入，所以呼叫本函式之後不可再寫 action log（Invoke-ForensiKit 會在本函式之後立刻 Close-FKActionLog）。
        本函式自己的 action log（CreateManifest）在計算雜湊之前寫入。

        files 的 source 與 collector 依路徑推得（evtx/live、evtx/vault → Export-FKEventLog；artifacts → Get-FKArtifact；
        action_log.jsonl → Write-FKAction），status 為 OK；單一檔案無法讀取時 sha256 為 null、status 為 Failed，不中斷（契約第 3 節）。

    .PARAMETER PackageRoot
        證據包根目錄（必須已存在）。

    .PARAMETER CaseId
        案號。

    .PARAMETER Operator
        操作者姓名。

    .PARAMETER StartUtc
        蒐證時段起點（UTC）。Kind = Local 的時間會先轉成 UTC；Kind = Unspecified 視為 UTC。

    .PARAMETER EndUtc
        蒐證時段終點（UTC）。

    .OUTPUTS
        [pscustomobject] @{ ManifestPath; ManifestSha256; FileCount }

    .EXAMPLE
        $m = New-FKManifest -PackageRoot $pkg -CaseId '2026-001' -Operator '王小明' -StartUtc $start -EndUtc $end
        $m.ManifestSha256   # 請操作者抄寫到監管鏈表單
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$PackageRoot,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CaseId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Operator,

        [Parameter(Mandatory)]
        [datetime]$StartUtc,

        [Parameter(Mandatory)]
        [datetime]$EndUtc
    )

    function ConvertTo-FKUtcKind {
        param([datetime]$Date)
        if ($Date.Kind -eq [System.DateTimeKind]::Local) { return $Date.ToUniversalTime() }
        return [datetime]::SpecifyKind($Date, [System.DateTimeKind]::Utc)
    }

    function Get-FKFileSha256 {
        # 小寫十六進位；不用 Get-FileHash 以避免路徑中的萬用字元問題
        param([string]$Path)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $bytes = $sha.ComputeHash($stream)
        }
        finally {
            $stream.Dispose()
            $sha.Dispose()
        }
        return (-join ($bytes | ForEach-Object { $_.ToString('x2') }))
    }

    function Get-FKFileOrigin {
        # 依相對路徑推得 source 與 collector
        param([string]$RelativePath)
        $parts = $RelativePath.Split('/')
        if ($parts.Count -ge 3 -and $parts[0] -eq 'evtx' -and $parts[1] -eq 'live') {
            return @([System.IO.Path]::GetFileNameWithoutExtension($parts[2]).Replace('%4', '/'), 'Export-FKEventLog')
        }
        if ($parts.Count -ge 4 -and $parts[0] -eq 'evtx' -and $parts[1] -eq 'vault') {
            return @($parts[2].Replace('%4', '/'), 'Export-FKEventLog')
        }
        if ($parts[0] -eq 'artifacts') {
            if ($parts.Count -ge 3) { return @($parts[1], 'Get-FKArtifact') }
            return @([System.IO.Path]::GetFileNameWithoutExtension($parts[1]), 'Get-FKArtifact')
        }
        if ($RelativePath -eq 'action_log.jsonl') { return @('ActionLog', 'Write-FKAction') }
        return @($null, $null)
    }

    if (-not (Test-Path -LiteralPath $PackageRoot -PathType Container)) {
        throw "證據包目錄不存在：$PackageRoot"
    }
    $root = (Resolve-Path -LiteralPath $PackageRoot).ProviderPath.TrimEnd('\')
    $StartUtc = ConvertTo-FKUtcKind -Date $StartUtc
    $EndUtc = ConvertTo-FKUtcKind -Date $EndUtc

    $manifestPath = Join-Path $root 'manifest.json'
    $cocPath = Join-Path $root 'chain_of_custody.txt'
    $excluded = @('manifest.json', 'chain_of_custody.txt')
    if (-not $PSCmdlet.ShouldProcess($root, '寫入 manifest.json 與 chain_of_custody.txt')) { return }

    # action log 必須在雜湊之前寫，否則 action_log.jsonl 的雜湊會對不上
    Write-FKAction -Action 'CreateManifest' -Target $root -Detail '計算證據包內所有檔案的 SHA-256，寫入 manifest.json 與 chain_of_custody.txt' -Status 'OK'
    $all = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue |
            ForEach-Object { [pscustomobject]@{ Item = $_; Rel = $_.FullName.Substring($root.Length + 1).Replace('\', '/') } } |
            Where-Object { $excluded -notcontains $_.Rel } |
            Sort-Object -Property Rel -CaseSensitive)

    $files = New-Object System.Collections.Generic.List[object]
    foreach ($f in $all) {
        $origin = Get-FKFileOrigin -RelativePath $f.Rel
        $hash = $null
        $status = 'OK'
        try {
            $hash = Get-FKFileSha256 -Path $f.Item.FullName
        }
        catch {
            $status = 'Failed'
            Write-Warning ("無法計算 {0} 的 SHA-256：{1}" -f $f.Rel, $_.Exception.Message)
        }
        $files.Add([ordered]@{
                path      = $f.Rel
                sha256    = $hash
                size      = [long]$f.Item.Length
                source    = $origin[0]
                collector = $origin[1]
                status    = $status
            })
    }

    $version = '0.1.0'
    if ($MyInvocation.MyCommand.Module -and $MyInvocation.MyCommand.Module.Version) { $version = $MyInvocation.MyCommand.Module.Version.ToString() }
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    $osVersion = $null
    if ($os) { $osVersion = [string]$os.Version }
    $collectedAt = [datetime]::UtcNow

    $manifest = [ordered]@{
        schemaVersion  = '1.0'
        tool           = [ordered]@{ name = 'ForensiKit'; version = $version }
        case           = [ordered]@{ caseId = $CaseId; operator = $Operator }
        host           = [ordered]@{ computerName = $env:COMPUTERNAME; osVersion = $osVersion; timeZone = [System.TimeZoneInfo]::Local.Id }
        timeRange      = [ordered]@{ startUtc = (ConvertTo-FKIsoUtc -Date $StartUtc); endUtc = (ConvertTo-FKIsoUtc -Date $EndUtc) }
        collectedAtUtc = (ConvertTo-FKIsoUtc -Date $collectedAt)
        files          = @($files.ToArray())
    }
    $json = ConvertTo-Json -InputObject $manifest -Depth 6
    [System.IO.File]::WriteAllText($manifestPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    $manifestSha = Get-FKFileSha256 -Path $manifestPath

    # 監管鏈表單：台灣不實施夏令時間，+08:00 固定
    $tw = { param([datetime]$d) $d.AddHours(8).ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture) + ' (+08:00)' }
    $lines = @(
        'ForensiKit 監管鏈紀錄（Chain of Custody）'
        '================================================'
        ''
        ('案號：{0}' -f $CaseId)
        ('操作者：{0}' -f $Operator)
        ('電腦名稱：{0}' -f $env:COMPUTERNAME)
        ('證據包：{0}' -f (Split-Path -Leaf $root))
        ''
        ('蒐證時段（UTC）：{0} ～ {1}' -f (ConvertTo-FKIsoUtc -Date $StartUtc), (ConvertTo-FKIsoUtc -Date $EndUtc))
        ('蒐證時段（台灣時間）：{0} ～ {1}' -f (& $tw $StartUtc), (& $tw $EndUtc))
        ('收集時間（UTC）：{0}' -f (ConvertTo-FKIsoUtc -Date $collectedAt))
        ('收集時間（台灣時間）：{0}' -f (& $tw $collectedAt))
        ('工具版本：ForensiKit {0}' -f $version)
        ''
        ('manifest.json SHA-256：{0}' -f $manifestSha)
        ('列入 manifest 的檔案數：{0}' -f $files.Count)
        ''
        '驗證方式：接收方以 Get-FileHash -Algorithm SHA256 計算 manifest.json，結果應與上方相同；'
        '          再以 Test-FKPackage -PackageRoot <證據包目錄> 驗證每個檔案的雜湊。'
        ''
        '移交紀錄'
        '------------------------------------------------'
        '序 | 交付人 | 接收人 | 時間 | 簽名'
        '1  |        |        |      |'
        '2  |        |        |      |'
        '3  |        |        |      |'
    )
    [System.IO.File]::WriteAllText($cocPath, (($lines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($true)))

    return [pscustomobject]@{
        ManifestPath   = $manifestPath
        ManifestSha256 = $manifestSha
        FileCount      = $files.Count
    }
}

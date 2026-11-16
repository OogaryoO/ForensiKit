function Open-FKActionLog {
    <#
    .SYNOPSIS
        指定「目前證據包」，之後的 Write-FKAction 會附加到 <PackageRoot>\action_log.jsonl。

    .DESCRIPTION
        由 Invoke-ForensiKit 建立證據包目錄後呼叫。檔案已存在時沿用並附加，不會清空。
        回傳 action log 的完整路徑。

    .PARAMETER PackageRoot
        證據包根目錄（必須已存在）。

    .EXAMPLE
        Open-FKActionLog -PackageRoot 'E:\FK_2026-001_WIN11-TEST_20261121T020304Z'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$PackageRoot
    )

    if (-not (Test-Path -LiteralPath $PackageRoot -PathType Container)) {
        throw "證據包目錄不存在：$PackageRoot"
    }
    $root = (Resolve-Path -LiteralPath $PackageRoot).ProviderPath
    $logPath = Join-Path $root 'action_log.jsonl'
    if (-not (Test-Path -LiteralPath $logPath)) {
        [System.IO.File]::WriteAllText($logPath, '', (New-Object System.Text.UTF8Encoding($false)))
    }
    $script:FKActionLogPath = $logPath
    return $logPath
}

function Close-FKActionLog {
    <#
    .SYNOPSIS
        結束目前證據包的 action log；之後的 Write-FKAction 不再寫檔。

    .EXAMPLE
        Close-FKActionLog
    #>
    [CmdletBinding()]
    param()

    $script:FKActionLogPath = $null
}

function Get-FKActionLogPath {
    <#
    .SYNOPSIS
        回傳目前證據包的 action log 路徑；尚未 Open-FKActionLog 時回傳 $null。

    .EXAMPLE
        Get-FKActionLogPath
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return $script:FKActionLogPath
}

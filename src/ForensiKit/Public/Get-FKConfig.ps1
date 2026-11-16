function Get-FKConfig {
    <#
    .SYNOPSIS
        讀取 ForensiKit 設定檔並回傳設定物件。

    .DESCRIPTION
        不帶 -Path 時讀取模組內建的 config/default-profile.json。
        設定檔可為有 BOM 或無 BOM 的 UTF-8。結構見 docs/ARCHITECTURE.md 第 6 節；
        檔案不存在、不是合法 JSON 或缺少必要欄位時 throw（屬參數錯誤）。

    .PARAMETER Path
        設定檔路徑。省略時使用模組內建的預設設定。

    .EXAMPLE
        $cfg = Get-FKConfig
        $cfg.channels

    .EXAMPLE
        Get-FKConfig -Path 'D:\FK\hospital-profile.json'
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if (-not $PSBoundParameters.ContainsKey('Path')) {
        $Path = Join-Path $script:FKModuleRoot 'config\default-profile.json'
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "找不到設定檔：$Path"
    }
    $fullPath = (Resolve-Path -LiteralPath $Path).ProviderPath

    # Encoding.UTF8 讀取時會自動略過 BOM，有無 BOM 都能讀
    $text = [System.IO.File]::ReadAllText($fullPath, [System.Text.Encoding]::UTF8)
    try {
        $config = $text | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "設定檔不是合法的 JSON（$fullPath）：$($_.Exception.Message)"
    }

    $missing = New-Object System.Collections.Generic.List[string]
    if (-not $config) { $missing.Add('(整個檔案)') }
    else {
        $names = @($config.PSObject.Properties.Name)
        if ($names -notcontains 'channels' -or @($config.channels).Count -eq 0) { $missing.Add('channels') }
        if ($names -notcontains 'defaultLookbackDays') { $missing.Add('defaultLookbackDays') }
        if ($names -notcontains 'preservation' -or -not $config.preservation) { $missing.Add('preservation') }
        else {
            $pNames = @($config.preservation.PSObject.Properties.Name)
            foreach ($key in 'logMaxSizeMB', 'vaultRoot', 'vaultIntervalMinutes', 'vaultMaxTotalMB') {
                if ($pNames -notcontains $key) { $missing.Add("preservation.$key") }
            }
        }
    }
    if ($missing.Count -gt 0) {
        throw "設定檔缺少必要欄位（$fullPath）：$($missing -join ', ')"
    }

    return $config
}

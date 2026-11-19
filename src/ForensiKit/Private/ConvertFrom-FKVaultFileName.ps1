function ConvertFrom-FKVaultFileName {
    <#
    .SYNOPSIS
        把 vault 備份檔名 yyyyMMddTHHmmssZ.evtx 轉成 Kind = Utc 的 [datetime]；格式不符時回傳 $null。

    .DESCRIPTION
        檔名時間是該次備份「開始」的 UTC 時間，備份檔可能含比它稍晚的事件
        （docs/ARCHITECTURE.md 第 5 節）。依此時間判斷是否略過某份備份時要保留安全邊界。

    .PARAMETER Name
        檔名（含或不含 .evtx，也可以是完整路徑）。

    .EXAMPLE
        ConvertFrom-FKVaultFileName -Name '20261120T031500Z.evtx'
        # 2026-11-20 03:15:00（Kind = Utc）
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $base = [System.IO.Path]::GetFileNameWithoutExtension($Name)
    $parsed = [datetime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]'AssumeUniversal, AdjustToUniversal'
    if ([datetime]::TryParseExact($base, "yyyyMMdd'T'HHmmss'Z'", [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
        return $parsed
    }
    return $null
}

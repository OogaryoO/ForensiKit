function ConvertTo-FKIsoUtc {
    <#
    .SYNOPSIS
        把時間轉成契約第 3 節的 ISO 8601 UTC 字串，例如 2026-11-20T03:15:00Z。

    .DESCRIPTION
        Kind = Local 的時間會先轉成 UTC；Kind = Unspecified 視為 UTC（不做時區換算）。

    .PARAMETER Date
        要轉換的時間。

    .EXAMPLE
        ConvertTo-FKIsoUtc -Date ([datetime]::UtcNow)
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [datetime]$Date
    )

    if ($Date.Kind -eq [System.DateTimeKind]::Local) {
        $Date = $Date.ToUniversalTime()
    }
    return $Date.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-FKSafeChannelName {
    <#
    .SYNOPSIS
        把事件記錄 channel 名稱轉成可當檔名／目錄名的安全名稱（/ 改為 %4，與 Windows winevt\Logs 相同）。

    .DESCRIPTION
        用於 evtx/live/<Channel>.evtx、evtx/vault/<Channel>/ 與 vault 目錄（docs/ARCHITECTURE.md 第 4、5 節）。

    .PARAMETER Channel
        channel 名稱，例如 Microsoft-Windows-Sysmon/Operational。

    .EXAMPLE
        ConvertTo-FKSafeChannelName -Channel 'Microsoft-Windows-Sysmon/Operational'
        # Microsoft-Windows-Sysmon%4Operational
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Channel
    )

    return $Channel.Replace('/', '%4')
}

function Get-FKLogMaxSize {
    <#
    .SYNOPSIS
        回傳事件記錄 channel 目前的大小上限（bytes）；channel 不存在時回傳 $null。

    .PARAMETER Channel
        channel 名稱，例如 Security、Microsoft-Windows-Sysmon/Operational。

    .EXAMPLE
        Get-FKLogMaxSize -Channel 'Security'
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Channel
    )

    try {
        $log = Get-WinEvent -ListLog $Channel -ErrorAction Stop
        return [long]$log.MaximumSizeInBytes
    }
    catch {
        return $null
    }
}

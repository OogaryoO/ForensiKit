function Test-FKAdmin {
    <#
    .SYNOPSIS
        目前的 PowerShell 是否以系統管理員身分（已提權）執行。
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-FKAdmin {
    <#
    .SYNOPSIS
        不是系統管理員時 throw。蒐證與保全函式開頭呼叫（契約第 3 節：無管理員權限才 throw）。

    .EXAMPLE
        Assert-FKAdmin
    #>
    [CmdletBinding()]
    param()

    if (-not (Test-FKAdmin)) {
        throw 'ForensiKit 需要系統管理員權限，請以「以系統管理員身分執行」開啟 PowerShell 後再試。'
    }
}

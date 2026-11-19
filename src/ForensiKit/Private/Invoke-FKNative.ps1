function Invoke-FKNative {
    <#
    .SYNOPSIS
        執行外部程式（wevtutil、takeown、icacls…），回傳 exit code、輸出與完整命令列，不 throw。

    .DESCRIPTION
        呼叫期間把 $ErrorActionPreference 暫時改為 Continue，避免外部程式寫入 stderr 時被當成終止錯誤。
        CommandLine 欄位用於寫進 action log（CONTRIBUTING.md 第 5 節：外部指令的完整命令列要寫進 action log）。
        單元測試以 Mock 取代本函式，不會真的執行外部程式。

    .PARAMETER FilePath
        外部程式名稱或路徑。

    .PARAMETER ArgumentList
        參數陣列（由 PowerShell 直接傳遞，不經 cmd.exe）。

    .EXAMPLE
        $r = Invoke-FKNative -FilePath 'wevtutil.exe' -ArgumentList @('gl', 'Security')
        if ($r.ExitCode -ne 0) { ... }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$FilePath,

        [string[]]$ArgumentList = @()
    )

    $commandLine = (@($FilePath) + $ArgumentList) -join ' '
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $FilePath @ArgumentList 2>&1 | ForEach-Object { "$_" })
        $exitCode = $LASTEXITCODE
    }
    catch {
        $output = @($_.Exception.Message)
        $exitCode = -1
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }

    return [pscustomobject]@{
        ExitCode    = $exitCode
        Output      = ($output -join "`n")
        CommandLine = $commandLine
    }
}

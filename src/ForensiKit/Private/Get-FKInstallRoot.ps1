function Get-FKInstallRoot {
    <#
    .SYNOPSIS
        回傳常駐保全的安裝目錄（預設 C:\ProgramData\ForensiKit）。

    .DESCRIPTION
        安裝目錄內容：
          module\ForensiKit\     排程執行時載入的模組副本
          bin\VaultBackup.ps1    排程工作執行的啟動腳本
          preservation.json      安裝時採用的設定
          action_log.jsonl       安裝／移除動作的紀錄
        單元測試以 Mock 把它導到 TestDrive。

    .EXAMPLE
        Get-FKInstallRoot
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return (Join-Path $env:ProgramData 'ForensiKit')
}

@{
    RootModule           = 'ForensiKit.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '6f2b0c1e-4d7a-4b8e-9a3f-2c5d8e1f7a40'
    Author               = 'ForensiKit Team'
    CompanyName          = 'ForensiKit'
    Copyright            = '(c) ForensiKit Team. All rights reserved.'
    Description          = 'Windows 端點事件紀錄與執行痕跡的時段匯出、雜湊與監管鏈工具（PoC）。'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop')

    # 依 docs/ARCHITECTURE.md 第 7 節列出所有契約中的公開函式。
    # 尚未實作的函式不會報錯，只是不存在；實際匯出以 ForensiKit.psm1 的 Export-ModuleMember（Public/ 下的檔案）為準。
    FunctionsToExport    = @(
        'Write-FKAction'
        'Get-FKConfig'
        'Export-FKEventLog'
        'Get-FKArtifact'
        'Install-FKPreservation'
        'Uninstall-FKPreservation'
        'Get-FKPreservationStatus'
        'New-FKManifest'
        'Test-FKPackage'
        'Protect-FKPackage'
        'Unprotect-FKPackage'
        'Invoke-ForensiKit'
        'Start-ForensiKitGui'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()

    PrivateData          = @{
        PSData = @{
            Tags       = @('Forensics', 'DFIR', 'EventLog', 'Windows')
            ProjectUri = 'https://github.com/OogaryoO/ForensiKit'
        }
    }
}

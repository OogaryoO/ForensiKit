function Get-FKPreservationConfig {
    <#
    .SYNOPSIS
        回傳常駐保全實際採用的設定：已安裝時讀 <安裝目錄>\preservation.json，否則用模組內建的預設設定。

    .DESCRIPTION
        Install-FKPreservation -ConfigPath 可能用了自訂的 vaultRoot，所以需要 vault 位置的函式
        （Export-FKEventLog -IncludeVault、Get-FKPreservationStatus 等）一律透過本函式取得設定，
        不自行讀取設定檔（docs/ARCHITECTURE.md 第 5 節）。
        preservation.json 存在但無法讀取或格式錯誤時，輸出 Warning 並改用預設設定，不中斷蒐證流程。

    .EXAMPLE
        (Get-FKPreservationConfig).preservation.vaultRoot
    #>
    [CmdletBinding()]
    param()

    $installed = Join-Path (Get-FKInstallRoot) 'preservation.json'
    if (Test-Path -LiteralPath $installed -PathType Leaf) {
        try {
            return (Get-FKConfig -Path $installed)
        }
        catch {
            Write-Warning "無法讀取已安裝的設定（$installed），改用預設設定：$($_.Exception.Message)"
        }
    }
    return (Get-FKConfig)
}

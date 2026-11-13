function Start-ForensiKitGui {
    <#
    .SYNOPSIS
        開啟 ForensiKit 一鍵蒐證視窗（給資訊室值班人員使用）。

    .DESCRIPTION
        單一視窗輸入案號、操作者、時段（台灣時間，內部轉成 UTC）、輸出位置（自動優先選隨身碟）與加密密碼，
        按「開始匯出」後在背景呼叫 Invoke-ForensiKit，完成後以大字顯示 manifest SHA-256，提示抄寫到監管鏈表單。

        - 不是系統管理員時，會提示並透過 UAC 以系統管理員身分重新開啟自己。
        - WinForms 需要 STA；不是 STA 時會以 -STA 重新開啟。
        - 環境變數 FK_GUI_DEMO=1 時進入 DEMO 模式：不需要管理員權限、不呼叫 Invoke-ForensiKit，結果是假的
          （畫面有紅色警示），用於 T09 完成前開發 GUI 與練習操作。

    .EXAMPLE
        Start-ForensiKitGui

    .EXAMPLE
        $env:FK_GUI_DEMO = '1'; Start-ForensiKitGui
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = '只開啟視窗，不改變系統狀態；名稱由契約第 7 節指定')]
    [CmdletBinding()]
    param()

    Add-Type -AssemblyName System.Windows.Forms
    $demo = ($env:FK_GUI_DEMO -eq '1')
    $manifest = Join-Path $script:FKModuleRoot 'ForensiKit.psd1'
    $relaunchArgs = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -Command "& {{ Import-Module -Name ''{0}''; Start-ForensiKitGui }}"' -f $manifest.Replace("'", "''")

    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $relaunchArgs
        return
    }

    if (-not $demo -and -not (Test-FKAdmin)) {
        $ok = Show-FKGuiMessage -Text '蒐證需要系統管理員權限。按「是」後 Windows 會詢問是否允許，請選「是」。' -Icon Question -YesNo
        if ($ok) {
            try { Start-Process -FilePath 'powershell.exe' -ArgumentList $relaunchArgs -Verb RunAs -ErrorAction Stop }
            catch { $null = Show-FKGuiMessage -Text '沒有取得系統管理員權限，無法蒐證。請聯絡資訊室負責人。' -Icon Error }
        }
        return
    }

    if (-not $demo -and -not (Get-Command -Name 'Invoke-ForensiKit' -Module 'ForensiKit' -ErrorAction SilentlyContinue)) {
        $null = Show-FKGuiMessage -Text '找不到主流程 Invoke-ForensiKit（尚未安裝或版本不完整），無法蒐證。' -Icon Error
        return
    }

    [System.Windows.Forms.Application]::EnableVisualStyles()
    $ui = Initialize-FKGuiForm -Demo:$demo
    try {
        [void]$ui.Form.ShowDialog()
    }
    finally {
        $ui.Timer.Dispose()
        $ui.Form.Dispose()
        $script:FKGui = $null
    }
}

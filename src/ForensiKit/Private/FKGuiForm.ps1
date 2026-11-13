# GUI（T10）的 WinForms 視窗與事件處理。
# 事件處理都只呼叫內部函式，狀態放在模組變數 $script:FKGui（handler 不依賴呼叫堆疊的變數），方便單元測試。

$script:FKGui = $null

function Show-FKGuiMessage {
    <#
    .SYNOPSIS
        顯示訊息對話框（獨立成函式，單元測試以 Mock 取代，避免卡住）。

    .PARAMETER Text
        訊息內容。

    .PARAMETER Icon
        Information、Warning、Error 或 Question。

    .PARAMETER YesNo
        顯示「是／否」按鈕；回傳 $true 表示按了「是」。

    .EXAMPLE
        Show-FKGuiMessage -Text '完成' -Icon Information
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Text,
        [ValidateSet('Information', 'Warning', 'Error', 'Question')][string]$Icon = 'Information',
        [switch]$YesNo
    )

    $buttons = [System.Windows.Forms.MessageBoxButtons]::OK
    if ($YesNo) { $buttons = [System.Windows.Forms.MessageBoxButtons]::YesNo }
    $answer = [System.Windows.Forms.MessageBox]::Show($Text, 'ForensiKit', $buttons, [System.Windows.Forms.MessageBoxIcon]::$Icon)
    return ($answer -eq [System.Windows.Forms.DialogResult]::Yes -or $answer -eq [System.Windows.Forms.DialogResult]::OK)
}

function Initialize-FKGuiForm {
    <#
    .SYNOPSIS
        建立 ForensiKit 主視窗（不顯示），回傳狀態物件 $script:FKGui（含 Form 與各控制項）。

    .PARAMETER Demo
        DEMO 模式：不呼叫 Invoke-ForensiKit，改用假結果，畫面加上紅色警示。

    .EXAMPLE
        $ui = Initialize-FKGuiForm -Demo
        [void]$ui.Form.ShowDialog()
    #>
    [CmdletBinding()]
    param(
        [switch]$Demo
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $lookbackDays = 7
    try { $lookbackDays = [int](Get-FKConfig).defaultLookbackDays } catch { Write-Verbose "使用預設回溯天數 7：$($_.Exception.Message)" }

    $font = New-Object System.Drawing.Font('Microsoft JhengHei UI', 10)
    $bold = New-Object System.Drawing.Font('Microsoft JhengHei UI', 12, [System.Drawing.FontStyle]::Bold)
    $mono = New-Object System.Drawing.Font('Consolas', 15, [System.Drawing.FontStyle]::Bold)

    $ui = @{
        Demo       = [bool]$Demo
        DemoDelay  = 3
        ModulePath = (Join-Path $script:FKModuleRoot 'ForensiKit.psd1')
        Job        = $null
        Hash       = $null
        Result     = $null
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'ForensiKit 一鍵蒐證'
    if ($Demo) { $form.Text += '（DEMO 模式）' }
    $form.Font = $font
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $form.ClientSize = New-Object System.Drawing.Size(760, 700)
    $form.MinimumSize = New-Object System.Drawing.Size(700, 660)
    $ui.Form = $form

    $layout = New-Object System.Windows.Forms.TableLayoutPanel
    $layout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $layout.Padding = New-Object System.Windows.Forms.Padding(14)
    $layout.ColumnCount = 3
    [void]$layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 120)))
    [void]$layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 120)))
    $form.Controls.Add($layout)

    $row = 0
    $anchorLR = [System.Windows.Forms.AnchorStyles]'Left, Right'

    function Add-FKRow {
        param([string]$Label, $Control, $Extra, [int]$Span = 1)
        [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
        if ($Label) {
            $l = New-Object System.Windows.Forms.Label
            $l.Text = $Label
            $l.AutoSize = $true
            $l.Anchor = [System.Windows.Forms.AnchorStyles]::Left
            $l.Margin = New-Object System.Windows.Forms.Padding(3, 8, 3, 3)
            $layout.Controls.Add($l, 0, $script:FKGuiRow)
        }
        if ($Control) {
            $col = 1
            if (-not $Label -and $Span -eq 3) { $col = 0 }
            $layout.Controls.Add($Control, $col, $script:FKGuiRow)
            if ($Span -gt 1) { $layout.SetColumnSpan($Control, $Span) }
        }
        if ($Extra) { $layout.Controls.Add($Extra, 2, $script:FKGuiRow) }
        $script:FKGuiRow++
    }
    $script:FKGuiRow = $row

    if ($Demo) {
        $banner = New-Object System.Windows.Forms.Label
        $banner.Text = 'DEMO 模式：不會蒐證，畫面上的結果與雜湊值都是假的。'
        $banner.ForeColor = [System.Drawing.Color]::White
        $banner.BackColor = [System.Drawing.Color]::Firebrick
        $banner.AutoSize = $false
        $banner.Height = 30
        $banner.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
        $banner.Anchor = $anchorLR
        Add-FKRow -Control $banner -Span 3
    }

    $ui.CaseId = New-Object System.Windows.Forms.TextBox
    $ui.CaseId.Anchor = $anchorLR
    Add-FKRow -Label '案號' -Control $ui.CaseId

    $ui.Operator = New-Object System.Windows.Forms.TextBox
    $ui.Operator.Anchor = $anchorLR
    Add-FKRow -Label '操作者' -Control $ui.Operator

    $nowTaipei = ConvertTo-FKTaipeiTime -Date ([datetime]::UtcNow)
    $endTaipei = $nowTaipei.Date.AddHours($nowTaipei.Hour).AddMinutes($nowTaipei.Minute)
    foreach ($name in 'Start', 'End') {
        $dt = New-Object System.Windows.Forms.DateTimePicker
        $dt.Format = [System.Windows.Forms.DateTimePickerFormat]::Custom
        $dt.CustomFormat = 'yyyy-MM-dd  HH:mm'
        $dt.ShowUpDown = $false
        $dt.Width = 200
        $ui[$name] = $dt
    }
    $ui.End.Value = $endTaipei
    $ui.Start.Value = $endTaipei.AddDays(-$lookbackDays)
    $tz1 = New-Object System.Windows.Forms.Label
    $tz1.Text = '台灣時間'
    $tz1.AutoSize = $true
    $tz1.Margin = New-Object System.Windows.Forms.Padding(3, 8, 3, 3)
    $tz2 = New-Object System.Windows.Forms.Label
    $tz2.Text = '台灣時間'
    $tz2.AutoSize = $true
    $tz2.Margin = New-Object System.Windows.Forms.Padding(3, 8, 3, 3)
    Add-FKRow -Label '開始時間' -Control $ui.Start -Extra $tz1
    Add-FKRow -Label '結束時間' -Control $ui.End -Extra $tz2

    $ui.UtcLabel = New-Object System.Windows.Forms.Label
    $ui.UtcLabel.AutoSize = $true
    $ui.UtcLabel.ForeColor = [System.Drawing.Color]::DimGray
    Add-FKRow -Label '' -Control $ui.UtcLabel -Span 2

    $ui.Output = New-Object System.Windows.Forms.TextBox
    $ui.Output.Anchor = $anchorLR
    $ui.Browse = New-Object System.Windows.Forms.Button
    $ui.Browse.Text = '瀏覽…'
    $ui.Browse.AutoSize = $true
    Add-FKRow -Label '輸出位置' -Control $ui.Output -Extra $ui.Browse

    $ui.OutputNote = New-Object System.Windows.Forms.Label
    $ui.OutputNote.AutoSize = $true
    $ui.OutputNote.MaximumSize = New-Object System.Drawing.Size(560, 0)
    Add-FKRow -Label '' -Control $ui.OutputNote -Span 2

    $ui.Password = New-Object System.Windows.Forms.TextBox
    $ui.Password.UseSystemPasswordChar = $true
    $ui.Password.Anchor = $anchorLR
    Add-FKRow -Label '加密密碼' -Control $ui.Password

    $ui.Password2 = New-Object System.Windows.Forms.TextBox
    $ui.Password2.UseSystemPasswordChar = $true
    $ui.Password2.Anchor = $anchorLR
    Add-FKRow -Label '再輸入一次' -Control $ui.Password2

    $ui.NoEncrypt = New-Object System.Windows.Forms.CheckBox
    $ui.NoEncrypt.Text = '不加密（不建議：證據包會以明文存放在隨身碟）'
    $ui.NoEncrypt.AutoSize = $true
    Add-FKRow -Label '' -Control $ui.NoEncrypt -Span 2

    $ui.StartButton = New-Object System.Windows.Forms.Button
    $ui.StartButton.Text = '開始匯出'
    $ui.StartButton.Font = $bold
    $ui.StartButton.Height = 46
    $ui.StartButton.Anchor = $anchorLR
    $ui.StartButton.Margin = New-Object System.Windows.Forms.Padding(3, 12, 3, 6)
    Add-FKRow -Control $ui.StartButton -Span 3

    $ui.Progress = New-Object System.Windows.Forms.ProgressBar
    $ui.Progress.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $ui.Progress.MarqueeAnimationSpeed = 0
    $ui.Progress.Anchor = $anchorLR
    Add-FKRow -Control $ui.Progress -Span 3

    $ui.Status = New-Object System.Windows.Forms.Label
    $ui.Status.AutoSize = $true
    $ui.Status.Text = '填好案號、操作者與密碼後，按「開始匯出」。'
    Add-FKRow -Control $ui.Status -Span 3

    $hashTitle = New-Object System.Windows.Forms.Label
    $hashTitle.Text = 'manifest SHA-256（完成後請抄寫到紙本監管鏈表單）'
    $hashTitle.AutoSize = $true
    $hashTitle.Margin = New-Object System.Windows.Forms.Padding(3, 12, 3, 3)
    Add-FKRow -Control $hashTitle -Span 3

    $ui.HashLabel = New-Object System.Windows.Forms.Label
    $ui.HashLabel.Font = $mono
    $ui.HashLabel.AutoSize = $true
    $ui.HashLabel.Text = '—'
    $ui.Copy = New-Object System.Windows.Forms.Button
    $ui.Copy.Text = '複製雜湊'
    $ui.Copy.AutoSize = $true
    $ui.Copy.Enabled = $false
    $layout.Controls.Add($ui.HashLabel, 0, $script:FKGuiRow)
    $layout.SetColumnSpan($ui.HashLabel, 2)
    $layout.Controls.Add($ui.Copy, 2, $script:FKGuiRow)
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $script:FKGuiRow++

    $ui.Detail = New-Object System.Windows.Forms.TextBox
    $ui.Detail.Multiline = $true
    $ui.Detail.ReadOnly = $true
    $ui.Detail.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $ui.Detail.Dock = [System.Windows.Forms.DockStyle]::Fill
    $layout.Controls.Add($ui.Detail, 0, $script:FKGuiRow)
    $layout.SetColumnSpan($ui.Detail, 3)
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $layout.RowCount = $script:FKGuiRow + 1

    $ui.Timer = New-Object System.Windows.Forms.Timer
    $ui.Timer.Interval = 500

    # ---- 預設值 ----
    $out = Get-FKDefaultOutputRoot
    $ui.Output.Text = $out.Path
    $ui.OutputNote.Text = $out.Note
    if ($out.IsRemovable) { $ui.OutputNote.ForeColor = [System.Drawing.Color]::DarkGreen }
    else { $ui.OutputNote.ForeColor = [System.Drawing.Color]::DarkOrange }

    # ---- 事件（只呼叫內部函式；狀態放在 $script:FKGui） ----
    $ui.Start.add_ValueChanged({ Update-FKGuiUtcLabel })
    $ui.End.add_ValueChanged({ Update-FKGuiUtcLabel })
    $ui.NoEncrypt.add_CheckedChanged({
            $enabled = -not $script:FKGui.NoEncrypt.Checked
            $script:FKGui.Password.Enabled = $enabled
            $script:FKGui.Password2.Enabled = $enabled
        })
    $ui.Browse.add_Click({ Select-FKGuiOutputFolder })
    $ui.Copy.add_Click({ if ($script:FKGui.Hash) { [System.Windows.Forms.Clipboard]::SetText($script:FKGui.Hash) } })
    $ui.StartButton.add_Click({ Invoke-FKGuiExport })
    $ui.Timer.add_Tick({ Receive-FKGuiJob })
    $form.add_FormClosing({
            param($formSender, $e)
            $null = $formSender
            $job = $script:FKGui.Job
            if ($job -and -not $job.Handle.IsCompleted) {
                if (-not (Show-FKGuiMessage -Text '匯出還在進行中，現在關閉會中斷蒐證、留下不完整的證據包。確定要關閉嗎？' -Icon Warning -YesNo)) {
                    $e.Cancel = $true
                    return
                }
                try { $job.PowerShell.Stop() } catch { Write-Verbose $_.Exception.Message }
            }
            $script:FKGui.Timer.Stop()
        })
    $form.AcceptButton = $ui.StartButton

    $script:FKGui = $ui
    Update-FKGuiUtcLabel
    return $ui
}

function Update-FKGuiUtcLabel {
    <#
    .SYNOPSIS
        依開始／結束時間更新畫面上的 UTC 對照文字。

    .EXAMPLE
        Update-FKGuiUtcLabel
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $ui = $script:FKGui
    if (-not $ui -or -not $PSCmdlet.ShouldProcess('UTC 對照文字', '更新')) { return }
    $s = ConvertTo-FKIsoUtc -Date (ConvertFrom-FKTaipeiTime -Date $ui.Start.Value)
    $e = ConvertTo-FKIsoUtc -Date (ConvertFrom-FKTaipeiTime -Date $ui.End.Value)
    $ui.UtcLabel.Text = "UTC：$s ～ $e"
}

function Select-FKGuiOutputFolder {
    <#
    .SYNOPSIS
        開啟資料夾選擇視窗，更新輸出位置。

    .EXAMPLE
        Select-FKGuiOutputFolder
    #>
    [CmdletBinding()]
    param()

    $ui = $script:FKGui
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = '選擇證據包的輸出位置（建議選隨身碟）'
    if ($ui.Output.Text -and (Test-Path -LiteralPath $ui.Output.Text)) { $dialog.SelectedPath = $ui.Output.Text }
    if ($dialog.ShowDialog($ui.Form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $ui.Output.Text = $dialog.SelectedPath
        $ui.OutputNote.Text = "已選擇：$($dialog.SelectedPath)"
        $ui.OutputNote.ForeColor = [System.Drawing.Color]::DimGray
    }
    $dialog.Dispose()
}

function Set-FKGuiBusy {
    <#
    .SYNOPSIS
        匯出中鎖定輸入欄位並顯示進度動畫；結束後解除。

    .PARAMETER Busy
        $true 表示匯出中。

    .EXAMPLE
        Set-FKGuiBusy -Busy $true
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][bool]$Busy)

    $ui = $script:FKGui
    if (-not $PSCmdlet.ShouldProcess('GUI 狀態', "Busy=$Busy")) { return }
    foreach ($c in $ui.CaseId, $ui.Operator, $ui.Start, $ui.End, $ui.Output, $ui.Browse, $ui.NoEncrypt, $ui.StartButton) {
        $c.Enabled = -not $Busy
    }
    $pwEnabled = (-not $Busy) -and (-not $ui.NoEncrypt.Checked)
    $ui.Password.Enabled = $pwEnabled
    $ui.Password2.Enabled = $pwEnabled
    if ($Busy) { $ui.Progress.MarqueeAnimationSpeed = 30 } else { $ui.Progress.MarqueeAnimationSpeed = 0 }
}

function Invoke-FKGuiExport {
    <#
    .SYNOPSIS
        「開始匯出」按鈕：檢查輸入，在背景 runspace 執行 Invoke-ForensiKit（DEMO 模式改用假結果），視窗不會凍結。

    .EXAMPLE
        Invoke-FKGuiExport
    #>
    [CmdletBinding()]
    param()

    $ui = $script:FKGui
    $startUtc = ConvertFrom-FKTaipeiTime -Date $ui.Start.Value
    $endUtc = ConvertFrom-FKTaipeiTime -Date $ui.End.Value
    $errors = Test-FKGuiInput -CaseId $ui.CaseId.Text.Trim() -Operator $ui.Operator.Text.Trim() -StartUtc $startUtc -EndUtc $endUtc `
        -OutputRoot $ui.Output.Text.Trim() -NoEncrypt:$ui.NoEncrypt.Checked -Password $ui.Password.Text -ConfirmPassword $ui.Password2.Text
    if (@($errors).Count -gt 0) {
        $null = Show-FKGuiMessage -Text ("請修正以下項目：`r`n`r`n- " + ($errors -join "`r`n- ")) -Icon Warning
        return
    }

    $params = @{
        CaseId     = $ui.CaseId.Text.Trim()
        Operator   = $ui.Operator.Text.Trim()
        StartUtc   = $startUtc
        EndUtc     = $endUtc
        OutputRoot = $ui.Output.Text.Trim()
    }
    if ($ui.NoEncrypt.Checked) {
        $params.NoEncrypt = $true
    }
    else {
        $secure = New-Object System.Security.SecureString
        foreach ($ch in $ui.Password.Text.ToCharArray()) { $secure.AppendChar($ch) }
        $secure.MakeReadOnly()
        $params.Password = $secure
    }
    $ui.Password.Text = ''
    $ui.Password2.Text = ''

    $worker = {
        param($ModulePath, $Params, $Demo, $DemoDelay)
        $ErrorActionPreference = 'Stop'
        $module = Import-Module -Name $ModulePath -Force -PassThru
        if ($Demo) { & $module { param($p, $d) Get-FKDemoResult @p -DelaySeconds $d } $Params $DemoDelay }
        else { Invoke-ForensiKit @Params }
    }
    $ps = [System.Management.Automation.PowerShell]::Create()
    $null = $ps.AddScript($worker).AddArgument($ui.ModulePath).AddArgument($params).AddArgument($ui.Demo).AddArgument($ui.DemoDelay)

    $ui.Hash = $null
    $ui.Result = $null
    $ui.HashLabel.Text = '—'
    $ui.Copy.Enabled = $false
    $ui.Detail.Text = ''
    $ui.Status.ForeColor = [System.Drawing.Color]::Black
    $ui.Status.Text = '匯出中…請勿關閉視窗或拔除隨身碟。'
    Set-FKGuiBusy -Busy $true

    $ui.Job = @{ PowerShell = $ps; Handle = $ps.BeginInvoke(); StartedUtc = [datetime]::UtcNow }
    $ui.Timer.Start()
}

function Receive-FKGuiJob {
    <#
    .SYNOPSIS
        計時器每 0.5 秒呼叫：更新經過時間；背景工作完成後顯示結果與 manifest SHA-256。

    .EXAMPLE
        Receive-FKGuiJob
    #>
    [CmdletBinding()]
    param()

    $ui = $script:FKGui
    $job = $ui.Job
    if (-not $job) { $ui.Timer.Stop(); return }

    if (-not $job.Handle.IsCompleted) {
        $elapsed = [int]([datetime]::UtcNow - $job.StartedUtc).TotalSeconds
        $ui.Status.Text = "匯出中…已經過 $elapsed 秒。請勿關閉視窗或拔除隨身碟。"
        return
    }

    $ui.Timer.Stop()
    $ui.Job = $null
    $ps = $job.PowerShell
    $output = @()
    $failure = $null
    try {
        $output = @($ps.EndInvoke($job.Handle))
    }
    catch {
        $failure = $_.Exception.InnerException
        if (-not $failure) { $failure = $_.Exception }
    }
    if (-not $failure -and $ps.Streams.Error.Count -gt 0) { $failure = $ps.Streams.Error[0].Exception }
    $ps.Dispose()
    Set-FKGuiBusy -Busy $false

    $result = $output | Where-Object { $_ -and $_.PSObject.Properties['ManifestSha256'] } | Select-Object -Last 1
    if (-not $result) {
        $message = '沒有取得結果。'
        if ($failure) { $message = $failure.Message }
        $ui.Status.ForeColor = [System.Drawing.Color]::Firebrick
        $ui.Status.Text = "匯出失敗：$message"
        $null = Show-FKGuiMessage -Text "匯出失敗：$message`r`n`r`n請拍下畫面並聯絡資訊室負責人。" -Icon Error
        return
    }

    $ui.Result = $result
    $ui.Hash = [string]$result.ManifestSha256
    $ui.HashLabel.Text = Format-FKHashForDisplay -Hash $ui.Hash
    $ui.Copy.Enabled = [bool]$ui.Hash

    switch ([string]$result.Status) {
        'OK' { $ui.Status.ForeColor = [System.Drawing.Color]::DarkGreen; $ui.Status.Text = '匯出完成。' }
        'Partial' { $ui.Status.ForeColor = [System.Drawing.Color]::DarkOrange; $ui.Status.Text = '部分項目失敗，但證據包已產生（詳見下方）。' }
        default { $ui.Status.ForeColor = [System.Drawing.Color]::Firebrick; $ui.Status.Text = "匯出狀態：$($result.Status)（詳見下方）。" }
    }
    if ($ui.Demo) { $ui.Status.Text = '[DEMO，非真實證據] ' + $ui.Status.Text }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("證據包資料夾：$($result.PackageRoot)")
    if ($result.PackagePath) { $lines.Add("加密檔：$($result.PackagePath)") }
    $lines.Add("耗時：$($result.DurationSec) 秒　整體狀態：$($result.Status)")
    $lines.Add('')
    foreach ($r in @($result.Results)) {
        $name = $null
        if ($r.PSObject.Properties['Channel']) { $name = $r.Channel }
        elseif ($r.PSObject.Properties['Name']) { $name = $r.Name }
        $count = $null
        if ($r.PSObject.Properties['EventCount']) { $count = "$($r.EventCount) 筆事件" }
        elseif ($r.PSObject.Properties['ItemCount']) { $count = "$($r.ItemCount) 筆" }
        $lines.Add(('[{0,-7}] {1}  {2}' -f $r.Status, $name, $count))
    }
    $ui.Detail.Text = $lines -join "`r`n"

    $null = Show-FKGuiMessage -Text ("匯出完成。請把畫面上的 manifest SHA-256 抄寫到紙本監管鏈表單，並由交付人與接收人簽名。`r`n`r`n" + $ui.HashLabel.Text) -Icon Information
}

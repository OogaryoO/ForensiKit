<#
    T10：GUI 的單元測試，由 T10 開發者撰寫。
    只建立視窗物件、不顯示；對話框（Show-FKGuiMessage）一律 Mock，測試不會卡住。
    背景匯出用 DEMO 模式（不呼叫 Invoke-ForensiKit、不碰系統）。
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\src\ForensiKit\ForensiKit.psd1') -Force -ErrorAction Stop

    # 視窗沒有顯示時 PerformClick 不會觸發事件，改用反射呼叫 OnClick（等同使用者按下按鈕）
    function Invoke-TestClick {
        param($Control)
        $m = [System.Windows.Forms.Control].GetMethod('OnClick', [System.Reflection.BindingFlags]'NonPublic, Instance')
        [void]$m.Invoke($Control, @([System.EventArgs]::Empty))
    }
}

AfterAll {
    Remove-Module ForensiKit -ErrorAction SilentlyContinue
}

Describe '台灣時間與 UTC 轉換（T10）' -Tag 'T10' {

    It '台灣時間 2026-11-20 11:15 → UTC 2026-11-20T03:15:00Z（Kind = Utc）' {
        InModuleScope ForensiKit {
            $utc = ConvertFrom-FKTaipeiTime -Date (New-Object datetime 2026, 11, 20, 11, 15, 0)
            $utc.Kind | Should -Be 'Utc'
            ConvertTo-FKIsoUtc -Date $utc | Should -Be '2026-11-20T03:15:00Z'
        }
    }

    It '跨日：台灣時間 2026-11-20 05:00 → UTC 前一天 21:00' {
        InModuleScope ForensiKit {
            ConvertTo-FKIsoUtc -Date (ConvertFrom-FKTaipeiTime -Date (New-Object datetime 2026, 11, 20, 5, 0, 0)) | Should -Be '2026-11-19T21:00:00Z'
        }
    }

    It '不受輸入的 Kind 影響（Local 也只取牆上時間）' {
        InModuleScope ForensiKit {
            $local = New-Object datetime 2026, 11, 20, 11, 15, 0, ([DateTimeKind]::Local)
            ConvertTo-FKIsoUtc -Date (ConvertFrom-FKTaipeiTime -Date $local) | Should -Be '2026-11-20T03:15:00Z'
        }
    }

    It 'ConvertTo-FKTaipeiTime 是反向轉換' {
        InModuleScope ForensiKit {
            $utc = New-Object datetime 2026, 11, 20, 3, 15, 0, ([DateTimeKind]::Utc)
            (ConvertTo-FKTaipeiTime -Date $utc).ToString('yyyy-MM-dd HH:mm') | Should -Be '2026-11-20 11:15'
        }
    }
}

Describe 'Test-FKGuiInput（T10）' -Tag 'T10' {

    BeforeAll {
        $script:Now = New-Object datetime 2026, 11, 21, 0, 0, 0, ([DateTimeKind]::Utc)
        $script:Ok = @{
            CaseId = '2026-001'; Operator = '王小明'
            StartUtc = $script:Now.AddDays(-1); EndUtc = $script:Now
            OutputRoot = $TestDrive; Password = 'P@ssw0rd!'; ConfirmPassword = 'P@ssw0rd!'; NowUtc = $script:Now
        }
    }

    It '全部正確時回傳空陣列' {
        $p = $script:Ok
        InModuleScope ForensiKit -Parameters @{ P = $p } { param($P) @(Test-FKGuiInput @P).Count | Should -Be 0 }
    }

    It '<Case>' -ForEach @(
        @{ Case = '案號空白'; Change = @{ CaseId = '' }; Expect = '*案號*' }
        @{ Case = '案號含不允許的字元（會成為資料夾名稱）'; Change = @{ CaseId = '2026/001' }; Expect = '*案號只能*' }
        @{ Case = '操作者空白'; Change = @{ Operator = ' ' }; Expect = '*操作者*' }
        @{ Case = '開始時間不早於結束時間'; Change = @{ StartUtc = (New-Object datetime 2026, 11, 21, 0, 0, 0, ([DateTimeKind]::Utc)) }; Expect = '*開始時間*' }
        @{ Case = '結束時間在未來'; Change = @{ EndUtc = (New-Object datetime 2026, 11, 22, 0, 0, 0, ([DateTimeKind]::Utc)) }; Expect = '*結束時間*' }
        @{ Case = '輸出位置不存在'; Change = @{ OutputRoot = 'Z:\no\such\dir' }; Expect = '*輸出位置*' }
        @{ Case = '密碼太短'; Change = @{ Password = 'short'; ConfirmPassword = 'short' }; Expect = '*至少 8*' }
        @{ Case = '密碼不一致（區分大小寫）'; Change = @{ ConfirmPassword = 'p@ssw0rd!' }; Expect = '*不一致*' }
    ) {
        $p = $script:Ok.Clone()
        foreach ($k in $Change.Keys) { $p[$k] = $Change[$k] }
        $errors = @(InModuleScope ForensiKit -Parameters @{ P = $p } { param($P) Test-FKGuiInput @P })
        @($errors).Count | Should -Be 1
        $errors[0] | Should -BeLike $Expect
    }

    It '勾選不加密時不檢查密碼' {
        $p = $script:Ok.Clone()
        $p.Password = ''
        $p.ConfirmPassword = ''
        InModuleScope ForensiKit -Parameters @{ P = $p } { param($P) @(Test-FKGuiInput @P -NoEncrypt).Count | Should -Be 0 }
    }
}

Describe 'Get-FKDefaultOutputRoot（T10）' -Tag 'T10' {

    It '有多個隨身碟時選剩餘空間最大的' {
        InModuleScope ForensiKit {
            Mock Get-CimInstance { @([pscustomobject]@{ DeviceID = 'E:'; FreeSpace = 1GB }, [pscustomobject]@{ DeviceID = 'F:'; FreeSpace = 8GB }) }
            $r = Get-FKDefaultOutputRoot
            $r.Path | Should -Be 'F:\'
            $r.IsRemovable | Should -BeTrue
        }
    }

    It '沒有隨身碟時退回桌面並提醒' {
        InModuleScope ForensiKit {
            Mock Get-CimInstance { @() }
            $r = Get-FKDefaultOutputRoot
            $r.IsRemovable | Should -BeFalse
            $r.Note | Should -BeLike '*隨身碟*'
        }
    }
}

Describe 'Format-FKHashForDisplay（T10）' -Tag 'T10' {

    It '64 字元分成兩行、每 4 字一組、小寫' {
        InModuleScope ForensiKit {
            $text = Format-FKHashForDisplay -Hash ('AB' * 32)
            $lines = $text -split [Environment]::NewLine
            $lines.Count | Should -Be 2
            $lines[0] | Should -Be ((@('abab') * 8) -join ' ')
        }
    }
}

Describe 'GUI 視窗（T10，DEMO 模式）' -Tag 'T10' {

    BeforeAll {
        Mock -ModuleName ForensiKit Show-FKGuiMessage { $true }
        Mock -ModuleName ForensiKit Get-FKDefaultOutputRoot { [pscustomobject]@{ Path = $TestDrive; IsRemovable = $true; Note = '測試用' } }
    }

    BeforeEach {
        $script:Ui = InModuleScope ForensiKit { Initialize-FKGuiForm -Demo }
    }

    AfterEach {
        $script:Ui.Timer.Dispose()
        $script:Ui.Form.Dispose()
    }

    It '預設時段為「現在」往前 defaultLookbackDays（7）天，並顯示 UTC 對照' {
        ($script:Ui.End.Value - $script:Ui.Start.Value).TotalDays | Should -Be 7
        $nowTaipei = [datetime]::UtcNow.AddHours(8)
        [math]::Abs(($script:Ui.End.Value - $nowTaipei).TotalMinutes) | Should -BeLessThan 2
        $script:Ui.UtcLabel.Text | Should -Match '^UTC：\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:00Z ～ \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:00Z$'
    }

    It '預設輸出位置來自 Get-FKDefaultOutputRoot' {
        $script:Ui.Output.Text | Should -Be $TestDrive
    }

    It 'DEMO 模式在標題標示' {
        $script:Ui.Form.Text | Should -BeLike '*DEMO*'
    }

    It '勾選「不加密」時停用密碼欄' {
        $script:Ui.NoEncrypt.Checked = $true
        $script:Ui.Password.Enabled | Should -BeFalse
        $script:Ui.NoEncrypt.Checked = $false
        $script:Ui.Password.Enabled | Should -BeTrue
    }

    It '輸入不完整時按「開始匯出」只顯示錯誤，不啟動匯出' {
        Invoke-TestClick $script:Ui.StartButton
        Should -Invoke -ModuleName ForensiKit Show-FKGuiMessage -Times 1 -Exactly -ParameterFilter { $Icon -eq 'Warning' -and $Text -like '*案號*' }
        $script:Ui.Job | Should -BeNullOrEmpty
    }

    It '完整流程：背景匯出完成後顯示 SHA-256、清空密碼欄、提示抄寫' {
        $ui = $script:Ui
        $ui.DemoDelay = 0
        $ui.CaseId.Text = '2026-001'
        $ui.Operator.Text = '王小明'
        $ui.End.Value = $ui.End.Value.AddMinutes(-10)
        $ui.Password.Text = 'P@ssw0rd!'
        $ui.Password2.Text = 'P@ssw0rd!'

        Invoke-TestClick $ui.StartButton
        $ui.Job | Should -Not -BeNullOrEmpty
        $ui.StartButton.Enabled | Should -BeFalse
        $ui.Password.Text | Should -Be ''

        $deadline = [datetime]::UtcNow.AddSeconds(60)
        while (-not $ui.Job.Handle.IsCompleted -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 200 }
        InModuleScope ForensiKit { Receive-FKGuiJob }

        $ui.Hash | Should -Match '^[0-9a-f]{64}$'
        $ui.HashLabel.Text | Should -Be (InModuleScope ForensiKit -Parameters @{ H = $ui.Hash } { param($H) Format-FKHashForDisplay -Hash $H })
        $ui.Result.PackagePath | Should -BeLike '*.fkpkg'
        $ui.Status.Text | Should -BeLike '*DEMO*完成*'
        $ui.Detail.Text | Should -BeLike '*Security*'
        $ui.StartButton.Enabled | Should -BeTrue
        Should -Invoke -ModuleName ForensiKit Show-FKGuiMessage -Times 1 -Exactly -ParameterFilter { $Icon -eq 'Information' -and $Text -like '*監管鏈*' }
    }
}

Describe 'Start-ForensiKitGui（T10）' -Tag 'T10' {

    It '非管理員且不是 DEMO：詢問後以 UAC 重新啟動，不開視窗' {
        $old = $env:FK_GUI_DEMO
        try {
            $env:FK_GUI_DEMO = $null
            Mock -ModuleName ForensiKit Test-FKAdmin { $false }
            Mock -ModuleName ForensiKit Show-FKGuiMessage { $true }
            Mock -ModuleName ForensiKit Start-Process { }
            Mock -ModuleName ForensiKit Initialize-FKGuiForm { throw '不應建立視窗' }
            Start-ForensiKitGui
            Should -Invoke -ModuleName ForensiKit Start-Process -Times 1 -Exactly -ParameterFilter { $Verb -eq 'RunAs' -and $ArgumentList -like '*Start-ForensiKitGui*' -and $ArgumentList -notlike '*EncodedCommand*' }
        }
        finally { $env:FK_GUI_DEMO = $old }
    }

    It '管理員但主流程 Invoke-ForensiKit 不存在：顯示錯誤，不開視窗' {
        $old = $env:FK_GUI_DEMO
        try {
            $env:FK_GUI_DEMO = $null
            Mock -ModuleName ForensiKit Test-FKAdmin { $true }
            Mock -ModuleName ForensiKit Show-FKGuiMessage { $true }
            Mock -ModuleName ForensiKit Initialize-FKGuiForm { throw '不應建立視窗' }
            Mock -ModuleName ForensiKit Get-Command { $null } -ParameterFilter { $Name -eq 'Invoke-ForensiKit' }
            Start-ForensiKitGui
            Should -Invoke -ModuleName ForensiKit Show-FKGuiMessage -Times 1 -Exactly -ParameterFilter { $Icon -eq 'Error' -and $Text -like '*Invoke-ForensiKit*' }
        }
        finally { $env:FK_GUI_DEMO = $old }
    }
}

<#
    T06：常駐保全（Install-/Uninstall-FKPreservation、Get-FKPreservationStatus、vault 備份）的單元測試，由 T06 開發者撰寫。
    QA 依契約撰寫的測試見 T11（Install-FKPreservation.Tests.ps1 等）。

    安全：所有會改系統的動作（排程、ACL、wevtutil／takeown／icacls、管理員檢查）都在最外層 BeforeAll 以 Mock 取代，
    安裝目錄與 vault 都導到 TestDrive。絕不會在執行測試的電腦上真的註冊排程或改 log 上限。
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\src\ForensiKit\ForensiKit.psd1') -Force -ErrorAction Stop

    function New-TestConfigFile {
        param([string]$Path, [string]$VaultRoot, [string[]]$Channels = @('Security', 'System', 'Microsoft-Windows-Sysmon/Operational'), [int]$MaxTotalMB = 2048)
        $cfg = [ordered]@{
            channels            = $Channels
            defaultLookbackDays = 7
            preservation        = [ordered]@{
                logMaxSizeMB         = [ordered]@{ Security = 512; default = 128 }
                vaultRoot            = $VaultRoot
                vaultIntervalMinutes = 60
                vaultMaxTotalMB      = $MaxTotalMB
            }
        }
        [System.IO.File]::WriteAllText($Path, ($cfg | ConvertTo-Json -Depth 5))
        return $Path
    }

    function Get-ActionLog {
        param([string]$Root)
        $p = Join-Path $Root 'action_log.jsonl'
        if (-not (Test-Path -LiteralPath $p)) { return @() }
        return @([System.IO.File]::ReadAllLines($p, [System.Text.Encoding]::UTF8) | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    }
}

AfterAll {
    Remove-Module ForensiKit -ErrorAction SilentlyContinue
}

Describe '常駐保全（T06）' -Tag 'T06' {

    BeforeAll {
        # ---- 安全護欄：所有系統操作一律 Mock ----
        Mock -ModuleName ForensiKit Assert-FKAdmin { }
        Mock -ModuleName ForensiKit Protect-FKDirectory { }
        Mock -ModuleName ForensiKit Register-FKVaultTask { }
        Mock -ModuleName ForensiKit Unregister-FKVaultTask { $true }
        Mock -ModuleName ForensiKit Get-FKVaultTaskInfo { [pscustomobject]@{ Registered = $false; LastRunUtc = $null; LastResult = $null } }
        Mock -ModuleName ForensiKit Invoke-FKNative { [pscustomobject]@{ ExitCode = 0; Output = ''; CommandLine = (@($FilePath) + $ArgumentList) -join ' ' } }
        # Security 20 MB、System 200 MB（已大於目標）、Sysmon 不存在
        Mock -ModuleName ForensiKit Get-FKLogMaxSize {
            switch ($Channel) {
                'Security' { [long]20MB }
                'System' { [long]200MB }
                default { $null }
            }
        }
    }

    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:InstallRoot = Join-Path $script:Root 'ProgramData\ForensiKit'
        $script:Vault = Join-Path $script:Root 'vault'
        New-Item -ItemType Directory -Path $script:Root | Out-Null
        $script:Config = New-TestConfigFile -Path (Join-Path $script:Root 'profile.json') -VaultRoot $script:Vault
        Mock -ModuleName ForensiKit Get-FKInstallRoot { $script:InstallRoot }
    }

    Context 'Install-FKPreservation' {

        It '回傳契約欄位，Status = OK，TaskRegistered = $true' {
            $r = Install-FKPreservation -ConfigPath $script:Config -Confirm:$false
            $r.PSObject.Properties.Name | Should -Be @('LogSizesApplied', 'VaultRoot', 'TaskRegistered', 'Status')
            $r.Status | Should -Be 'OK'
            $r.TaskRegistered | Should -BeTrue
            $r.VaultRoot | Should -Be $script:Vault
        }

        It '只對小於目標的 channel 執行 wevtutil sl，bytes 正確；不存在的 channel 為 Skipped' {
            $r = Install-FKPreservation -ConfigPath $script:Config -Confirm:$false
            Should -Invoke -ModuleName ForensiKit Invoke-FKNative -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'wevtutil.exe' -and ($ArgumentList -join ' ') -eq ('sl Security /ms:{0}' -f (512 * 1MB))
            }
            Should -Invoke -ModuleName ForensiKit Invoke-FKNative -Times 0 -Exactly -ParameterFilter { $ArgumentList -contains 'System' }
            ($r.LogSizesApplied | Where-Object Channel -EQ 'Security').Status | Should -Be 'OK'
            ($r.LogSizesApplied | Where-Object Channel -EQ 'System').PreviousMB | Should -Be 200
            ($r.LogSizesApplied | Where-Object Channel -EQ 'Microsoft-Windows-Sysmon/Operational').Status | Should -Be 'Skipped'
        }

        It '註冊排程時使用 vaultIntervalMinutes 與安裝目錄中的啟動腳本' {
            $null = Install-FKPreservation -ConfigPath $script:Config -Confirm:$false
            $runner = Join-Path $script:InstallRoot 'bin\VaultBackup.ps1'
            Should -Invoke -ModuleName ForensiKit Register-FKVaultTask -Times 1 -Exactly -ParameterFilter { $IntervalMinutes -eq 60 -and $RunnerPath -eq $runner }
        }

        It '建立模組副本、preservation.json 與 UTF-8 BOM 的啟動腳本' {
            $null = Install-FKPreservation -ConfigPath $script:Config -Confirm:$false
            Join-Path $script:InstallRoot 'module\ForensiKit\ForensiKit.psd1' | Should -Exist
            $cfgCopy = Join-Path $script:InstallRoot 'preservation.json'
            (Get-Content -LiteralPath $cfgCopy -Raw | ConvertFrom-Json).preservation.vaultRoot | Should -Be $script:Vault
            $runner = Join-Path $script:InstallRoot 'bin\VaultBackup.ps1'
            $bytes = [System.IO.File]::ReadAllBytes($runner)
            ('{0:X2}{1:X2}{2:X2}' -f $bytes[0], $bytes[1], $bytes[2]) | Should -Be 'EFBBBF'
            $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($runner, [ref]$null, [ref]$errors)
            $errors | Should -BeNullOrEmpty
        }

        It 'vault 與安裝目錄分別套用 Vault／InstallRoot 的 ACL' {
            $null = Install-FKPreservation -ConfigPath $script:Config -Confirm:$false
            $script:Vault | Should -Exist
            Should -Invoke -ModuleName ForensiKit Protect-FKDirectory -Times 1 -Exactly -ParameterFilter { $Mode -eq 'Vault' -and $Path -eq $script:Vault }
            Should -Invoke -ModuleName ForensiKit Protect-FKDirectory -Times 1 -Exactly -ParameterFilter { $Mode -eq 'InstallRoot' -and $Path -eq $script:InstallRoot }
        }

        It '重複安裝不 throw，結果相同（冪等）' {
            $null = Install-FKPreservation -ConfigPath $script:Config -Confirm:$false
            { Install-FKPreservation -ConfigPath $script:Config -Confirm:$false } | Should -Not -Throw
            (Install-FKPreservation -ConfigPath $script:Config -Confirm:$false).Status | Should -Be 'OK'
        }

        It '單一 channel 設定失敗 → Status = Partial，排程仍註冊' {
            Mock -ModuleName ForensiKit Invoke-FKNative { [pscustomobject]@{ ExitCode = 5; Output = 'Access denied'; CommandLine = 'wevtutil sl Security' } }
            $r = Install-FKPreservation -ConfigPath $script:Config -Confirm:$false
            $r.Status | Should -Be 'Partial'
            $r.TaskRegistered | Should -BeTrue
            ($r.LogSizesApplied | Where-Object Channel -EQ 'Security').Status | Should -Be 'Failed'
        }

        It '排程註冊失敗 → Status = Failed，不 throw' {
            Mock -ModuleName ForensiKit Register-FKVaultTask { throw 'boom' }
            $r = Install-FKPreservation -ConfigPath $script:Config -Confirm:$false
            $r.Status | Should -Be 'Failed'
            $r.TaskRegistered | Should -BeFalse
        }

        It '每個動作都寫進安裝目錄的 action_log.jsonl，含 wevtutil 完整命令列' {
            $null = Install-FKPreservation -ConfigPath $script:Config -Confirm:$false
            $log = Get-ActionLog -Root $script:InstallRoot
            $log.action | Should -Contain 'SetLogMaxSize'
            $log.action | Should -Contain 'InstallFiles'
            $log.action | Should -Contain 'CreateVault'
            $log.action | Should -Contain 'RegisterTask'
            ($log | Where-Object { $_.action -eq 'SetLogMaxSize' -and $_.target -eq 'Security' }).detail | Should -Match 'wevtutil\.exe sl Security /ms:'
        }

        It '安裝結束後恢復原本的「目前證據包」' {
            $pkg = Join-Path $script:Root 'pkg'
            New-Item -ItemType Directory -Path $pkg | Out-Null
            InModuleScope ForensiKit -Parameters @{ P = $pkg } { param($P) $null = Open-FKActionLog -PackageRoot $P }
            $null = Install-FKPreservation -ConfigPath $script:Config -Confirm:$false
            InModuleScope ForensiKit { Get-FKActionLogPath } | Should -Be (Join-Path $pkg 'action_log.jsonl')
            InModuleScope ForensiKit { Close-FKActionLog }
        }

        It '-WhatIf 不做任何變更，Status = Skipped' {
            $r = Install-FKPreservation -ConfigPath $script:Config -WhatIf
            $r.Status | Should -Be 'Skipped'
            Should -Invoke -ModuleName ForensiKit Register-FKVaultTask -Times 0 -Exactly
            Should -Invoke -ModuleName ForensiKit Invoke-FKNative -Times 0 -Exactly
        }

        It '非管理員時 throw' {
            Mock -ModuleName ForensiKit Assert-FKAdmin { throw 'ForensiKit 需要系統管理員權限' }
            { Install-FKPreservation -ConfigPath $script:Config -Confirm:$false } | Should -Throw -ExpectedMessage '*系統管理員*'
        }
    }

    Context 'Uninstall-FKPreservation' {

        BeforeEach {
            $null = Install-FKPreservation -ConfigPath $script:Config -Confirm:$false
            New-Item -ItemType Directory -Path (Join-Path $script:Vault 'Security') -Force | Out-Null
            [System.IO.File]::WriteAllBytes((Join-Path $script:Vault 'Security\20261120T000000Z.evtx'), [byte[]](1, 2, 3))
            Mock -ModuleName ForensiKit Get-FKVaultTaskInfo { [pscustomobject]@{ Registered = $true; LastRunUtc = $null; LastResult = 0 } }
        }

        It '刪除排程、模組副本與設定，保留 action_log.jsonl；預設刪除 vault' {
            $r = Uninstall-FKPreservation -Confirm:$false
            $r.Status | Should -Be 'OK'
            Should -Invoke -ModuleName ForensiKit Unregister-FKVaultTask -Times 1 -Exactly
            Join-Path $script:InstallRoot 'module' | Should -Not -Exist
            Join-Path $script:InstallRoot 'preservation.json' | Should -Not -Exist
            Join-Path $script:InstallRoot 'action_log.jsonl' | Should -Exist
            $script:Vault | Should -Not -Exist
            Should -Invoke -ModuleName ForensiKit Invoke-FKNative -ParameterFilter { $FilePath -eq 'takeown.exe' } -Times 1 -Exactly
        }

        It '-KeepVault 保留 vault 與備份檔' {
            $r = Uninstall-FKPreservation -KeepVault -Confirm:$false
            $r.Status | Should -Be 'OK'
            Join-Path $script:Vault 'Security\20261120T000000Z.evtx' | Should -Exist
            Should -Invoke -ModuleName ForensiKit Invoke-FKNative -ParameterFilter { $FilePath -eq 'takeown.exe' } -Times 0 -Exactly
        }

        It '-WhatIf 不刪任何東西' {
            $r = Uninstall-FKPreservation -WhatIf
            $r.Status | Should -Be 'Skipped'
            $script:Vault | Should -Exist
            Should -Invoke -ModuleName ForensiKit Unregister-FKVaultTask -Times 0 -Exactly
        }

        It 'ConfirmImpact 為 High（刪除 vault 前要求確認）' {
            $attr = (Get-Command Uninstall-FKPreservation).ScriptBlock.Attributes | Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] }
            $attr.SupportsShouldProcess | Should -BeTrue
            $attr.ConfirmImpact | Should -Be 'High'
        }
    }

    Context 'Uninstall-FKPreservation（尚未安裝）' {

        It '不 throw，Status = Skipped' {
            $r = Uninstall-FKPreservation -KeepVault -Confirm:$false
            $r.Status | Should -Be 'Skipped'
            Should -Invoke -ModuleName ForensiKit Unregister-FKVaultTask -Times 0 -Exactly
        }
    }

    Context 'Get-FKPreservationStatus' {

        It '未安裝：TaskRegistered = $false、LastRunUtc = $null、VaultSizeMB = 0，且不 throw' {
            $s = Get-FKPreservationStatus
            $s.PSObject.Properties.Name | Should -Be @('TaskRegistered', 'LastRunUtc', 'VaultSizeMB', 'LogSizes')
            $s.TaskRegistered | Should -BeFalse
            $s.LastRunUtc | Should -BeNullOrEmpty
        }

        It '已安裝：VaultSizeMB 為 .evtx 總大小、LastRunUtc 為 UTC、LogSizes 列出每個 channel' {
            $null = Install-FKPreservation -ConfigPath $script:Config -Confirm:$false
            New-Item -ItemType Directory -Path (Join-Path $script:Vault 'Security') -Force | Out-Null
            [System.IO.File]::WriteAllBytes((Join-Path $script:Vault 'Security\a.evtx'), (New-Object byte[] (1MB)))
            [System.IO.File]::WriteAllBytes((Join-Path $script:Vault 'Security\b.evtx'), (New-Object byte[] (512KB)))
            [System.IO.File]::WriteAllBytes((Join-Path $script:Vault 'action_log.jsonl'), (New-Object byte[] (1MB)))
            Mock -ModuleName ForensiKit Get-FKVaultTaskInfo { [pscustomobject]@{ Registered = $true; LastRunUtc = (New-Object datetime 2026, 11, 20, 3, 0, 0, ([DateTimeKind]::Utc)); LastResult = 0 } }

            $s = Get-FKPreservationStatus
            $s.TaskRegistered | Should -BeTrue
            $s.LastRunUtc.Kind | Should -Be 'Utc'
            $s.VaultSizeMB | Should -Be 1.5
            @($s.LogSizes).Count | Should -Be 3
            ($s.LogSizes | Where-Object Channel -EQ 'Security').MaxSizeMB | Should -Be 20
            ($s.LogSizes | Where-Object Channel -EQ 'Microsoft-Windows-Sysmon/Operational').Exists | Should -BeFalse
        }
    }

    Context 'Invoke-FKVaultBackup（排程執行的備份）' {

        BeforeEach {
            # 假的 wevtutil epl：在目的地建立 100 KB 的檔案
            Mock -ModuleName ForensiKit Invoke-FKNative {
                if ($ArgumentList[0] -eq 'epl') { [System.IO.File]::WriteAllBytes($ArgumentList[2], (New-Object byte[] (100KB))) }
                [pscustomobject]@{ ExitCode = 0; Output = ''; CommandLine = (@($FilePath) + $ArgumentList) -join ' ' }
            }
        }

        It '第一次完整匯出；channel 目錄使用安全名稱、檔名為 yyyyMMddTHHmmssZ.evtx；不存在的 channel 略過' {
            $r = InModuleScope ForensiKit -Parameters @{ C = $script:Config } { param($C) Invoke-FKVaultBackup -ConfigPath $C }
            ($r | Where-Object Channel -EQ 'Security').Status | Should -Be 'OK'
            ($r | Where-Object Channel -EQ 'Microsoft-Windows-Sysmon/Operational').Status | Should -Be 'Skipped'
            $file = @(Get-ChildItem -LiteralPath (Join-Path $script:Vault 'Security') -Filter '*.evtx')
            $file.Count | Should -Be 1
            $file[0].Name | Should -Match '^\d{8}T\d{6}Z\.evtx$'
            Should -Invoke -ModuleName ForensiKit Invoke-FKNative -Times 1 -Exactly -ParameterFilter { $ArgumentList[1] -eq 'Security' -and -not ($ArgumentList -like '/q:*') }
        }

        It '已有備份時只匯出「上一份時間 − 5 分鐘」之後的事件' {
            $dir = Join-Path $script:Vault 'Security'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            [System.IO.File]::WriteAllBytes((Join-Path $dir '20261120T030000Z.evtx'), [byte[]](1))
            $null = InModuleScope ForensiKit -Parameters @{ C = $script:Config } { param($C) Invoke-FKVaultBackup -ConfigPath $C }
            Should -Invoke -ModuleName ForensiKit Invoke-FKNative -Times 1 -Exactly -ParameterFilter {
                $ArgumentList[1] -eq 'Security' -and ($ArgumentList -contains "/q:*[System[TimeCreated[@SystemTime>='2026-11-20T02:55:00.000Z']]]")
            }
        }

        It 'channel 名稱含 / 時，目錄名改為 %4' {
            $cfg = New-TestConfigFile -Path (Join-Path $script:Root 'p2.json') -VaultRoot $script:Vault -Channels @('Microsoft-Windows-PowerShell/Operational')
            Mock -ModuleName ForensiKit Get-FKLogMaxSize { [long]1MB }
            $null = InModuleScope ForensiKit -Parameters @{ C = $cfg } { param($C) Invoke-FKVaultBackup -ConfigPath $C }
            Join-Path $script:Vault 'Microsoft-Windows-PowerShell%4Operational' | Should -Exist
        }

        It 'wevtutil 失敗時該 channel 為 Failed 並寫入 vault 的 action log' {
            Mock -ModuleName ForensiKit Invoke-FKNative { [pscustomobject]@{ ExitCode = 15007; Output = 'not found'; CommandLine = 'wevtutil epl Security x' } }
            $r = InModuleScope ForensiKit -Parameters @{ C = $script:Config } { param($C) Invoke-FKVaultBackup -ConfigPath $C }
            ($r | Where-Object Channel -EQ 'Security').Status | Should -Be 'Failed'
            (Get-ActionLog -Root $script:Vault | Where-Object { $_.status -eq 'Failed' }).target | Should -Contain 'Security'
        }
    }

    Context 'Limit-FKVaultSize（容量上限）' {

        It '超過上限時從最舊的開始刪，每個 channel 保留最新一份' {
            $sec = Join-Path $script:Vault 'Security'
            $sys = Join-Path $script:Vault 'System'
            New-Item -ItemType Directory -Path $sec, $sys -Force | Out-Null
            foreach ($n in '20261120T000000Z', '20261120T010000Z', '20261120T020000Z') {
                [System.IO.File]::WriteAllBytes((Join-Path $sec "$n.evtx"), (New-Object byte[] (1MB)))
            }
            [System.IO.File]::WriteAllBytes((Join-Path $sys '20261120T000000Z.evtx'), (New-Object byte[] (1MB)))

            InModuleScope ForensiKit -Parameters @{ V = $script:Vault } { param($V) Limit-FKVaultSize -VaultRoot $V -MaxTotalMB 2 }

            @(Get-ChildItem -LiteralPath $sec).Name | Should -Be @('20261120T020000Z.evtx')
            Join-Path $sys '20261120T000000Z.evtx' | Should -Exist
        }

        It '未超過上限時不刪除' {
            $sec = Join-Path $script:Vault 'Security'
            New-Item -ItemType Directory -Path $sec -Force | Out-Null
            [System.IO.File]::WriteAllBytes((Join-Path $sec '20261120T000000Z.evtx'), (New-Object byte[] (1KB)))
            [System.IO.File]::WriteAllBytes((Join-Path $sec '20261120T010000Z.evtx'), (New-Object byte[] (1KB)))
            InModuleScope ForensiKit -Parameters @{ V = $script:Vault } { param($V) Limit-FKVaultSize -VaultRoot $V -MaxTotalMB 1 }
            @(Get-ChildItem -LiteralPath $sec).Count | Should -Be 2
        }
    }

    Context 'ConvertFrom-FKVaultFileName' {

        It '解析 yyyyMMddTHHmmssZ 為 UTC；格式不符回傳 $null' {
            InModuleScope ForensiKit {
                $t = ConvertFrom-FKVaultFileName -Name '20261120T031500Z.evtx'
                $t.Kind | Should -Be 'Utc'
                $t.ToString('yyyy-MM-dd HH:mm:ss') | Should -Be '2026-11-20 03:15:00'
                ConvertFrom-FKVaultFileName -Name 'garbage.evtx' | Should -BeNullOrEmpty
            }
        }
    }
}

<#
    T04：Export-FKEventLog 實作細節的測試（開發者補充；契約層級的測試見 QA 的 T11 Export-FKEventLog.Tests.ps1）。
    wevtutil（epl、gl、gli）以 Mock 取代，不碰真實事件記錄；Get-WinEvent 也 Mock 掉並確認不再用於計數。檔案只寫在 TestDrive。
#>

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..\..\src\ForensiKit\ForensiKit.psd1'
    Import-Module $script:ModulePath -Force -ErrorAction Stop

    function New-UtcDate([int]$y, [int]$mo, [int]$d, [int]$h, [int]$mi, [int]$s, [int]$ms = 0) {
        New-Object datetime $y, $mo, $d, $h, $mi, $s, $ms, ([DateTimeKind]::Utc)
    }

    $script:start = New-UtcDate 2026 11 20 1 0 0
    $script:end = New-UtcDate 2026 11 20 3 0 0 999

    # 假 wevtutil：記錄每次呼叫；'FK-Missing' 不存在（15007）；'FK-Denied' 匯出失敗（5）；
    # 來源路徑含 'bad-backup' 的 vault 備份匯出失敗；其他 epl 成功並建立目的檔。
    $script:fakeWevtutil = {
        [void]$global:FKImplCalls.Add([string[]]@($args | ForEach-Object { [string]$_ }))
        $verb = [string]$args[0]
        $source = [string]$args[1]
        if ($source -eq 'FK-Missing') { $global:LASTEXITCODE = 15007; return 'channel not found' }
        if ($verb -eq 'gl') { $global:LASTEXITCODE = 0; return "name: $source" }
        if ($verb -eq 'gli') {
            # 筆數由 $global:FKImplGliCount 決定；$global:FKImplGliMode = 'fail' 時失敗、'garbled' 時輸出沒有 numberOfLogRecords
            if ($global:FKImplGliMode -eq 'fail') { $global:LASTEXITCODE = 2; return 'The system cannot find the file specified.' }
            $global:LASTEXITCODE = 0
            if ($global:FKImplGliMode -eq 'garbled') { return @('creationTime: 2026-11-20T01:00:00.000Z', 'fileSize: 69632') }
            return @('creationTime: 2026-11-20T01:00:00.000Z', 'fileSize: 69632', 'attributes: 32', "numberOfLogRecords: $global:FKImplGliCount", 'oldestRecordNumber: 1')
        }
        if ($verb -eq 'epl') {
            if ($source -eq 'FK-Denied' -or $source -like '*bad-backup*') { $global:LASTEXITCODE = 5; return 'Access is denied.' }
            [System.IO.File]::WriteAllText([string]$args[2], 'fake-evtx')
            $global:LASTEXITCODE = 0
            return
        }
        $global:LASTEXITCODE = 0
    }

    function Get-EplCall { @($global:FKImplCalls | Where-Object { $_[0] -eq 'epl' }) }

    function New-VaultBackup([string]$Root, [string]$Channel, [string[]]$Names) {
        $dir = Join-Path $Root $Channel
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        foreach ($n in $Names) { [System.IO.File]::WriteAllText((Join-Path $dir $n), 'fake-backup') }
    }

    function New-ImplConfig([string[]]$Channels, [string]$VaultRoot) {
        [pscustomobject]@{
            channels            = $Channels
            defaultLookbackDays = 7
            preservation        = [pscustomobject]@{
                logMaxSizeMB         = [pscustomobject]@{ default = 128 }
                vaultRoot            = $VaultRoot
                vaultIntervalMinutes = 60
                vaultMaxTotalMB      = 2048
            }
        }
    }
}

AfterAll {
    Remove-Variable -Name FKImplCalls, FKImplGliCount, FKImplGliMode -Scope Global -ErrorAction SilentlyContinue
    Remove-Module ForensiKit -ErrorAction SilentlyContinue
}

Describe 'Export-FKEventLog 實作細節（T04）' -Tag 'T04' {

    BeforeEach {
        $global:FKImplCalls = New-Object System.Collections.ArrayList
        $global:FKImplGliCount = 4
        $global:FKImplGliMode = 'ok'
        Mock wevtutil -ModuleName ForensiKit $script:fakeWevtutil
        # 計數改用 wevtutil gli（#29），不應再逐筆讀 Get-WinEvent
        Mock Get-WinEvent -ModuleName ForensiKit { throw 'Get-WinEvent should not be used for counting' }
        $script:dest = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    }

    Context '時段條件' {

        It 'XPath 使用毫秒格式，起訖都含（>= 與 <=）' {
            Export-FKEventLog -StartUtc $script:start -EndUtc $script:end -Destination $script:dest -Channels 'Security' | Out-Null
            $q = @(Get-EplCall)[0] | Where-Object { $_ -like '/q:*' }
            $q | Should -Be "/q:*[System[TimeCreated[@SystemTime>='2026-11-20T01:00:00.000Z' and @SystemTime<='2026-11-20T03:00:00.999Z']]]"
        }

        It 'Kind = Local 的時間先轉成 UTC' {
            Export-FKEventLog -StartUtc $script:start.ToLocalTime() -EndUtc $script:end.ToLocalTime() -Destination $script:dest -Channels 'Security' | Out-Null
            ((@(Get-EplCall)[0]) -join ' ') | Should -Match ([regex]::Escape("@SystemTime>='2026-11-20T01:00:00.000Z'"))
        }

        It 'Kind = Unspecified 的時間視為 UTC（不做時區換算）' {
            $s = New-Object datetime 2026, 11, 20, 1, 0, 0, ([DateTimeKind]::Unspecified)
            $e = New-Object datetime 2026, 11, 20, 2, 0, 0, ([DateTimeKind]::Unspecified)
            Export-FKEventLog -StartUtc $s -EndUtc $e -Destination $script:dest -Channels 'Security' | Out-Null
            ((@(Get-EplCall)[0]) -join ' ') | Should -Match ([regex]::Escape("@SystemTime<='2026-11-20T02:00:00.000Z'"))
        }

        It '毫秒以下：起點捨去、終點進位，邊界上的事件不會漏掉' {
            $s = $script:start.AddTicks(1234)    # 01:00:00.0001234
            $e = $script:start.AddTicks(4567890) # 01:00:00.4567890
            Export-FKEventLog -StartUtc $s -EndUtc $e -Destination $script:dest -Channels 'Security' | Out-Null
            $line = (@(Get-EplCall)[0]) -join ' '
            $line | Should -Match ([regex]::Escape("@SystemTime>='2026-11-20T01:00:00.000Z'"))
            $line | Should -Match ([regex]::Escape("@SystemTime<='2026-11-20T01:00:00.457Z'"))
        }

        It 'StartUtc 等於 EndUtc 時不 throw' {
            { Export-FKEventLog -StartUtc $script:start -EndUtc $script:start -Destination $script:dest -Channels 'Security' } | Should -Not -Throw
        }
    }

    Context '現行 log 的輸出與結果' {

        It 'Destination 不存在時自動建立，輸出在 live\ 之下' {
            $r = Export-FKEventLog -StartUtc $script:start -EndUtc $script:end -Destination $script:dest -Channels 'Microsoft-Windows-Sysmon/Operational'
            $r.Path | Should -Be (Join-Path $script:dest 'live\Microsoft-Windows-Sysmon%4Operational.evtx')
            $r.Path | Should -Exist
            $r.EventCount | Should -Be 4
        }

        It 'EventCount 來自 wevtutil gli <輸出檔> /lf:true 的 numberOfLogRecords，不使用 Get-WinEvent' {
            $global:FKImplGliCount = 123456
            $r = Export-FKEventLog -StartUtc $script:start -EndUtc $script:end -Destination $script:dest -Channels 'Security'
            $r.EventCount | Should -Be 123456
            $gli = @($global:FKImplCalls | Where-Object { $_[0] -eq 'gli' })
            $gli.Count | Should -Be 1
            $gli[0][1] | Should -Be $r.Path
            $gli[0][2] | Should -Be '/lf:true'
            Should -Invoke Get-WinEvent -ModuleName ForensiKit -Times 0 -Exactly -Scope It
        }

        It '時段內沒有事件（numberOfLogRecords: 0）時 EventCount = 0、Status = OK' {
            $global:FKImplGliCount = 0
            $r = Export-FKEventLog -StartUtc $script:start -EndUtc $script:end -Destination $script:dest -Channels 'Security'
            $r.EventCount | Should -Be 0
            $r.Status | Should -Be 'OK'
        }

        It '匯出成功但 wevtutil gli 失敗時 Status = Partial、EventCount = $null，action log 記錄原因' {
            Mock Write-FKAction -ModuleName ForensiKit { }
            $global:FKImplGliMode = 'fail'
            $r = Export-FKEventLog -StartUtc $script:start -EndUtc $script:end -Destination $script:dest -Channels 'Security'
            $r.Status | Should -Be 'Partial'
            $r.EventCount | Should -BeNullOrEmpty
            $r.Path | Should -Exist
            Should -Invoke Write-FKAction -ModuleName ForensiKit -Scope It -ParameterFilter { $Status -eq 'Partial' -and $Detail -match 'wevtutil gli' -and $Detail -match 'exit 2' }
        }

        It 'wevtutil gli 的輸出沒有 numberOfLogRecords 時 Status = Partial' {
            $global:FKImplGliMode = 'garbled'
            (Export-FKEventLog -StartUtc $script:start -EndUtc $script:end -Destination $script:dest -Channels 'Security').Status | Should -Be 'Partial'
        }

        It '略過與失敗的 channel：Path 與 EventCount 為 $null' {
            $r = @(Export-FKEventLog -StartUtc $script:start -EndUtc $script:end -Destination $script:dest -Channels 'FK-Missing', 'FK-Denied')
            foreach ($item in $r) {
                $item.Path | Should -BeNullOrEmpty
                $item.EventCount | Should -BeNullOrEmpty
            }
            @($r.Status) | Should -Be @('Skipped', 'Failed')
        }

        It '重複的 channel 只匯出一次' {
            $r = @(Export-FKEventLog -StartUtc $script:start -EndUtc $script:end -Destination $script:dest -Channels 'Security', 'Security')
            $r.Count | Should -Be 1
            @(Get-EplCall).Count | Should -Be 1
        }

        It '已開啟 action log 時，每個 channel 寫一行，detail 含完整的 wevtutil 命令列' {
            $pkg = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $pkg | Out-Null
            $log = InModuleScope ForensiKit -Parameters @{ Root = $pkg } { param($Root) Open-FKActionLog -PackageRoot $Root }
            try {
                Export-FKEventLog -StartUtc $script:start -EndUtc $script:end -Destination (Join-Path $pkg 'evtx') -Channels 'Security', 'FK-Missing' | Out-Null
            }
            finally {
                InModuleScope ForensiKit { Close-FKActionLog }
            }
            $lines = @([System.IO.File]::ReadAllLines($log, [System.Text.Encoding]::UTF8) | ForEach-Object { $_ | ConvertFrom-Json })
            $lines.Count | Should -Be 2
            $lines[0].action | Should -Be 'ExportEventLog'
            $lines[0].status | Should -Be 'OK'
            $lines[0].detail | Should -Match '^wevtutil epl Security .*Security\.evtx "/q:\*\[System\[TimeCreated'
            $lines[0].detail | Should -Match 'wevtutil gli .*Security\.evtx /lf:true'
            $lines[1].target | Should -Be 'FK-Missing'
            $lines[1].status | Should -Be 'Skipped'
        }
    }

    Context 'Vault' {

        BeforeEach {
            $script:vaultRoot = Join-Path $TestDrive ('vault-' + [guid]::NewGuid().ToString('N'))
            Mock Get-FKConfig -ModuleName ForensiKit { New-ImplConfig -Channels 'Security' -VaultRoot $script:vaultRoot }
        }

        It '依備份時間略過一定不含此時段的備份（安全邊界 60 分鐘）' {
            # 時段 01:00–03:00
            New-VaultBackup -Root $script:vaultRoot -Channel 'Security' -Names @(
                '20261119T220000Z.evtx'   # +60 分 = 23:00 < 01:00 → 太舊，略過
                '20261120T000500Z.evtx'   # +60 分 = 01:05 ≥ 01:00 → 匯出
                '20261120T020000Z.evtx'   # 時段內 → 匯出
                '20261120T040000Z.evtx'   # 上一份 02:00 − 60 分 = 01:00 ≤ 03:00 → 匯出（含 02:00 之後的事件）
                '20261120T050000Z.evtx'   # 上一份 04:00 − 60 分 = 03:00，不晚於 03:00 → 匯出（邊界）
                '20261120T060000Z.evtx'   # 上一份 05:00 − 60 分 = 04:00 > 03:00 → 太新，略過
            )
            $r = @(Export-FKEventLog -StartUtc $script:start -EndUtc $script:end -Destination $script:dest -Channels 'Security' -IncludeVault)
            $sources = @(Get-EplCall | Where-Object { $_ -contains '/lf:true' } | ForEach-Object { Split-Path -Leaf $_[1] })
            $sources | Should -Be @('20261120T000500Z.evtx', '20261120T020000Z.evtx', '20261120T040000Z.evtx', '20261120T050000Z.evtx')

            $v = $r | Where-Object { $_.Source -eq 'Vault' }
            $v.Status | Should -Be 'OK'
            $v.EventCount | Should -Be 16
            $v.Path | Should -Be (Join-Path $script:dest 'vault\Security')
        }

        It '檔名不是備份時間格式的檔案無法判斷，一律匯出' {
            New-VaultBackup -Root $script:vaultRoot -Channel 'Security' -Names @('manual-copy.evtx', '20261101T000000Z.evtx')
            Export-FKEventLog -StartUtc $script:start -EndUtc $script:end -Destination $script:dest -Channels 'Security' -IncludeVault | Out-Null
            $sources = @(Get-EplCall | Where-Object { $_ -contains '/lf:true' } | ForEach-Object { Split-Path -Leaf $_[1] })
            $sources | Should -Be @('manual-copy.evtx')
        }

        It '只取 *.evtx（vault 根目錄的 action_log.jsonl 等不理會）' {
            New-VaultBackup -Root $script:vaultRoot -Channel 'Security' -Names @('20261120T020000Z.evtx', 'notes.txt')
            [System.IO.File]::WriteAllText((Join-Path $script:vaultRoot 'action_log.jsonl'), '')
            Export-FKEventLog -StartUtc $script:start -EndUtc $script:end -Destination $script:dest -Channels 'Security' -IncludeVault | Out-Null
            @(Get-EplCall | Where-Object { $_ -contains '/lf:true' }).Count | Should -Be 1
        }

        It '帶 / 的 channel 在 vault 中用 %4 目錄名稱' {
            Mock Get-FKConfig -ModuleName ForensiKit { New-ImplConfig -Channels 'Microsoft-Windows-Sysmon/Operational' -VaultRoot $script:vaultRoot }
            New-VaultBackup -Root $script:vaultRoot -Channel 'Microsoft-Windows-Sysmon%4Operational' -Names @('20261120T020000Z.evtx')
            $r = @(Export-FKEventLog -StartUtc $script:start -EndUtc $script:end -Destination $script:dest -IncludeVault)
            $v = $r | Where-Object { $_.Source -eq 'Vault' }
            $v.Status | Should -Be 'OK'
            (Join-Path $script:dest 'vault\Microsoft-Windows-Sysmon%4Operational\20261120T020000Z.evtx') | Should -Exist
        }

        It '部分備份匯出失敗時 Status = Partial，EventCount 只加總成功的' {
            New-VaultBackup -Root $script:vaultRoot -Channel 'Security' -Names @('20261120T020000Z.evtx')
            # 檔名含 bad-backup 的會失敗；放在可解析時間之外，一律匯出
            New-VaultBackup -Root $script:vaultRoot -Channel 'Security' -Names @('bad-backup.evtx')
            $v = @(Export-FKEventLog -StartUtc $script:start -EndUtc $script:end -Destination $script:dest -Channels 'Security' -IncludeVault) | Where-Object { $_.Source -eq 'Vault' }
            $v.Status | Should -Be 'Partial'
            $v.EventCount | Should -Be 4
        }

        It '所有備份都在時段外時 Status = OK、EventCount = 0、Path = $null' {
            New-VaultBackup -Root $script:vaultRoot -Channel 'Security' -Names @('20261101T000000Z.evtx')
            $v = @(Export-FKEventLog -StartUtc $script:start -EndUtc $script:end -Destination $script:dest -Channels 'Security' -IncludeVault) | Where-Object { $_.Source -eq 'Vault' }
            $v.Status | Should -Be 'OK'
            $v.EventCount | Should -Be 0
            $v.Path | Should -BeNullOrEmpty
        }

        It 'vault 不存在（尚未安裝常駐保全）時 Status = Skipped，不 throw' {
            $r = @(Export-FKEventLog -StartUtc $script:start -EndUtc $script:end -Destination $script:dest -Channels 'Security' -IncludeVault)
            ($r | Where-Object { $_.Source -eq 'Vault' }).Status | Should -Be 'Skipped'
            ($r | Where-Object { $_.Source -eq 'Live' }).Status | Should -Be 'OK'
        }
    }
}

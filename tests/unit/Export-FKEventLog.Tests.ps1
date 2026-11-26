<#
    T11：Export-FKEventLog（T04）單元測試，依契約第 3、4、7 節與 TASKS.md T04。

    不碰真實事件記錄：wevtutil 與 Get-WinEvent 都以 Mock 取代。
    對實作的要求：請以 `wevtutil` 或 `wevtutil.exe` 名稱呼叫（不要用完整路徑），Mock 才攔得到。

    假的 wevtutil 行為：
      - 'FK-Missing/Channel'：channel 不存在（exit code 15007，Get-WinEvent -ListLog 也 throw）
      - 'FK-Denied/Channel' ：channel 存在，但 epl 失敗（exit code 5）
      - 其他 channel / 檔案 ：epl 成功並在目的地建立檔案
    假的 Get-WinEvent -Path 一律回傳 3 筆事件。
#>

BeforeDiscovery {
    . "$PSScriptRoot/_TestHelpers.ps1"
    $skip = -not (Test-FKCommandAvailable -Name 'Export-FKEventLog')
}

BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    Import-FKModuleUnderTest | Out-Null

    $script:start = New-FKUtcDate 2026 11 20 1 2 3
    $script:end = New-FKUtcDate 2026 11 20 4 5 6

    # 假 wevtutil 把每次呼叫的參數記在全域清單，兩種呼叫名稱（wevtutil / wevtutil.exe）都能一起檢查
    $script:fakeWevtutil = {
        [void]$global:FKTestWevtutilCalls.Add([string[]]@($args | ForEach-Object { [string]$_ }))
        $verb = [string]$args[0]
        $source = [string]$args[1]
        if ($source -eq 'FK-Missing/Channel') {
            $global:LASTEXITCODE = 15007
            return 'Failed to open channel. The specified channel could not be found.'
        }
        if ($verb -eq 'gl' -or $verb -eq 'get-log') {
            $global:LASTEXITCODE = 0
            return @("name: $source", 'enabled: true', 'type: Admin')
        }
        if ($verb -eq 'epl' -or $verb -eq 'export-log') {
            if ($source -eq 'FK-Denied/Channel') {
                $global:LASTEXITCODE = 5
                return 'Failed to export log. Access is denied.'
            }
            $dest = [string]$args[2]
            $dir = Split-Path -Parent $dest
            if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            [System.IO.File]::WriteAllText($dest, 'fake-evtx')
            $global:LASTEXITCODE = 0
            return
        }
        $global:LASTEXITCODE = 0
    }

    function Get-EplCall {
        <# 回傳所有 epl 呼叫的參數（每筆為 string[]） #>
        @($global:FKTestWevtutilCalls | Where-Object { $_[0] -eq 'epl' -or $_[0] -eq 'export-log' })
    }
}

AfterAll {
    Remove-Variable -Name FKTestWevtutilCalls -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Export-FKEventLog' -Tag 'T04' -Skip:$skip {

    BeforeEach {
        $global:FKTestWevtutilCalls = New-Object System.Collections.ArrayList
        Mock wevtutil -ModuleName ForensiKit $script:fakeWevtutil
        Mock wevtutil.exe -ModuleName ForensiKit $script:fakeWevtutil
        Mock Get-WinEvent -ModuleName ForensiKit -ParameterFilter { $null -ne $ListLog } {
            if ($ListLog -contains 'FK-Missing/Channel') { throw 'There is not an event log on the localhost computer that matches "FK-Missing/Channel".' }
            [pscustomobject]@{ LogName = $ListLog[0]; RecordCount = 10; IsEnabled = $true; FileSize = 1024 }
        }
        Mock Get-WinEvent -ModuleName ForensiKit -ParameterFilter { $null -ne $Path } {
            1..3 | ForEach-Object { [pscustomobject]@{ Id = 4624; TimeCreated = (Get-Date) } }
        }
        if (Get-Command Write-FKAction -Module ForensiKit -ErrorAction SilentlyContinue) { Mock Write-FKAction -ModuleName ForensiKit { } }

        $dest = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dest | Out-Null
        $channels = @('Security', 'Microsoft-Windows-Sysmon/Operational')
    }

    Context '現行 log 匯出（Live）' {

        It '每個 channel 回傳一筆結果，含 Channel、Source、Path、EventCount、Status' {
            $r = @(Export-FKEventLog -StartUtc $script:start -EndUtc $script:end -Destination $dest -Channels $channels)
            $r.Count | Should -Be 2
            foreach ($item in $r) {
                $names = $item.PSObject.Properties.Name
                foreach ($p in 'Channel', 'Source', 'Path', 'EventCount', 'Status') { $names | Should -Contain $p }
                $item.Source | Should -Be 'Live'
                $item.Status | Should -Be 'OK'
            }
            @($r | ForEach-Object { $_.Channel }) | Should -Be $channels
        }

        It '輸出檔名把 / 改為 %4，且檔案位於 Destination 之下' {
            $r = @(Export-FKEventLog -StartUtc $script:start -EndUtc $script:end -Destination $dest -Channels $channels)
            $sysmon = $r | Where-Object { $_.Channel -eq 'Microsoft-Windows-Sysmon/Operational' }
            Split-Path -Leaf $sysmon.Path | Should -Be 'Microsoft-Windows-Sysmon%4Operational.evtx'
            $sysmon.Path | Should -Exist
            $fullDest = (Resolve-Path $dest).Path
            (Resolve-Path $sysmon.Path).Path.StartsWith($fullDest, [StringComparison]::OrdinalIgnoreCase) | Should -BeTrue
        }

        It '以 wevtutil epl 匯出，查詢條件含起訖時間（UTC）' {
            Export-FKEventLog -StartUtc $script:start -EndUtc $script:end -Destination $dest -Channels 'Security' | Out-Null
            $s = $script:start.ToString('yyyy-MM-ddTHH:mm:ss')
            $e = $script:end.ToString('yyyy-MM-ddTHH:mm:ss')
            $calls = @(Get-EplCall | Where-Object { $_[1] -eq 'Security' })
            $calls.Count | Should -Be 1
            $line = $calls[0] -join ' '
            $line | Should -Match 'SystemTime' -Because 'TASKS.md T04：以 TimeCreated/@SystemTime 篩選'
            $line | Should -Match ([regex]::Escape($s))
            $line | Should -Match ([regex]::Escape($e))
        }

        It 'EventCount 以 Get-WinEvent -Path 計算' {
            $r = @(Export-FKEventLog -StartUtc $script:start -EndUtc $script:end -Destination $dest -Channels 'Security')
            $r[0].EventCount | Should -Be 3
            Should -Invoke Get-WinEvent -ModuleName ForensiKit -ParameterFilter { $null -ne $Path } -Scope It
        }

        It '外部指令的完整命令列寫進 action log（CONTRIBUTING.md 第 5 節）' {
            Export-FKEventLog -StartUtc $script:start -EndUtc $script:end -Destination $dest -Channels 'Security' | Out-Null
            Should -Invoke Write-FKAction -ModuleName ForensiKit -ParameterFilter { $Detail -match 'wevtutil' -and $Detail -match 'Security' } -Scope It
        }
    }

    Context '錯誤處理（契約第 3 節：單一項目失敗不中斷）' {

        It 'channel 不存在時回傳 Skipped，不 throw，其他 channel 照常匯出' {
            $r = @(Export-FKEventLog -StartUtc $script:start -EndUtc $script:end -Destination $dest -Channels 'FK-Missing/Channel', 'Security')
            ($r | Where-Object { $_.Channel -eq 'FK-Missing/Channel' }).Status | Should -Be 'Skipped'
            ($r | Where-Object { $_.Channel -eq 'Security' }).Status | Should -Be 'OK'
        }

        It 'wevtutil 匯出失敗時回傳 Failed，不 throw，其他 channel 照常匯出' {
            $r = @(Export-FKEventLog -StartUtc $script:start -EndUtc $script:end -Destination $dest -Channels 'FK-Denied/Channel', 'Security')
            ($r | Where-Object { $_.Channel -eq 'FK-Denied/Channel' }).Status | Should -Be 'Failed'
            ($r | Where-Object { $_.Channel -eq 'Security' }).Status | Should -Be 'OK'
        }

        It '失敗與略過也要寫 action log' {
            Export-FKEventLog -StartUtc $script:start -EndUtc $script:end -Destination $dest -Channels 'FK-Missing/Channel', 'FK-Denied/Channel' | Out-Null
            Should -Invoke Write-FKAction -ModuleName ForensiKit -ParameterFilter { $Status -eq 'Skipped' } -Scope It
            Should -Invoke Write-FKAction -ModuleName ForensiKit -ParameterFilter { $Status -eq 'Failed' } -Scope It
        }

        It 'Status 只用契約允許的值' {
            $r = @(Export-FKEventLog -StartUtc $script:start -EndUtc $script:end -Destination $dest -Channels 'FK-Missing/Channel', 'FK-Denied/Channel', 'Security')
            foreach ($item in $r) { $script:FKStatusValues | Should -Contain $item.Status }
        }

        It 'StartUtc 晚於 EndUtc 時 throw（參數錯誤）' {
            { Export-FKEventLog -StartUtc $script:end -EndUtc $script:start -Destination $dest -Channels 'Security' } | Should -Throw
        }
    }

    Context '預設 channel' {

        It '未指定 -Channels 時，匯出 Get-FKConfig 設定中的 channel' {
            Mock Get-FKConfig -ModuleName ForensiKit { New-FKTestConfig -Channels 'Security', 'System' }
            $r = @(Export-FKEventLog -StartUtc $script:start -EndUtc $script:end -Destination $dest)
            @($r | Where-Object { $_.Source -eq 'Live' } | ForEach-Object { $_.Channel }) | Should -Be @('Security', 'System')
        }
    }

    Context 'Vault（-IncludeVault）' {

        BeforeEach {
            $vaultRoot = Join-Path $TestDrive ('vault-' + [guid]::NewGuid().ToString('N'))
            $backups = @('20261120T020000Z.evtx', '20261120T030000Z.evtx')
            foreach ($b in $backups) { Write-FKTestFile -Root $vaultRoot -RelativePath "Security/$b" -Content 'fake-backup' | Out-Null }
            Mock Get-FKConfig -ModuleName ForensiKit { New-FKTestConfig -Channels 'Security' -VaultRoot $vaultRoot }
        }

        It '沒有 -IncludeVault 時不回傳 Vault 結果，也不讀取備份檔' {
            $r = @(Export-FKEventLog -StartUtc $script:start -EndUtc $script:end -Destination $dest -Channels 'Security')
            @($r | Where-Object { $_.Source -eq 'Vault' }).Count | Should -Be 0
            @(Get-EplCall | Where-Object { ($_ -join ' ') -match '/lf:true' }).Count | Should -Be 0
        }

        It '有 -IncludeVault 時，對每個備份檔以 /lf:true 和相同時段匯出' {
            Export-FKEventLog -StartUtc $script:start -EndUtc $script:end -Destination $dest -Channels 'Security' -IncludeVault | Out-Null
            $s = $script:start.ToString('yyyy-MM-ddTHH:mm:ss')
            $e = $script:end.ToString('yyyy-MM-ddTHH:mm:ss')
            foreach ($b in $backups) {
                $calls = @(Get-EplCall | Where-Object { $_[1] -like "*\Security\$b" })
                $calls.Count | Should -Be 1 -Because "備份檔 $b 應以 wevtutil epl <file> 匯出一次"
                $line = $calls[0] -join ' '
                $line | Should -Match '/lf:true'
                $line | Should -Match ([regex]::Escape($s))
                $line | Should -Match ([regex]::Escape($e))
            }
        }

        It '回傳 Source = Vault 的結果，輸出在 vault/Security/ 之下且保留備份時間檔名' {
            $r = @(Export-FKEventLog -StartUtc $script:start -EndUtc $script:end -Destination $dest -Channels 'Security' -IncludeVault)
            $vault = @($r | Where-Object { $_.Source -eq 'Vault' })
            $vault.Count | Should -BeGreaterThan 0
            foreach ($v in $vault) {
                $v.Channel | Should -Be 'Security'
                $script:FKStatusValues | Should -Contain $v.Status
            }
            $exported = @(Get-ChildItem -LiteralPath $dest -Recurse -File | Where-Object { $_.FullName -match '\\vault\\Security\\' } | ForEach-Object { $_.Name })
            foreach ($b in $backups) { $exported | Should -Contain $b }
        }
    }

    Context '待確認（等實作或 PM 回覆後再啟用）' {

        It 'Vault 結果是「每個 channel 一筆」還是「每個備份檔一筆」' -Skip {
            # 契約寫「每個 channel 一筆」，但 vault 每個 channel 有多個備份檔，待 T04 / PM 確認
        }

        It '帶 / 的 channel 在 vault 中的「安全名稱」是否同樣用 %4' -Skip {
            # 契約第 5 節只寫 <Channel 安全名稱>，待 T06 確認
        }
    }
}

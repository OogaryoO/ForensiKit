<#
    T05：Get-FKArtifact 實作細節的測試（開發者補充；契約層級的測試見 QA 的 T11 Get-FKArtifact.Tests.ps1）。
    所有讀取系統狀態的 cmdlet 都 Mock 掉，不會在實體電腦上蒐證：
      Get-CimInstance、Get-NetTCPConnection、Get-NetUDPEndpoint、Get-DnsClientCache、Get-ScheduledTask、
      Get-ScheduledTaskInfo、Export-ScheduledTask、Get-ItemProperty、Get-ChildItem
    檔案只寫在 TestDrive。
#>

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..\..\src\ForensiKit\ForensiKit.psd1'
    Import-Module $script:ModulePath -Force -ErrorAction Stop

    $script:start = New-Object datetime 2026, 11, 20, 0, 0, 0, ([DateTimeKind]::Utc)
    $script:end = New-Object datetime 2026, 11, 20, 12, 0, 0, ([DateTimeKind]::Utc)
    $script:all7 = @('Prefetch', 'ScheduledTasks', 'Services', 'Autoruns', 'Processes', 'NetworkConnections', 'DnsCache')

    # 測試用的「可執行檔」，用來驗證 SHA-256
    $script:binDir = Join-Path $TestDrive 'bin'
    New-Item -ItemType Directory -Path $script:binDir -Force | Out-Null
    $script:exeA = Join-Path $script:binDir 'evil tool.exe'
    [System.IO.File]::WriteAllText($script:exeA, 'not really an exe')
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $script:exeASha = -join ($sha.ComputeHash([System.IO.File]::ReadAllBytes($script:exeA)) | ForEach-Object { $_.ToString('x2') })
    $sha.Dispose()

    # 假的 Prefetch 檔案（LastWriteTimeUtc：時段前、起點、時段內、終點、時段後）
    $script:pfDir = Join-Path $TestDrive 'Prefetch'
    New-Item -ItemType Directory -Path $script:pfDir -Force | Out-Null
    $pfTimes = [ordered]@{
        'BEFORE.EXE-11111111.pf' = $script:start.AddSeconds(-1)
        'START.EXE-22222222.pf'  = $script:start
        'INSIDE.EXE-33333333.pf' = $script:start.AddHours(3)
        'END.EXE-44444444.pf'    = $script:end
        'AFTER.EXE-55555555.pf'  = $script:end.AddSeconds(1)
    }
    foreach ($k in $pfTimes.Keys) {
        $p = Join-Path $script:pfDir $k
        [System.IO.File]::WriteAllText($p, "pf $k")
        [System.IO.File]::SetLastWriteTimeUtc($p, $pfTimes[$k])
    }

    $script:startupDir = Join-Path $TestDrive 'Startup'
    New-Item -ItemType Directory -Path $script:startupDir -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $script:startupDir 'updater.cmd'), '@echo off')
    [System.IO.File]::WriteAllText((Join-Path $script:startupDir 'desktop.ini'), '[.ShellClassInfo]')

    function Set-ArtifactMock {
        Mock Write-FKAction -ModuleName ForensiKit { }
        Mock Get-CimInstance -ModuleName ForensiKit -ParameterFilter { $ClassName -eq 'Win32_Process' } {
            @(
                [pscustomobject]@{ ProcessId = 4321; ParentProcessId = 1000; Name = '惡意工具.exe'; ExecutablePath = $script:exeA; CommandLine = "`"$script:exeA`" -run"; CreationDate = (Get-Date '2026-11-20T08:00:00'); SessionId = 1 }
                [pscustomobject]@{ ProcessId = 4; ParentProcessId = 0; Name = 'System'; ExecutablePath = $null; CommandLine = $null; CreationDate = $null; SessionId = 0 }
            )
        }
        Mock Get-CimInstance -ModuleName ForensiKit -ParameterFilter { $ClassName -eq 'Win32_Service' } {
            @(
                [pscustomobject]@{ Name = 'EvilSvc'; DisplayName = 'Evil'; State = 'Running'; StartMode = 'Auto'; StartName = 'LocalSystem'; ServiceType = 'Own Process'; ProcessId = 4321; PathName = "`"$script:exeA`" --service"; Description = '' }
                [pscustomobject]@{ Name = 'Dnscache'; DisplayName = 'DNS Client'; State = 'Running'; StartMode = 'Auto'; StartName = 'NT AUTHORITY\NetworkService'; ServiceType = 'Share Process'; ProcessId = 1500; PathName = 'C:\Windows\system32\svchost.exe -k NetworkService -p'; Description = '' }
            )
        }
        Mock Get-NetTCPConnection -ModuleName ForensiKit {
            [pscustomobject]@{ LocalAddress = '10.0.0.5'; LocalPort = 49800; RemoteAddress = '203.0.113.9'; RemotePort = 443; State = 'Established'; OwningProcess = 4321; CreationTime = (Get-Date '2026-11-20T08:01:00') }
        }
        Mock Get-NetUDPEndpoint -ModuleName ForensiKit {
            [pscustomobject]@{ LocalAddress = '0.0.0.0'; LocalPort = 5353; OwningProcess = 4; CreationTime = $null }
        }
        Mock Get-DnsClientCache -ModuleName ForensiKit {
            @(
                [pscustomobject]@{ Entry = 'evil.example.com'; Name = 'evil.example.com'; Type = 1; Status = 0; Section = 1; TimeToLive = 300; DataLength = 4; Data = '203.0.113.9' }
                [pscustomobject]@{ Entry = 'x.example.com'; Name = 'x.example.com'; Type = 99; Status = 0; Section = 1; TimeToLive = 60; DataLength = 0; Data = '' }
            )
        }
        Mock Get-ScheduledTask -ModuleName ForensiKit {
            @(
                [pscustomobject]@{ TaskPath = '\'; TaskName = 'fk_updater'; State = 'Ready'; Author = 'attacker'; Description = ''; Date = '2026-11-20T08:02:00'
                    Actions = @([pscustomobject]@{ Execute = $script:exeA; Arguments = '/quiet'; WorkingDirectory = $null })
                    Triggers = @([pscustomobject]@{ Enabled = $true; StartBoundary = '2026-11-20T08:05:00' })
                    Principal = [pscustomobject]@{ UserId = 'SYSTEM'; RunLevel = 'Highest' }
                }
                [pscustomobject]@{ TaskPath = '\Microsoft\'; TaskName = 'Broken'; State = 'Disabled'; Author = $null; Description = $null; Date = $null; Actions = @(); Triggers = @(); Principal = $null }
            )
        }
        Mock Get-ScheduledTaskInfo -ModuleName ForensiKit { [pscustomobject]@{ LastRunTime = (Get-Date '2026-11-20T08:05:00'); NextRunTime = $null; LastTaskResult = 0 } }
        Mock Export-ScheduledTask -ModuleName ForensiKit { '<Task><Actions/></Task>' }
        Mock Get-ItemProperty -ModuleName ForensiKit { $null }
        Mock Get-ItemProperty -ModuleName ForensiKit -ParameterFilter { $LiteralPath -eq 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' } {
            [pscustomobject]@{ SecurityHealth = '%windir%\system32\SecurityHealthSystray.exe'; Evil = "`"$script:exeA`" /autorun"; PSPath = 'x'; PSParentPath = 'x'; PSChildName = 'Run'; PSDrive = 'HKLM'; PSProvider = 'Registry' }
        }
        Mock Get-ItemProperty -ModuleName ForensiKit -ParameterFilter { $LiteralPath -eq 'Registry::HKEY_USERS\S-1-5-21-1-2-3-1001\Software\Microsoft\Windows\CurrentVersion\RunOnce' } {
            [pscustomobject]@{ OtherUser = 'C:\Users\victim\AppData\Local\Temp\x.exe'; PSPath = 'x'; PSParentPath = 'x'; PSChildName = 'RunOnce'; PSDrive = $null; PSProvider = 'Registry' }
        }
        Mock Get-ItemProperty -ModuleName ForensiKit -ParameterFilter { $LiteralPath -like '*\Services\Dnscache\Parameters' } {
            [pscustomobject]@{ ServiceDll = '%SystemRoot%\System32\dnsrslvr.dll' }
        }
        Mock Get-ChildItem -ModuleName ForensiKit { @() }
        Mock Get-ChildItem -ModuleName ForensiKit -ParameterFilter { $LiteralPath -eq 'Registry::HKEY_USERS' } {
            @([pscustomobject]@{ PSChildName = 'S-1-5-21-1-2-3-1001' }, [pscustomobject]@{ PSChildName = 'S-1-5-21-1-2-3-1001_Classes' }, [pscustomobject]@{ PSChildName = '.DEFAULT' })
        }
        Mock Get-ChildItem -ModuleName ForensiKit -ParameterFilter { $LiteralPath -like ($env:ProgramData + '\*\Programs\StartUp') } {
            @(Get-Item -LiteralPath (Join-Path $script:startupDir 'updater.cmd'), (Join-Path $script:startupDir 'desktop.ini'))
        }
        Mock Get-ChildItem -ModuleName ForensiKit -ParameterFilter { $LiteralPath -like '*\Prefetch' } {
            @(New-Object System.IO.DirectoryInfo $script:pfDir).GetFiles('*.pf')
        }
    }

    function Read-Json([string]$Path) {
        # PS 5.1 的 ConvertFrom-Json 會把整個陣列當成一個物件輸出，這裡逐筆展開
        $o = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($i in $o) { $i }
    }
}

AfterAll {
    Remove-Module ForensiKit -ErrorAction SilentlyContinue
}

Describe 'Get-FKArtifact 實作細節（T05）' -Tag 'T05' {

    BeforeEach {
        Set-ArtifactMock
        $script:dest = Join-Path $TestDrive ('artifacts-' + [guid]::NewGuid().ToString('N'))
    }

    Context '整體' {

        It '未指定 -Name 時依序回傳 7 筆，都 OK，輸出檔名符合契約第 4 節' {
            $r = @(Get-FKArtifact -StartUtc $script:start -EndUtc $script:end -Destination $script:dest)
            @($r.Name) | Should -Be $script:all7
            foreach ($x in $r) { $x.Status | Should -Be 'OK' -Because $x.Name }
            $expected = @{ ScheduledTasks = 'scheduled_tasks.json'; Services = 'services.json'; Autoruns = 'autoruns.json'; Processes = 'processes.json'; NetworkConnections = 'network_connections.json'; DnsCache = 'dns_cache.json' }
            foreach ($k in $expected.Keys) {
                ($r | Where-Object Name -eq $k).Path | Should -Be (Join-Path $script:dest $expected[$k])
                ($r | Where-Object Name -eq $k).Path | Should -Exist
            }
            ($r | Where-Object Name -eq 'Prefetch').Path | Should -Be (Join-Path $script:dest 'prefetch')
        }

        It '-Name 指定子集合時只回傳那幾種' {
            $r = @(Get-FKArtifact -StartUtc $script:start -EndUtc $script:end -Destination $script:dest -Name DnsCache, Processes)
            @($r.Name) | Should -Be @('DnsCache', 'Processes')
            Should -Invoke Get-ScheduledTask -ModuleName ForensiKit -Times 0 -Exactly -Scope It
        }

        It '每種 artifact 都寫一筆 action log' {
            Get-FKArtifact -StartUtc $script:start -EndUtc $script:end -Destination $script:dest | Out-Null
            Should -Invoke Write-FKAction -ModuleName ForensiKit -Times 7 -Exactly -Scope It -ParameterFilter { $Action -eq 'CollectArtifact' }
        }

        It '單一 artifact 失敗時該筆 Failed，其他照常，不 throw' {
            Mock Get-DnsClientCache -ModuleName ForensiKit { throw 'DNS Client service is not running' }
            $r = @(Get-FKArtifact -StartUtc $script:start -EndUtc $script:end -Destination $script:dest)
            ($r | Where-Object Name -eq 'DnsCache').Status | Should -Be 'Failed'
            @($r | Where-Object { $_.Name -ne 'DnsCache' -and $_.Status -ne 'OK' }).Count | Should -Be 0
            Should -Invoke Write-FKAction -ModuleName ForensiKit -Scope It -ParameterFilter { $Target -eq 'DnsCache' -and $Status -eq 'Failed' }
        }

        It 'StartUtc 晚於 EndUtc 時 throw' {
            { Get-FKArtifact -StartUtc $script:end -EndUtc $script:start -Destination $script:dest } | Should -Throw
        }

        It '收集結果為空時 JSON 是 []' {
            Mock Get-DnsClientCache -ModuleName ForensiKit { @() }
            $r = Get-FKArtifact -StartUtc $script:start -EndUtc $script:end -Destination $script:dest -Name DnsCache
            $r.ItemCount | Should -Be 0
            [System.IO.File]::ReadAllText($r.Path).Trim() | Should -Be '[]'
        }
    }

    Context 'Prefetch' {

        It '只複製 LastWriteTimeUtc 落在 [StartUtc, EndUtc] 的 .pf（含兩端）' {
            $r = Get-FKArtifact -StartUtc $script:start -EndUtc $script:end -Destination $script:dest -Name Prefetch
            $r.ItemCount | Should -Be 3
            @(Get-ChildItem -LiteralPath $r.Path | ForEach-Object Name | Sort-Object) | Should -Be @('END.EXE-44444444.pf', 'INSIDE.EXE-33333333.pf', 'START.EXE-22222222.pf')
        }

        It 'Prefetch 目錄不存在時 Skipped' {
            Mock Get-ChildItem -ModuleName ForensiKit -ParameterFilter { $LiteralPath -like '*\Prefetch' } {
                throw (New-Object System.Management.Automation.ItemNotFoundException 'not found')
            }
            (Get-FKArtifact -StartUtc $script:start -EndUtc $script:end -Destination $script:dest -Name Prefetch).Status | Should -Be 'Skipped'
        }

        It '無法列出 Prefetch（例如非管理員）時 Failed' {
            Mock Get-ChildItem -ModuleName ForensiKit -ParameterFilter { $LiteralPath -like '*\Prefetch' } { throw (New-Object System.UnauthorizedAccessException 'Access denied') }
            (Get-FKArtifact -StartUtc $script:start -EndUtc $script:end -Destination $script:dest -Name Prefetch).Status | Should -Be 'Failed'
        }
    }

    Context '內容' {

        It 'processes.json：中文名稱、ISO UTC 時間、SHA-256；找不到的可執行檔為 null' {
            $r = Get-FKArtifact -StartUtc $script:start -EndUtc $script:end -Destination $script:dest -Name Processes
            $j = @(Read-Json $r.Path)
            $j[0].Name | Should -Be '惡意工具.exe'
            $j[0].Sha256 | Should -Be $script:exeASha
            $j[0].CreationDateUtc | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
            $j[1].Sha256 | Should -BeNullOrEmpty
        }

        It 'network_connections.json：TCP 與 UDP，並對應到行程名稱' {
            $j = @(Read-Json (Get-FKArtifact -StartUtc $script:start -EndUtc $script:end -Destination $script:dest -Name NetworkConnections).Path)
            $tcp = $j | Where-Object Protocol -eq 'TCP'
            $tcp.ProcessName | Should -Be '惡意工具.exe'
            $tcp.RemoteAddress | Should -Be '203.0.113.9'
            $tcp.State | Should -Be 'Established'
            ($j | Where-Object Protocol -eq 'UDP').ProcessName | Should -Be 'System'
        }

        It '行程清單只查一次（Processes 與 NetworkConnections 共用）' {
            Get-FKArtifact -StartUtc $script:start -EndUtc $script:end -Destination $script:dest -Name Processes, NetworkConnections | Out-Null
            Should -Invoke Get-CimInstance -ModuleName ForensiKit -Times 1 -Exactly -Scope It -ParameterFilter { $ClassName -eq 'Win32_Process' }
        }

        It 'UDP 讀取失敗時 Partial；TCP 與 UDP 都失敗時 Failed' {
            Mock Get-NetUDPEndpoint -ModuleName ForensiKit { throw 'udp failed' }
            (Get-FKArtifact -StartUtc $script:start -EndUtc $script:end -Destination $script:dest -Name NetworkConnections).Status | Should -Be 'Partial'
            Mock Get-NetTCPConnection -ModuleName ForensiKit { throw 'tcp failed' }
            (Get-FKArtifact -StartUtc $script:start -EndUtc $script:end -Destination (Join-Path $TestDrive ([guid]::NewGuid())) -Name NetworkConnections).Status | Should -Be 'Failed'
        }

        It 'dns_cache.json：常見的記錄類型轉成名稱，未知的保留數字' {
            $j = @(Read-Json (Get-FKArtifact -StartUtc $script:start -EndUtc $script:end -Destination $script:dest -Name DnsCache).Path)
            $j[0].RecordType | Should -Be 'A'
            $j[0].Data | Should -Be '203.0.113.9'
            $j[1].RecordType | Should -Be '99'
        }

        It 'scheduled_tasks.json：動作的可執行檔 SHA-256、執行資訊與完整 XML' {
            $j = @(Read-Json (Get-FKArtifact -StartUtc $script:start -EndUtc $script:end -Destination $script:dest -Name ScheduledTasks).Path)
            $t = $j | Where-Object TaskName -eq 'fk_updater'
            $t.Actions[0].Sha256 | Should -Be $script:exeASha
            $t.Actions[0].Arguments | Should -Be '/quiet'
            $t.UserId | Should -Be 'SYSTEM'
            $t.LastRunTimeUtc | Should -Match 'Z$'
            $t.Xml | Should -Be '<Task><Actions/></Task>'
            $t.PSObject.Properties.Name | Should -Not -Contain 'RegistrationDate'
        }

        It '排程註冊時間轉成 RegistrationDateUtc（沒有時區視為本地時間），原字串保留在 RegistrationDateRaw' {
            Mock Get-ScheduledTask -ModuleName ForensiKit {
                foreach ($d in '2026-11-20T08:02:00', '2026-11-20T08:02:00Z', '2026-11-20T08:02:00+08:00', 'not a date', $null) {
                    [pscustomobject]@{ TaskPath = '\'; TaskName = "t-$d"; State = 'Ready'; Author = $null; Description = $null; Date = $d; Actions = @(); Triggers = @(); Principal = $null }
                }
            }
            $j = @(Read-Json (Get-FKArtifact -StartUtc $script:start -EndUtc $script:end -Destination $script:dest -Name ScheduledTasks).Path)
            $localAsUtc = [datetime]::SpecifyKind((New-Object datetime 2026, 11, 20, 8, 2, 0), [DateTimeKind]::Local).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
            $j[0].RegistrationDateUtc | Should -Be $localAsUtc
            $j[0].RegistrationDateRaw | Should -Be '2026-11-20T08:02:00'
            $j[1].RegistrationDateUtc | Should -Be '2026-11-20T08:02:00Z'
            $j[2].RegistrationDateUtc | Should -Be '2026-11-20T00:02:00Z'
            $j[3].RegistrationDateUtc | Should -BeNullOrEmpty
            $j[3].RegistrationDateRaw | Should -Be 'not a date'
            $j[4].RegistrationDateUtc | Should -BeNullOrEmpty
        }

        It '某些排程匯不出 XML 時 Partial，仍輸出其他欄位' {
            Mock Export-ScheduledTask -ModuleName ForensiKit -ParameterFilter { $TaskName -eq 'Broken' } { throw 'access denied' }
            $r = Get-FKArtifact -StartUtc $script:start -EndUtc $script:end -Destination $script:dest -Name ScheduledTasks
            $r.Status | Should -Be 'Partial'
            $r.ItemCount | Should -Be 2
        }

        It 'services.json：有引號與參數的 PathName 解析出可執行檔；svchost 服務附 ServiceDll' {
            $j = @(Read-Json (Get-FKArtifact -StartUtc $script:start -EndUtc $script:end -Destination $script:dest -Name Services).Path)
            $evil = $j | Where-Object Name -eq 'EvilSvc'
            $evil.ExecutablePath | Should -Be $script:exeA
            $evil.Sha256 | Should -Be $script:exeASha
            ($j | Where-Object Name -eq 'Dnscache').ServiceDll | Should -Be (Join-Path $env:SystemRoot 'System32\dnsrslvr.dll')
        }

        It 'autoruns.json：HKLM Run、其他使用者的 RunOnce、Startup 資料夾；不含 PS* 屬性與 desktop.ini' {
            $r = Get-FKArtifact -StartUtc $script:start -EndUtc $script:end -Destination $script:dest -Name Autoruns
            $r.Status | Should -Be 'OK'
            $j = @(Read-Json $r.Path)
            @($j | ForEach-Object Name) | Should -Not -Contain 'PSPath'
            @($j | ForEach-Object Name) | Should -Not -Contain 'desktop.ini'
            ($j | Where-Object Name -eq 'Evil').Sha256 | Should -Be $script:exeASha
            ($j | Where-Object Name -eq 'SecurityHealth').ExecutablePath | Should -Be (Join-Path $env:windir 'system32\SecurityHealthSystray.exe')
            ($j | Where-Object Name -eq 'OtherUser').Location | Should -BeLike 'Registry::HKEY_USERS\S-1-5-21-1-2-3-1001\*\RunOnce'
            ($j | Where-Object Name -eq 'updater.cmd').Type | Should -Be 'StartupFolder'
            ($j | Where-Object Name -eq 'updater.cmd').LastWriteTimeUtc | Should -Match 'Z$'
        }

        It '自啟項涵蓋 HKLM（含 WOW6432Node）與 HKCU 的 Run、RunOnce，以及 HKU 中其他使用者（不含 _Classes）' {
            Get-FKArtifact -StartUtc $script:start -EndUtc $script:end -Destination $script:dest -Name Autoruns | Out-Null
            foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
                'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce') {
                Should -Invoke Get-ItemProperty -ModuleName ForensiKit -Scope It -ParameterFilter { $LiteralPath -eq $k } -Because $k
            }
            Should -Invoke Get-ItemProperty -ModuleName ForensiKit -Times 0 -Exactly -Scope It -ParameterFilter { $LiteralPath -like '*_Classes*' }
        }
    }
}

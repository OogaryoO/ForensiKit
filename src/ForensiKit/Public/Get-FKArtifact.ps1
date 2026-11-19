function Get-FKArtifact {
    <#
    .SYNOPSIS
        收集 7 種執行痕跡與系統狀態快照（Prefetch、排程、服務、自啟項、行程、網路連線、DNS 快取）。

    .DESCRIPTION
        輸出位置（docs/ARCHITECTURE.md 第 4 節），Destination 是證據包中的 artifacts 目錄：
          Prefetch           → <Destination>\prefetch\*.pf（只複製 LastWriteTimeUtc 落在 [StartUtc, EndUtc] 的檔案，含邊界）
          ScheduledTasks     → scheduled_tasks.json
          Services           → services.json
          Autoruns           → autoruns.json
          Processes          → processes.json
          NetworkConnections → network_connections.json
          DnsCache           → dns_cache.json
        除了 Prefetch，其他都是「收集當下的狀態快照」，不依時段篩選（契約第 7 節）；時間欄位一律為 ISO 8601 UTC 字串。
        JSON 為 UTF-8（無 BOM）的陣列。可執行檔附 SHA-256（小寫），檔案不存在、路徑不完整或無權限時為 null，不中斷。

        資料來源（單元測試可 Mock 這些 cmdlet）：
          Processes          Get-CimInstance -ClassName Win32_Process
          NetworkConnections Get-NetTCPConnection、Get-NetUDPEndpoint（行程名稱由 Win32_Process 對應）
          DnsCache           Get-DnsClientCache
          ScheduledTasks     Get-ScheduledTask、Get-ScheduledTaskInfo、Export-ScheduledTask（完整 XML）
          Services           Get-CimInstance -ClassName Win32_Service；svchost 服務另以 Get-ItemProperty 讀 Parameters\ServiceDll
          Autoruns           Get-ItemProperty 讀 HKLM（含 WOW6432Node）、HKCU 與所有已載入使用者（HKEY_USERS\S-1-5-21-*）的 Run／RunOnce；
                             Get-ChildItem 列出 ProgramData 與每個使用者設定檔的 Startup 資料夾（.lnk 以 WScript.Shell 解析目標）
          Prefetch           Get-ChildItem <SystemRoot>\Prefetch、Copy-Item

        錯誤處理（契約第 3 節）：單一 artifact 失敗 → 該筆 Status = Failed，其他照常收集，不 throw；
        部分來源失敗（例如 UDP 讀不到、某些排程匯不出 XML、部分 .pf 複製失敗）→ Partial；Prefetch 目錄不存在 → Skipped。
        每種 artifact 都寫一筆 action log（CollectArtifact）。

    .PARAMETER StartUtc
        時段起點（UTC，含）。只用於 Prefetch。Kind = Local 的時間會先轉成 UTC；Kind = Unspecified 視為 UTC。

    .PARAMETER EndUtc
        時段終點（UTC，含）。不得早於 StartUtc。

    .PARAMETER Destination
        證據包中的 artifacts 目錄，例如 <PackageRoot>\artifacts。不存在時自動建立。

    .PARAMETER Name
        要收集的 artifact，省略時收集全部 7 種：Prefetch、ScheduledTasks、Services、Autoruns、Processes、NetworkConnections、DnsCache。

    .OUTPUTS
        每種 artifact 一筆 [pscustomobject]：Name、Path、ItemCount、Status。

    .EXAMPLE
        Get-FKArtifact -StartUtc $start -EndUtc $end -Destination "$pkg\artifacts"

    .EXAMPLE
        Get-FKArtifact -StartUtc $start -EndUtc $end -Destination "$pkg\artifacts" -Name Processes, NetworkConnections
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [datetime]$StartUtc,

        [Parameter(Mandatory)]
        [datetime]$EndUtc,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Destination,

        [Parameter()]
        [ValidateSet('Prefetch', 'ScheduledTasks', 'Services', 'Autoruns', 'Processes', 'NetworkConnections', 'DnsCache')]
        [string[]]$Name = @('Prefetch', 'ScheduledTasks', 'Services', 'Autoruns', 'Processes', 'NetworkConnections', 'DnsCache')
    )

    # ---------------- 內部輔助 ----------------

    function ConvertTo-FKUtcKind {
        param([datetime]$Date)
        if ($Date.Kind -eq [System.DateTimeKind]::Local) { return $Date.ToUniversalTime() }
        return [datetime]::SpecifyKind($Date, [System.DateTimeKind]::Utc)
    }

    function ConvertTo-FKIsoOrNull {
        param($Value)
        if ($Value -is [datetime] -and $Value -ne [datetime]::MinValue) { return (ConvertTo-FKIsoUtc -Date $Value) }
        return $null
    }

    function Get-FKSha256OrNull {
        # 可執行檔的 SHA-256（小寫）；路徑不完整、不存在或無權限時回傳 $null。同一路徑只計算一次。
        param([string]$Path)
        if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
        try { if (-not [System.IO.Path]::IsPathRooted($Path)) { return $null } } catch { return $null }
        if ($hashCache.ContainsKey($Path)) { return $hashCache[$Path] }
        $h = $null
        try {
            if ([System.IO.File]::Exists($Path)) {
                $sha = [System.Security.Cryptography.SHA256]::Create()
                $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                try { $h = -join ($sha.ComputeHash($fs) | ForEach-Object { $_.ToString('x2') }) }
                finally { $fs.Dispose(); $sha.Dispose() }
            }
        }
        catch { $h = $null }
        $hashCache[$Path] = $h
        return $h
    }

    function Resolve-FKExecutablePath {
        # 從命令列（服務 PathName、Run 值、排程動作）取出可執行檔路徑。
        param([string]$CommandLine)
        if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $null }
        $s = [System.Environment]::ExpandEnvironmentVariables($CommandLine.Trim())
        if ($s.StartsWith('\??\')) { $s = $s.Substring(4) }
        if ($s -match '^(?i)\\SystemRoot\\') { $s = $env:SystemRoot + $s.Substring(11) }
        elseif ($s -match '^(?i)system32\\') { $s = Join-Path $env:SystemRoot $s }
        if ($s.StartsWith('"')) {
            $close = $s.IndexOf('"', 1)
            if ($close -gt 1) { return $s.Substring(1, $close - 1) }
            return $s.Trim('"')
        }
        # 沒有引號：逐段加長，找到存在的檔案為止（處理路徑中有空白的情況）
        $tokens = $s -split ' '
        $candidate = ''
        for ($i = 0; $i -lt $tokens.Count; $i++) {
            if ($i -eq 0) { $candidate = $tokens[0] } else { $candidate = $candidate + ' ' + $tokens[$i] }
            if ($candidate -match '(?i)\.(exe|dll|sys|com|bat|cmd|ps1|vbs|js|scr|cpl)$') {
                try { if ([System.IO.File]::Exists($candidate)) { return $candidate } } catch { $null = $_ }
            }
        }
        $m = [regex]::Match($s, '^(.+?\.(exe|dll|sys|com|bat|cmd|ps1|vbs|js|scr|cpl))(\s|,|$)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($m.Success) { return $m.Groups[1].Value }
        return $tokens[0]
    }

    function Write-FKJsonFile {
        param([string]$Path, [object[]]$Items)
        # PS 5.1 的 ConvertTo-Json 遇到空陣列會輸出空字串，所以自己寫 []
        if ($Items.Count -eq 0) { $json = '[]' } else { $json = ConvertTo-Json -InputObject $Items -Depth 6 }
        [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
    }

    function Get-FKProcessList {
        # Processes 與 NetworkConnections 共用，同一次呼叫只查一次
        # （$processCache 是外層的 hashtable，巢狀函式才能共用同一份）
        if ($null -eq $processCache.List) { $processCache.List = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop) }
        return $processCache.List
    }

    # ---------------- 各 artifact ----------------

    function Get-FKProcessItem {
        $items = @(foreach ($p in (Get-FKProcessList)) {
                [ordered]@{
                    ProcessId       = $p.ProcessId
                    ParentProcessId = $p.ParentProcessId
                    Name            = $p.Name
                    ExecutablePath  = $p.ExecutablePath
                    CommandLine     = $p.CommandLine
                    CreationDateUtc = ConvertTo-FKIsoOrNull $p.CreationDate
                    SessionId       = $p.SessionId
                    Sha256          = Get-FKSha256OrNull $p.ExecutablePath
                }
            })
        return [pscustomobject]@{ Items = $items; Notes = @(); Source = 'Get-CimInstance Win32_Process' }
    }

    function Get-FKNetworkItem {
        $notes = New-Object System.Collections.Generic.List[string]
        $byPid = @{}
        try { foreach ($p in (Get-FKProcessList)) { $byPid[[int]$p.ProcessId] = $p } }
        catch { $notes.Add("無法對應行程名稱：$($_.Exception.Message)") }

        $items = New-Object System.Collections.Generic.List[object]
        $ok = 0
        try {
            foreach ($c in @(Get-NetTCPConnection -ErrorAction Stop)) {
                $p = $byPid[[int]$c.OwningProcess]
                $items.Add([ordered]@{
                        Protocol        = 'TCP'
                        LocalAddress    = $c.LocalAddress
                        LocalPort       = $c.LocalPort
                        RemoteAddress   = $c.RemoteAddress
                        RemotePort      = $c.RemotePort
                        State           = [string]$c.State
                        OwningProcess   = $c.OwningProcess
                        ProcessName     = $(if ($p) { $p.Name } else { $null })
                        ProcessPath     = $(if ($p) { $p.ExecutablePath } else { $null })
                        CreationTimeUtc = ConvertTo-FKIsoOrNull $c.CreationTime
                    })
            }
            $ok++
        }
        catch { $notes.Add("TCP：$($_.Exception.Message)") }
        try {
            foreach ($u in @(Get-NetUDPEndpoint -ErrorAction Stop)) {
                $p = $byPid[[int]$u.OwningProcess]
                $items.Add([ordered]@{
                        Protocol        = 'UDP'
                        LocalAddress    = $u.LocalAddress
                        LocalPort       = $u.LocalPort
                        RemoteAddress   = $null
                        RemotePort      = $null
                        State           = $null
                        OwningProcess   = $u.OwningProcess
                        ProcessName     = $(if ($p) { $p.Name } else { $null })
                        ProcessPath     = $(if ($p) { $p.ExecutablePath } else { $null })
                        CreationTimeUtc = ConvertTo-FKIsoOrNull $u.CreationTime
                    })
            }
            $ok++
        }
        catch { $notes.Add("UDP：$($_.Exception.Message)") }
        if ($ok -eq 0) { throw ('TCP 與 UDP 都讀取失敗：' + ($notes -join '；')) }
        return [pscustomobject]@{ Items = $items.ToArray(); Notes = $notes.ToArray(); Source = 'Get-NetTCPConnection、Get-NetUDPEndpoint' }
    }

    function Get-FKDnsItem {
        $typeNames = @{ 1 = 'A'; 2 = 'NS'; 5 = 'CNAME'; 6 = 'SOA'; 12 = 'PTR'; 15 = 'MX'; 16 = 'TXT'; 28 = 'AAAA'; 33 = 'SRV' }
        $items = @(foreach ($d in @(Get-DnsClientCache -ErrorAction Stop)) {
                $type = $null
                if ($null -ne $d.Type) {
                    $type = [string]$d.Type
                    if ($typeNames.ContainsKey([int]$d.Type)) { $type = $typeNames[[int]$d.Type] }
                }
                [ordered]@{
                    Entry      = $d.Entry
                    RecordName = $d.Name
                    RecordType = $type
                    Status     = $d.Status
                    Section    = $d.Section
                    TimeToLive = $d.TimeToLive
                    DataLength = $d.DataLength
                    Data       = $d.Data
                }
            })
        return [pscustomobject]@{ Items = $items; Notes = @(); Source = 'Get-DnsClientCache' }
    }

    function Get-FKScheduledTaskItem {
        $xmlFailed = 0
        $infoFailed = 0
        $items = @(foreach ($t in @(Get-ScheduledTask -ErrorAction Stop)) {
                $actions = @(foreach ($a in @($t.Actions)) {
                        $exe = Resolve-FKExecutablePath $a.Execute
                        [ordered]@{
                            Execute          = $a.Execute
                            Arguments        = $a.Arguments
                            WorkingDirectory = $a.WorkingDirectory
                            ClassId          = $a.ClassId
                            ExecutablePath   = $exe
                            Sha256           = Get-FKSha256OrNull $exe
                        }
                    })
                $triggers = @(foreach ($tr in @($t.Triggers)) {
                        $kind = $null
                        if ($tr.CimClass) { $kind = $tr.CimClass.CimClassName }
                        [ordered]@{ Type = $kind; Enabled = $tr.Enabled; StartBoundary = $tr.StartBoundary }
                    })
                $lastRun = $null; $nextRun = $null; $lastResult = $null
                try {
                    $info = Get-ScheduledTaskInfo -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop
                    $lastRun = ConvertTo-FKIsoOrNull $info.LastRunTime
                    $nextRun = ConvertTo-FKIsoOrNull $info.NextRunTime
                    $lastResult = $info.LastTaskResult
                }
                catch { $infoFailed++ }
                $xml = $null
                try { $xml = [string](Export-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop) }
                catch { $xmlFailed++ }
                $userId = $null; $runLevel = $null
                if ($t.Principal) { $userId = $t.Principal.UserId; $runLevel = [string]$t.Principal.RunLevel }
                [ordered]@{
                    TaskPath         = $t.TaskPath
                    TaskName         = $t.TaskName
                    State            = [string]$t.State
                    Author           = $t.Author
                    Description      = $t.Description
                    RegistrationDate = $t.Date
                    UserId           = $userId
                    RunLevel         = $runLevel
                    LastRunTimeUtc   = $lastRun
                    NextRunTimeUtc   = $nextRun
                    LastTaskResult   = $lastResult
                    Actions          = $actions
                    Triggers         = $triggers
                    Xml              = $xml
                }
            })
        $notes = @()
        if ($xmlFailed -gt 0) { $notes += "$xmlFailed 個排程無法匯出 XML" }
        if ($infoFailed -gt 0) { $notes += "$infoFailed 個排程無法讀取執行資訊" }
        return [pscustomobject]@{ Items = $items; Notes = $notes; Source = 'Get-ScheduledTask、Get-ScheduledTaskInfo、Export-ScheduledTask' }
    }

    function Get-FKServiceItem {
        $items = @(foreach ($s in @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop)) {
                $exe = Resolve-FKExecutablePath $s.PathName
                $dll = $null
                if ($s.PathName -match '(?i)svchost\.exe') {
                    $prop = Get-ItemProperty -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\{0}\Parameters' -f $s.Name) -Name 'ServiceDll' -ErrorAction SilentlyContinue
                    if ($prop -and $prop.ServiceDll) { $dll = [System.Environment]::ExpandEnvironmentVariables([string]$prop.ServiceDll) }
                }
                [ordered]@{
                    Name             = $s.Name
                    DisplayName      = $s.DisplayName
                    State            = $s.State
                    StartMode        = $s.StartMode
                    StartName        = $s.StartName
                    ServiceType      = $s.ServiceType
                    ProcessId        = $s.ProcessId
                    PathName         = $s.PathName
                    ExecutablePath   = $exe
                    Sha256           = Get-FKSha256OrNull $exe
                    ServiceDll       = $dll
                    ServiceDllSha256 = Get-FKSha256OrNull $dll
                    Description      = $s.Description
                }
            })
        return [pscustomobject]@{ Items = $items; Notes = @(); Source = 'Get-CimInstance Win32_Service、Get-ItemProperty（ServiceDll）' }
    }

    function Get-FKAutorunItem {
        $notes = New-Object System.Collections.Generic.List[string]
        $items = New-Object System.Collections.Generic.List[object]
        $psProps = @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider')

        $keys = New-Object System.Collections.Generic.List[string]
        foreach ($root in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion', 'HKCU:\Software\Microsoft\Windows\CurrentVersion') {
            $keys.Add("$root\Run"); $keys.Add("$root\RunOnce")
        }
        # 蒐證通常以系統管理員執行，HKCU 是操作者自己；其他已登入使用者的機碼在 HKEY_USERS 下
        $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        try {
            foreach ($u in @(Get-ChildItem -LiteralPath 'Registry::HKEY_USERS' -ErrorAction Stop)) {
                $sid = $u.PSChildName
                if ($sid -match '^S-1-5-21-[\d-]+$' -and $sid -ne $currentSid) {
                    $keys.Add("Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Run")
                    $keys.Add("Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\RunOnce")
                }
            }
        }
        catch { $notes.Add("無法列出 HKEY_USERS：$($_.Exception.Message)") }

        foreach ($key in $keys) {
            try { $props = Get-ItemProperty -LiteralPath $key -ErrorAction Stop }
            catch [System.Management.Automation.ItemNotFoundException] { continue }
            catch { $notes.Add("$key：$($_.Exception.Message)"); continue }
            if (-not $props) { continue }
            foreach ($pp in $props.PSObject.Properties) {
                if ($psProps -contains $pp.Name) { continue }
                $cmd = [string]$pp.Value
                $exe = Resolve-FKExecutablePath $cmd
                $items.Add([ordered]@{
                        Type             = 'Registry'
                        Location         = $key
                        Name             = $pp.Name
                        Command          = $cmd
                        ExecutablePath   = $exe
                        Sha256           = Get-FKSha256OrNull $exe
                        FileSha256       = $null
                        LastWriteTimeUtc = $null
                    })
            }
        }

        $folders = New-Object System.Collections.Generic.List[string]
        $folders.Add((Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\StartUp'))
        if ($env:APPDATA) { $folders.Add((Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup')) }
        $usersRoot = $null
        if ($env:PUBLIC) { $usersRoot = Split-Path -Parent $env:PUBLIC }
        if ($usersRoot) {
            try {
                foreach ($profileDir in @(Get-ChildItem -LiteralPath $usersRoot -Directory -ErrorAction Stop)) {
                    $f = Join-Path $profileDir.FullName 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
                    if (-not ($folders -contains $f)) { $folders.Add($f) }
                }
            }
            catch { $notes.Add("無法列出使用者設定檔：$($_.Exception.Message)") }
        }

        $shell = $null
        foreach ($folder in $folders) {
            try { $entries = @(Get-ChildItem -LiteralPath $folder -File -Force -ErrorAction Stop) }
            catch [System.Management.Automation.ItemNotFoundException] { continue }
            catch { $notes.Add("$folder：$($_.Exception.Message)"); continue }
            foreach ($e in $entries) {
                if ($e.Name -ieq 'desktop.ini') { continue }
                $cmd = $e.FullName
                $exe = $e.FullName
                if ($e.Extension -ieq '.lnk') {
                    try {
                        if (-not $shell) { $shell = New-Object -ComObject WScript.Shell }
                        $lnk = $shell.CreateShortcut($e.FullName)
                        $exe = $lnk.TargetPath
                        $cmd = ($lnk.TargetPath + ' ' + $lnk.Arguments).Trim()
                    }
                    catch { $notes.Add("無法解析捷徑 $($e.FullName)") }
                }
                $items.Add([ordered]@{
                        Type             = 'StartupFolder'
                        Location         = $folder
                        Name             = $e.Name
                        Command          = $cmd
                        ExecutablePath   = $exe
                        Sha256           = Get-FKSha256OrNull $exe
                        FileSha256       = Get-FKSha256OrNull $e.FullName
                        LastWriteTimeUtc = ConvertTo-FKIsoOrNull $e.LastWriteTimeUtc
                    })
            }
        }
        return [pscustomobject]@{ Items = $items.ToArray(); Notes = $notes.ToArray(); Source = 'Get-ItemProperty（Run/RunOnce）、Get-ChildItem（Startup 資料夾）' }
    }

    # ---------------- 主流程 ----------------

    $StartUtc = ConvertTo-FKUtcKind -Date $StartUtc
    $EndUtc = ConvertTo-FKUtcKind -Date $EndUtc
    if ($StartUtc -gt $EndUtc) {
        throw ("StartUtc（{0}）晚於 EndUtc（{1}）。" -f (ConvertTo-FKIsoUtc -Date $StartUtc), (ConvertTo-FKIsoUtc -Date $EndUtc))
    }
    if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $Destination -Force -ErrorAction Stop
    }

    $hashCache = @{}   # PowerShell 的 hashtable 鍵不分大小寫，同一個檔案的不同大小寫路徑只算一次
    $processCache = @{ List = $null }
    $fileNames = @{
        ScheduledTasks     = 'scheduled_tasks.json'
        Services           = 'services.json'
        Autoruns           = 'autoruns.json'
        Processes          = 'processes.json'
        NetworkConnections = 'network_connections.json'
        DnsCache           = 'dns_cache.json'
    }

    foreach ($artifact in @($Name | Select-Object -Unique)) {
        if ($artifact -eq 'Prefetch') {
            $pfSource = Join-Path $env:SystemRoot 'Prefetch'
            $pfOut = Join-Path $Destination 'prefetch'
            try {
                $all = @(Get-ChildItem -LiteralPath $pfSource -Filter '*.pf' -File -ErrorAction Stop)
            }
            catch [System.Management.Automation.ItemNotFoundException] {
                Write-FKAction -Action 'CollectArtifact' -Target 'Prefetch' -Detail "Prefetch 目錄不存在：$pfSource" -Status 'Skipped'
                [pscustomobject]@{ Name = 'Prefetch'; Path = $null; ItemCount = 0; Status = 'Skipped' }
                continue
            }
            catch {
                Write-FKAction -Action 'CollectArtifact' -Target 'Prefetch' -Detail ("無法列出 {0}：{1}" -f $pfSource, $_.Exception.Message) -Status 'Failed'
                [pscustomobject]@{ Name = 'Prefetch'; Path = $null; ItemCount = $null; Status = 'Failed' }
                continue
            }
            $selected = @($all | Where-Object { $_.LastWriteTimeUtc -ge $StartUtc -and $_.LastWriteTimeUtc -le $EndUtc })
            if (-not (Test-Path -LiteralPath $pfOut -PathType Container)) { $null = New-Item -ItemType Directory -Path $pfOut -Force -ErrorAction Stop }
            $copied = 0
            $failed = New-Object System.Collections.Generic.List[string]
            foreach ($f in $selected) {
                try {
                    Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $pfOut $f.Name) -ErrorAction Stop
                    $copied++
                }
                catch { $failed.Add($f.Name) }
            }
            if ($failed.Count -eq 0) { $status = 'OK' }
            elseif ($copied -eq 0) { $status = 'Failed' }
            else { $status = 'Partial' }
            $detail = 'Get-ChildItem {0}\*.pf → 共 {1} 個，LastWriteTimeUtc 在時段內 {2} 個，複製 {3} 個（Prefetch 只記錄最後執行時間）' -f $pfSource, $all.Count, $selected.Count, $copied
            if ($failed.Count -gt 0) { $detail += '；複製失敗：' + ($failed -join ', ') }
            Write-FKAction -Action 'CollectArtifact' -Target 'Prefetch' -Detail $detail -Status $status
            [pscustomobject]@{ Name = 'Prefetch'; Path = $pfOut; ItemCount = $copied; Status = $status }
            continue
        }

        $outFile = Join-Path $Destination $fileNames[$artifact]
        try {
            switch ($artifact) {
                'Processes' { $r = Get-FKProcessItem }
                'NetworkConnections' { $r = Get-FKNetworkItem }
                'DnsCache' { $r = Get-FKDnsItem }
                'ScheduledTasks' { $r = Get-FKScheduledTaskItem }
                'Services' { $r = Get-FKServiceItem }
                'Autoruns' { $r = Get-FKAutorunItem }
            }
            $items = @($r.Items)
            Write-FKJsonFile -Path $outFile -Items $items
            $status = 'OK'
            $detail = '{0} → {1} 筆，寫入 {2}' -f $r.Source, $items.Count, $fileNames[$artifact]
            if (@($r.Notes).Count -gt 0) {
                $status = 'Partial'
                $detail += '；部分失敗：' + (@($r.Notes) -join '；')
            }
            Write-FKAction -Action 'CollectArtifact' -Target $artifact -Detail $detail -Status $status
            [pscustomobject]@{ Name = $artifact; Path = $outFile; ItemCount = $items.Count; Status = $status }
        }
        catch {
            Write-FKAction -Action 'CollectArtifact' -Target $artifact -Detail ('收集失敗：{0}' -f $_.Exception.Message) -Status 'Failed'
            $leftover = $null
            if (Test-Path -LiteralPath $outFile -PathType Leaf) { $leftover = $outFile }
            [pscustomobject]@{ Name = $artifact; Path = $leftover; ItemCount = $null; Status = 'Failed' }
        }
    }
}

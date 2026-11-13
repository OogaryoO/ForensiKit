function Install-FKPreservation {
    <#
    .SYNOPSIS
        安裝常駐保全：加大事件記錄上限，並註冊每小時把事件記錄備份到 vault 的 SYSTEM 排程。

    .DESCRIPTION
        依設定檔（docs/ARCHITECTURE.md 第 5、6 節）執行：
          1. 以 wevtutil sl <channel> /ms:<bytes> 加大每個 channel 的上限（只加大不縮小；channel 不存在則略過）。
          2. 把模組複製到 <安裝目錄>\module\，寫入設定檔 preservation.json 與排程啟動腳本 bin\VaultBackup.ps1，
             安裝目錄設為只有 SYSTEM 與 Administrators 可寫入（避免一般使用者竄改以 SYSTEM 執行的腳本）。
          3. 建立 vault 並設定 ACL：SYSTEM 完全控制、Administrators 唯讀、其他人無權限、不繼承。
          4. 註冊（或覆寫）排程工作 \ForensiKit\VaultBackup，並立即執行一次。
        可以重複執行（冪等）。單一 channel 設定失敗時 Status = 'Partial'，其他步驟照常進行；
        vault 或排程失敗時 Status = 'Failed'。安裝目錄預設為 C:\ProgramData\ForensiKit，
        動作記錄在其中的 action_log.jsonl。需要系統管理員權限；只能在測試 VM 或正式部署的端點上執行。

    .PARAMETER ConfigPath
        設定檔路徑。省略時使用模組內建的 config/default-profile.json。

    .EXAMPLE
        Install-FKPreservation

    .EXAMPLE
        Install-FKPreservation -ConfigPath 'D:\FK\hospital-profile.json' -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$ConfigPath
    )

    Assert-FKAdmin
    if ($PSBoundParameters.ContainsKey('ConfigPath')) { $config = Get-FKConfig -Path $ConfigPath }
    else { $config = Get-FKConfig }

    $installRoot = Get-FKInstallRoot
    $vaultRoot = [string]$config.preservation.vaultRoot
    $result = [pscustomobject]@{
        LogSizesApplied = @()
        VaultRoot       = $vaultRoot
        TaskRegistered  = $false
        Status          = 'Failed'
    }

    if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, "安裝 ForensiKit 常駐保全（vault：$vaultRoot）")) {
        $result.Status = 'Skipped'
        return $result
    }

    if (-not (Test-Path -LiteralPath $installRoot -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $installRoot -Force
    }
    $previousLog = Get-FKActionLogPath
    $null = Open-FKActionLog -PackageRoot $installRoot
    try {
        Write-FKAction -Action 'InstallPreservation' -Target $env:COMPUTERNAME -Detail "開始安裝；vaultRoot=$vaultRoot" -Status 'OK'

        # ---- 1. 加大 log 上限 ----
        $sizes = New-Object System.Collections.Generic.List[object]
        $sizeTable = $config.preservation.logMaxSizeMB
        foreach ($channel in @($config.channels)) {
            $channel = [string]$channel
            $targetMB = $sizeTable.default
            if ($sizeTable.PSObject.Properties.Name -contains $channel) { $targetMB = $sizeTable.$channel }
            $targetBytes = [long]$targetMB * 1MB
            $entry = [pscustomobject]@{ Channel = $channel; PreviousMB = $null; TargetMB = [int]$targetMB; Status = 'Failed' }

            $current = Get-FKLogMaxSize -Channel $channel
            if ($null -eq $current) {
                $entry.Status = 'Skipped'
                Write-FKAction -Action 'SetLogMaxSize' -Target $channel -Detail 'channel 不存在，略過' -Status 'Skipped'
            }
            else {
                $entry.PreviousMB = [math]::Round($current / 1MB, 2)
                if ($current -ge $targetBytes) {
                    $entry.Status = 'OK'
                    Write-FKAction -Action 'SetLogMaxSize' -Target $channel -Detail ("目前 {0} bytes ≥ 目標 {1} bytes，不變更" -f $current, $targetBytes) -Status 'Skipped'
                }
                else {
                    $r = Invoke-FKNative -FilePath 'wevtutil.exe' -ArgumentList @('sl', $channel, "/ms:$targetBytes")
                    if ($r.ExitCode -eq 0) {
                        $entry.Status = 'OK'
                        Write-FKAction -Action 'SetLogMaxSize' -Target $channel -Detail $r.CommandLine -Status 'OK'
                    }
                    else {
                        Write-FKAction -Action 'SetLogMaxSize' -Target $channel -Detail ("{0} → exit {1}：{2}" -f $r.CommandLine, $r.ExitCode, $r.Output) -Status 'Failed'
                    }
                }
            }
            $sizes.Add($entry)
        }
        $result.LogSizesApplied = $sizes.ToArray()

        # ---- 2. 安裝目錄：模組副本、設定、啟動腳本 ----
        $moduleDest = Join-Path $installRoot 'module\ForensiKit'
        $configDest = Join-Path $installRoot 'preservation.json'
        $runnerPath = Join-Path $installRoot 'bin\VaultBackup.ps1'
        try {
            $sourceRoot = (Resolve-Path -LiteralPath $script:FKModuleRoot).ProviderPath.TrimEnd('\')
            $destFull = [System.IO.Path]::GetFullPath($moduleDest).TrimEnd('\')
            if ($sourceRoot -ne $destFull) {
                if (Test-Path -LiteralPath $moduleDest) { Remove-Item -LiteralPath $moduleDest -Recurse -Force }
                $null = New-Item -ItemType Directory -Path (Split-Path $moduleDest -Parent) -Force
                Copy-Item -LiteralPath $sourceRoot -Destination $moduleDest -Recurse -Force
            }
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($configDest, (ConvertTo-Json -InputObject $config -Depth 10), $utf8NoBom)

            $null = New-Item -ItemType Directory -Path (Split-Path $runnerPath -Parent) -Force
            $manifest = Join-Path $moduleDest 'ForensiKit.psd1'
            $runner = @(
                '# ForensiKit VaultBackup 啟動腳本：由 Install-FKPreservation 產生，請勿手動修改。'
                "`$ErrorActionPreference = 'Stop'"
                "`$module = Import-Module -Name '$($manifest.Replace("'", "''"))' -Force -PassThru"
                "& `$module { param(`$p) Invoke-FKVaultBackup -ConfigPath `$p } '$($configDest.Replace("'", "''"))' | Out-Null"
            ) -join "`r`n"
            [System.IO.File]::WriteAllText($runnerPath, $runner + "`r`n", (New-Object System.Text.UTF8Encoding($true)))

            Protect-FKDirectory -Path $installRoot -Mode InstallRoot
            Write-FKAction -Action 'InstallFiles' -Target $installRoot -Detail "模組 → $moduleDest；設定 → $configDest；啟動腳本 → $runnerPath；ACL：SYSTEM/Administrators 完全控制、Users 讀取" -Status 'OK'
        }
        catch {
            Write-FKAction -Action 'InstallFiles' -Target $installRoot -Detail $_.Exception.Message -Status 'Failed'
            return $result
        }

        # ---- 3. vault ----
        try {
            if (-not (Test-Path -LiteralPath $vaultRoot -PathType Container)) {
                $null = New-Item -ItemType Directory -Path $vaultRoot -Force
            }
            Protect-FKDirectory -Path $vaultRoot -Mode Vault
            Write-FKAction -Action 'CreateVault' -Target $vaultRoot -Detail 'ACL：SYSTEM 完全控制、Administrators 唯讀、不繼承' -Status 'OK'
        }
        catch {
            Write-FKAction -Action 'CreateVault' -Target $vaultRoot -Detail $_.Exception.Message -Status 'Failed'
            return $result
        }

        # ---- 4. 排程 ----
        $interval = [int]$config.preservation.vaultIntervalMinutes
        try {
            Register-FKVaultTask -RunnerPath $runnerPath -IntervalMinutes $interval
            $result.TaskRegistered = $true
            Write-FKAction -Action 'RegisterTask' -Target '\ForensiKit\VaultBackup' -Detail "SYSTEM，每 $interval 分鐘與開機時執行：$runnerPath" -Status 'OK'
        }
        catch {
            Write-FKAction -Action 'RegisterTask' -Target '\ForensiKit\VaultBackup' -Detail $_.Exception.Message -Status 'Failed'
            return $result
        }

        $failedSizes = @($result.LogSizesApplied | Where-Object { $_.Status -eq 'Failed' })
        if ($failedSizes.Count -gt 0) { $result.Status = 'Partial' } else { $result.Status = 'OK' }
        Write-FKAction -Action 'InstallPreservation' -Target $env:COMPUTERNAME -Detail '安裝結束' -Status $result.Status
        return $result
    }
    finally {
        if ($previousLog) { $null = Open-FKActionLog -PackageRoot (Split-Path -Path $previousLog -Parent) }
        else { Close-FKActionLog }
    }
}

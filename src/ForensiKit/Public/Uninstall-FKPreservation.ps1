function Uninstall-FKPreservation {
    <#
    .SYNOPSIS
        移除常駐保全：刪除排程與安裝的檔案；未指定 -KeepVault 時一併刪除 vault 中的所有備份。

    .DESCRIPTION
        - 刪除排程工作 \ForensiKit\VaultBackup。
        - 刪除安裝目錄中的 module\、bin\ 與 preservation.json；保留 action_log.jsonl（安裝與移除的紀錄）。
        - 未指定 -KeepVault 時刪除 vault：vault 對 Administrators 是唯讀，所以先以 takeown 取得擁有權、
          icacls 授予 Administrators 完全控制後再刪除。
        - 不會把事件記錄上限改回原值（縮小上限可能讓尚未匯出的事件被覆寫）。
        刪除 vault 無法復原，預設會要求確認（ConfirmImpact = High），自動化時請加 -Confirm:$false。
        尚未安裝時不會 throw，回傳 Status = 'Skipped'。需要系統管理員權限。

    .PARAMETER KeepVault
        保留 vault 目錄與其中的備份檔。

    .EXAMPLE
        Uninstall-FKPreservation -KeepVault

    .EXAMPLE
        Uninstall-FKPreservation -Confirm:$false
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [switch]$KeepVault
    )

    Assert-FKAdmin
    $installRoot = Get-FKInstallRoot
    $configPath = Join-Path $installRoot 'preservation.json'

    # vault 位置以安裝時的設定為準；找不到時用內建預設值
    $vaultRoot = $null
    try {
        if (Test-Path -LiteralPath $configPath -PathType Leaf) { $vaultRoot = [string](Get-FKConfig -Path $configPath).preservation.vaultRoot }
        else { $vaultRoot = [string](Get-FKConfig).preservation.vaultRoot }
    }
    catch {
        Write-Warning "無法讀取設定，略過 vault：$($_.Exception.Message)"
    }

    $taskInfo = Get-FKVaultTaskInfo
    $vaultExists = $vaultRoot -and (Test-Path -LiteralPath $vaultRoot -PathType Container)
    $installed = $taskInfo.Registered -or (Test-Path -LiteralPath $configPath) -or (Test-Path -LiteralPath (Join-Path $installRoot 'module'))
    if (-not $installed -and ($KeepVault -or -not $vaultExists)) {
        return [pscustomobject]@{ Status = 'Skipped' }
    }

    $what = '排程 \ForensiKit\VaultBackup 與安裝的檔案'
    if (-not $KeepVault -and $vaultExists) { $what += "，以及 vault（$vaultRoot）中的所有備份（無法復原）" }
    if (-not $PSCmdlet.ShouldProcess($what, '移除 ForensiKit 常駐保全')) {
        return [pscustomobject]@{ Status = 'Skipped' }
    }

    if (-not (Test-Path -LiteralPath $installRoot -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $installRoot -Force
    }
    $previousLog = Get-FKActionLogPath
    $null = Open-FKActionLog -PackageRoot $installRoot
    $failed = 0
    try {
        Write-FKAction -Action 'UninstallPreservation' -Target $env:COMPUTERNAME -Detail ("開始移除；KeepVault={0}" -f [bool]$KeepVault) -Status 'OK'

        try {
            $removed = Unregister-FKVaultTask
            $taskStatus = 'Skipped'
            if ($removed) { $taskStatus = 'OK' }
            Write-FKAction -Action 'UnregisterTask' -Target '\ForensiKit\VaultBackup' -Detail '' -Status $taskStatus
        }
        catch {
            $failed++
            Write-FKAction -Action 'UnregisterTask' -Target '\ForensiKit\VaultBackup' -Detail $_.Exception.Message -Status 'Failed'
        }

        foreach ($name in 'module', 'bin', 'preservation.json') {
            $path = Join-Path $installRoot $name
            if (-not (Test-Path -LiteralPath $path)) { continue }
            try {
                Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
                Write-FKAction -Action 'RemoveFiles' -Target $path -Detail '' -Status 'OK'
            }
            catch {
                $failed++
                Write-FKAction -Action 'RemoveFiles' -Target $path -Detail $_.Exception.Message -Status 'Failed'
            }
        }

        if ($KeepVault) {
            Write-FKAction -Action 'RemoveVault' -Target ([string]$vaultRoot) -Detail '指定 -KeepVault，保留 vault' -Status 'Skipped'
        }
        elseif ($vaultExists) {
            $takeown = Invoke-FKNative -FilePath 'takeown.exe' -ArgumentList @('/F', $vaultRoot, '/R', '/A')
            Write-FKAction -Action 'RemoveVault' -Target $vaultRoot -Detail ("{0} → exit {1}" -f $takeown.CommandLine, $takeown.ExitCode) -Status $(if ($takeown.ExitCode -eq 0) { 'OK' } else { 'Failed' })
            $grant = Invoke-FKNative -FilePath 'icacls.exe' -ArgumentList @($vaultRoot, '/grant', '*S-1-5-32-544:(OI)(CI)F', '/T', '/C', '/Q')
            Write-FKAction -Action 'RemoveVault' -Target $vaultRoot -Detail ("{0} → exit {1}" -f $grant.CommandLine, $grant.ExitCode) -Status $(if ($grant.ExitCode -eq 0) { 'OK' } else { 'Failed' })
            try {
                Remove-Item -LiteralPath $vaultRoot -Recurse -Force -ErrorAction Stop
                Write-FKAction -Action 'RemoveVault' -Target $vaultRoot -Detail '已刪除 vault 與所有備份' -Status 'OK'
            }
            catch {
                $failed++
                Write-FKAction -Action 'RemoveVault' -Target $vaultRoot -Detail $_.Exception.Message -Status 'Failed'
            }
        }

        $status = 'OK'
        if ($failed -gt 0) { $status = 'Partial' }
        Write-FKAction -Action 'UninstallPreservation' -Target $env:COMPUTERNAME -Detail '移除結束' -Status $status
        return [pscustomobject]@{ Status = $status }
    }
    finally {
        if ($previousLog) { $null = Open-FKActionLog -PackageRoot (Split-Path -Path $previousLog -Parent) }
        else { Close-FKActionLog }
    }
}

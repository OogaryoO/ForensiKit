#Requires -Version 5.1
<#
.SYNOPSIS
    ForensiKit GUI 入口（T10）：載入同一份 repo／部署資料夾中的模組並開啟一鍵蒐證視窗。

.DESCRIPTION
    值班人員請直接雙擊同資料夾的 ForensiKit.cmd。
    本腳本依序尋找模組：..\src\ForensiKit（repo 結構）→ .\ForensiKit（部署時與 GUI 放在一起）。
    設定環境變數 FK_GUI_DEMO=1 可進入 DEMO 模式（不蒐證、結果為假，用於開發與練習）。

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\gui\ForensiKit.Gui.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$candidates = @(
    (Join-Path $PSScriptRoot '..\src\ForensiKit\ForensiKit.psd1'),
    (Join-Path $PSScriptRoot 'ForensiKit\ForensiKit.psd1')
)
$manifest = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $manifest) {
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show("找不到 ForensiKit 模組：`r`n$($candidates -join "`r`n")", 'ForensiKit')
    exit 1
}

Import-Module -Name (Resolve-Path -LiteralPath $manifest).ProviderPath -Force
Start-ForensiKitGui

<#
    T11：依 docs/ARCHITECTURE.md 第 7 節，檢查每個公開函式的參數名稱、型別與是否必填。
    函式尚未實作（模組未匯出）時，該函式的整組測試自動 Skip；實作合併後自動啟用。
    契約有變動時（[contract] PR），請同步更新下方 $contracts。
#>

BeforeDiscovery {
    . "$PSScriptRoot/_TestHelpers.ps1"

    $dt = 'System.DateTime'
    $str = 'System.String'
    $strArr = 'System.String[]'
    $sw = 'System.Management.Automation.SwitchParameter'
    $sec = 'System.Security.SecureString'

    # Name：函式；Params：契約列出的參數（Mandatory = 契約中沒有方括號）
    $contracts = @(
        @{ Name = 'Write-FKAction'; Task = 'T01'; Params = @(
                @{ Param = 'Action'; Type = $str; Mandatory = $true }
                @{ Param = 'Target'; Type = $str; Mandatory = $true }
                @{ Param = 'Detail'; Type = $str; Mandatory = $true }
                @{ Param = 'Status'; Type = $str; Mandatory = $true }) }
        @{ Name = 'Get-FKConfig'; Task = 'T01'; Params = @(
                @{ Param = 'Path'; Type = $str; Mandatory = $false }) }
        @{ Name = 'Export-FKEventLog'; Task = 'T04'; Params = @(
                @{ Param = 'StartUtc'; Type = $dt; Mandatory = $true }
                @{ Param = 'EndUtc'; Type = $dt; Mandatory = $true }
                @{ Param = 'Destination'; Type = $str; Mandatory = $true }
                @{ Param = 'Channels'; Type = $strArr; Mandatory = $false }
                @{ Param = 'IncludeVault'; Type = $sw; Mandatory = $false }) }
        @{ Name = 'Get-FKArtifact'; Task = 'T05'; Params = @(
                @{ Param = 'StartUtc'; Type = $dt; Mandatory = $true }
                @{ Param = 'EndUtc'; Type = $dt; Mandatory = $true }
                @{ Param = 'Destination'; Type = $str; Mandatory = $true }
                @{ Param = 'Name'; Type = $strArr; Mandatory = $false }) }
        @{ Name = 'Install-FKPreservation'; Task = 'T06'; Params = @(
                @{ Param = 'ConfigPath'; Type = $str; Mandatory = $false }) }
        @{ Name = 'Uninstall-FKPreservation'; Task = 'T06'; Params = @(
                @{ Param = 'KeepVault'; Type = $sw; Mandatory = $false }) }
        @{ Name = 'Get-FKPreservationStatus'; Task = 'T06'; Params = @() }
        @{ Name = 'New-FKManifest'; Task = 'T07'; Params = @(
                @{ Param = 'PackageRoot'; Type = $str; Mandatory = $true }
                @{ Param = 'CaseId'; Type = $str; Mandatory = $true }
                @{ Param = 'Operator'; Type = $str; Mandatory = $true }
                @{ Param = 'StartUtc'; Type = $dt; Mandatory = $true }
                @{ Param = 'EndUtc'; Type = $dt; Mandatory = $true }) }
        @{ Name = 'Test-FKPackage'; Task = 'T07'; Params = @(
                @{ Param = 'PackageRoot'; Type = $str; Mandatory = $true }) }
        @{ Name = 'Protect-FKPackage'; Task = 'T08'; Params = @(
                @{ Param = 'PackageRoot'; Type = $str; Mandatory = $true }
                @{ Param = 'Password'; Type = $sec; Mandatory = $true }
                @{ Param = 'RemovePlaintext'; Type = $sw; Mandatory = $false }) }
        @{ Name = 'Unprotect-FKPackage'; Task = 'T08'; Params = @(
                @{ Param = 'Path'; Type = $str; Mandatory = $true }
                @{ Param = 'Password'; Type = $sec; Mandatory = $true }
                @{ Param = 'Destination'; Type = $str; Mandatory = $true }) }
        @{ Name = 'Invoke-ForensiKit'; Task = 'T09'; Params = @(
                @{ Param = 'CaseId'; Type = $str; Mandatory = $true }
                @{ Param = 'Operator'; Type = $str; Mandatory = $true }
                @{ Param = 'StartUtc'; Type = $dt; Mandatory = $true }
                @{ Param = 'EndUtc'; Type = $dt; Mandatory = $true }
                @{ Param = 'OutputRoot'; Type = $str; Mandatory = $true }
                @{ Param = 'Password'; Type = $sec; Mandatory = $false }
                @{ Param = 'NoEncrypt'; Type = $sw; Mandatory = $false }) }
    )

    foreach ($c in $contracts) {
        $c.Available = Test-FKCommandAvailable -Name $c.Name
        foreach ($p in $c.Params) { $p.Command = $c.Name }
    }
}

BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"
    Import-FKModuleUnderTest | Out-Null
}

Describe '契約參數：<Contract.Name>（<Contract.Task>）' -Tag 'Contract' -ForEach @($contracts | ForEach-Object { @{ Contract = $_ } }) {

    Context '參數' -Skip:(-not $Contract.Available) {

        It '有參數 -<Param>，型別 <Type>，必填 = <Mandatory>' -ForEach $Contract.Params {
            $info = Get-FKParameterInfo -Command $Command -Parameter $Param
            $info.Exists | Should -BeTrue -Because "契約第 7 節列出 -$Param"
            $info.TypeName | Should -Be $Type
            $info.Mandatory | Should -Be $Mandatory
        }

        It '沒有契約以外的必填參數（避免呼叫端照契約呼叫時被要求輸入）' {
            $cmd = Get-Command -Name $Contract.Name -Module ForensiKit
            $contractNames = @($Contract.Params | ForEach-Object { $_.Param })
            $extraMandatory = @(
                $cmd.Parameters.Values | Where-Object {
                    $contractNames -notcontains $_.Name -and
                    ($_.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory })
                } | ForEach-Object { $_.Name }
            )
            $extraMandatory | Should -BeNullOrEmpty
        }

        It '有 comment-based help（SYNOPSIS 與 EXAMPLE）' {
            $help = Get-Help -Name $Contract.Name -Full
            ([string]$help.Synopsis).Trim() | Should -Not -BeNullOrEmpty
            # 沒寫 .SYNOPSIS 時，PowerShell 會自動用「函式名稱 + 語法」當 synopsis
            ([string]$help.Synopsis).Trim() | Should -Not -BeLike "$($Contract.Name)*" -Because '應有 .SYNOPSIS 說明，而不是自動產生的語法'
            @($help.examples.example).Count | Should -BeGreaterThan 0
        }
    }
}

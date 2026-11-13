function Protect-FKDirectory {
    <#
    .SYNOPSIS
        對目錄套用 ForensiKit 的固定 ACL（關閉繼承、移除其他所有權限）。

    .DESCRIPTION
        Mode = Vault（docs/ARCHITECTURE.md 第 5 節）：
          SYSTEM 完全控制、Administrators 讀取與執行，其他人無權限。
        Mode = InstallRoot（排程以 SYSTEM 執行此目錄中的腳本，必須防止一般使用者竄改）：
          SYSTEM 與 Administrators 完全控制、Users 讀取與執行。
        權限都會繼承到子目錄與檔案（之後由排程建立的備份檔也適用）。
        以 SID 指定帳戶，中英文 Windows 都適用。

    .PARAMETER Path
        要設定的目錄（必須已存在）。

    .PARAMETER Mode
        Vault 或 InstallRoot。

    .EXAMPLE
        Protect-FKDirectory -Path 'C:\ProgramData\ForensiKit\vault' -Mode Vault
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateSet('Vault', 'InstallRoot')]
        [string]$Mode
    )

    $system = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
    $admins = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $users = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')

    $full = [System.Security.AccessControl.FileSystemRights]::FullControl
    $read = [System.Security.AccessControl.FileSystemRights]::ReadAndExecute
    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow

    $rules = @(New-Object System.Security.AccessControl.FileSystemAccessRule($system, $full, $inherit, $propagation, $allow))
    if ($Mode -eq 'Vault') {
        $rules += New-Object System.Security.AccessControl.FileSystemAccessRule($admins, $read, $inherit, $propagation, $allow)
    }
    else {
        $rules += New-Object System.Security.AccessControl.FileSystemAccessRule($admins, $full, $inherit, $propagation, $allow)
        $rules += New-Object System.Security.AccessControl.FileSystemAccessRule($users, $read, $inherit, $propagation, $allow)
    }

    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)   # 不繼承上層、不保留原本繼承的權限
    foreach ($rule in $rules) { $acl.AddAccessRule($rule) }

    $dir = Get-Item -LiteralPath $Path -ErrorAction Stop
    $dir.SetAccessControl($acl)
}

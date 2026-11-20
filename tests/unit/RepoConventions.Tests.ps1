<#
    T11：檢查 CONTRIBUTING.md 第 5 節與 AGENTS.md 第 4 節的程式規範。
    這組測試不依賴任何實作，會掃描 repo 中現有的 PowerShell 檔案（src、gui、scripts、tests）。
#>

BeforeDiscovery {
    . "$PSScriptRoot/_TestHelpers.ps1"

    $scanRoots = @('src', 'gui', 'scripts', 'tests') |
        ForEach-Object { Join-Path $script:FKRepoRoot $_ } |
        Where-Object { Test-Path -LiteralPath $_ }

    $psFiles = @(
        foreach ($r in $scanRoots) {
            # PS 5.1 的 -Include 搭配 -LiteralPath 不生效，改用副檔名過濾
            Get-ChildItem -LiteralPath $r -Recurse -File |
                Where-Object { @('.ps1', '.psm1', '.psd1') -contains $_.Extension.ToLowerInvariant() -and $_.FullName -notmatch '\\tests\\e2e\\run\\' }
        }
    ) | ForEach-Object {
        @{ Path = $_.FullName; Rel = $_.FullName.Substring($script:FKRepoRoot.Length + 1) -replace '\\', '/' }
    }

    $publicDir = Join-Path $script:FKRepoRoot 'src\ForensiKit\Public'
    $publicFiles = @()
    if (Test-Path -LiteralPath $publicDir) {
        $publicFiles = @(Get-ChildItem -LiteralPath $publicDir -Filter '*.ps1' -File | ForEach-Object {
                @{ Path = $_.FullName; Rel = "src/ForensiKit/Public/$($_.Name)"; Name = $_.BaseName }
            })
    }

    $isPs51 = $PSVersionTable.PSVersion.Major -eq 5
}

BeforeAll {
    . "$PSScriptRoot/_TestHelpers.ps1"

    function Get-FKTestAst {
        param([string]$Path)
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        return [pscustomobject]@{ Ast = $ast; Errors = @($errors) }
    }
}

Describe 'PowerShell 檔案格式：<Rel>' -Tag 'Conventions' -ForEach $psFiles {

    It '編碼為 UTF-8 with BOM' {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $bytes.Length | Should -BeGreaterOrEqual 3
        ('{0:X2}{1:X2}{2:X2}' -f $bytes[0], $bytes[1], $bytes[2]) | Should -Be 'EFBBBF' -Because 'PS 5.1 讀無 BOM 的中文會亂碼'
    }

    It '換行為 CRLF（沒有單獨的 LF）' {
        $text = [System.IO.File]::ReadAllText($Path)
        $loneLf = [regex]::Matches($text, '(?<!\r)\n').Count
        $loneLf | Should -Be 0
    }

    It '可被 PowerShell 5.1 解析（不含 PS7 專屬語法）' -Skip:(-not $isPs51) {
        (Get-FKTestAst -Path $Path).Errors | Should -BeNullOrEmpty
    }

    It '不使用 Invoke-Expression' {
        $ast = (Get-FKTestAst -Path $Path).Ast
        $hits = @($ast.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.CommandAst] -and
                    @('invoke-expression', 'iex') -contains ([string]$n.GetCommandName()).ToLowerInvariant()
                }, $true))
        $hits.Count | Should -Be 0
    }
}

Describe '公開函式檔案：<Rel>' -Tag 'Conventions' -ForEach $publicFiles {

    BeforeAll {
        $parsed = Get-FKTestAst -Path $Path
        $functions = @($parsed.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false))
        $fn = $functions | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    }

    It '檔名＝函式名（檔案中定義了函式 <Name>）' {
        $fn | Should -Not -BeNullOrEmpty
    }

    It '函式名稱使用核准動詞與 FK 前綴' {
        $verb, $noun = $Name -split '-', 2
        (Get-Verb | ForEach-Object { $_.Verb }) | Should -Contain $verb
        $noun | Should -Match '^(FK|ForensiKit)'
    }

    It '使用 [CmdletBinding()]' {
        $fn.Body.ParamBlock | Should -Not -BeNullOrEmpty
        @($fn.Body.ParamBlock.Attributes | Where-Object { $_.TypeName.Name -eq 'CmdletBinding' }).Count | Should -Be 1
    }

    It '有 comment-based help：.SYNOPSIS、.EXAMPLE，且每個參數都有 .PARAMETER' {
        $help = $fn.GetHelpContent()
        $help | Should -Not -BeNullOrEmpty -Because 'CONTRIBUTING.md 第 5 節要求 comment-based help'
        ([string]$help.Synopsis).Trim() | Should -Not -BeNullOrEmpty
        @($help.Examples).Count | Should -BeGreaterThan 0
        $declared = @($fn.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $documented = @($help.Parameters.Keys | ForEach-Object { $_.ToUpperInvariant() })
        foreach ($p in $declared) {
            $documented | Should -Contain $p.ToUpperInvariant() -Because ".PARAMETER $p 缺少說明"
        }
    }

    It '有對應的單元測試檔 tests/unit/<Name>.Tests.ps1' {
        Join-Path $PSScriptRoot "$Name.Tests.ps1" | Should -Exist
    }
}

# 單元測試專用的 PSScriptAnalyzer 設定（src/ 仍用預設規則，見 CONTRIBUTING.md 第 5 節）
#   Invoke-ScriptAnalyzer -Path ./tests/unit -Recurse -Settings ./tests/unit/PSScriptAnalyzerSettings.psd1
#
# 排除的規則都是 Pester 測試檔的已知誤報：
#   PSUseDeclaredVarsMoreThanAssignments        變數在 BeforeDiscovery / BeforeEach 指定、在 -Skip 或 It 中使用，分析器看不出跨區塊使用
#   PSAvoidGlobalVars                           Mock 的本體不一定保留 closure，假指令的呼叫紀錄要用全域變數傳回測試（AfterAll 會清除）
#   PSUseShouldProcessForStateChangingFunctions 測試輔助函式（New-FKTestPackage 等）只在 TestDrive 建立假資料，不需要 -WhatIf
@{
    Severity     = @('Warning', 'Error')
    ExcludeRules = @(
        'PSUseDeclaredVarsMoreThanAssignments',
        'PSAvoidGlobalVars',
        'PSUseShouldProcessForStateChangingFunctions'
    )
}

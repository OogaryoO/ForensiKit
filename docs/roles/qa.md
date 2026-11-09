# 角色：測試與 QA — wangLJ1015（王荏甲）

> 給 wangLJ1015 的 AI agent：你的使用者負責測試、VM 環境與驗收，是決定「做完了沒」的人。讀完本檔與 `docs/TEST_PLAN.md` 後依 `AGENTS.md` 的規則工作。

## 你負責的任務

| 任務 | 週次 | 說明 |
|---|---|---|
| T02 | W10 | `docs/VM_SETUP.md` ＋ `scripts/vm/Setup-TestVM.ps1`。**三人都要用它建 VM，優先完成。** |
| T03 | W10–W11 | 攻擊模擬腳本 S1–S7 與預期事件 JSON |
| T11 | W11–W12 | 依契約為每個公開函式寫 Pester 單元測試 |
| T12 | W12–W13 | `tests/e2e/Invoke-E2E.ps1`：自動跑情境、匯出、驗證、量測 AC1–AC6（W11 起先拿 T09a 試跑） |
| T13 | W13 | 在自己的 VM 跑完整 E2E；並收集另外兩人的結果 |
| T15 | W13–W14 | `docs/TEST_REPORT.md` 測試報告 |
| T17 | W12–W13 | 基準比較：手動整檔複製 vs KAPE vs ForensiKit（AC7），結果放進測試報告 |

細節見 `docs/TASKS.md` 與 `docs/TEST_PLAN.md`。

## 你的權責

- **驗收權**：功能 Issue 由你驗證通過後才能關閉。
- **回報 bug**：用 bug 範本開 Issue，指派給該模組負責人（見 `docs/TASKS.md` 總覽表），加 `bug` label。
- **審核測試相關 PR**，並可對任何 PR 留下測試面的意見。

## 給你的 AI 的提醒

- **你不需要等功能寫完才寫測試。** 介面契約已定，可以先寫測試、用 `Mock` 模擬 `wevtutil` 等外部指令；真正的整合驗證留到 E2E。
- 攻擊模擬腳本**必須**先檢查 `C:\FK-TEST-VM.marker`，並提供 `-Cleanup` 參數；只用內建指令，不寫真正的惡意程式。
- 預期事件 JSON 要具體（channel、eventId、最少次數、比對欄位），才能自動算出 AC4 命中率。
- 量測數字要可重現：每次記錄 commit SHA、VM OS 版本、快照名稱。
- 報告要誠實寫出沒通過的項目與原因，不要只報好消息。

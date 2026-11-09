# 協作規則

適用於三位成員以及各自的 AI agent。AI agent 另需遵守 `AGENTS.md` 第 3 節的硬性規則。

## 1. 分工與決策

- **PM（OogaryoO）** 決定範圍、排程、任務指派，負責合併 PR 與修改介面契約。
- 對規格有疑問 → 在該任務的 Issue 留言 @OogaryoO；**24 小時內沒回覆就照契約與 TASKS.md 的字面意思做，並在 PR 中註明你的假設**。
- 三人每週固定一次 15 分鐘同步（時間由 PM 訂），其餘溝通走 GitHub Issue／PR 留言，方便 AI 讀取脈絡。

## 2. 任務流程

1. PM 為 `docs/TASKS.md` 的每個任務開 Issue，指派負責人並加上里程碑（M0–M4）。
2. 負責人開工時把 Issue 加上 `in-progress` label。
3. 從最新的 `main` 開分支：
   | 類型 | 分支名稱 |
   |---|---|
   | 功能 | `feat/T04-export-eventlog` |
   | 測試 | `test/T11-unit-export-eventlog` |
   | 修 bug | `fix/<issue 編號>-short-name` |
   | 文件 | `docs/<short-name>` |
   | 改契約 | `contract/<short-name>` |
4. 小步提交，**至少每天 push 一次**到自己的分支，讓別人看得到進度。
5. 盡早開 **Draft PR**，完成後轉為 Ready for review。
6. 遇到阻礙：Issue 加 `blocked` label，留言說明卡在哪、需要誰。

## 3. Pull Request 規則

- 一個 PR 只做一個任務（或一個 bug）。描述中寫 `Closes #<issue>`，並填完 PR 範本。
- **審核人**：
  | PR 作者 | 必要審核人 |
  |---|---|
  | YuChenKUO（功能） | OogaryoO |
  | OogaryoO（功能） | YuChenKUO |
  | wangLJ1015（測試） | 被測模組的負責人 |
  | 任何 `[contract]` PR | OogaryoO ＋ 受影響的成員 |
- 合併條件：CI 綠燈、至少 1 位**人類**核准、所有審核留言已處理。
- 由 **PM 合併**，使用 **Squash and merge**。PM 自己的 PR 在 YuChenKUO 核准後由 PM 合併。
- AI 可以協助審查並留言建議，但「Approve」必須由人類按。

## 4. 檔案歸屬（避免互相覆蓋）

`.github/CODEOWNERS` 定義每個路徑的擁有者。改別人擁有的檔案時：
- 小修正（錯字、明顯 bug）→ 可以直接在你的 PR 中修，但要 @ 擁有者。
- 其他情況 → 開 Issue 請擁有者處理。

## 5. 程式規範

- **PowerShell 5.1 相容**；不使用 PS7 專屬語法。
- 檔案編碼 **UTF-8 with BOM**、換行 CRLF（`.gitattributes` 已設定換行；編輯器請設定 BOM）。
- 函式命名用核准動詞（`Get-Verb`）＋ `FK` 前綴，例如 `Export-FKEventLog`。
- 每個公開函式要有 comment-based help（`.SYNOPSIS`、`.PARAMETER`、`.EXAMPLE`）。
- 使用 `[CmdletBinding()]` 與參數驗證；不得使用 `Invoke-Expression`。
- 外部指令（`wevtutil` 等）的完整命令列要寫進 action log。
- 提交前本機跑：
  ```powershell
  Invoke-Pester ./tests/unit
  Invoke-ScriptAnalyzer -Path ./src -Recurse -Severity Warning,Error
  ```

## 6. Commit 訊息

採 Conventional Commits，並帶任務編號：

```
feat(T04): export event logs by time range via wevtutil
test(T11): add unit tests for Export-FKEventLog
fix(#23): handle missing Sysmon channel
```

AI 產生的 commit 可附 `Co-Authored-By:` 行，但 commit 作者必須是成員本人的 GitHub 帳號。

## 7. 完成的定義（Definition of Done）

- [ ] 符合 `docs/ARCHITECTURE.md` 的介面與輸出格式
- [ ] 單元測試通過、PSScriptAnalyzer 無 Warning/Error、CI 綠燈
- [ ] 在 VM 中實際執行過一次（PR 描述附執行結果摘要）
- [ ] 相關文件已更新
- [ ] QA 驗證通過後才關閉 Issue（功能任務）

## 8. 禁止事項

- 直接 push 到 `main`、force push、改寫已推送的歷史。
- commit 證據包、EVTX、密碼、個資或任何 `output/` 內容。
- 在實體電腦上執行攻擊模擬或安裝保全排程。
- 未經 `[contract]` PR 就改變公開函式的參數或輸出格式。

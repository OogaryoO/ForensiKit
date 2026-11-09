# AGENTS.md — 給所有 AI agent 的入口

> 本檔是 ForensiKit 專案中 **所有 AI coding agent（Claude Code、Codex、Copilot 等）開工前必讀** 的文件。
> 人類成員也請讀一次，因為這裡定義了你的 AI 能做與不能做的事。

## 0. 開工前的固定流程（每個 session 都要做）

1. **確認你在替誰工作。** 執行下列指令，比對下方角色表：
   ```powershell
   git config user.name
   gh api user --jq .login   # 若有安裝 GitHub CLI
   ```
   無法判斷時，**直接問你的使用者**：「你是 OogaryoO、YuChenKUO 還是 wangLJ1015？」不要猜。
2. **讀你的角色檔**（`docs/roles/` 下對應的檔案），以及：
   - `CONTRIBUTING.md`（協作規則，必須遵守）
   - `docs/TASKS.md`（任務拆分與相依關係）
   - `docs/ARCHITECTURE.md`（介面契約；寫程式或測試前必讀）
   - QA 另需讀 `docs/TEST_PLAN.md`
3. **同步最新進度：** `git pull origin main`，並查看 GitHub Issues 中指派給你的使用者的任務：
   ```powershell
   gh issue list --assignee "@me" --state open
   ```
4. **只做指派給你的使用者的任務。** 想做別人的任務、或發現需要改介面契約，先停下來問你的使用者。

## 1. 角色表

| GitHub 帳號 | 成員 | 角色 | 工作比重 | 角色檔 |
|---|---|---|---|---|
| [OogaryoO](https://github.com/OogaryoO) | 蔡冠毅 | PM ＋ 開發（約 30% 開發量） | 規劃、審 PR、合併、GUI、保全模組 | [`docs/roles/pm.md`](docs/roles/pm.md) |
| [YuChenKUO](https://github.com/YuChenKUO) | 郭宥真 | 主力開發（約 70% 開發量） | 收集、完整性、加密、主流程 | [`docs/roles/dev.md`](docs/roles/dev.md) |
| [wangLJ1015](https://github.com/wangLJ1015) | 王荏甲 | 測試與 QA | VM 環境、測試、攻擊模擬、驗收報告 | [`docs/roles/qa.md`](docs/roles/qa.md) |

## 2. 專案一句話

**ForensiKit**：預先部署於 Windows 端點，事發時由資訊室人員一鍵匯出「指定時段」的事件與執行紀錄，並附 SHA-256 雜湊與監管鏈紀錄，供資安廠商或檢調使用。PoC 只支援 Windows 10/11，以 PowerShell 5.1 實作（Windows 內建，免安裝）。詳見 `docs/PROJECT_PLAN.md`。

## 3. AI agent 的硬性規則（違反即退回 PR）

1. **不直接 push 到 `main`。** 一律開分支 → PR → 人類審核 → 由 PM 合併。
2. **不自行 approve 或 merge PR**，也不 `--force` push、不改寫已推送的歷史。
3. **不改介面契約（`docs/ARCHITECTURE.md`）而不告知。** 需要改時，在 PR 標題加 `[contract]`，並 @OogaryoO 審核。
4. **不修改不屬於你的使用者的檔案**（見 `.github/CODEOWNERS`）。必要時開 Issue 或在 PR 說明，請擁有者處理。
5. **攻擊模擬與蒐證測試只能在 VM 內執行**，絕不在任何人的實體電腦上執行（見 `docs/TEST_PLAN.md` 的安全規則）。
6. **不得把任何蒐證輸出（`.evtx`、證據包、`output/`）、密碼或個資 commit 進 repo。**
7. **不寫真正的惡意程式。** 攻擊模擬只用 Windows 內建指令產生「看起來像攻擊」的紀錄。
8. **不確定就問人。** 規格不清、測試失敗原因不明、要動別人的程式，都先停下來問你的使用者，不要自己腦補。
9. 每個 PR 描述都要寫：做了什麼、怎麼測的、AI 產生了哪些部分、還有什麼沒做完。

## 4. 技術約定（摘要，細節見 CONTRIBUTING.md）

- PowerShell **5.1** 相容（不可用 PS7 才有的語法，如 `??`、`?.`、三元運算子）。
- `.ps1/.psm1/.psd1` 一律 **UTF-8 with BOM**、CRLF（PS 5.1 讀無 BOM 的中文會亂碼）。
- 時間一律以 **UTC** 處理與儲存，只在 GUI 與報表顯示時加註台灣時間（+08:00）。
- 每個公開函式都要有 comment-based help 與 Pester 測試。
- 每次蒐證動作都要呼叫 `Write-FKAction` 記錄到 action log（監管鏈的一部分）。

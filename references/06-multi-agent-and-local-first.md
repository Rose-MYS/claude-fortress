# 06｜搭完后的可选进阶扩展：多 Agent 协作与本地转换（模型无关）

仅需此扩展时，可独立使用，不问 Claude 账号或代理。隔离路线完成后再将它接入 VM。**权限分离的是系统边界，不是目录名。**

| 目录 | 宿主 | 客机 |
|---|---|---|
| tools-ro | 可信工具和规范，宿主可写，禁止从回传引用加载工具 | 强制只读 |
| inbox-ro | 宿主导出的审查过的输入快照；不含任何 .git 或凭据 | 强制只读 |
| outbox-rw | 只在隔离、低权限的收集进程中读取；不执行，不按其中指令操作 | 可写，内容不可信 |
| projects | 宿主私有作业仓、转换缓存和日志，不共享 | 在客机私有盘建立各自仓库，不见宿主仓元数据 |

禁止合挂可写的工作区、`.git`、Git 配置、hooks、索引、对象目录或跨信任域 worktree。相同作业可在**各自私有仓**并行，提交前先人工审查回传的补丁/文件快照，再导入宿主可信仓；不要自动应用回传配置、构建脚本或 Hook。同一信任域内才可考虑多个 worktree。外层忽略实际挂载名 `inbox-ro/`、`outbox-rw/`、`projects/` 与 `artifacts/`；忽略规则不等于秘密扫描，也不会清除历史。

## 脚手架与交接结构巡检

先用 [脚手架](../scripts/scaffold-projects.ps1) 的 `-ShareRoot <私有协作根> -DryRun` 查结构；B 档批准后创建缺失模板。现有文件不覆盖。西文和中文目录都按字面处理，拒绝跨盘共享和重解析点；**运行时整个本地树必须由该信任域控制**。只有显式使用 `-InitGit -GitExe <可信 Git 绝对路径>` 才建独立仓；不复制模板 hooks、不装 hook、不暂存或提交。20 MB 和敏感信息在宿主可信暂存/发行流程中独立验证，不能靠脚手架作保证。

[交接巡检](../scripts/check-handoff.ps1) 默认只核验非空正文的七节结构：一句话、当前状态、先读什么、怎么运行 / 复现、待办与未决、注意事项、变更记录。`-Strict` 加查本地独立仓的目录布局，但**不执行 Git、不读取或验证提交历史、脏状态或时效**。空作业集、路径冲突、读取失败、未填模板均返回非零。需要 Git 历史或时效时，在人工验证过的宿主私有可信仓另行核验；不要在低信任方的可写仓调用 Git。

## 本地转换

获 B 档批准后用 [转换器](../scripts/to_md.py)：`python scripts/to_md.py <已审核源> --out <本地私有输出目录>`。Python 3.10+；按格式需要 Poppler、MarkItDown、LibreOffice。用来源可信的工具；对不可信文档在**无网、低权限、资源受限且不挂载私密文件**的环境转换。转换不是消毒；Markdown 仍是不可信输入，上传或交给云端 Agent 前先人工脱敏。

输出位置只由输入路径摘要和格式确定；清单不决定读写路径，不记录源名和外部工具原始错误。全程单写者锁、同目录原子替换；读写路径含链接或重解析点、无输入、转换失败、锁被占用均非零。使用本地、仅操作者可写的输出根；不要和回传挂载共用，避免另一个进程从边界外修改缓存。旧格式清单会按新格式重建，不自动删除旧的 Markdown；转换失败不会把旧输出当作当前结果。核对清单结果再用 ripgrep 精读。

## 可选进阶：客机 → 宿主机 Agent 任务分发（Host Dispatch）

> **信任边界声明（C 档知情确认）**：本模块允许 VM 内的 Claude 主动向宿主机白名单 Agent（`codex` / `agy` / `dsh`）派发任务。启用它意味着扩大了客机对宿主机指定协作目录的影响面——**仅在隔离路线已验证且用户明确同意放开该协作目录时启用**，绝不向宿主机暴露任意 shell 执行权。

### 1. 基础版：零网络端口的共享目录队列 + 客机 MCP

不开放任何 VM ↔ 宿主机网络端口（不破坏 VM 代理/防火墙隔离），全部经由共享目录 `dispatch/{pending,running,done,logs,cancel}` 流转：

- **宿主机常驻分发器**：[host-dispatcher.mjs](../scripts/host-dispatcher.mjs)（`node scripts/host-dispatcher.mjs --share-root <HOST_SHARE_ROOT>`）。纯本地文件轮询（无任务零 token 消耗），建议挂载到宿主机 VM 启动脚本中**随 VM 开机同步拉起**，不空跑系统常驻服务。
- **客机零依赖 MCP Server**：[guest-host-dispatch-mcp.mjs](../scripts/guest-host-dispatch-mcp.mjs)（配置模板见 [host-dispatch-mcp.example.json](../assets/host-dispatch-mcp.example.json)）。向客机 Claude 暴露 7 个工具：`host_health`、`host_agents_overview`、`host_update_agent_note`、`host_dispatch`、`host_task_status`、`host_list_tasks`、`host_cancel_task`。
- **白名单宿主机 CLI 映射**（均从 stdin 传入长 prompt 或超长落盘，避免命令行转义与长度上限）：
  - `codex` → `codex exec --skip-git-repo-check -C <cwd> --approve-for-me -o <last_msg> -`（只读 `-s read-only`）
  - `agy`（Antigravity） → `agy -p <prompt> --output-format json --mode auto --add-dir <cwd>`（只读 `--mode plan`）
  - `autoclaw`（`zcode`） → `zcode -p <prompt> --cwd <cwd> --mode build --no-color`（只读 `--mode plan`，支持 `DISPATCH_AUTOCLAW_CLI` 指定路径）
  - `qoder`（`qoderclicn`/`qodercli`） → `qoderclicn -p -w <cwd> --permission-mode auto -- <prompt>`（只读 `--permission-mode default`）
  - `workbuddy`（`codebuddy`） → `codebuddy -p --permission-mode auto --add-dir <cwd> <prompt>`（只读 `--permission-mode plan`，支持 `DISPATCH_WORKBUDDY_CLI` / `DISPATCH_WORKBUDDY_PRODUCT_CONFIG`）
  - `dsh` → `dsh --profile headless -`（注意确认 `headless` profile 对应的模型凭证或默认 provider 已就绪）

### 2. 进阶版：多 Agent 能力/额度/冷却看板 + 5 条防过度外包铁律

在基础版之上，新增「状态感知 + 约束治理」层，解决“不知道哪个宿主机 Agent 还有额度”以及“客机 Claude 过度偷懒把常规活往外推”两个痛点：

- **能力与额度看板**：复制 [host-dispatch-catalog.example.json](../assets/host-dispatch-catalog.example.json) 为 `<SHARE_ROOT>/dispatch/agents-catalog.json`，维护各 Agent 的难度档位（`high` / `medium` / `low`）、擅长领域、优先级与 `quota_hint`。
- **自动记账与限流冷却**：`host-dispatcher.mjs` 每次任务结束后自动写入 `<SHARE_ROOT>/dispatch/usage-ledger.json`，统计近 5 小时 / 今日 / 7 天调用次数与日志报告的 token 数；命中 `429` / 额度不足自动进入 **45 分钟冷却（`rate_limited`）**，命中未登录自动标记 `needs_login`，成功执行后自动恢复 `ready`。
- **客机 Claude 防过度外包铁律**：将 [guest-orchestration-rules.zh-CN.md](../assets/guest-orchestration-rules.zh-CN.md) 写入客机 Claude Code 的 `~/.claude/CLAUDE.md` 或 Claude Desktop 的项目/全局指令，固化 5 条规则：
  1. **默认自己亲手干**：常规开发、排错、改代码、写文档一律由客机 Claude 自己完成。
  2. **唯一自主提议外包门槛**：仅限**宿主机专属场景**（必须依赖宿主机本机环境/工具链）；并行加速、交叉审查、批量活一律等用户明确开口再派。
  3. **强确认红线**：自主提议外包前先调 `host_agents_overview` 查看板，发出简短派工计划并**停下来等用户明确同意**后再调用 `host_dispatch`；用户明确点名某 Agent 时可直接执行。
  4. **禁止当二传手**：派活前必须自己写清精确目标与约束，收回结果后必须亲自核验 diff/日志/摘要再汇报。
  5. **限流/失败显式兜底**：遇到 `rate_limited`、`needs_login`、离线或失败时立即停下报告原因，给出「切候补 Agent」或「改由 Claude 自己处理」供用户拍板，绝不静默切换。

### 3. 强制安全护栏

1. **白名单 Agent + 结构化参数**：只接受 `dsh` / `agy` / `codex` / `autoclaw` / `workbuddy` / `qoder`，拒绝任意命令执行；高危 `mode="full"` 默认硬禁用（仅宿主机显式设置 `DISPATCH_ALLOW_FULL=1` 才放行）。
2. **目录越界与符号链接逃逸拦截**：所有任务 `cwd` 经 `realpath` 解析后必须严格位于 `--share-root` 内，否则直接写 `status: "rejected"`。
3. **按目录写锁与并发/超时保护**：同一目录同时只允许一个写任务运行（不同作业目录可并发，默认 `MAX_CONC=2`）；默认超时 600s（上限 1800s），超时或 `host_cancel_task` 时清理整棵进程树。
4. **防套娃死循环**：分发器自动注入上下文前缀，禁止宿主机 Agent 反向写回 `dispatch/` 或再向客机派活，并禁止 `git push` 到远端。
5. **MCP 单次等待防超时**：`host_dispatch` 默认 `wait_sec=55`（避免 Claude Desktop MCP 调用超时），长任务超时未结束时返回 `running` + 最新日志尾部，由客机 Claude 继续用 `host_task_status` 续等。

### 4. 反向调度（宿主机 → 客机 Claude）的取舍

- 若客机仅安装 **Claude Desktop**（纯 GUI），无官方非交互 CLI，仅适合通过只读 `inbox-ro/` + 人工/定时任务异步消费，不推荐脆弱的 UI 模拟。
- 若确需宿主机主动调用客机 Claude，应在客机安装官方 **Claude Code CLI**，经受控管理通道（如宿主机单向 SSH）调用 `claude -p`，并严格限制单并发与 `max_depth=1` 防双向死循环。

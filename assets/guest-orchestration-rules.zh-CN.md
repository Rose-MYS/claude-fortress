# 客机 Claude 宿主机多 Agent 协作铁律（进阶版模板）

> 用法：将本文件内容追加至客机 Claude Code 的 `~/.claude/CLAUDE.md`，或粘贴至 Claude Desktop 的 Project Instructions / 个人偏好设置中。

你运行在隔离虚拟机中，已通过 `host-dispatch` MCP 连接宿主机上的白名单协作者（`codex`、`agy`、`autoclaw`、`qoder`、`workbuddy`、`dsh`）。

## 1. 默认自己亲手干（反过度外包）
- 常规开发、排错、改代码、写文档、分析问题，一律由你（Claude）自己亲手完成，不得主动把常规活推给宿主机 Agent。
- **唯一允许你主动提议外包的场景**：**宿主机专属场景**（必须依赖宿主机本机环境、软件或工具链等客机无法直接完成的事）。
- 并行加速、多模型交叉审查、批量重复活等场景，**不要主动提议外包**，一律等用户明确开口下令时再派发。

## 2. 先查看板再选人
需要派活前，先调用 `host_agents_overview` 查看宿主机分发器在线状态、各 Agent 难度档位（`high` / `medium` / `low`）、擅长领域、当前健康态（`ready` / `busy` / `rate_limited` / `needs_login`）、近 5 小时/今日/7 天用量与 `quota_hint`。绝不向 `enabled=false`、`needs_login` 或冷却中的 `rate_limited` Agent 派活。

## 3. 强确认红线
- **用户明确指定某 Agent**：可直接调用 `host_dispatch` 执行。
- **你因宿主机专属场景自主提议外包**：正式调用 `host_dispatch` 前，**必须先向用户发出简短「派工计划」并停下来等待用户明确同意**（写清为什么必须用宿主机、具体子任务与目录、推荐 Agent 与当前状态/用量、以及 `read-only` / `auto` 权限模式）。

## 4. 禁止当二传手（交接与验收责任）
- **派活前**：自己先理清问题，写出精确的目标、范围、约束与验收标准，禁止把用户原话直接转发。
- **收回后**：必须亲自核验宿主机 Agent 的输出摘要、修改的文件/diff 或日志，确认无误后再向用户汇报。

## 5. 限流/失败显式兜底
若目标 Agent 返回 `rate_limited`、`needs_login`、离线或执行失败，**立即停下来向用户报告原因**，给出「切换候补 Agent」或「改由你（Claude）自己处理」两个选项等用户拍板，绝不静默切换重试。用户告知额度变化或已完成登录时，可调用 `host_update_agent_note` 更新看板。

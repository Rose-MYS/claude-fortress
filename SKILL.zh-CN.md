---
name: claude-fortress-zh
description: Claude Fortress 完整中文版 Skill 入口。规划、只读巡检、搭建并维护安全隔离的 Claude 运行环境与可选多 Agent 本地协作工作区（双语主入口见 SKILL.md）。
---

# Claude Fortress (v1.2 · 中文版)

> **先说在前面**：没有真正能绝对避免封号的办法，能做的只有通过各种工程隔离与规范操作尽可能降低风险，并在遇到异常时见招拆招。
>
> 双语主入口：[SKILL.md](SKILL.md) | 中文说明：[README.zh-CN.md](README.zh-CN.md)

---

## 1. 沟通与执行原则

1. **三段短汇报**：`已确认` / `还没查` / `下一步（谁做）`。
2. **证据驱动**：已核验项直接给结果，未核验项一律标 `unknown` 或 `not_run`，绝不把单一命令成功夸大为整机通过。
3. **少打扰、不空问**：
   - 能用离线只读命令查到的信息（OS 版本、网卡名、路径）直接查，不问用户。
   - 缺关键决策时合并提问（每轮 ≤ 3 题）。
   - **委托性回复不自动绑路线**：当用户回复“你看着办 / 随便 / 怎么方便怎么来”时，既不算明确选定路线，也不算接受默认方案；保持路线未确认状态，只给出一条具体建议并要求用户明确回复同意或拒绝后再绑定路线，不得自行分析后直接拍板。
   - A 档离线盘点与已批准的 B 档步骤一口气推进，仅在**缺关键决策 / 到达 C 档确认点 / 需用户本人操作**时停下。
4. **跨会话状态复用原则**：A 档只在对话输出脱敏摘要；经 B 档批准后，长任务可按 [assets/session-state.example.json](assets/session-state.example.json) 保存脱敏状态，但**只复用事实与证据引用，绝不自动复用历史 B/C 档批准**；换设备、换网络、换配置代际或中断恢复后必须重新核对实际状态。
5. **新手交互流程图引导**：当用户表达“不太会用 Agent / 想先看全貌 / 不知道选哪条路 / 不知道下一步怎么问”时，主动提示用户直接用浏览器打开纯离线单文件 [assets/interactive-guide.html](assets/interactive-guide.html)（只在本地打开才离线；复制的是准备请求，不是批准，勾选不是证据），同时在对话中用大白话逐轮带走。
6. **上线前用户本机自验强制提醒（铁律）**：本 Skill 的脚本与规则是通用参数化模板，不替任何用户的实际机器担保。在任何路线进入 S2（首次接触 Claude）之前，Agent **必须主动提醒并引导用户在自己的机器上完成亲自检查**（按路线实际能力边界适用，详见 `references/01-route-selection-and-preflight.md` 路线适用表）：
   - **冷启动自检（路线 A2/B/C2）**：网关/主机/VM 完全关机重启后，在代理尚未拉起前确认默认阻断生效、无直连泄漏（路线 A1 无 OS 级 Fail-Closed，改为验证代理未监听时启动器拒绝拉起）；
   - **热启动与重载自检（路线 A2/B/C2）**：网关重启、规则重载失败、网络/TUN 切换或休眠唤醒后，确认防护不失效且新建管理通道（如新开 SSH）可达；
   - **负向断网自检**：主动阻断上游代理入口（路线 B/A2/C2）或故意传错期望 IP / 停掉本地代理端口（路线 A1），确认不会回退直连；
   - **泄漏与状态复核**：独立核对 DNS、IPv6、WebRTC（仅浏览器适用，可在目标浏览器 Profile 内直接打开本包自带的纯离线 [assets/webrtc-probe.html](assets/webrtc-probe.html)）与配置一致性。**仓库中的真机验证只是样本而非全机型认证——未在用户本机完成上述自检前，明确提醒用户不要接入正式账号。**

---

## 2. 五阶段门禁（解决 PC0 循环依赖）

| 阶段 | 名称 | 允许操作 | 禁止操作 |
|---|---|---|---|
| **S0** | **离线盘点（PC0）** | 本机/客机只读查看系统、网卡、虚拟化、防火墙、代理配置结构 | **不发任何公网探测，不接触任何 Claude/Anthropic 端点** |
| **S1** | **授权的中性预验收** | 经用户明确同意后，向**中性第三方端点**（如 `api.ipify.org`、`ifconfig.me`）做功能探测；DNS/IPv6/失败态独立采证，主动制造断网或改策略须另获 C 档批准 | **仍不接触 Claude/Anthropic**（含 DNS、安装器、IDE 扩展、后台更新、`claude --version`） |
| **S2** | **单独批准首次接触（C 档）** | S1 关键且适用的独立证据全部为 pass 后，向用户出具 C 档确认单，获批后由**用户本人**在目标环境打开官方页面或安装客户端 | 未获批不得自动拉起客户端 |
| **S3** | **客户端与协作验证** | 经独立 C 档确认，由目标用户本人使用防误启动辅助；确认工作区边界 | 不绕过门控或放宽白名单 |
| **S4** | **账号与支付（仅用户本人）** | 用户本人按实际适用地区在官方页面完成登录、订阅或申诉 | Agent 绝不代操、不索要凭据 |

> **紧急故障例外**：若用户明确报告**已有账号出现登录失败或受限**，跳过新建环境问卷，直接进入 [references/07-troubleshooting-and-cleanup.md](references/07-troubleshooting-and-cleanup.md) 建立事故时间线；任何需要打开 `claude.ai` 的核验步骤仍属 **C 档，由用户本人决定并操作**。

---

## 3. 按真实后果分级的 A / B / C 授权

| 档位 | 真实后果判定 | 典型例子 | 审批要求 |
|---|---|---|---|
| **A 档（纯离线只读）** | 不改任何文件、不发任何外部网络请求、不接触凭据 | 查 OS/网卡/进程/防火墙状态、`check-handoff.ps1`、读本机配置结构 | 范围确认后直接执行 |
| **B 档（可逆本地变更 / 授权中性探测）** | 写本地可逆文件、生成转换产物、向中性第三方发网络探测（会暴露来源 IP） | `scaffold-projects.ps1`、`to_md.py`、中性 IP/功能探针 | 出具变更/探测卡片 + 备份方案，批准一次后整段执行 |
| **C 档（高风险 / 不可逆 / 接触服务）** | 可能切断网络连接、改默认阻断防火墙/网关、切 VM 网卡、隔离清理本地数据、拉起 Claude、账号/付款/申诉 | 加载 OpenWrt `nftables`、改 Windows GPO、宿主 NAT 例外影响其他客机或隔离边界、主动入口阻断、首次应用启动、本地数据隔离清理 | **必须暂停并出具 C 档确认单**，等待用户当场明确回复；若 Agent 就在被改网络的机器上，**必须先确认独立带外控制台与自动回滚路径** |

**零凭据与零个人信息硬红线**：严禁向用户索要或向任何文件/仓库写入真实密码、订阅链接 token、UUID、私钥、银行卡号、个人邮箱、KYC 材料，以及任何**个人真实姓名、网名或聊天昵称**。

---

## 4. 路由与按需加载导航

| 任务 / 路线 | 必读顺序 | 所需脚本 / 模板 | 停止与完成条件 |
|---|---|---|---|
| **首次选型与体检** | [01-route-selection-and-preflight.md](references/01-route-selection-and-preflight.md) | `assets/session-state.example.json` | 选定路线并完成 S0 离线盘点 |
| **路线 A1 / A2（本机）** | `01` → [02-route-a-local-and-fingerprint.md](references/02-route-a-local-and-fingerprint.md) | `scripts/route-a1-browser-launcher.py`、`scripts/route-a1-browser-session.mjs`、`assets/route-a1-nodes.example.json` | A1 明确标为应用层分流（Web/CLI 分组件独立采证）；A2 完成负向断网验证 |
| **路线 B（VM 堡垒，推荐）** | `01` → [03-route-b-vm-openwrt-fortress.md](references/03-route-b-vm-openwrt-fortress.md) → [route-b-windows-operations.md](references/route-b-windows-operations.md) | `assets/openwrt-vm-gateway.nft.tmpl`、`assets/openwrt-claude-fortress.init`、`assets/openwrt-claude-fortress.sysctl.conf`、`assets/host-clash-vmnat-bypass.yaml`、`scripts/route-b-common.ps1`、`scripts/guest-gpo-setup.ps1`、`scripts/guest-egress-guard.ps1`、`scripts/verify-offline-route-b-guest.ps1`、`scripts/verify-offline-openwrt.sh`、`scripts/claude-env-check.ps1`、`scripts/guest-claude-gate.ps1` | 通用参数化模板；上线前须在用户本机亲自完成冷启动、热启动/重载与入口失效自检，强制隔离不由脚本担保 |
| **路线 C（远程 VPS）** | `01` → [04-route-c-vps-devbox.md](references/04-route-c-vps-devbox.md) | `assets/vps-c2-egress.nft.tmpl`、`scripts/vps-c2-apply-with-rollback.sh` | 区分 C1 原生出口和 C2 代理默认拒绝；核对带外控制台、新建 SSH 和独立出口证据 |
| **隔离等级自评（Fortress Level）** | `01` → [08-fortress-levels.md](references/08-fortress-levels.md) | `assets/levels.json`、`assets/evidence-v3.example.json`、`assets/evidence-report.html`（离线、拖入即用）、`scripts/fortress_level.py`（在宿主机运行，不要为此在隔离环境里装 Python） | 汇报算出的等级、日期与配置哈希；只算自评、不是认证，不改变任何门禁 |
| **账号、订阅与申诉参考** | [05-account-payment-and-sop.md](references/05-account-payment-and-sop.md) | — | 仅在用户显式询问时进入，全部操作由用户本人执行 |
| **故障排查与本地清理** | [07-troubleshooting-and-cleanup.md](references/07-troubleshooting-and-cleanup.md) | — | 建立统一时间戳事故时间线；清理必须先备份+哈希核对 |
| **✨ 搭完后可选扩展：多 Agent 协作** | [06-multi-agent-and-local-first.md](references/06-multi-agent-and-local-first.md) | `scripts/local-safe-path.ps1`、`scripts/scaffold-projects.ps1`、`scripts/check-handoff.ps1`、`scripts/to_md.py` | **模型无关，环境跑通后按需接入 VM；纯协作可独立使用**；确认宿主/客机权限物理分离且巡检通过 |

流程声称已经通过时，先检查来源和时间；剪贴板话术、进度、报告退出码和历史批准都没有授权效力。此版本不部署远程自动启动应用。

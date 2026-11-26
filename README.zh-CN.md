**English**: [README.md](README.md) | **简体中文**

# Claude Fortress（公开模板 · 首次部署须在本机自验）

> **先说在前面**：没有真正能绝对避免封号的办法，能做的只有通过各种工程隔离与规范操作尽可能降低风险，并在遇到异常时见招拆招。
>
> **可验证的隔离设计 + 可交接的本地协作。** 本项目是面向个人用户的开源 Agent Skill 与参数化工程模板，**不是“免验即安全”的一键黑盒软件**——每台机器的系统、网卡、固件与上游线路都不同，Skill 会主动提醒并陪你在**你自己的机器上**逐项完成**冷启动、热启动/重载、入口阻断负向断网**等自检；未在你本机自检通过前，请勿接入正式账号。

| 入口 | 目标 | 状态 |
|---|---|---|
| A1 本机 Profile + CLI | 应用层分流，非 Fail-Closed | 通用模板，先读 [本机路线](references/02-route-a-local-and-fingerprint.md) |
| A2 本机整机 | TUN + OS 出站防护 | 跨平台参考设计（部署前须在本机自验） |
| B VMware + 专用 OpenWrt | 网关默认拒绝 + 客机 GPO；人工防误启动辅助 | [参数化参考实现](references/03-route-b-vm-openwrt-fortress.md)（须在本机完成冷/热启动自验） |
| C Linux VPS | C1 原生出口 / C2 代理默认拒绝 | [两种独立契约](references/04-route-c-vps-devbox.md)，不支持 Windows Desktop |
| 搭完后的可选进阶扩展（模型无关） | 宿客权限分离、私有 Git 仓、交接和本地转换 | [可独立使用](references/06-multi-agent-and-local-first.md)，不需要账号或代理 |

信任宿主、虚拟化、网关固件、客机管理员和上游运营方；同一桌面账户的其他程序不是防误启动辅助可约束的对象。顶层 [Skill（双语主入口）](SKILL.md) / [Skill 中文版](SKILL.zh-CN.md) 定义 S0–S4 和 A/B/C；[01 验收协议](references/01-route-selection-and-preflight.md) 定义功能、边界和停条件。

## 五分钟：只做离线盘点，不部署

1. 从本地浏览器直接打开 [中文交互向导](assets/interactive-guide.html)（或 [English Guide](assets/interactive-guide.en.html)）；单 HTML 没有外部资源。**只有打开本地文件才是离线**；网页托管（GitHub Pages）访问需要联网。复制不是批准、勾选不是安全证据。
2. 若要体验 Skill，只复制 `claude-fortress/` 子目录。Claude Code 使用用户目录 `.claude/skills/` 或项目级同名目录；Codex 与其他宿主使用各自已启用的 Skills 目录，以本机配置为准。先用已可用的宿主，不要求安装或打开待验收的客户端。
3. 对 Agent 说：“请读 Skill，给我一份 A 档、离线、只读的盘点清单和对比建议；不要写文件、联网、改网卡、安装或启动。”安装 Skill 文件本身不属于 A 档，离线盘点也不等于宿主 Agent 没有自己的后台联网。

## 路线 B 首次部署必做自检（在你的机器上亲自验证）

- 使用 [统一配置样例](assets/route-b-config.example.json)、[独立证据样例](assets/route-b-evidence.example.json) 和 [Windows 部署说明](references/route-b-windows-operations.md)。样例故意不可运行；私有配置、探针回执和实机证据不得放进发布包。`claude-env-check.ps1` 只提供中性功能观测，不能单独替代下面的边界自检。
- OpenWrt 只使用 [专用持久加载流程](references/03-route-b-vm-openwrt-fortress.md)，禁止在共享网关用作导入。保存 sysctl/规则、VM 配置和独立恢复能力。所有可能切断网络或改变隔离边界的动作，先获 C 档明确同意。
- **正式接入账号前，必须按 Skill 提示在你本机亲自完成以下 4 类实测**：
  1. **冷启动自检**：网关与 VM 完全关机后冷启动，确认在代理/TUN 尚未拉起前，网关默认不转发、WAN 侧零未授权出站；
  2. **热启动 / 重载自检**：模拟网关重启、规则重载失败、宿主机切换 TUN/系统代理或客机休眠唤醒后，防护边界依然闭合且**新建管理 SSH** 可达；
  3. **负向断网演练**：网关临时阻断上游入口，确认客机双路径彻底断网、旧连接不残留、不回退直连，到期后自动恢复；
  4. **泄漏与边界复核**：独立核对 DNS、IPv6、UDP、WebRTC 与第二网卡情况。未在本机跑通前，切勿接入正式账号。

## 发布与许可

自有内容使用 [MIT](LICENSE)；见 [打包和来源复核清单](references/release-review.md)。不要提交实值、账号资料、日志或参考资料原包，不要公开整个工作仓。遵守实际所在地与服务资格要求，登录、付款和申诉由用户本人完成。

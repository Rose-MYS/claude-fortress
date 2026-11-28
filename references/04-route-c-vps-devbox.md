# 04｜路线 C：远程 VPS 开发机路线（参考设计）

> 适用于偏好纯 Linux 远程终端开发（Claude Code CLI）的用户。**先明确出口模式，再动手加固；任何防火墙改动前必须先核验带外控制台（VNC/Web Console）与自动回滚定时器。**

---

## 1. 先选定两种出口模式之一

| 模式 | 适用前提 | 防火墙目标 |
|---|---|---|
| **模式 C1：原生纯净出口** | VPS 自身具备纯净静态 ISP / 住宅 IP 且位于受支持地区 | 入站最小暴露 + 禁 IPv6 泄漏（若仅走 IPv4）+ 常规安全加固 |
| **模式 C2：算力机 + 代理出站（默认拒绝）** | 普通机房 VPS 仅做算力，禁止以 VPS 原生机房 IP 访问外部服务 | **出站默认拒绝（nftables）**：仅放行管理 SSH、上游固定代理入口 IP:Port、必要 DNS/系统更新例外，其余公网出站全部丢弃 |

---

## 2. 防锁死前置与基础加固（B / C 档）

1. **带外恢复前置与一键防锁死加载（C 档必做）**：
   - 先确认云商 Web Console / VNC 可用；注意最小化 Debian / Ubuntu 云镜像默认可能未预装 `nftables`，先确认 `command -v nft`（缺失则先 `apt-get update && apt-get install -y nftables`）。
   - 模式 C2 可直接使用本包内置的通用模板 [../assets/vps-c2-egress.nft.tmpl](../assets/vps-c2-egress.nft.tmpl)（原子替换自有表 `inet cf_vps_c2`，不全局 flush）与防锁死脚本 [../scripts/vps-c2-apply-with-rollback.sh](../scripts/vps-c2-apply-with-rollback.sh)（已在 Debian 12 + `systemd` 实机验证 DryRun、坏语法拦截、超时自动回滚与取消回滚常驻）：
     ```sh
     # 1）先替换模板占位符（<MGMT_SSH_CIDR> / <SSH_PORT> / <ENTRY_IP> / <ENTRY_PORT>）并做离线语法预检
     sh scripts/vps-c2-apply-with-rollback.sh --rules /etc/claude-fortress/vps-c2.nft --dry-run

     # 2）经 C 档确认后以 180 秒自动回滚窗口加载（自动备份原表并布防 cf-vps-c2-rollback.timer）
     sudo sh scripts/vps-c2-apply-with-rollback.sh --rules /etc/claude-fortress/vps-c2.nft --timeout 180s --confirm-tier-c

     # 3）保持旧会话，另开一条全新 SSH 验证密钥、权限与计数器：
     sudo nft list counters table inet cf_vps_c2
     #    全部核验通过后取消自动回滚（若不取消，到期自动还原，绝不锁死 SSH）：
     sudo systemctl stop cf-vps-c2-rollback.timer
     ```
2. **SSH 与系统加固**：仅密钥登录、禁用密码、`MaxAuthTries 3`、`fail2ban`、开启自动安全更新。
3. **IPv6 与时区**：若出口仅走 IPv4，在内核与代理侧同步禁用 IPv6 出口；时区对齐出口地区（`timedatectl set-timezone <TZ>`）。

---

## 3. S1 中性验收与远端 IDE 边界

1. **中性出口与 DNS 核验**：C1：以选定的原生出口为基线，不做代理入口断线声明。C2：两个独立中性站点测代理出口，C 档限时阻断入口并实测不能旁路。IPv6 看绑定、路由和出口证据，不能把一次 curl 失败当阻断；DNS 检查实际解析日志及出口抓包，不只看配置。自动更新/DNS 例外必须列出、可验证，不能绕开所声明的边界。
2. **远端 IDE / 容器边界**：若使用 VS Code / Cursor Remote-SSH 或 Docker 容器：
   - 明确区分“宿主机本地扩展”与“远端 VPS 扩展”，避免本地 IDE 扩展在宿主机侧发起 Claude 请求；
   - 审查 SSH 端口转发、Agent Forwarding 与容器 `host` 网络模式，避免绕过 VPS 的出站白名单。

---

## 4. 社区图形化部署工具参考与避坑提示

若走远程 Ubuntu VPS 路线且偏好图形化部署，可参考开源桌面工具（如社区的 `safe-code` 等，封装了 VPS 初始化、SSH 隧道、XFCE 远程桌面与目录挂载），但使用前务必核对两条安全边界：
1. **图形化工具不等于干净出口**：仍须先按第 1 节确认 VPS 出口模式，切忌用普通机房 VPS 原生 IP 硬上；
2. **慎用高争议/高权限扩展功能**：避免将个人订阅/CLI 封装为自建 API 网关桥接转发，并谨慎开启“允许云端 VPS 经反向 SSH 控制宿主机命令行”（防云端失陷或 Prompt Injection 反向击穿宿主机）。

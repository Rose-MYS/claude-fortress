# 03｜路线 B：Windows VM + 专用 OpenWrt 隔离网关（完整实战蓝图 · 分层可选）

> **怎么用这本手册**：本手册脱敏沉淀自作者长期实机运行的 **VM + 独立 OpenWrt 网关 + Windows 客机 GPO** 完整方案，并拆为**「第一部分：核心最小闭环（MVP 5 步保姆级操作）」**与**「第二部分：进阶可选积木」**。
> - **新手**可以按 MVP 5 步直接参照脱敏范例照抄跑通；
> - **有经验的用户**可以只采用核心双层 Fail-Closed 骨架，按自己的代理协议、网段或自动化习惯自由替换任意积木。
> - **边界提醒**：脚本与模板均为通用参数化版本，**不替任何用户的实际机器担保**；上线前必须按第 5 步在自己的机器上完成冷启动、重载失败与入口阻断自验。A/B/C 档审批按 [SKILL](../SKILL.md) 的真实后果分级执行。

---

## 0. 先看懂整体架构（为什么客机内防火墙还不够？）

仅靠虚拟机里的防火墙或看门狗，存在「刚开机服务未就绪的冷启动窗口」与「策略被改漂移」风险。路线 B 用**两道互不依赖的门**锁死出口（客机外 OpenWrt 网关 + 客机内 Windows GPO）：

```text
Windows 11 客机（例：192.168.242.129，仅保留 1 块虚拟物理网卡 Ethernet0）
  │ VMware 专用隔离网段（LAN Segment，例：VM-Egress-Isolated）
  ▼
专用 OpenWrt 网关虚拟机（LAN: 192.168.242.1 / WAN: 192.168.125.3）
  │ nftables 默认拒绝所有转发 + 关闭 IPv6 转发
  │ 公网转发白名单仅放行当前唯一代理入口 <ENTRY_IP>:<ENTRY_PORT>/TCP
  ▼
VMware VMnet8 NAT → 宿主机物理网络（宿主机开 TUN 时按第 4 步放行 vmnat.exe）
  ▼
上游住宅代理节点 → 固定住宅出口 <RESIDENTIAL_EGRESS_IP>
```

**前置硬件与介质准备（仅支持 VMware Workstation + 独占 OpenWrt + Windows 11）**：
- 建议宿主机 ≥ 16 GB 内存、≥ 80 GB 可用磁盘；
- 提前用官方签名/SHA-256 核验离线介质：Windows 11 ISO、OpenWrt x86-64 镜像（`combined-ext4.img` 转 `.vmdk`）、代理核心与 OpenSSH；
- 保留**独立带外控制通道**：VMware 宿主机控制台 + OpenWrt 虚拟机串口（Serial Port），改动前留好离线回滚副本。

---

## 第一部分：核心最小闭环（MVP · 新手 5 步保姆级操作）

> 下面 5 步是跑通路线 B 的**最小必需步骤**；每一步都能单独验证，不跨步盲操作。

### 第 1 步：先关门，再接客机——搭 VMware 隔离拓扑（C 档）

1. **新建隔离网段**：在 VMware Workstation 中，打开任意虚拟机设置 → 网络适配器 → **LAN 区段（LAN Segments）** → 新建专用隔离网段（例如命名 `VM-Egress-Isolated`）。
2. **给 OpenWrt 网关配两块网卡 + 串口（免 `qemu-img` 建盘要点）**：
   - **磁盘转换（免装 `qemu-img`）**：官方 `openwrt-*-x86-64-generic-ext4-combined.img.gz` 先按官方 `sha256sums` 校验；注意 OpenWrt 24.10.x 的 `.img.gz` 末尾附带 34 字节 `fwtool` 元数据尾部，Python 标准 `gzip.open()` 会报错，需用流式 `zlib.decompressobj(16 + zlib.MAX_WBITS)` 解压为 `openwrt-flat.vmdk`，再按 `文件字节数 / 512` 写出纯文本 `monolithicFlat` 描述文件 `openwrt.vmdk` 即可直接挂载到 VMware；
   - **网卡 1（LAN，接内网）**：绑定刚才新建的 `VM-Egress-Isolated`（记下两块网卡的 MAC 地址，进 OpenWrt 后按 MAC 核对哪个是 LAN、哪个是 WAN）；
   - **网卡 2（WAN，先不接生产网）**：绑定 `NAT (VMnet8)`，**先取消勾选「已连接」和「启动时连接」**，等第 2 步离线失败态演练通过后再勾回；
   - **添加串行端口（Serial Port）**：选「使用命名管道」（如 `\\.\pipe\cf-openwrt-serial`，该端是服务器、另一端是应用程序），哪怕防火墙改错也能经串口带外管理。
3. **给 Windows 11 客机只留 1 块网卡**：
   - 仅保留唯一虚拟物理网卡（如 `Ethernet0`）并接入 `VM-Egress-Isolated`；
   - **红线**：不要桥接，不要给客机加第二块网卡，网关未启动时客机在链路层即彻底断网。
4. **规划互不重叠的示例网段**（可照抄示例或自行替换）：
   - WAN（VMnet8）：在 VMware「编辑 → 虚拟网络编辑器 → VMnet8 → NAT 设置」中查看实际子网前缀、NAT 网关 IP 与宿主机管理 IP `<HOST_MGMT_IP>`（如 `192.168.125.1`），为网关 WAN 分配同网段静态 IP `<GATEWAY_WAN_IP>`（如 `192.168.125.3/24`，默认网关指向 VMnet8 NAT 网关）；
   - LAN（隔离网段）：网关 LAN `<GATEWAY_LAN_IP>`（如 `192.168.242.1/24`）、客机固定租约 `<GUEST_LAN_IP>`（如 `192.168.242.129`）。

---

### 第 2 步：配置专用 OpenWrt 默认拒绝网关（C 档）

> **仅支持下述持久加载法**；不要在生产共享路由器上使用本模板。

1. **先停用自带防火墙（顺序不可颠倒）**：经串口进入 OpenWrt，在 WAN 未接生产网时备份原配置，关闭 IPv4/IPv6 转发并停用禁用 `firewall`（fw4）：
   - **真机实测必避坑**：OpenWrt 24.10.x 的 `/etc/init.d/firewall stop` 会清空**所有** `nft` 表（包括 `inet vm_gate`），因此**必须先停用禁用 `fw4`，再加载 `claude-fortress`**。
2. **用 UCI 配双网口与固定租约（已真机验证命令块）**：
   - **真机实测必避坑**：OpenWrt 24.10.x 默认把 `eth0` 桥接在 `br-lan` 下；若模板 `<LAN_IF>` 填 `eth0`，必须通过 UCI 解除桥接（`network.lan.device='eth0'`），否则数据包实际从 `br-lan` 进入而匹配不到 `eth0` 规则：
   ```sh
   uci batch <<'EOF'
   set network.lan=interface
   set network.lan.device='eth0'
   set network.lan.proto='static'
   set network.lan.ipaddr='192.168.242.1'
   set network.lan.netmask='255.255.255.0'
   set network.lan.ip6assign='0'
   set network.lan.force_link='1'
   set network.wan=interface
   set network.wan.device='eth1'
   set network.wan.proto='static'
   set network.wan.ipaddr='192.168.125.3'
   set network.wan.netmask='255.255.255.0'
   set network.wan.gateway='<VMNET8_NAT_GW_IP>'
   set network.wan.peerdns='0'
   set network.wan6.auto='0'
   set dhcp.lan.force='1'
   set dhcp.lan.ra='disabled'
   set dhcp.lan.dhcpv6='disabled'
   set dhcp.lan.ndp='disabled'
   set dhcp.fortress_guest=host
   set dhcp.fortress_guest.name='fortress-guest'
   set dhcp.fortress_guest.mac='<GUEST_NIC_MAC>'
   set dhcp.fortress_guest.ip='192.168.242.129'
   set dhcp.@dnsmasq[0].port='0'
   set dhcp.@dnsmasq[0].noresolv='1'
   set dhcp.@dnsmasq[0].localuse='0'
   commit network
   commit dhcp
   EOF
   /etc/init.d/network reload
   /etc/init.d/dnsmasq restart
   /etc/init.d/firewall disable && /etc/init.d/firewall stop
   ```
   - 宿主机到客机的管理 SSH 经网关 WAN `22` 端口 DNAT 到客机 `22`（宿主机用固定主机密钥校验），网关自身始终通过串口管理。
3. **断网经串口传入三件套模板（全部仅 root 可写）**：
   - **真机实测必避坑**：默认 OpenWrt 24.10.x 自带 `/usr/sbin/nft`、`flock`、`sha256sum`、`awk`，但**没有 `base64` 和 `stat` 命令**。断网环境下可通过串口分块写入 Base64 再用 `awk` 解码落盘（或挂载临时只读 ISO 拷入），落盘后必须用 `sha256sum -c` 逐个核对，并用 `ls -l` 确认权限：
   - [openwrt-claude-fortress.sysctl.conf](../assets/openwrt-claude-fortress.sysctl.conf) → `/etc/sysctl.d/99-claude-fortress.conf`（注意固件自带 `10-default.conf` 会先设 `ip_forward=1`，再由 `99-claude-fortress.conf` 覆写回 `0`）；
   - [openwrt-vm-gateway.nft.tmpl](../assets/openwrt-vm-gateway.nft.tmpl) 展开并替换全部占位符（两网卡名必须不同）→ `/etc/claude-fortress/gateway.nft`；
   - [openwrt-claude-fortress.init](../assets/openwrt-claude-fortress.init) → `/etc/init.d/claude-fortress`（`chmod 700`）并执行 `/etc/init.d/claude-fortress enable && /etc/init.d/claude-fortress start`。以后**只能经此 init 服务启停和重载**（先关转发 → 语法校验 → 单批替换自有表 `inet vm_gate` → 核对表存在才开 IPv4 转发；任何失败均保持转发关闭，绝不全局 flush）。
4. **先离线演练失败态与重启再接 WAN**：在未接生产 WAN 时，演练一次重启（注意重启后串口约第 7 秒即可登录，需等待 `procd` 跑完 `S25claude-fortress` 再查表）、故意破坏规则语法并执行 `reload`（确认返回非零且 `/proc/sys/net/ipv4/ip_forward` 降为 `0`）、修复后 `reload` 恢复为 `1`；查看具名计数器用 **`nft list counters table inet vm_gate`**（注意 `nftables v1.1+` 必须带 `table` 关键字；空计数不等于零流量，后续必须与 WAN 抓包互证）。确认无误后，经 C 档确认再把 OpenWrt 网卡 2（VMnet8）的「已连接 / 启动时连接」勾回。

---

### 第 3 步：Windows 11 客机受保护配置与一键 GPO 防火墙（C 档）

1. **先装好客机核心组件，再填受保护私有配置**：
   - 详细权限要求见 [Windows 客机部署与门控说明](route-b-windows-operations.md)：先用离线核验介质在客机装好代理核心（确认其绝对路径与 TUN 网卡名，如 `Mihomo`）以及 Windows OpenSSH Server（确认 `sshd.exe` 绝对路径并验证本地服务就绪），避免先锁 GPO 后才发现代理或 SSH 未装；
   - 在客机以管理员创建 `%ProgramData%\ClaudeFortress`（仅 Administrators/SYSTEM 可写，普通桌面账户只读/执行，无重解析点），放入 `route-b-common.ps1`、`guest-egress-guard.ps1`、`guest-gpo-setup.ps1`、`claude-env-check.ps1`、`guest-claude-gate.ps1`；
   - 复制 [route-b-config.example.json](../assets/route-b-config.example.json) 保存为 `C:\ProgramData\ClaudeFortress\config.json` 并替换为真实私有值（主机名、桌面用户 SID、代理核心与 `sshd.exe` 绝对路径、入口 IP/端口、预期出口 IPv4、MSIX 应用 ID/发布者），**绝不提交或分享私有配置**。新手/Agent 可用下面 3 行离线只读命令直接查出最难填的 3 个字段：
     ```powershell
     # 1）在普通桌面账户下查 desktop_sid
     whoami /user /fo list
     # 2）查 MSIX 应用的 PackageFamilyName 与 app_publisher（把 *Claude* 换为目标包名）
     Get-AppxPackage | Where-Object { $_.Name -like '*Claude*' } | Select-Object Name, PackageFamilyName, Publisher
     # 3）查精确 app_id（AUMID）
     Get-StartApps | Where-Object { $_.Name -like '*Claude*' } | Format-Table -AutoSize
     ```
2. **用 `guest-gpo-setup.ps1` 先预览（DryRun），再一键生成 GPO 并保留回滚**：
   - 确认通过 VMware 客机控制台可随时本地操作与恢复后，先跑 `-Mode DryRun` 核对规则，再执行 `-Mode Apply -ConfirmTierC`（自动将 Domain / Private / Public 三个 GPO Profile 设为默认阻断入/出站、关闭本地规则合并，并在 `localhost` GPO 存储中精确创建与 `guest-egress-guard.ps1` 匹配的 6 条内部 `Name` 规则）：

   ```powershell
   # 1）先离线只读预览（A 档，不改系统）
   powershell -NoProfile -File "C:\ProgramData\ClaudeFortress\guest-gpo-setup.ps1" -ConfigPath "C:\ProgramData\ClaudeFortress\config.json" -Mode DryRun

   # 2）经 C 档确认后，在客机管理员终端执行（自动先备份现有 localhost GPO）
   powershell -NoProfile -File "C:\ProgramData\ClaudeFortress\guest-gpo-setup.ps1" -ConfigPath "C:\ProgramData\ClaudeFortress\config.json" -Mode Apply -ConfirmTierC -BackupDir "C:\ProgramData\ClaudeFortress\backups"

   # 3）如需回滚（保留独立控制台，按 Apply 输出的备份路径还原）
   powershell -NoProfile -File "C:\ProgramData\ClaudeFortress\guest-gpo-setup.ps1" -ConfigPath "C:\ProgramData\ClaudeFortress\config.json" -Mode Rollback -BackupPath "<BACKUP_PATH>"
   ```

   **6 条 GPO 放行规则对照表**（`PolicyStore=localhost`、`Profile=Any`、`Action=Allow`、`Edge=Block`、禁覆盖阻断）：

   | 内部 Name | 方向 | 限定范围 |
   |---|---|---|
   | `CG-Managed-Node` | 出站 | LAN 网卡、可信代理核心绝对路径、`<ENTRY_IP>:<ENTRY_PORT>` TCP |
   | `CG-Managed-Tun` | 出站 | TUN 网卡、本地 Fake-IP 源网段（例 `198.18.0.0/16`，先实测确认） |
   | `CG-Managed-Loop` | 出站 | 远端 IPv4 回环 `127.0.0.0/8` |
   | `CG-Managed-DhcpOut` | 出站 | LAN 网卡、`Dhcp` 服务、UDP 68→67、网关 IP 与 `255.255.255.255`（**保留广播，否则续租失败**） |
   | `CG-Managed-DhcpIn` | 入站 | LAN 网卡、`Dhcp` 服务、UDP 本地 68/远端 67、网关 IP |
   | `CG-Managed-Ssh` | 入站 | LAN 网卡、可信 `sshd.exe` 绝对路径、`<HOST_MGMT_IP>`、TCP 本地 22 |

3. **立即离线核对 GPO 策略**：运行 `guest-egress-guard.ps1 -ConfigPath <私有配置> -Status -PolicyOnly`，确认 `policy_ok: true`；若某项报错，先查实际策略与 CIM 值，**绝不为通过而放宽白名单**。

---

### 第 4 步：宿主机 TUN 防冲突配置（仅宿主机开启 TUN 时需要）

如果宿主机代理客户端开启了 **TUN 模式**，可能会强行劫持 VMware NAT 进程（`vmnat.exe`），导致 `客机代理 → OpenWrt → 宿主机 TUN` 双层嵌套、出现假 2 ms 延迟或并发超时：
- **先核查影响（可能影响其他 NAT 客机或隔离边界时按 C 档）**：确认宿主机没有其他依赖宿主 TUN 的 NAT 客机；
- 按 [host-clash-vmnat-bypass.yaml](../assets/host-clash-vmnat-bypass.yaml) 在宿主机规则模式前置进程放行规则（**不得前置 `MATCH`**），然后复测宿主机原有分流与客机双路径。

---

### 第 5 步：S1 独立采证、负向自验 → S2/S3 人工启动

1. **正向双路径中性探针（B 档，零 Claude 接触）**：
   - 先用 [01 适用矩阵](01-route-selection-and-preflight.md) 与 [Windows 门控说明](route-b-windows-operations.md) 跑 `claude-env-check.ps1 -ConfigPath <私有配置> -RequestId <32位十六进制ID> -AuthorizedNeutralProbe`；
   - 也可在客机手工核对两条生产路径均返回同一预期 `<RESIDENTIAL_EGRESS_IP>`：
     ```powershell
     # 路径 1：直走 TUN 虚拟网卡
     curl.exe -q -4 -fsS --max-time 8 --noproxy '*' https://api.ipify.org
     # 路径 2：走本地 HTTP/mixed 代理端口
     curl.exe -q -4 -fsS --max-time 8 --noproxy no-proxy.invalid --proxy http://127.0.0.1:7897 https://api.ipify.org
     ```
2. **负向边界与独立证据（硬门槛）**：
   - 在自己机器上完成并记录：冷启动 WAN 零直出抓包、网关重载失败仍阻断、C 档限时阻断上游入口（保留并验证**新建管理 SSH**，**不要靠停 `clash_verge_service` 测断网**）、IPv6 绑定/路由核查、代理 DNS 日志、以及目标浏览器 WebRTC 无泄露；
   - 管理员按 [route-b-evidence.example.json](../assets/route-b-evidence.example.json) 关联配置/报告/私有证据包 SHA-256 写入受保护 `evidence\` 目录。
3. **S2/S3 人工启动（C 档）**：
   - 所有适用 S1 证据均为 `pass` 后，由客机普通桌面用户本人在本地桌面运行 `guest-claude-gate.ps1 -Mode Launch -ConfigPath <私有配置> -RequestId <ID>`，当场输入 C 档确认后激活应用（这是防误启动辅助，不替代底层网络隔离）。

---

## 第二部分：进阶可选积木（核心跑通后按需选用）

> 以下 3 个模块均为作者在实机运维中进一步搭建的**可选增强能力**。你可以完全不装、只装其中某一个，或按自己的习惯重新实现：

### 积木 A｜宿主机只读预检与顺序启机（可选）
- **痛点**：同时管理 OpenWrt 网关和 Windows 客机，手工点开顺序错了客机就断网；误移 `.vmx` / `.vmdk` 描述文件还会导致网关起不来。
- **推荐做法**：在宿主机写轻量化启动脚本，只做管理面动作：
  1. 核对 OpenWrt 网关磁盘链与描述文件 SHA-256（缺失仅提示离线核验恢复，绝不覆盖新数据盘）；
  2. 先启动 OpenWrt 网关并等串口/就绪，再启动 Windows 客机；
  3. 用预先固定的主机密钥 SSH 连客机，**仅运行 `guest-claude-gate.ps1 -Mode Inspect` 收集脱敏状态回执**（公开版不部署远程一键自动拉起应用，也不在宿主机模拟客机 C 档批准）。

### 积木 B｜上游入口动态变更的事务化更新思路（可选）
- **痛点**：部分独享住宅节点出口 IP 固定，但上游中转入口 IP/端口会定期变动；一旦入口变了，OpenWrt 白名单和客机 GPO 白名单就会挡住流量。
- **事务化安全思路（避免半途锁死或扩大白名单）**：
  1. **凭据隔离**：订阅地址等敏感信息只存在宿主机本机 DPAPI 加密区或受保护私有目录，绝不进 Git 或共享区；
  2. **独立预检**：在**独立隔离准备环境**用新入口验证双中性 HTTPS 端点，确认出口仍为 `<RESIDENTIAL_EGRESS_IP>`；
  3. **先备份再原子切换（切换期间保持阻断）**：冻结客机启动，留存 OpenWrt 规则、客机 GPO（可用 `guest-gpo-setup.ps1` 备份）、代理配置的本地哈希与代际号；同步更新三端配置并热重载，**切换窗口内保持阻断，三端复验通过后再放行**（含凭据的备份仅限本机受保护存储，日志与证据包脱敏后再分享）；
  4. **复验与自动回滚**：复验客机 TUN 与本地代理双路径；任一步失败立即经带外通道恢复整套已知好配置（**不要靠恢复整机快照覆盖掉客机里的项目资料**）。

### 积木 C｜多 Agent 权限分离本地协作区（可选）
- 核心环境跑通后再按需挂载，详见 [06-multi-agent-and-local-first.md](06-multi-agent-and-local-first.md)（严格分离宿主机与客机读写权限，不共享 `.git`）。

---

## 第三部分：真实踩坑速查（3 个高频问题）

更多排障细节与时间线模板见 [07-troubleshooting-and-cleanup.md](07-troubleshooting-and-cleanup.md)：

1. **宿主机切 TUN 后客机代理假 2 ms 延迟 / 并发超时**：宿主 TUN 劫持 `vmnat.exe` 造成双层嵌套与 `198.18.0.0/16` Fake-IP 冲突 → 见第 4 步放行 `vmnat.exe`（核查无其他依赖宿主 TUN 的 NAT 客机，不含 `MATCH`）。
2. **整理目录误移网关 `.vmx` / `.vmdk` 描述文件导致客机彻底断网**：反向证明 Fail-Closed 生效；带外停机核对 backing 文件、容量与已知好版本 SHA-256 后再恢复描述文件，不覆盖数据盘。
3. **客机 DHCP 无法续租或偶发断网**：核对 GPO `CG-Managed-DhcpOut` 是否保留了广播地址 `255.255.255.255`，以及 OpenWrt `input/output` 链是否放行了 UDP 68↔67。

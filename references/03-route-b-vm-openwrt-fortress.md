# 03｜路线 B：Windows VM + 专用 OpenWrt 网关（未实机验收的参考实现）

设计目标是“客机内 GPO + 客机外默认拒绝”，不是当前版本的实测结论。只支持 **VMware Workstation + 独占 OpenWrt + Windows 11** 的文档拓扑。保留独立宿主机控制台、网关串口、离线回滚副本；A/B/C 按 [SKILL](../SKILL.md) 的实际后果分级。

## 1. 先关门，再接客机（C 档）

1. 保持客机断网，网关 WAN 不接生产网络。建立独立 VMware LAN Segment，仅连接网关 LAN 与客机唯一一块虚拟物理网卡；网关 WAN 才连接 VMnet8。不要桥接，不许第二张客机网卡。Windows、Clash、OpenSSH 用独立签名/哈希核验过的离线介质准备。
2. 规划互不重叠的示例网段：WAN 对应 `<HOST_MGMT_IP>`、`<GATEWAY_WAN_IP>`；LAN 包含 `<GATEWAY_LAN_IP>`、`<GUEST_LAN_IP>`。仅向该客机分配固定租约，关闭 DNS 转发和无关的网关本机监听；WAN 用静态地址。SSH 管理走 DNAT，宿主固定校验客机主机密钥；网关自身通过串口管理。
3. **仅支持下述持久加载法。** 在两侧隔离、带外控制可用时，备份原规则、sysctl、网卡与启动项；关闭 IPv4/IPv6 转发；停止并禁用专用网关的 `firewall`（fw4）服务，确保无其他防火墙、热插拔、流量卸载、容器或启动项拥有相同转发控制。不要在生产共享网关使用此模板。
4. 安装 [sysctl 零转发默认](../assets/openwrt-claude-fortress.sysctl.conf) 到 `/etc/sysctl.d/99-claude-fortress.conf`；核对固件确实会在连通前应用且无后来设置覆盖。将 [规则模板](../assets/openwrt-vm-gateway.nft.tmpl) 展开成 `/etc/claude-fortress/gateway.nft`。全部替换接口、地址、端口；两接口必须不同，四个管理/内网端点必须匹配实际方向。文件及父目录仅 root 可写。
5. 将 [唯一 init 模板](../assets/openwrt-claude-fortress.init) 安装到 `/etc/init.d/claude-fortress`，设为 root 所有且可执行。先确认 `/usr/sbin/nft` 与本地 `flock` 可用，再启用此启动项。只能经此服务启动、重载、停用：先关转发，语法检查后在单一批次只替换自有表，检查表存在后才开 IPv4 转发。检查或加载失败保留转发关闭；不直接全局 flush，不用 hotplug 或 sysctl 后台再开启转发。
6. 先在未接生产 WAN 时测试重启、缺失规则、语法不通过、重复重载（失败时不转发且有带外恢复）；锁冲突只拒绝新操作，不将旧规则状态标为本次加载成功。再经 C 确认接入，冷启动和 WAN 验收通过前不要放入认证态账号。使用 `nft list counters inet vm_gate` 查看具名计数器和方向；丢弃计数不是泄漏，空计数也不能证明没有流量，必须与 WAN 抓包互证。

## 2. 客机 GPO 与统一配置（C 档）

GPO 将 Domain/Private/Public 防火墙启用、入出站默认 Block、关闭本地防火墙/IPsec 合并、无禁用接口；清除所有额外启用的 Allow（含非当前 Profile）。按下表设置规则实际内部 **Name**，不只是显示名；全部为 GroupPolicy/Any profile，默认过滤值 Any，Edge=Block，禁止覆盖阻断。保留独立恢复路径。

| Name | 方向 | 限定 |
|---|---|---|
| CG-Managed-Node | 出 | LAN、可信代理核心绝对路径、入口 IPv4/端口 TCP |
| CG-Managed-Tun | 出 | TUN 接口、本地 Fake-IP 源网段（先实测出站时的源地址） |
| CG-Managed-Loop | 出 | 远端 IPv4 回环 /8 |
| CG-Managed-DhcpOut | 出 | LAN、Dhcp 服务、UDP 68→67、网关或广播 |
| CG-Managed-DhcpIn | 入 | LAN、Dhcp 服务、UDP 目标 68/源 67、网关 |
| CG-Managed-Ssh | 入 | LAN、可信 sshd 绝对路径、宿主管理 IPv4、TCP 目标 22 |

将 [统一配置样例](../assets/route-b-config.example.json) 复制到客机私有区替换占位符，绝不提交实值。按 [Windows 部署与门控说明](route-b-windows-operations.md) 放置脚本和 ACL。只读 Guard 不是 GPO 安装器，也不会阻断漂移；无法匹配其预期过滤器时，先查实际策略与 CIM 值，不为通过而放宽策略。

宿主开 TUN 时，按 [宿主规则片段](../assets/host-clash-vmnat-bypass.yaml) 检查是否需要 VMware NAT 例外。**可能改变隔离边界或其他 NAT 客机出口时按 C**；只在核验目标、进程实际路径及影响后按卡操作，复测所有相关客机、宿主原有分流和有效合并规则。不得前置 MATCH。

## 3. 独立证据、启用、恢复

[01 的 S1 合同](01-route-selection-and-preflight.md) 与 [Windows 门控说明](route-b-windows-operations.md) 是验收入口。先取独立 DNS、IPv6、冷启动、重载失败、现有连接、入口失效、UDP/QUIC、第二网卡拓扑、管理 SSH、目标浏览器 WebRTC 的证据；再经同意跑短时功能探针。除代理 TCP 与精确的 SSH 管理外，测试不允许出现额外 WAN 出站；核对 PMTU/大包行为与限定的 ICMP 错误。入口阻断必须另按 C 档、限时、验证新建 SSH；不停止代理服务。证据缺失不启动。

入口换代：保留旧配置与会话数据，单写者冻结启动，预先在**独立隔离准备环境**验证新入口，不扩大生产白名单。记录网关规则、客机 GPO、代理配置的本地哈希、代际与回执；不以共享 Git 或状态样例保存订阅/凭据。任一步失败保持隔离，经带外恢复整套已知配置，再重验，不恢复会覆盖项目资料的整机快照。当前没有跨机自动事务，也没有达到公开发布标准所需的实机验收。

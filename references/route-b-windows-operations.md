# 路线 B｜Windows 客机部署、验收与宿主端边界

## 受保护的部署约定

在客机由管理员、经 C 档确认部署。使用 64 位 Windows PowerShell 5.1。将 `route-b-common.ps1`、`guest-egress-guard.ps1`、`claude-env-check.ps1`、`guest-claude-gate.ps1` 和私有受保护配置存于 `%ProgramData%\ClaudeFortress`。创建 `reports`、`evidence` 两个同样受保护的子目录。不继承普通主体的写入权限；Administrators/SYSTEM 拥有且可写，指定桌面账户仅 Read/Execute，所有父路径无重解析点。核验管理员控制代理/sshd 完整路径及父目录，同时审计签名、允许的 ACL、任务与 GPO 来源。桌面账户必须是普通用户。网络探针由有权写入报告目录的受控管理员执行；报告默认为脱敏，私有诊断显式开启后不得分享。

按 [配置样例](../assets/route-b-config.example.json) 填目标主机/专用用户 SID、代际、适配器、IPv4、TCP/本地代理端口和配置中的 MSIX 应用 ID/发布者。SID、主机名、真实 IP 仅存本机私有配置；样例故意不能运行。只支持指定身份的 MSIX 应用，不匹配则停止，不降级到按名称模糊查找。

## S1 功能和独立证据、S2/S3 人工启动

1. 离线先用 Guard 的 `-ConfigPath <私有配置> -Status -PolicyOnly` 核对策略。功能探测先取得覆盖端点、代理与来源 IP 暴露的明确 B 档批准。用新 GUID 的 N 格式作为请求 ID，执行 checker 的 `-ConfigPath <私有配置> -RequestId <ID> -AuthorizedNeutralProbe`。退出 0 仅表示本次双路径 IPv4 功能通过且 IPv6 探针未收到响应；不证明 DNS 或 IPv6 阻断。
2. 依据 [独立证据样例](../assets/route-b-evidence.example.json)，由掌握 WAN 抓包与配置的受信管理员复核检查项，把配置文件 SHA-256、功能报告 SHA-256、私有证据包 SHA-256 与本次请求关联，在受保护 evidence 目录落盘为同一 ID 的 JSON。每个边界项必须有证据并标 pass。无法检查目标浏览器时保持 not_run，不降级放行。24 小时证据窗口、15 分钟功能窗口不是安全保证，任何网络、固件、GPO、客户端、模式或代际变化都应作废旧证据并重采。脚本验证受保护的人工回执，并不解析抓包或认证远端设备真实状态。
3. 由指定普通用户在本地桌面调用 gate 的 `-Mode Launch -ConfigPath <私有配置> -RequestId <ID>`。脚本先核验，再要求当场输入本次操作的明确 C 档确认；不从命令行或旧状态文件载入批准。确认限 120 秒，之后复核 TTL、配置及本地 Guard；只报告发出激活，不冒充已打开或登录。并发返回 BUSY，不排队，失败需本地重试。**这是防误启动辅助，不是强制门控**：它不能禁止同一桌面用户从其他入口打开应用。隔离由持久网络策略执行。

## 可选任务与宿主运行手册

不部署自动启动应用的 Windows 任务，不接受 SSH 注入启动请求，不创建共享队列。若需要定期离线巡检，通过任务计划程序创建 **仅 Inspect** 的任务：动作使用客机固定系统 Windows PowerShell 完整路径，参数为 `-NoProfile -NonInteractive -File "<受保护的 guest-claude-gate.ps1>" -Mode Inspect -ConfigPath "<受保护的配置>"`。不要用 ExecutionPolicy Bypass；任务定义仅管理员可改；使用受控最小权限服务主体，核验它只能读取受保护材料且能读取 GPO，读不到应失败。设置执行上限 60 秒、运行中不启动新实例，输出结果仅给私有监控通道，监控连续失败和无心跳；不宣称已交付外部告警服务。退出 0 只是策略巡检结果。

宿主侧预检只允许管理操作：核对网关磁盘链和哈希 → 检查独立控制台 → 启动隔离 VM → 用预先固定的主机密钥建立新 SSH 会话，仅运行 Inspect 或接收脱敏回执。SSH 不改网络、不发送启动请求；宿主不运行客机回传文件。此版本不提供远程一键启动，也不在无法证明安全的主机上模拟批准。

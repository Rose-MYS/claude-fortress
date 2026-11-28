# 08｜Fortress Level：隔离等级自评标准

> 一句话：把 S1 那一堆检查项，换算成一个用户能说出口的等级——「我的环境在本机自测达到 Fortress L2」。
>
> 机器可读定义：[assets/levels.json](../assets/levels.json)｜离线报告页：[assets/evidence-report.html](../assets/evidence-report.html)｜证据示例：[assets/evidence-v3.example.json](../assets/evidence-v3.example.json)｜参考计算器：[scripts/fortress_level.py](../scripts/fortress_level.py)

---

## 1. 它是什么，不是什么

- **是**：在**你这台机器、这一代配置**上，按 [01 的 S1 证据契约](01-route-selection-and-preflight.md)采集证据后，换算出的**自评**等级。
- **不是**：认证、担保或「这条路线普遍安全」。等级只说明那一次、那台机器上测过什么；换机器、换配置、过了有效期就要重测。
- 等级**不改变任何门禁**：进入 S2 仍须按 01 的适用矩阵全部 `pass`，再由用户本人确认 C 档。等级是给人看的汇总，不是新的放行开关。

## 2. 四个等级

每一级都包含下一级的全部要求（逐级累加）。

| 等级 | 名称 | 本级新增的必测项 | 最高能到这一级的路线 |
|---|---|---|---|
| **L0** | 出口已核验 | 双中性端点 IPv4 出口一致、DNS 远程解析与无直出、三时段出口稳定 | C1（原生 VPS 出口） |
| **L1** | 泄漏面已封堵 | **A1**：应用层断代理拒绝拉起，Web 另加 WebRTC 无泄漏；**系统级路线**：IPv6 阻断，用浏览器时加 WebRTC 无泄漏 | A1（Web、CLI 分开评） |
| **L2** | 系统级默认阻断 | 冷启动、规则重载失败、上游入口失效三项负向演练均不回退直连；远程管理时加「演练中新建管理 SSH 可达」 | A2、C2 |
| **L3** | 客机外网关双层 | 网关 WAN 侧无未授权出站、客机内策略与防误启动生效、UDP 不绕过网关、无第二网卡旁路、切换后已有连接不残留直连 | B |

- 路线 B 的「新建管理 SSH」是无条件必测（网关通过 SSH 管理）；C2 同理。A2 只有在 `remote_management` 为 `true` 时才要求。
- WebRTC 只在 `browser_used` 为 `true`（A1 Web 恒为必测）时要求。

## 3. 判定规则

1. **按组件评**：每份证据只对应一个「路线 + 组件」，例如 `A1/web` 和 `A1/cli` 各一份；沿用 01 的规则——Web 通过不能放行 CLI，反之亦然。
2. **只有 `pass` 和 `user_attested` 算达标**。`unknown`、`not_run`、`fail` 都不算。
3. **`user_attested` 只能用于负向演练类检查项**（`levels.json` 里 `attestable: true` 的项：应用层断代理、冷启动、重载失败、入口失效、新建管理 SSH、WAN 侧抓包、已有连接）。这些演练属于 C 档，由用户本人执行后录入结果；报告必须单独列出哪些项是用户自述的。
4. **`not_applicable` 只能用于本组件不要求的项**（比如 CLI 的 WebRTC、条件为 `false` 的条件项），并且必须写理由。把必测项标成 `not_applicable` 会让整份证据**无效**，而不是被跳过。
5. **逐级判定，遇到第一个缺口就停**：L1 有一项没过，即使 L2 的演练全部通过，结果也只是 L0。
6. **有效期**：从参与判定的检查项里**最早**的采集时间算起，30 天后标记为「过期」。
7. **配置代际**：证据里的 `config_sha256` 和当前配置的哈希不一致时，标记为「配置已变」，必须重测。
8. **证据无效时不给等级**：格式错误、未知检查项、缺时间戳等，一律不给等级，只列出错误。

## 4. 证据格式 v3

在 v2（[route-b-evidence.example.json](../assets/route-b-evidence.example.json)）的基础上扩展，主要变化：

| 字段 | 说明 |
|---|---|
| `schema_version` | 固定为 `3` |
| `request_id` | 32 位小写十六进制，每次采证新生成 |
| `route` / `component` | 如 `B` / `system`、`A1` / `web`，必须对应 `levels.json` 的一个 profile |
| `config_sha256` | 被测配置的 SHA-256（64 位小写十六进制），用于判断配置是否变更 |
| `conditions` | `browser_used`、`remote_management`，取 `true` / `false` |
| `checks.<id>` | 每项是一个对象：`status`、`method`（采证方式）、`captured_utc`（以 `Z` 结尾的 UTC 时间，`pass` / `user_attested` 必填）、`tool`（工具与版本）、`raw_sha256`（私有原始证据的哈希）、`note`（`not_applicable` 必填理由） |
| `private_evidence_reference` | 私有原始证据的存放位置，只写占位或本地别名，原始日志不进证据文件 |

**脱敏要求**（与零个人信息红线一致）：证据文件里不出现明文公网 IP、订阅链接、账号、个人路径；出口一致性只记录「是否一致」和加盐哈希，主机和网卡用别名。

**从 v2 迁移**：v2 的每个检查项只有一个状态字符串，没有时间戳，因此不能直接换算等级；需要按 v3 重新采证。v2 的 `dns`、`ipv6`、`cold_boot`、`reload_failure`、`entry_loss`、`management_ssh`、`udp`、`second_nic`、`existing_connections`、`browser_webrtc` 与 v3 同名，可以照搬采证方法。

## 5. 怎么算

在**宿主机或任意可信机器**上运行（只读、不联网、不写文件；不要为此在被检查的隔离环境里安装 Python）：

```bash
python scripts/fortress_level.py <证据文件>.json
python scripts/fortress_level.py <证据文件>.json --json --current-config-sha256 <当前配置哈希>
```

退出码：`0` 已判定（看输出里的等级），`2` 证据无效，`64` 用法错误。

也可以用浏览器直接打开纯离线的 [assets/evidence-report.html](../assets/evidence-report.html)：拖入证据 v3（可同时拖入 [WebRTC 检测页](../assets/webrtc-probe.html)导出的 JSON，自动合并为 `browser_webrtc` 一项），页面会显示等级、逐级的检查项、还差哪几项，并能导出脱敏 Markdown 摘要。页面内嵌同一份 `levels.json`，CI 会核对它和 Python 计算器在 [tests/fixtures/levels/cases.json](../tests/fixtures/levels/cases.json) 的全部用例上结果一致。页面还会提示证据里疑似的公网 IP、邮箱、订阅链接和个人路径，但这只是提醒，分享前仍要自己检查。

## 6. 对外怎么说

- ✅ 「在本机自测达到 **Fortress L2**（2026-11-28，配置 `a1b2c3d4…`）」
- ✅ 「路线 B 最高可评到 L3，我目前是 L2，L3 还差 UDP 一项」
- ❌ 「已通过 Fortress L3 认证」「这条路线是 L3 的，所以安全」
- 有用户自述项时附一句：「其中冷启动、入口失效两项为用户自述」。

## 7. 修改等级标准

改 `levels.json` 时必须同时检查：[01 的适用矩阵](01-route-selection-and-preflight.md)（中英两版）、`tests/fixtures/levels/cases.json` 的期望结果、本文第 2 节的表格。CI 会检查 `levels.json` 与 01 矩阵是否一致，以及计算器是否通过全部共享用例；不要为了让 CI 变绿而改弱断言。

# 加密 DNS 切换器（工作名 DNSwitch，待定）

一个 macOS **菜单栏应用**，用原生 SwiftUI 界面在**加密 DNS 协议（DoT / DoH / DoH3 / DoQ）与供应商之间快速切换**，底层内嵌 AdGuard [dnsproxy](https://github.com/AdguardTeam/dnsproxy)（Apache-2.0）作为 DNS 引擎。

**目标**：菜单栏点一下就切协议 / 切供应商，**进程内秒切、无可感知重启**；只覆盖用户真正要用的 4 家（Google / Cloudflare 无过滤、NextDNS、阿里 AliDNS）。

## 当前状态

- **阶段**：**阶段 3 UI/UX · 已完成并合入 main**（2026-07-15）。阶段 0–3 均已在 main，各阶段经 Fable 5 评审 + 真机验收。
  - 阶段 2 服务化（`phase-2-service`）：状态持久化 + 自测门控开机恢复、cgo DNS watchdog（换网补钉、VPN 跳过）、控制台用户属主 + 审计令牌鉴权、`SMAppService` 打包。见 [docs/07](docs/07-阶段2服务化设计.md)。
  - 阶段 3 UI（`phase-3-ui`）：设置窗（⌘,,配置移出列表、输入自动生效）、**NextDNS Profile ID 选填**（空=免费 config-less 公共解析）、菜单打磨（hover、定宽协议按钮、钥匙图标、名字带 ID 后缀、整行可点）、中英自动本地化。
  - 阶段 3 收尾（`ui-quiet-menu`）：首次安装的菜单**只留一个按钮**；未装服务时点 Toggle → 抖动 + 说明（含 VoiceOver 播报）；**Toggle/图标不再撒谎**（守护进程被停 = DNS 已还原 = 显示为关，重新批准后自动恢复）；设置里新增**移除后台服务**（删 App 不会删服务）；后台轮询按能耗取舍**只在菜单打开时**跑。
  - **关键修复**：NextDNS 的 `1.1.1.1` bootstrap 已失效（NextDNS 改了前置架构，四协议全崩），全部改走 NextDNS 自家 anycast `45.90.28.0 45.90.30.0`（`ParallelResolver` 双 IP）。见 [docs/04](docs/04-加密DNS供应商与协议实测.md)。
  - **公证与分发（`main`，2026-07-15）**：Developer ID + hardened runtime + 公证 + staple + Universal 全线打通，**第一个公证包已产出并通过 `spctl`（`source=Notarized Developer ID`）**。一条命令出包：`./packaging/release.sh` → `dist/DNSwitch-<版本>.zip`，换机不再需要 `xattr` / 右键→打开。见 [docs/09](docs/09-公证与分发.md)。
  - **下一步**：控制协议 `watch` 推送（[docs/07 §12](docs/07-阶段2服务化设计.md)，做了之后菜单栏图标才能既即时又不耗电）；F4「暂停/直连」；DMG 分发；日志轮转。
- **引擎**：AdGuard dnsproxy（Apache-2.0），**以 Go 库形式内嵌**（不用 ctrld、不 shell 调二进制）。
- **形态**：原生 SwiftUI 菜单栏前端（`app/`）+ Go 特权守护进程（`engine/`，内嵌 dnsproxy）。二者分工与理由见 [docs/01 §3–§4](docs/01-技术评估与架构方案.md)。

## 支持的供应商（已实测，见 [docs/04](docs/04-加密DNS供应商与协议实测.md)）

| 供应商 | DoT | DoH | DoH3 | DoQ |
|---|:---:|:---:|:---:|:---:|
| Google（无过滤） | ✅ | ✅ | ✅ | ❌ |
| Cloudflare（无过滤 1.1.1.1） | ✅ | ✅ | ✅ | ❌ |
| NextDNS | ✅ | ✅ | ✅ | ✅ |
| 阿里 AliDNS（公共 + 企业子域） | ✅ | ✅ | ✅ | ✅ |

> DoQ 只有 NextDNS / 阿里提供——UI 里对 Google、Cloudflare 置灰。Cloudflare DoT 用 `1.1.1.1`，不要用 `cloudflare-dns.com`（见 docs/04）。

## 运行阶段 0（本机验收）

```bash
cd engine && go build -o engine ./...
sudo ./engine          # 绑 127.0.0.1:53，把系统 DNS 指向本地加密解析器；Ctrl-C 停止并还原
```

验收要点（[docs/05 §G](docs/05-阶段0落地方案.md)）：先关掉 **Chrome Secure DNS** 与 **iCloud 私域中继**（否则绕过系统 DNS 造成假象）；起来后 `scutil --dns | head` 应显示 `nameserver[0] : 127.0.0.1`；每步之间 `sudo killall -HUP mDNSResponder` 刷新缓存；`kill -9` 后再次启动应自动对账还原。断网自救见下节。

## 文档索引

| 文档 | 内容 | 读者 |
|---|---|---|
| [docs/01-技术评估与架构方案.md](docs/01-技术评估与架构方案.md) | 引擎选型（dnsproxy vs ctrld vs 现成 App）、为什么"原生 UI + Go 引擎 = Swift 前端 + Go 守护进程"、整体架构、macOS 权限层、风险清单 | 立项必读 |
| [docs/02-MVP路线图.md](docs/02-MVP路线图.md) | 阶段 0–4 的范围、明确不做的事、每阶段验收清单 | 跟进进度用 |
| [docs/03-产品决策清单.md](docs/03-产品决策清单.md) | 所有已拍板的产品/技术决策，附状态与更新记录（§N） | **决策记录** |
| [docs/04-加密DNS供应商与协议实测.md](docs/04-加密DNS供应商与协议实测.md) | 4 家 × 4 协议的实测矩阵、上游 URL 模板、可复现命令、竞品全景 | 实现供应商预设用 |
| [docs/05-阶段0落地方案.md](docs/05-阶段0落地方案.md) | 守护进程骨架、IPC/权限形态选型（Shape 1/2）、服务注册、阶段 0 验收 | 开工前必读 |
| [docs/06-阶段1接口设计.md](docs/06-阶段1接口设计.md) | socket NDJSON 协议、Option B 切换时序、鉴权、并发互锁（经顾问评审定稿） | 写阶段 1 前必读 |
| [docs/07-阶段2服务化设计.md](docs/07-阶段2服务化设计.md) | SMAppService 注册、控制台用户属主 + 审计令牌鉴权、DNS watchdog、状态持久化；§9 顾问评审、§10 chunk ② 实现与评审记录 | 写阶段 2 前必读 |
| [docs/08-验收回归清单与构建指南.md](docs/08-验收回归清单与构建指南.md) | 全量真机回归清单（勾选式）+ 如何构建（含通用二进制）/安装/在第二台 Mac 上测试 | 每次验收/换机测试 |

## 规划中的仓库结构（阶段 0 落地）

```
adguard_dnsproxy/
├── engine/                Go 守护进程：内嵌 dnsproxy 库，绑 127.0.0.1:53、改系统 DNS、控制接口
│   └── (embeds github.com/AdguardTeam/dnsproxy/proxy)
├── app/                   Swift SwiftUI 菜单栏前端（MenuBarExtra）
├── packaging/             LaunchDaemon plist、SMAppService、签名与公证脚本
└── docs/                  本目录
```

## 紧急恢复（断网自救）

若守护进程异常退出导致系统 DNS 指向 `127.0.0.1` 而无人监听（整机无法解析域名），在终端逐个网络服务执行：

```bash
networksetup -listallnetworkservices          # 列出服务名
sudo networksetup -setdnsservers "Wi-Fi" Empty   # 恢复为 DHCP（其他服务同理）
```

正常情况下不需要手动执行——引擎启动时会按持久化快照自动对账还原（见 [docs/05 §F](docs/05-阶段0落地方案.md)）。

> 若装了 Little Snitch / LuLu：未签名的引擎首次外联加密上游会触发拦截弹窗，此时 DNS 已指向 `127.0.0.1` 会显得像"断网"——放行该引擎即可（评审 G-4）。

## 工作方式

- 每个阶段：实现 → 本机真机验收（切 DNS 后用 `scutil --dns` / 浏览器实测）→ 反馈 → 下一阶段。
- 每阶段验收含**换网/连 VPN 回归**（macOS 会在网络变化时重置 DNS，是这类工具最大的隐形坑）；阶段 3 起含**强制门户场景**（暂停/直连开关）。
- 加供应商 / 改协议行为走 [docs/03](docs/03-产品决策清单.md) 决策流程；实测数据进 [docs/04](docs/04-加密DNS供应商与协议实测.md)。
- 开始编码时初始化 git（用户私密端点值——NextDNS profile id、阿里企业子域——不入库，仓库里一律用占位符）。

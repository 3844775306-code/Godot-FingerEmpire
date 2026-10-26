# FingerEmpire

> 服务端权威的中世纪即时战略游戏（RTS），使用 **Godot 4.7**（Forward+）开发，支持 PC 与移动端。

玩家扮演一方领主，从采集资源、修建城堡开始，发展经济、组建军队，最终摧毁敌方主城。游戏内置 7 个风格迥异的国家、5 种资源、30 余种兵种与 20 余种建筑，并支持单机 AI 与多人联机对战。

## 核心特性

- **7 个国家**：维京、英格兰、法兰西、中国、匈牙利、日本、拜占庭，各有专属兵种与国家加成
- **完整经济链**：金、木、石、食物、石油五种资源，农民采集、商队贸易、集市买卖
- **深度战斗系统**：近战/远程护甲分离、范围伤害、穿透、攻城器械、驻军增伤、海战与运载船
- **建造与升级**：20 余种建筑，城堡解锁科技，建筑最高 5 级，城墙/梯子/桥改变地形通行
- **战争迷雾**：按单位视野动态探索，已探索区域保留压暗底图
- **A\* 寻路**：地形高度、水域、城墙阻挡、攀爬梯子与坡度限速
- **单机 AI**：三阶段运营（生产 → 发展 → 进攻）+ 后期战术（骚扰/压制/突袭/防守），四档难度
- **多人联机**：1v1 / 2v2 / 3v3，支持 ENet、WebSocket、Steam P2P 三种传输
- **乱斗模式**：3–5 国自由外交，可结盟、进贡、决裂、背叛

## 运行

1. 安装 [Godot 4.7](https://godotengine.org/)（标准版即可，Forward+ 渲染后端）
2. 用编辑器打开根目录的 `project.godot`
3. 按 `F5` 运行，主场景为 [main_menu.tscn](scenes/main_menu.tscn)

> 首次打开时 Godot 会重新导入资源，耗时取决于磁盘速度。仓库不包含 `build/` 与 `android/` 等构建产物，需要时在「项目 → 导出」中重新生成。

## 操作说明

### PC

| 操作 | 说明 |
| --- | --- |
| 左键点击 / 拖拽 | 选中单位、框选、确认建造位置 |
| 右键 | 移动、攻击、采集、设置集结点 |
| Shift + 右键 | 追加连续指令（路径点） |
| 中键拖拽 / 方向键 | 平移镜头 |
| 滚轮 | 缩放镜头 |
| Ctrl + 1~9 | 将选中单位编为 1~9 队 |
| 1~9 | 调出对应编队 |
| H | 全军暂停 / 恢复采集 |
| P | 原地防守（hold position） |
| R | 选中全部军队 |
| A | 全军攻击敌方主城 |
| S | 全军撤回己方主城 |
| Delete | 拆除选中建筑 |
| Space | 释放选中建筑内的驻军；无驻军时跳转至最近警报 |
| L | 显示 / 隐藏单位血条上的文字 |

### 移动端

- 左下角虚拟摇杆平移镜头，三指拖拽也可平移
- 双指捏合缩放
- 触屏点选、框选与拖拽放置建筑
- 移动端默认为「单次命令」模式（下令后自动取消选择）

## 国家与加成

| 国家 | 加成 | 专属兵种 |
| --- | --- | --- |
| 维京 | +25% 生命，+10% 速度 | 狂战士 |
| 英格兰 | +15% 攻击，+20% 视野，采木 +10% | 长弓兵 |
| 法兰西 | +25 护甲，主城起始 2 级 | 法式骑兵 |
| 中国 | 食物 +20%，黄金 +10%，人口 +10 | 诸葛连弩 |
| 匈牙利 | +15 护甲，石材 +15%，黄金 +10%，人口 +5 | 象骑兵 |
| 日本 | +15% 攻速，+10% 攻击 | 日本武士 |
| 拜占庭 | +2 双护甲，黄金 +10% | 甲胄骑兵 |

## 游戏模式

- **单机**：1v1、2v2、3v3 对称团队战，以及 3 / 4 / 5 国乱斗；AI 难度分简单 / 普通 / 困难 / 地狱（随难度提升 AI 资源倍率与速度）
- **联机**：1v1、2v2、3v3，空位由 AI 补足；主机权威，客户端只做表现层同步
- **胜利条件**：摧毁敌方主城（城堡 ID 20）；乱斗模式为最后存活的城堡

## 项目结构

```
project.godot          Godot 工程配置（Autoload、输入、渲染）
scenes/                主菜单、联机大厅、单机/联机服务端/客户端战斗场景、单位图鉴
scripts/
  core/                全局单例：配置、数据、网络、音频、Steam、性能分析
  entities/            GameEntity 基类与 Army / Building / WorldResource、移动控制、子弹
  scenes/              单机 RTSBattleManager、联机 OnlineBattleManager、外交系统
  client/              联机客户端：渲染镜像、输入、HUD、信息面板
  ai/                  AIController（运营、建造、侦察、战斗、外交）
  map/                 程序化地形、镜头控制、小地图
  ui/                  主菜单、联机菜单、HUD、选择、建造菜单、单位图鉴、主题
  data/                国家兵种解锁表、国家加成数值
models/                78 个 GLB 模型（建筑、兵种、动物、船只等）
resources/             字体、音频、水面着色器
addons/                编辑器与运行时插件（见下）
```

## 技术架构

### Autoload 单例

| 单例 | 职责 |
| --- | --- |
| `RTSConfig` | 全局常量、阵营/国家枚举、颜色池、实体模型映射 |
| `GameManager` | 场景状态机（MENU → PLAYING → GAME_OVER） |
| `EntityDatabase` | 0–66 号实体配置表，`get_config()` 返回副本 |
| `NetworkManager` | ENet / WebSocket / Steam P2P 连接与 RPC |
| `GameSettings` | 国家选择、AI 难度、单机模式、UI 缩放 |
| `AudioManager` | 背景音乐与音效（含 3D 音效） |
| `SteamManager` | Steam 初始化、大厅、P2P 会话 |
| `WebTunnel` | PC 网页房：自动启动 Cloudflare 快速隧道，生成公网 `wss://` 邀请链接 |
| `ThemeHelper` | UI 主题工具 |
| `Profiler` | 性能采样 |

### 单机 / 联机 / 客户端三端

- **单机**：[RTSBattleManager.gd](scripts/scenes/RTSBattleManager.gd) 同时承担逻辑与表现，拥有实体缓存、经济、人口、迷雾、胜负判定
- **联机服务端**：[OnlineBattleManager.gd](scripts/scenes/OnlineBattleManager.gd) 继承单机管理器，增加指令校验、按玩家可见性裁剪的快照广播
- **联机客户端**：[ClientRenderer.gd](scripts/client/ClientRenderer.gd) 只应用快照并插值渲染，不运行游戏逻辑；[ClientInput.gd](scripts/client/ClientInput.gd) 将操作发送给服务端

### 网络协议

- 客户端 → 服务端：`NetworkManager.send_command({action: ...})`，支持 `right_click`、`build`、`upgrade`、`produce`、`rally`、`set_group`、`global_attack`、`global_retreat`、`stop_gather`、`toggle_hold_position`、`demolish`、`set_garrison`、`clear_garrison` 等
- 服务端 → 客户端：约 10Hz 快照，100ms 增量 + 每 3s 全量；紧凑数组序列化，按队伍可见性裁剪
- 端口：ENet `9000`，WebSocket `8080`；支持 UPnP 自动端口映射

### 网页版联机（PC 开房 + 自动公网 wss）

浏览器不能监听 TCP 端口，Netlify 也只能托管静态文件，因此网页版采用“PC 主机开房、浏览器加入”的模式：

1. PC 端进入「联机对战」，传输方式选 **WebSocket**，点击「创建网页房间（自动公网）」；
2. 游戏会启动本机 WS 服务器（8080），并自动拉起 `cloudflared` 快速隧道，生成形如
   `https://fingerempire.netlify.app/?server=wss%3A%2F%2Fxxxx.trycloudflare.com` 的邀请链接；
3. 把链接发给网页玩家。对方打开后会自动进入联机大厅并连接；主机点击「开始游戏」即可。

注意：

- 主机需要保持游戏运行，电脑休眠/断网会断开网页玩家；
- 每次开房都会生成新的随机 `trycloudflare.com` 地址，关房后旧链接失效；
- Windows 发布 zip 会带上 `cloudflared.exe`；从源码运行可先执行 `tools/get_cloudflared.ps1` 下载到项目根目录。

## 插件（addons）

| 插件 | 用途 | 是否必需 |
| --- | --- | --- |
| `godot_mcp` | 编辑器 MCP 服务器，供 AI 工具直接操作项目 | 开发辅助 |
| `steam-multiplayer-peer` | Steam Sockets 的 GDExtension 实现 | Steam 联机必需 |
| `godotsteam` | Steamworks SDK 绑定（大厅、成就等） | Steam 功能必需 |
| `godot-git-plugin` | 编辑器内 Git 集成 | 可选 |
| `git_describe` | 编辑器标题栏显示版本信息 | 可选 |
| `script-ide` | 增强脚本编辑器（大纲、快速打开、分屏） | 可选 |
| `github_copilot` | 编辑器内 Copilot | 可选 |
| `breakpoint_mcp` | 断点调试 MCP 桥接 | 可选 |

## 导出

[export_presets.cfg](export_presets.cfg) 已配置 Windows、Android、iOS、Web 四个预设。导出前需在 Godot 中安装对应版本的导出模板；Steam 相关导出需保证 `steam_appid.txt` 与 `steam_api64.dll` 位于可执行文件同级目录。

## 开发约定

详见 [CLAUDE.md](CLAUDE.md)：

- **GDScript 一律使用 Tab 缩进**，禁止空格缩进与混用
- 提交信息需包含修改时间、修改原因与改动文件清单
- 配置数据通过 `EntityDatabase.get_config()` 获取副本，禁止修改原始配置
- 逻辑集中在服务端，客户端只做状态镜像

## 版权说明

本仓库未附带开源许可证。未经作者许可，请勿用于商业用途或再分发。

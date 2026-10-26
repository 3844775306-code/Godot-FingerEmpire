# CLAUDE.md

**语言要求：始终使用中文进行交流和回复。**

## 代码缩进铁律

**所有 GDScript 代码必须使用 Tab 缩进，严禁使用空格缩进。** 这是 Godot 编辑器的默认标准，也是项目所有现有代码的约定。

| 规则 | 说明 |
|------|------|
| 缩进字符 | **Tab**（不是 2 空格、不是 4 空格） |
| 缩进层级 | 每级 1 个 Tab |
| 顶级声明 | `class_name`、`extends`、`const`、`var`、`func`、`signal`、`enum` 顶格不缩进 |
| 函数体内 | 1 级 Tab |
| 条件/循环体内 | 继续累加 Tab |
| 混合使用 | **绝对禁止** Tab 和空格混用 |

**使用 Write 工具时**：正文内容必须用 Tab 缩进。
**使用 sed 替换时**：替换文本中要用 `\t` 表示 Tab，不要用空格。
**使用 Edit 工具时**：`old_string` 和 `new_string` 必须精确匹配目标文件的 Tab 缩进。

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Git 提交规范

每次修改代码后提交到 Git，必须使用以下格式编写 commit message：

```
<简要描述修改内容>

修改时间: YYYY-MM-DD HH:MM
修改原因: <为什么要做这个改动>
改动文件:
  - path/to/file1.gd  — <该文件的具体改动>
  - path/to/file2.gd  — <该文件的具体改动>
```

**要求：**
- 第一行：简洁的改动摘要（中文）
- 修改时间：实际的修改日期和时间
- 修改原因：说明为什么需要这个改动（修复 bug / 新增功能 / 优化性能 / 重构等）
- 改动文件：列出所有修改的文件及每个文件的具体改动说明
- 提交末尾添加 `Co-Authored-By: Claude <noreply@anthropic.com>`

**示例：**
```
修复客户端快照延迟导致的单位位置跳变

修改时间: 2026-07-24 14:30
修改原因: 修复在线模式中快照应用频率过低导致客户端单位位置插值不平滑
改动文件:
  - scripts/client/ClientRenderer.gd  — 提高插值频率，优化 lerp 平滑度
  - scripts/scenes/OnlineBattleManager.gd  — 调整快照发送间隔从 200ms 降到 100ms

Co-Authored-By: Claude <noreply@anthropic.com>
```

## 版本号规则（自动递增）

版本号唯一来源是 `scripts/core/AppVersion.gd` 的 `VERSION` / `RELEASE_DATE`，**不要手改散落在别处的版本字符串**（主菜单、更新日志面板、底部版本行都读它）。

规则（玩家定的）：

| 条件 | 动作 | 例子 |
|------|------|------|
| 每累计 10 次 git 提交 | 小版本 +1，余数保留到下次 | v1.0.0 → v1.0.1 |
| 距上次版本号发布日 ≥ 3 天且有提交 | 中版本 +1，小版本归零 | v1.0.8 → v1.1.0 |
| 玩家口头指定（如「把版本更新到 2.0.0」） | `-Major N` 手动升，中/小归零 | → v2.0.0 |

**每次任务提交后必须跑一次**（这一步由执行任务的人负责，没有 git hook）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/bump_version.ps1
```

- 输出 `VERSION_SAME v1.0.x (...)` = 不需要升版（计数已记录在 `tools/version_state.json`）；
- 输出 `VERSION_BUMPED v1.0.x -> v1.0.y (...)` = 已改写 `AppVersion.gd`，**接着要做两件事**：
  1. 在 `scripts/data/ChangelogData.gd` 的 `entries()` 顶部补一条该版本记录（玩家向要点，5~8 条，前缀「新增/优化/修复」）；
  2. 把 `AppVersion.gd`、`tools/version_state.json`、`ChangelogData.gd` 一起提交（commit message 里写 `版本号更新到 vX.Y.Z`）。
- `-DryRun` 只判断不写文件；`-Major 2` 手动指定大版本。
- `tools/version_state.json` 里存 `major/minor/patch/pending/last_bump_commit/last_bump_date`，**不要手工改**（除非要修计数）。

## 自动检查更新

> **发布铁律：每个新版本都必须自动可更新。**
>
> 不允许只上传安装包或只换网页而不更新 `update.json`。每个版本发布时都必须让三种入口同时生效：Web 刷新、Android 下载 APK、Windows 下载 zip。发布顺序固定为「改版本 → 导出安装包 → 上传 Release → 部署 Web 和清单」，避免玩家点更新却拿到旧包。
>
> 每次发布后必须验证：线上 `update.json` 的 `version` 等于 `AppVersion.VERSION`，并且两个 Release 下载链接都返回 200。

APK / Web / EXE 启动后（主菜单）都会拉一次 `update.json`，远端版本比本地高时，主菜单显示对应平台的入口：

- Web：显示「点此刷新」，直接跳转到新网页；
- Android：显示「点此下载」，打开 APK 下载地址；
- Windows：显示「点此下载」，打开 Windows 压缩包地址。

更新日志面板顶部也有「🔍 检查更新」按钮可手动强制刷新；按钮下方直接列出 Web / Android APK / Windows EXE 三个最新版本下载入口。

- 站点地址配置在 `scripts/core/UpdateConfig.gd` 的 `SITE_URL`（不带结尾 `/`）；
- Web 会自动使用当前网页的 `location.origin`，所以 Web 构建不依赖写死域名；
- APK / EXE 没有网页来源，必须配置 `SITE_URL`；运行 `tools/deploy_web.ps1` 时脚本会从 Netlify 读取真实地址并自动写回；
- `tools/build_web.ps1` 会根据 `AppVersion.gd` 自动生成 `build/web/update.json`；
- 安装包默认放 GitHub Releases（Netlify 单文件上限放不下 APK/EXE），地址使用 `releases/latest/download/FingerEmpire.apk` 和 `FingerEmpire-win.zip`。

清单格式（构建脚本自动生成，不要手改线上文件）：

```json
{
  "version": "v1.1.0",
  "date": "2026-11-02",
  "notes": "本轮更新一句话说明",
  "downloads": {
    "windows": "https://github.com/OWNER/REPO/releases/latest/download/FingerEmpire-win.zip",
    "android": "https://github.com/OWNER/REPO/releases/latest/download/FingerEmpire.apk",
    "web": "https://你的站点.netlify.app/",
    "default": "https://你的站点.netlify.app/"
  }
}
```

**发版流程：**

1. 修改 `AppVersion.gd` 的版本号，并在 `ChangelogData.gd` 补更新日志；
2. 用 Godot 导出新的 `FingerEmpire.apk`、`FingerEmpire.exe` / `.pck`；
3. 上传安装包：`powershell -NoProfile -ExecutionPolicy Bypass -File tools/publish_release.ps1 -Notes "本次更新说明"`（需要先 `gh auth login`，仓库必须公开）；
4. 发布网页和清单：`powershell -NoProfile -ExecutionPolicy Bypass -File tools/deploy_web.ps1 -Godot "<Godot.exe 路径>"`。

相关代码：`scripts/core/UpdateChecker.gd`（比对版本、解析清单、30 分钟缓存）、`scripts/core/UpdateConfig.gd`（站点地址、超时、缓存时长）。

## Steam 版打包

Steam 联机依赖原生库，**不能只发 `FingerEmpire.exe` + `FingerEmpire.pck`**。Windows 发布 zip 必须包含：

- `steam_api64.dll`
- `libgodotsteam.windows.template_release.x86_64.dll`
- `steam-multiplayer-peer.windows.template_release.x86_64.dll`
- `steam_appid.txt`

`tools/publish_release.ps1` 会自动收集这些文件并校验 zip，不再生成只能单机的 Windows 包。当前 `steam_appid.txt` 是 `480`（Spacewar 测试 App ID）；正式上 Steam 前必须替换成真实 App ID。

## Project Overview

**FingerEmpire** — a server-authoritative medieval RTS built in Godot 4.7 (Forward Plus). Features 7 nations (Viking, England, France, China, Hungary, Japan, Byzantine), resource economy, fog of war, A* pathfinding, and online multiplayer via ENet / WebSocket / Steam P2P. Supports singleplayer 1v1, 2v2, 3v3 and 3–5 nation FFA, plus online 1v1/2v2/3v3 with AI filling empty slots.

## Opening the project

Open `project.godot` in the Godot 4.7 editor. The main scene is configured there. There are no command-line build/test steps — everything runs through the Godot editor.

## Architecture

### Autoloaded Singletons (defined in `project.godot` `[autoload]`)
These are globally accessible nodes loaded before any scene:

| Singleton | Script | Purpose |
|-----------|--------|---------|
| `RTSConfig` | `scripts/core/RTSConfig.gd` | Global constants (MAP_SIZE, Team enum, Nation enum, COLOR_POOL, ENTITY_MODELS map) |
| `GameManager` | `scripts/core/GameManager.gd` | Scene-level state machine (MENU → PLAYING → GAME_OVER); switches between `main_menu.tscn` and `rts_battle.tscn` |
| `EntityDatabase` | `scripts/core/EntityDatabase.gd` | Central registry of all entity configs (IDs 0–66: resources, buildings, armies, animals). `get_config(id)` returns a duplicated Dictionary. |
| `NetworkManager` | `scripts/core/NetworkManager.gd` | Multiplayer peer management over ENet (port 9000), WebSocket (port 8080) and Steam P2P. Modes: NONE/SERVER/CLIENT. RPCs for commands, snapshots, map data, nation selection. |
| `ThemeHelper` | `scripts/ui/ThemeHelper.gd` | UI theming utility |
| `GameSettings` | `scripts/core/GameSettings.gd` | Player settings (nation choice, AI difficulty, post-game data) |
| `AudioManager` | `scripts/core/AudioManager.gd` | Music and SFX playback (play_music, play_sfx, play_sfx_3d) |
| `Profiler` | `scripts/core/Profiler.gd` | Performance profiling |
| `SteamManager` | `scripts/core/SteamManager.gd` | Steam init, lobby and P2P session; auto-detects `steam-multiplayer-peer` GDExtension vs GodotSteam built-in |

### Entity System (`scripts/entities/`)

Three entity types, all extending `GameEntity` (CharacterBody3D):

- **Army** (`Army.gd`) — mobile units (peasants, soldiers, ships, merchants, officials, animals). Has MovementController, combat AI, gathering, waypoints, garrison points.
- **Building** (`Building.gd`) — structures with production queues, upgrade system (5 levels), construction timers. Key IDs: 20=Castle (game-over on death), 21=Barracks, 25/26=Towers, 27=Walls, 28=Houses.
- **WorldResource** (`WorldResource.gd`) — gatherable resource nodes (gold, wood, stone, food, oil fields)

Entities are spawned via `RTSBattleManager.spawn_entity(config, team, pos, level)`, which loads 3D models (GLB), applies team tint, registers to the entity cache, and adjusts ground height.

### Server-Side Battle Managers

**`RTSBattleManager`** (`scripts/scenes/RTSBattleManager.gd`) — base class for both singleplayer and multiplayer. Owns:
- Entity cache system (`_entities_by_team`, `_armies`, `_buildings`, `_resources`, `_towers`) with dirty-flag pattern for O(1) lookups
- Fog of war (explored_grid/visible_grid, vision-based)
- Resource economy (player/enemy resources, limits, population)
- Building placement & validation
- Game-over detection (castle death)
- Power-history chart at end of match

**`OnlineBattleManager`** (`scripts/scenes/OnlineBattleManager.gd`) — extends RTSBattleManager for multiplayer. Adds:
- Delta-compressed incremental snapshots (every 100ms, full snapshot every ~3s)
- Compact array-based entity serialization (enum indices for wire format)
- Per-player visibility grids for snapshot culling
- Command processing (1v1 and team 2v2/3v3 variants)
- AI player creation and management
- Resource limits and population per peer_id

### Client-Side (`scripts/client/`)

**`ClientRenderer`** (`scripts/client/ClientRenderer.gd`) — receives snapshots, creates/maintains entity nodes, handles:
- Snapshot delta application (compact array → Dictionary conversion)
- Entity node pooling (create on first sight, update positions via lerp interpolation)
- Client-side fog of war (incremental batch processing)
- Health bars, production bars, upgrade bars
- 3D model loading with team tint, weapons, mounts
- Waypoint/A* path visualization
- Sound effect dispatch based on state transitions and visibility

**`ClientInput`** (`scripts/client/ClientInput.gd`) — mouse/touch input, selection, right-click commands; sends actions to server via `NetworkManager.send_command`.

**`ClientHUD`** (`scripts/client/ClientHUD.gd`) — resource display, minimap, alerts, control groups.

### AI (`scripts/ai/AI.gd`)

`AIController` — attached per AI player (peer_id). Runs a three-phase loop (`PRODUCTION` → `DEVELOPMENT` → `ASSAULT`) with late-game tactics (harass / overwhelm / raid / defend), four difficulty levels (EASY / NORMAL / HARD / HELL), and FFA diplomacy (ally / tribute / break / betray).

### Map (`scripts/map/`)

- `Ground.gd` — procedural terrain generation (perlin-based), terrain grid (plains/water/mountains), height grid, resource distribution, castle placement. Exposes `get_terrain()`, `get_height_at()`, `apply_fog()`.
- `Map.gd` — legacy map node
- `CameraController.gd` — RTS-style camera (pan, zoom, edge scrolling)
- `Minimap.gd` — minimap rendering with entity dots and alert flashes

### Data (`scripts/data/`)

- `NationData.gd` — nation-specific unit unlocks and tech trees
- `NationBonuses.gd` — static nation bonus values (population, starting castle level)

## Network Protocol

Commands sent client→server via `NetworkManager.send_command(data)` RPC. The `data` dictionary always has an `"action"` key:
- `right_click`, `build`, `upgrade`, `produce`, `global_attack`, `global_retreat`, `stop_gather`, `toggle_hold_position`, `rally`, `set_group`, `recall_group`, `demolish`, `set_garrison`, `clear_garrison`

Server→client snapshots are delta-compressed arrays sent at ~10Hz. Compact format uses enum indices (`E.ID=0`, `E.EID=1`, etc.) rather than string keys.

## Key Design Patterns

- **Entity cache with dirty flag**: `RTSBattleManager._ensure_cache_fresh()` — called before any query that needs entity lists. Rebuilds `_all_entities`, `_armies`, `_buildings`, `_resources`, `_towers`, `_entities_by_team`, `_entity_lookup` from the `$Entities` child list.
- **Config duplication**: `EntityDatabase.get_config()` always returns a `.duplicate()` — never modify the original.
- **Networked state ownership**: 1v1 uses team-based ownership; 2v2/3v3 and FFA use `owner_peer_id` for per-player isolation.
- **Client model mirroring**: ClientRenderer replicates server entity state from snapshots, including 3D models, animations, and team tinting — it does NOT run game logic.

## Addons (in `addons/`)

- **godot_mcp** — editor-side MCP server exposing project/scene/node/script tools to AI clients (enabled in `project.godot`)
- **steam-multiplayer-peer** — GDExtension implementation of Steam Sockets; required for Steam P2P matchmaking
- **godotsteam** — Steamworks SDK integration (not initialized on startup per project config)
- **script-ide** — enhanced script editor with outline, quick-open, split editing
- **github_copilot** — in-editor GitHub Copilot AI assistance
- **git_describe** — git describe info in editor title bar
- **godot-git-plugin** — version control integration (enabled in project settings)
- **breakpoint_mcp** — local breakpoint-debug bridge (optional developer tool)

## Godot 4 GDScript 设计模式参考

> 来源：`wshobson-agents-godot-gdscript-patterns` 技能（SKILL.md 位于 `.claude/skills/`）

### 模式 1：状态机 (State Machine)

- `StateMachine` 节点管理状态切换，`State` 子节点实现具体逻辑
- 通过 `transition_to(state_name, msg)` 切换状态，触发 `state_changed` 信号
- 每个 State 有 `enter()` / `exit()` / `update()` / `physics_update()` / `handle_input()` 生命周期
- 适用场景：玩家控制器、敌人 AI、UI 流程
- **项目关联**：可用于 `AIController` 的行为决策（巡逻/采集/战斗/撤退）

### 模式 2：Autoload 单例 (Autoload Singletons)

- 全局事件总线 `EventBus`：集中管理跨系统信号，解耦节点间依赖
- `GameManager`：管理游戏状态机（MENU → PLAYING → PAUSED → GAME_OVER）
- 原则：**谨慎使用 Autoload**，仅用于真正的全局系统
- **项目关联**：已有 `GameManager`、`NetworkManager`、`AudioManager` 等，符合此模式

### 模式 3：资源化数据 (Resource-based Data)

- 将配置数据（武器、角色属性）定义为 `Resource` 类型，与逻辑代码分离
- **关键**：运行时必须 `.duplicate()` 资源副本，避免修改原始资源文件
- 信号驱动属性变更通知（如 `stat_changed`）
- **项目关联**：`EntityDatabase.get_config()` 已是此模式——每次都返回 `.duplicate()`

### 模式 4：对象池 (Object Pooling)

- 预创建一组实例，用 `get_instance()` 获取、`return_to_pool()` 归还
- 实例停用时设置 `PROCESS_MODE_DISABLED` + `visible = false`
- 支持自动扩容（`can_grow`）和 `on_spawn()` / `on_despawn()` 回调
- 适用场景：弹射物、粒子特效、频繁创建销毁的对象
- **项目关联**：`ClientRenderer` 已有节点池化思路，可进一步抽象为此模式

### 模式 5：组件系统 (Component System)

- 用组合替代继承：`HealthComponent`、`HitboxComponent`、`HurtboxComponent` 独立挂载
- 组件通过信号通信，减少硬引用耦合
- 无敌帧用 `await create_timer().timeout` 实现
- 适用场景：需要灵活组合能力的角色系统

### 模式 6：场景管理 (Scene Management)

- `SceneManager` Autoload 负责异步加载场景 + 过渡动画
- `ResourceLoader.load_threaded_request()` 异步加载，配合进度条
- **关键**：先 `queue_free()` 旧场景，再 `add_child()` 新场景
- **项目关联**：`GameManager` 的场景切换可升级为异步加载模式

### 模式 7：存档系统 (Save System)

- `SaveManager` Autoload 用 `FileAccess.open_encrypted_with_pass()` 加密存档
- `Saveable` 组件挂载到需要持久化的节点，自动收集/恢复数据
- 数据格式：JSON 序列化 Dictionary
- 注意：`ENCRYPTION_KEY` 仅为占位符，正式使用需替换

### 性能优化要点

| 做法 | 说明 |
|------|------|
| `@onready var sprite := $Sprite2D` | 缓存节点引用，避免 `_process` 中重复查找 |
| 对象池 | 频繁生成/销毁的对象用模式 4 |
| 复用数组 | `_reusable_array.clear()` 替代每次 `new` |
| 静态类型 | `func calc(value: float) -> float` 优于动态类型 |
| 按需关闭处理 | 离屏节点 `set_process(false)` |

### 最佳实践清单

**应该做：**
- ✅ 用信号解耦，避免直接引用
- ✅ 全部使用静态类型
- ✅ 数据用 Resource 存储，与逻辑分离
- ✅ 频繁生成的对象用对象池
- ✅ Autoload 谨慎使用

**不要做：**
- ❌ 循环中调用 `get_node()`
- ❌ 场景之间紧耦合
- ❌ 在 Resource 中写逻辑
- ❌ 忽略 Profiler 性能分析
- ❌ 与场景树设计对抗

### 参考资源

- [Godot 官方文档](https://docs.godotengine.org/en/stable/)
- [GDQuest 教程](https://www.gdquest.com/)
- [Godot Recipes](https://kidscancode.org/godot_recipes/)

## 任务完成提示（工作区约定）

每完成一项任务（代码改动已提交 / 交付物已给出）时，必须发出提示，避免用户离开屏幕后无法判断进度：

1. **执行提示脚本**（一次搞定提示音 + 屏幕右下角提示窗）：
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File tools/notify_done.ps1 -Message "<本次改动的一句话摘要>"
   ```
   脚本行为：两声上扬提示音 + 屏幕右下角置顶无边框小窗（标题「FingerEmpire 任务完成」+ 摘要，深色底、绿色顶条，3.5 秒后自动消失，点击可立即关闭）。
   > 注意：Windows 11 已不再显示传统托盘气球通知（`NotifyIcon.ShowBalloonTip` 从 PowerShell 调用时常完全看不到），所以脚本改为自绘 WinForms 置顶窗口。
   > 该脚本必须保存为 **UTF-8 with BOM**，否则 PowerShell 按 ANSI 读取会让中文标题变乱码。
2. **回复首行**输出醒目的 `✅ 任务完成`，紧跟一句本次改动摘要。
3. 若有可交付文件（文档、截图、表格等），用 `present` 出示文件卡片。

> 备注：Git 的 `post-commit` hook 在本机沙箱环境下无法运行（sh 启动时报 `couldn't create signal pipe, Win32 error 5`，沙箱禁止命名管道），因此不依赖 hook，而是在完成任务时主动调用提示脚本。若换到非受限环境，可在 hook 里调用同一个 `tools/notify_done.ps1` 实现全自动提示。

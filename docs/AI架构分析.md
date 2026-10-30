# FingerEmpire AI 架构完整分析

> 分析对象：`scripts/ai/` 全部代码（8 个 .gd，约 12,700 行）+ AI 的实例化/难度/确定性集成点。
> 分析时间：2026-10-30 · 基线：当前工作区 HEAD · 结论均带行号，可逐条回查。
>
> **复审：2026-10-30 19:20 · HEAD `bf2aeba` · 新增第 5 章覆盖 18:41–19:13 的 十余个 AI 提交（防御 5 阶段 / 农民 6 阶段 / 军队调度 3 步 / 确定性回放基础）。第 1~4 章为 18:46 快照，冲突处以第 5 章为准。**

## 总览

---

### 0. 一句话结论

这不是"一个 AI 脚本"，而是一套**挂在服务端战斗管理器子节点上、以玩家同款指令 API 下命令的、按帧切片执行的分层决策系统**：
`AIController`（主控，6.2k 行）负责"想什么"，四个专案子模块（防御/渡水/爬梯/城墙施工）负责"怎么落地"，`RTSBattleManager` 负责"世界真值 + 资源扣减 + 实体生成"。AI 与真人玩家在协议层**没有特权通道**——它用的仍然是 `spawn_entity`、`assign_builders`、`request_repair`、`tribute_resources` 这些公共接口。

---

### 1. 文件构成与职责边界

| 文件 | 行数 | 职责 | 被谁驱动 |
|------|------|------|----------|
| `AI.gd`（`AIController`） | 6,179 | 主控：状态机、经济、生产、指挥、外交、侦察、调试面板 | 自身 `_process` / `_physics_process`（AI.gd:1846/1851） |
| `AIDefense.gd` | 3,721 | 防御：威胁评估、防线/塔圈规划、守军调度、资源前哨 | `AIController._run_decide_step(8)`（AI.gd:2329） |
| `AIWaterCrossing.gd` | 1,708 | 渡水：搭桥 / 船坞运载船 / 护航，跨水进攻 | `_run_decide_step(14)`（AI.gd:2374，按决策轮次而非帧推进） |
| `AIWorkerDirector.gd` | 367 | 农民角色账本（第 1 阶段只读，不改命令） | `_ai_simulation_tick`（AI.gd:1935） |
| `AILadderSiege.gd` | 266 | 爬梯翻墙：梯子建造/冷却/上限 | 阶段状态机内 tick（如 AI.gd:2208-2209） |
| `AIWallPlanner.gd` | 143 | 城墙施工**顺序**排序（只排队，不改墙线） | `_run_decide_step(12)`（AI.gd:2362） |
| `defense/DefenseThreatModel.gd` | 250 | 威胁模型：平滑、主城掉血、扇区快照 | AIDefense 内部 |
| `defense/DefenseContext.gd` | 135 | 敌我判定口径统一 + 共享上下文 | AIDefense 内部 |

设计取向很明确：**主控不膨胀到不可读，但也没做彻底拆分**——`AI.gd` 仍是 6.2k 行的"上帝对象"，防御与渡水这两个最复杂的专项被抽走，其余（经济/生产/指挥/外交/侦察/UI）继续留在主控内。这是"沿最痛处拆分"的实用主义结果，不是干净的分层架构。

---

### 2. 逻辑分层

```
┌──────────────────────────────────────────────────────────────┐
│ 决策层  AIController.decide —— 15 个 step（0–14），7ms/帧预算切片         │
│   step 0  刷新上限/人口      step 7  资源泄压 + 外交决策        │
│   step 1  失效目标清理        step 8  AIDefense.tick（防御）    │
│   step 2  刷新可见性/迷雾     step 9  守墙部署 + 塔内驻军       │
│   step 3  侦察推进            step 10 生产/发展/进攻 状态机     │
│   step 4  解析主敌            step 11 DEVELOPMENT→ASSAULT 判定  │
│   step 5  资源压力+配额       step 12 AIWallPlanner.tick        │
│   step 6  时代/科研兜底       step 13 前线闲兵补派              │
│                               step 14 AIWaterCrossing.tick      │
├──────────────────────────────────────────────────────────────┤
│ 战术层  Phase{PRODUCTION,DEVELOPMENT,ASSAULT} + LateTactic      │
│         {HARASS,OVERWHELM,RAID,DEFEND} + AIDefense 防线/守军     │
├──────────────────────────────────────────────────────────────┤
│ 执行层  生产队列 / 建造 / 升级 / 攻击移动 / 驻军 / 渡水 / 爬梯    │
├──────────────────────────────────────────────────────────────┤
│ 接口层  RTSBattleManager 公共 API（spawn_entity、assign_builders │
│         request_repair、tribute_resources、update_player_limits…）│
└──────────────────────────────────────────────────────────────┘
```

接口层是硬约束：AI 对 `battle` 的引用中，`battle.entities` 73 次、`battle.game_time` 46 次、`battle.diplomacy` 35 次，共涉及约 90 个不同方法/字段。也就是说 **AI 的世界模型不是自己维护的，而是每次都回读战斗管理器**——AI 侧只缓存"摘要"（可见敌人列表、收入速率、资源快照、角色租约）。

---

### 3. 运行节奏：一切皆节流

AI 没有"每帧全量思考"，而是四层节流叠加（AI.gd:1856-1958）：

| 层 | 机制 | 参数 |
|----|------|------|
| 难度基频 | `think_interval`，仅首帧按难度设定一次 | EASY 2.0s / NORMAL 1.75s / HARD 1.5s / HELL 1.0s（AI.gd:1865-1868） |
| 规模降频 | 实体数越多，决策间隔越长 | >180 ×1.4 …>450 ×4.2 …>700 ×6 …>1000 ×12（AI.gd:1900-1915） |
| 帧内切片 | 一轮 decide 拆 15 段，每帧最多 7ms | `DECIDE_BUDGET_USEC=7000`、`DECIDE_LAST_STEP=14`（AI.gd:27-28） |
| 成本自适应 | 整轮耗时超标则下一轮整体拉长 | 60/120/250ms 三档，倍率上限 5/6/8（AI.gd:2262-2269） |

另有**多 AI 互斥**：`battle.acquire_ai_decide_slot(peer_id)`，抢不到就顺延 0.1s（AI.gd:1916-1919），保证同一帧只有一个 AI 在做全量扫描。
**相位错峰**：多 AI 开局同帧 0 计时器会让扫描叠在一起，用 `(peer*7 + instance) % 17 / 17` 把 timer/农民分配/海军巡逻/修理/进贡全部错开（AI.gd:1869-1877）。
**独立节流器**与 decide 解耦：农民分配 3s、修理扫描 2.5s、海军巡逻、石头共享 5s、补派闲兵、侦察——各自带 `_late_game_scale()` 降频（AI.gd:1926-1958）。

---

### 4. 难度到底改了什么

难度不是"更聪明"，而是"**更勤 + 更准**"：`think_interval`（1.0~2.0s）决定反应速度；`GameSettings.AIDifficulty` 还会经 `red_ai_difficulty`/`blue_ai_difficulty` 在联机里按阵营分别取值（AI.gd:1863-1864）。难度不影响经济系数、不 cheating、不读隐藏信息——AI 走 `_refresh_visibility()` 的视野判定（AI.gd:831），遵守与玩家相同的战争迷雾。

---

### 5. 双轨运行与确定性

`GameSettings.deterministic_sim` 为真（指令回放/录像）时，AI 从 `_process` 切到 `_physics_process` 固定步长驱动，随机源改走 `SimRandom`，并跳过所有 `Time.get_ticks_usec()` 预算切片（AI.gd:1846-1854、2248）——保证回放逐帧可复现。代价是回放场景 AI 会一次性跑完整个 decide。

---

### 6. 实例化：谁在什么时候造 AI

- 单机 2v2/3v3、FFA、训练营：`RTSBattleManager` 里 `AIController.new()` + 设 `my_peer_id/my_team` + `add_child`（RTSBattleManager.gd:1754、1870、2021、2167）。
- 单机 1v1 / 战役：场景里预置名为 `AIController` 的静态节点（`get_node_or_null("AIController")`，RTSBattleManager.gd:1581 等），`my_peer_id = -1` 表示"按 team 记账"。
- 联机：`OnlineBattleManager.gd:676` 为缺席槽位补 AI。
- 创建后 AI 立刻接管：`ai_players[pid]`、`ai_resources`、`ai_population`、`ai_limits` 由战斗管理器分账，AI 通过 `battle.get_resources_for(pid)` 这类方法读写自己那一份。

细节见第 3 章 §6「集成入口」。

---

### 7. 可观测性

`update_debug_label()`（AI.gd:5686）+ `_create_debug_panel()`（AI.gd:5993）给每个 AI 一块 540×400 面板（手机端不建，AI.gd:1829），暴露 phase、战术、资源收支、兵力、目标、科研、防御状态；`_log_decide_profile()` 在单轮 >80ms 时把 15 个阶段耗时写进 `user://ai_decide.log`（AI.gd:2277-2289），是性能回归的第一手证据。`StatsOverviewScreen` 在手机端读取同一批 AI 字段。

---

### 8. 阅读路线建议

- 想改**决策优先级/节奏** → 第 1 章 §4（14 阶段）§5（三阶段）
- 想改**经济/建造** → 第 1 章 §7
- 想改**防御/城墙** → 第 2 章（AIDefense）+ 第 3 章 §3（WallPlanner）
- 想改**跨水/爬梯** → 第 3 章 §2、§4
- 想改**难度/性能** → 第 1 章 §4.3、§5 与本文 §3-§4
- 想做**重构** → 第 4 章（跨模块风险与改进路线）

## 第 1 章 · AIController 主控架构（AI.gd）

### 1. 总览：AIController 的定位与规模

- `class_name AIController` / `extends Node`（AI.gd:3-4），每个 AI 玩家一个实例，挂在战斗管理器（battle）之下，通过 `@onready var battle = get_parent()` 反向引用父节点（AI.gd:18）。文件实际 **6179 行**（任务书写的 6166 略有偏差）。
- 单文件承担了「AI 全部决策」：经济/建造/生产/军事指挥/防线/海军/外交/调试面板。真正的算法细节被外移到 5 个子模块脚本，主类只做调度与状态持有：`AIDefense`、`AIWaterCrossing`、`AIWallPlanner`、`AILadderSiege`、`AIWorkerDirector`（AI.gd:9-13）。
- 双模式兼容：`my_peer_id != -1` 走在线/多人（读 `OnlineBattleManager` 的 per-player 资源表），`my_peer_id == -1` 走单机「敌方 AI」（读 `battle.enemy_resources`）。这一分歧被 4 个包装函数收敛：`_get_resources/_get_limits/_get_population/_can_train_unit`（AI.gd:286-316），是理解全文的第一把钥匙。

### 2. 类结构：常量与成员分组

#### 2.1 顶层枚举

- `enum Phase { PRODUCTION, DEVELOPMENT, ASSAULT }`（AI.gd:15）：三阶段主状态机。
- `enum LateTactic { NONE, HARASS, OVERWHELM, RAID, DEFEND }`（AI.gd:16）：后期战术模式，与 Phase 正交（DEVELOPMENT/ASSAULT 里都会 `update_tactic`）。
- `enum UnitRole`（AI.gd:4878）：15 种部队角色，供 Director 账本使用，是全文第二套「状态」体系。

#### 2.2 常量分区（按注释分隔线可读）

| 区块 | 代表常量 | 行号 |
|---|---|---|
| decide 分帧预算 | `DECIDE_BUDGET_USEC=7000`、`DECIDE_LAST_STEP=14` | 27-28 |
| 兵种/建筑目标 | `wanted_buildings`、`wanted_units`、`TARGET_FIELD_ARMY_TOTAL=50`、`SUPPORT_UNIT_IDS` | 41-52 |
| 民居/建筑上限 | `HOUSE_TARGET_MAX=8`、`CAMPAIGN_AI_BUILDING_CAP=50` | 55-58 |
| 资源压力 | `RESOURCE_PRESSURE_RATIO=.85`、`RESOURCE_CRITICAL_RATIO=.97`、`RESOURCE_PRESSURE_TRAIN_BURST=2` | 74-79 |
| 侦察 | `SCOUT_ID=19`、`SCOUT_START_DELAY=60`、`SCOUT_RETARGET_SEC=14` | 120-133 |
| 外交 | `DIPLO_DECIDE_INTERVAL=12`、`PROPOSE_WAIT_MAX=45`、`ACCEPT_VALUE_MIN=.4`、`TOP_DOMINATE_RATIO=.8` | 2481-2491 |
| 防线/守墙 | `WALL_DEPLOY_INTERVAL=10`、`WALL_BUILD_CAP_AI=420`、`WALL_GUARD_*_META` | 185-208 |
| 修理 | `REPAIR_SCAN_INTERVAL=2.5`、`REPAIR_MAX_CONCURRENT=2`、`REPAIR_WEIGHT` | 255-275 |
| Director | `DIRECTOR_INTERVAL=0.5`、`DIRECTOR_FIELD_LEASE=30`、`DIRECTOR_STANDBY_LEASE=25` | 4880-4885 |
| 面板 | `PANEL_WIDTH/HEIGHT`、`PANEL_REFRESH_INTERVAL_OPEN=1.0` | 5872-5876 |

#### 2.3 关键成员状态

- 节奏：`think_interval`（难度决定）、`_decide_cost_scale`（自适应倍率）、`_decide_cursor/_decide_running/_decide_step_usec`（分帧游标与热点计时）（AI.gd:22-33）。
- 经济：`desired_worker_count=8`、`_resource_pressure_time`、`_last_spend_block`（泄压阻塞原因诊断）、`_ai_income_rate`（10 秒窗口收入估计）（AI.gd:60-64、105-109）。
- 模块句柄全部惰性/`_ready` 创建：`_defense/_wall_planner/_water_crossing/_ladder_siege/_worker_director`（AI.gd:88-92）。
- 战术：`current_tactic`、`_harass_ids`、`_harass_until`、`last_tactic_time`（AI.gd:93-101）。
- 部队账本：`_roles: Dictionary`（instance_id → {role, since, until}）（AI.gd:4887）。
- 外交：`_diplo_propose_target/_diplo_last_propose_time/_diplo_propose_history`（AI.gd:140-145）。
- 调试：`debug_panel` 及其 20+ 个控件引用（AI.gd:5817-5867）。

### 3. 生命周期与驱动

#### 3.1 `_ready()`（AI.gd:1822）

1. `process_mode = PAUSABLE`：battle 是 `ALWAYS`，AI 必须显式可暂停，否则暂停时仍出兵（AI.gd:1824-1825）。
2. `_add_nation_special_unit()`：把所选国家的特色兵种追加进 `wanted_units`（AI.gd:653-666）。
3. 非移动端才 `_create_debug_panel()`（`InputSource.use_mobile_ui()` 判断，覆盖 Web 移动端）（AI.gd:1832）。
4. 依次 `new()` 4 个模块；`_worker_director` 额外 `setup(self)`（AI.gd:1834-1838）。
5. 注意：`_wall_planner` **不在** `_ready` 创建，而是在 decide step 12 懒加载（AI.gd:2362-2364）。

#### 3.2 双轨 tick

- `_process` 只在 `not GameSettings.deterministic_sim` 时驱动，`_physics_process` 反之（AI.gd:1849-1857）。二者都调用 `_ai_simulation_tick(delta)`（AI.gd:1859），保证确定性模拟下 AI 跑在物理帧上。
- `_ai_simulation_tick` 是全文件唯一的常驻循环，职责：难度初始化、收入采样、decide 触发/推进、以及一批固定节流器的独立调度（AI.gd:1859-1978）。

#### 3.3 首帧初始化与相位错峰

- 难度 → `think_interval`：EASY 2.0 / NORMAL 1.75 / HARD 1.5 / HELL 1.0；在线模式按红/蓝 AI 难度分别取（AI.gd:1863-1871）。
- 用 `seed_id = my_peer_id 或 my_team` 计算 `phase ∈ [0,1)`，把 `timer/worker_allocate_timer/_naval_patrol_timer/_repair_scan_timer/_tribute_to_human_timer` 全部错开初始化（AI.gd:1872-1880）。这是多 AI 同帧不齐步卡顿的关键手段。
- 收入估计：每 tick 用「快照差值只累加增量」的方式统计（避免支出把增量算负），每 10 秒折算成 `_ai_income_rate`（AI.gd:1883-1893）。

#### 3.4 独立节流器一览（与 decide 解耦）

| 逻辑 | 间隔 | 行号 |
|---|---|---|
| `allocate_workers()` | 3.0s × late_scale | 1932-1935 |
| WorkerDirector 只读账本 tick | 每帧 | 1937-1938 |
| `_patrol_navy_around_water`（≥DEVELOPMENT） | 15s × late_scale | 1939-1943 |
| `_retarget_attacked_siege_units` | 1s | 1945-1948 |
| `_tick_building_repair` | 2.5s | 1951-1954 |
| `_spend_surplus_stone_on_walls`+`_share_surplus_stone_with_ally` | 5s | 1957-1960 |
| `_tribute_to_human_teammate` | 20s | 1962-1966 |
| `update_debug_label`（debug build 且面板存在） | 1s/5s | 1969-1974 |
| `_tick_director` | 0.5s | 1978 |

### 4. 决策调度：14 阶段分帧（核心机制）

#### 4.1 为什么要拆

类注释直接说明：整段 decide 在 600+ 实体时实测 200~500ms，是玩家感知的「隔几秒一顿」（AI.gd:24-26）。方案是把十几个 O(实体数) 阶段拆开，每帧只跑固定预算。

#### 4.2 四段式接口

- `decide(delta)`：兼容入口，一次性跑完 step 0..14（AI.gd:2226-2230）。**已无外部调用点**（全项目 grep 仅定义处），属于调试/回滚路径。
- `_begin_decide(interval,d)`：置 running、cursor=0、记录起始 usec、重置 `_decide_step_usec`（AI.gd:2232-2240）。
- `_pump_decide()`：单帧 while 循环推进 step，累计各步耗时；非确定性模拟下超 `DECIDE_BUDGET_USEC=7000` 即 break；跑完调 `_finish_decide`（AI.gd:2244-2254）。
- `_finish_decide()`：重置状态、`timer = _decide_interval * _decide_cost_scale`，按整轮耗时做倍率调整，>80ms 时写 `user://ai_decide.log` 分步剖析（AI.gd:2256-2292）。

#### 4.3 自适应倍率 `_decide_cost_scale`

>250ms ×1.5（上限 8）；>120ms ×1.35（上限 6）；>60ms ×1.3（上限 5）；<25ms ×0.97（下限 1.0）（AI.gd:2265-2272）。即「慢就降频、快就缓慢恢复」，无需手调配置。

#### 4.4 15 个 step（0–14）的职责（AI.gd:2294-2377）

| step | 内容 |
|---|---|
| 0 | 刷新资源上限/人口（在线走 `update_player_*`，单机走 `update_resource_limits/update_population_limits`）（2299-2304） |
| 1 | `clear_invalid_targets()` 清理悬空目标（2306） |
| 2 | `_refresh_visibility()` 重建可见敌军缓存（2308；实现见 831） |
| 3 | `_process_scout_recon()` 侦察探图（2310；实现 1034） |
| 4 | `_refresh_primary_enemy()` 解析 FFA 主敌（2312） |
| 5 | 资源压力计时 + 民居/兵营配额兜底（2314-2316） |
| 6 | 每 30s 检查升时代建筑、并尝试直接开升（2320-2324） |
| 7 | `_relieve_resource_pressure()` + `_diplo_decide()`（2326-2328） |
| 8 | `_defense.tick()`（2329-2332） |
| 9 | 守墙 `_deploy_ranged_units_to_walls`（10s）→ 塔内驻军 `_ai_garrison_soldiers`（4s）（2337-2347）。顺序被注释强调：先守墙再驻军，否则新兵会被集结/主攻先抢走（2334-2336、2342-2344） |
| 10 | 三阶段分派 `_state_production/_state_development/_state_assault`（2348-2352） |
| 11 | DEVELOPMENT→ASSAULT 判定：`count_field_military >= 30`（2355-2360） |
| 12 | `_wall_planner.tick()`（懒创建，2362-2365） |
| 13 | `_retask_idle_front_units()` 前线闲兵补派（2s）（2368-2372） |
| 14 | `_water_crossing.tick(_decide_interval)`——传的是「决策轮次间隔」而非帧 delta（2374-2377） |

#### 4.5 多 AI 互斥与二次降频

- 触发 decide 前先算实体规模倍率：>1000 ×12、>850 ×9、>700 ×6、>550 ×5、>450 ×4.2、>360 ×3.2、>260 ×2.2、>180 ×1.4（AI.gd:1903-1918）。
- `battle.acquire_ai_decide_slot(my_peer_id)` 抢占本帧决策权，失败则 `timer=0.1` 顺延（AI.gd:1919-1922）。这是「帧级令牌」而非锁，避免多个 AI 同帧跑 decide。

### 5. 三阶段状态机

- 阶段推进条件：`_state_setup` 校验主城存在否则 `queue_free()`（AI.gd:2100-2104）；PRODUCTION 内按 `production_step` 0→1，step1 结束时若农民已满或 `game_time>=120` 则转 DEVELOPMENT（AI.gd:2148-2149）；DEVELOPMENT 由 step 11 的野战军阈值（30）转 ASSAULT（AI.gd:2355-2360）。ASSAULT **不会回退**。
- `_state_production`（2107-2156）：先补农民（优先 WorkerDirector.ensure_worker_count，退化才直接 produce）→ 升主城 → 船坞/渔船/仓库 → `_process_line_military`；被压家时额外跑三线（2152-2155）。
- `_state_development`（2158-2202）：城堡 rush（3/6/10 分钟 → Lv3/4/5，`_castle_rush_done` 一次性标记，2158-2167）→ 防守时先军后建 → 升级线交替 → 生产/商贸/僧侣/船坞/渡水/集结点/狩猎/官员驻派 → `update_tactic`。
- `_state_assault`（2203-2223）：与 DEVELOPMENT 后半段高度重复（升级+补兵+4 线+船坞+集结+狩猎+tactic），差别主要是少了防守分支与 castle rush。**这是明显的冗余点，可抽公共尾段**。
- `_priority_upgrade()`（4372）优先把 21/23/24/29/54 推到 4 级，必要时先升主城（城堡等级是子建筑上限）。

### 6. 后期战术 LateTactic

`update_tactic`（AI.gd:3505-3565）判定顺序严格：

1. `threat_level >= 2`（AIDefense 提供）→ 强制 DEFEND + 清空骚扰队（3515-3525）。
2. 已是 DEFEND：只有 threat 回落到 <2 且 `my_mil>=12 且 player_mil<=my_mil*1.35` 才解除（3529-3536）。
3. `player_mil > my_mil*1.5` → 直接放弃进攻（3538）。
4. `my_mil >= 20` 且当前为 HARASS/RAID/NONE 且过冷却 → **OVERWHELM**（3543-3548）。
5. 冷却闸门（`TACTIC_COOLDOWN=25`）后按兵力优势选：`my_mil > player_mil*1.1 且 >10` → OVERWHELM；否则 `my_mil>=4` 时 65% 概率 HARASS，10 人以上才可能 RAID（3552-3565）。
- 军力口径：`my_mil = count_field_military`（排除守军/守墙/驻军/骚扰/海军/运输，757-781），`player_mil = _visible_enemy_military()`（只数可见，2459-2472）。

#### 6.1 三种战术算法

- **HARASS**（3568-3588）：`_find_harass_target` 打分选敌方农民/商队/推车（离敌主城<12 的跳过，`score = min(d_enemy,60)*0.6 - d_us*0.02`，农民 +2），无经济单位则退而打 22/23 建筑；`_pick_harass_squad` 取最近 3 个速度≥1.7 的机动兵（排除 16/17/18/40/58/59）；打 `ai_harass` meta + Director HARASS 租约 32s，`_harass_until = game_time+32`（3578-3588），到期由 `_cleanup_harass_squad` 撤标签（3665-3672）。
- **OVERWHELM**（3674-3711）：两波式——先全军 `attack_move` 到敌城前 5 米集结点，`await 10s` 后若威胁 <2 再压上敌城；全程跳过已有命令/交战中的单位（3691-3692），避免清空前线目标。注意其内部 `await` 使该函数为协程，调用方（update_tactic）不等待。
- **RAID**（3713-3768）：要求己方主城 `level>=3`；不足 3 个国家特色兵（或无特色则 15 骑兵）就先补产；绕侧翼 `flank=28~46`、随机侧向，若航点 22 米内有敌塔则换另一侧并 +12；部队分两批间隔 1.8s 出发（`move_to` waypoint），等 `RAID_WAIT_TIME=5s` 后统一 `attack_move` 敌城，上限 10 人。

### 7. 经济系统

#### 7.1 水位与泄压

- 比率/阈值：`_resource_pressure_ratio` 取五资源最大值（340-344）；快速模式阈值 -0.10 并 clamp 到 [0.70,0.90]（347-351）；`_resource_overflow` 要求连续高水位 ≥10s（353-355），`_resource_critical` 用 0.97（357-359）。
- `_food_emergency`：食物 <120 且比率 <0.25（363-367）——食物是唯一同时卡农民与战斗兵的资源。
- 泄压流程 `_relieve_resource_pressure`（4607-4625）：溢出才动 → 若首圈墙需优先则直接返回 → `_spend_surplus_stone_on_walls`（石头转墙/炮台，4528）→ 仍不满足则 `consider_warehouse_near_farmer` → `_process_line_3`（民居）→ `_upgrade_any_affordable_building` → 临界时 `_train_overflow_units` → `_process_line_1`。
- 配套目标放大：`_effective_army_target` 按人口缺口/溢出抬高目标（快速模式 free_cap=24，381-397）；`_field_army_target_for = max(base, ceil(50/可生产兵种数))`（419-424）；`_effective_house_target` 人口临满且资源>60% 时抬到 `8+4`（429-440）。
- 预算保留（重要耦合面）：`can_afford/_can_afford_building/_can_afford_upgrade` 三层都串接「升时代预留 → 投石机预留 → 重装科技预留」（1249-1296、4665-4680）。任何绕过 `can_afford` 的直接扣费都会破坏攒钱逻辑，注释已明示（1303-1304）。

#### 7.2 农民分配

- `allocate_workers()` 只是门面：有 `_worker_director` 就全权交给它 `allocate()`，否则回退 `_legacy_allocate_workers()`（2737-2745）。**当前生产路径默认走 WorkerDirector**，旧实现（2744-2857）保留为回滚路径。
- 旧实现的核心思路（读作设计意图）：目标农民数 8（PRODUCTION）/15（DEVELOPMENT）（2751）；`_force_food_workers` 食物告急时把 50%（clamp 4~8）农民改采食物，4 秒节流（2860-2895）；`_emergency_rebalance_workers` 满仓资源↔见底资源互换，最多改 2~4 人（2900-2949）；每 11 次分配才做一次按稀缺度的配额重排（2812-2855）。
- 权重：`_get_phase_weights` 按阶段+建造完成度分档（PRODUCTION 农民<8 时 food=5.0；DEVELOPMENT 按 build_pct<0.4/0.75 给 wood/stone 高权重，2964-2988）；食物告急额外 food≥7~10 且 wood/stone ×0.45；**oil 永不进农民权重**（农民不能采油，2995-2998 注释）。
- `_worker_resource_weights` 再剔除已达压力阈值的资源（2993-3002），形成「不往已满的池子送」闭环。
- 选矿评分：`priority - 距离*0.01 - 威胁惩罚`，威胁惩罚上限仅 2.5（刻意不否决），并按资源点缓存避免 O(农民×资源)（3019-3069）。
- 建造/修复统一走 `find_nearest_idle_builder`；民居和兵营有 `_force_house_builder` 强制抽农民（5049-5082），解决「没房→人口满→没兵→永远没房」。

#### 7.3 建造配额与选址

- 选址三级兜底：`find_valid_build_position`（围绕主城 9 个距离 × 12 角度采样，2636-2667）→ `_find_build_position_near_own`（主城失败则绕外围建筑，2700-2726）→ 被压家时 `_find_rebuild_position` 优先建在威胁反方向（2668 附近）。
- 落位校验 `_can_place_ai_building`（1364-1447）是全项目最严格的 AI 规则：地图边界（建筑半径×2 放大补偿）、地形/平坦度、船坞需邻水、桥走 battle 校验、墙顶炮台必须压在己方墙上、与所有建筑/资源做体积相交（墙-墙 0.9、墙-其他 1.6）。
- `build_building`（1537-1641）串行门槛：城堡等级 → 战役总建筑软上限 50 → 桥木保留 → 数量 cap（墙 420 / 民居 effective / 炮台 160 / 其他 10）→ 10 米内无敌军（民居/兵营在挨打时例外）→ 视野内 → 落位合法 → 有农民可达（被水隔断则委托 `_water_crossing.plan_bridge_to`）→ 预留检查 → 扣费 → spawn + `start_construction(5.0)` + 派工。
- 升时代条件兜底：`_ensure_age_upgrade_buildings`（475-495）每 30s 按 age1/2/3 缺口补建并给停工地基补派农民（608-619），且只统计 **已完成** 建筑（581-598），避免「把地基算成就绪」的假满足。

#### 7.4 时代/科研/修理/贸易

- 升时代：`_compute_research_age_reserve` 只在本轮「条件已齐、仅差资源」或「现在能点」时锁预算（2004-2029）；主城血量 <30% 时放弃预留保命（2007-2014）。`_try_start_age_upgrade` 每 30s 由 step 6 触发（2032-2043）。
- 科技：`RESEARCH_PRIORITY` 40 项固定顺序（1981-1986），先把升时代必需科技插队，再通用表，最后国家特色科技；攒时代资源时**暂停普通科技**（2059-2096）。
- 修理 `_tick_building_repair`（1659-1702）：开局 60s 内不修、已损 <10% 不修、同时最多 2 座、每轮最多开工 1 座；排序分 = `REPAIR_WEIGHT × (0.4+0.6×损伤比)`（1706-1712），城墙额外按相邻墙数加权 1.5/1.15（1714-1733）；`_repair_reserve` 按阶段给不同储备（PRODUCTION 最高、ASSAULT 最低、防守时 ×0.6，1737-1748）。
- 贸易：`_ensure_merchants` 按集市等级≥3/4/5 往 `production_list` 追加 44/45/43 与固定 cooldown（5223-5238）；商人过河由 `_manage_merchant_bridges` 交给渡水模块。

### 8. 军事生产

- 主函数 `_process_line_military`（4795-4829）：① `_emergency_army_stalled`（兵营>0、军队<10、资源压力>0.75）→ 强制造最便宜兵；② `_try_produce_trebuchet`（1207）优先；③ 投石机攒钱期直接 return；④ 人口不可训练则先补民居；⑤ 主城 2 级后补 1 个侦察兵（4730-4750，60s 后、死亡 15s 重试）；⑥ 按 `get_counter_priority()` 逐兵种补到 `_field_army_target_for`，正常每轮 1 个、资源临界时 `RESOURCE_PRESSURE_TRAIN_BURST=2` 个。
- 克制矩阵：`COUNTER_MATRIX` 静态表（1770-1776）；`get_counter_priority` 统计**可见**敌军构成打分排序，再过滤「没有生产建筑能造」的兵种（1801-1819）。
- 巨型投石机专线：`_trebuchet_pending/_unlocked/_reserve_active`（1126-1160）+ `_heavy_siege_tech_reserve_cost`（1174-1192）+ `_ensure_heavy_siege_tech`（1222-1250）构成「先城堡4级 → 29 到4级 → 暂停普通消费攒钱 → 优先排 59」的完整链路，超时 90s/180s 自动放弃，避免永久锁死经济。
- 人口安全：`_queued_unit_count` 把「存活+已排队」一起算进人口上限（321-332），防止泄压爆发时超编。
- 海军生产在 `_process_line_5`（5173-5214）：先判断船坞所在连通水域是否有军事价值（`_shipyard_has_military_water` 4111 附近，BFS 上限 6000 格、8s 缓存），有价值才补战船 13/炮艇 39，并保证每船坞至少 1~2 条渔船。

### 9. 部队指挥：AIDefense + ArmyDirector 双轨

- **AIDefense（外部模块）**：防线规划/威胁分级/守军/资源守卫全在 `scripts/ai/AIDefense.gd`；AI.gd 只保留 `_defense.tick()`（step 8）和 `_is_defending()`（3786，threat≥2 或 tactic==DEFEND）。
- **旧防线代码已死**：`build_defense_line`（3797）、`check_defense_line`（3820）、`rebuild_defense_line`（3829）、`upgrade_defense_to_max`（3841）、`_manage_defense`（3852）在 AI.gd 内**无任何调用点**（grep 证实），属 AIDefense 取代后的遗留，建议后续清理。
- **ArmyDirector 租约系统**（4887-5039）：`_roles` 记录 instance_id → `{role, since, until}`；`_tick_director` 每 0.5s `_director_prune` 清理死亡/超期/非己方，然后收集「非陆地战斗单位、无角色、`_director_is_busy()` 为假」的闲兵（4891-4916）。
- `_director_dispatch`（5001-5026）三级派单：40 米内有敌 → ≤25m 直接 `attack_target`、否则 `attack_move`，租 FIELD 30s；否则若可野战（有敌城且 phase≠PRODUCTION）→ 全军 `attack_move` 敌城；兜底回主城集结点（>10m 才下命令），租 STANDBY 25s。
- `_director_release_role`（4979-4999）按角色回滚 meta（WALL→清 `ai_wall_guard`/hold_position；HOME_GUARD→清 `ai_home_guard`+garrison_point；GARRISON→清 `_garrison_target_id`；RESOURCE_GUARD→清 meta），保证租约到期不留脏状态。
- 与旧调度器的共存方式：旧调度器在派单时 `_director_claim(...)` 登记角色（如 `attack_move` 3081-3112、`_rally_land_army_to_castle` 5242-5277、`_assign_wall_guard` 5322），Director 的兜底因此不会抢走它们。

#### 9.1 各专项指挥

- **集结点**：`_rally_land_army_to_castle`（5242-5277）在敌来向 12 米处集结，落点在水上会做 6 方向偏移修正；跳过已有 `_roles` 的角色单位（5265）。
- **前线闲兵补派**：`_retask_idle_front_units`（4832-4873）1~2s 一次、每轮最多 10 人；40 米内找敌（≤25m 锁敌、否则 attack_move），或对带 `ai_stalled_attack`（20s 内）的单位重新压向敌城；threat≥3 时整体不做（4835）。
- **守墙**：`_deploy_ranged_units_to_walls`（5386-5508）按墙格占用、`ai_wall_guard` 有效性、`_is_ranged_wall_candidate` 三重过滤，每面墙独立选「炮台 / 1 个远程 / 2~3 个小体积远程」，槽位偏移用城墙**格中心**为基准（避免偏移过半格丢墙顶免疫，5351-5356）；炮台只给按拐角/墙端/正对敌方向评分最高的墙段，总量 wall×30% clamp 2~24（5554-5623）。
- **驻军**：`_ai_garrison_soldiers`（3296-3405）只往 25/26/53 塞，远程优先、和平期 cap 6 人、防守期 cap 12 人。
- **海军**：`_patrol_navy_around_water`（5626-5688）跳过渔船 14/运载船 9/爆破船 40；先按「全图鱼数 - 5 保留量」派船猎鱼，剩余船去最近船坞周围找水面巡逻点。
- **御兽狩猎**：`_ai_hunt_animals`（3420-3506）每 8s 补齐，农民>15 才分人（`HUNT_MIN_PEASANTS`），固定 5 猎人围一只动物，沙漠图搜索半径 60（其他 30），`_check_hunt_cleanup` 猎人<2 时释放。
- **官员**：`_ai_garrison_officials`（3226-3292）按 46/47/48/49/50 分别找仓库/塔/生产建筑/城堡/最热门建筑，处理目标被拆、寻路失败（3s 退避）、无空位时退回主城。

### 10. 外交（仅乱斗 FFA）

- 开关：`_diplo_enabled()` 要求 `battle.diplomacy.active and my_peer_id != -1`（2495-2497）；单机/1v1 整块禁用，行为与旧版一致。
- 节流：开局 90s 不外交（`DIPLO_EARLY_START`），之后每 12s（`DIPLO_DECIDE_INTERVAL`）一次（2500-2505）。
- `_diplo_decide`（2500-2514）：有盟 → `_diplo_maintain`；无盟 → 先响应来件、仍无盟再主动提案。
- 战力估值 `_diplo_strength = count_military(owner) + 城堡等级×2`（2517-2521）；盟友价值 `_diplo_ally_value = 邻近0.35 + 军力匹配0.45 + 抗独裁0.2`（2543-2561）。
- 接受门槛 `ACCEPT_VALUE_MIN=0.40`，主动提案门槛 `TARGET_VALUE_MIN=0.35`，被拒/超时进入 90s 冷却（`PROPOSE_COOLDOWN_SECONDS`）（2564-2608）；提案等待 45s 超时自动取消（2585-2591）。
- 续盟：只在剩余<60s、仍需要盟、盟友军力≥我方 35% 且距上次进贡≥40s 时送 500 资源续期（2610-2620）；`_diplo_send_tribute` 取余额最多且扣完仍高于时代预留的资源（2623-2634）。设计原则注释明确：「一旦结盟便守约到自然到期，永不公开决裂」（2478-2480）。
- 另有面向**真人队友**的进贡（2v2/3v3）：`_tribute_to_human_teammate` 每 20s 一次，给资源压力最低的队友送 100~300，AI 源比例≥70%、目标比例<65% 才触发，走 `battle.tribute_resources`（含 20% 税）（4456-4515）。FFA 下直接返回 false（4461-4463）。

### 11. 主敌解析与敌我判定

- `_refresh_primary_enemy`：仅在 diplomacy 激活时，从「存活 + 敌对」国家里选**城堡最远**者为主敌（2401-2416）——注释说明 FFA 中 `1-my_team` 会解析到空队导致永不进攻。
- `_primary_enemy_team` 非乱斗回退红蓝对位（2418-2422），`_get_attack_target_castle`（2426-2450）优先取**最近**的敌方主城，再退主敌/对位队伍城堡。
- `_entity_is_enemy`（2453-2459）：有外交管理器时按 owner + `is_hostile` 判定，否则退化为纯队伍比较且资源点永不为敌。

### 12. 侦察与视野

- AI **不读玩家** `explored_grid`，而是维护自己的 `_scout_explored` 掩码，由 `battle.get_team_visible_mask` 每轮累积（909-931）。
- `_process_scout_recon`（1034-1092）每 think 执行：清理过期黑名单 → 血量 <35% 或 9 米内有敌则撤退 8s → 到达/超时 14s/卡住 3s 才换目标；只有「卡住」才拉黑 45s，避免大地图远点被误判（1080-1083）。
- `_pick_scout_target`（约 963-1001）以 4 格步长扫前沿未探索格，评分 = 距侦察兵² + 距主城²×0.05 + 9 米内可见敌军的 4000 惩罚，全图探完走 `_scout_fallback_target` 当移动视野。
- `_refresh_visibility`（831-902）是性能重点：视野源按 12×12 格去重 + 上限 64 抽样 + 侦察兵补回，然后用 `battle.get_nearby_enemies` 做空间查询去重，避免「己方单位×全图敌人」双循环。

### 13. 调试面板

- 仅 `OS.is_debug_build()` 且非移动端创建（1822-1832、6120-6121）；挂在 battle 的 `UI` CanvasLayer 下而非 AI 子节点，因此 `_exit_tree` 必须显式 `queue_free`（5822-5825）。
- 默认折叠为 44px 标题条（6115），折叠时不刷新主体（5704）；展开后 1s 刷新、折叠 5s（5876-5879、1969-1974）。
- 展示字段（`update_debug_label` 5696-5815）：标题（敌我 tag + 国家名/色）、国家特性、科研时代与在研进度、主城血量、人口条、五资源「数值 + 采集人数 + +x.x/s」（收入来自 `_ai_income_rate`）、经济单位清单、军队清单（30 种）、建筑清单（含最高等级）、狩猎/修理状态、AIDefense 状态文本。**单次遍历实体**聚合所有统计（5709-5735），避免每字段全表扫描。
- 面板位置：在线按 `(team*2+slot)*340` 纵向排；单机按更小 peer_id 的 AI 数量排行，最后由 `battle.layout_ai_debug_panels()` 统一排布（6012-6019、6118-6119）。

### 14. 设计模式、耦合点与风险

#### 14.1 值得肯定的模式

- **分帧预算 + 自适应降频**：`_run_decide_step` + `_pump_decide` + `_decide_cost_scale` + 规模倍率 + `acquire_ai_decide_slot` 五层防护，是 6k 行脚本仍能跑多 AI 的核心。
- **角色租约（Director）**：用 `_roles` + meta 双写、按角色回滚，渐进式替换旧调度器而不破坏兼容（4871-4884 注释明确「第 1 步：安全网」）。
- **预算预留链**：升时代/投石机/重装科技三种预留统一挂到 `can_afford*` 出口，避免散落扣费点各写一遍。
- **包装函数收敛双模式**：资源/人口/训练判定只有 4 个入口（286-316），是单机与在线共存的关键。

#### 14.2 耦合点

- 强依赖 battle 的内部字段与方法：`_all_entities`、`_armies`、`_buildings`、`entities.get_children()`、`_wall_entity_grid`、`get_nearby_entities/get_nearby_enemies`、`player_resources/player_limits_dict/player_population`、`_is_terrain_flat`、`assign_builders`、`request_repair`、`tribute_resources`。任一改名都会静默失效（多数调用用 `has_method` 兜底，反而容易掩盖错误）。
- 强依赖 `GameSettings`（难度、fast_mode、campaign_mode、ai_mode、deterministic_sim、map_id）与 `SimTime/SimRandom`：AI 的随机性全部走 `SimRandom`，`deterministic_sim` 下同时切换 tick 轨道与预算 break（2247-2248、2259-2260），确定性/非确定性两条路径行为不完全等价。
- 大量**约定式 meta**：`ai_home_guard/ai_resource_guard/ai_wall_guard/ai_harass/ai_transporting/ai_escorting/ai_stalled_attack/ai_scout_target/ai_role/ai_ladder/ai_transport_shipyard` 等，跨 AI/Army/AIDefense/AIWaterCrossing 共享，没有统一常量表（仅守墙 5 个 meta 定义成常量 202-206），容易拼写漂移。

#### 14.3 明显风险与冗余

1. **死代码/重复实现**：`decide()`（2226）无调用点；旧防线 5 个函数（3797-3869）被 AIDefense 取代但仍在文件里；`_legacy_allocate_workers`（2744-2857）与 `_worker_resource_weights` 类逻辑并存两条农民分配路径。
2. **状态双写不一致风险**：Phase / `current_tactic` / `UnitRole` 三套状态互相约束（如 `_is_defending()` 同时看 tactic 与 threat），但更新点分散在 `update_tactic`、step 11、AIDefense 三处，容易出现「账面 DEFEND 但野战军在推进」的中态。
3. **协程副作用**：`execute_overwhelm`（含 `await 10s`）与 `execute_raid`（含多次 `await`）由 `update_tactic` 同步调用但不等待，期间战术可能被 `update_tactic` 新一轮改写，出现「刚集结完又换目标」的竞态。
4. **O(实体数) 调用仍散落**：`count_unit/count_building` 每次全量扫描，且被 `_get_build_completion`、`_process_line_1` 的嵌套循环反复调用（如 4358-4366 对 9 个建筑 ID 各扫一遍 count），大后期仍是主要开销来源之一。
5. **硬编码数值密集**：兵种 ID、建筑 ID、距离阈值、比例常量遍布全文（如 `[5,6,9,10,14,33,43..51]` 这类排除表在 20+ 处重复出现），新增兵种时需要多点同步修改，容易漏改。
6. **文件职责过载**：单文件同时是「经济/军事/外交/UI」四套系统，虽有子模块但主类仍 6179 行；`_state_development` 与 `_state_assault`、`_process_line_1/3/4/5` 之间存在明显可合并的重复段落，是后续拆分（建议按 economy / military / diplomacy / ui 四个 partial 或子节点）的首要候选。

## 第 2 章 · 防御子系统（AIDefense / DefenseThreatModel / DefenseContext）


> 分析对象：`scripts/ai/AIDefense.gd`（3721 行）、`scripts/ai/defense/DefenseContext.gd`（135 行）、`scripts/ai/defense/DefenseThreatModel.gd`（250 行）、`scripts/ai/AIWallPlanner.gd`（仅接口衔接部分）。
> 结论均来自源码，行号格式为 `文件:行`。

### 一、模块职责与边界

`AIDefense` 是 `RefCounted`、**刻意不带 `class_name`**，通过 `preload` 挂到 `AI.gd`，避免全局类缓存不同步（AIDefense.gd:11-15）。它同时承担 6 件事：威胁感知镜像、城墙圈/隘口/弧线三套防线规划、分批建造与补建、主城守军调度、建筑受袭反击、资源区守卫与瞭望塔。

真实职责已经下沉到两个新文件，但只完成第 1 阶段：`DefenseThreatModel` 接管威胁计算（AIDefense.gd:297-312），`DefenseContext` 作为只读上下文/命令适配层（DefenseContext.gd:1-5）。防线规划、建造、守军仍然直接读写 `ai.battle` 与 `ai.*`（例如 AIDefense.gd:3663 直接调 `ai.battle.get_nearby_entities`），迁移尚未覆盖。

### 二、模块分层与数据流总览

```
AI.gd (AIController)
  ├─ _ready / think#8 ── new + tick(delta) ──────────────► AIDefense
  │                                                        ├─ _threat_model: DefenseThreatModel
  │                                                        │     └─ context: DefenseContext ─► ai.battle
  │                                                        ├─ _defense_queue / _defense_slots / wall_positions
  │                                                        ├─ _home_guard_ids / _resource_guard_ids
  │                                                        └─ _building_health（掉血差分表）
  ├─ think#9  ── _deploy_ranged_units_to_walls / _ai_garrison_soldiers（读 threat_level 决定是否增派）
  ├─ think#12 ── AIWallPlanner.tick（只改写 _defense_queue 的 priority）
  └─ update_tactic ── threat>=2 时 start_defense()，主攻前 release_guards_for_attack()
```

数据流是**单向**的：`battle 实体 + _visible_enemies` → DefenseContext → DefenseThreatModel → 快照/镜像字段 → 规划与调度 → `ai.build_building` / `unit.set_garrison` / `attack_target` 等命令出口。唯一的回写是 AIWallPlanner 对队列优先级的重排。

### 三、在 AI.gd 中的实例化与调用时序

- 正常开局：`_ready` 里 `_defense = AIDefenseScript.new(self)`（AI.gd:1834）。
- 惰性兜底：`prebuild_campaign_defense()` 内 `new`（AI.gd:1029-1031）、think 状态机第 8 步前判空再 `new`（AI.gd:2330-2331）。
- 每帧（决策帧）主调用：`_defense.tick(_last_delta)`（AI.gd:2332）。同帧顺序：第 8 步防御 tick → 第 9 步守墙/塔内驻军（AI.gd:2333-2347）→ 第 12 步 `_wall_planner.tick`（AI.gd:2361-2365）→ 第 14 步渡水。防御先于驻军与城墙调度，保证“已有目标”的单位优先被标成守军，后续逻辑不会二次抢人。
- AI 侧读取的对外 API：`threat_level`（AI.gd:3299/3302、3515、3696、3757、3762、3789、4835、4999、5124）、`start_defense()`（AI.gd:3791-3795）、`release_guards_for_attack()`（AI.gd:5137/5144/5158）、`first_ring_needs_priority()`（AI.gd:4611-4612，抑制溢出泄压）、`find_watchtower_build_position()`（AI.gd:627-628）、`prebuild_campaign_castle_ring()`（AI.gd:1031）、`get_status_text()`（AI.gd:5745）。
- 战役进攻关预置：`prebuild_campaign_castle_ring` 直接 `spawn_entity` 落墙、不扣资源不等农民（AIDefense.gd:889-934），并用 `ai.set_meta("campaign_prebuilt_ring", true)`（AIDefense.gd:933）反查 `_required_wall_ring_count` 只返回 1 圈（AIDefense.gd:361-363）。

### 四、旧公开字段镜像 vs `_threat_model.snapshot`

`AIDefense.gd:124` 明确写着「暂时保留旧公开字段做镜像，后续模块逐步改读 `_threat_model.snapshot`」。落地方式：`_evaluate_threat()` 变成纯搬运，逐字段从模型复制 8 个值（AIDefense.gd:303-312）：`threat_level/score/enemy_count/dir/center` 加上 `smoothed`、`castle_damage_until`、`last_castle_id/health`。节奏不变：仍由 `THREAT_INTERVAL = 2.5s` 触发（AIDefense.gd:20、231-234），无主城时 `_threat_model.reset()` 并清零镜像（AIDefense.gd:222-230）。

新接口 `get_threat_snapshot()` / `get_primary_threat_sector()`（AIDefense.gd:315-323）已具备，但全仓 `grep` 结果显示**除 AIDefense 自身外没有任何消费者**：`tracks` 与 8 扇区数据目前只产出不消费，属于第 2 阶段的预留接口。调试面板走的是 `get_status_text()`（AIDefense.gd:279-291），仍未展示扇区。

### 五、DefenseThreatModel：威胁评估数据流

输入 → 打分 → 平滑 → 分级 → 输出快照：

1. **输入**只取 `context.get_visible_enemies()`（DefenseThreatModel.gd:82），即 AI 视野内的敌军，不做全图侦测；先过 `context.is_combat_enemy()`（85）。
2. **距离门限**：`THREAT_OUTER_RADIUS = 26.0` 硬截断（11-12、89-90）；15 米内全权重，15~26 米乘 0.45（94-95）。
3. **单位权重**：`1 + prox*3.5`，攻击力 ≥30 +0.6，攻城器械（`SIEGE_IDS`）+0.8，18 米内再 +1.0（92-101）。
4. **方向/中心**：按 `w = 0.25 + prox` 对来向（三维归一）与位置做加权平均（103-113）；无敌人时退回敌方主城方向（167-168），保证防线朝向不抖。
5. **扇区**：8 个扇区各累计压力/敌军数/来向（115-120、232-250），`_sector_index` 用 `atan2(z,x)` 映射（218-223）；`get_primary_sector()` 返回压力最大扇区（208-216）。
6. **轨迹**：每敌一条 `{unit_id, entity_id, sector, pos, dir, distance, pressure, kind}`，`kind` 分 siege/approach/assault（121-130、225-230）。
7. **主城掉血**：只在“已有可见近敌”时加 4 分，单独掉血不触发威胁（132-140）。
8. **平滑**：无敌人立即归零（143-144）；上升用 `lerp 0.7`、下降用 `0.45`，形成快速拉高、缓慢回落的迟滞（147-150）。
9. **分级阈值**：`>=12` 危急、`>=6` 防守、`>=2` 警戒（154-161）。注释说明“单个远处侦察兵不应让 AI 全员回防”。
10. **输出**：`_snapshot` 含 level/score/enemy_count/dir/center/tracks/sectors/updated_at（175-184），`get_snapshot()` 深拷贝（187-199）。

### 六、DefenseContext：口径统一与共享上下文

只有 135 行，但统一了两件容易分叉的事：敌我判定与战场事实读取。

- `is_combat_enemy()` 与旧 `AIDefense._is_combat_enemy()` **同口径**：必须是 `Army`、血量 >0、非 NEUTRAL、是敌人、且有 `target_type>0` 或 `attack>0`（DefenseContext.gd:41-52 对应 AIDefense.gd:340-348）。中文动物/中立单位永远不会触发防守。
- 事实读取封装：可见敌人、己方建筑/部队缓存、资源、上限、时代、网格换算、找一个空闲农民（DefenseContext.gd:26-135）。
- 命令适配（`can_build/build/assign_builders`，DefenseContext.gd:114-122）目前**无人调用**——AIDefense 仍直接调 `ai.build_building`（如 AIDefense.gd:2773、2882、3590），Cmd 通道是预留。
- 注意 `battle` 在 `_init` 里一次性捕获（DefenseContext.gd:11-13），若同一 AIController 跨局复用而 `ai.battle` 被替换，上下文会指向旧战斗。

### 七、tick 调度节奏（AIDefense.gd:212-246）

| 子步骤 | 周期常量 | 作用 |
|---|---|---|
| 威胁重算 | 2.5s（:20） | 调威胁模型并镜像字段 |
| 建筑掉血检测 | 0.5s（:98-100） | 遍历全部建筑，掉血即派兵反击 |
| `_manage_defense` | 每 tick | 圈数达标→规划/补缺口/分批建造/保底塔 |
| `_manage_home_guard` | 60s（:75） | 完整守军审计（数量、超编释放） |
| `_quick_fill_home_guard` | 2s（:76） | 家门口 35 米内轻量补员 |
| `_manage_resource_security` | 1.5s/12s（:77-78） | 农民避险 + 资源区卫队 + 瞭望塔 |
| `_manage_defense_upgrades` | 9s（:41） | 塔升级（朝威胁方向优先） |

### 八、防线规划：三套方案与失败降级链

圈数由进度决定：经典模式 `城堡等级-2`，科研模式按时代，战役预置恒为 1（AIDefense.gd:354-367）。

**单方案制**（AIDefense.gd:396-406）：一旦 `_wall_ring_target > 0`，就不再叠加独立的隘口/前线防线——注释记录过两套方案并行会导致墙半径离散 5~7 米、角度覆盖仅 17~38%。只有未到触发等级时才走 `_ensure_chokepoint`（战略隘口）或 `_manage_early_defense`（地形墙线，开局 150 秒后无条件尝试，AIDefense.gd:386-394）。

`_plan_wall_ring`（AIDefense.gd:476-551）是核心，降级链为：

1. 期望半径 `_wall_ring_desired_radius`：取己方建筑距离的 **90 分位 + 体半径 + 1.8**，首圈不低于 14 米（`NORMAL_RING_MIN_RADIUS`、`CAMPAIGN_RING_MIN_RADIUS`），外圈比内圈至少 +3（AIDefense.gd:442-472）。
2. `_pick_ring_radius_best` → A* 环（`_ring_build_path`）→ 逐格兜底（`_ring_build_spot_fallback`）→ BFS 闭合验收，不闭合则 `_ring_fill_gaps` 补墙（AIDefense.gd:1664-1997、1979-1982）。
3. 墙数不足（首圈需 ≥ max(8, 计划的 55%)，AIDefense.gd:503）则回滚三张表后尝试 **贴地形环** `_plan_terrain_ring`（AIDefense.gd:520、578-687）。
4. 仍失败则半径内收重试 `[r-3, r-6, r+2]`（AIDefense.gd:524-529）。
5. 最后降级为 **朝敌半圆墙 + 2 座箭塔** `_plan_fallback_wall_arc`（AIDefense.gd:531、854-884）。

**闭合判据**是本模块最值得注意的设计：`_ring_is_sealed` 从主城泛洪，8 连通、禁止斜穿墙角，能走到地图边界即判漏风（AIDefense.gd:2400-2454）；贴边基地走远侧边界的变体（AIDefense.gd:2459-2524）。地形环另外用“已封点角度间隙弧长 >1.6 米即失败 + 落墙覆盖率 <80% 即失败”双重判据（AIDefense.gd:653-673），注释记录过“洪泛封闭”漏判导致 t+11s 有 8/14 敌人走进环内。

**性能护栏**：`RING_PLAN_BUDGET_MS = 55` 毫秒硬限时，且只对第一个候选半径必算、之后超时即用近似圈（AIDefense.gd:64、1955-1963）；`_ring_blocked_base` 把全图地形 + 建筑/资源占地缓存成一张字典，供所有候选半径复用（AIDefense.gd:2372-2396）；`_ring_exact_ok_cache` 同理（AIDefense.gd:167-168、1559-1592）。

### 九、建造节流、缺口队列与补建

- `_build_defense_step`：0.25 秒一次，每次最多 3 项（AIDefense.gd:36-38、2716-2721）。
- 队列顺序即建造顺序（降序优先级，`priority` 小的先建，AIDefense.gd:550、686）。
- 经济闸门：墙在塔不足 `MIN_TOWERS=6` 且石头 <80 / 木材 <110 时**跳过**（AIDefense.gd:2734-2742）；墙总数另有周长预算 `ceil(TAU*r/1.1)+8`（AIDefense.gd:849-850、2743-2748）；总上限 `WALL_BUILD_CAP=420`、塔类 10 座（AIDefense.gd:74、2728-2731）。
- 保留金：塔只留 5%（`reserve=0.05`），墙/其他走 `_defense_reserve()`（AIDefense.gd:2752-2756）——注释记录过“墙花光钱后塔永远等不到石头”。
- 不消耗队列项的三种“等待”：无空闲农民（AIDefense.gd:2759-2763）、目标点附近有敌军（2766-2768）、当前无己方视野（2769-2771）。失败累计 `tries>=4` 才丢弃（2777-2780）。
- 补建：每 `DEFENSE_GAP_INTERVAL=25s` 扫 `_defense_slots`，缺什么补什么，压入 `priority=0.0`（AIDefense.gd:35、2786-2795），因此补建项永远排在最前。
- 保底火力：`_ensure_min_towers` 只认**已建成**的塔（避免“队列里 8 座塔却一块石头没花”），150 秒后每 22 秒沿圈补塔（AIDefense.gd:2827-2861）；`_maybe_reactive_tower` 在威胁方向 7.8 米处应急加塔/炮（2863-2883）。

### 十、选址评分与升级优先级

- **塔圈塔位**：8 个方向，先试墙外 +2 米（射程 6~7 米正好覆盖墙线），再试墙线、墙内 -2.8 米（AIDefense.gd:2036-2049）；不足 3 座时在墙外 +3 米补 4 个角度（2052-2058）；炮塔固定朝敌两侧 ±0.55 弧度、每侧至少一座（2059-2074）。
- **隘口防线**：`_find_pass_anchor` 用地图 `_pass_centers` 数据（12~48 米、对齐度 ≥0.15、宽度 2~9 格），评分含对齐度 ×30、宽度偏差 -1.5/格、横向偏移 -0.55、距主城 28 米最优、可放墙段数 ×2.5（AIDefense.gd:1115-1248）。塔退到墙后 4.5 米、并且先铺瞭望塔链保证视野（1360-1402）。
- **瞭望塔**：按“新增视野收益”打分，用队伍可见掩码 + 2 格采样 + 已规划塔去重，收益 <18 直接否决（AIDefense.gd:110-119、2153-2192）；暴露在 12 米内敌军视野会重罚（2201-2211）。上限 6 座：基地 2、隘口链 4、资源区 2（AIDefense.gd:110-113、2269-2332、3558-3591）。
- **升级**：只升塔，等级不超过主城、血量 ≥45%、按到 `threat_center` 距离排序、每次 tick 只升 1 座，保留比例 0.2（威胁 ≥2）/0.42（AIDefense.gd:2893-2929）。

### 十一、守军调度与主攻部队的边界

- **规模**：平静/警戒 5 人；防守 `max(6, 敌数*2+2)`；危急全部（AIDefense.gd:3093-3108）。家门口正有目标的单位直接算“有效防守力量”并从名单移除，不重复抽兵（3110-3119）。超编时释放**离主城最远**的（3158-3170）。
- **快补**：2 秒一次，只在家门 35 米内挑人，上限 `min(5+敌数*2, 18)`（AIDefense.gd:86-90、3199-3220）。
- **集结点**：主城朝威胁方向 5.5 米，落点非平地则退到 +3,+3（AIDefense.gd:3272-3286）。
- **不抢人的硬规则**：`_unit_has_existing_task` 判定有目标/攻击移动/采集/排队/已驻扎即跳过（AIDefense.gd:3359-3368）；`_land_combat_units` 排除农民/经济单位、侦察兵（19）、水上单位、`ai_transporting`、`ai_wall_guard`、`_boarded_on`、`_soldier_garrison_building`（AIDefense.gd:3326-3355）。这就是“登船/驻扎单位不被拉走”的实现；AI 侧对称地在 `attack_move` 里跳过 `ai_home_guard / ai_resource_guard / ai_harass / ai_transporting / ai_escorting / ai_wall_guard` 以及有 `garrison_point`、`_garrison_target_id`、局部防守标记的单位（AI.gd:3077-3095）。
- **反抢**：`_assign_guard` 打 `ai_home_guard` + `set_garrison()`，并向导演账本申报 `UnitRole.HOME_GUARD` 60 秒（AIDefense.gd:3288-3298）；`release_guards_for_attack` 解除全部守军并设 20 秒 `_guard_block_until` 静默期，防止 2 秒快补立刻把人抓回（AIDefense.gd:3222-3231，AI.gd:5136-5137）。
- **建筑受袭反击**：0.5 秒轮询血量差，`_last_damager` 不合法时在 15/35 米内找最近可战斗敌军兜底（AIDefense.gd:2953-2957）；优先级主城 > 军事建筑 > 经济建筑（2961-2980）；单建筑最多 5 人、主城 8 人（:95-96、2987-2989）；给单位打 `ai_building_defense_until` 15 秒标记并记录回防锚点，避免被守军调度同帧拉回（AIDefense.gd:3021-3028）。
- **资源区**：每 12 秒聚类农民正在采的矿，取前 3 片（距离 ≤62 米，金/石 +0.6，远矿 +1.0，AIDefense.gd:3386-3433）；农民 8 米内有敌才躲，带货运回、空手反向挪 6 米，最长 9 秒（3444-3472）；最危险资源区派 1~3 人（3492-3526），45 米外且离家 >25 米的不动，守护 9 秒后撤回（3493、3511-3513、3533-3543）。

### 十二、资源预留：防守不能吃光补兵预算

`_defense_reserve()` 返回必须留存的资源比例：平静 0.35、警戒 0.2、防守及以上 0.22（AIDefense.gd:3693-3700）。注释直指历史 bug：AIDefense 在 AI 生产流程之前把资源花光，导致“进入防守后不再生产军队”。`_can_spend` 对每项资源要求 `余额 - 该项成本 >= 上限 × reserve_ratio`（AIDefense.gd:3681-3691）。该保留金被早期城堡升级（:375）、应急塔（:2879）、城防建造（:2754）、塔升级（:2921）共用；只有箭塔/炮塔被允许绕过（0.05），因为“塔跟不上就永远没有火力”。

### 十三、与 AIWallPlanner 的衔接

分工是**几何 vs 顺序**的切分：AIDefense 决定墙位坐标并压入 `_defense_queue`（含初始 `priority`），`AIWallPlanner` 只改优先级、不改墙线（AIWallPlanner.gd:1-4）。

- 挂载：`AIWallPlannerScript.new(self, _defense)`（AI.gd:2363-2364），每 0.8 秒 tick（AIWallPlanner.gd:7、30-33）。
- 前置条件：必须 `defense.defense_initialized` 为真（AIWallPlanner.gd:34-35）。
- 排序规则：以“天然屏障端头”为根先落地（-2.8），已咬合已建墙的次之（-1.1），孤立墙段罚 +3.5，朝敌方向再 -0.8×对齐度（AIWallPlanner.gd:62-76）；`_base_priority` 缓存原始优先级，避免每轮叠加（:54-61、:52-53 上限 768 条）。
- 结果直接写回 `defense._defense_queue` 的 `item["priority"]` 并重排（AIWallPlanner.gd:76-80），`_build_defense_step` 按数组顺序取用。**因此最终建造顺序由 AIWallPlanner 决定，AIDefense 只提供基准值。**

### 十四、设计模式

- **适配器/门面**：DefenseContext 把 `AI` 的内部字段包成只读 API，威胁模型不感知 AI 结构（DefenseContext.gd:26-52）。
- **镜像过渡（Strangler Fig）**：新模型接管计算，旧字段保留兼容，调用方逐个迁移（AIDefense.gd:124、297-312）。
- **多级降级**：闭合环 → 贴地形环 → 半径内收 → 半圈墙，每级都可完整回滚三张表再试（AIDefense.gd:512-533）。
- **预算/节流**：毫秒级时间预算 + 空间缓存 + 分帧批量（AIDefense.gd:36-41、64、167-168、2372-2396）。
- **角色标签 + 中央账本**：meta 标记 (`ai_home_guard/ai_wall_guard/ai_resource_guard/ai_transporting`) 与 `_director_claim` 双轨，防止各模块互抢单位（AIDefense.gd:3293、3036-3039、3326-3355）。

### 十五、复杂度热点

1. `_is_valid_defense_ground` 每个候选点都遍历全部实体 + 全部可见敌军（AIDefense.gd:3597-3643）；素数级候选（隘口搜索 8×15 格、半径 6~28）时是主要成本。
2. `_ring_blocked_base` 一次 10000 格 + 全实体占地标记（AIDefense.gd:2372-2396），虽有缓存但缓存按“一次规划”清空（:2002-2003）。
3. `_ring_is_sealed` / `_ring_sealed` 每个候选半径跑一次全 BFS，`_ring_fill_gaps` 内最多再跑 6 次（AIDefense.gd:1824-1832）。
4. `_ring_gap_deg` 180 分箱 × 全部 `wall_positions`（AIDefense.gd:756-804），`_cell_obstructed` 逐段遍历全部实体（:690-698）。
5. `_watchtower_visible_gain` 每候选约 600 次采样 × `_watchtower_cell_weight`（AIDefense.gd:2153-2184）。

### 十六、风险与改进建议

1. **旧公开字段与快照双写，没有一致性约束**。`sectors/tracks` 全仓无消费者，迁移停在半途（AIDefense.gd:315-323）。建议：先在调试面板消费 `get_primary_threat_sector()`，再把墙段/塔位优先级改成按扇区加权，最后删掉镜像字段。
2. **注释与实现自相矛盾**：AIDefense.gd:549 说“首圈墙排在塔和外圈之前”，但首圈墙 `prio_base=4.0`（:493），箭塔 0.6、炮塔 0.5（:2049、:2070）——升序队列里塔实际先建；:474-475 与 :2047-2049 也给出了相反描述。建议统一口径（现状是“塔优先”，与 :2734-2742 的经济闸门一致），并修正注释。
3. **AI.gd 残留整套旧防御实现**：`defense_check_timer/defense_initialized/_defense_queue`（AI.gd:83-85）与 `_manage_defense` / `_build_defense_step` / `_queue_defense_gaps`（AI.gd:3852-3874、3971、4002）已无调用点（grep 仅命中定义）。建议删除，避免后人误改死代码。
4. **DefenseContext 的适配方法未接入**：`build/assign_builders` 无人调用，`battle` 只捕获一次（DefenseContext.gd:11-13）。建议让 AIDefense 全部改走 context，并做成 `get_battle()` 动态取。
5. **递归重试缺时间预算**：`_plan_wall_ring` 在 `force_radius<=0` 时递归 3 次（:524-529），每次重跑 A* + BFS，而 `RING_PLAN_BUDGET_MS` 只在半径循环里检查（:1955-1963）。极端地形下仍可能一次性卡住主线程，建议把预算计时器下传到递归层。
6. **威胁只看可见单位，无“记忆”**：敌军走出视野瞬间压力归零（DefenseThreatModel.gd:89、143-144），只有 `castle_damage_until` 有 8 秒记忆（:137）。可考虑对 `tracks` 做短期衰减记忆，复用现成轨迹结构。
7. **阈值硬编码**：12/6/2（DefenseThreatModel.gd:154-161）与难度无关，HELL 与 EASY 用同一套防线触发节奏，可作为难度参数外置。
8. **`_ring_wall_budget(null, max_rr)` 传 null castle**（AIDefense.gd:2747）依赖函数当前不读 castle 参数（:849-850），属于隐式契约，建议改成显式 `ring_r` 参数。

## 第 3 章 · 附属工程模块与集成入口（渡水 / 城墙 / 爬梯 / 农民调度）

### 0. 阅读范围与结论摘要

本文件拆解 AI 的 4 个附属模块（渡水、城墙排序、梯子攻城、农民调度）以及它们在单机 1v1/2v2/3v3/FFA、联机、战役/训练营中的创建入口。所有结论均来自当前工作区代码。

- 4 个模块都是 `RefCounted`（无节点生命周期），由 `AIController._ready()` 统一 new 出来 (AI.gd:1834-1838)，在 AI 的决策轮次 / 独立节流器里被 tick。
- `AIWaterCrossing` 是目前唯一有完整"规划→建造→装船→出航→卸载→冷却"状态机的模块，且自带失败退避 (AIWaterCrossing.gd:124-203)。
- `AIWallPlanner` 严格只改 `AIDefense._defense_queue` 的优先级排序，不改墙位集合 (AIWallPlanner.gd:2/76-80)。
- `AILadderSiege` 只做"选梯位 + `ai.build_ladder()` + 号召破墙"，被拆后 10 秒冷却重试 (AILadderSiege.gd:59/112-133)。
- `AIWorkerDirector` 的设计文档仍写"第 1 阶段只读账本"，但代码已进入第 2 阶段并接管补农/采集分配 (AIWorkerDirector.gd:2-4, AI.gd:2737-2744)，注释与实现存在版本漂移。
- 难度枚举 `EASY/NORMAL/HARD/HELL` 在 AI 侧只有 2 个真实读取点：思考间隔和 AI 资源交付倍率；其余行为并不随难度变化。

### 1. 模块总览

| 文件 | 行数 | 类型 | 职责 | 接入位置 |
|---|---|---|---|---|
| AIWaterCrossing.gd | 1708 | `class_name` + RefCounted | 搭桥 / 运载船渡海 / 船坞与护航协同 | AI.gd:1835，tick 在 AI.gd:2374-2377 |
| AIWallPlanner.gd | 143 | RefCounted | 仅重排 AIDefense 墙位优先级 | AI.gd:2361-2365（懒创建） |
| AILadderSiege.gd | 266 | `class_name` + RefCounted | 贴敌墙造梯子并号召部队穿墙 | AI.gd:1836，tick 在 AI.gd:2185-2186/2211-2212 |
| AIWorkerDirector.gd | 367 | `class_name` + RefCounted | 农民账本 / 补农 / 采集与重排 | AI.gd:1837-1838、1937-1938、2737-2740 |

四个模块的构造签名：渡水/梯子只传 `self`，墙规划器传 `(self, _defense)`，农民调度器分两步 `new()` + `setup(self)` (AI.gd:1834-1838, AIWallPlanner.gd:23-25, AIWorkerDirector.gd:29-32)。

### 2. AIWaterCrossing：渡水规划与执行

#### 2.1 触发判定（每 6 秒一次规划）

`tick()` 先递减 `_plan_timer`，到期后调用 `_refresh_plan()`，然后按 `mode` 分派 `_tick_bridge` 或 `_tick_transport` (AIWaterCrossing.gd:124-134)。规划间隔 `PLAN_INTERVAL = 6.0` (AIWaterCrossing.gd:25)。

`_refresh_plan()` 的判定顺序 (AIWaterCrossing.gd:138-203)：

1. 搭桥中途不重算，避免丢掉建了一半的桥段 (AIWaterCrossing.gd:140-141)；
2. 运载船队已集结/出航时冻结两岸，只有超过 `SHORES_REFRESH_SEC=60s` 才强制换登陆场 (AIWaterCrossing.gd:146-149, 85)；
3. 取己方主城与"当前进攻目标城堡"，任一无效则 `_stop_all()` (AIWaterCrossing.gd:150-154)；
4. 以主城格为起点做陆地 BFS（桥梁视为可通行） (AIWaterCrossing.gd:155-159)；若目标格已可达，说明陆军能走过去，只尝试"资源短桥" (AIWaterCrossing.gd:160-166, 346-360)；
5. 连续 3 次搭桥失败后进入 45 秒退避，退避期间跳过搭桥计划 (AIWaterCrossing.gd:169-177, 836-840)；
6. 桥计划为空则尝试资源桥，再失败才切运载船：`_find_transport_shores()` 找到两岸停泊/登陆点即 `mode = MODE_TRANSPORT`，否则 `_stop_all()` (AIWaterCrossing.gd:189-203)。

桥梁选择算法：从己方岸沿 4 个方向直扫，跨度上限 `MAX_BRIDGE_SPAN=10`，整局桥数上限 `MAX_BRIDGES=10`，评分 `桥长*8 + 已建桥数惩罚`，取最小分 (AIWaterCrossing.gd:13-18, 298-344)。资源桥更短更保守：跨度 ≤7、目标资源半径 3、整局最多 3 座 (AIWaterCrossing.gd:21-24, 460-548)。

#### 2.2 桥梁执行

`_tick_bridge()` 只处理计划队首 (AIWaterCrossing.gd:766-834)：

- 施工中的桥段不会被弹出计划，只有 `build_timer<=0` 才算已建 (AIWaterCrossing.gd:774-785)；
- 若桥段停工/农民阵亡/`awaiting_builder`，按施工倒计时是否推进判断卡死，停 8 秒就 `_release_builders()` 后重派 (AIWaterCrossing.gd:786-805)；
- 木材不够时累计 `BRIDGE_AFFORD_TIMEOUT=30s` 后放弃本段并记一次失败 (AIWaterCrossing.gd:806-814, 50)；
- 桥位被占/地形变化由 `battle.is_valid_bridge_position()` 否决 (AIWaterCrossing.gd:816-821)；
- 真正落地统一走 `ai.build_building(BRIDGE_ID, pos)`（ID 7） (AIWaterCrossing.gd:13, 822)；
- 桥全部建成后对全军 `recalculate_path()` 并立刻 `ai.allocate_workers()` 重新分配农民 (AIWaterCrossing.gd:827-850)。

#### 2.3 船坞 / 运载船 / 护航协同

运载船分支的核心参数：运载船 ID=9、船坞 ID=23、船坞需 3 级、单船载 8 人、基础一波 4 船/30 兵/4 护航，每 240 秒成长一档，上限 8 船/8 护航/每次 +8 兵 (AIWaterCrossing.gd:13-36, 855-890)。

- 船坞选址：优先在己方登陆岸 16m 内找现有船坞，否则用 `_find_shore_shipyard_pos()` 在岸边新建 (AIWaterCrossing.gd:1531-1620)；
- 船坞水域连通性：用 BFS 检查船坞旁水域能否开到出发岸，结果按"船坞实例+岸格"缓存，避免内陆水塘船坞 (AIWaterCrossing.gd:81-83, 1475-1530)；
- 科技：强制把"渡水专用"船坞升到 3 级，绕开 `ai.upgrade_building(23)` 会选到内陆船坞的问题 (AIWaterCrossing.gd:1639-1656)；
- 造运载船：只统计已下水数量（不算生产队列），并把运载船插到生产队列索引 1，避免排在十几艘船后面 (AIWaterCrossing.gd:1658-1686)；
- 护航舰 ID 取 `[13, 39, 40]`，需船坞 2 级以上，同样插队 (AIWaterCrossing.gd:39, 1688-1708)；
- 登陆点：在敌岸候选里按防御分（敌军/防御塔距离加权）挑安全点，若最近点过强则在 28m 内换点，允许绕行不超过 10% (AIWaterCrossing.gd:89-94, 641-713)；
- 编队凑不齐时 `FLEET_ASSEMBLY_TIMEOUT=45s` 后按现有船只降级出发，避免海峡图永远不登陆 (AIWaterCrossing.gd:44-47, 947-964)。

#### 2.4 状态机与超时

渡水是双层状态机：`mode`（NONE/BRIDGE/TRANSPORT）+ `_transport_state`（IDLE/GATHER/SAIL/COOLDOWN） (AIWaterCrossing.gd:55-62, 96)。

| 状态 | 行为 | 超时/出口 |
|---|---|---|
| STATE_IDLE | 等船坞/等船、集结岸边停泊位 | 45s 降级出发 (AIWaterCrossing.gd:960-962)、90s 判定卡住换岸点 (AIWaterCrossing.gd:52, 1009-1013) |
| STATE_GATHER | 农民/陆军上船 | 50s `BOARD_WAIT_TIMEOUT` 或达配额即开船 (AIWaterCrossing.gd:43, 1145-1215) |
| STATE_SAIL | 舰队驶向敌岸、卸载 | 180s `FLEET_SAIL_TIMEOUT` (AIWaterCrossing.gd:53, 1217-1270) |
| STATE_COOLDOWN | 5 秒后船回己岸、重置波次规模 | 5s (AIWaterCrossing.gd:976-991) |

防守时直接 `_abort_transport()` 释放海军，不让渡水锁住防守兵力 (AIWaterCrossing.gd:938-941)；中止时把所有已登船单位就近卸载，避免单位永久藏在船里 (AIWaterCrossing.gd:214-241)。

#### 2.5 与 AI.gd 的接口

模块对 AI 是"鸭子类型 + 私有成员直连"，没有抽象接口：

- 被 AI 调用：`has_pending_bridge()` → 桥梁木材预留 (AIWaterCrossing.gd:362, AI.gd:1446-1452)；`can_builder_reach()` → 建造/搭梯可达性 (AIWaterCrossing.gd:367-409, AI.gd:1482/1614-1616)；`is_planned_bridge_position()` (AIWaterCrossing.gd:455, AI.gd:1592)；`plan_bridge_to()` (AIWaterCrossing.gd:411-453, AI.gd:1616/4214)。
- 反向调用 AI：`ai.build_building` (AIWaterCrossing.gd:822)、`ai.can_afford_building`、`ai.upgrade_building`、`ai.count_building`、`ai.get_peer_castle`、`ai._get_attack_target_castle`（私有）、`ai._is_defending`（私有） (AIWaterCrossing.gd:150-151, 806, 938, 1649-1656)。
- 对战场：`battle.world_to_grid/grid_to_world/get_terrain_at_grid/is_valid_bridge_position/assign_builders/entities` (AIWaterCrossing.gd:155-157, 774-802, 816)。
- tick 传入的是 AI 的决策间隔 `_decide_interval` 而非帧 delta，否则船队计时会慢几十倍 (AI.gd:2374-2377)。

### 3. AIWallPlanner：只排队、不改墙线

模块头部注明"只调整 AIDefense 已经规划好的墙位顺序，不改墙线本身" (AIWallPlanner.gd:2)，这是硬约束：它只遍历 `defense._defense_queue` 中 `id==27`（城墙）的项，改写 `item["priority"]` 后原地排序 (AIWallPlanner.gd:47-80)。

- 节流：`RANK_INTERVAL=0.8s`，且必须等 `defense.defense_initialized` 为真才工作 (AIWallPlanner.gd:7, 27-35)；
- 缓存基准优先级：按位置字符串 `"%.2f:%.2f"` 记住 AIDefense 给的原始 priority，>768 条清空防膨胀 (AIWallPlanner.gd:16, 51-61, 95-96)；
- 排序修正：锚点 `-2.8`、已连接已建墙 `-1.1`、孤立墙段 `+3.5`、朝敌方向再 `- front_score*0.8`，最终 priority 越小越先建 (AIWallPlanner.gd:9-11, 62-76)；
- 锚点定义：墙格 8 邻域贴地图边缘、贴悬崖 `is_cliff_tile`、或贴山体（terrain==2 且 overlay!=3，浅滩不算屏障） (AIWallPlanner.gd:99-124)；结果按格缓存 (AIWallPlanner.gd:17, 101-103)；
- 连接判定：`LINK_RADIUS=2.35` 内存在己方已建城墙即算"已连接" (AIWallPlanner.gd:8, 82-93, 126-136)；
- 消费者：`AIDefense._build_defense_step` 按数组顺序取，所以排序即建造顺序 (AIWallPlanner.gd:77)。

### 4. AILadderSiege：造梯翻墙

触发条件 `_can_try()` (AILadderSiege.gd:112-133)：处于 DEVELOPMENT/ASSAULT 阶段、对局 ≥120 秒、自身不在防守、非 DEFEND 战术、训练关允许该建筑、距上次重试 ≥10 秒、连续失败 <8 次（达到后冷却变 3 倍）。梯子 ID=8，同波次最多 2 把 (AILadderSiege.gd:11, 17, 22-23)。

选点流程 (AILadderSiege.gd:80-110)：目标城堡有效 → 找到最近的己方野战军位置 (`_main_army_position`，排除水军/农民/守墙/骚扰/运输中单位) (AILadderSiege.gd:145-165) → 战场单位 ≥8 → 资源够 → 已有梯子 <2 → 枚举敌墙。

- 候选墙：敌方的、已完工的城墙，距目标城堡 ≤30m；评分 `-距野战军*1.2 - |距城堡-12|*0.8 - 墙顶炮数*6`，取前 8 (AILadderSiege.gd:19, 24, 167-187, 189-200)；
- 梯位：先只试"朝城堡外侧"的 4 个相邻格，不满足再放宽到四侧；`battle.is_valid_ladder_position()` 校验，评分 `距野战军 - 墙顶炮数*4` (AILadderSiege.gd:202-233)；
- 实际建造委托给 `ai.build_ladder(spot)` (AILadderSiege.gd:103)，该方法在 AI.gd:1457-1500，额外要求：同波 ≤2 把、可负担、`is_valid_ladder_position`、墙边 22m 内己方野战单位 ≥4、有空闲农民、农民能经桥/船到达 (AI.gd:1461-1483)；成功后 `spawn_entity` 并旋转梯面垂直墙面 (AI.gd:1494-1499)。
- 完工后 `_send_breach()` 对梯子 26m 内己方野战军下 `force_attack_move_to(目标城堡)`，每 7 秒重发一次 (AILadderSiege.gd:20-21, 74-78, 247-266)；
- 兜底：梯子被拆/墙先破/农民死亡时清空计划并 10 秒冷却；`awaiting_builder` 时自动补派空闲农民 (AILadderSiege.gd:44-78)。

### 5. AIWorkerDirector：账本与第 2 阶段

文件头声明"第 2 阶段：接管补农 + 基础采集分配；建造/修理/逃跑仍由旧逻辑负责" (AIWorkerDirector.gd:2-4)，角色枚举 8 种（IDLE/GATHER/HAULER/BUILDER/REPAIRER/FLEE/GARRISON/HUNT） (AIWorkerDirector.gd:8-17)。

- 账本：每 1 秒 `_sync_roster()` 只读扫描全部农民，记录角色/当前命令/目标/位置到 `_workers`，同时同步 `ai.desired_worker_count` (AIWorkerDirector.gd:18, 34-45, 122-143)；
- 分配：AI 的 `allocate_workers()` 已改路由到本模块，旧实现 `_legacy_allocate_workers()` 保留作回滚路径 (AI.gd:2737-2744)；每约 3 秒调用 `allocate()`，内部依次清威胁缓存、食物救急、紧急再平衡、补农、空闲分配、满仓改派、周期重排 (AIWorkerDirector.gd:47-64, AI.gd:1932-1938)；
- 补农：阶段目标 8/12/15，保底 4/6/8；保底补农不受食物告急/资源满仓限制；训练冷却 1.5s (AIWorkerDirector.gd:66-110, 198-210)；
- 满仓改派：资源占比 ≥ `ai._pressure_threshold()` 时把农民转去未满资源 (AIWorkerDirector.gd:229-252)；
- 周期重排：每 11 次分配（≈33 秒）按 `(1-库存比)*阶段权重` 计算缺口并重排，同时触发仓库远近检查 (AIWorkerDirector.gd:254-317)；
- 日志：仅 debug 构建每 5 秒一行 `[WORKER]`，含 live/queued/target/floor/角色分布/训练阻塞原因 (AIWorkerDirector.gd:19, 336-357)。

注意版本漂移：AI.gd:1936 注释仍写"第 1 阶段：只读账本，不改农民命令"，但该模块实际会 `produce_unit(10)`、`gather_at()` 并接管 `allocate_workers()`，设计文档 `docs/AI_WORKER_DIRECTOR_DESIGN.md` 也仍记录"第 1 阶段已接入"。

### 6. 集成入口：AI 实例在哪创建

#### 6.1 单机 1v1 / 战役：场景静态 AIController

1v1 不 `new()`，而是复用 `rts_battle.tscn` 里预置的 `AIController` 子节点：`_ready()` 里随机红蓝后重写 `static_ai.my_team = enemy_team` (RTSBattleManager.gd:1570-1583)；开局生成阶段再兜底一次 (RTSBattleManager.gd:2933-2937)。战役同样复用该静态节点，只改 team (RTSBattleManager.gd:1592-1594)，再由 `CampaignDirector._setup_ai()` 决定保留/销毁并写 `nation` (CampaignDirector.gd:252-263)，必要时调用 `ai.prebuild_campaign_defense()` 预置要塞 (CampaignDirector.gd:268-276, AI.gd:1026)。

#### 6.2 单机 2v2 / 3v3：`_init_multi_single`

固定 4 或 6 个席位，setup 数组写死 `peer_id 1..N + team + slot`，AI 国家用 `SimRandom.randi() % Nation.size()` 随机 (RTSBattleManager.gd:1825-1832)。AI 实例在 1870-1874 创建：只赋 `my_peer_id`、`my_team`、`name`，然后 `add_child`；资源/人口/上限在此前按 pid 写入 `ai_resources`/`ai_population`/`ai_limits` (RTSBattleManager.gd:1866-1868)，3v3 同构 (RTSBattleManager.gd:1988-2025)。创建后立即销毁场景静态 AI，避免多跑一个红队 (RTSBattleManager.gd:2027-2032)。

#### 6.3 单机 FFA（3~5 国）

`_init_ffa_single()` 给每个 AI 独立段：`pid = 3000 + index`、`team = 3 + index`（避开 RED=0/NEUTRAL=2/BLUE=1）、国家从国家池 `SimRandom.shuffle` 去重抽取 (RTSBattleManager.gd:1668-1694, 1722-1726)。AI 控制器创建于 1754-1758，同样只写 peer_id/team；城堡、外交注册、3 个初始农民在此前后完成 (RTSBattleManager.gd:1736-1752)。

#### 6.4 联机：`OnlineBattleManager`

`_create_ai_player(peer_id, team, slot)` 先写 `player_info[peer_id]`（`is_ai=true`、nation、color、alive）、`player_resources`（各 100）、`player_population`（3/30）、`team_nations`，再 `AIController.new()` 并赋 `my_peer_id/my_team` (OnlineBattleManager.gd:657-679)。调用点是按 `NetworkManager.red_ai_count/blue_ai_count` 补齐红蓝槽位 (OnlineBattleManager.gd:571-586)。AI 淘汰清理由 `_clear_eliminated_player_entities/_team_entities` 按 `AIController.my_peer_id` 或 `my_team` 停进程并 `queue_free` (OnlineBattleManager.gd:1575-1620)。

#### 6.5 训练营多 AI

`_create_training_ai(pid, team, nation)` 是唯一显式写 `ai.nation` 的创建入口 (RTSBattleManager.gd:2166-2172)；训练营强制三处难度为 EASY (RTSBattleManager.gd:2077-2079)，盟友 pid=1000、敌人 pid=2000+i (RTSBattleManager.gd:2090-2118)。

#### 6.6 AIController ↔ RTSBattleManager 接口面

- 生成：`battle.spawn_entity(cfg, team, pos, level)`，AI 建造统一走 `ai.build_building()`/`ai.build_ladder()` → battle 校验 → spawn (AI.gd:1484-1494)；
- 查询：`battle._ensure_cache_fresh()` + `_all_entities/_armies/_buildings/_cached_buildings()`，模块直接读这些数组 (AILadderSiege.gd:42, 148, 169; AIWallPlanner.gd:85)；
- 命令/建造：`battle.find_nearest_idle_builder()`、`battle.assign_builders()`、`battle.is_valid_ladder_position()`、`battle.is_training_building_allowed()`、`battle.is_valid_bridge_position()` (AILadderSiege.gd:63-68, 122-124; AIWaterCrossing.gd:799-802, 816)；
- 资源账本：单机 `ai_resources/ai_population/ai_limits` 按 owner 索引，AI 侧 `_get_resources()/_get_limits()` 映射到它们；联机则是 `player_resources/player_population/player_limits_dict` 按 peer_id 索引 (RTSBattleManager.gd:1866-1868, OnlineBattleManager.gd:667-670)。这是两套账本，模块通过 AI 的封装函数才不感知差异。

### 7. GameSettings 难度枚举与实际读取点

枚举定义 `enum AIDifficulty { EASY, NORMAL, HARD, HELL }`，三个字段：`ai_difficulty`、`blue_ai_difficulty`、`red_ai_difficulty`（2v2 分色） (GameSettings.gd:2, 12, 14-15)。实际读取点只有：

| 读取点 | 作用 | 行号 |
|---|---|---|
| AIController 初始化 | 思考间隔 EASY 2.0 / NORMAL 1.75 / HARD 1.5 / HELL 1.0 秒 | AI.gd:1865-1871 |
| 单机资源交付 | NORMAL ×2、HARD 及以上 ×3 | RTSBattleManager.gd:2557-2559、3763-3764 |
| 联机资源交付 | 按 `red/blue_ai_difficulty` 同样 ×2/×3 | OnlineBattleManager.gd:313-317 |
| 结算面板文案 | `diff_names[clampi(ai_difficulty,0,3)]` | RTSBattleManager.gd:5522 |

也就是说难度目前只影响"AI 反应速度 + 采集效率倍率"，不影响兵力规模、战术选择、渡水/梯子触发阈值。

### 8. SimRandom / SimTime 用法

`SimRandom` 是确定性随机源（每次取数 `_draws++`）(SimRandom.gd:3-44)；`SimTime.now_ms()` 在 `GameSettings.deterministic_sim` 为真时用物理帧换算，否则返回墙钟 (SimTime.gd:16-22)。随机源在 `RTSBattleManager._enter_tree()` 一次性播种，指令回放会强制 `deterministic_sim` 并复用 `sim_seed` 作为地图种子 (RTSBattleManager.gd:1528-1543)。

| 文件 | SimRandom 调用 | SimTime 调用 | 典型场景 |
|---|---|---|---|
| AI.gd | 13 | 12 | 出生点抖动/阵型偏移、随机选兵种、概率分支、SIM 日志帧号、各种冷却时间戳 (AI.gd:2643, 3188-3190, 3556, 3736-3737, 4318, 5478, 5535, 5684; 1994, 3233, 3265, 4757, 4838) |
| AIWaterCrossing.gd | 0 | 6 | 上岸点 60s 刷新、搭桥退避 45s、失败判定 (AIWaterCrossing.gd:147, 172, 200, 419, 840) |
| AILadderSiege.gd | 0 | 5 | 重试/破墙重发冷却 (AILadderSiege.gd:59, 74, 110, 125) |
| AIWallPlanner.gd | 0 | 0 | 纯几何排序，无计时/随机 |
| AIWorkerDirector.gd | 0 | 0 | 用 `battle.game_time` 与 1s tick (AIWorkerDirector.gd:97, 34-40) |
| AIDefense.gd | 0 | 5 | 环形防线规划预算 (AIDefense.gd:1823-1831, 1955-1961) |

确定性相关：AI 在 `deterministic_sim` 下把 `_process` 切到 `_physics_process` 驱动 (AI.gd:1849-1857)，相位错开中的 `get_instance_id()` 在确定性模式下被置 0 (AI.gd:1872-1873)。风险点：联机 AI 国家和建造位置仍用全局随机——`_pick_ai_nation()` 用 `randi()` (OnlineBattleManager.gd:655)，`find_valid_build_position()` 用 `randf_range()` (OnlineBattleManager.gd:706-708)，若未来开放联机回放，这两处不进入 SimRandom 序列，会导致重演分叉。

### 9. 依赖关系图（文字版）

```
rts_battle.tscn 静态节点 AIController ──(1v1/战役/训练营复用, 改 team)
RTSBattleManager._init_ffa_single/_init_multi_single/_create_training_ai
OnlineBattleManager._create_ai_player
        │ add_child(AIController)
        ▼
AIController (AI.gd)
 ├─ preload：AIWaterCrossing / AIWallPlanner / AILadderSiege / AIWorkerDirector (AI.gd:10-13)
 ├─ _defense = AIDefense.new(self) (AI.gd:1834)
 ├─ _water_crossing = new(self)           ── 读 ai.*、battle.*；反向 ai.build_building / ai.allocate_workers
 ├─ _ladder_siege = new(self)             ── 读 battle._armies/_buildings；调 ai.build_ladder
 ├─ _worker_director = new()+setup(self)  ── 读 ai._cached_armies；写 ai.desired_worker_count；
 │                                          调 ai.produce_unit / ai.find_best_resource_for_worker / ai.consider_warehouse_near_farmer
 └─ _wall_planner = new(self, _defense)   ── 读写 defense._defense_queue 与 ai.battle.*
        │
        ▼
RTSBattleManager（实体缓存 / spawn_entity / 建造校验 / 资源账本 / 树障与地形查询）
        │
        ├─ SimRandom（确定性随机，_enter_tree 播种）
        ├─ SimTime（回放时钟）
        └─ GameSettings（难度枚举/种子/模式）

模块间横向调用：AIWaterCrossing → ai.allocate_workers() → AIWorkerDirector.allocate()（跨模块单向下行）；
AI.build_ladder() → AIWaterCrossing.can_builder_reach()（AI 作为中介形成 A→B→A 的间接回路）。
AIDefense._defense_queue 是 AIWallPlanner 的唯一输入，AIDefense 不反向依赖墙规划器（无预加载环）。
```

### 10. 风险清单

1. **私有成员耦合**：4 个模块大量直接调用 `ai._get_attack_target_castle/_is_defending/_cached_armies/_cached_buildings/_get_enemy_army_direction/_worker_resource_weights` 等私有方法与字段 (AIWaterCrossing.gd:151/938, AIWallPlanner.gd:40/85, AILadderSiege.gd:83/143, AIWorkerDirector.gd:128)。任何私有成员改名都会在运行时才暴露，而非编译期。
2. **注释与实现漂移**：WorkerDirector 已是第 2 阶段（接管补农/采集），但 AI.gd:1936 与设计文档仍写"第 1 阶段只读账本"，容易误判回滚范围。
3. **难度只影响 2 个维度**：见第 7 节，EASY 与 HELL 的 AI 战术行为完全一致，仅思考频率与资源倍率不同。
4. **确定性地雷**：联机 AI 国家/建造点使用全局 RNG (OnlineBattleManager.gd:655/706-708)，与 SimRandom 体系并存。
5. **两套资源账本**：单机按 `ai_resources[pid]`、联机按 `player_resources[peer_id]`，模块必须经 AI 封装访问；若新模块直接读 battle 字段，会在另一种模式静默取空。
6. **每帧/每轮全量扫描**：梯子模块每 2 秒遍历 `_armies` 两次、墙规划每 0.8 秒遍历全部己方建筑（AIWallPlanner.gd:82-93, AILadderSiege.gd:145-187）。靠 AI.gd `_late_game_scale()` 降频的是农民/海军/修理，墙规划与梯子仍按固定间隔跑，600+ 实体时是潜在热点 (AI.gd:1840-1847, 2361-2365)。

## 第 4 章 · 跨模块风险登记与改进路线

> 本章不重复各章细节，只做**跨模块归并**：同一根因在多个模块出现时合并为一条，并给出优先级与改法。
> 行号引用来自前 3 章同一基线。

### 4.1 风险分级总表

| 级别 | 风险 | 证据（跨模块） | 影响 |
|------|------|----------------|------|
| **P0** | 联机 AI 用全局 RNG | `OnlineBattleManager.gd:655`、`:706-708`（AI 国家/建造点用 `randi/randf_range`），而 AI 内部全走 `SimRandom` | 指令回放（`deterministic_sim`）在联机 AI 局必然不同步，回放失效 |
| **P0** | 战术函数内 `await` 与同步调用竞态 | `execute_overwhelm` 含 `await 10s`、`execute_raid` 多次 `await`，由 `update_tactic` 同步调用不等待（AI.gd:3505-3768） | 集结/骚扰途中被下一轮战术改写，出现"刚集合又换目标"的中态 |
| **P0** | 两套资源账本 + 模块直读 AI 私有成员 | 单机 `ai_resources[pid]` / 联机 `player_resources[peer]`；4 个模块直接调 `ai._cached_armies`、`ai._is_defending` 等（AIWaterCrossing.gd:151/938、AIWallPlanner.gd:40/85、AILadderSiege.gd:83/143、AIWorkerDirector.gd:128） | 新模块若直接读 battle 字段，在另一种模式下**静默取空**；改名只在运行时炸 |
| **P0** | 确定性/非确定性两条路径不等价 | `_process` vs `_physics_process` 双轨（AI.gd:1846-1854）、预算 break 在确定性下关闭（:2248）、`_decide_cost_scale` 被强制 1.0（:2257-2258） | 回放局与实战局 AI 行为不同，录像不能作为 bug 复现依据 |
| **P1** | `AI.gd` 上帝对象 6.2k 行 | 经济/军事/外交/UI 四套系统同文件；`_state_development`/`_state_assault` 尾段重复（AI.gd:2158-2223） | 改动易互相踩踏，评审成本高 |
| **P1** | 死代码与双实现并存 | `decide()` 无调用点（:2226）、旧防线 5 函数（:3797-3869）未删、`_legacy_allocate_workers`（:2744）与 WorkerDirector 双路径 | 后人误改死代码；grep 噪声大 |
| **P1** | O(实体数) 全量扫描散落且部分未降频 | `count_unit/count_building` 每次全扫；`_get_build_completion` 对 9 个 ID 各扫一遍（AI.gd:4358-4366）；`AIDefense._is_valid_defense_ground` 每候选遍历全实体+全敌军（AIDefense.gd:3597-3643）；`AIWallPlanner` 0.8s、`AILadderSiege` 2s 是固定间隔，**不受 `_late_game_scale()` 影响** | 600+ 实体后期是主要卡顿源 |
| **P1** | 硬编码 ID/阈值 20+ 处重复 | 兵种排除表 `[5,6,9,10,14,33,43..51]` 等在 20+ 处重复（AI.gd 全文）；`DefenseThreatModel` 阈值 12/6/2（:154-161） | 新增兵种/调平衡需多点同步，必漏改 |
| **P2** | 难度只影响 2 个维度 | 仅 `think_interval`（AI.gd:1865-1868）与资源交付倍率（RTSBattleManager.gd:2557-2559 / OnlineBattleManager.gd:313-317）；防线触发阈值与战术选择与难度无关 | EASY 与 HELL 战术同构，"更高难度"= 反应更快而非更聪明 |
| **P2** | 威胁无记忆 | 敌军离开视野压力立即归零（DefenseThreatModel.gd:89、:143-144），仅主城掉血有 8s 记忆（:137） | 诱敌/骚扰可把防线拉空；`tracks` 结构已具备但未用于衰减记忆 |
| **P2** | 注释与实现漂移 | `AI.gd:1936` 写"第 1 阶段只读账本"但 WorkerDirector 已接管补农/采集；`AIDefense.gd:549` 说墙先于塔但 `prio` 实际塔先（:493/:2049） | 误判回滚范围与优先级 |
| **P2** | 约定式 meta 无常量表 | `ai_home_guard/ai_wall_guard/ai_resource_guard/ai_harass/ai_transporting/ai_escorting/ai_role/ai_ladder…` 跨 5 个文件共享，仅守墙 5 个定义为常量（AI.gd:202-206） | 拼写漂移静默失效 |
| **P2** | 半途的预留接口 | `DefenseThreatModel.sectors/tracks` 全仓无消费者（DefenseThreatModel.gd:315-323）；`DefenseContext.build/assign_builders` 无人调用（DefenseContext.gd:11-13） | 增加理解成本，迁移停滞 |

### 4.2 改进路线（按投入产出排序）

**阶段 A：低成本清理（约 1~2 天，零行为变更）**

1. 删除死代码：`decide()`、旧防线 5 函数、`_legacy_allocate_workers`；同步清理 `AI.gd:83-85` 的孤儿字段。
2. 修正 3 处反向注释（AI.gd:1936、AIDefense.gd:549/474）。
3. 建 `AIMetaDefs` 常量表，替换 20+ 处重复兵种/建筑排除表。
4. 给 `AIWallPlanner` / `AILadderSiege` 接上 `_late_game_scale()` 降频（改动点小、后期收益直接）。
5. 联机 AI 的 `randi/randf_range` 全部换成 `SimRandom`，让指令回放在联机 AI 局成立。

**阶段 B：结构拆分（约 1 周，需回归验证）**

6. `AI.gd` 按职责拆为 `AIEconomy / AIMilitary / AICommand / AIDiplomacy / AIDebugPanel` 五个子模块（与现有 5 个专案模块同构，`RefCounted` + `setup(self)`），主类只保留 decide 调度与状态持有。
7. 把"预算预留链"（升时代/投石机/重装科技三种 reserve 挂在 `can_afford*` 出口，AI.gd:1249-1296）显式化为 `ReserveBudget` 对象，杜绝绕过。
8. 抽出 `_state_development` / `_state_assault` 的公共尾段为 `_common_late_tick()`。
9. 私有成员访问改为显式接口（模块只依赖 `AIController` 的公共方法），把运行时错误提前到静态检查。

**阶段 C：行为深化（约 1~2 周）**

10. 难度外置为参数表：思考间隔、防线触发阈值（12/6/2）、侦察频率、战术触发条件、资源倍率都进表，让 HELL 真正"更聪明"而不只是"更快"。
11. 威胁记忆化：用现有 `tracks` 做 5~10s 衰减记忆，避免被诱敌拉空防线。
12. 战术执行改为"意图 → 选择 → 执行"三段：`update_tactic` 只产生意图，执行器带取消/超时，消除 `await` 竞态。

**阶段 D：验证体系（与 A 并行即可启动）**

13. 固定种子自对弈回归：N 局 × 固定地图/种子，比对建造序列、首攻时间、胜负分布，作为行为回归基线。
14. 决策耗时基线：聚合 `user://ai_decide.log` 的 15 段耗时，设阈值告警（现在只有 >80ms 才记一条，无趋势）。
15. 面板字段快照测试：`update_debug_label` 输出的关键状态做断言，防止重构时静默改行为。

### 4.3 总体评价

- **工程化程度高于同类项目**：多层节流（难度基频 / 规模倍率 / 7ms 帧切片 / 成本自适应 / 帧级令牌）、确定性双轨、`ai_decide.log` 剖析、随局调试面板，说明作者是"按线上卡顿数据改 AI"而非拍脑袋。
- **行为覆盖面罕见**：经济（采集/贸易/仓储/修理）、军事（克制/攻城武器/爬梯/渡水/海军/登城守墙）、防御（三套防线方案 + 四级降级）、外交（FFA 结盟/进贡/背叛）、侦察迷雾全部有实现，且都遵守玩家同款规则（无作弊视野、无资源作弊）。
- **主要债务集中在三处**：① 6.2k 行上帝对象 + 死代码；② 硬编码表与约定式 meta 缺少单一事实源；③ 确定性双轨与联机 AI 的 RNG 不一致，导致回放不可信。
- 结论：**架构方向正确、局部实现过度耦合**。按阶段 A→B 推进可在两周内把可维护性提升一个档次，且不改变现有 AI 行为；阶段 C 才是"让 AI 更强"的真正入口。


## 第 5 章 · 复审（HEAD `bf2aeba` / `cb79362`，2026-10-30 19:20）

> 触发：18:46 报告交付后，作者又完成 **十余个 AI 相关提交**（18:41–19:13），把 AI 从"单体 + 若干子模块"推进为**「账本 + 租约 + 需求表」范式**，并落地了确定性回放的模拟基础。
> 方法：`git show` 精读每个提交的 diff + 当前文件复核；本章结论全部基于当前 HEAD，**优先于第 1~4 章**；与旧结论冲突处逐条列出。

### 5.1 这 26 分钟改了什么（提交演进线）

| 演进线 | 提交 | 内容 | 状态 |
|--------|------|------|------|
| **防御**（5 阶段） | `fa8096e`→`bfa0f3b` | 第1阶段威胁模型 → 第2阶段姿态导演+只读计划 → 第3阶段接管圈数/防守预算 → 第4阶段守军分配器（影子） → 第5阶段按分配器顺序实际选兵 | **5 阶段全部落地**，第 6 阶段未开始 |
| **农民调度**（6 阶段） | `7f034ac`→`045832a` | 第2阶段补农/采集 → 第3阶段建造/修理建造者 → 第4阶段逃跑+打猎阈值 → 第5阶段墙体/梯子建造 → 第6阶段建造请求队列（`AI_WORKER_DIRECTOR_DESIGN.md` 自述已接入） | **6 阶段落地**，第 5 步"清理旧入口"**未做** |
| **军队调度**（4 步） | `ba217a1`→`4eae94a` | 第3步进攻类接入账本 + 主攻门槛改总陆军 → 第4步统一角色判定，收敛重复过滤 | **3/4 步完成**，第 4 步"删旧函数/旧 meta"未做 |
| **确定性回放** | `19c4bca` | 新增 `SimRandom`/`SimTime`，AI 双轨 tick、固定物理步、移除实例 ID/墙钟依赖；RTSBattleManager 固定步长 + 初始化屏障 + 校验和 | **单机侧打通**，联机侧仍有全局 RNG |
| **工程修复** | `cb79362`、`ddf2f00` | `current_target` 可能已被释放时先判活再 `is Building`，修 `previously freed instance` 报错 | 已修 |

两份**作者自写的施工图**是本轮重构的权威依据，建议与代码并读：
[docs/AI_ARMY_DISPATCH_DESIGN.md](AI_ARMY_DISPATCH_DESIGN.md)（军队，4 步）、[docs/AI_WORKER_DIRECTOR_DESIGN.md](AI_WORKER_DIRECTOR_DESIGN.md)（农民，5 步 + 第 6 阶段说明）。

### 5.2 当前文件构成（v2）

| 文件 | 行数 | 变化 |
|------|------|------|
| `AI.gd` | 6,240 | +61 行（v1 为 6,179） |
| `AIDefense.gd` | 3,818 | +97 行 |
| `AIWorkerDirector.gd` | 636 | **+269 行**（v1 为 367） |
| `defense/DefenseForceAllocator.gd` | 211 | **新增** |
| `defense/DefenseDirector.gd` | 109 | +14 |
| `defense/DefensePlan.gd` | 139 | 新增（v1 附录已记录） |
| `defense/DefenseContext.gd` | 140 | +5 |
| `defense/DefenseThreatModel.gd` | 250 | 未变 |
| `AIWaterCrossing.gd` / `AIWallPlanner.gd` / `AILadderSiege.gd` | 1,708 / 143 / 266 | 仅确定性改造（`Time` → `SimTime`） |
| **合计** | **约 13,860 行** | +约 1,100 行 |

### 5.3 防御链路 v2：从"影子"到"部分实权"

当前链路与实权程度（`AIDefense.gd` 3818 行为准）：

| 环节 | 模块 | 状态 | 证据 |
|------|------|------|------|
| 威胁评估（26m 门限/平滑/扇区） | `DefenseThreatModel` | **实权** | AIDefense.gd:216 构造、tick 内取值 |
| DEFCON 姿态 + 防守预算 | `DefenseDirector` | **实权**（第3阶段起） | `_defense_reserve()` 委托 `reserve_for_level()`；`_required_wall_ring_count()` 委托 `required_ring_count()`（含科研/战役口径） |
| 只读计划视图（圈/墙位/队列） | `DefensePlan` | 只读影子（1s） | AIDefense.gd:260 附近 `_update_defense_plan_shadow` |
| 守军分配（KEEP/PROPOSE/RELEASE） | `DefenseForceAllocator` | **半实权**（第5阶段） | 每 2s 影子出建议；`get_preferred_ids()` 参与守军选兵排序，最终仍由任务/兵种/城墙规则裁决 |
| 墙/塔建造的建造者 | `AIWorkerDirector` | **实权**（第3阶段） | AIDefense.gd:2837-2838 先用 `has_available_builder()` 再规划，拿不到人就不建 |
| 农民遇敌逃跑 | `AIWorkerDirector` | **实权**（第4阶段） | AIDefense.gd:3541 起 `if ai._worker_director != null: continue`，旧移动逻辑停用 |

**分配器算法（`DefenseForceAllocator.gd`）**：
- 目标守军数：威胁 0/1 → `min(兵力, 5)`；威胁 2 → `max(6, 可见敌军×2+2)`；威胁 3 → 全员；`_force_guard_until` → 全员（:111-127）。
- 候选打分：`dist² × (1.25 − 0.25 × 与威胁方向的点积)`，即同距离优先靠威胁方向（:141-154）。
- 过滤：已有墙卫/资源卫/建筑反击/已有任务的兵不抢（:129-139）；输出还带"角色重合数"指标用于诊断（:97-108）。
- 局限：`claim` 不写 meta、不调 `_director_claim`，仍是"排序建议"；`RELEASE` 建议目前无人消费。

**v1 结论修订**：
- ❌ "预算 0.35/0.20/0.22 硬编码在 AIDefense、与难度无关" → 已迁到 `DefenseDirector`（仍与难度无关，这条风险仍在）。
- ❌ "防线圈数按主城等级 3/4/5→1/2/3 判在 AIDefense" → 已迁到 `DefenseDirector.required_ring_count()`，科研/战役口径一并迁移。
- ❌ "迁移停在半途、`DefenseContext` 适配方法无人调用" → 第 3~5 阶段已接入，`DefenseContext.get_meta_flag()` 等在用。
- ✅ 仍成立："威胁无记忆（出视野即归零）""注释与实现漂移（AIDefense.gd 塔/墙优先级）""递归重试缺时间预算"。

### 5.4 农民调度 v2：接管到第 6 阶段

`AIWorkerDirector`（636 行）现在的能力：

- **角色**：8 类（IDLE/GATHER/HAULER/BUILDER/REPAIRER/FLEE/GARRISON/HUNT，:7-16），tick 1s（:17），`allocate()` 由 AI.gd 每 3s 调一次（AI.gd:2773-2777）。
- **补农**：目标/保底 8/12/15 与 4/6/8（:465-477）；`ensure_worker_count()` 先保底再补目标，保底不受食物危机/满仓限制（:81-105）；训练冷却 1.5s（:19）。
- **采集**：空闲农民必须有目标（:480-494）；满仓资源改派（:497-519）；约 33s 按缺口做配额重排（:522-584）。
- **建造/修理**：`acquire_builder()` 三级优先级（空闲→未锁定采集→关键时抢采集兵，:127-192），90s 租约 + 3s 宽限（:20-21、275-308）；`request_build()` 队列 30s TTL / 3 次重试（:217-255）；`has_available_builder()` 供 AIDefense 建墙前查询。
- **逃跑**：8m 内有敌 → 有货先交付、无货远离 6m，9s 租约，解除后回原资源点（:367-414）。
- **仍未收编**：`ai._force_food_workers()`、`ai._emergency_rebalance_workers()` 仍由旧实现承担（:69-71 注释"第 3 阶段再收编"，实际未做）；打猎仍由 AI.gd `_ai_hunt_animals` 派单。
- **回滚路径**：`allocate_workers()` = `director.allocate()`，director 为空才走 `_legacy_allocate_workers()`（AI.gd:2773-2777）；旧函数完整保留。

**v1 结论修订**：❌ "WorkerDirector 只是第 1/2 阶段只读账本/仅补农" → 已接管采集、建造、修理、逃跑、墙体、梯子与建造请求队列；❌ "`_legacy_allocate_workers` 与 Director 双路径并存" → 仍并存，但已降级为显式回滚路径（有注释说明），风险性质从"双写"变为"回滚开关"。

### 5.5 军队调度 v2：账本成为唯一占位判定

- **角色枚举 15 类**：`IDLE/SCOUT/GARRISON/WALL/HOME_GUARD/RESOURCE_GUARD/BUILDING_DEFENSE/HARASS/RAID/FIELD/SIEGE/TRANSPORT/ESCORT/RETREAT/STANDBY`（AI.gd 头部 enum UnitRole）。
- **账本 + 租约**：`_roles[uid]`，FIELD 30s、HARASS 32s、STANDBY 25s，Director 0.5s tick（`DIRECTOR_INTERVAL`）。
- **统一判定 `_unit_has_claim()`**（AI.gd:3110 附近）：先查账本，再查 7 个旧 meta。`4eae94a` 把 `count_field_military / _ladder_support_count / attack_move / _ai_garrison_soldiers / _pick_harass_squad / execute_overwhelm×2 / execute_raid / …` 里各抄一份的组合条件全部收敛到这一个函数。
- **主攻门槛换口径**：新增 `count_land_army()`（全部陆军战斗单位，含守军/守墙/驻军，只排农民/侦察/海军，AI.gd:780-795）；`_process_line_4()` 用它在 :5220 判定主攻；`attack_move()` 跳过有角色单位并登记 FIELD；`_rally_land_army_to_castle()` 改 STANDBY 租约，首波后新兵能再次集结。
- **⚠️ 两套口径并存**：step 11 的 `DEVELOPMENT→ASSAULT` 阶段门槛**仍是** `count_field_military() >= 30`（AI.gd:2389-2396），而主攻门槛已换成 `count_land_army()`。作者的实测数据（提交信息）显示前线参与从 31.6%→67.6%、待命 45.1%→8.5%；但"阶段推进"与"是否主攻"用的是两把尺子，守军多时仍可能出现"已进 ASSAULT 但主攻不满足"的空窗，建议后续统一。
- 未做（设计文档第 4 步）：删 `_manage_home_guard/_quick_fill_home_guard/_deploy_ranged_units_to_walls/_ai_garrison_soldiers/_rally_land_army_to_castle/attack_move/execute_harass/raid/overwhelm/_retask_idle_front_units` 等旧入口、删旧 meta、接 `[DIRECTOR]` 日志。

### 5.6 确定性回放基础（`19c4bca`）

- 新增 `scripts/core/SimRandom.gd`（68 行，静态 RNG + 洗牌 + 抽样轨迹统计，仅用于"会改变对局状态"的随机）与 `SimTime.gd`（22 行：固定物理帧时钟，`deterministic_sim` 时用 `physics_frame` 换算毫秒）。
- AI 侧：`_process` 与 `_physics_process` 双轨（确定性走物理帧），`battle.sim_ready` 初始化屏障（AI.gd 顶部 `_ai_simulation_tick` 开头直接 return 直到就绪）；相位错峰里的实例 ID 归零；所有 `Time.get_ticks_msec/usec` 改 `SimTime`；确定性下 **关闭 7ms 预算切片与 `_decide_cost_scale` 自适应**（一轮 decide 在单帧内跑完，保证逐帧可复现）。
- 副作用：确定性回放时 AI 的一轮决策会完整占用一帧（600+ 实体时可达 200~500ms），回放/录像场景可接受，但"看回放会卡一下"应预期。
- **仍未闭环**：`OnlineBattleManager.gd` 仍有全局 `randi()/randf_range()`（:655、:707-708、:815、:866、:1352 等，用于 AI 国家池、出生点、集结点抖动）→ **联机 AI 局的指令回放仍不可信**，v1 的 P0 风险只是从"AI 内部"缩小到"战斗管理器建局阶段"。

### 5.7 死代码与注释漂移现况

| v1 结论 | 现状 |
|---------|------|
| `decide()` 无调用点 | **仍在**（AI.gd:2262），仍无调用 |
| 旧防线 5 函数被 AIDefense 取代未删 | **仍在**：`_manage_defense`（:3896）、`_build_defense_step`（:4015）、`_queue_defense_gaps`（:4046）等 |
| `_legacy_allocate_workers` 双路径 | **仍在**（:2780），但已明确为回滚路径 |
| 注释与实现漂移 | **新增 3 处**：① `AIWorkerDirector.gd:3` 头注释仍写"打猎仍由旧入口派单"，而 `AI_WORKER_DIRECTOR_DESIGN.md:7` 已声明第 6 阶段（建造请求队列）接入；② 设计文档称第 5 步"删旧入口"未做；③ 第 5.5 节的两套主攻口径 |

### 5.8 更新后的风险表（只列变化项）

| 级别 | 风险 | 变化 |
|------|------|------|
| **P0** | 联机 AI 建局用全局 RNG | 未解，但范围已缩小到 `OnlineBattleManager` 建局阶段（AI 决策侧已确定性化） |
| **P0** | 战术 `await` 竞态 | 未解（`execute_overwhelm/raid` 仍是同步调用含 await 的函数） |
| **P0** | 两套资源账本 + 模块直读私有成员 | 未解，且**新增** 4 个模块直接读 `ai._cached_armies/_land_combat_units/_defense_queue` 等私有成员 |
| **P1** | 双份状态（新增） | 影子模块与旧字段并存：`DefenseDirector/Plan/ForceAllocator` + `AIWorkerDirector` 账本 + 旧 meta/旧队列；任一处脱同步都会让日志"显示对、行为错" |
| **P1** | 阶段门槛与主攻门槛两套口径 | 新增（5.5 节） |
| **P1** | 死代码 / 旧入口 | 数量反而增加了 ~10 个待删函数（设计文档第 4/5 步的清理项） |
| **P2** | 注释漂移 | 从 3 处增到 5+ 处 |
| **P2** | 确定性路径下 decide 单帧跑满 | 新增（回放体验问题，非逻辑错误） |

### 5.9 下一步（按作者设计文档 + 当前代码缺口）

1. **清理旧入口（最高性价比）**：军队调度第 4 步 + 农民第 5 步——删 10 个旧函数、旧 meta 读写，接 `[DIRECTOR]`/`[WORKER]` 日志（后者已实现）。
2. **统一门槛口径**：step 11 阶段推进改用 `count_land_army()`（或明确保留两套的理由）。
3. **防御第 6 阶段**：`DefenseForceAllocator` 的 KEEP/PROPOSE/RELEASE 从"排序建议"升级为真实 claim 写入，接管墙卫/资源卫。
4. **联机确定性**：`OnlineBattleManager` 建局随机改 `SimRandom`，联机 AI 局回放才能成立。
5. **AI 回归基线**：固定种子自对弈（设计文档已建议），对比前线参与率/待命率/首攻时间，防止重构回归。
6. **收编剩余农民入口**：`_force_food_workers/_emergency_rebalance_workers` 进 Director，打猎改低优先级需求。

## 附录 A · v1 快照说明（历史存档，当前状态见第 5 章）

> 本报告的分析时间窗为 **2026-10-30 18:39–18:46（Asia/Shanghai）**。

**快照声明**：分析期间该目录有**另一个进程在并发编辑**（`AI.gd`、`AIDefense.gd`、`AIWorkerDirector.gd` 的 mtime 在分析过程中连续变化），因此本文所有行号以该时间窗的读取结果为准，后续可能有 ±数行漂移。**建议以函数名/字段名为锚点检索**，不要只信行号。

**并发新增的架构增量（已并入当前架构，前文正文未覆盖）**

| 文件 | 行数 | 角色 |
|------|------|------|
| `defense/DefenseDirector.gd` | 95 | 影子模式"态势/预算导演"：把威胁快照翻译成 `Posture{CALM,ALERT,DEFEND,CRITICAL}`（= 威胁 level 0-3）、预算预留 0.35/0.20/0.22、主扇区、圈数目标；只读 `describe()`，不改任何命令 |
| `defense/DefensePlan.gd` | 139 | 影子模式"只读防御计划视图"：汇总 rings / wall_slots / build_queue / sectors / posture / revision，供调试面板与后续规划器读取，**不写回任何旧状态** |

接入点（`AIDefense.gd`）：`16-17` preload、`132-133` 字段、`214-215` 构造、`235-236` 每轮 clear、`255` 每 tick 调 `_update_defense_plan_shadow`、`340-354` `director.evaluate()` + `plan.rebuild()`、`356-374` 对外 getter（`get_defense_plan / get_defense_posture / get_defense_budget_reserve / get_defense_director_summary`）。

**这意味着什么**

- 第 4.1 节里"半途的预留接口（P2）"应改判为**正在进行中的分段迁移**：第 1 阶段（`DefenseThreatModel` 接管计算）与第 2 阶段（`DefenseDirector`/`DefensePlan` 影子汇总）都已就位，下一步才是让 `AIDefense` 改读 `DefensePlan`、删除旧字段镜像。
- 新增风险（应加入第 4.1 节 P2）：**影子模式的双份状态**——director/plan 与 `AIDefense` 若字段脱同步，调试面板与日志会"显示正确但行为不对"；`DefensePlan.get_walls_in_ring()` 目前恒返回空数组（`DefensePlan.gd:124-126`），说明逐圈墙归属尚未实现，`build_queue` 的 `priority` 语义也仍以旧队列为准。
- 本轮并发编辑也再次印证第 1 章 §14.2 的判断：`AI.gd` / `AIDefense.gd` 这类 3k~6k 行文件在没有模块边界的情况下被频繁改动，任何行号引用都极易失效——这是"上帝对象"债务最直接的体感证据。

**复核清单（拿到最新代码后）**

1. `grep -n "func decide\|_run_decide_step\|DECIDE_LAST_STEP" scripts/ai/AI.gd` 确认 15 段决策链未变。
2. `grep -n "DefenseDirector\|DefensePlan" scripts/ai/AIDefense.gd` 确认影子接入点与本文一致。
3. 若 `DefensePlan` 开始被写入决策路径（而非只读），第 2 章"防线四级降级链"的调用位置需重新核对。

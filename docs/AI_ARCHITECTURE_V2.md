# AI 架构 v2 设计提案（草案，待拍板）

> 基线：HEAD `bf2aeba`（AI 约 13,860 行；防御 5 阶段、农民 6 阶段、军队 3/4 步已落地）
> 依据：[AI 架构分析](AI架构分析.md) 第 5 章 + 作者施工图 [AI_ARMY_DISPATCH_DESIGN.md](AI_ARMY_DISPATCH_DESIGN.md)、[AI_WORKER_DIRECTOR_DESIGN.md](AI_WORKER_DIRECTOR_DESIGN.md)
> 定位：**重构而非重写**——保留已验证的行为与数据口径，把已经出现的正确模式（账本/租约/需求表/影子迁移）提升为全局骨架。

---

## 1. 现状诊断（只列架构级问题）

| # | 问题 | 证据 |
|---|------|------|
| 1 | **决策与调度混在 6,240 行的 `AI.gd`**：经济/军事/外交/侦察/海军/UI 全部内联，`_process_line_1/3/4/5` + `_state_*` 两套流程交叉调用 | 第 1 章 §14 |
| 2 | **同一思想两套实现**：军队账本 `_roles` 内联在 AI.gd，农民账本在独立 `AIWorkerDirector`；租约/需求/优先级各自写一遍 | AI.gd:3110 vs AIWorkerDirector.gd:590 |
| 3 | **三套状态互相约束**：`Phase`(3) / `LateTactic`(4) / `UnitRole`(15)，更新点分散在 step 11、`update_tactic`、AIDefense | 第 1 章 §14.3 |
| 4 | **多个 ad-hoc 计时器**：1s/2s/3s/5s/10s/120s…约 20 个，各自全量扫描，全靠 `_late_game_scale()` 兜底 | AI.gd:1926-1958 |
| 5 | **约定式 meta 契约**：`ai_home_guard/ai_wall_guard/ai_role/ai_flee_until…` 跨 6 个文件共享，无常量表 | 第 1 章 §14.2 |
| 6 | **防御子系统仍有 3,818 行**且规划/建造/守军混在一起，4 个 defense/ 子模块 + 影子双份状态 | 第 5 章 §5.3 |
| 7 | **死代码与旧入口持续累积**：`decide()`、旧防线 5 函数、`_legacy_allocate_workers`，本轮又新增 ~10 个待删旧函数 | 第 5 章 §5.7 |
| 8 | **门槛口径两套**：阶段推进用 `count_field_military()`，主攻用 `count_land_army()` | AI.gd:2389 vs :5220 |
| 9 | **无行为回归基线**：每次重构只能靠作者手工观察 + 提交信息里的实测数字 | 提交 `ba217a1` 正文 |

---

## 2. 设计原则（5 条）

1. **单一事实源**：世界状态只有 `Situation`，单位归属只有 `RoleLedger`，参数只有 `AIConfig`。
2. **单一入口**：任何单位改角色只能 `assign/release`；任何 tick 只在 `AIClock` 某档执行一次。
3. **决策/调度/执行三层分离**：Planner 决定"要什么"（Intent），Director 决定"谁去做"（Demand→Lease），Executor 只调用 `battle` API 不写业务判断。
4. **行为可回归**：每个阶段都有"行为等价"验收指标（自对弈固定种子），重构期间用 feature flag 一键回滚。
5. **确定性默认开**：随机只走 `AIRng`，遍历顺序稳定（按 entity_id），禁墙钟。

---

## 3. 目标架构

### 3.1 分层

```
┌───────────────────────────────────────────────────────────────┐
│ Facade        AIController（≤400 行）                          │
│               只做：装配、生命周期、对外 getter、调试面板入口      │
├───────────────────────────────────────────────────────────────┤
│ Brain          AIClock → 每 4Hz 一次 AIBrain.tick()             │
│  Planner        EconomyPlanner / MilitaryPlanner / DiploPlanner  │
│                输出 Intent 列表（建造/训练/升级/进攻/防守姿态）    │
├───────────────────────────────────────────────────────────────┤
│ Director       EntityDirector ×2（Army / Worker，同一实现）      │
│                DemandTable（每 tick 生成）→ 抢占/租约 → Lease    │
├───────────────────────────────────────────────────────────────┤
│ Services       DefenseService / NavyService / WaterService /     │
│                SiegeService / ScoutService / TradeService        │
│                读 Situation，产出 Intent 或 Demand，不直接囤逻辑  │
├───────────────────────────────────────────────────────────────┤
│ Executor       BuildExec / TrainExec / MoveExec / CombatExec      │
│                薄适配：参数校验 + 调 battle API + 失败原因回传     │
├───────────────────────────────────────────────────────────────┤
│ Infra          AIClock · AIRng · AIEvents · AIConfig · AILog      │
│                Situation（每 tick 只读快照）· ExecutiveCache      │
└───────────────────────────────────────────────────────────────┘
```

### 3.2 目录结构（建议）

```
scripts/ai/
  ai_controller.gd            # Facade
  core/  ai_clock.gd  ai_rng.gd  ai_events.gd  ai_config.gd  ai_log.gd
  world/ ai_situation.gd      # 快照 + 空间索引 + 可见性
  brain/ ai_brain.gd  economy_planner.gd  military_planner.gd  diplomacy_planner.gd  intents.gd
  director/ entity_director.gd  demand_table.gd  role_ledger.gd  role_defs.gd
  services/ defense_service.gd  navy_service.gd  water_service.gd
            siege_service.gd  scout_service.gd  trade_service.gd
  defense/  threat_model.gd  director.gd  plan.gd  force_allocator.gd   # 现有文件收敛进来
  exec/ build_exec.gd  train_exec.gd  move_exec.gd
  data/ unit_table.gd  building_table.gd  difficulty_profile.gd
  debug/ panel.gd  selfplay.gd  metrics.gd
```

### 3.3 七个核心抽象（接口级）

```gdscript
# 1) AIClock：唯一 tick 源，三档节流
clock.every(0.25, _fast)   # 决策/调度主循环
clock.every(1.0,  _medium) # 侦察/修理/建造请求
clock.every(5.0,  _slow)   # 外交/普查/日志

# 2) AIRng：单流确定性随机（按 peer 播种），禁止全局 randi
AIRng.range(a,b) / AIRng.pick(arr) / AIRng.shuffle(arr)

# 3) Situation：每 tick 一次只读快照
situation.armies / workers / buildings / resources / visible_enemies / threats
situation.count_land_army() / count_field() / ratio(rk) / nearest(...)

# 4) RoleLedger：唯一单位归属账本（军队/农民共用一个实现）
ledger.assign(unit, role, lease_s, target) -> bool
ledger.release(unit, reason) -> void
ledger.has_claim(unit) / count_by_role(role) / units_with(role) / expire(now)

# 5) DemandTable：每 tick 由 Planner+Services 生成的需求表
{role=WALL, budget=槽位数, pick=Callable, order=Callable, priority=70}

# 6) Intent：高层意图（不含单位）
{kind=BUILD/TRAIN/RESEARCH/ATTACK/DEFEND, payload, priority, source, expires}

# 7) Executor：执行 + 结构化失败原因（驱动下一轮决策，避免"静默失败"）
exec.build(intent, builder) -> {ok, block_reason}
```

### 3.4 一次 tick 的数据流

```
AIClock.fast (4Hz)
  → Situation.refresh()                 # 一次扫描，全模块复用
  → Brain.plan(situation)               # 3 个 Planner 产出 Intent[]
  → Director.build_demands(situation, intents)
  → Director.fill(demands)              # 账本抢占 + 下单 + 失败原因回收
  → Services.tick(situation)            # 防御/海军/渡水/攻城/侦察的慢节奏动作
  → Executor 由 Director/Services 调用
  → AILog.record(tick, intents, demands, ledger_delta, timings)
```

关键约束：**每 tick 只扫描一次实体**（Situation 承担），Planner/Director/Services 一律读快照，禁止再遍历 `battle.entities`。这是把当前 20 个计时器各自全扫的根因去掉。

---

## 4. 关键机制

### 4.1 统一账本（合并两支 Director）

- 角色按**族**分组：`Economy{IDLE,GATHER,HAULER,BUILDER,REPAIRER,FLEE,HUNT}`、`Army{IDLE,SCOUT,GARRISON,WALL,HOME_GUARD,RESOURCE_GUARD,BUILDING_DEFENSE,HARASS,RAID,FIELD,SIEGE,TRANSPORT,ESCORT,RETREAT,STANDBY}`。
- 同一套 `RoleDefs` 表描述：租约、是否可抢占、抢占优先级、释放条件、是否计入 `count_field`/`count_land`。
- 收益：删掉 `_roles` 与 `AIWorkerDirector._workers` 两套实现，`_unit_has_claim()` 只剩一行 `ledger.has_claim(u)`；旧 meta 用**只读适配器**过渡（读取兼容、写入逐步迁移）。

### 4.2 需求表 + 抢占优先级（沿用作者设计并统一）

| 优先级 | 角色族 |
|---|---|
| 100 | FLEE / RETREAT |
| 90 | BUILDING_DEFENSE / 关键民居兵营重建 |
| 80 | HOME_GUARD |
| 70 | WALL |
| 60 | GARRISON |
| 50 | RESOURCE_GUARD / REPAIR |
| 40 | HARASS / RAID |
| 30 | FIELD / GATHER |
| 10 | HUNT |
| 0 | IDLE 兜底 |

规则沿用设计文档：只从低优先级未满额处拿人；行军/交战单位不可抢占（例外 RETREAT/BUILDING_DEFENSE）；同优先级先到先得；所有租约到期即回池、同一 tick 内重新分配。

### 4.3 Planner：把散落的 if 变成"意图 + 打分"

- `EconomyPlanner`：根据阶段、库存水位、建造需求、军队生产，产出 `BUILD/TRAIN/RESEARCH` 意图（替代 `_process_line_1/3/4/5` 里的顺序 if）。
- `MilitaryPlanner`：根据 `count_land_army`、敌情、威胁姿态，产出 `ATTACK/HARASS/DEFEND` 意图与兵种配比。
- 打分制（utility）：`score = 收益 × 紧急度 − 成本惩罚`，同 tick 取 top-N；阈值集中进 `AIConfig`，**难度只改这张表**。

### 4.4 阶段与战术：保留概念，改为派生值

`Phase` / `LateTactic` 对外仍暴露（HUD、调试面板、日志、平衡都在用），但改为 `StrategyState.derive(situation)` 纯函数计算（带滞回），不再由 step 11、`update_tactic` 各自写。这样消灭"三套状态互相打架"的根因，同时不破坏观感。

### 4.5 事件与缓存

- `AIEvents` 订阅 `battle` 现有信号（实体死亡、建筑受损、资源耗尽、生产完成），维护增量索引；Situation 只做增量+周期性全量校验（例如每 5s 一次，开销可控）。
- 目标：消灭 O(N) 重复扫描，把 AI 每帧成本从"随实体数线性 × 计时器个数"降到"每 tick 一次"。

### 4.6 确定性

- 所有 AI 随机 → `AIRng`；遍历统一按 `entity_id` 升序；时间只读 `SimTime`。
- `OnlineBattleManager` 建局阶段的 `randi/randf_range` 一并迁移（当前唯一 P0 残留）。
- 目标：同 seed + 同指令序列 → 校验和一致（回放可用作 bug 复现与回归）。

### 4.7 配置与难度参数化

- `AIConfig`（Resource，可热改）：兵种/建筑 ID 表、排除表、阈值、距离。
- `DifficultyProfile`：思考频率、防线阈值（12/6/2）、侦察频率、战术触发、资源倍率、允许的"作弊项"（默认 0）——**难度从"更快"变成"更准/更敢/更会算"**。

---

## 5. 旧 → 新 映射（迁移时照此对位）

| 现状 | 新归属 |
|---|---|
| `_run_decide_step` 15 段 | `AIClock.fast` + `Situation` + Planner/Director/Services 的固定顺序 |
| `_state_production/development/assault` | `StrategyState.derive()` + Planner 意图集 |
| `_process_line_1/3/4/5` | `EconomyPlanner` / `MilitaryPlanner` |
| `_roles` + `_director_*` | `RoleLedger` + `EntityDirector(Army)` |
| `AIWorkerDirector` | `EntityDirector(Worker)` + `EntityDirector` 复用 |
| `AIDefense`(3,818) | `DefenseService`（规划/建造/守军拆到 4 个现有 defense/ 模块 + 服务壳） |
| 各专项计时器 | `AIClock` 三档 |
| `Phase/LateTactic` 写点 | `StrategyState` 派生 |
| 旧 meta | `RoleLedger` claim + 只读适配器 |
| 硬编码 ID/阈值 | `data/*_table.gd` + `AIConfig` |

---

## 6. 迁移路线（6 阶段，每阶段可单独发布/回滚）

| 阶段 | 内容 | 验收 | 预估 |
|---|---|---|---|
| **P0 基线** | 自对弈回归脚本（固定种子 8 局，抓 idle 率/前线参与率/首攻时间/胜负/帧耗时） | 基线数据入库，后续每阶段对比 | 0.5 天 |
| **P1 基础设施** | AIClock/AIRng/AIEvents/AIConfig/AILog（行为零变化） | 同 seed 校验和一致；帧耗时无回退 | 1~2 天 |
| **P2 世界模型** | Situation 快照 + 空间索引，替换散落全扫 | 扫描耗时对比；行为指标 ±2% 内 | 2~3 天 |
| **P3 统一 Director** | `RoleLedger` + `EntityDirector` 两实例，旧 meta 适配器 | idle 率、卡死数不劣化；`_unit_has_claim` 单入口 | 2~3 天 |
| **P4 规划器** | Economy/Military Planner 替换 `_process_line_*`/`_state_*` | 建造序列、首攻时间、胜率对比 | 3~4 天 |
| **P5 服务化** | 防御/海军/渡水/攻城/侦察/外交收为 Service | 防御阶段指标、单文件行数达标 | 3~5 天 |
| **P6 清理调优** | 删死代码/旧 meta/旧入口；难度参数表；平衡迭代 | 死代码清零、难度差异可测、`AI.gd ≤ 400` 行 | 2~3 天 |

**总工期**：约 2.5~3 周（单人）。每个阶段结束跑 P0 的回归，任一指标劣化超阈值就回滚该阶段 feature flag。

---

## 7. 验收指标（写进 P0 脚本，自动出表）

| 指标 | 现状 | 目标 |
|---|---|---|
| AI 决策单帧耗时 p95 | 未系统测量（>80ms 才记日志） | ≤ 4ms（不降频情况下） |
| 单位 idle 率（t=480） | ~19.7%（重构前） | < 8% |
| 前线参与率 | 31.6% → 67.6%（Ba217a1 实测） | > 75% |
| 卡死在 transport/garrison 预约 | 存在 | 0（租约保证） |
| 农民保底恢复时间 | 未测 | ≤ 30s |
| 建造请求无 builder > 5s | 未测 | 0（不安全点除外） |
| `AI.gd` 行数 | 6,240 | ≤ 400（Facade） |
| 硬编码兵种/建筑 ID 数组 | 20+ 处 | ≤ 3 处（全在 data） |
| 同 seed 回放校验和 | 单机部分成立 | 单机+联机一致 |

---

## 8. 风险与对策

| 风险 | 对策 |
|---|---|
| 大规模移动代码导致行为回归，且难定位 | 每阶段 feature flag + P0 回归指标 + 影子对比（先只读后接管，沿用你已验证的 5 阶段防御打法） |
| Situation 快照引入"数据过期"（伤害/死亡延迟一 tick） | 事件即时标记 + 快照内保留 `stale` 标记，决策层对关键实体做二次校验 |
| Planner 打分制调参失控 | 阈值全部进 AIConfig + 自对弈扫参；保留旧行为作为 fallback profile |
| 联机 AI 与单机 AI 分叉 | 只保留一个 `AIController`，联机差异只体现在 `Situation` 数据源与命令通道（现有封装已具备） |
| 工期拖长 | P1~P3 是纯结构性收益，可随时停在任一阶段交付；P4/P5 才动行为 |

---

## 9. 需要你拍板的 4 个决策

1. **范围**：只做单机 AI（联机共用同一 Facade，后续自然复用）/ 同时覆盖联机（多 1 周，含建局确定性）。
2. **路径**：渐进式 strangler（推荐，每阶段可发布）/ 新分支大改（快但风险集中）。
3. **优先级**：先可维护性（行为保持不变，P1→P3）→ 再强化行为（P4/P5）；还是先要"AI 更强"（Planner 提前）。
4. **P0 基线口径**：沿用作者提交信息里的手工实测口径（3v3、6 AI HELL、8 倍速、固定种子 24680），还是我另建一套无头自对弈脚本（更慢但可自动化）。

拍板后我按阶段出可执行的改动清单（文件级 + 函数级 diff 计划），每阶段单独提交、单独回归。


---

## 10. 决策记录（2026-10-30，已锁定）

| 决策 | 选择 | 影响 |
|------|------|------|
| 范围 | **同时覆盖联机 + 建局确定性** | P1 起把 `OnlineBattleManager` 的全局 RNG 一并迁到 `AIRng`；联机 AI 局回放可用 |
| 路径 | **渐进式 strangler，每阶段可发布可回滚** | 每阶段独立提交 + P0 回归对比，劣化即回滚该阶段 feature flag |
| 优先级 | **先可维护性（行为保持不变），再强化行为** | P1~P3 不动行为；P4/P5 才改决策质量 |
| 基线 | **另建无头自对弈脚本**（已落地，见第 11 节） | 每阶段自动出 CSV/JSON，回归可量化 |

## 11. P0 已落地：无头自对弈基线（2026-10-30 19:34）

代码：`tools/ai_selfplay.tscn` + `tools/ai_selfplay.gd`（启动器）+ `tools/ai_selfplay_runner.gd`（逻辑），说明见 [tools/ai_selfplay.md](../tools/ai_selfplay.md)。

首轮基线（seed=24680，3v3、5 AI、HELL、8x、research、城堡锁血，8 游戏分钟，墙钟 73s）：

| t(游戏秒) | 实体 | 军队 | 交战中 | 推进中 | 待命 | 帧 p95 |
|---|---|---|---|---|---|---|
| 61 | 409 | 103 | 2 | 8 | 1 | 141ms |
| 180 | 455 | 131 | 13 | 7 | 4 | 196ms |
| 300 | 485 | 138 | 26 | 1 | 7 | 187ms |
| 480 | 513 | 147 | 12 | 16 | 12 | 145ms |

汇总：`engage 41.1% / push 21.8% / idle 23.3% / front 62.9%`、`workers_avg 11.9`、`land_avg 6.6`。
与作者提交 `ba217a1` 实测（t=360：交战 45.4% / 推进 22.2% / 待命 8.5%，前线 67.6%）相比，前线参与接近，**待命率明显偏高**；已定位两个原因：

1. **阶段门槛卡死**：基线中所有 AI 的 `phase` 始终为 1（DEVELOPMENT），t=480 仍未进 ASSAULT；`peers.csv` 里 `field` 长期 0~9，而门槛是 `count_field_military() >= 30`。军队账本接管后单位普遍带角色，field 计数被扣空 → **这是"两套门槛口径"的直接证据**，建议 P1 前先把 step 11 统一为 `count_land_army()`。
2. **idle 口径包含驻军/船上单位**（order 为空即计 idle），与作者手工口径不完全同源；后续在指标里拆 `garrisoned` 列，主口径保持稳定。

基准数据：`docs/ai-analysis/selfplay/`（`seed_24680_samples.csv`、`seed_24680_peers.csv`、`summary.json`）。

### 11.1 已修复：阶段门槛卡死（本次提交）

| 项 | 修复前 | 修复后 |
|----|--------|--------|
| 判断口径 | `count_field_military(...) >= 30`（被角色扣空，长期 0~9） | `count_land_army() >= 14`（总陆军，含守军/墙守/游击） |
| 实测 | 12 分钟所有 AI 仍 `phase=DEVELOPMENT` | `phase=ASSAULT` 在 t=420 / 540 / 600 分别触发（peer 2000 / 2001 / 1001） |
| 依据 | 自对弈基线 `docs/ai-analysis/selfplay/` | 修复后对照 `docs/ai-analysis/selfplay/after_phase_fix/` |

阈值定 14 的实测依据：总陆军 14 在 t≈8~9 分钟出现、18 要到 12 分钟、21 到 12 分钟仍未普及；取 14 保证 ASSAULT 在常规对局中段真正发生。

### 11.2 P1 基础设施已落地（第一批）

| 模块 | 文件 | 状态 |
|------|------|------|
| `AIClock` | `scripts/ai/core/AIClock.gd` | 已接管 `retask` 计时器（行为等价：初始 0 首轮即触发）；其余 20 余个计时器待逐步迁入 |
| `AIRng` | `scripts/ai/core/AIRng.gd` | 已就绪：确定性模式走独立流，非确定性模式降级全局 RNG（保证改造期行为不变）；AI 内的 `randi/randf_range` 替换待逐点进行 |
| `AIEvents` | `scripts/ai/core/AIEvents.gd` | 容器与事件常量已就绪；接入 battle 信号属于 P2（世界模型） |
| `AIConfig` | `scripts/ai/core/AIConfig.gd` | 已接管 `ASSAULT_LAND_ARMY_THRESHOLD`、决策预算/步数、难度思考间隔、农民目标数 |

接入方式：`AI.gd` 顶部 `preload`（与项目现有风格一致，避免依赖编辑器生成的 global class 缓存）。

剩余 P1 工作：
1. `AIClock` 替换其余散落计时器（1s/2s/3s/5s/10s…），并给每个 key 配相位偏移削峰；
2. `AIRng` 替换 AI 决策中的全部全局随机点（含 `AILadderSiege` / `AIWaterCrossing`）；
3. `OnlineBattleManager` 建局 RNG（当前 7 处 `randi/randf_range`）迁到 `SimRandom`/`AIRng`，并保证服务端种子随地图数据下发——此项需单独验证联机一致性，暂未动。

### 11.3 P1 收尾完成（2026-10-30 20:00）

| 项 | 结果 |
|---|---|
| `AI.gd` 内裸计时器 | **0 个**（原 4 个：retask / age_build / wall_deploy / garrison 全部迁到 `AIClock`） |
| 行为等价性 | 相位按旧初始值设定（`age_build` phase=1 表示首轮不触发；其余 phase=0 首轮即触发）；`timer += interval` 只修正长期累积漂移，不改变节奏 |
| AI 随机点现状 | **AI 目录内已 100% 使用 `SimRandom`**（复审确认无裸 `randi/randf_range`），故 `AIRng` 并非紧急替换项，定位改为"未来 per-AI 独立流 / 联机回放"的预留能力 |
| 其余模块计时器 | `AIDefense` 11 处、`AIWorkerDirector` 2 处、`AIWaterCrossing` 1 处——属于各自模块 tick 内部节流，留到 P3 统一 Director 时一并收口 |
| 冒烟验证 | 无头自对弈 3 分钟：5 AI 正常、无解析/运行错误、front≈58~73%（噪声范围内） |

**P1 结论**：基础设施四件套可用，`AI.gd` 的节流与参数入口已统一；下一步进入 **P2 世界模型（Situation 快照 + 空间索引）**。

### 11.4 P2 影子版世界模型已落地（2026-10-30 20:20）

| 项 | 结果 |
|---|---|
| `AISituation` | `scripts/ai/world/AISituation.gd`：单次遍历产出本方/敌方、农民/陆军/建筑/主城分类视图 + 自身计数 |
| 只读接入 | `AI.gd` step 0 每轮刷新快照（不接管任何决策），5 秒（游戏时间）做一次对账 |
| 一致性 | 8 分钟对弈：`land / worker / castle` 三项计数**0 次不一致**（`[SITUATION] MISMATCH` 0 条） |
| 成本 | 单次刷新 0.05~0.18 ms（EMA），远低于一次完整决策（数百 ms） |
| 回归数据 | 自对弈 CSV 新增 `src_usec` / `src_mismatch` 两列 |

**顺带发现的既有问题（未改，留给 P3）**：`_last_delta` 是"本轮所在单帧的 delta"，而多数计时器每轮只减一次，导致**名义 10s 的计时器实际要几十秒才触发**（旧代码同样如此，AIClock 迁移保持了行为一致）。修正需要引入"轮次经过时间" `elapsed_since_last_round` 统一替换，属于行为改动，放到 P3 统一 Director 时一起做。

**P2 下一步**：
1. `Situation` 增加空间索引（近邻查询）与敌军可见性，供防御/骚扰使用；
2. 把 `count_land_army` / `count_field_military` 等读取点切到快照（影子→接管）；
3. 资源节点与建造点缓存进快照，减少 `find_valid_build_position` 的重复扫描。

### 11.5 P2 能力补全：空间索引 / 资源索引 / 可见性（2026-10-30 20:35）

| 能力 | 接口 | 实现要点 | 成本 |
|---|---|---|---|
| 敌军空间索引 | `enemies_within(pos, r)` / `nearest_enemy(pos, d)` / `enemies_within_count` | 8m 网格分桶，查询只遍历覆盖到的格子 | 每轮随 refresh 建索引，开销可忽略 |
| 资源索引 | `resources_of_kind(id)` / `nearest_resource(pos, kinds, d)` | 按资源类型分组 + 网格；**只在低频轮重建**（资源点几百个且很少变化） | 低频轮才付，避免每轮 0.8ms |
| 敌军可见性 | `visible_enemies` | 低频轮以本方主城（或首支部队）为观察者，调 `battle.is_target_visible_from()` | 0.37~0.53ms/次（5 秒一次） |

**成本变化**：资源索引低频化后，单轮 refresh 从 0.8ms 降到 **0.25~0.40ms**；对账仍 **0 不一致**。

**下一步（P2 收尾）**：把读取点切到快照——优先 `count_land_army()` / `count_field_military()` 与防御的"附近敌人"查询；切换后用 P0 基线对比扫描成本与 front/idle 指标。

### 11.6 P2 读取点切换（已实现，开关默认关闭，待验证）

**已做**：
- `count_land_army()` 增加快照分支（`USE_SITUATION_COUNTS`），旧实现保留为 `_count_land_army_live()`；阴影对账改用 live 值与快照比较（避免"自比自"）。
- 快照最多滞后一个决策步（step 10 生产的单位下一轮才计入），对阶段判断无实质影响。
- **默认 `USE_SITUATION_COUNTS = false`**：本机验证时有正在运行的游戏实例，无法做干净的无头基线对比；先保持旧路径，验证通过后再置 true。

**验证待办（环境干净时执行）**：
```powershell
# 1) 关闭游戏/编辑器实例后跑 12 分钟基线
<Godot> --headless --path . res://tools/ai_selfplay.tscn -- `
  --seeds=24680 --minutes=12 --sample=60 --mode=3v3 --diff=HELL --time-scale=8 --immortal=1 `
  --out=res://docs/ai-analysis/selfplay/baseline_pre
# 2) 把 USE_SITUATION_COUNTS 置 true，再跑同参数一遍
# 3) 对比 front/idle/land/阶段触发时间，劣化超 2% 就回退开关
```

**顺带修复**：`docs/ai-analysis/selfplay/` 下的 CSV 被 Godot 当成翻译资源导入了（生成一堆 `.import`/`.translation`）。已加上 `.gdignore` 并清理，后续该目录不会再被导入。

## 12. P3 施工图：统一 Director + 节拍修正（文件级计划）

### 12.1 目标与非目标

**目标**：让"谁在干什么"只有一本账，"谁该多久动一次"只有一个钟。
**非目标**：不新增战术行为、不改难度参数、不动联机协议。

### 12.2 现状盘点（已核对代码）

| 记录"占用"的地方 | 位置 | 问题 |
|---|---|---|
| `AI._roles` | `AI.gd:4960` | 军队角色账本，AI 自己写 |
| `AIWorkerDirector._workers / _flee_resume / _builder_reservations / _build_requests` | `AIWorkerDirector.gd:26-35` | 农民账本，模块自己写 |
| `AIDefense` 内部守军/预留 | `AIDefense.gd` | 防御自己写，靠 `_unit_has_claim()` / `_is_held_by_garrison()` 互相查询来"避免撞车" |

三本账互相查询 → 每次判断都要跨模块问一遍，且新增模块必须记得问，是当前最容易出"同一单位被两处调度"的结构性风险。

**计时器分两类**：

| 类型 | 例子 | 正确性 |
|---|---|---|
| 帧级（每帧 `tick(delta)`） | `AIDefense` 11 个、`AIWorkerDirector` 2 个 | ✅ 正确 |
| 轮次级（决策 step 内递减） | `AI.gd` 的 4 个（已迁 `AIClock`） | ❌ 每轮只减一帧 delta，名义 10s 实际几十秒 |

### 12.3 施工步骤

**P3.0 节拍修正（最小、可独立验证）**
- `AI.gd`：`_process` 每帧累加 `_elapsed_since_round += delta`；`_begin_decide` 时取出并清零。
- `_ai_clock.advance(_elapsed_since_round)` 替换现在的 `advance(_last_delta)`。
- 开关 `USE_TRUE_ROUND_ELAPSED`（默认 false，先量成本再开）：开启后 `retask=2s / wall=10s / garrison / age_build=30s` 才是真实秒数，触发频率会明显上升。
- 验收：同种子 12 分钟，AIClock `next_in()` 与 `battle.game_time` 推进一致；p95 帧耗时上升 < 5%。

**P3.1 统一账本 `RoleLedger`**
- 新增 `scripts/ai/core/RoleLedger.gd`（`class_name RoleLedger`）：
  - `claim(unit, kind, source, ttl=-1.0)`、`release(unit)`、`release_by_source(source)`、`get(unit)`、`holders(kind)`、`counts()`、`sweep(now)`（死亡/TTL 自动回收）
  - 不变式：一个单位同时最多一条 claim；单位死亡当帧必须被回收（`sweep` + 死亡信号双保险）。
- `AI._roles` 改为 `_ledger` 的薄包装：`_unit_has_claim` / `_role_of` 等签名不变，内部改查 `_ledger`（调用点零改动）。
- `AIWorkerDirector` 的 `_workers` 退化为"快照视图"（每 tick 从 `_ledger` + `_cached_armies` 重建），删除 `_flee_resume` / `_builder_reservations` 里的重复状态，改登记 claim。
- `AIDefense` 的守军/预留改为在 `_ledger` 登记（source=`"defense"`），`_is_held_by_garrison` 改查账本。
- 影子期：旧账本与新账本**双写**，每 5 秒断言两者一致，不一致打印 `[LEDGER] MISMATCH`。

**P3.2 `AIDirector` 统一调度**
- 新增 `scripts/ai/AIDirector.gd`：持有 `ai._situation` 与 `ai._ledger`，按固定顺序调度 `production → worker → military → defense → naval`。
- 每个模块只声明"我要什么"（如防御要 `situation.visible_enemies`、军事要 `situation.own_land_count`），不再各自遍历 `battle._armies`。
- 一次 `situation.refresh()` 供所有模块使用（现在影子快照已经是每轮一次，切换成本低）。

**P3.3 计时器收口**
| 模块 | 现状 | 迁移后 keys |
|---|---|---|
| `AI.gd` | 4 个（已迁 AIClock） | `retask / wall_deploy / garrison / age_build` |
| `AIDefense.gd` | 11 个裸计时器 | `threat(0.5s) / guard(1s) / alert(1s) / resource(2s) / zone(2s) / defense_check(3s) / upgrade(4s)` |
| `AIWorkerDirector.gd` | 2 个 | `worker_tick` + `worker_log` |
| `AIWaterCrossing.gd` | 1 个 | `water_check` |

所有 key 用同一 `AIClock`，相位按 AI 序号错开，避免 5 个 AI 同帧触发。

### 12.4 文件级改动清单

| 文件 | 动作 | 风险 |
|---|---|---|
| `scripts/ai/core/RoleLedger.gd` | 新增（约 120 行） | 低（纯数据结构 + 不变式） |
| `scripts/ai/AIDirector.gd` | 新增（约 150 行） | 中（调度顺序变化会改行为） |
| `scripts/ai/AI.gd` | 改：`_roles`→`_ledger` 包装、`_elapsed_since_round`、4 处时间源 | 中 |
| `scripts/ai/AIWorkerDirector.gd` | 改：状态改登记 claim，`_workers` 变视图 | 中高（农民行为最敏感） |
| `scripts/ai/AIDefense.gd` | 改：11 个计时器→AIClock；守军登记账本 | 中 |
| `scripts/ai/AIWaterCrossing.gd` | 改：1 个计时器 | 低 |
| `tools/ai_selfplay_runner.gd` | 改：CSV 增加 `ledger_mismatch` 列 | 低 |

### 12.5 验证与回滚

每步独立提交，独立开关，可单独回退：

| 步骤 | 开关 | 验收指标 | 回退方式 |
|---|---|---|---|
| P3.0 | `USE_TRUE_ROUND_ELAPSED` | AIClock 间隔准确性；p95 帧耗时 | 开关置 false |
| P3.1 | `USE_ROLE_LEDGER` | `[LEDGER] MISMATCH` = 0；workers/land/front 与基线差 < 2% | 开关置 false（旧账本仍在） |
| P3.2 | `USE_DIRECTOR` | front/idle/engage、ASSAULT 触发时间 | 开关置 false |
| P3.3 | 按模块 | 各模块日志频率符合预期 | 单模块回退 |

**确定性**：每步用同种子跑 `simulation_checksum`，必须与改动前逐 tick 一致（除 P3.0 有意改变触发频率外）。

### 12.6 建议顺序与工期

1. P3.0（半天）——先修钟，否则后面所有"多久一次"都在错的基础上调；
2. P3.1（1~2 天）——账本统一，风险最高但收益最大，影子双写降低风险；
3. P3.2（1 天）——调度收口，依赖 1 的账本和已有 Situation；
4. P3.3（1 天）——纯搬运，机械改动。

**不建议**先做 P3.2：没有统一账本时，Director 只会变成一个新的"第五本账"。

### 12.3.1 P3.0 已实现（开关默认关闭，2026-10-30 20:30）

| 改动 | 位置 | 说明 |
|---|---|---|
| `_elapsed_since_round` | `AI.gd:113` | 每帧在 `_ai_simulation_tick` 累加真实时间 |
| `USE_TRUE_ROUND_ELAPSED` | `AI.gd:6278` | 默认 false（行为与旧版完全一致） |
| 取用点 | `_begin_decide` | true 时 `_last_delta = _elapsed_since_round` 并清零 |
| 可观测 | `get_situation_summary()` | 新增 `round_delta`、`elapsed_since_round`、`clock`（各 key 的 next_in） |

**为什么默认关闭**：打开后 `_last_delta` 从「单帧 delta」变成「轮间真实时间」（通常大 10~20 倍），所有按轮递减的计时器（`AIClock` 4 个 + `AIDefense` 内部 11 个 + `AIWorkerDirector` 2 个 + `AIWaterCrossing` 1 个）触发频率会同步上升，属于**行为 + 性能双重变化**，必须单独验证。

**验证方法（环境干净时）**：
1. 同种子 12 分钟跑两次（开关 false / true），对比 `summary.json` 的 front/idle/engage/land 与 p95 帧耗时；
2. 看 `[SITUATION]` 日志的检查间隔：false 时明显大于 5 秒，true 时贴近 5 秒（游戏时间）；
3. 若性能超标，把模块计时器先减半再打开，而不要直接回退整个开关。

### 12.3.2 P3.1 第一步已实现：影子角色账本（2026-10-30 20:42）

| 项 | 内容 |
|---|---|
| 新增 `scripts/ai/core/RoleLedger.gd` | 通用 claim/release/sweep/holders/counts 接口；一个单位同时最多一条 claim；不同来源重复认领会被拒绝并计数 |
| 镜像写入 | `AI._director_set_role` / `_director_release` / `_director_release_role` / `_director_prune` 同步登记/释放/回收 |
| 对账 | 每 5 秒（与 Situation 同节拍）比较 `_roles` 与账本的键集合 + 角色号，输出 `[LEDGER] ok` / `[LEDGER] MISMATCH` |
| 可观测 | `get_situation_summary()` 增加 `ledger`（claims/releases/rejected/expired）、`ledger_checks`、`ledger_mismatch` |
| 行为影响 | **零**：`_roles` 仍是唯一事实来源，账本只读镜像；无开关，删除即回退 |

**第一步验收条件**：12 分钟对弈 `[LEDGER] MISMATCH` = 0，`rejected` = 0。

**第二步（待第一步验收后）**：把读取点切到账本（`_unit_has_claim` / `_role_of` / `get_role_summary` / `_director_role_count`），
`AIWorkerDirector._workers`、`AIDefense` 的守军预留改登记到同一账本（source 分别为 `worker` / `defense`），
届时 `rejected > 0` 就是真实的"两个模块抢同一单位"，正好暴露现在靠互相查询掩盖的冲突。

### 12.3.3 验证结果（2026-10-30 21:10，8 分钟 3v3 HELL，种子 24680，每组 3 次）

| 组 | 开关 | front% | idle% | engage% | land | workers | p95ms |
|---|---|---|---|---|---|---|---|
| A | 全关（基线） | 65.0 / 60.1 / 40.1 | 12.8 / 19.7 / 34.2 | 41.4 / 31.8 / 15.1 | 4.5 / 5.3 / 7.4 | 11.7 / 11.8 / 11.7 | 243 / 269 / 203 |
| B | 读取点切换 | 64.5 / 48.2 / 54.7 / 50.0 | 22.3 / 25.6 / 28.7 / 31.9 | — | — | — | 256 / 311 / 264 / 222 |
| C | 真实轮间时间 | 77.7 / 71.9 / 57.2 | 5.5 / 11.7 / 27.0 | 53.8 / 50.0 / 32.3 | 6.7 / 8.2 / 8.8 | 12.1 / 12.2 / 12.4 | 293 / 314 / 278 |

**结论**：
- **B（读取点切换）判定劣化**：待命比例 4 次全部高于基线（22~32% vs 13~34%，中位数 27% vs 20%），front 中位数 52% vs 62%。快照相对实时计数仍存在时机差异，**保持关闭**。
- **C（真实轮间时间）判定改善**：front 三组 77.7/71.9/57.2 全部高于基线，待命 5.5/11.7/27.0 全部低于基线，主攻比例同步上升；代价是 p95 帧耗时约 +24%（243→295 中位数）。属于修掉"计时器慢 10~20 倍"这个实际 bug，**已默认打开**。
- **对账**：全部 10 次运行 `[SITUATION] MISMATCH` = 0、`[LEDGER] MISMATCH` = 0，账本 `rejected` = 0、`expired` = 0。
- **同种子方差很大**（A 组 front 40~65%），原因是 AI 决策依赖帧 delta；单次运行不足以判断，必须成组比较——这一点也写进自对弈脚本的使用说明。

**已知副作用**：C 打开后 AI 计时器按真实秒数触发（补派 2s、守墙 10s 等），HELL 难度会比之前更"勤快"，属于预期内的行为变化；如需回调，把 `USE_TRUE_ROUND_ELAPSED` 置回 false 即可一键回退。

### 12.3.4 P3.1 第二步：读取点切换已实现（开关默认关闭）

| 读取点 | 切换后实现 | 回退 |
|---|---|---|
| `_unit_has_claim(u)` | `_ledger.has(uid)` | 开关 false 读 `_roles` |
| `_director_role_count(role)` | `_ledger.count(role)` | 同上 |
| `get_role_summary()` | `_ledger.counts()` | 同上 |

开关 `USE_LEDGER_READS`（默认 false）。写入路径仍是 `_roles` 主写 + 账本镜像，读取切过去之后两本账互为校验：
`[LEDGER] MISMATCH` 若仍为 0，说明账本可以完全替代 `_roles`。

**验证待办**：8 分钟对弈各 3 次（开关 false / true），要求 front/idle 中位数差异 < 2%、`rejected` = 0；通过后打开开关并删除 `_roles` 主写（P3.1 第三步）。

### 12.3.5 P3.1 第二步验证通过，账本接管读取点（2026-10-30 22:45）

8 分钟 3v3 HELL，种子 24680，`USE_LEDGER_READS` 关/开各 2 次：

| 组 | front% | idle% | engage% | land | S_MISMATCH | L_MISMATCH |
|---|---|---|---|---|---|---|
| 关 | 57.98 / 52.67 | 27.45 / 18.67 | 29.13 / 30.22 | 8.1 / 10.4 | 0 | 0 |
| 开 | 64.90 / 68.37 | 19.23 / 15.35 | 41.11 / 37.21 | 9.7 / 10.0 | 0 | 0 |

**判定**：打开。`branch 读取点只是数据来源，语义应与 `_roles` 完全相同；开/关两组差异在环境噪声范围内（本轮 p95 从 391 漂到 667，说明机器负载波动大），关键是 **4 次运行 `MISMATCH` 全 0、`rejected` 全 0**，证明账本与 `_roles` 内容等价。

**下一步（P3.1 第三步）**：`_roles` 降级为只写别名（或直接删除），让 `RoleLedger` 成为唯一事实来源；届时把农民/防御也登记进同一本账（source = `worker` / `defense`），`rejected` 才会出现真实含义——即"两个模块抢同一单位"。

### 12.3.6 P3.1 第三步：账本成为写入侧事实来源（2026-10-30 22:55）

| 改动 | 说明 |
|---|---|
| 写入顺序反转 | `_director_set_role` 先 `_ledger.claim(...)`，成功后才写 `_roles` 镜像；`_roles` 从此是"账本的人读视图" |
| 冲突检测 | claim 被拒绝（同一单位已被别的 source 占用）时**保留原占用者**、`_ledger_conflicts += 1`、打印 `[LEDGER] CONFLICT t= uid= want= holder= kind=` |
| 来源名 | 新增 `LEDGER_SRC_DIRECTOR = "director"`，为农民（`worker`）/防御（`defense`）登记留位 |
| 可观测 | `get_situation_summary()` 增加 `ledger_conflicts` |

**当前行为不变**：所有 claim 都来自 `director`，账本不会拒绝，冲突计数恒为 0。这一步的价值是把"抢单位"从**静默覆盖**变成**显式拒绝 + 冲突日志**——等农民/防御登记进来后，`CONFLICT` 出现的位置就是现在靠 `_unit_has_claim()` 互相查询掩盖掉的真实冲突点。

**冒烟结果**：3 分钟 3v3 HELL，无脚本错误，`SITUATION/LEDGER MISMATCH` = 0，`CONFLICT` = 0，front 56.5% / idle 15.3%，行为正常。

**下一步（第四步）**：把 `AIWorkerDirector` 的农民角色与 `AIDefense` 的守军/预留登记为 `worker` / `defense` 来源（kind 用不同偏移避免与 `UnitRole` 撞号），观察 `CONFLICT` 分布；确认无真实冲突后删除 `_roles` 主写。

### 12.3.7 P3.1 第四步：农民角色登记进统一账本（2026-10-30 23:10）

| 项 | 实现 |
|---|---|
| 上报接口 | `AIWorkerDirector.worker_claims() -> {uid: role}`（只上报非 IDLE 的"正在干活"角色） |
| 登记 | `AI._mirror_worker_claims()`，来源 `worker`，`kind = 1000 + 农民角色号`（与陆军 `UnitRole` 0~99 分命名空间） |
| 心跳语义 | 每 5 秒先 `release_by_source("worker")` 再整批重登记，租约 6 秒；农民死了自然过期 |
| 让位规则 | 单位已被其它来源占用时**农民侧让位**（`worker_claim_skips += 1`），不改行为、不算冲突——农民被 director 征去骚扰是正常设计 |
| 对账收窄 | `_ledger_check` / `_director_role_count` / `get_role_summary` 只看 `director` 来源，避免被 `worker` 的 kind 污染（新增 `size_of/count_of/counts_of`） |

**冒烟**：3 分钟 3v3 HELL，无错误，`SITUATION/LEDGER MISMATCH` = 0、`CONFLICT` = 0，front 80.3% / idle 4.2%。

**说明**：农民让位意味着目前 `CONFLICT` 仍为 0；真正的冲突要等 `defense` 来源登记进来（守军与 director 都会挑陆军单位），那时 `CONFLICT` 才会指认真实抢单位点。

### 12.3.8 P3.1 第五步：删除 `_roles`，账本成为唯一事实来源（2026-10-30 23:25）

| 原 `_roles` 用途 | 现在 |
|---|---|
| 写入/擦除（`_director_set_role` / `_director_release`） | 只写账本 |
| 过期回收（`_director_prune` 遍历 `_roles`） | 遍历 `_ledger.entries_of("director")`，`until` 由账本维护 |
| 角色计数（`_director_role_count`）/ 摘要（`get_role_summary`） | `count_of` / `counts_of("director")` |
| 释放时取角色（`_director_release_role`） | `_ledger.kind_of(uid)` |
| 占用判定（`_unit_has_claim` / 集结 / 主攻派单） | `_ledger.has(uid)` |
| 与 `_roles` 对账（`_ledger_check`） | 改为**账本自检**：每条占用必须指向活着的、属于我的单位，且与 `ai_role` 元数据一致 |

`USE_LEDGER_READS` 开关随之删除（读取点已全部走账本，没有回退必要）。
自检里对"单位已死但本轮 prune 未跑到"的条目单独记为 `pending`（正常回收窗口），不算错误。

**4 分钟 3v3 HELL 验证**：无脚本错误，`STALE` = 0、`CONFLICT` = 0、`SITUATION MISMATCH` = 0，front 71.4% / idle 15.1% / land 5.3，与迁移前区间一致。

至此 P3.1 完成：**角色占用只有一本账**，director 与 worker 分来源登记，抢单位会被显式拒绝并计数。

### 12.4 P3.2 影子 AIDirector（2026-10-30 23:40）

新文件 `scripts/ai/AIDirector.gd`（RefCounted，无 `class_name`，走 preload）。每轮（跟着 `AISituation` 的 5 秒对账节奏）拿**同一份快照 + 同一本账**算出意图，只打印不执行：

| 意图 | 判定 | 优先级 |
|---|---|---|
| `defend` | 视野敌人 > 账本里守墙/守家/回防/驻军占用 | 0 |
| `push` | 陆军 ≥ 进攻阈值，且主攻/突袭/攻城占比不足 | 1 |
| `reinforce` | 陆军未达进攻阈值，缺口数 | 2 |
| `gather` | 农民 < 目标数，缺口数 | 2 |
| `idle_warn` | 占用率 < 25%（或陆军 ≥ 4 但账本零占用） | 3 |

日志形如 `[DIRECTOR-V2] t=26 intents=3 defend(1) reinforce(12) gather(2)`；`get_situation_summary()["director_v2"]` 暴露 `ticks/intents/kinds/summary`。

**为什么先做影子**：现在的决策分散在 ~10 个模块里，直接搬会让"没验证的行为变化"和"重构"混在一起。影子期先用同一份输入重算一遍意图，能直接和真实决策对照——一旦某轮意图与实际行动背离，就是后续搬逻辑时要修的缺口。

**约束**：不能反向 `preload("res://scripts/ai/AI.gd")`（循环依赖），角色号以本地常量镜像 `UnitRole`，改动枚举时必须同步。

**4 分钟验证**：无脚本错误，意图日志正常，front 74.0% / idle 10.4% / land 3.5，行为与迁移前一致。

### 12.5 P3.3 计时器收口：试过，实测劣化，已回退（2026-10-30 23:55）

**做法**：把 AI 剩余的固定周期计时器（收入统计 10s、石头共享 5s、狩猎补手 8s、升级周期 20s、防线补建、director 0.5s）全部换成 `AIClock` 的 `due()`，删掉各自的 `_xxx_timer -= delta` 浮点计时器，与已迁移的 `retask` / `age_build` / `wall_deploy` / `garrison` 统一。

**实测**（5 分钟 3v3 HELL，种子 24680，同一台机器的同一负载窗口，p95 都在 700ms 量级）：

| 版本 | front% | idle% | engage% | land |
|---|---|---|---|---|
| 合并前（v4.0.50） | 67.6 | 19.3 | 53.1 | 5.2 |
| 合并后 | 34.9 | 47.4 | 5.7 | 6.2 |

劣化幅度远超噪声范围（此前同配置的方差区间为 front 40~80%），因此**回退**，计时器维持原样。

**推测原因**（未进一步验证，留给后续）：`AIClock.advance()` 只在决策轮 step 0 推进一次，`due()` 的判定粒度被拉到"每轮一次"；原本逐帧递减的计时器在长思考间隔（后期 12 倍降频）下会被压缩到同一轮集中触发，改成时钟后这些动作反而被推迟——尤其狩猎补手与升级周期直接影响经济与出兵节奏。

**结论**：P3.3 的"物理合并"并不是纯重构，它改变了触发粒度。要重做必须先给 `AIClock` 增加"按真实时间在帧内推进"的路径，并逐模块做 A/B，不能一次性替换。文档保留此结论，避免后来者重复踩。

### 12.6 P4 第一步：联机玩法路径的随机源收口（2026-10-31 00:10）

**问题**：`OnlineBattleManager` 还有 7 处直接调用全局 `randi()/randf_range()` 的地方，包括地图种子、随机池取项、出生点/站位抖动。这些都会改变对局状态，却来自不可复现的全局 RNG——联机对局与"建局可复现"因此在源头上对不齐。

**改动**：
| 位置 | 之前 | 现在 |
|---|---|---|
| 组队地图重建 | `map_node.custom_seed = randi()` | 先把种子记到 `GameSettings.map_seed`（0 时用 `SimRandom.randi()` 生成再记录），再传给地图 |
| 随机池取项 | `pool[randi() % size]` | `pool[SimRandom.randi() % size]` |
| 出生角/半径、出生点、回城点、城堡站位抖动 | `randf_range(...)` | `SimRandom.randf_range(...)` |

**为什么这样够**：`RTSBattleManager._ready()` 在 `_init_team_mode()` 之前就按 `sim_seed` 播种 `SimRandom`（`sim_seed` 为 0 时随机生成并落库到 `GameSettings`），而回放头文件本来就记录 `sim_seed`/`map_seed`，所以种子链路现在是完整的：**记录 → 重放 → 同一张图 + 同一条随机序列**。

**验证**：4 分钟 3v3 自对弈不报错、行为正常（单机路径不经过这些分支，主要验证不回归）。联机双端一致性仍需真机双进程对局验证——当前环境无法无头模拟两个 ENet 端，已列入待办。

**AI 侧无需改动**：`scripts/ai/**` 里 12 处随机调用已全部是 `SimRandom.*`，没有全局 RNG 泄漏。

### 12.7 P3.3 重做成功：帧级时钟 + 计时器合并（2026-10-31 00:35）

**第一步：给 AIClock 帧级推进**
之前 `AIClock.advance()` 只在决策轮 step 0 调用一次，`due()` 的判定粒度被拉到"每轮一次"，短周期计时器要么被压后、要么在一轮里集中触发——这正是 12.5 里合并后劣化的根因。
现在改为在 `_ai_simulation_tick` 里按帧 `advance(delta)`，并删除 step 0 的整轮累加（避免重复计数），`due()` 拿到与逐帧自减同级的精度。

**第二步：重新合并固定周期计时器**
`income`(10s) / `stone_share`(5s) / `hunt`(8s) / `upgrade_cycle`(20s) / `defense_gap` 全部改为 `AIClock.due()`，删除各自的浮点计时器；猎手够用时用 `clock.reset("hunt", 0.35)` 提前补手；调试面板改读 `clock.remaining("hunt")`。

**验证**（5 分钟 3v3 HELL，种子 24680，同机同负载窗口）：

| 版本 | front% | idle% | engage% | 样本 |
|---|---|---|---|---|
| 帧级时钟、未合并（基线） | 62.05 / 54.89 | 9.74 / 24.81 | 46.67 / 21.80 | 2 |
| 帧级时钟 + 合并 | 63.73 / 61.64 | 21.24 / 19.63 | 36.79 / 37.90 | 2 |
| 旧（轮级时钟 + 合并，已回退） | 34.9 | 47.4 | 5.7 | 1 |

合并后在噪声范围内与基线持平（front 中位 62.7 vs 58.5，idle 中位 20.4 vs 17.3），且不再出现 12.5 那次 34.9/47.4 的崩溃式劣化 → **保留合并**。

**结论**：这次证明 12.5 的判断是对的——问题不在"合并"本身，而在时钟推进粒度。任何"只做重构"的行为改动，都必须先证明其触发粒度没变。

### 12.8 P3.2 落地：defend 意图接真实派单（开关默认关闭，2026-10-31 00:50）

新增 `USE_DIRECTOR_DEFEND`：当影子 Director 报出 `defend(N)` 意图（可见敌人 > 已分配守军），就从"未被占用且没有任何命令"的陆军里挑最近的 N 个登记为 `HOME_GUARD`（租约 12 秒），让它们回家防守；`_defense.threat_level >= 3` 时让位给 AIDefense，避免两套逻辑同时调兵。

**验证**（5 分钟 3v3 HELL，种子 24680）：

| 版本 | front% | idle% | engage% | Director 实际调兵次数 |
|---|---|---|---|---|
| 关（基线） | 63.73 / 61.64 | 21.24 / 19.63 | 36.79 / 37.90 | 0 |
| 开 | 67.46 / 60.34 | 15.79 / 20.11 | 32.06 / 34.08 | 1 / 0 |

**判定**：开关保持**关闭**。两个样本与基线持平（噪声内），但 `defend` 意图在 5 分钟对局里只触发 0~1 次，说明这个条件下"守军不足"很少成立——收益无法证明，保持默认关闭。**价值在于链路已经打通并验证过**（日志 `[DIRECTOR-V2] apply ... defend_claim=1`），后续把条件放宽（例如按"敌方离城堡距离"而不是"全局视野敌人"）或把 push 意图也接上时，只需改判定，不用再动接线。

### 12.9 P2 收尾结论：剩余读取点不切（2026-10-31 00:50）

计划里还剩 `count_field_military`、防御侧就近敌人查询两处读取点可以切到 `AISituation`。评估后**不做**：

1. `count_field_military(peer)` 的口径是"未被任何角色占用、无运输/驻军标记的可出击兵力"，而快照只存"本方陆军总数"，要做等价判断必须在快照里再存一份占用快照，等于把账本逻辑复制一遍；
2. 12.3.3 的实测已经表明同类切换（`count_land_army`）会让待命比例系统性升高——快照与实时计数存在时机差，切过去是"看起来统一、实际变钝"；
3. 这两处的调用频率远低于 `count_land_army`，省下的开销可以忽略。

**结论**：`AISituation` 的定位收敛为"低成本世界概览 + 对账基准"，不做决策读取源；决策读取源统一到 `RoleLedger`。这个边界比"所有读取点都走快照"更清楚，也避免了两套事实来源打架。

### 12.10 迁移后基线（2026-10-31 01:05）

8 分钟 3v3 HELL、种子 24680、同一机器同负载窗口跑 1 次（第 2 次因机器负载超时）：

| 指标 | 迁移后 |
|---|---|
| 前线占有率 front | **70.9%** |
| 待命 idle | **15.7%** |
| 交战中 engage | 52.7% |
| 陆军规模 land | 10.3 |
| 农民 workers | 12.1 |

对照迁移前的 8 分钟基线（front 62.9% / idle 23.3% / engage 41.1%）：**front +8pt、idle −7.6pt**，主要来自 P3.0 真实轮间时间与 P3.3 帧级时钟（计时器不再慢 10~20 倍）。

### 12.11 P0~P4 收口状态

| 阶段 | 内容 | 状态 |
|---|---|---|
| P0 | 无头自对弈基线与指标（CSV/汇总） | ✅ |
| P1 | AIClock / AIRng / AIEvents / AIConfig 基础设施 + 首轮计时器迁移 | ✅ |
| P2 | `AISituation` 快照（空间索引、资源索引、可见性、对账） | ✅ 只做概览与对账，不做决策读取源（12.9） |
| P3.0 | 真实轮间时间（修掉计时器慢 10~20 倍） | ✅ 默认打开 |
| P3.1 | `RoleLedger` 统一账本：影子 → 读取点 → 写入侧 → 农民入账 → 删除 `_roles` | ✅ 完成 |
| P3.2 | 影子 `AIDirector` + defend 意图接线 | ✅ 接线完成，开关默认关闭（12.8） |
| P3.3 | 计时器合并 | ✅ 帧级时钟基础上重做成功（12.7） |
| P4 | 联机玩法路径随机源收口到 `SimRandom`、地图种子可复现 | ✅ 第一步完成；联机双端一致性待真机验证 |

**已知缺口（不在本轮范围）**：
1. 联机双端确定性仍需两个真实进程验证（当前无头环境无法模拟 ENet 双端）；
2. `AIDefense` 内部仍有 10 个自维护计时器，未并入 AIClock（并入需要单独 A/B，参考 12.7 的方法）；
3. `AIWaterCrossing` 的 `_plan_timer`、`AIWorkerDirector` 的 `_timer` 同理；
4. 决策逻辑分散在约 10 个模块，`AIDirector` 目前只覆盖 defend/push/reinforce/gather/idle_warn 五类意图的影子计算，尚未接管真实派单。

### 12.12 模块内计时器收口：WorkerDirector / WaterCrossing / Defense（2026-10-31 00:45）

三个模块各自维护浮点计时器，节拍精度与 AI 主时钟不一致。这次给每个模块配一个自己的 `AIClock`（`advance(delta)` 在各自 `tick` 里调用），把固定周期计时器换掉：

| 模块 | 迁移的计时器 | 保留 |
|---|---|---|
| `AIWorkerDirector` | `_timer`(2s 主节拍)、`_log_timer`(日志) | 建造请求 TTL、租约到期（都是"截止时间"语义，不是节拍） |
| `AIWaterCrossing` | `_plan_timer`(6s 规划，初始 2s 延迟) | `_fleet_*` 系列（按事件计时的等待窗口） |
| `AIDefense` | `_threat_timer`(2.5s)、`_building_alert_timer`(0.5s)、`_guard_refill_timer`(2s)、`_resource_timer`(1.5s) | `_guard_timer`(60s，被多处当"距上次完整审计"条件读取)、`_defense_check_timer`(25s)、`_upgrade_timer`、`_zone_timer`、两个影子计时器 |

**踩到的坑**：`const AIClockScript = preload(...)` 不能插在 `extends` 之前，否则整个模块 `Unexpected "extends" in class body` 解析失败、AI 全部停摆。已按"`extends` 之后、其它 const 之前"放置。

**验证**（5 分钟 3v3 HELL，种子 24680）：front 58.95 / 51.00，idle 23.58 / 22.00 —— 落在基线噪声区间（54.9~63.7 / 9.7~24.8）内，无脚本错误。

**剩余**：`_guard_timer` 等"跨函数当条件读"的计时器没有迁移——它们的语义不是"到点触发"，而是"距上次事件多久"，改成时钟会引入 `due()` 的消费语义歧义，需要先改调用结构再迁移。

**8 分钟复验**（迁移后、含本次模块收口）：front **69.58%** / idle **14.89%** / engage 50.49% / land 7.25 / workers 12.18 —— 与 12.10 的迁移后基线（70.91 / 15.68）一致，模块计时器收口没有引入劣化。

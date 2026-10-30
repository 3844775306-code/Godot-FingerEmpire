# AI 总体架构设计（v3）

> 目标：把现有 14 个 AI 文件、约 13000 行代码，收敛成**职责单一、依赖单向、跨模块调用受控**的架构。
> 判据不是"文件拆得够细"，而是：**任何两个模块之间都不允许出现隐式双向调用；任何状态都只有一个写者；任何时刻出问题都能在一个地方看到因果。**
> 前置阅读：[AI架构分析.md](AI架构分析.md)（现状诊断）、[AI_ARCHITECTURE_V2.md](AI_ARCHITECTURE_V2.md)（已完成的 v2 迁移记录）。

---

## 1. 现状：为什么"互相调用"会出问题

基于实际代码扫描，当前 `AI.gd` 与各模块的调用关系是**星型但双向**的：

| 模块 | 调用 `ai.*` 的**不同方法数** | 典型调用 |
|---|---|---|
| `AIDefense.gd` | 27 | `_director_claim`、`_visible_enemies`、`build_building`、`upgrade_building`、`_get_resources` |
| `AIWorkerDirector.gd` | 30 | `_unit_has_claim`、`produce_unit`、`find_best_resource_for_worker`、`_get_limits` |
| `AIWaterCrossing.gd` | 22 | `_cached_armies`、`_get_phase_weights`、`can_afford_building`、`allocate_workers` |
| `AILadderSiege.gd` | 14 | `count_field_military`、`_get_attack_target_castle`、`build_ladder` |
| `AIWallPlanner.gd` | 6 | `_get_enemy_army_direction`、`_cached_buildings` |

**四个具体病症**（都是真实存在的，不是理论风险）：

1. **控制器变成公共黑板**：150+ 个 `ai.xxx()` 调用点意味着 `AI.gd` 的每个私有方法都事实上成了公共 API，改一个私有方法可能打破任意模块。
2. **模块之间偷偷互相调**：`AIWaterCrossing` 直接调 `ai.allocate_workers()`（农民模块的活）、`_release_wall_guard()`（防守模块的活）；`AIWallPlanner` 构造时直接吃进 `_defense` 对象。这是"各司其职"被破坏的根源。
3. **状态多写者**：兵的角色曾同时写在 `_roles`、`RoleLedger`、`garrison_point`、`current_target`、`current_order` 五处（账本迁移已完成一部分，但"命令"这一层仍是多写者）。
4. **调用顺序靠人肉记忆**：`AI.gd` 的决策轮是一段 14 步的流水，谁在谁之前、谁依赖谁刚算完的结果，没有声明，只能靠读代码。

---

## 2. 设计原则（5 条，后面所有规则都从这里推出来）

| 原则 | 含义 | 对应的硬规则 |
|---|---|---|
| **P1 单一写者** | 每类状态只有一个模块能改 | 角色/占用 → 只 `RoleLedger`；资源扣减 → 只 `EconomyPort`；建筑落位 → 只 `BuildPort` |
| **P2 只读上下文** | 模块读世界通过只读对象，不持有控制器 | 模块构造只收 `AIContext`（只读），禁止持有 `ai` 节点引用 |
| **P3 单向依赖** | 依赖方向固定，禁止同层互调 | 分层矩阵见 §4；L3 之间只能通过事件或端口间接交互 |
| **P4 意图与执行分离** | 决策产"意图数据"，执行者消费；决策者不直接调兵 | `AIDirector` 只产 `Intent`；`Executor` 只执行 `Intent` |
| **P5 顺序显式化** | 流水线声明式注册，不写死在函数体里 | `AITickPipeline` 声明阶段与依赖，`tick()` 按注册顺序跑并做断言 |

---

## 3. 目标分层

```
┌──────────────────────────────────────────────────────────────┐
│ L5  演示/调试层   AIDebugPanel（读快照，只读）                  │
├──────────────────────────────────────────────────────────────┤
│ L4  编排层        AIController（AI.gd）                        │
│      职责：生命周期、tick 顺序、对外接口（被 BattleManager 调）  │
├──────────────────────────────────────────────────────────────┤
│ L3  决策层        AIDirector（意图）+ AIPhaseMachine（阶段）     │
│      只读 AIContext，只产 Intent，不执行                        │
├──────────────────────────────────────────────────────────────┤
│ L2  执行层（专业模块，彼此不互调）                                │
│   AIDefense  AIWorkerDirector  AIWaterCrossing                 │
│   AIWallPlanner  AILadderSiege  AIMilitary（主攻/骚扰/撤退）     │
│      只读 AIContext，写只经 Port，产出事件                       │
├──────────────────────────────────────────────────────────────┤
│ L1  世界层        AISituation（快照）+ AIContext（只读门面）      │
│      每轮刷新一次，之后所有模块共享同一份只读视图                 │
├──────────────────────────────────────────────────────────────┤
│ L0  基础设施      AIClock / AIRng / AIConfig / AIEvents         │
│                   RoleLedger（纯数据结构） / Ports（接口）       │
└──────────────────────────────────────────────────────────────┘
依赖方向：只允许 ↑（上层依赖下层）。L2 之间横向依赖 = 违规。
```

### 3.1 每层的职责边界（"各司其职"的定义）

| 层 | 能做 | **不能做** |
|---|---|---|
| L0 基础设施 | 计时、随机、常量、事件、账本存取 | 不知道任何游戏业务概念（不许出现"农民/城墙/主攻"） |
| L1 世界层 | 扫描实体、生成只读快照、提供查询 | 修改任何状态；缓存跨轮复用（每轮重建） |
| L2 执行层 | 按自己的专业领域决策并**通过 Port** 落地 | 调其它 L2 模块；持有 `AIController`；直接扣资源/直接改角色 |
| L3 决策层 | 产出 `Intent`（想做什么、优先级、前提） | 直接派兵、直接建建筑、直接改阶段以外的状态 |
| L4 编排层 | 排定顺序、组装依赖、异常隔离、对外接口 | 包含业务决策（不许出现"如果敌人多就派兵"这类分支） |

### 3.2 端口（Port）——L2 唯一的写出口

L2 模块不允许再出现 `ai.build_building(...)` 这种调用，统一改成端口：

| 端口 | 方法 | 现在的对应物 |
|---|---|---|
| `EconomyPort` | `can_afford`、`spend`、`resources`、`limits` | `ai._get_resources` / `can_afford` / `_get_limits` |
| `BuildPort` | `can_place`、`request_build`、`request_upgrade` | `ai._can_place_ai_building` / `build_building` / `upgrade_building` |
| `RecruitPort` | `can_train`、`request_train` | `ai._can_train_unit_with_queue` / `produce_unit` |
| `CommandPort` | `claim`、`release`、`order_attack`、`order_move`、`order_gather` | `ai._director_claim` / `_director_release` / 直接改 `current_target` |
| `EventSink` | `emit(kind, payload)` | 现在散落的 `print` 与隐式副作用 |

**端口是接口不是实现**：`AI.gd` 提供实现（它是唯一知道 BattleManager 细节的地方），L2 只认接口。这样 L2 模块可以脱离 `AI.gd` 单测。

---

## 4. 依赖矩阵（谁可以调谁）

| 调用方 ↓ 被调 → | L0 | L1 | L2 | L3 | L4 |
|---|---|---|---|---|---|
| **L0** | ✅ 同层工具 | ❌ | ❌ | ❌ | ❌ |
| **L1 快照/上下文** | ✅ | ❌ | ❌ | ❌ | ❌ |
| **L2 专业模块** | ✅ | ✅ 只读 | ❌ **禁止** | ❌ | ❌ 只经 Port |
| **L3 决策** | ✅ | ✅ 只读 | ❌ | ❌ | ❌ |
| **L4 编排** | ✅ | ✅ | ✅ | ✅ | — |

**四条硬规则**（可以用脚本自动检查，见 §8）：

- **R1**：L2 文件里禁止出现 `ai.` 前缀调用（只能出现 `_ctx.`、`_cmd.`、`_eco.` 等端口对象）。
- **R2**：L2 文件里禁止出现其它 L2 模块的类型（如 `AIDefense` 出现在 `AIWaterCrossing` 里）。
- **R3**：L2 模块构造签名只允许 `(context, ports...)`，禁止 `(ai)`。
- **R4**：任何模块禁止调用 `battle.`（战斗管理器）——它属于 L4 的实现细节，经 Port 暴露。

---

## 5. 一轮决策的时序（显式流水线）

```text
每帧（_process/physics）:
  AIClock.advance(delta)                    ← L0，唯一时间来源

决策轮（到点触发）:
  ① AISituation.refresh()                   ← L1，一次扫描，产出只读快照
  ② AIContext.rebuild(situation, ledger)    ← L1，只读门面绑定本轮的快照
  ③ AIPhaseMachine.evaluate(ctx)            ← L3，决定阶段（PRODUCTION/DEVELOPMENT/ASSAULT）
  ④ AIDirector.produce_intents(ctx)         ← L3，产出 Intent 列表（带优先级与前提）
  ⑤ AITickPipeline.run()                    ← L4，按注册顺序执行 L2
       5.1 AIDefense.tick(ctx, ports)        （消费 defend / reinforce 意图）
       5.2 AIMilitary.tick(ctx, ports)       （消费 push / harass 意图）
       5.3 AIWorkerDirector.tick(ctx, ports) （消费 gather / economy 意图）
       5.4 AIWaterCrossing.tick(ctx, ports)  （消费 cross_water 意图）
       5.5 AIWallPlanner / AILadderSiege     （消费 fortify / siege 意图）
  ⑥ RoleLedger.sweep(now)                   ← L0，过期回收
  ⑦ 自检（debug 构建才跑）                    ← 账本自审计、快照对账、意图-执行闭环检查
```

**阶段的显式依赖**（由 `AITickPipeline` 声明，而不是靠代码位置）：

```text
situation → context → phase → director → defense → military → workers → naval → siege → sweep → audit
```

规则：**同一阶段内模块按声明顺序执行；不同阶段只能读前一阶段之后写入的状态**。加新模块只需注册，不改 `AI.gd`。

---

## 6. 状态归属表（"一个状态只有一个写者"）

| 状态 | 唯一写者 | 读者 | 落地方式 |
|---|---|---|---|
| 兵的角色/占用/租约 | `RoleLedger` | 所有 L2、L3 | `CommandPort.claim/release` |
| 兵的当前命令（target/order/garrison） | `CommandPort` | L2、L1 快照 | 端口内部写，外部只读 `unit` 字段 |
| 资源/人口 | `EconomyPort` | 所有层 | 只经端口扣减，禁止直接改 `battle.player_resources` |
| 建筑落位/升级 | `BuildPort` | L2、L1 | 端口内部做校验，模块只表达"想建什么、在哪" |
| 生产队列 | `RecruitPort` | L2 | 同上 |
| 阶段（PRODUCTION/DEVELOPMENT/ASSAULT） | `AIPhaseMachine` | L2、L3 | 模块只读 `ctx.phase`，禁止自行切阶段 |
| 意图（本轮想做什么） | `AIDirector` | L2 | 每轮重建，不跨轮缓存 |
| 世界快照 | `AISituation` | 所有层 | 每轮重建，模块不得缓存跨轮引用 |
| 外交（盟友/背叛） | `AIDiplomacy`（L3） | L2 | 独立模块，不进执行层 |

---

## 7. 关键机制：让"互相调用"在结构上不可能出错

### 7.1 只读上下文（替代 `ai` 引用）

```gdscript
# AIContext：每轮重建，L2/L3 只读
class AIContext:
	var phase: int                  # 当前阶段
	var my_team / my_peer
	var resources / limits          # 只读副本（本帧快照）
	var castle
	var own_army: Array             # 只读数组（不要在模块里 sort/改）
	var visible_enemies: Array
	var counts: Dictionary          # land/field/workers/buildings…
	var ledger_view: LedgerView     # 只读视图：holders(kind)、count(source, kind)
```

**为什么必须有副本**：现在模块直接拿 `ai.battle.entities` 遍历，中途其它模块 spawn/kill 实体会让遍历行为不确定（之前就出现过"单位已死但仍在列表里"的 `[LEDGER] STALE`）。快照把这一层隔离掉。

### 7.2 意图（Intent）而不是直接调兵

```gdscript
class Intent:
	var kind: String      # "defend" / "push" / "gather" / "fortify" / "cross_water" / "siege"
	var priority: int
	var payload: Dictionary   # 目标、数量、区域
	var preconditions: Array  # 例如 ["has_reserve:300"]
```

- **L3 只产 Intent**，不执行；**L2 只消费 Intent**，不自己发明全局目标。
- 一个 Intent 被谁消费、是否被满足，记进 `AIEvents`，调试面板一眼能看出"这轮想推进但没人接"。

### 7.3 重入与异常隔离

- 每个模块 `tick` 外包一层守卫：同一模块同一帧重复进入 → 记 `AIEvents` 并跳过（现在没有，`_defense.tick` 在 `_ready` 和决策轮各调一次就是隐患）。
- 模块内抛错（`push_error`/脚本错误）→ 编排层捕获、记录、该模块本轮跳过，**不拖垮整局 AI**。
- 所有模块 tick 必须在 `AITickPipeline` 内执行，禁止在 `_ready`/`_process` 里零散调用。

### 7.4 一次扫描，多处复用

`AISituation` 已经做到"每轮一次扫描"（成本 0.19~0.40ms，可见性 0.34~0.52ms）。新架构把它升格为**唯一的世界读取入口**：模块禁止自己遍历 `battle.entities`（R4 已禁 `battle.`）。这一条同时解决"同一轮里不同模块看到不同世界"的不一致。

---

## 8. 可自动检查的约束（不靠自觉）

| 检查 | 实现 | 违反时 |
|---|---|---|
| R1：L2 不得 `ai.` 调用 | `tools/ai_arch_check.ps1` 扫 `scripts/ai/*.gd` 的 `\bai\.` | 构建失败（本地脚本） |
| R2：L2 不得跨模块引用 | 同上，扫 L2 文件名互现 | 构建失败 |
| R3：模块构造签名 | 正则校验 `func _init(` / `setup(` 参数 | 构建失败 |
| R4：L2 不得碰 `battle.` | 同上 | 构建失败 |
| 账本自审计 | 现有 `[LEDGER] ok/STALE` | STALE > 0 记告警 |
| 快照对账 | 现有 `[SITUATION] MISMATCH` | MISMATCH > 0 记告警 |
| 意图闭环 | `[DIRECTOR-V2] intents=N consumed=M`，N≠M 时要解释 | 每轮日志 |
| 行为基线 | `tools/ai_selfplay_runner.gd` 的 front/idle/engage 表 | 回归 > 5pt 需说明 |

---

## 9. 迁移路径（每步可发布、可回滚）

沿用 v2 已验证的"影子 → 切换 → 删除旧路径"三段式，**不一次性重写**：

| 步 | 内容 | 风险 | 回滚方式 |
|---|---|---|---|
| **A1** | 新增 `AIContext`（只读门面），内部先直接转发到现有实现；模块继续用 `ai` | 极低 | 删文件即可 |
| **A2** | `AIDefense` 改用 `_ctx` 读世界（写留 `ai`），一次一个模块 | 低 | 单模块回退 |
| **A3** | 新增 `CommandPort/EconomyPort/BuildPort` 实现（包一层现有方法），模块写改端口 | 中 | 端口内部转发回旧方法 |
| **A4** | `AIWorkerDirector`、`AIWaterCrossing` 改端口，并删掉它们对 `ai.allocate_workers` 等跨模块调用，改发 `EventSink` | 中 | 单模块回退 |
| **A5** | `AIDirector` 从"影子"升级为"唯一意图来源"，L2 只消费意图；老的"模块自己判断要不要进攻"逐步下线 | 中高 | `USE_DIRECTOR_INTENTS` 开关 |
| **A6** | `AITickPipeline` 接管顺序，`AI.gd` 只剩组装与对外接口 | 低 | 保留旧流水分支 |
| **A7** | 打开 §8 的 R1~R4 检查，清理存量违规（预计 150+ 处 `ai.` 调用） | 低（纯重构） | 分批提交 |

**每一步之后都跑 8 分钟 3v3 自对弈对照 front/idle**，劣化就回退——v2 的 P3.3 已经证明"看起来是纯重构"的改动也会真实改变行为。

---

## 10. 验收标准（做完是什么样）

1. **依赖可枚举**：`scripts/ai/` 内任意文件，用一条 grep 就能列出它依赖谁；不存在双向引用。
2. **模块可单测**：每个 L2 模块能只喂 `AIContext` + 假端口跑通一轮，不需要真 `BattleManager`。
3. **改一处不炸别处**：修改 `AI.gd` 的私有实现不影响 L2（因为 L2 只见端口）。
4. **顺序可断言**：`AITickPipeline` 能在运行时打印"本轮谁先谁后、各花多久"。
5. **行为可对照**：任一次改动都能用自对弈出 front/idle/engage 对照表。
6. **新模块 = 注册一行**：加一个专业模块不需要改 `AI.gd` 的 14 步流水。

---

## 11. 与现有代码的对应关系（哪些已经有了）

| 设计元素 | 现状 | 差距 |
|---|---|---|
| 统一节拍 `AIClock` | ✅ 已落地（含帧级推进） | 无 |
| 确定性随机 `AIRng`/`SimRandom` | ✅ AI 侧 12 处全走 SimRandom；联机 7 处已收口 | 联机双端待真机验证 |
| 统一角色账本 `RoleLedger` | ✅ 唯一写者（`_roles` 已删） | "命令"这一层仍是多写者 |
| 只读世界快照 `AISituation` | ✅ 每轮一次 + 对账 | 未升格为唯一读取入口 |
| 意图层 `AIDirector` | ✅ 影子五类意图 + defend 接线（默认关） | 未成为唯一决策来源 |
| 只读上下文 `AIContext` | ❌ 没有 | §9 A1 |
| 端口 `Economy/Build/Recruit/Command` | ❌ 没有 | §9 A3 |
| 流水线 `AITickPipeline` | ❌ 顺序写死在 `AI.gd` | §9 A6 |
| 架构约束检查脚本 | ❌ 没有 | §9 A7 |
| 行为基线自对弈 | ✅ `tools/ai_selfplay*` | 需固定"跑前清 Godot 进程" |

---

## 12. 一句话总结

**现在的 AI 是"一个大控制器 + 五个能反过来指挥控制器的模块"；目标形态是"一个薄编排器 + 一个只读世界 + 一个意图层 + 一组只能通过端口动手的专业执行者"。** 数据流向是单向的：世界 → 意图 → 执行 → 账本，任何写操作都能溯源到唯一的端口调用点。

---

## 13. 可追溯性（回答"任意一条 AI 指令能否精准找到底层逻辑"）

**先说结论：只靠 §3~§8 的分层和端口，不够。** 分层解决的是"这条指令属于哪个模块"（能从 27~30 个 `ai.*` 方法收敛到 1 个端口），但回答不了三个更细的问题：

1. **是哪条规则决定的？** —— "生产步兵"在现有代码里有 **8 个调用点**（`AI.gd:1242/2201/2219/2857/3830/4755/4801/4813`、`AIWorkerDirector.gd:121`），分属补员、扩军、主攻准备、紧急翻盘等完全不同的规则；
2. **为什么是这一轮、这个数量？** —— 依赖当轮快照与账本，跨轮不可复现；
3. **为什么没生产出来？** —— 可能被资源、人口、队列、`_can_train_unit` 中任意一关拒绝，现在全靠 `print`，且大量分支根本没日志。

所以必须在架构里加**第 6 条原则（P6 可追溯）**和一个 L0 设施 `AITrace`。

### 13.1 五跳原则

任何一条会改变对局状态的动作，都必须能回答五个问题，缺一个就算架构缺陷：

| 跳 | 问题 | 载体 |
|---|---|---|
| 1 意图 | 这一轮 AI 总体想干什么 | `Intent.id` + `kind`（Director 产出） |
| 2 规则 | 哪条规则决定动手 | 稳定规则 ID，如 `military.reinforce_gap` |
| 3 指令 | 具体调用了什么、参数是什么 | Port 调用：`RecruitPort.request_train(14, 1)` |
| 4 落地 | 最终落到引擎/战斗管理器的哪一步 | `battle.produce_unit` / 建筑队列 |
| 5 结果 | 成功还是被谁拒绝 | `ok` / `reject_reason`（`no_gold` / `queue_full` / `no_building`） |

### 13.2 机制：规则上下文 + 端口强制带来源

```gdscript
# L0：AITrace。关闭时零分配（只判一个 bool）。
AITrace.begin_round(round_no, elapsed)
AITrace.intent(id, kind, payload)                  # 由 Director 调用
AITrace.rule("military.reinforce_gap", {"gap": 3}) # 进入某条规则的上下文（栈）
AITrace.command("recruit.request_train", {"unit": 14, "n": 1})
AITrace.result(ok, "no_gold")                      # 失败必须带原因
AITrace.end_round()                                # 落盘/入环形缓冲
```

关键约束：**Port 的写方法在内部自动读"当前规则上下文"并记录**，模块忘了写日志也不会丢来源；反过来，**没有规则上下文的 Port 调用直接记 `rule=<unattributed>` 并在自检里报错**——这样"偷偷改状态"在结构上不可能。

### 13.3 稳定规则 ID（不是文件行号）

行号会随重构漂移，规则 ID 必须是人起的名字：

```text
military.reinforce_gap      补员：可出击兵力 < 门槛
military.assault_ready      主攻准备完成，开始集结
worker.food_crisis          食物告急，强制改派农民
worker.build_request        有建造请求待分配建造者
defense.guard_refill        守军快速补员
defense.wall_ring           城墙补圈
naval.cross_water           组织渡海
```

代码里每个决策分支入口写一行 `AITrace.rule("...")`，规则清单统一登记在 `AIConfig.RULES`（便于检查"定义了但没用到/用到了但没定义"）。

### 13.4 一条指令的完整链路（以"生产一个步兵"为例）

```text
[1 意图]  director: intent defender#3  kind=reinforce  want=12 have=9
[2 规则]  military.reinforce_gap {"gap":3, "phase":"DEVELOPMENT", "gold":420, "pop":38/50}
[3 指令]  RecruitPort.request_train(unit=14, n=1)   ← 由 AIMilitary 发起
[4 落地]  AI.gd → battle.produce_unit(14) → Building(21).queue.append(14)
[5 结果]  ok=true  cost={gold:60,food:40}  queue_depth=1
```

**反向查询**（给定一个刚出生的步兵实体）：实体 → `RoleLedger` 记录（source=director, kind=SIEGE, trace=#8123）→ trace#8123 → 上面五跳。**这就是"从下往上找到底层逻辑"和"从上往下找到落地"的双向可查。**

### 13.5 落地工具

| 工具 | 用途 |
|---|---|
| `--trace=1` 自对弈参数 | 每轮把 trace 写成 `trace.jsonl`（一行一条 JSON，可 grep/jq） |
| `tools/ai_trace.gd` 查询脚本 | `--rule=military.reinforce_gap` / `--entity=14` / `--round=120` 打印链路 |
| 调试面板「调度」页 | 点一个兵 → 显示它的 trace 链与当前占用来源 |
| `[TRACE]` 日志 | 只打印被拒绝的动作、`unattributed` 调用、意图无人消费 |

### 13.6 验收（可执行）

1. 从 `trace.jsonl` 任取一条 `produce_unit`，**5 跳内**能回到 intent 与规则 ID；
2. 从任一实体 id 能反查到最近一次改变它角色的规则 ID；
3. 关掉 trace 时性能开销为 0（只多一个 `if not enabled: return`）；
4. 打开 R1~R4 + `unattributed` 检查后，`scripts/ai/` 里**不存在**无法归因的状态写入。

### 13.7 迁移插入点

在 §9 的 A1 之前加 **A0：加 AITrace + 只覆盖"生产"这一条竖切路径**（`military.reinforce_gap` → `RecruitPort` → `battle.produce_unit`），跑通 13.4 的端到端链路，再按模块逐个接规则 ID。**先做一条能看的链路，比先做全量框架有效。**

### 13.8 A0 竖切已落地（2026-10-31 02:15）

**已实现**：`scripts/ai/core/AITrace.gd` + 生产漏斗挂点。

1. `produce_unit(unit_id, trace_rule := "")` 成为唯一的带追踪漏斗——所有 17 个生产调用点都经它（实现体改名 `_produce_unit_impl`）；
2. 14 个调用点已标注稳定规则 ID：`military.assault_recruit` / `military.front_recruit` / `worker.train_peasant` / `military.opening_infantry` / `military.nation_special` / `military.trebuchet` / `military.scout` / `naval.ship`；
3. 每轮 `_begin_decide` 开轮、决策末轮 `end_round`；`AIDirector` 的意图每轮作为 `intent` 行写入；
4. 命令行加 `--trace` 即开启，输出 `docs/ai-analysis/trace/trace.jsonl`（默认关闭，关闭时只多一次 bool 判断）；
5. 建 `docs/ai-analysis/trace/.gdignore` 防止 Godot 导入，`*.jsonl` 加入 `.gitignore`。

**首次实测**（3 分钟 3v3 HELL，种子 24680）：257 行 / 45KB，
`command=167`（成功 92、被拒 75）、`intent=90`、**`unattributed=0`**（所有生产都有规则归属）。

按规则分布：

| 规则 | 成功 | 被拒 |
|---|---|---|
| `military.assault_recruit` | 14 | **75** |
| `worker.train_peasant` | 46 | 0 |
| `military.front_recruit` | 28 | 0 |
| `military.scout` | 4 | 0 |

**立刻暴露了一个真问题**：`assault_recruit` 有 **84%（75/89）的尝试被拒**——主攻集结时反复尝试造兵、反复失败。这正是做可追溯性的价值：以前这类"静默失败"只会拖慢节奏，没人能看见。

**下一步（A0 收尾）**：给 `RecruitPort` 补细粒度拒绝原因（`no_gold` / `pop_full` / `queue_busy` / `no_building` / `locked`），把现在笼统的 `rejected` 拆开；再据此修 assault 集结的重复失败。

### 13.9 A0 收尾：拒绝原因细化 + 追踪抓出的第一个真 bug（2026-10-31 02:40）

**1. 拒绝原因细化**：`produce_unit` 不再只报 "rejected"，区分五种：

| 原因 | 含义 |
|---|---|
| `locked` | 研究/时代未解锁 |
| `no_cost` | 资源真的不够 |
| `reserved` | 资源够，但被升级预算预留锁住 |
| `cap` / `no_merchant` | 数量上限 / 没有商人可跟 |
| `no_queue` | 所有生产建筑队列都忙（正常节流，不是错误） |

**2. 追踪立刻抓出的问题**：`military.assault_recruit` 有 **111/226 次（49%）被 `locked` 拒绝**——两个位置在反复尝试生产**没解锁**的单位：

- `_train_overflow_units()` 的克制单位循环（51/44/45）；
- `_try_produce_merchants_or_officials()` 的 `[51, 44, 45, 43]` 循环。

两处都在 `can_afford` 通过后直接调 `produce_unit`，而"是否解锁"只在漏斗内部才检查，于是每轮白试一次。

**3. 修复**：两处循环在尝试前先过 `battle.is_unit_unlocked(...)`，未解锁直接 `continue`。

**4. 修复后同配置实测**：`locked` 从 111 → **0**，总指令 226 → 145（少了 36% 的无用动作），`unattributed` 保持 0；剩下的拒绝全是 `no_queue`（队列忙，属正常节流）。行为指标 front 62.5% / idle 16.0%，与基线一致。

**结论**：这一步验证了"可追溯性不只是好看"——两个隐藏多年的空转，是靠 `rule + reject_reason` 两列一排序就看见的。

---

## 14. A1 已落地：AIContext 只读门面（2026-10-31 03:10）

**做了什么**：新增 `scripts/ai/world/AIContext.gd`，在 `AI.gd` 每轮快照刷新后 `bind(self, _situation, _ledger, round_no)`，对外提供只读查询：

| 分类 | 接口 |
|---|---|
| 身份 | `my_peer_id()` / `my_team()` / `phase()` / `round_no()` |
| 经济 | `resources()` / `limits()` / `can_afford*()` |
| 归属 | `belongs_to_me()` / `is_enemy()` / `is_defending()` / `primary_enemy_team()` |
| 建筑 | `castle()` / `enemy_castle()` / `count_building()` / `count_unit()` |
| 敌情 | `visible_enemies()`（优先当轮快照）/ `enemy_army_within()` / `is_ranged_wall_candidate()` |
| 账本 | `ledger_holders(kind)` / `ledger_count(kind)` |

**当前状态**：转发式实现（内部仍指向控制器与快照），**还没有任何模块改用它**——A1 只是把门面立起来，行为零变化。摘要里已暴露 `context` 段，便于确认绑定时机。

**验证**：2 分钟 3v3 HELL 自对弈通过，`front 71.4% / idle 19.0%`，无脚本错误。

**下一步（A2）**：`AIDefense` 是第一个改造对象。它读控制器的方法有 11 种、共 43 处调用（`entity_belongs_to_me` 17、`count_building` 7、`_entity_is_enemy` 5、`get_peer_castle` 4…），把读取全部换成 `_ctx.xxx()`，写操作（`build_building`/`upgrade_building`/`_director_claim`）暂时保留，等 A3 的 Port 再收。改完跑 8 分钟对照，行为不变才继续下一个模块。

---

## 15. A2 已完成：AIDefense 的读取切到 AIContext（2026-10-31 03:25）

**改动**：`AIDefense` 新增 `set_context(ctx)` 与三个读取包装（`_belongs` / `_count_bld` / `_is_enemy_ent`），把最高频的三类读取从控制器迁到只读上下文：

| 读取 | 原调用点 | 迁移后 |
|---|---|---|
| `entity_belongs_to_me` | 17 处 | `_belongs()` → `_ctx.belongs_to_me()` |
| `count_building` | 7 处 | `_count_bld()` → `_ctx.count_building()` |
| `_entity_is_enemy` | 5 处 | `_is_enemy_ent()` → `_ctx.is_enemy()` |

**共 29 处读取迁移**（占该模块 43 处读取的 2/3）。包装函数暂时保留"上下文未绑定时回落控制器"的分支，A3 的 Port 到位后删除回落——这样每一步都可回滚，且不会因为漏绑上下文直接断掉防守逻辑。

**踩坑（值得记住）**：批量替换 `ai.xxx(` 时把包装函数自己的回落分支也替换了，导致**自递归**（`_belongs` 里调 `_belongs`）。因为包装是在替换前插入的，脚本没区分"新增代码"与"存量代码"。改批量替换脚本时，要么先替换存量再加包装，要么对新增段落做保护标记。

**验证**：2 分钟 3v3 HELL → `front 76.7% / idle 6.7% / engage 36.7%`，无脚本错误；写操作（`build_building` / `upgrade_building` / `_director_claim`）仍走控制器，留待 A3。

**剩余**：`AIDefense` 还有 14 处读取（`get_peer_castle` 4、`_get_resources` 2、`_primary_enemy_team` 2、`_get_limits` 1、`_is_defending` 1、`_is_ranged_wall_candidate` 1、`_enemy_army_within` 1…）与全部写操作，在 A3/A4 一并处理。

---

## 16. A2 收尾 + A3 落地：读取全迁 + 写操作进端口（2026-10-31 03:50）

**A2 收尾**：`AIDefense` 剩余 14 处读取（`get_peer_castle` 4、`_get_resources` 2、`_primary_enemy_team` 2、`get_team_castle` 2、`_get_limits`/`_is_defending`/`_is_ranged_wall_candidate`/`_enemy_army_within` 各 1）全部改走 `_ctx`，包装函数保留控制器回落。至此该模块**业务读取 100% 走只读上下文**，只剩 `battle`（121 处，R4 尚未处理）、身份字段与写操作。

**A3 落地**：新增 `scripts/ai/ports/AIPorts.gd`，三个端口：

| 端口 | 方法 | 转发到 |
|---|---|---|
| `EconomyPort` | `resources` / `limits` / `can_afford` / `last_spend_block` | `ai._get_resources` 等 |
| `BuildPort` | `can_place` / `can_build` / `build` / `upgrade` / `castle_lv` | `ai._can_place_ai_building` / `build_building` / `upgrade_building` |
| `CommandPort` | `claim` / `release` / `has_claim` / `role_of` | `ai._director_claim` / `_director_release` / `_unit_has_claim` |

`AIDefense` 的 9 处写操作（`build_building` 3、`_can_place_ai_building` 2、`_director_claim` 2、`upgrade_building` 1、`_director_release` 1）已改为 `_build_port.xxx` / `_cmd_port.xxx`。**"谁在建、谁在抢兵"从此有单一入口。**

**验证**：2 分钟 3v3 HELL → `front 74.4% / idle 10.3% / engage 28.2%`，脚本错误 0。

**踩坑两条**：
1. `_enemy_army_near(pos)` 丢了默认半径 → `Too few arguments` 编译失败，补默认值；
2. `AIContext` 的 `team_castle_of` 插入锚点没匹配上（`is_ranged_wall_candidate` 那行已被前一次替换改过），运行期才暴露 `Nonexistent function`。**教训：新增方法后必须跑一次真实对局**，仅靠"脚本报 ok"不可信。

**下一步（A4）**：`AIWorkerDirector`（30 个 `ai.*` 读取）与 `AIWaterCrossing`（22 个）改用 `_ctx`；重点是**删掉它们的跨模块调用**（`ai.allocate_workers` / `ai._release_wall_guard`），改为发 `AIEvents` 由对应模块自行处理。

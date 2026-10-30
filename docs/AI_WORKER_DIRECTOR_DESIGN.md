# AI 农民调度重构设计（WorkerDirector）

> 目标：把现在散落在 `AI.gd`、`AIDefense.gd`、`AIWaterCrossing.gd`、`RTSBattleManager.gd`
> 里的补农、采集、逃跑、建造、修理、打猎逻辑，收敛成
> **一个调度器 + 一张需求表 + 一套角色租约**。
>
> 实施状态：**第 6 阶段（建造请求队列）已接入**。没有可用建造者时，`build_building`
> 会把请求登记到 Director，下一轮分配统一重试；请求带位置去重、30 秒 TTL 和
> 3 次尝试上限。完整 RepairRequest 队列和旧回退分支清理仍未完成。
>
> 这套结构可以视为 [AI_ARMY_DISPATCH_DESIGN.md](AI_ARMY_DISPATCH_DESIGN.md)
> 的农民版：军队用 ArmyDirector，农民用 WorkerDirector，两者共用同一套
> 「单一账本、唯一入口、租约、优先级需求」原则。

## 1. 现状问题

### 1.1 入口太多，没有仲裁

当前至少 7 个入口会直接改农民状态：

| 入口 | 位置 | 行为 |
|---|---|---|
| 开局补农 | `_state_production()` | 补到 8 个 |
| 周期补农/采集 | `allocate_workers()` | 每 3 秒重分配、补到 15 |
| 食物救急 | `_force_food_workers()` | 拉一半人去食物 |
| 稀缺资源平衡 | `_emergency_rebalance_workers()` | 改派 2~4 人 |
| 建造 | `build_building()` → `find_nearest_idle_builder()` | 找空闲农民 |
| 民居/兵营兜底 | `_force_house_builder()` | 强行抽一个农民 |
| 修理 | `_tick_building_repair()` | 找空闲农民 |
| 防线建造 | `AIDefense` | 找空闲农民 |
| 遇敌逃跑 | `AIDefense._defend_resources()` | 直接 `move_to()` |
| 打猎 | `_ai_hunt_animals()` | 直接 `attack_target()` |
| 修桥后重分配 | `AIWaterCrossing` | 直接调 `allocate_workers()` |

这些入口之间没有优先级、没有占位、没有释放契约。典型冲突：

- AIDefense 刚让农民逃跑，`_force_house_builder()` 又把他抓去建房；
- 所有农民都在采集，`find_nearest_idle_builder()` 找不到人，墙/塔/修理全部停摆；
- 农民死光后，补农逻辑因为食物不足或资源满仓直接停止；
- `allocate_workers()` 每 3 秒重算一次，农民目标频繁抖动。

### 1.2 没有农民账本

现在只能靠 `count_unit(10)` 和单位身上的 `ai_flee_until` 等 meta 推断状态。
无法回答：

- 这个农民现在是什么角色？
- 他正在为哪个建造请求服务？
- 这个角色什么时候到期？
- 他为什么没去采集？

### 1.3 建造者选择口径不统一

`find_nearest_idle_builder()` 只接受：

- `current_order == "" / "idle"`；
- 或 `current_order == "gather"` 且 `_work_target_id == -1`。

真正正在采集的农民不会被普通建造选中。
只有民居/兵营有 `_force_house_builder()` 兜底，修理、墙、塔、梯子都没有。

### 1.4 补农没有保底

- 目标数量固定 8/15，没有最低保底；
- 食物 < 50 就买不起农民；
- 食物告急且已有 8 个农民时，主动停止补农；
- 四种资源都接近满仓时，也停止补农。

结果就是实测中的 pid 2001：

```text
人口 3，农民 0，军队 0，食物 44
```

经济已经死亡，AI 没有自救路径。

## 2. 核心模型

### 2.1 角色枚举（唯一真相）

```gdscript
enum WorkerRole {
    IDLE,
    GATHER,
    HAULER,      # 背货回仓库途中
    BUILDER,     # 正在施工
    REPAIRER,    # 正在修理
    FLEE,        # 避险中
    GARRISON,    # 进入城堡/建筑暂避
    HUNT,        # 打猎
}
```

单位身上**只写一个** meta：`ai_worker_role`（整数）。
旧 meta 全部退役：

```text
ai_flee_until
```

不再由多个系统直接写农民命令。

### 2.2 账本（唯一数据源）

```gdscript
var _workers: Dictionary = {}
# uid -> {
#   unit: Army,
#   role: int,
#   task_id: int,
#   lease_until: float,
#   target_id: int,
#   resource_type: String,
#   safe_pos: Vector3,
#   since: float,
#   last_reason: String,
# }
```

所有系统只能通过两个入口改农民：

```gdscript
func assign(worker, role, task, lease_s)
func release(worker, reason)
```

`assign()` 写账本、写 meta、下单；`release()` 清任务、清 meta、把农民放回 `IDLE` 池。

### 2.3 任务/需求表

建造、修理、采集、逃跑都变成任务请求，而不是直接操作单位：

```gdscript
class WorkerRequest:
    var id: int
    var kind: int          # BUILD / REPAIR / GATHER / FLEE / HUNT
    var priority: int
    var target_id: int
    var position: Vector3
    var workers_needed: int
    var workers_assigned: int
    var expires_at: float
    var source: String     # "house_quota" / "defense_wall" / "repair" ...
```

需求表由当前局面生成，例如：

```gdscript
{kind=BUILD,  priority=90, budget=1, source="critical_house"}
{kind=REPAIR, priority=70, budget=1, source="repair"}
{kind=GATHER, priority=30, budget=自由农民数, source="economy"}
{kind=HUNT,   priority=10, budget=5, source="food_surplus"}
```

### 2.4 优先级

```text
FLEE                 100   敌人贴脸，最高优先
CRITICAL_BUILD/REPAIR 90   民居/兵营被打掉、城墙破口
FOOD_GATHER           80   食物告急
NORMAL_BUILD          60   普通扩张
REPAIR                50   普通修理
GATHER                30   常规采集
HUNT                  10   有余力才打猎
IDLE                   0   兜底
```

规则：

- 只有高优先级需求未满额，才能从低优先级角色拿人；
- 正在施工/修理的农民默认不可抢占，除非 FLEE 或 CRITICAL；
- 同优先级先到先得；
- 每个任务都有租约，到期自动释放，避免永久卡死。

### 2.5 单一 tick

```gdscript
func _tick_worker_director(delta):     # 1 秒一次
    _sync_roster()                     # 处理死亡/新农民/换主
    _expire_leases()                   # 到期角色回收
    _collect_requests()                # 收建造/修理/采集/逃跑需求
    _evaluate_mode()                   # NORMAL / FOOD_CRISIS / BASE_ALERT / WORKER_CRISIS
    _ensure_worker_floor()             # 先保农民数量，再谈其他
    var demands := _build_demands()    # 唯一决策点
    _fill_demands(demands)             # 按优先级分配
    _standby_fallback()                # 闲散农民必须有采集目标
    _record_metrics()
```

所有扫描只在这里做一次，其他模块只提交请求/威胁数据，不再各自遍历实体。

## 3. 补农逻辑（Recruiter）

### 3.1 数量模型

| 阶段 | 目标 | 保底 |
|---|---:|---:|
| PRODUCTION | 8 | 4 |
| DEVELOPMENT | 12 | 6 |
| ASSAULT | 15 | 8 |

- `target` 是希望达到的数量；
- `floor` 是绝对不能让经济死亡的数量；
- 农民数 = 活着的 + 生产队列里的（避免 3 秒内连续排队）。

### 3.2 补农规则

```text
if workers < floor:
    WORKER_CRISIS：无条件优先补农
    预留 50 食物，暂停非必要建筑/兵种消费
elif workers < target:
    正常补农；食物告急时最多补到 floor
```

关键变化：

- `floor` 不受 `_all_gather_resources_full()` 限制；
- `floor` 不受“食物告急且已有 8 个农民”的旧规则限制；
- 如果食物不够 50，进入 `FOOD_FOR_WORKERS` 模式：
  - 暂停非必要消费；
  - 把现有农民优先派去食物；
  - 记录 `block=no_food`，而不是静默停止。

### 3.3 训练预算

- 每个 tick 最多补 1 个农民；
- 记录 `train_block_reason`：
  - `food`
  - `population`
  - `no_castle`
  - `queue_full`
- 生产队列也计入农民数，避免连续超排。

## 4. 采集需求（Economy）

### 4.1 配额制，而不是每个农民独立选

```gdscript
var gather_quota := {"food": 4, "wood": 5, "stone": 3, "gold": 2}
```

- 由阶段、建造需求、军队生产、资源缺口共同计算；
- 每 5 秒更新一次；
- 每次 tick 最多改派 2 个农民，避免抖动；
- 农民默认保持当前资源点，直到：
  - 资源点耗尽；
  - 资源类型超额；
  - 位置不安全；
  - 进入食物危机/基地警报。

### 4.2 安全选点

`find_best_resource_for_worker()` 保留，但由 Director 统一调用：

```text
score = 资源权重
      - 距离 × 0.01
      - 危险分
```

- 危险分来自 AIDefense 的威胁快照；
- 危险分超过硬阈值时，不派农民去该点；
- 没有安全点时，允许选“相对最安全”的点，而不是全部缩回主城。

### 4.3 食物危机

`FOOD_CRISIS` 模式：

- 食物 < 120 且比例 < 25%；
- 目标：把 50% 农民放到食物；
- 暂停非必要建造；
- 如果食物不足以补农，先保农民食物预算，再考虑士兵。

## 5. 安全/逃跑（Safety）

AIDefense 不再直接移动农民，只发布威胁信息：

```gdscript
# AIDefense 每 1 秒更新
danger_zones = [
    {"center": Vector3, "radius": 8.0, "enemy_count": 2, "until": ...}
]
```

WorkerDirector 负责：

1. 农民在危险区内 → `FLEE`；
2. 有货 → 先交付；
3. 无货 → 移动到安全点：
   - 优先城堡/后方安全区；
   - 没有安全区则远离敌人，而不是固定 6 米；
4. 威胁解除后释放 `FLEE`，回到原采集任务（如果还安全）。

硬规则：

- `FLEE` 中的农民不能被建造/修理请求抓走；
- `FLEE` 有租约，敌人消失后最多 2 秒释放；
- 建造点不安全时，建造请求等待，不派农民送死。

## 6. 建造/修理（Build & Repair）

### 6.1 AI 不再自己找农民

旧流程：

```text
AI 规划建筑 → build_building() → find_nearest_idle_builder() → 直接扣资源
```

新流程：

```text
AI 规划建筑 → 提交 BuildRequest → WorkerDirector 分配 Builder
            → build_building(builder) → 扣资源/生成建筑
```

`build_building()` 增加可选 `builder` 参数：

- 有 builder：直接使用；
- 没有 builder：返回失败，请求留在队列，不扣资源。

### 6.2 建造预算

| 阶段 | 同时施工人数 |
|---|---:|
| 开局 | 1 |
| 发展 | 2 |
| 后期 | 3 |
| 基地危急 | 3 + 1 个应急名额 |

- 普通建造只能从 `IDLE` 或 `GATHER` 里抽人；
- 关键民居/兵营/破口修理可以抢占一个采集农民；
- 不允许把全部农民拉去建造。

### 6.3 修理

修理也变成 `REPAIR` 请求：

- 优先级 50；
- 危险区内不修；
- 当前修理中的农民有租约，建筑修好/被拆/超时释放；
- 不再要求“必须有空闲农民”，Director 可以临时抽一个采集农民。

## 7. 打猎（Hunt）

旧逻辑要求农民 > 15，而目标也是 15，实际几乎永不触发。

新规则：

```text
if food_gap > threshold and workers > floor + 2:
    enqueue HUNT, budget=5, priority=10
```

- 打猎是低优先级，只在食物有缺口且农民有余量时执行；
- 猎手有租约，动物死亡/食物恢复后释放；
- 释放后回到采集池。

## 8. 修桥/跨海

`AIWaterCrossing` 不再直接调 `allocate_workers()`，改为：

```gdscript
worker_director.notify("bridge_completed")
```

Director 在下一个 tick：

- 重算可达资源；
- 重新计算采集配额；
- 如果桥上需要建造者，生成 `BUILD` 请求；
- 不直接改农民命令。

## 9. 指标与可观测性

每个 AI 每 5 秒输出一行：

```text
[WORKER] mode=NORMAL live=12 queued=1 target=15 floor=8
         gather=8 build=2 repair=1 flee=1 idle=0
         quota={food:4,wood:5,stone:3,gold:2}
         block=none last=flee_expired
```

必须能回答：

- 农民总数/目标/保底；
- 每个角色有多少人；
- 当前有没有建造请求等人；
- 最近一次补农失败原因；
- 是否有农民被多个系统争抢。

## 10. 迁移计划（5 步，每步可独立提交/回滚）

### 第 1 步：骨架 + 只读账本

- 新增 `AIWorkerDirector`；
- 每 tick 同步农民列表、记录角色/位置/任务，但**不改任何行为**；
- 加 `[WORKER]` 日志；
- 用途：先观察现状，确认账本和指标正确。

### 第 2 步：收编补农 + 采集

- `_state_production()` 和 `allocate_workers()` 的补农/采集逻辑迁移到 Director；
- 旧函数保留为薄包装，避免一次性改太多；
- 加入 `floor` 保底和 `WORKER_CRISIS`；
- 删除 `_all_gather_resources_full()` 对保底补农的阻断。

### 第 3 步：收编建造/修理

- 给 `build_building()` 增加 `builder` 参数；
- AI 建房、民居/兵营兜底、修理、AIDefense 墙塔、梯子、修桥全部改为提交 `BuildRequest`；
- 删除直接调用 `find_nearest_idle_builder()` 的 AI 路径；
- `RTSBattleManager.assign_builders()` 仍然是底层执行接口。

### 第 4 步：收编逃跑 + 打猎

- AIDefense 只发布威胁，不再移动农民；
- Director 负责 FLEE/返回；
- 打猎改为低优先级需求；
- 删除 `ai_flee_until` 在建造路径里的隐式依赖。

### 第 5 步：清理

删除旧入口：

```text
_allocate_workers() 的主逻辑
_force_food_workers()
_emergency_rebalance_workers()
_force_house_builder() 的旧抽人逻辑
AIDefense._defend_resources() 中的农民移动
AIWaterCrossing 直接 allocate_workers()
```

保留兼容包装，确认无调用后再删。

## 11. 验收指标

| 指标 | 目标 |
|---|---|
| 农民 0 且食物 < 50 持续 > 15 秒 | **0 次** |
| 农民全灭后恢复到 floor | **≤ 30 秒**（资源允许时） |
| 有建造请求但无 builder 持续 > 5 秒 | **0 次**（不安全点除外） |
| 同一农民 1 分钟内角色切换 | **≤ 3 次** |
| `FLEE` 农民被建造抓走 | **0 次** |
| 三局五分钟后每 AI 活农民 | **≥ 8** |
| 三局五分钟后每 AI 民居/兵营 | 不低于当前基线 |
| `[WORKER]` 日志可解释每个农民状态 | **100%** |

## 12. 待确认

### A. 农民目标数量

- 方案一（推荐）：`8 / 12 / 15`，保底 `4 / 6 / 8`；
- 方案二：维持当前 `8 / 15`，只加保底 `5`。

### B. 建造抢占边界

- 方案一（推荐）：关键民居/兵营/破口修理可抢占 1 个采集农民；
- 方案二：只允许空闲农民，宁可等待。

### C. 逃跑目的地

- 方案一（推荐）：城堡/后方安全区，威胁解除后回原资源点；
- 方案二：只做短距离逃离，不改变资源点。

### D. 实施范围

- 方案一（推荐）：先只改单机 AI，联机 AI 走同一个 AIController，后续自然复用；
- 方案二：第一版同时改 OnlineBattleManager 的 AI 路径。

### E. 与 ArmyDirector 的关系

- 方案一（推荐）：WorkerDirector 先独立实现，共用“账本/租约/需求表”模式；
- 方案二：先抽一个通用 `AIDirector` 基类，再同时做军队和农民，工程更大。

# AI 军队调度重构设计（ArmyDirector）

> 目标：把现在"10 个调度器各自遍历实体、各自写 meta、各自判排除条件"的混乱结构，
> 收敛成**一个调度器 + 一张需求表 + 一套角色租约**，从代码层面保证"不会有兵没人管"。

## 1. 现状问题（读码结论）

1. **没有仲裁**：塔内驻军(4s)、守墙(10s)、建筑回防(0.5s)、守家审计(60s)、守家快补(2s)、
   资源守卫(1.5s)、主攻(10s)、集结(每轮)、战术(25s)、补派(2s) 共 10 个入口，
   谁先到期谁先抢，没有优先级、没有账本。
2. **排除条件重复 8 份**：每个调度器都手写一串 `has_meta("ai_home_guard") or ...`，
   已经出现不一致（例如 `count_field_military` 不排除 `ai_building_defense_until`，
   但 `attack_move` 排除）。新增角色要改 8 处，必漏。
3. **角色没有释放契约**：`ai_rallied` 永久；`ai_home_guard` 只能靠一个特殊函数释放；
   `_garrison_target_id` 只有"到达/目标失效"才清 → 单位会永久卡在"正在赶去驻军"，
   而所有调度器（含 `count_field_military`）都会跳过它。
4. **指标和门槛互相拖**：主攻要求"野战兵 ≥12"，而野战兵数量是**扣除守军/守墙/骚扰后的余数**，
   守家一抓人，野战兵就掉到 12 以下 → 不解锁守军 → 更容易被抓 → 自锁。
5. **无兜底**：单位 idle 时没有任何代码保证它会被重新分配；PRODUCTION 阶段甚至不跑主攻/集结。

## 2. 核心模型

### 2.1 角色枚举（唯一真相）

```gdscript
enum Role { IDLE, SCOUT, GARRISON, WALL, HOME_GUARD, RESOURCE_GUARD,
            BUILDING_DEFENSE, HARASS, RAID, FIELD, SIEGE, TRANSPORT, ESCORT, RETREAT }
```

单位身上**只写一个** meta：`ai_role`（整数，便于调试面板/日志）。
其余旧 meta 全部退役（`ai_home_guard / ai_wall_guard / ai_harass / ai_rallied /
ai_resource_guard / ai_building_defense_until / ai_stalled_attack`）。

### 2.2 账本（AI 侧，唯一数据源）

```gdscript
var _roles: Dictionary = {}   # uid -> {role:int, since:float, lease_until:float, target:Vector3}
```

- `assign(unit, role, target, lease_s)`：写账本 + meta + 下单。
- `release(unit, reason)`：清账本 + meta + `hold_position` + `_garrison_target_id` + 黑名单，回到 idle 池。
- **所有调度器只能通过这两个函数改角色，禁止直接 write meta。**

### 2.3 租约（lease）——解决"卡死"的根本手段

| 角色 | 租约 | 续期/释放条件 |
|---|---|---|
| SCOUT | 30 s | 到达/死亡 |
| GARRISON | 20 s | 进塔成功 / 超时释放 |
| WALL | 墙存在即续 | 墙被拆 / 单位死亡 |
| HOME_GUARD | 60 s | 威胁解除（60 s 复审） |
| RESOURCE_GUARD | 45 s | 资源区无威胁 |
| BUILDING_DEFENSE | 20 s | 建筑不再挨打 |
| HARASS | 32 s | 到期 / 目标死亡 |
| RAID | 45 s | 到期 / 到达侧翼 |
| FIELD | 命令结束 | 命令结束 → **立即**回 idle 池 |
| RETREAT | 8 s | 回到主城 |

**关键不变量**：租约到期 = 角色失效 = 单位回到 idle 池 = **同一 tick 内**被重新分配。
所以"卡在半路"最多持续一个租约周期，不会永久。

### 2.4 单一入口

```gdscript
func _tick_director(delta):        # 0.5 s 一次
    _sync_registry()               # 清理死亡/换主/新建单位
    _expire_leases()               # 到期角色回收进 idle 池
    _collect_busy_and_idle()       # busy = 有命令/有目标/有队列/在驻军/在船上
    var demand := _build_demands() # 当前局面需要什么（唯一决策点）
    _fill_demands(demand)          # 按优先级从 idle 池取人
    _standby_fallback()            # 兜底：池子必须清空
```

### 2.5 需求表（替代散落的分支）

```gdscript
# 由当前局面（威胁/阶段/兵力/资源）生成，全部集中在 _build_demands()
{role=WALL,       budget=槽位数,       pick=_is_ranged_wall_candidate, order=move+hold}
{role=GARRISON,   budget=塔内空位,      pick=_is_garrisonable,          order=garrison}
{role=HOME_GUARD, budget=5(+威胁*2),    pick=any,                       order=move(集结环)}
{role=RESOURCE_GUARD, budget=资源区数,  pick=any,                        order=attack_move}
{role=FIELD,      budget=999,           pick=any,                       order=attack_move(敌主城)}
{role=HARASS,     budget=3,             pick=高机动,                    order=attack_move(外围农民)}
{role=RAID,       budget=10,            pick=any,                       order=move(侧翼)}
```

**优先级（抢占用）**：
```
RETREAT 100 > BUILDING_DEFENSE 90 > HOME_GUARD 80 > WALL 70 > GARRISON 60
        > RESOURCE_GUARD 50 > HARASS/RAID 40 > FIELD 20 > IDLE 0
```
- 只有"高优先级需求名额未满"才能拿走 **IDLE** 单位；
- **正在执行命令的单位不可抢占**（唯一例外：RETREAT / BUILDING_DEFENSE）；
- 同优先级先到先得，名额满就不再遍历。

### 2.6 阶段不再分散判断

`_build_demands()` 里用 `phase / threat_level / 军队总数 / 是否被压制` 决定这张表：
- PRODUCTION：WALL/GARRISON 优先，无 FIELD（但 idle 兜底仍是"驻守集结点"，不是干站）；
- DEVELOPMENT：WALL/GARRISON/HOME_GUARD + FIELD（门槛用**总陆军数**，不是余数）；
- ASSAULT：FIELD 名额放开，HOME_GUARD 降到 3；
- 威胁 ≥2：HOME_GUARD 提到 6~18，FIELD 暂停但已出门的单位保留命令（不强行召回）。

### 2.7 指标解耦

- `count_land_army()`：**全部**本方陆军战斗单位（含守军/守墙/骚扰），用作主攻门槛；
- `count_by_role(role)`：账本直接统计，用于日志/UI；
- 不再有"扣除角色后的野战军"这种会随分配抖动的指标。

## 3. 验收指标（重构后必须复测）

| 指标 | 现状 | 目标 |
|---|---|---|
| AI 战斗单位 idle+无目标占比 | ~19.7%（t=480） | **< 8%** |
| 离家 <25 m 的 idle 占比 | ~20% | **< 5%** |
| 主攻/推进占比（交战+推进） | ~63% | **> 70%** |
| 卡死在 transport/garrison 预约的单位 | 存在 | **0**（租约保证） |
| 每个 AI 的角色分布可解释 | 不可观测 | 每 5 s 一行 `[DIRECTOR]` 日志 |

## 4. 迁移计划（4 步，每步可独立提交/回滚）

1. **安全网**：加 `_roles` 账本 + `assign/release` + 0.5 s tick 的 boundary 兜底
   （只把"无角色且 idle"的单位统一派到集结点）。不动现有调度器 → 立刻消掉死锁与站桩。
2. **收编防务类**：守家、驻军、守墙、资源守卫改成 demand（行为等价，去掉 8 份重复过滤）。
3. **收编进攻类**：主攻、骚扰、突袭、集结改成 demand；门槛改用 `count_land_army()`。
4. **清理**：删旧函数（`_manage_home_guard/_quick_fill_home_guard/_deploy_ranged_units_to_walls/
   `_ai_garrison_soldiers/_rally_land_army_to_castle/attack_move/execute_harass/raid/overwhelm/
   `_retask_idle_front_units`）、删旧 meta 读写、接入 `[DIRECTOR]` 日志。

## 5. 待定（需要确认）

- **A. 抢占边界**：行军/交战中是否允许被高威胁召回？（建议：只允许 RETREAT/BUILDING_DEFENSE）
- **B. 兜底去向**：idle 兜底是"回集结点"还是"就地待命"？（建议：集结点，便于观察和二次投入）
- **C. 编制**：是否让 director 决定兵种配比（前排/远程），还是继续由生产线按兵种计数造？
- **D. 范围**：只单机 AI（AI.gd + AIDefense.gd），还是同步接联机 AI（OnlineBattleManager）？

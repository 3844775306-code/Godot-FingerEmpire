# scripts/ai/AI.gd
# Merged AI Controller — single-player + online dual-mode
extends Node

class_name AIController

const AIDefenseScript = preload("res://scripts/ai/AIDefense.gd")
const AIWaterCrossingScript = preload("res://scripts/ai/AIWaterCrossing.gd")
const AIWallPlannerScript = preload("res://scripts/ai/AIWallPlanner.gd")
const AILadderSiegeScript = preload("res://scripts/ai/AILadderSiege.gd")
const AIWorkerDirectorScript = preload("res://scripts/ai/AIWorkerDirector.gd")

enum Phase { PRODUCTION, DEVELOPMENT, ASSAULT }
enum LateTactic { NONE, HARASS, OVERWHELM, RAID, DEFEND }

@onready var battle = get_parent()

var phase: int = Phase.PRODUCTION
var timer: float = 0.0
var think_interval: float = 2.0  # overridden by difficulty in _ready
var _decide_cost_scale: float = 1.0  # decide 实测耗时过长时自动拉长间隔（硬件/规模自适应）
# decide() 内部是十几个 O(实体数) 的阶段。整段一次跑完在 600+ 实体时实测单帧
# 200~500ms，就是玩家看到的「隔几秒一顿」。这里把它拆成阶段，每帧只跑固定预算，
# 剩余阶段留给后续帧，把单帧峰值摊平（总工作量不变，但不再整段堵住主线程）。
const DECIDE_BUDGET_USEC: int = 7000
const DECIDE_LAST_STEP: int = 14
var _decide_cursor: int = 0        # 下次要执行的阶段；> LAST 表示本轮结束
var _decide_running: bool = false
var _decide_interval: float = 2.0
var _decide_start_usec: int = 0
var _decide_step_usec: Array = []  # 各阶段耗时，用于定位真正的热点
var _think_ready: bool = false    # 难度对应的思考间隔只初始化一次
var worker_allocate_timer: float = 0.0
const WORKER_ALLOCATE_INTERVAL: float = 3.0
var last_attack_time: float = -999.0
const ATTACK_COOLDOWN: float = 120.0
var production_step: int = 0

var wanted_buildings: Array = [20, 21, 29, 23, 42, 54, 24, 52, 53]
var wanted_units: Array = [11,12,15,16,17,18,35,36,37,38,39,40,13,43,44,45,46,47,48,49,50,58,59,5,6,9]
var target_army_count: int = 7
# 旧逻辑用「每个兵种 7 个」当军队目标；可生产兵种少时总兵力只能到 7~28。
# 这里额外给一个总野战军目标，按当前可生产兵种均分，保证 3 倍速 5 分钟能到 50 左右。
const TARGET_FIELD_ARMY_TOTAL: int = 50
# 贸易车只跟随这四种商人；AI 生产贸易车时数量必须小于商人数量，避免刷出一堆闲置车
const TRADE_CART_ID: int = 6
# 官员/商人由各自的生产逻辑管理（官员一栋建筑只能一个），
# 不能像战斗单位一样按 target_army_count 反复补。否则书院升级后
# AI 会把大量官员当普通兵排队生产，最终一堆官员没有建筑可进驻。
const SUPPORT_UNIT_IDS: Array = [43, 44, 45, 46, 47, 48, 49, 50, 51]
const MERCHANT_UNIT_IDS: Array = [43, 44, 45, 51]
# 民居数量上限：第 X 分钟至少 X 座（X 最多 8），提前一分钟开工保证到点时已建成
const HOUSE_TARGET_MAX: int = 8
const HOUSE_BUILD_LEAD_MINUTES: int = 1
# 战役 AI 的总建筑软上限：避免后期把基地铺成上百座建筑，既堵路又拖慢战斗。
const CAMPAIGN_AI_BUILDING_CAP: int = 50
var target_house_count: int = HOUSE_TARGET_MAX
var desired_worker_count: int = 8
var _resource_pressure_time: float = 0.0
# 最近一次“泄压但买不起”的阻塞原因，便于面板/日志定位是金、木还是食物不足。
var _last_spend_block: String = ""
var _last_spend_block_time: float = -999.0
var _last_emergency_rebalance_time: float = -999.0
var _last_wall_sink_time: float = -999.0
var _stone_share_timer: float = 0.0

# ═══ 资源溢出治理 ═══
# 旧逻辑里军队/建筑都有固定上限（每兵种 7 个、民居 8 座、兵营 3 座…），
# 但资源上限会随主城等级和仓库不断增加；中后期采集中队把资源顶到上限后，
# 继续交资源会被 add_resource 直接截断，等于白采。下面几个阈值用于在资源
# 接近满仓时主动把多余资源转成军队、人口和建筑升级，而不是继续囤着。
const RESOURCE_PRESSURE_RATIO: float = 0.85      # 任一资源达到上限 85% 即开始泄压
const RESOURCE_PRESSURE_GRACE: float = 10.0       # 连续高水位 10 秒才进入泄压，避开开局初始资源
const RESOURCE_CRITICAL_RATIO: float = 0.97      # 接近满仓，允许一次多排几个兵
const RESOURCE_PRESSURE_EXTRA_ARMY: int = 4      # 泄压时每个兵种额外允许的数量
const RESOURCE_PRESSURE_EXTRA_HOUSES: int = 4    # 人口满时额外补的民居数
const RESOURCE_PRESSURE_TRAIN_BURST: int = 2     # 最紧张时一次决策最多多排几个兵

var cached_shipyard_pos: Vector3 = Vector3.ZERO
var defense_line_built: bool = false
var defense_check_timer: float = 0.0
var defense_initialized: bool = false   # 防线位置已规划（进入分批建造阶段）
var _defense_queue: Array = []          # 待建防线队列：[{"id": 建筑id, "pos": 位置}]
const DEFENSE_CHECK_INTERVAL: float = 120.0
const DEFENSE_STEP_MAX: int = 3         # 每个 think tick 至多尝试建造的防线建筑数
var _defense = null                      # AIDefense 模块：威胁/防线/守军/资源区
var _wall_planner = null                 # AIWallPlanner 模块：城墙施工顺序/墙顶炮选点
var _water_crossing = null               # AIWaterCrossing 模块：搭桥/运载船渡水
var _ladder_siege = null                 # AILadderSiege 模块：造梯子翻越敌方城墙
var _worker_director = null              # WorkerDirector 模块：农民只读账本（第 1 阶段）
var _harass_ids: Dictionary = {}         # 当前骚扰小队 instance_id -> true
var _harass_until: float = -999.0        # 骚扰小队回收时间
var _upgrade_cycle_timer: float = 20.0   # 每20秒切换
var _in_upgrade_cycle: bool = true     # 前20秒为升级周期
var _castle_rush_done: Array = [false, false, false]  # 3/6/10min castle rush
var wall_positions: Array = []
var tower_positions: Array = []
var current_tactic: int = LateTactic.NONE
const TACTIC_COOLDOWN: float = 25.0
var last_tactic_time: float = -999.0
var nation = -1

var _ai_income_timer: float = 10.0
var _last_delta: float = 2.0
var _ai_res_snapshot: Dictionary = {}
var _ai_res_income: Dictionary = {}
var _ai_income_rate: Dictionary = {"gold":0,"wood":0,"stone":0,"food":0,"oil":0}
var _territory_timer: float = 120.0
var _hunt_timer: float = 0.0
var _hunt_target = null
var _hunt_target_id: int = -1
var _visible_enemies: Array = []  # enemies visible to AI (refreshed each think cycle)

# ═══ 侦察兵探图 ═══
# AI 不读取玩家的 explored_grid，而是用自己的可见掩码维护一份“AI 已探索”网格。
# 探测目标按 4 格步长采样，只在 think 周期执行，避免每帧扫全图。
const SCOUT_ID: int = 19
const SCOUT_TARGET_COUNT: int = 1
const SCOUT_START_DELAY: float = 60.0
const SCOUT_RETRY_AFTER_DEATH: float = 15.0
const SCOUT_RETARGET_SEC: float = 14.0
const SCOUT_ARRIVE_DIST: float = 3.0
const SCOUT_SCAN_STEP: int = 4
const SCOUT_FRONTIER_RADIUS: int = 6
const SCOUT_BLACKLIST_SEC: float = 45.0
const SCOUT_THREAT_RADIUS: float = 9.0
const SCOUT_RETREAT_HEALTH_RATIO: float = 0.35
const SCOUT_RETREAT_SEC: float = 8.0
var _scout_explored: PackedByteArray = PackedByteArray()
var _scout_next_produce_at: float = 0.0
var _scout_blacklist: Dictionary = {}  # Vector2i -> 可再次选中的 game_time

var my_peer_id: int = -1
var my_team: int = RTSConfig.Team.RED
var _primary_enemy_owner: int = -1   # 乱斗 FFA 主敌国家 owner_peer_id（每 think 刷新；-1=未确定/非乱斗）

# ── 乱斗 FFA 外交状态 ──（仅 _diplo_enabled() 时使用）
var _diplo_last_decide: float = -999.0      # 上次外交决策 game_time
var _diplo_propose_target: int = -1         # 我方提案等待中的目标 owner；-1=无
var _diplo_propose_at: float = -1.0         # 发起提案时的 game_time
var _diplo_last_propose_time: float = -999.0  # 上次发起提案的 game_time（最小间隔）
var _diplo_last_tribute_time: float = -999.0  # 上次进贡续期的 game_time（最小间隔）
var _diplo_propose_history: Dictionary = {} # owner -> game_time（冷却期内不重复骚扰同一国家）

# AI 队友向真人玩家进贡：多人 2v2/3v3 时玩家不需要开口，AI 会按固定节奏补资源。
const TRIBUTE_ALLY_INTERVAL: float = 20.0
const TRIBUTE_ALLY_MAX_AMOUNT: int = 300
const TRIBUTE_ALLY_MIN_AMOUNT: int = 100
const TRIBUTE_ALLY_SOURCE_RATIO: float = 0.70
const TRIBUTE_ALLY_TARGET_RATIO: float = 0.65
var _tribute_to_human_timer: float = 0.0

const WAREHOUSE_MAX_COUNT: int = 5
const HOME_ASSEMBLE_RANGE: float = 50.0
# 新版重装武器厂(29)只有在4级才会解锁巨型投石机(59)。
# 以前 29 排在建/升级队列很后面，且 59 没有独立生产目标，实战里几乎见不到。
# 这里把 29 提前，并让 AI 主动攒资源造一台 59。
const MILITARY_PRODUCER_TARGETS = {21: 3, 24: 2, 29: 1}
const TREBUCHET_ID: int = 59
const HEAVY_SIEGE_BUILDING_ID: int = 29
const TREBUCHET_TARGET_COUNT: int = 1
const TREBUCHET_SAVE_TIMEOUT: float = 90.0
const HEAVY_SIEGE_TECH_SAVE_TIMEOUT: float = 180.0
var _trebuchet_save_started: float = -1.0
var _heavy_siege_tech_save_started: float = -1.0
# 科研模式：升时代不再按固定时间点，改为每 30 秒检查一次“现在能不能升”，
# 条件齐备时立刻开始；这里只负责在差资源时锁住时代预算。
var _research_age_reserve_stamp: int = -1
var _research_age_reserve_value: Dictionary = {}
# 石油通常位于水域中央，船坞只要建在能出海的水岸即可，不必紧贴油田；
# 该半径用于判断水岸是否可服务油田，以及已建船坞是否仍值得保留。
const SHIPYARD_OIL_REACH: float = 32.0
const SHIPYARD_SPACING: float = 35.0
const SHIPYARD_FISHER_RADIUS: float = 15.0
var built_shipyard_pos: Array[Vector3] = []

const RAID_MIN_SPECIAL_TROOPS: int = 3
const RAID_FLANK_MIN: float = 28.0
const RAID_FLANK_MAX: float = 46.0
const RAID_WAIT_TIME: float = 5.0
const AVOID_DEFENSE_RANGE: float = 22.0
const RAID_UNIT: int = 15
const WALL_COUNT: int = 24            # 旧版连续墙线的段数上限
# AIDefense 的封闭塔圈要绕主城一整圈，旧的 24 段上限会在圆圈上留下缺口，
# 这里单独放宽城墙/墙顶炮台的实际上限；旧版防线仍只规划 WALL_COUNT 段。
const WALL_COUNT_MAX: int = 160
# 主城 3/4/5 级（或封建/城堡/帝国）会各扩建一圈城墙，
# 单圈上限之外还需要容纳三层圈的总墙数。
const WALL_BUILD_CAP_AI: int = 420
const WALL_SPACING: float = 1.3       # 旧版直线防线间距（build_defense_line 仍在用）
const WALL_STEP: float = 1.5          # 连续墙线的中心距：必须 < 墙直径 2.0，段段重叠才不留缝
const WALL_MAX_HALF_SPAN: float = 11.0  # 墙线从正中向两侧各延伸的最大距离
# 远程单位上墙：墙未破时只吃远程伤害，近战必须先拆墙，因此优先把闲置远程兵铺到墙格上；
# 每面城墙独立选择“墙顶炮台”或“远程驻军”，赶路中的单位用 ai_wall_guard 预留墙格。
const WALL_DEPLOY_INTERVAL: float = 10.0
# 前线闲兵补派间隔：待命单位大多是攻击命令结束后无人重新派单，2 秒补一次足够
const RETASK_IDLE_INTERVAL: float = 2.0
const WALL_DEPLOY_MAX_DISTANCE: float = 60.0
const WALL_CANNON_ID: int = 64
const WALL_GUARD_MODE_META: String = "ai_wall_guard_mode"
const WALL_GUARD_TARGET_META: String = "ai_wall_guard_target"
const WALL_GUARD_SMALL_META: String = "ai_wall_guard_small"
const WALL_GUARD_SLOT_META: String = "ai_wall_guard_slot"
const WALL_GUARD_POS_META: String = "ai_wall_guard_pos"
const WALL_GUARD_SMALL_BODY: float = 0.5
var _wall_deploy_timer: float = 0.0
var _retask_timer: float = 0.0
# 防御建筑驻军：AI 会把部分闲置士兵/农民送进箭塔、炮塔和城堡，
# 让它们吃到多子弹齐射加成，而不是只在塔外站着。
const GARRISON_CHECK_INTERVAL: float = 4.0
const GARRISON_TOWER_WANT: int = 1
const GARRISON_CASTLE_WANT: int = 2
const GARRISON_TOWER_WANT_DEFEND: int = 3
const GARRISON_CASTLE_WANT_DEFEND: int = 4
const GARRISON_MAX_DISTANCE: float = 42.0
var _garrison_timer: float = 0.0
var defense_wall_axis: Vector3 = Vector3.RIGHT
const TOWER_SPACING: float = 3.0
const DEFENSE_FRONT_DIST: float = 8.0
const BUILD_ENEMY_ARMY_SAFE_RADIUS: float = 10.0
const SAFE_DEFEND_RADIUS: float = 45.0
const LAND_RALLY_DISTANCE: float = 12.0
const LAND_RALLY_INTERVAL: float = 8.0
var _land_rally_timer: float = 0.0
const NAVAL_PATROL_INTERVAL: float = 15.0
var _naval_patrol_timer: float = 0.0
# 船坞水域是否值得造战船：只有连通水域靠近敌方沿岸建筑/敌方战船才算军事水域。
# 结果按船坞缓存，避免每次生产决策都从船坞做一次水域洪泛。
const NAVAL_VALUE_RECHECK: float = 8.0
const NAVAL_VALUE_BFS_LIMIT: int = 6000
const NAVAL_VALUE_BUILDING_RANGE: float = 18.0
const NAVAL_VALUE_CASTLE_RANGE: float = 55.0
var _naval_value_cache: Dictionary = {}
# 闲置战船可以猎鱼补食物，但必须给鱼群留够繁殖数量；每次巡逻最多按
# “当前鱼数 - 保留数”派出猎手，避免几艘船把整片水域的鱼一次清空。
const NAVAL_MIN_FISH_POPULATION: int = 5
const NAVAL_FISH_ATTACK_RANGE: float = 32.0
# 非攻城部队打建筑时若被敌方部队偷袭，要尽快回头；独立于 decide 的 1 秒扫描，
# 避免 AI 思考间隔 1.5~2 秒时部队一直挨打拆墙。
const RETARGET_CHECK_INTERVAL: float = 1.0
const RETARGET_MEMORY: float = 3.0
const RETARGET_MAX_DIST: float = 22.0
var _retarget_timer: float = 0.0

# ── 建筑修理（AI 也会修残破建筑）──
# 修理机制本身在 Building 内实现：按已损比例扣费 + 计时，主城(20/53)不可修；
# 玩家可在敌军旁边强行修理，AI 则会避开附近 10 米内有敌方部队的建筑。
# AI 侧只负责「什么时候修、先修哪座、别把造兵的钱花光」这层决策：
#   · 每 REPAIR_SCAN_INTERVAL 扫一次自己的建筑，不每帧遍历；
#   · 同时最多 REPAIR_MAX_CONCURRENT 座、每轮最多新开 REPAIR_MAX_START_PER_SCAN 座；
#   · 付款后每种资源仍要 >= 储备阈值（见 _repair_reserve），避免经济被修理拖死；
#   · 排序按建筑重要度 × 受损程度，出兵/防守建筑优先，民居最后。
const REPAIR_SCAN_INTERVAL: float = 2.5        # AI 扫描可修建筑的间隔（秒）
const REPAIR_MAX_CONCURRENT: int = 2           # 同时进行中的修理工程上限
const REPAIR_MAX_START_PER_SCAN: int = 1       # 每轮扫描最多新开工数量
const REPAIR_EARLY_GAME_SECONDS: float = 60.0  # 开局这段时间不修（先把农民与经济铺开）
const REPAIR_MIN_DAMAGE: float = 0.10          # 已损低于该比例不值得修
# 建筑重要度权重：出兵/防守建筑优先，民居最后（主城不在表内，can_repair() 已排除）
const REPAIR_WEIGHT = {
	21: 1.35,  # 兵营
	24: 1.30,  # 攻城车间
	29: 1.35,  # 重装武器厂
	25: 1.20,  # 箭塔
	26: 1.20,  # 炮塔
	64: 1.15,  # 墙顶炮台
	27: 1.10,  # 城墙
	42: 1.00,  # 书院
	54: 1.00,  # 修道院
	52: 0.95,  # 集市
	23: 0.95,  # 船坞
	22: 0.90,  # 仓库
	28: 0.75,  # 民居
}
var _repair_scan_timer: float = 0.0

# ── 升时代建筑补齐 ──
# 升时代不只要求人口，还要求若干“已建成建筑”。普通建造目标只覆盖出兵/经济建筑，
# 像黑暗时代必需的瞭望塔(41)不在 wanted_buildings 里，AI 会一直差建筑。
# 每 30 秒同时检查一次：缺建筑就补建筑；条件齐备就直接开始升时代。
const AGE_BUILDING_CHECK_INTERVAL: float = 30.0
var _age_building_check_timer: float = AGE_BUILDING_CHECK_INTERVAL

# ═══ Resource wrappers ═══
func _get_resources() -> Dictionary:
	if my_peer_id != -1:
		if battle is OnlineBattleManager:
			return battle.player_resources.get(my_peer_id, {})
		if battle.has_method("get_resources_for"):
			return battle.get_resources_for(my_peer_id)
	return battle.enemy_resources

func _get_limits() -> Dictionary:
	if my_peer_id != -1:
		if battle is OnlineBattleManager:
			return battle.player_limits_dict.get(my_peer_id, {})
		if battle.has_method("get_limits_for"):
			return battle.get_limits_for(my_peer_id)
	return battle.enemy_resource_limits

func _get_population() -> Dictionary:
	if my_peer_id != -1:
		if battle is OnlineBattleManager:
			return battle.player_population.get(my_peer_id, {"current":0,"max":30})
		if battle.has_method("get_population_for"):
			return battle.get_population_for(my_peer_id)
	return {"current": battle.enemy_pop, "max": battle.enemy_max_pop}

func _can_train_unit() -> bool:
	if my_peer_id != -1:
		if battle is OnlineBattleManager:
			return battle.can_player_train(my_peer_id)
		if battle.has_method("can_train_for"):
			return battle.can_train_for(my_peer_id)
	return battle.can_train_unit(my_team)

# 生产队列不会立刻增加人口，只有真正 spawn 时才 +1。普通补兵按当前人口
# 判断会在排队阶段重复超编；泄压时一次多排几个更容易把人口顶爆。
# 这里把“已存活 + 已排队”一起算，保证不会排到人口上限之外。
func _queued_unit_count() -> int:
	var total: int = 0
	for entity in _cached_buildings():
		if entity is Building and is_instance_valid(entity) and entity_belongs_to_me(entity):
			total += entity.production_queue.size()
	return total

func _can_train_unit_with_queue() -> bool:
	if not _can_train_unit():
		return false
	var pop: Dictionary = _get_population()
	return int(pop.get("current", 0)) + _queued_unit_count() < int(pop.get("max", 0))

func _resource_ratio(rk: String) -> float:
	var lim: float = float(_get_limits().get(rk, 0))
	if lim <= 0.0:
		return 0.0
	return float(_get_resources().get(rk, 0)) / lim

func _resource_pressure_ratio() -> float:
	var best: float = 0.0
	for rk in ["gold", "wood", "stone", "food", "oil"]:
		best = maxf(best, _resource_ratio(rk))
	return best

# 快速模式采集 3 倍、建造/生产只有 2 倍，水位阈值必须提前，否则收入先顶满。
func _pressure_threshold() -> float:
	var t: float = RESOURCE_PRESSURE_RATIO
	if GameSettings.fast_mode:
		t -= 0.10
	return clampf(t, 0.70, 0.90)

func _resource_overflow() -> bool:
	return _resource_pressure_time >= RESOURCE_PRESSURE_GRACE \
			and _resource_pressure_ratio() >= _pressure_threshold()

func _resource_critical() -> bool:
	return _resource_pressure_time >= RESOURCE_PRESSURE_GRACE \
			and _resource_pressure_ratio() >= RESOURCE_CRITICAL_RATIO

# 食物是唯一同时卡农民和战斗兵的资源：农民 50 食物，步兵 70、骑兵 90。
# 只按总资源压力判断时，木/石满仓会掩盖食物见底，AI 会一直补农民/建筑却不出兵。
func _food_emergency() -> bool:
	if battle == null:
		return false
	var food: int = int(_get_resources().get("food", 0))
	return food < 120 and _resource_ratio("food") < 0.25

# 开局 AI 的金/木/粮就是满的（500/500），但这是给建造序列用的启动资金。
# 连续高水位一小段时间仍花不出去，才说明真的在浪费收入，此时再泄压。
func _update_resource_pressure(delta: float) -> void:
	if _resource_pressure_ratio() >= _pressure_threshold():
		_resource_pressure_time += maxf(delta, 0.0)
	else:
		_resource_pressure_time = 0.0

# 资源堆积时临时放宽每兵种数量上限，避免“每个兵种都 7 个”之后军队停止增长。
# 实战里还出现过四资源顶满、人口 83/100、目标仍为 7 的情况：资源没溢出时
# 只按固定值补兵，人口空着也不花。这里在进入中后期或资源偏高时按人口缺口
# 抬高目标，真正把收入转成人口和兵力。
func _effective_army_target() -> int:
	var target: int = target_army_count
	var pop: Dictionary = _get_population()
	var free_pop: int = maxi(0, int(pop.get("max", 0)) - int(pop.get("current", 0)))
	var mid_game: bool = battle != null and battle.game_time >= 120.0
	if free_pop > 2 and (mid_game or _resource_pressure_ratio() >= 0.60):
		# 快速模式收入更高，人口缺口要更积极转成军队，否则资源顶满、兵却停涨。
		var free_cap: int = 24 if GameSettings.fast_mode else 10
		target = maxi(target, target_army_count + mini(free_pop - 2, free_cap))
	if _resource_overflow():
		var extra: int = RESOURCE_PRESSURE_EXTRA_ARMY
		if _resource_critical():
			extra += RESOURCE_PRESSURE_EXTRA_ARMY
		target = maxi(target, target_army_count + extra)
		# 有资源、有人口时至少把一半人口转成军队，避免只造到固定 17 个就停手。
		target = maxi(target, int(float(pop.get("max", 0)) * 0.5))
	return target

# 陆战兵种：排除农民、手推车、侦察兵、运载船/战船和辅助单位。
func _is_land_combat_unit(u_id: int) -> bool:
	if u_id in [10, 5, 6, 9, 13, 19, 39, 40] or u_id in SUPPORT_UNIT_IDS:
		return false
	var cfg = EntityDatabase.get_config(u_id)
	if cfg.is_empty():
		return false
	if bool(cfg.get("water_capable", false)):
		return false
	return int(cfg.get("target_type", 0)) > 0

func _land_combat_type_count() -> int:
	var n: int = 0
	for u_id in get_counter_priority():
		if _is_land_combat_unit(int(u_id)):
			n += 1
	return maxi(1, n)

# 单个兵种的数量目标：普通兵种继续按 7 个补，但总野战军要能到 50。
# 只有 1 种兵可用时步兵目标就是 50；有 4 种兵时每种约 13 个。
func _field_army_target_for(u_id: int) -> int:
	var base: int = _effective_army_target()
	if not _is_land_combat_unit(u_id):
		return base
	var types: int = _land_combat_type_count()
	return maxi(base, int(ceil(float(TARGET_FIELD_ARMY_TOTAL) / float(types))))

# 人口已满而资源还多时，先补额外民居，否则多出来的资源无处转化为军队。
# 不一定非要“溢出”：人口接近上限且资源已经超过 60% 时就应继续补房，
# 否则会出现“人口 90/90、资源 1700/2300、军队目标掉回 7”的中期停摆。
func _effective_house_target() -> int:
	var pop: Dictionary = _get_population()
	var current: int = int(pop.get("current", 0))
	var max_pop: int = int(pop.get("max", 0))
	var near_cap: bool = max_pop > 0 and current >= max_pop - 2
	if not _resource_overflow():
		if near_cap and _resource_pressure_ratio() >= 0.60:
			return maxi(target_house_count, HOUSE_TARGET_MAX + RESOURCE_PRESSURE_EXTRA_HOUSES)
		return target_house_count
	if current < max_pop - 2:
		return target_house_count
	return maxi(target_house_count, HOUSE_TARGET_MAX + RESOURCE_PRESSURE_EXTRA_HOUSES)

# 兵营造满后如果资源仍然堆积，多补几个生产建筑把资源转成兵力。
func _effective_producer_target(b_id: int) -> int:
	var target: int = int(MILITARY_PRODUCER_TARGETS.get(b_id, 1))
	# 科研模式的升时代有硬性建筑要求。普通建造目标只保证“有 1 座”，
	# 到帝国时代却需要 2 座城堡（53）；这里单独抬高目标，否则 AI 永远差建筑。
	target = maxi(target, _research_age_required_building_target(b_id))
	if not _resource_overflow():
		return target
	if b_id == 21:
		target += 2
	elif b_id == 24 or b_id == 29:
		target += 1
	return target

# 当前科研时代升级还缺哪些建筑。返回值只负责“数量目标”，
# 具体科技解锁仍由 _ai_can_build()/建造队列判断。
func _research_age_required_building_target(b_id: int) -> int:
	if battle == null or not battle.has_method("is_research_mode") or not battle.is_research_mode():
		return 0
	var st: Dictionary = battle.get_research_state(my_peer_id, my_team)
	if st.is_empty():
		return 0
	# 封建时代(age=1)升城堡时代(age=2)的硬性条件是 3 座封建建筑；
	# 普通建筑目标已覆盖（攻城车间/集市/修道院等），无需额外抬高。
	# 城堡时代(age=2)升帝国时代(age=3)要求 4 座城堡建筑且至少 2 座城堡(53)。
	if int(st.get("age", 0)) == 2 and b_id == 53:
		return 2
	return 0

# ── 升时代建筑条件兜底 ──
# 升时代要求的是“已建成建筑”，普通建造目标不会主动补瞭望塔(41)这类条件建筑。
# 每 30 秒按当前时代的目标建筑清单检查一次，缺什么补什么；建造目标本身仍受
# 资源、城堡等级、地图空间和时代预留限制，不会为了凑数把时代预算花光。
func _ensure_age_upgrade_buildings() -> void:
	if battle == null or not battle.has_method("is_research_mode") or not battle.is_research_mode():
		return
	var st: Dictionary = battle.get_research_state(my_peer_id, my_team)
	if st.is_empty():
		return
	var age: int = int(st.get("age", 0))
	if age >= 3:
		return
	if get_peer_castle(my_peer_id) == null:
		return
	match age + 1:
		1:
			_ensure_age1_required_buildings()
		2:
			_ensure_age2_required_buildings()
		3:
			_ensure_age3_required_buildings()

# age1：2 座 [兵营(21)/瞭望塔(41)]。AI 的普通目标只造兵营，经常没有瞭望塔。
func _ensure_age1_required_buildings() -> void:
	for _attempt in range(2):
		var info: Dictionary = _age_building_counts([21, 41])
		var counts: Dictionary = info["counts"]
		var b21: int = int(counts.get(21, 0))
		var b41: int = int(counts.get(41, 0))
		if int(info["total"]) >= 2:
			return
		# 升时代只认“已完成建筑”。如果地基已经拍下但农民被杀/被调走，建筑会永久停工；
		# 旧逻辑把地基也算进数量，于是 AI 会一直以为条件已满足，永远不补建。
		if not _age_pending_buildings([21, 41]).is_empty():
			_ensure_age_pending_builders([21, 41])
			return
		var candidates: Array = []
		if b21 >= 1 and b41 == 0:
			# 已有兵营时优先补瞭望塔；若塔的位置被占，退回再造一座兵营。
			candidates = [41, 21]
		else:
			candidates = [21, 41]
		var built: bool = false
		for bid in candidates:
			if _try_build_age_requirement(int(bid)):
				built = true
				break
		if not built:
			return

# age2：3 座 [船坞/攻城车间/箭塔/集市/修道院]，且至少 2 种类型。
func _ensure_age2_required_buildings() -> void:
	var ids: Array = [23, 24, 25, 52, 54]
	var priority: Array = [24, 52, 54, 25, 23]
	for _attempt in range(3):
		var info: Dictionary = _age_building_counts(ids)
		var counts: Dictionary = info["counts"]
		if int(info["total"]) >= 3 and int(info["types"]) >= 2:
			return
		if not _age_pending_buildings(ids).is_empty():
			_ensure_age_pending_builders(ids)
			return
		var candidates: Array = []
		# 先补“完全没有的类型”，避免 3 座全是攻城车间却凑不出 2 种类型。
		if int(info["types"]) < 2:
			for bid in priority:
				if int(counts.get(int(bid), 0)) == 0:
					candidates.append(int(bid))
		for bid in priority:
			if int(counts.get(int(bid), 0)) < 2 and int(bid) not in candidates:
				candidates.append(int(bid))
		var built: bool = false
		for bid in candidates:
			if _try_build_age_requirement(int(bid)):
				built = true
				break
		if not built:
			return

# age3：4 座 [炮塔/重装武器厂/书院/城堡/墙顶炮台]，且至少 2 座城堡(53)。
func _ensure_age3_required_buildings() -> void:
	var ids: Array = [26, 29, 42, 53, 64]
	var priority: Array = [29, 42, 26, 64]
	for _attempt in range(4):
		var info: Dictionary = _age_building_counts(ids)
		var counts: Dictionary = info["counts"]
		if int(info["total"]) >= 4 and int(counts.get(53, 0)) >= 2:
			return
		if not _age_pending_buildings(ids).is_empty():
			_ensure_age_pending_builders(ids)
			return
		var candidates: Array = []
		if int(counts.get(53, 0)) < 2:
			candidates.append(53)
		for bid in priority:
			if int(counts.get(int(bid), 0)) == 0:
				candidates.append(int(bid))
		for bid in priority:
			if int(counts.get(int(bid), 0)) < 2 and int(bid) not in candidates:
				candidates.append(int(bid))
		var built: bool = false
		for bid in candidates:
			if _try_build_age_requirement(int(bid)):
				built = true
				break
		if not built:
			return

# 只统计已完成的时代条件建筑（建造中的地基不能算数）。
func _age_building_counts(ids: Array) -> Dictionary:
	var counts: Dictionary = {}
	var total: int = 0
	var types: int = 0
	for b in _cached_buildings():
		if not is_instance_valid(b) or b.health <= 0 or b.build_timer > 0.0:
			continue
		if not (b.entity_id in ids) or not entity_belongs_to_me(b):
			continue
		counts[b.entity_id] = int(counts.get(b.entity_id, 0)) + 1
		total += 1
	for bid in ids:
		if int(counts.get(int(bid), 0)) > 0:
			types += 1
	return {"counts": counts, "total": total, "types": types}

# 当前正在建造、且属于升时代条件的己方建筑。
func _age_pending_buildings(ids: Array) -> Array:
	var out: Array = []
	for b in _cached_buildings():
		if not is_instance_valid(b) or b.health <= 0 or b.build_timer <= 0.0:
			continue
		if b.entity_id in ids and entity_belongs_to_me(b):
			out.append(b)
	return out

# 给停工的地基补派农民，避免“地基永远建不完、条件永远差一座”。
func _ensure_age_pending_builders(ids: Array) -> int:
	var assigned: int = 0
	if battle == null or not battle.has_method("assign_builders"):
		return assigned
	for b in _age_pending_buildings(ids):
		if int(b.get("builder_count_cache")) <= 0 or bool(b.get("awaiting_builder")):
			if battle.assign_builders(b, []) > 0:
				assigned += 1
	return assigned

func _try_build_age_requirement(building_id: int) -> bool:
	if not _ai_can_build(building_id):
		return false
	if not can_afford_building(building_id):
		return false
	var pos: Vector3 = Vector3.ZERO
	# 瞭望塔是视野建筑，升时代补建筑时也不能在主城周围随机拍；
	# 让 AIDefense 按新增视野/敌军来路选一个真正有用的位置。
	if building_id == 41 and _defense != null \
			and _defense.has_method("find_watchtower_build_position"):
		pos = _defense.find_watchtower_build_position(get_peer_castle(my_peer_id))
	if pos == Vector3.ZERO:
		pos = _get_build_position(building_id)
	if pos == Vector3.ZERO:
		return false
	return build_building(building_id, pos)

func _deduct_resources(cost: Dictionary) -> bool:
	if my_peer_id != -1:
		if battle is OnlineBattleManager:
			return battle.deduct_player_resources(my_peer_id, cost)
		if battle.has_method("deduct_resources_for"):
			return battle.deduct_resources_for(my_peer_id, cost)
	var res = battle.enemy_resources
	for k in cost:
		if res[k] < cost[k]: return false
	for k in cost:
		res[k] -= cost[k]
	return true

func entity_belongs_to_me(entity: GameEntity) -> bool:
	if my_peer_id != -1: return entity.owner_peer_id == my_peer_id
	return entity.team == my_team

# ═══ Nation ═══
func _add_nation_special_unit():
	if battle is OnlineBattleManager:
		nation = battle.player_info.get(my_peer_id, {}).get("nation", -1)
	elif battle.ai_players.has(my_peer_id):
		nation = battle.ai_players[my_peer_id].get("nation", GameSettings.enemy_nation)
	else:
		nation = GameSettings.enemy_nation
	if nation < 0: return
	NationData._static_init()
	var special_units = NationData.NATION_UNITS.get(nation, [])
	for unit_data in special_units:
		var uid = unit_data["unit_id"]
		if uid != 10 and uid not in wanted_units:
			wanted_units.append(uid)

# ═══ Counting ═══
# 统一走 battle 的实体缓存，避免每个统计函数都把 entities 子节点全扫一遍。
func _ensure_battle_cache() -> void:
	if battle and battle.has_method("_ensure_cache_fresh"):
		battle._ensure_cache_fresh()

func _cached_armies() -> Array:
	_ensure_battle_cache()
	return battle._armies

func _cached_buildings() -> Array:
	_ensure_battle_cache()
	return battle._buildings

func _is_scout_unit(entity) -> bool:
	return entity is Army and int(entity.entity_id) == SCOUT_ID

func count_unit(id: int, include_queue: bool = true) -> int:
	var cnt = 0
	# Count existing units
	for entity in _cached_armies():
		if not is_instance_valid(entity) or entity.health <= 0:
			continue
		if entity.entity_id == id:
			if my_peer_id != -1 and entity.owner_peer_id != my_peer_id: continue
			if my_peer_id == -1 and entity.team != my_team: continue
			cnt += 1
	# Count units in production queues（决策用；面板统计传 false，避免把队列当成已存在单位）
	if include_queue:
		for entity in _cached_buildings():
			if not is_instance_valid(entity) or entity.health <= 0:
				continue
			if my_peer_id != -1 and entity.owner_peer_id != my_peer_id: continue
			if my_peer_id == -1 and entity.team != my_team: continue
			for pid in entity.production_queue:
				if pid == id: cnt += 1
	return cnt

# 商人总数（含生产队列）；贸易车数量必须严格小于该值
func _count_merchants() -> int:
	var total: int = 0
	for mid in MERCHANT_UNIT_IDS:
		total += count_unit(mid)
	return total

func count_building(id: int) -> int:
	var cnt = 0
	for entity in _cached_buildings():
		if not is_instance_valid(entity) or entity.health <= 0:
			continue
		if entity.entity_id == id:
			if my_peer_id != -1 and entity.owner_peer_id != my_peer_id: continue
			if my_peer_id == -1 and entity.team != my_team: continue
			cnt += 1
	return cnt

# 战役 AI 的总建筑数（不计城墙/梯子/墙顶炮台，这些有独立上限）
func _campaign_ai_building_count() -> int:
	var cnt := 0
	for entity in _cached_buildings():
		if not is_instance_valid(entity) or entity.health <= 0:
			continue
		if not entity_belongs_to_me(entity):
			continue
		if int(entity.entity_id) in [8, 27, WALL_CANNON_ID]:
			continue
		cnt += 1
	return cnt

func count_military(peer: int) -> int:
	var total = 0
	for entity in _cached_armies():
		if not is_instance_valid(entity) or entity.health <= 0:
			continue
		if my_peer_id != -1 and entity.owner_peer_id != peer: continue
		if my_peer_id == -1 and entity.team != peer: continue
		if entity.entity_id != 10 and entity.entity_id != 14 and entity.entity_id not in [43,44,45,46,47,48,49,50,51]:
			total += 1
	# Count queued military units in production
	for entity in _cached_buildings():
		if not is_instance_valid(entity) or entity.health <= 0:
			continue
		if my_peer_id != -1 and entity.owner_peer_id != peer: continue
		if my_peer_id == -1 and entity.team != peer: continue
		for pid in entity.production_queue:
			if pid != 10 and pid != 14 and pid not in [43,44,45,46,47,48,49,50,51]:
				total += 1
	return total

# 可出击的野战军：只统计活着、当前没有防守/驻扎/守墙/骚扰/运输角色的陆军战斗单位。
# 主攻和进攻阶段不能直接用 count_military()：后者包含生产队列、主城守军和守墙兵，
# 会出现“账面 30 人，实际能出门的只有几个”的假兵力。
func count_field_military(peer: int) -> int:
	var total = 0
	for entity in _cached_armies():
		if not is_instance_valid(entity) or entity.health <= 0:
			continue
		if my_peer_id != -1 and entity.owner_peer_id != peer: continue
		if my_peer_id == -1 and entity.team != peer: continue
		if int(entity.target_type) <= 0: continue
		if entity.entity_id in [10,14,43,44,45,46,47,48,49,50,51]: continue
		# 侦察兵由探图逻辑单独调度，不能算作可出击主攻兵力。
		if _is_scout_unit(entity): continue
		# 海军由 AIWaterCrossing / 船坞逻辑单独调度，不能算作陆地主攻兵力。
		if entity.water_capable: continue
		if entity.has_meta("ai_home_guard") or entity.has_meta("ai_resource_guard") or entity.has_meta("ai_harass") or entity.has_meta("ai_wall_guard"):
			continue
		if entity.has_meta("ai_transporting"): continue
		if _is_held_by_garrison(entity): continue
		total += 1
	return total

# 全部本方陆军战斗单位（含守军/守墙/骚扰/驻军/待命），只排除农民、侦察兵和海军。
# 主攻门槛必须用这个口径：旧的 count_field_military 扣掉所有角色，守军一多野战兵就变少，
# 于是越强越不敢打，和守军抓人形成自锁（详见 docs/AI_ARMY_DISPATCH_DESIGN.md）。
func count_land_army() -> int:
	var n: int = 0
	for e in _cached_armies():
		if not is_instance_valid(e) or e.health <= 0:
			continue
		if not entity_belongs_to_me(e):
			continue
		if int(e.entity_id) == 10 or int(e.attack) <= 0:
			continue
		if _is_scout_unit(e) or bool(e.water_capable):
			continue
		n += 1
	return n

func count_military_by_team(tm: int) -> int:
	var total = 0
	for entity in _cached_armies():
		if not is_instance_valid(entity) or entity.health <= 0:
			continue
		if entity.team != tm: continue
		if entity.entity_id != 10 and entity.entity_id != 14 and entity.entity_id not in [43,44,45,46,47,48,49,50,51]:
			total += 1
	# Count queued military units in production
	for entity in _cached_buildings():
		if not is_instance_valid(entity) or entity.health <= 0:
			continue
		if entity.team != tm: continue
		for pid in entity.production_queue:
			if pid != 10 and pid != 14 and pid not in [43,44,45,46,47,48,49,50,51]:
				total += 1
	return total
# Check if any AI unit can see this entity
func _is_visible_to_ai(target: GameEntity) -> bool:
	if battle != null and battle.has_method("is_position_visible_to_team"):
		return battle.is_position_visible_to_team(my_team, target.global_position)
	for e in battle.entities.get_children():
		if e is GameEntity and e.health > 0:
			if my_peer_id != -1 and e.owner_peer_id != my_peer_id: continue
			if my_peer_id == -1 and e.team != my_team: continue
			var vision: float = float(e.vision_range)
			# 用实际有效视野（地图倍率、高地、森林遮蔽），而不是裸视野半径
			if battle.has_method("get_effective_vision"):
				vision = float(battle.get_effective_vision(e))
			if e.global_position.distance_to(target.global_position) <= vision:
				return true
	return false

# Refresh visible enemies cache (called once per think cycle)
func _refresh_visibility():
	_visible_enemies.clear()
	# 先缓存己方视野源，避免对每个敌人重复全实体扫描和重复计算有效视野
	var sources: Array = []
	var scout_sources: Array = []
	for own in battle.entities.get_children():
		if not (own is GameEntity) or own.health <= 0:
			continue
		if not entity_belongs_to_me(own):
			continue
		var vision: float = float(own.vision_range)
		if battle.has_method("get_effective_vision"):
			vision = float(battle.get_effective_vision(own))
		var source: Array = [own.global_position, vision]
		sources.append(source)
		# 侦察兵通常孤军深入，不能在后期的视野源抽样里被裁掉，否则探到的敌人
		# 不会进入 AI 的可见敌军缓存。
		if _is_scout_unit(own):
			scout_sources.append(source)
	if sources.is_empty():
		return
	# 后期每个 AI 可能有上百个单位，若每个单位都作为视野源查询一次，
	# 4 个 AI 每轮会做数百次空间查询。按 12×12 区域每格保留一个代表，
	# 再做上限截断，既保持全图视野覆盖，又避免重复查询同一片区域。
	if sources.size() > 24:
		var by_cell: Dictionary = {}
		for s in sources:
			var key := Vector2i(int(floor((s[0] as Vector3).x / 12.0)), int(floor((s[0] as Vector3).z / 12.0)))
			if not by_cell.has(key):
				by_cell[key] = s
			elif float(s[1]) > float(by_cell[key][1]):
				by_cell[key] = s
		sources = by_cell.values()
		if sources.size() > 64:
			var sampled: Array = []
			var step: float = float(sources.size()) / 64.0
			for i in 64:
				sampled.append(sources[int(i * step)])
			sources = sampled
	# 抽样后把没有被附近代表覆盖的侦察兵补回来（通常只有 1 个，查询成本可忽略）。
	for s in scout_sources:
		var covered: bool = false
		for t in sources:
			if (t[0] as Vector3).distance_squared_to(s[0] as Vector3) <= 36.0:
				covered = true
				break
		if not covered:
			sources.append(s)
	# 有空间索引时按视野源查询附近敌军并去重，避免“己方单位数 × 全图敌人数”的
	# 双重循环；没有 battle 空间索引时保留原来的全量扫描兜底。
	if battle.has_method("get_nearby_enemies"):
		var seen: Dictionary = {}
		for s in sources:
			for e in battle.get_nearby_enemies(s[0], float(s[1]), my_team, my_peer_id, true):
				if not (e is GameEntity) or e.health <= 0: continue
				if entity_belongs_to_me(e): continue
				if e is WorldResource: continue
				var eid: int = e.get_instance_id()
				if seen.has(eid): continue
				seen[eid] = true
				_visible_enemies.append(e)
		return
	for e in battle.entities.get_children():
		if not (e is GameEntity): continue
		if e.health <= 0: continue
		if entity_belongs_to_me(e): continue
		if e is WorldResource: continue
		var ep: Vector3 = e.global_position
		for s in sources:
			if (s[0] as Vector3).distance_to(ep) <= float(s[1]):
				_visible_enemies.append(e)
				break

# Check if an entity is in the visible enemies cache
func _is_visible_enemy(entity: GameEntity) -> bool:
	return entity in _visible_enemies

# ═══ 侦察兵探图 ═══
func _ensure_scout_explored() -> void:
	var need: int = int(RTSConfig.MAP_SIZE) * int(RTSConfig.MAP_SIZE)
	if _scout_explored.size() != need:
		_scout_explored.resize(need)
		_scout_explored.fill(0)

# 只把 AI 自己队伍的可见格写进探索记录；不读取玩家的 explored_grid。
func _mark_scout_explored() -> void:
	if battle == null or not battle.has_method("get_team_visible_mask"):
		return
	var mask: PackedByteArray = battle.get_team_visible_mask(my_team)
	if mask.size() != _scout_explored.size():
		return
	for i in range(mask.size()):
		if mask[i] != 0:
			_scout_explored[i] = 1

func _scout_cell_explored(gx: int, gy: int) -> bool:
	var ms: int = int(RTSConfig.MAP_SIZE)
	if gx < 0 or gy < 0 or gx >= ms or gy >= ms:
		return true
	var idx: int = gx * ms + gy
	return idx >= 0 and idx < _scout_explored.size() and _scout_explored[idx] != 0

func _scout_tile_walkable(gx: int, gy: int) -> bool:
	if battle == null or not battle.has_method("get_terrain_at_grid"):
		return false
	var terrain: int = int(battle.get_terrain_at_grid(gx, gy))
	if terrain < 0 or terrain == 2:
		return false
	if terrain == 1:
		# 普通山壁不可通行；只有缓坡(4)/山顶台地(5)能上陆军。
		var overlay: int = int(battle.get_overlay_at_grid(gx, gy))
		if overlay != 4 and overlay != 5:
			return false
	return true

func _scout_is_frontier(gx: int, gy: int) -> bool:
	var r: int = SCOUT_FRONTIER_RADIUS
	for dx in [-r, 0, r]:
		for dy in [-r, 0, r]:
			if dx == 0 and dy == 0:
				continue
			if _scout_cell_explored(gx + dx, gy + dy):
				return true
	return false

func _scout_blacklisted(gx: int, gy: int) -> bool:
	if battle == null:
		return false
	var key := Vector2i(gx, gy)
	return _scout_blacklist.has(key) and float(battle.game_time) < float(_scout_blacklist[key])

# 选离侦察兵最近、且处在已探索边缘的未探索陆地格。
func _pick_scout_target(scout) -> Vector3:
	if battle == null:
		return Vector3.ZERO
	var ms: int = int(RTSConfig.MAP_SIZE)
	var castle = get_peer_castle(my_peer_id)
	var base_pos: Vector3 = castle.global_position if castle != null else Vector3.ZERO
	var best := Vector3.ZERO
	var best_found: bool = false
	var best_score: float = INF
	var step: int = SCOUT_SCAN_STEP
	var threat_sq: float = (SCOUT_THREAT_RADIUS * 2.0) * (SCOUT_THREAT_RADIUS * 2.0)
	for gx in range(2, ms - 2, step):
		for gy in range(2, ms - 2, step):
			if _scout_cell_explored(gx, gy):
				continue
			if _scout_blacklisted(gx, gy):
				continue
			if not _scout_tile_walkable(gx, gy):
				continue
			if not _scout_is_frontier(gx, gy):
				continue
			var pos: Vector3 = battle.grid_to_world(gx, gy)
			var score: float = scout.global_position.distance_squared_to(pos)
			if castle != null:
				score += base_pos.distance_squared_to(pos) * 0.05
			# 避开当前看得见的敌军，别让侦察兵直接撞上去。
			for e in _visible_enemies:
				if not (e is Army) or e.health <= 0:
					continue
				if e.global_position.distance_squared_to(pos) <= threat_sq:
					score += 4000.0
			if score < best_score:
				best_score = score
				best = pos
				best_found = true
	if not best_found:
		return _scout_fallback_target()
	# 地图中心 (0,0,0) 与“无目标”的哨兵值重合，偏移半米避免被当成未分配。
	return best if best != Vector3.ZERO else Vector3(0.5, 0.0, 0.0)

# 全图探索完后的巡逻点：停在敌方主城外侧或自家城堡外，继续当移动视野。
func _scout_fallback_target() -> Vector3:
	var castle = get_peer_castle(my_peer_id)
	var enemy = _get_attack_target_castle()
	if enemy != null and is_instance_valid(enemy) and castle != null:
		var back: Vector3 = castle.global_position - enemy.global_position
		if back.length() > 1.0:
			return enemy.global_position + back.normalized() * 22.0
		return enemy.global_position + Vector3(22.0, 0, 0)
	if castle != null:
		return castle.global_position + Vector3(10.0, 0, 10.0)
	return Vector3.ZERO

func _scout_enemy_near(pos: Vector3) -> bool:
	var r_sq: float = SCOUT_THREAT_RADIUS * SCOUT_THREAT_RADIUS
	for e in _visible_enemies:
		if not (e is Army) or e.health <= 0:
			continue
		if e.global_position.distance_squared_to(pos) <= r_sq:
			return true
	return false

# 战役进攻关开局调用：按 AIDefense 的地形塔圈规划，预置一整圈外围城墙与防御塔。
func prebuild_campaign_defense(castle, threat_dir: Vector3) -> bool:
	if battle == null or castle == null or not is_instance_valid(castle):
		return false
	if _defense == null:
		_defense = AIDefenseScript.new(self)
	return _defense.prebuild_campaign_castle_ring(castle, threat_dir)

# 每个 think 周期调用：更新探索记录，并给侦察兵分配下一个前沿目标。
func _process_scout_recon() -> void:
	if battle == null:
		return
	var scouts: Array = []
	for entity in _cached_armies():
		if not is_instance_valid(entity) or entity.health <= 0:
			continue
		if not entity_belongs_to_me(entity) or not _is_scout_unit(entity):
			continue
		scouts.append(entity)
	if scouts.is_empty():
		return
	_ensure_scout_explored()
	_mark_scout_explored()
	var now: float = float(battle.game_time)
	for key in _scout_blacklist.keys():
		if now >= float(_scout_blacklist[key]):
			_scout_blacklist.erase(key)
	var castle = get_peer_castle(my_peer_id)
	for entity in scouts:
		if not is_instance_valid(entity) or entity.health <= 0:
			continue
		if not entity.has_meta("ai_scout"):
			entity.set_meta("ai_scout", true)
		var retreat_until: float = float(entity.get_meta("ai_scout_retreat_until", -1.0))
		if now < retreat_until:
			continue
		var health_ratio: float = entity.health / maxf(entity.max_health, 1.0)
		if castle != null and (health_ratio < SCOUT_RETREAT_HEALTH_RATIO or _scout_enemy_near(entity.global_position)):
			if entity.current_order != "" or entity.current_target != null or entity.is_attack_moving:
				entity.stop_movement()
			var away: Vector3 = castle.global_position - entity.global_position
			if away.length() < 1.0:
				away = Vector3(1.0, 0.0, 1.0)
			entity.set_meta("ai_scout_retreat_until", now + SCOUT_RETREAT_SEC)
			entity.move_to(castle.global_position + away.normalized() * 6.0)
			continue
		var target: Vector3 = entity.get_meta("ai_scout_target", Vector3.ZERO)
		var target_time: float = float(entity.get_meta("ai_scout_target_time", -999.0))
		var reached: bool = target != Vector3.ZERO \
			and entity.global_position.distance_to(target) <= SCOUT_ARRIVE_DIST
		var expired: bool = target == Vector3.ZERO or now - target_time >= SCOUT_RETARGET_SEC
		var idle: bool = entity.current_order == "" and entity.current_target == null and not entity.is_attack_moving
		var stuck_idle: bool = idle and target != Vector3.ZERO and now - target_time >= 3.0
		if not (reached or expired or stuck_idle):
			continue
		if target != Vector3.ZERO and not reached and stuck_idle:
			# 只有真正卡住/走不到的目标才拉黑；单纯“14 秒还没走到”不拉黑，
			# 否则大地图上距离较远的前沿会被误判成不可达。
			_scout_blacklist[battle.world_to_grid(target)] = now + SCOUT_BLACKLIST_SEC
		if entity.current_order != "" or entity.current_target != null or entity.is_attack_moving:
			entity.stop_movement()
		var next_target: Vector3 = _pick_scout_target(entity)
		if next_target == Vector3.ZERO:
			entity.remove_meta("ai_scout_target")
			continue
		entity.set_meta("ai_scout_target", next_target)
		entity.set_meta("ai_scout_target_time", now)
		entity.move_to(next_target)


# ═══ Economy ═══
func _ai_can_build(building_id: int) -> bool:
	if battle != null and battle.has_method("is_research_mode") and battle.is_research_mode():
		if battle.has_method("is_building_unlocked"):
			return battle.is_building_unlocked(building_id, my_peer_id, my_team)
	var cl = 0
	var castle = get_peer_castle(my_peer_id)
	if castle: cl = castle.upgrade_level
	match building_id:
		23, 25, 26, 64:  # 船坞、箭塔、炮塔、墙顶炮台 → 城堡2级
			return cl >= 2
		24, 29, 52:   # 攻城车间、重装武器厂、集市 → 城堡3级
			return cl >= 3
		53, 54:   # 城堡、修道院 → 主城4级
			return cl >= 4
		42:   # 书院→3级
			return cl >= 3
	return true

# ═══ 巨型投石机专线 ═══
# AI 以前的兵种列表里虽然有 59，但缺少“科技 + 攒钱 + 优先生产”的完整链路：
# 重装武器厂(29)要升到4级才会解锁，升级又需要城堡4级和大量石/油；
# 同时普通军队会持续吃掉资源，导致 59 永远差一点资源。
# 下面几个函数负责：优先把 29 推到4级、解锁后暂停普通消费攒钱、最后优先排产 59。

func _find_own_building(building_id: int) -> Building:
	for entity in battle.entities.get_children():
		if entity is Building and entity.health > 0 and entity.entity_id == building_id and entity_belongs_to_me(entity):
			return entity
	return null

func _trebuchet_pending() -> bool:
	return count_unit(TREBUCHET_ID) < TREBUCHET_TARGET_COUNT

func _trebuchet_unlocked() -> bool:
	for entity in battle.entities.get_children():
		if entity is Building and entity.health > 0 and entity.build_timer <= 0 and entity.entity_id == HEAVY_SIEGE_BUILDING_ID and entity_belongs_to_me(entity):
			if entity.upgrade_level >= 4:
				return true
	return false

# 解锁 59 之后，如果普通生产继续花钱，就永远凑不齐 200木/250石/150金。
# 这里在解锁后进入短暂的“攒钱模式”：除 59 本身外，其他消费都要求扣完后仍能支付 59。
# 防守或人口已满时不启用，避免 AI 为了憋投石机而不补兵/不造民居。
func _trebuchet_reserve_active() -> bool:
	if not _trebuchet_pending():
		_trebuchet_save_started = -1.0
		return false
	if not _trebuchet_unlocked():
		return false
	if not _can_train_unit():
		return false
	if _is_defending():
		return false
	if battle == null:
		return false
	if _trebuchet_save_started < 0.0:
		_trebuchet_save_started = battle.game_time
	if battle.game_time - _trebuchet_save_started > TREBUCHET_SAVE_TIMEOUT:
		_trebuchet_save_started = -1.0
		return false
	return true

func _can_pay_with_trebuchet_reserve(cost: Dictionary) -> bool:
	var tcfg = EntityDatabase.get_config(TREBUCHET_ID)
	if not tcfg:
		return true
	return _can_pay_with_reserve(cost, tcfg.get("cost", {}))

func _can_pay_with_reserve(cost: Dictionary, reserve_cost: Dictionary) -> bool:
	var res = _get_resources()
	for k in cost:
		if int(res.get(k, 0)) - int(cost[k]) < int(reserve_cost.get(k, 0)):
			return false
	return true

# 29 的升级和“城堡等级追上 29”都消耗大量石/油/金。
# 29 一落地就开始留这段预算，否则普通升级/重装兵会把资源反复花掉，
# AI 永远卡在“差一点就能升29”的状态。
func _heavy_siege_tech_reserve_cost() -> Dictionary:
	if not _trebuchet_pending():
		return {}
	if _trebuchet_unlocked():
		return {}
	var b29 = _find_own_building(HEAVY_SIEGE_BUILDING_ID)
	if b29 == null or b29.upgrade_level >= 4:
		return {}
	var castle = get_peer_castle(my_peer_id)
	if castle == null:
		return {}
	if castle.upgrade_level < 4:
		if castle.upgrade_level <= b29.upgrade_level:
			return castle.get_upgrade_cost()
		return {}
	return b29.get_upgrade_cost()

func _heavy_siege_tech_reserve_active() -> bool:
	if _is_defending():
		return false
	var cost = _heavy_siege_tech_reserve_cost()
	if cost.is_empty():
		_heavy_siege_tech_save_started = -1.0
		return false
	if battle == null:
		return false
	if _heavy_siege_tech_save_started < 0.0:
		_heavy_siege_tech_save_started = battle.game_time
	if battle.game_time - _heavy_siege_tech_save_started > HEAVY_SIEGE_TECH_SAVE_TIMEOUT:
		_heavy_siege_tech_save_started = -1.0
		return false
	return true

func _try_produce_trebuchet() -> bool:
	if not _trebuchet_pending():
		return false
	if not _trebuchet_unlocked():
		return false
	if not _can_train_unit():
		return false
	if not can_afford(TREBUCHET_ID):
		return false
	if produce_unit(TREBUCHET_ID):
		_trebuchet_save_started = -1.0
		return true
	return false

# 重装武器厂4级需要城堡4级；城堡等级不够时先升城堡，够了一级一级升 29。
func _ensure_heavy_siege_tech() -> bool:
	if not _trebuchet_pending():
		return false
	var b29: Building = null
	for entity in battle.entities.get_children():
		if entity is Building and entity.health > 0 and entity.entity_id == HEAVY_SIEGE_BUILDING_ID and entity_belongs_to_me(entity):
			if b29 == null or int(entity.upgrade_level) > int(b29.upgrade_level):
				b29 = entity
	if b29 == null or b29.upgrade_level >= 4:
		return false
	var castle = get_peer_castle(my_peer_id)
	if castle == null:
		return false
	if castle.upgrade_level <= b29.upgrade_level:
		if can_afford_upgrade(20):
			upgrade_building(20)
			_heavy_siege_tech_save_started = -1.0
			return true
		return false
	for entity in battle.entities.get_children():
		if entity is Building and entity.health > 0 and entity.build_timer <= 0 and entity.entity_id == HEAVY_SIEGE_BUILDING_ID and entity_belongs_to_me(entity):
			if entity.upgrade_level < 4 and entity.can_upgrade():
				if entity.perform_upgrade(battle):
					_heavy_siege_tech_save_started = -1.0
					return true
	return false

func can_afford(unit_id: int) -> bool:
	var cfg = EntityDatabase.get_config(unit_id)
	if not cfg: return false
	var cost = cfg.get("cost", {})
	var res = _get_resources()
	for k in cost: if res.get(k, 0) < cost[k]: return false
	if _research_age_reserve_active() and not _can_pay_with_reserve(cost, _research_age_reserve_cost()):
		return false
	if unit_id != TREBUCHET_ID and _trebuchet_reserve_active():
		return _can_pay_with_trebuchet_reserve(cost)
	if unit_id != TREBUCHET_ID and _heavy_siege_tech_reserve_active():
		return _can_pay_with_reserve(cost, _heavy_siege_tech_reserve_cost())
	return true

func can_afford_building(building_id: int) -> bool:
	var cfg = EntityDatabase.get_config(building_id)
	if not cfg: return false
	var cost = cfg.get("cost", {})
	var res = _get_resources()
	for k in cost: if res.get(k, 0) < cost[k]: return false
	if _research_age_reserve_active() and not _can_pay_with_reserve(cost, _research_age_reserve_cost()):
		return false
	if _trebuchet_reserve_active():
		return _can_pay_with_trebuchet_reserve(cost)
	if _heavy_siege_tech_reserve_active():
		return _can_pay_with_reserve(cost, _heavy_siege_tech_reserve_cost())
	return true

func can_afford_upgrade(building_id: int) -> bool:
	for entity in battle.entities.get_children():
		if entity is Building and entity.health > 0 and entity.entity_id == building_id:
			if not entity_belongs_to_me(entity): continue
			if entity.can_upgrade():
				if entity.entity_id != 20:
					var castle = get_peer_castle(my_peer_id)
					if castle and entity.upgrade_level >= castle.upgrade_level:
						continue
				var cost = entity.get_upgrade_cost()
				var res = _get_resources()
				for k in cost: if res.get(k, 0) < cost[k]: return false
				if _research_age_reserve_active() and not _can_pay_with_reserve(cost, _research_age_reserve_cost()):
					return false
				if _trebuchet_reserve_active():
					return _can_pay_with_trebuchet_reserve(cost)
				if building_id != HEAVY_SIEGE_BUILDING_ID and building_id != 20 and _heavy_siege_tech_reserve_active():
					return _can_pay_with_reserve(cost, _heavy_siege_tech_reserve_cost())
				return true
	return false

# ═══ Production ═══
func produce_unit(unit_id: int) -> bool:
	if battle != null and battle.has_method("is_research_mode") and battle.is_research_mode():
		if battle.has_method("is_unit_unlocked") and not battle.is_unit_unlocked(unit_id, my_peer_id, my_team):
			return false
	# 所有生产入口都统一走 can_afford，确保升时代攒预算不会被某个直接调用绕过。
	if not can_afford(unit_id):
		return false
	# 贸易车没有商人可跟就是废单位；生产时严格保证“车 < 商人”
	if unit_id == 33 and count_unit(33) >= 2:
		return false
	if unit_id == TRADE_CART_ID and count_unit(TRADE_CART_ID) >= _count_merchants():
		return false

	var produced = 0
	for entity in battle.entities.get_children():
		if produced >= 1: break
		if entity is Building and entity.health > 0 and entity.build_timer <= 0:
			if not entity_belongs_to_me(entity): continue
			if entity.try_produce(unit_id):
				produced += 1
	return produced > 0

# 建造前安全检查：10 单位内存在敌方作战军队时不允许落建筑，
# 避免 AI 当着敌军的面拍塔/拍民居，刚建好就被拆。
func _enemy_army_within(pos: Vector3, radius: float = BUILD_ENEMY_ARMY_SAFE_RADIUS) -> bool:
	if battle == null:
		return false
	for e in battle.get_nearby_entities(pos, radius):
		if not (e is Army) or e.health <= 0:
			continue
		if int(e.target_type) <= 0 and float(e.attack) <= 0.0:
			continue
		if _entity_is_enemy(e):
			return true
	return false

# 基地是否正在挨打：只看城堡 15 米内是否已经有"真正有威胁的"敌军。
# 不能直接用 _defense.threat_level：六 AI 混战时它经常全局 >=2，
# 会把所有主攻永久取消，导致 AI 只守不攻、双方僵持。
# 也不能只按"有没有敌人"算：实测敌方一个侦察兵路过城堡 15 米，就会让整个 AI
# 在整局里再也不敢出主攻（420 秒里 4~6 个 AI 几乎每帧都是"家被打"）。
# 现在的门槛：最近的真实战斗单位 < 8 米，或者 15 米内至少有 2 个真实战斗单位。
func _base_under_attack() -> bool:
	if battle == null:
		return false
	var castle = get_peer_castle(my_peer_id)
	if castle == null:
		return false
	var count: int = 0
	var nearest: float = 999.0
	for e in battle.get_nearby_entities(castle.global_position, 15.0):
		if not (e is Army) or e.health <= 0:
			continue
		if int(e.target_type) <= 0 and float(e.attack) <= 0.0:
			continue
		if int(e.entity_id) == 10 or _is_scout_unit(e):
			continue
		if not _entity_is_enemy(e):
			continue
		count += 1
		nearest = minf(nearest, castle.global_position.distance_to(e.global_position))
	return nearest < 8.0 or count >= 2

# 最终落位校验：AI 的所有建造入口（随机仓库、防线规划、补建队列）都必须过这一关，
# 防止建筑重叠、建到水面/山坡上，或直接压住资源点。
func _can_place_ai_building(building_id: int, pos: Vector3) -> bool:
	var half = RTSConfig.MAP_SIZE / 2.0
	var gx = int(round(pos.x + half))
	var gz = int(round(pos.z + half))
	if gx < 0 or gx >= RTSConfig.MAP_SIZE or gz < 0 or gz >= RTSConfig.MAP_SIZE:
		return false
	# 建筑有体积：中心格在地图内还不够，建筑边缘也不能超出地图，
	# 否则贴边造出来的建筑会有半截漂在地图外面。
	var cfg_edge = EntityDatabase.get_config(building_id)
	var br_edge: float = maxf(0.5, float(cfg_edge.get("body_radius", 1.0))) if cfg_edge else 1.0
	# 服务端会把建筑放大 2 倍（部分特殊建筑除外），这里的半径要按放大后的算
	if building_id not in [41, 27, 64, 7, 8, 25, 26]:
		br_edge *= 2.0
	var edge_limit: float = half - br_edge - 0.5
	# 城墙是封口建筑：允许贴到地图最外圈（中心距边界 1 格），
	# 否则墙圈两端只能停在边界内 1.5 格外，敌人能沿着地图边缘绕过墙头。
	# 墙直径 2 米，贴边放置时模型边缘正好压在地图边界上，不会悬空。
	if building_id == 27:
		edge_limit = half - br_edge
	if pos.x < -edge_limit or pos.x > edge_limit or pos.z < -edge_limit or pos.z > edge_limit:
		return false
	# 桥只能建在水上，使用战斗管理器与玩家共用的选址校验
	if building_id == 7:
		if battle.has_method("is_valid_bridge_position"):
			return battle.is_valid_bridge_position(pos)
		return false
	var terrain = battle.get_terrain_at_grid(gx, gz)
	if terrain == 2:
		return false
	# 船坞：必须放在陆地且至少邻接一格水面
	if building_id == 23:
		if terrain != 0:
			return false
		var water_adj = 0
		for dx in [-1, 0, 1]:
			for dz in [-1, 0, 1]:
				if dx == 0 and dz == 0: continue
				if battle.get_terrain_at_grid(gx + dx, gz + dz) == 2:
					water_adj += 1
		if water_adj < 1:
			return false
	else:
		if terrain != 0:
			return false
		var cfg_t = EntityDatabase.get_config(building_id)
		var br_t = float(cfg_t.get("body_radius", 1.0)) if cfg_t else 1.0
		if battle.has_method("_is_terrain_flat") and not battle._is_terrain_flat(pos, maxf(0.5, br_t * 0.5)):
			return false
	var cfg = EntityDatabase.get_config(building_id)
	if not cfg: return false
	var radius = maxf(0.5, float(cfg.get("body_radius", 1.0)))
	# 炮台墙顶专用：必须落在己方完整城墙上；它与所依附的城墙允许重叠。
	var wall_only: bool = building_id == WALL_CANNON_ID
	if wall_only:
		var on_own_wall := false
		for e in battle.entities.get_children():
			if e is Building and e.entity_id == 27 and e.health > 0 and e.build_timer <= 0.0 \
					and entity_belongs_to_me(e):
				if e.global_position.distance_to(pos) < e.body_radius + 0.2:
					on_own_wall = true
					break
		if not on_own_wall:
			return false
	# 与所有存活建筑/资源点做实际体积相交检测；单位可以移动，不在这里卡建造
	for e in battle.entities.get_children():
		if not (e is Building or e is WorldResource) or e.health <= 0: continue
		# 炮台本来就该压在墙顶上，不能把所依附的城墙当成重叠障碍。
		if wall_only and e is Building and e.entity_id == 27 and entity_belongs_to_me(e):
			continue
		var other_radius = maxf(0.3, float(e.body_radius))
		var min_dist = radius + other_radius + 0.15
		# 城墙本来就是首尾相接的连续墙段，允许墙与墙贴紧；
		# 墙也要能贴着己方的塔/建筑收口，否则每个塔位前后两格都建不起来，
		# 整条墙线正好在塔的位置裂开，敌人从缺口直插主城。
		if building_id == 27 and e is Building and e.entity_id == 27:
			min_dist = 0.9
		elif building_id == 27 and e is Building:
			min_dist = 1.6
		if e.global_position.distance_to(pos) < min_dist:
			return false
	return true

func _bridge_wood_reserve() -> int:
	if _water_crossing == null or not _water_crossing.has_pending_bridge():
		return 0
	var bridge_cfg = EntityDatabase.get_config(7)
	if not bridge_cfg:
		return 0
	return int(bridge_cfg.get("cost", {}).get("wood", 0))

# 梯子攻城专用建造入口：不能走普通建筑的“敌军 10 米内禁止落建筑”规则，
# 因为梯子本来就要贴着敌方城墙造；改为要求附近有己方野战部队掩护，
# 并且必须通过 RTSBattleManager 的裸露敌墙校验。
func build_ladder(pos: Vector3) -> bool:
	var cfg = EntityDatabase.get_config(8)
	if not cfg:
		return false
	if not _ai_can_build(8):
		return false
	if battle.has_method("is_training_building_allowed") and not battle.is_training_building_allowed(8):
		return false
	# 同一波进攻最多保留两把梯子；被拆后由 AILadderSiege 冷却重试。
	if count_building(8) >= 2:
		return false
	if not can_afford_building(8):
		return false
	if battle.has_method("is_valid_ladder_position"):
		if not battle.is_valid_ladder_position(pos, my_team):
			return false
	else:
		return false
	# 墙边至少要有几名野战单位掩护，避免农民单独跑到敌墙下送死。
	if _ladder_support_count(pos, 22.0) < 4:
		return false
	var builder = battle.find_nearest_idle_builder(my_team, my_peer_id, pos, 70.0) \
			if battle.has_method("find_nearest_idle_builder") else null
	if builder == null:
		return false
	if _water_crossing != null and not _water_crossing.can_builder_reach(builder.global_position, pos):
		return false
	var cost = cfg.get("cost", {})
	if not _deduct_resources(cost):
		return false
	cfg["owner_peer_id"] = my_peer_id
	var team: int = my_team
	if my_peer_id != -1:
		if battle is OnlineBattleManager:
			team = battle.player_info[my_peer_id].team
		else:
			team = my_team
	var b = battle.spawn_entity(cfg, team, pos) as Building
	if b == null:
		return false
	# 梯子模型很薄，必须让梯面垂直于墙、薄边朝向墙体，否则横向卡进墙里。
	# 同时把梯子中心向墙外挪 0.12 米，避免模型厚度与墙面重叠。
	var wall_dir := Vector3.ZERO
	for e in battle._buildings:
		if not is_instance_valid(e) or not (e is Building) or e.health <= 0:
			continue
		if int(e.entity_id) != 27 or e.team == team:
			continue
		if e.global_position.distance_to(b.global_position) <= 2.0:
			wall_dir = e.global_position - b.global_position
			wall_dir.y = 0.0
			break
	if wall_dir.length_squared() > 0.001:
		wall_dir = wall_dir.normalized()
		# 局部 +Z 是梯子薄边方向；绕 Y 旋转到墙体方向即可贴墙。
		b.rotation.y = atan2(wall_dir.x, wall_dir.z)
		b.global_position -= wall_dir * 0.12
	b.start_construction(5.0, cfg)
	b.set_meta("ai_ladder", true)
	if battle.has_method("assign_builders"):
		battle.assign_builders(b, [builder.get_instance_id()])
	return true

func _ladder_support_count(pos: Vector3, radius: float) -> int:
	var count := 0
	for e in _cached_armies():
		if not is_instance_valid(e) or e.health <= 0:
			continue
		if not entity_belongs_to_me(e):
			continue
		if int(e.target_type) <= 0 or e.water_capable:
			continue
		if int(e.entity_id) in [10, 14, 43, 44, 45, 46, 47, 48, 49, 50, 51]:
			continue
		if e.has_meta("ai_wall_guard") or e.has_meta("ai_harass") or e.has_meta("ai_home_guard"):
			continue
		if e.global_position.distance_to(pos) <= radius:
			count += 1
	return count

func build_building(building_id: int, pos: Vector3, facing: Vector3 = Vector3.ZERO) -> bool:
	# 梯子有独立的贴墙校验与掩护规则，不能套普通建筑流程。
	if building_id == 8:
		return build_ladder(pos)
	var cfg = EntityDatabase.get_config(building_id)
	if not cfg: return false
	# Check castle level requirement (matches RTSBattleManager.is_building_unlocked)
	if not _ai_can_build(building_id): return false
	# 战役敌方 AI 的总建筑软上限，避免铺满地图后堵住寻路。
	if GameSettings.campaign_mode and my_peer_id == -1 \
			and building_id != 8 and building_id != 27 and building_id != WALL_CANNON_ID \
			and _campaign_ai_building_count() >= CAMPAIGN_AI_BUILDING_CAP:
		return false
	# 已经规划好一座桥时，先给桥留住木材：农民修桥需要 50 木，
	# 如果 AI 同时把木材花在仓库/民房上，桥会永远差最后几块木头。
	if building_id != 7:
		var bridge_wood: int = _bridge_wood_reserve()
		if bridge_wood > 0:
			var own_wood: int = int(_get_resources().get("wood", 0))
			var want_wood: int = int(cfg.get("cost", {}).get("wood", 0))
			if own_wood - want_wood < bridge_wood:
				return false
	# 城墙允许建三层圈（WALL_BUILD_CAP_AI 面），民居最多 HOUSE_TARGET_MAX 座，
	# 墙顶炮台最多 WALL_COUNT_MAX 座；其余建筑上限 10
	var _cap = WALL_BUILD_CAP_AI if building_id == 27 else (_effective_house_target() if building_id == 28 else 10)
	if building_id == WALL_CANNON_ID:
		_cap = WALL_COUNT_MAX
	if count_building(building_id) >= _cap: return false
	# 周围 10 单位内不能有敌方作战军队；否则直接放弃本次建造，不扣资源。
	# 但民居/兵营被拆且基地正在挨打时，必须允许在城堡背侧紧急重建，
	# 否则会出现“被打→建筑没了→永远不敢造→人口/产能彻底停摆”的死循环。
	if _enemy_army_within(pos):
		if building_id not in [21, 28] or not _base_under_attack():
			return false
	# Non-shipyard buildings: must be within AI vision range
	if building_id == 7:
		# 桥从己方岸边向对岸延伸：第一段允许在 20 距离内建造，
		# 后续桥段允许紧邻已有桥继续往前修，否则远端会因视野不足中断
		var bridge_world_pos = Vector3(pos.x, 0, pos.z)
		var bridge_visible = false
		for e in battle.entities.get_children():
			if e is GameEntity and e.health > 0 and entity_belongs_to_me(e):
				if e is Building and e.entity_id == 7:
					if e.global_position.distance_to(bridge_world_pos) <= 3.0:
						bridge_visible = true
						break
				if e.global_position.distance_to(bridge_world_pos) <= maxf(float(e.vision_range), 20.0):
					bridge_visible = true
					break
		if not bridge_visible:
			# AI 已经规划好的经济桥：允许直接开工第一段，
			# 后续桥段仍靠“紧邻已有桥”规则延伸。
			if _water_crossing == null or not _water_crossing.is_planned_bridge_position(bridge_world_pos):
				return false
	elif building_id != 23:
		var world_pos = Vector3(pos.x, 0, pos.z)
		var visible = false
		for e in battle.entities.get_children():
			if e is GameEntity and e.health > 0 and entity_belongs_to_me(e):
				if e.global_position.distance_to(world_pos) <= e.vision_range:
					visible = true
					break
		if not visible:
			return false  # cannot build outside vision
	if not _can_place_ai_building(building_id, pos):
		return false
	# 建造必须有农民到场：先找一个能派过去的农民，找不到就不扣资源、不拍地基
	var builder = battle.find_nearest_idle_builder(my_team, my_peer_id, pos, 60.0) \
			if battle.has_method("find_nearest_idle_builder") else null
	if builder == null:
		return false
	# 农民脚下到建造点没有陆路（被水隔开）时，不要先拍一个永远修不完的地基：
	# 让渡水模块从农民所在岸边规划短桥，桥修通后 AI 的下一次建造会自然成功。
	# 桥本身（7）不适用这条规则，它本来就要建在水上。
	if building_id != 7 and _water_crossing != null \
			and not _water_crossing.can_builder_reach(builder.global_position, pos):
		_water_crossing.plan_bridge_to(pos, builder.global_position)
		return false
	var cost = cfg.get("cost", {})
	if _research_age_reserve_active() and building_id != 28 and not (building_id == 22 and _resource_overflow()) \
			and not _can_pay_with_reserve(cost, _research_age_reserve_cost()):
		return false
	if not _deduct_resources(cost): return false
	cfg["owner_peer_id"] = my_peer_id
	# 队伍判定：在线走 player_info；本地乱斗/多人各 AI 有唯一 team(my_team)，
	# 若始终用 RED 会让 AI 建筑建错阵营，被自己和盟友攻击。
	var team = my_team
	if my_peer_id != -1:
		if battle is OnlineBattleManager:
			team = battle.player_info[my_peer_id].team
		else:
			team = my_team
	var b = battle.spawn_entity(cfg, team, pos)
	if b:
		# 防御塔朝向敌方/防线正面；城墙是方形墙体，不需要额外朝向
		if facing.length_squared() > 0.01 and building_id in [25, 26]:
			var face_target: Vector3 = b.global_position + Vector3(facing.x, 0.0, facing.z).normalized()
			b.look_at(face_target, Vector3.UP)
		b.start_construction(5.0, cfg)
		if builder != null and is_instance_valid(builder):
			battle.assign_builders(b, [builder.get_instance_id()])
	return b != null

func upgrade_building(building_id: int):
	for entity in battle.entities.get_children():
		if entity is Building and entity.health > 0 and entity.entity_id == building_id:
			if not entity_belongs_to_me(entity): continue
			# 同类型可能有多个建筑；升级建筑必须是当前可升级的那一个，
			# 不能只看第一个（第一个满级后会导致后面同类建筑永远不升级）
			if not entity.can_upgrade(): continue
			var upgrade_cost: Dictionary = entity.get_upgrade_cost()
			if _research_age_reserve_active() and not _can_pay_with_reserve(upgrade_cost, _research_age_reserve_cost()):
				continue
			if entity.perform_upgrade(battle): return

# ═══ 建筑修理（AI 决策）═══
# 只处理「自己的、非主城、受损且附近没有敌方部队」的建筑：
# Building.can_repair() 对 AI 建筑已经排除了主城/满血/建造中/升级中/已在修理/10 米内有敌军的情况，
# 这里只再叠加资源余量与并发限制，然后直接 perform_repair()（扣费在 Building 内完成）。
func _tick_building_repair() -> void:
	if battle == null:
		return
	# 开局先铺经济；这段时间 AI 的建筑本来就很少被打
	if battle.game_time < REPAIR_EARLY_GAME_SECONDS:
		return
	var repairing: int = 0
	var candidates: Array = []
	for entity in _cached_buildings():
		if not is_instance_valid(entity) or not (entity is Building) or entity.health <= 0:
			continue
		if not entity_belongs_to_me(entity):
			continue
		if entity.is_under_repair():
			repairing += 1
			continue
		if not entity.can_repair():
			continue
		if float(entity.repair_damage_ratio()) < REPAIR_MIN_DAMAGE:
			continue
		candidates.append(entity)
	# 已经修满上限时不再开工：修理会占住建筑本身（期间不能升级），不宜全基地同时施工
	if candidates.is_empty() or repairing >= REPAIR_MAX_CONCURRENT:
		return
	# 同权重时更残破的先修
	candidates.sort_custom(func(a, b): return _repair_score(a) > _repair_score(b))
	var started: int = 0
	for b in candidates:
		if repairing + started >= REPAIR_MAX_CONCURRENT:
			break
		if started >= REPAIR_MAX_START_PER_SCAN:
			break
		var cost: Dictionary = b.repair_cost()
		if not _repair_has_spare_resources(cost):
			continue
		# 双保险：BattleManager 按 owner/team 取资源判断，口径与 AI 自己的查询保持一致
		if battle.has_method("can_repair_building") and not battle.can_repair_building(b):
			continue
		var builder = battle.find_nearest_idle_builder(my_team, my_peer_id, b.global_position, 60.0) \
				if battle.has_method("find_nearest_idle_builder") else null
		if builder == null:
			continue
		if battle.request_repair(b, [builder.get_instance_id()]):
			started += 1

# 单座建筑优先级 = 重要度 × (0.4 + 0.6 × 已损比例)
# 权重决定「同类里更该修的」，已损比例保证残血建筑不会被小修拖后。
func _repair_score(b: Building) -> float:
	var w: float = float(REPAIR_WEIGHT.get(int(b.entity_id), 1.0))
	# 城墙是防线上的“连续墙段”：端头/破口旁的墙先修，否则敌人会从缺口灌进来。
	# 这里只提高权重，真正能不能修仍由 Building.can_repair() 对 AI 的附近无敌军规则决定。
	if int(b.entity_id) == 27:
		w *= _wall_repair_weight(b)
	return w * (0.4 + 0.6 * float(b.repair_damage_ratio()))

func _wall_repair_weight(wall: Building) -> float:
	var neighbors: int = 0
	for e in _cached_buildings():
		if not is_instance_valid(e) or not (e is Building) or e == wall:
			continue
		if int(e.entity_id) != 27 or e.health <= 0:
			continue
		if not entity_belongs_to_me(e):
			continue
		var d: Vector3 = e.global_position - wall.global_position
		d.y = 0.0
		if d.length_squared() <= 2.35 * 2.35:
			neighbors += 1
			if neighbors >= 2:
				break
	if neighbors <= 1:
		return 1.5   # 墙端/破口旁：优先续上
	if neighbors == 2:
		return 1.15  # 正常连续墙段
	return 1.0

# 修理费储备门槛：不同阶段给造兵/升级留的钱不一样。
# 防守时进一步放宽 —— 前线建筑塌了会直接丢防线，这时修比攒钱重要。
func _repair_reserve() -> Dictionary:
	var reserve := {"gold": 120, "wood": 150, "stone": 90, "food": 80, "oil": 60}
	match phase:
		Phase.PRODUCTION:
			reserve = {"gold": 220, "wood": 260, "stone": 160, "food": 120, "oil": 100}
		Phase.ASSAULT:
			reserve = {"gold": 90, "wood": 110, "stone": 70, "food": 60, "oil": 40}
	if _is_defending():
		# 防守优先级提高：储备压到六成，但仍保留最低补兵钱
		for k in reserve:
			reserve[k] = int(round(float(reserve[k]) * 0.6))
	return reserve

# 付款后每种资源仍不低于储备，才算「有余量修」
func _repair_has_spare_resources(cost: Dictionary) -> bool:
	var res: Dictionary = _get_resources()
	var reserve: Dictionary = _repair_reserve()
	for k in cost:
		var need: int = int(cost[k])
		if need <= 0:
			continue
		if int(res.get(k, 0)) - need < int(reserve.get(k, 0)):
			return false
	# 正在攒巨型投石机 / 重装武器厂科技时修理也要让路，沿用现有预留逻辑
	if _research_age_reserve_active() and not _can_pay_with_reserve(cost, _research_age_reserve_cost()):
		return false
	if _trebuchet_reserve_active() and not _can_pay_with_trebuchet_reserve(cost):
		return false
	if _heavy_siege_tech_reserve_active() and not _can_pay_with_reserve(cost, _heavy_siege_tech_reserve_cost()):
		return false
	return true

# ═══ Counter matrix ═══
const COUNTER_MATRIX = {
	11: [12,16,17,37], 15: [11,34,35,36], 12: [15,16,17,13,38],
	16: [15,13,38], 17: [15,13,38], 18: [11,34,36],
	13: [16,17,39], 34: [12,37], 35: [12,37], 36: [12,37,39],
	37: [15,13,38,40], 38: [36,11,34,35], 39: [13,40,17], 40: [13,16,17],
		58: [36,38,25,26,64], 59: [25,26,36,37,64], 9: [13,39,40], 64: [16,17,18,59],
}

func analyze_enemy_composition() -> Dictionary:
	var comp = {}
	for entity in _visible_enemies:
		if not is_instance_valid(entity) or entity.health <= 0: continue
		if entity is Army:
			if entity_belongs_to_me(entity): continue
			var uid = entity.entity_id
			if uid in COUNTER_MATRIX:
				comp[uid] = comp.get(uid, 0) + 1
	return comp

# 检查是否有建筑能生产指定单位
func _can_produce_unit(unit_id: int) -> bool:
	for entity in _cached_buildings():
		if not is_instance_valid(entity) or entity.health <= 0:
			continue
		if entity.build_timer <= 0:
			if not entity_belongs_to_me(entity): continue
			for prod in entity.production_list:
				if prod.unit_id == unit_id:
					return true
	return false

func get_counter_priority() -> Array:
	var enemy_comp = analyze_enemy_composition()
	var scores = {}
	for u_id in wanted_units:
		scores[u_id] = 0
		for enemy_id in enemy_comp:
			if u_id in COUNTER_MATRIX.get(enemy_id, []):
				scores[u_id] += enemy_comp[enemy_id]
	var list = scores.keys()
	list.sort_custom(func(a, b): return scores[a] > scores[b])
	# 过滤掉没有生产建筑的兵种
	var filtered: Array = []
	for u_id in list:
		if _can_produce_unit(u_id) or u_id == 10:  # 农民总是可以
			filtered.append(u_id)
	# 确保基础步兵在列表中（城堡可生产）
	if filtered.is_empty() and _can_produce_unit(11):
		filtered.append(11)
	return filtered

# ═══ Init ═══
func _ready():
	# 战斗管理器本身是 PROCESS_MODE_ALWAYS（暂停时仍接玩家指令），
	# AI 必须显式 PAUSABLE，否则暂停时仍会生产、出兵、下令。
	process_mode = Node.PROCESS_MODE_PAUSABLE
	_add_nation_special_unit()
	# 手机端不创建 AI 决策面板：屏幕装不下多块 540×400 的面板，
	# 而且 MobileHUD 只在自己装配时隐藏一次，AI 是开局后才建的，压不住。
	# 相关信息在手机端已并入全屏统计大屏。
	# 注意 Web 手机浏览器没有 mobile/android 特性，必须用 use_mobile_ui()
	# 才能覆盖网页版移动端。
	if not InputSource.use_mobile_ui():
		_create_debug_panel()
	_defense = AIDefenseScript.new(self)
	_water_crossing = AIWaterCrossingScript.new(self)
	_ladder_siege = AILadderSiegeScript.new(self)
	_worker_director = AIWorkerDirectorScript.new()
	_worker_director.setup(self)

# 后期实体数越多，AI 的周期性全量扫描越贵；返回统一的降频倍率。
func _late_game_scale() -> float:
	var n: int = battle._all_entities.size() if battle else 0
	if n > 700:
		return 3.0
	if n > 450:
		return 2.0
	return 1.0

func _process(delta):
	# Set think interval based on difficulty (once) + 错开各 AI 的计时器。
	# 多 AI 同时开局时，timer/worker/naval 都为 0，会在同一帧集中做全实体扫描和寻路，
	# 造成明显的周期性卡顿；按 peer/instance id 相位错开可把峰值摊到不同帧。
	if not _think_ready:
		_think_ready = true
		var diff = GameSettings.ai_difficulty
		if battle is OnlineBattleManager and my_peer_id != -1:
			diff = GameSettings.red_ai_difficulty if my_team == RTSConfig.Team.RED else GameSettings.blue_ai_difficulty
		if diff == GameSettings.AIDifficulty.EASY: think_interval = 2.0
		elif diff == GameSettings.AIDifficulty.NORMAL: think_interval = 1.75
		elif diff == GameSettings.AIDifficulty.HARD: think_interval = 1.5
		elif diff == GameSettings.AIDifficulty.HELL: think_interval = 1.0
		var seed_id: int = my_peer_id if my_peer_id >= 0 else my_team
		var phase: float = float((seed_id * 7 + get_instance_id() % 13) % 17) / 17.0
		timer = think_interval * phase
		worker_allocate_timer = WORKER_ALLOCATE_INTERVAL * phase
		_naval_patrol_timer = NAVAL_PATROL_INTERVAL * phase
		# 修理扫描同样按相位错开，避免多个 AI 在同一帧一起扫全建筑
		_repair_scan_timer = REPAIR_SCAN_INTERVAL * phase
		# 进贡也错开：第一个 AI 不会在开局第 0 秒就送资源
		_tribute_to_human_timer = TRIBUTE_ALLY_INTERVAL * phase + 5.0
	timer -= delta
	_ai_income_timer -= delta
	if _ai_res_snapshot.is_empty():
		_ai_res_snapshot = _get_resources().duplicate()
	else:
		var cur = _get_resources()
		for rk in ["gold","wood","stone","food","oil"]:
			var cv = cur.get(rk, 0)
			var pv = _ai_res_snapshot.get(rk, cv)
			if cv > pv: _ai_res_income[rk] = _ai_res_income.get(rk, 0) + (cv - pv)
			_ai_res_snapshot[rk] = cv
	if _ai_income_timer <= 0:
		_ai_income_timer = 10.0
		for rk in ["gold","wood","stone","food","oil"]:
			_ai_income_rate[rk] = _ai_res_income.get(rk, 0) / 10.0
			_ai_res_income[rk] = 0
	if timer <= 0 and not _decide_running:
		# 后期实体多时 AI 决策降频：单次 decide 会做多轮全实体统计和可见性刷新，
		# 4 个 AI 同时跑会造成周期性主线程尖峰。260 个实体后拉长间隔，
		# 不影响前期节奏，但能显著降低后期 AI 的固定开销。
		var interval: float = think_interval
		var entity_count: int = battle._all_entities.size() if battle else 0
		if entity_count > 1000:
			interval *= 12.0
		elif entity_count > 850:
			interval *= 9.0
		elif entity_count > 700:
			interval *= 6.0
		elif entity_count > 550:
			interval *= 5.0
		elif entity_count > 450:
			interval *= 4.2
		elif entity_count > 360:
			interval *= 3.2
		elif entity_count > 260:
			interval *= 2.2
		elif entity_count > 180:
			interval *= 1.4
		if battle != null and battle.has_method("acquire_ai_decide_slot") \
				and not bool(battle.acquire_ai_decide_slot(my_peer_id)):
			# 本帧已有别的 AI 在决策：顺延 0.1s，避免多个 decide 叠在同一帧。
			timer = 0.1
		elif battle != null:
			# 本轮决策不再整段执行，改为从这里开始逐帧推进（每帧约 7ms 预算）。
			_begin_decide(interval, delta)
	if _decide_running:
		_pump_decide()

	# 后期实体多时，AI 的周期性全量扫描（分配农民、海军巡逻、修建筑）也一起降频：
	# 这些扫描和 decide() 一样是 O(实体数)，5 个 AI 叠起来在 600+ 实体时非常可观。
	var late_scale: float = _late_game_scale()
	worker_allocate_timer -= delta
	if worker_allocate_timer <= 0:
		worker_allocate_timer = WORKER_ALLOCATE_INTERVAL * late_scale
		allocate_workers()
	# WorkerDirector 第 1 阶段：只读账本/日志，不改农民命令。
	if _worker_director != null:
		_worker_director.tick(delta)
	_naval_patrol_timer -= delta
	if _naval_patrol_timer <= 0:
		_naval_patrol_timer = NAVAL_PATROL_INTERVAL * late_scale
		if phase >= Phase.DEVELOPMENT:
			_patrol_navy_around_water()
	# 被偷袭后回头打人：独立 1 秒节流，避免等下一次 decide 才反应。
	_retarget_timer -= delta
	if _retarget_timer <= 0.0:
		_retarget_timer = RETARGET_CHECK_INTERVAL * minf(late_scale, 2.0)
		_retarget_attacked_siege_units()
	# 修理节奏独立于难度思考间隔（固定 2.5s）：建筑受损/修好之后最多 2.5s 内响应，
	# 且不挤在 decide() 那一帧里再做一次全建筑扫描。
	_repair_scan_timer -= delta
	if _repair_scan_timer <= 0.0:
		_repair_scan_timer = REPAIR_SCAN_INTERVAL * minf(late_scale, 2.0)
		_tick_building_repair()
	# 2v2/3v3 的石头共享独立节流：不依赖当前 phase 是否调用 _process_line_1，
	# 否则生产卡住的 AI 会一直满仓、队友却缺石头造墙。
	_stone_share_timer -= delta
	if _stone_share_timer <= 0.0:
		_stone_share_timer = 5.0
		_spend_surplus_stone_on_walls()
		_share_surplus_stone_with_ally()
	# AI 队友向真人玩家进贡：2v2/3v3 才存在同队真人，1v1/FFA 找不到目标会自动跳过。
	_tribute_to_human_timer -= delta
	if _tribute_to_human_timer <= 0.0:
		_tribute_to_human_timer = TRIBUTE_ALLY_INTERVAL
		_tribute_to_human_teammate()
	# 决策面板刷新独立于 AI 思考间隔：展开时每秒刷新一次，收起时放慢到 5 秒。
	# 以前挂在 decide() 的帧计数上，AI 思考间隔 1~2 秒时面板最多要等两轮 think 才更新，
	# 看起来像数据不刷新；现在按真实 delta 计时，打开面板就是稳定每秒更新。
	if OS.is_debug_build() and is_instance_valid(debug_panel):
		_panel_refresh_timer -= delta
		if _panel_refresh_timer <= 0.0:
			_panel_refresh_timer = PANEL_REFRESH_INTERVAL_COLLAPSED if _panel_collapsed else PANEL_REFRESH_INTERVAL_OPEN
			update_debug_label()
	# 部队积累判定放到 decide() 的 AI 思考节流里，避免每帧全实体扫描
	# 军队调度安全网：0.5 秒一次，只处理没有任何角色、也没有任何命令的陆军战斗单位，
	# 保证不会有兵在无人派单的情况下长期站着（设计见 docs/AI_ARMY_DISPATCH_DESIGN.md）。
	_tick_director(delta)

# ═══ 科研模式 AI：按难度节奏升时代，再按优先表研究科技 ═══
const RESEARCH_PRIORITY: Array = [
	"A1", "B1", "C1", "D1", "I2", "I3", "B2", "C2", "D5", "D2",
	"E1", "E2", "F1", "F3", "A2", "B6", "A4", "I5", "C3", "D4",
	"H1", "B3", "C4", "F2", "G1", "G3", "G5", "A5", "B5", "C5",
	"E3", "F4", "F10", "I1", "I6", "H3", "H4", "G2", "B7", "F8",
]

# 升时代不再有固定时间表：是否进入新时代只看当前人口、建筑和资源条件。
# 每 30 秒由 decide() 调用 _try_start_age_upgrade() 检查一次，条件满足就点。

# 当前是否应该为下一次时代升级锁资源。
# 返回空字典 = 不预留；返回 {资源: 数量} = 在付款后必须仍保留这些资源。
func _research_age_reserve_cost() -> Dictionary:
	var stamp := Engine.get_physics_frames()
	if stamp == _research_age_reserve_stamp:
		return _research_age_reserve_value
	_research_age_reserve_stamp = stamp
	_research_age_reserve_value = _compute_research_age_reserve()
	return _research_age_reserve_value

func _research_age_reserve_active() -> bool:
	return not _research_age_reserve_cost().is_empty()

func _compute_research_age_reserve() -> Dictionary:
	if battle == null or not battle.has_method("is_research_mode") or not battle.is_research_mode():
		return {}
	# 以前防守时直接关闭升时代预留，结果只要玩家持续骚扰，AI 就永远在补兵/补科技，
	# 永远攒不齐 600 食物，看起来像卡死在黑暗时代。现在防守时也继续攒时代预算，
	# 只有主城血量已经很低（马上要丢城）时才临时取消预留，优先保命。
	if _is_defending():
		var castle = get_peer_castle(my_peer_id)
		if castle != null and is_instance_valid(castle):
			var hp_ratio: float = float(castle.health) / maxf(float(castle.max_health), 1.0)
			if hp_ratio < 0.30:
				return {}
	var st: Dictionary = battle.get_research_state(my_peer_id, my_team)
	if st.is_empty() or not st.get("current", {}).is_empty():
		return {}
	var age: int = int(st.get("age", 0))
	if age >= 3:
		return {}
	var target: int = age + 1
	var check: Dictionary = battle.can_research_age(my_peer_id, my_team)
	var error := String(check.get("error", ""))
	# 只有“人口/建筑条件已齐、只差资源”或“现在就能点”时才锁预算；
	# 如果还缺人口/建筑，AI 应继续发展，而不是提前囤着资源不动。
	if not bool(check.get("ok", false)) and error != "资源不足":
		return {}
	return TechTreeData.get_age(target).get("cost", {}).duplicate(true)

# 每 30 秒检查一次能否进入新时代；条件齐备就立刻开始研究。
func _try_start_age_upgrade() -> bool:
	if battle == null:
		return false
	var st: Dictionary = battle.get_research_state(my_peer_id, my_team)
	if st.is_empty() or not st.get("current", {}).is_empty():
		return false
	if int(st.get("age", 0)) >= 3:
		return false
	var check: Dictionary = battle.can_research_age(my_peer_id, my_team)
	if not bool(check.get("ok", false)):
		return false
	return bool(battle.research_start_age(my_peer_id, my_team).get("ok", false))

# 升时代除人口外还有建筑条件；如果 AI 只按普通战斗科技顺序研究，
# 经常会卡在“建筑没解锁/只有 1 座城堡”上。这里把当前目标时代需要的
# 解锁科技插到研究队列最前面，保证 AI 能真正凑齐升级条件。
func _research_age_requirement_techs(target_age: int) -> Array:
	match target_age:
		2:
			# 3 座封建建筑：攻城车间(24)/集市(52)/修道院(54)/箭塔(25)
			return ["F1", "I5", "H1", "B6"]
		3:
			# 4 座城堡建筑且至少 2 座城堡：城堡(53)/重装武器厂(29)/书院(42)
			# 同时带上它们的前置科技，避免目标科技因缺前置被跳过。
			return ["A4", "A2", "B6", "G1", "C3", "I1"]
	return []

func _tick_research() -> void:
	var st: Dictionary = battle.get_research_state(my_peer_id, my_team)
	if st.is_empty():
		return
	if not st.get("current", {}).is_empty():
		return
	var age: int = int(st.get("age", 0))
	var saving_for_age := _research_age_reserve_active()
	# 升时代由 decide() 每 30 秒统一检查；这里只负责普通科技。
	# 已经进入升时代攒资源窗口时，暂停科技研究：研究队列会被普通科技占用，
	# 而且科技花费会把刚攒到的时代预算重新吃掉。等时代点下去后再继续研究。
	if saving_for_age:
		return
	# 1) 通用科技：先处理升时代必需科技，再按常规优先表。
	var bits: int = int(st.get("bits", 0))
	var research_order: Array = _research_age_requirement_techs(age + 1) + RESEARCH_PRIORITY
	for tid in research_order:
		if TechTreeData.has_bit(bits, tid):
			continue
		var info := TechTreeData.get_tech(tid)
		if info.is_empty() or int(info.get("age", 0)) > age:
			continue
		if not battle.research_can_afford(my_peer_id, my_team, info.get("cost", {})):
			continue
		if bool(battle.research_start(my_peer_id, my_team, tid).get("ok", false)):
			return
	# 3) 国家特色科技：通用项目都点不动时，优先补本国科技。
	var nation_techs := TechTreeData.nation_techs(nation)
	for t in nation_techs:
		var tid := String(t.get("id", ""))
		if TechTreeData.has_nation_bit(int(st.get("nation_bits", 0)), nation, tid):
			continue
		if int(t.get("age", 0)) > age:
			continue
		if not battle.research_can_afford(my_peer_id, my_team, t.get("cost", {})):
			continue
		if bool(battle.research_start(my_peer_id, my_team, tid).get("ok", false)):
			return
# ═══ Decide ═══

# -- SETUP: validate castle exists, transition to PRODUCTION --
func _state_setup():
	if not get_peer_castle(my_peer_id):
		queue_free()
		return
	phase = Phase.PRODUCTION

# -- PRODUCTION: build initial economy and military --
func _state_production(_delta):
	var workers = count_unit(10)
	var warehouses = count_building(22)
	if production_step == 0:
		if workers < desired_worker_count and can_afford(10) and _can_train_unit():
			produce_unit(10)
		else:
			if can_afford_upgrade(20):
				upgrade_building(20)
			elif workers >= desired_worker_count and count_building(20) > 0:
				var castle = get_peer_castle(my_peer_id)
				if castle and castle.upgrade_level >= 1:
					production_step = 1
	elif production_step == 1:
		# 船坞/渔船/仓库都只是可选开局动作，任何一项失败都不能让 AI 永远停在 PRODUCTION
		if count_building(23) < 1 and _ai_can_build(23) and can_afford_building(23):
			_cache_shipyard_location()
			if cached_shipyard_pos != Vector3.ZERO:
				if build_building(23, cached_shipyard_pos):
					built_shipyard_pos.append(cached_shipyard_pos)
		if count_building(23) > 0 and count_unit(14) < 3 and can_afford(14) and _can_train_unit():
			produce_unit(14)
		if warehouses < WAREHOUSE_MAX_COUNT and can_afford_building(22):
			var castle = get_peer_castle(my_peer_id)
			if castle:
				var near_count = 0
				for e in battle.entities.get_children():
					if e is Building and e.entity_id == 22 and e.team == my_team and e.health > 0:
						if e.global_position.distance_to(castle.global_position) < 25.0: near_count += 1
				# More warehouses nearby = lower priority, but still build if < 5 total
				if near_count < 3:
					var wpos = find_valid_build_position(castle.global_position, 22)
					if wpos != Vector3.ZERO:
						build_building(22, wpos)
		# 工人已补齐（进入 step1 的前提）或已经过开局阶段，就直接进入 DEVELOPMENT
		if count_unit(10) >= desired_worker_count or battle.game_time >= 120.0:
			phase = Phase.DEVELOPMENT
		_process_line_military()
	# 开局就被压到家时不能只造农民/升级主城，否则会一直处于“防守但不补兵”的状态
	if _is_defending():
		_process_line_military()
		_process_line_1()
		_process_line_3()

# -- DEVELOPMENT: expand base, counter enemy, upgrade --
func _state_development(_delta):
	# Castle rush: 3min→lv3, 6min→lv4, 10min→lv5
	var _gm = battle.game_time / 60.0
	for _ci in range(3):
		if not _castle_rush_done[_ci] and _gm >= [3, 6, 10][_ci]:
			var _castle = get_peer_castle(my_peer_id)
			var _target_lv = _ci + 3
			if _castle and _castle.upgrade_level < _target_lv and can_afford_upgrade(20):
				upgrade_building(20)
				_castle_rush_done[_ci] = true
			
	# Upgrade cycle toggle
	var defending: bool = _is_defending()
	if defending:
		# 防守时先补军队，再补建筑和升级；否则升级会先把资源吃光，导致一直不补兵
		_process_line_military()
		_process_line_1()
	
	if not _priority_upgrade():
		_process_line_upgrade()
	
	if not defending:
		_process_line_military()
	_process_line_1()
	_process_line_3()
	# 主力出击不再只等到 ASSAULT：发育阶段兵力成型且开局时间已过，也要主动发起主攻
	_process_line_4()
	if _ladder_siege != null:
		_ladder_siege.tick(_delta)
	_ensure_merchants()
	var _did_merchant = _try_produce_merchants_or_officials()
	_try_produce_monks()
	if not _did_merchant:
		if not _priority_upgrade():
			_process_line_upgrade()
	_manage_shipyards()
	_manage_merchant_bridges()
	_process_line_5()
	_rally_land_army_to_castle()
	_ai_hunt_animals(_delta)
	_check_hunt_cleanup()
	_ai_garrison_officials()
	update_tactic(_delta)

# -- ASSAULT: execute tactical attacks --
func _state_assault(_delta):
	# 进攻阶段也要先把资源投到建筑升级上，不能只无限补兵
	if not _priority_upgrade():
		_process_line_upgrade()
	_process_line_military()
	_process_line_1()
	_process_line_3()
	_process_line_4()
	if _ladder_siege != null:
		_ladder_siege.tick(_delta)
	_ensure_merchants()
	_rally_land_army_to_castle()
	_try_produce_merchants_or_officials()
	_try_produce_monks()
	_manage_shipyards()
	_manage_merchant_bridges()
	_process_line_5()
	_ai_hunt_animals(_delta)
	_check_hunt_cleanup()
	_ai_garrison_officials()
	update_tactic(_delta)
# ═══ State Machine Dispatcher ═══
# 兼容入口：一次性跑完全部阶段（调试/特殊场景用）。正常节奏走分帧版本。
func decide(_delta):
	_last_delta = _delta
	if not battle: return
	for step in range(DECIDE_LAST_STEP + 1):
		_run_decide_step(step)

func _begin_decide(interval: float, d: float) -> void:
	_last_delta = d
	_decide_interval = interval
	_decide_running = true
	_decide_cursor = 0
	_decide_start_usec = Time.get_ticks_usec()
	if _decide_step_usec.size() != DECIDE_LAST_STEP + 1:
		_decide_step_usec.resize(DECIDE_LAST_STEP + 1)
	_decide_step_usec.fill(0)

# 逐帧推进：一帧内按 7ms 预算连续跑阶段，超预算就留到下一帧。
# 实测 600+ 实体时整段 decide 要 200~500ms，拆开后单帧最多多花 7ms 左右。
func _pump_decide() -> void:
	var frame_start: int = Time.get_ticks_usec()
	while _decide_cursor <= DECIDE_LAST_STEP:
		var step_start: int = Time.get_ticks_usec()
		_run_decide_step(_decide_cursor)
		_decide_step_usec[_decide_cursor] = int(_decide_step_usec[_decide_cursor]) + (Time.get_ticks_usec() - step_start)
		_decide_cursor += 1
		if Time.get_ticks_usec() - frame_start >= DECIDE_BUDGET_USEC:
			break
	if _decide_cursor > DECIDE_LAST_STEP:
		_finish_decide()

func _finish_decide() -> void:
	var total_ms: float = float(Time.get_ticks_usec() - _decide_start_usec) / 1000.0
	_decide_running = false
	_decide_cursor = 0
	timer = _decide_interval * _decide_cost_scale
	# 整轮耗时超过 60ms 就自动拉长下一轮间隔，避免高规模/低配机器上频繁卡顿。
	if total_ms > 250.0:
		_decide_cost_scale = minf(_decide_cost_scale * 1.5, 8.0)
	elif total_ms > 120.0:
		_decide_cost_scale = minf(_decide_cost_scale * 1.35, 6.0)
	elif total_ms > 60.0:
		_decide_cost_scale = minf(_decide_cost_scale * 1.3, 5.0)
	elif total_ms < 25.0:
		_decide_cost_scale = maxf(_decide_cost_scale * 0.97, 1.0)
	if total_ms > 80.0:
		_log_decide_profile(total_ms)
	if battle != null and battle.has_method("is_research_mode") and battle.is_research_mode():
		_tick_research()

# 决策耗时诊断：单轮超过 80ms 时把各阶段耗时写进 user://ai_decide.log，
# 用真实数据定位到底哪一段吃掉主线程（而不是靠猜）。
func _log_decide_profile(total_ms: float) -> void:
	var parts: PackedStringArray = PackedStringArray()
	for i in range(DECIDE_LAST_STEP + 1):
		parts.append("%d=%.0f" % [i, float(_decide_step_usec[i]) / 1000.0])
	var f: FileAccess = FileAccess.open("user://ai_decide.log", FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open("user://ai_decide.log", FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	f.store_line("DECIDE peer=%d total=%.0fms entities=%d %s" % [
		my_peer_id, total_ms, battle._all_entities.size() if battle else 0, " ".join(parts)])
	f.close()

func _run_decide_step(step: int) -> void:
	if not battle:
		return
	match step:
		0:
			if my_peer_id != -1 and battle.has_method("update_player_limits"):
				battle.update_player_limits(my_peer_id)
				battle.update_player_population(my_peer_id)
			else:
				battle.update_resource_limits(my_team)
				battle.update_population_limits()
		1:
			clear_invalid_targets()
		2:
			_refresh_visibility()
		3:
			_process_scout_recon()
		4:
			_refresh_primary_enemy()
		5:
			_update_resource_pressure(_last_delta)
			_ensure_house_quota()
			_ensure_military_producer_quota()
		6:
			# 升时代要求每 30 秒兜底检查一次：普通建造目标不一定包含瞭望塔等条件建筑；
			# 同一轮里再检查一次能否直接进入新时代（不再按固定分钟数等待）。
			_age_building_check_timer -= _last_delta
			if _age_building_check_timer <= 0.0:
				_age_building_check_timer = AGE_BUILDING_CHECK_INTERVAL
				_ensure_age_upgrade_buildings()
				_try_start_age_upgrade()
		7:
			# 资源囤到接近上限时先泄压：补人口/建筑升级/多排兵，避免继续采集却被上限截断。
			_relieve_resource_pressure()
			_diplo_decide()
		8:
			if _defense == null:
				_defense = AIDefenseScript.new(self)
			_defense.tick(_last_delta)
		9:
			# 守墙调度必须先于本帧的集结/主攻：新生产的远程兵在出生后的第一个
			# AI 决策帧仍是空闲状态，若先执行 _state_* 里的 _rally_land_army_to_castle
			# 或 attack_move，它们会被立刻拉去集结点/前线，之后一直是 MOVING/攻击移动，
			# _is_ranged_wall_candidate 永远不满足，城墙也就永远等不到远程守军。
			_wall_deploy_timer -= _last_delta
			if _wall_deploy_timer <= 0.0:
				_wall_deploy_timer = WALL_DEPLOY_INTERVAL
				_deploy_ranged_units_to_walls()
			# 守墙之后再安排塔内驻军：墙顶单位、赶路单位都已被占用，
			# 不会把刚派去城墙的远程兵又抽回箭塔。
			_garrison_timer -= _last_delta
			if _garrison_timer <= 0.0:
				_garrison_timer = GARRISON_CHECK_INTERVAL
				_ai_garrison_soldiers()
		10:
			match phase:
				Phase.PRODUCTION: _state_production(_last_delta)
				Phase.DEVELOPMENT: _state_development(_last_delta)
				Phase.ASSAULT: _state_assault(_last_delta)
		11:
			# 进攻阶段转换只在思考节流里判断；count_field_military 会遍历全部实体，不能每帧调用。
			if phase == Phase.DEVELOPMENT:
				# 用可出击野战军而不是总军事人口：守墙/守家/队列里的兵不会出门，
				# 用总数判断会让 AI 提前进入 ASSAULT，却只有少量部队可派。
				var army_count = count_field_military(my_peer_id if my_peer_id != -1 else my_team)
				if army_count >= 30:
					phase = Phase.ASSAULT
		12:
			if _defense != null:
				if _wall_planner == null:
					_wall_planner = AIWallPlannerScript.new(self, _defense)
				_wall_planner.tick(_last_delta)
		13:
			# 前线闲兵补派：attack/attack_move 结束后（或被墙挡住停下）没人重新派单，
			# 这些单位就长期待命。实测待命兵 45% 停在离家 25 米内、身边全有敌人。
			_retask_timer -= _last_delta
			if _retask_timer <= 0.0:
				_retask_timer = RETASK_IDLE_INTERVAL
				_retask_idle_front_units()
		14:
			if _water_crossing:
				# 渡水模块按“决策轮次”推进，不是每帧推进。传入帧 delta 会让
				# 船队集结/靠岸/搭桥的计时慢几十倍，看起来像 AI 永远不过河。
				_water_crossing.tick(_decide_interval)
func get_team_castle(tm) -> Building:
	for entity in _cached_buildings():
		if not is_instance_valid(entity) or entity.health <= 0:
			continue
		if entity.entity_id == 20 and entity.team == tm:
			return entity
	return null

func get_peer_castle(peer) -> Building:
	for entity in _cached_buildings():
		if not is_instance_valid(entity) or entity.health <= 0:
			continue
		if entity.entity_id == 20:
			if my_peer_id != -1 and entity.owner_peer_id == peer: return entity
			if my_peer_id == -1 and entity.team == my_team: return entity
	return null

# ═══ 乱斗 FFA 主敌解析 ═══
# 非乱斗（1v1 / 在线 2v2）的对手就是红蓝对位的另一个队伍，行为与原逻辑完全一致；
# 乱斗 FFA 中每个国家独立成队（team 从 3 起），"1-my_team" 会解析到空队导致 AI 永不进攻，
# 故以"仍存活 + 与我有外交敌意（盟友除外）的国家"为候选，取其城堡距我最远者为主敌。
# _primary_enemy_owner 每 think 周期由 decide() 顶部刷新一次，查询均为 O(1)。

func _refresh_primary_enemy():
	_primary_enemy_owner = -1
	if my_peer_id == -1: return
	if not (battle and battle.diplomacy and battle.diplomacy.active): return
	var self_castle = get_peer_castle(my_peer_id)
	var base = self_castle.global_position if self_castle else Vector3.ZERO
	var best_d = INF
	for o in battle.diplomacy.get_alive_owners():
		if o == my_peer_id: continue
		if not battle.diplomacy.is_hostile(my_peer_id, o): continue  # 盟友/中立 → 不为主敌
		var oc = get_peer_castle(o)
		if not oc: continue
		var d = base.distance_squared_to(oc.global_position)
		if d < best_d:
			best_d = d
			_primary_enemy_owner = o

func _primary_enemy_team() -> int:
	if _primary_enemy_owner != -1 and battle and battle.diplomacy and battle.diplomacy.active:
		return battle.diplomacy.get_team_of(_primary_enemy_owner)
	# 非乱斗经典红蓝对位；乱斗下全盟友无主敌时回退（BLUE/RED 无独立国时自然为空，不会误打盟友）
	return RTSConfig.Team.BLUE if my_team == RTSConfig.Team.RED else RTSConfig.Team.RED

# 主攻目标：优先外交确定的主敌，其次对位队伍，最后找最近的敌对城堡。
# 乱斗里 BLUE/RED 不一定有国家，只按队伍找会拿到空目标，导致 AI 永远不发起主攻。
func _get_attack_target_castle() -> Building:
	# 优先打「最近的」敌方主城：多国混战时等于就近开战，
	# 避免 AI 隔着半个地图去扑一个固定主敌、把后方基地晾着。
	var my_castle = get_peer_castle(my_peer_id)
	var base: Vector3 = my_castle.global_position if my_castle else Vector3.ZERO
	var best: Building = null
	var best_d: float = INF
	for e in battle.entities.get_children():
		if not (e is Building) or int(e.entity_id) != 20 or e.health <= 0:
			continue
		if not _entity_is_enemy(e):
			continue
		var d: float = base.distance_squared_to(e.global_position)
		if d < best_d:
			best_d = d
			best = e
	if best != null:
		return best
	# 兜底：没有可测距的敌方主城时，退回主敌/主敌队伍的城堡
	if _primary_enemy_owner != -1:
		var oc = get_peer_castle(_primary_enemy_owner)
		if oc != null and oc.health > 0:
			return oc
	var tc = get_team_castle(_primary_enemy_team())
	return tc

# 该实体是否对我构成敌对（owner 感知）。无外交管理器时退化为纯队伍判定，资源恒非敌。
func _entity_is_enemy(e) -> bool:
	if not (e is GameEntity) or e.health <= 0: return false
	if battle and battle.diplomacy and battle.diplomacy.active and my_peer_id != -1:
		var eo: int = -1
		if "owner_peer_id" in e: eo = e.owner_peer_id
		return eo >= 0 and eo != my_peer_id and battle.diplomacy.is_hostile(my_peer_id, eo)
	return e.team != my_team and not (e is WorldResource)

# 只统计 AI 当前视野内能看到的敌军，避免用全图信息做防守/进攻判断
func _visible_enemy_military() -> int:
	var total: int = 0
	for e in _visible_enemies:
		if not is_instance_valid(e) or e.health <= 0: continue
		if not (e is Army): continue
		if int(e.team) == RTSConfig.Team.NEUTRAL: continue
		if not _entity_is_enemy(e): continue
		# _visible_enemies 已经过视野筛选，不再重复调用 _is_visible_to_ai
		if e.entity_id != 10 and e.entity_id != 14 and int(e.entity_id) not in [43,44,45,46,47,48,49,50,51]:
			total += 1
	return total

# ═══ 乱斗 FFA 外交策略 ═══
# AI 外交以 owner_peer_id 为国别，按自身相对强弱决定结盟意愿与对象：
#   · 顶级战力（≥ 全场最强 × 0.8）独行清场，不接受也不主动结盟；
#   · 其余国家寻求盟友：优先接受价值达标的提案，无盟时主动向"军力匹配且邻近"的国家提案；
#   · 一旦结盟便守约到自然到期（永不公开决裂——违约对战力无益），临到期若仍需此盟且资源富余，进贡 500 续期；
#   · 只依赖 DiplomacyManager 公开查询与 count_military / get_peer_castle，不触碰任何实体所有权。
# 非乱斗（diplomacy 未激活 / my_peer_id == -1）时本区块整体禁用，AI 行为与以往完全一致。
const DIPLO_DECIDE_INTERVAL: float = 12.0        # 外交思考节流（game_time 秒）
const DIPLO_EARLY_START: float = 90.0            # 开局发育期不外交
const PROPOSE_WAIT_MAX: float = 45.0             # 提案无人响应的最长等待，超时取消换人
const PROPOSE_MIN_INTERVAL: float = 20.0         # 连续两次主动提案的最小间隔
const PROPOSE_COOLDOWN_SECONDS: float = 90.0     # 对被拒/被无视对象的重提冷却
const TRIBUTE_RENEW_SECONDS: float = 60.0        # 联盟剩余少于此值则考虑进贡续期
const TRIBUTE_SEND_INTERVAL: float = 40.0        # 连续两次进贡的最小间隔
const ALLY_MIN_RATIO: float = 0.35               # 盟友军力不足我此比例则停止投入续期
const ACCEPT_VALUE_MIN: float = 0.40             # 接受提案所需的最低盟友价值（近邻强者拉拢约 0.45，需留浮点余量）
const TARGET_VALUE_MIN: float = 0.35             # 主动提案的最低目标价值
const TOP_DOMINATE_RATIO: float = 0.8            # 我 ≥ 全场最强 × 此值 → 视为顶级独行
const BALANCE_DOM_RATIO: float = 1.5             # 最强方达到此倍数视为"独裁者"，弱者之间价值加成

# 外交是否在本 AI 上生效（仅乱斗 FFA）。
func _diplo_enabled() -> bool:
	return battle != null and battle.diplomacy != null and battle.diplomacy.active and my_peer_id != -1

# 外交主决策：在 decide() 每 think 调用，内部按 game_time 节流。
# 有盟 → 维护续期；无盟 → 先响应来盟提案，再考虑主动提案。
func _diplo_decide():
	if not _diplo_enabled(): return
	var gt: float = battle.game_time
	if gt < DIPLO_EARLY_START: return
	if gt - _diplo_last_decide < DIPLO_DECIDE_INTERVAL: return
	_diplo_last_decide = gt
	var ally: int = battle.diplomacy.get_ally(my_peer_id)
	if ally >= 0:
		_diplo_maintain(ally)
		return
	_diplo_respond_incoming()
	if battle.diplomacy.has_active_alliance(my_peer_id):
		_diplo_propose_target = -1
		return
	_diplo_consider_propose(gt)

# 该国家当前战力估值：军力（含生产队列）+ 城堡等级 × 2。
func _diplo_strength(owner: int) -> int:
	var s := count_military(owner)
	var c := get_peer_castle(owner)
	if c: s += c.upgrade_level * 2
	return s

# 全场存活国家中的最强战力。
func _diplo_top_strength() -> int:
	var best := 0
	for o in battle.diplomacy.get_alive_owners():
		var s := _diplo_strength(o)
		if s > best: best = s
	return best

# 我是否"需要盟友"：场上存活 ≤2（决战）或我已是顶级独行 → 不需要。
func _diplo_wants_ally() -> bool:
	var alive: Array = battle.diplomacy.get_alive_owners()
	if alive.size() <= 2: return false
	var top := _diplo_top_strength()
	if top <= 0: return true
	return _diplo_strength(my_peer_id) < top * TOP_DOMINATE_RATIO

# owner 作为潜在盟友对我的价值（0..1）。
#   · 邻近 +0.35：城堡距离近便于协同；
#   · 军力匹配 +0.45：强于我则可能反过来吞并我、弱于我则拖后腿，势均最稳；
#   · 抗强平衡 +0.2：全场存在独裁者且我弱小时，同弱者结盟共抗更强。
func _diplo_ally_value(owner: int) -> float:
	var me: int = maxi(1, _diplo_strength(my_peer_id))
	var them: int = maxi(0, _diplo_strength(owner))
	var a = get_peer_castle(my_peer_id)
	var b = get_peer_castle(owner)
	var d := 9999.0
	if a and b: d = a.global_position.distance_to(b.global_position)
	var d_norm := clampf(1.0 - d / 120.0, 0.0, 1.0)
	var ratio: float = them / float(me)
	var power: float
	if ratio >= 1.0:
		power = clampf(1.0 - (ratio - 1.0) * 0.6, 0.45, 1.0)
	else:
		power = clampf(ratio * 1.1, 0.0, 1.0)
	var top := _diplo_top_strength()
	var balance := 0.0
	if top > maxi(me, them) * BALANCE_DOM_RATIO and me < top * TOP_DOMINATE_RATIO:
		balance = 0.2
	return clampf(d_norm * 0.35 + power * 0.45 + balance, 0.0, 1.0)

# 响应发给我方（acceptor=me）的待处理提案。每轮最多接受一位；其余一律 decline 并记入重提冷却。
func _diplo_respond_incoming():
	if not _diplo_wants_ally():
		for p in battle.diplomacy.get_incoming_proposals(my_peer_id):
			battle.diplomacy.decline_alliance(my_peer_id, p)
			_diplo_propose_history[p] = battle.game_time
		return
	for p in battle.diplomacy.get_incoming_proposals(my_peer_id):
		if battle.diplomacy.has_active_alliance(my_peer_id):
			battle.diplomacy.decline_alliance(my_peer_id, p)  # 已有盟，其余提案拒绝
			continue
		if battle.diplomacy.alliance_block_reason(p, my_peer_id) != "":
			battle.diplomacy.decline_alliance(my_peer_id, p)
			continue
		if _diplo_ally_value(p) >= ACCEPT_VALUE_MIN:
			if battle.diplomacy.accept_alliance(my_peer_id, p):
				_diplo_propose_target = -1
		else:
			battle.diplomacy.decline_alliance(my_peer_id, p)
			_diplo_propose_history[p] = battle.game_time

# 主动提案：处理等待中超时/冷却，然后按最高盟友价值（过阈值）向一位尚未拒绝过的国家提案。
func _diplo_consider_propose(gt: float):
	if _diplo_propose_target >= 0:
		if gt - _diplo_propose_at > PROPOSE_WAIT_MAX:
			battle.diplomacy.cancel_proposal(my_peer_id)
			_diplo_propose_history[_diplo_propose_target] = gt
			_diplo_propose_target = -1
		else:
			return  # 等待既有提案，不重复发起
	if gt - _diplo_last_propose_time < PROPOSE_MIN_INTERVAL: return
	if not _diplo_wants_ally(): return
	var best := -1
	var best_v := TARGET_VALUE_MIN
	for o in battle.diplomacy.get_alive_owners():
		if o == my_peer_id: continue
		if battle.diplomacy.alliance_block_reason(my_peer_id, o) != "": continue
		if _diplo_propose_history.has(o) and gt - _diplo_propose_history[o] < PROPOSE_COOLDOWN_SECONDS: continue
		var v := _diplo_ally_value(o)
		if v > best_v: best_v = v; best = o
	if best < 0: return
	if battle.diplomacy.propose_alliance(my_peer_id, best):
		_diplo_propose_target = best
		_diplo_propose_at = gt
		_diplo_last_propose_time = gt

# 维护既有盟约：盟期将尽（<60s）时若我仍需要此盟、盟友军力未崩坏且资源够，进贡续期；否则守约到自然到期。
func _diplo_maintain(ally: int):
	_diplo_propose_target = -1
	var rem: float = battle.diplomacy.alliance_remaining(my_peer_id)
	if rem <= 0.0: return
	if not _diplo_wants_ally(): return
	var me := _diplo_strength(my_peer_id)
	var them := _diplo_strength(ally)
	if them < me * ALLY_MIN_RATIO: return
	if rem >= TRIBUTE_RENEW_SECONDS: return
	if battle.game_time - _diplo_last_tribute_time < TRIBUTE_SEND_INTERVAL: return
	_diplo_send_tribute(ally)

# 从自身余额最多的资源里送出 500（与外交系统的 TRIBUTE_DELIVERY=500 一致），送成则记录冷却。
func _diplo_send_tribute(ally: int):
	var res: Dictionary = battle.get_resources_for(my_peer_id)
	var age_reserve: Dictionary = _research_age_reserve_cost()
	var order := ["gold", "wood", "stone", "food", "oil"]
	var best := ""
	var best_v := 500
	for k in order:
		var v: int = res.get(k, 0)
		if v >= best_v and v - 500 >= int(age_reserve.get(k, 0)): best_v = v; best = k
	if best == "": return
	if battle.diplomacy.deliver_tribute(my_peer_id, ally, best):
		_diplo_last_tribute_time = battle.game_time

func find_valid_build_position(near_pos: Vector3, building_id: int) -> Vector3:
	var cfg = EntityDatabase.get_config(building_id)
	var radius = cfg.get("body_radius", 1.0)
	# 3v3/经典大陆的基地更拥挤：原来只搜到 20 米，且每个距离只试 8 个角度，
	# 常常找不到空位就放弃，导致民居/兵营长期只有 1~4 座。向外扩到 38 米并增加采样。
	for dist in [3, 5, 8, 12, 16, 20, 26, 32, 38]:
		for _try in range(12):
			var test = near_pos + Vector3(cos(randf_range(0, TAU))*dist, 0, sin(randf_range(0, TAU))*dist)
			var overlap = false
			# 旧实现每个候选点都全表扫一遍建筑/资源；6×8 个候选点会放大成
			# 几十次全场扫描。先用空间索引取附近实体，再按同样半径规则判断。
			var nearby: Array = []
			if battle.has_method("get_nearby_entities"):
				nearby = battle.get_nearby_entities(test, float(radius) + 14.0)
			else:
				nearby = battle.entities.get_children()
			for entity in nearby:
				# 单位会移动，不能因为附近站着农民/士兵就判定无法建造；只避让建筑和资源点
				if not (entity is Building or entity is WorldResource) or entity.health <= 0: continue
				if test.distance_to(entity.global_position) < (radius + entity.body_radius + 2.0):
					overlap = true; break
			if not overlap and _is_valid_build_ground(test):
				return test
	# 兜底也要走地形校验；找不到就返回 ZERO 让调用方跳过，绝不能盲目偏移硬塞
	for dist in [20, 26, 32, 38]:
		for _fb in range(12):
			var fp = near_pos + Vector3(cos(randf_range(0, TAU))*dist, 0, sin(randf_range(0, TAU))*dist)
			if _is_valid_build_ground(fp): return fp
	return Vector3.ZERO

# 基地被压制时，优先把民居/兵营补在敌军来的反方向，而不是继续围着主城
# 随机找位置。找不到合格背侧点时返回 ZERO，交给普通搜索兜底。
func _find_rebuild_position(building_id: int) -> Vector3:
	var castle = get_peer_castle(my_peer_id)
	if castle == null:
		return Vector3.ZERO
	var threat_pos: Vector3 = Vector3.ZERO
	var best_d: float = INF
	for e in _cached_armies():
		if not is_instance_valid(e) or not (e is Army) or e.health <= 0:
			continue
		if int(e.target_type) <= 0 or not _entity_is_enemy(e):
			continue
		var d: float = e.global_position.distance_squared_to(castle.global_position)
		if d < best_d and d <= 45.0 * 45.0:
			best_d = d
			threat_pos = e.global_position
	if threat_pos == Vector3.ZERO:
		return Vector3.ZERO
	var away: Vector3 = castle.global_position - threat_pos
	away.y = 0.0
	if away.length_squared() < 0.01:
		away = Vector3.BACK
	away = away.normalized()
	for dist in [8, 10, 12, 16, 20, 26, 32]:
		for deg in [-70, -45, -20, 0, 20, 45, 70]:
			var ang: float = float(deg) * PI / 180.0
			var test: Vector3 = castle.global_position + away.rotated(Vector3.UP, ang) * dist
			if not _enemy_army_within(test, 8.0) and _can_place_ai_building(building_id, test):
				return test
	return Vector3.ZERO

# 主城周围找不到位置时，再围绕自己的外围建筑找。经典大陆上主城常被资源点/
# 建筑围死，只围绕主城搜索会让 AI 永远补不到民居和兵营。
func _find_build_position_near_own(building_id: int) -> Vector3:
	var castle = get_peer_castle(my_peer_id)
	if castle == null:
		return Vector3.ZERO
	if building_id in [21, 28] and _base_under_attack():
		var rebuild_pos: Vector3 = _find_rebuild_position(building_id)
		if rebuild_pos != Vector3.ZERO:
			return rebuild_pos
	var pos: Vector3 = find_valid_build_position(castle.global_position, building_id)
	if pos != Vector3.ZERO:
		return pos
	var bases: Array = []
	for e in _cached_buildings():
		if not is_instance_valid(e) or not (e is Building) or e.health <= 0 or e.build_timer > 0.0:
			continue
		if not entity_belongs_to_me(e) or int(e.entity_id) in [7, 8]:
			continue
		bases.append(e)
	bases.sort_custom(func(a, b):
		return a.global_position.distance_squared_to(castle.global_position) \
				< b.global_position.distance_squared_to(castle.global_position)
	)
	for b in bases:
		pos = find_valid_build_position(b.global_position, building_id)
		if pos != Vector3.ZERO:
			return pos
	return Vector3.ZERO

func _get_build_position(b_id: int) -> Vector3:
	return _find_build_position_near_own(b_id)

# ═══ Worker allocation ═══
var allocate_timers = 0
# 同一轮农民分配里，资源点威胁只与资源点/敌人有关，与具体农民无关；
# 之前每个农民都会对每个资源点做一次 get_nearby_enemies，后期是 O(农民×资源)。
var _worker_threat_cache: Dictionary = {}

func allocate_workers():
	_worker_threat_cache.clear()
	var workers = []
	for entity in battle.entities.get_children():
		if entity is Army and entity.health > 0 and entity.entity_id == 10 and entity_belongs_to_me(entity):
			workers.append(entity)

	desired_worker_count = 15 if phase >= Phase.DEVELOPMENT else 8

	var non_delivering = []
	for w in workers:
		if w.current_order != "deliver": non_delivering.append(w)


	# 先救急：石油/石头已经满仓、但金/木/食物见底时，把正在采满仓资源的
	# 农民强行拉去采稀缺资源。旧的 97% 阈值要等资源几乎完全满仓才动，
	# 而 85% 泄压又早就开始了，中间这段收入会一直堆在不能造兵的资源上。
	_force_food_workers(workers)
	_emergency_rebalance_workers(workers)

	# 食物见底时先不要再补农民：一个农民 50 食物，会把本来就凑不齐的
	# 步兵 70 食物继续吃掉，形成“农民越多、兵越造不出”的死循环。
	var can_add_worker: bool = not (_food_emergency() and workers.size() >= 8)
	if workers.size() < desired_worker_count and can_add_worker and not _all_gather_resources_full():
		if can_afford(10) and _can_train_unit(): produce_unit(10)
		var train_weights: Dictionary = _worker_resource_weights()
		if not train_weights.is_empty():
			for w in non_delivering:
				if _worker_is_fleeing(w): continue
				var target = find_best_resource_for_worker(w, train_weights)
				if target: w.gather_at(target)

	# 已经达到目标农民数后，新增/逃跑回来的农民不会走上面的补农分支；
	# 这里每次分配都兜底处理完全空闲的农民，避免他们长期聚在主城不动。
	for w in workers:
		if _worker_is_fleeing(w):
			continue
		if w.has_meta("ai_flee_until"):
			w.remove_meta("ai_flee_until")
		if w.current_target == null and w.current_order == "":
			var idle_weights: Dictionary = _worker_resource_weights()
			if idle_weights.is_empty():
				continue
			var idle_target = find_best_resource_for_worker(w, idle_weights)
			if idle_target: w.gather_at(idle_target)

	# 某个资源快满仓时，正在采它的农民立即改采还有缺口的资源。
	# 旧逻辑只有每 11 次分配才检查一次，而且已经站在矿上的农民即使
	# 对应资源满仓也不会被改派，于是继续把收入送进被上限截断的池子。
	var full_types: Array = []
	for rk in ["gold", "wood", "stone", "food"]:
		if _resource_ratio(rk) >= _pressure_threshold():
			full_types.append(rk)
	if not full_types.is_empty():
		var alt_weights: Dictionary = _worker_resource_weights()
		if not alt_weights.is_empty():
			for w in workers:
				if _worker_is_fleeing(w) or w.current_order == "deliver":
					continue
				var tgt = w.current_target
				if not (is_instance_valid(tgt) and tgt is WorldResource):
					continue
				if not (tgt.resource_type in full_types):
					continue
				var alt = find_best_resource_for_worker(w, alt_weights)
				if alt != null and not (alt.resource_type in full_types):
					w.gather_at(alt)

	allocate_timers += 1
	if allocate_timers > 10:
		consider_warehouse_near_farmer()
		allocate_timers = 0
		var res = _get_resources()
		var limits = _get_limits()
		var phase_weights = _worker_resource_weights()
		var scarcity = {}
		for rk in ["gold","wood","stone","food"]:
			var pct = float(res.get(rk,0)) / max(limits.get(rk,500), 1)
			var base = max(0.05, 1.0 - pct) if pct <= 0.9 else 0.0
			scarcity[rk] = base * phase_weights.get(rk, 1.0)
		var total = 0.0
		for rk in scarcity: total += scarcity[rk]
		if total > 0:
			for rk in scarcity: scarcity[rk] = scarcity[rk] / total * desired_worker_count
		var current = {"gold":0,"wood":0,"stone":0,"food":0}
		var idle = []
		for w in non_delivering:
			var tgt = w.current_target
			if is_instance_valid(tgt) and tgt is WorldResource:
				var t = tgt.resource_type
				if t in current:
					current[t] += 1
					if current[t] > scarcity.get(t, 2): idle.append(w)
				else: idle.append(w)
			else: idle.append(w)
		for w in workers:
			if _worker_is_fleeing(w): continue
			if w.current_order == "deliver":
				for rk in ["gold","wood","stone","food"]:
					if w.cargo.get(rk, 0) > 0:
						current[rk] = current.get(rk, 0) + 1
						if current[rk] > scarcity.get(rk, 2): idle.append(w)
						break
		for w in idle:
			if _worker_is_fleeing(w): continue
			var best_rk = ""; var best_gap = -1.0
			for rk in scarcity:
				var gap = scarcity[rk] - current.get(rk, 0)
				if gap > best_gap: best_gap = gap; best_rk = rk
			if best_rk != "":
				var target = find_best_resource_for_worker(w, {best_rk: 100})
				if target: w.gather_at(target); current[best_rk] = current.get(best_rk, 0) + 1

# 满仓资源与见底资源同时存在时，优先救急改派农民。
# 食物低于 120 时，把一半左右的农民尽快拉去采食物。
# 普通 _emergency_rebalance_workers 最多只改 2~4 人，15 个农民时救不回食物。
func _force_food_workers(workers: Array) -> void:
	if battle == null or workers.is_empty() or not _food_emergency():
		return
	if battle.game_time - _last_emergency_rebalance_time < 4.0:
		return
	var on_food: int = 0
	var candidates: Array = []
	for w in workers:
		if not is_instance_valid(w) or w.health <= 0 or _worker_is_fleeing(w) or w.current_order == "deliver":
			continue
		var tgt = w.current_target
		if is_instance_valid(tgt) and tgt is WorldResource:
			if String(tgt.resource_type) == "food":
				on_food += 1
			elif String(tgt.resource_type) in ["gold", "wood", "stone"]:
				candidates.append(w)
	var want: int = clampi(int(workers.size() * 0.5), 4, 8)
	if on_food >= want:
		return
	var moved: int = 0
	for w in candidates:
		var target = find_best_resource_for_worker(w, {"food": 100})
		if target == null:
			break
		if String(target.resource_type) != "food":
			continue
		w.gather_at(target)
		moved += 1
		if on_food + moved >= want:
			break
	_last_emergency_rebalance_time = battle.game_time
	if moved > 0:
		_last_spend_block = "food_rebalanced"
	else:
		_last_spend_block = "no_food_target"
	_last_spend_block_time = battle.game_time

# 实战出现过：石油 700/700、金 12/800、木 0、食物 4，12 个农民仍在采油/石，
# 泄压一直在跑但所有兵都买不起。这里不等 97% 满仓，85% 就开始把采集满仓
# 资源的人拉去采最缺的那种资源；如果地图上找不到对应矿，只记录原因。
func _emergency_rebalance_workers(workers: Array) -> void:
	if battle == null or workers.is_empty():
		return
	if battle.game_time - _last_emergency_rebalance_time < 4.0:
		return
	var scarce: Array = []
	var overfull: Array = []
	for rk in ["gold", "wood", "food", "stone", "oil"]:
		var ratio: float = _resource_ratio(rk)
		if ratio >= _pressure_threshold():
			overfull.append(rk)
		elif rk != "oil" and ratio <= 0.20:
			scarce.append(rk)
	if scarce.is_empty() or overfull.is_empty():
		return
	scarce.sort_custom(func(a, b): return _resource_ratio(a) < _resource_ratio(b))
	var best_rk: String = String(scarce[0])
	var candidates: Array = []
	for w in workers:
		if _worker_is_fleeing(w) or w.current_order == "deliver":
			continue
		var tgt = w.current_target
		if is_instance_valid(tgt) and tgt is WorldResource and String(tgt.resource_type) in overfull:
			candidates.append(w)
	if candidates.is_empty():
		return
	var max_moves: int = clampi(int(workers.size() / 4), 2, 4)
	var moved: int = 0
	for w in candidates:
		var target = find_best_resource_for_worker(w, {best_rk: 100})
		if target == null:
			for rk in scarce:
				if String(rk) == best_rk:
					continue
				target = find_best_resource_for_worker(w, {String(rk): 100})
				if target != null:
					break
		if target == null:
			break
		w.gather_at(target)
		moved += 1
		if moved >= max_moves:
			break
	if moved > 0:
		_last_emergency_rebalance_time = battle.game_time
		_last_spend_block = "rebalanced_" + best_rk
		_last_spend_block_time = battle.game_time
	else:
		_last_spend_block = "no_target_" + best_rk
		_last_spend_block_time = battle.game_time

func _worker_is_fleeing(w) -> bool:
	if w == null or not is_instance_valid(w) or not w.has_meta("ai_flee_until"):
		return false
	return battle != null and battle.game_time < float(w.get_meta("ai_flee_until"))

func _get_build_completion() -> float:
	var total_targets = 0.0; var built = 0.0
	for b_id in wanted_buildings:
		var target = MILITARY_PRODUCER_TARGETS.get(b_id, 1)
		total_targets += target
		built += min(count_building(b_id), target)
	return built / max(total_targets, 1.0)

func _get_phase_weights() -> Dictionary:
	var w: Dictionary
	if phase == Phase.PRODUCTION:
		if count_unit(10) < 8:
			w = {"gold": 0.5, "wood": 1.5, "stone": 0.8, "food": 5.0}
		else:
			w = {"gold": 1.0, "wood": 3.0, "stone": 2.0, "food": 1.5}
	else:
		var build_pct = _get_build_completion()
		if build_pct < 0.4:
			w = {"gold": 2.0, "wood": 4.5, "stone": 3.5, "food": 2.0}
		elif build_pct < 0.75:
			w = {"gold": 3.0, "wood": 3.0, "stone": 4.0, "food": 3.0}
		else:
			w = {"gold": 4.0, "wood": 2.0, "stone": 5.0, "food": 3.0}
	# 石油只能由采集船采集，农民的可采列表里没有 oil。
	# 这里不能再把 oil 加进农民权重，否则 AI 会把农民派到油井边空站。
	if _food_emergency():
		var food_ratio: float = _resource_ratio("food")
		var food_weight: float = 10.0 if food_ratio <= 0.10 else 7.0
		w["food"] = maxf(float(w.get("food", 1.0)), food_weight)
		# 食物见底时不要再让木/石把农民全吸走。
		w["wood"] = float(w.get("wood", 1.0)) * 0.45
		w["stone"] = float(w.get("stone", 1.0)) * 0.45
	return w

# 农民不再去采已经接近上限的资源；否则交资源时会被 add_resource 截断。
# 这里返回的权重只去掉“危险满仓”的类型，85%~97% 之间仍允许继续补，
# 因为泄压流程会同时把资源花掉。
func _worker_resource_weights() -> Dictionary:
	var weights: Dictionary = _get_phase_weights()
	for rk in ["gold", "wood", "stone", "food"]:
		# 到压力阈值就不再优先派农民去采，避免一边泄压一边继续堆满仓资源。
		if _resource_ratio(rk) >= _pressure_threshold():
			weights.erase(rk)
	return weights

func _all_gather_resources_full() -> bool:
	for rk in ["gold", "wood", "stone", "food"]:
		if _resource_ratio(rk) < RESOURCE_CRITICAL_RATIO:
			return false
	return true

func clear_invalid_targets():
	for entity in battle.entities.get_children():
		if entity is Army and entity.health > 0 and entity_belongs_to_me(entity):
			if entity.current_target and not is_instance_valid(entity.current_target):
				entity.current_target = null
				entity.current_order = ""

# 农民选资源时，附近敌军只做“适度避让”，不能像以前那样直接 -500 把所有
# 受威胁资源一票否决；否则资源区一有敌人，农民就会全部缩回主城不出去。
const WORKER_THREAT_RADIUS: float = 12.0
const WORKER_THREAT_MAX_PENALTY: float = 2.5

func find_best_resource_for_worker(worker: Army, priority_score: Dictionary) -> WorldResource:
	var best = null; var best_score: float = -INF
	for entity in battle.entities.get_children():
		if entity is WorldResource and entity.health > 0:
			var type = entity.resource_type
			# 按单位自己的可采列表过滤：农民不能采石油，采集船不能采陆地上的木/金/石/粮。
			# 之前只按 AI 权重找最近资源，导致农民被派去油井后原地空站。
			if worker.gatherable_resources.size() > 0 and not type in worker.gatherable_resources:
				continue
			# 玩家在资源面板点“停止采集”后，本队农民（含同队 AI）两分钟内不再选它。
			if battle.has_method("is_resource_gather_blacklisted") \
					and battle.is_resource_gather_blacklisted(entity, worker.team):
				continue
			if type in priority_score:
				var score = priority_score[type] - worker.global_position.distance_to(entity.global_position) * 0.01
				var threat_penalty: float = float(_worker_threat_cache.get(entity, -1.0))
				if threat_penalty < 0.0:
					threat_penalty = 0.0
					var nearby: Array = []
					if battle.has_method("get_nearby_enemies"):
						nearby = battle.get_nearby_enemies(entity.global_position, WORKER_THREAT_RADIUS, worker.team, worker.owner_peer_id, true)
					else:
						nearby = battle.entities.get_children()
					for e in nearby:
						if not (e is Army) or e.health <= 0:
							continue
						if e.entity_id in [10, 14, 43, 44, 45]:
							continue
						if e.get("_animal_type") != null and str(e.get("_animal_type")) != "":
							continue
						if not _entity_is_enemy(e):
							continue
						var d: float = e.global_position.distance_to(entity.global_position)
						if d < WORKER_THREAT_RADIUS:
							# 距离越近惩罚越大，但上限只有 2.5，低于大多数资源权重，
							# 保证农民仍会挑一个相对安全的矿点出门，而不是全留主城。
							threat_penalty = maxf(threat_penalty, (1.0 - d / WORKER_THREAT_RADIUS) * WORKER_THREAT_MAX_PENALTY)
					_worker_threat_cache[entity] = threat_penalty
				score -= threat_penalty
				if score > best_score: best_score = score; best = entity
	return best

# 已有驻扎点的部队不再被进攻/打猎/巡逻调用；建筑被攻击时的本地反击单位
# 同样在短时间内保留目标，避免刚出门就被别的调度覆盖。
func _is_local_defense_active(u) -> bool:
	if u == null or not is_instance_valid(u) or not u.has_meta("ai_building_defense_until"):
		return false
	if float(battle.game_time) < float(u.get_meta("ai_building_defense_until")):
		return true
	u.remove_meta("ai_building_defense_until")
	return false

func _is_held_by_garrison(u) -> bool:
	if u == null or not is_instance_valid(u):
		return true
	if u.garrison_point != Vector3.ZERO:
		return true
	# 已预约进驻建筑、正在赶路：在抵达前也不能被主攻/集结/守家调度拉走。
	if int(u.get("_garrison_target_id")) != -1:
		return true
	return _is_local_defense_active(u)

func attack_move(target_position: Vector3, max_units: int):
	var sent = 0
	for entity in battle.entities.get_children():
		if sent >= max_units: break
		if entity is Army and entity.health > 0 and int(entity.entity_id) not in [5,6,9,10,14,33,43,44,45,46,47,48,49,50,51] and entity_belongs_to_me(entity):
			if _is_scout_unit(entity):
				continue
			if entity.has_meta("ai_home_guard") or entity.has_meta("ai_resource_guard") or entity.has_meta("ai_harass") or entity.has_meta("ai_transporting") or entity.has_meta("ai_escorting") or entity.has_meta("ai_wall_guard"):
				continue
			# 已有驻扎点的部队不再被主攻调用（防守时由 AIDefense 单独调度）
			if entity.garrison_point != Vector3.ZERO:
				continue
			if _is_local_defense_active(entity):
				continue
			# 账本里已有角色（守军/守墙/驻军/骚扰/待命）的单位不归主攻调度。
			if _roles.has(entity.get_instance_id()):
				continue
			# 主攻只调度真正空闲的野战部队。正在交战/移动/攻击移动/排队命令的单位
			# 如果被重新下发，会清空 current_target 和命令队列，表现为“打两下就转身”。
			if entity.current_target != null or entity.current_order != "" or entity.is_attack_moving:
				continue
			if not entity.command_queue.is_empty():
				continue
			# 海军不能收到陆地城堡的攻击移动命令，否则会一直寻路失败。
			if entity.water_capable:
				continue
			var boarded = entity.get("_boarded_on")
			if boarded != null and int(boarded) != -1:
				continue
			entity.attack_move_to(target_position)
			_director_claim(entity, UnitRole.FIELD, 30.0)
			sent += 1

func an_attack() -> bool:
	var now = Time.get_ticks_msec() / 1000.0
	if now - last_attack_time < 10.0: return false
	last_attack_time = now
	return true

func _should_build_or_upgrade(b_id: int) -> bool:
	if b_id == 25 and count_building(25) >= 5: return false
	if count_building(b_id) == 0: return true
	# 科技攒钱期间不要顺手把主城升5级，优先保证29/59的前置科技
	if b_id == 20 and _heavy_siege_tech_reserve_active():
		return false
	# 29升到4级已解锁59，先把第一台59造出来再考虑升5级，别把石/油又吃光
	if b_id == HEAVY_SIEGE_BUILDING_ID and _trebuchet_pending():
		var highest_lv = 0
		for entity in battle.entities.get_children():
			if entity is Building and entity.health > 0 and entity.entity_id == b_id and entity_belongs_to_me(entity):
				highest_lv = maxi(highest_lv, int(entity.upgrade_level))
		if highest_lv >= 4:
			return false
	for entity in battle.entities.get_children():
		if entity is Building and entity.health > 0 and entity.entity_id == b_id:
			if not entity_belongs_to_me(entity): continue
			if entity.upgrade_level < entity.max_upgrade_level: return true
	return false

# ═══ Warehouse ═══
func _can_afford_warehouse() -> bool:
	if not _resource_overflow():
		return can_afford_building(22)
	var cfg = EntityDatabase.get_config(22)
	if not cfg: return false
	var res = _get_resources()
	for k in cfg.get("cost", {}):
		if int(res.get(k, 0)) < int(cfg["cost"][k]): return false
	# 资源已经到上限时，时代预算继续囤也存不进去；仓库抬高上限反而有利于后续攒钱。
	return true

func consider_warehouse_near_farmer():
	if count_building(22) >= WAREHOUSE_MAX_COUNT:
		return
	var overflow: bool = _resource_overflow()
	var castle = get_peer_castle(my_peer_id)
	if not castle: return
	var res = _get_resources(); var limits = _get_limits()
	var farmer_data = []
	for entity in battle.entities.get_children():
		if entity is Army and entity.health > 0 and entity.entity_id == 10 and entity_belongs_to_me(entity):
			var tgt = entity.current_target
			if is_instance_valid(tgt) and tgt is WorldResource: farmer_data.append({"farmer": entity, "resource": tgt})
	if not farmer_data.is_empty():
		var best_score = -999.0; var best_pos = Vector3.ZERO
		for item in farmer_data:
			var rn = item.resource; var rp = rn.global_position; var rt = rn.resource_type
			var s1 = min(rp.distance_to(castle.global_position) / 30.0, 1.0) * 5.0
			var s2 = max(0.0, 1.0 - float(res.get(rt,0)) / max(limits.get(rt,500), 1)) * 3.0
			var nf = 0
			for other in farmer_data:
				if other.resource.global_position.distance_to(rp) < 5.0: nf += 1
			var s3 = min(float(nf)/5.0, 1.0) * 1.0
			var nr = 0
			for e in battle.entities.get_children():
				if e is WorldResource and e.health > 0 and e.global_position.distance_to(rp) < 6.0: nr += 1
			var s4 = min(float(nr)/5.0, 1.0) * 1.0
			# Heavily penalize proximity to existing warehouses (<20m → -10 score)
			var wh_penalty = 0.0
			for ew in battle.entities.get_children():
				if ew is Building and ew.entity_id == 22 and ew.team == my_team and ew.health > 0:
					var wd = ew.global_position.distance_to(rp)
					if wd < 25.0: wh_penalty += max(0.0, 10.0 - wd * 0.4)  # closer = bigger penalty
			var score = s1 + s2 + s3 + s4 - wh_penalty
			if score > best_score:
				best_score = score
				for _t in range(5):
					var tp = rp + Vector3(randf_range(-2.5,2.5), 0, randf_range(-2.5,2.5))
					if _is_valid_build_ground(tp): best_pos = tp; break
				if best_pos == Vector3.ZERO: best_pos = rp + Vector3(randf_range(-2,2), 0, randf_range(-2,2))
		if best_pos != Vector3.ZERO and (best_score >= 2.0 or overflow) and _can_afford_warehouse():
			build_building(22, best_pos)
			return
	# 资源已经溢出但附近没有可跟随的农民资源点时，也要在城堡附近补仓库抬上限，
	# 否则采集队继续交资源会被满仓截断，玩家会看到 AI 永远不造仓库。
	if overflow and _can_afford_warehouse():
		var wpos: Vector3 = find_valid_build_position(castle.global_position, 22)
		if wpos != Vector3.ZERO:
			build_building(22, wpos)

func _is_valid_build_ground(world_pos: Vector3) -> bool:
	var gx = int(world_pos.x + RTSConfig.MAP_SIZE / 2); var gz = int(world_pos.z + RTSConfig.MAP_SIZE / 2)
	if gx < 0 or gx >= RTSConfig.MAP_SIZE or gz < 0 or gz >= RTSConfig.MAP_SIZE: return false
	if battle.get_terrain_at_grid(gx, gz) != 0: return false
	# 只检查建造点周围：己方建筑要留出间距，敌人靠近则视为危险。
	# 以前对每个候选点全表扫两遍，AI 每次选址会重复几十次。
	var nearby: Array = []
	if battle.has_method("get_nearby_entities"):
		nearby = battle.get_nearby_entities(world_pos, 12.0)
	else:
		nearby = battle.entities.get_children()
	for e in nearby:
		if e is Building and e.team == my_team and e.health > 0:
			if e.global_position.distance_to(world_pos) < (e.body_radius + 3.0): return false
		if _entity_is_enemy(e):
			if e.global_position.distance_to(world_pos) < 10.0: return false
	return true

# ═══ Territory ═══
# 资源前哨已交给 AIDefense 统一按“正在采集的资源区 + 瞭望塔/守军”规划，
# 这里不再随机在资源旁边撒箭塔，避免消耗防线的石头与建造位。
func _ai_expand_territory():
	pass

# ═══ Officials ═══
func _ai_garrison_officials():
	# 书院被拆后不要停止管理已有官员：他们仍然可以进驻剩余建筑，
	# 只是享受不到书院等级加成。原来看 count_building(42)==0 就直接返回，
	# 会留下一批永远站在野外的官员。
	for entity in battle.entities.get_children():
		if not (entity is Army and entity.entity_id >= 46 and entity.entity_id <= 50 and entity.health > 0): continue
		if not entity_belongs_to_me(entity): continue
		if Time.get_ticks_msec() < int(entity.get_meta("_official_retry_after", 0)): continue
		var gb = entity.get("_garrison_building")
		if gb and gb.get_ref():
			# 之前因为缺少对应建筑而临时退回主城的官员，一旦 AI 补回仓库/塔/
			# 生产建筑，就重新改派到真正能发挥作用的建筑，不能一直留在主城。
			if entity.entity_id in [46, 47, 48] and not _official_building_is_preferred(entity.entity_id, gb.get_ref()):
				# 已经在前往另一栋建筑的路上时不要重复改派，尤其 48 的目标是
				# 随机选的，否则每轮 think 都可能换目标，官员永远走不到。
				if int(entity.get("_garrison_target_id")) != -1:
					continue
				var preferred := _find_preferred_official_building_s(entity.entity_id)
				if preferred != null:
					entity.command_garrison(preferred)
			continue
		if entity.get("_garrison_target_id") != -1:
			# 目标建筑中途被拆/开始重建时，及时清掉目标，下一轮重新选空位
			var target_id := int(entity.get("_garrison_target_id"))
			var existing_target: Building = null
			for b in battle.entities.get_children():
				if b is Building and b.get_instance_id() == target_id:
					existing_target = b
					break
			if existing_target == null or existing_target.health <= 0 or existing_target.build_timer > 0:
				entity._garrison_target_id = -1
				entity._set_order(Army.UnitState.IDLE)
				entity._movement.stop()
			elif entity._movement.move_path_failed:
				# 目标建筑还在，但路径失败（被墙/水隔断等）：清掉目标并短暂退避，
				# 否则 _garrison_target_id 会一直非 -1，AI 永远不会重新选址。
				entity._garrison_target_id = -1
				entity._set_order(Army.UnitState.IDLE)
				entity._movement.stop()
				entity.set_meta("_official_retry_after", Time.get_ticks_msec() + 3000)
			continue
		# 统帅(49)不占建筑，只需要待在城堡/主力附近提供光环；
		# 原逻辑没有 49 的分支，AI 造出来后会永远闲置。
		if entity.entity_id == 49:
			if entity._order_is(Army.UnitState.MOVING):
				continue
			var commander_hold_until := int(entity.get_meta("_ai_commander_hold_until", 0))
			if Time.get_ticks_msec() < commander_hold_until:
				continue
			var station := _find_commander_station_s()
			if station:
				entity.command_garrison(station)
				# 统帅不占建筑，到达后 _garrison_target_id 仍是 -1；
				# 加一个冷却，避免 AI 每轮 think 都重新下发移动命令。
				entity.set_meta("_ai_commander_hold_until", Time.get_ticks_msec() + 15000)
			continue
		var target: Building = null
		match entity.entity_id:
			46: target = _find_vacant_warehouse_s()
			47: target = _find_vacant_tower_s()
			48: target = _find_random_prod_or_def_s()
			50: target = _find_most_officiated_s()
		if target == null:
			# 暂时没有对应类型的空建筑（例如仓库/塔被拆光）时，先退回主城，
			# 至少不要站在野外闲置；等 AI 补回对应建筑后会再改派。
			target = _find_commander_station_s()
		if target: entity.command_garrison(target)

# AI 普通部队进驻防御建筑：箭塔/炮塔/城堡。
# 与官员不同，士兵/农民走 _garrison_target_id + move_to 的到达进驻流程。
func _ai_garrison_soldiers() -> void:
	if _defense == null:
		return
	var castle = get_peer_castle(my_peer_id if my_peer_id != -1 else my_team)
	if castle == null or not is_instance_valid(castle):
		return
	var defending: bool = _is_defending() or int(_defense.threat_level) >= 1
	var pending: Dictionary = {}
	var candidates: Array = []
	for e in _cached_armies():
		if not is_instance_valid(e) or e.health <= 0:
			continue
		if not entity_belongs_to_me(e):
			continue
		# 农民、官员、商人、侦察兵、攻城器械和海军不参与塔内驻军。
		if int(e.entity_id) in [10, 14, 16, 17, 18, 19, 43, 44, 45, 46, 47, 48, 49, 50, 51, 59]:
			continue
		if e.water_capable or e.hold_position:
			continue
		if e.has_meta("ai_home_guard") or e.has_meta("ai_wall_guard") \
				or e.has_meta("ai_resource_guard") or e.has_meta("ai_harass") \
				or e.has_meta("ai_transporting") or e.has_meta("ai_escorting") \
				or e.has_meta("ai_building_defense_until"):
			continue
		if _is_local_defense_active(e):
			continue
		var boarded = e.get("_boarded_on")
		if boarded != null and int(boarded) != -1:
			continue
		var sgb = e.get("_soldier_garrison_building")
		if sgb != null and sgb.get_ref() != null:
			continue
		var tid := int(e.get("_garrison_target_id"))
		if tid != -1:
			# 已经在赶去进驻：目标失效/已满/寻路失败时清掉预约，下一轮重新分配。
			var target = instance_from_id(tid)
			var target_ok: bool = target != null and is_instance_valid(target) \
				and target.health > 0 and target.has_method("can_garrison_soldier") \
				and target.can_garrison_soldier()
			if not target_ok or (e._movement != null and e._movement.move_path_failed):
				e._garrison_target_id = -1
				if e.has_method("stop_movement"):
					e.stop_movement()
				continue
			pending[tid] = int(pending.get(tid, 0)) + 1
			continue
		if e.garrison_point != Vector3.ZERO:
			continue
		if e.current_target != null or e.current_order != "" or e.is_attack_moving:
			continue
		if not e.command_queue.is_empty():
			continue
		if e.has_method("_is_unit_on_wall") and e._is_unit_on_wall():
			continue
		candidates.append(e)
	var buildings: Array = []
	for b in _cached_buildings():
		if not is_instance_valid(b) or b.health <= 0 or not entity_belongs_to_me(b):
			continue
		if int(b.entity_id) not in [25, 26, 53]:
			continue
		if b.build_timer > 0.0 or not b.can_garrison_soldier():
			continue
		buildings.append(b)
	if buildings.is_empty() or candidates.is_empty():
		return
	buildings.sort_custom(func(x, y):
		return x.global_position.distance_squared_to(castle.global_position) \
			< y.global_position.distance_squared_to(castle.global_position))
	var assigned_total := 0
	var total_cap := 12 if defending else 6
	for b in buildings:
		if assigned_total >= total_cap:
			break
		var bid: int = int(b.get_instance_id())
		var want := GARRISON_CASTLE_WANT if int(b.entity_id) == 53 else GARRISON_TOWER_WANT
		if defending:
			want = GARRISON_CASTLE_WANT_DEFEND if int(b.entity_id) == 53 else GARRISON_TOWER_WANT_DEFEND
		var have := int(b.get_garrison_count()) + int(pending.get(bid, 0))
		var need := want - have
		if need <= 0:
			continue
		# 优先把远程兵放进塔里；同距离下近战再补位。
		var ranged: Array = []
		var melee: Array = []
		for u in candidates:
			if u.global_position.distance_to(b.global_position) > GARRISON_MAX_DISTANCE:
				continue
			if float(u.attack_range) >= 2.0:
				ranged.append(u)
			else:
				melee.append(u)
		ranged.sort_custom(func(a, c):
			return a.global_position.distance_squared_to(b.global_position) \
				< c.global_position.distance_squared_to(b.global_position))
		melee.sort_custom(func(a, c):
			return a.global_position.distance_squared_to(b.global_position) \
				< c.global_position.distance_squared_to(b.global_position))
		var pool: Array = ranged + melee
		var take := mini(need, pool.size())
		for i in range(take):
			var u = pool[i]
			if not is_instance_valid(u):
				continue
			u._garrison_target_id = bid
			_director_claim(u, UnitRole.GARRISON, 20.0)
			u.move_to(b.global_position)
			candidates.erase(u)
			assigned_total += 1
		pending[bid] = int(pending.get(bid, 0)) + take

# ═══ Hunting ═══
# 沙漠类地图食物资源几乎为零、全靠兽群：狩猎要更频繁、范围更大，并允许农民一起上
func _is_hunting_heavy_map() -> bool:
	if String(GameSettings.map_id) == "desert":
		return true
	# 其它把 food 资源权重压到 0 的自定义图，同样按「以狩猎为食」处理
	var map = battle.get_node_or_null("Map")
	if map and map.get("map_preset") is Dictionary:
		var res: Dictionary = map.map_preset.get("resources", {})
		if res.has("food") and float(res.get("food", 1.0)) <= 0.0:
			return true
	return false

func _ai_hunt_animals(delta):
	_hunt_timer -= delta
	if _hunt_timer > 0: return
	_hunt_timer = 8.0   # 持续狩猎：每 8 秒补齐一次猎手，动物死了能自动换目标

	# 只派农民；农民总数超过 15 才分人出去，前期不打断采集
	var peasants: Array = []
	for e in battle.entities.get_children():
		if not (e is Army) or e.health <= 0: continue
		if e.entity_id != 10: continue
		if not entity_belongs_to_me(e): continue
		if _is_held_by_garrison(e): continue
		peasants.append(e)
	if peasants.size() <= HUNT_MIN_PEASANTS: return

	# 统计已经在打猎的农民（攻击目标带 _animal_type）
	var hunters: Array = []
	for e in peasants:
		var t = e.current_target
		if t != null and is_instance_valid(t):
			var at0 = t.get("_animal_type")
			if at0 != null and str(at0) != "":
				hunters.append(e)
	if hunters.size() >= HUNT_PEASANT_COUNT: return

	var castle = get_peer_castle(my_peer_id)
	if not castle: return

	# 找附近的陆地动物（农民不下水，鱼留给渔船）
	var search_r: float = 60.0 if _is_hunting_heavy_map() else 30.0
	var animals = []
	for e in battle.entities.get_children():
		if e is Army and e.health > 0:
			var at = e.get("_animal_type")
			if at != null and str(at) != "":
				if str(at) == "fish": continue
				var d = castle.global_position.distance_to(e.global_position)
				if d < search_r:
					animals.append({"entity": e, "dist": d})
	if animals.is_empty(): return
	animals.sort_custom(func(a, b): return a.dist < b.dist)

	# 选一只还没围满猎手的动物
	var hunt_target = null
	for ai in animals:
		var existing = 0
		for e in battle.entities.get_children():
			if e is Army and entity_belongs_to_me(e) and e.current_target == ai.entity: existing += 1
		if existing < HUNT_PEASANT_COUNT: hunt_target = ai.entity; break
	if not hunt_target: return

	# 补齐到固定 5 个：优先闲置农民，不够再从采集农民里抽（总数 >15 有余量）
	var need: int = HUNT_PEASANT_COUNT - hunters.size()
	var candidates: Array = []
	for e in peasants:
		if hunters.has(e): continue
		if e.current_order == "" and e.current_target == null:
			candidates.append(e)
	if candidates.size() < need:
		for e in peasants:
			if hunters.has(e) or candidates.has(e): continue
			candidates.append(e)
	for u in candidates:
		if need <= 0: break
		u.attack_target(hunt_target)
		need -= 1
	_hunt_target = hunt_target; _hunt_target_id = hunt_target.get_instance_id()

func _check_hunt_cleanup():
	if not _hunt_target or not is_instance_valid(_hunt_target): return
	var active_hunters = 0
	for e in battle.entities.get_children():
		if e is Army and entity_belongs_to_me(e) and e.current_target == _hunt_target:
			active_hunters += 1
	if active_hunters < 2:
		for e in battle.entities.get_children():
			if e is Army and entity_belongs_to_me(e) and e.current_target == _hunt_target:
				e.current_target = null; e.current_order = ""
				if e.entity_id == 10: e._find_nearest_resource()
		_hunt_target = null
		# 猎杀完成后快速寻找新目标（若猎人不足3）
		if active_hunters >= 3:
			_hunt_timer = 5.0

# ═══ Tactics ═══
func update_tactic(_delta):
	var now = Time.get_ticks_msec() / 1000.0
	var my_key = my_peer_id if my_peer_id != -1 else my_team
	var my_mil = count_field_military(my_key)
	# 战术判断只看当前视野内看到的敌军，不读取全图敌人军力
	var player_mil = _visible_enemy_military()
	_cleanup_harass_squad(float(battle.game_time))

	var threat: int = 0
	if _defense != null:
		threat = int(_defense.threat_level)

	# 敌人已经压到基地：立即转防守并召回守军，暂停所有进攻战术
	if threat >= 2:
		_harass_until = -999.0
		_cleanup_harass_squad(float(battle.game_time))
		if current_tactic != LateTactic.DEFEND:
			start_defense()
			current_tactic = LateTactic.DEFEND
			last_tactic_time = now
		return

	# 防守姿态：只有 threat>=2（真正压上基地）才继续锁死；警戒级由守军处理，
	# 兵力成型且未被明显压制时恢复进攻，不能永远缩在城里
	if current_tactic == LateTactic.DEFEND:
		# 只有威胁重新升到“真正压上基地”才继续锁死；警戒级可由守军处理，主力恢复进攻
		if threat >= 2:
			return
		if my_mil >= 12 and player_mil <= my_mil * 1.35:
			current_tactic = LateTactic.NONE
			last_tactic_time = now
		return

	if player_mil > my_mil * 1.5:
		return

	# 兵力成型（>=20 野战兵）时不再满足于骚扰小队：直接切成全军压上，
	# 否则大部队会长期待在主城里，实际参战比很低（实测 27 兵只有 8 个在交战）。
	if my_mil >= 20 and current_tactic in [LateTactic.HARASS, LateTactic.RAID, LateTactic.NONE] \
			and now - last_tactic_time >= TACTIC_COOLDOWN:
		current_tactic = LateTactic.OVERWHELM
		execute_overwhelm()
		last_tactic_time = now
		return

	if now - last_tactic_time < TACTIC_COOLDOWN and current_tactic != LateTactic.NONE: return

	if my_mil > player_mil * 1.1 and my_mil > 10:
		current_tactic = LateTactic.OVERWHELM
		execute_overwhelm()
	elif my_mil >= 4:
		if randf() < 0.65:
			current_tactic = LateTactic.HARASS
			execute_harass()
		elif my_mil >= 10:
			current_tactic = LateTactic.RAID
			execute_raid()
		else:
			current_tactic = LateTactic.HARASS
			execute_harass()
	last_tactic_time = now

# 骚扰改为 2-3 个高机动单位的小队，优先打外围农民/商队，不再把全军拉去拆仓库。
func execute_harass():
	_harass_until = -999.0
	_cleanup_harass_squad(float(battle.game_time))
	var my_castle = get_peer_castle(my_peer_id)
	var enemy_castle = _get_attack_target_castle()
	var target = _find_harass_target(my_castle, enemy_castle)
	if target == null:
		current_tactic = LateTactic.NONE
		return
	var squad: Array = _pick_harass_squad(my_castle)
	if squad.is_empty():
		current_tactic = LateTactic.NONE
		return
	for u in squad:
		if not is_instance_valid(u) or u.health <= 0:
			continue
		u.set_meta("ai_harass", true)
		_director_claim(u, UnitRole.HARASS, 32.0)
		u.attack_move_to(target.global_position)
		_harass_ids[u.get_instance_id()] = true
	_harass_until = battle.game_time + 32.0

func _find_harass_target(my_castle, enemy_castle):
	var best = null
	var best_score = -INF
	for e in battle.entities.get_children():
		if not (e is Army) or e.health <= 0:
			continue
		if not _entity_is_enemy(e):
			continue
		if int(e.entity_id) not in [10, 5, 6, 43, 44, 45, 51, 14]:
			continue
		if e.water_capable:
			continue
		if enemy_castle and is_instance_valid(enemy_castle):
			if e.global_position.distance_to(enemy_castle.global_position) < 12.0:
				continue
		var d_us: float = my_castle.global_position.distance_to(e.global_position) if my_castle else 999.0
		if d_us > 95.0:
			continue
		var d_enemy: float = e.global_position.distance_to(enemy_castle.global_position) if enemy_castle else 30.0
		var score: float = minf(d_enemy, 60.0) * 0.6 - d_us * 0.02
		if int(e.entity_id) == 10:
			score += 2.0
		if score > best_score:
			best_score = score
			best = e
	if best != null:
		return best
	# 没有外围经济单位时，退而拆远离敌主城的仓库/船坞
	for e in battle.entities.get_children():
		if not (e is Building) or e.health <= 0 or not _entity_is_enemy(e):
			continue
		if int(e.entity_id) not in [22, 23]:
			continue
		if enemy_castle and e.global_position.distance_to(enemy_castle.global_position) < 15.0:
			continue
		if my_castle and e.global_position.distance_to(my_castle.global_position) > 95.0:
			continue
		return e
	return null

func _pick_harass_squad(my_castle) -> Array:
	var candidates: Array = []
	for e in battle.entities.get_children():
		if not (e is Army) or e.health <= 0 or not entity_belongs_to_me(e):
			continue
		if int(e.target_type) <= 0 or e.water_capable:
			continue
		if _is_scout_unit(e):
			continue
		var sgb = e.get("_soldier_garrison_building")
		if sgb != null and sgb.get_ref() != null:
			continue
		if e.has_meta("ai_home_guard") or e.has_meta("ai_resource_guard") or e.has_meta("ai_transporting") or e.has_meta("ai_escorting") or e.has_meta("ai_wall_guard"):
			continue
		if e.garrison_point != Vector3.ZERO:
			continue
		if _is_local_defense_active(e):
			continue
		var boarded = e.get("_boarded_on")
		if boarded != null and int(boarded) != -1:
			continue
		if int(e.entity_id) in [16, 17, 18, 40, 58, 59]:
			continue
		if float(e.speed) < 1.7:
			continue
		var d: float = e.global_position.distance_to(my_castle.global_position) if my_castle else 0.0
		candidates.append({"u": e, "d": d})
	candidates.sort_custom(func(a, b): return float(a["d"]) < float(b["d"]))
	var out: Array = []
	for item in candidates:
		if out.size() >= 3:
			break
		out.append(item["u"])
	return out

func _cleanup_harass_squad(now: float) -> void:
	if now < _harass_until and _harass_ids.size() > 0:
		return
	for uid in _harass_ids.keys():
		var u = instance_from_id(int(uid))
		if u != null and is_instance_valid(u) and u.has_meta("ai_harass"):
			u.remove_meta("ai_harass")
	_harass_ids.clear()

func execute_overwhelm():
	var enemy_castle = _get_attack_target_castle()
	if not enemy_castle:
		current_tactic = LateTactic.NONE
		return
	# 不再为了主攻解除已有驻扎点的部队；常驻守军/玩家驻扎部队留在原地
	var rally = enemy_castle.global_position + Vector3(0, 0, 5)
	#if wall_positions.size() > 0: rally = wall_positions[wall_positions.size()/2] + Vector3(0, 0, 2)
	var self_castle = get_peer_castle(my_peer_id)
	if not self_castle:
		current_tactic = LateTactic.NONE
		return
	# 第一波：召集全军到敌方集结点（取消距离限制，确保全军参与）
	for entity in battle.entities.get_children():
		if entity is Army and entity_belongs_to_me(entity) and entity.health > 0:
			if int(entity.entity_id) in [5,6,10,14,33,43,44,45,46,47,48,49,50,51]: continue
			if _is_scout_unit(entity): continue
			if entity.has_meta("ai_home_guard") or entity.has_meta("ai_resource_guard") or entity.has_meta("ai_harass") or entity.has_meta("ai_wall_guard"): continue
			if _is_held_by_garrison(entity): continue
			if entity.water_capable: continue
			# 已经在交战/移动的单位不重新下发，避免“全军压上”把前线目标清掉。
			if entity.current_target != null or entity.current_order != "" or entity.is_attack_moving: continue
			entity.attack_move_to(rally)
	# 等待部队集结
	await get_tree().create_timer(10.0, false).timeout
	if _defense != null and int(_defense.threat_level) >= 2:
		return
	# 第二波：全军压上敌方城堡
	for entity in battle.entities.get_children():
		if entity is Army and entity_belongs_to_me(entity) and entity.health > 0:
			if int(entity.entity_id) in [5,6,10,14,33,43,44,45,46,47,48,49,50,51]: continue
			if _is_scout_unit(entity): continue
			if entity.has_meta("ai_home_guard") or entity.has_meta("ai_resource_guard") or entity.has_meta("ai_harass") or entity.has_meta("ai_wall_guard"): continue
			if _is_held_by_garrison(entity): continue
			if entity.water_capable: continue
			if entity.current_target != null or entity.current_order != "" or entity.is_attack_moving: continue
			if not enemy_castle or not is_instance_valid(enemy_castle): continue
			entity.attack_move_to(enemy_castle.global_position)

func execute_raid():
	var self_castle = get_peer_castle(my_peer_id)
	if not self_castle or self_castle.level < 3:
		current_tactic = LateTactic.NONE
		return
	var enemy_castle = _get_attack_target_castle()
	if not enemy_castle or not is_instance_valid(enemy_castle):
		current_tactic = LateTactic.NONE
		return
	var enemy_team: int = int(enemy_castle.team)
	var enemy_pos = enemy_castle.global_position
	var special_uid = RAID_UNIT
	if NationData.NATION_UNITS.has(nation) and NationData.NATION_UNITS.get(nation).size() >= 2:
		special_uid = NationData.NATION_UNITS.get(nation)[1]["unit_id"]
	# 木牛流马不参与偷袭，改用普通步兵。
	if int(special_uid) == 33:
		special_uid = 11
	var _raid_attempts = 0
	while count_unit(special_uid) < RAID_MIN_SPECIAL_TROOPS and _raid_attempts < 10:
		if can_afford(special_uid) and _can_train_unit(): produce_unit(special_uid)
		else: break
		_raid_attempts += 1
	var enemy_dir = _get_enemy_army_direction(enemy_pos)
	var flank = randf_range(RAID_FLANK_MIN, RAID_FLANK_MAX)
	var side = sign(randf() - 0.5)
	var waypoint = enemy_pos + enemy_dir.rotated(Vector3.UP, deg_to_rad(90*side)) * flank
	if _is_near_enemy_tower(waypoint, AVOID_DEFENSE_RANGE, enemy_team):
		waypoint = enemy_pos + enemy_dir.rotated(Vector3.UP, deg_to_rad(-90*side)) * (flank + 12)
	var raid_army = []
	for e in battle.entities.get_children():
		if e is Army and e.team == my_team and e.health > 0 and (int(e.entity_id) not in [5,6,9,10,14,33,43,44,45,46,47,48,49,50,51]) and entity_belongs_to_me(e):
			if _is_scout_unit(e):
				continue
			if e.has_meta("ai_home_guard") or e.has_meta("ai_resource_guard") or e.has_meta("ai_harass") or e.has_meta("ai_wall_guard"):
				continue
			if _is_held_by_garrison(e):
				continue
			if e.water_capable:
				continue
			raid_army.append(e)
	if raid_army.is_empty(): return
	if raid_army.size() > 10:
		raid_army = raid_army.slice(0, 10)
	var half = raid_army.size() / 2
	for i in range(half):
		if is_instance_valid(raid_army[i]): raid_army[i].move_to(waypoint)
	await get_tree().create_timer(1.8, false).timeout
	if _defense != null and int(_defense.threat_level) >= 2:
		return
	for i in range(half, raid_army.size()):
		if is_instance_valid(raid_army[i]): raid_army[i].move_to(waypoint)
	await get_tree().create_timer(RAID_WAIT_TIME, false).timeout
	if _defense != null and int(_defense.threat_level) >= 2:
		return
	for u in raid_army:
		if is_instance_valid(u) and is_instance_valid(enemy_castle): u.attack_move_to(enemy_castle.global_position)

func _get_enemy_army_direction(center: Vector3) -> Vector3:
	var enemy_team = _primary_enemy_team()
	var sum = Vector3.ZERO; var cnt = 0
	for e in battle.entities.get_children():
		if e is Army and e.team == enemy_team and e.health > 0:
			var d = e.global_position - center
			if d.length() > 12: sum += d.normalized(); cnt += 1
	return Vector3.FORWARD if cnt == 0 else sum.normalized()

func _is_near_enemy_tower(pos: Vector3, range: float, enemy_team: int) -> bool:
	for e in battle.entities.get_children():
		if e is Building and e.team == enemy_team and e.health > 0 and e.entity_id in [21,24,25]:
			if pos.distance_to(e.global_position) < range: return true
	return false

# ═══ Defense ═══
func _is_defending() -> bool:
	if current_tactic == LateTactic.DEFEND:
		return true
	return _defense != null and int(_defense.threat_level) >= 2

func start_defense():
	current_tactic = LateTactic.DEFEND
	# 防御建筑、威胁方向、守军数量统一交给 AIDefense 处理。
	if _defense != null:
		_defense.start_defense()

func build_defense_line():
	var castle = get_peer_castle(my_peer_id)
	if not castle: return
	var enemy_dir = _get_enemy_army_direction(castle.global_position)
	var front_center = castle.global_position + enemy_dir.normalized() * DEFENSE_FRONT_DIST
	wall_positions.clear(); tower_positions.clear()
	var right_dir = enemy_dir.cross(Vector3.UP).normalized()
	defense_wall_axis = right_dir
	var tower_front = front_center - enemy_dir * 1.8
	for i in range(4):
		var offset = (i - 1.5) * TOWER_SPACING
		if _is_valid_build_ground(tower_front + right_dir * offset):
			build_building(26, tower_front + right_dir * offset)
			tower_positions.append({"pos": tower_front + right_dir * offset, "id": 26})
		var apos = tower_front + right_dir * (offset + 0.3)
		if _is_valid_build_ground(apos):
			build_building(25, apos)
			tower_positions.append({"pos": apos, "id": 25})
	for i in range(WALL_COUNT):
		var bp = front_center + right_dir * ((i - WALL_COUNT/2) * WALL_SPACING)
		if _is_valid_build_ground(bp): build_building(27, bp); wall_positions.append(bp)
	await get_tree().create_timer(0.3, false).timeout

func check_defense_line():
	var walls = 0; var cannons = 0; var arrows = 0
	for entity in battle.entities.get_children():
		if entity is Building and entity.health > 0 and entity_belongs_to_me(entity):
			if entity.entity_id == 27: walls += 1
			elif entity.entity_id == 26: cannons += 1
			elif entity.entity_id == 25: arrows += 1
	if walls < 5 or cannons < 3 or arrows < 3: rebuild_defense_line()

func rebuild_defense_line():
	for pos in wall_positions:
		var exists = false
		for e in battle.entities.get_children():
			if e is Building and e.health > 0 and e.entity_id == 27 and entity_belongs_to_me(e) and e.global_position.distance_to(pos) < 1.0: exists = true; break
		if not exists and can_afford_building(27): build_building(27, pos)
	for td in tower_positions:
		var exists = false
		for e in battle.entities.get_children():
			if e is Building and e.health > 0 and e.entity_id == td["id"] and entity_belongs_to_me(e) and e.global_position.distance_to(td["pos"]) < 1.0: exists = true; break
		if not exists and can_afford_building(td["id"]): build_building(td["id"], td["pos"])

func upgrade_defense_to_max():
	for entity in battle.entities.get_children():
		if entity is Building and entity.health > 0 and entity.entity_id in [20,25,26,27,23,21,24] and entity_belongs_to_me(entity):
			var _upg_attempts = 0
			while entity.can_upgrade() and can_afford_upgrade(entity.entity_id) and _upg_attempts < 10:
				upgrade_building(entity.entity_id)
				_upg_attempts += 1

# ── 渐进式防线建造（每个 think 调用）──
# 城堡升至2级后：先规划防线（记录位置），再每 tick 分批建造数座，
# 资源不足时留待后续 tick；周期检查被打掉的墙/塔并自动补建。
func _manage_defense(_delta):
	if phase == Phase.PRODUCTION:
		return
	var castle = get_peer_castle(my_peer_id)
	if not castle:
		return
	# 箭塔/炮塔需城堡2级解锁，城墙与其配合才能成防线
	if castle.upgrade_level < 2:
		return
	# 周期补建：防线建筑被摧毁/拆除后重新加入待建队列
	defense_check_timer -= _delta
	if defense_check_timer <= 0.0:
		defense_check_timer = DEFENSE_CHECK_INTERVAL
		_queue_defense_gaps()
	# 首次规划防线位置（不做一次性批量建造）
	if not defense_initialized:
		if _plan_defense_line():
			defense_initialized = true
	# 每 tick 分批建造待建队列
	if not _defense_queue.is_empty():
		_build_defense_step()

# 计算并缓存防线各建筑位置；至少有一个可行位置才视为规划成功
func _plan_defense_line() -> bool:
	var castle = get_peer_castle(my_peer_id)
	if not castle:
		return false
	var enemy_dir = _get_enemy_army_direction(castle.global_position).normalized()
	var front_center = castle.global_position + enemy_dir * DEFENSE_FRONT_DIST
	var right_dir = enemy_dir.cross(Vector3.UP).normalized()
	wall_positions.clear(); tower_positions.clear(); _defense_queue.clear()
	defense_wall_axis = right_dir
	var tower_front = front_center - enemy_dir * 1.8
	for i in range(4):
		var offset = (i - 1.5) * TOWER_SPACING
		var tp = tower_front + right_dir * offset
		if _is_valid_build_ground(tp):
			tower_positions.append({"id": 26, "pos": tp}); _defense_queue.append({"id": 26, "pos": tp})
		var apos = tower_front + right_dir * (offset + 0.3)
		if _is_valid_build_ground(apos):
			tower_positions.append({"id": 25, "pos": apos}); _defense_queue.append({"id": 25, "pos": apos})
	_plan_wall_chain(front_center, right_dir, enemy_dir)
	return not _defense_queue.is_empty()

# 连续墙线：从防线正中向两侧逐段铺墙，中心距固定 WALL_STEP（< 墙直径 2.0），
# 保证段与段首尾重叠、敌人钻不过去；遇到水面/峭壁就停，让地形当天然封口。
# 旧逻辑用 _is_valid_build_ground 校验（要求离自家建筑 radius+3 米），墙与墙
# 之间会被互相判成非法，最后只零星立起几段，中间全是大缝。
func _plan_wall_chain(front_center: Vector3, axis: Vector3, forward: Vector3) -> void:
	# 8 米线正好压在山上/水里是常事，先在前后几米里挑一条能连续铺墙的线，
	# 否则整排墙位全非法，AI 一段墙都建不出来（敌人从主城正面长驱直入）。
	front_center = _pick_wall_line_center(front_center, axis, forward)
	var center_spot: Vector3 = _add_wall_slot(front_center, axis, forward, Vector3.ZERO)
	if center_spot == Vector3.ZERO:
		return
	for side in [1.0, -1.0]:
		var cursor: Vector3 = center_spot
		var off: float = WALL_STEP
		while off <= WALL_MAX_HALF_SPAN and wall_positions.size() < WALL_COUNT:
			var nominal: Vector3 = front_center + axis * (float(side) * off)
			var spot: Vector3 = _add_wall_slot(nominal, axis, forward, cursor)
			if spot == Vector3.ZERO:
				# 山/水/资源点把这一侧挡住：收边，绝不跳过留洞
				break
			cursor = spot
			off += WALL_STEP

# 与已规划的塔位保持 1.7 米以上：塔先落地，墙贴太近会被建造校验拒掉，
# 正好在塔位裂开一个洞。
func _near_planned_tower(pos: Vector3) -> bool:
	for td in tower_positions:
		var tp: Vector3 = td["pos"] if td is Dictionary else td
		if pos.distance_to(tp) < 1.7:
			return true
	return false

# 在理想墙位附近找一个能落地的点（前后/左右各 1 米内微调），
# 并且必须紧贴上一段墙（中心距 < 墙直径），返回实际落点；找不到返回零向量。
func _add_wall_slot(nominal: Vector3, axis: Vector3, forward: Vector3, prev: Vector3) -> Vector3:
	var max_link: float = WALL_STEP * 1.25   # 1.875 < 2.0，保证与上一段重叠
	for back in [0.0, 0.35, -0.35, 0.7, -0.7, 1.05, -1.05]:
		for side in [0.0, 0.2, -0.2, 0.4, -0.4]:
			var p: Vector3 = nominal - forward * float(back) + axis * float(side)
			if prev != Vector3.ZERO and prev.distance_to(p) > max_link:
				continue
			if not _can_place_ai_building(27, p):
				continue
			if _near_planned_tower(p):
				continue
			wall_positions.append(p)
			_defense_queue.append({"id": 27, "pos": p})
			return p
	return Vector3.ZERO

# 在理想防线前方/后方几米内挑一条能连续铺墙的线：按整条墙线上可建造的点数打分，
# 挑得分最高的一条，避免 8 米线正好落在山壁/水面上导致整排墙位作废。
func _pick_wall_line_center(front_center: Vector3, axis: Vector3, forward: Vector3) -> Vector3:
	var best: Vector3 = front_center
	var best_len: int = -1
	for dd in [0.0, 0.5, -0.5, 1.0, -1.0, 1.5, -1.5, 2.0, -2.0, 3.0, -3.0, 4.0, -4.0]:
		var cand: Vector3 = front_center + forward * float(dd)
		var run_start: int = 0
		var run_len: int = 0
		for k in range(-7, 8):
			var p: Vector3 = cand + axis * (float(k) * WALL_STEP)
			if _can_place_ai_building(27, p):
				if run_len == 0:
					run_start = k
				run_len += 1
				# 只认连续能建的一段：这样墙线不会在资源/山体处中断后留下大洞
				if run_len > best_len:
					best_len = run_len
					var mid_k: float = float(run_start) + float(run_len - 1) * 0.5
					best = cand + axis * (mid_k * WALL_STEP)
			else:
				run_len = 0
	return best

# 每 tick 至多尝试建造 DEFENSE_STEP_MAX 座；已建/在建的跳过，资源不足等待下轮
func _build_defense_step():
	if _defense_queue.is_empty():
		return
	var res = _get_resources()
	var built = 0
	var i = 0
	while i < _defense_queue.size() and built < DEFENSE_STEP_MAX:
		var item = _defense_queue[i]
		var b_id = int(item["id"])
		var b_pos: Vector3 = item["pos"]
		if _pos_has_building(b_id, b_pos):
			_defense_queue.remove_at(i)
			continue
		var cost = EntityDatabase.get_config(b_id).get("cost", {})
		var can_now = true
		for k in cost:
			if res.get(k, 0) < cost[k]:
				can_now = false
				break
		if not can_now:
			if built == 0:
				break  # 当前资源不足以开工任何一座，留待下轮
			i += 1
			continue
		build_building(b_id, b_pos)
		# build_building 无返回值：以建筑是否实际落成判定（未落成则出队，留待周期补建）
		if _pos_has_building(b_id, b_pos):
			built += 1
		_defense_queue.remove_at(i)

# 防线中缺失的建筑（被打掉/拆除）重新入队待建
func _queue_defense_gaps():
	var need: Array = []
	for pos in wall_positions:
		if not _pos_has_building(27, pos):
			need.append({"id": 27, "pos": pos})
	for td in tower_positions:
		if not _pos_has_building(int(td["id"]), td["pos"]):
			need.append({"id": int(td["id"]), "pos": td["pos"]})
	# 补缝：把实际建成的墙沿墙线排序，相邻两段中心距超过墙直径就是漏洞
	# （中间被拆/当初没建起来），直接在缺口正中补一段，敌人挤不进来。
	var built_walls: Array = []
	for e in battle.entities.get_children():
		if e is Building and e.health > 0 and e.entity_id == 27 and entity_belongs_to_me(e):
			built_walls.append(e.global_position)
	if built_walls.size() >= 2:
		built_walls.sort_custom(func(a, b): return a.dot(defense_wall_axis) < b.dot(defense_wall_axis))
		for i in range(built_walls.size() - 1):
			var wa: Vector3 = built_walls[i]
			var wb: Vector3 = built_walls[i + 1]
			if wa.distance_to(wb) <= WALL_STEP * 1.6:
				continue
			var mid: Vector3 = (wa + wb) * 0.5
			if _can_place_ai_building(27, mid) and not _pos_has_building(27, mid):
				need.append({"id": 27, "pos": mid})
	for item in need:
		if not _queue_has_item(item):
			_defense_queue.append(item)

func _queue_has_item(item: Dictionary) -> bool:
	for q in _defense_queue:
		if int(q["id"]) == int(item["id"]) and (q["pos"] - item["pos"]).length() < 0.5:
			return true
	return false

# 指定位置是否已有同类型建筑（含建造中）
func _pos_has_building(b_id: int, pos: Vector3) -> bool:
	for e in battle.entities.get_children():
		if e is Building and e.health > 0 and e.entity_id == b_id and entity_belongs_to_me(e):
			if e.global_position.distance_to(pos) < 1.0:
				return true
	return false

# ═══ Shipyard ═══
func _cache_shipyard_location():
	cached_shipyard_pos = _find_best_water_adjacent_plain()

func _find_best_water_adjacent_plain() -> Vector3:
	var castle = get_peer_castle(my_peer_id)
	if not castle: return Vector3.ZERO
	var best_pos = Vector3.ZERO; var best_score = -1.0
	var oil_pos_list: Array[Vector3] = []
	for ent in battle.entities.get_children():
		if ent is GameEntity and ent.entity_id == 4 and ent.health > 0: oil_pos_list.append(ent.global_position)
	for gx in range(RTSConfig.MAP_SIZE):
		for gz in range(RTSConfig.MAP_SIZE):
			if battle.get_terrain_at_grid(gx, gz) != 0 or not _check_near_water(gx, gz): continue
			var wp = battle.grid_to_world(gx, gz)
			var too_close = false
			for ep in built_shipyard_pos:
				if wp.distance_to(ep) < SHIPYARD_SPACING: too_close = true; break
			if too_close: continue
			var reach_oil = false
			for op in oil_pos_list:
				if wp.distance_to(op) < SHIPYARD_OIL_REACH: reach_oil = true; break
			if not reach_oil: continue
			# 船坞要下水和跑采集船，周围水域越开阔越好：
			# 按半径 6 格内的水面数量打分，距离只作次要参考，
			# 避免选址落到窄小的死水塘导致船出不来。
			var water_area: int = _count_water_in_radius(gx, gz, 6)
			if water_area < 8: continue
			var dis = wp.distance_to(castle.global_position)
			var score: float = float(water_area) * 10.0 - dis * 0.5
			if score > best_score: best_score = score; best_pos = wp
	return best_pos

# 统计以 (gx,gz) 为中心、半径 r 格范围内的水面格数，用于评估水域开阔程度
func _count_water_in_radius(gx: int, gz: int, r: int) -> int:
	var n := 0
	for dx in range(-r, r + 1):
		for dz in range(-r, r + 1):
			var nx: int = gx + dx
			var nz: int = gz + dz
			if nx < 0 or nx >= RTSConfig.MAP_SIZE or nz < 0 or nz >= RTSConfig.MAP_SIZE: continue
			if battle.get_terrain_at_grid(nx, nz) == 2: n += 1
	return n

func _check_near_water(gx: int, gz: int) -> bool:
	for dx in [-1,0,1]:
		for dz in [-1,0,1]:
			if dx == 0 and dz == 0: continue
			var nx = gx + dx; var nz = gz + dz
			if nx >= 0 and nx < RTSConfig.MAP_SIZE and nz >= 0 and nz < RTSConfig.MAP_SIZE:
				if battle.get_terrain_at_grid(nx, nz) == 2: return true
	return false

# 船坞所在连通水域是否有军事价值：
#   · 水域能开到敌方沿岸建筑/主城附近，战船才有炮击目标；
#   · 或敌方战船已经进入这片水域，需要己方战船对抗。
# 纯油田小水塘通常两者都不满足，只保留采集船，不浪费资源造战船。
func _shipyard_has_military_water(sy: Building) -> bool:
	var key: int = sy.get_instance_id()
	var now: float = battle.game_time
	var cached = _naval_value_cache.get(key)
	if cached is Dictionary and now - float(cached.get("time", -999.0)) < NAVAL_VALUE_RECHECK:
		return bool(cached.get("value", false))
	var value: bool = _water_body_has_military_target(sy.global_position)
	_naval_value_cache[key] = {"time": now, "value": value}
	return value

func _water_body_has_military_target(pos: Vector3) -> bool:
	var start: Vector2i = _find_adjacent_water_cell(pos)
	if start.x < 0:
		return false
	var enemy_castle = _get_attack_target_castle()
	var castle_pos: Vector3 = Vector3.ZERO
	if enemy_castle and is_instance_valid(enemy_castle):
		castle_pos = enemy_castle.global_position
	var enemy_buildings: Array[Vector3] = []
	var enemy_ship_cells: Dictionary = {}
	for e in battle.entities.get_children():
		if not (e is GameEntity) or e.health <= 0 or not _entity_is_enemy(e):
			continue
		if e is Building:
			enemy_buildings.append(e.global_position)
		elif e is Army and e.water_capable:
			enemy_ship_cells[battle.world_to_grid(e.global_position)] = true
	var visited: Dictionary = {start: true}
	var queue: Array[Vector2i] = [start]
	var head: int = 0
	while head < queue.size() and head < NAVAL_VALUE_BFS_LIMIT:
		var cell: Vector2i = queue[head]
		head += 1
		if enemy_ship_cells.has(cell):
			return true
		var wp: Vector3 = battle.grid_to_world(cell.x, cell.y)
		if castle_pos != Vector3.ZERO and wp.distance_to(castle_pos) <= NAVAL_VALUE_CASTLE_RANGE:
			return true
		for ep in enemy_buildings:
			if wp.distance_to(ep) <= NAVAL_VALUE_BUILDING_RANGE:
				return true
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = cell + d
			if n.x < 0 or n.x >= RTSConfig.MAP_SIZE or n.y < 0 or n.y >= RTSConfig.MAP_SIZE:
				continue
			if visited.has(n) or battle.get_terrain_at_grid(n.x, n.y) != 2:
				continue
			visited[n] = true
			queue.append(n)
	return false

func _find_adjacent_water_cell(pos: Vector3) -> Vector2i:
	var center: Vector2i = battle.world_to_grid(pos)
	for r in range(1, 4):
		for dx in range(-r, r + 1):
			for dz in range(-r, r + 1):
				if absi(dx) != r and absi(dz) != r:
					continue
				var nx: int = center.x + dx
				var nz: int = center.y + dz
				if nx < 0 or nx >= RTSConfig.MAP_SIZE or nz < 0 or nz >= RTSConfig.MAP_SIZE:
					continue
				if battle.get_terrain_at_grid(nx, nz) == 2:
					return Vector2i(nx, nz)
	return Vector2i(-1, -1)

func _manage_shipyards():
	var shipyards = []
	for e in battle.entities.get_children():
		if e is Building and e.entity_id == 23 and e.health > 0 and e.build_timer <= 0 and entity_belongs_to_me(e):
			shipyards.append(e)
	if shipyards.size() < 2:
		if can_afford_building(23):
			var pos = _find_shipyard_pos_near_oil()
			if pos != Vector3.ZERO: build_building(23, pos)
		return
	for sy in shipyards:
		# 渡水模块专门建在登陆岸边的船坞不能因为附近没油田被拆掉
		if sy.has_meta("ai_transport_shipyard"):
			continue
		var has_oil = false
		for res in battle.entities.get_children():
			if res is WorldResource and res.resource_type == "oil" and res.health > 0 and sy.global_position.distance_to(res.global_position) < SHIPYARD_OIL_REACH: has_oil = true; break
		if not has_oil and shipyards.size() > 1:
			sy.queue_free()
			if can_afford_building(23):
				var pos = _find_shipyard_pos_near_oil()
				if pos != Vector3.ZERO: build_building(23, pos)

# ── 为商人搭桥 ──
# 商人往返城堡与集市，如果集市场或商人被河隔开就会一直绕路甚至卡住。
# 这里检测"商人 → 己方城堡"连线是否跨水，跨水就在商人这一侧的岸边尝试修桥。
func _manage_merchant_bridges() -> void:
	# 桥数上限和普通建筑一致，到顶就不再折腾
	if count_building(7) >= 10:
		return
	# 没有商人就没有需求，避免每帧全量遍历实体
	if _count_merchants() <= 0:
		return
	var castle = get_peer_castle(my_peer_id)
	if not castle or not is_instance_valid(castle):
		return
	for e in battle.entities.get_children():
		if not (e is Army) or e.health <= 0 or not entity_belongs_to_me(e):
			continue
		if not (e.entity_id in MERCHANT_UNIT_IDS):
			continue
		var from: Vector3 = e.global_position
		var to: Vector3 = castle.global_position
		if not _line_crosses_water(from, to):
			continue
		# 交给渡水模块生成完整桥段计划，而不是只拍一段桥。
		# 单段桥在河宽超过一格时仍无法让商人通过，旧逻辑会反复尝试同一水面。
		if _water_crossing != null and _water_crossing.plan_bridge_to(to, from):
			return

# 两点连线上的采样是否出现过水面
func _line_crosses_water(from: Vector3, to: Vector3) -> bool:
	const STEPS: int = 40
	for i in range(1, STEPS):
		var t: float = float(i) / float(STEPS)
		if battle.get_terrain_at(from.lerp(to, t)) == 2:
			return true
	return false

func _find_shipyard_pos_near_oil() -> Vector3:
	var castle = get_peer_castle(my_peer_id)
	if not castle: return Vector3.ZERO
	for radius in [8, 15, 25]:
		for _try in range(40):
			var tp = castle.global_position + Vector3(cos(randf_range(0,TAU))*randf_range(3,radius), 0, sin(randf_range(0,TAU))*randf_range(3,radius))
			if battle.get_terrain_at(tp) != 0: continue
			var gx = int(tp.x + RTSConfig.MAP_SIZE/2); var gz = int(tp.z + RTSConfig.MAP_SIZE/2)
			var adj = false
			for dx in [-1,0,1]:
				for dy in [-1,0,1]:
					if dx == 0 and dy == 0: continue
					if battle.get_terrain_at_grid(gx+dx, gz+dy) == 2: adj = true; break
				if adj: break
			if not adj: continue
			for res in battle.entities.get_children():
				if res is WorldResource and res.resource_type == "oil" and res.health > 0 and tp.distance_to(res.global_position) < SHIPYARD_OIL_REACH: return tp
	return Vector3.ZERO

# ═══ Official helpers ═══
# 某栋建筑是否已被同类型官员占用，或已有同类型官员在赶往那里。
# AI 可能训练出多个同类型官员，选目标时必须把“在路上”的预约也算进去，
# 否则他们会一起冲向同一栋建筑，最后只有一个能进驻。
func _official_slot_claimed(building: Building, official_id: int) -> bool:
	for oe in battle.entities.get_children():
		if oe is Army and oe.entity_id == official_id and oe.health > 0:
			var ogb = oe.get("_garrison_building")
			if ogb and ogb.get_ref() == building:
				return true
			if int(oe.get("_garrison_target_id")) == building.get_instance_id():
				return true
	return false

func _find_vacant_warehouse_s() -> Building:
	for e in battle.entities.get_children():
		if e is Building and e.entity_id == 22 and e.team == my_team and e.health > 0 and e.build_timer <= 0:
			if not _official_slot_claimed(e, 46):
				return e
	return null

func _find_vacant_tower_s() -> Building:
	for e in battle.entities.get_children():
		if e is Building and e.entity_id in [25,26] and e.team == my_team and e.health > 0 and e.build_timer <= 0:
			if not _official_slot_claimed(e, 47):
				return e
	return null

# 统帅不占建筑，优先去自己的主城；没有主城时退而找任意已建成建筑。
func _find_commander_station_s() -> Building:
	var fallback: Building = null
	for e in battle.entities.get_children():
		if not (e is Building and e.team == my_team and e.health > 0 and e.build_timer <= 0):
			continue
		if e.entity_id == 20:
			return e
		if fallback == null:
			fallback = e
	return fallback

func _find_preferred_official_building_s(official_id: int) -> Building:
	match official_id:
		46: return _find_vacant_warehouse_s()
		47: return _find_vacant_tower_s()
		48: return _find_random_prod_or_def_s()
	return null

func _official_building_is_preferred(official_id: int, building: Building) -> bool:
	if building == null or not is_instance_valid(building):
		return false
	match official_id:
		46: return building.entity_id == 22
		47: return building.entity_id in [25, 26]
		48: return building.entity_id in [21, 23, 24, 29, 25, 26]
	return true

# 训练官员前先确认有可进驻的空位，避免书院升级后一次性造出
# 一批“没有对应建筑可去”的官员，只能站在基地里发呆。
func _official_has_slot(official_id: int) -> bool:
	match official_id:
		46: return _find_vacant_warehouse_s() != null
		47: return _find_vacant_tower_s() != null
		48: return _find_random_prod_or_def_s() != null
		49: return true  # 统帅不占建筑，只要还有己方建筑就能提供光环
		50: return _find_most_officiated_s() != null
	return false

func _find_random_prod_or_def_s() -> Building:
	var cand = []
	for e in battle.entities.get_children():
		if e is Building and e.entity_id in [21,23,24,29,25,26] and e.team == my_team and e.health > 0 and e.build_timer <= 0:
			if not _official_slot_claimed(e, 48):
				cand.append(e)
	return cand[randi() % cand.size()] if cand.size() > 0 else null

func _find_most_officiated_s() -> Building:
	var best: Building = null; var best_cnt = -1
	for e in battle.entities.get_children():
		if e is Building and e.team == my_team and e.health > 0 and e.build_timer <= 0:
			var cnt = 0
			for oe in battle.entities.get_children():
				if oe is Army and oe.entity_id >= 46 and oe.entity_id <= 49 and oe.get("_garrison_building") and oe.get("_garrison_building").get_ref() == e: cnt += 1
			if cnt > best_cnt: best_cnt = cnt; best = e
	return best

# ═══ Production lines ═══
# 升级周期：development阶段每20秒切换一次
func _should_skip_for_upgrade_cycle(delta) -> bool:
	if phase != Phase.DEVELOPMENT: return false
	_upgrade_cycle_timer -= delta
	if _upgrade_cycle_timer <= 0:
		_upgrade_cycle_timer = 20.0
		_in_upgrade_cycle = not _in_upgrade_cycle
	return _in_upgrade_cycle and _any_building_can_upgrade()

func _any_building_can_upgrade() -> bool:
	for b_id in wanted_buildings:
		if _should_build_or_upgrade(b_id) :
			return true
	return false
func _process_line_1():
	# 石头快满时先升城墙/补墙，再考虑普通建筑和重装科技。
	# 放在重装/投石机储备的提前 return 之前，否则科技读条期间石头会一直满仓。
	_spend_surplus_stone_on_walls()
	# 花墙之后仍然顶在 95% 以上时，把富余石头转给同队缺石头的 AI，
	# 而不是让 3v3 里一个 AI 石头 1800/1800、另一个 AI 25/1300 造不出墙。
	_share_surplus_stone_with_ally()
	# 重装武器厂/城堡4级是59的前置科技，优先于普通建筑升级
	if _ensure_heavy_siege_tech():
		return
	if _trebuchet_reserve_active():
		return
	for b_id in wanted_buildings:
		if _should_build_or_upgrade(b_id) and can_afford_upgrade(b_id):
			upgrade_building(b_id)
			
	for b_id in wanted_buildings:
		var target = _effective_producer_target(b_id)
		if count_building(b_id) < target and can_afford_building(b_id):
			var bpos = _get_build_position(b_id)
			if bpos != Vector3.ZERO:
				build_building(b_id, bpos)
			
	_ai_expand_territory()


# 优先升级：兵营(21)升到4级，受城堡等级限制则先升城堡
func _priority_upgrade():
	if _ensure_heavy_siege_tech():
		return true
	if _trebuchet_reserve_active():
		return false
	var castle = get_peer_castle(my_peer_id)
	if not castle: return false
	for i in [21,23,24,29,54]:
	# 城堡等级不够兵营4级（兵营>=4需要城堡>=4）
		for entity in battle.entities.get_children():
			if entity is Building and entity.entity_id == i and entity_belongs_to_me(entity):
				if entity.upgrade_level < 4:
					if castle.upgrade_level < entity.upgrade_level + 1:
						if can_afford_upgrade(20):
							upgrade_building(20); return true
					if can_afford_upgrade(i):
						upgrade_building(i); return true
	return false

func _process_line_upgrade():
	if _ensure_heavy_siege_tech():
		return
	if _trebuchet_reserve_active():
		return
	for b_id in wanted_buildings:
		if _should_build_or_upgrade(b_id) and can_afford_upgrade(b_id):
			upgrade_building(b_id)

# 3v3/2v2 同队 AI 各自独立资源：石头富余且自己的墙已经花不出去时，
# 转一部分给同队石头最缺的 AI。没有这一步，3v3 快速模式会长期出现
# “一个 AI 石头满仓、另一个 AI 连第一段墙都造不起”的两极分化。
func _share_surplus_stone_with_ally() -> bool:
	if battle == null or GameSettings.ai_mode < 2:
		return false
	if _resource_ratio("stone") < 0.95:
		return false
	if int(battle.ai_players.size()) <= 1:
		return false
	var my_res: Dictionary = _get_resources()
	var my_lim: Dictionary = _get_limits()
	var my_stone: int = int(my_res.get("stone", 0))
	var my_cap: int = int(my_lim.get("stone", 0))
	if my_cap <= 0 or my_stone < int(float(my_cap) * 0.95):
		return false
	var best_pid: int = -1
	# 只要队友石头没到 80% 就可以接，不要求“极度缺石头”。
	# 否则全队都中等充裕时，满仓 AI 找不到接收方，石头仍然顶格。
	var best_ratio: float = 0.80
	for pid in battle.ai_players.keys():
		if int(pid) == my_peer_id:
			continue
		if int(pid) == int(battle.player_owner_id):
			continue
		var info: Dictionary = battle.ai_players.get(pid, {})
		if int(info.get("team", -1)) != my_team:
			continue
		var ally_res: Dictionary = battle.get_resources_for(int(pid))
		var ally_lim: Dictionary = battle.get_limits_for(int(pid))
		var ally_cap: int = int(ally_lim.get("stone", 0))
		if ally_cap <= 0:
			continue
		var ally_ratio: float = float(ally_res.get("stone", 0)) / float(ally_cap)
		if ally_ratio < best_ratio:
			best_ratio = ally_ratio
			best_pid = int(pid)
	if best_pid < 0:
		return false
	var ally_res2: Dictionary = battle.get_resources_for(best_pid)
	var ally_lim2: Dictionary = battle.get_limits_for(best_pid)
	var ally_cap2: int = int(ally_lim2.get("stone", 0))
	var space: int = int(float(ally_cap2) * 0.85) - int(ally_res2.get("stone", 0))
	var amount: int = mini(int(float(my_cap) * 0.25), 300)
	amount = mini(amount, space)
	amount = mini(amount, my_stone - int(float(my_cap) * 0.65))
	if amount < 100:
		return false
	my_res["stone"] = my_stone - amount
	ally_res2["stone"] = int(ally_res2.get("stone", 0)) + amount
	_last_spend_block = "stone_share_%d" % best_pid
	_last_spend_block_time = battle.game_time
	return true

# AI 队友向同队真人玩家进贡：玩家资源比例低、AI 自己有富余时送一笔，
# 统一走 battle.tribute_resources（扣 20% 税），和玩家主动进贡同一套规则。
func _tribute_to_human_teammate() -> bool:
	if battle == null or not battle.has_method("get_human_owners") \
			or not battle.has_method("tribute_resources"):
		return false
	# FFA 每国一队，不存在“队友”，避免把外交进贡规则混进来。
	if battle.diplomacy != null and battle.diplomacy.active:
		return false
	var humans: Array = battle.get_human_owners()
	if humans.is_empty():
		return false
	var target: int = -1
	var target_worst: float = TRIBUTE_ALLY_TARGET_RATIO
	for h in humans:
		var hid: int = int(h)
		if hid == my_peer_id:
			continue
		if int(battle.get_team_of_owner(hid)) != my_team:
			continue
		var pressure: float = 0.0
		for rk2 in ["gold", "wood", "stone", "food"]:
			pressure = maxf(pressure, _owner_resource_ratio(hid, rk2))
		if pressure < target_worst:
			target_worst = pressure
			target = hid
	if target < 0:
		return false
	var my_res: Dictionary = _get_resources()
	var my_lim: Dictionary = _get_limits()
	var best_rk: String = ""
	var best_amount: int = 0
	for rk in ["gold", "wood", "stone", "food"]:
		var my_cap: int = int(my_lim.get(rk, 0))
		if my_cap <= 0:
			continue
		var my_ratio: float = float(my_res.get(rk, 0)) / float(my_cap)
		if my_ratio < TRIBUTE_ALLY_SOURCE_RATIO:
			continue
		var t_res: Dictionary = battle.get_resources_for(target)
		var t_lim: Dictionary = battle.get_limits_for(target)
		var t_cap: int = int(t_lim.get(rk, 0))
		if t_cap <= 0:
			continue
		var t_ratio: float = float(t_res.get(rk, 0)) / float(t_cap)
		if t_ratio >= TRIBUTE_ALLY_TARGET_RATIO:
			continue
		var space: int = int(float(t_cap) * 0.80) - int(t_res.get(rk, 0))
		var amount: int = mini(TRIBUTE_ALLY_MAX_AMOUNT, int(my_res.get(rk, 0)) - int(float(my_cap) * 0.50))
		amount = mini(amount, int(float(space) / 0.80))
		if amount > best_amount:
			best_amount = amount
			best_rk = rk
	if best_rk == "" or best_amount < TRIBUTE_ALLY_MIN_AMOUNT:
		return false
	var result: Dictionary = battle.tribute_resources(my_peer_id, target, best_rk, best_amount)
	if not bool(result.get("ok", false)):
		return false
	_last_spend_block = "tribute_player_%d" % target
	_last_spend_block_time = battle.game_time
	# 成功播报统一由 battle.tribute_resources 写入战况/警报栏，这里不再重复提示。
	return true

func _owner_resource_ratio(owner: int, rk: String) -> float:
	if battle == null:
		return 0.0
	var lim: float = float(battle.get_limits_for(owner).get(rk, 0))
	if lim <= 0.0:
		return 0.0
	return float(battle.get_resources_for(owner).get(rk, 0)) / lim

# 石头高水位时优先把石头变成防线：先升级城墙，墙满级后再补一圈墙。
# 3v3 快速模式里 5 个 AI 抢资源，会出现“石头 1800/1800、城墙等级仍 1”的
# 情况；以前泄压先造仓库，只是把上限从 1800 抬到 2300，石头依然不花。
func _spend_surplus_stone_on_walls() -> bool:
	if battle == null or _resource_ratio("stone") < 0.80:
		return false
	var castle = get_peer_castle(my_peer_id)
	for e in _cached_buildings():
		if not (e is Building) or not is_instance_valid(e) or e.health <= 0:
			continue
		if not entity_belongs_to_me(e) or int(e.entity_id) != 27:
			continue
		if not e.can_upgrade():
			continue
		var cost: Dictionary = e.get_upgrade_cost()
		if cost.is_empty() or not _can_pay_with_reserves(cost, 27):
			continue
		if e.perform_upgrade(battle):
			_last_spend_block = "wall_upgrade"
			_last_spend_block_time = battle.game_time
			return true
	if not is_instance_valid(castle):
		return false
	if battle.game_time - _last_wall_sink_time < 0.5:
		return false
	# 城墙都升到当前上限后，沿已有城墙向外再贴一层墙。
	# 这比无限抬高仓库上限更符合“石头多就修墙”，也能直接消耗 30 石头/段。
	var walls: Array = []
	for e in _cached_buildings():
		if e is Building and is_instance_valid(e) and e.health > 0 \
				and entity_belongs_to_me(e) and int(e.entity_id) == 27:
			walls.append(e)
	# 快速模式采集是 3 倍、建造只有 2 倍，一次只补一段墙追不上石头收入；
	# 这里一轮最多补 8 段，石头降到 65% 以下就停手。
	var built: int = 0
	for wall in walls:
		if _resource_ratio("stone") < 0.65 or built >= 8:
			break
		var dir: Vector3 = wall.global_position - castle.global_position
		dir.y = 0.0
		if dir.length() < 0.5:
			continue
		var candidate: Vector3 = wall.global_position + dir.normalized() * 2.6
		if build_building(27, candidate):
			built += 1
	if built == 0:
		# 贴墙位置被地形/建筑占满时，退回通用合法落点，至少保证石头有地方花。
		var first_pos: Vector3 = find_valid_build_position(castle.global_position, 27)
		if first_pos != Vector3.ZERO and build_building(27, first_pos):
			built += 1
	if built == 0 and walls.is_empty():
		for i in range(12):
			if _resource_ratio("stone") < 0.65 or built >= 8:
				break
			var ang: float = TAU * float(i) / 12.0
			var candidate2: Vector3 = castle.global_position \
					+ Vector3(cos(ang), 0.0, sin(ang)) * 9.0
			if build_building(27, candidate2):
				built += 1
	# 补墙之外再把石头变成墙上的炮台（炮台只能贴墙建）。
	# 这仍然是防线支出，不把石头留给仓库上限。
	var cannon_built: int = 0
	for wall in walls:
		if _resource_ratio("stone") < 0.65 or cannon_built >= 4:
			break
		if build_building(64, wall.global_position):
			cannon_built += 1
	built += cannon_built
	if built > 0:
		_last_wall_sink_time = battle.game_time
		_last_spend_block = "wall_sink"
		_last_spend_block_time = battle.game_time
		return true
	return false

# 资源接近上限时的泄压流程：
#   1) 人口快满 → 补民居；
#   2) 任何可升级建筑（包括不在 wanted_buildings 里的民居/塔）→ 升级；
#   3) 多排战斗兵；
#   4) 兵营/马厩/重工不够就补生产建筑。
# 所有支出仍然走 can_afford 系列，会保留投石机/重装科技预算；
# 不同的是不再受“每兵种 7 个、民居 8 座”这类固定上限束缚。
func _relieve_resource_pressure() -> void:
	if not _resource_overflow():
		return
	# 第一圈城墙触发后，先保证墙圈建造资金，别把溢出的石头/木材转成升级和兵。
	if _defense != null and _defense.has_method("first_ring_needs_priority") \
			and _defense.first_ring_needs_priority():
		return
	# 石头高水位时优先升级城墙或补墙圈，而不是先造仓库把上限抬高。
	# 仓库只是把“满仓”变成“还能装”，玩家看到的就是石头长期不花。
	var wall_spent: bool = _spend_surplus_stone_on_walls()
	if not wall_spent:
		# 先补仓库：溢出时仓库直接抬高存储上限，比把资源排成兵更能解决“满仓后白采”。
		# 必须放在泄压支出之前，否则几轮兵/升级花完后资源已低于阈值，又不会造仓库。
		consider_warehouse_near_farmer()
	_process_line_3()
	_upgrade_any_affordable_building()
	if _resource_critical():
		_train_overflow_units()
	_process_line_1()

# 买不起时返回具体缺哪种资源，用于诊断“资源很多但军队不涨”。
func _afford_block_reason(unit_id: int) -> String:
	var cfg = EntityDatabase.get_config(unit_id)
	if not cfg:
		return "no_config"
	var res: Dictionary = _get_resources()
	var cost: Dictionary = cfg.get("cost", {})
	for k in cost:
		if int(res.get(k, 0)) < int(cost[k]):
			return "missing_" + String(k)
	if _research_age_reserve_active():
		return "reserve_age"
	if unit_id != TREBUCHET_ID and _trebuchet_reserve_active():
		return "reserve_trebuchet"
	return ""

func _train_overflow_units() -> void:
	if not _resource_overflow() or not _can_train_unit_with_queue():
		return
	var budget: int = RESOURCE_PRESSURE_TRAIN_BURST
	if GameSettings.fast_mode:
		budget += 1
	for u_id in get_counter_priority():
		if budget <= 0:
			return
		if u_id in SUPPORT_UNIT_IDS:
			continue
		if u_id == TRADE_CART_ID and count_unit(TRADE_CART_ID) >= _count_merchants():
			continue
		var cap: int = _effective_army_target()
		if count_unit(u_id) < cap and not can_afford(u_id):
			_last_spend_block = _afford_block_reason(u_id)
			_last_spend_block_time = battle.game_time
		while budget > 0 and count_unit(u_id) < cap and _can_train_unit_with_queue() and can_afford(u_id):
			if not produce_unit(u_id):
				break
			budget -= 1

func _can_pay_with_reserves(cost: Dictionary, building_id: int = -1) -> bool:
	var res: Dictionary = _get_resources()
	for k in cost:
		if int(res.get(k, 0)) < int(cost[k]):
			return false
	if _research_age_reserve_active() and not _can_pay_with_reserve(cost, _research_age_reserve_cost()):
		return false
	if _trebuchet_reserve_active() and not _can_pay_with_trebuchet_reserve(cost):
		return false
	# 与 can_afford_upgrade 保持一致：升级主城/重装厂本身就是在推进 59 科技，
	# 不应被“为 29 科技预留”的预算反锁住。
	if _heavy_siege_tech_reserve_active() \
			and building_id != HEAVY_SIEGE_BUILDING_ID and building_id != 20 \
			and not _can_pay_with_reserve(cost, _heavy_siege_tech_reserve_cost()):
		return false
	return true

# 泄压时不要只盯着 wanted_buildings：民居、塔等建筑继续升级
# 也能把石/木/金吃掉，并带来人口/防御收益（仓库只抬上限，跳过）。
func _upgrade_any_affordable_building() -> bool:
	for entity in _cached_buildings():
		if not (entity is Building) or not is_instance_valid(entity) or entity.health <= 0:
			continue
		if not entity_belongs_to_me(entity):
			continue
		# 仓库升级只把上限继续抬高；平时泄压优先军营/民居/塔，但资源已经溢出时
		# 升级仓库正是最直接的“把资源转成上限”手段。
		if entity.entity_id == 22 and not _resource_overflow():
			continue
		if not entity.can_upgrade():
			continue
		var cost: Dictionary = entity.get_upgrade_cost()
		if cost.is_empty() or not _can_pay_with_reserves(cost, int(entity.entity_id)):
			continue
		if entity.perform_upgrade(battle):
			return true
	return false


func _try_produce_merchants_or_officials() -> bool:
	for mid in [51, 44, 45, 43]:
		if count_unit(mid) < 1 and can_afford(mid) and _can_train_unit():
			if produce_unit(mid): return true
	if count_building(42) > 0:
		var alv = _get_academy_lv()
		for i in range(alv):
			var oid = [46, 47, 48, 49, 50][i]
			if count_unit(oid) >= 1:
				continue
			if not _official_has_slot(oid):
				# 没有仓库/塔/生产建筑的对应空位时先不造，等 AI 建出空位再补，
				# 避免官员出生后就长期闲置。
				continue
			if can_afford(oid) and _can_train_unit():
				if produce_unit(oid): return true
	return false

# 修道院生产僧侣/长老/宗师
func _try_produce_monks():
	if count_building(54) == 0: return
	var monk_order = [55, 56, 57]  # 僧侣→长老→宗师
	for mid in monk_order:
		if count_unit(mid) < 2 and can_afford(mid) and _can_train_unit():
			produce_unit(mid); return

func _try_produce_scout() -> bool:
	if battle == null:
		return false
	if battle.game_time < SCOUT_START_DELAY:
		return false
	if battle.game_time < _scout_next_produce_at:
		return false
	if count_unit(SCOUT_ID) >= SCOUT_TARGET_COUNT:
		return false
	if not _can_produce_unit(SCOUT_ID):
		return false
	if not _can_train_unit_with_queue():
		return false
	if not can_afford(SCOUT_ID):
		return false
	if not produce_unit(SCOUT_ID):
		# 生产队列满/建筑暂时不可用时不要每个 think 都重试。
		_scout_next_produce_at = battle.game_time + SCOUT_RETRY_AFTER_DEATH
		return false
	_scout_next_produce_at = battle.game_time + SCOUT_RETRY_AFTER_DEATH
	return true

# AI 非攻城部队在拆建筑时被敌方部队偷袭：把目标从建筑切回攻击者。
# 攻城器械（火炮/投石车/冲车/弩炮/巨投）保持拆建筑，不因为挨打就放弃攻城。
func _retarget_attacked_siege_units() -> void:
	if battle == null:
		return
	var now: float = Time.get_ticks_msec() / 1000.0
	for e in battle.entities.get_children():
		if not (e is Army) or e.health <= 0 or not entity_belongs_to_me(e):
			continue
		if not (e.current_target is Building):
			continue
		if int(e.entity_id) in [16, 17, 18, 58, 59]:
			continue
		var attacker = e._last_unit_attacker
		if attacker == null or not is_instance_valid(attacker) or attacker.health <= 0:
			continue
		if not (attacker is Army) or not _entity_is_enemy(attacker):
			continue
		if now - float(e._last_unit_attack_time) > RETARGET_MEMORY:
			continue
		if e.global_position.distance_to(attacker.global_position) > RETARGET_MAX_DIST:
			continue
		if e.has_method("_is_target_attackable_now") and not e._is_target_attackable_now(attacker):
			continue
		e.attack_target(attacker)

func _emergency_army_stalled() -> bool:
	if battle == null or count_building(21) <= 0:
		return false
	var my_key = my_peer_id if my_peer_id != -1 else my_team
	if count_military(my_key) >= 10:
		return false
	if _resource_pressure_ratio() < 0.75:
		return false
	return _can_train_unit_with_queue()

func _try_produce_emergency_defender() -> bool:
	# 优先最便宜的步兵/弓箭手；骑兵和重装兵只在便宜兵不可训练时兜底。
	for u_id in [11, 12, 35, 15]:
		if _can_produce_unit(u_id) and can_afford(u_id) and produce_unit(u_id):
			return true
	return false

func _process_line_military():
	# 资源已经压满、兵营也有，但军队仍低于 10 时，说明 AI 被别的逻辑
	# （投石机攒钱、错误兵种目标、守军/队列判断）卡住了。先强制补最便宜的
	# 可训练兵种，避免“资源满仓却不出兵”。
	if _emergency_army_stalled() and _try_produce_emergency_defender():
		return
	# 59优先排产；如果已经解锁但资源不够，进入短暂攒钱模式，避免普通兵种把资源吃干
	if _try_produce_trebuchet():
		return
	if _trebuchet_reserve_active():
		return
	# 人口满时先补民居，否则 AI 会一直卡在上限，看起来像“不会造房、也不出兵”
	if not _can_train_unit_with_queue():
		_process_line_3()
		if not _can_train_unit_with_queue():
			return
	# 主城升到 2 级后补 1 个侦察兵探图；死亡后按冷却补回。
	if _try_produce_scout():
		return
	var priority = get_counter_priority()
	var train_budget: int = RESOURCE_PRESSURE_TRAIN_BURST if _resource_critical() else 1
	for u_id in priority:
		if u_id in SUPPORT_UNIT_IDS:
			continue
		# 手推车/贸易车是商人系统的单位，不能算进野战军；旧逻辑会把军费/人口全拿去买车。
		if u_id in [5, TRADE_CART_ID]:
			continue
		var unit_target: int = _field_army_target_for(int(u_id))
		if count_unit(u_id) < unit_target and can_afford(u_id) and _can_train_unit_with_queue():
			# 普通情况每轮补 1 个；资源临界满仓时一次多排几个，尽快把收入转成兵力。
			var trained: int = 0
			while trained < train_budget and count_unit(u_id) < unit_target \
					and _can_train_unit_with_queue() and can_afford(u_id) and produce_unit(u_id):
				trained += 1

# 把"打完仗就站着"的野战兵重新推上去：身边 40 米内有敌就直接锁敌，
# 没有敌人但刚因为走不到目标停下过（ai_stalled_attack）就重新压向敌方主城。
func _retask_idle_front_units() -> void:
	if battle == null:
		return
	if _defense != null and int(_defense.threat_level) >= 3:
		return
	var sent: int = 0
	var now_ms: int = Time.get_ticks_msec()
	var castle_target = null
	for u in _cached_armies():
		if sent >= 10:
			break
		if not is_instance_valid(u) or u.health <= 0 or not entity_belongs_to_me(u):
			continue
		if int(u.entity_id) == 10 or int(u.attack) <= 0 or bool(u.water_capable):
			continue
		if u.has_meta("ai_home_guard") or u.has_meta("ai_resource_guard") or u.has_meta("ai_harass") \
				or u.has_meta("ai_wall_guard") or u.has_meta("ai_transporting") or u.has_meta("ai_escorting"):
			continue
		if String(u.current_order) != "" or u.current_target != null or not u.command_queue.is_empty():
			continue
		if u.garrison_point != Vector3.ZERO:
			continue
		var enemy = u._find_nearest_enemy_near(u.global_position, 40.0)
		if enemy != null and is_instance_valid(enemy):
			# 远处敌人用攻击移动过去（attack_target 对超出射程的目标会被目标校验拒绝），
			# 近距离才直接锁敌。
			var ed: float = u.global_position.distance_to(enemy.global_position)
			if ed <= 25.0:
				u.attack_target(enemy)
			else:
				u.attack_move_to(enemy.global_position)
			sent += 1
			continue
		if u.has_meta("ai_stalled_attack") \
				and now_ms - int(u.get_meta("ai_stalled_attack")) <= 20000:
			u.remove_meta("ai_stalled_attack")
			if castle_target == null:
				castle_target = _get_attack_target_castle()
			if castle_target != null and is_instance_valid(castle_target):
				u.attack_move_to(castle_target.global_position)
				sent += 1

# ═══ ArmyDirector（第 1 步：安全网）═══
# 只做两件事：维护角色账本 _roles（谁因为什么角色被占用、租约何时到期），
# 并把既没有角色、也没有任何命令的陆军战斗单位兜底派出去。
# 旧的各调度器暂时保留，后续步骤会逐个改成向 director 提需求。
enum UnitRole { IDLE, SCOUT, GARRISON, WALL, HOME_GUARD, RESOURCE_GUARD, BUILDING_DEFENSE, HARASS, RAID, FIELD, SIEGE, TRANSPORT, ESCORT, RETREAT, STANDBY }

const DIRECTOR_INTERVAL: float = 0.5
const DIRECTOR_FIELD_LEASE: float = 30.0
const DIRECTOR_STANDBY_LEASE: float = 25.0
const DIRECTOR_STANDBY_MIN_DIST: float = 10.0
const DIRECTOR_LOG_INTERVAL: float = 5.0

var director_debug: bool = false
var _roles: Dictionary = {}
var _director_timer: float = 0.0
var _director_log_timer: float = 0.0

func _tick_director(delta: float) -> void:
	if battle == null or bool(battle.game_over):
		return
	_director_timer -= delta
	if _director_timer > 0.0:
		return
	_director_timer = DIRECTOR_INTERVAL
	var now: float = float(battle.game_time)
	_director_prune(now)
	var idle: Array = []
	for u in _cached_armies():
		if not _director_is_land_combat(u):
			continue
		if _roles.has(u.get_instance_id()):
			continue
		if _director_is_busy(u):
			continue
		idle.append(u)
	if not idle.is_empty():
		_director_dispatch(idle, now)
	if director_debug:
		_director_log_timer -= DIRECTOR_INTERVAL
		if _director_log_timer <= 0.0:
			_director_log_timer = DIRECTOR_LOG_INTERVAL
			_director_log()

func _director_is_land_combat(u) -> bool:
	if not is_instance_valid(u) or u.health <= 0:
		return false
	if not entity_belongs_to_me(u):
		return false
	if int(u.entity_id) == 10 or int(u.attack) <= 0:
		return false
	if _is_scout_unit(u) or bool(u.water_capable) or bool(u.hold_position):
		return false
	if u.has_meta("ai_home_guard") or u.has_meta("ai_resource_guard") or u.has_meta("ai_wall_guard") \
		or u.has_meta("ai_harass") or u.has_meta("ai_transporting") or u.has_meta("ai_escorting"):
		return false
	return true

func _director_is_busy(u) -> bool:
	if String(u.current_order) != "" or u.current_target != null:
		return true
	if not u.command_queue.is_empty():
		return true
	if u.garrison_point != Vector3.ZERO:
		return true
	if _is_held_by_garrison(u) or _is_local_defense_active(u):
		return true
	var boarded = u.get("_boarded_on")
	if boarded != null and int(boarded) != -1:
		return true
	return false

func _director_prune(now: float) -> void:
	if _roles.is_empty():
		return
	var drop: Array = []
	for uid in _roles.keys():
		var ent: Dictionary = _roles[uid]
		var u = instance_from_id(int(uid))
		if u == null or not is_instance_valid(u) or not entity_belongs_to_me(u) or float(ent.get("until", 0.0)) <= now:
			drop.append(uid)
	for uid in drop:
		_director_release_role(int(uid))

func _director_set_role(u, role: int, lease: float, now: float) -> void:
	_roles[u.get_instance_id()] = {"role": role, "since": now, "until": now + lease}
	u.set_meta("ai_role", role)

# 统一认领接口：旧的 4 个防务调度器（守家/守墙/驻军/资源守卫）改走这里登记角色，
# director 的兜底派单因此不会再碰它们，租约到期也能自动回收（后续步骤会把挑选逻辑也收进来）。
func _director_claim(u, role: int, lease: float) -> void:
	if u == null or not is_instance_valid(u) or battle == null:
		return
	_director_set_role(u, role, lease, float(battle.game_time))

func _director_release(uid: int) -> void:
	_roles.erase(uid)

func _director_role_count(role: int) -> int:
	var n: int = 0
	for uid in _roles.keys():
		var ent: Dictionary = _roles[uid]
		if int(ent.get("role", -1)) == role:
			n += 1
	return n

func _director_release_role(uid: int) -> void:
	var ent = _roles.get(uid)
	if ent == null:
		return
	var u = instance_from_id(uid)
	if u != null and is_instance_valid(u):
		var role: int = int(ent.get("role", 0))
		match role:
			UnitRole.WALL:
				u.remove_meta("ai_wall_guard")
				u.remove_meta(WALL_GUARD_SLOT_META)
				u.remove_meta(WALL_GUARD_POS_META)
				u.hold_position = false
			UnitRole.HOME_GUARD:
				u.remove_meta("ai_home_guard")
				u.garrison_point = Vector3.ZERO
			UnitRole.GARRISON:
				u._garrison_target_id = -1
			UnitRole.RESOURCE_GUARD:
				u.remove_meta("ai_resource_guard")
	_roles.erase(uid)

func _director_dispatch(idle: Array, now: float) -> void:
	var threatened: bool = _defense != null and int(_defense.threat_level) >= 2
	var castle = get_peer_castle(my_peer_id)
	var field_target = _get_attack_target_castle() if not threatened else null
	var can_field: bool = field_target != null and is_instance_valid(field_target) and phase != Phase.PRODUCTION
	var rally: Vector3 = castle.global_position if castle != null and is_instance_valid(castle) else Vector3.ZERO
	for u in idle:
		if not is_instance_valid(u) or u.health <= 0:
			continue
		# 身边 40 米内有敌：直接接敌，这是最高优先级（避免站在敌群里发呆）
		var enemy = u._find_nearest_enemy_near(u.global_position, 40.0)
		if enemy != null and is_instance_valid(enemy):
			if u.global_position.distance_to(enemy.global_position) <= 25.0:
				u.attack_target(enemy)
			else:
				u.attack_move_to(enemy.global_position)
			_director_set_role(u, UnitRole.FIELD, DIRECTOR_FIELD_LEASE, now)
			continue
		if can_field:
			u.attack_move_to(field_target.global_position)
			_director_set_role(u, UnitRole.FIELD, DIRECTOR_FIELD_LEASE, now)
			continue
		# 兜底：回主城集结点待命。离得近就不重复下命令，只登记租约。
		if castle != null and is_instance_valid(castle) and u.global_position.distance_to(rally) > DIRECTOR_STANDBY_MIN_DIST:
			u.attack_move_to(rally)
		_director_set_role(u, UnitRole.STANDBY, DIRECTOR_STANDBY_LEASE, now)

func _director_log() -> void:
	var names: Array = ["IDLE", "SCOUT", "GARRISON", "WALL", "HOME_GUARD", "RESOURCE_GUARD", "BUILDING_DEFENSE", "HARASS", "RAID", "FIELD", "SIEGE", "TRANSPORT", "ESCORT", "RETREAT", "STANDBY"]
	var counts: Dictionary = {}
	for uid in _roles.keys():
		var ent: Dictionary = _roles[uid]
		var k: int = int(ent.get("role", 0))
		counts[k] = int(counts.get(k, 0)) + 1
	var parts: Array = []
	for k in counts.keys():
		var idx: int = clampi(int(k), 0, names.size() - 1)
		parts.append("%s=%d" % [String(names[idx]), int(counts[k])])
	print("[DIRECTOR] p%d t=%.0f %s" % [my_peer_id, float(battle.game_time), " ".join(parts)])

func _process_line_3():
	if count_building(28) < _effective_house_target() and can_afford_building(28):
		var hp2 = _find_build_position_near_own(28)
		if hp2 != Vector3.ZERO and _force_house_builder(hp2):
			build_building(28, hp2)

# 人口满时房屋是解锁兵营/登陆兵的唯一出路。找不到空闲农民时，
# 从采集/运输里的农民临时抽一个出来建房，避免"没房→人口满→没兵→永远没房"。
func _force_house_builder(pos: Vector3) -> bool:
	if battle == null or not battle.has_method("find_nearest_idle_builder"):
		return false
	var existing = battle.find_nearest_idle_builder(my_team, my_peer_id, pos, 60.0)
	if existing != null:
		return true
	var best = null
	var best_d: float = INF
	for e in _cached_armies():
		if not is_instance_valid(e) or not (e is Army) or e.health <= 0:
			continue
		if e.entity_id != 10 or not entity_belongs_to_me(e) or not e.can_move:
			continue
		if e.has_meta("ai_transporting") or e.has_meta("ai_home_guard") or e.has_meta("ai_wall_guard"):
			continue
		# 采集中也要能抽走；旧逻辑把 _work_target_id != -1 的农民全跳过，
		# 六 AI 混战时 15 个农民都在采集，结果一个建房工人都找不到。
		if String(e.current_order) == "build":
			continue
		var d: float = e.global_position.distance_squared_to(pos)
		if d < best_d:
			best_d = d
			best = e
	if best == null:
		return false
	if best.has_method("_detach_from_building"):
		best._detach_from_building()
	if best.has_method("stop_movement"):
		best.stop_movement()
	best.current_order = ""
	best.current_target = null
	best._work_target_id = -1
	return true

# 第 X 分钟至少 X 座民居，8 座封顶；提前一分钟开工，给建造时间留出余量。
func _required_house_count() -> int:
	if battle == null:
		return 0
	var minute: int = int(floor(battle.game_time / 60.0)) + HOUSE_BUILD_LEAD_MINUTES
	return mini(minute, HOUSE_TARGET_MAX)

# 民居优先于造兵/攒投石机资源；这里绕过 reserve 检查，只确认木材足够。
# 否则人口满时 AI 会先把木材花在别处，导致“到点没有 X 座民居”。
func _ensure_house_quota() -> void:
	# 接近人口上限时 effective 会抬到 12；旧实现只按“第 X 分钟 X 座”造到 8，
	# 结果人口满了但民居目标还是 8，军队长期卡在 40/50 人口。
	var required: int = maxi(_required_house_count(), _effective_house_target())
	if required <= 0 or count_building(28) >= required:
		return
	var cfg = EntityDatabase.get_config(28)
	if cfg.is_empty():
		return
	var cost = cfg.get("cost", {})
	var res = _get_resources()
	for k in cost:
		if int(res.get(k, 0)) < int(cost[k]):
			return
	var hp: Vector3 = _find_build_position_near_own(28)
	if hp != Vector3.ZERO and _force_house_builder(hp):
		build_building(28, hp)

# 六 AI 混战时经常只有 0~1 座兵营：普通建造循环被升级/资源储备打断后，
# 人口一满就再也补不上生产建筑。这里每轮决策兜底保证至少 2 座兵营。
func _ensure_military_producer_quota() -> void:
	if battle == null or count_building(21) >= 2:
		return
	if not can_afford_building(21):
		return
	var hp: Vector3 = _find_build_position_near_own(21)
	if hp != Vector3.ZERO and _force_house_builder(hp):
		build_building(21, hp)

func _process_line_4():
	# 只保留"危急"（敌军确实压上基地）时的守家优先；普通警戒交给守军处理，
	# 否则六 AI 混战里 threat 长期 >=2，主攻会被永久取消。
	if _defense != null and int(_defense.threat_level) >= 3:
		return
	if current_tactic == LateTactic.DEFEND:
		return
	# 主城 15 米内有敌不再取消整场主攻：守家兵有 ai_home_guard 标签，
	# attack_move() 本来就跳过它们，野战部队可以照常出门。
	var my_key_gate = my_peer_id if my_peer_id != -1 else my_team
	var want_attack_gate: bool = an_attack()
	# 解锁守军的时机提前：原来它排在"家被打就 return"之后，导致守军永远解锁不了，
	# 每个 AI 都有约 1/3 的兵被 ai_home_guard 永久锁在主城（实测 27 兵里锁 5 个）。
	# 解除守军不再绑"野战兵 < 12"这个条件：那个条件用的指标本身排除了守军，
	# 兵越多守军越多、野战兵越少，反而永远不解锁（自锁）。现在每次主攻都解锁。
	if want_attack_gate and _defense != null:
		_defense.release_guards_for_attack()
	# 压制姿态必须持续给实际部队下主攻命令：不要求先满 12 人，也不等 120 秒，
	# 否则队列里的兵会让“压制”提前亮起，但场上实际部队一直不出门。
	if current_tactic == LateTactic.OVERWHELM:
		if not want_attack_gate:
			return
		if _defense != null:
			_defense.release_guards_for_attack()
		var overwhem_target = _get_attack_target_castle()
		if overwhem_target:
			attack_move(overwhem_target.global_position, 40)
		return
	# 发育阶段保留原来的 ASSAULT 门槛，但兵力成型且开局时间已过就先发起主攻，
	# 避免一直等到 30 人、结果因为人口/产能卡住而永远不出门
	if phase == Phase.DEVELOPMENT and battle.game_time < 120.0:
		return
	# 骚扰小队出门时主力仍可进攻；attack_move 会跳过 ai_harass 单位
	# 主攻前先解除主城守军：守军会计入军队总数但不计入可出击野战军，
	# 不解锁就会被“账面 30、野战 5”卡住 12 人主攻门槛。
	var want_attack: bool = want_attack_gate
	if want_attack and _defense != null:
		_defense.release_guards_for_attack()
	var my_key = my_key_gate
	# 主攻门槛不再固定 12：六 AI 混战时很多 AI 的野战兵长期只有 4~10 个
	# （实测 t=420 时 6 个 AI 里 4 个 <12），固定门槛会让它们整局都不出门，
	# 家里一堆兵站着待命。开局 180 秒后、主城没有被真打，6 个野战兵就允许出门。
	var field_now: int = count_land_army()
	var attack_threshold: int = 12
	if battle.game_time >= 180.0 and not _base_under_attack():
		attack_threshold = 6
	if field_now >= attack_threshold and want_attack:
		var target = _get_attack_target_castle()
		if target:
			# 上限从 30 提到 40：后期野战兵常常多于 30，剩下的人一直待命
			attack_move(target.global_position, 40)

func _process_line_5():
	var shipyards = []
	for e in battle.entities.get_children():
		if e is Building and e.entity_id == 23 and e.health > 0 and e.build_timer <= 0 and entity_belongs_to_me(e):
			shipyards.append(e)
	if shipyards.is_empty(): return
	# 战船也走普通兵种的全局数量上限。旧逻辑只数“船坞附近”的船，
	# 战船一开走就重新计数，AI 会无限补船；改为全局 count_unit 后，
	# 和步兵/骑兵一样最多补到当前军队目标数。
	var army_target: int = _effective_army_target()
	var total_warships: int = count_unit(13)
	var total_gunboats: int = count_unit(39)
	for sy in shipyards:
		var warships = 0; var gunboats = 0; var fishermen = 0
		for e in battle.entities.get_children():
			if e is Army and e.health > 0 and entity_belongs_to_me(e) and e.global_position.distance_to(sy.global_position) < SHIPYARD_FISHER_RADIUS:
				if e.entity_id == 13: warships += 1
				elif e.entity_id == 39: gunboats += 1
				elif e.entity_id == 14: fishermen += 1
		# 只有军事水域才造战船；油田小水塘只保留采集船，避免白耗木头/金币。
		var military_water: bool = _shipyard_has_military_water(sy)
		if military_water:
			while warships < 2 and total_warships < army_target and can_afford(13) and _can_train_unit():
				if not produce_unit(13):
					break
				warships += 1
				total_warships += 1
			while gunboats < 2 and total_gunboats < army_target and can_afford(39) and _can_train_unit():
				if not produce_unit(39):
					break
				gunboats += 1
				total_gunboats += 1
		# 每个船坞至少保证 1 艘采集船，直接在该船坞排队，避免被别的船坞抢走产能
		# 重装武器厂科技期间油需求很大，每个船坞临时补到 2 艘采集船
		var fisher_target = 1
		if _trebuchet_pending() and not _trebuchet_unlocked() and int(_get_resources().get("oil", 0)) < 400:
			fisher_target = 2
		var has_fisher_queued: bool = false
		for pid in sy.production_queue:
			if int(pid) == 14: has_fisher_queued = true; break
		if fishermen < fisher_target and not has_fisher_queued and can_afford(14) and _can_train_unit():
			sy.try_produce(14)

# ═══ Merchants (castle Lv3+) ═══
func _get_academy_lv() -> int:
	for entity in battle.entities.get_children():
		if entity is Building and entity.entity_id == 42 and entity.team == my_team and entity.health > 0:
			return entity.upgrade_level
	return 0

func _ensure_merchants():
	for entity in battle.entities.get_children():
		if not (entity is Building and entity.entity_id == 52): continue
		if entity.health <= 0 or entity.build_timer > 0: continue
		if not entity_belongs_to_me(entity): continue
		if entity.upgrade_level < 3: continue
		var needed = []
		if entity.upgrade_level >= 3: needed.append(44)
		if entity.upgrade_level >= 4: needed.append(45)
		if entity.upgrade_level >= 5: needed.append(43)
		for mid in needed:
			var found = false
			for prod in entity.production_list:
				if prod.unit_id == mid: found = true; break
			if not found: entity.production_list.append({"unit_id": mid, "cooldown": 10.0, "queue_limit": 3})


# ═══ Land Army Rally ═══
# 每个单位只集合一次（通过 meta 标记），在 decide() 中每次决策周期调用
func _rally_land_army_to_castle():
	var castle = get_peer_castle(my_peer_id)
	if not castle: return
	var enemy_dir = _get_enemy_army_direction(castle.global_position)
	var rally_point = castle.global_position + enemy_dir.normalized() * LAND_RALLY_DISTANCE
	# Ensure rally point is on valid terrain (not water)
	var gx = int(rally_point.x + RTSConfig.MAP_SIZE / 2)
	var gz = int(rally_point.z + RTSConfig.MAP_SIZE / 2)
	if gx >= 0 and gx < RTSConfig.MAP_SIZE and gz >= 0 and gz < RTSConfig.MAP_SIZE:
		if battle.get_terrain_at_grid(gx, gz) == 2:
			for offset in [Vector3(5,0,0), Vector3(-5,0,0), Vector3(0,0,5), Vector3(0,0,-5), Vector3(8,0,0), Vector3(-8,0,0)]:
				var alt = rally_point + offset
				var agx = int(alt.x + RTSConfig.MAP_SIZE / 2)
				var agz = int(alt.z + RTSConfig.MAP_SIZE / 2)
				if agx >= 0 and agx < RTSConfig.MAP_SIZE and agz >= 0 and agz < RTSConfig.MAP_SIZE:
					if battle.get_terrain_at_grid(agx, agz) != 2:
						rally_point = alt; break
	for entity in battle.entities.get_children():
		if not (entity is Army) or entity.health <= 0: continue
		if not entity_belongs_to_me(entity): continue
		# Skip non-combat / naval units
		if entity.entity_id in [5, 6, 10, 14, 43, 44, 45, 46, 47, 48, 49, 50, 51]: continue
		if _is_scout_unit(entity): continue
		if entity.water_capable: continue
		# 账本里已有角色（集结/守军/守墙/驻军/骚扰）的单位不再重复集结。
		# 以前用永久的 ai_rallied 标记，导致首波之后新生产的兵再也不会被集结。
		if _roles.has(entity.get_instance_id()): continue
		if entity.has_meta("ai_home_guard") or entity.has_meta("ai_resource_guard") or entity.has_meta("ai_harass") or entity.has_meta("ai_transporting") or entity.has_meta("ai_wall_guard"): continue
		if _is_held_by_garrison(entity): continue
		# 已登船单位由 AIWaterCrossing 管理，不再被集结点重新下令
		var boarded = entity.get("_boarded_on")
		if boarded != null and int(boarded) != -1: continue
		# Only rally idle units (刚生产出来的单位处于空闲状态)
		if entity.current_order != "" or entity.current_target != null: continue
		_director_claim(entity, UnitRole.STANDBY, 30.0)
		entity.attack_move_to(rally_point)

# ═══ Wall Defense Deployment ═══
# 把闲置远程单位送上前线城墙。城墙未破时单位只吃远程伤害，且站得高射界好；
# 每面墙独立决定炮台/驻军，小型远程单位可派 2~3 个，移动中的单位保留
# ai_wall_guard 元数据防止重复派人。
func _is_valid_wall_slot(wall) -> bool:
	return is_instance_valid(wall) and wall is Building and int(wall.entity_id) == 27 and wall.health > 0 and wall.build_timer <= 0.0

func _is_ranged_wall_candidate(e) -> bool:
	if not (e is Army) or e.health <= 0 or not entity_belongs_to_me(e):
		return false
	if e.water_capable or not bool(e.can_move):
		return false
	if float(e.attack_range) < 2.0 or int(e.target_type) <= 0:
		return false
	if int(e.entity_id) in [5, 6, 9, 10, 14, 16, 17, 33, 43, 44, 45, 46, 47, 48, 49, 50, 51, 55, 56, 57, 59]:
		return false
	var animal_type = e.get("_animal_type")
	if animal_type != null and str(animal_type) != "":
		return false
	var boarded = e.get("_boarded_on")
	if boarded != null and int(boarded) != -1:
		return false
	if e.has_meta("ai_wall_guard") or e.hold_position:
		return false
	# 正在执行资源守卫/骚扰/运输/护航/建筑回防的单位有专属角色，不能被守墙调度截走。
	if e.has_meta("ai_resource_guard") or e.has_meta("ai_harass") \
			or e.has_meta("ai_transporting") or e.has_meta("ai_escorting") \
			or e.has_meta("ai_building_defense_until"):
		return false
	if e.garrison_point != Vector3.ZERO:
		return false
	if e.current_target != null or e.current_order != "":
		return false
	# 有排队命令的单位马上要执行下一步，不能被守墙调度截走。
	if not e.command_queue.is_empty():
		return false
	var sgb = e.get("_soldier_garrison_building")
	if sgb != null and sgb.get_ref() != null:
		return false
	if e._is_unit_on_wall():
		return false
	return true

func _assign_wall_guard(unit, wall, slot: int = 0, count: int = 1) -> void:
	_director_claim(unit, UnitRole.WALL, 600.0)
	unit.set_meta("ai_wall_guard", wall.get_instance_id())
	unit.set_meta(WALL_GUARD_SLOT_META, slot)
	unit.set_meta(WALL_GUARD_POS_META, _wall_guard_slot_position(wall, slot, count))
	unit.hold_position = true
	# 同一个墙格可能安排 2~3 个小型远程兵，用槽位错开站位；
	# 抵达墙脚后由 Army 负责把单位抬到墙顶。
	_order_wall_move(unit, wall, slot, count)

func _order_wall_move(unit, wall, slot: int = 0, count: int = 1) -> void:
	var target_pos: Vector3 = _wall_guard_slot_position(wall, slot, count)
	# 记录精确落点：Army 抵达墙脚后要靠它判断上墙位置和槽位偏移。
	unit.set_meta(WALL_GUARD_POS_META, target_pos)
	# 城墙刚补建/刚完成时，单位可能曾把该墙格记为不可达；不清掉的话会永远站在原地。
	if unit._movement:
		unit._movement.clear_blacklist_at(target_pos)
	unit.move_to(target_pos)

func _wall_guard_slot_position(wall, slot: int, count: int) -> Vector3:
	var offsets: Array = [0.0]
	if count == 2:
		offsets = [-0.35, 0.35]
	elif count >= 3:
		offsets = [-0.35, 0.0, 0.35]
	var idx: int = clampi(slot, 0, offsets.size() - 1)
	var axis: Vector3 = defense_wall_axis
	if axis.length_squared() < 0.01:
		axis = _wall_guard_neighbor_axis(wall)
	# 用城墙所在格中心作为站位基准，而不是建筑节点中心：
	# 偏移一旦超过半格，world_to_grid 会落到相邻格，单位就失去墙顶免疫。
	var g: Vector2i = battle.world_to_grid(wall.global_position)
	var base: Vector3 = battle.grid_to_world(g.x, g.y)
	base.y = wall.global_position.y
	return base + axis.normalized() * float(offsets[idx])

# 防线方向由 _plan_defense_line 记录；若旧城墙没有记录，就用最近同阵营城墙推断墙线方向。
func _wall_guard_neighbor_axis(wall) -> Vector3:
	var best: Building = null
	var best_d: float = 4.0
	for b in _cached_buildings():
		if b == wall or not _is_valid_wall_slot(b) or not entity_belongs_to_me(b):
			continue
		var d: float = wall.global_position.distance_to(b.global_position)
		if d > 0.05 and d < best_d:
			best_d = d
			best = b
	if best != null:
		return (best.global_position - wall.global_position).normalized()
	return Vector3.RIGHT

func _release_wall_guard(unit) -> void:
	if not is_instance_valid(unit):
		return
	_director_release(unit.get_instance_id())
	unit.remove_meta("ai_wall_guard")
	unit.remove_meta(WALL_GUARD_SLOT_META)
	unit.remove_meta(WALL_GUARD_POS_META)
	unit.hold_position = false
	# 城墙被拆时不管当前是在赶路还是正在攻击，都立即清空战斗状态；
	# 否则单位会带着旧的 attack 目标继续追出去，看起来像“守墙兵弃墙”。
	if unit.has_method("stop_movement"):
		unit.stop_movement()

func _deploy_ranged_units_to_walls() -> void:
	if battle == null:
		return
	var armies: Array = _cached_armies()
	var occupied: Dictionary = {}
	var guard_count: Dictionary = {}
	var used_slots: Dictionary = {}
	for e in armies:
		if not is_instance_valid(e) or e.health <= 0:
			continue
		var boarded = e.get("_boarded_on")
		if boarded != null and int(boarded) != -1:
			continue
		var eg: Vector2i = battle.world_to_grid(e.global_position)
		var wall_here = battle._wall_entity_grid.get(eg)
		if wall_here != null and is_instance_valid(wall_here) and wall_here.health > 0:
			occupied[eg] = true
		if not e.has_meta("ai_wall_guard"):
			continue
		var wid: int = int(e.get_meta("ai_wall_guard"))
		var wall = instance_from_id(wid)
		if not _is_valid_wall_slot(wall):
			_release_wall_guard(e)
			continue
		guard_count[wid] = int(guard_count.get(wid, 0)) + 1
		var slot: int = int(e.get_meta(WALL_GUARD_SLOT_META, 0))
		if not used_slots.has(wid):
			used_slots[wid] = {}
		used_slots[wid][slot] = true
		if e._is_unit_on_wall():
			# 已经站上城墙：锁定站位，避免剩余路径让它在墙顶来回走。
			e.hold_position = true
			if e.current_order == "move":
				e.stop_movement()
		elif e.current_order == "":
			# 中途被打断/寻路失败回到空闲时重新送上去；战斗中不强行拉走。
			_order_wall_move(e, wall, slot, int(e.get_meta(WALL_GUARD_TARGET_META, 1)))
	# 炮台等墙顶建筑也占用墙格，避免远程兵与炮台重叠
	for b in _cached_buildings():
		if is_instance_valid(b) and b.health > 0 and int(b.entity_id) == WALL_CANNON_ID:
			occupied[battle.world_to_grid(b.global_position)] = true
	var walls: Array = []
	for b in _cached_buildings():
		if _is_valid_wall_slot(b) and entity_belongs_to_me(b):
			walls.append(b)
	if walls.is_empty():
		return
	var candidates: Array = []
	for e in armies:
		if not is_instance_valid(e) or e.health <= 0:
			continue
		if not _is_ranged_wall_candidate(e):
			continue
		if occupied.has(battle.world_to_grid(e.global_position)):
			continue
		candidates.append(e)
	# 墙顶炮台不再每面墙 50% 随机：优先拐角、墙端和正对威胁方向的墙段，
	# 并限制总量，避免把石头/木材全砸在整圈炮台上。
	var cannon_walls: Dictionary = _pick_wall_cannon_walls(walls)
	for wall in walls:
		var wid: int = wall.get_instance_id()
		var wall_grid: Vector2i = battle.world_to_grid(wall.global_position)
		var have: int = int(guard_count.get(wid, 0))
		var mode: String = str(wall.get_meta(WALL_GUARD_MODE_META, ""))
		# 炮台可能已存在但元数据丢失（例如重载/旧逻辑），先按炮台墙处理。
		if _wall_has_cannon(wall):
			wall.set_meta(WALL_GUARD_MODE_META, "cannon")
			occupied[wall_grid] = true
			continue
		# 已有其他单位站在墙格上且不是本逻辑派出的守军时，保留原状态，不硬塞炮台。
		if have <= 0 and occupied.has(wall_grid):
			continue
		if have > 0 and mode != "ranged":
			mode = "ranged"
			wall.set_meta(WALL_GUARD_MODE_META, mode)
		if mode == "":
			mode = "cannon" if cannon_walls.has(wid) else "ranged"
			wall.set_meta(WALL_GUARD_MODE_META, mode)
		if mode == "cannon":
			if have > 0:
				# 老存档/旧逻辑已经在墙上放了兵，就不再硬塞炮台，避免重叠。
				wall.set_meta(WALL_GUARD_MODE_META, "ranged")
			elif _try_build_wall_cannon(wall):
				occupied[wall_grid] = true
			continue
		var target: int = int(wall.get_meta(WALL_GUARD_TARGET_META, 0))
		var want_small: bool = bool(wall.get_meta(WALL_GUARD_SMALL_META, false))
		if target <= 0:
			var first = _pick_random_wall_candidate(candidates, wall, -1)
			if first == null:
				continue
			want_small = _is_small_wall_guard(first)
			target = randi_range(2, 3) if want_small else 1
			wall.set_meta(WALL_GUARD_TARGET_META, target)
			wall.set_meta(WALL_GUARD_SMALL_META, want_small)
			var first_slot: int = _find_free_wall_slot(used_slots.get(wid, {}), target)
			if first_slot >= 0:
				_assign_wall_guard(first, wall, first_slot, target)
				candidates.erase(first)
				if not used_slots.has(wid):
					used_slots[wid] = {}
				used_slots[wid][first_slot] = true
				have += 1
		if have >= target:
			continue
		var want_flag: int = 1 if want_small else 0
		while have < target:
			var pick = _pick_random_wall_candidate(candidates, wall, want_flag)
			if pick == null and want_flag != -1:
				# 同类兵不够时允许用其他远程单位补位，避免城墙一直空着。
				pick = _pick_random_wall_candidate(candidates, wall, -1)
			if pick == null:
				break
			var slot: int = _find_free_wall_slot(used_slots.get(wid, {}), target)
			if slot < 0:
				break
			_assign_wall_guard(pick, wall, slot, target)
			candidates.erase(pick)
			if not used_slots.has(wid):
				used_slots[wid] = {}
			used_slots[wid][slot] = true
			have += 1

func _is_small_wall_guard(unit) -> bool:
	return float(unit.body_radius) <= WALL_GUARD_SMALL_BODY

func _find_free_wall_slot(used: Dictionary, count: int) -> int:
	for i in range(count):
		if not used.has(i):
			return i
	return -1

# 从候选里随机挑一个；want_small: -1=不限，1=小型远程，0=大型远程。
func _pick_random_wall_candidate(candidates: Array, wall, want_small: int):
	var pool: Array = []
	var max_d2: float = WALL_DEPLOY_MAX_DISTANCE * WALL_DEPLOY_MAX_DISTANCE
	for u in candidates:
		if not is_instance_valid(u) or u.health <= 0:
			continue
		if u.global_position.distance_squared_to(wall.global_position) > max_d2:
			continue
		var small: bool = _is_small_wall_guard(u)
		if want_small == 1 and not small:
			continue
		if want_small == 0 and small:
			continue
		pool.append(u)
	if pool.is_empty():
		return null
	return pool.pick_random()

func _wall_has_cannon(wall) -> bool:
	for b in _cached_buildings():
		if b is Building and b.health > 0 and int(b.entity_id) == WALL_CANNON_ID \
				and entity_belongs_to_me(b):
			if b.global_position.distance_to(wall.global_position) < 0.9:
				return true
	return false

func _try_build_wall_cannon(wall) -> bool:
	if _wall_has_cannon(wall):
		return true
	if not _ai_can_build(WALL_CANNON_ID) or not can_afford_building(WALL_CANNON_ID):
		return false
	return build_building(WALL_CANNON_ID, wall.global_position)

# 墙顶炮台只放在“值得放”的墙段：拐角、墙端、正对敌方向。
# 总量按墙数 30% 封顶（2~24 座），防止 AI 把整圈城墙都改造成炮台。
func _pick_wall_cannon_walls(walls: Array) -> Dictionary:
	var existing: int = 0
	for b in _cached_buildings():
		if is_instance_valid(b) and b.health > 0 and int(b.entity_id) == WALL_CANNON_ID \
				and entity_belongs_to_me(b):
			existing += 1
	var quota: int = clampi(int(ceil(float(walls.size()) * 0.3)), 2, 24)
	var need: int = quota - existing
	if need <= 0:
		return {}
	var castle = get_peer_castle(my_peer_id)
	var enemy_dir: Vector3 = _get_enemy_army_direction(castle.global_position) \
			if is_instance_valid(castle) else Vector3.FORWARD
	enemy_dir.y = 0.0
	if enemy_dir.length_squared() < 0.0001:
		enemy_dir = Vector3.FORWARD
	else:
		enemy_dir = enemy_dir.normalized()
	var rated: Array = []
	for w in walls:
		if not is_instance_valid(w):
			continue
		if _wall_has_cannon(w):
			continue
		if str(w.get_meta(WALL_GUARD_MODE_META, "")) == "ranged":
			continue
		if int(w.get_meta(WALL_GUARD_TARGET_META, 0)) > 0:
			continue
		rated.append(w)
	rated.sort_custom(func(a, b):
		return _wall_cannon_score(a, walls, castle, enemy_dir) \
				> _wall_cannon_score(b, walls, castle, enemy_dir)
	)
	var out: Dictionary = {}
	for i in mini(need, rated.size()):
		out[rated[i].get_instance_id()] = true
	return out

func _wall_cannon_score(wall: Building, walls: Array, castle, enemy_dir: Vector3) -> float:
	var score: float = 0.0
	if is_instance_valid(castle):
		var to_wall: Vector3 = wall.global_position - castle.global_position
		to_wall.y = 0.0
		if to_wall.length_squared() > 0.0001:
			score += to_wall.normalized().dot(enemy_dir) * 2.0
	var neighbors: int = 0
	var dirs: Array = []
	for other in walls:
		if other == wall or not is_instance_valid(other):
			continue
		var d: Vector3 = other.global_position - wall.global_position
		d.y = 0.0
		if d.length_squared() <= 2.35 * 2.35:
			neighbors += 1
			dirs.append(d.normalized())
	if neighbors <= 1:
		score += 2.2   # 墙端：正对绕后/爆破点，炮台价值最高
	else:
		# 拐角：相邻墙方向不是一条直线
		var corner: bool = false
		for i in dirs.size():
			for j in range(i + 1, dirs.size()):
				if absf(dirs[i].dot(dirs[j])) < 0.55:
					corner = true
					break
			if corner:
				break
		if corner:
			score += 1.4
	return score

# ═══ Naval Patrol ═══
func _patrol_navy_around_water():
	var shipyards: Array = []
	for e in battle.entities.get_children():
		if e is Building and e.entity_id == 23 and e.health > 0 and e.build_timer <= 0 and entity_belongs_to_me(e):
			shipyards.append(e)
	if shipyards.is_empty(): return
	var idle_naval: Array = []
	for entity in battle.entities.get_children():
		if not (entity is Army) or entity.health <= 0: continue
		if not entity_belongs_to_me(entity): continue
		if not entity.water_capable: continue
		if entity.entity_id == 14: continue  # skip fishing boats
		if entity.entity_id == 9: continue  # 运载船由渡水模块调度，不能当成巡逻舰
		if entity.entity_id == 40: continue  # 爆破船应冲向敌舰/敌岸，不能拿去绕圈巡逻
		if entity.has_meta("ai_transporting") or entity.has_meta("ai_escorting"): continue
		if _is_held_by_garrison(entity): continue
		if entity.current_order != "" or entity.current_target != null: continue
		idle_naval.append(entity)
	if idle_naval.is_empty(): return
	# 统计全图活鱼，留够繁殖基数后才允许战船猎鱼；否则继续正常巡逻。
	var fish_targets: Array = []
	for e in battle.entities.get_children():
		if e is Army and e.health > 0 and str(e.get("_animal_type")) == "fish":
			fish_targets.append(e)
	var hunt_budget: int = maxi(0, fish_targets.size() - NAVAL_MIN_FISH_POPULATION)
	for unit in idle_naval:
		if hunt_budget > 0:
			var fish = _find_nearby_fish(unit.global_position, fish_targets)
			if fish != null:
				unit.attack_target(fish)
				hunt_budget -= 1
				continue
		var best_sy = shipyards[0]
		var best_dist = unit.global_position.distance_to(best_sy.global_position)
		for sy in shipyards:
			var d = unit.global_position.distance_to(sy.global_position)
			if d < best_dist:
				best_dist = d
				best_sy = sy
		var patrol_point = _find_water_patrol_point(best_sy.global_position)
		if patrol_point != Vector3.ZERO:
			unit.attack_move_to(patrol_point)

func _find_nearby_fish(pos: Vector3, fish_list: Array) -> Army:
	var best: Army = null
	var best_dist: float = NAVAL_FISH_ATTACK_RANGE
	for f in fish_list:
		if not is_instance_valid(f) or f.health <= 0:
			continue
		var d: float = pos.distance_to(f.global_position)
		if d < best_dist:
			best_dist = d
			best = f
	return best

func _find_water_patrol_point(near_pos: Vector3) -> Vector3:
	for radius in [8, 15, 25, 35]:
		for _try in range(30):
			var angle = randf_range(0, TAU)
			var test = near_pos + Vector3(cos(angle) * radius, 0, sin(angle) * radius)
			var gx = int(test.x + RTSConfig.MAP_SIZE / 2)
			var gz = int(test.z + RTSConfig.MAP_SIZE / 2)
			if gx >= 0 and gx < RTSConfig.MAP_SIZE and gz >= 0 and gz < RTSConfig.MAP_SIZE:
				if battle.get_terrain_at_grid(gx, gz) == 2:
					return test
	return Vector3.ZERO



# ═══ Debug panel ═══
func update_debug_label():
	if not debug_panel: return
	if _title_rtl:
		_title_rtl.text = _relation_tag() + _panel_title_base + _my_nation_tag()
	_apply_panel_relation()
	if _trait_rtl:
		_trait_rtl.text = "[color=#d9c6aa]%s[/color]" % NationBonuses.get_trait_full(_my_nation_index())
	# 收起状态：主体不可见，跳过整块内容刷新，省掉每帧的统计与遍历开销
	if _panel_collapsed: return
	_update_research_text()

	# 面板统计只遍历一次实体：原实现对每种资源/单位/建筑各扫一遍全实体，
	# 7 个 AI 面板同时展开时每 10 帧会产生数百次全量扫描，是后期掉帧大户。
	var own_unit_counts: Dictionary = {}
	var own_build_counts: Dictionary = {}
	var own_build_levels: Dictionary = {}
	var gather_counts_by_res: Dictionary = {}
	var hunt_count: int = 0
	var repair_active: int = 0
	for entity in battle.entities.get_children():
		if not (entity is GameEntity) or entity.health <= 0:
			continue
		if not entity_belongs_to_me(entity):
			continue
		if entity is Building and entity.is_under_repair():
			repair_active += 1
		if entity is Army:
			var uid := int(entity.entity_id)
			own_unit_counts[uid] = int(own_unit_counts.get(uid, 0)) + 1
			if entity.entity_id in [10, 14] and entity.current_order in ["gather", "deliver"]:
				var gather_target = entity.current_target
				if is_instance_valid(gather_target) and gather_target is WorldResource:
					gather_counts_by_res[gather_target.resource_type] = int(gather_counts_by_res.get(gather_target.resource_type, 0)) + 1
			if _hunt_target and is_instance_valid(_hunt_target) and entity.current_target == _hunt_target:
				hunt_count += 1
		elif entity is Building and entity.build_timer <= 0:
			var bid := int(entity.entity_id)
			own_build_counts[bid] = int(own_build_counts.get(bid, 0)) + 1
			own_build_levels[bid] = maxi(int(own_build_levels.get(bid, 1)), int(entity.upgrade_level))

	var res = _get_resources(); var pop = _get_population()
	var _pe = {"PRODUCTION": "🌱", "DEVELOPMENT": "🏗️", "ASSAULT": "⚔️"}
	var phase_color := Color(0.49, 0.89, 0.63)
	if phase == Phase.DEVELOPMENT:
		phase_color = Color(1.0, 0.78, 0.34)
	elif phase == Phase.ASSAULT:
		phase_color = Color(1.0, 0.48, 0.42)
	_header_rtl.text = "%s [color=#%s]%s[/color]  |  %s" % [_pe.get(Phase.keys()[phase], "▶️"), phase_color.to_html(), Phase.keys()[phase], _get_tactic_name(current_tactic)]
	if _defense != null:
		_header_rtl.text += "\n[color=#9fd3ff]🛡 %s[/color]" % _defense.get_status_text()
	var pop_pct = float(pop.current) / max(pop.max, 1)
	_pop_bar.value = pop_pct * 100
	var pfs = _pop_bar.get_theme_stylebox("fill")
	if pfs: pfs.bg_color = Color(0.36, 0.82, 0.52) if pop_pct < 0.8 else Color(1.0, 0.62, 0.25)
	_pop_label.text = "👥 人口 %d/%d" % [pop.current, pop.max]
	# 主城血量
	var castle = get_peer_castle(my_peer_id) if my_peer_id != -1 else get_team_castle(my_team)
	if _castle_bar and _castle_label:
		if castle and is_instance_valid(castle):
			_castle_bar.visible = true
			_castle_bar.update_bar(castle.health, castle.max_health, -1, battle.get_entity_color(castle))
			_castle_label.text = "🏰 主城 Lv.%d %d/%d" % [castle.upgrade_level, int(castle.health), int(castle.max_health)]
		else:
			_castle_bar.visible = false
			_castle_label.text = "🏰 主城 已失守"
	var res_list = [
		{"k":"gold","n":"金","c":Color(1.0,0.84,0.1)}, {"k":"wood","n":"木","c":Color(0.25,0.82,0.2)},
		{"k":"stone","n":"石","c":Color(0.62,0.62,0.62)}, {"k":"food","n":"食","c":Color(1.0,0.55,0.1)},
		{"k":"oil","n":"油","c":Color(0.4,0.25,0.1)},
	]
	var limits = _get_limits()
	for i in range(5):
		var r = res_list[i]; var val = res.get(r.k, 0); var lim = limits.get(r.k, 500)
		_res_bars[i].value = min(float(val)/max(lim,1)*100, 100)
		_res_labels[i].text = "%d" % val
		var gc = int(gather_counts_by_res.get(r.k, 0))
		_res_labels[i].text += " %d人" % gc
		_res_labels[i].text += " %+.1f/s" % _ai_income_rate[r.k]
		var s = _res_bars[i].get_theme_stylebox("fill")
		if s: s.bg_color = r.c
	var eco_units = [[10,"农"],[14,"采船"],[5,"推车"],[6,"贸车"],[9,"运载"],
		[43,"油商"],[44,"木商"],[45,"石商"],[51,"食商"],[46,"县吏"],[47,"上校"],[48,"尚书"],[49,"统帅"],[50,"丞相"]]
	var eco_lines = []
	var eco_total = 0
	for u in eco_units:
		var cnt = int(own_unit_counts.get(u[0], 0))
		eco_total += cnt
		if cnt > 0: eco_lines.append("[color=#9fd6a4]%s%s[/color]:[color=white]%d[/color]" % [UITheme.entity_emoji(u[0], 2), u[1], cnt])
	_eco_rtl.text = "[color=#a39a8e](无经济单位)[/color]" if eco_lines.is_empty() else " ".join(eco_lines)
	if _eco_title: _eco_title.text = "[color=#7cc4ff]▸ 💰 经济 %d[/color]" % eco_total

	var mil_units = [[11,"步"],[12,"弓"],[13,"战船"],[15,"骑"],[16,"炮"],[17,"投石"],[18,"攻城"],[19,"侦察"],
		[30,"狂战"],[31,"长弓"],[32,"法骑"],[33,"木牛"],[34,"象骑"],[35,"长枪"],[36,"重步"],[37,"重弓"],[38,"重骑"],[39,"炮艇"],[40,"爆破"],
		[58,"连弩"],[59,"巨投"],[55,"僧侣"],[56,"长老"],[57,"宗师"],[65,"武士"],[66,"甲骑"],
		[67,"蒙弓"],[68,"长生"],[69,"方阵"]]
	var mil_lines = []
	var mil_total = 0
	for u in mil_units:
		var cnt = int(own_unit_counts.get(u[0], 0))
		mil_total += cnt
		if cnt > 0: mil_lines.append("[color=#c9c0b0]%s%s[/color]:[color=white]%d[/color]" % [UITheme.entity_emoji(u[0], 2), u[1], cnt])
	_mil_rtl.text = "[color=#a39a8e](无军队)[/color]" if mil_lines.is_empty() else " ".join(mil_lines)
	if _mil_title: _mil_title.text = "[color=#7cc4ff]▸ ⚔️ 军队 %d[/color]" % mil_total
	var all_blds = [[20,"城"],[21,"营"],[22,"仓"],[23,"坞"],[24,"攻城车"],[25,"箭塔"],[26,"炮塔"],[27,"墙"],[28,"民"],[29,"重工"],[41,"瞭望"],[42,"书院"],[52,"集市"],[53,"城堡"],[64,"炮台"],[7,"桥"],[8,"梯子"],[54,"修道"]]
	var bld_lines = []
	var bld_total = 0
	for b in all_blds:
		var cnt = int(own_build_counts.get(b[0], 0))
		var max_lv = int(own_build_levels.get(b[0], 1))
		bld_total += cnt
		if cnt > 0: bld_lines.append("[color=#b6ad9f]%s【%d】%s[/color]:[color=white]%d[/color]" % [UITheme.entity_emoji(b[0], 1), max_lv, b[1], cnt])
	_bld_rtl.text = "[color=#a39a8e](无建筑)[/color]" if bld_lines.is_empty() else " ".join(bld_lines)
	if _bld_title: _bld_title.text = "[color=#7cc4ff]▸ 🏰 建筑 %d[/color]" % bld_total
	var hunt_info = "[color=#ffd27a]🏹 狩猎: %.0fs[/color]" % max(0, _hunt_timer)
	if _hunt_target and is_instance_valid(_hunt_target):
		hunt_info += " [color=#ff9a8a]目标:%s 猎人:%d/5[/color]" % [_hunt_target.get("_animal_type"), hunt_count]
	else: hunt_info += " [color=#a39a8e](待命)[/color]"
	if repair_active > 0:
		hunt_info += " [color=#8fe6c0]🔧 修理中:%d/%d[/color]" % [repair_active, REPAIR_MAX_CONCURRENT]
	_bld_rtl.text = hunt_info + "\n" + _bld_rtl.text

var debug_panel: Control = null
var _header_rtl: RichTextLabel

# 决策面板挂在 battle 的 UI 画布下，不是 AI 节点的子节点；
# AI 被移除（城堡被摧毁 / 场景切换）时必须显式释放，避免留下空面板
func _exit_tree():
	if is_instance_valid(debug_panel):
		debug_panel.queue_free()
	debug_panel = null

# 面板标题上显示本国名称：owner 优先，其次队伍默认（静态 1v1 红方 AI 用敌方国家）
func _my_nation_index() -> int:
	if not battle:
		return -1
	if battle is OnlineBattleManager:
		return int(battle.player_info.get(my_peer_id, {}).get("nation", -1))
	elif my_peer_id != -1 and battle.ai_players.has(my_peer_id):
		return int(battle.ai_players[my_peer_id].get("nation", -1))
	return int(GameSettings.enemy_nation)

func _my_nation_tag() -> String:
	if not battle or not battle.has_method("get_nation_name"):
		return ""
	var nat := _my_nation_index()
	if nat >= 0:
		# 国家名本身用暖白，避免国家色与敌我红/蓝在文字上抢语义；
		# 左边加一个实色小方块作为国家索引，和顶部色带呼应。
		var nc := RTSConfig.get_nation_color(nat, Color(0.85, 0.80, 0.70))
		return " [color=#%s]■[/color] [color=#e8dcc4]「%s」[/color]" % [nc.to_html(false), battle.get_nation_name(nat)]
	return ""
var _pop_bar: ProgressBar; var _pop_label: Label
var _res_bars: Array = []; var _res_labels: Array = []
var _mil_rtl: RichTextLabel; var _bld_rtl: RichTextLabel
var _trait_rtl: RichTextLabel
var _research_title: RichTextLabel = null   # 「🔬 科研」小节标题（经典模式隐藏）
var _research_rtl: RichTextLabel = null     # 科技时代 / 在研项目 / 已完成科技
var _castle_bar: HealthBarControl
var _castle_label: Label
var _eco_title: RichTextLabel
var _eco_rtl: RichTextLabel
var _mil_title: RichTextLabel
var _bld_title: RichTextLabel
var _title_rtl: RichTextLabel = null       # 面板标题（用于追加国家名）
var _panel_title_base: String = ""         # 不含国家名的原始标题
var _collapse_btn: Button = null           # 标题栏右侧的隐藏/展开按钮
var _body_vb: VBoxContainer = null         # 面板主体（隐藏时整块不可见）
var _body_scroll: ScrollContainer = null   # 内容滚动区，避免建筑统计被面板高度截断
var _panel_collapsed: bool = false         # 面板是否已收起为标题条
var _panel_bg_style: StyleBoxFlat = null   # 面板底板样式（按友方/敌方着色）
var _last_relation: int = -2               # 上次计算的敌我关系，避免每帧重设样式
var _last_panel_nation: Color = Color(-1, -1, -1, -1)  # 上次使用的国家底色，用于检测 nation 延迟写入
# 狩猎：固定派几个农民持续打猎，农民总数超过阈值才开始（避免前期断经济）
const HUNT_PEASANT_COUNT: int = 5
const HUNT_MIN_PEASANTS: int = 15

const PANEL_WIDTH: float = 540.0
const PANEL_HEIGHT: float = 400.0
const PANEL_COLLAPSED_HEIGHT: float = 44.0
# 决策面板展开时按真实时间每秒刷新一次；收起后只留标题条，放慢到 5 秒。
const PANEL_REFRESH_INTERVAL_OPEN: float = 1.0
const PANEL_REFRESH_INTERVAL_COLLAPSED: float = 5.0
var _panel_refresh_timer: float = 0.0
# 面板配色：主体保持低饱和暖黑，保证长文本可读；国家色只用于顶部色带和极淡底纹，
# 阵营色只用于左侧粗边和标题徽标，避免整块底板被高饱和色染得刺眼、发闷。
const PANEL_BG_BASE := Color(0.078, 0.072, 0.082, 0.95)
const PANEL_NATION_BG_TINT: float = 0.06
const PANEL_HEADER_TINT_ALPHA: float = 0.14
const PANEL_FRIENDLY := Color(0.34, 0.67, 1.0)
const PANEL_HOSTILE := Color(1.0, 0.40, 0.34)
const PANEL_NEUTRAL := Color(0.65, 0.65, 0.65)
var _panel_header_style: StyleBoxFlat = null

# 当前面板实际高度（折叠后只保留标题条），供统一布局函数计算下方面板位置
func get_panel_height() -> float:
	return PANEL_COLLAPSED_HEIGHT if _panel_collapsed else PANEL_HEIGHT

# 面板视角的敌我关系：1=友方（同队/盟友），-1=敌方，0=自己/中立
func _relation_to_player() -> int:
	if not battle: return 0
	if battle.diplomacy:
		var me = battle.player_owner_id
		if my_peer_id == me: return 0
		return 1 if battle.diplomacy.is_ally(me, my_peer_id) else -1
	if my_peer_id == battle.player_owner_id: return 0
	return 1 if my_team == battle.get_host_team() else -1

func _relation_color() -> Color:
	match _relation_to_player():
		1: return PANEL_FRIENDLY
		-1: return PANEL_HOSTILE
		_: return PANEL_NEUTRAL

func _relation_tag() -> String:
	match _relation_to_player():
		1: return "[color=#7cc4ff]🛡 友方[/color] "
		-1: return "[color=#ff9288]⚔ 敌方[/color] "
		_: return ""

# AI 所属国家的颜色：顶部色带与极淡底纹用它，一眼能看出是哪个国家在指挥。
# 不能用 team_nations：2v2/3v3 同队 AI 可能来自不同国家，按队伍取色会让
# 同一队的所有面板变成同一个颜色。优先按 owner peer（my_peer_id）取国家。
func _nation_color() -> Color:
	var nn: int = _my_nation_index()
	if nn >= 0:
		return RTSConfig.get_nation_color(nn)
	# 旧存档/数据尚未就绪时退回队伍国家，至少不显示成灰色
	if battle != null and battle.has_method("get_team_nation"):
		nn = int(battle.get_team_nation(my_team))
		if nn >= 0:
			return RTSConfig.get_nation_color(nn)
	return Color(0.7, 0.7, 0.7)

# 面板左侧粗边按友方蓝、敌方红区分（乱斗联盟变化时随之刷新）；
# 顶部色带与淡底纹用 AI 国家色，两者分开表达，互不抢文字可读性。
func _apply_panel_relation() -> void:
	if _panel_bg_style == null: return
	var rel = _relation_to_player()
	var nc := _nation_color()
	# 关系或国家颜色变化时才重建样式；AI 的 nation 可能在面板创建后才写入，
	# 所以不能只看 relation，否则会永远停在灰色兜底色。
	if rel == _last_relation and nc == _last_panel_nation:
		return
	_last_relation = rel
	_last_panel_nation = nc
	var c = _relation_color()
	# 左侧粗边表达阵营，其余三边收细，减少“整块色框”的压迫感。
	_panel_bg_style.border_color = Color(c.r, c.g, c.b, 0.9)
	_panel_bg_style.border_width_left = 5
	_panel_bg_style.border_width_right = 1
	_panel_bg_style.border_width_top = 1
	_panel_bg_style.border_width_bottom = 1
	# 主体只保留极淡的国家色倾向（6%），文字区基本是中性暖黑；
	# 国家身份主要交给顶部色带和提亮后的国家名，避免深红/深黄/深绿底把文字吞掉。
	var tinted: Color = PANEL_BG_BASE.lerp(nc, PANEL_NATION_BG_TINT)
	_panel_bg_style.bg_color = Color(tinted.r, tinted.g, tinted.b, 0.95)
	if _panel_header_style != null:
		_panel_header_style.bg_color = Color(nc.r, nc.g, nc.b, PANEL_HEADER_TINT_ALPHA)
		_panel_header_style.border_color = Color(nc.r, nc.g, nc.b, 0.95)

# AI 的科研情况：时代、在研项目（进度）、已完成的通用/特色科技。
# 只有科研模式才有意义；经典模式把整节隐藏，避免面板多一行“暂无”。
func _update_research_text() -> void:
	if _research_title == null or _research_rtl == null:
		return
	var research_on: bool = battle != null and battle.has_method("is_research_mode") and battle.is_research_mode()
	_research_title.visible = research_on
	_research_rtl.visible = research_on
	if not research_on:
		return
	if battle == null or not battle.has_method("get_research_state"):
		_research_rtl.text = "[color=#a39a8e]（科研数据不可用）[/color]"
		return
	var st: Dictionary = battle.get_research_state(my_peer_id, my_team)
	if st.is_empty():
		_research_rtl.text = "[color=#a39a8e]（暂无科研数据）[/color]"
		return
	var age: int = int(st.get("age", 0))
	var lines: Array = []
	lines.append("[color=#9fd3ff]时代：%s[/color]" % TechTreeData.age_name(age))
	var cur: Dictionary = st.get("current", {})
	if cur.is_empty():
		lines.append("[color=#a39a8e]研究队列空闲[/color]")
	else:
		var total: float = maxf(float(cur.get("total", 1.0)), 0.001)
		var pct: int = int(round(clampf(float(cur.get("elapsed", 0.0)) / total, 0.0, 1.0) * 100.0))
		lines.append("[color=#8fe6c0]研究中：%s %d%%[/color]" % [String(cur.get("name", "?")), pct])
	var bits: int = int(st.get("bits", 0))
	var nation_bits: int = int(st.get("nation_bits", 0))
	var nation: int = int(st.get("nation", -1))
	var done_names: Array = []
	for tid in TechTreeData.tech_ids():
		if TechTreeData.has_bit(bits, String(tid)):
			var info: Dictionary = TechTreeData.get_tech(String(tid))
			done_names.append(String(info.get("name", tid)))
	if nation >= 0:
		for t in TechTreeData.nation_techs(nation):
			if TechTreeData.has_nation_bit(nation_bits, nation, String(t.get("id", ""))):
				done_names.append(String(t.get("name", t.get("id", ""))))
	if done_names.is_empty():
		lines.append("[color=#d5c8a5]已完成：无[/color]")
	else:
		# 只列最近 3 项，面板宽度有限；总数用数字说明
		var recent: Array = done_names.slice(maxi(done_names.size() - 3, 0))
		lines.append("[color=#d5c8a5]已完成 %d 项：%s[/color]" % [done_names.size(), "、".join(recent)])
	_research_rtl.text = "\n".join(lines)

func _create_debug_panel():
	debug_panel = Control.new(); debug_panel.name = "AIDebugPanel"; debug_panel.z_index = 100
	debug_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var offset_y = 10
	var panel_title = "[color=#4af]🤖 ◈ AI 决策中心[/color]"
	if my_peer_id != -1:
		if battle is OnlineBattleManager:
			var info = battle.player_info.get(my_peer_id)
			if info:
				offset_y = 10 + (info.team * 2 + info.slot) * 340
				panel_title = "[color=#4af]🤖 ◈ AI-%d 决策中心[/color]" % my_peer_id
		else:
			# 单机乱斗：各 AI 的 pid 唯一且随创建递增，按更小 pid 的 AI 数量定纵向行，面板不再叠在左上角
			var ai_row := 0
			for c in battle.get_children():
				if c is AIController and c != self and c.my_peer_id > 0 and c.my_peer_id < my_peer_id:
					ai_row += 1
			offset_y = 10 + ai_row * 340
			panel_title = "[color=#4af]🤖 ◈ AI-%d 决策中心[/color]" % (ai_row + 1)
	debug_panel.position = Vector2(400, offset_y)
	debug_panel.custom_minimum_size = Vector2(PANEL_WIDTH, PANEL_HEIGHT); debug_panel.size = Vector2(PANEL_WIDTH, PANEL_HEIGHT)
	var bg = Panel.new(); bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg_style = StyleBoxFlat.new(); bg_style.bg_color = PANEL_BG_BASE
	bg_style.corner_radius_top_left = 8; bg_style.corner_radius_top_right = 8
	bg_style.corner_radius_bottom_left = 8; bg_style.corner_radius_bottom_right = 8
	bg_style.border_width_left = 2; bg_style.border_width_right = 2
	bg_style.border_width_top = 2; bg_style.border_width_bottom = 2
	bg_style.border_color = Color(0.25, 0.5, 0.8, 0.5)
	_panel_bg_style = bg_style
	bg.add_theme_stylebox_override("panel", bg_style); debug_panel.add_child(bg)
	# 顶部 42px 国家色带：顶部 3px 实色描边 + 14% 淡色底，国家一眼可辨，
	# 但不会像以前那样把整块面板染成深红/深黄，正文仍是中性底。
	var header = Panel.new(); header.name = "NationHeader"
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	debug_panel.add_child(header)
	header.set_anchors_preset(Control.PRESET_TOP_WIDE)
	header.offset_left = 1.0; header.offset_top = 0.0
	header.offset_right = -1.0; header.offset_bottom = 42.0
	var header_style = StyleBoxFlat.new()
	header_style.bg_color = PANEL_BG_BASE
	header_style.corner_radius_top_left = 8; header_style.corner_radius_top_right = 8
	header_style.border_width_top = 3
	_panel_header_style = header_style
	header.add_theme_stylebox_override("panel", header_style)
	_apply_panel_relation()
	var vb = VBoxContainer.new(); vb.position = Vector2(10, 8); vb.add_theme_constant_override("separation", 3)
	# 固定内容宽度：折叠后主体隐藏时 VBox 不能收缩，否则右对齐的折叠按钮会跳到标题旁边
	vb.custom_minimum_size = Vector2(PANEL_WIDTH - 20.0, PANEL_HEIGHT - 16.0)
	vb.size = Vector2(PANEL_WIDTH - 20.0, PANEL_HEIGHT - 16.0)
	debug_panel.add_child(vb)
	# 标题行：左侧标题 + 右侧隐藏按钮（点一下整块收起，只留标题条，不再遮挡战场）
	var title_hbox = HBoxContainer.new(); vb.add_child(title_hbox)
	var title = _make_rtl(); _title_rtl = title; _panel_title_base = panel_title
	title.text = _relation_tag() + panel_title; title.add_theme_font_size_override("font_size", 22)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL; title_hbox.add_child(title)
	_collapse_btn = Button.new(); _collapse_btn.text = "▼"
	_collapse_btn.tooltip_text = "隐藏 AI 决策面板"
	_collapse_btn.toggle_mode = true
	_collapse_btn.custom_minimum_size = Vector2(34, 28)
	UITheme.apply_muted_button(_collapse_btn, UITheme.FONT_MD)
	_collapse_btn.pressed.connect(_on_collapse_pressed)
	title_hbox.add_child(_collapse_btn)
	# 面板主体：放进滚动区，内容超出面板高度时可滚动查看
	_body_scroll = ScrollContainer.new()
	_body_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_body_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_body_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body_scroll.custom_minimum_size = Vector2(PANEL_WIDTH - 20.0, PANEL_HEIGHT - 52.0)
	vb.add_child(_body_scroll)
	var body = VBoxContainer.new(); body.add_theme_constant_override("separation", 3)
	body.custom_minimum_size = Vector2(PANEL_WIDTH - 44.0, 0)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body_scroll.add_child(body); _body_vb = body
	_header_rtl = _make_rtl(); _header_rtl.add_theme_font_size_override("font_size", 19); body.add_child(_header_rtl)
	# 国家特色
	_trait_rtl = _make_rtl(); _trait_rtl.add_theme_font_size_override("font_size", 13); body.add_child(_trait_rtl)
	# 科研进度（仅科研模式显示）：时代、当前研究、已完成科技
	_research_title = _make_section("🔬 科研"); body.add_child(_research_title)
	_research_rtl = _make_rtl(); body.add_child(_research_rtl)
	# 主城血量
	var castle_hbox = HBoxContainer.new()
	_castle_label = Label.new(); _castle_label.add_theme_font_size_override("font_size", 14)
	_castle_label.add_theme_color_override("font_color", Color(UITheme.PARCHMENT))
	castle_hbox.add_child(_castle_label)
	_castle_bar = HealthBarControl.new(); _castle_bar.custom_minimum_size = Vector2(300, 10)
	castle_hbox.add_child(_castle_bar)
	body.add_child(castle_hbox)
	var pop_hbox = HBoxContainer.new()
	_pop_label = Label.new(); _pop_label.add_theme_font_size_override("font_size", 16); _pop_label.add_theme_color_override("font_color", Color.WHITE)
	pop_hbox.add_child(_pop_label)
	_pop_bar = _make_bar(Color.GREEN); _pop_bar.custom_minimum_size = Vector2(370, 10); pop_hbox.add_child(_pop_bar)
	body.add_child(pop_hbox)
	body.add_child(_make_section("💰 资源"))
	var res_grid = GridContainer.new(); res_grid.columns = 5
	var res_cfg = [["金",Color(1.0,0.84,0.1)],["木",Color(0.25,0.82,0.2)],["石",Color(0.62,0.62,0.62)],["食",Color(1.0,0.55,0.1)],["油",Color(0.4,0.25,0.1)]]
	var res_keys = ["gold", "wood", "stone", "food", "oil"]
	for i in range(5):
		var col = VBoxContainer.new()
		var bl = Label.new(); bl.text = UITheme.RESOURCE_ICONS.get(res_keys[i], res_cfg[i][0]); bl.add_theme_font_size_override("font_size", 13); bl.add_theme_color_override("font_color", res_cfg[i][1])
		bl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; col.add_child(bl)
		var br = _make_bar(res_cfg[i][1]); br.custom_minimum_size = Vector2(85, 8); _res_bars.append(br); col.add_child(br)
		var ll = Label.new(); ll.add_theme_font_size_override("font_size", 11); ll.add_theme_color_override("font_color", Color.WHITE)
		ll.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; ll.clip_text = true; ll.custom_minimum_size = Vector2(85, 0)
		_res_labels.append(ll); col.add_child(ll); res_grid.add_child(col)
	body.add_child(res_grid)
	# 经济
	_eco_title = _make_section("💰 经济"); body.add_child(_eco_title); _eco_rtl = _make_rtl(); body.add_child(_eco_rtl)
	# 军队
	_mil_title = _make_section("⚔️ 军队"); body.add_child(_mil_title); _mil_rtl = _make_rtl(); body.add_child(_mil_rtl)
	_bld_title = _make_section("🏰 建筑"); body.add_child(_bld_title); _bld_rtl = _make_rtl(); body.add_child(_bld_rtl)
	var hud = battle.get_node("UI") as CanvasLayer; hud.add_child(debug_panel)
	# 默认折叠为标题条
	set_panel_collapsed(true, false)
	debug_panel.set_meta("expanded_at", 0)
	# 创建后交给管理器统一排布，避免多个面板叠放
	if battle.has_method("layout_ai_debug_panels"):
		battle.call_deferred("layout_ai_debug_panels")
	if not OS.is_debug_build():
		debug_panel.visible = false

# ▼/▲：隐藏或展开面板主体；管理器可在超限时直接调用（relayout=false）
func _on_collapse_pressed():
	set_panel_collapsed(_collapse_btn.button_pressed, true)

func set_panel_collapsed(collapsed: bool, relayout: bool = true):
	if _collapse_btn == null or _body_vb == null or debug_panel == null:
		return
	_panel_collapsed = collapsed
	_collapse_btn.button_pressed = collapsed
	if _body_scroll:
		_body_scroll.visible = not collapsed
	else:
		_body_vb.visible = not collapsed
	_collapse_btn.text = "▲" if collapsed else "▼"
	_collapse_btn.tooltip_text = "展开 AI 决策面板" if collapsed else "隐藏 AI 决策面板"
	var h = PANEL_COLLAPSED_HEIGHT if collapsed else PANEL_HEIGHT
	debug_panel.custom_minimum_size = Vector2(PANEL_WIDTH, h)
	debug_panel.size = Vector2(PANEL_WIDTH, h)
	if not collapsed:
		debug_panel.set_meta("expanded_at", Time.get_ticks_msec())
		# 展开的瞬间就补一次数据，之后由 _process 里的 1 秒计时器稳定刷新。
		# 之前面板内容只在每 30 帧的定时刷新里更新，点开后要等下一次 tick
		# 才能看到第一屏统计，低帧率时尤其像“卡住”。
		_panel_refresh_timer = PANEL_REFRESH_INTERVAL_OPEN
		call_deferred("_refresh_debug_panel_now")
	if relayout and battle and is_instance_valid(battle) and battle.has_method("layout_ai_debug_panels"):
		battle.layout_ai_debug_panels()

# 展开后的首帧刷新：延迟到布局完成再填数据，避免在按钮回调里做整实体扫描。
func _refresh_debug_panel_now() -> void:
	if debug_panel and not _panel_collapsed:
		update_debug_label()

func _make_rtl() -> RichTextLabel:
	var r = RichTextLabel.new(); r.bbcode_enabled = true; r.fit_content = true; r.clip_contents = true
	r.add_theme_font_size_override("font_size", 15); return r

func _make_bar(color: Color) -> ProgressBar:
	var b = ProgressBar.new(); b.max_value = 100; b.show_percentage = false
	var fs = StyleBoxFlat.new(); fs.bg_color = color
	fs.corner_radius_top_left = 2; fs.corner_radius_top_right = 2
	fs.corner_radius_bottom_left = 2; fs.corner_radius_bottom_right = 2
	b.add_theme_stylebox_override("fill", fs)
	var bs = StyleBoxFlat.new(); bs.bg_color = Color(0.08,0.08,0.08,0.9)
	bs.corner_radius_top_left = 2; bs.corner_radius_top_right = 2
	bs.corner_radius_bottom_left = 2; bs.corner_radius_bottom_right = 2
	b.add_theme_stylebox_override("background", bs); return b

func _make_section(title: String) -> RichTextLabel:
	var r = RichTextLabel.new(); r.bbcode_enabled = true; r.fit_content = true
	r.text = "[color=#7cc4ff]▸ %s[/color]" % title; r.add_theme_font_size_override("font_size", 16); return r

func _get_tactic_name(tactic: int) -> String:
	match tactic:
		LateTactic.NONE: return "无"
		LateTactic.HARASS: return "🔥 骚扰"
		LateTactic.OVERWHELM: return "⚔️ 压制"
		LateTactic.RAID: return "⚡ 突袭"
		LateTactic.DEFEND: return "🛡️ 防守"
		_: return "未知"

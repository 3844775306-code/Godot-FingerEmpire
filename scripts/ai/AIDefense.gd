# scripts/ai/AIDefense.gd
# AI 防守与资源控制模块。
#
# 目标：
#   1. 用可见敌军 + 主城掉血 + 资源区受袭共同评估威胁，而不是只看军力总和；
#   2. 防线允许建在主城附近，按“内圈箭塔 → 外墙 → 炮塔”分批建造，被拆后补建；
#   3. 常驻少量守军，威胁升高时逐步回防，危急时召回全部陆战部队；
#   4. 资源区受袭时先让农民短距离躲避，再派 1-3 个机动部队去资源区；远矿点补瞭望塔；
#   5. 防守升级按“威胁方向上的塔优先”逐个升级，不再随机升级所有建筑。
#
# 本模块保持无 class_name，由 AI.gd 通过 preload 加载，避免全局类缓存不同步。
extends RefCounted
const AIClockScript = preload("res://scripts/ai/core/AIClock.gd")
const SimTime = preload("res://scripts/core/SimTime.gd")
const DefenseContextScript = preload("res://scripts/ai/defense/DefenseContext.gd")
const DefenseThreatModelScript = preload("res://scripts/ai/defense/DefenseThreatModel.gd")
const DefenseDirectorScript = preload("res://scripts/ai/defense/DefenseDirector.gd")
const DefensePlanScript = preload("res://scripts/ai/defense/DefensePlan.gd")
const DefenseForceAllocatorScript = preload("res://scripts/ai/defense/DefenseForceAllocator.gd")

const THREAT_RADIUS: float = 15.0
# 威胁的外圈：15~26 米内的可见敌军按低权重计入，避免“敌人已经压到墙下但威胁仍为 0”
const THREAT_OUTER_RADIUS: float = 26.0
const THREAT_INTERVAL: float = 2.5
const PLAN_SHADOW_INTERVAL: float = 1.0
const FORCE_SHADOW_INTERVAL: float = 2.0
const DEFENSE_FRONT: float = 7.2
const DEFENSE_WALL_RADIUS: float = 12.2
# 防线地形搜索：在城堡朝敌方向的前方扇形里找隘口/浅滩，把墙线横在通道上
const DEFENSE_ANCHOR_MIN_DIST: int = 7
const DEFENSE_ANCHOR_MAX_DIST: int = 14
const DEFENSE_ANCHOR_LATERAL: int = 7
const DEFENSE_LANE_MAX_WIDTH: int = 9
# 战略隘口：白垩山脊这类地图的关口离主城可能 30~40 米，
# 不能只按主城门口 7~14 米范围找防线，否则 AI 永远看不到山口的价值。
const CHOKE_MIN_DIST: float = 12.0
const CHOKE_MAX_DIST: float = 48.0
const CHOKE_MIN_WIDTH: int = 2
const CHOKE_MAX_WIDTH: int = 9
const CHOKE_RETRY_INTERVAL: float = 32.0
const DEFENSE_GAP_INTERVAL: float = 25.0
const DEFENSE_BUILD_MAX_PER_TICK: int = 3
# 建造队列检查不必每帧跑：每帧扫几十上百个墙位会把主线程拖慢。
const DEFENSE_BUILD_STEP_INTERVAL: float = 0.25
# 己方视野来源最远 25 米，查可见性时只取附近实体，避免全图扫描。
const DEFENSE_VISION_QUERY_RADIUS: float = 26.0
const DEFENSE_UPGRADE_INTERVAL: float = 9.0
# ── 封闭塔圈 ──
# 在 castle 周围按整数网格找一圈连续的墙：山崖/水面/资源点/已有建筑视为天然墙段，
# 其余可通行格全部补墙，墙心间距 ≤1.41 米（墙直径 2 米），保证敌人钻不过去。
# 己方城墙对己方单位是可通行的（MovementController 只把敌方城墙视为障碍），
# 所以 AI 的农民/军队仍能正常出入，不需要留门。
const RING_MIN_RADIUS: int = 6
# 主城 3/4/5 级（经典）或封建/城堡/帝国时代（科研）最多三层圈，
# 最外层要能包住扩张后的基地，半径上限比旧版单圈更宽。
const RING_MAX_RADIUS: int = 28
# 首圈不能为了包住一个远处的哨站就吃到最大半径，否则后面两级没有扩建空间。
const RING_FIRST_MAX: int = 18
# 单圈墙数上限：外层周长更大，但仍限制在可规划的合理范围内。
const RING_WALL_MAX: int = 160
# 环闭合验收：墙圈上任意 30° 以上的缺口都等于“给敌人留门”，实测有 AI 出现 156° 缺口，
# 结果 BFS 上敌军的进攻路线完全没有被绕开（绕行增量 0%）。规划必须按缺口验收，而不是按墙段数量。
const RING_MAX_GAP_DEG: float = 30.0
const MIN_TOWERS: int = 6
# 判定“这一段墙属于本圈”的径向容差（米）。
const RING_RADIAL_TOL: float = 1.6
const RING_WALL_MIN: int = 8
# 圈规划在 AI 思考帧里同步跑，必须硬限时；否则白垩山脊这种多坡地图
# 一次规划会卡住 1~3 秒。先算最可能的半径，超时就退回“可见的近似圈”。
const RING_PLAN_BUDGET_MS: int = 55
# 进攻类战役关卡的首圈是开局预置的“外围防线”，不能只贴着主城围一圈：
# 至少留出 14 米半径来容纳箭塔/炮塔/墙顶炮台，同时仍在主城视野包络内。
const CAMPAIGN_RING_MIN_RADIUS: int = 14
# 普通对战 AI 的首圈也按“外围要塞”来修，而不是贴着主城围一个刚好包住
# 现有建筑的小圈；否则城墙、箭塔、炮塔、墙顶炮台会挤在一起，看不出层次。
const NORMAL_RING_MIN_RADIUS: int = 14
# 预置防线每圈最多配几座墙顶炮台；实际按墙段数量取 3~6 座。
const CAMPAIGN_WALL_CANNON_MAX: int = 6
# 三层圈的总墙数上限（旧版单圈上限 160 不够扩建圈使用）。
const WALL_BUILD_CAP: int = 420
const GUARD_INTERVAL: float = 60.0
const GUARD_REFILL_INTERVAL: float = 2.0
const RESOURCE_INTERVAL: float = 1.5
const RESOURCE_ZONE_INTERVAL: float = 12.0
const OUTPOST_INTERVAL: float = 24.0
const RESOURCE_GUARD_HOLD: float = 9.0
const DEFENSE_RECALL_SAFE_RADIUS: float = 25.0
const WORKER_FLEE_TIME: float = 9.0
const WORKER_FLEE_RADIUS: float = 8.0
const WORKER_FLEE_DISTANCE: float = 6.0
const FORCE_GUARD_TIME: float = 16.0
# 常驻主城守军数量。低于防守状态时保持 5 人，避免主力出门后家里完全空虚。
const HOME_GUARD_COUNT: int = 5
# 2 秒一次的快速补员只在家门口找兵；远处的空闲野战军由 60 秒一次的完整审计处理，
# 否则刚集结好的部队会被每 2 秒拉走一个，永远出不了门。
const HOME_GUARD_REFILL_RADIUS: float = 35.0
# 友方建筑被攻击时，调动建筑周围这个半径内、没有任务的陆军反击。
# 主城（20）单独放宽到 CASTLE_DEFENSE_RADIUS，用于“回防检查”。
const BUILDING_DEFENSE_RADIUS: float = 15.0
const CASTLE_DEFENSE_RADIUS: float = 35.0
const BUILDING_DEFENSE_MAX: int = 5
const CASTLE_DEFENSE_MAX: int = 8
const BUILDING_DEFENSE_HOLD: float = 15.0
# 建筑掉血检测原来每帧遍历全部实体；后期几百单位 × 多个 AI 会形成固定开销，
# 0.5 秒一次足够发现“正在被打”，响应延迟仍在可接受范围。
const BUILDING_ALERT_INTERVAL: float = 0.5
const CASTLE_ID: int = 20
const MILITARY_BUILDING_IDS: Array = [21, 22, 23, 24, 25, 26, 27, 41, 64]

const SIEGE_IDS: Array = [16, 17, 18, 58, 59]
const ECO_IDS: Array = [10, 14, 43, 44, 45, 51]
const TOWER_IDS: Array = [25, 26]
const OUTPOST_ID: int = 41
# 瞭望塔是纯视野建筑（25 米视野、无攻击）。位置应该按“新增视野”选，
# 而不是围着主城均匀撒一圈；但也要限制总数量，避免吃掉箭塔/炮塔的石头。
const WATCHTOWER_CAP: int = 6
const WATCHTOWER_BASE_MAX: int = 2
const WATCHTOWER_CHAIN_MAX: int = 4
const WATCHTOWER_RESOURCE_MAX: int = 2
const WATCHTOWER_MIN_SEP: float = 7.5
# 视野收益低于这个阈值时不再单独加塔，防止两座塔看到同一片区域。
const WATCHTOWER_GAIN_MIN: float = 18.0
# 计算视野收益时按 2 格采样；100×100 地图上每座候选约 600 个采样点，
# 不会像逐格扫描那样把防线规划拖慢。
const WATCHTOWER_SAMPLE_STEP: int = 2

var ai = null

# ── 新架构第 1 阶段：只读上下文 + 威胁模型 ──
# AIDefense 暂时保留旧公开字段做镜像，后续模块逐步改读 _threat_model.snapshot。
var _defense_context = null
var _threat_model = null
var _last_threat_snapshot: Dictionary = {}
# 第 2 阶段：姿态导演 + 只读计划视图，不参与现有决策。
var _defense_director = null
var _defense_plan = null
var _plan_shadow_timer: float = 0.0
var _force_allocator = null
var _allocator_shadow_timer: float = 0.0

# ── 威胁状态 ──
var threat_level: int = 0             # 0 平静 / 1 警戒 / 2 防守 / 3 危急
var threat_score: float = 0.0
var threat_enemy_count: int = 0
var threat_dir: Vector3 = Vector3.FORWARD
var threat_center: Vector3 = Vector3.ZERO
var _clock = null
var _threat_smoothed: float = 0.0
var _castle_damage_until: float = -999.0
var _last_castle_id: int = -1
var _last_castle_health: float = -1.0

# ── 防线状态 ──
var defense_initialized: bool = false
var _defense_dir: Vector3 = Vector3.FORWARD
var _defense_queue: Array = []        # [{"id","pos","priority","tries"}]
var _defense_slots: Array = []        # [{"id","pos"}]
var wall_positions: Array = []
var tower_positions: Array = []
var _defense_anchor: Dictionary = {}   # 选中的隘口/浅滩防线锚点
var _defense_terrain_text: String = "" # 调试面板显示的地形类型
# 战略隘口防线：优先占住主城与敌军之间的山口，而不是只在主城门口修一圈。
var _choke_planned: bool = false
var _choke_anchor: Dictionary = {}
var _next_choke_try: float = 0.0
# 塔圈状态
var _castle_ring_planned: bool = false
var _castle_ring_radius: int = 0
var _castle_ring_wall_count: int = 0
var _first_ring_wall_start: int = 0
# 已筹备的城墙圈数、各圈半径；圈数由主城等级（经典）或时代（科研）决定。
var _wall_rings_planned: int = 0
var _wall_ring_radii: Array = []
var _wall_ring_target: int = 0
# 战役进攻关开局预置外围墙圈时临时抬高首圈最小半径，结束后恢复 0。
var _campaign_ring_min_radius: int = 0
# 一次圈规划内复用：墙格可建性和山/水/建筑阻挡都不随候选半径变化，
# 每个半径都重算一次会让一次规划卡住好几秒。
var _ring_exact_ok_cache: Dictionary = {}
var _ring_blocked_base_cache: Dictionary = {}
var _next_ring_plan_at: float = 0.0
var _first_ring_planned_at: float = -1.0
var _ring_gap_count: int = 0
var _defense_check_timer: float = 3.0
var _next_layout_try: float = 0.0
var _defense_retry_at: float = 0.0
var _next_build_step: float = 0.0
var _first_ring_priority_cache: bool = false
var _first_ring_priority_cache_at: float = -999.0
var _next_reactive_tower: float = 0.0

# ── 守军状态 ──
var _home_guard_ids: Dictionary = {}
var _force_guard_until: float = -999.0
# 主攻前解除守军后的静默期：期间不再抢人，避免刚放出去又被守军抓回
var _guard_block_until: float = -999.0

# ── 建筑被攻击追踪 ──
var _building_health: Dictionary = {}

# ── 资源区状态 ──
var resource_zones: Array = []        # [{"center","type","workers","nodes","enemy_count"}]
var _next_outpost: float = 0.0
# 记录已经落位的资源区瞭望塔，便于限制每片资源区只建一座。
var watchtower_positions: Array = []
var _resource_guard_ids: Dictionary = {}
var _resource_guard_hold_until: float = -999.0

# A2：只读上下文。读取优先走 AIContext，未绑定时回落到控制器（A3 之后删回落）。
var _ctx = null

func set_context(c) -> void:
	_ctx = c

func _belongs(e) -> bool:
	return _ctx.belongs_to_me(e)

func _count_bld(building_id: int) -> int:
	return _ctx.count_building(building_id)

func _is_enemy_ent(e) -> bool:
	return _ctx.is_enemy(e)

# A3：写操作只经端口（BuildPort/CommandPort），不再直接调控制器。
var _build_port = null
var _cmd_port = null

func set_ports(build_port, cmd_port) -> void:
	_build_port = build_port
	_cmd_port = cmd_port

# A6 收尾：角色常量本地化（数值须与 AI.UnitRole 枚举一致）。
const ROLE_HOME_GUARD: int = 4
const ROLE_RESOURCE_GUARD: int = 5

func _init(owner_ai, ctx = null) -> void:
	ai = owner_ai
	_ctx = ctx
	# P3.3：模块内计时器统一走 AIClock（按帧推进），不再各自维护浮点计时。
	_clock = AIClockScript.new()
	_clock.add("threat", THREAT_INTERVAL)
	_clock.add("building_alert", BUILDING_ALERT_INTERVAL)
	_clock.add("guard_refill", GUARD_REFILL_INTERVAL)
	_clock.add("resource", RESOURCE_INTERVAL)
	_clock.add("guard", GUARD_INTERVAL)
	_clock.add("defense_upgrade", DEFENSE_UPGRADE_INTERVAL, 4.0 / DEFENSE_UPGRADE_INTERVAL)
	_clock.add("zone", RESOURCE_ZONE_INTERVAL)
	_defense_context = DefenseContextScript.new(ai)
	_threat_model = DefenseThreatModelScript.new(_defense_context)
	_defense_director = DefenseDirectorScript.new(_defense_context)
	_defense_plan = DefensePlanScript.new()
	_force_allocator = DefenseForceAllocatorScript.new(_defense_context)

# ═══════════════════════════════════════════════════════════════
# 主入口
# ═══════════════════════════════════════════════════════════════

func tick(delta: float) -> void:
	if ai == null:
		return
	var b = _ctx.battle_ref()
	if b == null or not is_instance_valid(b):
		return
	if b.game_over:
		return
	if _clock != null:
		_clock.advance(delta)
	var castle = _castle()
	if castle == null or not is_instance_valid(castle):
		# 没有主城时不能保留上一场战斗的高威胁分数，否则调试面板会显示“敌军 0 却高度警戒”
		if _threat_model != null:
			_threat_model.reset()
			_last_threat_snapshot = _threat_model.get_snapshot()
		if _defense_plan != null:
			_defense_plan.clear()
		if _force_allocator != null:
			_force_allocator.clear()
		_plan_shadow_timer = 0.0
		_allocator_shadow_timer = 0.0
		threat_level = 0
		threat_score = 0.0
		_threat_smoothed = 0.0
		threat_enemy_count = 0
		return
	if _clock.due("threat"):
		_evaluate_threat(castle)
	# 先检测建筑掉血并给附近空闲部队下反击命令，再调度守军；
	# 被本地防守标记的部队会在守军调度里跳过，避免刚出击就被拉回主城。
	# 检测本身要遍历全部实体，不能每帧跑；0.5 秒一次已经足够及时。
	if _clock.due("building_alert"):
		_detect_building_attacks()
	_manage_defense(castle, delta)
	_update_defense_plan_shadow(castle, delta)
	_update_force_allocator_shadow(castle, delta)
	_manage_home_guard(castle, delta)
	_quick_fill_home_guard(castle, delta)
	_manage_resource_security(castle, delta)
	_manage_defense_upgrades(castle, delta)

func start_defense() -> void:
	var castle = _castle()
	if castle == null:
		return
	_force_guard_until = float(_ctx.game_time()) + FORCE_GUARD_TIME
	_clock.reset("guard", 0.0)
	_ensure_layout(castle)
	_assign_home_guard(castle, true)

# 首圈未建完时给 AI 一个“资源让路”信号：城墙优先于溢出的经济/升级支出。
# 最多持续 180 秒，避免某几段墙因地形永远建不成而让 AI 一直不泄压。
func first_ring_needs_priority() -> bool:
	if not _castle_ring_planned or _castle_ring_wall_count <= 0:
		return false
	if _first_ring_planned_at < 0.0:
		return false
	var now: float = float(_ctx.game_time())
	if now - _first_ring_planned_at > 180.0:
		return false
	# 溢出泄压每帧都会问一次；半秒缓存足够，否则每帧扫首圈几十面墙会把主线程拖住。
	if now - _first_ring_priority_cache_at < 0.5:
		return _first_ring_priority_cache
	_first_ring_priority_cache_at = now
	var alive: int = 0
	var total: int = mini(_castle_ring_wall_count, wall_positions.size() - _first_ring_wall_start)
	for i in range(_first_ring_wall_start, _first_ring_wall_start + total):
		if _pos_has_building(27, wall_positions[i]):
			alive += 1
	_first_ring_priority_cache = alive < total
	return _first_ring_priority_cache

func get_status_text() -> String:
	var names: Array = ["平静", "警戒", "防守", "危急"]
	var idx: int = clampi(threat_level, 0, names.size() - 1)
	var terrain_txt: String = ""
	if _castle_ring_planned:
		terrain_txt = " 城墙圈:%d/%d %d墙%d塔" % [
			_wall_rings_planned, maxi(_wall_ring_target, _wall_rings_planned),
			wall_positions.size(), tower_positions.size()]
	elif not _defense_anchor.is_empty():
		terrain_txt = " 地形:%s" % str(_defense_terrain_text)
	return "威胁:%s(敌%d) 守军:%d 资源卫:%d%s" % [
		names[idx], threat_enemy_count, _home_guard_ids.size(), _resource_guard_ids.size(), terrain_txt,
	]

# ═══════════════════════════════════════════════════════════════
# 威胁评估
# ═══════════════════════════════════════════════════════════════

func _evaluate_threat(castle) -> void:
	# 第 1 阶段：评估逻辑搬到 DefenseThreatModel，本函数只做旧接口镜像。
	# threat_level / threat_score / threat_dir / threat_center 的数值和更新节奏保持不变，
	# 其他模块可以先继续读旧字段；需要扇区/轨迹时调用 get_threat_snapshot()。
	if _threat_model == null:
		return
	_last_threat_snapshot = _threat_model.evaluate(castle)
	threat_level = _threat_model.threat_level
	threat_score = _threat_model.threat_score
	threat_enemy_count = _threat_model.threat_enemy_count
	threat_dir = _threat_model.threat_dir
	threat_center = _threat_model.threat_center
	_threat_smoothed = _threat_model.smoothed
	_castle_damage_until = _threat_model.castle_damage_until
	_last_castle_id = _threat_model.last_castle_id
	_last_castle_health = _threat_model.last_castle_health

# 给调试面板/后续守军分配模块读取的威胁快照（含 tracks 与 8 扇区热度）。
func get_threat_snapshot() -> Dictionary:
	if _threat_model == null:
		return {}
	return _threat_model.get_snapshot()

func get_primary_threat_sector() -> int:
	if _threat_model == null:
		return -1
	return _threat_model.get_primary_sector()

# 第 2 阶段影子刷新：每秒把威胁快照翻译成姿态/预算/只读计划。
# 本函数只读旧状态，不写回 _wall_ring_target、队列或守军。
func _update_defense_plan_shadow(_castle, delta: float) -> void:
	if _defense_director == null or _defense_plan == null:
		return
	_plan_shadow_timer -= delta
	if _plan_shadow_timer > 0.0:
		return
	_plan_shadow_timer = PLAN_SHADOW_INTERVAL
	var snapshot: Dictionary = _last_threat_snapshot
	if snapshot.is_empty():
		snapshot = get_threat_snapshot()
	var now: float = 0.0
	if ai != null and _ctx.battle_ref() != null:
		now = float(_ctx.game_time())
	_defense_director.evaluate(snapshot, _wall_ring_target, now)
	_defense_plan.rebuild(self, _defense_director, snapshot)

func get_defense_plan() -> Dictionary:
	if _defense_plan == null:
		return {}
	return _defense_plan.to_dictionary()

func get_defense_posture() -> int:
	if _defense_director == null:
		return 0
	return int(_defense_director.posture)

func get_defense_budget_reserve() -> float:
	if _defense_director == null:
		return 0.35
	return float(_defense_director.budget_reserve)

func get_defense_director_summary() -> String:
	if _defense_director == null:
		return "-"
	return _defense_director.describe()

# 第 4 阶段影子分配：每 2 秒算一次主城守军建议，不写回任何 meta 或角色账本。
func _update_force_allocator_shadow(castle, delta: float) -> void:
	if _force_allocator == null or _defense_director == null:
		return
	_allocator_shadow_timer -= delta
	if _allocator_shadow_timer > 0.0:
		return
	_allocator_shadow_timer = FORCE_SHADOW_INTERVAL
	var snapshot: Dictionary = _last_threat_snapshot
	if snapshot.is_empty():
		snapshot = get_threat_snapshot()
	_force_allocator.build_plan(castle, _defense_director, self, snapshot)

func get_force_allocation_shadow() -> Dictionary:
	if _force_allocator == null:
		return {}
	return _force_allocator.to_dictionary()

func get_force_allocator_summary() -> String:
	if _force_allocator == null:
		return "-"
	return _force_allocator.describe()

func _enemy_castle_dir(castle) -> Vector3:
	var enemy_team: int = _primary_team()
	var ec = _team_castle(enemy_team)
	if ec == null:
		for e in _ctx.entities_children():
			if e is Building and int(e.entity_id) == 20 and e.health > 0 and _is_enemy_ent(e):
				ec = e
				break
	if ec:
		var d: Vector3 = ec.global_position - castle.global_position
		d.y = 0.0
		if d.length_squared() > 0.01:
			return d.normalized()
	return Vector3.FORWARD

func _is_combat_enemy(e) -> bool:
	if e == null or not is_instance_valid(e) or not (e is Army) or e.health <= 0:
		return false
	# 中立动物/中立单位不是敌军，不能触发防守
	if int(e.team) == RTSConfig.Team.NEUTRAL:
		return false
	if not _is_enemy_ent(e):
		return false
	return int(e.target_type) > 0 or float(e.attack) > 0.0

# ═══════════════════════════════════════════════════════════════
# 防线规划与建造
# ═══════════════════════════════════════════════════════════════

# 玩家要求：经典模式主城 3 级、科研模式进入封建时代后修第一圈城墙，
# 之后主城每升 1 级/每进入一个新时代就再筹备一圈。圈数直接由进度决定：
#   经典：主城 3/4/5 级 -> 1/2/3 圈
#   科研：封建/城堡/帝国 -> 1/2/3 圈
func _required_wall_ring_count(castle) -> int:
	# 第 3 阶段：圈数规则已迁到 DefenseDirector，本函数保留为旧调用点入口。
	if _defense_director == null:
		return 0
	return _defense_director.required_ring_count(castle)

# 还没到 3 级/封建时代时保留旧版前线防守：有威胁或开局 150 秒后仍会布地形防线，
# 避免为了等城墙圈把 AI 前期的防御塔/墙线全部取消。
func _manage_early_defense(castle, delta: float) -> void:
	if int(castle.upgrade_level) < 2:
		if threat_level >= 1 and castle.can_upgrade():
			var up_cost: Dictionary = castle.get_upgrade_cost()
			if not up_cost.is_empty() and _can_spend(up_cost, _defense_reserve()):
				_build_port.upgrade(20)
		return
	if defense_initialized:
		_defense_check_timer -= delta
		if _defense_check_timer <= 0.0:
			_defense_check_timer = DEFENSE_GAP_INTERVAL
			_queue_defense_gaps()
		_build_defense_step()
		_maybe_reactive_tower(castle)
		return
	var now: float = float(_ctx.game_time())
	if now < _next_layout_try:
		return
	if threat_level >= 1 or now >= 150.0:
		if _plan_defense_line(castle):
			defense_initialized = true
			_next_layout_try = now + 5.0
		else:
			_next_layout_try = now + 8.0

func _manage_defense(castle, delta: float) -> void:
	# 先看能不能占住主城与敌军之间的天然山口；这一步与塔圈互不冲突，
	# 山口防线会一直留在建造队列里，后面升级主城再补塔圈。
	_wall_ring_target = _required_wall_ring_count(castle)
	# 单方案制：进入城墙圈路线后不再叠加独立的隘口/前线防线——两套方案各按自己的半径铺墙，
	# 实测墙的平均半径离散 5~7 米、角度覆盖只有 17~38%，等于两条互不连接的墙带。
	if _wall_ring_target <= 0:
		_ensure_chokepoint(castle)
	if _wall_ring_target <= 0:
		_manage_early_defense(castle, delta)
		return
	# 到达触发等级/时代后立即筹备下一圈；规划失败也持续重试，而不是等固定时间。
	var now: float = float(_ctx.game_time())
	if _wall_rings_planned < _wall_ring_target and now >= _next_ring_plan_at:
		if _plan_wall_ring(castle, _wall_rings_planned):
			defense_initialized = true
			_next_ring_plan_at = 0.0
		else:
			_next_ring_plan_at = now + 20.0
	if not defense_initialized:
		return
	_defense_check_timer -= delta
	if _defense_check_timer <= 0.0:
		_defense_check_timer = DEFENSE_GAP_INTERVAL
		_queue_defense_gaps()
	_build_defense_step()
	_ensure_min_towers(castle)
	if _wall_rings_planned >= _wall_ring_target:
		_maybe_reactive_tower(castle)

func _ensure_layout(castle) -> bool:
	if defense_initialized:
		return true
	if _required_wall_ring_count(castle) <= 0:
		return false
	if float(_ctx.game_time()) < _next_layout_try:
		return false
	if _plan_wall_ring(castle, 0):
		defense_initialized = true
		_next_layout_try = float(_ctx.game_time()) + 5.0
		return true
	_next_layout_try = float(_ctx.game_time()) + 8.0
	return false

# 首圈要求尽量把己方基地建筑包进去：取主城周围己方建筑距离的 90 分位（向上取），
# 再预留墙厚/边距作为期望半径；外圈至少比内圈大 3 格，保证逐级向外扩建。
func _wall_ring_desired_radius(castle, ring_index: int) -> int:
	var min_r: int = maxi(RING_MIN_RADIUS, int(ceil(float(castle.body_radius) + 3.0)))
	if ring_index > 0 and _wall_ring_radii.size() >= ring_index:
		min_r = maxi(min_r, int(_wall_ring_radii[ring_index - 1]) + 3)
	var center: Vector3 = castle.global_position
	var outer_min: int = 0
	if ring_index == 0:
		# 战役预置圈用临时最小半径；普通对战用统一的外围首圈半径。
		outer_min = _campaign_ring_min_radius if _campaign_ring_min_radius > 0 \
				else NORMAL_RING_MIN_RADIUS
	var samples: Array = []
	for e in _ctx.entities_children():
		if not (e is Building) or e.health <= 0 or not _belongs(e):
			continue
		# 城墙本身不参与“势力范围”计算，否则外圈会被已规划的内圈墙拖着走。
		if int(e.entity_id) == 27:
			continue
		var d: float = Vector2(e.global_position.x - center.x, e.global_position.z - center.z).length()
		if d > float(RING_MAX_RADIUS) + 8.0:
			continue
		samples.append(d + float(e.body_radius) + 1.8)
	if samples.is_empty():
		return clampi(maxi(min_r, outer_min), RING_MIN_RADIUS,
				RING_FIRST_MAX if ring_index == 0 else RING_MAX_RADIUS)
	samples.sort()
	var idx: int = clampi(int(ceil(float(samples.size() - 1) * 0.9)), 0, samples.size() - 1)
	var desired: int = maxi(min_r, int(ceil(float(samples[idx]))))
	var max_r: int = RING_FIRST_MAX if ring_index == 0 else RING_MAX_RADIUS
	if ring_index == 0:
		desired = maxi(desired, outer_min)
	return clampi(desired, RING_MIN_RADIUS, max_r)

# 规划一圈墙。ring_index=0 是首圈，>0 是逐级扩建的外圈。
# 首圈墙的建造优先级高于塔和其他防线；外圈排在首圈之后。
func _plan_wall_ring(castle, ring_index: int, force_radius: int = 0) -> bool:
	var preferred: int = _wall_ring_desired_radius(castle, ring_index)
	var forced_radius: int = 0
	if ring_index > 0:
		forced_radius = maxi(preferred, int(_wall_ring_radii[ring_index - 1]) + 3)
	if force_radius > 0:
		preferred = force_radius
		forced_radius = force_radius
	var pick: Dictionary = _pick_ring_radius_best(castle, forced_radius, preferred, ring_index == 0 and force_radius <= 0)
	if pick.is_empty():
		return false
	var radius: int = int(pick["radius"])
	var walls_before: int = wall_positions.size()
	var queue_before: int = _defense_queue.size()
	var slots_before: int = _defense_slots.size()
	var threat_ang: float = atan2(_defense_dir.z, _defense_dir.x)
	var wall_pts: Array = pick.get("positions", [])
	var prio_base: float = 4.0 if ring_index == 0 else 30.0 + float(ring_index) * 20.0
	for p in wall_pts:
		var dx: float = p.x - castle.global_position.x
		var dz: float = p.z - castle.global_position.z
		var ang: float = atan2(dz, dx)
		var diff: float = absf(wrapf(ang - threat_ang, -PI, PI))
		# 朝敌方向先建，但首圈整体仍排在其他防线之前。
		var prio: float = prio_base + diff * 2.0
		_direct_add_defense_slot(27, p, prio, "wall")
	var planned: int = wall_positions.size() - walls_before
	var need: int = 6 if ring_index > 0 else maxi(8, int(float(int(pick["walls"])) * 0.55))
	# 数量够了还不够：必须真正闭合。先按缺口补墙，补不上就整圈作废（交给降级半圈）。
	var gap_deg: float = _ring_gap_deg(castle, radius)
	if planned >= need and gap_deg > RING_MAX_GAP_DEG:
		_fill_ring_gaps(castle, radius, prio_base)
		gap_deg = _ring_gap_deg(castle, radius)
		planned = wall_positions.size() - walls_before
	# 注意：这里只用“数量”判定失败。缺口验收只用于诊断和补墙（_fill_ring_gaps），
	# 不直接否决整圈——实测按缺口硬否决会让全部 AI 退化成半圈墙，塔位也随之消失。
	if planned < need:
		# 规划失败不能留下半圈墙位，否则后续补缺口会以为这些墙已经计划好。
		_defense_queue.resize(queue_before)
		_defense_slots.resize(slots_before)
		wall_positions.resize(walls_before)
		# 首选“贴地形闭合环”：从主城做一次有界洪泛，把可达区域的边界整圈砌墙——
		# 天然被河/山/地图边缘挡住的方向不需要墙，其余方向正好封死，闭合成败由洪泛保证，
		# 而不是靠“固定半径圆”去碰地形（实测圆形候选在河岸侧必然留出 200° 以上的缺口）。
		if _plan_terrain_ring(castle, ring_index):
			return true
		# 这一档半径闭合不了时，先把半径往内收再试（更小的圈更容易被地形封住），
		# 而不是直接退化成半圈墙。实测按缺口验收会让多个 AI 直接掉到半圈。
		if force_radius <= 0:
			for rr in [radius - 3, radius - 6, radius + 2]:
				if int(rr) < RING_MIN_RADIUS + 2:
					continue
				if _plan_wall_ring(castle, ring_index, int(rr)):
					return true
		# 最后的降级：朝敌方向的半圈墙 + 2 座箭塔，至少不是完全裸奔。
		if _plan_fallback_wall_arc(castle, ring_index):
			return true
		return false
	_wall_ring_radii.append(radius)
	_wall_rings_planned = ring_index + 1
	if ring_index == 0:
		_plan_ring_towers(castle, radius)
		_first_ring_planned_at = float(_ctx.game_time())
		_castle_ring_planned = true
		_castle_ring_radius = radius
		_first_ring_wall_start = walls_before
		_castle_ring_wall_count = planned
		_ring_gap_count = int(ceil(gap_deg))
		_defense_terrain_text = "塔圈" if not bool(pick.get("open", false)) else "塔圈(待封口)"
	else:
		_defense_terrain_text = "城墙%d圈" % _wall_rings_planned
		if bool(pick.get("open", false)):
			_defense_terrain_text += "(待封口)"
	# 队列按优先级从低到高建；首圈墙排在塔和外圈之前。
	_defense_queue.sort_custom(func(a, b): return float(a["priority"]) < float(b["priority"]))
	return true

# 从主城出发的“有界洪泛”：只走可通行地形，限制在半径 limit 格内，返回可达格集合。
func _flood_region(center: Vector2i, limit: int) -> Dictionary:
	var region: Dictionary = {center: true}
	var queue: Array = [center]
	var head: int = 0
	var lim_sq: int = limit * limit
	while head < queue.size():
		var cur: Vector2i = queue[head]
		head += 1
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = cur + d
			if region.has(n):
				continue
			if (n - center).length_squared() > lim_sq:
				continue
			# 只穿过“平地格”扩张：坡地/浅滩是单位能走的天然隘口，但墙建不上去。
			# 若把它们算进可达区域，边界会贴在坡地/浅滩上导致整圈墙 60% 落不下去（实测可用边界格只有 19/84）。
			if not _terrain_plain_grid(n.x, n.y):
				continue
			region[n] = true
			queue.append(n)
	return region

# 贴地形闭合环：洪泛可达区域的边界就是天然的“围一圈”，沿边界逐格砌墙。
# 相比固定半径圆，它会把墙压在河岸/山脚/地图边缘上，闭合成败不依赖半径候选。
func _plan_terrain_ring(castle, ring_index: int) -> bool:
	var desired: int = _wall_ring_desired_radius(castle, ring_index)
	var max_r: int = clampi(desired, RING_MIN_RADIUS + 2,
			RING_FIRST_MAX if ring_index == 0 else RING_MAX_RADIUS)
	var center: Vector2i = _ctx.world_to_grid(castle.global_position)
	var cpos: Vector3 = castle.global_position
	# 墙是按 1 米一格摆的，一圈要“真的没有缝”就需要 ≈ 周长米数的墙段（半径 18 米要 113 段）。
	# 之前的实现只按预算挑了前 N 个边界格，剩下 60% 的周长是空的，判“闭合”却挡不住人。
	# 所以这里先把半径收到“周长墙数 ≤ 预算”的档位：18 → 14 → 12 → 10。
	var ring_budget: int = mini(RING_WALL_MAX, 96)
	var region: Dictionary = {}
	var pick_r: int = max_r
	for rr in [max_r, 14, 12, 10, 8]:
		if int(rr) > max_r:
			continue
		var reg_try: Dictionary = _flood_region(center, int(rr))
		if reg_try.size() < 24:
			continue
		var edge_n: int = 0
		for key in reg_try.keys():
			var tt: Vector2i = key
			if Vector2(tt.x - center.x, tt.y - center.y).length() < float(RING_MIN_RADIUS):
				continue
			for dd in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				if not reg_try.has(tt + dd):
					edge_n += 1
					break
		if edge_n <= ring_budget:
			region = reg_try
			pick_r = int(rr)
			break
	if region.is_empty():
		return false
	var threat_ang: float = atan2(_defense_dir.z, _defense_dir.x)
	var pieces: Array = []
	var sum_r: float = 0.0
	for key in region.keys():
		var t: Vector2i = key
		var rel := Vector2(t.x - center.x, t.y - center.y)
		var dd: float = rel.length()
		if dd < float(RING_MIN_RADIUS):
			continue
		var edge: bool = false
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			if region.has(t + d):
				continue
			edge = true
			break
		if not edge:
			continue
		var wp: Vector3 = Vector3(float(t.x) - RTSConfig.MAP_SIZE / 2.0 + 0.5, cpos.y,
				float(t.y) - RTSConfig.MAP_SIZE / 2.0 + 0.5)
		var ang: float = atan2(wp.z - cpos.z, wp.x - cpos.x)
		var diff: float = absf(wrapf(ang - threat_ang, -PI, PI))
		pieces.append({"pos": wp, "prio": 1.0 + diff * 2.0})
		sum_r += dd
	if pieces.size() < 16:
		return false
	pieces.sort_custom(func(a, b): return float(a["prio"]) < float(b["prio"]))
	var queue_before: int = _defense_queue.size()
	var slots_before: int = _defense_slots.size()
	var wall_before: int = wall_positions.size()
	# 逐格处理边界：已有建筑/资源点占住的格本来就是障碍，跳过；地形不是平地建不了墙，算缺口；
	# 其余平地格必须落墙，落不下就是“能走人的缺口”。
	var closed_angles: Array = []
	for it in pieces:
		var pos: Vector3 = it["pos"]
		if _cell_obstructed(pos):
			closed_angles.append(atan2(pos.z - cpos.z, pos.x - cpos.x))
			continue
		var gcell: Vector2i = _ctx.world_to_grid(pos)
		if not _terrain_plain_grid(gcell.x, gcell.y):
			continue
		if _add_defense_slot(27, pos, float(it["prio"]), "wall", true, false, false):
			closed_angles.append(atan2(pos.z - cpos.z, pos.x - cpos.x))
	var planned: int = wall_positions.size() - wall_before
	# 物理闭合判据：相邻两个“已封闭点”（墙或天然障碍）之间的角度空档换算成弧长，
	# 超过 1.6 米就说明单位（半径 0.5 米）能挤过去 —— 实测用“洪泛封闭”会漏判，
	# 敌人在 t+11s 就有 8/14 走进了环内。
	closed_angles.sort()
	var max_gap_m: float = 0.0
	if closed_angles.size() >= 2:
		for i in range(closed_angles.size()):
			var a1: float = float(closed_angles[i])
			var a2: float = float(closed_angles[(i + 1) % closed_angles.size()])
			var da: float = a2 - a1
			if i == closed_angles.size() - 1:
				da += TAU
			max_gap_m = maxf(max_gap_m, da * float(desired))
	# 落墙覆盖率：边界格里有 20% 以上没落下墙，说明这一圈半径根本摆不满，直接失败去收缩半径。
	var fill_ratio: float = float(planned) / maxf(float(pieces.size()), 1.0)
	if planned < 12 or fill_ratio < 0.8 or max_gap_m > 1.6 or not _ring_sealed(castle, desired):
		_defense_queue.resize(queue_before)
		_defense_slots.resize(slots_before)
		wall_positions.resize(wall_before)
		return false
	var mean_r: int = maxi(RING_MIN_RADIUS, int(round(sum_r / float(pieces.size()))))
	_wall_ring_radii.append(mean_r)
	_wall_rings_planned = ring_index + 1
	_castle_ring_planned = true
	_castle_ring_radius = mean_r
	_castle_ring_wall_count = planned
	_ring_gap_count = int(ceil(_ring_gap_deg(castle, mean_r)))
	_defense_terrain_text = "地形环%d段(闭)" % planned
	if ring_index == 0:
		_first_ring_planned_at = float(_ctx.game_time())
		_first_ring_wall_start = wall_before
	_plan_ring_towers(castle, mean_r)
	_defense_queue.sort_custom(func(a, b): return float(a["priority"]) < float(b["priority"]))
	return true

# 该格是否已经被建筑/资源点的实体本身占住（这种格不需要砌墙，敌人也过不去）。
func _cell_obstructed(pos: Vector3) -> bool:
	for e in _ctx.entities_children():
		if not is_instance_valid(e) or e.health <= 0:
			continue
		if not (e is Building) and not (e is WorldResource):
			continue
		if e.global_position.distance_to(pos) <= float(e.body_radius) + 0.45:
			return true
	return false

# 从主城洪泛，判断“墙 + 建筑 + 资源点 + 地形”是否真的把主城围死。
# 逃不出去 = 闭合；能走到 radius + 6 格以外 = 有缺口（这个判定直接对应“敌人能不能走进来”）。
func _ring_sealed(castle, radius: int) -> bool:
	var b = _ctx.battle_ref()
	if b == null:
		return false
	var center: Vector2i = b.world_to_grid(castle.global_position)
	var blocked: Dictionary = {}
	for e in b.entities.get_children():
		if not is_instance_valid(e) or e.health <= 0:
			continue
		if e is Building:
			var br: float = float(e.body_radius)
			var cg: Vector2i = b.world_to_grid(e.global_position)
			var span: int = int(ceil(br)) + 1
			for dx in range(-span, span + 1):
				for dz in range(-span, span + 1):
					var gg: Vector2i = cg + Vector2i(dx, dz)
					var gp: Vector3 = Vector3(float(gg.x) - RTSConfig.MAP_SIZE / 2.0 + 0.5, 0.0,
							float(gg.y) - RTSConfig.MAP_SIZE / 2.0 + 0.5)
					if Vector2(gp.x - e.global_position.x, gp.z - e.global_position.z).length() <= br + 0.4:
						blocked[gg] = true
		elif e is WorldResource:
			var rr: float = float(e.body_radius) + 0.3
			var rg: Vector2i = b.world_to_grid(e.global_position)
			var rspan: int = int(ceil(rr)) + 1
			for dx in range(-rspan, rspan + 1):
				for dz in range(-rspan, rspan + 1):
					var gg2: Vector2i = rg + Vector2i(dx, dz)
					var gp2: Vector3 = Vector3(float(gg2.x) - RTSConfig.MAP_SIZE / 2.0 + 0.5, 0.0,
							float(gg2.y) - RTSConfig.MAP_SIZE / 2.0 + 0.5)
					if Vector2(gp2.x - e.global_position.x, gp2.z - e.global_position.z).length() <= rr:
						blocked[gg2] = true
	var escaped: bool = false
	var seen: Dictionary = {center: true}
	var queue: Array = [center]
	var head: int = 0
	var escape_r: int = radius + 6
	while head < queue.size():
		var cur: Vector2i = queue[head]
		head += 1
		if (cur - center).length() > float(escape_r):
			escaped = true
			break
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = cur + d
			if seen.has(n) or blocked.has(n):
				continue
			if not _terrain_passable_grid(n.x, n.y):
				continue
			seen[n] = true
			queue.append(n)
	return not escaped

# 统计某一圈（半径 ring_r ± 容差）上的最大角度缺口（度）。
# 天然屏障（不可通行地形/地图边缘）算作已经封住，不算缺口。
func _ring_gap_deg(castle, ring_r: int) -> float:
	var cpos: Vector3 = castle.global_position
	var bins: PackedByteArray = PackedByteArray()
	bins.resize(180)
	bins.fill(0)
	# 按“弧长覆盖”判定：一段墙（体半径 1 米）在半径 r 上大约封住 ±1.6 米弧长，
	# 用角度分箱直接比相等会把正常间距 1.5 米的墙误判成缺口。
	var arm_tol: float = 1.6 / maxf(float(ring_r), 1.0)
	for p in wall_positions:
		var d: Vector3 = p - cpos
		var rr: float = Vector2(d.x, d.z).length()
		if absf(rr - float(ring_r)) > RING_RADIAL_TOL:
			continue
		var ang: float = atan2(d.z, d.x)
		var span: int = int(ceil(arm_tol / (TAU / 180.0))) + 1
		var bi: int = int(fposmod(ang, TAU) / TAU * 180.0)
		for k in range(-span, span + 1):
			bins[int(fposmod(float(bi + k), 180.0))] = 1
	# 天然屏障方向标记为已封
	for i in range(180):
		if bins[i] == 1:
			continue
		var ang2: float = TAU * float(i) / 180.0
		var px: float = cpos.x + cos(ang2) * float(ring_r)
		var pz: float = cpos.z + sin(ang2) * float(ring_r)
		var g: Vector2i = _ctx.world_to_grid(Vector3(px, 0.0, pz))
		if not _terrain_passable_grid(g.x, g.y):
			bins[i] = 1
	var max_gap: int = 0
	var run: int = 0
	for i in range(180):
		if bins[i] == 1:
			run = 0
		else:
			run += 1
			max_gap = maxi(max_gap, run)
	# 首尾相接的缺口
	var tail: int = 0
	for i in range(179, -1, -1):
		if bins[i] == 1:
			break
		tail += 1
	var head: int = 0
	for i in range(180):
		if bins[i] == 1:
			break
		head += 1
	max_gap = maxi(max_gap, tail + head)
	return float(max_gap) * 2.0

func _terrain_plain_grid(gx: int, gz: int) -> bool:
	if gx < 0 or gz < 0 or gx >= RTSConfig.MAP_SIZE or gz >= RTSConfig.MAP_SIZE:
		return false
	return _ctx.terrain_at_grid(gx, gz) == 0

func _terrain_passable_grid(gx: int, gz: int) -> bool:
	if gx < 0 or gz < 0 or gx >= RTSConfig.MAP_SIZE or gz >= RTSConfig.MAP_SIZE:
		return false
	var t: int = _ctx.terrain_at_grid(gx, gz)
	if t == 2:
		return _ctx.overlay_at_grid(gx, gz) == 3
	if t == 1:
		var ov: int = _ctx.overlay_at_grid(gx, gz)
		return ov == 4 or ov == 5
	return true

# 按 2° 步长在圈上补缺口：只补“可通行且当前无墙”的角度，天然屏障方向跳过。
func _fill_ring_gaps(castle, ring_r: int, prio_base: float) -> void:
	var cpos: Vector3 = castle.global_position
	for i in range(180):
		var ang: float = TAU * float(i) / 180.0
		var px: float = cpos.x + cos(ang) * float(ring_r)
		var pz: float = cpos.z + sin(ang) * float(ring_r)
		var g: Vector2i = _ctx.world_to_grid(Vector3(px, 0.0, pz))
		if not _terrain_passable_grid(g.x, g.y):
			continue
		var covered: bool = false
		var arm_tol: float = 1.6 / maxf(float(ring_r), 1.0)
		for p in wall_positions:
			var d: Vector3 = p - cpos
			var rr: float = Vector2(d.x, d.z).length()
			if absf(rr - float(ring_r)) > RING_RADIAL_TOL:
				continue
			if absf(wrapf(atan2(d.z, d.x) - ang, -PI, PI)) <= arm_tol:
				covered = true
				break
		if covered:
			continue
		var pos: Vector3 = Vector3(px, cpos.y, pz)
		_add_defense_slot(27, pos, prio_base + absf(wrapf(ang - atan2(_defense_dir.z, _defense_dir.x), -PI, PI)) * 2.0,
				"wall", true, false, false)

# 一圈墙的数量预算：按周长算，超了就不再往墙上堆石头（实测有 AI 在“不成环”的墙上堆了 112 段）。
func _ring_wall_budget(castle, ring_r: int) -> int:
	return int(ceil(TAU * float(maxi(ring_r, 6)) / 1.1)) + 8

# 整圈墙闭合不了时的降级方案：只在“朝敌方向”铺一段半圆弧墙，再补 2 座箭塔。
# 半径按档位依次回退，直到能落下至少 8 段墙；落不下就整体回滚并返回 false。
func _plan_fallback_wall_arc(castle, ring_index: int) -> bool:
	var base_r: int = _wall_ring_desired_radius(castle, ring_index)
	var wall_before: int = wall_positions.size()
	var queue_before: int = _defense_queue.size()
	var slots_before: int = _defense_slots.size()
	for r_try in [base_r, base_r - 2, base_r + 2, base_r - 4, 6]:
		var rr: int = int(r_try)
		if rr < RING_MIN_RADIUS:
			continue
		for i in range(19):
			var t: float = float(i) / 18.0
			var wa: float = lerpf(-0.95, 0.95, t)
			var p: Vector3 = castle.global_position + _defense_dir.rotated(Vector3.UP, wa) * float(rr)
			_add_defense_slot(27, p, 2.0 + absf(wa) * 2.0, "wall", true, false, false)
		if wall_positions.size() - wall_before >= 8:
			_wall_ring_radii.append(rr)
			_castle_ring_planned = true
			_castle_ring_radius = rr
			_castle_ring_wall_count = wall_positions.size() - wall_before
			_defense_terrain_text = "半圈墙(降级)%d段" % int(_castle_ring_wall_count)
			# 半圈墙内侧各补一座箭塔，优先级排在墙前面，先立塔再砌墙。
			for side in [-0.5, 0.5]:
				var tp: Vector3 = castle.global_position 					+ _defense_dir.rotated(Vector3.UP, float(side)) * maxf(4.0, float(rr) - 2.5)
				_add_defense_slot(25, tp, 0.45 + absf(float(side)), "tower", true, false, false)
			_wall_rings_planned = ring_index + 1
			_defense_queue.sort_custom(func(a, b): return float(a["priority"]) < float(b["priority"]))
			return true
		_defense_queue.resize(queue_before)
		_defense_slots.resize(slots_before)
		wall_positions.resize(wall_before)
	return false

# 战役进攻关：开局直接把 AI 基地外围的一圈城墙、箭塔、炮塔和墙顶炮台预置好。
# 复用塔圈规划器保证墙线沿地形闭合；这里只把规划结果一次性落成建筑，不扣资源、
# 不等农民施工，避免玩家前 2 分钟就看到一个没有外围工事的敌基地。
func prebuild_campaign_castle_ring(castle, threat_dir: Vector3) -> bool:
	if ai == null or castle == null or not is_instance_valid(castle):
		return false
	if bool(_ctx.meta("campaign_prebuilt_ring", false)):
		return true
	var dir := Vector3(threat_dir.x, 0.0, threat_dir.z)
	if dir.length_squared() < 0.0001:
		dir = Vector3.FORWARD
	_defense_dir = dir.normalized()
	# 部分地图的敌基地贴着河岸/山脚，14 米外墙圈可能无处闭合；依次退到更小的
	# 外围半径重试，避免整张关卡一张城墙都预置不出来。
	var planned_ok: bool = false
	for min_r in [CAMPAIGN_RING_MIN_RADIUS, 12, 10, 8]:
		_clear_campaign_prebuild_plan()
		_campaign_ring_min_radius = int(min_r)
		planned_ok = _plan_wall_ring(castle, 0)
		_campaign_ring_min_radius = 0
		if planned_ok:
			break
	if not planned_ok:
		return false

	var wall_buildings: Array = []
	var failed: Array = []
	for item in _defense_queue:
		var bid: int = int(item.get("id", -1))
		var pos: Vector3 = item.get("pos", Vector3.ZERO)
		var spawned = _build_port.spawn(EntityDatabase.get_config(bid), _ctx.my_team(), pos, 1)
		if spawned == null:
			failed.append(item)
			continue
		if bid == 27:
			wall_buildings.append(spawned)
	# 没落成的墙位保留在队列里，后续 AI 仍可补建；已落成的清掉，避免重复施工。
	_defense_queue = failed
	_spawn_campaign_wall_cannons(castle, wall_buildings)
	defense_initialized = true
	_wall_rings_planned = 1
	_wall_ring_target = 1
	_castle_ring_planned = true
	_castle_ring_radius = int(_wall_ring_radii[0]) if not _wall_ring_radii.is_empty() else 0
	_castle_ring_wall_count = wall_buildings.size()
	# 预置圈不需要再让经济给“首圈施工”让路。
	_first_ring_planned_at = -1.0
	_ctx.set_meta_value("campaign_prebuilt_ring", true)
	return true

# 预置外围防线每次重试前清掉上一轮的墙位/塔位；保留 _defense_dir。
func _clear_campaign_prebuild_plan() -> void:
	_defense_queue.clear()
	_defense_slots.clear()
	wall_positions.clear()
	tower_positions.clear()
	_wall_ring_radii.clear()
	_wall_rings_planned = 0
	_wall_ring_target = 1
	_first_ring_planned_at = -1.0
	_castle_ring_planned = false
	_castle_ring_wall_count = 0
	_castle_ring_radius = 0
	_ring_exact_ok_cache.clear()
	_ring_blocked_base_cache.clear()

# 沿预置墙圈均匀挑 3~6 段放墙顶炮台，保证“箭塔 / 炮台 / 炮塔”三种都有。
func _spawn_campaign_wall_cannons(castle, walls: Array) -> void:
	if castle == null or walls.size() < 3:
		return
	var center: Vector3 = castle.global_position
	walls.sort_custom(func(a, b):
		var aa: float = atan2(a.global_position.z - center.z, a.global_position.x - center.x)
		var ab: float = atan2(b.global_position.z - center.z, b.global_position.x - center.x)
		return aa < ab
	)
	var count: int = mini(CAMPAIGN_WALL_CANNON_MAX,
			maxi(3, int(ceil(float(walls.size()) / 9.0))))
	for i in range(count):
		var idx: int = int(round(float(i) * float(walls.size() - 1)
				/ float(maxi(count - 1, 1))))
		var wall = walls[clampi(idx, 0, walls.size() - 1)]
		if not is_instance_valid(wall) or wall.health <= 0:
			continue
		_build_port.spawn(EntityDatabase.get_config(64), _ctx.my_team(),
				wall.global_position, 1)

# ── 地形防线：在朝敌方向前方寻找隘口/浅滩 ──
func _cell_blocks_land(gx: int, gz: int) -> bool:
	var terrain: int = _ctx.terrain_at_grid(gx, gz)
	if terrain < 0:
		return true
	if terrain == 2 and _ctx.overlay_at_grid(gx, gz) != 3:
		return true
	# 普通山地是天然墙；只有缓坡/台地（is_cliff_tile 返回 false）才算可通行地形。
	return _ctx.is_cliff_tile(gx, gz)

func _is_ford_cell(gx: int, gz: int) -> bool:
	return _ctx.terrain_at_grid(gx, gz) == 2 and _ctx.overlay_at_grid(gx, gz) == 3

# 沿垂直方向测量可通行通道宽度；两侧山/水会很快截断
func _lane_width(pos: Vector3, perp: Vector3, max_steps: int = DEFENSE_LANE_MAX_WIDTH) -> int:
	var left: int = 0
	var right: int = 0
	while left < max_steps:
		var lc: Vector2i = _ctx.world_to_grid(pos - perp * float(left + 1))
		if _cell_blocks_land(lc.x, lc.y):
			break
		left += 1
	while right < max_steps:
		var rc: Vector2i = _ctx.world_to_grid(pos + perp * float(right + 1))
		if _cell_blocks_land(rc.x, rc.y):
			break
		right += 1
	return left + right + 1

func _count_nearby_barriers(pos: Vector3, radius: int = 3) -> int:
	var total: int = 0
	var center: Vector2i = _ctx.world_to_grid(pos)
	for dx in range(-radius, radius + 1):
		for dz in range(-radius, radius + 1):
			if dx == 0 and dz == 0:
				continue
			if _cell_blocks_land(center.x + dx, center.y + dz):
				total += 1
	return total

func _find_ford_near(pos: Vector3, radius: float = 3.5) -> Vector3:
	var center: Vector2i = _ctx.world_to_grid(pos)
	var r: int = int(ceil(radius))
	var best: Vector3 = Vector3.ZERO
	var best_d: float = INF
	for dx in range(-r, r + 1):
		for dz in range(-r, r + 1):
			if not _is_ford_cell(center.x + dx, center.y + dz):
				continue
			var wp: Vector3 = _ctx.grid_to_world(center.x + dx, center.y + dz)
			var d: float = wp.distance_squared_to(pos)
			if d < best_d:
				best_d = d
				best = wp
	return best

func _find_defense_anchor(castle, enemy_dir: Vector3,
		min_dist: int = DEFENSE_ANCHOR_MIN_DIST,
		max_dist: int = DEFENSE_ANCHOR_MAX_DIST,
		lateral_max: int = DEFENSE_ANCHOR_LATERAL) -> Dictionary:
	var forward: Vector3 = enemy_dir
	forward.y = 0.0
	if forward.length_squared() < 0.01:
		return {}
	forward = forward.normalized()
	var perp: Vector3 = forward.cross(Vector3.UP).normalized()
	if perp.length_squared() < 0.01:
		perp = Vector3.RIGHT

	var best: Dictionary = {}
	var best_score: float = -INF
	for dist_i in range(min_dist, max_dist + 1):
		var dist: float = float(dist_i)
		for lateral_i in range(-lateral_max, lateral_max + 1):
			var lateral: float = float(lateral_i)
			var p: Vector3 = castle.global_position + forward * dist + perp * lateral
			if not _is_valid_defense_ground(p, 1.0, true):
				continue
			var to_p: Vector3 = p - castle.global_position
			to_p.y = 0.0
			if to_p.length_squared() < 0.01:
				continue
			var align: float = to_p.normalized().dot(forward)
			if align < 0.35:
				continue
			var width: int = _lane_width(p, perp)
			if width < 2 or width > DEFENSE_LANE_MAX_WIDTH:
				continue
			var barriers: int = _count_nearby_barriers(p, 3)
			var ford: Vector3 = _find_ford_near(p, 3.5)
			var is_ford: bool = ford != Vector3.ZERO
			if barriers < 2 and not is_ford:
				continue
			# 浅滩防线必须落在己方一侧，不能跑到河对岸去
			if is_ford:
				var ford_depth: float = (ford - castle.global_position).dot(forward)
				var p_depth: float = to_p.dot(forward)
				if p_depth > ford_depth + 1.0:
					continue
			# 通道太宽不算隘口；5 格左右最理想，过窄可能是城墙/资源夹出的假通道
			var width_score: float = 5.0 - absf(float(width) - 5.0) * 1.25
			var center_bonus: float = 1.0 - absf(lateral) / float(lateral_max + 1)
			var score: float = width_score * 2.0 + float(barriers) * 0.45 + center_bonus * 3.0 + align * 5.0
			score -= absf(dist - 10.0) * 0.22
			if is_ford:
				score += 14.0
			if score > best_score:
				best_score = score
				var pdir: Vector3 = to_p.normalized()
				best = {
					"pos": p,
					"dir": pdir,
					"perp": pdir.cross(Vector3.UP).normalized(),
					"dist": dist,
					"width": float(width),
					"kind": "ford" if is_ford else "choke",
				}
	return best

# ═══════════════════════════════════════════════════════════════
# 战略隘口：在白垩山脊这类“山脊横贯、只有几处山口”的地图上，
# 主动把墙线横在己方与敌军之间的山口上，而不是等敌人冲到主城门口。
# ═══════════════════════════════════════════════════════════════

func _fort_tech_ready(castle) -> bool:
	if _ctx.is_research_mode():
		var st: Dictionary = _ctx.research_state(_ctx.my_peer_id(), _ctx.my_team())
		return int(st.get("age", 0)) >= 1
	return int(castle.upgrade_level) >= 2

func _enemy_dir_for_pass(castle) -> Vector3:
	var enemy_team: int = _primary_team()
	var ec = _team_castle(enemy_team)
	if ec != null and is_instance_valid(ec):
		var d: Vector3 = ec.global_position - castle.global_position
		d.y = 0.0
		if d.length_squared() > 1.0:
			return d.normalized()
	return _enemy_castle_dir(castle)

# 地图生成器会把“隘口中心”记在 Map 节点的 _pass_centers 里；
# 优先用这些真实地图数据，找不到时再退回地形扇形搜索。
func _map_pass_centers() -> Array:
	var map = _ctx.battle_node("Map")
	if map == null:
		return []
	var raw = map.get("_pass_centers")
	if raw is Array:
		return raw.duplicate()
	return []

# 山口墙线单段：只在通道横向左右微调，不沿通道大幅前后跳，
# 否则同一条墙会被资源挤成前后错开的两截，看起来像断墙。
func _find_pass_line_spot(base: Vector3, perp: Vector3, lateral: float) -> Vector3:
	for dd in [0.0, 0.6, -0.6, 1.2, -1.2]:
		var p: Vector3 = base + perp * lateral + _defense_dir * float(dd)
		if not _is_valid_defense_ground(p, 1.0, true, false, false, true):
			continue
		# 直接用 AI 的实际建造校验，避免规划通过、建造时因为坡度/资源重叠反复失败。
		if not _build_port.can_place(27, p):
			continue
		if _defense_slot_clear(p, 1.0, 27):
			return p
	return Vector3.ZERO

# 统计某个候选墙线位置上能放下几段墙，不写入建造队列。
func _count_clear_wall_spots(base: Vector3, dir: Vector3, perp: Vector3, width: int) -> int:
	var half: float = maxf(3.0, float(width) * 0.5 + 3.0)
	var clear: int = 0
	var lateral: float = -half
	while lateral <= half + 0.01:
		for dd in [0.0, 0.6, -0.6, 1.2, -1.2]:
			var p: Vector3 = base + perp * lateral + dir * float(dd)
			if not _is_valid_defense_ground(p, 1.0, true, false, false, true):
				continue
			if not _build_port.can_place(27, p):
				continue
			if _defense_slot_clear(p, 1.0, 27):
				clear += 1
				break
		lateral += 1.5
	return clear

func _find_pass_anchor_spot(pass_pos: Vector3, dir: Vector3, perp: Vector3) -> Vector3:
	# 白垩山脊的隘口中心通常被金矿/石矿占满，沿通道往己方一侧多退几米，
	# 直到退出资源占地；墙线仍然横在同一个 4 格宽的山口里。
	# 多个候选里选“能放下最多完整墙段”的位置，而不是第一个勉强可站人的点。
	var first_valid: Vector3 = Vector3.ZERO
	var best_pos: Vector3 = Vector3.ZERO
	var best_clear: int = -1
	for forward_off in [0.0, -1.8, -3.6, -5.4, -7.2, -9.0, -12.0, -15.0, -18.0, 1.8, 3.6]:
		for lateral_off in [0.0, 1.2, -1.2, 2.4, -2.4]:
			var cand: Vector3 = pass_pos + dir * float(forward_off) + perp * float(lateral_off)
			# 山口可能在 30 米外、当前没有视野；先规划，瞭望塔链会先把视野铺过去。
			# 锚点本身只要求可通行；真正的墙位/塔位再检查平整度。
			if not _is_valid_defense_ground(cand, 1.0, true, false, false):
				continue
			var w: int = _lane_width(cand, perp)
			if w < CHOKE_MIN_WIDTH or w > CHOKE_MAX_WIDTH:
				continue
			if first_valid == Vector3.ZERO:
				first_valid = cand
			var clear: int = _count_clear_wall_spots(cand - dir * 0.8, dir, perp, w)
			if clear > best_clear:
				best_clear = clear
				best_pos = cand
			if best_clear >= 4:
				return best_pos
	if best_clear >= 3:
		return best_pos
	return first_valid

func _find_pass_anchor(castle) -> Dictionary:
	var base: Vector3 = castle.global_position
	var enemy_dir: Vector3 = _enemy_dir_for_pass(castle)
	enemy_dir.y = 0.0
	if enemy_dir.length_squared() < 0.01:
		return {}
	enemy_dir = enemy_dir.normalized()
	var pass_centers: Array = _map_pass_centers()
	if pass_centers.is_empty():
		# 没有“隘口”地图数据的地图仍由原来的近主城防线/工事逻辑处理，
		# 避免在经典大陆的普通狭窄地形上误判成战略山口。
		return {}
	var best: Dictionary = {}
	var best_score: float = -INF
	var seen: Dictionary = {}
	for pc in pass_centers:
		if not (pc is Vector2i):
			continue
		# 平台台地/峡谷地图可能把同一处隘口记多次，6 格内去重。
		var key := Vector2i(pc.x / 6, pc.y / 6)
		if seen.has(key):
			continue
		seen[key] = true
		var p: Vector3 = _ctx.grid_to_world(pc.x, pc.y)
		p.y = _ctx.height_at_grid(pc.x, pc.y)
		var delta: Vector3 = p - base
		delta.y = 0.0
		var dist: float = delta.length()
		if dist < CHOKE_MIN_DIST or dist > CHOKE_MAX_DIST:
			continue
		var align: float = delta.normalized().dot(enemy_dir)
		# 只占主城与敌人之间的山口；敌人背后的山口没有防守价值。
		if align < 0.15:
			continue
		var perp: Vector3 = Vector3(-delta.z, 0.0, delta.x).normalized()
		var anchor_pos: Vector3 = _find_pass_anchor_spot(p, delta.normalized(), perp)
		if anchor_pos == Vector3.ZERO:
			continue
		var width: int = _lane_width(anchor_pos, perp)
		if width < CHOKE_MIN_WIDTH or width > CHOKE_MAX_WIDTH:
			continue
		var barriers: int = _count_nearby_barriers(anchor_pos, 3)
		if barriers < 2:
			continue
		# 山口再战略，落不下墙也没用；把“该山口能放几段墙”直接算进评分。
		var wall_info: Dictionary = _find_pass_wall_base(anchor_pos, delta.normalized(), perp)
		var wall_clear: int = int(wall_info.get("clear", 0))
		delta = anchor_pos - base
		delta.y = 0.0
		var lateral: float = absf(delta.x * enemy_dir.z - delta.z * enemy_dir.x)
		var score: float = align * 30.0 - absf(float(width) - 4.0) * 1.5 \
				- lateral * 0.55 - absf(dist - 28.0) * 0.2 + float(barriers) * 0.6 \
				+ float(wall_clear) * 2.5
		if score > best_score:
			best_score = score
			best = {
				"pos": anchor_pos,
				"dir": delta.normalized(),
				"perp": perp,
				"dist": delta.length(),
				"width": float(width),
				"kind": "pass",
			}
	return best

func _ensure_chokepoint(castle) -> bool:
	if _choke_planned:
		return true
	if not _fort_tech_ready(castle):
		return false
	var now: float = float(_ctx.game_time())
	if now < _next_choke_try:
		return false
	_next_choke_try = now + CHOKE_RETRY_INTERVAL
	var anchor: Dictionary = _find_pass_anchor(castle)
	if anchor.is_empty():
		return false
	var old_dir: Vector3 = _defense_dir
	_defense_dir = anchor["dir"]
	var queue_before: int = _defense_queue.size()
	var slots_before: int = _defense_slots.size()
	var walls_before: int = wall_positions.size()
	var towers_before: int = tower_positions.size()
	var walls: int = _plan_anchor_defense(castle, anchor, 8.0, true)
	var towers_added: int = tower_positions.size() - towers_before
	# 窄口两段墙（每段直径 2 米）就能封死；4~5 格宽至少 3 段。
	# 资源点本身也是天然障碍，墙段只需要补住可通行缝隙。
	# 山口地形经常只剩塔位没有整段平地：先保证瞭望塔链/箭塔占住山口，
	# 能落几段墙就落几段；完全没有墙位时也不放弃整个战略点。
	var min_walls: int = 0 if towers_added >= 2 else 2

	if walls < min_walls or towers_added < 1:
		_defense_queue.resize(queue_before)
		_defense_slots.resize(slots_before)
		wall_positions.resize(walls_before)
		tower_positions.resize(towers_before)
		_defense_dir = old_dir
		return false
	_choke_planned = true
	_choke_anchor = anchor
	_defense_anchor = anchor
	_defense_terrain_text = "隘口"
	defense_initialized = true
	_next_layout_try = now + 5.0
	return true

func _find_anchor_spot(center: Vector3, b_id: int, search: float,
		require_vision: bool = true, require_flat: bool = false) -> Vector3:
	var cfg: Dictionary = EntityDatabase.get_config(b_id)
	if cfg.is_empty():
		return Vector3.ZERO
	var radius: float = float(cfg.get("body_radius", 1.0))
	for r in [0.0, search * 0.5, search, search * 1.5]:
		for i in range(8):
			var a: float = TAU * float(i) / 8.0
			var p: Vector3 = center + Vector3(cos(a) * float(r), 0.0, sin(a) * float(r))
			if not _is_valid_defense_ground(p, radius, true, false, require_vision, require_flat):
				continue
			if not _defense_slot_clear(p, radius, b_id):
				continue
			return p
	return Vector3.ZERO

func _find_defense_line_spot(base: Vector3, perp: Vector3, lateral: float,
		b_id: int, max_off: float, require_vision: bool = true,
		require_flat: bool = false) -> Vector3:
	var cfg: Dictionary = EntityDatabase.get_config(b_id)
	if cfg.is_empty():
		return Vector3.ZERO
	var radius: float = float(cfg.get("body_radius", 1.0))
	for dl in [0.0, 0.6, -0.6, 1.2, -1.2]:
		for dd in [0.0, 0.8, -0.8, 1.6, -1.6, 2.4, -2.4, 3.6, -3.6, max_off, -max_off]:
			var p: Vector3 = base + perp * (lateral + float(dl)) + _defense_dir * float(dd)
			if not _is_valid_defense_ground(p, radius, true, false, require_vision, require_flat):
				continue
			if not _defense_slot_clear(p, radius, b_id):
				continue
			return p
	return Vector3.ZERO

# 山口中心经常被金矿占住，把整条墙线沿通道往己方一侧后退，
# 在能放下最多墙段的横向位置落墙；宽度仍按该位置的实际通道宽。
func _find_pass_wall_base(anchor_pos: Vector3, dir: Vector3, perp: Vector3) -> Dictionary:
	var best: Dictionary = {}
	var best_clear: int = -1
	# 除了沿通道前后退，还要左右平移整条墙线：金矿经常压在通道正中，
	# 墙线整体偏半格就能从资源缝里落下去。
	for off in [0.0, 2.0, 4.0, 6.0, 8.0, 10.0, 12.0, 14.0, 16.0, 18.0, 20.0]:
		for lateral_off in [0.0, -1.5, 1.5, -3.0, 3.0, -4.5, 4.5]:
			var base: Vector3 = anchor_pos - dir * (0.8 + float(off)) + perp * float(lateral_off)
			var w: int = _lane_width(base, perp)
			if w < CHOKE_MIN_WIDTH or w > CHOKE_MAX_WIDTH:
				continue
			var clear: int = _count_clear_wall_spots(base, dir, perp, w)
			if clear > best_clear:
				best_clear = clear
				best = {"base": base, "width": float(w), "clear": clear}
			if best_clear >= 4:
				break
		if best_clear >= 4:
			break
	return best

# 在隘口/浅滩两侧布置箭塔，并把墙线横向排开；返回实际可用的墙段数。
# priority_base < 10 时用于“主动守山口”，塔/墙会比普通主城防线更早开工；
# vision_chain 会在城堡到山口的路上铺瞭望塔，保证 30 米外的墙不会因无视野被拒绝。
func _plan_anchor_defense(castle, anchor: Dictionary,
		priority_base: float = 20.0, vision_chain: bool = false) -> int:
	var dir: Vector3 = anchor["dir"]
	var perp: Vector3 = anchor["perp"]
	if perp.length_squared() < 0.01:
		perp = dir.cross(Vector3.UP).normalized()
	var anchor_pos: Vector3 = anchor["pos"]
	var wall_base: Vector3 = anchor_pos - dir * 0.8
	var wall_width: float = float(anchor["width"])
	if vision_chain:
		var wall_info: Dictionary = _find_pass_wall_base(anchor_pos, dir, perp)
		if not wall_info.is_empty():
			wall_base = wall_info["base"]
			wall_width = float(wall_info["width"])
	# 3~4 格宽的山口不能把塔放到山壁上；塔位收进通道内侧，
	# 大范围防线仍用原来的半宽。
	var half_width: float = clampf(wall_width * 0.35, 1.2, 3.0) if vision_chain \
			else maxf(2.2, wall_width * 0.5)
	var vision_prio: float = 2.0 if priority_base < 10.0 else 9.0
	var arrow_prio: float = 6.0 if priority_base < 10.0 else 12.0
	var cannon_prio: float = 7.0 if priority_base < 10.0 else 15.0

	# 锚点较远时先在城堡到山口的路上补瞭望塔，保证后续墙/塔能落在己方视野内。
	# 具体位置按视野收益选，不能沿直线固定每 8 米硬塞一座。
	if vision_chain:
		_plan_chain_watchtowers(castle, wall_base, dir, vision_prio)
	elif float(anchor["dist"]) > 10.0:
		var vision_pos2: Vector3 = castle.global_position + dir * 8.0
		var vision_spot2: Vector3 = _find_anchor_spot(vision_pos2, 25, 1.5)
		if vision_spot2 != Vector3.ZERO:
			_add_defense_slot(25, vision_spot2, vision_prio, "tower")

	# 山口塔位要退到墙后 4.5 米，否则规划塔时会把墙位挤掉，
	# 最后只剩塔没有墙（塔和墙的规划最小间距是 2.8 米）。
	var tower_base: Vector3 = wall_base - dir * (4.5 if vision_chain else 1.0)
	var require_tower_vision: bool = not vision_chain
	if vision_chain:
		# 山口正中先补一座箭塔，保证不是只有瞭望塔没有火力；
		# 资源/坡度把它挤开时再试两侧。
		var center_tower: Vector3 = wall_base - dir * 4.2
		var center_spot: Vector3 = _find_anchor_spot(center_tower, 25, 4.0, false, true)
		if center_spot != Vector3.ZERO:
			_add_defense_slot(25, center_spot, arrow_prio, "tower", false, false, true)
	for side in [-1.0, 1.0]:
		if _count_planned(25) >= 7:
			break
		var tower_pos: Vector3 = tower_base + perp * side * half_width
		var tower_spot: Vector3 = _find_anchor_spot(tower_pos, 25, 2.2,
				require_tower_vision, vision_chain)
		if tower_spot != Vector3.ZERO:
			_add_defense_slot(25, tower_spot, arrow_prio + absf(float(side)) * 0.5, "tower",
					false, require_tower_vision, vision_chain)

	if _count_planned(26) < 3:
		var cannon_pos: Vector3 = tower_base - dir * 1.2
		var cannon_spot: Vector3 = _find_anchor_spot(cannon_pos, 26, 2.0,
				require_tower_vision, vision_chain)
		if cannon_spot != Vector3.ZERO:
			_add_defense_slot(26, cannon_spot, cannon_prio, "tower",
					false, require_tower_vision, vision_chain)

	# 城墙半径 1.0（直径 2.0）：中心距必须 < 2.0 才能首尾重叠，
	# 旧值 2.0 只是刚好相切，任何一段被微调/漏建就会露出能钻人的缝。
	var spacing: float = 1.5
	var walls: int = 0
	if vision_chain:
		# 山口：横向扫一整排墙位，资源/山壁占住的格子自然跳过；
		# 资源点本身也是不可通行的天然障碍，墙段和资源一起封口。
		var half: float = maxf(3.0, wall_width * 0.5 + 3.0)
		var lateral: float = -half
		while lateral <= half + 0.01 and walls < 16:
			var wall_spot: Vector3 = _find_pass_line_spot(wall_base, perp, lateral)
			if wall_spot != Vector3.ZERO:
				if _add_defense_slot(27, wall_spot, priority_base + absf(lateral) * 0.35,
						"wall", false, false, true):
					walls += 1
			lateral += spacing
	else:
		# 普通主城防线至少 6 段；宽一点的正面才需要更多。
		var wall_count: int = clampi(int(ceil(wall_width / spacing)) + 1, 6, 16)
		for i in range(wall_count):
			var lateral2: float = (float(i) - float(wall_count - 1) * 0.5) * spacing
			var wall_spot2: Vector3 = _find_defense_line_spot(wall_base, perp, lateral2, 27, 1.6)
			if wall_spot2 != Vector3.ZERO:
				if _add_defense_slot(27, wall_spot2, priority_base + absf(lateral2) * 0.35,
						"wall"):
					walls += 1
	return walls

# ═══════════════════════════════════════════════════════════════
# 封闭塔圈：把主城用一圈连续城墙包住
# ═══════════════════════════════════════════════════════════════

# 生成一圈 8 连通的外环格子。按圆采样后用 Bresenham 把采样点之间补齐，
# 确保相邻墙格中心距 ≤√2，不会因为圆采样跳格而留下可通行的缝。
func _ring_cells(center: Vector2i, radius: int) -> Array:
	var out: Array = []
	var steps: int = maxi(36, int(ceil(TAU * float(radius) * 2.4)))
	var prev := Vector2i(-9999, -9999)
	for i in range(steps):
		var a: float = TAU * float(i) / float(steps)
		var cell := Vector2i(
			center.x + int(round(cos(a) * float(radius))),
			center.y + int(round(sin(a) * float(radius)))
		)
		if i == 0:
			out.append(cell)
		else:
			_append_ring_line(out, prev, cell)
		prev = cell
	if out.size() > 1:
		_append_ring_line(out, prev, out[0])
	# 去重同时保持环顺序
	var seen: Dictionary = {}
	var unique: Array = []
	for c in out:
		if not seen.has(c):
			seen[c] = true
			unique.append(c)
	return unique

func _append_ring_line(out: Array, from: Vector2i, to: Vector2i) -> void:
	var x0: int = from.x
	var y0: int = from.y
	var x1: int = to.x
	var y1: int = to.y
	var dx: int = absi(x1 - x0)
	var sx: int = 1 if x0 < x1 else -1
	var dy: int = -absi(y1 - y0)
	var sy: int = 1 if y0 < y1 else -1
	var err: int = dx + dy
	while true:
		var cell := Vector2i(x0, y0)
		if out.is_empty() or out[out.size() - 1] != cell:
			out.append(cell)
		if x0 == x1 and y0 == y1:
			break
		var e2: int = err * 2
		if e2 >= dy:
			err += dy
			x0 += sx
		if e2 <= dx:
			err += dx
			y0 += sy

# 该环格是否已被天然地形/现有建筑/资源点堵死（无需再补墙）；
# 间距按墙真实可建造间距预留，建筑本身就可以充当一段墙。
func _ring_cell_blocked(cell: Vector2i) -> bool:
	# 地图最外圈不能放墙（_ring_exact_wall_ok 也要求 >=1），把它当作天然边界，
	# 墙段终点落在边界内侧一格，和地图边界一起封口。
	if cell.x <= 0 or cell.y <= 0 or cell.x >= RTSConfig.MAP_SIZE - 1 or cell.y >= RTSConfig.MAP_SIZE - 1:
		return true
	if _cell_blocks_land(cell.x, cell.y):
		return true
	var wp: Vector3 = _ctx.grid_to_world(cell.x, cell.y)
	wp.y = _ctx.height_at_grid(cell.x, cell.y)
	var nearby: Array = []
	if _ctx.battle_has_method("get_nearby_entities"):
		nearby = _ctx.nearby_entities(wp, 3.2)
	else:
		nearby = _ctx.entities_children()
	for e in nearby:
		if not (e is Building or e is WorldResource) or e.health <= 0:
			continue
		var dx: float = e.global_position.x - wp.x
		var dz: float = e.global_position.z - wp.z
		if sqrt(dx * dx + dz * dz) < float(e.body_radius) + 1.15:
			return true
	return false

# 环格上能否放一面墙（不把会移动的军队算作障碍，敌人靠近时先规划、建造时再重试）
func _ring_wall_spot(cell: Vector2i, nearby: Array = []) -> Vector3:
	var base: Vector3 = _ctx.grid_to_world(cell.x, cell.y)
	if nearby.is_empty() and _ctx.battle_has_method("get_nearby_entities"):
		nearby = _ctx.nearby_entities(base, 6.0)
	# 环格中心不平时在 2.5 米内找最近的平地墙位；海边/山脚的环线本来就该顺着可建地形微调。
	var offsets: Array = [Vector3.ZERO]
	for dist in [0.6, 1.1, 1.5, 2.0, 2.5]:
		for k in range(8):
			var a: float = TAU * float(k) / 8.0
			offsets.append(Vector3(cos(a) * float(dist), 0.0, sin(a) * float(dist)))
	for off in offsets:
		var wp: Vector3 = base + off
		var gx: int = int(round(wp.x + RTSConfig.MAP_SIZE / 2.0))
		var gz: int = int(round(wp.z + RTSConfig.MAP_SIZE / 2.0))
		if gx < 1 or gz < 1 or gx >= RTSConfig.MAP_SIZE - 1 or gz >= RTSConfig.MAP_SIZE - 1:
			continue
		if _ctx.terrain_at_grid(gx, gz) != 0:
			continue
		if _ctx.battle_has_method("_is_terrain_flat") and not _ctx.is_terrain_flat(wp, 0.45):
			continue
		var blocked: bool = false
		for e in nearby:
			if not (e is Building or e is WorldResource) or e.health <= 0:
				continue
			var dx: float = e.global_position.x - wp.x
			var dz: float = e.global_position.z - wp.z
			if sqrt(dx * dx + dz * dz) < float(e.body_radius) + 1.2:
				blocked = true
				break
		if blocked:
			continue
		if not _defense_slot_clear(wp, 1.0, 27):
			continue
		return wp
	return Vector3.ZERO

# 环格中心本身能否直接放墙：A* 只走这些格子，保证墙格 8 连通。
func _ring_exact_wall_ok(cell: Vector2i, cache: Dictionary = {}) -> bool:
	if cache.has(cell):
		return bool(cache[cell])
	if _ring_exact_ok_cache.has(cell):
		var cached: bool = bool(_ring_exact_ok_cache[cell])
		cache[cell] = cached
		return cached
	var ok: bool = true
	var wp: Vector3 = _ctx.grid_to_world(cell.x, cell.y)
	if cell.x < 1 or cell.y < 1 or cell.x >= RTSConfig.MAP_SIZE - 1 or cell.y >= RTSConfig.MAP_SIZE - 1:
		ok = false
	elif _cell_blocks_land(cell.x, cell.y) or _is_ford_cell(cell.x, cell.y):
		ok = false
	elif _ctx.terrain_at_grid(cell.x, cell.y) != 0:
		ok = false
	elif _ctx.battle_has_method("_is_terrain_flat") and not _ctx.is_terrain_flat(wp, 0.45):
		ok = false
	else:
		var nearby: Array = []
		if _ctx.battle_has_method("get_nearby_entities"):
			nearby = _ctx.nearby_entities(wp, 4.0)
		else:
			nearby = _ctx.entities_children()
		for e in nearby:
			if not (e is Building or e is WorldResource) or e.health <= 0:
				continue
			var dx: float = e.global_position.x - wp.x
			var dz: float = e.global_position.z - wp.z
			if sqrt(dx * dx + dz * dz) < float(e.body_radius) + 1.2:
				ok = false
				break
	cache[cell] = ok
	_ring_exact_ok_cache[cell] = ok
	return ok

# 在两个天然屏障格之间用 A* 找一段连续墙格；只允许“能放墙的格”和“天然屏障格”，
# 这样墙段能绕开陡坡/浅滩，且两端一定接到山水/建筑上，不会留缝。
func _ring_connect_a_star(start: Vector2i, goal: Vector2i, center: Vector2i, radius: int) -> Dictionary:
	if start == goal:
		return {"ok": true, "cells": []}
	var sz: int = RTSConfig.MAP_SIZE
	# 墙线不必是标准圆：允许在环内外各 4 格范围内绕开建筑/陡坡，
	# 只要最终仍把主城包住，形状可以是不规则的。
	var lo: int = maxi(3, radius - 4)
	var hi: int = radius + 4
	var exact_cache: Dictionary = {}
	var g: Dictionary = {start: 0.0}
	var parent: Dictionary = {}
	var open: Array = [start]
	var closed: Dictionary = {}
	var dirs: Array = [
		Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
		Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
	]
	while not open.is_empty():
		var bi: int = 0
		var bf: float = INF
		for i in range(open.size()):
			var c: Vector2i = open[i]
			var f: float = float(g.get(c, INF)) + Vector2(c - goal).length()
			if f < bf:
				bf = f
				bi = i
		var cur: Vector2i = open[bi]
		open.remove_at(bi)
		if closed.has(cur):
			continue
		if cur == goal:
			var path: Array = []
			var node: Vector2i = cur
			while parent.has(node):
				path.append(node)
				node = parent[node]
			path.append(start)
			path.reverse()
			return {"ok": true, "cells": path}
		closed[cur] = true
		for d in dirs:
			var n: Vector2i = cur + d
			if n.x < 0 or n.y < 0 or n.x >= sz or n.y >= sz:
				continue
			if closed.has(n):
				continue
			var dx: int = n.x - center.x
			var dz: int = n.y - center.y
			var dist2: int = dx * dx + dz * dz
			if dist2 < lo * lo or dist2 > hi * hi:
				continue
			# 中间只允许走“能直接放墙”的格子；天然屏障只作为每段墙的起点/终点锚点。
			# 若允许 A* 穿过建筑/山体，它会抄近路把多段墙连到主城内部，圈反而包不住主城。
			var is_wall: bool = _ring_exact_wall_ok(n, exact_cache)
			if not is_wall and n != goal:
				continue
			var step: float = 1.0
			step += absf(sqrt(float(dist2)) - float(radius)) * 0.22
			var ng: float = float(g.get(cur, INF)) + step
			if ng < float(g.get(n, INF)):
				g[n] = ng
				parent[n] = cur
				open.append(n)
	return {"ok": false, "cells": []}

# 规划一圈完全闭合的墙：以环上的天然屏障（山水/建筑/资源）为锚点，逐段 A* 连墙。
# 不要求墙线是规则圆：A* 可在环内外绕行，最终形状由地形和建筑决定；
# 没有天然屏障时要求环格全部能直接放墙。
func _ring_build_path(center: Vector2i, radius: int) -> Dictionary:
	var cells: Array = _ring_cells(center, radius)
	if cells.size() < 16:
		return {"ok": false}
	var barrier_idx: Array = []
	for i in range(cells.size()):
		if _ring_cell_blocked(cells[i]):
			barrier_idx.append(i)
	var wall_cells: Dictionary = {}
	if barrier_idx.size() <= 1:
		# 没有山水/建筑可借力：只能整圈都直接放墙
		for cell in cells:
			if _ring_cell_blocked(cell):
				continue
			if not _ring_exact_wall_ok(cell):
				return {"ok": false}
			wall_cells[cell] = true
	else:
		# 只连接“天然屏障之间的可通行段”。旧逻辑把每两个相邻屏障格都连一遍，
		# 地图边缘会形成一整段连续的外界格，A* 在两端都出界时必然失败，
		# 于是贴边的基地永远规划不出能借地图边界封口的墙圈。
		for k in range(barrier_idx.size()):
			var ia: int = int(barrier_idx[k])
			var ib: int = int(barrier_idx[(k + 1) % barrier_idx.size()])
			var span: int = (ib - ia + cells.size()) % cells.size()
			if span <= 1:
				# 两个屏障紧挨着，中间没有可建墙的缝。
				continue
			# 从屏障两侧的第一格可通行格开始连，而不是从屏障格本身开始：
			# 贴地图边缘时屏障外侧就是地图外/边界，A* 从那里没有合法落脚点。
			var start_idx: int = (ia + 1) % cells.size()
			var end_idx: int = (ib - 1 + cells.size()) % cells.size()
			var a: Vector2i = cells[start_idx]
			var b: Vector2i = cells[end_idx]
			if not _ring_exact_wall_ok(a) or not _ring_exact_wall_ok(b):
				return {"ok": false}
			wall_cells[a] = true
			if a == b:
				continue
			var res: Dictionary = _ring_connect_a_star(a, b, center, radius)
			if not bool(res.get("ok", false)):
				return {"ok": false}
			for c in res.get("cells", []):
				if not _ring_cell_blocked(c):
					wall_cells[c] = true
	var pts: Array = []
	for c in wall_cells.keys():
		pts.append(_ctx.grid_to_world(c.x, c.y))
	var walls: int = pts.size()
	if walls < RING_WALL_MIN or walls > RING_WALL_MAX:
		return {"ok": false}
	return {
		"ok": true,
		"radius": radius,
		"cells": cells,
		"walls": walls,
		"barriers": barrier_idx.size(),
		"gaps": 0,
		"positions": pts,
	}

# 兜底：逐格在环格附近找墙位（允许 2.5 米内避坡），只用于 A* 找不到精确墙格时。
func _ring_build_spot_fallback(center: Vector2i, radius: int) -> Dictionary:
	var cells: Array = _ring_cells(center, radius)
	if cells.size() < 16:
		return {"ok": false}
	var positions: Array = []
	var barriers: int = 0
	var prev_pos: Vector3 = Vector3.ZERO
	var prev_was_wall: bool = false
	var first_pos: Vector3 = Vector3.ZERO
	var first_is_wall: bool = false
	var last_pos: Vector3 = Vector3.ZERO
	var last_is_wall: bool = false
	for cell in cells:
		if _ring_cell_blocked(cell):
			barriers += 1
			prev_was_wall = false
			continue
		if _is_ford_cell(cell.x, cell.y):
			return {"ok": false}
		var wp: Vector3 = _ring_wall_spot(cell)
		if wp == Vector3.ZERO:
			return {"ok": false}
		# 相邻环格在绕坡时可能吸附到同一个墙位；重复墙位会触发 0.9 米间距校验，
		# 让整圈兜底被误判为不可建。保留第一个即可，后面的格子由同一面墙覆盖。
		if not positions.is_empty() and (positions[positions.size() - 1] as Vector3).distance_to(wp) < 0.9:
			continue
		# 兜底墙位允许在 2.5 米内避坡，但相邻两面墙必须仍能咬合；
		# 否则看似“规划成功”，实际墙圈会留下敌人可钻的缺口。
		if prev_was_wall and prev_pos.distance_to(wp) > 1.85:
			return {"ok": false}
		if not first_is_wall:
			first_is_wall = true
			first_pos = wp
		last_is_wall = true
		last_pos = wp
		prev_pos = wp
		prev_was_wall = true
		positions.append(wp)
	# 环形首尾相邻：两端都没有天然屏障隔断时也要能咬合。
	# 贴地图边缘时首尾之间就是地图外（天然屏障），不需要也不应该连起来。
	if not _ring_uses_map_edge(center, radius) and first_is_wall and last_is_wall \
			and last_pos.distance_to(first_pos) > 1.85:
		return {"ok": false}
	if positions.size() < RING_WALL_MIN or positions.size() > RING_WALL_MAX:
		return {"ok": false}
	return {
		"ok": true,
		"radius": radius,
		"cells": cells,
		"walls": positions.size(),
		"barriers": barriers,
		"gaps": 0,
		"positions": positions,
	}

# 等半径的墙圈是否已经碰到地图边界；碰到时边界本身就是天然屏障。
func _ring_uses_map_edge(center: Vector2i, radius: int) -> bool:
	var sz: int = RTSConfig.MAP_SIZE
	return center.x - radius < 1 or center.y - radius < 1 \
			or center.x + radius >= sz - 1 or center.y + radius >= sz - 1

# 规划出的墙圈即使被 BFS 判定有缺口，也先在缺口处补墙再验收。
# 补墙从“主城泛洪第一次冲出环半径”的那条路径上取，保证补的是真实缺口，
# 而不是在环上随便加密墙段。补不上就返回空，绝不接受漏人的墙圈。
func _ring_fill_gaps(castle, center: Vector2i, radius: int,
		base_blocked: Dictionary, built: Dictionary) -> Dictionary:
	var positions: Array = built.get("positions", []).duplicate()
	var wall_cells: Dictionary = {}
	for p in positions:
		wall_cells[_ctx.world_to_grid(p)] = true
	# 先在环线上补“本该有墙但实际缺失”的格子。A* 兜底/建造失败留下的洞，
	# 往往就是环序列里少了一格；直接补这一格比从泛洪路径上猜位置准确得多。
	var ring_cells: Array = built.get("cells", [])
	for c in ring_cells:
		if wall_cells.has(c) or _ring_cell_blocked(c):
			continue
		if not _ring_exact_wall_ok(c):
			continue
		var cp: Vector3 = _ctx.grid_to_world(c.x, c.y)
		var close: bool = false
		for p in positions:
			if (p as Vector3).distance_to(cp) < 0.9:
				close = true
				break
		if close:
			continue
		positions.append(cp)
		wall_cells[c] = true
		if positions.size() > RING_WALL_MAX:
			return {}
	# 整圈缺失格一次性补齐后再验收，避免每补一格就全图泛洪一次。
	if _ring_is_sealed(castle, radius, base_blocked, wall_cells):
		var ring_sealed: Dictionary = built.duplicate(true)
		ring_sealed["positions"] = positions
		ring_sealed["walls"] = positions.size()
		ring_sealed["gaps"] = positions.size() - int(built.get("walls", positions.size()))
		return ring_sealed
	var started_ms: int = SimTime.now_ms()
	for attempt in range(6):
		if _ring_is_sealed(castle, radius, base_blocked, wall_cells):
			var sealed_built: Dictionary = built.duplicate(true)
			sealed_built["positions"] = positions
			sealed_built["walls"] = positions.size()
			sealed_built["gaps"] = attempt
			return sealed_built
		if SimTime.now_ms() - started_ms >= RING_PLAN_BUDGET_MS:
			break
		var gap: Vector2i = _find_ring_gap_cell(castle, center, radius, base_blocked, wall_cells)
		if gap == Vector2i(-9999, -9999):
			break
		if wall_cells.has(gap):
			break
		var gap_pos: Vector3 = _ctx.grid_to_world(gap.x, gap.y)
		positions.append(gap_pos)
		wall_cells[gap] = true
	if not _ring_is_sealed(castle, radius, base_blocked, wall_cells):
		return {}
	var sealed: Dictionary = built.duplicate(true)
	sealed["positions"] = positions
	sealed["walls"] = positions.size()
	sealed["gaps"] = positions.size() - int(built.get("walls", positions.size()))
	return sealed

# 从主城附近泛洪，找到第一次冲出墙圈半径的路径，并在路径靠近环线的位置
# 找一个能直接落墙的格子。返回 (-9999,-9999) 表示当前点位已经封死或找不到可补位置。
func _find_ring_gap_cell(castle, center: Vector2i, radius: int,
		base_blocked: Dictionary, wall_cells: Dictionary) -> Vector2i:
	var sz: int = RTSConfig.MAP_SIZE
	var edge_mode: bool = _ring_uses_map_edge(center, radius)
	var blocked_use: Dictionary = base_blocked
	if edge_mode:
		# 与 _ring_is_sealed_by_far_edge 保持一致：地图最外圈不可站立，
		# 否则找缺口时会沿着地图边界绕过墙段终点，误以为到处是缺口。
		blocked_use = base_blocked.duplicate()
		for i in range(sz):
			blocked_use[Vector2i(i, 0)] = true
			blocked_use[Vector2i(i, sz - 1)] = true
			blocked_use[Vector2i(0, i)] = true
			blocked_use[Vector2i(sz - 1, i)] = true
	var start_r: int = maxi(3, int(ceil(float(castle.body_radius))) + 1)
	var queue: Array = []
	var seen: Dictionary = {}
	var parent: Dictionary = {}
	var center_cell: Vector2i = _ctx.world_to_grid(castle.global_position)
	for dx in range(-start_r, start_r + 1):
		for dz in range(-start_r, start_r + 1):
			var c := Vector2i(center_cell.x + dx, center_cell.y + dz)
			if c.x < 0 or c.y < 0 or c.x >= sz or c.y >= sz:
				continue
			if blocked_use.has(c) or wall_cells.has(c) or seen.has(c):
				continue
			seen[c] = true
			queue.append(c)
	var target := Vector2i(-9999, -9999)
	var dirs: Array = [
		Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
		Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
	]
	var escape_r: float = float(radius) + (4.0 if edge_mode else 2.0)
	var bound_r: float = float(radius) + 9.0
	var head: int = 0
	while head < queue.size():
		var cur: Vector2i = queue[head]
		head += 1
		if Vector2(cur - center).length() > escape_r:
			target = cur
			break
		for d in dirs:
			var n: Vector2i = cur + d
			if n.x < 0 or n.y < 0 or n.x >= sz or n.y >= sz:
				continue
			if seen.has(n) or blocked_use.has(n) or wall_cells.has(n):
				continue
			if Vector2(n - center).length() > bound_r:
				continue
			if d.x != 0 and d.y != 0:
				if blocked_use.has(cur + Vector2i(d.x, 0)) or wall_cells.has(cur + Vector2i(d.x, 0)) \
						or blocked_use.has(cur + Vector2i(0, d.y)) or wall_cells.has(cur + Vector2i(0, d.y)):
					continue
			seen[n] = true
			parent[n] = cur
			queue.append(n)
	if target == Vector2i(-9999, -9999):
		return target
	# 路径从外向内回溯，先挑靠近环线、且能直接落墙的格子。
	var path: Array = []
	var node: Vector2i = target
	while parent.has(node):
		path.append(node)
		node = parent[node]
	path.append(node)
	for c in path:
		var dist: float = Vector2(c - center).length()
		if dist < float(radius) - 2.5 or dist > float(radius) + 2.0:
			continue
		if _ring_exact_wall_ok(c) and not wall_cells.has(c):
			return c
	# 环线附近没有平地时，退而求其次封住路径上第一个可落墙格。
	for c in path:
		if _ring_exact_wall_ok(c) and not wall_cells.has(c):
			return c
	return Vector2i(-9999, -9999)


func _pick_ring_radius(castle, forced_radius: int = 0, center_override: Vector2i = Vector2i(-9999, -9999), preferred_radius: int = 0) -> Dictionary:
	var center: Vector2i = center_override if center_override.x > -9000 else _ctx.world_to_grid(castle.global_position)
	var base_blocked: Dictionary = _ring_blocked_base()
	var radii: Array = []
	var min_r: int = maxi(RING_MIN_RADIUS, int(ceil(float(castle.body_radius) + 3.0)))
	var seen_radii: Dictionary = {}
	var add_radius := func(r: int) -> void:
		r = clampi(r, min_r, RING_MAX_RADIUS)
		if not seen_radii.has(r):
			seen_radii[r] = true
			radii.append(r)
	if forced_radius > 0:
		# 外圈只试“期望半径 + 少量向外步长”，山脚/水湾绕不过去时
		# 用第一个可建近似圈兜底；不再把 20 多个半径全部算一遍。
		for delta in [0, 4, 8, 12]:
			add_radius.call(maxi(5, forced_radius) + int(delta))
	elif preferred_radius > 0:
		# 首圈优先保证能快速出圈：期望半径、稍大、稍小，最后退回最小圈。
		var start_r: int = clampi(preferred_radius, RING_MIN_RADIUS, RING_MAX_RADIUS)
		for delta in [0, 4, -4]:
			add_radius.call(start_r + int(delta))
		add_radius.call(min_r)
	else:
		add_radius.call(min_r)
		add_radius.call(min_r + 4)
	var started_ms: int = SimTime.now_ms()
	var tried: int = 0
	for r in radii:
		if int(r) > RING_MAX_RADIUS:
			continue
		# 第一个候选必算，之后超时立即收手，用已经拿到的近似圈兜底。
		if tried > 0 and SimTime.now_ms() - started_ms >= RING_PLAN_BUDGET_MS:
			break
		tried += 1
		# 贴地图边缘的基地允许墙圈伸出地图：超出边界的部分天然不可通行，
		# 只要地图内的墙段首尾接到边界，就能用地图边界当墙，省下一整段城墙。
		if center.x < 2 or center.y < 2 \
				or center.x >= RTSConfig.MAP_SIZE - 2 or center.y >= RTSConfig.MAP_SIZE - 2:
			continue
		var built: Dictionary = _ring_build_path(center, int(r))
		if not bool(built.get("ok", false)):
			built = _ring_build_spot_fallback(center, int(r))
		if not bool(built.get("ok", false)):
			continue
		# BFS 只看最终点位，不管来自 A* 还是兜底：先算清真正能通行的缺口，
		# 能补的墙位补上；补不上就换下一个半径，绝不把缺口环当成已闭合圈。
		var candidate_walls: Dictionary = {}
		for p in built["positions"]:
			candidate_walls[_ctx.world_to_grid(p)] = true
		if not _ring_is_sealed(castle, int(r), base_blocked, candidate_walls):
			built = _ring_fill_gaps(castle, center, int(r), base_blocked, built)
			if built.is_empty():
				continue
		# 墙与墙至少 0.9 米，否则 build_building 会拒绝第二面墙，点位上却看不出来。
		var pts0: Array = built.get("positions", [])
		var spaced: bool = true
		for i in range(pts0.size()):
			for j in range(i + 1, pts0.size()):
				if (pts0[i] as Vector3).distance_to(pts0[j] as Vector3) < 0.9:
					spaced = false
					break
			if not spaced:
				break
		if not spaced:
			continue
		# 半径从小到大扫，第一个能闭合的环直接采用：墙数通常最少，规划耗时也可控。
		return built
	return {}

# 主城正好压在山脚/水湾时，环心稍微平移一两格往往就能闭合；用平移后的环心再试几次。
func _pick_ring_radius_best(castle, forced_radius: int = 0,
		preferred_radius: int = 0, allow_shift: bool = true) -> Dictionary:
	_ring_exact_ok_cache.clear()
	_ring_blocked_base_cache.clear()
	var base: Dictionary = _pick_ring_radius(castle, forced_radius, Vector2i(-9999, -9999), preferred_radius)
	if not base.is_empty() or not allow_shift:
		return base
	# 基地正好贴山脚/地图边缘时，环心向地图内侧挪 2 格通常就能闭合；
	# 只在原环心完全失败时补试一次，避免每次都多跑几轮 A*。
	var center: Vector2i = _ctx.world_to_grid(castle.global_position)
	var map_center := Vector2i(RTSConfig.MAP_SIZE / 2, RTSConfig.MAP_SIZE / 2)
	var dir := Vector2(map_center.x - center.x, map_center.y - center.y)
	if dir.length() < 1.5:
		return base
	dir = dir.normalized()
	var off := Vector2i(int(round(dir.x * 2.0)), int(round(dir.y * 2.0)))
	return _pick_ring_radius(castle, forced_radius, center + off, preferred_radius)

# 旧入口保留给 _plan_defense_line 等历史路径；实际圈数由 _plan_wall_ring 管理。
func _plan_castle_ring(castle, is_outer: bool = false) -> bool:
	if _required_wall_ring_count(castle) <= 0:
		return false
	if is_outer:
		if _wall_rings_planned <= 0:
			return false
		return _plan_wall_ring(castle, _wall_rings_planned)
	return _plan_wall_ring(castle, 0)

# 圈内塔：箭塔均匀分布，炮塔优先朝威胁方向。
# 塔放在墙内侧 3 米左右，既不打断墙圈，又能覆盖墙外。
func _plan_ring_towers(castle, radius: int) -> void:
	# 外圈半径超过主城 10 米视野时，先用少量瞭望塔把外圈视野铺出来；
	# 位置由 _plan_base_watchtowers() 按“新增视野”选，而不是固定撒四座。
	if radius > 7:
		_plan_base_watchtowers(castle, radius)
	var tower_before: int = tower_positions.size()
	# 塔尽量贴在墙外侧 2 米（射程 6~7 米，正好覆盖整段墙线 + 墙外 4 米）。
	# 外圈被地形占住时依次退回墙线上、墙内侧，保证每圈至少落几座塔。
	for i in range(8):
		var a: float = TAU * float(i) / 8.0
		var spot: Vector3 = Vector3.ZERO
		for tr in [float(radius) + 2.0, float(radius) + 0.5, float(radius) - 2.8]:
			var p: Vector3 = castle.global_position + Vector3(cos(a) * tr, 0.0, sin(a) * tr)
			spot = _find_anchor_spot(p, 25, 2.2)
			if spot != Vector3.ZERO:
				break
		if spot != Vector3.ZERO:
			# 塔的优先级必须低于墙（队列按优先级升序建造）：墙一圈几十段，
			# 塔排在墙后面就永远轮不到它（实测 8 分钟 0 座塔）。
			_add_defense_slot(25, spot, 0.6 + float(i) * 0.1, "tower")
	# 小半径时圈内被主城/民居占满，塔位放不进去；改在墙外 3 米补一圈塔，
	# 不破坏墙体闭合（塔在墙外，不会在墙圈上开口），同时保证有塔圈可用。
	if tower_positions.size() - tower_before < 3:
		for i in range(4):
			var a2: float = TAU * float(i) / 4.0 + 0.4
			var op: Vector3 = castle.global_position + Vector3(cos(a2), 0.0, sin(a2)) * (float(radius) + 3.0)
			var ospot: Vector3 = _find_anchor_spot(op, 25, 2.2)
			if ospot != Vector3.ZERO:
				_add_defense_slot(25, ospot, 0.8 + float(i) * 0.1, "tower")
	var cannon_r: float = float(radius) + 1.0
	for side in [-1.0, 1.0]:
		# 墙圈内侧同时有瞭望塔/箭塔，固定角度可能刚好被占；向两侧多试几个角度，
		# 保证每圈至少落下一座炮塔，而不是“规划成功但只有箭塔”。
		var placed: bool = false
		for turn in [0.0, 0.35, -0.35, 0.7, -0.7, 1.0, -1.0]:
			var dir: Vector3 = _defense_dir.rotated(Vector3.UP, (0.55 + float(turn)) * float(side))
			for extra in [0.0, 2.0, -2.0]:
				var cp: Vector3 = castle.global_position + dir * (cannon_r + float(extra))
				var cspot: Vector3 = _find_anchor_spot(cp, 26, 2.0)
				if cspot != Vector3.ZERO:
					_add_defense_slot(26, cspot, 0.5 + absf(float(turn)), "tower")
					placed = true
					break
			if placed:
				break

# ═══════════════════════════════════════════════════════════════
# 瞭望塔选点：按“能新增多少有效视野”打分，而不是固定围主城一圈
# ═══════════════════════════════════════════════════════════════

# 已建 + 已规划的数量。规划中的塔还没有进入 battle 的实体缓存，必须单独算。
func _watchtower_total() -> int:
	return maxi(_count_bld(OUTPOST_ID), _count_planned(OUTPOST_ID))

# 已建或已规划的瞭望塔是否离目标太近。太近只会重复已有的 25 米视野。
func _watchtower_near(pos: Vector3, radius: float = WATCHTOWER_MIN_SEP) -> bool:
	for s in _defense_slots:
		if int(s["id"]) == OUTPOST_ID:
			var sp: Vector3 = s["pos"]
			if sp.distance_to(pos) < radius:
				return true
	if _ctx.battle_has_method("get_nearby_buildings"):
		for e in _ctx.nearby_buildings(pos, radius):
			if e is Building and e.health > 0 and int(e.entity_id) == OUTPOST_ID \
					and _belongs(e):
				if e.global_position.distance_to(pos) < radius:
					return true
	return false

func _watchtower_centers() -> Array:
	var out: Array = []
	for s in _defense_slots:
		if int(s["id"]) == OUTPOST_ID:
			out.append(s["pos"])
	return out

# 一片格子值多少：敌人来路/隘口/资源区附近值钱，主城内部已经看得见的区域不值钱。
func _watchtower_cell_weight(world_pos: Vector3, anchor: Vector3, mode: String) -> float:
	var weight: float = 1.0
	var castle = _castle()
	if castle != null and is_instance_valid(castle):
		var rel: Vector3 = world_pos - castle.global_position
		rel.y = 0.0
		var dist: float = rel.length()
		if dist < 10.0:
			weight *= 0.2
		elif dist < 16.0:
			weight *= 0.65
		if rel.length_squared() > 0.01 and _defense_dir.length_squared() > 0.01:
			var facing: float = rel.normalized().dot(_defense_dir.normalized())
			weight *= 1.0 + maxf(facing, 0.0) * 2.0
	if not _choke_anchor.is_empty():
		var cp: Vector3 = _choke_anchor.get("pos", Vector3.ZERO)
		if cp != Vector3.ZERO:
			var dc: float = cp.distance_to(world_pos)
			if dc < 16.0:
				weight += 1.2 * (1.0 - dc / 16.0)
	for z in resource_zones:
		if not z.has("center"):
			continue
		var zp: Vector3 = z["center"]
		var dz: float = zp.distance_to(world_pos)
		if dz < 14.0:
			weight += 0.8 * (1.0 - dz / 14.0)
	if mode == "resource":
		var da: float = anchor.distance_to(world_pos)
		if da < 18.0:
			weight *= 1.0 + (1.0 - da / 18.0)
	elif mode == "chain":
		var dch: float = anchor.distance_to(world_pos)
		if dch < 16.0:
			weight *= 1.0 + (1.0 - dch / 16.0)
	return weight

func _watchtower_covered_by_planned(world_pos: Vector3, planned: Array) -> bool:
	for p in planned:
		var pp: Vector3 = p
		if pp.distance_to(world_pos) <= 25.0:
			return true
	return false

# 候选塔能新增的加权视野格。用队伍可见掩码，不读取玩家迷雾；
# 同时把已经规划、但还没落成的瞭望塔算进去，避免一次规划里连续选同一片区域。
func _watchtower_visible_gain(pos: Vector3, anchor: Vector3, mode: String) -> float:
	var cfg: Dictionary = EntityDatabase.get_config(OUTPOST_ID)
	if cfg.is_empty():
		return 0.0
	var vision: float = float(cfg.get("vision_range", 25.0))
	var mask: PackedByteArray = PackedByteArray()
	if _ctx.battle_has_method("get_team_visible_mask"):
		mask = _ctx.visible_mask(_ctx.my_team())
	var ms: int = RTSConfig.MAP_SIZE
	var center: Vector2i = _ctx.world_to_grid(pos)
	var planned: Array = _watchtower_centers()
	var radius: int = int(ceil(vision))
	var steps: int = int(ceil(float(radius) / float(WATCHTOWER_SAMPLE_STEP)))
	var full_mask: bool = mask.size() == ms * ms
	var gain: float = 0.0
	for ix in range(-steps, steps + 1):
		var dx: int = ix * WATCHTOWER_SAMPLE_STEP
		for iz in range(-steps, steps + 1):
			var dz: int = iz * WATCHTOWER_SAMPLE_STEP
			if dx * dx + dz * dz > radius * radius:
				continue
			var gx: int = center.x + dx
			var gz: int = center.y + dz
			if gx < 0 or gz < 0 or gx >= ms or gz >= ms:
				continue
			if full_mask and mask[gx * ms + gz] == 1:
				continue
			var wp: Vector3 = _ctx.grid_to_world(gx, gz)
			if _watchtower_covered_by_planned(wp, planned):
				continue
			gain += _watchtower_cell_weight(wp, anchor, mode)
	return gain

func _score_watchtower_candidate(pos: Vector3, anchor: Vector3, mode: String) -> float:
	if _watchtower_near(pos):
		return -1.0
	var gain: float = _watchtower_visible_gain(pos, anchor, mode)
	if gain < WATCHTOWER_GAIN_MIN:
		return -1.0
	var score: float = gain
	var dist: float = pos.distance_to(anchor)
	if mode == "base":
		# 基地塔放在 8~12 米最合适：太贴主城会和主城视野重叠，太远又容易被拆。
		score -= absf(dist - 10.0) * 0.6
	elif mode == "resource":
		score -= absf(dist - 8.0) * 0.8
	elif mode == "chain":
		score -= dist * 0.05
	# 纯视野建筑没有自卫能力，明显暴露在敌军面前的位置直接降权。
	for e in _ctx.visible_enemies():
		if not is_instance_valid(e) or e.health <= 0:
			continue
		if not (e is Army or e is Building):
			continue
		if not _is_enemy_ent(e):
			continue
		var ed: float = e.global_position.distance_to(pos)
		if ed < 12.0:
			score -= (12.0 - ed) * 3.0
	return score

func _watchtower_candidate_ok(pos: Vector3, require_vision: bool,
		require_actual_vision: bool) -> bool:
	var cfg: Dictionary = EntityDatabase.get_config(OUTPOST_ID)
	if cfg.is_empty():
		return false
	var radius: float = float(cfg.get("body_radius", 0.6))
	if not _is_valid_defense_ground(pos, radius, true, false, require_vision, true):
		return false
	if require_actual_vision and not _defense_pos_visible(pos):
		return false
	if not _defense_slot_clear(pos, radius, OUTPOST_ID):
		return false
	if _watchtower_near(pos):
		return false
	return true

func _collect_watchtower_candidates(center: Vector3, radii: Array, angle_count: int,
		require_vision: bool, require_actual_vision: bool) -> Array:
	var out: Array = []
	var seen: Dictionary = {}
	for rad in radii:
		var rf: float = float(rad)
		for i in range(angle_count):
			var a: float = TAU * float(i) / float(angle_count)
			var p: Vector3 = center + Vector3(cos(a) * rf, 0.0, sin(a) * rf)
			var key: Vector2i = _ctx.world_to_grid(p)
			if seen.has(key):
				continue
			seen[key] = true
			if _watchtower_candidate_ok(p, require_vision, require_actual_vision):
				out.append(p)
	return out

func _best_watchtower_index(candidates: Array, anchor: Vector3, mode: String) -> int:
	var best_idx: int = -1
	var best_score: float = -1.0
	for i in range(candidates.size()):
		var p: Vector3 = candidates[i]
		var s: float = _score_watchtower_candidate(p, anchor, mode)
		if s > best_score:
			best_score = s
			best_idx = i
	return best_idx

func _pick_watchtower_spot(center: Vector3, radii: Array, angle_count: int,
		anchor: Vector3, mode: String, require_vision: bool,
		require_actual_vision: bool) -> Vector3:
	var candidates: Array = _collect_watchtower_candidates(center, radii, angle_count,
			require_vision, require_actual_vision)
	var idx: int = _best_watchtower_index(candidates, anchor, mode)
	if idx < 0:
		return Vector3.ZERO
	return candidates[idx]

# 主城圈：最多两座，先保证朝敌方向/外圈墙位的视野，再补侧翼。
func _plan_base_watchtowers(castle, radius: int) -> void:
	var left: int = WATCHTOWER_CAP - _watchtower_total()
	if left <= 0:
		return
	var limit: int = mini(WATCHTOWER_BASE_MAX, left)
	var anchor: Vector3 = castle.global_position
	# 塔本身不参战，基地塔不要落到墙圈外侧；半径较小时只取 8 米这一档。
	var max_base_dist: float = clampf(float(radius) - 2.0, 8.0, 12.0)
	var radii: Array = [8.0]
	if max_base_dist >= 9.5:
		radii.append(10.0)
	if max_base_dist >= 11.5:
		radii.append(12.0)
	var candidates: Array = _collect_watchtower_candidates(anchor,
			radii, 12, true, true)
	var added: int = 0
	while added < limit and not candidates.is_empty():
		var idx: int = _best_watchtower_index(candidates, anchor, "base")
		if idx < 0:
			break
		var spot: Vector3 = candidates[idx]
		candidates.remove_at(idx)
		if not _add_defense_slot(OUTPOST_ID, spot, 2.0 + float(added) * 0.1,
				"tower", false, true, true):
			continue
		added += 1
	# 极端地形下评分候选全被挡掉时，才用旧的近主城四点兜底。
	# 如果已经存在瞭望塔，说明视野不是完全没铺，不能为了兜底再重复加塔。
	if added == 0 and _watchtower_total() == 0:
		for i in range(4):
			var va: float = TAU * float(i) / 4.0 + PI / 4.0
			var vp: Vector3 = castle.global_position + Vector3(cos(va), 0.0, sin(va)) * 8.0
			var vs: Vector3 = _find_anchor_spot(vp, OUTPOST_ID, 1.6)
			if vs != Vector3.ZERO and not _watchtower_near(vs) \
					and _add_defense_slot(OUTPOST_ID, vs, 2.0 + float(i) * 0.1, "tower"):
				added += 1
				if added >= limit:
					break

# 隘口视野链：只沿主城到山口的路线补塔，单次规划最多 4 座；
# 已经看得见的区域不再重复加塔，但靠近墙基的最后一段保留兜底。
func _plan_chain_watchtowers(castle, wall_base: Vector3, dir: Vector3,
		priority: float) -> int:
	var total_dist: float = castle.global_position.distance_to(wall_base)
	if total_dist < 8.0:
		return 0
	var step: float = 8.0
	var d: float = step
	var added: int = 0
	while d < total_dist - 1.0 and added < WATCHTOWER_CHAIN_MAX:
		if _watchtower_total() >= WATCHTOWER_CAP:
			break
		var center: Vector3 = castle.global_position + dir * d
		var spot: Vector3 = _pick_watchtower_spot(center, [0.0, 2.2], 8, wall_base,
				"chain", false, false)
		if spot != Vector3.ZERO:
			var gain: float = _watchtower_visible_gain(spot, wall_base, "chain")
			var near_wall: bool = spot.distance_to(wall_base) < 26.0
			if gain >= WATCHTOWER_GAIN_MIN or near_wall:
				if _add_defense_slot(OUTPOST_ID, spot, priority + float(added) * 0.1,
						"tower", false, false, true):
					added += 1
		d += step
	return added

# 给升时代补齐建筑用：只返回位置，不走防线队列，避免和 _try_build_age_requirement
# 的立即建造重复排队。找不到合适位置时返回 ZERO，让 AI 走普通兜底。
func find_watchtower_build_position(castle) -> Vector3:
	if castle == null or not is_instance_valid(castle):
		return Vector3.ZERO
	if _watchtower_total() >= WATCHTOWER_CAP:
		return Vector3.ZERO
	var spot: Vector3 = _pick_watchtower_spot(castle.global_position,
			[8.0, 10.0, 12.0], 12, castle.global_position, "base", true, true)
	if spot != Vector3.ZERO:
		return spot
	for dist in [8.0, 10.0, 12.0]:
		for i in range(8):
			var a: float = TAU * float(i) / 8.0
			var p: Vector3 = castle.global_position + Vector3(cos(a) * float(dist), 0.0,
					sin(a) * float(dist))
			if _watchtower_candidate_ok(p, true, true):
				return p
	return Vector3.ZERO

func _resource_watchtower_count() -> int:
	var count: int = 0
	for e in _ctx.entities_children():
		if not (e is Building) or e.health <= 0:
			continue
		if int(e.entity_id) != OUTPOST_ID or not _belongs(e):
			continue
		for z in resource_zones:
			if not z.has("center"):
				continue
			var zp: Vector3 = z["center"]
			if e.global_position.distance_to(zp) < 14.0:
				count += 1
				break
	return count

# 山/水 + 现有建筑/资源对陆军的阻挡。同一次圈规划里这些不会变，
# 缓存一次供所有候选半径复用，避免每个半径都扫全图地形和实体。
func _ring_blocked_base() -> Dictionary:
	if not _ring_blocked_base_cache.is_empty():
		return _ring_blocked_base_cache
	var sz: int = RTSConfig.MAP_SIZE
	var blocked: Dictionary = {}
	for gx in range(sz):
		for gz in range(sz):
			if _cell_blocks_land(gx, gz):
				blocked[Vector2i(gx, gz)] = true
	for e in _ctx.entities_children():
		if not (e is GameEntity) or e.health <= 0:
			continue
		if not (e is Building or e is WorldResource):
			continue
		var c: Vector2i = _ctx.world_to_grid(e.global_position)
		var rr: int = int(ceil(float(e.body_radius)))
		# 城墙是 2 米宽的连续墙体，兜底点位允许有不到 1.85 米的中心距；
		# 闭合校验按墙体半径 + 安全边距算，否则 0.45 的余量会把实际封死的墙圈误判为有缝。
		var rr2: float = float(e.body_radius) + (0.9 if int(e.entity_id) == 27 else 0.45)
		for dx in range(-rr, rr + 1):
			for dz in range(-rr, rr + 1):
				if dx * dx + dz * dz <= rr2 * rr2:
					blocked[Vector2i(c.x + dx, c.y + dz)] = true
	_ring_blocked_base_cache = blocked
	return blocked

# 用敌人陆地通行规则做一次 BFS：候选墙格 + 现有建筑/资源 + 山/水都算阻挡，
# 从地图边界泛洪；如果能进到主城周围半径内，就说明环没有闭合。
func _ring_is_sealed(castle, radius: int, base_blocked: Dictionary = {},
		candidate_walls: Dictionary = {}) -> bool:
	var sz: int = RTSConfig.MAP_SIZE
	var blocked: Dictionary = base_blocked
	if blocked.is_empty():
		blocked = _ring_blocked_base()
	var extra: Dictionary = candidate_walls
	if extra.is_empty():
		for p in wall_positions:
			extra[_ctx.world_to_grid(p)] = true
	var center: Vector2i = _ctx.world_to_grid(castle.global_position)
	# 墙圈伸出地图时，地图边界就是墙的一部分：这时从“远侧边界”往主城泛洪，
	# 只要远侧进不来，主城就被墙段 + 地图边界封死了。
	# 旧实现一律要求内圈不能碰边界，导致贴边基地永远无法用地图边缘省墙。
	if _ring_uses_map_edge(center, radius):
		return _ring_is_sealed_by_far_edge(castle, center, radius, blocked, extra)
	# 从主城周围的空地开始泛洪；如果内圈和地图边界连通，说明墙圈有缺口。
	# 反过来“从边界泛洪再查半径”会把墙圈外、名义半径内的空地误判成泄漏。
	var seen: Dictionary = {}
	var queue: Array = []
	var start_r: int = maxi(3, int(ceil(float(castle.body_radius))) + 1)
	for dx in range(-start_r, start_r + 1):
		for dz in range(-start_r, start_r + 1):
			var c := Vector2i(center.x + dx, center.y + dz)
			if c.x < 0 or c.y < 0 or c.x >= sz or c.y >= sz:
				continue
			if blocked.has(c) or extra.has(c) or seen.has(c):
				continue
			seen[c] = true
			queue.append(c)
	if queue.is_empty():
		return true
	var dirs: Array = [
		Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
		Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
	]
	var head: int = 0
	while head < queue.size():
		var cur: Vector2i = queue[head]
		head += 1
		if cur.x <= 0 or cur.y <= 0 or cur.x >= sz - 1 or cur.y >= sz - 1:
			return false  # 内圈能走到地图边界 -> 有缺口
		for d in dirs:
			var n: Vector2i = cur + d
			if n.x < 0 or n.y < 0 or n.x >= sz or n.y >= sz:
				continue
			if seen.has(n) or blocked.has(n) or extra.has(n):
				continue
			if d.x != 0 and d.y != 0:
				if blocked.has(cur + Vector2i(d.x, 0)) or extra.has(cur + Vector2i(d.x, 0)) \
						or blocked.has(cur + Vector2i(0, d.y)) or extra.has(cur + Vector2i(0, d.y)):
					continue
			seen[n] = true
			queue.append(n)
	return true

# 贴边墙圈的验收：墙段 + 地图边界共同围住主城时，近侧边界属于“圈内”，
# 不能当作泄漏；只从离主城足够远的边界格子（远侧 / 侧翼）泛洪。
# 如果远侧能一路走到主城，说明墙段没有接到边界或中间有缺口。
func _ring_is_sealed_by_far_edge(castle, center: Vector2i, radius: int,
		blocked: Dictionary, extra: Dictionary) -> bool:
	var sz: int = RTSConfig.MAP_SIZE
	var inside: Dictionary = {}
	var seen: Dictionary = {}
	var queue: Array = []
	var start_r: int = maxi(3, int(ceil(float(castle.body_radius))) + 1)
	for dx in range(-start_r, start_r + 1):
		for dz in range(-start_r, start_r + 1):
			var c := Vector2i(center.x + dx, center.y + dz)
			if c.x < 0 or c.y < 0 or c.x >= sz or c.y >= sz:
				continue
			if blocked.has(c) or extra.has(c):
				continue
			inside[c] = true
	# 地图最外圈对守军敌人来说不可站立（墙网也按边界处理），泛洪时整圈封死；
	# 外部种子取边界内侧一格，避免敌人沿着地图边界绕过墙段终点。
	var edge_blocked: Dictionary = blocked.duplicate()
	for i in range(sz):
		edge_blocked[Vector2i(i, 0)] = true
		edge_blocked[Vector2i(i, sz - 1)] = true
		edge_blocked[Vector2i(0, i)] = true
		edge_blocked[Vector2i(sz - 1, i)] = true
	# 只取远侧边界：距主城超过 radius+4 的边界内圈格。近侧边界在墙圈里面，
	# 若也当外部种子，会把封好的贴边基地误判成漏风。
	var perim: Array = []
	for x in range(1, sz - 1):
		perim.append(Vector2i(x, 1))
		perim.append(Vector2i(x, sz - 2))
	for y in range(2, sz - 2):
		perim.append(Vector2i(1, y))
		perim.append(Vector2i(sz - 2, y))
	var far_r2: float = pow(float(radius) + 4.0, 2.0)
	for c in perim:
		if edge_blocked.has(c) or extra.has(c) or inside.has(c) or seen.has(c):
			continue
		if Vector2(c - center).length_squared() <= far_r2:
			continue
		seen[c] = true
		queue.append(c)
	if queue.is_empty():
		# 远侧边界全被山水/建筑占住，敌人本来也进不来。
		return true
	var dirs: Array = [
		Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
		Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
	]
	var head: int = 0
	while head < queue.size():
		var cur: Vector2i = queue[head]
		head += 1
		if inside.has(cur):
			return false
		for d in dirs:
			var n: Vector2i = cur + d
			if n.x < 0 or n.y < 0 or n.x >= sz or n.y >= sz:
				continue
			if seen.has(n) or edge_blocked.has(n) or extra.has(n):
				continue
			if d.x != 0 and d.y != 0:
				if edge_blocked.has(cur + Vector2i(d.x, 0)) or extra.has(cur + Vector2i(d.x, 0)) \
						or edge_blocked.has(cur + Vector2i(0, d.y)) or extra.has(cur + Vector2i(0, d.y)):
					continue
			seen[n] = true
			queue.append(n)
	return true

# 进度已经允许、但当前圈数还不够时，补规划下一圈。
# 新逻辑在 _manage_defense 里直接调用 _plan_wall_ring；这里保留兼容入口。
func _maybe_plan_outer_ring(castle) -> void:
	var wanted: int = _required_wall_ring_count(castle)
	if _wall_rings_planned < wanted:
		_plan_wall_ring(castle, _wall_rings_planned)

func _plan_defense_line(castle) -> bool:
	var dir: Vector3 = threat_dir
	dir.y = 0.0
	if dir.length_squared() < 0.01:
		dir = _enemy_castle_dir(castle)
	dir = dir.normalized()
	if dir.length_squared() < 0.01:
		dir = Vector3.FORWARD

	_defense_dir = dir
	_defense_queue.clear()
	_defense_slots.clear()
	wall_positions.clear()
	tower_positions.clear()

	# 首选封闭塔圈：一圈连续城墙把主城包住，水面/山崖/资源点当天然墙段，
	# 塔放在圈内。成功则不再只守朝敌方向的一条弧线。
	if _plan_castle_ring(castle, false):
		_defense_terrain_text = "塔圈"
		return true
	# 找不到完整闭合环时清掉半成品，退回隘口/弧线防线
	_defense_queue.clear()
	_defense_slots.clear()
	wall_positions.clear()
	tower_positions.clear()

	# 先找前方隘口/浅滩；找到后把整条防线转向该地形通道，墙线横在通道口
	_defense_anchor = _find_defense_anchor(castle, dir)
	if not _defense_anchor.is_empty():
		dir = _defense_anchor["dir"]
		_defense_terrain_text = "浅滩" if str(_defense_anchor["kind"]) == "ford" else "隘口"
	else:
		_defense_terrain_text = ""
	_defense_dir = dir

	# 内圈箭塔：固定角度优先；树/矿/水面占位时在附近找可用点
	var arrow_specs: Array = [
		{"angle": -0.58, "dist": 7.2},
		{"angle": 0.58, "dist": 7.2},
		{"angle": -1.02, "dist": 8.3},
		{"angle": 1.02, "dist": 8.3},
	]
	for spec in arrow_specs:
		var a: float = float(spec["angle"])
		var d: float = float(spec["dist"])
		var p: Vector3 = _find_defense_spot(castle, dir, a, d, 25, 9.8)
		if p != Vector3.ZERO:
			_add_defense_slot(25, p, 10.0 + absf(a) * 2.0, "tower")
	# 固定角度只落到 1 座以内时，补搜主城前方可用塔位
	if _count_planned(25) < 4:
		for a in [-1.3, -0.9, -0.3, 0.3, 0.9, 1.3, -1.6, 1.6, 0.0]:
			if _count_planned(25) >= 4:
				break
			var p2: Vector3 = _find_defense_spot(castle, dir, a, 8.4, 25, 9.8)
			if p2 != Vector3.ZERO:
				_add_defense_slot(25, p2, 11.0 + absf(a) * 2.0, "tower")

	# 有隘口/浅滩时，墙线横在通道上；否则回退到主城前方的外墙弧线
	var anchor_wall_count: int = 0
	if not _defense_anchor.is_empty():
		anchor_wall_count = _plan_anchor_defense(castle, _defense_anchor)
	if anchor_wall_count == 0:
		# 外墙弧线：先按空位最多的半径选弧线，再逐段微调避开树/矿
		var wall_radius: float = _pick_wall_radius(castle, dir)
		# 弧线上每段墙的中心距也要压在 1.5 以内（旧版固定 9 段 ≈ 2.38 米，
		# 段与段之间留着 0.38 米的缝，小兵能从缝里溜进城墙内侧）。
		var arc_step: float = 2.0 * asin(clampf(1.5 / (2.0 * wall_radius), 0.0, 1.0))
		var arc_walls: int = maxi(9, int(ceil(1.56 / maxf(arc_step, 0.001))) + 1)
		for i in range(arc_walls):
			var t: float = float(i) / float(arc_walls - 1)
			var wa: float = lerpf(-0.78, 0.78, t)
			var wp: Vector3 = _find_defense_spot(castle, dir, wa, wall_radius, 27, 16.0)
			if wp != Vector3.ZERO:
				_add_defense_slot(27, wp, 20.0 + absf(t - 0.5) * 6.0, "wall")

	for side in [-1.0, 1.0]:
		var ca: float = 0.34 * side
		var cp: Vector3 = _find_defense_spot(castle, dir, ca, 9.8, 26, 9.8)
		if cp != Vector3.ZERO:
			_add_defense_slot(26, cp, 32.0, "tower")
	# 炮塔也被占位时补搜：正面/侧面优先，实在不行再找背面空隙
	if _count_planned(26) < 2:
		for a in [-0.7, 0.7, 0.0, -1.0, 1.0, -1.4, 1.4, -1.8, 1.8, -2.2, 2.2, -2.6, 2.6, 3.14]:
			if _count_planned(26) >= 2:
				break
			var cp2: Vector3 = _find_defense_spot(castle, dir, a, 9.8, 26, 9.8)
			if cp2 != Vector3.ZERO:
				_add_defense_slot(26, cp2, 33.0, "tower")

	_defense_queue.sort_custom(func(a, b): return float(a["priority"]) < float(b["priority"]))
	return not _defense_queue.is_empty()

# 在一段弧线/半径附近寻找可建造点：先试原位置，再向内外、左右微调
func _find_defense_spot(castle, dir: Vector3, angle: float, dist: float, b_id: int, max_dist: float) -> Vector3:
	var cfg: Dictionary = EntityDatabase.get_config(b_id)
	if cfg.is_empty():
		return Vector3.ZERO
	var radius: float = float(cfg.get("body_radius", 1.0))
	for da in [0.0, 0.12, -0.12, 0.24, -0.24, 0.36, -0.36, 0.5, -0.5, 0.68, -0.68]:
		for dd in [0.0, 1.2, -1.2, 2.2, -2.2, 3.2, -3.2]:
			var try_dist: float = dist + float(dd)
			if try_dist < 5.0 or try_dist > max_dist:
				continue
			var p: Vector3 = castle.global_position + dir.rotated(Vector3.UP, angle + float(da)) * try_dist
			if not _is_valid_defense_ground(p, radius, true):
				continue
			if not _defense_slot_clear(p, radius, b_id):
				continue
			return p
	return Vector3.ZERO

func _pick_wall_radius(castle, dir: Vector3) -> float:
	var best_r: float = DEFENSE_WALL_RADIUS
	var best_n: int = -1
	for r in [DEFENSE_WALL_RADIUS, 13.6, 15.0, 11.0]:
		var n: int = 0
		for i in range(9):
			var t: float = float(i) / 8.0
			var wa: float = lerpf(-0.78, 0.78, t)
			var p: Vector3 = castle.global_position + dir.rotated(Vector3.UP, wa) * float(r)
			if _is_valid_defense_ground(p, 1.0, true) and _defense_slot_clear(p, 1.0, 27):
				n += 1
		if n > best_n:
			best_n = n
			best_r = float(r)
	return best_r

func _count_planned(b_id: int) -> int:
	var n: int = 0
	for s in _defense_slots:
		if int(s["id"]) == b_id:
			n += 1
	return n

# 环线上的墙点已经过地形/建筑校验，不再用通用间距规则二次过滤：
# 通用规则会为了避开资源/建筑把连续墙段拆开，反而留下缺口。
func _direct_add_defense_slot(b_id: int, pos: Vector3, priority: float, kind: String) -> void:
	_defense_slots.append({"id": b_id, "pos": pos})
	_defense_queue.append({"id": b_id, "pos": pos, "priority": priority, "tries": 0})
	if kind == "wall":
		wall_positions.append(pos)
	else:
		tower_positions.append({"id": b_id, "pos": pos})

func _defense_slot_clear(pos: Vector3, radius: float, b_id: int) -> bool:
	for s in _defense_slots:
		var cfg: Dictionary = EntityDatabase.get_config(int(s["id"]))
		var other_r: float = float(cfg.get("body_radius", 1.0))
		var min_sep: float = radius + other_r + 0.6
		# 城墙是一段接一段的，墙体之间可以贴得更近
		if b_id == 27 and int(s["id"]) == 27:
			min_sep = 0.9
		if (s["pos"] - pos).length() < min_sep:
			return false
	return true

func _add_defense_slot(b_id: int, pos: Vector3, priority: float, kind: String,
		ignore_armies: bool = false, require_vision: bool = true,
		require_flat: bool = false) -> bool:
	var cfg: Dictionary = EntityDatabase.get_config(b_id)
	if cfg.is_empty():
		return false
	var radius: float = float(cfg.get("body_radius", 1.0))
	# 防线塔位在规划阶段不受敌军距离影响；建好之后敌方靠近也不会把已有计划清空。
	# 山口防线在 30 米外时当前没有视野，先按 require_vision=false 规划，
	# 由优先建造的瞭望塔链在实际建造前把视野铺过去。
	if not _is_valid_defense_ground(pos, radius, true, ignore_armies,
			require_vision, require_flat):
		return false
	if not _defense_slot_clear(pos, radius, b_id):
		return false
	_defense_slots.append({"id": b_id, "pos": pos})
	_defense_queue.append({"id": b_id, "pos": pos, "priority": priority, "tries": 0})
	if kind == "wall":
		wall_positions.append(pos)
	else:
		tower_positions.append({"id": b_id, "pos": pos})
	return true

func _build_defense_step() -> void:
	if _defense_queue.is_empty():
		return
	var now: float = float(_ctx.game_time())
	if now < _defense_retry_at or now < _next_build_step:
		return
	_next_build_step = now + DEFENSE_BUILD_STEP_INTERVAL
	var built: int = 0
	var i: int = 0
	while i < _defense_queue.size() and built < DEFENSE_BUILD_MAX_PER_TICK:
		var item: Dictionary = _defense_queue[i]
		var b_id: int = int(item["id"])
		var b_pos: Vector3 = item["pos"]
		if _pos_has_building(b_id, b_pos):
			_defense_queue.remove_at(i)
			continue
		var cap: int = WALL_BUILD_CAP if b_id == 27 else 10
		if _count_bld(b_id) >= cap:
			_defense_queue.remove_at(i)
			continue
		# 墙的石耗按“一圈周长”设预算：超了就不再往墙上堆石头（实测有 AI 堆到 112 段，
		# 而其中 60% 以上的墙朝的方向本来就没封闭，纯粹浪费石头）。省下的钱给塔和补兵。
		# 塔没建满之前别把钱全砸在墙上：箭塔要 80 木 50 石，石头低于 80 就先攒着，
		# 否则队列里 8 个塔位永远缺石头（实测破防时塔只有 1 座，墙却有 21~38 段）。
		if b_id == 27:
			var towers_built: int = _count_bld(25) + _count_bld(26)
			if towers_built < MIN_TOWERS:
				var res_now: Dictionary = _res()
				if float(res_now.get("stone", 0)) < 80.0 or float(res_now.get("wood", 0)) < 110.0:
					i += 1
					continue
		if b_id == 27 and not _wall_ring_radii.is_empty():
			var max_rr: int = 0
			for r in _wall_ring_radii:
				max_rr = maxi(max_rr, int(r))
			if max_rr > 0 and wall_positions.size() >= _ring_wall_budget(null, max_rr):
				i += 1
				continue
		if not _build_port.can_build(b_id):
			break
		# 塔是防守火力支柱，不能因为“给补兵预留”的保留金被卡住：
		# 实测墙把资源花完后 _can_spend_building(25) 变 false，塔永远等不到钱。
		var reserve: float = 0.05 if b_id in TOWER_IDS else _defense_reserve()
		if not _can_spend_building(b_id, reserve):
			break
		# 没有空闲农民时不要把队列项当“失败”消耗掉，否则第一圈几十面墙
		# 会在农民还走在路上时就被全部移出队列，最后只立起三四面墙。
		if not _ctx.has_available_builder(b_pos):
			break
		else:
			var idle_builder = _ctx.nearest_idle_builder(
					_ctx.my_team(), _ctx.my_peer_id(), b_pos, 60.0) \
					if _ctx.battle_has_method("find_nearest_idle_builder") else null
			if idle_builder == null:
				break
		# 敌人临时站在山口、或瞭望塔链还没把视野铺到时，不要把这一个队列项
		# 当成“失败”消耗掉；等下一轮条件满足再建，否则山口防线会被敌人一次路过清空。
		if _enemy_army_near(b_pos):
			i += 1
			continue
		if not _defense_pos_visible(b_pos):
			i += 1
			continue
		var facing: Vector3 = _defense_dir if b_id in TOWER_IDS else Vector3.ZERO
		if _build_port.build(b_id, b_pos, facing):
			built += 1
			_defense_queue.remove_at(i)
			continue
		item["tries"] = int(item.get("tries", 0)) + 1
		if int(item["tries"]) >= 4:
			_defense_queue.remove_at(i)
			continue
		i += 1
		_defense_retry_at = now + 3.0
	if built > 0:
		_defense_retry_at = now + 0.5

func _queue_defense_gaps() -> void:
	for slot in _defense_slots:
		var b_id: int = int(slot["id"])
		var p: Vector3 = slot["pos"]
		if _pos_has_building(b_id, p):
			continue
		if _queue_has(b_id, p):
			continue
		_defense_queue.append({"id": b_id, "pos": p, "priority": 0.0, "tries": 0})
	_defense_queue.sort_custom(func(a, b): return float(a["priority"]) < float(b["priority"]))

func _queue_has(b_id: int, pos: Vector3) -> bool:
	for q in _defense_queue:
		if int(q["id"]) == b_id and (q["pos"] - pos).length() < 1.0:
			return true
	return false

func _pos_has_building(b_id: int, pos: Vector3) -> bool:
	# 用战斗管理器的建筑空间网格只查附近建筑，别再为每个墙位扫全图实体。
	if _ctx.battle_has_method("get_nearby_buildings"):
		for e in _ctx.nearby_buildings(pos, 1.2):
			if e is Building and e.health > 0 and int(e.entity_id) == b_id \
					and _belongs(e):
				if e.global_position.distance_to(pos) < 1.2:
					return true
		return false
	if _ctx.battle_has_method("get_nearby_entities"):
		for e in _ctx.nearby_entities(pos, 1.2):
			if e is Building and e.health > 0 and int(e.entity_id) == b_id \
					and _belongs(e):
				if e.global_position.distance_to(pos) < 1.2:
					return true
		return false
	for e in _ctx.entities_children():
		if e is Building and e.health > 0 and int(e.entity_id) == b_id and _belongs(e):
			if e.global_position.distance_to(pos) < 1.2:
				return true
	return false

# 不管环规划成不成功，都要保证主城周围至少有几座塔。
# 实测闭合判据收紧后“环规划失败”的 AI 会掉到 1 座塔，火力等于没有。
func _ensure_min_towers(castle) -> void:
	# 只认"已经建成的塔"：以前把队列里排着的也算进去，结果塔位排了 8 个、一块石头没花，
	# 保底逻辑以为够了就再也不补（实测破防时塔只有 1 座）。
	var built: int = _count_bld(25) + _count_bld(26)
	var planned: int = _count_planned(25) + _count_planned(26)
	if built >= MIN_TOWERS or planned > 0:
		return
	var now: float = float(_ctx.game_time())
	if now < 150.0 or now < _next_reactive_tower:
		return
	_next_reactive_tower = now + 22.0
	var base_dir: Vector3 = _defense_dir
	if base_dir.length_squared() < 0.01:
		base_dir = _enemy_castle_dir(castle)
	base_dir.y = 0.0
	if base_dir.length_squared() < 0.01:
		base_dir = Vector3.FORWARD
	base_dir = base_dir.normalized()
	# 塔贴墙外侧环形分布：射程覆盖整条墙线，而不是全挤在主城一个点。
	var ring_r: float = float(_castle_ring_radius)
	if ring_r < 8.0:
		ring_r = float(maxi(RING_MIN_RADIUS, 10))
	for i in range(8):
		var ang: float = TAU * float(i) / 8.0
		var dir: Vector3 = base_dir.rotated(Vector3.UP, ang)
		for off in [2.2, 1.0, 3.6, 5.0, -1.5]:
			var p: Vector3 = castle.global_position + dir * (ring_r + float(off))
			var spot: Vector3 = _find_anchor_spot(p, 25, 2.0)
			if spot == Vector3.ZERO:
				continue
			_add_defense_slot(25, spot, 0.35 + float(i) * 0.06, "tower", true, false, false)
			if _count_planned(25) + built >= MIN_TOWERS:
				_defense_queue.sort_custom(func(a, b): return float(a["priority"]) < float(b["priority"]))
				return
			break

func _maybe_reactive_tower(castle) -> void:
	if threat_level < 1:
		return
	var now: float = float(_ctx.game_time())
	if now < _next_reactive_tower:
		return
	_next_reactive_tower = now + 28.0
	var p: Vector3 = castle.global_position + threat_dir * 7.8
	if _own_tower_near(p, 9.0):
		return
	var ids: Array = [25]
	if threat_level >= 3:
		ids.append(26)
	for b_id in ids:
		if _count_bld(int(b_id)) >= (8 if int(b_id) == 25 else 4):
			continue
		if not _can_spend_building(int(b_id), _defense_reserve()):
			continue
		if _is_valid_defense_ground(p, float(EntityDatabase.get_config(int(b_id)).get("body_radius", 1.0))):
			_build_port.build(int(b_id), p, threat_dir)
			return

func _own_tower_near(pos: Vector3, radius: float) -> bool:
	for e in _ctx.entities_children():
		if e is Building and e.health > 0 and int(e.entity_id) in TOWER_IDS and _belongs(e):
			if e.global_position.distance_to(pos) < radius:
				return true
	return false

# ── 防守升级：只升级塔/墙，优先威胁方向 ──
func _manage_defense_upgrades(castle, delta: float) -> void:
	if not _clock.due("defense_upgrade"):
		return
	var now: float = float(_ctx.game_time())
	if threat_level == 0 and now < 240.0:
		return
	var towers: Array = []
	for e in _ctx.entities_children():
		if not (e is Building) or e.health <= 0:
			continue
		if not _belongs(e):
			continue
		if int(e.entity_id) not in TOWER_IDS:
			continue
		if not e.can_upgrade():
			continue
		if int(e.upgrade_level) >= int(castle.upgrade_level):
			continue
		if e.health < e.max_health * 0.45:
			continue
		towers.append(e)
	if towers.is_empty():
		return
	towers.sort_custom(func(a, b):
		return a.global_position.distance_squared_to(threat_center) < b.global_position.distance_squared_to(threat_center)
	)
	var reserve: float = 0.2 if threat_level >= 2 else 0.42
	for t in towers:
		var cost: Dictionary = t.get_upgrade_cost()
		if cost.is_empty():
			continue
		if not _can_spend(cost, reserve):
			continue
		if t.perform_upgrade(_ctx.battle_ref()):
			return

# ═══════════════════════════════════════════════════════════════
# 建筑被攻击 → 周围空闲部队反击
# ═══════════════════════════════════════════════════════════════

func _detect_building_attacks() -> void:
	var now: float = float(_ctx.game_time())
	var seen: Dictionary = {}
	var alerts: Array = []
	for e in _ctx.entities_children():
		if not (e is Building) or e.health <= 0:
			continue
		if int(e.team) == RTSConfig.Team.NEUTRAL:
			continue
		# 友方建筑包括自己的和同队玩家的建筑；敌方建筑不处理
		if _is_enemy_ent(e):
			continue
		var uid: int = e.get_instance_id()
		seen[uid] = true
		var prev: float = float(_building_health.get(uid, -1.0))
		_building_health[uid] = e.health
		if prev < 0.0 or e.health >= prev - 0.5:
			continue
		var attacker = e.get("_last_damager")
		# 远程弹丸/防御塔的 source 可能不是 Army，兜底找建筑周围最近的可战斗敌军
		if not _is_combat_enemy(attacker):
			var alert_radius: float = CASTLE_DEFENSE_RADIUS if int(e.entity_id) == CASTLE_ID else BUILDING_DEFENSE_RADIUS
			attacker = _nearest_enemy_combat(e.global_position, alert_radius)
		if attacker == null:
			continue
		alerts.append({"building": e, "attacker": attacker})
	# 同一帧多个建筑受袭时，先保主城，再保军事建筑，最后才保经济建筑，
	# 避免附近有限的空闲部队被边缘建筑先抽空。
	alerts.sort_custom(func(a, b):
		return _building_defense_priority(a["building"]) < _building_defense_priority(b["building"])
	)
	for alert in alerts:
		_send_building_defenders(alert["building"], alert["attacker"], now)
	# 清理已消失建筑的旧血量，防止 instance_id 复用造成误判
	for uid in _building_health.keys():
		if not seen.has(uid):
			_building_health.erase(uid)

func _building_defense_priority(building) -> int:
	if building == null or not is_instance_valid(building):
		return 9
	if int(building.entity_id) == CASTLE_ID:
		return 0
	if int(building.entity_id) in MILITARY_BUILDING_IDS:
		return 1
	return 2

func _send_building_defenders(building, attacker, now: float) -> void:
	if building == null or not is_instance_valid(building):
		return
	if attacker == null or not is_instance_valid(attacker) or attacker.health <= 0:
		return
	var is_castle: bool = int(building.entity_id) == CASTLE_ID
	var radius: float = CASTLE_DEFENSE_RADIUS if is_castle else BUILDING_DEFENSE_RADIUS
	var max_responders: int = CASTLE_DEFENSE_MAX if is_castle else BUILDING_DEFENSE_MAX
	var candidates: Array = []
	for u in _land_combat_units():
		if not is_instance_valid(u) or u.health <= 0:
			continue
		if u.global_position.distance_to(building.global_position) > radius:
			continue
		# 只调动真正空闲的部队；已有目标、移动/攻击移动、排队命令的部队不打断
		if u.current_target != null and is_instance_valid(u.current_target):
			continue
		if u.is_attack_moving or u.current_order != "" or not u.command_queue.is_empty():
			continue
		if _is_local_building_defender(u, now):
			continue
		# 攻击者可能在船上/墙上，近战或不会对空的兵种去了也打不到，
		# 不要把名额和回防标记浪费在无法攻击的目标上。
		if u.has_method("_can_attack_target") and not u._can_attack_target(attacker):
			continue
		if u.has_method("_is_target_attackable_now") and not u._is_target_attackable_now(attacker):
			continue
		candidates.append(u)
	# 距离最近的先响应，并限制单座建筑抽兵数量；主城威胁可多派一些。
	candidates.sort_custom(func(a, b):
		return a.global_position.distance_squared_to(building.global_position) < b.global_position.distance_squared_to(building.global_position)
	)
	var sent: int = 0
	for u in candidates:
		if sent >= max_responders:
			break
		# 非驻扎单位的原锚点=接到命令时的位置；目标死亡/超时后回这里，
		# 避免建筑防守部队被一路带到地图另一头。上一次回防的 meta 已过期时
		# 要刷新锚点，否则会把它送回上一座建筑附近。
		var prev_defense_until: float = -1.0
		if u.has_meta("ai_building_defense_until"):
			prev_defense_until = float(u.get_meta("ai_building_defense_until"))
		if u._defense_return_position == Vector3.ZERO or prev_defense_until <= now:
			u._defense_return_position = u.global_position
		# 驻扎中的部队也可以回防“自己附近的建筑”，这是防守例外；
		# 但给它一个短标记，防止同一帧后续守军调度把它重新拉回主城。
		u.set_meta("ai_building_defense_until", now + BUILDING_DEFENSE_HOLD)
		if u.has_method("attack_target"):
			u.attack_target(attacker)
		else:
			u.current_target = attacker
			u.current_order = "attack"
		sent += 1

func _is_local_building_defender(u, now: float) -> bool:
	if u == null or not is_instance_valid(u):
		return false
	return u.has_meta("ai_building_defense_until") and now < float(u.get_meta("ai_building_defense_until"))

# ═══════════════════════════════════════════════════════════════
# 守军调度
# ═══════════════════════════════════════════════════════════════

func _defense_mode_active() -> bool:
	if threat_level >= 2:
		return true
	if ai != null and float(_ctx.game_time()) < _force_guard_until:
		return true
	if true:
		return bool(_is_defending_v())
	return false

# 判断“防守回撤”时是否应跳过该单位：
# 已经在主城 25 单位内、并且正有攻击目标，说明它正在家门口交战，不能被召回换目标。
func _skip_near_castle_active(unit, castle) -> bool:
	if unit == null or not is_instance_valid(unit) or castle == null or not is_instance_valid(castle):
		return false
	if unit.global_position.distance_squared_to(castle.global_position) > DEFENSE_RECALL_SAFE_RADIUS * DEFENSE_RECALL_SAFE_RADIUS:
		return false
	var target = unit.current_target
	return target != null and is_instance_valid(target)

# 城墙优先保留远程兵：守墙逻辑每 30 秒才巡检一次，守军快速补员
# 不能在这之前把刚生产出来的远程兵全部收进主城，否则城墙会长期空着。
func _has_valid_walls() -> bool:
	for b in _ctx.entities_children():
		if b is Building and int(b.entity_id) == 27 and b.health > 0 and b.build_timer <= 0.0 \
				and _belongs(b):
			return true
	return false

func _reserve_ranged_for_wall(unit, walls_exist: bool) -> bool:
	if not walls_exist or unit == null or not is_instance_valid(unit):
		return false
	if not _ranged_wall_ok(unit):
		return false
	return true

func _manage_home_guard(castle, delta: float) -> void:
	if not _clock.due("guard"):
		return
	_prune_guard_ids()

	var own: Array = _land_combat_units()
	if own.is_empty():
		return
	var now: float = float(_ctx.game_time())
	var is_defending: bool = _defense_mode_active()
	var walls_exist: bool = _has_valid_walls()
	var desired: int = 0
	if not is_defending and now < _guard_block_until:
		desired = 0
	elif now < _force_guard_until:
		desired = own.size()
	else:
		match threat_level:
			0:
				desired = mini(own.size(), HOME_GUARD_COUNT)
			1:
				desired = mini(own.size(), HOME_GUARD_COUNT)
			2:
				desired = mini(own.size(), maxi(6, threat_enemy_count * 2 + 2))
			_:
				desired = own.size()
	desired = mini(desired, own.size())

	# 家门口已有目标、正在交战的部队算作有效防守力量，不重复从远处抽兵填补名额
	if is_defending:
		var active_near: int = 0
		for u in own:
			if _skip_near_castle_active(u, castle):
				active_near += 1
				var active_uid: int = u.get_instance_id()
				if _home_guard_ids.has(active_uid):
					_release_guard(active_uid)
		desired = maxi(0, desired - active_near)

	# 第 5 阶段：优先按守军分配器的建议顺序选兵（先保留现有守军，再按威胁扇区
	# 选候选）；分配器不可用时退回原来的“离主城最近”排序。后面的任务/兵种/
	# 城墙保留过滤仍然保留，所以不会抢走正在交战的部队。
	var preferred: Array = []
	if _force_allocator != null:
		preferred = _force_allocator.get_preferred_ids()
	var preferred_rank: Dictionary = {}
	for i in range(preferred.size()):
		preferred_rank[int(preferred[i])] = i
	own.sort_custom(func(a, b):
		var ar: int = int(preferred_rank.get(a.get_instance_id(), 999999))
		var br: int = int(preferred_rank.get(b.get_instance_id(), 999999))
		if ar != br:
			return ar < br
		return a.global_position.distance_squared_to(castle.global_position) < b.global_position.distance_squared_to(castle.global_position)
	)
	var rally: Vector3 = _guard_rally(castle)
	var assigned: int = 0
	for u in own:
		if assigned >= desired:
			break
		if not is_instance_valid(u) or u.health <= 0:
			continue
		if _is_local_building_defender(u, now):
			continue
		# 非防守状态不再调动已有驻扎点的部队；自己的常驻守军已在 _home_guard_ids 中，
		# 允许继续刷新集结点，不会因此被重复招募或丢失。
		var uid: int = u.get_instance_id()
		if not is_defending and u.garrison_point != Vector3.ZERO and not _home_guard_ids.has(uid):
			continue
		if is_defending and _skip_near_castle_active(u, castle):
			# 家门口正在交战的部队保留当前目标；驻扎点已在前面统一解除
			continue
		# 守卫主城只给没有任务的部队下达指令：正在交战、攻击移动、采集/交付、
		# 排队执行命令或已经驻扎的部队继续做自己的事，不能被守军调度打断。
		if _unit_has_existing_task(u):
			continue
		# 城墙优先保留远程兵；已经在守军名单里的单位不受影响。
		# 紧急回防（_force_guard_until）期间不再保留，所有能回的单位都要回主城。
		if not _home_guard_ids.has(uid) and threat_level < 2 and now >= _force_guard_until \
				and _reserve_ranged_for_wall(u, walls_exist):
			continue
		var special: bool = u.has_meta("ai_resource_guard") or u.has_meta("ai_harass")
		if special and threat_level < 3 and now >= _force_guard_until:
			continue
		if special:
			_clear_special_role(u)
		_assign_guard(u, rally)
		assigned += 1

	# 威胁解除/守军超编时释放距离主城最远的守军
	var extra: Array = []
	for uid in _home_guard_ids.keys():
		if _home_guard_ids.size() - extra.size() <= desired:
			break
		var u = instance_from_id(int(uid))
		if u == null or not is_instance_valid(u) or not (u is Army) or u.health <= 0:
			_home_guard_ids.erase(uid)
			continue
		extra.append({"id": int(uid), "d": u.global_position.distance_squared_to(castle.global_position)})
	extra.sort_custom(func(a, b): return float(a["d"]) > float(b["d"]))
	for item in extra:
		_release_guard(int(item["id"]))

# 主城守军每 2 秒做一次轻量补员：守卫阵亡/被调走时不必等满一分钟审计。
# 数量/威胁等级变化仍由每 60 秒的 _manage_home_guard 完整审计处理。
func _quick_fill_home_guard(castle, delta: float) -> void:
	if not _clock.due("guard_refill"):
		return
	if _clock.remaining("guard") <= 0.0:
		return
	if threat_level >= 2:
		# 进入防守/危急时立刻走完整守军调度，不等一分钟。
		_clock.reset("guard", 0.0)
		_manage_home_guard(castle, 0.0)
		return
	_prune_guard_ids()
	if threat_level < 2 and float(_ctx.game_time()) < _guard_block_until:
		return
	if _home_guard_ids.size() >= HOME_GUARD_COUNT:
		return
	var own: Array = _land_combat_units()
	if own.is_empty():
		return
	var walls_exist: bool = _has_valid_walls()
	own.sort_custom(func(a, b):
		return a.global_position.distance_squared_to(castle.global_position) < b.global_position.distance_squared_to(castle.global_position)
	)
	var rally: Vector3 = _guard_rally(castle)
	# 守军规模随威胁扩编：固定 5 个在“32 个敌人压境”时明显不够，
	# 最多补到 18 个（大约一支满编前排），威胁消退后再自动回落。
	var guard_cap: int = mini(HOME_GUARD_COUNT + int(threat_enemy_count) * 2, 18)
	for u in own:
		if _home_guard_ids.size() >= guard_cap:
			break
		if not is_instance_valid(u) or u.health <= 0:
			continue
		if u.global_position.distance_to(castle.global_position) > HOME_GUARD_REFILL_RADIUS:
			# own 已按距离排序，后面的只会更远。
			break
		if u.has_meta("ai_home_guard") or u.has_meta("ai_wall_guard"):
			continue
		# 补员同样只挑没有任务的部队，避免把正在交战/行军/采集/排队的部队拉回主城。
		if _unit_has_existing_task(u):
			continue
		if _is_local_building_defender(u, float(_ctx.game_time())):
			continue
		if _reserve_ranged_for_wall(u, walls_exist) \
				and float(_ctx.game_time()) >= _force_guard_until:
			continue
		_assign_guard(u, rally)

# 主攻前调用：解除主城守军的驻扎，避免 attack_move 被 garrison_point 拉回主城
func release_guards_for_attack() -> void:
	_force_guard_until = -999.0
	_clock.reset("guard", 0.0)
	# 解除后 20 秒内不再抓人：否则 2 秒一次的守军快补马上又把同一批兵抓回主城，
	# 主攻刚放出去的人又被 garrison_point 卡住，等于没解锁。
	_guard_block_until = float(_ctx.game_time()) + 20.0
	for uid in _home_guard_ids.keys():
		_release_guard(int(uid))
	_home_guard_ids.clear()

func _assign_home_guard(castle, force: bool) -> void:
	var own: Array = _land_combat_units()
	if own.is_empty():
		return
	var is_defending: bool = _defense_mode_active()
	var rally: Vector3 = _guard_rally(castle)
	var desired: int = own.size() if force else mini(own.size(), maxi(HOME_GUARD_COUNT, threat_enemy_count * 2 + 2))
	if is_defending:
		var active_near: int = 0
		for u in own:
			if _skip_near_castle_active(u, castle):
				active_near += 1
				var active_uid: int = u.get_instance_id()
				if _home_guard_ids.has(active_uid):
					_release_guard(active_uid)
		desired = maxi(0, desired - active_near)
	var assigned: int = 0
	own.sort_custom(func(a, b):
		return a.global_position.distance_squared_to(castle.global_position) < b.global_position.distance_squared_to(castle.global_position)
	)
	for u in own:
		if assigned >= desired:
			break
		if not is_instance_valid(u) or u.health <= 0:
			continue
		if _is_local_building_defender(u, float(_ctx.game_time())):
			continue
		# 强制回防也只动没有任务的部队；正在执行任务的主力继续自己的行动。
		if _unit_has_existing_task(u):
			continue
		if is_defending and _skip_near_castle_active(u, castle):
			continue
		if force or threat_level >= 3:
			_clear_special_role(u)
		elif u.has_meta("ai_resource_guard") or u.has_meta("ai_harass"):
			continue
		_assign_guard(u, rally)
		assigned += 1

func _guard_rally(castle) -> Vector3:
	var dir: Vector3 = threat_dir
	if threat_level == 0:
		dir = _enemy_castle_dir(castle)
	dir.y = 0.0
	if dir.length_squared() < 0.01:
		dir = Vector3.FORWARD
	var p: Vector3 = castle.global_position + dir.normalized() * 5.5
	var gx: int = int(p.x + RTSConfig.MAP_SIZE / 2.0)
	var gz: int = int(p.z + RTSConfig.MAP_SIZE / 2.0)
	if gx < 0 or gx >= RTSConfig.MAP_SIZE or gz < 0 or gz >= RTSConfig.MAP_SIZE:
		return castle.global_position
	if _ctx.terrain_at_grid(gx, gz) != 0:
		return castle.global_position + Vector3(3.0, 0.0, 3.0)
	return p

func _assign_guard(unit, rally: Vector3) -> void:
	var uid: int = unit.get_instance_id()
	var is_new: bool = not unit.has_meta("ai_home_guard")
	_home_guard_ids[uid] = true
	unit.set_meta("ai_home_guard", true)
	_cmd_port.claim(unit, ROLE_HOME_GUARD, 60.0)
	# 驻军点只为“新守军/换了集结点”更新，避免每 0.8 秒重建一次旗帜标记
	if is_new or unit.garrison_point.distance_to(rally) > 1.0:
		unit.set_garrison(rally)
	if unit.global_position.distance_to(rally) > 4.0 and unit.current_order != "move":
		unit.move_to(rally)

func _release_guard(uid: int) -> void:
	_home_guard_ids.erase(uid)
	_cmd_port.release(uid)
	var u = instance_from_id(uid)
	if u == null or not is_instance_valid(u):
		return
	if u.has_meta("ai_home_guard"):
		u.remove_meta("ai_home_guard")
	u.garrison_point = Vector3.ZERO
	if u.has_method("_hide_garrison_marker"):
		u.call("_hide_garrison_marker")

func _prune_guard_ids() -> void:
	for uid in _home_guard_ids.keys():
		var u = instance_from_id(int(uid))
		if u == null or not is_instance_valid(u) or not (u is Army) or u.health <= 0 \
				or not u.has_meta("ai_home_guard"):
			_home_guard_ids.erase(uid)

func _clear_special_role(unit) -> void:
	if unit.has_meta("ai_harass"):
		unit.remove_meta("ai_harass")
	if unit.has_meta("ai_resource_guard"):
		unit.remove_meta("ai_resource_guard")
	_resource_guard_ids.erase(unit.get_instance_id())

func _land_combat_units() -> Array:
	var out: Array = []
	for e in _ctx.entities_children():
		if not (e is Army) or e.health <= 0:
			continue
		if not _belongs(e):
			continue
		if int(e.target_type) <= 0:
			continue
		if int(e.entity_id) in [10, 14, 43, 44, 45, 46, 47, 48, 49, 50, 51]:
			continue
		# 侦察兵由 AI 的探图逻辑单独调度，不参与守军/资源守卫。
		if int(e.entity_id) == 19:
			continue
		if e.water_capable:
			continue
		# 正在登船/坐船渡水的单位由 AIWaterCrossing 管理，不能被守军调度拉回
		if e.has_meta("ai_transporting"):
			continue
		# 固定在城墙上的远程单位由 AI 的守墙逻辑管理，不能再被守军调度拉走
		if e.has_meta("ai_wall_guard"):
			continue
		var boarded = e.get("_boarded_on")
		if boarded != null and int(boarded) != -1:
			continue
		var sgb = e.get("_soldier_garrison_building")
		if sgb != null and sgb.get_ref() != null:
			continue
		out.append(e)
	return out

# 是否已有目标/正在执行任务：这类部队不应被资源守军调度拉走
# 包括追击/攻击目标、移动/攻击移动/采集/交付中、有排队指令、已驻扎在其他据点的部队
func _unit_has_existing_task(u) -> bool:
	if u.current_target != null and is_instance_valid(u.current_target):
		return true
	if u.is_attack_moving or u.current_order != "":
		return true
	if not u.command_queue.is_empty():
		return true
	if u.garrison_point != Vector3.ZERO:
		return true
	return false

# ═══════════════════════════════════════════════════════════════
# 资源区控制
# ═══════════════════════════════════════════════════════════════

func _manage_resource_security(castle, delta: float) -> void:
	if not _clock.due("resource"):
		return
	if _clock.due("zone"):
		_refresh_resource_zones(castle)
	_defend_resources(castle)
	_maybe_build_outpost(castle)

func _refresh_resource_zones(castle) -> void:
	var clusters: Array = []
	for w in _ctx.entities_children():
		if not (w is Army) or w.health <= 0 or not _belongs(w):
			continue
		if int(w.entity_id) != 10:
			continue
		var tgt = w.current_target
		if tgt == null or not is_instance_valid(tgt) or not (tgt is WorldResource):
			continue
		if tgt.health <= 0:
			continue
		var p: Vector3 = tgt.global_position
		var found = null
		for c in clusters:
			if c["center"].distance_to(p) < 10.0:
				found = c
				break
		if found == null:
			found = {"center": p, "sum": Vector3.ZERO, "workers": 0, "nodes": {}, "type": String(tgt.resource_type)}
			clusters.append(found)
		found["sum"] += p
		found["workers"] = int(found["workers"]) + 1
		found["center"] = found["sum"] / float(found["workers"])
		found["nodes"][tgt.get_instance_id()] = true

	var zones: Array = []
	for c in clusters:
		var center: Vector3 = c["center"]
		var dist: float = center.distance_to(castle.global_position)
		if dist > 62.0:
			continue
		var score: float = float(c["workers"]) * 2.0 + minf(dist / 18.0, 3.0)
		if String(c["type"]) in ["gold", "stone"]:
			score += 0.6
		if dist > 24.0:
			score += 1.0
		zones.append({
			"center": center,
			"type": String(c["type"]),
			"workers": int(c["workers"]),
			"nodes": c["nodes"],
			"dist": dist,
			"score": score,
			"enemy_count": 0,
		})
	zones.sort_custom(func(a, b): return float(a["score"]) > float(b["score"]))
	resource_zones = zones.slice(0, 3)

func _defend_resources(castle) -> void:
	var now: float = float(_ctx.game_time())
	var workers: Array = []
	for w in _ctx.entities_children():
		if w is Army and w.health > 0 and int(w.entity_id) == 10 and _belongs(w):
			workers.append(w)

	# 1) 农民避险：只有敌人贴到 8m 才短暂躲避，往远离敌人的方向挪 6m，
	#    不再把所有农民都召回主城；防守状态下资源采集也尽量保持。
	for w in workers:
		# 第 4 阶段起农民逃跑由 WorkerDirector 接管，避免两套逻辑每帧互相推目标。
		if true:
			continue
		var danger = _nearest_enemy_combat(w.global_position, WORKER_FLEE_RADIUS)
		if danger:
			# 已经在躲避中就不要每 1.5 秒重复改目标，否则农民会被一路推着跑
			if w.has_meta("ai_flee_until") and now < float(w.get_meta("ai_flee_until")):
				continue
			w.set_meta("ai_flee_until", now + WORKER_FLEE_TIME)
			var has_cargo: bool = false
			for rk in ["gold", "wood", "stone", "food", "oil"]:
				if int(w.cargo.get(rk, 0)) > 0:
					has_cargo = true
					break
			if has_cargo:
				# 有货物时按正常经济逻辑去交付，不强行把它押回主城
				if w.current_order != "deliver" and w.current_order != "move":
					if w.has_method("_return_to_deliver"):
						w.call("_return_to_deliver")
			elif w.current_order != "move":
				var away: Vector3 = w.global_position - danger.global_position
				away.y = 0.0
				if away.length_squared() < 0.01:
					away = Vector3.RIGHT
				var flee_pos: Vector3 = w.global_position + away.normalized() * WORKER_FLEE_DISTANCE
				var half_limit: float = RTSConfig.MAP_SIZE / 2.0 - 3.0
				flee_pos.x = clampf(flee_pos.x, -half_limit, half_limit)
				flee_pos.z = clampf(flee_pos.z, -half_limit, half_limit)
				w.move_to(flee_pos)
		elif w.has_meta("ai_flee_until") and now >= float(w.get_meta("ai_flee_until")):
			w.remove_meta("ai_flee_until")

	# 2) 选出最危险的资源区
	var hot_zone = null
	var hot_enemies: int = 0
	for z in resource_zones:
		var ec: int = _count_enemy_combat_near(z["center"], 17.0)
		z["enemy_count"] = ec
		if ec > hot_enemies:
			hot_enemies = ec
			hot_zone = z
	if hot_zone == null:
		# 资源区刷新有 12 秒间隔；若有农民已经挨打，用农民位置临时兜底
		for w in workers:
			var danger = _nearest_enemy_combat(w.global_position, 13.0)
			if danger:
				hot_zone = {"center": w.global_position, "workers": 1, "type": "emergency", "enemy_count": 1}
				hot_enemies = 1
				break

	if hot_zone != null:
		_resource_guard_hold_until = now + RESOURCE_GUARD_HOLD
		var needed: int = mini(3, maxi(1, hot_enemies))
		_prune_resource_guards()
		var guards: Array = []
		for uid in _resource_guard_ids.keys():
			var u = instance_from_id(int(uid))
			if u != null and is_instance_valid(u) and u is Army and u.health > 0:
				guards.append(u)
		if guards.size() < needed:
			var candidates: Array = []
			for u in _land_combat_units():
				if u.has_meta("ai_home_guard") or u.has_meta("ai_harass"):
					continue
				# 已有目标/正在执行任务的部队保持原命令，不拉来守资源
				if _unit_has_existing_task(u):
					continue
				if _resource_guard_ids.has(u.get_instance_id()):
					continue
				var d: float = u.global_position.distance_to(hot_zone["center"])
				if d > 45.0 and u.global_position.distance_to(castle.global_position) > 25.0:
					continue
				candidates.append({"u": u, "d": d})
			candidates.sort_custom(func(a, b): return float(a["d"]) < float(b["d"]))
			for item in candidates:
				if guards.size() >= needed:
					break
				var u = item["u"]
				_resource_guard_ids[u.get_instance_id()] = true
				u.set_meta("ai_resource_guard", true)
				_cmd_port.claim(u, ROLE_RESOURCE_GUARD, 45.0)
				u.set_garrison(hot_zone["center"])
				if u.global_position.distance_to(hot_zone["center"]) > 5.0:
					u.move_to(hot_zone["center"])
				guards.append(u)
		else:
			# 资源区转移时，让已有卫队跟随新位置
			for u in guards:
				if u.global_position.distance_to(hot_zone["center"]) > 12.0:
					u.set_garrison(hot_zone["center"])
					u.move_to(hot_zone["center"])
	elif now >= _resource_guard_hold_until:
		_prune_resource_guards()
		for uid in _resource_guard_ids.keys():
			var u = instance_from_id(int(uid))
			_resource_guard_ids.erase(uid)
			if u != null and is_instance_valid(u) and u is Army:
				if u.has_meta("ai_resource_guard"):
					u.remove_meta("ai_resource_guard")
				u.garrison_point = Vector3.ZERO
				if u.has_method("_hide_garrison_marker"):
					u.call("_hide_garrison_marker")

func _prune_resource_guards() -> void:
	for uid in _resource_guard_ids.keys():
		var u = instance_from_id(int(uid))
		if u == null or not is_instance_valid(u) or not (u is Army) or u.health <= 0:
			_resource_guard_ids.erase(uid)

func _own_outpost_near(pos: Vector3, radius: float) -> bool:
	for e in _ctx.entities_children():
		if e is Building and e.health > 0 and int(e.entity_id) == OUTPOST_ID and _belongs(e):
			if e.global_position.distance_to(pos) < radius:
				return true
	return false

func _maybe_build_outpost(castle) -> void:
	var now: float = float(_ctx.game_time())
	if now < _next_outpost:
		return
	_next_outpost = now + OUTPOST_INTERVAL
	if _watchtower_total() >= WATCHTOWER_CAP:
		return
	if _resource_watchtower_count() >= WATCHTOWER_RESOURCE_MAX:
		return
	var best = null
	var best_score: float = 0.0
	for z in resource_zones:
		if int(z["workers"]) < 2:
			continue
		if float(z["dist"]) < 22.0 or float(z["dist"]) > 58.0:
			continue
		if int(z.get("enemy_count", 0)) > 0:
			continue
		if _own_outpost_near(z["center"], 12.0):
			continue
		var score: float = float(z["workers"]) * 2.0 + float(z["dist"]) / 20.0
		if score > best_score:
			best_score = score
			best = z
	if best == null:
		return
	if not _can_spend_building(OUTPOST_ID, 0.4):
		return
	var spot: Vector3 = _pick_watchtower_spot(best["center"], [5.0, 7.0, 9.0, 11.0],
			12, best["center"], "resource", true, true)
	if spot == Vector3.ZERO:
		return
	if _build_port.build(OUTPOST_ID, spot):
		watchtower_positions.append(spot)

# ═══════════════════════════════════════════════════════════════
# 通用判定
# ═══════════════════════════════════════════════════════════════

func _is_valid_defense_ground(pos: Vector3, radius: float = 1.0,
		allow_under_fire: bool = false, ignore_armies: bool = false,
		require_vision: bool = true, require_flat: bool = false) -> bool:
	var half: float = RTSConfig.MAP_SIZE / 2.0
	if absf(pos.x) >= half - 2.0 or absf(pos.z) >= half - 2.0:
		return false
	var gx: int = int(pos.x + half)
	var gz: int = int(pos.z + half)
	if gx < 0 or gx >= RTSConfig.MAP_SIZE or gz < 0 or gz >= RTSConfig.MAP_SIZE:
		return false
	if _ctx.terrain_at_grid(gx, gz) != 0:
		return false
	# 山口/山脊边缘常见“中心格是平地、脚下实际是斜坡”的位置；
	# 建造校验 _can_place_ai_building 会检查平整度，规划阶段先过滤掉，避免反复失败。
	if require_flat and _ctx.battle_has_method("_is_terrain_flat"):
		if not _ctx.is_terrain_flat(pos, maxf(0.5, radius * 0.5)):
			return false
	for e in _ctx.entities_children():
		if not (e is GameEntity) or e.health <= 0:
			continue
		var d: float = e.global_position.distance_to(pos)
		if e is WorldResource:
			if d < radius + 1.8:
				return false
		elif e is Building:
			if d < radius + float(e.body_radius) + 0.8:
				return false
		elif e is Army:
			# 规划防线时不要被部队挡住：部队会移动，建造失败还有补建队列。
			# 塔圈规划时连敌方军队也跳过，避免敌人临时站在环线上导致整圈规划被否。
			if ignore_armies:
				continue
			if allow_under_fire and _belongs(e):
				continue
			if d < radius + float(e.body_radius) + 0.5:
				return false
	if not allow_under_fire:
		for e in _ctx.visible_enemies():
			if not is_instance_valid(e) or not (e is Army or e is Building) or e.health <= 0:
				continue
			if not _is_enemy_ent(e):
				continue
			if e.global_position.distance_to(pos) < 5.0:
				return false
	if require_vision and not _has_friendly_vision(pos):
		return false
	return true

func _has_friendly_vision(pos: Vector3) -> bool:
	# 主城默认视野 10m，而外墙在 12m 外；先按“防线包络”允许规划，
	# 实际建造时前面几座箭塔会提供视野，build_building 仍会做最终校验。
	var castle = _castle()
	if castle != null and castle.global_position.distance_to(pos) <= 18.0:
		return true
	for e in _ctx.entities_children():
		if e is GameEntity and e.health > 0 and _belongs(e):
			if e.global_position.distance_to(pos) <= float(e.vision_range):
				return true
	return false

# 和 AI.build_building 的实际建造视野校验保持一致：
# 只认已存在己方实体的视野，不使用规划用的 18 米城堡包络。
func _defense_pos_visible(pos: Vector3) -> bool:
	var world_pos := Vector3(pos.x, 0.0, pos.z)
	# 只查附近实体；己方最远视野 25 米，不需要为每个墙位遍历全图。
	if _ctx.battle_has_method("get_nearby_entities"):
		for e in _ctx.nearby_entities(world_pos, DEFENSE_VISION_QUERY_RADIUS):
			if e is GameEntity and e.health > 0 and _belongs(e):
				if e.global_position.distance_to(world_pos) <= float(e.vision_range):
					return true
		return false
	for e in _ctx.entities_children():
		if e is GameEntity and e.health > 0 and _belongs(e):
			if e.global_position.distance_to(world_pos) <= float(e.vision_range):
				return true
	return false

func _can_spend_building(b_id: int, reserve_ratio: float) -> bool:
	var cfg: Dictionary = EntityDatabase.get_config(b_id)
	if cfg.is_empty():
		return false
	var cost: Dictionary = cfg.get("cost", {})
	return _can_spend(cost, reserve_ratio)

func _can_spend(cost: Dictionary, reserve_ratio: float) -> bool:
	var res: Dictionary = _res()
	var limits: Dictionary = _limits()
	for k in cost:
		var need: float = float(cost[k])
		if float(res.get(k, 0)) < need:
			return false
		var limit: float = maxf(float(limits.get(k, 500)), 1.0)
		if float(res.get(k, 0)) - need < limit * reserve_ratio:
			return false
	return true

func _defense_reserve() -> float:
	# 第 3 阶段：预算规则已迁到 DefenseDirector；直接按当前威胁等级取同口径值。
	# 防守建设/升级必须先留出一部分资源给补兵，否则 AIDefense 在 AI 生产之前把资源花光，
	# 就会出现“进入防守后不再生产军队”的情况。
	if _defense_director == null:
		return 0.35
	return _defense_director.reserve_for_level(threat_level)

func _nearest_enemy_combat(pos: Vector3, radius: float):
	var best = null
	var best_d: float = radius
	for e in _ctx.visible_enemies():
		if not _is_combat_enemy(e):
			continue
		var d: float = e.global_position.distance_to(pos)
		if d < best_d:
			best_d = d
			best = e
	return best

func _count_enemy_combat_near(pos: Vector3, radius: float) -> int:
	var n: int = 0
	for e in _ctx.visible_enemies():
		if not _is_combat_enemy(e):
			continue
		if e.global_position.distance_to(pos) <= radius:
			n += 1
	return n

# ── A2 收尾：剩余读取的上下文包装（未绑定时回落控制器，A3 之后删除回落）──
func _castle():
	return _ctx.castle()

func _team_castle(team: int):
	return _ctx.team_castle_of(team)

func _res() -> Dictionary:
	return _ctx.resources()

func _limits() -> Dictionary:
	return _ctx.limits()

func _is_defending_v() -> bool:
	return _ctx.is_defending()

func _primary_team() -> int:
	return _ctx.primary_enemy_team()

func _ranged_wall_ok(unit) -> bool:
	return _ctx.is_ranged_wall_candidate(unit)

func _enemy_army_near(pos: Vector3, radius: float = -1.0) -> bool:
	if radius < 0.0:
		if _ctx != null:
			return _ctx.enemy_army_within(pos, 10.0)
		return _ctx.enemy_army_within(pos, 10.0)
	return _ctx.enemy_army_within(pos, radius)

func _afford(id: int) -> bool:
	return _ctx.can_afford(id)

func _afford_bld(id: int) -> bool:
	return _ctx.can_afford_building(id)

func _afford_upg(id: int) -> bool:
	return _ctx.can_afford_upgrade(id)
func _now() -> float:
	return _ctx.game_time() if _ctx != null else float(_ctx.game_time())


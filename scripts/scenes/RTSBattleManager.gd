class_name RTSBattleManager
extends Node3D
const BattleStatsScript = preload("res://scripts/core/BattleStats.gd")
# 强制走程序化攻击动作的兵种：模型即使自带 attack 动画幅度也太小，看不出来
const PROC_ATTACK_IDS = [18, 16, 17, 59, 13, 39]
# 开火时需要在炮口喷烟尘火光的建筑/炮台（攻城器械由 SiegeAttackFx 单独处理）
const MUZZLE_ATTACK_IDS = [25, 26, 64]
# 城墙模型 wall.glb 的原始顶面高度：模型底面在局部 y=0、原始顶面在 1.31。
# 生成时模型还会按 body_radius 自动缩放，所以实际站墙高度必须用
# get_wall_top_height() 按每面墙的模型实例计算，不能直接加这个常量。
const WALL_TOP_HEIGHT: float = 1.31
# 放置炮台时向最近城墙吸附的水平半径（米）
const WALL_CANNON_SNAP: float = 6.0
# 建造/修理自动派工：每隔一段时间给没人施工的工地找最近的空闲农民
const BUILDER_SEARCH_RADIUS: float = 45.0
const BUILDER_DISPATCH_INTERVAL: float = 0.6
var _builder_dispatch_timer: float = 0.0
const BattleStatsPanelScript = preload("res://scripts/ui/BattleStatsPanel.gd")
const MapPresets = preload("res://scripts/map/MapPresets.gd")
const TutorialHintScript = preload("res://scripts/ui/TutorialHint.gd")
const CampaignDirectorScript = preload("res://scripts/scenes/CampaignDirector.gd")
const LevelVisualScript = preload("res://scripts/effects/BuildingLevelVisual.gd")
var previous_emulate_mouse: bool
# ==================== 资源 ====================
var player_resources: Dictionary = {"gold": 100, "wood": 100, "stone": 100 ,"food": 100, "oil": 0}
var enemy_resources: Dictionary = {"gold": 100, "wood": 100, "stone": 100, "food": 100, "oil": 0}
var player_resource_limits: Dictionary = {"gold": 500, "wood": 500, "stone": 500, "food": 500, "oil": 0}
var enemy_resource_limits: Dictionary = {"gold": 500, "wood": 500, "stone": 500, "food": 500, "oil": 0}
var is_online: bool = false
var team_building_levels: Dictionary = {}  # team -> {building_id: level}
var build_touch_active: bool = false   # 是否正在拖拽建造
var build_drag_started: bool = false   # 是否已开始拖拽（手指按下后）
var mobile_keep_build_mode: bool = false  # 移动端连造：放置完成后不退出建造模式
var mobile_centered_build: bool = false   # 移动端居中建造：预览固定屏幕中央，滑动地图调整位置
var _mobile_preview_timer: float = 0.0
# ==================== 人口 ====================
var player_pop: int = 0
var player_max_pop: int = 50
var enemy_pop: int = 0
var enemy_max_pop: int = 50
var game_mode_2v2: bool = false               # 是否单机2v2模式
var is_ffa: bool = false                      # 是否乱斗模式（多国自由结盟/进贡/决裂/背叛）
var player_owner_id: int = 1                  # 玩家自己的owner_peer_id (单机2v2=1, 1v1=-1)
# 单机每局随机分配红/蓝阵营；联机由 OnlineBattleManager 决定，两者都通过 get_host_team() 读取。
var player_team: int = RTSConfig.Team.BLUE
var enemy_team: int = RTSConfig.Team.RED
var local_auto_attack: bool = false           # 本地玩家的自动进攻开关
# 左键智能指挥之外的显式下令模式："" / "attack" / "move"
# 由 SelectionManager 在按 A / M 后置位，下一次左键执行一次后清空。
var pending_command_mode: String = ""
# 智能军需官：开启后自动把空闲农民派去采集，并在仓容紧张时自动补仓库
var local_quartermaster: bool = false
var _quartermaster_timer: float = 0.0
const QUARTERMASTER_INTERVAL: float = 1.6
const QUARTERMASTER_PEASANT_TARGET: int = 15
const QUARTERMASTER_REBALANCE_INTERVAL: float = 8.0
const QUARTERMASTER_WAREHOUSE_ID: int = 22
const QUARTERMASTER_MAX_WAREHOUSES: int = 4
const QUARTERMASTER_WAREHOUSE_GAP: float = 14.0
const QUARTERMASTER_STORAGE_TRIGGER: float = 0.9
var _qm_last_warehouse_time: Dictionary = {}  # owner_id -> 上次自动建仓库的 game_time
var _qm_last_rebalance: Dictionary = {}       # owner_id -> 上次重分配农民的 game_time
# 智能军队官：玩家在设置面板给每个兵种设一个"保底数量"，数量不足时自动补兵。
# 阈值只存内存（按局生效），0 = 不自动生产。
var local_army_officer: bool = false
var _army_officer_timer: float = 0.0
const ARMY_OFFICER_INTERVAL: float = 2.5
# 每次检查最多入队几个：避免一开开关就把产能和资源全梭光
const ARMY_OFFICER_MAX_PER_TICK: int = 3
var army_officer_thresholds: Dictionary = {}   # unit_id -> 期望数量
const AUTO_ATTACK_EXCLUDE_IDS = [5, 6, 9, 10, 14, 43, 44, 45, 51, 46, 47, 48, 49, 50]
# 官员编制：官员总数不能超过己方“可进驻建筑”的数量。
# 桥(7)、梯(8)、城墙(27)不是驻军建筑，不提供官员名额；在建/被毁建筑也不计。
const OFFICIAL_UNIT_IDS: Array[int] = [46, 47, 48, 49, 50]
const OFFICIAL_HOST_EXCLUDE_IDS: Array[int] = [7, 8, 27]
var ai_players: Dictionary = {}               # { peer_id: { "team":, "slot":, "castle": } }
var ai_resources: Dictionary = {}             # peer_id -> resources dict
var ai_population: Dictionary = {}            # peer_id -> population dict
var ai_limits: Dictionary = {}                # peer_id -> limits dict
var diplomacy: DiplomacyManager = null        # 乱斗模式外交核心（子节点），非乱斗为 null
# ==================== 废弃建筑（地图边缘的中立废墟） ====================
# 开局在地图边缘随机生成若干中立建筑；任何一方单位靠近并停留 2.5 秒即归其所有，
# 先到先得。占领后立刻获得该建筑自身的功能（瞭望视野 / 仓储上限 / 民居人口）与一次性战利品。
const ABANDONED_TYPE_IDS := [41, 41, 41, 22, 28, 27, 27]   # 瞭望塔(视野)/仓库(仓储)/民居(人口)/城墙(断墙残段)
const ABANDONED_CAPTURE_RADIUS := 4.5
const ABANDONED_CAPTURE_TIME := 2.5
var _abandoned_sites: Array = []                  # 尚未被占领的中立废墟（Building）
var _abandoned_capture: Dictionary = {}           # 废墟 instance_id -> {"team": int, "time": float}
var _abandoned_spawned: bool = false
var _abandoned_ready_timer: float = 0.0
# ==================== 建造 ====================
var building_defs: Array = []
var build_mode: bool = false
var selected_building_id: int = -1
var build_preview: Node3D = null
var current_build_menu: Control = null

# ==================== 迷雾 ====================
var explored_grid: Array = []
var visible_grid: Array = []
var fog_timer: float = 0.0
var fog_version: int = 0             # 迷雾实际变化版本号，供小地图判断是否需要重建底图
var map_modifiers: Dictionary = {}   # 当前地图的规则修正（视野/高地/浅滩等）
# 视野增量覆盖计数：每个格子被多少个己方视野源覆盖。
# 旧实现每 0.5s 清空全图并重算所有单位视野圆；后期几百个单位时是固定主线程热点。
var _fog_cover: Array = []
var _fog_sources: Dictionary = {}    # instance_id -> {"x","y","r"}
var _fog_host_team: int = -999
# 每个视野源缓存的可见格集合：height/半径不变就不重算，队伍视野掩码只做并集。
var _vision_cells_cache: Dictionary = {}
# 每个队伍的可见格掩码（PackedByteArray，gx*MAP_SIZE+gy），AI/联机快照/建造预览共用。
var _team_vis_cache: Dictionary = {}
const TEAM_VIS_CACHE_MS: int = 350
# 视野源没有变化时，队伍掩码不需要每 350ms 重新并集一次。几百个静止单位时
# 这一步会占掉几十毫秒；最多 2 秒兜底刷新一次，避免死亡单位残留视野。
var _vision_dirty: bool = true
const TEAM_VIS_IDLE_MS: int = 2000
const VISION_CELLS_CACHE_MAX: int = 900

# ==================== 游戏状态 ====================
var _pending_left_click: bool = false
var _left_click_timer: float = 0.0
var _touch_start_pos: Vector2 = Vector2.ZERO
var _touch_start_time: int = 0
var _left_click_source: String = "selection"
var _processing_delayed: bool = false
const CLICK_DELAY: float = 0.1

var game_over_panel: Control = null
var game_over_label: Label = null
var game_over: bool = false
var battle_stats = null          # 战斗统计器（累计 + 实时采样）
var _team_castle_count: Dictionary = {}   # 单机2v2: 每队存活城堡数
var game_time: float = 0.0
var game_time_label: Label = null
var _last_clock_secs: int = -1
var rally_mode: bool = false

# ==================== 警报系统 ====================
var _alert_cooldowns: Dictionary = {}
var _enemy_attack_cooldown: float = 0.0

# ==================== 城堡位置 ====================
var player_castle_pos: Vector3
var enemy_castle_pos: Vector3

# ==================== 节点引用 ====================
@onready var entities: Node3D = $Entities
@onready var selection: SelectionManager = $SelectionManager
@onready var info_panel: InfoPanel = $UI/InfoPanel

# ==================== 实体分组缓存 (避免每帧 O(N) 全量扫描) ====================
var _entity_cache_dirty: bool = true
var _all_entities: Array = []           # 所有存活实体
var _armies: Array = []                 # 仅 Army 实体
var _buildings: Array = []              # 仅 Building 实体
var _resources: Array = []              # 仅 WorldResource 实体
var _towers: Array = []                 # 防御塔 (id 25, 26)
var _entities_by_team: Dictionary = {}  # team int → Array
var _entity_lookup: Dictionary = {}     # instance_id → GameEntity (O(1) 查找)
var _global_wall_cache: Dictionary = {}  # cached entity positions for pathfinding
var _wall_cache_dirty: bool = true
var _cache_refresh_timer: float = 0.0
# 弹丸避障查询非常频繁；建筑缓存最多每 0.5 秒刷新一次，避免每发箭都触发
# _rebuild_entity_cache（单位死亡/出生时 dirty，全量重建会形成帧尖峰）。
var _projectile_cache_refresh_ms: int = -100000
const PROJECTILE_CACHE_REFRESH_MS: int = 500
var _projectile_building_top_cells: Dictionary = {}
# ==================== 空间索引（网格分桶，消除 O(n²) 近邻扫描） ====================
const _SPATIAL_CELL_SIZE: float = 4.0
var _spatial_cells: Dictionary = {}  # Vector2i -> Array[GameEntity]，随实体缓存重建
var _building_cells: Dictionary = {}  # Vector2i -> Array[Building]，仅供碰撞分离精确查询建筑
# ==================== A* 分帧预算 ====================
# 大部队同时下令时，几十/上百个单位会在同一帧各跑一次 A*。这里按帧限制
# 请求数和耗时，超出的单位延后到后续帧重试；调用方 MovementController 会等待。
# 原 8/6ms → 12/9ms → 24/48 仍然偏紧：后期几百个单位同时追击时，长路径
# 单次就可能吃掉几毫秒，队列会长期停在几十甚至上百个。这里把基础预算再放宽
# 到 32ms/64 个请求，并按当前排队量逐级加码（最多 44ms/88 个），让队尾能
# 在几帧内被消化；时间预算仍按实际计算耗时截断，不会真的把整帧跑满。
const ASTAR_REQUESTS_PER_FRAME: int = 64
const ASTAR_TIME_BUDGET_USEC: int = 32000
# 给“已经因为预算不足排队过”的请求预留配额。新请求最多用 44 个名额/22ms，
# 剩余 20 个名额/10ms 留给 pending 重试，避免新移动命令长期压住已排队单位。
const ASTAR_RETRY_RESERVE_REQUESTS: int = 20
const ASTAR_RETRY_RESERVE_USEC: int = 10000
# 排队单位超过这个数量时进入“泄洪”模式：新请求少放行，把预算让给
# 已经排队的单位；否则不断到来的新移动命令会把队尾永远压在后面。
const ASTAR_BACKLOG_PRESSURE: int = 30
# 排队量每达到一档，额外增加的名额/耗时；最多加 3 档。
const ASTAR_BACKLOG_STEP: int = 30
const ASTAR_BACKLOG_MAX_BOOST: int = 3
const ASTAR_BOOST_REQUESTS: int = 8
const ASTAR_BOOST_USEC: int = 4000
# 排队太久的请求会饿死：普通配额按帧分配，但每帧新请求和重建请求
# 不断插队，队尾可能几秒都轮不到，最后触发 pending 超时→判失败→重发，
# 形成“永远在排队、永远没路径”的循环。给等过头的请求一条强制通道：
# 不受普通名额限制，但每帧最多放行几个，避免一次性把所有长路径都算完造成卡顿。
const ASTAR_FORCE_REQUESTS_PER_FRAME: int = 3
var _astar_budget_frame: int = -1
var _astar_budget_count: int = 0
var _astar_budget_usec: int = 0
var _astar_force_frame: int = -1
var _astar_force_count: int = 0
# 顶部诊断/预算共用的排队估计值，由 get_moving_no_path_stats() 定期刷新。
var _astar_pending_estimate: int = 0

func get_astar_pending_estimate() -> int:
	return _astar_pending_estimate

# 攻击移动共用路线：读取/写入都只操作本管理器，单位移动控制器不各自缓存，
# 这样同一波部队才能真的复用同一条 A* 路线。
func get_group_attack_path(cache_key: Vector3i) -> Array:
	var entry = _group_attack_path_cache.get(cache_key, null)
	if entry == null:
		return []
	return entry.get("path", [])

func set_group_attack_path(cache_key: Vector3i, path: Array, start_pos: Vector3) -> void:
	if path.is_empty():
		return
	# 目的地种类可能很多，限制缓存条目；超出后整体丢弃重建，避免长期占内存。
	if _group_attack_path_cache.size() >= GROUP_ATTACK_PATH_CACHE_MAX:
		_group_attack_path_cache.clear()
	_group_attack_path_cache[cache_key] = {
		"path": path.duplicate(),
		"start": start_pos,
	}
# A* 统计：调用次数按 1 秒窗口滚动，峰值/累计供结算面板使用。
# 实际调用包含建筑变化后 recalculate() 的直算，所以可能略高于分配次数。
var _astar_calls_window: int = 0
var _astar_stats_window_ms: int = 0
# 结算面板用的全场累计值：总调用、总分配、峰值/秒、总耗时
var _astar_calls_total: int = 0
var _astar_alloc_total: int = 0
var _astar_peak_calls_per_sec: int = 0
var _astar_usec_total: int = 0
# ==================== 墙体/梯子网格缓存（O(1) 查询，随实体缓存重建） ====================
var _wall_cache_version: int = 0          # 墙体/建筑布局实际变化时递增，MovementController 据此判断墙集合是否失效
var _wall_layout_signature: int = 0       # 建筑/资源布局签名，避免实体缓存每 0.5s 刷新都让寻路墙缓存失效
var _wall_signature_initialized: bool = false
# 攻击移动群体路线缓存：同一边、同一片目的地的部队共用一条 A* 路线。
# 后期 AI 一波几十个单位同时攻击移动，若每个单位各跑一次 A*，预算很快被吃光，
# 队尾单位会长期停在“攻击移动却没有路径”。这里只让第一个单位算完整路线，
# 其余单位从最近航点并入；布局变化时整体清空。
const GROUP_ATTACK_PATH_CACHE_MAX: int = 48
var _group_attack_path_cache: Dictionary = {}  # Vector3i(team, cell_x, cell_z) -> {"path": Array, "start": Vector3}
var _wall_entity_grid: Dictionary = {}    # Vector2i -> Building(城墙 id==27)，供 process_move 高度平滑 O(1) 查询
var _wall_shot_grid: Dictionary = {}      # Vector2i -> true，城墙墙格及段间接缝，远程跨墙射击遮挡
var _wall_top_entity_grid: Dictionary = {} # Vector2i -> Building(城墙/墙顶炮台)，近战锁敌时 O(1) 判断目标是否在墙顶
var _ladder_entity_grid: Dictionary = {}  # Vector2i -> Building(梯子 id==8)，供 _has_adjacent_ladder O(8) 查询
var _bridge_entity_grid: Dictionary = {}  # Vector2i -> Building(桥 id==7)，供落水判定 O(1) 查询
# 水域距离网格：每个陆地格到最近水格的格数，供海军追击目标筛选。地图水域不会变，懒构建一次即可。
var _water_distance_grid: PackedInt32Array = PackedInt32Array()
var _water_distance_size: int = -1
var _water_distance_has_water: bool = false
# 弹丸对象池：后期每秒几十上百发箭/炮弹，复用节点可避免反复 new + GLB instantiate + 物理形状创建
var _bullet_pool: Dictionary = {}         # pool_key -> Array[Bullet]
# 同模型同队伍的单位共享 tint / 顶点色材质，避免每个单位复制出独立材质，
# 减少材质状态切换与显存占用。
var _team_material_cache: Dictionary = {}

func _bullet_pool_key(source, p_damage_radius: float, p_team: int) -> String:
	var sid: int = -1
	if source != null and is_instance_valid(source):
		sid = int(source.entity_id)
	if sid == 17 or sid == 59:
		return "boulder_%d_%d" % [sid, p_team]
	if p_damage_radius > 0.0 or sid in [16, 26, 39]:
		return "cannon_%d" % p_team
	return "arrow_%d" % p_team

func acquire_bullet(source, p_damage_radius: float, p_team: int) -> Bullet:
	var key: String = _bullet_pool_key(source, p_damage_radius, p_team)
	var bucket: Array = _bullet_pool.get(key, [])
	while bucket.size() > 0:
		var pooled = bucket.pop_back()
		if is_instance_valid(pooled):
			pooled.reset_for_reuse(source, p_damage_radius, p_team, key)
			return pooled
	var b := Bullet.new()
	# 暂停时弹丸必须停在原地，避免解冻瞬间全部命中。
	b.process_mode = Node.PROCESS_MODE_PAUSABLE
	b.team = p_team
	b.source = source
	b.damage_radius = p_damage_radius
	b._pool_key = key
	add_child(b)
	return b

func recycle_bullet(b: Bullet) -> void:
	if not is_instance_valid(b):
		return
	var key: String = b._pool_key
	if key == "":
		b.queue_free()
		return
	var bucket: Array = _bullet_pool.get(key, [])
	bucket.append(b)
	_bullet_pool[key] = bucket

# 预扣一次 A* 请求的配额。返回 false 时调用方应把目标记为 pending，下一帧再试。
# is_retry 为 true 表示这是已经排队过的 pending 请求，可使用预留配额。
# force 为 true 时给排队过久的请求开放强制通道：绕过普通名额/耗时预算，
# 每帧最多放行 ASTAR_FORCE_REQUESTS_PER_FRAME 个，下一帧继续消化队尾。
func reserve_astar_request(is_retry: bool = false, force: bool = false) -> bool:
	var frame: int = Engine.get_process_frames()
	if frame != _astar_budget_frame:
		_astar_budget_frame = frame
		_astar_budget_count = 0
		_astar_budget_usec = 0
	if force:
		if frame != _astar_force_frame:
			_astar_force_frame = frame
			_astar_force_count = 0
		if _astar_force_count >= ASTAR_FORCE_REQUESTS_PER_FRAME:
			return false
		_astar_force_count += 1
		_astar_budget_count += 1
		_astar_alloc_total += 1
		return true
	# 排队越多，这一帧的 A* 总预算越大；但最多加 3 档，避免极端情况下
	# 把所有帧时间都耗在寻路上。
	var boost: int = clampi(_astar_pending_estimate / ASTAR_BACKLOG_STEP, 0, ASTAR_BACKLOG_MAX_BOOST)
	var max_count: int = ASTAR_REQUESTS_PER_FRAME + boost * ASTAR_BOOST_REQUESTS
	var base_usec: int = _astar_frame_budget_usec()
	var max_usec: int = base_usec + boost * ASTAR_BOOST_USEC
	if base_usec < ASTAR_TIME_BUDGET_USEC:
		# 后期总量大时预算已经收紧，积压再多也只额外放 4ms，防止 A* 反向
		# 把整帧吃光。单位暂时排队比每帧 30ms+ 的卡顿更容易接受。
		max_usec = mini(max_usec, base_usec + 4000)
	if not is_retry:
		var reserve_count: int = ASTAR_RETRY_RESERVE_REQUESTS
		var reserve_usec: int = mini(ASTAR_RETRY_RESERVE_USEC, base_usec / 3)
		# 队列已经很长时，进一步压缩新请求配额，把更多预算让给 pending 队尾。
		if _astar_pending_estimate >= ASTAR_BACKLOG_PRESSURE:
			reserve_count += 8
			reserve_usec = mini(reserve_usec + 2000, base_usec / 2)
		max_count -= reserve_count
		max_usec -= reserve_usec
	if max_usec <= 0:
		return false
	if _astar_budget_count >= max_count or _astar_budget_usec >= max_usec:
		return false
	_astar_budget_count += 1
	_astar_alloc_total += 1
	return true

# 按实体规模收紧单帧 A* 总预算：小规模对局保留原 32ms，保证寻路及时；
# 后期 400+ 实体时降到 10ms，把剩余帧时间留给单位物理/AI，避免长路径叠加成卡顿。
func _astar_frame_budget_usec() -> int:
	var total: int = _all_entities.size()
	if total >= 420:
		return 10000
	if total >= 300:
		return 14000
	if total >= 180:
		return 20000
	return ASTAR_TIME_BUDGET_USEC

# 每次真正进入 A* 计算时调用（包括不走预算的 recalculate 直算）。
func note_astar_path_call() -> void:
	_astar_calls_window += 1
	_astar_calls_total += 1

# 每帧滚动统计窗口；顶部信息栏读取 *_last_second 两个值。
func _tick_astar_stats() -> void:
	var now_ms: int = Time.get_ticks_msec()
	if _astar_stats_window_ms == 0:
		_astar_stats_window_ms = now_ms
		return
	if now_ms - _astar_stats_window_ms < 1000:
		return
	_astar_peak_calls_per_sec = maxi(_astar_peak_calls_per_sec, _astar_calls_window)
	_astar_calls_window = 0
	_astar_stats_window_ms = now_ms

# 结算面板读取：全场累计 + 平均/峰值（平均按对局时长计算）
func get_astar_stats() -> Dictionary:
	var secs: float = maxf(game_time, 1.0)
	return {
		"calls_total": _astar_calls_total,
		"alloc_total": _astar_alloc_total,
		# 结算发生在窗口滚动前时，把当前未结算窗口也算进峰值
		"peak_calls_per_sec": maxi(_astar_peak_calls_per_sec, _astar_calls_window),
		"avg_calls_per_sec": float(_astar_calls_total) / secs,
		"avg_alloc_per_sec": float(_astar_alloc_total) / secs,
		"usec_total": _astar_usec_total,
	}

func report_astar_cost(usec: int) -> void:
	if usec > 0:
		_astar_budget_usec += usec
		_astar_usec_total += usec

# 顶部诊断：统计需要移动、但当前 astar_path 为空的存活单位。
# 攻击射程内、采集/交付接触距离内、坚守或不能移动的单位不计入。
# pending 单独计数：这些单位在排队等 A* 预算，并不一定是状态卡死。
func get_moving_no_path_stats() -> Dictionary:
	_ensure_cache_fresh()
	var stats := {
		"total": 0,
		"pending": 0,       # 无路径且正在排队的单位（顶部“移动无路径”明细）
		"pending_total": 0, # 所有正在等 A* 的单位（包括仍有旧路径的追击单位）
		"move_failed": 0,
		"attack_failed": 0,
		"partial": 0,
		"stalled": 0,
	}
	for army in _armies:
		if not is_instance_valid(army) or army.health <= 0:
			continue
		var mover = army._movement
		if mover != null and mover._pending_path:
			# 追击单位可能还保留着旧路径边追边等，这种也要算进真实排队量，
			# 否则只看“无路径”会低估 A* 压力。
			stats["pending_total"] += 1
		if not army.needs_move_without_path():
			continue
		stats["total"] += 1
		if mover == null:
			continue
		if mover._pending_path:
			stats["pending"] += 1
		elif mover.move_path_failed:
			stats["move_failed"] += 1
		elif mover.attack_path_failed:
			stats["attack_failed"] += 1
		elif mover.path_partial:
			stats["partial"] += 1
		else:
			# 没有路径、没有排队、也没有失败/部分路径标记：状态兜底没有接上
			stats["stalled"] += 1
	_astar_pending_estimate = int(stats["pending_total"])
	return stats

# ==================== 诊断工具 ====================
var _diag_timer: float = 5.0
var _diag_last_total: int = 0
var _diag_last_bullets: int = 0
var _diag_step: int = 0
var _diag_active_entity: String = ""
var _diag_active_frame: int = 0
var _diag_physics_heartbeat: int = 0
var _fps_label: Label = null
var _snap_rate_label: Label = null
var _diag_bg: Panel = null
var _diag_layer: CanvasLayer = null
var _top_info_visible: bool = true       # 打开移动端统计大屏时临时隐藏顶部信息
var _diag_rect: Rect2 = Rect2()          # 顶部信息面板当前矩形（HUD 战况栏据此避让）
var _diag_capsule_rect: Rect2 = Rect2()  # 手机端资源胶囊矩形：信息栏贴在它下面

# ==================== 后期自动画质 ====================
# 后期实体数量上来后，大量单位模型 + 实时阴影会把 GPU 压到 30~40 FPS。
# 这里按真实 FPS 分档降低 3D 渲染分辨率，并缩短阴影距离/降低阴影分片；
# 不再直接关闭实时阴影，否则单位会完全失去影子。
var _perf_quality_level: int = 0
# 默认锁定“极致”画质，不再参与后期自动降档；玩家仍可在设置面板手动选档
var hand_quality_mode: bool = false
var _perf_sample_timer: float = 5.0
var _perf_low_streak: int = 0
var _perf_high_streak: int = 0
var _perf_initialized: bool = false
var _perf_base_scale: float = 1.0
var _perf_viewport: Viewport = null
var _perf_light: DirectionalLight3D = null
var _perf_light_shadow_original: bool = true
var _perf_light_shadow_distance_original: float = 60.0
var _perf_light_shadow_mode_original: int = -1
var _perf_env: Environment = null
var _perf_ssao_original: bool = false
const PERF_LEVEL_SCALES: Array[float] = [1.0, 0.85, 0.72, 0.62, 0.52]
# 阴影始终保留，低画质只缩短阴影投射距离，单位近处仍有影子
const PERF_SHADOW_DISTANCE_SCALES: Array[float] = [1.0, 0.9, 0.8, 0.7, 0.6]
var _distant_shadow_timer: float = 2.0
var _anim_lod_timer: float = 1.0
# 大规模战斗自适应物理频率：渲染仍按60FPS，逻辑/物理降到30Hz，避免
# 每帧追赶多个物理 tick 形成“越卡越追、越追越卡”的死循环。
var _physics_tick_timer: float = 2.0
var _physics_tick_original: int = 60
var _physics_max_steps_original: int = 8
var _physics_rate_low: bool = false

func _create_diag_label():
	# 顶部信息只保留两行：性能（FPS/画质）和对局信息（AI/地图/时间）。
	# 实体数量、A* 寻路排队这些诊断数据已从这里移除，给战场留空间。
	# 桌面放指令底板下方居中；手机竖屏放资源胶囊正下方，横屏夹在胶囊与小地图之间。
	var mobile := InputSource.use_mobile_ui()
	_diag_bg = Panel.new()
	_diag_bg.name = "DiagBG"
	_diag_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_diag_bg.z_index = 199
	var bg_style := StyleBoxFlat.new()
	bg_style.bg_color = Color(0.0, 0.0, 0.0, 0.45)
	bg_style.set_corner_radius_all(int(UILayout.dp(6.0)))
	_diag_bg.add_theme_stylebox_override("panel", bg_style)
	_diag_layer = CanvasLayer.new()
	_diag_layer.name = "DiagLayer"
	_diag_layer.layer = 100
	_diag_layer.add_child(_diag_bg)
	_fps_label = _make_top_label("DiagFPS", mobile, UILayout.font_dp(10.0) if mobile else 24, Color.LIME_GREEN)
	_snap_rate_label = _make_top_label("DiagInfo", mobile, UILayout.font_dp(9.5) if mobile else 22, Color(1.0, 0.9, 0.3))
	_diag_layer.add_child(_fps_label)
	_diag_layer.add_child(_snap_rate_label)
	add_child(_diag_layer)
	_diag_physics_heartbeat = 0
	_layout_diag_now()

# 移动端统计大屏打开时隐藏顶部信息，关掉再恢复（大屏是模态覆盖，信息栏会压住它）
func set_top_info_visible(v: bool) -> void:
	_top_info_visible = v
	if _diag_layer != null and is_instance_valid(_diag_layer):
		_diag_layer.visible = v

# 顶部信息的一行文字（带黑描边，浅色地面也看得清）。
# 桌面居中；手机左对齐并按 dp 放大字号，超长才用省略号兜底。
func _make_top_label(node_name: String, mobile: bool, font_size: int, color: Color) -> Label:
	var lb := Label.new()
	lb.name = node_name
	lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT if mobile else HORIZONTAL_ALIGNMENT_CENTER
	lb.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if mobile:
		lb.clip_text = true
		lb.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	lb.add_theme_font_size_override("font_size", font_size)
	lb.add_theme_color_override("font_color", color)
	lb.add_theme_color_override("font_outline_color", Color.BLACK)
	lb.add_theme_constant_override("outline_size", maxi(3, int(font_size * 0.2)))
	lb.z_index = 200
	lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return lb

# 资源胶囊矩形：手机取 MobileHUD 真实控件（展开/收起都能跟上）；
# 桌面取 HUD 左上角的统计胶囊，取不到按 UILayout 兜底。
func _diag_capsule_rect_now() -> Rect2:
	if InputSource.use_mobile_ui():
		var mh = get_tree().get_first_node_in_group("mobile_hud")
		if mh != null and is_instance_valid(mh):
			var cap = mh.get("capsule")
			if cap is Control and (cap as Control).visible:
				var cr: Rect2 = (cap as Control).get_global_rect()
				if cr.size.x > 0.0:
					return cr
		var insets := UILayout.safe_insets()
		return Rect2(Vector2(insets.x + UILayout.dp(2.0), insets.y + UILayout.dp(2.0)),
			Vector2(UILayout.dp(UILayout.mobile_capsule_width_dp()), UILayout.dp(42.0)))
	var hud = get_tree().get_first_node_in_group("game_hud")
	if hud != null and is_instance_valid(hud):
		var cap2 = hud.get("_stats_capsule")
		if cap2 is Control and (cap2 as Control).visible:
			var cr2: Rect2 = (cap2 as Control).get_global_rect()
			if cr2.size.x > 0.0:
				return cr2
	return UILayout.top_capsule_rect(UILayout.view_size(), UILayout.TOP_CAPSULE_MIN_W)

# 是否单行模式：竖屏手机例外（保持胶囊下方两行），桌面与手机横屏都缩成一行放胶囊右边
func _diag_single_line() -> bool:
	return not (InputSource.use_mobile_ui() and UILayout.is_portrait())

# 单行信息按可用宽度自动压字号，保证文字不撑破底板
func _fit_diag_font(text: String, base_size: int, max_w: float) -> int:
	var f: Font = _fps_label.get_theme_font("font") if _fps_label != null else null
	if f == null:
		f = ThemeDB.fallback_font
	var fs := base_size
	while fs > 8 and f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > max_w:
		fs -= 1
	return fs

# 顶部信息面板重排：每 10 帧随刷新跑一次，旋转屏幕 / 胶囊展开后矩形自动跟上
func _layout_diag_now() -> void:
	if _diag_bg == null or _fps_label == null:
		return
	var mobile := InputSource.use_mobile_ui()
	var single := _diag_single_line()
	var rect := Rect2()
	_diag_capsule_rect = _diag_capsule_rect_now()
	if single:
		var vp := UILayout.view_size()
		if mobile:
			rect = UILayout.mobile_info_right_rect(_diag_capsule_rect, 22.0)
		else:
			rect = UILayout.top_info_right_rect(vp, _diag_capsule_rect.position.x + _diag_capsule_rect.size.x, 48.0)
		if rect.size.x <= 0.0:
			# 极端窄屏（胶囊把空档吃光）兜底：退回指令栏下方一行
			rect = UILayout.top_diag_rect(vp, 1040.0, 44.0)
	elif mobile:
		rect = UILayout.mobile_top_info_rect(_diag_capsule_rect)
	else:
		rect = UILayout.top_diag_rect(UILayout.view_size(), 1040.0, 44.0)
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return
	_diag_rect = rect
	_diag_bg.position = rect.position
	_diag_bg.size = rect.size
	var pad_x := UILayout.dp(6.0) if mobile else UILayout.dp(4.0)
	var inner_w := rect.size.x - pad_x * 2.0
	_fps_label.position = Vector2(rect.position.x + pad_x, rect.position.y)
	_fps_label.size = Vector2(inner_w, rect.size.y)
	_fps_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT if (single or mobile) else HORIZONTAL_ALIGNMENT_CENTER
	if single:
		_snap_rate_label.visible = false
		var base := UILayout.font_dp(9.5) if mobile else 20
		_fps_label.add_theme_font_size_override("font_size", _fit_diag_font(_fps_label.text, base, inner_w))
		return
	# 竖屏手机：仍是两行
	_snap_rate_label.visible = true
	var line_h := rect.size.y / 2.0
	_fps_label.size = Vector2(inner_w, line_h)
	_fps_label.add_theme_font_size_override("font_size", UILayout.font_dp(10.0))
	_snap_rate_label.position = Vector2(rect.position.x + pad_x, rect.position.y + line_h)
	_snap_rate_label.size = Vector2(inner_w, line_h)
	_snap_rate_label.add_theme_font_size_override("font_size", UILayout.font_dp(9.5))

# 战况栏避让用：信息面板底边
func get_diag_panel_rect() -> Rect2:
	return _diag_rect

func _rebuild_entity_cache():
	_all_entities.clear()
	_armies.clear()
	_buildings.clear()
	_resources.clear()
	_towers.clear()
	_entities_by_team.clear()
	_entity_lookup.clear()
	if not entities: return
	for child in entities.get_children():
		if not is_instance_valid(child) or not (child is GameEntity) or child.health <= 0:
			continue
		_all_entities.append(child)
		_entity_lookup[child.get_instance_id()] = child
		if child is Army:
			_armies.append(child)
		elif child is Building:
			_buildings.append(child)
			if child.entity_id in [25, 26]:
				_towers.append(child)
		elif child is WorldResource:
			_resources.append(child)
		var t = child.team
		if not _entities_by_team.has(t):
			_entities_by_team[t] = []
		_entities_by_team[t].append(child)
	# 同步构建空间索引（网格分桶）
	_spatial_cells.clear()
	for e in _all_entities:
		var key = Vector2i(int(floor(e.global_position.x / _SPATIAL_CELL_SIZE)), int(floor(e.global_position.z / _SPATIAL_CELL_SIZE)))
		if not _spatial_cells.has(key):
			_spatial_cells[key] = []
		_spatial_cells[key].append(e)
	# 建筑单独分桶：碰撞分离只需要极近的建筑，避免从单位大桶里返回整片密集人群
	_building_cells.clear()
	for b in _buildings:
		var bkey = Vector2i(int(floor(b.global_position.x / _SPATIAL_CELL_SIZE)), int(floor(b.global_position.z / _SPATIAL_CELL_SIZE)))
		if not _building_cells.has(bkey):
			_building_cells[bkey] = []
		_building_cells[bkey].append(b)
	# 同步构建墙体/梯子网格（MovementController 寻路与高度平滑的 O(1)/O(8) 缓存）
	_wall_entity_grid.clear()
	_wall_shot_grid.clear()
	_wall_top_entity_grid.clear()
	_ladder_entity_grid.clear()
	_bridge_entity_grid.clear()
	var wall_cells: Array = []
	for b in _buildings:
		if b.health <= 0:
			continue
		if b.entity_id == 27:
			var wc: Vector2i = world_to_grid(b.global_position)
			_wall_entity_grid[wc] = b
			_wall_shot_grid[wc] = true
			_wall_top_entity_grid[wc] = b
			wall_cells.append(wc)
		elif b.entity_id == 64:
			_wall_top_entity_grid[world_to_grid(b.global_position)] = b
		elif b.entity_id == 8:
			_ladder_entity_grid[world_to_grid(b.global_position)] = b
		elif b.entity_id == 7:
			_bridge_entity_grid[world_to_grid(b.global_position)] = b
	# 相邻墙段中心距约 1.5~2 米，落在两格之间时接缝格本身不是墙格；
	# 远程弹道只检查中心格会从接缝“漏射”，这里把段间中点也标成墙体。
	# 只查每面墙周围 2 格，避免几千面墙两两配对形成 O(n²) 的卡顿。
	for wc in wall_cells:
		for dx in range(-2, 3):
			for dy in range(-2, 3):
				if dx == 0 and dy == 0:
					continue
				# 每对墙只处理一次：只看向右/向下的偏移。
				if dx < 0 or (dx == 0 and dy < 0):
					continue
				if not _wall_entity_grid.has(Vector2i(wc.x + dx, wc.y + dy)):
					continue
				var gap: Vector2i = Vector2i(
					roundi(float(wc.x) + float(dx) * 0.5),
					roundi(float(wc.y) + float(dy) * 0.5)
				)
				_wall_shot_grid[gap] = true
	# 只有建筑/资源布局真的变化时才让寻路墙缓存失效。实体缓存本身每 0.5s
	# 会因刷新而重建，若这里无条件 +1，所有单位每 0.5s 都会重新扫描全图建墙集合。
	var layout_sig: int = 0
	for e in _all_entities:
		if e is Building:
			layout_sig = hash(layout_sig + e.get_instance_id() * 31 + int(e.team) * 131 + int(e.entity_id) * 17)
		elif e is WorldResource:
			layout_sig = hash(layout_sig + e.get_instance_id() * 17)
	if not _wall_signature_initialized or layout_sig != _wall_layout_signature:
		_wall_layout_signature = layout_sig
		_wall_signature_initialized = true
		_wall_cache_version += 1
		# 建筑/资源布局变化后旧路线可能穿墙，整批丢弃，让下一波单位重新算。
		_group_attack_path_cache.clear()
	_entity_cache_dirty = false

func mark_entity_cache_dirty():
	_entity_cache_dirty = true

# 落水判定：桥所在格视为可站立，不参与溺水伤害
func is_bridge_at(world_pos: Vector3) -> bool:
	_ensure_cache_fresh()
	return _bridge_entity_grid.has(world_to_grid(world_pos))

# 编队落点合法性：陆军只落在平地/桥面，水军只落在可航行水面；
# 目标点若在建筑/资源/山体/水里，就在附近找最近的可站立点。
# 大量军队编队时每个单位目标点独立检查，避免方阵边缘掉进水里或山上。
func find_legal_formation_pos(unit: Army, desired: Vector3) -> Vector3:
	if unit == null:
		return desired
	var base := Vector3(desired.x, 0.0, desired.z)
	if _is_formation_slot_legal(unit, base):
		return _formation_slot_world(base)
	# 从目标点向外一圈圈找，优先最近的可站立点；12 格足够让方阵边缘
	# 从河道/山脚退到岸上或平地，又不会把整支部队拉回主城。
	var max_ring: int = 12
	for ring in range(1, max_ring + 1):
		var steps: int = maxi(8, ring * 8)
		for i in range(steps):
			var a: float = TAU * float(i) / float(steps)
			var cand := base + Vector3(cos(a), 0.0, sin(a)) * float(ring)
			if _is_formation_slot_legal(unit, cand):
				return _formation_slot_world(cand)
	# 实在找不到合法点时不要发出“下水/上山”命令，原地待命。
	return unit.global_position

func _is_formation_slot_legal(unit: Army, flat_pos: Vector3) -> bool:
	var half: float = RTSConfig.MAP_SIZE / 2.0
	var gx: int = int(round(flat_pos.x + half))
	var gz: int = int(round(flat_pos.z + half))
	if gx < 1 or gz < 1 or gx >= RTSConfig.MAP_SIZE - 1 or gz >= RTSConfig.MAP_SIZE - 1:
		return false
	var terr: int = get_terrain_at_grid(gx, gz)
	var on_bridge: bool = is_bridge_at(flat_pos)
	if unit.water_capable:
		# 水军只能待在水面，桥面不能开上去。
		if terr != 2 or on_bridge:
			return false
	else:
		# 陆军不能下水；山体(terrain=1)即使是缓坡/台地也不作为方阵落点，
		# 避免大部队挤在窄坡上。桥面是水面上的合法陆地落点。
		if terr == 1:
			return false
		# 浅滩(overlay=3)和桥面一样是陆军可通行的过河点，允许作为落点。
		var ov: int = get_overlay_at_grid(gx, gz)
		if terr == 2 and not on_bridge and ov != 3:
			return false
	# 落点不能压建筑/资源/城墙；只检查静态障碍，其他会移动的军队不算。
	var nearby: Array = get_nearby_entities(flat_pos, 5.0)
	for e in nearby:
		if not (e is Building or e is WorldResource) or e.health <= 0:
			continue
		if e is Building and e.entity_id == 7 and on_bridge:
			continue  # 桥面本身允许陆军站立
		var d: float = Vector2(flat_pos.x - e.global_position.x, flat_pos.z - e.global_position.z).length()
		if d < float(e.body_radius) + float(unit.body_radius) + 0.35:
			return false
	return true

func _formation_slot_world(flat_pos: Vector3) -> Vector3:
	var g: Vector2i = world_to_grid(flat_pos)
	return Vector3(flat_pos.x, get_height_at_grid(g.x, g.y), flat_pos.z)

func _ensure_cache_fresh():
	if _entity_cache_dirty:
		_rebuild_entity_cache()

# 空间索引：返回 from_pos 周围 search_range 外扩约 2.5 单位内的全部存活实体候选
# （外扩用于覆盖缓存期内实体移动，外层函数再做精确距离过滤）
func _spatial_query(from_pos: Vector3, search_range: float) -> Array:
	_ensure_cache_fresh()
	var result: Array = []
	var csize = _SPATIAL_CELL_SIZE
	# 只外扩约 2.5 个单位覆盖实体在 0.5s 缓存期内的位移。
	# 之前外扩整整一个 cell（8 格）会让密集人群查询把相邻 3x3 格的全部实体都返回，
	# 实体只有 300 个时一次碰撞查询就会扫到几百个候选，是后期最大的 CPU 热点。
	var extend = search_range + 2.5
	var min_x = floori((from_pos.x - extend) / csize)
	var max_x = floori((from_pos.x + extend) / csize)
	var min_z = floori((from_pos.z - extend) / csize)
	var max_z = floori((from_pos.z + extend) / csize)
	for cx in range(min_x, max_x + 1):
		for cz in range(min_z, max_z + 1):
			var bucket = _spatial_cells.get(Vector2i(cx, cz))
			if bucket == null:
				continue
			for entity in bucket:
				if not is_instance_valid(entity) or entity.health <= 0:
					continue
				result.append(entity)
	return result

# 建筑专用近邻查询：只遍历建筑桶，避免把周围单位一起返回。
func get_nearby_buildings(from_pos: Vector3, search_range: float) -> Array:
	_ensure_cache_fresh()
	var result: Array = []
	var csize = _SPATIAL_CELL_SIZE
	var extend = search_range + 2.5
	var min_x = floori((from_pos.x - extend) / csize)
	var max_x = floori((from_pos.x + extend) / csize)
	var min_z = floori((from_pos.z - extend) / csize)
	var max_z = floori((from_pos.z + extend) / csize)
	for cx in range(min_x, max_x + 1):
		for cz in range(min_z, max_z + 1):
			var bucket = _building_cells.get(Vector2i(cx, cz))
			if bucket == null:
				continue
			for b in bucket:
				if not is_instance_valid(b) or b.health <= 0:
					continue
				result.append(b)
	return result

# 权威敌对判定（乱斗 FFA 按国家 owner 关系，其余模式按队伍）。
# my_owner 为 -1（未划分国家的 1v1 等）时退化为纯队伍判定；
# 中立资源/同国/存活盟友一律不可攻击 → false。
func is_hostile_to(my_team: int, my_owner: int, entity) -> bool:
	if entity == null or not is_instance_valid(entity):
		return false
	if entity.team == RTSConfig.Team.NEUTRAL:
		return false
	var e_owner: int = -1
	if "owner_peer_id" in entity:
		e_owner = entity.owner_peer_id
	if diplomacy and diplomacy.active and my_owner >= 0 and e_owner >= 0:
		return diplomacy.is_hostile(my_owner, e_owner)
	return entity.team != my_team

# 获取范围内敌军实体（仅搜索敌对实体）— 空间索引加速。
# 直接在桶内过滤，避免先把整片候选复制到临时数组再二次循环。
func get_nearby_enemies(from_pos: Vector3, search_range: float, my_team: int, my_owner: int = -1, only_visible: bool = false) -> Array:
	_ensure_cache_fresh()
	var result: Array = []
	var csize = _SPATIAL_CELL_SIZE
	var extend = search_range + 2.5
	var min_x = floori((from_pos.x - extend) / csize)
	var max_x = floori((from_pos.x + extend) / csize)
	var min_z = floori((from_pos.z - extend) / csize)
	var max_z = floori((from_pos.z + extend) / csize)
	for cx in range(min_x, max_x + 1):
		for cz in range(min_z, max_z + 1):
			var bucket = _spatial_cells.get(Vector2i(cx, cz))
			if bucket == null:
				continue
			for entity in bucket:
				if not is_instance_valid(entity) or entity.health <= 0:
					continue
				if not is_hostile_to(my_team, my_owner, entity):
					continue
				var dist = from_pos.distance_squared_to(entity.global_position)
				var max_dist = search_range + entity.body_radius + 1.0
				if dist > max_dist * max_dist:
					continue
				# 索敌/开火判断用“真实可见”，子弹溅射等纯几何查询保持默认 false。
				if only_visible and not is_position_visible_to_team(my_team, entity.global_position):
					continue
				result.append(entity)
	return result

# 获取最近资源 — 空间索引加速
func get_nearest_resource(from_pos: Vector3, search_range: float, resource_types: Array = []) -> WorldResource:
	var best_dist = search_range * search_range
	var best: WorldResource = null
	for res in _spatial_query(from_pos, search_range):
		if not (res is WorldResource):
			continue
		if res.health <= 0:
			continue
		if resource_types.size() > 0 and not res.resource_type in resource_types:
			continue
		var d = from_pos.distance_squared_to(res.global_position)
		if d < best_dist:
			best_dist = d
			best = res
	return best

# 获取附近所有实体（用于碰撞检测等）
func get_global_wall_cache() -> Dictionary:
	if _wall_cache_dirty:
		_global_wall_cache.clear()
		for e in entities.get_children():
			if not (e is GameEntity): continue
			if e.health <= 0: continue
			if e is Building or e is WorldResource:
				var key = "%d,%d" % [int(e.global_position.x + RTSConfig.MAP_SIZE/2.0), int(e.global_position.z + RTSConfig.MAP_SIZE/2.0)]
				_global_wall_cache[key] = true
	_wall_cache_dirty = false
	return _global_wall_cache
func get_nearby_entities(from_pos: Vector3, search_range: float) -> Array:
	_ensure_cache_fresh()
	var result: Array = []
	var csize = _SPATIAL_CELL_SIZE
	var extend = search_range + 2.5
	var sq_range = search_range * search_range
	var min_x = floori((from_pos.x - extend) / csize)
	var max_x = floori((from_pos.x + extend) / csize)
	var min_z = floori((from_pos.z - extend) / csize)
	var max_z = floori((from_pos.z + extend) / csize)
	for cx in range(min_x, max_x + 1):
		for cz in range(min_z, max_z + 1):
			var bucket = _spatial_cells.get(Vector2i(cx, cz))
			if bucket == null:
				continue
			for entity in bucket:
				if not is_instance_valid(entity) or entity.health <= 0:
					continue
				var d = from_pos.distance_squared_to(entity.global_position)
				if d <= sq_range:
					result.append(entity)
	return result

# ==================== 国家系统 ====================
var team_nations: Dictionary = {
	RTSConfig.Team.BLUE: GameSettings.player_nation,
	RTSConfig.Team.RED: GameSettings.enemy_nation
}

# 玩家颜色映射 — 联机时由 OnlineBattleManager 填充实际 peer_id
var _player_colors: Dictionary = {
	1: Color(0.2, 0.6, 1.0),   # 蓝方玩家（单机默认）
	3: Color(1.0, 0.3, 0.2),   # 红方AI（单机默认）
}
# owner_peer_id -> nation。生成实体前先登记，保证城堡/农民一出生就用国家色，
# 而不是等 ai_players 里补 nation 后才改色。
var _owner_nations: Dictionary = {}
func get_player_colors() -> Dictionary:
	return _player_colors

func get_team_nation(team: int) -> int:
	return team_nations.get(team, -1)

# 国家索引 -> 中文名（供 AI 决策面板 / 单位血条等处显示）
func get_nation_name(nation: int) -> String:
	match nation:
		RTSConfig.Nation.VIKING: return "维京"
		RTSConfig.Nation.ENGLAND: return "英格兰"
		RTSConfig.Nation.FRANCE: return "法兰西"
		RTSConfig.Nation.CHINA: return "中国"
		RTSConfig.Nation.HUNGARY: return "匈牙利"
		RTSConfig.Nation.JAPAN: return "日本"
		RTSConfig.Nation.BYZANTINE: return "拜占庭"
		RTSConfig.Nation.MONGOL: return "蒙古"
		RTSConfig.Nation.PERSIA: return "波斯"
		RTSConfig.Nation.SPAIN: return "西班牙"
	return "未知"

# 返回某个玩家（owner_peer_id）所属的国家索引，未知返回 -1。
# 战报要靠它区分「同队不同国」：2v2 里队友和自己同属一个 team，
# 只看 team 会把队友的单位说成自己的国家。
func get_nation_of_owner(owner: int) -> int:
	if owner < 0:
		return -1
	if _owner_nations.has(owner):
		return int(_owner_nations[owner])
	var info = ai_players.get(owner, {})
	if info.has("nation"):
		return int(info.get("nation", -1))
	return -1

# 返回某个玩家（owner_peer_id）所属的队伍，未知返回 -1
func get_team_of_owner(owner: int) -> int:
	if owner < 0:
		return -1
	var info = ai_players.get(owner, {})
	if info.has("team"):
		return int(info.get("team", -1))
	return -1

# 返回实体所属国家的索引（owner 感知优先；无 owner 时按队伍推断），未知返回 -1
func get_entity_nation(entity) -> int:
	if entity == null:
		return -1
	if entity.owner_peer_id != -1:
		if _owner_nations.has(entity.owner_peer_id):
			return int(_owner_nations[entity.owner_peer_id])
		var info = ai_players.get(entity.owner_peer_id, {})
		if info.has("nation"):
			return int(info.get("nation", -1))
		# 玩家自己的实体在部分初始化阶段可能还没登记 ai_players，按玩家阵营兜底。
		if entity.owner_peer_id == player_owner_id:
			return int(team_nations.get(get_host_team(), -1))
		return -1
	return get_team_nation(entity.team)


# 战报头部要用的国家索引数组（与 source_teams 一一对应）。
# 建造/升级/生产完成这类战报原来只带队伍，2v2/乱斗里队友与自己同队不同国时，
# 只按 team 查国家会把「队友的主城升级完成」写成自己（或队里第一个国家）；
# 这里改成按实体 owner 取国家，HUD 拿到 -1 时才会退回按队伍查。
func get_alert_nations(entity) -> Array:
	return [get_entity_nation(entity)]


# 返回实体所属国家的颜色（血条、模型、小地图统一着色）。
# 国家颜色优先于阵营/玩家颜色，这样同队不同国家的部队也能一眼区分。
func get_entity_color(entity) -> Color:
	if entity == null:
		return Color(0.7, 0.7, 0.7)
	var nation: int = get_entity_nation(entity)
	if nation >= 0 and RTSConfig.has_nation_color(nation):
		var nation_color: Color = RTSConfig.get_nation_color(nation)
		# 单机理论上已避开同国；直接启动战斗场景等极端情况下给异队同国一个暗色变体，
		# 避免完全撞色。
		if not is_online and entity.team != get_host_team() and nation == int(team_nations.get(get_host_team(), -1)):
			nation_color = nation_color.darkened(0.35)
		return nation_color
	if entity.owner_peer_id != -1 and _player_colors.has(entity.owner_peer_id):
		return _player_colors[entity.owner_peer_id]
	match entity.team:
		RTSConfig.Team.BLUE:
			return Color(0.2, 0.6, 1.0)
		RTSConfig.Team.RED:
			return Color(1.0, 0.3, 0.2)
		_:
			return Color(0.7, 0.7, 0.7)   # 中立灰色

# ==================== 获取主城堡 ====================
var _initial_focus_done: bool = false   # 开局镜头是否已对准玩家主城

# 开局视角定位：各模式的城堡都是延迟生成的，因此每帧尝试一次，成功后不再执行
func _focus_camera_on_player_castle_once() -> void:
	if _initial_focus_done:
		return
	var castle := get_player_castle()
	if castle == null or not is_instance_valid(castle):
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	if cam.has_method("focus_on_ground"):
		cam.call("focus_on_ground", castle.global_position)
	else:
		cam.global_position = Vector3(castle.global_position.x, cam.global_position.y, castle.global_position.z)
	_initial_focus_done = true

func get_player_castle() -> Building:
	_ensure_cache_fresh()
	for entity in _buildings:
		if is_instance_valid(entity) and entity.team == get_host_team() and entity.entity_id == 20:
			return entity
	return null

func get_player_castle_level() -> int:
	_ensure_cache_fresh()
	var max_lv = 1
	for e in _buildings:
		if is_instance_valid(e) and e.entity_id == 20 and e.team == get_host_team() and e.health > 0:
			if e.upgrade_level > max_lv:
				max_lv = e.upgrade_level
	return max_lv

# 检查建筑是否已解锁。科研模式按科技；经典模式保持原主城等级规则。
func is_building_unlocked(building_id: int, owner_peer_id: int = -1, team: int = -1) -> bool:
	if is_research_mode():
		if team < 0:
			team = get_host_team()
		var st := get_research_state(owner_peer_id, team)
		return bool(st.get("unlocked_buildings", {}).get(building_id, false))
	var cl = get_player_castle_level()
	match building_id:
		23, 25, 26, 64:  # 船坞、箭塔、炮塔、炮台 → 城堡2级
			return cl >= 2
		24, 29, 52:   # 攻城车间、重装武器厂、集市 → 城堡3级
			return cl >= 3
		42:            # 书院 → 主城3级
			return cl >= 3
		53, 54:        # 城堡、修道院 → 主城4级
			return cl >= 4
	return true

# 获取某建筑需要的城堡等级描述
func get_building_required_castle_level(building_id: int) -> int:
	match building_id:
		23, 25, 26, 64: return 2
		24, 29: return 3
		42, 54: return 4
	return 1

func get_enemy_castle() -> Building:
	_ensure_cache_fresh()
	for entity in _buildings:
		if is_instance_valid(entity) and entity.team == get_enemy_team() and entity.entity_id == 20:
			return entity
	return null

# ==================== 自动进攻开关 ====================
# 开启后：现有军队（无攻击目标）与后续新生产的军队自动向敌方主城攻击移动；
# 关闭后：正在攻击具体目标的军队不受影响，其余军队停止向敌方主城移动。
func set_local_auto_attack(enabled: bool) -> void:
	local_auto_attack = enabled
	for e in get_tree().get_nodes_in_group("entities"):
		if not (e is Army) or e.health <= 0: continue
		if not is_local_player_owned(e.owner_peer_id, e.team): continue
		if not e._is_military() or e.entity_id in AUTO_ATTACK_EXCLUDE_IDS: continue
		if enabled:
			if e.current_target != null: continue
			# 每支军队各自挑最近的敌方主城，避免全军挤在同一条路线上
			var target = _get_auto_attack_target(e.owner_peer_id, e.team, e.global_position)
			if target:
				e._clear_command_queue()
				e.attack_move_to(target.global_position)
		else:
			if _has_attack_move_order(e) and e.current_target == null:
				e.stop_movement()
				e._clear_command_queue()

func _has_attack_move_order(e: Army) -> bool:
	if e.is_attack_moving: return true
	for cmd in e.command_queue:
		if cmd is Dictionary and cmd.get("type", "") == "attack_move":
			return true
	return false

func _is_auto_attack_enabled_for(owner: int, team: int) -> bool:
	return local_auto_attack and is_local_player_owned(owner, team)

# 挑选自动进攻目标：所有存活敌方主城里距离 from_pos 最近的那个。
# 多国混战时这条决定了「就近开战」而不是全军扑向同一个固定目标。
# from_pos 留空时用己方主城位置作为参考点。
func _get_auto_attack_target(owner: int, team: int, from_pos: Vector3 = Vector3.ZERO) -> Building:
	_ensure_cache_fresh()
	var origin: Vector3 = from_pos
	if origin == Vector3.ZERO:
		# 没给起点时用己方主城位置，让「最近的敌方主城」有意义
		for e in _buildings:
			if e is Building and int(e.entity_id) == 20 and e.health > 0 and e.team == team:
				origin = e.global_position
				break
	var best: Building = null
	var best_d: float = INF
	for e in _buildings:
		if not (e is Building) or int(e.entity_id) != 20 or e.health <= 0:
			continue
		if e.team == team:
			continue
		if owner >= 0 and int(e.owner_peer_id) == owner:
			continue
		if is_local_player_owned(e.owner_peer_id, e.team):
			continue
		var d: float = origin.distance_squared_to(e.global_position)
		if d < best_d:
			best_d = d
			best = e
	return best

# 新生产的军队继承当前自动进攻状态
func _apply_auto_attack_to_entity(entity: GameEntity) -> void:
	if not is_instance_valid(entity) or not (entity is Army): return
	if entity.health <= 0 or not entity._is_military(): return
	if entity.entity_id in AUTO_ATTACK_EXCLUDE_IDS: return
	if not _is_auto_attack_enabled_for(entity.owner_peer_id, entity.team): return
	if entity.current_target != null: return
	var target = _get_auto_attack_target(entity.owner_peer_id, entity.team, entity.global_position)
	if target:
		entity.attack_move_to(target.global_position)

# ==================== 游戏结束界面 ====================
func _create_game_over_panel():
	var panel = BattleStatsPanelScript.new()
	game_over_panel = panel
	game_over_panel.name = "GameOverPanel"
	game_over_panel.visible = false
	if has_node("UI"):
		$UI.add_child(game_over_panel)
	else:
		add_child(game_over_panel)
	game_over_label = panel.result_label

# 结算时统一隐藏统计面板：玩家军力统计、统计开关以及所有 AI 决策面板
func hide_all_stat_panels() -> void:
	var hud = get_node_or_null("UI")
	if hud and hud.has_method("hide_stat_panels"):
		hud.hide_stat_panels()
	for child in get_children():
		if child is AIController and is_instance_valid(child.debug_panel):
			child.debug_panel.visible = false

# 结算：先固定最后一帧统计，再交给结算面板绘制全部曲线
func _show_battle_stats() -> void:
	hide_all_stat_panels()
	if battle_stats:
		battle_stats.finalize()
	if game_over_panel and game_over_panel.has_method("show_stats"):
		game_over_panel.show_stats(battle_stats)
	if game_over_panel:
		game_over_panel.visible = true

func _create_game_timer():
	game_time_label = Label.new()
	game_time_label.name = "GameTimer"
	game_time_label.text = "00:00"
	game_time_label.add_theme_font_size_override("font_size", 28)
	game_time_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
	game_time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	game_time_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	game_time_label.position = Vector2(-60, 8)
	game_time_label.size = Vector2(120, 40)
	if has_node("UI"):
		add_child(game_time_label)
	else:
		add_child(game_time_label)

# ==================== AI / 外交面板布局 ====================
# 右下角停靠：外交面板在上、AI 面板在下；默认折叠，最多同时展开 2 个。
# 展开/折叠/创建/AI 被消灭时统一重排，并避开右上角小地图。
func _collect_panel_items(hud) -> Array:
	var items: Array = []
	# 外交面板（乱斗模式才存在）
	if hud and hud.has_method("is_diplo_collapsed") and hud.get("_diplo_panel") != null:
		items.append({
			"panel": hud.get("_diplo_panel"),
			"h": hud.get_diplo_panel_height(),
			"collapsed": hud.is_diplo_collapsed(),
			"ai": null,
			"w": hud.get_diplo_panel_width(),
		})
	var ais: Array = []
	for c in get_children():
		if c is AIController and is_instance_valid(c.debug_panel):
			ais.append(c)
	ais.sort_custom(func(a, b): return a.my_peer_id < b.my_peer_id)
	for ai in ais:
		items.append({
			"panel": ai.debug_panel,
			"h": ai.get_panel_height(),
			"collapsed": ai._panel_collapsed,
			"ai": ai,
			"w": AIController.PANEL_WIDTH,
		})
	return items

func layout_ai_debug_panels() -> void:
	var hud = get_node_or_null("UI")
	var items: Array = _collect_panel_items(hud)
	if items.is_empty(): return

	# 最多同时展开 2 个：超限时收起最早展开的
	var expanded: Array = items.filter(func(it): return not it["collapsed"])
	if expanded.size() > 2:
		expanded.sort_custom(func(a, b):
			return int(a["panel"].get_meta("expanded_at", 0)) < int(b["panel"].get_meta("expanded_at", 0)))
		for i in range(expanded.size() - 2):
			var it = expanded[i]
			if it["ai"] != null:
				it["ai"].set_panel_collapsed(true, false)
			elif hud:
				hud.set_diplo_collapsed(true, false)
		items = _collect_panel_items(hud)

	var vw: float = 2400.0
	var vh: float = 1400.0
	var vp = get_viewport()
	if vp:
		var vr = vp.get_visible_rect().size
		vw = vr.x
		vh = vr.y

	# 小地图在右上角：停靠区从它下方开始
	var dock_top: float = 408.0
	var minimap = get_node_or_null("UI/Minimap")
	if minimap:
		dock_top = minimap.position.y + minimap.size.y + 8.0
	var gap: float = 8.0
	var total_h: float = 0.0
	for it in items:
		total_h += it["h"]
	total_h += gap * (items.size() - 1)
	var y: float = maxf(dock_top, vh - 12.0 - total_h)
	for it in items:
		it["panel"].position = Vector2(vw - it["w"] - 16.0, y)
		y += it["h"] + gap

# ==================== 城堡被摧毁 → 游戏结束 ====================
# 某个 AI 玩家被消灭：发送通知、清除其全部残余单位，并移除其 AI 控制器
# （决策面板挂在 UI 下，由 AIController._exit_tree 一并释放）
func _eliminate_ai_player(owner: int) -> void:
	if owner == player_owner_id:
		return
	var info = ai_players.get(owner, {})
	var color: Color = _player_colors.get(owner, Color(1.0, 0.6, 0.2))
	# 被攻击型战报：前缀国家取被攻灭的那一方，国家名交给战况前缀显示，
	# 消息正文里不再重复写一遍
	var dead_team: int = int(info.get("team", -1))
	_show_hud_alert("城堡被攻破，残余部队已溃散", color, [dead_team], -1)
	# 残余单位/建筑（health<=0 的正在播放死亡动画，交给各自 die() 自清理）
	var to_free: Array = []
	for e in entities.get_children():
		if e is GameEntity and (e as GameEntity).owner_peer_id == owner and (e as GameEntity).health > 0:
			to_free.append(e)
	for e in to_free:
		if is_instance_valid(e):
			e.queue_free()
	# 停止并移除该国 AI 控制器
	for c in get_children():
		if c is AIController and c.my_peer_id == owner:
			c.set_process(false)
			c.set_physics_process(false)
			# 先摘掉面板引用，避免延迟布局时仍把它算进列表
			if is_instance_valid(c.debug_panel):
				c.debug_panel.queue_free()
				c.debug_panel = null
			c.queue_free()
	# 该 AI 的面板移除后，其余面板立即上移
	call_deferred("layout_ai_debug_panels")
	# 清理该国经济表，避免每帧继续刷新
	ai_players.erase(owner)
	ai_resources.erase(owner)
	ai_population.erase(owner)
	ai_limits.erase(owner)

# 单机2v2：检查同队所有城堡是否全部死亡
func _on_2v2_castle_died(team: int, owner: int = -1):
	if game_over: return
	if battle_stats:
		battle_stats.sample_now()
	# 单个 AI 的城堡被摧毁：立即通知并清场，即使本队还有其他城堡存活
	if owner != -1:
		_eliminate_ai_player(owner)
	_team_castle_count[team] = _team_castle_count.get(team, 2) - 1
	if _team_castle_count[team] > 0: return   # 还有存活城堡，继续
	game_over = true
	AudioManager.play_music("defeat" if team == get_host_team() else "victory")
	if team == get_host_team():
		# 攻守双方都带上：攻击方在前、被攻击方在后
		_show_hud_alert("我方基地正遭受攻击！", Color(1.0, 0.2, 0.1), [get_enemy_team(), get_host_team()], get_host_team())
		game_over_label.text = "你输了！"
		game_over_label.add_theme_color_override("font_color", Color.RED)
	else:
		# 攻守双方都带上：我方为攻击方，敌方为被摧毁方
		_show_hud_alert("敌军基地已被摧毁！", Color(0.2, 1.0, 0.3), [get_host_team(), get_enemy_team()], get_host_team())
		game_over_label.text = "你赢了！"
		game_over_label.add_theme_color_override("font_color", Color.GREEN)
	_show_battle_stats()
func _on_castle_died(team: int):
	if game_over: return
	if battle_stats:
		battle_stats.sample_now()
	game_over = true
	AudioManager.play_music("defeat" if team == get_host_team() else "victory")

	if team == get_host_team():
		# 攻守双方都带上：攻击方在前、被攻击方在后
		_show_hud_alert("我方基地正遭受攻击！", Color(1.0, 0.2, 0.1), [get_enemy_team(), get_host_team()], get_host_team())
		game_over_label.text = "你输了！"
		game_over_label.add_theme_color_override("font_color", Color.RED)
	else:
		# 攻守双方都带上：我方为攻击方，敌方为被摧毁方
		_show_hud_alert("敌军基地已被摧毁！", Color(0.2, 1.0, 0.3), [get_host_team(), get_enemy_team()], get_host_team())
		game_over_label.text = "你赢了！"
		game_over_label.add_theme_color_override("font_color", Color.GREEN)

	_show_battle_stats()

# 战役模式：team -> 固定人口上限（空 = 按主城/民居计算）
var campaign_pop_caps: Dictionary = {}

# ==================== 人口上限更新 ====================
func update_population_limits():
	# 闯关模式人口上限由关卡直接指定：没有主城的关卡按建筑算会变成 0，
	# 那样连初始军队都超编（生产按钮全灰），任务就没法玩了。
	if GameSettings.campaign_mode and not campaign_pop_caps.is_empty():
		player_max_pop = int(campaign_pop_caps.get(get_host_team(), 0)) \
			+ NationBonuses.get_population_bonus(team_nations.get(get_host_team(), -1))
		enemy_max_pop = int(campaign_pop_caps.get(get_enemy_team(), 0)) \
			+ NationBonuses.get_population_bonus(team_nations.get(get_enemy_team(), -1))
		return
	var p_max = 0
	var e_max = 0
	for entity in get_tree().get_nodes_in_group("pop_buildings"):
		if entity.health <= 0 or entity.build_timer > 0: continue
		if entity.team == get_host_team():
			if entity.entity_id == 20: p_max += 20
			elif entity.entity_id == 28: p_max += 10
		elif entity.team == get_enemy_team():
			if entity.entity_id == 20: e_max += 20
			elif entity.entity_id == 28: e_max += 10
	player_max_pop = p_max
	enemy_max_pop = e_max

	player_max_pop += NationBonuses.get_population_bonus(team_nations.get(get_host_team(), -1))
	enemy_max_pop += NationBonuses.get_population_bonus(team_nations.get(get_enemy_team(), -1))
	if is_research_mode():
		player_max_pop += research_pop_bonus(player_owner_id, get_host_team())
		enemy_max_pop += research_pop_bonus(-1, get_enemy_team())

func increase_population(team: int, amount: int = 1):
	if team == get_host_team():
		player_pop += amount
	else:
		enemy_pop += amount

func decrease_population(team: int, amount: int = 1):
	if team == get_host_team():
		player_pop = max(0, player_pop - amount)
	else:
		enemy_pop = max(0, enemy_pop - amount)

func can_train_unit(team: int) -> bool:
	return (team == get_host_team() and player_pop < player_max_pop) or (team == get_enemy_team() and enemy_pop < enemy_max_pop)

	
# ==================== 初始化 ====================
func _ready():
	# 新手教程沿用原有成长节奏，强制经典模式，避免教程目标与科技解锁冲突。
	# 战役可由选关界面选择科研模式，不再在这里强制回经典。
	if GameSettings.tutorial_mode:
		GameSettings.progression_mode = GameSettings.ProgressionMode.CLASSIC
	# 暂停时整局仍要接收建造/生产/升级/右键指令，所以管理器保持运行；
	# 真正的单位、建筑、弹丸会在 spawn 时显式设为 PAUSABLE，由 SceneTree.paused 冻结。
	process_mode = Node.PROCESS_MODE_ALWAYS
	# 每局重新随机国家颜色；颜色不再固定对应某个国家。
	RTSConfig.randomize_nation_colors()
	add_to_group("battle_manager")
	_physics_tick_original = Engine.physics_ticks_per_second
	_physics_max_steps_original = Engine.max_physics_steps_per_frame
	# 地图规则修正（子节点 Map 的 _ready 先于本节点执行，此时预设已解析完成）
	if $Map:
		var preset = $Map.get("map_preset")
		if preset is Dictionary:
			map_modifiers = preset.get("modifiers", {})
	_init_building_defs()
	battle_stats = BattleStatsScript.new(self)
	if not is_online and not GameSettings.is_ffa and not GameSettings.campaign_mode:
		# 单机版每局随机分配红/蓝阵营（1v1/2v2/3v3 的出生侧与颜色一起交换）。
		# 乱斗模式玩家固定蓝方（其余国家使用独立 team 3..），不参与红蓝对调。
		if randi() % 2 == 1:
			player_team = RTSConfig.Team.RED
			enemy_team = RTSConfig.Team.BLUE
		else:
			player_team = RTSConfig.Team.BLUE
			enemy_team = RTSConfig.Team.RED
		# 1v1 的静态 AI 在子节点 _ready 已跑完，这里立刻把它的阵营改成玩家对立面；
		# 2v2/3v3 会在 _init_multi_single 里销毁这个静态 AI。
		var static_ai = get_node_or_null("AIController")
		if static_ai:
			static_ai.my_team = enemy_team
	if not is_online:
		if GameSettings.campaign_mode:
			# 闯关模式：固定玩家蓝方、敌国红方，开局生成与胜负全部交给战役导演
			player_team = RTSConfig.Team.BLUE
			enemy_team = RTSConfig.Team.RED
			var campaign_ai = get_node_or_null("AIController")
			if campaign_ai:
				campaign_ai.my_team = enemy_team
			var director = CampaignDirectorScript.new()
			director.name = "CampaignDirector"
			director.process_mode = Node.PROCESS_MODE_PAUSABLE
			add_child(director)
		elif GameSettings.is_ffa:
			_init_ffa_single(GameSettings.ffa_nation_count)
		elif game_mode_2v2:
			_init_2v2_single()
		elif GameSettings.ai_mode >= 2:
			_init_multi_single(GameSettings.ai_mode)
		else:
			call_deferred("_init_entities_deferred")   # 单机1v1原逻辑
	if info_panel: info_panel.battle = self
	# 命令卡覆盖层
	var card = CommandCard.new(); card.name = "CommandCard"
	$UI.add_child(card)
	_create_game_over_panel()
	set_process_input(true)
	_create_game_timer()
	_create_diag_label()
	AudioManager.play_music("battle")
	set_process(true)
	# 默认画质固定为“极致”，不进入后期自动降档逻辑。
	_apply_default_quality()
	# 新手教程对局：等实体初始化后显示左上角动态目标卡（仅单机）
	if GameSettings.tutorial_mode and not is_online:
		call_deferred("_spawn_tutorial_hint")

func _spawn_tutorial_hint() -> void:
	if not GameSettings.tutorial_mode or is_online:
		return
	if get_node_or_null("TutorialHint") != null:
		return
	var hint = TutorialHintScript.new()
	hint.name = "TutorialHint"
	hint.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(hint)

# ==================== 乱斗模式（FFA） ====================
# 开局：N 国环绕布局，各国独立 team/owner/颜色/国家加成/AI控制器。
# 玩家为 layout[0]（地图正下方，蓝队 BLUE=1）；其余 AI 国依次分到 team 3..（避开
# RED=0 与 NEUTRAL=2），保证"同队即友军"的既有判定在 FFA 里各国默认互敌。
func _init_ffa_single(_nation_count: int):
	is_ffa = true
	var map = $Map
	if not map: return
	var count = clampi(_nation_count, 3, 5)
	var layout = map.get_ffa_castle_positions(count)
	if layout.size() < count: return

	# —— 外交管理器（先建，各国注册进关系表） ——
	diplomacy = DiplomacyManager.new()
	diplomacy.setup(self)
	diplomacy.name = "Diplomacy"
	add_child(diplomacy)

	player_owner_id = 1
	player_resources = {"gold": 500, "wood": 500, "stone": 300, "food": 500, "oil": 0}
	player_pop = 0; player_max_pop = 20
	player_resource_limits = {"gold": 500, "wood": 500, "stone": 500, "food": 500, "oil": 0}
	team_nations[RTSConfig.Team.BLUE] = GameSettings.player_nation

	# 其余 count-1 个 AI 国家：从国家池随机抽不重复国家（不含玩家所选国家）
	var ai_nation_pool: Array = []
	for n in range(RTSConfig.Nation.size()):
		if n != GameSettings.player_nation:
			ai_nation_pool.append(n)
	ai_nation_pool.shuffle()
	var ai_nations = ai_nation_pool.slice(0, count - 1)

	# 玩家与 AI 都使用国家色；乱斗各国国家唯一，不会撞色。
	_owner_nations[player_owner_id] = GameSettings.player_nation
	_player_colors[player_owner_id] = RTSConfig.get_nation_color(GameSettings.player_nation)

	# —— 玩家城堡 ——
	var player_castle = null
	var player_cfg = EntityDatabase.get_config(20)
	player_cfg["owner_peer_id"] = player_owner_id
	player_cfg["team"] = RTSConfig.Team.BLUE
	player_castle = spawn_entity(player_cfg, RTSConfig.Team.BLUE, layout[0], 1)
	if player_castle:
		player_castle.owner_peer_id = player_owner_id
		player_castle.died.connect(_on_ffa_castle_died.bind(player_owner_id))
		var start_lv = NationBonuses.get_castle_start_level(GameSettings.player_nation)
		player_castle.upgrade_level = start_lv
		player_castle.level = start_lv
	ai_players[player_owner_id] = {"castle": player_castle, "team": RTSConfig.Team.BLUE, "slot": 0, "nation": GameSettings.player_nation}
	diplomacy.register_nation(player_owner_id, RTSConfig.Team.BLUE, GameSettings.player_nation, true, RTSConfig.get_nation_color(GameSettings.player_nation))

	# 玩家初始农民
	var peasant_cfg = EntityDatabase.get_config(10)
	for i in range(3):
		var cfg = peasant_cfg.duplicate()
		cfg["owner_peer_id"] = player_owner_id
		spawn_entity(cfg, RTSConfig.Team.BLUE, layout[0] + Vector3(randf_range(-3, 3), 0, randf_range(-3, 3)), 1)

	# —— AI 国家循环：独立资源/人口/上限/唯一 team/国家色/AI 控制器 ——
	for ai_index in range(ai_nations.size()):
		var pid = 3000 + ai_index        # AI owner_peer_id（乱斗独立段，不与 2v2/3v3 冲突）
		var team = 3 + ai_index          # 唯一 team：3..（避开 RED=0/NEUTRAL=2/BLUE=1）
		var nation = ai_nations[ai_index]
		var castle_pos = layout[1 + ai_index]
		var col: Color = RTSConfig.get_nation_color(nation)
		_owner_nations[pid] = nation
		_player_colors[pid] = col

		ai_resources[pid] = {"gold": 500, "wood": 500, "stone": 300, "food": 500, "oil": 0}
		ai_population[pid] = {"current": 0, "max": 20}
		ai_limits[pid] = {"gold": 500, "wood": 500, "stone": 500, "food": 500, "oil": 0}

		var castle_cfg = EntityDatabase.get_config(20)
		castle_cfg["owner_peer_id"] = pid
		castle_cfg["team"] = team
		var castle = spawn_entity(castle_cfg, team, castle_pos, 1)
		if castle:
			castle.owner_peer_id = pid
			castle.died.connect(_on_ffa_castle_died.bind(pid))
			var start_lv_ai = NationBonuses.get_castle_start_level(nation)
			castle.upgrade_level = start_lv_ai
			castle.level = start_lv_ai
		ai_players[pid] = {"castle": castle, "team": team, "slot": ai_index + 1, "nation": nation}
		diplomacy.register_nation(pid, team, nation, false, col)

		for j in range(3):
			var cfg = peasant_cfg.duplicate()
			cfg["owner_peer_id"] = pid
			spawn_entity(cfg, team, castle_pos + Vector3(randf_range(-3, 3), 0, randf_range(-3, 3)), 1)

		var ai = AIController.new()
		ai.my_peer_id = pid
		ai.my_team = team
		ai.name = "AIController_%d" % pid
		add_child(ai)

	# 禁用 1v1 静态 AI（my_peer_id=-1），避免作为额外红队 AI 乱跑
	var static_ai = get_node_or_null("AIController")
	if static_ai:
		static_ai.set_process(false)
		static_ai.set_physics_process(false)
		static_ai.queue_free()

	# 资源点
	for res in map.resource_positions:
		var cfg = EntityDatabase.get_config(res.type)
		spawn_entity(cfg, RTSConfig.Team.NEUTRAL, res.pos)

	_init_fog_grid()
	# 聚焦玩家城堡
	if player_castle:
		var cam = get_viewport().get_camera_3d()
		if cam:
			cam.global_position = Vector3(player_castle.global_position.x, cam.global_position.y, player_castle.global_position.z)

# 乱斗：某国城堡被摧毁 → 该国淘汰。玩家被灭即败；存活国剩 1 时判定胜者。
func _on_ffa_castle_died(owner: int):
	if game_over: return
	if battle_stats:
		battle_stats.sample_now()
	var remaining: Array = diplomacy.notify_castle_died(owner) if diplomacy else []
	# 清除该国残余军队/建筑（AI 走统一清场流程并发送通知；玩家则清场后判负）
	if owner != player_owner_id:
		_eliminate_ai_player(owner)
	else:
		var to_free: Array = []
		for e in entities.get_children():
			if e is GameEntity and (e as GameEntity).owner_peer_id == owner and (e as GameEntity).health > 0:
				to_free.append(e)
		for e in to_free:
			if is_instance_valid(e):
				e.queue_free()
		ai_players.erase(owner)
		ai_resources.erase(owner)
		ai_population.erase(owner)
		ai_limits.erase(owner)

	# 玩家被消灭 → 直接结束
	if owner == player_owner_id:
		game_over = true
		AudioManager.play_music("defeat")
		game_over_label.text = "你被消灭了！"
		game_over_label.add_theme_color_override("font_color", Color.RED)
		_show_battle_stats()
		return
	# 只剩最后一个国家 → 判定胜者
	if remaining.size() <= 1:
		game_over = true
		if remaining.size() == 1 and remaining[0] == player_owner_id:
			AudioManager.play_music("victory")
			game_over_label.text = "你赢得了乱斗！"
			game_over_label.add_theme_color_override("font_color", Color.GREEN)
		else:
			AudioManager.play_music("defeat")
			var winner_name = diplomacy.get_display_name(remaining[0]) if remaining.size() == 1 else "无人"
			game_over_label.text = "%s 赢得了乱斗！" % winner_name
			game_over_label.add_theme_color_override("font_color", Color(1.0, 0.6, 0.2))
		_show_battle_stats()


func _init_2v2_single():
	# 定义四个玩家：玩家+1名AI队友同阵营，2名AI敌人另一阵营。
	# 阵营每局随机，所以这里按 player_team/enemy_team 生成，而不是写死蓝/红。
	var setup = [
		{ "peer_id": 1, "team": player_team, "slot": 0, "is_human": true, "nation": GameSettings.player_nation },
		{ "peer_id": 2, "team": player_team, "slot": 1, "is_human": false, "nation": randi() % RTSConfig.Nation.size() },
		{ "peer_id": 3, "team": enemy_team, "slot": 0, "is_human": false, "nation": randi() % RTSConfig.Nation.size() },
		{ "peer_id": 4, "team": enemy_team, "slot": 1, "is_human": false, "nation": randi() % RTSConfig.Nation.size() },
	]

	var map = $Map
	if not map: return
	var positions = map.get_four_castle_positions()   # [blue1, blue2, red1, red2]
	var enemy_nation = GameSettings.enemy_nation
	if enemy_nation < 0 or enemy_nation >= RTSConfig.Nation.size():
		enemy_nation = randi() % RTSConfig.Nation.size()
	team_nations = {
		player_team: GameSettings.player_nation,
		enemy_team: enemy_nation
	}

	_team_castle_count[player_team] = 2
	_team_castle_count[enemy_team] = 2
	# 颜色按国家，不再按阵营。
	_owner_nations[1] = GameSettings.player_nation
	_player_colors[1] = RTSConfig.get_nation_color(GameSettings.player_nation)
	for info in setup:
		var pid = info.peer_id
		var team = info.team
		var slot = info.slot
		var info_nation: int = int(info.get("nation", -1))
		_owner_nations[pid] = info_nation
		if pid != 1:
			_player_colors[pid] = RTSConfig.get_nation_color(info_nation)
		var castle_pos = positions[slot] if team == RTSConfig.Team.BLUE else positions[2 + slot]

		# 初始化资源
		if info.is_human:
			player_resources = {"gold": 500, "wood": 500, "stone": 300, "food": 500, "oil": 0}
			player_pop = 0; player_max_pop = 20
			player_owner_id = pid
		else:
			ai_resources[pid] = {"gold": 500, "wood": 500, "stone": 300, "food": 500, "oil": 0}
			ai_population[pid] = {"current": 0, "max": 20}
			ai_limits[pid] = {"gold": 500, "wood": 500, "stone": 500, "food": 500, "oil": 0}
			# 创建AI控制器
			var ai = AIController.new()
			ai.my_peer_id = pid
			ai.my_team = team
			ai.name = "AIController_%d" % pid
			add_child(ai)

		# 创建城堡
		var castle_cfg = EntityDatabase.get_config(20)
		castle_cfg["team"] = team
		castle_cfg["owner_peer_id"] = pid
		var castle = spawn_entity(castle_cfg, team, castle_pos, 1)
		if castle:
			castle.owner_peer_id = pid
			if info.is_human:
				castle.died.connect(_on_2v2_castle_died.bind(team))
			else:
				castle.died.connect(_on_2v2_castle_died.bind(team, pid))
			ai_players[pid] = {"castle": castle, "team": team, "slot": slot, "nation": info.get("nation", -1)}

		# 生成3个农民
		var peasant_cfg = EntityDatabase.get_config(10)
		peasant_cfg["team"] = team
		for i in range(3):
			var pos = castle_pos + Vector3(randf_range(-3,3), 0, randf_range(-3,3))
			var cfg = peasant_cfg.duplicate()
			cfg["owner_peer_id"] = pid
			spawn_entity(cfg, team, pos, 1)

	# 资源点
	for res in map.resource_positions:
		var cfg = EntityDatabase.get_config(res.type)
		var e = spawn_entity(cfg, RTSConfig.Team.NEUTRAL, res.pos)

	_init_fog_grid()
	# 聚焦玩家城堡
	var player_castle = ai_players[1].castle
	if player_castle:
		var cam = get_viewport().get_camera_3d()
		if cam:
			cam.global_position = Vector3(player_castle.global_position.x, cam.global_position.y, player_castle.global_position.z)

# 随机 AI 国家池：排除玩家国家，尽量让每个 AI 国家不同
func _random_ai_nation_pool(count: int) -> Array:
	var pool: Array = []
	for n in range(RTSConfig.Nation.size()):
		if n != GameSettings.player_nation:
			pool.append(n)
	pool.shuffle()
	var out: Array = []
	while out.size() < count:
		if pool.is_empty():
			for n in range(RTSConfig.Nation.size()):
				if n != GameSettings.player_nation:
					pool.append(n)
			pool.shuffle()
		out.append(pool.pop_back())
	return out

# 单机对称团队战：玩家+同阵营AI vs 另一阵营AI（2V2/3V3），每方人数=模式值。
# 颜色不再按阵营区分，而是按国家色区分，避免同队玩家/队友撞色。
func _init_multi_single(mode: int):
	var map = $Map
	if not map: return
	mode = clampi(mode, 2, 3)
	var layout = map.get_four_castle_positions() if mode == 2 else map.get_six_castle_positions()
	# layout 顺序: [blue1, blue2, (blue3), red1, red2, (red3)]

	player_owner_id = 1
	player_resources = {"gold": 500, "wood": 500, "stone": 300, "food": 500, "oil": 0}
	player_pop = 0; player_max_pop = 20
	player_resource_limits = {"gold": 500, "wood": 500, "stone": 500, "food": 500, "oil": 0}
	# 阵营每局随机：玩家可能占用蓝/红任意一侧，AI 队友和敌人随之整体对调。
	var enemy_nation = GameSettings.enemy_nation
	if enemy_nation < 0 or enemy_nation >= RTSConfig.Nation.size():
		enemy_nation = randi() % RTSConfig.Nation.size()
	team_nations = {
		player_team: GameSettings.player_nation,
		enemy_team: enemy_nation
	}
	# 先登记 owner->nation，保证首座城堡/农民生成时就按国家色着色。
	_owner_nations[player_owner_id] = GameSettings.player_nation

	_team_castle_count[player_team] = mode
	_team_castle_count[enemy_team] = mode

	# 所有 AI 国家独立随机（排除玩家国家，尽量互不重复）
	var ai_nation_order: Array = _random_ai_nation_pool((mode - 1) + mode)
	var ai_nation_idx: int = 0

	# 玩家城堡：蓝方取 layout[0]，红方取 layout[mode]（各自阵营的 0 号位）
	var player_pos = layout[0] if player_team == RTSConfig.Team.BLUE else layout[mode]
	var player_castle = null
	# 颜色按国家，不再按阵营。
	_player_colors[player_owner_id] = RTSConfig.get_nation_color(GameSettings.player_nation)
	var player_cfg = EntityDatabase.get_config(20)
	player_cfg["owner_peer_id"] = player_owner_id
	player_cfg["team"] = player_team
	player_castle = spawn_entity(player_cfg, player_team, player_pos, 1)
	if player_castle:
		player_castle.owner_peer_id = player_owner_id
		player_castle.died.connect(_on_2v2_castle_died.bind(player_team))
		var start_lv = NationBonuses.get_castle_start_level(GameSettings.player_nation)
		player_castle.upgrade_level = start_lv
		player_castle.level = start_lv
	ai_players[player_owner_id] = {"castle": player_castle, "team": player_team, "slot": 0, "nation": GameSettings.player_nation}

	# 玩家初始农民
	var peasant_cfg = EntityDatabase.get_config(10)
	for i in range(3):
		var cfg = peasant_cfg.duplicate()
		cfg["owner_peer_id"] = player_owner_id
		spawn_entity(cfg, player_team, player_pos + Vector3(randf_range(-3,3), 0, randf_range(-3,3)), 1)

	# 玩家阵营 AI（队友）与敌方 AI，各自独立资源/人口/上限/国家色/AI控制器
	for team in [player_team, enemy_team]:
		var is_ally_team = team == player_team
		var count = (mode - 1) if is_ally_team else mode
		var base_pid = 1000 if team == RTSConfig.Team.BLUE else 2000
		for ai_index in range(count):
			var pid = base_pid + ai_index
			var nation = ai_nation_order[ai_nation_idx] if ai_nation_idx < ai_nation_order.size() else (randi() % RTSConfig.Nation.size())
			ai_nation_idx += 1
			# 玩家阵营 AI 队友占 1..mode-1 号位，敌方 AI 占 0..mode-1 号位
			var slot = (ai_index + 1) if is_ally_team else ai_index
			var castle_pos = layout[slot] if team == RTSConfig.Team.BLUE else layout[mode + slot]
			_owner_nations[pid] = nation
			_player_colors[pid] = RTSConfig.get_nation_color(nation)

			ai_resources[pid] = {"gold": 500, "wood": 500, "stone": 300, "food": 500, "oil": 0}
			ai_population[pid] = {"current": 0, "max": 20}
			ai_limits[pid] = {"gold": 500, "wood": 500, "stone": 500, "food": 500, "oil": 0}

			var castle_cfg = EntityDatabase.get_config(20)
			castle_cfg["owner_peer_id"] = pid
			castle_cfg["team"] = team
			var castle = spawn_entity(castle_cfg, team, castle_pos, 1)
			if castle:
				castle.owner_peer_id = pid
				castle.died.connect(_on_2v2_castle_died.bind(team, pid))
				var start_lv_ai = NationBonuses.get_castle_start_level(nation)
				castle.upgrade_level = start_lv_ai
				castle.level = start_lv_ai
			ai_players[pid] = {"castle": castle, "team": team, "slot": slot, "nation": nation}

			# AI初始农民
			for j in range(3):
				var cfg = peasant_cfg.duplicate()
				cfg["owner_peer_id"] = pid
				spawn_entity(cfg, team, castle_pos + Vector3(randf_range(-3,3), 0, randf_range(-3,3)), 1)

			# 创建AI控制器
			var ai = AIController.new()
			ai.my_peer_id = pid
			ai.my_team = team
			ai.name = "AIController_%d" % pid
			add_child(ai)

	# 禁用 1v1 静态 AI（my_peer_id=-1），避免作为额外红队AI乱跑
	var static_ai = get_node_or_null("AIController")
	if static_ai:
		static_ai.set_process(false)
		static_ai.set_physics_process(false)
		static_ai.queue_free()

	# 资源点
	for res in map.resource_positions:
		var cfg = EntityDatabase.get_config(res.type)
		var e = spawn_entity(cfg, RTSConfig.Team.NEUTRAL, res.pos)

	_init_fog_grid()
	# 聚焦玩家城堡
	if player_castle:
		var cam = get_viewport().get_camera_3d()
		if cam:
			cam.global_position = Vector3(player_castle.global_position.x, cam.global_position.y, player_castle.global_position.z)
# 获取房主队伍的统一入口（子类 OnlineBattleManager 重写为实际队伍）
func get_host_team() -> int:
	return player_team

# 与房主敌对的队伍（1v1/2v2/3v3 只有红蓝两队；乱斗另有独立 team）
func get_enemy_team() -> int:
	return RTSConfig.Team.RED if get_host_team() == RTSConfig.Team.BLUE else RTSConfig.Team.BLUE

# 把 team 判断统一收敛到这两个接口：单机随机阵营后，玩家不一定还是 BLUE。
func is_host_team(team: int) -> bool:
	return team == get_host_team()

func get_team_resources(team: int) -> Dictionary:
	return player_resources if is_host_team(team) else enemy_resources

func get_team_resource_limits(team: int) -> Dictionary:
	return player_resource_limits if is_host_team(team) else enemy_resource_limits

# 按队伍找主城（单机 2v2/3v3 同队多城时只取第一座；调用方需要 owner 精度时自行过滤）
func get_castle_by_team(team: int) -> Building:
	_ensure_cache_fresh()
	for entity in _buildings:
		if is_instance_valid(entity) and entity.entity_id == 20 and entity.team == team:
			return entity
	return null

# 获取房主资源的统一入口（子类 OnlineBattleManager 重写为 peer_id=1 格式）
func get_host_resources() -> Dictionary:
	return player_resources
func get_host_pop() -> int:
	return player_pop
func get_host_max_pop() -> int:
	return player_max_pop
func get_host_limits() -> Dictionary:
	return player_resource_limits

# 根据owner_id获取资源字典
func get_resources_for(owner_id: int) -> Dictionary:
	if owner_id == player_owner_id:
		return player_resources
	if owner_id == -1:
		return enemy_resources
	return ai_resources.get(owner_id, {})

# 根据owner_id扣除资源
func deduct_resources_for(owner_id: int, cost: Dictionary) -> bool:
	var res = get_resources_for(owner_id)
	for k in cost: 
		if res.get(k, 0) < cost[k]: return false
	for k in cost: 
		res[k] -= cost[k]

	return true

# 获取人口
func get_population_for(owner_id: int) -> Dictionary:
	if owner_id == player_owner_id:
		return {"current": player_pop, "max": player_max_pop}
	return ai_population.get(owner_id, {"current":0,"max":20})

# 增加人口
func increase_population_for(owner_id: int, amount: int = 1):
	if owner_id == player_owner_id:
		player_pop += amount
	else:
		if ai_population.has(owner_id):
			ai_population[owner_id]["current"] += amount

# 减少人口
func decrease_population_for(owner_id: int, amount: int = 1):
	if owner_id == player_owner_id:
		player_pop = max(0, player_pop - amount)
	else:
		if ai_population.has(owner_id):
			ai_population[owner_id]["current"] = max(0, ai_population[owner_id]["current"] - amount)

# 检查是否可以训练
func can_train_for(owner_id: int) -> bool:
	var pop = get_population_for(owner_id)
	return pop["current"] < pop["max"]

# 增加资源（采集时调用）
func add_resource_for(owner_id: int, type: String, amount: int):
	var res = get_resources_for(owner_id)
	if res.has(type):
		res[type] = min(res[type] + amount, get_limits_for(owner_id).get(type, 99999))

# 扣除资源（商人和建筑使用）
func deduct_player_resources(owner_id: int, cost: Dictionary) -> bool:
	var res = get_resources_for(owner_id)
	for k in cost:
		if res.get(k, 0) < cost[k]:
			return false
	for k in cost:
		res[k] -= cost[k]

	return true

# 获取上限
func get_limits_for(owner_id: int) -> Dictionary:
	if owner_id == player_owner_id:
		return player_resource_limits
	return ai_limits.get(owner_id, {})

# 单机多AI：指定 owner 交付资源（AI难度资源倍率）
func deliver_player_resources(owner_id: int, cargo: Dictionary):
	var mult = 1.0
	if owner_id != player_owner_id:
		if GameSettings.ai_difficulty == GameSettings.AIDifficulty.NORMAL: mult = 2.0
		elif GameSettings.ai_difficulty >= GameSettings.AIDifficulty.HARD: mult = 3.0
	for t in cargo:
		var amount = int(cargo[t] * mult)
		if battle_stats:
			battle_stats.record_gathered(owner_id, -1, amount)
		add_resource_for(owner_id, t, amount)

# 单机多AI：人口增减（统一走 owner API）
func decrease_player_population(owner_id: int, amount: int = 1):
	decrease_population_for(owner_id, amount)

func increase_player_population(owner_id: int, amount: int = 1):
	increase_population_for(owner_id, amount)

# 单机多AI：生产检查（人口 < 上限）
func can_player_train(owner_id: int) -> bool:
	return can_train_for(owner_id)

# ==================== 官员编制上限 ====================
# 官员与农民共用随机人物模型；这里只负责生产端：官员总数（含排队中）
# 不得超过己方已完成、可进驻建筑的数量，避免书院无限排队刷出一堆无处安放的官员。
func _is_official_host_building(b: Building) -> bool:
	if not is_instance_valid(b):
		return false
	if b.health <= 0.0 or b.build_timer > 0.0:
		return false
	return b.entity_id not in OFFICIAL_HOST_EXCLUDE_IDS

func _same_owner_or_team(entity_owner: int, entity_team: int, owner_peer_id: int, team: int) -> bool:
	# 1v1/战役的开局实体只登记队伍、没有 owner_peer_id；
	# 玩家科研按 owner=1 查询时，必须把这类实体按同队算进来，
	# 否则“已完成主城”和升时代建筑条件永远不满足。
	if entity_owner < 0:
		return entity_team == team
	if owner_peer_id != -1:
		return entity_owner == owner_peer_id
	return entity_team == team

func get_official_host_capacity(team: int, owner_peer_id: int) -> int:
	_ensure_cache_fresh()
	var capacity := 0
	for b in _buildings:
		if not _is_official_host_building(b):
			continue
		if not _same_owner_or_team(b.owner_peer_id, b.team, owner_peer_id, team):
			continue
		capacity += 1
	return capacity

func count_official_units(team: int, owner_peer_id: int, include_queue: bool = true) -> int:
	_ensure_cache_fresh()
	var total := 0
	for e in _armies:
		if not is_instance_valid(e) or e.health <= 0:
			continue
		if e.entity_id not in OFFICIAL_UNIT_IDS:
			continue
		if not _same_owner_or_team(e.owner_peer_id, e.team, owner_peer_id, team):
			continue
		total += 1
	if include_queue:
		for b in _buildings:
			if not is_instance_valid(b):
				continue
			if not _same_owner_or_team(b.owner_peer_id, b.team, owner_peer_id, team):
				continue
			for queued_id in b.production_queue:
				if int(queued_id) in OFFICIAL_UNIT_IDS:
					total += 1
	return total

# Building.try_produce 在扣资源前调用：名额已满时直接拒绝，客户端 UI 也会置灰按钮。
func can_produce_official(unit_id: int, building: Building) -> bool:
	if unit_id not in OFFICIAL_UNIT_IDS:
		return true
	if not is_instance_valid(building):
		return false
	var capacity := get_official_host_capacity(building.team, building.owner_peer_id)
	return count_official_units(building.team, building.owner_peer_id) < capacity

# 单机多AI：按 owner 刷新资源上限（建筑/仓库/船坞）
func update_player_limits(owner_id: int):
	var limits = get_limits_for(owner_id)
	if limits.is_empty(): return
	var castle = 0
	var warehouse = 0
	var shipyard = 0
	for e in get_tree().get_nodes_in_group("storage_buildings"):
		if e.owner_peer_id == owner_id and e.health > 0:
			if e.entity_id == 20: castle += 1
			elif e.entity_id == 22 and e.build_timer <= 0: warehouse += e.building_data.get("storage_bonus", 0)
			elif e.entity_id == 23: shipyard += 1
	limits["gold"] = 500 + castle*300 + warehouse
	limits["wood"] = 500 + castle*300 + warehouse
	limits["stone"] = 500 + castle*300 + warehouse
	limits["food"] = 500 + castle*300 + warehouse
	limits["oil"] = shipyard * 700

# 单机多AI：按 owner 刷新人口上限（城堡+房屋+国家加成）
func update_player_population(owner_id: int):
	var p_max = 0
	for entity in get_tree().get_nodes_in_group("pop_buildings"):
		if entity.owner_peer_id == owner_id and entity.health > 0 and entity.build_timer <= 0:
			if entity.entity_id == 20: p_max += 20
			elif entity.entity_id == 28: p_max += 10
	var nation = team_nations.get(get_host_team(), -1) if owner_id == player_owner_id else ai_players.get(owner_id, {}).get("nation", -1)
	p_max += NationBonuses.get_population_bonus(nation)
	if is_research_mode():
		var team := get_team_of_owner(owner_id)
		if team < 0 and owner_id == player_owner_id:
			team = get_host_team()
		p_max += research_pop_bonus(owner_id, team)
	if owner_id == player_owner_id:
		player_max_pop = p_max
	else:
		var pop = ai_population.get(owner_id)
		if pop:
			pop["max"] = p_max

# 直接重算“当前人口”：以“存活且占人口额度”的实体为准，按 owner（或队伍）统计，
# 避免 spawn/die 的事件式 ±1 记录出现漂移（例如中立动物的死亡被误减）
func recount_current_population():
	if is_online:
		return
	_ensure_cache_fresh()
	var counts := {}
	var team_blue := 0
	var team_red := 0
	for e in _all_entities:
		if not is_instance_valid(e) or e.health <= 0:
			continue
		if not _occupies_population(e):
			continue
		if e.owner_peer_id != -1:
			counts[e.owner_peer_id] = counts.get(e.owner_peer_id, 0) + 1
		elif e.team == get_host_team():
			team_blue += 1
		elif e.team == get_enemy_team():
			team_red += 1
	if ai_players.is_empty():
		# 纯队伍制（离线 1v1）：玩家/敌方各维护一份
		player_pop = team_blue
		enemy_pop = team_red
	else:
		# owner 制（单机 FFA / 2V2 / 多 AI）：玩家映射 player_owner_id，AI 各自入账
		player_pop = counts.get(player_owner_id, 0)
		for pid in ai_population:
			ai_population[pid]["current"] = counts.get(pid, 0)

# 该实体是否占用人口额度 —— 口径与 spawn_entity 的增减、GameEntity.die 的扣除保持一致
func _occupies_population(e) -> bool:
	if e is Army:
		return e.entity_id < 60
	if e is Building:
		return e.entity_id == 25 or e.entity_id == 26
	return false

# Global building type upgrade (2v2: per-player via owner_peer_id, 1v1: per-team)
func get_building_type_level(team: int, building_id: int, peer_id: int = -1) -> int:
	var key = peer_id if peer_id != -1 else team
	if not team_building_levels.has(key):
		team_building_levels[key] = {}
	return team_building_levels[key].get(building_id, 1)

func upgrade_building_type(team: int, building_id: int, from_building: Building):
	var pid = from_building.owner_peer_id
	var key = pid if pid != -1 else team
	if not team_building_levels.has(key):
		team_building_levels[key] = {}
	var new_lv = team_building_levels[key].get(building_id, 1) + 1
	team_building_levels[key][building_id] = new_lv
	# Apply to all existing buildings of this type (same owner in 2v2, same team in 1v1)
	var upgrade = from_building.upgrade_data[min(from_building.upgrade_level - 1, from_building.upgrade_data.size() - 1)]
	for e in entities.get_children():
		if e is Building and e.entity_id == building_id and e.health > 0:
			var matches = (pid != -1 and e.owner_peer_id == pid) or (pid == -1 and e.team == team)
			if not matches: continue
			e.upgrade_level = new_lv
			e.level = new_lv
			e.max_health += upgrade.get("health_bonus", 0)
			e.health = min(e.health + upgrade.get("health_bonus", 0), e.max_health)
			e.melee_armor += upgrade.get("melee_armor_bonus", upgrade.get("armor_bonus", 0))
			e.shield_armor += upgrade.get("shield_armor_bonus", upgrade.get("armor_bonus", 0))
			e.attack += upgrade.get("attack_bonus", 0)
			# 升级属于基础值，不把增量算进科研/官员分项
			e.apply_upgrade_stat_delta(upgrade)
			# 按 unlock_level / 当前等级同步生产列表，支持同一级解锁多个单位
			e._sync_production_unlocks()
			# 等级外观随全局升级同步刷新（同类型所有建筑一起升）
			e.refresh_level_visual()
			# 兼容不在 produces 中、只通过升级解锁的特殊单位（如集市商人）
			var unlock_ids: Array = []
			if upgrade.has("unlocks_units") and upgrade["unlocks_units"] is Array:
				unlock_ids = upgrade["unlocks_units"]
			elif upgrade.has("unlocks_unit"):
				unlock_ids = [upgrade["unlocks_unit"]]
			for uid in unlock_ids:
				var uc = EntityDatabase.get_config(uid)
				if uc.is_empty():
					continue
				var dup = false
				for ep in e.production_list:
					if ep.get("unit_id") == uid:
						dup = true
						break
				if not dup:
					e.production_list.append({"unit_id": uid, "cooldown": uc.get("attack_speed", 5.0), "queue_limit": 3})
			# Warehouse bonus
			if e.entity_id == 22 and upgrade.has("storage_bonus"):
				e.building_data["storage_bonus"] = e.building_data.get("storage_bonus", 0) + upgrade["storage_bonus"]
			# Nation units
			if e.entity_id == 53 and new_lv >= 1:
				var nation = get_team_nation(team)
				if nation >= 0:
					e._unlock_nation_units(nation)
	if pid != -1:
		update_player_limits(pid)
		update_player_population(pid)
	else:
		update_resource_limits(team)
		update_population_limits()

func _init_building_defs():
	building_defs.clear()
	for cfg in EntityDatabase.configs.values():
		if cfg.type == 1 and cfg.id != 20:
			building_defs.append(cfg.duplicate())

func _init_entities_deferred():
	var map = $Map
	if not map: return

	# 单机随机到红方时，玩家使用红方出生点、敌方使用蓝方出生点；
	# 这样海岸登陆等非对称地图也会随机决定玩家在海岛还是外周。
	var host_pos = map.player_castle_pos
	var foe_pos = map.enemy_castle_pos
	if not is_online and get_host_team() == RTSConfig.Team.RED:
		host_pos = map.enemy_castle_pos
		foe_pos = map.player_castle_pos
	player_castle_pos = host_pos
	enemy_castle_pos = foe_pos

	# 获取国家
	var player_nation = GameSettings.player_nation
	var enemy_nation = GameSettings.enemy_nation
	if enemy_nation < 0 or enemy_nation >= RTSConfig.Nation.size():
		enemy_nation = randi() % RTSConfig.Nation.size()

	team_nations = {
		get_host_team(): player_nation,
		get_enemy_team(): enemy_nation
	}

	# 生成玩家城堡
	var castle_cfg = EntityDatabase.get_config(20)
	castle_cfg["team"] = get_host_team()
	var player_castle = spawn_entity(castle_cfg, get_host_team(), player_castle_pos)
	if player_castle:
		# 单机 1v1 的玩家实体在旧流程里没有 owner_peer_id，导致科研的
		# “已完成主城”检查和兵种解锁按 owner=-1 查不到玩家科技状态；
		# 玩家主城和初始农民统一补上 player_owner_id，和玩家自建建筑保持一致。
		player_castle.owner_peer_id = player_owner_id
		player_castle.died.connect(_on_castle_died.bind(get_host_team()))
		var start_lv = NationBonuses.get_castle_start_level(player_nation)
		player_castle.upgrade_level = start_lv
		player_castle.level = start_lv

	# 生成敌人城堡
	castle_cfg = EntityDatabase.get_config(20)
	castle_cfg["team"] = get_enemy_team()
	var enemy_castle = spawn_entity(castle_cfg, get_enemy_team(), enemy_castle_pos)
	if enemy_castle:
		enemy_castle.died.connect(_on_castle_died.bind(get_enemy_team()))
		var start_lv_enemy = NationBonuses.get_castle_start_level(enemy_nation)
		enemy_castle.upgrade_level = start_lv_enemy
		enemy_castle.level = start_lv_enemy

	# 资源点
	for res in map.resource_positions:
		var cfg = EntityDatabase.get_config(res.type)
		var e = spawn_entity(cfg, RTSConfig.Team.NEUTRAL, res.pos)

	# 初始农民（随机在城堡周围平原上生成）
	var peasant_cfg = EntityDatabase.get_config(10)
	for _i in range(3):
		var fx = player_castle_pos.x + randf_range(-3, 3)
		var fz = player_castle_pos.z + randf_range(-3, 3)
		var ft = get_terrain_at(Vector3(fx, 0, fz))
		var cfg = peasant_cfg.duplicate()
		cfg["owner_peer_id"] = player_owner_id
		if ft == 0:
			spawn_entity(cfg, get_host_team(), Vector3(fx, 0, fz))
		else:
			spawn_entity(cfg, get_host_team(), player_castle_pos + Vector3(randf_range(-3,3), 0, randf_range(-3,3)))
	for _i in range(3):
		var fx = enemy_castle_pos.x + randf_range(-3, 3)
		var fz = enemy_castle_pos.z + randf_range(-3, 3)
		var ft = get_terrain_at(Vector3(fx, 0, fz))
		if ft == 0:
			spawn_entity(peasant_cfg, get_enemy_team(), Vector3(fx, 0, fz))
		else:
			spawn_entity(peasant_cfg, get_enemy_team(), enemy_castle_pos + Vector3(randf_range(-3,3), 0, randf_range(-3,3)))

	# 1v1 静态 AI 默认写死红方；玩家随机到红方时必须同步改成蓝方。
	if not is_online:
		var static_ai = get_node_or_null("AIController")
		if static_ai:
			static_ai.my_team = get_enemy_team()

	# 相机聚焦玩家城堡
	var cam = get_viewport().get_camera_3d()
	if cam and player_castle:
		cam.global_position = Vector3(player_castle.global_position.x, cam.global_position.y, player_castle.global_position.z)

# ==================== 实体生成 ====================
# 模型缩放：普通模型按最大边等比缩放到实体直径；城墙另外处理横向占地，
# 让中心相距 2 米的相邻墙段边缘咬合，同时保持原来的墙顶高度。
func _model_scale_for(entity_id: int, body_radius: float, aabb: AABB) -> Vector3:
	var target_size: float = body_radius * 2.0
	var current_size: float = max(aabb.size.x, max(aabb.size.y, aabb.size.z))
	if current_size <= 0.01:
		return Vector3.ONE
	var model_scale: float = RTSConfig.get_model_scale(entity_id)
	if entity_id == 27:
		return RTSConfig.get_wall_model_scale(body_radius, aabb) * model_scale
	return Vector3.ONE * (target_size / current_size * model_scale)

func _apply_entity_model(entity: GameEntity) -> bool:
	var model_path = RTSConfig.get_entity_model(entity.entity_id, entity.level)
	# 城墙拐角检测
	if entity.entity_id == 27:
		var has_x = false; var has_z = false
		for e in entities.get_children():
			if e is Building and e.entity_id == 27 and e.health > 0 and e != entity:
				var d = e.global_position - entity.global_position
				if abs(d.x) < 2.0 and abs(d.z) < 0.5: has_x = true
				if abs(d.z) < 2.0 and abs(d.x) < 0.5: has_z = true
		if has_x and has_z: model_path = "res://models/castle/wall-corner.glb"
		else: model_path = "res://models/castle/wall.glb"
	if model_path == "" or not ResourceLoader.exists(model_path):
		return false
	var model_scene = load(model_path)
	if not model_scene: return false
	var model_instance = model_scene.instantiate()
	if not model_instance: return false
	# 移除旧Mesh子节点
	for child in entity.get_children():
		if child is MeshInstance3D and child.name != "SelectionRing":
			child.queue_free()
	# 缩放模型以匹配实体大小
	var aabb = _get_model_aabb(model_instance)
	model_instance.scale = _model_scale_for(entity.entity_id, entity.body_radius, aabb)
	# 打个标记，让 Army 能稳定取到自己的模型根节点（不能按名字找：名字来自 GLB）
	model_instance.set_meta("entity_model", true)
	entity.add_child(model_instance)
	_ensure_model_shadows(model_instance)
	# 模型换了，头顶高度缓存要重算，否则视野起点还停在旧模型高度
	entity.reset_vision_head_height()
	# 特殊朝向调整
	if entity.entity_id == 16: model_instance.rotation.y = deg_to_rad(180)
	elif entity.entity_id == 17: model_instance.rotation.y = deg_to_rad(90)
	elif entity.entity_id == 18: model_instance.rotation.y = deg_to_rad(90)
	elif entity.entity_id == 59:
		# 巨型投石机：模型默认朝向与单位前方垂直，顺时针旋转 90° 校正
		model_instance.rotation.y = deg_to_rad(-90)
	elif entity.entity_id == 64:
		# 炮台：顺时针旋转 90° 对齐城墙朝向。
		# 模型底面本来就在局部 y=0，实体高度由 spawn_entity 精确对齐到墙顶，
		# 这里不能再往下塞，否则会陷进墙体里。
		model_instance.rotation.y = deg_to_rad(-90)
	# character 与步兵模型默认朝向相反，统一绕 Y 轴旋转 180° 掉头
	if RTSConfig.model_needs_flip(model_path):
		model_instance.rotation.y = deg_to_rad(180)
	# 存储模型引用用于动画
	entity.set_meta("_model_instance", model_instance)
	# GLB 动画默认不循环；统一配置 idle/walk/attack 循环，避免播放一次后定格
	var ap := AnimationHelper.configure_loops(model_instance)
	if entity is Army:
		entity.bind_animation_player(ap)
	# 角色模型启用顶点颜色（编辑器预览依赖此特性）
	if entity.entity_id in [10, 43, 44, 45, 46, 47, 48, 49, 50, 51]:
		_enable_vertex_colors(model_instance)
	# 船只：划艇摆桨、有帆的船按风向转帆（纯视觉）
	if entity.entity_id in SHIP_ANIM_IDS:
		_attach_ship_sail_animator(model_instance)
	# 石油：常年冒黑烟 + 脚下一圈油渍，把黑石头和地面糊在一起
	if entity.entity_id == OIL_RESOURCE_ID:
		_attach_oil_smoke(model_instance, entity.body_radius)
	return true

# 石油资源（EntityDatabase id 4）。模型是 water-rocks（几块黑石头），
# 没有任何“油”的视觉暗示，靠冒烟来区分。
const OIL_RESOURCE_ID := 4

# 在石油模型下面挂 OilSmoke，重复调用不会叠加（联机客户端节点会被复用）
func _attach_oil_smoke(model_instance: Node3D, body_radius: float) -> void:
	if model_instance == null or not is_instance_valid(model_instance):
		return
	if model_instance.get_node_or_null("OilSmoke") != null:
		return
	model_instance.add_child(OilSmoke.create(body_radius))


# 需要划桨/帆位动画的船：采集船是划艇，其余三条有帆
const SHIP_ANIM_IDS := [13, 14, 39, 40]

# 在船模型下面挂一个 ShipSailAnimator，重复调用不会叠加（客户端节点会被复用）
func _attach_ship_sail_animator(model_instance: Node3D) -> void:
	if model_instance == null or not is_instance_valid(model_instance):
		return
	if model_instance.get_node_or_null("ShipSailAnimator") != null:
		return
	var animator := ShipSailAnimator.new()
	animator.name = "ShipSailAnimator"
	model_instance.add_child(animator)
	animator.setup(model_instance)

func _set_unshaded_recursive(node: Node):
	for child in node.get_children():
		if child is MeshInstance3D and child.mesh:
			for si in child.mesh.get_surface_count():
				var src = child.get_active_material(si)
				if src and "shading_mode" in src:
					var m = src.duplicate()
					m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
					child.set_surface_override_material(si, m)
		_set_unshaded_recursive(child)

# 模型需要投射/接收实时阴影，否则光影层次会明显变弱
func _ensure_model_shadows(node: Node) -> void:
	if node is MeshInstance3D:
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	for child in node.get_children():
		_ensure_model_shadows(child)

func _get_model_aabb(node: Node) -> AABB:
	var aabb = AABB()
	for child in node.get_children():
		if child is MeshInstance3D and child.mesh:
			var child_aabb = child.mesh.get_aabb()
			if child_aabb.size.length() > 0:
				aabb = aabb.merge(child_aabb)
		var child_result = _get_model_aabb(child)
		if child_result.size.length() > 0:
			aabb = aabb.merge(child_result)
	return aabb

# 队伍着色：递归遍历，保留纹理，用 albedo_color 做色调
func _apply_team_tint(entity: GameEntity, tint: Color):
	_tint_recursive(entity, tint)

func _print_mesh_info(node: Node, depth: int):
	for child in node.get_children():
		var indent = "  ".repeat(depth)
		if child is MeshInstance3D and child.mesh:
			var mat = child.get_active_material(0)
			var has_tex = mat and "albedo_texture" in mat and mat.albedo_texture != null
			print(indent + "[Mesh] name=%s alb=%s tex=%s" % [child.name, str(mat.albedo_color), str(has_tex)])
			var vc = child.mesh.get("vertex_color_array") if "vertex_color_array" in child.mesh else "n/a"
			print(indent + "[Mesh] name=%s surf=%d has_tex=%s vc=%s" % [child.name, child.mesh.get_surface_count(), str(has_tex), str(vc != null and vc != "n/a")])
		else:
			print(indent + "[Node] name=%s type=%s" % [child.name, child.get_class()])
		_print_mesh_info(child, depth+1)

func _count_meshes(node: Node) -> int:
	var c = 0
	for child in node.get_children():
		if child is MeshInstance3D and child.mesh: c += 1
		c += _count_meshes(child)
	return c

func _tint_recursive(node: Node, tint: Color):
	var tint_key := tint.to_html()
	for child in node.get_children():
		if child is MeshInstance3D and child.mesh:
			for si in child.mesh.get_surface_count():
				var src = child.get_active_material(si)
				
				if src and "albedo_color" in src:
					var dup = _cached_override_material(src, "tint:" + tint_key)
					dup.albedo_color = src.albedo_color.lerp(tint, 0.5)
					child.set_surface_override_material(si, dup)
		_tint_recursive(child, tint)

# 同一原始材质 + 同一用途/颜色只复制一次。模型 GLB 的材质通常在同模型
# 多个实例之间共享，因此同队伍同兵种能直接复用同一份 override 材质。
func _cached_override_material(src: Material, suffix: String):
	var key := "%d|%s" % [src.get_instance_id(), suffix]
	var cached = _team_material_cache.get(key)
	if cached == null:
		cached = src.duplicate()
		_team_material_cache[key] = cached
	return cached

# 单机/联机主机：Army 每次真正出手时调用一次。不要放在 _update_entity_animation
# 里，否则进入攻击距离、状态切换等也会触发，导致一次攻击播放多次动画。
func _on_entity_attack_started(entity: Army) -> void:
	if entity == null or not is_instance_valid(entity):
		return
	if not entity.has_meta("_model_instance"):
		return
	var model = entity.get_meta("_model_instance")
	if model is not Node3D:
		return
	if SiegeAttackAnim.is_siege(entity.entity_id):
		_play_entity_attack_anim(entity, model as Node3D)

func _update_entity_animation(entity: GameEntity):
	if not entity.has_meta("_model_instance"): return
	var model = entity.get_meta("_model_instance")
	if model is not Node3D:
		return
	var model3d := model as Node3D
	# 攻城器械的死亡/清场：先停掉程序化动作并复位，避免尸体还在甩炮臂
	if entity is Army and SiegeAttackAnim.is_siege(entity.entity_id):
		if entity.health <= 0:
			SiegeAttackAnim.reset(model3d)
	var ap = model.get_node_or_null("AnimationPlayer") as AnimationPlayer
	var anim = ""
	if entity.health <= 0:
		anim = "die"
	elif entity is Army and (entity as Army)._animal_type != "":
		# 动物不走指令流、也不经过 MovementController，velocity 恒为 0；
		# 只能看 _process_animal 里标的 _animal_moving，否则整群动物都滑行不迈腿。
		anim = "walk" if (entity as Army)._animal_moving else "idle"
	elif entity is Army:
		var army := entity as Army
		var _moving_now: bool = army.velocity.length_squared() > 0.04
		if army._order_is(army.UnitState.GATHERING):
			# 采集途中播放走路；进入采集距离后才播放挥动；被挡住停住时不要原地踏步
			anim = "attack-melee-left" if _is_entity_in_action_range(army) else ("walk" if _moving_now else "idle")
		elif army._order_is(army.UnitState.ATTACKING) or army._order_is(army.UnitState.ATTACK_MOVING):
			# 锁定目标但还在接近时仍然是走路动画，进入攻击距离后才出手。
			# 出手姿势按兵种取，法术/射击单位不能用近战左勾拳。
			anim = AnimationHelper.attack_anim_for(army.entity_id) if _is_entity_in_action_range(army) else ("walk" if _moving_now else "idle")
		elif army._order_in([army.UnitState.MOVING, army.UnitState.DELIVERING]):
			anim = "walk" if _moving_now else "idle"
		elif army._order_is(army.UnitState.BUILDING):
			# 建造/修理：到工地前走路，站定后挥动工具
			anim = "attack-melee-left" if army._at_work_site else ("walk" if _moving_now else "idle")
		else:
			anim = "idle"
	else:
		anim = "idle"
	# 这些兵种即使模型自带 attack 动画也偏弱（挥动幅度很小），
	# 统一强制走程序化动作，保证攻城/远程单位开火时一眼能看出来
	var force_proc: bool = entity is Army and entity.entity_id in PROC_ATTACK_IDS
	if ap != null and anim != "" and ap.has_animation(anim) and not (force_proc and anim == "attack-melee-left"):
		var spd := 1.0
		if anim != "walk" and anim != "idle" and anim != "die":
			# 出手动作按攻击冷却循环；GATHERING 也复用攻击动作，让采集有挥动反馈
			spd = AnimationHelper.attack_speed_scale(ap, anim, entity.attack_speed)
		elif anim == "walk":
			var actual_speed: float = entity.speed
			if entity is Army:
				var army_walk := entity as Army
				if army_walk._visual_speed > 0.05:
					actual_speed = army_walk._visual_speed
			spd = AnimationHelper.walk_speed_scale(actual_speed)
		ap.speed_scale = spd
		if anim == "walk":
			AnimationHelper.play_looped(ap, anim, true)
		elif ap.current_animation != anim:
			ap.play(anim)

# 判断单位是否已经进入实际出手距离。攻击/攻击移动看攻击距离，
# 采集看资源点采集距离；还没走到时统一按走路处理。
func _is_entity_in_action_range(entity: Army) -> bool:
	var target = entity.current_target
	if target == null or not is_instance_valid(target):
		return false
	if not (target is GameEntity):
		return false
	var dx: float = entity.global_position.x - target.global_position.x
	var dz: float = entity.global_position.z - target.global_position.z
	var dist: float = Vector2(dx, dz).length() - entity.body_radius - target.body_radius
	if entity._order_is(entity.UnitState.GATHERING):
		return dist <= 0.5
	if entity._order_is(entity.UnitState.BUILDING):
		return bool(entity._at_work_site)
	if entity._order_in([entity.UnitState.ATTACKING, entity.UnitState.ATTACK_MOVING]):
		return dist <= entity.attack_range + 0.05
	return false

# ── 兵种专用攻击动作分发 ──
# 攻城六件套由 SiegeAttackAnim 分层处理（炮臂/撞木/轮子/帆/旗 + 炮口特效）；
# 35/58 等旧兵种保留原有程序化动作。
func _play_entity_attack_anim(entity: Army, model: Node3D) -> void:
	# 攻城器械统一走分层程序化动画：炮臂/撞木/轮子/帆/旗分别动，
	# 并在出手瞬间补炮口、尘土、水花等特效。
	if SiegeAttackAnim.is_siege(entity.entity_id):
		SiegeAttackAnim.play(entity.entity_id, model, {
			"target": entity.current_target,
			"body_radius": entity.body_radius,
			"forward": -entity.global_transform.basis.z,
			"right": entity.global_transform.basis.x,
		})
		return
	# 僧侣/长老/宗师的法术弹由 Army._caster_attack() 直接发射，
	# 因为命中时还要结算治疗/伤害，不能只在这里做纯视觉播放。
	# 开火瞬间在炮口位置喷一小团亮色烟尘：车身位移在远景里容易看漏，
	# 这个一闪而过的火光才是最容易被眼睛捕捉到的信号。0.5 秒节流避免重复刷。
	if entity.entity_id in MUZZLE_ATTACK_IDS:
		var now: float = Time.get_ticks_msec() * 0.001
		if now - float(entity.get_meta("_muzzle_last", 0.0)) > 0.5:
			entity.set_meta("_muzzle_last", now)
			_spawn_muzzle_effect(entity)
	match entity.entity_id:
		35:
			_procedural_pike_thrust(model)
		58:
			_procedural_repeater_fire(model)
		_:
			_procedural_attack(model)

# 攻城/远程单位开火时炮口的短暂烟尘火光
func _spawn_muzzle_effect(entity: Army) -> void:
	var root := get_tree().current_scene as Node3D
	if root == null or not is_instance_valid(entity):
		return
	# 沿单位正前方偏移出炮口位置（模型 -Z 为前方）
	var fwd: Vector3 = -entity.global_transform.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.01:
		fwd = Vector3.FORWARD
	var muzzle: Vector3 = entity.global_position + fwd.normalized() * (entity.body_radius + 1.3) + Vector3.UP * 0.9
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.amount = 10
	p.lifetime = 0.5
	p.explosiveness = 1.0
	p.direction = Vector3.UP
	p.spread = 70.0
	p.initial_velocity_min = 1.0
	p.initial_velocity_max = 2.8
	p.gravity = Vector3(0.0, -3.0, 0.0)
	p.scale_amount_min = 1.0
	p.scale_amount_max = 1.5
	var mesh := SphereMesh.new()
	mesh.radius = 0.16
	mesh.height = 0.32
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 0.86, 0.52, 0.9)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.72, 0.32)
	mat.emission_energy_multiplier = 2.2
	mesh.material = mat
	p.mesh = mesh
	p.position = muzzle
	root.add_child(p)
	# 延迟一帧发射，避免同帧 transform 未同步时从原点喷出
	p.set_deferred("emitting", true)
	get_tree().create_timer(1.2).timeout.connect(func():
		if is_instance_valid(p):
			p.queue_free())

# 长枪兵：枪身长，刺出距离比普通单位远，动作更直、更"戳"
func _procedural_pike_thrust(model: Node3D) -> void:
	if not _begin_proc_anim(model):
		return
	var base_pos: Vector3 = model.position
	var dur: float = 0.6
	var tw := model.create_tween()
	# 后收蓄力
	tw.tween_property(model, "position", base_pos + Vector3(0.0, 0.0, 0.35), dur * 0.3) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	# 直线突刺（长枪的位移明显大于普通刺击）
	tw.tween_property(model, "position", base_pos + Vector3(0.0, 0.0, -1.2), dur * 0.25) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	# 收枪归位
	tw.tween_property(model, "position", base_pos, dur * 0.45) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_callback(func():
		if is_instance_valid(model):
			model.set_meta("_proc_anim_running", false))

# 连弩：射速极快，只用很短的小幅后坐，连发时看起来是连续"哒哒"的抖动
func _procedural_repeater_fire(model: Node3D) -> void:
	if not _begin_proc_anim(model):
		return
	var base_pos: Vector3 = model.position
	var dur: float = 0.25
	var tw := model.create_tween()
	tw.tween_property(model, "position", base_pos + Vector3(0.0, 0.0, 0.2), dur * 0.35) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(model, "position", base_pos, dur * 0.65) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_callback(func():
		if is_instance_valid(model):
			model.set_meta("_proc_anim_running", false))

# 程序化攻击/死亡的同一模型互斥锁：避免动画叠加把模型拉飞
func _begin_proc_anim(model: Node3D) -> bool:
	if model == null or not is_instance_valid(model):
		return false
	if bool(model.get_meta("_proc_anim_running", false)):
		return false
	model.set_meta("_proc_anim_running", true)
	return true

# 程序化攻击动作：模型没有内置 attack 动画时，用 Tween 做一次前刺 + 前倾，
# 攻击/采集时都有看得见的动作反馈。同一模型同时只跑一次，避免 Tween 叠加把模型拉飞。
func _procedural_attack(model: Node3D) -> void:
	if model == null or not is_instance_valid(model):
		return
	if bool(model.get_meta("_proc_atk_running", false)):
		return
	model.set_meta("_proc_atk_running", true)
	var base_pos: Vector3 = model.position
	var base_rx: float = model.rotation.x
	var dur: float = 0.5
	var tw := model.create_tween()
	tw.set_parallel(true)
	# 前半段：向攻击方向（模型 -Z）刺出并前倾
	tw.tween_property(model, "position", base_pos + Vector3(0.0, 0.0, -0.9), dur * 0.35) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(model, "rotation:x", base_rx - 0.7, dur * 0.35) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	# 后半段：回到原位
	tw.chain().tween_property(model, "position", base_pos, dur * 0.7) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.parallel().tween_property(model, "rotation:x", base_rx, dur * 0.7) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.chain().tween_callback(func():
		if is_instance_valid(model):
			model.set_meta("_proc_atk_running", false))

func _enable_vertex_colors(node: Node):
	for child in node.get_children():
		if child is MeshInstance3D and child.mesh:
			for si in child.mesh.get_surface_count():
				var m = child.get_active_material(si)
				if m and "vertex_color_use_as_albedo" in m:
					var dup = _cached_override_material(m, "vertex_color")
					dup.vertex_color_use_as_albedo = true
					child.set_surface_override_material(si, dup)
		_enable_vertex_colors(child)

# 距给定点最近的同队城墙的顶面世界高度；附近没有城墙时返回一个很负的哨兵值。
# 城墙模型底面在局部 y=0，但实际顶面取决于模型自动缩放后的高度。
func get_wall_top_y_near(pos: Vector3, team: int) -> float:
	var best: float = -1e20
	var best_d: float = WALL_CANNON_SNAP
	for e in entities.get_children():
		if not (e is Building) or e.entity_id != 27 or e.team != team or e.health <= 0:
			continue
		var d: float = Vector2(e.global_position.x - pos.x, e.global_position.z - pos.z).length()
		if d <= best_d:
			best_d = d
			best = e.global_position.y + get_wall_top_height(e as Building)
	return best

# 城墙实际顶面高度（相对城墙实体原点）。wall.glb 原始高 1.31 米，
# 生成时会被自动缩放到 body_radius 对应的尺寸，因此不能再用固定 1.31。
# 按模型实例缓存，拐角换模型后 instance_id 变化会自动重算。
func get_wall_top_height(wall: Building) -> float:
	if wall == null or not is_instance_valid(wall) or int(wall.entity_id) != 27:
		return WALL_TOP_HEIGHT
	var mi = wall.get_meta("_model_instance", null)
	if not (mi is Node3D):
		return WALL_TOP_HEIGHT
	var model := mi as Node3D
	var model_id := model.get_instance_id()
	var cached_id := int(wall.get_meta("_wall_top_model_id", 0))
	var cached_scale := float(wall.get_meta("_wall_top_scale_y", -1.0))
	if cached_id == model_id and absf(cached_scale - model.scale.y) < 0.0001:
		return float(wall.get_meta("_wall_top_height", WALL_TOP_HEIGHT))
	var local_top := 0.0
	var aabb := _get_model_aabb(model)
	if aabb.size.length() > 0.001:
		local_top = maxf(aabb.end.y, 0.0)
	var top := WALL_TOP_HEIGHT
	if local_top > 0.001:
		top = local_top * model.scale.y + model.position.y
	top = maxf(top, 0.0)
	wall.set_meta("_wall_top_model_id", model_id)
	wall.set_meta("_wall_top_scale_y", model.scale.y)
	wall.set_meta("_wall_top_height", top)
	return top

# 弹丸路径上方需要越过的最低顶面：地形高度，以及附近建筑/城墙的实际模型顶。
# 投石车用它抬高抛物线；其它直射弹丸用它判断是否已经撞到建筑或山体。
func get_projectile_obstacle_height(world_pos: Vector3, radius: float = 0.25) -> float:
	var now_ms: int = Time.get_ticks_msec()
	if now_ms - _projectile_cache_refresh_ms >= PROJECTILE_CACHE_REFRESH_MS:
		_projectile_cache_refresh_ms = now_ms
		# 只刷新弹丸自己的轻量建筑顶缓存，不在弹丸查询里触发 _rebuild_entity_cache；
		# 单位出生/死亡会让实体缓存变 dirty，全量重建放在正常战斗循环里做。
		_refresh_projectile_building_top_cells()
	var top: float = -INF
	if $Map and $Map.has_method("get_height_at"):
		top = maxf(top, float($Map.get_height_at(world_pos)))
	var csize: float = _SPATIAL_CELL_SIZE
	var key := Vector2i(
		int(floor(world_pos.x / csize)), int(floor(world_pos.z / csize))
	)
	var entries = _projectile_building_top_cells.get(key)
	if entries != null:
		for item in entries:
			var entry: Vector4 = item
			var dx: float = world_pos.x - entry.x
			var dz: float = world_pos.z - entry.z
			var reach: float = entry.z + radius
			if dx * dx + dz * dz <= reach * reach:
				top = maxf(top, entry.w)
	return top

# 每 0.5 秒把所有建筑/城墙按 4 米空间格缓存成“中心 x/z、碰撞半径、模型顶”。
# 弹丸查询只查所在格并做一次平方距离比较，不再为每个采样点遍历建筑列表和模型 AABB。
func _refresh_projectile_building_top_cells() -> void:
	_projectile_building_top_cells.clear()
	var csize: float = _SPATIAL_CELL_SIZE
	for b in _buildings:
		if not is_instance_valid(b) or b.health <= 0:
			continue
		var btop: float = b.global_position.y
		if int(b.entity_id) == 27:
			btop += get_wall_top_height(b)
		else:
			btop += maxf(float(b.get_vision_head_height()), float(b.body_radius) * 1.5)
		var br: float = maxf(float(b.body_radius), 0.8)
		var entry := Vector4(b.global_position.x, b.global_position.z, br, btop)
		var min_x: int = int(floor((b.global_position.x - br) / csize))
		var max_x: int = int(floor((b.global_position.x + br) / csize))
		var min_z: int = int(floor((b.global_position.z - br) / csize))
		var max_z: int = int(floor((b.global_position.z + br) / csize))
		for cx in range(min_x, max_x + 1):
			for cz in range(min_z, max_z + 1):
				var key := Vector2i(cx, cz)
				if not _projectile_building_top_cells.has(key):
					_projectile_building_top_cells[key] = []
				_projectile_building_top_cells[key].append(entry)

# 计算模型自身坐标系里的最低点：动物模型的原点常不在脚底，
# 用它把模型最低点对齐到实体原点（实体原点就是地面高度）。
func _model_local_min_y(model: Node3D) -> float:
	var inv: Transform3D = model.global_transform.affine_inverse()
	var merged := AABB()
	var has := false
	var meshes: Array = model.find_children("*", "MeshInstance3D", true, false)
	for c in meshes:
		var mi := c as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var a: AABB = (inv * mi.global_transform) * mi.get_aabb()
		if not has:
			merged = a
			has = true
		else:
			merged = merged.merge(a)
	if not has:
		return 0.0
	return merged.position.y

func spawn_entity(config: Dictionary, team: int, pos: Vector3, level: int = 1) -> GameEntity:
	if not entities or config.is_empty(): return null

	# 深拷贝配置，避免建筑之间共享生产列表等可变数据
	var cfg = config.duplicate(true)

	var entity: GameEntity
	match cfg.type:
		0: entity = WorldResource.new()
		1: entity = Building.new()
		2: entity = Army.new()

	cfg["level"] = level
	cfg["team"] = team
	# 暂停时冻结所有游戏实体；管理器本身是 ALWAYS，只负责接指令和建造预览。
	entity.process_mode = Node.PROCESS_MODE_PAUSABLE
	entities.add_child(entity)
	# 实体以任何方式离开场景树（死亡动画结束、销毁、场景退出）都立即标记缓存失效，
	# 避免 AI/统计缓存里残留已释放实例，访问属性时报 "previously freed"。
	if not entity.tree_exiting.is_connected(mark_entity_cache_dirty):
		entity.tree_exiting.connect(mark_entity_cache_dirty)
	entity.setup(cfg)
	# 错开索敌相位：所有单位的 think_timer 默认都是 0，同一批生产/刷出的
	# 几百个单位会在同一物理帧一起做可见性射线和目标搜索，形成周期性大卡顿。
	if entity is Army:
		entity.think_timer = randf_range(0.0, 0.75)
	# 尝试加载3D模型
	var model_loaded = _apply_entity_model(entity)
	# 国家色着色：非资源、非中立实体。颜色与阵营解耦，按国家统一。
	if entity.entity_type != 0 and entity.team != RTSConfig.Team.NEUTRAL:
		var tint: Color = get_entity_color(entity)
		tint = Color(0.2 + tint.r * 0.8, 0.2 + tint.g * 0.8, 0.2 + tint.b * 0.8)
		_apply_team_tint(entity, tint)
	# 有坐骑的单位抬高主模型；侦察兵坐骑按固定倍率缩放，狗背比 0.5*体半径更高，
	# 需要按坐骑包围盒顶面继续抬高，否则士兵会整个人陷进坐骑里。
	if RTSConfig.is_mounted(entity.entity_id) and entity.has_meta("_model_instance"):
		var mi = entity.get_meta("_model_instance")
		if is_instance_valid(mi):
			var mount_node := entity.get_node_or_null("Mount") as Node3D
			var mount_top: float = RTSConfig.get_model_top_in_parent(entity, mount_node) if mount_node != null else 0.0
			mi.position.y = RTSConfig.get_rider_base_y(entity.entity_id, entity.body_radius, mount_top)
	# 动物模型的原点很多时候不在脚底，直接把 y 设成地面高度就会浮空或陷进地里。
	# 这里按模型包围盒把最低点对齐到实体原点（原点即地面高度）。
	if entity is Army and str(entity.get("_animal_type")) != "" and entity.has_meta("_model_instance"):
		var ani = entity.get_meta("_model_instance")
		if is_instance_valid(ani):
			var animin: float = _model_local_min_y(ani)
			if absf(animin) > 0.005:
				ani.position.y -= animin
	# 建筑整体放大（瞭望塔 41、城墙 27、炮台 64、桥 7、梯子 8、箭塔 25、炮塔 26 除外：
	# 它们与地形/城墙拼接尺寸绑定，放大后会出现缝隙、接不上岸或悬空）：
	# 模型、碰撞体、body_radius 必须一起放大，只放大模型会让单位走进建筑内部，
	# 放置校验、AOE 判定也仍按旧尺寸计算。
	# 倍率统一放在 RTSConfig，建造预览也使用同一系数，避免预览与实际尺寸不一致。
	if entity is Building:
		var body_scale: float = RTSConfig.get_building_body_scale(entity.entity_id)
		if body_scale != 1.0:
			entity.body_radius *= body_scale
			if entity.has_method("_update_collision_shape"):
				entity.call("_update_collision_shape")
			if entity.has_meta("_model_instance"):
				var bmi = entity.get_meta("_model_instance")
				if is_instance_valid(bmi):
					bmi.scale *= body_scale
					# 放大后按包围盒重新贴地，避免模型原点不在底部时陷进地面
					var bmin: float = _model_local_min_y(bmi)
					if absf(bmin) > 0.005:
						bmi.position.y -= bmin
		# 等级旗帜/底座色环/等级徽章。放在模型和整体放大之后，尺寸才与最终模型一致；
		# 建造中的建筑由 Building.start_construction() 再隐藏。
		LevelVisualScript.apply(
			entity as Building,
			maxi(entity.upgrade_level, entity.level),
			0.0,
			get_entity_color(entity),
			entity.build_timer <= 0.0,
		)
	# 船只模型已通过 ENTITY_MODEL_SCALE 放大，推挤/碰撞半径同步补偿；
	# 只改 push_radius，不改 body_radius，避免攻击距离等战斗数值一起变化。
	if entity is Army:
		var ship_collision_scale: float = RTSConfig.get_ship_collision_scale(entity.entity_id)
		if ship_collision_scale != 1.0:
			entity.push_radius = entity.body_radius * ship_collision_scale
			if entity.has_method("_update_collision_shape"):
				entity.call("_update_collision_shape")
	# 资源需要 setup 后再重建 visual
	if entity.entity_type == 0 and not model_loaded and entity.has_method("_create_visual"):
		entity._create_visual()
	entity.global_position = pos
	# 特定建筑旋转90度
	if entity.entity_id in [22, 27, 28]: entity.rotation.y = deg_to_rad(90)
	mark_entity_cache_dirty()

	# 地面高度修正（炮台跳过——高度由城墙顶面决定）
	if $Map and entity.entity_id != 64:
		var h = $Map.get_height_at(pos)
		entity.global_position.y = h

	# 炮台必须坐在城墙顶上：按最近同队城墙的顶面高度对齐实体 y。
	# 玩家手动放置和 AI 的 build_building(64, wall_pos) 都走这里，保证两边一致。
	if entity.entity_id == 64:
		var wall_top: float = get_wall_top_y_near(entity.global_position, team)
		if wall_top > -1e19:
			entity.global_position.y = wall_top
			# 朝向与城墙保持一致，炮口才会横在墙面上而不是斜插过去
			for e in entities.get_children():
				if e is Building and e.entity_id == 27 and e.team == team and e.health > 0:
					if Vector2(e.global_position.x - entity.global_position.x, e.global_position.z - entity.global_position.z).length() < WALL_CANNON_SNAP:
						entity.rotation.y = e.rotation.y
						break


	# 人口管理（单机多AI按 owner 增加，1v1 沿用团队级）
	if entity is Army and entity.entity_id < 60:
		if entity.owner_peer_id != -1:
			increase_population_for(entity.owner_peer_id, 1)
		else:
			increase_population(team, 1)
	elif entity is Building and (entity.entity_id == 25 or entity.entity_id == 26):
		if entity.owner_peer_id != -1:
			increase_population_for(entity.owner_peer_id, 1)
		else:
			increase_population(team, 1)

	if entity is Army and entity.health > 0:
		call_deferred("_apply_auto_attack_to_entity", entity)

	return entity

# ==================== 拆除建筑 ====================
func demolish_building(building: Building) -> bool:
	if not building or not is_instance_valid(building):
		return false
	if building.entity_id == 20:  # 不能拆除城堡
		return false
	if building.build_timer > 0 or building.upgrade_timer > 0:
		return false

	# 返还50%建造费用
	var base_cfg = EntityDatabase.get_config(building.entity_id)
	if not base_cfg.is_empty():
		var cost = base_cfg.get("cost", {})
		if building.owner_peer_id != -1:
			for res in cost:
				var refund = int(cost[res] * 0.5)
				add_resource_for(building.owner_peer_id, res, refund)
		else:
			for res in cost:
				var refund = int(cost[res] * 0.5)
				add_resource(res, refund, building.team)

	

	building.die()
	var _b_owner = building.owner_peer_id
	if _b_owner != -1:
		update_player_limits(_b_owner)
		update_player_population(_b_owner)
	else:
		update_resource_limits(building.team)
		update_population_limits()
	return true

# ==================== 资源系统 ====================
func update_resource_limits(team: int):
	var limits = get_team_resource_limits(team)
	var castle = 0
	var warehouse = 0
	var shipyard = 0

	for e in get_tree().get_nodes_in_group("storage_buildings"):
		if e.team == team and e.health > 0:
			if e.entity_id == 20: castle += 1
			elif e.entity_id == 22 and e.build_timer <= 0: warehouse += e.building_data.get("storage_bonus", 0)
			elif e.entity_id == 23: shipyard += 1

	limits.gold = 500 + castle*300 + warehouse
	limits.wood = 500 + castle*300 + warehouse
	limits.stone = 500 + castle*300 + warehouse
	limits.food = 500 + castle*300 + warehouse
	limits.oil = shipyard * 700

func add_resource(type: String, amount: int, team: int):
	var res = get_team_resources(team)
	var lim = get_team_resource_limits(team)
	if res.has(type):
		res[type] = min(res[type] + amount, lim[type])

func deliver_resources(cargo: Dictionary, team: int):
	var mult = 1.0
	if team == get_enemy_team():
		if GameSettings.ai_difficulty == GameSettings.AIDifficulty.NORMAL: mult = 2.0
		elif GameSettings.ai_difficulty >= GameSettings.AIDifficulty.HARD: mult = 3.0
	for t in cargo:
		var amount = int(cargo[t] * mult)
		if battle_stats:
			battle_stats.record_gathered(-1, team, amount)
		add_resource(t, amount, team)

func _input(event):
	# O键切换命令卡
	if event is InputEventKey and event.pressed and event.keycode == KEY_O:
		var cc = $UI.get_node_or_null("CommandCard")
		if cc: cc.visible = not cc.visible
	# Don't process clicks on interactive UI panels
	if event is InputEventMouseButton:
		if has_node("UI/InfoPanel"):
			var ip = $UI/InfoPanel
			if ip.visible and ip.get_global_rect().has_point(event.position):
				return
		if has_node("UI/BuildMenu"):
			var bm = $UI/BuildMenu
			if bm.visible and bm.get_global_rect().has_point(event.position):
				return

	if build_mode:
		# 手机端居中建造：单指滑动交给 TouchGestureRouter 平移地图，
		# 世界点击不再直接放置，确认/取消只走预览下方的勾叉按钮。
		if mobile_centered_build:
			return
		# 移动端触摸建造逻辑
		if event is InputEventScreenTouch:
			if event.pressed:
				# 手指按下
				_start_build_drag(event.position)
			else:
				# 手指抬起 → 尝试放置
				_update_build_preview_from_screen(event.position)
				_end_build_drag_and_place()
		elif event is InputEventScreenDrag and build_touch_active:
			# 手指拖动
			_update_build_preview_from_screen(event.position)
		else:
			_process_build_mode(event)
		return   # 建造模式下不再处理其他输入

func _unhandled_input(event):
	# Game clicks - only fires when no GUI Control consumed the event
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		_pending_left_click = false
		_handle_right_click(event)


# 统计指定类型的建筑数量（按队伍过滤）
func _count_buildings_of_type(building_id: int, for_team: int) -> int:
	var cnt = 0
	for e in entities.get_children():
		if e is Building and e.health > 0 and e.entity_id == building_id and e.team == for_team:
			cnt += 1
	return cnt
func _place_building_at(pos: Vector3):
	# 检查城堡等级解锁
	if not is_building_unlocked(selected_building_id, player_owner_id, get_host_team()):
		var unlock_tip := get_building_unlock_text(selected_building_id, player_owner_id, get_host_team())
		if unlock_tip == "":
			unlock_tip = "需要主城 Lv.%d" % get_building_required_castle_level(selected_building_id)
		_show_hud_alert(unlock_tip, Color(1.0, 0.8, 0.1), get_host_team(), get_host_team())
		return

	var cfg = EntityDatabase.get_config(selected_building_id)
	if not cfg:
		return false

	# 资源检查
	var cost = cfg.get("cost", {})
	var res = player_resources
	if has_method("get_host_resources"):
		res = get_host_resources()
	for k in cost:
		if res[k] < cost[k]:
			_show_hud_alert({"gold":"黄金","wood":"木材","stone":"石头","food":"食物","oil":"石油"}.get(k, k) + "不足！", Color(1.0, 0.8, 0.1), get_host_team(), get_host_team())
			return
	
	# 人口检查（防御塔）
	var is_defense = (selected_building_id == 25 or selected_building_id == 26)
	if is_defense and not can_train_unit(get_host_team()):
		return false
	

	# 扣资源
	for k in cost:
		res[k] -= cost[k]
		if has_method("get_host_resources"):
			player_resources[1][k] = res[k]

	# 生成建筑（设置所有权用于颜色）
	cfg["owner_peer_id"] = 1 if not is_online else player_owner_id
	var b = spawn_entity(cfg, get_host_team(), pos) as Building
	if b:
		if selected_building_id == 64:
			for e in entities.get_children():
				if e is Building and e.entity_id == 27 and e.team == get_host_team() and e.health > 0:
					if Vector2(e.global_position.x - pos.x, e.global_position.z - pos.z).length() < e.body_radius:
						b.rotation.y = e.rotation.y
						break
		b.start_construction(5.0, cfg)
		request_construction(b)
		AudioManager.play_sfx("build_place")
		notify_path_recalc(pos)
	# 注意：如果仍需要支持鼠标（PC调试），可以同时保留原鼠标处理
	# 但移动端主要用触摸，PC端继续用鼠标左键命令+右键选择

# Notify all moving armies to recalculate paths after building placement
func notify_path_recalc(build_pos: Vector3 = Vector3.ZERO):
	if not entities: return
	for e in entities.get_children():
		if e is Army and e._order_is(e.UnitState.MOVING):
			if build_pos != Vector3.ZERO and e.global_position.distance_to(build_pos) > 10.0: continue
			e.recalculate_path()
func _start_build_drag(screen_pos: Vector2):
	if not build_preview:
		return false
	build_touch_active = true
	build_drag_started = true
	# 立即更新一次预览位置
	_update_build_preview_from_screen(screen_pos)

func _update_build_preview_from_screen(screen_pos: Vector2):
	if not build_preview:
		return false
	var cam = get_viewport().get_camera_3d()
	if not cam:
		return false
	var from = cam.project_ray_origin(screen_pos)
	var to = from + cam.project_ray_normal(screen_pos) * 500
	var space = get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(from, to)
	# 居中建造只看地面，避免镜头中央压在建筑/单位上时把预览吸到它们身上
	query.collision_mask = 2
	var result = space.intersect_ray(query)
	if result:
		var pos = result.position
		# 网格对齐（如果你希望建筑对齐网格）
		pos.x = round(pos.x)
		pos.z = round(pos.z)
		pos.y = $Map.get_height_at(pos) if $Map else 0
		# 炮台预览：放置在城墙上
		if selected_building_id == 64:
			for e in entities.get_children():
				if e is Building and e.entity_id == 27 and e.team == get_host_team() and e.health > 0:
					var hdist2 = Vector2(e.global_position.x - pos.x, e.global_position.z - pos.z).length()
					if hdist2 < (e.body_radius + 1.0):
						pos.x = e.global_position.x
						pos.z = e.global_position.z
						pos.y = e.global_position.y + get_wall_top_height(e as Building)
						build_preview.rotation.y = e.rotation.y
						break
		build_preview.global_position = pos
		build_preview.visible = true
		var valid = is_position_in_player_vision(pos) and _is_valid_build_position(pos)
		_tint_preview(build_preview, Color(0, 1, 0) if valid else Color(1, 0, 0))
	else:
		build_preview.visible = false

func _end_build_drag_and_place():
	if not build_touch_active:
		return false
	build_touch_active = false
	build_drag_started = false
	
	if build_preview and build_preview.visible:
		# 检查当前位置是否有效
		var pos = build_preview.global_position
		if is_position_in_player_vision(pos) and _is_valid_build_position(pos):
			_place_building_at(pos)
		elif selected_building_id == 64:
			_show_hud_alert("炮台只能建在已完工的己方城墙上", Color(1.0, 0.8, 0.1), get_host_team(), get_host_team())
	# 无论是否放置成功，都退出建造模式
	_exit_build_mode()
func _handle_right_click(event):
	# 右键：只有点空地才打开/关闭建造菜单；点目标继续执行智能命令或查看。
	if pending_command_mode != "":
		pending_command_mode = ""
		return false

	var hit = _get_entity_under_click(event.position)
	if selection.selected_entities.is_empty():
		if hit:
			selection.inspect_entity(hit)
		else:
			_try_open_build_menu(event.position)
		return false

	if not hit:
		_try_open_build_menu(event.position)
		return false

	# 点中目标：己方城墙/桥/运载船走特殊移动，其余目标交给智能指挥。
	_command_selected_units(event.position)
	return false

func _set_garrison_for_selected(screen_pos: Vector2):
	# 防御：队友/敌方单位只可查看，不允许设置驻扎点
	if not (selection and selection.has_method("_selection_all_local") and selection._selection_all_local()):
		return
	var pos = _get_ground_pos(screen_pos)
	if pos == Vector3.ZERO: return
	for u in selection.selected_entities:
		if u is Army and u.has_method("_is_military") and u._is_military():
			u.set_garrison(pos)
		elif u is Building:
			u.garrison_point = pos
			if u.has_method("_show_garrison_marker"):
				u._show_garrison_marker()

func _get_ground_pos(screen_pos: Vector2) -> Vector3:
	var cam = get_viewport().get_camera_3d()
	if not cam: return Vector3.ZERO
	var from = cam.project_ray_origin(screen_pos)
	var to = from + cam.project_ray_normal(screen_pos) * 500
	var q = PhysicsRayQueryParameters3D.create(from, to)
	q.collide_with_bodies = true
	q.collision_mask = 2
	var res = get_world_3d().direct_space_state.intersect_ray(q)
	return res.position if res else Vector3.ZERO

func _get_entity_under_click(screen_pos: Vector2):
	var cam = get_viewport().get_camera_3d()
	if not cam: return null
	var from = cam.project_ray_origin(screen_pos)
	var to = from + cam.project_ray_normal(screen_pos) * 500
	var q = PhysicsRayQueryParameters3D.create(from, to)
	q.collide_with_bodies = true
	q.collision_mask = 1
	var res = get_world_3d().direct_space_state.intersect_ray(q)
	if res and res.collider is GameEntity:
		return res.collider
	return null

func set_pending_command_mode(mode: String) -> void:
	if mode != "attack" and mode != "move":
		return
	pending_command_mode = mode
	if mode == "attack":
		_show_hud_alert("攻击模式：左键选择目标，右键或 Esc 取消", Color(0.4, 0.8, 1.0), get_host_team(), get_host_team())
	else:
		_show_hud_alert("移动模式：左键选择落点，右键或 Esc 取消", Color(0.4, 0.8, 1.0), get_host_team(), get_host_team())

func has_pending_command() -> bool:
	return pending_command_mode != ""

func clear_pending_command() -> void:
	pending_command_mode = ""

func execute_pending_command(screen_pos: Vector2) -> void:
	var mode := pending_command_mode
	pending_command_mode = ""
	if mode == "":
		return
	_command_selected_units(screen_pos, mode)

# Esc 的取消优先级：一次性下令模式 → 建造模式/建造菜单 → 当前选择。
func handle_cancel() -> void:
	if pending_command_mode != "":
		pending_command_mode = ""
		return
	if build_mode:
		_exit_build_mode()
		return
	if current_build_menu and is_instance_valid(current_build_menu):
		current_build_menu.queue_free()
		current_build_menu = null
		return
	if selection and not selection.selected_entities.is_empty():
		selection._clear_selection()

func clear_garrison_for_selected() -> void:
	if not (selection and selection.has_method("_selection_all_local") and selection._selection_all_local()):
		return
	for u in selection.selected_entities:
		if u is Army and u.has_method("_clear_garrison"):
			u._clear_garrison()
		elif u is Building:
			u.garrison_point = Vector3.ZERO
			if u.has_method("_hide_garrison_marker"):
				u._hide_garrison_marker()

# 己方城墙、桥、己方运载船：选中军队时点击它们应作为移动/上墙/上船目标。
# 敌方城墙/运载船仍按普通攻击目标处理，避免这里把攻城指令吃掉。
func is_special_move_target(target) -> bool:
	if target == null or not is_instance_valid(target) or target.health <= 0:
		return false
	if target is Building:
		var bid := int(target.entity_id)
		if bid == 7:
			# 只有己方桥才是“上桥移动”目标；敌方桥必须走攻击分支，
			# 否则右键敌桥会被吞成普通移动，部队继续打原来的目标。
			return target.team == get_host_team() \
				and is_local_player_owned(int(target.owner_peer_id), int(target.team))
		if bid == 27:
			return target.team == get_host_team() and target.build_timer <= 0.0 \
				and is_local_player_owned(int(target.owner_peer_id), int(target.team))
	if target is Army and int(target.entity_id) == 9:
		return target.team == get_host_team() and is_local_player_owned(int(target.owner_peer_id), int(target.team))
	return false

func command_special_target(target) -> bool:
	_begin_player_command()
	var handled: bool = _command_special_target_impl(target)
	_end_player_command()
	return handled

func _command_special_target_impl(target) -> bool:
	if not is_special_move_target(target):
		return false
	if not (selection and selection.has_method("_selection_all_local") and selection._selection_all_local()):
		return false
	if not selection.has_method("_selection_has_local_army") or not selection._selection_has_local_army():
		return false
	if target is Building and int(target.entity_id) == 27:
		_command_wall_move(target)
	elif target is Building and int(target.entity_id) == 7:
		_command_bridge_move(target)
	elif target is Army and int(target.entity_id) == 9:
		_command_transport_move(target)
	return true

func _selected_ground_army() -> Array:
	var out: Array = []
	if selection == null:
		return out
	for u in selection.selected_entities:
		if not is_instance_valid(u) or not (u is Army) or u.health <= 0:
			continue
		if bool(u.get("water_capable")):
			continue
		var boarded = u.get("_boarded_on")
		if boarded != null and int(boarded) != -1:
			continue
		out.append(u)
	return out

func _clear_wall_guard_assignment(u) -> void:
	if u == null or not is_instance_valid(u):
		return
	if u.has_meta("ai_wall_guard"):
		u.remove_meta("ai_wall_guard")
	if u.has_meta("ai_wall_guard_slot"):
		u.remove_meta("ai_wall_guard_slot")
	if u.has_meta("ai_wall_guard_pos"):
		u.remove_meta("ai_wall_guard_pos")
	if u.has_meta("_auto_board_ship"):
		u.remove_meta("_auto_board_ship")
	u.hold_position = false

func _wall_guard_axis(wall) -> Vector3:
	var best: Building = null
	var best_d := 4.0
	for b in _buildings:
		if b == wall or not is_instance_valid(b) or b.health <= 0:
			continue
		if int(b.entity_id) != 27 or int(b.team) != int(wall.team):
			continue
		var d: float = wall.global_position.distance_to(b.global_position)
		if d > 0.05 and d < best_d:
			best_d = d
			best = b
	if best != null:
		return (best.global_position - wall.global_position).normalized()
	var basis_axis: Vector3 = wall.global_transform.basis.x
	return basis_axis.normalized() if basis_axis.length_squared() > 0.01 else Vector3.RIGHT

func _wall_guard_slot_position(wall, slot: int, count: int) -> Vector3:
	var offsets: Array = [0.0]
	if count == 2:
		offsets = [-0.35, 0.35]
	elif count >= 3:
		offsets = [-0.35, 0.0, 0.35]
	var idx: int = clampi(slot, 0, offsets.size() - 1)
	var axis: Vector3 = _wall_guard_axis(wall)
	# 用城墙格中心而不是建筑节点中心，偏移超过半格会掉到相邻格，失去墙顶保护。
	var g: Vector2i = world_to_grid(wall.global_position)
	var base: Vector3 = grid_to_world(g.x, g.y)
	base.y = wall.global_position.y
	return base + axis.normalized() * float(offsets[idx])

func _wall_has_cannon(wall) -> bool:
	var wg: Vector2i = world_to_grid(wall.global_position)
	for b in _buildings:
		if b == null or not is_instance_valid(b) or b.health <= 0:
			continue
		if int(b.entity_id) == 64 and int(b.team) == int(wall.team) \
				and world_to_grid(b.global_position) == wg:
			return true
	return false

# 墙脚待命点：找墙格外一圈可通行的陆地，避免容量外的部队被寻路塞到墙格上。
func _wall_foot_point(wall) -> Vector3:
	var wg: Vector2i = world_to_grid(wall.global_position)
	var base: Vector3 = wall.global_position
	var start_r: float = float(wall.body_radius) + 1.0
	for r in [start_r, start_r + 1.0, start_r + 2.0]:
		for i in 16:
			var ang: float = TAU * float(i) / 16.0
			var p := base + Vector3(cos(ang) * float(r), 0.0, sin(ang) * float(r))
			if world_to_grid(p) == wg:
				continue
			var t: int = int(get_terrain_at(p))
			if t not in [0, 3]:
				continue
			if is_cliff_between_world(base, p):
				continue
			return p
	return base

func _command_wall_move(wall) -> void:
	var units: Array = _selected_ground_army()
	if units.is_empty():
		return
	if not is_instance_valid(wall) or int(wall.entity_id) != 27 or wall.health <= 0 or wall.build_timer > 0.0:
		return
	if _wall_has_cannon(wall):
		_show_hud_alert("这段城墙已安装炮台，无法再站人", Color(1.0, 0.8, 0.1), get_host_team(), get_host_team())
		return

	var used_slots: Dictionary = {}
	var occupied := 0
	var occupied_large := false
	for e in _armies:
		if not is_instance_valid(e) or e.health <= 0 or e == null:
			continue
		if not e.has_meta("ai_wall_guard"):
			continue
		if int(e.get_meta("ai_wall_guard")) != wall.get_instance_id():
			continue
		occupied += 1
		used_slots[int(e.get_meta("ai_wall_guard_slot", 0))] = true
		if float(e.body_radius) > 0.55:
			occupied_large = true

	var max_slots := 3
	for u in units:
		if float(u.body_radius) > 0.55:
			max_slots = 1
			break
	if occupied_large:
		max_slots = 1
	var free_slots: Array = []
	for i in max_slots:
		if not used_slots.has(i):
			free_slots.append(i)
	# 大型单位独占一段墙：已经有一个守军时不再接受第二个大型单位。
	if max_slots == 1 and occupied > 0:
		free_slots.clear()
	if free_slots.is_empty():
		_show_hud_alert("城墙容量已满，多余部队在墙脚待命", Color(1.0, 0.8, 0.1), get_host_team(), get_host_team())
		for u in units:
			# 已经在墙上的守军保持原位，只把新增部队派到墙脚。
			if u.has_meta("ai_wall_guard") and int(u.get_meta("ai_wall_guard")) == wall.get_instance_id():
				continue
			u.hold_position = true
			u.move_to(_wall_foot_point(wall))
		return

	units.sort_custom(func(a, b):
		return a.global_position.distance_squared_to(wall.global_position) \
			< b.global_position.distance_squared_to(wall.global_position))
	var assigned := 0
	for u in units:
		if assigned < free_slots.size():
			var slot: int = int(free_slots[assigned])
			_clear_wall_guard_assignment(u)
			u.set_meta("ai_wall_guard", wall.get_instance_id())
			u.set_meta("ai_wall_guard_slot", slot)
			var slot_pos: Vector3 = _wall_guard_slot_position(wall, slot, max_slots)
			u.set_meta("ai_wall_guard_pos", slot_pos)
			u.hold_position = true
			if u._movement:
				u._movement.clear_blacklist_at(slot_pos)
			u.move_to(slot_pos)
			assigned += 1
		else:
			# 容量之外的部队到墙脚待命，不占用墙顶槽位。
			_clear_wall_guard_assignment(u)
			u.hold_position = true
			u.move_to(_wall_foot_point(wall))

func _command_bridge_move(bridge) -> void:
	if bridge == null or not is_instance_valid(bridge) or bridge.health <= 0:
		return
	for u in _selected_ground_army():
		_clear_wall_guard_assignment(u)
		u.move_to(bridge.global_position)

func _command_transport_move(ship) -> void:
	if ship == null or not is_instance_valid(ship) or ship.health <= 0:
		return
	if int(ship.get_boarded_count()) >= int(ship.get_board_capacity()):
		_show_hud_alert("运载船已满", Color(1.0, 0.8, 0.1), get_host_team(), get_host_team())
		return
	var shore: Vector3 = _ship_shore_point(ship)
	if shore == Vector3.ZERO:
		_show_hud_alert("运载船未靠岸，无法上船", Color(1.0, 0.8, 0.1), get_host_team(), get_host_team())
		return
	var available: int = int(ship.get_board_capacity()) - int(ship.get_boarded_count())
	var units: Array = _selected_ground_army()
	if units.is_empty():
		return
	# 先清掉旧的自动上船标记：容量外的部队必须原地待命，不能被旧指令带走。
	for u in units:
		if u.has_meta("_auto_board_ship"):
			u.remove_meta("_auto_board_ship")
	units.sort_custom(func(a, b):
		return a.global_position.distance_squared_to(ship.global_position) \
			< b.global_position.distance_squared_to(ship.global_position))
	var assigned := 0
	for u in units:
		if assigned >= available:
			# 容量外的选中部队原地待命，不能保留旧的移动指令。
			u.stop_movement()
			continue
		_clear_wall_guard_assignment(u)
		u.move_to(shore)
		u.set_meta("_auto_board_ship", ship.get_instance_id())
		assigned += 1
	# 容量之外的选中部队保持原地（不要给它们 move_to/自动上船元数据）。

# 运载船旁边的最近可通行陆地点；与 InfoPanel 的登船按钮使用同一套规则。
func _ship_shore_point(ship) -> Vector3:
	var base: Vector3 = ship.global_position
	for r in [1.5, 2.5, 3.5, 5.0, 6.5, 8.0]:
		for i in 16:
			var ang: float = TAU * float(i) / 16.0
			var p := base + Vector3(cos(ang) * float(r), 0.0, sin(ang) * float(r))
			var terrain: int = int(get_terrain_at(p))
			if terrain < 0:
				continue
			if terrain != 2 and is_cliff_between_world(base, p):
				continue
			if terrain == 2:
				var g: Vector2i = world_to_grid(p)
				if int(get_overlay_at_grid(g.x, g.y)) != 3:
					continue
			return p
	return Vector3.ZERO

# ==================== 玩家命令上下文 ====================
# 用于区分“玩家主动命令”和 AI/军需官/自动逻辑的命令：
# 施工中的农民只在玩家命令下才会放下锤子，自动命令会被 Army._queue_command 丢弃。
var _player_cmd_depth: int = 0

func is_player_command_active() -> bool:
	return _player_cmd_depth > 0

func _begin_player_command() -> void:
	_player_cmd_depth += 1

func _end_player_command() -> void:
	_player_cmd_depth = maxi(0, _player_cmd_depth - 1)

func _command_selected_units(screen_pos: Vector2, mode: String = ""):
	_begin_player_command()
	_command_selected_units_impl(screen_pos, mode)
	_end_player_command()

func _command_selected_units_impl(screen_pos: Vector2, mode: String = ""):
	# 防御：只有己方单位可被指挥；队友/敌方选中仅用于查看信息
	if not (selection and selection.has_method("_selection_all_local") and selection._selection_all_local()):
		return
	var cam = get_viewport().get_camera_3d()
	if not cam: return

	var from = cam.project_ray_origin(screen_pos)
	var to = from + cam.project_ray_normal(screen_pos) * 500
	var space = get_world_3d().direct_space_state
	var q = PhysicsRayQueryParameters3D.create(from, to)
	q.collide_with_bodies = true
	q.collision_mask = 1   # 与 SelectionManager 保持一致，只检测实体层
	var res = space.intersect_ray(q)

	var target: GameEntity = null
	if res:
		if res.collider is GameEntity:
			target = res.collider
		elif res.collider.has_meta("entity_root"):
			target = res.collider.get_meta("entity_root")
	var pos = res.position if res else _ray_plane_intersection(from,to,Vector3.ZERO,Vector3.UP)

	# 城墙/桥/运载船优先走特殊移动逻辑，不能被后面的建造/修理分支吃掉。
	if target != null and command_special_target(target):
		return

	# 下达任何普通命令前，先解除此前的上墙/自动上船安排，避免单位继续往旧目标跑。
	for u in selection.selected_entities:
		if u is Army:
			_clear_wall_guard_assignment(u)

	# 选中农民 + 右键自家在建/破损建筑：优先派去施工/修理
	if target is Building and target.team == get_host_team():
		var bt: Building = target as Building
		var builder_ids: Array = []
		for u in selection.selected_entities:
			if u is Army and u.entity_id == 10 and u.health > 0:
				builder_ids.append(u.get_instance_id())
		if not builder_ids.is_empty() and (bt.build_timer > 0.0 or bt.repair_pending or bt.repair_timer > 0.0 or bt.can_repair()):
			if bt.build_timer > 0.0:
				if request_construction(bt, builder_ids) > 0:
					return
			elif bt.repair_pending or bt.repair_timer > 0.0:
				if assign_builders(bt, builder_ids) > 0:
					return
			else:
				if request_repair(bt, builder_ids):
					return

	# 点单位下达攻击/采集时也会先打到旁边建筑的碰撞盒：用选择器的轮廓拾取纠正。
	# 只纠正敌方/中立单位，避免把「点单位旁边空地移动」误判成攻击自家单位。
	if selection and selection.has_method("_get_entity_under_mouse"):
		var picked = selection._get_entity_under_mouse(screen_pos)
		if picked is Army and picked != target and selection.has_method("_is_inspect_only") \
				and selection._is_inspect_only(picked):
			target = picked
			pos = picked.global_position

	# Formation spread for multi-unit move commands (no target clicked)
	var formation_offsets = []
	if not target:
		var count = selection.selected_entities.size()
		var cols = int(ceil(sqrt(count)))
		var spacing = 1.0
		for i in count:
			var row = i / cols
			var col = i % cols
			var ox = (col - (cols - 1) / 2.0) * spacing
			var oy = (row - (cols / 2.0)) * spacing
			formation_offsets.append(Vector3(ox, 0, oy))

	var fi = 0
	for u in selection.selected_entities:
		if is_instance_valid(u) and u is Army:
			# 已登船单位不响应任何地面命令：上/下船统一在运载船信息面板里操作
			if u.get("_boarded_on") != null and u._boarded_on != -1:
				continue
			# A + 左键：强制攻击目标/攻击移动；M + 左键：纯移动，不主动索敌。
			if mode == "move":
				var dest: Vector3 = pos
				if target != null:
					dest = target.global_position
				else:
					if formation_offsets.size() > fi:
						dest = pos + formation_offsets[fi]
					# 方阵落点必须对陆军/水军各自合法，不能把边缘单位送到水里或山上。
					dest = find_legal_formation_pos(u, dest)
				u.move_to(dest)
				fi += 1
				continue
			if mode == "attack":
				if target is WorldResource:
					u.attack_move_to(target.global_position)
				elif target != null:
					if u.has_method("_can_attack_target") and u._can_attack_target(target):
						u.attack_target(target, true)
					else:
						u.attack_move_to(target.global_position)
				else:
					var attack_pos: Vector3 = pos
					if formation_offsets.size() > fi:
						attack_pos += formation_offsets[fi]
					u.attack_move_to(find_legal_formation_pos(u, attack_pos))
				fi += 1
				continue
			if target:
				if target is WorldResource:
					if u.entity_id == 10 or u.entity_id == 14 or u.get("_animal_type") != "":
						# 玩家手动指定采集目标后，军需官不再把这个农民当成自己人重分配。
						_qm_clear_managed(u)
						u.gather_at(target)
					else:
						u.attack_move_to(target.global_position)
				elif target is Army and str(target.get("_animal_type")) != "" \
						and u.has_method("_can_attack_target") and u._can_attack_target(target):
					# 中立动物不是敌对阵营，is_hostile_to 会返回 false；但玩家手动
					# 点动物时应按“狩猎”处理，否则军队只会走到动物旁边不动。
					u.attack_target(target, true)
				elif is_hostile_to(u.team, u.owner_peer_id, target):
					# 攻击过滤：不可攻击目标（同国/盟友/中立）改为移动；
					# 农民/商队等平民不响应攻击指令，避免混合编队里被顺手拉去送死。
					if u.has_method("_can_attack_target") and u._can_attack_target(target):
						u.attack_target(target, true)
					elif int(u.target_type) > 0 and not (u.has_method("_is_naval_chase_target_blocked") and u._is_naval_chase_target_blocked(target)):
						u.move_to(target.global_position)
				elif u.entity_id >= 46 and u.entity_id <= 50 and target is Building:
					u.command_garrison(target)
				elif u.has_method("can_soldier_garrison") and u.can_soldier_garrison(target):
					u._garrison_target_id = target.get_instance_id()
					u.move_to(target.global_position)
				else:
					u.move_to(target.global_position)
			else:
				var fp: Vector3 = pos
				if formation_offsets.size() > fi:
					fp = pos + formation_offsets[fi]
				u.move_to(find_legal_formation_pos(u, fp))
			fi += 1

func _try_open_build_menu(screen_pos: Vector2):
	var cam = get_viewport().get_camera_3d()
	if not cam: return
	var from = cam.project_ray_origin(screen_pos)
	var to = from + cam.project_ray_normal(screen_pos)*500
	var space = get_world_3d().direct_space_state
	var res = space.intersect_ray(PhysicsRayQueryParameters3D.create(from,to))
	if res and is_position_in_player_vision(res.position):
		_show_build_menu(res.position)

func _set_rally_point_by_click(screen_pos: Vector2):
	var cam = get_viewport().get_camera_3d()
	if not cam: return
	var from = cam.project_ray_origin(screen_pos)
	var to = from + cam.project_ray_normal(screen_pos)*500
	var res = get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(from,to))
	if res:
		execute_rally(res.position)

# ==================== 建造系统 ====================
func _process_build_mode(event):
	if event is InputEventMouseMotion:
		_update_build_preview(event.position)
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_touch_start_pos = event.position
			_left_click_timer = CLICK_DELAY
			_pending_left_click = true
			_left_click_source = "build"
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			_pending_left_click = false
			_exit_build_mode()

func _update_build_preview(screen_pos: Vector2):
	var cam = get_viewport().get_camera_3d()
	if not cam or not build_preview: return

	var from = cam.project_ray_origin(screen_pos)
	var to = from + cam.project_ray_normal(screen_pos)*500
	var res = get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(from,to))

	if res:
		var pos = res.position
		pos.x = round(pos.x)
		pos.z = round(pos.z)
		pos.y = $Map.get_height_at(pos) if $Map else 0
		# 炮台预览：放置在城墙上
		if selected_building_id == 64:
			for e in entities.get_children():
				if e is Building and e.entity_id == 27 and e.team == get_host_team() and e.health > 0:
					var hd2 = Vector2(e.global_position.x - pos.x, e.global_position.z - pos.z).length()
					if hd2 < (e.body_radius + 1.0):
						pos.x = e.global_position.x
						pos.z = e.global_position.z
						pos.y = e.global_position.y + get_wall_top_height(e as Building)
						build_preview.rotation.y = e.rotation.y
						break
		build_preview.global_position = pos
		build_preview.visible = true

		var valid = is_position_in_player_vision(pos) and _is_valid_build_position(pos)
		_tint_preview(build_preview, Color(0, 1, 0) if valid else Color(1, 0, 0))
	else:
		build_preview.visible = false

# Check if terrain within radius is flat (adjacent height diff < 0.8)
func _is_terrain_flat(pos: Vector3, radius: float) -> bool:
	if not $Map or not $Map.has_method("get_height_at_grid"): return true
	var g = world_to_grid(pos)
	var check_range = int(ceil(radius)) 
	for dx in range(-check_range, check_range + 1):
		for dy in range(-check_range, check_range + 1):
			var nx = g.x + dx; var ny = g.y + dy
			if nx < 0 or nx >= RTSConfig.MAP_SIZE or ny < 0 or ny >= RTSConfig.MAP_SIZE: continue
			var h0 = $Map.get_height_at_grid(nx, ny)
			for nd in [Vector2i(1,0), Vector2i(0,1)]:
				var ax = nx + nd.x; var ay = ny + nd.y
				if ax < 0 or ax >= RTSConfig.MAP_SIZE or ay < 0 or ay >= RTSConfig.MAP_SIZE: continue
				var h1 = $Map.get_height_at_grid(ax, ay)
				if abs(h1 - h0) >= 1.0: return false
	return true

# 桥(7)的选址校验：只能在水上，不能与其他实体重叠（已有桥除外），
# 且至少有一侧正交邻格是陆地或已有桥 —— 单机与联机服务端共用同一套规则
func is_valid_bridge_position(pos: Vector3) -> bool:
	if get_terrain_at(pos) != 2: return false
	for e in entities.get_children():
		if e is GameEntity and e.health > 0:
			if e is Building and e.entity_id == 7: continue  # 允许邻接已有桥
			if e.global_position.distance_to(pos) < (e.body_radius + 0.5):
				return false
	# 至少一侧邻接陆地或已有桥
	var g = world_to_grid(pos)
	var has_land = false
	for dx in [-1, 0, 1]:
		for dy in [-1, 0, 1]:
			if dx == 0 and dy == 0: continue
			if abs(dx) + abs(dy) != 1: continue
			var nx = g.x + dx; var ny = g.y + dy
			if nx < 0 or nx >= RTSConfig.MAP_SIZE or ny < 0 or ny >= RTSConfig.MAP_SIZE: continue
			if get_terrain_at_grid(nx, ny) != 2: has_land = true
			for e in entities.get_children():
				if e is Building and e.entity_id == 7 and e.health > 0:
					var bg = world_to_grid(e.global_position)
					if bg.x == nx and bg.y == ny: has_land = true
	if not has_land: return false
	return true

func _is_valid_build_position(pos: Vector3, building_id: int = -1, for_team: int = -1) -> bool:
	var bid: int = building_id if building_id >= 0 else selected_building_id
	var bteam: int = for_team if for_team >= 0 else get_host_team()
	var cfg: Dictionary = EntityDatabase.get_config(bid)
	var wall_only := bool(cfg.get("wall_only", false))
	# 普通建筑不能贴着敌军造（防塔攻）。墙顶炮台本来就只能装在己方城墙上，
	# 前线交火时墙边有敌军是常态，不能再按 10 米敌军范围拒绝，否则炮台永远补不上墙。
	if not wall_only:
		for e in entities.get_children():
			if e is GameEntity and e.team != bteam and e.team != RTSConfig.Team.NEUTRAL and e.health > 0:
				if e.global_position.distance_to(pos) < 10.0:
					return false
	var t = get_terrain_at(pos)
	# 陆军不能直接上山，建筑也不能落在普通山体或缓坡/台地上：
	# 否则会造出工人和援军都走不到的孤岛建筑。
	if t == 1:
		return false
	# 桥：只能在水上建造
	if bid == 7:
		return is_valid_bridge_position(pos)
	# 梯子：必须在敌方城墙裸露侧建造
	if bid == 8:
		if t == 2: return false
		for e in entities.get_children():
			if e is GameEntity and e.health > 0:
				if e.global_position.distance_to(pos) < (e.body_radius + 0.5):
					return false
		# 检查是否与敌方城墙裸露侧相邻
		var g = world_to_grid(pos)
		for dx in [-1, 0, 1]:
			for dy in [-1, 0, 1]:
				if dx == 0 and dy == 0: continue
				if abs(dx) + abs(dy) != 1: continue  # 仅正交方向
				var wx = g.x + dx; var wy = g.y + dy
				for e in entities.get_children():
					if e is Building and e.entity_id == 27 and e.team != bteam and e.team != RTSConfig.Team.NEUTRAL and e.health > 0:
						var wg = world_to_grid(e.global_position)
						if wg.x == wx and wg.y == wy:
							# 检查城墙在此方向是否裸露(反方向无同队城墙)
							var exposed = true
							for e2 in entities.get_children():
								if e2 is Building and e2.entity_id == 27 and e2.team == e.team and e2.health > 0 and e2 != e:
									var wg2 = world_to_grid(e2.global_position)
									if wg2.x == wg.x - dx and wg2.y == wg.y - dy:
										exposed = false; break
							if exposed: return true
		return false
	if bid == 23:
		if t != 0: return false
		var g = world_to_grid(pos)
		var water_count = 0
		for dx in [-1,0,1]:
			for dy in [-1,0,1]:
				if dx==0 and dy==0: continue
				if $Map.get_terrain(g.x+dx, g.y+dy) == 2: water_count += 1
		return water_count >= 3
		return false
	else:
		# 炮台(ID=64)：只能放在己方城墙上
		if bid == 64:
			var on_wall = false
			for e in entities.get_children():
				if e is Building and e.entity_id == 27 and e.team == bteam and e.health > 0:
					var wd = Vector2(e.global_position.x - pos.x, e.global_position.z - pos.z).length()
					if wd < (e.body_radius):
						on_wall = true
						break
			if not on_wall: return false
		# Cannot overlap existing buildings/entities
		for e in entities.get_children():
			if e is GameEntity and e.health > 0:
				if e.global_position.distance_to(pos) < (e.body_radius + 0.5):
					return false
		# Check terrain flatness within building radius
		var br = cfg.get("body_radius", 1.0) if cfg else 1.0
		if not _is_terrain_flat(pos, br*0.5): return false
		return t != 2

func _place_building():
	if not build_preview or not build_preview.visible: return
	var pos = build_preview.global_position
	if not is_position_in_player_vision(pos): return
	# Cannot build near enemies
	if not _is_valid_build_position(pos):
		if selected_building_id == 64:
			_show_hud_alert("炮台只能建在已完工的己方城墙上", Color(1.0, 0.8, 0.1), get_host_team(), get_host_team())
		return
	# 检查城堡等级解锁
	if not is_building_unlocked(selected_building_id, player_owner_id, get_host_team()):
		var unlock_tip := get_building_unlock_text(selected_building_id, player_owner_id, get_host_team())
		if unlock_tip == "":
			unlock_tip = "需要主城 Lv.%d" % get_building_required_castle_level(selected_building_id)
		_show_hud_alert(unlock_tip, Color(1.0, 0.8, 0.1), get_host_team(), get_host_team())
		return

	var cfg = EntityDatabase.get_config(selected_building_id)
	if not cfg: return

	# 地形检查（桥允许水上、船坞必须陆地邻水）
	if selected_building_id != 23 and selected_building_id != 7 and get_terrain_at(pos) == 2: return
	if selected_building_id == 23 and get_terrain_at(pos) != 0: return

	# 资源检查
	var cost = cfg.get("cost", {})
	var res = player_resources
	if has_method("get_host_resources"):
		res = get_host_resources()
	for k in cost:
		if res[k] < cost[k]:
			_show_hud_alert({"gold":"黄金","wood":"木材","stone":"石头","food":"食物","oil":"石油"}.get(k, k) + "不足！", Color(1.0, 0.8, 0.1), get_host_team(), get_host_team())
			return

	# 人口（防御塔）
	var is_defense = (selected_building_id == 25 or selected_building_id == 26)
	if is_defense and not can_train_unit(get_host_team()): return


	# 扣费
	for k in cost:
		res[k] -= cost[k]


	# 建造（设置所有权用于颜色）
	cfg["owner_peer_id"] = 1 if not is_online else player_owner_id
	var b = spawn_entity(cfg, get_host_team(), pos) as Building
	if b:
		b.start_construction(5.0, cfg)
		request_construction(b)
		AudioManager.play_sfx("build_place")
		notify_path_recalc(pos)

	if not (Input.is_key_pressed(KEY_SHIFT) or mobile_keep_build_mode):
		_exit_build_mode()

func _exit_build_mode():
	build_mode = false
	mobile_keep_build_mode = false
	mobile_centered_build = false
	build_touch_active = false
	build_drag_started = false
	selected_building_id = -1
	if build_preview and is_instance_valid(build_preview):
		build_preview.queue_free()
	build_preview = null
	if current_build_menu and is_instance_valid(current_build_menu):
		current_build_menu.queue_free()
	current_build_menu = null

func _mobile_screen_center() -> Vector2:
	return get_viewport().get_visible_rect().size * 0.5

# 手机端勾选：在当前屏幕中央尝试建造。连续建造开时保持建造模式，
# 关闭时由 _place_building() 原有的退出逻辑结束建造。
func confirm_mobile_build() -> void:
	if not build_mode or not mobile_centered_build or not build_preview:
		return
	_update_build_preview_from_screen(_mobile_screen_center())
	if not build_preview.visible:
		return
	var pos = build_preview.global_position
	if not is_position_in_player_vision(pos) or not _is_valid_build_position(pos):
		return
	# 以当前开关为准，避免进入建造模式后用户又切换连续建造
	mobile_keep_build_mode = GameSettings.mobile_continuous_build
	_place_building()
	if build_mode and mobile_centered_build:
		_update_build_preview_from_screen(_mobile_screen_center())

# 手机端叉号：无条件退出建造模式
func cancel_mobile_build() -> void:
	if build_mode:
		_exit_build_mode()

func _show_build_menu(world_pos: Vector3):
	if current_build_menu: current_build_menu.queue_free()
	var menu = load("res://scripts/ui/BuildMenu.gd").new()
	menu.building_defs = building_defs
	menu.castle_level = get_player_castle_level()
	if has_node("UI"):
		$UI.add_child(menu)
	else:
		add_child(menu)
	# 尺寸要等 add_child 触发 _ready 之后才知道
	var cam = get_viewport().get_camera_3d()
	var screen_pos: Vector2 = cam.unproject_position(world_pos)
	if InputSource.use_mobile_ui() and menu.has_method("get_menu_size"):
		# 触屏菜单更大：以触点为中心弹出，并夹在视口内避免超出屏幕
		var ms: Vector2 = menu.get_menu_size()
		var vp: Vector2 = get_viewport().get_visible_rect().size
		var margin: float = UILayout.dp(8.0)
		menu.position = Vector2(
			clampf(screen_pos.x - ms.x * 0.5, margin, maxf(margin, vp.x - ms.x - margin)),
			clampf(screen_pos.y - ms.y * 0.5, margin, maxf(margin, vp.y - ms.y - margin)))
	else:
		menu.position = screen_pos - Vector2(65, 15)
	menu.z_index = 10
	current_build_menu = menu
	menu.building_selected.connect(_on_building_selected_for_build)

func _tint_preview(node: Node, color: Color):
	for child in node.get_children():
		if child is MeshInstance3D and child.mesh:
			for si in child.mesh.get_surface_count():
				var existing = child.get_surface_override_material(si)
				if existing and "albedo_color" in existing:
					existing.albedo_color = existing.albedo_color.lerp(color, 0.5)
					continue
				var src = child.get_active_material(si)
				if src and "albedo_color" in src:
					var m = src.duplicate()
					m.albedo_color = src.albedo_color.lerp(color, 0.5)
					child.set_surface_override_material(si, m)
		_tint_preview(child, color)

func _on_building_selected_for_build(building_id: int):
	selected_building_id = building_id
	build_mode = true
	# 手机端「连续建造」开关打开时，放置完一个建筑后保持建造模式（等价电脑端按住 Shift）
	mobile_keep_build_mode = GameSettings.mobile_continuous_build
	var cfg = EntityDatabase.get_config(building_id)
	if not cfg: return
	# 预览必须使用和实际生成相同的有效半径：大部分建筑实际 body_radius 会再乘 2
	var effective_radius: float = float(cfg.get("body_radius", 1.0)) * RTSConfig.get_building_body_scale(building_id)

	# 加载建筑3D模型作为预览
	var model_path = RTSConfig.get_entity_model(building_id)
	if model_path != "" and ResourceLoader.exists(model_path):
		var s = load(model_path)
		if s:
			build_preview = s.instantiate()
			# character 与步兵模型默认朝向相反，预览同样旋转 180°
			if RTSConfig.model_needs_flip(model_path): build_preview.rotation.y = deg_to_rad(180)
	if not build_preview:
		build_preview = MeshInstance3D.new()
		build_preview.mesh = BoxMesh.new()
		build_preview.mesh.size = Vector3(effective_radius * 2.0, effective_radius * 1.5, effective_radius * 2.0)
	# 缩放预览模型匹配实际大小（城墙也要共用横向咬合缩放，避免预览比实墙窄）
	var aabb = _get_model_aabb(build_preview)
	build_preview.scale = _model_scale_for(building_id, effective_radius, aabb)
	build_preview.visible = false
	# 预览旋转（与实际放置一致）
	if building_id in [22, 27, 28]: build_preview.rotation.y = deg_to_rad(90)
	_tint_preview(build_preview, Color(0, 1, 0))
	add_child(build_preview)

	# 手机端：选中即把预览放到屏幕中央，之后单指滑动地图调整落点
	if InputSource.use_mobile_ui():
		mobile_centered_build = true
		_pending_left_click = false
		build_touch_active = false
		build_drag_started = false
		_update_build_preview_from_screen(_mobile_screen_center())

# ==================== 战争迷雾 ====================
func _init_fog_grid():
	explored_grid.clear()
	visible_grid.clear()
	_fog_cover.clear()
	_fog_sources.clear()
	_vision_cells_cache.clear()
	_team_vis_cache.clear()
	_vision_dirty = true
	for x in range(RTSConfig.MAP_SIZE):
		var col_exp = []
		var col_vis = []
		var col_cover = []
		for y in range(RTSConfig.MAP_SIZE):
			col_exp.append(false)
			col_vis.append(false)
			col_cover.append(0)
		explored_grid.append(col_exp)
		visible_grid.append(col_vis)
		_fog_cover.append(col_cover)

func _fog_apply_circle(gx: int, gy: int, r: int, delta: int) -> void:
	var rr: int = r * r
	for dx in range(-r, r + 1):
		var nx: int = gx + dx
		if nx < 0 or nx >= RTSConfig.MAP_SIZE:
			continue
		var cover_row: Array = _fog_cover[nx]
		var vis_row: Array = visible_grid[nx]
		var exp_row: Array = explored_grid[nx]
		for dy in range(-r, r + 1):
			if dx * dx + dy * dy > rr:
				continue
			var ny: int = gy + dy
			if ny < 0 or ny >= RTSConfig.MAP_SIZE:
				continue
			var c: int = int(cover_row[ny]) + delta
			if c > 0:
				cover_row[ny] = c
				vis_row[ny] = true
				exp_row[ny] = true
			else:
				cover_row[ny] = 0
				vis_row[ny] = false

func _update_fog_visibility():
	if visible_grid.is_empty() or explored_grid.is_empty():
		_init_fog_grid()
	var host_team := get_host_team()
	if host_team != _fog_host_team:
		# 换阵营/重开一局时清空一次，之后每轮直接按队伍可见掩码覆盖。
		_init_fog_grid()
		_fog_host_team = host_team
	var mask: PackedByteArray = get_team_visible_mask(host_team)
	var ms: int = RTSConfig.MAP_SIZE
	for x in range(ms):
		var vis_row: Array = visible_grid[x]
		var exp_row: Array = explored_grid[x]
		for y in range(ms):
			var on: bool = mask[x * ms + y] == 1
			vis_row[y] = on
			if on:
				exp_row[y] = true

# 某个视野源当前能看见的格子（带缓存；只在移动/高度/半径变化时重算）。
func _get_source_vision_cells(e, r: int) -> PackedInt32Array:
	if e == null or not is_instance_valid(e) or r <= 0:
		return PackedInt32Array()
	if not e.has_method("get_vision_origin"):
		return PackedInt32Array()
	var map_node = $Map
	if map_node == null or not is_instance_valid(map_node):
		return PackedInt32Array()
	var g: Vector2i = world_to_grid(e.global_position)
	var origin: Vector3 = e.get_vision_origin()
	var id: int = e.get_instance_id()
	var cached = _vision_cells_cache.get(id)
	if cached != null:
		if int(cached.get("gx", -999)) == g.x and int(cached.get("gy", -999)) == g.y \
			and int(cached.get("r", -1)) == r \
			and absf(float(cached.get("head", -999.0)) - origin.y) < 0.08:
			return cached.get("cells", PackedInt32Array())
	var cells: PackedInt32Array = VisionSystem.compute_visible_cells(map_node, origin, float(r))
	_vision_cells_cache[id] = {"gx": g.x, "gy": g.y, "head": origin.y, "r": r, "cells": cells}
	_vision_dirty = true
	# 死亡/移除的单位不少，缓存偶尔清一次，避免 instance_id 长期堆积
	if _vision_cells_cache.size() > VISION_CELLS_CACHE_MAX:
		for key in _vision_cells_cache.keys():
			var ent = instance_from_id(int(key))
			if ent == null or not is_instance_valid(ent) or ent.health <= 0:
				_vision_cells_cache.erase(key)
				_vision_dirty = true
	return cells

# 队伍可见掩码：AI 索敌、联机快照裁剪、建造预览、主机迷雾全部共用。
func get_team_visible_mask(team: int) -> PackedByteArray:
	var ms: int = RTSConfig.MAP_SIZE
	var now: int = Time.get_ticks_msec()
	var cached = _team_vis_cache.get(team)
	var max_age: int = TEAM_VIS_CACHE_MS if _vision_dirty else TEAM_VIS_IDLE_MS
	if cached != null and now - int(cached.get("time", 0)) < max_age:
		return cached.get("mask", PackedByteArray())
	var tree := get_tree()
	if tree == null:
		return PackedByteArray()
	var mask: PackedByteArray = PackedByteArray()
	mask.resize(ms * ms)
	mask.fill(0)
	for e in tree.get_nodes_in_group("vision_providers"):
		if not is_instance_valid(e) or e.health <= 0 or int(e.team) != team:
			continue
		var r: int = get_effective_vision(e)
		if r <= 0:
			continue
		var cells: PackedInt32Array = _get_source_vision_cells(e, r)
		for idx in cells:
			if idx >= 0 and idx < mask.size():
				mask[idx] = 1
	_team_vis_cache[team] = {"time": now, "mask": mask}
	_vision_dirty = false
	return mask

func is_position_visible_to_team(team: int, world_pos: Vector3) -> bool:
	if team < 0:
		return false
	var g: Vector2i = world_to_grid(world_pos)
	var mask: PackedByteArray = get_team_visible_mask(team)
	var idx: int = g.x * RTSConfig.MAP_SIZE + g.y
	return idx >= 0 and idx < mask.size() and mask[idx] == 1

# 远程攻城/箭矢不能隔着一道完整城墙打另一侧；以下情况放行：
# 1) 观察者或目标站在城墙顶上（墙顶对墙下、墙下对墙顶都能打）；
# 2) 观察者是箭塔/炮塔/墙顶炮台（高塔射界越过墙头）；
# 3) 目标就是城墙本身（玩家手动拆墙）；
# 4) 投石车/巨型投石机发射的是抛物线巨石，可以越过墙头砸到另一侧。
# 只有“观察者”能享受石头抛物线豁免；目标在墙后时，普通箭矢仍看不见它。
const WALL_PARABOLIC_UNIT_IDS := [17, 59]

func _is_wall_shot_exempt(entity, as_viewer: bool) -> bool:
	if entity is Building:
		return int(entity.entity_id) in [25, 26, 64]
	if entity is Army:
		if entity._is_unit_on_wall():
			return true
		return as_viewer and int(entity.entity_id) in WALL_PARABOLIC_UNIT_IDS
	return false

func is_wall_blocking_shot(viewer, target) -> bool:
	if viewer == null or not is_instance_valid(viewer) or target == null or not is_instance_valid(target):
		return false
	if int(viewer.get("target_type") if viewer.get("target_type") != null else 2) != 3:
		return false
	if target is Building and int(target.entity_id) == 27:
		return false
	if _is_wall_shot_exempt(viewer, true) or _is_wall_shot_exempt(target, false):
		return false
	return is_wall_between_positions(viewer.global_position, target.global_position)

# 任意两点之间是否隔着一道城墙（路径被封锁时用于挑出真正挡路的墙）。
func is_wall_between_positions(from_pos: Vector3, to_pos: Vector3) -> bool:
	if $Map == null:
		return false
	var cells: Array = VisionSystem.ray_cells(
		$Map, from_pos, to_pos, RTSConfig.MAP_SIZE
	)
	# 两端格不参与遮挡：观察者/目标可能已经贴着墙脚。
	for i in range(1, cells.size() - 1):
		if _wall_shot_grid.has(cells[i]):
			return true
	return false

# 单个单位到目标的真实视线：自动索敌用这个，避免“队友在山上看见”就让
# 山脚单位隔山开火。除了地形/森林，也会按该单位自己的有效视野半径收口。
func is_target_visible_from(viewer, target) -> bool:
	if viewer == null or not is_instance_valid(viewer) or target == null or not is_instance_valid(target):
		return false
	if not viewer.has_method("get_vision_origin"):
		return true
	if viewer.get("vision_range") != null:
		var eff: int = get_effective_vision(viewer)
		if eff > 0:
			var flat_d: float = Vector2(
				target.global_position.x - viewer.global_position.x,
				target.global_position.z - viewer.global_position.z
			).length()
			if flat_d > float(eff) + float(target.get("body_radius") if target.get("body_radius") != null else 0.5):
				return false
	# 城墙遮挡只限制箭矢/炮弹类远程单位；近战无弹道，不受这条影响。
	if is_wall_blocking_shot(viewer, target):
		return false
	if not $Map:
		return true
	return VisionSystem.has_line_of_sight($Map, viewer.get_vision_origin(), target.global_position)

# 兼容旧接口：判断某个位置是否在玩家（主机队伍）当前视野内。
func is_position_in_player_vision(world_pos: Vector3) -> bool:
	return is_position_visible_to_team(get_host_team(), world_pos)

func _apply_fog():
	if $Map and $Map.has_method("apply_fog"):
		if $Map.apply_fog(explored_grid, visible_grid):
			fog_version += 1

func _update_visibility():
	if not entities: return
	if visible_grid.is_empty():
		_init_fog_grid()
	var host_team = get_host_team()
	for e in entities.get_children():
		if not (e is GameEntity): continue
		if e.team == host_team:
			e.visible = true
			continue
		var g = world_to_grid(e.global_position)
		if g.x < 0 or g.x >= RTSConfig.MAP_SIZE or g.y < 0 or g.y >= RTSConfig.MAP_SIZE:
			e.visible = false
			continue
		# 敌方/中立可见性直接查本帧已算好的迷雾网格，避免每帧对每个实体遍历全部友军
		if e.team == RTSConfig.Team.NEUTRAL:
			e.visible = explored_grid[g.x][g.y]
		else:
			e.visible = visible_grid[g.x][g.y]

# ==================== 警报辅助 ====================
# 该实体是否由“人类玩家”控制：单机只认玩家本人（排除同队 AI），联机排除 1000+ 的 AI 合成 peer_id
func is_human_owned(owner: int, team: int) -> bool:
	if is_online:
		if owner < 0:
			return team != RTSConfig.Team.NEUTRAL   # 1v1 单位没有 owner，按队伍区分
		# 联机客户端 peer_id 是随机大整数（实测见过 385949886），不能按数值判断是否 AI，
		# 交给 OnlineBattleManager 的 player_info 判定
		if has_method("is_ai_peer"):
			return not bool(call("is_ai_peer", owner))
		if owner >= 1000:
			return false
		return true
	if owner != -1:
		return owner == player_owner_id
	return team == get_host_team()

# 本地玩家（单机=玩家本人，联机=房主 peer 1）的 owner/team 与归属判断，供统计面板使用
func get_local_owner_id() -> int:
	return player_owner_id

func get_local_team() -> int:
	return get_host_team()

# 建造/升级/生产这类战报是否值得生成：
# - 自己家（人类玩家）一定要生成；
# - 队友也要生成（2v2/3v3 的 AI 队友同队、乱斗里的 AI 盟友不同队但结盟），
#   显不显示交给接收端的「战报筛选」开关决定；
# - 敌方一律不生成，避免泄露视野外的动静（联机里敌方人类玩家的战报只会推给他自己那一方）。
func is_progress_reportable(owner: int, team: int) -> bool:
	if is_human_owned(owner, team):
		return true
	if team < 0 or team == RTSConfig.Team.NEUTRAL:
		return false
	if is_ffa and diplomacy != null and owner >= 0 and diplomacy.is_ally(player_owner_id, owner):
		return true
	# 联机 2v2/3v3：AI 队友是合成 peer，但它所在的队伍里有真人负责接收，
	# 所以照样生成；推送时只会发给该队伍的真人客户端。
	if is_online:
		return team_has_human_player(team)
	# 单机：AI 队友与自己同队
	return team == get_host_team()

# 该队伍里是否有真人玩家（联机由 OnlineBattleManager 覆写；单机没有这个概念）
func team_has_human_player(_team: int) -> bool:
	return false

func is_local_player_owned(owner: int, team: int) -> bool:
	if owner != -1:
		return owner == get_local_owner_id()
	return team == get_local_team()

# 移动端：判断屏幕坐标是否落在触屏面板上（面板点击交给 GUI，不做世界选择）
func is_mobile_ui_point(pos: Vector2) -> bool:
	var mh = get_tree().get_first_node_in_group("mobile_hud")
	if mh and mh.has_method("is_point_over_panel"):
		return bool(mh.call("is_point_over_panel", pos))
	return false

# source_team：这条战况的「当事国」，HUD 据此显示国家名并着色
# （自己绿 / 同阵营友方蓝 / 敌方红）。
# 被攻击型战报一律取被攻击的那一方，而不是攻击方——战况读起来是
# 「【被攻击国】某某被打了」，而不是「【攻击国】打了某某」。
# 无法判定时传 -1，只显示消息本体。
# target_team：联机模式下只推给哪个阵营；-1 表示广播给双方。单机忽略这个参数。
func _show_hud_alert(msg: String, color: Color = Color(1.0, 0.2, 0.1), source_teams = -1, target_team: int = -1, alert_kind: int = 0, is_castle: bool = false, nations: Array = [], alert_pos: Vector3 = Vector3.ZERO, source_owner: int = -1):
	if color == Color(1.0, 0.2, 0.1) or color == Color(1.0, 0.8, 0.1): AudioManager.play_sfx("alert")
	if has_node("UI"):
		var hud = $UI
		if hud and hud.has_method("show_alert_message"):
			hud.show_alert_message(msg, color, source_teams, alert_kind, is_castle, nations, alert_pos, source_owner)

# 队伍列表归一化：支持单个 int 与 Array，负数（未知来源）丢弃
func _alert_team_list(raw) -> Array:
	var out: Array = []
	if raw is int:
		if int(raw) >= 0:
			out.append(int(raw))
		return out
	if raw is Array:
		for t in raw:
			if int(t) >= 0 and not out.has(int(t)):
				out.append(int(t))
	return out

func _is_alert_on_cooldown(key: String, duration: float = 5.0) -> bool:
	return _alert_cooldowns.has(key) and _alert_cooldowns[key] > 0

func _set_alert_cooldown(key: String, duration: float = 5.0):
	_alert_cooldowns[key] = duration

func _detect_enemy_near_base():
	if game_over: return
	var player_castle = get_player_castle()
	if not player_castle: return

	var threat_detected = false
	for e in get_tree().get_nodes_in_group("vision_providers"):
		if not (e is Army) or e.team == get_host_team() or e.team == RTSConfig.Team.NEUTRAL or e.health <= 0: continue
		var dist = e.global_position.distance_to(player_castle.global_position)
		if dist < player_castle.vision_range * 1.2:
			threat_detected = true
			break

	if threat_detected and not _is_alert_on_cooldown("enemy_approach"):
		var loc_str = "(%d,%d)" % [int(player_castle.global_position.x), int(player_castle.global_position.z)]
		# 攻守双方都带上：敌军为攻击方，我方为被入侵方
		_show_hud_alert("敌军来袭！接近我方基地方向 %s" % loc_str, Color(1.0, 0.8, 0.1), [get_enemy_team(), get_host_team()], get_host_team())
		_set_alert_cooldown("enemy_approach", 5.0)

# ==================== 废弃建筑：生成 / 占领 ====================
# 只有真正跑战斗逻辑的一端（单机、联机主机）生成和结算；联机客户端靠快照还原
func is_battle_authority() -> bool:
	return true

func _tick_abandoned_sites(delta: float) -> void:
	if not is_battle_authority():
		return
	if game_over:
		return
	if not _abandoned_spawned:
		# 等各方城堡/初始单位就位（联机开局加载地图有延迟），再撒废墟
		_abandoned_ready_timer += delta
		if _abandoned_ready_timer < 3.0:
			return
		_spawn_abandoned_sites()
		return
	if _abandoned_sites.is_empty():
		return
	_process_abandoned_capture(delta)

# 在地图边缘随机撒中立废墟：要求 3x3 平地、远离双方基地、彼此分散
func _spawn_abandoned_sites() -> void:
	_ensure_cache_fresh()
	var castles: Array = []
	for b in _buildings:
		if is_instance_valid(b) and b.entity_id == 20 and b.health > 0:
			castles.append(b)
	if castles.size() < 2:
		return
	_abandoned_spawned = true
	var map = $Map
	if map == null:
		return
	var size: int = int(map.terrain_grid.size())
	var count: int = clampi(int(round(float(size) * 0.05)), 4, 8)
	var margin: int = 5
	var max_depth: int = maxi(6, int(float(size) * 0.08))
	# 枚举地图四条边缘带上的候选格（深 4..max_depth），洗牌后按间距择优，
	# 比"随机撒点+重试"更容易在群岛/多河这类地图像素上凑够数量
	var cands: Array = []
	for d in range(4, max_depth + 1):
		for along in range(margin, size - margin):
			cands.append(Vector2i(along, margin + d))
			cands.append(Vector2i(along, size - margin - d))
			cands.append(Vector2i(margin + d, along))
			cands.append(Vector2i(size - margin - d, along))
	cands.shuffle()
	var picks: Array = []
	# 间距从宽松到紧凑三档重试，保证任何地图都能撒满
	for spacing in [0.14, 0.10, 0.07]:
		if picks.size() >= count:
			break
		var gap: float = float(size) * float(spacing)
		for g in cands:
			if picks.size() >= count:
				break
			# 需要 3x3 平地：避免长在河面/山体/坡道上
			var flat: bool = true
			for dx in range(-1, 2):
				for dy in range(-1, 2):
					var nx: int = g.x + dx
					var ny: int = g.y + dy
					if nx < 0 or ny < 0 or nx >= size or ny >= size:
						flat = false
						break
					if int(map.terrain_grid[nx][ny]) != 0:
						flat = false
						break
				if not flat:
					break
			if not flat:
				continue
			var wp: Vector3 = grid_to_world(g.x, g.y)
			var far_enough: bool = true
			for b in castles:
				if Vector2(wp.x - b.global_position.x, wp.z - b.global_position.z).length() < float(size) * 0.24:
					far_enough = false
					break
			if far_enough:
				for q in picks:
					if Vector2(wp.x - q.x, wp.z - q.z).length() < gap:
						far_enough = false
						break
			if far_enough:
				picks.append(wp)
	for wp in picks:
		var type_id: int = int(ABANDONED_TYPE_IDS[randi() % ABANDONED_TYPE_IDS.size()])
		var cfg: Dictionary = EntityDatabase.get_config(type_id)
		if cfg.is_empty():
			continue
		cfg["team"] = RTSConfig.Team.NEUTRAL
		var site = spawn_entity(cfg, RTSConfig.Team.NEUTRAL, wp, 1)
		if site:
			site.owner_peer_id = -1
			_abandoned_sites.append(site)
	if not _abandoned_sites.is_empty():
		print("[废弃建筑] 生成 %d 座中立废墟（期待 %d 座，候选 %d 格）" % [
			_abandoned_sites.size(), count, cands.size()])

# 每帧检查：谁的单位最靠近废墟，累计停留时间；先填满 2.5 秒的一方占领
func _process_abandoned_capture(delta: float) -> void:
	_ensure_cache_fresh()
	var alive: Array = []
	for site in _abandoned_sites:
		if not is_instance_valid(site) or site.health <= 0:
			if is_instance_valid(site):
				_abandoned_capture.erase(site.get_instance_id())
			continue
		var best_team: int = -1
		var best_dist: float = 1e20
		var best_army = null
		for e in _spatial_query(site.global_position, ABANDONED_CAPTURE_RADIUS + 3.0):
			if not (e is Army):
				continue
			if e.health <= 0 or e.team == RTSConfig.Team.NEUTRAL:
				continue
			var d: float = site.global_position.distance_to(e.global_position) - e.body_radius
			if d > ABANDONED_CAPTURE_RADIUS:
				continue
			if d < best_dist:
				best_dist = d
				best_team = e.team
				best_army = e
		var sid: int = site.get_instance_id()
		if best_team < 0:
			_abandoned_capture.erase(sid)
			alive.append(site)
			continue
		var st: Dictionary = _abandoned_capture.get(sid, {"team": -1, "time": 0.0})
		if int(st["team"]) != best_team:
			st = {"team": best_team, "time": 0.0}
		st["time"] = float(st["time"]) + delta
		_abandoned_capture[sid] = st
		if float(st["time"]) >= ABANDONED_CAPTURE_TIME:
			_capture_abandoned_site(site, best_army)
			_abandoned_capture.erase(sid)
			continue
		alive.append(site)
	_abandoned_sites = alive

func _capture_abandoned_site(site: Building, army: Army) -> void:
	if not is_instance_valid(site) or not is_instance_valid(army):
		return
	var team: int = army.team
	var owner_id: int = int(army.owner_peer_id)
	site.team = team
	site.owner_peer_id = owner_id
	# 换成占领方的国家色，和正常建筑一致
	var tint: Color = get_entity_color(site)
	tint = Color(0.2 + tint.r * 0.8, 0.2 + tint.g * 0.8, 0.2 + tint.b * 0.8)
	_apply_team_tint(site, tint)
	# 等级旗帜/底座色环/等级徽章是按「生成时的队伍色」烘出来的，占领后必须按新国家色重建，
	# 否则废墟会一直挂着中立灰旗（联机客户端收到新 team 的快照后会自己重刷）
	LevelVisualScript.apply(
		site,
		maxi(site.upgrade_level, site.level),
		0.0,
		get_entity_color(site),
		site.build_timer <= 0.0,
	)
	mark_entity_cache_dirty()
	# 废弃仓库/民居从"中立"转为"己方"，仓储与人口上限要按新队伍重算
	if site.entity_id == 22:
		update_resource_limits(team)
	elif site.entity_id == 28:
		update_population_limits()
	var loot: Dictionary = _abandoned_loot_for(site.entity_id)
	_grant_capture_loot(army, loot)
	var who: String = "我方" if is_human_owned(owner_id, team) else "队友"
	_show_hud_alert("【废弃建筑】%s占领了%s%s" % [who, _abandoned_label(site.entity_id), _loot_text(loot)],
		Color(0.95, 0.85, 0.35), [team], team, GameSettings.AlertKind.MISC, false, [],
		site.global_position, owner_id)
	print("[废弃建筑] team=%d owner=%d 占领 %s" % [team, owner_id, _abandoned_label(site.entity_id)])

# 战利品按队伍/玩家入账：自建模式走 owner 资源，单机 1v1 走队伍资源
func _grant_capture_loot(army: Army, loot: Dictionary) -> void:
	var owner_id: int = int(army.owner_peer_id)
	if owner_id >= 0:
		for k in loot:
			add_resource_for(owner_id, k, int(loot[k]))
	else:
		for k in loot:
			add_resource(k, int(loot[k]), army.team)

func _abandoned_loot_for(type_id: int) -> Dictionary:
	match type_id:
		22:
			return {"gold": 120, "wood": 80}
		28:
			return {"food": 100, "gold": 60}
		27:
			return {"stone": 60, "gold": 30}
		_:
			return {"gold": 80}

func _abandoned_label(type_id: int) -> String:
	match type_id:
		22:
			return "废弃仓库"
		28:
			return "废弃民居"
		27:
			return "废弃城墙"
		_:
			return "废弃瞭望塔"

func _loot_text(loot: Dictionary) -> String:
	var names: Dictionary = {"gold": "黄金", "wood": "木材", "stone": "石头", "food": "食物", "oil": "石油"}
	var parts: Array = []
	for k in loot:
		parts.append("+%d %s" % [int(loot[k]), names.get(k, k)])
	if parts.is_empty():
		return ""
	return "：" + "、".join(parts)

# ==================== 每帧更新 ====================
var _limit_update_timer: float = 0.0
func _process(delta):
	_tick_astar_stats()
	# 手机端居中建造：地图被单指平移后，预览始终落在新的屏幕中心
	if build_mode and mobile_centered_build and build_preview:
		_mobile_preview_timer -= delta
		if _mobile_preview_timer <= 0.0:
			_mobile_preview_timer = 0.05
			_update_build_preview_from_screen(_mobile_screen_center())
	# 延迟左键处理：建造模式下直接放置建筑
	if _pending_left_click:
		_left_click_timer -= delta
		if _left_click_timer <= 0:
			_pending_left_click = false
			if _left_click_source == "build":
				_place_building()
				if not Input.is_key_pressed(KEY_SHIFT):
					_exit_build_mode()
	# 暂停：建造预览和延迟左键已经处理完，但时间、AI、建造/生产/升级、寻路、迷雾全部冻结。
	if get_tree().paused:
		return
	game_time += delta
	_tick_research(delta)
	_tick_builder_dispatch(delta)
	_tick_quartermaster(delta)
	_tick_army_officer(delta)
	_tick_abandoned_sites(delta)
	_focus_camera_on_player_castle_once()
	if battle_stats:
		battle_stats.tick(delta)
	# 乱斗外交推进（联盟到期 / 二人存活强制解除等）
	if diplomacy:
		diplomacy.tick(game_time)
	if game_time_label:
		var secs_total := int(game_time)
		# Label 文本每帧重设会触发 GUI 重新排版，秒数不变时不必更新
		if secs_total != _last_clock_secs:
			_last_clock_secs = secs_total
			var mins = int(game_time / 60)
			var secs = secs_total % 60
			game_time_label.text = "%02d:%02d" % [mins, secs]

	# ---- 顶部信息：性能 + 对局信息（桌面两行 / 手机四行短句）----
	if _fps_label and Engine.get_process_frames() % 10 == 0:
		_ensure_cache_fresh()
		var mobile := InputSource.use_mobile_ui()
		var phys_frames = Engine.get_physics_frames()
		var phys_ok = (phys_frames != _diag_physics_heartbeat)
		var single := _diag_single_line()
		var diff_names = ["简单", "普通", "困难", "地狱"]
		var dn = diff_names[clampi(GameSettings.ai_difficulty, 0, 3)]
		var map_name := String(MapPresets.get_info(GameSettings.map_id).get("name", "经典大陆"))
		var clock := "%02d:%02d" % [int(game_time / 60.0), int(game_time) % 60]
		if not phys_ok and _diag_physics_heartbeat > 0:
			_fps_label.add_theme_color_override("font_color", Color.RED)
			_fps_label.text = "🔴 主循环卡死 FPS:%.0f" % Engine.get_frames_per_second()
			if _snap_rate_label:
				_snap_rate_label.text = ""
		else:
			_fps_label.add_theme_color_override("font_color", Color.LIME_GREEN)
			if single:
				# 桌面/手机横屏：一行塞进胶囊右边；文字尽量短，字号由 _layout_diag_now 自适应
				if mobile:
					_fps_label.text = "%dF 画质%d | %s %s %s" % [
						Engine.get_frames_per_second(), _perf_quality_level, dn, map_name, clock]
				else:
					_fps_label.text = "%dFPS 画质%d | %s %s %s" % [
						Engine.get_frames_per_second(), _perf_quality_level, dn, map_name, clock]
				if _snap_rate_label:
					_snap_rate_label.text = ""
			else:
				# 竖屏手机：保持两行
				_fps_label.text = "FPS:%.0f 画质:%d" % [
					Engine.get_frames_per_second(), _perf_quality_level]
				if _snap_rate_label:
					_snap_rate_label.text = "AI:%s %s %s" % [dn, map_name, clock]
		_layout_diag_now()
		_diag_physics_heartbeat = phys_frames
		_diag_step = (_diag_step + 1) % 1000

	# 定期刷新实体缓存 (0.5s间隔，避免过于频繁重建)
	_cache_refresh_timer -= delta
	if _cache_refresh_timer <= 0:
		_cache_refresh_timer = 0.5
		mark_entity_cache_dirty()

	# ---- 诊断：每5秒输出实体统计，检测泄漏 ----
	_diag_timer -= delta
	if _diag_timer <= 0:
		_diag_timer = 5.0
		_ensure_cache_fresh()
		var bullet_count = get_tree().get_nodes_in_group("bullets").size() if false else 0
		# 统计子弹（通过遍历所有节点）
		var bullets = 0
		for c in get_children():
			if c is Bullet: bullets += 1
		for c in entities.get_children():
			if c is Bullet: bullets += 1
		var delta_total = _all_entities.size() - _diag_last_total
		
		

		_diag_last_total = _all_entities.size()
		_diag_last_bullets = bullets

	fog_timer -= delta
	if fog_timer <= 0:
		fog_timer = 0.5
		_update_fog_visibility()
		_apply_fog()
		# 实体可见性依赖的迷雾网格每 0.5s 才变化，无需每帧全量刷新
		_update_visibility()
		# 队伍制（纯离线1v1 / 联机）才整队刷新人口上限；owner 制由下方 1s 循环按 owner 刷新，
		# 避免 0.5s 的全蓝方统计把队友房屋算进玩家上限
		if ai_players.is_empty():
			update_population_limits()
		# 每 0.5s 直接重算“当前人口”= 存活且占人口额度的实体数，纠正事件式 ±1 记录的漂移
		recount_current_population()

	# Update resource limits every second
	_limit_update_timer -= delta
	if _limit_update_timer <= 0:
		_limit_update_timer = 1.0
		update_resource_limits(get_host_team())
		update_resource_limits(get_enemy_team())
		_update_command_card_sp()
		if ai_players.size() > 0:
			for pid in ai_players.keys():
				update_player_limits(pid)
				update_player_population(pid)

		var mm = $UI/Minimap
		if mm:
			mm.explored_grid = explored_grid
			mm.visible_grid = visible_grid

	# 更新警报冷却
	for key in _alert_cooldowns.keys():
		_alert_cooldowns[key] -= delta
		if _alert_cooldowns[key] <= 0:
			_alert_cooldowns.erase(key)

	# 敌军来袭检测
	_enemy_attack_cooldown -= delta
	if _enemy_attack_cooldown <= 0:
		_enemy_attack_cooldown = 5.0
		_detect_enemy_near_base()

	_tick_adaptive_quality(delta)
	_tick_distant_shadows(delta)
	_tick_animation_lod(delta)
	_tick_physics_rate(delta)

# ==================== 后期自动画质 ====================
# 默认画质固定为“极致”，并锁定档位；玩家在设置面板手动选择其他画质时仍会覆盖该档位。
func _apply_default_quality() -> void:
	hand_quality_mode = true
	_perf_quality_level = 0
	var vp := get_viewport()
	if vp:
		vp.scaling_3d_scale = 1.0
	var light := _find_directional_light()
	if light:
		light.shadow_enabled = true
		light.directional_shadow_max_distance = 120.0
	var env := _find_world_environment()
	if env:
		env.ssao_enabled = true

func _tick_adaptive_quality(delta: float) -> void:
	if game_over or DisplayServer.get_name() == "headless":
		return
	# 默认锁定最高画质，或玩家手动选定画质后，不再自动降档
	if hand_quality_mode:
		return
	if not _perf_initialized:
		_perf_initialized = true
		if DisplayServer.get_name() == "headless":
			return
		_perf_viewport = get_viewport()
		_perf_base_scale = _perf_viewport.scaling_3d_scale if _perf_viewport else 1.0
		_perf_light = _find_directional_light()
		if _perf_light:
			_perf_light_shadow_original = _perf_light.shadow_enabled
			_perf_light_shadow_distance_original = _perf_light.directional_shadow_max_distance
			_perf_light_shadow_mode_original = _perf_light.directional_shadow_mode
		_perf_env = _find_world_environment()
		if _perf_env:
			_perf_ssao_original = _perf_env.ssao_enabled
	# 光照/环境节点可能比战斗根节点稍晚就绪，缺失时在后续采样中再找一次
	if _perf_light == null:
		_perf_light = _find_directional_light()
		if _perf_light:
			_perf_light_shadow_original = _perf_light.shadow_enabled
			_perf_light_shadow_distance_original = _perf_light.directional_shadow_max_distance
			_perf_light_shadow_mode_original = _perf_light.directional_shadow_mode
	if _perf_env == null:
		_perf_env = _find_world_environment()
		if _perf_env:
			_perf_ssao_original = _perf_env.ssao_enabled
	# 开局前 45 秒不采样，避开地图生成、加载和建筑一次性落地的波动
	if game_time < 45.0:
		return
	_perf_sample_timer -= delta
	if _perf_sample_timer > 0.0:
		return
	_perf_sample_timer = 1.5

	var fps := Engine.get_frames_per_second()
	if fps < 50.0:
		_perf_low_streak += 1
		_perf_high_streak = 0
	elif fps > 56.0:
		_perf_high_streak += 1
		_perf_low_streak = 0
	else:
		_perf_low_streak = 0
		_perf_high_streak = 0

	# 降档要快：连续约 3 秒低于 50 就降，低于 40 一次降两档；
	# 升档仍要连续 6 秒高于 56，避免画质来回跳。
	if _perf_low_streak >= 2 and _perf_quality_level < PERF_LEVEL_SCALES.size() - 1:
		var steps: int = 2 if fps < 40.0 else 1
		_perf_quality_level = mini(_perf_quality_level + steps, PERF_LEVEL_SCALES.size() - 1)
		_perf_low_streak = 0
		_perf_high_streak = 0
		_apply_perf_quality()
	elif _perf_high_streak >= 4 and _perf_quality_level > 0:
		_perf_quality_level -= 1
		_perf_low_streak = 0
		_perf_high_streak = 0
		_apply_perf_quality()
	# 实体数本身就是压力信号：后期几百个单位时即使还没掉到 50 也先降档，
	# 否则等帧率继续下滑，玩家已经感到卡顿了
	var ent_count: int = entities.get_child_count() if entities else 0
	if ent_count >= 300 and _perf_quality_level < 2:
		_perf_quality_level = 2
		_apply_perf_quality()
	elif ent_count >= 220 and _perf_quality_level < 1:
		_perf_quality_level = 1
		_apply_perf_quality()

func _apply_perf_quality() -> void:
	var vp := get_viewport()
	if vp:
		var scale_factor: float = PERF_LEVEL_SCALES[_perf_quality_level]
		vp.scaling_3d_scale = clampf(_perf_base_scale * scale_factor, 0.5, 2.0)
	if _perf_light and is_instance_valid(_perf_light):
		# 单位影子必须保留：不再按画质关闭实时阴影，只缩短投射距离并减少分片。
		# 这样中后期近处单位仍有影子，远处阴影先消失，GPU 压力明显小于全距离阴影。
		var ent_count: int = entities.get_child_count() if entities else 0
		# 最低画质档连实时阴影一起关掉：几百个单位各投一次影是后期 GPU 的最大单项开销
		var want_shadow: bool = _perf_light_shadow_original and _perf_quality_level < PERF_LEVEL_SCALES.size() - 1
		if _perf_light.shadow_enabled != want_shadow:
			_perf_light.shadow_enabled = want_shadow
			if not want_shadow:
				_restore_shadow_casting()
		if want_shadow:
			var distance_scale: float = PERF_SHADOW_DISTANCE_SCALES[clampi(_perf_quality_level, 0, PERF_SHADOW_DISTANCE_SCALES.size() - 1)]
			# 实体越多阴影越短，避免后期几百单位同时投影
			if ent_count > 320:
				distance_scale *= 0.68
			elif ent_count > 240:
				distance_scale *= 0.85
			_perf_light.directional_shadow_max_distance = maxf(_perf_light_shadow_distance_original * distance_scale, 12.0)
			if _perf_light_shadow_mode_original == DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS:
				_perf_light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS if _perf_quality_level >= 2 else _perf_light_shadow_mode_original
			else:
				_perf_light.directional_shadow_mode = _perf_light_shadow_mode_original
	if _perf_env and is_instance_valid(_perf_env):
		# 第一档就关闭 SSAO；全屏环境光遮蔽在几百个单位同屏时开销很高，关掉后画面差异很小
		var want_ssao: bool = _perf_ssao_original and _perf_quality_level < 1
		if _perf_env.ssao_enabled != want_ssao:
			_perf_env.ssao_enabled = want_ssao
	# 水面：画质档越低，屏幕空间反射越弱（最低档完全关闭），船体尾迹略降
	var map_node := get_node_or_null("Map")
	if map_node and map_node.has_method("set_water_quality"):
		map_node.set_water_quality(_perf_quality_level)

# 远景单位不投影：相机远处的单位在屏幕上只有几个像素，阴影 pass 却仍要画一遍完整几何。
# 节流到 2 秒一次，按相机距离批量开关，后期能明显减少阴影绘制量。
func _tick_distant_shadows(delta: float) -> void:
	if DisplayServer.get_name() == "headless" or game_over:
		return
	_distant_shadow_timer -= delta
	if _distant_shadow_timer > 0.0:
		return
	_distant_shadow_timer = 2.0
	if not _perf_light or not is_instance_valid(_perf_light):
		return
	if not _perf_light.shadow_enabled:
		# 阴影已整体关闭：把之前按距离关掉的节点恢复，避免下次开阴影时状态错乱
		_restore_shadow_casting()
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	_ensure_cache_fresh()
	var cam_pos := cam.global_position
	var limit: float = 46.0 - float(_perf_quality_level) * 6.0
	for a in _armies:
		if not is_instance_valid(a):
			continue
		var far: bool = cam_pos.distance_to(a.global_position) > limit
		_toggle_shadow_recursive(a, far)

# 动画 LOD：几百个角色即使屏幕外，AnimationPlayer 仍会推进骨骼动画。
# 每秒按“是否在相机视锥内 + 距离”批量停掉远景/屏幕外单位的动画，
# 重新进入视野时恢复；单位少时全部恢复，避免影响正常战斗画面。
func _tick_animation_lod(delta: float) -> void:
	if game_over:
		return
	_anim_lod_timer -= delta
	if _anim_lod_timer > 0.0:
		return
	_anim_lod_timer = 1.0
	_ensure_cache_fresh()
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null or _armies.size() < 260:
		for a in _armies:
			if is_instance_valid(a):
				a.set_animation_lod(false)
		return
	for a in _armies:
		if not is_instance_valid(a) or a.health <= 0:
			continue
		var p: Vector3 = a.global_position + Vector3(0, 1.0, 0)
		# 只停“屏幕外”单位。不能再用距离阈值：RTS 相机高度 10~95m，
		# 默认/拉远视角下相机到屏幕中心单位往往已经超过 55m，按距离停会把
		# 全屏可见单位的动画一起停掉，表现为后期所有单位定格。
		var offscreen: bool = not cam.is_position_in_frustum(p)
		a.set_animation_lod(offscreen)

# 500 单位级战斗：每个物理 tick 的 Army 逻辑已经接近 16ms，再乘上帧末
# 追赶的多个 physics tick 就会把帧时间推到几百毫秒。渲染保持 60FPS，
# 单机大规模战斗把模拟降到 30Hz；低于 20FPS 时再降到 20Hz，减少每帧补跑步数。
func _tick_physics_rate(delta: float) -> void:
	if game_over:
		return
	_physics_tick_timer -= delta
	if _physics_tick_timer > 0.0:
		return
	_physics_tick_timer = 2.0
	if is_online or NetworkManager.mode != NetworkManager.Mode.NONE:
		_set_physics_rate_low(false)
		return
	var ent_count: int = entities.get_child_count() if entities else 0
	# 240 个单位开始就可能出现“一帧补跑多个物理步”的死亡螺旋，不必等到 420。
	# 30Hz 模拟对 RTS 的移动/战斗手感影响很小，但能把每帧物理工作量砍半。
	if ent_count >= 240:
		_set_physics_rate_low(true)
	elif ent_count < 200:
		_set_physics_rate_low(false)

func _set_physics_rate_low(low: bool) -> void:
	# 低帧率时既要保持游戏时间接近真实，又不能一帧补跑太多物理步：
	# 30Hz 模拟在 10FPS 下每帧要补 3 步，Army 逻辑重时会把帧时间继续推高，
	# 表现为画面一阵一阵地卡。低于 20FPS 时把模拟降到 20Hz，10FPS 只需补 2 步，
	# 总模拟时间仍然是 1 秒，但每帧少跑一步；正常帧率仍保持 30Hz 手感。
	var fps: float = Engine.get_frames_per_second()
	var want_hz: int = 20 if (low and fps < 20.0) else 30
	# 最多补 4 步：20Hz 下足以支撑到 5FPS，30Hz 下足以支撑到 7.5FPS；
	# 更极端的掉帧宁可让游戏稍微慢一点，也不制造更长的卡顿尖峰。
	var want_steps: int = 4
	if _physics_rate_low == low \
			and (not low or (Engine.physics_ticks_per_second == want_hz \
				and Engine.max_physics_steps_per_frame == want_steps)):
		return
	_physics_rate_low = low
	if low:
		Engine.physics_ticks_per_second = want_hz
		Engine.max_physics_steps_per_frame = want_steps
	else:
		Engine.physics_ticks_per_second = maxi(_physics_tick_original, 30)
		Engine.max_physics_steps_per_frame = maxi(_physics_max_steps_original, 1)

func _toggle_shadow_recursive(node: Node, far: bool) -> void:
	for c in node.get_children():
		if c is GeometryInstance3D:
			var gi := c as GeometryInstance3D
			if far:
				if not gi.has_meta("_shadow_orig"):
					gi.set_meta("_shadow_orig", gi.cast_shadow)
				if gi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
					gi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			elif gi.has_meta("_shadow_orig"):
				gi.cast_shadow = int(gi.get_meta("_shadow_orig"))
				gi.remove_meta("_shadow_orig")
		_toggle_shadow_recursive(c, far)

func _restore_shadow_casting() -> void:
	for a in _armies:
		if is_instance_valid(a):
			_toggle_shadow_recursive(a, false)

func _exit_tree() -> void:
	# 大规模战斗物理降频是全局 Engine 设置，离开战斗必须还原。
	Engine.physics_ticks_per_second = maxi(_physics_tick_original, 30)
	Engine.max_physics_steps_per_frame = maxi(_physics_max_steps_original, 1)
	# 自动画质改的是根 Viewport/场景光照，切回主菜单或开下一局前必须还原
	if _perf_viewport and is_instance_valid(_perf_viewport):
		_perf_viewport.scaling_3d_scale = _perf_base_scale
	if _perf_light and is_instance_valid(_perf_light):
		_perf_light.shadow_enabled = _perf_light_shadow_original
		_perf_light.directional_shadow_max_distance = _perf_light_shadow_distance_original
		if _perf_light_shadow_mode_original != -1:
			_perf_light.directional_shadow_mode = _perf_light_shadow_mode_original
	if _perf_env and is_instance_valid(_perf_env):
		_perf_env.ssao_enabled = _perf_ssao_original

func _find_world_environment() -> Environment:
	var scene := get_tree().current_scene
	if scene == null:
		return null
	var envs := scene.find_children("*", "WorldEnvironment", true, false)
	for we in envs:
		if we is WorldEnvironment and we.environment:
			return we.environment
	return null

func _find_directional_light() -> DirectionalLight3D:
	var scene := get_tree().current_scene
	if scene == null:
		return null
	var lights := scene.find_children("*", "DirectionalLight3D", true, false)
	for l in lights:
		if l is DirectionalLight3D:
			return l
	return null

# ==================== 工具函数 ====================
func _ray_plane_intersection(ro, re, po, pn):
	var d = (re - ro).normalized()
	var den = d.dot(pn)
	if abs(den) < 0.0001: return Vector3.ZERO
	var t = (po - ro).dot(pn) / den
	return ro + d * t if t >= 0 else Vector3.ZERO

func world_to_grid(pos: Vector3) -> Vector2i:
	var half = RTSConfig.MAP_SIZE / 2.0
	var gx = clampi(round(pos.x + half), 0, RTSConfig.MAP_SIZE-1)
	var gy = clampi(round(pos.z + half), 0, RTSConfig.MAP_SIZE-1)
	return Vector2i(gx, gy)

func get_terrain_at(pos: Vector3) -> int:
	var g = world_to_grid(pos)
	return $Map.get_terrain(g.x, g.y) if $Map else -1

func get_terrain_at_grid(gx: int, gy: int) -> int:
	if not $Map or not $Map.has_method("get_terrain"):
		return -1
	return $Map.get_terrain(gx, gy)

# 懒构建“到最近水域的格数”网格。BFS 从所有水格出发，地图只加载一次，
# 之后海军筛选追击目标就是 O(1) 查询，不会每个候选都扫一圈地形。
func _ensure_water_distance_grid() -> void:
	if not $Map:
		return
	# 地图脚本可能还没跑完 _ready，terrain_grid 先分配后填充；等节点就绪再缓存，
	# 否则会把一张还没有水的地形网格缓存成“全陆地”。
	if not $Map.is_node_ready():
		return
	var map_generated = $Map.get("map_generated")
	if map_generated != null and not bool(map_generated):
		return
	var terrain = $Map.get("terrain_grid")
	if not (terrain is Array) or terrain.is_empty():
		return
	var size: int = terrain.size()
	if _water_distance_size == size and _water_distance_grid.size() == size * size:
		return
	var total: int = size * size
	var grid := PackedInt32Array()
	grid.resize(total)
	for i in range(total):
		grid[i] = -1
	var queue := PackedInt32Array()
	queue.resize(total)
	var head: int = 0
	var tail: int = 0
	for gx in range(size):
		var col = terrain[gx]
		if not (col is Array) or col.size() < size:
			continue
		for gy in range(size):
			if int(col[gy]) == 2:
				var idx: int = gy * size + gx
				grid[idx] = 0
				queue[tail] = idx
				tail += 1
	_water_distance_has_water = tail > 0
	while head < tail:
		var idx: int = queue[head]
		head += 1
		var next_dist: int = grid[idx] + 1
		var gx: int = idx % size
		var gy: int = int(idx / size)
		for dx in range(-1, 2):
			var nx: int = gx + dx
			if nx < 0 or nx >= size:
				continue
			for dy in range(-1, 2):
				if dx == 0 and dy == 0:
					continue
				var ny: int = gy + dy
				if ny < 0 or ny >= size:
					continue
				var nidx: int = ny * size + nx
				if grid[nidx] != -1:
					continue
				grid[nidx] = next_dist
				queue[tail] = nidx
				tail += 1
	_water_distance_grid = grid
	_water_distance_size = size

# 返回世界坐标所在格到最近水格的格数（一格约 1 米）。没有地图/没有水时返回 -1，
# 调用方据此放行，避免把“没有海的地图”误判成所有地面目标都不可追。
func get_water_distance_at(pos: Vector3) -> float:
	if not $Map:
		return -1.0
	_ensure_water_distance_grid()
	if not _water_distance_has_water or _water_distance_grid.is_empty():
		return -1.0
	var g: Vector2i = world_to_grid(pos)
	if g.x < 0 or g.x >= _water_distance_size or g.y < 0 or g.y >= _water_distance_size:
		return -1.0
	var dist: int = _water_distance_grid[g.y * _water_distance_size + g.x]
	if dist < 0:
		return 9999.0
	return float(dist)

# 覆盖层：0=无 1=森林 2=沼泽 3=浅滩 4=缓坡 5=山顶台地
# 山地只有 4/5 可通行，普通山壁由 is_blocked_mountain_tile 判定为不可通行。
func get_overlay_at_grid(gx: int, gy: int) -> int:
	if not $Map or not $Map.has_method("get_overlay"):
		return 0
	return $Map.get_overlay(gx, gy)

# 有效视野：地图倍率 × 高地加成 × 森林遮蔽，供迷雾与可见性判定共用
func get_effective_vision(e) -> int:
	if not e:
		return 0
	if not $Map:
		return maxi(0, int(round(float(e.vision_range) * float(map_modifiers.get("vision", 1.0)))))
	return VisionSystem.effective_radius(
		$Map, e.global_position, float(e.vision_range), map_modifiers
	)
# 将网格坐标 (gx, gy) 转换为世界坐标 (以地图中心为原点)
func grid_to_world(gx: int, gy: int) -> Vector3:
	return Vector3(gx - RTSConfig.MAP_SIZE / 2.0, 0, gy - RTSConfig.MAP_SIZE / 2.0)
# ==================== 快捷功能 ====================
func get_height_at_grid(gx: int, gy: int) -> float:
		if not $Map or not $Map.has_method("get_height_at_grid"):
			return 0.0
		return $Map.get_height_at_grid(gx, gy)

# 普通山壁：terrain=1 且没有缓坡(4)/台地(5)标记。陆军不能直接上山，
# 这类格子在出生、登陆、AI 防线判断里都按“悬崖”处理。
func is_blocked_mountain_tile(gx: int, gy: int) -> bool:
	if get_terrain_at_grid(gx, gy) != 1:
		return false
	var ov: int = get_overlay_at_grid(gx, gy)
	return ov != 4 and ov != 5

func is_highland_tile(gx: int, gy: int) -> bool:
	var ov: int = get_overlay_at_grid(gx, gy)
	return ov == 4 or ov == 5

func is_plateau_tile(gx: int, gy: int) -> bool:
	return get_overlay_at_grid(gx, gy) == 5

# 台地边缘只允许接缓坡或另一块台地；平地/水面直接贴台地按悬崖处理。
func is_plateau_transition_blocked(a: Vector2i, b: Vector2i) -> bool:
	var oa: int = get_overlay_at_grid(a.x, a.y)
	var ob: int = get_overlay_at_grid(b.x, b.y)
	if oa != 5 and ob != 5:
		return false
	var a_high := oa == 4 or oa == 5
	var b_high := ob == 4 or ob == 5
	return not a_high or not b_high

# 某格是否存在超过最大可走坡度的邻接台阶，或本身就是不可通行的山壁。
# 用于出生点、登陆点、AI 防线等“能不能站/能不能过去”的判定；
# 真正的寻路仍由 MovementController 逐边计算。
func is_cliff_tile(gx: int, gy: int) -> bool:
	if is_blocked_mountain_tile(gx, gy):
		return true
	if is_plateau_tile(gx, gy):
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var px: int = gx + d.x
			var py: int = gy + d.y
			if px < 0 or py < 0 or px >= RTSConfig.MAP_SIZE or py >= RTSConfig.MAP_SIZE:
				continue
			if not is_highland_tile(px, py):
				return true
	var h: float = get_height_at_grid(gx, gy)
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var nx: int = gx + d.x
		var ny: int = gy + d.y
		if nx < 0 or ny < 0 or nx >= RTSConfig.MAP_SIZE or ny >= RTSConfig.MAP_SIZE:
			continue
		if RTSConfig.is_cliff_slope(get_height_at_grid(nx, ny) - h, 1.0):
			return true
	return false

# 两个世界坐标所在格之间是否是悬崖台阶或不可通行的山壁。注意这不是完整路径校验，
# 只用于判断“当前点到下一落脚点”这种相邻格移动。
func is_cliff_between_world(from_pos: Vector3, to_pos: Vector3) -> bool:
	var a: Vector2i = world_to_grid(from_pos)
	var b: Vector2i = world_to_grid(to_pos)
	if a == b:
		return false
	# 目标或当前格是普通山壁时直接拒绝；缓坡(4)/台地(5)仍按坡度判断。
	if is_blocked_mountain_tile(a.x, a.y) or is_blocked_mountain_tile(b.x, b.y):
		return true
	# 台地边缘不能和平地/水面直接相邻通过，必须经过缓坡。
	if is_plateau_transition_blocked(a, b):
		return true
	var run: float = Vector2(float(b.x - a.x), float(b.y - a.y)).length()
	if run < 0.001:
		return false
	return RTSConfig.is_cliff_slope(get_height_at_grid(b.x, b.y) - get_height_at_grid(a.x, a.y), run)

func set_rally_mode(active: bool):
	rally_mode = active
	var hud = $UI
	if hud and hud.has_method("update_rally_button_style"):
		hud.update_rally_button_style(active)

func execute_rally(target_pos: Vector3):
	if not entities: return
	for e in entities.get_children():
		if e is Army and e.team == get_host_team() and e.health > 0:
			if e.entity_id != 10 and e.entity_id != 14:
				e.move_to(target_pos)

# ---- 命令卡热键方法 (单机) ----
func clear_orders_for_selected():
	for e in selection.selected_entities:
		if is_instance_valid(e) and e is Army:
			e.current_target = null
			e.current_order = ""
			e._clear_command_queue()
			if e.has_method("cancel_combat_orders"):
				e.cancel_combat_orders()
			if e.has_method("_ungarrison_official"): e._ungarrison_official()

func toggle_attack_move_for_selected():
	for e in selection.selected_entities:
		if is_instance_valid(e) and e is Army:
			if e.has_method("set_combat_advance_enabled"):
				e.set_combat_advance_enabled(not e.is_attack_moving)
			else:
				e.is_attack_moving = not e.is_attack_moving

func garrison_nearest_for_selected():
	_ensure_cache_fresh()
	var avg = _get_selected_avg_pos()
	var best_dist = 30.0 * 30.0; var best_target: GameEntity = null
	for entity in _all_entities:
		if entity.team != get_host_team(): continue
		var ok = (entity is Building and entity.entity_id in [20,21,22,23,24,25,26,29,41,42,52,53,54]) or (entity is Army and entity.entity_id in [9,18])
		if not ok: continue
		var d = entity.global_position.distance_squared_to(avg)
		if d < best_dist: best_dist = d; best_target = entity
	if best_target:
		for e in selection.selected_entities:
			if is_instance_valid(e) and e is Army:
				if e.entity_id >= 46 and e.entity_id <= 50 and best_target is Building:
					# 官员走统一进驻入口，避免多个同类型官员抢同一栋建筑
					e.command_garrison(best_target)
				else:
					e.set("_garrison_target_id", best_target.get_instance_id())
					e.move_to(best_target.global_position)

func global_attack():
	var castle = get_enemy_castle_pos()
	if castle == Vector3.ZERO: return
	for e in selection.selected_entities:
		# 全局进攻只调度战斗单位；农民/商队/官员留在原地继续干活，
		# 不能被“全选+进攻”顺手拉去敌方主城。
		if is_instance_valid(e) and e is Army and e.target_type > 0:
			e.attack_move_to(castle)

func global_retreat():
	var castle = get_host_castle_pos()
	if castle == Vector3.ZERO: return
	for e in selection.selected_entities:
		if is_instance_valid(e) and e is Army: e.move_to(castle)

func global_attack_selected(): global_attack()
func global_retreat_selected(): global_retreat()

func get_enemy_castle_pos() -> Vector3:
	for e in _all_entities:
		if e is Building and e.entity_id == 20 and e.team != get_host_team(): return e.global_position
	return Vector3.ZERO

func get_host_castle_pos() -> Vector3:
	for e in _all_entities:
		if e is Building and e.entity_id == 20 and e.team == get_host_team(): return e.global_position
	return Vector3.ZERO

func ungarrison_selected():
	for e in selection.selected_entities:
		if is_instance_valid(e) and e is Army and e.has_method("_exit_soldier_garrison"):
			e._exit_soldier_garrison()
		if is_instance_valid(e) and e is Building and e.has_method("release_all_garrisoned"):
			e.release_all_garrisoned()

func toggle_patrol_mode():
	print("[RTS] patrol mode stub")

func produce_unit(building: Building, unit_id: int):
	building.try_produce(unit_id)

func upgrade_building(b: Building):
	if b.has_method("start_upgrade"): b.start_upgrade()

# 修理残破建筑（单机/主机路径）。规则与扣费都在 Building 内实现，
# 这里负责先找农民、再登记工程；联机时同名逻辑走 OnlineBattleManager 的 repair 命令。
func repair_building(b: Building) -> bool:
	if b == null or not is_instance_valid(b) or not (b is Building):
		return false
	if not b.has_method("begin_repair"):
		return false
	return request_repair(b, [])

# ==================== 建造/修理派工 ====================
func _same_owner(a, b) -> bool:
	if a == null or b == null or not is_instance_valid(a) or not is_instance_valid(b):
		return false
	if a.team != b.team:
		return false
	var ao: int = int(a.owner_peer_id)
	var bo: int = int(b.owner_peer_id)
	if ao == -1 or bo == -1:
		return true
	return ao == bo

func _is_available_builder(a) -> bool:
	if a == null or not is_instance_valid(a) or not (a is Army):
		return false
	if a.entity_id != 10 or a.health <= 0 or not a.can_move:
		return false
	if int(a._work_target_id) != -1 or String(a.current_order) == "build":
		return false
	# 空闲农民优先；没有空闲的再临时抽调采集中（哪怕背着货）的农民，
	# 否则开局三个农民一直在采集，玩家放下民房会永远等不到人。
	return String(a.current_order) in ["", "idle", "gather"]

func find_nearest_idle_builder(team: int, owner_id: int, from_pos: Vector3, max_dist: float = BUILDER_SEARCH_RADIUS):
	_ensure_cache_fresh()
	var best = null
	var best_d: float = max_dist * max_dist
	var best_priority: int = 99
	for a in _armies:
		if a == null or not is_instance_valid(a) or a.health <= 0:
			continue
		if a.team != team:
			continue
		if owner_id != -1 and int(a.owner_peer_id) != -1 and int(a.owner_peer_id) != owner_id:
			continue
		if not _is_available_builder(a):
			continue
		var d: float = from_pos.distance_squared_to(a.global_position)
		if d > max_dist * max_dist:
			continue
		# 空闲农民优先；没有空闲的才抽调采集中（哪怕背着货）的农民。
		var priority: int = 0 if String(a.current_order) in ["", "idle"] else 1
		if priority < best_priority or (priority == best_priority and d < best_d):
			best_priority = priority
			best_d = d
			best = a
	return best

func _resolve_entity_by_id(eid: int):
	_ensure_cache_fresh()
	return _entity_lookup.get(eid, null)

# 返回实际登记的农民数（0~3）。builder_ids 为空时自动找最近的农民。
func assign_builders(b: Building, builder_ids: Array = []) -> int:
	if b == null or not is_instance_valid(b) or not (b is Building) or b.health <= 0:
		return 0
	var count: int = 0
	if builder_ids.is_empty():
		var u = find_nearest_idle_builder(b.team, b.owner_peer_id, b.global_position)
		if u != null and u.work_on_building(b):
			count += 1
		return count
	for eid in builder_ids:
		var u = _resolve_entity_by_id(int(eid))
		if u == null or not (u is Army):
			continue
		if not _same_owner(u, b):
			continue
		if u.work_on_building(b):
			count += 1
	return count

# ==================== 智能军需官 ====================
# 玩家开启后由服务端/主机自动执行三类工作：
# 1) 农民不足 15 人时自动补农民；
# 2) 按各资源储量/仓容缺口分配和重分配农民；
# 3) 仓容接近上限时，在资源点附近自动补一座仓库。
func set_local_quartermaster(enabled: bool) -> void:
	if local_quartermaster == enabled:
		return
	local_quartermaster = enabled
	_quartermaster_timer = 0.0
	if enabled:
		_qm_adopt_existing_workers()

# 开启时接管当前正在采集的农民，像 AI 一样从现有分布开始调度；
# 之后玩家手动改派目标会清除接管标记，军需官不会再抢回来。
func _qm_adopt_existing_workers() -> void:
	_ensure_cache_fresh()
	for owner_id in _quartermaster_owner_ids():
		var oid: int = int(owner_id)
		var team: int = _quartermaster_team_for(oid)
		if team < 0 or not is_quartermaster_enabled_for(oid, team):
			continue
		for u in _qm_peasants(oid, team):
			var rt: String = _qm_current_resource_type(u)
			if rt != "":
				_qm_mark_managed(u, rt)

# 单机/主机默认只管本地玩家；OnlineBattleManager 会覆盖成每个真人玩家。
func _quartermaster_owner_ids() -> Array:
	return [get_local_owner_id()]

func _quartermaster_team_for(owner_id: int) -> int:
	if owner_id == player_owner_id:
		return get_host_team()
	return int(ai_players.get(owner_id, {}).get("team", -1))

func is_quartermaster_enabled_for(owner_id: int, team: int) -> bool:
	return local_quartermaster and is_local_player_owned(owner_id, team)

func _tick_quartermaster(delta: float) -> void:
	var any_enabled := false
	for owner_id in _quartermaster_owner_ids():
		if is_quartermaster_enabled_for(int(owner_id), _quartermaster_team_for(int(owner_id))):
			any_enabled = true
			break
	if not any_enabled:
		return
	_quartermaster_timer -= delta
	if _quartermaster_timer > 0.0:
		return
	_quartermaster_timer = QUARTERMASTER_INTERVAL
	for owner_id in _quartermaster_owner_ids():
		var oid: int = int(owner_id)
		var team: int = _quartermaster_team_for(oid)
		if team < 0 or not is_quartermaster_enabled_for(oid, team):
			continue
		_run_quartermaster(oid, team)

func _run_quartermaster(owner_id: int, team: int) -> void:
	_ensure_cache_fresh()
	var peasants: Array = _qm_peasants(owner_id, team)
	# 仿照 AI 的经济循环：农民不足时先补农民，再把闲置/富余农民按资源缺口重新分配。
	_qm_train_peasants(owner_id, team, peasants)
	if peasants.is_empty():
		return
	_qm_assign_idle(owner_id, team, peasants)
	_qm_rebalance_workers(owner_id, team, peasants)
	_qm_maybe_build_warehouse(owner_id, team, peasants)

func _qm_train_peasants(owner_id: int, team: int, peasants: Array) -> void:
	if peasants.size() >= QUARTERMASTER_PEASANT_TARGET:
		return
	var queued: int = _qm_queued_peasants(owner_id, team)
	if peasants.size() + queued >= QUARTERMASTER_PEASANT_TARGET:
		return
	var pop: Dictionary = _qm_population(owner_id, team)
	if int(pop.get("current", 0)) + queued >= int(pop.get("max", 0)):
		return
	if owner_id >= 0 and has_method("can_player_train"):
		if not can_player_train(owner_id):
			return
	elif not can_train_unit(team):
		return
	for b in _buildings:
		if b == null or not is_instance_valid(b) or not (b is Building):
			continue
		if int(b.entity_id) <= 0 or int(b.team) != team or b.health <= 0 or b.build_timer > 0.0:
			continue
		if not _qm_owner_matches(b, owner_id):
			continue
		if b.try_produce(10):
			return

func _qm_queued_peasants(owner_id: int, team: int) -> int:
	var total := 0
	for b in _buildings:
		if b == null or not is_instance_valid(b) or not (b is Building):
			continue
		if int(b.team) != team or not _qm_owner_matches(b, owner_id):
			continue
		for id in b.production_queue:
			if int(id) == 10:
				total += 1
	return total

func _qm_population(owner_id: int, team: int) -> Dictionary:
	var online_pop = get("player_population")
	if online_pop is Dictionary and online_pop.has(owner_id):
		return online_pop[owner_id]
	if owner_id < 0:
		if team == get_host_team():
			return {"current": player_pop, "max": player_max_pop}
		return {"current": enemy_pop, "max": enemy_max_pop}
	if has_method("get_population_for"):
		var pop = get_population_for(owner_id)
		if pop is Dictionary and not pop.is_empty():
			return pop
	if team == get_host_team():
		return {"current": player_pop, "max": player_max_pop}
	return {"current": enemy_pop, "max": enemy_max_pop}

func _qm_owner_matches(entity, owner_id: int) -> bool:
	if owner_id < 0:
		return true
	var eo: int = int(entity.owner_peer_id)
	return eo == owner_id or eo == -1

func _qm_peasants(owner_id: int, team: int) -> Array:
	var out: Array = []
	for e in _armies:
		if e == null or not is_instance_valid(e) or not (e is Army):
			continue
		if e.health <= 0 or int(e.entity_id) != 10 or int(e.team) != team:
			continue
		if not _qm_owner_matches(e, owner_id):
			continue
		out.append(e)
	return out

func _qm_resources(owner_id: int, team: int) -> Dictionary:
	if owner_id >= 0:
		var r = get_resources_for(owner_id)
		if r != null and not r.is_empty():
			return r
	return get_team_resources(team)

func _qm_limits(owner_id: int, team: int) -> Dictionary:
	if has_method("get_limits_for"):
		var lim = get_limits_for(owner_id)
		if lim != null and not lim.is_empty():
			return lim
	return get_team_resource_limits(team) if team >= 0 else {}

func _qm_assign_idle(owner_id: int, team: int, peasants: Array) -> void:
	var res: Dictionary = _qm_resources(owner_id, team)
	var lim: Dictionary = _qm_limits(owner_id, team)
	if res.is_empty() or lim.is_empty():
		return
	var desired: Dictionary = _qm_desired_counts(peasants.size(), res, lim)
	var counts := {}
	for rt in desired.keys():
		counts[rt] = 0
	var idle: Array = []
	for u in peasants:
		var order := String(u.current_order)
		if order == "gather":
			var rt: String = _qm_current_resource_type(u)
			if rt != "" and counts.has(rt):
				counts[rt] = int(counts[rt]) + 1
			elif rt == "":
				# 资源采空/目标不可达时 Army 不再自动找新矿，交给军需官重新分配。
				idle.append(u)
		elif order in ["", "idle", "deliver"] and not u._has_cargo():
			idle.append(u)
	if idle.is_empty():
		return
	var castle = _qm_castle(owner_id, team)
	var castle_pos: Vector3 = castle.global_position if castle != null else Vector3.ZERO
	for u in idle:
		var pick := ""
		var best_gap: float = 0.0
		var best_fill: float = 9.0
		for rt in desired.keys():
			var gap: float = float(desired[rt]) - float(counts.get(rt, 0))
			if gap <= 0.0:
				continue
			var cap: float = maxf(float(lim.get(rt, 1)), 1.0)
			var fill: float = float(res.get(rt, 0)) / cap
			if gap > best_gap or (is_equal_approx(gap, best_gap) and fill < best_fill):
				best_gap = gap
				best_fill = fill
				pick = rt
		if pick == "":
			break
		var node = get_nearest_resource(u.global_position, 80.0, [pick])
		if node == null and castle != null:
			node = get_nearest_resource(castle_pos, 140.0, [pick])
		if node == null:
			desired[pick] = 0.0
			continue
		u.gather_at(node)
		_qm_mark_managed(u, pick)
		counts[pick] = int(counts.get(pick, 0)) + 1

func _qm_desired_counts(total: int, res: Dictionary, lim: Dictionary) -> Dictionary:
	# 与 AI 的分配思路一致：先看各资源当前填充率，再乘经济权重；
	# 越接近满仓的资源分到的农民越少，缺口大的资源优先补人。
	var target_total: int = maxi(total, QUARTERMASTER_PEASANT_TARGET)
	var weights: Dictionary
	if total < 8:
		weights = {"food": 5.0, "wood": 1.6, "gold": 0.6, "stone": 0.8}
	else:
		weights = {"food": 1.5, "wood": 3.0, "gold": 1.0, "stone": 2.0}
	var scored := {}
	var total_score := 0.0
	for rt in weights.keys():
		var cap: float = maxf(float(lim.get(rt, 1)), 1.0)
		var pct: float = float(res.get(rt, 0)) / cap
		var scarcity := 0.0
		if pct < 0.9:
			scarcity = maxf(0.05, 1.0 - pct)
		scored[rt] = scarcity * float(weights[rt])
		total_score += float(scored[rt])
	var out := {}
	for rt in scored.keys():
		out[rt] = 0.0
	if total_score <= 0.0:
		return out
	for rt in scored.keys():
		out[rt] = float(scored[rt]) / total_score * float(target_total)
	return out

func _qm_current_resource_type(u) -> String:
	if u == null or not is_instance_valid(u):
		return ""
	if String(u.current_order) != "gather":
		return ""
	var target = u.current_target
	if not is_instance_valid(target) or not (target is WorldResource) or target.health <= 0:
		return ""
	if u.has_method("_is_target_marked_unreachable") and u._is_target_marked_unreachable(target):
		return ""
	return String(target.resource_type)

func _qm_mark_managed(u, resource_type: String) -> void:
	if u == null or not is_instance_valid(u):
		return
	u.set_meta("qm_managed", true)
	u.set_meta("qm_res_type", resource_type)

func _qm_clear_managed(u) -> void:
	if u == null or not is_instance_valid(u):
		return
	if u.has_meta("qm_managed"):
		u.remove_meta("qm_managed")
	if u.has_meta("qm_res_type"):
		u.remove_meta("qm_res_type")

func _qm_managed_type(u) -> String:
	var rt: String = _qm_current_resource_type(u)
	if rt == "" or not u.has_meta("qm_managed"):
		return ""
	if u.has_meta("qm_res_type") and String(u.get_meta("qm_res_type")) != rt:
		_qm_clear_managed(u)
		return ""
	return rt

func _qm_rebalance_workers(owner_id: int, team: int, peasants: Array) -> void:
	if game_time - float(_qm_last_rebalance.get(owner_id, -999.0)) < QUARTERMASTER_REBALANCE_INTERVAL:
		return
	_qm_last_rebalance[owner_id] = game_time
	var res: Dictionary = _qm_resources(owner_id, team)
	var lim: Dictionary = _qm_limits(owner_id, team)
	if res.is_empty() or lim.is_empty():
		return
	var desired: Dictionary = _qm_desired_counts(peasants.size(), res, lim)
	var counts := {}
	var managed := {}
	for rt in desired.keys():
		counts[rt] = 0
		managed[rt] = 0
	for u in peasants:
		var rt: String = _qm_current_resource_type(u)
		if rt == "":
			continue
		if counts.has(rt):
			counts[rt] = int(counts[rt]) + 1
		if _qm_managed_type(u) != "" and managed.has(rt):
			managed[rt] = int(managed[rt]) + 1
	var from_rt := ""
	var from_surplus := 0.0
	var to_rt := ""
	var to_deficit := 0.0
	for rt in desired.keys():
		var gap: float = float(desired[rt]) - float(counts.get(rt, 0))
		if gap < -1.0 and -gap > from_surplus and int(managed.get(rt, 0)) > 0:
			from_surplus = -gap
			from_rt = rt
		elif gap > 1.0 and gap > to_deficit:
			to_deficit = gap
			to_rt = rt
	if from_rt == "" or to_rt == "":
		return
	# 只重分配军需官自己派出去的农民；玩家手动安排的农民不动。
	for u in peasants:
		if _qm_managed_type(u) != from_rt:
			continue
		var node = get_nearest_resource(u.global_position, 110.0, [to_rt])
		if node == null:
			return
		u.gather_at(node)
		_qm_mark_managed(u, to_rt)
		return

func _qm_castle(owner_id: int, team: int):
	for b in _buildings:
		if b == null or not is_instance_valid(b) or not (b is Building):
			continue
		if int(b.entity_id) != 20 or int(b.team) != team or b.health <= 0:
			continue
		if _qm_owner_matches(b, owner_id):
			return b
	return get_castle_by_team(team)

func _qm_warehouse_cap(peasant_count: int) -> int:
	return clampi(peasant_count / 3, 1, QUARTERMASTER_MAX_WAREHOUSES)

func _qm_maybe_build_warehouse(owner_id: int, team: int, peasants: Array) -> void:
	if game_time - float(_qm_last_warehouse_time.get(owner_id, -999.0)) < 25.0:
		return
	var owned := 0
	var under := 0
	for b in _buildings:
		if b == null or not is_instance_valid(b) or not (b is Building):
			continue
		if int(b.entity_id) != QUARTERMASTER_WAREHOUSE_ID or int(b.team) != team:
			continue
		if b.health <= 0 or not _qm_owner_matches(b, owner_id):
			continue
		if b.build_timer > 0.0:
			under += 1
		else:
			owned += 1
	if under > 0 or owned + under >= _qm_warehouse_cap(peasants.size()):
		return
	var res: Dictionary = _qm_resources(owner_id, team)
	var lim: Dictionary = _qm_limits(owner_id, team)
	if res.is_empty() or lim.is_empty():
		return
	var pressure := false
	for rt in ["food", "wood", "gold", "stone"]:
		var cap: float = maxf(float(lim.get(rt, 1)), 1.0)
		if float(res.get(rt, 0)) >= cap * QUARTERMASTER_STORAGE_TRIGGER:
			pressure = true
			break
	# 开局资源还没用掉时不急着造；没有仓库且已经打了一会儿，补第一座。
	if not pressure and owned == 0 and game_time > 25.0:
		pressure = true
	if not pressure:
		return
	var castle = _qm_castle(owner_id, team)
	var center: Vector3 = castle.global_position if castle != null else Vector3.ZERO
	var cluster: Vector3 = _qm_pick_resource_cluster(owner_id, team, res, lim, center)
	var pos: Vector3 = _qm_find_warehouse_spot(cluster, team)
	if not pos.is_finite():
		pos = _qm_find_warehouse_spot(center, team)
	if not pos.is_finite():
		return
	# 至少有一个农民能去施工，否则只拍地基没有意义。
	if find_nearest_idle_builder(team, owner_id, center, 70.0) == null:
		return
	var cfg = EntityDatabase.get_config(QUARTERMASTER_WAREHOUSE_ID)
	if cfg.is_empty():
		return
	var cost: Dictionary = cfg.get("cost", {})
	if not _qm_deduct(owner_id, team, cost):
		return
	cfg["owner_peer_id"] = owner_id
	var b = spawn_entity(cfg, team, pos, 1) as Building
	if b == null:
		_qm_refund(owner_id, team, cost)
		return
	b.start_construction(5.0, cfg)
	request_construction(b)
	_qm_last_warehouse_time[owner_id] = game_time
	var builder = find_nearest_idle_builder(team, owner_id, pos, 70.0)
	if builder != null:
		assign_builders(b, [builder.get_instance_id()])

func _qm_deduct(owner_id: int, team: int, cost: Dictionary) -> bool:
	# 单机 1v1 的玩家 owner_id 可能是 -1（表示按队伍共用一个资源池），
	# 此时不能走 get_resources_for(-1)，那会扣到敌方资源上。
	if owner_id >= 0:
		return deduct_resources_for(owner_id, cost)
	var res: Dictionary = get_team_resources(team)
	for k in cost:
		if int(res.get(k, 0)) < int(cost[k]):
			return false
	for k in cost:
		res[k] = int(res.get(k, 0)) - int(cost[k])
	return true

func _qm_refund(owner_id: int, team: int, cost: Dictionary) -> void:
	for k in cost:
		if owner_id >= 0:
			add_resource_for(owner_id, k, int(cost[k]))
		else:
			add_resource(k, int(cost[k]), team)

func _qm_pick_resource_cluster(owner_id: int, team: int, res: Dictionary, lim: Dictionary, center: Vector3) -> Vector3:
	var best: Vector3 = center
	var best_score: float = -INF
	for node in _resources:
		if node == null or not is_instance_valid(node) or not (node is WorldResource) or node.health <= 0:
			continue
		var rt: String = String(node.resource_type)
		if not rt in ["food", "wood", "gold", "stone"]:
			continue
		var d: float = center.distance_to(node.global_position)
		if d > 90.0:
			continue
		var covered := false
		for b in _buildings:
			if b == null or not is_instance_valid(b) or not (b is Building):
				continue
			if int(b.entity_id) == QUARTERMASTER_WAREHOUSE_ID and int(b.team) == team and _qm_owner_matches(b, owner_id):
				if b.global_position.distance_to(node.global_position) < QUARTERMASTER_WAREHOUSE_GAP:
					covered = true
					break
		if covered:
			continue
		var cap: float = maxf(float(lim.get(rt, 1)), 1.0)
		var ratio: float = float(res.get(rt, 0)) / cap
		var score: float = (1.0 - ratio) * 3.0 - d / 60.0
		if score > best_score:
			best_score = score
			best = node.global_position
	return best

func _qm_find_warehouse_spot(center: Vector3, team: int) -> Vector3:
	if center == Vector3.ZERO:
		return Vector3.INF
	for radius in [5.0, 6.5, 8.0, 10.0, 12.0, 15.0, 18.0]:
		for i in range(16):
			var ang: float = TAU * float(i) / 16.0
			var pos := center + Vector3(cos(ang) * radius, 0.0, sin(ang) * radius)
			if _is_valid_build_position(pos, QUARTERMASTER_WAREHOUSE_ID, team):
				return pos
	return Vector3.INF

# ==================== 智能军队官 ====================
# 与军需官同一套结构：玩家在设置面板打开开关并给兵种设"保底数量"，
# 军队官每隔 ARMY_OFFICER_INTERVAL 秒查一次自己的生产建筑，
# 某种兵（存活 + 排队）少于保底数量就补一个，人口满或资源不够时自然跳过。
func set_local_army_officer(enabled: bool) -> void:
	if local_army_officer == enabled:
		return
	local_army_officer = enabled
	_army_officer_timer = 0.0

func set_army_officer_thresholds(th: Dictionary) -> void:
	army_officer_thresholds.clear()
	for k in th.keys():
		army_officer_thresholds[int(k)] = clampi(int(th[k]), 0, GameSettings.ARMY_OFFICER_THRESHOLD_MAX)
	_army_officer_timer = 0.0

func get_army_officer_thresholds_for(_owner_id: int, _team: int = -1) -> Dictionary:
	return army_officer_thresholds

func is_army_officer_enabled_for(owner_id: int, team: int) -> bool:
	return local_army_officer and is_local_player_owned(owner_id, team)

# 单机/主机默认只管本地玩家；OnlineBattleManager 覆盖成每个真人玩家。
func _army_officer_owner_ids() -> Array:
	return [get_local_owner_id()]

func _tick_army_officer(delta: float) -> void:
	var any_enabled := false
	for owner_id in _army_officer_owner_ids():
		if is_army_officer_enabled_for(int(owner_id), _quartermaster_team_for(int(owner_id))):
			any_enabled = true
			break
	if not any_enabled:
		return
	_army_officer_timer -= delta
	if _army_officer_timer > 0.0:
		return
	_army_officer_timer = ARMY_OFFICER_INTERVAL
	for owner_id in _army_officer_owner_ids():
		var oid: int = int(owner_id)
		var team: int = _quartermaster_team_for(oid)
		if team < 0 or not is_army_officer_enabled_for(oid, team):
			continue
		_run_army_officer(oid, team)

# 设置面板用：返回"自己的建筑真的能造"的战斗兵种，用来生成阈值行。
# owner_id 传 -99999 表示当前本地玩家。
func army_officer_candidates(owner_id: int = -99999) -> Array:
	var oid: int = int(owner_id)
	if oid == -99999:
		oid = get_local_owner_id()
	var team: int = _quartermaster_team_for(oid)
	if team < 0:
		return []
	_ensure_cache_fresh()
	var out: Array = []
	for b in _buildings:
		if b == null or not is_instance_valid(b) or not (b is Building):
			continue
		if int(b.team) != team or not _qm_owner_matches(b, oid):
			continue
		if b.health <= 0:
			continue
		for prod in b.production_list:
			var uid: int = int(prod.get("unit_id", -1))
			if uid <= 0 or out.has(uid) or not _ao_is_combat_unit(uid):
				continue
			out.append(uid)
	out.sort()
	return out

# 农民/商队/运输船/官员不归军队官管：农民由军需官补，商队和官员是玩家手动决策
func _ao_is_combat_unit(unit_id: int) -> bool:
	if unit_id in [5, 6, 9, 10, 14, 43, 44, 45, 51, 46, 47, 48, 49, 50]:
		return false
	return true

# 推荐阈值：只给"现在真的能造"的兵种填，避免设置一堆造不出来的兵种
func _default_army_officer_thresholds(owner_id: int) -> Dictionary:
	var out := {}
	for uid in army_officer_candidates(owner_id):
		var v: int = int(GameSettings.ARMY_OFFICER_RECOMMENDED.get(int(uid), 0))
		if v > 0:
			out[int(uid)] = v
	return out

# 默认写进本地玩家状态；OnlineBattleManager 覆盖成按队/按玩家存
func _apply_army_officer_thresholds(_owner_id: int, _team: int, th: Dictionary) -> void:
	set_army_officer_thresholds(th)
	GameSettings.army_officer_thresholds = th.duplicate()

func _run_army_officer(owner_id: int, team: int) -> void:
	var thresholds: Dictionary = get_army_officer_thresholds_for(owner_id, team)
	if thresholds.is_empty():
		# 刚开局就开开关时还没有能造的战斗兵种：等建筑造好后自动补上推荐值
		var def := _default_army_officer_thresholds(owner_id)
		if def.is_empty():
			return
		_apply_army_officer_thresholds(owner_id, team, def)
		thresholds = get_army_officer_thresholds_for(owner_id, team)
	_ensure_cache_fresh()
	var pop: Dictionary = _qm_population(owner_id, team)
	var pop_current: int = int(pop.get("current", 0))
	var pop_max: int = int(pop.get("max", 0))
	# 现存 + 排队一起算，否则会在排队还没落地时重复补兵
	var counts := {}
	for b in _buildings:
		if b == null or not is_instance_valid(b) or not (b is Building):
			continue
		if int(b.team) != team or not _qm_owner_matches(b, owner_id):
			continue
		for id in b.production_queue:
			var qid: int = int(id)
			counts[qid] = int(counts.get(qid, 0)) + 1
	for e in _armies:
		if e == null or not is_instance_valid(e) or not (e is Army) or e.health <= 0:
			continue
		if int(e.team) != team or not _qm_owner_matches(e, owner_id):
			continue
		var eid: int = int(e.entity_id)
		counts[eid] = int(counts.get(eid, 0)) + 1
	var placed := 0
	for b in _buildings:
		if placed >= ARMY_OFFICER_MAX_PER_TICK or pop_current >= pop_max:
			return
		if b == null or not is_instance_valid(b) or not (b is Building):
			continue
		if int(b.team) != team or not _qm_owner_matches(b, owner_id):
			continue
		if b.health <= 0 or b.build_timer > 0.0:
			continue
		for prod in b.production_list:
			if placed >= ARMY_OFFICER_MAX_PER_TICK or pop_current >= pop_max:
				return
			var uid: int = int(prod.get("unit_id", -1))
			if uid <= 0 or not _ao_is_combat_unit(uid):
				continue
			var target: int = int(thresholds.get(uid, 0))
			if target <= 0 or int(counts.get(uid, 0)) >= target:
				continue
			if not b.try_produce(uid):
				continue
			counts[uid] = int(counts.get(uid, 0)) + 1
			pop_current += 1
			placed += 1

# 工地/修理点没人时自动补派最近的农民（玩家和 AI 共用）
func _tick_builder_dispatch(delta: float) -> void:
	_builder_dispatch_timer -= delta
	if _builder_dispatch_timer > 0.0:
		return
	_builder_dispatch_timer = BUILDER_DISPATCH_INTERVAL
	_ensure_cache_fresh()
	for b in _buildings:
		if b == null or not is_instance_valid(b) or b.health <= 0:
			continue
		var needs_worker: bool = b.build_timer > 0.0 or b.repair_pending or b.repair_timer > 0.0
		if not needs_worker:
			continue
		if b.builder_count() > 0:
			continue
		var u = find_nearest_idle_builder(b.team, b.owner_peer_id, b.global_position)
		if u != null:
			u.work_on_building(b)

# 放置建筑后调用：开始建造并自动派最近农民
func request_construction(b: Building, builder_ids: Array = []) -> int:
	if b == null or not is_instance_valid(b) or not (b is Building):
		return 0
	if b.build_timer <= 0.0:
		return 0
	b.awaiting_builder = true
	return assign_builders(b, builder_ids)

func _refund_building_cost(b: Building, cost: Dictionary) -> void:
	if cost.is_empty():
		return
	if b.owner_peer_id != -1 and has_method("add_resource_for"):
		for k in cost:
			add_resource_for(b.owner_peer_id, k, int(cost[k]))
	else:
		var res := get_team_resources(b.team)
		for k in cost:
			if res.has(k):
				res[k] = min(int(res[k]) + int(cost[k]), int(get_team_resource_limits(b.team).get(k, 99999)))

# 先扣费再登记修理；没有可用农民时不扣费。
func request_repair(b: Building, builder_ids: Array = []) -> bool:
	if b == null or not is_instance_valid(b) or not (b is Building):
		return false
	if not b.has_method("begin_repair") or not b.can_repair():
		return false
	var candidates: Array = []
	if builder_ids.is_empty():
		var u = find_nearest_idle_builder(b.team, b.owner_peer_id, b.global_position)
		if u != null:
			candidates.append(u)
	else:
		for eid in builder_ids:
			var u = _resolve_entity_by_id(int(eid))
			if u != null and (u is Army) and _same_owner(u, b):
				candidates.append(u)
	if candidates.is_empty():
		return false
	var cost: Dictionary = b.repair_cost()
	if not b.begin_repair(self):
		return false
	var assigned: int = 0
	for u in candidates:
		if u.work_on_building(b):
			assigned += 1
	if assigned == 0:
		# 登记失败（例如已经有 3 个农民）时把已扣的修理费退回
		_refund_building_cost(b, cost)
		b.repair_pending = false
		b.max_repair_time = 0.0
		if b.has_method("cancel_repair_visual"):
			b.cancel_repair_visual()
		return false
	return true

# 开工前（进度还是 0）允许取消并全额退款；已经动工则不允许。
func cancel_construction(b: Building) -> bool:
	if b == null or not is_instance_valid(b) or not (b is Building):
		return false
	if b.build_timer <= 0.0 or b.entity_id in [20, 53]:
		return false
	var total: float = maxf(b.max_build_time, 0.001)
	var progress: float = clampf(1.0 - b.build_timer / total, 0.0, 1.0)
	if progress > 0.001:
		return false
	var cost: Dictionary = b.building_data.get("cost", {}) if b.building_data is Dictionary else {}
	_refund_building_cost(b, cost)
	b.build_timer = 0.0
	b.awaiting_builder = false
	if b.has_method("_release_builders"):
		b._release_builders()
	if b.has_method("die"):
		b.health = 0
		b.queue_free()
	return true

# 给 UI 用：能不能修（含资源是否够），不动状态
func can_repair_building(b: Building) -> bool:
	if b == null or not is_instance_valid(b) or not (b is Building):
		return false
	if not b.has_method("can_repair") or not b.can_repair():
		return false
	# 没有可派出的农民时不能点修理（避免先扣费再失败）
	if find_nearest_idle_builder(b.team, b.owner_peer_id, b.global_position) == null:
		return false
	var cost: Dictionary = b.repair_cost() if b.has_method("repair_cost") else {}
	if cost.is_empty():
		return true
	var res: Dictionary = get_resources_for(b.owner_peer_id) if b.owner_peer_id != -1 else get_team_resources(b.team)
	for k in cost:
		if int(res.get(k, 0)) < int(cost[k]):
			return false
	return true



func release_garrisoned(b: Building):
	if b.has_method("release_all_garrisoned"): b.release_all_garrisoned()

func enter_build_mode(building_id: int):
	_on_building_selected_for_build(building_id)

func can_afford_building(build_id: int, team: int) -> bool:
	var cfg = EntityDatabase.get_config(build_id)
	if cfg.is_empty(): return false
	var cost = cfg.get("cost", {})
	if cost.is_empty(): return true
	var res = get_team_resources(team)
	for k in cost:
		if res.get(k, 0) < cost[k]: return false
	return true

func _get_selected_avg_pos() -> Vector3:
	var p = Vector3.ZERO; var c = 0
	for e in selection.selected_entities:
		if is_instance_valid(e): p += e.global_position; c += 1
	return p / c if c > 0 else Vector3.ZERO

func _update_command_card_sp():
	var cc = $UI.get_node_or_null("CommandCard")
	if not cc or not cc.visible: return
	if selection.selected_entities.size() == 1:
		var e = selection.selected_entities[0]
		# 队友/敌方建筑或军队只可查看：不显示生产/升级/拆除/指挥按钮
		if not selection._is_local_owned(e):
			cc.hide_all()
			return
		if is_instance_valid(e) and e is Building:
			cc.show_building(e.production_list, e.get_instance_id(), e.entity_id, self)
		elif is_instance_valid(e) and e is Army:
			cc.show_army()
		else:
			cc.hide_all()
	elif selection.selected_entities.is_empty():
		var clv = 1
		for e in _buildings: if e.entity_id==20 and e.team==get_host_team(): clv = e.level; break
		cc.show_construct(get_host_resources(), clv, self)
	else:
		cc.hide_all()

# ==================== 科研模式（服务端权威） ====================
# 状态按“玩家”保存：1v1 无 owner 时用 team，2v2/3v3/FFA 用 owner_peer_id。
# 客户端 ClientRenderer 只镜像快照；所有开始/取消/完成都在这里校验和结算。
var research_states: Dictionary = {}
var _research_tax_timer: float = 0.0
# 智能科研官检查间隔：避免每帧扫描全部科技；0.8 秒足够在完成研究后立刻接下一项。
const RESEARCH_AUTO_INTERVAL: float = 0.8
var _research_auto_timer: float = 0.0

func is_research_mode() -> bool:
	return GameSettings.progression_mode == GameSettings.ProgressionMode.RESEARCH

func research_key(owner_peer_id: int, team: int) -> int:
	if owner_peer_id >= 0:
		return owner_peer_id
	# 无 owner 的队伍级科研状态必须用负键：1v1 里玩家 owner=1，
	# 若再用 team(0/1) 当键，会和玩家状态撞在一起（敌方 AI 的科技/时代会覆盖玩家）。
	return -1000 - team

func research_team(owner_peer_id: int, team: int) -> int:
	if team >= 0:
		return team
	if owner_peer_id >= 0:
		var t := get_team_of_owner(owner_peer_id)
		if t >= 0:
			return t
	return get_host_team()

func research_nation(owner_peer_id: int, team: int) -> int:
	if owner_peer_id >= 0:
		var n := get_nation_of_owner(owner_peer_id)
		if n >= 0:
			return n
		if owner_peer_id == player_owner_id:
			return int(team_nations.get(research_team(owner_peer_id, team), -1))
	return int(team_nations.get(research_team(owner_peer_id, team), -1))

func _new_research_state(owner_peer_id: int, team: int) -> Dictionary:
	return {
		"age": 0,
		"bits": 0,
		"nation_bits": 0,
		"nation": research_nation(owner_peer_id, team),
		"current": {},
		"mods": {},
		"unlocked_units": {10: true, 11: true},
		"unlocked_buildings": {20: true, 21: true, 22: true, 27: true, 28: true, 41: true, 8: true},
		"tax_pool": 0.0,
		"owner": owner_peer_id,
		"team": team,
		"auto": ResearchAdvisor.default_config(),
	}

func get_research_state(owner_peer_id: int, team: int, create: bool = true) -> Dictionary:
	if not is_research_mode():
		return {}
	var key := research_key(owner_peer_id, team)
	if not research_states.has(key):
		if not create:
			return {}
		research_states[key] = _new_research_state(owner_peer_id, team)
		research_states[key]["_key"] = key
		_refresh_research_derived(research_states[key])
	elif int(research_states[key].get("nation", -1)) < 0:
		_refresh_research_derived(research_states[key])
	if not research_states[key].has("auto"):
		research_states[key]["auto"] = ResearchAdvisor.default_config()
	return research_states[key]

func get_research_state_for_entity(e) -> Dictionary:
	if e == null or not is_instance_valid(e):
		return {}
	return get_research_state(int(e.owner_peer_id), int(e.team))

func get_host_research_state() -> Dictionary:
	if not is_research_mode():
		return {}
	return get_research_state(player_owner_id, get_local_team())

func get_local_research_state() -> Dictionary:
	return get_host_research_state()

func _refresh_research_derived(st: Dictionary) -> void:
	if st.is_empty():
		return
	# 国家可能在状态首次创建之后才确定（联机选国/补 AI 席位），这里惰性同步。
	if int(st.get("nation", -1)) < 0:
		st["nation"] = research_nation(int(st.get("owner", -1)), int(st.get("team", -1)))
	var nation := int(st.get("nation", -1))
	st["mods"] = TechTreeData.collect_mods(int(st.get("bits", 0)), int(st.get("nation_bits", 0)), nation)
	st["unlocked_units"] = TechTreeData.unlocked_units(int(st.get("bits", 0)), int(st.get("nation_bits", 0)), nation)
	st["unlocked_buildings"] = TechTreeData.unlocked_buildings(int(st.get("bits", 0)), int(st.get("nation_bits", 0)), nation)

func research_resources(owner_peer_id: int, team: int) -> Dictionary:
	if owner_peer_id >= 0:
		return get_resources_for(owner_peer_id)
	return get_team_resources(team)

func research_pop(owner_peer_id: int, team: int) -> int:
	if owner_peer_id >= 0:
		return int(get_population_for(owner_peer_id).get("current", 0))
	return player_pop if team == get_host_team() else enemy_pop

func research_can_afford(owner_peer_id: int, team: int, cost: Dictionary) -> bool:
	var res := research_resources(owner_peer_id, team)
	for k in cost:
		if int(res.get(k, 0)) < int(cost[k]):
			return false
	return true

func research_auto_config(owner_peer_id: int, team: int) -> Dictionary:
	var st := get_research_state(owner_peer_id, team)
	if st.is_empty():
		return ResearchAdvisor.default_config()
	return ResearchAdvisor.normalize_config(st.get("auto", {}))

# 玩家设置智能科研官：启用开关、自动升时代开关、分类优先级。
# 服务端会重新清洗一遍，客户端只能改自己的配置。
func research_set_auto(owner_peer_id: int, team: int, config) -> Dictionary:
	if not is_research_mode():
		return {"ok": false, "error": "当前不是科研模式"}
	if not (config is Dictionary):
		return {"ok": false, "error": "科研官配置格式错误"}
	var st := get_research_state(owner_peer_id, team)
	if st.is_empty():
		return {"ok": false, "error": "当前不是科研模式"}
	st["auto"] = ResearchAdvisor.normalize_config(config)
	return {"ok": true, "error": "", "auto": st["auto"].duplicate(true)}

func _research_pay(owner_peer_id: int, team: int, cost: Dictionary) -> void:
	var res := research_resources(owner_peer_id, team)
	for k in cost:
		res[k] = int(res.get(k, 0)) - int(cost[k])

func _research_refund(owner_peer_id: int, team: int, cost: Dictionary, ratio: float) -> void:
	var res := research_resources(owner_peer_id, team)
	for k in cost:
		res[k] = int(res.get(k, 0)) + int(floor(float(cost[k]) * ratio))

func _research_has_completed_castle(owner_peer_id: int, team: int) -> bool:
	_ensure_cache_fresh()
	for b in _buildings:
		if is_instance_valid(b) and b.health > 0 and b.build_timer <= 0.0 \
				and b.entity_id == 20 and _same_owner_or_team(b.owner_peer_id, b.team, owner_peer_id, team):
			return true
	return false

func _research_count_buildings(owner_peer_id: int, team: int, ids: Array) -> int:
	_ensure_cache_fresh()
	var n := 0
	for b in _buildings:
		if not is_instance_valid(b) or b.health <= 0 or b.build_timer > 0.0:
			continue
		if not (b.entity_id in ids):
			continue
		if _same_owner_or_team(b.owner_peer_id, b.team, owner_peer_id, team):
			n += 1
	return n

func _research_distinct_building_types(owner_peer_id: int, team: int, ids: Array) -> int:
	_ensure_cache_fresh()
	var kinds := {}
	for b in _buildings:
		if not is_instance_valid(b) or b.health <= 0 or b.build_timer > 0.0:
			continue
		if not (b.entity_id in ids):
			continue
		if _same_owner_or_team(b.owner_peer_id, b.team, owner_peer_id, team):
			kinds[b.entity_id] = true
	return kinds.size()

func _research_count_building_id(owner_peer_id: int, team: int, bid: int) -> int:
	return _research_count_buildings(owner_peer_id, team, [bid])

# 时代升级条件：返回 {ok, error}；条件只在开始研究时检查，研究中不再回滚。
func can_research_age(owner_peer_id: int, team: int) -> Dictionary:
	var st := get_research_state(owner_peer_id, team)
	if st.is_empty():
		return {"ok": false, "error": "当前不是科研模式"}
	var age := int(st.get("age", 0))
	if age >= 3:
		return {"ok": false, "error": "已经是帝国时代"}
	if not st.get("current", {}).is_empty():
		return {"ok": false, "error": "研究队列正在忙碌"}
	var target := age + 1
	var pop := research_pop(owner_peer_id, team)
	match target:
		1:
			if pop < 20:
				return {"ok": false, "error": "需要人口 ≥ 20（当前 %d）" % pop}
			if _research_count_buildings(owner_peer_id, team, [21, 41]) < 2:
				return {"ok": false, "error": "需要 2 座已完成的黑暗时代军事建筑（兵营/瞭望塔）"}
		2:
			if pop < 50:
				return {"ok": false, "error": "需要人口 ≥ 50（当前 %d）" % pop}
			if _research_count_buildings(owner_peer_id, team, [23, 24, 25, 52, 54]) < 3 \
					or _research_distinct_building_types(owner_peer_id, team, [23, 24, 25, 52, 54]) < 2:
				return {"ok": false, "error": "需要 3 座封建建筑且至少 2 种（船坞/攻城车间/箭塔/集市/修道院）"}
		3:
			if pop < 80:
				return {"ok": false, "error": "需要人口 ≥ 80（当前 %d）" % pop}
			if _research_count_buildings(owner_peer_id, team, [26, 29, 42, 53, 64]) < 4 \
					or _research_count_building_id(owner_peer_id, team, 53) < 2:
				return {"ok": false, "error": "需要 4 座城堡建筑，其中至少 2 座城堡"}
	var info := TechTreeData.next_age(age)
	if not research_can_afford(owner_peer_id, team, info.get("cost", {})):
		return {"ok": false, "error": "资源不足"}
	return {"ok": true, "error": "", "target": target}

func research_start_age(owner_peer_id: int, team: int) -> Dictionary:
	if not is_research_mode():
		return {"ok": false, "error": "当前不是科研模式"}
	team = research_team(owner_peer_id, team)
	if not _research_has_completed_castle(owner_peer_id, team):
		return {"ok": false, "error": "需要一座已完成的主城"}
	var check := can_research_age(owner_peer_id, team)
	if not bool(check.get("ok", false)):
		return check
	var st := get_research_state(owner_peer_id, team)
	var target := int(check.get("target", 0))
	var info := TechTreeData.get_age(target)
	_research_pay(owner_peer_id, team, info.get("cost", {}))
	st["current"] = {
		"id": "AGE_%d" % target,
		"kind": "age",
		"name": String(info.get("name", "")),
		"time": float(info.get("time", 0)),
		"total": float(info.get("time", 0)),
		"elapsed": 0.0,
		"cost": info.get("cost", {}).duplicate(true),
	}
	return {"ok": true, "error": ""}

func _research_check_tech_prereq(t: Dictionary, st: Dictionary) -> String:
	var nation := int(st.get("nation", -1))
	for p in t.get("prereq", []):
		var pid := String(p)
		if pid.begins_with("N"):
			if not TechTreeData.has_nation_bit(int(st.get("nation_bits", 0)), nation, pid):
				return "缺少前置国家科技 %s" % pid
		else:
			if not TechTreeData.has_bit(int(st.get("bits", 0)), pid):
				return "缺少前置科技 %s" % pid
	return ""

func _research_exclusion_error(st: Dictionary, tid: String) -> String:
	var bits := int(st.get("bits", 0))
	if tid == "I2" and TechTreeData.has_bit(bits, "I6"):
		return "I2 与 I6 互斥（已研究 I6）"
	if tid == "I6" and TechTreeData.has_bit(bits, "I2"):
		return "I2 与 I6 互斥（已研究 I2）"
	return ""

func research_start_tech(owner_peer_id: int, team: int, tid: String) -> Dictionary:
	if not is_research_mode():
		return {"ok": false, "error": "当前不是科研模式"}
	var st := get_research_state(owner_peer_id, team)
	if st.is_empty():
		return {"ok": false, "error": "当前不是科研模式"}
	if not st.get("current", {}).is_empty():
		return {"ok": false, "error": "研究队列正在忙碌"}
	var t := TechTreeData.get_any(tid)
	if t.is_empty():
		return {"ok": false, "error": "未知科技 %s" % tid}
	var nation := int(st.get("nation", -1))
	var is_nation := String(t.get("kind", "")) == "nation"
	if is_nation:
		if int(t.get("nation", -1)) != nation:
			return {"ok": false, "error": "只能研究本国特色科技"}
		if TechTreeData.has_nation_bit(int(st.get("nation_bits", 0)), nation, tid):
			return {"ok": false, "error": "该科技已完成"}
	else:
		if TechTreeData.has_bit(int(st.get("bits", 0)), tid):
			return {"ok": false, "error": "该科技已完成"}
	if int(t.get("age", 0)) > int(st.get("age", 0)):
		return {"ok": false, "error": "需要先进入%s" % TechTreeData.age_name(int(t.get("age", 0)))}
	var err := _research_check_tech_prereq(t, st)
	if err != "":
		return {"ok": false, "error": err}
	err = _research_exclusion_error(st, tid)
	if err != "":
		return {"ok": false, "error": err}
	var cost: Dictionary = t.get("cost", {})
	if not research_can_afford(owner_peer_id, team, cost):
		return {"ok": false, "error": "资源不足"}
	_research_pay(owner_peer_id, team, cost)
	st["current"] = {
		"id": tid,
		"kind": "nation" if is_nation else "tech",
		"name": String(t.get("name", "")),
		"time": float(t.get("time", 0)),
		"total": float(t.get("time", 0)),
		"elapsed": 0.0,
		"cost": cost.duplicate(true),
	}
	return {"ok": true, "error": ""}

func research_start(owner_peer_id: int, team: int, tid: String) -> Dictionary:
	if not _research_has_completed_castle(owner_peer_id, research_team(owner_peer_id, team)):
		return {"ok": false, "error": "需要一座已完成的主城"}
	if TechTreeData.is_age_tech(tid):
		return research_start_age(owner_peer_id, research_team(owner_peer_id, team))
	return research_start_tech(owner_peer_id, research_team(owner_peer_id, team), tid)

func research_cancel(owner_peer_id: int, team: int) -> Dictionary:
	var st := get_research_state(owner_peer_id, team)
	if st.is_empty() or st.get("current", {}).is_empty():
		return {"ok": false, "error": "没有正在研究的项目"}
	var cur: Dictionary = st["current"]
	if String(cur.get("kind", "")) == "age":
		return {"ok": false, "error": "时代升级不可取消"}
	var ratio := 1.0 if float(cur.get("elapsed", 0.0)) <= 10.0 else 0.5
	_research_refund(owner_peer_id, team, cur.get("cost", {}), ratio)
	st["current"] = {}
	return {"ok": true, "error": "", "refund_ratio": ratio}

func _research_complete(st: Dictionary) -> void:
	var cur: Dictionary = st.get("current", {})
	if cur.is_empty():
		return
	var tid := String(cur.get("id", ""))
	var kind := String(cur.get("kind", ""))
	if kind == "age":
		var target := int(tid.substr(4))
		st["age"] = clampi(target, 0, 3)
	else:
		var nation := int(st.get("nation", -1))
		if kind == "nation":
			st["nation_bits"] = TechTreeData.set_nation_bit(int(st.get("nation_bits", 0)), nation, tid)
		else:
			st["bits"] = TechTreeData.set_bit(int(st.get("bits", 0)), tid)
	st["current"] = {}
	_refresh_research_derived(st)
	if kind == "age":
		update_population_limits()
	_apply_research_to_owned_entities(st)
	_refresh_research_production(st)
	_research_refresh_entity_bars()
	# 1v1 的 state key 是队伍号（0/1），不能当 owner 传给按 peer 统计的人口接口。
	_update_player_population(int(st.get("owner", -1)))
	var owner := int(st.get("owner", -1))
	var team := int(st.get("team", get_host_team()))
	var nation := int(st.get("nation", -1))
	# 自己完成科研 → 提示；队友（AI 队友 / 2v2 真人队友）完成科研也推给同队，
	# 由 HUD 按「战报筛选 · 科研完成」决定是否显示（默认接收），敌方科研会被过滤掉。
	_show_hud_alert("研究完成：%s" % String(cur.get("name", "")), Color(0.4, 0.9, 1.0),
		[team], team, GameSettings.AlertKind.RESEARCH, false, [nation], Vector3.ZERO, owner)

# 遍历该玩家单位/建筑，从基础值重算科研加成（不增量叠加）。
func _apply_research_to_owned_entities(st: Dictionary) -> void:
	_ensure_cache_fresh()
	for e in _all_entities:
		if not is_instance_valid(e) or e.health <= 0:
			continue
		var key := research_key(int(e.owner_peer_id), int(e.team))
		if key == int(st.get("_key", -999999)):
			apply_research_bonuses(e)

func _refresh_research_production(st: Dictionary) -> void:
	_ensure_cache_fresh()
	for b in _buildings:
		if not is_instance_valid(b) or b.health <= 0 or b.build_timer > 0.0:
			continue
		var key := research_key(int(b.owner_peer_id), int(b.team))
		if key != int(st.get("_key", -999999)):
			continue
		if b.has_method("_sync_production_unlocks"):
			b._sync_production_unlocks()
		if b.has_method("_unlock_nation_units") and b.entity_id == 53:
			var bn := get_entity_nation(b)
			if bn >= 0:
				b._unlock_nation_units(bn)

func _update_player_population(owner_key: int) -> void:
	if owner_key >= 0:
		update_player_population(owner_key)
		return
	update_population_limits()

func _tick_research(delta: float) -> void:
	if not is_research_mode():
		return
	# 暂停时研究也暂停（管理器本身要保持运行以接收指令）。
	if get_tree().paused:
		return
	# 3 倍速模式的采集是 3 倍，科研此前仍是 1 倍，会明显显得“时代/科技很慢”。
	# 科研进度与采集同步按 3 倍推进；研究费用和面板总时长不变。
	var speed_mult: float = 3.0 if GameSettings.fast_mode else 1.0
	for key in research_states.keys():
		var st: Dictionary = research_states[key]
		st["_key"] = key
		var cur: Dictionary = st.get("current", {})
		if cur.is_empty():
			continue
		cur["elapsed"] = float(cur.get("elapsed", 0.0)) + delta * speed_mult
		if float(cur["elapsed"]) >= float(cur.get("total", 1.0)):
			_research_complete(st)
	# 智能科研官：只对玩家开启了自动研究的科研状态生效；AI 有自己的科研节奏。
	_research_auto_timer += delta
	if _research_auto_timer >= RESEARCH_AUTO_INTERVAL:
		_research_auto_timer = 0.0
		_tick_auto_research()
	# I2 户税：每 10 秒按人口结算，避免逐帧浮点累加漂移。
	_research_tax_timer += delta
	while _research_tax_timer >= 10.0:
		_research_tax_timer -= 10.0
		for key in research_states.keys():
			var st: Dictionary = research_states[key]
			if not TechTreeData.has_bit(int(st.get("bits", 0)), "I2"):
				continue
			var owner := int(st.get("owner", -1))
			var team := int(st.get("team", get_host_team()))
			var tax_rate := float(st.get("mods", {}).get("tax_gold", 0.0))
			if tax_rate <= 0.0:
				continue
			var pop := research_pop(owner, team)
			var pool := float(st.get("tax_pool", 0.0)) + float(pop) * tax_rate
			var gain := int(floor(pool))
			pool -= float(gain)
			st["tax_pool"] = pool
			if gain > 0:
				var res := research_resources(owner, team)
				var lim: Dictionary = get_limits_for(owner) if owner >= 0 else get_team_resource_limits(team)
				var cap := int(lim.get("gold", 99999))
				res["gold"] = min(int(res.get("gold", 0)) + gain, cap)

# ==================== 智能科研官（玩家科研自动化） ====================
func _tick_auto_research() -> void:
	for key in research_states.keys():
		var st: Dictionary = research_states[key]
		if st.is_empty():
			continue
		var cfg := ResearchAdvisor.normalize_config(st.get("auto", {}))
		st["auto"] = cfg
		if not bool(cfg.get("enabled", false)):
			continue
		if not st.get("current", {}).is_empty():
			continue
		var owner := int(st.get("owner", -1))
		var team := int(st.get("team", get_host_team()))
		if not _research_has_completed_castle(owner, team):
			continue
		_auto_research_state(st, cfg)

func _auto_research_state(st: Dictionary, cfg: Dictionary) -> void:
	var owner := int(st.get("owner", -1))
	var team := int(st.get("team", get_host_team()))
	var age := int(st.get("age", 0))
	var reserve: Dictionary = {}
	if bool(cfg.get("auto_age", true)) and age < 3:
		var check := can_research_age(owner, team)
		if bool(check.get("ok", false)):
			if bool(research_start_age(owner, team).get("ok", false)):
				return
		else:
			var err := String(check.get("error", ""))
			if err == "资源不足":
				# 人口/建筑条件已齐，只差资源：把时代费用锁住，科技只能花“多出来”的
				# 那部分，避免科研官自己把升时代预算吃掉。
				reserve = TechTreeData.get_age(age + 1).get("cost", {}).duplicate(true)
			else:
				# 条件没齐：先补能解锁升级所需建筑的科技，否则自动升时代会永远卡住。
				var support := ResearchAdvisor.age_requirement_techs(age + 1)
				if _auto_start_first_tech(st, support, reserve):
					return
	# 按玩家设定的分类优先级选下一项；如果正在为升时代攒资源，只允许不破坏预算的科技。
	_auto_start_by_priority(st, cfg, reserve)

func _auto_start_first_tech(st: Dictionary, ids: Array, reserve: Dictionary) -> bool:
	var owner := int(st.get("owner", -1))
	var team := int(st.get("team", get_host_team()))
	var age := int(st.get("age", 0))
	for tid in ids:
		var t := TechTreeData.get_tech(String(tid))
		if t.is_empty() or not _auto_tech_candidate(st, t, age, reserve):
			continue
		if bool(research_start_tech(owner, team, String(tid)).get("ok", false)):
			return true
	return false

func _auto_start_by_priority(st: Dictionary, cfg: Dictionary, reserve: Dictionary) -> bool:
	var owner := int(st.get("owner", -1))
	var team := int(st.get("team", get_host_team()))
	var age := int(st.get("age", 0))
	var nation := int(st.get("nation", -1))
	var priority: Array = cfg.get("priority", ResearchAdvisor.DEFAULT_PRIORITY)
	var candidates: Array = []
	var order := 0
	for tid in TechTreeData.tech_ids():
		var t := TechTreeData.get_tech(String(tid))
		if _auto_tech_candidate(st, t, age, reserve):
			candidates.append({
				"id": String(tid),
				"rank": ResearchAdvisor.priority_rank(priority, String(t.get("category", ""))),
				"age": int(t.get("age", 0)),
				"time": float(t.get("time", 0.0)),
				"order": order,
			})
		order += 1
	for t in TechTreeData.nation_techs(nation):
		if _auto_tech_candidate(st, t, age, reserve):
			candidates.append({
				"id": String(t.get("id", "")),
				"rank": ResearchAdvisor.priority_rank(priority, "N"),
				"age": int(t.get("age", 0)),
				"time": float(t.get("time", 0.0)),
				"order": order,
			})
		order += 1
	if candidates.is_empty():
		return false
	candidates.sort_custom(func(a, b):
		if int(a["rank"]) != int(b["rank"]):
			return int(a["rank"]) < int(b["rank"])
		if int(a["age"]) != int(b["age"]):
			return int(a["age"]) < int(b["age"])
		if not is_equal_approx(float(a["time"]), float(b["time"])):
			return float(a["time"]) < float(b["time"])
		return int(a["order"]) < int(b["order"])
	)
	for c in candidates:
		if bool(research_start_tech(owner, team, String(c["id"])).get("ok", false)):
			return true
	return false

func _auto_tech_candidate(st: Dictionary, t: Dictionary, age: int, reserve: Dictionary) -> bool:
	if t.is_empty():
		return false
	var tid := String(t.get("id", ""))
	if tid.is_empty():
		return false
	var nation := int(st.get("nation", -1))
	var is_nation := String(t.get("kind", "")) == "nation"
	if is_nation:
		if int(t.get("nation", -1)) != nation:
			return false
		if TechTreeData.has_nation_bit(int(st.get("nation_bits", 0)), nation, tid):
			return false
	else:
		if TechTreeData.has_bit(int(st.get("bits", 0)), tid):
			return false
	if int(t.get("age", 0)) > age:
		return false
	if _research_check_tech_prereq(t, st) != "":
		return false
	if _research_exclusion_error(st, tid) != "":
		return false
	var owner := int(st.get("owner", -1))
	var team := int(st.get("team", get_host_team()))
	return _auto_can_afford_with_reserve(owner, team, t.get("cost", {}), reserve)

func _auto_can_afford_with_reserve(owner_peer_id: int, team: int, cost: Dictionary, reserve: Dictionary) -> bool:
	var res := research_resources(owner_peer_id, team)
	for k in cost:
		if int(res.get(k, 0)) < int(cost[k]) + int(reserve.get(k, 0)):
			return false
	return true

# ==================== 科研解锁查询 ====================
func is_unit_unlocked(unit_id: int, owner_peer_id: int = -1, team: int = -1) -> bool:
	if not is_research_mode():
		return true
	if team < 0:
		team = get_host_team()
	var st := get_research_state(owner_peer_id, team)
	return bool(st.get("unlocked_units", {}).get(unit_id, false))

func get_building_unlock_text(building_id: int, owner_peer_id: int = -1, team: int = -1) -> String:
	if not is_research_mode():
		return ""
	match building_id:
		7: return "需研究 E1 栈桥飞渡"
		23: return "需研究 E2 渔汛舟师"
		24: return "需研究 F1 冲车工坊"
		25: return "需研究 B6 烽燧望楼"
		52: return "需研究 I5 关市"
		54: return "需研究 H1 苦修戒律"
		53: return "需研究 A4 石城筑法（前置 A2+B6）"
		42: return "需研究 I1 察举制"
		26, 64: return "需研究 F10 棱堡炮位"
		29: return "需研究 G1 重装步军"
	return ""

# ==================== 科研数值加成 ====================
func get_research_mods(owner_peer_id: int, team: int) -> Dictionary:
	var st := get_research_state(owner_peer_id, team)
	return st.get("mods", {}) if not st.is_empty() else {}

func research_gather_mult(owner_peer_id: int, team: int, res_type: String) -> float:
	var mods := get_research_mods(owner_peer_id, team)
	var pct := float(mods.get("gather_all_pct", 0.0)) + float(mods.get("gather_%s_pct" % res_type, 0.0))
	return 1.0 + pct / 100.0

func research_pop_bonus(owner_peer_id: int, team: int) -> int:
	return int(get_research_mods(owner_peer_id, team).get("pop_bonus", 0.0))

func _mod_pct(mods: Dictionary, key: String) -> float:
	return float(mods.get(key, 0.0)) / 100.0

func _mod_unit(mods: Dictionary, uid: int, prefix: String) -> float:
	return float(mods.get("%s:%d" % [prefix, uid], 0.0)) / 100.0

func _mod_class(mods: Dictionary, uid: int, prefix: String) -> float:
	var total := 0.0
	for cls in TechTreeData.UNIT_CLASSES.get(uid, []):
		total += float(mods.get("%s:%s" % [prefix, cls], 0.0)) / 100.0
	return total

func _mod_class_raw(mods: Dictionary, uid: int, prefix: String) -> float:
	var total := 0.0
	for cls in TechTreeData.UNIT_CLASSES.get(uid, []):
		total += float(mods.get("%s:%s" % [prefix, cls], 0.0))
	return total

func apply_research_bonuses(e) -> void:
	if not is_research_mode() or e == null or not is_instance_valid(e):
		return
	if not e.has_method("_capture_research_base"):
		return
	var st := get_research_state_for_entity(e)
	if st.is_empty():
		return
	var base: Dictionary = e._research_base_stats
	if base.is_empty():
		# 单位要等国家加成执行完再记录基础值，避免把国家加成刷掉或重复计算。
		if e is Army:
			return
		e._capture_research_base()
		base = e._research_base_stats
	if base.is_empty():
		return
	var mods: Dictionary = st.get("mods", {})
	var uid := int(e.entity_id)
	var health_ratio := 1.0
	if e.max_health > 0.0:
		health_ratio = clampf(e.health / e.max_health, 0.0, 1.0)
	# 先恢复基础值，保证多次刷新不会滚雪球。
	e.max_health = float(base.get("max_health", e.max_health))
	e.attack = float(base.get("attack", e.attack))
	e.attack_speed = float(base.get("attack_speed", e.attack_speed))
	e.attack_range = float(base.get("attack_range", e.attack_range))
	e.speed = float(base.get("speed", e.speed))
	e.vision_range = float(base.get("vision_range", e.vision_range))
	e.melee_armor = int(base.get("melee_armor", e.melee_armor))
	e.shield_armor = int(base.get("shield_armor", e.shield_armor))
	e.damage_radius = float(base.get("damage_radius", e.damage_radius))
	e.shield_pierce = 0.0
	e.melee_pierce = 0.0
	e.building_damage_pct = 0.0
	e.vs_archer_pct = 0.0
	e.vs_cavalry_pct = 0.0
	e.vs_ship_pct = 0.0
	e.spell_power_mult = 1.0
	e.spell_resist = 0.0
	e.accuracy_mult = 1.0
	e.splash_damage_mult = 0.0
	if e is Building:
		var hp_pct := _mod_pct(mods, "building_hp_pct")
		var armor_add := int(mods.get("building_armor", 0))
		if uid == 53 or uid == 27:
			hp_pct += _mod_pct(mods, "castle_wall_hp_pct")
			armor_add += int(mods.get("castle_wall_armor", 0))
		hp_pct += _mod_pct(mods, "building_hp_pct:%d" % uid)
		e.max_health = float(base.get("max_health", e.max_health)) * (1.0 + hp_pct)
		e.melee_armor = int(base.get("melee_armor", 0)) + armor_add
		e.shield_armor = int(base.get("shield_armor", 0)) + armor_add
		e.attack = float(base.get("attack", 0.0)) * (1.0 + _mod_pct(mods, "building_attack_pct:%d" % uid))
		e.attack_range = float(base.get("attack_range", 0.0)) + float(mods.get("main_castle_range", 0.0)) if uid in [20, 53] else float(base.get("attack_range", 0.0))
		e.attack = e.attack * (1.0 + _mod_pct(mods, "main_castle_attack_pct")) if uid in [20, 53] else e.attack
		if uid == 20 and float(mods.get("main_city_attack", 0.0)) > 0.0:
			e.attack = float(mods.get("main_city_attack", 15.0))
			e.attack_range = float(mods.get("main_city_range", 6.0))
			e.attack_speed = float(mods.get("main_city_attack_speed", 1.2))
		if uid in [25, 26]:
			e.attack_range += float(mods.get("tower_range", 0.0))
			e.attack_speed = float(base.get("attack_speed", e.attack_speed)) / (1.0 + _mod_pct(mods, "tower_attack_speed_pct"))
		if uid in TechTreeData.CANNON_UNIT_IDS:
			e.attack *= 1.0 + _mod_pct(mods, "cannon_damage_pct")
			e.attack_range += float(mods.get("cannon_range", 0.0))
			if float(mods.get("cannon_splash", 0.0)) > 0.0:
				e.splash_damage_mult = float(mods.get("cannon_splash", 0.0)) / 100.0
		if uid in [20, 53]:
			e.volley_count = int(mods.get("volley_count", 1))
			e.volley_mult = float(mods.get("volley_mult", 1.0))
		e.health = minf(e.max_health, e.max_health * health_ratio) if health_ratio > 0.0 else e.max_health
		e._capture_stats_before_official()
		return
	# 单位
	var hp := _mod_class(mods, uid, "class_hp_pct") + _mod_unit(mods, uid, "unit_hp_pct") + _mod_pct(mods, "all_hp_pct")
	var atk := _mod_class(mods, uid, "class_attack_pct") + _mod_unit(mods, uid, "unit_attack_pct")
	var spd := _mod_class(mods, uid, "class_speed_pct") + _mod_unit(mods, uid, "unit_speed_pct") + _mod_pct(mods, "all_speed_pct")
	var aspd := _mod_class(mods, uid, "class_attack_speed_pct") + _mod_unit(mods, uid, "unit_attack_speed_pct")
	var vision := _mod_class(mods, uid, "class_vision_pct") + _mod_unit(mods, uid, "unit_vision_pct")
	e.max_health = float(base.get("max_health", e.max_health)) * (1.0 + hp)
	e.attack = float(base.get("attack", e.attack)) * (1.0 + atk)
	e.speed = float(base.get("speed", e.speed)) * (1.0 + clampf(spd, -0.5, 0.4))
	e.attack_speed = float(base.get("attack_speed", e.attack_speed)) / (1.0 + maxf(aspd, -0.8))
	e.vision_range = float(base.get("vision_range", e.vision_range)) * (1.0 + vision)
	e.melee_armor = int(base.get("melee_armor", 0)) + int(mods.get("class_melee_armor:%d" % uid, 0))
	e.shield_armor = int(base.get("shield_armor", 0)) + int(mods.get("class_shield_armor:%d" % uid, 0))
	for cls in TechTreeData.UNIT_CLASSES.get(uid, []):
		e.melee_armor += int(mods.get("class_melee_armor:%s" % cls, 0))
		e.shield_armor += int(mods.get("class_shield_armor:%s" % cls, 0))
	e.melee_armor += int(mods.get("unit_melee_armor:%d" % uid, 0))
	e.shield_armor += int(mods.get("unit_shield_armor:%d" % uid, 0))
	e.shield_pierce = maxf(_mod_class_raw(mods, uid, "class_shield_pierce"), float(mods.get("archer_shield_pierce", 0.0)) if uid in [12, 31, 33, 37, 58] else 0.0)
	e.melee_pierce = _mod_class_raw(mods, uid, "class_melee_pierce")
	e.building_damage_pct = _mod_class(mods, uid, "class_building_damage_pct")
	e.vs_archer_pct = _mod_class(mods, uid, "class_vs_archer_pct")
	e.vs_cavalry_pct = _mod_class(mods, uid, "class_vs_cavalry_pct")
	e.vs_ship_pct = _mod_unit(mods, uid, "unit_vs_ship_pct")
	if uid in [12, 31, 33, 37, 58]:
		e.attack_range = float(base.get("attack_range", e.attack_range)) + float(mods.get("archer_range", 0.0))
	if uid in TechTreeData.CANNON_UNIT_IDS:
		e.attack *= 1.0 + _mod_pct(mods, "cannon_damage_pct")
		e.attack_range += float(mods.get("cannon_range", 0.0))
		if float(mods.get("cannon_splash", 0.0)) > 0.0:
			e.splash_damage_mult = float(mods.get("cannon_splash", 0.0)) / 100.0
	if uid in TechTreeData.STONE_UNIT_IDS:
		e.attack *= 1.0 + _mod_pct(mods, "stone_damage_pct")
		e.damage_radius = float(base.get("damage_radius", 0.0)) * (1.0 + _mod_pct(mods, "stone_splash_pct"))
		e.accuracy_mult = 1.0 + _mod_pct(mods, "treb_accuracy_pct")
		e.accuracy_mult = clampf(e.accuracy_mult, 0.2, 2.0)
	if uid in [55, 56, 57]:
		e.spell_power_mult = 1.0 + _mod_pct(mods, "spell_power_pct")
		e.spell_resist = _mod_pct(mods, "spell_resist_pct")
	e.health = e.max_health * health_ratio
	e._capture_stats_before_official()

# 数值变更后刷新一次可见血条；联机客户端靠快照同步，不存在客户端调用。
func _research_refresh_entity_bars() -> void:
	for e in get_tree().get_nodes_in_group("entities"):
		if e is GameEntity and e.has_method("_refresh_damage_visual"):
			e._refresh_damage_visual()

func research_age_label(owner_peer_id: int = -1, team: int = -1) -> String:
	if not is_research_mode():
		return "经典模式"
	if team < 0:
		team = get_host_team()
	var st := get_research_state(owner_peer_id, team)
	return TechTreeData.age_name(int(st.get("age", 0))) if not st.is_empty() else "黑暗时代"

# ==================== UI 统一接口（单机 battle manager / 联机 ClientRenderer 同签名） ====================
func ui_research_state() -> Dictionary:
	return get_host_research_state()

func ui_research_start(tid: String) -> Dictionary:
	return research_start(player_owner_id, get_host_team(), tid)

func ui_research_start_age() -> Dictionary:
	return research_start_age(player_owner_id, get_host_team())

func ui_research_cancel() -> Dictionary:
	return research_cancel(player_owner_id, get_host_team())

# 智能科研官设置（单机/房主直接写服务端状态；联机客户端由 ClientRenderer 转发）。
func ui_research_set_auto(config: Dictionary) -> Dictionary:
	return research_set_auto(player_owner_id, get_host_team(), config)

func ui_research_available() -> bool:
	return is_research_mode()

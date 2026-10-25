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
const BattleStatsPanelScript = preload("res://scripts/ui/BattleStatsPanel.gd")
const MapPresets = preload("res://scripts/map/MapPresets.gd")
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
var gather_paused: bool = false
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
# ==================== 空间索引（网格分桶，消除 O(n²) 近邻扫描） ====================
const _SPATIAL_CELL_SIZE: float = 4.0
var _spatial_cells: Dictionary = {}  # Vector2i -> Array[GameEntity]，随实体缓存重建
var _building_cells: Dictionary = {}  # Vector2i -> Array[Building]，仅供碰撞分离精确查询建筑
# ==================== A* 分帧预算 ====================
# 大部队同时下令时，几十/上百个单位会在同一帧各跑一次 A*。这里按帧限制
# 请求数和耗时，超出的单位延后到后续帧重试；调用方 MovementController 会等待。
# 原 8 请求/6ms 在大部队同时下令时首批路径分配偏慢，放宽到 12 请求/9ms；
# 仍按帧限制总耗时，避免单帧被寻路无限拖长。
const ASTAR_REQUESTS_PER_FRAME: int = 12
const ASTAR_TIME_BUDGET_USEC: int = 9000
# 给“已经因为预算不足排队过”的请求预留配额。新请求最多用 8 个名额/6ms，
# 剩余 4 个名额/3ms 留给 pending 重试，避免大量新移动命令永远压在场景树后段的单位前面。
const ASTAR_RETRY_RESERVE_REQUESTS: int = 4
const ASTAR_RETRY_RESERVE_USEC: int = 3000
var _astar_budget_frame: int = -1
var _astar_budget_count: int = 0
var _astar_budget_usec: int = 0
# ==================== 墙体/梯子网格缓存（O(1) 查询，随实体缓存重建） ====================
var _wall_cache_version: int = 0          # 墙体/建筑布局实际变化时递增，MovementController 据此判断墙集合是否失效
var _wall_layout_signature: int = 0       # 建筑/资源布局签名，避免实体缓存每 0.5s 刷新都让寻路墙缓存失效
var _wall_signature_initialized: bool = false
var _wall_entity_grid: Dictionary = {}    # Vector2i -> Building(城墙 id==27)，供 process_move 高度平滑 O(1) 查询
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
func reserve_astar_request(is_retry: bool = false) -> bool:
	var frame: int = Engine.get_process_frames()
	if frame != _astar_budget_frame:
		_astar_budget_frame = frame
		_astar_budget_count = 0
		_astar_budget_usec = 0
	var max_count: int = ASTAR_REQUESTS_PER_FRAME
	var max_usec: int = ASTAR_TIME_BUDGET_USEC
	if not is_retry:
		max_count -= ASTAR_RETRY_RESERVE_REQUESTS
		max_usec -= ASTAR_RETRY_RESERVE_USEC
	if _astar_budget_count >= max_count or _astar_budget_usec >= max_usec:
		return false
	_astar_budget_count += 1
	return true

func report_astar_cost(usec: int) -> void:
	if usec > 0:
		_astar_budget_usec += usec

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
var _diag_top_y: float = 6.0
var _diag_line_h: float = 34.0

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
	# 顶部中央偏右的两行大字：第一行性能（帧率/画质/实体），第二行对局信息（AI/地图/时间）
	# 桌面端放偏右（0.675）避开左侧那排全局指令按钮，右侧也不压小地图；手机端顶部没有按钮，保持居中
	var mobile := InputSource.use_mobile_ui()
	var center_anchor: float = 0.5 if mobile else 0.675
	var f1: int = UILayout.font_dp(12.0) if mobile else 24
	var f2: int = UILayout.font_dp(11.0) if mobile else 22
	var y1: float = UILayout.dp(76.0) if mobile else 6.0
	var line_h: float = UILayout.dp(18.0) if mobile else 34.0
	var half_w: float = UILayout.dp(330.0) if mobile else 520.0
	_diag_top_y = y1
	_diag_line_h = line_h
	_diag_bg = Panel.new()
	_diag_bg.name = "DiagBG"
	_diag_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_diag_bg.z_index = 199
	_diag_bg.anchor_left = center_anchor
	_diag_bg.anchor_right = center_anchor
	_diag_bg.anchor_top = 0.0
	_diag_bg.anchor_bottom = 0.0
	var bg_style := StyleBoxFlat.new()
	bg_style.bg_color = Color(0.0, 0.0, 0.0, 0.45)
	bg_style.set_corner_radius_all(int(UILayout.dp(6.0)))
	_diag_bg.add_theme_stylebox_override("panel", bg_style)
	_fps_label = _make_top_label("DiagFPS", y1, line_h, f1, half_w, center_anchor, Color.LIME_GREEN)
	_snap_rate_label = _make_top_label("DiagInfo", y1 + line_h, line_h, f2, half_w, center_anchor, Color(1.0, 0.9, 0.3))
	var canvas = CanvasLayer.new()
	canvas.name = "DiagLayer"
	canvas.layer = 100
	canvas.add_child(_diag_bg)
	canvas.add_child(_fps_label)
	canvas.add_child(_snap_rate_label)
	add_child(canvas)
	_update_diag_bg(y1, line_h)

# 半透明底板按两行文字的实际宽度自适应，文字换长（实体数变大）时也不会露在外面
func _update_diag_bg(top_y: float, line_h: float) -> void:
	if _diag_bg == null or not is_instance_valid(_diag_bg) or _fps_label == null:
		return
	var pad_x: float = UILayout.dp(10.0)
	var pad_y: float = UILayout.dp(4.0)
	var text_w: float = _fps_label.get_minimum_size().x
	if _snap_rate_label:
		text_w = maxf(text_w, _snap_rate_label.get_minimum_size().x)
	var w: float = text_w + pad_x * 2.0
	var h: float = line_h * 2.0 + pad_y * 2.0
	var bg_top: float = maxf(top_y - pad_y, 0.0)
	_diag_bg.offset_left = -w * 0.5
	_diag_bg.offset_right = w * 0.5
	_diag_bg.offset_top = bg_top
	_diag_bg.offset_bottom = bg_top + h

# 顶部中央的一行信息（带黑描边，浅色地面也看得清）
func _make_top_label(node_name: String, top_y: float, line_h: float, font_size: int, half_w: float, center_anchor: float, color: Color) -> Label:
	var lb := Label.new()
	lb.name = node_name
	lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lb.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lb.anchor_left = center_anchor
	lb.anchor_right = center_anchor
	lb.anchor_top = 0.0
	lb.anchor_bottom = 0.0
	lb.offset_left = -half_w
	lb.offset_right = half_w
	lb.offset_top = top_y
	lb.offset_bottom = top_y + line_h
	lb.add_theme_font_size_override("font_size", font_size)
	lb.add_theme_color_override("font_color", color)
	lb.add_theme_color_override("font_outline_color", Color.BLACK)
	lb.add_theme_constant_override("outline_size", maxi(3, int(font_size * 0.2)))
	lb.z_index = 200
	return lb

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
	_wall_top_entity_grid.clear()
	_ladder_entity_grid.clear()
	_bridge_entity_grid.clear()
	for b in _buildings:
		if b.health <= 0:
			continue
		if b.entity_id == 27:
			_wall_entity_grid[world_to_grid(b.global_position)] = b
			_wall_top_entity_grid[world_to_grid(b.global_position)] = b
		elif b.entity_id == 64:
			_wall_top_entity_grid[world_to_grid(b.global_position)] = b
		elif b.entity_id == 8:
			_ladder_entity_grid[world_to_grid(b.global_position)] = b
		elif b.entity_id == 7:
			_bridge_entity_grid[world_to_grid(b.global_position)] = b
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
	_entity_cache_dirty = false

func mark_entity_cache_dirty():
	_entity_cache_dirty = true

# 落水判定：桥所在格视为可站立，不参与溺水伤害
func is_bridge_at(world_pos: Vector3) -> bool:
	_ensure_cache_fresh()
	return _bridge_entity_grid.has(world_to_grid(world_pos))

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
func get_nearby_enemies(from_pos: Vector3, search_range: float, my_team: int, my_owner: int = -1) -> Array:
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
				if dist <= max_dist * max_dist:
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

# 检查建筑是否已由城堡等级解锁
func is_building_unlocked(building_id: int) -> bool:
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
		23, 25, 26: return 2
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
	var target = _get_auto_attack_target(-1, get_local_team())
	for e in get_tree().get_nodes_in_group("entities"):
		if not (e is Army) or e.health <= 0: continue
		if not is_local_player_owned(e.owner_peer_id, e.team): continue
		if not e._is_military() or e.entity_id in AUTO_ATTACK_EXCLUDE_IDS: continue
		if enabled:
			if e.current_target != null: continue
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

func _get_auto_attack_target(_owner: int, _team: int) -> Building:
	var castle = get_enemy_castle()
	if castle: return castle
	# 乱斗模式没有 RED 队伍：选择任意非本地玩家的主城
	_ensure_cache_fresh()
	for e in _buildings:
		if e is Building and e.entity_id == 20 and e.health > 0:
			if not is_local_player_owned(e.owner_peer_id, e.team):
				return e
	return null

# 新生产的军队继承当前自动进攻状态
func _apply_auto_attack_to_entity(entity: GameEntity) -> void:
	if not is_instance_valid(entity) or not (entity is Army): return
	if entity.health <= 0 or not entity._is_military(): return
	if entity.entity_id in AUTO_ATTACK_EXCLUDE_IDS: return
	if not _is_auto_attack_enabled_for(entity.owner_peer_id, entity.team): return
	if entity.current_target != null: return
	var target = _get_auto_attack_target(entity.owner_peer_id, entity.team)
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

# ==================== 人口上限更新 ====================
func update_population_limits():
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
	if not is_online and not GameSettings.is_ffa:
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
		if GameSettings.is_ffa:
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
			# 按 unlock_level / 当前等级同步生产列表，支持同一级解锁多个单位
			e._sync_production_unlocks()
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
		if ft == 0:
			spawn_entity(peasant_cfg, get_host_team(), Vector3(fx, 0, fz))
		else:
			spawn_entity(peasant_cfg, get_host_team(), player_castle_pos + Vector3(randf_range(-3,3), 0, randf_range(-3,3)))
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
	var target_size = entity.body_radius * 2.0
	var aabb = _get_model_aabb(model_instance)
	var current_size = max(aabb.size.x, max(aabb.size.y, aabb.size.z))
	var scale_factor := 1.0
	if current_size > 0.01:
		scale_factor = target_size / current_size * RTSConfig.get_model_scale(entity.entity_id)
		model_instance.scale = Vector3.ONE * scale_factor
	# 打个标记，让 Army 能稳定取到自己的模型根节点（不能按名字找：名字来自 GLB）
	model_instance.set_meta("entity_model", true)
	entity.add_child(model_instance)
	_ensure_model_shadows(model_instance)
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
	return true

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
	elif entity is Army:
		var army := entity as Army
		var _moving_now: bool = army.velocity.length_squared() > 0.04
		if army._order_is(army.UnitState.GATHERING):
			# 采集途中播放走路；进入采集距离后才播放挥动；被挡住停住时不要原地踏步
			anim = "attack-melee-left" if _is_entity_in_action_range(army) else ("walk" if _moving_now else "idle")
		elif army._order_is(army.UnitState.ATTACKING) or army._order_is(army.UnitState.ATTACK_MOVING):
			# 锁定目标但还在接近时仍然是走路动画，进入攻击距离后才挥击
			anim = "attack-melee-left" if _is_entity_in_action_range(army) else ("walk" if _moving_now else "idle")
		elif army._order_in([army.UnitState.MOVING, army.UnitState.DELIVERING]):
			anim = "walk" if _moving_now else "idle"
		else:
			anim = "idle"
	else:
		anim = "idle"
	# 这些兵种即使模型自带 attack 动画也偏弱（挥动幅度很小），
	# 统一强制走程序化动作，保证攻城/远程单位开火时一眼能看出来
	var force_proc: bool = entity is Army and entity.entity_id in PROC_ATTACK_IDS
	if ap != null and anim != "" and ap.has_animation(anim) and not (force_proc and anim == "attack-melee-left"):
		var spd := 1.0
		if anim == "attack-melee-left":
			# 攻击动作按攻击冷却循环；GATHERING 也复用攻击动作，让采集有挥动反馈
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
	# 僧侣/长老/宗师是远程法术单位，走「蓄力—释放」的施法动作，
	# 而不是近战那套整身前刺，并在出手瞬间放出带颜色的法球。
	if CasterAttackAnim.is_caster(entity.entity_id):
		CasterAttackAnim.play(entity.entity_id, model, {
			"range": entity.attack_range,
			"target": entity.current_target,
		})
		return
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
	entities.add_child(entity)
	# 实体以任何方式离开场景树（死亡动画结束、销毁、场景退出）都立即标记缓存失效，
	# 避免 AI/统计缓存里残留已释放实例，访问属性时报 "previously freed"。
	if not entity.tree_exiting.is_connected(mark_entity_cache_dirty):
		entity.tree_exiting.connect(mark_entity_cache_dirty)
	entity.setup(cfg)
	# 尝试加载3D模型
	var model_loaded = _apply_entity_model(entity)
	# 国家色着色：非资源、非中立实体。颜色与阵营解耦，按国家统一。
	if entity.entity_type != 0 and entity.team != RTSConfig.Team.NEUTRAL:
		var tint: Color = get_entity_color(entity)
		tint = Color(0.2 + tint.r * 0.8, 0.2 + tint.g * 0.8, 0.2 + tint.b * 0.8)
		_apply_team_tint(entity, tint)
	# 有坐骑的单位抬高模型
	if entity.entity_id in [15, 19, 34, 38] and entity.has_meta("_model_instance"):
		var mi = entity.get_meta("_model_instance")
		if is_instance_valid(mi): mi.position.y += entity.body_radius * 0.5
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
	if not is_building_unlocked(selected_building_id): return

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
	# 无论是否放置成功，都退出建造模式
	_exit_build_mode()
func _handle_right_click(event):
	# Alt+右键 → 清除驻扎点
	if Input.is_key_pressed(KEY_ALT):
		for u in selection.selected_entities:
			if u is Army and u.has_method("_clear_garrison"):
				u._clear_garrison()
			elif u is Building and u.has_method("_hide_garrison_marker"):
				u.garrison_point = Vector3.ZERO
				u._hide_garrison_marker()
		return false

	

	if selection.selected_entities.is_empty():
		_try_open_build_menu(event.position)
		return false

	# 右键空地 → 取消选择（桥：射线穿透时通过grid后备检测）
	var hit = _get_entity_under_click(event.position)
	if not hit:
		var gpos = _get_ground_pos(event.position)
		if gpos != Vector3.ZERO:
			var gg = world_to_grid(gpos)
			var found_bridge = false
			for e in entities.get_children():
				if e is Building and e.entity_id == 7 and e.health > 0:
					if world_to_grid(e.global_position) == gg:
						found_bridge = true; break
			if not found_bridge:
				selection._clear_selection()
				return false
		else:
			selection._clear_selection()
			return false

	_command_selected_units(event.position)

func _set_garrison_for_selected(screen_pos: Vector2):
	# 防御：队友单位只可查看，不允许设置驻扎点
	if selection and selection.has_method("_selection_has_teammate") and selection._selection_has_teammate():
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

func _command_selected_units(screen_pos: Vector2):
	# 防御：队友单位只可查看，任何路径都不能把命令发给队友
	if selection and selection.has_method("_selection_has_teammate") and selection._selection_has_teammate():
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
			if target:
				if target is WorldResource:
					if u.entity_id == 10 or u.entity_id == 14 or u.get("_animal_type") != "":
						u.gather_at(target)
					else:
						u.attack_move_to(target.global_position)
				elif is_hostile_to(u.team, u.owner_peer_id, target):
					# 攻击过滤：不可攻击目标（同国/盟友/中立）改为移动
					if u.has_method("_can_attack_target") and u._can_attack_target(target):
						u.attack_target(target)
					elif not (u.has_method("_is_naval_chase_target_blocked") and u._is_naval_chase_target_blocked(target)):
						u.move_to(target.global_position)
				elif u.entity_id >= 46 and u.entity_id <= 50 and target is Building:
					u._garrison_target_id = target.get_instance_id()
					u.move_to(target.global_position)
				elif u.has_method("can_soldier_garrison") and u.can_soldier_garrison(target):
					u._garrison_target_id = target.get_instance_id()
					u.move_to(target.global_position)
				else:
					u.move_to(target.global_position)
			else:
				var fp = pos
				if formation_offsets.size() > 1:
					fp = pos + formation_offsets[fi]
				u.move_to(fp)
			fi += 1

func _try_open_build_menu(screen_pos: Vector2):
	selection.selected_entities.clear()
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

func is_position_in_player_vision(world_pos: Vector3) -> bool:
	if not entities: return false
	for e in entities.get_children():
		if e is GameEntity and e.team == get_host_team() and e.health>0:
			if e.global_position.distance_to(world_pos) <= e.vision_range:
				return true
	return false

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

func _is_valid_build_position(pos: Vector3) -> bool:
	# Cannot build near enemy units (10 unit radius)
	for e in entities.get_children():
		if e is GameEntity and e.team != get_host_team() and e.team != RTSConfig.Team.NEUTRAL and e.health > 0:
			if e.global_position.distance_to(pos) < 10.0:
				return false
	var t = get_terrain_at(pos)
	# 山体不再按 terrain 或 overlay 禁止建造：是否平整由下面的 _is_terrain_flat 判断。
	# 这样可走的缓坡/台地与陡崖都统一用高度坡度规则处理。
	# 桥：只能在水上建造
	if selected_building_id == 7:
		return is_valid_bridge_position(pos)
	# 梯子：必须在敌方城墙裸露侧建造
	if selected_building_id == 8:
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
					if e is Building and e.entity_id == 27 and e.team != get_host_team() and e.team != RTSConfig.Team.NEUTRAL and e.health > 0:
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
	if selected_building_id == 23:
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
		if selected_building_id == 64:
			var on_wall = false
			for e in entities.get_children():
				if e is Building and e.entity_id == 27 and e.team == get_host_team() and e.health > 0:
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
		var cfg = EntityDatabase.get_config(selected_building_id)
		var br = cfg.get("body_radius", 1.0) if cfg else 1.0
		if not _is_terrain_flat(pos, br*0.5): return false
		return t != 2

func _place_building():
	if not build_preview or not build_preview.visible: return
	var pos = build_preview.global_position
	if not is_position_in_player_vision(pos): return
	# Cannot build near enemies
	if not _is_valid_build_position(pos): return
	# 检查城堡等级解锁
	if not is_building_unlocked(selected_building_id): return

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
	# 缩放预览模型匹配实际大小
	var target_size = effective_radius * 2.0 * RTSConfig.get_model_scale(building_id)
	var aabb = _get_model_aabb(build_preview)
	var current_size = max(aabb.size.x, max(aabb.size.y, aabb.size.z))
	if current_size > 0.01: build_preview.scale = Vector3.ONE * (target_size / current_size)
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
	if visible_grid.is_empty() or _fog_cover.is_empty():
		_init_fog_grid()
	var host_team := get_host_team()
	if host_team != _fog_host_team:
		# 换阵营/重开一局时清空一次，之后只做增量覆盖
		_init_fog_grid()
		_fog_host_team = host_team
	var current: Dictionary = {}
	for e in get_tree().get_nodes_in_group("vision_providers"):
		if not is_instance_valid(e) or e.health <= 0 or e.team != host_team:
			continue
		var g = world_to_grid(e.global_position)
		current[e.get_instance_id()] = {
			"x": g.x,
			"y": g.y,
			"r": get_effective_vision(e),
		}
	# 移除已经死亡/离开视野组的单位，先扣掉它原来的覆盖
	for id in _fog_sources.keys():
		if current.has(id):
			continue
		var old: Dictionary = _fog_sources[id]
		_fog_apply_circle(int(old["x"]), int(old["y"]), int(old["r"]), -1)
		_fog_sources.erase(id)
	# 只更新移动过或视野范围变化的单位；静止单位不再每 0.5s 重画视野圆
	for id in current.keys():
		var val: Dictionary = current[id]
		if _fog_sources.has(id):
			var old2: Dictionary = _fog_sources[id]
			if int(old2["x"]) == int(val["x"]) and int(old2["y"]) == int(val["y"]) and int(old2["r"]) == int(val["r"]):
				continue
			_fog_apply_circle(int(old2["x"]), int(old2["y"]), int(old2["r"]), -1)
		_fog_apply_circle(int(val["x"]), int(val["y"]), int(val["r"]), 1)
		_fog_sources[id] = val

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
func _show_hud_alert(msg: String, color: Color = Color(1.0, 0.2, 0.1), source_teams = -1, target_team: int = -1, alert_kind: int = 0, is_castle: bool = false, nations: Array = []):
	if color == Color(1.0, 0.2, 0.1) or color == Color(1.0, 0.8, 0.1): AudioManager.play_sfx("alert")
	if has_node("UI"):
		var hud = $UI
		if hud and hud.has_method("show_alert_message"):
			hud.show_alert_message(msg, color, source_teams, alert_kind, is_castle, nations)

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
	mark_entity_cache_dirty()
	# 废弃仓库/民居从"中立"转为"己方"，仓储与人口上限要按新队伍重算
	if site.entity_id == 22:
		update_resource_limits(team)
	elif site.entity_id == 28:
		update_population_limits()
	var loot: Dictionary = _abandoned_loot_for(site.entity_id)
	_grant_capture_loot(army, loot)
	_show_hud_alert("【废弃建筑】我方占领了%s%s" % [_abandoned_label(site.entity_id), _loot_text(loot)],
		Color(0.95, 0.85, 0.35), [team], team)
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
	game_time += delta
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

	# ---- 顶部中央两行信息：性能 + 对局信息 ----
	if _fps_label and Engine.get_process_frames() % 10 == 0:
		_ensure_cache_fresh()
		var phys_frames = Engine.get_physics_frames()
		var phys_ok = (phys_frames != _diag_physics_heartbeat)
		if not phys_ok and _diag_physics_heartbeat > 0:
			_fps_label.add_theme_color_override("font_color", Color.RED)
			_fps_label.text = "🔴 物理卡死 FPS:%.0f | 实体:%d" % [
				Engine.get_frames_per_second(), _all_entities.size()
			]
		else:
			_fps_label.add_theme_color_override("font_color", Color.LIME_GREEN)
			_fps_label.text = "FPS:%.0f | 画质:%d | 实体:%d(A%d B%d) | 物理:%d" % [
				Engine.get_frames_per_second(), _perf_quality_level,
				_all_entities.size(), _armies.size(), _buildings.size(), phys_frames
			]
		if _snap_rate_label:
			var diff_names = ["简单", "普通", "困难", "地狱"]
			var dn = diff_names[clampi(GameSettings.ai_difficulty, 0, 3)]
			var map_name := String(MapPresets.get_info(GameSettings.map_id).get("name", "经典大陆"))
			var clock := "%02d:%02d" % [int(game_time / 60.0), int(game_time) % 60]
			_snap_rate_label.text = "AI:%s | 地图:%s | 时间:%s" % [dn, map_name, clock]
		# 底板宽度跟着文字走
		_update_diag_bg(_diag_top_y, _diag_line_h)
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
# 单机大规模战斗把模拟降到 30Hz，并限制每帧追赶步数，打断“越卡越追”。
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
	if ent_count >= 420:
		_set_physics_rate_low(true)
	elif ent_count < 360:
		_set_physics_rate_low(false)

func _set_physics_rate_low(low: bool) -> void:
	if _physics_rate_low == low:
		return
	_physics_rate_low = low
	if low:
		Engine.physics_ticks_per_second = 30
		Engine.max_physics_steps_per_frame = 4
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

# 覆盖层：0=无 1=森林 2=沼泽 3=浅滩（只影响移速/视野，不改地形判定）
# 山体的可通行性不再依赖覆盖层，统一由高度坡度规则决定。
func get_overlay_at_grid(gx: int, gy: int) -> int:
	if not $Map or not $Map.has_method("get_overlay"):
		return 0
	return $Map.get_overlay(gx, gy)

# 有效视野：地图倍率 × 高地加成 × 森林遮蔽，供迷雾与可见性判定共用
func get_effective_vision(e) -> int:
	if not e:
		return 0
	var r := float(e.vision_range)
	if r <= 0.0:
		return 0
	r *= float(map_modifiers.get("vision", 1.0))
	var g := world_to_grid(e.global_position)
	var ov := get_overlay_at_grid(g.x, g.y)
	if ov == 1:
		r *= 0.55
	var hg := float(map_modifiers.get("high_ground_vision", 0.0))
	if hg > 0.0 and get_height_at_grid(g.x, g.y) >= float(map_modifiers.get("high_ground_min", 1.0)):
		r *= 1.0 + hg
	return maxi(1, int(round(r)))
# 将网格坐标 (gx, gy) 转换为世界坐标 (以地图中心为原点)
func grid_to_world(gx: int, gy: int) -> Vector3:
	return Vector3(gx - RTSConfig.MAP_SIZE / 2.0, 0, gy - RTSConfig.MAP_SIZE / 2.0)
# ==================== 快捷功能 ====================
func get_height_at_grid(gx: int, gy: int) -> float:
		if not $Map or not $Map.has_method("get_height_at_grid"):
			return 0.0
		return $Map.get_height_at_grid(gx, gy)

# 某格是否存在超过最大可走坡度的邻接台阶。用于出生点、登陆点、AI 防线等
# “能不能站/能不能过去”的判定；真正的寻路仍由 MovementController 逐边计算。
func is_cliff_tile(gx: int, gy: int) -> bool:
	var h: float = get_height_at_grid(gx, gy)
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var nx: int = gx + d.x
		var ny: int = gy + d.y
		if nx < 0 or ny < 0 or nx >= RTSConfig.MAP_SIZE or ny >= RTSConfig.MAP_SIZE:
			continue
		if RTSConfig.is_cliff_slope(get_height_at_grid(nx, ny) - h, 1.0):
			return true
	return false

# 两个世界坐标所在格之间是否是悬崖台阶。注意这不是完整路径校验，
# 只用于判断“当前点到下一落脚点”这种相邻格移动。
func is_cliff_between_world(from_pos: Vector3, to_pos: Vector3) -> bool:
	var a: Vector2i = world_to_grid(from_pos)
	var b: Vector2i = world_to_grid(to_pos)
	if a == b:
		return false
	var run: float = Vector2(float(b.x - a.x), float(b.y - a.y)).length()
	if run < 0.001:
		return false
	return RTSConfig.is_cliff_slope(get_height_at_grid(b.x, b.y) - get_height_at_grid(a.x, a.y), run)

func stop_all_gather():

	

	gather_paused = !gather_paused
	if gather_paused:
		# 暂停所有己方农民和采集船
		for entity in entities.get_children():
			if entity is Army and is_instance_valid(entity) and entity.team == get_host_team() and entity.health > 0:
				if entity.entity_id == 10 or entity.entity_id == 14:
					entity.current_target = null
					entity.current_order = ""
					entity._movement.astar_path.clear()
					entity.is_attack_moving = false
	else:
		# 恢复：让空闲农民重新寻找资源
		for entity in entities.get_children():
			if entity is Army and is_instance_valid(entity) and entity.team == get_host_team() and entity.health > 0:
				if (entity.entity_id == 10 or entity.entity_id == 14) and entity.current_order == "":
					entity._find_nearest_resource()

var hold_position_active: bool = false

func toggle_hold_position():
	hold_position_active = !hold_position_active
	if not entities: return
	for e in entities.get_children():
		if e is Army and e.team == get_host_team() and e.health > 0:
			if e.entity_id != 10 and e.entity_id != 14:
				e.hold_position = hold_position_active

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
				e.set("_garrison_target_id", best_target.get_instance_id())
				e.move_to(best_target.global_position)

func global_attack():
	var castle = get_enemy_castle_pos()
	if castle == Vector3.ZERO: return
	for e in selection.selected_entities:
		if is_instance_valid(e) and e is Army: e.attack_move_to(castle)

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

# scripts/entities/MovementController.gd
# Extracted from Army.gd — handles all movement, pathfinding, and collision separation
class_name MovementController
extends RefCounted

var _army: Army  # parent unit reference

# Movement state
var astar_path: Array = []
var astar_target: Vector3 = Vector3.ZERO
var astar_recalc_timer: float = 0.0
const ASTAR_RECALC_INTERVAL: float = 2.0
# 追击移动目标时目标位置每帧都在变；若每次变化都重算 A*（最多 1000 节点），
# 大部队交战时每帧会跑数百次寻路。按单位错峰限频，保留路径跟随和最终接近。
const ATTACK_PATH_COOLDOWN_MS: int = 700
# 追击目标在小范围内移动时继续沿用现有路径，避免每 0.5~0.7s 为每个单位重跑一次 A*
const ATTACK_TARGET_MOVE_TOLERANCE: float = 2.5
# 路径预览最多绘制多少个点，避免长路径为每个格子创建一个 MeshInstance3D。
const MAX_PATH_PREVIEW_POINTS: int = 64
var _last_attack_path_ms: int = -100000
# A* 分帧预算用：当前请求被延后时暂存目标，下一帧继续尝试。
var _pending_path: bool = false
var _pending_target: Vector3 = Vector3.ZERO
var _pending_stop_range: float = 0.0

var _path_sphere: SphereMesh = null
var _path_mat: StandardMaterial3D = null
var _path_mat_end: StandardMaterial3D = null  # green for last waypoint
# Path markers
var _path_markers: Array = []
var _is_selected: bool = false

# Collision
var collision_timer: float = 0.0
const COLLISION_INTERVAL: float = 0.15
var _last_recalc_frame: int = -99  # prevent recalc spam
var _path_cache: Dictionary = {}  # Vector2i(world_x, world_z) -> path_array, cleared on building placement
var _blacklist: Dictionary = {}  # Vector2i -> true for unreachable targets

func _init(army: Army):
	_army = army
	# 错开各单位首次碰撞分离的帧，避免几百个单位在同一物理帧集中做近邻查询
	collision_timer = randf_range(0.0, COLLISION_INTERVAL)
	# 单位死亡/离场时清理挂在 battle_manager 下的路径球。不能用
	# MovementController 的 PREDELETE 通知里再调方法，RefCounted 析构阶段方法表已不可用。
	if army != null and not army.tree_exiting.is_connected(_hide_path):
		army.tree_exiting.connect(_hide_path)

# ==================== Public API ====================

func set_selected(sel: bool):
	_is_selected = sel
	if sel:
		_show_path()
	else:
		_hide_path()

func set_move_target(pos: Vector3, stop_range: float = 0.0):
	# Use Vector2i key for fast hashing (was string "%d,%d")
	if astar_target.distance_to(pos)<0.5:return
	var key = Vector2i(int(pos.x), int(pos.z))
	if _blacklist.has(key):
		_pending_path = false
		return  # permanently blacklisted (cleared on building placement)

	var is_attack_move := stop_range > 0.0
	if is_attack_move:
		# 目标只挪动一点点时旧路径仍然可用，先不重算；等偏移超过容差或冷却到期再更新
		if astar_path.size() > 0 and astar_target != Vector3.ZERO and astar_target.distance_to(pos) < ATTACK_TARGET_MOVE_TOLERANCE:
			return
		var now_ms := Time.get_ticks_msec()
		# 首次追击按 unit id 分 16 个相位错峰，避免全军在同一帧集中跑 A*；
		# 后续只加少量抖动，保证追击路径不会滞后太久。
		var phase_ms := int(_army.get_instance_id() % 16) * 30
		var cooldown_ms := ATTACK_PATH_COOLDOWN_MS + int(_army.get_instance_id() % 5) * 15
		if _last_attack_path_ms < 0:
			_last_attack_path_ms = now_ms - cooldown_ms + phase_ms
		if now_ms - _last_attack_path_ms < cooldown_ms:
			# 注意：这里不能写 astar_target，否则下一次调用会被开头的
			# distance_to < 0.5 提前返回，永远不再生成路径。
			return
		_last_attack_path_ms = now_ms

	# Only cache normal movement (stop_range==0). Attacks recalc every time.
	#var use_cache = (stop_range == 0.0)
	#if use_cache and _path_cache.has(key):
		#astar_path = _path_cache[key]
		#if _is_selected: _show_path()
		#return
	# New target: calculate and cache. A* 受每帧预算限制，超预算时暂存到下一帧，
	# 避免全军同一帧各跑一次长路径导致操作卡顿。
	if not _try_compute_path(pos, stop_range):
		_pending_path = true
		_pending_target = pos
		_pending_stop_range = stop_range
		if not is_attack_move:
			# 普通移动命令先收起旧路径，避免短暂继续走向旧目标；追击保留旧路径。
			# 同步更新 astar_target，防止 Army 的“已到达”判断拿旧目标误清命令。
			astar_target = pos
			astar_path.clear()
			if _is_selected: _hide_path()
		return
	# 新目标已立即算完，清掉可能残留的旧 pending，避免下一帧把它重新算回来。
	_pending_path = false

func _try_compute_path(pos: Vector3, stop_range: float, bm: RTSBattleManager = null) -> bool:
	if bm == null:
		bm = _get_bm()
	if bm != null and not bm.reserve_astar_request():
		return false
	var started_usec := Time.get_ticks_usec()
	var path := _calculate_astar_path(pos, stop_range)
	if bm != null:
		bm.report_astar_cost(Time.get_ticks_usec() - started_usec)
	_apply_path(pos, path, stop_range)
	return true

func _apply_path(pos: Vector3, path: Array, stop_range: float) -> void:
	var is_attack_move := stop_range > 0.0
	astar_target = pos
	astar_path = path
	var key = Vector2i(int(pos.x), int(pos.z))
	if astar_path.size() > 0:
		if not is_attack_move:
			_path_cache[key] = astar_path
	elif is_attack_move:
		# 追击目标寻路失败时不写永久黑名单；重置目标，让冷却后还能重试
		astar_target = Vector3.ZERO
	else:
		_blacklist[key] = true
	if _is_selected: _show_path()

func _try_compute_pending_path(bm: RTSBattleManager) -> bool:
	if not _pending_path:
		return true
	if not _try_compute_path(_pending_target, _pending_stop_range, bm):
		return false
	_pending_path = false
	return true

func cancel_pending_path() -> void:
	_pending_path = false

func _get_bm() -> RTSBattleManager:
	if _army == null or not is_instance_valid(_army) or not _army.is_inside_tree():
		return null
	return _army.get_tree().get_first_node_in_group("battle_manager") as RTSBattleManager

func recalculate():
	
	_path_cache.clear()  # new building may block cached paths
	_blacklist.clear()  # new building may open paths
	_last_attack_path_ms = -100000  # 建筑变化后允许立即重算追击路径
	# building recalc - cached paths cleared
	if astar_target != Vector3.ZERO and _army.current_order == "move":
		var key = Vector2i(int(astar_target.x), int(astar_target.z))
		_path_cache.erase(key)
		astar_path = _calculate_astar_path(astar_target)
		_pending_path = false
		if astar_path.size() > 0: _path_cache[key] = astar_path  # only cache valid paths
		if _is_selected:
			_show_path()

func get_current_target() -> Vector3:
	if is_instance_valid(_army.current_target):
		return _army.current_target.global_position
	if _army.is_attack_moving:
		return _army.attack_move_target
	if _army._order_is(_army.UnitState.MOVING):
		return astar_target
	return Vector3.ZERO

func stop():
	astar_path.clear()
	astar_target = Vector3.ZERO
	_pending_path = false
	_stop_velocity()

# 单位停止/进入攻击距离后必须把残留速度清零，否则 Army 的 simple_idle 永远不成立，
# 后期几百个已经停下的单位仍会每 0.15~0.22 秒做一次碰撞近邻查询。
func _stop_velocity() -> void:
	if _army != null:
		_army.velocity = Vector3.ZERO

# ==================== Main movement update ====================

func process_move(delta, bm: RTSBattleManager):
	# 之前因 A* 预算被延后的目标，继续在本帧尝试；仍未轮到则原地等待，
	# 不能拿旧路径继续走，否则大部队下令后会先朝旧目标移动。
	if _pending_path:
		if not _army.is_attack_moving and not _army._order_is(_army.UnitState.MOVING):
			_pending_path = false
		elif not _try_compute_pending_path(bm):
			_stop_velocity()
			return
	if not _army.can_move or _army.speed <= 0:
		_stop_velocity()
		return
	if _army.hold_position and _army.target_type != 0:
		_stop_velocity()
		return

	# Stop if at gather/attack range of target
	if _army.current_target and is_instance_valid(_army.current_target):
		var target_radius = 0.0
		if _army.current_target is GameEntity:
			target_radius = _army.current_target.body_radius
		var h_diff = Vector2(_army.global_position.x - _army.current_target.global_position.x,
			_army.global_position.z - _army.current_target.global_position.z)
		var h_dist = h_diff.length() - _army.body_radius - target_radius
		if _army.current_target is WorldResource and h_dist <= 0.5:
			_stop_velocity()
			return
		elif _army.current_target is GameEntity and h_dist <= _army.attack_range:
			_stop_velocity()
			return

	var target_pos = get_current_target()
	if target_pos == Vector3.ZERO:
		_stop_velocity()
		return

	# Follow A* path
	var move_target = target_pos
	# No A* path = no movement, unless close to target (final approach)
	if astar_path.size() == 0:
		if astar_target.distance_squared_to(_army.global_position) > 3.0:
			_stop_velocity()
			return  # too far, no path → stay put
		# Close enough: allow final approach to exact target

	if astar_path.size() > 0:
		move_target = astar_path[0]
		var h_dist = Vector2(move_target.x - _army.global_position.x, move_target.z - _army.global_position.z)
		if h_dist.length() < 0.5:
			astar_path.pop_front()
			# 不要每经过一个航点就重建全部路径球：选中大部队时这一步会瞬间
			# 创建/销毁数千个 MeshInstance3D。只在路径走完时收起预览，换目标时
			# 由 set_move_target()/recalculate() 重新生成。
			if astar_path.is_empty() and _is_selected:
				_hide_path()
			if astar_path.size() > 0:
				move_target = astar_path[0]
	# Build horizontal direction
	var horizontal_target = Vector3(move_target.x, _army.global_position.y, move_target.z)
	var move_dir = (horizontal_target - _army.global_position).normalized()
	if move_dir.length() < 0.01:
		_stop_velocity()
		return

	

	## Mountain avoidance: deflect if next step is impassable
	#var next_pos = _army.global_position + move_dir * _army.speed * 0.016
	#if bm and not _army.water_capable:
		#var terr = bm.get_terrain_at(next_pos)
		#if terr == 1:
			#var alt = move_dir.rotated(Vector3.UP, deg_to_rad(45))
			#next_pos = _army.global_position + alt * _army.speed * 0.016
			#if bm.get_terrain_at(next_pos) == 1:
				#alt = move_dir.rotated(Vector3.UP, deg_to_rad(-90))
				#next_pos = _army.global_position + alt * _army.speed * 0.016
				#if bm.get_terrain_at(next_pos) == 1: return
			#move_dir = alt
	_army.velocity = Vector3(move_dir.x, 0, move_dir.z) * _army.speed
	_army.move_and_slide()
	# Movement sounds (every 10 frames, when actually moving)
	if _army.speed > 0.1 and Engine.get_process_frames() % 40 == 0:
		var terr = bm.get_terrain_at(_army.global_position) if bm else 0
		if terr == 2:
			_army._play_sfx_if_visible("sail")
		else:
			_army._play_sfx_if_visible("walk")

	# Rotate toward movement direction
	if move_dir.length() > 0.01:
		var look_target = _army.global_position + move_dir
		_army.look_at(Vector3(look_target.x, _army.global_position.y, look_target.z), Vector3.UP)

	# Boundary clamp
	var half_map = RTSConfig.MAP_SIZE / 2.0
	_army.global_position.x = clamp(_army.global_position.x, -half_map, half_map)
	_army.global_position.z = clamp(_army.global_position.z, -half_map, half_map)

	# Terrain height smoothing
	if bm:
		var map = bm.get_node("Map")
		if map and map.has_method("get_height_at"):
			var target_height = map.get_height_at(_army.global_position)
			# Climb friendly walls + laddered enemy walls (O(1) 墙体网格查询，替代每帧全量遍历)
			var gpos2 = bm.world_to_grid(_army.global_position)
			var wall_b = bm._wall_entity_grid.get(gpos2)
			if wall_b:
				if wall_b.team == _army.team:
					target_height += 4.5  # friendly wall
				elif _has_adjacent_ladder(bm, gpos2, _army.team):
					target_height += 4.5  # laddered enemy wall
			_army.global_position.y = move_toward(_army.global_position.y, target_height, 5.0 * delta)

# ==================== Collision separation ====================

func apply_collision(delta):
	var bm = _army._get_bm()
	if bm == null:
		return
	# 单位碰撞只需要极近的邻居，过去固定查 5 格会把密集人群整片返回；
	# 建筑中心半径较大，单独走建筑桶查询，避免为了命中建筑而扫描周围所有单位。
	var near_range: float = maxf(_army.body_radius * 2.0 + 0.8, 1.2)
	var entities_nearby: Array = bm.get_nearby_entities(_army.global_position, near_range)
	var buildings_nearby: Array = []
	if bm.has_method("get_nearby_buildings"):
		buildings_nearby = bm.get_nearby_buildings(_army.global_position, _army.body_radius + 5.0)
	else:
		buildings_nearby = bm._buildings
	for entity in entities_nearby:
		if entity == _army or not is_instance_valid(entity): continue
		if not (entity is GameEntity) or entity.health <= 0: continue
		if entity is Building or entity is WorldResource: continue
		_separate_from(entity, delta)
	for entity in buildings_nearby:
		if entity == _army or not is_instance_valid(entity): continue
		if not (entity is Building) or entity.health <= 0: continue
		if entity.entity_id == 7: continue  # 桥不阻挡通行
		if entity.entity_id == 27 and entity.team == _army.team: continue  # pass through friendly walls
		if entity.entity_id == 27 and entity.team != _army.team:
			if _has_adjacent_ladder(bm, bm.world_to_grid(entity.global_position), _army.team): continue  # pass through laddered enemy walls
		_separate_from(entity, delta)

func _separate_from(entity: GameEntity, delta: float) -> void:
	var dist = _army.global_position.distance_to(entity.global_position)
	var min_dist = _army.body_radius + entity.body_radius
	if dist < min_dist and dist > 0.001:
		var overlap = min_dist - dist
		var push_dir = (_army.global_position - entity.global_position).normalized()
		var push_s = 10.0 if entity is Building and entity.entity_id == 27 and entity.team != _army.team else 15.0 if entity is Building else 5.0
		_army.global_position += push_dir * overlap * min(push_s * delta, 0.95)
	elif dist < 0.001:
		_army.global_position += Vector3(randf_range(-0.2, 0.2), 0, randf_range(-0.2, 0.2))

func _path_height(wp: Vector3, bm) -> float:
	if bm.has_node("Map") and bm.get_node("Map").has_method("get_height_at"):
		return bm.get_node("Map").get_height_at(wp)
	if bm.has_method("get_height_at_grid"):
		var g = bm.world_to_grid(wp)
		return bm.get_height_at_grid(g.x, g.y)
	return 0.0

# ==================== Path markers ====================

func _show_path():
	if not _path_sphere:
		_path_sphere = SphereMesh.new()
		_path_sphere.radius = 0.2; _path_sphere.height = 0.4
	if not _path_mat:
		_path_mat = StandardMaterial3D.new()
		_path_mat.albedo_color = Color(0, 1, 1, 0.8)
		if not _path_mat_end:
			_path_mat_end = StandardMaterial3D.new()
			_path_mat_end.albedo_color = Color(0, 1, 0, 0.8)  # green
			_path_mat_end.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_path_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_hide_path()
	if astar_path.size() < 2: return
	var bm = _army.get_tree().get_first_node_in_group("battle_manager")

	if not bm: return
	# 框选大部队时只为第一个选中单位绘制路径，避免几十/上百条路径同时生成。
	if bm.selection != null and bm.selection.selected_entities.size() > 1:
		if bm.selection.selected_entities[0] != _army:
			return
	# 单条长路径也不逐格创建，按固定上限抽样；尾点始终保留。
	var points: Array = []
	if astar_path.size() <= MAX_PATH_PREVIEW_POINTS:
		points = astar_path
	else:
		var step: float = float(astar_path.size() - 1) / float(MAX_PATH_PREVIEW_POINTS - 1)
		for i in range(MAX_PATH_PREVIEW_POINTS):
			points.append(astar_path[int(round(float(i) * step))])
	var last_wp: Vector3 = astar_path[astar_path.size() - 1]
	for wp in points:
		var m = MeshInstance3D.new()
		m.mesh = _path_sphere
		m.position = Vector3(wp.x, _path_height(wp, bm) + 0.3, wp.z)
		# 路径点只是操作提示，不参与阴影投射，避免额外 shadow pass。
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# Last waypoint is green
		if wp == last_wp:
			m.material_override = _path_mat_end
		else:
			m.material_override = _path_mat
		bm.add_child(m)
		_path_markers.append(m)

func _hide_path():
	for m in _path_markers:
		if is_instance_valid(m): m.queue_free()
	_path_markers.clear()

# ==================== A* Pathfinding (optimized) ====================

# Min-heap priority queue — O(log n) push/pop vs O(n) linear scan
class MinHeap extends RefCounted:
	var _data: Array = []  # [{tile: Vector2i, f: float}, ...]

	func size() -> int: return _data.size()
	func is_empty() -> bool: return _data.is_empty()

	func push(tile: Vector2i, f: float):
		_data.append({"tile": tile, "f": f})
		_sift_up(_data.size() - 1)

	func pop() -> Dictionary:
		if _data.is_empty(): return {}
		var result = _data[0]
		var last = _data.pop_back()
		if not _data.is_empty():
			_data[0] = last
			_sift_down(0)
		return result

	func _sift_up(idx: int):
		while idx > 0:
			var parent = (idx - 1) / 2
			if _data[idx].f >= _data[parent].f: break
			var tmp = _data[idx]; _data[idx] = _data[parent]; _data[parent] = tmp
			idx = parent

	func _sift_down(idx: int):
		var sz = _data.size()
		while true:
			var smallest = idx
			var left = 2 * idx + 1; var right = 2 * idx + 2
			if left < sz and _data[left].f < _data[smallest].f: smallest = left
			if right < sz and _data[right].f < _data[smallest].f: smallest = right
			if smallest == idx: break
			var tmp = _data[idx]; _data[idx] = _data[smallest]; _data[smallest] = tmp
			idx = smallest

# Shared wall cache — keyed by (bm_id, wall_cache_version, team).
# Stationary entities (buildings + resources) only move on build/destroy, so the
# wall set is rebuilt only when the battle manager's entity cache version bumps
# (NOT per frame, NOT per target — `end_tile` no longer invalidates it; the A*
# loop already skips wall checks for the goal tile).
static var _wall_set: Dictionary = {}    # Vector2i -> true
static var _wall_ver: int = -1
static var _wall_bm_id: int = -1
static var _wall_team: int = -1  # friendly-wall passability is team-dependent
static var _bridge_set: Dictionary = {}          # 桥所在格子
static var _ladder_set: Dictionary = {}          # 梯子使该敌方城墙格可通行
static var _transport_water: Dictionary = {}     # 运载船周围3格水域(陆军可通行)
static var _transport_frame: int = -1            # 运载船是移动的，水域标记单独做帧级缓存
static var _transport_team: int = -1

func _calculate_astar_path(target_pos: Vector3, stop_range: float = 0.0) -> Array:
	var bm = _army._get_bm() as RTSBattleManager
	if not bm: return []
	var start = _army.global_position
	var start_tile = bm.world_to_grid(start)
	var end_tile = bm.world_to_grid(target_pos)

	if start_tile == end_tile and stop_range <= 0: return []

	# 静态墙集合按实体缓存版本号重建（建造/摧毁时才变化），运载船水域单独做帧级缓存
	var frame = Engine.get_process_frames()
	var bm_id = bm.get_instance_id()
	if _wall_bm_id != bm_id or _wall_ver != bm._wall_cache_version or _wall_team != _army.team:
		_wall_set.clear()
		_bridge_set.clear()
		_ladder_set.clear()
		for e in bm.entities.get_children():
			if not (e is GameEntity) or e.health <= 0: continue
			if not (e is Building or e is WorldResource): continue
			var eg = bm.world_to_grid(e.global_position)
			# 桥不阻挡通行，单独记录
			if e is Building and e.entity_id == 7:
				_bridge_set[eg] = true
				continue
			# 梯子不阻挡通行，且使其相邻敌方城墙可通行
			if e is Building and e.entity_id == 8:
				# 标记梯子相邻的敌方城墙格为可通行（O(8) 查墙体网格，替代 O(8×n) 全量扫描）
				for dx in range(-1, 2):
					for dy in range(-1, 2):
						if dx == 0 and dy == 0: continue
						var wall_b = bm._wall_entity_grid.get(Vector2i(eg.x + dx, eg.y + dy))
						if wall_b and wall_b.team != _army.team:
							_ladder_set[Vector2i(eg.x + dx, eg.y + dy)] = true
				continue
			if e is Building and e.entity_id == 27 and e.team == _army.team: continue
			_wall_set[eg] = true
		_wall_bm_id = bm_id; _wall_ver = bm._wall_cache_version; _wall_team = _army.team
	# 运载船会移动：水域标记做帧级缓存（同一帧多个单位寻路只算一次）
	if _transport_frame != frame or _transport_team != _army.team:
		_transport_water.clear()
		for e in bm.entities.get_children():
			if e is Army and e.entity_id == 9 and e.health > 0 and e.team == _army.team:
				var tg = bm.world_to_grid(e.global_position)
				for rdx in range(-3, 4):
					for rdy in range(-3, 4):
						var tx = tg.x + rdx; var ty = tg.y + rdy
						if tx >= 0 and tx < RTSConfig.MAP_SIZE and ty >= 0 and ty < RTSConfig.MAP_SIZE:
							if bm.get_terrain_at_grid(tx, ty) == 2:
								_transport_water[Vector2i(tx, ty)] = true
		_transport_frame = frame; _transport_team = _army.team
	var wall_cache = _wall_set

	# A* data structures — Vector2i keys (fast int hash, no string allocs)
	var open_list = MinHeap.new()
	var closed_set := {}  # Vector2i -> true
	var g_score := {}     # Vector2i -> float
	var came_from := {}   # Vector2i -> Vector2i

	g_score[start_tile] = 0.0
	open_list.push(start_tile, _heuristic(start_tile, end_tile) * 1.2)

	var max_nodes: int = 1000
	# 固定 1000 节点在 100×100 地图上不够跨河：桥头堡等地图的浅滩偏离起点/终点连线时，
	# A* 会沿着河岸展开 1500~1800 个节点才找到渡口，旧上限会提前返回空路径。
	# 表现就是 AI 部队堵在集结点、永远不发起进攻。按起终点距离放宽预算，同时保留硬上限。
	# 150×150 的 2v2/3v3 河图上，双河/海湾类地图的绕行更远（实测最坏约 12k 节点），
	# 因此预算与上限相应上调；普通短距离寻路命中节点数不变，不影响常规性能。
	var tile_span: int = absi(start_tile.x - end_tile.x) + absi(start_tile.y - end_tile.y)
	max_nodes = clampi(2000 + tile_span * 80, 2000, 12000)
	var nodes_explored := 0
	var from_height := _get_tile_height(start_tile, bm)

	while not open_list.is_empty() and nodes_explored < max_nodes:
		var current_entry = open_list.pop()
		if current_entry.is_empty(): break
		var cur_tile: Vector2i = current_entry.tile
		nodes_explored += 1

		# Goal checks
		if stop_range > 0:
			if abs(cur_tile.x - end_tile.x) <= stop_range and abs(cur_tile.y - end_tile.y) <= stop_range:
				var path2 = _reconstruct_path(came_from, cur_tile)
				if path2.size() > 1: path2.pop_front()
				return path2
		if cur_tile == end_tile:
			var path = _reconstruct_path(came_from, cur_tile)
			if path.size() > 1: path.pop_front()
			return path

		closed_set[cur_tile] = true
		var cur_g = g_score.get(cur_tile, 9999.0)
		from_height = _get_tile_height(cur_tile, bm)

		# 8-neighbor expansion — merged terrain+wall+slope check
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				if dx == 0 and dy == 0: continue
				var neighbor = Vector2i(cur_tile.x + dx, cur_tile.y + dy)
				if neighbor.x < 0 or neighbor.x >= RTSConfig.MAP_SIZE or neighbor.y < 0 or neighbor.y >= RTSConfig.MAP_SIZE: continue
				if closed_set.has(neighbor): continue

				# Single terrain cost lookup (merged passability + cost, was 2-3 calls)
				var terrain_cost = _get_terrain_cost(neighbor, bm, wall_cache)
				if terrain_cost >= 999.0: continue

				# Slope check (was in separate _can_traverse call)
				var neighbor_h = _get_tile_height(neighbor, bm)
				if abs(neighbor_h - from_height) > 3.0: continue

				# Wall collision (skip for goal tile — allow reaching target)
				if neighbor != end_tile and wall_cache.has(neighbor) and not _ladder_set.has(neighbor): continue

				var step_cost = terrain_cost * (1.414 if (dx != 0 and dy != 0) else 1.0)
				var tentative_g = cur_g + step_cost

				if tentative_g < g_score.get(neighbor, 9999.0):
					came_from[neighbor] = cur_tile
					g_score[neighbor] = tentative_g
					open_list.push(neighbor, tentative_g + _heuristic(neighbor, end_tile) * 1.2)

	return []

func _heuristic(a: Vector2i, b: Vector2i) -> float:
	return abs(a.x - b.x) + abs(a.y - b.y)

func _get_terrain_cost(tile: Vector2i, bm: RTSBattleManager, wall_cache: Dictionary) -> float:
	# 梯子使敌方城墙可通行
	if _ladder_set.has(tile): return 3.0
	# 普通建筑/资源阻挡
	if wall_cache.has(tile): return 5.0
	var terrain = bm.get_terrain_at_grid(tile.x, tile.y)
	if _army.water_capable:
		# 水军无法通过桥
		return 999.0 if _bridge_set.has(tile) else (0.8 if terrain == 2 else 999.0)
	# 浅滩：仍是水格，但陆军可以涉水通过；沼泽：陆地但泥泞难行（成本高于平原、低于山地）
	var ov := bm.get_overlay_at_grid(tile.x, tile.y)
	if ov == 3:
		return 2.5
	if ov == 2:
		return 1.8
	match terrain:
		0: return 1.0
		1: return 2.5
		2: return 1.5 if _bridge_set.has(tile) or _transport_water.has(tile) else 999.0
	return 999.0

func _get_tile_height(tile: Vector2i, bm: RTSBattleManager) -> float:
	if bm and bm.has_method("get_height_at_grid"):
		return bm.get_height_at_grid(tile.x, tile.y)
	return 0.0

func _reconstruct_path(came_from: Dictionary, end_tile: Vector2i) -> Array:
	# Use append + reverse instead of push_front (O(1) per step vs O(n))
	var path := []
	var current = end_tile
	var half = RTSConfig.MAP_SIZE / 2.0
	path.append(Vector3(current.x - half, 0, current.y - half))
	# 远距离/绕河路径可能超过 200 格，必须按实际 came_from 链回溯，不能截断
	for _i in range(RTSConfig.MAP_SIZE * 4):
		if not came_from.has(current): break
		current = came_from[current]
		path.append(Vector3(current.x - half, 0, current.y - half))
	path.reverse()
	return path

# 检查指定城墙格是否有己方梯子相邻（O(8) 查梯子网格，替代 O(8×n) 全量扫描）
func _has_adjacent_ladder(bm: RTSBattleManager, wall_tile: Vector2i, my_team: int) -> bool:
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			if dx == 0 and dy == 0: continue
			var ladder_b = bm._ladder_entity_grid.get(Vector2i(wall_tile.x + dx, wall_tile.y + dy))
			if ladder_b and ladder_b.health > 0 and ladder_b.team == my_team:
				return true
	return false

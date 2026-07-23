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
		return  # permanently blacklisted (cleared on building placement)

	# Only cache normal movement (stop_range==0). Attacks recalc every time.
	#var use_cache = (stop_range == 0.0)
	#if use_cache and _path_cache.has(key):
		#astar_path = _path_cache[key]
		#if _is_selected: _show_path()
		#return
	# New target: calculate and cache
	astar_target = pos
	astar_path = _calculate_astar_path(pos, stop_range)
	if astar_path.size() > 0:
		_path_cache[key] = astar_path
	else:
		_blacklist[key] = true
	if _is_selected: _show_path()

func recalculate():
	
	_path_cache.clear()  # new building may block cached paths
	_blacklist.clear()  # new building may open paths
	# building recalc - cached paths cleared
	if astar_target != Vector3.ZERO and _army.current_order == "move":
		var key = Vector2i(int(astar_target.x), int(astar_target.z))
		_path_cache.erase(key)
		astar_path = _calculate_astar_path(astar_target)
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

# ==================== Main movement update ====================

func process_move(delta, bm: RTSBattleManager):
	if not _army.can_move or _army.speed <= 0:
		return
	if _army.hold_position and _army.target_type != 0:
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
			return
		elif _army.current_target is GameEntity and h_dist <= _army.attack_range:
			return

	var target_pos = get_current_target()
	if target_pos == Vector3.ZERO:
		return

	# Follow A* path
	var move_target = target_pos
	# No A* path = no movement, unless close to target (final approach)
	if astar_path.size() == 0:
		if astar_target.distance_squared_to(_army.global_position) > 3.0:
			return  # too far, no path → stay put
		# Close enough: allow final approach to exact target

	if astar_path.size() > 0:
		move_target = astar_path[0]
		var h_dist = Vector2(move_target.x - _army.global_position.x, move_target.z - _army.global_position.z)
		if h_dist.length() < 0.5:
			astar_path.pop_front()
			if _is_selected: _show_path()
			if astar_path.size() > 0:
				move_target = astar_path[0]
	# Build horizontal direction
	var horizontal_target = Vector3(move_target.x, _army.global_position.y, move_target.z)
	var move_dir = (horizontal_target - _army.global_position).normalized()
	if move_dir.length() < 0.01:
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
			# Climb friendly walls + laddered enemy walls
			var gpos2 = bm.world_to_grid(_army.global_position)
			for e in bm.entities.get_children():
				if e is Building and e.entity_id == 27 and e.health > 0:
					var wg = bm.world_to_grid(e.global_position)
					if wg.x == gpos2.x and wg.y == gpos2.y:
						if e.team == _army.team:
							target_height += 4.5; break  # friendly wall
						elif _has_adjacent_ladder(bm, wg, _army.team):
							target_height += 4.5; break  # laddered enemy wall
			_army.global_position.y = move_toward(_army.global_position.y, target_height, 5.0 * delta)

# ==================== Collision separation ====================

func apply_collision(delta):
	var bm = _army._get_bm()
	var entities_nearby = bm.get_nearby_entities(_army.global_position, 5.0) if bm else _army.get_tree().get_nodes_in_group("entities")
	for entity in entities_nearby:
		if entity == _army or not is_instance_valid(entity): continue
		if not (entity is GameEntity) or entity.health <= 0: continue
		if entity is WorldResource: continue
		if entity is Building and entity.entity_id == 7: continue  # 桥不阻挡通行
		if entity is Building and entity.entity_id == 27 and entity.team == _army.team: continue  # pass through friendly walls
		if entity is Building and entity.entity_id == 27 and entity.team != _army.team:
			if _has_adjacent_ladder(bm, bm.world_to_grid(entity.global_position), _army.team): continue  # pass through laddered enemy walls

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
	for wp in astar_path:
		var m = MeshInstance3D.new()
		m.mesh = _path_sphere
		m.position = Vector3(wp.x, _path_height(wp, bm) + 0.3, wp.z)
		# Last waypoint is green
		if wp == astar_path[astar_path.size() - 1]:
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

# Shared frame-level wall cache — keyed by (frame, bm_id, team, exclude_tile).
# Only blocks stationary entities (buildings + resources), not armies.
# Armies use collision separation for local avoidance.
static var _wall_set: Dictionary = {}    # Vector2i -> true
static var _wall_exclude: Vector2i = Vector2i(-999, -999)
static var _wall_frame: int = -1
static var _wall_bm_id: int = -1
static var _wall_team: int = -1  # friendly-wall passability is team-dependent
static var _bridge_set: Dictionary = {}          # 桥所在格子
static var _ladder_set: Dictionary = {}          # 梯子使该敌方城墙格可通行
static var _transport_water: Dictionary = {}     # 运载船周围3格水域(陆军可通行)

func _calculate_astar_path(target_pos: Vector3, stop_range: float = 0.0) -> Array:
	var _pt = Time.get_ticks_usec()
	var bm = _army.get_tree().get_first_node_in_group("battle_manager") as RTSBattleManager
	if not bm: return []
	var start = _army.global_position
	var start_tile = bm.world_to_grid(start)
	var end_tile = bm.world_to_grid(target_pos)

	if start_tile == end_tile and stop_range <= 0: return []

	# Build shared wall cache once per frame (only buildings + resources — stationary)
	var frame = Engine.get_process_frames()
	var bm_id = bm.get_instance_id()
	if _wall_frame != frame or _wall_bm_id != bm_id or _wall_team != _army.team or _wall_exclude != end_tile:
		_wall_set.clear()
		_bridge_set.clear()
		_ladder_set.clear()
		_transport_water.clear()
		# 运载船：周围3格水域标记为陆军可通行
		for e in bm.entities.get_children():
			if e is Army and e.entity_id == 9 and e.health > 0 and e.team == _army.team:
				var tg = bm.world_to_grid(e.global_position)
				for rdx in range(-3, 4):
					for rdy in range(-3, 4):
						var tx = tg.x + rdx; var ty = tg.y + rdy
						if tx >= 0 and tx < RTSConfig.MAP_SIZE and ty >= 0 and ty < RTSConfig.MAP_SIZE:
							if bm.get_terrain_at_grid(tx, ty) == 2:
								_transport_water[Vector2i(tx, ty)] = true
		for e in bm.entities.get_children():
			if not (e is GameEntity) or e.health <= 0: continue
			if not (e is Building or e is WorldResource): continue
			var eg = bm.world_to_grid(e.global_position)
			if eg == end_tile: continue
			# 桥不阻挡通行，单独记录
			if e is Building and e.entity_id == 7:
				_bridge_set[eg] = true
				continue
			# 梯子不阻挡通行，且使其相邻敌方城墙可通行
			if e is Building and e.entity_id == 8:
				# 标记梯子相邻的敌方城墙格为可通行
				for dx in range(-1, 2):
					for dy in range(-1, 2):
						if dx == 0 and dy == 0: continue
						var nx = eg.x + dx; var ny = eg.y + dy
						if nx < 0 or nx >= RTSConfig.MAP_SIZE or ny < 0 or ny >= RTSConfig.MAP_SIZE: continue
						# 检查相邻格是否有敌方城墙
						for e2 in bm.entities.get_children():
							if e2 is Building and e2.entity_id == 27 and e2.team != _army.team and e2.health > 0:
								var wg = bm.world_to_grid(e2.global_position)
								if wg.x == nx and wg.y == ny:
									_ladder_set[wg] = true
				continue
			if e is Building and e.entity_id == 27 and e.team == _army.team: continue
			_wall_set[eg] = true
		_wall_frame = frame; _wall_bm_id = bm_id; _wall_team = _army.team; _wall_exclude = end_tile
	var wall_cache = _wall_set

	# A* data structures — Vector2i keys (fast int hash, no string allocs)
	var open_list = MinHeap.new()
	var closed_set := {}  # Vector2i -> true
	var g_score := {}     # Vector2i -> float
	var came_from := {}   # Vector2i -> Vector2i

	g_score[start_tile] = 0.0
	open_list.push(start_tile, _heuristic(start_tile, end_tile) * 1.2)

	var max_nodes = 1000; var nodes_explored = 0
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

	var _elapsed = (Time.get_ticks_usec() - _pt) / 1000.0
	if _elapsed > 3.0 or Engine.get_process_frames() % 120 == 0:
		var gm = _army.get_tree().get_first_node_in_group("battle_manager")
		var gt = gm.game_time if gm else 0.0
		print("[A*] t=%.1fs elapsed=%.1fms nodes=%d" % [gt, _elapsed, nodes_explored])
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
	for _i in range(200):
		if not came_from.has(current): break
		current = came_from[current]
		path.append(Vector3(current.x - half, 0, current.y - half))
	path.reverse()
	return path

# 检查指定城墙格是否有己方梯子相邻
func _has_adjacent_ladder(bm: RTSBattleManager, wall_tile: Vector2i, my_team: int) -> bool:
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			if dx == 0 and dy == 0: continue
			for e in bm.entities.get_children():
				if e is Building and e.entity_id == 8 and e.health > 0 and e.team == my_team:
					var lt = bm.world_to_grid(e.global_position)
					if lt.x == wall_tile.x + dx and lt.y == wall_tile.y + dy:
						return true
	return false

class_name AISituation
extends RefCounted

const SimTime = preload("res://scripts/core/SimTime.gd")

# P2 世界模型（影子版）：一次扫描，产出本帧只读快照。
#
# 现阶段不接管任何决策，只做四件事：
#  1. 用**单次遍历**产出 AI 需要的分类视图（本方/敌方、农民/陆军/建筑/主城）；
#  2. 空间索引：按网格分桶敌军与资源点，供"附近敌人/最近资源"这类高频查询；
#  3. 敌军可见性（可选，低频）：只有对账时才计算，避免每轮 refresh 都做视野判定；
#  4. 记录快照构建耗时 + 与 count_* 对账，作为影子迁移的验收依据。
#
# 后续 P2 正式切换时，Planner/Director 改为只读本快照，不再各自遍历 battle._armies。

const CELL_SIZE: float = 8.0

var valid: bool = false
var stamp_time: float = 0.0
var stamp_frame: int = 0
var cost_usec: int = 0
var visibility_usec: int = 0

var own_armies: Array = []
var enemy_armies: Array = []
var own_buildings: Array = []
var enemy_buildings: Array = []
var own_buildings_by_id: Dictionary = {}

var own_land_count: int = 0
var own_worker_count: int = 0
var own_military_count: int = 0
var enemy_land_count: int = 0
var enemy_worker_count: int = 0
var enemy_building_count: int = 0
var own_castle = null
var enemy_castle = null

# 资源点与可见敌军
var resource_count: int = 0
var visible_enemies: Array = []

var _enemy_grid: Dictionary = {}
var _resource_grid: Dictionary = {}
var _resource_by_kind: Dictionary = {}

static func _cell_key(pos: Vector3) -> Vector2i:
	return Vector2i(int(floor(pos.x / CELL_SIZE)), int(floor(pos.z / CELL_SIZE)))

func _grid_insert(grid: Dictionary, pos: Vector3, e) -> void:
	var k: Vector2i = _cell_key(pos)
	var arr: Array = grid.get(k, [])
	arr.append(e)
	grid[k] = arr

# 与 AI.count_land_army() 完全一致的口径：活着、本方、非农民、attack > 0、非侦察、非海军。
func refresh(ai, compute_visibility: bool = false, index_resources: bool = false) -> void:
	var t0: int = Time.get_ticks_usec()
	own_armies.clear()
	enemy_armies.clear()
	own_buildings.clear()
	enemy_buildings.clear()
	own_buildings_by_id.clear()
	_enemy_grid.clear()
	_resource_grid.clear()
	_resource_by_kind.clear()
	visible_enemies.clear()
	own_land_count = 0
	own_worker_count = 0
	own_military_count = 0
	enemy_land_count = 0
	enemy_worker_count = 0
	enemy_building_count = 0
	resource_count = 0
	own_castle = null
	enemy_castle = null
	valid = false
	visibility_usec = 0
	if ai == null or ai.battle == null:
		cost_usec = Time.get_ticks_usec() - t0
		return
	var battle = ai.battle
	if battle.has_method("_ensure_cache_fresh"):
		battle._ensure_cache_fresh()
	for e in battle._armies:
		if not is_instance_valid(e) or e.health <= 0:
			continue
		var mine: bool = ai.entity_belongs_to_me(e)
		if mine:
			own_armies.append(e)
			if int(e.entity_id) == 10:
				own_worker_count += 1
			else:
				own_military_count += 1
				if int(e.attack) > 0 and not bool(e.water_capable) and not ai._is_scout_unit(e):
					own_land_count += 1
		else:
			enemy_armies.append(e)
			_grid_insert(_enemy_grid, e.global_position, e)
			if int(e.entity_id) == 10:
				enemy_worker_count += 1
			elif int(e.attack) > 0 and not bool(e.water_capable):
				enemy_land_count += 1
	for b in battle._buildings:
		if not is_instance_valid(b) or b.health <= 0:
			continue
		if ai.entity_belongs_to_me(b):
			own_buildings.append(b)
			var bid: int = int(b.entity_id)
			own_buildings_by_id[bid] = int(own_buildings_by_id.get(bid, 0)) + 1
			if bid == 20 and own_castle == null:
				own_castle = b
		else:
			enemy_buildings.append(b)
			enemy_building_count += 1
			_grid_insert(_enemy_grid, b.global_position, b)
			if int(b.entity_id) == 20 and enemy_castle == null:
				enemy_castle = b
	if index_resources:
		_index_resources(battle)
	stamp_time = float(battle.game_time)
	stamp_frame = SimTime.frame()
	valid = true
	cost_usec = Time.get_ticks_usec() - t0
	if compute_visibility:
		_compute_visibility(ai, battle)

# 可见性只在低频对账时算：以本方主城（没有则第一支本方部队）为观察者。
func _compute_visibility(ai, battle) -> void:
	var t0: int = Time.get_ticks_usec()
	var observer = own_castle
	if observer == null and not own_armies.is_empty():
		observer = own_armies[0]
	if observer != null and battle.has_method("is_target_visible_from"):
		for e in enemy_armies:
			if battle.is_target_visible_from(observer, e):
				visible_enemies.append(e)
	visibility_usec = Time.get_ticks_usec() - t0

func count_building(id: int) -> int:
	return int(own_buildings_by_id.get(id, 0))

func enemies_within(pos: Vector3, radius: float) -> Array:
	var out: Array = []
	if radius <= 0.0:
		return out
	var r2: float = radius * radius
	var cx0: int = int(floor((pos.x - radius) / CELL_SIZE))
	var cx1: int = int(floor((pos.x + radius) / CELL_SIZE))
	var cz0: int = int(floor((pos.z - radius) / CELL_SIZE))
	var cz1: int = int(floor((pos.z + radius) / CELL_SIZE))
	for cx in range(cx0, cx1 + 1):
		for cz in range(cz0, cz1 + 1):
			var arr: Array = _enemy_grid.get(Vector2i(cx, cz), [])
			for e in arr:
				if is_instance_valid(e) and e.global_position.distance_squared_to(pos) <= r2:
					out.append(e)
	return out

func enemies_within_count(pos: Vector3, radius: float) -> int:
	return enemies_within(pos, radius).size()

func nearest_enemy(pos: Vector3, max_dist: float = 40.0):
	var best = null
	var best_d: float = max_dist
	for e in enemies_within(pos, max_dist):
		var d: float = pos.distance_to(e.global_position)
		if d < best_d:
			best_d = d
			best = e
	return best

func resources_of_kind(kind_id: int) -> Array:
	return _resource_by_kind.get(kind_id, [])

func nearest_resource(pos: Vector3, kind_ids: Array, max_dist: float = 60.0):
	var best = null
	var best_d: float = max_dist
	for k in kind_ids:
		for r in _resource_by_kind.get(int(k), []):
			if not is_instance_valid(r) or r.health <= 0:
				continue
			var d: float = pos.distance_to(r.global_position)
			if d < best_d:
				best_d = d
				best = r
	return best

func describe() -> Dictionary:
	return {
		"valid": valid,
		"t": stamp_time,
		"cost_usec": cost_usec,
		"visibility_usec": visibility_usec,
		"visible_enemies": visible_enemies.size(),
		"own_armies": own_armies.size(),
		"enemy_armies": enemy_armies.size(),
		"own_land": own_land_count,
		"own_workers": own_worker_count,
		"own_military": own_military_count,
		"enemy_land": enemy_land_count,
		"own_buildings": own_buildings.size(),
		"enemy_buildings": enemy_building_count,
		"resources": resource_count,
	}

# 资源点数量多（几百个）且很少变化，只在低频轮建索引，避免每轮刷新都付这份成本。
func _index_resources(battle) -> void:
	resource_count = 0
	for r in battle._resources:
		if not is_instance_valid(r) or r.health <= 0:
			continue
		resource_count += 1
		_grid_insert(_resource_grid, r.global_position, r)
		var rid: int = int(r.entity_id)
		var by_kind: Array = _resource_by_kind.get(rid, [])
		by_kind.append(r)
		_resource_by_kind[rid] = by_kind
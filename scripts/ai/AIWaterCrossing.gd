class_name AIWaterCrossing
extends RefCounted

# AI 渡水行为：
# 1) 如果敌方城堡与己方城堡在陆地上不连通，先尝试在较窄的水面搭桥；
# 2) 桥搭不过去（海面太宽/没有落点）时，升级船坞到3级、组织运载船队，
#    一次运至少30名陆军过海，并派多艘战船/炮艇护航，再发起进攻。
# 这里只做“怎么过水”的规划与下令，不直接修改单位/建筑内部状态。

const BRIDGE_ID := 7
const TRANSPORT_ID := 9
const SHIPYARD_ID := 23
const TRANSPORT_SHIPYARD_LEVEL := 3
const MAX_BRIDGE_SPAN := 10
const MAX_BRIDGES := 10
const PLAN_INTERVAL := 6.0
const TRANSPORT_CAPACITY := 8
# 跨岛进攻至少需要30兵力，因此固定组织4艘运载船（32容量），
# 并带至少2艘、最多4艘战船/炮艇护航。
const TRANSPORT_FLEET_SIZE := 4
const MIN_TRANSPORT_TROOPS := 30
const MAX_TRANSPORT_TROOPS := TRANSPORT_FLEET_SIZE * TRANSPORT_CAPACITY
const ESCORT_TARGET := 4
const MIN_ESCORTS := 2
const ESCORT_IDS := [13, 39, 40]

const MODE_NONE := 0
const MODE_BRIDGE := 1
const MODE_TRANSPORT := 2

const STATE_IDLE := 0
const STATE_GATHER := 1
const STATE_SAIL := 2
const STATE_COOLDOWN := 3

var ai = null
var battle = null
var mode: int = MODE_NONE
var bridge_plan: Array = []

var _plan_timer: float = 2.0
var _bridge_fail_count: int = 0
var own_shore_water: Vector3 = Vector3.ZERO
var own_shore_land: Vector3 = Vector3.ZERO
var enemy_shore_water: Vector3 = Vector3.ZERO
var enemy_shore_land: Vector3 = Vector3.ZERO
var _transport_shores_valid: bool = false

var _transport_state: int = STATE_IDLE
var _transport_timer: float = 0.0
var _transport_units: Array = []
var _transports: Array = []
var _escorts: Array = []
var _unit_ship: Dictionary = {}
var _escort_advanced: bool = false

func _init(owner):
	ai = owner
	battle = ai.battle

func tick(delta: float):
	if battle == null or not is_instance_valid(battle):
		return
	_plan_timer -= delta
	if _plan_timer <= 0.0:
		_plan_timer = PLAN_INTERVAL
		_refresh_plan()
	if mode == MODE_BRIDGE:
		_tick_bridge(delta)
	elif mode == MODE_TRANSPORT:
		_tick_transport(delta)

# ═══════════════════════ 规划 ═══════════════════════

func _refresh_plan():
	# 搭桥过程中不要每个周期都重算，否则会把已经建了一半的桥段丢掉
	if mode == MODE_BRIDGE and not bridge_plan.is_empty():
		return
	# 运载船舰队已经集结/出航时也不要重算两岸，避免把船队中途改道
	if mode == MODE_TRANSPORT and _transport_state != STATE_IDLE:
		return
	var my_castle = ai.get_peer_castle(ai.my_peer_id)
	var enemy_castle = ai._get_attack_target_castle()
	if not is_instance_valid(my_castle) or not is_instance_valid(enemy_castle):
		_stop_all()
		return
	var start: Vector2i = battle.world_to_grid(my_castle.global_position)
	var target: Vector2i = battle.world_to_grid(enemy_castle.global_position)
	var bridges: Dictionary = _collect_bridges()
	var own_set: Dictionary = _bfs_land(start, bridges)
	if own_set.has(target):
		# 陆军已经能走到敌方城堡（陆地或浅滩/桥），不需要渡水
		_stop_all()
		return
	var enemy_set: Dictionary = _bfs_land(target, bridges)
	var plan: Array = []
	if _bridge_fail_count < 3:
		plan = _find_bridge_plan(own_set, enemy_set, bridges, start, target)
	if not plan.is_empty():
		if mode == MODE_TRANSPORT:
			_abort_transport()
		bridge_plan = plan
		_transport_state = STATE_IDLE
		_transport_units.clear()
		mode = MODE_BRIDGE
		return
	bridge_plan.clear()
	var shores: Dictionary = _find_transport_shores(own_set, enemy_set, bridges)
	if not shores.is_empty():
		own_shore_water = shores["own_water"]
		own_shore_land = shores["own_land"]
		enemy_shore_water = shores["enemy_water"]
		enemy_shore_land = shores["enemy_land"]
		_transport_shores_valid = true
		mode = MODE_TRANSPORT
	else:
		_stop_all()

func _stop_all():
	_abort_transport()
	bridge_plan.clear()
	_bridge_fail_count = 0
	_transport_shores_valid = false
	mode = MODE_NONE

func _abort_transport():
	# 让所有已登船的运载船就近靠岸放人，避免单位被永久藏在船里
	for ship in _transports:
		if is_instance_valid(ship) and ship.get_boarded_count() > 0:
			var land: Vector3 = _find_land_near(ship.global_position)
			if land == Vector3.ZERO:
				land = own_shore_land
			if land != Vector3.ZERO:
				ship.unboard_at(land)
	for u in _transport_units:
		if is_instance_valid(u) and u is Army:
			u.remove_meta("ai_transporting")
	for e in _escorts:
		if is_instance_valid(e):
			e.remove_meta("ai_escorting")
	_transport_units.clear()
	_unit_ship.clear()
	_transports.clear()
	_escorts.clear()
	_escort_advanced = false
	_transport_state = STATE_IDLE
	_transport_timer = 0.0

func _collect_bridges() -> Dictionary:
	var out: Dictionary = {}
	for e in battle.entities.get_children():
		if e is Building and e.entity_id == BRIDGE_ID and e.health > 0:
			out[battle.world_to_grid(e.global_position)] = true
	return out

func _land_passable(tile: Vector2i, bridges: Dictionary) -> bool:
	if tile.x < 0 or tile.x >= RTSConfig.MAP_SIZE or tile.y < 0 or tile.y >= RTSConfig.MAP_SIZE:
		return false
	if bridges.has(tile):
		return true
	var terrain = battle.get_terrain_at_grid(tile.x, tile.y)
	if terrain == 2:
		# 浅滩(3)是水格但陆军可通行
		return battle.get_overlay_at_grid(tile.x, tile.y) == 3
	return true

func _bfs_land(start: Vector2i, bridges: Dictionary) -> Dictionary:
	var visited: Dictionary = {start: true}
	var queue: Array = [start]
	var head: int = 0
	var dirs: Array = [
		Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
		Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)
	]
	while head < queue.size():
		var c: Vector2i = queue[head]
		head += 1
		for d in dirs:
			var n: Vector2i = c + d
			if visited.has(n):
				continue
			if not _land_passable(n, bridges):
				continue
			visited[n] = true
			queue.append(n)
	return visited

func _find_bridge_plan(own_set: Dictionary, enemy_set: Dictionary, bridges: Dictionary, own_grid: Vector2i, enemy_grid: Vector2i) -> Array:
	var best_line: Array = []
	var best_score: float = INF
	var dirs: Array = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	var existing_bridges: int = ai.count_building(BRIDGE_ID)
	for c in own_set.keys():
		for d in dirs:
			var line: Array = []
			var n: Vector2i = c + d
			while n.x >= 0 and n.x < RTSConfig.MAP_SIZE and n.y >= 0 and n.y < RTSConfig.MAP_SIZE:
				if battle.get_terrain_at_grid(n.x, n.y) != 2:
					break
				if bridges.has(n):
					break
				line.append(n)
				if line.size() > MAX_BRIDGE_SPAN:
					break
				n += d
			if line.is_empty() or line.size() > MAX_BRIDGE_SPAN:
				continue
			if existing_bridges + line.size() > MAX_BRIDGES:
				continue
			if not enemy_set.has(n):
				continue
			var first_world: Vector3 = battle.grid_to_world(line[0].x, line[0].y)
			if not battle.has_method("is_valid_bridge_position"):
				continue
			if not battle.is_valid_bridge_position(first_world):
				continue
			var mid: Vector2 = Vector2(
				(float(line[0].x) + float(line[line.size() - 1].x)) * 0.5,
				(float(line[0].y) + float(line[line.size() - 1].y)) * 0.5
			)
			var score: float = float(line.size()) * 8.0
			score += Vector2(line[0]).distance_to(Vector2(own_grid)) * 1.5
			score += _point_segment_distance(mid, Vector2(own_grid), Vector2(enemy_grid))
			if score < best_score:
				best_score = score
				best_line = line
	if best_line.is_empty():
		return []
	var out: Array = []
	for t in best_line:
		out.append(battle.grid_to_world(t.x, t.y))
	return out

func _point_segment_distance(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab: Vector2 = b - a
	var denom: float = ab.length_squared()
	if denom <= 0.0001:
		return p.distance_to(a)
	var t: float = clampf((p - a).dot(ab) / denom, 0.0, 1.0)
	return p.distance_to(a + ab * t)

# 在双方各自可达陆地之间寻找最短的可通航水面
func _find_transport_shores(own_set: Dictionary, enemy_set: Dictionary, bridges: Dictionary) -> Dictionary:
	var own_shores: Dictionary = {}
	var own_land: Dictionary = {}
	var enemy_shores: Dictionary = {}
	var enemy_land: Dictionary = {}
	var dirs: Array = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for c in own_set.keys():
		for d in dirs:
			var n: Vector2i = c + d
			if n.x < 0 or n.x >= RTSConfig.MAP_SIZE or n.y < 0 or n.y >= RTSConfig.MAP_SIZE:
				continue
			if battle.get_terrain_at_grid(n.x, n.y) != 2:
				continue
			if bridges.has(n):
				continue
			own_shores[n] = true
			own_land[n] = c
	for c in enemy_set.keys():
		for d in dirs:
			var n: Vector2i = c + d
			if n.x < 0 or n.x >= RTSConfig.MAP_SIZE or n.y < 0 or n.y >= RTSConfig.MAP_SIZE:
				continue
			if battle.get_terrain_at_grid(n.x, n.y) != 2:
				continue
			if bridges.has(n):
				continue
			enemy_shores[n] = true
			enemy_land[n] = c
	if own_shores.is_empty() or enemy_shores.is_empty():
		return {}
	var my_castle = ai.get_peer_castle(ai.my_peer_id)
	var enemy_castle = ai._get_attack_target_castle()
	if not is_instance_valid(my_castle) or not is_instance_valid(enemy_castle):
		return {}
	var own_grid: Vector2i = battle.world_to_grid(my_castle.global_position)
	var enemy_grid: Vector2i = battle.world_to_grid(enemy_castle.global_position)
	var visited: Dictionary = {}
	var source: Dictionary = {}
	var queue: Array = []
	for w in own_shores.keys():
		visited[w] = true
		source[w] = w
		queue.append(w)
	var head: int = 0
	var best_enemy: Vector2i = Vector2i(-1, -1)
	var best_score: float = INF
	while head < queue.size():
		var c: Vector2i = queue[head]
		head += 1
		if enemy_shores.has(c):
			var src: Vector2i = source[c]
			var score: float = Vector2(src).distance_to(Vector2(own_grid)) + Vector2(c).distance_to(Vector2(enemy_grid))
			if score < best_score:
				best_score = score
				best_enemy = c
		for d in dirs:
			var n: Vector2i = c + d
			if n.x < 0 or n.x >= RTSConfig.MAP_SIZE or n.y < 0 or n.y >= RTSConfig.MAP_SIZE:
				continue
			if visited.has(n):
				continue
			if battle.get_terrain_at_grid(n.x, n.y) != 2:
				continue
			# 运载船不能从桥下/桥上通过
			if bridges.has(n):
				continue
			visited[n] = true
			source[n] = source[c]
			queue.append(n)
	if best_enemy == Vector2i(-1, -1):
		return {}
	var best_src: Vector2i = source[best_enemy]
	var own_land_cell: Vector2i = own_land.get(best_src, best_src)
	var enemy_land_cell: Vector2i = enemy_land.get(best_enemy, best_enemy)
	return {
		"own_water": battle.grid_to_world(best_src.x, best_src.y),
		"own_land": battle.grid_to_world(own_land_cell.x, own_land_cell.y),
		"enemy_water": battle.grid_to_world(best_enemy.x, best_enemy.y),
		"enemy_land": battle.grid_to_world(enemy_land_cell.x, enemy_land_cell.y)
	}

# ═══════════════════════ 搭桥 ═══════════════════════

func _tick_bridge(_delta: float):
	if bridge_plan.is_empty():
		_plan_timer = minf(_plan_timer, 1.0)
		return
	var pos: Vector3 = bridge_plan[0]
	var g: Vector2i = battle.world_to_grid(pos)
	for e in battle.entities.get_children():
		if e is Building and e.entity_id == BRIDGE_ID and e.health > 0:
			if battle.world_to_grid(e.global_position) == g:
				bridge_plan.pop_front()
				return
	if not ai.can_afford_building(BRIDGE_ID):
		return
	if battle.has_method("is_valid_bridge_position") and not battle.is_valid_bridge_position(pos):
		# 这个桥位被单位/建筑挡住或地形已变，下一周期重新找
		bridge_plan.clear()
		_bridge_fail_count += 1
		_plan_timer = 1.0
		return
	if ai.build_building(BRIDGE_ID, pos):
		_bridge_fail_count = 0
		bridge_plan.pop_front()
		if bridge_plan.is_empty():
			_plan_timer = 0.0
			_recalculate_army_paths()
	else:
		# 视野不足、附近有敌军或位置被占：放弃本段，下一周期重新找线
		bridge_plan.clear()
		_bridge_fail_count += 1
		_plan_timer = 1.0

func _recalculate_army_paths():
	for e in battle.entities.get_children():
		if e is Army and e.health > 0 and ai.entity_belongs_to_me(e):
			if e.has_method("recalculate_path"):
				e.recalculate_path()

# ═══════════════════════ 运载船 ═══════════════════════

func _refresh_fleet():
	_transports.clear()
	_escorts.clear()
	for e in battle.entities.get_children():
		if not (e is Army) or e.health <= 0:
			continue
		if not ai.entity_belongs_to_me(e):
			continue
		if e.entity_id == TRANSPORT_ID:
			_transports.append(e)
		elif int(e.entity_id) in ESCORT_IDS:
			_escorts.append(e)
	# 先清掉上一轮的护航标记，再把当前选中的护航舰重新标记，
	# 防止海军巡逻/总攻把护航舰队拉去别处。
	for e in battle.entities.get_children():
		if e is Army and int(e.entity_id) in ESCORT_IDS and ai.entity_belongs_to_me(e):
			e.remove_meta("ai_escorting")
	if _transports.size() > TRANSPORT_FLEET_SIZE:
		_transports = _transports.slice(0, TRANSPORT_FLEET_SIZE)
	if _escorts.size() > ESCORT_TARGET:
		_escorts = _escorts.slice(0, ESCORT_TARGET)
	for e in _escorts:
		e.set_meta("ai_escorting", true)

func _tick_transport(delta: float):
	if not _transport_shores_valid:
		return
	if ai._is_defending():
		# 防守时释放护航舰/运载船；不要把海军锁在渡水任务里
		_abort_transport()
		return
	_refresh_fleet()
	# 必须凑够4艘运载船（32容量，至少运30兵）和至少2艘护航舰再出发
	if _transports.size() < TRANSPORT_FLEET_SIZE or _escorts.size() < MIN_ESCORTS:
		if _transport_state != STATE_IDLE:
			_abort_transport()
		_ensure_transport_tech()
		_ensure_transport_fleet()
		_ensure_escort_ships()
		return
	if _transport_state == STATE_IDLE:
		_tick_fleet_idle(delta)
	elif _transport_state == STATE_GATHER:
		_tick_fleet_gather(delta)
	elif _transport_state == STATE_SAIL:
		_tick_fleet_sail(delta)
	elif _transport_state == STATE_COOLDOWN:
		_transport_timer += delta
		if _transport_timer > 5.0:
			_transport_units.clear()
			_unit_ship.clear()
			for e in _escorts:
				if is_instance_valid(e):
					e.remove_meta("ai_escorting")
			var home_slots := _fleet_slots(own_shore_water, _transports.size(), 2.5)
			for i in range(_transports.size()):
				if is_instance_valid(_transports[i]):
					_transports[i].move_to(home_slots[i])
			_transport_state = STATE_IDLE
			_transport_timer = 0.0

func _tick_fleet_idle(delta: float):
	var slots := _fleet_slots(own_shore_water, _transports.size(), 2.5)
	var all_close: bool = true
	for i in range(_transports.size()):
		var ship = _transports[i]
		if not is_instance_valid(ship):
			continue
		if ship.global_position.distance_to(slots[i]) > 8.0:
			ship.move_to(slots[i])
			all_close = false
	if not all_close:
		return
	# 护航舰也先回到出发海域，和运载船一起走，避免船队先冲出去、护航舰还在后面
	var escort_slots := _fleet_slots(own_shore_water, _escorts.size(), 3.0)
	var escorts_home: bool = true
	for i in range(_escorts.size()):
		if not is_instance_valid(_escorts[i]):
			continue
		if _escorts[i].global_position.distance_to(escort_slots[i]) > 12.0:
			_escorts[i].move_to(escort_slots[i])
			escorts_home = false
	if not escorts_home:
		return
	var units: Array = _pick_units()
	if units.size() < MIN_TRANSPORT_TROOPS:
		# 兵力还不够30，继续等生产/集结，避免小股送人头
		_transport_timer += delta
		return
	_transport_units = units
	_unit_ship.clear()
	for i in range(units.size()):
		var u = units[i]
		if not is_instance_valid(u) or not (u is Army):
			continue
		var ship_idx: int = int(floor(float(i) / float(TRANSPORT_CAPACITY)))
		ship_idx = mini(ship_idx, _transports.size() - 1)
		var ship = _transports[ship_idx]
		if not is_instance_valid(ship):
			continue
		_unit_ship[u.get_instance_id()] = ship
		u.set_meta("ai_transporting", true)
		u.move_to(own_shore_land)
	_order_escorts_to(own_shore_water, 3.0)
	_transport_state = STATE_GATHER
	_transport_timer = 0.0

func _tick_fleet_gather(delta: float):
	_transport_timer += delta
	_clean_transport_units()
	if _transport_units.is_empty():
		_reset_transport_state()
		return
	var all_close: bool = true
	for u in _transport_units:
		var ship = _unit_ship.get(u.get_instance_id())
		if is_instance_valid(ship) and u.global_position.distance_to(ship.global_position) > 8.0:
			all_close = false
			break
	if not all_close and _transport_timer <= 30.0:
		return
	var boarded: Array = []
	for u in _transport_units:
		if not is_instance_valid(u) or not (u is Army):
			continue
		var ship = _unit_ship.get(u.get_instance_id())
		if not is_instance_valid(ship):
			u.remove_meta("ai_transporting")
			continue
		if ship.get_boarded_count() >= TRANSPORT_CAPACITY:
			u.remove_meta("ai_transporting")
			continue
		ship.board_unit(u)
		boarded.append(u)
	_transport_units = boarded
	if boarded.size() < MIN_TRANSPORT_TROOPS:
		# 有船沉了或单位没上齐，先回岸边重来，不把不足30人的部队送过去
		_abort_transport()
		return
	_transport_state = STATE_SAIL
	_transport_timer = 0.0
	_escort_advanced = false
	_order_fleet_sail()

func _tick_fleet_sail(delta: float):
	_transport_timer += delta
	var slots := _fleet_slots(enemy_shore_water, _transports.size(), 2.5)
	var all_near: bool = true
	var any_ship: bool = false
	for i in range(_transports.size()):
		var ship = _transports[i]
		if not is_instance_valid(ship):
			continue
		any_ship = true
		if ship.global_position.distance_to(slots[i]) > 6.0:
			all_near = false
	if not any_ship:
		_reset_transport_state()
		return
	if not _escort_advanced and _transport_timer > 8.0:
		_escort_advanced = true
		_order_escorts_to(enemy_shore_water, 3.0)
	if not all_near and _transport_timer <= 90.0:
		return
	# 所有运载船一起靠岸放人
	for ship in _transports:
		if not is_instance_valid(ship) or ship.get_boarded_count() <= 0:
			continue
		var land: Vector3 = _find_land_near(ship.global_position)
		if land == Vector3.ZERO:
			land = enemy_shore_land
		if land == Vector3.ZERO:
			land = own_shore_land
		if land != Vector3.ZERO:
			ship.unboard_at(land)
	var enemy_castle = ai._get_attack_target_castle()
	for u in _transport_units:
		if is_instance_valid(u) and u is Army:
			u.remove_meta("ai_transporting")
			if is_instance_valid(enemy_castle):
				u.attack_move_to(enemy_castle.global_position)
	_transport_units.clear()
	_unit_ship.clear()
	# 护航舰留在登陆场附近，继续掩护上岸部队
	_order_escorts_to(enemy_shore_water, 3.0)
	_transport_state = STATE_COOLDOWN
	_transport_timer = 0.0

func _order_fleet_sail():
	var slots := _fleet_slots(enemy_shore_water, _transports.size(), 2.5)
	for i in range(_transports.size()):
		if is_instance_valid(_transports[i]):
			_transports[i].move_to(slots[i])
	var mids := _convoy_midpoint()
	_order_escorts_to(mids, 3.0)

func _convoy_midpoint() -> Vector3:
	var mid: Vector3 = own_shore_water.lerp(enemy_shore_water, 0.55)
	if _is_water_point(mid):
		return mid
	return enemy_shore_water

func _order_escorts_to(base: Vector3, spacing: float):
	var slots := _fleet_slots(base, _escorts.size(), spacing)
	for i in range(_escorts.size()):
		if is_instance_valid(_escorts[i]):
			_escorts[i].move_to(slots[i])

func _fleet_slots(base: Vector3, count: int, spacing: float) -> Array:
	var out: Array = []
	if count <= 0:
		return out
	var dir: Vector3 = enemy_shore_water - own_shore_water
	dir.y = 0.0
	if dir.length() < 0.1:
		dir = Vector3(0, 0, 1)
	var perp: Vector3 = Vector3(-dir.z, 0.0, dir.x).normalized()
	var forward: Vector3 = dir.normalized()
	for i in range(count):
		var off: float = (float(i) - float(count - 1) * 0.5) * spacing
		var candidates: Array = [
			base + perp * off,
			base - perp * abs(off),
			base + forward * abs(off),
			base - forward * abs(off)
		]
		var chosen: Vector3 = base
		for c in candidates:
			if _is_water_point(c):
				chosen = c
				break
		out.append(chosen)
	return out

func _is_water_point(pos: Vector3) -> bool:
	var g: Vector2i = battle.world_to_grid(pos)
	if g.x < 0 or g.x >= RTSConfig.MAP_SIZE or g.y < 0 or g.y >= RTSConfig.MAP_SIZE:
		return false
	return battle.get_terrain_at_grid(g.x, g.y) == 2

func _reset_transport_state():
	_abort_transport()

func _clean_transport_units():
	var alive: Array = []
	for u in _transport_units:
		if is_instance_valid(u) and u is Army and u.health > 0:
			alive.append(u)
	_transport_units = alive

func _pick_units() -> Array:
	var candidates: Array = []
	var exclusions: Array = [5, 6, 9, 10, 13, 14, 39, 40, 43, 44, 45, 46, 47, 48, 49, 50, 51, 55, 56, 57]
	for e in battle.entities.get_children():
		if not (e is Army) or e.health <= 0:
			continue
		if not ai.entity_belongs_to_me(e):
			continue
		if int(e.entity_id) in exclusions:
			continue
		if e.target_type <= 0 or e.water_capable:
			continue
		if not e.can_move:
			continue
		var boarded = e.get("_boarded_on")
		if boarded != null and int(boarded) != -1:
			continue
		var sgb = e.get("_soldier_garrison_building")
		if sgb != null and sgb.get_ref() != null:
			continue
		var gb = e.get("_garrison_building")
		if gb != null and gb.get_ref() != null:
			continue
		if e.has_meta("ai_home_guard") or e.has_meta("ai_resource_guard") or e.has_meta("ai_harass") or e.has_meta("ai_transporting"):
			continue
		var dist: float = e.global_position.distance_to(own_shore_land)
		candidates.append({"unit": e, "dist": dist})
	if candidates.is_empty():
		return []
	candidates.sort_custom(func(a, b): return float(a["dist"]) < float(b["dist"]))
	var out: Array = []
	for item in candidates:
		out.append(item["unit"])
		if out.size() >= MAX_TRANSPORT_TROOPS:
			break
	return out

func _find_land_near(pos: Vector3) -> Vector3:
	var center: Vector2i = battle.world_to_grid(pos)
	for radius in range(0, 8):
		for dx in range(-radius, radius + 1):
			for dy in range(-radius, radius + 1):
				if maxi(absi(dx), absi(dy)) != radius:
					continue
				var gx: int = center.x + dx
				var gy: int = center.y + dy
				if gx < 0 or gx >= RTSConfig.MAP_SIZE or gy < 0 or gy >= RTSConfig.MAP_SIZE:
					continue
				if battle.get_terrain_at_grid(gx, gy) != 2:
					return battle.grid_to_world(gx, gy)
	return Vector3.ZERO

# ═══════════════════════ 运载船前置科技 ═══════════════════════

func _ensure_transport_tech():
	var sy = ai._find_own_building(SHIPYARD_ID)
	if not is_instance_valid(sy):
		return
	if sy.build_timer > 0.0:
		return
	if sy.upgrade_level >= TRANSPORT_SHIPYARD_LEVEL:
		return
	var castle = ai.get_peer_castle(ai.my_peer_id)
	if is_instance_valid(castle) and castle.upgrade_level <= sy.upgrade_level:
		if ai.can_afford_upgrade(20):
			ai.upgrade_building(20)
			return
	if ai.can_afford_upgrade(SHIPYARD_ID):
		ai.upgrade_building(SHIPYARD_ID)

func _ensure_transport_fleet():
	if ai.count_unit(TRANSPORT_ID) >= TRANSPORT_FLEET_SIZE:
		return
	var sy = ai._find_own_building(SHIPYARD_ID)
	if not is_instance_valid(sy) or sy.build_timer > 0.0:
		return
	if sy.upgrade_level < TRANSPORT_SHIPYARD_LEVEL:
		return
	var has_transport: bool = false
	for prod in sy.production_list:
		if int(prod.get("unit_id", -1)) == TRANSPORT_ID:
			has_transport = true
			break
	if not has_transport:
		# 船坞升级时正常会补全生产列表；这里兜底，避免升级完成事件的边缘情况
		sy.production_list.append({"unit_id": TRANSPORT_ID, "cooldown": 15.0, "queue_limit": 3})
	if not ai._can_train_unit():
		return
	if ai.can_afford(TRANSPORT_ID):
		sy.try_produce(TRANSPORT_ID)

func _ensure_escort_ships():
	var total: int = ai.count_unit(13) + ai.count_unit(39) + ai.count_unit(40)
	if total >= ESCORT_TARGET:
		return
	var sy = ai._find_own_building(SHIPYARD_ID)
	if not is_instance_valid(sy) or sy.build_timer > 0.0:
		return
	if sy.upgrade_level < 2:
		return
	var has_warship: bool = false
	for prod in sy.production_list:
		if int(prod.get("unit_id", -1)) == 13:
			has_warship = true
			break
	if not has_warship:
		sy.production_list.append({"unit_id": 13, "cooldown": 7.0, "queue_limit": 5})
	if not ai._can_train_unit():
		return
	if ai.can_afford(13):
		sy.try_produce(13)

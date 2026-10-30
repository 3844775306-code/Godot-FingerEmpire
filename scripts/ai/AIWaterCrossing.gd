class_name AIWaterCrossing
extends RefCounted

# AI 渡水行为：
# 1) 如果敌方城堡与己方城堡在陆地上不连通，先尝试在较窄的水面搭桥；
# 2) 桥搭不过去（海面太宽/没有落点）时，升级船坞到3级、组织运载船队，
#    基础一波至少运30名陆军过海，并派多艘战船/炮艇/爆破船护航，再发起进攻。
#    每组织一次新的登陆波次，编队规模按当前对局时间增长：运载船、运输兵力和
#    护航舰都会随游戏时间逐步增加，后期登陆波次明显更大。
# 这里只做“怎么过水”的规划与下令，不直接修改单位/建筑内部状态。

const BRIDGE_ID := 7
const TRANSPORT_ID := 9
const SHIPYARD_ID := 23
const TRANSPORT_SHIPYARD_LEVEL := 3
const MAX_BRIDGE_SPAN := 10
const MAX_BRIDGES := 10
# 资源岛短桥：只跨几格水面，专门让农民能去对岸砍树/挖矿。
# 太宽的水面交给运载船，避免 AI 把桥修到海中央。
const MAX_RESOURCE_BRIDGE_SPAN := 7
const RESOURCE_BRIDGE_GOAL_RADIUS := 3
# 一局最多为经济修几座资源桥：修太多会吃掉木材/石材，拖垮正常建设。
const MAX_RESOURCE_BRIDGES := 3
const PLAN_INTERVAL := 6.0
const TRANSPORT_CAPACITY := 8
# 跨岛登陆波次规模：基础4艘运载船（32容量）、30名陆军、4艘护航舰。
# 每过 FLEET_GROWTH_INTERVAL 秒，下一次组织的登陆波次多1艘运载船、1艘护航舰，
# 并多运8名陆军；上限8艘运载船、8艘护航舰，避免后期人口/产能完全崩溃。
const TRANSPORT_FLEET_SIZE := 4
const MAX_TRANSPORT_FLEET_SIZE := 8
const MIN_TRANSPORT_TROOPS := 30
const ESCORT_TARGET := 4
const MAX_ESCORT_TARGET := 8
const FLEET_GROWTH_INTERVAL := 240.0
const TROOP_GROWTH_PER_STEP := 8
# 兵力不足时等待集结的宽限时间；超时后只要基础30兵仍会出发，避免永远不登陆
const TROOP_GATHER_GRACE := 20.0
const ESCORT_IDS := [13, 39, 40]
const BOARD_DISTANCE := 7.0
const PARK_DISTANCE := 5.5
const UNLOAD_DISTANCE := 7.0
const BOARD_WAIT_TIMEOUT := 50.0
# 集结宽限：船坞被其他船占满、人口封顶或运载船在队列里迟迟不下水时，
# 不能永远等“4 运载船 + 4 护航舰”齐编。超过这个时间就按现有船先组织登陆，
# 否则海峡图这种完全无陆路的地图会一直停在 STATE_IDLE，永远不投送陆军。
const FLEET_ASSEMBLY_TIMEOUT := 45.0
# 桥计划在“木材不足”状态下不能无限占着通道：超时后放弃本段并计入失败，
# 连续失败会按既有逻辑改走运载船。
const BRIDGE_AFFORD_TIMEOUT := 30.0
# 船队已经集结/出航后，如果个别船被地形或其它船卡住，不能无限等待。
const FLEET_IDLE_TIMEOUT := 90.0
const FLEET_SAIL_TIMEOUT := 180.0

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
var _resource_bridges_started: int = 0
# 己方主城所在陆地的连通格集合。农民到建造点的可达性先用它做快速判断，
# 只有目标不在同一块陆地时才启动小范围 BFS，避免每次 AI 造建筑都扫全图。
var _reachable_land: Dictionary = {}

var _plan_timer: float = 2.0
var _bridge_fail_count: int = 0
var _bridge_retry_at_ms: int = 0
var own_shore_water: Vector3 = Vector3.ZERO
var own_shore_land: Vector3 = Vector3.ZERO
var enemy_shore_water: Vector3 = Vector3.ZERO
var enemy_shore_land: Vector3 = Vector3.ZERO
var _transport_shores_valid: bool = false
# 船坞所在水域是否和登陆出发岸连通：船坞旁边可能是内陆油田水塘，
# 船从这里下水后根本开不到登陆岸，运输波次会一直停在原地。
var _shipyard_water_cache: Dictionary = {}
# 上岸点定期更换：固定登陆场容易被对手守死，每分钟重新选一次
const SHORES_REFRESH_SEC: float = 60.0
var _shores_set_at_ms: int = 0
# 登陆场防御评估：先在最近上岸点登陆；若该点敌军/防御塔过强，
# 再在同一片岸线附近换一个防御更弱的点，而不是直接放弃渡海。
const LANDING_DEFENSE_RADIUS := 16.0
const LANDING_DEFENSE_MIN_LIMIT := 7.0
const LANDING_DEFENSE_PER_TROOP := 0.22
const LANDING_ALTERNATIVE_RADIUS := 28.0
const LANDING_ALTERNATIVE_SEA_GAP := 12
const LANDING_AVOID_MAX_DETOUR := 0.1

var _transport_state: int = STATE_IDLE
var _transport_timer: float = 0.0
var _transport_units: Array = []
var _transports: Array = []
var _escorts: Array = []
var _unit_ship: Dictionary = {}
var _transport_slots: Array = []
var _escort_advanced: bool = false
# 当前这次登陆波次的目标规模。波次一旦开始组织就固定下来，
# 避免舰队已经在海上时因为时间增长又要求追加船只，导致中途返航/放弃。
var _wave_transport_target: int = 0
var _wave_escort_target: int = 0
var _wave_troop_target: int = 0
var _wave_troop_quota: int = 0
var _fleet_wait_timer: float = 0.0
var _bridge_afford_timer: float = 0.0
# 施工中桥段的进度监视：农民可能被防守逻辑拉走/卡在水里，光看
# builder_count_cache 会误以为还在干活，桥段一停就是几分钟。
var _bridge_pending_gid: int = 0
var _bridge_pending_left: float = -1.0
var _bridge_pending_stall: float = 0.0
var _fleet_idle_timer: float = 0.0
var _fleet_sail_timer: float = 0.0

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
	# 运载船舰队已经集结/出航时也不要重算两岸，避免把船队中途改道。
	# 还在等船/等兵（STATE_IDLE）时同样要冻结：如果每 6 秒重算一次，
	# 岸点可能在几处候选之间来回跳，运载船永远开不到停泊点，也就不会上船。
	# 例外：上岸点每分钟强制换一次，避免固定登陆场被对手守死。
	if mode == MODE_TRANSPORT and _transport_shores_valid and (not _transports.is_empty() or _transport_state != STATE_IDLE):
		if Time.get_ticks_msec() - _shores_set_at_ms < int(SHORES_REFRESH_SEC * 1000.0):
			return
		# 到点：继续走下面的重算流程，用新的登陆/停泊岸点替换（船队状态不变）
	var my_castle = ai.get_peer_castle(ai.my_peer_id)
	var enemy_castle = ai._get_attack_target_castle()
	if not is_instance_valid(my_castle) or not is_instance_valid(enemy_castle):
		_stop_all()
		return
	var start: Vector2i = battle.world_to_grid(my_castle.global_position)
	var target: Vector2i = battle.world_to_grid(enemy_castle.global_position)
	var bridges: Dictionary = _collect_bridges()
	var own_set: Dictionary = _bfs_land(start, bridges)
	_reachable_land = own_set
	if own_set.has(target):
		# 陆军已经能走到敌方城堡（陆地或浅滩/桥），不需要为了进攻渡水；
		# 但如果对岸还有农民够不着的资源，仍然可以修一条短桥把经济接过去。
		_stop_all()
		if _bridge_fail_count < 3 and _try_resource_bridge(own_set, bridges, start):
			return
		return
	var enemy_set: Dictionary = _bfs_land(target, bridges)
	var plan: Array = []
	# 连续失败 3 次后暂时走运载船，但不要永久放弃搭桥：
	# 敌人退走、资源恢复或桥位空出来后，AI 仍应重新尝试。
	if _bridge_fail_count >= 3:
		if Time.get_ticks_msec() >= _bridge_retry_at_ms:
			_bridge_fail_count = 0
		else:
			plan = []
	if _bridge_fail_count < 3:
		plan = _find_bridge_plan(own_set, enemy_set, bridges, start, target)
	if not plan.is_empty():
		if mode == MODE_TRANSPORT:
			_abort_transport()
		bridge_plan = plan
		_bridge_afford_timer = 0.0
		_transport_state = STATE_IDLE
		_transport_units.clear()
		mode = MODE_BRIDGE
		return
	# 到敌方城堡的桥修不了时，先看能不能给农民搭一座短桥去对岸资源点；
	# 运载船留给真正需要跨海的进攻，避免被一座小资源岛拖住。
	if mode != MODE_TRANSPORT and _bridge_fail_count < 3:
		if _try_resource_bridge(own_set, bridges, start):
			return
	bridge_plan.clear()
	var shores: Dictionary = _find_transport_shores(own_set, enemy_set, bridges, enemy_shore_water)
	if not shores.is_empty():
		own_shore_water = shores["own_water"]
		own_shore_land = shores["own_land"]
		enemy_shore_water = shores["enemy_water"]
		enemy_shore_land = shores["enemy_land"]
		_transport_shores_valid = true
		_shores_set_at_ms = Time.get_ticks_msec()
		mode = MODE_TRANSPORT
	else:
		_stop_all()

func _stop_all():
	_abort_transport()
	bridge_plan.clear()
	_bridge_fail_count = 0
	_bridge_afford_timer = 0.0
	_transport_shores_valid = false
	_reachable_land.clear()
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
	_transport_slots.clear()
	_transports.clear()
	_escorts.clear()
	_escort_advanced = false
	_transport_state = STATE_IDLE
	_transport_timer = 0.0
	_fleet_wait_timer = 0.0
	_fleet_idle_timer = 0.0
	_fleet_sail_timer = 0.0
	# 中断后下一次组织登陆按当时时间重新计算波次规模
	_reset_wave_targets()

# 船队卡住时不只是原地重试：作废当前岸点，让下一轮重新找登陆场。
func _stall_transport():
	# 卡在远处水域的运载船（常见于内陆油田水塘、被陆地隔开的另一片海湾）
	# 永远到不了出发岸。把它们排除出本波舰队，让船坞补造靠岸的船；
	# 否则每 90 秒重试时还是会选中同一批远端船，登陆永远不开始。
	for s in _transports:
		if is_instance_valid(s) and s.global_position.distance_to(own_shore_water) > 15.0:
			s.set_meta("ai_transport_excluded", true)
	_transport_shores_valid = false
	_plan_timer = 0.0
	_abort_transport()

func _collect_bridges() -> Dictionary:
	var out: Dictionary = {}
	for e in battle.entities.get_children():
		# 只把完工的桥算作可通行；施工中的桥段不能拿来判断两岸已经连通。
		if e is Building and e.entity_id == BRIDGE_ID and e.health > 0 and e.build_timer <= 0.0:
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
	# 与陆军 A* 保持一致：山壁、悬崖、无法通过的台地边缘不能算陆地连通。
	if battle.has_method("is_cliff_tile") and battle.is_cliff_tile(tile.x, tile.y):
		return false
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

# 给农民找一座“经济桥”：从己方岸边跨过一段窄水，落到对岸资源点附近。
# 只找短桥，且只从临水岸边出发，避免每个周期扫全图内陆格。
func _try_resource_bridge(own_set: Dictionary, bridges: Dictionary, own_grid: Vector2i) -> bool:
	if _bridge_fail_count >= 3 or _resource_bridges_started >= MAX_RESOURCE_BRIDGES:
		return false
	var plan: Array = _find_resource_bridge_plan(own_set, bridges, own_grid)
	if plan.is_empty():
		return false
	_resource_bridges_started += 1
	bridge_plan = plan
	_bridge_afford_timer = 0.0
	_transport_state = STATE_IDLE
	_transport_units.clear()
	mode = MODE_BRIDGE
	if OS.is_debug_build():
		print("[AI] 为农民搭桥：%d 段，通往对岸资源" % plan.size())
	return true

func has_pending_bridge() -> bool:
	return mode == MODE_BRIDGE and not bridge_plan.is_empty()

# 农民从 from_pos 到 target_pos 是否有陆路（含已建成的桥）。
# 主城陆地集合是缓存；只有起点/终点不在这块陆地时才做一次带早停的 BFS。
func can_builder_reach(from_pos: Vector3, target_pos: Vector3) -> bool:
	if battle == null:
		return true
	var start: Vector2i = battle.world_to_grid(from_pos)
	var goal: Vector2i = battle.world_to_grid(target_pos)
	if start == goal:
		return true
	var bridges: Dictionary = _collect_bridges()
	if _reachable_land.is_empty():
		# 渡水规划还没跑过（刚开局/防守关没有敌方城堡）时，用己方主城补一次
		# 连通集，避免 AI 每造一座建筑都做一次全图 BFS。
		var castle = ai.get_peer_castle(ai.my_peer_id)
		if is_instance_valid(castle):
			_reachable_land = _bfs_land(battle.world_to_grid(castle.global_position), bridges)
	if _reachable_land.has(start) and _reachable_land.has(goal):
		return true
	return _bfs_reach(start, goal, bridges)

func _bfs_reach(start: Vector2i, goal: Vector2i, bridges: Dictionary) -> bool:
	if not _land_passable(start, bridges) or not _land_passable(goal, bridges):
		return false
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
		if c == goal:
			return true
		for d in dirs:
			var n: Vector2i = c + d
			if visited.has(n) or not _land_passable(n, bridges):
				continue
			visited[n] = true
			queue.append(n)
	return false

# AI 要在一座农民走不到的岛上造建筑时，先规划一条从农民脚下到该岛的短桥。
# 桥仍然复用现有 _find_bridge_plan / _tick_bridge，保证只是一次“请求”，
# 不绕过木材、桥数上限、敌军视野和正常施工流程。
func plan_bridge_to(target_pos: Vector3, from_pos: Vector3 = Vector3.ZERO) -> bool:
	if battle == null:
		return false
	if mode == MODE_BRIDGE and not bridge_plan.is_empty():
		return false
	# 正在组织登陆船队时不强行改道；等这波登陆结束再考虑为建造搭桥。
	if mode == MODE_TRANSPORT:
		return false
	if _bridge_fail_count >= 3 and Time.get_ticks_msec() < _bridge_retry_at_ms:
		return false
	var start_pos: Vector3 = from_pos if not from_pos.is_zero_approx() else Vector3.ZERO
	if start_pos == Vector3.ZERO:
		var castle = ai.get_peer_castle(ai.my_peer_id)
		if not is_instance_valid(castle):
			return false
		start_pos = castle.global_position
	var start: Vector2i = battle.world_to_grid(start_pos)
	var goal: Vector2i = battle.world_to_grid(target_pos)
	if start == goal:
		return false
	var bridges: Dictionary = _collect_bridges()
	var own_set: Dictionary = _bfs_land(start, bridges)
	if own_set.has(goal):
		return false
	var goal_set: Dictionary = _bfs_land(goal, bridges)
	if goal_set.has(start):
		return false
	var plan: Array = _find_bridge_plan(own_set, goal_set, bridges, start, goal)
	if plan.is_empty():
		return false
	bridge_plan = plan
	_bridge_afford_timer = 0.0
	mode = MODE_BRIDGE
	_transport_state = STATE_IDLE
	_transport_units.clear()
	_bridge_fail_count = 0
	_bridge_retry_at_ms = 0
	if OS.is_debug_build():
		print("[AI] 农民到不了建造点，先搭 %d 段桥：%s" % [plan.size(), str(target_pos)])
	return true

# AI 已经规划好的桥段不受玩家“必须看得见才能建”的限制：
# 这座桥是 AI 为了让自己农民够到对岸资源而主动规划的基础设施，
# 第一段由 AI 直接开工；后续桥段仍按“邻接已有桥”的常规规则延伸。
func is_planned_bridge_position(pos: Vector3) -> bool:
	if bridge_plan.is_empty():
		return false
	return battle.world_to_grid(pos) == battle.world_to_grid(bridge_plan[0])

func _find_resource_bridge_plan(own_set: Dictionary, bridges: Dictionary, own_grid: Vector2i) -> Array:
	var resource_tiles: Dictionary = {}
	for e in battle.entities.get_children():
		if not (e is WorldResource) or e.health <= 0:
			continue
		var rt: Vector2i = battle.world_to_grid(e.global_position)
		if rt.x < 0 or rt.y < 0 or rt.x >= RTSConfig.MAP_SIZE or rt.y >= RTSConfig.MAP_SIZE:
			continue
		if own_set.has(rt):
			continue
		if battle.get_terrain_at_grid(rt.x, rt.y) != 0:
			continue
		resource_tiles[rt] = String(e.resource_type)
	if resource_tiles.is_empty():
		return []

	var dirs: Array = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	var existing_bridges: int = ai.count_building(BRIDGE_ID)
	var best_score: float = INF
	var best_line: Array = []
	for c in own_set.keys():
		var cell: Vector2i = c
		# 只从临水格出发：内陆格不可能直接修第一段桥
		var near_water := false
		for d in dirs:
			var w: Vector2i = cell + d
			if w.x < 0 or w.y < 0 or w.x >= RTSConfig.MAP_SIZE or w.y >= RTSConfig.MAP_SIZE:
				continue
			if battle.get_terrain_at_grid(w.x, w.y) == 2:
				near_water = true
				break
		if not near_water:
			continue
		for d in dirs:
			var line: Array = []
			var n: Vector2i = cell + d
			while n.x >= 0 and n.x < RTSConfig.MAP_SIZE and n.y >= 0 and n.y < RTSConfig.MAP_SIZE:
				if battle.get_terrain_at_grid(n.x, n.y) != 2:
					break
				if bridges.has(n):
					break
				line.append(n)
				if line.size() > MAX_RESOURCE_BRIDGE_SPAN:
					break
				n += d
			if line.is_empty() or line.size() > MAX_RESOURCE_BRIDGE_SPAN:
				continue
			if existing_bridges + line.size() > MAX_BRIDGES:
				continue
			if n.x < 0 or n.y < 0 or n.x >= RTSConfig.MAP_SIZE or n.y >= RTSConfig.MAP_SIZE:
				continue
			# 桥头必须落在可走的平地上，不能把桥修到山壁/水里
			if battle.get_terrain_at_grid(n.x, n.y) != 0:
				continue
			var goal_tile := Vector2i(-1, -1)
			var goal_dist: float = INF
			var goal_type := ""
			for dx in range(-RESOURCE_BRIDGE_GOAL_RADIUS, RESOURCE_BRIDGE_GOAL_RADIUS + 1):
				for dy in range(-RESOURCE_BRIDGE_GOAL_RADIUS, RESOURCE_BRIDGE_GOAL_RADIUS + 1):
					var g: Vector2i = n + Vector2i(dx, dy)
					if not resource_tiles.has(g):
						continue
					var dist: float = Vector2(n).distance_to(Vector2(g))
					if dist < goal_dist:
						goal_dist = dist
						goal_tile = g
						goal_type = String(resource_tiles[g])
			if goal_tile.x < 0:
				continue
			var first_world: Vector3 = battle.grid_to_world(line[0].x, line[0].y)
			if battle.has_method("is_valid_bridge_position") and not battle.is_valid_bridge_position(first_world):
				continue
			var weight: float = 1.0
			if ai != null and ai.has_method("_get_phase_weights"):
				weight = maxf(0.3, float(ai._get_phase_weights().get(goal_type, 1.0)))
			# 桥越短越优先；资源越紧缺、离己方主城越近越优先
			var score: float = float(line.size()) * 10.0
			score += Vector2(line[0]).distance_to(Vector2(own_grid)) * 0.8
			score += goal_dist * 3.0
			score -= weight * 5.0
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
# avoid_pos 非零时优先挑一个离它较远的候选岸点（用于每分钟轮换登陆场）
func _find_transport_shores(own_set: Dictionary, enemy_set: Dictionary, bridges: Dictionary, avoid_pos: Vector3 = Vector3.ZERO) -> Dictionary:
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
	var sea_dist: Dictionary = {}
	var queue: Array = []
	for w in own_shores.keys():
		visited[w] = true
		source[w] = w
		sea_dist[w] = 0
		queue.append(w)
	var head: int = 0
	var cands: Array = []
	while head < queue.size():
		var c: Vector2i = queue[head]
		head += 1
		if enemy_shores.has(c) and enemy_land.has(c):
			var src: Vector2i = source[c]
			var land_cell: Vector2i = enemy_land[c]
			var own_land_cell: Vector2i = own_land.get(src, src)
			cands.append({
				"cell": c,
				"src": src,
				"sea_dist": float(sea_dist.get(c, 0)),
				"own_land": own_land_cell,
				"enemy_land": land_cell,
				"own_castle_dist": Vector2(src).distance_to(Vector2(own_grid)),
				"enemy_castle_dist": Vector2(land_cell).distance_to(Vector2(enemy_grid))
			})
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
			sea_dist[n] = int(sea_dist.get(c, 0)) + 1
			queue.append(n)
	if cands.is_empty():
		return {}
	# 一次收集敌岸附近的守军/防御塔，避免为每个候选岸点重复全实体扫描。
	var defenses: Array = _collect_landing_defenses()
	for cd in cands:
		var land_world: Vector3 = battle.grid_to_world(cd["enemy_land"].x, cd["enemy_land"].y)
		cd["defense"] = _landing_defense_score(land_world, defenses)
		# 先比较“从己方主城到登陆点”的实际接近距离（陆路到己岸 + 最短海路），
		# 再比较登陆后到敌方主城的陆路距离；距离最近的上岸点优先。
		cd["approach"] = float(cd["own_castle_dist"]) + float(cd["sea_dist"])
		cd["route"] = float(cd["approach"]) + float(cd["enemy_castle_dist"]) * 0.35
	cands.sort_custom(func(a, b):
		if not is_equal_approx(float(a["approach"]), float(b["approach"])):
			return float(a["approach"]) < float(b["approach"])
		return float(a["route"]) < float(b["route"])
	)
	var nearest: Dictionary = cands[0]
	var defense_limit: float = _landing_defense_limit()
	var pick: Dictionary = nearest
	# 最近上岸点敌军过强：只在这片岸线附近找替代点，保证运载船仍然就近登陆。
	if float(nearest["defense"]) > defense_limit:
		var nearby: Array = []
		var nearest_land: Vector3 = battle.grid_to_world(nearest["enemy_land"].x, nearest["enemy_land"].y)
		for cd in cands:
			if cd == nearest:
				continue
			# 只考虑防御确实更低的附近岸点；否则换过去反而更危险，不如保持最近点。
			if float(cd["defense"]) >= float(nearest["defense"]) - 0.5:
				continue
			var near_land: Vector3 = battle.grid_to_world(cd["enemy_land"].x, cd["enemy_land"].y)
			if _flat_distance(near_land, nearest_land) <= LANDING_ALTERNATIVE_RADIUS \
					or absf(float(cd["sea_dist"]) - float(nearest["sea_dist"])) <= LANDING_ALTERNATIVE_SEA_GAP:
				nearby.append(cd)
		# 优先换到“仍在附近、且防御已降到可接受范围”的最近岸点；
		# 如果附近没有可接受的点，再退而求其次选防御最低的。
		nearby.sort_custom(func(a, b):
			var a_safe: bool = float(a["defense"]) <= defense_limit
			var b_safe: bool = float(b["defense"]) <= defense_limit
			if a_safe != b_safe:
				return a_safe
			if not a_safe:
				if not is_equal_approx(float(a["defense"]), float(b["defense"])):
					return float(a["defense"]) < float(b["defense"])
			var a_land: Vector3 = battle.grid_to_world(a["enemy_land"].x, a["enemy_land"].y)
			var b_land: Vector3 = battle.grid_to_world(b["enemy_land"].x, b["enemy_land"].y)
			var a_d: float = _flat_distance(a_land, nearest_land)
			var b_d: float = _flat_distance(b_land, nearest_land)
			if not is_equal_approx(a_d, b_d):
				return a_d < b_d
			return float(a["approach"]) < float(b["approach"])
		)
		if not nearby.is_empty():
			pick = nearby[0]
	# 定期轮换只作为“几乎同距”的微调：不把船队强行拉到明显更远的岸点。
	if avoid_pos != Vector3.ZERO and pick == nearest:
		for cd in cands:
			if float(cd["defense"]) > defense_limit:
				continue
			if float(cd["approach"]) > float(nearest["approach"]) + LANDING_AVOID_MAX_DETOUR:
				continue
			var cd_land: Vector3 = battle.grid_to_world(cd["enemy_land"].x, cd["enemy_land"].y)
			if _flat_distance(cd_land, avoid_pos) > 6.0:
				pick = cd
				break
	var best_src2: Vector2i = pick["src"]
	var best_enemy2: Vector2i = pick["cell"]
	var own_land_cell2: Vector2i = own_land.get(best_src2, best_src2)
	var enemy_land_cell2: Vector2i = enemy_land.get(best_enemy2, best_enemy2)
	return {
		"own_water": battle.grid_to_world(best_src2.x, best_src2.y),
		"own_land": battle.grid_to_world(own_land_cell2.x, own_land_cell2.y),
		"enemy_water": battle.grid_to_world(best_enemy2.x, best_enemy2.y),
		"enemy_land": battle.grid_to_world(enemy_land_cell2.x, enemy_land_cell2.y)
	}

# 统计登陆点附近的敌方防御强度。只算能反击的陆军、战船与防御建筑；
# 农民/商人/官员以及资源点不参与，避免把普通村庄误判成重兵把守。
func _collect_landing_defenses() -> Array:
	var out: Array = []
	for e in ai._cached_armies():
		if not is_instance_valid(e) or e.health <= 0:
			continue
		if int(e.team) == RTSConfig.Team.NEUTRAL:
			continue
		if not ai._entity_is_enemy(e):
			continue
		var uid: int = int(e.entity_id)
		if uid == 10 or uid == 14 or uid in [43, 44, 45, 46, 47, 48, 49, 50, 51]:
			continue
		if int(e.target_type) <= 0 and float(e.attack) <= 0.0:
			continue
		out.append({
			"pos": e.global_position,
			"score": 1.0 + maxf(0.0, float(e.attack)) * 0.06 + maxf(0.0, float(e.target_type)) * 0.18
		})
	for b in ai._cached_buildings():
		if not is_instance_valid(b) or b.health <= 0:
			continue
		if int(b.team) == RTSConfig.Team.NEUTRAL or b.build_timer > 0.0:
			continue
		if not ai._entity_is_enemy(b):
			continue
		var bid: int = int(b.entity_id)
		var bscore: float = 0.0
		if bid == 20:
			bscore = 8.0
		elif bid == 25 or bid == 26:
			bscore = 5.0 + maxf(0.0, float(b.attack)) * 0.08
		if bscore > 0.0:
			out.append({"pos": b.global_position, "score": bscore})
	return out

func _landing_defense_limit() -> float:
	var troops: int = _wave_troop_target if _wave_troop_target > 0 else MIN_TRANSPORT_TROOPS
	return maxf(LANDING_DEFENSE_MIN_LIMIT, float(troops) * LANDING_DEFENSE_PER_TROOP)

func _landing_defense_score(pos: Vector3, defenses: Array) -> float:
	var total: float = 0.0
	for d in defenses:
		var dist: float = _flat_distance(pos, d["pos"])
		if dist > LANDING_DEFENSE_RADIUS:
			continue
		var prox: float = clampf(1.0 - dist / LANDING_DEFENSE_RADIUS, 0.0, 1.0)
		total += float(d["score"]) * (0.35 + prox * 0.65)
	return total

# ═══════════════════════ 搭桥 ═══════════════════════

func _tick_bridge(delta: float):
	if bridge_plan.is_empty():
		_bridge_afford_timer = 0.0
		_plan_timer = minf(_plan_timer, 1.0)
		return
	var pos: Vector3 = bridge_plan[0]
	var g: Vector2i = battle.world_to_grid(pos)
	var pending_bridge: Building = null
	for e in battle.entities.get_children():
		if e is Building and e.entity_id == BRIDGE_ID and e.health > 0:
			if battle.world_to_grid(e.global_position) == g:
				# 施工中的桥段不能从计划里弹掉。以前只要桥实体存在就算“已建”，
				# AI 会把整条计划快速弹空，最后一段却停在等待农民的状态，
				# 之后重新规划又把这段当成已存在弹掉，桥永远差一格不通。
				if e.build_timer > 0.0:
					pending_bridge = e
				else:
					_bridge_afford_timer = 0.0
					bridge_plan.pop_front()
					return
	if pending_bridge != null:
		# 给停工桥段补派农民（农民可能阵亡、被防守逻辑拉走或卡在岸边）。
		# 光看“有农民”不够：农民可能卡在够不到的岸边，施工计时一直不动，
		# 这里按施工倒计时是否推进来判断，停 8 秒就重派。
		var gid: int = pending_bridge.get_instance_id()
		if gid != _bridge_pending_gid or absf(pending_bridge.build_timer - _bridge_pending_left) > 0.05:
			_bridge_pending_gid = gid
			_bridge_pending_left = pending_bridge.build_timer
			_bridge_pending_stall = 0.0
		else:
			_bridge_pending_stall += delta
		var stalled: bool = _bridge_pending_stall >= 8.0
		if stalled or int(pending_bridge.get("builder_count_cache")) <= 0 or bool(pending_bridge.get("awaiting_builder")):
			if battle.has_method("assign_builders"):
				if stalled and pending_bridge.has_method("_release_builders"):
					pending_bridge._release_builders()
				battle.assign_builders(pending_bridge, [])
			_bridge_pending_stall = 0.0
		_bridge_afford_timer = 0.0
		return
	if not ai.can_afford_building(BRIDGE_ID):
		_bridge_afford_timer += delta
		if _bridge_afford_timer >= BRIDGE_AFFORD_TIMEOUT:
			# 木材长期不够：放弃这条桥，让下一次规划改走运载船或更短的资源桥。
			bridge_plan.clear()
			_bridge_afford_timer = 0.0
			_register_bridge_failure()
			_plan_timer = 1.0
		return
	_bridge_afford_timer = 0.0
	if battle.has_method("is_valid_bridge_position") and not battle.is_valid_bridge_position(pos):
		# 这个桥位被单位/建筑挡住或地形已变，下一周期重新找
		bridge_plan.clear()
		_register_bridge_failure()
		_plan_timer = 1.0
		return
	if ai.build_building(BRIDGE_ID, pos):
		_bridge_fail_count = 0
		_bridge_retry_at_ms = 0
		_bridge_afford_timer = 0.0
		bridge_plan.pop_front()
		if bridge_plan.is_empty():
			_plan_timer = 0.0
			_recalculate_army_paths()
	else:
		# 附近有敌军或位置被占：放弃本段，下一周期重新找线
		bridge_plan.clear()
		_register_bridge_failure()
		_plan_timer = 1.0

func _register_bridge_failure():
	_bridge_fail_count += 1
	if _bridge_fail_count >= 3:
		# 45 秒后允许再次尝试，避免一次临时失败就让 AI 永远只会坐船
		_bridge_retry_at_ms = Time.get_ticks_msec() + 45000

func _recalculate_army_paths():
	for e in battle.entities.get_children():
		if e is Army and e.health > 0 and ai.entity_belongs_to_me(e):
			if e.has_method("recalculate_path"):
				e.recalculate_path()
	# 新桥会让对岸资源变得可达；立刻重分配一次农民，
	# 否则他们可能还停在修桥前的旧目标/闲置状态里。
	if ai != null and ai.has_method("allocate_workers"):
		ai.allocate_workers()

# ═══════════════════════ 运载船 ═══════════════════════

# 当前时间对应的登陆波次成长档位：每 FLEET_GROWTH_INTERVAL 秒升一档。
func _wave_step() -> int:
	if battle == null:
		return 0
	return int(maxf(0.0, float(battle.game_time)) / FLEET_GROWTH_INTERVAL)

# 在“开始组织新一轮登陆”时固定本波规模，避免舰队出航途中目标继续膨胀。
func _prepare_wave_targets():
	if _wave_transport_target > 0:
		return
	var step: int = _wave_step()
	_wave_transport_target = mini(TRANSPORT_FLEET_SIZE + step, MAX_TRANSPORT_FLEET_SIZE)
	_wave_escort_target = mini(ESCORT_TARGET + step, MAX_ESCORT_TARGET)
	_wave_troop_target = mini(
		MIN_TRANSPORT_TROOPS + step * TROOP_GROWTH_PER_STEP,
		_wave_transport_target * TRANSPORT_CAPACITY
	)
	_wave_troop_quota = 0

func _reset_wave_targets():
	_wave_transport_target = 0
	_wave_escort_target = 0
	_wave_troop_target = 0
	_wave_troop_quota = 0
	_fleet_wait_timer = 0.0

# 本波次最低登船人数：既要保证不是“一艘空船跑过去”，也不能因为常规敌情
# 让 AI 长期只有 20~29 名可抽调的野战兵时，卡在 30 人门槛前永远不出海。
# 运力越小门槛越低，最多仍按 MIN_TRANSPORT_TROOPS 要求。
func _min_wave_troops(capacity: int) -> int:
	# 岛屿图 AI 的野战兵常被守家/守墙占去大半，能抽出的可能只有个位数。
	# 门槛按运力的 1/8 计算，先送一支小型先遣队上岸，后续船队再补人；
	# 总比“永远等 30 人、永远不出海”更接近真实渡海行为。
	return mini(MIN_TRANSPORT_TROOPS, maxi(2, capacity / 8))

func _refresh_fleet():
	_transports.clear()
	_escorts.clear()
	for e in battle.entities.get_children():
		if not (e is Army) or e.health <= 0:
			continue
		if not ai.entity_belongs_to_me(e):
			continue
		if e.entity_id == TRANSPORT_ID:
			# 在远处油田水塘/另一片海湾/内陆湖建造后永远开不到出发岸的船，
			# 不能被当成“已拥有运载船”，否则 AI 不再补造，波次永远凑不齐。
			# 出发岸 20 米以外的运载船一律排除；近岸船坞会补造新的。
			if own_shore_water != Vector3.ZERO:
				var far: bool = e.global_position.distance_to(own_shore_water) > 20.0
				if far:
					e.set_meta("ai_transport_excluded", true)
				elif e.has_meta("ai_transport_excluded"):
					e.remove_meta("ai_transport_excluded")
			if e.has_meta("ai_transport_excluded"):
				continue
			_transports.append(e)
		elif int(e.entity_id) in ESCORT_IDS:
			_escorts.append(e)
	# 先清掉上一轮的护航标记，再把当前选中的护航舰重新标记，
	# 防止海军巡逻/总攻把护航舰队拉去别处。
	for e in battle.entities.get_children():
		if e is Army and int(e.entity_id) in ESCORT_IDS and ai.entity_belongs_to_me(e):
			e.remove_meta("ai_escorting")
	var transport_cap: int = maxi(1, _wave_transport_target)
	var escort_cap: int = maxi(1, _wave_escort_target)
	if _transports.size() > transport_cap:
		_transports = _transports.slice(0, transport_cap)
	if _escorts.size() > escort_cap:
		_escorts = _escorts.slice(0, escort_cap)
	for e in _escorts:
		e.set_meta("ai_escorting", true)

# 只统计能参与渡水的运载船，排除已判定到不了出发岸的远端船。
func _usable_transport_count() -> int:
	var n: int = 0
	for e in battle.entities.get_children():
		if e is Army and e.health > 0 and int(e.entity_id) == TRANSPORT_ID \
				and ai.entity_belongs_to_me(e) and not e.has_meta("ai_transport_excluded"):
			n += 1
	return n

func _tick_transport(delta: float):
	if not _transport_shores_valid:
		return
	if ai._is_defending():
		# 防守时释放护航舰/运载船；不要把海军锁在渡水任务里
		_abort_transport()
		return
	_prepare_wave_targets()
	_refresh_fleet()
	# 没有船坞就永远造不出运载船。优先保证己方登陆岸边有一座船坞，
	# 而不是被动等待 AI 通用的“油田旁船坞”逻辑（很多地图近岸没有油田）。
	_ensure_shore_shipyard()
	# 只有“开始组织新波次”时才必须凑齐本次的全部运载船和护航舰。
	# 舰队已经开始集结/出航后，个别船只战损不应让整波返航，
	# 否则后期护航舰越多、损失一艘就越容易导致登陆部队被反复撤回。
	if _transport_state == STATE_IDLE:
		var fleet_short: bool = _transports.size() < _wave_transport_target \
			or _escorts.size() < _wave_escort_target
		if fleet_short:
			_ensure_transport_tech()
			_ensure_transport_fleet()
			_ensure_escort_ships()
			_fleet_wait_timer += delta
			# 船没造出来/卡在船坞队列时不能无限等满编；超过宽限后按现有
			# 运载船组织一波较小的登陆，至少让海峡图 AI 能越过海面。
			if _fleet_wait_timer < FLEET_ASSEMBLY_TIMEOUT:
				return
			_relax_fleet_requirement()
			if _transports.is_empty():
				return
		else:
			_fleet_wait_timer = 0.0
	elif _transports.is_empty():
		_abort_transport()
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
			var home_slots := _shore_slots(own_shore_water, _transports.size(), 2.5)
			for i in range(_transports.size()):
				if is_instance_valid(_transports[i]):
					_transports[i].move_to(home_slots[i])
			_transport_state = STATE_IDLE
			_transport_timer = 0.0
			# 下一次组织登陆时按当时的时间重新计算更大的波次规模
			_reset_wave_targets()

# 久等仍凑不满编队：把本波目标降到实际拥有的运载船/护航舰数量。
# 只降低“这一波”的目标，下一波仍会按游戏时间重新要求更大的编队。
func _relax_fleet_requirement() -> void:
	var actual_transports: int = _transports.size()
	if actual_transports <= 0:
		return
	_wave_transport_target = actual_transports
	_wave_escort_target = mini(_wave_escort_target, _escorts.size())
	_wave_troop_target = mini(_wave_troop_target, actual_transports * TRANSPORT_CAPACITY)
	_wave_troop_quota = 0
	_fleet_wait_timer = 0.0
	if OS.is_debug_build():
		print("[AI] 运载船编队未凑齐，按现有 %d 艘运载船/ %d 艘护航舰组织登陆" % [
			actual_transports, _escorts.size()
		])

func _tick_fleet_idle(delta: float):
	# 运载船要用“靠岸停泊点”，而不是随便一个水面点
	var slots := _shore_slots(own_shore_water, _transports.size(), 2.5)
	var all_close: bool = true
	for i in range(_transports.size()):
		var ship = _transports[i]
		if not is_instance_valid(ship):
			continue
		if ship.global_position.distance_to(slots[i]) > PARK_DISTANCE or not _is_shore_water_point(ship.global_position):
			ship.move_to(slots[i])
			all_close = false
		else:
			# 到岸边后先停船，等陆军走到船边再上船
			ship.stop_movement()
	if not all_close:
		_fleet_idle_timer += delta
		# 有一两艘船卡在远处水域时，不能拖住整支船队。20 秒后只保留
		# 已经靠近出发岸的船先组织登陆，远处的船排除并让船坞补造。
		if _fleet_idle_timer >= 20.0:
			var usable: Array = []
			for i in range(_transports.size()):
				var s = _transports[i]
				if not is_instance_valid(s):
					continue
				if s.global_position.distance_to(own_shore_water) <= 30.0:
					usable.append(s)
				else:
					s.set_meta("ai_transport_excluded", true)
			if not usable.is_empty():
				_transports = usable
				slots = _shore_slots(own_shore_water, _transports.size(), 2.5)
				all_close = true
				_fleet_idle_timer = 0.0
			else:
				_stall_transport()
				return
		if not all_close:
			if _fleet_idle_timer >= FLEET_IDLE_TIMEOUT:
				_stall_transport()
			return
	_transport_slots = slots
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
		_fleet_idle_timer += delta
		if _fleet_idle_timer >= FLEET_IDLE_TIMEOUT:
			_stall_transport()
		return
	_fleet_idle_timer = 0.0
	# 本波次实际目标兵力：不超过本次运载船总容量。
	# 编队缩水时最低人数也随运力下降，否则 2 艘船永远达不到 30 人。
	var capacity: int = _transports.size() * TRANSPORT_CAPACITY
	var min_troops: int = _min_wave_troops(capacity)
	var desired_troops: int = mini(maxi(_wave_troop_target, min_troops), capacity)
	var units: Array = _pick_units(desired_troops)
	if units.size() < desired_troops:
		# 尽量等本波次要求的兵力到齐；兵力实在不足时等待 TROOP_GATHER_GRACE 后
		# 仍按当前运力能接受的最低人数出发，避免一波永远凑不齐导致 AI 再也不从海上进攻。
		_transport_timer += delta
		if _transport_timer < TROOP_GATHER_GRACE or units.size() < min_troops:
			return
	else:
		_transport_timer = 0.0
	_wave_troop_quota = units.size()
	_transport_units = units
	# 被征用的守家/守资源/守墙兵转为登陆部队，避免 AI 防守逻辑下一帧又把它们拉回去。
	for u in units:
		if is_instance_valid(u):
			u.remove_meta("ai_home_guard")
			u.remove_meta("ai_resource_guard")
			if u.has_meta("ai_wall_guard"):
				if ai != null and ai.has_method("_release_wall_guard"):
					ai._release_wall_guard(u)
				else:
					u.remove_meta("ai_wall_guard")
					u.hold_position = false
	_unit_ship.clear()
	# 按“离哪艘船最近 + 该船还有空位”分配，而不是按队列顺序硬塞。
	# 多艘船沿岸排开时，靠岸单位如果被分到另一端的船，很容易永远走不到
	# 3.5 格登船距离内，最后超时放弃；就近分配能让每艘船都有人上。
	var assigned_counts: Dictionary = {}
	for u in units:
		if not is_instance_valid(u) or not (u is Army):
			continue
		var ship = null
		var best_dist: float = INF
		for candidate in _transports:
			if not is_instance_valid(candidate):
				continue
			var cid: int = candidate.get_instance_id()
			if candidate.get_boarded_count() >= TRANSPORT_CAPACITY:
				continue
			if int(assigned_counts.get(cid, 0)) >= TRANSPORT_CAPACITY:
				continue
			var d: float = _flat_distance(u.global_position, candidate.global_position)
			if d < best_dist:
				best_dist = d
				ship = candidate
		if not is_instance_valid(ship):
			u.remove_meta("ai_transporting")
			continue
		assigned_counts[ship.get_instance_id()] = int(assigned_counts.get(ship.get_instance_id(), 0)) + 1
		_unit_ship[u.get_instance_id()] = ship
		u.set_meta("ai_transporting", true)
		# 每艘船对应的陆军走到该船旁边的陆地，不能隔老远直接“传送”上船
		var landing: Vector3 = _find_land_near(ship.global_position)
		if landing == Vector3.ZERO:
			landing = own_shore_land
		u.move_to(landing)
	_order_escorts_to(own_shore_water, 3.0)
	_transport_state = STATE_GATHER
	_transport_timer = 0.0
	_fleet_idle_timer = 0.0
	_fleet_sail_timer = 0.0

func _tick_fleet_gather(delta: float):
	_transport_timer += delta
	_clean_transport_units()
	if _transport_units.is_empty():
		_reset_transport_state()
		return
	var slots: Array = _transport_slots
	if slots.size() != _transports.size():
		slots = _shore_slots(own_shore_water, _transports.size(), 2.5)
	# 各船各自靠岸即可，不再要求所有运载船同时停在泊位才允许上船。
	# 只要某艘船已经靠岸，它附近的士兵就先上；其他船继续开，避免一艘船
	# 被挤住/寻路慢导致整支舰队都停在岸边等人。
	for i in range(_transports.size()):
		var ship = _transports[i]
		if not is_instance_valid(ship):
			continue
		if ship.global_position.distance_to(slots[i]) > PARK_DISTANCE or not _is_shore_water_point(ship.global_position):
			ship.move_to(slots[i])
		else:
			ship.stop_movement()
	# 只让真正走到船边的单位上船，距离远的继续等
	var waiting: int = 0
	for u in _transport_units:
		if not is_instance_valid(u) or not (u is Army):
			continue
		if u.has_meta("_boarded_on"):
			continue
		var ship = _unit_ship.get(u.get_instance_id())
		if not is_instance_valid(ship):
			u.remove_meta("ai_transporting")
			continue
		if ship.get_boarded_count() >= TRANSPORT_CAPACITY:
			waiting += 1
			continue
		if _flat_distance(u.global_position, ship.global_position) > BOARD_DISTANCE:
			# 单位可能因为岸边拥挤/寻路失败停在半路；路径空时重新下令到船边，
			# 不能只是干等到超时后整支舰队放弃。
			if u._movement.astar_path.is_empty():
				var landing: Vector3 = _find_land_near(ship.global_position)
				if landing != Vector3.ZERO:
					u.move_to(landing)
			waiting += 1
			continue
		ship.board_unit(u)
	var boarded_units: Array = []
	var boarded_now: int = 0
	for u in _transport_units:
		if is_instance_valid(u) and u.has_meta("_boarded_on"):
			boarded_units.append(u)
			boarded_now += 1
	# 已经够本波次目标人数时不要为了等最后几个掉队的兵一直拖到 50 秒超时；
	# 给落单单位一个短暂追赶窗口后直接出发。
	var capacity: int = _transports.size() * TRANSPORT_CAPACITY
	var min_troops: int = _min_wave_troops(capacity)
	var troop_quota: int = maxi(_wave_troop_quota, min_troops)
	var stop_waiting: bool = _transport_timer > BOARD_WAIT_TIMEOUT or (boarded_now >= troop_quota and _transport_timer > 8.0)
	for u in _transport_units:
		if is_instance_valid(u) and not u.has_meta("_boarded_on") and stop_waiting:
			u.remove_meta("ai_transporting")
	if waiting > 0 and not stop_waiting:
		return
	_transport_units = boarded_units
	if _transport_units.size() < min_troops:
		# 连当前运力能接受的最低人数都没上船，回岸边重来，不把过小的部队送过去
		_abort_transport()
		return
	_transport_state = STATE_SAIL
	_transport_timer = 0.0
	_fleet_sail_timer = 0.0
	_escort_advanced = false
	_order_fleet_sail()

func _tick_fleet_sail(delta: float):
	_transport_timer += delta
	_fleet_sail_timer += delta
	var slots := _shore_slots(enemy_shore_water, _transports.size(), 2.5)
	var all_unloaded: bool = true
	var any_ship: bool = false
	for i in range(_transports.size()):
		var ship = _transports[i]
		if not is_instance_valid(ship):
			continue
		any_ship = true
		if ship.get_boarded_count() <= 0:
			continue
		# 必须真正靠到敌岸浅水/岸边才能下人，不能在海中间直接卸载
		if ship.global_position.distance_to(slots[i]) > UNLOAD_DISTANCE or not _is_shore_water_point(ship.global_position):
			ship.move_to(slots[i])
			all_unloaded = false
			continue
		ship.stop_movement()
		var land: Vector3 = _find_land_near(ship.global_position)
		if land == Vector3.ZERO:
			land = enemy_shore_land
		if land == Vector3.ZERO:
			land = own_shore_land
		if land != Vector3.ZERO:
			ship.unboard_at(land)
		else:
			all_unloaded = false
	if not any_ship:
		_reset_transport_state()
		return
	if not _escort_advanced and _transport_timer > 8.0:
		_escort_advanced = true
		_order_escorts_to(enemy_shore_water, 3.0)
	# 没全部靠岸就继续等/继续开，不在深海放人。
	# 但长时间到不了敌岸时必须放弃当前登陆场，否则整支舰队会在海上永航。
	if not all_unloaded:
		if _fleet_sail_timer >= FLEET_SAIL_TIMEOUT:
			_stall_transport()
		return
	_fleet_sail_timer = 0.0
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
	var slots := _shore_slots(enemy_shore_water, _transports.size(), 2.5)
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

func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()

func _is_shore_water_point(pos: Vector3) -> bool:
	if not _is_water_point(pos):
		return false
	var g: Vector2i = battle.world_to_grid(pos)
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var nx: int = g.x + d.x
		var ny: int = g.y + d.y
		if nx < 0 or nx >= RTSConfig.MAP_SIZE or ny < 0 or ny >= RTSConfig.MAP_SIZE:
			continue
		# 浅滩（overlay==3）陆军可以走，也算能靠岸
		if battle.get_terrain_at_grid(nx, ny) != 2 or battle.get_overlay_at_grid(nx, ny) == 3:
			return true
	return false

# 运载船必须停在“靠岸水面”，不能停在离岸很远的水里
func _shore_slots(base: Vector3, count: int, spacing: float) -> Array:
	if count <= 0:
		return []
	var generic := _fleet_slots(base, count, spacing)
	var all_shore: bool = true
	for p in generic:
		if not _is_shore_water_point(p):
			all_shore = false
			break
	if all_shore:
		return generic
	var center: Vector2i = battle.world_to_grid(base)
	var radius: int = int(ceil(spacing * float(count))) + 8
	var candidates: Array = []
	for dx in range(-radius, radius + 1):
		for dy in range(-radius, radius + 1):
			var gx: int = center.x + dx
			var gy: int = center.y + dy
			if gx < 0 or gx >= RTSConfig.MAP_SIZE or gy < 0 or gy >= RTSConfig.MAP_SIZE:
				continue
			if not _is_shore_water_point(battle.grid_to_world(gx, gy)):
				continue
			var p: Vector3 = battle.grid_to_world(gx, gy)
			candidates.append({"p": p, "d": p.distance_to(base)})
	candidates.sort_custom(func(a, b): return float(a["d"]) < float(b["d"]))
	var out: Array = []
	for item in candidates:
		if out.size() >= count:
			break
		var ok: bool = true
		for p in out:
			if p.distance_to(item["p"]) < spacing * 0.9:
				ok = false
				break
		if ok:
			out.append(item["p"])
	if out.is_empty():
		out.append(base)
	while out.size() < count:
		out.append(out[0])
	return out

func _reset_transport_state():
	_abort_transport()

func _clean_transport_units():
	var alive: Array = []
	for u in _transport_units:
		if is_instance_valid(u) and u is Army and u.health > 0:
			alive.append(u)
	_transport_units = alive

func _transport_candidate_less(a: Dictionary, b: Dictionary) -> bool:
	# 渡海征用优先级：空闲兵 > 守家/守资源兵 > 守墙兵。
	# 只有前两类不够时才抽守墙兵，避免为了登陆把城墙直接抽空。
	if int(a["priority"]) != int(b["priority"]):
		return int(a["priority"]) < int(b["priority"])
	return float(a["dist"]) < float(b["dist"])

func _pick_units(max_count: int) -> Array:
	var candidates: Array = []
	var exclusions: Array = [5, 6, 9, 10, 13, 14, 19, 39, 40, 43, 44, 45, 46, 47, 48, 49, 50, 51, 55, 56, 57]
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
		if e.has_meta("ai_harass") or e.has_meta("ai_transporting"):
			continue
		# 守墙兵是最后一级可征用兵：岛屿图的 AI 常把全部陆军派去守墙，
		# 如果这里直接排除，渡海模块就会永远显示 0 个可用士兵。
		# 仍按“空闲 > 守家/守资源 > 守墙”的顺序抽人，前两类足够时不会动城墙。
		var is_wall_guard: bool = e.has_meta("ai_wall_guard")
		var priority: int = 0
		if is_wall_guard:
			priority = 2
		elif e.has_meta("ai_home_guard") or e.has_meta("ai_resource_guard"):
			priority = 1
		var dist: float = e.global_position.distance_to(own_shore_land)
		candidates.append({"unit": e, "dist": dist, "priority": priority})
	if candidates.is_empty():
		return []
	candidates.sort_custom(_transport_candidate_less)
	var out: Array = []
	for item in candidates:
		out.append(item["unit"])
		if out.size() >= max_count:
			break
	return out

func _find_land_near(pos: Vector3) -> Vector3:
	var center: Vector2i = battle.world_to_grid(pos)
	# 搜索半径放大到 11 格：原来的 8 格在宽阔水域里常常找不到岸，
	# 单位就被一直留在船里下不来。
	for radius in range(0, 11):
		for dx in range(-radius, radius + 1):
			for dy in range(-radius, radius + 1):
				if maxi(absi(dx), absi(dy)) != radius:
					continue
				var gx: int = center.x + dx
				var gy: int = center.y + dy
				if gx < 0 or gx >= RTSConfig.MAP_SIZE or gy < 0 or gy >= RTSConfig.MAP_SIZE:
					continue
				# 普通山地不可登陆；只有缓坡/台地(4/5)能让陆军上岸。
				# 浅滩（overlay==3）陆军能走，算合格。
				var terrain: int = int(battle.get_terrain_at_grid(gx, gy))
				if terrain < 0:
					continue
				if terrain != 2 and battle.is_cliff_tile(gx, gy):
					continue
				if terrain == 2 and int(battle.get_overlay_at_grid(gx, gy)) != 3:
					continue
				return battle.grid_to_world(gx, gy)
	return Vector3.ZERO

# ═══════════════════════ 运载船前置科技 ═══════════════════════

# 船坞必须开在“能航行到己方出发岸”的水域里。只按直线距离判断会选中
# 城堡旁的内陆油田水塘：船虽然造得出来，却永远开不到登陆岸。
func _shipyard_reaches_own_water(sy: Building) -> bool:
	if not is_instance_valid(sy) or own_shore_water == Vector3.ZERO:
		return false
	var shore_grid: Vector2i = battle.world_to_grid(own_shore_water)
	var key: String = "%d@%d,%d" % [sy.get_instance_id(), shore_grid.x, shore_grid.y]
	if _shipyard_water_cache.has(key):
		return bool(_shipyard_water_cache[key])
	var start: Vector2i = battle.world_to_grid(sy.global_position)
	var target: Vector2i = Vector2i(-1, -1)
	# 船坞在陆地上，找它旁边最近的一格水面作为 BFS 起点。
	for radius in range(0, 4):
		for dx in range(-radius, radius + 1):
			for dz in range(-radius, radius + 1):
				if maxi(absi(dx), absi(dz)) != radius:
					continue
				var gx: int = start.x + dx
				var gz: int = start.y + dz
				if gx < 0 or gx >= RTSConfig.MAP_SIZE or gz < 0 or gz >= RTSConfig.MAP_SIZE:
					continue
				if battle.get_terrain_at_grid(gx, gz) == 2:
					target = Vector2i(gx, gz)
					break
			if target.x >= 0:
				break
		if target.x >= 0:
			break
	var reachable: bool = false
	if target.x >= 0 and battle.get_terrain_at_grid(shore_grid.x, shore_grid.y) == 2:
		if target == shore_grid:
			reachable = true
		else:
			var visited: Dictionary = {shore_grid: true}
			var queue: Array = [shore_grid]
			var head: int = 0
			while head < queue.size() and visited.size() < 12000:
				var c: Vector2i = queue[head]
				head += 1
				if c == target:
					reachable = true
					break
				for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var n: Vector2i = c + d
					if visited.has(n):
						continue
					if n.x < 0 or n.x >= RTSConfig.MAP_SIZE or n.y < 0 or n.y >= RTSConfig.MAP_SIZE:
						continue
					if battle.get_terrain_at_grid(n.x, n.y) != 2:
						continue
					visited[n] = true
					queue.append(n)
	_shipyard_water_cache[key] = reachable
	return reachable

# 己方登陆岸边没有船坞时，直接在岸边找一块合法陆地建造。
# AI 通用的 _manage_shipyards 只会在“临岸且 10 格内有油田”的位置建，
# 岛屿/无油地图会因此永远凑不出运载船。
func _ensure_shore_shipyard():
	if own_shore_water == Vector3.ZERO or own_shore_land == Vector3.ZERO:
		return
	# 只保留一座“离出发岸最近”的渡水专用船坞。
	# 之前只要 16 米内有船坞就标记并返回，岛屿图第二座船坞也容易留下旧标记，
	# 运载船就会从远处船坞下水，随后又被 _refresh_fleet 以“离岸超过20米”排除。
	var best: Building = null
	var best_dist: float = INF
	for e in battle.entities.get_children():
		if not (e is Building) or e.entity_id != SHIPYARD_ID or e.health <= 0:
			continue
		if not ai.entity_belongs_to_me(e):
			continue
		var near: bool = e.global_position.distance_to(own_shore_water) <= 16.0 \
			and _shipyard_reaches_own_water(e)
		if not near:
			if e.has_meta("ai_transport_shipyard"):
				e.remove_meta("ai_transport_shipyard")
			continue
		var d: float = e.global_position.distance_to(own_shore_water)
		if d < best_dist:
			best = e
			best_dist = d
	if is_instance_valid(best):
		for e in battle.entities.get_children():
			if e is Building and e.entity_id == SHIPYARD_ID and e != best:
				if e.has_meta("ai_transport_shipyard"):
					e.remove_meta("ai_transport_shipyard")
		best.set_meta("ai_transport_shipyard", true)
		_drop_remote_transport_orders(best)
		return
	if not ai.can_afford_building(SHIPYARD_ID):
		return
	var pos: Vector3 = _find_shore_shipyard_pos()
	if pos == Vector3.ZERO:
		return
	if not ai.build_building(SHIPYARD_ID, pos):
		return
	var built: Building = null
	for e in battle.entities.get_children():
		if e is Building and e.entity_id == SHIPYARD_ID and e.health > 0 and ai.entity_belongs_to_me(e):
			if e.global_position.distance_to(pos) <= 3.0:
				built = e
				break
	if is_instance_valid(built):
		built.set_meta("ai_transport_shipyard", true)
		_drop_remote_transport_orders(built)

# 运载船只能从渡水专用船坞生产。远处船坞排出的运载船开不到出发岸，
# 留下来只会白吃木头/金币和人口，所以每次确认专用船坞后清掉这些排队项。
func _drop_remote_transport_orders(keep: Building) -> void:
	for e in battle.entities.get_children():
		if not (e is Building) or e.entity_id != SHIPYARD_ID or e == keep or e.health <= 0:
			continue
		if not ai.entity_belongs_to_me(e):
			continue
		while e.production_queue.has(TRANSPORT_ID):
			e.production_queue.erase(TRANSPORT_ID)

func _find_shore_shipyard_pos() -> Vector3:
	var base: Vector2i = battle.world_to_grid(own_shore_land)
	for radius in range(1, 13):
		for dx in range(-radius, radius + 1):
			for dz in range(-radius, radius + 1):
				if maxi(absi(dx), absi(dz)) != radius:
					continue
				var gx: int = base.x + dx
				var gz: int = base.y + dz
				if gx < 0 or gx >= RTSConfig.MAP_SIZE or gz < 0 or gz >= RTSConfig.MAP_SIZE:
					continue
				if battle.get_terrain_at_grid(gx, gz) != 0:
					continue
				var has_water: bool = false
				for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var nx: int = gx + d.x
					var nz: int = gz + d.y
					if nx < 0 or nx >= RTSConfig.MAP_SIZE or nz < 0 or nz >= RTSConfig.MAP_SIZE:
						continue
					if battle.get_terrain_at_grid(nx, nz) == 2:
						has_water = true
						break
				if not has_water:
					continue
				var pos: Vector3 = battle.grid_to_world(gx, gz)
				if ai.has_method("_can_place_ai_building") and not ai._can_place_ai_building(SHIPYARD_ID, pos):
					continue
				return pos
	return Vector3.ZERO

# 优先使用靠近登陆岸的专用船坞；只有没有专用船坞时才退回第一座己方船坞。
# 否则 AI 可能把运载船科技/生产排到远处只产渔船/战船的油田船坞上。
func _find_transport_shipyard() -> Building:
	var fallback: Building = null
	for e in battle.entities.get_children():
		if not (e is Building) or e.health <= 0 or e.entity_id != SHIPYARD_ID:
			continue
		if not ai.entity_belongs_to_me(e) or not e.has_meta("ai_transport_shipyard"):
			continue
		if not _shipyard_reaches_own_water(e):
			continue
		if e.build_timer <= 0.0 and e.upgrade_level >= TRANSPORT_SHIPYARD_LEVEL:
			return e as Building
		if fallback == null:
			fallback = e as Building
	if fallback != null:
		return fallback
	return null

func _ensure_transport_tech():
	var sy = _find_transport_shipyard()
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
	if sy.can_upgrade() and ai.can_afford_upgrade(SHIPYARD_ID):
		# 直接升级这座“渡水专用”船坞。ai.upgrade_building(23) 会从所有船坞里
		# 挑第一个可升级的，经常升级到内陆油田船坞，而登陆岸这座一直停在 2 级，
		# 运载船科技永远不够。
		sy.perform_upgrade(battle)

func _ensure_transport_fleet():
	# 只统计已经下水的运载船。count_unit 默认包含生产队列，若把队列里的船
	# 当成已拥有，就会出现“实际只有2艘、队列里4艘、AI以为够了不再下单”的卡死。
	if _usable_transport_count() >= _wave_transport_target:
		return
	var sy = _find_transport_shipyard()
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
		if sy.try_produce(TRANSPORT_ID):
			# 船坞平时会被战船/渔船排满；运载船如果排在十几艘船后面，
			# AI 可能几分钟都凑不齐本波次的运载船。把运载船插到当前生产项之后，
			# 保留正在建造的那一艘的计时，同时让运载船尽快下水。
			var idx: int = sy.production_queue.rfind(TRANSPORT_ID)
			if idx > 1:
				sy.production_queue.remove_at(idx)
				sy.production_queue.insert(1, TRANSPORT_ID)

func _ensure_escort_ships():
	# 同上：只算已经下水的护航舰，队列里的不计入“已具备”。
	var total: int = ai.count_unit(13, false) + ai.count_unit(39, false) + ai.count_unit(40, false)
	if total >= _wave_escort_target:
		return
	var sy = _find_transport_shipyard()
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

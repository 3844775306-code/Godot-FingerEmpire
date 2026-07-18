# scripts/ai/AI.gd
# Merged AI Controller — single-player + online dual-mode
extends Node

class_name AIController

enum Phase { PRODUCTION, DEVELOPMENT, ASSAULT }
enum LateTactic { NONE, HARASS, OVERWHELM, RAID, DEFEND }

@onready var battle = get_parent()

var phase: int = Phase.PRODUCTION
var timer: float = 0.0
var think_interval: float = 2.0
var worker_allocate_timer: float = 0.0
const WORKER_ALLOCATE_INTERVAL: float = 3.0
var last_attack_time: float = -999.0
const ATTACK_COOLDOWN: float = 120.0
var production_step: int = 0

var wanted_buildings: Array = [20, 21, 23, 25, 42, 26, 24, 29, 41, 52, 53]
var wanted_units: Array = [11,12,15,16,17,18,35,36,37,38,39,40,13,43,44,45,46,47,48,49,50]
var target_army_count: int = 12
var target_house_count: int = 8
var desired_worker_count: int = 8

var cached_shipyard_pos: Vector3 = Vector3.ZERO
var defense_line_built: bool = false
var defense_check_timer: float = 0.0
const DEFENSE_CHECK_INTERVAL: float = 120.0
var wall_positions: Array = []
var tower_positions: Array = []
var current_tactic: int = LateTactic.NONE
const TACTIC_COOLDOWN: float = 25.0
var last_tactic_time: float = -999.0
var nation = -1

var _ai_income_timer: float = 10.0
var _ai_res_snapshot: Dictionary = {}
var _ai_res_income: Dictionary = {}
var _ai_income_rate: Dictionary = {"gold":0,"wood":0,"stone":0,"food":0,"oil":0}
var _territory_timer: float = 120.0
var _hunt_timer: float = 0.0
var _hunt_target = null
var _hunt_target_id: int = -1

var my_peer_id: int = -1
var my_team: int = RTSConfig.Team.RED

const WAREHOUSE_MAX_COUNT: int = 5
const HOME_ASSEMBLE_RANGE: float = 50.0
const MILITARY_PRODUCER_TARGETS = {21: 3, 24: 2, 29: 2}
const BOAT_VISION_RANGE: float = 12.0
const SHIPYARD_SPACING: float = 35.0
var built_shipyard_pos: Array[Vector3] = []

const RAID_MIN_SPECIAL_TROOPS: int = 3
const RAID_FLANK_MIN: float = 28.0
const RAID_FLANK_MAX: float = 46.0
const RAID_WAIT_TIME: float = 5.0
const AVOID_DEFENSE_RANGE: float = 22.0
const RAID_UNIT: int = 15
const WALL_COUNT: int = 12
const WALL_SPACING: float = 1.3
const TOWER_SPACING: float = 3.0
const DEFENSE_FRONT_DIST: float = 8.0
const SAFE_DEFEND_RADIUS: float = 45.0

# ═══ Resource wrappers ═══
func _get_resources() -> Dictionary:
	if battle is OnlineBattleManager and my_peer_id != -1:
		return battle.player_resources.get(my_peer_id, {})
	return battle.enemy_resources

func _get_limits() -> Dictionary:
	if battle is OnlineBattleManager and my_peer_id != -1:
		return battle.player_limits_dict.get(my_peer_id, {})
	return battle.enemy_resource_limits

func _get_population() -> Dictionary:
	if battle is OnlineBattleManager and my_peer_id != -1:
		return battle.player_population.get(my_peer_id, {"current":0,"max":30})
	return {"current": battle.enemy_pop, "max": battle.enemy_max_pop}

func _can_train_unit() -> bool:
	if battle is OnlineBattleManager and my_peer_id != -1:
		return battle.can_player_train(my_peer_id)
	return battle.can_train_unit(RTSConfig.Team.RED)

func _deduct_resources(cost: Dictionary) -> bool:
	if battle is OnlineBattleManager and my_peer_id != -1:
		return battle.deduct_player_resources(my_peer_id, cost)
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
func count_unit(id: int) -> int:
	var cnt = 0
	for entity in battle.entities.get_children():
		if entity is Army and entity.health > 0 and entity.entity_id == id:
			if my_peer_id != -1 and entity.owner_peer_id != my_peer_id: continue
			if my_peer_id == -1 and entity.team != my_team: continue
			cnt += 1
	return cnt

func count_building(id: int) -> int:
	var cnt = 0
	for entity in battle.entities.get_children():
		if entity is Building and entity.health > 0 and entity.entity_id == id:
			if my_peer_id != -1 and entity.owner_peer_id != my_peer_id: continue
			if my_peer_id == -1 and entity.team != my_team: continue
			cnt += 1
	return cnt

func count_military(peer: int) -> int:
	var total = 0
	for entity in battle.entities.get_children():
		if entity is Army and entity.health > 0:
			if my_peer_id != -1 and entity.owner_peer_id != peer: continue
			if my_peer_id == -1 and entity.team != peer: continue
			if entity.entity_id != 10 and entity.entity_id != 14 and entity.entity_id not in [46,47,48,50]:
				total += 1
	return total

func count_military_by_team(tm: int) -> int:
	var total = 0
	for entity in battle.entities.get_children():
		if entity is Army and entity.health > 0:
			if entity.team != tm: continue
			if entity.entity_id != 10 and entity.entity_id != 14 and entity.entity_id not in [46,47,48,50]:
				total += 1
	return total

# ═══ Economy ═══
func can_afford(unit_id: int) -> bool:
	var cfg = EntityDatabase.get_config(unit_id)
	if not cfg: return false
	var cost = cfg.get("cost", {})
	var res = _get_resources()
	for k in cost: if res.get(k, 0) < cost[k]: return false
	return true

func can_afford_building(building_id: int) -> bool:
	var cfg = EntityDatabase.get_config(building_id)
	if not cfg: return false
	var cost = cfg.get("cost", {})
	var res = _get_resources()
	for k in cost: if res.get(k, 0) < cost[k]: return false
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
				return true
	return false

# ═══ Production ═══
func produce_unit(unit_id: int) -> bool:
	var produced = 0
	for entity in battle.entities.get_children():
		if produced >= 3: break
		if entity is Building and entity.health > 0 and entity.build_timer <= 0:
			if not entity_belongs_to_me(entity): continue
			if entity.try_produce(unit_id):
				produced += 1
	return produced > 0

func build_building(building_id: int, pos: Vector3):
	var cfg = EntityDatabase.get_config(building_id)
	if not cfg: return
	var cost = cfg.get("cost", {})
	if not _deduct_resources(cost): return
	cfg["owner_peer_id"] = my_peer_id
	var team = RTSConfig.Team.RED
	if battle is OnlineBattleManager and my_peer_id != -1:
		team = battle.player_info[my_peer_id].team
	var b = battle.spawn_entity(cfg, team, pos)
	if b:
		b.start_construction(5.0, cfg)
		if building_id == 25 or building_id == 26:
			if battle is OnlineBattleManager and my_peer_id != -1:
				battle.increase_player_population(my_peer_id)
			else:
				battle.increase_population(team)

func upgrade_building(building_id: int):
	for entity in battle.entities.get_children():
		if entity is Building and entity.health > 0 and entity.entity_id == building_id:
			if not entity_belongs_to_me(entity): continue
			entity.perform_upgrade(battle)
			break

# ═══ Counter matrix ═══
const COUNTER_MATRIX = {
	11: [12,16,17,33,37], 15: [11,34,35,36], 12: [15,16,17,13,38],
	33: [15,16,17,13,38], 16: [15,13,38], 17: [15,13,38], 18: [11,34,36],
	13: [16,17,39], 34: [12,33,37], 35: [12,33,37], 36: [12,33,37,39],
	37: [15,13,38,40], 38: [36,11,34,35], 39: [13,40,17], 40: [13,16,17],
}

func analyze_enemy_composition() -> Dictionary:
	var comp = {}
	for entity in battle.entities.get_children():
		if entity is Army and entity.health > 0:
			if entity_belongs_to_me(entity): continue
			var uid = entity.entity_id
			if uid in COUNTER_MATRIX:
				comp[uid] = comp.get(uid, 0) + 1
	return comp

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
	return list

# ═══ Init ═══
func _ready():
	_add_nation_special_unit()
	_create_debug_panel()

func _process(delta):
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
	if timer <= 0:
		timer = think_interval
		decide(think_interval)
	worker_allocate_timer -= delta
	if worker_allocate_timer <= 0:
		worker_allocate_timer = WORKER_ALLOCATE_INTERVAL
		allocate_workers()
	if defense_line_built:
		defense_check_timer -= delta
		if defense_check_timer <= 0:
			defense_check_timer = DEFENSE_CHECK_INTERVAL
			check_defense_line()

# ═══ Decide ═══
func decide(_delta):
	if not battle: return
	if battle is OnlineBattleManager and my_peer_id != -1:
		battle.update_player_limits(my_peer_id)
		battle.update_player_population(my_peer_id)
	else:
		battle.update_resource_limits(RTSConfig.Team.RED)
		battle.update_population_limits()
	clear_invalid_targets()
	if not get_peer_castle(my_peer_id):
		queue_free()
		return
	var workers = count_unit(10)
	var warehouses = count_building(22)

	if phase == Phase.PRODUCTION:
		if production_step == 0:
			if workers < desired_worker_count and can_afford(10) and _can_train_unit():
				produce_unit(10)
			else:
				if can_afford_upgrade(20):
					upgrade_building(20)
				elif workers >= desired_worker_count and count_building(20) > 0:
					var castle = get_peer_castle(my_peer_id)
					if castle and castle.upgrade_level >= 2:
						production_step = 1
		elif production_step == 1:
			if count_building(23) < 1 and can_afford_building(23):
				_cache_shipyard_location()
				if cached_shipyard_pos != Vector3.ZERO:
					build_building(23, cached_shipyard_pos)
			elif count_unit(14) < 1 and count_building(23) > 0 and can_afford(14) and _can_train_unit():
				produce_unit(14)
			elif warehouses < 1 and can_afford_building(22):
				var castle = get_peer_castle(my_peer_id)
				if castle:
					build_building(22, castle.global_position + Vector3(randf_range(-10,10), 0, randf_range(-10,10)))
			else:
				if count_building(23) >= 1 and warehouses >= 1:
					phase = Phase.DEVELOPMENT

	elif phase == Phase.DEVELOPMENT:
		_ensure_merchants()
		_ai_hunt_animals(_delta)
		_check_hunt_cleanup()
		_manage_shipyards()
		_process_line_1()
		_process_line_3()
		if _try_produce_merchants_or_officials():
			pass
		elif randf() < 0.5:
			_process_line_upgrade()
		else:
			_process_line_military()
		_process_line_4()
		_process_line_5()
		_ai_garrison_officials()
		update_tactic(_delta)

	if OS.is_debug_build():
		update_debug_label()

# ═══ Castle helpers ═══
func get_team_castle(tm) -> Building:
	for entity in battle.entities.get_children():
		if entity is Building and entity.entity_id == 20 and entity.team == tm and entity.health > 0:
			return entity
	return null

func get_peer_castle(peer) -> Building:
	for entity in battle.entities.get_children():
		if entity is Building and entity.entity_id == 20:
			if my_peer_id != -1 and entity.owner_peer_id == peer: return entity
			if my_peer_id == -1 and entity.team == my_team: return entity
	return null

func find_valid_build_position(near_pos: Vector3, building_id: int) -> Vector3:
	var cfg = EntityDatabase.get_config(building_id)
	var radius = cfg.get("body_radius", 1.0)
	for dist in [3, 5, 8, 12, 16, 20]:
		for _try in range(8):
			var test = near_pos + Vector3(cos(randf_range(0, TAU))*dist, 0, sin(randf_range(0, TAU))*dist)
			var overlap = false
			for entity in battle.entities.get_children():
				if not (entity is GameEntity) or entity.health <= 0: continue
				if test.distance_to(entity.global_position) < (radius + entity.body_radius + 2.0):
					overlap = true; break
			if not overlap and _is_valid_build_ground(test):
				return test
	# Fallback: guaranteed offset from castle
	return near_pos + Vector3(cos(randf_range(0, TAU))*20, 0, sin(randf_range(0, TAU))*20)
	
	

func _get_build_position(b_id: int) -> Vector3:
	var castle = get_peer_castle(my_peer_id)
	if castle: return find_valid_build_position(castle.global_position, b_id)
	return Vector3.ZERO

# ═══ Worker allocation ═══
var allocate_timers = 0

func allocate_workers():
	var workers = []
	for entity in battle.entities.get_children():
		if entity is Army and entity.health > 0 and entity.entity_id == 10 and entity_belongs_to_me(entity):
			workers.append(entity)

	desired_worker_count = 15 if phase >= Phase.DEVELOPMENT else 8

	var non_delivering = []
	for w in workers:
		if w.current_order != "deliver": non_delivering.append(w)

	if workers.size() < desired_worker_count:
		if can_afford(10) and _can_train_unit(): produce_unit(10)
		for w in non_delivering:
			var target = find_best_resource_for_worker(w, {"food": 100})
			if target: w.gather_at(target)
		return

	allocate_timers += 1
	if allocate_timers > 20:
		consider_warehouse_near_farmer()
		allocate_timers = 0
		var res = _get_resources()
		var limits = _get_limits()
		var phase_weights = _get_phase_weights()
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
			if w.current_order == "deliver":
				for rk in ["gold","wood","stone","food"]:
					if w.cargo.get(rk, 0) > 0:
						current[rk] = current.get(rk, 0) + 1
						if current[rk] > scarcity.get(rk, 2): idle.append(w)
						break
		for w in idle:
			var best_rk = ""; var best_gap = -1.0
			for rk in scarcity:
				var gap = scarcity[rk] - current.get(rk, 0)
				if gap > best_gap: best_gap = gap; best_rk = rk
			if best_rk != "":
				var target = find_best_resource_for_worker(w, {best_rk: 100})
				if target: w.gather_at(target); current[best_rk] = current.get(best_rk, 0) + 1

func _get_build_completion() -> float:
	var total_targets = 0.0; var built = 0.0
	for b_id in wanted_buildings:
		var target = MILITARY_PRODUCER_TARGETS.get(b_id, 1)
		total_targets += target
		built += min(count_building(b_id), target)
	return built / max(total_targets, 1.0)

func _get_phase_weights() -> Dictionary:
	if phase == Phase.PRODUCTION:
		if count_unit(10) < 8:
			return {"gold": 0.5, "wood": 1.5, "stone": 0.8, "food": 5.0}
		else:
			return {"gold": 1.0, "wood": 3.0, "stone": 2.0, "food": 1.5}
	else:
		var build_pct = _get_build_completion()
		if build_pct < 0.4:
			return {"gold": 2.0, "wood": 4.5, "stone": 3.5, "food": 2.0}
		elif build_pct < 0.75:
			return {"gold": 3.0, "wood": 3.0, "stone": 4.0, "food": 3.0}
		else:
			return {"gold": 4.0, "wood": 2.0, "stone": 5.0, "food": 3.0}

func clear_invalid_targets():
	for entity in battle.entities.get_children():
		if entity is Army and entity.health > 0 and entity_belongs_to_me(entity):
			if entity.current_target and not is_instance_valid(entity.current_target):
				entity.current_target = null
				entity.current_order = ""

func find_best_resource_for_worker(worker: Army, priority_score: Dictionary) -> WorldResource:
	var best = null; var best_score = -1
	var enemy_team = RTSConfig.Team.BLUE if my_team == RTSConfig.Team.RED else RTSConfig.Team.RED
	for entity in battle.entities.get_children():
		if entity is WorldResource and entity.health > 0:
			var type = entity.resource_type
			if type in priority_score:
				var score = priority_score[type] - worker.global_position.distance_to(entity.global_position) * 0.01
				for e in battle.entities.get_children():
					if e is Army and e.team == enemy_team and e.health > 0 and e.entity_id not in [10,14,43,44,45]:
						if e.global_position.distance_to(entity.global_position) < 10.0: score -= 500; break
				if score > best_score: best_score = score; best = entity
	return best

func attack_move(target_position: Vector3, max_units: int):
	var sent = 0
	for entity in battle.entities.get_children():
		if sent >= max_units: break
		if entity is Army and entity.health > 0 and entity.entity_id not in [10,14] and entity_belongs_to_me(entity):
			entity.attack_move_to(target_position)
			sent += 1

func an_attack() -> bool:
	var now = Time.get_ticks_msec() / 1000.0
	if now - last_attack_time < 10.0: return false
	last_attack_time = now
	return true

func _should_build_or_upgrade(b_id: int) -> bool:
	if b_id == 25 and count_building(25) >= 5: return false
	if count_building(b_id) == 0: return true
	for entity in battle.entities.get_children():
		if entity is Building and entity.health > 0 and entity.entity_id == b_id:
			if not entity_belongs_to_me(entity): continue
			if entity.upgrade_level < entity.max_upgrade_level: return true
	return false

# ═══ Warehouse ═══
func consider_warehouse_near_farmer():
	var castle = get_peer_castle(my_peer_id)
	if not castle: return
	if count_building(22) >= WAREHOUSE_MAX_COUNT: return
	var res = _get_resources(); var limits = _get_limits()
	var farmer_data = []
	for entity in battle.entities.get_children():
		if entity is Army and entity.health > 0 and entity.entity_id == 10 and entity_belongs_to_me(entity):
			var tgt = entity.current_target
			if is_instance_valid(tgt) and tgt is WorldResource: farmer_data.append({"farmer": entity, "resource": tgt})
	if farmer_data.is_empty(): return
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
		if s1+s2+s3+s4 > best_score:
			best_score = s1+s2+s3+s4
			for _t in range(5):
				var tp = rp + Vector3(randf_range(-2.5,2.5), 0, randf_range(-2.5,2.5))
				if _is_valid_build_ground(tp): best_pos = tp; break
			if best_pos == Vector3.ZERO: best_pos = rp + Vector3(randf_range(-2,2), 0, randf_range(-2,2))
	if best_pos != Vector3.ZERO and can_afford_building(22): build_building(22, best_pos)

func _is_valid_build_ground(world_pos: Vector3) -> bool:
	var gx = int(world_pos.x + RTSConfig.MAP_SIZE / 2); var gz = int(world_pos.z + RTSConfig.MAP_SIZE / 2)
	if gx < 0 or gx >= RTSConfig.MAP_SIZE or gz < 0 or gz >= RTSConfig.MAP_SIZE: return false
	if battle.get_terrain_at_grid(gx, gz) != 0: return false
	for e in battle.entities.get_children():
		if e is GameEntity and e.team == my_team and e.health > 0:
			if e.global_position.distance_to(world_pos) < 10.0: return false
	for e in battle.entities.get_children():
		if e is Building and e.team == my_team and e.health > 0:
			if e.global_position.distance_to(world_pos) < (e.body_radius + 3.0): return false
	var enemy_team = RTSConfig.Team.BLUE if my_team == RTSConfig.Team.RED else RTSConfig.Team.RED
	for e in battle.entities.get_children():
		if e is GameEntity and e.team == enemy_team and e.health > 0:
			if e.global_position.distance_to(world_pos) < 10.0: return false
	return true

# ═══ Territory ═══
func _ai_expand_territory():
	_territory_timer -= 2.0
	if _territory_timer > 0: return
	_territory_timer = 120.0
	var castle = get_peer_castle(my_peer_id)
	if not castle: return
	if count_building(42) == 0: return
	for e in battle.entities.get_children():
		if e is WorldResource and e.health > 0:
			var rtype = e.resource_type; var dist = e.global_position.distance_to(castle.global_position)
			var nearby = 0; var gold_nearby = 0; var stone_nearby = 0
			for e2 in battle.entities.get_children():
				if e2 is WorldResource and e2.health > 0 and e2 != e:
					if e2.global_position.distance_to(e.global_position) < 8:
						nearby += 1
						if e2.resource_type == "gold": gold_nearby += 1
						if e2.resource_type == "stone": stone_nearby += 1
			if (rtype in ["gold","stone"] and dist > 25) or nearby > 5 or gold_nearby > 2 or stone_nearby > 2:
				var guarded = false
				for be in battle.entities.get_children():
					if be is Building and be.entity_id in [25,41] and be.team == my_team and be.health > 0:
						if be.global_position.distance_to(e.global_position) < 8: guarded = true; break
				if guarded: continue
				if can_afford_building(25) and count_building(25) < 6:
					var pos = e.global_position + Vector3(randf_range(-4,4), 0, randf_range(-4,4))
					if _is_valid_build_ground(pos):
						build_building(25, pos)
						if can_afford_building(41): build_building(41, pos + Vector3(randf_range(2,4), 0, randf_range(2,4)))
						return
	for e in battle.entities.get_children():
		if e is Building and e.entity_id == 23 and e.team == my_team and e.health > 0:
			var has_tower = false
			for be in battle.entities.get_children():
				if be is Building and be.entity_id == 25 and be.team == my_team and be.global_position.distance_to(e.global_position) < 8: has_tower = true; break
			if not has_tower and can_afford_building(25):
				var tpos = e.global_position + Vector3(randf_range(3,5), 0, randf_range(3,5))
				if _is_valid_build_ground(tpos): build_building(25, tpos); return

# ═══ Officials ═══
func _ai_garrison_officials():
	if count_building(42) == 0: return
	for entity in battle.entities.get_children():
		if not (entity is Army and entity.entity_id >= 46 and entity.entity_id <= 50 and entity.health > 0): continue
		if not entity_belongs_to_me(entity): continue
		var gb = entity.get("_garrison_building")
		if gb and gb.get_ref(): continue
		if entity.get("_garrison_target_id") != -1: continue
		var target: Building = null
		match entity.entity_id:
			46: target = _find_vacant_warehouse_s()
			47: target = _find_vacant_tower_s()
			48: target = _find_random_prod_or_def_s()
			50: target = _find_most_officiated_s()
		if target: entity._garrison_target_id = target.get_instance_id(); entity.move_to(target.global_position)

# ═══ Hunting ═══
func _ai_hunt_animals(delta):
	_hunt_timer -= delta
	if _hunt_timer > 0: return
	_hunt_timer = 120.0

	# Collect idle military units (not peasants, ships, merchants, officials)
	var idle_land = []   # land-capable
	var idle_water = []  # water-capable
	for e in battle.entities.get_children():
		if not (e is Army) or e.health <= 0: continue
		if not entity_belongs_to_me(e): continue
		# Exclude non-combat units
		if e.entity_id == 10 or e.entity_id == 14: continue  # peasants, gathering ships
		if e.entity_id >= 43: continue  # merchants, officials, food merchant
		if e.current_order != "" or e.current_target != null: continue  # only idle
		if e.water_capable: idle_water.append(e)
		else: idle_land.append(e)

	if idle_land.is_empty() and idle_water.is_empty(): return

	var castle = get_peer_castle(my_peer_id)
	if not castle: return

	# Find animals within 30 units
	var animals = []
	for e in battle.entities.get_children():
		if e is Army and e.health > 0:
			var at = e.get("_animal_type")
			if at != null and str(at) != "":
				var d = castle.global_position.distance_to(e.global_position)
				if d < 30.0:
					animals.append({"entity": e, "dist": d, "is_fish": (at == "fish")})
	if animals.is_empty(): return
	animals.sort_custom(func(a, b): return a.dist < b.dist)

	# Pick a target not already swarmed
	var hunt_target = null; var is_fish_target = false
	for ai in animals:
		var existing = 0
		for e in battle.entities.get_children():
			if e is Army and entity_belongs_to_me(e) and e.current_target == ai.entity: existing += 1
		if existing < 3: hunt_target = ai.entity; is_fish_target = ai.is_fish; break
	if not hunt_target: return

	# Select up to 5 hunters — water units for fish, land units for land animals
	var hunters = []
	var pool = idle_water if is_fish_target else idle_land
	# If pool is empty, fall back to the other pool
	if pool.is_empty(): pool = idle_land if is_fish_target else idle_water
	for u in pool:
		if hunters.size() >= 5: break
		hunters.append(u)
	if hunters.is_empty(): return

	for u in hunters:
		u.attack_target(hunt_target)
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

# ═══ Tactics ═══
func update_tactic(_delta):
	var now = Time.get_ticks_msec() / 1000.0
	var my_key = my_peer_id if my_peer_id != -1 else my_team
	var my_mil = count_military(my_key)
	var enemy_team = RTSConfig.Team.BLUE if my_team == RTSConfig.Team.RED else RTSConfig.Team.RED
	var player_mil = count_military_by_team(enemy_team)

	if current_tactic == LateTactic.DEFEND:
		if my_mil > player_mil * 2 and my_mil > 10:
			current_tactic = LateTactic.OVERWHELM; execute_overwhelm(); last_tactic_time = now; return
		if count_building(27) < 5: start_defense()
		else: check_defense_line(); upgrade_defense_to_max()
		return

	if player_mil > my_mil * 1.5:
		if current_tactic != LateTactic.DEFEND: start_defense()
		return

	if now - last_tactic_time < TACTIC_COOLDOWN and current_tactic != LateTactic.NONE: return

	if my_mil > player_mil * 2 and my_mil > 10:
		current_tactic = LateTactic.OVERWHELM; execute_overwhelm()
	else:
		if randf() < 0.5: current_tactic = LateTactic.HARASS; execute_harass()
		else: current_tactic = LateTactic.RAID; execute_raid()
	last_tactic_time = now

func execute_harass():
	var enemy_castle = get_team_castle(1 - my_team)
	if not enemy_castle: return
	for i in range(10 - count_unit(15)):
		if can_afford(15) and _can_train_unit(): produce_unit(15)
	for i in range(10 - count_unit(13)):
		if can_afford(13) and _can_train_unit(): produce_unit(13)
	var best_warehouse: Building = null; var best_dist = 0.0
	for entity in battle.entities.get_children():
		if entity is Building and entity.team == 1-my_team and entity.entity_id == 22 and entity.health > 0:
			var dist = entity.global_position.distance_to(enemy_castle.global_position)
			if dist > 15 and dist > best_dist: best_warehouse = entity; best_dist = dist
	if best_warehouse:
		for entity in battle.entities.get_children():
			if entity is Army and entity.team == my_team and entity.health > 0 and entity.entity_id == 15 and entity_belongs_to_me(entity):
				entity.attack_move_to(best_warehouse.global_position)
	var player_shipyard: Building = null
	for entity in battle.entities.get_children():
		if entity is Building and entity.team == 1-my_team and entity.entity_id == 23 and entity.health > 0: player_shipyard = entity; break
	if player_shipyard:
		for entity in battle.entities.get_children():
			if entity is Army and entity.team == my_team and entity.health > 0 and entity.entity_id == 13 and entity_belongs_to_me(entity):
				entity.attack_move_to(player_shipyard.global_position)

func execute_overwhelm():
	var enemy_castle = get_team_castle(1 - my_team)
	if not enemy_castle: return
	var rally = enemy_castle.global_position + Vector3(0, 0, 5)
	if wall_positions.size() > 0: rally = wall_positions[wall_positions.size()/2] + Vector3(0, 0, 2)
	var self_castle = get_peer_castle(my_peer_id)
	if not self_castle: return
	var home = self_castle.global_position
	for entity in battle.entities.get_children():
		if entity is Army and entity.team == my_team and entity.health > 0 and entity_belongs_to_me(entity):
			if entity.entity_id in [10,14,46,47,48,50]: continue
			if entity.global_position.distance_to(home) <= HOME_ASSEMBLE_RANGE:
				entity.attack_move_to(rally)
	await get_tree().create_timer(10.0).timeout
	for entity in battle.entities.get_children():
		if entity is Army and entity.team == my_team and entity.health > 0 and entity_belongs_to_me(entity):
			if entity.entity_id in [10,14,46,47,48,50]: continue
			entity.attack_move_to(enemy_castle.global_position)

func execute_raid():
	var self_castle = get_peer_castle(my_peer_id)
	if not self_castle or self_castle.level < 3: return
	var enemy_castle = get_team_castle(1 - my_team)
	if not enemy_castle or not is_instance_valid(enemy_castle): return
	var enemy_pos = enemy_castle.global_position
	var enemy_team = RTSConfig.Team.BLUE if my_team == RTSConfig.Team.RED else RTSConfig.Team.RED
	var special_uid = RAID_UNIT
	if NationData.NATION_UNITS.has(nation) and NationData.NATION_UNITS.get(nation).size() >= 2:
		special_uid = NationData.NATION_UNITS.get(nation)[1]["unit_id"]
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
		if e is Army and e.team == my_team and e.health > 0 and (e.entity_id == RAID_UNIT or e.entity_id == special_uid) and entity_belongs_to_me(e):
			raid_army.append(e)
	if raid_army.is_empty(): return
	var half = raid_army.size() / 2
	for i in range(half):
		if is_instance_valid(raid_army[i]): raid_army[i].move_to(waypoint)
	await get_tree().create_timer(1.8).timeout
	for i in range(half, raid_army.size()):
		if is_instance_valid(raid_army[i]): raid_army[i].move_to(waypoint)
	await get_tree().create_timer(RAID_WAIT_TIME)
	for u in raid_army:
		if is_instance_valid(u) and is_instance_valid(enemy_castle): u.attack_move_to(enemy_castle.global_position)

func _get_enemy_army_direction(center: Vector3) -> Vector3:
	var sum = Vector3.ZERO; var cnt = 0
	for e in battle.entities.get_children():
		if e is Army and e.team == 1-my_team and e.health > 0:
			var d = e.global_position - center
			if d.length() > 12: sum += d.normalized(); cnt += 1
	return Vector3.FORWARD if cnt == 0 else sum.normalized()

func _is_near_enemy_tower(pos: Vector3, range: float, enemy_team: int) -> bool:
	for e in battle.entities.get_children():
		if e is Building and e.team == enemy_team and e.health > 0 and e.entity_id in [21,24,25]:
			if pos.distance_to(e.global_position) < range: return true
	return false

# ═══ Defense ═══
func start_defense():
	current_tactic = LateTactic.DEFEND
	var self_castle = get_peer_castle(my_peer_id)
	if not self_castle: return
	var castle_pos = self_castle.global_position
	var defend_pos = castle_pos + Vector3(0, 0, -3)
	if wall_positions.size() > 0:
		var avg = Vector3.ZERO
		for p in wall_positions: avg += p
		avg /= wall_positions.size()
		defend_pos = avg - _get_enemy_army_direction(castle_pos).normalized() * 3.5
	for entity in battle.entities.get_children():
		if entity is Army and entity.team == my_team and entity.health > 0 and entity_belongs_to_me(entity):
			if entity.entity_id in [10,14,46,47,48,50]: continue
			if entity.global_position.distance_to(castle_pos) > SAFE_DEFEND_RADIUS:
				entity.attack_move_to(defend_pos)
	for i in range(6 - count_unit(12)):
		if can_afford(12) and _can_train_unit(): produce_unit(12)
	for i in range(4 - count_unit(16)):
		if can_afford(16) and _can_train_unit(): produce_unit(16)
	if not defense_line_built and count_building(20) > 0:
		build_defense_line(); defense_line_built = true
	check_defense_line(); upgrade_defense_to_max()

func build_defense_line():
	var castle = get_peer_castle(my_peer_id)
	if not castle: return
	var enemy_dir = _get_enemy_army_direction(castle.global_position)
	var front_center = castle.global_position + enemy_dir.normalized() * DEFENSE_FRONT_DIST
	wall_positions.clear(); tower_positions.clear()
	var right_dir = enemy_dir.cross(Vector3.UP).normalized()
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
	await get_tree().create_timer(0.3)

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

# ═══ Shipyard ═══
func _cache_shipyard_location(): cached_shipyard_pos = _find_best_water_adjacent_plain()

func _find_best_water_adjacent_plain() -> Vector3:
	var castle = get_peer_castle(my_peer_id)
	if not castle: return Vector3.ZERO
	var best_pos = Vector3.ZERO; var best_dist = 9999.0
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
				if wp.distance_to(op) < BOAT_VISION_RANGE: reach_oil = true; break
			if not reach_oil: continue
			var dis = wp.distance_to(castle.global_position)
			if dis < best_dist: best_dist = dis; best_pos = wp
	if best_pos != Vector3.ZERO: built_shipyard_pos.append(best_pos)
	return best_pos

func _check_near_water(gx: int, gz: int) -> bool:
	for dx in [-1,0,1]:
		for dz in [-1,0,1]:
			if dx == 0 and dz == 0: continue
			var nx = gx + dx; var nz = gz + dz
			if nx >= 0 and nx < RTSConfig.MAP_SIZE and nz >= 0 and nz < RTSConfig.MAP_SIZE:
				if battle.get_terrain_at_grid(nx, nz) == 2: return true
	return false

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
		var has_oil = false
		for res in battle.entities.get_children():
			if res is WorldResource and res.resource_type == "oil" and res.health > 0 and sy.global_position.distance_to(res.global_position) < 15.0: has_oil = true; break
		if not has_oil and shipyards.size() > 1:
			sy.queue_free()
			if can_afford_building(23):
				var pos = _find_shipyard_pos_near_oil()
				if pos != Vector3.ZERO: build_building(23, pos)

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
				if res is WorldResource and res.resource_type == "oil" and res.health > 0 and tp.distance_to(res.global_position) < 10.0: return tp
	return Vector3.ZERO

# ═══ Official helpers ═══
func _find_vacant_warehouse_s() -> Building:
	for e in battle.entities.get_children():
		if e is Building and e.entity_id == 22 and e.team == my_team and e.health > 0 and e.build_timer <= 0:
			var ok = true
			for oe in battle.entities.get_children():
				if oe is Army and oe.entity_id == 46 and oe.get("_garrison_building") and oe.get("_garrison_building").get_ref() == e: ok = false; break
			if ok: return e
	return null

func _find_vacant_tower_s() -> Building:
	for e in battle.entities.get_children():
		if e is Building and e.entity_id in [25,26] and e.team == my_team and e.health > 0:
			var ok = true
			for oe in battle.entities.get_children():
				if oe is Army and oe.entity_id == 47 and oe.get("_garrison_building") and oe.get("_garrison_building").get_ref() == e: ok = false; break
			if ok: return e
	return null

func _find_random_prod_or_def_s() -> Building:
	var cand = []
	for e in battle.entities.get_children():
		if e is Building and e.entity_id in [21,23,24,29,25,26] and e.team == my_team and e.health > 0 and e.build_timer <= 0:
			var ok = true
			for oe in battle.entities.get_children():
				if oe is Army and oe.entity_id == 48 and oe.get("_garrison_building") and oe.get("_garrison_building").get_ref() == e: ok = false; break
			if ok: cand.append(e)
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
func _process_line_1():
	_ai_expand_territory()
	for b_id in wanted_buildings:
		var target = MILITARY_PRODUCER_TARGETS.get(b_id, 1)
		if count_building(b_id) < target and can_afford_building(b_id):
			build_building(b_id, _get_build_position(b_id))
			return
	for b_id in wanted_buildings:
		if _should_build_or_upgrade(b_id) and can_afford_upgrade(b_id):
			upgrade_building(b_id)
			return

func _process_line_upgrade():
	for b_id in wanted_buildings:
		if _should_build_or_upgrade(b_id) and can_afford_upgrade(b_id):
			upgrade_building(b_id)
			return

func _try_produce_merchants_or_officials() -> bool:
	for mid in [51, 44, 45, 43]:
		if count_unit(mid) < 1 and can_afford(mid) and _can_train_unit():
			if produce_unit(mid): return true
	if count_building(42) > 0:
		var alv = _get_academy_lv()
		for i in range(alv):
			var oid = [46, 47, 48, 49, 50][i]
			if count_unit(oid) < 1 and can_afford(oid) and _can_train_unit():
				if produce_unit(oid): return true
	return false

func _process_line_military():
	var priority = get_counter_priority()
	for u_id in priority:
		if count_unit(u_id) < target_army_count and can_afford(u_id) and _can_train_unit():
			produce_unit(u_id); return

func _process_line_3():
	if count_building(28) < target_house_count and can_afford_building(28):
		var castle = get_peer_castle(my_peer_id)
		if castle: build_building(28, castle.global_position + Vector3(randf_range(-8,8), 0, randf_range(-8,8)))

func _process_line_4():
	var my_key = my_peer_id if my_peer_id != -1 else my_team
	if count_military(my_key) >= 15 and an_attack():
		var target = get_team_castle(1-my_team)
		if target: attack_move(target.global_position, 30)

func _process_line_5():
	var shipyards = []
	for e in battle.entities.get_children():
		if e is Building and e.entity_id == 23 and e.health > 0 and e.build_timer <= 0 and entity_belongs_to_me(e):
			shipyards.append(e)
	if shipyards.is_empty(): return
	for sy in shipyards:
		var warships = 0; var gunboats = 0
		for e in battle.entities.get_children():
			if e is Army and e.health > 0 and entity_belongs_to_me(e) and e.global_position.distance_to(sy.global_position) < 15.0:
				if e.entity_id == 13: warships += 1
				elif e.entity_id == 39: gunboats += 1
		while warships < 2 and can_afford(13) and _can_train_unit(): produce_unit(13); warships += 1
		while gunboats < 2 and can_afford(39) and _can_train_unit(): produce_unit(39); gunboats += 1

# ═══ Merchants (castle Lv3+) ═══
func _get_academy_lv() -> int:
	for entity in battle.entities.get_children():
		if entity is Building and entity.entity_id == 42 and entity.team == my_team and entity.health > 0:
			return entity.upgrade_level
	return 0

func _ensure_merchants():
	for entity in battle.entities.get_children():
		if not (entity is Building and entity.entity_id == 20): continue
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



# ═══ Debug panel ═══
func update_debug_label():
	if not debug_panel: return
	var res = _get_resources(); var pop = _get_population()
	_header_rtl.text = "[color=#%s]%s[/color]  |  %s" % [(Color.GREEN if phase == Phase.ASSAULT else (Color(1,0.7,0) if phase == Phase.DEVELOPMENT else Color.CYAN)).to_html(), Phase.keys()[phase], _get_tactic_name(current_tactic)]
	var pop_pct = float(pop.current) / max(pop.max, 1)
	_pop_bar.value = pop_pct * 100
	var pfs = _pop_bar.get_theme_stylebox("fill")
	if pfs: pfs.bg_color = Color.GREEN if pop_pct < 0.8 else Color(1,0.5,0)
	_pop_label.text = "人口 %d/%d" % [pop.current, pop.max]
	var res_list = [
		{"k":"gold","n":"金","c":Color(1.0,0.84,0.1)}, {"k":"wood","n":"木","c":Color(0.25,0.82,0.2)},
		{"k":"stone","n":"石","c":Color(0.62,0.62,0.62)}, {"k":"food","n":"食","c":Color(1.0,0.55,0.1)},
		{"k":"oil","n":"油","c":Color(0.4,0.25,0.1)},
	]
	var limits = _get_limits()
	for i in range(5):
		var r = res_list[i]; var val = res.get(r.k, 0); var lim = limits.get(r.k, 500)
		_res_bars[i].value = min(float(val)/max(lim,1)*100, 100)
		_res_labels[i].text = "%s %d" % [r.n, val]
		var gc = 0
		for entity in battle.entities.get_children():
			if entity is Army and entity.health > 0 and entity.entity_id in [10,14] and entity.current_order in ["gather","deliver"]:
				var tgt = entity.current_target
				if is_instance_valid(tgt) and tgt is WorldResource and tgt.resource_type == r.k and entity_belongs_to_me(entity):
					gc += 1
		_res_labels[i].text += " %d人" % gc
		_res_labels[i].text += " %+.1f/s" % _ai_income_rate[r.k]
		var s = _res_bars[i].get_theme_stylebox("fill")
		if s: s.bg_color = r.c
	var all_units = [[10,"农"],[11,"步"],[12,"弓"],[13,"战船"],[14,"采船"],[15,"骑"],[16,"炮"],[17,"投石"],[18,"攻城"],[19,"侦察"],
		[30,"狂战"],[31,"长弓"],[32,"法骑"],[33,"连弩"],[34,"象骑"],[35,"长枪"],[36,"重步"],[37,"重弓"],[38,"重骑"],[39,"炮艇"],[40,"快艇"],
		[43,"油商"],[44,"木商"],[45,"石商"],[51,"食商"],[46,"县吏"],[47,"上校"],[48,"尚书"],[49,"统帅"],[50,"丞相"]]
	var mil_lines = []
	for u in all_units:
		var cnt = count_unit(u[0])
		if cnt > 0: mil_lines.append("[color=#aaa]%s[/color]:[color=white]%d[/color]" % [u[1], cnt])
	_mil_rtl.text = "[color=gray](无军队)[/color]" if mil_lines.is_empty() else " ".join(mil_lines)
	var all_blds = [[20,"城"],[21,"营"],[22,"仓"],[23,"坞"],[24,"攻城车"],[25,"箭塔"],[26,"炮塔"],[27,"墙"],[28,"民"],[29,"重工"],[41,"瞭望"],[42,"书院"],[52,"集市"],[53,"城堡"]]
	var bld_lines = []
	for b in all_blds:
		var cnt = 0; var max_lv = 1
		for entity in battle.entities.get_children():
			if entity is Building and entity.entity_id == b[0] and entity_belongs_to_me(entity) and entity.health > 0:
				cnt += 1
				if entity.upgrade_level > max_lv: max_lv = entity.upgrade_level
		if cnt > 0: bld_lines.append("[color=#888]【%d】%s[/color]:[color=white]%d[/color]" % [max_lv, b[1], cnt])
	_bld_rtl.text = "[color=gray](无建筑)[/color]" if bld_lines.is_empty() else " ".join(bld_lines)
	var hunt_info = "[color=#ffa]狩猎: %.0fs[/color]" % max(0, _hunt_timer)
	if _hunt_target and is_instance_valid(_hunt_target):
		var hc = 0
		for e in battle.entities.get_children():
			if e is Army and entity_belongs_to_me(e) and e.current_target == _hunt_target: hc += 1
		hunt_info += " [color=#f88]目标:%s 猎人:%d/5[/color]" % [_hunt_target.get("_animal_type"), hc]
	else: hunt_info += " [color=gray](待命)[/color]"
	_bld_rtl.text = hunt_info + "\n" + _bld_rtl.text

var debug_panel: Control = null
var _header_rtl: RichTextLabel
var _pop_bar: ProgressBar; var _pop_label: Label
var _res_bars: Array = []; var _res_labels: Array = []
var _mil_rtl: RichTextLabel; var _bld_rtl: RichTextLabel

func _create_debug_panel():
	debug_panel = Control.new(); debug_panel.name = "AIDebugPanel"; debug_panel.z_index = 100
	debug_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var offset_y = 10
	if battle is OnlineBattleManager:
		var info = battle.player_info.get(my_peer_id)
		if info: offset_y = 10 + (info.team * 2 + info.slot) * 340
	debug_panel.position = Vector2(400, offset_y)
	debug_panel.custom_minimum_size = Vector2(540, 380); debug_panel.size = Vector2(540, 380)
	var bg = Panel.new(); bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg_style = StyleBoxFlat.new(); bg_style.bg_color = Color(0.05, 0.06, 0.12, 0.92)
	bg_style.corner_radius_top_left = 8; bg_style.corner_radius_top_right = 8
	bg_style.corner_radius_bottom_left = 8; bg_style.corner_radius_bottom_right = 8
	bg_style.border_width_left = 2; bg_style.border_width_right = 2
	bg_style.border_width_top = 2; bg_style.border_width_bottom = 2
	bg_style.border_color = Color(0.25, 0.5, 0.8, 0.5)
	bg.add_theme_stylebox_override("panel", bg_style); debug_panel.add_child(bg)
	var vb = VBoxContainer.new(); vb.position = Vector2(10, 8); vb.add_theme_constant_override("separation", 3)
	debug_panel.add_child(vb)
	var title_text = "[color=#4af]◈ AI 决策中心[/color]"
	if battle is OnlineBattleManager: title_text = "[color=#4af]◈ AI-%d 决策中心[/color]" % my_peer_id
	var title = _make_rtl(); title.text = title_text; title.add_theme_font_size_override("font_size", 22); vb.add_child(title)
	_header_rtl = _make_rtl(); _header_rtl.add_theme_font_size_override("font_size", 19); vb.add_child(_header_rtl)
	var pop_hbox = HBoxContainer.new()
	_pop_label = Label.new(); _pop_label.add_theme_font_size_override("font_size", 16); _pop_label.add_theme_color_override("font_color", Color.WHITE)
	pop_hbox.add_child(_pop_label)
	_pop_bar = _make_bar(Color.GREEN); _pop_bar.custom_minimum_size = Vector2(370, 10); pop_hbox.add_child(_pop_bar)
	vb.add_child(pop_hbox)
	vb.add_child(_make_section("资源"))
	var res_grid = GridContainer.new(); res_grid.columns = 5
	var res_cfg = [["金",Color(1.0,0.84,0.1)],["木",Color(0.25,0.82,0.2)],["石",Color(0.62,0.62,0.62)],["食",Color(1.0,0.55,0.1)],["油",Color(0.4,0.25,0.1)]]
	for i in range(5):
		var col = VBoxContainer.new()
		var bl = Label.new(); bl.text = res_cfg[i][0]; bl.add_theme_font_size_override("font_size", 13); bl.add_theme_color_override("font_color", res_cfg[i][1])
		bl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; col.add_child(bl)
		var br = _make_bar(res_cfg[i][1]); br.custom_minimum_size = Vector2(85, 8); _res_bars.append(br); col.add_child(br)
		var ll = Label.new(); ll.add_theme_font_size_override("font_size", 11); ll.add_theme_color_override("font_color", Color.WHITE)
		ll.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; ll.clip_text = true; ll.custom_minimum_size = Vector2(85, 0)
		_res_labels.append(ll); col.add_child(ll); res_grid.add_child(col)
	vb.add_child(res_grid)
	vb.add_child(_make_section("军队")); _mil_rtl = _make_rtl(); vb.add_child(_mil_rtl)
	vb.add_child(_make_section("建筑")); _bld_rtl = _make_rtl(); vb.add_child(_bld_rtl)
	var hud = battle.get_node("UI") as CanvasLayer; hud.add_child(debug_panel)

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
	r.text = "[color=#5af]▸ %s[/color]" % title; r.add_theme_font_size_override("font_size", 16); return r

func _get_tactic_name(tactic: int) -> String:
	match tactic:
		LateTactic.NONE: return "无"
		LateTactic.HARASS: return "骚扰"
		LateTactic.OVERWHELM: return "压制"
		LateTactic.RAID: return "突袭"
		LateTactic.DEFEND: return "防守"
		_: return "未知"

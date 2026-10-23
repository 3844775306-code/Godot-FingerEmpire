# scripts/ai/AI.gd
# Merged AI Controller — single-player + online dual-mode
extends Node

class_name AIController

enum Phase { PRODUCTION, DEVELOPMENT, ASSAULT }
enum LateTactic { NONE, HARASS, OVERWHELM, RAID, DEFEND }

@onready var battle = get_parent()

var phase: int = Phase.PRODUCTION
var timer: float = 0.0
var think_interval: float = 2.0  # overridden by difficulty in _ready
var worker_allocate_timer: float = 0.0
const WORKER_ALLOCATE_INTERVAL: float = 3.0
var last_attack_time: float = -999.0
const ATTACK_COOLDOWN: float = 120.0
var production_step: int = 0

var wanted_buildings: Array = [20, 21, 23, 25, 42, 54, 26, 24, 29, 41, 52, 53]
var wanted_units: Array = [11,12,15,16,17,18,35,36,37,38,39,40,13,43,44,45,46,47,48,49,50,58,59,5,6,9]
var target_army_count: int = 7
var target_house_count: int = 8
var desired_worker_count: int = 8

var cached_shipyard_pos: Vector3 = Vector3.ZERO
var defense_line_built: bool = false
var defense_check_timer: float = 0.0
var defense_initialized: bool = false   # 防线位置已规划（进入分批建造阶段）
var _defense_queue: Array = []          # 待建防线队列：[{"id": 建筑id, "pos": 位置}]
const DEFENSE_CHECK_INTERVAL: float = 120.0
const DEFENSE_STEP_MAX: int = 3         # 每个 think tick 至多尝试建造的防线建筑数
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
const LAND_RALLY_DISTANCE: float = 12.0
const LAND_RALLY_INTERVAL: float = 8.0
var _land_rally_timer: float = 0.0
const NAVAL_PATROL_INTERVAL: float = 15.0
var _naval_patrol_timer: float = 0.0

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
	return battle.can_train_unit(RTSConfig.Team.RED)

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
func count_unit(id: int, include_queue: bool = true) -> int:
	var cnt = 0
	# Count existing units
	for entity in battle.entities.get_children():
		if entity is Army and entity.health > 0 and entity.entity_id == id:
			if my_peer_id != -1 and entity.owner_peer_id != my_peer_id: continue
			if my_peer_id == -1 and entity.team != my_team: continue
			cnt += 1
	# Count units in production queues（决策用；面板统计传 false，避免把队列当成已存在单位）
	if include_queue:
		for entity in battle.entities.get_children():
			if entity is Building and entity.health > 0:
				if my_peer_id != -1 and entity.owner_peer_id != my_peer_id: continue
				if my_peer_id == -1 and entity.team != my_team: continue
				for pid in entity.production_queue:
					if pid == id: cnt += 1
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
		if not is_instance_valid(entity) or entity is GameEntity and entity.health <= 0: continue
		if entity is Army:
			if my_peer_id != -1 and entity.owner_peer_id != peer: continue
			if my_peer_id == -1 and entity.team != peer: continue
			if entity.entity_id != 10 and entity.entity_id != 14 and entity.entity_id not in [43,44,45,46,47,48,49,50,51]:
				total += 1
	# Count queued military units in production
	for entity in battle.entities.get_children():
		if entity is Building and entity.health > 0:
			if my_peer_id != -1 and entity.owner_peer_id != peer: continue
			if my_peer_id == -1 and entity.team != peer: continue
			for pid in entity.production_queue:
				if pid != 10 and pid != 14 and pid not in [43,44,45,46,47,48,49,50,51]:
					total += 1
	return total

func count_military_by_team(tm: int) -> int:
	var total = 0
	for entity in battle.entities.get_children():
		if entity is Army and entity.health > 0:
			if entity.team != tm: continue
			if entity.entity_id != 10 and entity.entity_id != 14 and entity.entity_id not in [43,44,45,46,47,48,49,50,51]:
				total += 1
	# Count queued military units in production
	for entity in battle.entities.get_children():
		if entity is Building and entity.health > 0:
			if entity.team != tm: continue
			for pid in entity.production_queue:
				if pid != 10 and pid != 14 and pid not in [43,44,45,46,47,48,49,50,51]:
					total += 1
	return total
# Check if any AI unit can see this entity
func _is_visible_to_ai(target: GameEntity) -> bool:
	for e in battle.entities.get_children():
		if e is GameEntity and e.health > 0:
			if my_peer_id != -1 and e.owner_peer_id != my_peer_id: continue
			if my_peer_id == -1 and e.team != my_team: continue
			if e.global_position.distance_to(target.global_position) <= e.vision_range:
				return true
	return false

# Refresh visible enemies cache (called once per think cycle)
func _refresh_visibility():
	_visible_enemies.clear()
	for e in battle.entities.get_children():
		if not (e is GameEntity): continue
		if e.health <= 0: continue
		if entity_belongs_to_me(e): continue
		if e is WorldResource: continue
		if _is_visible_to_ai(e):
			_visible_enemies.append(e)

# Check if an entity is in the visible enemies cache
func _is_visible_enemy(entity: GameEntity) -> bool:
	return entity in _visible_enemies

# ═══ Economy ═══
func _ai_can_build(building_id: int) -> bool:
	var cl = 0
	var castle = get_peer_castle(my_peer_id)
	if castle: cl = castle.upgrade_level
	match building_id:
		23, 25, 26:  # 船坞、箭塔、炮塔 → 城堡2级
			return cl >= 2
		24, 29, 52:   # 攻城车间、重装武器厂、集市 → 城堡3级
			return cl >= 3
		53:   # 城堡→4级
			return cl >= 4
		42:   # 书院→3级
			return cl >= 3
	return true

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
			if produced >= 1: break
			if entity is Building and entity.health > 0 and entity.build_timer <= 0:
				if not entity_belongs_to_me(entity): continue
				if entity.try_produce(unit_id):
					produced += 1
		return produced > 0

func build_building(building_id: int, pos: Vector3) -> bool:
	var cfg = EntityDatabase.get_config(building_id)
	if not cfg: return false
	# Check castle level requirement (matches RTSBattleManager.is_building_unlocked)
	if not _ai_can_build(building_id): return false
	# 城墙允许建 WALL_COUNT 面（防线需求），其余建筑上限 10
	var _cap = WALL_COUNT if building_id == 27 else 10
	if count_building(building_id) >= _cap: return false
	# Non-shipyard buildings: must be within AI vision range
	if building_id != 23:
		var world_pos = Vector3(pos.x, 0, pos.z)
		var visible = false
		for e in battle.entities.get_children():
			if e is GameEntity and e.health > 0 and entity_belongs_to_me(e):
				if e.global_position.distance_to(world_pos) <= e.vision_range:
					visible = true
					break
		if not visible:
			return false  # cannot build outside vision
	var cost = cfg.get("cost", {})
	if not _deduct_resources(cost): return false
	cfg["owner_peer_id"] = my_peer_id
	# 队伍判定：在线走 player_info；本地乱斗/多人各 AI 有唯一 team(my_team)，
	# 若始终用 RED 会让 AI 建筑建错阵营，被自己和盟友攻击。
	var team = RTSConfig.Team.RED
	if my_peer_id != -1:
		if battle is OnlineBattleManager:
			team = battle.player_info[my_peer_id].team
		else:
			team = my_team
	var b = battle.spawn_entity(cfg, team, pos)
	if b:
		b.start_construction(5.0, cfg)
	return b != null

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
	for entity in battle.entities.get_children():
		if entity is Building and entity.health > 0 and entity.build_timer <= 0:
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
	_add_nation_special_unit()
	_create_debug_panel()

func _process(delta):
	# Set think interval based on difficulty (once)
	if think_interval == 2.0:
		var diff = GameSettings.ai_difficulty
		if battle is OnlineBattleManager and my_peer_id != -1:
			diff = GameSettings.red_ai_difficulty if my_team == RTSConfig.Team.RED else GameSettings.blue_ai_difficulty
		if diff == GameSettings.AIDifficulty.EASY: think_interval = 2.0
		elif diff == GameSettings.AIDifficulty.NORMAL: think_interval = 1.75
		elif diff == GameSettings.AIDifficulty.HARD: think_interval = 1.5
		elif diff == GameSettings.AIDifficulty.HELL: think_interval = 1.0
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
	_naval_patrol_timer -= delta
	if _naval_patrol_timer <= 0:
		_naval_patrol_timer = NAVAL_PATROL_INTERVAL
		if phase >= Phase.DEVELOPMENT:
			_patrol_navy_around_water()
	# Troop accumulation: assault when army >= 30
	var army_count = count_military(my_peer_id if my_peer_id != -1 else my_team)
	if army_count >= 30 and phase == Phase.DEVELOPMENT:
		phase = Phase.ASSAULT

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
		if count_building(23) < 1 and _ai_can_build(23) and can_afford_building(23):
			_cache_shipyard_location()
			if cached_shipyard_pos != Vector3.ZERO:
				if build_building(23, cached_shipyard_pos):
					built_shipyard_pos.append(cached_shipyard_pos)
		elif count_unit(14) < 3 and count_building(23) > 0 and can_afford(14) and _can_train_unit():
			produce_unit(14)
		elif warehouses < WAREHOUSE_MAX_COUNT and can_afford_building(22):
			var castle = get_peer_castle(my_peer_id)
			if castle:
				var near_count = 0
				for e in battle.entities.get_children():
					if e is Building and e.entity_id == 22 and e.team == my_team and e.health > 0:
						if e.global_position.distance_to(castle.global_position) < 25.0: near_count += 1
				# More warehouses nearby = lower priority, but still build if < 5 total
				if near_count < 3:
					build_building(22, castle.global_position + Vector3(randf_range(-10,10), 0, randf_range(-10,10)))
		else:
			if count_building(23) >= 1:
				phase = Phase.DEVELOPMENT
			_process_line_military()

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
	
	if not _priority_upgrade():
		_process_line_upgrade()
	
	_process_line_military()
	_process_line_1()
	_process_line_3()
	_ensure_merchants()
	var _did_merchant = _try_produce_merchants_or_officials()
	_try_produce_monks()
	if not _did_merchant:
		if not _priority_upgrade():
			_process_line_upgrade()
	_manage_shipyards()
	_process_line_5()
	_rally_land_army_to_castle()
	_ai_hunt_animals(_delta)
	_check_hunt_cleanup()
	_ai_garrison_officials()
	_manage_defense(_delta)
	update_tactic(_delta)

# -- ASSAULT: execute tactical attacks --
func _state_assault(_delta):
	_process_line_military()
	_process_line_1()
	_process_line_3()
	_process_line_4()
	_ensure_merchants()
	_rally_land_army_to_castle()
	_try_produce_merchants_or_officials()
	_try_produce_monks()
	_manage_shipyards()
	_process_line_5()
	_ai_hunt_animals(_delta)
	_check_hunt_cleanup()
	_ai_garrison_officials()
	_manage_defense(_delta)
	update_tactic(_delta)
# ═══ State Machine Dispatcher ═══
func decide(_delta):
	var _pt = Time.get_ticks_usec()
	_last_delta = _delta
	if not battle: return
	if my_peer_id != -1 and battle.has_method("update_player_limits"):
		battle.update_player_limits(my_peer_id)
		battle.update_player_population(my_peer_id)
	else:
		battle.update_resource_limits(RTSConfig.Team.RED)
		battle.update_population_limits()
	clear_invalid_targets()
	_refresh_visibility()
	_refresh_primary_enemy()
	_diplo_decide()
	if Engine.get_process_frames() % 60 == 0:
		var _w = count_unit(10)
	# State dispatch
	match phase:
		Phase.PRODUCTION: _state_production(_delta)
		Phase.DEVELOPMENT: _state_development(_delta)
		Phase.ASSAULT: _state_assault(_delta)
	if OS.is_debug_build():
		update_debug_label()
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

# 该实体是否对我构成敌对（owner 感知）。无外交管理器时退化为纯队伍判定，资源恒非敌。
func _entity_is_enemy(e) -> bool:
	if not (e is GameEntity) or e.health <= 0: return false
	if battle and battle.diplomacy and battle.diplomacy.active and my_peer_id != -1:
		var eo: int = -1
		if "owner_peer_id" in e: eo = e.owner_peer_id
		return eo >= 0 and eo != my_peer_id and battle.diplomacy.is_hostile(my_peer_id, eo)
	return e.team != my_team and not (e is WorldResource)

func _enemy_total_military() -> int:
	if my_peer_id != -1 and battle and battle.diplomacy and battle.diplomacy.active:
		var total = 0
		for o in battle.diplomacy.get_alive_owners():
			if o == my_peer_id: continue
			if not battle.diplomacy.is_hostile(my_peer_id, o): continue
			total += count_military(o)
		return total
	return count_military_by_team(_primary_enemy_team())

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
	var order := ["gold", "wood", "stone", "food", "oil"]
	var best := ""
	var best_v := 500
	for k in order:
		var v: int = res.get(k, 0)
		if v >= best_v: best_v = v; best = k
	if best == "": return
	if battle.diplomacy.deliver_tribute(my_peer_id, ally, best):
		_diplo_last_tribute_time = battle.game_time

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
	# Fallback: guaranteed offset from castle with terrain check
	for _fb in range(10):
		var fp = near_pos + Vector3(cos(randf_range(0, TAU))*20, 0, sin(randf_range(0, TAU))*20)
		if _is_valid_build_ground(fp): return fp
	return near_pos + Vector3(20, 0, 0)
	
	

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
		

	allocate_timers += 1
	if allocate_timers > 10:
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
	for entity in battle.entities.get_children():
		if entity is WorldResource and entity.health > 0:
			var type = entity.resource_type
			if type in priority_score:
				var score = priority_score[type] - worker.global_position.distance_to(entity.global_position) * 0.01
				for e in battle.entities.get_children():
					if e is Army and e.entity_id not in [10,14,43,44,45] and _entity_is_enemy(e):
						if e.global_position.distance_to(entity.global_position) < 10.0: score -= 500; break
				if score > best_score: best_score = score; best = entity
	return best

func attack_move(target_position: Vector3, max_units: int):
	var sent = 0
	for entity in battle.entities.get_children():
		if sent >= max_units: break
		if entity is Army and entity.health > 0 and entity.entity_id not in [10,14,45,46,47,48,50] and entity_belongs_to_me(entity):
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
	# Only build if score is acceptable (>= 2.0)
	if best_pos != Vector3.ZERO and best_score >= 2.0 and can_afford_building(22): build_building(22, best_pos)

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
	for e in battle.entities.get_children():
		if _entity_is_enemy(e):
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

	# Select up to 5 hunters — strict water/land separation, no cross-terrain
	var hunters = []
	var pool = idle_water if is_fish_target else idle_land
	if pool.is_empty(): return  # no suitable units for this terrain
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
		# 猎杀完成后快速寻找新目标（若猎人不足3）
		if active_hunters >= 3:
			_hunt_timer = 5.0

# ═══ Tactics ═══
func update_tactic(_delta):
	var now = Time.get_ticks_msec() / 1000.0
	var my_key = my_peer_id if my_peer_id != -1 else my_team
	var my_mil = count_military(my_key)
	var player_mil = _enemy_total_military()

	if current_tactic == LateTactic.DEFEND:
		if my_mil > player_mil  and my_mil > 10:
			current_tactic = LateTactic.OVERWHELM; execute_overwhelm(); last_tactic_time = now; return
		# assault mode: focus on attack, no defense spam
		return

	if player_mil > my_mil * 1.5:
		# skip defense — replaced by troop accumulation
		return

	if now - last_tactic_time < TACTIC_COOLDOWN and current_tactic != LateTactic.NONE: return

	if my_mil > player_mil * 1 and my_mil > 10:
		current_tactic = LateTactic.OVERWHELM; execute_overwhelm()
	else:
		if randf() < 0.5: current_tactic = LateTactic.HARASS; execute_harass()
		else: current_tactic = LateTactic.RAID; execute_raid()
	last_tactic_time = now

func execute_harass():
	var enemy_team = _primary_enemy_team()
	var enemy_castle = get_team_castle(enemy_team)
	if not enemy_castle: return
	#for i in range(10 - count_unit(15)):
		#if can_afford(15) and _can_train_unit(): produce_unit(15)
	#for i in range(10 - count_unit(13)):
		#if can_afford(13) and _can_train_unit(): produce_unit(13)
	var best_warehouse: Building = null; var best_dist = 0.0
	for entity in battle.entities.get_children():
		if entity is Building and entity.team == enemy_team and entity.entity_id == 22 and entity.health > 0:
			var dist = entity.global_position.distance_to(enemy_castle.global_position)
			if dist > 15 and dist > best_dist: best_warehouse = entity; best_dist = dist
	if best_warehouse:
		for entity in battle.entities.get_children():
			if entity is Army and entity.team == my_team and entity.health > 0 and entity.entity_id not in [10,14,46,47,48,50] and entity_belongs_to_me(entity):
				entity.attack_move_to(best_warehouse.global_position)
	var player_shipyard: Building = null
	for entity in battle.entities.get_children():
		if entity is Building and entity.team == enemy_team and entity.entity_id == 23 and entity.health > 0: player_shipyard = entity; break
	if player_shipyard:
		for entity in battle.entities.get_children():
			if entity is Army and entity.team == my_team and entity.health > 0 and entity.entity_id not in [10,14,46,47,48,50] and entity_belongs_to_me(entity):
				entity.attack_move_to(player_shipyard.global_position)

func execute_overwhelm():
	var enemy_castle = get_team_castle(_primary_enemy_team())
	if not enemy_castle: return
	var rally = enemy_castle.global_position + Vector3(0, 0, 5)
	#if wall_positions.size() > 0: rally = wall_positions[wall_positions.size()/2] + Vector3(0, 0, 2)
	var self_castle = get_peer_castle(my_peer_id)
	if not self_castle: return
	# 第一波：召集全军到敌方集结点（取消距离限制，确保全军参与）
	for entity in battle.entities.get_children():
		if entity is Army and entity.team == my_team and entity.health > 0 and entity_belongs_to_me(entity):
			if entity.entity_id in [10,14,46,47,48,50]: continue
			entity.attack_move_to(rally)
	# 等待部队集结
	await get_tree().create_timer(10.0).timeout
	# 第二波：全军压上敌方城堡
	for entity in battle.entities.get_children():
		if entity is Army and entity.team == my_team and entity.health > 0 and entity_belongs_to_me(entity):
			if entity.entity_id in [10,14,46,47,48,50]: continue
			if not enemy_castle or not is_instance_valid(enemy_castle): continue
			entity.attack_move_to(enemy_castle.global_position)

func execute_raid():
	var self_castle = get_peer_castle(my_peer_id)
	if not self_castle or self_castle.level < 3: return
	var enemy_team = _primary_enemy_team()
	var enemy_castle = get_team_castle(enemy_team)
	if not enemy_castle or not is_instance_valid(enemy_castle): return
	var enemy_pos = enemy_castle.global_position
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
		if e is Army and e.team == my_team and e.health > 0 and (e.entity_id not in [10,14,46,47,48,50]) and entity_belongs_to_me(e):
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
	var tower_front = front_center - enemy_dir * 1.8
	for i in range(4):
		var offset = (i - 1.5) * TOWER_SPACING
		var tp = tower_front + right_dir * offset
		if _is_valid_build_ground(tp):
			tower_positions.append(tp); _defense_queue.append({"id": 26, "pos": tp})
		var apos = tower_front + right_dir * (offset + 0.3)
		if _is_valid_build_ground(apos):
			tower_positions.append(apos); _defense_queue.append({"id": 25, "pos": apos})
	for i in range(WALL_COUNT):
		var bp = front_center + right_dir * ((i - WALL_COUNT / 2.0) * WALL_SPACING)
		if _is_valid_build_ground(bp):
			wall_positions.append(bp); _defense_queue.append({"id": 27, "pos": bp})
	return not _defense_queue.is_empty()

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
	
	for b_id in wanted_buildings:
		if _should_build_or_upgrade(b_id) and can_afford_upgrade(b_id):
			upgrade_building(b_id)
			
	for b_id in wanted_buildings:
		var target = MILITARY_PRODUCER_TARGETS.get(b_id, 1)
		if count_building(b_id) < target and can_afford_building(b_id):
			build_building(b_id, _get_build_position(b_id))
			
	_ai_expand_territory()


# 优先升级：兵营(21)升到4级，受城堡等级限制则先升城堡
func _priority_upgrade():
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
	for b_id in wanted_buildings:
		if _should_build_or_upgrade(b_id) and can_afford_upgrade(b_id):
			upgrade_building(b_id)
			

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

# 修道院生产僧侣/长老/宗师
func _try_produce_monks():
	if count_building(54) == 0: return
	var monk_order = [55, 56, 57]  # 僧侣→长老→宗师
	for mid in monk_order:
		if count_unit(mid) < 2 and can_afford(mid) and _can_train_unit():
			produce_unit(mid); return

func _process_line_military():
	var priority = get_counter_priority()
	
	for u_id in priority:
		if count_unit(u_id) < target_army_count and can_afford(u_id) and _can_train_unit():
			
			produce_unit(u_id); 

func _process_line_3():
	if count_building(28) < target_house_count and can_afford_building(28):
		var castle = get_peer_castle(my_peer_id)
		if castle:
			var hp2 = find_valid_build_position(castle.global_position, 28)
			if hp2 != Vector3.ZERO: build_building(28, hp2)

func _process_line_4():
	var my_key = my_peer_id if my_peer_id != -1 else my_team
	if count_military(my_key) >= 15 and an_attack():
		var target = get_team_castle(_primary_enemy_team())
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
		if entity.entity_id in [10, 14, 43, 44, 45, 46, 47, 48, 49, 50, 51]: continue
		if entity.water_capable: continue
		# 已集合过的单位不再重复集合
		if entity.has_meta("ai_rallied"): continue
		# Only rally idle units (刚生产出来的单位处于空闲状态)
		if entity.current_order != "" or entity.current_target != null: continue
		entity.set_meta("ai_rallied", true)
		entity.attack_move_to(rally_point)

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
		if entity.current_order != "" or entity.current_target != null: continue
		idle_naval.append(entity)
	if idle_naval.is_empty(): return
	for unit in idle_naval:
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
	# 收起状态：主体不可见，跳过整块内容刷新，省掉每帧的统计与遍历开销
	if _panel_collapsed: return
	var res = _get_resources(); var pop = _get_population()
	var _pe = {"PRODUCTION": "🌱", "DEVELOPMENT": "🏗️", "ASSAULT": "⚔️"}
	_header_rtl.text = "%s [color=#%s]%s[/color]  |  %s" % [_pe.get(Phase.keys()[phase], "▶️"), (Color.GREEN if phase == Phase.ASSAULT else (Color(1,0.7,0) if phase == Phase.DEVELOPMENT else Color.CYAN)).to_html(), Phase.keys()[phase], _get_tactic_name(current_tactic)]
	var pop_pct = float(pop.current) / max(pop.max, 1)
	_pop_bar.value = pop_pct * 100
	var pfs = _pop_bar.get_theme_stylebox("fill")
	if pfs: pfs.bg_color = Color.GREEN if pop_pct < 0.8 else Color(1,0.5,0)
	_pop_label.text = "👥 人口 %d/%d" % [pop.current, pop.max]
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
		[30,"狂战"],[31,"长弓"],[32,"法骑"],[33,"诸弩"],[34,"象骑"],[35,"长枪"],[36,"重步"],[37,"重弓"],[38,"重骑"],[39,"炮艇"],[40,"爆破"],
		[43,"油商"],[44,"木商"],[45,"石商"],[51,"食商"],[46,"县吏"],[47,"上校"],[48,"尚书"],[49,"统帅"],[50,"丞相"],
		[58,"连弩"],[59,"巨投"],[5,"推车"],[6,"贸车"],[9,"运载"],[55,"僧侣"],[56,"长老"],[57,"宗师"],[65,"武士"],[66,"甲骑"]]
	var mil_lines = []
	for u in all_units:
		var cnt = count_unit(u[0], false)
		if cnt > 0: mil_lines.append("[color=#aaa]%s[/color]:[color=white]%d[/color]" % [u[1], cnt])
	_mil_rtl.text = "[color=gray](无军队)[/color]" if mil_lines.is_empty() else " ".join(mil_lines)
	var all_blds = [[20,"城"],[21,"营"],[22,"仓"],[23,"坞"],[24,"攻城车"],[25,"箭塔"],[26,"炮塔"],[27,"墙"],[28,"民"],[29,"重工"],[41,"瞭望"],[42,"书院"],[52,"集市"],[53,"城堡"],[64,"炮台"],[7,"桥"],[8,"梯子"],[54,"修道"]]
	var bld_lines = []
	for b in all_blds:
		var cnt = 0; var max_lv = 1
		for entity in battle.entities.get_children():
			if entity is Building and entity.entity_id == b[0] and entity_belongs_to_me(entity) and entity.health > 0 and entity.build_timer <= 0:
				cnt += 1
				if entity.upgrade_level > max_lv: max_lv = entity.upgrade_level
		if cnt > 0: bld_lines.append("[color=#888]【%d】%s[/color]:[color=white]%d[/color]" % [max_lv, b[1], cnt])
	_bld_rtl.text = "[color=gray](无建筑)[/color]" if bld_lines.is_empty() else " ".join(bld_lines)
	var hunt_info = "[color=#ffa]🏹 狩猎: %.0fs[/color]" % max(0, _hunt_timer)
	if _hunt_target and is_instance_valid(_hunt_target):
		var hc = 0
		for e in battle.entities.get_children():
			if e is Army and entity_belongs_to_me(e) and e.current_target == _hunt_target: hc += 1
		hunt_info += " [color=#f88]目标:%s 猎人:%d/5[/color]" % [_hunt_target.get("_animal_type"), hc]
	else: hunt_info += " [color=gray](待命)[/color]"
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
func _my_nation_tag() -> String:
	if not battle or not battle.has_method("get_nation_name"):
		return ""
	var nat := -1
	if battle is OnlineBattleManager:
		nat = int(battle.player_info.get(my_peer_id, {}).get("nation", -1))
	elif my_peer_id != -1 and battle.ai_players.has(my_peer_id):
		nat = int(battle.ai_players[my_peer_id].get("nation", -1))
	else:
		nat = int(GameSettings.enemy_nation)
	if nat >= 0:
		return " [color=#ffd34f]「%s」[/color]" % battle.get_nation_name(nat)
	return ""
var _pop_bar: ProgressBar; var _pop_label: Label
var _res_bars: Array = []; var _res_labels: Array = []
var _mil_rtl: RichTextLabel; var _bld_rtl: RichTextLabel
var _title_rtl: RichTextLabel = null       # 面板标题（用于追加国家名）
var _panel_title_base: String = ""         # 不含国家名的原始标题
var _collapse_btn: Button = null           # 标题栏右侧的隐藏/展开按钮
var _body_vb: VBoxContainer = null         # 面板主体（隐藏时整块不可见）
var _panel_collapsed: bool = false         # 面板是否已收起为标题条
var _panel_bg_style: StyleBoxFlat = null   # 面板底板样式（按友方/敌方着色）
var _last_relation: int = -2               # 上次计算的敌我关系，避免每帧重设样式
const PANEL_WIDTH: float = 540.0
const PANEL_HEIGHT: float = 380.0
const PANEL_COLLAPSED_HEIGHT: float = 44.0

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
		1: return Color(0.25, 0.65, 1.0)
		-1: return Color(1.0, 0.3, 0.25)
		_: return Color(0.7, 0.7, 0.7)

func _relation_tag() -> String:
	match _relation_to_player():
		1: return "[color=#4ac3ff]🛡 友方[/color] "
		-1: return "[color=#ff6b5a]⚔ 敌方[/color] "
		_: return ""

# 面板边框/底色按友方蓝、敌方红区分（乱斗联盟变化时随之刷新）
func _apply_panel_relation() -> void:
	if _panel_bg_style == null: return
	var rel = _relation_to_player()
	if rel == _last_relation: return
	_last_relation = rel
	var c = _relation_color()
	_panel_bg_style.border_color = Color(c.r, c.g, c.b, 0.7)
	_panel_bg_style.border_width_left = 6
	_panel_bg_style.border_width_right = 2
	_panel_bg_style.border_width_top = 2
	_panel_bg_style.border_width_bottom = 2
	if rel == 1:
		_panel_bg_style.bg_color = Color(0.04, 0.09, 0.16, 0.93)
	elif rel == -1:
		_panel_bg_style.bg_color = Color(0.15, 0.05, 0.06, 0.93)
	else:
		_panel_bg_style.bg_color = Color(0.05, 0.06, 0.12, 0.92)

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
	var bg_style = StyleBoxFlat.new(); bg_style.bg_color = Color(0.05, 0.06, 0.12, 0.92)
	bg_style.corner_radius_top_left = 8; bg_style.corner_radius_top_right = 8
	bg_style.corner_radius_bottom_left = 8; bg_style.corner_radius_bottom_right = 8
	bg_style.border_width_left = 2; bg_style.border_width_right = 2
	bg_style.border_width_top = 2; bg_style.border_width_bottom = 2
	bg_style.border_color = Color(0.25, 0.5, 0.8, 0.5)
	_panel_bg_style = bg_style
	_apply_panel_relation()
	bg.add_theme_stylebox_override("panel", bg_style); debug_panel.add_child(bg)
	var vb = VBoxContainer.new(); vb.position = Vector2(10, 8); vb.add_theme_constant_override("separation", 3)
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
	# 面板主体：全部内容挂这里，隐藏按钮关闭整块
	var body = VBoxContainer.new(); body.add_theme_constant_override("separation", 3)
	vb.add_child(body); _body_vb = body
	_header_rtl = _make_rtl(); _header_rtl.add_theme_font_size_override("font_size", 19); body.add_child(_header_rtl)
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
	body.add_child(_make_section("⚔️ 军队")); _mil_rtl = _make_rtl(); body.add_child(_mil_rtl)
	body.add_child(_make_section("🏰 建筑")); _bld_rtl = _make_rtl(); body.add_child(_bld_rtl)
	var hud = battle.get_node("UI") as CanvasLayer; hud.add_child(debug_panel)
	if not OS.is_debug_build():
		debug_panel.visible = false

# ▼/▲：隐藏或展开面板主体。收起后仅保留标题条，面板高度同步压缩，不再长期遮挡战场
func _on_collapse_pressed():
	if _collapse_btn == null or _body_vb == null or debug_panel == null:
		return
	_panel_collapsed = _collapse_btn.button_pressed
	_body_vb.visible = not _panel_collapsed
	_collapse_btn.text = "▲" if _panel_collapsed else "▼"
	_collapse_btn.tooltip_text = "展开 AI 决策面板" if _panel_collapsed else "隐藏 AI 决策面板"
	var h = PANEL_COLLAPSED_HEIGHT if _panel_collapsed else PANEL_HEIGHT
	debug_panel.custom_minimum_size = Vector2(PANEL_WIDTH, h)
	debug_panel.size = Vector2(PANEL_WIDTH, h)

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
		LateTactic.HARASS: return "🔥 骚扰"
		LateTactic.OVERWHELM: return "⚔️ 压制"
		LateTactic.RAID: return "⚡ 突袭"
		LateTactic.DEFEND: return "🛡️ 防守"
		_: return "未知"

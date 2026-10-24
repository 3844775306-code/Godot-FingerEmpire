# scripts/ai/AI.gd
# Merged AI Controller — single-player + online dual-mode
extends Node

class_name AIController

const AIDefenseScript = preload("res://scripts/ai/AIDefense.gd")
const AIWaterCrossingScript = preload("res://scripts/ai/AIWaterCrossing.gd")

enum Phase { PRODUCTION, DEVELOPMENT, ASSAULT }
enum LateTactic { NONE, HARASS, OVERWHELM, RAID, DEFEND }

@onready var battle = get_parent()

var phase: int = Phase.PRODUCTION
var timer: float = 0.0
var think_interval: float = 2.0  # overridden by difficulty in _ready
var _think_ready: bool = false    # 难度对应的思考间隔只初始化一次
var worker_allocate_timer: float = 0.0
const WORKER_ALLOCATE_INTERVAL: float = 3.0
var last_attack_time: float = -999.0
const ATTACK_COOLDOWN: float = 120.0
var production_step: int = 0

var wanted_buildings: Array = [20, 21, 29, 23, 42, 54, 24, 52, 53]
var wanted_units: Array = [11,12,15,16,17,18,35,36,37,38,39,40,13,43,44,45,46,47,48,49,50,58,59,5,6,9]
var target_army_count: int = 7
# 贸易车只跟随这四种商人；AI 生产贸易车时数量必须小于商人数量，避免刷出一堆闲置车
const TRADE_CART_ID: int = 6
const MERCHANT_UNIT_IDS: Array = [43, 44, 45, 51]
# 民居数量上限：第 X 分钟至少 X 座（X 最多 8），提前一分钟开工保证到点时已建成
const HOUSE_TARGET_MAX: int = 8
const HOUSE_BUILD_LEAD_MINUTES: int = 1
var target_house_count: int = HOUSE_TARGET_MAX
var desired_worker_count: int = 8

var cached_shipyard_pos: Vector3 = Vector3.ZERO
var defense_line_built: bool = false
var defense_check_timer: float = 0.0
var defense_initialized: bool = false   # 防线位置已规划（进入分批建造阶段）
var _defense_queue: Array = []          # 待建防线队列：[{"id": 建筑id, "pos": 位置}]
const DEFENSE_CHECK_INTERVAL: float = 120.0
const DEFENSE_STEP_MAX: int = 3         # 每个 think tick 至多尝试建造的防线建筑数
var _defense = null                      # AIDefense 模块：威胁/防线/守军/资源区
var _water_crossing = null               # AIWaterCrossing 模块：搭桥/运载船渡水
var _harass_ids: Dictionary = {}         # 当前骚扰小队 instance_id -> true
var _harass_until: float = -999.0        # 骚扰小队回收时间
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
# 新版重装武器厂(29)只有在4级才会解锁巨型投石机(59)。
# 以前 29 排在建/升级队列很后面，且 59 没有独立生产目标，实战里几乎见不到。
# 这里把 29 提前，并让 AI 主动攒资源造一台 59。
const MILITARY_PRODUCER_TARGETS = {21: 3, 24: 2, 29: 1}
const TREBUCHET_ID: int = 59
const HEAVY_SIEGE_BUILDING_ID: int = 29
const TREBUCHET_TARGET_COUNT: int = 1
const TREBUCHET_SAVE_TIMEOUT: float = 90.0
const HEAVY_SIEGE_TECH_SAVE_TIMEOUT: float = 180.0
var _trebuchet_save_started: float = -1.0
var _heavy_siege_tech_save_started: float = -1.0
# 石油通常位于水域中央，船坞只要建在能出海的水岸即可，不必紧贴油田；
# 该半径用于判断水岸是否可服务油田，以及已建船坞是否仍值得保留。
const SHIPYARD_OIL_REACH: float = 32.0
const SHIPYARD_SPACING: float = 35.0
const SHIPYARD_FISHER_RADIUS: float = 15.0
var built_shipyard_pos: Array[Vector3] = []

const RAID_MIN_SPECIAL_TROOPS: int = 3
const RAID_FLANK_MIN: float = 28.0
const RAID_FLANK_MAX: float = 46.0
const RAID_WAIT_TIME: float = 5.0
const AVOID_DEFENSE_RANGE: float = 22.0
const RAID_UNIT: int = 15
const WALL_COUNT: int = 12
const WALL_SPACING: float = 1.3
# 远程单位上墙：墙未破时免疫伤害，因此优先把闲置远程兵铺到墙格上；
# 每格一个单位，赶路中的单位用 ai_wall_guard 预留墙格。
const WALL_DEPLOY_INTERVAL: float = 6.0
const WALL_DEPLOY_MAX_DISTANCE: float = 60.0
var _wall_deploy_timer: float = 0.0
const TOWER_SPACING: float = 3.0
const DEFENSE_FRONT_DIST: float = 8.0
const BUILD_ENEMY_ARMY_SAFE_RADIUS: float = 10.0
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
	return battle.can_train_unit(my_team)

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
# 统一走 battle 的实体缓存，避免每个统计函数都把 entities 子节点全扫一遍。
func _ensure_battle_cache() -> void:
	if battle and battle.has_method("_ensure_cache_fresh"):
		battle._ensure_cache_fresh()

func _cached_armies() -> Array:
	_ensure_battle_cache()
	return battle._armies

func _cached_buildings() -> Array:
	_ensure_battle_cache()
	return battle._buildings

func count_unit(id: int, include_queue: bool = true) -> int:
	var cnt = 0
	# Count existing units
	for entity in _cached_armies():
		if not is_instance_valid(entity) or entity.health <= 0:
			continue
		if entity.entity_id == id:
			if my_peer_id != -1 and entity.owner_peer_id != my_peer_id: continue
			if my_peer_id == -1 and entity.team != my_team: continue
			cnt += 1
	# Count units in production queues（决策用；面板统计传 false，避免把队列当成已存在单位）
	if include_queue:
		for entity in _cached_buildings():
			if not is_instance_valid(entity) or entity.health <= 0:
				continue
			if my_peer_id != -1 and entity.owner_peer_id != my_peer_id: continue
			if my_peer_id == -1 and entity.team != my_team: continue
			for pid in entity.production_queue:
				if pid == id: cnt += 1
	return cnt

# 商人总数（含生产队列）；贸易车数量必须严格小于该值
func _count_merchants() -> int:
	var total: int = 0
	for mid in MERCHANT_UNIT_IDS:
		total += count_unit(mid)
	return total

func count_building(id: int) -> int:
	var cnt = 0
	for entity in _cached_buildings():
		if not is_instance_valid(entity) or entity.health <= 0:
			continue
		if entity.entity_id == id:
			if my_peer_id != -1 and entity.owner_peer_id != my_peer_id: continue
			if my_peer_id == -1 and entity.team != my_team: continue
			cnt += 1
	return cnt
func count_military(peer: int) -> int:
	var total = 0
	for entity in _cached_armies():
		if not is_instance_valid(entity) or entity.health <= 0:
			continue
		if my_peer_id != -1 and entity.owner_peer_id != peer: continue
		if my_peer_id == -1 and entity.team != peer: continue
		if entity.entity_id != 10 and entity.entity_id != 14 and entity.entity_id not in [43,44,45,46,47,48,49,50,51]:
			total += 1
	# Count queued military units in production
	for entity in _cached_buildings():
		if not is_instance_valid(entity) or entity.health <= 0:
			continue
		if my_peer_id != -1 and entity.owner_peer_id != peer: continue
		if my_peer_id == -1 and entity.team != peer: continue
		for pid in entity.production_queue:
			if pid != 10 and pid != 14 and pid not in [43,44,45,46,47,48,49,50,51]:
				total += 1
	return total

func count_military_by_team(tm: int) -> int:
	var total = 0
	for entity in _cached_armies():
		if not is_instance_valid(entity) or entity.health <= 0:
			continue
		if entity.team != tm: continue
		if entity.entity_id != 10 and entity.entity_id != 14 and entity.entity_id not in [43,44,45,46,47,48,49,50,51]:
			total += 1
	# Count queued military units in production
	for entity in _cached_buildings():
		if not is_instance_valid(entity) or entity.health <= 0:
			continue
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
			var vision: float = float(e.vision_range)
			# 用实际有效视野（地图倍率、高地、森林遮蔽），而不是裸视野半径
			if battle.has_method("get_effective_vision"):
				vision = float(battle.get_effective_vision(e))
			if e.global_position.distance_to(target.global_position) <= vision:
				return true
	return false

# Refresh visible enemies cache (called once per think cycle)
func _refresh_visibility():
	_visible_enemies.clear()
	# 先缓存己方视野源，避免对每个敌人重复全实体扫描和重复计算有效视野
	var sources: Array = []
	for own in battle.entities.get_children():
		if not (own is GameEntity) or own.health <= 0:
			continue
		if not entity_belongs_to_me(own):
			continue
		var vision: float = float(own.vision_range)
		if battle.has_method("get_effective_vision"):
			vision = float(battle.get_effective_vision(own))
		sources.append([own.global_position, vision])
	if sources.is_empty():
		return
	# 后期每个 AI 可能有上百个单位，若每个单位都作为视野源查询一次，
	# 4 个 AI 每轮会做数百次空间查询。按 12×12 区域每格保留一个代表，
	# 再做上限截断，既保持全图视野覆盖，又避免重复查询同一片区域。
	if sources.size() > 24:
		var by_cell: Dictionary = {}
		for s in sources:
			var key := Vector2i(int(floor((s[0] as Vector3).x / 12.0)), int(floor((s[0] as Vector3).z / 12.0)))
			if not by_cell.has(key):
				by_cell[key] = s
			elif float(s[1]) > float(by_cell[key][1]):
				by_cell[key] = s
		sources = by_cell.values()
		if sources.size() > 64:
			var sampled: Array = []
			var step: float = float(sources.size()) / 64.0
			for i in 64:
				sampled.append(sources[int(i * step)])
			sources = sampled
	# 有空间索引时按视野源查询附近敌军并去重，避免“己方单位数 × 全图敌人数”的
	# 双重循环；没有 battle 空间索引时保留原来的全量扫描兜底。
	if battle.has_method("get_nearby_enemies"):
		var seen: Dictionary = {}
		for s in sources:
			for e in battle.get_nearby_enemies(s[0], float(s[1]), my_team, my_peer_id):
				if not (e is GameEntity) or e.health <= 0: continue
				if entity_belongs_to_me(e): continue
				if e is WorldResource: continue
				var eid: int = e.get_instance_id()
				if seen.has(eid): continue
				seen[eid] = true
				_visible_enemies.append(e)
		return
	for e in battle.entities.get_children():
		if not (e is GameEntity): continue
		if e.health <= 0: continue
		if entity_belongs_to_me(e): continue
		if e is WorldResource: continue
		var ep: Vector3 = e.global_position
		for s in sources:
			if (s[0] as Vector3).distance_to(ep) <= float(s[1]):
				_visible_enemies.append(e)
				break

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
		53, 54:   # 城堡、修道院 → 主城4级
			return cl >= 4
		42:   # 书院→3级
			return cl >= 3
	return true

# ═══ 巨型投石机专线 ═══
# AI 以前的兵种列表里虽然有 59，但缺少“科技 + 攒钱 + 优先生产”的完整链路：
# 重装武器厂(29)要升到4级才会解锁，升级又需要城堡4级和大量石/油；
# 同时普通军队会持续吃掉资源，导致 59 永远差一点资源。
# 下面几个函数负责：优先把 29 推到4级、解锁后暂停普通消费攒钱、最后优先排产 59。

func _find_own_building(building_id: int) -> Building:
	for entity in battle.entities.get_children():
		if entity is Building and entity.health > 0 and entity.entity_id == building_id and entity_belongs_to_me(entity):
			return entity
	return null

func _trebuchet_pending() -> bool:
	return count_unit(TREBUCHET_ID) < TREBUCHET_TARGET_COUNT

func _trebuchet_unlocked() -> bool:
	for entity in battle.entities.get_children():
		if entity is Building and entity.health > 0 and entity.build_timer <= 0 and entity.entity_id == HEAVY_SIEGE_BUILDING_ID and entity_belongs_to_me(entity):
			if entity.upgrade_level >= 4:
				return true
	return false

# 解锁 59 之后，如果普通生产继续花钱，就永远凑不齐 200木/250石/150金。
# 这里在解锁后进入短暂的“攒钱模式”：除 59 本身外，其他消费都要求扣完后仍能支付 59。
# 防守或人口已满时不启用，避免 AI 为了憋投石机而不补兵/不造民居。
func _trebuchet_reserve_active() -> bool:
	if not _trebuchet_pending():
		_trebuchet_save_started = -1.0
		return false
	if not _trebuchet_unlocked():
		return false
	if not _can_train_unit():
		return false
	if _is_defending():
		return false
	if battle == null:
		return false
	if _trebuchet_save_started < 0.0:
		_trebuchet_save_started = battle.game_time
	if battle.game_time - _trebuchet_save_started > TREBUCHET_SAVE_TIMEOUT:
		_trebuchet_save_started = -1.0
		return false
	return true

func _can_pay_with_trebuchet_reserve(cost: Dictionary) -> bool:
	var tcfg = EntityDatabase.get_config(TREBUCHET_ID)
	if not tcfg:
		return true
	return _can_pay_with_reserve(cost, tcfg.get("cost", {}))

func _can_pay_with_reserve(cost: Dictionary, reserve_cost: Dictionary) -> bool:
	var res = _get_resources()
	for k in cost:
		if int(res.get(k, 0)) - int(cost[k]) < int(reserve_cost.get(k, 0)):
			return false
	return true

# 29 的升级和“城堡等级追上 29”都消耗大量石/油/金。
# 29 一落地就开始留这段预算，否则普通升级/重装兵会把资源反复花掉，
# AI 永远卡在“差一点就能升29”的状态。
func _heavy_siege_tech_reserve_cost() -> Dictionary:
	if not _trebuchet_pending():
		return {}
	if _trebuchet_unlocked():
		return {}
	var b29 = _find_own_building(HEAVY_SIEGE_BUILDING_ID)
	if b29 == null or b29.upgrade_level >= 4:
		return {}
	var castle = get_peer_castle(my_peer_id)
	if castle == null:
		return {}
	if castle.upgrade_level < 4:
		if castle.upgrade_level <= b29.upgrade_level:
			return castle.get_upgrade_cost()
		return {}
	return b29.get_upgrade_cost()

func _heavy_siege_tech_reserve_active() -> bool:
	if _is_defending():
		return false
	var cost = _heavy_siege_tech_reserve_cost()
	if cost.is_empty():
		_heavy_siege_tech_save_started = -1.0
		return false
	if battle == null:
		return false
	if _heavy_siege_tech_save_started < 0.0:
		_heavy_siege_tech_save_started = battle.game_time
	if battle.game_time - _heavy_siege_tech_save_started > HEAVY_SIEGE_TECH_SAVE_TIMEOUT:
		_heavy_siege_tech_save_started = -1.0
		return false
	return true

func _try_produce_trebuchet() -> bool:
	if not _trebuchet_pending():
		return false
	if not _trebuchet_unlocked():
		return false
	if not _can_train_unit():
		return false
	if not can_afford(TREBUCHET_ID):
		return false
	if produce_unit(TREBUCHET_ID):
		_trebuchet_save_started = -1.0
		return true
	return false

# 重装武器厂4级需要城堡4级；城堡等级不够时先升城堡，够了一级一级升 29。
func _ensure_heavy_siege_tech() -> bool:
	if not _trebuchet_pending():
		return false
	var b29: Building = null
	for entity in battle.entities.get_children():
		if entity is Building and entity.health > 0 and entity.entity_id == HEAVY_SIEGE_BUILDING_ID and entity_belongs_to_me(entity):
			if b29 == null or int(entity.upgrade_level) > int(b29.upgrade_level):
				b29 = entity
	if b29 == null or b29.upgrade_level >= 4:
		return false
	var castle = get_peer_castle(my_peer_id)
	if castle == null:
		return false
	if castle.upgrade_level <= b29.upgrade_level:
		if can_afford_upgrade(20):
			upgrade_building(20)
			_heavy_siege_tech_save_started = -1.0
			return true
		return false
	for entity in battle.entities.get_children():
		if entity is Building and entity.health > 0 and entity.build_timer <= 0 and entity.entity_id == HEAVY_SIEGE_BUILDING_ID and entity_belongs_to_me(entity):
			if entity.upgrade_level < 4 and entity.can_upgrade():
				if entity.perform_upgrade(battle):
					_heavy_siege_tech_save_started = -1.0
					return true
	return false

func can_afford(unit_id: int) -> bool:
	var cfg = EntityDatabase.get_config(unit_id)
	if not cfg: return false
	var cost = cfg.get("cost", {})
	var res = _get_resources()
	for k in cost: if res.get(k, 0) < cost[k]: return false
	if unit_id != TREBUCHET_ID and _trebuchet_reserve_active():
		return _can_pay_with_trebuchet_reserve(cost)
	if unit_id != TREBUCHET_ID and _heavy_siege_tech_reserve_active():
		return _can_pay_with_reserve(cost, _heavy_siege_tech_reserve_cost())
	return true

func can_afford_building(building_id: int) -> bool:
	var cfg = EntityDatabase.get_config(building_id)
	if not cfg: return false
	var cost = cfg.get("cost", {})
	var res = _get_resources()
	for k in cost: if res.get(k, 0) < cost[k]: return false
	if _trebuchet_reserve_active():
		return _can_pay_with_trebuchet_reserve(cost)
	if _heavy_siege_tech_reserve_active():
		return _can_pay_with_reserve(cost, _heavy_siege_tech_reserve_cost())
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
				if _trebuchet_reserve_active():
					return _can_pay_with_trebuchet_reserve(cost)
				if building_id != HEAVY_SIEGE_BUILDING_ID and building_id != 20 and _heavy_siege_tech_reserve_active():
					return _can_pay_with_reserve(cost, _heavy_siege_tech_reserve_cost())
				return true
	return false

# ═══ Production ═══
func produce_unit(unit_id: int) -> bool:
	# 贸易车没有商人可跟就是废单位；生产时严格保证“车 < 商人”
	if unit_id == TRADE_CART_ID and count_unit(TRADE_CART_ID) >= _count_merchants():
		return false

	var produced = 0
	for entity in battle.entities.get_children():
		if produced >= 1: break
		if entity is Building and entity.health > 0 and entity.build_timer <= 0:
			if not entity_belongs_to_me(entity): continue
			if entity.try_produce(unit_id):
				produced += 1
	return produced > 0

# 建造前安全检查：10 单位内存在敌方作战军队时不允许落建筑，
# 避免 AI 当着敌军的面拍塔/拍民居，刚建好就被拆。
func _enemy_army_within(pos: Vector3, radius: float = BUILD_ENEMY_ARMY_SAFE_RADIUS) -> bool:
	if battle == null:
		return false
	for e in battle.get_nearby_entities(pos, radius):
		if not (e is Army) or e.health <= 0:
			continue
		if int(e.target_type) <= 0 and float(e.attack) <= 0.0:
			continue
		if _entity_is_enemy(e):
			return true
	return false

# 最终落位校验：AI 的所有建造入口（随机仓库、防线规划、补建队列）都必须过这一关，
# 防止建筑重叠、建到水面/山坡上，或直接压住资源点。
func _can_place_ai_building(building_id: int, pos: Vector3) -> bool:
	var half = RTSConfig.MAP_SIZE / 2.0
	var gx = int(round(pos.x + half))
	var gz = int(round(pos.z + half))
	if gx < 0 or gx >= RTSConfig.MAP_SIZE or gz < 0 or gz >= RTSConfig.MAP_SIZE:
		return false
	# 桥只能建在水上，使用战斗管理器与玩家共用的选址校验
	if building_id == 7:
		if battle.has_method("is_valid_bridge_position"):
			return battle.is_valid_bridge_position(pos)
		return false
	var terrain = battle.get_terrain_at_grid(gx, gz)
	if terrain == 2:
		return false
	# 船坞：必须放在陆地且至少邻接一格水面
	if building_id == 23:
		if terrain != 0:
			return false
		var water_adj = 0
		for dx in [-1, 0, 1]:
			for dz in [-1, 0, 1]:
				if dx == 0 and dz == 0: continue
				if battle.get_terrain_at_grid(gx + dx, gz + dz) == 2:
					water_adj += 1
		if water_adj < 1:
			return false
	else:
		if terrain != 0:
			return false
		var cfg_t = EntityDatabase.get_config(building_id)
		var br_t = float(cfg_t.get("body_radius", 1.0)) if cfg_t else 1.0
		if battle.has_method("_is_terrain_flat") and not battle._is_terrain_flat(pos, maxf(0.5, br_t * 0.5)):
			return false
	var cfg = EntityDatabase.get_config(building_id)
	if not cfg: return false
	var radius = maxf(0.5, float(cfg.get("body_radius", 1.0)))
	# 与所有存活建筑/资源点做实际体积相交检测；单位可以移动，不在这里卡建造
	for e in battle.entities.get_children():
		if not (e is Building or e is WorldResource) or e.health <= 0: continue
		var other_radius = maxf(0.3, float(e.body_radius))
		var min_dist = radius + other_radius + 0.15
		# 城墙本来就是首尾相接的连续墙段，允许墙与墙贴紧；墙和其他建筑仍按体积避让
		if building_id == 27 and e is Building and e.entity_id == 27:
			min_dist = 0.9
		if e.global_position.distance_to(pos) < min_dist:
			return false
	return true

func build_building(building_id: int, pos: Vector3, facing: Vector3 = Vector3.ZERO) -> bool:
	var cfg = EntityDatabase.get_config(building_id)
	if not cfg: return false
	# Check castle level requirement (matches RTSBattleManager.is_building_unlocked)
	if not _ai_can_build(building_id): return false
	# 城墙允许建 WALL_COUNT 面（防线需求），民居最多 HOUSE_TARGET_MAX 座，其余建筑上限 10
	var _cap = WALL_COUNT if building_id == 27 else (target_house_count if building_id == 28 else 10)
	if count_building(building_id) >= _cap: return false
	# 周围 10 单位内不能有敌方作战军队；否则直接放弃本次建造，不扣资源
	if _enemy_army_within(pos):
		return false
	# Non-shipyard buildings: must be within AI vision range
	if building_id == 7:
		# 桥从己方岸边向对岸延伸：第一段允许在 20 距离内建造，
		# 后续桥段允许紧邻已有桥继续往前修，否则远端会因视野不足中断
		var bridge_world_pos = Vector3(pos.x, 0, pos.z)
		var bridge_visible = false
		for e in battle.entities.get_children():
			if e is GameEntity and e.health > 0 and entity_belongs_to_me(e):
				if e is Building and e.entity_id == 7:
					if e.global_position.distance_to(bridge_world_pos) <= 3.0:
						bridge_visible = true
						break
				if e.global_position.distance_to(bridge_world_pos) <= maxf(float(e.vision_range), 20.0):
					bridge_visible = true
					break
		if not bridge_visible:
			return false
	elif building_id != 23:
		var world_pos = Vector3(pos.x, 0, pos.z)
		var visible = false
		for e in battle.entities.get_children():
			if e is GameEntity and e.health > 0 and entity_belongs_to_me(e):
				if e.global_position.distance_to(world_pos) <= e.vision_range:
					visible = true
					break
		if not visible:
			return false  # cannot build outside vision
	if not _can_place_ai_building(building_id, pos):
		return false
	var cost = cfg.get("cost", {})
	if not _deduct_resources(cost): return false
	cfg["owner_peer_id"] = my_peer_id
	# 队伍判定：在线走 player_info；本地乱斗/多人各 AI 有唯一 team(my_team)，
	# 若始终用 RED 会让 AI 建筑建错阵营，被自己和盟友攻击。
	var team = my_team
	if my_peer_id != -1:
		if battle is OnlineBattleManager:
			team = battle.player_info[my_peer_id].team
		else:
			team = my_team
	var b = battle.spawn_entity(cfg, team, pos)
	if b:
		# 防御塔朝向敌方/防线正面；城墙是方形墙体，不需要额外朝向
		if facing.length_squared() > 0.01 and building_id in [25, 26]:
			var face_target: Vector3 = b.global_position + Vector3(facing.x, 0.0, facing.z).normalized()
			b.look_at(face_target, Vector3.UP)
		b.start_construction(5.0, cfg)
	return b != null

func upgrade_building(building_id: int):
	for entity in battle.entities.get_children():
		if entity is Building and entity.health > 0 and entity.entity_id == building_id:
			if not entity_belongs_to_me(entity): continue
			# 同类型可能有多个建筑；升级建筑必须是当前可升级的那一个，
			# 不能只看第一个（第一个满级后会导致后面同类建筑永远不升级）
			if not entity.can_upgrade(): continue
			if entity.perform_upgrade(battle): return

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
	for entity in _cached_buildings():
		if not is_instance_valid(entity) or entity.health <= 0:
			continue
		if entity.build_timer <= 0:
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
	_defense = AIDefenseScript.new(self)
	_water_crossing = AIWaterCrossingScript.new(self)

func _process(delta):
	# Set think interval based on difficulty (once) + 错开各 AI 的计时器。
	# 多 AI 同时开局时，timer/worker/naval 都为 0，会在同一帧集中做全实体扫描和寻路，
	# 造成明显的周期性卡顿；按 peer/instance id 相位错开可把峰值摊到不同帧。
	if not _think_ready:
		_think_ready = true
		var diff = GameSettings.ai_difficulty
		if battle is OnlineBattleManager and my_peer_id != -1:
			diff = GameSettings.red_ai_difficulty if my_team == RTSConfig.Team.RED else GameSettings.blue_ai_difficulty
		if diff == GameSettings.AIDifficulty.EASY: think_interval = 2.0
		elif diff == GameSettings.AIDifficulty.NORMAL: think_interval = 1.75
		elif diff == GameSettings.AIDifficulty.HARD: think_interval = 1.5
		elif diff == GameSettings.AIDifficulty.HELL: think_interval = 1.0
		var seed_id: int = my_peer_id if my_peer_id >= 0 else my_team
		var phase: float = float((seed_id * 7 + get_instance_id() % 13) % 17) / 17.0
		timer = think_interval * phase
		worker_allocate_timer = WORKER_ALLOCATE_INTERVAL * phase
		_naval_patrol_timer = NAVAL_PATROL_INTERVAL * phase
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
		# 后期实体多时 AI 决策降频：单次 decide 会做多轮全实体统计和可见性刷新，
		# 4 个 AI 同时跑会造成周期性主线程尖峰。260 个实体后拉长间隔，
		# 不影响前期节奏，但能显著降低后期 AI 的固定开销。
		var interval: float = think_interval
		var entity_count: int = battle._all_entities.size() if battle else 0
		if entity_count > 450:
			interval *= 2.4
		elif entity_count > 360:
			interval *= 1.9
		elif entity_count > 260:
			interval *= 1.5
		timer = interval
		decide(interval)
	worker_allocate_timer -= delta
	if worker_allocate_timer <= 0:
		worker_allocate_timer = WORKER_ALLOCATE_INTERVAL
		allocate_workers()
	_naval_patrol_timer -= delta
	if _naval_patrol_timer <= 0:
		_naval_patrol_timer = NAVAL_PATROL_INTERVAL
		if phase >= Phase.DEVELOPMENT:
			_patrol_navy_around_water()
	# 部队积累判定放到 decide() 的 AI 思考节流里，避免每帧全实体扫描

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
		# 船坞/渔船/仓库都只是可选开局动作，任何一项失败都不能让 AI 永远停在 PRODUCTION
		if count_building(23) < 1 and _ai_can_build(23) and can_afford_building(23):
			_cache_shipyard_location()
			if cached_shipyard_pos != Vector3.ZERO:
				if build_building(23, cached_shipyard_pos):
					built_shipyard_pos.append(cached_shipyard_pos)
		if count_building(23) > 0 and count_unit(14) < 3 and can_afford(14) and _can_train_unit():
			produce_unit(14)
		if warehouses < WAREHOUSE_MAX_COUNT and can_afford_building(22):
			var castle = get_peer_castle(my_peer_id)
			if castle:
				var near_count = 0
				for e in battle.entities.get_children():
					if e is Building and e.entity_id == 22 and e.team == my_team and e.health > 0:
						if e.global_position.distance_to(castle.global_position) < 25.0: near_count += 1
				# More warehouses nearby = lower priority, but still build if < 5 total
				if near_count < 3:
					var wpos = find_valid_build_position(castle.global_position, 22)
					if wpos != Vector3.ZERO:
						build_building(22, wpos)
		# 工人已补齐（进入 step1 的前提）或已经过开局阶段，就直接进入 DEVELOPMENT
		if count_unit(10) >= desired_worker_count or battle.game_time >= 120.0:
			phase = Phase.DEVELOPMENT
		_process_line_military()
	# 开局就被压到家时不能只造农民/升级主城，否则会一直处于“防守但不补兵”的状态
	if _is_defending():
		_process_line_military()
		_process_line_1()
		_process_line_3()

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
	var defending: bool = _is_defending()
	if defending:
		# 防守时先补军队，再补建筑和升级；否则升级会先把资源吃光，导致一直不补兵
		_process_line_military()
		_process_line_1()
	
	if not _priority_upgrade():
		_process_line_upgrade()
	
	if not defending:
		_process_line_military()
	_process_line_1()
	_process_line_3()
	# 主力出击不再只等到 ASSAULT：发育阶段兵力成型且开局时间已过，也要主动发起主攻
	_process_line_4()
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
	update_tactic(_delta)

# -- ASSAULT: execute tactical attacks --
func _state_assault(_delta):
	# 进攻阶段也要先把资源投到建筑升级上，不能只无限补兵
	if not _priority_upgrade():
		_process_line_upgrade()
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
		battle.update_resource_limits(my_team)
		battle.update_population_limits()
	clear_invalid_targets()
	_refresh_visibility()
	_refresh_primary_enemy()
	_ensure_house_quota()
	_diplo_decide()
	if _defense == null:
		_defense = AIDefenseScript.new(self)
	_defense.tick(_delta)
	_wall_deploy_timer -= _delta
	if _wall_deploy_timer <= 0.0:
		_wall_deploy_timer = WALL_DEPLOY_INTERVAL
		_deploy_ranged_units_to_walls()
	if Engine.get_process_frames() % 60 == 0:
		var _w = count_unit(10)
	# State dispatch
	match phase:
		Phase.PRODUCTION: _state_production(_delta)
		Phase.DEVELOPMENT: _state_development(_delta)
		Phase.ASSAULT: _state_assault(_delta)
	# 进攻阶段转换只在思考节流里判断；count_military 会遍历全部实体，不能每帧调用
	if phase == Phase.DEVELOPMENT:
		var army_count = count_military(my_peer_id if my_peer_id != -1 else my_team)
		if army_count >= 30:
			phase = Phase.ASSAULT
	if _water_crossing:
		_water_crossing.tick(_delta)
	if OS.is_debug_build() and (Engine.get_process_frames() + int(get_instance_id())) % 30 == 0:
		update_debug_label()
func get_team_castle(tm) -> Building:
	for entity in _cached_buildings():
		if not is_instance_valid(entity) or entity.health <= 0:
			continue
		if entity.entity_id == 20 and entity.team == tm:
			return entity
	return null

func get_peer_castle(peer) -> Building:
	for entity in _cached_buildings():
		if not is_instance_valid(entity) or entity.health <= 0:
			continue
		if entity.entity_id == 20:
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

# 主攻目标：优先外交确定的主敌，其次对位队伍，最后找最近的敌对城堡。
# 乱斗里 BLUE/RED 不一定有国家，只按队伍找会拿到空目标，导致 AI 永远不发起主攻。
func _get_attack_target_castle() -> Building:
	if _primary_enemy_owner != -1:
		var oc = get_peer_castle(_primary_enemy_owner)
		if oc != null and oc.health > 0:
			return oc
	var tc = get_team_castle(_primary_enemy_team())
	if tc != null:
		return tc
	var my_castle = get_peer_castle(my_peer_id)
	var base = my_castle.global_position if my_castle else Vector3.ZERO
	var best: Building = null
	var best_d: float = INF
	for e in battle.entities.get_children():
		if not (e is Building) or int(e.entity_id) != 20 or e.health <= 0:
			continue
		if not _entity_is_enemy(e):
			continue
		var d: float = base.distance_squared_to(e.global_position)
		if d < best_d:
			best_d = d
			best = e
	return best

# 该实体是否对我构成敌对（owner 感知）。无外交管理器时退化为纯队伍判定，资源恒非敌。
func _entity_is_enemy(e) -> bool:
	if not (e is GameEntity) or e.health <= 0: return false
	if battle and battle.diplomacy and battle.diplomacy.active and my_peer_id != -1:
		var eo: int = -1
		if "owner_peer_id" in e: eo = e.owner_peer_id
		return eo >= 0 and eo != my_peer_id and battle.diplomacy.is_hostile(my_peer_id, eo)
	return e.team != my_team and not (e is WorldResource)

# 只统计 AI 当前视野内能看到的敌军，避免用全图信息做防守/进攻判断
func _visible_enemy_military() -> int:
	var total: int = 0
	for e in _visible_enemies:
		if not is_instance_valid(e) or e.health <= 0: continue
		if not (e is Army): continue
		if int(e.team) == RTSConfig.Team.NEUTRAL: continue
		if not _entity_is_enemy(e): continue
		# _visible_enemies 已经过视野筛选，不再重复调用 _is_visible_to_ai
		if e.entity_id != 10 and e.entity_id != 14 and int(e.entity_id) not in [43,44,45,46,47,48,49,50,51]:
			total += 1
	return total

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
			# 旧实现每个候选点都全表扫一遍建筑/资源；6×8 个候选点会放大成
			# 几十次全场扫描。先用空间索引取附近实体，再按同样半径规则判断。
			var nearby: Array = []
			if battle.has_method("get_nearby_entities"):
				nearby = battle.get_nearby_entities(test, float(radius) + 14.0)
			else:
				nearby = battle.entities.get_children()
			for entity in nearby:
				# 单位会移动，不能因为附近站着农民/士兵就判定无法建造；只避让建筑和资源点
				if not (entity is Building or entity is WorldResource) or entity.health <= 0: continue
				if test.distance_to(entity.global_position) < (radius + entity.body_radius + 2.0):
					overlap = true; break
			if not overlap and _is_valid_build_ground(test):
				return test
	# 兜底也要走地形校验；找不到就返回 ZERO 让调用方跳过，绝不能盲目偏移硬塞
	for _fb in range(10):
		var fp = near_pos + Vector3(cos(randf_range(0, TAU))*20, 0, sin(randf_range(0, TAU))*20)
		if _is_valid_build_ground(fp): return fp
	return Vector3.ZERO
	
	

func _get_build_position(b_id: int) -> Vector3:
	var castle = get_peer_castle(my_peer_id)
	if castle: return find_valid_build_position(castle.global_position, b_id)
	return Vector3.ZERO

# ═══ Worker allocation ═══
var allocate_timers = 0
# 同一轮农民分配里，资源点威胁只与资源点/敌人有关，与具体农民无关；
# 之前每个农民都会对每个资源点做一次 get_nearby_enemies，后期是 O(农民×资源)。
var _worker_threat_cache: Dictionary = {}

func allocate_workers():
	_worker_threat_cache.clear()
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
			if _worker_is_fleeing(w): continue
			var target = find_best_resource_for_worker(w, {"food": 100})
			if target: w.gather_at(target)

	# 已经达到目标农民数后，新增/逃跑回来的农民不会走上面的补农分支；
	# 这里每次分配都兜底处理完全空闲的农民，避免他们长期聚在主城不动。
	for w in workers:
		if _worker_is_fleeing(w):
			continue
		if w.has_meta("ai_flee_until"):
			w.remove_meta("ai_flee_until")
		if w.current_target == null and w.current_order == "":
			var idle_target = find_best_resource_for_worker(w, _get_phase_weights())
			if idle_target: w.gather_at(idle_target)

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
			if _worker_is_fleeing(w): continue
			if w.current_order == "deliver":
				for rk in ["gold","wood","stone","food"]:
					if w.cargo.get(rk, 0) > 0:
						current[rk] = current.get(rk, 0) + 1
						if current[rk] > scarcity.get(rk, 2): idle.append(w)
						break
		for w in idle:
			if _worker_is_fleeing(w): continue
			var best_rk = ""; var best_gap = -1.0
			for rk in scarcity:
				var gap = scarcity[rk] - current.get(rk, 0)
				if gap > best_gap: best_gap = gap; best_rk = rk
			if best_rk != "":
				var target = find_best_resource_for_worker(w, {best_rk: 100})
				if target: w.gather_at(target); current[best_rk] = current.get(best_rk, 0) + 1

func _worker_is_fleeing(w) -> bool:
	if w == null or not is_instance_valid(w) or not w.has_meta("ai_flee_until"):
		return false
	return battle != null and battle.game_time < float(w.get_meta("ai_flee_until"))

func _get_build_completion() -> float:
	var total_targets = 0.0; var built = 0.0
	for b_id in wanted_buildings:
		var target = MILITARY_PRODUCER_TARGETS.get(b_id, 1)
		total_targets += target
		built += min(count_building(b_id), target)
	return built / max(total_targets, 1.0)

func _get_phase_weights() -> Dictionary:
	var w: Dictionary
	if phase == Phase.PRODUCTION:
		if count_unit(10) < 8:
			w = {"gold": 0.5, "wood": 1.5, "stone": 0.8, "food": 5.0}
		else:
			w = {"gold": 1.0, "wood": 3.0, "stone": 2.0, "food": 1.5}
	else:
		var build_pct = _get_build_completion()
		if build_pct < 0.4:
			w = {"gold": 2.0, "wood": 4.5, "stone": 3.5, "food": 2.0}
		elif build_pct < 0.75:
			w = {"gold": 3.0, "wood": 3.0, "stone": 4.0, "food": 3.0}
		else:
			w = {"gold": 4.0, "wood": 2.0, "stone": 5.0, "food": 3.0}
	# 重装武器厂需要大量油；农民权重里以前完全没有 oil，升级 29 时会长期卡油。
	# 只在已有 29 或进入发育/进攻阶段后加入，避免开局抢走采粮/采木的农民。
	if phase >= Phase.DEVELOPMENT or count_building(HEAVY_SIEGE_BUILDING_ID) > 0:
		w["oil"] = maxf(float(w.get("oil", 0.0)), 1.5)
	if count_building(HEAVY_SIEGE_BUILDING_ID) > 0 and _trebuchet_pending() and not _trebuchet_unlocked():
		w["oil"] = maxf(float(w.get("oil", 0.0)), 4.0)
	return w

func clear_invalid_targets():
	for entity in battle.entities.get_children():
		if entity is Army and entity.health > 0 and entity_belongs_to_me(entity):
			if entity.current_target and not is_instance_valid(entity.current_target):
				entity.current_target = null
				entity.current_order = ""

# 农民选资源时，附近敌军只做“适度避让”，不能像以前那样直接 -500 把所有
# 受威胁资源一票否决；否则资源区一有敌人，农民就会全部缩回主城不出去。
const WORKER_THREAT_RADIUS: float = 12.0
const WORKER_THREAT_MAX_PENALTY: float = 2.5

func find_best_resource_for_worker(worker: Army, priority_score: Dictionary) -> WorldResource:
	var best = null; var best_score: float = -INF
	for entity in battle.entities.get_children():
		if entity is WorldResource and entity.health > 0:
			var type = entity.resource_type
			if type in priority_score:
				var score = priority_score[type] - worker.global_position.distance_to(entity.global_position) * 0.01
				var threat_penalty: float = float(_worker_threat_cache.get(entity, -1.0))
				if threat_penalty < 0.0:
					threat_penalty = 0.0
					var nearby: Array = []
					if battle.has_method("get_nearby_enemies"):
						nearby = battle.get_nearby_enemies(entity.global_position, WORKER_THREAT_RADIUS, worker.team, worker.owner_peer_id)
					else:
						nearby = battle.entities.get_children()
					for e in nearby:
						if not (e is Army) or e.health <= 0:
							continue
						if e.entity_id in [10, 14, 43, 44, 45]:
							continue
						if e.get("_animal_type") != null and str(e.get("_animal_type")) != "":
							continue
						if not _entity_is_enemy(e):
							continue
						var d: float = e.global_position.distance_to(entity.global_position)
						if d < WORKER_THREAT_RADIUS:
							# 距离越近惩罚越大，但上限只有 2.5，低于大多数资源权重，
							# 保证农民仍会挑一个相对安全的矿点出门，而不是全留主城。
							threat_penalty = maxf(threat_penalty, (1.0 - d / WORKER_THREAT_RADIUS) * WORKER_THREAT_MAX_PENALTY)
					_worker_threat_cache[entity] = threat_penalty
				score -= threat_penalty
				if score > best_score: best_score = score; best = entity
	return best

# 已有驻扎点的部队不再被进攻/打猎/巡逻调用；建筑被攻击时的本地反击单位
# 同样在短时间内保留目标，避免刚出门就被别的调度覆盖。
func _is_local_defense_active(u) -> bool:
	if u == null or not is_instance_valid(u) or not u.has_meta("ai_building_defense_until"):
		return false
	if float(battle.game_time) < float(u.get_meta("ai_building_defense_until")):
		return true
	u.remove_meta("ai_building_defense_until")
	return false

func _is_held_by_garrison(u) -> bool:
	if u == null or not is_instance_valid(u):
		return true
	if u.garrison_point != Vector3.ZERO:
		return true
	return _is_local_defense_active(u)

func attack_move(target_position: Vector3, max_units: int):
	var sent = 0
	for entity in battle.entities.get_children():
		if sent >= max_units: break
		if entity is Army and entity.health > 0 and int(entity.entity_id) not in [5,6,9,10,14,43,44,45,46,47,48,49,50,51] and entity_belongs_to_me(entity):
			if entity.has_meta("ai_home_guard") or entity.has_meta("ai_resource_guard") or entity.has_meta("ai_harass") or entity.has_meta("ai_transporting") or entity.has_meta("ai_escorting") or entity.has_meta("ai_wall_guard"):
				continue
			# 已有驻扎点的部队不再被主攻调用（防守时由 AIDefense 单独调度）
			if entity.garrison_point != Vector3.ZERO:
				continue
			if _is_local_defense_active(entity):
				continue
			var boarded = entity.get("_boarded_on")
			if boarded != null and int(boarded) != -1:
				continue
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
	# 科技攒钱期间不要顺手把主城升5级，优先保证29/59的前置科技
	if b_id == 20 and _heavy_siege_tech_reserve_active():
		return false
	# 29升到4级已解锁59，先把第一台59造出来再考虑升5级，别把石/油又吃光
	if b_id == HEAVY_SIEGE_BUILDING_ID and _trebuchet_pending():
		var highest_lv = 0
		for entity in battle.entities.get_children():
			if entity is Building and entity.health > 0 and entity.entity_id == b_id and entity_belongs_to_me(entity):
				highest_lv = maxi(highest_lv, int(entity.upgrade_level))
		if highest_lv >= 4:
			return false
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
	# 只检查建造点周围：己方建筑要留出间距，敌人靠近则视为危险。
	# 以前对每个候选点全表扫两遍，AI 每次选址会重复几十次。
	var nearby: Array = []
	if battle.has_method("get_nearby_entities"):
		nearby = battle.get_nearby_entities(world_pos, 12.0)
	else:
		nearby = battle.entities.get_children()
	for e in nearby:
		if e is Building and e.team == my_team and e.health > 0:
			if e.global_position.distance_to(world_pos) < (e.body_radius + 3.0): return false
		if _entity_is_enemy(e):
			if e.global_position.distance_to(world_pos) < 10.0: return false
	return true

# ═══ Territory ═══
# 资源前哨已交给 AIDefense 统一按“正在采集的资源区 + 瞭望塔/守军”规划，
# 这里不再随机在资源旁边撒箭塔，避免消耗防线的石头与建造位。
func _ai_expand_territory():
	pass

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
# 沙漠类地图食物资源几乎为零、全靠兽群：狩猎要更频繁、范围更大，并允许农民一起上
func _is_hunting_heavy_map() -> bool:
	if String(GameSettings.map_id) == "desert":
		return true
	# 其它把 food 资源权重压到 0 的自定义图，同样按「以狩猎为食」处理
	var map = battle.get_node_or_null("Map")
	if map and map.get("map_preset") is Dictionary:
		var res: Dictionary = map.map_preset.get("resources", {})
		if res.has("food") and float(res.get("food", 1.0)) <= 0.0:
			return true
	return false

func _ai_hunt_animals(delta):
	_hunt_timer -= delta
	if _hunt_timer > 0: return
	var heavy: bool = _is_hunting_heavy_map()
	_hunt_timer = 45.0 if heavy else 120.0

	# Collect idle military units (not peasants, ships, merchants, officials)
	var idle_land = []   # land-capable
	var idle_water = []  # water-capable
	for e in battle.entities.get_children():
		if not (e is Army) or e.health <= 0: continue
		if not entity_belongs_to_me(e): continue
		# Exclude non-combat units
		if e.entity_id == 10 or e.entity_id == 14: continue  # peasants, gathering ships
		if e.entity_id == 5 or e.entity_id == 6: continue  # handcarts / trade carts
		if e.entity_id >= 43: continue  # merchants, officials, food merchant
		if e.has_meta("ai_home_guard") or e.has_meta("ai_resource_guard") or e.has_meta("ai_harass") or e.has_meta("ai_wall_guard"): continue
		if _is_held_by_garrison(e): continue
		if e.current_order != "" or e.current_target != null: continue  # only idle
		if e.water_capable: idle_water.append(e)
		else: idle_land.append(e)

	# 沙漠图食物全靠狩猎：把空闲农民也编入猎手（农民对动物有 10 倍伤害）
	if heavy:
		for e in battle.entities.get_children():
			if not (e is Army) or e.health <= 0: continue
			if e.entity_id != 10: continue
			if not entity_belongs_to_me(e): continue
			if _is_held_by_garrison(e): continue
			if e.current_order != "" or e.current_target != null: continue
			idle_land.append(e)

	if idle_land.is_empty() and idle_water.is_empty(): return

	var castle = get_peer_castle(my_peer_id)
	if not castle: return

	# Find animals within 30 units（沙漠图放宽到 60，兽群分布更散）
	var search_r: float = 60.0 if heavy else 30.0
	var swarm_limit: int = 6 if heavy else 3
	var max_hunters: int = 10 if heavy else 5
	var animals = []
	for e in battle.entities.get_children():
		if e is Army and e.health > 0:
			var at = e.get("_animal_type")
			if at != null and str(at) != "":
				var d = castle.global_position.distance_to(e.global_position)
				if d < search_r:
					animals.append({"entity": e, "dist": d, "is_fish": (at == "fish")})
	if animals.is_empty(): return
	animals.sort_custom(func(a, b): return a.dist < b.dist)

	# Pick a target not already swarmed
	var hunt_target = null; var is_fish_target = false
	for ai in animals:
		var existing = 0
		for e in battle.entities.get_children():
			if e is Army and entity_belongs_to_me(e) and e.current_target == ai.entity: existing += 1
		if existing < swarm_limit: hunt_target = ai.entity; is_fish_target = ai.is_fish; break
	if not hunt_target: return

	# Select hunters — strict water/land separation, no cross-terrain
	var hunters = []
	var pool = idle_water if is_fish_target else idle_land
	if pool.is_empty(): return  # no suitable units for this terrain
	for u in pool:
		if hunters.size() >= max_hunters: break
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
	# 战术判断只看当前视野内看到的敌军，不读取全图敌人军力
	var player_mil = _visible_enemy_military()
	_cleanup_harass_squad(float(battle.game_time))

	var threat: int = 0
	if _defense != null:
		threat = int(_defense.threat_level)

	# 敌人已经压到基地：立即转防守并召回守军，暂停所有进攻战术
	if threat >= 2:
		_harass_until = -999.0
		_cleanup_harass_squad(float(battle.game_time))
		if current_tactic != LateTactic.DEFEND:
			start_defense()
			current_tactic = LateTactic.DEFEND
			last_tactic_time = now
		return

	# 防守姿态：只有 threat>=2（真正压上基地）才继续锁死；警戒级由守军处理，
	# 兵力成型且未被明显压制时恢复进攻，不能永远缩在城里
	if current_tactic == LateTactic.DEFEND:
		# 只有威胁重新升到“真正压上基地”才继续锁死；警戒级可由守军处理，主力恢复进攻
		if threat >= 2:
			return
		if my_mil >= 12 and player_mil <= my_mil * 1.35:
			current_tactic = LateTactic.NONE
			last_tactic_time = now
		return

	if player_mil > my_mil * 1.5:
		return

	if now - last_tactic_time < TACTIC_COOLDOWN and current_tactic != LateTactic.NONE: return

	if my_mil > player_mil * 1.1 and my_mil > 10:
		current_tactic = LateTactic.OVERWHELM
		execute_overwhelm()
	elif my_mil >= 4:
		if randf() < 0.65:
			current_tactic = LateTactic.HARASS
			execute_harass()
		elif my_mil >= 10:
			current_tactic = LateTactic.RAID
			execute_raid()
		else:
			current_tactic = LateTactic.HARASS
			execute_harass()
	last_tactic_time = now

# 骚扰改为 2-3 个高机动单位的小队，优先打外围农民/商队，不再把全军拉去拆仓库。
func execute_harass():
	_harass_until = -999.0
	_cleanup_harass_squad(float(battle.game_time))
	var my_castle = get_peer_castle(my_peer_id)
	var enemy_castle = _get_attack_target_castle()
	var target = _find_harass_target(my_castle, enemy_castle)
	if target == null:
		current_tactic = LateTactic.NONE
		return
	var squad: Array = _pick_harass_squad(my_castle)
	if squad.is_empty():
		current_tactic = LateTactic.NONE
		return
	for u in squad:
		if not is_instance_valid(u) or u.health <= 0:
			continue
		u.set_meta("ai_harass", true)
		u.attack_move_to(target.global_position)
		_harass_ids[u.get_instance_id()] = true
	_harass_until = battle.game_time + 32.0

func _find_harass_target(my_castle, enemy_castle):
	var best = null
	var best_score = -INF
	for e in battle.entities.get_children():
		if not (e is Army) or e.health <= 0:
			continue
		if not _entity_is_enemy(e):
			continue
		if int(e.entity_id) not in [10, 5, 6, 43, 44, 45, 51, 14]:
			continue
		if e.water_capable:
			continue
		if enemy_castle and is_instance_valid(enemy_castle):
			if e.global_position.distance_to(enemy_castle.global_position) < 12.0:
				continue
		var d_us: float = my_castle.global_position.distance_to(e.global_position) if my_castle else 999.0
		if d_us > 95.0:
			continue
		var d_enemy: float = e.global_position.distance_to(enemy_castle.global_position) if enemy_castle else 30.0
		var score: float = minf(d_enemy, 60.0) * 0.6 - d_us * 0.02
		if int(e.entity_id) == 10:
			score += 2.0
		if score > best_score:
			best_score = score
			best = e
	if best != null:
		return best
	# 没有外围经济单位时，退而拆远离敌主城的仓库/船坞
	for e in battle.entities.get_children():
		if not (e is Building) or e.health <= 0 or not _entity_is_enemy(e):
			continue
		if int(e.entity_id) not in [22, 23]:
			continue
		if enemy_castle and e.global_position.distance_to(enemy_castle.global_position) < 15.0:
			continue
		if my_castle and e.global_position.distance_to(my_castle.global_position) > 95.0:
			continue
		return e
	return null

func _pick_harass_squad(my_castle) -> Array:
	var candidates: Array = []
	for e in battle.entities.get_children():
		if not (e is Army) or e.health <= 0 or not entity_belongs_to_me(e):
			continue
		if int(e.target_type) <= 0 or e.water_capable:
			continue
		var sgb = e.get("_soldier_garrison_building")
		if sgb != null and sgb.get_ref() != null:
			continue
		if e.has_meta("ai_home_guard") or e.has_meta("ai_resource_guard") or e.has_meta("ai_transporting") or e.has_meta("ai_escorting") or e.has_meta("ai_wall_guard"):
			continue
		if e.garrison_point != Vector3.ZERO:
			continue
		if _is_local_defense_active(e):
			continue
		var boarded = e.get("_boarded_on")
		if boarded != null and int(boarded) != -1:
			continue
		if int(e.entity_id) in [16, 17, 18, 40, 58, 59]:
			continue
		if float(e.speed) < 1.7:
			continue
		var d: float = e.global_position.distance_to(my_castle.global_position) if my_castle else 0.0
		candidates.append({"u": e, "d": d})
	candidates.sort_custom(func(a, b): return float(a["d"]) < float(b["d"]))
	var out: Array = []
	for item in candidates:
		if out.size() >= 3:
			break
		out.append(item["u"])
	return out

func _cleanup_harass_squad(now: float) -> void:
	if now < _harass_until and _harass_ids.size() > 0:
		return
	for uid in _harass_ids.keys():
		var u = instance_from_id(int(uid))
		if u != null and is_instance_valid(u) and u.has_meta("ai_harass"):
			u.remove_meta("ai_harass")
	_harass_ids.clear()

func execute_overwhelm():
	var enemy_castle = _get_attack_target_castle()
	if not enemy_castle:
		current_tactic = LateTactic.NONE
		return
	# 不再为了主攻解除已有驻扎点的部队；常驻守军/玩家驻扎部队留在原地
	var rally = enemy_castle.global_position + Vector3(0, 0, 5)
	#if wall_positions.size() > 0: rally = wall_positions[wall_positions.size()/2] + Vector3(0, 0, 2)
	var self_castle = get_peer_castle(my_peer_id)
	if not self_castle:
		current_tactic = LateTactic.NONE
		return
	# 第一波：召集全军到敌方集结点（取消距离限制，确保全军参与）
	for entity in battle.entities.get_children():
		if entity is Army and entity_belongs_to_me(entity) and entity.health > 0:
			if int(entity.entity_id) in [5,6,10,14,43,44,45,46,47,48,49,50,51]: continue
			if entity.has_meta("ai_home_guard") or entity.has_meta("ai_resource_guard") or entity.has_meta("ai_harass") or entity.has_meta("ai_wall_guard"): continue
			if _is_held_by_garrison(entity): continue
			entity.attack_move_to(rally)
	# 等待部队集结
	await get_tree().create_timer(10.0).timeout
	if _defense != null and int(_defense.threat_level) >= 2:
		return
	# 第二波：全军压上敌方城堡
	for entity in battle.entities.get_children():
		if entity is Army and entity_belongs_to_me(entity) and entity.health > 0:
			if int(entity.entity_id) in [5,6,10,14,43,44,45,46,47,48,49,50,51]: continue
			if entity.has_meta("ai_home_guard") or entity.has_meta("ai_resource_guard") or entity.has_meta("ai_harass") or entity.has_meta("ai_wall_guard"): continue
			if _is_held_by_garrison(entity): continue
			if not enemy_castle or not is_instance_valid(enemy_castle): continue
			entity.attack_move_to(enemy_castle.global_position)

func execute_raid():
	var self_castle = get_peer_castle(my_peer_id)
	if not self_castle or self_castle.level < 3:
		current_tactic = LateTactic.NONE
		return
	var enemy_castle = _get_attack_target_castle()
	if not enemy_castle or not is_instance_valid(enemy_castle):
		current_tactic = LateTactic.NONE
		return
	var enemy_team: int = int(enemy_castle.team)
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
		if e is Army and e.team == my_team and e.health > 0 and (int(e.entity_id) not in [5,6,9,10,14,43,44,45,46,47,48,49,50,51]) and entity_belongs_to_me(e):
			if e.has_meta("ai_home_guard") or e.has_meta("ai_resource_guard") or e.has_meta("ai_harass") or e.has_meta("ai_wall_guard"):
				continue
			if _is_held_by_garrison(e):
				continue
			raid_army.append(e)
	if raid_army.is_empty(): return
	if raid_army.size() > 10:
		raid_army = raid_army.slice(0, 10)
	var half = raid_army.size() / 2
	for i in range(half):
		if is_instance_valid(raid_army[i]): raid_army[i].move_to(waypoint)
	await get_tree().create_timer(1.8).timeout
	if _defense != null and int(_defense.threat_level) >= 2:
		return
	for i in range(half, raid_army.size()):
		if is_instance_valid(raid_army[i]): raid_army[i].move_to(waypoint)
	await get_tree().create_timer(RAID_WAIT_TIME)
	if _defense != null and int(_defense.threat_level) >= 2:
		return
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
func _is_defending() -> bool:
	if current_tactic == LateTactic.DEFEND:
		return true
	return _defense != null and int(_defense.threat_level) >= 2

func start_defense():
	current_tactic = LateTactic.DEFEND
	# 防御建筑、威胁方向、守军数量统一交给 AIDefense 处理。
	if _defense != null:
		_defense.start_defense()

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
				if wp.distance_to(op) < SHIPYARD_OIL_REACH: reach_oil = true; break
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
		# 渡水模块专门建在登陆岸边的船坞不能因为附近没油田被拆掉
		if sy.has_meta("ai_transport_shipyard"):
			continue
		var has_oil = false
		for res in battle.entities.get_children():
			if res is WorldResource and res.resource_type == "oil" and res.health > 0 and sy.global_position.distance_to(res.global_position) < SHIPYARD_OIL_REACH: has_oil = true; break
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
				if res is WorldResource and res.resource_type == "oil" and res.health > 0 and tp.distance_to(res.global_position) < SHIPYARD_OIL_REACH: return tp
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
	# 重装武器厂/城堡4级是59的前置科技，优先于普通建筑升级
	if _ensure_heavy_siege_tech():
		return
	if _trebuchet_reserve_active():
		return
	for b_id in wanted_buildings:
		if _should_build_or_upgrade(b_id) and can_afford_upgrade(b_id):
			upgrade_building(b_id)
			
	for b_id in wanted_buildings:
		var target = MILITARY_PRODUCER_TARGETS.get(b_id, 1)
		if count_building(b_id) < target and can_afford_building(b_id):
			var bpos = _get_build_position(b_id)
			if bpos != Vector3.ZERO:
				build_building(b_id, bpos)
			
	_ai_expand_territory()


# 优先升级：兵营(21)升到4级，受城堡等级限制则先升城堡
func _priority_upgrade():
	if _ensure_heavy_siege_tech():
		return true
	if _trebuchet_reserve_active():
		return false
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
	if _ensure_heavy_siege_tech():
		return
	if _trebuchet_reserve_active():
		return
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
	# 59优先排产；如果已经解锁但资源不够，进入短暂攒钱模式，避免普通兵种把资源吃干
	if _try_produce_trebuchet():
		return
	if _trebuchet_reserve_active():
		return
	# 人口满时先补民居，否则 AI 会一直卡在上限，看起来像“不会造房、也不出兵”
	if not _can_train_unit():
		_process_line_3()
		if not _can_train_unit():
			return
	var priority = get_counter_priority()
	
	for u_id in priority:
		if u_id == TRADE_CART_ID and count_unit(TRADE_CART_ID) >= _count_merchants():
			continue
		if count_unit(u_id) < target_army_count and can_afford(u_id) and _can_train_unit():
			
			produce_unit(u_id); 

func _process_line_3():
	if count_building(28) < target_house_count and can_afford_building(28):
		var castle = get_peer_castle(my_peer_id)
		if castle:
			var hp2 = find_valid_build_position(castle.global_position, 28)
			if hp2 != Vector3.ZERO: build_building(28, hp2)

# 第 X 分钟至少 X 座民居，8 座封顶；提前一分钟开工，给建造时间留出余量。
func _required_house_count() -> int:
	if battle == null:
		return 0
	var minute: int = int(floor(battle.game_time / 60.0)) + HOUSE_BUILD_LEAD_MINUTES
	return mini(minute, HOUSE_TARGET_MAX)

# 民居优先于造兵/攒投石机资源；这里绕过 reserve 检查，只确认木材足够。
# 否则人口满时 AI 会先把木材花在别处，导致“到点没有 X 座民居”。
func _ensure_house_quota() -> void:
	var required: int = _required_house_count()
	if required <= 0 or count_building(28) >= required:
		return
	var cfg = EntityDatabase.get_config(28)
	if cfg.is_empty():
		return
	var cost = cfg.get("cost", {})
	var res = _get_resources()
	for k in cost:
		if int(res.get(k, 0)) < int(cost[k]):
			return
	var castle = get_peer_castle(my_peer_id)
	if castle == null:
		return
	var hp: Vector3 = find_valid_build_position(castle.global_position, 28)
	if hp != Vector3.ZERO:
		build_building(28, hp)

func _process_line_4():
	# 威胁上升 / 防守姿态时不再把主力送出去；骚扰、突袭、全军压上时仍允许补发主攻
	if _defense != null and int(_defense.threat_level) >= 2:
		return
	if current_tactic == LateTactic.DEFEND:
		return
	# 压制姿态必须持续给实际部队下主攻命令：不要求先满 12 人，也不等 120 秒，
	# 否则队列里的兵会让“压制”提前亮起，但场上实际部队一直不出门。
	if current_tactic == LateTactic.OVERWHELM:
		if not an_attack():
			return
		var overwhem_target = _get_attack_target_castle()
		if overwhem_target:
			attack_move(overwhem_target.global_position, 30)
		return
	# 发育阶段保留原来的 ASSAULT 门槛，但兵力成型且开局时间已过就先发起主攻，
	# 避免一直等到 30 人、结果因为人口/产能卡住而永远不出门
	if phase == Phase.DEVELOPMENT and battle.game_time < 120.0:
		return
	# 骚扰小队出门时主力仍可进攻；attack_move 会跳过 ai_harass 单位
	var my_key = my_peer_id if my_peer_id != -1 else my_team
	if count_military(my_key) >= 12 and an_attack():
		var target = _get_attack_target_castle()
		if target:
			attack_move(target.global_position, 30)

func _process_line_5():
	var shipyards = []
	for e in battle.entities.get_children():
		if e is Building and e.entity_id == 23 and e.health > 0 and e.build_timer <= 0 and entity_belongs_to_me(e):
			shipyards.append(e)
	if shipyards.is_empty(): return
	for sy in shipyards:
		var warships = 0; var gunboats = 0; var fishermen = 0
		for e in battle.entities.get_children():
			if e is Army and e.health > 0 and entity_belongs_to_me(e) and e.global_position.distance_to(sy.global_position) < SHIPYARD_FISHER_RADIUS:
				if e.entity_id == 13: warships += 1
				elif e.entity_id == 39: gunboats += 1
				elif e.entity_id == 14: fishermen += 1
		while warships < 2 and can_afford(13) and _can_train_unit(): produce_unit(13); warships += 1
		while gunboats < 2 and can_afford(39) and _can_train_unit(): produce_unit(39); gunboats += 1
		# 每个船坞至少保证 1 艘采集船，直接在该船坞排队，避免被别的船坞抢走产能
		# 重装武器厂科技期间油需求很大，每个船坞临时补到 2 艘采集船
		var fisher_target = 1
		if _trebuchet_pending() and not _trebuchet_unlocked() and int(_get_resources().get("oil", 0)) < 400:
			fisher_target = 2
		var has_fisher_queued: bool = false
		for pid in sy.production_queue:
			if int(pid) == 14: has_fisher_queued = true; break
		if fishermen < fisher_target and not has_fisher_queued and can_afford(14) and _can_train_unit():
			sy.try_produce(14)

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
		if entity.entity_id in [5, 6, 10, 14, 43, 44, 45, 46, 47, 48, 49, 50, 51]: continue
		if entity.water_capable: continue
		# 已集合过的单位不再重复集合
		if entity.has_meta("ai_rallied"): continue
		if entity.has_meta("ai_home_guard") or entity.has_meta("ai_resource_guard") or entity.has_meta("ai_harass") or entity.has_meta("ai_transporting") or entity.has_meta("ai_wall_guard"): continue
		if _is_held_by_garrison(entity): continue
		# 已登船单位由 AIWaterCrossing 管理，不再被集结点重新下令
		var boarded = entity.get("_boarded_on")
		if boarded != null and int(boarded) != -1: continue
		# Only rally idle units (刚生产出来的单位处于空闲状态)
		if entity.current_order != "" or entity.current_target != null: continue
		entity.set_meta("ai_rallied", true)
		entity.attack_move_to(rally_point)

# ═══ Wall Defense Deployment ═══
# 把闲置远程单位送上前线城墙。城墙未破时单位免疫伤害，且站得高射界好；
# 每个墙格只安排一个单位，移动中的单位保留 ai_wall_guard 元数据防止重复派人。
func _is_valid_wall_slot(wall) -> bool:
	return is_instance_valid(wall) and wall is Building and int(wall.entity_id) == 27 and wall.health > 0 and wall.build_timer <= 0.0

func _is_ranged_wall_candidate(e) -> bool:
	if not (e is Army) or e.health <= 0 or not entity_belongs_to_me(e):
		return false
	if e.water_capable or not bool(e.can_move):
		return false
	if float(e.attack_range) < 2.0 or int(e.target_type) <= 0:
		return false
	if int(e.entity_id) in [5, 6, 9, 10, 14, 17, 43, 44, 45, 46, 47, 48, 49, 50, 51, 55, 56, 57, 59]:
		return false
	var animal_type = e.get("_animal_type")
	if animal_type != null and str(animal_type) != "":
		return false
	var boarded = e.get("_boarded_on")
	if boarded != null and int(boarded) != -1:
		return false
	if e.has_meta("ai_wall_guard") or e.hold_position:
		return false
	if e.garrison_point != Vector3.ZERO:
		return false
	if e.current_target != null or e.current_order != "":
		return false
	var sgb = e.get("_soldier_garrison_building")
	if sgb != null and sgb.get_ref() != null:
		return false
	if e._is_unit_on_wall():
		return false
	return true

func _assign_wall_guard(unit, wall) -> void:
	unit.set_meta("ai_wall_guard", wall.get_instance_id())
	unit.hold_position = true
	# 已经在墙上就不重复下令；否则走到墙格中心，MovementController 会自动把高度抬到墙顶。
	if not unit._is_unit_on_wall():
		_order_wall_move(unit, wall)

func _order_wall_move(unit, wall) -> void:
	# 城墙刚补建/刚完成时，单位可能曾把该墙格记为不可达；不清掉的话会永远站在原地。
	if unit._movement:
		unit._movement.clear_blacklist_at(wall.global_position)
	unit.move_to(wall.global_position)

func _release_wall_guard(unit) -> void:
	if not is_instance_valid(unit):
		return
	unit.remove_meta("ai_wall_guard")
	unit.hold_position = false
	if unit.current_order == "move":
		unit.stop_movement()

func _deploy_ranged_units_to_walls() -> void:
	if battle == null:
		return
	var armies: Array = _cached_armies()
	var occupied: Dictionary = {}
	var reserved: Dictionary = {}
	for e in armies:
		if not is_instance_valid(e) or e.health <= 0:
			continue
		var boarded = e.get("_boarded_on")
		if boarded != null and int(boarded) != -1:
			continue
		var eg: Vector2i = battle.world_to_grid(e.global_position)
		var wall_here = battle._wall_entity_grid.get(eg)
		if wall_here != null and is_instance_valid(wall_here) and wall_here.health > 0:
			occupied[eg] = true
		if not e.has_meta("ai_wall_guard"):
			continue
		var wid: int = int(e.get_meta("ai_wall_guard"))
		var wall = instance_from_id(wid)
		if not _is_valid_wall_slot(wall):
			_release_wall_guard(e)
			continue
		reserved[wid] = true
		if e._is_unit_on_wall():
			# 已经站上城墙：锁定站位，避免剩余路径让它在墙顶来回走。
			e.hold_position = true
			if e.current_order == "move":
				e.stop_movement()
		elif e.current_order == "":
			# 中途被打断/寻路失败回到空闲时重新送上去；战斗中不强行拉走。
			_order_wall_move(e, wall)
	# 炮台等墙顶建筑也占用墙格，避免远程兵与炮台重叠
	for b in _cached_buildings():
		if is_instance_valid(b) and b.health > 0 and int(b.entity_id) == 64:
			occupied[battle.world_to_grid(b.global_position)] = true
	var walls: Array = []
	for b in _cached_buildings():
		if not _is_valid_wall_slot(b) or not entity_belongs_to_me(b):
			continue
		if reserved.has(b.get_instance_id()):
			continue
		if occupied.has(battle.world_to_grid(b.global_position)):
			continue
		walls.append(b)
	if walls.is_empty():
		return
	var candidates: Array = []
	for e in armies:
		if not is_instance_valid(e) or e.health <= 0:
			continue
		if not _is_ranged_wall_candidate(e):
			continue
		if occupied.has(battle.world_to_grid(e.global_position)):
			continue
		candidates.append(e)
	for wall in walls:
		if candidates.is_empty():
			break
		var best = null
		var best_d: float = WALL_DEPLOY_MAX_DISTANCE * WALL_DEPLOY_MAX_DISTANCE
		for u in candidates:
			var d: float = u.global_position.distance_squared_to(wall.global_position)
			if d < best_d:
				best_d = d
				best = u
		if best == null:
			continue
		_assign_wall_guard(best, wall)
		candidates.erase(best)

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
		if entity.entity_id == 9: continue  # 运载船由渡水模块调度，不能当成巡逻舰
		if entity.entity_id == 40: continue  # 爆破船应冲向敌舰/敌岸，不能拿去绕圈巡逻
		if entity.has_meta("ai_transporting") or entity.has_meta("ai_escorting"): continue
		if _is_held_by_garrison(entity): continue
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
	if _trait_rtl:
		_trait_rtl.text = "[color=#cba]%s[/color]" % NationBonuses.get_trait_full(_my_nation_index())
	# 收起状态：主体不可见，跳过整块内容刷新，省掉每帧的统计与遍历开销
	if _panel_collapsed: return

	# 面板统计只遍历一次实体：原实现对每种资源/单位/建筑各扫一遍全实体，
	# 7 个 AI 面板同时展开时每 10 帧会产生数百次全量扫描，是后期掉帧大户。
	var own_unit_counts: Dictionary = {}
	var own_build_counts: Dictionary = {}
	var own_build_levels: Dictionary = {}
	var gather_counts_by_res: Dictionary = {}
	var hunt_count: int = 0
	for entity in battle.entities.get_children():
		if not (entity is GameEntity) or entity.health <= 0:
			continue
		if not entity_belongs_to_me(entity):
			continue
		if entity is Army:
			var uid := int(entity.entity_id)
			own_unit_counts[uid] = int(own_unit_counts.get(uid, 0)) + 1
			if entity.entity_id in [10, 14] and entity.current_order in ["gather", "deliver"]:
				var gather_target = entity.current_target
				if is_instance_valid(gather_target) and gather_target is WorldResource:
					gather_counts_by_res[gather_target.resource_type] = int(gather_counts_by_res.get(gather_target.resource_type, 0)) + 1
			if _hunt_target and is_instance_valid(_hunt_target) and entity.current_target == _hunt_target:
				hunt_count += 1
		elif entity is Building and entity.build_timer <= 0:
			var bid := int(entity.entity_id)
			own_build_counts[bid] = int(own_build_counts.get(bid, 0)) + 1
			own_build_levels[bid] = maxi(int(own_build_levels.get(bid, 1)), int(entity.upgrade_level))

	var res = _get_resources(); var pop = _get_population()
	var _pe = {"PRODUCTION": "🌱", "DEVELOPMENT": "🏗️", "ASSAULT": "⚔️"}
	_header_rtl.text = "%s [color=#%s]%s[/color]  |  %s" % [_pe.get(Phase.keys()[phase], "▶️"), (Color.GREEN if phase == Phase.ASSAULT else (Color(1,0.7,0) if phase == Phase.DEVELOPMENT else Color.CYAN)).to_html(), Phase.keys()[phase], _get_tactic_name(current_tactic)]
	if _defense != null:
		_header_rtl.text += "\n[color=#9fd3ff]🛡 %s[/color]" % _defense.get_status_text()
	var pop_pct = float(pop.current) / max(pop.max, 1)
	_pop_bar.value = pop_pct * 100
	var pfs = _pop_bar.get_theme_stylebox("fill")
	if pfs: pfs.bg_color = Color.GREEN if pop_pct < 0.8 else Color(1,0.5,0)
	_pop_label.text = "👥 人口 %d/%d" % [pop.current, pop.max]
	# 主城血量
	var castle = get_peer_castle(my_peer_id) if my_peer_id != -1 else get_team_castle(my_team)
	if _castle_bar and _castle_label:
		if castle and is_instance_valid(castle):
			_castle_bar.visible = true
			_castle_bar.update_bar(castle.health, castle.max_health, -1, battle.get_entity_color(castle))
			_castle_label.text = "🏰 主城 Lv.%d %d/%d" % [castle.upgrade_level, int(castle.health), int(castle.max_health)]
		else:
			_castle_bar.visible = false
			_castle_label.text = "🏰 主城 已失守"
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
		var gc = int(gather_counts_by_res.get(r.k, 0))
		_res_labels[i].text += " %d人" % gc
		_res_labels[i].text += " %+.1f/s" % _ai_income_rate[r.k]
		var s = _res_bars[i].get_theme_stylebox("fill")
		if s: s.bg_color = r.c
	var eco_units = [[10,"农"],[14,"采船"],[5,"推车"],[6,"贸车"],[9,"运载"],
		[43,"油商"],[44,"木商"],[45,"石商"],[51,"食商"],[46,"县吏"],[47,"上校"],[48,"尚书"],[49,"统帅"],[50,"丞相"]]
	var eco_lines = []
	var eco_total = 0
	for u in eco_units:
		var cnt = int(own_unit_counts.get(u[0], 0))
		eco_total += cnt
		if cnt > 0: eco_lines.append("[color=#8c8]%s%s[/color]:[color=white]%d[/color]" % [UITheme.entity_emoji(u[0], 2), u[1], cnt])
	_eco_rtl.text = "[color=gray](无经济单位)[/color]" if eco_lines.is_empty() else " ".join(eco_lines)
	if _eco_title: _eco_title.text = "[color=#5af]▸ 💰 经济 %d[/color]" % eco_total

	var mil_units = [[11,"步"],[12,"弓"],[13,"战船"],[15,"骑"],[16,"炮"],[17,"投石"],[18,"攻城"],[19,"侦察"],
		[30,"狂战"],[31,"长弓"],[32,"法骑"],[33,"诸弩"],[34,"象骑"],[35,"长枪"],[36,"重步"],[37,"重弓"],[38,"重骑"],[39,"炮艇"],[40,"爆破"],
		[58,"连弩"],[59,"巨投"],[55,"僧侣"],[56,"长老"],[57,"宗师"],[65,"武士"],[66,"甲骑"]]
	var mil_lines = []
	var mil_total = 0
	for u in mil_units:
		var cnt = int(own_unit_counts.get(u[0], 0))
		mil_total += cnt
		if cnt > 0: mil_lines.append("[color=#aaa]%s%s[/color]:[color=white]%d[/color]" % [UITheme.entity_emoji(u[0], 2), u[1], cnt])
	_mil_rtl.text = "[color=gray](无军队)[/color]" if mil_lines.is_empty() else " ".join(mil_lines)
	if _mil_title: _mil_title.text = "[color=#5af]▸ ⚔️ 军队 %d[/color]" % mil_total
	var all_blds = [[20,"城"],[21,"营"],[22,"仓"],[23,"坞"],[24,"攻城车"],[25,"箭塔"],[26,"炮塔"],[27,"墙"],[28,"民"],[29,"重工"],[41,"瞭望"],[42,"书院"],[52,"集市"],[53,"城堡"],[64,"炮台"],[7,"桥"],[8,"梯子"],[54,"修道"]]
	var bld_lines = []
	var bld_total = 0
	for b in all_blds:
		var cnt = int(own_build_counts.get(b[0], 0))
		var max_lv = int(own_build_levels.get(b[0], 1))
		bld_total += cnt
		if cnt > 0: bld_lines.append("[color=#888]%s【%d】%s[/color]:[color=white]%d[/color]" % [UITheme.entity_emoji(b[0], 1), max_lv, b[1], cnt])
	_bld_rtl.text = "[color=gray](无建筑)[/color]" if bld_lines.is_empty() else " ".join(bld_lines)
	if _bld_title: _bld_title.text = "[color=#5af]▸ 🏰 建筑 %d[/color]" % bld_total
	var hunt_info = "[color=#ffa]🏹 狩猎: %.0fs[/color]" % max(0, _hunt_timer)
	if _hunt_target and is_instance_valid(_hunt_target):
		hunt_info += " [color=#f88]目标:%s 猎人:%d/5[/color]" % [_hunt_target.get("_animal_type"), hunt_count]
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
func _my_nation_index() -> int:
	if not battle:
		return -1
	if battle is OnlineBattleManager:
		return int(battle.player_info.get(my_peer_id, {}).get("nation", -1))
	elif my_peer_id != -1 and battle.ai_players.has(my_peer_id):
		return int(battle.ai_players[my_peer_id].get("nation", -1))
	return int(GameSettings.enemy_nation)

func _my_nation_tag() -> String:
	if not battle or not battle.has_method("get_nation_name"):
		return ""
	var nat := _my_nation_index()
	if nat >= 0:
		return " [color=#ffd34f]「%s」[/color]" % battle.get_nation_name(nat)
	return ""
var _pop_bar: ProgressBar; var _pop_label: Label
var _res_bars: Array = []; var _res_labels: Array = []
var _mil_rtl: RichTextLabel; var _bld_rtl: RichTextLabel
var _trait_rtl: RichTextLabel
var _castle_bar: HealthBarControl
var _castle_label: Label
var _eco_title: RichTextLabel
var _eco_rtl: RichTextLabel
var _mil_title: RichTextLabel
var _bld_title: RichTextLabel
var _title_rtl: RichTextLabel = null       # 面板标题（用于追加国家名）
var _panel_title_base: String = ""         # 不含国家名的原始标题
var _collapse_btn: Button = null           # 标题栏右侧的隐藏/展开按钮
var _body_vb: VBoxContainer = null         # 面板主体（隐藏时整块不可见）
var _body_scroll: ScrollContainer = null   # 内容滚动区，避免建筑统计被面板高度截断
var _panel_collapsed: bool = false         # 面板是否已收起为标题条
var _panel_bg_style: StyleBoxFlat = null   # 面板底板样式（按友方/敌方着色）
var _last_relation: int = -2               # 上次计算的敌我关系，避免每帧重设样式
const PANEL_WIDTH: float = 540.0
const PANEL_HEIGHT: float = 400.0
const PANEL_COLLAPSED_HEIGHT: float = 44.0

# 当前面板实际高度（折叠后只保留标题条），供统一布局函数计算下方面板位置
func get_panel_height() -> float:
	return PANEL_COLLAPSED_HEIGHT if _panel_collapsed else PANEL_HEIGHT

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
	# 固定内容宽度：折叠后主体隐藏时 VBox 不能收缩，否则右对齐的折叠按钮会跳到标题旁边
	vb.custom_minimum_size = Vector2(PANEL_WIDTH - 20.0, PANEL_HEIGHT - 16.0)
	vb.size = Vector2(PANEL_WIDTH - 20.0, PANEL_HEIGHT - 16.0)
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
	# 面板主体：放进滚动区，内容超出面板高度时可滚动查看
	_body_scroll = ScrollContainer.new()
	_body_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_body_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_body_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body_scroll.custom_minimum_size = Vector2(PANEL_WIDTH - 20.0, PANEL_HEIGHT - 52.0)
	vb.add_child(_body_scroll)
	var body = VBoxContainer.new(); body.add_theme_constant_override("separation", 3)
	body.custom_minimum_size = Vector2(PANEL_WIDTH - 44.0, 0)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body_scroll.add_child(body); _body_vb = body
	_header_rtl = _make_rtl(); _header_rtl.add_theme_font_size_override("font_size", 19); body.add_child(_header_rtl)
	# 国家特色
	_trait_rtl = _make_rtl(); _trait_rtl.add_theme_font_size_override("font_size", 13); body.add_child(_trait_rtl)
	# 主城血量
	var castle_hbox = HBoxContainer.new()
	_castle_label = Label.new(); _castle_label.add_theme_font_size_override("font_size", 14)
	_castle_label.add_theme_color_override("font_color", Color(UITheme.PARCHMENT))
	castle_hbox.add_child(_castle_label)
	_castle_bar = HealthBarControl.new(); _castle_bar.custom_minimum_size = Vector2(300, 10)
	castle_hbox.add_child(_castle_bar)
	body.add_child(castle_hbox)
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
	# 经济
	_eco_title = _make_section("💰 经济"); body.add_child(_eco_title); _eco_rtl = _make_rtl(); body.add_child(_eco_rtl)
	# 军队
	_mil_title = _make_section("⚔️ 军队"); body.add_child(_mil_title); _mil_rtl = _make_rtl(); body.add_child(_mil_rtl)
	_bld_title = _make_section("🏰 建筑"); body.add_child(_bld_title); _bld_rtl = _make_rtl(); body.add_child(_bld_rtl)
	var hud = battle.get_node("UI") as CanvasLayer; hud.add_child(debug_panel)
	# 默认折叠为标题条
	set_panel_collapsed(true, false)
	debug_panel.set_meta("expanded_at", 0)
	# 创建后交给管理器统一排布，避免多个面板叠放
	if battle.has_method("layout_ai_debug_panels"):
		battle.call_deferred("layout_ai_debug_panels")
	if not OS.is_debug_build():
		debug_panel.visible = false

# ▼/▲：隐藏或展开面板主体；管理器可在超限时直接调用（relayout=false）
func _on_collapse_pressed():
	set_panel_collapsed(_collapse_btn.button_pressed, true)

func set_panel_collapsed(collapsed: bool, relayout: bool = true):
	if _collapse_btn == null or _body_vb == null or debug_panel == null:
		return
	_panel_collapsed = collapsed
	_collapse_btn.button_pressed = collapsed
	if _body_scroll:
		_body_scroll.visible = not collapsed
	else:
		_body_vb.visible = not collapsed
	_collapse_btn.text = "▲" if collapsed else "▼"
	_collapse_btn.tooltip_text = "展开 AI 决策面板" if collapsed else "隐藏 AI 决策面板"
	var h = PANEL_COLLAPSED_HEIGHT if collapsed else PANEL_HEIGHT
	debug_panel.custom_minimum_size = Vector2(PANEL_WIDTH, h)
	debug_panel.size = Vector2(PANEL_WIDTH, h)
	if not collapsed:
		debug_panel.set_meta("expanded_at", Time.get_ticks_msec())
	if relayout and battle and is_instance_valid(battle) and battle.has_method("layout_ai_debug_panels"):
		battle.layout_ai_debug_panels()

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

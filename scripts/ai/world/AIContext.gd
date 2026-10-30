extends RefCounted

# A1：只读世界上下文（AIContext）。
#
# 目标（见 docs/AI架构总设计.md §3、§7.1）：执行层模块（L2）不再持有 AIController，
# 只拿这一个只读门面做判断。这样模块可以脱离 BattleManager 单测，也不会悄悄改状态。
#
# A1 阶段的做法：先做"转发式"实现——内部仍指向 AI 控制器与当轮快照，
# 模块逐个切过来（A2 起），确认行为不变后再收紧（去掉对 ai 的持有）。
# 任何写操作（建造/生产/claim）都不在这个类里，留到 A3 的 Port。

var _ai = null
var _situation = null
var _ledger = null
var _round: int = 0
var _bound_t: float = -1.0

func bind(ai, situation, ledger, round_no: int) -> void:
	_ai = ai
	_situation = situation
	_ledger = ledger
	_round = round_no
	_bound_t = float(ai.battle.game_time) if ai != null and ai.battle != null else 0.0

func is_bound() -> bool:
	return _ai != null

func round_no() -> int:
	return _round

# ── 身份 ──
func my_peer_id() -> int:
	return int(_ai.my_peer_id) if _ai != null else -1

func my_team() -> int:
	return int(_ai.my_team) if _ai != null else -1

func phase() -> int:
	return int(_ai.phase) if _ai != null else 0

# ── 经济（只读副本语义：调用方不应缓存）──
func resources() -> Dictionary:
	return _ai._get_resources() if _ai != null else {}

func limits() -> Dictionary:
	return _ai._get_limits() if _ai != null else {}

func can_afford(id: int) -> bool:
	return _ai.can_afford(id) if _ai != null else false

func can_afford_building(id: int) -> bool:
	return _ai.can_afford_building(id) if _ai != null else false

func can_afford_upgrade(id: int) -> bool:
	return _ai.can_afford_upgrade(id) if _ai != null else false

# ── 归属与敌我 ──
func belongs_to_me(e) -> bool:
	return _ai.entity_belongs_to_me(e) if _ai != null else false

func is_enemy(e) -> bool:
	return _ai._entity_is_enemy(e) if _ai != null else false

func is_defending() -> bool:
	return _ai._is_defending() if _ai != null else false

func primary_enemy_team() -> int:
	return int(_ai._primary_enemy_team()) if _ai != null else -1

# ── 建筑 ──
func castle():
	return _ai.get_peer_castle(_ai.my_peer_id) if _ai != null else null

func enemy_castle():
	return _ai.get_team_castle(_ai._primary_enemy_team()) if _ai != null else null

func count_building(building_id: int) -> int:
	return int(_ai.count_building(building_id)) if _ai != null else 0

func count_unit(unit_id: int, include_queue: bool = true) -> int:
	return int(_ai.count_unit(unit_id, include_queue)) if _ai != null else 0

# ── 敌情（优先当轮快照；快照为空时回落到实时缓存，A2 之后再收紧）──
func visible_enemies() -> Array:
	if _situation != null and not _situation.visible_enemies.is_empty():
		return _situation.visible_enemies
	return _ai._visible_enemies if _ai != null else []

func enemy_army_within(pos: Vector3, radius: float) -> bool:
	return _ai._enemy_army_within(pos, radius) if _ai != null else false

func is_ranged_wall_candidate(unit) -> bool:
	return _ai._is_ranged_wall_candidate(unit) if _ai != null else false

# ── 只读账本视图 ──
func ledger_holders(kind: int) -> Array:
	return _ledger.holders(kind) if _ledger != null else []

func ledger_count(kind: int) -> int:
	return int(_ledger.count(kind)) if _ledger != null else 0

func debug_snapshot() -> Dictionary:
	return {
		"round": _round,
		"bound_t": _bound_t,
		"peer": my_peer_id(),
		"team": my_team(),
		"phase": phase(),
		"castles": count_building(20),
		"ledger_director": _ledger.size_of("director") if _ledger != null else -1,
	}

func team_castle_of(team: int):
	return _ai.get_team_castle(team) if _ai != null else null

func defense_threat_level() -> int:
	return int(_ai._defense.threat_level) if _ai != null and _ai._defense != null else 0

# ── 地图与时间（只读查询，L2 不再直接摸 battle）──
func game_time() -> float:
	return float(_ai.battle.game_time) if _ai != null and _ai.battle != null else 0.0

func world_to_grid(pos):
	return _ai.battle.world_to_grid(pos) if _ai != null else Vector2i.ZERO

func grid_to_world(gx: int, gy: int):
	return _ai.battle.grid_to_world(gx, gy) if _ai != null else Vector3.ZERO

func terrain_at_grid(gx: int, gy: int) -> int:
	return int(_ai.battle.get_terrain_at_grid(gx, gy)) if _ai != null else -1

func overlay_at_grid(gx: int, gy: int) -> int:
	return int(_ai.battle.get_overlay_at_grid(gx, gy)) if _ai != null else -1

func is_cliff_tile(gx: int, gy: int) -> bool:
	return bool(_ai.battle.is_cliff_tile(gx, gy)) if _ai != null else false

func is_valid_bridge_position(pos) -> bool:
	return bool(_ai.battle.is_valid_bridge_position(pos)) if _ai != null else false

func nearby_entities(pos, radius: float) -> Array:
	return _ai.battle.get_nearby_entities(pos, radius) if _ai != null else []

func nearby_enemies(pos, radius: float, team: int, owner: int = -1, only_visible: bool = false) -> Array:
	return _ai.battle.get_nearby_enemies(pos, radius, team, owner, only_visible) if _ai != null else []

func is_research_mode() -> bool:
	return bool(_ai.battle.is_research_mode()) if _ai != null and _ai.battle.has_method("is_research_mode") else false

# ── 缓存视图（只读；调用方不得修改返回数组内容）──
func cached_buildings() -> Array:
	return _ai._cached_buildings() if _ai != null else []

func cached_armies() -> Array:
	return _ai._cached_armies() if _ai != null else []

func can_train_unit() -> bool:
	return bool(_ai._can_train_unit()) if _ai != null else false

func can_train_unit_with_queue() -> bool:
	return bool(_ai._can_train_unit_with_queue()) if _ai != null else false

func phase_weights() -> Dictionary:
	return _ai._get_phase_weights() if _ai != null else {}

# ── 策略查询（只读，转发给控制器；A6 之后改为由 Director 提供）──
func food_emergency() -> bool:
	return bool(_ai._food_emergency()) if _ai != null else false

func all_gather_resources_full() -> bool:
	return bool(_ai._all_gather_resources_full()) if _ai != null else false

func worker_is_fleeing(w) -> bool:
	return bool(_ai._worker_is_fleeing(w)) if _ai != null else false

func resource_ratio(kind) -> float:
	return float(_ai._resource_ratio(kind)) if _ai != null else 0.0

func pressure_threshold() -> float:
	return float(_ai._pressure_threshold()) if _ai != null else 0.0

func worker_resource_weights() -> Dictionary:
	return _ai._worker_resource_weights() if _ai != null else {}

func find_best_resource_for_worker(w, weights = null) -> Variant:
	if _ai == null:
		return null
	if weights == null:
		return _ai.find_best_resource_for_worker(w)
	return _ai.find_best_resource_for_worker(w, weights)

func attack_target_castle():
	return _ai._get_attack_target_castle() if _ai != null else null

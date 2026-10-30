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

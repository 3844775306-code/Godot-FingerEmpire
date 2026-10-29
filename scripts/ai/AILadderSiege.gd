class_name AILadderSiege
extends RefCounted

# AI 梯子攻城模块：
# 1) 主攻目标外围有敌方城墙时，选一段外侧裸露墙，派农民贴墙造梯子；
# 2) 梯子完工后，把卡在墙脚拆墙的野战部队改成 attack_move 穿过梯子；
# 3) 梯子被拆、墙先破、农民被打断时自动回退，不阻塞原来的拆墙/进攻逻辑。
# 本模块只做“选梯位、造梯子、下令改道”，不修改 Army/Building 的核心状态。

const LADDER_ID := 8
const PHASE_DEVELOPMENT := 1
const PHASE_ASSAULT := 2
const TACTIC_DEFEND := 4
const MIN_GAME_TIME := 120.0
const MIN_FIELD_UNITS := 8
const MAX_LADDERS := 2
const PLAN_INTERVAL := 2.0
const WALL_SEARCH_RADIUS := 30.0
const BREACH_RADIUS := 26.0
const BREACH_REISSUE_MS := 7000
const RETRY_COOLDOWN_MS := 10000
const MAX_ATTEMPTS := 8
const MAX_WALL_CANDIDATES := 8

var ai = null
var battle = null
var _plan_timer: float = 0.0
var _retry_at_ms: int = 0
var _attempts: int = 0
var _active_ladder: Building = null
var _active_wall: Building = null
var _breach_sent_ms: int = 0

func _init(ai_controller) -> void:
	ai = ai_controller
	battle = ai.battle if ai != null else null

func tick(delta: float) -> void:
	if ai == null or battle == null or not is_instance_valid(ai):
		return
	if battle.has_method("_ensure_cache_fresh"):
		battle._ensure_cache_fresh()
	if _active_ladder != null and not is_instance_valid(_active_ladder):
		_clear_active()
	if _active_ladder != null:
		_tick_active()
		return
	_plan_timer -= delta
	if _plan_timer > 0.0:
		return
	_plan_timer = PLAN_INTERVAL
	_try_start()

func _tick_active() -> void:
	if not is_instance_valid(_active_ladder) or _active_ladder.health <= 0 \
			or int(_active_ladder.entity_id) != LADDER_ID:
		_clear_active()
		_retry_at_ms = Time.get_ticks_msec() + RETRY_COOLDOWN_MS
		return
	if _active_ladder.build_timer > 0.0:
		# 农民中途死亡时梯子会停在“等待建造者”状态，补派一个空闲农民。
		if _active_ladder.awaiting_builder and battle.has_method("find_nearest_idle_builder"):
			var builder = battle.find_nearest_idle_builder(
				ai.my_team, ai.my_peer_id, _active_ladder.global_position, 70.0
			)
			if builder != null and battle.has_method("assign_builders"):
				battle.assign_builders(_active_ladder, [builder.get_instance_id()])
		return
	if _active_wall == null or not is_instance_valid(_active_wall) or _active_wall.health <= 0:
		# 墙已经被普通拆墙部队打掉，梯子不再有价值，直接收掉计划。
		_clear_active()
		return
	var now := Time.get_ticks_msec()
	if now - _breach_sent_ms < BREACH_REISSUE_MS:
		return
	_breach_sent_ms = now
	_send_breach()

func _try_start() -> void:
	if not _can_try():
		return
	var castle = ai._get_attack_target_castle()
	if castle == null or not is_instance_valid(castle) or castle.health <= 0:
		return
	var army_pos = _main_army_position(castle)
	if army_pos == Vector3.ZERO:
		return
	if _field_unit_count() < MIN_FIELD_UNITS:
		return
	if not ai.can_afford_building(LADDER_ID):
		return
	if ai.count_building(LADDER_ID) >= MAX_LADDERS:
		return
	var walls := _wall_candidates(castle, army_pos)
	for item in walls:
		var wall: Building = item["wall"]
		if wall == null or not is_instance_valid(wall) or wall.health <= 0:
			continue
		var spot := _best_ladder_spot(wall, castle, army_pos)
		if spot == Vector3.ZERO:
			continue
		if ai.build_ladder(spot):
			_active_wall = wall
			_active_ladder = _find_ladder_near(spot)
			_breach_sent_ms = 0
			_attempts += 1
			return
	_attempts += 1
	_retry_at_ms = Time.get_ticks_msec() + RETRY_COOLDOWN_MS

func _can_try() -> bool:
	var phase_id: int = int(ai.phase)
	if phase_id != PHASE_DEVELOPMENT and phase_id != PHASE_ASSAULT:
		return false
	if battle.game_time < MIN_GAME_TIME:
		return false
	if ai.has_method("_is_defending") and ai._is_defending():
		return false
	if int(ai.current_tactic) == TACTIC_DEFEND:
		return false
	if battle.has_method("is_training_building_allowed") \
			and not battle.is_training_building_allowed(LADDER_ID):
		return false
	var now := Time.get_ticks_msec()
	if now < _retry_at_ms:
		return false
	if _attempts >= MAX_ATTEMPTS:
		# 连续失败后放长冷却，避免 AI 每 2 秒就把木材/农民往墙下送。
		_retry_at_ms = now + RETRY_COOLDOWN_MS * 3
		_attempts = 0
		return false
	return true

func _clear_active() -> void:
	_active_ladder = null
	_active_wall = null
	_breach_sent_ms = 0
	_plan_timer = 0.0

func _field_unit_count() -> int:
	var key: int = ai.my_peer_id if ai.my_peer_id != -1 else ai.my_team
	return ai.count_field_military(key)

func _main_army_position(castle: Building) -> Vector3:
	var best := Vector3.ZERO
	var best_d := INF
	for e in battle._armies:
		if not is_instance_valid(e) or e.health <= 0:
			continue
		if not ai.entity_belongs_to_me(e):
			continue
		if int(e.target_type) <= 0 or e.water_capable:
			continue
		if int(e.entity_id) in [10, 14, 43, 44, 45, 46, 47, 48, 49, 50, 51]:
			continue
		if e.has_meta("ai_wall_guard") or e.has_meta("ai_harass") or e.has_meta("ai_home_guard"):
			continue
		if e.has_meta("ai_transporting"):
			continue
		var d: float = e.global_position.distance_squared_to(castle.global_position)
		if d < best_d:
			best_d = d
			best = e.global_position
	return best

func _wall_candidates(castle: Building, army_pos: Vector3) -> Array:
	var out: Array = []
	for e in battle._buildings:
		if not is_instance_valid(e) or not (e is Building) or e.health <= 0:
			continue
		if int(e.entity_id) != 27 or e.build_timer > 0.0:
			continue
		if not ai._entity_is_enemy(e):
			continue
		var to_castle: float = e.global_position.distance_to(castle.global_position)
		if to_castle > WALL_SEARCH_RADIUS:
			continue
		var to_army: float = e.global_position.distance_to(army_pos)
		var score: float = -to_army * 1.2 - absf(to_castle - 12.0) * 0.8
		# 墙顶炮台会直接压制梯子，尽量换一段没有炮的墙。
		score -= float(_wall_cannon_count(e)) * 6.0
		out.append({"wall": e, "score": score})
	out.sort_custom(func(a, b): return float(a["score"]) > float(b["score"]))
	if out.size() > MAX_WALL_CANDIDATES:
		out.resize(MAX_WALL_CANDIDATES)
	return out

func _wall_cannon_count(wall: Building) -> int:
	var count := 0
	for e in battle._buildings:
		if not is_instance_valid(e) or not (e is Building) or e.health <= 0:
			continue
		if int(e.entity_id) != 64:
			continue
		if int(e.team) == int(ai.my_team):
			continue
		if e.global_position.distance_to(wall.global_position) <= 4.0:
			count += 1
	return count

func _best_ladder_spot(wall: Building, castle: Building, army_pos: Vector3) -> Vector3:
	var g: Vector2i = battle.world_to_grid(wall.global_position)
	var half := RTSConfig.MAP_SIZE / 2.0
	var outward := wall.global_position - castle.global_position
	outward.y = 0.0
	var outward_dir := outward.normalized() if outward.length_squared() > 0.01 else Vector3.ZERO
	var best := Vector3.ZERO
	var best_score := INF
	# 第一遍只选朝城堡外侧的墙脚，避免把梯子搭到墙内侧；
	# 找不到时再放宽到四侧，兼容直线城墙/非闭合防线。
	for require_outside in [true, false]:
		for dir in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var side := Vector3(float(dir.x), 0.0, float(dir.y))
			if require_outside and outward_dir != Vector3.ZERO and side.dot(outward_dir) < 0.15:
				continue
			var gx: int = g.x + dir.x
			var gy: int = g.y + dir.y
			if gx < 0 or gx >= RTSConfig.MAP_SIZE or gy < 0 or gy >= RTSConfig.MAP_SIZE:
				continue
			var pos := Vector3(float(gx) - half, 0.0, float(gy) - half)
			if battle.has_method("get_height_at_grid"):
				pos.y = battle.get_height_at_grid(gx, gy)
			if not battle.is_valid_ladder_position(pos, ai.my_team):
				continue
			var d: float = pos.distance_to(army_pos)
			var score: float = d - float(_wall_cannon_count(wall)) * 4.0
			if score < best_score:
				best_score = score
				best = pos
		if best != Vector3.ZERO:
			return best
	return Vector3.ZERO

func _find_ladder_near(pos: Vector3) -> Building:
	if battle.has_method("_ensure_cache_fresh"):
		battle._ensure_cache_fresh()
	for e in battle._buildings:
		if not is_instance_valid(e) or not (e is Building) or e.health <= 0:
			continue
		if int(e.entity_id) != LADDER_ID:
			continue
		if e.global_position.distance_to(pos) <= 1.5 and ai.entity_belongs_to_me(e):
			return e
	return null

func _send_breach() -> void:
	var target = ai._get_attack_target_castle()
	var target_pos: Vector3 = _active_wall.global_position if target == null else target.global_position
	if _active_ladder == null or not is_instance_valid(_active_ladder):
		return
	for e in battle._armies:
		if not is_instance_valid(e) or e.health <= 0:
			continue
		if not (e is Army) or not ai.entity_belongs_to_me(e):
			continue
		if int(e.target_type) <= 0 or e.water_capable:
			continue
		if int(e.entity_id) in [10, 14, 43, 44, 45, 46, 47, 48, 49, 50, 51]:
			continue
		if e.has_meta("ai_wall_guard") or e.has_meta("ai_harass") or e.has_meta("ai_home_guard"):
			continue
		if e.global_position.distance_to(_active_ladder.global_position) > BREACH_RADIUS:
			continue
		if e.has_method("force_attack_move_to"):
			e.force_attack_move_to(target_pos)

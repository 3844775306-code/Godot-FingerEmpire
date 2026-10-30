# scripts/ai/defense/DefenseForceAllocator.gd
# 防御架构第 4 阶段：守军分配器（影子模式）。
#
# 第 4 阶段先只计算“应该由谁守主城”，并与当前 ai_home_guard 名单做对比：
#   · 用 DefenseDirector 的姿态/敌军数量算目标守军数；
#   · 用威胁方向扇区优先选兵，而不是只按离主城最近选；
#   · 输出 KEEP / PROPOSE / RELEASE 建议，不写 meta、不调 _director_claim。
# 其他角色（城墙守军/资源守卫/建筑反击）先只统计现状，等主城守军口径确认后再接管。
extends RefCounted

enum Claim { KEEP, PROPOSE, RELEASE }

const CLAIM_NAMES: Array = ["KEEP", "PROPOSE", "RELEASE"]
# 与 AIDefense.HOME_GUARD_COUNT 同步；影子分配只读，不直接依赖实例常量访问。
const HOME_GUARD_BASE: int = 5

var context = null

var claims: Array = []
var metrics: Dictionary = {}
var updated_at: float = 0.0

func _init(context_ref) -> void:
	context = context_ref

# defense 是 AIDefense 实例，director 是已 evaluate 的 DefenseDirector。
# 返回值可直接给调试面板/日志使用。
func build_plan(castle, director, defense, _snapshot: Dictionary = {}) -> Dictionary:
	claims.clear()
	metrics = {}
	if context == null or defense == null or castle == null or not is_instance_valid(castle):
		return to_dictionary()
	var now: float = context.get_game_time()
	var own: Array = defense._land_combat_units()
	var desired: int = _desired_home_count(own.size(), director, defense, now)
	var current_home: Dictionary = {}
	var wall_count: int = 0
	var resource_count: int = 0
	var overlap_count: int = 0
	var roster: Array = []
	for u in own:
		if u == null or not is_instance_valid(u) or u.health <= 0:
			continue
		var uid: int = u.get_instance_id()
		var roles: int = 0
		if u.has_meta("ai_home_guard"):
			current_home[uid] = true
			roles += 1
		if u.has_meta("ai_wall_guard"):
			wall_count += 1
			roles += 1
		if u.has_meta("ai_resource_guard"):
			resource_count += 1
			roles += 1
		if u.has_meta("ai_building_defense_until"):
			roles += 1
		if roles > 1:
			overlap_count += 1
		roster.append({
			"uid": uid,
			"unit": u,
			"is_home": u.has_meta("ai_home_guard"),
			"blocked": _is_blocked_candidate(u, defense, now),
			"score": _candidate_score(u, castle, defense, director),
		})
	roster.sort_custom(func(a, b): return float(a["score"]) < float(b["score"]))

	var wanted: int = 0
	for entry in roster:
		if wanted >= desired:
			break
		var uid: int = int(entry["uid"])
		var unit = entry["unit"]
		if bool(entry["is_home"]):
			wanted += 1
			claims.append(_claim(uid, Claim.KEEP, "existing_home_guard", unit, castle))
			continue
		if bool(entry["blocked"]):
			continue
		wanted += 1
		claims.append(_claim(uid, Claim.PROPOSE, "sector_priority", unit, castle))
	# 超出目标或被特殊角色占用的旧守军建议释放。
	for uid in current_home.keys():
		if _has_claim(uid):
			continue
		var unit = instance_from_id(int(uid))
		claims.append(_claim(int(uid), Claim.RELEASE, "over_target_or_blocked", unit, castle))

	var proposed_adds: int = 0
	var proposed_releases: int = 0
	for item in claims:
		if int(item["claim"]) == Claim.PROPOSE:
			proposed_adds += 1
		elif int(item["claim"]) == Claim.RELEASE:
			proposed_releases += 1
	updated_at = now
	metrics = {
		"own_count": own.size(),
		"desired_home": desired,
		"current_home": current_home.size(),
		"proposed_adds": proposed_adds,
		"proposed_releases": proposed_releases,
		"wall_guard_count": wall_count,
		"resource_guard_count": resource_count,
		"overlap_roles": overlap_count,
		"posture": int(director.posture) if director != null else 0,
		"primary_sector": int(director.primary_sector) if director != null else -1,
	}
	return to_dictionary()

func _desired_home_count(own_size: int, director, defense, now: float) -> int:
	if own_size <= 0:
		return 0
	if not defense._defense_mode_active() and now < float(defense._guard_block_until):
		return 0
	if now < float(defense._force_guard_until):
		return own_size
	var level: int = int(defense.threat_level)
	if director != null:
		level = int(director.threat_level)
	match level:
		0, 1:
			return mini(own_size, HOME_GUARD_BASE)
		2:
			return mini(own_size, maxi(6, int(defense.threat_enemy_count) * 2 + 2))
		_:
			return own_size

func _is_blocked_candidate(unit, defense, now: float) -> bool:
	if unit == null or not is_instance_valid(unit):
		return true
	# 已有其他防守角色/正在建筑反击的部队不抢；已有任务的普通部队也不抢。
	if unit.has_meta("ai_wall_guard") or unit.has_meta("ai_resource_guard"):
		return true
	if defense._is_local_building_defender(unit, now):
		return true
	if not unit.has_meta("ai_home_guard") and defense._unit_has_existing_task(unit):
		return true
	return false

func _candidate_score(unit, castle, defense, director) -> float:
	var base: float = unit.global_position.distance_squared_to(castle.global_position)
	if director == null:
		return base
	var threat_dir: Vector3 = defense.threat_dir
	if threat_dir.length_squared() < 0.001:
		return base
	var rel: Vector3 = unit.global_position - castle.global_position
	rel.y = 0.0
	if rel.length_squared() < 0.001:
		return base
	var align: float = clampf(rel.normalized().dot(threat_dir), -1.0, 1.0)
	# 同距离下优先选靠近威胁方向的兵；不改变现有守军数量口径。
	return base * (1.25 - 0.25 * align)

func _claim(uid: int, claim: int, reason: String, unit, castle) -> Dictionary:
	var sector: int = -1
	var pos := Vector3.ZERO
	if unit != null and is_instance_valid(unit):
		pos = unit.global_position
		var rel: Vector3 = pos - castle.global_position
		rel.y = 0.0
		if rel.length_squared() > 0.001:
			var angle: float = atan2(rel.z, rel.x)
			sector = clampi(int(floor((angle + PI) / TAU * 8.0)), 0, 7)
	return {
		"unit_id": uid,
		"claim": claim,
		"claim_name": String(CLAIM_NAMES[clampi(claim, 0, 2)]),
		"reason": reason,
		"sector": sector,
		"pos": pos,
	}

func _has_claim(uid: int) -> bool:
	for item in claims:
		if int(item["unit_id"]) == uid:
			return true
	return false

func clear() -> void:
	claims.clear()
	metrics = {}
	updated_at = 0.0

func to_dictionary() -> Dictionary:
	return {
		"claims": claims.duplicate(true),
		"metrics": metrics.duplicate(true),
		"updated_at": updated_at,
	}

func describe() -> String:
	return "守军 目标:%d 现有:%d 建议+%d/-%d 重合:%d 墙卫:%d 资源卫:%d" % [
		int(metrics.get("desired_home", 0)),
		int(metrics.get("current_home", 0)),
		int(metrics.get("proposed_adds", 0)),
		int(metrics.get("proposed_releases", 0)),
		int(metrics.get("overlap_roles", 0)),
		int(metrics.get("wall_guard_count", 0)),
		int(metrics.get("resource_guard_count", 0)),
	]

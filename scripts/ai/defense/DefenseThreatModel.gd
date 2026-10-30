# scripts/ai/defense/DefenseThreatModel.gd
# 防御架构第 1 阶段：威胁感知模型。
#
# 对外仍输出旧的 threat_level / threat_score / threat_dir / threat_center，
# 保证 AIDefense 的现有调用点行为不变；内部额外维护：
#   · tracks：每条可见敌方作战单位的威胁轨迹；
#   · sectors：以主城为中心的 8 个扇区热度/敌军数/平均来向。
# 后续守军分配、墙段优先级、塔位覆盖会逐步改用 sectors，而不是全局单方向。
extends RefCounted

const THREAT_RADIUS: float = 15.0
const THREAT_OUTER_RADIUS: float = 26.0
const SECTOR_COUNT: int = 8
const SIEGE_IDS: Array = [16, 17, 18, 58, 59]

var context = null

# 兼容旧 AIDefense 的公开状态
var threat_level: int = 0
var threat_score: float = 0.0
var threat_enemy_count: int = 0
var threat_dir: Vector3 = Vector3.FORWARD
var threat_center: Vector3 = Vector3.ZERO

# 内部平滑/主城掉血状态；第 1 阶段仍由本模型持有，AIDefense 只做镜像。
var smoothed: float = 0.0
var castle_damage_until: float = -999.0
var last_castle_id: int = -1
var last_castle_health: float = -1.0

var _tracks: Array = []
var _sectors: Array = []
var _snapshot: Dictionary = {}
var _updated_at: float = 0.0

func _init(context_ref) -> void:
	context = context_ref
	reset()

func reset() -> void:
	threat_level = 0
	threat_score = 0.0
	threat_enemy_count = 0
	threat_dir = Vector3.FORWARD
	threat_center = Vector3.ZERO
	smoothed = 0.0
	castle_damage_until = -999.0
	last_castle_id = -1
	last_castle_health = -1.0
	_tracks.clear()
	_sectors.clear()
	_snapshot = {}
	_updated_at = 0.0

# 与旧 AIDefense._evaluate_threat 等价的评估入口。
# 返回快照，方便调试面板/测试读取；同时更新模型字段。
func evaluate(castle) -> Dictionary:
	if context == null or castle == null or not is_instance_valid(castle):
		reset()
		return get_snapshot()
	context.set_castle(castle)
	var now: float = context.get_game_time()
	var raw: float = 0.0
	var count: int = 0
	var dir_sum: Vector3 = Vector3.ZERO
	var center_sum: Vector3 = Vector3.ZERO
	var weight_sum: float = 0.0
	var sector_dirs: Array = []
	var sector_centers: Array = []
	var sector_weights: Array = []
	var sector_pressures: Array = []
	var sector_counts: Array = []
	for i in range(SECTOR_COUNT):
		sector_dirs.append(Vector3.ZERO)
		sector_centers.append(Vector3.ZERO)
		sector_weights.append(0.0)
		sector_pressures.append(0.0)
		sector_counts.append(0)
	_tracks.clear()

	# 威胁只来自 AI 当前视野内、确实能看到的敌军；不做全图侦测。
	for e in context.get_visible_enemies():
		if not is_instance_valid(e) or not (e is Army) or e.health <= 0:
			continue
		if not context.is_combat_enemy(e):
			continue
		var d: float = e.global_position.distance_to(castle.global_position)
		# 15 米内全权重，15~26 米的逼近部队按 45% 权重计入。
		if d > THREAT_OUTER_RADIUS:
			continue
		count += 1
		var prox: float = clampf(1.0 - d / THREAT_OUTER_RADIUS, 0.0, 1.0)
		var s: float = 1.0 + prox * 3.5
		if d > THREAT_RADIUS:
			s *= 0.45
		if float(e.attack) >= 30.0:
			s += 0.6
		if int(e.entity_id) in SIEGE_IDS:
			s += 0.8
		if d < 18.0:
			s += 1.0
		raw += s
		var w: float = 0.25 + prox
		var rel: Vector3 = e.global_position - castle.global_position
		var flat_rel := Vector3(rel.x, 0.0, rel.z)
		var dir_norm := Vector3.FORWARD
		if flat_rel.length_squared() > 0.0001:
			dir_norm = flat_rel.normalized()
		# 全局来向保持旧实现的三维归一化口径，避免为了扇区而改变原威胁方向。
		var full_dir: Vector3 = rel.normalized()
		dir_sum += full_dir * w
		center_sum += e.global_position * w
		weight_sum += w

		var sector: int = _sector_index(flat_rel)
		sector_dirs[sector] = (sector_dirs[sector] as Vector3) + dir_norm * w
		sector_centers[sector] = (sector_centers[sector] as Vector3) + e.global_position * w
		sector_weights[sector] = float(sector_weights[sector]) + w
		sector_pressures[sector] = float(sector_pressures[sector]) + s
		sector_counts[sector] = int(sector_counts[sector]) + 1
		_tracks.append({
			"unit_id": e.get_instance_id(),
			"entity_id": int(e.entity_id),
			"sector": sector,
			"pos": e.global_position,
			"dir": dir_norm,
			"distance": d,
			"pressure": s,
			"kind": _track_kind(e, d),
		})

	# 主城掉血只作为“已有可见近敌”的严重度加成，不再单独触发威胁。
	if last_castle_id != castle.get_instance_id():
		last_castle_id = castle.get_instance_id()
		last_castle_health = castle.health
	if castle.health < last_castle_health - 0.5:
		castle_damage_until = now + 8.0
	last_castle_health = castle.health
	if count > 0 and now < castle_damage_until:
		raw += 4.0

	# 没有任何可见近敌时直接清零，避免之前战斗的高分继续残留。
	if count == 0:
		smoothed = 0.0

	threat_enemy_count = count
	if raw > smoothed:
		smoothed = lerpf(smoothed, raw, 0.7)
	else:
		smoothed = lerpf(smoothed, raw, 0.45)
	threat_score = smoothed

	# 只有成建制敌军逼近/攻城才进入防守，单个远处侦察兵不应让 AI 全员回防。
	if threat_score >= 12.0:
		threat_level = 3
	elif threat_score >= 6.0:
		threat_level = 2
	elif threat_score >= 2.0:
		threat_level = 1
	else:
		threat_level = 0

	if weight_sum > 0.01 and dir_sum.length_squared() > 0.01:
		threat_dir = (dir_sum / weight_sum).normalized()
		threat_center = center_sum / weight_sum
	else:
		threat_dir = context.get_enemy_castle_dir(castle)
		threat_center = castle.global_position + threat_dir * 18.0
	if threat_dir.length_squared() < 0.001:
		threat_dir = Vector3.FORWARD

	_sectors = _build_sectors(sector_dirs, sector_centers, sector_weights,
			sector_pressures, sector_counts)
	_updated_at = now
	_snapshot = {
		"level": threat_level,
		"score": threat_score,
		"enemy_count": threat_enemy_count,
		"dir": threat_dir,
		"center": threat_center,
		"tracks": _tracks.duplicate(true),
		"sectors": _sectors.duplicate(true),
		"updated_at": _updated_at,
	}
	return get_snapshot()

func get_snapshot() -> Dictionary:
	if _snapshot.is_empty():
		return {
			"level": threat_level,
			"score": threat_score,
			"enemy_count": threat_enemy_count,
			"dir": threat_dir,
			"center": threat_center,
			"tracks": [],
			"sectors": [],
			"updated_at": _updated_at,
		}
	return _snapshot.duplicate(true)

func get_tracks() -> Array:
	return _tracks.duplicate(true)

func get_sectors() -> Array:
	return _sectors.duplicate(true)

# 当前压力最大的扇区；没有威胁时返回 -1。
func get_primary_sector() -> int:
	var best: int = -1
	var best_pressure: float = 0.0
	for i in range(_sectors.size()):
		var pressure: float = float(_sectors[i].get("pressure", 0.0))
		if pressure > best_pressure:
			best_pressure = pressure
			best = i
	return best

func _sector_index(rel: Vector3) -> int:
	if rel.length_squared() < 0.0001:
		return 0
	var angle: float = atan2(rel.z, rel.x)
	var idx: int = int(floor((angle + PI) / TAU * float(SECTOR_COUNT)))
	return clampi(idx, 0, SECTOR_COUNT - 1)

func _track_kind(entity, distance: float) -> String:
	if int(entity.entity_id) in SIEGE_IDS:
		return "siege"
	if distance > THREAT_RADIUS:
		return "approach"
	return "assault"

func _build_sectors(sector_dirs: Array, sector_centers: Array, sector_weights: Array,
		sector_pressures: Array, sector_counts: Array) -> Array:
	var out: Array = []
	for i in range(SECTOR_COUNT):
		var weight: float = float(sector_weights[i])
		var direction := Vector3.ZERO
		var center := Vector3.ZERO
		if weight > 0.01:
			direction = (sector_dirs[i] as Vector3).normalized()
			center = (sector_centers[i] as Vector3) / weight
		out.append({
			"index": i,
			"angle_center": -PI + (float(i) + 0.5) * TAU / float(SECTOR_COUNT),
			"pressure": float(sector_pressures[i]),
			"enemy_count": int(sector_counts[i]),
			"dir": direction,
			"center": center,
		})
	return out

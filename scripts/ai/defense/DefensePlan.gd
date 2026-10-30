# scripts/ai/defense/DefensePlan.gd
# 防御架构第 2 阶段：只读防御计划视图。
#
# 把 AIDefense 里分散的状态（圈数/半径/已规划墙位/队列/扇区）汇总成一份 DefensePlan，
# 供调试面板和后续规划器读取。本阶段不写回任何旧状态，避免改变现有行为。
extends RefCounted

const RING_UNPLANNED: String = "UNPLANNED"
const RING_PLANNED: String = "PLANNED"
const RING_BUILDING: String = "BUILDING"
const RING_SEALED: String = "SEALED"
const RING_BREACHED: String = "BREACHED"

var rings: Array = []
var wall_slots: Array = []
var build_queue: Array = []
var sectors: Array = []
var posture: int = 0
var budget_reserve: float = 0.35
var threat_level: int = 0
var updated_at: float = 0.0
var revision: int = 0

# defense 是 AIDefense 实例；director 是已 evaluate 过的 DefenseDirector；
# snapshot 是当前威胁快照（可选），用于保留完整扇区字段。
func rebuild(defense, director, snapshot: Dictionary = {}) -> Dictionary:
	rings.clear()
	wall_slots.clear()
	build_queue.clear()
	sectors.clear()
	posture = 0
	budget_reserve = 0.35
	threat_level = 0
	if defense == null:
		updated_at = 0.0
		revision += 1
		return to_dictionary()
	if director != null:
		posture = int(director.posture)
		budget_reserve = float(director.budget_reserve)
		threat_level = int(director.threat_level)
		if not snapshot.is_empty() and snapshot.get("sectors", []) is Array:
			sectors = (snapshot.get("sectors", []) as Array).duplicate(true)
		else:
			sectors = _snapshot_sectors(director)
	else:
		threat_level = int(defense.threat_level)
		posture = clampi(threat_level, 0, 3)
		budget_reserve = _legacy_reserve(threat_level)

	var target: int = maxi(int(defense._wall_ring_target), int(defense._wall_rings_planned))
	var radii: Array = defense._wall_ring_radii
	for i in range(target):
		var radius: int = 0
		if i < radii.size():
			radius = int(radii[i])
		var status: String = RING_UNPLANNED
		if i == 0 and bool(defense._castle_ring_planned):
			status = RING_BUILDING
		elif i < int(defense._wall_rings_planned):
			status = RING_PLANNED
		rings.append({
			"index": i,
			"radius": radius,
			"status": status,
		})

	var positions: Array = defense.wall_positions
	for i in range(positions.size()):
		var pos: Vector3 = positions[i]
		wall_slots.append({"index": i, "pos": pos, "kind": "wall"})

	var queue: Array = defense._defense_queue
	for item in queue:
		if not (item is Dictionary):
			continue
		build_queue.append({
			"id": int(item.get("id", 0)),
			"pos": item.get("pos", Vector3.ZERO),
			"priority": float(item.get("priority", 0.0)),
			"tries": int(item.get("tries", 0)),
			"is_wall": int(item.get("id", 0)) == 27,
		})

	updated_at = float(defense.ai.battle.game_time) if defense.ai != null and defense.ai.battle != null else 0.0
	revision += 1
	return to_dictionary()

func _snapshot_sectors(director) -> Array:
	# DefenseDirector 只保存扇区压力数组；这里按压力重建最小视图。
	var pressure: Array = director.sector_pressure
	var out: Array = []
	for i in range(pressure.size()):
		out.append({
			"index": i,
			"pressure": float(pressure[i]),
			"is_primary": i == int(director.primary_sector),
		})
	return out

func _legacy_reserve(level: int) -> float:
	if level >= 2:
		return 0.22
	if level == 1:
		return 0.20
	return 0.35

func get_ring(index: int) -> Dictionary:
	if index < 0 or index >= rings.size():
		return {}
	return (rings[index] as Dictionary).duplicate(true)

func clear() -> void:
	rings.clear()
	wall_slots.clear()
	build_queue.clear()
	sectors.clear()
	posture = 0
	budget_reserve = 0.35
	threat_level = 0
	updated_at = 0.0
	revision += 1

func get_walls_in_ring(index: int) -> Array:
	# 第 2 阶段没有可靠的逐圈墙归属，先返回空数组；后续规划器会按半径/扇区填充。
	return []

func to_dictionary() -> Dictionary:
	return {
		"posture": posture,
		"threat_level": threat_level,
		"budget_reserve": budget_reserve,
		"rings": rings.duplicate(true),
		"wall_slots": wall_slots.duplicate(true),
		"build_queue": build_queue.duplicate(true),
		"sectors": sectors.duplicate(true),
		"revision": revision,
		"updated_at": updated_at,
	}

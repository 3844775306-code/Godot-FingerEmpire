# scripts/ai/AIWorkerDirector.gd
# WorkerDirector 第 1 阶段：只读账本。
# 只观察和记录农民状态，不改变任何单位命令、角色或 meta。
# 等日志确认账本口径正确后，再逐步接管补农/采集/建造/逃跑。
class_name AIWorkerDirector
extends RefCounted

const ROLE_IDLE: int = 0
const ROLE_GATHER: int = 1
const ROLE_HAULER: int = 2
const ROLE_BUILDER: int = 3
const ROLE_REPAIRER: int = 4
const ROLE_FLEE: int = 5
const ROLE_GARRISON: int = 6
const ROLE_HUNT: int = 7

const ROLE_NAMES: Array = ["IDLE", "GATHER", "HAULER", "BUILDER", "REPAIRER", "FLEE", "GARRISON", "HUNT"]
const TICK_INTERVAL: float = 1.0
const LOG_INTERVAL: float = 5.0

var ai = null
var _timer: float = 0.0
var _log_timer: float = 0.0
var _workers: Dictionary = {}   # uid -> read-only snapshot

func setup(controller) -> void:
	ai = controller
	_timer = 0.0
	_log_timer = 0.0

func tick(delta: float) -> void:
	if ai == null:
		return
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = TICK_INTERVAL
	_sync_roster()
	_log_timer -= TICK_INTERVAL
	if _log_timer <= 0.0:
		_log_timer = LOG_INTERVAL
		_log_metrics()

# 只读扫描：不写 current_order/current_target/meta，只记录当前分类。
func _sync_roster() -> void:
	var now: float = 0.0
	if ai.battle != null:
		now = float(ai.battle.game_time)
	var seen: Dictionary = {}
	for entity in ai._cached_armies():
		if not is_instance_valid(entity) or not (entity is Army) or entity.health <= 0:
			continue
		if int(entity.entity_id) != 10:
			continue
		if not ai.entity_belongs_to_me(entity):
			continue
		var uid: int = entity.get_instance_id()
		var role: int = _classify(entity, now)
		seen[uid] = {
			"role": role,
			"order": String(entity.current_order),
			"target": _target_desc(entity.current_target),
			"pos": entity.global_position,
		}
	# 只保留仍活着的农民；本阶段不释放/不接管命令，仅更新观察账本。
	_workers = seen

func _classify(worker, now: float) -> int:
	if worker.has_meta("ai_flee_until") and now < float(worker.get_meta("ai_flee_until")):
		return ROLE_FLEE
	if _is_garrisoned(worker):
		return ROLE_GARRISON
	var tgt = worker.current_target
	if String(worker.current_order) == "build":
		return ROLE_BUILDER
	if String(worker.current_order) == "deliver":
		return ROLE_HAULER
	if tgt != null and is_instance_valid(tgt):
		if tgt is WorldResource:
			return ROLE_GATHER
		if tgt is Building and tgt.health > 0 and tgt.build_timer > 0.0:
			return ROLE_BUILDER
		if tgt is Army and _is_animal_target(tgt):
			return ROLE_HUNT
	return ROLE_IDLE

func _is_garrisoned(worker) -> bool:
	var gb = worker.get("_garrison_building")
	if gb != null and gb.get_ref() != null:
		return true
	var sgb = worker.get("_soldier_garrison_building")
	return sgb != null and sgb.get_ref() != null

func _is_animal_target(target) -> bool:
	var at = target.get("_animal_type")
	return at != null and str(at) != ""

func _target_desc(target) -> String:
	if target == null or not is_instance_valid(target):
		return "-"
	if target is WorldResource:
		return "res:" + String(target.resource_type)
	if target is Building:
		return "b:%d" % int(target.entity_id)
	if target is Army:
		return "u:%d" % int(target.entity_id)
	return "?"

func _count_queued_workers() -> int:
	var total: int = 0
	for entity in ai._cached_buildings():
		if not is_instance_valid(entity) or not (entity is Building) or entity.health <= 0:
			continue
		if not ai.entity_belongs_to_me(entity):
			continue
		for pid in entity.production_queue:
			if int(pid) == 10:
				total += 1
	return total

func _worker_target_count() -> int:
	if ai.phase >= 2:
		return 15
	if ai.phase == 1:
		return 12
	return 8

func _worker_floor_count() -> int:
	if ai.phase >= 2:
		return 8
	if ai.phase == 1:
		return 6
	return 4

func _role_counts() -> Dictionary:
	var counts: Dictionary = {}
	for uid in _workers:
		var role: int = int(_workers[uid].get("role", ROLE_IDLE))
		counts[role] = int(counts.get(role, 0)) + 1
	return counts

func _format_role_counts(counts: Dictionary) -> String:
	var parts: Array = []
	for role in [ROLE_GATHER, ROLE_HAULER, ROLE_BUILDER, ROLE_REPAIRER, ROLE_FLEE, ROLE_GARRISON, ROLE_HUNT, ROLE_IDLE]:
		var n: int = int(counts.get(role, 0))
		if n > 0:
			parts.append("%s=%d" % [ROLE_NAMES[role], n])
	if parts.is_empty():
		return "-"
	return ",".join(parts)

func _log_metrics() -> void:
	if ai == null or ai.battle == null:
		return
	# 发布版不打印：6 个 AI 每 5 秒各一行，调试够用，正式局不需要这个开销。
	if not OS.is_debug_build():
		return
	var live: int = _workers.size()
	var queued: int = _count_queued_workers()
	var counts: Dictionary = _role_counts()
	var idle: int = int(counts.get(ROLE_IDLE, 0))
	var flee: int = int(counts.get(ROLE_FLEE, 0))
	var mode: String = "NORMAL"
	if live + queued <= _worker_floor_count():
		mode = "WORKER_CRISIS"
	elif ai._food_emergency():
		mode = "FOOD_CRISIS"
	elif ai._defense != null and int(ai._defense.threat_level) >= 2:
		mode = "BASE_ALERT"
	# 只读日志：字段保持稳定，方便后续 grep 和多局对比。
	print("[WORKER] t=%d pid=%d mode=%s live=%d queued=%d target=%d floor=%d idle=%d flee=%d roles=%s block=%s" % [
		int(ai.battle.game_time), int(ai.my_peer_id), mode, live, queued,
		_worker_target_count(), _worker_floor_count(), idle, flee,
		_format_role_counts(counts), String(ai._last_spend_block)])

func debug_snapshot() -> Dictionary:
	return {
		"live": _workers.size(),
		"queued": _count_queued_workers(),
		"target": _worker_target_count(),
		"floor": _worker_floor_count(),
		"roles": _role_counts(),
	}

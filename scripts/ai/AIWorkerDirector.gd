# scripts/ai/AIWorkerDirector.gd
# WorkerDirector：统一补农、采集、建造/修理、逃跑与打猎的农民调度。
# 当前阶段：补农、基础采集、建造者租约、逃跑接管；打猎仍由旧入口派单。
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
const TRAIN_COOLDOWN: float = 1.5
const BUILDER_LEASE: float = 90.0
const BUILDER_ASSIGN_GRACE: float = 3.0

var ai = null
var _timer: float = 0.0
var _log_timer: float = 0.0
var _workers: Dictionary = {}   # uid -> snapshot + unit
var _last_train_at: float = -999.0
var _last_train_block: String = ""
# uid -> 逃跑前的资源点；危险解除后优先回到原资源点。
var _flee_resume: Dictionary = {}
# uid -> {unit, building, kind, source, created_at, assigned_at, expires_at}
var _builder_reservations: Dictionary = {}

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
	_release_finished_builders()
	_update_flee()
	_log_timer -= TICK_INTERVAL
	if _log_timer <= 0.0:
		_log_timer = LOG_INTERVAL
		_log_metrics()

# 每 3 秒由 AI.gd 的 allocate_workers() 调用。
# 这里接管补农、空闲农民分配、满仓资源改派和周期性配额重排。
func allocate() -> void:
	if ai == null or ai.battle == null:
		return
	ai._worker_threat_cache.clear()
	_sync_roster()
	var workers: Array = _live_workers()
	ai.desired_worker_count = _worker_target_count()

	# 食物/稀缺资源救急仍然复用旧实现，第 3 阶段再收编。
	ai._force_food_workers(workers)
	ai._emergency_rebalance_workers(workers)

	ensure_worker_count(workers)
	_assign_idle(workers)
	_reassign_full(workers)
	_periodic_rebalance(workers)

# 补农唯一入口：先保底，再补到阶段目标。
# 返回是否成功排入一个农民。
func ensure_worker_count(workers: Array = []) -> bool:
	if ai == null or ai.battle == null:
		return false
	if workers.is_empty():
		_sync_roster()
		workers = _live_workers()
	var live: int = workers.size()
	var queued: int = _count_queued_workers()
	var total: int = live + queued
	var floor_count: int = _worker_floor_count()
	var target: int = _worker_target_count()

	if total >= target:
		_last_train_block = "at_target"
		return false
	if total < floor_count:
		# 保底优先：不受食物告急、资源满仓、建造预留限制。
		return _try_train_worker("floor")
	if ai._food_emergency():
		_last_train_block = "food_crisis"
		return false
	if ai._all_gather_resources_full():
		_last_train_block = "all_full"
		return false
	return _try_train_worker("target")

func _try_train_worker(reason: String) -> bool:
	if ai == null or ai.battle == null:
		return false
	var now: float = float(ai.battle.game_time)
	if now - _last_train_at < TRAIN_COOLDOWN:
		_last_train_block = "cooldown"
		return false
	if not ai.can_afford(10):
		_last_train_block = "no_food"
		return false
	if not ai._can_train_unit_with_queue():
		_last_train_block = "population"
		return false
	ai.produce_unit(10)
	_last_train_at = now
	_last_train_block = "trained_" + reason
	return true

# 建造/修理统一从这里领取农民。
# critical=true 时允许从正在采集的农民里抽 1 个，用于民居/兵营紧急重建。
func acquire_builder(pos: Vector3, critical: bool = false, max_dist: float = 60.0,
		source: String = "build") -> Army:
	if ai == null or ai.battle == null:
		return null
	_sync_roster()
	_release_finished_builders()
	var now: float = float(ai.battle.game_time)
	var best = null
	var best_priority: int = 99
	var best_dist: float = INF
	var max_dist_sq: float = max_dist * max_dist
	for uid in _workers:
		if _builder_reservations.has(uid):
			continue
		var rec: Dictionary = _workers[uid]
		var w = rec.get("unit")
		if w == null or not is_instance_valid(w) or w.health <= 0 or not w.can_move:
			continue
		if ai._worker_is_fleeing(w) or _is_garrisoned(w):
			continue
		if String(w.current_order) == "build":
			continue
		if ai._unit_has_claim(w):
			continue
		var order: String = String(w.current_order)
		var work_id: int = int(w.get("_work_target_id"))
		var priority: int = 99
		if order == "" or order == "idle":
			priority = 0
		elif order == "gather" and work_id == -1:
			priority = 1
		elif critical and order == "gather":
			priority = 2
		if priority > 2:
			continue
		if priority == 2 and not critical:
			continue
		var d: float = w.global_position.distance_squared_to(pos)
		if d > max_dist_sq:
			continue
		if priority < best_priority or (priority == best_priority and d < best_dist):
			best = w
			best_priority = priority
			best_dist = d
	if best == null:
		return null
	# 关键建造可以打断“正在采集”的农民；普通建造只拿空闲/未锁定目标的农民。
	if best_priority >= 2:
		if best.has_method("_detach_from_building"):
			best._detach_from_building()
		if best.has_method("stop_movement"):
			best.stop_movement()
		best.current_order = ""
		best.current_target = null
		best._work_target_id = -1
	var uid: int = best.get_instance_id()
	_builder_reservations[uid] = {
		"unit": best,
		"building": null,
		"kind": "repair" if source.begins_with("repair") else "build",
		"source": source,
		"created_at": now,
		"assigned_at": -1.0,
		"expires_at": now + BUILDER_LEASE,
	}
	return best

func on_builder_assigned(builder, building, kind: String = "") -> void:
	if builder == null or not is_instance_valid(builder):
		return
	var uid: int = builder.get_instance_id()
	if not _builder_reservations.has(uid):
		return
	var rec: Dictionary = _builder_reservations[uid]
	rec["building"] = building
	if kind != "":
		rec["kind"] = kind
	rec["assigned_at"] = float(ai.battle.game_time) if ai != null and ai.battle != null else 0.0
	_builder_reservations[uid] = rec

func release_builder(builder, reason: String = "") -> void:
	if builder == null:
		return
	_builder_reservations.erase(builder.get_instance_id())

func _release_finished_builders() -> void:
	if _builder_reservations.is_empty():
		return
	var now: float = float(ai.battle.game_time) if ai != null and ai.battle != null else 0.0
	for uid in _builder_reservations.keys():
		var rec: Dictionary = _builder_reservations[uid]
		var w = rec.get("unit")
		if w == null or not is_instance_valid(w) or w.health <= 0:
			_builder_reservations.erase(uid)
			continue
		var b = rec.get("building")
		if b != null:
			if not is_instance_valid(b) or b.health <= 0:
				_builder_reservations.erase(uid)
				continue
			var working: bool = b.build_timer > 0.0 or (b.has_method("is_under_repair") and b.is_under_repair())
			if not working and now - float(rec.get("assigned_at", -1.0)) > BUILDER_ASSIGN_GRACE:
				_builder_reservations.erase(uid)
				continue
			# 已指派但农民没有真正进入施工/修理（寻路失败、命令被覆盖），释放租约。
			if now - float(rec.get("assigned_at", -1.0)) > BUILDER_ASSIGN_GRACE:
				var kind: String = String(rec.get("kind", "build"))
				if kind == "build" and String(w.current_order) != "build":
					_builder_reservations.erase(uid)
					continue
				if kind == "repair" and not (b.has_method("is_under_repair") and b.is_under_repair()):
					_builder_reservations.erase(uid)
					continue
		elif now - float(rec.get("created_at", now)) > BUILDER_ASSIGN_GRACE:
			# 拿到农民但建造没落地（资源/校验失败），尽快释放，避免锁死。
			_builder_reservations.erase(uid)
			continue
		if now > float(rec.get("expires_at", now + BUILDER_LEASE)):
			_builder_reservations.erase(uid)

func has_builder_reservation(builder) -> bool:
	return builder != null and _builder_reservations.has(builder.get_instance_id())

func _live_workers() -> Array:
	var result: Array = []
	for uid in _workers:
		var rec: Dictionary = _workers[uid]
		var unit = rec.get("unit")
		if unit != null and is_instance_valid(unit) and unit.health > 0:
			result.append(unit)
	return result

# 只读扫描角色；同时同步 desired_worker_count。
func _sync_roster() -> void:
	var now: float = 0.0
	if ai.battle != null:
		now = float(ai.battle.game_time)
	ai.desired_worker_count = _worker_target_count()
	var seen: Dictionary = {}
	for entity in ai._cached_armies():
		if not is_instance_valid(entity) or not (entity is Army) or entity.health <= 0:
			continue
		if int(entity.entity_id) != 10:
			continue
		if not ai.entity_belongs_to_me(entity):
			continue
		var uid: int = entity.get_instance_id()
		seen[uid] = {
			"unit": entity,
			"role": _classify(entity, now),
			"order": String(entity.current_order),
			"target": _target_desc(entity.current_target),
			"pos": entity.global_position,
		}
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

# 第 4 阶段：逃跑由 Director 统一接管。
# 危险靠近时先记录原资源点，再按“有货交付、无货远离”处理；危险解除后回原资源点。
func _update_flee() -> void:
	if ai == null or ai.battle == null:
		return
	var now: float = float(ai.battle.game_time)
	for uid in _workers.keys():
		var rec: Dictionary = _workers[uid]
		var w = rec.get("unit")
		if w == null or not is_instance_valid(w) or w.health <= 0:
			_flee_resume.erase(uid)
			continue
		if _is_garrisoned(w):
			continue
		var danger = _nearest_enemy(w.global_position, 8.0)
		if danger != null:
			if w.has_meta("ai_flee_until") and now < float(w.get_meta("ai_flee_until")):
				continue
			var tgt = w.current_target
			if is_instance_valid(tgt) and tgt is WorldResource:
				_flee_resume[uid] = tgt
			elif not _flee_resume.has(uid):
				_flee_resume[uid] = null
			w.set_meta("ai_flee_until", now + 9.0)
			var has_cargo: bool = false
			for rk in ["gold", "wood", "stone", "food", "oil"]:
				if int(w.cargo.get(rk, 0)) > 0:
					has_cargo = true
					break
			if has_cargo:
				if w.current_order != "deliver" and w.current_order != "move" and w.has_method("_return_to_deliver"):
					w.call("_return_to_deliver")
			elif String(w.current_order) != "move":
				var away: Vector3 = w.global_position - danger.global_position
				away.y = 0.0
				if away.length_squared() < 0.01:
					away = Vector3.RIGHT
				var flee_pos: Vector3 = w.global_position + away.normalized() * 6.0
				var half_limit: float = RTSConfig.MAP_SIZE / 2.0 - 3.0
				flee_pos.x = clampf(flee_pos.x, -half_limit, half_limit)
				flee_pos.z = clampf(flee_pos.z, -half_limit, half_limit)
				w.move_to(flee_pos)
		elif w.has_meta("ai_flee_until") and now >= float(w.get_meta("ai_flee_until")):
			w.remove_meta("ai_flee_until")
			var resume = _flee_resume.get(uid)
			if is_instance_valid(resume) and resume is WorldResource:
				var rk: String = String(resume.resource_type)
				if ai._resource_ratio(rk) < ai._pressure_threshold():
					w.gather_at(resume)
			_flee_resume.erase(uid)

func _nearest_enemy(pos: Vector3, radius: float):
	if ai == null or ai.battle == null or not ai.battle.has_method("get_nearby_enemies"):
		return null
	var w = null
	for e in ai.battle.get_nearby_enemies(pos, radius, ai.my_team, ai.my_peer_id, true):
		if not (e is Army) or e.health <= 0:
			continue
		if _is_animal_target(e):
			continue
		if ai.entity_belongs_to_me(e):
			continue
		w = e
		break
	return w

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

# 空闲农民必须有采集目标；已经采着的农民不重排，避免每 3 秒目标抖动。
func _assign_idle(workers: Array) -> void:
	for w in workers:
		if not is_instance_valid(w) or w.health <= 0:
			continue
		if ai._worker_is_fleeing(w):
			continue
		if w.has_meta("ai_flee_until"):
			w.remove_meta("ai_flee_until")
		if w.current_target == null and w.current_order == "":
			var weights: Dictionary = ai._worker_resource_weights()
			if weights.is_empty():
				continue
			var target = ai.find_best_resource_for_worker(w, weights)
			if target != null:
				w.gather_at(target)

# 资源接近满仓时，不再让农民继续往这个池子里送。
func _reassign_full(workers: Array) -> void:
	var full_types: Array = []
	for rk in ["gold", "wood", "stone", "food"]:
		if ai._resource_ratio(rk) >= ai._pressure_threshold():
			full_types.append(rk)
	if full_types.is_empty():
		return
	var alt_weights: Dictionary = ai._worker_resource_weights()
	if alt_weights.is_empty():
		return
	for w in workers:
		if not is_instance_valid(w) or w.health <= 0:
			continue
		if ai._worker_is_fleeing(w) or String(w.current_order) == "deliver":
			continue
		var tgt = w.current_target
		if not (is_instance_valid(tgt) and tgt is WorldResource):
			continue
		if not (String(tgt.resource_type) in full_types):
			continue
		var alt = ai.find_best_resource_for_worker(w, alt_weights)
		if alt != null and not (String(alt.resource_type) in full_types):
			w.gather_at(alt)

# 每 11 次分配（约 33 秒）按资源缺口做一次配额重排。
func _periodic_rebalance(workers: Array) -> void:
	ai.allocate_timers += 1
	if ai.allocate_timers <= 10:
		return
	ai.consider_warehouse_near_farmer()
	ai.allocate_timers = 0
	var res: Dictionary = ai._get_resources()
	var limits: Dictionary = ai._get_limits()
	var phase_weights: Dictionary = ai._worker_resource_weights()
	var scarcity: Dictionary = {}
	var total_weight: float = 0.0
	for rk in ["gold", "wood", "stone", "food"]:
		var pct: float = float(res.get(rk, 0)) / maxf(float(limits.get(rk, 500)), 1.0)
		var base: float = maxf(0.05, 1.0 - pct) if pct <= 0.9 else 0.0
		scarcity[rk] = base * float(phase_weights.get(rk, 1.0))
		total_weight += float(scarcity[rk])
	if total_weight <= 0.0:
		return
	for rk in scarcity:
		scarcity[rk] = float(scarcity[rk]) / total_weight * float(_worker_target_count())
	var current: Dictionary = {"gold": 0, "wood": 0, "stone": 0, "food": 0}
	var idle: Array = []
	for w in workers:
		if not is_instance_valid(w) or w.health <= 0:
			continue
		var tgt = w.current_target
		if is_instance_valid(tgt) and tgt is WorldResource:
			var t: String = String(tgt.resource_type)
			if t in current:
				current[t] = int(current[t]) + 1
				if int(current[t]) > int(scarcity.get(t, 2)):
					idle.append(w)
			else:
				idle.append(w)
		else:
			idle.append(w)
	for w in workers:
		if not is_instance_valid(w) or w.health <= 0 or ai._worker_is_fleeing(w):
			continue
		if String(w.current_order) != "deliver":
			continue
		for rk in ["gold", "wood", "stone", "food"]:
			if int(w.cargo.get(rk, 0)) > 0:
				current[rk] = int(current.get(rk, 0)) + 1
				if int(current[rk]) > int(scarcity.get(rk, 2)):
					idle.append(w)
				break
	for w in idle:
		if not is_instance_valid(w) or w.health <= 0 or ai._worker_is_fleeing(w):
			continue
		var best_rk: String = ""
		var best_gap: float = -1.0
		for rk in scarcity:
			var gap: float = float(scarcity[rk]) - float(current.get(rk, 0))
			if gap > best_gap:
				best_gap = gap
				best_rk = String(rk)
		if best_rk == "":
			continue
		var target = ai.find_best_resource_for_worker(w, {best_rk: 100})
		if target != null:
			w.gather_at(target)
			current[best_rk] = int(current.get(best_rk, 0)) + 1

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
	print("[WORKER] t=%d pid=%d mode=%s live=%d queued=%d target=%d floor=%d idle=%d flee=%d builders=%d roles=%s train=%s block=%s" % [
		int(ai.battle.game_time), int(ai.my_peer_id), mode, live, queued,
		_worker_target_count(), _worker_floor_count(), idle, flee,
		_builder_reservations.size(), _format_role_counts(counts), _last_train_block,
		String(ai._last_spend_block)])

func debug_snapshot() -> Dictionary:
	return {
		"live": _workers.size(),
		"queued": _count_queued_workers(),
		"target": _worker_target_count(),
		"floor": _worker_floor_count(),
		"roles": _role_counts(),
		"builders": _builder_reservations.size(),
		"train_block": _last_train_block,
	}

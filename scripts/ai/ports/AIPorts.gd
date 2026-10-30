extends RefCounted

# A3：执行层唯一的写出口（Ports）。
#
# 设计见 docs/AI架构总设计.md §3.2：
#   EconomyPort  资源查询与扣减（只读部分已在 AIContext，这里放"花出去"的入口）
#   BuildPort    建造/升级（落位校验 + 实际下单）
#   CommandPort  调兵（角色占用/释放/命令下发）
#
# 当前是"转发实现"：内部仍调用 AI 控制器的既有方法，等所有模块切过来之后再收紧。
# 关键在于：执行层以后只认 Port，不再出现 ai.build_building(...) 这类直接调用。

# ───────────────────────── EconomyPort ─────────────────────────
class EconomyPort:
	var _ai = null

	func _init(ai) -> void:
		_ai = ai

	func resources() -> Dictionary:
		return _ai._get_resources() if _ai != null else {}

	func limits() -> Dictionary:
		return _ai._get_limits() if _ai != null else {}

	func can_afford(id: int) -> bool:
		return _ai.can_afford(id) if _ai != null else false

	func last_spend_block() -> String:
		return String(_ai._last_spend_block) if _ai != null else ""

# ───────────────────────── BuildPort ─────────────────────────
class BuildPort:
	var _ai = null

	func _init(ai) -> void:
		_ai = ai

	func can_place(building_id: int, pos: Vector3) -> bool:
		if _ai == null:
			return false
		return bool(_ai._can_place_ai_building(building_id, pos))

	func can_build(building_id: int) -> bool:
		if _ai == null:
			return false
		return bool(_ai._ai_can_build(building_id)) if _ai.has_method("_ai_can_build") else true

	func build(building_id: int, pos = null, facing = null) -> bool:
		if _ai == null:
			return false
		if pos == null:
			return bool(_ai.build_building(building_id))
		if facing == null:
			return bool(_ai.build_building(building_id, pos))
		return bool(_ai.build_building(building_id, pos, facing))

	func upgrade(building_id: int) -> bool:
		if _ai == null:
			return false
		return bool(_ai.upgrade_building(building_id))

	func castle_lv() -> int:
		return int(_ai.get_peer_castle(_ai.my_peer_id).upgrade_level) if _ai != null and _ai.get_peer_castle(_ai.my_peer_id) != null else 0

# ───────────────────────── RecruitPort ─────────────────────────
class RecruitPort:
	var _ai = null

	func _init(ai) -> void:
		_ai = ai

	func produce(unit_id: int, rule: String = "") -> bool:
		if _ai == null:
			return false
		return bool(_ai.produce_unit(unit_id, rule))

	func can_train() -> bool:
		return bool(_ai._can_train_unit()) if _ai != null else false

	func can_train_with_queue() -> bool:
		return bool(_ai._can_train_unit_with_queue()) if _ai != null else false

# ───────────────────────── CommandPort ─────────────────────────
class CommandPort:
	var _ai = null

	func _init(ai) -> void:
		_ai = ai

	func claim(unit, role: int, lease: float) -> void:
		if _ai == null or unit == null:
			return
		_ai._director_claim(unit, role, lease)

	func release(uid: int) -> void:
		if _ai == null:
			return
		_ai._director_release(uid)

	# 跨模块请求统一走这里，模块代码不再直连其它模块。
	func request_worker_rebalance() -> void:
		if _ai != null:
			_ai.allocate_workers()

	func release_wall_guard(unit) -> void:
		if _ai != null:
			_ai._release_wall_guard(unit)

	func has_claim(unit) -> bool:
		return bool(_ai._unit_has_claim(unit)) if _ai != null else false

	func role_of(unit) -> int:
		return int(_ai._director_role_of(unit)) if _ai != null and _ai.has_method("_director_role_of") else -1

# ───────────────────────── 组装 ─────────────────────────
var economy = null
var build = null
var command = null
var recruit = null

func bind(ai) -> void:
	economy = EconomyPort.new(ai)
	build = BuildPort.new(ai)
	command = CommandPort.new(ai)
	recruit = RecruitPort.new(ai)

func debug_snapshot() -> Dictionary:
	return {"bound": economy != null}

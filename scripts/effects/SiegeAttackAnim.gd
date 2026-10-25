class_name SiegeAttackAnim
extends RefCounted

# 攻城器械的分层程序化攻击动画。
# 不改变实体朝向/移动，只动画模型根节点和 GLB 内部的炮臂、撞木、轮子、帆、旗。
# 单机 RTSBattleManager 与联机 ClientRenderer 共用，保证两边手感一致。

const SIEGE_IDS := [13, 16, 17, 18, 39, 59]
const META_RUNNING := "_siege_anim_running"
const META_TWEENS := "_siege_anim_tweens"
const META_BASE := "_siege_anim_base"

static func is_siege(entity_id: int) -> bool:
	return entity_id in SIEGE_IDS

static func play(entity_id: int, model: Node3D, opts: Dictionary = {}) -> bool:
	if not is_siege(entity_id) or not _valid(model):
		return false
	reset(model)
	var base := _capture(model)
	model.set_meta(META_BASE, base)
	model.set_meta(META_TWEENS, [])
	model.set_meta(META_RUNNING, true)

	# 战船左右舷随机，单机优先按目标方向选侧，避免每次都朝同一边开火
	var ship_side: float = 1.0
	if entity_id in [13, 39]:
		ship_side = float(opts.get("side", 1 if model.get_instance_id() % 2 == 0 else -1))
		var target = opts.get("target")
		if not opts.has("side") and target is Node3D and is_instance_valid(target):
			var right: Vector3 = model.global_transform.basis.x
			if right.dot((target as Node3D).global_position - model.global_position) < 0.0:
				ship_side = -1.0
		opts["side"] = int(ship_side)

	var duration: float = 1.0
	match entity_id:
		18:
			duration = _ram(model)
		16:
			duration = _cannon(model)
		17:
			duration = _catapult(model)
		59:
			duration = _trebuchet(model)
		13:
			duration = _warship(model, false, ship_side)
		39:
			duration = _warship(model, true, ship_side)
		_:
			reset(model)
			return false

	# 主 Tween 只负责在动作结束后兜底复位，各部件 Tween 独立运行
	var master := model.create_tween()
	master.tween_interval(duration + 0.02)
	master.tween_callback(func() -> void: _finish(model))
	_remember(model, master)
	SiegeAttackFx.play(entity_id, model, opts)
	return true

# 死亡、换目标或需要强制停止时调用；会把所有部件恢复到动画前姿态
static func reset(model: Node3D) -> void:
	if not _valid(model):
		return
	var tweens = model.get_meta(META_TWEENS, [])
	if tweens is Array:
		for tw in tweens:
			if tw is Tween and tw.is_valid():
				tw.kill()
	_restore(model)
	model.set_meta(META_RUNNING, false)
	model.set_meta(META_TWEENS, [])
	model.remove_meta(META_BASE)

static func _finish(model: Node3D) -> void:
	if not _valid(model):
		return
	_restore(model)
	model.set_meta(META_RUNNING, false)
	model.set_meta(META_TWEENS, [])
	model.remove_meta(META_BASE)

# ---------- 各兵种动作 ----------

# 攻城车：整车后拉后猛撞，撞木相对车体再向前多顶一截
static func _ram(model: Node3D) -> float:
	var pos: Vector3 = model.position
	_seq(model, model, "position", [
		{"v": pos + Vector3(0.0, 0.0, 0.72), "t": 0.16, "tr": Tween.TRANS_SINE},
		{"v": pos + Vector3(0.0, 0.04, -2.05), "t": 0.22, "tr": Tween.TRANS_EXPO, "e": Tween.EASE_IN},
		{"v": pos, "t": 0.56, "tr": Tween.TRANS_ELASTIC},
	])
	_entity_pitch(model, [
		{"a": -0.20, "t": 0.38, "tr": Tween.TRANS_QUAD},
		{"a": 0.0, "t": 0.56, "tr": Tween.TRANS_ELASTIC},
	])
	var ram := _find(model, "ram")
	if ram != null:
		var p: Vector3 = ram.position
		# 模型绕 Y 旋转 90°，局部 +X 对应实体正前方
		_seq(model, ram, "position", [
			{"v": p + Vector3(-0.14, 0.0, 0.0), "t": 0.16, "tr": Tween.TRANS_SINE},
			{"v": p + Vector3(0.58, 0.0, 0.0), "t": 0.22, "tr": Tween.TRANS_EXPO, "e": Tween.EASE_IN},
			{"v": p, "t": 0.56, "tr": Tween.TRANS_ELASTIC},
		])
	_wheels(model, 0.32)
	return 0.96

# 火炮：整炮后坐并上跳，两侧轮轴被后坐力带得急停回摆
static func _cannon(model: Node3D) -> float:
	var pos: Vector3 = model.position
	_seq(model, model, "position", [
		{"v": pos + Vector3(0.0, 0.30, 0.68), "t": 0.12, "tr": Tween.TRANS_EXPO},
		{"v": pos, "t": 0.62, "tr": Tween.TRANS_BOUNCE},
	])
	_entity_pitch(model, [
		{"a": 0.18, "t": 0.10, "tr": Tween.TRANS_EXPO},
		{"a": 0.0, "t": 0.64, "tr": Tween.TRANS_BOUNCE},
	])
	for wheel in _find_prefix(model, "Group"):
		var r: Vector3 = wheel.rotation
		_seq(model, wheel, "rotation", [
			{"v": r + Vector3(0.34, 0.0, 0.0), "t": 0.12, "tr": Tween.TRANS_QUAD},
			{"v": r, "t": 0.55, "tr": Tween.TRANS_ELASTIC},
		])
	return 0.78

# 投石车：投臂顺着出手方向甩出，随后阻尼回摆
static func _catapult(model: Node3D) -> float:
	var pos: Vector3 = model.position
	_seq(model, model, "position", [
		{"v": pos + Vector3(0.0, -0.12, 0.06), "t": 0.22, "tr": Tween.TRANS_SINE},
		{"v": pos, "t": 0.84, "tr": Tween.TRANS_ELASTIC},
	])
	_entity_pitch(model, [
		{"a": -0.10, "t": 0.20, "tr": Tween.TRANS_SINE},
		{"a": 0.0, "t": 0.86, "tr": Tween.TRANS_ELASTIC},
	])
	var arm := _find(model, "catapult")
	if arm != null:
		var rz: float = arm.rotation.z
		_seq(model, arm, "rotation:z", [
			{"v": rz - 1.08, "t": 0.18, "tr": Tween.TRANS_EXPO, "e": Tween.EASE_OUT},
			{"v": rz + 0.24, "t": 0.22, "tr": Tween.TRANS_BACK, "e": Tween.EASE_OUT},
			{"v": rz, "t": 0.64, "tr": Tween.TRANS_ELASTIC},
		])
	_wheels(model, 0.16)
	return 1.12

# 巨型投石机：配重下坠带动投臂缓慢释放，再以低频余摆收住
static func _trebuchet(model: Node3D) -> float:
	var pos: Vector3 = model.position
	_seq(model, model, "position", [
		{"v": pos + Vector3(0.0, -0.18, 0.05), "t": 0.50, "tr": Tween.TRANS_SINE},
		{"v": pos, "t": 1.18, "tr": Tween.TRANS_ELASTIC},
	])
	_entity_pitch(model, [
		{"a": -0.12, "t": 0.55, "tr": Tween.TRANS_SINE},
		{"a": 0.0, "t": 1.12, "tr": Tween.TRANS_ELASTIC},
	])
	var arm := _find(model, "arm")
	if arm != null:
		var rz: float = arm.rotation.z
		_seq(model, arm, "rotation:z", [
			{"v": rz - 1.38, "t": 0.22, "tr": Tween.TRANS_EXPO, "e": Tween.EASE_OUT},
			{"v": rz + 0.30, "t": 0.30, "tr": Tween.TRANS_BACK, "e": Tween.EASE_OUT},
			{"v": rz, "t": 1.10, "tr": Tween.TRANS_ELASTIC},
		])
	var weight := _find(model, "weight")
	if weight != null:
		var wr: Vector3 = weight.rotation
		_seq(model, weight, "rotation", [
			{"v": wr + Vector3(0.0, 0.0, 0.22), "t": 0.48, "tr": Tween.TRANS_SINE},
			{"v": wr, "t": 0.92, "tr": Tween.TRANS_ELASTIC},
		])
	_wheels(model, 0.12)
	return 1.72

# 战船/炮艇：侧舷齐射的横摇、下沉、帆布鼓起和旗帜后甩
static func _warship(model: Node3D, heavy: bool, side: float) -> float:
	var pos: Vector3 = model.position
	var rz: float = model.rotation.z
	var roll: float = 0.20 if heavy else 0.13
	var sink: float = 0.32 if heavy else 0.18
	var push: float = 0.60 if heavy else 0.36
	var total: float = 1.18 if heavy else 0.98
	_seq(model, model, "rotation:z", [
		{"v": rz + side * roll, "t": 0.18, "tr": Tween.TRANS_QUAD},
		{"v": rz - side * roll * 0.25, "t": 0.22, "tr": Tween.TRANS_SINE},
		{"v": rz, "t": 0.72 if heavy else 0.54, "tr": Tween.TRANS_ELASTIC},
	])
	# 侧舷齐射的反作用力让船向开火的反方向横移，而不是前后冲
	_seq(model, model, "position", [
		{"v": pos + Vector3(-side * push, -sink, 0.0), "t": 0.20, "tr": Tween.TRANS_QUAD},
		{"v": pos + Vector3(side * push * 0.12, sink * 0.12, 0.0), "t": 0.24, "tr": Tween.TRANS_SINE},
		{"v": pos, "t": 0.70 if heavy else 0.52, "tr": Tween.TRANS_ELASTIC},
	])
	for sail in _find_prefix(model, "sail"):
		var b: Vector3 = sail.scale
		var grow: float = 1.075 if heavy else 1.05
		_seq(model, sail, "scale", [
			{"v": b * grow, "t": 0.18, "tr": Tween.TRANS_BACK, "e": Tween.EASE_OUT},
			{"v": b, "t": 0.62 if heavy else 0.50, "tr": Tween.TRANS_ELASTIC},
		])
	var flag_index: int = 0
	for flag in _find_prefix(model, "flag"):
		var fr: Vector3 = flag.rotation
		var amp: float = 0.28 if heavy else 0.18
		_seq(model, flag, "rotation", [
			{"wait": float(flag_index) * 0.025},
			{"v": fr + Vector3(0.0, 0.0, amp), "t": 0.10, "tr": Tween.TRANS_QUAD},
			{"v": fr - Vector3(0.0, 0.0, amp * 0.28), "t": 0.14, "tr": Tween.TRANS_SINE},
			{"v": fr, "t": 0.50, "tr": Tween.TRANS_ELASTIC},
		])
		flag_index += 1
	return total

# ---------- 工具函数 ----------

static func _seq(model: Node3D, node: Node3D, prop: String, steps: Array) -> void:
	if node == null or not is_instance_valid(node):
		return
	var tw := node.create_tween()
	for step in steps:
		if step.has("wait"):
			tw.tween_interval(float(step["wait"]))
			continue
		var target = step.get("v")
		if target == null:
			continue
		var dur: float = float(step.get("t", 0.2))
		var tr: int = int(step.get("tr", Tween.TRANS_SINE))
		var ease_type: int = int(step.get("e", Tween.EASE_OUT))
		tw.tween_property(node, prop, target, dur).set_trans(tr).set_ease(ease_type)
	_remember(model, tw)

static func _wheels(model: Node3D, amount: float) -> void:
	for wheel in _find_prefix(model, "wheel"):
		var r: Vector3 = wheel.rotation
		# 这些 GLB 的车轮厚度沿局部 Z，轮轴也是 Z；绕 X 转会变成外倾摆动
		_seq(model, wheel, "rotation", [
			{"v": r + Vector3(0.0, 0.0, amount), "t": 0.16, "tr": Tween.TRANS_QUAD},
			{"v": r, "t": 0.72, "tr": Tween.TRANS_ELASTIC},
		])

# 根节点旋转：模型根带有 90°/180° 朝向修正，直接改 rotation.x 会变成侧倾。
# 这里在“实体空间”的右轴（父节点 X）上做俯仰，再与原始四元数组合。
static func _entity_pitch(model: Node3D, steps: Array) -> void:
	var base_q: Quaternion = model.quaternion
	var converted: Array = []
	for step in steps:
		var copy: Dictionary = step.duplicate()
		copy["v"] = Quaternion(Vector3.RIGHT, float(copy.get("a", 0.0))) * base_q
		copy.erase("a")
		converted.append(copy)
	_seq(model, model, "quaternion", converted)

static func _find(model: Node3D, node_name: String) -> Node3D:
	var node := model.find_child(node_name, true, false)
	return node as Node3D

static func _find_prefix(model: Node3D, prefix: String) -> Array:
	var out: Array = []
	for node in model.find_children(prefix + "*", "Node3D", true, false):
		if node is Node3D:
			out.append(node)
	return out

static func _capture(model: Node3D) -> Dictionary:
	var data: Dictionary = {}
	_store_base(data, model)
	for node in model.find_children("*", "Node3D", true, false):
		_store_base(data, node as Node3D)
	return data

static func _store_base(data: Dictionary, node: Node3D) -> void:
	if node == null or not is_instance_valid(node) or data.has(node):
		return
	data[node] = {
		"p": node.position,
		"r": node.rotation,
		"s": node.scale,
	}

static func _restore(model: Node3D) -> void:
	if not _valid(model):
		return
	var data = model.get_meta(META_BASE, {})
	if not (data is Dictionary):
		return
	for node in data.keys():
		if node is Node3D and is_instance_valid(node):
			var d: Dictionary = data[node]
			(node as Node3D).position = d.get("p", (node as Node3D).position)
			(node as Node3D).rotation = d.get("r", (node as Node3D).rotation)
			(node as Node3D).scale = d.get("s", (node as Node3D).scale)

static func _remember(model: Node3D, tw: Tween) -> void:
	var list = model.get_meta(META_TWEENS, [])
	if not (list is Array):
		list = []
	list.append(tw)
	model.set_meta(META_TWEENS, list)

static func _valid(model: Node3D) -> bool:
	return model != null and is_instance_valid(model) and model.is_inside_tree()

class_name SiegeWalkAnim
extends RefCounted

# 攻城器械的行走动画。
#
# 只驱动 GLB 内部的轮子 / 炮架节点，绝不碰实体位置或模型根节点的 transform ——
# 攻击动画（SiegeAttackAnim）改的是根节点 position / quaternion，
# 两者写同一属性就会互相覆盖，所以这里刻意只动子节点。
#
# 单机 RTSBattleManager 与联机 ClientRenderer 共用同一份实现，保证两端手感一致。

const WALK_IDS := [16, 17, 18, 59]
const META_ROLL := "_siege_walk_roll"

# 轮子半径（模型局部的近似值，缩放前）：弧度 = 前进距离 / 半径。
# 用距离累加而不是「速度 × 时间」，速度骤变时滚动相位不会跳。
const WHEEL_RADIUS: float = 0.28

static func is_walker(entity_id: int) -> bool:
	return entity_id in WALK_IDS

# speed: 当前水平移动速度（米/秒），0 表示静止。
# 静止时只把轮子停在当前角度，不再逐帧写属性。
static func update(model: Node3D, entity_id: int, delta: float, speed: float) -> void:
	if not is_walker(entity_id) or not _valid(model):
		return
	# 攻击动画进行中让位：它会 tween 轮子/炮架，这里再写就打架了
	if bool(model.get_meta(SiegeAttackAnim.META_RUNNING, false)):
		return

	var roll: float = float(model.get_meta(META_ROLL, 0.0))
	if speed > 0.02:
		roll = fposmod(roll + speed * delta / WHEEL_RADIUS, TAU)
		model.set_meta(META_ROLL, roll)
	elif roll <= 0.001:
		# 完全没动过就不做任何写入
		return

	if entity_id == 16:
		# 火炮模型（cannon.glb）没有 wheel 节点，只有两根炮架腿 Group / Group2，
		# 用它们交替前后摆动表现“被拖着走”
		_cannon_legs(model, roll, speed)
	else:
		_roll_wheels(model, roll, speed)

static func _roll_wheels(model: Node3D, roll: float, speed: float) -> void:
	var wheels := _find_prefix(model, "wheel")
	if wheels.is_empty():
		return
	# 这几个 GLB 的车轮厚度沿局部 Z、轮轴也是 Z，绕 Z 转才是滚动；
	# 绕 X 会变成外倾摆动（攻击动画里已经踩过这个坑）
	for wheel in wheels:
		(wheel as Node3D).rotation.z = _base_axis(model, wheel) + roll

static func _cannon_legs(model: Node3D, roll: float, speed: float) -> void:
	var legs := _find_prefix(model, "Group")
	if legs.is_empty():
		return
	var index := 0
	for leg in legs:
		var dir: float = 1.0 if index % 2 == 0 else -1.0
		var swing: float = 0.0
		if speed > 0.02:
			# 摆幅随速度线性增大，停下时自然归零
			swing = dir * sin(roll * 2.4) * clampf(speed * 0.10, 0.015, 0.06)
		(leg as Node3D).rotation.z = _base_axis(model, leg) + swing
		index += 1

# 记住每个节点「未被动画驱动时」的 Z 旋转，行走动画在它基础上叠加。
# 键里带实例 id：同一份模型可能同时挂在多个实体上。
static func _base_axis(model: Node3D, node: Node3D) -> float:
	var key := "_siege_walk_bz_%d" % node.get_instance_id()
	if model.has_meta(key):
		return float(model.get_meta(key))
	var base: float = node.rotation.z
	model.set_meta(key, base)
	return base

static func _find_prefix(model: Node3D, prefix: String) -> Array:
	var out: Array = []
	for node in model.find_children(prefix + "*", "Node3D", true, false):
		if node is Node3D:
			out.append(node)
	return out

static func _valid(model: Node3D) -> bool:
	return model != null and is_instance_valid(model) and model.is_inside_tree()

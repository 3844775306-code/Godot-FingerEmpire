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

# 轮子半径（GLB 局部坐标）：实测各轮 mesh 的 AABB 是 0.4028 × 0.4028 × 0.1332，
# 即半径 0.2014、厚度 0.1332、盘面法线沿局部 Z —— 轮轴就是局部 Z。
const WHEEL_RADIUS: float = 0.2014

static func is_walker(entity_id: int) -> bool:
	return entity_id in WALK_IDS

# speed: 当前水平移动速度（世界米/秒），0 表示静止。
static func update(model: Node3D, entity_id: int, delta: float, speed: float) -> void:
	if not is_walker(entity_id) or not _valid(model):
		return
	# 攻击动画进行中让位：它会 tween 轮子/炮架，这里再写就打架了
	if bool(model.get_meta(SiegeAttackAnim.META_RUNNING, false)):
		return

	var roll: float = float(model.get_meta(META_ROLL, 0.0))
	if speed > 0.02:
		# 模型根节点在 _apply_entity_model 里被缩放成实体大小，
		# 世界速度要折算回模型局部才发现「滚过的距离 / 轮半径」是多少弧度
		var model_scale: float = absf(model.scale.x)
		if model_scale < 0.01:
			model_scale = 1.0
		roll = fposmod(roll + speed * delta / (WHEEL_RADIUS * model_scale), TAU)
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
	# 这几个 GLB 的车轮盘面在局部 XY、轮轴沿局部 Z，绕 Z 才是滚动；
	# 绕 X 会变成外倾摆动（攻击动画里已经踩过这个坑）。
	for wheel in wheels:
		_spin_wheel(model, wheel as Node3D, roll)

# 让轮子绕「网格几何中心」转，而不是绕节点原点转。
#
# 关键点：ram.glb（攻城车）的 6 个轮子网格中心在 (−0.2014, +0.2014, +0.0666)，
# 根本不在节点原点上。直接改 rotation.z 相当于让轮子绕自己边缘的一个点公转，
# 会甩出车体画大圈 —— 视觉上就是“转轴不对”。catapult / trebuchet 的轮子中心
# 恰好是原点，补偿量为零，所以这套算法对三者都适用。
static func _spin_wheel(model: Node3D, wheel: Node3D, angle: float) -> void:
	var base_z: float = _base_axis(model, wheel)
	var pivot: Vector3 = _mesh_center(model, wheel)
	wheel.rotation.z = base_z + angle
	if pivot.length_squared() < 0.000001:
		return
	# 想让网格绕过 pivot 的轴旋转：position 必须补上「pivot − R(θ)·pivot」
	var spun: Vector3 = pivot.rotated(Vector3.BACK, base_z + angle)
	wheel.position = _base_position(model, wheel) + (pivot - spun)

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

# ---------- 基线缓存 ----------
# 攻击动画会临时改这些值，行走动画必须始终基于「未被动画驱动时」的原始值叠加。
# 键里带实例 id：同一份模型可能同时挂在多个实体上。

static func _base_axis(model: Node3D, node: Node3D) -> float:
	var key := "_siege_walk_bz_%d" % node.get_instance_id()
	if model.has_meta(key):
		return float(model.get_meta(key))
	var base: float = node.rotation.z
	model.set_meta(key, base)
	return base

static func _base_position(model: Node3D, node: Node3D) -> Vector3:
	var key := "_siege_walk_bp_%d" % node.get_instance_id()
	if model.has_meta(key):
		return model.get_meta(key)
	var base: Vector3 = node.position
	model.set_meta(key, base)
	return base

# 网格几何中心相对节点原点的偏移（模型局部坐标）。缓存一次，避免每帧重算 AABB。
static func _mesh_center(model: Node3D, node: Node3D) -> Vector3:
	var key := "_siege_walk_bc_%d" % node.get_instance_id()
	if model.has_meta(key):
		return model.get_meta(key)
	var center := Vector3.ZERO
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null:
			var aabb: AABB = mi.mesh.get_aabb()
			center = aabb.position + aabb.size * 0.5
	model.set_meta(key, center)
	return center

static func _find_prefix(model: Node3D, prefix: String) -> Array:
	var out: Array = []
	for node in model.find_children(prefix + "*", "Node3D", true, false):
		if node is Node3D:
			out.append(node)
	return out

static func _valid(model: Node3D) -> bool:
	return model != null and is_instance_valid(model) and model.is_inside_tree()

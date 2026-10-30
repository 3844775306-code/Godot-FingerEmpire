class_name SupportCartAnim
extends RefCounted

# 木牛流马的车轮/车斗动画；手推车/贸易车也复用这里的车轮滚动。
# 牛腿由 animal-cow.glb 自带的 AnimationPlayer 播放 walk / idle；
# 这里只驱动挂车上的木轮和轻微颠簸，避免和牛骨动画抢节点。

const SUPPORT_ID := 33
const CART_IDS := [5, 6]
const CART_NODE := "Cart"
const META_ROLL := "_support_cart_roll"
const WHEEL_RADIUS := 0.23

static func is_support(entity_id: int) -> bool:
	return entity_id == SUPPORT_ID

static func is_simple_cart(entity_id: int) -> bool:
	return entity_id in CART_IDS

static func update(model: Node3D, delta: float, speed: float, entity_id: int = -1) -> void:
	if not _valid(model):
		return
	if is_simple_cart(entity_id):
		_update_simple_cart(model, delta, speed)
		return
	var cart := model.get_node_or_null(CART_NODE) as Node3D
	if cart == null:
		return
	var roll: float = float(model.get_meta(META_ROLL, 0.0))
	if speed > 0.02:
		var model_scale: float = absf(model.scale.x)
		if model_scale < 0.01:
			model_scale = 1.0
		roll = fposmod(roll + speed * delta / (0.21 * model_scale), TAU)
		model.set_meta(META_ROLL, roll)
	elif absf(roll) < 0.001:
		return
	_spin_wheels(model, cart, roll)
	_bob_cart(model, cart, roll, speed)

# 手推车/贸易车模型没有 AnimationPlayer，也没有 Cart 子节点；
# 顶层就是车身，两个 Group 是左右车轮。按位移滚动轮子，消除“贴地滑行”感。
static func _update_simple_cart(model: Node3D, delta: float, speed: float) -> void:
	var model_scale: float = absf(model.scale.x)
	if model_scale < 0.01:
		model_scale = 1.0
	var roll: float = float(model.get_meta(META_ROLL, 0.0))
	if speed > 0.02:
		roll = fposmod(roll + speed * delta / (WHEEL_RADIUS * model_scale), TAU)
		model.set_meta(META_ROLL, roll)
	elif absf(roll) < 0.001:
		return
	_spin_wheels(model, model, roll)

static func _spin_wheels(model: Node3D, cart: Node3D, roll: float) -> void:
	for wheel in cart.find_children("Group*", "MeshInstance3D", true, false):
		if wheel is not Node3D:
			continue
		_spin_wheel(model, wheel as Node3D, roll)

static func _spin_wheel(model: Node3D, wheel: Node3D, angle: float) -> void:
	var base_x: float = _base_rotation_x(model, wheel)
	var pivot: Vector3 = _mesh_center(model, wheel)
	wheel.rotation.x = base_x + angle
	if pivot.length_squared() < 0.000001:
		return
	var spun: Vector3 = pivot.rotated(Vector3.RIGHT, base_x + angle)
	wheel.position = _base_position(model, wheel) + (pivot - spun)

static func _bob_cart(model: Node3D, cart: Node3D, roll: float, speed: float) -> void:
	var amp: float = clampf(speed * 0.012, 0.0, 0.035)
	cart.position.y = _base_cart_y(model, cart) + sin(roll * 1.6) * amp
	cart.rotation.z = _base_cart_roll(model, cart) + sin(roll * 0.8) * amp * 0.35

static func _base_rotation_x(model: Node3D, node: Node3D) -> float:
	var key := "_support_cart_bx_%d" % node.get_instance_id()
	if model.has_meta(key):
		return float(model.get_meta(key))
	var base: float = node.rotation.x
	model.set_meta(key, base)
	return base

static func _base_position(model: Node3D, node: Node3D) -> Vector3:
	var key := "_support_cart_bp_%d" % node.get_instance_id()
	if model.has_meta(key):
		return model.get_meta(key)
	var base: Vector3 = node.position
	model.set_meta(key, base)
	return base

static func _base_cart_y(model: Node3D, cart: Node3D) -> float:
	var key := "_support_cart_by_%d" % cart.get_instance_id()
	if model.has_meta(key):
		return float(model.get_meta(key))
	var base: float = cart.position.y
	model.set_meta(key, base)
	return base

static func _base_cart_roll(model: Node3D, cart: Node3D) -> float:
	var key := "_support_cart_br_%d" % cart.get_instance_id()
	if model.has_meta(key):
		return float(model.get_meta(key))
	var base: float = cart.rotation.z
	model.set_meta(key, base)
	return base

static func _mesh_center(model: Node3D, node: Node3D) -> Vector3:
	var key := "_support_cart_bc_%d" % node.get_instance_id()
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

static func _valid(model: Node3D) -> bool:
	return model != null and is_instance_valid(model) and model.is_inside_tree()

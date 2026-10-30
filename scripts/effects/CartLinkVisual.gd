class_name CartLinkVisual
extends Node3D

# 农民/商人和手推车/贸易车之间的可见连接件。
# 服务端单机和联机客户端都挂同一个脚本，保证两边看到的是同一套“牵引杆”。
const NODE_NAME := "CartLinkVisual"
const HANDCART_ID := 5
const TRADE_CART_ID := 6
const HIDE_DISTANCE := 5.5

var owner_node: Node3D = null
var cart_eid: int = 0
var _bars: Array[MeshInstance3D] = []
var _bar_material: StandardMaterial3D

static func ensure(cart: Node3D, owner: Node3D, eid: int) -> void:
	if cart == null or owner == null or not is_instance_valid(cart) or not is_instance_valid(owner):
		return
	var link = cart.get_node_or_null(NODE_NAME) as CartLinkVisual
	if link == null:
		link = CartLinkVisual.new()
		link.name = NODE_NAME
		cart.add_child(link)
	link.setup(owner, eid)

static func remove(cart: Node3D) -> void:
	if cart == null or not is_instance_valid(cart):
		return
	var link = cart.get_node_or_null(NODE_NAME)
	if link != null:
		link.queue_free()

func setup(owner: Node3D, eid: int) -> void:
	owner_node = owner
	if cart_eid == eid and not _bars.is_empty():
		return
	cart_eid = eid
	_rebuild()

func _rebuild() -> void:
	for bar in _bars:
		if is_instance_valid(bar):
			bar.queue_free()
	_bars.clear()
	if _bar_material == null:
		_bar_material = StandardMaterial3D.new()
		_bar_material.albedo_color = Color(0.36, 0.21, 0.10)
		_bar_material.roughness = 0.88
	var count := 2 if cart_eid == HANDCART_ID else 1
	for i in range(count):
		var bar := MeshInstance3D.new()
		var mesh := CylinderMesh.new()
		mesh.top_radius = 0.024
		mesh.bottom_radius = 0.024
		mesh.height = 1.0
		mesh.radial_segments = 6
		mesh.rings = 1
		bar.mesh = mesh
		bar.material_override = _bar_material
		bar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		bar.top_level = true
		add_child(bar)
		_bars.append(bar)

func _process(_delta: float) -> void:
	var cart := get_parent() as Node3D
	if cart == null or owner_node == null or not is_instance_valid(cart) or not is_instance_valid(owner_node):
		visible = false
		return
	if not cart.visible:
		visible = false
		return
	if owner_node is GameEntity and (owner_node as GameEntity).health <= 0:
		visible = false
		return
	if not owner_node.visible:
		visible = false
		return
	if cart.global_position.distance_to(owner_node.global_position) > HIDE_DISTANCE:
		visible = false
		return
	visible = true

	var cart_basis := cart.global_transform.basis
	var owner_basis := owner_node.global_transform.basis
	var cart_forward := -cart_basis.z
	cart_forward.y = 0.0
	if cart_forward.length_squared() < 0.001:
		cart_forward = Vector3.FORWARD
	cart_forward = cart_forward.normalized()
	var owner_forward := -owner_basis.z
	owner_forward.y = 0.0
	if owner_forward.length_squared() < 0.001:
		owner_forward = Vector3.FORWARD
	owner_forward = owner_forward.normalized()
	var owner_right := owner_basis.x
	owner_right.y = 0.0
	if owner_right.length_squared() < 0.001:
		owner_right = Vector3.RIGHT
	owner_right = owner_right.normalized()

	# 连接件接车身上离主人最近的一端：不依赖 cart.glb 的车头朝向，
	# 手推车在前/贸易车在后都能自动找到靠主人那一侧的扶手。
	var owner_anchor_forward := 0.10 if cart_eid == HANDCART_ID else -0.12
	var count := _bars.size()
	for i in range(count):
		var side := 0.0
		if count > 1:
			side = -0.22 if i == 0 else 0.22
		var owner_anchor: Vector3 = owner_node.global_position + Vector3(0.0, 0.58, 0.0) + owner_forward * owner_anchor_forward + owner_right * (side * 0.65)
		var cart_end_a := cart.to_global(Vector3(side, 0.52, 0.55))
		var cart_end_b := cart.to_global(Vector3(side, 0.52, -0.55))
		var cart_anchor := cart_end_a if cart_end_a.distance_to(owner_anchor) <= cart_end_b.distance_to(owner_anchor) else cart_end_b
		_place_bar(_bars[i], cart_anchor, owner_anchor)

func _place_bar(bar: MeshInstance3D, a: Vector3, b: Vector3) -> void:
	var d := b - a
	var length := d.length()
	if length < 0.16:
		bar.visible = false
		return
	bar.visible = true
	var y_axis := d / length
	var reference := Vector3.UP
	if absf(y_axis.dot(Vector3.UP)) > 0.98:
		reference = Vector3.RIGHT
	var x_axis := reference.cross(y_axis).normalized()
	var z_axis := x_axis.cross(y_axis).normalized()
	bar.global_transform = Transform3D(Basis(x_axis, y_axis, z_axis), (a + b) * 0.5)
	bar.scale = Vector3(1.0, length, 1.0)

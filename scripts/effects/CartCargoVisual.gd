class_name CartCargoVisual
extends Node3D

# 车斗里的货物：按农民背包/商人本轮贸易量生成最多 8 件小货物。
# 只做数量与资源颜色的视觉映射，精确数值仍以信息面板为准。
const NODE_NAME := "CartCargoVisual"
const MAX_PIECES := 8
const MERCHANT_MAX_CARGO := 260.0
const HANDCART_ID := 5
const TRADE_CART_ID := 6

const SLOT_POSITIONS := [
	Vector3(-0.20, 0.42, -0.27),
	Vector3(0.00, 0.42, -0.27),
	Vector3(0.20, 0.42, -0.27),
	Vector3(-0.20, 0.42, 0.00),
	Vector3(0.00, 0.42, 0.00),
	Vector3(0.20, 0.42, 0.00),
	Vector3(-0.20, 0.42, 0.27),
	Vector3(0.20, 0.42, 0.27),
]

var _last_total: int = -1
var _last_max: int = -1
var _last_resources: Dictionary = {}

static func update_from_owner(cart: Node3D, owner: Node3D) -> void:
	if cart == null or not is_instance_valid(cart):
		return
	if owner == null or not is_instance_valid(owner):
		hide_cargo(cart)
		return
	update(cart, payload_for_owner(int(cart.get("entity_id")), owner))

static func update(cart: Node3D, payload: Dictionary) -> void:
	if cart == null or not is_instance_valid(cart):
		return
	var total := int(payload.get("cargo_total", 0))
	var max_total := int(payload.get("cargo_max", 0))
	var resources: Dictionary = payload.get("cargo_resources", {})
	if total <= 0 or resources.is_empty():
		hide_cargo(cart)
		return
	var visual := ensure(cart)
	visual._sync(total, max_total, resources)

static func hide_cargo(cart: Node3D) -> void:
	if cart == null or not is_instance_valid(cart):
		return
	var visual := _find_visual(cart)
	if visual != null:
		visual.visible = false

static func ensure(cart: Node3D) -> CartCargoVisual:
	var host: Node3D = cart
	var model = cart.get_meta("_model_instance", null)
	if model is Node3D:
		host = model as Node3D
	var existing := host.get_node_or_null(NODE_NAME)
	if existing is CartCargoVisual:
		return existing as CartCargoVisual
	if existing != null:
		host.remove_child(existing)
		existing.queue_free()
	var visual := CartCargoVisual.new()
	visual.name = NODE_NAME
	host.add_child(visual)
	return visual

static func _find_visual(cart: Node3D) -> CartCargoVisual:
	var model = cart.get_meta("_model_instance", null)
	var hosts: Array[Node] = [cart]
	if model is Node3D:
		hosts.append(model as Node3D)
	for host in hosts:
		var node := host.get_node_or_null(NODE_NAME)
		if node is CartCargoVisual:
			return node as CartCargoVisual
	return null

# 商人没有实体背包，货物数量直接跟随信息面板里的「本轮交易量」：
# 去市场（state 2）车里是金币，其余阶段是采购/经营的资源。
static func payload_for_owner(cart_eid: int, owner: Node3D) -> Dictionary:
	if owner == null or not is_instance_valid(owner):
		return {}
	if cart_eid == TRADE_CART_ID:
		var state := int(owner.get("_merchant_state"))
		var volume := int(owner.get("_merchant_trade_volume"))
		var resource := str(owner.get("_merchant_resource"))
		if volume <= 0:
			return {}
		if state == 2:
			resource = "gold"
		elif resource == "":
			resource = "food"
		return {
			"cargo_total": volume,
			"cargo_max": int(MERCHANT_MAX_CARGO),
			"cargo_resources": {resource: volume},
		}
	var total := 0
	var resources: Dictionary = {}
	if owner.get("cargo") is Dictionary:
		resources = (owner.get("cargo") as Dictionary).duplicate()
	for value in resources.values():
		total += int(value)
	if total <= 0:
		return {}
	return {
		"cargo_total": total,
		"cargo_max": int(owner.get("max_cargo")),
		"cargo_resources": resources,
	}

func _sync(total: int, max_total: int, resources: Dictionary) -> void:
	if total == _last_total and max_total == _last_max and resources == _last_resources and get_child_count() > 0:
		visible = true
		return
	_last_total = total
	_last_max = max_total
	_last_resources = resources.duplicate()
	_rebuild(total, max_total, resources)

func _rebuild(total: int, max_total: int, resources: Dictionary) -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	var ratio := 1.0
	if max_total > 0:
		ratio = clampf(float(total) / float(max_total), 0.0, 1.0)
	var count := clampi(ceili(ratio * float(MAX_PIECES)), 1, MAX_PIECES)
	var colors := _resource_slots(resources, count, total)
	var cargo_y := 0.48 if _cart_entity_id() == HANDCART_ID else 0.70
	for i in range(count):
		var piece := _make_piece(colors[i])
		piece.position = SLOT_POSITIONS[i] + Vector3(0.0, cargo_y - 0.42, 0.0)
		add_child(piece)
	visible = true

func _cart_entity_id() -> int:
	var node := get_parent()
	while node != null:
		if node.has_meta("snapshot_info"):
			return int((node.get_meta("snapshot_info") as Dictionary).get("entity_id", 0))
		if node.has_method("get_cart_owner_id"):
			return int(node.get("entity_id"))
		node = node.get_parent()
	return 0

# 把总量按比例分配到各个槽位，资源混合时仍能看出主要货物类型。
static func _resource_slots(resources: Dictionary, count: int, total: int) -> Array:
	var entries: Array = []
	for key in ["gold", "wood", "stone", "food", "oil"]:
		var amount := int(resources.get(key, 0))
		if amount > 0:
			entries.append([key, amount])
	var colors: Array = []
	if entries.is_empty() or total <= 0:
		for i in range(count):
			colors.append(Color(0.55, 0.45, 0.30))
		return colors
	var cumulative := 0
	var entry_index := 0
	for i in range(count):
		var target := (float(i) + 0.5) * float(total) / float(count)
		while entry_index < entries.size() - 1 and target > float(cumulative + int(entries[entry_index][1])):
			cumulative += int(entries[entry_index][1])
			entry_index += 1
		colors.append(_resource_color(str(entries[entry_index][0])))
	return colors

static func _resource_color(resource: String) -> Color:
	match resource:
		"gold":
			return Color(0.95, 0.76, 0.20)
		"wood":
			return Color(0.38, 0.22, 0.10)
		"stone":
			return Color(0.55, 0.57, 0.60)
		"food":
			return Color(0.32, 0.62, 0.24)
		"oil":
			return Color(0.12, 0.13, 0.15)
		_:
			return Color(0.55, 0.45, 0.30)

static func _make_piece(color: Color) -> MeshInstance3D:
	var piece := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.085
	mesh.height = 0.16
	mesh.radial_segments = 8
	mesh.rings = 4
	piece.mesh = mesh
	piece.scale = Vector3(1.0, 0.72, 1.12)
	piece.material_override = _make_material(color)
	piece.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return piece

static func _make_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.8
	mat.metallic = 0.1 if color.r > 0.7 and color.g > 0.5 else 0.0
	return mat

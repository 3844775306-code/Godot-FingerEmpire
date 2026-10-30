class_name FarmerBackpackVisual
extends Node3D

# 农民背后的低多边形行囊：皮革背包 + 顶部铺盖卷 + 背带/扣具。
# 挂在 torso 骨骼上，跟随身体动画，不参与队伍色染色（由调用时机保证）。
const EID_FARMER := 10
const NODE_NAME := "FarmerBackpack"
const BONE_NAME := "torso"

const LEATHER := Color(0.34, 0.21, 0.12)
const LEATHER_DARK := Color(0.20, 0.12, 0.065)
const CANVAS := Color(0.57, 0.47, 0.30)
const METAL := Color(0.78, 0.60, 0.24)

static func attach(entity: Node3D, entity_id: int) -> void:
	if entity == null or not is_instance_valid(entity) or entity_id != EID_FARMER:
		return
	if entity.has_meta("_farmer_backpack") and is_instance_valid(entity.get_meta("_farmer_backpack")):
		return
	var model := _find_model(entity)
	if model == null:
		return
	var skeleton := _find_skeleton(model)
	if skeleton != null and skeleton.find_bone(BONE_NAME) >= 0:
		var attachment := BoneAttachment3D.new()
		attachment.name = NODE_NAME + "Bone"
		attachment.bone_name = BONE_NAME
		skeleton.add_child(attachment)
		var root := _build_root()
		root.position = Vector3(0.0, 0.02, -0.165)
		attachment.add_child(root)
		entity.set_meta("_farmer_backpack", attachment)
		return
	# 极端兜底：没有骨骼时挂在模型背后，至少不会消失。
	var fallback := _build_root()
	fallback.position = Vector3(0.0, 0.18, -0.22)
	model.add_child(fallback)
	entity.set_meta("_farmer_backpack", fallback)

static func _build_root() -> Node3D:
	var root := Node3D.new()
	root.name = NODE_NAME

	# 主袋：稍微压扁的椭圆，低面数，和角色模型的低多边形风格一致。
	var bag := MeshInstance3D.new()
	var bag_mesh := SphereMesh.new()
	bag_mesh.radius = 0.125
	bag_mesh.height = 0.30
	bag_mesh.radial_segments = 8
	bag_mesh.rings = 5
	bag.mesh = bag_mesh
	bag.scale = Vector3(1.0, 0.92, 0.68)
	bag.position = Vector3(0.0, 0.0, 0.0)
	bag.material_override = _material(LEATHER, 0.86)
	root.add_child(bag)

	# 背包盖：向后翻的一小片深色皮革。
	var flap := MeshInstance3D.new()
	var flap_mesh := BoxMesh.new()
	flap_mesh.size = Vector3(0.225, 0.095, 0.018)
	flap.mesh = flap_mesh
	flap.position = Vector3(0.0, 0.105, -0.088)
	flap.rotation.x = deg_to_rad(-8.0)
	flap.material_override = _material(LEATHER_DARK, 0.90)
	root.add_child(flap)

	# 顶部铺盖卷：横放在背包上方。
	var roll := MeshInstance3D.new()
	var roll_mesh := CylinderMesh.new()
	roll_mesh.top_radius = 0.043
	roll_mesh.bottom_radius = 0.043
	roll_mesh.height = 0.24
	roll_mesh.radial_segments = 8
	roll.mesh = roll_mesh
	roll.rotation.z = deg_to_rad(90.0)
	roll.position = Vector3(0.0, 0.185, 0.01)
	roll.material_override = _material(CANVAS, 0.92)
	root.add_child(roll)

	# 两条背带：从袋背向上延伸，视觉上把背包挂在肩上。
	for side in [-1.0, 1.0]:
		var strap := MeshInstance3D.new()
		var strap_mesh := BoxMesh.new()
		strap_mesh.size = Vector3(0.030, 0.255, 0.012)
		strap.mesh = strap_mesh
		strap.position = Vector3(0.083 * side, 0.075, -0.086)
		strap.material_override = _material(LEATHER_DARK, 0.92)
		root.add_child(strap)

	# 袋盖扣具：小金属扣。
	var buckle := MeshInstance3D.new()
	var buckle_mesh := BoxMesh.new()
	buckle_mesh.size = Vector3(0.040, 0.032, 0.012)
	buckle.mesh = buckle_mesh
	buckle.position = Vector3(0.0, 0.073, -0.103)
	buckle.material_override = _material(METAL, 0.45, 0.55)
	root.add_child(buckle)

	# 侧边小袋，让轮廓不只是一个圆球。
	var pouch := MeshInstance3D.new()
	var pouch_mesh := BoxMesh.new()
	pouch_mesh.size = Vector3(0.060, 0.105, 0.070)
	pouch.mesh = pouch_mesh
	pouch.position = Vector3(-0.138, -0.035, 0.006)
	pouch.material_override = _material(LEATHER_DARK, 0.88)
	root.add_child(pouch)

	return root

static func _material(color: Color, roughness: float, metallic: float = 0.0) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = roughness
	mat.metallic = metallic
	return mat

static func _find_model(entity: Node3D) -> Node3D:
	if entity.has_meta("_model_instance"):
		var cached = entity.get_meta("_model_instance")
		if cached is Node3D and is_instance_valid(cached):
			return cached as Node3D
	for child in entity.get_children():
		if child is Node3D:
			var found := _find_model(child)
			if found != null:
				return found
	return null

static func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D
	for child in node.get_children():
		var found := _find_skeleton(child)
		if found != null:
			return found
	return null

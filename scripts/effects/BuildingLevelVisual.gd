class_name BuildingLevelVisual
extends RefCounted

# 建筑等级外观：不依赖新的 GLB，用程序化旗帜、底座色环和等级徽章区分 Lv.1～Lv.5。
# 单机服务端和联机客户端共用同一套生成逻辑，避免两边看起来不一致。
#
# 设计约束：
# - 只挂在建筑实体下，不挂到 GLB 根节点下，避免被 _apply_team_tint 递归染色；
# - 城墙、桥、梯子、墙顶炮台不挂装饰，否则每段墙都插旗会很乱，也会干扰拼接；
# - 升级时整组重建，节点名固定，方便服务端和客户端反复刷新。

const NODE_NAME := "LevelVisual"
# 城墙(27)、墙顶炮台(64)、桥(7)、梯子(8)：构件太多或与地形拼接，不显示等级装饰。
const EXCLUDE_IDS := [7, 8, 27, 64]

# 五个等级的主色：石灰、青铜、白银、黄金、紫金。
const TIER_COLORS := [
	Color(0.62, 0.60, 0.54),
	Color(0.76, 0.48, 0.27),
	Color(0.78, 0.84, 0.90),
	Color(0.96, 0.73, 0.24),
	Color(0.68, 0.42, 0.96),
]

# 每级旗帜位置（以建筑中心为原点，按模型水平半径比例缩放）。
# 数量严格等于等级：Lv.1 一面、Lv.2 两面……Lv.5 五面。
const FLAG_SLOTS := [
	[Vector2(0.0, 1.0)],
	[Vector2(-0.78, 0.62), Vector2(0.78, 0.62)],
	[Vector2(0.0, 1.0), Vector2(-0.78, 0.62), Vector2(0.78, 0.62)],
	[Vector2(0.0, 1.0), Vector2(-0.78, 0.62), Vector2(0.78, 0.62), Vector2(-0.92, -0.42)],
	[Vector2(0.0, 1.0), Vector2(-0.78, 0.62), Vector2(0.78, 0.62), Vector2(-0.92, -0.42), Vector2(0.92, -0.42)],
]

const FLAG_CLOTH_SIZE := Vector2(0.40, 0.25)
const FLAG_POLE_RADIUS := 0.035
static var _MATERIAL_CACHE: Dictionary = {}

static func apply(building: Node3D, level: int, fallback_radius: float = 0.0, team_color: Color = Color.WHITE, visible: bool = true) -> void:
	if building == null or not is_instance_valid(building):
		return
	var eid := _entity_id_of(building)
	if eid in EXCLUDE_IDS:
		return
	level = clampi(level, 1, 5)

	# 先移除旧装饰。queue_free 同帧不会立即释放，直接 remove_child 更稳，
	# 否则新节点会和旧节点重名，Godot 自动改名成 LevelVisual2。
	var old := building.get_node_or_null(NODE_NAME)
	if old != null:
		building.remove_child(old)
		old.queue_free()

	var bounds := _visual_bounds(building)
	var radius := fallback_radius
	if bounds.size.x > 0.01 and bounds.size.z > 0.01:
		radius = maxf(radius, maxf(bounds.size.x, bounds.size.z) * 0.5)
	radius = clampf(radius, 0.55, 24.0)
	var top := bounds.end.y
	if top < 0.2:
		top = 1.8
	var center := bounds.get_center() if bounds.size.x > 0.01 else Vector3.ZERO

	var color: Color = TIER_COLORS[level - 1]
	var root := Node3D.new()
	root.name = NODE_NAME
	root.visible = visible
	building.add_child(root)

	_add_base_ring(root, radius, color, level)
	_add_flags(root, radius, top, team_color, level)
	_add_level_badge(root, center, top, color, level)
	if level >= 5:
		_add_max_level_glow(root, radius, color)

	building.set_meta("_level_visual_level", level)

static func set_visible(building: Node3D, visible: bool) -> void:
	if building == null or not is_instance_valid(building):
		return
	var node := building.get_node_or_null(NODE_NAME)
	if node is Node3D:
		(node as Node3D).visible = visible

static func remove(building: Node3D) -> void:
	if building == null or not is_instance_valid(building):
		return
	var node := building.get_node_or_null(NODE_NAME)
	if node != null:
		building.remove_child(node)
		node.queue_free()

static func _entity_id_of(building: Node3D) -> int:
	var prop = building.get("entity_id")
	if prop != null:
		return int(prop)
	return int(building.get_meta("_entity_id", -1))

# 计算模型在建筑实体局部空间中的 AABB。不能用 global_transform：
# 联机客户端在 _create_entity_node 里调用时，节点还没加入场景树。
static func _visual_bounds(building: Node3D) -> AABB:
	var model = building.get_meta("_model_instance", null) if building.has_meta("_model_instance") else null
	if model is Node3D and is_instance_valid(model):
		var bounds := _collect_bounds(model as Node3D, Transform3D.IDENTITY, AABB(Vector3.ZERO, Vector3.ZERO))
		if bounds.size.x >= 0.0 and bounds.size.y >= 0.0 and bounds.size.z >= 0.0:
			return bounds
	return AABB(Vector3.ZERO, Vector3.ZERO)

static func _collect_bounds(node: Node3D, parent_xf: Transform3D, box: AABB) -> AABB:
	var xf := parent_xf * node.transform
	var out := box
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh != null:
			var mesh_aabb := mesh_instance.mesh.get_aabb()
			for i in range(8):
				out = out.expand(xf * mesh_aabb.get_endpoint(i))
	for child in node.get_children():
		if child is Node3D:
			out = _collect_bounds(child as Node3D, xf, out)
	return out

static func _add_flags(root: Node3D, radius: float, top: float, team_color: Color, level: int) -> void:
	var slots: Array = FLAG_SLOTS[level - 1]
	# 旗杆插在屋顶边缘而不是地面上：城墙/城堡等高大建筑如果只到腰高，
	# 后排旗帜会被建筑主体完全挡住，等级数量就看不出来了。
	var flag_base_y := maxf(top - 0.35, 0.0)
	var pole_h := clampf(0.62 + top * 0.28, 0.9, 2.4)
	var cloth_color := team_color.lerp(Color.WHITE, 0.12)
	var pole_mat := _mat("level_flag_pole", Color(0.25, 0.19, 0.13), 0.0, 0.6)
	var cloth_mat := _mat("level_flag_cloth_%s" % cloth_color.to_html(), cloth_color, 0.0, 0.75)
	# 旗帜如果固定朝外，侧面和背面看过去会变成一条线，数不出数量；
	# 布料改成正对相机、双面不剔除，旗杆仍保持立体。
	cloth_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cloth_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	cloth_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	for slot in slots:
		var slot_vec: Vector2 = slot
		var xz := Vector2(slot_vec.x * radius, slot_vec.y * radius)
		var flag_root := Node3D.new()
		flag_root.position = Vector3(xz.x, flag_base_y, xz.y)
		# 让旗帜的 +X 方向朝外，避免旗帜穿进建筑主体。
		flag_root.rotation.y = atan2(-xz.y, xz.x)
		root.add_child(flag_root)

		var pole := MeshInstance3D.new()
		var pole_mesh := CylinderMesh.new()
		pole_mesh.top_radius = FLAG_POLE_RADIUS
		pole_mesh.bottom_radius = FLAG_POLE_RADIUS * 1.25
		pole_mesh.height = pole_h
		pole_mesh.radial_segments = 6
		pole_mesh.rings = 1
		pole.mesh = pole_mesh
		pole.position.y = pole_h * 0.5
		pole.material_override = pole_mat
		pole.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		flag_root.add_child(pole)

		var cloth := MeshInstance3D.new()
		var cloth_mesh := QuadMesh.new()
		cloth_mesh.size = FLAG_CLOTH_SIZE
		cloth_mesh.orientation = PlaneMesh.FACE_Z
		cloth.mesh = cloth_mesh
		cloth.position = Vector3(FLAG_CLOTH_SIZE.x * 0.5 + 0.02, pole_h - FLAG_CLOTH_SIZE.y * 0.55, 0.0)
		cloth.material_override = cloth_mat
		cloth.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		flag_root.add_child(cloth)

static func _add_base_ring(root: Node3D, radius: float, color: Color, level: int) -> void:
	var ring := MeshInstance3D.new()
	ring.name = "LevelRing"
	var torus := TorusMesh.new()
	torus.inner_radius = maxf(radius * 0.98, 0.38)
	torus.outer_radius = torus.inner_radius + clampf(radius * 0.055, 0.045, 0.12)
	torus.rings = 32
	torus.ring_segments = 4
	ring.mesh = torus
	ring.position.y = 0.07
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var ring_mat := _mat("level_ring_%d" % level, color.darkened(0.08), 0.0, 0.45)
	ring.material_override = ring_mat
	root.add_child(ring)

static func _add_level_badge(root: Node3D, center: Vector3, top: float, color: Color, level: int) -> void:
	var label := Label3D.new()
	label.name = "LevelBadge"
	label.text = "Lv.%d" % level
	label.font_size = 40
	label.pixel_size = 0.012
	label.outline_size = 10
	label.modulate = color
	label.outline_modulate = Color(0.0, 0.0, 0.0, 0.9)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = false
	label.position = Vector3(center.x, top + 0.62, center.z)
	label.visibility_range_begin = 0.0
	label.visibility_range_end = 55.0
	root.add_child(label)

static func _add_max_level_glow(root: Node3D, radius: float, color: Color) -> void:
	var glow := MeshInstance3D.new()
	glow.name = "MaxLevelGlow"
	var torus := TorusMesh.new()
	torus.inner_radius = maxf(radius * 1.12, 0.45)
	torus.outer_radius = torus.inner_radius + 0.035
	torus.rings = 32
	torus.ring_segments = 4
	glow.mesh = torus
	glow.position.y = 0.09
	glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 0.9
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow.material_override = mat
	root.add_child(glow)

static func _mat(key: String, color: Color, emission: float, roughness: float) -> StandardMaterial3D:
	if _MATERIAL_CACHE.has(key):
		return _MATERIAL_CACHE[key]
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = roughness
	if emission > 0.0:
		mat.emission_enabled = true
		mat.emission = color
		mat.emission_energy_multiplier = emission
	_MATERIAL_CACHE[key] = mat
	return mat

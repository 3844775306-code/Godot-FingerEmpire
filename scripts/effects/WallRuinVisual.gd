class_name WallRuinVisual
extends RefCounted

# 中立废墟里的“断墙残段”外观。
# 城墙模型换过之后，残段不能再固定用旧砖块模型，否则会和现役城墙完全不像。
# 这里直接在当前 wall.glb / wall-corner.glb 实例上做压低、倾斜和碎石处理，
# 模型本体一换，废墟会跟着自动同步；被占领时 restore() 恢复成完整城墙。

const RUBBLE_NAME := "WallRuinRubble"
const RUIN_HEIGHT_SCALE := 0.42

static func apply(building: Node3D) -> void:
	if not is_instance_valid(building):
		return
	var eid = building.get("entity_id")
	if eid == null:
		eid = building.get_meta("_entity_id", -1)
	if int(eid) != 27:
		return
	if building.has_meta("_wall_ruin_applied"):
		# 客户端的等级刷新每帧都会重刷 WallTierVisual，残段外观必须把材质再盖回去。
		WallTierVisual.apply(building, 2, Color(0.62, 0.58, 0.52))
		return
	var model = building.get_meta("_model_instance", null)
	if not is_instance_valid(model) or not (model is Node3D):
		return
	var model_3d := model as Node3D
	var base := {
		"position": model_3d.position,
		"rotation": model_3d.rotation,
		"scale": model_3d.scale,
	}
	var bm = building.get_tree().get_first_node_in_group("battle_manager")
	var bottom_lift := 0.0
	if bm != null and bm.has_method("_get_model_aabb"):
		var aabb: AABB = bm._get_model_aabb(model_3d)
		# 以模型包围盒底边为基准压缩高度，避免城墙残段陷进地面或悬空。
		bottom_lift = aabb.position.y * (1.0 - RUIN_HEIGHT_SCALE)
	model_3d.scale = Vector3(base["scale"].x * 1.03, base["scale"].y * RUIN_HEIGHT_SCALE, base["scale"].z * 1.03)
	model_3d.position = Vector3(base["position"].x, base["position"].y + bottom_lift, base["position"].z)
	model_3d.rotation.z += deg_to_rad(randf_range(-5.5, 5.5))
	model_3d.rotation.y += deg_to_rad(randf_range(-8.0, 8.0))
	building.set_meta("_wall_ruin_applied", base)
	WallTierVisual.apply(building, 2, Color(0.62, 0.58, 0.52))
	var body_radius = building.get("body_radius")
	if body_radius == null:
		body_radius = building.get_meta("_body_radius", 1.0)
	_add_rubble(building, float(body_radius))

# 直墙/拐角切换换了模型后，旧残段的基准变换已经失效；只清标记和碎石，
# 不要用旧模型的数据去套新模型。
static func forget(building: Node3D) -> void:
	if not is_instance_valid(building):
		return
	building.remove_meta("_wall_ruin_applied")
	var rubble = building.get_node_or_null(RUBBLE_NAME)
	if rubble != null:
		rubble.queue_free()

static func restore(building: Node3D) -> void:
	if not is_instance_valid(building):
		return
	if not building.has_meta("_wall_ruin_applied"):
		return
	var model = building.get_meta("_model_instance", null)
	if is_instance_valid(model) and model is Node3D:
		var model_3d := model as Node3D
		var base: Dictionary = building.get_meta("_wall_ruin_applied")
		model_3d.position = base["position"]
		model_3d.rotation = base["rotation"]
		model_3d.scale = base["scale"]
	building.remove_meta("_wall_ruin_applied")
	var rubble = building.get_node_or_null(RUBBLE_NAME)
	if rubble != null:
		rubble.queue_free()
	# 强制重刷队伍色/等级材质（占领后颜色通常已变化）。
	building.remove_meta("_wall_tier_key")
	var bm = building.get_tree().get_first_node_in_group("battle_manager")
	var tint := Color.WHITE
	if bm != null and bm.has_method("get_entity_color"):
		tint = bm.get_entity_color(building)
	var lv = building.get("upgrade_level")
	if lv == null:
		lv = building.get_meta("_upgrade_level", 1)
	var base_lv = building.get("level")
	if base_lv == null:
		base_lv = building.get_meta("_level", 1)
	WallTierVisual.apply(building, maxi(int(lv), int(base_lv)), tint)

static func _add_rubble(building: Node3D, body_radius: float) -> void:
	if building.get_node_or_null(RUBBLE_NAME) != null:
		return
	var root := Node3D.new()
	root.name = RUBBLE_NAME
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.42, 0.38, 0.31)
	mat.roughness = 1.0
	var radius := maxf(0.55, body_radius)
	for i in range(4):
		var piece := MeshInstance3D.new()
		var box := BoxMesh.new()
		var s := radius * randf_range(0.12, 0.24)
		box.size = Vector3(s * randf_range(1.0, 1.8), s * randf_range(0.45, 0.8), s * randf_range(1.0, 1.8))
		box.material = mat
		piece.mesh = box
		piece.position = Vector3(
			randf_range(-radius * 0.85, radius * 0.85),
			box.size.y * 0.5,
			randf_range(-radius * 0.7, radius * 0.7)
		)
		piece.rotation.y = randf() * TAU
		root.add_child(piece)
	building.add_child(root)

class_name GarrisonVisual
extends Node3D

# 驻军不再用悬浮文字，而是在屋顶/城墙边缘立一排守军剪影：
# 最多 5 个矛尖+头盔+小盾；超过 5 人再加一面小队旗，精确人数仍看信息面板。
const NODE_NAME := "GarrisonVisual"
const OLD_BADGE_NAME := "GarrisonBadge"
const MAX_MARKERS := 5
const CASTLE_ID := 53
const TOWER_IDS := [25, 26]

const WOOD_COLOR := Color(0.25, 0.15, 0.08)
const STEEL_COLOR := Color(0.62, 0.65, 0.70)

static func limit_for(entity_id: int) -> int:
	match entity_id:
		CASTLE_ID:
			return 10
		25, 26:
			return 5
		_:
			return 0

static func update(building: Node3D, count: int, limit: int, radius: float, team_color: Color, is_visible: bool) -> void:
	if building == null or not is_instance_valid(building):
		return
	var old_badge := building.get_node_or_null(OLD_BADGE_NAME)
	if old_badge != null:
		old_badge.queue_free()
	if limit <= 0 or count <= 0 or not is_visible:
		var hidden := building.get_node_or_null(NODE_NAME) as GarrisonVisual
		if hidden != null:
			hidden.visible = false
		return
	var visual := ensure(building)
	visual.visible = true
	visual._sync(count, radius, team_color)

static func ensure(building: Node3D) -> GarrisonVisual:
	var existing := building.get_node_or_null(NODE_NAME)
	if existing is GarrisonVisual:
		return existing as GarrisonVisual
	if existing != null:
		building.remove_child(existing)
		existing.queue_free()
	var visual := GarrisonVisual.new()
	visual.name = NODE_NAME
	building.add_child(visual)
	return visual

static func remove(building: Node3D) -> void:
	if building == null or not is_instance_valid(building):
		return
	var visual := building.get_node_or_null(NODE_NAME)
	if visual != null:
		building.remove_child(visual)
		visual.queue_free()

var _shown_count: int = -1
var _radius: float = -1.0
var _team_color: Color = Color(0, 0, 0, 0)

func _sync(count: int, radius: float, team_color: Color) -> void:
	var shown := mini(count, MAX_MARKERS)
	var extra := count > MAX_MARKERS
	if shown == _shown_count and is_equal_approx(radius, _radius) and team_color == _team_color and _has_children():
		return
	_shown_count = shown
	_radius = radius
	_team_color = team_color
	_rebuild(shown, extra, radius, team_color)

func _has_children() -> bool:
	return get_child_count() > 0

func _rebuild(shown: int, extra: bool, radius: float, team_color: Color) -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	# 定位到建筑模型的顶部：塔楼比底座高，不能只用 body_radius 估高度。
	var bounds := BuildingLevelVisual._visual_bounds(get_parent() as Node3D)
	var top := radius * 2.0 + 0.55
	var center := Vector3.ZERO
	if bounds.size.y > 0.01:
		top = maxf(top, bounds.end.y + 0.18)
		center = bounds.get_center()
	position = Vector3(center.x, top, center.z)

	var wood := _make_material(WOOD_COLOR, 0.0, 0.0, 0.85)
	var steel := _make_material(STEEL_COLOR, 0.0, 0.35, 0.42)
	var team := _make_material(team_color, 0.18, 0.1, 0.55)
	var span := clampf(radius * 0.55, 0.45, 2.8)
	var step := span / maxf(float(MAX_MARKERS - 1), 1.0)
	for i in range(shown):
		var offset_x := (float(i) - float(shown - 1) * 0.5) * step
		_add_guard(Vector3(offset_x, 0.0, 0.0), wood, steel, team)
	if extra:
		_add_pennant(Vector3(0.0, 0.0, 0.18), wood, team)

func _add_guard(offset: Vector3, wood: Material, steel: Material, team: Material) -> void:
	var guard := Node3D.new()
	guard.position = offset
	add_child(guard)

	# 矛杆
	var shaft := MeshInstance3D.new()
	var shaft_mesh := CylinderMesh.new()
	shaft_mesh.top_radius = 0.012
	shaft_mesh.bottom_radius = 0.016
	shaft_mesh.height = 0.58
	shaft_mesh.radial_segments = 6
	shaft.mesh = shaft_mesh
	shaft.material_override = wood
	shaft.position.y = 0.29
	guard.add_child(shaft)

	# 矛尖
	var tip := MeshInstance3D.new()
	var tip_mesh := CylinderMesh.new()
	tip_mesh.top_radius = 0.0
	tip_mesh.bottom_radius = 0.045
	tip_mesh.height = 0.14
	tip_mesh.radial_segments = 8
	tip.mesh = tip_mesh
	tip.material_override = steel
	tip.position.y = 0.65
	guard.add_child(tip)

	# 头盔
	var helmet := MeshInstance3D.new()
	var helmet_mesh := SphereMesh.new()
	helmet_mesh.radius = 0.058
	helmet_mesh.height = 0.12
	helmet_mesh.radial_segments = 8
	helmet_mesh.rings = 4
	helmet.mesh = helmet_mesh
	helmet.material_override = steel
	helmet.position.y = 0.17
	guard.add_child(helmet)

	# 小盾
	var shield := MeshInstance3D.new()
	var shield_mesh := CylinderMesh.new()
	shield_mesh.top_radius = 0.082
	shield_mesh.bottom_radius = 0.082
	shield_mesh.height = 0.035
	shield_mesh.radial_segments = 10
	shield.mesh = shield_mesh
	shield.material_override = team
	shield.rotation.x = deg_to_rad(90.0)
	shield.position = Vector3(0.0, 0.14, -0.065)
	guard.add_child(shield)

func _add_pennant(offset: Vector3, wood: Material, team: Material) -> void:
	var pole := MeshInstance3D.new()
	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = 0.012
	pole_mesh.bottom_radius = 0.016
	pole_mesh.height = 0.78
	pole_mesh.radial_segments = 6
	pole.mesh = pole_mesh
	pole.material_override = wood
	pole.position = offset + Vector3(0.0, 0.39, 0.0)
	add_child(pole)

	var flag := MeshInstance3D.new()
	var flag_mesh := PrismMesh.new()
	flag_mesh.size = Vector3(0.24, 0.16, 0.025)
	flag_mesh.left_to_right = 0.5
	flag.mesh = flag_mesh
	flag.material_override = team
	flag.position = offset + Vector3(0.13, 0.68, 0.0)
	add_child(flag)

static func _make_material(color: Color, emission: float, metallic: float, roughness: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.metallic = metallic
	mat.roughness = roughness
	if emission > 0.0:
		mat.emission_enabled = true
		mat.emission = color
		mat.emission_energy_multiplier = emission
	return mat

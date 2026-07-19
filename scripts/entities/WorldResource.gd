class_name WorldResource
extends GameEntity

var resource_type: String = "gold"

func _ready():
	super._ready()
	entity_type = 0
	var lv = randi_range(1,5)
	level = lv
	var scale = 0.4 + (lv - 1) * 0.3
	max_health = int(max_health * scale)
	health = max_health
	team = RTSConfig.Team.NEUTRAL
	can_move = false
	_create_visual()
	_add_selection_ring()
	_add_collision_shape()
	

func setup(config: Dictionary):
	super.setup(config)
	resource_type = config.get("resource_type", "gold")

func _create_visual():
	var mesh = MeshInstance3D.new()
	var sphere = SphereMesh.new()
	sphere.radius = body_radius
	mesh.mesh = sphere
	add_child(mesh)
	var mat = StandardMaterial3D.new()
	match resource_type:
		"oil": mat.albedo_color = Color(0.1, 0.1, 0.1)   # 黑色
		"gold": mat.albedo_color = Color.YELLOW
		"wood": mat.albedo_color = Color.GREEN
		"stone": mat.albedo_color = Color.GRAY
		"food": mat.albedo_color = Color.SADDLE_BROWN
		_: mat.albedo_color = Color.PINK
	mesh.set_surface_override_material(0, mat)

func _add_selection_ring():
	if not has_node("SelectionRing"):
		var ring = MeshInstance3D.new()
		ring.name = "SelectionRing"
		var torus = TorusMesh.new()
		torus.inner_radius = body_radius + 0.1
		torus.outer_radius = body_radius + 0.2
		ring.mesh = torus
		ring.position = Vector3(0, 0.1, 0)
		ring.material_override = StandardMaterial3D.new()
		ring.material_override.albedo_color = Color.GREEN
		ring.visible = false
		add_child(ring)

func _add_collision_shape():
	if not has_node("CollisionShape3D"):
		var col = CollisionShape3D.new()
		var shape = SphereShape3D.new()
		shape.radius = body_radius * 0.6
		col.shape = shape
		col.name = "CollisionShape3D"
		add_child(col)
		collision_layer = 1
		collision_mask = 0

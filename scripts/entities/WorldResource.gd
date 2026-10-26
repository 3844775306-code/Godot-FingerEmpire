class_name WorldResource
extends GameEntity

var resource_type: String = "gold"

# 资源脚下的地面贴花：中间实、边缘渐隐，颜色按资源类型微调。
# 资源模型本身没有“底座”，直接立在草地/雪地上时边缘会像贴纸一样生硬；
# 铺一层和资源属性相符的软边地皮后，模型与地面之间才有过渡。
const GROUND_PATCH_COLORS := {
	"gold": Color(0.53, 0.44, 0.26, 0.84),
	"wood": Color(0.24, 0.32, 0.17, 0.82),
	"stone": Color(0.37, 0.37, 0.34, 0.82),
	"food": Color(0.45, 0.34, 0.19, 0.84),
	"oil": Color(0.10, 0.10, 0.09, 0.72),
}
const RESOURCE_TYPE_BY_ID := {0: "gold", 1: "wood", 2: "stone", 3: "food", 4: "oil"}
const GROUND_PATCH_FADE_TIME := 2.0
# 地形在第 1 层；油井落在水面，水面单独在第 19 层（与 Ground.WATER_LAYER 一致）。
# 两层都投射，油井才会在水面上留下油渍一样的过渡。
const GROUND_PATCH_CULL_MASK := 1 | (1 << 19)

static var _ground_patch_tex: ImageTexture = null
var _ground_patch: Decal = null

func _ready():
	super._ready()
	entity_type = 0
	
	 
	
	
	_create_visual()
	_add_selection_ring()
	_add_collision_shape()
	# setup()/模型加载都在 add_child 之后才发生，延后一帧再按真实资源类型和模型尺寸铺地皮
	call_deferred("_spawn_ground_patch")
	

func setup(config: Dictionary):
	super.setup(config)
	resource_type = config.get("resource_type", "gold")
	var lv = randi_range(1,5)
	level = lv
	max_health  *= 0.4 + (level - 1.0) * 0.3
	
	health = max_health
	team = RTSConfig.Team.NEUTRAL
	can_move = false

static func resource_type_for_id(eid: int) -> String:
	return RESOURCE_TYPE_BY_ID.get(eid, "gold")

static func ground_patch_color(rtype: String) -> Color:
	return GROUND_PATCH_COLORS.get(rtype, Color(0.43, 0.34, 0.22, 0.76))

# 程序生成一张柔边、带轻微不规则边缘的地皮贴图。
# 相比建筑用的方形渐隐贴图，这里把边缘按角度做了小幅扰动，资源成片分布时
# 不会出现一排同样大小的圆盘；整张图全项目共用。
static func ground_patch_texture() -> ImageTexture:
	if _ground_patch_tex != null:
		return _ground_patch_tex
	var n: int = 96
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var u: float = (float(x) + 0.5) / float(n) * 2.0 - 1.0
			var v: float = (float(y) + 0.5) / float(n) * 2.0 - 1.0
			var d: float = sqrt(u * u + v * v)
			var ang: float = atan2(v, u)
			# 边缘扰动要低频，否则远看会像锯齿
			var wobble: float = sin(ang * 5.0 + 1.3) * 0.06 \
				+ sin(ang * 9.0 - 0.7) * 0.035 \
				+ sin(ang * 15.0 + 2.1) * 0.018
			var edge: float = 0.81 + wobble
			var a: float = clampf((edge - d) / 0.24, 0.0, 1.0)
			a = a * a * (3.0 - 2.0 * a)
			var h: float = float(absi((x * 73856093) ^ (y * 19349663)) % 1000) / 1000.0
			var shade: float = 0.87 + h * 0.16
			a *= 0.88 + h * 0.12
			img.set_pixel(x, y, Color(shade, shade, shade, a))
	_ground_patch_tex = ImageTexture.create_from_image(img)
	return _ground_patch_tex

# 贴花半宽：优先按模型实际水平尺寸算，再外扩一圈软边。
# 模型的包围盒原点已经在脚底，这里只取水平尺寸，不参与垂直贴地计算。
static func ground_patch_half_size(body_radius: float, model: Node3D) -> float:
	var r: float = maxf(body_radius, 0.3)
	if model != null and is_instance_valid(model) and model.is_inside_tree():
		var inv: Transform3D = model.global_transform.affine_inverse()
		var merged := AABB()
		var has := false
		for child in model.find_children("*", "MeshInstance3D", true, false):
			var mi := child as MeshInstance3D
			if mi == null or mi.mesh == null:
				continue
			var a: AABB = (inv * mi.global_transform) * mi.get_aabb()
			if not has:
				merged = a
				has = true
			else:
				merged = merged.merge(a)
		if has:
			var horiz: float = maxf(merged.size.x, merged.size.z) * 0.5
			if horiz > 0.05:
				r = horiz
	return maxf(r + 0.55, body_radius * 0.9)

func _spawn_ground_patch() -> void:
	if _ground_patch != null and is_instance_valid(_ground_patch):
		return
	if health <= 0:
		return
	var model: Node3D = null
	if has_meta("_model_instance"):
		var mi = get_meta("_model_instance")
		if is_instance_valid(mi) and mi is Node3D:
			model = mi
	var half: float = ground_patch_half_size(body_radius, model)
	var decal := Decal.new()
	decal.name = "GroundPatch"
	decal.texture_albedo = ground_patch_texture()
	decal.modulate = ground_patch_color(resource_type)
	# 资源本身颜色已经比较实，地皮只做覆盖过渡，保留草地/雪地原来的色相
	decal.albedo_mix = 0.9
	# 只投射到世界层（地形/水面），避免把单位或建筑染上一层色
	decal.cull_mask = GROUND_PATCH_CULL_MASK
	# 垂直范围放在实体原点两侧，地面正好落在中间，不会落进上下淡出区
	decal.size = Vector3(half * 2.0, 6.0, half * 2.0)
	decal.position = Vector3.ZERO
	decal.upper_fade = 1.0
	decal.lower_fade = 1.0
	add_child(decal)
	_ground_patch = decal

# 资源采空/被摧毁时，地皮不要跟着模型一起沉进地下：
# 先摘下来留在原地淡出，避免地面上突然少一块颜色。
func _fade_ground_patch() -> void:
	if _ground_patch == null or not is_instance_valid(_ground_patch):
		_ground_patch = null
		return
	var decal := _ground_patch
	_ground_patch = null
	var parent := get_parent()
	if parent != null:
		decal.reparent(parent, true)
	var tw := decal.create_tween()
	tw.tween_property(decal, "modulate:a", 0.0, GROUND_PATCH_FADE_TIME)
	tw.tween_callback(Callable(decal, "queue_free"))

func die():
	_fade_ground_patch()
	super.die()

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
		shape.radius = body_radius * 1.2 # 增大碰撞范围，确保点击树叶边缘时也能命中
		col.shape = shape
		col.name = "CollisionShape3D"
		add_child(col)
		collision_layer = 1
		collision_mask = 0

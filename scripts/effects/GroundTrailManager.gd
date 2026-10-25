class_name GroundTrailManager
extends Node3D

# 全场景共享的地面痕迹与脚步特效。原先每个陆军单位各自创建 14 个脚印 Mesh 和一个
# CPUParticles3D，几百个单位时节点和 draw call 会明显失控；这里改成一张 MultiMesh
# 环缓冲加一小组复用粒子，所有单位共用。

const MAX_PRINTS := 384
const PRINT_LIFETIME := 10.0
# RTS 相机不是贴地视角：默认 size=17.5 时相机到地面焦点约 66 米，最远约 97 米，
# 边缘单位还要再加一段水平距离。之前 42/36 米的上限会把默认视野里的痕迹全部裁掉，
# 所以这里只裁剪真正远离战场的痕迹，不用它做近景优化。
const PRINT_DISTANCE := 160.0
const DUST_DISTANCE := 120.0
const DUST_POOL_SIZE := 10
const RIPPLE_POOL_SIZE := 6
const TRAIL_Y_OFFSET := 0.055

static var _shared = null

var _print_mm: MultiMesh
var _print_node: MultiMeshInstance3D
var _print_age := PackedFloat32Array()
var _print_active := PackedByteArray()
var _print_color := PackedColorArray()
var _print_next: int = 0
var _fade_accum: float = 0.0

var _dust_pool: Array[CPUParticles3D] = []
var _dust_next: int = 0
var _dust_mesh: SphereMesh
var _dust_mat: StandardMaterial3D
var _dust_ramp: Gradient

var _ripple_pool: Array[MeshInstance3D] = []
var _ripple_next: int = 0
var _ripple_mesh: TorusMesh
var _ripple_mat: StandardMaterial3D

static func get_instance(tree: SceneTree) -> GroundTrailManager:
	if _shared != null and is_instance_valid(_shared) and _shared.is_inside_tree():
		return _shared
	if tree == null:
		return null
	var root := tree.current_scene
	if root == null:
		return null
	var existing := root.get_node_or_null("GroundTrailManager")
	if existing is GroundTrailManager:
		_shared = existing
		return _shared
	var mgr := GroundTrailManager.new()
	mgr.name = "GroundTrailManager"
	root.add_child(mgr)
	_shared = mgr
	return _shared

func _ready() -> void:
	_build_prints()
	_build_dust()
	_build_ripples()
	set_process(false)

func _exit_tree() -> void:
	if _shared == self:
		_shared = null

# ── 脚印 / 车辙 ──
# 一张 MultiMesh 里循环覆盖最旧的痕迹，所有实例共用同一个材质和渐变贴图。
func _build_prints() -> void:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled;

uniform sampler2D print_texture : source_color, filter_linear;

void fragment() {
	vec4 tex = texture(print_texture, UV);
	ALBEDO = COLOR.rgb;
	ALPHA = COLOR.a * tex.a;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = shader

	var shape_grad := Gradient.new()
	shape_grad.set_color(0, Color(1.0, 1.0, 1.0, 1.0))
	shape_grad.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
	var shape_tex := GradientTexture2D.new()
	shape_tex.gradient = shape_grad
	shape_tex.fill = GradientTexture2D.FILL_RADIAL
	shape_tex.fill_from = Vector2(0.5, 0.5)
	shape_tex.fill_to = Vector2(1.0, 0.5)
	shape_tex.width = 96
	shape_tex.height = 96
	mat.set_shader_parameter("print_texture", shape_tex)

	var quad := PlaneMesh.new()
	quad.size = Vector2(1.0, 1.0)
	quad.material = mat

	_print_mm = MultiMesh.new()
	_print_mm.transform_format = MultiMesh.TRANSFORM_3D
	_print_mm.use_colors = true
	_print_mm.mesh = quad
	_print_mm.instance_count = MAX_PRINTS

	_print_age.resize(MAX_PRINTS)
	_print_active.resize(MAX_PRINTS)
	_print_color.resize(MAX_PRINTS)
	var hidden := Transform3D(Basis.from_scale(Vector3(0.001, 0.001, 0.001)), Vector3(0.0, -1000.0, 0.0))
	for i in MAX_PRINTS:
		_print_age[i] = 0.0
		_print_active[i] = 0
		_print_color[i] = Color(0.0, 0.0, 0.0, 0.0)
		_print_mm.set_instance_transform(i, hidden)
		_print_mm.set_instance_color(i, Color(0.0, 0.0, 0.0, 0.0))

	_print_node = MultiMeshInstance3D.new()
	_print_node.name = "Footprints"
	_print_node.multimesh = _print_mm
	_print_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# MultiMesh 在实例变换动态写入后，引擎侧计算出的 AABB 可能是零尺寸，
	# 多相机/真实战斗场景下会被整体视锥剔除（水面涟漪用普通 MeshInstance，
	# 有自己的正常 AABB，所以一直可见）。这里显式给一个覆盖全地图的本地包围盒，
	# 384 个薄片本身开销很小，不需要靠自动 AABB 做精细裁剪。
	_print_node.custom_aabb = AABB(Vector3(-300.0, -40.0, -300.0), Vector3(600.0, 80.0, 600.0))
	add_child(_print_node)

func _process(delta: float) -> void:
	_fade_accum += delta
	if _fade_accum < 0.1:
		return
	var elapsed := _fade_accum
	_fade_accum = 0.0
	var any_active := false
	for i in MAX_PRINTS:
		if _print_active[i] == 0:
			continue
		_print_age[i] += elapsed
		var t: float = _print_age[i] / PRINT_LIFETIME
		if t >= 1.0:
			_print_active[i] = 0
			_print_mm.set_instance_color(i, Color(0.0, 0.0, 0.0, 0.0))
			continue
		any_active = true
		var c: Color = _print_color[i]
		c.a *= (1.0 - t) * (1.0 - t)
		_print_mm.set_instance_color(i, c)
	if not any_active:
		set_process(false)

func _add_print(pos: Vector3, dir: Vector3, vehicle: bool, terrain: int, overlay: int, side: int) -> void:
	var flat := Vector3(dir.x, 0.0, dir.z)
	if flat.length_squared() < 0.0001:
		flat = Vector3.FORWARD
	flat = flat.normalized()
	var right := Vector3(-flat.z, 0.0, flat.x)
	var lateral: float = 0.0 if vehicle else 0.11 * float(side)
	var yaw: float = atan2(flat.x, flat.z) + randf_range(-0.15, 0.15)
	# 默认 RTS 相机离地约 50 米，脚印在屏幕上只有几十像素；沿用旧版尺寸，
	# 避免共享池化后视觉上比原来的贴痕小一圈。
	var width: float = 1.70 if vehicle else 0.75
	var length: float = 3.00 if vehicle else 1.10
	var jitter: float = randf_range(0.86, 1.14)
	var basis := Basis(Vector3.UP, yaw) * Basis.from_scale(Vector3(width * jitter, 1.0, length * jitter))
	var i := _print_next
	_print_next = (_print_next + 1) % MAX_PRINTS
	_print_age[i] = 0.0
	_print_active[i] = 1
	_print_color[i] = _print_color_for(terrain, overlay, vehicle)
	_print_mm.set_instance_transform(i, Transform3D(basis, pos + right * lateral + Vector3(0.0, TRAIL_Y_OFFSET, 0.0)))
	_print_mm.set_instance_color(i, _print_color[i])
	set_process(true)

func _print_color_for(terrain: int, overlay: int, vehicle: bool) -> Color:
	var color := Color(0.24, 0.18, 0.11, 0.55)
	if vehicle:
		color = Color(0.27, 0.20, 0.13, 0.62)
	if terrain == 1:
		# 山地/石地：更像压痕而不是泥印
		color = Color(0.32, 0.30, 0.27, 0.36)
	elif overlay == 1:
		# 森林地表：腐殖土更深
		color = Color(0.20, 0.18, 0.12, 0.52)
	elif overlay == 2:
		# 沼泽：湿泥，深且窄
		color = Color(0.16, 0.14, 0.10, 0.60)
	return color

# ── 脚步扬尘 ──
# 不再让每个单位常驻一个粒子发射器；用 10 个一次性粒子节点轮转。
func _build_dust() -> void:
	_dust_mesh = SphereMesh.new()
	_dust_mesh.radius = 0.11
	_dust_mesh.height = 0.22
	_dust_mesh.radial_segments = 6
	_dust_mesh.rings = 3
	_dust_mat = StandardMaterial3D.new()
	_dust_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_dust_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# CPUParticles3D 的 p.color / color_ramp 是通过顶点色传给网格的；
	# StandardMaterial3D 默认不读取顶点色，颜色会被忽略成白色，必须显式打开。
	_dust_mat.vertex_color_use_as_albedo = true
	_dust_mat.albedo_color = Color.WHITE
	_dust_mesh.material = _dust_mat
	_dust_ramp = Gradient.new()
	# 这里的 alpha 只负责粒子生命周期内的淡出，真正的浓度由 p.color 控制。
	# 两边都乘一次会把 alpha 从 0.22 压到 0.07，远景下几乎完全透明。
	_dust_ramp.set_color(0, Color(1.0, 1.0, 1.0, 1.0))
	_dust_ramp.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
	for i in DUST_POOL_SIZE:
		var p := CPUParticles3D.new()
		p.one_shot = true
		p.emitting = false
		p.amount = 6
		p.lifetime = 0.6
		p.explosiveness = 1.0
		p.local_coords = false
		p.direction = Vector3.UP
		p.spread = 70.0
		p.initial_velocity_min = 0.12
		p.initial_velocity_max = 0.48
		p.gravity = Vector3(0.0, 0.10, 0.0)
		p.scale_amount_min = 1.0
		p.scale_amount_max = 1.5
		p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
		p.emission_sphere_radius = 0.35
		p.color_ramp = _dust_ramp
		p.mesh = _dust_mesh
		p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		p.visibility_aabb = AABB(Vector3(-4.0, -2.0, -4.0), Vector3(8.0, 6.0, 8.0))
		add_child(p)
		_dust_pool.append(p)

func _spawn_dust(pos: Vector3, color: Color, amount: int, lifetime: float, strength: float) -> void:
	if _dust_pool.is_empty():
		return
	var p := _dust_pool[_dust_next]
	_dust_next = (_dust_next + 1) % _dust_pool.size()
	p.global_position = pos + Vector3(0.0, 0.07, 0.0)
	p.amount = maxi(2, amount)
	p.lifetime = lifetime
	p.color = color
	p.initial_velocity_min = 0.10 * strength
	p.initial_velocity_max = 0.40 * strength
	p.scale_amount_max = 1.3 + strength * 0.4
	p.restart()
	p.emitting = true

# ── 浅水涟漪 ──
func _build_ripples() -> void:
	_ripple_mesh = TorusMesh.new()
	_ripple_mesh.inner_radius = 0.78
	_ripple_mesh.outer_radius = 1.0
	_ripple_mesh.rings = 24
	_ripple_mesh.ring_segments = 8
	_ripple_mat = StandardMaterial3D.new()
	_ripple_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ripple_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ripple_mat.albedo_color = Color(0.68, 0.85, 0.92, 0.42)
	_ripple_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	for i in RIPPLE_POOL_SIZE:
		var ring := MeshInstance3D.new()
		ring.name = "FootRipple"
		ring.mesh = _ripple_mesh
		ring.material_override = _ripple_mat
		ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		ring.visible = false
		add_child(ring)
		_ripple_pool.append(ring)

func _spawn_ripple(pos: Vector3, size: float) -> void:
	if _ripple_pool.is_empty():
		return
	var ring := _ripple_pool[_ripple_next]
	_ripple_next = (_ripple_next + 1) % _ripple_pool.size()
	if ring.has_meta("_ripple_tween"):
		var old = ring.get_meta("_ripple_tween")
		if old is Tween and old.is_valid():
			old.kill()
	ring.visible = true
	ring.global_position = pos + Vector3(0.0, 0.04, 0.0)
	ring.scale = Vector3.ONE * 0.18
	ring.transparency = 0.0
	var tw := ring.create_tween()
	tw.set_parallel(true)
	tw.tween_property(ring, "scale", Vector3.ONE * size, 0.58) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(ring, "transparency", 1.0, 0.58) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(ring.hide)
	ring.set_meta("_ripple_tween", tw)

# ── 对外入口 ──
# dir: 前进方向；vehicle: 是否车辆/攻城器；terrain: 0 平原 1 山 2 水；
# overlay: 0 无 1 森林 2 沼泽 3 浅滩；side: 左右脚交替（车辆传 0）。
func emit_step(pos: Vector3, dir: Vector3, vehicle: bool, terrain: int, overlay: int, side: int) -> void:
	if not is_inside_tree():
		return
	var water := terrain == 2 or overlay == 3
	if water:
		if _within_camera(pos, DUST_DISTANCE):
			_spawn_ripple(pos, 1.1 if vehicle else 0.62)
			_spawn_dust(pos, Color(0.62, 0.78, 0.82, 0.32), 6, 0.52, 0.55)
		return
	if not _within_camera(pos, PRINT_DISTANCE):
		return
	_add_print(pos, dir, vehicle, terrain, overlay, side)
	if not _within_camera(pos, DUST_DISTANCE):
		return
	var color := Color(0.62, 0.55, 0.42, 0.38)
	var amount := 7
	var lifetime := 0.58
	var strength := 0.9
	if vehicle:
		color = Color(0.58, 0.49, 0.35, 0.46)
		amount = 12
		lifetime = 0.80
		strength = 1.35
	elif terrain == 1:
		color = Color(0.48, 0.46, 0.42, 0.26)
		amount = 5
		lifetime = 0.46
		strength = 0.7
	elif overlay == 2:
		color = Color(0.34, 0.29, 0.21, 0.42)
		amount = 7
		lifetime = 0.54
		strength = 0.8
	elif overlay == 1:
		color = Color(0.45, 0.43, 0.30, 0.32)
		amount = 5
		lifetime = 0.52
		strength = 0.75
	_spawn_dust(pos, color, amount, lifetime, strength)

func _within_camera(pos: Vector3, max_dist: float) -> bool:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return false
	return cam.global_position.distance_to(pos) <= max_dist

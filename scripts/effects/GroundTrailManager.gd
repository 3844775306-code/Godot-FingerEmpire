class_name GroundTrailManager
extends Node3D

# 全场景共享的地面痕迹与脚步特效。原先每个陆军单位各自创建 14 个脚印 Mesh 和一个
# CPUParticles3D，几百个单位时节点和 draw call 会明显失控；这里改成一张 MultiMesh
# 环缓冲加一小组复用粒子，所有单位共用。

const MAX_PRINTS := 384
# 痕迹改成「按格子累积强度」：同一块地反复被踩会越来越深，而不是每次
# 都新画一片再各自淡出。加深刻意放慢（约 18 次经过才到最深），
# 消退比加深更慢（满强度约 55 秒才淡完），大部队走过之后会留下能看出来的路。
const TRAIL_CELL_SIZE := 0.5
const TRAIL_STEP_GAIN := 0.055
const TRAIL_DECAY_RATE := 0.018
const TRAIL_MAX_ALPHA := 0.85
# 与建筑脚下贴花同一套土色，路径和建筑地基看起来属于同一片土地
const TRAIL_SOIL_COLOR := Color(0.42, 0.31, 0.19)
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
var _print_strength := PackedFloat32Array()   # 0..1 的踩踏强度，决定颜色深浅
var _print_base_color := PackedColorArray()   # 按地形定下的土色基底，alpha 交给强度
var _print_active := PackedByteArray()
var _print_next: int = 0
var _trail_cell: Dictionary = {}              # 格子 key -> MultiMesh 槽位，用于同格累积
var _slot_key: Array = []                     # 槽位 -> 它代表的格子，释放时反查用
var _fade_accum: float = 0.0

var _dust_pool: Array[CPUParticles3D] = []
var _dust_next: int = 0
var _dust_mesh: QuadMesh
var _dust_mat: StandardMaterial3D
var _dust_tex: ImageTexture
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

	_print_strength.resize(MAX_PRINTS)
	_print_base_color.resize(MAX_PRINTS)
	_print_active.resize(MAX_PRINTS)
	var hidden := Transform3D(Basis.from_scale(Vector3(0.001, 0.001, 0.001)), Vector3(0.0, -1000.0, 0.0))
	for i in MAX_PRINTS:
		_print_strength[i] = 0.0
		_print_base_color[i] = TRAIL_SOIL_COLOR
		_print_active[i] = 0
		_print_mm.set_instance_transform(i, hidden)
		_print_mm.set_instance_color(i, Color(0.0, 0.0, 0.0, 0.0))
	_slot_key.resize(MAX_PRINTS)
	for i in MAX_PRINTS:
		_slot_key[i] = Vector2i(-999999, -999999)

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
		# 按强度衰减：每一步都在慢慢变浅，而不是按固定寿命一刀切
		_print_strength[i] -= TRAIL_DECAY_RATE * elapsed
		if _print_strength[i] <= 0.0:
			_print_active[i] = 0
			_print_strength[i] = 0.0
			_print_mm.set_instance_color(i, Color(0.0, 0.0, 0.0, 0.0))
			_trail_cell.erase(_cell_key_of(i))
			continue
		any_active = true
		var c: Color = _print_base_color[i]
		c.a = minf(_print_strength[i], 1.0) * TRAIL_MAX_ALPHA
		_print_mm.set_instance_color(i, c)
	if not any_active:
		set_process(false)

# 同一格内的重复经过视为同一条痕迹，用来累加强度而不是铺新的一片
func _cell_key(pos: Vector3) -> Vector2i:
	return Vector2i(int(floor(pos.x / TRAIL_CELL_SIZE)), int(floor(pos.z / TRAIL_CELL_SIZE)))

# 槽位反查格子 key：释放时要把映射一起清掉，否则会残留假条目
func _cell_key_of(slot: int) -> Vector2i:
	if slot < 0 or slot >= _slot_key.size():
		return Vector2i(-999999, -999999)
	return _slot_key[slot]

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
	var world_pos: Vector3 = pos + right * lateral + Vector3(0.0, TRAIL_Y_OFFSET, 0.0)
	var key := _cell_key(world_pos)

	# 这块地已经被踩过：只加深刻度，不再占用新的槽位
	if _trail_cell.has(key):
		var existing: int = int(_trail_cell[key])
		if _print_active[existing] == 1:
			_print_strength[existing] = minf(_print_strength[existing] + TRAIL_STEP_GAIN, 1.0)
			var c2: Color = _print_base_color[existing]
			c2.a = _print_strength[existing] * TRAIL_MAX_ALPHA
			_print_mm.set_instance_color(existing, c2)
			set_process(true)
			return
		_trail_cell.erase(key)

	var i := _print_next
	_print_next = (_print_next + 1) % MAX_PRINTS
	# 槽位被别的格子占着：先把旧格子的映射断掉，避免两处共用一个 key
	if _print_active[i] == 1:
		_trail_cell.erase(_cell_key_of(i))
	_print_active[i] = 1
	_print_strength[i] = TRAIL_STEP_GAIN
	_print_base_color[i] = _print_color_for(terrain, overlay, vehicle)
	var col: Color = _print_base_color[i]
	col.a = _print_strength[i] * TRAIL_MAX_ALPHA
	_print_mm.set_instance_transform(i, Transform3D(basis, world_pos))
	_print_mm.set_instance_color(i, col)
	_slot_key[i] = key
	_trail_cell[key] = i
	set_process(true)

# 土色基底：颜色跟着地形走，深浅由踩踏强度决定（见 _process）
func _print_color_for(terrain: int, overlay: int, vehicle: bool) -> Color:
	var color := TRAIL_SOIL_COLOR
	if vehicle:
		# 车辙比脚印更压实，略深一点
		color = Color(0.36, 0.26, 0.16)
	if terrain == 1:
		# 山地/石地：压痕偏灰，不是泥色
		color = Color(0.40, 0.37, 0.32)
	elif overlay == 1:
		# 森林地表：腐殖土更深
		color = Color(0.31, 0.24, 0.15)
	elif overlay == 2:
		# 沼泽：湿泥最深
		color = Color(0.26, 0.21, 0.15)
	return color

# ── 脚步扬尘 ──
# 不再让每个单位常驻一个粒子发射器；用 10 个一次性粒子节点轮转。
# 尘粒改用带柔边噪声的 billboard 小面片：之前的低面数球体在 RTS 远景下
# 会呈现为一颗颗边缘生硬、颜色均匀的圆点，看起来像纸屑而不是尘土。
func _build_dust() -> void:
	_dust_tex = _make_dust_texture()
	_dust_mesh = QuadMesh.new()
	_dust_mesh.size = Vector2(0.18, 0.18)
	_dust_mat = StandardMaterial3D.new()
	_dust_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_dust_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# CPUParticles3D 的 p.color / color_ramp 是通过顶点色传给网格的；
	# StandardMaterial3D 默认不读取顶点色，颜色会被忽略成白色，必须显式打开。
	_dust_mat.vertex_color_use_as_albedo = true
	_dust_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	_dust_mat.billboard_keep_scale = true
	_dust_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_dust_mat.albedo_color = Color.WHITE
	_dust_mat.albedo_texture = _dust_tex
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
		p.amount = 14
		p.lifetime = 0.65
		p.explosiveness = 1.0
		p.local_coords = false
		p.direction = Vector3.UP
		p.spread = 82.0
		p.initial_velocity_min = 0.06
		p.initial_velocity_max = 0.30
		p.gravity = Vector3(0.0, 0.06, 0.0)
		p.scale_amount_min = 0.55
		p.scale_amount_max = 1.20
		p.angle_min = 0.0
		p.angle_max = 360.0
		p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
		p.emission_sphere_radius = 0.30
		p.color_ramp = _dust_ramp
		p.mesh = _dust_mesh
		p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		p.visibility_aabb = AABB(Vector3(-4.0, -2.0, -4.0), Vector3(8.0, 6.0, 8.0))
		add_child(p)
		_dust_pool.append(p)

func _make_dust_texture() -> ImageTexture:
	var tex_size := 64
	var img := Image.create(tex_size, tex_size, false, Image.FORMAT_RGBA8)
	var noise := FastNoiseLite.new()
	noise.seed = 7411
	noise.frequency = 0.11
	for y in tex_size:
		for x in tex_size:
			var dx := (float(x) + 0.5) / float(tex_size) * 2.0 - 1.0
			var dy := (float(y) + 0.5) / float(tex_size) * 2.0 - 1.0
			var d := sqrt(dx * dx + dy * dy)
			var falloff := clampf(1.0 - d, 0.0, 1.0)
			falloff = smoothstep(0.0, 1.0, falloff)
			var n := noise.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
			var alpha := clampf(falloff * (0.42 + n * 0.66), 0.0, 1.0)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, alpha))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

func _spawn_dust(pos: Vector3, color: Color, amount: int, lifetime: float, strength: float) -> void:
	if _dust_pool.is_empty():
		return
	var p := _dust_pool[_dust_next]
	_dust_next = (_dust_next + 1) % _dust_pool.size()
	p.global_position = pos + Vector3(0.0, 0.07, 0.0)
	p.amount = maxi(4, amount)
	p.lifetime = lifetime
	# 每一团尘土做轻微亮度/色温/透明度扰动，避免整片扬尘颜色完全一致。
	var tint_r := randf_range(0.94, 1.05)
	var tint_g := randf_range(0.95, 1.03)
	var tint_b := randf_range(0.93, 1.04)
	var alpha_jitter := randf_range(0.82, 1.12)
	p.color = Color(
		clampf(color.r * tint_r, 0.0, 1.0),
		clampf(color.g * tint_g, 0.0, 1.0),
		clampf(color.b * tint_b, 0.0, 1.0),
		clampf(color.a * alpha_jitter, 0.0, 1.0)
	)
	p.initial_velocity_min = 0.10 * strength
	p.initial_velocity_max = 0.40 * strength
	p.scale_amount_max = 1.05 + strength * 0.30
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
			_spawn_dust(pos, Color(0.62, 0.73, 0.76, 0.26), 9, 0.56, 0.55)
		return
	if not _within_camera(pos, PRINT_DISTANCE):
		return
	_add_print(pos, dir, vehicle, terrain, overlay, side)
	if not _within_camera(pos, DUST_DISTANCE):
		return
	var color := Color(0.58, 0.55, 0.49, 0.28)
	var amount := 14
	var lifetime := 0.62
	var strength := 0.9
	if vehicle:
		color = Color(0.54, 0.51, 0.45, 0.33)
		amount = 20
		lifetime = 0.88
		strength = 1.35
	elif terrain == 1:
		color = Color(0.56, 0.55, 0.52, 0.22)
		amount = 9
		lifetime = 0.50
		strength = 0.7
	elif overlay == 2:
		color = Color(0.36, 0.34, 0.28, 0.30)
		amount = 11
		lifetime = 0.58
		strength = 0.8
	elif overlay == 1:
		color = Color(0.44, 0.43, 0.37, 0.24)
		amount = 9
		lifetime = 0.55
		strength = 0.75
	_spawn_dust(pos, color, amount, lifetime, strength)

func _within_camera(pos: Vector3, max_dist: float) -> bool:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return false
	return cam.global_position.distance_to(pos) <= max_dist

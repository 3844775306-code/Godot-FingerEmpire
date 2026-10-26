class_name GroundRangeRing
extends MeshInstance3D

# 选中单位时贴在地上的一圈范围线。
#
#   视野范围 = 细线（淡青白）
#   作用范围 = 粗线（暖琥珀）——军队射程、官员光环半径
#
# 不用圆环模型（TorusMesh）的原因是它是一块刚性平面：地形一起伏就会一半埋进土里、
# 一半浮在空中，看着像一块圆盘砸在地上。这里按地形逐顶点贴地画一条带子，
# 材质用 unshaded + 不写深度 + 横向软边，和地面是「叠一层颜色」而不是「贴一张纸」。
#
# 线宽不是固定米数：RTS 相机常常在 50 米高空，0.11 米在屏幕上不到 1 个像素，
# 再加上软边半透明，等于看不见。所以每次重建都按「至少占几个像素」反算世界宽度，
# 相机拉远/推近时也会重建。

enum Kind { VISION, ACTION }

const VISION_WIDTH: float = 0.16
const ACTION_WIDTH: float = 0.40
# 屏幕上至少要占几个像素，否则细线在远处等于画在空气里
const VISION_MIN_PIXELS: float = 2.6
const ACTION_MIN_PIXELS: float = 4.4
const VISION_TINT: Color = Color(0.80, 0.92, 1.00, 0.46)
const ACTION_TINT: Color = Color(1.00, 0.84, 0.50, 0.56)

# 移动后重建网格的阈值：太小会每帧重建，太大会看到线跟不上地形
const REBUILD_DISTANCE: float = 0.10
const REBUILD_INTERVAL: float = 0.08
# 相机距离变化超过这个比例就重算线宽（拉远时线会自动变粗，观感才一致）
const CAMERA_DIST_REL: float = 0.12
# 呼吸动画：粗线（作用范围）轻微起伏，静止时也能看出「这是选中状态」
const PULSE_SPEED: float = 1.7
const PULSE_DEPTH: float = 0.16

var kind: int = Kind.VISION
var radius: float = 0.0

var _tint: Color = Color.WHITE
var _height_fn: Callable
var _last_center: Vector3 = Vector3(INF, INF, INF)
var _rebuild_timer: float = 0.0
var _pulse_t: float = 0.0
var _base_alpha: float = 0.0
var _mat: ShaderMaterial
var _last_cam_dist: float = 0.0

# kind 决定线宽与配色的默认组合；tint 不传（alpha=0）时按 kind 取默认色
static func create(p_kind: int, p_radius: float, p_height_fn: Callable, p_tint: Color = Color(0, 0, 0, 0)) -> GroundRangeRing:
	var ring := GroundRangeRing.new()
	ring.name = "GroundRangeRing"
	ring._init_ring(p_kind, p_radius, p_height_fn, p_tint)
	return ring

func _init_ring(p_kind: int, p_radius: float, p_height_fn: Callable, p_tint: Color) -> void:
	kind = p_kind
	radius = maxf(p_radius, 0.4)
	_height_fn = p_height_fn
	_tint = p_tint if p_tint.a > 0.001 else (VISION_TINT if kind == Kind.VISION else ACTION_TINT)
	_base_alpha = _tint.a
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_mat = GroundStripMesh.make_material(_tint, 0.26, 0.0, 0.20, 0.0)
	material_override = _mat
	# 真正建网格要等在树上（要用 global_position 采样地形），_ready 里会补上

func set_radius(p_radius: float) -> void:
	p_radius = maxf(p_radius, 0.4)
	if absf(p_radius - radius) < 0.01:
		return
	radius = p_radius
	_rebuild(true)

func set_tint(c: Color) -> void:
	_tint = c
	_base_alpha = c.a
	_mat.set_shader_parameter("tint", _tint)

func set_ring_visible(on: bool) -> void:
	visible = on
	set_process(on)

func _ready() -> void:
	# 脱离父节点的变换：单位会转身、会被模型节点缩放/倾斜，网格的高度是按
	# 世界坐标逐顶点采样的，一旦叉在父节点下面，顶点会被父变换挪到别的位置，
	# 高度就和位置对不上——陆地上直接埋进土里（水面平所以看不出来）。
	# 用 top_level 让圈只跟随位置、不继承旋转/缩放，位置每帧自己同步。
	top_level = true
	# top_level 会把「当前的全局变换」留下来当自己的变换。单位这时多半是转过身的，
	# 圈就白捡了一个等于单位朝向的旋转，顶点会被转离它采样高度时的位置，
	# 陆地上随朝向偏出半米到几米（水面平所以看不出来）。这里把旋转/缩放清零。
	var keep: Vector3 = global_position
	transform.basis = Basis()
	global_position = keep
	_sync_to_parent()
	_rebuild(true)

# 把自身放到父节点（单位）的位置上；top_level 之后必须自己跟着走
func _sync_to_parent() -> void:
	var p := get_parent()
	if p is Node3D:
		var target: Vector3 = (p as Node3D).global_position
		if global_position.distance_squared_to(target) > 0.000001:
			global_position = target

func _process(delta: float) -> void:
	# 单位在动的时候地形没变，但圆心的位置变了，需要重新采样高度，
	# 否则单位走上坡，圈还留在原来的高度上。
	_pulse_t += delta
	_rebuild_timer -= delta
	_sync_to_parent()
	var moved: bool = global_position.distance_to(_last_center) > REBUILD_DISTANCE
	# 相机推近/拉远时，屏幕上的线宽会跟着变，必须重算「至少几个像素」的世界宽度，
	# 否则拉远到 50 米高时细线只剩不到 1 个像素，等于没画。
	var cam_moved: bool = false
	var vp := get_viewport()
	if vp != null:
		var cam := vp.get_camera_3d()
		if cam != null:
			var d: float = cam.global_position.distance_to(global_position)
			# 第一次拿到有效相机距离（建网格时相机可能还没进树）也要补一次重建
			if _last_cam_dist <= 0.001:
				cam_moved = true
			elif absf(d - _last_cam_dist) > maxf(_last_cam_dist * CAMERA_DIST_REL, 2.0):
				cam_moved = true
	if _rebuild_timer <= 0.0 and (moved or cam_moved):
		_rebuild(false)
	# 粗线（作用范围）做一点轻微的呼吸，细线保持安静，避免满屏都在闪
	if kind == Kind.ACTION and _mat != null:
		var k: float = 1.0 + PULSE_DEPTH * sin(_pulse_t * PULSE_SPEED)
		var c: Color = _tint
		c.a = clampf(_base_alpha * k, 0.0, 1.0)
		_mat.set_shader_parameter("tint", c)

# 相机距离（米）
func _camera_distance() -> float:
	var vp := get_viewport()
	if vp == null:
		return 0.0
	var cam := vp.get_camera_3d()
	if cam == null:
		return 0.0
	return cam.global_position.distance_to(global_position)

# 屏幕高度（像素）对应的世界高度
func _min_world_width(min_pixels: float) -> float:
	var vp := get_viewport()
	if vp == null:
		return 0.0
	var cam := vp.get_camera_3d()
	if cam == null:
		return 0.0
	var screen_h: float = vp.get_visible_rect().size.y
	if screen_h <= 1.0:
		return 0.0
	var d: float = _camera_distance()
	if d <= 0.01:
		return 0.0
	# 透视投影：距离 d 处，一屏高对应 2*d*tan(fov/2) 米
	var world_h: float = 2.0 * d * tan(deg_to_rad(cam.fov) * 0.5)
	return min_pixels * world_h / screen_h

# force=true 时无视距离阈值直接重建（半径变化/首次创建）
func _rebuild(force: bool) -> void:
	# 还没进场景树时 global_position 无效，等 _ready 再建
	if not is_inside_tree():
		return
	_last_center = global_position
	_rebuild_timer = REBUILD_INTERVAL
	_last_cam_dist = _camera_distance()
	var center: Vector3 = global_position
	# 网格建在本地空间：本地原点就是节点原点，所以要把世界坐标减回去。
	# top_level 之后自身不继承父节点的旋转/缩放，本地轴就是世界轴。
	var centerline: Array = GroundStripMesh.circle_points(Vector3.ZERO, radius)
	var local_center := Vector3(0.0, 0.0, 0.0)
	var pts: Array = []
	for p in centerline:
		pts.append(p + local_center)
	# 线宽取「固定米数」和「至少 N 个像素」的较大者：近看重观感，远看保证能看见
	var base_w: float = VISION_WIDTH if kind == Kind.VISION else ACTION_WIDTH
	var min_px: float = VISION_MIN_PIXELS if kind == Kind.VISION else ACTION_MIN_PIXELS
	var width: float = maxf(base_w, _min_world_width(min_px))
	var half_width: float = width * 0.5
	# 高度采样要在世界空间做：把本地圆心还原成世界坐标再去问地形。
	# 返回值必须再减掉圆心自身的高度——网格顶点是局部坐标，
	# 不减的话「节点自身高度 + 地形高度」会叠两次，圈就浮在半空。
	var to_local_y := func(local_p: Vector3) -> float:
		var w: Vector3 = center + Vector3(local_p.x, 0.0, local_p.z)
		return float(_height_fn.call(w)) - center.y
	mesh = GroundStripMesh.build_strip(pts, half_width, to_local_y, true)

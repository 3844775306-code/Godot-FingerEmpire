class_name GroundPathGuide
extends Node3D

# 路径指引带：替换掉原来那一串青色小球（路径球）。
#
# 小球的问题是又硬又飘：球心统一抬 0.3~1 米，和地面没有关系，草地、石板、
# 斜坡上都是一模一样的青点，整条路径看起来像「悬在空中的虚线」。
# 这里改成贴地的指引带：
#   1. 中心线逐顶点贴地，草坡/台阶会自然弯下去；
#   2. 实线会变成流动的虚线（沿线滚动），方向感由流动方向表达，比小球更直观；
#   3. 起点从脚下淡出、末端是一个缓慢呼吸的落点环，两头都不会突然断掉；
#   4. 整体半透明叠加在地面上，不写深度、不投影，跟地面的颜色混在一起。
#
# 一个单位最多一条指引带；框选多支军队时每支被选中的军队各画一条。

const DASH_COLOR: Color = Color(0.60, 0.96, 0.88, 0.55)   # 青白，和草地/土地都能叠
const DASH_WIDTH: float = 0.32                             # 虚线带宽（米）
const DASH_MIN_PIXELS: float = 3.2                         # 屏幕上至少占几个像素
const DASH_PER_METER: float = 0.85                         # 每米几个虚线周期（约 1.2 米一段）
const FLOW_SPEED: float = 0.55                             # 虚线滚动速度（周期/秒）
const END_COLOR: Color = Color(0.98, 0.86, 0.52, 0.62)     # 落点暖黄
const END_RADIUS: float = 0.45
const END_WIDTH: float = 0.15
const END_MIN_PIXELS: float = 2.2
const END_PULSE_SPEED: float = 2.1
# 相机距离变化超过这个比例就重算线宽
const CAMERA_DIST_REL: float = 0.12
const CAMERA_REBUILD_INTERVAL: float = 0.15

var points: Array = []
var _height_fn: Callable
var _dash_mat: ShaderMaterial
var _end_mat: ShaderMaterial
var _end_node: MeshInstance3D
var _flow: float = 0.0
var _pulse_t: float = 0.0
var _pending_build: bool = false
var _last_cam_dist: float = 0.0
var _cam_timer: float = 0.0

static func create(p_points: Array, p_height_fn: Callable, tint: Color = Color(0, 0, 0, 0)) -> GroundPathGuide:
	var guide := GroundPathGuide.new()
	guide.name = "GroundPathGuide"
	guide._init_guide(p_points, p_height_fn, tint)
	return guide

func _init_guide(p_points: Array, p_height_fn: Callable, tint: Color) -> void:
	# 调用方可能传入空/失效的 Callable（客户端地形未就绪、脚本热重载、管理器已释放），
	# 直接 call() 会抛 "Attempt to call function 'null::null (Callable)' on a null instance."
	# 这里和 GroundRangeRing 一样先兜底成「保持原 y」的采样器。
	_height_fn = p_height_fn if p_height_fn.is_valid() else _flat_height_fn()
	_dash_mat = GroundStripMesh.make_material(tint if tint.a > 0.001 else DASH_COLOR, 0.34, DASH_PER_METER, 0.22, 1.0)
	var ribbon := MeshInstance3D.new()
	ribbon.name = "GuideRibbon"
	ribbon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ribbon.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	ribbon.material_override = _dash_mat
	add_child(ribbon)
	_end_node = MeshInstance3D.new()
	_end_node.name = "GuideEnd"
	_end_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_end_node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_end_mat = GroundStripMesh.make_material(END_COLOR, 0.30, 0.0, 0.16, 0.0)
	_end_node.material_override = _end_mat
	add_child(_end_node)
	points = _sanitize(p_points)
	# 网格要进树之后才建（依赖 global_position / 地形高度），_ready 里补建
	_pending_build = true

func _ready() -> void:
	if _pending_build:
		_pending_build = false
		_rebuild()

func set_points(p_points: Array) -> void:
	points = _sanitize(p_points)
	if not is_inside_tree():
		_pending_build = true
		return
	_rebuild()

# 路径点可能是 Vector3，也可能是快照里的 [x,y,z] 数组或字典，这里统一成 Vector3
func _sanitize(src: Array) -> Array:
	var out: Array = []
	for e in src:
		var v: Vector3
		if e is Vector3:
			v = e
		elif e is Array and e.size() >= 3:
			v = Vector3(float(e[0]), float(e[1]), float(e[2]))
		elif e is Dictionary and e.has("x"):
			v = Vector3(float(e["x"]), 0.0, float(e["z"]))
		else:
			continue
		# 贴地之后 y 由地形决定，原始 y 只作为拿不到地形时的兜底
		var base: Vector3 = v
		base.y = 0.0
		if not out.is_empty():
			# 距离过近的点直接丢掉，避免虚线被抖成一片
			var prev: Vector3 = out[out.size() - 1]
			if Vector2(base.x - prev.x, base.z - prev.z).length() < 0.25:
				continue
		out.append(base)
	return out

func _rebuild() -> void:
	var ribbon := get_node_or_null("GuideRibbon") as MeshInstance3D
	if ribbon == null:
		return
	if points.size() < 2:
		ribbon.mesh = null
		if _end_node != null:
			_end_node.mesh = null
		return
	_last_cam_dist = _camera_distance()
	# 运行中高度采样器也可能失效（地形管理器被释放），每次重建前再校验一次
	var height_fn: Callable = _height_fn
	if not height_fn.is_valid():
		height_fn = _flat_height_fn()
		_height_fn = height_fn
	# 中心线在本地空间：节点自身放在世界原点（挂在 entities_container 下）
	var origin: Vector3 = global_position
	var local: Array = []
	for p in points:
		local.append(Vector3(p.x - origin.x, 0.0, p.z - origin.z))
	# 路径点可能被抽样得很稀，先加密到 1.1 米一段，贴地带才不会斜插进地形
	local = GroundStripMesh.densify(local, 1.1)
	# 若指引带挂在会旋转的父节点下，本地偏移也要先按基向量转到世界方向，
	# 否则顶点采到的高度和它实际所在的位置错开，陆地上会埋进地里。
	var basis: Basis = global_transform.basis
	var denom: float = basis.y.y
	if absf(denom) < 0.0001:
		denom = 1.0
	var to_local_y := func(lp: Vector3) -> float:
		var off: Vector3 = basis * Vector3(lp.x, 0.0, lp.z)
		return (float(height_fn.call(origin + Vector3(off.x, 0.0, off.z))) - origin.y) / denom
	# 线宽取「固定米数」和「至少 N 个像素」的较大者：远景下细虚线会彻底消失
	var dash_w: float = maxf(DASH_WIDTH, _min_world_width(DASH_MIN_PIXELS))
	ribbon.mesh = GroundStripMesh.build_strip(local, dash_w * 0.5, to_local_y, false)
	# 落点环
	var last_world: Vector3 = points[points.size() - 1]
	var circle: Array = GroundStripMesh.circle_points(Vector3.ZERO, END_RADIUS)
	var last_local := Vector3(last_world.x - origin.x, 0.0, last_world.z - origin.z)
	var end_local: Array = []
	for p in circle:
		end_local.append(p + last_local)
	var end_w: float = maxf(END_WIDTH, _min_world_width(END_MIN_PIXELS))
	_end_node.mesh = GroundStripMesh.build_strip(end_local, end_w * 0.5, to_local_y, true)

# 相机到指引带起点的距离
func _camera_distance() -> float:
	var vp := get_viewport()
	if vp == null:
		return 0.0
	var cam := vp.get_camera_3d()
	if cam == null:
		return 0.0
	return cam.global_position.distance_to(global_position)

# 空 Callable / 地形管理器已释放时的兜底高度：不改顶点 y，至少不会报错。
static func _flat_height_fn() -> Callable:
	return func(p: Vector3) -> float:
		return p.y

# 「至少 N 个像素」换算成距相机 d 处的世界宽度
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
	return min_pixels * (2.0 * d * tan(deg_to_rad(cam.fov) * 0.5)) / screen_h

func _process(delta: float) -> void:
	# 虚线沿线滚动 = 前进方向；静止时不更新，避免空转
	_flow += delta * FLOW_SPEED
	if _dash_mat != null:
		_dash_mat.set_shader_parameter("dash_flow", _flow)
	_pulse_t += delta
	if _end_mat != null:
		var c: Color = END_COLOR
		c.a = clampf(END_COLOR.a * (1.0 + 0.20 * sin(_pulse_t * END_PULSE_SPEED)), 0.0, 1.0)
		_end_mat.set_shader_parameter("tint", c)
	# 相机推近/拉远时重算线宽，否则拉远后虚线会细到看不见
	_cam_timer -= delta
	if _cam_timer <= 0.0:
		_cam_timer = CAMERA_REBUILD_INTERVAL
		var d: float = _camera_distance()
		if _last_cam_dist > 0.001 and absf(d - _last_cam_dist) > maxf(_last_cam_dist * CAMERA_DIST_REL, 2.0):
			_rebuild()

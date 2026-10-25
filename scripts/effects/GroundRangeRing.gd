class_name GroundRangeRing
extends MeshInstance3D

# 选中单位时贴在地上的一圈范围线。
#
#   视野范围 = 细线（淡青白，0.11 米宽）
#   作用范围 = 粗线（暖琥珀，0.34 米宽）——军队射程、官员光环半径
#
# 不用圆环模型（TorusMesh）的原因是它是一块刚性平面：地形一起伏就会一半埋进土里、
# 一半浮在空中，看着像一块圆盘砸在地上。这里按地形逐顶点贴地画一条带子，
# 材质用 unshaded + 不写深度 + 横向软边，和地面是「叠一层颜色」而不是「贴一张纸」。

enum Kind { VISION, ACTION }

const VISION_WIDTH: float = 0.11
const ACTION_WIDTH: float = 0.34
const VISION_TINT: Color = Color(0.80, 0.92, 1.00, 0.26)
const ACTION_TINT: Color = Color(1.00, 0.84, 0.50, 0.34)

# 移动后重建网格的阈值：太小会每帧重建，太大会看到线跟不上地形
const REBUILD_DISTANCE: float = 0.18
const REBUILD_INTERVAL: float = 0.12
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
	_mat = GroundStripMesh.make_material(_tint, 0.44, 0.0, 0.22, 0.0)
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
	_rebuild(true)

func _process(delta: float) -> void:
	# 单位在动的时候地形没变，但圆心的位置变了，需要重新采样高度，
	# 否则单位走上坡，圈还留在原来的高度上。
	_pulse_t += delta
	_rebuild_timer -= delta
	if _rebuild_timer <= 0.0 and global_position.distance_to(_last_center) > REBUILD_DISTANCE:
		_rebuild(false)
	# 粗线（作用范围）做一点轻微的呼吸，细线保持安静，避免满屏都在闪
	if kind == Kind.ACTION and _mat != null:
		var k: float = 1.0 + PULSE_DEPTH * sin(_pulse_t * PULSE_SPEED)
		var c: Color = _tint
		c.a = clampf(_base_alpha * k, 0.0, 1.0)
		_mat.set_shader_parameter("tint", c)

# force=true 时无视距离阈值直接重建（半径变化/首次创建）
func _rebuild(force: bool) -> void:
	# 还没进场景树时 global_position 无效，等 _ready 再建
	if not is_inside_tree():
		return
	_last_center = global_position
	_rebuild_timer = REBUILD_INTERVAL
	var center: Vector3 = global_position
	# 网格建在本地空间：本地原点就是节点原点，所以要把世界坐标减回去。
	# 这样范围圈可以直接挂在单位节点下面，跟着单位一起平移/转身，不用每帧同步位置。
	var centerline: Array = GroundStripMesh.circle_points(Vector3.ZERO, radius)
	var local_center := Vector3(0.0, 0.0, 0.0)
	var pts: Array = []
	for p in centerline:
		pts.append(p + local_center)
	var half_width: float = (VISION_WIDTH if kind == Kind.VISION else ACTION_WIDTH) * 0.5
	# 高度采样要在世界空间做：把本地圆心还原成世界坐标再去问地形。
	# 返回值必须再减掉圆心自身的高度——网格顶点是局部坐标，
	# 不减的话「节点自身高度 + 地形高度」会叠两次，圈就浮在半空。
	var to_local_y := func(local_p: Vector3) -> float:
		var w: Vector3 = center + Vector3(local_p.x, 0.0, local_p.z)
		return float(_height_fn.call(w)) - center.y
	mesh = GroundStripMesh.build_strip(pts, half_width, to_local_y, true)

class_name OilSmoke
extends Node3D

# 石油资源的冒烟特效。
#
# 石油在 3D 里用的是 water-rocks 模型（几块黑石头），本身没有任何「油」的暗示，
# 混在矿石堆里完全看不出来。这里给它加常年不断的黑烟柱：
#   1. 粒子往上飘、边飘边扩散变淡，看起来像油气从石缝里渗出来；
#   2. 脚下一圈深色油渍贴花，把石头和地面糊在一起；
#   3. 全部用 CPUParticles3D，数量压得很低，几十个油点也不至于掉帧。
# 服务端（单机/联机主机）与联机客户端共用同一份实现，两边外观一致。

# 一个油点最多同时存在的烟粒子数。取值偏小是因为地图上石油点可能成片出现。
const SMOKE_AMOUNT: int = 40
# 烟要飘到半空中才有「油井在冒气」的样子：寿命拉长到 4 秒，
# 配合上升初速度和持续上浮加速度，柱顶能到 8 米左右（约两三层楼高）。
const SMOKE_LIFETIME: float = 4.0
const SMOKE_RISE: float = 1.15        # 上升初速度（米/秒）
const SMOKE_UP_ACCEL: float = 0.42    # 持续上浮加速度，模拟热气往上顶
const SMOKE_DRIFT: Vector3 = Vector3(0.10, 0.0, 0.06)  # 轻微横向漂移，柱子别笔直得像根杆
const SMOKE_SPREAD: float = 0.28      # 出生点水平散布半径
# 俯视时整根烟柱会叠在同一个屏幕小区域里，透明度会累加，所以看着很明显；
# 平视时烟柱沿竖直方向铺开，每团烟只剩自己的透明度，原来的 0.34 倍尺寸
# 在黑蓝色水面上几乎看不见。这里把单团烟放大、加浓，保证侧视也有体积感。
const SMOKE_START_SCALE: float = 0.52
const SMOKE_END_SCALE: float = 2.70   # 飘到高处散得更开

const OIL_STAIN_COLOR: Color = Color(0.10, 0.09, 0.08, 0.72)
const OIL_STAIN_CULL_MASK: int = 1 | (1 << 19)

static var _puff_tex: ImageTexture = null

# 程序生成一张柔边圆斑，给烟粒子当贴图。比起纯色方块，柔边圆才有「烟」的感觉。
static func puff_texture() -> ImageTexture:
	if _puff_tex != null:
		return _puff_tex
	var n: int = 48
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var u: float = (float(x) + 0.5) / float(n) * 2.0 - 1.0
			var v: float = (float(y) + 0.5) / float(n) * 2.0 - 1.0
			var d: float = sqrt(u * u + v * v)
			# 中心实、边缘软，再叠一点低频扰动让圆不呆板
			var wobble: float = sin(atan2(v, u) * 3.0 + 0.8) * 0.10
			var a: float = clampf((0.92 + wobble - d) / 0.55, 0.0, 1.0)
			a = a * a * (3.0 - 2.0 * a)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	_puff_tex = ImageTexture.create_from_image(img)
	return _puff_tex

static func create(body_radius: float) -> OilSmoke:
	var node := OilSmoke.new()
	node.name = "OilSmoke"
	node._build(body_radius)
	return node

func _build(body_radius: float) -> void:
	var r: float = maxf(body_radius, 0.35)
	_add_stain(r)
	_add_smoke(r)

# 脚下油渍：复用资源地皮那套贴花，把黑石头和地面颜色过渡掉
func _add_stain(body_radius: float) -> void:
	var decal := Decal.new()
	decal.name = "OilStain"
	decal.texture_albedo = WorldResource.ground_patch_texture()
	decal.modulate = OIL_STAIN_COLOR
	decal.albedo_mix = 0.75
	# 只投到世界层（地形/水面），别把马路过的单位染色
	decal.cull_mask = OIL_STAIN_CULL_MASK
	var half: float = body_radius * 1.9 + 0.5
	decal.size = Vector3(half * 2.0, 5.0, half * 2.0)
	decal.upper_fade = 1.0
	decal.lower_fade = 1.0
	add_child(decal)

func _add_smoke(body_radius: float) -> void:
	var smoke := CPUParticles3D.new()
	smoke.name = "OilSmokePuff"
	smoke.amount = SMOKE_AMOUNT
	smoke.lifetime = SMOKE_LIFETIME
	smoke.local_coords = false
	smoke.emitting = true
	smoke.preprocess = SMOKE_LIFETIME   # 进场时烟柱已经是满的，不用等它长出来
	smoke.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	smoke.emission_sphere_radius = SMOKE_SPREAD
	smoke.direction = Vector3.UP
	smoke.spread = 12.0
	smoke.initial_velocity_min = SMOKE_RISE * 0.75
	smoke.initial_velocity_max = SMOKE_RISE * 1.3
	# 重力这里当「浮力」用：持续向上加速，烟才爬得高，不会升两步就散在原地
	smoke.gravity = Vector3(SMOKE_DRIFT.x, SMOKE_UP_ACCEL, SMOKE_DRIFT.z)
	# 阻尼要小，否则初速度几秒就被吃掉，烟柱只能贴着地面打转
	smoke.damping_min = 0.02
	smoke.damping_max = 0.05
	smoke.angular_velocity_min = -12.0
	smoke.angular_velocity_max = 12.0
	smoke.scale_amount_min = SMOKE_START_SCALE
	smoke.scale_amount_max = SMOKE_START_SCALE * 1.5
	# 沿生命周期逐渐扩散、变淡：这就是烟和「小黑球往上飞」的区别
	var grow := Curve.new()
	grow.add_point(Vector2(0.0, 1.0))
	grow.add_point(Vector2(1.0, SMOKE_END_SCALE / SMOKE_START_SCALE))
	smoke.scale_amount_curve = grow
	smoke.visibility_aabb = AABB(Vector3(-9, -2, -9), Vector3(18, 18, 18))

	var quad := QuadMesh.new()
	quad.size = Vector2(0.85, 0.85)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = puff_texture()
	# 不写深度，避免烟柱互相把对方切出硬边；但要排在半透明水面之后绘制，
	# 否则低角度时水面会把整根烟柱盖掉，只剩俯视能看到。
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.render_priority = 2
	quad.material = mat
	smoke.mesh = quad

	var ramp := Gradient.new()
	ramp.set_color(0, Color(0.16, 0.15, 0.14, 0.0))    # 刚冒出来是透明的
	ramp.set_color(1, Color(0.16, 0.14, 0.12, 0.0))    # 飘散了也透明
	ramp.add_point(0.10, Color(0.10, 0.095, 0.09, 0.82))
	ramp.add_point(0.40, Color(0.18, 0.17, 0.16, 0.64))
	ramp.add_point(0.75, Color(0.30, 0.28, 0.26, 0.38))
	smoke.color_ramp = ramp

	# 从石头堆顶部往外冒，不要从地基下面钻出来
	smoke.position = Vector3(0.0, body_radius * 0.9 + 0.15, 0.0)
	add_child(smoke)

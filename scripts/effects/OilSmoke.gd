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
const SMOKE_AMOUNT: int = 16
const SMOKE_LIFETIME: float = 2.8
const SMOKE_RISE: float = 0.65        # 上升初速度（米/秒）
const SMOKE_SPREAD: float = 0.16      # 出生点水平散布半径
const SMOKE_START_SCALE: float = 0.34
const SMOKE_END_SCALE: float = 1.25

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
	smoke.spread = 14.0
	smoke.initial_velocity_min = SMOKE_RISE * 0.6
	smoke.initial_velocity_max = SMOKE_RISE * 1.3
	smoke.gravity = Vector3(0.0, 0.18, 0.0)   # 略微上浮，别像落灰一样往下掉
	smoke.damping_min = 0.05
	smoke.damping_max = 0.12
	smoke.angular_velocity_min = -12.0
	smoke.angular_velocity_max = 12.0
	smoke.scale_amount_min = SMOKE_START_SCALE
	smoke.scale_amount_max = SMOKE_START_SCALE * 1.5
	# 沿生命周期逐渐扩散、变淡：这就是烟和「小黑球往上飞」的区别
	var grow := Curve.new()
	grow.add_point(Vector2(0.0, 1.0))
	grow.add_point(Vector2(1.0, SMOKE_END_SCALE / SMOKE_START_SCALE))
	smoke.scale_amount_curve = grow
	smoke.visibility_aabb = AABB(Vector3(-6, -2, -6), Vector3(12, 10, 12))

	var quad := QuadMesh.new()
	quad.size = Vector2(0.55, 0.55)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = puff_texture()
	# 不写深度，避免烟柱互相把对方切出硬边
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	quad.material = mat
	smoke.mesh = quad

	var ramp := Gradient.new()
	ramp.set_color(0, Color(0.16, 0.15, 0.14, 0.0))    # 刚冒出来是透明的
	ramp.set_color(1, Color(0.16, 0.14, 0.12, 0.0))    # 飘散了也透明
	ramp.add_point(0.18, Color(0.13, 0.12, 0.11, 0.55))
	ramp.add_point(0.65, Color(0.24, 0.22, 0.20, 0.30))
	smoke.color_ramp = ramp

	# 从石头堆顶部往外冒，不要从地基下面钻出来
	smoke.position = Vector3(0.0, body_radius * 0.9 + 0.15, 0.0)
	add_child(smoke)

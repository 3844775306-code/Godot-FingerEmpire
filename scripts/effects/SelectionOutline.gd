class_name SelectionOutline
extends RefCounted

# 选中指示：单位「边缘发光」，用来替代脚下那个选中环。
# 做法：给被选中的模型复制一份 MeshInstance3D（同一份 mesh / skin / skeleton_path，
# 所以骨骼动画、蒙皮、朝向全都跟本体完全同步），只给这份副本挂一个外壳描边材质：
#   顶点沿法线撑出去一圈 → 只画背面（cull_front）→ 身体本体把它盖住，
#   露出来的就只有模型轮廓外面那一圈；unshaded + 加法混合 + 不写深度 = 边缘发光。
# 为什么是「复制一份 MeshInstance」而不是「给原材质加 next_pass」：
#   实测 Godot 4.7 里 next_pass / material_overlay 这两条附加通道拿不到蒙皮数据，
#   副本只有 bind pose 那一小块会被画出来（一只脚那么大），残留成脏点。
#   复制实例走的是正常渲染路径，蒙皮一定跟随。
# 其他取舍：
#   · 描边宽度按当前相机换算成「米」，再除以模型缩放（因为放大是在模型空间做的），
#     这样任何缩放层级下看上去都是差不多粗的一圈；
#   · 材质按（颜色 + 线宽）缓存共享，同批选中的单位复用同一份；
#   · 透明表面（树叶、旗子、披风）的那份副本跳过，否则会出现一圈脏边；
#   · 取消选中时把副本删掉，原模型一个字节都不改。
# 想退回原来的选中环，把 ENABLED 改成 false 即可（环会重新显示）。

const ENABLED: bool = true
# 选中色：亮薄荷绿，草地/雪地/水面上都能读出来，又不至于像红色那样抢眼
const DEFAULT_COLOR := Color(0.60, 1.00, 0.70, 0.92)
# 目标描边宽度（3D 渲染缓冲像素）：小兵约 9px，体积大的建筑最多 12px。
# 项目开了 3D 缩放，缓冲比屏幕小，所以这个数值大约对应屏幕上 17~23 像素。
# 调参只看这两个常量：PX_BASE 决定最小粗细（小兵），PX_MAX 决定建筑的上限。
const PX_BASE: float = 9.0
const PX_PER_METER: float = 0.20
const PX_MAX: float = 12.0
# 米为单位的兜底夹取，避免相机没准备好时算出 0 或大得离谱
const WIDTH_MIN: float = 0.01
const WIDTH_MAX: float = 0.60
# 描边副本的节点名前缀，同时用于识别/清理
const NODE_PREFIX := "SelOutline"
# 描边不该出现在这些辅助节点上
const SKIP_NAMES := ["SelectionRing", "ClientSelectionRing", "GroundRangeRing", "CasterAura"]

const SHADER_CODE := """
shader_type spatial;
render_mode unshaded, cull_front, blend_mix, depth_draw_never, shadows_disabled;

uniform vec4 glow_color : source_color = vec4(0.60, 1.0, 0.70, 0.92);
uniform float hull_width = 0.06;   // 模型空间单位（调用方会按模型缩放折算好）
uniform float pulse_speed = 2.2;

void vertex() {
	// 沿法线把外壳撑出去一圈，只画背面 → 本体盖住里面，露出来的只有轮廓
	VERTEX += NORMAL * hull_width;
}

void fragment() {
	// 轻微呼吸：安静的单位也有存在感，但不会闪得烦人
	float pulse = 0.78 + 0.22 * sin(TIME * pulse_speed);
	ALBEDO = glow_color.rgb;
	ALPHA = glow_color.a * pulse;
}
"""

# 颜色 + 线宽 → 外壳材质（跨单位共享）
static var _material_cache: Dictionary = {}
static var _shader: Shader = null


static func _get_shader() -> Shader:
	if _shader == null:
		_shader = Shader.new()
		_shader.code = SHADER_CODE
	return _shader


# 给一棵实体子树打开/关闭描边
static func apply(root: Node, on: bool, color: Color = DEFAULT_COLOR) -> void:
	if not ENABLED or root == null or not is_instance_valid(root):
		return
	if on:
		_add_outlines(root, color)
	else:
		clear(root)


# 清掉一棵实体子树下所有描边副本
static func clear(root: Node) -> void:
	if root == null or not is_instance_valid(root):
		return
	for dup in _collect_outlines(root):
		dup.queue_free()


static func is_outlined(root: Node) -> bool:
	return root != null and is_instance_valid(root) and not _collect_outlines(root).is_empty()


static func _add_outlines(root: Node, color: Color) -> void:
	var world_per_px: float = world_per_pixel(root)
	for mi in _collect_meshes(root):
		if mi.get_parent() == null or _has_outline(mi):
			continue
		var width_px: float = clampf(PX_BASE + _max_dimension(mi) * PX_PER_METER, PX_BASE, PX_MAX)
		var width_world: float = clampf(width_px * world_per_px, WIDTH_MIN, WIDTH_MAX)
		var scale: float = mi.global_transform.basis.get_scale().x
		if absf(scale) < 0.0001:
			continue
		var dup := mi.duplicate() as MeshInstance3D
		if dup == null:
			continue
		dup.name = "%s_%d" % [NODE_PREFIX, mi.get_instance_id()]
		# 只画"壳"，不参与阴影/遮挡标记等其它用途
		dup.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		dup.material_override = _outline_material(color, width_world / absf(scale))
		dup.material_overlay = null
		dup.visible = true
		dup.set_meta("_sel_outline_src", mi.get_instance_id())
		mi.get_parent().add_child(dup)
		# 副本必须和本体在同一个变换下（duplicate 会带上变换，但位置/旋转/缩放取自本体）
		dup.global_transform = mi.global_transform


static func _has_outline(mi: MeshInstance3D) -> bool:
	if mi.get_parent() == null:
		return false
	var want := "%s_%d" % [NODE_PREFIX, mi.get_instance_id()]
	for c in mi.get_parent().get_children():
		if c is MeshInstance3D and String(c.name) == want:
			return true
	return false


static func _collect_outlines(root: Node) -> Array:
	var out: Array = []
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D and String(node.name).begins_with(NODE_PREFIX):
			out.append(node)
			continue
		for c in node.get_children():
			stack.append(c)
	return out


static func _collect_meshes(root: Node) -> Array:
	var out: Array = []
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D:
			var mi := node as MeshInstance3D
			if mi.mesh == null or mi.mesh.get_surface_count() == 0:
				continue
			if SKIP_NAMES.has(String(mi.name)) or String(mi.name).begins_with(NODE_PREFIX):
				continue
			# 透明表面（树叶/旗子/披风）跳过：壳会变成一圈脏边
			var src: Material = mi.get_active_material(0)
			if src != null:
				var bm := src as BaseMaterial3D
				if bm != null and bm.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
					continue
			out.append(mi)
			continue
		for c in node.get_children():
			stack.append(c)
	return out


# 单个模型的最大边长（米），用来给大块头更粗的描边
static func _max_dimension(mi: MeshInstance3D) -> float:
	var aabb: AABB = mi.get_aabb()
	var sc: Vector3 = mi.global_transform.basis.get_scale().abs()
	return maxf(aabb.size.x * sc.x, maxf(aabb.size.y * sc.y, aabb.size.z * sc.z))


# 当前相机下「1 个像素等于多少米」。
# 注意：项目开了 UI 缩放，get_visible_rect() 拿到的是设计分辨率（1400 高），
# 而 3D 实际按窗口像素渲染，所以这里用窗口高度。
static func world_per_pixel(root: Node) -> float:
	var vp: Viewport = root.get_viewport() if root.is_inside_tree() else null
	var cam: Camera3D = vp.get_camera_3d() if vp != null else null
	# 用 3D 渲染目标的实际高度：项目开了 3D 缩放，视口矩形是设计分辨率（1400），
	# 窗口是屏幕像素，而真正渲染 3D 的缓冲是两者都不是的第三个数（实测 371）。
	var h: float = float(vp.get_texture().get_size().y) if vp != null else 720.0
	if h <= 1.0:
		h = 720.0
	if cam == null:
		return 0.03
	if cam.projection == Camera3D.PROJECTION_ORTHOGONAL:
		return cam.size / h
	var node3d := root as Node3D
	var dist: float = cam.global_position.distance_to(node3d.global_position if node3d != null else Vector3.ZERO)
	return 2.0 * maxf(dist, 0.5) * tan(deg_to_rad(cam.fov) * 0.5) / h


static func _outline_material(color: Color, width_model: float) -> ShaderMaterial:
	var key := "%s|%.4f" % [color.to_html(), width_model]
	var cached = _material_cache.get(key)
	if cached != null:
		return cached
	var mat := ShaderMaterial.new()
	mat.shader = _get_shader()
	mat.set_shader_parameter("glow_color", color)
	mat.set_shader_parameter("hull_width", width_model)
	_material_cache[key] = mat
	return mat

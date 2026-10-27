extends Node

# 建造菜单图标生成器：把可建造建筑的 GLB 模型渲染成 256x256 透明底 PNG。
#
# 用法（改了建筑模型或新增建筑时跑一次）：
#   Godot_v4.7.2-stable_win64_console.exe --path <项目根> res://tools/render_build_icons.tscn
# 生成结果写到 res://assets/ui/build_icons/<建筑id>.png，随项目一起提交。
# 每张图会先裁掉透明边，再等比缩放进 210px、底边对齐 y=236，并垫一层椭圆软阴影，
# 这样不同尺寸的建筑在卡片里视觉重量一致。

const OUT_DIR := "res://assets/ui/build_icons/"
const BUILDING_IDS: Array = [7, 8, 21, 22, 23, 24, 25, 26, 27, 28, 29, 41, 42, 52, 53, 54, 64]

var _vp: SubViewport
var _cam: Camera3D
var _world: Node3D
var _slot: Node3D

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	_vp = SubViewport.new()
	_vp.size = Vector2i(256, 256)
	_vp.transparent_bg = true
	_vp.own_world_3d = true
	_vp.msaa_3d = Viewport.MSAA_4X
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_vp)

	_world = Node3D.new()
	_vp.add_child(_world)

	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.82, 0.76, 0.66)
	env.ambient_light_energy = 0.85
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	we.environment = env
	_world.add_child(we)

	_add_light(Vector3(-0.55, -0.75, 0.5), 2.2, Color(1.0, 0.95, 0.86), true)
	_add_light(Vector3(0.7, -0.4, 0.55), 0.9, Color(0.72, 0.8, 1.0), false)
	_add_light(Vector3(0.2, 0.7, -0.8), 0.7, Color(1.0, 0.9, 0.8), false)

	_cam = Camera3D.new()
	_cam.fov = 32.0
	_cam.near = 0.05
	_cam.far = 4000.0
	_world.add_child(_cam)

	_slot = Node3D.new()
	_world.add_child(_slot)

	await get_tree().process_frame
	for id in BUILDING_IDS:
		await _render_building(id)
	print("GEN_DONE")
	get_tree().quit()

func _add_light(dir: Vector3, energy: float, color: Color, shadows: bool) -> void:
	var l := DirectionalLight3D.new()
	l.light_energy = energy
	l.light_color = color
	l.shadow_enabled = shadows
	l.transform.basis = Basis.looking_at(dir.normalized(), Vector3.UP)
	_world.add_child(l)

func _render_building(id: int) -> void:
	for c in _slot.get_children():
		c.queue_free()
	var model_path: String = RTSConfig.get_entity_model(id)
	if model_path == "" or not ResourceLoader.exists(model_path):
		push_warning("缺少模型: %d %s" % [id, model_path])
		return
	var scene = load(model_path)
	if scene == null:
		push_warning("加载失败: %d %s" % [id, model_path])
		return
	var node = scene.instantiate()
	_slot.add_child(node)
	await get_tree().process_frame
	await get_tree().process_frame

	var aabb := AABB()
	var first := true
	for mi in _all_meshes(node):
		var box: AABB = mi.global_transform * mi.get_aabb()
		if first:
			aabb = box
			first = false
		else:
			aabb = aabb.merge(box)
	if first or aabb.size.length() <= 0.001:
		push_warning("模型没有网格: %d" % id)
		return

	var center: Vector3 = aabb.get_center()
	var radius: float = maxf(aabb.size.length() * 0.5, 0.05)
	var dir := Vector3(0.75, 0.62, 0.95).normalized()
	var dist: float = radius * 2.6
	_cam.global_position = center + dir * dist
	_cam.look_at(center, Vector3.UP)
	await get_tree().process_frame
	await get_tree().process_frame

	var img: Image = _vp.get_texture().get_image()
	if img == null:
		push_warning("渲染失败: %d" % id)
		return
	img = _normalize_icon(img)
	img.save_png(OUT_DIR + "%d.png" % id)
	print("GEN %d %s 尺寸=%.1f" % [id, model_path.get_file(), aabb.size.length()])

func _all_meshes(node: Node, out: Array = []) -> Array:
	if node is MeshInstance3D:
		out.append(node)
	for c in node.get_children():
		_all_meshes(c, out)
	return out

# 裁掉透明边 → 等比缩放 → 底部对齐 → 加椭圆软阴影
func _normalize_icon(img: Image) -> Image:
	img.convert(Image.FORMAT_RGBA8)
	var used: Rect2i = img.get_used_rect()
	if used.size.x <= 0 or used.size.y <= 0:
		return img
	var crop: Image = img.get_region(used)
	var k: float = minf(210.0 / float(crop.get_width()), 210.0 / float(crop.get_height()))
	var nw: int = maxi(1, int(round(float(crop.get_width()) * k)))
	var nh: int = maxi(1, int(round(float(crop.get_height()) * k)))
	crop.resize(nw, nh, Image.INTERPOLATE_LANCZOS)

	var canvas := Image.create(256, 256, false, Image.FORMAT_RGBA8)
	canvas.fill(Color(0.0, 0.0, 0.0, 0.0))

	# 椭圆软阴影（先画，模型再盖上去）
	var sw: float = float(nw) * 0.92
	var sh: float = maxf(12.0, float(nh) * 0.16)
	var cx: float = 128.0
	var cy: float = 236.0
	for y in range(maxi(0, int(cy - sh)), mini(256, int(cy + sh) + 1)):
		for x in range(maxi(0, int(cx - sw * 0.5)), mini(256, int(cx + sw * 0.5) + 1)):
			var dx: float = (float(x) - cx) / (sw * 0.5)
			var dy: float = (float(y) - cy) / (sh * 0.5)
			var d: float = dx * dx + dy * dy
			if d <= 1.0:
				canvas.set_pixel(x, y, Color(0.0, 0.0, 0.0, (1.0 - d) * 0.42))

	var dst := Vector2i((256 - nw) / 2, 236 - nh)
	canvas.blit_rect(crop, Rect2i(0, 0, nw, nh), dst)
	return canvas

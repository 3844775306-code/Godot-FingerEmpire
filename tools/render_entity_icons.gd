extends Node

# 实体图标生成器：把每个兵种 / 资源点的 GLB 模型渲染成 256x256 透明底 PNG，
# 供「生产按钮」「单位信息面板」「框选分组列表」使用。
#
# 用法（改了兵种模型或新增兵种时跑一次）：
#   Godot_v4.7.2-stable_win64_console.exe --path <项目根> res://tools/render_entity_icons.tscn
# 结果写到 res://assets/ui/entity_icons/<实体id>.png，随项目一起提交。
# 取景与裁切规则跟建筑图标一致（等比缩放进 210px、底边对齐、垫椭圆软阴影），
# 这样单位和建筑的图标摆在一起视觉重量不会一大一小。

const OUT_DIR := "res://assets/ui/entity_icons/"

# 资源点（金矿/树林/石矿/农田/石油）+ EntityDatabase 里全部 type=2（单位）的 id
const ENTITY_IDS: Array = [
	0, 1, 2, 3, 4,
	5, 6, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19,
	30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40,
	43, 44, 45, 46, 47, 48, 49, 50, 51,
	55, 56, 57, 58, 59, 60, 61, 62, 63,
	65, 66, 67, 68, 69,
]

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
	for id in ENTITY_IDS:
		await _render_unit(id)
	print("GEN_DONE")
	get_tree().quit()

func _add_light(dir: Vector3, energy: float, color: Color, shadows: bool) -> void:
	var l := DirectionalLight3D.new()
	l.light_energy = energy
	l.light_color = color
	l.shadow_enabled = shadows
	l.transform.basis = Basis.looking_at(dir.normalized(), Vector3.UP)
	_world.add_child(l)

func _render_unit(id: int) -> void:
	for c in _slot.get_children():
		c.queue_free()
	# get_entity_model 对同一兵种会在角色池里随机挑模型；固定种子让图标每次都一样
	seed(id * 7919)
	var model_path: String = RTSConfig.get_entity_model(id, 1)
	if model_path == "" or not ResourceLoader.exists(model_path):
		push_warning("缺少模型: %d %s" % [id, model_path])
		print("GEN_SKIP %d 无模型" % id)
		return
	var scene = load(model_path)
	if scene == null:
		push_warning("加载失败: %d %s" % [id, model_path])
		print("GEN_SKIP %d 加载失败" % id)
		return
	var node = scene.instantiate()
	_slot.add_child(node)
	# 兵种差异主要靠手里的武器/盾牌/坐骑区分，这里按 Army._add_weapon 的规则补齐
	_add_equipment(node, id)
	_pose_idle(node)
	for i in range(4):
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
		print("GEN_SKIP %d 无网格" % id)
		return

	var center: Vector3 = aabb.get_center()
	var radius: float = maxf(aabb.size.length() * 0.5, 0.05)
	# 视平线略高一点的 3/4 侧前方视角：人物的脸、武器、坐骑都能看清
	var dir := Vector3(0.68, 0.34, 1.0).normalized()
	var dist: float = radius * 2.5
	_cam.global_position = center + dir * dist
	_cam.look_at(center, Vector3.UP)
	for i in range(3):
		await get_tree().process_frame

	var img: Image = _vp.get_texture().get_image()
	if img == null:
		push_warning("渲染失败: %d" % id)
		print("GEN_SKIP %d 渲染失败" % id)
		return
	img = _normalize_icon(img)
	img.save_png(OUT_DIR + "%d.png" % id)
	print("GEN %d %s 尺寸=%.1f" % [id, model_path.get_file(), aabb.size.length()])

# 与 entities/Army.gd::_add_weapon 保持一致：图标里要能看出弓/矛/剑/盾/坐骑
func _add_equipment(root: Node3D, id: int) -> void:
	var cfg: Dictionary = EntityDatabase.get_config(id)
	var br: float = float(cfg.get("body_radius", 0.5))
	if br <= 0.0:
		br = 0.5
	var wpath := ""
	if id in [12, 31, 37, 67]:
		wpath = "res://models/forest/weapon-bow.glb"
	elif id in [35, 69]:
		wpath = "res://models/arena/weapon-spear.glb"
	elif id in [11, 15, 19, 30, 32, 34, 36, 38, 65, 66, 68]:
		wpath = "res://models/arena/weapon-sword.glb"
	if wpath != "" and ResourceLoader.exists(wpath):
		var ws = load(wpath)
		if ws is PackedScene:
			var w = (ws as PackedScene).instantiate()
			if w is Node3D:
				(w as Node3D).position = Vector3(br * 1.2, br * 0.4, 0.0)
				if id in [12, 31, 37, 67]:
					(w as Node3D).rotation_degrees = Vector3(0, 180, 0)
				root.add_child(w)
	if id in [36, 37, 38, 68, 69] and ResourceLoader.exists("res://models/arena/shield-round.glb"):
		var shs = load("res://models/arena/shield-round.glb")
		if shs is PackedScene:
			var sh = (shs as PackedScene).instantiate()
			if sh is Node3D:
				(sh as Node3D).position = Vector3(-0.3, br * 0.6, 0.0)
				(sh as Node3D).scale = Vector3.ONE * 0.8
				root.add_child(sh)
	var mpath := ""
	if id in [15, 19, 38, 66, 67]:
		mpath = "res://models/pets/animal-dog.glb"
	elif id == 34:
		mpath = "res://models/pets/animal-elephant.glb"
	if mpath != "" and ResourceLoader.exists(mpath):
		var ms = load(mpath)
		if ms is PackedScene:
			var m = (ms as PackedScene).instantiate()
			if m is Node3D:
				(m as Node3D).position = Vector3(0.0, -br * 1.2, 0.0)
				(m as Node3D).scale = Vector3.ONE * 0.7
				root.add_child(m)

# 人物/动物模型都带待机动作，摆第一个 Idle 的中段，避免僵直的 T 字姿势
func _pose_idle(node: Node) -> void:
	for n in _all_nodes(node):
		if n is AnimationPlayer:
			var ap := n as AnimationPlayer
			var list: PackedStringArray = ap.get_animation_list()
			if list.is_empty():
				continue
			var pick := ""
			for nm in list:
				if String(nm).to_lower().contains("idle"):
					pick = String(nm)
					break
			if pick == "":
				pick = String(list[0])
			ap.play(pick)
			ap.seek(0.45, true)
			return

func _all_nodes(node: Node, out: Array = []) -> Array:
	if node is Node:
		out.append(node)
	for c in node.get_children():
		_all_nodes(c, out)
	return out

func _all_meshes(node: Node, out: Array = []) -> Array:
	if node is MeshInstance3D:
		out.append(node)
	for c in node.get_children():
		_all_meshes(c, out)
	return out

# 裁掉透明边 → 等比缩放 → 底部对齐 → 加椭圆软阴影（与建筑图标同一套规则）
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

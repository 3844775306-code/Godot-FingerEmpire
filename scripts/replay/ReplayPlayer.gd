extends Node3D

const ReplayStoreScript = preload("res://scripts/replay/ReplayStore.gd")
const GroundScript = preload("res://scripts/map/Ground.gd")
const CameraScript = preload("res://scripts/map/CameraController.gd")
const WallTierVisual = preload("res://scripts/effects/WallTierVisual.gd")

var _path: String = ""
var _header: Dictionary = {}
var _frames: Array = []
var _duration: float = 0.0
var _time: float = 0.0
var _speed: float = 1.0
var _playing: bool = true
var _last_frame_idx: int = -1
var _snap_next: bool = false
var _error: String = ""

var _entities_root: Node3D = null
var _entity_nodes: Dictionary = {}
var _camera: Camera3D = null

var _play_btn: Button = null
var _slider: HSlider = null
var _time_label: Label = null
var _title_label: Label = null
var _speed_opt: OptionButton = null
var _ui_updating: bool = false

func _ready() -> void:
	_path = ReplayStoreScript.pending_path
	if _path == "" or not FileAccess.file_exists(_path):
		_path = ReplayStoreScript.latest_path()
	if _path == "":
		_error = "还没有录像。完成一局单机或联机对战后会自动保存。"
		_build_ui()
		return
	var data := ReplayStoreScript.load_all(_path)
	if data.is_empty():
		_error = "录像文件损坏或格式不兼容。"
		_build_ui()
		return
	_header = data.get("header", {})
	_frames = data.get("frames", [])
	if _frames.is_empty():
		_error = "录像里没有可回放的帧。"
		_build_ui()
		return
	_duration = float(_header.get("duration", _frames[_frames.size() - 1].get("t", 0.0)))
	_build_world()
	_build_ui()
	_seek(0.0, true)
	_playing = true
	_update_play_button()

func _build_world() -> void:
	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.10, 0.12, 0.16)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.72, 0.78, 0.88)
	env.ambient_light_energy = 0.8
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env_node.environment = env
	add_child(env_node)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52.0, -38.0, 0.0)
	sun.light_energy = 1.8
	sun.shadow_enabled = true
	add_child(sun)

	var map_data: Dictionary = _header.get("map", {})
	var terrain = map_data.get("terrain", [])
	if terrain is Array and not terrain.is_empty():
		var ground := GroundScript.new()
		ground.name = "Map"
		ground.map_generated = true
		ground.map_size_override = terrain.size()
		add_child(ground)
		var height = map_data.get("height", [])
		var overlay = map_data.get("overlay", PackedByteArray())
		var preset := String(map_data.get("preset", ""))
		ground.apply_received_map(terrain, height, [], overlay, preset)

	_entities_root = Node3D.new()
	_entities_root.name = "ReplayEntities"
	add_child(_entities_root)

	_camera = Camera3D.new()
	_camera.name = "ReplayCamera"
	_camera.set_script(CameraScript)
	add_child(_camera)
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.min_zoom = 18.0
	_camera.max_zoom = 46.0
	_camera.size = 36.0
	_camera.position = Vector3(0.0, 42.0, 42.0)
	_camera.look_at(Vector3(0.0, 0.0, 0.0), Vector3.UP)
	_camera.current = true

func _build_ui() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "ReplayUI"
	add_child(canvas)
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(root)

	var top := ColorRect.new()
	top.color = Color(0.06, 0.05, 0.04, 0.88)
	top.set_anchors_preset(Control.PRESET_TOP_WIDE)
	top.offset_bottom = 54.0
	top.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(top)

	var top_box := HBoxContainer.new()
	top_box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	top_box.offset_left = 12.0
	top_box.offset_right = -12.0
	top_box.add_theme_constant_override("separation", 12)
	top.add_child(top_box)

	var back := Button.new()
	back.text = "← 返回录像列表"
	back.custom_minimum_size = Vector2(170, 36)
	back.pressed.connect(_on_back)
	top_box.add_child(back)

	_title_label = Label.new()
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title_label.add_theme_font_size_override("font_size", 20)
	_title_label.add_theme_color_override("font_color", Color(0.94, 0.86, 0.65))
	top_box.add_child(_title_label)

	var info := Label.new()
	info.custom_minimum_size = Vector2(190, 36)
	info.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	info.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	info.add_theme_font_size_override("font_size", 14)
	if not _error.is_empty():
		info.text = "无法播放"
	else:
		var meta: Dictionary = _header.get("meta", {})
		info.text = String(meta.get("map_name", "对局录像"))
	top_box.add_child(info)

	if not _error.is_empty():
		var msg := Label.new()
		msg.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
		msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		msg.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		msg.text = _error
		msg.add_theme_font_size_override("font_size", 24)
		msg.add_theme_color_override("font_color", Color(0.95, 0.65, 0.55))
		root.add_child(msg)
		return

	var bottom := ColorRect.new()
	bottom.color = Color(0.06, 0.05, 0.04, 0.9)
	bottom.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	bottom.offset_top = -72.0
	bottom.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(bottom)

	var bottom_box := HBoxContainer.new()
	bottom_box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bottom_box.offset_left = 16.0
	bottom_box.offset_right = -16.0
	bottom_box.add_theme_constant_override("separation", 10)
	bottom.add_child(bottom_box)

	_play_btn = Button.new()
	_play_btn.custom_minimum_size = Vector2(100, 36)
	_play_btn.pressed.connect(_toggle_play)
	bottom_box.add_child(_play_btn)

	_time_label = Label.new()
	_time_label.custom_minimum_size = Vector2(110, 36)
	_time_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_time_label.add_theme_font_size_override("font_size", 15)
	bottom_box.add_child(_time_label)

	_slider = HSlider.new()
	_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_slider.min_value = 0.0
	_slider.max_value = maxf(_duration, 0.01)
	_slider.step = 0.05
	_slider.value_changed.connect(_on_slider_changed)
	bottom_box.add_child(_slider)

	_speed_opt = OptionButton.new()
	_speed_opt.custom_minimum_size = Vector2(100, 36)
	for s in [0.5, 1.0, 2.0, 4.0]:
		_speed_opt.add_item("%sx" % str(s), _speed_opt.item_count)
		_speed_opt.set_item_metadata(_speed_opt.item_count - 1, s)
	_speed_opt.select(1)
	_speed_opt.item_selected.connect(_on_speed_selected)
	bottom_box.add_child(_speed_opt)

	var title := String(_header.get("meta", {}).get("map_name", "对局录像"))
	_title_label.text = "🎬 " + title
	_update_time_ui()

func _toggle_play() -> void:
	_playing = not _playing
	if _playing and _time >= _duration - 0.001:
		_seek(0.0, true)
	_update_play_button()

func _update_play_button() -> void:
	if _play_btn == null:
		return
	_play_btn.text = "⏸ 暂停" if _playing else "▶ 播放"

func _on_slider_changed(value: float) -> void:
	if _ui_updating:
		return
	_playing = false
	_seek(value, true)
	_update_play_button()

func _on_speed_selected(index: int) -> void:
	_speed = float(_speed_opt.get_item_metadata(index))

func _seek(value: float, snap: bool = true) -> void:
	_time = clampf(value, 0.0, _duration)
	_last_frame_idx = -1
	_snap_next = snap
	_update_frame_for_time()
	_update_time_ui()

func _update_frame_for_time() -> void:
	if _frames.is_empty():
		return
	var idx := 0
	while idx + 1 < _frames.size() and float(_frames[idx + 1].get("t", 0.0)) <= _time:
		idx += 1
	if idx == _last_frame_idx:
		return
	_last_frame_idx = idx
	_apply_frame(_frames[idx], _snap_next)
	_snap_next = false

func _apply_frame(frame: Dictionary, snap: bool) -> void:
	var seen: Dictionary = {}
	for d in frame.get("e", []):
		if not (d is Dictionary):
			continue
		var id := int(d.get("i", 0))
		if id == 0:
			continue
		seen[id] = true
		var slot: Dictionary
		if not _entity_nodes.has(id):
			slot = _create_entity(d)
			_entity_nodes[id] = slot
		else:
			slot = _entity_nodes[id]
			var node: Node3D = slot["node"]
			if not is_instance_valid(node):
				_entity_nodes.erase(id)
				slot = _create_entity(d)
				_entity_nodes[id] = slot
		var p: Array = d.get("p", [0, 0, 0])
		slot["target"] = Vector3(float(p[0]), float(p[1]), float(p[2]))
		slot["target_rot"] = float(d.get("r", 0.0))
		var eid := int(d.get("e", 0))
		var mp := String(d.get("mp", ""))
		var old_mp := String(slot.get("model_path", ""))
		if mp != "" and mp != old_mp:
			var old_model: Node3D = slot.get("model")
			if is_instance_valid(old_model):
				old_model.queue_free()
			slot["model"] = _make_model(slot["node"], d)
			slot["model_path"] = mp
		var model: Node3D = slot.get("model")
		if is_instance_valid(model):
			_apply_model_transform(model, d)
		if eid == 27:
			var col: Array = d.get("col", [0.7, 0.7, 0.7])
			var color := Color(float(col[0]), float(col[1]), float(col[2]))
			var ruin := bool(d.get("ruin", false))
			WallTierVisual.apply(slot["node"], 2 if ruin else int(d.get("lv", 1)), color)
		if snap:
			var node2: Node3D = slot["node"]
			node2.position = slot["target"]
			node2.rotation.y = slot["target_rot"]
	for id in _entity_nodes.keys():
		if seen.has(id):
			continue
		var old: Dictionary = _entity_nodes[id]
		var old_node: Node3D = old["node"]
		if is_instance_valid(old_node):
			old_node.queue_free()
		_entity_nodes.erase(id)

func _create_entity(d: Dictionary) -> Dictionary:
	var root := Node3D.new()
	root.name = "Entity_%d" % int(d.get("i", 0))
	_entities_root.add_child(root)
	var p: Array = d.get("p", [0, 0, 0])
	root.position = Vector3(float(p[0]), float(p[1]), float(p[2]))
	root.rotation.y = float(d.get("r", 0.0))
	var model := _make_model(root, d)
	return {
		"node": root,
		"model": model,
		"model_path": String(d.get("mp", "")),
		"target": root.position,
		"target_rot": root.rotation.y,
	}

func _make_model(root: Node3D, d: Dictionary) -> Node3D:
	var eid := int(d.get("e", 0))
	var lv := int(d.get("lv", 1))
	var model_path := String(d.get("mp", ""))
	if model_path == "" and eid == 27 and bool(d.get("c", false)):
		model_path = "res://models/castle/wall-corner.glb"
	if model_path == "" or not ResourceLoader.exists(model_path):
		model_path = RTSConfig.get_entity_model(eid, lv)
	var model: Node3D = null
	if model_path != "" and ResourceLoader.exists(model_path):
		var packed = load(model_path)
		if packed is PackedScene:
			model = packed.instantiate() as Node3D
	if model == null:
		var box := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = Vector3(1.0, 1.0, 1.0)
		box.mesh = mesh
		model = box
	root.add_child(model)
	_apply_model_transform(model, d)
	root.set_meta("_model_instance", model)
	root.set_meta("_entity_id", eid)

	var col: Array = d.get("col", [0.7, 0.7, 0.7])
	var color := Color(float(col[0]), float(col[1]), float(col[2]))
	if eid == 27:
		var ruin := bool(d.get("ruin", false))
		WallTierVisual.apply(root, 2 if ruin else lv, color)
	else:
		_tint_recursive(model, color)
	return model

func _apply_model_transform(model: Node3D, d: Dictionary) -> void:
	var mo: Array = d.get("mo", [0, 0, 0])
	var mr: Array = d.get("mr", [0, 0, 0])
	var ms: Array = d.get("ms", [1, 1, 1])
	model.position = Vector3(float(mo[0]), float(mo[1]), float(mo[2]))
	model.rotation = Vector3(float(mr[0]), float(mr[1]), float(mr[2]))
	model.scale = Vector3(float(ms[0]), float(ms[1]), float(ms[2]))

func _tint_recursive(node: Node, tint: Color) -> void:
	for child in node.get_children():
		if child is MeshInstance3D and child.mesh:
			for si in child.mesh.get_surface_count():
				var src = child.get_active_material(si)
				if src:
					var mat = src.duplicate()
					if "albedo_color" in mat:
						mat.albedo_color = src.albedo_color.lerp(tint, 0.5)
					if "shading_mode" in mat:
						mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
					child.set_surface_override_material(si, mat)
				else:
					var mat2 := StandardMaterial3D.new()
					mat2.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
					mat2.albedo_color = tint
					child.set_surface_override_material(si, mat2)
		_tint_recursive(child, tint)

func _process(delta: float) -> void:
	if not _error.is_empty():
		return
	if _playing:
		_time = minf(_time + delta * _speed, _duration)
		_update_frame_for_time()
		if _time >= _duration:
			_playing = false
			_update_play_button()
	_update_smoothing(delta)
	_update_time_ui()

func _update_smoothing(delta: float) -> void:
	var t := clampf(delta * 12.0, 0.0, 1.0)
	for slot in _entity_nodes.values():
		var node: Node3D = slot.get("node")
		if not is_instance_valid(node):
			continue
		node.position = node.position.lerp(slot.get("target", node.position), t)
		node.rotation.y = lerp_angle(node.rotation.y, float(slot.get("target_rot", node.rotation.y)), t)

func _update_time_ui() -> void:
	if _slider == null or _time_label == null:
		return
	_ui_updating = true
	_slider.set_value_no_signal(_time)
	_ui_updating = false
	_time_label.text = "%s / %s" % [
		ReplayStoreScript.format_duration(_time),
		ReplayStoreScript.format_duration(_duration),
	]

func _on_back() -> void:
	ReplayStoreScript.pending_path = ""
	get_tree().change_scene_to_file("res://scenes/replay_menu.tscn")

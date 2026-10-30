extends Node3D

const ReplayStoreScript = preload("res://scripts/replay/ReplayStore.gd")
const GroundScript = preload("res://scripts/map/Ground.gd")
const CameraScript = preload("res://scripts/map/CameraController.gd")
const WallTierVisual = preload("res://scripts/effects/WallTierVisual.gd")

var _path: String = ""
var _header: Dictionary = {}
var _frames: Array = []
var _format: int = 1
var _stats_samples: Array = []
var _duration: float = 0.0
var _time: float = 0.0
var _speed: float = 1.0
var _playing: bool = true
var _last_frame_idx: int = -1
var _snap_next: bool = false
var _error: String = ""
var _panel_timer: float = 0.0
var _selected_id: int = 0

var _entities_root: Node3D = null
var _entity_nodes: Dictionary = {}
var _static_defs: Dictionary = {}
var _camera: Camera3D = null
var _selection_ring: MeshInstance3D = null

var _play_btn: Button = null
var _slider: HSlider = null
var _time_label: Label = null
var _title_label: Label = null
var _speed_opt: OptionButton = null
var _stats_label: RichTextLabel = null
var _stats_panel: PanelContainer = null
var _info_panel: PanelContainer = null
var _info_name: Label = null
var _info_body: RichTextLabel = null
var _info_hp_bg: ColorRect = null
var _info_hp_fill: ColorRect = null
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
	_format = int(_header.get("version", 1))
	_stats_samples = _header.get("stats", [])
	if not (_stats_samples is Array):
		_stats_samples = []
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

	_selection_ring = MeshInstance3D.new()
	var ring_mesh := CylinderMesh.new()
	ring_mesh.top_radius = 1.5
	ring_mesh.bottom_radius = 1.5
	ring_mesh.height = 0.08
	ring_mesh.radial_segments = 32
	_selection_ring.mesh = ring_mesh
	var ring_mat := StandardMaterial3D.new()
	ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring_mat.albedo_color = Color(0.45, 1.0, 0.55, 0.9)
	ring_mat.emission_enabled = true
	ring_mat.emission = Color(0.25, 0.8, 0.35)
	_selection_ring.material_override = ring_mat
	_selection_ring.visible = false
	add_child(_selection_ring)

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
	_build_panels(root)
	_update_time_ui()

func _build_panels(parent: Control) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.035, 0.04, 0.055, 0.88)
	style.border_color = Color(0.55, 0.45, 0.25, 0.75)
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)

	_stats_panel = PanelContainer.new()
	_stats_panel.add_theme_stylebox_override("panel", style)
	_stats_panel.anchor_left = 0.0
	_stats_panel.anchor_top = 0.0
	_stats_panel.anchor_right = 0.0
	_stats_panel.anchor_bottom = 0.0
	_stats_panel.offset_left = 12.0
	_stats_panel.offset_top = 64.0
	_stats_panel.offset_right = 442.0
	_stats_panel.offset_bottom = 330.0
	_stats_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	parent.add_child(_stats_panel)
	var stats_box := VBoxContainer.new()
	stats_box.add_theme_constant_override("separation", 4)
	_stats_panel.add_child(stats_box)
	var stats_title := Label.new()
	stats_title.text = "📊 对局统计"
	stats_title.add_theme_font_size_override("font_size", 17)
	stats_title.add_theme_color_override("font_color", Color(0.95, 0.82, 0.55))
	stats_box.add_child(stats_title)
	_stats_label = RichTextLabel.new()
	_stats_label.bbcode_enabled = true
	_stats_label.fit_content = true
	_stats_label.scroll_active = false
	_stats_label.add_theme_font_size_override("normal_font_size", 13)
	_stats_label.add_theme_color_override("default_color", Color(0.88, 0.88, 0.82))
	stats_box.add_child(_stats_label)

	_info_panel = PanelContainer.new()
	_info_panel.add_theme_stylebox_override("panel", style)
	_info_panel.anchor_left = 1.0
	_info_panel.anchor_top = 0.0
	_info_panel.anchor_right = 1.0
	_info_panel.anchor_bottom = 0.0
	_info_panel.offset_left = -342.0
	_info_panel.offset_top = 64.0
	_info_panel.offset_right = -12.0
	_info_panel.offset_bottom = 420.0
	_info_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_info_panel.visible = false
	parent.add_child(_info_panel)
	var info_box := VBoxContainer.new()
	info_box.add_theme_constant_override("separation", 6)
	_info_panel.add_child(info_box)
	var info_head := HBoxContainer.new()
	info_box.add_child(info_head)
	_info_name = Label.new()
	_info_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_info_name.add_theme_font_size_override("font_size", 18)
	_info_name.add_theme_color_override("font_color", Color(0.96, 0.88, 0.68))
	info_head.add_child(_info_name)
	var close := Button.new()
	close.text = "✕"
	close.custom_minimum_size = Vector2(36, 30)
	close.pressed.connect(func(): _select_entity(0))
	info_head.add_child(close)
	_info_hp_bg = ColorRect.new()
	_info_hp_bg.color = Color(0.05, 0.05, 0.06, 0.9)
	_info_hp_bg.custom_minimum_size = Vector2(0, 12)
	info_box.add_child(_info_hp_bg)
	_info_hp_fill = ColorRect.new()
	_info_hp_fill.color = Color(0.35, 0.9, 0.45)
	_info_hp_fill.anchor_bottom = 1.0
	_info_hp_fill.anchor_right = 1.0
	_info_hp_fill.offset_right = 0.0
	_info_hp_bg.add_child(_info_hp_fill)
	_info_body = RichTextLabel.new()
	_info_body.bbcode_enabled = true
	_info_body.fit_content = true
	_info_body.scroll_active = false
	_info_body.add_theme_font_size_override("normal_font_size", 14)
	_info_body.add_theme_color_override("default_color", Color(0.86, 0.87, 0.84))
	info_box.add_child(_info_body)

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
	_panel_timer -= delta
	if _panel_timer <= 0.0:
		_panel_timer = 0.2
		_update_stats_panel()
		if _selected_id != 0:
			_update_info_panel()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch and event.pressed:
		_select_at(event.position)
		return
	if not (event is InputEventMouseButton) or not event.pressed:
		return
	if event.button_index != MOUSE_BUTTON_LEFT:
		return
	_select_at(event.position)

func _select_at(screen_pos: Vector2) -> void:
	if _camera == null:
		return
	var best_id := 0
	var best_dist := 30.0
	for id in _entity_nodes:
		var slot: Dictionary = _entity_nodes[id]
		var node: Node3D = slot.get("node")
		if not is_instance_valid(node):
			continue
		var world_pos: Vector3 = node.global_position + Vector3(0.0, 1.2, 0.0)
		if _camera.is_position_behind(world_pos):
			continue
		var sp := _camera.unproject_position(world_pos)
		var d := sp.distance_to(screen_pos)
		if d < best_dist:
			best_dist = d
			best_id = int(id)
	_select_entity(best_id)

func _select_entity(id: int) -> void:
	_selected_id = id
	if _selection_ring == null:
		return
	if id == 0 or not _entity_nodes.has(id):
		_selection_ring.visible = false
		if _info_panel:
			_info_panel.visible = false
		return
	var slot: Dictionary = _entity_nodes[id]
	var node: Node3D = slot.get("node")
	if not is_instance_valid(node):
		return
	_selection_ring.visible = true
	_selection_ring.global_position = node.global_position + Vector3(0.0, 0.08, 0.0)
	_info_panel.visible = true
	_update_info_panel()

func _update_stats_panel() -> void:
	if _stats_label == null:
		return
	if _stats_samples.is_empty():
		_stats_label.text = "本局没有记录统计信息"
		return
	var sample: Dictionary = _stats_samples[0]
	for s in _stats_samples:
		if float(s.get("time", 0.0)) <= _time + 0.05:
			sample = s
		else:
			break
	var owners: Dictionary = sample.get("owners", {})
	var keys := owners.keys()
	keys.sort_custom(func(a, b): return int(owners[a].get("team", -1)) < int(owners[b].get("team", -1)))
	var lines: Array = []
	for key in keys:
		var o: Dictionary = owners[key]
		var team := int(o.get("team", -1))
		if team == RTSConfig.Team.NEUTRAL:
			continue
		var color: Color = RTSConfig.TEAM_BASE_COLORS.get(team, Color(0.75, 0.75, 0.75))
		var label := _owner_label(o)
		lines.append("[color=#%s]■[/color] %s" % [color.to_html(false), label])
		lines.append("  资源 %d  军队 %d  建筑 %d" % [
			int(o.get("resources", 0)), int(o.get("army", 0)), int(o.get("buildings", 0))])
		lines.append("  采 %.0f  产 %.0f  歼 %.0f  伤 %.0f" % [
			float(o.get("gathered", 0.0)), float(o.get("produced", 0.0)),
			float(o.get("kills", 0.0)), float(o.get("damage", 0.0))])
	if lines.is_empty():
		lines.append("暂无统计")
	_stats_label.text = "\n".join(lines)

func _owner_label(o: Dictionary) -> String:
	var nation := int(o.get("nation", -1))
	var names := ["维京", "英格兰", "法兰西", "中国", "匈牙利", "日本", "拜占庭", "蒙古", "波斯", "西班牙"]
	var nn: String = String(names[nation]) if nation >= 0 and nation < names.size() else "未知"
	var owner := int(o.get("owner", -1))
	if owner < 0:
		return "%s（%s）" % ["玩家" if nation == int(GameSettings.player_nation) else "对手", nn]
	return "%s%d（%s）" % ["玩家", owner, nn]

func _update_info_panel() -> void:
	if _info_panel == null or _info_body == null:
		return
	if not _entity_nodes.has(_selected_id):
		_info_panel.visible = false
		return
	var slot: Dictionary = _entity_nodes[_selected_id]
	var d: Dictionary = slot.get("data", {})
	if d.is_empty():
		return
	var eid := int(d.get("e", 0))
	var cfg: Dictionary = EntityDatabase.get_config(eid) if eid >= 0 else {}
	var name := String(cfg.get("name", "实体 #%d" % eid))
	_info_name.text = name
	var team := int(d.get("tm", -1))
	var team_color: Color = RTSConfig.TEAM_BASE_COLORS.get(team, Color(0.75, 0.75, 0.75))
	var team_text := "中立" if team == RTSConfig.Team.NEUTRAL else ("蓝队" if team == RTSConfig.Team.BLUE else "红队")
	if team == RTSConfig.Team.NEUTRAL:
		team_color = Color(0.7, 0.7, 0.7)
	var hp := float(d.get("h", 0.0))
	var max_hp := maxf(float(d.get("mh", 0.0)), 1.0)
	var ratio := clampf(hp / max_hp, 0.0, 1.0)
	_info_hp_fill.anchor_right = ratio
	_info_hp_fill.color = team_color
	var type_names := ["资源", "建筑", "军队"]
	var ty := int(d.get("ty", -1))
	var type_text: String = String(type_names[ty]) if ty >= 0 and ty < type_names.size() else "实体"
	var lines: Array = []
	lines.append("[color=#%s]■[/color] %s  ·  %s" % [team_color.to_html(false), team_text, type_text])
	lines.append("生命：%.0f / %.0f" % [hp, max_hp])
	lines.append("等级：%d" % int(d.get("lv", 1)))
	if cfg.has("attack"):
		lines.append("攻击：%d  ·  攻速：%.1f  ·  射程：%.1f" % [
			int(cfg.get("attack", 0)), float(cfg.get("attack_speed", 1.0)), float(cfg.get("attack_range", 0.0))])
	if cfg.has("melee_armor"):
		lines.append("近防：%d  ·  盾防：%d  ·  速度：%.1f" % [
			int(cfg.get("melee_armor", 0)), int(cfg.get("shield_armor", 0)), float(cfg.get("speed", 0.0))])
	if float(d.get("bt", 0.0)) > 0.0:
		lines.append("建造剩余：%.1f 秒" % float(d.get("bt", 0.0)))
	lines.append("坐标：%.1f, %.1f" % [float(d.get("p", [0, 0, 0])[0]), float(d.get("p", [0, 0, 0])[2])])
	_info_body.text = "\n".join(lines)

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
	if _format >= 2:
		if _snap_next or _last_frame_idx < 0 or idx < _last_frame_idx:
			_rebuild_v2(idx)
		else:
			for i in range(_last_frame_idx + 1, idx + 1):
				_apply_v2_frame(_frames[i], false)
		_last_frame_idx = idx
		_snap_next = false
		return
	_last_frame_idx = idx
	_apply_frame(_frames[idx], _snap_next)
	_snap_next = false

func _rebuild_v2(target_idx: int) -> void:
	_clear_entities()
	var key_idx := target_idx
	while key_idx > 0 and not bool(_frames[key_idx].get("k", false)):
		key_idx -= 1
	for i in range(key_idx, target_idx + 1):
		_apply_v2_frame(_frames[i], true)

func _clear_entities() -> void:
	for id in _entity_nodes.keys():
		var slot: Dictionary = _entity_nodes[id]
		var node: Node3D = slot.get("node")
		if is_instance_valid(node):
			node.queue_free()
	_entity_nodes.clear()
	_static_defs.clear()

func _apply_v2_frame(frame: Dictionary, snap: bool) -> void:
	var keyframe := bool(frame.get("k", false))
	var seen: Dictionary = {}
	for d in frame.get("e", []):
		if not (d is Dictionary):
			continue
		var id := int(d.get("i", 0))
		if id == 0:
			continue
		seen[id] = true
		_apply_entity(d, snap)
	if keyframe:
		_remove_absent(seen)
	else:
		for id in frame.get("r", []):
			_remove_entity(int(id))

func _apply_frame(frame: Dictionary, snap: bool) -> void:
	var seen: Dictionary = {}
	for d in frame.get("e", []):
		if not (d is Dictionary):
			continue
		var id := int(d.get("i", 0))
		if id == 0:
			continue
		seen[id] = true
		_apply_entity(d, snap)
	_remove_absent(seen)

func _apply_entity(d: Dictionary, snap: bool) -> void:
	var id := int(d.get("i", 0))
	if d.get("d") is Dictionary:
		_static_defs[id] = d["d"]
	var merged: Dictionary = d
	if not d.has("e"):
		var base: Dictionary = _static_defs.get(id, {})
		merged = base.duplicate()
		merged["i"] = id
		merged["p"] = d.get("p", [0, 0, 0])
		merged["r"] = d.get("r", 0.0)
		if d.has("h"):
			merged["h"] = d["h"]
		if d.has("bt"):
			merged["bt"] = d["bt"]
	else:
		_static_defs[id] = _static_of(d)
	var slot: Dictionary
	if not _entity_nodes.has(id):
		slot = _create_entity(merged)
		_entity_nodes[id] = slot
	else:
		slot = _entity_nodes[id]
		var node: Node3D = slot["node"]
		if not is_instance_valid(node):
			_entity_nodes.erase(id)
			slot = _create_entity(merged)
			_entity_nodes[id] = slot
	slot["data"] = merged
	var p: Array = merged.get("p", [0, 0, 0])
	slot["target"] = Vector3(float(p[0]), float(p[1]), float(p[2]))
	slot["target_rot"] = float(merged.get("r", 0.0))
	var eid := int(merged.get("e", 0))
	var mp := String(merged.get("mp", ""))
	var old_mp := String(slot.get("model_path", ""))
	if mp != "" and mp != old_mp:
		var old_model: Node3D = slot.get("model")
		if is_instance_valid(old_model):
			old_model.queue_free()
		slot["model"] = _make_model(slot["node"], merged)
		slot["model_path"] = mp
	var model: Node3D = slot.get("model")
	if is_instance_valid(model):
		_apply_model_transform(model, merged)
	if eid == 27:
		var col: Array = merged.get("col", [0.7, 0.7, 0.7])
		var color := Color(float(col[0]), float(col[1]), float(col[2]))
		var ruin := bool(merged.get("ruin", false))
		WallTierVisual.apply(slot["node"], 2 if ruin else int(merged.get("lv", 1)), color)
	if snap:
		var node2: Node3D = slot["node"]
		node2.position = slot["target"]
		node2.rotation.y = slot["target_rot"]

func _remove_absent(seen: Dictionary) -> void:
	for id in _entity_nodes.keys():
		if seen.has(id):
			continue
		_remove_entity(int(id))

func _remove_entity(id: int) -> void:
	if not _entity_nodes.has(id):
		return
	var old: Dictionary = _entity_nodes[id]
	var old_node: Node3D = old["node"]
	if is_instance_valid(old_node):
		old_node.queue_free()
	_entity_nodes.erase(id)

func _static_of(d: Dictionary) -> Dictionary:
	var out := {}
	for key in ["e", "mp", "mo", "mr", "ms", "col", "lv", "c", "ruin"]:
		if d.has(key):
			out[key] = d[key]
	return out

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

func _update_smoothing(delta: float) -> void:
	var t := clampf(delta * 12.0, 0.0, 1.0)
	for slot in _entity_nodes.values():
		var node: Node3D = slot.get("node")
		if not is_instance_valid(node):
			continue
		node.position = node.position.lerp(slot.get("target", node.position), t)
		node.rotation.y = lerp_angle(node.rotation.y, float(slot.get("target_rot", node.rotation.y)), t)
	if _selected_id != 0:
		if not _entity_nodes.has(_selected_id):
			_select_entity(0)
		elif _selection_ring:
			var node: Node3D = _entity_nodes[_selected_id].get("node")
			if is_instance_valid(node):
				_selection_ring.global_position = node.global_position + Vector3(0.0, 0.08, 0.0)

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

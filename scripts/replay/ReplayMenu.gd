extends Control

const ReplayStoreScript = preload("res://scripts/replay/ReplayStore.gd")
const CommandReplayScript = preload("res://scripts/replay/CommandReplay.gd")
const MapPresetsScript = preload("res://scripts/map/MapPresets.gd")

var _list_box: VBoxContainer = null
var _empty_label: Label = null

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.09, 0.08, 0.07)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 36)
	margin.add_theme_constant_override("margin_right", 36)
	margin.add_theme_constant_override("margin_top", 22)
	margin.add_theme_constant_override("margin_bottom", 22)
	add_child(margin)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	margin.add_child(vb)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 14)
	vb.add_child(header)

	var back := Button.new()
	back.text = "← 返回主菜单"
	back.custom_minimum_size = Vector2(170, 40)
	back.pressed.connect(_on_back)
	header.add_child(back)

	var title := Label.new()
	title.text = "🎬 对局录像"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color(0.94, 0.84, 0.55))
	header.add_child(title)

	var refresh := Button.new()
	refresh.text = "刷新"
	refresh.custom_minimum_size = Vector2(90, 40)
	refresh.pressed.connect(_populate)
	header.add_child(refresh)

	var hint := Label.new()
	hint.text = "完成单机对局或联机主机对局后会自动保存录像；点击条目即可回放。"
	hint.add_theme_font_size_override("font_size", 15)
	hint.add_theme_color_override("font_color", Color(0.78, 0.72, 0.6))
	vb.add_child(hint)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(scroll)

	_list_box = VBoxContainer.new()
	_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_box.add_theme_constant_override("separation", 8)
	scroll.add_child(_list_box)

	_empty_label = Label.new()
	_empty_label.text = "还没有录像文件。"
	_empty_label.add_theme_font_size_override("font_size", 18)
	_empty_label.add_theme_color_override("font_color", Color(0.7, 0.65, 0.58))
	vb.add_child(_empty_label)

	_populate()

func _populate() -> void:
	if _list_box == null:
		return
	for child in _list_box.get_children():
		child.queue_free()
	var replays := ReplayStoreScript.list_replays()
	for cmd_item in _list_command_replays():
		replays.append(cmd_item)
	replays.sort_custom(func(a, b): return int(a.get("mtime", 0)) > int(b.get("mtime", 0)))
	_empty_label.visible = replays.is_empty()
	for item in replays:
		_list_box.add_child(_make_row(item))

func _list_command_replays() -> Array:
	var out: Array = []
	var dir := DirAccess.open(ReplayStoreScript.DEFAULT_DIR)
	if dir == null:
		return out
	for file in dir.get_files():
		if not file.ends_with(".cmdr"):
			continue
		var path: String = ReplayStoreScript.DEFAULT_DIR.path_join(file)
		var raw := CommandReplayScript.load_file(path)
		if raw.is_empty():
			continue
		var header: Dictionary = raw.get("header", {})
		var mtime := FileAccess.get_modified_time(path)
		var fsize := 0
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null:
			fsize = f.get_length()
			f.close()
		out.append({
			"path": path,
			"file": file,
			"mtime": mtime,
			"date": ReplayStoreScript.format_datetime(mtime),
			"mode": "command",
			"map_name": String(MapPresetsScript.get_info(String(header.get("map_id", "classic")))["name"]),
			"duration": float(header.get("duration", 0.0)),
			"size": fsize,
			"header": header,
		})
	return out

func _make_row(item: Dictionary) -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(0, 62)
	panel.add_theme_stylebox_override("panel", _row_style())

	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 12)
	panel.add_child(hb)

	var label := Label.new()
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var mode := "指令" if String(item.get("mode", "")) == "command" else ("联机" if String(item.get("mode", "")) == "online" else "单机")
	label.text = "%s  ·  %s  ·  %s  ·  %s  ·  %s" % [
		String(item.get("date", "")), mode, String(item.get("map_name", "未知地图")),
		ReplayStoreScript.format_duration(float(item.get("duration", 0.0))),
		ReplayStoreScript.format_size(int(item.get("size", 0))),
	]
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", Color(0.92, 0.88, 0.78))
	hb.add_child(label)

	var play := Button.new()
	play.text = "▶ 播放"
	play.custom_minimum_size = Vector2(100, 42)
	play.pressed.connect(_on_play.bind(String(item.get("path", ""))))
	hb.add_child(play)

	var del := Button.new()
	del.text = "删除"
	del.custom_minimum_size = Vector2(76, 42)
	del.add_theme_color_override("font_color", Color(0.9, 0.55, 0.48))
	del.pressed.connect(_on_delete.bind(String(item.get("path", ""))))
	hb.add_child(del)
	return panel

func _row_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.16, 0.13, 0.10, 0.95)
	style.border_color = Color(0.45, 0.36, 0.22, 0.8)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	return style

func _on_play(path: String) -> void:
	if path == "" or not FileAccess.file_exists(path):
		_populate()
		return
	if path.ends_with(".cmdr"):
		_play_command(path)
		return
	ReplayStoreScript.pending_path = path
	get_tree().change_scene_to_file("res://scenes/replay_player.tscn")

func _play_command(path: String) -> void:
	var raw := CommandReplayScript.load_file(path)
	if raw.is_empty():
		_populate()
		return
	var h: Dictionary = raw.get("header", {})
	GameSettings.replay_mode = "command"
	GameSettings.command_replay = true
	GameSettings.command_replay_file = path
	GameSettings.deterministic_sim = true
	GameSettings.sim_seed = int(h.get("sim_seed", 0))
	GameSettings.map_seed = int(h.get("map_seed", 0))
	GameSettings.map_id = String(h.get("map_id", "classic"))
	GameSettings.player_nation = int(h.get("player_nation", 0))
	GameSettings.enemy_nation = int(h.get("enemy_nation", 1))
	GameSettings.ai_mode = int(h.get("ai_mode", 1))
	GameSettings.ai_difficulty = int(h.get("ai_difficulty", 0))
	GameSettings.blue_ai_difficulty = int(h.get("blue_ai_difficulty", 0))
	GameSettings.red_ai_difficulty = int(h.get("red_ai_difficulty", 0))
	GameSettings.is_ffa = bool(h.get("is_ffa", false))
	GameSettings.ffa_nation_count = int(h.get("ffa_nation_count", 3))
	GameSettings.is_single_2v2 = bool(h.get("is_single_2v2", false))
	GameSettings.progression_mode = int(h.get("progression_mode", 0))
	GameSettings.fast_mode = bool(h.get("fast_mode", false))
	GameSettings.campaign_mode = false
	GameSettings.tutorial_mode = false
	GameSettings.training_mode = false
	get_tree().change_scene_to_file("res://scenes/rts_battle.tscn")

func _on_delete(path: String) -> void:
	if path == "":
		return
	if path.ends_with(".cmdr"):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	else:
		ReplayStoreScript.delete_file(path)
	_populate()

func _on_back() -> void:
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")

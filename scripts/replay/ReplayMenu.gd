extends Control

const ReplayStoreScript = preload("res://scripts/replay/ReplayStore.gd")

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
	_empty_label.visible = replays.is_empty()
	for item in replays:
		_list_box.add_child(_make_row(item))

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
	var mode := "联机" if String(item.get("mode", "")) == "online" else "单机"
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
	ReplayStoreScript.pending_path = path
	get_tree().change_scene_to_file("res://scenes/replay_player.tscn")

func _on_delete(path: String) -> void:
	if path == "":
		return
	ReplayStoreScript.delete_file(path)
	_populate()

func _on_back() -> void:
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")

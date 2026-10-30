extends Control

# 指令回放顶部提示条：显示进度，并提供返回回放列表的入口。
# 根节点不拦截鼠标，单位选择/信息面板/统计面板仍可正常点击。

const CommandPlayerScript = preload("res://scripts/replay/CommandPlayer.gd")

var manager = null
var _label: Label = null
var _pause_btn: Button = null

func setup(battle) -> void:
	manager = battle
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	panel.offset_left = -260
	panel.offset_right = 260
	panel.offset_top = 14
	panel.custom_minimum_size = Vector2(520, 46)
	add_child(panel)

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.09, 0.12, 0.90)
	style.border_color = Color(0.74, 0.62, 0.32, 0.9)
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	panel.add_theme_stylebox_override("panel", style)

	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 10)
	panel.add_child(hb)

	_label = Label.new()
	_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override("font_size", 15)
	_label.add_theme_color_override("font_color", Color(0.95, 0.88, 0.68))
	hb.add_child(_label)

	_pause_btn = Button.new()
	_pause_btn.text = "⏸ 暂停"
	_pause_btn.custom_minimum_size = Vector2(88, 32)
	_pause_btn.pressed.connect(_toggle_pause)
	hb.add_child(_pause_btn)

	var back := Button.new()
	back.text = "← 回放列表"
	back.custom_minimum_size = Vector2(104, 32)
	back.pressed.connect(func():
		GameSettings.command_replay = false
		GameSettings.command_replay_file = ""
		GameSettings.deterministic_sim = false
		GameSettings.replay_mode = "snapshot"
		get_tree().change_scene_to_file("res://scenes/replay_menu.tscn"))
	hb.add_child(back)

func _process(_delta: float) -> void:
	if _label == null or manager == null or not is_instance_valid(manager):
		return
	var tick := int(manager.get_sim_tick())
	var total := 1
	var idx := 0
	if manager.command_player != null:
		total = maxi(1, manager.command_player.commands.size())
		idx = manager.command_player._idx
	_label.text = "🎬 指令回放  ·  %.1fs  ·  命令 %d/%d  ·  点击单位查看信息" % [float(tick) / 60.0, idx, total]

func _toggle_pause() -> void:
	var paused := not get_tree().paused
	get_tree().paused = paused
	_pause_btn.text = "▶ 继续" if paused else "⏸ 暂停"

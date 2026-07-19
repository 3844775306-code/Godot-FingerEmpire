extends Control

var nation_select: OptionButton

func _ready():
	AudioManager.play_music("menu")
	# 隐藏旧的场景节点，全部用代码重建
	var old_box = get_node_or_null("VBoxContainer")
	if old_box: old_box.visible = false

	# 全屏暗色背景
	var bg = ColorRect.new()
	bg.color = Color(0.06, 0.06, 0.1)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	move_child(bg, 0)

	# 装饰性顶部横条
	var top_bar = ColorRect.new()
	top_bar.color = Color(0.2, 0.45, 0.8, 0.3)
	top_bar.position = Vector2(0, 0)
	top_bar.size = Vector2(2400, 4)
	add_child(top_bar)

	# 中央内容垂直居中容器
	var center_y = 350  # 整体上移

	# 标题
	var title = Label.new()
	title.text = "FINGER EMPIRE"
	title.position = Vector2(0, center_y - 300)
	title.size = Vector2(2400, 80)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 96)
	title.add_theme_color_override("font_color", Color(0.9, 0.75, 0.1))
	title.add_theme_color_override("font_shadow_color", Color.BLACK)
	title.add_theme_constant_override("shadow_offset_x", 3)
	title.add_theme_constant_override("shadow_offset_y", 3)
	title.add_theme_constant_override("shadow_size", 8)
	add_child(title)

	# 副标题
	var subtitle = Label.new()
	subtitle.text = "即时战略"
	subtitle.position = Vector2(0, center_y - 200)
	subtitle.size = Vector2(2400, 40)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 40)
	subtitle.add_theme_color_override("font_color", Color(0.5, 0.6, 0.7))
	add_child(subtitle)

	# 国家选择区
	var nation_label = Label.new()
	nation_label.text = "选择国家"
	nation_label.position = Vector2(700, center_y - 100)
	nation_label.size = Vector2(1000, 36)
	nation_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	nation_label.add_theme_font_size_override("font_size", 26)
	nation_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	add_child(nation_label)

	nation_select = OptionButton.new()
	nation_select.add_item("  维京    +25%生命  +10%速度")
	nation_select.add_item("  英格兰  +15%攻击  +20%视野  采木+10%")
	nation_select.add_item("  法兰西  +25护甲  城堡2级起始")
	nation_select.add_item("  中国    食物+20%  黄金+10%  人口+10")
	nation_select.add_item("  匈牙利  +15护甲  石材+15%  黄金+10%  人口+5")
	nation_select.position = Vector2(750, center_y - 55)
	nation_select.size = Vector2(900, 55)
	nation_select.add_theme_font_size_override("font_size", 22)
	add_child(nation_select)

	# 按钮
	var btn_data = [
		["单人游戏", Vector2(850, center_y + 40), _on_play_pressed, Color(0.15, 0.5, 0.2)],
		["联机对战", Vector2(850, center_y + 135), _on_multiplayer_pressed, Color(0.15, 0.3, 0.55)],
		["退出游戏", Vector2(850, center_y + 230), _on_quit_pressed, Color(0.35, 0.15, 0.15)],
	]

	for data in btn_data:
		var btn = _make_menu_button(data[0], data[1], data[3])
		btn.pressed.connect(data[2])
		add_child(btn)

	# 底部装饰面板
	var bot_panel = Panel.new()
	bot_panel.position = Vector2(300, 1050)
	bot_panel.size = Vector2(1800, 250)
	var bot_style = StyleBoxFlat.new()
	bot_style.bg_color = Color(0.08, 0.09, 0.14, 0.7)
	bot_style.corner_radius_top_left = 10; bot_style.corner_radius_top_right = 10
	bot_style.corner_radius_bottom_left = 10; bot_style.corner_radius_bottom_right = 10
	bot_style.border_width_left = 1; bot_style.border_width_right = 1
	bot_style.border_width_top = 1; bot_style.border_width_bottom = 1
	bot_style.border_color = Color(0.25, 0.4, 0.6, 0.3)
	bot_panel.add_theme_stylebox_override("panel", bot_style)
	add_child(bot_panel)

	var tip_label = Label.new()
	tip_label.text = "快捷键: Ctrl+[1-9] 编队  |  [1-9] 选择编队  |  Shift+右键 连续指令  |  H 暂停采集  |  P 原地防守"
	tip_label.position = Vector2(0, 30)
	tip_label.size = Vector2(1600, 30)
	tip_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tip_label.add_theme_font_size_override("font_size", 20)
	tip_label.add_theme_color_override("font_color", Color(0.4, 0.5, 0.6))
	bot_panel.add_child(tip_label)

	var tip2 = Label.new()
	tip2.text = "维京 +25%HP +10%速 | 英格兰 +15%攻 +20%视野 | 法兰西 +25护甲 城堡2级 | 中国 食物+20% 金+10% 人口+10 | 匈牙利 +15护甲 石+15% 金+10%"
	tip2.position = Vector2(0, 80)
	tip2.size = Vector2(1600, 30)
	tip2.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tip2.add_theme_font_size_override("font_size", 18)
	tip2.add_theme_color_override("font_color", Color(0.35, 0.4, 0.5))
	bot_panel.add_child(tip2)

	# 底部版本号
	var version = Label.new()
	version.text = "v1.0 - Godot 4.5"
	version.position = Vector2(0, 1350)
	version.size = Vector2(2400, 30)
	version.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	version.add_theme_font_size_override("font_size", 18)
	version.add_theme_color_override("font_color", Color(0.3, 0.3, 0.4))
	add_child(version)

func _make_menu_button(text: String, pos: Vector2, color: Color) -> Button:
	var btn = Button.new()
	btn.text = text
	btn.position = pos
	btn.size = Vector2(600, 80)

	var style = StyleBoxFlat.new()
	style.bg_color = color
	style.corner_radius_top_left = 8; style.corner_radius_top_right = 8
	style.corner_radius_bottom_left = 8; style.corner_radius_bottom_right = 8
	style.border_width_left = 2; style.border_width_right = 2
	style.border_width_top = 2; style.border_width_bottom = 2
	style.border_color = Color(color.r * 1.4, color.g * 1.4, color.b * 1.4, 0.6)
	style.content_margin_left = 10; style.content_margin_top = 5

	var hover = style.duplicate()
	hover.bg_color = Color(color.r * 1.3, color.g * 1.3, color.b * 1.3)

	btn.add_theme_stylebox_override("normal", style)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_font_size_override("font_size", 30)
	return btn

func _on_play_pressed():
	GameSettings.player_nation = nation_select.selected
	GameSettings.enemy_nation = randi() % 5
	get_tree().change_scene_to_file("res://scenes/rts_battle.tscn")

func _on_multiplayer_pressed():
	get_tree().change_scene_to_file("res://scenes/online_menu.tscn")

func _on_settings_pressed():
	pass

func _on_quit_pressed():
	get_tree().quit()

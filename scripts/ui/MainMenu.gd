extends Control

const MapPresets = preload("res://scripts/map/MapPresets.gd")
const MapSelectDialog = preload("res://scripts/ui/MapSelectDialog.gd")

var nation_select: OptionButton
var _map_button: Button = null
var _last_map_id: String = "classic"
var _map_allowed: bool = true

# 主菜单场景没有战斗内的 TouchGestureRouter：触摸拖动直接驱动 ScrollContainer 滚动
# （手机点击仍由引擎模拟鼠标完成，这里只管滑动）。
func _input(event: InputEvent) -> void:
	if not InputSource.use_mobile_ui():
		return
	if event is InputEventScreenDrag:
		UILayout.scroll_at(self, event.position, event.relative.y)

func _ready():
	AudioManager.play_music("menu")
	# Scale to fit screen (design: 2400x1400)
	var vs = get_viewport().get_visible_rect().size
	var s = min(vs.x / 2400.0, vs.y / 1400.0)
	scale = Vector2(s, s)
	position = (vs - Vector2(2400, 1400) * s) / 2.0
	# 手机端：桌面绝对布局在 674×393dp 的屏幕上字只有 5~7dp，改用竖排滚动布局
	if InputSource.use_mobile_ui():
		# 场景里那套桌面节点必须一起隐藏，否则会和下面的竖排布局重叠，变成"两层 UI"
		var old_box = get_node_or_null("VBoxContainer")
		if old_box: old_box.visible = false
		# 根 Control 默认 size 为 0，anchors 布局会整体塌成 0 高，必须先给设计尺寸
		size = Vector2(2400, 1400)
		_build_mobile_layout()
		return
	# 隐藏旧的场景节点，全部用代码重建
	var old_box = get_node_or_null("VBoxContainer")
	if old_box: old_box.visible = false

	# 全屏暖黑背景（羊皮纸皇庭底色）
	var bg = ColorRect.new()
	bg.color = Color(0.10, 0.08, 0.06)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	move_child(bg, 0)

	# 顶部皇庭金饰横条
	var top_bar = ColorRect.new()
	top_bar.color = Color(UITheme.GOLD)
	top_bar.position = Vector2(0, 0)
	top_bar.size = Vector2(2400, 6)
	add_child(top_bar)
	var top_bar2 = ColorRect.new()
	top_bar2.color = Color(UITheme.GOLD, 0.35)
	top_bar2.position = Vector2(0, 6)
	top_bar2.size = Vector2(2400, 3)
	add_child(top_bar2)

	var center_y = 350  # 整体上移

	# 主标题（皇庭金徽章）
	var title = Label.new()
	title.text = "👑 FINGER EMPIRE 👑"
	title.position = Vector2(0, center_y - 300)
	title.size = Vector2(2400, 90)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 96)
	title.add_theme_color_override("font_color", UITheme.GOLD.lightened(0.15))
	title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	title.add_theme_constant_override("shadow_offset_x", 3)
	title.add_theme_constant_override("shadow_offset_y", 3)
	title.add_theme_constant_override("shadow_size", 10)
	add_child(title)

	# 标题下方金色装饰线
	var gold_line = ColorRect.new()
	gold_line.color = Color(UITheme.GOLD, 0.7)
	gold_line.position = Vector2(860, center_y - 196)
	gold_line.size = Vector2(680, 3)
	add_child(gold_line)

	# 副标题
	var subtitle = Label.new()
	subtitle.text = "即时战略 · 帝国纷争"
	subtitle.position = Vector2(0, center_y - 185)
	subtitle.size = Vector2(2400, 40)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(subtitle, 34, UITheme.PARCHMENT)
	add_child(subtitle)

	# 中央皇庭面板
	var panel = Panel.new()
	panel.position = Vector2(620, 205)
	panel.size = Vector2(1160, 725)
	panel.add_theme_stylebox_override("panel", UITheme.card_style(UITheme.GOLD))
	add_child(panel)

	# 面板内分区标题
	var section = UITheme.make_section_title("⚔️ 战役配置 ⚔️", UITheme.GOLD, 28)
	section.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	section.position = Vector2(620, 218)
	section.size = Vector2(1160, 36)
	add_child(section)

	# 国家选择区
	var nation_label = Label.new()
	nation_label.text = "选择国家"
	nation_label.position = Vector2(620, 262)
	nation_label.size = Vector2(1160, 30)
	nation_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(nation_label, 24, UITheme.PARCHMENT)
	add_child(nation_label)

	nation_select = OptionButton.new()
	nation_select.add_item("  维京    +25%生命  +10%速度")
	nation_select.add_item("  英格兰  +15%攻击  +20%视野  采木+10%")
	nation_select.add_item("  法兰西  +25护甲  城堡2级起始")
	nation_select.add_item("  中国    食物+20%  黄金+10%  人口+10")
	nation_select.add_item("  匈牙利  +15护甲  石材+15%  黄金+10%  人口+5")
	nation_select.add_item("  日本    +15%攻速  +10%攻击")
	nation_select.add_item("  拜占庭  +2双护甲  黄金+10%")
	nation_select.position = Vector2(750, 296)
	nation_select.size = Vector2(900, 50)
	_style_option(nation_select, 20)
	add_child(nation_select)

	# AI难度选择
	var diff_label = Label.new()
	diff_label.text = "AI难度"
	diff_label.position = Vector2(700, 366)
	diff_label.size = Vector2(200, 30)
	diff_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	UITheme.apply_label(diff_label, 20, UITheme.PARCHMENT)
	add_child(diff_label)
	var diff_select = OptionButton.new()
	diff_select.name = "DiffSelect"
	diff_select.add_item("  简单")
	diff_select.add_item("  普通（AI资源×2）")
	diff_select.add_item("  困难（AI资源×3+额外资源）")
	diff_select.add_item("  地狱（困难+速度+20%）")
	diff_select.position = Vector2(910, 364)
	diff_select.size = Vector2(740, 46)
	_style_option(diff_select, 16)
	add_child(diff_select)

	# 游戏模式选择（1V1 / 2V2 / 3V3 对称团队战 / 乱斗3-5国）
	var mode_label = Label.new()
	mode_label.text = "游戏模式"
	mode_label.position = Vector2(700, 428)
	mode_label.size = Vector2(200, 30)
	mode_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	UITheme.apply_label(mode_label, 20, UITheme.PARCHMENT)
	add_child(mode_label)
	var mode_select = OptionButton.new()
	mode_select.name = "ModeSelect"
	mode_select.add_item("  1V1")
	mode_select.add_item("  2V2")
	mode_select.add_item("  3V3")
	mode_select.add_item("  乱斗·3国")
	mode_select.add_item("  乱斗·4国")
	mode_select.add_item("  乱斗·5国")
	mode_select.selected = 0   # 默认 1V1
	mode_select.position = Vector2(910, 426)
	mode_select.size = Vector2(740, 46)
	_style_option(mode_select, 16)
	add_child(mode_select)

	# 战场地形：按钮打开卡片选择器（试点：特殊地图仅 1V1 可选）
	var map_label = Label.new()
	map_label.text = "战场地形"
	map_label.position = Vector2(700, 488)
	map_label.size = Vector2(200, 30)
	map_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	UITheme.apply_label(map_label, 20, UITheme.PARCHMENT)
	add_child(map_label)

	var map_btn = Button.new()
	map_btn.name = "MapButton"
	map_btn.position = Vector2(910, 486)
	map_btn.size = Vector2(420, 40)
	UITheme.apply_muted_button(map_btn, 16)
	map_btn.pressed.connect(_open_map_dialog)
	add_child(map_btn)
	_map_button = map_btn
	_refresh_map_button()
	mode_select.item_selected.connect(_update_map_availability)
	_update_map_availability(mode_select.selected)

	# 快速模式
	var fast_check = CheckBox.new()
	fast_check.name = "FastCheck"
	fast_check.text = "快速模式（采集×3）"
	fast_check.position = Vector2(1360, 492)
	fast_check.add_theme_font_size_override("font_size", 18)
	fast_check.add_theme_color_override("font_color", UITheme.PARCHMENT)
	fast_check.add_theme_color_override("font_hover_color", UITheme.GOLD)
	fast_check.add_theme_color_override("icon_normal_color", UITheme.GOLD)
	fast_check.add_theme_color_override("icon_hover_color", UITheme.GOLD.lightened(0.2))
	add_child(fast_check)

	# 按钮（金主 CTA / 蓝书图鉴 / 石次 / 朱红危险）
	var btn_data = [
		["单人游戏", Vector2(900, center_y + 216), _on_play_pressed, "primary"],
		["联机对战", Vector2(900, center_y + 290), _on_multiplayer_pressed, "primary"],
		["📖 单位图鉴", Vector2(900, center_y + 364), _on_units_pressed, "book"],
		["设  置", Vector2(900, center_y + 438), _on_settings_pressed, "muted"],
		["退出游戏", Vector2(900, center_y + 512), _on_quit_pressed, "danger"],
	]

	for data in btn_data:
		var btn = _make_menu_button(data[0], data[1], data[3])
		btn.pressed.connect(data[2])
		add_child(btn)
		if data[3] == "primary" and data[0] == "单人游戏":
			UITheme.pulse(btn, 1.03, 0.9)   # 主 CTA 呼吸高亮
		else:
			UITheme.hover_scale(btn)

	# 中央面板淡入
	UITheme.fade_in(panel, 0.4)

	# 底部提示面板
	var bot_panel = Panel.new()
	bot_panel.position = Vector2(300, 1020)
	bot_panel.size = Vector2(1800, 250)
	bot_panel.add_theme_stylebox_override("panel", UITheme.card_style(UITheme.GOLD))
	add_child(bot_panel)
	UITheme.fade_in(bot_panel, 0.5)

	var tip_label = Label.new()
	tip_label.text = "快捷键: Ctrl+[1-9] 编队  |  [1-9] 选择编队  |  Shift+右键 连续指令  |  H 暂停采集  |  P 原地防守  |  L 隐藏单位血条文字"
	tip_label.position = Vector2(0, 30)
	tip_label.size = Vector2(1800, 30)
	tip_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(tip_label, 20, UITheme.PARCHMENT)
	bot_panel.add_child(tip_label)

	var tip2 = Label.new()
	tip2.text = "维京 +25%HP +10%速 | 英格兰 +15%攻 +20%视野 | 法兰西 +25护甲 城堡2级 | 中国 食物+20% 金+10% 人口+10 | 匈牙利 +15护甲 石+15% 金+10% | 日本 +15%攻速 +10%攻 | 拜占庭 +2护甲 金+10%"
	tip2.position = Vector2(0, 80)
	tip2.size = Vector2(1800, 30)
	tip2.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(tip2, 18, Color(UITheme.STONE).lightened(0.3))
	bot_panel.add_child(tip2)

	# 底部版本号
	var version = Label.new()
	version.text = "v1.0 - Godot 4.7"
	version.position = Vector2(0, 1340)
	version.size = Vector2(2400, 30)
	version.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(version, 18, Color(UITheme.STONE).lightened(0.2))
	add_child(version)
	UITheme.fade_in(version, 0.6)

## 主题化 OptionButton（含弹出列表）
func _style_option(o: OptionButton, font_size: int) -> void:
	o.add_theme_font_size_override("font_size", font_size)
	o.add_theme_color_override("font_color", UITheme.PARCHMENT)
	o.add_theme_color_override("font_hover_color", UITheme.GOLD)
	var pop = o.get_popup()
	pop.add_theme_font_size_override("font_size", font_size)
	pop.add_theme_color_override("font_color", UITheme.PARCHMENT)
	pop.add_theme_color_override("font_hover_color", UITheme.GOLD)

## 菜单按钮（金主 / 蓝书图鉴 / 石次 / 朱红危险）
func _make_menu_button(text: String, pos: Vector2, kind: String) -> Button:
	var btn = Button.new()
	btn.text = text
	btn.position = pos
	btn.size = Vector2(600, 62)
	match kind:
		"primary": UITheme.apply_primary_button(btn, UITheme.FONT_XXL)
		"danger": UITheme.apply_danger_button(btn, UITheme.FONT_XXL)
		"book":
			# 图鉴专用「宝石蓝」书页风格，与金色 CTA 区分
			var sb = StyleBoxFlat.new()
			sb.bg_color = Color(UITheme.SAPPHIRE, 0.16)
			sb.border_color = Color(UITheme.SAPPHIRE, 0.95)
			sb.set_corner_radius_all(10)
			sb.set_border_width_all(2)
			sb.set_content_margin_all(6)
			btn.add_theme_stylebox_override("normal", sb)
			var hover = sb.duplicate()
			hover.bg_color = Color(UITheme.SAPPHIRE, 0.30)
			btn.add_theme_stylebox_override("hover", hover)
			var pressed = hover.duplicate()
			pressed.bg_color = Color(UITheme.SAPPHIRE, 0.44)
			btn.add_theme_stylebox_override("pressed", pressed)
			var focus = StyleBoxEmpty.new()
			btn.add_theme_stylebox_override("focus", focus)
			btn.add_theme_font_size_override("font_size", UITheme.FONT_XXL)
			btn.add_theme_color_override("font_color", UITheme.PARCHMENT)
			btn.add_theme_color_override("font_hover_color", Color(UITheme.GOLD, 1.0))
			btn.add_theme_color_override("font_pressed_color", UITheme.GOLD.lightened(0.2))
		_: UITheme.apply_muted_button(btn, UITheme.FONT_XXL)
	return btn

## 命令模式分段切换样式
func _set_cmd_toggle(btn: Button, on: bool) -> void:
	if on:
		UITheme.apply_primary_button(btn, UITheme.FONT_SM)
	else:
		UITheme.apply_muted_button(btn, UITheme.FONT_SM)

## 特殊地形支持 1V1 / 2V2 / 3V3，乱斗（3/4/5 国环绕）禁用并回退经典大陆
func _update_map_availability(mode_idx: int) -> void:
	if not _map_button:
		return
	var allow := mode_idx <= 2
	if not allow and _map_allowed:
		# 只有从"可选"切到"不可选"时才记下选择，避免每次切模式都把选图清掉
		if GameSettings.map_id != "classic":
			_last_map_id = GameSettings.map_id
		GameSettings.map_id = "classic"
	elif allow and not _map_allowed:
		GameSettings.map_id = _last_map_id
	_map_allowed = allow
	_map_button.disabled = not allow
	_refresh_map_button()

func _refresh_map_button() -> void:
	if not _map_button:
		return
	var info := MapPresets.get_info(GameSettings.map_id)
	var suffix := ""
	if String(info["battle"]) != "":
		suffix = " · " + String(info["battle"])
	_map_button.text = "  %s%s ▸" % [String(info["name"]), suffix]
	if _map_button.disabled:
		_map_button.text += "（乱斗不支持）"

# ---------- 战场地形卡片选择器 ----------
func _open_map_dialog() -> void:
	if _map_button and _map_button.disabled:
		return
	var existing = get_node_or_null("MapDialog")
	if existing:
		existing.queue_free()
		return
	var dlg = MapSelectDialog.new()
	dlg.name = "MapDialog"
	dlg.map_selected.connect(_select_map)
	add_child(dlg)

func _select_map(id: String) -> void:
	GameSettings.map_id = id
	_refresh_map_button()

# 桌面版控件直接挂在根节点下，手机版嵌在滚动容器里；
# 统一递归查找，否则手机端读不到 ModeSelect/DiffSelect，模式永远落到 1V1。
func _find_ui(node_name: String) -> Node:
	var n = find_child(node_name, true, false)
	if n:
		return n
	return get_node_or_null(node_name)

func _on_play_pressed():
	GameSettings.player_nation = nation_select.selected
	GameSettings.enemy_nation = randi() % RTSConfig.Nation.size()
	var ds = _find_ui("DiffSelect")
	if ds: GameSettings.ai_difficulty = ds.selected
	var ms = _find_ui("ModeSelect")
	var mode_idx = ms.selected if ms else 0
	GameSettings.is_ffa = mode_idx >= 3   # 3/4/5 国乱斗
	if GameSettings.is_ffa:
		# 乱斗项自 index 3 起，index 值恰好等于国家数（3/4/5）
		GameSettings.ffa_nation_count = mode_idx
		GameSettings.ai_mode = 1   # 乱斗不套用 1v1/2v2 语义
	else:
		GameSettings.ffa_nation_count = 3
		GameSettings.ai_mode = mode_idx + 1
	# 战场地形：仅 1V1 生效，其余模式回经典大陆
	if _map_button and _map_button.disabled:
		GameSettings.map_id = "classic"
	var fc = _find_ui("FastCheck")
	GameSettings.fast_mode = fc.button_pressed if fc else false
	get_tree().change_scene_to_file("res://scenes/rts_battle.tscn")

func _on_multiplayer_pressed():
	var ds = _find_ui("DiffSelect")
	if ds: GameSettings.ai_difficulty = ds.selected
	GameSettings.ai_mode = 1   # 联机模式不使用单机模式
	GameSettings.is_ffa = false
	GameSettings.map_id = "classic"   # 联机选图在联机大厅里选
	var fc = _find_ui("FastCheck")
	GameSettings.fast_mode = fc.button_pressed if fc else false
	get_tree().change_scene_to_file("res://scenes/online_menu.tscn")

func _on_units_pressed():
	# 打开单位图鉴页面
	get_tree().change_scene_to_file("res://scenes/unit_view.tscn")

func _on_settings_pressed():
	# Toggle settings panel
	var existing = get_node_or_null("SettingsPanel")
	if existing:
		existing.visible = !existing.visible
		return
	if InputSource.use_mobile_ui():
		_create_settings_panel_mobile()
	else:
		_create_settings_panel()

func _create_settings_panel():
	var panel = Panel.new()
	panel.name = "SettingsPanel"
	panel.position = Vector2(750, 400)
	panel.size = Vector2(900, 420)
	panel.add_theme_stylebox_override("panel", UITheme.card_style(UITheme.GOLD))
	add_child(panel)
	UITheme.fade_in(panel, 0.3)

	# Title
	var ttl = UITheme.make_section_title("⚙️ 音量设置", UITheme.GOLD, 30)
	ttl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ttl.position = Vector2(0, 15)
	ttl.size = Vector2(900, 40)
	panel.add_child(ttl)

	# Close button
	var close = Button.new()
	close.text = "✕"
	close.position = Vector2(840, 10)
	close.size = Vector2(50, 50)
	UITheme.apply_muted_button(close, UITheme.FONT_SM)
	close.pressed.connect(func(): panel.visible = false)
	panel.add_child(close)

	# Music volume
	var ml = Label.new()
	ml.text = "音乐音量"
	ml.position = Vector2(50, 90)
	ml.size = Vector2(200, 30)
	UITheme.apply_label(ml, 22, UITheme.PARCHMENT)
	panel.add_child(ml)

	var mv = HSlider.new()
	mv.name = "MusicSlider"
	mv.position = Vector2(280, 92)
	mv.size = Vector2(500, 30)
	mv.min_value = 0; mv.max_value = 100
	mv.value = AudioManager._music_volume * 100
	mv.value_changed.connect(func(v: float): AudioManager.set_music_volume(v / 100.0))
	panel.add_child(mv)

	var mvl = Label.new()
	mvl.name = "MusicValue"
	mvl.text = "%d%%" % int(mv.value)
	mvl.position = Vector2(790, 90)
	mvl.size = Vector2(80, 30)
	UITheme.apply_label(mvl, 20, UITheme.RES_GOLD)
	panel.add_child(mvl)
	mv.value_changed.connect(func(v: float): mvl.text = "%d%%" % int(v))

	# SFX volume
	var sl = Label.new()
	sl.text = "音效音量"
	sl.position = Vector2(50, 160)
	sl.size = Vector2(200, 30)
	UITheme.apply_label(sl, 22, UITheme.PARCHMENT)
	panel.add_child(sl)

	var sv = HSlider.new()
	sv.name = "SFXSlider"
	sv.position = Vector2(280, 162)
	sv.size = Vector2(500, 30)
	sv.min_value = 0; sv.max_value = 100
	sv.value = AudioManager._sfx_volume * 100
	sv.value_changed.connect(func(v: float): AudioManager.set_sfx_volume(v / 100.0))
	panel.add_child(sv)

	var svl = Label.new()
	svl.name = "SFXValue"
	svl.text = "%d%%" % int(sv.value)
	svl.position = Vector2(790, 160)
	svl.size = Vector2(80, 30)
	UITheme.apply_label(svl, 20, UITheme.RES_GOLD)
	panel.add_child(svl)
	sv.value_changed.connect(func(v: float): svl.text = "%d%%" % int(v))

	# Test SFX button
	var test = Button.new()
	test.text = "测试音效"
	test.position = Vector2(280, 230)
	test.size = Vector2(180, 45)
	UITheme.apply_muted_button(test, UITheme.FONT_SM)
	test.pressed.connect(func(): AudioManager.play_sfx("ui_click"))
	panel.add_child(test)

	# --- 命令模式 ---
	var cmd_label = Label.new()
	cmd_label.text = "命令模式"
	cmd_label.position = Vector2(50, 292)
	cmd_label.size = Vector2(200, 30)
	UITheme.apply_label(cmd_label, 22, UITheme.PARCHMENT)
	panel.add_child(cmd_label)

	var cmd_single = Button.new()
	cmd_single.text = "单次命令"
	cmd_single.position = Vector2(280, 292)
	cmd_single.size = Vector2(140, 40)

	var cmd_cont = Button.new()
	cmd_cont.text = "连续命令"
	cmd_cont.position = Vector2(430, 292)
	cmd_cont.size = Vector2(140, 40)

	_set_cmd_toggle(cmd_single, GameSettings.command_mode == 0)
	_set_cmd_toggle(cmd_cont, GameSettings.command_mode == 1)
	cmd_single.pressed.connect(func():
		GameSettings.command_mode = 0
		_set_cmd_toggle(cmd_single, true)
		_set_cmd_toggle(cmd_cont, false)
	)
	cmd_cont.pressed.connect(func():
		GameSettings.command_mode = 1
		_set_cmd_toggle(cmd_single, false)
		_set_cmd_toggle(cmd_cont, true)
	)
	panel.add_child(cmd_single)
	panel.add_child(cmd_cont)

	# Hint
	var hint = Label.new()
	hint.text = "音效距离衰减：50米内可听到 | 单次命令：下令后取消选择"
	hint.position = Vector2(50, 356)
	hint.size = Vector2(800, 25)
	UITheme.apply_label(hint, 16, Color(UITheme.STONE).lightened(0.25))
	panel.add_child(hint)

func _on_quit_pressed():
	get_tree().quit()

# ==================== 手机端布局 ====================
# 桌面版是 2400×1400 绝对定位；手机屏只有 674×393dp，字号与按钮必须按 dp 重排。
# 结构：标题 + 可滚动竖排配置区（国家/AI 难度/模式/地图/快速模式/按钮）。

func _build_mobile_layout() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.10, 0.08, 0.06)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var top_bar := ColorRect.new()
	top_bar.color = Color(UITheme.GOLD)
	top_bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	top_bar.offset_bottom = UILayout.dp(2.0)
	add_child(top_bar)

	var title := Label.new()
	title.text = "👑 FINGER EMPIRE 👑"
	title.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	title.offset_top = UILayout.dp(6.0)
	title.offset_bottom = UILayout.dp(28.0)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", UILayout.font_dp(15.0))
	title.add_theme_color_override("font_color", UITheme.GOLD.lightened(0.15))
	title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	title.add_theme_constant_override("shadow_offset_x", 3)
	title.add_theme_constant_override("shadow_offset_y", 3)
	add_child(title)

	var subtitle := Label.new()
	subtitle.text = "即时战略 · 帝国纷争"
	subtitle.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	subtitle.offset_top = UILayout.dp(28.0)
	subtitle.offset_bottom = UILayout.dp(41.0)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(subtitle, UILayout.font_dp(9.0), UITheme.PARCHMENT)
	add_child(subtitle)

	# 滚动区：配置区内容超过一屏时上下滑动
	var scroll := ScrollContainer.new()
	scroll.name = "MobileScroll"
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.offset_top = UILayout.dp(44.0)
	scroll.offset_left = UILayout.dp(10.0)
	scroll.offset_right = -UILayout.dp(10.0)
	scroll.offset_bottom = -UILayout.dp(6.0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	# 触摸拖动由 MainMenu._input 驱动；容器自身忽略鼠标事件，避免它把 scroll 值又算回 0
	scroll.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(scroll)

	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", int(UILayout.dp(6.0)))
	scroll.add_child(vb)

	# 国家选择（选项文本较长，字号用 10dp 防止截断过多）
	var nation_title := _mobile_section("⚔️ 战役配置 ⚔️", UITheme.GOLD)
	vb.add_child(nation_title)

	nation_select = OptionButton.new()
	nation_select.add_item("  维京    +25%生命  +10%速度")
	nation_select.add_item("  英格兰  +15%攻击  +20%视野  采木+10%")
	nation_select.add_item("  法兰西  +25护甲  城堡2级起始")
	nation_select.add_item("  中国    食物+20%  黄金+10%  人口+10")
	nation_select.add_item("  匈牙利  +15护甲  石材+15%  黄金+10%  人口+5")
	nation_select.add_item("  日本    +15%攻速  +10%攻击")
	nation_select.add_item("  拜占庭  +2双护甲  黄金+10%")
	nation_select.custom_minimum_size = Vector2(0, UILayout.dp(38.0))
	nation_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_option(nation_select, UILayout.font_dp(10.0))
	vb.add_child(nation_select)

	var diff_select := OptionButton.new()
	diff_select.name = "DiffSelect"
	diff_select.add_item("  AI 难度：简单")
	diff_select.add_item("  AI 难度：普通（资源×2）")
	diff_select.add_item("  AI 难度：困难（资源×3+额外）")
	diff_select.add_item("  AI 难度：地狱（困难+速度+20%）")
	diff_select.custom_minimum_size = Vector2(0, UILayout.dp(36.0))
	diff_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_option(diff_select, UILayout.font_dp(10.0))
	vb.add_child(diff_select)

	var mode_select := OptionButton.new()
	mode_select.name = "ModeSelect"
	mode_select.add_item("  模式：1V1")
	mode_select.add_item("  模式：2V2")
	mode_select.add_item("  模式：3V3")
	mode_select.add_item("  乱斗·3国")
	mode_select.add_item("  乱斗·4国")
	mode_select.add_item("  乱斗·5国")
	mode_select.selected = 0
	mode_select.custom_minimum_size = Vector2(0, UILayout.dp(36.0))
	mode_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_option(mode_select, UILayout.font_dp(10.0))
	vb.add_child(mode_select)

	var map_btn := Button.new()
	map_btn.name = "MapButton"
	map_btn.custom_minimum_size = Vector2(0, UILayout.dp(36.0))
	map_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.apply_muted_button(map_btn, UILayout.font_dp(10.0))
	map_btn.pressed.connect(_open_map_dialog)
	vb.add_child(map_btn)
	_map_button = map_btn
	_refresh_map_button()
	mode_select.item_selected.connect(_update_map_availability)
	_update_map_availability(mode_select.selected)

	var fast_check := CheckBox.new()
	fast_check.name = "FastCheck"
	fast_check.text = "快速模式（采集×3）"
	fast_check.custom_minimum_size = Vector2(0, UILayout.dp(34.0))
	fast_check.add_theme_font_size_override("font_size", UILayout.font_dp(10.0))
	fast_check.add_theme_color_override("font_color", UITheme.PARCHMENT)
	fast_check.add_theme_color_override("font_hover_color", UITheme.GOLD)
	fast_check.add_theme_color_override("icon_normal_color", UITheme.GOLD)
	vb.add_child(fast_check)

	var sep := HSeparator.new()
	vb.add_child(sep)

	var btn_data := [
		["⚔️ 单人游戏", _on_play_pressed, "primary"],
		["🌐 联机对战", _on_multiplayer_pressed, "primary"],
		["📖 单位图鉴", _on_units_pressed, "book"],
		["⚙️ 设  置", _on_settings_pressed, "muted"],
		["🚪 退出游戏", _on_quit_pressed, "danger"],
	]
	for data in btn_data:
		var btn := Button.new()
		btn.text = data[0]
		btn.custom_minimum_size = Vector2(0, UILayout.dp(42.0))
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_mobile_style_button(btn, data[2], UILayout.font_dp(13.0))
		btn.pressed.connect(data[1])
		vb.add_child(btn)

	var tip := Label.new()
	tip.text = "手机操作：点按选择 / 拖动平移视角 / 双指缩放 / 长按空地呼出建造菜单 / 右上角小地图切换统计"
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tip.add_theme_font_size_override("font_size", UILayout.font_dp(8.0))
	tip.add_theme_color_override("font_color", Color(UITheme.STONE).lightened(0.25))
	vb.add_child(tip)

	vb.add_child(_mobile_section("v1.0 - Godot 4.7", Color(UITheme.STONE).lightened(0.2)))

func _mobile_section(text: String, color: Color) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", UILayout.font_dp(11.0))
	lbl.add_theme_color_override("font_color", color)
	return lbl

# 菜单按钮样式（primary / danger / book / muted），字号由调用方按 dp 传入
func _mobile_style_button(btn: Button, kind: String, font_size: int) -> void:
	match kind:
		"primary":
			UITheme.apply_primary_button(btn, font_size)
		"danger":
			UITheme.apply_danger_button(btn, font_size)
		"book":
			var sb := StyleBoxFlat.new()
			sb.bg_color = Color(UITheme.SAPPHIRE, 0.16)
			sb.border_color = Color(UITheme.SAPPHIRE, 0.95)
			sb.set_corner_radius_all(10)
			sb.set_border_width_all(2)
			sb.set_content_margin_all(6)
			btn.add_theme_stylebox_override("normal", sb)
			var hover := sb.duplicate()
			hover.bg_color = Color(UITheme.SAPPHIRE, 0.30)
			btn.add_theme_stylebox_override("hover", hover)
			var pressed := hover.duplicate()
			pressed.bg_color = Color(UITheme.SAPPHIRE, 0.44)
			btn.add_theme_stylebox_override("pressed", pressed)
			btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
			btn.add_theme_font_size_override("font_size", font_size)
			btn.add_theme_color_override("font_color", UITheme.PARCHMENT)
			btn.add_theme_color_override("font_hover_color", Color(UITheme.GOLD, 1.0))
			btn.add_theme_color_override("font_pressed_color", UITheme.GOLD.lightened(0.2))
		_:
			UITheme.apply_muted_button(btn, font_size)

# 手机端设置面板：全屏滚动卡片，控件按 dp 放大
func _create_settings_panel_mobile() -> void:
	var panel := Panel.new()
	panel.name = "SettingsPanel"
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.offset_left = UILayout.dp(6.0)
	panel.offset_right = -UILayout.dp(6.0)
	panel.offset_top = UILayout.dp(8.0)
	panel.offset_bottom = -UILayout.dp(8.0)
	panel.add_theme_stylebox_override("panel", UITheme.card_style(UITheme.GOLD))
	panel.z_index = 50
	add_child(panel)
	UITheme.fade_in(panel, 0.3)

	var scroll := ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.offset_left = UILayout.dp(8.0)
	scroll.offset_right = -UILayout.dp(8.0)
	scroll.offset_top = UILayout.dp(8.0)
	scroll.offset_bottom = -UILayout.dp(8.0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(scroll)

	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", int(UILayout.dp(6.0)))
	scroll.add_child(vb)

	var ttl := UITheme.make_section_title("⚙️ 音量设置", UITheme.GOLD, UILayout.font_dp(12.0))
	ttl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(ttl)

	vb.add_child(_mobile_volume_row("音乐音量", AudioManager._music_volume,
		func(v: float): AudioManager.set_music_volume(v), "MusicSlider"))
	vb.add_child(_mobile_volume_row("音效音量", AudioManager._sfx_volume,
		func(v: float): AudioManager.set_sfx_volume(v), "SFXSlider"))

	var test := Button.new()
	test.text = "🔊 测试音效"
	test.custom_minimum_size = Vector2(0, UILayout.dp(36.0))
	UITheme.apply_muted_button(test, UILayout.font_dp(11.0))
	test.pressed.connect(func(): AudioManager.play_sfx("ui_click"))
	vb.add_child(test)

	vb.add_child(_mobile_section("命令模式", UITheme.PARCHMENT))

	var cmd_row := HBoxContainer.new()
	cmd_row.add_theme_constant_override("separation", int(UILayout.dp(6.0)))
	vb.add_child(cmd_row)
	var cmd_single := Button.new()
	cmd_single.text = "单次命令"
	cmd_single.custom_minimum_size = Vector2(0, UILayout.dp(36.0))
	cmd_single.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var cmd_cont := Button.new()
	cmd_cont.text = "连续命令"
	cmd_cont.custom_minimum_size = Vector2(0, UILayout.dp(36.0))
	cmd_cont.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_set_cmd_toggle(cmd_single, GameSettings.command_mode == 0)
	_set_cmd_toggle(cmd_cont, GameSettings.command_mode == 1)
	cmd_single.add_theme_font_size_override("font_size", UILayout.font_dp(11.0))
	cmd_cont.add_theme_font_size_override("font_size", UILayout.font_dp(11.0))
	cmd_single.pressed.connect(func():
		GameSettings.command_mode = 0
		_set_cmd_toggle(cmd_single, true)
		_set_cmd_toggle(cmd_cont, false)
	)
	cmd_cont.pressed.connect(func():
		GameSettings.command_mode = 1
		_set_cmd_toggle(cmd_single, false)
		_set_cmd_toggle(cmd_cont, true)
	)
	cmd_row.add_child(cmd_single)
	cmd_row.add_child(cmd_cont)

	var hint := Label.new()
	hint.text = "音效距离衰减：50米内可听到 | 单次命令：下令后取消选择"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", UILayout.font_dp(8.0))
	hint.add_theme_color_override("font_color", Color(UITheme.STONE).lightened(0.25))
	vb.add_child(hint)

	var close := Button.new()
	close.text = "关闭"
	close.custom_minimum_size = Vector2(0, UILayout.dp(40.0))
	UITheme.apply_danger_button(close, UILayout.font_dp(12.0))
	close.pressed.connect(func(): panel.visible = false)
	vb.add_child(close)

# 手机端音量行：标签 + 滑块 + 百分比
func _mobile_volume_row(label_text: String, value: float, setter: Callable, slider_name: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", int(UILayout.dp(4.0)))
	var lbl := Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size = Vector2(UILayout.dp(62.0), 0)
	lbl.add_theme_font_size_override("font_size", UILayout.font_dp(10.0))
	lbl.add_theme_color_override("font_color", UITheme.PARCHMENT)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(lbl)

	var slider := HSlider.new()
	slider.name = slider_name
	slider.custom_minimum_size = Vector2(0, UILayout.dp(28.0))
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.min_value = 0
	slider.max_value = 100
	slider.value = value * 100.0
	row.add_child(slider)

	var val := Label.new()
	val.text = "%d%%" % int(slider.value)
	val.custom_minimum_size = Vector2(UILayout.dp(34.0), 0)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val.add_theme_font_size_override("font_size", UILayout.font_dp(10.0))
	val.add_theme_color_override("font_color", UITheme.RES_GOLD)
	val.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(val)

	slider.value_changed.connect(func(v: float):
		val.text = "%d%%" % int(v)
		setter.call(v / 100.0)
	)
	return row

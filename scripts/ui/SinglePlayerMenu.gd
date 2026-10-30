extends Control

const MapPresets = preload("res://scripts/map/MapPresets.gd")
const MapSelectDialog = preload("res://scripts/ui/MapSelectDialog.gd")
const AppVersion = preload("res://scripts/core/AppVersion.gd")

var nation_select: OptionButton
var diff_select: OptionButton
var mode_select: OptionButton
var fast_check: CheckBox
var research_check: CheckBox
var replay_check: CheckBox
var _map_button: Button
var _nation_detail: Label
var _mode_desc: Label
var _summary: Label
var _summary_values: Dictionary = {}
var _last_mode_idx: int = 0

func _input(event: InputEvent) -> void:
	if not InputSource.use_mobile_ui():
		return
	if event is InputEventScreenDrag:
		UILayout.scroll_at(self, event.position, event.relative.y)

func _ready() -> void:
	add_child(TouchDragGuard.new())
	AudioManager.play_music("menu")

	var vs = get_viewport().get_visible_rect().size
	var s = min(vs.x / 2400.0, vs.y / 1400.0)
	scale = Vector2(s, s)
	position = (vs - Vector2(2400, 1400) * s) / 2.0

	if InputSource.use_mobile_ui():
		scale = Vector2.ONE
		position = Vector2.ZERO
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		size = UILayout.view_size()
		add_child(OrientationReload.new())
		_build_mobile_ui()
		return

	# 桌面/网页：按当前实际画布铺满，避免专属界面又缩回中间一条。
	var design_size = Vector2(ceil(vs.x / s), maxf(1400.0, ceil(vs.y / s)))
	size = design_size
	position = Vector2.ZERO
	_build_desktop_ui()

# ---------------- 桌面版 ----------------
func _build_desktop_ui() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.10, 0.08, 0.06)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	move_child(bg, 0)

	var bar := ColorRect.new()
	bar.color = Color(UITheme.GOLD)
	bar.size = Vector2(size.x, 6)
	add_child(bar)
	var bar2 := ColorRect.new()
	bar2.color = Color(UITheme.GOLD, 0.35)
	bar2.position = Vector2(0, 6)
	bar2.size = Vector2(size.x, 3)
	add_child(bar2)

	var frame := MarginContainer.new()
	frame.name = "DesktopFrame"
	frame.size = size
	frame.add_theme_constant_override("margin_left", 28)
	frame.add_theme_constant_override("margin_right", 28)
	frame.add_theme_constant_override("margin_top", 20)
	frame.add_theme_constant_override("margin_bottom", 20)
	add_child(frame)

	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 12)
	frame.add_child(layout)

	# ---------- 标题栏 ----------
	var header := HBoxContainer.new()
	header.custom_minimum_size = Vector2(0, 132)
	header.add_theme_constant_override("separation", 18)
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	layout.add_child(header)

	var back_btn := _make_button("← 返回主菜单", "muted", 24)
	back_btn.name = "BackButton"
	back_btn.custom_minimum_size = Vector2(250, 64)
	back_btn.pressed.connect(_on_back_pressed)
	header.add_child(back_btn)

	var title_box := VBoxContainer.new()
	title_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_box.alignment = BoxContainer.ALIGNMENT_CENTER
	title_box.add_theme_constant_override("separation", 2)
	header.add_child(title_box)

	var title := Label.new()
	title.text = "⚔  单人征战"
	title.add_theme_font_size_override("font_size", 56)
	title.add_theme_color_override("font_color", UITheme.GOLD.lightened(0.15))
	title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	title.add_theme_constant_override("shadow_offset_x", 3)
	title.add_theme_constant_override("shadow_offset_y", 3)
	title.add_theme_constant_override("shadow_size", 10)
	title_box.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "配置文明、难度与战场，然后开始你的帝国征程"
	UITheme.apply_label(subtitle, 22, UITheme.PARCHMENT)
	title_box.add_child(subtitle)

	var version := Label.new()
	version.text = "%s  ·  Godot 4.7" % AppVersion.display()
	version.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	version.custom_minimum_size = Vector2(420, 0)
	UITheme.apply_label(version, 18, Color(UITheme.STONE).lightened(0.25))
	header.add_child(version)

	# ---------- 主体 ----------
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 18)
	layout.add_child(body)

	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_stretch_ratio = 1.22
	left.add_theme_constant_override("separation", 16)
	body.add_child(left)

	# 文明
	var nation_panel := _make_panel()
	nation_panel.name = "NationPanel"
	nation_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	nation_panel.size_flags_stretch_ratio = 1.15
	left.add_child(nation_panel)
	var nation_vb := _panel_body(nation_panel)
	nation_vb.add_child(UITheme.make_section_title("🏛 选择文明", UITheme.GOLD, 32))
	var nation_caption := Label.new()
	nation_caption.text = "不同文明的开局加成不同，联机中每位玩家各自生效。"
	UITheme.apply_label(nation_caption, 18, Color(UITheme.PARCHMENT, 0.78))
	nation_vb.add_child(nation_caption)

	nation_select = OptionButton.new()
	nation_select.name = "NationSelect"
	nation_select.add_item("  维京    +25%生命  +10%速度")
	nation_select.add_item("  英格兰  +15%攻击  +20%视野  采木+10%")
	nation_select.add_item("  法兰西  +25护甲  城堡2级起始")
	nation_select.add_item("  中国    食物+20%  黄金+10%  人口+10")
	nation_select.add_item("  匈牙利  +15护甲  石材+15%  黄金+10%  人口+5")
	nation_select.add_item("  日本    +15%攻速  +10%攻击")
	nation_select.add_item("  拜占庭  +2双护甲  黄金+10%")
	nation_select.add_item("  蒙古    速度+20%  攻速+10%  视野+20%")
	nation_select.add_item("  波斯    生命+15%  盾甲+1  黄金+15%  人口+5")
	nation_select.add_item("  西班牙  攻击+10%  铠甲+1  黄金+15%")
	nation_select.selected = clampi(GameSettings.player_nation, 0, 9)
	nation_select.custom_minimum_size = Vector2(0, 62)
	nation_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_option(nation_select, 20)
	nation_select.item_selected.connect(_on_nation_selected)
	nation_vb.add_child(nation_select)

	_nation_detail = Label.new()
	_nation_detail.custom_minimum_size = Vector2(0, 76)
	_nation_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.apply_label(_nation_detail, 18, Color(UITheme.PARCHMENT, 0.82))
	nation_vb.add_child(_nation_detail)

	# 难度 + 模式
	var selectors := HBoxContainer.new()
	selectors.add_theme_constant_override("separation", 16)
	selectors.size_flags_vertical = Control.SIZE_EXPAND_FILL
	selectors.size_flags_stretch_ratio = 1.0
	left.add_child(selectors)

	var diff_panel := _make_panel()
	diff_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	selectors.add_child(diff_panel)
	var diff_vb := _panel_body(diff_panel)
	diff_vb.add_child(UITheme.make_section_title("🤖 AI 难度", UITheme.GOLD, 28))
	diff_select = OptionButton.new()
	diff_select.name = "DiffSelect"
	diff_select.add_item("  简单")
	diff_select.add_item("  普通（AI资源×2）")
	diff_select.add_item("  困难（AI资源×3+额外资源）")
	diff_select.add_item("  地狱（困难+速度+20%）")
	diff_select.custom_minimum_size = Vector2(0, 60)
	diff_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_option(diff_select, 18)
	diff_select.item_selected.connect(_on_option_changed)
	diff_vb.add_child(diff_select)
	var diff_hint := Label.new()
	diff_hint.text = "越高难度，AI 的资源与扩张速度越快。"
	diff_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.apply_label(diff_hint, 16, Color(UITheme.PARCHMENT, 0.7))
	diff_vb.add_child(diff_hint)

	var mode_panel := _make_panel()
	mode_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	selectors.add_child(mode_panel)
	var mode_vb := _panel_body(mode_panel)
	mode_vb.add_child(UITheme.make_section_title("⚔ 对局模式", UITheme.GOLD, 28))
	mode_select = OptionButton.new()
	mode_select.name = "ModeSelect"
	mode_select.add_item("  1V1 单挑")
	mode_select.add_item("  2V2 团队")
	mode_select.add_item("  3V3 团队")
	mode_select.add_item("  乱斗 · 3 国")
	mode_select.add_item("  乱斗 · 4 国")
	mode_select.add_item("  乱斗 · 5 国")
	mode_select.selected = 0
	mode_select.custom_minimum_size = Vector2(0, 60)
	mode_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_option(mode_select, 18)
	mode_select.item_selected.connect(_on_mode_selected)
	mode_vb.add_child(mode_select)
	_mode_desc = Label.new()
	_mode_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_mode_desc.custom_minimum_size = Vector2(0, 72)
	UITheme.apply_label(_mode_desc, 16, Color(UITheme.PARCHMENT, 0.72))
	mode_vb.add_child(_mode_desc)

	# 地形 + 规则
	var map_panel := _make_panel()
	map_panel.name = "MapPanel"
	map_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	map_panel.size_flags_stretch_ratio = 1.0
	left.add_child(map_panel)
	var map_vb := _panel_body(map_panel)
	map_vb.add_child(UITheme.make_section_title("🗺 战场与规则", UITheme.GOLD, 28))

	var map_caption := Label.new()
	map_caption.text = "战场地形"
	UITheme.apply_label(map_caption, 17, Color(UITheme.PARCHMENT, 0.82))
	map_vb.add_child(map_caption)

	_map_button = Button.new()
	_map_button.name = "MapButton"
	_map_button.custom_minimum_size = Vector2(0, 56)
	_map_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.apply_muted_button(_map_button, 19)
	_map_button.pressed.connect(_open_map_dialog)
	map_vb.add_child(_map_button)
	_refresh_map_button()

	fast_check = CheckBox.new()
	fast_check.name = "FastCheck"
	fast_check.text = "快速模式（采集/科研 ×3，建造/生产 ×2）"
	fast_check.custom_minimum_size = Vector2(0, 38)
	fast_check.add_theme_font_size_override("font_size", 18)
	fast_check.add_theme_color_override("font_color", UITheme.PARCHMENT)
	fast_check.add_theme_color_override("font_hover_color", UITheme.GOLD)
	fast_check.add_theme_color_override("icon_normal_color", UITheme.GOLD)
	fast_check.toggled.connect(func(_on): _update_summary())
	map_vb.add_child(fast_check)

	research_check = CheckBox.new()
	research_check.name = "ResearchCheck"
	research_check.text = "科研模式（四时代 · 科技树）"
	research_check.custom_minimum_size = Vector2(0, 38)
	research_check.add_theme_font_size_override("font_size", 18)
	research_check.add_theme_color_override("font_color", UITheme.PARCHMENT)
	research_check.add_theme_color_override("font_hover_color", UITheme.GOLD)
	research_check.add_theme_color_override("icon_normal_color", UITheme.GOLD)
	research_check.tooltip_text = "关闭为经典模式（原升级模式）；开启后通过时代与科技树解锁建筑/单位。"
	research_check.button_pressed = GameSettings.is_research_mode()
	research_check.toggled.connect(_on_research_toggled)
	map_vb.add_child(research_check)

	# 录像方式：默认快照录像；勾选后使用严格指令回放（固定种子+固定步长，文件更小）。
	replay_check = CheckBox.new()
	replay_check.name = "ReplayModeCheck"
	replay_check.text = "指令回放录像（严格确定性 · 文件更小）"
	replay_check.custom_minimum_size = Vector2(0, 38)
	replay_check.add_theme_font_size_override("font_size", 18)
	replay_check.add_theme_color_override("font_color", UITheme.PARCHMENT)
	replay_check.add_theme_color_override("font_hover_color", UITheme.GOLD)
	replay_check.add_theme_color_override("icon_normal_color", UITheme.GOLD)
	replay_check.tooltip_text = "不勾选：按快照录像，兼容现有回放；勾选：只记录你的操作与随机种子，回放时重新模拟。"
	replay_check.button_pressed = GameSettings.replay_mode == "command"
	replay_check.toggled.connect(func(on): GameSettings.replay_mode = "command" if on else "snapshot"; _update_summary())
	map_vb.add_child(replay_check)

	# 右侧：摘要 + 操作
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_stretch_ratio = 0.78
	right.add_theme_constant_override("separation", 16)
	body.add_child(right)

	var summary_panel := _make_panel()
	summary_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(summary_panel)
	var summary_vb := _panel_body(summary_panel)
	summary_vb.add_child(UITheme.make_section_title("📋 出征准备", UITheme.GOLD, 32))
	var summary_tip := Label.new()
	summary_tip.text = "确认配置后点击下方按钮开始一局单人战役。"
	summary_tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.apply_label(summary_tip, 17, Color(UITheme.PARCHMENT, 0.72))
	summary_vb.add_child(summary_tip)

	_summary = Label.new()
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_summary.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_summary.add_theme_font_size_override("font_size", 21)
	_summary.add_theme_color_override("font_color", UITheme.PARCHMENT)
	_summary.add_theme_constant_override("line_spacing", 8)
	summary_vb.add_child(_summary)

	var start_btn := _make_button("⚔  开始征战", "primary", 34)
	start_btn.name = "StartBattleButton"
	start_btn.custom_minimum_size = Vector2(0, 108)
	start_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	start_btn.pressed.connect(_start_battle)
	UITheme.pulse(start_btn, 1.02, 1.2)
	right.add_child(start_btn)

	var bottom_back := _make_button("← 返回主菜单", "muted", 24)
	bottom_back.custom_minimum_size = Vector2(0, 64)
	bottom_back.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom_back.pressed.connect(_on_back_pressed)
	right.add_child(bottom_back)

	# 底部提示
	var tip_panel := PanelContainer.new()
	tip_panel.custom_minimum_size = Vector2(0, 96)
	tip_panel.add_theme_stylebox_override("panel", UITheme.card_style(UITheme.GOLD))
	layout.add_child(tip_panel)
	var tip_margin := MarginContainer.new()
	tip_margin.add_theme_constant_override("margin_left", 28)
	tip_margin.add_theme_constant_override("margin_right", 28)
	tip_margin.add_theme_constant_override("margin_top", 12)
	tip_margin.add_theme_constant_override("margin_bottom", 12)
	tip_panel.add_child(tip_margin)
	var tip_box := VBoxContainer.new()
	tip_box.alignment = BoxContainer.ALIGNMENT_CENTER
	tip_box.add_theme_constant_override("separation", 4)
	tip_margin.add_child(tip_box)
	_add_tip(tip_box, "🖱️ 左键选择/框选 · 右键建造菜单 · 中键拖拽 · 滚轮缩放 · A+左键攻击 · M+左键移动", 16, UITheme.PARCHMENT)
	_add_tip(tip_box, "💡 新手建议先用简单难度熟悉经济与兵种；需要完整说明可回主菜单打开「📘 操作指南」", 16, Color(UITheme.GOLD, 0.9))

	# 初始化摘要与事件
	_apply_saved_defaults()
	_on_nation_selected(nation_select.selected)
	_on_mode_selected(mode_select.selected)
	_on_option_changed(0)
	UITheme.fade_in(left, 0.35)
	UITheme.fade_in(right, 0.4)

func _apply_saved_defaults() -> void:
	if diff_select != null:
		diff_select.selected = clampi(GameSettings.ai_difficulty, 0, 3)
	if mode_select != null:
		if GameSettings.is_ffa:
			mode_select.selected = clampi(GameSettings.ffa_nation_count, 3, 5)
		else:
			mode_select.selected = clampi(GameSettings.ai_mode - 1, 0, 2)
	if fast_check != null:
		fast_check.button_pressed = GameSettings.fast_mode
	if research_check != null:
		research_check.button_pressed = GameSettings.is_research_mode()

func _make_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", UITheme.card_style(UITheme.GOLD))
	return panel

func _panel_body(panel: PanelContainer) -> VBoxContainer:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_bottom", 14)
	panel.add_child(margin)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	margin.add_child(vb)
	return vb

func _make_button(text: String, kind: String, font_size: int) -> Button:
	var btn := Button.new()
	btn.text = text
	match kind:
		"primary":
			UITheme.apply_primary_button(btn, font_size)
		"danger":
			UITheme.apply_danger_button(btn, font_size)
		"book":
			var sb := StyleBoxFlat.new()
			sb.bg_color = Color(UITheme.SAPPHIRE, 0.18)
			sb.border_color = Color(UITheme.SAPPHIRE, 0.95)
			sb.set_corner_radius_all(10)
			sb.set_border_width_all(2)
			sb.set_content_margin_all(6)
			btn.add_theme_stylebox_override("normal", sb)
			var hover := sb.duplicate()
			hover.bg_color = Color(UITheme.SAPPHIRE, 0.32)
			btn.add_theme_stylebox_override("hover", hover)
			var pressed := hover.duplicate()
			pressed.bg_color = Color(UITheme.SAPPHIRE, 0.44)
			btn.add_theme_stylebox_override("pressed", pressed)
			btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
			btn.add_theme_font_size_override("font_size", font_size)
			btn.add_theme_color_override("font_color", UITheme.PARCHMENT)
			btn.add_theme_color_override("font_hover_color", UITheme.GOLD)
		_:
			UITheme.apply_muted_button(btn, font_size)
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	return btn

func _style_option(o: OptionButton, font_size: int) -> void:
	o.add_theme_font_size_override("font_size", font_size)
	o.add_theme_color_override("font_color", UITheme.PARCHMENT)
	o.add_theme_color_override("font_hover_color", UITheme.GOLD)
	var pop = o.get_popup()
	pop.add_theme_font_size_override("font_size", font_size)
	pop.add_theme_color_override("font_color", UITheme.PARCHMENT)
	pop.add_theme_color_override("font_hover_color", UITheme.GOLD)

func _add_tip(box: VBoxContainer, text: String, font_size: int, color: Color) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.apply_label(lbl, font_size, color)
	box.add_child(lbl)

# ---------------- 数据与回调 ----------------
func _refresh_map_button() -> void:
	if _map_button == null:
		return
	var info := MapPresets.get_info(GameSettings.map_id)
	var suffix := ""
	if String(info["battle"]) != "":
		suffix = " · " + String(info["battle"])
	_map_button.text = "  %s%s ▸" % [String(info["name"]), suffix]
	_update_summary()

func _open_map_dialog() -> void:
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

func _on_nation_selected(idx: int) -> void:
	if _nation_detail == null or nation_select == null:
		return
	if idx < 0 or idx >= nation_select.item_count:
		return
	_nation_detail.text = "🏛 当前文明：%s\n开局加成会直接作用到单位与资源；联机中每位玩家各自生效。" % nation_select.get_item_text(idx).strip_edges()
	_update_summary()

func _on_mode_selected(idx: int) -> void:
	_last_mode_idx = clampi(idx, 0, 5)
	if _mode_desc == null:
		return
	match _last_mode_idx:
		0:
			_mode_desc.text = "1V1：单路对决，摧毁敌方主城即可获胜。"
		1, 2:
			_mode_desc.text = "团队战：与队友共享视野，任意队友主城仍在即可继续。"
		_:
			_mode_desc.text = "乱斗：多国混战，可结盟、纳贡或背叛，最后存活者获胜。"
	_update_summary()

func _on_option_changed(_idx: int) -> void:
	_update_summary()

func _on_research_toggled(on: bool) -> void:
	GameSettings.progression_mode = GameSettings.ProgressionMode.RESEARCH if on else GameSettings.ProgressionMode.CLASSIC
	_update_summary()

func _update_summary() -> void:
	if _summary == null:
		return
	var mode_names = ["1V1 单挑", "2V2 团队", "3V3 团队", "乱斗 · 3 国", "乱斗 · 4 国", "乱斗 · 5 国"]
	var diff_names = ["简单", "普通", "困难", "地狱"]
	var nation_name := ""
	if nation_select != null and nation_select.selected >= 0:
		nation_name = nation_select.get_item_text(nation_select.selected).strip_edges()
	var diff_name: String = diff_names[clampi(diff_select.selected if diff_select else 0, 0, 3)]
	var mode_name: String = mode_names[clampi(mode_select.selected if mode_select else 0, 0, 5)]
	var map_name := String(MapPresets.get_info(GameSettings.map_id)["name"])
	var progression := "科研 · 四时代科技树" if GameSettings.is_research_mode() else "经典 · 升级解锁"
	var pace := "快速" if (fast_check != null and fast_check.button_pressed) else "标准"
	var replay := "指令回放" if (replay_check != null and replay_check.button_pressed) else "快照录像"
	_summary.text = "文明\n%s\n\n难度\n%s\n\n模式\n%s\n\n地形\n%s\n\n发展\n%s\n\n节奏\n%s\n\n录像\n%s" % [
		nation_name, diff_name, mode_name, map_name, progression, pace, replay
	]

func _start_battle() -> void:
	GameSettings.tutorial_mode = false
	GameSettings.campaign_mode = false
	GameSettings.campaign_level_id = ""
	GameSettings.player_nation = nation_select.selected if nation_select != null else 0
	var enemy_nation = randi() % (RTSConfig.Nation.size() - 1)
	if enemy_nation >= GameSettings.player_nation:
		enemy_nation += 1
	GameSettings.enemy_nation = enemy_nation
	GameSettings.ai_difficulty = diff_select.selected if diff_select != null else 0
	var mode_idx := mode_select.selected if mode_select != null else 0
	GameSettings.is_ffa = mode_idx >= 3
	if GameSettings.is_ffa:
		GameSettings.ffa_nation_count = mode_idx
		GameSettings.ai_mode = 1
	else:
		GameSettings.ffa_nation_count = 3
		GameSettings.ai_mode = mode_idx + 1
	GameSettings.fast_mode = fast_check.button_pressed if fast_check != null else false
	GameSettings.progression_mode = GameSettings.ProgressionMode.RESEARCH if (research_check != null and research_check.button_pressed) else GameSettings.ProgressionMode.CLASSIC
	GameSettings.replay_mode = "command" if (replay_check != null and replay_check.button_pressed) else "snapshot"
	GameSettings.command_replay = false
	GameSettings.command_replay_file = ""
	GameSettings.deterministic_sim = false
	GameSettings.sim_seed = 0
	GameSettings.map_seed = 0
	LoadingScreen.goto_scene("res://scenes/rts_battle.tscn")

func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")

# ---------------- 手机版 ----------------
func _build_mobile_ui() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.10, 0.08, 0.06)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var top_bar := ColorRect.new()
	top_bar.color = Color(UITheme.GOLD)
	top_bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	top_bar.offset_bottom = UILayout.dp(2.0)
	add_child(top_bar)

	var back := Button.new()
	back.text = "← 返回"
	back.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	back.offset_left = UILayout.dp(6.0)
	back.offset_top = UILayout.dp(6.0)
	back.offset_right = UILayout.dp(52.0)
	back.offset_bottom = UILayout.dp(30.0)
	_mobile_style(back, "muted", UILayout.font_dp(9.0))
	back.pressed.connect(_on_back_pressed)
	add_child(back)

	var title := Label.new()
	title.text = "⚔ 单人征战"
	title.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	title.offset_top = UILayout.dp(7.0)
	title.offset_bottom = UILayout.dp(31.0)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", UILayout.font_dp(14.0))
	title.add_theme_color_override("font_color", UITheme.GOLD.lightened(0.15))
	add_child(title)

	var scroll := ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.offset_top = UILayout.dp(38.0)
	scroll.offset_left = UILayout.dp(8.0)
	scroll.offset_right = -UILayout.dp(8.0)
	scroll.offset_bottom = -UILayout.dp(6.0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(scroll)

	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", UILayout.dp(5.0))
	scroll.add_child(vb)

	vb.add_child(_mobile_section("🏛 选择文明"))
	nation_select = OptionButton.new()
	nation_select.add_item("  维京    +25%生命  +10%速度")
	nation_select.add_item("  英格兰  +15%攻击  +20%视野  采木+10%")
	nation_select.add_item("  法兰西  +25护甲  城堡2级起始")
	nation_select.add_item("  中国    食物+20%  黄金+10%  人口+10")
	nation_select.add_item("  匈牙利  +15护甲  石材+15%  黄金+10%  人口+5")
	nation_select.add_item("  日本    +15%攻速  +10%攻击")
	nation_select.add_item("  拜占庭  +2双护甲  黄金+10%")
	nation_select.add_item("  蒙古    速度+20%  攻速+10%  视野+20%")
	nation_select.add_item("  波斯    生命+15%  盾甲+1  黄金+15%  人口+5")
	nation_select.add_item("  西班牙  攻击+10%  铠甲+1  黄金+15%")
	nation_select.selected = clampi(GameSettings.player_nation, 0, 9)
	nation_select.custom_minimum_size = Vector2(0, UILayout.dp(38.0))
	nation_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_option(nation_select, UILayout.font_dp(10.0))
	nation_select.item_selected.connect(_on_nation_selected)
	vb.add_child(nation_select)

	_nation_detail = Label.new()
	_nation_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.apply_label(_nation_detail, UILayout.font_dp(8.0), Color(UITheme.PARCHMENT, 0.8))
	vb.add_child(_nation_detail)

	vb.add_child(_mobile_section("🤖 AI 难度"))
	diff_select = OptionButton.new()
	diff_select.add_item("  简单")
	diff_select.add_item("  普通（AI资源×2）")
	diff_select.add_item("  困难（AI资源×3+额外资源）")
	diff_select.add_item("  地狱（困难+速度+20%）")
	diff_select.custom_minimum_size = Vector2(0, UILayout.dp(36.0))
	diff_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_option(diff_select, UILayout.font_dp(10.0))
	diff_select.item_selected.connect(_on_option_changed)
	vb.add_child(diff_select)

	vb.add_child(_mobile_section("⚔ 对局模式"))
	mode_select = OptionButton.new()
	mode_select.add_item("  1V1 单挑")
	mode_select.add_item("  2V2 团队")
	mode_select.add_item("  3V3 团队")
	mode_select.add_item("  乱斗 · 3 国")
	mode_select.add_item("  乱斗 · 4 国")
	mode_select.add_item("  乱斗 · 5 国")
	mode_select.custom_minimum_size = Vector2(0, UILayout.dp(36.0))
	mode_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_option(mode_select, UILayout.font_dp(10.0))
	mode_select.item_selected.connect(_on_mode_selected)
	vb.add_child(mode_select)
	_mode_desc = Label.new()
	_mode_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.apply_label(_mode_desc, UILayout.font_dp(8.0), Color(UITheme.PARCHMENT, 0.7))
	vb.add_child(_mode_desc)

	vb.add_child(_mobile_section("🗺 战场与规则"))
	_map_button = Button.new()
	_map_button.custom_minimum_size = Vector2(0, UILayout.dp(36.0))
	_map_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.apply_muted_button(_map_button, UILayout.font_dp(10.0))
	_map_button.pressed.connect(_open_map_dialog)
	vb.add_child(_map_button)
	_refresh_map_button()

	fast_check = CheckBox.new()
	fast_check.text = "快速模式（采集/科研×3）"
	fast_check.custom_minimum_size = Vector2(0, UILayout.dp(32.0))
	fast_check.add_theme_font_size_override("font_size", UILayout.font_dp(9.0))
	fast_check.add_theme_color_override("font_color", UITheme.PARCHMENT)
	fast_check.toggled.connect(func(_on): _update_summary())
	vb.add_child(fast_check)

	research_check = CheckBox.new()
	research_check.text = "科研模式（四时代·科技树）"
	research_check.custom_minimum_size = Vector2(0, UILayout.dp(32.0))
	research_check.add_theme_font_size_override("font_size", UILayout.font_dp(9.0))
	research_check.add_theme_color_override("font_color", UITheme.PARCHMENT)
	research_check.button_pressed = GameSettings.is_research_mode()
	research_check.toggled.connect(_on_research_toggled)
	vb.add_child(research_check)

	replay_check = CheckBox.new()
	replay_check.text = "指令回放录像（严格确定性）"
	replay_check.custom_minimum_size = Vector2(0, UILayout.dp(32.0))
	replay_check.add_theme_font_size_override("font_size", UILayout.font_dp(9.0))
	replay_check.add_theme_color_override("font_color", UITheme.PARCHMENT)
	replay_check.button_pressed = GameSettings.replay_mode == "command"
	replay_check.toggled.connect(func(on): GameSettings.replay_mode = "command" if on else "snapshot"; _update_summary())
	vb.add_child(replay_check)

	vb.add_child(_mobile_section("📋 出征准备"))
	_summary = Label.new()
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_summary.add_theme_font_size_override("font_size", UILayout.font_dp(9.0))
	_summary.add_theme_color_override("font_color", UITheme.PARCHMENT)
	vb.add_child(_summary)

	var start_btn := Button.new()
	start_btn.text = "⚔  开始征战"
	start_btn.custom_minimum_size = Vector2(0, UILayout.dp(44.0))
	start_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mobile_style(start_btn, "primary", UILayout.font_dp(13.0))
	start_btn.pressed.connect(_start_battle)
	vb.add_child(start_btn)

	var back_bottom := Button.new()
	back_bottom.text = "← 返回主菜单"
	back_bottom.custom_minimum_size = Vector2(0, UILayout.dp(36.0))
	back_bottom.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mobile_style(back_bottom, "muted", UILayout.font_dp(10.0))
	back_bottom.pressed.connect(_on_back_pressed)
	vb.add_child(back_bottom)

	_apply_saved_defaults()
	_on_nation_selected(nation_select.selected)
	_on_mode_selected(mode_select.selected)
	_on_option_changed(0)

func _mobile_section(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", UILayout.font_dp(11.0))
	lbl.add_theme_color_override("font_color", UITheme.GOLD)
	return lbl

func _mobile_style(btn: Button, kind: String, font_size: int) -> void:
	match kind:
		"primary":
			UITheme.apply_primary_button(btn, font_size)
		"danger":
			UITheme.apply_danger_button(btn, font_size)
		_:
			UITheme.apply_muted_button(btn, font_size)

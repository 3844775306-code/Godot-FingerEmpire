extends Control

# 闯关模式选关界面：章节 + 关卡卡片 + 星级进度 + 关卡简报。
# 全部 UI 在代码里搭，方便跟着 UILayout 适配手机端。

const CampaignDataScript = preload("res://scripts/data/CampaignData.gd")
const CampaignProgressScript = preload("res://scripts/core/CampaignProgress.gd")
const UIThemeScript = preload("res://scripts/ui/UITheme.gd")

var _mobile := false
var _vb: VBoxContainer = null
var _level_area: VBoxContainer = null
var _dialog_layer: Control = null
var _mode_check: CheckBox = null
var _free_banner: Label = null
var _progress_label: Label = null
var _free_tick := 0.0
var _free_expiry_rebuilt := false

func _ready() -> void:
	# 触屏滑动误点守卫：选关卡片列表滑动后不误进关卡
	add_child(TouchDragGuard.new())
	_mobile = InputSource.use_mobile_ui()
	if _mobile:
		# 横竖屏切换后重建选关卡片，避免竖屏下仍按横屏的列宽排版。
		add_child(OrientationReload.new())
	GameSettings.campaign_mode = true
	AudioManager.play_music("menu")

	# 桌面按 2400×1400 设计画布缩放；手机端铺满实际视口。
	var vs = get_viewport().get_visible_rect().size
	var s = min(vs.x / 2400.0, vs.y / 1400.0)
	if _mobile:
		scale = Vector2.ONE
		position = Vector2.ZERO
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		size = UILayout.view_size()
	else:
		# 场景根节点在 tscn 里是 FULL_RECT；先改成左上锚点，
		# 否则 _ready 设置的 2400 设计尺寸会在下一帧被锚点覆盖成视口大小。
		set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
		scale = Vector2(s, s)
		position = Vector2.ZERO
		size = Vector2(ceil(vs.x / s), maxf(1400.0, ceil(vs.y / s)))
	_build()
	set_process(true)

func _process(delta: float) -> void:
	if _free_banner == null:
		return
	_free_tick += delta
	if _free_tick < 1.0:
		return
	_free_tick = 0.0
	_update_free_banner()

func _build() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.055, 0.048, 0.043)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var frame := MarginContainer.new()
	frame.name = "CampaignFrame"
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.add_theme_constant_override("margin_left", UILayout.dp(10.0) if _mobile else 32)
	frame.add_theme_constant_override("margin_right", UILayout.dp(10.0) if _mobile else 32)
	frame.add_theme_constant_override("margin_top", UILayout.dp(8.0) if _mobile else 24)
	frame.add_theme_constant_override("margin_bottom", UILayout.dp(6.0) if _mobile else 22)
	add_child(frame)

	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", UILayout.dp(6.0) if _mobile else 12)
	frame.add_child(layout)

	_mode_check = _make_mode_check()
	layout.add_child(_make_header())
	layout.add_child(_make_free_banner())
	if _mobile and _mode_check != null:
		layout.add_child(_mode_check)

	var scroll := ScrollContainer.new()
	scroll.name = "LevelScroll"
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	layout.add_child(scroll)

	_level_area = VBoxContainer.new()
	_level_area.name = "LevelArea"
	_level_area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_level_area.add_theme_constant_override("separation", UILayout.dp(14.0) if _mobile else 22)
	scroll.add_child(_level_area)

	_free_expiry_rebuilt = not CampaignProgressScript.is_free_unlock_active()
	_populate_levels()
	_update_free_banner()
	_refresh_progress()

func _make_header() -> Control:
	if _mobile:
		var box := VBoxContainer.new()
		box.name = "Header"
		box.add_theme_constant_override("separation", UILayout.dp(2.0))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", UILayout.dp(8.0))
		box.add_child(row)
		row.add_child(_make_back_button())
		var title_box := VBoxContainer.new()
		title_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		title_box.alignment = BoxContainer.ALIGNMENT_CENTER
		title_box.add_theme_constant_override("separation", 1)
		row.add_child(title_box)
		var title := Label.new()
		title.text = "⚔ 帝国远征"
		UIThemeScript.apply_label(title, UILayout.font_dp(19.0), UIThemeScript.GOLD.lightened(0.1))
		title_box.add_child(title)
		var sub := Label.new()
		sub.text = "固定地图 · 每关一个任务 · 全 %d 关" % CampaignDataScript.playable_levels().size()
		UIThemeScript.apply_label(sub, UILayout.font_dp(8.0), Color(UIThemeScript.STONE).lightened(0.35))
		title_box.add_child(sub)
		_progress_label = Label.new()
		_progress_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		UIThemeScript.apply_label(_progress_label, UILayout.font_dp(8.0), UIThemeScript.PARCHMENT)
		box.add_child(_progress_label)
		return box

	var header := HBoxContainer.new()
	header.name = "Header"
	header.custom_minimum_size = Vector2(0, 118)
	header.add_theme_constant_override("separation", 22)
	header.add_child(_make_back_button())

	var title_box := VBoxContainer.new()
	title_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_box.alignment = BoxContainer.ALIGNMENT_CENTER
	title_box.add_theme_constant_override("separation", 2)
	header.add_child(title_box)

	var title := Label.new()
	title.text = "⚔ 帝国远征"
	UIThemeScript.apply_label(title, 50, UIThemeScript.GOLD.lightened(0.1))
	title_box.add_child(title)

	var sub := Label.new()
	sub.text = "固定地图 · 每关一个任务 · 全 %d 关" % CampaignDataScript.playable_levels().size()
	UIThemeScript.apply_label(sub, 19, Color(UIThemeScript.STONE).lightened(0.35))
	title_box.add_child(sub)

	var right := VBoxContainer.new()
	right.name = "HeaderRight"
	right.alignment = BoxContainer.ALIGNMENT_CENTER
	right.add_theme_constant_override("separation", 8)
	header.add_child(right)

	_progress_label = Label.new()
	_progress_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	UIThemeScript.apply_label(_progress_label, 21, UIThemeScript.PARCHMENT)
	right.add_child(_progress_label)

	if _mode_check != null:
		right.add_child(_mode_check)
	return header

func _make_back_button() -> Button:
	var back := Button.new()
	back.name = "BackButton"
	back.text = "← 返回"
	back.custom_minimum_size = Vector2(UILayout.dp(78.0) if _mobile else 210, UILayout.dp(32.0) if _mobile else 56)
	if _mobile:
		UIThemeScript.apply_muted_button(back, UILayout.font_dp(9.0))
	else:
		UIThemeScript.apply_muted_button(back, UIThemeScript.FONT_MD)
	back.pressed.connect(_on_back_pressed)
	return back


func _make_free_banner() -> Control:
	var panel := PanelContainer.new()
	panel.name = "FreeTrialBanner"
	panel.custom_minimum_size = Vector2(0, UILayout.dp(50.0) if _mobile else 76)
	panel.add_theme_stylebox_override("panel", UIThemeScript.card_style(UIThemeScript.GOLD))
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", UILayout.dp(10.0) if _mobile else 22)
	margin.add_theme_constant_override("margin_right", UILayout.dp(10.0) if _mobile else 22)
	margin.add_theme_constant_override("margin_top", UILayout.dp(5.0) if _mobile else 10)
	margin.add_theme_constant_override("margin_bottom", UILayout.dp(5.0) if _mobile else 10)
	panel.add_child(margin)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UILayout.dp(8.0) if _mobile else 18)
	margin.add_child(row)

	var icon := Label.new()
	icon.text = "🎁"
	UIThemeScript.apply_label(icon, UILayout.font_dp(18.0) if _mobile else 34, UIThemeScript.GOLD)
	row.add_child(icon)

	_free_banner = Label.new()
	_free_banner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_free_banner.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_free_banner.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UIThemeScript.apply_label(_free_banner, UILayout.font_dp(9.0) if _mobile else 21,
		UIThemeScript.GOLD)
	row.add_child(_free_banner)
	return panel

func _update_free_banner() -> void:
	if _free_banner == null:
		return
	var left := CampaignProgressScript.free_unlock_remaining()
	if left > 0:
		_free_banner.text = "全关卡体验期 · %d 关全部开放 ｜ 剩余 %s" % [
			CampaignDataScript.playable_levels().size(), CampaignProgressScript.free_unlock_text()]
		_free_banner.add_theme_color_override("font_color", UIThemeScript.GOLD.lightened(0.12))
		return
	_free_banner.text = "全关卡体验期已结束 · 关卡按通关进度解锁"
	_free_banner.add_theme_color_override("font_color", Color(UIThemeScript.STONE).lightened(0.35))
	if not _free_expiry_rebuilt:
		_free_expiry_rebuilt = true
		_rebuild_levels()

func _refresh_progress() -> void:
	if _progress_label == null:
		return
	var levels: Array = CampaignDataScript.playable_levels()
	var total := levels.size()
	var cleared := 0
	for lv in levels:
		if CampaignProgressScript.is_cleared(String(lv.get("id", ""))):
			cleared += 1
	var stars := CampaignProgressScript.total_stars()
	_progress_label.text = "通关 %d / %d ｜ ★ %d / %d" % [cleared, total, stars, total * 3]

func _populate_levels() -> void:
	if _level_area == null:
		return
	for chapter in CampaignDataScript.all_chapters():
		var section := VBoxContainer.new()
		section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		section.add_theme_constant_override("separation", UILayout.dp(5.0) if _mobile else 10)

		var head := VBoxContainer.new()
		head.add_theme_constant_override("separation", 1)
		section.add_child(head)

		var chapter_title := Label.new()
		chapter_title.text = String(chapter.get("name", ""))
		UIThemeScript.apply_label(chapter_title, UILayout.font_dp(12.0) if _mobile else 30,
			UIThemeScript.GOLD)
		head.add_child(chapter_title)

		var chapter_desc := Label.new()
		chapter_desc.text = String(chapter.get("desc", ""))
		chapter_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		UIThemeScript.apply_label(chapter_desc, UILayout.font_dp(8.0) if _mobile else 17,
			Color(UIThemeScript.STONE).lightened(0.3))
		head.add_child(chapter_desc)

		var grid := GridContainer.new()
		grid.columns = 2 if _mobile else 4
		grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_theme_constant_override("h_separation", UILayout.dp(6.0) if _mobile else 16)
		grid.add_theme_constant_override("v_separation", UILayout.dp(6.0) if _mobile else 16)
		section.add_child(grid)

		var has_level := false
		for lv in CampaignDataScript.playable_levels():
			if int(lv.get("chapter", 0)) != int(chapter.get("id", 0)):
				continue
			has_level = true
			grid.add_child(_make_level_card(lv))
		if not has_level:
			var coming := Label.new()
			coming.text = "本章正在开发中。"
			UIThemeScript.apply_label(coming, UILayout.font_dp(9.0) if _mobile else UIThemeScript.FONT_SM,
				Color(UIThemeScript.STONE).lightened(0.2))
			section.add_child(coming)
		_level_area.add_child(section)

func _rebuild_levels() -> void:
	if _level_area == null:
		return
	for child in _level_area.get_children():
		_level_area.remove_child(child)
		child.queue_free()
	_populate_levels()
	_refresh_progress()

func _make_level_card(level: Dictionary) -> Control:
	var level_id := String(level.get("id", ""))
	var unlocked := CampaignProgressScript.is_unlocked(level_id)
	var stars := CampaignProgressScript.best_stars(level_id)
	var cleared := CampaignProgressScript.is_cleared(level_id)
	var free_active := CampaignProgressScript.is_free_unlock_active()
	var accent: Color = UIThemeScript.GOLD if unlocked else UIThemeScript.STONE
	var card := Button.new()
	card.name = "Level_" + level_id
	card.text = ""
	card.custom_minimum_size = Vector2(0, UILayout.dp(170.0) if _mobile else 320)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	card.disabled = not unlocked
	card.focus_mode = Control.FOCUS_NONE
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if unlocked else Control.CURSOR_ARROW
	card.tooltip_text = "进入关卡查看简报" if unlocked else "通关上一关后解锁"
	card.add_theme_stylebox_override("normal", _card_style(accent, unlocked))
	card.add_theme_stylebox_override("hover", _card_style(UIThemeScript.GOLD, true, true))
	card.add_theme_stylebox_override("pressed", _card_style(UIThemeScript.GOLD, true, true, true))
	card.add_theme_stylebox_override("disabled", _card_style(UIThemeScript.STONE, false))
	card.pressed.connect(_open_brief.bind(level))

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", UILayout.dp(8.0) if _mobile else 22)
	margin.add_theme_constant_override("margin_right", UILayout.dp(8.0) if _mobile else 22)
	margin.add_theme_constant_override("margin_top", UILayout.dp(6.0) if _mobile else 16)
	margin.add_theme_constant_override("margin_bottom", UILayout.dp(6.0) if _mobile else 16)
	card.add_child(margin)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", UILayout.dp(2.0) if _mobile else 6)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(vb)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 4)
	vb.add_child(top)

	var badge := Label.new()
	var chapter := int(level.get("chapter", 1))
	var index := int(level.get("index", 1))
	if chapter == 5:
		badge.text = "挑战 %d" % (index - 100)
	else:
		badge.text = "第 %d 关" % index
	badge.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UIThemeScript.apply_label(badge, UILayout.font_dp(9.0) if _mobile else 18,
		accent if unlocked else Color(UIThemeScript.STONE).lightened(0.2))
	top.add_child(badge)

	var star_label := Label.new()
	if stars > 0:
		star_label.text = "★".repeat(stars) + "☆".repeat(3 - stars)
	else:
		star_label.text = "☆☆☆" if not (free_active and unlocked) else "🎁 体验"
	UIThemeScript.apply_label(star_label, UILayout.font_dp(9.0) if _mobile else 19,
		UIThemeScript.GOLD if stars > 0 else Color(UIThemeScript.STONE).lightened(0.2))
	top.add_child(star_label)

	var title := Label.new()
	title.text = String(level.get("name", ""))
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UIThemeScript.apply_label(title, UILayout.font_dp(12.0) if _mobile else 30,
		UIThemeScript.PARCHMENT if unlocked else Color(UIThemeScript.STONE).lightened(0.15))
	vb.add_child(title)

	var sub := Label.new()
	sub.text = String(level.get("subtitle", ""))
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UIThemeScript.apply_label(sub, UILayout.font_dp(8.0) if _mobile else 16,
		Color(UIThemeScript.PARCHMENT, 0.82) if unlocked else Color(UIThemeScript.STONE).lightened(0.15))
	vb.add_child(sub)

	var objective := Label.new()
	objective.text = _card_objective(level)
	objective.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	objective.size_flags_vertical = Control.SIZE_EXPAND_FILL
	UIThemeScript.apply_label(objective, UILayout.font_dp(8.0) if _mobile else 15,
		Color(UIThemeScript.PARCHMENT, 0.7) if unlocked else Color(UIThemeScript.STONE).lightened(0.2))
	vb.add_child(objective)

	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 4)
	vb.add_child(foot)

	var status := Label.new()
	status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if not unlocked:
		status.text = "🔒 未解锁"
	elif cleared:
		status.text = "最佳 ★%d" % stars
	elif free_active:
		status.text = "🎁 体验期开放"
	else:
		status.text = "任务待完成"
	UIThemeScript.apply_label(status, UILayout.font_dp(8.0) if _mobile else 16,
		Color(UIThemeScript.STONE).lightened(0.3) if not unlocked else (UIThemeScript.GOLD if free_active else UIThemeScript.PARCHMENT))
	foot.add_child(status)

	if unlocked:
		var go := Label.new()
		go.text = "进入 ▸" if not cleared else "再战 ▸"
		go.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		UIThemeScript.apply_label(go, UILayout.font_dp(9.0) if _mobile else 18,
			UIThemeScript.GOLD)
		foot.add_child(go)
	return card

func _card_objective(level: Dictionary) -> String:
	var labels: Array = []
	for o in level.get("objectives", []):
		labels.append(str(o.get("label", "")))
	var text := "；".join(labels)
	var limit := float(level.get("time_limit", 0.0))
	if limit > 0.0:
		text += " · 限时 %d 分钟" % int(limit / 60.0)
	return text

func _card_style(accent: Color, unlocked: bool, hover: bool = false, pressed: bool = false) -> StyleBoxFlat:
	var s := UIThemeScript.panel_style(UIThemeScript.RADIUS_MD, UIThemeScript.BORDER_MED, 0.96)
	s.bg_color = Color(0.105, 0.09, 0.075, 0.97) if unlocked else Color(0.075, 0.07, 0.065, 0.95)
	if hover:
		s.bg_color = Color(0.16, 0.13, 0.09, 0.98)
	if pressed:
		s.bg_color = Color(0.2, 0.16, 0.1, 0.99)
	s.border_color = Color(accent, 0.9 if (hover or pressed) else (0.55 if unlocked else 0.25))
	s.set_border_width_all(UIThemeScript.BORDER_MED if unlocked else UIThemeScript.BORDER_THIN)
	s.set_corner_radius_all(UIThemeScript.RADIUS_MD)
	s.shadow_size = 8 if unlocked else 3
	s.shadow_color = Color(0, 0, 0, 0.45)
	s.shadow_offset = Vector2(2, 3)
	return s

func _make_mode_check() -> CheckBox:
	var cb := CheckBox.new()
	cb.name = "CampaignResearchCheck"
	cb.text = "科研模式（四时代科技树）"
	cb.button_pressed = GameSettings.is_research_mode()
	cb.tooltip_text = "开启后，本关使用四时代与科技树发展；关闭则沿用经典主城升级模式。新手教程仍固定经典模式。"
	cb.add_theme_font_size_override("font_size", UILayout.font_dp(9.0) if _mobile else UIThemeScript.FONT_MD)
	cb.add_theme_color_override("font_color", UIThemeScript.PARCHMENT)
	cb.add_theme_color_override("font_hover_color", UIThemeScript.GOLD)
	cb.add_theme_color_override("icon_normal_color", UIThemeScript.GOLD)
	cb.toggled.connect(_on_mode_toggled)
	if _mobile:
		cb.custom_minimum_size = Vector2(0, UILayout.dp(30.0))
		cb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	else:
		cb.custom_minimum_size = Vector2(0, 32)
		cb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return cb

func _on_mode_toggled(on: bool) -> void:
	GameSettings.progression_mode = GameSettings.ProgressionMode.RESEARCH if on else GameSettings.ProgressionMode.CLASSIC

# 关卡简报弹窗：完整背景故事 + 3 条提示 + 开始
func _open_brief(level: Dictionary) -> void:
	var level_id := String(level.get("id", ""))
	if not CampaignProgressScript.is_unlocked(level_id):
		return
	if _dialog_layer != null and is_instance_valid(_dialog_layer):
		_dialog_layer.queue_free()
	_dialog_layer = Control.new()
	_dialog_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_dialog_layer)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.66)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_dialog_layer.add_child(dim)

	var card_w: float = UILayout.dp(520.0) if _mobile else 760.0
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", UIThemeScript.card_style(UIThemeScript.GOLD))
	card.custom_minimum_size = Vector2(card_w, 0.0)
	card.anchor_left = 0.5
	card.anchor_right = 0.5
	card.anchor_top = 0.5
	card.anchor_bottom = 0.5
	card.offset_left = -card_w * 0.5
	card.offset_right = card_w * 0.5
	card.grow_horizontal = Control.GROW_DIRECTION_BOTH
	card.grow_vertical = Control.GROW_DIRECTION_BOTH
	_dialog_layer.add_child(card)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", UILayout.dp(14.0) if _mobile else 26)
	margin.add_theme_constant_override("margin_right", UILayout.dp(14.0) if _mobile else 26)
	margin.add_theme_constant_override("margin_top", UILayout.dp(12.0) if _mobile else 22)
	margin.add_theme_constant_override("margin_bottom", UILayout.dp(12.0) if _mobile else 22)
	card.add_child(margin)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	margin.add_child(vb)

	var title := Label.new()
	title.text = CampaignDataScript.display_name(level)
	UIThemeScript.apply_label(title, UILayout.font_dp(15.0) if _mobile else UIThemeScript.FONT_XXL,
		UIThemeScript.GOLD)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)

	var brief := Label.new()
	brief.text = String(level.get("brief", ""))
	brief.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UIThemeScript.apply_label(brief, UILayout.font_dp(10.0) if _mobile else UIThemeScript.FONT_MD,
		UIThemeScript.PARCHMENT)
	vb.add_child(brief)

	var sep := HSeparator.new()
	vb.add_child(sep)

	for tip in level.get("tips", []):
		var line := Label.new()
		line.text = "· " + str(tip)
		line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		UIThemeScript.apply_label(line, UILayout.font_dp(9.0) if _mobile else UIThemeScript.FONT_SM,
			Color(UIThemeScript.PARCHMENT, 0.88))
		vb.add_child(line)

	# 目标与时限
	var goal := Label.new()
	goal.text = "目标：" + _objective_text(level)
	goal.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UIThemeScript.apply_label(goal, UILayout.font_dp(10.0) if _mobile else UIThemeScript.FONT_MD,
		UIThemeScript.EMERALD)
	vb.add_child(goal)

	var mode_line := Label.new()
	mode_line.text = "发展模式：" + ("科研模式（四时代科技树）" if GameSettings.is_research_mode() else "经典模式（主城升级）")
	mode_line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UIThemeScript.apply_label(mode_line, UILayout.font_dp(9.0) if _mobile else UIThemeScript.FONT_SM,
		Color(UIThemeScript.GOLD, 0.92))
	vb.add_child(mode_line)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	vb.add_child(row)
	var start := Button.new()
	start.text = "开始任务"
	if _mobile:
		start.custom_minimum_size = Vector2(UILayout.dp(140.0), UILayout.dp(40.0))
		UIThemeScript.apply_primary_button(start, UILayout.font_dp(11.0))
	else:
		start.custom_minimum_size = Vector2(170.0, 46.0)
		UIThemeScript.apply_primary_button(start, UIThemeScript.FONT_LG)
	start.pressed.connect(_start_level.bind(level))
	row.add_child(start)
	var cancel := Button.new()
	cancel.text = "取消"
	if _mobile:
		cancel.custom_minimum_size = Vector2(UILayout.dp(100.0), UILayout.dp(40.0))
		UIThemeScript.apply_button(cancel, UILayout.font_dp(11.0))
	else:
		cancel.custom_minimum_size = Vector2(120.0, 46.0)
		UIThemeScript.apply_button(cancel, UIThemeScript.FONT_LG)
	cancel.pressed.connect(func() -> void:
		if _dialog_layer != null and is_instance_valid(_dialog_layer):
			_dialog_layer.queue_free()
			_dialog_layer = null)
	row.add_child(cancel)
	UIThemeScript.fade_in(_dialog_layer, 0.18)

func _objective_text(level: Dictionary) -> String:
	var labels: Array = []
	for o in level.get("objectives", []):
		labels.append(str(o.get("label", "")))
	var text := "；".join(labels)
	var limit := float(level.get("time_limit", 0.0))
	if limit > 0.0:
		text += "（限时 %d 分钟" % int(limit / 60.0)
		var three := float(level.get("stars", {}).get("three", 0.0))
		if three > 0.0:
			text += " · %d 分钟内通关 3★" % int(three / 60.0)
		text += "）"
	return text

func _start_level(level: Dictionary) -> void:
	var level_id := String(level.get("id", ""))
	if not CampaignProgressScript.is_unlocked(level_id):
		return
	GameSettings.campaign_mode = true
	GameSettings.campaign_level_id = level_id
	GameSettings.tutorial_mode = false
	if _mode_check != null and is_instance_valid(_mode_check):
		GameSettings.progression_mode = GameSettings.ProgressionMode.RESEARCH if _mode_check.button_pressed else GameSettings.ProgressionMode.CLASSIC
	GameSettings.is_ffa = false
	GameSettings.ai_mode = 1
	GameSettings.map_id = String(level.get("map_id", "classic"))
	GameSettings.map_seed = int(level.get("map_seed", 0))
	var player_cfg: Dictionary = level.get("player", {})
	var enemy_cfg: Dictionary = level.get("enemy", {})
	GameSettings.player_nation = int(player_cfg.get("nation", GameSettings.player_nation))
	GameSettings.enemy_nation = int(enemy_cfg.get("nation", GameSettings.enemy_nation))
	GameSettings.ai_difficulty = int(enemy_cfg.get("ai_difficulty", GameSettings.AIDifficulty.EASY))
	GameSettings.fast_mode = false
	LoadingScreen.goto_scene("res://scenes/rts_battle.tscn")

func _on_back_pressed() -> void:
	GameSettings.campaign_mode = false
	GameSettings.campaign_level_id = ""
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")

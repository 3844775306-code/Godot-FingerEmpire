extends Control

# 闯关模式选关界面：章节 + 关卡卡片 + 星级进度 + 关卡简报。
# 全部 UI 在代码里搭，方便跟着 UILayout 适配手机端。

const CampaignDataScript = preload("res://scripts/data/CampaignData.gd")
const CampaignProgressScript = preload("res://scripts/core/CampaignProgress.gd")
const UIThemeScript = preload("res://scripts/ui/UITheme.gd")

var _mobile := false
var _vb: VBoxContainer = null
var _dialog_layer: Control = null

func _ready() -> void:
	# 触屏滑动误点守卫：选关卡片列表滑动后不误进关卡
	add_child(TouchDragGuard.new())
	_mobile = InputSource.use_mobile_ui()
	if _mobile:
		# 横竖屏切换后重建选关卡片，避免竖屏下仍按横屏的列宽排版。
		add_child(OrientationReload.new())
	GameSettings.campaign_mode = true
	AudioManager.play_music("menu")
	_build()

func _build() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.055, 0.048, 0.043)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var title := Label.new()
	title.text = "⚔ 帝国远征"
	UIThemeScript.apply_label(title, UILayout.font_dp(24.0) if _mobile else 40, UIThemeScript.GOLD)
	title.position = Vector2(UILayout.dp(16.0) if _mobile else 48.0, UILayout.dp(10.0) if _mobile else 24.0)
	add_child(title)

	var sub := Label.new()
	sub.text = "闯关模式 · 固定地图 · 每关一个任务"
	UIThemeScript.apply_label(sub, UILayout.font_dp(9.0) if _mobile else UIThemeScript.FONT_SM,
		Color(UIThemeScript.STONE).lightened(0.35))
	sub.position = Vector2(UILayout.dp(16.0) if _mobile else 50.0,
		(UILayout.dp(40.0) if _mobile else 76.0))
	add_child(sub)

	# 星级与通关进度
	var total_levels: int = CampaignDataScript.playable_levels().size()
	var cleared := 0
	for lv in CampaignDataScript.playable_levels():
		if CampaignProgressScript.is_cleared(String(lv.get("id", ""))):
			cleared += 1
	var star_total: int = CampaignProgressScript.total_stars()
	var progress := Label.new()
	progress.text = "通关 %d / %d ｜ 累计 ★ %d / %d" % [cleared, total_levels, star_total, total_levels * 3]
	UIThemeScript.apply_label(progress, UILayout.font_dp(10.0) if _mobile else UIThemeScript.FONT_MD,
		UIThemeScript.PARCHMENT)
	progress.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	progress.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	progress.offset_left = -(UILayout.dp(220.0) if _mobile else 420.0)
	progress.offset_right = -(UILayout.dp(16.0) if _mobile else 48.0)
	progress.offset_top = UILayout.dp(14.0) if _mobile else 36.0
	progress.offset_bottom = progress.offset_top + 30.0
	add_child(progress)

	# 关卡列表（可滚动）
	var scroll := ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.offset_left = UILayout.dp(10.0) if _mobile else 48.0
	scroll.offset_right = -(UILayout.dp(10.0) if _mobile else 48.0)
	scroll.offset_top = UILayout.dp(62.0) if _mobile else 120.0
	scroll.offset_bottom = -(UILayout.dp(58.0) if _mobile else 96.0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	_vb = VBoxContainer.new()
	_vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vb.add_theme_constant_override("separation", 10)
	scroll.add_child(_vb)

	for chapter in CampaignDataScript.all_chapters():
		_vb.add_child(_make_chapter_header(chapter))
		var has_level := false
		for lv in CampaignDataScript.playable_levels():
			if int(lv.get("chapter", 0)) != int(chapter.get("id", 0)):
				continue
			has_level = true
			_vb.add_child(_make_level_card(lv))
		if not has_level:
			var coming := Label.new()
			coming.text = "　本章正在开发中，先通关第一章吧。"
			UIThemeScript.apply_label(coming, UILayout.font_dp(9.0) if _mobile else UIThemeScript.FONT_SM,
				Color(UIThemeScript.STONE).lightened(0.2))
			_vb.add_child(coming)

	# 返回主菜单
	var back := Button.new()
	back.text = "← 返回主菜单"
	if _mobile:
		back.custom_minimum_size = Vector2(UILayout.dp(160.0), UILayout.dp(40.0))
		UIThemeScript.apply_button(back, UILayout.font_dp(11.0))
		back.position = Vector2(UILayout.dp(12.0), size.y - UILayout.dp(50.0))
		back.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
		back.offset_left = UILayout.dp(12.0)
		back.offset_bottom = -UILayout.dp(10.0)
		back.offset_top = -UILayout.dp(50.0)
		back.offset_right = UILayout.dp(172.0)
	else:
		back.custom_minimum_size = Vector2(180.0, 46.0)
		UIThemeScript.apply_button(back, UIThemeScript.FONT_MD)
		back.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
		back.offset_left = 48.0
		back.offset_top = -78.0
		back.offset_right = 228.0
		back.offset_bottom = -30.0
	back.pressed.connect(_on_back_pressed)
	add_child(back)

func _make_chapter_header(chapter: Dictionary) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	var title := Label.new()
	title.text = String(chapter.get("name", ""))
	UIThemeScript.apply_label(title, UILayout.font_dp(13.0) if _mobile else UIThemeScript.FONT_XL,
		UIThemeScript.GOLD)
	box.add_child(title)
	var desc := Label.new()
	desc.text = String(chapter.get("desc", ""))
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UIThemeScript.apply_label(desc, UILayout.font_dp(8.0) if _mobile else UIThemeScript.FONT_SM,
		Color(UIThemeScript.STONE).lightened(0.3))
	box.add_child(desc)
	return box

func _make_level_card(level: Dictionary) -> Control:
	var level_id := String(level.get("id", ""))
	var unlocked: bool = CampaignProgressScript.is_unlocked(level_id)
	var stars: int = CampaignProgressScript.best_stars(level_id)
	var accent: Color = UIThemeScript.GOLD if unlocked else UIThemeScript.STONE
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", UIThemeScript.card_style(accent))
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	card.add_child(vb)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	vb.add_child(head)

	var name_label := Label.new()
	name_label.text = CampaignDataScript.display_name(level)
	UIThemeScript.apply_label(name_label, UILayout.font_dp(12.0) if _mobile else UIThemeScript.FONT_XL,
		UIThemeScript.PARCHMENT if unlocked else Color(UIThemeScript.STONE).lightened(0.2))
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(name_label)

	var star_label := Label.new()
	star_label.text = ("★".repeat(stars) + "☆".repeat(3 - stars)) if stars > 0 else "☆☆☆"
	UIThemeScript.apply_label(star_label, UILayout.font_dp(12.0) if _mobile else UIThemeScript.FONT_LG,
		UIThemeScript.GOLD if stars > 0 else Color(UIThemeScript.STONE).lightened(0.1))
	head.add_child(star_label)

	var sub := Label.new()
	sub.text = String(level.get("subtitle", ""))
	UIThemeScript.apply_label(sub, UILayout.font_dp(9.0) if _mobile else UIThemeScript.FONT_SM,
		Color(UIThemeScript.PARCHMENT, 0.85))
	vb.add_child(sub)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	vb.add_child(row)

	if unlocked:
		var go := Button.new()
		go.text = "进入关卡" if stars <= 0 else "再次挑战"
		if _mobile:
			go.custom_minimum_size = Vector2(UILayout.dp(110.0), UILayout.dp(34.0))
			UIThemeScript.apply_primary_button(go, UILayout.font_dp(10.0))
		else:
			go.custom_minimum_size = Vector2(130.0, 38.0)
			UIThemeScript.apply_primary_button(go, UIThemeScript.FONT_MD)
		go.pressed.connect(_open_brief.bind(level))
		row.add_child(go)
	else:
		var lock := Label.new()
		lock.text = "🔒 通关上一关后解锁"
		UIThemeScript.apply_label(lock, UILayout.font_dp(9.0) if _mobile else UIThemeScript.FONT_SM,
			Color(UIThemeScript.STONE).lightened(0.3))
		row.add_child(lock)
	return card

# 关卡简报弹窗：完整背景故事 + 3 条提示 + 开始
func _open_brief(level: Dictionary) -> void:
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

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	card.add_child(vb)

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
		text += "（限时 %d 分钟）" % int(limit / 60.0)
	return text

func _start_level(level: Dictionary) -> void:
	GameSettings.campaign_mode = true
	GameSettings.campaign_level_id = String(level.get("id", ""))
	GameSettings.tutorial_mode = false
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
	get_tree().change_scene_to_file("res://scenes/rts_battle.tscn")

func _on_back_pressed() -> void:
	GameSettings.campaign_mode = false
	GameSettings.campaign_level_id = ""
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")

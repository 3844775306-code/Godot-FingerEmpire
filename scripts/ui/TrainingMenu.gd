extends Control

# 新兵训练营选关界面。
# 四个页签：基础训练 / 进阶训练 / 实战演习 / 国家档案。
# 训练进度独立保存在 user://training_progress.json，不影响闯关模式。

const TrainingDataScript = preload("res://scripts/data/TrainingData.gd")
const TrainingProgressScript = preload("res://scripts/core/TrainingProgress.gd")

var _tab := 0
var _content: VBoxContainer
var _progress_label: Label
var _detail: Control = null
var _nation_pick: OptionButton = null
var _selected_nation := 0

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_background()
	_build_header()
	_build_tabs()
	_content = VBoxContainer.new()
	_content.add_theme_constant_override("separation", 12)
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var scroll := ScrollContainer.new()
	scroll.position = Vector2(0, 158)
	scroll.size = Vector2(size.x, maxf(size.y - 158.0, 100.0))
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	add_child(scroll)
	scroll.add_child(_content)
	_refresh()
	# 调试/自动化：godot ... res://scenes/training_menu.tscn -- --training=t01
	if OS.is_debug_build():
		for a in OS.get_cmdline_user_args():
			if a.begins_with("--training="):
				get_tree().process_frame.connect(_debug_start.bind(a.substr(11)), CONNECT_ONE_SHOT)
				return
			if a.begins_with("--detail="):
				get_tree().process_frame.connect(_debug_detail.bind(a.substr(9)), CONNECT_ONE_SHOT)

func _debug_detail(tid: String) -> void:
	for lv in TrainingDataScript.playable_levels():
		if String(lv.get("id", "")) == tid:
			_open_detail(lv)
			return

func _debug_start(tid: String) -> void:
	for lv in TrainingDataScript.playable_levels():
		if String(lv.get("id", "")) == tid:
			_start_level(lv)
			return

func _build_background() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.035, 0.045, 0.06)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var top := ColorRect.new()
	top.color = Color(0.12, 0.09, 0.04)
	top.position = Vector2.ZERO
	top.size = Vector2(size.x, 152)
	add_child(top)

func _build_header() -> void:
	var title := Label.new()
	title.text = "🎓 新兵训练营"
	title.position = Vector2(28, 18)
	title.size = Vector2(size.x - 56, 44)
	UITheme.apply_label(title, 34, UITheme.GOLD)
	add_child(title)
	var sub := Label.new()
	sub.text = "仅经典模式 · 固定维京 · 每关两个新概念 · 挑战关只考已学内容"
	sub.position = Vector2(30, 66)
	sub.size = Vector2(size.x - 60, 24)
	UITheme.apply_label(sub, 16, UITheme.PARCHMENT)
	add_child(sub)
	_progress_label = Label.new()
	_progress_label.position = Vector2(30, 98)
	_progress_label.size = Vector2(size.x - 260, 24)
	UITheme.apply_label(_progress_label, 15, UITheme.GOLD)
	add_child(_progress_label)
	var back := Button.new()
	back.text = "‹ 返回主菜单"
	back.position = Vector2(size.x - 190, 22)
	back.size = Vector2(160, 42)
	UITheme.apply_button(back, 15)
	back.pressed.connect(_on_back)
	add_child(back)
	var reset := Button.new()
	reset.text = "重置进度"
	reset.position = Vector2(size.x - 190, 74)
	reset.size = Vector2(160, 36)
	UITheme.apply_muted_button(reset, 13)
	reset.pressed.connect(_on_reset)
	add_child(reset)

func _build_tabs() -> void:
	var hb := HBoxContainer.new()
	hb.position = Vector2(28, 126)
	hb.size = Vector2(size.x - 56, 30)
	hb.add_theme_constant_override("separation", 8)
	add_child(hb)
	var names := ["基础训练", "进阶训练", "实战演习", "国家档案"]
	for i in range(names.size()):
		var b := Button.new()
		b.text = names[i]
		b.custom_minimum_size = Vector2(118, 30)
		if i == _tab:
			UITheme.apply_primary_button(b, 15)
		else:
			UITheme.apply_button(b, 15)
		b.pressed.connect(_on_tab.bind(i))
		hb.add_child(b)

func _on_tab(i: int) -> void:
	_tab = i
	# 重建整个界面最简单可靠：页签按钮状态和内容同时刷新。
	for c in get_children():
		if c is HBoxContainer or c is ScrollContainer:
			c.queue_free()
	_build_tabs()
	_content = VBoxContainer.new()
	_content.add_theme_constant_override("separation", 12)
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var scroll := ScrollContainer.new()
	scroll.position = Vector2(0, 158)
	scroll.size = Vector2(size.x, maxf(size.y - 158.0, 100.0))
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	add_child(scroll)
	scroll.add_child(_content)
	_refresh()

func _refresh() -> void:
	if _progress_label:
		_progress_label.text = "主线 %d/%d · 高难 %d/1 · 国家体验 %d/10" % [
			TrainingProgressScript.cleared_main_count(), TrainingDataScript.main_total(),
			TrainingProgressScript.cleared_optional_count(), TrainingProgressScript.nation_seen_count()]
	if _content == null:
		return
	for c in _content.get_children():
		c.queue_free()
	match _tab:
		0:
			_add_section("基础篇 · 第 1-15 关", 1, 15)
		1:
			_add_section("进阶篇 · 第 16-24 关", 16, 24)
		2:
			_add_section("实战演习 · 第 25-26 关", 25, 26)
		3:
			_add_nation_archive()

func _add_section(title_text: String, from_index: int, to_index: int) -> void:
	var header := Label.new()
	header.text = title_text
	header.custom_minimum_size = Vector2(size.x - 56, 34)
	UITheme.apply_label(header, 20, UITheme.GOLD)
	_content.add_child(header)
	var grid := GridContainer.new()
	grid.columns = 2 if InputSource.use_mobile_ui() else 3
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 12)
	_content.add_child(grid)
	for lv in TrainingDataScript.playable_levels():
		var idx := int(lv.get("index", 0))
		if idx < from_index or idx > to_index:
			continue
		grid.add_child(_make_level_card(lv))

func _make_level_card(lv: Dictionary) -> Control:
	var mobile := InputSource.use_mobile_ui()
	var w: float = (size.x - 80.0) / 2.0 if mobile else (size.x - 100.0) / 3.0
	var h: float = 134.0 if mobile else 146.0
	var id := String(lv.get("id", ""))
	var unlocked := TrainingProgressScript.is_unlocked(id)
	var cleared := TrainingProgressScript.is_cleared(id)
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(w, h)
	card.add_theme_stylebox_override("panel", UITheme.card_style(
		UITheme.GOLD if cleared else (UITheme.STONE if not unlocked else UITheme.PARCHMENT)))
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	card.gui_input.connect(_on_card_input.bind(lv))
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 3)
	vb.add_theme_constant_override("margin_left", 10)
	vb.add_theme_constant_override("margin_right", 8)
	vb.add_theme_constant_override("margin_top", 8)
	vb.add_theme_constant_override("margin_bottom", 8)
	card.add_child(vb)
	var title := Label.new()
	var status := "✅" if cleared else ("🔒" if not unlocked else "▸")
	title.text = "%s %02d  %s" % [status, int(lv.get("index", 0)), String(lv.get("name", ""))]
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.apply_label(title, 17 if mobile else 18,
		UITheme.GOLD if not unlocked else UITheme.PARCHMENT)
	vb.add_child(title)
	var type := Label.new()
	type.text = "[%s]  %s" % [String(lv.get("type_label", "")), _concept_names(lv)]
	type.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.apply_label(type, 13 if mobile else 14, UITheme.GOLD.lightened(0.15))
	vb.add_child(type)
	var extra := Label.new()
	if not unlocked:
		extra.text = "通关上一关后解锁"
	elif String(lv.get("multi_mode", "")) != "":
		extra.text = "团队目标：摧毁两座敌方主城"
	elif cleared:
		extra.text = "最好成绩：%s" % _fmt_time(TrainingProgressScript.best_time(id))
	else:
		extra.text = "点击查看两个新概念"
	extra.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.apply_label(extra, 11 if mobile else 12, UITheme.PARCHMENT.darkened(0.2))
	vb.add_child(extra)
	return card

func _concept_names(lv: Dictionary) -> String:
	var concepts: Array = lv.get("concepts", [])
	if concepts.is_empty():
		return "无新概念 · 综合挑战"
	var parts: Array = []
	for c in concepts:
		parts.append(String(c.get("icon", "•")) + String(c.get("name", "")))
	return " / ".join(parts)

func _on_card_input(event: InputEvent, lv: Dictionary) -> void:
	var pressed := false
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		pressed = true
	if event is InputEventScreenTouch and event.pressed:
		pressed = true
	if pressed:
		_open_detail(lv)

func _open_detail(lv: Dictionary) -> void:
	var id := String(lv.get("id", ""))
	var unlocked := TrainingProgressScript.is_unlocked(id)
	var mobile := InputSource.use_mobile_ui()
	if _detail != null and is_instance_valid(_detail):
		_detail.queue_free()
	_detail = Control.new()
	_detail.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_detail.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_detail)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.7)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_detail.add_child(dim)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UITheme.card_style(UITheme.GOLD))
	panel.custom_minimum_size = Vector2(UILayout.dp(520.0) if mobile else 700.0, 0.0)
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -(UILayout.dp(260.0) if mobile else 350.0)
	panel.offset_right = (UILayout.dp(260.0) if mobile else 350.0)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_detail.add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	vb.add_theme_constant_override("margin_left", 24)
	vb.add_theme_constant_override("margin_right", 24)
	vb.add_theme_constant_override("margin_top", 18)
	vb.add_theme_constant_override("margin_bottom", 18)
	panel.add_child(vb)
	var title := Label.new()
	title.text = "%s %s" % [String(lv.get("type_label", "")), String(lv.get("name", ""))]
	UITheme.apply_label(title, UILayout.font_dp(20.0) if mobile else 26, UITheme.GOLD)
	vb.add_child(title)
	var sub := Label.new()
	sub.text = "%s · 仅经典模式" % _map_name(String(lv.get("map_id", "")))
	UITheme.apply_label(sub, UILayout.font_dp(10.0) if mobile else 14, UITheme.PARCHMENT)
	vb.add_child(sub)
	var brief := Label.new()
	brief.text = String(lv.get("brief", ""))
	brief.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.apply_label(brief, UILayout.font_dp(10.0) if mobile else 15, UITheme.PARCHMENT)
	vb.add_child(brief)
	var concepts: Array = lv.get("concepts", [])
	for c in concepts:
		var line := Label.new()
		line.text = "%s %s\n%s" % [String(c.get("icon", "•")), String(c.get("name", "")),
			String(c.get("desc", ""))]
		line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		UITheme.apply_label(line, UILayout.font_dp(9.0) if mobile else 14, UITheme.GOLD.lightened(0.15))
		vb.add_child(line)
	if String(lv.get("id", "")) == "t24":
		var pick_label := Label.new()
		pick_label.text = "选择国家："
		UITheme.apply_label(pick_label, UILayout.font_dp(10.0) if mobile else 15, UITheme.PARCHMENT)
		vb.add_child(pick_label)
		_nation_pick = OptionButton.new()
		_nation_pick.custom_minimum_size = Vector2(0, 36)
		for n in TrainingDataScript.nation_options():
			_nation_pick.add_item("%s · %s" % [String(n.get("name", "")), String(n.get("unit_name", ""))],
				int(n.get("id", 0)))
		_nation_pick.selected = clampi(_selected_nation, 0, 9)
		vb.add_child(_nation_pick)
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 10)
	vb.add_child(buttons)
	var close_btn := Button.new()
	close_btn.text = "关闭"
	close_btn.custom_minimum_size = Vector2(UILayout.dp(100.0) if mobile else 120, 40)
	UITheme.apply_button(close_btn, UILayout.font_dp(10.0) if mobile else 15)
	close_btn.pressed.connect(func(): _detail.queue_free())
	buttons.add_child(close_btn)
	var start_btn := Button.new()
	start_btn.text = "开始训练 ▸" if unlocked else "尚未解锁"
	start_btn.disabled = not unlocked
	start_btn.custom_minimum_size = Vector2(UILayout.dp(140.0) if mobile else 180, 40)
	UITheme.apply_primary_button(start_btn, UILayout.font_dp(10.0) if mobile else 15)
	start_btn.pressed.connect(_start_level.bind(lv))
	buttons.add_child(start_btn)

func _start_level(lv: Dictionary) -> void:
	var id := String(lv.get("id", ""))
	if not TrainingProgressScript.is_unlocked(id):
		return
	var nation := RTSConfig.Nation.VIKING
	if String(lv.get("id", "")) == "t24" and _nation_pick != null:
		nation = int(_nation_pick.get_selected_id())
	_selected_nation = nation
	GameSettings.training_prev_progression = GameSettings.progression_mode
	GameSettings.training_mode = true
	GameSettings.campaign_mode = true
	GameSettings.training_level_id = id
	GameSettings.training_nation = nation
	GameSettings.tutorial_mode = false
	GameSettings.is_ffa = false
	GameSettings.progression_mode = GameSettings.ProgressionMode.CLASSIC
	GameSettings.player_nation = nation if id == "t24" else RTSConfig.Nation.VIKING
	var enemy_cfg: Dictionary = lv.get("enemy", {})
	GameSettings.enemy_nation = int(enemy_cfg.get("nation", RTSConfig.Nation.ENGLAND))
	GameSettings.ai_difficulty = GameSettings.AIDifficulty.EASY
	GameSettings.ai_mode = 2 if String(lv.get("multi_mode", "")) != "" else 1
	GameSettings.map_id = String(lv.get("map_id", "classic"))
	GameSettings.map_seed = int(lv.get("map_seed", 0))
	LoadingScreen.goto_scene("res://scenes/rts_battle.tscn")

func _add_nation_archive() -> void:
	var intro := Label.new()
	intro.text = "10 个国家的全局加成与特色兵种。通关基础篇后开放；第 24 关可以亲手体验。"
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.custom_minimum_size = Vector2(size.x - 56, 28)
	UITheme.apply_label(intro, 15, UITheme.PARCHMENT)
	_content.add_child(intro)
	var grid := GridContainer.new()
	grid.columns = 2 if InputSource.use_mobile_ui() else 3
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 12)
	_content.add_child(grid)
	for n in TrainingDataScript.nation_options():
		var card := PanelContainer.new()
		var mobile := InputSource.use_mobile_ui()
		var w: float = (size.x - 80.0) / 2.0 if mobile else (size.x - 100.0) / 3.0
		card.custom_minimum_size = Vector2(w, 138.0)
		card.add_theme_stylebox_override("panel", UITheme.card_style(UITheme.STONE))
		var vb := VBoxContainer.new()
		vb.add_theme_constant_override("separation", 4)
		vb.add_theme_constant_override("margin_left", 10)
		vb.add_theme_constant_override("margin_right", 8)
		vb.add_theme_constant_override("margin_top", 8)
		vb.add_theme_constant_override("margin_bottom", 8)
		card.add_child(vb)
		var name_label := Label.new()
		name_label.text = "👑 %s" % String(n.get("name", ""))
		UITheme.apply_label(name_label, 18, UITheme.GOLD)
		vb.add_child(name_label)
		var unit := Label.new()
		unit.text = "特色兵：%s" % String(n.get("unit_name", ""))
		UITheme.apply_label(unit, 14, UITheme.PARCHMENT)
		vb.add_child(unit)
		var bonus := Label.new()
		bonus.text = String(n.get("bonus", ""))
		bonus.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		UITheme.apply_label(bonus, 12, UITheme.PARCHMENT.darkened(0.15))
		vb.add_child(bonus)
		if TrainingProgressScript.nation_seen(int(n.get("id", 0))):
			var seen := Label.new()
			seen.text = "✅ 已体验"
			UITheme.apply_label(seen, 11, UITheme.EMERALD)
			vb.add_child(seen)
		grid.add_child(card)

func _map_name(map_id: String) -> String:
	return {
		"classic": "经典大陆", "ridge": "白垩山脊", "forest": "黑森林",
		"desert": "沙漠", "strait": "海峡", "coast": "海岸",
		"marsh": "沼泽", "bridge": "桥头", "crater": "火山口",
	}.get(map_id, map_id)

func _fmt_time(seconds: float) -> String:
	if seconds <= 0.0:
		return "—"
	var s := int(seconds)
	return "%02d:%02d" % [s / 60, s % 60]

func _on_back() -> void:
	GameSettings.training_mode = false
	GameSettings.training_level_id = ""
	GameSettings.campaign_mode = false
	GameSettings.progression_mode = GameSettings.training_prev_progression
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")

func _on_reset() -> void:
	var dlg := ConfirmationDialog.new()
	dlg.title = "重置训练进度"
	dlg.dialog_text = "确定清空全部训练营进度？闯关模式进度不受影响。"
	dlg.confirmed.connect(func():
		TrainingProgressScript.reset_all()
		_refresh())
	add_child(dlg)
	dlg.popup_centered()

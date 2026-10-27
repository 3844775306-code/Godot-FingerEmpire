extends Control

# 主菜单「科技总览」弹层：只读展示四时代、56 项通用科技与每国 3 项国家科技。
# 不依赖对局状态，因此主菜单、战役选关、联机大厅都可以直接查看完整的科研路线。

const TechTreeDataScript = preload("res://scripts/data/TechTreeData.gd")

const FILTER_ALL := "ALL"
const FILTER_NATION := "NATION"

var _mobile := false
var _filter := FILTER_ALL
var _content: VBoxContainer = null
var _filter_buttons: Dictionary = {}
var _scroll: ScrollContainer = null

func _ready() -> void:
	_mobile = InputSource.use_mobile_ui()
	add_to_group("mobile_modal_ui")
	size = UILayout.view_size() if _mobile else Vector2(UILayout.DESIGN_W, UILayout.DESIGN_H)
	position = Vector2.ZERO
	mouse_filter = Control.MOUSE_FILTER_STOP
	z_index = 300
	_build()
	UITheme.fade_in(self, 0.18)

func _build() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.74)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	dim.gui_input.connect(_on_dim_input)
	add_child(dim)

	var card := Panel.new()
	card.add_theme_stylebox_override("panel", UITheme.card_style(UITheme.GOLD))
	if _mobile:
		card.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		card.offset_left = UILayout.dp(4.0)
		card.offset_top = UILayout.dp(4.0)
		card.offset_right = -UILayout.dp(4.0)
		card.offset_bottom = -UILayout.dp(4.0)
	else:
		card.position = Vector2(120, 50)
		card.size = Vector2(2160, 1300)
	add_child(card)

	var margin := MarginContainer.new()
	var pad: int = int(UILayout.dp(7.0)) if _mobile else 30
	margin.add_theme_constant_override("margin_left", pad)
	margin.add_theme_constant_override("margin_right", pad)
	margin.add_theme_constant_override("margin_top", pad)
	margin.add_theme_constant_override("margin_bottom", pad)
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	card.add_child(margin)

	var root := VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_theme_constant_override("separation", int(UILayout.dp(6.0)) if _mobile else 12)
	margin.add_child(root)

	var header := HBoxContainer.new()
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(header)

	var title := UITheme.make_section_title("📜 科技总览", UITheme.GOLD,
		UILayout.font_dp(17.0) if _mobile else 38)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)

	var close := Button.new()
	close.text = "✕"
	close.custom_minimum_size = Vector2(UILayout.dp(34.0) if _mobile else 48.0,
		UILayout.dp(30.0) if _mobile else 42.0)
	close.focus_mode = Control.FOCUS_NONE
	UITheme.apply_muted_button(close, UILayout.font_dp(12.0) if _mobile else 20)
	close.pressed.connect(_close)
	header.add_child(close)

	var subtitle := Label.new()
	subtitle.text = "四时代 · 56 项通用科技 · 每国 3 项国家科技 · 与经典模式并行"
	subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.apply_label(subtitle, UILayout.font_dp(8.5) if _mobile else 18,
		Color(UITheme.PARCHMENT, 0.82))
	root.add_child(subtitle)

	var mode_text := "当前主菜单默认：科研模式" if GameSettings.is_research_mode() else "当前主菜单默认：经典模式"
	mode_text += "　｜　科研模式可在单人、联机、乱斗与战役中使用；新手教程固定经典模式。"
	var mode_label := Label.new()
	mode_label.text = mode_text
	mode_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.apply_label(mode_label, UILayout.font_dp(8.0) if _mobile else 16,
		Color(UITheme.GOLD, 0.9))
	root.add_child(mode_label)

	root.add_child(_make_age_strip())

	root.add_child(_make_filter_bar())

	_scroll = ScrollContainer.new()
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	root.add_child(_scroll)

	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", int(UILayout.dp(8.0)) if _mobile else 18)
	_scroll.add_child(_content)

	_rebuild_content()

func _make_age_strip() -> GridContainer:
	var grid := GridContainer.new()
	grid.columns = 2 if _mobile else 4
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", int(UILayout.dp(5.0)) if _mobile else 12)
	grid.add_theme_constant_override("v_separation", int(UILayout.dp(5.0)) if _mobile else 10)
	for i in range(4):
		var age: Dictionary = TechTreeDataScript.get_age(i)
		var panel := PanelContainer.new()
		panel.add_theme_stylebox_override("panel", UITheme.card_style(_age_color(i)))
		panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var vb := VBoxContainer.new()
		vb.add_theme_constant_override("separation", 1)
		panel.add_child(vb)

		var head := Label.new()
		head.text = "%s · %s" % [String(age.get("name", "")), String(age.get("roman", ""))]
		UITheme.apply_label(head, UILayout.font_dp(10.0) if _mobile else 20, _age_color(i))
		vb.add_child(head)

		var info := Label.new()
		var pop := int(age.get("pop", 0))
		var time := int(age.get("time", 0))
		info.text = "人口 %s ｜ 研究 %s ｜ %s" % [
			"—" if pop <= 0 else str(pop),
			"开局" if time <= 0 else "%d 秒" % time,
			_cost_text(age.get("cost", {}), "无成本" if time <= 0 else ""),
		]
		info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		UITheme.apply_label(info, UILayout.font_dp(7.5) if _mobile else 15,
			Color(UITheme.PARCHMENT, 0.8))
		vb.add_child(info)
		grid.add_child(panel)
	return grid

func _make_filter_bar() -> GridContainer:
	var grid := GridContainer.new()
	grid.columns = 3 if _mobile else 6
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", int(UILayout.dp(4.0)) if _mobile else 10)
	grid.add_theme_constant_override("v_separation", int(UILayout.dp(4.0)) if _mobile else 8)

	_add_filter_button(grid, FILTER_ALL, "全部科技")
	for cat in TechTreeDataScript.CATEGORIES:
		var cid := String(cat.get("id", ""))
		_add_filter_button(grid, cid, "%s %s" % [cid, String(cat.get("name", ""))])
	_add_filter_button(grid, FILTER_NATION, "🌍 国家科技")
	return grid

func _add_filter_button(grid: GridContainer, id: String, text: String) -> void:
	var btn := Button.new()
	btn.text = text
	btn.focus_mode = Control.FOCUS_NONE
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.custom_minimum_size = Vector2(0, int(UILayout.dp(32.0)) if _mobile else 40)
	btn.pressed.connect(func() -> void: _set_filter(id))
	grid.add_child(btn)
	_filter_buttons[id] = btn

func _set_filter(id: String) -> void:
	if _filter == id:
		return
	_filter = id
	_update_filter_styles()
	_rebuild_content()
	if _scroll != null:
		_scroll.scroll_vertical = 0

func _update_filter_styles() -> void:
	for id in _filter_buttons:
		var btn: Button = _filter_buttons[id]
		if not is_instance_valid(btn):
			continue
		if String(id) == _filter:
			UITheme.apply_primary_button(btn, UILayout.font_dp(8.0) if _mobile else 16)
		else:
			UITheme.apply_muted_button(btn, UILayout.font_dp(8.0) if _mobile else 16)

func _rebuild_content() -> void:
	if _content == null:
		return
	for child in _content.get_children():
		_content.remove_child(child)
		child.queue_free()
	_update_filter_styles()

	if _filter == FILTER_NATION:
		for nation in range(TechTreeDataScript.NATION_NAMES.size()):
			_add_nation_section(nation)
		return

	if _filter == FILTER_ALL:
		for cat in TechTreeDataScript.CATEGORIES:
			_add_category_section(String(cat.get("id", "")))
		return
	_add_category_section(_filter)

func _add_category_section(cat_id: String) -> void:
	var techs: Array = []
	for t in TechTreeDataScript.all_techs():
		if String(t.get("category", "")) == cat_id:
			techs.append(t)
	if techs.is_empty():
		return
	var cat_name := _category_name(cat_id)
	var header := UITheme.make_section_title("%s · %s  (%d)" % [cat_id, cat_name, techs.size()],
		_age_color(0), UILayout.font_dp(11.0) if _mobile else 24)
	_content.add_child(header)
	_content.add_child(_make_card_grid(techs))

func _add_nation_section(nation: int) -> void:
	var techs: Array = TechTreeDataScript.nation_techs(nation)
	if techs.is_empty():
		return
	var nation_name: String = String(TechTreeDataScript.NATION_NAMES[nation])
	var feature := ""
	var unit_id := int(TechTreeDataScript.NATION_UNIT_ID.get(nation, -1))
	if unit_id >= 0:
		feature = String(EntityDatabase.get_config(unit_id).get("name", ""))
	var header := UITheme.make_section_title(
		"🌍 %s · 特色单位：%s  (%d)" % [nation_name, feature, techs.size()],
		UITheme.GOLD, UILayout.font_dp(11.0) if _mobile else 24)
	_content.add_child(header)
	_content.add_child(_make_card_grid(techs, nation))

func _make_card_grid(techs: Array, nation: int = -1) -> GridContainer:
	var grid := GridContainer.new()
	grid.columns = 1 if _mobile else 3
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", int(UILayout.dp(5.0)) if _mobile else 14)
	grid.add_theme_constant_override("v_separation", int(UILayout.dp(5.0)) if _mobile else 12)
	for t in techs:
		grid.add_child(_make_tech_card(t, nation))
	return grid

func _make_tech_card(t: Dictionary, nation: int = -1) -> PanelContainer:
	var age := int(t.get("age", 0))
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", UITheme.card_style(_age_color(age)))
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 2)
	card.add_child(vb)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	vb.add_child(head)

	var tid := Label.new()
	tid.text = String(t.get("id", ""))
	tid.custom_minimum_size = Vector2(UILayout.dp(31.0) if _mobile else 58, 0)
	UITheme.apply_label(tid, UILayout.font_dp(8.0) if _mobile else 16, _age_color(age))
	head.add_child(tid)

	var name_label := Label.new()
	name_label.text = String(t.get("name", ""))
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.apply_label(name_label, UILayout.font_dp(10.0) if _mobile else 20, UITheme.PARCHMENT)
	head.add_child(name_label)

	var badge := Label.new()
	badge.text = TechTreeDataScript.age_name(age)
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	UITheme.apply_label(badge, UILayout.font_dp(7.0) if _mobile else 14,
		Color(_age_color(age), 0.95))
	head.add_child(badge)

	var effect := Label.new()
	effect.text = String(t.get("effect_text", ""))
	effect.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.apply_label(effect, UILayout.font_dp(8.0) if _mobile else 16, UITheme.PARCHMENT)
	vb.add_child(effect)

	var meta := Label.new()
	meta.text = "前置：%s　｜　成本：%s　｜　时间：%d 秒" % [
		_prereq_text(t.get("prereq", [])),
		_cost_text(t.get("cost", {}), "无"),
		int(t.get("time", 0)),
	]
	meta.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.apply_label(meta, UILayout.font_dp(7.0) if _mobile else 13,
		Color(UITheme.STONE.lightened(0.4)))
	vb.add_child(meta)

	var unlocks := _unlock_text(t.get("unlocks", []))
	if unlocks != "":
		var unlock_label := Label.new()
		unlock_label.text = "解锁：%s" % unlocks
		unlock_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		UITheme.apply_label(unlock_label, UILayout.font_dp(7.0) if _mobile else 13,
			Color(UITheme.EMERALD.lightened(0.2)))
		vb.add_child(unlock_label)

	if nation >= 0:
		var nation_label := Label.new()
		nation_label.text = "国家科技 · %s 专属" % String(TechTreeDataScript.NATION_NAMES[nation])
		UITheme.apply_label(nation_label, UILayout.font_dp(7.0) if _mobile else 13,
			Color(UITheme.GOLD, 0.8))
		vb.add_child(nation_label)
	return card

func _prereq_text(prereq: Array) -> String:
	if prereq.is_empty():
		return "无"
	var parts: Array = []
	for p in prereq:
		parts.append(String(p))
	return " + ".join(parts)

func _cost_text(cost: Dictionary, empty_text: String) -> String:
	var labels := {"food": "粮", "wood": "木", "gold": "金", "stone": "石", "oil": "油"}
	var parts: Array = []
	for key in ["food", "wood", "gold", "stone", "oil"]:
		if cost.has(key) and int(cost[key]) > 0:
			parts.append("%s%d" % [labels[key], int(cost[key])])
	return " · ".join(parts) if not parts.is_empty() else empty_text

func _unlock_text(unlocks: Array) -> String:
	var parts: Array = []
	for uid in unlocks:
		var cfg: Dictionary = EntityDatabase.get_config(int(uid))
		if cfg.is_empty():
			continue
		parts.append(String(cfg.get("name", str(uid))))
	return "、".join(parts)

func _category_name(cat_id: String) -> String:
	for cat in TechTreeDataScript.CATEGORIES:
		if String(cat.get("id", "")) == cat_id:
			return String(cat.get("name", ""))
	return ""

func _age_color(age: int) -> Color:
	match age:
		1: return UITheme.EMERALD
		2: return UITheme.SAPPHIRE
		3: return UITheme.GOLD
		_: return Color(UITheme.STONE.lightened(0.3))

func _on_dim_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_close()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_close()
		get_viewport().set_input_as_handled()

func _close() -> void:
	queue_free()

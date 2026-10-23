class_name StatsOverviewScreen
extends Control

# 全屏统计大屏：一卡一国（玩家 + 全部 AI），右侧挂外交面板。
# 数据直接取 BattleStats 的采样结果（按 owner/team/nation 聚合），不重复实现统计逻辑。

var battle_manager_provider: Callable = Callable()
var hud: Node = null

var _dim: ColorRect = null
var _title: Label = null
var _close_btn: Button = null
var _grid: GridContainer = null
var _diplo_host: Control = null
var _diplo_hint: Label = null
var _diplo_panel: Control = null
var _diplo_original_parent: Node = null

func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()

func _build() -> void:
	_dim = ColorRect.new()
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.color = Color(0.02, 0.03, 0.05, 0.94)
	_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_dim)

	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.offset_left = UILayout.dp(14.0)
	root.offset_right = -UILayout.dp(14.0)
	root.offset_top = UILayout.dp(10.0)
	root.offset_bottom = -UILayout.dp(12.0)
	root.add_theme_constant_override("separation", int(UILayout.dp(6.0)))
	add_child(root)

	var header := HBoxContainer.new()
	root.add_child(header)

	_title = Label.new()
	_title.text = "📊 国家统计"
	_title.add_theme_font_size_override("font_size", 20)
	_title.add_theme_color_override("font_color", Color(UITheme.PARCHMENT))
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_title)

	_close_btn = Button.new()
	_close_btn.text = "关闭"
	_close_btn.custom_minimum_size = Vector2(UILayout.dp(64.0), UILayout.dp(32.0))
	UITheme.apply_button(_close_btn, 14)
	_close_btn.pressed.connect(close)
	header.add_child(_close_btn)

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", int(UILayout.dp(8.0)))
	root.add_child(body)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_stretch_ratio = 1.7
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(scroll)

	_grid = GridContainer.new()
	_grid.columns = 2
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.add_theme_constant_override("h_separation", int(UILayout.dp(6.0)))
	_grid.add_theme_constant_override("v_separation", int(UILayout.dp(6.0)))
	scroll.add_child(_grid)

	_diplo_host = Control.new()
	_diplo_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_diplo_host.size_flags_stretch_ratio = 1.0
	body.add_child(_diplo_host)

	_diplo_hint = Label.new()
	_diplo_hint.text = "外交：仅乱斗模式可用"
	_diplo_hint.add_theme_font_size_override("font_size", 13)
	_diplo_hint.add_theme_color_override("font_color", Color(UITheme.PARCHMENT, 0.6))
	_diplo_host.add_child(_diplo_hint)

func open() -> void:
	visible = true
	_refresh()
	_attach_diplo(true)
	move_to_front()

func close() -> void:
	_attach_diplo(false)
	visible = false

func is_point_inside(pos: Vector2) -> bool:
	return visible and get_global_rect().has_point(pos)

func _get_bm() -> Node:
	if battle_manager_provider.is_valid():
		return battle_manager_provider.call()
	return get_tree().get_first_node_in_group("battle_manager")

func _refresh() -> void:
	for child in _grid.get_children():
		child.queue_free()

	var bm := _get_bm()
	var owners: Dictionary = {}
	if bm != null and bm.get("battle_stats") != null:
		var stats = bm.get("battle_stats")
		if stats.samples.is_empty():
			stats.sample_now()
		if not stats.samples.is_empty():
			owners = stats.samples[-1].get("owners", {})

	if owners.is_empty():
		var empty := Label.new()
		empty.text = "暂无统计数据"
		_diplo_host.visible = false
		_grid.add_child(empty)
		return
	_diplo_host.visible = true

	var entries: Array = []
	for key in owners.keys():
		entries.append(owners[key])
	entries.sort_custom(func(a, b):
		if int(a.get("team", 0)) != int(b.get("team", 0)):
			return int(a.get("team", 0)) < int(b.get("team", 0))
		return int(a.get("owner", 0)) < int(b.get("owner", 0)))

	for entry in entries:
		_grid.add_child(_make_card(entry))

func _make_card(entry: Dictionary) -> PanelContainer:
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var style := StyleBoxFlat.new()
	style.bg_color = Color(UITheme.INK, 0.92)
	style.border_color = Color(UITheme.GOLD, 0.3)
	style.set_border_width_all(1)
	style.set_corner_radius_all(int(UILayout.dp(8.0)))
	card.add_theme_stylebox_override("panel", style)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", int(UILayout.dp(2.0)))
	card.add_child(vb)

	var nation := int(entry.get("nation", -1))
	var team := int(entry.get("team", -1))
	var nation_name := "中立"
	if nation >= 0 and nation < BattleStats.NATION_NAMES.size():
		nation_name = BattleStats.NATION_NAMES[nation]
	var team_name := "蓝方" if team == RTSConfig.Team.BLUE else ("红方" if team == RTSConfig.Team.RED else "中立")
	var team_color := Color(0.35, 0.62, 1.0) if team == RTSConfig.Team.BLUE else Color(0.92, 0.35, 0.32)

	var header := HBoxContainer.new()
	vb.add_child(header)

	var dot := ColorRect.new()
	dot.custom_minimum_size = Vector2(UILayout.dp(10.0), UILayout.dp(10.0))
	dot.color = team_color
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header.add_child(dot)

	var title := Label.new()
	var owner := int(entry.get("owner", -1))
	var owner_tag := "玩家" if owner == 0 or owner == 1 else ("AI-%d" % owner)
	title.text = "  %s · %s" % [nation_name, team_name]
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", team_color)
	header.add_child(title)

	var tag := Label.new()
	tag.text = owner_tag
	tag.add_theme_font_size_override("font_size", 11)
	tag.add_theme_color_override("font_color", Color(UITheme.PARCHMENT, 0.6))
	header.add_child(tag)

	var live := Label.new()
	live.text = "🏰%d  ⚔️%d  🪙%d  👁%d" % [
		int(entry.get("buildings", 0)), int(entry.get("army", 0)),
		int(entry.get("resources", 0)), int(entry.get("vision", 0))]
	live.add_theme_font_size_override("font_size", 12)
	vb.add_child(live)

	var accum := Label.new()
	accum.text = "采集 %d · 生产 %d · 歼敌 %d · 伤害 %d" % [
		int(entry.get("gathered", 0)), int(entry.get("produced", 0)),
		int(entry.get("kills", 0)), int(entry.get("damage", 0))]
	accum.add_theme_font_size_override("font_size", 11)
	accum.add_theme_color_override("font_color", Color(UITheme.PARCHMENT, 0.75))
	vb.add_child(accum)
	return card

# 外交面板复用桌面 HUD 的现成节点：打开时临时挂到右栏，关闭时归还原位
func _attach_diplo(on: bool) -> void:
	if hud == null:
		return
	if on:
		var panel = hud.get("_diplo_panel")
		if panel is Control and is_instance_valid(panel):
			_diplo_panel = panel
			_diplo_original_parent = panel.get_parent()
			panel.reparent(_diplo_host)
			panel.visible = true
			panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			_diplo_hint.visible = false
		else:
			_diplo_hint.visible = true
	else:
		if _diplo_panel and is_instance_valid(_diplo_panel) and _diplo_original_parent:
			_diplo_panel.reparent(_diplo_original_parent)
			_diplo_panel.visible = false
		_diplo_panel = null
		_diplo_original_parent = null
		_diplo_hint.visible = true

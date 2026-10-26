class_name ClientBuildMenu
extends Control

const RC = {"wood": "green", "stone": "gray", "gold": "gold", "food": "orange", "oil": "saddlebrown"}
var world_pos: Vector3
signal build_placement_started(building_id: int)

const BUILDING_REQUIRED_CASTLE: Dictionary = {
	23: 2, 25: 2, 26: 2,
	24: 3, 29: 3, 52: 3,
	42: 4, 53: 4, 54: 4
}

func popup_at(p_world_pos: Vector3, screen_pos: Vector2):
	world_pos = p_world_pos
	position = screen_pos
	_refresh_ui()
	_clamp_to_viewport()
	show()

func is_mobile() -> bool:
	return InputSource.use_mobile_ui()

# 手机上菜单以触点为中心弹出，必须夹回屏幕内，否则最右/最下三列会被裁掉。
func _clamp_to_viewport() -> void:
	if not is_mobile():
		return
	var vp := get_viewport().get_visible_rect().size
	var sz := _menu_size
	position.x = clampf(position.x, UILayout.dp(6.0), maxf(UILayout.dp(6.0), vp.x - UILayout.dp(6.0) - sz.x))
	position.y = clampf(position.y, UILayout.dp(6.0), maxf(UILayout.dp(6.0), vp.y - UILayout.dp(6.0) - sz.y))

var _menu_size: Vector2 = Vector2(200, 0)

func _refresh_ui():
	for child in get_children():
		remove_child(child)
		child.queue_free()

	var renderer = get_tree().get_first_node_in_group("client_renderer")
	var pop_current = 0; var pop_max = 0
	var castle_lv = 1
	if renderer and renderer.has_method("get_population"):
		var pd = renderer.get_population()
		pop_current = pd.get("current", 0); pop_max = pd.get("max", 0)
	if renderer and renderer.has_method("get_player_castle_level"):
		castle_lv = renderer.get_player_castle_level()

	var mobile := is_mobile()
	var font: int = UILayout.font_dp(10.0) if mobile else 14
	var rtl_font: int = UILayout.font_dp(9.5) if mobile else 13
	var item_h: float = UILayout.dp(40.0) if mobile else 42.0
	var gap: float = UILayout.dp(4.0) if mobile else 4.0
	var pad: float = UILayout.dp(4.0) if mobile else 10.0
	var cell_w: float = UILayout.dp(196.0) if mobile else 180.0
	var container: Node = null
	var count_buildings := 0

	if mobile:
		# 三列网格：一屏看全，避免竖排 10 多个建筑超出 393dp 屏高。
		var grid := GridContainer.new()
		grid.columns = 3
		grid.position = Vector2(pad, pad)
		grid.add_theme_constant_override("h_separation", int(gap))
		grid.add_theme_constant_override("v_separation", int(gap))
		container = grid
	else:
		var vbox := VBoxContainer.new()
		vbox.position = Vector2(pad, pad)
		vbox.add_theme_constant_override("separation", 4)
		container = vbox

	for cfg in EntityDatabase.configs.values():
		if cfg.type != 1 or cfg.id == 20: continue
		var bid = cfg.id
		count_buildings += 1
		var is_locked = BUILDING_REQUIRED_CASTLE.has(bid) and castle_lv < BUILDING_REQUIRED_CASTLE[bid]

		var btn = Button.new(); btn.text = ""
		var cost = cfg.get("cost", {})
		var affordable = true; var ct = ""
		for res in cost.keys():
			var need = cost[res]
			var have = renderer.get_player_resource(res) if renderer else 0
			if have < need: affordable = false
			var rc = RC.get(res, "#D4C5A9")
			var cc = "#D4C5A9" if have >= need else "#C0392B"
			ct += "[color=%s]%s[/color]:[color=%s]%d[/color] " % [rc, res, cc, need]
		if cfg.id == 25 or cfg.id == 26:
			if pop_current >= pop_max: affordable = false

		UITheme.apply_row_button(btn, UITheme.GOLD)
		btn.disabled = not affordable or is_locked
		btn.modulate = Color(0.55, 0.55, 0.55) if (not affordable or is_locked) else Color.WHITE
		btn.custom_minimum_size = Vector2(cell_w, item_h)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if mobile:
			btn.add_theme_font_size_override("font_size", font)
		var rtl = RichTextLabel.new(); rtl.bbcode_enabled = true; rtl.fit_content = true
		rtl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		rtl.add_theme_color_override("default_color", UITheme.PARCHMENT)
		rtl.add_theme_font_size_override("normal_font_size", rtl_font)
		rtl.anchor_left = 0; rtl.anchor_right = 1; rtl.anchor_top = 0; rtl.anchor_bottom = 1
		if is_locked:
			var req_lv = BUILDING_REQUIRED_CASTLE[bid]
			rtl.text = "%s\n[color=#C0392B]城堡Lv.%d解锁[/color]" % [cfg.name, req_lv]
		else:
			rtl.text = "%s\n%s" % [cfg.name, ct.strip_edges()]
		btn.add_child(rtl)
		if not is_locked:
			btn.pressed.connect(func(): _on_building_selected(cfg.id))
		container.add_child(btn)

	var close_btn = Button.new()
	close_btn.text = "取消"
	UITheme.apply_muted_button(close_btn, UITheme.FONT_MD)
	if mobile:
		close_btn.custom_minimum_size = Vector2(cell_w, item_h)
		close_btn.add_theme_font_size_override("font_size", font)
	else:
		close_btn.custom_minimum_size = Vector2(0, 42)
		close_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	close_btn.pressed.connect(hide)
	container.add_child(close_btn)

	var panel = Panel.new()
	panel.add_theme_stylebox_override("panel", UITheme.card_style(UITheme.GOLD))
	if mobile:
		var rows: int = int(ceil(float(count_buildings + 1) / 3.0))
		_menu_size = Vector2(cell_w * 3.0 + gap * 2.0 + pad * 2.0,
			rows * (item_h + gap) - gap + pad * 2.0)
		panel.size = _menu_size
		custom_minimum_size = _menu_size
		size = _menu_size
	else:
		_menu_size = Vector2(200, (count_buildings + 1) * 48 + 20)
		panel.size = _menu_size
	panel.add_child(container)
	add_child(panel)

func _on_building_selected(building_id: int):
	emit_signal("build_placement_started", building_id)
	hide()

# 手机端触摸转发需要知道菜单实际面板范围（根 Control 尺寸为 0）
func is_point_inside(pos: Vector2) -> bool:
	if not visible:
		return false
	for child in get_children():
		if child is Control and child.visible and child.get_global_rect().has_point(pos):
			return true
	return false

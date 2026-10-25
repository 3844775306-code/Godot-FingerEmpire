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
	show()

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

	var vbox = VBoxContainer.new()
	vbox.position = Vector2(10, 10)
	vbox.add_theme_constant_override("separation", 4)

	for cfg in EntityDatabase.configs.values():
		if cfg.type != 1 or cfg.id == 20: continue
		var bid = cfg.id
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
		btn.custom_minimum_size = Vector2(180, 42)
		btn.add_theme_font_size_override("font_size", 14)
		var rtl = RichTextLabel.new(); rtl.bbcode_enabled = true; rtl.fit_content = true
		rtl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		rtl.add_theme_color_override("default_color", UITheme.PARCHMENT)
		rtl.add_theme_font_size_override("normal_font_size", 13)
		rtl.anchor_left = 0; rtl.anchor_right = 1; rtl.anchor_top = 0; rtl.anchor_bottom = 1
		if is_locked:
			var req_lv = BUILDING_REQUIRED_CASTLE[bid]
			rtl.text = "%s\n[color=#C0392B]城堡Lv.%d解锁[/color]" % [cfg.name, req_lv]
		else:
			rtl.text = "%s\n%s" % [cfg.name, ct.strip_edges()]
		btn.add_child(rtl)
		if not is_locked:
			btn.pressed.connect(func(): _on_building_selected(cfg.id))
		vbox.add_child(btn)

	var close_btn = Button.new()
	close_btn.text = "取消"
	UITheme.apply_muted_button(close_btn, UITheme.FONT_MD)
	close_btn.custom_minimum_size = Vector2(0, 42)
	close_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	close_btn.pressed.connect(hide)
	vbox.add_child(close_btn)

	var panel = Panel.new()
	panel.add_theme_stylebox_override("panel", UITheme.card_style(UITheme.GOLD))
	panel.size = Vector2(200, vbox.get_child_count() * 48 + 20)
	panel.add_child(vbox)
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

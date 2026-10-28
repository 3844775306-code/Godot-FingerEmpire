class_name ClientBuildMenu
extends Control

# 联机客户端的建造菜单：和单机 BuildMenu 同一套图标卡片（3D 缩略图 + 名称 + 成本）。
# 数据来源是 EntityDatabase + ClientRenderer 的本地资源/人口缓存。

signal build_placement_started(building_id: int)

const BuildMenuCardScript = preload("res://scripts/ui/BuildMenuCard.gd")

var world_pos: Vector3

const BUILDING_REQUIRED_CASTLE: Dictionary = {
	23: 2, 25: 2, 26: 2, 64: 2,   # 船坞、箭塔、炮塔、炮台 → 2级
	24: 3, 29: 3, 52: 3,    # 攻城车间、重装武器厂、集市 → 3级
	42: 3, 53: 4, 54: 4     # 书院→3级 城堡→4级
}

const GROUP_ORDER: Array = [21, 24, 29, 25, 26, 27, 41, 64, 22, 28, 52, 42, 54, 53, 23, 7, 8]

var _menu_size: Vector2 = Vector2(300, 200)
var _cards: Array = []
var _clamped := false

func is_mobile() -> bool:
	return InputSource.use_mobile_ui()

func popup_at(p_world_pos: Vector3, screen_pos: Vector2) -> void:
	world_pos = p_world_pos
	_refresh_ui()
	position = screen_pos
	_clamped = false
	set_process(true)
	show()
	_clamp_to_viewport()

# 手机上菜单以触点为中心弹出，必须夹回屏幕内，否则最右/最下会被裁掉
func _clamp_to_viewport() -> void:
	var vp := get_viewport().get_visible_rect().size
	var margin: float = UILayout.dp(6.0) if is_mobile() else 6.0
	position.x = clampf(position.x, margin, maxf(margin, vp.x - _menu_size.x - margin))
	position.y = clampf(position.y, margin, maxf(margin, vp.y - _menu_size.y - margin))

func _process(_delta: float) -> void:
	if _clamped:
		set_process(false)
		return
	_clamped = true
	_clamp_to_viewport()

func _refresh_ui() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_cards.clear()

	var renderer = get_tree().get_first_node_in_group("client_renderer")
	var pop_current := 0
	var pop_max := 0
	var castle_lv := 1
	if renderer and renderer.has_method("get_population"):
		var pd = renderer.get_population()
		pop_current = int(pd.get("current", 0))
		pop_max = int(pd.get("max", 0))
	if renderer and renderer.has_method("get_player_castle_level"):
		castle_lv = int(renderer.get_player_castle_level())

	var mobile := is_mobile()
	var cols: int = 4 if mobile else 3
	var card: Vector2
	var icon: float
	var name_px: int
	var cost_px: int
	var gap: float
	var pad: float
	if mobile:
		card = Vector2(UILayout.dp(88.0), UILayout.dp(70.0))
		icon = UILayout.dp(40.0)
		name_px = UILayout.font_dp(9.0)
		cost_px = UILayout.font_dp(7.5)
		gap = UILayout.dp(4.0)
		pad = UILayout.dp(5.0)
	else:
		card = Vector2(170.0, 158.0)
		icon = 92.0
		name_px = 17
		cost_px = 12
		gap = 8.0
		pad = 8.0

	var by_id: Dictionary = {}
	for cfg in EntityDatabase.configs.values():
		if int(cfg.type) != 1 or int(cfg.id) == 20:
			continue
		by_id[int(cfg.id)] = cfg
	var defs: Array = []
	for bid in GROUP_ORDER:
		if by_id.has(bid):
			defs.append(by_id[bid])
			by_id.erase(bid)
	for cfg in by_id.values():
		defs.append(cfg)

	var cells: int = defs.size() + 1
	var rows: int = int(ceil(float(cells) / float(cols)))
	_menu_size = Vector2(
		cols * card.x + (cols - 1) * gap + pad * 2.0,
		rows * card.y + (rows - 1) * gap + pad * 2.0)
	custom_minimum_size = _menu_size
	size = _menu_size

	var panel := Panel.new()
	panel.add_theme_stylebox_override("panel", UITheme.card_style(UITheme.GOLD))
	panel.size = _menu_size
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(panel)

	var grid := GridContainer.new()
	grid.columns = cols
	grid.position = Vector2(pad, pad)
	grid.add_theme_constant_override("h_separation", int(gap))
	grid.add_theme_constant_override("v_separation", int(gap))
	panel.add_child(grid)

	for i in range(defs.size()):
		var cfg: Dictionary = defs[i]
		var bid := int(cfg.get("id", 0))
		var bd_name := String(cfg.get("name", ""))
		var cost: Dictionary = cfg.get("cost", {})
		var locked: bool = BUILDING_REQUIRED_CASTLE.has(bid) and castle_lv < int(BUILDING_REQUIRED_CASTLE[bid])
		var have: Dictionary = {}
		var affordable := true
		for res in cost.keys():
			var need := int(cost[res])
			var got: int = int(renderer.get_player_resource(res)) if renderer else 0
			have[res] = got
			if got < need:
				affordable = false
		if (bid == 25 or bid == 26) and pop_current >= pop_max:
			affordable = false
		var hotkey: int = i + 1 if (i < 9 and not mobile) else 0
		var lock_text := "城堡 Lv.%d" % int(BUILDING_REQUIRED_CASTLE.get(bid, 1)) if locked else ""
		var card_node := BuildMenuCardScript.new()
		card_node.setup(bid, bd_name, BuildMenuCardScript.cost_bbcode(cost, have), locked, lock_text,
			hotkey, card, icon, name_px, cost_px, 1 if mobile else 2)
		card_node.disabled = locked or not affordable
		var tip := "%s\n%s" % [bd_name, BuildMenuCardScript.cost_plain(cost)]
		if locked:
			tip = "%s\n需要城堡 Lv.%d" % [bd_name, int(BUILDING_REQUIRED_CASTLE.get(bid, 1))]
		elif not affordable:
			tip += "\n资源或人口不足"
		card_node.tooltip_text = tip
		if not locked:
			card_node.pressed.connect(_on_building_selected.bind(bid))
		grid.add_child(card_node)
		_cards.append(card_node)

	var close_btn := Button.new()
	close_btn.text = "取消"
	UITheme.apply_muted_button(close_btn, name_px)
	close_btn.custom_minimum_size = card
	close_btn.size = card
	close_btn.add_theme_font_size_override("font_size", name_px)
	close_btn.pressed.connect(hide)
	grid.add_child(close_btn)

func _input(event: InputEvent) -> void:
	if not visible:
		return
	# 触屏：点面板外面关闭
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if is_mobile() and not _point_inside(event.position):
			hide()
			return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			hide()
			get_viewport().set_input_as_handled()
			return
		if is_mobile():
			return
		var idx := -1
		match event.keycode:
			KEY_1: idx = 0
			KEY_2: idx = 1
			KEY_3: idx = 2
			KEY_4: idx = 3
			KEY_5: idx = 4
			KEY_6: idx = 5
			KEY_7: idx = 6
			KEY_8: idx = 7
			KEY_9: idx = 8
		if idx >= 0 and idx < _cards.size():
			var card = _cards[idx]
			if card != null and is_instance_valid(card) and not card.disabled:
				card.emit_signal("pressed")
				get_viewport().set_input_as_handled()

func _point_inside(pos: Vector2) -> bool:
	for child in get_children():
		if child is Control and child.visible and child.get_global_rect().has_point(pos):
			return true
	return false

func _on_building_selected(building_id: int) -> void:
	emit_signal("build_placement_started", building_id)
	hide()

# 手机端触摸转发需要知道菜单实际面板范围（根 Control 尺寸即面板尺寸）
func is_point_inside(pos: Vector2) -> bool:
	if not visible:
		return false
	return _point_inside(pos)

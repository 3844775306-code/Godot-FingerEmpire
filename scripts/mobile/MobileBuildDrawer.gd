class_name MobileBuildDrawer
extends Control

# 底部中间·建造/生产抽屉。
#   建造页：任何时间都能打开（电脑端本来就不要求先选农民）
#   生产页：选中建筑后可用，内容为该建筑可生产的兵种
# 抽屉展开占半屏，点卡片直接进入放置/入队，收起即退出建造模式。

signal build_requested(building_id: int)
signal produce_requested(building: Node, unit_id: int)

const WIDTH_DP: float = 360.0
const HANDLE_H_DP: float = 34.0
const EXPANDED_H_DP: float = 190.0
const CARD_H_DP: float = 40.0

var battle_manager_provider: Callable = Callable()

var expanded: bool = false
var page: String = "build"          # build / produce

var _panel: Panel = null
var _vbox: VBoxContainer = null
var _tab_row: HBoxContainer = null
var _build_tab: Button = null
var _produce_tab: Button = null
var _scroll: ScrollContainer = null
var _grid: GridContainer = null
var _handle_btn: Button = null
var _selected: Array = []

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()

func _build() -> void:
	_apply_rect()

	_panel = Panel.new()
	_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(UITheme.INK, 0.88)
	style.border_color = Color(UITheme.GOLD, 0.35)
	style.set_border_width_all(1)
	style.set_corner_radius_all(int(UILayout.dp(8.0)))
	_panel.add_theme_stylebox_override("panel", style)
	add_child(_panel)

	_vbox = VBoxContainer.new()
	_vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_vbox.offset_left = UILayout.dp(6.0)
	_vbox.offset_right = -UILayout.dp(6.0)
	_vbox.offset_top = UILayout.dp(4.0)
	_vbox.offset_bottom = -UILayout.dp(4.0)
	_vbox.add_theme_constant_override("separation", int(UILayout.dp(4.0)))
	add_child(_vbox)

	_handle_btn = Button.new()
	_handle_btn.text = "🔨 建造 ▲"
	_handle_btn.custom_minimum_size = Vector2(0.0, UILayout.dp(HANDLE_H_DP))
	UITheme.apply_button(_handle_btn, 14)
	_handle_btn.pressed.connect(_on_handle_pressed)
	_vbox.add_child(_handle_btn)

	_tab_row = HBoxContainer.new()
	_tab_row.add_theme_constant_override("separation", int(UILayout.dp(4.0)))
	_tab_row.visible = false
	_vbox.add_child(_tab_row)

	_build_tab = Button.new()
	_build_tab.text = "建造"
	_build_tab.custom_minimum_size = Vector2(0.0, UILayout.dp(30.0))
	_build_tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.apply_primary_button(_build_tab, 13)
	_build_tab.pressed.connect(func(): _set_page("build"))
	_tab_row.add_child(_build_tab)

	_produce_tab = Button.new()
	_produce_tab.text = "生产"
	_produce_tab.custom_minimum_size = Vector2(0.0, UILayout.dp(30.0))
	_produce_tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.apply_button(_produce_tab, 13)
	_produce_tab.pressed.connect(func(): _set_page("produce"))
	_tab_row.add_child(_produce_tab)

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.visible = false
	_vbox.add_child(_scroll)

	_grid = GridContainer.new()
	_grid.columns = 2
	_grid.add_theme_constant_override("h_separation", int(UILayout.dp(5.0)))
	_grid.add_theme_constant_override("v_separation", int(UILayout.dp(5.0)))
	_scroll.add_child(_grid)

func _apply_rect() -> void:
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 1.0
	anchor_bottom = 1.0
	var insets := UILayout.safe_insets()
	var w := UILayout.dp(WIDTH_DP)
	var h := UILayout.dp(EXPANDED_H_DP if expanded else HANDLE_H_DP)
	var bottom := -(insets.w + UILayout.dp(4.0) + UILayout.dp(48.0))
	offset_left = -w * 0.5
	offset_right = w * 0.5
	offset_top = bottom - h
	offset_bottom = bottom
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	grow_vertical = Control.GROW_DIRECTION_BEGIN

func _on_handle_pressed() -> void:
	expanded = not expanded
	_refresh_layout()
	if not expanded:
		_cancel_build_mode()

func _cancel_build_mode() -> void:
	var bm := _get_bm()
	if bm and bm.get("build_mode") == true:
		bm.set("mobile_keep_build_mode", false)
		if bm.has_method("_exit_build_mode"):
			bm.call("_exit_build_mode")

func _refresh_layout() -> void:
	_tab_row.visible = expanded
	_scroll.visible = expanded
	_handle_btn.text = "🔨 建造 ▼" if expanded else "🔨 建造 ▲"
	_apply_rect()
	if expanded:
		_rebuild_cards()

func _set_page(target: String) -> void:
	page = target
	_rebuild_cards()

# 由 MobileHUD 定时调用
func refresh(selected: Array) -> void:
	_selected = selected
	if expanded and page == "produce":
		_rebuild_cards()
	var has_building := _find_selected_building() != null
	_produce_tab.disabled = not has_building
	if has_building and page == "build" and expanded:
		# 选中建筑时自动切到生产页，避免多一次点按
		page = "produce"
		_rebuild_cards()

func _get_bm() -> Node:
	if battle_manager_provider.is_valid():
		return battle_manager_provider.call()
	return get_tree().get_first_node_in_group("battle_manager")

func _find_selected_building() -> Node:
	for e in _selected:
		if e != null and is_instance_valid(e) and e.get("entity_id") != null:
			if e is Building:
				return e
	return null

func _clear_cards() -> void:
	for child in _grid.get_children():
		child.queue_free()

func _rebuild_cards() -> void:
	_clear_cards()
	if page == "produce":
		_rebuild_produce_cards()
	else:
		_rebuild_build_cards()

func _rebuild_build_cards() -> void:
	var bm := _get_bm()
	if bm == null or bm.get("building_defs") == null:
		return
	var defs: Array = bm.get("building_defs")
	var castle_level := 1
	if bm.has_method("get_player_castle_level"):
		castle_level = bm.call("get_player_castle_level")
	for cfg in defs:
		if cfg is Dictionary == false:
			continue
		var bid := int(cfg.get("id", -1))
		if bid < 0:
			continue
		var unlocked := true
		if bm.has_method("is_building_unlocked"):
			unlocked = bm.call("is_building_unlocked", bid)
		var affordable := true
		if bm.has_method("can_afford_building"):
			affordable = bm.call("can_afford_building", bid, bm.call("get_host_team") if bm.has_method("get_host_team") else 0)
		# 卡片
		var card := _make_card(str(cfg.get("name", "建筑")), cfg.get("cost", {}), unlocked and affordable, not unlocked)
		card.pressed.connect(func(): _on_build_card(bid))
		_grid.add_child(card)

func _rebuild_produce_cards() -> void:
	var building := _find_selected_building()
	if building == null:
		return
	var prods: Array = building.get("production_list") if building.get("production_list") != null else []
	for prod in prods:
		if prod is Dictionary == false:
			continue
		var uid := int(prod.get("unit_id", -1))
		if uid < 0:
			continue
		var cfg := EntityDatabase.get_config(uid)
		if cfg.is_empty():
			continue
		var card := _make_card(str(cfg.get("name", "单位")), cfg.get("cost", {}), true, false)
		card.pressed.connect(func(): _on_produce_card(building, uid))
		_grid.add_child(card)

func _make_card(title: String, cost: Dictionary, enabled: bool, locked: bool) -> Button:
	var card := Button.new()
	card.custom_minimum_size = Vector2(0.0, UILayout.dp(CARD_H_DP))
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.disabled = not enabled
	card.modulate = Color(1, 1, 1, 1.0 if enabled else 0.45)

	var vb := VBoxContainer.new()
	vb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vb.offset_left = UILayout.dp(6.0)
	vb.offset_right = -UILayout.dp(4.0)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_theme_constant_override("separation", 0)
	card.add_child(vb)

	var title_lbl := Label.new()
	title_lbl.text = title + ("  🔒" if locked else "")
	title_lbl.add_theme_font_size_override("font_size", 13)
	title_lbl.add_theme_color_override("font_color", Color(UITheme.PARCHMENT))
	title_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(title_lbl)

	var cost_row := HBoxContainer.new()
	cost_row.add_theme_constant_override("separation", int(UILayout.dp(4.0)))
	cost_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(cost_row)
	for key in ["gold", "wood", "stone", "food", "oil"]:
		var need := int(cost.get(key, 0))
		if need <= 0:
			continue
		var cl := Label.new()
		cl.text = "%s%d" % [String(UITheme.RESOURCE_ICONS.get(key, "◆")), need]
		cl.add_theme_font_size_override("font_size", 10)
		cl.add_theme_color_override("font_color", UITheme.PARCHMENT if _affordable(key, need) else Color(1.0, 0.42, 0.38))
		cl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cost_row.add_child(cl)
	return card

func _affordable(key: String, need: int) -> bool:
	var bm := _get_bm()
	if bm == null:
		return true
	var res: Dictionary = {}
	if bm.get("player_resources") != null:
		res = bm.get("player_resources")
	if bm.has_method("get_host_resources"):
		res = bm.call("get_host_resources")
	return int(res.get(key, 0)) >= need

func _on_build_card(building_id: int) -> void:
	var bm := _get_bm()
	if bm == null:
		return
	bm.set("mobile_keep_build_mode", true)
	if bm.has_method("enter_build_mode"):
		bm.call("enter_build_mode", building_id)
	expanded = false
	_refresh_layout()
	build_requested.emit(building_id)

func _on_produce_card(building: Node, unit_id: int) -> void:
	produce_requested.emit(building, unit_id)

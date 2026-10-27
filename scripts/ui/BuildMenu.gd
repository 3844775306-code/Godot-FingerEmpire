# scripts/ui/BuildMenu.gd
extends Control

# 长按/右键呼出的建造菜单：图标卡片网格（3D 模型缩略图 + 名称 + 成本）。
# 桌面端 3 列 × 6 行、移动端 4 列 × 5 行，都在一屏内看全，不滚动。
# 桌面端支持数字键 1~9 直接选前 9 个建筑，Esc 关闭。

signal building_selected(building_id: int)

const BuildMenuCardScript = preload("res://scripts/ui/BuildMenuCard.gd")

var building_defs: Array = []
var castle_level: int = 1

# 建筑需要的城堡等级
const BUILDING_REQUIRED_CASTLE: Dictionary = {
	23: 2, 25: 2, 26: 2,   # 船坞、箭塔、炮塔 → 2级
	24: 3, 29: 3, 52: 3,    # 攻城车间、重装武器厂、集市 → 3级
	42: 3, 53: 4, 54: 4     # 书院→3级 城堡→4级
}

# 展示顺序：军事 → 防御 → 经济 → 特殊。按用途分组，比按 id 顺序好找。
const GROUP_ORDER: Array = [21, 24, 29, 25, 26, 27, 41, 64, 22, 28, 52, 42, 54, 53, 23, 7, 8]

var _menu_size: Vector2 = Vector2(300, 200)
var _cards: Array = []
var _clamped := false

func is_mobile() -> bool:
	return InputSource.use_mobile_ui()

# 供弹出逻辑取尺寸做居中与夹边
func get_menu_size() -> Vector2:
	return _menu_size

func _ready() -> void:
	var bm = get_tree().get_first_node_in_group("battle_manager")
	var mobile := is_mobile()
	var cols: int = 4 if mobile else 3
	var card: Vector2
	var icon: float
	var name_px: int
	var cost_px: int
	var gap: float
	var pad: float
	if mobile:
		# 触屏屏高约 393dp：4 列 × 5 行刚好一屏，不需要滑动
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

	var defs := _ordered_defs()
	var cells: int = defs.size() + 1  # +「取消」
	var rows: int = int(ceil(float(cells) / float(cols)))
	_menu_size = Vector2(
		cols * card.x + (cols - 1) * gap + pad * 2.0,
		rows * card.y + (rows - 1) * gap + pad * 2.0)

	# 皇庭卡片底：暖黑 + 金边
	var bg := Panel.new()
	bg.add_theme_stylebox_override("panel", UITheme.card_style(UITheme.GOLD))
	bg.size = _menu_size
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var grid := GridContainer.new()
	grid.columns = cols
	grid.position = Vector2(pad, pad)
	grid.add_theme_constant_override("h_separation", int(gap))
	grid.add_theme_constant_override("v_separation", int(gap))
	add_child(grid)

	var have: Dictionary = {}
	if bm != null:
		if bm.has_method("get_host_resources"):
			have = bm.get_host_resources()
		elif "player_resources" in bm:
			have = bm.player_resources

	for i in range(defs.size()):
		var bd: Dictionary = defs[i]
		var bid := int(bd.get("id", 0))
		var bd_name := String(bd.get("name", ""))
		var cost: Dictionary = bd.get("cost", {})
		var locked: bool = BUILDING_REQUIRED_CASTLE.has(bid) and castle_level < int(BUILDING_REQUIRED_CASTLE[bid])
		var affordable := true
		for res in cost.keys():
			if int(have.get(res, 0)) < int(cost[res]):
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
			tip += "\n资源不足"
		card_node.tooltip_text = tip
		if not locked:
			card_node.pressed.connect(_on_building_pressed.bind(bid))
		grid.add_child(card_node)
		_cards.append(card_node)

	var close_btn := Button.new()
	close_btn.text = "取消"
	UITheme.apply_muted_button(close_btn, name_px)
	close_btn.custom_minimum_size = card
	close_btn.size = card
	close_btn.add_theme_font_size_override("font_size", name_px)
	close_btn.pressed.connect(queue_free)
	grid.add_child(close_btn)

	custom_minimum_size = _menu_size
	size = _menu_size
	set_process(true)

# 按用途排序，只保留当前真正能造的建筑（building_defs 由战斗管理器提供）
func _ordered_defs() -> Array:
	var by_id: Dictionary = {}
	for bd in building_defs:
		by_id[int(bd.get("id", -1))] = bd
	var out: Array = []
	for bid in GROUP_ORDER:
		if by_id.has(bid):
			out.append(by_id[bid])
			by_id.erase(bid)
	for bd in by_id.values():
		out.append(bd)
	return out

# 弹窗位置可能在加进场景后才设置，这里统一夹回视口，避免右侧/底部超出屏幕
func _process(_delta: float) -> void:
	if _clamped:
		set_process(false)
		return
	_clamped = true
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var margin: float = UILayout.dp(8.0) if is_mobile() else 8.0
	position.x = clampf(position.x, margin, maxf(margin, vp.x - _menu_size.x - margin))
	position.y = clampf(position.y, margin, maxf(margin, vp.y - _menu_size.y - margin))

func _input(event: InputEvent) -> void:
	# 触屏：点菜单外面即关闭（合成鼠标事件会经过这里）
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if is_mobile() and not get_global_rect().has_point(event.position):
			queue_free()
			return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			queue_free()
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

func _on_building_pressed(id: int) -> void:
	emit_signal("building_selected", id)
	queue_free()

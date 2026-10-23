# scripts/ui/BuildMenu.gd
extends Control

# 长按/右键呼出的建造菜单。
# 桌面端尺寸保持原样；移动端整体放大（dp 换算），并在弹出时夹在视口内。

signal building_selected(building_id: int)

var building_defs: Array = []
var castle_level: int = 1
const RC = {"wood": "green", "stone": "gray", "gold": "gold", "food": "orange", "oil": "saddlebrown"}

# 移动端尺寸（dp）
const MENU_W_DP: float = 250.0
const ITEM_H_DP: float = 42.0
const PAD_DP: float = 6.0

# 建筑需要的城堡等级
const BUILDING_REQUIRED_CASTLE: Dictionary = {
	23: 2, 25: 2, 26: 2,   # 船坞、箭塔、炮塔 → 2级
	24: 3, 29: 3, 52: 3,    # 攻城车间、重装武器厂、集市 → 3级
	42: 3, 53: 4, 54: 4             # 书院→3级 城堡→4级
}

var _menu_size: Vector2 = Vector2(165, 40)

func is_mobile() -> bool:
	return InputSource.use_mobile_ui()

# 供弹出逻辑取尺寸做居中与夹边
func get_menu_size() -> Vector2:
	return _menu_size

func _ready():
	var bm = get_tree().get_first_node_in_group("battle_manager")
	var mobile := is_mobile()
	var item_h: float = UILayout.dp(ITEM_H_DP) if mobile else 38.0
	var gap: float = UILayout.dp(5.0) if mobile else 4.0
	var font: int = UILayout.font_dp(11.0) if mobile else 13
	var pad: float = UILayout.dp(PAD_DP) if mobile else 8.0
	var menu_w: float = UILayout.dp(MENU_W_DP) if mobile else 165.0

	# Background panel
	var bg = Panel.new()
	var bs = StyleBoxFlat.new()
	bs.bg_color = Color(0.06, 0.07, 0.13, 0.93)
	bs.corner_radius_top_left = 6; bs.corner_radius_top_right = 6
	bs.corner_radius_bottom_left = 6; bs.corner_radius_bottom_right = 6
	bs.border_width_left = 1; bs.border_width_right = 1
	bs.border_width_top = 1; bs.border_width_bottom = 1
	bs.border_color = Color(0.25, 0.5, 0.8, 0.5)
	bg.add_theme_stylebox_override("panel", bs)
	add_child(bg)

	var vbox = VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", int(gap))
	var container: Node = vbox
	var cell_w: float = menu_w - pad * 2.0
	if mobile:
		# 触屏屏高只有约 393dp，竖排列表必须滑动，滑动手感差；
		# 直接摊成 3 列网格，一屏看全，不需要滑动。
		var cols := 3
		var vp: Vector2 = get_viewport().get_visible_rect().size
		var avail_w: float = vp.x - UILayout.dp(16.0)
		cell_w = UILayout.dp(196.0)
		menu_w = cols * cell_w + (cols - 1) * gap + pad * 2.0
		if menu_w > avail_w:
			cell_w = (avail_w - pad * 2.0 - (cols - 1) * gap) / float(cols)
			menu_w = cols * cell_w + (cols - 1) * gap + pad * 2.0
		var grid := GridContainer.new()
		grid.columns = cols
		grid.position = Vector2(pad, pad)
		grid.add_theme_constant_override("h_separation", int(gap))
		grid.add_theme_constant_override("v_separation", int(gap))
		add_child(grid)
		container = grid
		var rows: int = int(ceil(float(building_defs.size() + 1) / float(cols)))
		_menu_size = Vector2(menu_w, rows * (item_h + gap) - gap + pad * 2.0)
	else:
		vbox.position = Vector2(pad, pad)
		add_child(vbox)

	for bd in building_defs:
		var bid = bd.id
		var is_locked = BUILDING_REQUIRED_CASTLE.has(bid) and castle_level < BUILDING_REQUIRED_CASTLE[bid]

		var btn = Button.new(); btn.text = ""
		var cost = bd.get("cost", {})
		var affordable = true; var ct = ""
		for res in ["wood", "stone", "gold", "food", "oil"]:
			if cost.get(res, 0) > 0:
				var need = cost[res]
				var res_dict = bm.player_resources
				if bm and bm.has_method("get_host_resources"):
					res_dict = bm.get_host_resources()
				var have = res_dict.get(res, 0)
				if have < need: affordable = false
				var rc = RC.get(res, "white")
				var cc = "white" if have >= need else "red"
				ct += "[color=%s]%s[/color]:[color=%s]%d[/color] " % [rc, res, cc, need]

		btn.disabled = not affordable or is_locked
		if mobile:
			btn.custom_minimum_size = Vector2(cell_w, item_h)
		else:
			btn.custom_minimum_size = Vector2(150, 38)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.add_theme_font_size_override("font_size", font)
		var rtl = RichTextLabel.new(); rtl.bbcode_enabled = true; rtl.fit_content = true
		rtl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		rtl.anchor_left = 0; rtl.anchor_right = 1; rtl.anchor_top = 0; rtl.anchor_bottom = 1
		# 移动端字号必须用 normal_font_size，只设 font_size 对 RichTextLabel 无效
		if mobile:
			rtl.add_theme_font_size_override("normal_font_size", font)
			rtl.add_theme_font_size_override("bold_font_size", font)

		if is_locked:
			var req_lv = BUILDING_REQUIRED_CASTLE[bid]
			rtl.text = "%s\n[color=red]城堡Lv.%d解锁[/color]" % [bd.name, req_lv]
		else:
			rtl.text = "%s\n%s" % [bd.name, ct.strip_edges()]

		btn.add_child(rtl)
		if not is_locked:
			btn.pressed.connect(_on_building_pressed.bind(bd.id))
		container.add_child(btn)

	var cancel_h: float = item_h
	var close_btn = Button.new()
	close_btn.text = "取消"
	if mobile:
		close_btn.custom_minimum_size = Vector2(cell_w, cancel_h)
	else:
		close_btn.custom_minimum_size = Vector2(0, cancel_h)
		close_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	close_btn.add_theme_font_size_override("font_size", font)
	close_btn.pressed.connect(queue_free)
	container.add_child(close_btn)

	if mobile:
		bg.size = _menu_size
		custom_minimum_size = _menu_size
		size = _menu_size
	else:
		_menu_size = Vector2(165, 20 + building_defs.size() * 45)
		bg.size = _menu_size
		size = _menu_size

# 触屏：点菜单外面即关闭（合成鼠标事件会经过这里）
func _input(event: InputEvent) -> void:
	if not is_mobile():
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if not get_global_rect().has_point(event.position):
			queue_free()

func _on_building_pressed(id: int):
	emit_signal("building_selected", id)
	queue_free()

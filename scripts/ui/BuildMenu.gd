# scripts/ui/BuildMenu.gd
extends Control

signal building_selected(building_id: int)

var building_defs: Array = []
var castle_level: int = 1
const RC = {"wood": "green", "stone": "gray", "gold": "gold", "food": "orange", "oil": "saddlebrown"}

# 建筑需要的城堡等级
const BUILDING_REQUIRED_CASTLE: Dictionary = {
	23: 2, 25: 2, 26: 2,   # 船坞、箭塔、炮塔 → 2级
	24: 3, 29: 3, 52: 3,    # 攻城车间、重装武器厂、集市 → 3级
	42: 4, 53: 4             # 书院/城堡 → 4级
}

func _ready():
	var bm = get_tree().get_first_node_in_group("battle_manager")
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
	vbox.position = Vector2(8, 8)
	vbox.add_theme_constant_override("separation", 4)
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
				var have = bm.player_resources[res] if bm else 0
				if have < need: affordable = false
				var rc = RC.get(res, "white")
				var cc = "white" if have >= need else "red"
				ct += "[color=%s]%s[/color]:[color=%s]%d[/color] " % [rc, res, cc, need]

		btn.disabled = not affordable or is_locked
		btn.custom_minimum_size = Vector2(150, 38)
		btn.add_theme_font_size_override("font_size", 13)
		var rtl = RichTextLabel.new(); rtl.bbcode_enabled = true; rtl.fit_content = true
		rtl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		rtl.anchor_left = 0; rtl.anchor_right = 1; rtl.anchor_top = 0; rtl.anchor_bottom = 1

		if is_locked:
			var req_lv = BUILDING_REQUIRED_CASTLE[bid]
			rtl.text = "%s\n[color=red]城堡Lv.%d解锁[/color]" % [bd.name, req_lv]
		else:
			rtl.text = "%s\n%s" % [bd.name, ct.strip_edges()]

		btn.add_child(rtl)
		if not is_locked:
			btn.pressed.connect(_on_building_pressed.bind(bd.id))
		vbox.add_child(btn)

	var close_btn = Button.new()
	close_btn.text = "Cancel"; close_btn.add_theme_font_size_override("font_size", 13)
	close_btn.pressed.connect(queue_free)
	vbox.add_child(close_btn)

	bg.size = Vector2(165, 20 + building_defs.size() * 45)

func _on_building_pressed(id: int):
	emit_signal("building_selected", id)
	queue_free()

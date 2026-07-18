class_name ClientInfoPanel
extends Panel

@onready var upgrade_btn = $VBox/UpgradeBtn
@onready var produce_vbox = $VBox/ProduceVBox
@onready var close_btn = $CloseBtn

var name_rtl: RichTextLabel
var stats_rtl: RichTextLabel
var hp_bar: ColorRect
var observed_entity_id: int = -1
var renderer: ClientRenderer = null
var demolish_btn: Button = null
var resources: Dictionary = {}
var limits: Dictionary = {}
var population: Dictionary = {}

const RC = {"wood": "green", "stone": "gray", "gold": "gold", "food": "orange", "oil": "saddlebrown"}

func _ready():
	visible = false
	var s = StyleBoxFlat.new()
	s.bg_color = Color(0.06, 0.07, 0.13, 0.93)
	s.corner_radius_top_left = 8; s.corner_radius_top_right = 8
	s.corner_radius_bottom_left = 8; s.corner_radius_bottom_right = 8
	s.border_width_left = 2; s.border_width_right = 2
	s.border_width_top = 2; s.border_width_bottom = 2
	s.border_color = Color(0.25, 0.5, 0.8, 0.6)
	add_theme_stylebox_override("panel", s)
	custom_minimum_size = Vector2(200, 0)

	_swap_rtl("NameLabel"); _swap_rtl("StatsLabel")
	name_rtl = $VBox.get_node("NameLabel")
	stats_rtl = $VBox.get_node("StatsLabel")

	hp_bar = ColorRect.new(); hp_bar.name = "HPBar"
	hp_bar.custom_minimum_size = Vector2(1, 14); hp_bar.color = Color.GREEN
	var vb = $VBox; vb.add_child(hp_bar); vb.move_child(hp_bar, 1)
	close_btn.pressed.connect(_on_close_pressed)

	# 拆除按钮
	demolish_btn = Button.new()
	demolish_btn.name = "DemolishBtn"
	demolish_btn.text = "拆除建筑"
	demolish_btn.add_theme_font_size_override("font_size", 13)
	demolish_btn.custom_minimum_size = Vector2(180, 32)
	demolish_btn.add_theme_color_override("font_color", Color.RED)
	demolish_btn.visible = false
	demolish_btn.pressed.connect(_on_demolish_pressed)
	$VBox.add_child(demolish_btn)

	set_process(true)
	renderer = get_tree().get_first_node_in_group("client_renderer")

func _swap_rtl(nm: String):
	var old = $VBox.get_node_or_null(nm)
	if not old: return
	var p = old.get_parent(); var i = old.get_index()
	p.remove_child(old); old.queue_free()
	var r = RichTextLabel.new(); r.name = nm
	r.bbcode_enabled = true; r.fit_content = true; r.autowrap_mode = TextServer.AUTOWRAP_OFF
	r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.add_child(r); p.move_child(r, i)

func _bc(pct: float) -> Color:
	if pct > 0.6: return Color(0.15, 0.75, 0.15)
	if pct > 0.3: return Color(0.85, 0.75, 0.1)
	return Color(0.85, 0.15, 0.1)

func _hc(pct: float) -> String:
	if pct > 0.6: return "green"
	if pct > 0.3: return "yellow"
	return "red"

func _make_rtl_label() -> RichTextLabel:
	var l = RichTextLabel.new(); l.bbcode_enabled = true; l.fit_content = true; l.autowrap_mode = TextServer.AUTOWRAP_OFF
	l.add_theme_font_size_override("font_size", 14)
	return l

func set_resources(res: Dictionary, lim: Dictionary, pop: Dictionary = {}):
	resources = res; limits = lim; population = pop

func update_info(entity_id: int):
	if not renderer: return
	observed_entity_id = entity_id
	var info = renderer.get_entity_info(entity_id)
	if info.is_empty(): visible = false; return
	visible = true

	# Count same-type buildings in selection for batch indicator
	var batch_count = 1
	var inp = get_tree().get_first_node_in_group("client_input") as client_input
	if inp and info["type"] == 1:
		for sid in inp.client_selected_ids:
			if sid != entity_id:
				var si = renderer.get_entity_info(sid)
				if si.get("entity_id") == info.get("entity_id"):
					batch_count += 1

	var group_prefix = ""
	# Client side: group display not available (needs server-side GameEntity ref)
	var nm = group_prefix + "%s  [color=royalblue]Lv.%d[/color]" % [info["name"], info.get("level", 1)]
	if batch_count > 1:
		nm += "  [color=orange][Ctrl+x%d][/color]" % batch_count
	name_rtl.text = nm

	var pct = float(info["health"]) / max(float(info["max_health"]), 1.0)
	hp_bar.color = _bc(pct); hp_bar.size.x = 180 * pct; hp_bar.visible = true

	var hc = _hc(pct)
	var t = "[color=%s]HP[/color]:  [color=white]%d / %d[/color]\n" % [hc, info["health"], info["max_health"]]
	t += "[color=orange]ATK[/color]:  [color=white]%d[/color]" % info["attack"]
	if info.get("armor", 0) > 0: t += "\n[color=steelblue]ARMOR[/color]:  [color=white]%d[/color]" % info["armor"]
	t += "\n[color=gold]RANGE[/color]:  [color=white]%.1f[/color]" % info.get("attack_range", 0.0)
	t += "\n[color=royalblue]SPEED[/color]:  [color=white]%.1f[/color]" % info.get("speed", 0.0)
	stats_rtl.text = t

	# Always detach old upgrade box first (avoid deferred-deletion residue)
	var old_box = $VBox.get_node_or_null("UpgradeInfoBox")
	if old_box:
		$VBox.remove_child(old_box)
		old_box.queue_free()
	if info["type"] == 1:
		# 拆除按钮（城堡不可拆）
		if demolish_btn:
			demolish_btn.visible = (info.get("entity_id", 0) != 20)
		if info.get("can_upgrade", false):
			upgrade_btn.visible = true; upgrade_btn.text = "Upgrade"
			if upgrade_btn.pressed.is_connected(_on_upgrade_pressed):
				upgrade_btn.pressed.disconnect(_on_upgrade_pressed)
			upgrade_btn.pressed.connect(_on_upgrade_pressed)

			var box = VBoxContainer.new(); box.name = "UpgradeInfoBox"; $VBox.add_child(box)

			var cost = info.get("get_upgrade_cost", {})
			for res in ["wood", "stone", "gold", "oil"]:
				if cost.get(res, 0) > 0:
					var need = cost[res]; var have = resources.get(res, 0)
					var rc = RC.get(res, "white"); var cc = "white" if have >= need else "red"
					var l = _make_rtl_label()
					l.text = "[color=%s]%s[/color]:  [color=%s]%d/%d[/color]" % [rc, res, cc, need, have]
					box.add_child(l)

			if info.get("castle_level_required", 0) > 0 and info.get("current_castle_level", 1) < info["castle_level_required"]:
				var l = _make_rtl_label()
				l.text = "[color=red]Need Castle Lv.%d[/color]" % info["castle_level_required"]
				box.add_child(l)
			upgrade_btn.disabled = false
		else:
			upgrade_btn.visible = false

		# Spacer
		var sp = Control.new(); sp.custom_minimum_size = Vector2(0, 8); produce_vbox.add_child(sp)
		for c in produce_vbox.get_children(): c.queue_free()
		var pl = info.get("production_list", [])
		if pl:
			produce_vbox.visible = true
			for prod in pl:
				var uc = EntityDatabase.get_config(prod["unit_id"])
				if not uc: continue
				var btn = Button.new(); btn.text = ""; btn.add_theme_font_size_override("font_size", 13); btn.custom_minimum_size = Vector2(180, 32); btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				var ok = population.get("current", 0) < population.get("max", 0); var cs = []
				var cost = prod.get("current_cost", uc.get("cost", {}))
				for res in cost:
					if cost[res] > 0:
						var need = cost[res] * batch_count
						var have = resources.get(res, 0)
						if have < need: ok = false
						cs.append({"res": res, "need": need, "have": have})
				btn.disabled = not ok
				var rtl = RichTextLabel.new(); rtl.bbcode_enabled = true; rtl.fit_content = true; rtl.autowrap_mode = TextServer.AUTOWRAP_OFF
				rtl.mouse_filter = Control.MOUSE_FILTER_IGNORE
				rtl.anchor_left = 0; rtl.anchor_right = 1; rtl.anchor_top = 0; rtl.anchor_bottom = 1
				var ct = ""
				for ci in cs:
					var rc = RC.get(ci.res, "white")
					var cc = "white" if ci.have >= ci.need else "red"
					ct += "[color=%s]%s[/color]:[color=%s]%d[/color] " % [rc, ci.res, cc, ci.need]
				rtl.text = "%s  [%s]" % [uc.get("name", "?"), ct.strip_edges()]
				btn.add_child(rtl)
				btn.pressed.connect(func(): _on_produce_pressed(prod["unit_id"]))
				produce_vbox.add_child(btn)
		else:
			produce_vbox.visible = false
	else:
		upgrade_btn.visible = false; produce_vbox.visible = false
		if demolish_btn: demolish_btn.visible = false
		hp_bar.visible = false

func _on_upgrade_pressed():
	if observed_entity_id == -1: return
	var n = 5 if Input.is_key_pressed(KEY_SHIFT) else 1
	# 升级已全局生效，只需升级当前建筑即可
	for _i in range(n):
		NetworkManager.send_command.rpc_id(1, {"action": "upgrade", "building_id": observed_entity_id, "ctrl_held": false, "shift_held": Input.is_key_pressed(KEY_SHIFT)})

func _on_produce_pressed(unit_id: int):
	if observed_entity_id == -1: return
	var n = 5 if Input.is_key_pressed(KEY_SHIFT) else 1
	var info = renderer.get_entity_info(observed_entity_id)
	var inp = get_tree().get_first_node_in_group("client_input") as client_input
	if inp and Input.is_key_pressed(KEY_CTRL):
		for sid in inp.client_selected_ids:
			var si = renderer.get_entity_info(sid)
			if si.get("entity_id") == info.get("entity_id"):
				for _i in range(n):
					NetworkManager.send_command.rpc_id(1, {"action": "produce", "building_id": sid, "unit_id": unit_id, "ctrl_held": true, "shift_held": Input.is_key_pressed(KEY_SHIFT)})
	else:
		for _i in range(n):
			NetworkManager.send_command.rpc_id(1, {"action": "produce", "building_id": observed_entity_id, "unit_id": unit_id, "ctrl_held": false, "shift_held": Input.is_key_pressed(KEY_SHIFT)})

var _refresh_timer: float = 0.0
var _last_ctrl: bool = false
var _last_sel_count: int = 0

func _process(delta):
	if not visible or observed_entity_id == -1: return
	var ctrl_now = Input.is_key_pressed(KEY_CTRL)
	var inp = get_tree().get_first_node_in_group("client_input") as client_input
	var sel_count = inp.client_selected_ids.size() if inp else 0
	_refresh_timer -= delta
	if _refresh_timer <= 0 or ctrl_now != _last_ctrl or sel_count != _last_sel_count:
		_refresh_timer = 0.5
		_last_ctrl = ctrl_now
		_last_sel_count = sel_count
		update_info(observed_entity_id)

# Multi-selection statistics panel
const ROW_COLORS = [
	Color(0.2, 0.8, 1.0),   # 青
	Color(1.0, 0.5, 0.0),   # 橙
	Color(0.3, 1.0, 0.3),   # 绿
	Color(1.0, 0.3, 0.8),   # 粉
	Color(1.0, 1.0, 0.2),   # 黄
	Color(0.7, 0.3, 1.0),   # 紫
	Color(1.0, 0.6, 0.4),   # 桃
	Color(0.4, 0.8, 0.6),   # 薄荷
]

var _multi_vbox: VBoxContainer = null
var _pending_multi_ids: Array = []         # IDs being accumulated via Ctrl+click
var _pending_multi_btns: Dictionary = {}   # btn -> true for tracking pressed state

func show_multi_selection(ids: Array):
	visible = true
	observed_entity_id = -1
	upgrade_btn.visible = false
	if demolish_btn: demolish_btn.visible = false
	produce_vbox.visible = true
	hp_bar.visible = false
	var old_box = $VBox.get_node_or_null("UpgradeInfoBox")
	if old_box:
		$VBox.remove_child(old_box)
		old_box.queue_free()
	name_rtl.text = "[color=white]选中 %d 个单位[/color]" % ids.size()
	stats_rtl.text = ""
	for c in produce_vbox.get_children(): c.queue_free()

	# Aggregate by (entity_id, owner_peer_id)
	var groups: Dictionary = {}
	for eid in ids:
		var info = renderer.get_entity_info(eid)
		if info.is_empty(): continue
		var key = "%d_%d_%s" % [info["entity_id"], info.get("owner_peer_id", -1), info["name"]]
		if not groups.has(key):
			groups[key] = {"count": 0, "entity_id": info["entity_id"], "name": info["name"],
				"owner_peer_id": info.get("owner_peer_id", -1), "team": info["team"],
				"ids": [], "min_level": 99, "max_level": 0}
		var g = groups[key]
		g["count"] += 1
		g["ids"].append(eid)
		g["min_level"] = min(g["min_level"], info.get("level", 1))
		g["max_level"] = max(g["max_level"], info.get("level", 1))

	var keys = groups.keys()
	keys.sort_custom(func(a, b): return groups[a]["count"] > groups[b]["count"])

	# Reset pending multi-selection
	_pending_multi_ids.clear()
	_pending_multi_btns.clear()

	for i in range(keys.size()):
		var g = groups[keys[i]]
		var row_color = ROW_COLORS[i % ROW_COLORS.size()]

		var btn = Button.new()
		btn.custom_minimum_size = Vector2(180, 36)
		btn.add_theme_font_size_override("font_size", 14)
		btn.toggle_mode = true

		# Normal style
		var sb = StyleBoxFlat.new()
		sb.bg_color = Color(row_color.r * 0.15, row_color.g * 0.15, row_color.b * 0.15, 0.9)
		sb.border_width_left = 3
		sb.border_color = row_color
		sb.corner_radius_top_left = 4; sb.corner_radius_top_right = 4
		sb.corner_radius_bottom_left = 4; sb.corner_radius_bottom_right = 4
		btn.add_theme_stylebox_override("normal", sb)

		# Hover style
		var hover_sb = StyleBoxFlat.new()
		hover_sb.bg_color = Color(row_color.r * 0.25, row_color.g * 0.25, row_color.b * 0.25, 0.95)
		hover_sb.border_width_left = 3
		hover_sb.border_color = row_color.lightened(0.3)
		hover_sb.corner_radius_top_left = 4; hover_sb.corner_radius_top_right = 4
		hover_sb.corner_radius_bottom_left = 4; hover_sb.corner_radius_bottom_right = 4
		btn.add_theme_stylebox_override("hover", hover_sb)

		# Pressed/selected style (brighter)
		var pressed_sb = StyleBoxFlat.new()
		pressed_sb.bg_color = Color(row_color.r * 0.4, row_color.g * 0.4, row_color.b * 0.4, 0.95)
		pressed_sb.border_width_left = 3
		pressed_sb.border_color = row_color.lightened(0.5)
		pressed_sb.corner_radius_top_left = 4; pressed_sb.corner_radius_top_right = 4
		pressed_sb.corner_radius_bottom_left = 4; pressed_sb.corner_radius_bottom_right = 4
		btn.add_theme_stylebox_override("pressed", pressed_sb)

		var lvl_text = " Lv.%d" % g["min_level"] if g["min_level"] == g["max_level"] else " Lv.%d~%d" % [g["min_level"], g["max_level"]]
		btn.text = "%d x %s%s" % [g["count"], g["name"], lvl_text]
		btn.add_theme_color_override("font_color", row_color)
		btn.add_theme_color_override("font_pressed_color", row_color.lightened(0.3))

		var row_ids = g["ids"].duplicate()
		btn.pressed.connect(func():
			var ci = get_tree().get_first_node_in_group("client_input") as client_input
			if not ci: return
			if Input.is_key_pressed(KEY_CTRL):
				# Toggle in pending list
				if btn.button_pressed:
					if row_ids[0] not in _pending_multi_ids:
						for rid in row_ids:
							if rid not in _pending_multi_ids:
								_pending_multi_ids.append(rid)
						_pending_multi_btns[btn] = true
				else:
					for rid in row_ids:
						_pending_multi_ids.erase(rid)
					_pending_multi_btns.erase(btn)
			else:
				# Immediate selection - recast
				var _cx = get_tree().get_first_node_in_group("client_input") as client_input
				if _cx:
					_cx.set_client_selected_ids(row_ids)
		)

		produce_vbox.add_child(btn)

	# Start monitoring Ctrl key release
	set_process_input(true)
# Detect Ctrl release to commit pending multi-selection
func _input(event):
	if event is InputEventKey and not event.pressed:
		if event.keycode == KEY_CTRL and _pending_multi_ids.size() > 0:
			var ci2 = get_tree().get_first_node_in_group("client_input") as client_input
			if ci2:
				ci2.client_selected_ids = _pending_multi_ids.duplicate()
				ci2._update_selection_visuals()
				ci2.emit_signal("selection_changed", ci2.client_selected_ids.duplicate())
			# Reset pending list and un-toggle all buttons
			for btn in _pending_multi_btns.keys():
				if is_instance_valid(btn):
					btn.button_pressed = false
			_pending_multi_ids.clear()
			_pending_multi_btns.clear()

func _on_demolish_pressed():
	if observed_entity_id == -1: return
	NetworkManager.send_command.rpc_id(1, {"action": "demolish", "building_id": observed_entity_id})
	visible = false
	observed_entity_id = -1
	var ci = get_tree().get_first_node_in_group("client_input") as client_input
	if ci:
		ci.client_selected_ids.erase(observed_entity_id)
		ci._update_selection_visuals()
		ci.emit_signal("selection_changed", ci.client_selected_ids.duplicate())

func _on_close_pressed():
	_pending_multi_ids.clear()
	_pending_multi_btns.clear()
	visible = false; observed_entity_id = -1

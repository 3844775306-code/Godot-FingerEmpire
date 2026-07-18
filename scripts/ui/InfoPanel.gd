# scripts/ui/InfoPanel.gd
class_name InfoPanel
extends Panel

@onready var upgrade_btn = $VBox/UpgradeBtn
@onready var produce_vbox = $VBox/ProduceVBox
@onready var close_btn = $CloseBtn

var name_rtl: RichTextLabel
var stats_rtl: RichTextLabel
var hp_bar: ColorRect
var observed_entity: GameEntity = null
var battle: RTSBattleManager = null
var demolish_btn: Button = null

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
	l.add_theme_font_size_override("font_size", 10)
	return l

func _get_same_type_buildings(entity: Building) -> Array[Building]:
	var result: Array[Building] = []
	if Input.is_key_pressed(KEY_CTRL):
		# Ctrl: ALL player buildings of same type
		var bm = get_tree().get_first_node_in_group("battle_manager")
		if bm and bm.has_node("Entities"):
			for e in bm.get_node("Entities").get_children():
				if e is Building and e.entity_id == entity.entity_id and e.team == entity.team:
					result.append(e)
	else:
		result.append(entity)
	return result

func update_info(entity: GameEntity):
	observed_entity = entity; visible = true

	# Batch count from selection
	var batch_count = 1
	if entity is Building:
		var same = _get_same_type_buildings(entity)
		batch_count = max(1, same.size())

	var group_prefix = ""
	var sm = get_tree().get_first_node_in_group("battle_manager")
	if sm and sm.has_node("SelectionManager") and sm.get_node("SelectionManager").has_method("get_entity_groups"):
		var e = observed_entity if observed_entity else null
		var groups = sm.get_node("SelectionManager").get_entity_groups(e)
		for g in groups:
			group_prefix += "[color=red]T%d[/color] " % g
	var nm = group_prefix + "%s  [color=royalblue]Lv.%d[/color]" % [entity.display_name, entity.level]
	if batch_count > 1:
		nm += "  [color=orange][Ctrl+x%d][/color]" % batch_count
	name_rtl.text = nm

	var pct = float(entity.health) / max(float(entity.max_health), 1.0)
	hp_bar.color = _bc(pct); hp_bar.size.x = 180 * pct; hp_bar.visible = true

	var hc = _hc(pct)
	var t = "[color=%s]HP[/color]:  [color=white]%d / %d[/color]\n" % [hc, entity.health, entity.max_health]
	t += "[color=orange]ATK[/color]:  [color=white]%d[/color]" % entity.attack
	if entity.armor > 0: t += "\n[color=steelblue]ARMOR[/color]:  [color=white]%d[/color]" % entity.armor
	t += "\n[color=gold]RANGE[/color]:  [color=white]%.1f[/color]" % entity.attack_range
	t += "\n[color=royalblue]SPEED[/color]:  [color=white]%.1f[/color]" % entity.speed
	stats_rtl.text = t

	# Always detach old upgrade box first (avoid deferred-deletion residue)
	var old_box = $VBox.get_node_or_null("UpgradeInfoBox")
	if old_box:
		$VBox.remove_child(old_box)
		old_box.queue_free()
	if entity is Building:
		# 拆除按钮（城堡不可拆）
		if demolish_btn:
			demolish_btn.visible = (entity.entity_id != 20)
		if entity.can_upgrade():
			upgrade_btn.visible = true; upgrade_btn.text = "升级"
			if upgrade_btn.pressed.is_connected(_on_upgrade_pressed):
				upgrade_btn.pressed.disconnect(_on_upgrade_pressed)
			upgrade_btn.pressed.connect(_on_upgrade_pressed)

			var box = VBoxContainer.new(); box.name = "UpgradeInfoBox"; $VBox.add_child(box)

			# Show cost per building * batch count
			var cost = entity.get_upgrade_cost()
			for res in ["wood", "stone", "gold", "oil"]:
				if cost.get(res, 0) > 0:
					var need = cost[res]
					var have = battle.player_resources.get(res, 0) if battle else 0
					var rc = RC.get(res, "white")
					var cc = "white" if have >= need else "red"
					var l = _make_rtl_label()
					l.text = "[color=%s]%s[/color]:  [color=%s]%d/%d[/color]" % [rc, res, cc, need, have]
					box.add_child(l)

			if entity.entity_id != 20:
				var cl = entity.get_castle_level()
				if entity.upgrade_level + 1 > cl:
					var l = _make_rtl_label()
					l.text = "[color=red]Need Castle Lv.%d[/color]" % (entity.upgrade_level + 1)
					box.add_child(l)
		else:
			upgrade_btn.visible = false

		for c in produce_vbox.get_children(): c.queue_free()
		if not entity.production_list.is_empty():
			produce_vbox.visible = true
			for prod in entity.production_list:
				var uc = EntityDatabase.get_config(prod.unit_id)
				if not uc: continue
				var btn = Button.new(); btn.text = ""; btn.add_theme_font_size_override("font_size", 13); btn.custom_minimum_size = Vector2(180, 32); btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				var ok = true; var cs = []
				var lv = entity.level
				for res in uc.get("cost", {}):
					var base = uc["cost"][res]
					var scaled = int(base * (1.0 + (lv - 1) * 0.2))
					var need = scaled * batch_count
					var have = battle.player_resources.get(res, 0) if battle else 0
					if have < need: ok = false
					cs.append({"res": res, "need": need})
				btn.disabled = not ok
				var rtl = RichTextLabel.new(); rtl.bbcode_enabled = true; rtl.fit_content = true; rtl.autowrap_mode = TextServer.AUTOWRAP_OFF
				rtl.mouse_filter = Control.MOUSE_FILTER_IGNORE
				rtl.anchor_left = 0; rtl.anchor_right = 1; rtl.anchor_top = 0; rtl.anchor_bottom = 1
				var ct = ""
				for ci in cs:
					var rc = RC.get(ci.res, "white")
					var cc = "white" if battle.player_resources.get(ci.res, 0) >= ci.need else "red"
					ct += "[color=%s]%s[/color]:[color=%s]%d[/color] " % [rc, ci.res, cc, ci.need]
				rtl.text = "%s  [%s]" % [uc.get("name", "?"), ct.strip_edges()]
				btn.add_child(rtl)
				btn.pressed.connect(func(): _on_produce_pressed(prod.unit_id))
				produce_vbox.add_child(btn)
		else:
			produce_vbox.visible = false
	else:
		upgrade_btn.visible = false; produce_vbox.visible = false
		if demolish_btn: demolish_btn.visible = false
	hp_bar.visible = true

func _on_upgrade_pressed():
	if not observed_entity or not is_instance_valid(observed_entity): return
	var n = 999 if Input.is_key_pressed(KEY_SHIFT) else 1
	# 升级已全局生效，只需升级当前建筑即可
	for _i in range(n):
		if not observed_entity.can_upgrade() or not observed_entity.perform_upgrade(battle): break

func _on_produce_pressed(unit_id: int):
	if not observed_entity or not is_instance_valid(observed_entity): return
	var n = 5 if Input.is_key_pressed(KEY_SHIFT) else 1
	var targets = _get_same_type_buildings(observed_entity) if Input.is_key_pressed(KEY_CTRL) else [observed_entity]
	for b in targets:
		for _i in range(n):
			if not b.try_produce(unit_id): break

var _refresh_timer: float = 0.0

func _process(delta):
	if not visible or not observed_entity or not is_instance_valid(observed_entity): return
	_refresh_timer -= delta
	if _refresh_timer <= 0:
		_refresh_timer = 1.0
		update_info(observed_entity)

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

var _pending_multi_entities: Array = []
var _pending_multi_btns: Dictionary = {}

func show_multi_selection(entities: Array):
	var old_box = $VBox.get_node_or_null("UpgradeInfoBox")
	if old_box:
		$VBox.remove_child(old_box)
		old_box.queue_free()
	visible = true
	observed_entity = null
	upgrade_btn.visible = false
	if demolish_btn: demolish_btn.visible = false
	produce_vbox.visible = true
	hp_bar.visible = false
	name_rtl.text = "[color=white]选中 %d 个单位[/color]" % entities.size()
	stats_rtl.text = ""
	for c in produce_vbox.get_children(): c.queue_free()

	# Aggregate by (entity_id, team, owner_peer_id)
	var groups: Dictionary = {}
	for entity in entities:
		if not is_instance_valid(entity) or entity.health <= 0: continue
		var key = "%d_%d_%d" % [entity.entity_id, entity.team, entity.owner_peer_id]
		if not groups.has(key):
			groups[key] = {"count": 0, "entity_id": entity.entity_id,
				"name": entity.display_name, "team": entity.team,
				"owner_peer_id": entity.owner_peer_id,
				"entities": [], "min_level": 99, "max_level": 0}
		var g = groups[key]
		g["count"] += 1
		g["entities"].append(entity)
		g["min_level"] = min(g["min_level"], entity.level)
		g["max_level"] = max(g["max_level"], entity.level)

	var keys = groups.keys()
	keys.sort_custom(func(a, b): return groups[a]["count"] > groups[b]["count"])

	# Reset pending multi-selection
	_pending_multi_entities.clear()
	_pending_multi_btns.clear()

	for i in range(keys.size()):
		var g = groups[keys[i]]
		var row_color = ROW_COLORS[i % ROW_COLORS.size()]

		var btn = Button.new()
		btn.custom_minimum_size = Vector2(180, 36)
		btn.add_theme_font_size_override("font_size", 14)
		btn.toggle_mode = true

		var sb = StyleBoxFlat.new()
		sb.bg_color = Color(row_color.r * 0.15, row_color.g * 0.15, row_color.b * 0.15, 0.9)
		sb.border_width_left = 3
		sb.border_color = row_color
		sb.corner_radius_top_left = 4; sb.corner_radius_top_right = 4
		sb.corner_radius_bottom_left = 4; sb.corner_radius_bottom_right = 4
		btn.add_theme_stylebox_override("normal", sb)

		var hover_sb = StyleBoxFlat.new()
		hover_sb.bg_color = Color(row_color.r * 0.25, row_color.g * 0.25, row_color.b * 0.25, 0.95)
		hover_sb.border_width_left = 3
		hover_sb.border_color = row_color.lightened(0.3)
		hover_sb.corner_radius_top_left = 4; hover_sb.corner_radius_top_right = 4
		hover_sb.corner_radius_bottom_left = 4; hover_sb.corner_radius_bottom_right = 4
		btn.add_theme_stylebox_override("hover", hover_sb)

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

		var row_entities = g["entities"].duplicate()
		btn.pressed.connect(func():
			var sel = get_tree().get_first_node_in_group("battle_manager").get_node_or_null("SelectionManager")
			if not sel: return
			if Input.is_key_pressed(KEY_CTRL):
				# Toggle in pending list
				if btn.button_pressed:
					for e in row_entities:
						if is_instance_valid(e) and e not in _pending_multi_entities:
							_pending_multi_entities.append(e)
					_pending_multi_btns[btn] = true
				else:
					for e in row_entities:
						_pending_multi_entities.erase(e)
					_pending_multi_btns.erase(btn)
			else:
				# Immediate selection
				for e in sel.selected_entities:
					if is_instance_valid(e): e.set_selected(false)
				sel.selected_entities = row_entities
				for e in row_entities:
					if is_instance_valid(e): e.set_selected(true)
				sel._update_info_panel()
		)

		produce_vbox.add_child(btn)

	# Start monitoring Ctrl key release
	set_process_input(true)

# Detect Ctrl release to commit pending multi-selection
func _input(event):
	if event is InputEventKey and not event.pressed:
		if event.keycode == KEY_CTRL and _pending_multi_entities.size() > 0:
			var sel = get_tree().get_first_node_in_group("battle_manager").get_node_or_null("SelectionManager")
			if sel:
				for e in sel.selected_entities:
					if is_instance_valid(e): e.set_selected(false)
				sel.selected_entities.clear()
				for e in _pending_multi_entities:
					if is_instance_valid(e):
						sel.selected_entities.append(e)
						e.set_selected(true)
				sel._update_info_panel()
			# Reset pending list
			for btn in _pending_multi_btns.keys():
				if is_instance_valid(btn):
					btn.button_pressed = false
			_pending_multi_entities.clear()
			_pending_multi_btns.clear()


func _on_demolish_pressed():
	if not observed_entity or not is_instance_valid(observed_entity):
		return
	if not (observed_entity is Building):
		return
	var bm = get_tree().get_first_node_in_group("battle_manager") as RTSBattleManager
	if bm:
		bm.demolish_building(observed_entity)
	visible = false
	observed_entity = null

func _on_close_pressed():
	visible = false; observed_entity = null

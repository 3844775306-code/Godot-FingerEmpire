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
var hp_bar_bg: ColorRect = null
# 顶部纹章头像（clash-royale 卡片式徽章）：队伍色边框 + 实体 emoji
var _crest_sb: StyleBoxFlat = null
var _crest_emoji: Label = null
# 统一资源获取：在线模式用 get_host_resources()，单机用 player_resources
func _get_res() -> Dictionary:
	if not battle:
		return {}
	if battle.has_method("get_host_resources"):
		return battle.get_host_resources()
	return battle.player_resources
func _ready():
	visible = false
	add_theme_stylebox_override("panel", UITheme.panel_style(UITheme.RADIUS_LG, UITheme.BORDER_MED))
	custom_minimum_size = Vector2(360, 0)

	_swap_rtl("NameLabel"); _swap_rtl("StatsLabel")
	name_rtl = $VBox.get_node("NameLabel")
	stats_rtl = $VBox.get_node("StatsLabel")
	name_rtl.add_theme_font_size_override("font_size", UITheme.FONT_XL)
	name_rtl.add_theme_color_override("default_color", UITheme.PARCHMENT)
	name_rtl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stats_rtl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	stats_rtl.add_theme_color_override("default_color", UITheme.PARCHMENT)

	# 血条：黑色背景条 + 锚点前景（宽度 = 血量比例）
	hp_bar_bg = ColorRect.new(); hp_bar_bg.name = "HPBarBg"
	hp_bar_bg.custom_minimum_size = Vector2(1, 16)
	hp_bar_bg.color = Color(0, 0, 0, 0.55)
	hp_bar_bg.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hp_bar = ColorRect.new(); hp_bar.name = "HPBar"
	hp_bar.color = Color.GREEN
	hp_bar.anchor_top = 0; hp_bar.anchor_bottom = 1
	hp_bar.anchor_left = 0; hp_bar.anchor_right = 1
	hp_bar_bg.add_child(hp_bar)
	var vb = $VBox; vb.add_child(hp_bar_bg); vb.move_child(hp_bar_bg, 1)
	close_btn.pressed.connect(_on_close_pressed)
	close_btn.text = "✕ 关闭"
	UITheme.apply_muted_button(close_btn, UITheme.FONT_SM)
	UITheme.apply_primary_button(upgrade_btn, UITheme.FONT_MD)

	# 拆除按钮 — 危险红
	demolish_btn = Button.new()
	demolish_btn.name = "DemolishBtn"
	demolish_btn.text = "💥 拆除建筑"
	demolish_btn.custom_minimum_size = Vector2(180, 36)
	demolish_btn.visible = false
	demolish_btn.pressed.connect(_on_demolish_pressed)
	UITheme.apply_danger_button(demolish_btn, UITheme.FONT_SM)
	$VBox.add_child(demolish_btn)

	# 顶部纹章头（名称行移入，紧贴徽章）
	_build_crest_header()

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

# 顶部纹章头：队伍色圆徽（实体 emoji）+ 名称行紧贴其后
func _build_crest_header() -> void:
	var vb := $VBox
	var header := HBoxContainer.new()
	header.name = "HeaderRow"
	header.add_theme_constant_override("separation", 10)
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var crest := Panel.new()
	crest.name = "Crest"
	crest.custom_minimum_size = Vector2(58, 58)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(UITheme.INK, 0.95)
	sb.set_corner_radius_all(10)
	sb.set_border_width_all(UITheme.BORDER_MED)
	sb.border_width_top = UITheme.BORDER_THICK + 1
	sb.border_color = Color(UITheme.GOLD, 0.9)
	sb.shadow_size = 4
	sb.shadow_color = Color(0, 0, 0, 0.5)
	sb.shadow_offset = Vector2(1, 2)
	crest.add_theme_stylebox_override("panel", sb)
	_crest_sb = sb

	var emoji := Label.new()
	emoji.name = "Emoji"
	emoji.text = "🛡️"
	emoji.set_anchors_preset(Control.PRESET_FULL_RECT)
	emoji.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	emoji.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	emoji.add_theme_font_size_override("font_size", UITheme.FONT_XXL)
	emoji.mouse_filter = Control.MOUSE_FILTER_IGNORE
	crest.add_child(emoji)
	_crest_emoji = emoji
	header.add_child(crest)

	# 名称行移入头部（宽高让给 RTL 自动折行）
	vb.remove_child(name_rtl)
	name_rtl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header.add_child(name_rtl)

	vb.add_child(header)
	vb.move_child(header, 0)
	# 血条紧跟标题行
	if hp_bar_bg:
		vb.move_child(hp_bar_bg, 1)

# 更新纹章：accent 边框 + emoji 内容
func _set_crest(accent: Color, emoji_text: String) -> void:
	if _crest_emoji:
		_crest_emoji.text = emoji_text
	if _crest_sb:
		_crest_sb.border_color = Color(accent, 0.95)
		_crest_sb.bg_color = Color(accent, 0.18)

# 根据实体所属队伍取强调色（友方=蓝宝石 / 敌方=朱红 / 中立=金）
func _accent_for(team: int) -> Color:
	if battle and battle.has_method("get_host_team") and team == battle.get_host_team():
		return UITheme.SAPPHIRE
	match team:
		0: return UITheme.VERMILION
		1: return UITheme.SAPPHIRE
		_: return UITheme.GOLD

func _bc(pct: float) -> Color:
	return UITheme.health_bar_color(pct)

func _hc(pct: float) -> String:
	return UITheme.hex_str(UITheme.health_bar_color(pct))

func _make_rtl_label() -> RichTextLabel:
	var l = RichTextLabel.new(); l.bbcode_enabled = true; l.fit_content = true; l.autowrap_mode = TextServer.AUTOWRAP_OFF
	l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	l.add_theme_color_override("default_color", UITheme.PARCHMENT)
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

	_set_crest(_accent_for(entity.team), UITheme.entity_emoji(entity.entity_id, entity.entity_type))

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
			group_prefix += "[color=%s]T%d[/color] " % [UITheme.hex_str(UITheme.VERMILION), g]
	var nm = group_prefix + "%s  [color=%s]Lv.%d[/color]" % [
		UITheme.entity_emoji(entity.entity_id, entity.entity_type),
		UITheme.hex_str(UITheme.GOLD), entity.level]
	if batch_count > 1:
		nm += "  [color=%s][Ctrl + x%d][/color]" % [UITheme.hex_str(UITheme.ALERT_WARNING), batch_count]
	name_rtl.text = nm

	var pct = float(entity.health) / max(float(entity.max_health), 1.0)
	hp_bar.color = _bc(pct)
	hp_bar.anchor_right = pct
	if hp_bar_bg: hp_bar_bg.visible = true
	hp_bar.visible = true

	var hc = _hc(pct)
	var t = "❤️ [color=%s]HP[/color]:  [color=white]%d / %d[/color]\n" % [hc, entity.health, entity.max_health]
	t += "⚔️ [color=%s]ATK[/color]:  [color=white]%d[/color]" % [UITheme.hex_str(UITheme.GOLD), entity.attack]
	if entity.melee_armor > 0 or entity.shield_armor > 0:
		t += "
	⛓️ [color=%s]铠甲[/color]:  [color=white]%d[/color]  🛡️ [color=%s]盾牌[/color]:  [color=white]%d[/color]" % [
		UITheme.hex_str(UITheme.SAPPHIRE), entity.melee_armor,
		UITheme.hex_str(UITheme.STONE), entity.shield_armor]
	t += "\n🎯 [color=%s]RANGE[/color]:  [color=white]%.1f[/color]" % [UITheme.hex_str(UITheme.GOLD), entity.attack_range]
	t += "\n👟 [color=%s]SPEED[/color]:  [color=white]%.1f[/color]" % [UITheme.hex_str(UITheme.EMERALD), entity.speed]
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
			box.add_theme_constant_override("separation", 2)

			# Show cost per building * batch count
			var cost = entity.get_upgrade_cost()
			for res in ["wood", "stone", "gold", "oil"]:
				if cost.get(res, 0) > 0:
					var need = cost[res]
					var have = _get_res().get(res, 0)
					var rc = UITheme.hex_str(UITheme.RESOURCE_COLORS.get(res, UITheme.PARCHMENT))
					var cc = "white" if have >= need else UITheme.hex_str(UITheme.VERMILION)
					var l = _make_rtl_label()
					l.text = "%s [color=%s]%s[/color]:  [color=%s]%d / %d[/color]" % [
						UITheme.RESOURCE_ICONS.get(res, ""), rc,
						UITheme.RESOURCE_NAMES.get(res, res), cc, have, need]
					box.add_child(l)

			if entity.entity_id != 20:
				var cl = entity.get_castle_level()
				if entity.upgrade_level + 1 > cl:
					var l = _make_rtl_label()
					l.text = "[color=%s]🏰 需主城 Lv.%d[/color]" % [UITheme.hex_str(UITheme.VERMILION), entity.upgrade_level + 1]
					box.add_child(l)
		else:
			upgrade_btn.visible = false

		for c in produce_vbox.get_children(): c.queue_free()
		if not entity.production_list.is_empty():
			produce_vbox.visible = true
			var seen = {}
			for prod in entity.production_list:
				if seen.has(prod.unit_id): continue
				seen[prod.unit_id] = true
				var uc = EntityDatabase.get_config(prod.unit_id)
				if not uc: continue
				var btn = Button.new(); btn.text = ""; btn.custom_minimum_size = Vector2(200, 40); btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				UITheme.apply_button(btn, UITheme.FONT_SM)
				var ok = true; var cs = []
				var lv = entity.level
				for res in uc.get("cost", {}):
					var base = uc["cost"][res]
					var scaled = int(base * (1.0 + (lv - 1) * 0.2))
					var need = scaled * batch_count
					var have = _get_res().get(res, 0)
					if have < need: ok = false
					cs.append({"res": res, "need": need})
				btn.disabled = not ok
				var rtl = RichTextLabel.new(); rtl.bbcode_enabled = true; rtl.fit_content = true; rtl.autowrap_mode = TextServer.AUTOWRAP_OFF
				rtl.mouse_filter = Control.MOUSE_FILTER_IGNORE
				rtl.anchor_left = 0; rtl.anchor_right = 1; rtl.anchor_top = 0; rtl.anchor_bottom = 1
				rtl.add_theme_color_override("default_color", UITheme.PARCHMENT)
				var ct = ""
				for ci in cs:
					var cc = "white" if _get_res().get(ci.res, 0) >= ci.need else UITheme.hex_str(UITheme.VERMILION)
					ct += "%s[color=%s]%d[/color] " % [UITheme.RESOURCE_ICONS.get(ci.res, ""), cc, ci.need]
				rtl.text = "%s %s  [%s]" % [
					UITheme.entity_emoji(int(uc.get("id", -1)), int(uc.get("type", 2))),
					uc.get("name", "?"), ct.strip_edges()]
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
	if hp_bar_bg: hp_bar_bg.visible = false
	_set_crest(UITheme.GOLD, "👥")
	name_rtl.text = "[color=%s]⚔️ 选中 %d 个单位[/color]" % [UITheme.hex_str(UITheme.GOLD), entities.size()]
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
		btn.custom_minimum_size = Vector2(200, 40)
		btn.toggle_mode = true
		UITheme.apply_row_button(btn, row_color)

		var etype: int = 2
		if g["entities"].size() > 0:
			etype = g["entities"][0].entity_type
		var lvl_text = " Lv.%d" % g["min_level"] if g["min_level"] == g["max_level"] else " Lv.%d~%d" % [g["min_level"], g["max_level"]]
		btn.text = "%s %d x %s%s" % [UITheme.entity_emoji(g["entity_id"], etype), g["count"], g["name"], lvl_text]

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
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if bm:
		var sel = bm.get_node_or_null("SelectionManager")
		if sel and sel.has_method("_clear_selection"):
			sel._clear_selection()

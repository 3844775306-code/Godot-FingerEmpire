# scripts/ui/InfoPanel.gd
class_name InfoPanel
extends Panel

var upgrade_btn: Button = null
var produce_vbox: VBoxContainer = null
var _vb: VBoxContainer = null
var _panel_scroll: ScrollContainer = null

# ==================== 运载船：上/下船 ====================
const BOARD_RANGE: float = 2.5  # 只有船周围 2.5 米内的陆地单位才能上船

var _board_box: VBoxContainer = null
var _board_label: RichTextLabel = null
var _board_up_btn: Button = null
var _board_down_btn: Button = null
var _board_near_units: Array = []
var _board_shore: Vector3 = Vector3.ZERO
@onready var close_btn = $CloseBtn

var name_rtl: RichTextLabel
var stats_rtl: RichTextLabel
var hp_bar: ColorRect
var observed_entity = null
var battle: RTSBattleManager = null
var demolish_btn: Button = null
var hp_bar_bg: ColorRect = null
# 统一资源获取：在线模式用 get_host_resources()，单机用 player_resources
func _get_res() -> Dictionary:
	if not battle:
		return {}
	if battle.has_method("get_host_resources"):
		return battle.get_host_resources()
	return battle.player_resources

# 移动端字号：设计空间 2400x1400 直接写 14 号字在手机上只有约 4dp。
# 注意 RichTextLabel 的字号主题项是 normal_font_size，只设 font_size 不会生效。
func _is_mobile() -> bool:
	return InputSource.use_mobile_ui()

func _mobile_font(base_size: int) -> int:
	if not _is_mobile():
		return base_size
	return int(round(base_size * UILayout.DP_RATIO))

func _set_rtl_font(rtl: RichTextLabel, size: int) -> void:
	rtl.add_theme_font_size_override("normal_font_size", size)
	rtl.add_theme_font_size_override("bold_font_size", size)
	rtl.add_theme_font_size_override("italics_font_size", size)
	rtl.add_theme_font_size_override("bold_italics_font_size", size)
	rtl.add_theme_font_size_override("mono_font_size", size)

func _ready():
	visible = false
	_vb = $VBox
	upgrade_btn = _vb.get_node("UpgradeBtn")
	produce_vbox = _vb.get_node("ProduceVBox")
	add_theme_stylebox_override("panel", UITheme.panel_style(UITheme.RADIUS_LG, UITheme.BORDER_MED))
	custom_minimum_size = Vector2(360, 0)

	_swap_rtl("NameLabel"); _swap_rtl("StatsLabel")
	name_rtl = _vb.get_node("NameLabel")
	stats_rtl = _vb.get_node("StatsLabel")
	name_rtl.add_theme_font_size_override("font_size", UITheme.FONT_XL)
	name_rtl.add_theme_color_override("default_color", UITheme.PARCHMENT)
	name_rtl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stats_rtl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	stats_rtl.add_theme_color_override("default_color", UITheme.PARCHMENT)
	if _is_mobile():
		# 手机上名称与属性两行都要能看清：名称 15dp、属性 12dp
		_set_rtl_font(name_rtl, UILayout.font_dp(15.0))
		_set_rtl_font(stats_rtl, UILayout.font_dp(12.0))

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
	var vb = _vb; vb.add_child(hp_bar_bg); vb.move_child(hp_bar_bg, 1)
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
	_vb.add_child(demolish_btn)

	set_process(true)
	if _is_mobile():
		_build_mobile_scroll()

# 手机端面板只有 260×200dp，建筑生产按钮一多就会超出屏幕底部；
# 把内容包进滚动容器，触摸拖动由手势路由调用 UILayout.scroll_at 驱动。
func _build_mobile_scroll() -> void:
	# 关闭按钮放大到可点尺寸并固定在右上角，不随内容滚动
	close_btn.custom_minimum_size = Vector2(UILayout.dp(46.0), UILayout.dp(18.0))
	close_btn.anchor_left = 1.0
	close_btn.anchor_right = 1.0
	close_btn.offset_left = -UILayout.dp(54.0)
	close_btn.offset_right = -UILayout.dp(5.0)
	close_btn.offset_top = UILayout.dp(4.0)
	close_btn.offset_bottom = UILayout.dp(21.0)

	var sc := ScrollContainer.new()
	sc.name = "PanelScroll"
	sc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	sc.offset_left = UILayout.dp(4.0)
	sc.offset_right = -UILayout.dp(4.0)
	sc.offset_top = UILayout.dp(24.0)   # 顶部给关闭按钮留一行
	sc.offset_bottom = -UILayout.dp(4.0)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	# 容器自身不吃事件：滚动由 UILayout.scroll_at 直接驱动，避免它把 scroll 值算回去
	sc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(sc)
	move_child(sc, 0)   # 放到最底层，关闭按钮保持在上面

	if _vb.get_parent():
		_vb.get_parent().remove_child(_vb)
	sc.add_child(_vb)
	_vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vb.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_panel_scroll = sc

func _swap_rtl(nm: String):
	var old = _vb.get_node_or_null(nm)
	if not old: return
	var p = old.get_parent(); var i = old.get_index()
	p.remove_child(old); old.queue_free()
	var r = RichTextLabel.new(); r.name = nm
	r.bbcode_enabled = true; r.fit_content = true; r.autowrap_mode = TextServer.AUTOWRAP_OFF
	r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.add_child(r); p.move_child(r, i)

func _bc(pct: float) -> Color:
	return UITheme.health_bar_color(pct)

func _hc(pct: float) -> String:
	return UITheme.hex_str(UITheme.health_bar_color(pct))

# 信息面板用：把目标名称缩短成可读文本，避免面板被长名字撑爆
func _target_display_name(target) -> String:
	if target == null or not is_instance_valid(target):
		return "未知目标"
	var nm: String = ""
	if target is GameEntity:
		nm = target.display_name
	if nm == "":
		var cfg: Dictionary = EntityDatabase.get_config(int(target.entity_id))
		nm = str(cfg.get("name", "目标"))
	return nm

# 单位任务：驻守 / 攻击目标 / 反击，其余显示移动、采集、空闲。
# 反击包括：驻扎圈内自动应战、AI 建筑被攻击后的临时支援、被同一个敌人攻击后的还击。
func _army_task_text(a: Army) -> String:
	var target = a.current_target
	# 采集/交付的目标是资源点，不是作战目标；只把军队/建筑当作攻击目标显示
	var has_target: bool = target != null and is_instance_valid(target) and target.health > 0 and (target is Army or target is Building)
	var now: float = float(battle.game_time) if battle != null else 0.0
	var counter: bool = false
	if a.has_meta("ai_building_defense_until") and now < float(a.get_meta("ai_building_defense_until")):
		counter = true
	if has_target and a.garrison_point != Vector3.ZERO:
		var defend_radius: float = 10.0
		if a.has_meta("ai_building_defense_until"):
			defend_radius = 45.0
		if target.global_position.distance_to(a.garrison_point) <= defend_radius:
			counter = true
	var last_damager = a.get("_last_damager")
	if has_target and last_damager != null and is_instance_valid(last_damager) and last_damager == target:
		counter = true
	if counter:
		return "🛡 反击 · %s" % _target_display_name(target)
	if has_target:
		return "⚔ 攻击目标 · %s" % _target_display_name(target)
	if a.garrison_point != Vector3.ZERO:
		if a.current_order == "move":
			return "🏰 驻守 · 返回驻扎点"
		return "🏰 驻守"
	if a.is_attack_moving or a.current_order == "attack_move":
		return "🎯 攻击移动"
	match a.current_order:
		"move":
			return "👣 移动"
		"gather":
			return "⛏ 采集"
		"deliver":
			return "📦 交付"
	if not a.command_queue.is_empty():
		return "📋 待执行指令 %d" % a.command_queue.size()
	return "空闲"

func _make_rtl_label() -> RichTextLabel:
	var l = RichTextLabel.new(); l.bbcode_enabled = true; l.fit_content = true; l.autowrap_mode = TextServer.AUTOWRAP_OFF
	l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	l.add_theme_color_override("default_color", UITheme.PARCHMENT)
	_set_rtl_font(l, _mobile_font(UITheme.FONT_XS))
	return l

# 批量生产条件：电脑端 Ctrl，手机端「批量生产」开关（没有键盘修饰键）
func _is_batch_produce() -> bool:
	return Input.is_key_pressed(KEY_CTRL) or (InputSource.use_mobile_ui() and GameSettings.mobile_batch_produce)

func _get_same_type_buildings(entity: Building) -> Array[Building]:
	var result: Array[Building] = []
	if _is_batch_produce() and _is_local_owned_entity(entity):
		# Ctrl: ALL player buildings of same type（只批量自己的建筑，队友建筑只读）
		var bm = get_tree().get_first_node_in_group("battle_manager")
		if bm and bm.has_node("Entities"):
			for e in bm.get_node("Entities").get_children():
				if e is Building and e.entity_id == entity.entity_id and e.team == entity.team and _is_local_owned_entity(e):
					result.append(e)
	else:
		result.append(entity)
	return result

# 队友单位只读：同队但不属于本地玩家时，只展示信息，不提供生产/升级/拆除入口
func _is_local_owned_entity(entity) -> bool:
	if entity == null or not is_instance_valid(entity):
		return false
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if not bm: return false
	if bm.has_method("is_local_player_owned"):
		return bm.is_local_player_owned(entity.owner_peer_id, entity.team)
	return entity.team == bm.get_host_team()

func update_info(entity):
	if entity == null or not is_instance_valid(entity) or entity.health <= 0:
		observed_entity = null
		visible = false
		return
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
			group_prefix += "[color=%s]T%d[/color] " % [UITheme.hex_str(UITheme.VERMILION), g]
	var nm = group_prefix + "%s  [color=%s]Lv.%d[/color]" % [
		UITheme.entity_emoji(entity.entity_id, entity.entity_type),
		UITheme.hex_str(UITheme.GOLD), entity.level]
	var readonly := not _is_local_owned_entity(entity)
	if batch_count > 1:
		nm += "  [color=%s][Ctrl + x%d][/color]" % [UITheme.hex_str(UITheme.ALERT_WARNING), batch_count]
	if readonly:
		nm += "  [color=%s]（队友 · 仅查看）[/color]" % UITheme.hex_str(UITheme.PARCHMENT)
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
	if entity is Army:
		t += "\n🧭 [color=%s]任务[/color]:  [color=white]%s[/color]" % [
			UITheme.hex_str(UITheme.SAPPHIRE), _army_task_text(entity)]
	stats_rtl.text = t

	# Always detach old upgrade box first (avoid deferred-deletion residue)
	var old_box = _vb.get_node_or_null("UpgradeInfoBox")
	if old_box:
		_vb.remove_child(old_box)
		old_box.queue_free()
	if entity is Building:
		# 拆除按钮（城堡不可拆；队友建筑只读）
		if demolish_btn:
			demolish_btn.visible = (entity.entity_id != 20) and not readonly
		if entity.can_upgrade() and not readonly:
			upgrade_btn.visible = true; upgrade_btn.text = "升级"
			if upgrade_btn.pressed.is_connected(_on_upgrade_pressed):
				upgrade_btn.pressed.disconnect(_on_upgrade_pressed)
			upgrade_btn.pressed.connect(_on_upgrade_pressed)

			var box = VBoxContainer.new(); box.name = "UpgradeInfoBox"; _vb.add_child(box)
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
				var btn = Button.new(); btn.text = ""
				if _is_mobile():
					btn.custom_minimum_size = Vector2(0, UILayout.dp(40.0))
					UITheme.apply_button(btn, UILayout.font_dp(13.0))
				else:
					btn.custom_minimum_size = Vector2(200, 40)
					UITheme.apply_button(btn, UITheme.FONT_SM)
				btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				var ok = true; var cs = []
				var lv = entity.level
				for res in uc.get("cost", {}):
					var base = uc["cost"][res]
					var scaled = int(base * (1.0 + (lv - 1) * 0.2))
					var need = scaled * batch_count
					var have = _get_res().get(res, 0)
					if have < need: ok = false
					cs.append({"res": res, "need": need})
				btn.disabled = (not ok) or readonly
				if readonly:
					btn.tooltip_text = "队友建筑仅可查看，无法下达生产命令"
				var rtl = RichTextLabel.new(); rtl.bbcode_enabled = true; rtl.fit_content = true; rtl.autowrap_mode = TextServer.AUTOWRAP_OFF
				rtl.mouse_filter = Control.MOUSE_FILTER_IGNORE
				rtl.anchor_left = 0; rtl.anchor_right = 1; rtl.anchor_top = 0; rtl.anchor_bottom = 1
				rtl.add_theme_color_override("default_color", UITheme.PARCHMENT)
				_set_rtl_font(rtl, _mobile_font(UITheme.FONT_SM))
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
		# 运载船：信息面板里直接给「上船 / 下船」，按钮上标出可上/下船人数
		if entity is Army and entity.entity_id == 9 and not readonly:
			_update_board_ui(entity)
		elif _board_box != null and is_instance_valid(_board_box):
			_board_box.visible = false
		if demolish_btn: demolish_btn.visible = false
	hp_bar.visible = true

func _on_upgrade_pressed():
	if not observed_entity or not is_instance_valid(observed_entity): return
	if not _is_local_owned_entity(observed_entity): return
	var n = 999 if Input.is_key_pressed(KEY_SHIFT) else 1
	# 升级已全局生效，只需升级当前建筑即可
	for _i in range(n):
		if not observed_entity.can_upgrade() or not observed_entity.perform_upgrade(battle): break

func _on_produce_pressed(unit_id: int):
	if not observed_entity or not is_instance_valid(observed_entity): return
	if not _is_local_owned_entity(observed_entity): return
	var n = 5 if Input.is_key_pressed(KEY_SHIFT) else 1
	var targets = _get_same_type_buildings(observed_entity) if _is_batch_produce() else [observed_entity]
	for b in targets:
		if not _is_local_owned_entity(b): continue
		for _i in range(n):
			if not b.try_produce(unit_id): break

# ==================== 运载船：上/下船 ====================
func _ensure_board_box() -> void:
	if _board_box != null and is_instance_valid(_board_box):
		return
	_board_box = VBoxContainer.new()
	_board_box.name = "BoardBox"
	_board_box.add_theme_constant_override("separation", 2)
	_vb.add_child(_board_box)

	_board_label = _make_rtl_label()
	_board_box.add_child(_board_label)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", int(UILayout.dp(4.0)) if _is_mobile() else 4)
	_board_box.add_child(row)

	_board_up_btn = Button.new()
	_board_up_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if _is_mobile():
		_board_up_btn.custom_minimum_size = Vector2(0, UILayout.dp(40.0))
		UITheme.apply_primary_button(_board_up_btn, UILayout.font_dp(12.0))
	else:
		_board_up_btn.custom_minimum_size = Vector2(90, 32)
		UITheme.apply_primary_button(_board_up_btn, UITheme.FONT_SM)
	_board_up_btn.pressed.connect(_on_board_up_pressed)
	row.add_child(_board_up_btn)

	_board_down_btn = Button.new()
	_board_down_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if _is_mobile():
		_board_down_btn.custom_minimum_size = Vector2(0, UILayout.dp(40.0))
		UITheme.apply_muted_button(_board_down_btn, UILayout.font_dp(12.0))
	else:
		_board_down_btn.custom_minimum_size = Vector2(90, 32)
		UITheme.apply_muted_button(_board_down_btn, UITheme.FONT_SM)
	_board_down_btn.pressed.connect(_on_board_down_pressed)
	row.add_child(_board_down_btn)

# 船旁边最近的陆地格：找得到说明船已靠岸（可以下船），全水返回 Vector3.ZERO
func _ship_shore_point(ship) -> Vector3:
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if bm == null:
		return Vector3.ZERO
	var base: Vector3 = ship.global_position
	for r in [1.2, 2.0, 3.0, 4.5, 6.0]:
		for i in 12:
			var ang: float = TAU * float(i) / 12.0
			var p := base + Vector3(cos(ang) * float(r), 0.0, sin(ang) * float(r))
			if int(bm.get_terrain_at(p)) != 2:
				return p
	return Vector3.ZERO

func _update_board_ui(ship) -> void:
	_ensure_board_box()
	_board_box.visible = true
	var bm = get_tree().get_first_node_in_group("battle_manager")
	var cap: int = int(ship.get_board_capacity()) if ship.has_method("get_board_capacity") else 8
	var boarded: int = int(ship.get_boarded_count())
	# 可上船单位：船周围 2.5 米内、还没上船的陆地单位（含农民等经济单位）
	var near: Array = []
	if bm:
		bm._ensure_cache_fresh()
		for u in bm._armies:
			if not is_instance_valid(u) or u == ship or u.health <= 0:
				continue
			if int(u.entity_id) == 9:
				continue
			var boarded_on = u.get("_boarded_on")
			if boarded_on != null and int(boarded_on) != -1:
				continue
			if u.global_position.distance_to(ship.global_position) > BOARD_RANGE:
				continue
			if int(bm.get_terrain_at(u.global_position)) == 2:
				continue
			near.append(u)
	_board_near_units = near
	_board_shore = _ship_shore_point(ship)

	_board_label.text = "🚢 [color=%s]船上[/color]: [color=white]%d / %d[/color]" % [
		UITheme.hex_str(UITheme.SAPPHIRE), boarded, cap]
	_board_up_btn.text = "⬆ 上船 (%d)" % near.size()
	_board_up_btn.disabled = near.is_empty() or boarded >= cap
	_board_up_btn.tooltip_text = "只有船周围 %.1f 米内的陆地单位能上船" % BOARD_RANGE
	_board_down_btn.text = "⬇ 下船 (%d)" % boarded
	_board_down_btn.disabled = boarded <= 0 or _board_shore == Vector3.ZERO
	_board_down_btn.tooltip_text = "船靠岸后才能下船"

func _on_board_up_pressed() -> void:
	var ship = observed_entity
	if ship == null or not is_instance_valid(ship) or not (ship is Army):
		return
	for u in _board_near_units:
		if is_instance_valid(u):
			ship.board_unit(u)
	update_info(ship)

func _on_board_down_pressed() -> void:
	var ship = observed_entity
	if ship == null or not is_instance_valid(ship) or not (ship is Army):
		return
	if _board_shore == Vector3.ZERO:
		return
	ship.unboard_at(_board_shore)
	update_info(ship)

var _refresh_timer: float = 0.0

func _process(delta):
	if not visible or observed_entity == null or not is_instance_valid(observed_entity) or observed_entity.health <= 0:
		return
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
	var old_box = _vb.get_node_or_null("UpgradeInfoBox")
	if old_box:
		_vb.remove_child(old_box)
		old_box.queue_free()
	visible = true
	observed_entity = null
	upgrade_btn.visible = false
	if demolish_btn: demolish_btn.visible = false
	produce_vbox.visible = true
	hp_bar.visible = false
	if hp_bar_bg: hp_bar_bg.visible = false
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
		if _is_mobile():
			btn.custom_minimum_size = Vector2(0, UILayout.dp(40.0))
		else:
			btn.custom_minimum_size = Vector2(200, 40)
		btn.toggle_mode = true
		UITheme.apply_row_button(btn, row_color)
		if _is_mobile():
			btn.add_theme_font_size_override("font_size", UILayout.font_dp(12.0))

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
	if not _is_local_owned_entity(observed_entity):
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

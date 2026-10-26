class_name ClientInfoPanel
extends Panel

@onready var upgrade_btn = $VBox/UpgradeBtn
@onready var produce_vbox = $VBox/ProduceVBox
@onready var close_btn = $CloseBtn

var name_rtl: RichTextLabel
var stats_rtl: RichTextLabel
var hp_bar: ColorRect
var hp_bar_bg: ColorRect = null
var observed_entity_id: int = -1
var renderer: ClientRenderer = null
var demolish_btn: Button = null
var repair_btn: Button = null
var resources: Dictionary = {}
var limits: Dictionary = {}
var population: Dictionary = {}

# ==================== 简略 / 详细 ====================
var detail_toggle: Button = null
var _detail_mode: bool = false
var _detail_view: Control = null
var _detail_scroll: ScrollContainer = null
var _detail_rtl: RichTextLabel = null
var _detail_content: VBoxContainer = null
var _detail_last_id: int = -1
var _detail_last_text: String = ""

const RC = {"wood": "green", "stone": "gray", "gold": "gold", "food": "orange", "oil": "saddlebrown"}

func _ready():
	visible = false
	# 与单机版信息面板同一套皇庭皮肤：暖黑底 + 金边
	add_theme_stylebox_override("panel", UITheme.panel_style(UITheme.RADIUS_LG, UITheme.BORDER_MED))
	custom_minimum_size = Vector2(200, 0)

	_swap_rtl("NameLabel"); _swap_rtl("StatsLabel")
	name_rtl = $VBox.get_node("NameLabel")
	stats_rtl = $VBox.get_node("StatsLabel")
	name_rtl.add_theme_font_size_override("font_size", UITheme.FONT_XL)
	name_rtl.add_theme_color_override("default_color", UITheme.PARCHMENT)
	name_rtl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stats_rtl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	stats_rtl.add_theme_color_override("default_color", UITheme.PARCHMENT)

	# 血条：黑色背景条 + 锚点前景（宽度 = 血量比例），与单机版一致
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

	# 修理按钮 — 建筑掉血后才出现；主城不可修，逻辑与命令卡一致。
	repair_btn = Button.new()
	repair_btn.name = "RepairBtn"
	repair_btn.text = "🔧 修理建筑"
	repair_btn.custom_minimum_size = Vector2(180, 36)
	repair_btn.visible = false
	repair_btn.pressed.connect(_on_repair_pressed)
	UITheme.apply_primary_button(repair_btn, UITheme.FONT_SM)
	$VBox.add_child(repair_btn)

	set_process(true)
	renderer = get_tree().get_first_node_in_group("client_renderer")
	$VBox.offset_top = _detail_top_offset()
	_build_detail_view()
	_build_detail_toggle()

func _is_mobile() -> bool:
	return InputSource.use_mobile_ui()

func _detail_top_offset() -> float:
	return UILayout.dp(24.0) if _is_mobile() else 36.0

func _build_detail_toggle() -> void:
	detail_toggle = Button.new()
	detail_toggle.name = "DetailToggle"
	detail_toggle.text = "详细" if _is_mobile() else "📖 详细"
	detail_toggle.focus_mode = Control.FOCUS_NONE
	detail_toggle.anchor_left = 0.0
	detail_toggle.anchor_right = 0.0
	detail_toggle.anchor_top = 0.0
	detail_toggle.anchor_bottom = 0.0
	if _is_mobile():
		detail_toggle.offset_left = UILayout.dp(5.0)
		detail_toggle.offset_top = UILayout.dp(4.0)
		detail_toggle.offset_right = UILayout.dp(59.0)
		detail_toggle.offset_bottom = UILayout.dp(22.0)
		detail_toggle.custom_minimum_size = Vector2(UILayout.dp(54.0), UILayout.dp(18.0))
		UITheme.apply_muted_button(detail_toggle, UILayout.font_dp(10.0))
	else:
		detail_toggle.offset_left = 14.0
		detail_toggle.offset_top = 2.0
		detail_toggle.offset_right = 108.0
		detail_toggle.offset_bottom = 30.0
		detail_toggle.custom_minimum_size = Vector2(94, 28)
		UITheme.apply_muted_button(detail_toggle, UITheme.FONT_XS)
	detail_toggle.z_index = 3
	detail_toggle.visible = false
	detail_toggle.pressed.connect(_on_detail_toggle_pressed)
	add_child(detail_toggle)

func _build_detail_view() -> void:
	_detail_view = Control.new()
	_detail_view.name = "DetailView"
	_detail_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_detail_view.offset_left = 8.0
	_detail_view.offset_top = _detail_top_offset()
	_detail_view.offset_right = -8.0
	_detail_view.offset_bottom = -8.0
	_detail_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_detail_view)

	_detail_scroll = ScrollContainer.new()
	_detail_scroll.name = "DetailScroll"
	_detail_scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_detail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_detail_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_detail_scroll.mouse_filter = Control.MOUSE_FILTER_IGNORE if _is_mobile() else Control.MOUSE_FILTER_STOP
	_detail_view.add_child(_detail_scroll)

	_detail_content = VBoxContainer.new()
	_detail_content.name = "DetailContent"
	_detail_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_detail_content.add_theme_constant_override("separation", 4)
	_detail_scroll.add_child(_detail_content)

	_detail_rtl = RichTextLabel.new()
	_detail_rtl.name = "DetailLabel"
	_detail_rtl.bbcode_enabled = true
	_detail_rtl.fit_content = true
	_detail_rtl.scroll_active = false
	_detail_rtl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail_rtl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_rtl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_detail_rtl.add_theme_color_override("default_color", UITheme.PARCHMENT)
	var font_size: int = UILayout.font_dp(12.0) if _is_mobile() else UITheme.FONT_SM
	for key in ["normal_font_size", "bold_font_size", "italics_font_size", "bold_italics_font_size", "mono_font_size"]:
		_detail_rtl.add_theme_font_size_override(key, font_size)
	_detail_content.add_child(_detail_rtl)
	_detail_view.visible = false

func _on_detail_toggle_pressed() -> void:
	_detail_mode = not _detail_mode
	_apply_detail_mode(true)

func _apply_detail_mode(force_reset: bool = false) -> void:
	var has_single: bool = observed_entity_id != -1
	if detail_toggle != null:
		detail_toggle.visible = has_single
		detail_toggle.text = ("简略" if _detail_mode else "详细") if _is_mobile() else ("📄 简略" if _detail_mode else "📖 详细")
	var show_detail: bool = _detail_mode and has_single
	if _detail_view != null:
		_detail_view.visible = show_detail
	$VBox.visible = not show_detail
	if show_detail:
		var reset: bool = force_reset or observed_entity_id != _detail_last_id
		if reset:
			_detail_last_id = observed_entity_id
		_refresh_detail_text(reset)

func _refresh_detail_text(reset_scroll: bool) -> void:
	if _detail_rtl == null or not is_instance_valid(_detail_rtl):
		return
	if observed_entity_id == -1:
		return
	if renderer == null:
		renderer = get_tree().get_first_node_in_group("client_renderer")
	if renderer == null:
		return
	var info: Dictionary = renderer.get_entity_info(observed_entity_id)
	if info.is_empty():
		return
	var text: String = EntityInfoText.detailed(int(info.get("entity_id", -1)), info)
	if text != _detail_last_text:
		_detail_last_text = text
		_detail_rtl.text = text
	if reset_scroll:
		_detail_scroll.scroll_vertical = 0
		_reset_detail_scroll_deferred()

func _reset_detail_scroll_deferred() -> void:
	if _detail_scroll != null and is_instance_valid(_detail_scroll):
		_detail_scroll.scroll_vertical = 0

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
	return UITheme.health_bar_color(pct)

func _hc(pct: float) -> String:
	return UITheme.hex_str(UITheme.health_bar_color(pct))

func _make_rtl_label() -> RichTextLabel:
	var l = RichTextLabel.new(); l.bbcode_enabled = true; l.fit_content = true; l.autowrap_mode = TextServer.AUTOWRAP_OFF
	l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	l.add_theme_color_override("default_color", UITheme.PARCHMENT)
	return l

func set_resources(res: Dictionary, lim: Dictionary, pop: Dictionary = {}):
	resources = res; limits = lim; population = pop

# 队友单位只读：同队但 owner 不是本地玩家时，只展示信息，不提供生产/升级/拆除入口
func _is_local_owned_info(info: Dictionary) -> bool:
	if info.is_empty(): return false
	if not renderer: return false
	if renderer.my_peer_id != -1:
		return int(info.get("owner_peer_id", -1)) == renderer.my_peer_id
	return int(info.get("team", -1)) == renderer.player_team

# ==================== 修理信息 ====================
# 已损比例：优先用快照里的权威值 repair_damage_ratio，老快照按 HP 现算
func _repair_damage_ratio(info: Dictionary) -> float:
	if info.has("repair_damage_ratio"):
		return clampf(float(info["repair_damage_ratio"]), 0.0, 1.0)
	var mhp := maxf(float(info.get("max_health", 1)), 1.0)
	return clampf(1.0 - float(info.get("health", 0)) / mhp, 0.0, 1.0)

# 修理费：优先读快照里的权威值 repair_cost（ClientRenderer 已按服务端同公式算好），
# 老快照缺字段时按「已损比例 × 原价，向上取整」本地兜底
func _repair_cost_from_info(info: Dictionary, ratio: float) -> Dictionary:
	var direct = info.get("repair_cost", {})
	if direct is Dictionary and not direct.is_empty():
		return direct
	var out := {}
	var cfg = EntityDatabase.get_config(int(info.get("entity_id", -1)))
	var base = cfg.get("cost", {})
	if base is Dictionary:
		for k in base:
			var v := int(ceil(float(base[k]) * ratio))
			if v > 0:
				out[k] = v
	return out

# 拼装修理文案：修理中进度 / 已损百分比 / 修理费（主城不可修，不显示）
func _repair_status_str(info: Dictionary) -> String:
	if int(info.get("entity_id", 0)) in [20, 53]:
		return ""
	if float(info.get("build_timer", 0.0)) > 0.0:
		return ""
	var ratio := _repair_damage_ratio(info)
	var rt := float(info.get("repair_timer", 0.0))
	var mrt := float(info.get("max_repair_time", 0.0))
	if rt > 0.0 and mrt > 0.0:
		var pct := clampf(1.0 - rt / mrt, 0.0, 1.0)
		return "\n🔧 [color=%s]修理中[/color]:  %.0f%%   已损: %.0f%%" % [UITheme.hex_str(UITheme.REPAIR_PROGRESS), 100.0 * pct, 100.0 * ratio]
	if ratio <= 0.001:
		return ""
	var cost := _repair_cost_from_info(info, ratio)
	var cost_txt := ""
	for res in ["wood", "stone", "gold", "oil"]:
		if int(cost.get(res, 0)) > 0:
			var need := int(cost[res])
			var have := int(resources.get(res, 0))
			var cc := "white" if have >= need else "red"
			cost_txt += "%s[color=%s]%d[/color] " % [UITheme.RESOURCE_ICONS.get(res, ""), cc, need]
	var out := "\n🔧 [color=%s]已损[/color]:  %.0f%%" % [UITheme.hex_str(UITheme.ALERT_WARNING), 100.0 * ratio]
	if not cost_txt.strip_edges().is_empty():
		out += "   修理费: %s" % cost_txt.strip_edges()
	if not bool(int(info.get("can_repair", 0))):
		out += "  [color=%s]（暂不可修）[/color]" % UITheme.hex_str(UITheme.VERMILION)
	return out

func update_info(entity_id: int):
	if not renderer: renderer = get_tree().get_first_node_in_group("client_renderer")
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
	var readonly := not _is_local_owned_info(info)
	var nm = group_prefix + "%s %s  [color=%s]Lv.%d[/color]" % [
		UITheme.entity_emoji(info.get("entity_id", -1), info.get("type", 2)),
		info["name"], UITheme.hex_str(UITheme.GOLD), info.get("level", 1)]
	if batch_count > 1:
		nm += "  [color=%s][Ctrl + x%d][/color]" % [UITheme.hex_str(UITheme.ALERT_WARNING), batch_count]
	if readonly:
		nm += "  [color=%s]（队友 · 仅查看）[/color]" % UITheme.hex_str(UITheme.PARCHMENT)
	name_rtl.text = nm

	var pct = float(info["health"]) / max(float(info["max_health"]), 1.0)
	hp_bar.color = _bc(pct)
	hp_bar.anchor_right = pct
	if hp_bar_bg: hp_bar_bg.visible = true
	hp_bar.visible = true

	# Construction / upgrade progress
	var hc = _hc(pct)
	var bt = info.get("build_timer", 0.0)
	var mbt = info.get("max_build_time", 0.0)
	var bt_str = ""
	if bt > 0 and mbt > 0:
		bt_str = "\n🔨 [color=orange]建造中[/color]:  %.0f%%" % (100.0 * (1.0 - bt / mbt))
	var ut = info.get("upgrade_timer", 0.0)
	var mut = info.get("max_upgrade_time", 0.0)
	if ut > 0 and mut > 0:
		bt_str += "\n⬆️ [color=purple]升级中[/color]:  %.0f%%" % (100.0 * (1.0 - ut / mut))
	# 修理状态只在建筑上展示（已损 / 修理中进度 / 修理费）
	if int(info.get("type", -1)) == 1:
		bt_str += _repair_status_str(info)
	var t = "❤️ [color=%s]HP[/color]:  [color=white]%d / %d[/color]%s\n" % [hc, info["health"], info["max_health"], bt_str]
	t += "⚔️ [color=%s]ATK[/color]:  [color=white]%d[/color]" % [UITheme.hex_str(UITheme.GOLD), info["attack"]]
	if info.get("melee_armor", 0) > 0 or info.get("shield_armor", 0) > 0:
		t += "\n⛓️ [color=%s]铠甲[/color]:  [color=white]%d[/color]  🛡️ [color=%s]盾牌[/color]:  [color=white]%d[/color]" % [UITheme.hex_str(UITheme.SAPPHIRE), info.get("melee_armor", 0), UITheme.hex_str(UITheme.STONE), info.get("shield_armor", 0)]
	t += "\n🎯 [color=%s]RANGE[/color]:  [color=white]%.1f[/color]" % [UITheme.hex_str(UITheme.GOLD), info.get("attack_range", 0.0)]
	t += "\n👟 [color=%s]SPEED[/color]:  [color=white]%.1f[/color]" % [UITheme.hex_str(UITheme.EMERALD), info.get("speed", 0.0)]
	stats_rtl.text = t

	# Always detach old upgrade box first (avoid deferred-deletion residue)
	var old_box = $VBox.get_node_or_null("UpgradeInfoBox")
	if old_box:
		$VBox.remove_child(old_box)
		old_box.queue_free()
	if info["type"] == 1:
		# 拆除按钮（城堡不可拆；队友建筑只读）
		if demolish_btn:
			demolish_btn.visible = (info.get("entity_id", 0) != 20) and not readonly
		_update_repair_ui(info, readonly)
		if info.get("can_upgrade", false) and not readonly:

			upgrade_btn.visible = true; upgrade_btn.text = "升级"
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
					l.text = "%s [color=%s]%s[/color]:  [color=%s]%d/%d[/color]" % [UITheme.RESOURCE_ICONS.get(res, ""), rc, UITheme.RESOURCE_NAMES.get(res, res), cc, need, have]
					box.add_child(l)

			if info.get("castle_level_required", 0) > 0 and info.get("current_castle_level", 1) < info["castle_level_required"]:
				var l = _make_rtl_label()
				l.text = "[color=red]🏰 需主城 Lv.%d[/color]" % info["castle_level_required"]
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
				var btn = Button.new(); btn.text = ""; UITheme.apply_button(btn, UITheme.FONT_SM); btn.custom_minimum_size = Vector2(200, 40); btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				var ok = population.get("current", 0) < population.get("max", 0); var cs = []
				var cost = prod.get("current_cost", uc.get("cost", {}))
				for res in cost:
					if cost[res] > 0:
						var need = cost[res] * batch_count
						var have = resources.get(res, 0)
						if have < need: ok = false
						cs.append({"res": res, "need": need, "have": have})
				btn.disabled = (not ok) or readonly
				if readonly:
					btn.tooltip_text = "队友建筑仅可查看，无法下达生产命令"
				var rtl = RichTextLabel.new(); rtl.bbcode_enabled = true; rtl.fit_content = true; rtl.autowrap_mode = TextServer.AUTOWRAP_OFF
				rtl.mouse_filter = Control.MOUSE_FILTER_IGNORE
				rtl.anchor_left = 0; rtl.anchor_right = 1; rtl.anchor_top = 0; rtl.anchor_bottom = 1
				rtl.add_theme_color_override("default_color", UITheme.PARCHMENT)
				rtl.add_theme_font_size_override("normal_font_size", UITheme.FONT_SM)
				var ct = ""
				for ci in cs:
					var rc = RC.get(ci.res, "white")
					var cc = "white" if ci.have >= ci.need else "red"
					ct += "%s[color=%s]%d[/color] " % [UITheme.RESOURCE_ICONS.get(ci.res, ""), cc, ci.need]
				rtl.text = "%s %s  [%s]" % [UITheme.entity_emoji(int(uc.get("id", -1)), int(uc.get("type", 2))), uc.get("name", "?"), ct.strip_edges()]
				btn.add_child(rtl)
				btn.pressed.connect(func(): _on_produce_pressed(prod["unit_id"]))
				produce_vbox.add_child(btn)
		else:
			produce_vbox.visible = false
	else:
		upgrade_btn.visible = false; produce_vbox.visible = false
		if demolish_btn: demolish_btn.visible = false
		if repair_btn: repair_btn.visible = false
		hp_bar.visible = false
	_apply_detail_mode()

func _update_repair_ui(info: Dictionary, readonly: bool) -> void:
	if repair_btn == null:
		return
	repair_btn.visible = false
	var eid := int(info.get("entity_id", -1))
	if readonly or eid in [20, 53]:
		return
	var ratio := _repair_damage_ratio(info)
	var under := float(info.get("repair_timer", 0.0)) > 0.0
	var busy := float(info.get("build_timer", 0.0)) > 0.0 or float(info.get("upgrade_timer", 0.0)) > 0.0
	if busy or (ratio <= 0.001 and not under):
		return
	repair_btn.visible = true
	var cost := _repair_cost_from_info(info, ratio)
	var can_click := bool(int(info.get("can_repair", 1))) if info.has("can_repair") else true
	if can_click and not under:
		for k in cost:
			if int(resources.get(k, 0)) < int(cost[k]):
				can_click = false
				break
	repair_btn.disabled = under or not can_click
	if under:
		var mrt := maxf(float(info.get("max_repair_time", 0.0)), 0.001)
		var pct := clampf(1.0 - float(info.get("repair_timer", 0.0)) / mrt, 0.0, 1.0)
		repair_btn.text = "🔧 修理中 %d%%" % int(pct * 100.0)
	else:
		repair_btn.text = "🔧 修理 %s" % _repair_cost_text(cost)
	var ctime := float(info.get("repair_time_total", 0.0))
	var tip := "修理残破建筑：修完回复到满血（主城不可修理）"
	tip += "\n费用：%s" % (_repair_cost_text(cost) if not cost.is_empty() else "免费")
	if ctime > 0.0:
		tip += "\n耗时：%.1f 秒" % ctime
	if under:
		tip += "\n状态：修理中"
	elif not can_click:
		tip += "\n状态：资源不足或附近有敌军，暂不可修"
	repair_btn.tooltip_text = tip

func _repair_cost_text(cost: Dictionary) -> String:
	var parts: Array[String] = []
	for res in ["wood", "stone", "gold", "oil"]:
		var need := int(cost.get(res, 0))
		if need > 0:
			parts.append("%s%d" % [UITheme.RESOURCE_ICONS.get(res, ""), need])
	return " ".join(parts) if not parts.is_empty() else "免费"

func _on_repair_pressed():
	if observed_entity_id == -1:
		return
	if not _is_local_owned_info(renderer.get_entity_info(observed_entity_id)):
		return
	NetworkManager.send_command.rpc_id(1, {
		"action": "repair",
		"building_id": observed_entity_id,
		"shift_held": Input.is_key_pressed(KEY_SHIFT),
	})
	# 快照回来前先本地置灰，避免连点重复下单
	if repair_btn:
		repair_btn.disabled = true
		repair_btn.text = "🔧 修理中…"
		repair_btn.tooltip_text = "修理已提交，等待服务端确认"

func _on_upgrade_pressed():
	if observed_entity_id == -1: return
	if not _is_local_owned_info(renderer.get_entity_info(observed_entity_id)): return
	var n = 5 if Input.is_key_pressed(KEY_SHIFT) else 1
	# 升级已全局生效，只需升级当前建筑即可
	for _i in range(n):
		NetworkManager.send_command.rpc_id(1, {"action": "upgrade", "building_id": observed_entity_id, "ctrl_held": false, "shift_held": Input.is_key_pressed(KEY_SHIFT)})

func _on_produce_pressed(unit_id: int):
	if observed_entity_id == -1: return
	if not _is_local_owned_info(renderer.get_entity_info(observed_entity_id)): return
	var n = 5 if Input.is_key_pressed(KEY_SHIFT) else 1
	var info = renderer.get_entity_info(observed_entity_id)
	if Input.is_key_pressed(KEY_CTRL):
		# Ctrl: ALL player buildings of same type (match single-player behavior)
		var target_eid = info.get("entity_id")
		var sent = false
		for node in renderer.entity_nodes.values():
			if not node.has_meta("snapshot_info"): continue
			var si = node.get_meta("snapshot_info")
			if not si: continue
			if si.get("entity_id") == target_eid and si.get("health", 0) > 0:
				if not _is_local_owned_info(si): continue
				for _i in range(n):
					NetworkManager.send_command.rpc_id(1, {"action": "produce", "building_id": si["id"], "unit_id": unit_id, "ctrl_held": true, "shift_held": Input.is_key_pressed(KEY_SHIFT)})
				sent = true
		if not sent:
			for _i in range(n):
				NetworkManager.send_command.rpc_id(1, {"action": "produce", "building_id": observed_entity_id, "unit_id": unit_id, "ctrl_held": true, "shift_held": Input.is_key_pressed(KEY_SHIFT)})
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
	if repair_btn: repair_btn.visible = false
	produce_vbox.visible = true
	hp_bar.visible = false
	if hp_bar_bg: hp_bar_bg.visible = false
	var old_box = $VBox.get_node_or_null("UpgradeInfoBox")
	if old_box:
		$VBox.remove_child(old_box)
		old_box.queue_free()
	name_rtl.text = "[color=%s]⚔️ 选中 %d 个单位[/color]" % [UITheme.hex_str(UITheme.GOLD), ids.size()]
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
		btn.custom_minimum_size = Vector2(200, 40)
		btn.toggle_mode = true
		UITheme.apply_row_button(btn, row_color)

		var lvl_text = " Lv.%d" % g["min_level"] if g["min_level"] == g["max_level"] else " Lv.%d~%d" % [g["min_level"], g["max_level"]]
		btn.text = "%s %d x %s%s" % [UITheme.entity_emoji(g["entity_id"], 2), g["count"], g["name"], lvl_text]

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
	_apply_detail_mode()
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
	if not _is_local_owned_info(renderer.get_entity_info(observed_entity_id)): return
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
	var ci = get_tree().get_first_node_in_group("client_input") as client_input
	if ci:
		ci.client_selected_ids.clear()
		ci._update_selection_visuals()
		ci.emit_signal("selection_changed", [])

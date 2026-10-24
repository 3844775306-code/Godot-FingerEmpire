class_name hud
extends Control

var _mobile_hud = null    # 移动端界面装配器（仅触屏设备创建）

# 最近一次快照下发的经济数据（统计面板用；原左下角资源卡已移除）
var _last_res: Dictionary = {}
var _last_limits: Dictionary = {}
var gather_counts: Dictionary = {}
var income_rate: Dictionary = {}

var attack_all_btn: Button
var retreat_all_btn: Button
var auto_attack_btn: Button
var rally_btn: Button

var player_nation: int = -1
var enemy_nation: int = -1

# ==================== 玩家单位统计面板（布局对齐单机版 HUD） ====================
var unit_stats_panel: Control = null
var unit_stats_visible: bool = true
var _stats_title: RichTextLabel
var _stats_bonus: Label
var _stats_mil_title: RichTextLabel
var _stats_bld_title: RichTextLabel
var _stats_eco_title: RichTextLabel
var _stats_mil_rtl: RichTextLabel
var _stats_bld_rtl: RichTextLabel
var _stats_eco_rtl: RichTextLabel
var _stats_pop_bar: ProgressBar
var _stats_pop_label: Label
var _stats_res_labels: Dictionary = {}
var _stats_res_bars: Dictionary = {}
var _stats_res_info: Dictionary = {}
var _stats_castle_bar: HealthBarControl
var _stats_castle_label: Label
var _cmd_panel: Panel = null
var _settings_btn: Button = null
var _unit_stats_timer: float = 1.0
# 统计面板折叠态：展开是完整面板，折叠后只留一条「资源 + 人口」胶囊（与单机版一致，默认折叠）
var _stats_collapsed: bool = true
var _stats_collapse_btn: Button = null
var _stats_capsule: Panel = null
var _capsule_pop_label: Label = null
var _capsule_res_labels: Dictionary = {}

# ==================== 警报系统 ====================
const MapPresets = preload("res://scripts/map/MapPresets.gd")
const ALERT_DANGER = UITheme.ALERT_DANGER
const ALERT_WARNING = UITheme.ALERT_WARNING
const ALERT_INFO = UITheme.ALERT_INFO
const ALERT_GROUP = UITheme.ALERT_GROUP

var _alert_label: Label = null
var _alert_bg: Panel = null
var _alert_timer: float = 0.0


func _get_nation_name(nation: int) -> String:
	match nation:
		RTSConfig.Nation.VIKING: return "维京"
		RTSConfig.Nation.ENGLAND: return "英格兰"
		RTSConfig.Nation.FRANCE: return "法兰西"
		RTSConfig.Nation.CHINA: return "中国"
		RTSConfig.Nation.HUNGARY: return "匈牙利"
		RTSConfig.Nation.JAPAN: return "日本"
		RTSConfig.Nation.BYZANTINE: return "拜占庭"
		_: return "未知"


# 国家特色：标题用短描述，下面一行用完整描述（与单机版 HUD 一致）
func _nation_trait_short(nation: int) -> String:
	return NationBonuses.get_trait_short(nation)

func _nation_trait_full(nation: int) -> String:
	return NationBonuses.get_trait_full(nation)


func set_nations(p_nation: int, e_nation: int):
	player_nation = p_nation
	enemy_nation = e_nation
	# 国家名与特性直接显示在统计面板标题里（单机版同款布局，不再单独放国家面板）
	if _stats_title and _stats_bonus:
		_refresh_stats_nation()


func _refresh_stats_nation() -> void:
	if _stats_title == null or _stats_bonus == null:
		return
	var nation: int = player_nation
	if nation < 0:
		var renderer = get_tree().get_first_node_in_group("client_renderer")
		if renderer:
			nation = int(renderer.my_nation)
	if nation < 0:
		_stats_title.text = "[color=#5af]👑 未知[/color]"
		_stats_bonus.text = ""
		return
	_stats_title.text = "[color=#5af]👑 %s[/color] · [color=#ffd34f]%s[/color]" % [_get_nation_name(nation), _nation_trait_short(nation)]
	_stats_bonus.text = _nation_trait_full(nation)


# ==================== 单位统计面板创建 ====================
	# 联机客户端结算时隐藏统计面板
func hide_stat_panels() -> void:
	unit_stats_visible = false
	if unit_stats_panel:
		unit_stats_panel.visible = false
	if _stats_capsule:
		_stats_capsule.visible = false

func _create_unit_stats_panel():
	unit_stats_panel = Control.new()
	unit_stats_panel.name = "PlayerUnitStats"
	unit_stats_panel.z_index = 100
	unit_stats_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 与单机版完全一致：左上角 600×560
	unit_stats_panel.position = Vector2(10, 10)
	unit_stats_panel.size = Vector2(600, 560)

	# 与单机版一致的暗色圆角底板 + 金边
	var bg = Panel.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg_style = StyleBoxFlat.new()
	bg_style.bg_color = Color(UITheme.INK, UITheme.ALPHA_BG)
	bg_style.corner_radius_top_left = 8
	bg_style.corner_radius_top_right = 8
	bg_style.corner_radius_bottom_left = 8
	bg_style.corner_radius_bottom_right = 8
	bg_style.border_width_left = 2
	bg_style.border_width_right = 2
	bg_style.border_width_top = 2
	bg_style.border_width_bottom = 2
	bg_style.border_color = Color(UITheme.GOLD, UITheme.ALPHA_BORDER)
	bg.add_theme_stylebox_override("panel", bg_style)
	unit_stats_panel.add_child(bg)

	var vb = VBoxContainer.new()
	vb.position = Vector2(12, 10)
	vb.custom_minimum_size = Vector2(576, 0)
	vb.add_theme_constant_override("separation", 4)
	unit_stats_panel.add_child(vb)

	# 标题：国家名 + 国家特色
	_stats_title = _make_stats_rtl()
	_stats_title.add_theme_font_size_override("font_size", 24)
	vb.add_child(_stats_title)

	_stats_bonus = Label.new()
	_stats_bonus.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_stats_bonus.custom_minimum_size = Vector2(576, 0)
	_stats_bonus.add_theme_font_size_override("font_size", 14)
	_stats_bonus.add_theme_color_override("font_color", Color(UITheme.PARCHMENT, 0.85))
	vb.add_child(_stats_bonus)

	# 人口
	var pop_hbox = HBoxContainer.new()
	pop_hbox.add_theme_constant_override("separation", 8)
	_stats_pop_label = Label.new()
	_stats_pop_label.add_theme_font_size_override("font_size", 16)
	_stats_pop_label.add_theme_color_override("font_color", Color.WHITE)
	_stats_pop_label.text = "👥 人口: 0/0"
	pop_hbox.add_child(_stats_pop_label)
	_stats_pop_bar = _make_stats_bar(Color(0.25, 0.65, 1.0))
	_stats_pop_bar.custom_minimum_size = Vector2(300, 8)
	pop_hbox.add_child(_stats_pop_bar)
	vb.add_child(pop_hbox)

	# 五项资源：图标 + 数值 + 细进度条（替代原左下角资源 HUD）
	var res_grid = GridContainer.new()
	res_grid.columns = 5
	res_grid.add_theme_constant_override("h_separation", 6)
	vb.add_child(res_grid)
	var res_cfg = [
		["gold", UITheme.RES_GOLD], ["wood", UITheme.RES_WOOD], ["stone", UITheme.RES_STONE],
		["food", UITheme.RES_FOOD], ["oil", UITheme.RES_OIL],
	]
	for rc in res_cfg:
		var key: String = rc[0]
		var col: Color = rc[1]
		var col_vb = VBoxContainer.new()
		col_vb.custom_minimum_size = Vector2(108, 0)
		var head = Label.new()
		head.text = "%s %s" % [UITheme.RESOURCE_ICONS.get(key, "◆"), UITheme.RESOURCE_NAMES.get(key, key)]
		head.add_theme_font_size_override("font_size", 13)
		head.add_theme_color_override("font_color", col)
		col_vb.add_child(head)
		var val = Label.new()
		val.add_theme_font_size_override("font_size", 16)
		val.add_theme_color_override("font_color", Color.WHITE)
		val.text = "0"
		col_vb.add_child(val)
		_stats_res_labels[key] = val
		var rbar = _make_stats_bar(col)
		rbar.custom_minimum_size = Vector2(100, 5)
		col_vb.add_child(rbar)
		_stats_res_bars[key] = rbar
		var info = Label.new()
		info.add_theme_font_size_override("font_size", 10)
		info.add_theme_color_override("font_color", Color(UITheme.PARCHMENT, 0.7))
		info.text = "0人 +0.0/s"
		col_vb.add_child(info)
		_stats_res_info[key] = info
		res_grid.add_child(col_vb)

	# 主城血量
	var castle_hbox = HBoxContainer.new()
	castle_hbox.add_theme_constant_override("separation", 8)
	_stats_castle_label = Label.new()
	_stats_castle_label.add_theme_font_size_override("font_size", 16)
	_stats_castle_label.add_theme_color_override("font_color", Color(UITheme.PARCHMENT))
	_stats_castle_label.text = "🏰 主城 0/0"
	castle_hbox.add_child(_stats_castle_label)
	_stats_castle_bar = HealthBarControl.new()
	_stats_castle_bar.custom_minimum_size = Vector2(320, 12)
	castle_hbox.add_child(_stats_castle_bar)
	vb.add_child(castle_hbox)

	# 经济（农民/采集船/商人/手推车/贸易车/运载船/官员）
	_stats_eco_title = _make_stats_section("💰 经济")
	vb.add_child(_stats_eco_title)
	_stats_eco_rtl = _make_stats_rtl()
	_stats_eco_rtl.add_theme_font_size_override("font_size", 14)
	vb.add_child(_stats_eco_rtl)

	# 军队（总数直接跟在分栏标题后）
	_stats_mil_title = _make_stats_section("⚔️ 军队")
	vb.add_child(_stats_mil_title)
	_stats_mil_rtl = _make_stats_rtl()
	_stats_mil_rtl.add_theme_font_size_override("font_size", 14)
	vb.add_child(_stats_mil_rtl)

	# 建筑
	_stats_bld_title = _make_stats_section("🏰 建筑")
	vb.add_child(_stats_bld_title)
	_stats_bld_rtl = _make_stats_rtl()
	_stats_bld_rtl.add_theme_font_size_override("font_size", 14)
	vb.add_child(_stats_bld_rtl)

	add_child(unit_stats_panel)
	_refresh_stats_nation()

	# 标题栏右上角的折叠按钮：收成资源/人口胶囊
	_stats_collapse_btn = Button.new()
	_stats_collapse_btn.name = "StatsCollapseButton"
	_stats_collapse_btn.text = "▴ 折叠"
	_stats_collapse_btn.position = Vector2(500, 8)
	_stats_collapse_btn.custom_minimum_size = Vector2(88, 30)
	UITheme.apply_muted_button(_stats_collapse_btn, UITheme.FONT_SM)
	_stats_collapse_btn.pressed.connect(_on_stats_collapse_pressed)
	unit_stats_panel.add_child(_stats_collapse_btn)
	_create_stats_capsule()
	# 默认折叠：开局只显示资源/人口胶囊，点一下再展开完整面板
	_set_stats_collapsed(true)

# 统计面板折叠：展开是完整面板，折叠后只留一条「资源 + 人口」胶囊
func _set_stats_collapsed(collapsed: bool) -> void:
	_stats_collapsed = collapsed
	if unit_stats_panel:
		unit_stats_panel.visible = (not collapsed) and unit_stats_visible
	if _stats_capsule:
		_stats_capsule.visible = collapsed and unit_stats_visible

func _on_stats_collapse_pressed() -> void:
	_set_stats_collapsed(true)

func _on_stats_capsule_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_set_stats_collapsed(false)

func _res_color_for(key: String) -> Color:
	match key:
		"gold": return UITheme.RES_GOLD
		"wood": return UITheme.RES_WOOD
		"stone": return UITheme.RES_STONE
		"food": return UITheme.RES_FOOD
		"oil": return UITheme.RES_OIL
	return Color.WHITE

func _update_stats_capsule(res: Dictionary, lim: Dictionary, pop: int, max_pop: int) -> void:
	if _capsule_pop_label:
		_capsule_pop_label.text = "👥 %d/%d" % [pop, max_pop]
	for rk in _capsule_res_labels.keys():
		var l: Label = _capsule_res_labels[rk]
		if l:
			var cur: int = int(res.get(rk, 0))
			l.text = "%s %d" % [UITheme.RESOURCE_ICONS.get(rk, ""), cur]
			# 资源满了字体变红：再采集就浪费
			var cap: int = int(lim.get(rk, 0))
			var full: bool = cap > 0 and cur >= cap
			l.add_theme_color_override("font_color", UITheme.ALERT_DANGER if full else _res_color_for(rk))

# 折叠后的胶囊：一行显示人口与五项资源，点击展开回完整统计面板
func _create_stats_capsule() -> void:
	_stats_capsule = Panel.new()
	_stats_capsule.name = "StatsCapsule"
	_stats_capsule.z_index = 100
	_stats_capsule.position = Vector2(10, 10)
	_stats_capsule.size = Vector2(600, 40)
	_stats_capsule.visible = false
	_stats_capsule.mouse_filter = Control.MOUSE_FILTER_STOP
	var st := StyleBoxFlat.new()
	st.bg_color = Color(UITheme.INK, UITheme.ALPHA_BG)
	st.set_corner_radius_all(8)
	st.set_border_width_all(2)
	st.border_color = Color(UITheme.GOLD, UITheme.ALPHA_BORDER)
	_stats_capsule.add_theme_stylebox_override("panel", st)
	var row := HBoxContainer.new()
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 12
	row.offset_right = -12
	row.add_theme_constant_override("separation", 14)
	_stats_capsule.add_child(row)
	_capsule_pop_label = Label.new()
	_capsule_pop_label.add_theme_font_size_override("font_size", 17)
	_capsule_pop_label.add_theme_color_override("font_color", Color.WHITE)
	_capsule_pop_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_capsule_pop_label.text = "👥 0/0"
	row.add_child(_capsule_pop_label)
	for rk in ["gold", "wood", "stone", "food", "oil"]:
		var l := Label.new()
		l.add_theme_font_size_override("font_size", 16)
		l.add_theme_color_override("font_color", _res_color_for(rk))
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.text = "0"
		row.add_child(l)
		_capsule_res_labels[rk] = l
	_stats_capsule.gui_input.connect(_on_stats_capsule_input)
	add_child(_stats_capsule)

func _make_stats_rtl() -> RichTextLabel:
	var r = RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = true
	r.add_theme_font_size_override("font_size", 14)
	return r

func _make_stats_bar(color: Color) -> ProgressBar:
	var b = ProgressBar.new()
	b.max_value = 100
	b.show_percentage = false
	var fs = StyleBoxFlat.new()
	fs.bg_color = color
	fs.corner_radius_top_left = 2
	fs.corner_radius_top_right = 2
	fs.corner_radius_bottom_left = 2
	fs.corner_radius_bottom_right = 2
	b.add_theme_stylebox_override("fill", fs)
	var bs = StyleBoxFlat.new()
	bs.bg_color = Color(0.08, 0.08, 0.08, 0.9)
	bs.corner_radius_top_left = 2
	bs.corner_radius_top_right = 2
	bs.corner_radius_bottom_left = 2
	bs.corner_radius_bottom_right = 2
	b.add_theme_stylebox_override("background", bs)
	return b

func _make_stats_section(title: String) -> RichTextLabel:
	var r = RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = true
	r.text = "[color=#5af]▸ %s[/color]" % title
	r.add_theme_font_size_override("font_size", 15)
	return r

# 更新单位统计（从 ClientRenderer 的 entity_nodes + 最近一次快照资源读取；布局与单机版一致）
func _update_unit_stats():
	if not unit_stats_panel or not unit_stats_visible:
		return

	var renderer = get_tree().get_first_node_in_group("client_renderer")
	if not renderer:
		return

	var my_peer_id: int = renderer.my_peer_id
	var my_team: int = renderer.my_team if my_peer_id != -1 else renderer.player_team
	if my_team == -1:
		return

	# 国家标题 / 国家特性
	_refresh_stats_nation()

	# 人口
	var pop: Dictionary = renderer.last_population if renderer.last_population else {"current": 0, "max": 0}
	if _stats_pop_label and _stats_pop_bar:
		_stats_pop_label.text = "👥 人口: %d/%d" % [int(pop.get("current", 0)), int(pop.get("max", 0))]
		_stats_pop_bar.value = minf(float(pop.get("current", 1)) / maxf(float(pop.get("max", 1)), 1.0) * 100.0, 100.0)
	# 折叠胶囊：人口 + 五项资源（只在折叠时刷新）
	if _stats_capsule and _stats_capsule.visible:
		_update_stats_capsule(_last_res, _last_limits, int(pop.get("current", 0)), int(pop.get("max", 0)))

	# 五项资源：当前/上限 + 采集人数 + 增速（接管原左下角资源 HUD 的信息）
	for key in ["gold", "wood", "stone", "food", "oil"]:
		var lbl: Label = _stats_res_labels.get(key)
		if lbl:
			lbl.text = "%d/%d" % [int(_last_res.get(key, 0)), int(_last_limits.get(key, 500))]
		var rb: ProgressBar = _stats_res_bars.get(key)
		if rb:
			rb.value = clampf(float(_last_res.get(key, 0)) / maxf(float(_last_limits.get(key, 500)), 1.0) * 100.0, 0.0, 100.0)
		var info: Label = _stats_res_info.get(key)
		if info:
			info.text = "%d人 %+.1f/s" % [int(gather_counts.get(key, 0)), float(income_rate.get(key, 0.0))]

	# 统计单位 - 从 entity_nodes 的 snapshot_info 中读取
	var unit_names = {
		5: "手推车", 6: "贸易车", 9: "运载船",
		10: "农民", 11: "步兵", 12: "弓箭手", 13: "战船", 14: "采集船",
		15: "骑兵", 16: "火炮", 17: "投石车", 18: "攻城车", 19: "侦察兵",
		30: "狂战士", 31: "长弓兵", 32: "法式骑兵", 33: "诸葛连弩",
		34: "象骑兵", 35: "长枪兵", 36: "重装步兵", 37: "重装弓箭手",
		38: "重装骑兵", 39: "炮艇", 40: "爆破船",
		43: "油商", 44: "木商", 45: "石商", 51: "食商",
		46: "县吏", 47: "上校", 48: "尚书", 49: "统帅", 50: "丞相",
		55: "僧侣", 56: "长老", 57: "宗师", 58: "连弩", 59: "巨型投石机",
		65: "日本武士", 66: "甲胄骑兵"
	}
	var building_names = {
		7: "桥", 8: "梯子",
		20: "主城", 21: "兵营", 22: "仓库", 23: "船坞", 24: "攻城车间",
		25: "箭塔", 26: "炮塔", 27: "城墙", 28: "民居", 29: "重装武器厂",
		41: "瞭望塔", 42: "书院", 52: "集市", 53: "城堡", 54: "修道院", 64: "炮台"
	}

	var unit_counts = {}
	var building_counts = {}
	var building_levels = {}
	var under_construction := 0
	var castle_info: Dictionary = {}

	for id in renderer.entity_nodes.keys():
		var node = renderer.entity_nodes[id]
		if not is_instance_valid(node): continue
		if not node.has_meta("snapshot_info"): continue
		var info = node.get_meta("snapshot_info")
		if not info: continue

		# 只统计自己的实体（2v2/3v3 按 peer，1v1 按队伍）
		var belongs := false
		if my_peer_id != -1:
			belongs = (int(info.get("owner_peer_id", -1)) == my_peer_id)
		else:
			belongs = (int(info.get("team", -1)) == my_team)
		if not belongs: continue
		if int(info.get("health", 0)) <= 0: continue

		var eid: int = int(info.get("entity_id", -1))
		var etype: int = int(info.get("type", -1))

		if etype == 2:  # Army
			unit_counts[eid] = unit_counts.get(eid, 0) + 1
		elif etype == 1:  # Building
			if int(info.get("build_timer", 0)) > 0:
				under_construction += 1
				continue
			building_counts[eid] = building_counts.get(eid, 0) + 1
			var lv: int = int(info.get("upgrade_level", info.get("level", 1)))
			if not building_levels.has(eid) or building_levels[eid] < lv:
				building_levels[eid] = lv
			if eid == 20 and castle_info.is_empty():
				castle_info = info

	# 主城血量（与单机版一致）
	if _stats_castle_bar and _stats_castle_label:
		if not castle_info.is_empty():
			var chp: float = float(castle_info.get("health", 0.0))
			var cmax: float = maxf(float(castle_info.get("max_health", chp)), 1.0)
			var ccolor: Color = renderer.my_color
			if ccolor == Color.WHITE:
				ccolor = UITheme.SAPPHIRE if my_team == RTSConfig.Team.BLUE else UITheme.VERMILION
			_stats_castle_bar.visible = true
			_stats_castle_bar.update_bar(chp, cmax, my_team, ccolor)
			_stats_castle_label.text = "🏰 主城 Lv.%d %d/%d" % [int(castle_info.get("upgrade_level", 1)), int(chp), int(cmax)]
		else:
			_stats_castle_bar.visible = false
			_stats_castle_label.text = "🏰 主城 已失守"

	# 军用 ID 与展示列表共用同一组，保证总数与明细一致
	var military_ids = [11, 12, 13, 15, 16, 17, 18, 19, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 55, 56, 57, 58, 59, 65, 66]
	var military_total := 0
	for uid in military_ids:
		military_total += int(unit_counts.get(uid, 0))
	var building_total := 0
	for bid in building_counts:
		building_total += int(building_counts[bid])
	var under_txt := ""
	if under_construction > 0:
		under_txt = "    [color=#caa]🏗️ 在建 %d[/color]" % under_construction
	if _stats_mil_title:
		_stats_mil_title.text = "[color=#5af]▸ ⚔️ 军队 %d[/color]" % military_total
	if _stats_bld_title:
		_stats_bld_title.text = "[color=#5af]▸ 🏰 建筑 %d[/color]%s" % [building_total, under_txt]

	# 经济单位（农民、采集船、商人、手推车、贸易车、运载船、官员）
	var eco_ids = [10, 14, 5, 6, 9, 43, 44, 45, 51, 46, 47, 48, 49, 50]
	var eco_total := 0
	var eco_lines = []
	for uid in eco_ids:
		var cnt: int = int(unit_counts.get(uid, 0))
		eco_total += cnt
		if cnt > 0:
			var name = unit_names.get(uid, str(uid))
			eco_lines.append("[color=#8c8]%s %s[/color]:[color=white]%d[/color]" % [UITheme.entity_emoji(uid, 2), name, cnt])
	if _stats_eco_title:
		_stats_eco_title.text = "[color=#5af]▸ 💰 经济 %d[/color]" % eco_total
	if _stats_eco_rtl:
		_stats_eco_rtl.text = "[color=gray](无经济单位)[/color]" if eco_lines.is_empty() else " ".join(eco_lines)

	# 战斗单位
	var military_lines = []
	for uid in military_ids:
		var cnt: int = int(unit_counts.get(uid, 0))
		if cnt > 0:
			var name = unit_names.get(uid, str(uid))
			military_lines.append("[color=#aaa]%s %s[/color]:[color=white]%d[/color]" % [UITheme.entity_emoji(uid, 2), name, cnt])
	if _stats_mil_rtl:
		_stats_mil_rtl.text = "[color=gray](无军队)[/color]" if military_lines.is_empty() else " ".join(military_lines)

	# 建筑统计
	var building_lines = []
	var building_order = [7, 8, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 41, 42, 52, 53, 54, 64]
	for bid in building_order:
		var cnt: int = int(building_counts.get(bid, 0))
		if cnt > 0:
			var lv: int = int(building_levels.get(bid, 1))
			var name = building_names.get(bid, str(bid))
			building_lines.append("[color=#888]%s【%d】%s[/color]:[color=white]%d[/color]" % [UITheme.entity_emoji(bid, 1), lv, name, cnt])

	if under_construction > 0:
		building_lines.append("[color=#caa]🏗️ 在建[/color]:[color=white]%d[/color]" % under_construction)

	if _stats_bld_rtl:
		_stats_bld_rtl.text = "[color=gray](无建筑)[/color]" if building_lines.is_empty() else " ".join(building_lines)


func _get_client_input_node():
	var input_node = get_tree().get_first_node_in_group("client_input")
	if not input_node:
		input_node = get_node_or_null("ClientRoot/ClientInput")
	return input_node

func _on_select_screen_pressed():
	var ci = _get_client_input_node()
	if ci and ci.has_method("select_screen_military"):
		ci.select_screen_military()

func _on_select_all_pressed():
	var ci = _get_client_input_node()
	if ci and ci.has_method("select_all_military"):
		ci.select_all_military()

func _on_retreat_screen_pressed():
	var ci = _get_client_input_node()
	if ci and ci.has_method("retreat_screen_units"):
		ci.retreat_screen_units()

func _on_rally_pressed():
	var input_node = get_tree().get_first_node_in_group("client_input")
	if not input_node:
		input_node = get_node_or_null("ClientRoot/ClientInput")
	if input_node:
		input_node.select_all_military()


func _get_player_resource(res: String) -> int:
	var renderer = get_tree().get_first_node_in_group("client_renderer")
	if renderer: return renderer.get_player_resource(res)
	return 0

func _input(event):
	if event is InputEventKey and event.pressed:
		match event.keycode:
			_: pass  # Space等由ClientInput统一处理

func _on_jump_to_alert():
	var minimap = get_node_or_null("../Minimap") as Minimap
	if minimap and minimap.has_latest_alert:
		var cam = get_viewport().get_camera_3d()
		if cam:
			var target = minimap.latest_alert_world_pos
			if cam.has_method("focus_on_ground"):
				cam.focus_on_ground(target)
			else:
				cam.global_position = Vector3(target.x, cam.global_position.y, target.z)
			minimap.has_latest_alert = false


func _on_attack_all_pressed():
	var ci = _get_client_input_node()
	if ci and ci.has_method("toggle_auto_attack"):
		ci.toggle_auto_attack()
		_on_auto_attack_changed(ci.auto_attack_on)


func _on_retreat_all_pressed():
	NetworkManager.send_command.rpc_id(1, {
		"action": "global_retreat",
		"selected_ids": []
	})


func show_alert_message(msg: String, color: Color = ALERT_DANGER):
	var mobile := InputSource.use_mobile_ui()
	if not _alert_label:
		# 皇庭横幅背景：暖黑底 + 警报色细边 + 顶部警报色强调条
		_alert_bg = Panel.new()
		# 文字标签
		_alert_label = Label.new()
		_alert_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_alert_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_alert_label.add_theme_color_override("font_outline_color", Color.BLACK)
		_alert_label.add_theme_constant_override("outline_size", 3)
		if mobile:
			# 手机端按 dp 放大并居中，且可点击跳转；
			# 位置固定在资源胶囊（左上，收起 42dp / 展开 72dp）下方，避免挡住资源数值
			var w: float = UILayout.dp(320.0)
			var h: float = UILayout.dp(40.0)
			var top_y: float = UILayout.dp(118.0)
			_alert_bg.anchor_left = 0.5; _alert_bg.anchor_right = 0.5
			_alert_bg.anchor_top = 0.0; _alert_bg.anchor_bottom = 0.0
			_alert_bg.offset_left = -w; _alert_bg.offset_right = w
			_alert_bg.offset_top = top_y; _alert_bg.offset_bottom = top_y + h
			_alert_bg.mouse_filter = Control.MOUSE_FILTER_STOP
			_alert_bg.gui_input.connect(_on_alert_gui_input)
			_alert_label.anchor_left = 0.5; _alert_label.anchor_right = 0.5
			_alert_label.anchor_top = 0.0; _alert_label.anchor_bottom = 0.0
			_alert_label.offset_left = -w; _alert_label.offset_right = w
			_alert_label.offset_top = top_y; _alert_label.offset_bottom = top_y + h
			_alert_label.add_theme_font_size_override("font_size", UILayout.font_dp(14.0))
			_alert_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		else:
			_alert_bg.position = Vector2(755, 196)
			_alert_bg.size = Vector2(810, 46)
			_alert_label.add_theme_font_size_override("font_size", UITheme.FONT_XXL)
			_alert_label.position = Vector2(760, 202)
			_alert_label.size = Vector2(800, 40)
		add_child(_alert_bg)
		add_child(_alert_label)
	_alert_label.text = msg
	_alert_label.add_theme_color_override("font_color", color)
	# 横幅边框色跟随警报类型（危险红 / 警告黄 / 信息绿 / 编队蓝）
	var ab := StyleBoxFlat.new()
	ab.bg_color = Color(UITheme.INK, 0.88)
	ab.set_corner_radius_all(UITheme.RADIUS_MD)
	ab.set_border_width_all(UITheme.BORDER_THIN)
	ab.border_color = Color(color, 0.5)
	ab.border_width_top = UITheme.BORDER_THICK
	_alert_bg.add_theme_stylebox_override("panel", ab)
	_alert_label.visible = true
	_alert_bg.visible = true
	_alert_timer = 3.0

# 点警报条：跳到警报位置
func _on_alert_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_on_jump_to_alert()
		_alert_timer = 0.0
		if _alert_label: _alert_label.visible = false
		if _alert_bg: _alert_bg.visible = false
		accept_event()

func _ready():
	# 与单机版一致：左上统计面板（含资源/人口/主城/经济/军队/建筑），原左下角资源 HUD 已移除
	_create_unit_stats_panel()

	# 电脑版左下角摇杆用不上：隐藏并停掉它的输入处理，避免抢占鼠标
	if not InputSource.use_mobile_ui():
		var parent_node := get_parent()
		var stick := parent_node.get_node_or_null("VirtualStick") if parent_node else null
		if stick is Control:
			stick.visible = false
			stick.set_process(false)
			stick.set_process_input(false)
			stick.set_process_unhandled_input(false)

	# 对局内设置入口：右上角小地图下方（画质 / 音量 / 退出；联机不提供暂停）
	_create_game_settings_button()

	# 全军指令：与单机版一致，5 个按钮统一放在半透明底板里（620,10）
	_cmd_panel = Panel.new()
	_cmd_panel.name = "GlobalCommandPanel"
	_cmd_panel.position = Vector2(620, 10)
	_cmd_panel.size = Vector2(662, 86)
	_cmd_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var cmd_style := StyleBoxFlat.new()
	cmd_style.bg_color = Color(0.0, 0.0, 0.0, 0.38)
	cmd_style.set_corner_radius_all(6)
	cmd_style.set_border_width_all(1)
	cmd_style.border_color = Color(UITheme.GOLD, 0.25)
	_cmd_panel.add_theme_stylebox_override("panel", cmd_style)
	add_child(_cmd_panel)

	var cmd_grid := GridContainer.new()
	cmd_grid.columns = 3
	cmd_grid.position = Vector2(8, 8)
	cmd_grid.add_theme_constant_override("h_separation", 8)
	cmd_grid.add_theme_constant_override("v_separation", 6)
	cmd_grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cmd_panel.add_child(cmd_grid)

	attack_all_btn = _make_cmd_button("全选屏幕军队 (F1)", _on_select_screen_pressed, false)
	retreat_all_btn = _make_cmd_button("全选所有军队 (Ctrl+F1)", _on_select_all_pressed, false)
	auto_attack_btn = _make_cmd_button("⚔️ 自动进攻：关 (F2)", _on_attack_all_pressed, true)
	var b_ret_screen = _make_cmd_button("屏幕军队撤退 (F3)", _on_retreat_screen_pressed, false)
	var b_ret_all = _make_cmd_button("所有军队撤退 (Ctrl+F3)", _on_retreat_all_pressed, false)
	for b in [attack_all_btn, retreat_all_btn, auto_attack_btn, b_ret_screen, b_ret_all]:
		cmd_grid.add_child(b)

	# 顶部中央偏右两行大字：第一行性能、第二行对局/网络信息（只保留这两条）
	# 桌面端偏右（0.675）避开左侧全局指令按钮与右上小地图；手机端顶部没按钮，保持居中
	var mobile := InputSource.use_mobile_ui()
	var center_anchor: float = 0.5 if mobile else 0.675
	var f1: int = UILayout.font_dp(12.0) if mobile else 24
	var f2: int = UILayout.font_dp(11.0) if mobile else 22
	var y1: float = UILayout.dp(76.0) if mobile else 6.0
	var line_h: float = UILayout.dp(18.0) if mobile else 34.0
	var half_w: float = UILayout.dp(336.0) if mobile else 560.0
	_top_top_y = y1
	_top_line_h = line_h
	var diag := CanvasLayer.new()
	diag.name = "TopInfoLayer"
	diag.layer = 90
	add_child(diag)
	_top_bg = Panel.new()
	_top_bg.name = "TopInfoBG"
	_top_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_top_bg.z_index = 89
	_top_bg.anchor_left = center_anchor
	_top_bg.anchor_right = center_anchor
	_top_bg.anchor_top = 0.0
	_top_bg.anchor_bottom = 0.0
	var bg_style := StyleBoxFlat.new()
	bg_style.bg_color = Color(0.0, 0.0, 0.0, 0.45)
	bg_style.set_corner_radius_all(int(UILayout.dp(6.0)))
	_top_bg.add_theme_stylebox_override("panel", bg_style)
	diag.add_child(_top_bg)
	_fps_label = _make_top_label(diag, "DiagFPS", y1, line_h, f1, half_w, center_anchor, Color.LIME_GREEN)
	_net_stat_label = _make_top_label(diag, "DiagInfo", y1 + line_h, line_h, f2, half_w, center_anchor, Color(1.0, 0.9, 0.3))
	# 游戏时间 / 延迟已并入第二行，不再单独显示
	_game_time_label = null
	_ping_label = null
	_update_top_bg()

	set_process(true)
	add_to_group("client_hud")
	call_deferred("_connect_client_input")

	# 移动端：装配触屏界面（桌面端不进入此分支）
	if InputSource.use_mobile_ui():
		_mobile_hud = MobileHUD.new()
		add_child(_mobile_hud)
		_mobile_hud.setup(self)

	# 服务器警报：走 NetworkManager 的可靠 RPC 信号（快照里的 alerts 已弃用，丢包就永久丢失）
	if NetworkManager.has_signal("client_alert_received"):
		if not NetworkManager.client_alert_received.is_connected(_on_server_alert):
			NetworkManager.client_alert_received.connect(_on_server_alert)

# 收到服务器警报：直接走本地播报条
func _on_server_alert(msg: String, color: Color) -> void:
	show_alert_message(msg, color)

func _make_cmd_button(text: String, cb: Callable, danger: bool) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(210, 30)
	if danger:
		UITheme.apply_danger_button(b, UITheme.FONT_MD)
	else:
		UITheme.apply_primary_button(b, UITheme.FONT_MD)
	b.pressed.connect(cb)
	return b

func _open_game_settings() -> void:
	if get_node_or_null("SettingsLayer/GameSettingsPanel"):
		return
	var panel: Control = preload("res://scripts/ui/GameSettingsPanel.gd").new()
	var layer := get_node_or_null("SettingsLayer")
	if layer == null:
		layer = CanvasLayer.new()
		layer.name = "SettingsLayer"
		layer.layer = 95
		add_child(layer)
	layer.add_child(panel)
	panel.call("setup", true, true)

# 对局内设置入口（联机版）：挂在独立 CanvasLayer 上，才能按视口做右上角锚点
func _create_game_settings_button() -> void:
	var layer := CanvasLayer.new()
	layer.name = "SettingsLayer"
	layer.layer = 95
	add_child(layer)
	_settings_btn = Button.new()
	_settings_btn.name = "GameSettingsButton"
	_settings_btn.text = "⚙ 设置"
	_settings_btn.anchor_left = 1.0
	_settings_btn.anchor_right = 1.0
	_settings_btn.anchor_top = 0.0
	_settings_btn.anchor_bottom = 0.0
	_settings_btn.offset_left = -200
	_settings_btn.offset_right = -8
	_settings_btn.offset_top = 208
	_settings_btn.offset_bottom = 248
	UITheme.apply_muted_button(_settings_btn, UITheme.FONT_MD)
	_settings_btn.pressed.connect(_open_game_settings)
	layer.add_child(_settings_btn)

func _connect_client_input():
	var ci = _get_client_input_node()
	if ci and ci.has_signal("auto_attack_changed"):
		if not ci.auto_attack_changed.is_connected(_on_auto_attack_changed):
			ci.auto_attack_changed.connect(_on_auto_attack_changed)
	if ci:
		_on_auto_attack_changed(ci.auto_attack_on)

func _on_auto_attack_changed(on: bool):
	if auto_attack_btn:
		auto_attack_btn.text = "⚔️ 自动进攻：%s (F2)" % ("开" if on else "关")


func update_data(resources: Dictionary, population: Dictionary, limits: Dictionary, p_gather_counts: Dictionary = {}, p_income_rate: Dictionary = {}):
	# 左下角资源 HUD 已删除：数据缓存下来，统一由左上统计面板每秒刷新展示
	_last_res = resources
	_last_limits = limits
	gather_counts = p_gather_counts
	income_rate = p_income_rate
	if _mobile_hud and is_instance_valid(_mobile_hud):
		_mobile_hud.update_data(resources, population, limits, p_gather_counts, p_income_rate)


var _fps_label: Label = null
var _game_time_label: Label = null
var _fps_update_timer: float = 0.5
var _client_time_acc: float = 0.0
# Network stats
var _snap_recv_count: int = 0
var _snap_recv_rate: int = 0
var _snap_lost_count: int = 0
var _last_snap_seq: int = -1
var _net_stat_timer: float = 1.0
var _ping_label: Label = null
var _net_stat_label: Label = null
var _ping_rtt: int = 0
var _top_bg: Panel = null
var _top_top_y: float = 6.0
var _top_line_h: float = 34.0

# 半透明底板按两行文字的实际宽度自适应
func _update_top_bg() -> void:
	if _top_bg == null or not is_instance_valid(_top_bg) or _fps_label == null:
		return
	var pad_x: float = UILayout.dp(10.0)
	var pad_y: float = UILayout.dp(4.0)
	var text_w: float = _fps_label.get_minimum_size().x
	if _net_stat_label:
		text_w = maxf(text_w, _net_stat_label.get_minimum_size().x)
	var w: float = text_w + pad_x * 2.0
	var h: float = _top_line_h * 2.0 + pad_y * 2.0
	var bg_top: float = maxf(_top_top_y - pad_y, 0.0)
	_top_bg.offset_left = -w * 0.5
	_top_bg.offset_right = w * 0.5
	_top_bg.offset_top = bg_top
	_top_bg.offset_bottom = bg_top + h

# 顶部中央的一行信息（挂在独立 CanvasLayer 上，锚点按视口算）
func _make_top_label(parent: CanvasLayer, node_name: String, top_y: float, line_h: float,
		font_size: int, half_w: float, center_anchor: float, color: Color) -> Label:
	var lb := Label.new()
	lb.name = node_name
	lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lb.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lb.anchor_left = center_anchor
	lb.anchor_right = center_anchor
	lb.anchor_top = 0.0
	lb.anchor_bottom = 0.0
	lb.offset_left = -half_w
	lb.offset_right = half_w
	lb.offset_top = top_y
	lb.offset_bottom = top_y + line_h
	lb.add_theme_font_size_override("font_size", font_size)
	lb.add_theme_color_override("font_color", color)
	lb.add_theme_color_override("font_outline_color", Color.BLACK)
	lb.add_theme_constant_override("outline_size", maxi(3, int(font_size * 0.2)))
	parent.add_child(lb)
	return lb

func _process(delta):
	# 同步自动进攻按钮状态（F2 可能由 ClientInput 直接触发）
	if auto_attack_btn:
		var ci = _get_client_input_node()
		if ci:
			var t = "⚔️ 自动进攻：%s (F2)" % ("开" if ci.auto_attack_on else "关")
			if auto_attack_btn.text != t:
				auto_attack_btn.text = t
	# 每秒更新一次单位统计
	_unit_stats_timer -= delta
	if _unit_stats_timer <= 0:
		_unit_stats_timer = 1.0
		_update_unit_stats()

	# 本地计时（联机没有可信的服务器时钟，用客户端累计时间显示）
	_client_time_acc += delta
	var t_min = int(_client_time_acc / 60)
	var t_sec = int(_client_time_acc) % 60
	# 顶部中央两行：第一行性能、第二行 AI/地图/时间/延迟/快照
	_fps_update_timer -= delta
	if _fps_update_timer <= 0:
		_fps_update_timer = 0.5
		if _fps_label:
			_fps_label.text = "FPS:%.0f" % Engine.get_frames_per_second()
		if _net_stat_label:
			var diff_names = ["简单", "普通", "困难", "地狱"]
			var dn = diff_names[clampi(GameSettings.ai_difficulty, 0, 3)]
			var map_name := String(MapPresets.get_info(GameSettings.map_id).get("name", "经典大陆"))
			var ping_txt := "%dms" % _ping_rtt if _ping_rtt > 0 else "--"
			_net_stat_label.text = "AI:%s | 地图:%s | 时间:%02d:%02d | 延迟:%s | 快照:%d/s" % [
				dn, map_name, t_min, t_sec, ping_txt, _snap_recv_rate
			]
		_update_top_bg()

	# 快照率每秒统计一次
	_net_stat_timer -= delta
	if _net_stat_timer <= 0:
		_net_stat_timer = 1.0
		_snap_recv_rate = _snap_recv_count
		_snap_recv_count = 0
	# Ping every 1s
	NetworkManager.ping_server.rpc_id(1, Time.get_ticks_msec())
	if _alert_label and _alert_timer > 0:
		_alert_timer -= delta
		if _alert_timer <= 0:
			_alert_label.visible = false
			if _alert_bg:
				_alert_bg.visible = false

class_name hud
extends Control

var _mobile_hud = null    # 移动端界面装配器（仅触屏设备创建）
var _last_portrait: bool = false
var _mobile_rebuild_pending: bool = false
var _cmd_research_btn: Button = null
var _top_info_suppressed: bool = false   # 打开移动端统计大屏时隐藏顶部信息
var _top_single_line: bool = false       # 顶部信息是否单行（桌面/手机横屏放胶囊右边）

# 最近一次快照下发的经济数据（统计面板用；原左下角资源卡已移除）
var _last_res: Dictionary = {}
var _last_limits: Dictionary = {}
var gather_counts: Dictionary = {}
var income_rate: Dictionary = {}

var attack_all_btn: Button
var retreat_all_btn: Button
var auto_attack_btn: Button
var quartermaster_btn: Button
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
# 全局指令底板：6 个按钮 2 行 × 3 列
const CMD_PANEL_W: float = 662.0
const CMD_PANEL_H: float = 82.0
var _unit_stats_timer: float = 1.0
# 统计面板折叠态：展开是完整面板，折叠后只留一条「资源 + 人口」胶囊（与单机版一致，默认折叠）
var _stats_collapsed: bool = true
var _stats_collapse_btn: Button = null
var _stats_capsule: Panel = null
var _capsule_pop_label: Label = null
var _capsule_res_labels: Dictionary = {}
var _capsule_row: HBoxContainer = null
const TributePanelScript = preload("res://scripts/ui/TributePanel.gd")
var _tribute_panel: Control = null

# ==================== 警报系统 ====================
const MapPresets = preload("res://scripts/map/MapPresets.gd")
const ALERT_DANGER = UITheme.ALERT_DANGER
const ALERT_WARNING = UITheme.ALERT_WARNING
const ALERT_INFO = UITheme.ALERT_INFO
const ALERT_GROUP = UITheme.ALERT_GROUP

var _alert_stack: VBoxContainer = null
var _alert_rows: Array = []      # [{ "rtl": RichTextLabel, "holder": PanelContainer, "life": float }]
# 同一条服务器警报可能同时走可靠 RPC 和快照兜底，按 alert_id 去重，避免重复播报。
var _seen_server_alert_ids: Dictionary = {}


func _get_nation_name(nation: int) -> String:
	match nation:
		RTSConfig.Nation.VIKING: return "维京"
		RTSConfig.Nation.ENGLAND: return "英格兰"
		RTSConfig.Nation.FRANCE: return "法兰西"
		RTSConfig.Nation.CHINA: return "中国"
		RTSConfig.Nation.HUNGARY: return "匈牙利"
		RTSConfig.Nation.JAPAN: return "日本"
		RTSConfig.Nation.BYZANTINE: return "拜占庭"
		RTSConfig.Nation.MONGOL: return "蒙古"
		RTSConfig.Nation.PERSIA: return "波斯"
		RTSConfig.Nation.SPAIN: return "西班牙"
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
	# 胶囊宽度跟随内容：开局数字短时紧凑，后期四五位数也不会被截断；
	# 位置与宽度统一交给顶部带布局，保证不会顶到居中的指令栏。
	if _capsule_row != null and _stats_capsule != null:
		var need: float = _capsule_row.get_combined_minimum_size().x + 32.0
		var rect := UILayout.top_capsule_rect(get_viewport().get_visible_rect().size, need)
		_stats_capsule.position = rect.position
		_stats_capsule.size = rect.size

# 折叠后的胶囊：一行显示人口与五项资源，点击展开回完整统计面板
func _create_stats_capsule() -> void:
	_stats_capsule = Panel.new()
	_stats_capsule.name = "StatsCapsule"
	_stats_capsule.z_index = 100
	_stats_capsule.position = Vector2(10, 10)
	_stats_capsule.size = Vector2(780, 52)
	_stats_capsule.visible = false
	_stats_capsule.mouse_filter = Control.MOUSE_FILTER_STOP
	var st := StyleBoxFlat.new()
	st.bg_color = Color(UITheme.INK, UITheme.ALPHA_BG)
	st.set_corner_radius_all(10)
	st.set_border_width_all(2)
	st.border_color = Color(UITheme.GOLD, UITheme.ALPHA_BORDER)
	_stats_capsule.add_theme_stylebox_override("panel", st)
	var row := HBoxContainer.new()
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 16
	row.offset_right = -16
	row.add_theme_constant_override("separation", 18)
	_stats_capsule.add_child(row)
	_capsule_row = row
	_capsule_pop_label = Label.new()
	_capsule_pop_label.add_theme_font_size_override("font_size", 21)
	_capsule_pop_label.add_theme_color_override("font_color", Color.WHITE)
	_capsule_pop_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_capsule_pop_label.text = "👥 0/0"
	row.add_child(_capsule_pop_label)
	for rk in ["gold", "wood", "stone", "food", "oil"]:
		var l := Label.new()
		l.add_theme_font_size_override("font_size", 20)
		l.add_theme_color_override("font_color", _res_color_for(rk))
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.text = "0"
		row.add_child(l)
		_capsule_res_labels[rk] = l
	var tribute_btn := Button.new()
	tribute_btn.text = "🤝 进贡"
	tribute_btn.custom_minimum_size = Vector2(82, 32)
	tribute_btn.vertical_icon_alignment = VERTICAL_ALIGNMENT_CENTER
	UITheme.apply_muted_button(tribute_btn, UITheme.FONT_SM)
	tribute_btn.tooltip_text = "向同队队友进贡资源（扣 20% 税）"
	tribute_btn.pressed.connect(_open_tribute_panel)
	row.add_child(tribute_btn)
	_stats_capsule.gui_input.connect(_on_stats_capsule_input)
	add_child(_stats_capsule)

func _open_tribute_panel() -> void:
	var renderer = get_tree().get_first_node_in_group("client_renderer")
	if renderer == null:
		return
	if _tribute_panel == null or not is_instance_valid(_tribute_panel):
		_tribute_panel = TributePanelScript.new()
		add_child(_tribute_panel)
	var roster: Dictionary = renderer.get("player_roster")
	_tribute_panel.setup(null, int(renderer.my_peer_id), roster, int(renderer.my_team))
	_tribute_panel.open()

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
		65: "日本武士", 66: "甲胄骑兵",
		67: "蒙古弓骑", 68: "长生军", 69: "方阵兵"
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
	var military_ids = [11, 12, 13, 15, 16, 17, 18, 19, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 55, 56, 57, 58, 59, 65, 66, 67, 68, 69]
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
			KEY_T:
				if not event.echo:
					_open_research_panel()
			_: pass  # Space等由ClientInput统一处理

func _update_research_button():
	if _cmd_research_btn == null or not is_instance_valid(_cmd_research_btn):
		return
	var cr = get_tree().get_first_node_in_group("client_renderer")
	var on: bool = GameSettings.is_research_mode() and cr != null and cr.has_method("ui_research_state")
	_cmd_research_btn.visible = on
	if not on:
		return
	var st: Dictionary = cr.ui_research_state()
	var age_name := TechTreeData.age_name(int(st.get("age", 0)))
	var cur: Dictionary = st.get("current", {})
	var short_text := "🔬 科研树"
	if cur.is_empty():
		_cmd_research_btn.text = "🔬 %s · 科研树 (T)" % age_name
	else:
		var pct: int = int(clampf(float(cur.get("elapsed", 0.0)) / maxf(float(cur.get("total", 1.0)), 0.1) * 100.0, 0.0, 100.0))
		_cmd_research_btn.text = "🔬 %s · %s %d%% (T)" % [age_name, String(cur.get("name", "")), pct]
		short_text = "🔬 科研 %d%%" % pct
	# 手机指令栏的科研树按钮同步进度（空间小，用短文案）
	var mh = _mobile_hud
	if mh != null and is_instance_valid(mh):
		var cb = mh.get("command_bar")
		if cb != null and is_instance_valid(cb) and cb.has_method("set_research_text"):
			cb.call("set_research_text", short_text)

# 科研树：客户端状态来自 ClientRenderer 的快照镜像，操作通过 RPC 发给主机。
func _open_research_panel():
	if not GameSettings.is_research_mode():
		return
	var cr = get_tree().get_first_node_in_group("client_renderer")
	if cr == null or not cr.has_method("ui_research_state"):
		return
	ResearchPanel.open(self, cr)

# 把镜头定位到某个世界坐标（战报点击跳转用）
func _jump_to_world(target: Vector3) -> void:
	var cam = get_viewport().get_camera_3d()
	if cam == null:
		return
	if cam.has_method("focus_on_ground"):
		cam.focus_on_ground(target)
	else:
		cam.global_position = Vector3(target.x, cam.global_position.y, target.z)

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

func _on_quartermaster_pressed():
	var ci = _get_client_input_node()
	if ci and ci.has_method("toggle_quartermaster"):
		ci.toggle_quartermaster()
		_on_quartermaster_changed(ci.quartermaster_on)

func _on_quartermaster_changed(on: bool):
	if quartermaster_btn:
		quartermaster_btn.text = "🧺 军需官：%s (F4)" % ("开" if on else "关")


func _on_retreat_all_pressed():
	NetworkManager.send_command.rpc_id(1, {
		"action": "global_retreat",
		"selected_ids": []
	})


# 战况栏：同时最多 3 条，新的在最下面最亮，旧的逐级变淡（与单机 HUD 一致）
const ALERT_MAX_ROWS: int = 3
const ALERT_LIFE: float = 3.4

func show_alert_message(msg: String, color: Color = ALERT_DANGER, teams = [], alert_kind: int = 0, is_castle: bool = false, nations: Array = [], alert_pos: Vector3 = Vector3.ZERO, source_owner: int = -1):
	var mobile := InputSource.use_mobile_ui()
	var team_list: Array = _normalize_alert_teams(teams)
	# 按设置过滤掉不关心的战报（主要是队友的建造/升级/生产）
	if _alert_is_filtered(team_list, alert_kind, is_castle, source_owner):
		return
	if _alert_stack == null:
		_alert_stack = VBoxContainer.new()
		_alert_stack.name = "AlertStack"
		_alert_stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_alert_stack.add_theme_constant_override("separation", 2 if mobile else 4)
		add_child(_alert_stack)
		_layout_alert_stack()

	# 每行一个半透明背景块：纯文字压在战场上读不清，但也不能变回实心黑条挡住战场
	var holder := PanelContainer.new()
	holder.mouse_filter = Control.MOUSE_FILTER_STOP
	holder.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(UITheme.INK, 0.62)
	sb.set_corner_radius_all(UITheme.RADIUS_MD)
	sb.border_width_left = 3
	sb.border_color = color
	var pad_x: int = int(UILayout.dp(9.0)) if mobile else 10
	sb.content_margin_left = float(pad_x)
	sb.content_margin_right = float(pad_x)
	sb.content_margin_top = 2.0
	sb.content_margin_bottom = 2.0
	holder.add_theme_stylebox_override("panel", sb)
	holder.gui_input.connect(_on_alert_gui_input.bind(holder))
	holder.set_meta("alert_pos", alert_pos)

	# 国家名和正文要两种颜色，普通 Label 做不到
	var row := RichTextLabel.new()
	row.bbcode_enabled = true
	row.fit_content = true
	row.scroll_active = false
	row.autowrap_mode = TextServer.AUTOWRAP_OFF
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_color_override("font_outline_color", Color.BLACK)
	row.add_theme_constant_override("outline_size", 3)
	row.text = _alert_bbcode(msg, color, team_list, nations)
	holder.add_child(row)
	_alert_stack.add_child(holder)
	_alert_rows.append({"rtl": row, "holder": holder, "life": ALERT_LIFE})
	while _alert_rows.size() > ALERT_MAX_ROWS:
		var old: Dictionary = _alert_rows.pop_front()
		var old_holder = old.get("holder")
		if is_instance_valid(old_holder):
			old_holder.queue_free()
	_refresh_alert_weights()

# 兼容单个队伍（int）与队伍数组两种写法；负数表示未知，直接丢弃
func _normalize_alert_teams(raw) -> Array:
	var out: Array = []
	if raw is int:
		if int(raw) >= 0:
			out.append(int(raw))
		return out
	if raw is Array:
		for t in raw:
			if int(t) >= 0 and not out.has(int(t)):
				out.append(int(t))
	return out

# 战报筛选：队友国家的建造/升级/生产默认不接收，主城升级例外；
# 科研完成默认接收，敌方科研永远不推送（避免泄露对手时代/科技进度）。
func _alert_is_filtered(teams: Array, alert_kind: int, is_castle: bool, source_owner: int = -1) -> bool:
	if alert_kind == GameSettings.AlertKind.RESEARCH:
		if teams.is_empty():
			return false
		var sender_team: int = int(teams[0])
		var my_team: int = _alert_my_team()
		if sender_team >= 0 and my_team >= 0 and sender_team != my_team:
			return true
		if source_owner < 0:
			return false
		var my_owner_id: int = _alert_my_owner()
		if my_owner_id >= 0 and source_owner == my_owner_id:
			return false
		return not GameSettings.alert_friendly_research
	if alert_kind != GameSettings.AlertKind.BUILD \
		and alert_kind != GameSettings.AlertKind.UPGRADE \
		and alert_kind != GameSettings.AlertKind.PRODUCE:
		return false
	if teams.is_empty():
		return false
	var sender: int = int(teams[0])
	if sender < 0:
		return false
	# 「自己」和「队友」要按 owner 区分：2v2/3v3 里 AI 队友与自己同队，
	# 只看 team 会把队友的动静当成自己的而永远显示，开关也就失效了。
	# owner 缺失（1v1 队伍级单位、旧数据）时按自己处理，保持原有行为。
	var my_owner: int = _alert_my_owner()
	if source_owner < 0 or (my_owner >= 0 and source_owner == my_owner):
		return false
	if alert_kind == GameSettings.AlertKind.UPGRADE and is_castle:
		return false
	match alert_kind:
		GameSettings.AlertKind.BUILD:
			return not GameSettings.alert_friendly_build
		GameSettings.AlertKind.UPGRADE:
			return not GameSettings.alert_friendly_upgrade
		GameSettings.AlertKind.PRODUCE:
			return not GameSettings.alert_friendly_produce
	return false

# 本地玩家的队伍号：科研战报要区分「敌方科研」和「队友科研」

# 消息前加国家前缀。一条战报可能同时涉及多个国家（例如「A 攻打 B」），
# 全部按同一规则着色：自己绿、同阵营友方蓝、敌方红，国家之间用箭头连接。
# nations 是服务器直接下发的国家索引（与 teams 一一对应时优先使用）：
# 2v2 里队友与自己同队但不同国，只靠 teams 会把队友的单位误标成自己的国家。
func _alert_bbcode(msg: String, color: Color, teams: Array, nations: Array = []) -> String:
	var out := ""
	var parts: Array = []
	for i in teams.size():
		var team: int = int(teams[i])
		var nation_name := ""
		var nation_idx: int = int(nations[i]) if i < nations.size() else -1
		if nation_idx >= 0 and nation_idx < ClientRenderer.NATION_LABELS.size():
			nation_name = String(ClientRenderer.NATION_LABELS[nation_idx])
		else:
			nation_name = _alert_nation_of_team(team)
		if nation_name.is_empty():
			continue
		parts.append("[color=#%s]【%s】[/color]" % [_alert_team_color(team).to_html(false), nation_name])
	if not parts.is_empty():
		out += "[color=#BBBBBB]→[/color]".join(parts)
		out += " "
	out += "[color=#%s]%s[/color]" % [color.to_html(false), msg.replace("[", "[lb]")]
	return out

func _alert_my_team() -> int:
	var r = get_tree().get_first_node_in_group("client_renderer")
	if r == null or not is_instance_valid(r):
		return -1
	if int(r.my_team) != -1:
		return int(r.my_team)
	return int(r.player_team)

# 自己这个玩家的 peer_id（用于区分「自己的建筑」和「同队队友的建筑」）
func _alert_my_owner() -> int:
	var r = get_tree().get_first_node_in_group("client_renderer")
	if r == null or not is_instance_valid(r):
		return -1
	return int(r.my_peer_id)

# 队伍 → 国家名。联机端只有 ClientRenderer 知道各国的分配，
# 拿不到映射时返回空串，调用方退化成不带前缀的纯消息。
func _alert_nation_of_team(team: int) -> String:
	var r = get_tree().get_first_node_in_group("client_renderer")
	if r == null or not is_instance_valid(r) or not r.has_method("get_team_nation"):
		return ""
	var n: int = int(r.get_team_nation(team))
	if n < 0 or n >= ClientRenderer.NATION_LABELS.size():
		return ""
	return String(ClientRenderer.NATION_LABELS[n])

# 自己 → 绿；同阵营友方 → 蓝；敌方与中立 → 红
func _alert_team_color(team: int) -> Color:
	if team < 0:
		return Color(1.0, 1.0, 1.0, 0.0)
	var me: int = _alert_my_team()
	var enemy: int = -1
	if me != -1:
		enemy = RTSConfig.Team.RED if me == RTSConfig.Team.BLUE else RTSConfig.Team.BLUE
	if team == me:
		return Color(0.35, 1.0, 0.45)
	if enemy != -1 and team != enemy:
		return Color(0.45, 0.72, 1.0)
	return Color(1.0, 0.38, 0.32)

func _refresh_alert_weights() -> void:
	var n: int = _alert_rows.size()
	var mobile := InputSource.use_mobile_ui()
	var base_size: int = UILayout.font_dp(12.5) if mobile else UITheme.FONT_LG
	var alphas: Array = [1.0, 0.70, 0.46]
	for i in range(n):
		var row: Dictionary = _alert_rows[i]
		var rtl = row.get("rtl")
		var holder = row.get("holder")
		if not is_instance_valid(rtl) or not is_instance_valid(holder):
			continue
		var age: int = n - 1 - i
		holder.modulate = Color(1.0, 1.0, 1.0, float(alphas[mini(age, alphas.size() - 1)]))
		rtl.add_theme_font_size_override("normal_font_size", maxi(base_size - age, base_size - 2))

func _clear_alert_rows() -> void:
	for row in _alert_rows:
		var holder = row.get("holder")
		if is_instance_valid(holder):
			holder.queue_free()
	_alert_rows.clear()

# 点任意一条战况：跳到该条战报对应的位置（没有位置信息时退回最新警报位置）并清空战况栏
func _on_alert_gui_input(event: InputEvent, holder = null) -> void:
	var clicked: bool = false
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		clicked = true
	elif event is InputEventScreenTouch and event.pressed:
		clicked = true
	if not clicked:
		return
	var alert_pos: Vector3 = Vector3.ZERO
	if holder != null and is_instance_valid(holder):
		alert_pos = holder.get_meta("alert_pos", Vector3.ZERO)
	_clear_alert_rows()
	if alert_pos != Vector3.ZERO:
		_jump_to_world(alert_pos)
	else:
		_on_jump_to_alert()
	accept_event()

func _ready():
	# 与单机版一致：左上统计面板（含资源/人口/主城/经济/军队/建筑），原左下角资源 HUD 已移除
	_create_unit_stats_panel()
	# 科研模式下指令底板多一行科研树按钮，底板高度跟着变
	UILayout.cmd_research_row = GameSettings.is_research_mode()

	# 电脑版左下角摇杆用不上：隐藏并停掉它的输入处理，避免抢占鼠标
	if not InputSource.use_mobile_ui():
		var parent_node := get_parent()
		var stick := parent_node.get_node_or_null("VirtualStick") if parent_node else null
		if stick is Control:
			stick.visible = false
			stick.set_process(false)
			stick.set_process_input(false)
			stick.set_process_unhandled_input(false)

	# 全军指令：与单机版一致，6 个按钮正好排成两排（3×2），统一放在半透明底板里（620,10）
	# 全局指令：6 个按钮排成 2 行 × 3 列（3×2），整块底板水平居中
	_cmd_panel = Panel.new()
	_cmd_panel.name = "GlobalCommandPanel"
	_cmd_panel.size = Vector2(CMD_PANEL_W, CMD_PANEL_H)
	_cmd_panel.position = Vector2((get_viewport().get_visible_rect().size.x - CMD_PANEL_W) * 0.5, 10)
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
	# 军需官 / 军队官开关已收进 ⚙ 设置面板（F4 仍可切换军需官）
	var b_ret_screen = _make_cmd_button("屏幕军队撤退 (F3)", _on_retreat_screen_pressed, false)
	var b_ret_all = _make_cmd_button("所有军队撤退 (Ctrl+F3)", _on_retreat_all_pressed, false)
	var b_settings = _make_cmd_button("⚙ 设置", _open_game_settings, false)
	for b in [attack_all_btn, retreat_all_btn, auto_attack_btn, b_ret_screen, b_ret_all, b_settings]:
		cmd_grid.add_child(b)

	# 科研树归入指令按钮栏（整行放在六个指令按钮下面），不再单独挂悬浮按钮。
	_cmd_research_btn = Button.new()
	_cmd_research_btn.name = "CmdResearchButton"
	_cmd_research_btn.text = "🔬 科研树 (T)"
	_cmd_research_btn.position = Vector2(8, 82)
	_cmd_research_btn.size = Vector2(UILayout.TOP_CMD_W - 16.0, 30)
	_cmd_research_btn.custom_minimum_size = _cmd_research_btn.size
	UITheme.apply_muted_button(_cmd_research_btn, UITheme.FONT_MD)
	_cmd_research_btn.pressed.connect(_open_research_panel)
	_cmd_research_btn.visible = GameSettings.is_research_mode()
	_cmd_panel.add_child(_cmd_research_btn)

	# 顶部两行信息：第一行性能、第二行对局/网络信息。
	# 位置不写死：桌面优先塞进指令栏与小地图之间的空档（放不下就落到指令栏正下方），
	# 手机横屏夹在资源胶囊与小地图之间，竖屏隐藏，统一由 _layout_top_info() 计算。
	var diag := CanvasLayer.new()
	diag.name = "TopInfoLayer"
	diag.layer = 90
	add_child(diag)
	_top_bg = Panel.new()
	_top_bg.name = "TopInfoBG"
	_top_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_top_bg.z_index = 89
	var bg_style := StyleBoxFlat.new()
	bg_style.bg_color = Color(0.0, 0.0, 0.0, 0.45)
	bg_style.set_corner_radius_all(int(UILayout.dp(6.0)))
	_top_bg.add_theme_stylebox_override("panel", bg_style)
	diag.add_child(_top_bg)
	_fps_label = _make_top_label(diag, "DiagFPS", 24 if not InputSource.use_mobile_ui() else UILayout.font_dp(10.5), Color.LIME_GREEN)
	_net_stat_label = _make_top_label(diag, "DiagInfo", 22 if not InputSource.use_mobile_ui() else UILayout.font_dp(9.5), Color(1.0, 0.9, 0.3))
	_top_line_h = UILayout.dp(18.0) if InputSource.use_mobile_ui() else 34.0
	# 游戏时间 / 延迟已并入第二行，不再单独显示
	_game_time_label = null
	_ping_label = null

	set_process(true)
	add_to_group("client_hud")
	call_deferred("_connect_client_input")

	# 移动端：装配触屏界面（桌面端不进入此分支）
	_last_portrait = UILayout.is_portrait()
	if get_viewport() != null:
		get_viewport().size_changed.connect(_on_viewport_size_changed)
	if InputSource.use_mobile_ui():
		_mobile_hud = MobileHUD.new()
		add_child(_mobile_hud)
		_mobile_hud.setup(self)
	_layout_top_band()

	# 服务器警报：走 NetworkManager 的可靠 RPC 信号（快照里的 alerts 已弃用，丢包就永久丢失）
	if NetworkManager.has_signal("client_alert_received"):
		if not NetworkManager.client_alert_received.is_connected(_on_server_alert):
			NetworkManager.client_alert_received.connect(_on_server_alert)

# 手机横竖屏切换：战斗不能重载场景，只重建 MobileHUD。
# 所有移动组件（资源胶囊/小地图/指令栏/信息面板）都在构建时按 dp 算尺寸，
# 重建一遍才能让竖屏的 6.3 倍 dp 生效。
func _on_viewport_size_changed() -> void:
	_layout_top_band()
	if not InputSource.use_mobile_ui():
		return
	var now := UILayout.is_portrait()
	if now == _last_portrait:
		return
	_last_portrait = now
	if _mobile_rebuild_pending:
		return
	_mobile_rebuild_pending = true
	call_deferred("_rebuild_mobile_hud_for_orientation")

func _rebuild_mobile_hud_for_orientation() -> void:
	_mobile_rebuild_pending = false
	if not is_inside_tree():
		return
	if _mobile_hud != null and is_instance_valid(_mobile_hud):
		remove_child(_mobile_hud)
		_mobile_hud.queue_free()
	_mobile_hud = MobileHUD.new()
	add_child(_mobile_hud)
	_mobile_hud.setup(self)
	_layout_top_band()

# 顶部带统一排布：资源胶囊 / 指令栏 / 小地图 / 顶部信息栏 / 科研入口 / 战况栏一次算好，
# 元素之间固定留出空隙，窄屏时信息栏自动改到指令栏下方，避免互相压住。
func _layout_top_band() -> void:
	var vp := get_viewport().get_visible_rect().size
	var mobile := InputSource.use_mobile_ui()
	if _cmd_panel != null:
		var cmd_rect := UILayout.top_cmd_rect(vp)
		_cmd_panel.position = cmd_rect.position
		_cmd_panel.size = cmd_rect.size
	if _stats_capsule != null and not mobile:
		var cap_rect := UILayout.top_capsule_rect(vp, _stats_capsule.size.x)
		_stats_capsule.position = cap_rect.position
		_stats_capsule.size = cap_rect.size
	if not mobile:
		var mm := get_node_or_null("../Minimap") as Control
		if mm != null:
			var mm_rect := UILayout.top_minimap_rect(vp)
			UILayout.place(mm, 1.0, 0.0, -UILayout.TOP_MARGIN - mm_rect.size.x,
					UILayout.TOP_MARGIN, -UILayout.TOP_MARGIN, UILayout.TOP_MARGIN + mm_rect.size.y)
	_layout_top_info()
	_layout_alert_stack()

# 移动端统计大屏打开时隐藏顶部信息栏（它是全屏模态，信息栏会压住关闭按钮）
func _on_stats_overlay_toggled(open: bool) -> void:
	if not is_inside_tree():
		return
	_top_info_suppressed = open
	_layout_top_info()

# 顶部信息栏：桌面与手机横屏缩成一行放资源胶囊右边（空档不够时自动压字号）；
# 手机竖屏例外，保留胶囊下方 3 行短句。
func _layout_top_info() -> void:
	if _top_bg == null or not is_instance_valid(_top_bg):
		return
	if _fps_label == null or _net_stat_label == null:
		return
	var vp := get_viewport().get_visible_rect().size
	var mobile_info := InputSource.use_mobile_ui()
	var cap := _capsule_rect_for_info()
	var rect := Rect2()
	var single := false
	if mobile_info:
		if UILayout.is_portrait():
			rect = UILayout.mobile_top_info_rect(cap, 3)
		else:
			rect = UILayout.mobile_info_right_rect(cap, 22.0)
			single = true
			if rect.size.x <= 0.0:
				rect = UILayout.mobile_top_info_rect(cap)
			# 空档不足退回胶囊下方时仍按一行排，字号继续压
	else:
		rect = UILayout.top_info_right_rect(vp, cap.position.x + cap.size.x, 48.0)
		single = true
		if rect.size.x <= 0.0:
			# 联机桌面资源胶囊更宽（780），胶囊与指令底板之间只剩约 120 设计像素，
			# 一行字压到最小也放不下，退到指令底板右侧、小地图左侧的顶部空档。
			var cmd := UILayout.top_cmd_rect(vp)
			var mm := UILayout.top_minimap_rect(vp)
			var left := cmd.position.x + cmd.size.x + 12.0
			var right := mm.position.x - 12.0
			if right - left >= 140.0:
				rect = Rect2(Vector2(left, UILayout.TOP_MARGIN), Vector2(right - left, 48.0))
			else:
				rect = UILayout.top_info_rect(vp)
	_top_single_line = single
	_top_rect = rect
	var show := rect.size.x > 0.0 and rect.size.y > 0.0 and not _top_info_suppressed
	_top_bg.visible = show
	_fps_label.visible = show
	_net_stat_label.visible = show and not single
	if not show:
		return
	var pad_x := UILayout.dp(8.0)
	var inner_w := rect.size.x - pad_x * 2.0
	_top_bg.position = rect.position
	_top_bg.size = rect.size
	_fps_label.position = rect.position + Vector2(pad_x, 0.0)
	_fps_label.size = Vector2(inner_w, rect.size.y)
	_fps_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	if single:
		# 单行：按文字实际宽度压字号，保证整行落在胶囊右侧空档里
		var f: Font = _fps_label.get_theme_font("font")
		if f == null:
			f = ThemeDB.fallback_font
		var fs: int = 18 if not mobile_info else UILayout.font_dp(9.5)
		while fs > 8 and f.get_string_size(_fps_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > inner_w:
			fs -= 1
		_fps_label.add_theme_font_size_override("font_size", fs)
		return
	# 竖屏手机：3 行（FPS + 网络/对局 2 行）
	_fps_label.add_theme_font_size_override("font_size", UILayout.font_dp(10.5))
	var line_h := rect.size.y / 3.0
	_fps_label.size = Vector2(inner_w, line_h)
	_net_stat_label.position = rect.position + Vector2(pad_x, line_h)
	_net_stat_label.size = Vector2(inner_w, line_h * 2.0)
	_net_stat_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_net_stat_label.add_theme_font_size_override("font_size", UILayout.font_dp(9.5))

# 顶部信息避让用胶囊矩形：手机取真实控件；桌面取左上角统计胶囊，取不到按 UILayout 兜底
func _capsule_rect_for_info() -> Rect2:
	if InputSource.use_mobile_ui():
		return _mobile_capsule_rect_ui()
	var vp := get_viewport().get_visible_rect().size
	if _stats_capsule != null and is_instance_valid(_stats_capsule) and _stats_capsule.visible:
		var cr: Rect2 = _stats_capsule.get_global_rect()
		if cr.size.x > 0.0:
			return cr
	return UILayout.top_capsule_rect(vp, UILayout.TOP_CAPSULE_MIN_W)

# 手机端资源胶囊矩形：优先取 MobileHUD 真实控件，取不到按 dp 规则兜底。
func _mobile_capsule_rect_ui() -> Rect2:
	if _mobile_hud != null and is_instance_valid(_mobile_hud):
		var cap = _mobile_hud.get("capsule")
		if cap is Control and (cap as Control).visible:
			var cr: Rect2 = (cap as Control).get_global_rect()
			if cr.size.x > 0.0:
				return cr
	var insets := UILayout.safe_insets()
	return Rect2(Vector2(insets.x + UILayout.dp(2.0), insets.y + UILayout.dp(2.0)),
		Vector2(UILayout.dp(UILayout.mobile_capsule_width_dp()), UILayout.dp(42.0)))

# 战况栏：桌面放指令底板正下方居中；手机横屏在胶囊下方，竖屏再往下让开小地图。
func _layout_alert_stack() -> void:
	if _alert_stack == null or not is_instance_valid(_alert_stack):
		return
	if InputSource.use_mobile_ui():
		var r := UILayout.mobile_alert_rect(_mobile_capsule_rect_ui(), 3)
		_alert_stack.anchor_left = 0.5
		_alert_stack.anchor_right = 0.5
		_alert_stack.anchor_top = 0.0
		_alert_stack.anchor_bottom = 0.0
		_alert_stack.offset_left = -r.size.x * 0.5
		_alert_stack.offset_right = r.size.x * 0.5
		_alert_stack.offset_top = r.position.y
		_alert_stack.offset_bottom = r.position.y
		return
	var rd := UILayout.top_alert_rect(get_viewport().get_visible_rect().size)
	_alert_stack.anchor_left = 0.0
	_alert_stack.anchor_right = 0.0
	_alert_stack.anchor_top = 0.0
	_alert_stack.anchor_bottom = 0.0
	_alert_stack.position = rd.position
	_alert_stack.custom_minimum_size = Vector2(rd.size.x, 0)
	_alert_stack.size = Vector2(rd.size.x, 0)

# 收到服务器警报：直接走本地播报条
func _on_server_alert(msg: String, color: Color, alert_id: int = 0, teams = [], alert_kind: int = 0, is_castle: bool = false, nations: Array = [], alert_pos: Vector3 = Vector3.ZERO, source_owner: int = -1) -> void:
	show_server_alert(msg, color, alert_id, teams, alert_kind, is_castle, nations, alert_pos, source_owner)

# 服务器警报统一入口：RPC 与快照兜底都会调用，按 id 去重；
# 危险/警告级警报补一次客户端本地音效（服务器端 AudioManager 不会在客户端播放）。
func show_server_alert(msg: String, color: Color, alert_id: int = 0, teams = [], alert_kind: int = 0, is_castle: bool = false, nations: Array = [], alert_pos: Vector3 = Vector3.ZERO, source_owner: int = -1) -> void:
	if alert_id > 0:
		if _seen_server_alert_ids.has(alert_id):
			return
		if _seen_server_alert_ids.size() > 512:
			_seen_server_alert_ids.clear()
		_seen_server_alert_ids[alert_id] = true
	if color == ALERT_DANGER or color == ALERT_WARNING:
		AudioManager.play_sfx("alert")
	show_alert_message(msg, color, teams, alert_kind, is_castle, nations, alert_pos, source_owner)

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

# 对局内设置面板（按钮本身在指令底板第二排最后一个；面板挂独立 CanvasLayer 才能全屏）
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
var _top_line_h: float = 34.0
var _top_rect: Rect2 = Rect2()

# 顶部信息栏的文字宽度不再决定底板尺寸：位置/尺寸由 _layout_top_info() 统一给，
# 文字超长时用省略号截断，避免把底板顶到指令栏或小地图上。
func _update_top_bg() -> void:
	_layout_top_info()

# 顶部信息行：左对齐、超长省略号截断；具体坐标由 _layout_top_info() 设置。
func _make_top_label(parent: CanvasLayer, node_name: String, font_size: int, color: Color) -> Label:
	var lb := Label.new()
	lb.name = node_name
	lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	lb.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lb.clip_text = true
	lb.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	lb.add_theme_font_size_override("font_size", font_size)
	lb.add_theme_color_override("font_color", color)
	lb.add_theme_color_override("font_outline_color", Color.BLACK)
	lb.add_theme_constant_override("outline_size", maxi(3, int(font_size * 0.2)))
	# 顶部底板 z_index=89；文字必须压在底板上方，否则会被半透明黑底盖住，
	# 视觉上就像字体变暗、和单机版不一致。
	lb.z_index = 90
	parent.add_child(lb)
	return lb

func _process(delta):
	_update_research_button()
	# 同步自动进攻按钮状态（F2 可能由 ClientInput 直接触发）
	if auto_attack_btn:
		var ci = _get_client_input_node()
		if ci:
			var t = "⚔️ 自动进攻：%s (F2)" % ("开" if ci.auto_attack_on else "关")
			if auto_attack_btn.text != t:
				auto_attack_btn.text = t
	if quartermaster_btn:
		var ci_qm = _get_client_input_node()
		if ci_qm:
			var tq = "🧺 军需官：%s (F4)" % ("开" if ci_qm.quartermaster_on else "关")
			if quartermaster_btn.text != tq:
				quartermaster_btn.text = tq
	# 每秒更新一次单位统计
	_unit_stats_timer -= delta
	if _unit_stats_timer <= 0:
		_unit_stats_timer = 1.0
		_update_unit_stats()

	# 本地计时（联机没有可信的服务器时钟，用客户端累计时间显示）
	_client_time_acc += delta
	var t_min = int(_client_time_acc / 60)
	var t_sec = int(_client_time_acc) % 60
	# 顶部信息：桌面两行（性能 / AI/地图/时间/延迟/快照）；
	# 手机四行：第一行 FPS，后三行放对局信息，长句拆行避免省略号。
	_fps_update_timer -= delta
	if _fps_update_timer <= 0:
		_fps_update_timer = 0.5
		var diff_names = ["简单", "普通", "困难", "地狱"]
		var dn = diff_names[clampi(GameSettings.ai_difficulty, 0, 3)]
		var map_name := String(MapPresets.get_info(GameSettings.map_id).get("name", "经典大陆"))
		var ping_txt := "%dms" % _ping_rtt if _ping_rtt > 0 else "--"
		if _fps_label:
			if _top_single_line:
				# 桌面/手机横屏一行：FPS + 对局/网络信息
				if InputSource.use_mobile_ui():
					_fps_label.text = "%dF %s %s %02d:%02d %s %d/s" % [
						Engine.get_frames_per_second(), dn, map_name, t_min, t_sec,
						ping_txt, _snap_recv_rate]
				else:
					_fps_label.text = "%dFPS | %s %s %02d:%02d | %s %d/s" % [
						Engine.get_frames_per_second(), dn, map_name, t_min, t_sec,
						ping_txt, _snap_recv_rate]
			else:
				_fps_label.text = "FPS:%.0f" % Engine.get_frames_per_second()
		if _net_stat_label:
			if _top_single_line:
				_net_stat_label.text = ""
			elif InputSource.use_mobile_ui():
				# 竖屏手机：网络/对局信息拆成两行
				_net_stat_label.text = "AI:%s 地图:%s 时间:%02d:%02d\n延迟:%s 快照:%d/s" % [
					dn, map_name, t_min, t_sec, ping_txt, _snap_recv_rate
				]
			else:
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
	# 战况栏计时：每行各自倒计时，到期的自己消失，剩下的重新分配明暗
	if not _alert_rows.is_empty():
		for i in range(_alert_rows.size() - 1, -1, -1):
			var row: Dictionary = _alert_rows[i]
			row["life"] = float(row.get("life", 0.0)) - delta
			if float(row["life"]) > 0.0:
				continue
			var holder = row.get("holder")
			if is_instance_valid(holder):
				holder.queue_free()
			_alert_rows.remove_at(i)
		_refresh_alert_weights()

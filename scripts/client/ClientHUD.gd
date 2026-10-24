class_name hud
extends Control

var _mobile_hud = null    # 移动端界面装配器（仅触屏设备创建）

var gold_label: Label
var wood_label: Label
var stone_label: Label
var food_label: Label
var oil_label: Label
var pop_label: Label
var res_bars: Dictionary = {}
var pop_bar: ProgressBar
var cli_res_name_lbls: Dictionary = {}
var cli_gather_timer: float = 0.0
var cli_income_timer: float = 0.0
var cli_res_snapshot: Dictionary = {}
var cli_res_income: Dictionary = {}
var cli_income_rate: Dictionary = {}
var gather_labels: Dictionary = {}
var res_snapshot: Dictionary = {}
var snapshot_timer: float = 0.0
var res_income: Dictionary = {"gold":0,"wood":0,"stone":0,"food":0,"oil":0} 

var attack_all_btn: Button
var retreat_all_btn: Button
var auto_attack_btn: Button
var rally_btn: Button

var nation_bonus_label: Label
var player_nation_label: Label
var enemy_nation_label: Label

var player_nation: int = -1
var enemy_nation: int = -1

# ==================== 玩家单位统计面板 ====================
var unit_stats_panel: Control = null
var unit_stats_visible: bool = true
var _stats_header_rtl: RichTextLabel
var _stats_mil_rtl: RichTextLabel
var _stats_bld_rtl: RichTextLabel
var _stats_pop_bar: ProgressBar
var _stats_pop_label: Label
var _toggle_stats_btn: Button
var _unit_stats_timer: float = 1.0

# ==================== 警报系统 ====================
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


func set_nations(p_nation: int, e_nation: int):
	player_nation = p_nation
	enemy_nation = e_nation
	player_nation_label.text = "👑 我方国家: %s" % _get_nation_name(p_nation)
	enemy_nation_label.text = "⚔️ 敌方国家: %s" % _get_nation_name(e_nation)


# ==================== 单位统计面板创建 ====================
func _create_stats_toggle_button():
	_toggle_stats_btn = Button.new()
	_toggle_stats_btn.name = "StatsToggleButton"
	_toggle_stats_btn.text = "📊 统计"
	_toggle_stats_btn.position = Vector2(10, 660)
	_toggle_stats_btn.toggle_mode = true
	_toggle_stats_btn.button_pressed = true
	_toggle_stats_btn.custom_minimum_size = Vector2(200, 50)
	UITheme.apply_muted_button(_toggle_stats_btn, UITheme.FONT_LG)
	_toggle_stats_btn.pressed.connect(_on_toggle_stats_pressed)
	add_child(_toggle_stats_btn)
	UITheme.hover_scale(_toggle_stats_btn)

func _on_toggle_stats_pressed():
	unit_stats_visible = _toggle_stats_btn.button_pressed
	if unit_stats_panel:
		unit_stats_panel.visible = unit_stats_visible

# 联机客户端结算时隐藏统计面板与切换按钮
func hide_stat_panels() -> void:
	unit_stats_visible = false
	if unit_stats_panel:
		unit_stats_panel.visible = false
	if _toggle_stats_btn:
		_toggle_stats_btn.button_pressed = false
		_toggle_stats_btn.visible = false

func _create_unit_stats_panel():
	unit_stats_panel = Control.new()
	unit_stats_panel.name = "PlayerUnitStats"
	unit_stats_panel.z_index = 100
	unit_stats_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	unit_stats_panel.position = Vector2(1960, 950)

	# 背景（皇庭卡：羊皮纸底 + 金边 + 顶部金强调条）
	var bg = Panel.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.add_theme_stylebox_override("panel", UITheme.card_style(UITheme.GOLD))
	unit_stats_panel.add_child(bg)

	var vb = VBoxContainer.new()
	vb.position = Vector2(10, 8)
	vb.add_theme_constant_override("separation", 2)
	unit_stats_panel.add_child(vb)

	# 标题
	var title = _make_stats_rtl()
	title.text = "[color=#C9A84C]👑 ◈ 我方军力统计[/color]"
	title.add_theme_font_size_override("font_size", 20)
	vb.add_child(title)

	# 人口
	var pop_hbox = HBoxContainer.new()
	_stats_pop_label = Label.new()
	_stats_pop_label.add_theme_font_size_override("font_size", 15)
	_stats_pop_label.add_theme_color_override("font_color", Color.WHITE)
	_stats_pop_label.text = "👥 人口: 0/0"
	pop_hbox.add_child(_stats_pop_label)

	_stats_pop_bar = _make_stats_bar(UITheme.RES_POP)
	_stats_pop_bar.custom_minimum_size = Vector2(200, 8)
	pop_hbox.add_child(_stats_pop_bar)
	vb.add_child(pop_hbox)

	# 军队
	vb.add_child(_make_stats_section("⚔️ 军队"))
	_stats_mil_rtl = _make_stats_rtl()
	_stats_mil_rtl.add_theme_font_size_override("font_size", 14)
	vb.add_child(_stats_mil_rtl)

	# 建筑
	vb.add_child(_make_stats_section("🏰 建筑"))
	_stats_bld_rtl = _make_stats_rtl()
	_stats_bld_rtl.add_theme_font_size_override("font_size", 14)
	vb.add_child(_stats_bld_rtl)

	# 添加到场景
	add_child(unit_stats_panel)
	unit_stats_panel.custom_minimum_size = Vector2(400, 0)
	unit_stats_panel.size = Vector2(420, 380)

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
	r.text = "[color=#C9A84C]▸ %s[/color]" % title
	r.add_theme_font_size_override("font_size", 15)
	return r

# 更新单位统计（从 ClientRenderer 的 entity_nodes 读取）
func _update_unit_stats():
	if not unit_stats_panel or not unit_stats_visible:
		return

	var renderer = get_tree().get_first_node_in_group("client_renderer")
	if not renderer:
		return

	var my_peer_id = renderer.my_peer_id
	var my_team = renderer.my_team if my_peer_id != -1 else renderer.player_team
	if my_team == -1:
		return

	# 更新人口
	var pop = renderer.last_population if renderer.last_population else {"current": 0, "max": 0}
	if _stats_pop_label and _stats_pop_bar:
		_stats_pop_label.text = "👥 人口: %d/%d" % [pop.get("current", 0), pop.get("max", 0)]
		_stats_pop_bar.value = min(float(pop.get("current", 1)) / max(pop.get("max", 1), 1) * 100, 100)

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
		20: "城堡", 21: "兵营", 22: "仓库", 23: "船坞", 24: "攻城车间",
		25: "箭塔", 26: "炮塔", 27: "城墙", 28: "民居", 29: "重装武器厂",
		41: "瞭望塔", 42: "书院", 52: "集市", 53: "城堡", 54: "修道院", 64: "炮台"
	}

	var unit_counts = {}
	var building_counts = {}
	var building_levels = {}
	var under_construction = 0

	for id in renderer.entity_nodes.keys():
		var node = renderer.entity_nodes[id]
		if not is_instance_valid(node): continue
		if not node.has_meta("snapshot_info"): continue
		var info = node.get_meta("snapshot_info")
		if not info: continue

		# Check if entity belongs to this player
		var belongs = false
		if my_peer_id != -1:
			belongs = (info.get("owner_peer_id", -1) == my_peer_id)
		else:
			belongs = (info.get("team", -1) == my_team)
		if not belongs: continue
		if info.get("health", 0) <= 0: continue

		var eid = info.get("entity_id", -1)
		var etype = info.get("type", -1)

		if etype == 2:  # Army
			unit_counts[eid] = unit_counts.get(eid, 0) + 1
		elif etype == 1:  # Building
			if info.get("build_timer", 0) > 0:
				under_construction += 1
				continue
			building_counts[eid] = building_counts.get(eid, 0) + 1
			var lv = info.get("upgrade_level", info.get("level", 1))
			if not building_levels.has(eid) or building_levels[eid] < lv:
				building_levels[eid] = lv

	# 军用 ID 与展示列表共用同一组，保证总数与明细一致
	var military_ids = [11, 12, 13, 15, 16, 17, 18, 19, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 55, 56, 57, 58, 59, 65, 66]
	var military_total = 0
	for uid in military_ids:
		military_total += unit_counts.get(uid, 0)

	var military_lines = []
	var eco_lines = []
	# 经济单位
	for uid in [10, 14, 5, 6, 9]:
		var cnt = unit_counts.get(uid, 0)
		if cnt > 0:
			var name = unit_names.get(uid, str(uid))
			eco_lines.append("[color=#8c8]%s %s[/color]:[color=white]%d[/color]" % [UITheme.entity_emoji(uid, 2), name, cnt])
	# 战斗单位
	for uid in military_ids:
		var cnt = unit_counts.get(uid, 0)
		if cnt > 0:
			var name = unit_names.get(uid, str(uid))
			military_lines.append("[color=#aaa]%s %s[/color]:[color=white]%d[/color]" % [UITheme.entity_emoji(uid, 2), name, cnt])

	# 商人
	var merchant_lines = []
	for uid in [43, 44, 45, 51]:
		var cnt = unit_counts.get(uid, 0)
		if cnt > 0:
			var name = unit_names.get(uid, str(uid))
			merchant_lines.append("[color=#ffa]%s %s[/color]:[color=white]%d[/color]" % [UITheme.entity_emoji(uid, 2), name, cnt])

	# 添加官员（如果有）
	var official_lines = []
	for uid in [46, 47, 48, 49, 50]:
		var cnt = unit_counts.get(uid, 0)
		if cnt > 0:
			var name = unit_names.get(uid, str(uid))
			official_lines.append("[color=#f8a]%s %s[/color]:[color=white]%d[/color]" % [UITheme.entity_emoji(uid, 2), name, cnt])

	if military_lines.is_empty() and official_lines.is_empty() and eco_lines.is_empty() and merchant_lines.is_empty():
		_stats_mil_rtl.text = "[color=gray](无军队)[/color]"
	else:
		var text = ""
		if not eco_lines.is_empty():
			text = " ".join(eco_lines)
		if not military_lines.is_empty():
			if text != "": text += "\n"
			text += "[color=#8cf]⚔️ 战斗: %d[/color] | " % military_total + " ".join(military_lines)
		if not merchant_lines.is_empty():
			if text != "": text += "\n"
			text += "[color=#ffa]🛒 商人:[/color] " + " ".join(merchant_lines)
		if not official_lines.is_empty():
			if text != "": text += "\n"
			text += "[color=#a8f]🎖️ 官员:[/color] " + " ".join(official_lines)
		_stats_mil_rtl.text = text if text != "" else "[color=gray](无军队)[/color]"

	# 构建建筑显示
	var building_lines = []
	var building_order = [7, 8, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 41, 42, 52, 53, 54, 64]
	for bid in building_order:
		var cnt = building_counts.get(bid, 0)
		if cnt > 0:
			var lv = building_levels.get(bid, 1)
			var name = building_names.get(bid, str(bid))
			building_lines.append("[color=#888]%s【%d】%s[/color]:[color=white]%d[/color]" % [UITheme.entity_emoji(bid, 1), lv, name, cnt])

	if under_construction > 0:
		building_lines.append("[color=#caa]🏗️ 在建[/color]:[color=white]%d[/color]" % under_construction)

	if building_lines.is_empty():
		_stats_bld_rtl.text = "[color=gray](无建筑)[/color]"
	else:
		_stats_bld_rtl.text = " ".join(building_lines)


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
			# 手机端按 dp 放大并居中，且可点击跳转
			var w: float = UILayout.dp(320.0)
			var h: float = UILayout.dp(40.0)
			_alert_bg.anchor_left = 0.5; _alert_bg.anchor_right = 0.5
			_alert_bg.anchor_top = 0.15
			_alert_bg.offset_left = -w; _alert_bg.offset_right = w
			_alert_bg.offset_top = -h * 0.5; _alert_bg.offset_bottom = h * 0.5
			_alert_bg.mouse_filter = Control.MOUSE_FILTER_STOP
			_alert_bg.gui_input.connect(_on_alert_gui_input)
			_alert_label.anchor_left = 0.5; _alert_label.anchor_right = 0.5
			_alert_label.anchor_top = 0.15
			_alert_label.offset_left = -w; _alert_label.offset_right = w
			_alert_label.offset_top = -h * 0.5; _alert_label.offset_bottom = h * 0.5
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
	# 创建资源标签（皇庭筹码：图标 + 名称 + 数值 + 采集速率 + 进度条）
	const RES_CFG = [
		{name="黄金", key="gold", color=UITheme.RES_GOLD},
		{name="木材", key="wood", color=UITheme.RES_WOOD},
		{name="石头", key="stone", color=UITheme.RES_STONE},
		{name="食物", key="food", color=UITheme.RES_FOOD},
		{name="石油", key="oil", color=UITheme.RES_OIL},
		{name="人口", key="pop", color=UITheme.RES_POP},
	]
	const ROW_H = 44; const ROW_W = 290
	var _res_lbls = {}

	for i in range(RES_CFG.size()):
		var cfg = RES_CFG[i]
		var y = 1100 + i * (ROW_H + 5)
		var col = cfg.color

		# 筹码卡背景：暖黑半透明 + 资源色细边 + 顶部资源色强调条
		var bg = Panel.new()
		bg.position = Vector2(6, y); bg.size = Vector2(ROW_W, ROW_H)
		var s := UITheme.panel_style(UITheme.RADIUS_MD, UITheme.BORDER_THIN, 0.78)
		s.border_color = Color(col, 0.4)
		s.border_width_top = 2
		bg.add_theme_stylebox_override("panel", s)
		add_child(bg)

		# 名称行：图标 + 资源名（update_data 会补充采集人数/速率）
		var nl = Label.new()
		nl.position = Vector2(14, y + 4); nl.text = "%s %s" % [UITheme.RESOURCE_ICONS.get(cfg.key, ""), cfg.name]
		nl.add_theme_font_size_override("font_size", UITheme.FONT_MD)
		nl.add_theme_color_override("font_color", col)
		nl.add_theme_color_override("font_outline_color", Color.BLACK)
		nl.add_theme_constant_override("outline_size", 1)
		add_child(nl)
		cli_res_name_lbls[cfg.key] = nl  # Store for later update

		# 数值行：当前/上限，右对齐
		var vl = Label.new()
		vl.position = Vector2(96, y + 4); vl.size = Vector2(ROW_W - 110, 22)
		vl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		vl.add_theme_font_size_override("font_size", UITheme.FONT_LG)
		vl.add_theme_color_override("font_color", UITheme.PARCHMENT)
		vl.add_theme_color_override("font_outline_color", Color.BLACK)
		vl.add_theme_constant_override("outline_size", 1)
		add_child(vl)
		_res_lbls[cfg.key] = vl

		# 采集信息行：人数 + 速率（小字灰色）
		var gl = Label.new()
		gl.position = Vector2(14, y + 26)
		gl.size = Vector2(ROW_W - 28, 14)
		gl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		gl.add_theme_color_override("font_color", UITheme.STONE)
		add_child(gl)
		gather_labels[cfg.key] = gl

		# 资源进度条：亮色 fill + 暖黑底细边
		var pbar = ProgressBar.new()
		pbar.position = Vector2(14, y + ROW_H - 9)
		pbar.size = Vector2(ROW_W - 28, 5)
		pbar.max_value = 100; pbar.show_percentage = false
		var fs := StyleBoxFlat.new(); fs.bg_color = col.lightened(0.1)
		fs.corner_radius_top_left = 3; fs.corner_radius_top_right = 3
		fs.corner_radius_bottom_left = 3; fs.corner_radius_bottom_right = 3
		pbar.add_theme_stylebox_override("fill", fs)
		var bs := StyleBoxFlat.new(); bs.bg_color = Color(0.06, 0.05, 0.04, 0.85)
		bs.corner_radius_top_left = 3; bs.corner_radius_top_right = 3
		bs.corner_radius_bottom_left = 3; bs.corner_radius_bottom_right = 3
		bs.set_border_width_all(1); bs.border_color = Color(col, 0.25)
		pbar.add_theme_stylebox_override("background", bs)
		add_child(pbar)
		match cfg.key:
			"gold": res_bars["gold"] = pbar
			"wood": res_bars["wood"] = pbar
			"stone": res_bars["stone"] = pbar
			"food": res_bars["food"] = pbar
			"oil": res_bars["oil"] = pbar
			"pop": pop_bar = pbar

	gold_label = _res_lbls["gold"]
	wood_label = _res_lbls["wood"]
	stone_label = _res_lbls["stone"]
	food_label = _res_lbls["food"]
	oil_label = _res_lbls["oil"]
	pop_label = _res_lbls["pop"]

	# 国家及加成面板（皇庭卡：羊皮纸底 + 金边 + 顶部金强调条）
	var nation_panel := Panel.new()
	nation_panel.position = Vector2(6, 316); nation_panel.size = Vector2(430, 168)
	nation_panel.add_theme_stylebox_override("panel", UITheme.card_style(UITheme.GOLD))
	add_child(nation_panel)

	player_nation_label = Label.new()
	player_nation_label.position = Vector2(16, 8)
	player_nation_label.add_theme_font_size_override("font_size", UITheme.FONT_XL)
	player_nation_label.add_theme_color_override("font_color", UITheme.SAPPHIRE.lightened(0.15))
	player_nation_label.add_theme_color_override("font_outline_color", Color.BLACK)
	player_nation_label.add_theme_constant_override("outline_size", 1)
	nation_panel.add_child(player_nation_label)

	enemy_nation_label = Label.new()
	enemy_nation_label.position = Vector2(16, 48)
	enemy_nation_label.add_theme_font_size_override("font_size", UITheme.FONT_XL)
	enemy_nation_label.add_theme_color_override("font_color", UITheme.VERMILION.lightened(0.1))
	enemy_nation_label.add_theme_color_override("font_outline_color", Color.BLACK)
	enemy_nation_label.add_theme_constant_override("outline_size", 1)
	nation_panel.add_child(enemy_nation_label)

	nation_bonus_label = Label.new()
	nation_bonus_label.position = Vector2(16, 92)
	nation_bonus_label.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	nation_bonus_label.add_theme_color_override("font_color", UITheme.PARCHMENT)
	nation_bonus_label.add_theme_color_override("font_outline_color", Color.BLACK)
	nation_bonus_label.add_theme_constant_override("outline_size", 1)
	nation_bonus_label.text = "加成:\n" + NationBonuses.get_description(GameSettings.player_nation)
	nation_panel.add_child(nation_bonus_label)

	# 全军指令：选择 / 自动进攻 / 撤退
	attack_all_btn = Button.new()
	attack_all_btn.text = "全选屏幕军队 (F1)"
	attack_all_btn.position = Vector2(10, 506)
	attack_all_btn.custom_minimum_size = Vector2(200, 44)
	UITheme.apply_primary_button(attack_all_btn, UITheme.FONT_LG)
	attack_all_btn.pressed.connect(_on_select_screen_pressed)
	add_child(attack_all_btn)

	retreat_all_btn = Button.new()
	retreat_all_btn.text = "全选所有军队 (Ctrl+F1)"
	retreat_all_btn.position = Vector2(220, 506)
	retreat_all_btn.custom_minimum_size = Vector2(200, 44)
	UITheme.apply_primary_button(retreat_all_btn, UITheme.FONT_LG)
	retreat_all_btn.pressed.connect(_on_select_all_pressed)
	add_child(retreat_all_btn)

	var b_auto = Button.new()
	b_auto.text = "⚔️ 自动进攻：关 (F2)"
	b_auto.position = Vector2(10, 560)
	b_auto.custom_minimum_size = Vector2(200, 44)
	UITheme.apply_danger_button(b_auto, UITheme.FONT_LG)
	b_auto.pressed.connect(_on_attack_all_pressed)
	add_child(b_auto)
	auto_attack_btn = b_auto

	var b_ret_screen = Button.new()
	b_ret_screen.text = "屏幕军队撤退 (F3)"
	b_ret_screen.position = Vector2(220, 560)
	b_ret_screen.custom_minimum_size = Vector2(200, 44)
	UITheme.apply_primary_button(b_ret_screen, UITheme.FONT_LG)
	b_ret_screen.pressed.connect(_on_retreat_screen_pressed)
	add_child(b_ret_screen)

	var b_ret_all = Button.new()
	b_ret_all.text = "所有军队撤退 (Ctrl+F3)"
	b_ret_all.position = Vector2(10, 614)
	b_ret_all.custom_minimum_size = Vector2(200, 44)
	UITheme.apply_primary_button(b_ret_all, UITheme.FONT_LG)
	b_ret_all.pressed.connect(_on_retreat_all_pressed)
	add_child(b_ret_all)

	# 创建单位统计面板
	_create_unit_stats_panel()

	# 创建切换按钮
	_create_stats_toggle_button()

	# FPS + 游戏时间显示
	_fps_label = Label.new()
	_fps_label.position = Vector2(1100, 8)
	_fps_label.add_theme_font_size_override("font_size", 16)
	_fps_label.add_theme_color_override("font_color", UITheme.EMERALD)
	add_child(_fps_label)

	# Network stats display
	_net_stat_label = Label.new()
	_net_stat_label.position = Vector2(1100, 48)
	_net_stat_label.add_theme_font_size_override("font_size", 14)
	_net_stat_label.add_theme_color_override("font_color", UITheme.STONE)
	add_child(_net_stat_label)
	_ping_label = Label.new()
	_ping_label.position = Vector2(1100, 65)
	_ping_label.add_theme_font_size_override("font_size", 14)
	_ping_label.add_theme_color_override("font_color", UITheme.SAPPHIRE.lightened(0.15))
	add_child(_ping_label)
	_game_time_label = Label.new()
	_game_time_label.position = Vector2(1100, 28)
	_game_time_label.add_theme_font_size_override("font_size", 16)
	_game_time_label.add_theme_color_override("font_color", Color.WHITE)
	add_child(_game_time_label)

	set_process(true)
	add_to_group("client_hud")
	call_deferred("_connect_client_input")

	# 移动端：装配触屏界面（桌面端不进入此分支）
	if InputSource.use_mobile_ui():
		_mobile_hud = MobileHUD.new()
		add_child(_mobile_hud)
		_mobile_hud.setup(self)

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


func update_data(resources: Dictionary, population: Dictionary, limits: Dictionary, gather_counts: Dictionary = {}, income_rate: Dictionary = {}):
	gold_label.text = "%d/%d" % [resources.get("gold", 0), limits.get("gold", 0)]
	wood_label.text = "%d/%d" % [resources.get("wood", 0), limits.get("wood", 0)]
	stone_label.text = "%d/%d" % [resources.get("stone", 0), limits.get("stone", 0)]
	food_label.text = "%d/%d" % [resources.get("food", 0), limits.get("food", 0)]
	oil_label.text = "%d/%d" % [resources.get("oil", 0), limits.get("oil", 0)]
	pop_label.text = "%d/%d" % [population.get("current", 0), population.get("max", 0)]

	# 名称行保持固定「图标 + 资源名」，采集人数/速率显示在独立速率行
	for rk in ["gold", "wood", "stone", "food", "oil"]:
		var nl = cli_res_name_lbls.get(rk)
		var gc = gather_counts.get(rk, 0)
		var rate = income_rate.get(rk, 0.0)
		if nl:
			nl.text = "%s %s" % [UITheme.RESOURCE_ICONS.get(rk, "◆"), UITheme.RESOURCE_NAMES.get(rk, rk)]
		var gl = gather_labels.get(rk)
		if gl:
			gl.text = "%d人  %+.1f/s" % [gc, rate]

	if pop_bar:
		pop_bar.value = min(float(population.get("current",1))/max(population.get("max",1),1)*100, 100)
	for rk in ["gold","wood","stone","food","oil"]:
		if res_bars.has(rk):
			var rv = resources.get(rk, 0)
			var rl = limits.get(rk, 500) if not limits.is_empty() else 500
			res_bars[rk].value = min(float(rv)/max(rl,1)*100, 100)
	if _mobile_hud and is_instance_valid(_mobile_hud):
		_mobile_hud.update_data(resources, population, limits, gather_counts, income_rate)


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

	# 本地计时
	_client_time_acc += delta
	var t_min = int(_client_time_acc / 60)
	var t_sec = int(_client_time_acc) % 60
	if _game_time_label:
		_game_time_label.text = "%02d:%02d" % [t_min, t_sec]
	# FPS + 游戏时间
	_fps_update_timer -= delta
	if _fps_update_timer <= 0 and _fps_label:
		_fps_update_timer = 0.5
		_fps_label.text = "FPS: %.0f  |  %02d:%02d" % [Engine.get_frames_per_second(), t_min, t_sec]

	# Network stats every 1 second
	_net_stat_timer -= delta
	if _net_stat_timer <= 0:
		_net_stat_timer = 1.0
		_snap_recv_rate = _snap_recv_count
		_snap_recv_count = 0
	_net_stat_label.text = "Snap: %d/s" % _snap_recv_rate
	# Ping every 1s
	NetworkManager.ping_server.rpc_id(1, Time.get_ticks_msec())
	if _ping_label:
		var pc = Color.GREEN if _ping_rtt < 60 else (Color.YELLOW if _ping_rtt < 120 else Color.RED)
		_ping_label.add_theme_color_override("font_color", pc)
		_ping_label.text = "Ping: %dms" % _ping_rtt if _ping_rtt > 0 else "Ping: --"
	if _alert_label and _alert_timer > 0:
		_alert_timer -= delta
		if _alert_timer <= 0:
			_alert_label.visible = false
			if _alert_bg:
				_alert_bg.visible = false

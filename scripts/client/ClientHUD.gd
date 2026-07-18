class_name hud
extends Control

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
const ALERT_DANGER = Color(1.0, 0.2, 0.1)
const ALERT_WARNING = Color(1.0, 0.8, 0.1)
const ALERT_INFO = Color(0.2, 1.0, 0.3)
const ALERT_GROUP = Color(0.3, 0.7, 1.0)

var _alert_label: Label = null
var _alert_bg: ColorRect = null
var _alert_timer: float = 0.0


func _get_nation_name(nation: int) -> String:
	match nation:
		RTSConfig.Nation.VIKING: return "维京"
		RTSConfig.Nation.ENGLAND: return "英格兰"
		RTSConfig.Nation.FRANCE: return "法兰西"
		RTSConfig.Nation.CHINA: return "中国"
		RTSConfig.Nation.HUNGARY: return "匈牙利"
		_: return "未知"


func set_nations(p_nation: int, e_nation: int):
	player_nation = p_nation
	enemy_nation = e_nation
	player_nation_label.text = "我方国家: %s" % _get_nation_name(p_nation)
	enemy_nation_label.text = "敌方国家: %s" % _get_nation_name(e_nation)


# ==================== 单位统计面板创建 ====================
func _create_stats_toggle_button():
	var btn_theme = Theme.new()
	btn_theme.set_font_size("font_size", "Button", 18)

	_toggle_stats_btn = Button.new()
	_toggle_stats_btn.text = "📊 统计"
	_toggle_stats_btn.position = Vector2(10, 660)
	_toggle_stats_btn.theme = btn_theme
	_toggle_stats_btn.toggle_mode = true
	_toggle_stats_btn.button_pressed = true
	_toggle_stats_btn.custom_minimum_size = Vector2(180, 50)
	_toggle_stats_btn.pressed.connect(_on_toggle_stats_pressed)
	add_child(_toggle_stats_btn)

func _on_toggle_stats_pressed():
	unit_stats_visible = _toggle_stats_btn.button_pressed
	if unit_stats_panel:
		unit_stats_panel.visible = unit_stats_visible

func _create_unit_stats_panel():
	unit_stats_panel = Control.new()
	unit_stats_panel.name = "PlayerUnitStats"
	unit_stats_panel.z_index = 100
	unit_stats_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	unit_stats_panel.position = Vector2(1960, 950)

	# 背景
	var bg = Panel.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg_style = StyleBoxFlat.new()
	bg_style.bg_color = Color(0.05, 0.06, 0.12, 0.88)
	bg_style.corner_radius_top_left = 8
	bg_style.corner_radius_top_right = 8
	bg_style.corner_radius_bottom_left = 8
	bg_style.corner_radius_bottom_right = 8
	bg_style.border_width_left = 2
	bg_style.border_width_right = 2
	bg_style.border_width_top = 2
	bg_style.border_width_bottom = 2
	bg_style.border_color = Color(0.2, 0.6, 1.0, 0.5)
	bg.add_theme_stylebox_override("panel", bg_style)
	unit_stats_panel.add_child(bg)

	var vb = VBoxContainer.new()
	vb.position = Vector2(10, 8)
	vb.add_theme_constant_override("separation", 2)
	unit_stats_panel.add_child(vb)

	# 标题
	var title = _make_stats_rtl()
	title.text = "[color=#5af]◈ 我方军力统计[/color]"
	title.add_theme_font_size_override("font_size", 20)
	vb.add_child(title)

	# 人口
	var pop_hbox = HBoxContainer.new()
	_stats_pop_label = Label.new()
	_stats_pop_label.add_theme_font_size_override("font_size", 15)
	_stats_pop_label.add_theme_color_override("font_color", Color.WHITE)
	_stats_pop_label.text = "人口: 0/0"
	pop_hbox.add_child(_stats_pop_label)

	_stats_pop_bar = _make_stats_bar(Color(0.25, 0.65, 1.0))
	_stats_pop_bar.custom_minimum_size = Vector2(200, 8)
	pop_hbox.add_child(_stats_pop_bar)
	vb.add_child(pop_hbox)

	# 军队
	vb.add_child(_make_stats_section("军队"))
	_stats_mil_rtl = _make_stats_rtl()
	_stats_mil_rtl.add_theme_font_size_override("font_size", 14)
	vb.add_child(_stats_mil_rtl)

	# 建筑
	vb.add_child(_make_stats_section("建筑"))
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
	r.text = "[color=#5af]▸ %s[/color]" % title
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
		_stats_pop_label.text = "人口: %d/%d" % [pop.get("current", 0), pop.get("max", 0)]
		_stats_pop_bar.value = min(float(pop.get("current", 1)) / max(pop.get("max", 1), 1) * 100, 100)

	# 统计单位 - 从 entity_nodes 的 snapshot_info 中读取
	var unit_names = {
		10: "农民", 11: "步兵", 12: "弓箭手", 13: "战船", 14: "采集船",
		15: "骑兵", 16: "火炮", 17: "投石车", 18: "攻城车", 19: "侦察兵",
		30: "狂战士", 31: "长弓兵", 32: "法式骑兵", 33: "诸葛连弩",
		34: "象骑兵", 35: "长枪兵", 36: "重装步兵", 37: "重装弓箭手",
		38: "重装骑兵", 39: "炮艇", 40: "快艇",
		43: "油商", 44: "木商", 45: "石商",
		46: "县吏", 47: "上校", 48: "尚书", 49: "统帅", 50: "丞相"
	}
	var building_names = {
		20: "城堡", 21: "兵营", 22: "仓库", 23: "船坞", 24: "攻城车间",
		25: "箭塔", 26: "炮塔", 27: "城墙", 28: "民居", 29: "重装武器厂",
		41: "瞭望塔", 42: "书院"
	}

	var unit_counts = {}
	var building_counts = {}
	var building_levels = {}

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
			building_counts[eid] = building_counts.get(eid, 0) + 1
			var lv = info.get("upgrade_level", info.get("level", 1))
			if not building_levels.has(eid) or building_levels[eid] < lv:
				building_levels[eid] = lv

	# 构建军队显示（排除农民、采集船、官员）
	var military_total = 0
	for uid in unit_counts.keys():
		if uid != 10 and uid != 14 and uid not in [46, 47, 48, 49, 50]:
			military_total += unit_counts[uid]

	var military_lines = []
	var eco_lines = []
	# 经济单位
	for uid in [10, 14]:
		var cnt = unit_counts.get(uid, 0)
		if cnt > 0:
			var name = unit_names.get(uid, str(uid))
			eco_lines.append("[color=#8c8]%s[/color]:[color=white]%d[/color]" % [name, cnt])
	# 战斗单位
	var unit_order = [11, 12, 15, 16, 17, 18, 19, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40]
	for uid in unit_order:
		var cnt = unit_counts.get(uid, 0)
		if cnt > 0:
			var name = unit_names.get(uid, str(uid))
			military_lines.append("[color=#aaa]%s[/color]:[color=white]%d[/color]" % [name, cnt])

	# 添加官员（如果有）
	var official_lines = []
	for uid in [46, 47, 48, 49, 50]:
		var cnt = unit_counts.get(uid, 0)
		if cnt > 0:
			var name = unit_names.get(uid, str(uid))
			official_lines.append("[color=#f8a]%s[/color]:[color=white]%d[/color]" % [name, cnt])

	if military_lines.is_empty() and official_lines.is_empty() and eco_lines.is_empty():
		_stats_mil_rtl.text = "[color=gray](无军队)[/color]"
	else:
		var text = ""
		if not eco_lines.is_empty():
			text = " ".join(eco_lines)
		if not military_lines.is_empty():
			if text != "": text += "\n"
			text += "[color=#8cf]战斗: %d[/color] | " % military_total + " ".join(military_lines)
		if not official_lines.is_empty():
			if text != "": text += "\n"
			text += "[color=#a8f]官员:[/color] " + " ".join(official_lines)
		_stats_mil_rtl.text = text if text != "" else "[color=gray](无军队)[/color]"

	# 构建建筑显示
	var building_lines = []
	var building_order = [20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 41, 42]
	for bid in building_order:
		var cnt = building_counts.get(bid, 0)
		if cnt > 0:
			var lv = building_levels.get(bid, 1)
			var name = building_names.get(bid, str(bid))
			building_lines.append("[color=#888]【%d】%s[/color]:[color=white]%d[/color]" % [lv, name, cnt])

	if building_lines.is_empty():
		_stats_bld_rtl.text = "[color=gray](无建筑)[/color]"
	else:
		_stats_bld_rtl.text = " ".join(building_lines)


func _on_rally_pressed():
	var input_node = get_tree().get_first_node_in_group("client_input")
	if not input_node:
		input_node = get_node_or_null("ClientRoot/ClientInput")
	if input_node:
		input_node.select_all_military()


func _on_stop_gather_pressed():
	NetworkManager.send_command.rpc_id(1, {"action": "stop_gather"})


func _on_hold_position_pressed():
	NetworkManager.send_command.rpc_id(1, {"action": "toggle_hold_position"})


func _input(event):
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_H: _on_stop_gather_pressed()
			KEY_P: _on_hold_position_pressed()
			KEY_R: _on_rally_pressed()
			KEY_A: _on_attack_all_pressed()
			KEY_S: _on_retreat_all_pressed()
			KEY_SPACE: _on_jump_to_alert()

func _on_jump_to_alert():
	var minimap = get_node_or_null("../Minimap") as Minimap
	if minimap and minimap.has_latest_alert:
		var cam = get_viewport().get_camera_3d()
		if cam:
			var target = minimap.latest_alert_world_pos
			cam.global_position = Vector3(target.x, cam.global_position.y, target.z)
			minimap.has_latest_alert = false


func _on_attack_all_pressed():
	NetworkManager.send_command.rpc_id(1, {
		"action": "global_attack",
		"selected_ids": []
	})


func _on_retreat_all_pressed():
	NetworkManager.send_command.rpc_id(1, {
		"action": "global_retreat",
		"selected_ids": []
	})


func show_alert_message(msg: String, color: Color = ALERT_DANGER):
	if not _alert_label:
		# 半透明黑色背景
		_alert_bg = ColorRect.new()
		_alert_bg.color = Color(0, 0, 0, 0.55)
		_alert_bg.position = Vector2(755, 196)
		_alert_bg.size = Vector2(810, 44)
		add_child(_alert_bg)
		# 文字标签
		_alert_label = Label.new()
		_alert_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_alert_label.add_theme_font_size_override("font_size", 24)
		_alert_label.add_theme_color_override("font_outline_color", Color.BLACK)
		_alert_label.add_theme_constant_override("outline_size", 3)
		_alert_label.position = Vector2(760, 200)
		_alert_label.size = Vector2(800, 40)
		add_child(_alert_label)
	_alert_label.text = msg
	_alert_label.add_theme_color_override("font_color", color)
	_alert_label.visible = true
	_alert_bg.visible = true
	_alert_timer = 3.0

func _ready():
	# 创建资源标签（字号28，背景扩大）
	const RES_CFG = [
		{name="黄金", key="gold", color=Color(1.0, 0.84, 0.08)},
		{name="木材", key="wood", color=Color(0.2, 0.78, 0.18)},
		{name="石头", key="stone", color=Color(0.6, 0.6, 0.6)},
		{name="食物", key="food", color=Color(1.0, 0.5, 0.08)},
		{name="石油", key="oil", color=Color(0.4, 0.25, 0.1)},
		{name="人口", key="pop", color=Color(0.25, 0.65, 1.0)},
	]
	const BASE_BG = Color(0.12, 0.12, 0.12, 0.75)
	const ROW_H = 44; const ROW_W = 290; const FONT_SZ = 18
	var _res_lbls = {}

	for i in range(RES_CFG.size()):
		var cfg = RES_CFG[i]
		var y = 10 + i * (ROW_H + 5)
		var col = cfg.color

		var bg = Panel.new()
		bg.position = Vector2(6, y); bg.size = Vector2(ROW_W, ROW_H)
		var s = StyleBoxFlat.new()
		s.bg_color = BASE_BG
		s.corner_radius_top_left = 5; s.corner_radius_top_right = 5
		s.corner_radius_bottom_left = 5; s.corner_radius_bottom_right = 5
		s.border_width_left = 2; s.border_width_right = 2; s.border_width_top = 2; s.border_width_bottom = 2
		s.border_color = Color(col.r * 0.35, col.g * 0.35, col.b * 0.35, 0.45)
		bg.add_theme_stylebox_override("panel", s)
		add_child(bg)

		var nl = Label.new()
		nl.position = Vector2(14, y + 10); nl.text = cfg.name
		nl.add_theme_font_size_override("font_size", FONT_SZ)
		nl.add_theme_color_override("font_color", col)
		nl.add_theme_color_override("font_outline_color", Color.BLACK)
		nl.add_theme_constant_override("outline_size", 1)
		add_child(nl)

		var vl = Label.new()
		vl.position = Vector2(100, y + 10); vl.size = Vector2(ROW_W - 110, 22)
		vl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		vl.add_theme_font_size_override("font_size", FONT_SZ)
		vl.add_theme_color_override("font_color", Color.WHITE)
		vl.add_theme_color_override("font_outline_color", Color.BLACK)
		vl.add_theme_constant_override("outline_size", 1)
		add_child(vl)
		_res_lbls[cfg.key] = vl
		cli_res_name_lbls[cfg.key] = nl  # Store for later update

		# Gatherer count label
		var gl = Label.new()
		gl.position = Vector2(14, y + ROW_H - 24)
		gl.size = Vector2(ROW_W - 28, 14)
		gl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		gl.add_theme_font_size_override("font_size", 10)
		gl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		add_child(gl)
		gather_labels[cfg.key] = gl

		# Progress bar
		var pbar = ProgressBar.new()
		pbar.position = Vector2(14, y + ROW_H - 10)
		pbar.size = Vector2(ROW_W - 28, 6)
		pbar.max_value = 100; pbar.show_percentage = false
		var fs = StyleBoxFlat.new(); fs.bg_color = col.darkened(0.15); fs.corner_radius_top_left = 2; fs.corner_radius_top_right = 2; fs.corner_radius_bottom_left = 2; fs.corner_radius_bottom_right = 2
		pbar.add_theme_stylebox_override("fill", fs)
		var bs = StyleBoxFlat.new(); bs.bg_color = Color(0.08,0.08,0.08,0.8); bs.corner_radius_top_left = 2; bs.corner_radius_top_right = 2; bs.corner_radius_bottom_left = 2; bs.corner_radius_bottom_right = 2
		pbar.add_theme_stylebox_override("background", bs)
		add_child(pbar)
		match cfg.key:
			"gold": res_bars["gold"] = pbar
			"wood": res_bars["wood"] = pbar
			"stone": res_bars["stone"] = pbar
			"food": res_bars["food"] = pbar
			"oil": res_bars["oil"] = pbar

	gold_label = _res_lbls["gold"]
	wood_label = _res_lbls["wood"]
	stone_label = _res_lbls["stone"]
	food_label = _res_lbls["food"]
	oil_label = _res_lbls["oil"]
	pop_label = _res_lbls["pop"]

	# Population progress bar
	pop_bar = ProgressBar.new()
	pop_bar.position = Vector2(14, 10 + 5 * (ROW_H + 5) + ROW_H - 10)
	pop_bar.size = Vector2(ROW_W - 28, 6)
	pop_bar.max_value = 100; pop_bar.show_percentage = false
	var pfs2 = StyleBoxFlat.new(); pfs2.bg_color = Color(0.25, 0.65, 1.0).darkened(0.15)
	pfs2.corner_radius_top_left = 2; pfs2.corner_radius_top_right = 2
	pfs2.corner_radius_bottom_left = 2; pfs2.corner_radius_bottom_right = 2
	pop_bar.add_theme_stylebox_override("fill", pfs2)
	var pbs2 = StyleBoxFlat.new(); pbs2.bg_color = Color(0.08,0.08,0.08,0.8)
	pbs2.corner_radius_top_left = 2; pbs2.corner_radius_top_right = 2
	pbs2.corner_radius_bottom_left = 2; pbs2.corner_radius_bottom_right = 2
	pop_bar.add_theme_stylebox_override("background", pbs2)
	add_child(pop_bar)

	# 国家及加成标签（字号24，带描边）
	player_nation_label = Label.new()
	player_nation_label.position = Vector2(10, 330)
	player_nation_label.add_theme_font_size_override("font_size", 24)
	player_nation_label.add_theme_color_override("font_color", Color.WHITE)
	player_nation_label.add_theme_color_override("font_outline_color", Color.BLACK)
	player_nation_label.add_theme_constant_override("outline_size", 1)
	add_child(player_nation_label)

	enemy_nation_label = Label.new()
	enemy_nation_label.position = Vector2(10, 360)
	enemy_nation_label.add_theme_font_size_override("font_size", 24)
	enemy_nation_label.add_theme_color_override("font_color", Color.WHITE)
	enemy_nation_label.add_theme_color_override("font_outline_color", Color.BLACK)
	enemy_nation_label.add_theme_constant_override("outline_size", 1)
	add_child(enemy_nation_label)

	nation_bonus_label = Label.new()
	nation_bonus_label.position = Vector2(10, 400)
	nation_bonus_label.add_theme_font_size_override("font_size", 22)
	nation_bonus_label.add_theme_color_override("font_color", Color.LIGHT_GRAY)
	nation_bonus_label.add_theme_color_override("font_outline_color", Color.BLACK)
	nation_bonus_label.add_theme_constant_override("outline_size", 1)
	nation_bonus_label.text = "加成:\n" + NationBonuses.get_description(GameSettings.player_nation)
	add_child(nation_bonus_label)

	# 按钮主题（字号24）
	var btn_theme = Theme.new()
	btn_theme.set_font_size("font_size", "Button", 24)

	attack_all_btn = Button.new()
	attack_all_btn.text = "全军进攻 (A)"
	attack_all_btn.position = Vector2(10, 470)
	attack_all_btn.theme = btn_theme
	attack_all_btn.custom_minimum_size = Vector2(180, 50)
	attack_all_btn.pressed.connect(_on_attack_all_pressed)
	add_child(attack_all_btn)

	retreat_all_btn = Button.new()
	retreat_all_btn.text = "全军撤退 (S)"
	retreat_all_btn.position = Vector2(210, 470)
	retreat_all_btn.theme = btn_theme
	retreat_all_btn.custom_minimum_size = Vector2(180, 50)
	retreat_all_btn.pressed.connect(_on_retreat_all_pressed)
	add_child(retreat_all_btn)

	var stop_gather_btn = Button.new()
	stop_gather_btn.text = "暂停采集 (H)"
	stop_gather_btn.position = Vector2(10, 540)
	stop_gather_btn.theme = btn_theme
	stop_gather_btn.custom_minimum_size = Vector2(180, 50)
	stop_gather_btn.pressed.connect(_on_stop_gather_pressed)
	add_child(stop_gather_btn)

	var hold_position_btn = Button.new()
	hold_position_btn.text = "原地防守 (P)"
	hold_position_btn.position = Vector2(210, 540)
	hold_position_btn.theme = btn_theme
	hold_position_btn.custom_minimum_size = Vector2(180, 50)
	hold_position_btn.pressed.connect(_on_hold_position_pressed)
	add_child(hold_position_btn)

	var rally_btn = Button.new()
	rally_btn.text = "全选军队 (R)"
	rally_btn.position = Vector2(10, 610)
	rally_btn.theme = btn_theme
	rally_btn.custom_minimum_size = Vector2(180, 50)
	rally_btn.pressed.connect(_on_rally_pressed)
	add_child(rally_btn)

	# 创建单位统计面板
	_create_unit_stats_panel()

	# 创建切换按钮
	_create_stats_toggle_button()

	# FPS + 游戏时间显示
	_fps_label = Label.new()
	_fps_label.position = Vector2(10, 600)
	_fps_label.add_theme_font_size_override("font_size", 16)
	_fps_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.3))
	add_child(_fps_label)
	_game_time_label = Label.new()
	_game_time_label.position = Vector2(10, 620)
	_game_time_label.add_theme_font_size_override("font_size", 16)
	_game_time_label.add_theme_color_override("font_color", Color.WHITE)
	add_child(_game_time_label)

	set_process(true)
	add_to_group("client_hud")


func update_data(resources: Dictionary, population: Dictionary, limits: Dictionary, gather_counts: Dictionary = {}, income_rate: Dictionary = {}, game_time: float = -1.0):
	gold_label.text = "%d/%d" % [resources.get("gold", 0), limits.get("gold", 0)]
	wood_label.text = "%d/%d" % [resources.get("wood", 0), limits.get("wood", 0)]
	stone_label.text = "%d/%d" % [resources.get("stone", 0), limits.get("stone", 0)]
	food_label.text = "%d/%d" % [resources.get("food", 0), limits.get("food", 0)]
	oil_label.text = "%d/%d" % [resources.get("oil", 0), limits.get("oil", 0)]
	pop_label.text = "%d/%d" % [population.get("current", 0), population.get("max", 0)]
	# 游戏时间
	if game_time >= 0 and _game_time_label:
		var m = int(game_time / 60)
		var s = int(game_time) % 60
		_game_time_label.text = "%02d:%02d" % [m, s]

	# Display server-computed gather counts and income rates
	var rn = {"gold": "黄金", "wood": "木材", "stone": "石头", "food": "食物", "oil": "石油"}
	for rk in ["gold", "wood", "stone", "food", "oil"]:
		var nl = cli_res_name_lbls.get(rk)
		if nl:
			var gc = gather_counts.get(rk, 0)
			var rate = income_rate.get(rk, 0.0)
			nl.text = "%s %d人 %+.1f/s" % [rn[rk], gc, rate]

	if pop_bar:
		pop_bar.value = min(float(population.get("current",1))/max(population.get("max",1),1)*100, 100)
	for rk in ["gold","wood","stone","food","oil"]:
		if res_bars.has(rk):
			var rv = resources.get(rk, 0)
			var rl = limits.get(rk, 500) if not limits.is_empty() else 500
			res_bars[rk].value = min(float(rv)/max(rl,1)*100, 100)


var _fps_label: Label = null
var _game_time_label: Label = null
var _fps_update_timer: float = 0.5

func _process(delta):
	# 每秒更新一次单位统计
	_unit_stats_timer -= delta
	if _unit_stats_timer <= 0:
		_unit_stats_timer = 1.0
		_update_unit_stats()

	# FPS + 游戏时间
	_fps_update_timer -= delta
	if _fps_update_timer <= 0 and _fps_label:
		_fps_update_timer = 0.5
		_fps_label.text = "FPS: %.0f" % Engine.get_frames_per_second()

	# 警报消息计时
	if _alert_label and _alert_timer > 0:
		_alert_timer -= delta
		if _alert_timer <= 0:
			_alert_label.visible = false
			if _alert_bg:
				_alert_bg.visible = false

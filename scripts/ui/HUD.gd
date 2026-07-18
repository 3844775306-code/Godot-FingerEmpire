class_name HUD
extends CanvasLayer

# 缓存的节点引用 — 避免每帧 get_tree().get_first_node_in_group()
var _bm: Node = null
var _sm: Node = null

var health_bar_timer = 0.0
var gold_label: Label
var wood_label: Label
var stone_label: Label
var food_label: Label
var oil_label: Label
var unit_bars: Dictionary = {}
var res_bars: Dictionary = {}
var pop_bar: ProgressBar = null
var pop_label: Label
var res_name_labels: Dictionary = {}
var res_snapshot: Dictionary = {}
var gather_timer: float = 0.0
var income_timer: float = 0.0
var res_income: Dictionary = {}
var income_rate: Dictionary = {}
var minimap_timer: float = 0.0

var attack_all_btn: Button
var retreat_all_btn: Button
var rally_btn: Button
var player_nation_label: Label
var enemy_nation_label: Label
var nation_bonus_label: Label

# ==================== 玩家单位统计面板 ====================
var unit_stats_panel: Control = null
var unit_stats_visible: bool = true
var _stats_mil_rtl: RichTextLabel
var _stats_bld_rtl: RichTextLabel
var _stats_pop_bar: ProgressBar
var _stats_pop_label: Label
var _toggle_stats_btn: Button
var _alert_label: Label = null
var _alert_bg: ColorRect = null
var _alert_timer: float = 0.0
var _unit_stats_timer: float = 1.0


func _get_nation_name(nation: int) -> String:
	match nation:
		RTSConfig.Nation.VIKING: return "维京"
		RTSConfig.Nation.ENGLAND: return "英格兰"
		RTSConfig.Nation.FRANCE: return "法兰西"
		RTSConfig.Nation.CHINA: return "中国"
		RTSConfig.Nation.HUNGARY: return "匈牙利"
		_: return "未知"

# 缓存 battle_manager / selection_manager 引用，避免每帧场景树遍历
func _get_bm():
	if not is_instance_valid(_bm):
		_bm = get_tree().get_first_node_in_group("battle_manager")
	return _bm

func _get_sm():
	if not is_instance_valid(_sm):
		var bm = _get_bm()
		if bm and bm.has_node("SelectionManager"):
			_sm = bm.get_node("SelectionManager")
	return _sm


# ==================== 单位统计面板 ====================
func _create_stats_toggle_button():
	var btn_theme = Theme.new()
	btn_theme.set_font_size("font_size", "Button", 18)

	_toggle_stats_btn = Button.new()
	_toggle_stats_btn.text = "📊 统计"
	_toggle_stats_btn.position = Vector2(10, 540)
	_toggle_stats_btn.theme = btn_theme
	_toggle_stats_btn.toggle_mode = true
	_toggle_stats_btn.button_pressed = true
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

	add_child(unit_stats_panel)
	unit_stats_panel.custom_minimum_size = Vector2(380, 0)
	unit_stats_panel.size = Vector2(400, 380)

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

func _update_unit_stats():
	if not unit_stats_panel or not unit_stats_visible:
		return

	var bm = _get_bm()
	if not bm:
		return

	var team = RTSConfig.Team.BLUE

	# 更新人口
	if _stats_pop_label and _stats_pop_bar:
		_stats_pop_label.text = "人口: %d/%d" % [bm.player_pop, bm.player_max_pop]
		_stats_pop_bar.value = min(float(bm.player_pop) / max(bm.player_max_pop, 1) * 100, 100)

	var unit_names = {
		10: "农民", 11: "步兵", 12: "弓箭手", 13: "战船", 14: "采集船",
		15: "骑兵", 16: "火炮", 17: "投石车", 18: "攻城车", 19: "侦察兵",
		30: "狂战士", 31: "长弓兵", 32: "法式骑兵", 33: "诸葛连弩",
		34: "象骑兵", 35: "长枪兵", 36: "重装步兵", 37: "重装弓箭手",
		38: "重装骑兵", 39: "炮艇", 40: "快艇",
		43: "油商", 44: "木商", 45: "石商", 51: "食商",
		46: "县吏", 47: "上校", 48: "尚书", 49: "统帅", 50: "丞相"
	}
	var building_names = {
		20: "主城", 21: "兵营", 22: "仓库", 23: "船坞", 24: "攻城车间",
		25: "箭塔", 26: "炮塔", 27: "城墙", 28: "民居", 29: "重装武器厂",
		41: "瞭望塔", 42: "书院", 52: "集市", 53: "城堡"
	}

	var unit_counts = {}
	var building_counts = {}
	var building_levels = {}

	for entity in bm.entities.get_children():
		if not (entity is GameEntity) or entity.health <= 0:
			continue
		if entity.team != team:
			continue

		if entity is Army:
			unit_counts[entity.entity_id] = unit_counts.get(entity.entity_id, 0) + 1
		elif entity is Building:
			building_counts[entity.entity_id] = building_counts.get(entity.entity_id, 0) + 1
			var lv = entity.upgrade_level if entity.has_method("get_upgrade_level") else entity.level
			if not building_levels.has(entity.entity_id) or building_levels[entity.entity_id] < lv:
				building_levels[entity.entity_id] = lv

	# 军队统计（排除农民、采集船、官员）
	var military_total = 0
	for uid in unit_counts.keys():
		if uid != 10 and uid != 14 and uid not in [43, 44, 45, 46, 47, 48, 49, 50, 51]:
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

	var merchant_lines = []
	for uid in [43, 44, 45, 51]:
		var cnt = unit_counts.get(uid, 0)
		if cnt > 0:
			var name = unit_names.get(uid, str(uid))
			merchant_lines.append("[color=#ffa]%s[/color]:[color=white]%d[/color]" % [name, cnt])

	var official_lines = []
	for uid in [46, 47, 48, 49, 50]:
		var cnt = unit_counts.get(uid, 0)
		if cnt > 0:
			var name = unit_names.get(uid, str(uid))
			official_lines.append("[color=#f8a]%s[/color]:[color=white]%d[/color]" % [name, cnt])

	if military_lines.is_empty() and official_lines.is_empty() and eco_lines.is_empty() and merchant_lines.is_empty():
		_stats_mil_rtl.text = "[color=gray](无军队)[/color]"
	else:
		var text = ""
		if not eco_lines.is_empty():
			text = " ".join(eco_lines)
		if not military_lines.is_empty():
			if text != "": text += "\n"
			text += "[color=#8cf]战斗: %d[/color] | " % military_total + " ".join(military_lines)
		if not merchant_lines.is_empty():
			if text != "": text += "\n"
			text += "[color=#ffa]商人:[/color] " + " ".join(merchant_lines)
		if not official_lines.is_empty():
			if text != "": text += "\n"
			text += "[color=#a8f]官员:[/color] " + " ".join(official_lines)
		_stats_mil_rtl.text = text if text != "" else "[color=gray](无军队)[/color]"

	# 建筑统计
	var building_lines = []
	var building_order = [20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 41, 42, 52, 53]
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
	var bm = _get_bm() as RTSBattleManager
	if bm:
		var sel = bm.get_node("SelectionManager") as SelectionManager
		if sel:
			sel.select_all_military()


func _input(event):
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_H: _on_stop_gather_pressed()
			KEY_P: _on_hold_position_pressed()
			KEY_R: _on_rally_pressed()
			KEY_A: _on_attack_all_pressed()
			KEY_S: _on_retreat_all_pressed()
			KEY_DELETE: _on_demolish_selected()
			KEY_SPACE: _on_jump_to_alert()

func _on_jump_to_alert():
	var minimap = $Minimap as Minimap
	if minimap and minimap.has_latest_alert:
		var cam = get_viewport().get_camera_3d()
		if cam:
			var target = minimap.latest_alert_world_pos
			cam.global_position = Vector3(target.x, cam.global_position.y, target.z)
			minimap.has_latest_alert = false


func _on_attack_all_pressed():
	var bm = _get_bm()
	if not bm: return
	var target = bm.get_enemy_castle()
	if target:
		_order_all_units("attack", target.global_position)


func _on_retreat_all_pressed():
	var bm = _get_bm()
	if not bm: return
	var home = bm.get_player_castle()
	if home:
		_order_all_units("move", home.global_position)


func _order_all_units(order_type: String, destination: Vector3):
	for unit in get_tree().get_nodes_in_group("entities"):
		if unit is Army and unit.team == RTSConfig.Team.BLUE and unit.target_type > 0 and unit.entity_id not in [43,44,45,46,47,48,49,50,51]:
			match order_type:
				"attack":
					unit.attack_move_to(destination)
				"move":
					unit.move_to(destination)


func _ready():
	# 资源颜色和名称
	const RES_CFG = [
		{name="黄金", key="gold", color=Color(1.0, 0.84, 0.1)},
		{name="木材", key="wood", color=Color(0.25, 0.82, 0.2)},
		{name="石头", key="stone", color=Color(0.62, 0.62, 0.62)},
		{name="食物", key="food", color=Color(1.0, 0.55, 0.1)},
		{name="石油", key="oil", color=Color(0.4, 0.25, 0.1)},
		{name="人口", key="pop", color=Color(0.3, 0.7, 1.0)},
	]
	var res_labels = {}

	for i in range(RES_CFG.size()):
		var cfg = RES_CFG[i]
		var y = 10 + i * 38
		var col = cfg.color

		# 圆角背景面板（半透明暗色 + 彩色边框）
		var bg = Panel.new()
		bg.position = Vector2(8, y)
		bg.size = Vector2(240, 36)
		var bg_style = StyleBoxFlat.new()
		bg_style.bg_color = Color(0.12, 0.12, 0.12, 0.75)
		bg_style.corner_radius_top_left = 5; bg_style.corner_radius_top_right = 5
		bg_style.corner_radius_bottom_left = 5; bg_style.corner_radius_bottom_right = 5
		bg_style.border_width_left = 1; bg_style.border_width_right = 1
		bg_style.border_width_top = 1; bg_style.border_width_bottom = 1
		bg_style.border_color = Color(col.r * 0.4, col.g * 0.4, col.b * 0.4, 0.5)
		bg.add_theme_stylebox_override("panel", bg_style)
		add_child(bg)

		# 资源名称
		var name_lbl = Label.new()
		name_lbl.position = Vector2(14, y + 6)
		name_lbl.text = cfg.name
		name_lbl.add_theme_font_size_override("font_size", 15)
		name_lbl.add_theme_color_override("font_color", col)
		name_lbl.add_theme_color_override("font_outline_color", Color.BLACK)
		name_lbl.add_theme_constant_override("outline_size", 1)
		add_child(name_lbl)
		res_name_labels[cfg.key] = name_lbl

		# 数值（右对齐）
		var val_lbl = Label.new()
		val_lbl.position = Vector2(80, y + 6)
		val_lbl.size = Vector2(160, 20)
		val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		val_lbl.add_theme_font_size_override("font_size", 15)
		val_lbl.add_theme_color_override("font_color", Color.WHITE)
		val_lbl.add_theme_color_override("font_outline_color", Color.BLACK)
		val_lbl.add_theme_constant_override("outline_size", 1)
		add_child(val_lbl)
		res_labels[cfg.key] = val_lbl

		# Progress bar for this resource
		var pbar = ProgressBar.new()
		pbar.position = Vector2(14, y + 24)
		pbar.size = Vector2(220, 6)
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

	gold_label = res_labels["gold"]
	wood_label = res_labels["wood"]
	stone_label = res_labels["stone"]
	food_label = res_labels["food"]
	oil_label = res_labels["oil"]
	pop_label = res_labels["pop"]

	# Population progress bar
	pop_bar = ProgressBar.new()
	pop_bar.position = Vector2(14, 10 + 5 * (32 + 6) + 24)
	pop_bar.size = Vector2(220, 6)
	pop_bar.max_value = 100; pop_bar.show_percentage = false
	var pfs = StyleBoxFlat.new(); pfs.bg_color = Color(0.25, 0.65, 1.0).darkened(0.15)
	pfs.corner_radius_top_left = 2; pfs.corner_radius_top_right = 2
	pfs.corner_radius_bottom_left = 2; pfs.corner_radius_bottom_right = 2
	pop_bar.add_theme_stylebox_override("fill", pfs)
	var pbs = StyleBoxFlat.new(); pbs.bg_color = Color(0.08,0.08,0.08,0.8)
	pbs.corner_radius_top_left = 2; pbs.corner_radius_top_right = 2
	pbs.corner_radius_bottom_left = 2; pbs.corner_radius_bottom_right = 2
	pop_bar.add_theme_stylebox_override("background", pbs)
	add_child(pop_bar)

	# 国家及加成标签（字号20）
	player_nation_label = Label.new()
	player_nation_label.position = Vector2(10, 280)
	player_nation_label.add_theme_font_size_override("font_size", 20)
	player_nation_label.add_theme_color_override("font_color", Color.WHITE)
	player_nation_label.add_theme_color_override("font_outline_color", Color.BLACK)
	player_nation_label.add_theme_constant_override("outline_size", 1)
	add_child(player_nation_label)

	enemy_nation_label = Label.new()
	enemy_nation_label.position = Vector2(10, 310)
	enemy_nation_label.add_theme_font_size_override("font_size", 20)
	enemy_nation_label.add_theme_color_override("font_color", Color.WHITE)
	enemy_nation_label.add_theme_color_override("font_outline_color", Color.BLACK)
	enemy_nation_label.add_theme_constant_override("outline_size", 1)
	add_child(enemy_nation_label)

	nation_bonus_label = Label.new()
	nation_bonus_label.position = Vector2(10, 340)
	nation_bonus_label.add_theme_font_size_override("font_size", 18)
	nation_bonus_label.add_theme_color_override("font_color", Color.LIGHT_GRAY)
	nation_bonus_label.add_theme_color_override("font_outline_color", Color.BLACK)
	nation_bonus_label.add_theme_constant_override("outline_size", 1)
	add_child(nation_bonus_label)

	# 按钮设置较大字体（通过 Theme）
	var btn_theme = Theme.new()
	var default_font = Label.new().get_theme_font("font", "Label")
	btn_theme.set_font_size("font_size", "Button", 20)
	
	attack_all_btn = Button.new()
	attack_all_btn.text = "全军进攻 (A)"
	attack_all_btn.position = Vector2(10, 420)
	attack_all_btn.theme = btn_theme
	attack_all_btn.pressed.connect(_on_attack_all_pressed)
	add_child(attack_all_btn)

	retreat_all_btn = Button.new()
	retreat_all_btn.text = "全军撤退 (S)"
	retreat_all_btn.position = Vector2(180, 420)
	retreat_all_btn.theme = btn_theme
	retreat_all_btn.pressed.connect(_on_retreat_all_pressed)
	add_child(retreat_all_btn)

	var stop_gather_btn = Button.new()
	stop_gather_btn.text = "暂停采集 (H)"
	stop_gather_btn.position = Vector2(10, 460)
	stop_gather_btn.toggle_mode = true
	stop_gather_btn.theme = btn_theme
	stop_gather_btn.pressed.connect(_on_stop_gather_pressed)
	add_child(stop_gather_btn)

	var hold_position_btn = Button.new()
	hold_position_btn.text = "原地防守 (P)"
	hold_position_btn.position = Vector2(180, 460)
	hold_position_btn.toggle_mode = true
	hold_position_btn.theme = btn_theme
	hold_position_btn.pressed.connect(_on_hold_position_pressed)
	add_child(hold_position_btn)

	var rally_btn = Button.new()
	rally_btn.text = "全选军队 (R)"
	rally_btn.position = Vector2(10, 500)
	rally_btn.theme = btn_theme
	rally_btn.pressed.connect(_on_rally_pressed)
	add_child(rally_btn)
	# 创建单位统计面板
	_create_unit_stats_panel()
	# 创建切换按钮
	_create_stats_toggle_button()

	set_process(true)

const ALERT_DANGER = Color(1.0, 0.2, 0.1)     # 红色 — 基地/建筑被攻击
const ALERT_WARNING = Color(1.0, 0.8, 0.1)   # 黄色 — 敌军来袭/资源不足
const ALERT_INFO = Color(0.2, 1.0, 0.3)      # 绿色 — 建造/训练/升级完成
const ALERT_GROUP = Color(0.3, 0.7, 1.0)     # 蓝色 — 编队反馈

func show_alert_message(msg: String, color: Color = ALERT_DANGER):
	if not _alert_label:
		# 半透明黑色背景
		_alert_bg = ColorRect.new()
		_alert_bg.color = Color(0, 0, 0, 0.55)
		_alert_bg.anchor_left = 0.5; _alert_bg.anchor_right = 0.5
		_alert_bg.anchor_top = 0.15
		_alert_bg.offset_left = -420; _alert_bg.offset_right = 420
		_alert_bg.offset_top = -4
		_alert_bg.offset_bottom = 32
		add_child(_alert_bg)
		# 文字标签
		_alert_label = Label.new()
		_alert_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_alert_label.add_theme_font_size_override("font_size", 24)
		_alert_label.add_theme_color_override("font_outline_color", Color.BLACK)
		_alert_label.add_theme_constant_override("outline_size", 3)
		_alert_label.anchor_left = 0.5; _alert_label.anchor_right = 0.5
		_alert_label.anchor_top = 0.15
		_alert_label.offset_left = -420; _alert_label.offset_right = 420
		add_child(_alert_label)
	_alert_label.text = msg
	_alert_label.add_theme_color_override("font_color", color)
	_alert_label.visible = true
	_alert_bg.visible = true
	_alert_timer = 3.0

	set_process(true)


func update_data(resources: Dictionary, population: Dictionary, limits: Dictionary = {}):
	gold_label.text = "%d" % resources.get("gold", 0)
	wood_label.text = "%d" % resources.get("wood", 0)
	stone_label.text = "%d" % resources.get("stone", 0)
	food_label.text = "%d" % resources.get("food", 0)
	oil_label.text = "%d" % resources.get("oil", 0)
	pop_label.text = "%d/%d" % [population.get("current", 0), population.get("max", 0)]
	if pop_bar:
		pop_bar.value = min(float(population.get("current",1))/max(population.get("max",1),1)*100, 100)
	for rk in ["gold","wood","stone","food","oil"]:
		if res_bars.has(rk):
			var rv = resources.get(rk, 0)
			var rl = limits.get(rk, 500) if not limits.is_empty() else 500
			res_bars[rk].value = min(float(rv)/max(rl,1)*100, 100)
	

func _process(delta):
	_unit_stats_timer -= delta
	var bm = _get_bm()
	if bm:
		gold_label.text = "黄金: %d/%d" % [bm.player_resources["gold"], bm.player_resource_limits["gold"]]
		wood_label.text = "木材: %d/%d" % [bm.player_resources["wood"], bm.player_resource_limits["wood"]]
		stone_label.text = "石头: %d/%d" % [bm.player_resources["stone"], bm.player_resource_limits["stone"]]
		food_label.text = "食物: %d/%d" % [bm.player_resources["food"], bm.player_resource_limits["food"]]
		oil_label.text = "石油: %d/%d" % [bm.player_resources["oil"], bm.player_resource_limits["oil"]]
		pop_label.text = "人口: %d/%d" % [bm.player_pop, bm.player_max_pop]
		if pop_bar:
			pop_bar.value = min(float(bm.player_pop)/max(bm.player_max_pop,1)*100, 100)
			for rk in ["gold","wood","stone","food","oil"]:
				if res_bars.has(rk):
					var rv = bm.player_resources.get(rk, 0)
					var rl = bm.player_resource_limits.get(rk, 500)
					res_bars[rk].value = min(float(rv)/max(rl,1)*100, 100)
		var player_nation = bm.team_nations.get(RTSConfig.Team.BLUE, -1)
		player_nation_label.text = "我方国家: %s" % _get_nation_name(player_nation)
		nation_bonus_label.text = "加成:\n" + NationBonuses.get_description(player_nation)
		var enemy_nation = bm.team_nations.get(RTSConfig.Team.RED, -1)
		enemy_nation_label.text = "敌方国家: %s" % _get_nation_name(enemy_nation)

	# Gatherer count every 1s, income rate every 10s
	gather_timer -= delta
	income_timer -= delta
	
	if gather_timer <= 0:
		gather_timer = 1.0
		var gather_counts = {"gold":0, "wood":0, "stone":0, "food":0, "oil":0}
		for entity in get_tree().get_nodes_in_group("entities"):
			if entity is Army and entity.team == RTSConfig.Team.BLUE and entity.health > 0:
				if entity.entity_id in [10, 14] and entity.current_order in ["gather", "deliver"]:
					var tgt = entity.current_target
					if is_instance_valid(tgt) and tgt is WorldResource:
						var rt = tgt.resource_type
						if rt in gather_counts:
							gather_counts[rt] += 1
	
		if res_snapshot.is_empty():
			res_snapshot = bm.player_resources.duplicate()
		else:
			for rk in ["gold","wood","stone","food","oil"]:
				var cur = bm.player_resources.get(rk, 0)
				var prev = res_snapshot.get(rk, cur)
				if cur > prev:
					res_income[rk] = res_income.get(rk, 0) + (cur - prev)
				res_snapshot[rk] = cur
		if income_timer <= 0:
			income_timer = 10.0
			for rk in ["gold","wood","stone","food","oil"]:
				income_rate[rk] = res_income.get(rk, 0) / 10.0
				res_income[rk] = 0
		var res_names = {"gold":"黄金","wood":"木材","stone":"石头","food":"食物","oil":"石油"}
		for rk in ["gold","wood","stone","food","oil"]:
			var nl = res_name_labels.get(rk)
			if nl:
				nl.text = "%s %d人 %+.1f/s" % [res_names[rk], gather_counts[rk], income_rate.get(rk, 0.0)]


	minimap_timer -= delta
	if minimap_timer <= 0:
		minimap_timer = 0.5
		if bm:
			var minimap = $Minimap as Minimap
			if minimap:
				if minimap.terrain_colors.is_empty():
					var map_node = bm.get_node("Map")
					if map_node and map_node.has_method("get_base_colors"):
						minimap.terrain_colors = map_node.get_base_colors()
				var entities_info = []
				for entity in bm.entities.get_children():
					if entity is GameEntity and entity.health > 0:
						entities_info.append({
							"x": entity.global_position.x,
							"z": entity.global_position.z,
							"team": entity.team,
							"type": entity.entity_type,
							"id": entity.get_instance_id(),
							"owner_peer_id": entity.owner_peer_id
						})
				minimap.set_data(bm.explored_grid, bm.visible_grid, entities_info)

	# 警报消息计时
	if _alert_label and _alert_timer > 0:
		_alert_timer -= delta
		if _alert_timer <= 0:
			_alert_label.visible = false
			if _alert_bg:
				_alert_bg.visible = false

	_update_health_bars()
	# 更新单位统计（每秒一次）
	if _unit_stats_timer <= 0:
		_unit_stats_timer = 1.0
		_update_unit_stats()


func _update_health_bars():
	var entities = get_tree().get_nodes_in_group("entities")
	var cam = get_viewport().get_camera_3d()
	if not cam:
		return

	# 基准血条尺寸和字体（针对 2400x1400 适当增大）
	var base_size = Vector2(100, 16)   # 原 60x10 → 100x16
	var base_font = 18                 # 原 12 → 18
	var ref_ortho_size = 30.0
	var scale_factor = 1.0
	if cam.projection == Camera3D.PROJECTION_ORTHOGONAL:
		scale_factor = ref_ortho_size / cam.size
	var bar_size = base_size * scale_factor
	var font_size = int(base_font * scale_factor)

	# 移除失效实体
	var to_remove = []
	for e in unit_bars.keys():
		if not is_instance_valid(e) or e.health <= 0:
			to_remove.append(e)
	for e in to_remove:
		if unit_bars.has(e):
			unit_bars[e].bar.queue_free()
			unit_bars[e].label.queue_free()
			if unit_bars[e].has("prod_bar"):
				unit_bars[e].prod_bar.queue_free()
				unit_bars[e].prod_label.queue_free()
			unit_bars.erase(e)

	# 遍历所有实体
	for entity in entities:
		if not is_instance_valid(entity) or entity.health <= 0:
			continue
		if not entity.visible:
			if entity in unit_bars:
				unit_bars[entity].bar.visible = false
				unit_bars[entity].label.visible = false
				if unit_bars[entity].has("prod_bar"):
					unit_bars[entity].prod_bar.visible = false
					unit_bars[entity].prod_label.visible = false
			continue

		if entity not in unit_bars:
			_create_health_bar(entity)

		var data = unit_bars[entity]
		var bar: HealthBarControl = data.bar
		var label: Label = data.label
		var prod_bar: ProgressBar = data.prod_bar if data.has("prod_bar") else null
		var prod_label: Label = data.prod_label if data.has("prod_label") else null

		# 动态调整尺寸与字体
		bar.size = bar_size
		label.add_theme_font_size_override("font_size", font_size)
		if prod_bar:
			prod_bar.custom_minimum_size = Vector2(bar_size.x, 8 * scale_factor)
			prod_label.add_theme_font_size_override("font_size", max(int(font_size * 0.8), 12))

		# 世界转屏幕
		var world_pos = entity.global_position + Vector3.UP * (entity.body_radius * 2 + 0.5)
		var screen_pos = cam.unproject_position(world_pos)
		bar.position = screen_pos - bar_size / 2

		# 建造进度
		# Upgrade progress (matches health bar scaling)
		if entity is Building and entity.upgrade_timer > 0:
			var up_bar_data = unit_bars[entity]
			var up_bar = up_bar_data.get("upgrade_bar")
			var up_lbl = up_bar_data.get("upgrade_label")
			if not up_bar:
				up_bar = HealthBarControl.new()
				add_child(up_bar); up_bar_data["upgrade_bar"] = up_bar
				up_bar.z_index = -1
			if not up_lbl:
				up_lbl = Label.new()
				up_lbl.add_theme_color_override("font_color", Color.WHITE)
				up_lbl.add_theme_color_override("font_outline_color", Color.BLACK)
				up_lbl.add_theme_constant_override("outline_size", 1)
				add_child(up_lbl); up_bar_data["upgrade_label"] = up_lbl
				up_lbl.z_index = -1
			up_bar.custom_minimum_size = bar_size
			up_lbl.add_theme_font_size_override("font_size", font_size)
			up_bar.visible = true; up_lbl.visible = true
			up_bar.set_team_color(Color(0.6, 0.2, 0.8))
			up_bar.update_bar(entity.upgrade_timer, entity.max_upgrade_time, -1)
			up_lbl.text = "升级中"
			up_bar.position = screen_pos - bar_size / 2 + Vector2(0, -bar_size.y * 2 - 6)
			up_lbl.position = up_bar.position + Vector2(0, -bar_size.y - 4)
		else:
			var up_data2 = unit_bars[entity]
			if up_data2.has("upgrade_bar") and up_data2.upgrade_bar:
				up_data2.upgrade_bar.visible = false
			if up_data2.has("upgrade_label") and up_data2.upgrade_label:
				up_data2.upgrade_label.visible = false

		if entity is Building and entity.has_method("is_under_construction") and entity.is_under_construction():
			bar.visible = true
			label.visible = true
			bar.set_team_color(Color.YELLOW)
			var progress = 1.0 - (entity.build_timer / entity.max_build_time)
			bar.update_bar(progress * entity.max_health, entity.max_health, entity.team)
			label.text = "%s (建造中)" % entity.display_name
			# Color label
			var _hlc2 = _get_hud_label_color(entity)
			label.add_theme_color_override("font_color", _hlc2)
			if prod_bar:
				prod_bar.visible = false
				prod_label.visible = false
			continue

		# 生产队列进度条
		var has_production = entity is Building and entity.production_queue.size() > 0
		if prod_bar and prod_label:
			if has_production:
				prod_bar.visible = true
				prod_label.visible = true
				var current_id = entity.production_queue[0]
				var unit_cfg = EntityDatabase.get_config(current_id)
				var unit_name = unit_cfg.get("name", "?")
				var prod_cfg = null
				for p in entity.production_list:
					if p.unit_id == current_id:
						prod_cfg = p
						break
				if prod_cfg:
					var progress = 1.0 - (entity.production_timer / prod_cfg.cooldown)
					prod_bar.max_value = 1.0
					prod_bar.value = progress
					prod_label.text = "%s x%d" % [unit_name, entity.production_queue.size()]
					prod_bar.position = bar.position + Vector2(0, bar_size.y + 4)
					prod_label.position = prod_bar.position + Vector2(0, -14)
				else:
					prod_bar.visible = false
					prod_label.visible = false
			else:
				prod_bar.visible = false
				prod_label.visible = false

		# 屏幕裁剪检查
		var cam_rect = get_viewport().get_visible_rect()
		if not cam_rect.has_point(screen_pos):
			bar.visible = false
			label.visible = false
			continue

		label.visible = true
		var group_prefix = ""
		var sm = get_tree().get_first_node_in_group("battle_manager")
		if sm and sm.has_node("SelectionManager") and sm.get_node("SelectionManager").has_method("get_entity_groups"):
			var groups = sm.get_node("SelectionManager").get_entity_groups(entity)
			for g in groups:
				group_prefix += "T%d " % g
			var _res_info = ""
			if entity.entity_id in [10, 14]:
				var _tgt = entity.current_target
				if is_instance_valid(_tgt) and _tgt is WorldResource:
					var _rn = {"gold":"采金","wood":"伐木","stone":"采石","food":"采食","oil":"采油"}
					_res_info = "\n" + _rn.get(_tgt.resource_type, "")
				elif entity.current_order == "deliver":
					_res_info = "\n返回"
			elif entity.entity_id in [43, 44, 45]:
				_res_info = "
交易量:%d" % entity._merchant_trade_volume
			label.text = group_prefix + "%s Lv.%d%s\n%d/%d" % [entity.display_name, entity.level, _res_info, int(entity.health), int(entity.max_health)]
			label.position = bar.position + Vector2(0, -22)

			# Color label by owner/team
			var _hlc = _get_hud_label_color(entity)
			label.add_theme_color_override("font_color", _hlc)
		label.position = bar.position + Vector2(0, -22)

		if entity.health >= entity.max_health:
			bar.visible = false
			continue

		bar.visible = true
		bar.set_team_color(Color.RED if entity.team == 0 else Color.BLUE)
		bar.update_bar(entity.health, entity.max_health, entity.team)


func _create_health_bar(entity):
	var bar = HealthBarControl.new()
	bar.size = Vector2(100, 16)
	bar.visible = false
	bar.z_index = -1
	add_child(bar)

	var label = Label.new()
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 1)
	label.z_index = -1
	add_child(label)

	unit_bars[entity] = {"bar": bar, "label": label}

	var prod_bar = ProgressBar.new()
	prod_bar.max_value = 1.0
	prod_bar.value = 0.0
	prod_bar.custom_minimum_size = Vector2(100, 8)
	prod_bar.show_percentage = false
	prod_bar.visible = false
	prod_bar.z_index = -1
	add_child(prod_bar)

	var prod_label = Label.new()
	prod_label.add_theme_font_size_override("font_size", 12)
	prod_label.z_index = -1
	add_child(prod_label)
	prod_label.visible = false

	unit_bars[entity] = {"bar": bar, "label": label, "prod_bar": prod_bar, "prod_label": prod_label}


# Control-group label colors
const GROUP_LABEL_COLORS = {
	1: Color(1.0, 0.3, 0.2),   # Red
	2: Color(0.2, 0.6, 1.0),   # Blue
	3: Color(0.2, 1.0, 0.3),   # Green
	4: Color(1.0, 1.0, 0.2),   # Yellow
	5: Color(1.0, 0.5, 0.0),   # Orange
	6: Color(0.7, 0.3, 1.0),   # Purple
	7: Color(0.0, 1.0, 1.0),   # Cyan
	8: Color(1.0, 0.4, 0.7),   # Pink
	9: Color(0.5, 1.0, 0.5),   # Mint
}

# Helper: get label color for entity (by control group first, then team)
func _get_hud_label_color(entity: GameEntity) -> Color:
	var sm = _get_bm()
	if sm and sm.has_node("SelectionManager") and sm.get_node("SelectionManager").has_method("get_entity_groups"):
		var groups = sm.get_node("SelectionManager").get_entity_groups(entity)
		if groups.size() > 0:
			var g = groups[0]
			if GROUP_LABEL_COLORS.has(g):
				return GROUP_LABEL_COLORS[g]
	
	return Color.WHITE

func _on_demolish_selected():
	var bm = _get_bm() as RTSBattleManager
	if not bm: return
	var sel = bm.get_node_or_null("SelectionManager") as SelectionManager
	if not sel: return
	# 收集选中实体中的建筑（先copy防止迭代中修改）
	var buildings_to_demolish: Array = []
	for e in sel.selected_entities:
		if is_instance_valid(e) and e is Building and e.entity_id != 20:
			buildings_to_demolish.append(e)
	for b in buildings_to_demolish:
		bm.demolish_building(b)
	sel.selected_entities.clear()
	var panel = bm.get_node_or_null("UI/InfoPanel") as InfoPanel
	if panel: panel.visible = false

func _on_stop_gather_pressed():
	var bm = _get_bm() as RTSBattleManager
	if bm: bm.stop_all_gather()


func _on_hold_position_pressed():
	var bm = _get_bm() as RTSBattleManager
	if bm: bm.toggle_hold_position()

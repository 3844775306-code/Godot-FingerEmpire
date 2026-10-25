class_name HUD
extends CanvasLayer

# 缓存的节点引用 — 避免每帧 get_tree().get_first_node_in_group()
var _bm: Node = null
var _sm: Node = null
var _mobile_hud = null    # 移动端界面装配器（仅触屏设备创建）

var health_bar_timer = 0.0
const HEALTH_BAR_UPDATE_INTERVAL: float = 0.05
# 血条基础 20Hz；实体多时分档降频，血量文字与血条使用同一刷新周期
var _last_health_scale: float = -1.0
var gold_label: Label
var wood_label: Label
var stone_label: Label
var food_label: Label
var oil_label: Label
var unit_bars: Dictionary = {}
# 血条文字开关（L 键切换）：关闭后只保留血条色条，隐藏名称/血量/生产/升级文字
var show_unit_text: bool = true
var res_bars: Dictionary = {}
var pop_bar: ProgressBar = null
var pop_label: Label
var res_name_labels: Dictionary = {}
var res_snapshot: Dictionary = {}
var gather_timer: float = 0.0
var income_timer: float = 0.0
var res_income: Dictionary = {}
var income_rate: Dictionary = {}
# 各资源采集人数（每帧刷新，移动端资源胶囊展开时读取）
var gather_counts: Dictionary = {"gold": 0, "wood": 0, "stone": 0, "food": 0, "oil": 0}
var minimap_timer: float = 0.0
var _minimap_fog_version: int = -1

var player_nation_label: Label
var auto_attack_btn: Button
var auto_attack_on: bool = false
var enemy_nation_label: Label
var nation_bonus_label: Label

# ==================== 玩家单位统计面板 ====================
var unit_stats_panel: Control = null
var unit_stats_visible: bool = true
var _stats_title: RichTextLabel
var _stats_bonus: Label
var _stats_mil_rtl: RichTextLabel
var _stats_bld_rtl: RichTextLabel
var _stats_eco_rtl: RichTextLabel
var _stats_eco_title: RichTextLabel
var _stats_mil_title: RichTextLabel
var _stats_bld_title: RichTextLabel
var _stats_pop_bar: ProgressBar
var _stats_pop_label: Label
var _stats_res_labels: Dictionary = {}
var _stats_res_bars: Dictionary = {}
var _stats_res_info: Dictionary = {}
var _stats_castle_bar: HealthBarControl
var _stats_castle_label: Label
# 折叠态：面板收成一条「资源 + 人口」胶囊（电脑版默认折叠）
var _stats_collapsed: bool = true
var _stats_collapse_btn: Button = null
var _stats_capsule: Panel = null
var _capsule_pop_label: Label = null
var _capsule_res_labels: Dictionary = {}
# 全局指令按钮底板（6 个按钮排两行）
var _cmd_panel: Panel = null
var _alert_label: Label = null
var _alert_bg: Control = null
var _alert_timer: float = 0.0
var _unit_stats_timer: float = 1.0

# ==================== FFA 外交部面板 ====================
var _diplo_panel: Control = null            # 面板根（右侧外交部）
var _diplo_scroll: ScrollContainer = null
var _diplo_content: VBoxContainer = null    # 滚动区内容（重建式渲染）
var _diplo_timer: float = 0.0               # 内容重建节流
var _diplo_hash: String = ""                # 上次渲染快照（变化才重建）
var _diplo_visible: bool = true             # 面板开关
var _diplo_toggle_btn: Button = null        # 左侧切换按钮
var _diplo_collapsed: bool = true            # 外交面板默认折叠
var _diplo_collapse_btn: Button = null
const DIPLO_WIDTH: float = 445.0
const DIPLO_EXPANDED_H: float = 400.0
const DIPLO_COLLAPSED_H: float = 44.0

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

# 国家特色：标题用短描述，下面一行用完整描述
func _nation_trait_short(nation: int) -> String:
	return NationBonuses.get_trait_short(nation)

func _nation_trait_full(nation: int) -> String:
	return NationBonuses.get_trait_full(nation)

func _find_local_castle(bm) -> Building:
	if bm == null: return null
	for e in bm.entities.get_children():
		if e is Building and e.entity_id == 20 and e.health > 0:
			if bm.is_local_player_owned(e.owner_peer_id, e.team):
				return e
	return null

# 单位血条上方的“国家类别”前缀：由 battle_manager 的 owner/队伍解析，未知国家返回空串
func _nat_tag(entity: GameEntity) -> String:
	var bm = _get_bm()
	if bm and bm.has_method("get_entity_nation") and bm.has_method("get_nation_name"):
		var nat = bm.get_entity_nation(entity)
		if nat >= 0:
			return "「%s」" % bm.get_nation_name(nat)
	return ""

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
# 战斗结算面板弹出时，隐藏所有统计/决策类面板，避免压在结算层上
func hide_stat_panels() -> void:
	unit_stats_visible = false
	if unit_stats_panel:
		unit_stats_panel.visible = false
	if _stats_capsule:
		_stats_capsule.visible = false
	if _diplo_panel:
		_diplo_panel.visible = false

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

func _create_unit_stats_panel():
	unit_stats_panel = Control.new()
	unit_stats_panel.name = "PlayerUnitStats"
	unit_stats_panel.z_index = 100
	unit_stats_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	unit_stats_panel.position = Vector2(10, 10)
	unit_stats_panel.size = Vector2(600, 560)

	# 与 AI 决策面板一致的暗色圆角底板
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

	# 五项资源：图标 + 数值 + 细进度条
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
	# 电脑版默认折叠：开局只显示资源/人口胶囊，点一下再展开完整面板
	_set_stats_collapsed(true)

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

	# 资源 / 国家 / 主城
	var res = bm.player_resources
	var lim = bm.player_resource_limits
	if bm.has_method("get_host_resources"):
		res = bm.get_host_resources()
		lim = bm.get_host_limits()
	var local_team = bm.get_local_team()
	var nation = bm.team_nations.get(local_team, -1)
	if _stats_title:
		_stats_title.text = "[color=#5af]👑 %s[/color] · [color=#ffd34f]%s[/color]" % [_get_nation_name(nation), _nation_trait_short(nation)]
	if _stats_bonus:
		_stats_bonus.text = _nation_trait_full(nation)
	for key in ["gold", "wood", "stone", "food", "oil"]:
		var lbl = _stats_res_labels.get(key)
		if lbl:
			lbl.text = "%d/%d" % [res.get(key, 0), lim.get(key, 500)]
		var rb = _stats_res_bars.get(key)
		if rb:
			rb.value = clampf(float(res.get(key, 0)) / maxf(float(lim.get(key, 500)), 1.0) * 100.0, 0.0, 100.0)
	var castle = _find_local_castle(bm)
	if _stats_castle_bar and _stats_castle_label:
		if castle:
			_stats_castle_bar.visible = true
			_stats_castle_bar.update_bar(castle.health, castle.max_health, -1, bm.get_entity_color(castle))
			_stats_castle_label.text = "🏰 主城 Lv.%d %d/%d" % [castle.upgrade_level, int(castle.health), int(castle.max_health)]
		else:
			_stats_castle_bar.visible = false
			_stats_castle_label.text = "🏰 主城 已失守"

	# 在线模式桥接
	var pop = bm.player_pop
	var max_pop = bm.player_max_pop
	if bm.has_method("get_host_resources"):
		pop = bm.get_host_pop()
		max_pop = bm.get_host_max_pop()

	# 更新人口
	if _stats_pop_label and _stats_pop_bar:
		_stats_pop_label.text = "👥 人口: %d/%d" % [pop, max_pop]
		_stats_pop_bar.value = min(float(pop) / max(max_pop, 1) * 100, 100)

	# 折叠时只刷新资源/人口胶囊
	if _stats_capsule and _stats_capsule.visible:
		_update_stats_capsule(res, lim, pop, max_pop)

	# 各资源采集人数 + 增长速率
	gather_counts = {"gold": 0, "wood": 0, "stone": 0, "food": 0, "oil": 0}
	for entity in bm.entities.get_children():
		if entity is Army and entity.health > 0 and bm.is_local_player_owned(entity.owner_peer_id, entity.team):
			if entity.entity_id in [10, 14] and entity.current_order in ["gather", "deliver"]:
				var tgt = entity.current_target
				if is_instance_valid(tgt) and tgt is WorldResource:
					var rt: String = tgt.resource_type
					if gather_counts.has(rt):
						gather_counts[rt] += 1
	if res_snapshot.is_empty():
		res_snapshot = res.duplicate()
	else:
		for rk in ["gold", "wood", "stone", "food", "oil"]:
			var cur = int(res.get(rk, 0))
			var prev = int(res_snapshot.get(rk, cur))
			if cur > prev:
				res_income[rk] = res_income.get(rk, 0) + (cur - prev)
			res_snapshot[rk] = cur
	income_timer -= 1.0
	if income_timer <= 0.0:
		income_timer = 10.0
		for rk in ["gold", "wood", "stone", "food", "oil"]:
			income_rate[rk] = res_income.get(rk, 0) / 10.0
			res_income[rk] = 0
	for rk in ["gold", "wood", "stone", "food", "oil"]:
		var info = _stats_res_info.get(rk)
		if info:
			info.text = "%d人 %+.1f/s" % [gather_counts.get(rk, 0), income_rate.get(rk, 0.0)]

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
	var under_construction = 0

	for entity in bm.entities.get_children():
		if not (entity is GameEntity) or entity.health <= 0:
			continue
		# 只统计本地玩家的单位/建筑：单机排除同队 AI，联机排除队友与敌方
		if not bm.is_local_player_owned(entity.owner_peer_id, entity.team):
			continue

		if entity is Army:
			unit_counts[entity.entity_id] = unit_counts.get(entity.entity_id, 0) + 1
		elif entity is Building:
			if entity.build_timer > 0:
				under_construction += 1
				continue
			building_counts[entity.entity_id] = building_counts.get(entity.entity_id, 0) + 1
			var lv: int = entity.upgrade_level
			if not building_levels.has(entity.entity_id) or building_levels[entity.entity_id] < lv:
				building_levels[entity.entity_id] = lv

	# 军队统计（与下方展示列表使用同一组 ID，保证总数与明细一致）
	var military_ids = [11, 12, 13, 15, 16, 17, 18, 19, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 55, 56, 57, 58, 59, 65, 66]
	var military_total = 0
	for uid in military_ids:
		military_total += unit_counts.get(uid, 0)
	var building_total = 0
	for bid in building_counts:
		building_total += building_counts[bid]
	var under_txt := ""
	if under_construction > 0:
		under_txt = "    [color=#caa]🏗️ 在建 %d[/color]" % under_construction
	if _stats_mil_title:
		_stats_mil_title.text = "[color=#5af]▸ ⚔️ 军队 %d[/color]" % military_total
	if _stats_bld_title:
		_stats_bld_title.text = "[color=#5af]▸ 🏰 建筑 %d[/color]%s" % [building_total, under_txt]

	# 经济单位（农民、采集船、商人、手推车、贸易车、运载船、官员）
	var eco_ids = [10, 14, 5, 6, 9, 43, 44, 45, 51, 46, 47, 48, 49, 50]
	var eco_total = 0
	var eco_lines = []
	for uid in eco_ids:
		var cnt = unit_counts.get(uid, 0)
		eco_total += cnt
		if cnt > 0:
			var name = unit_names.get(uid, str(uid))
			eco_lines.append("[color=#8c8]%s %s[/color]:[color=white]%d[/color]" % [UITheme.entity_emoji(uid, 2), name, cnt])
	if _stats_eco_title:
		_stats_eco_title.text = "[color=#5af]▸ 💰 经济 %d[/color]" % eco_total
	_stats_eco_rtl.text = "[color=gray](无经济单位)[/color]" if eco_lines.is_empty() else " ".join(eco_lines)

	var military_lines = []
	for uid in military_ids:
		var cnt = unit_counts.get(uid, 0)
		if cnt > 0:
			var name = unit_names.get(uid, str(uid))
			military_lines.append("[color=#aaa]%s %s[/color]:[color=white]%d[/color]" % [UITheme.entity_emoji(uid, 2), name, cnt])
	_stats_mil_rtl.text = "[color=gray](无军队)[/color]" if military_lines.is_empty() else " ".join(military_lines)

	# 建筑统计
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


func _input(event):
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_F1:
				if event.ctrl_pressed: _on_select_all_pressed()
				else: _on_select_screen_pressed()
			KEY_F2: _on_attack_all_pressed()
			KEY_F3:
				if event.ctrl_pressed: _on_retreat_all_pressed()
				else: _on_retreat_screen_pressed()
			KEY_H: _on_stop_gather_pressed()
			KEY_P: _on_hold_position_pressed()
			KEY_DELETE: _on_demolish_selected()
			KEY_SPACE: _on_space_pressed()
			KEY_L: _toggle_unit_text()

# L 键：切换血条文字显示（隐藏后画面上只剩血条色条）
func _toggle_unit_text():
	show_unit_text = not show_unit_text
	show_alert_message("单位血条文字：%s" % ("显示" if show_unit_text else "隐藏"), ALERT_INFO)

func _on_space_pressed():
	# 优先：释放选中建筑的进驻单位
	var bm = _get_bm()
	if bm and bm.has_node("SelectionManager"):
		var sm = bm.get_node("SelectionManager")
		if sm.has_method("get_selected_entities"):
			var sel = sm.get_selected_entities()
			var released = false
			for e in sel:
				if e is Building and e.garrisoned_soldiers.size() > 0:
					e.release_all_garrisoned()
					released = true
				elif e is Army and e.entity_id == 18 and e._ram_garrisoned_soldiers.size() > 0:
					e._recalc_ram_garrison_bonus.call_deferred()
					for uid in e._ram_garrisoned_soldiers.duplicate():
						var unit = instance_from_id(uid)
						if unit and is_instance_valid(unit):
							unit._exit_soldier_garrison()
					released = true
			if released: return
	# 否则：跳转到警报位置
	_on_jump_to_alert()

func _on_jump_to_alert():
	var minimap = $Minimap as Minimap
	if minimap and minimap.has_latest_alert:
		var cam = get_viewport().get_camera_3d()
		if cam:
			var target = minimap.latest_alert_world_pos
			if cam.has_method("focus_on_ground"):
				cam.focus_on_ground(target)
			else:
				cam.global_position = Vector3(target.x, cam.global_position.y, target.z)
			minimap.has_latest_alert = false
			return
	# 没有待处理的小地图警报时兜底跳回主城，避免点击后没有任何反应
	var bm2 = _get_bm()
	var castle = null
	if bm2 and bm2.has_method("get_player_castle"):
		castle = bm2.call("get_player_castle")
	if castle and is_instance_valid(castle):
		var cam2 = get_viewport().get_camera_3d()
		if cam2:
			if cam2.has_method("focus_on_ground"):
				cam2.focus_on_ground(castle.global_position)
			else:
				cam2.global_position = Vector3(castle.global_position.x, cam2.global_position.y, castle.global_position.z)


# 本地玩家的战斗单位（排除农民/采集船/商人/推车/官员等经济单位）
func _get_local_military_units(screen_only: bool) -> Array:
	var units: Array = []
	var bm = _get_bm()
	if not bm: return units
	var cam = get_viewport().get_camera_3d()
	var vp_rect = get_viewport().get_visible_rect()
	for e in bm.entities.get_children():
		if not (e is Army) or e.health <= 0: continue
		if not bm.is_local_player_owned(e.owner_peer_id, e.team): continue
		if e.entity_id in [10, 14, 5, 6, 9, 43, 44, 45, 51, 46, 47, 48, 49, 50]: continue
		if screen_only:
			if cam == null: continue
			if cam.projection != Camera3D.PROJECTION_ORTHOGONAL and cam.is_position_behind(e.global_position): continue
			if not vp_rect.has_point(cam.unproject_position(e.global_position)): continue
		units.append(e)
	return units

func _select_units(units: Array):
	var bm = _get_bm()
	if not bm: return
	var sm = bm.get_node_or_null("SelectionManager")
	if not sm: return
	sm._clear_selection()
	for u in units:
		if is_instance_valid(u) and u not in sm.selected_entities:
			sm.selected_entities.append(u)
			u.set_selected(true)
	sm._update_info_panel()

func _on_select_screen_pressed():
	_select_units(_get_local_military_units(true))

func _on_select_all_pressed():
	_select_units(_get_local_military_units(false))

func _on_attack_all_pressed():
	var bm = _get_bm()
	if not bm: return
	auto_attack_on = not auto_attack_on
	if bm.has_method("set_local_auto_attack"):
		bm.set_local_auto_attack(auto_attack_on)
	_update_auto_attack_button()
	show_alert_message("自动进攻：%s" % ("开启" if auto_attack_on else "关闭"), ALERT_WARNING if auto_attack_on else ALERT_INFO)

func _update_auto_attack_button():
	if auto_attack_btn:
		auto_attack_btn.text = "⚔️ 自动进攻：%s (F2)" % ("开" if auto_attack_on else "关")

func _retreat_units(units: Array):
	var bm = _get_bm()
	if not bm: return
	var home = bm.get_player_castle()
	if home == null: return
	var n = max(units.size(), 1)
	for i in range(units.size()):
		var u = units[i]
		if not is_instance_valid(u): continue
		var ang = TAU * float(i) / float(n)
		var dest = home.global_position + Vector3(cos(ang) * 4.0, 0.0, sin(ang) * 4.0)
		u.move_to(dest)

func _on_retreat_screen_pressed():
	_retreat_units(_get_local_military_units(true))

func _on_retreat_all_pressed():
	_retreat_units(_get_local_military_units(false))

func _on_rally_pressed():
	_on_select_all_pressed()

# 全局指令按钮：统一尺寸，交给 GridContainer 排两行
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

# 对局内设置面板入口（按钮本身在全局指令底板第二排最后一个）
func _open_game_settings() -> void:
	if get_node_or_null("GameSettingsPanel"):
		return
	var panel: Control = preload("res://scripts/ui/GameSettingsPanel.gd").new()
	add_child(panel)
	panel.call("setup", false, false)

func _ready():
	# 电脑版左下角的虚拟摇杆用不上：隐藏并停掉它的输入处理，避免抢占鼠标
	if not InputSource.use_mobile_ui():
		var stick := get_node_or_null("VirtualStick")
		if stick is Control:
			stick.visible = false
			stick.set_process(false)
			stick.set_process_input(false)
			stick.set_process_unhandled_input(false)

	_create_unit_stats_panel()

	# 全局指令：6 个按钮正好排成两排（3×2），统一放在一块半透明底板里
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

	var b_select_screen = _make_cmd_button("全选屏幕军队 (F1)", _on_select_screen_pressed, false)
	var b_select_all = _make_cmd_button("全选所有军队 (Ctrl+F1)", _on_select_all_pressed, false)
	auto_attack_btn = _make_cmd_button("⚔️ 自动进攻：关 (F2)", _on_attack_all_pressed, true)
	var b_retreat_screen = _make_cmd_button("屏幕军队撤退 (F3)", _on_retreat_screen_pressed, false)
	var b_retreat_all = _make_cmd_button("所有军队撤退 (Ctrl+F3)", _on_retreat_all_pressed, false)
	var b_settings = _make_cmd_button("⚙ 设置", _open_game_settings, false)
	for b in [b_select_screen, b_select_all, auto_attack_btn, b_retreat_screen, b_retreat_all, b_settings]:
		cmd_grid.add_child(b)

	set_process(true)

	# 移动端：装配触屏界面（桌面端不进入此分支，零改动）
	if InputSource.use_mobile_ui():
		_mobile_hud = MobileHUD.new()
		add_child(_mobile_hud)
		_mobile_hud.setup(self)
const ALERT_DANGER = UITheme.ALERT_DANGER     # 红色 — 基地/建筑被攻击
const ALERT_WARNING = UITheme.ALERT_WARNING   # 黄色 — 敌军来袭/资源不足
const ALERT_INFO = UITheme.ALERT_INFO      # 绿色 — 建造/训练/升级完成
const ALERT_GROUP = UITheme.ALERT_GROUP     # 蓝色 — 编队反馈

func show_alert_message(msg: String, color: Color = ALERT_DANGER):
	var mobile := InputSource.use_mobile_ui()
	if not _alert_label:
		# 皇庭横幅背景：暖黑底 + 警报色细边 + 顶部警报色强调条（与联机客户端同一套皮肤）
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
	# 横幅底色压到半透明：原来 0.88 几乎是一块实心黑条，报警时正好挡住最需要看的战场。
	# 文字带黑色描边，降到 0.55 依然清晰。
	var ab := StyleBoxFlat.new()
	ab.bg_color = Color(UITheme.INK, 0.55)
	ab.set_corner_radius_all(UITheme.RADIUS_MD)
	ab.set_border_width_all(UITheme.BORDER_THIN)
	ab.border_color = Color(color, 0.5)
	ab.border_width_top = UITheme.BORDER_THICK
	_alert_bg.add_theme_stylebox_override("panel", ab)
	_alert_label.visible = true
	_alert_bg.visible = true
	_alert_timer = 3.0

	set_process(true)

# 点警报条：跳到警报位置（没有小地图警报时至少跳回主城，保证有反馈）
func _on_alert_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_on_jump_to_alert()
		_alert_timer = 0.0
		if _alert_label: _alert_label.visible = false
		if _alert_bg: _alert_bg.visible = false
		get_viewport().set_input_as_handled()


func update_data(resources: Dictionary, population: Dictionary, limits: Dictionary = {}):
	for rk in ["gold", "wood", "stone", "food", "oil"]:
		var lbl = _stats_res_labels.get(rk)
		if lbl:
			lbl.text = "%d" % resources.get(rk, 0)
		var rb = _stats_res_bars.get(rk)
		if rb:
			var rl = limits.get(rk, 500) if not limits.is_empty() else 500
			rb.value = clampf(float(resources.get(rk, 0)) / maxf(float(rl), 1.0) * 100.0, 0.0, 100.0)
	if _stats_pop_label:
		_stats_pop_label.text = "👥 人口: %d/%d" % [population.get("current", 0), population.get("max", 0)]
	if _stats_pop_bar:
		_stats_pop_bar.value = clampf(float(population.get("current", 1)) / maxf(float(population.get("max", 1)), 1.0) * 100.0, 0.0, 100.0)
	if _mobile_hud and is_instance_valid(_mobile_hud):
		_mobile_hud.update_data(resources, population, limits, gather_counts, income_rate)
func _process(delta):
	_tick_ffa_diplo(delta)
	_unit_stats_timer -= delta
	var bm = _get_bm()
	if bm == null:
		return
	if bm.game_over and unit_stats_visible:
		hide_stat_panels()
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
				# 用 battle 的存活实体缓存，避免每 0.5s 重新遍历 entities 子节点并做类型判断
				if bm.has_method("_ensure_cache_fresh"):
					bm._ensure_cache_fresh()
				for entity in bm._all_entities:
					if entity.health > 0:
						entities_info.append({
							"x": entity.global_position.x,
							"z": entity.global_position.z,
							"team": entity.team,
							"type": entity.entity_type,
							"id": entity.get_instance_id(),
							"entity_id": entity.entity_id,
							"owner_peer_id": entity.owner_peer_id,
							"color": bm.get_entity_color(entity) if bm.has_method("get_entity_color") else Color.WHITE
						})
				# 只有迷雾真正变化时才让小地图重建底图；单位点移动只重绘点
				var fog_ver: int = int(bm.fog_version)
				var terrain_dirty: bool = fog_ver != _minimap_fog_version
				_minimap_fog_version = fog_ver
				minimap.set_data(bm.explored_grid, bm.visible_grid, entities_info, terrain_dirty)

	# 警报消息计时
	if _alert_label and _alert_timer > 0:
		_alert_timer -= delta
		if _alert_timer <= 0:
			_alert_label.visible = false
			if _alert_bg:
				_alert_bg.visible = false

	health_bar_timer -= delta
	if health_bar_timer <= 0:
		# 后期实体越多，血条/文字 Control 的布局开销越大；分档降频，
		# 220 个以内保持 20Hz，超过后降到约 10Hz / 7Hz，画面仍可接受。
		var entity_count: int = bm._all_entities.size()
		var bar_interval := HEALTH_BAR_UPDATE_INTERVAL
		if entity_count > 320:
			bar_interval = 0.14
		elif entity_count > 220:
			bar_interval = 0.10
		elif entity_count > 140:
			bar_interval = 0.07
		health_bar_timer = bar_interval
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
	var base_size = Vector2(50, 8)     # 原 100x16；血条宽 ×0.5、高 ×0.25 后再把高度 ×2
	var base_font = 18                 # 原 12 → 18
	var ref_ortho_size = 30.0
	var scale_factor = 1.0
	if cam.projection == Camera3D.PROJECTION_ORTHOGONAL:
		scale_factor = ref_ortho_size / cam.size
	var bar_size = base_size * scale_factor
	var font_size = int(base_font * scale_factor)
	var cam_rect := get_viewport().get_visible_rect()
	var refresh_style := absf(scale_factor - _last_health_scale) > 0.001
	if refresh_style:
		_last_health_scale = scale_factor
	# 血量文字与血条使用同一刷新周期，避免文字比血条慢一拍；后期实体多时
	# 满血单位的文字仍会被下面的 text_budget 省掉，避免大量 Label 重排。
	var bm_for_text = _get_bm()
	var refresh_text := true
	var sm = _get_sm()
	var ent_total: int = bm_for_text._all_entities.size() if bm_for_text else 0
	# 后期实体多时，满血单位连名字/血量文字一起省掉：几百个 Label 的布局与绘制
	# 是 UI 侧最大开销，战斗中的受伤单位仍会照常显示
	var text_budget: bool = ent_total <= 220

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
			if unit_bars[e].has("build_bar") and unit_bars[e].build_bar:
				unit_bars[e].build_bar.queue_free()
			if unit_bars[e].has("upgrade_bar") and unit_bars[e].upgrade_bar:
				unit_bars[e].upgrade_bar.queue_free()
			if unit_bars[e].has("upgrade_label") and unit_bars[e].upgrade_label:
				unit_bars[e].upgrade_label.queue_free()
			unit_bars.erase(e)

	# 遍历所有实体
	for entity in entities:
		if not is_instance_valid(entity) or entity.health <= 0:
			continue
		# 第一人称跟随视角：被跟随单位自身的血条锚点位于相机处，会悬浮在画面中央——隐藏
		if cam.has_method("get_follow_target") and cam.get_follow_target() == entity:
			_hide_entity_health_bars(entity)
			continue
		if not entity.visible:
			_hide_entity_health_bars(entity)
			continue

		# 先做屏幕裁剪：离屏实体不创建血条/文字节点，已有节点直接隐藏
		var world_pos = entity.global_position + Vector3.UP * (entity.body_radius * 2 + 0.5)
		# 透视投影下相机后方的实体会 unproject 出翻转坐标——隐藏血条
		if cam.projection != Camera3D.PROJECTION_ORTHOGONAL and cam.is_position_behind(world_pos):
			_hide_entity_health_bars(entity)
			continue
		var screen_pos = cam.unproject_position(world_pos)
		if not cam_rect.has_point(screen_pos):
			_hide_entity_health_bars(entity)
			continue

		var data = unit_bars.get(entity)
		var created := false
		if data == null:
			# 满血陆军不创建任何血条/文字节点：后期同屏几百个单位时，这些节点
			# 即使 visible=false 也要参与布局与场景树维护。受伤后再按需创建。
			if entity is Army and entity.health >= entity.max_health:
				continue
			_create_health_bar(entity)
			data = unit_bars[entity]
			created = true

		var bar: HealthBarControl = data.bar
		var label: Label = data.label
		var prod_bar: ProgressBar = data.prod_bar if data.has("prod_bar") else null
		var prod_label: Label = data.prod_label if data.has("prod_label") else null

		# 动态调整尺寸与字体（仅相机缩放变化或新建时）
		if refresh_style or created:
			# 最小尺寸跟随缩放，否则 Control 会被默认/旧的 custom_minimum_size 卡住
			bar.custom_minimum_size = bar_size
			bar.size = bar_size
			label.add_theme_font_size_override("font_size", font_size)
			if prod_bar:
				prod_bar.custom_minimum_size = Vector2(bar_size.x, 8 * scale_factor)
				prod_label.add_theme_font_size_override("font_size", max(int(font_size * 0.8), 12))

		var refresh_text_now := refresh_text or created
		_hide_build_bar(entity)
		bar.position = screen_pos - bar_size / 2

		# 建造进度
		# Upgrade progress (matches health bar scaling)
		if entity is Building and entity.upgrade_timer > 0:
			var up_bar_data = unit_bars[entity]
			var up_bar = up_bar_data.get("upgrade_bar")
			var up_lbl = up_bar_data.get("upgrade_label")
			if not up_bar:
				up_bar = ProgressBar.new()
				UITheme.style_progress_bar(up_bar, UITheme.UPGRADE_PROGRESS, 8.0)
				add_child(up_bar); up_bar_data["upgrade_bar"] = up_bar
				up_bar.z_index = -1
			if not up_lbl:
				up_lbl = Label.new()
				up_lbl.add_theme_color_override("font_color", Color.WHITE)
				up_lbl.add_theme_color_override("font_outline_color", Color.BLACK)
				up_lbl.add_theme_constant_override("outline_size", 1)
				add_child(up_lbl); up_bar_data["upgrade_label"] = up_lbl
				up_lbl.z_index = -1
			up_bar.custom_minimum_size = Vector2(bar_size.x, 8 * scale_factor)
			up_lbl.add_theme_font_size_override("font_size", font_size)
			up_bar.visible = true; up_lbl.visible = show_unit_text
			var up_total := maxf(entity.max_upgrade_time, 0.001)
			var up_pct := clampf(1.0 - entity.upgrade_timer / up_total, 0.0, 1.0)
			up_bar.value = up_pct
			if refresh_text_now:
				up_lbl.text = "升级中 %d%%" % int(up_pct * 100.0)
			up_bar.position = screen_pos - bar_size / 2 + Vector2(0, -bar_size.y * 2 - 6)
			up_lbl.position = up_bar.position + Vector2(0, -bar_size.y - 4)
		else:
			var up_data2 = unit_bars[entity]
			if up_data2.has("upgrade_bar") and up_data2.upgrade_bar:
				up_data2.upgrade_bar.visible = false
			if up_data2.has("upgrade_label") and up_data2.upgrade_label:
				up_data2.upgrade_label.visible = false

		if entity is Building and entity.has_method("is_under_construction") and entity.is_under_construction():
			var bdata = unit_bars[entity]
			var build_bar: ProgressBar = bdata.get("build_bar")
			if not build_bar:
				build_bar = ProgressBar.new()
				UITheme.style_progress_bar(build_bar, UITheme.BUILD_PROGRESS, 8.0)
				add_child(build_bar); build_bar.z_index = -1
				bdata["build_bar"] = build_bar
			var build_total := maxf(entity.max_build_time, 0.001)
			var build_pct := clampf(1.0 - entity.build_timer / build_total, 0.0, 1.0)
			build_bar.visible = true
			build_bar.size = Vector2(bar_size.x, 8 * scale_factor)
			build_bar.position = bar.position + Vector2(0, -bar_size.y - 4)
			build_bar.value = build_pct
			bar.visible = false
			label.visible = show_unit_text
			if refresh_text_now:
				label.text = "%s (建造中 %d%%)" % [entity.display_name, int(build_pct * 100.0)]
				# Color label
				var _hlc2 = _get_hud_label_color(entity)
				label.add_theme_color_override("font_color", _hlc2)
				_apply_hud_label_outline(label, entity)
			label.position = build_bar.position + Vector2(0, -22)
			if prod_bar:
				prod_bar.visible = false
				prod_label.visible = false
			continue

		# 生产队列进度条
		var has_production = entity is Building and entity.production_queue.size() > 0
		if prod_bar and prod_label:
			if has_production:
				prod_bar.visible = true
				prod_label.visible = show_unit_text
				var current_id = entity.production_queue[0]
				var prod_cfg = null
				for p in entity.production_list:
					if p.unit_id == current_id:
						prod_cfg = p
						break
				if prod_cfg:
					var progress = 1.0 - (entity.production_timer / prod_cfg.cooldown)
					progress = clampf(progress, 0.0, 1.0)
					prod_bar.max_value = 1.0
					prod_bar.value = progress
					if refresh_text_now:
						var unit_cfg = EntityDatabase.get_config(current_id)
						var unit_name = unit_cfg.get("name", "?")
						prod_label.text = "%s x%d %d%%" % [unit_name, entity.production_queue.size(), int(progress * 100.0)]
					prod_bar.position = bar.position + Vector2(0, bar_size.y + 4)
					prod_label.position = prod_bar.position + Vector2(0, -14)
				else:
					prod_bar.visible = false
					prod_label.visible = false
			else:
				prod_bar.visible = false
				prod_label.visible = false

		var show_text: bool = show_unit_text and (text_budget or entity.health < entity.max_health)
		label.visible = show_text
		if refresh_text_now and show_text:
			var group_prefix = ""
			if sm and sm.has_method("get_entity_groups"):
				var groups = sm.get_entity_groups(entity)
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
				_res_info = "\n交易量:%d" % entity._merchant_trade_volume
			label.text = group_prefix + _nat_tag(entity) + "%s Lv.%d%s\n%d/%d" % [entity.display_name, entity.level, _res_info, int(entity.health), int(entity.max_health)]
			# Color label by owner/team
			var _hlc = _get_hud_label_color(entity)
			label.add_theme_color_override("font_color", _hlc)
			_apply_hud_label_outline(label, entity)
		label.position = bar.position + Vector2(0, -22)

		if entity.health >= entity.max_health:
			bar.visible = false
			label.visible = false
			continue

		bar.visible = true
		# 血条颜色与模型一致：按 owner_peer_id 取该 AI/玩家专属阵营色（乱斗/2v2 各阵营颜色不同）
		var bm2 = _get_bm()
		var bar_color: Color = Color(0.2, 0.6, 1.0)
		if bm2 and bm2.has_method("get_entity_color"):
			bar_color = bm2.get_entity_color(entity)
		bar.update_bar(entity.health, entity.max_health, entity.team, bar_color)


func _hide_entity_health_bars(entity):
	var d = unit_bars.get(entity)
	if d == null:
		return
	d.bar.visible = false
	d.label.visible = false
	if d.has("prod_bar") and d.prod_bar:
		d.prod_bar.visible = false
	if d.has("prod_label") and d.prod_label:
		d.prod_label.visible = false
	if d.has("upgrade_bar") and d.upgrade_bar:
		d.upgrade_bar.visible = false
	if d.has("upgrade_label") and d.upgrade_label:
		d.upgrade_label.visible = false
	_hide_build_bar(entity)

func _hide_build_bar(entity):
	if entity in unit_bars:
		var d = unit_bars[entity]
		if d.has("build_bar") and d.build_bar:
			d.build_bar.visible = false

func _create_health_bar(entity):
	var bar = HealthBarControl.new()
	bar.size = Vector2(50, 8)
	bar.visible = false
	bar.z_index = -1
	add_child(bar)
	# add_child 会触发 HealthBarControl._ready 写入默认最小尺寸，需在其后覆盖，
	# 否则 50x8 的血条会被 80x12 撑回去
	bar.custom_minimum_size = Vector2(50, 8)

	var label = Label.new()
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 1)
	label.z_index = -1
	add_child(label)

	var data := {"bar": bar, "label": label}
	unit_bars[entity] = data

	# 只有建筑需要生产进度条；单位/资源不要为每一条血条额外创建 ProgressBar + Label
	if entity is Building:
		var prod_bar = ProgressBar.new()
		UITheme.style_progress_bar(prod_bar, UITheme.SAPPHIRE, 8.0)
		prod_bar.visible = false
		prod_bar.z_index = -1
		add_child(prod_bar)
		data["prod_bar"] = prod_bar

		var prod_label = Label.new()
		prod_label.add_theme_font_size_override("font_size", 12)
		prod_label.z_index = -1
		add_child(prod_label)
		prod_label.visible = false
		data["prod_label"] = prod_label


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
	var sm = _get_sm()
	if sm and sm.has_method("get_entity_groups"):
		var groups = sm.get_entity_groups(entity)
		if groups.size() > 0:
			var g = groups[0]
			if GROUP_LABEL_COLORS.has(g):
				return GROUP_LABEL_COLORS[g]
	
	return Color.WHITE

# 血条标签镶边：玩家自己的单位用绿色，友军/敌军仍用所属国家/阵营色
func _apply_hud_label_outline(label: Label, entity: GameEntity) -> void:
	var bm = _get_bm()
	if not bm: return
	var is_own := false
	if entity.owner_peer_id != -1:
		is_own = entity.owner_peer_id == bm.player_owner_id
	else:
		is_own = entity.team == bm.get_host_team()
	var outline: Color = Color(0.25, 1.0, 0.35) if is_own else bm.get_entity_color(entity)
	label.add_theme_color_override("font_outline_color", outline)
	label.add_theme_constant_override("outline_size", 2)

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


# ==================== FFA 外交部面板 ====================

# 规范对键（小|大），与 DiplomacyManager 一致
func _diplo_pair_key(a: int, b: int) -> String:
	var lo := a if a < b else b
	var hi := b if a < b else a
	return "%d|%d" % [lo, hi]

# 每帧驱动：仅单机 FFA 生效；面板未建则建，节流重建
func _tick_ffa_diplo(delta: float):
	var bm := _get_bm() as RTSBattleManager
	if bm == null or not bm.is_ffa or bm.diplomacy == null:
		return
	if _diplo_panel == null:
		_build_diplo_panel()
	_diplo_panel.visible = not bm.game_over
	if not _diplo_panel.visible:
		return
	_diplo_timer -= delta
	if _diplo_timer > 0.0:
		return
	_diplo_timer = 0.4
	var snap := _diplo_snapshot()
	if snap != _diplo_hash:
		_diplo_hash = snap
		_rebuild_diplo_content()

func _build_diplo_panel():
	if _diplo_panel != null:
		return
	var panel := Panel.new()
	panel.name = "DiploPanel"
	panel.z_index = 120
	panel.position = Vector2(1945, 100)
	panel.size = Vector2(DIPLO_WIDTH, DIPLO_COLLAPSED_H)
	panel.add_theme_stylebox_override("panel", UITheme.panel_style(UITheme.RADIUS_LG, UITheme.BORDER_MED, 0.92))
	add_child(panel)
	_diplo_panel = panel

	var title := UITheme.make_section_title("🕊️ 外交部", UITheme.GOLD, UITheme.FONT_XL)
	title.position = Vector2(14, 8)
	panel.add_child(title)

	_diplo_collapse_btn = Button.new()
	_diplo_collapse_btn.text = "▲"
	_diplo_collapse_btn.toggle_mode = true
	_diplo_collapse_btn.button_pressed = true
	_diplo_collapse_btn.custom_minimum_size = Vector2(36, 28)
	_diplo_collapse_btn.position = Vector2(DIPLO_WIDTH - 48, 6)
	_diplo_collapse_btn.tooltip_text = "展开外交面板"
	UITheme.apply_muted_button(_diplo_collapse_btn, UITheme.FONT_MD)
	_diplo_collapse_btn.pressed.connect(_on_diplo_collapse_pressed)
	panel.add_child(_diplo_collapse_btn)

	var scroll := ScrollContainer.new()
	scroll.name = "DiploScroll"
	scroll.position = Vector2(10, 44)
	scroll.size = Vector2(DIPLO_WIDTH - 20, DIPLO_EXPANDED_H - 54)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.visible = false
	panel.add_child(scroll)
	_diplo_scroll = scroll

	var content := VBoxContainer.new()
	content.name = "DiploContent"
	content.add_theme_constant_override("separation", 6)
	scroll.add_child(content)
	_diplo_content = content
	_rebuild_diplo_content()
	set_diplo_collapsed(true, false)
	if _get_bm() and _get_bm().has_method("layout_ai_debug_panels"):
		_get_bm().call_deferred("layout_ai_debug_panels")

func is_diplo_collapsed() -> bool:
	return _diplo_collapsed

func get_diplo_panel_height() -> float:
	return DIPLO_COLLAPSED_H if _diplo_collapsed else DIPLO_EXPANDED_H

func get_diplo_panel_width() -> float:
	return DIPLO_WIDTH

func set_diplo_collapsed(collapsed: bool, relayout: bool = true):
	_diplo_collapsed = collapsed
	if _diplo_scroll:
		_diplo_scroll.visible = not collapsed
		_diplo_scroll.size = Vector2(DIPLO_WIDTH - 20, DIPLO_EXPANDED_H - 54)
	if _diplo_collapse_btn:
		_diplo_collapse_btn.button_pressed = collapsed
		_diplo_collapse_btn.text = "▲" if collapsed else "▼"
		_diplo_collapse_btn.tooltip_text = "展开外交面板" if collapsed else "折叠外交面板"
	if _diplo_panel:
		var h = get_diplo_panel_height()
		_diplo_panel.custom_minimum_size = Vector2(DIPLO_WIDTH, h)
		_diplo_panel.size = Vector2(DIPLO_WIDTH, h)
		if not collapsed:
			_diplo_panel.set_meta("expanded_at", Time.get_ticks_msec())
	if relayout:
		var bm = _get_bm()
		if bm and bm.has_method("layout_ai_debug_panels"):
			bm.layout_ai_debug_panels()

func _on_diplo_collapse_pressed():
	set_diplo_collapsed(_diplo_collapse_btn.button_pressed, true)

# 外交部另一入口：左侧切换按钮
func _build_diplo_toggle():
	if _diplo_toggle_btn != null:
		return
	var btn := Button.new()
	btn.name = "DiploToggle"
	btn.text = "🕊️ 外交"
	btn.position = Vector2(176, 540)
	btn.toggle_mode = true
	btn.button_pressed = true
	UITheme.apply_muted_button(btn, UITheme.FONT_LG)
	btn.pressed.connect(_diplo_toggle_pressed)
	add_child(btn)
	_diplo_toggle_btn = btn

func _diplo_toggle_pressed():
	if _diplo_toggle_btn == null:
		return
	_diplo_visible = _diplo_toggle_btn.button_pressed
	if _diplo_panel:
		_diplo_panel.visible = _diplo_visible

# 外交状态快照：任何字段变化都会改变 hash → 触发重建
func _diplo_snapshot() -> String:
	var bm := _get_bm() as RTSBattleManager
	if bm == null or bm.diplomacy == null:
		return ""
	var d: DiplomacyManager = bm.diplomacy
	var player: int = bm.player_owner_id
	var parts: Array = []
	parts.append(str(player))
	var ally: int = d.get_ally(player)
	parts.append(str(ally))
	var inc: Array = d.get_incoming_proposals(player)
	inc.sort()
	parts.append(str(inc))
	if ally != -1:
		parts.append(str(max(int(d.alliance_remaining(player)), 0)))
		var key := _diplo_pair_key(player, ally)
		var al: Dictionary = d.alliances.get(key, {})
		parts.append(str(al.get("total_tribute", 0)))
	else:
		parts.append("-1")
		parts.append("0")
	parts.append(str(int(d._pending_proposals.get(player, -1))))
	var keys: Array = d.nations.keys()
	keys.sort()
	for owner in keys:
		var o: int = int(owner)
		if o == player or not d.is_nation_alive(o):
			continue
		var st: String = d.get_display_name(o)
		if d.is_ruptured_pair(player, o):
			st += "·裂"
		if d.is_betrayer(o):
			st += "·叛"
		st += "·" + str(int(d._pending_proposals.get(o, -1) == player))
		parts.append(st)
	return str(parts)

# 重建外交部滚动内容（三节：收到的提议 / 我的盟约 / 可结盟国家）
func _rebuild_diplo_content():
	if _diplo_content == null:
		return
	for c in _diplo_content.get_children():
		c.free()
	var bm := _get_bm() as RTSBattleManager
	if bm == null or bm.diplomacy == null:
		return
	var d: DiplomacyManager = bm.diplomacy
	var player: int = bm.player_owner_id
	var ally: int = d.get_ally(player)

	_add_diplo_section("📨 收到的提议")
	var inc: Array = d.get_incoming_proposals(player)
	inc.sort()
	if inc.is_empty():
		_add_diplo_card("暂无国家向你提议", UITheme.STONE)
	else:
		for proposer in inc:
			_add_proposal_row(d, player, int(proposer))

	_add_diplo_section("🤝 我的盟约")
	if ally == -1:
		_add_diplo_card("当前没有盟约", UITheme.STONE)
	else:
		_add_alliance_card(d, player, ally)

	_add_diplo_section("⚔️ 可结盟国家")
	if ally != -1:
		_add_diplo_card("你已结盟 —— 决裂前无法再结盟", UITheme.ALERT_WARNING)
	else:
		var my_pending: int = int(d._pending_proposals.get(player, -1))
		var keys: Array = d.nations.keys()
		keys.sort()
		for owner in keys:
			var o: int = int(owner)
			if o == player or not d.is_nation_alive(o):
				continue
			_add_ally_option_row(d, player, o, o == my_pending)

func _add_diplo_section(text: String) -> void:
	var lb: Label = UITheme.make_section_title(text, UITheme.PARCHMENT, UITheme.FONT_LG)
	_diplo_content.add_child(lb)

func _add_diplo_card(text: String, accent: Color) -> void:
	var lb := Label.new()
	lb.text = text
	lb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.apply_label(lb, UITheme.FONT_SM)
	_diplo_content.add_child(_wrap_card(lb, accent))

# 卡片包裹：内容 + 内边距 + 顶部强调色边框
func _wrap_card(content: Control, accent: Color) -> PanelContainer:
	var pc := PanelContainer.new()
	pc.add_theme_stylebox_override("panel", UITheme.card_style(accent))
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_bottom", 6)
	pc.add_child(margin)
	margin.add_child(content)
	return pc

# 一条收到的结盟提议：[国家] 请求与你结盟  [接受] [拒绝]
func _add_proposal_row(d: DiplomacyManager, player: int, proposer: int) -> void:
	var hb := HBoxContainer.new()
	hb.custom_minimum_size = Vector2(0, 36)
	hb.add_theme_constant_override("separation", 8)
	var lb := Label.new()
	lb.text = "%s 请求与你结盟" % d.get_display_name(proposer)
	lb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.apply_label(lb, UITheme.FONT_SM)
	hb.add_child(lb)
	var accept := Button.new()
	accept.text = "接受"
	UITheme.apply_primary_button(accept, UITheme.FONT_SM)
	accept.pressed.connect(_diplo_accept.bind(proposer))
	hb.add_child(accept)
	var decline := Button.new()
	decline.text = "拒绝"
	UITheme.apply_danger_button(decline, UITheme.FONT_SM)
	decline.pressed.connect(_diplo_decline.bind(proposer))
	hb.add_child(decline)
	_diplo_content.add_child(_wrap_card(hb, UITheme.ALERT_GROUP))

# 我的盟约卡：盟友 / 剩余时间 / 累计进贡 / 四种资源进贡按钮 / 决裂
func _add_alliance_card(d: DiplomacyManager, player: int, ally: int) -> void:
	var ally_name: String = d.get_display_name(ally)
	var remaining: float = d.alliance_remaining(player)
	var secs: int = maxi(int(remaining), 0)
	var mm: int = secs / 60
	var ss: int = secs % 60
	var key := _diplo_pair_key(player, ally)
	var al: Dictionary = d.alliances.get(key, {})
	var tribute: int = int(al.get("total_tribute", 0))
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	var info := Label.new()
	info.text = "盟友：%s\n剩余时间：%02d:%02d\n累计进贡：%d" % [ally_name, mm, ss, tribute]
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.apply_label(info, UITheme.FONT_MD)
	vb.add_child(info)
	var trib_lb := Label.new()
	trib_lb.text = "进贡 %d（选择资源，可延长盟约）:" % DiplomacyManager.TRIBUTE_DELIVERY
	UITheme.apply_label(trib_lb, UITheme.FONT_SM, UITheme.STONE)
	vb.add_child(trib_lb)
	var res_row := HBoxContainer.new()
	res_row.add_theme_constant_override("separation", 6)
	for rk in ["gold", "wood", "stone", "food"]:
		var rb := Button.new()
		var rname: String = str(UITheme.RESOURCE_NAMES.get(rk, rk))
		rb.text = "%s %d" % [rname, DiplomacyManager.TRIBUTE_DELIVERY]
		UITheme.apply_row_button(rb, UITheme.RESOURCE_COLORS.get(rk, UITheme.PARCHMENT))
		rb.pressed.connect(_diplo_send_tribute.bind(rk))
		res_row.add_child(rb)
	vb.add_child(res_row)
	var rupture_btn := Button.new()
	rupture_btn.text = "💥 决裂断交（永久封禁该对）"
	UITheme.apply_danger_button(rupture_btn, UITheme.FONT_SM)
	rupture_btn.pressed.connect(_diplo_rupture.bind())
	vb.add_child(rupture_btn)
	_diplo_content.add_child(_wrap_card(vb, UITheme.EMERALD))

# 可结盟国家行：名字 + [提议结盟 / 撤回提议 / 不可结盟]
func _add_ally_option_row(d: DiplomacyManager, player: int, owner: int, is_pending: bool) -> void:
	var name_str: String = d.get_display_name(owner)
	var reason: String = d.alliance_block_reason(player, owner)
	var hb := HBoxContainer.new()
	hb.custom_minimum_size = Vector2(0, 36)
	hb.add_theme_constant_override("separation", 8)
	var lb := Label.new()
	lb.text = name_str
	lb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.apply_label(lb, UITheme.FONT_MD)
	hb.add_child(lb)
	var btn := Button.new()
	if reason != "":
		btn.disabled = true
		btn.text = "不可结盟"
		btn.tooltip_text = reason
		UITheme.apply_muted_button(btn, UITheme.FONT_SM)
	elif is_pending:
		btn.text = "撤回提议"
		UITheme.apply_muted_button(btn, UITheme.FONT_SM)
		btn.pressed.connect(_diplo_cancel_proposal.bind())
	else:
		btn.text = "提议结盟"
		UITheme.apply_primary_button(btn, UITheme.FONT_SM)
		btn.pressed.connect(_diplo_propose_to.bind(owner))
	hb.add_child(btn)
	_diplo_content.add_child(_wrap_card(hb, UITheme.STONE))

# ==================== 外交部动作回调 ====================
func _diplo_accept(proposer: int):
	var bm := _get_bm() as RTSBattleManager
	if bm == null or bm.diplomacy == null:
		return
	var d: DiplomacyManager = bm.diplomacy
	var player: int = bm.player_owner_id
	if d.accept_alliance(player, proposer):
		show_alert_message("✅ 已与 %s 结盟" % d.get_display_name(proposer), ALERT_INFO)
	else:
		var reason: String = d.alliance_block_reason(player, proposer)
		show_alert_message(reason if reason != "" else "结盟失败", ALERT_WARNING)

func _diplo_decline(proposer: int):
	var bm := _get_bm() as RTSBattleManager
	if bm == null or bm.diplomacy == null:
		return
	var d: DiplomacyManager = bm.diplomacy
	d.decline_alliance(bm.player_owner_id, proposer)
	show_alert_message("已拒绝 %s 的结盟提议" % d.get_display_name(proposer), ALERT_WARNING)

func _diplo_propose_to(owner: int):
	var bm := _get_bm() as RTSBattleManager
	if bm == null or bm.diplomacy == null:
		return
	var d: DiplomacyManager = bm.diplomacy
	var player: int = bm.player_owner_id
	if d.propose_alliance(player, owner):
		show_alert_message("已向 %s 发出结盟提议" % d.get_display_name(owner), ALERT_INFO)
	else:
		var reason: String = d.alliance_block_reason(player, owner)
		show_alert_message(reason if reason != "" else "提议失败", ALERT_WARNING)

func _diplo_cancel_proposal():
	var bm := _get_bm() as RTSBattleManager
	if bm == null or bm.diplomacy == null:
		return
	var d: DiplomacyManager = bm.diplomacy
	var player: int = bm.player_owner_id
	var target: int = int(d._pending_proposals.get(player, -1))
	if target == -1:
		return
	d.cancel_proposal(player)
	show_alert_message("已撤回对 %s 的结盟提议" % d.get_display_name(target), ALERT_WARNING)

func _diplo_send_tribute(res_type: String):
	var bm := _get_bm() as RTSBattleManager
	if bm == null or bm.diplomacy == null:
		return
	var d: DiplomacyManager = bm.diplomacy
	var player: int = bm.player_owner_id
	var ally: int = d.get_ally(player)
	if ally == -1:
		return
	if d.deliver_tribute(player, ally, res_type):
		var rname: String = str(UITheme.RESOURCE_NAMES.get(res_type, res_type))
		show_alert_message("已向 %s 进贡 %d %s" % [d.get_display_name(ally), DiplomacyManager.TRIBUTE_DELIVERY, rname], ALERT_INFO)
	else:
		show_alert_message("进贡失败：资源不足或对方仓库已满", ALERT_WARNING)

func _diplo_rupture():
	var bm := _get_bm() as RTSBattleManager
	if bm == null or bm.diplomacy == null:
		return
	var d: DiplomacyManager = bm.diplomacy
	var player: int = bm.player_owner_id
	var ally: int = d.get_ally(player)
	if d.rupture_alliance(player):
		show_alert_message("💥 你已与 %s 决裂，双方永久无法再结盟" % d.get_display_name(ally), ALERT_WARNING)
	else:
		show_alert_message("当前没有盟约可决裂", ALERT_WARNING)

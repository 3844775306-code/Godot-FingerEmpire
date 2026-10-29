class_name HUD
extends CanvasLayer

# 缓存的节点引用 — 避免每帧 get_tree().get_first_node_in_group()
var _bm: Node = null
var _sm: Node = null
var _mobile_hud = null    # 移动端界面装配器（仅触屏设备创建）
var _last_portrait: bool = false
var _mobile_rebuild_pending: bool = false

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
# 血条文字开关（默认关闭，只显示血条色条；在设置里手动开启，L 键可临时切换）
var show_unit_text: bool = false
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
var quartermaster_btn: Button
var quartermaster_on: bool = false
var _last_space_press: float = 0.0
var _pause_overlay: Control = null
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
var _capsule_row: HBoxContainer = null
const TributePanelScript = preload("res://scripts/ui/TributePanel.gd")
var _tribute_panel: Control = null
# 开发者倍速：仅调试构建 + 单机模式可用，F9/点击循环 1→2→4→8 倍。
const DEV_SPEEDS: Array = [1.0, 2.0, 4.0, 8.0]
var _dev_speed_index: int = 0
var _dev_speed_btn: Button = null
# 全局指令按钮底板（6 个按钮排两行）
var _cmd_panel: Panel = null
var _cmd_research_btn: Button = null
# 全局指令底板：6 个按钮 2 行 × 3 列
const CMD_PANEL_W: float = 662.0
const CMD_PANEL_H: float = 82.0
# 战况栏：同时最多堆 3 条，新的在最下面、最亮，旧的逐级变淡
const ALERT_MAX_ROWS: int = 3
const ALERT_LIFE: float = 3.4
# 与 RTSConfig.Nation 枚举顺序一致
const ALERT_NATION_NAMES: Array = ["维京", "英格兰", "法兰西", "中国", "匈牙利", "日本", "拜占庭", "蒙古", "波斯", "西班牙"]
var _alert_stack: VBoxContainer = null
var _alert_rows: Array = []      # [{ "rtl": RichTextLabel, "life": float }]
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
		RTSConfig.Nation.MONGOL: return "蒙古"
		RTSConfig.Nation.PERSIA: return "波斯"
		RTSConfig.Nation.SPAIN: return "西班牙"
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
	if _dev_speed_btn:
		_dev_speed_btn.visible = false
	if _diplo_panel:
		_diplo_panel.visible = false

# 统计面板折叠：展开是完整面板，折叠后只留一条「资源 + 人口」胶囊
func _set_stats_collapsed(collapsed: bool) -> void:
	_stats_collapsed = collapsed
	if unit_stats_panel:
		unit_stats_panel.visible = (not collapsed) and unit_stats_visible
	if _stats_capsule:
		_stats_capsule.visible = collapsed and unit_stats_visible
	if _dev_speed_btn != null and is_instance_valid(_dev_speed_btn):
		_dev_speed_btn.visible = collapsed and _dev_speed_available()

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
	# 进贡按钮放最左侧，避开展开态标题栏右上角的「▴ 折叠」。
	# 胶囊较窄时右侧资源可能被裁，但进贡入口始终可见且不会压住折叠按钮。
	row.move_child(tribute_btn, 0)
	_stats_capsule.gui_input.connect(_on_stats_capsule_input)
	add_child(_stats_capsule)
	_create_dev_speed_button()

# 开发者倍速按钮：只在调试构建 + 单机对局出现，不污染正式版和联机。
func _create_dev_speed_button() -> void:
	if not _dev_speed_available():
		return
	_dev_speed_btn = Button.new()
	_dev_speed_btn.name = "DevSpeedButton"
	_dev_speed_btn.position = Vector2(10, 70)
	_dev_speed_btn.size = Vector2(118, 32)
	_dev_speed_btn.z_index = 100
	_dev_speed_btn.focus_mode = Control.FOCUS_NONE
	_dev_speed_btn.text = "⏩ 1x"
	_dev_speed_btn.tooltip_text = "开发者倍速：F9 或点击循环 1→2→4→8 倍（仅单机调试）"
	UITheme.apply_muted_button(_dev_speed_btn, UITheme.FONT_SM)
	_dev_speed_btn.pressed.connect(_cycle_dev_speed)
	add_child(_dev_speed_btn)
	_update_dev_speed_button()

func _dev_speed_available() -> bool:
	return OS.is_debug_build() and NetworkManager.mode == NetworkManager.Mode.NONE

func _update_dev_speed_button() -> void:
	if _dev_speed_btn == null or not is_instance_valid(_dev_speed_btn):
		return
	var speed: float = float(DEV_SPEEDS[_dev_speed_index])
	_dev_speed_btn.text = "⏩ %dx" % int(speed)
	_dev_speed_btn.add_theme_color_override("font_color", UITheme.GOLD if speed > 1.0 else Color(0.8, 0.82, 0.86))

func _cycle_dev_speed() -> void:
	if not _dev_speed_available():
		return
	_dev_speed_index = (_dev_speed_index + 1) % DEV_SPEEDS.size()
	var speed: float = float(DEV_SPEEDS[_dev_speed_index])
	Engine.time_scale = speed
	_update_dev_speed_button()
	if speed > 1.0:
		show_alert_message("开发者倍速：%dx（仅调试模式）" % int(speed), UITheme.GOLD)
	else:
		show_alert_message("开发者倍速：已恢复 1x", Color(0.8, 0.82, 0.86))


func _open_tribute_panel() -> void:
	var bm = _get_bm()
	if bm == null:
		return
	if _tribute_panel == null or not is_instance_valid(_tribute_panel):
		_tribute_panel = TributePanelScript.new()
		add_child(_tribute_panel)
	_tribute_panel.setup(bm, int(bm.player_owner_id), {}, int(bm.get_team_of_owner(int(bm.player_owner_id))))
	_tribute_panel.open()

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
	var military_ids = [11, 12, 13, 15, 16, 17, 18, 19, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 55, 56, 57, 58, 59, 65, 66, 67, 68, 69]
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


func _create_pause_overlay():
	_pause_overlay = PanelContainer.new()
	_pause_overlay.name = "PauseOverlay"
	_pause_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pause_overlay.z_index = 200
	_pause_overlay.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_pause_overlay.offset_left = -190
	_pause_overlay.offset_right = 190
	_pause_overlay.offset_top = 118
	_pause_overlay.offset_bottom = 196
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.05, 0.07, 0.82)
	style.border_color = Color(UITheme.GOLD, 0.75)
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	style.content_margin_left = 18
	style.content_margin_right = 18
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	_pause_overlay.add_theme_stylebox_override("panel", style)
	var vb := VBoxContainer.new()
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 4)
	_pause_overlay.add_child(vb)
	var title := Label.new()
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title.text = "⏸ 已暂停"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", UITheme.GOLD)
	vb.add_child(title)
	var hint := Label.new()
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint.text = "打开设置 → 继续游戏" if InputSource.use_mobile_ui() else "P 继续游戏"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 14)
	hint.add_theme_color_override("font_color", Color(0.85, 0.87, 0.9))
	vb.add_child(hint)
	_pause_overlay.visible = get_tree().paused
	add_child(_pause_overlay)

func _update_pause_overlay():
	if is_instance_valid(_pause_overlay):
		_pause_overlay.visible = get_tree().paused

func _toggle_battle_pause():
	get_tree().paused = not get_tree().paused
	_update_pause_overlay()

func _exit_tree():
	# 离开对局必须恢复时间倍率，避免影响主菜单/下一局。
	Engine.time_scale = 1.0
	if get_tree() != null and get_tree().paused:
		get_tree().paused = false

func _input(event):
	if event is InputEventKey and event.pressed:
		# P 快速暂停/继续；暂停中仍允许建造、升级、生产和下发指令。
		var is_p_key: bool = event.keycode == KEY_P or event.physical_keycode == KEY_P
		if is_p_key and not event.ctrl_pressed and not event.alt_pressed and not event.shift_pressed:
			if not event.echo and NetworkManager.mode == NetworkManager.Mode.NONE:
				_toggle_battle_pause()
			get_viewport().set_input_as_handled()
			return
		# F9：开发者倍速（仅调试构建 + 单机对局）
		if event.keycode == KEY_F9 and not event.echo and _dev_speed_available():
			_cycle_dev_speed()
			get_viewport().set_input_as_handled()
			return
		match event.keycode:
			KEY_F1:
				if event.ctrl_pressed: _on_select_all_pressed()
				else: _on_select_screen_pressed()
			KEY_F2: _on_attack_all_pressed()
			KEY_F4: _on_quartermaster_pressed()
			KEY_F3:
				if event.ctrl_pressed: _on_retreat_all_pressed()
				else: _on_retreat_screen_pressed()
			KEY_DELETE: _on_demolish_selected()
			KEY_SPACE:
				if not event.echo: _on_space_pressed()
			KEY_L: _toggle_unit_text()
			KEY_T: _open_research_panel()

func _update_research_button(bm) -> void:
	if _cmd_research_btn == null or not is_instance_valid(_cmd_research_btn):
		return
	var on: bool = bm.has_method("is_research_mode") and bm.is_research_mode()
	_cmd_research_btn.visible = on
	if not on:
		return
	var st: Dictionary = bm.get_host_research_state() if bm.has_method("get_host_research_state") else {}
	var age_name := TechTreeData.age_name(int(st.get("age", 0)))
	var cur: Dictionary = st.get("current", {})
	var short_text := "🔬 科研树"
	if cur.is_empty():
		_cmd_research_btn.text = "🔬 %s · 科研树 (T)" % age_name
	else:
		var pct: int = int(clampf(float(cur.get("elapsed", 0.0)) / maxf(float(cur.get("total", 1.0)), 0.1) * 100.0, 0.0, 100.0))
		_cmd_research_btn.text = "🔬 %s · %s %d%% (T)" % [age_name, String(cur.get("name", "")), pct]
		short_text = "🔬 科研 %d%%" % pct
	# 手机指令栏里的科研树按钮同步显示年龄/进度（指令栏空间小，用短文案）
	var mh = _mobile_hud
	if mh != null and is_instance_valid(mh):
		var cb = mh.get("command_bar")
		if cb != null and is_instance_valid(cb) and cb.has_method("set_research_text"):
			cb.call("set_research_text", short_text)

# 科研树入口：经典模式不显示；联机客户端由 ClientHUD 处理。
func _open_research_panel():
	if not GameSettings.is_research_mode():
		return
	var bm = _get_bm()
	if bm == null:
		return
	ResearchPanel.open(self, bm)

# L 键：切换血条文字显示（隐藏后画面上只剩血条色条）
func _toggle_unit_text():
	show_unit_text = not show_unit_text
	GameSettings.show_unit_text = show_unit_text
	show_alert_message("单位血条文字：%s" % ("显示" if show_unit_text else "隐藏"), ALERT_INFO)

func _on_space_pressed():
	# 优先：释放选中建筑的进驻单位
	var bm = _get_bm()
	if bm and bm.has_node("SelectionManager"):
		var sm = bm.get_node("SelectionManager")
		if sm.has_method("get_selected_entities"):
			var sel = sm.get_selected_entities()
			# 队友/敌方选中只读：不能释放对方进驻单位
			var can_command: bool = sm.has_method("_selection_all_local") and sm._selection_all_local()
			var released = false
			if not can_command:
				sel = []
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
	# 双击空格：镜头居中当前选中；单击：跳转到最新警报
	var sm2 = bm.get_node_or_null("SelectionManager") if bm else null
	var now := Time.get_ticks_msec() / 1000.0
	if sm2 and now - _last_space_press < 0.3 and not sm2.selected_entities.is_empty():
		_last_space_press = 0.0
		var center := Vector3.ZERO
		var count := 0
		for e in sm2.selected_entities:
			if is_instance_valid(e):
				center += e.global_position
				count += 1
		if count > 0:
			var cam := get_viewport().get_camera_3d()
			if cam:
				center /= float(count)
				if cam.has_method("focus_on_ground"):
					cam.focus_on_ground(center)
				else:
					cam.global_position = Vector3(center.x, cam.global_position.y, center.z)
			return
	_last_space_press = now
	_on_jump_to_alert()

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
# 运载船默认包含在“全选军队”里；撤退时单独排除，避免船被派到陆地上的主城。
func _get_local_military_units(screen_only: bool, include_transport: bool = true) -> Array:
	var units: Array = []
	var bm = _get_bm()
	if not bm: return units
	var cam = get_viewport().get_camera_3d()
	var vp_rect = get_viewport().get_visible_rect()
	for e in bm.entities.get_children():
		if not (e is Army) or e.health <= 0: continue
		if not bm.is_local_player_owned(e.owner_peer_id, e.team): continue
		if e.entity_id in [10, 14, 5, 6, 43, 44, 45, 51, 46, 47, 48, 49, 50]: continue
		if not include_transport and e.entity_id == 9: continue
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

func _on_quartermaster_pressed():
	var bm = _get_bm()
	if not bm: return
	quartermaster_on = not quartermaster_on
	if bm.has_method("set_local_quartermaster"):
		bm.set_local_quartermaster(quartermaster_on)
	_update_quartermaster_button()
	show_alert_message("智能军需官：%s" % ("开启，自动补农民并按资源缺口分配，仓容紧张时补仓库" if quartermaster_on else "关闭"), ALERT_INFO)

func _update_quartermaster_button():
	if quartermaster_btn:
		quartermaster_btn.text = "🧺 军需官：%s (F4)" % ("开" if quartermaster_on else "关")

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
	_retreat_units(_get_local_military_units(true, false))

func _on_retreat_all_pressed():
	_retreat_units(_get_local_military_units(false, false))

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
	# 血条文字默认关闭；设置面板/上一局状态由 GameSettings 统一保存。
	show_unit_text = GameSettings.show_unit_text
	add_to_group("game_hud")
	# 暂停时 HUD 仍要响应快捷栏、建造菜单、信息面板与相机操作。
	process_mode = Node.PROCESS_MODE_ALWAYS
	_create_pause_overlay()
	# 电脑版左下角的虚拟摇杆用不上：隐藏并停掉它的输入处理，避免抢占鼠标
	if not InputSource.use_mobile_ui():
		var stick := get_node_or_null("VirtualStick")
		if stick is Control:
			stick.visible = false
			stick.set_process(false)
			stick.set_process_input(false)
			stick.set_process_unhandled_input(false)

	_create_unit_stats_panel()
	# 科研模式下指令底板多一行科研树按钮，底板高度跟着变
	UILayout.cmd_research_row = GameSettings.is_research_mode()

	# 全局指令：6 个按钮排成 2 行 × 3 列（3×2），整块底板水平居中
	_cmd_panel = Panel.new()
	_cmd_panel.name = "GlobalCommandPanel"
	var cmd_rect := UILayout.top_cmd_rect(get_viewport().get_visible_rect().size)
	_cmd_panel.size = cmd_rect.size
	_cmd_panel.position = cmd_rect.position
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
	# 智能军需官 / 军队官的开关已经收进 ⚙ 设置面板，指令栏只留战斗相关按钮；
	# F4 快捷键仍然可用（老玩家习惯），与设置面板共用同一个状态。
	var b_retreat_screen = _make_cmd_button("屏幕军队撤退 (F3)", _on_retreat_screen_pressed, false)
	var b_retreat_all = _make_cmd_button("所有军队撤退 (Ctrl+F3)", _on_retreat_all_pressed, false)
	var b_settings = _make_cmd_button("⚙ 设置", _open_game_settings, false)
	for b in [b_select_screen, b_select_all, auto_attack_btn, b_retreat_screen, b_retreat_all, b_settings]:
		cmd_grid.add_child(b)
	# 科研树归入指令按钮栏：整行放在六个指令按钮下面，经典模式隐藏。
	# 不再单独挂一个悬浮按钮，顶部带只保留胶囊/指令/信息/小地图四类元素。
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

	set_process(true)

	# 顶部带统一排布：资源胶囊 / 指令栏 / 小地图 / 科研入口 / 战况栏
	_layout_top_band()

	# 移动端：装配触屏界面（桌面端不进入此分支，零改动）
	_last_portrait = UILayout.is_portrait()
	if get_viewport() != null:
		get_viewport().size_changed.connect(_on_viewport_size_changed)
	if InputSource.use_mobile_ui():
		_mobile_hud = MobileHUD.new()
		add_child(_mobile_hud)
		_mobile_hud.setup(self)
		_layout_top_band()

# 顶部带重排：所有端共用一条横带，元素之间永远留出 TOP_MARGIN 级别的空隙。
func _layout_top_band() -> void:
	var vp := get_viewport().get_visible_rect().size
	var mobile := InputSource.use_mobile_ui()
	# 指令底板：桌面水平居中；手机端由 MobileCommandBar 替代，底板隐藏
	if _cmd_panel != null:
		var cmd_rect := UILayout.top_cmd_rect(vp)
		_cmd_panel.position = cmd_rect.position
		_cmd_panel.size = cmd_rect.size
	# 资源胶囊：桌面左上；手机上改用 MobileResourceCapsule
	if _stats_capsule != null and not mobile:
		var cap_rect := UILayout.top_capsule_rect(vp, _stats_capsule.size.x)
		_stats_capsule.position = cap_rect.position
		_stats_capsule.size = cap_rect.size
	# 小地图：桌面贴右上；手机交给 MobileHUD 按横竖屏摆放
	if not mobile:
		var mm := get_node_or_null("Minimap") as Control
		if mm != null:
			var mm_rect := UILayout.top_minimap_rect(vp)
			UILayout.place(mm, 1.0, 0.0, -UILayout.TOP_MARGIN - mm_rect.size.x,
					UILayout.TOP_MARGIN, -UILayout.TOP_MARGIN, UILayout.TOP_MARGIN + mm_rect.size.y)
	# 战况栏
	_layout_alert_stack()

# 手机端资源胶囊矩形：优先取 MobileHUD 真实控件，取不到按 UILayout 的 place_dp 规则兜底。
func _mobile_capsule_rect_ui() -> Rect2:
	var mh = _mobile_hud
	if mh != null and is_instance_valid(mh):
		var cap = mh.get("capsule")
		if cap is Control and (cap as Control).visible:
			var cr: Rect2 = (cap as Control).get_global_rect()
			if cr.size.x > 0.0:
				return cr
	# 取不到真实控件时按 MobileResourceCapsule 的 place_dp 规则兜底（344×42dp）
	var insets := UILayout.safe_insets()
	return Rect2(Vector2(insets.x + UILayout.dp(2.0), insets.y + UILayout.dp(2.0)),
		Vector2(UILayout.dp(UILayout.mobile_capsule_width_dp()), UILayout.dp(42.0)))

# 移动端统计大屏打开时隐藏顶部信息面板（DiagLayer 在很上层，会压住统计大屏的关闭按钮）
func _on_stats_overlay_toggled(open: bool) -> void:
	if not is_inside_tree():
		return
	var bm = _get_bm()
	if bm != null and bm.has_method("set_top_info_visible"):
		bm.call("set_top_info_visible", not open)

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

# 战况栏：桌面放顶部信息面板/指令底板下方居中；手机按横竖屏放在信息栏/胶囊下方，
# 避免压住胶囊、小地图和四行信息栏。
func _layout_alert_stack() -> void:
	if _alert_stack == null or not is_instance_valid(_alert_stack):
		return
	if InputSource.use_mobile_ui():
		var r := UILayout.mobile_alert_rect(_mobile_capsule_rect_ui())
		_alert_stack.anchor_left = 0.5
		_alert_stack.anchor_right = 0.5
		_alert_stack.anchor_top = 0.0
		_alert_stack.anchor_bottom = 0.0
		_alert_stack.offset_left = -r.size.x * 0.5
		_alert_stack.offset_right = r.size.x * 0.5
		_alert_stack.offset_top = r.position.y
		_alert_stack.offset_bottom = r.position.y
		return
	# 桌面：单机顶部信息面板可能落到指令栏下方，战况栏要跟着往下让
	var diag_bottom := 0.0
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if bm != null and bm.has_method("get_diag_panel_rect"):
		var dr: Rect2 = bm.get_diag_panel_rect()
		if dr.size.y > 0.0:
			diag_bottom = dr.position.y + dr.size.y
	var rd := UILayout.top_alert_rect(get_viewport().get_visible_rect().size, diag_bottom)
	_alert_stack.anchor_left = 0.0
	_alert_stack.anchor_right = 0.0
	_alert_stack.anchor_top = 0.0
	_alert_stack.anchor_bottom = 0.0
	_alert_stack.position = rd.position
	_alert_stack.custom_minimum_size = Vector2(rd.size.x, 0)
	_alert_stack.size = Vector2(rd.size.x, 0)
const ALERT_DANGER = UITheme.ALERT_DANGER     # 红色 — 基地/建筑被攻击
const ALERT_WARNING = UITheme.ALERT_WARNING   # 黄色 — 敌军来袭/资源不足
const ALERT_INFO = UITheme.ALERT_INFO      # 绿色 — 建造/训练/升级完成
const ALERT_GROUP = UITheme.ALERT_GROUP     # 蓝色 — 编队反馈

func show_alert_message(msg: String, color: Color = ALERT_DANGER, teams = [], alert_kind: int = 0, is_castle: bool = false, nations: Array = [], alert_pos: Vector3 = Vector3.ZERO, source_owner: int = -1):
	var mobile := InputSource.use_mobile_ui()
	var team_list: Array = _normalize_alert_teams(teams)
	# 按设置过滤掉不关心的战报（主要是队友的建造/升级/生产）
	if _alert_is_filtered(team_list, alert_kind, is_castle, source_owner):
		return
	if _alert_stack == null:
		# 战况栏改成竖排多行：每条战况独立一行，新消息加在末尾（最下面），
		# 超过上限就从最上面挤掉。用 VBoxContainer 自动排版，增删行不用手算坐标。
		_alert_stack = VBoxContainer.new()
		_alert_stack.name = "AlertStack"
		_alert_stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_alert_stack.add_theme_constant_override("separation", 2 if mobile else 4)
		add_child(_alert_stack)
		_layout_alert_stack()

	# 每行一个半透明背景块 + 内部 RichTextLabel。
	# 纯文字直接压在战场上很难读（草地和雪地尤其糟），背景压到 0.62 既保证可读
	# 又不至于变回一条实心黑条把战场挡住；左侧 3px 竖条沿用警报色标明类型。
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

	# 一行里国家名和正文要显示成两种颜色，普通 Label 做不到
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
	# 只保留最近几条：战况栏本身是临时提示，堆多了会盖住战场
	while _alert_rows.size() > ALERT_MAX_ROWS:
		var old: Dictionary = _alert_rows.pop_front()
		var old_holder = old.get("holder")
		if is_instance_valid(old_holder):
			old_holder.queue_free()
	_refresh_alert_weights()
	set_process(true)

# 兼容两种写法：单个队伍（int）或队伍数组。负数表示未知来源，直接丢弃。
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
# 科研完成默认接收，但敌方科研永远不推送（会泄露对手时代/科技进度）。
# 其他类型（战斗、外交、经济）与自己直接相关，始终接收。
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
	# 「自己」和「队友」按 owner 区分：2v2/3v3 里 AI 队友与自己同队，只看 team
	# 会把队友的动静当成自己的而永远显示，「战报筛选」开关也就失效了。
	# owner 缺失（1v1 队伍级单位、旧数据）时按自己处理，保持原有行为。
	if sender < 0:
		return false
	var my_owner: int = _alert_my_owner()
	if source_owner < 0 or (my_owner >= 0 and source_owner == my_owner):
		return false
	# 队友主城升级是重要节点（意味着对方整体实力跃升），不跟着一起过滤
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
func _alert_my_team() -> int:
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if bm == null or not bm.has_method("get_local_team"):
		return -1
	return int(bm.get_local_team())

# 消息前加国家前缀。一条战报可能同时涉及多个国家（例如「A 攻打 B」），
# 全部按同一规则着色：自己绿、同阵营友方蓝、敌方红，国家之间用箭头连接。
# nations 是直接给出的国家索引（与 teams 一一对应时优先使用）：
# 2v2 里队友与自己同队但不同国，只靠 teams 会把队友的单位误标成自己的国家。
func _alert_bbcode(msg: String, color: Color, teams: Array, nations: Array = []) -> String:
	var out := ""
	var parts: Array = []
	for i in teams.size():
		var team: int = int(teams[i])
		var nation_idx: int = int(nations[i]) if i < nations.size() else -1
		var nation := ""
		if nation_idx >= 0 and nation_idx < ALERT_NATION_NAMES.size():
			nation = String(ALERT_NATION_NAMES[nation_idx])
		else:
			nation = _alert_nation_name(team)
		if nation.is_empty():
			continue
		parts.append("[color=#%s]【%s】[/color]" % [_alert_team_color(team).to_html(false), nation])
	if not parts.is_empty():
		# 箭头单独用浅灰，避免跟着前后国家的颜色走
		out += "[color=#BBBBBB]→[/color]".join(parts)
		out += " "
	# 正文里的方括号必须转义，否则会被当成 BBCode 标签吞掉
	out += "[color=#%s]%s[/color]" % [color.to_html(false), msg.replace("[", "[lb]")]
	return out

func _alert_nation_name(team: int) -> String:
	if team < 0:
		return ""
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if bm == null or not bm.has_method("get_team_nation"):
		return ""
	var n: int = int(bm.get_team_nation(team))
	if n < 0 or n >= ALERT_NATION_NAMES.size():
		return ""
	return String(ALERT_NATION_NAMES[n])

# 本地玩家所在队伍（单机与联机房主都是 host team）
func get_my_team() -> int:
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if bm != null and bm.has_method("get_host_team"):
		return int(bm.get_host_team())
	return -1

# 本地玩家的 owner（单机 2v2/3v3/乱斗用来区分「自己的建筑」和「AI 队友的建筑」）
func _alert_my_owner() -> int:
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if bm == null:
		return -1
	var v = bm.get("player_owner_id")
	if v == null:
		return -1
	return int(v)

# 自己 → 绿；同阵营友方 → 蓝；敌方与中立 → 红
func _alert_team_color(team: int) -> Color:
	if team < 0:
		return Color(1.0, 1.0, 1.0, 0.0)
	var bm = get_tree().get_first_node_in_group("battle_manager")
	var me: int = get_my_team()
	var enemy: int = -1
	if bm != null and bm.has_method("get_enemy_team"):
		enemy = int(bm.get_enemy_team())
	if team == me:
		return Color(0.35, 1.0, 0.45)
	if enemy != -1 and team != enemy:
		return Color(0.45, 0.72, 1.0)
	return Color(1.0, 0.38, 0.32)

# 最新的那条最亮、字号最大；往上逐级变淡缩小，扫一眼就知道哪条刚发生。
# 透明度调在整行背景块上，文字和底色一起淡出，不会出现字淡了底还实的情况。
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
var _stutter_last_usec: int = 0
var _stutter_window_count: int = 0
var _stutter_window_max: float = 0.0
var _stutter_window_timer: float = 30.0
var _stutter_window_sum: float = 0.0
var _stutter_window_frames: int = 0
var _stutter_file: FileAccess = null

# 卡顿诊断：单帧超过 60ms 就记一条到 user://stutter.log（含游戏时间/实体数/物理帧率），
# 每 30 秒再写一条汇总。用来定位“帧率不低但每隔一段时间一顿”的具体时刻。
func _tick_stutter_log(delta: float) -> void:
	_stutter_window_timer -= delta
	var now := Time.get_ticks_usec()
	if _stutter_last_usec == 0:
		_stutter_last_usec = now
		return
	var ms := float(now - _stutter_last_usec) / 1000.0
	_stutter_last_usec = now
	if _stutter_file == null:
		_stutter_file = FileAccess.open("user://stutter.log", FileAccess.WRITE)
		if _stutter_file:
			print("[Stutter] 日志: ", ProjectSettings.globalize_path("user://stutter.log"))
			# 首行记运行环境：玩家机器与开发机差异很大（窗口分辨率、垂直同步、
			# 刷新率、渲染器），没有这行就无法判断“同样的实体数为什么差 3 倍”。
			_stutter_file.store_line("ENV win=%s screen=%s refresh=%.0f vsync=%d max_fps=%d cpus=%d adapter=%s renderer=%s scale3d=%.2f" % [
				str(DisplayServer.window_get_size()), str(DisplayServer.screen_get_size()),
				DisplayServer.screen_get_refresh_rate(), DisplayServer.window_get_vsync_mode(),
				Engine.max_fps, OS.get_processor_count(), RenderingServer.get_video_adapter_name(),
				RenderingServer.get_video_adapter_api_version(), get_viewport().scaling_3d_scale,
			])
	_stutter_window_sum += ms
	_stutter_window_frames += 1
	var bm = _get_bm()
	if ms > 60.0:
		_stutter_window_count += 1
		_stutter_window_max = maxf(_stutter_window_max, ms)
		if _stutter_file:
			var gt: float = float(bm.game_time) if bm else 0.0
			var ents: int = bm._all_entities.size() if bm and "_all_entities" in bm else 0
			var armies: int = bm._armies.size() if bm and "_armies" in bm else 0
			_stutter_file.store_line("SPIKE ms=%.1f game_time=%.1f entities=%d armies=%d phys_hz=%d procs_ms=%.1f phys_ms=%.1f draws=%d" % [
				ms, gt, ents, armies, Engine.physics_ticks_per_second,
				float(Performance.get_monitor(Performance.TIME_PROCESS)) * 1000.0,
				float(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0,
				int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
			])
	if _stutter_window_timer <= 0.0:
		_stutter_window_timer = 30.0
		if _stutter_file:
			var bm2 = _get_bm()
			var wframes: int = maxi(_stutter_window_frames, 1)
			var wavg: float = _stutter_window_sum / float(wframes)
			_stutter_file.store_line("SUMMARY 30s spikes=%d max_ms=%.1f avg_ms=%.1f fps=%.1f game_time=%.1f entities=%d vsync=%d" % [
				_stutter_window_count, _stutter_window_max, wavg, 1000.0 / maxf(wavg, 0.01),
				float(bm2.game_time) if bm2 else 0.0,
				bm2._all_entities.size() if bm2 and "_all_entities" in bm2 else 0,
				DisplayServer.window_get_vsync_mode(),
			])
		_stutter_window_count = 0
		_stutter_window_max = 0.0
		_stutter_window_sum = 0.0
		_stutter_window_frames = 0

func _process(delta):
	_tick_stutter_log(delta)
	_update_pause_overlay()
	_tick_ffa_diplo(delta)
	_unit_stats_timer -= delta
	var bm = _get_bm()
	if bm == null:
		return
	_update_research_button(bm)
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

	# 战况栏计时：每行各自倒计时，到期的自己消失，剩下的重新分配明暗
	if not _alert_rows.is_empty():
		for i in range(_alert_rows.size() - 1, -1, -1):
			var row: Dictionary = _alert_rows[i]
			row["life"] = float(row.get("life", 0.0)) - delta
			if float(row["life"]) > 0.0:
				continue
			var rtl = row.get("rtl")
			var holder = row.get("holder")
			if is_instance_valid(holder):
				holder.queue_free()
			_alert_rows.remove_at(i)
		_refresh_alert_weights()

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
			if unit_bars[e].has("repair_bar") and unit_bars[e].repair_bar:
				unit_bars[e].repair_bar.queue_free()
			if unit_bars[e].has("repair_label") and unit_bars[e].repair_label:
				unit_bars[e].repair_label.queue_free()
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
		_hide_repair_bar(entity)
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

		# 修理进度：残破建筑被修理时在血条正上方画一条翠绿进度条（与建造条同款样式）
		if entity is Building and entity.has_method("is_under_repair") and entity.is_under_repair():
			var rdata = unit_bars[entity]
			var repair_bar: ProgressBar = rdata.get("repair_bar")
			var repair_label: Label = rdata.get("repair_label")
			if not repair_bar:
				repair_bar = ProgressBar.new()
				UITheme.style_progress_bar(repair_bar, UITheme.REPAIR_PROGRESS, 8.0)
				add_child(repair_bar); repair_bar.z_index = -1
				rdata["repair_bar"] = repair_bar
			if not repair_label:
				repair_label = Label.new()
				repair_label.add_theme_color_override("font_color", Color.WHITE)
				repair_label.add_theme_color_override("font_outline_color", Color.BLACK)
				repair_label.add_theme_constant_override("outline_size", 1)
				add_child(repair_label); repair_label.z_index = -1
				rdata["repair_label"] = repair_label
			var repair_total := maxf(entity.max_repair_time, 0.001)
			var repair_pct := clampf(1.0 - entity.repair_timer / repair_total, 0.0, 1.0)
			repair_bar.custom_minimum_size = Vector2(bar_size.x, 8 * scale_factor)
			repair_bar.size = Vector2(bar_size.x, 8 * scale_factor)
			repair_bar.visible = true
			repair_bar.value = repair_pct
			repair_bar.position = bar.position + Vector2(0, -bar_size.y - 4)
			repair_label.add_theme_font_size_override("font_size", font_size)
			repair_label.visible = show_unit_text
			if refresh_text_now:
				if entity.repair_pending and entity.repair_timer <= 0.0:
					repair_label.text = "等待农民修理"
				else:
					repair_label.text = "修理中 %d%% · 农民%d" % [int(repair_pct * 100.0), entity.builder_count_cache]
			repair_label.position = repair_bar.position + Vector2(0, -22)
		else:
			_hide_repair_bar(entity)

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
				if entity.awaiting_builder and entity.builder_count_cache == 0:
					label.text = "%s (等待农民)" % entity.display_name
				elif entity.awaiting_builder:
					label.text = "%s (农民赶路中 · %d)" % [entity.display_name, entity.builder_count_cache]
				else:
					label.text = "%s (建造中 %d%% · 农民%d)" % [entity.display_name, int(build_pct * 100.0), entity.builder_count_cache]
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
	_hide_repair_bar(entity)

func _hide_build_bar(entity):
	if entity in unit_bars:
		var d = unit_bars[entity]
		if d.has("build_bar") and d.build_bar:
			d.build_bar.visible = false

# 修理条与修理文字一起隐藏（与建造条同一套数据缓存）
func _hide_repair_bar(entity):
	if entity in unit_bars:
		var d = unit_bars[entity]
		if d.has("repair_bar") and d.repair_bar:
			d.repair_bar.visible = false
		if d.has("repair_label") and d.repair_label:
			d.repair_label.visible = false

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
	# 只有己方建筑可拆除；敌方/队友选中只用于查看信息
	if not sel._selection_all_local():
		return
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
		show_alert_message("✅ 已与 %s 结盟" % d.get_display_name(proposer), ALERT_INFO, [get_my_team(), d.get_team_of(proposer)])
	else:
		var reason: String = d.alliance_block_reason(player, proposer)
		show_alert_message(reason if reason != "" else "结盟失败", ALERT_WARNING)

func _diplo_decline(proposer: int):
	var bm := _get_bm() as RTSBattleManager
	if bm == null or bm.diplomacy == null:
		return
	var d: DiplomacyManager = bm.diplomacy
	d.decline_alliance(bm.player_owner_id, proposer)
	show_alert_message("已拒绝 %s 的结盟提议" % d.get_display_name(proposer), ALERT_WARNING, [get_my_team(), d.get_team_of(proposer)])

func _diplo_propose_to(owner: int):
	var bm := _get_bm() as RTSBattleManager
	if bm == null or bm.diplomacy == null:
		return
	var d: DiplomacyManager = bm.diplomacy
	var player: int = bm.player_owner_id
	if d.propose_alliance(player, owner):
		show_alert_message("已向 %s 发出结盟提议" % d.get_display_name(owner), ALERT_INFO, [get_my_team(), d.get_team_of(owner)])
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
	show_alert_message("已撤回对 %s 的结盟提议" % d.get_display_name(target), ALERT_WARNING, [get_my_team(), d.get_team_of(target)])

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
		show_alert_message("已向 %s 进贡 %d %s" % [d.get_display_name(ally), DiplomacyManager.TRIBUTE_DELIVERY, rname], ALERT_INFO, [get_my_team(), d.get_team_of(ally)])
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
		show_alert_message("💥 你已与 %s 决裂，双方永久无法再结盟" % d.get_display_name(ally), ALERT_WARNING, [get_my_team(), d.get_team_of(ally)])
	else:
		show_alert_message("当前没有盟约可决裂", ALERT_WARNING)

# scripts/ui/InfoPanel.gd
class_name InfoPanel
extends Panel

var upgrade_btn: Button = null
var produce_vbox: VBoxContainer = null
var _vb: VBoxContainer = null
var _panel_scroll: ScrollContainer = null

# ==================== 简略 / 详细 ====================
var detail_toggle: Button = null
var _detail_mode: bool = false
var _detail_view: Control = null
var _detail_scroll: ScrollContainer = null
var _detail_rtl: RichTextLabel = null
var _detail_content: VBoxContainer = null
var _detail_last_id: int = -1
var _detail_last_text: String = ""

# ==================== 运载船：上/下船 ====================
const BOARD_RANGE: float = 5.0  # 只有船周围 5 米内的陆地单位才能上船

var _board_box: VBoxContainer = null
var _board_label: RichTextLabel = null
var _board_up_btn: Button = null
var _board_down_btn: Button = null
var _board_near_units: Array = []
var _board_shore: Vector3 = Vector3.ZERO
@onready var close_btn = $CloseBtn

var name_rtl: RichTextLabel
var _portrait: TextureRect = null   # 单选时显示实体模型图（单位/建筑/资源）
var _header_row: HBoxContainer = null   # 头像 + 名称/血条/属性 的头部区
var _produce_grid: GridContainer = null  # 生产按钮 / 框选分组的大图标网格
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
var repair_btn: Button = null
var cancel_build_btn: Button = null
# 选中被驻军建筑时的“取消进驻”按钮
var _ungarrison_btn: Button = null
# 选中资源点时出现的“采集 / 停止采集”操作区
var _resource_box: VBoxContainer = null
var _resource_gather_btn: Button = null
var _resource_stop_btn: Button = null
# 选中施工中/修理中的建筑时出现的“加人建造 / 加人修理”操作区
var _builder_box: VBoxContainer = null
var _builder_info_rtl: RichTextLabel = null
var _add_builder_btn: Button = null
var _add_repairer_btn: Button = null
# 选中敌方单位时，按“视野内能看到它的我方兵种”分组生成的攻击按钮
var _attack_box: VBoxContainer = null
var _attack_title_rtl: RichTextLabel = null
var _attack_flow: HFlowContainer = null
var _attack_groups: Dictionary = {}  # entity_id(int) -> Array[Army]
# 注意 RichTextLabel 的字号主题项是 normal_font_size，只设 font_size 不会生效。
func _is_mobile() -> bool:
	return InputSource.use_mobile_ui()

func _mobile_font(base_size: int) -> int:
	if not _is_mobile():
		return base_size
	return int(round(base_size * UILayout.dp_ratio()))

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
	# 桌面端加宽到 470：图标卡片要两列排得下；手机端尺寸由 MobileHUD.place_dp 决定
	custom_minimum_size = Vector2(470, 0) if not _is_mobile() else Vector2(0, 0)

	_swap_rtl("NameLabel"); _swap_rtl("StatsLabel")
	name_rtl = _vb.get_node("NameLabel")
	stats_rtl = _vb.get_node("StatsLabel")
	name_rtl.add_theme_font_size_override("font_size", UITheme.FONT_XL)
	name_rtl.add_theme_color_override("default_color", UITheme.PARCHMENT)
	name_rtl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# fit_content 遇到自动换行时高度可能滞后一帧算成 0；先给最小高度，保证名字始终占位可见
	name_rtl.custom_minimum_size = Vector2(0, float(UITheme.FONT_XL) + 6.0)
	stats_rtl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	stats_rtl.add_theme_color_override("default_color", UITheme.PARCHMENT)
	# 加成说明可能比属性行更长（国家特色、多项科研），窄面板必须允许换行
	stats_rtl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if _is_mobile():
		# 手机上名称与属性两行都要能看清：名称 15dp、属性 12dp
		_set_rtl_font(name_rtl, UILayout.font_dp(15.0))
		_set_rtl_font(stats_rtl, UILayout.font_dp(12.0))
		name_rtl.custom_minimum_size = Vector2(0, UILayout.font_dp(15.0) + UILayout.dp(3.0))

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
	_build_header()
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

	# 修理按钮 — 建筑掉血后才出现；主城不可修，逻辑与命令卡一致。
	repair_btn = Button.new()
	repair_btn.name = "RepairBtn"
	repair_btn.text = "🔧 修理建筑"
	repair_btn.custom_minimum_size = Vector2(180, 36)
	repair_btn.visible = false
	repair_btn.pressed.connect(_on_repair_pressed)
	UITheme.apply_primary_button(repair_btn, UITheme.FONT_SM)
	_vb.add_child(repair_btn)

	# 取消建造：地基刚放下、农民还没动工时可以全额退款取消
	cancel_build_btn = Button.new()
	cancel_build_btn.name = "CancelBuildBtn"
	cancel_build_btn.text = "❌ 取消建造（全额退款）"
	cancel_build_btn.custom_minimum_size = Vector2(180, 36)
	cancel_build_btn.visible = false
	cancel_build_btn.pressed.connect(_on_cancel_build_pressed)
	UITheme.apply_danger_button(cancel_build_btn, UITheme.FONT_SM)
	_vb.add_child(cancel_build_btn)

	# 取消进驻：释放该建筑里的全部驻军
	_ungarrison_btn = Button.new()
	_ungarrison_btn.name = "UngarrisonBtn"
	_ungarrison_btn.text = "🚪 取消进驻"
	_ungarrison_btn.custom_minimum_size = Vector2(180, 36)
	_ungarrison_btn.visible = false
	_ungarrison_btn.pressed.connect(_on_ungarrison_pressed)
	UITheme.apply_muted_button(_ungarrison_btn, UITheme.FONT_SM)
	_vb.add_child(_ungarrison_btn)

	# 资源点操作区：两个按钮并排，手机端也放得下。
	_resource_box = VBoxContainer.new()
	_resource_box.name = "ResourceBox"
	_resource_box.visible = false
	_resource_box.add_theme_constant_override("separation", 4)
	var res_row := HBoxContainer.new()
	res_row.add_theme_constant_override("separation", 6)
	_resource_gather_btn = Button.new()
	_resource_gather_btn.text = "⛏ 采集"
	_resource_gather_btn.custom_minimum_size = Vector2(0, UILayout.dp(30.0) if _is_mobile() else 34.0)
	_resource_gather_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_resource_gather_btn.pressed.connect(_on_resource_gather_pressed)
	UITheme.apply_primary_button(_resource_gather_btn, UITheme.FONT_SM)
	_resource_stop_btn = Button.new()
	_resource_stop_btn.text = "🚫 停止采集"
	_resource_stop_btn.tooltip_text = "本队农民 2 分钟内不再采集这个资源点"
	_resource_stop_btn.custom_minimum_size = Vector2(0, UILayout.dp(30.0) if _is_mobile() else 34.0)
	_resource_stop_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_resource_stop_btn.pressed.connect(_on_resource_stop_pressed)
	UITheme.apply_danger_button(_resource_stop_btn, UITheme.FONT_SM)
	res_row.add_child(_resource_gather_btn)
	res_row.add_child(_resource_stop_btn)
	_resource_box.add_child(res_row)
	_vb.add_child(_resource_box)

	# 建筑施工现场操作区：只在建造中/修理中显示。
	_builder_box = VBoxContainer.new()
	_builder_box.name = "BuilderBox"
	_builder_box.visible = false
	_builder_box.add_theme_constant_override("separation", 4)
	_builder_info_rtl = RichTextLabel.new()
	_builder_info_rtl.bbcode_enabled = true
	_builder_info_rtl.fit_content = true
	_builder_info_rtl.scroll_active = false
	_builder_info_rtl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_builder_info_rtl.add_theme_font_size_override("normal_font_size", UITheme.FONT_SM)
	_builder_info_rtl.add_theme_color_override("default_color", UITheme.PARCHMENT)
	_builder_box.add_child(_builder_info_rtl)
	var build_row := HBoxContainer.new()
	build_row.add_theme_constant_override("separation", 6)
	_add_builder_btn = Button.new()
	_add_builder_btn.text = "➕ 加人建造"
	_add_builder_btn.custom_minimum_size = Vector2(0, UILayout.dp(30.0) if _is_mobile() else 34.0)
	_add_builder_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_add_builder_btn.pressed.connect(_on_add_builder_pressed)
	UITheme.apply_primary_button(_add_builder_btn, UITheme.FONT_SM)
	_add_repairer_btn = Button.new()
	_add_repairer_btn.text = "➕ 加人修理"
	_add_repairer_btn.custom_minimum_size = Vector2(0, UILayout.dp(30.0) if _is_mobile() else 34.0)
	_add_repairer_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_add_repairer_btn.pressed.connect(_on_add_repairer_pressed)
	UITheme.apply_primary_button(_add_repairer_btn, UITheme.FONT_SM)
	build_row.add_child(_add_builder_btn)
	build_row.add_child(_add_repairer_btn)
	_builder_box.add_child(build_row)
	_vb.add_child(_builder_box)

	# 敌方单位：按兵种分组列出“视野内能看到它”的我方军队，点一下即全军攻击。
	_attack_box = VBoxContainer.new()
	_attack_box.name = "AttackBox"
	_attack_box.visible = false
	_attack_box.add_theme_constant_override("separation", 4)
	_attack_title_rtl = RichTextLabel.new()
	_attack_title_rtl.bbcode_enabled = true
	_attack_title_rtl.fit_content = true
	_attack_title_rtl.scroll_active = false
	_attack_title_rtl.add_theme_font_size_override("normal_font_size", UITheme.FONT_SM)
	_attack_title_rtl.add_theme_color_override("default_color", UITheme.PARCHMENT)
	_attack_box.add_child(_attack_title_rtl)
	_attack_flow = HFlowContainer.new()
	_attack_flow.add_theme_constant_override("h_separation", 6)
	_attack_flow.add_theme_constant_override("v_separation", 4)
	_attack_box.add_child(_attack_flow)
	_vb.add_child(_attack_box)

	set_process(true)
	if _is_mobile():
		_build_mobile_scroll()
	else:
		# 顶部给「简略 / 详细」切换按钮留一行，避免按钮压住单位名。
		_vb.offset_top = 36.0
	_build_detail_view()
	_build_detail_toggle()

# 手机端面板只有 260×200dp，建筑生产按钮一多就会超出屏幕底部；
# 把内容包进滚动容器，触摸拖动由手势路由调用 UILayout.scroll_at 驱动。
# 单选：名字左边放一张实体图（单位/建筑/资源都有渲染图），一眼看出选的是谁
# 单选头部：左边大头像，右边名称 + 血条 + 属性（手机面板太窄，头像只挨着名字，
# 血条和属性仍占满整行，避免右列被挤成一条缝）
func _build_header() -> void:
	if _header_row != null:
		return
	_portrait = TextureRect.new()
	_portrait.name = "Portrait"
	_portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_portrait.visible = false
	_header_row = HBoxContainer.new()
	_header_row.name = "HeaderRow"
	_header_row.add_theme_constant_override("separation", 10)
	var idx := name_rtl.get_index()
	_vb.remove_child(name_rtl)
	_vb.remove_child(hp_bar_bg)
	_vb.remove_child(stats_rtl)
	_vb.add_child(_header_row)
	_vb.move_child(_header_row, mini(idx, maxi(0, _vb.get_child_count() - 1)))
	_header_row.add_child(_portrait)
	if _is_mobile():
		_portrait.custom_minimum_size = Vector2(UILayout.dp(56.0), UILayout.dp(56.0))
		_header_row.add_child(name_rtl)
		name_rtl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_vb.add_child(hp_bar_bg)
		_vb.move_child(hp_bar_bg, _header_row.get_index() + 1)
		_vb.add_child(stats_rtl)
		_vb.move_child(stats_rtl, hp_bar_bg.get_index() + 1)
	else:
		_portrait.custom_minimum_size = Vector2(112.0, 112.0)
		var info_col := VBoxContainer.new()
		info_col.name = "InfoCol"
		info_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		info_col.add_theme_constant_override("separation", 3)
		info_col.add_child(name_rtl)
		info_col.add_child(hp_bar_bg)
		info_col.add_child(stats_rtl)
		_header_row.add_child(info_col)

func _update_portrait(entity) -> void:
	if _portrait == null:
		return
	var tex: Texture2D = EntityIcon.texture(int(entity.entity_id), int(entity.entity_type))
	_portrait.texture = tex
	_portrait.visible = tex != null

# 生产按钮/框选分组共用的网格：桌面两列、手机一列，卡片由 EntityCard 生成
func _ensure_produce_grid() -> GridContainer:
	if _produce_grid != null and is_instance_valid(_produce_grid):
		return _produce_grid
	_produce_grid = GridContainer.new()
	_produce_grid.name = "ProduceGrid"
	_produce_grid.columns = 1 if _is_mobile() else 2
	_produce_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_produce_grid.add_theme_constant_override("h_separation", 6)
	_produce_grid.add_theme_constant_override("v_separation", 4)
	produce_vbox.add_child(_produce_grid)
	return _produce_grid

func _clear_produce_area() -> void:
	for c in produce_vbox.get_children():
		c.queue_free()
	_produce_grid = null

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
	# 手机端交给 TouchGestureRouter / UILayout.scroll_at 驱动，避免和面板横滑手势抢事件。
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
	_set_rtl_font(_detail_rtl, _mobile_font(UITheme.FONT_SM))
	_detail_content.add_child(_detail_rtl)
	_detail_view.visible = false

func _on_detail_toggle_pressed() -> void:
	_detail_mode = not _detail_mode
	_apply_detail_mode(true)

func _apply_detail_mode(force_reset: bool = false) -> void:
	var has_single: bool = observed_entity != null and is_instance_valid(observed_entity)
	if detail_toggle != null:
		detail_toggle.visible = has_single
		detail_toggle.text = ("简略" if _detail_mode else "详细") if _is_mobile() else ("📄 简略" if _detail_mode else "📖 详细")
	var show_detail: bool = _detail_mode and has_single
	if _detail_view != null:
		_detail_view.visible = show_detail
	if _vb != null:
		_vb.visible = not show_detail
	if _panel_scroll != null:
		_panel_scroll.visible = not show_detail
	if show_detail:
		var key: int = observed_entity.get_instance_id()
		var reset: bool = force_reset or key != _detail_last_id
		if reset:
			_detail_last_id = key
		_refresh_detail_text(reset)

func _entity_detail_state(entity) -> Dictionary:
	var d := {
		"health": entity.health,
		"max_health": entity.max_health,
		"attack": entity.attack,
		"attack_speed": entity.attack_speed,
		"attack_range": entity.attack_range,
		"speed": entity.speed,
		"melee_armor": entity.melee_armor,
		"shield_armor": entity.shield_armor,
		"level": entity.level,
		"nation": _entity_nation(entity),
		"max_health_breakdown": EntityBonusText.stat_breakdown_text(entity, "max_health"),
		"attack_breakdown": EntityBonusText.stat_breakdown_text(entity, "attack"),
		"attack_range_breakdown": EntityBonusText.stat_breakdown_text(entity, "attack_range", 1),
		"speed_breakdown": EntityBonusText.stat_breakdown_text(entity, "speed", 1),
		"melee_armor_breakdown": EntityBonusText.stat_breakdown_text(entity, "melee_armor"),
		"shield_armor_breakdown": EntityBonusText.stat_breakdown_text(entity, "shield_armor"),
		"attack_speed_breakdown": EntityBonusText.attack_speed_breakdown_text(entity),
	}
	if entity is Army:
		d["task"] = _army_task_text(entity)
	return d

func _refresh_detail_text(reset_scroll: bool) -> void:
	if _detail_rtl == null or not is_instance_valid(_detail_rtl):
		return
	if observed_entity == null or not is_instance_valid(observed_entity):
		return
	var text: String = EntityInfoText.detailed(int(observed_entity.entity_id), _entity_detail_state(observed_entity))
	# 详细页也展示加成来源：国家特色 + 科研，避免切到详细后信息消失
	text += _bonus_text(observed_entity)
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
	var old = _vb.get_node_or_null(nm)
	if not old: return
	var p = old.get_parent(); var i = old.get_index()
	p.remove_child(old); old.queue_free()
	var r = RichTextLabel.new(); r.name = nm
	r.bbcode_enabled = true; r.fit_content = true; r.autowrap_mode = TextServer.AUTOWRAP_OFF
	r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.add_child(r); p.move_child(r, i)

# 血条颜色 = 阵营色：常规对局红/蓝两种，混战模式改用国家色（每国一色）。
# 血量高低不再靠血条颜色表达，改由旁边 HP 数字的颜色体现——血条要负责「这是谁的单位」。
func _faction_color(entity) -> Color:
	if entity == null or not is_instance_valid(entity):
		return Color(0.7, 0.7, 0.7)
	var bm = get_tree().get_first_node_in_group("battle_manager")
	var ffa: bool = GameSettings.is_ffa
	var nation: int = -1
	if bm != null:
		if "is_ffa" in bm:
			ffa = bool(bm.get("is_ffa"))
		if bm.has_method("get_entity_nation"):
			nation = int(bm.get_entity_nation(entity))
	return RTSConfig.faction_color(int(entity.team), nation, ffa)

# 单位所属国家：优先按 owner_peer_id 解析，无法解析时由 battle_manager 按队伍兜底。
func _entity_nation(entity) -> int:
	if entity == null or not is_instance_valid(entity):
		return -1
	var bm = battle if battle else get_tree().get_first_node_in_group("battle_manager")
	if bm != null and bm.has_method("get_entity_nation"):
		return int(bm.get_entity_nation(entity))
	return -1

# 左侧信息面板的“国家”行。中立单位没有国家，返回空串不占行。
func _nation_display(entity) -> String:
	var nation: int = _entity_nation(entity)
	if nation < 0:
		return ""
	var bm = battle if battle else get_tree().get_first_node_in_group("battle_manager")
	var nation_name := ""
	if bm != null and bm.has_method("get_nation_name"):
		nation_name = str(bm.get_nation_name(nation))
	if nation_name.is_empty():
		nation_name = "未知"
	var nc: Color = RTSConfig.get_nation_color(nation) if RTSConfig.has_nation_color(nation) else UITheme.GOLD
	return "🌍 [color=%s]国家[/color]:  [color=%s]%s[/color]" % [
		UITheme.hex_str(UITheme.PARCHMENT), UITheme.hex_str(nc), nation_name]

# 加成来源：国家特色（始终显示）+ 已生效科研（科研模式才显示）。
# 科研部分直接对比实体套用科技前的基础值，避免把国家加成误算成科研。
func _bonus_text(entity) -> String:
	var nation: int = _entity_nation(entity)
	var out: String = EntityBonusText.nation_block(nation)
	var bm = battle if battle else get_tree().get_first_node_in_group("battle_manager")
	if nation >= 0 and bm != null and bm.has_method("is_research_mode") and bm.is_research_mode():
		out += EntityBonusText.research_block_from_entity(entity)
	out += EntityBonusText.official_block(entity)
	return out

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

# 单位任务：军事单位按五状态战斗模型显示，其余单位仍按 UnitState 旧任务显示。
# 五状态不能只看 current_order：攻击移动锁到敌人后 current_order 会变成 attack，
# 但 combat_resume_advance 仍表示“打完后继续推进”，必须显示成攻击移动。
func _army_task_text(a: Army) -> String:
	if a.has_method("_uses_combat_state") and a._uses_combat_state():
		return _combat_army_task_text(a)
	return _legacy_army_task_text(a)

# 五状态任务：守墙 > 攻击移动交战 > 驻守 > 反击 > 追击/攻击 > 行军。
# 守墙和驻守是长期任务，优先于当前锁定的目标，避免任务栏只显示“攻击”而看不出职责。
func _combat_army_task_text(a: Army) -> String:
	var target = a.current_target
	# 采集/交付的目标是资源点，不是作战目标；只把军队/建筑当作攻击目标显示
	var has_target: bool = target != null and is_instance_valid(target) \
		and target.health > 0 and (target is Army or target is Building)
	if a.has_meta("ai_wall_guard"):
		var on_wall: bool = a.has_method("_is_effective_wall_guard") and a._is_effective_wall_guard()
		if has_target:
			return "🏰 守墙 · 迎敌 · %s" % _target_display_name(target)
		if a.combat_state == Army.CombatState.MARCH or not on_wall:
			return "🏰 守墙 · 前往城墙"
		return "🏰 守墙"
	# 攻击移动途中锁到目标时，is_attack_moving 会被清掉，但续接标记还在。
	if a.combat_resume_advance and a.combat_resume_destination != Vector3.ZERO:
		if has_target:
			var verb: String = "追击" if a.combat_state == Army.CombatState.PURSUE else "交战"
			return "🎯 攻击移动 · %s · %s" % [verb, _target_display_name(target)]
		return "🎯 攻击移动"
	if a.garrison_point != Vector3.ZERO:
		if has_target:
			return "🏰 驻守 · 迎敌 · %s" % _target_display_name(target)
		if a.combat_state == Army.CombatState.MARCH:
			return "🏰 驻守 · 返回驻扎点"
		return "🏰 驻守"
	if has_target and _army_is_countering(a, has_target):
		return "🛡 反击 · %s" % _target_display_name(target)
	if has_target:
		if a.combat_state == Army.CombatState.PURSUE:
			return "🏃 追击 · %s" % _target_display_name(target)
		return "⚔ 攻击 · %s" % _target_display_name(target)
	if a.combat_state == Army.CombatState.ADVANCE or a.is_attack_moving \
			or a.current_order == "attack_move":
		return "🎯 攻击移动"
	if a.combat_state == Army.CombatState.MARCH:
		return "👣 行军"
	if not a.command_queue.is_empty():
		return "📋 待执行指令 %d" % a.command_queue.size()
	if a.hold_position:
		return "✋ 原地坚守"
	return "空闲"

# 反击判定：建筑临时回防、驻扎圈自动迎敌、被同一敌人攻击后的还击。
func _army_is_countering(a: Army, has_target: bool) -> bool:
	if not has_target:
		return false
	var target = a.current_target
	var now: float = float(battle.game_time) if battle != null else 0.0
	if a.has_meta("ai_building_defense_until") and now < float(a.get_meta("ai_building_defense_until")):
		return true
	if a.garrison_point != Vector3.ZERO:
		var defend_radius: float = 10.0
		if a.has_meta("ai_building_defense_until"):
			defend_radius = 45.0
		if target.global_position.distance_to(a.garrison_point) <= defend_radius:
			return true
	var last_damager = a.get("_last_damager")
	if last_damager != null and is_instance_valid(last_damager) and last_damager == target:
		return true
	return false

# 非五状态单位（农民/商队/官员/僧侣/运输等）沿用原来的任务说明。
func _legacy_army_task_text(a: Army) -> String:
	# 农民施工/修理时 current_target 会被清空，真正的目标记在 _work_target_id；
	# 旧任务栏只看 current_target，所以这类任务一直显示“空闲”。
	if a.current_order == "build":
		var work_b = a._get_work_building() if a.has_method("_get_work_building") else null
		if work_b != null:
			var at_site: bool = bool(a.get("_at_work_site"))
			var repairing: bool = bool(work_b.repair_pending) or (work_b.has_method("is_under_repair") and work_b.is_under_repair())
			var label: String
			if repairing:
				label = "🔧 修理" if at_site else "🔧 前往修理"
			else:
				label = "🔨 建造" if at_site else "🔨 前往建造"
			return "%s · %s" % [label, _target_display_name(work_b)]
		# 目标建筑已被拆掉/缓存未刷新时，至少不要让农民看起来在“空闲”。
		return "🔨 建造/修理"
	var target = a.current_target
	# 采集/交付的目标是资源点，不是作战目标；只把军队/建筑当作攻击目标显示
	var has_target: bool = target != null and is_instance_valid(target) and target.health > 0 and (target is Army or target is Building)
	if has_target and _army_is_countering(a, has_target):
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
			var gres := _gather_resource_name(a, false)
			return ("⛏ 采集 · %s" % gres) if gres != "" else "⛏ 采集"
		"deliver":
			var dres := _gather_resource_name(a, true)
			return ("📦 交付 · %s" % dres) if dres != "" else "📦 交付"
	if not a.command_queue.is_empty():
		return "📋 待执行指令 %d" % a.command_queue.size()
	return "空闲"

# 采集/交付的物资种类（黄金/木材/石头/食物/石油）；取不到时返回空串
# 采集阶段看当前资源点的 resource_type，交付阶段看农民身上携带的 cargo
func _gather_resource_name(a: Army, prefer_cargo: bool) -> String:
	var rk: String = ""
	if not prefer_cargo:
		var t = a.current_target
		if t != null and is_instance_valid(t):
			var rt = t.get("resource_type")
			if rt != null:
				rk = str(rt)
	if rk == "":
		var cargo = a.get("cargo")
		if cargo is Dictionary:
			for k in ["gold", "wood", "stone", "food", "oil"]:
				if int(cargo.get(k, 0)) > 0:
					rk = k
					break
	if rk == "":
		return ""
	return str(UITheme.RESOURCE_NAMES.get(rk, rk))

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

# 不同队伍且非中立：只读信息面板上显示「敌方」而不是「队友」
func _is_enemy_entity(entity) -> bool:
	if entity == null or not is_instance_valid(entity):
		return false
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if not bm: return false
	return entity.team != RTSConfig.Team.NEUTRAL and entity.team != bm.get_host_team()

func _is_neutral_entity(entity) -> bool:
	if entity == null or not is_instance_valid(entity):
		return false
	return entity.team == RTSConfig.Team.NEUTRAL

# 中立目标类型只影响只读标签，不提供任何操作入口
func _neutral_readonly_label(entity) -> String:
	if entity is WorldResource:
		return "中立资源"
	if entity is Army:
		return "中立动物"
	if entity is Building:
		return "中立建筑"
	return "中立"

func update_info(entity):
	if entity == null or not is_instance_valid(entity) or entity.health <= 0:
		observed_entity = null
		visible = false
		return
	# 单选时不该留着框选多选的操作按钮
	_hide_multi_board_btn()
	_hide_multi_garrison_btn()
	_multi_entities.clear()
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
	# 选中后先显示单位名字（配置表里的 name，如“农民”“采集船”），再接等级
	var unit_name := str(EntityDatabase.get_config(int(entity.entity_id)).get("name", "单位"))
	var nm = group_prefix + "%s %s  [color=%s]Lv.%d[/color]" % [
		UITheme.entity_emoji(entity.entity_id, entity.entity_type),
		unit_name,
		UITheme.hex_str(UITheme.GOLD), entity.level]
	# 中立资源虽然不属于玩家，但采集是玩家可执行的操作，不能按“仅查看”处理。
	var readonly := not _is_local_owned_entity(entity) and not (entity is WorldResource)
	var readonly_label := "队友"
	if _is_enemy_entity(entity):
		readonly_label = "敌方"
	elif _is_neutral_entity(entity):
		readonly_label = _neutral_readonly_label(entity)
	if batch_count > 1:
		nm += "  [color=%s][Ctrl + x%d][/color]" % [UITheme.hex_str(UITheme.ALERT_WARNING), batch_count]
	if readonly:
		# 另起一行：和名字挤在同一行时，长中文会把名字挤出可视区域，看起来像"名字不见了"
		nm += "\n[color=%s]（%s · 仅查看）[/color]" % [UITheme.hex_str(UITheme.ALERT_WARNING), readonly_label]
	name_rtl.text = nm
	_update_portrait(entity)

	var pct = float(entity.health) / max(float(entity.max_health), 1.0)
	hp_bar.color = _faction_color(entity)
	hp_bar.anchor_right = pct
	if hp_bar_bg: hp_bar_bg.visible = true
	hp_bar.visible = true

	# 资源点：只展示资源种类/剩余量和采集人数，不再显示 ATK/RANGE 等战斗属性。
	if entity is WorldResource:
		_hide_all_action_buttons()
		_update_resource_ui(entity)
		_apply_detail_mode()
		return

	_hide_resource_box()
	_hide_attack_box()
	if _ungarrison_btn:
		_ungarrison_btn.visible = false

	var hc = _hc(pct)
	var t := _nation_display(entity)
	if t != "":
		t += "\n"
	t += "❤️ [color=%s]HP[/color]:  [color=white]%d[/color] / %s\n" % [
		hc, entity.health, EntityBonusText.stat_breakdown_text(entity, "max_health")]
	t += "⚔️ [color=%s]ATK[/color]:  %s" % [
		UITheme.hex_str(UITheme.GOLD), EntityBonusText.stat_breakdown_text(entity, "attack")]
	if entity.melee_armor > 0 or entity.shield_armor > 0:
		t += "\n⛓️ [color=%s]铠甲[/color]:  %s  🛡️ [color=%s]盾牌[/color]:  %s" % [
			UITheme.hex_str(UITheme.SAPPHIRE), EntityBonusText.stat_breakdown_text(entity, "melee_armor"),
			UITheme.hex_str(UITheme.STONE), EntityBonusText.stat_breakdown_text(entity, "shield_armor")]
	t += "\n🎯 [color=%s]RANGE[/color]:  %s" % [
		UITheme.hex_str(UITheme.GOLD), EntityBonusText.stat_breakdown_text(entity, "attack_range", 1)]
	t += "\n👟 [color=%s]SPEED[/color]:  %s" % [
		UITheme.hex_str(UITheme.EMERALD), EntityBonusText.stat_breakdown_text(entity, "speed", 1)]
	if entity.attack > 0.0:
		t += "\n⚡ [color=%s]攻速[/color]:  %s [color=%s]次/秒[/color]" % [
			UITheme.hex_str(UITheme.ALERT_WARNING), EntityBonusText.attack_speed_breakdown_text(entity),
			UITheme.hex_str(UITheme.STONE)]
	if entity is Building:
		var gids: Array = entity.get_garrison_unit_ids() if entity.has_method("get_garrison_unit_ids") else []
		if not gids.is_empty():
			var gcounts: Dictionary = {}
			for gid in gids:
				gcounts[int(gid)] = int(gcounts.get(int(gid), 0)) + 1
			var gparts: Array[String] = []
			for gid in gcounts:
				var cfg: Dictionary = EntityDatabase.get_config(int(gid))
				gparts.append("%s%s×%d" % [UITheme.entity_emoji(int(gid), 2),
					str(cfg.get("name", "单位")), int(gcounts[gid])])
			t += "\n🛡️ [color=%s]驻军[/color] (%d/%d):  %s" % [
				UITheme.hex_str(UITheme.EMERALD), entity.get_garrison_count(),
				entity.get_garrison_limit(), "、".join(gparts)]
		if entity.build_timer > 0.0:
			var bp := clampf(1.0 - entity.build_timer / maxf(entity.max_build_time, 0.001), 0.0, 1.0)
			if entity.awaiting_builder and entity.builder_count_cache == 0:
				t += "\n🔨 [color=%s]等待农民[/color]:  右键工地可手动派农民" % UITheme.hex_str(UITheme.ALERT_WARNING)
			elif entity.awaiting_builder:
				t += "\n🔨 [color=%s]农民赶路中[/color]:  %d 人" % [UITheme.hex_str(UITheme.ALERT_WARNING), entity.builder_count_cache]
			else:
				t += "\n🔨 [color=%s]建造中[/color]:  [color=white]%d%%[/color]  农民:%d" % [
					UITheme.hex_str(UITheme.BUILD_PROGRESS), int(bp * 100.0), entity.builder_count_cache]
		if entity.upgrade_timer > 0.0 and entity.max_upgrade_time > 0.0:
			var up_pct := clampf(1.0 - entity.upgrade_timer / entity.max_upgrade_time, 0.0, 1.0)
			t += "\n⬆️ [color=%s]升级中[/color]:  [color=white]%d%%[/color]" % [
				UITheme.hex_str(UITheme.UPGRADE_PROGRESS), int(up_pct * 100.0)]
	if entity is Building and entity.has_method("repair_damage_ratio"):
		if entity.repair_pending:
			t += "\n🔧 [color=%s]等待农民修理[/color]" % UITheme.hex_str(UITheme.REPAIR_PROGRESS)
		elif entity.is_under_repair() and entity.max_repair_time > 0.0:
			var rep_pct := clampf(1.0 - entity.repair_timer / entity.max_repair_time, 0.0, 1.0)
			t += "\n🔧 [color=%s]修理中[/color]:  [color=white]%d%%[/color]  农民:%d" % [
				UITheme.hex_str(UITheme.REPAIR_PROGRESS), int(rep_pct * 100.0), entity.builder_count_cache]
		elif entity.repair_damage_ratio() > 0.001:
			t += "\n🔧 [color=%s]已损[/color]:  [color=white]%d%%[/color]" % [
				UITheme.hex_str(UITheme.ALERT_WARNING), int(entity.repair_damage_ratio() * 100.0)]
	if entity is Army:
		if entity.entity_id == 10:
			t += EntityInfoText.peasant_cargo_text(entity.cargo, entity.max_cargo)
		elif MerchantMarker.is_merchant(entity.entity_id):
			t += EntityInfoText.merchant_goods_text(
				entity.entity_id, str(entity._merchant_resource),
				int(entity._merchant_trade_volume), int(entity._merchant_state))
		if entity.entity_id in [5, 6] and entity.has_method("get_cart_owner_id") and entity.get_cart_owner_id() > 0:
			t += "\n🛒 [color=%s]已挂载[/color]:  跟随%s" % [
				UITheme.hex_str(UITheme.EMERALD), "农民" if entity.entity_id == 5 else "商人"]
		elif entity.has_meta("_has_cart"):
			t += "\n🛒 [color=%s]已挂载[/color]:  %s" % [
				UITheme.hex_str(UITheme.EMERALD), "手推车（+50 载重）" if entity.entity_id == 10 else "贸易车（+80 贸易收益）"]
		t += "\n🧭 [color=%s]任务[/color]:  [color=white]%s[/color]" % [
			UITheme.hex_str(UITheme.SAPPHIRE), _army_task_text(entity)]
	t += _bonus_text(entity)
	stats_rtl.text = t

	# 敌方单位/建筑：不再显示生产/升级等只读操作，改为按兵种给出攻击按钮。
	if _is_enemy_entity(entity) and (entity is Army or entity is Building):
		_hide_all_action_buttons()
		_update_attack_ui(entity)
		hp_bar.visible = true
		_promote_mobile_actions()
		_apply_detail_mode()
		return

	# Always detach old upgrade box first (avoid deferred-deletion residue)
	var old_box = _vb.get_node_or_null("UpgradeInfoBox")
	if old_box:
		_vb.remove_child(old_box)
		old_box.queue_free()
	if entity is Building:
		# 拆除按钮（城堡不可拆；队友建筑只读）
		if demolish_btn:
			demolish_btn.visible = (entity.entity_id != 20) and not readonly
		if _ungarrison_btn:
			var gc := int(entity.get_garrison_count())
			_ungarrison_btn.visible = gc > 0 and not readonly
			_ungarrison_btn.text = "🚪 取消进驻 (%d)" % gc
		_update_repair_ui(entity, readonly)
		_update_builder_ui(entity, readonly)
		if cancel_build_btn:
			var can_cancel := false
			if entity.build_timer > 0.0 and not readonly:
				var bp2 := clampf(1.0 - entity.build_timer / maxf(entity.max_build_time, 0.001), 0.0, 1.0)
				can_cancel = bp2 <= 0.001 and entity.entity_id not in [20, 53]
			cancel_build_btn.visible = can_cancel
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

		_clear_produce_area()
		if not entity.production_list.is_empty():
			produce_vbox.visible = true
			# 书院显示当前官员编制，让玩家知道为什么官员生产按钮会置灰。
			if entity.entity_id == 42 and battle and battle.has_method("get_official_host_capacity"):
				var cap: int = battle.get_official_host_capacity(entity.team, entity.owner_peer_id)
				var used: int = battle.count_official_units(entity.team, entity.owner_peer_id)
				var cap_label := _make_rtl_label()
				cap_label.text = "官员编制（含排队）[color=%s]%d / %d[/color]" % [
					UITheme.hex_str(UITheme.GOLD), used, cap]
				produce_vbox.add_child(cap_label)
			var grid := _ensure_produce_grid()
			var seen = {}
			for prod in entity.production_list:
				if seen.has(prod.unit_id): continue
				seen[prod.unit_id] = true
				var uc = EntityDatabase.get_config(prod.unit_id)
				if not uc: continue
				var ok = true; var cs = []
				var lv = entity.level
				for res in uc.get("cost", {}):
					var base = uc["cost"][res]
					var scaled = int(base * (1.0 + (lv - 1) * 0.2))
					var need = scaled * batch_count
					var have = _get_res().get(res, 0)
					if have < need: ok = false
					cs.append({"res": res, "need": need})
				var official_full := false
				if battle and battle.has_method("can_produce_official") and uc.get("official_type", "") != "":
					official_full = not battle.can_produce_official(prod.unit_id, entity)
				var ct = ""
				for ci in cs:
					var cc = "white" if _get_res().get(ci.res, 0) >= ci.need else UITheme.hex_str(UITheme.VERMILION)
					ct += "%s[color=%s]%d[/color] " % [UITheme.RESOURCE_ICONS.get(ci.res, ""), cc, ci.need]
				# 大图标卡片：桌面 64px 图标 / 手机 40dp，名字一行、价格一行
				var card_min := Vector2(0, UILayout.dp(64.0)) if _is_mobile() else Vector2(0, 86.0)
				var icon_px: float = UILayout.dp(48.0) if _is_mobile() else 64.0
				var card := EntityCard.make(int(prod.unit_id), 2, uc.get("name", "?"), ct.strip_edges(),
					icon_px, card_min, UITheme.GOLD, false,
					_mobile_font(UITheme.FONT_MD) if _is_mobile() else UITheme.FONT_MD,
					_mobile_font(UITheme.FONT_XS) if _is_mobile() else UITheme.FONT_XS, false)
				card.disabled = (not ok) or readonly or official_full
				EntityCard.set_dimmed(card, card.disabled)
				if official_full and not readonly:
					card.tooltip_text = "官员总数不能超过可进驻建筑数"
				elif readonly:
					card.tooltip_text = "%s仅可查看，无法下达生产命令" % readonly_label
				card.pressed.connect(func(): _on_produce_pressed(prod.unit_id))
				grid.add_child(card)
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
		if repair_btn: repair_btn.visible = false
		if cancel_build_btn: cancel_build_btn.visible = false
		_hide_builder_box()
	hp_bar.visible = true
	_promote_mobile_actions()
	_apply_detail_mode()

# 手机竖屏/横屏信息面板高度只有 200dp，属性文字较长时升级/生产按钮会被挤到可视区外。
# 把玩法操作提到属性前面，至少保证「升级」和第一批生产卡不用滚动就能点到。
func _promote_mobile_actions() -> void:
	if not _is_mobile() or _vb == null:
		return
	var idx: int = 2
	if upgrade_btn != null and is_instance_valid(upgrade_btn) and upgrade_btn.visible:
		_vb.move_child(upgrade_btn, idx)
		idx += 1
	var box := _vb.get_node_or_null("UpgradeInfoBox")
	if box != null:
		_vb.move_child(box, idx)
		idx += 1
	if produce_vbox != null and is_instance_valid(produce_vbox) and produce_vbox.visible:
		_vb.move_child(produce_vbox, idx)
		idx += 1
	if _builder_box != null and is_instance_valid(_builder_box) and _builder_box.visible:
		_vb.move_child(_builder_box, idx)
		idx += 1
	if _attack_box != null and is_instance_valid(_attack_box) and _attack_box.visible:
		_vb.move_child(_attack_box, idx)

# 切到资源点时把建筑/单位操作全部收起，避免残留“升级/生产/拆除”按钮。
func _hide_all_action_buttons() -> void:
	if upgrade_btn: upgrade_btn.visible = false
	if produce_vbox: produce_vbox.visible = false
	if demolish_btn: demolish_btn.visible = false
	if repair_btn: repair_btn.visible = false
	if cancel_build_btn: cancel_build_btn.visible = false
	if _ungarrison_btn: _ungarrison_btn.visible = false
	_hide_builder_box()
	_hide_attack_box()
	_hide_multi_board_btn()
	_hide_multi_garrison_btn()
	_clear_produce_area()
	var old_box = _vb.get_node_or_null("UpgradeInfoBox")
	if old_box:
		_vb.remove_child(old_box)
		old_box.queue_free()

func _hide_resource_box() -> void:
	if _resource_box != null:
		_resource_box.visible = false

func _hide_builder_box() -> void:
	if _builder_box != null:
		_builder_box.visible = false
	if _add_builder_btn != null:
		_add_builder_btn.visible = false
	if _add_repairer_btn != null:
		_add_repairer_btn.visible = false

func _hide_attack_box() -> void:
	_attack_groups.clear()
	if _attack_flow != null:
		for c in _attack_flow.get_children():
			_attack_flow.remove_child(c)
			c.queue_free()
	if _attack_box != null:
		_attack_box.visible = false

func _update_attack_ui(entity) -> void:
	if _attack_box == null or battle == null:
		return
	_hide_attack_box()
	if not (entity is Army or entity is Building):
		return
	var groups: Dictionary = {}
	if battle.has_method("get_attack_groups_in_vision"):
		groups = battle.get_attack_groups_in_vision(entity)
	if groups.is_empty():
		return
	_attack_groups = groups
	var total: int = 0
	for gid in groups:
		total += groups[gid].size()
	_attack_title_rtl.text = "⚔️ [color=%s]视野内可攻击的我方军队[/color]:  [color=white]%d[/color] 支" % [
		UITheme.hex_str(UITheme.VERMILION), total]
	_attack_box.visible = true
	var ids: Array = groups.keys()
	ids.sort()
	for gid in ids:
		var units: Array = groups[gid]
		if units.is_empty():
			continue
		var cfg: Dictionary = EntityDatabase.get_config(int(gid))
		var uname: String = str(cfg.get("name", "军队"))
		var b := Button.new()
		b.text = "%s %s ×%d" % [UITheme.entity_emoji(int(gid), 2), uname, units.size()]
		b.custom_minimum_size = Vector2(0, UILayout.dp(30.0) if _is_mobile() else 34.0)
		b.tooltip_text = "命令这 %d 支%s立即攻击选中目标" % [units.size(), uname]
		b.pressed.connect(_on_attack_group_pressed.bind(int(gid)))
		UITheme.apply_danger_button(b, UITheme.FONT_SM)
		_attack_flow.add_child(b)

func _on_attack_group_pressed(unit_id: int) -> void:
	if observed_entity == null or not is_instance_valid(observed_entity) or battle == null:
		return
	var n: int = 0
	if battle.has_method("command_attack_group"):
		n = int(battle.command_attack_group(observed_entity, unit_id))
	if n <= 0 and battle.has_method("_show_hud_alert"):
		battle._show_hud_alert("所选兵种当前无法攻击该目标", UITheme.ALERT_WARNING)
	update_info(observed_entity)

func _update_builder_ui(entity, readonly: bool) -> void:
	if _builder_box == null or battle == null or not (entity is Building):
		_hide_builder_box()
		return
	var constructing: bool = entity.build_timer > 0.0
	var repairing: bool = false
	if entity.has_method("is_under_repair"):
		repairing = entity.is_under_repair()
	if not constructing and not repairing:
		_hide_builder_box()
		return
	var count: int = 0
	if entity.has_method("builder_count"):
		count = entity.builder_count()
	_builder_box.visible = true
	if repairing:
		_builder_info_rtl.text = "🔧 [color=%s]修理人数[/color]:  [color=white]%d[/color] 人" % [
			UITheme.hex_str(UITheme.REPAIR_PROGRESS), count]
		_add_builder_btn.visible = false
		_add_repairer_btn.visible = true
		_add_repairer_btn.disabled = readonly
	else:
		_builder_info_rtl.text = "🔨 [color=%s]建造人数[/color]:  [color=white]%d[/color] 人" % [
			UITheme.hex_str(UITheme.BUILD_PROGRESS), count]
		_add_builder_btn.visible = true
		_add_builder_btn.disabled = readonly
		_add_repairer_btn.visible = false

func _on_add_builder_pressed() -> void:
	if observed_entity == null or not is_instance_valid(observed_entity):
		return
	if not (observed_entity is Building) or battle == null:
		return
	var ok: bool = false
	if battle.has_method("assign_builder_to_building"):
		ok = bool(battle.assign_builder_to_building(observed_entity))
	if not ok and battle.has_method("_show_hud_alert"):
		battle._show_hud_alert("附近没有可施工的我方农民", UITheme.ALERT_WARNING)
	update_info(observed_entity)

func _on_add_repairer_pressed() -> void:
	if observed_entity == null or not is_instance_valid(observed_entity):
		return
	if not (observed_entity is Building) or battle == null:
		return
	var ok: bool = false
	if battle.has_method("assign_builder_to_building"):
		ok = bool(battle.assign_builder_to_building(observed_entity))
	if not ok and battle.has_method("_show_hud_alert"):
		battle._show_hud_alert("附近没有可修理的我方农民", UITheme.ALERT_WARNING)
	update_info(observed_entity)

func _update_resource_ui(entity) -> void:
	if _resource_box == null or battle == null:
		return
	var team: int = battle.get_host_team()
	var n: int = 0
	if battle.has_method("count_gatherers_on_resource"):
		n = battle.count_gatherers_on_resource(entity, team)
	var remaining: float = 0.0
	if battle.has_method("resource_gather_blacklist_remaining"):
		remaining = battle.resource_gather_blacklist_remaining(entity, team)
	var rtype: String = str(entity.resource_type)
	var rname: String = str(UITheme.RESOURCE_NAMES.get(rtype, rtype))
	var hp: int = int(entity.health)
	var max_hp: int = int(entity.max_health)
	var txt: String = "🌿 [color=%s]%s[/color]\n" % [
		UITheme.hex_str(UITheme.RESOURCE_COLORS.get(rtype, UITheme.PARCHMENT)), rname]
	txt += "📦 剩余:  [color=white]%d / %d[/color]\n" % [hp, max_hp]
	txt += "⛏ 采集中:  [color=%s]%d[/color] 人" % [
		UITheme.hex_str(UITheme.EMERALD), n]
	if remaining > 0.0:
		txt += "\n[color=%s]🚫 已停止采集：剩余 %d 秒[/color]" % [
			UITheme.hex_str(UITheme.VERMILION), int(ceil(remaining))]
	stats_rtl.text = txt
	_resource_box.visible = true
	_resource_gather_btn.disabled = false
	_resource_gather_btn.text = "⛏ 采集"
	_resource_stop_btn.disabled = false
	_resource_stop_btn.text = "🚫 停止采集"
	if remaining > 0.0:
		_resource_stop_btn.text = "🚫 停止中 (%ds)" % int(ceil(remaining))

func _on_resource_gather_pressed() -> void:
	if observed_entity == null or not is_instance_valid(observed_entity):
		return
	if not (observed_entity is WorldResource) or battle == null:
		return
	var ok: bool = false
	if battle.has_method("assign_gatherer_to_resource"):
		ok = bool(battle.assign_gatherer_to_resource(observed_entity))
	if not ok and battle.has_method("_show_hud_alert"):
		battle._show_hud_alert("附近没有可采集的我方农民", UITheme.ALERT_WARNING)
	update_info(observed_entity)

func _on_resource_stop_pressed() -> void:
	if observed_entity == null or not is_instance_valid(observed_entity):
		return
	if not (observed_entity is WorldResource) or battle == null:
		return
	if battle.has_method("blacklist_resource_gathering"):
		battle.blacklist_resource_gathering(observed_entity, battle.get_host_team(), 120.0)
	if battle.has_method("_show_hud_alert"):
		battle._show_hud_alert("已停止采集该资源点 2 分钟", UITheme.ALERT_INFO)
	update_info(observed_entity)

func _on_upgrade_pressed():
	if not observed_entity or not is_instance_valid(observed_entity): return
	if not _is_local_owned_entity(observed_entity): return
	var n = 999 if Input.is_key_pressed(KEY_SHIFT) else 1
	# 升级已全局生效，只需升级当前建筑即可
	for _i in range(n):
		if not observed_entity.can_upgrade() or not observed_entity.perform_upgrade(battle): break

# 信息面板里的修理入口：只在「掉血且不是主城」时出现，和命令卡规则保持一致。
# 建造/升级中不显示；资源不足时保留按钮但置灰，tooltip 说明原因。
func _update_repair_ui(entity: Building, readonly: bool) -> void:
	if repair_btn == null:
		return
	repair_btn.visible = false
	if readonly or entity.entity_id in [20, 53]:
		return
	if not entity.has_method("repair_damage_ratio") or not entity.has_method("can_repair"):
		return
	var dmg: float = entity.repair_damage_ratio()
	var under: bool = entity.is_under_repair() if entity.has_method("is_under_repair") else false
	var pending: bool = entity.repair_pending if entity is Building else false
	var busy: bool = entity.build_timer > 0.0 or entity.upgrade_timer > 0.0
	if busy or (dmg <= 0.001 and not under):
		return
	repair_btn.visible = true
	var cost: Dictionary = entity.repair_cost() if entity.has_method("repair_cost") else {}
	var time_total: float = entity.repair_time_total() if entity.has_method("repair_time_total") else 0.0
	var can_click := false
	if not under:
		if battle and battle.has_method("can_repair_building"):
			can_click = battle.can_repair_building(entity)
		else:
			can_click = entity.can_repair()
	repair_btn.disabled = under or not can_click
	if pending and entity.repair_timer <= 0.0:
		repair_btn.text = "🔧 等待农民修理"
	elif under and entity.max_repair_time > 0.0:
		var pct: float = clampf(1.0 - entity.repair_timer / entity.max_repair_time, 0.0, 1.0)
		repair_btn.text = "🔧 修理中 %d%%" % int(pct * 100.0)
	else:
		repair_btn.text = "🔧 修理 %s" % _repair_cost_text(cost)
	var tip := "修理残破建筑：需要农民到场施工，修完回复到满血（主城不可修理）"
	tip += "\n费用：%s" % (_repair_cost_text(cost) if not cost.is_empty() else "免费")
	tip += "\n耗时：%.1f 秒" % maxf(time_total, 0.0)
	if pending:
		tip += "\n状态：已扣费，等待农民到场"
	elif under:
		tip += "\n状态：修理中"
	elif dmg <= 0.001:
		tip += "\n状态：建筑完好"
	elif not can_click:
		tip += "\n状态：资源不足或修理科技未解锁，暂不可修"
	repair_btn.tooltip_text = tip

func _repair_cost_text(cost: Dictionary) -> String:
	var parts: Array[String] = []
	for res in ["wood", "stone", "gold", "oil"]:
		var need := int(cost.get(res, 0))
		if need > 0:
			parts.append("%s%d" % [UITheme.RESOURCE_ICONS.get(res, ""), need])
	return " ".join(parts) if not parts.is_empty() else "免费"

func _on_repair_pressed():
	if not observed_entity or not is_instance_valid(observed_entity):
		return
	if not (observed_entity is Building):
		return
	if not _is_local_owned_entity(observed_entity):
		return
	var bm = battle if battle else get_tree().get_first_node_in_group("battle_manager") as RTSBattleManager
	if bm and bm.has_method("repair_building"):
		bm.repair_building(observed_entity)
	update_info(observed_entity)

func _on_ungarrison_pressed():
	if not observed_entity or not is_instance_valid(observed_entity):
		return
	if not (observed_entity is Building):
		return
	if not _is_local_owned_entity(observed_entity):
		return
	var bm = battle if battle else get_tree().get_first_node_in_group("battle_manager")
	if bm and bm.has_method("release_garrisoned"):
		bm.release_garrisoned(observed_entity)
	update_info(observed_entity)

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
		_board_up_btn.custom_minimum_size = Vector2(0, UILayout.dp(44.0))
		UITheme.apply_primary_button(_board_up_btn, UILayout.font_dp(12.0))
	else:
		_board_up_btn.custom_minimum_size = Vector2(90, 32)
		UITheme.apply_primary_button(_board_up_btn, UITheme.FONT_SM)
	_board_up_btn.pressed.connect(_on_board_up_pressed)
	row.add_child(_board_up_btn)

	_board_down_btn = Button.new()
	_board_down_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if _is_mobile():
		_board_down_btn.custom_minimum_size = Vector2(0, UILayout.dp(44.0))
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
	# 普通山地不可作为登陆点；缓坡/台地与浅滩是合格落点。
	# 浅滩（overlay==3）陆军能走，算合格落点。
	for r in [1.5, 2.5, 3.5, 5.0, 6.5, 8.0]:
		for i in 16:
			var ang: float = TAU * float(i) / 16.0
			var p := base + Vector3(cos(ang) * float(r), 0.0, sin(ang) * float(r))
			var terrain: int = int(bm.get_terrain_at(p))
			if terrain < 0:
				continue
			if terrain != 2 and bm.is_cliff_between_world(base, p):
				continue
			if terrain == 2:
				var g: Vector2i = bm.world_to_grid(p)
				if int(bm.get_overlay_at_grid(g.x, g.y)) != 3:
					continue
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
			# 水上单位（战船/渔船/爆破船）不能上运载船
			if bool(u.get("water_capable")):
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
	# 多选时 observed_entity 是空的，下面会早退，所以登船按钮的可用性要在这里单独刷新：
	# 船可能在这期间开走或装满，按钮必须跟着变灰。
	if _multi_entities.size() > 0:
		_multi_refresh_accum += delta
		if _multi_refresh_accum >= 1.0:
			_multi_refresh_accum = 0.0
			if visible:
				_refresh_multi_board_btn()
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

# 框选多选时底部的「陆地单位上附近运载船」按钮
const MULTI_BOARD_SEARCH_RADIUS: float = 120.0
var _multi_board_btn: Button = null
var _multi_garrison_btn: Button = null
var _multi_entities: Array = []
var _multi_refresh_accum: float = 0.0

func _ensure_multi_board_btn() -> void:
	if _multi_board_btn and is_instance_valid(_multi_board_btn):
		# 每次重选都把它挪到面板最底部
		if _multi_board_btn.get_parent() == _vb:
			_vb.move_child(_multi_board_btn, _vb.get_child_count() - 1)
		return
	_multi_board_btn = Button.new()
	_multi_board_btn.name = "MultiBoardBtn"
	_multi_board_btn.custom_minimum_size = Vector2(0, UILayout.dp(38.0)) if _is_mobile() else Vector2(200, 34)
	_multi_board_btn.add_theme_font_size_override("font_size", UILayout.font_dp(12.0) if _is_mobile() else UITheme.FONT_SM)
	UITheme.apply_row_button(_multi_board_btn, Color(0.35, 0.75, 1.0))
	_multi_board_btn.pressed.connect(_on_multi_board_pressed)
	_vb.add_child(_multi_board_btn)

func _hide_multi_board_btn() -> void:
	if _multi_board_btn and is_instance_valid(_multi_board_btn):
		_multi_board_btn.visible = false

func _ensure_multi_garrison_btn() -> void:
	if _multi_garrison_btn and is_instance_valid(_multi_garrison_btn):
		if _multi_garrison_btn.get_parent() == _vb:
			_vb.move_child(_multi_garrison_btn, _vb.get_child_count() - 1)
		return
	_multi_garrison_btn = Button.new()
	_multi_garrison_btn.name = "MultiGarrisonBtn"
	_multi_garrison_btn.custom_minimum_size = Vector2(0, UILayout.dp(38.0)) if _is_mobile() else Vector2(200, 34)
	_multi_garrison_btn.add_theme_font_size_override("font_size", UILayout.font_dp(12.0) if _is_mobile() else UITheme.FONT_SM)
	UITheme.apply_primary_button(_multi_garrison_btn, UITheme.FONT_SM)
	_multi_garrison_btn.pressed.connect(_on_multi_garrison_pressed)
	_vb.add_child(_multi_garrison_btn)

func _hide_multi_garrison_btn() -> void:
	if _multi_garrison_btn and is_instance_valid(_multi_garrison_btn):
		_multi_garrison_btn.visible = false

func _refresh_multi_garrison_btn() -> void:
	_ensure_multi_garrison_btn()
	var count := 0
	var bm = get_tree().get_first_node_in_group("battle_manager")
	var all_local := true
	for u in _multi_entities:
		if not is_instance_valid(u) or not (u is Army) or u.health <= 0:
			continue
		if bm and bm.has_method("get_host_team") and int(u.team) != int(bm.get_host_team()):
			all_local = false
			break
		count += 1
	if count == 0 or not all_local:
		_multi_garrison_btn.visible = false
		return
	_multi_garrison_btn.visible = true
	_multi_garrison_btn.disabled = false
	_multi_garrison_btn.text = "🛡️ 进驻建筑 (%d)" % count
	_multi_garrison_btn.tooltip_text = "点击后再点己方箭塔/炮塔/城堡或攻城车，把所选部队派去进驻"

func _on_multi_garrison_pressed() -> void:
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if bm and bm.has_method("set_pending_command_mode"):
		bm.set_pending_command_mode("garrison")

# 刷新「上附近运载船」按钮：有可上船的陆地单位、且附近有停靠岸边且没装满的运载船才能点
func _refresh_multi_board_btn() -> void:
	_ensure_multi_board_btn()
	_multi_board_btn.visible = true
	var candidates: Array = []
	for u in _multi_entities:
		if is_instance_valid(u) and u is Army and u.health > 0 and not bool(u.get("water_capable")):
			candidates.append(u)
	if candidates.is_empty():
		_multi_board_btn.visible = false
		return
	var ship = _nearest_idle_shore_transport(candidates[0].global_position, int(candidates[0].team), {})
	if ship == null:
		_multi_board_btn.text = "⛵ 附近没有空闲运载船"
		_multi_board_btn.disabled = true
		_multi_board_btn.tooltip_text = "需要一艘停在岸边、还有空位的运载船"
	else:
		_multi_board_btn.text = "⛵ 陆地单位上附近运载船 (%d)" % candidates.size()
		_multi_board_btn.disabled = false
		_multi_board_btn.tooltip_text = "框选中的陆地单位会自动走到最近的运载船并登船"

# 找最近的、还有空位、且停在岸边的运载船。
# load_map 记录本轮已经分配出去的名额，避免一艘船被塞爆。
func _nearest_idle_shore_transport(from: Vector3, team: int, load_map: Dictionary):
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if bm == null:
		return null
	bm._ensure_cache_fresh()
	var best = null
	var best_d: float = MULTI_BOARD_SEARCH_RADIUS
	for e in bm._armies:
		if not is_instance_valid(e) or e.health <= 0:
			continue
		if int(e.entity_id) != 9 or int(e.team) != team:
			continue
		var used: int = int(load_map.get(e.get_instance_id(), 0))
		if e.get_boarded_count() + used >= e.get_board_capacity():
			continue
		if not _is_transport_at_shore(e):
			continue
		var d: float = from.distance_to(e.global_position)
		if d <= best_d:
			best_d = d
			best = e
	return best

# 船停在岸边：船所在格是水，周围两圈内有可通行的陆地（平原或浅滩）
func _is_transport_at_shore(ship) -> bool:
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if bm == null:
		return false
	var g: Vector2i = bm.world_to_grid(ship.global_position)
	if int(bm.get_terrain_at_grid(g.x, g.y)) != 2:
		return false
	for r in range(1, 3):
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var gx: int = g.x + dx
				var gy: int = g.y + dy
				if gx < 0 or gy < 0 or gx >= RTSConfig.MAP_SIZE or gy >= RTSConfig.MAP_SIZE:
					continue
				var t: int = int(bm.get_terrain_at_grid(gx, gy))
				if t < 0 or t == 1:
					continue
				if t == 2 and int(bm.get_overlay_at_grid(gx, gy)) != 3:
					continue
				return true
	return false

# 点击：框选中的所有陆地单位各自走向最近的空闲运载船，到位后由 Army 自动登船
func _on_multi_board_pressed() -> void:
	var load_map: Dictionary = {}
	var assigned: int = 0
	for u in _multi_entities:
		if not is_instance_valid(u) or not (u is Army) or u.health <= 0:
			continue
		if bool(u.get("water_capable")):
			continue
		var ship = _nearest_idle_shore_transport(u.global_position, int(u.team), load_map)
		if ship == null:
			continue
		var shore: Vector3 = _ship_shore_point(ship)
		if shore == Vector3.ZERO:
			continue
		load_map[ship.get_instance_id()] = int(load_map.get(ship.get_instance_id(), 0)) + 1
		u.move_to(shore)
		u.set_meta("_auto_board_ship", ship.get_instance_id())
		assigned += 1
	_refresh_multi_board_btn()

func show_multi_selection(entities: Array):
	var old_box = _vb.get_node_or_null("UpgradeInfoBox")
	if old_box:
		_vb.remove_child(old_box)
		old_box.queue_free()
	visible = true
	observed_entity = null
	if _portrait != null:
		_portrait.visible = false
	upgrade_btn.visible = false
	if demolish_btn: demolish_btn.visible = false
	if repair_btn: repair_btn.visible = false
	if cancel_build_btn: cancel_build_btn.visible = false
	if _ungarrison_btn: _ungarrison_btn.visible = false
	produce_vbox.visible = true
	hp_bar.visible = false
	if hp_bar_bg: hp_bar_bg.visible = false
	name_rtl.text = "[color=%s]⚔️ 选中 %d 个单位[/color]" % [UITheme.hex_str(UITheme.GOLD), entities.size()]
	stats_rtl.text = ""
	_clear_produce_area()
	var grid := _ensure_produce_grid()

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
		var etype: int = 2
		if g["entities"].size() > 0:
			etype = g["entities"][0].entity_type
		var lvl_text = "Lv.%d" % g["min_level"] if g["min_level"] == g["max_level"] else "Lv.%d~%d" % [g["min_level"], g["max_level"]]
		# 大图标卡片：点数即选中，Ctrl+点击累加/取消
		var icon_px: float = UILayout.dp(48.0) if _is_mobile() else 64.0
		var card_min := Vector2(0, UILayout.dp(64.0)) if _is_mobile() else Vector2(0, 84.0)
		var card := EntityCard.make(int(g["entity_id"]), etype, "%d × %s" % [g["count"], g["name"]],
			lvl_text, icon_px, card_min, row_color, true,
			_mobile_font(UITheme.FONT_MD) if _is_mobile() else UITheme.FONT_MD,
			_mobile_font(UITheme.FONT_SM) if _is_mobile() else UITheme.FONT_SM, false)
		card.tooltip_text = "点击单独选中这一种；按住 Ctrl 点击可累加 / 取消"
		var row_entities = g["entities"].duplicate()
		card.pressed.connect(func():
			var sel = get_tree().get_first_node_in_group("battle_manager").get_node_or_null("SelectionManager")
			if not sel: return
			if Input.is_key_pressed(KEY_CTRL):
				if card.button_pressed:
					for e in row_entities:
						if is_instance_valid(e) and e not in _pending_multi_entities:
							_pending_multi_entities.append(e)
					_pending_multi_btns[card] = true
				else:
					for e in row_entities:
						_pending_multi_entities.erase(e)
					_pending_multi_btns.erase(card)
			else:
				for e in sel.selected_entities:
					if is_instance_valid(e): e.set_selected(false)
				sel.selected_entities = row_entities
				for e in row_entities:
					if is_instance_valid(e): e.set_selected(true)
				sel._update_info_panel()
		)
		grid.add_child(card)

	# Start monitoring Ctrl key release
	set_process_input(true)

	# 框选面板底部：一键让选中的陆地单位上附近的运载船
	_multi_entities = entities.duplicate()
	_refresh_multi_board_btn()
	_refresh_multi_garrison_btn()
	_apply_detail_mode()

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


func _on_cancel_build_pressed():
	if not observed_entity or not is_instance_valid(observed_entity):
		return
	if not (observed_entity is Building):
		return
	if not _is_local_owned_entity(observed_entity):
		return
	var bm = get_tree().get_first_node_in_group("battle_manager") as RTSBattleManager
	if bm and bm.has_method("cancel_construction"):
		bm.cancel_construction(observed_entity)
	if cancel_build_btn:
		cancel_build_btn.visible = false
	observed_entity = null
	visible = false

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

extends Control

const MapPresets = preload("res://scripts/map/MapPresets.gd")
const MapSelectDialog = preload("res://scripts/ui/MapSelectDialog.gd")
const AppVersion = preload("res://scripts/core/AppVersion.gd")
const ChangelogData = preload("res://scripts/data/ChangelogData.gd")
const ChangelogPanel = preload("res://scripts/ui/ChangelogPanel.gd")
const GuidePanel = preload("res://scripts/ui/GuidePanel.gd")
const TechOverviewPanel = preload("res://scripts/ui/TechOverviewPanel.gd")
const UpdateConfig = preload("res://scripts/core/UpdateConfig.gd")
const UpdateChecker = preload("res://scripts/core/UpdateChecker.gd")

var nation_select: OptionButton
var _nation_detail: Label = null
var _mode_detail: Label = null
var _last_mode_idx: int = 0
var _map_button: Button = null
# 带 NEW 未读标记的更新日志按钮（打开日志后清掉标记）
var _changelog_btn: Button = null
# 更新检查（有新版时底部弹出下载按钮）
var _update_checker: UpdateChecker = null
var _update_banner: Button = null
# 手机端滚动列表：有新版时把下载按钮插到最上面
var _mobile_vb: VBoxContainer = null

# 主菜单场景没有战斗内的 TouchGestureRouter：触摸拖动直接驱动 ScrollContainer 滚动
# （手机点击仍由引擎模拟鼠标完成，这里只管滑动）。
func _input(event: InputEvent) -> void:
	if not InputSource.use_mobile_ui():
		return
	if event is InputEventScreenDrag:
		UILayout.scroll_at(self, event.position, event.relative.y)

func _ready():
	# 触屏滑动误点守卫：菜单里所有滚动列表（地图/模式卡片）滑动后不再误触点击
	add_child(TouchDragGuard.new())
	AudioManager.play_music("menu")
	# Scale to fit screen (design: 2400x1400)
	var vs = get_viewport().get_visible_rect().size
	var s = min(vs.x / 2400.0, vs.y / 1400.0)
	scale = Vector2(s, s)
	position = (vs - Vector2(2400, 1400) * s) / 2.0
	# 手机端：桌面绝对布局在 674×393dp 的屏幕上字只有 5~7dp，改用竖排滚动布局
	if InputSource.use_mobile_ui():
		# 手机布局直接铺满「展开后的设计视口」：竖屏时视口会变成 2400×4267，
		# 如果仍按 2400×1400 居中缩放，菜单只会占屏幕中间一条，上下全是黑的。
		scale = Vector2.ONE
		position = Vector2.ZERO
		# 锚点铺满：即使 Web 首帧稍后才把视口从 2400×1400 扩成竖屏高度，根节点也会跟着长高。
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		size = UILayout.view_size()
		# 横竖屏切换后重建菜单：所有 dp 尺寸和滚动区高度都要按新方向重算。
		add_child(OrientationReload.new())
		# 场景里那套桌面节点必须一起隐藏，否则会和下面的竖排布局重叠，变成"两层 UI"
		var old_box = get_node_or_null("VBoxContainer")
		if old_box: old_box.visible = false
		_build_mobile_layout()
		_setup_update_check()
		return
	# 桌面/网页：按当前实际画布尺寸铺满，宽屏/超宽屏两边不再留黑边。
	var design_size = Vector2(ceil(vs.x / s), maxf(1400.0, ceil(vs.y / s)))
	size = design_size
	position = Vector2.ZERO
	var old_box = get_node_or_null("VBoxContainer")
	if old_box: old_box.visible = false
	_build_desktop_layout()
	_setup_update_check()

# ==================== 桌面版：整屏卡片式布局 ====================
func _build_desktop_layout() -> void:
	# 全屏暖黑背景（羊皮纸皇庭底色）
	var bg = ColorRect.new()
	bg.color = Color(0.10, 0.08, 0.06)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	move_child(bg, 0)

	# 顶部皇庭金饰横条
	var top_bar = ColorRect.new()
	top_bar.color = Color(UITheme.GOLD)
	top_bar.position = Vector2(0, 0)
	top_bar.size = Vector2(size.x, 6)
	add_child(top_bar)
	var top_bar2 = ColorRect.new()
	top_bar2.color = Color(UITheme.GOLD, 0.35)
	top_bar2.position = Vector2(0, 6)
	top_bar2.size = Vector2(size.x, 3)
	add_child(top_bar2)

	# 整屏外边距：上/下 20，左/右 28；内部全部用容器分配，不再堆绝对坐标。
	var frame = MarginContainer.new()
	frame.name = "DesktopFrame"
	frame.size = size
	frame.add_theme_constant_override("margin_left", 28)
	frame.add_theme_constant_override("margin_right", 28)
	frame.add_theme_constant_override("margin_top", 20)
	frame.add_theme_constant_override("margin_bottom", 20)
	add_child(frame)

	var layout = VBoxContainer.new()
	layout.name = "DesktopLayout"
	layout.add_theme_constant_override("separation", 12)
	frame.add_child(layout)

	# ---------- 顶部标题栏 ----------
	var header = HBoxContainer.new()
	header.name = "Header"
	header.custom_minimum_size = Vector2(0, 132)
	header.add_theme_constant_override("separation", 18)
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	layout.add_child(header)

	var title_box = VBoxContainer.new()
	title_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_box.alignment = BoxContainer.ALIGNMENT_CENTER
	title_box.add_theme_constant_override("separation", 2)
	header.add_child(title_box)

	var title = Label.new()
	title.text = "👑 指尖帝国"
	title.add_theme_font_size_override("font_size", 68)
	title.add_theme_color_override("font_color", UITheme.GOLD.lightened(0.15))
	title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	title.add_theme_constant_override("shadow_offset_x", 3)
	title.add_theme_constant_override("shadow_offset_y", 3)
	title.add_theme_constant_override("shadow_size", 10)
	title_box.add_child(title)

	var subtitle = Label.new()
	subtitle.text = "FINGER EMPIRE  ·  即时战略  ·  帝国纷争"
	UITheme.apply_label(subtitle, 24, UITheme.PARCHMENT)
	title_box.add_child(subtitle)

	var gold_line = ColorRect.new()
	gold_line.color = Color(UITheme.GOLD, 0.65)
	gold_line.custom_minimum_size = Vector2(560, 3)
	gold_line.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	title_box.add_child(gold_line)

	var header_right = VBoxContainer.new()
	header_right.name = "HeaderRight"
	header_right.custom_minimum_size = Vector2(560, 0)
	header_right.alignment = BoxContainer.ALIGNMENT_CENTER
	header_right.add_theme_constant_override("separation", 4)
	header.add_child(header_right)

	var tagline = Label.new()
	tagline.text = "选择文明 · 整军备战 · 扩张帝国"
	tagline.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	UITheme.apply_label(tagline, 19, Color(UITheme.PARCHMENT, 0.85))
	header_right.add_child(tagline)

	var version_top = Label.new()
	version_top.name = "VersionLabel"
	version_top.text = "%s  ·  Godot 4.7" % AppVersion.display()
	version_top.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	UITheme.apply_label(version_top, 18, Color(UITheme.STONE).lightened(0.25))
	header_right.add_child(version_top)

	# ---------- 中央主体：整屏行动卡片（单人配置已移入专属界面） ----------
	var body = HBoxContainer.new()
	body.name = "Body"
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 18)
	layout.add_child(body)

	# 左：2×2 主行动大卡片，占满主体大部分面积
	var primary_grid = GridContainer.new()
	primary_grid.name = "PrimaryGrid"
	primary_grid.columns = 2
	primary_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	primary_grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	primary_grid.size_flags_stretch_ratio = 1.48
	primary_grid.add_theme_constant_override("h_separation", 16)
	primary_grid.add_theme_constant_override("v_separation", 16)
	body.add_child(primary_grid)

	var primary_data = [
		["⚔️", "单人游戏", "进入专属界面配置文明、难度与地图", "primary", Callable(self, "_on_play_pressed")],
		["🌐", "联机对战", "ENet / WebSocket / Steam 房间", "primary", Callable(self, "_on_multiplayer_pressed")],
		["🏰", "战役闯关", "固定关卡 · 任务目标 · 星级挑战", "book", Callable(self, "_on_campaign_pressed")],
		["📖", "单位图鉴", "10 国兵种、建筑与科技资料", "book", Callable(self, "_on_units_pressed")],
	]
	for data in primary_data:
		var card = _make_tile_button(data[0], data[1], data[2], data[3], Vector2(0, 300))
		card.pressed.connect(data[4])
		primary_grid.add_child(card)
		if data[1] == "单人游戏":
			UITheme.pulse(card, 1.015, 1.2)
		else:
			UITheme.hover_scale(card)
		if data[1] == "战役闯关":
			card.tooltip_text = "闯关模式：固定地图与任务目标，完成后获得星级评价"

	# 右：竖向排列的辅助入口 + 底部设置/退出
	var side_area = VBoxContainer.new()
	side_area.name = "SideArea"
	side_area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	side_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side_area.size_flags_stretch_ratio = 0.82
	side_area.add_theme_constant_override("separation", 14)
	body.add_child(side_area)

	var secondary_data = [
		["📘", "操作指南", "鼠标键盘与进阶技巧", "book", Callable(self, "_on_guide_pressed")],
		["🎓", "新兵训练营", "26 关渐进教学 · 经典模式", "muted", Callable(self, "_on_tutorial_pressed")],
		["📜", "科技总览", "四时代科技树", "book", Callable(self, "_on_tech_overview_pressed")],
		["📜", "更新日志", "版本改动一览", "muted", Callable(self, "_on_changelog_pressed")],
	]
	for data in secondary_data:
		var card = _make_tile_button(data[0], data[1], data[2], data[3], Vector2(0, 170))
		card.pressed.connect(data[4])
		card.size_flags_vertical = Control.SIZE_EXPAND_FILL
		side_area.add_child(card)
		UITheme.hover_scale(card)
		if data[1] == "更新日志":
			_changelog_btn = card
			_attach_new_badge(card, UITheme.FONT_SM)

	var bottom_row = HBoxContainer.new()
	bottom_row.name = "BottomRow"
	bottom_row.custom_minimum_size = Vector2(0, 80)
	bottom_row.add_theme_constant_override("separation", 14)
	side_area.add_child(bottom_row)

	var settings_btn = _make_menu_button("⚙  设  置", Vector2.ZERO, "muted")
	settings_btn.custom_minimum_size = Vector2(0, 80)
	settings_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	settings_btn.size_flags_stretch_ratio = 1.2
	settings_btn.add_theme_font_size_override("font_size", 26)
	settings_btn.pressed.connect(_on_settings_pressed)
	settings_btn.tooltip_text = "音量、画质、相机与游戏设置"
	bottom_row.add_child(settings_btn)

	var quit_btn = _make_menu_button("🚪  退出游戏", Vector2.ZERO, "danger")
	quit_btn.custom_minimum_size = Vector2(0, 80)
	quit_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	quit_btn.add_theme_font_size_override("font_size", 26)
	quit_btn.pressed.connect(_on_quit_pressed)
	bottom_row.add_child(quit_btn)

	UITheme.hover_scale(settings_btn)
	UITheme.hover_scale(quit_btn)

	# ---------- 底部操作提示：铺满整行 ----------
	var bot_panel = PanelContainer.new()
	bot_panel.name = "TipsPanel"
	bot_panel.custom_minimum_size = Vector2(0, 142)
	bot_panel.add_theme_stylebox_override("panel", UITheme.card_style(UITheme.GOLD))
	layout.add_child(bot_panel)

	var tip_margin = MarginContainer.new()
	tip_margin.add_theme_constant_override("margin_left", 28)
	tip_margin.add_theme_constant_override("margin_right", 28)
	tip_margin.add_theme_constant_override("margin_top", 12)
	tip_margin.add_theme_constant_override("margin_bottom", 12)
	bot_panel.add_child(tip_margin)

	var tip_box = VBoxContainer.new()
	tip_box.add_theme_constant_override("separation", 4)
	tip_box.alignment = BoxContainer.ALIGNMENT_CENTER
	tip_margin.add_child(tip_box)
	_add_tip_line(tip_box, "🖱️ 左键选择/框选 · 右键空地打开建造菜单 · 中键拖拽平移 · Ctrl+中键旋转视角 · 滚轮缩放", 16, UITheme.PARCHMENT)
	_add_tip_line(tip_box, "⌨️ A+左键攻击 · M+左键纯移动 · Esc 取消 · Ctrl+1~9 编队 · F1 全选军队 · F2 自动进攻 · F3 撤退", 16, UITheme.PARCHMENT)
	_add_tip_line(tip_box, "✨ %s：点「📖 单位图鉴」「📘 操作指南」「📜 科技总览」可查看完整国家加成与四时代科技树" % AppVersion.version(), 15, Color(UITheme.GOLD, 0.95))
	UITheme.fade_in(bot_panel, 0.5)

# 小号说明标签
func _make_field_label(text: String, font_size: int = 18) -> Label:
	var lbl = Label.new()
	lbl.text = text
	UITheme.apply_label(lbl, font_size, Color(UITheme.PARCHMENT, 0.9))
	return lbl

# 方形/长方形行动卡片：图标 + 标题 + 说明，整张卡片都可点击。
func _make_tile_button(icon_text: String, title_text: String, sub_text: String, kind: String, min_size: Vector2) -> Button:
	var btn = _make_menu_button("", Vector2.ZERO, kind)
	btn.text = ""
	btn.custom_minimum_size = min_size
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.size_flags_vertical = Control.SIZE_EXPAND_FILL
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.tooltip_text = "%s：%s" % [title_text, sub_text]

	var content = MarginContainer.new()
	content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_theme_constant_override("margin_left", 18)
	content.add_theme_constant_override("margin_right", 18)
	content.add_theme_constant_override("margin_top", 10)
	content.add_theme_constant_override("margin_bottom", 10)
	btn.add_child(content)

	var vb = VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 2)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(vb)

	var primary := kind == "primary"
	var big_tile := min_size.y >= 200.0
	var icon_color := UITheme.GOLD_TEXT if primary else UITheme.GOLD
	var title_color := UITheme.GOLD_TEXT if primary else UITheme.PARCHMENT
	var sub_color := Color(UITheme.GOLD_TEXT, 0.78) if primary else Color(UITheme.PARCHMENT, 0.72)

	var icon = Label.new()
	icon.text = icon_text
	icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	icon.add_theme_font_size_override("font_size", 58 if big_tile else 42)
	icon.add_theme_color_override("font_color", icon_color)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(icon)

	var title = Label.new()
	title.text = title_text
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 34 if big_tile else 28)
	title.add_theme_color_override("font_color", title_color)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(title)

	var sub = Label.new()
	sub.text = sub_text
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sub.add_theme_font_size_override("font_size", 17 if big_tile else 15)
	sub.add_theme_color_override("font_color", sub_color)
	sub.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(sub)
	return btn

# 国家说明会随下拉选择实时更新，让配置区多一点有用信息。
func _on_nation_selected(idx: int) -> void:
	if _nation_detail == null or nation_select == null:
		return
	if idx < 0 or idx >= nation_select.item_count:
		return
	_nation_detail.text = "🏛 当前文明：%s\n加成会直接作用到开局单位与资源，联机中双方各自生效。" % nation_select.get_item_text(idx).strip_edges()

# 对局摘要：模式规则、当前地图、发展路线，避免左侧配置区出现大片空白。
func _on_mode_selected(idx: int) -> void:
	_last_mode_idx = clampi(idx, 0, 5)
	if _mode_detail == null:
		return
	var mode_names = ["1V1 单挑", "2V2 团队", "3V3 团队", "乱斗 · 3 国", "乱斗 · 4 国", "乱斗 · 5 国"]
	var mode_desc = ""
	match _last_mode_idx:
		0:
			mode_desc = "单路对决，摧毁敌方主城即可获胜。"
		1, 2:
			mode_desc = "与队友协同作战，共享视野；任意队友主城仍在即可继续。"
		_:
			mode_desc = "多国混战，可结盟、纳贡或背叛；最后存活的国家获胜。"
	var map_name := String(MapPresets.get_info(GameSettings.map_id)["name"])
	var progression := "科研（四时代科技树）" if GameSettings.is_research_mode() else "经典（升级解锁）"
	_mode_detail.text = "模式：%s\n%s\n地图：%s\n发展：%s" % [mode_names[_last_mode_idx], mode_desc, map_name, progression]

func _on_research_toggled(on: bool) -> void:
	GameSettings.progression_mode = GameSettings.ProgressionMode.RESEARCH if on else GameSettings.ProgressionMode.CLASSIC
	_on_mode_selected(_last_mode_idx)

## 主题化 OptionButton（含弹出列表）
func _style_option(o: OptionButton, font_size: int) -> void:
	o.add_theme_font_size_override("font_size", font_size)
	o.add_theme_color_override("font_color", UITheme.PARCHMENT)
	o.add_theme_color_override("font_hover_color", UITheme.GOLD)
	var pop = o.get_popup()
	pop.add_theme_font_size_override("font_size", font_size)
	pop.add_theme_color_override("font_color", UITheme.PARCHMENT)
	pop.add_theme_color_override("font_hover_color", UITheme.GOLD)

## 菜单按钮（金主 / 蓝书图鉴 / 石次 / 朱红危险）
func _make_menu_button(text: String, pos: Vector2, kind: String) -> Button:
	var btn = Button.new()
	btn.text = text
	btn.position = pos
	btn.size = Vector2(600, 58)
	match kind:
		"primary": UITheme.apply_primary_button(btn, UITheme.FONT_XXL)
		"danger": UITheme.apply_danger_button(btn, UITheme.FONT_XXL)
		"book":
			# 图鉴专用「宝石蓝」书页风格，与金色 CTA 区分
			var sb = StyleBoxFlat.new()
			sb.bg_color = Color(UITheme.SAPPHIRE, 0.16)
			sb.border_color = Color(UITheme.SAPPHIRE, 0.95)
			sb.set_corner_radius_all(10)
			sb.set_border_width_all(2)
			sb.set_content_margin_all(6)
			btn.add_theme_stylebox_override("normal", sb)
			var hover = sb.duplicate()
			hover.bg_color = Color(UITheme.SAPPHIRE, 0.30)
			btn.add_theme_stylebox_override("hover", hover)
			var pressed = hover.duplicate()
			pressed.bg_color = Color(UITheme.SAPPHIRE, 0.44)
			btn.add_theme_stylebox_override("pressed", pressed)
			var focus = StyleBoxEmpty.new()
			btn.add_theme_stylebox_override("focus", focus)
			btn.add_theme_font_size_override("font_size", UITheme.FONT_XXL)
			btn.add_theme_color_override("font_color", UITheme.PARCHMENT)
			btn.add_theme_color_override("font_hover_color", Color(UITheme.GOLD, 1.0))
			btn.add_theme_color_override("font_pressed_color", UITheme.GOLD.lightened(0.2))
		_: UITheme.apply_muted_button(btn, UITheme.FONT_XXL)
	return btn

## 命令模式分段切换样式
func _set_cmd_toggle(btn: Button, on: bool) -> void:
	if on:
		UITheme.apply_primary_button(btn, UITheme.FONT_SM)
	else:
		UITheme.apply_muted_button(btn, UITheme.FONT_SM)

## 地图选择对所有模式开放；乱斗同样可以选特殊地形，只是城堡布局仍按环形展开
func _update_map_availability(_mode_idx: int) -> void:
	if not _map_button:
		return
	_map_button.disabled = false
	_refresh_map_button()

func _refresh_map_button() -> void:
	if not _map_button:
		return
	var info := MapPresets.get_info(GameSettings.map_id)
	var suffix := ""
	if String(info["battle"]) != "":
		suffix = " · " + String(info["battle"])
	_map_button.text = "  %s%s ▸" % [String(info["name"]), suffix]

# ---------- 战场地形卡片选择器 ----------
func _open_map_dialog() -> void:
	if _map_button and _map_button.disabled:
		return
	var existing = get_node_or_null("MapDialog")
	if existing:
		existing.queue_free()
		return
	var dlg = MapSelectDialog.new()
	dlg.name = "MapDialog"
	dlg.map_selected.connect(_select_map)
	add_child(dlg)

func _select_map(id: String) -> void:
	GameSettings.map_id = id
	_refresh_map_button()
	_on_mode_selected(_last_mode_idx)

# 桌面版控件直接挂在根节点下，手机版嵌在滚动容器里；
# 统一递归查找，否则手机端读不到 ModeSelect/DiffSelect，模式永远落到 1V1。
func _find_ui(node_name: String) -> Node:
	var n = find_child(node_name, true, false)
	if n:
		return n
	return get_node_or_null(node_name)

func _on_play_pressed():
	# 单机配置改到专属界面，主菜单只负责入口。
	get_tree().change_scene_to_file("res://scenes/single_player_menu.tscn")

func _on_multiplayer_pressed():
	GameSettings.tutorial_mode = false
	GameSettings.campaign_mode = false
	GameSettings.campaign_level_id = ""
	GameSettings.ai_mode = 1   # 联机模式不使用单机模式
	GameSettings.is_ffa = false
	GameSettings.map_id = "classic"   # 联机选图在联机大厅里选
	GameSettings.fast_mode = false
	get_tree().change_scene_to_file("res://scenes/online_menu.tscn")

func _on_units_pressed():
	# 打开单位图鉴页面
	get_tree().change_scene_to_file("res://scenes/unit_view.tscn")

# 科技总览：主菜单只读查看完整科研路线，开关式弹层。
func _on_tech_overview_pressed() -> void:
	var existing := get_node_or_null("TechOverviewPanel")
	if existing != null:
		existing.queue_free()
		return
	var panel := TechOverviewPanel.new()
	panel.name = "TechOverviewPanel"
	add_child(panel)

# 操作指南：完整按键 / 经济 / 战斗说明，可滚动阅读
func _on_guide_pressed() -> void:
	GuidePanel.open(self, GuidePanel.Mode.GUIDE)

# 新兵训练营：打开独立选关界面（基础 15 关 + 进阶 9 关 + 2 关演习）
func _on_tutorial_pressed() -> void:
	GameSettings.training_prev_progression = GameSettings.progression_mode
	GameSettings.tutorial_mode = false
	GameSettings.training_mode = false
	GameSettings.training_level_id = ""
	GameSettings.campaign_mode = false
	get_tree().change_scene_to_file("res://scenes/training_menu.tscn")

func _start_tutorial_battle() -> void:
	var player_nation: int = GameSettings.player_nation
	if player_nation < 0 or player_nation >= RTSConfig.Nation.size():
		player_nation = RTSConfig.Nation.VIKING
	GameSettings.tutorial_mode = true
	GameSettings.campaign_mode = false
	GameSettings.campaign_level_id = ""
	GameSettings.player_nation = player_nation
	GameSettings.enemy_nation = (player_nation + 1) % RTSConfig.Nation.size()
	GameSettings.ai_difficulty = GameSettings.AIDifficulty.EASY
	GameSettings.ai_mode = 1
	GameSettings.is_ffa = false
	GameSettings.fast_mode = true
	GameSettings.progression_mode = GameSettings.ProgressionMode.CLASSIC
	GameSettings.map_id = "classic"
	GameSettings.map_seed = 0
	get_tree().change_scene_to_file("res://scenes/rts_battle.tscn")

# 闯关模式：打开选关界面（关卡数据在 scripts/data/CampaignData.gd）
func _on_campaign_pressed() -> void:
	GameSettings.tutorial_mode = false
	GameSettings.campaign_mode = true
	GameSettings.campaign_level_id = ""
	# 发展模式沿用单人配置界面/上次选择；选关界面里还可以再切换。
	get_tree().change_scene_to_file("res://scenes/campaign_menu.tscn")

# 打开更新日志面板（已打开则关掉，形成"按钮开关"）
func _on_changelog_pressed() -> void:
	var existing := get_node_or_null("ChangelogPanel")
	if existing != null:
		existing.queue_free()
		return
	ChangelogPanel.open(self)
	# 看过了就把 NEW 标记清掉
	if _changelog_btn != null and is_instance_valid(_changelog_btn):
		var badge := _changelog_btn.get_node_or_null("NewBadge")
		if badge != null:
			badge.queue_free()

# 入口按钮上的「NEW」小徽章：有新版本日志没看过时才加
func _attach_new_badge(btn: Button, font_size: int) -> void:
	if not ChangelogData.is_unseen():
		return
	var badge := Label.new()
	badge.name = "NewBadge"
	badge.text = "NEW"
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	badge.add_theme_font_size_override("font_size", font_size)
	badge.add_theme_color_override("font_color", UITheme.GOLD_TEXT)
	var sb := StyleBoxFlat.new()
	sb.bg_color = UITheme.GOLD
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(2)
	badge.add_theme_stylebox_override("normal", sb)
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	badge.offset_left = -66
	badge.offset_right = -10
	badge.offset_top = 10
	badge.offset_bottom = 34
	btn.add_child(badge)

# 手机版入口按钮整行宽：NEW 徽章用右上角锚点，窗口/字号变化都不会错位
func _attach_new_badge_mobile(btn: Button) -> void:
	if not ChangelogData.is_unseen():
		return
	var badge := Label.new()
	badge.name = "NewBadge"
	badge.text = "NEW"
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	badge.add_theme_font_size_override("font_size", UILayout.font_dp(8.5))
	badge.add_theme_color_override("font_color", UITheme.GOLD_TEXT)
	var sb := StyleBoxFlat.new()
	sb.bg_color = UITheme.GOLD
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(2)
	badge.add_theme_stylebox_override("normal", sb)
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	badge.offset_left = -UILayout.dp(46.0)
	badge.offset_right = -UILayout.dp(6.0)
	badge.offset_top = UILayout.dp(3.0)
	badge.offset_bottom = UILayout.dp(19.0)
	btn.add_child(badge)

# 底部说明行：居中、自动换行，字体/颜色跟随主题
func _add_tip_line(box: VBoxContainer, text: String, font_size: int, color: Color) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.apply_label(lbl, font_size, color)
	box.add_child(lbl)

# ==================== 更新检查 ====================
# 主菜单启动后拉一次版本清单：有新版就在底部（手机在列表最上面）弹出下载按钮。
func _setup_update_check() -> void:
	if not UpdateConfig.ENABLED:
		return
	_update_checker = UpdateChecker.new()
	_update_checker.name = "UpdateChecker"
	add_child(_update_checker)
	_update_checker.finished.connect(_on_update_checked)
	_update_checker.check(false)

func _on_update_checked(ok: bool, has_update: bool, remote_version: String, download_url: String, notes: String) -> void:
	if not ok or not has_update or download_url == "":
		return
	_show_update_banner(remote_version, download_url, notes)

# 有新版本：底部一个金色下载按钮（桌面绝对定位 / 手机插到滚动列表最上面）
func _show_update_banner(remote_version: String, download_url: String, notes: String) -> void:
	if _update_banner != null and is_instance_valid(_update_banner):
		return
	var btn := Button.new()
	btn.name = "UpdateBanner"
	var action := "点此刷新" if OS.has_feature("web") else "点此下载"
	btn.text = "🆕 发现新版本 %s · %s" % [remote_version, action]
	btn.tooltip_text = notes
	btn.pressed.connect(_open_download.bind(download_url))
	if InputSource.use_mobile_ui():
		btn.custom_minimum_size = Vector2(0, UILayout.dp(42.0))
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_mobile_style_button(btn, "primary", UILayout.font_dp(12.0))
		if _mobile_vb != null and is_instance_valid(_mobile_vb):
			_mobile_vb.add_child(btn)
			_mobile_vb.move_child(btn, 0)
		else:
			add_child(btn)
	else:
		# 桌面/网页：更新提示塞进右上角标题栏，不再盖住底部提示面板。
		var head_slot = get_node_or_null("DesktopFrame/DesktopLayout/Header/HeaderRight")
		if head_slot != null:
			btn.custom_minimum_size = Vector2(0, 44)
			btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			UITheme.apply_primary_button(btn, 16)
			head_slot.add_child(btn)
		else:
			btn.position = Vector2(900, 1288)
			btn.size = Vector2(600, 46)
			UITheme.apply_primary_button(btn, UITheme.FONT_MD + 2)
			add_child(btn)
		UITheme.pulse(btn, 1.02, 1.1)
	_update_banner = btn

# 用系统浏览器/商店打开下载页；Web 版直接跳到新地址，避免停留在旧页面。
func _open_download(url: String) -> void:
	if OS.has_feature("web"):
		var js = Engine.get_singleton("JavaScriptBridge")
		if js != null:
			var target := url.strip_edges()
			if target == "":
				js.eval("window.location.reload();")
			else:
				js.eval("window.location.href = %s;" % JSON.stringify(target))
			return
	if url.strip_edges() == "":
		return
	OS.shell_open(url)

func _on_settings_pressed():
	# Toggle settings panel
	var existing = get_node_or_null("SettingsPanel")
	if existing:
		existing.visible = !existing.visible
		return
	if InputSource.use_mobile_ui():
		_create_settings_panel_mobile()
	else:
		_create_settings_panel()

func _create_settings_panel():
	var panel = Panel.new()
	panel.name = "SettingsPanel"
	panel.position = Vector2(750, 400)
	panel.size = Vector2(900, 420)
	panel.add_theme_stylebox_override("panel", UITheme.card_style(UITheme.GOLD))
	add_child(panel)
	UITheme.fade_in(panel, 0.3)

	# Title
	var ttl = UITheme.make_section_title("⚙️ 音量设置", UITheme.GOLD, 30)
	ttl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ttl.position = Vector2(0, 15)
	ttl.size = Vector2(900, 40)
	panel.add_child(ttl)

	# Close button
	var close = Button.new()
	close.text = "✕"
	close.position = Vector2(840, 10)
	close.size = Vector2(50, 50)
	UITheme.apply_muted_button(close, UITheme.FONT_SM)
	close.pressed.connect(func(): panel.visible = false)
	panel.add_child(close)

	# Music volume
	var ml = Label.new()
	ml.text = "音乐音量"
	ml.position = Vector2(50, 90)
	ml.size = Vector2(200, 30)
	UITheme.apply_label(ml, 22, UITheme.PARCHMENT)
	panel.add_child(ml)

	var mv = HSlider.new()
	mv.name = "MusicSlider"
	mv.position = Vector2(280, 92)
	mv.size = Vector2(500, 30)
	mv.min_value = 0; mv.max_value = 100
	mv.value = AudioManager._music_volume * 100
	mv.value_changed.connect(func(v: float): AudioManager.set_music_volume(v / 100.0))
	panel.add_child(mv)

	var mvl = Label.new()
	mvl.name = "MusicValue"
	mvl.text = "%d%%" % int(mv.value)
	mvl.position = Vector2(790, 90)
	mvl.size = Vector2(80, 30)
	UITheme.apply_label(mvl, 20, UITheme.RES_GOLD)
	panel.add_child(mvl)
	mv.value_changed.connect(func(v: float): mvl.text = "%d%%" % int(v))

	# SFX volume
	var sl = Label.new()
	sl.text = "音效音量"
	sl.position = Vector2(50, 160)
	sl.size = Vector2(200, 30)
	UITheme.apply_label(sl, 22, UITheme.PARCHMENT)
	panel.add_child(sl)

	var sv = HSlider.new()
	sv.name = "SFXSlider"
	sv.position = Vector2(280, 162)
	sv.size = Vector2(500, 30)
	sv.min_value = 0; sv.max_value = 100
	sv.value = AudioManager._sfx_volume * 100
	sv.value_changed.connect(func(v: float): AudioManager.set_sfx_volume(v / 100.0))
	panel.add_child(sv)

	var svl = Label.new()
	svl.name = "SFXValue"
	svl.text = "%d%%" % int(sv.value)
	svl.position = Vector2(790, 160)
	svl.size = Vector2(80, 30)
	UITheme.apply_label(svl, 20, UITheme.RES_GOLD)
	panel.add_child(svl)
	sv.value_changed.connect(func(v: float): svl.text = "%d%%" % int(v))

	# Test SFX button
	var test = Button.new()
	test.text = "测试音效"
	test.position = Vector2(280, 230)
	test.size = Vector2(180, 45)
	UITheme.apply_muted_button(test, UITheme.FONT_SM)
	test.pressed.connect(func(): AudioManager.play_sfx("ui_click"))
	panel.add_child(test)

	# --- 命令模式 ---
	var cmd_label = Label.new()
	cmd_label.text = "命令模式"
	cmd_label.position = Vector2(50, 292)
	cmd_label.size = Vector2(200, 30)
	UITheme.apply_label(cmd_label, 22, UITheme.PARCHMENT)
	panel.add_child(cmd_label)

	var cmd_single = Button.new()
	cmd_single.text = "单次命令"
	cmd_single.position = Vector2(280, 292)
	cmd_single.size = Vector2(140, 40)

	var cmd_cont = Button.new()
	cmd_cont.text = "连续命令"
	cmd_cont.position = Vector2(430, 292)
	cmd_cont.size = Vector2(140, 40)

	_set_cmd_toggle(cmd_single, GameSettings.command_mode == 0)
	_set_cmd_toggle(cmd_cont, GameSettings.command_mode == 1)
	cmd_single.pressed.connect(func():
		GameSettings.command_mode = 0
		_set_cmd_toggle(cmd_single, true)
		_set_cmd_toggle(cmd_cont, false)
	)
	cmd_cont.pressed.connect(func():
		GameSettings.command_mode = 1
		_set_cmd_toggle(cmd_single, false)
		_set_cmd_toggle(cmd_cont, true)
	)
	panel.add_child(cmd_single)
	panel.add_child(cmd_cont)

	# Hint
	var hint = Label.new()
	hint.text = "音效距离衰减：50米内可听到 | 单次命令：下令后取消选择"
	hint.position = Vector2(50, 356)
	hint.size = Vector2(800, 25)
	UITheme.apply_label(hint, 16, Color(UITheme.STONE).lightened(0.25))
	panel.add_child(hint)

func _on_quit_pressed():
	get_tree().quit()

# ==================== 手机端布局 ====================
# 桌面版是 2400×1400 绝对定位；手机屏只有 674×393dp，字号与按钮必须按 dp 重排。
# 结构：标题 + 可滚动竖排配置区（国家/AI 难度/模式/地图/快速模式/按钮）。

func _build_mobile_layout() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.10, 0.08, 0.06)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var top_bar := ColorRect.new()
	top_bar.color = Color(UITheme.GOLD)
	top_bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	top_bar.offset_bottom = UILayout.dp(2.0)
	add_child(top_bar)

	var title := Label.new()
	title.text = "👑 FINGER EMPIRE 👑"
	title.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	title.offset_top = UILayout.dp(6.0)
	title.offset_bottom = UILayout.dp(28.0)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", UILayout.font_dp(15.0))
	title.add_theme_color_override("font_color", UITheme.GOLD.lightened(0.15))
	title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	title.add_theme_constant_override("shadow_offset_x", 3)
	title.add_theme_constant_override("shadow_offset_y", 3)
	add_child(title)

	var subtitle := Label.new()
	subtitle.text = "即时战略 · 帝国纷争"
	subtitle.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	subtitle.offset_top = UILayout.dp(28.0)
	subtitle.offset_bottom = UILayout.dp(41.0)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(subtitle, UILayout.font_dp(9.0), UITheme.PARCHMENT)
	add_child(subtitle)

	# 滚动区：配置区内容超过一屏时上下滑动
	var scroll := ScrollContainer.new()
	scroll.name = "MobileScroll"
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.offset_top = UILayout.dp(44.0)
	scroll.offset_left = UILayout.dp(10.0)
	scroll.offset_right = -UILayout.dp(10.0)
	scroll.offset_bottom = -UILayout.dp(6.0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	# 触摸拖动由 MainMenu._input 驱动；容器自身忽略鼠标事件，避免它把 scroll 值又算回 0
	scroll.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(scroll)

	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", int(UILayout.dp(6.0)))
	scroll.add_child(vb)

	# 主菜单不再放配置表单：单人配置进入专属界面，这里用 2 列行动卡片铺满
	vb.add_child(_mobile_section("⚔️ 开始你的帝国 ⚔️", UITheme.GOLD))

	var action_grid := GridContainer.new()
	action_grid.columns = 2
	action_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	action_grid.add_theme_constant_override("h_separation", int(UILayout.dp(6.0)))
	action_grid.add_theme_constant_override("v_separation", int(UILayout.dp(6.0)))
	vb.add_child(action_grid)

	var btn_data := [
		["⚔️", "单人游戏", _on_play_pressed, "primary"],
		["🌐", "联机对战", _on_multiplayer_pressed, "primary"],
		["🏰", "战役闯关", _on_campaign_pressed, "primary"],
		["📖", "单位图鉴", _on_units_pressed, "book"],
		["📜", "科技总览", _on_tech_overview_pressed, "book"],
		["📘", "操作指南", _on_guide_pressed, "book"],
		["🎓", "新兵训练", _on_tutorial_pressed, "muted"],
		["⚙️", "设  置", _on_settings_pressed, "muted"],
		["📜", "更新日志", _on_changelog_pressed, "muted"],
		["🚪", "退出游戏", _on_quit_pressed, "danger"],
	]
	for data in btn_data:
		var btn := Button.new()
		btn.text = "%s\n%s" % [data[0], data[1]]
		btn.custom_minimum_size = Vector2(0, UILayout.dp(60.0))
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_mobile_style_button(btn, data[3], UILayout.font_dp(11.0))
		btn.pressed.connect(data[2])
		action_grid.add_child(btn)
		if String(data[1]) == "更新日志":
			_changelog_btn = btn
			_attach_new_badge_mobile(btn)

	var action_hint := Label.new()
	action_hint.text = "单人游戏会进入专属配置界面：文明 / 难度 / 模式 / 地图"
	action_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	action_hint.add_theme_font_size_override("font_size", UILayout.font_dp(8.0))
	action_hint.add_theme_color_override("font_color", Color(UITheme.PARCHMENT, 0.7))
	vb.add_child(action_hint)

	var tip := Label.new()
	tip.text = "手机操作：点按选择·指挥 / 拖动平移 / 双指缩放 / ↻ 按住旋转视角 / 长按空地建造 / 右上角小地图切换统计"
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tip.add_theme_font_size_override("font_size", UILayout.font_dp(8.0))
	tip.add_theme_color_override("font_color", Color(UITheme.STONE).lightened(0.25))
	vb.add_child(tip)

	# 本版贴士（和桌面版一致，提示这版新增可调项与更新日志入口）
	var tip_ver := Label.new()
	tip_ver.text = "本版 %s：设置里可调相机倍数 · 主菜单「📜 更新日志」看全部改动" % AppVersion.version()
	tip_ver.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tip_ver.add_theme_font_size_override("font_size", UILayout.font_dp(8.0))
	tip_ver.add_theme_color_override("font_color", Color(UITheme.GOLD, 0.8))
	vb.add_child(tip_ver)

	vb.add_child(_mobile_section("%s - Godot 4.7" % AppVersion.display(), Color(UITheme.STONE).lightened(0.2)))
	_mobile_vb = vb

func _mobile_section(text: String, color: Color) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", UILayout.font_dp(11.0))
	lbl.add_theme_color_override("font_color", color)
	return lbl

# 菜单按钮样式（primary / danger / book / muted），字号由调用方按 dp 传入
func _mobile_style_button(btn: Button, kind: String, font_size: int) -> void:
	match kind:
		"primary":
			UITheme.apply_primary_button(btn, font_size)
		"danger":
			UITheme.apply_danger_button(btn, font_size)
		"book":
			var sb := StyleBoxFlat.new()
			sb.bg_color = Color(UITheme.SAPPHIRE, 0.16)
			sb.border_color = Color(UITheme.SAPPHIRE, 0.95)
			sb.set_corner_radius_all(10)
			sb.set_border_width_all(2)
			sb.set_content_margin_all(6)
			btn.add_theme_stylebox_override("normal", sb)
			var hover := sb.duplicate()
			hover.bg_color = Color(UITheme.SAPPHIRE, 0.30)
			btn.add_theme_stylebox_override("hover", hover)
			var pressed := hover.duplicate()
			pressed.bg_color = Color(UITheme.SAPPHIRE, 0.44)
			btn.add_theme_stylebox_override("pressed", pressed)
			btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
			btn.add_theme_font_size_override("font_size", font_size)
			btn.add_theme_color_override("font_color", UITheme.PARCHMENT)
			btn.add_theme_color_override("font_hover_color", Color(UITheme.GOLD, 1.0))
			btn.add_theme_color_override("font_pressed_color", UITheme.GOLD.lightened(0.2))
		_:
			UITheme.apply_muted_button(btn, font_size)

# 手机端设置面板：全屏滚动卡片，控件按 dp 放大
func _create_settings_panel_mobile() -> void:
	var panel := Panel.new()
	panel.name = "SettingsPanel"
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.offset_left = UILayout.dp(6.0)
	panel.offset_right = -UILayout.dp(6.0)
	panel.offset_top = UILayout.dp(8.0)
	panel.offset_bottom = -UILayout.dp(8.0)
	panel.add_theme_stylebox_override("panel", UITheme.card_style(UITheme.GOLD))
	panel.z_index = 50
	add_child(panel)
	UITheme.fade_in(panel, 0.3)

	var scroll := ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.offset_left = UILayout.dp(8.0)
	scroll.offset_right = -UILayout.dp(8.0)
	scroll.offset_top = UILayout.dp(8.0)
	scroll.offset_bottom = -UILayout.dp(8.0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(scroll)

	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", int(UILayout.dp(6.0)))
	scroll.add_child(vb)

	var ttl := UITheme.make_section_title("⚙️ 音量设置", UITheme.GOLD, UILayout.font_dp(12.0))
	ttl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(ttl)

	vb.add_child(_mobile_volume_row("音乐音量", AudioManager._music_volume,
		func(v: float): AudioManager.set_music_volume(v), "MusicSlider"))
	vb.add_child(_mobile_volume_row("音效音量", AudioManager._sfx_volume,
		func(v: float): AudioManager.set_sfx_volume(v), "SFXSlider"))

	var test := Button.new()
	test.text = "🔊 测试音效"
	test.custom_minimum_size = Vector2(0, UILayout.dp(36.0))
	UITheme.apply_muted_button(test, UILayout.font_dp(11.0))
	test.pressed.connect(func(): AudioManager.play_sfx("ui_click"))
	vb.add_child(test)

	vb.add_child(_mobile_section("命令模式", UITheme.PARCHMENT))

	var cmd_row := HBoxContainer.new()
	cmd_row.add_theme_constant_override("separation", int(UILayout.dp(6.0)))
	vb.add_child(cmd_row)
	var cmd_single := Button.new()
	cmd_single.text = "单次命令"
	cmd_single.custom_minimum_size = Vector2(0, UILayout.dp(36.0))
	cmd_single.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var cmd_cont := Button.new()
	cmd_cont.text = "连续命令"
	cmd_cont.custom_minimum_size = Vector2(0, UILayout.dp(36.0))
	cmd_cont.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_set_cmd_toggle(cmd_single, GameSettings.command_mode == 0)
	_set_cmd_toggle(cmd_cont, GameSettings.command_mode == 1)
	cmd_single.add_theme_font_size_override("font_size", UILayout.font_dp(11.0))
	cmd_cont.add_theme_font_size_override("font_size", UILayout.font_dp(11.0))
	cmd_single.pressed.connect(func():
		GameSettings.command_mode = 0
		_set_cmd_toggle(cmd_single, true)
		_set_cmd_toggle(cmd_cont, false)
	)
	cmd_cont.pressed.connect(func():
		GameSettings.command_mode = 1
		_set_cmd_toggle(cmd_single, false)
		_set_cmd_toggle(cmd_cont, true)
	)
	cmd_row.add_child(cmd_single)
	cmd_row.add_child(cmd_cont)

	var hint := Label.new()
	hint.text = "音效距离衰减：50米内可听到 | 单次命令：下令后取消选择"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", UILayout.font_dp(8.0))
	hint.add_theme_color_override("font_color", Color(UITheme.STONE).lightened(0.25))
	vb.add_child(hint)

	var close := Button.new()
	close.text = "关闭"
	close.custom_minimum_size = Vector2(0, UILayout.dp(40.0))
	UITheme.apply_danger_button(close, UILayout.font_dp(12.0))
	close.pressed.connect(func(): panel.visible = false)
	vb.add_child(close)

# 手机端音量行：标签 + 滑块 + 百分比
func _mobile_volume_row(label_text: String, value: float, setter: Callable, slider_name: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", int(UILayout.dp(4.0)))
	var lbl := Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size = Vector2(UILayout.dp(62.0), 0)
	lbl.add_theme_font_size_override("font_size", UILayout.font_dp(10.0))
	lbl.add_theme_color_override("font_color", UITheme.PARCHMENT)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(lbl)

	var slider := HSlider.new()
	slider.name = slider_name
	slider.custom_minimum_size = Vector2(0, UILayout.dp(28.0))
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.min_value = 0
	slider.max_value = 100
	slider.value = value * 100.0
	row.add_child(slider)

	var val := Label.new()
	val.text = "%d%%" % int(slider.value)
	val.custom_minimum_size = Vector2(UILayout.dp(34.0), 0)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val.add_theme_font_size_override("font_size", UILayout.font_dp(10.0))
	val.add_theme_color_override("font_color", UITheme.RES_GOLD)
	val.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(val)

	slider.value_changed.connect(func(v: float):
		val.text = "%d%%" % int(v)
		setter.call(v / 100.0)
	)
	return row

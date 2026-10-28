extends Control

const MapPresets = preload("res://scripts/map/MapPresets.gd")
const MapSelectDialog = preload("res://scripts/ui/MapSelectDialog.gd")

var nation_select: OptionButton
var red_ai_spin: SpinBox
var blue_ai_spin: SpinBox
var mode_1v1_btn: Button
var mode_2v2_btn: Button
var mode_3v3_btn: Button
var status_label: Label
var ip_input: LineEdit
var enet_toggle_btn: Button
var ws_toggle_btn: Button
var host_btn: Button
var ip_label: Label
var map_btn: Button
var _last_map_id: String = "classic"
var _map_allowed: bool = true
# 网页房：PC 主机自动开 Cloudflare 隧道，生成可分享的 wss 链接
var _web_room_dialog: AcceptDialog = null
var _web_room_share_url: String = ""
var _web_room_wss_url: String = ""
var _web_auto_join_started: bool = false

# 手机端全屏滚动表单：触摸拖动直接驱动 ScrollContainer（没有战斗触摸路由器）。
func _input(event: InputEvent) -> void:
	if not InputSource.use_mobile_ui():
		return
	if event is InputEventScreenDrag:
		UILayout.scroll_at(self, event.position, event.relative.y)

func _ready():
	# 触屏滑动误点守卫：房间/地图列表滑动后不误触按钮
	add_child(TouchDragGuard.new())
	NetworkManager.connection_success.connect(_on_connected)
	NetworkManager.connection_failed.connect(_on_failed)

	NetworkManager.upnp_ready.connect(_on_upnp_ready)
	NetworkManager.upnp_failed.connect(_on_upnp_failed)
	SteamManager.steam_ready.connect(_on_steam_ready)
	SteamManager.steam_init_failed.connect(_on_steam_failed)
	SteamManager.lobby_created.connect(_on_steam_lobby_created)
	SteamManager.lobby_joined.connect(_on_steam_lobby_joined)
	SteamManager.lobby_join_failed.connect(_on_steam_lobby_join_failed)
	SteamManager.lobby_list_received.connect(_on_steam_lobby_list)
	SteamManager.lobby_member_joined.connect(_on_steam_member_joined)
	SteamManager.lobby_member_left.connect(_on_steam_member_left)
	SteamManager.game_starting.connect(_on_steam_game_starting)
	WebTunnel.tunnel_ready.connect(_on_web_tunnel_ready)
	WebTunnel.tunnel_failed.connect(_on_web_tunnel_failed)
	# Hide old scene nodes
	var old = get_node_or_null("Panel")
	if old: old.visible = false

	# 场景根节点在 online_menu.tscn 里没有设尺寸（默认 0×0）。
	# 桌面版按 2400×1400 设计画布缩放；手机端用锚点铺满，避免根节点 0×0 压成空白。
	var vs = get_viewport().get_visible_rect().size
	var s = min(vs.x / 2400.0, vs.y / 1400.0)
	scale = Vector2(s, s)
	position = (vs - Vector2(2400, 1400) * s) / 2.0

	# 手机端：桌面版 2400×1400 绝对布局在 393dp 屏上只有 4~14dp 字，
	# 直接改用竖排滚动布局；桌面路径完全不动。
	if InputSource.use_mobile_ui():
		scale = Vector2.ONE
		position = Vector2.ZERO
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		size = UILayout.view_size()
		# 横竖屏切换后重建表单，避免按钮/字号仍按旧方向计算。
		add_child(OrientationReload.new())
		_build_mobile_ui()
		_apply_web_defaults()
		return

	# 桌面/网页：按实际画布铺满，不再把表单缩在中间 1300×700 的面板里。
	var design_size = Vector2(ceil(vs.x / s), maxf(1400.0, ceil(vs.y / s)))
	size = design_size
	position = Vector2.ZERO
	_build_desktop_ui()
	_apply_web_defaults()

func _build_desktop_ui() -> void:
	# 全屏暖黑背景（羊皮纸皇庭底色）
	var bg = ColorRect.new(); bg.color = Color(0.10, 0.08, 0.06)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg); move_child(bg, 0)

	# 顶部皇庭金饰横条
	var bar = ColorRect.new(); bar.color = Color(UITheme.GOLD)
	bar.size = Vector2(size.x, 6)
	add_child(bar)
	var bar2 = ColorRect.new(); bar2.color = Color(UITheme.GOLD, 0.35)
	bar2.position = Vector2(0, 6); bar2.size = Vector2(size.x, 3)
	add_child(bar2)

	var frame = MarginContainer.new()
	frame.name = "DesktopFrame"
	frame.size = size
	frame.add_theme_constant_override("margin_left", 28)
	frame.add_theme_constant_override("margin_right", 28)
	frame.add_theme_constant_override("margin_top", 20)
	frame.add_theme_constant_override("margin_bottom", 20)
	add_child(frame)

	var layout = VBoxContainer.new()
	layout.add_theme_constant_override("separation", 12)
	frame.add_child(layout)

	# ---------- 顶部标题栏 ----------
	var header = HBoxContainer.new()
	header.custom_minimum_size = Vector2(0, 132)
	header.add_theme_constant_override("separation", 18)
	layout.add_child(header)

	var ret_btn = _make_btn("← 返回主菜单", Color(0.25, 0.25, 0.35), Vector2.ZERO, Vector2(250, 64), "muted")
	ret_btn.name = "BackButton"
	ret_btn.custom_minimum_size = Vector2(250, 64)
	ret_btn.pressed.connect(_on_return_pressed)
	header.add_child(ret_btn)

	var title_box = VBoxContainer.new()
	title_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_box.alignment = BoxContainer.ALIGNMENT_CENTER
	title_box.add_theme_constant_override("separation", 2)
	header.add_child(title_box)

	var title = Label.new()
	title.text = "👑 联机对战"
	title.add_theme_font_size_override("font_size", 62)
	title.add_theme_color_override("font_color", UITheme.GOLD.lightened(0.15))
	title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	title.add_theme_constant_override("shadow_offset_x", 3)
	title.add_theme_constant_override("shadow_offset_y", 3)
	title.add_theme_constant_override("shadow_size", 10)
	title_box.add_child(title)

	var subtitle = Label.new()
	subtitle.text = "创建主机、加入局域网，或通过 Steam / WebSocket 跨平台联机"
	UITheme.apply_label(subtitle, 23, UITheme.PARCHMENT)
	title_box.add_child(subtitle)

	var header_tip = Label.new()
	header_tip.text = "ENet · WebSocket · Steam\n主机保持运行，等待玩家加入"
	header_tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	header_tip.custom_minimum_size = Vector2(500, 0)
	UITheme.apply_label(header_tip, 17, Color(UITheme.STONE).lightened(0.3))
	header.add_child(header_tip)

	# ---------- 三栏主体 ----------
	var body = HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 16)
	layout.add_child(body)

	# 左栏：对局设置
	var col1 = _online_panel()
	col1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col1.size_flags_stretch_ratio = 0.94
	body.add_child(col1)
	var c1 = _online_panel_body(col1)
	c1.add_child(UITheme.make_section_title("⚔ 对局设置", UITheme.GOLD, 30))
	c1.add_child(_online_label("游戏模式", 18))
	var mode_row = HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", 8)
	c1.add_child(mode_row)
	mode_1v1_btn = _make_btn("1V1", Color(0.15, 0.4, 0.15), Vector2.ZERO, Vector2(0, 60))
	mode_1v1_btn.toggle_mode = true; mode_1v1_btn.button_pressed = true
	mode_1v1_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mode_1v1_btn.custom_minimum_size = Vector2(0, 60)
	mode_1v1_btn.pressed.connect(func(): _select_mode(NetworkManager.GameMode.ONEvONE))
	mode_row.add_child(mode_1v1_btn)
	mode_2v2_btn = _make_btn("2V2", Color(0.15, 0.4, 0.15), Vector2.ZERO, Vector2(0, 60))
	mode_2v2_btn.toggle_mode = true
	mode_2v2_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mode_2v2_btn.custom_minimum_size = Vector2(0, 60)
	mode_2v2_btn.pressed.connect(func(): _select_mode(NetworkManager.GameMode.TWOVTWO))
	mode_row.add_child(mode_2v2_btn)
	mode_3v3_btn = _make_btn("3V3", Color(0.15, 0.4, 0.15), Vector2.ZERO, Vector2(0, 60))
	mode_3v3_btn.toggle_mode = true
	mode_3v3_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mode_3v3_btn.custom_minimum_size = Vector2(0, 60)
	mode_3v3_btn.pressed.connect(func(): _select_mode(NetworkManager.GameMode.THREEvTHREE))
	mode_row.add_child(mode_3v3_btn)

	c1.add_child(_online_label("AI 玩家", 18))
	var ai_row = HBoxContainer.new()
	ai_row.add_theme_constant_override("separation", 10)
	c1.add_child(ai_row)
	red_ai_spin = SpinBox.new()
	red_ai_spin.min_value = 0; red_ai_spin.max_value = 2; red_ai_spin.value = 0
	red_ai_spin.prefix = "红方 AI  "
	red_ai_spin.custom_minimum_size = Vector2(0, 52)
	red_ai_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_spin(red_ai_spin)
	ai_row.add_child(red_ai_spin)
	blue_ai_spin = SpinBox.new()
	blue_ai_spin.min_value = 0; blue_ai_spin.max_value = 2; blue_ai_spin.value = 0
	blue_ai_spin.prefix = "蓝方 AI  "
	blue_ai_spin.custom_minimum_size = Vector2(0, 52)
	blue_ai_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_spin(blue_ai_spin)
	ai_row.add_child(blue_ai_spin)

	c1.add_child(_online_label("选择国家", 18))
	nation_select = OptionButton.new()
	nation_select.add_item("  维京    +25%生命  +10%速度")
	nation_select.add_item("  英格兰  +15%攻击  +20%视野  采木+10%")
	nation_select.add_item("  法兰西  +25护甲  城堡2级起始")
	nation_select.add_item("  中国    食物+20%  黄金+10%  人口+10")
	nation_select.add_item("  匈牙利  +15护甲  石材+15%  黄金+10%  人口+5")
	nation_select.add_item("  日本    +15%攻速  +10%攻击")
	nation_select.add_item("  拜占庭  +2双护甲  黄金+10%")
	nation_select.add_item("  蒙古    速度+20%  攻速+10%  视野+20%")
	nation_select.add_item("  波斯    生命+15%  盾甲+1  黄金+15%  人口+5")
	nation_select.add_item("  西班牙  攻击+10%  铠甲+1  黄金+15%")
	nation_select.custom_minimum_size = Vector2(0, 54)
	nation_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_option(nation_select, 18)
	c1.add_child(nation_select)

	c1.add_child(_online_label("战场地形（房主）", 18))
	map_btn = _make_btn(" 经典大陆 ▸", Color(0.2, 0.28, 0.2), Vector2.ZERO, Vector2(0, 54), "muted")
	map_btn.custom_minimum_size = Vector2(0, 54)
	map_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_btn.pressed.connect(_open_map_dialog)
	c1.add_child(map_btn)
	_update_map_availability(true)

	var research_check := CheckBox.new()
	research_check.name = "ResearchCheck"
	research_check.text = "科研模式（四时代·科技树）"
	research_check.custom_minimum_size = Vector2(0, 40)
	research_check.add_theme_font_size_override("font_size", 18)
	research_check.add_theme_color_override("font_color", UITheme.PARCHMENT)
	research_check.add_theme_color_override("font_hover_color", UITheme.GOLD)
	research_check.add_theme_color_override("icon_normal_color", UITheme.GOLD)
	research_check.button_pressed = GameSettings.progression_mode == GameSettings.ProgressionMode.RESEARCH
	research_check.toggled.connect(func(on): GameSettings.progression_mode = GameSettings.ProgressionMode.RESEARCH if on else GameSettings.ProgressionMode.CLASSIC)
	c1.add_child(research_check)

	var c1_spacer = Control.new()
	c1_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	c1.add_child(c1_spacer)

	c1.add_child(_online_label("传输方式", 18))
	var trans_row = HBoxContainer.new()
	trans_row.add_theme_constant_override("separation", 8)
	c1.add_child(trans_row)
	enet_toggle_btn = _make_btn("ENet (UDP:9000)", Color(0.15, 0.3, 0.55), Vector2.ZERO, Vector2(0, 50))
	enet_toggle_btn.toggle_mode = true; enet_toggle_btn.button_pressed = true
	enet_toggle_btn.custom_minimum_size = Vector2(0, 50)
	enet_toggle_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	enet_toggle_btn.pressed.connect(func(): _on_transport_changed(false))
	trans_row.add_child(enet_toggle_btn)
	ws_toggle_btn = _make_btn("WebSocket (TCP:8080)", Color(0.4, 0.3, 0.2), Vector2.ZERO, Vector2(0, 50))
	ws_toggle_btn.toggle_mode = true; ws_toggle_btn.button_pressed = false
	ws_toggle_btn.custom_minimum_size = Vector2(0, 50)
	ws_toggle_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ws_toggle_btn.pressed.connect(func(): _on_transport_changed(true))
	trans_row.add_child(ws_toggle_btn)

	# 中栏：创建 / 加入
	var col2 = _online_panel()
	col2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col2.size_flags_stretch_ratio = 0.93
	body.add_child(col2)
	var c2 = _online_panel_body(col2)
	c2.add_child(UITheme.make_section_title("🏰 创建主机", UITheme.GOLD, 30))
	host_btn = _make_btn("创建服务器", Color(0.15, 0.5, 0.2), Vector2.ZERO, Vector2(0, 76), "primary")
	host_btn.custom_minimum_size = Vector2(0, 76)
	host_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	host_btn.pressed.connect(_on_create_server_pressed)
	c2.add_child(host_btn)
	var hi = Label.new()
	hi.text = "WebSocket 房会自动生成网页 wss 链接。\n把链接发给网页玩家即可加入；主机需保持运行。"
	hi.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.apply_label(hi, 16, Color(UITheme.STONE).lightened(0.25))
	c2.add_child(hi)

	var sep = HSeparator.new()
	sep.custom_minimum_size = Vector2(0, 16)
	c2.add_child(sep)

	c2.add_child(UITheme.make_section_title("📡 加入游戏", UITheme.GOLD, 30))
	ip_label = Label.new()
	ip_label.text = "服务器 IP 地址:"
	UITheme.apply_label(ip_label, 17, UITheme.PARCHMENT)
	c2.add_child(ip_label)
	ip_input = LineEdit.new()
	ip_input.text = "127.0.0.1"
	ip_input.custom_minimum_size = Vector2(0, 54)
	ip_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_line_edit(ip_input, 20)
	c2.add_child(ip_input)
	var join_btn = _make_btn("加入服务器", Color(0.15, 0.3, 0.55), Vector2.ZERO, Vector2(0, 76), "primary")
	join_btn.custom_minimum_size = Vector2(0, 76)
	join_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	join_btn.pressed.connect(_on_join_game_pressed)
	c2.add_child(join_btn)

	status_label = Label.new()
	status_label.add_theme_font_size_override("font_size", 17)
	status_label.add_theme_color_override("font_color", UITheme.ALERT_INFO)
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.text = "状态：等待操作…"
	status_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	c2.add_child(status_label)

	# 右栏：Steam 房间
	var col3 = _online_panel()
	col3.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col3.size_flags_stretch_ratio = 0.98
	body.add_child(col3)
	var c3 = _online_panel_body(col3)
	c3.add_child(UITheme.make_section_title("🎮 Steam 房间", UITheme.GOLD, 30))
	steam_status = Label.new()
	steam_status.text = "Steam: 初始化中..."
	steam_status.add_theme_font_size_override("font_size", 16)
	steam_status.add_theme_color_override("font_color", Color(UITheme.STONE).lightened(0.25))
	steam_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	c3.add_child(steam_status)

	steam_lobby_list = ItemList.new()
	steam_lobby_list.custom_minimum_size = Vector2(0, 220)
	steam_lobby_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	steam_lobby_list.add_theme_font_size_override("font_size", 15)
	steam_lobby_list.add_theme_color_override("font_color", UITheme.PARCHMENT)
	steam_lobby_list.add_theme_color_override("font_selected_color", UITheme.INK)
	steam_lobby_list.item_selected.connect(_on_steam_lobby_selected)
	c3.add_child(steam_lobby_list)

	# 主动检查 Steam 当前状态（弥补 Autoload 信号先于本节点发出的时序问题）
	if SteamManager.steam_initialized:
		_on_steam_ready()
	elif not Engine.has_singleton("Steam"):
		_on_steam_failed("Steam SDK 未加载，缺少 steam_api64.dll")
	elif SteamManager.steam_initialized == false:
		_on_steam_failed("Steam 初始化失败 - 请确认 Steam 客户端正在运行")

	var steam_grid = GridContainer.new()
	steam_grid.columns = 2
	steam_grid.add_theme_constant_override("h_separation", 8)
	steam_grid.add_theme_constant_override("v_separation", 8)
	c3.add_child(steam_grid)
	var steam_create = _make_btn("创建 Steam 房间", Color(0.15, 0.4, 0.5), Vector2.ZERO, Vector2(0, 48), "muted")
	steam_create.custom_minimum_size = Vector2(0, 48)
	steam_create.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	steam_create.pressed.connect(_on_steam_create_lobby)
	steam_grid.add_child(steam_create)
	var steam_search = _make_btn("搜索房间", Color(0.3, 0.3, 0.45), Vector2.ZERO, Vector2(0, 48), "muted")
	steam_search.custom_minimum_size = Vector2(0, 48)
	steam_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	steam_search.pressed.connect(_on_steam_search_lobbies)
	steam_grid.add_child(steam_search)
	steam_join_btn = _make_btn("加入房间", Color(0.15, 0.5, 0.2), Vector2.ZERO, Vector2(0, 48), "primary")
	steam_join_btn.custom_minimum_size = Vector2(0, 48)
	steam_join_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	steam_join_btn.disabled = true
	steam_join_btn.pressed.connect(_on_steam_join_lobby)
	steam_grid.add_child(steam_join_btn)
	steam_leave_btn = _make_btn("离开房间", Color(0.5, 0.2, 0.2), Vector2.ZERO, Vector2(0, 48), "danger")
	steam_leave_btn.custom_minimum_size = Vector2(0, 48)
	steam_leave_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	steam_leave_btn.visible = false
	steam_leave_btn.pressed.connect(_on_steam_leave_lobby)
	steam_grid.add_child(steam_leave_btn)

	start_game_btn = _make_btn("开始游戏", Color(0.15, 0.6, 0.2), Vector2.ZERO, Vector2(0, 64), "primary")
	start_game_btn.custom_minimum_size = Vector2(0, 64)
	start_game_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	start_game_btn.pressed.connect(_on_start_game_pressed)
	start_game_btn.disabled = true
	start_game_btn.visible = false
	c3.add_child(start_game_btn)

	NetworkManager.player_count_updated.connect(_on_player_count_changed)
	UITheme.fade_in(body, 0.35)

func _online_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UITheme.card_style(UITheme.GOLD))
	return panel

func _online_panel_body(panel: PanelContainer) -> VBoxContainer:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_top", 18)
	margin.add_theme_constant_override("margin_bottom", 18)
	panel.add_child(margin)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	margin.add_child(vb)
	return vb

func _online_label(text: String, font_size: int) -> Label:
	var lbl := Label.new()
	lbl.text = text
	UITheme.apply_label(lbl, font_size, UITheme.PARCHMENT)
	return lbl

# ==================== 手机端竖排布局 ====================
# 桌面版的绝对坐标布局在手机上会整体缩成 1/3 大小；这里按 dp 重建一套可滚动表单，
# 控件字段与桌面版共用，因此所有连接/回调逻辑无需分叉。
func _build_mobile_ui() -> void:
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
	title.text = "👑 联机对战 👑"
	title.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	title.offset_top = UILayout.dp(5.0)
	title.offset_bottom = UILayout.dp(23.0)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", UILayout.font_dp(15.0))
	title.add_theme_color_override("font_color", UITheme.GOLD.lightened(0.15))
	title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	title.add_theme_constant_override("shadow_offset_x", 2)
	title.add_theme_constant_override("shadow_offset_y", 2)
	add_child(title)

	var back := Button.new()
	back.text = "← 返回"
	back.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	back.offset_left = -UILayout.dp(72.0)
	back.offset_right = -UILayout.dp(6.0)
	back.offset_top = UILayout.dp(5.0)
	back.offset_bottom = UILayout.dp(25.0)
	UITheme.apply_muted_button(back, UILayout.font_dp(10.0))
	back.pressed.connect(_on_return_pressed)
	add_child(back)

	var scroll := ScrollContainer.new()
	scroll.name = "MobileScroll"
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.offset_left = UILayout.dp(8.0)
	scroll.offset_right = -UILayout.dp(8.0)
	scroll.offset_top = UILayout.dp(29.0)
	scroll.offset_bottom = -UILayout.dp(6.0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	# 手机触摸事件由 ScrollContainer 自己处理（此界面没有战斗触摸路由器）。
	scroll.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(scroll)

	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", int(UILayout.dp(5.0)))
	scroll.add_child(vb)

	var fs_section: int = UILayout.font_dp(11.0)
	var fs_body: int = UILayout.font_dp(10.0)
	var btn_h: float = UILayout.dp(36.0)

	var sec := func(txt: String) -> void:
		var l := UITheme.make_section_title(txt, UITheme.GOLD, fs_section)
		vb.add_child(l)

	sec.call("⚔️ 游戏模式")
	var mode_row := HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", int(UILayout.dp(4.0)))
	vb.add_child(mode_row)
	mode_1v1_btn = _mobile_btn("1V1", NetworkManager.GameMode.ONEvONE, mode_row, btn_h, fs_body)
	mode_1v1_btn.toggle_mode = true
	mode_1v1_btn.button_pressed = true
	mode_2v2_btn = _mobile_btn("2V2", NetworkManager.GameMode.TWOVTWO, mode_row, btn_h, fs_body)
	mode_2v2_btn.toggle_mode = true
	mode_3v3_btn = _mobile_btn("3V3", NetworkManager.GameMode.THREEvTHREE, mode_row, btn_h, fs_body)
	mode_3v3_btn.toggle_mode = true

	var mobile_research := CheckBox.new()
	mobile_research.name = "ResearchCheck"
	mobile_research.text = "科研模式（四时代·科技树）"
	mobile_research.custom_minimum_size = Vector2(0, UILayout.dp(32.0))
	mobile_research.add_theme_font_size_override("font_size", fs_body)
	mobile_research.add_theme_color_override("font_color", UITheme.PARCHMENT)
	mobile_research.add_theme_color_override("font_hover_color", UITheme.GOLD)
	mobile_research.add_theme_color_override("icon_normal_color", UITheme.GOLD)
	mobile_research.button_pressed = GameSettings.progression_mode == GameSettings.ProgressionMode.RESEARCH
	mobile_research.toggled.connect(func(on): GameSettings.progression_mode = GameSettings.ProgressionMode.RESEARCH if on else GameSettings.ProgressionMode.CLASSIC)
	vb.add_child(mobile_research)

	sec.call("🤖 AI 玩家")
	red_ai_spin = SpinBox.new()
	red_ai_spin.min_value = 0; red_ai_spin.max_value = 2; red_ai_spin.value = 0
	red_ai_spin.prefix = "红方 AI:   "
	red_ai_spin.custom_minimum_size = Vector2(0, btn_h)
	_style_spin_mobile(red_ai_spin, fs_body)
	vb.add_child(red_ai_spin)
	blue_ai_spin = SpinBox.new()
	blue_ai_spin.min_value = 0; blue_ai_spin.max_value = 2; blue_ai_spin.value = 0
	blue_ai_spin.prefix = "蓝方 AI:  "
	blue_ai_spin.custom_minimum_size = Vector2(0, btn_h)
	_style_spin_mobile(blue_ai_spin, fs_body)
	vb.add_child(blue_ai_spin)

	sec.call("🏳️ 选择国家")
	nation_select = OptionButton.new()
	for item in ["  维京    +25%生命  +10%速度", "  英格兰  +15%攻击  +20%视野  采木+10%",
			"  法兰西  +25护甲  城堡2级起始", "  中国    食物+20%  黄金+10%  人口+10",
			"  匈牙利  +15护甲  石材+15%  黄金+10%  人口+5", "  日本    +15%攻速  +10%攻击",
			"  拜占庭  +2双护甲  黄金+10%", "  蒙古    速度+20%  攻速+10%  视野+20%",
			"  波斯    生命+15%  盾甲+1  黄金+15%  人口+5", "  西班牙  攻击+10%  铠甲+1  黄金+15%"]:
		nation_select.add_item(item)
	nation_select.custom_minimum_size = Vector2(0, btn_h)
	_style_option(nation_select, fs_body)
	vb.add_child(nation_select)

	sec.call("🗺️ 战场地形（房主）")
	map_btn = Button.new()
	map_btn.custom_minimum_size = Vector2(0, btn_h)
	map_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.apply_muted_button(map_btn, fs_body)
	map_btn.pressed.connect(_open_map_dialog)
	vb.add_child(map_btn)
	_refresh_map_button()
	_update_map_availability(true)

	sec.call("📡 传输方式")
	var trans_row := HBoxContainer.new()
	trans_row.add_theme_constant_override("separation", int(UILayout.dp(4.0)))
	vb.add_child(trans_row)
	enet_toggle_btn = Button.new()
	enet_toggle_btn.text = "ENet (UDP)"
	enet_toggle_btn.toggle_mode = true
	enet_toggle_btn.button_pressed = true
	enet_toggle_btn.custom_minimum_size = Vector2(0, UILayout.dp(32.0))
	enet_toggle_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.apply_primary_button(enet_toggle_btn, fs_body)
	enet_toggle_btn.pressed.connect(func(): _on_transport_changed(false))
	trans_row.add_child(enet_toggle_btn)
	ws_toggle_btn = Button.new()
	ws_toggle_btn.text = "WebSocket (TCP)"
	ws_toggle_btn.toggle_mode = true
	ws_toggle_btn.custom_minimum_size = Vector2(0, UILayout.dp(32.0))
	ws_toggle_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.apply_muted_button(ws_toggle_btn, fs_body)
	ws_toggle_btn.pressed.connect(func(): _on_transport_changed(true))
	trans_row.add_child(ws_toggle_btn)

	sec.call("🏰 创建主机")
	host_btn = Button.new()
	host_btn.text = "创建服务器"
	host_btn.custom_minimum_size = Vector2(0, btn_h + UILayout.dp(4.0))
	UITheme.apply_primary_button(host_btn, fs_body + 1)
	host_btn.pressed.connect(_on_create_server_pressed)
	vb.add_child(host_btn)
	var host_hint := Label.new()
	host_hint.text = "WebSocket 房会自动生成网页 wss 链接，发给网页玩家即可加入；主机需保持运行。"
	host_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	host_hint.add_theme_font_size_override("font_size", UILayout.font_dp(8.0))
	host_hint.add_theme_color_override("font_color", Color(UITheme.STONE).lightened(0.25))
	vb.add_child(host_hint)

	sec.call("📡 加入游戏")
	ip_label = Label.new()
	ip_label.text = "服务器 IP 地址:"
	ip_label.add_theme_font_size_override("font_size", fs_body)
	ip_label.add_theme_color_override("font_color", UITheme.PARCHMENT)
	vb.add_child(ip_label)
	ip_input = LineEdit.new()
	ip_input.text = "127.0.0.1"
	ip_input.custom_minimum_size = Vector2(0, btn_h)
	_style_line_edit(ip_input, fs_body)
	vb.add_child(ip_input)
	var join_btn := Button.new()
	join_btn.text = "加入服务器"
	join_btn.custom_minimum_size = Vector2(0, btn_h + UILayout.dp(4.0))
	UITheme.apply_primary_button(join_btn, fs_body + 1)
	join_btn.pressed.connect(_on_join_game_pressed)
	vb.add_child(join_btn)

	status_label = Label.new()
	status_label.text = ""
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.add_theme_font_size_override("font_size", UILayout.font_dp(9.0))
	status_label.add_theme_color_override("font_color", UITheme.ALERT_INFO)
	status_label.custom_minimum_size = Vector2(0, UILayout.dp(24.0))
	vb.add_child(status_label)

	sec.call("🎮 Steam 房间")
	steam_status = Label.new()
	steam_status.text = "Steam: 初始化中..."
	steam_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	steam_status.add_theme_font_size_override("font_size", UILayout.font_dp(8.5))
	steam_status.add_theme_color_override("font_color", Color(UITheme.STONE).lightened(0.25))
	vb.add_child(steam_status)
	steam_lobby_list = ItemList.new()
	steam_lobby_list.custom_minimum_size = Vector2(0, UILayout.dp(80.0))
	steam_lobby_list.add_theme_font_size_override("font_size", fs_body)
	steam_lobby_list.add_theme_color_override("font_color", UITheme.PARCHMENT)
	steam_lobby_list.add_theme_color_override("font_selected_color", UITheme.INK)
	steam_lobby_list.item_selected.connect(_on_steam_lobby_selected)
	vb.add_child(steam_lobby_list)
	var steam_row := HBoxContainer.new()
	steam_row.add_theme_constant_override("separation", int(UILayout.dp(4.0)))
	vb.add_child(steam_row)
	var create_btn := Button.new()
	create_btn.text = "创建房间"
	create_btn.custom_minimum_size = Vector2(0, UILayout.dp(32.0))
	create_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.apply_muted_button(create_btn, fs_body)
	create_btn.pressed.connect(_on_steam_create_lobby)
	steam_row.add_child(create_btn)
	var search_btn := Button.new()
	search_btn.text = "搜索房间"
	search_btn.custom_minimum_size = Vector2(0, UILayout.dp(32.0))
	search_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.apply_muted_button(search_btn, fs_body)
	search_btn.pressed.connect(_on_steam_search_lobbies)
	steam_row.add_child(search_btn)
	steam_join_btn = Button.new()
	steam_join_btn.text = "加入房间"
	steam_join_btn.custom_minimum_size = Vector2(0, UILayout.dp(32.0))
	steam_join_btn.disabled = true
	UITheme.apply_primary_button(steam_join_btn, fs_body)
	steam_join_btn.pressed.connect(_on_steam_join_lobby)
	vb.add_child(steam_join_btn)
	steam_leave_btn = Button.new()
	steam_leave_btn.text = "离开房间"
	steam_leave_btn.custom_minimum_size = Vector2(0, UILayout.dp(32.0))
	steam_leave_btn.visible = false
	UITheme.apply_danger_button(steam_leave_btn, fs_body)
	steam_leave_btn.pressed.connect(_on_steam_leave_lobby)
	vb.add_child(steam_leave_btn)
	start_game_btn = Button.new()
	start_game_btn.text = "开始游戏"
	start_game_btn.custom_minimum_size = Vector2(0, UILayout.dp(40.0))
	start_game_btn.disabled = true
	start_game_btn.visible = false
	UITheme.apply_primary_button(start_game_btn, fs_body + 1)
	start_game_btn.pressed.connect(_on_start_game_pressed)
	vb.add_child(start_game_btn)

	if SteamManager.steam_initialized:
		_on_steam_ready()
	elif not Engine.has_singleton("Steam"):
		_on_steam_failed("Steam SDK 未加载，缺少 steam_api64.dll")
	elif SteamManager.steam_initialized == false:
		_on_steam_failed("Steam 初始化失败 - 请确认 Steam 客户端正在运行")
	if not NetworkManager.player_count_updated.is_connected(_on_player_count_changed):
		NetworkManager.player_count_updated.connect(_on_player_count_changed)

func _mobile_btn(text: String, mode: int, parent: Node, height: float, font_size: int) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, height)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.apply_primary_button(b, font_size)
	b.pressed.connect(func(): _select_mode(mode))
	parent.add_child(b)
	return b

func _style_spin_mobile(sp: SpinBox, font_size: int) -> void:
	var le := sp.get_line_edit()
	le.add_theme_font_size_override("font_size", font_size)
	le.add_theme_color_override("font_color", UITheme.PARCHMENT)
	le.add_theme_color_override("caret_color", UITheme.GOLD)
	le.add_theme_color_override("font_hover_color", UITheme.GOLD)

## 主题化 OptionButton（含弹出列表）
func _style_option(o: OptionButton, font_size: int) -> void:
	o.add_theme_font_size_override("font_size", font_size)
	o.add_theme_color_override("font_color", UITheme.PARCHMENT)
	o.add_theme_color_override("font_hover_color", UITheme.GOLD)
	var pop = o.get_popup()
	pop.add_theme_font_size_override("font_size", font_size)
	pop.add_theme_color_override("font_color", UITheme.PARCHMENT)
	pop.add_theme_color_override("font_hover_color", UITheme.GOLD)

## 主题化 SpinBox（内部 LineEdit）
func _style_spin(sp: SpinBox) -> void:
	var le = sp.get_line_edit()
	le.add_theme_font_size_override("font_size", 18)
	le.add_theme_color_override("font_color", UITheme.PARCHMENT)
	le.add_theme_color_override("caret_color", UITheme.GOLD)
	le.add_theme_color_override("font_hover_color", UITheme.GOLD)

## 主题化 LineEdit（深底金边）
func _style_line_edit(le: LineEdit, font_size: int) -> void:
	le.add_theme_font_size_override("font_size", font_size)
	le.add_theme_color_override("font_color", UITheme.PARCHMENT)
	le.add_theme_color_override("caret_color", UITheme.GOLD)
	le.add_theme_color_override("placeholder_font_color", Color(UITheme.STONE))
	var normal := UITheme.panel_style(UITheme.RADIUS_SM, UITheme.BORDER_THIN, 0.55)
	le.add_theme_stylebox_override("normal", normal)
	var focus := normal.duplicate() as StyleBoxFlat
	focus.border_color = Color(UITheme.GOLD, 0.9)
	focus.set_border_width_all(UITheme.BORDER_MED)
	le.add_theme_stylebox_override("focus", focus)

## 联机菜单按钮工厂
## kind = "primary"(金) / "danger"(朱红) / "muted"(石板) / "tint"(语义主色填充，统一金边圆角四态)
func _make_btn(text: String, color: Color, pos: Vector2, size: Vector2, kind: String = "tint") -> Button:
	var btn = Button.new(); btn.text = text; btn.position = pos; btn.size = size
	if kind == "primary":
		UITheme.apply_primary_button(btn, UITheme.FONT_LG)
		return btn
	if kind == "danger":
		UITheme.apply_danger_button(btn, UITheme.FONT_LG)
		return btn
	if kind == "muted":
		UITheme.apply_muted_button(btn, UITheme.FONT_LG)
		return btn
	# tint 路径：语义主色填充 + 统一金边圆角四态
	var s := StyleBoxFlat.new()
	s.bg_color = Color(color)
	s.set_corner_radius_all(UITheme.RADIUS_MD)
	s.set_border_width_all(UITheme.BORDER_MED)
	s.border_color = Color(UITheme.GOLD, 0.6)
	s.shadow_size = 3
	s.shadow_color = Color(0, 0, 0, 0.4)
	s.shadow_offset = Vector2(1, 2)
	var hover := s.duplicate() as StyleBoxFlat
	hover.bg_color = color.lightened(0.15)
	hover.border_color = Color(UITheme.GOLD)
	var pressed := s.duplicate() as StyleBoxFlat
	pressed.bg_color = color.lightened(0.3)
	pressed.border_color = Color(UITheme.GOLD)
	pressed.set_border_width_all(UITheme.BORDER_THICK)
	var disabled := s.duplicate() as StyleBoxFlat
	disabled.bg_color = Color(color.r, color.g, color.b, 0.25)
	disabled.shadow_size = 0
	btn.add_theme_stylebox_override("normal", s)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_stylebox_override("pressed", pressed)
	btn.add_theme_stylebox_override("disabled", disabled)
	btn.add_theme_font_size_override("font_size", UITheme.FONT_LG)
	btn.add_theme_color_override("font_color", UITheme.PARCHMENT)
	btn.add_theme_color_override("font_hover_color", UITheme.GOLD)
	btn.add_theme_color_override("font_pressed_color", UITheme.GOLD)
	btn.add_theme_color_override("font_disabled_color", Color(UITheme.STONE))
	return btn

func _select_mode(mode: int):
	NetworkManager.selected_mode = mode
	mode_1v1_btn.button_pressed = (mode == NetworkManager.GameMode.ONEvONE)
	mode_2v2_btn.button_pressed = (mode == NetworkManager.GameMode.TWOVTWO)
	mode_3v3_btn.button_pressed = (mode == NetworkManager.GameMode.THREEvTHREE)
	# AI 数量上限随每队人数调整（3v3 每队最多 3 个 AI），并收缩当前值防止越界
	var max_ai = NetworkManager.get_team_size()
	red_ai_spin.max_value = max_ai
	blue_ai_spin.max_value = max_ai
	red_ai_spin.value = mini(int(red_ai_spin.value), max_ai)
	blue_ai_spin.value = mini(int(blue_ai_spin.value), max_ai)
	_update_map_availability(true)

# ---------- 战场地形（特殊地图仅 1V1，跟随房主选择） ----------
func _open_map_dialog() -> void:
	if map_btn and map_btn.disabled:
		return
	var existing = get_node_or_null("MapDialog")
	if existing:
		existing.queue_free()
		return
	var dlg = MapSelectDialog.new()
	dlg.name = "MapDialog"
	dlg.map_selected.connect(_on_map_selected)
	add_child(dlg)

func _on_map_selected(id: String) -> void:
	GameSettings.map_id = id
	_refresh_map_button()

func _refresh_map_button() -> void:
	if not map_btn:
		return
	var info := MapPresets.get_info(GameSettings.map_id)
	var suffix := ""
	if String(info["battle"]) != "":
		suffix = " · " + String(info["battle"])
	map_btn.text = "  %s%s ▸" % [String(info["name"]), suffix]
	if map_btn.disabled:
		map_btn.text += "（当前模式不支持）"

func _update_map_availability(allow: bool) -> void:
	if not map_btn:
		return
	if not allow and _map_allowed:
		# 只有从"可选"切到"不可选"时才记下选择，避免每次切模式都把选图清掉
		if GameSettings.map_id != "classic":
			_last_map_id = GameSettings.map_id
		GameSettings.map_id = "classic"
	elif allow and not _map_allowed:
		GameSettings.map_id = _last_map_id
	_map_allowed = allow
	map_btn.disabled = not allow
	_refresh_map_button()

func _apply_web_defaults() -> void:
	if not OS.has_feature("web"):
		return
	if enet_toggle_btn:
		enet_toggle_btn.disabled = true
	if host_btn:
		host_btn.disabled = true
		host_btn.text = "浏览器版不能创建主机"
	if ip_label:
		ip_label.text = "服务器 WebSocket 地址:"
	_on_transport_changed(true)
	if ip_input:
		ip_input.text = ""
		ip_input.placeholder_text = "wss://你的服务器地址"
	if status_label:
		status_label.text = "浏览器版：打开邀请链接会自动加入；也可以粘贴 wss:// 地址。"
	# 主持人生成的分享链接形如：
	# https://fingerempire.netlify.app/?server=wss%3A%2F%2Fxxxx.trycloudflare.com
	# 网页端读 query 参数后自动填地址并尝试加入，玩家不用手抄 wss 地址。
	var room_url := _read_web_room_param()
	if room_url != "" and ip_input:
		ip_input.text = NetworkManager.normalize_ws_url(room_url)
		if status_label:
			status_label.text = "已读取网页房邀请，正在连接..."
		_web_auto_join_started = false
		call_deferred("_auto_join_web_room")

func _read_web_room_param() -> String:
	var js = Engine.get_singleton("JavaScriptBridge")
	if js == null:
		return ""
	var raw := String(js.eval("new URLSearchParams(location.search).get('server') || ''"))
	return raw.strip_edges()

func _auto_join_web_room() -> void:
	if _web_auto_join_started:
		return
	_web_auto_join_started = true
	# 等 UI 和自动加载的网络信号都接好，再发连接
	await get_tree().create_timer(0.7).timeout
	if not is_instance_valid(self):
		return
	if NetworkManager.mode != NetworkManager.Mode.NONE:
		return
	if ip_input and ip_input.text.strip_edges() != "":
		_on_join_game_pressed()

func _on_transport_changed(use_ws: bool):
	if OS.has_feature("web"):
		use_ws = true
	NetworkManager.use_websocket = use_ws
	enet_toggle_btn.button_pressed = not use_ws
	ws_toggle_btn.button_pressed = use_ws
	if OS.has_feature("web"):
		return
	if use_ws:
		if host_btn:
			host_btn.text = "创建网页房间（自动公网）"
		ip_input.text = "ws://127.0.0.1:8080"
		if status_label:
			status_label.text = "网页房会自动生成 wss 链接，网页玩家点链接即可加入。"
	else:
		if host_btn:
			host_btn.text = "创建服务器"
		ip_input.text = "127.0.0.1"
		if status_label:
			status_label.text = "ENet 房使用主机 IP 连接；网页玩家请切换到 WebSocket。\n"

func _on_create_server_pressed():
	if OS.has_feature("web"):
		status_label.text = "浏览器版不能创建服务器；请在 PC/服务器端启动 WebSocket 主机后，打开邀请链接加入。"
		return
	# 网页房已就绪时，再次点击主机按钮只重新显示邀请链接，不重建服务器
	if NetworkManager.use_websocket and WebTunnel.running and _web_room_share_url != "":
		_show_web_room_dialog()
		return
	NetworkManager.red_ai_count = int(red_ai_spin.value)
	NetworkManager.blue_ai_count = int(blue_ai_spin.value)
	if NetworkManager.use_websocket:
		if NetworkManager.mode != NetworkManager.Mode.SERVER:
			if not NetworkManager.start_ws_server(false):
				status_label.text = "WebSocket 服务器启动失败，端口 8080 可能被占用。"
				return
		status_label.text = "WS 服务器已启动 (端口 8080)\n正在生成网页玩家可用的 wss 链接..."
		start_game_btn.visible = true
		start_game_btn.text = "开始游戏 (1 名玩家)"
		# 复用已存在的隧道；否则启动 Cloudflare Quick Tunnel
		if WebTunnel.running and WebTunnel.wss_url != "":
			_on_web_tunnel_ready(WebTunnel.wss_url, WebTunnel.share_url)
		elif not WebTunnel.is_available():
			status_label.text = "WS 服务器已启动 (仅局域网)\n缺少 cloudflared.exe，无法生成网页公网链接。"
			_show_web_room_error("缺少 cloudflared.exe",
				"没有找到 Cloudflare 隧道组件，网页玩家暂时无法通过公网加入。\n\n" +
				"请重新下载完整 Windows 包，或把 cloudflared.exe 放到游戏 exe 同目录。")
		else:
			WebTunnel.start(NetworkManager.WS_PORT)
	else:
		NetworkManager.start_server()
		status_label.text = "服务器已启动 (端口 9000)\nUPnP 映射进行中..."
		start_game_btn.visible = true
		start_game_btn.text = "开始游戏 (1 名玩家)"
	# 网页房需要等网页玩家加入后再手动开始；不能因为 AI 填满就自动开战，
	# 否则大厅会直接切走，主机来不及把邀请链接发给别人。
	if not NetworkManager.use_websocket and NetworkManager.can_start_game():
		status_label.text = "全部由AI填充，自动开始..."
		await get_tree().create_timer(0.5).timeout
		var reason = NetworkManager.start_game()
		if reason != "":
			status_label.text = "启动失败: %s" % reason
			status_label.add_theme_color_override("font_color", UITheme.ALERT_WARNING)

func _on_join_game_pressed():
	var addr := ip_input.text.strip_edges()
	if NetworkManager.use_websocket:
		if addr == "":
			if OS.has_feature("web"):
				status_label.text = "请先填写 wss:// 服务器地址"
				return
			addr = "ws://127.0.0.1:8080"
	else:
		if addr == "":
			addr = "127.0.0.1"
	GameSettings.player_nation = nation_select.selected
	if NetworkManager.use_websocket:
		NetworkManager.start_ws_client(addr)
	else:
		NetworkManager.start_client(addr)
	status_label.text = "正在连接 %s..." % addr

func _on_connected(): status_label.text = "已连接!"
func _on_failed(reason): status_label.text = "连接失败: " + reason

func _on_upnp_ready(ip: String):
	if NetworkManager.use_websocket:
		status_label.text = "服务器就绪!\nURL: ws://%s:8080\n将此链接分享给好友!" % ip
	else:
		status_label.text = "服务器就绪!\n公网 IP: %s\n端口: 9000\n分享此 IP 给好友!" % ip

func _on_upnp_failed(reason: String):
	if NetworkManager.use_websocket:
		status_label.text = "WS 服务器已启动 (仅局域网)\n%s\n网页玩家需要公网 wss 链接，请使用「创建网页房间」自动生成。" % reason
	else:
		status_label.text = "服务器已启动 (仅局域网)\n%s\n同一网络的玩家可通过局域网 IP 加入" % reason

# ==================== 网页房（PC 主机 + Cloudflare 隧道） ====================
func _on_web_tunnel_ready(wss_url: String, share_url: String) -> void:
	_web_room_wss_url = wss_url
	_web_room_share_url = share_url
	if host_btn:
		host_btn.text = "显示网页邀请链接"
	DisplayServer.clipboard_set(share_url)
	if status_label:
		status_label.text = "网页房已就绪！邀请链接已复制到剪贴板，发给网页玩家即可。\n%s" % share_url
		status_label.add_theme_color_override("font_color", UITheme.ALERT_INFO)
	_show_web_room_dialog()

func _on_web_tunnel_failed(reason: String) -> void:
	_web_room_share_url = ""
	_web_room_wss_url = ""
	if host_btn:
		host_btn.text = "重试创建网页房间"
	if status_label:
		status_label.text = "网页公网链接生成失败：%s" % reason
		status_label.add_theme_color_override("font_color", UITheme.ALERT_WARNING)
	_show_web_room_error("网页公网链接生成失败", reason)

func _show_web_room_dialog() -> void:
	if _web_room_dialog != null and is_instance_valid(_web_room_dialog):
		_web_room_dialog.queue_free()
	var dlg := AcceptDialog.new()
	dlg.title = "网页房已创建"
	dlg.ok_button_text = "关闭"
	dlg.dialog_text = "把下面的邀请链接发给网页玩家，打开后会自动加入：\n\n%s\n\n主机需要保持游戏运行。\n\n网页玩家也可以手动填写：\n%s" % [
		_web_room_share_url, _web_room_wss_url,
	]
	dlg.add_button("复制邀请链接", true, "copy")
	dlg.add_button("打开网页入口", true, "open")
	dlg.custom_action.connect(_on_web_room_dialog_action.bind(dlg))
	dlg.get_label().autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(dlg)
	_web_room_dialog = dlg
	dlg.popup_centered(Vector2i(980, 430))

func _on_web_room_dialog_action(action: StringName, dlg: AcceptDialog) -> void:
	match String(action):
		"copy":
			DisplayServer.clipboard_set(_web_room_share_url)
			if status_label:
				status_label.text = "邀请链接已复制，发给网页玩家即可。"
		"open":
			OS.shell_open(_web_room_share_url)
	if dlg != null and is_instance_valid(dlg):
		dlg.hide()

func _show_web_room_error(title: String, message: String) -> void:
	var dlg := AcceptDialog.new()
	dlg.title = title
	dlg.ok_button_text = "关闭"
	dlg.dialog_text = message
	dlg.add_button("打开 cloudflared 下载页", true, "download")
	dlg.custom_action.connect(func(action: StringName):
		if String(action) == "download":
			OS.shell_open(WebTunnel.download_url())
	)
	dlg.get_label().autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(dlg)
	dlg.popup_centered(Vector2i(860, 360))

# Steam lobby vars
var steam_lobby_list: ItemList
var steam_status: Label
var steam_join_btn: Button
var steam_leave_btn: Button
var start_game_btn: Button
var _steam_lobbies: Array = []

func _on_steam_ready():
	steam_status.text = "Steam: 已连接为 " + SteamManager.get_my_name()
	steam_status.add_theme_color_override("font_color", UITheme.ALERT_INFO)
	# Enable buttons are already visible

func _on_steam_failed(reason: String):
	steam_status.text = "Steam: " + reason
	steam_status.add_theme_color_override("font_color", UITheme.ALERT_DANGER)

func _on_steam_create_lobby():
	NetworkManager.red_ai_count = int(red_ai_spin.value)
	NetworkManager.blue_ai_count = int(blue_ai_spin.value)
	SteamManager.create_lobby()
	steam_status.text = "创建房间中..."

func _on_steam_lobby_created(lobby_id: int):
	steam_status.text = "房间已创建! ID: %d" % lobby_id
	steam_status.add_theme_color_override("font_color", UITheme.ALERT_INFO)
	steam_leave_btn.visible = true
	NetworkManager.start_steam_server()
	start_game_btn.visible = true
	var count = SteamManager.lobby_members.size()
	var need = NetworkManager.get_max_humans()
	start_game_btn.text = "开始游戏 (%d/%d 名玩家)" % [count, need]
	var my_sid = SteamManager.get_my_steam_id()
	SteamManager.set_lobby_data("host_sid", str(my_sid))
	print("[OnlineMenu] Stored host Steam ID: ", my_sid)
	status_label.text = "Steam P2P 房间就绪! 等待玩家加入..."
	steam_status.text = steam_status.text + "\nSteam P2P - 无需端口"

func _on_steam_search_lobbies():
	steam_lobby_list.clear()
	_steam_lobbies.clear()
	steam_status.text = "搜索房间中..."
	SteamManager.search_lobbies()

func _on_steam_lobby_list(lobbies: Array):
	_steam_lobbies = lobbies
	steam_lobby_list.clear()
	for l in lobbies:
		steam_lobby_list.add_item("%s | %s | %d/%d 玩家" % [l.host_name, l.mode, l.members, l.max_members])
	steam_status.text = "找到 %d 个房间" % lobbies.size()

func _on_steam_lobby_selected(index: int):
	steam_join_btn.disabled = false

func _on_steam_join_lobby():
	var sel = steam_lobby_list.get_selected_items()
	if sel.is_empty() or sel[0] >= _steam_lobbies.size():
		return
	var lid = _steam_lobbies[sel[0]].id
	steam_status.text = "加入房间中..."
	SteamManager.join_lobby(lid)

func _on_steam_lobby_joined(lobby_id: int):
	steam_status.text = "已加入房间! ID: %d" % lobby_id
	steam_status.add_theme_color_override("font_color", UITheme.ALERT_INFO)
	steam_leave_btn.visible = true
	# 关键修复：房主自己也会收到 lobby_joined 回调，不应连接自己
	if SteamManager.is_lobby_owner():
		print("[OnlineMenu] I am the lobby owner — skipping self-connection")
		status_label.text = "房间就绪! 等待玩家加入..."
		return
	var host_sid_str = SteamManager.get_lobby_data("host_sid")
	print("[OnlineMenu] Steam lobby joined, host Steam ID: ", host_sid_str)
	var host_sid = int(host_sid_str) if host_sid_str != "" else 0
	if host_sid == 0:
		print("[OnlineMenu] ERROR: host_sid empty!")
		return
	print("[OnlineMenu] Connecting to host via Steam P2P, Steam ID: ", host_sid)
	NetworkManager.start_client_steam(host_sid)
	status_label.text = "已通过 Steam P2P 连接! 主机: " + host_sid_str

func _on_steam_lobby_join_failed(reason: String):
	steam_status.text = "加入失败: " + reason
	steam_status.add_theme_color_override("font_color", UITheme.ALERT_DANGER)

func _on_steam_member_joined(sid: int, sname: String):
	steam_status.text = steam_status.text + "\n" + sname + " 已加入"
	_update_steam_player_count()

func _on_steam_member_left(sid: int):
	steam_status.text = steam_status.text + "\n玩家已离开"
	_update_steam_player_count()

func _update_steam_player_count():
	if not NetworkManager.use_steam:
		return
	if NetworkManager.mode != NetworkManager.Mode.SERVER:
		return
	var count = SteamManager.lobby_members.size()
	var need = NetworkManager.get_max_humans()
	var peer_count = multiplayer.get_peers().size()
	start_game_btn.visible = true
	start_game_btn.text = "开始游戏 (%d/%d 名玩家)" % [count, need]
	var ready = NetworkManager.can_start_game()
	start_game_btn.disabled = not ready
	# 显示 P2P 连接状态
	if need > 1 and peer_count == 0 and count >= need:
		status_label.text = "房间已满! 等待 P2P 连接..."
		status_label.add_theme_color_override("font_color", UITheme.ALERT_WARNING)
	elif not ready:
		var reason = NetworkManager.get_block_reason()
		if reason != "":
			status_label.text = reason

func _on_steam_leave_lobby():
	SteamManager.leave_lobby()
	steam_leave_btn.visible = false
	steam_lobby_list.clear()
	steam_status.text = "Steam: 已连接为 " + SteamManager.get_my_name()
	steam_status.add_theme_color_override("font_color", UITheme.ALERT_INFO)

func _get_local_ip() -> String:
	var addresses = IP.get_local_addresses()
	for ip in addresses:
		if ip.begins_with("192.168.") or ip.begins_with("10.") or ip.begins_with("172.16."):
			return ip
	return "127.0.0.1"

func _on_start_game_pressed():
	var reason = NetworkManager.start_game()
	if reason != "":
		status_label.text = "无法开始: %s" % reason
		status_label.add_theme_color_override("font_color", UITheme.ALERT_WARNING)
		print("[OnlineMenu] Start blocked: ", reason)

func _on_player_count_changed():
	print("[OnlineMenu] player_count_changed fired")
	var count = NetworkManager.get_connected_count()
	var need = NetworkManager.get_max_humans()
	var ready = NetworkManager.can_start_game()
	var reason = NetworkManager.get_block_reason()
	print("[OnlineMenu] count=", count, " need=", need, " ready=", ready, " mode=", NetworkManager.mode)
	if count > 0 or NetworkManager.mode == NetworkManager.Mode.SERVER:
		start_game_btn.visible = true
		start_game_btn.text = "开始游戏 (%d/%d 名玩家)" % [count, need]
		start_game_btn.disabled = not ready
	if ready and not NetworkManager.game_started and not NetworkManager.use_websocket:
		status_label.text = "所有玩家到齐，自动开始..."
		start_game_btn.disabled = true  # 防止重复点击
		await get_tree().create_timer(0.5).timeout
		var start_reason = NetworkManager.start_game()
		if start_reason != "":
			status_label.text = "启动失败: %s" % start_reason
			status_label.add_theme_color_override("font_color", UITheme.ALERT_WARNING)
			start_game_btn.disabled = false
	if not ready and reason != "":
		status_label.text = reason
	print("[OnlineMenu] button updated: ", start_game_btn.text)

func _on_steam_game_starting():
	print("[OnlineMenu] Host started the game! Loading battle scene...")
	var tree = get_tree()
	if tree:
		# 与房主同尺寸加载：客户端场景不生成地图，但客户端网格/小地图按此尺寸预分配
		RTSConfig.MAP_SIZE = 150 if NetworkManager.selected_mode != NetworkManager.GameMode.ONEvONE else 100
		tree.change_scene_to_file("res://scenes/rts_battle_client.tscn")

func _on_return_pressed():
	if NetworkManager.mode == NetworkManager.Mode.SERVER and NetworkManager.use_websocket:
		WebTunnel.stop()
		NetworkManager.stop_server()
	var _t = get_tree()
	if _t: _t.change_scene_to_file("res://scenes/main_menu.tscn")

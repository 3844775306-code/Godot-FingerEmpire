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
var map_btn: Button
var _last_map_id: String = "classic"
var _map_allowed: bool = true

func _ready():
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
	# Hide old scene nodes
	var old = get_node_or_null("Panel")
	if old: old.visible = false

	# 全屏暖黑背景（羊皮纸皇庭底色）
	var bg = ColorRect.new(); bg.color = Color(0.10, 0.08, 0.06)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg); move_child(bg, 0)

	# 顶部皇庭金饰横条
	var bar = ColorRect.new(); bar.color = Color(UITheme.GOLD)
	bar.position = Vector2(0, 0); bar.size = Vector2(2400, 6)
	add_child(bar)
	var bar2 = ColorRect.new(); bar2.color = Color(UITheme.GOLD, 0.35)
	bar2.position = Vector2(0, 6); bar2.size = Vector2(2400, 3)
	add_child(bar2)

	# Title
	var t = Label.new(); t.text = "👑 联机对战 👑"; t.position = Vector2(0, 40)
	t.size = Vector2(2400, 70); t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.add_theme_font_size_override("font_size", 52)
	t.add_theme_color_override("font_color", UITheme.GOLD.lightened(0.15))
	t.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	t.add_theme_constant_override("shadow_offset_x", 3)
	t.add_theme_constant_override("shadow_offset_y", 3)
	t.add_theme_constant_override("shadow_size", 8)
	add_child(t)

	# 标题下金色装饰线
	var gold_line = ColorRect.new()
	gold_line.color = Color(UITheme.GOLD, 0.7)
	gold_line.position = Vector2(880, 118)
	gold_line.size = Vector2(640, 3)
	add_child(gold_line)

	# Center panel
	var panel = Panel.new()
	panel.position = Vector2(550, 140); panel.size = Vector2(1300, 700)
	panel.add_theme_stylebox_override("panel", UITheme.card_style(UITheme.GOLD))
	add_child(panel)

	var x0 = 50; var y = 30
	var _lb = func(txt, yy):
		var l = UITheme.make_section_title(txt, UITheme.GOLD, 20)
		l.position = Vector2(x0, yy); l.size = Vector2(500, 32)
		panel.add_child(l)

	# Left column - Game Config
	_lb.call("⚔️ 游戏模式", y)
	mode_1v1_btn = _make_btn("1V1", Color(0.15, 0.4, 0.15), Vector2(x0, y + 38), Vector2(160, 50))
	mode_1v1_btn.toggle_mode = true; mode_1v1_btn.button_pressed = true
	mode_1v1_btn.pressed.connect(func(): _select_mode(NetworkManager.GameMode.ONEvONE))
	panel.add_child(mode_1v1_btn)
	mode_2v2_btn = _make_btn("2V2", Color(0.15, 0.4, 0.15), Vector2(x0 + 175, y + 38), Vector2(160, 50))
	mode_2v2_btn.toggle_mode = true
	mode_2v2_btn.pressed.connect(func(): _select_mode(NetworkManager.GameMode.TWOVTWO))
	panel.add_child(mode_2v2_btn)
	mode_3v3_btn = _make_btn("3V3", Color(0.15, 0.4, 0.15), Vector2(x0 + 350, y + 38), Vector2(160, 50))
	mode_3v3_btn.toggle_mode = true
	mode_3v3_btn.pressed.connect(func(): _select_mode(NetworkManager.GameMode.THREEvTHREE))
	panel.add_child(mode_3v3_btn)

	y += 115
	_lb.call("🤖 AI 玩家", y)
	red_ai_spin = SpinBox.new()
	red_ai_spin.position = Vector2(x0, y + 38); red_ai_spin.size = Vector2(500, 44)
	red_ai_spin.min_value = 0; red_ai_spin.max_value = 2; red_ai_spin.value = 0
	red_ai_spin.prefix = "红方 AI:   "
	_style_spin(red_ai_spin)
	panel.add_child(red_ai_spin)
	blue_ai_spin = SpinBox.new()
	blue_ai_spin.position = Vector2(x0, y + 92); blue_ai_spin.size = Vector2(500, 44)
	blue_ai_spin.min_value = 0; blue_ai_spin.max_value = 2; blue_ai_spin.value = 0
	blue_ai_spin.prefix = "蓝方 AI:  "
	_style_spin(blue_ai_spin)
	panel.add_child(blue_ai_spin)

	y += 165
	_lb.call("🏳️ 选择国家", y)
	nation_select = OptionButton.new()
	nation_select.add_item("  维京    +25%生命  +10%速度")
	nation_select.add_item("  英格兰  +15%攻击  +20%视野  采木+10%")
	nation_select.add_item("  法兰西  +25护甲  城堡2级起始")
	nation_select.add_item("  中国    食物+20%  黄金+10%  人口+10")
	nation_select.add_item("  匈牙利  +15护甲  石材+15%  黄金+10%  人口+5")
	nation_select.add_item("  日本    +15%攻速  +10%攻击")
	nation_select.add_item("  拜占庭  +2双护甲  黄金+10%")
	nation_select.position = Vector2(x0, y + 38); nation_select.size = Vector2(500, 44)
	_style_option(nation_select, 16)
	panel.add_child(nation_select)

	y += 100
	_lb.call("🗺️ 战场地形（房主）", y)
	map_btn = _make_btn(" 经典大陆 ▸", Color(0.2, 0.28, 0.2), Vector2(x0, y + 38), Vector2(500, 44), "muted")
	map_btn.pressed.connect(_open_map_dialog)
	panel.add_child(map_btn)
	_update_map_availability(true)

	y += 100
	_lb.call("📡 传输方式", y)
	enet_toggle_btn = _make_btn("ENet (UDP:9000)", Color(0.15, 0.3, 0.55), Vector2(x0, y + 38), Vector2(240, 40))
	enet_toggle_btn.toggle_mode = true; enet_toggle_btn.button_pressed = true
	enet_toggle_btn.pressed.connect(func(): _on_transport_changed(false))
	panel.add_child(enet_toggle_btn)
	ws_toggle_btn = _make_btn("WebSocket (TCP:8080)", Color(0.4, 0.3, 0.2), Vector2(x0 + 255, y + 38), Vector2(240, 40))
	ws_toggle_btn.toggle_mode = true; ws_toggle_btn.button_pressed = false
	ws_toggle_btn.pressed.connect(func(): _on_transport_changed(true))
	panel.add_child(ws_toggle_btn)

	# Right column - Connection
	var rx = 680; var ry = 30
	var _lb2 = func(txt, yy):
		var l = UITheme.make_section_title(txt, UITheme.GOLD, 20)
		l.position = Vector2(rx, yy); l.size = Vector2(570, 32)
		panel.add_child(l)

	_lb2.call("🏰 创建主机", ry)
	var host_btn = _make_btn("创建服务器", Color(0.15, 0.5, 0.2), Vector2(rx, ry + 45), Vector2(570, 65), "primary")
	host_btn.pressed.connect(_on_create_server_pressed)
	panel.add_child(host_btn)
	# Host instructions
	var hi = Label.new()
	hi.text = "启动服务器并等待玩家加入。\n玩家需要你的 IP 地址才能连接。"
	hi.position = Vector2(rx, ry + 120); hi.size = Vector2(570, 50)
	UITheme.apply_label(hi, 14, Color(UITheme.STONE).lightened(0.25))
	panel.add_child(hi)

	ry += 190
	_lb2.call("📡 加入游戏", ry)
	var ip_lbl = Label.new()
	ip_lbl.text = "服务器 IP 地址:"
	ip_lbl.position = Vector2(rx, ry + 40); ip_lbl.size = Vector2(570, 24)
	UITheme.apply_label(ip_lbl, 16, UITheme.PARCHMENT)
	panel.add_child(ip_lbl)
	ip_input = LineEdit.new()
	ip_input.text = "127.0.0.1"; ip_input.position = Vector2(rx, ry + 70); ip_input.size = Vector2(570, 48)
	_style_line_edit(ip_input, 20)
	panel.add_child(ip_input)
	var join_btn = _make_btn("加入服务器", Color(0.15, 0.3, 0.55), Vector2(rx, ry + 135), Vector2(570, 65), "primary")
	join_btn.pressed.connect(_on_join_game_pressed)
	panel.add_child(join_btn)

	# Status bar at bottom
	ry += 230
	status_label = Label.new()
	status_label.position = Vector2(rx, ry); status_label.size = Vector2(570, 80)
	status_label.add_theme_font_size_override("font_size", 16)
	status_label.add_theme_color_override("font_color", UITheme.ALERT_INFO)
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(status_label)

	# Steam lobby section
	steam_status = Label.new()
	steam_status.text = "Steam: 初始化中..."
	steam_status.position = Vector2(rx, ry + 80); steam_status.size = Vector2(570, 30)
	steam_status.add_theme_font_size_override("font_size", 14)
	steam_status.add_theme_color_override("font_color", Color(UITheme.STONE).lightened(0.25))
	panel.add_child(steam_status)

	# 主动检查 Steam 当前状态（弥补 Autoload 信号先于本节点发出的时序问题）
	if SteamManager.steam_initialized:
		_on_steam_ready()
	elif not Engine.has_singleton("Steam"):
		_on_steam_failed("Steam SDK 未加载，缺少 steam_api64.dll")
	elif SteamManager.steam_initialized == false:
		_on_steam_failed("Steam 初始化失败 - 请确认 Steam 客户端正在运行")

	steam_lobby_list = ItemList.new()
	steam_lobby_list.position = Vector2(rx, ry + 115); steam_lobby_list.size = Vector2(570, 120)
	steam_lobby_list.add_theme_font_size_override("font_size", 14)
	steam_lobby_list.add_theme_color_override("font_color", UITheme.PARCHMENT)
	steam_lobby_list.add_theme_color_override("font_selected_color", UITheme.INK)
	steam_lobby_list.item_selected.connect(_on_steam_lobby_selected)
	panel.add_child(steam_lobby_list)

	var steam_create = _make_btn("创建 Steam 房间", Color(0.15, 0.4, 0.5), Vector2(rx, ry + 245), Vector2(275, 45), "muted")
	steam_create.pressed.connect(_on_steam_create_lobby)
	panel.add_child(steam_create)
	var steam_search = _make_btn("搜索房间", Color(0.3, 0.3, 0.45), Vector2(rx + 295, ry + 245), Vector2(275, 45), "muted")
	steam_search.pressed.connect(_on_steam_search_lobbies)
	panel.add_child(steam_search)
	steam_join_btn = _make_btn("加入房间", Color(0.15, 0.5, 0.2), Vector2(rx, ry + 300), Vector2(570, 45), "primary")
	steam_join_btn.pressed.connect(_on_steam_join_lobby)
	steam_join_btn.disabled = true
	panel.add_child(steam_join_btn)
	steam_leave_btn = _make_btn("离开房间", Color(0.5, 0.2, 0.2), Vector2(rx, ry + 355), Vector2(570, 45), "danger")
	steam_leave_btn.pressed.connect(_on_steam_leave_lobby)
	steam_leave_btn.visible = false
	panel.add_child(steam_leave_btn)

	# Start Game button (host only)
	start_game_btn = _make_btn("开始游戏", Color(0.15, 0.6, 0.2), Vector2(rx, ry + 415), Vector2(570, 55), "primary")
	start_game_btn.pressed.connect(_on_start_game_pressed)
	start_game_btn.disabled = true
	start_game_btn.visible = false
	panel.add_child(start_game_btn)
	NetworkManager.player_count_updated.connect(_on_player_count_changed)

	# Return button
	var ret_btn = _make_btn("← 返回", Color(0.25, 0.25, 0.35), Vector2(30, 30), Vector2(150, 45), "muted")
	ret_btn.pressed.connect(_on_return_pressed)
	add_child(ret_btn)

	UITheme.fade_in(panel, 0.35)

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

func _on_transport_changed(use_ws: bool):
	NetworkManager.use_websocket = use_ws
	enet_toggle_btn.button_pressed = not use_ws
	ws_toggle_btn.button_pressed = use_ws
	if use_ws:
		ip_input.text = "ws://127.0.0.1:8080"
	else:
		ip_input.text = "127.0.0.1"

func _on_create_server_pressed():
	NetworkManager.red_ai_count = int(red_ai_spin.value)
	NetworkManager.blue_ai_count = int(blue_ai_spin.value)
	if NetworkManager.use_websocket:
		NetworkManager.start_ws_server()
		status_label.text = "WS 服务器启动中 (端口 8080)\nUPnP 映射进行中..."
	else:
		NetworkManager.start_server()
		status_label.text = "服务器已启动 (端口 9000)\nUPnP 映射进行中..."
	start_game_btn.visible = true
	start_game_btn.text = "开始游戏 (1 名玩家)"
	# 无需等待其他人类玩家 → 自动开始
	if NetworkManager.can_start_game():
		status_label.text = "全部由AI填充，自动开始..."
		await get_tree().create_timer(0.5).timeout
		var reason = NetworkManager.start_game()
		if reason != "":
			status_label.text = "启动失败: %s" % reason
			status_label.add_theme_color_override("font_color", UITheme.ALERT_WARNING)

func _on_join_game_pressed():
	var default_addr = "ws://127.0.0.1:8080" if NetworkManager.use_websocket else "127.0.0.1"
	var addr = ip_input.text if ip_input.text != "" else default_addr
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
		status_label.text = "WS 服务器已启动 (仅局域网)\n%s\n同一网络内可用 ws://局域网IP:8080 连接" % reason
	else:
		status_label.text = "服务器已启动 (仅局域网)\n%s\n同一网络的玩家可通过局域网 IP 加入" % reason

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
	if ready and not NetworkManager.game_started:
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

func _on_return_pressed(): var _t = get_tree(); if _t: _t.change_scene_to_file("res://scenes/main_menu.tscn")

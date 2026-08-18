extends Control

var nation_select: OptionButton
var red_ai_spin: SpinBox
var blue_ai_spin: SpinBox
var mode_1v1_btn: Button
var mode_2v2_btn: Button
var status_label: Label
var ip_input: LineEdit
var enet_toggle_btn: Button
var ws_toggle_btn: Button

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

	# Full-screen dark bg
	var bg = ColorRect.new(); bg.color = Color(0.05, 0.05, 0.09)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg); move_child(bg, 0)

	# Top bar
	var bar = ColorRect.new(); bar.color = Color(0.2, 0.45, 0.8, 0.4)
	bar.position = Vector2(0, 0); bar.size = Vector2(2400, 4)
	add_child(bar)

	# Title
	var t = Label.new(); t.text = "MULTIPLAYER"; t.position = Vector2(0, 40)
	t.size = Vector2(2400, 70); t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.add_theme_font_size_override("font_size", 48)
	t.add_theme_color_override("font_color", Color(0.4, 0.75, 1.0))
	add_child(t)

	# Center panel
	var panel = Panel.new()
	panel.position = Vector2(550, 140); panel.size = Vector2(1300, 700)
	var ps = StyleBoxFlat.new()
	ps.bg_color = Color(0.07, 0.08, 0.14, 0.95)
	ps.corner_radius_top_left = 12; ps.corner_radius_top_right = 12
	ps.corner_radius_bottom_left = 12; ps.corner_radius_bottom_right = 12
	ps.border_width_left = 2; ps.border_width_right = 2; ps.border_width_top = 2; ps.border_width_bottom = 2
	ps.border_color = Color(0.25, 0.5, 0.8, 0.6)
	panel.add_theme_stylebox_override("panel", ps)
	add_child(panel)

	var x0 = 50; var y = 30
	var _lb = func(txt, yy):
		var l = Label.new(); l.text = txt; l.position = Vector2(x0, yy); l.size = Vector2(500, 32)
		l.add_theme_font_size_override("font_size", 22)
		l.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75))
		panel.add_child(l)

	# Left column - Game Config
	_lb.call("GAME MODE", y)
	mode_1v1_btn = _make_btn("1v1", Color(0.15, 0.4, 0.15), Vector2(x0, y + 38), Vector2(160, 50))
	mode_1v1_btn.toggle_mode = true; mode_1v1_btn.button_pressed = true
	mode_1v1_btn.pressed.connect(func(): _select_mode(NetworkManager.GameMode.ONEvONE))
	panel.add_child(mode_1v1_btn)
	mode_2v2_btn = _make_btn("2v2", Color(0.15, 0.4, 0.15), Vector2(x0 + 175, y + 38), Vector2(160, 50))
	mode_2v2_btn.toggle_mode = true
	mode_2v2_btn.pressed.connect(func(): _select_mode(NetworkManager.GameMode.TWOVTWO))
	panel.add_child(mode_2v2_btn)

	y += 115
	_lb.call("AI PLAYERS", y)
	red_ai_spin = SpinBox.new()
	red_ai_spin.position = Vector2(x0, y + 38); red_ai_spin.size = Vector2(500, 44)
	red_ai_spin.min_value = 0; red_ai_spin.max_value = 2; red_ai_spin.value = 0
	red_ai_spin.prefix = "Red AI:   "; red_ai_spin.add_theme_font_size_override("font_size", 18)
	panel.add_child(red_ai_spin)
	blue_ai_spin = SpinBox.new()
	blue_ai_spin.position = Vector2(x0, y + 92); blue_ai_spin.size = Vector2(500, 44)
	blue_ai_spin.min_value = 0; blue_ai_spin.max_value = 2; blue_ai_spin.value = 0
	blue_ai_spin.prefix = "Blue AI:  "; blue_ai_spin.add_theme_font_size_override("font_size", 18)
	panel.add_child(blue_ai_spin)

	y += 165
	_lb.call("NATION", y)
	nation_select = OptionButton.new()
	nation_select.add_item("  Viking     +25% HP  +10% Speed")
	nation_select.add_item("  England    +15% ATK  +20% Vision  Wood+10%")
	nation_select.add_item("  France     +25 Armor  Castle Lv.2")
	nation_select.add_item("  China      Food+20%  Gold+10%  Pop+10")
	nation_select.add_item("  Hungary    +15 Armor  Stone+15%  Gold+10%  Pop+5")
	nation_select.position = Vector2(x0, y + 38); nation_select.size = Vector2(500, 44)
	nation_select.add_theme_font_size_override("font_size", 16)
	panel.add_child(nation_select)

	y += 100
	_lb.call("TRANSPORT", y)
	enet_toggle_btn = _make_btn("ENet (UDP :9000)", Color(0.15, 0.3, 0.55), Vector2(x0, y + 38), Vector2(240, 40))
	enet_toggle_btn.toggle_mode = true; enet_toggle_btn.button_pressed = true
	enet_toggle_btn.pressed.connect(func(): _on_transport_changed(false))
	panel.add_child(enet_toggle_btn)
	ws_toggle_btn = _make_btn("WebSocket (TCP :8080)", Color(0.4, 0.3, 0.2), Vector2(x0 + 255, y + 38), Vector2(240, 40))
	ws_toggle_btn.toggle_mode = true; ws_toggle_btn.button_pressed = false
	ws_toggle_btn.pressed.connect(func(): _on_transport_changed(true))
	panel.add_child(ws_toggle_btn)

	# Right column - Connection
	var rx = 680; var ry = 30
	var _lb2 = func(txt, yy):
		var l = Label.new(); l.text = txt; l.position = Vector2(rx, yy); l.size = Vector2(570, 32)
		l.add_theme_font_size_override("font_size", 22)
		l.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75))
		panel.add_child(l)

	_lb2.call("HOST GAME", ry)
	var host_btn = _make_btn("CREATE SERVER", Color(0.15, 0.5, 0.2), Vector2(rx, ry + 45), Vector2(570, 65))
	host_btn.pressed.connect(_on_create_server_pressed)
	panel.add_child(host_btn)
	# Host instructions
	var hi = Label.new()
	hi.text = "Start a server and wait for players to join.\nThey need your IP address to connect."
	hi.position = Vector2(rx, ry + 120); hi.size = Vector2(570, 50)
	hi.add_theme_font_size_override("font_size", 14)
	hi.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	panel.add_child(hi)

	ry += 190
	_lb2.call("JOIN GAME", ry)
	var ip_lbl = Label.new()
	ip_lbl.text = "Server IP Address:"; ip_lbl.position = Vector2(rx, ry + 40); ip_lbl.size = Vector2(570, 24)
	ip_lbl.add_theme_font_size_override("font_size", 16)
	ip_lbl.add_theme_color_override("font_color", Color(0.65, 0.65, 0.65))
	panel.add_child(ip_lbl)
	ip_input = LineEdit.new()
	ip_input.text = "127.0.0.1"; ip_input.position = Vector2(rx, ry + 70); ip_input.size = Vector2(570, 48)
	ip_input.add_theme_font_size_override("font_size", 20)
	panel.add_child(ip_input)
	var join_btn = _make_btn("JOIN SERVER", Color(0.15, 0.3, 0.55), Vector2(rx, ry + 135), Vector2(570, 65))
	join_btn.pressed.connect(_on_join_game_pressed)
	panel.add_child(join_btn)

	# Status bar at bottom
	ry += 230
	status_label = Label.new()
	status_label.position = Vector2(rx, ry); status_label.size = Vector2(570, 80)
	status_label.add_theme_font_size_override("font_size", 16)
	status_label.add_theme_color_override("font_color", Color(0.5, 0.9, 0.5))
	panel.add_child(status_label)

	# Steam lobby section
	steam_status = Label.new()
	steam_status.text = "Steam: initializing..."
	steam_status.position = Vector2(rx, ry + 80); steam_status.size = Vector2(570, 30)
	steam_status.add_theme_font_size_override("font_size", 14)
	steam_status.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	panel.add_child(steam_status)

	# 主动检查 Steam 当前状态（弥补 Autoload 信号先于本节点发出的时序问题）
	if SteamManager.steam_initialized:
		_on_steam_ready()
	elif not Engine.has_singleton("Steam"):
		_on_steam_failed("Steam SDK not loaded, steam_api64.dll missing")
	elif SteamManager.steam_initialized == false:
		_on_steam_failed("Steam init failed - make sure Steam client is running")
	
	steam_lobby_list = ItemList.new()
	steam_lobby_list.position = Vector2(rx, ry + 115); steam_lobby_list.size = Vector2(570, 120)
	steam_lobby_list.add_theme_font_size_override("font_size", 14)
	steam_lobby_list.item_selected.connect(_on_steam_lobby_selected)
	panel.add_child(steam_lobby_list)
	
	var steam_create = _make_btn("CREATE STEAM LOBBY", Color(0.15, 0.4, 0.5), Vector2(rx, ry + 245), Vector2(275, 45))
	steam_create.pressed.connect(_on_steam_create_lobby)
	panel.add_child(steam_create)
	var steam_search = _make_btn("SEARCH LOBBIES", Color(0.3, 0.3, 0.45), Vector2(rx + 295, ry + 245), Vector2(275, 45))
	steam_search.pressed.connect(_on_steam_search_lobbies)
	panel.add_child(steam_search)
	steam_join_btn = _make_btn("JOIN LOBBY", Color(0.15, 0.5, 0.2), Vector2(rx, ry + 300), Vector2(570, 45))
	steam_join_btn.pressed.connect(_on_steam_join_lobby)
	steam_join_btn.disabled = true
	panel.add_child(steam_join_btn)
	steam_leave_btn = _make_btn("LEAVE LOBBY", Color(0.5, 0.2, 0.2), Vector2(rx, ry + 355), Vector2(570, 45))
	steam_leave_btn.pressed.connect(_on_steam_leave_lobby)
	steam_leave_btn.visible = false
	panel.add_child(steam_leave_btn)

	# Start Game button (host only)
	start_game_btn = _make_btn("START GAME", Color(0.15, 0.6, 0.2), Vector2(rx, ry + 415), Vector2(570, 55))
	start_game_btn.pressed.connect(_on_start_game_pressed)
	start_game_btn.disabled = true
	start_game_btn.visible = false
	panel.add_child(start_game_btn)
	NetworkManager.player_count_updated.connect(_on_player_count_changed)

	# Return button
	var ret_btn = _make_btn("<- BACK", Color(0.25, 0.25, 0.35), Vector2(30, 30), Vector2(150, 45))
	ret_btn.pressed.connect(_on_return_pressed)
	add_child(ret_btn)

func _make_btn(text: String, color: Color, pos: Vector2, size: Vector2) -> Button:
	var btn = Button.new(); btn.text = text; btn.position = pos; btn.size = size
	var s = StyleBoxFlat.new(); s.bg_color = color
	s.corner_radius_top_left = 6; s.corner_radius_top_right = 6
	s.corner_radius_bottom_left = 6; s.corner_radius_bottom_right = 6
	s.border_width_left = 1; s.border_width_right = 1; s.border_width_top = 1; s.border_width_bottom = 1
	s.border_color = Color(color.r * 1.3, color.g * 1.3, color.b * 1.3, 0.5)
	btn.add_theme_stylebox_override("normal", s)
	var hs = s.duplicate(); hs.bg_color = Color(color.r * 1.3, color.g * 1.3, color.b * 1.3, color.a)
	btn.add_theme_stylebox_override("hover", hs)
	btn.add_theme_font_size_override("font_size", 20)
	return btn

func _select_mode(mode: int):
	NetworkManager.selected_mode = mode
	mode_1v1_btn.button_pressed = (mode == NetworkManager.GameMode.ONEvONE)
	mode_2v2_btn.button_pressed = (mode == NetworkManager.GameMode.TWOVTWO)

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
		status_label.text = "WS Server starting on port 8080\nUPnP mapping in progress..."
	else:
		NetworkManager.start_server()
		status_label.text = "Server started on port 9000\nUPnP mapping in progress..."
	start_game_btn.visible = true
	start_game_btn.text = "START GAME (1 player)"
	# 无需等待其他人类玩家 → 自动开始
	if NetworkManager.can_start_game():
		status_label.text = "全部由AI填充，自动开始..."
		await get_tree().create_timer(0.5).timeout
		var reason = NetworkManager.start_game()
		if reason != "":
			status_label.text = "Start failed: %s" % reason
			status_label.add_theme_color_override("font_color", Color(1.0, 0.5, 0.3))

func _on_join_game_pressed():
	var default_addr = "ws://127.0.0.1:8080" if NetworkManager.use_websocket else "127.0.0.1"
	var addr = ip_input.text if ip_input.text != "" else default_addr
	GameSettings.player_nation = nation_select.selected
	if NetworkManager.use_websocket:
		NetworkManager.start_ws_client(addr)
	else:
		NetworkManager.start_client(addr)
	status_label.text = "Connecting to %s..." % addr

func _on_connected(): status_label.text = "Connected!"
func _on_failed(reason): status_label.text = "Failed: " + reason

func _on_upnp_ready(ip: String):
	if NetworkManager.use_websocket:
		status_label.text = "Server ready!\nURL: ws://%s:8080\nShare this URL with friends!" % ip
	else:
		status_label.text = "Server ready!\nPublic IP: %s\nPort: 9000\nShare this IP with friends!" % ip

func _on_upnp_failed(reason: String):
	if NetworkManager.use_websocket:
		status_label.text = "WS Server started (LAN only)\n%s\nTry ws://LOCAL_IP:8080 on same network" % reason
	else:
		status_label.text = "Server started (LAN only)\n%s\nPlayers on same network can join via local IP" % reason

# Steam lobby vars
var steam_lobby_list: ItemList
var steam_status: Label
var steam_join_btn: Button
var steam_leave_btn: Button
var start_game_btn: Button
var _steam_lobbies: Array = []

func _on_steam_ready():
	steam_status.text = "Steam: connected as " + SteamManager.get_my_name()
	steam_status.add_theme_color_override("font_color", Color(0.3, 1.0, 0.4))
	# Enable buttons are already visible

func _on_steam_failed(reason: String):
	steam_status.text = "Steam: " + reason
	steam_status.add_theme_color_override("font_color", Color(1.0, 0.4, 0.3))

func _on_steam_create_lobby():
	NetworkManager.red_ai_count = int(red_ai_spin.value)
	NetworkManager.blue_ai_count = int(blue_ai_spin.value)
	SteamManager.create_lobby()
	steam_status.text = "Creating lobby..."

func _on_steam_lobby_created(lobby_id: int):
	steam_status.text = "Lobby created! ID: %d" % lobby_id
	steam_status.add_theme_color_override("font_color", Color(0.3, 1.0, 0.4))
	steam_leave_btn.visible = true
	NetworkManager.start_steam_server()
	start_game_btn.visible = true
	var count = SteamManager.lobby_members.size()
	var need = NetworkManager.get_max_humans()
	start_game_btn.text = "START GAME (%d/%d players)" % [count, need]
	var my_sid = SteamManager.get_my_steam_id()
	SteamManager.set_lobby_data("host_sid", str(my_sid))
	print("[OnlineMenu] Stored host Steam ID: ", my_sid)
	status_label.text = "Steam P2P lobby ready! Waiting for players..."
	steam_status.text = steam_status.text + "\nSteam P2P - no port needed"

func _on_steam_search_lobbies():
	steam_lobby_list.clear()
	_steam_lobbies.clear()
	steam_status.text = "Searching lobbies..."
	SteamManager.search_lobbies()

func _on_steam_lobby_list(lobbies: Array):
	_steam_lobbies = lobbies
	steam_lobby_list.clear()
	for l in lobbies:
		steam_lobby_list.add_item("%s | %s | %d/%d players" % [l.host_name, l.mode, l.members, l.max_members])
	steam_status.text = "Found %d lobbies" % lobbies.size()

func _on_steam_lobby_selected(index: int):
	steam_join_btn.disabled = false

func _on_steam_join_lobby():
	var sel = steam_lobby_list.get_selected_items()
	if sel.is_empty() or sel[0] >= _steam_lobbies.size():
		return
	var lid = _steam_lobbies[sel[0]].id
	steam_status.text = "Joining lobby..."
	SteamManager.join_lobby(lid)

func _on_steam_lobby_joined(lobby_id: int):
	steam_status.text = "Joined lobby! ID: %d" % lobby_id
	steam_status.add_theme_color_override("font_color", Color(0.3, 1.0, 0.4))
	steam_leave_btn.visible = true
	# 关键修复：房主自己也会收到 lobby_joined 回调，不应连接自己
	if SteamManager.is_lobby_owner():
		print("[OnlineMenu] I am the lobby owner — skipping self-connection")
		status_label.text = "Lobby ready! Waiting for players..."
		return
	var host_sid_str = SteamManager.get_lobby_data("host_sid")
	print("[OnlineMenu] Steam lobby joined, host Steam ID: ", host_sid_str)
	var host_sid = int(host_sid_str) if host_sid_str != "" else 0
	if host_sid == 0:
		print("[OnlineMenu] ERROR: host_sid empty!")
		return
	print("[OnlineMenu] Connecting to host via Steam P2P, Steam ID: ", host_sid)
	NetworkManager.start_client_steam(host_sid)
	status_label.text = "Connected via Steam P2P! Host: " + host_sid_str

func _on_steam_lobby_join_failed(reason: String):
	steam_status.text = "Join failed: " + reason
	steam_status.add_theme_color_override("font_color", Color(1.0, 0.4, 0.3))

func _on_steam_member_joined(sid: int, sname: String):
	steam_status.text = steam_status.text + "\n" + sname + " joined"
	_update_steam_player_count()

func _on_steam_member_left(sid: int):
	steam_status.text = steam_status.text + "\nPlayer left"
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
	start_game_btn.text = "START GAME (%d/%d players)" % [count, need]
	var ready = NetworkManager.can_start_game()
	start_game_btn.disabled = not ready
	# 显示 P2P 连接状态
	if need > 1 and peer_count == 0 and count >= need:
		status_label.text = "Lobby full! Waiting for P2P connection..."
		status_label.add_theme_color_override("font_color", Color(1.0, 0.8, 0.3))
	elif not ready:
		var reason = NetworkManager.get_block_reason()
		if reason != "":
			status_label.text = reason

func _on_steam_leave_lobby():
	SteamManager.leave_lobby()
	steam_leave_btn.visible = false
	steam_lobby_list.clear()
	steam_status.text = "Steam: connected as " + SteamManager.get_my_name()
	steam_status.add_theme_color_override("font_color", Color(0.3, 1.0, 0.4))

func _get_local_ip() -> String:
	var addresses = IP.get_local_addresses()
	for ip in addresses:
		if ip.begins_with("192.168.") or ip.begins_with("10.") or ip.begins_with("172.16."):
			return ip
	return "127.0.0.1"

func _on_start_game_pressed():
	var reason = NetworkManager.start_game()
	if reason != "":
		status_label.text = "Cannot start: %s" % reason
		status_label.add_theme_color_override("font_color", Color(1.0, 0.5, 0.3))
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
		start_game_btn.text = "START GAME (%d/%d players)" % [count, need]
		start_game_btn.disabled = not ready
	if ready and not NetworkManager.game_started:
		status_label.text = "所有玩家到齐，自动开始..."
		start_game_btn.disabled = true  # 防止重复点击
		await get_tree().create_timer(0.5).timeout
		var start_reason = NetworkManager.start_game()
		if start_reason != "":
			status_label.text = "Start failed: %s" % start_reason
			status_label.add_theme_color_override("font_color", Color(1.0, 0.5, 0.3))
			start_game_btn.disabled = false
	if not ready and reason != "":
		status_label.text = reason
	print("[OnlineMenu] button updated: ", start_game_btn.text)

func _on_steam_game_starting():
	print("[OnlineMenu] Host started the game! Loading battle scene...")
	var tree = get_tree()
	if tree:
		tree.change_scene_to_file("res://scenes/rts_battle_client.tscn")

func _on_return_pressed(): var _t = get_tree(); if _t: _t.change_scene_to_file("res://scenes/main_menu.tscn")

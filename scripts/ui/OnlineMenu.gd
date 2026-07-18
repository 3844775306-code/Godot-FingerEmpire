extends Control

var nation_select: OptionButton
var red_ai_spin: SpinBox
var blue_ai_spin: SpinBox
var mode_1v1_btn: Button
var mode_2v2_btn: Button
var status_label: Label
var ip_input: LineEdit

func _ready():
	NetworkManager.connection_success.connect(_on_connected)
	NetworkManager.connection_failed.connect(_on_failed)

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

func _on_create_server_pressed():
	NetworkManager.red_ai_count = int(red_ai_spin.value)
	NetworkManager.blue_ai_count = int(blue_ai_spin.value)
	NetworkManager.start_server()
	status_label.text = "Server started on port 9000\nWaiting for players..."

func _on_join_game_pressed():
	var ip = ip_input.text if ip_input.text != "" else "127.0.0.1"
	GameSettings.player_nation = nation_select.selected
	NetworkManager.start_client(ip)
	status_label.text = "Connecting to %s..." % ip

func _on_connected(): status_label.text = "Connected!"
func _on_failed(reason): status_label.text = "Failed: " + reason
func _on_return_pressed(): get_tree().change_scene_to_file("res://scenes/main_menu.tscn")

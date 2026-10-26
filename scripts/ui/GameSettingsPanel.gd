extends Control
# 对局内设置面板：画质（固定档位，不允许自定义）、音量、暂停、退出
# 单机与联机客户端共用；联机模式下"暂停"不可用（服务器权威，客户端暂停无意义）

const PANEL_W: float = 470.0
const PANEL_H: float = 580.0

const QUALITY_NAMES: Array = ["流畅", "标准", "高清", "极致"]
const QUALITY_DESC: Array = [
	"3D 渲染 60% · 关闭阴影与 SSAO",
	"3D 渲染 80% · 关闭阴影与 SSAO",
	"3D 渲染 100% · 开启阴影（60m）",
	"3D 渲染 100% · 阴影 120m + SSAO",
]

var _is_online: bool = false
var _is_client: bool = false
var _quality_level: int = 2
var _quality_btns: Array = []
var _pause_btn: Button = null
var _hint_label: Label = null
var _mobile: bool = false

func setup(is_online: bool, is_client: bool) -> void:
	_is_online = is_online
	_is_client = is_client
	_build()

# ==================== 界面构建 ====================
func _build() -> void:
	name = "GameSettingsPanel"
	_mobile = InputSource.use_mobile_ui()
	# 触屏路由器只把落在已登记面板上的触摸翻译成 UI 事件；设置面板是全屏模态，
	# 不登记的话手机上连按钮都点不到，更别说滚动。
	add_to_group("mobile_modal_ui")
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	# 暂停时本面板仍要能被点击
	process_mode = Node.PROCESS_MODE_ALWAYS
	z_index = 200

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.62)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var panel := Panel.new()
	var vp := get_viewport().get_visible_rect().size
	var panel_w: float = PANEL_W
	var panel_h: float = PANEL_H
	if _mobile:
		# 手机屏高约 393dp：面板铺满可用高度，内部滚动，避免内容被裁掉。
		panel_w = minf(UILayout.dp(360.0), vp.x - UILayout.dp(12.0))
		panel_h = vp.y - UILayout.dp(16.0)
	panel.custom_minimum_size = Vector2(panel_w, panel_h)
	panel.size = Vector2(panel_w, panel_h)
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.offset_left = -panel_w * 0.5
	panel.offset_right = panel_w * 0.5
	panel.offset_top = -panel_h * 0.5
	panel.offset_bottom = panel_h * 0.5
	var st := StyleBoxFlat.new()
	st.bg_color = Color(UITheme.INK, 0.97)
	st.set_corner_radius_all(10)
	st.set_border_width_all(2)
	st.border_color = Color(UITheme.GOLD, 0.55)
	panel.add_theme_stylebox_override("panel", st)
	add_child(panel)

	var content_parent: Control = panel
	if _mobile:
		var scroll := ScrollContainer.new()
		scroll.name = "SettingsScroll"
		scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		scroll.offset_left = UILayout.dp(5.0)
		scroll.offset_right = -UILayout.dp(5.0)
		scroll.offset_top = UILayout.dp(5.0)
		scroll.offset_bottom = -UILayout.dp(5.0)
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
		panel.add_child(scroll)
		content_parent = scroll

	var vb := VBoxContainer.new()
	if _mobile:
		vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vb.add_theme_constant_override("separation", int(UILayout.dp(7.0)))
	else:
		vb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		vb.offset_left = 20
		vb.offset_right = -20
		vb.offset_top = 14
		vb.offset_bottom = -14
		vb.add_theme_constant_override("separation", 10)
	content_parent.add_child(vb)

	# 标题行
	var title_row := HBoxContainer.new()
	vb.add_child(title_row)
	var ttl := UITheme.make_section_title("⚙ 设置", UITheme.GOLD, UITheme.FONT_LG)
	ttl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(ttl)
	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.custom_minimum_size = Vector2(40, 34)
	UITheme.apply_muted_button(close_btn, UITheme.FONT_MD)
	close_btn.pressed.connect(_on_close_pressed)
	title_row.add_child(close_btn)

	# 画质（固定档位）
	vb.add_child(_make_label("🖼 画质（固定档位）", UITheme.GOLD))
	var qty_row := HBoxContainer.new()
	qty_row.add_theme_constant_override("separation", 8)
	vb.add_child(qty_row)
	for i in QUALITY_NAMES.size():
		var b := Button.new()
		b.text = QUALITY_NAMES[i]
		b.toggle_mode = true
		b.button_pressed = (i == _quality_level)
		b.custom_minimum_size = Vector2(0, 36)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.apply_primary_button(b, UITheme.FONT_MD)
		b.pressed.connect(_on_quality_pressed.bind(i))
		qty_row.add_child(b)
		_quality_btns.append(b)
	_hint_label = _make_label(QUALITY_DESC[_quality_level], UITheme.PARCHMENT, UITheme.FONT_SM)
	vb.add_child(_hint_label)

	# 音量
	vb.add_child(_make_label("🔊 音量", UITheme.GOLD))
	vb.add_child(_make_volume_row("总音量", 1.0, func(v: float): _set_master_volume(v)))
	vb.add_child(_make_volume_row("音乐", AudioManager._music_volume, func(v: float): AudioManager.set_music_volume(v)))
	vb.add_child(_make_volume_row("音效", AudioManager._sfx_volume, func(v: float): AudioManager.set_sfx_volume(v)))

	# 单位血条文字：默认关闭，避免满屏名称/血量文字遮挡战场；需要时手动打开
	vb.add_child(_make_label("🩸 血条文字", UITheme.GOLD))
	vb.add_child(_make_check_row("显示单位名称/血量/生产/升级文字（默认关闭）", GameSettings.show_unit_text,
		func(on: bool): GameSettings.set_unit_text_enabled(on)))

	# 战报筛选：队友国家的建造/升级/生产默认不接收，避免刷掉自己关心的战斗消息
	vb.add_child(_make_label("📢 战报筛选（队友国家）", UITheme.GOLD))
	vb.add_child(_make_check_row("建造完成", GameSettings.alert_friendly_build,
		func(on: bool): GameSettings.alert_friendly_build = on))
	vb.add_child(_make_check_row("升级完成（主城升级始终显示）", GameSettings.alert_friendly_upgrade,
		func(on: bool): GameSettings.alert_friendly_upgrade = on))
	vb.add_child(_make_check_row("训练完成", GameSettings.alert_friendly_produce,
		func(on: bool): GameSettings.alert_friendly_produce = on))

	# 底部：暂停 / 退出
	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 10)
	vb.add_child(bottom)
	_pause_btn = Button.new()
	_pause_btn.custom_minimum_size = Vector2(0, 42)
	_pause_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.apply_primary_button(_pause_btn, UITheme.FONT_MD)
	_pause_btn.pressed.connect(_on_pause_pressed)
	bottom.add_child(_pause_btn)
	if _is_online:
		_pause_btn.disabled = true
		_pause_btn.text = "⏸ 联机不可暂停"
	else:
		_refresh_pause_text()

	var quit_btn := Button.new()
	quit_btn.text = "🚪 退出对局"
	quit_btn.custom_minimum_size = Vector2(0, 42)
	quit_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.apply_danger_button(quit_btn, UITheme.FONT_MD)
	quit_btn.pressed.connect(_on_quit_pressed)
	bottom.add_child(quit_btn)

	if _mobile:
		# 保留桌面控件的结构，只把字号/触控高度/容器间距放大；面板本身可滚动。
		UILayout.scale_widgets_for_mobile(vb)
		if _hint_label:
			_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

# ==================== 画质 ====================
func _on_quality_pressed(level: int) -> void:
	_quality_level = level
	for i in _quality_btns.size():
		_quality_btns[i].button_pressed = (i == level)
	_apply_quality(level)
	if _hint_label:
		_hint_label.text = QUALITY_DESC[level]

func _apply_quality(level: int) -> void:
	# 手动选过画质后关掉后期自动画质，否则每秒都会被改回去
	var bm = _get_battle_manager()
	if bm and "hand_quality_mode" in bm:
		bm.set("hand_quality_mode", true)

	# 帧率上限跟着画质档一起改：只降分辨率不降帧率的话，GPU 照样满负荷跑，
	# 省不下来电。这一项对续航的影响比缩放分辨率更直接。
	if GameManager.has_method("set_quality_fps"):
		GameManager.set_quality_fps(level)

	var vp := get_viewport()
	var scene := get_tree().current_scene
	var light: DirectionalLight3D = null
	var world_env: WorldEnvironment = null
	if scene:
		light = scene.get_node_or_null("DirectionalLight3D") as DirectionalLight3D
		world_env = scene.get_node_or_null("WorldEnvironment") as WorldEnvironment
	match level:
		0:
			if vp: vp.scaling_3d_scale = 0.6
			if light: light.shadow_enabled = false
			if world_env and world_env.environment: world_env.environment.ssao_enabled = false
		1:
			if vp: vp.scaling_3d_scale = 0.8
			if light: light.shadow_enabled = false
			if world_env and world_env.environment: world_env.environment.ssao_enabled = false
		2:
			if vp: vp.scaling_3d_scale = 1.0
			if light:
				light.shadow_enabled = true
				light.directional_shadow_max_distance = 60.0
			if world_env and world_env.environment: world_env.environment.ssao_enabled = false
		_:
			if vp: vp.scaling_3d_scale = 1.0
			if light:
				light.shadow_enabled = true
				light.directional_shadow_max_distance = 120.0
			if world_env and world_env.environment: world_env.environment.ssao_enabled = true

# ==================== 音量 ====================
func _set_master_volume(v: float) -> void:
	var idx := AudioServer.get_bus_index("Master")
	if idx >= 0:
		AudioServer.set_bus_volume_db(idx, linear_to_db(clampf(v, 0.0001, 1.0)))

func _make_volume_row(label_text: String, value: float, setter: Callable) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var lb := Label.new()
	lb.text = label_text
	lb.custom_minimum_size = Vector2(86, 0)
	lb.add_theme_font_size_override("font_size", UITheme.FONT_MD)
	lb.add_theme_color_override("font_color", UITheme.PARCHMENT)
	row.add_child(lb)
	var slider := HSlider.new()
	slider.min_value = 0
	slider.max_value = 100
	slider.step = 1
	slider.value = clampf(value, 0.0, 1.0) * 100.0
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(0, UILayout.dp(26.0) if _mobile else 28)
	row.add_child(slider)
	var pct := Label.new()
	pct.text = "%d%%" % int(slider.value)
	pct.custom_minimum_size = Vector2(52, 0)
	pct.add_theme_font_size_override("font_size", UITheme.FONT_MD)
	pct.add_theme_color_override("font_color", UITheme.PARCHMENT)
	row.add_child(pct)
	slider.value_changed.connect(func(v: float):
		pct.text = "%d%%" % int(v)
		setter.call(clampf(v / 100.0, 0.0, 1.0)))
	return row

# ==================== 暂停 / 退出 ====================
func _on_pause_pressed() -> void:
	if _is_online:
		return
	var tree := get_tree()
	tree.paused = not tree.paused
	_refresh_pause_text()

func _refresh_pause_text() -> void:
	if _pause_btn == null:
		return
	_pause_btn.text = "▶ 继续游戏" if get_tree().paused else "⏸ 暂停游戏"

func _on_close_pressed() -> void:
	# 关闭面板时如果正暂停，顺手恢复游戏
	if get_tree().paused:
		get_tree().paused = false
	queue_free()

func _on_quit_pressed() -> void:
	get_tree().paused = false
	if _is_online:
		# 联机：断开连接并回联机菜单
		var nm = get_node_or_null("/root/NetworkManager")
		if nm and nm.has_method("leave_game"):
			nm.leave_game()
		get_tree().change_scene_to_file("res://scenes/online_menu.tscn")
	else:
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn")

# ==================== 工具 ====================
func _get_battle_manager() -> Node:
	var bm := get_tree().get_first_node_in_group("battle_manager")
	if bm == null:
		bm = get_tree().get_first_node_in_group("online_battle_manager")
	return bm

func _make_label(text: String, color: Color, font_size: int = -1) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size if font_size > 0 else UITheme.FONT_MD)
	l.add_theme_color_override("font_color", color)
	return l

# 战报筛选用的复选框：改完立即生效（HUD 每次播报都会重新读 GameSettings）
func _make_check_row(label_text: String, initial: bool, setter: Callable) -> CheckBox:
	var cb := CheckBox.new()
	cb.text = label_text
	cb.button_pressed = initial
	cb.add_theme_font_size_override("font_size", UITheme.FONT_MD)
	cb.add_theme_color_override("font_color", UITheme.PARCHMENT)
	cb.add_theme_color_override("font_pressed_color", UITheme.GOLD)
	cb.add_theme_color_override("font_hover_color", UITheme.GOLD)
	cb.toggled.connect(func(on: bool): setter.call(on))
	return cb

extends Control
# 对局内设置面板：画质（固定档位，不允许自定义）、音量、暂停、退出
# 单机与联机客户端共用；联机模式下"暂停"不可用（服务器权威，客户端暂停无意义）

const PANEL_W: float = 470.0
# 加了「相机放大倍数」一行后内容约 627px，面板留到 660 让桌面版一屏放得下；
# 真放不下时（更小的窗口）内容区会自动变成可滚动，不会裁掉底部按钮。
const PANEL_H: float = 660.0

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
var _panel: Panel = null
var _threshold_labels: Dictionary = {}   # unit_id -> 数字 Label（军队官阈值行）

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
	# 面板外的暗色遮罩就是“周围任意处”：点这里直接关闭设置，不再要求必须点右上角 ✕。
	dim.gui_input.connect(_on_dim_gui_input)
	add_child(dim)

	var panel := Panel.new()
	_panel = panel
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

	# 内容统一放进滚动容器：手机上必须滚动（屏矮），桌面上内容变多后
	#（画质 + 相机倍数 + 音量 + 血条 + 战报 + 底部按钮）也不会把底部按钮挤出面板。
	var scroll := ScrollContainer.new()
	scroll.name = "SettingsScroll"
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var pad: float = UILayout.dp(5.0) if _mobile else 8.0
	scroll.offset_left = pad
	scroll.offset_right = -pad
	scroll.offset_top = pad
	scroll.offset_bottom = -pad
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	panel.add_child(scroll)
	var content_parent: Control = scroll

	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", int(UILayout.dp(7.0)) if _mobile else 9)
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

	# ── 智能辅助：军需官 / 军队官 ──
	# 这两个开关原来在顶部指令栏，会挤占战场空间；集中到设置里，联机/单机共用。
	vb.add_child(_make_label("🤖 智能辅助", UITheme.GOLD))
	vb.add_child(_make_hint_label("军需官：自动补农民、按缺口分配采集、仓容紧张时补仓库。", UITheme.FONT_SM))
	vb.add_child(_make_check_row("🧺 启用智能军需官", _quartermaster_enabled(),
		func(on: bool): _set_quartermaster(on)))
	vb.add_child(_make_hint_label("军队官：某个兵种少于下面的保底数量时自动补兵，人口满或资源不够会跳过。",
		UITheme.FONT_SM))
	vb.add_child(_make_check_row("🛡 启用智能军队官", _army_officer_enabled(),
		func(on: bool): _set_army_officer(on)))
	_build_officer_thresholds(vb)

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

	# 相机放大倍数：屏幕越小的设备默认放大越多（电脑 100%、平板 112%、手机 125%）
	vb.add_child(_make_label("📷 相机放大倍数", UITheme.GOLD))
	vb.add_child(_make_zoom_row())

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

# ==================== 相机放大倍数 ====================
# 百分比显示：100% = 基准视野；百分比越大单位看着越大、能看到的战场越少。
# 范围收窄到 85%~135%，两端都还算舒服，不会出现贴脸或极远视角。
func _make_zoom_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var lb := Label.new()
	lb.text = "放大倍数"
	lb.custom_minimum_size = Vector2(86, 0)
	lb.add_theme_font_size_override("font_size", UITheme.FONT_MD)
	lb.add_theme_color_override("font_color", UITheme.PARCHMENT)
	row.add_child(lb)

	var slider := HSlider.new()
	slider.min_value = roundf(GameSettings.CAMERA_ZOOM_MIN * 100.0)
	slider.max_value = roundf(GameSettings.CAMERA_ZOOM_MAX * 100.0)
	slider.step = 5.0
	slider.value = clampf(GameSettings.camera_zoom_mult * 100.0, slider.min_value, slider.max_value)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(0, UILayout.dp(26.0) if _mobile else 28)
	row.add_child(slider)

	var pct := Label.new()
	pct.text = "%d%%" % int(slider.value)
	pct.custom_minimum_size = Vector2(52, 0)
	pct.add_theme_font_size_override("font_size", UITheme.FONT_MD)
	pct.add_theme_color_override("font_color", UITheme.GOLD)
	row.add_child(pct)

	slider.value_changed.connect(func(v: float):
		pct.text = "%d%%" % int(v)
		_set_camera_zoom(v / 100.0))
	return row

func _set_camera_zoom(mult: float) -> void:
	GameSettings.camera_zoom_mult = clampf(mult, GameSettings.CAMERA_ZOOM_MIN, GameSettings.CAMERA_ZOOM_MAX)
	# 立即生效：面板直接推给相机，暂停状态下也能看到变化
	for cam in get_tree().get_nodes_in_group("camera_controller"):
		if cam.has_method("apply_zoom_mult"):
			cam.apply_zoom_mult(GameSettings.camera_zoom_mult)
	var scene := get_tree().current_scene
	if scene != null:
		var cam: Node = scene.get_node_or_null("Camera3D")
		if cam != null and cam.has_method("apply_zoom_mult"):
			cam.call("apply_zoom_mult", GameSettings.camera_zoom_mult)

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

# 点击面板外的暗色区域关闭设置；面板内部仍由 Panel/按钮自己消费事件，
# 所以拖动滑条、点复选框、滚动内容都不会误触关闭。
func _on_dim_gui_input(event: InputEvent) -> void:
	# 暗色遮罩和面板有重叠区域时，落在面板矩形内的点击仍然只归面板，
	# 防止事件冒泡/触屏路由把面板内操作误当成“点外面”。
	if _panel != null and is_instance_valid(_panel) and _panel.get_global_rect().has_point(event.position):
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			accept_event()
			_on_close_pressed()
	elif event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		if st.pressed:
			accept_event()
			_on_close_pressed()

func _on_close_pressed() -> void:
	# 关闭设置面板不自动恢复游戏：暂停后必须由玩家按 P 或再次点「继续游戏」手动继续。
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

# ==================== 智能辅助（军需官 / 军队官） ====================
# 军队官不自动生产的单位：农民由军需官补，商队/运输船/官员属于手动决策
const OFFICER_EXCLUDE_IDS: Array[int] = [5, 6, 9, 10, 14, 43, 44, 45, 51, 46, 47, 48, 49, 50]

func _client_input_node() -> Node:
	return get_tree().get_first_node_in_group("client_input")

func _quartermaster_enabled() -> bool:
	if _is_client:
		var ci := _client_input_node()
		return bool(ci.get("quartermaster_on")) if ci != null else false
	var bm := _get_battle_manager()
	return bool(bm.get("local_quartermaster")) if bm != null else false

func _army_officer_enabled() -> bool:
	if _is_client:
		var ci := _client_input_node()
		return bool(ci.get("army_officer_on")) if ci != null else false
	var bm := _get_battle_manager()
	return bool(bm.get("local_army_officer")) if bm != null else false

func _set_quartermaster(on: bool) -> void:
	if _is_client:
		var ci := _client_input_node()
		if ci and ci.has_method("set_quartermaster"):
			ci.set_quartermaster(on)
		return
	var bm := _get_battle_manager()
	if bm and bm.has_method("set_local_quartermaster"):
		bm.set_local_quartermaster(on)
	# 同步 HUD 内部状态：F4 快捷键的提示文字跟设置面板保持一致
	for hud in get_tree().get_nodes_in_group("game_hud"):
		if "quartermaster_on" in hud:
			hud.set("quartermaster_on", on)

func _set_army_officer(on: bool) -> void:
	var candidates := _army_officer_candidates()
	if on:
		# 第一次开启时按推荐表填一遍，避免"开了但全是 0 = 什么都不产"
		GameSettings.ensure_army_officer_defaults(candidates)
		_refresh_threshold_labels()
	var th := GameSettings.army_officer_thresholds.duplicate()
	if _is_client:
		var ci := _client_input_node()
		if ci and ci.has_method("set_army_officer"):
			ci.set_army_officer(on, th)
		return
	var bm := _get_battle_manager()
	if bm and bm.has_method("set_local_army_officer"):
		bm.set_local_army_officer(on)
		if bm.has_method("set_army_officer_thresholds"):
			bm.set_army_officer_thresholds(th)

# 军队官阈值行：每种能造的兵一行，−/数字/＋ 直接调保底数量
func _build_officer_thresholds(parent: Control) -> void:
	_sync_thresholds_from_match()
	var candidates := _army_officer_candidates()
	if candidates.is_empty():
		parent.add_child(_make_hint_label("（还没有能自动生产兵种的建筑，先造兵营等生产建筑）", UITheme.FONT_SM))
		return
	parent.add_child(_make_hint_label("每种兵的保底数量（0 = 不自动生产）", UITheme.FONT_SM))
	var grid := GridContainer.new()
	grid.columns = 1 if _mobile else 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 4)
	parent.add_child(grid)
	for uid in candidates:
		grid.add_child(_make_threshold_row(int(uid)))
	var preset_row := HBoxContainer.new()
	preset_row.add_theme_constant_override("separation", 8)
	parent.add_child(preset_row)
	var rec := Button.new()
	rec.text = "推荐配置"
	rec.custom_minimum_size = Vector2(0, 30)
	rec.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.apply_primary_button(rec, UITheme.FONT_SM)
	rec.pressed.connect(_on_officer_recommend)
	preset_row.add_child(rec)
	var clr := Button.new()
	clr.text = "全部清零"
	clr.custom_minimum_size = Vector2(0, 30)
	clr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.apply_muted_button(clr, UITheme.FONT_SM)
	clr.pressed.connect(_on_officer_clear)
	preset_row.add_child(clr)

func _make_threshold_row(unit_id: int) -> HBoxContainer:
	var cfg := EntityDatabase.get_config(unit_id)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	var icon_px: float = UILayout.dp(20.0) if _mobile else 22.0
	var icon := EntityIcon.make_rect(unit_id, 2, icon_px)
	if icon != null:
		row.add_child(icon)
	var name_lb := Label.new()
	name_lb.text = String(cfg.get("name", "?"))
	name_lb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lb.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	name_lb.add_theme_color_override("font_color", UITheme.PARCHMENT)
	row.add_child(name_lb)
	var minus := _make_step_btn("−")
	minus.pressed.connect(func(): _bump_threshold(unit_id, -1))
	row.add_child(minus)
	var val := Label.new()
	val.text = str(GameSettings.army_officer_threshold(unit_id))
	val.custom_minimum_size = Vector2(28, 0)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	val.add_theme_font_size_override("font_size", UITheme.FONT_MD)
	val.add_theme_color_override("font_color", UITheme.GOLD)
	row.add_child(val)
	_threshold_labels[unit_id] = val
	var plus := _make_step_btn("＋")
	plus.pressed.connect(func(): _bump_threshold(unit_id, 1))
	row.add_child(plus)
	return row

# 可换行的小字说明：设置面板窄，长句必须自动换行，否则会把面板撑宽
func _make_hint_label(text: String, font_size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", UITheme.PARCHMENT)
	return l

func _make_step_btn(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(26, 26)
	UITheme.apply_muted_button(b, UITheme.FONT_MD)
	return b

func _bump_threshold(unit_id: int, delta: int) -> void:
	var v: int = GameSettings.army_officer_threshold(unit_id) + delta
	GameSettings.set_army_officer_threshold(unit_id, v)
	var lb: Label = _threshold_labels.get(unit_id, null)
	if lb != null:
		lb.text = str(GameSettings.army_officer_threshold(unit_id))
	GameSettings.push_army_officer_thresholds()

func _on_officer_recommend() -> void:
	for uid in _army_officer_candidates():
		var rec: int = int(GameSettings.ARMY_OFFICER_RECOMMENDED.get(int(uid), 5))
		GameSettings.set_army_officer_threshold(int(uid), rec)
	_refresh_threshold_labels()
	GameSettings.push_army_officer_thresholds()

func _on_officer_clear() -> void:
	for uid in _army_officer_candidates():
		GameSettings.set_army_officer_threshold(int(uid), 0)
	_refresh_threshold_labels()
	GameSettings.push_army_officer_thresholds()

func _refresh_threshold_labels() -> void:
	for uid in _threshold_labels.keys():
		var lb: Label = _threshold_labels[uid]
		if is_instance_valid(lb):
			lb.text = str(GameSettings.army_officer_threshold(int(uid)))

# 打开面板时把本局已有的阈值同步进 GameSettings，避免面板显示 0 但服务端还在补兵
func _sync_thresholds_from_match() -> void:
	if not GameSettings.army_officer_thresholds.is_empty():
		return
	if _is_client:
		var ci := _client_input_node()
		if ci != null:
			var th: Dictionary = ci.get("army_officer_thresholds")
			if th is Dictionary and not th.is_empty():
				GameSettings.army_officer_thresholds = th.duplicate()
		return
	var bm := _get_battle_manager()
	if bm != null:
		var th2 = bm.get("army_officer_thresholds")
		if th2 is Dictionary and not th2.is_empty():
			GameSettings.army_officer_thresholds = th2.duplicate()

# 单机优先用"自己的建筑真能造"的兵种；联机客户端拿不到服务端建筑列表，退回全部战斗兵种
func _army_officer_candidates() -> Array:
	var bm := _get_battle_manager()
	if bm != null and bm.has_method("army_officer_candidates"):
		# 单机/主机能直接问对局：返回空就说明现在还没有能造的战斗兵种，不要瞎列
		return bm.call("army_officer_candidates")
	var out: Array = []
	for id in EntityDatabase.configs.keys():
		if int(id) in OFFICER_EXCLUDE_IDS:
			continue
		var cfg: Dictionary = EntityDatabase.configs[id]
		if int(cfg.get("type", -1)) != 2:
			continue
		out.append(int(id))
	out.sort()
	return out

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

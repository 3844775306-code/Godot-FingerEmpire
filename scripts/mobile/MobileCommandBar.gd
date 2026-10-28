class_name MobileCommandBar
extends Control

# 右下角指令区：框选模式开关 + 按住旋转按钮 + 五个全局指令（与电脑端按钮一一对应）。
# 所有动作都转发给桌面 HUD 的既有函数，不新增任何玩法逻辑。

const WIDTH_DP: float = 152.0        # 原 190dp 的 80%，给战场多让出一点空间
# 高度压缩：40dp 太高，指令栏上缘会顶到右上角的小地图。
# 按钮 30dp、行距 3dp、内边距 4dp，整体从 240dp 压到约 170dp，上缘抬到 y≈709。
const BTN_H_DP: float = 30.0
const GAP_DP: float = 3.0
const PAD_DP: float = 2.0
const BASE_ROWS: int = 5             # 框选/旋转、两个全选、两个撤退、自动进攻/设置、批量/建造
# 科研模式下底部再加一行「科研树」，高度按实际行数算，避免横屏顶到右上角小地图
func _row_count() -> int:
	return BASE_ROWS + (1 if GameSettings.is_research_mode() else 0)

func _panel_h_dp() -> float:
	var rows := float(_row_count())
	return rows * BTN_H_DP + (rows - 1.0) * GAP_DP + PAD_DP * 2.0

var hud: Node = null
var router: TouchGestureRouter = null

var _box_mode_btn: Button = null
var _rotate_btn: Button = null
var _auto_btn: Button = null
var _batch_produce_btn: Button = null
var _build_btn: Button = null
var _panel: Panel = null
var _research_btn: Button = null

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()

func _build() -> void:
	UILayout.place_dp(self, "br", WIDTH_DP, _panel_h_dp())

	_panel = Panel.new()
	_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(UITheme.INK, 0.72)
	style.border_color = Color(UITheme.GOLD, 0.3)
	style.set_border_width_all(1)
	style.set_corner_radius_all(int(UILayout.dp(8.0)))
	_panel.add_theme_stylebox_override("panel", style)
	add_child(_panel)

	var vb := VBoxContainer.new()
	vb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vb.offset_left = UILayout.dp(6.0)
	vb.offset_right = -UILayout.dp(6.0)
	vb.offset_top = UILayout.dp(PAD_DP)
	vb.offset_bottom = -UILayout.dp(PAD_DP)
	vb.add_theme_constant_override("separation", int(UILayout.dp(GAP_DP)))
	add_child(vb)

	# 框选开关与「按住旋转」按钮并排
	var row0 := _make_row()
	_box_mode_btn = _make_button("框选：关", UILayout.font_dp(9.5))
	_box_mode_btn.toggle_mode = true
	_box_mode_btn.toggled.connect(_on_box_mode_toggled)
	row0.add_child(_box_mode_btn)

	# 按住 = 顺时针缓慢旋转视角，松手即停（按住约 11 秒转一整圈）。
	# 替代原来的「双指：缩放 / 双指：旋转」开关：双指现在固定只管缩放。
	_rotate_btn = _make_button("🔄 按住旋转", UILayout.font_dp(9.5))
	_rotate_btn.button_down.connect(_on_rotate_down)
	_rotate_btn.button_up.connect(_on_rotate_up)
	row0.add_child(_rotate_btn)
	vb.add_child(row0)

	var row1 := _make_row()
	row1.add_child(_make_command_button("屏幕全选", UILayout.font_dp(10.0), "_on_select_screen_pressed"))
	row1.add_child(_make_command_button("全军全选", UILayout.font_dp(10.0), "_on_select_all_pressed"))
	vb.add_child(row1)

	var row2 := _make_row()
	row2.add_child(_make_command_button("屏幕撤退", UILayout.font_dp(10.0), "_on_retreat_screen_pressed"))
	row2.add_child(_make_command_button("全军撤退", UILayout.font_dp(10.0), "_on_retreat_all_pressed"))
	vb.add_child(row2)

	# 自动进攻与设置并排
	var row3 := _make_row()
	_auto_btn = _make_command_button("自动进攻：关", UILayout.font_dp(9.5), "_on_attack_all_pressed")
	row3.add_child(_auto_btn)
	var settings_btn = _make_button("⚙ 设置", UILayout.font_dp(9.5))
	settings_btn.pressed.connect(_on_settings_pressed)
	row3.add_child(settings_btn)
	vb.add_child(row3)
	sync_auto_attack()

	# 手机端替代键盘修饰键的两个入口：批量生产 + 建造菜单
	var row4 := _make_row()
	_batch_produce_btn = _make_button("批量生产：关", UILayout.font_dp(9.5))
	_batch_produce_btn.toggle_mode = true
	_batch_produce_btn.toggled.connect(_on_batch_produce_toggled)
	row4.add_child(_batch_produce_btn)
	_build_btn = _make_button("🏗 建造", UILayout.font_dp(9.5))
	_build_btn.pressed.connect(_on_build_pressed)
	row4.add_child(_build_btn)
	vb.add_child(row4)

	# 科研树归入指令按钮栏：科研模式下多一行整宽按钮，经典模式不出现。
	if GameSettings.is_research_mode():
		var row5 := _make_row()
		_research_btn = _make_button("🔬 科研树", UILayout.font_dp(10.0))
		_research_btn.pressed.connect(func(): _invoke("_open_research_panel"))
		row5.add_child(_research_btn)
		vb.add_child(row5)

	# 智能军需官 / 军队官的开关已移到 ⚙ 设置面板，命令栏不再单占一行
	set_process(true)

# 手机指令栏的科研树按钮同步显示年龄/进度（HUD 每秒调一次）
func set_research_text(text: String) -> void:
	if _research_btn != null and is_instance_valid(_research_btn):
		_research_btn.text = text

func _on_settings_pressed() -> void:
	if hud and hud.has_method("_open_game_settings"):
		hud.call("_open_game_settings")

# 按住旋转：按下开始顺时针缓慢转视角，松手立刻停。
# 按钮被隐藏/面板关掉时也要收尾，否则手指还按着就切界面会一直转个不停。
func _on_rotate_down() -> void:
	_set_hold_rotate(1.0)
	_rotate_btn.add_theme_color_override("font_color", Color(0.55, 0.95, 0.55))

func _on_rotate_up() -> void:
	_set_hold_rotate(0.0)
	_rotate_btn.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))

func _set_hold_rotate(dir: float) -> void:
	var cam := _find_camera()
	if cam != null:
		cam.set_hold_rotate(dir)

func _exit_tree() -> void:
	# 场景切换/面板销毁时兜底停止，避免相机一直转
	_set_hold_rotate(0.0)

# 面板被隐藏（打开设置等）时也要松手，否则旋转会一直持续
func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and not visible:
		_set_hold_rotate(0.0)

# 场景约定：相机为场景根的直接子节点 Camera3D（与 VirtualStick 一致），
# 拿不到就退回整棵树里搜挂载了 CameraController 的相机。
func _find_camera() -> Camera3D:
	var tree := get_tree()
	if tree == null:
		return null
	var scene := tree.current_scene
	if scene == null:
		return null
	var direct := scene.get_node_or_null("Camera3D")
	if direct != null and direct.has_method("set_hold_rotate"):
		return direct as Camera3D
	return _search_camera(scene)

func _search_camera(n: Node) -> Camera3D:
	for c in n.get_children():
		if c.has_method("set_hold_rotate"):
			return c as Camera3D
		var hit := _search_camera(c)
		if hit != null:
			return hit
	return null

func _make_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", int(UILayout.dp(GAP_DP)))
	return row

func _make_button(text: String, font_size: int) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(0.0, UILayout.dp(BTN_H_DP))
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.apply_button(btn, font_size)
	return btn

func _make_command_button(text: String, font_size: int, method: String) -> Button:
	var btn := _make_button(text, font_size)
	btn.pressed.connect(func(): _invoke(method))
	return btn

func _invoke(method: String) -> void:
	if hud and hud.has_method(method):
		hud.call(method)

func _on_box_mode_toggled(pressed: bool) -> void:
	_box_mode_btn.text = "框选：开" if pressed else "框选：关"
	if router:
		router.set_box_select_mode(pressed)

# 批量生产开关：打开后点生产按钮 = 电脑端 Ctrl+生产（同类型建筑一起产）
func _on_batch_produce_toggled(pressed: bool) -> void:
	GameSettings.mobile_batch_produce = pressed
	_batch_produce_btn.text = "批量生产：开" if pressed else "批量生产：关"
	_batch_produce_btn.add_theme_color_override("font_color", Color(0.55, 0.95, 0.55) if pressed else Color(0.9, 0.9, 0.9))

# 建造按钮：和长按地图一样呼出建造菜单；连续建造开关已移入菜单内
func _on_build_pressed() -> void:
	var renderer := get_tree().get_first_node_in_group("client_renderer")
	if renderer and renderer.has_method("open_build_menu_for_mobile"):
		renderer.call("open_build_menu_for_mobile")
		return
	var bm := get_tree().get_first_node_in_group("battle_manager")
	if bm and bm.has_method("open_build_menu_for_mobile"):
		bm.call("open_build_menu_for_mobile")

func sync_auto_attack() -> void:
	if _auto_btn == null:
		return
	var on := false
	if hud and hud.get("auto_attack_on") != null:
		on = bool(hud.get("auto_attack_on"))
	else:
		var ci := get_tree().get_first_node_in_group("client_input")
		if ci and ci.get("auto_attack_on") != null:
			on = bool(ci.get("auto_attack_on"))
	_auto_btn.text = "自动进攻：开" if on else "自动进攻：关"
	_auto_btn.add_theme_color_override("font_color", Color(0.55, 0.95, 0.55) if on else Color(0.9, 0.9, 0.9))

func _process(_delta: float) -> void:
	sync_auto_attack()

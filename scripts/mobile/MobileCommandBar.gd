class_name MobileCommandBar
extends Control

# 右下角指令区：框选模式开关 + 双指手势模式开关 + 五个全局指令（与电脑端按钮一一对应）。
# 所有动作都转发给桌面 HUD 的既有函数，不新增任何玩法逻辑。

const WIDTH_DP: float = 152.0        # 原 190dp 的 80%，给战场多让出一点空间
# 高度压缩：40dp 太高，指令栏上缘会顶到右上角的小地图。
# 按钮 30dp、行距 3dp、内边距 4dp，整体从 240dp 压到约 170dp，上缘抬到 y≈709。
const BTN_H_DP: float = 30.0
const GAP_DP: float = 3.0
const PAD_DP: float = 4.0
const ROW_COUNT: int = 5             # 框选/双指、两个全选、两个撤退、自动进攻/设置、批量/连续
# 面板高度按内容自适应：5 行按钮 + 4 条行间距 + 上下内边距
const PANEL_H_DP: float = ROW_COUNT * BTN_H_DP + (ROW_COUNT - 1) * GAP_DP + PAD_DP * 2.0

var hud: Node = null
var router: TouchGestureRouter = null

var _box_mode_btn: Button = null
var _two_finger_btn: Button = null
var _auto_btn: Button = null
var _batch_produce_btn: Button = null
var _cont_build_btn: Button = null
var _panel: Panel = null

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()

func _build() -> void:
	UILayout.place_dp(self, "br", WIDTH_DP, PANEL_H_DP)

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

	# 框选开关与双指手势模式开关并排
	var row0 := _make_row()
	_box_mode_btn = _make_button("框选：关", UILayout.font_dp(9.5))
	_box_mode_btn.toggle_mode = true
	_box_mode_btn.toggled.connect(_on_box_mode_toggled)
	row0.add_child(_box_mode_btn)

	# 双指手势模式开关：按下 = 旋转模式，弹起 = 缩放模式（默认）
	_two_finger_btn = _make_button("双指：缩放", UILayout.font_dp(9.5))
	_two_finger_btn.toggle_mode = true
	_two_finger_btn.button_pressed = GameSettings.mobile_two_finger_mode == GameSettings.TwoFingerMode.ROTATE
	_two_finger_btn.toggled.connect(_on_two_finger_mode_toggled)
	row0.add_child(_two_finger_btn)
	_sync_two_finger_btn()
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

	# 手机端替代键盘修饰键的两个开关
	var row4 := _make_row()
	_batch_produce_btn = _make_button("批量生产：关", UILayout.font_dp(9.5))
	_batch_produce_btn.toggle_mode = true
	_batch_produce_btn.toggled.connect(_on_batch_produce_toggled)
	row4.add_child(_batch_produce_btn)
	_cont_build_btn = _make_button("连续建造：关", UILayout.font_dp(9.5))
	_cont_build_btn.toggle_mode = true
	_cont_build_btn.toggled.connect(_on_cont_build_toggled)
	row4.add_child(_cont_build_btn)
	vb.add_child(row4)
	set_process(true)

func _on_settings_pressed() -> void:
	if hud and hud.has_method("_open_game_settings"):
		hud.call("_open_game_settings")

# 双指手势模式开关：按下（绿色）= 旋转模式，弹起 = 缩放模式（默认）。
# 写回 GameSettings 后立刻生效，CameraController 每个手势事件都会重新读取模式。
func _on_two_finger_mode_toggled(pressed: bool) -> void:
	GameSettings.mobile_two_finger_mode = GameSettings.TwoFingerMode.ROTATE if pressed else GameSettings.TwoFingerMode.ZOOM
	_sync_two_finger_btn()

func _sync_two_finger_btn() -> void:
	if _two_finger_btn == null:
		return
	var rotate_mode: bool = GameSettings.mobile_two_finger_mode == GameSettings.TwoFingerMode.ROTATE
	_two_finger_btn.text = "双指：旋转" if rotate_mode else "双指：缩放"
	_two_finger_btn.add_theme_color_override("font_color", Color(0.55, 0.95, 0.55) if rotate_mode else Color(0.9, 0.9, 0.9))

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

# 连续建造开关：打开后放置建筑不退出建造模式 = 电脑端按住 Shift
func _on_cont_build_toggled(pressed: bool) -> void:
	GameSettings.mobile_continuous_build = pressed
	_cont_build_btn.text = "连续建造：开" if pressed else "连续建造：关"
	_cont_build_btn.add_theme_color_override("font_color", Color(0.55, 0.95, 0.55) if pressed else Color(0.9, 0.9, 0.9))
	var bm := get_tree().get_first_node_in_group("battle_manager")
	if bm:
		bm.mobile_keep_build_mode = pressed

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

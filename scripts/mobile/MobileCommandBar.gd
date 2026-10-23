class_name MobileCommandBar
extends Control

# 右下角指令区：框选模式开关 + 五个全局指令（与电脑端按钮一一对应）。
# 所有动作都转发给桌面 HUD 的既有函数，不新增任何玩法逻辑。

const WIDTH_DP: float = 176.0
const BTN_H_DP: float = 36.0
const GAP_DP: float = 5.0

var hud: Node = null
var router: TouchGestureRouter = null

var _box_mode_btn: Button = null
var _auto_btn: Button = null
var _panel: Panel = null

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()

func _build() -> void:
	UILayout.place_dp(self, "br", WIDTH_DP, 150.0)

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
	vb.offset_top = UILayout.dp(5.0)
	vb.offset_bottom = -UILayout.dp(5.0)
	vb.add_theme_constant_override("separation", int(UILayout.dp(GAP_DP)))
	add_child(vb)

	_box_mode_btn = _make_button("框选：关", 13)
	_box_mode_btn.toggle_mode = true
	_box_mode_btn.toggled.connect(_on_box_mode_toggled)
	vb.add_child(_box_mode_btn)

	var row1 := _make_row()
	row1.add_child(_make_command_button("屏幕全选", 13, "_on_select_screen_pressed"))
	row1.add_child(_make_command_button("全军全选", 13, "_on_select_all_pressed"))
	vb.add_child(row1)

	var row2 := _make_row()
	row2.add_child(_make_command_button("屏幕撤退", 13, "_on_retreat_screen_pressed"))
	row2.add_child(_make_command_button("全军撤退", 13, "_on_retreat_all_pressed"))
	vb.add_child(row2)

	_auto_btn = _make_command_button("自动进攻：关", 13, "_on_attack_all_pressed")
	vb.add_child(_auto_btn)
	sync_auto_attack()
	set_process(true)

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

class_name MobileBuildPlacementOverlay
extends Control

# 手机端居中建造浮层：预览固定在屏幕中央，单指滑动地图移动预览位置，
# 预览下方提供「勾」确认建造和「叉」取消。连续建造开关打开时，
# 勾选后保持预览与按钮，可继续放置下一个建筑。

signal confirmed
signal cancelled

const PANEL_W_DP: float = 286.0
const PANEL_TOP_RATIO: float = 0.625
const PANEL_H_DP: float = 118.0
const BTN_W_DP: float = 104.0
const BTN_H_DP: float = 52.0

var _panel: PanelContainer = null
var _hint_label: Label = null
var _mode_label: Label = null
var _check_btn: Button = null
var _cancel_btn: Button = null

func _ready() -> void:
	name = "BuildPlacementOverlay"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 40
	visible = false
	_build_panel()

func _build_panel() -> void:
	_panel = PanelContainer.new()
	_panel.name = "Panel"
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.add_theme_stylebox_override("panel", UITheme.card_style(UITheme.GOLD))
	var w: float = UILayout.dp(PANEL_W_DP)
	UILayout.place(_panel, 0.5, PANEL_TOP_RATIO,
		-w * 0.5, 0.0, w * 0.5, UILayout.dp(PANEL_H_DP))
	add_child(_panel)

	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", int(UILayout.dp(12.0)))
	margin.add_theme_constant_override("margin_right", int(UILayout.dp(12.0)))
	margin.add_theme_constant_override("margin_top", int(UILayout.dp(8.0)))
	margin.add_theme_constant_override("margin_bottom", int(UILayout.dp(10.0)))
	_panel.add_child(margin)

	var vb := VBoxContainer.new()
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_theme_constant_override("separation", int(UILayout.dp(3.0)))
	margin.add_child(vb)

	_hint_label = Label.new()
	_hint_label.text = "拖动地图移动建造位置"
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint_label.add_theme_font_size_override("font_size", UILayout.font_dp(11.0))
	_hint_label.add_theme_color_override("font_color", UITheme.PARCHMENT)
	vb.add_child(_hint_label)

	_mode_label = Label.new()
	_mode_label.text = ""
	_mode_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_mode_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mode_label.add_theme_font_size_override("font_size", UILayout.font_dp(10.0))
	vb.add_child(_mode_label)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", int(UILayout.dp(18.0)))
	vb.add_child(row)

	_cancel_btn = Button.new()
	_cancel_btn.text = "✕"
	_cancel_btn.focus_mode = Control.FOCUS_NONE
	_cancel_btn.custom_minimum_size = Vector2(UILayout.dp(BTN_W_DP), UILayout.dp(BTN_H_DP))
	UITheme.apply_danger_button(_cancel_btn, UILayout.font_dp(24.0))
	_cancel_btn.pressed.connect(func() -> void: cancelled.emit())
	row.add_child(_cancel_btn)

	_check_btn = Button.new()
	_check_btn.text = "✓"
	_check_btn.focus_mode = Control.FOCUS_NONE
	_check_btn.custom_minimum_size = Vector2(UILayout.dp(BTN_W_DP), UILayout.dp(BTN_H_DP))
	UITheme.apply_primary_button(_check_btn, UILayout.font_dp(24.0))
	_check_btn.pressed.connect(func() -> void: confirmed.emit())
	row.add_child(_check_btn)

func set_active(active: bool, continuous: bool) -> void:
	if visible != active:
		visible = active
	if not active:
		return
	var on_color := Color(0.55, 0.95, 0.55)
	var off_color := Color(0.72, 0.70, 0.66)
	if continuous:
		_mode_label.text = "连续建造：开 · 放完继续"
		_mode_label.add_theme_color_override("font_color", on_color)
	else:
		_mode_label.text = "连续建造：关 · 放完退出"
		_mode_label.add_theme_color_override("font_color", off_color)

func is_point_inside(pos: Vector2) -> bool:
	return visible and _panel != null and is_instance_valid(_panel) \
		and _panel.get_global_rect().has_point(pos)


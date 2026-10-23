class_name MobileResourceCapsule
extends Control

# 左上角资源胶囊：
#   收起态一行显示五项资源 + 人口 + 时间 + 统计按钮；
#   点按胶囊主体展开「采集人数 / 收入速率」详情行，再点一次收起。

signal stats_pressed()

const RES_KEYS: Array = ["gold", "wood", "stone", "food", "oil"]
const ROW_H_DP: float = 36.0
const EXPANDED_H_DP: float = 62.0
const WIDTH_DP: float = 300.0

var expanded: bool = false

var _panel: Panel = null
var _vbox: VBoxContainer = null
var _detail_row: HBoxContainer = null
var _res_value_labels: Dictionary = {}
var _res_detail_labels: Dictionary = {}
var _pop_label: Label = null
var _time_label: Label = null
var _chart_btn: Button = null
var _res_colors: Dictionary = {}

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()

func _build() -> void:
	UILayout.place_dp(self, "tl", WIDTH_DP, ROW_H_DP)
	_res_colors = {
		"gold": UITheme.RES_GOLD,
		"wood": UITheme.RES_WOOD,
		"stone": UITheme.RES_STONE,
		"food": UITheme.RES_FOOD,
		"oil": UITheme.RES_OIL,
	}

	_panel = Panel.new()
	_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(UITheme.INK, 0.88)
	style.border_color = Color(UITheme.GOLD, 0.45)
	style.set_border_width_all(1)
	style.set_corner_radius_all(int(UILayout.dp(8.0)))
	_panel.add_theme_stylebox_override("panel", style)
	add_child(_panel)

	_vbox = VBoxContainer.new()
	_vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_vbox.offset_left = UILayout.dp(8.0)
	_vbox.offset_right = -UILayout.dp(6.0)
	_vbox.offset_top = UILayout.dp(3.0)
	_vbox.add_theme_constant_override("separation", 1)
	_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_vbox)

	var main_row := HBoxContainer.new()
	main_row.add_theme_constant_override("separation", int(UILayout.dp(4.0)))
	main_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vbox.add_child(main_row)

	for key in RES_KEYS:
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 0)
		col.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var name_lbl := Label.new()
		name_lbl.text = String(UITheme.RESOURCE_ICONS.get(key, "◆"))
		name_lbl.add_theme_font_size_override("font_size", 11)
		name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		col.add_child(name_lbl)
		var value_lbl := Label.new()
		value_lbl.text = "0"
		value_lbl.add_theme_font_size_override("font_size", 15)
		value_lbl.add_theme_color_override("font_color", Color.WHITE)
		value_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		col.add_child(value_lbl)
		_res_value_labels[key] = value_lbl
		main_row.add_child(col)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	main_row.add_child(spacer)

	_pop_label = Label.new()
	_pop_label.text = "👥0/0"
	_pop_label.add_theme_font_size_override("font_size", 13)
	_pop_label.add_theme_color_override("font_color", Color.WHITE)
	_pop_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	main_row.add_child(_pop_label)

	_time_label = Label.new()
	_time_label.text = "00:00"
	_time_label.add_theme_font_size_override("font_size", 13)
	_time_label.add_theme_color_override("font_color", Color(UITheme.PARCHMENT, 0.9))
	_time_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	main_row.add_child(_time_label)

	_chart_btn = Button.new()
	_chart_btn.text = "📊"
	_chart_btn.custom_minimum_size = Vector2(UILayout.dp(30.0), UILayout.dp(30.0))
	_chart_btn.add_theme_font_size_override("font_size", 15)
	_chart_btn.mouse_filter = Control.MOUSE_FILTER_STOP
	_chart_btn.pressed.connect(func(): stats_pressed.emit())
	main_row.add_child(_chart_btn)

	_detail_row = HBoxContainer.new()
	_detail_row.add_theme_constant_override("separation", int(UILayout.dp(4.0)))
	_detail_row.visible = false
	_detail_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vbox.add_child(_detail_row)

	for key in RES_KEYS:
		var detail := Label.new()
		detail.text = "0人 +0.0/s"
		detail.add_theme_font_size_override("font_size", 10)
		detail.add_theme_color_override("font_color", Color(UITheme.PARCHMENT, 0.75))
		detail.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_res_detail_labels[key] = detail
		_detail_row.add_child(detail)

	set_process(false)

func _gui_input(event: InputEvent) -> void:
	# 点按胶囊主体切换详情行（不吞掉子按钮的事件）
	if event is InputEventScreenTouch and event.pressed:
		_toggle_expanded()
		accept_event()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_toggle_expanded()
		accept_event()

func _toggle_expanded() -> void:
	expanded = not expanded
	_detail_row.visible = expanded
	if expanded:
		UILayout.place_dp(self, "tl", WIDTH_DP, EXPANDED_H_DP)
	else:
		UILayout.place_dp(self, "tl", WIDTH_DP, ROW_H_DP)

func apply_data(resources: Dictionary, population: Dictionary, limits: Dictionary = {}) -> void:
	for key in RES_KEYS:
		var lbl: Label = _res_value_labels.get(key)
		if lbl == null:
			continue
		lbl.text = "%d" % int(resources.get(key, 0))
		lbl.add_theme_color_override("font_color", _res_colors.get(key, Color.WHITE))
	if _pop_label:
		_pop_label.text = "👥%d/%d" % [int(population.get("current", 0)), int(population.get("max", 0))]

func apply_rates(gather_counts: Dictionary, income_rate: Dictionary) -> void:
	for key in RES_KEYS:
		var lbl: Label = _res_detail_labels.get(key)
		if lbl == null:
			continue
		var gather := int(gather_counts.get(key, 0))
		var rate := float(income_rate.get(key, 0.0))
		lbl.text = "%d人 %+.1f/s" % [gather, rate]

func set_time_text(text: String) -> void:
	if _time_label:
		_time_label.text = text

class_name BattleStatsPanel
extends Control

const BattleStatsData = preload("res://scripts/core/BattleStats.gd")
const BattleStatsChartScript = preload("res://scripts/ui/BattleStatsChart.gd")

var stats = null
var mode: String = "nation"
var metric: String = "gathered"

var result_label: Label = null
var duration_label: Label = null
var chart_title: Label = null
var chart = null
var legend_box: VBoxContainer = null
var legend_title: Label = null
var mode_buttons: Dictionary = {}
var metric_buttons: Dictionary = {}
var restart_scene_path: String = "res://scenes/rts_battle.tscn"
var _result_panel: Panel = null
var _mobile: bool = false
var _perf_fps_chart = null
var _perf_units_chart = null
var _perf_fps_summary: Label = null
var _perf_units_summary: Label = null
var _astar_summary: Label = null

# 手机端字号放大倍率：设计空间 2400 宽 ≈ 674dp，桌面 13 号字只有约 3.6dp，按 2.6 倍放到约 9.5dp
func _fs(base: int) -> int:
	return int(round(float(base) * 2.6)) if _mobile else base

func _init() -> void:
	_build_ui()

func _ready() -> void:
	resized.connect(_fit_panel)
	_fit_panel()

func _fit_panel() -> void:
	if _result_panel == null:
		return
	var w := minf(1900.0, maxf(900.0, size.x - 80.0))
	var h := minf(1140.0, maxf(620.0, size.y - 80.0))
	if _mobile:
		# 手机端铺满全屏，空间都让给放大的文字
		w = size.x - UILayout.dp(12.0)
		h = size.y - UILayout.dp(12.0)
	_result_panel.position = (size - Vector2(w, h)) * 0.5
	_result_panel.size = Vector2(w, h)

func _build_ui() -> void:
	_mobile = InputSource.use_mobile_ui()
	name = "BattleStatsPanel"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	z_index = 500
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false

	var dim := ColorRect.new()
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.005, 0.008, 0.018, 0.82)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var panel := Panel.new()
	panel.name = "ResultPanel"
	panel.anchor_left = 0.0
	panel.anchor_top = 0.0
	panel.anchor_right = 0.0
	panel.anchor_bottom = 0.0
	panel.position = Vector2(250, 130)
	panel.size = Vector2(1900, 1140)
	_result_panel = panel
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.028, 0.04, 0.07, 0.98)
	style.border_color = Color(0.32, 0.55, 0.82, 0.9)
	style.border_width_left = 2
	style.border_width_right = 2
	style.border_width_top = 2
	style.border_width_bottom = 2
	style.corner_radius_top_left = 12
	style.corner_radius_top_right = 12
	style.corner_radius_bottom_left = 12
	style.corner_radius_bottom_right = 12
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 28)
	margin.add_theme_constant_override("margin_right", 28)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_bottom", 18)
	panel.add_child(margin)

	var root := VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_theme_constant_override("separation", int(UILayout.dp(6.0)) if _mobile else 12)
	if _mobile:
		# 手机上内容超过一屏，整页可上下滑动
		var page := ScrollContainer.new()
		page.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		page.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
		page.size_flags_vertical = Control.SIZE_EXPAND_FILL
		margin.add_child(page)
		page.add_child(root)
	else:
		margin.add_child(root)

	# ── 标题栏 ──
	var header: Container
	if _mobile:
		# 窄屏放不下标题+时长+三个按钮，用流式容器自动换行
		var flow := HFlowContainer.new()
		flow.add_theme_constant_override("h_separation", int(UILayout.dp(5.0)))
		flow.add_theme_constant_override("v_separation", int(UILayout.dp(4.0)))
		header = flow
	else:
		var hb := HBoxContainer.new()
		hb.add_theme_constant_override("separation", 18)
		header = hb
	root.add_child(header)

	var title_box := VBoxContainer.new()
	title_box.add_theme_constant_override("separation", 0)
	header.add_child(title_box)

	var title := Label.new()
	title.text = "🏆  战 斗 结 算"
	title.add_theme_font_size_override("font_size", _fs(38))
	title.add_theme_color_override("font_color", Color(1.0, 0.84, 0.38))
	title_box.add_child(title)

	result_label = Label.new()
	result_label.text = "战斗结束"
	result_label.add_theme_font_size_override("font_size", _fs(28))
	result_label.add_theme_color_override("font_color", Color(0.82, 0.9, 1.0))
	title_box.add_child(result_label)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)

	duration_label = Label.new()
	duration_label.text = "对局时长 00:00"
	duration_label.add_theme_font_size_override("font_size", _fs(20))
	duration_label.add_theme_color_override("font_color", Color(0.66, 0.76, 0.9))
	duration_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(duration_label)

	var close_btn := _make_button("关闭", 94)
	close_btn.pressed.connect(func() -> void: visible = false)
	header.add_child(close_btn)
	var restart_btn := _make_button("重新开始", 128)
	restart_btn.pressed.connect(func() -> void: get_tree().change_scene_to_file(restart_scene_path))
	header.add_child(restart_btn)
	var menu_btn := _make_button("返回主菜单", 138)
	menu_btn.pressed.connect(func() -> void: get_tree().change_scene_to_file("res://scenes/main_menu.tscn"))
	header.add_child(menu_btn)

	var line := HSeparator.new()
	root.add_child(line)

	# ── 控制栏 ──
	var controls: Container
	if _mobile:
		var cflow := HFlowContainer.new()
		cflow.add_theme_constant_override("h_separation", int(UILayout.dp(4.0)))
		cflow.add_theme_constant_override("v_separation", int(UILayout.dp(3.0)))
		controls = cflow
	else:
		var chb := HBoxContainer.new()
		chb.add_theme_constant_override("separation", 10)
		controls = chb
	root.add_child(controls)

	var mode_label := Label.new()
	mode_label.text = "查看方式"
	mode_label.add_theme_font_size_override("font_size", _fs(17))
	mode_label.add_theme_color_override("font_color", Color(0.78, 0.86, 0.98))
	mode_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	controls.add_child(mode_label)

	var group := ButtonGroup.new()
	for item in [["nation", "按国家"], ["team", "按阵营"]]:
		var b := _make_button(item[1], 116)
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = item[0] == mode
		b.pressed.connect(_on_mode_pressed.bind(item[0]))
		mode_buttons[item[0]] = b
		controls.add_child(b)

	var vline := VSeparator.new()
	controls.add_child(vline)
	var metric_label := Label.new()
	metric_label.text = "指标"
	metric_label.add_theme_font_size_override("font_size", _fs(17))
	metric_label.add_theme_color_override("font_color", Color(0.78, 0.86, 0.98))
	metric_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	controls.add_child(metric_label)

	var metric_grid := GridContainer.new()
	metric_grid.columns = 3 if _mobile else 4
	metric_grid.add_theme_constant_override("h_separation", 8)
	metric_grid.add_theme_constant_override("v_separation", 6)
	metric_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	controls.add_child(metric_grid)
	var metric_group := ButtonGroup.new()
	for m in BattleStatsData.METRICS:
		var b := _make_button(m["short"], 156)
		b.toggle_mode = true
		b.button_group = metric_group
		b.button_pressed = m["id"] == metric
		b.pressed.connect(_on_metric_pressed.bind(m["id"]))
		metric_buttons[m["id"]] = b
		metric_grid.add_child(b)

	# ── 图表与图例 ──
	var body: Container
	if _mobile:
		# 手机上图表与图例上下堆叠，图例单独一屏高
		var bv := VBoxContainer.new()
		bv.add_theme_constant_override("separation", int(UILayout.dp(5.0)))
		body = bv
	else:
		var bh := HBoxContainer.new()
		bh.add_theme_constant_override("separation", 18)
		bh.size_flags_vertical = Control.SIZE_EXPAND_FILL
		body = bh
	root.add_child(body)

	var chart_box := VBoxContainer.new()
	chart_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chart_box.add_theme_constant_override("separation", 6)
	body.add_child(chart_box)

	chart_title = Label.new()
	chart_title.text = "资源累计获取  ·  按国家"
	chart_title.add_theme_font_size_override("font_size", _fs(22))
	chart_title.add_theme_color_override("font_color", Color(0.9, 0.95, 1.0))
	chart_box.add_child(chart_title)

	chart = BattleStatsChartScript.new()
	chart.custom_minimum_size = Vector2(0, UILayout.dp(165.0)) if _mobile else Vector2(760, 420)
	chart.size_flags_vertical = Control.SIZE_EXPAND_FILL
	chart_box.add_child(chart)

	var side := VBoxContainer.new()
	side.custom_minimum_size = Vector2(0, 0) if _mobile else Vector2(420, 0)
	side.add_theme_constant_override("separation", 8)
	body.add_child(side)

	legend_title = Label.new()
	legend_title.text = "图例 / 最终值"
	legend_title.add_theme_font_size_override("font_size", _fs(20))
	legend_title.add_theme_color_override("font_color", Color(0.92, 0.96, 1.0))
	side.add_child(legend_title)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	if _mobile:
		scroll.custom_minimum_size = Vector2(0, UILayout.dp(110.0))
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	side.add_child(scroll)

	legend_box = VBoxContainer.new()
	legend_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	legend_box.add_theme_constant_override("separation", 7)
	scroll.add_child(legend_box)

	var hint := Label.new()
	hint.text = "曲线每 5 秒采样一次。累计指标只增不减；实时指标显示该时刻的总量。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", _fs(13))
	hint.add_theme_color_override("font_color", Color(0.58, 0.68, 0.82))
	side.add_child(hint)

	# ── 性能专栏：帧率 / 总单位数 ──
	var perf_panel := PanelContainer.new()
	perf_panel.custom_minimum_size = Vector2(0, UILayout.dp(232.0)) if _mobile else Vector2(0, 266)
	perf_panel.size_flags_vertical = Control.SIZE_SHRINK_END
	var perf_style := StyleBoxFlat.new()
	perf_style.bg_color = Color(0.024, 0.036, 0.06, 0.96)
	perf_style.border_color = Color(0.20, 0.34, 0.50, 0.85)
	perf_style.border_width_left = 1
	perf_style.border_width_right = 1
	perf_style.border_width_top = 1
	perf_style.border_width_bottom = 1
	perf_style.corner_radius_top_left = 8
	perf_style.corner_radius_top_right = 8
	perf_style.corner_radius_bottom_left = 8
	perf_style.corner_radius_bottom_right = 8
	perf_panel.add_theme_stylebox_override("panel", perf_style)
	root.add_child(perf_panel)

	var perf_margin := MarginContainer.new()
	perf_margin.add_theme_constant_override("margin_left", 10)
	perf_margin.add_theme_constant_override("margin_right", 10)
	perf_margin.add_theme_constant_override("margin_top", 6)
	perf_margin.add_theme_constant_override("margin_bottom", 6)
	perf_panel.add_child(perf_margin)

	var perf_root := VBoxContainer.new()
	perf_root.add_theme_constant_override("separation", 4)
	perf_margin.add_child(perf_root)

	var perf_header := HBoxContainer.new()
	perf_header.add_theme_constant_override("separation", 12)
	perf_root.add_child(perf_header)

	var perf_title := Label.new()
	perf_title.text = "⚙ 性能专栏"
	perf_title.add_theme_font_size_override("font_size", _fs(18))
	perf_title.add_theme_color_override("font_color", Color(1.0, 0.84, 0.38))
	perf_header.add_child(perf_title)

	var perf_hint := Label.new()
	perf_hint.text = "帧率 / 单位数每 5 秒采样 · A* 为全场累计"
	perf_hint.add_theme_font_size_override("font_size", _fs(12))
	perf_hint.add_theme_color_override("font_color", Color(0.58, 0.68, 0.82))
	perf_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	perf_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	perf_header.add_child(perf_hint)

	var perf_row := HBoxContainer.new()
	perf_row.add_theme_constant_override("separation", 14)
	perf_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	perf_root.add_child(perf_row)

	var fps_box: Dictionary = _build_perf_chart_box(perf_row, "帧率 FPS（周期均值）", Color(0.42, 0.92, 0.58))
	_perf_fps_chart = fps_box["chart"]
	_perf_fps_summary = fps_box["summary"]

	var units_box: Dictionary = _build_perf_chart_box(perf_row, "总单位数（军队 + 建筑）", Color(0.32, 0.78, 0.98))
	_perf_units_chart = units_box["chart"]
	_perf_units_summary = units_box["summary"]

	# A* 栏：寻路是全局统计，不按国家/阵营拆分；显示全场累计与每秒均值/峰值
	var astar_row := HBoxContainer.new()
	astar_row.add_theme_constant_override("separation", 10)
	perf_root.add_child(astar_row)
	var astar_title := Label.new()
	astar_title.text = "🧭 A* 寻路"
	astar_title.add_theme_font_size_override("font_size", _fs(15))
	astar_title.add_theme_color_override("font_color", Color(0.62, 0.86, 1.0))
	astar_row.add_child(astar_title)
	_astar_summary = Label.new()
	_astar_summary.text = "暂无 A* 调用数据"
	_astar_summary.add_theme_font_size_override("font_size", _fs(13))
	_astar_summary.add_theme_color_override("font_color", Color(0.70, 0.80, 0.92))
	_astar_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_astar_summary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	astar_row.add_child(_astar_summary)

func _build_perf_chart_box(parent: Control, title_text: String, color: Color) -> Dictionary:
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 2)
	parent.add_child(box)

	var title := Label.new()
	title.text = title_text
	title.add_theme_font_size_override("font_size", _fs(14))
	title.add_theme_color_override("font_color", color)
	box.add_child(title)

	var perf_chart = BattleStatsChartScript.new()
	perf_chart.custom_minimum_size = Vector2(0, UILayout.dp(105.0)) if _mobile else Vector2(0, 150)
	perf_chart.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	perf_chart.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(perf_chart)

	var summary := Label.new()
	summary.text = "暂无数据"
	summary.add_theme_font_size_override("font_size", _fs(13))
	summary.add_theme_color_override("font_color", Color(0.70, 0.80, 0.92))
	box.add_child(summary)

	return { "chart": perf_chart, "summary": summary }

func _make_button(text: String, min_width: float) -> Button:
	var b := Button.new()
	b.text = text
	if _mobile:
		b.custom_minimum_size = Vector2(min_width * 1.7, UILayout.dp(34.0))
	else:
		b.custom_minimum_size = Vector2(min_width, 36)
	b.add_theme_font_size_override("font_size", _fs(16))
	b.focus_mode = Control.FOCUS_NONE
	return b

func show_stats(p_stats) -> void:
	stats = p_stats
	if stats:
		var mins := int(stats.duration / 60.0)
		var secs := int(stats.duration) % 60
		duration_label.text = "对局时长 %02d:%02d" % [mins, secs]
	_refresh()
	visible = true

func _on_mode_pressed(p_mode: String) -> void:
	mode = p_mode
	_refresh()

func _on_metric_pressed(p_metric: String) -> void:
	metric = p_metric
	_refresh()

func _refresh() -> void:
	if stats == null:
		return
	var def: Dictionary = stats.get_metric(metric)
	var series: Array = stats.get_series(metric, mode)
	chart.set_data(series, stats.duration, metric)
	var mode_name := "按国家" if mode == "nation" else "按阵营"
	chart_title.text = "%s  ·  %s" % [def["label"], mode_name]
	for id in mode_buttons.keys():
		mode_buttons[id].button_pressed = id == mode
	for id in metric_buttons.keys():
		metric_buttons[id].button_pressed = id == metric
	_rebuild_legend(series)
	_refresh_performance()

func _refresh_performance() -> void:
	if stats == null or _perf_fps_chart == null or _perf_units_chart == null:
		return
	var fps_series: Array = stats.get_performance_series("fps")
	var units_series: Array = stats.get_performance_series("units")
	_perf_fps_chart.set_data(fps_series, stats.duration, "fps")
	_perf_units_chart.set_data(units_series, stats.duration, "units")
	_perf_fps_summary.text = _perf_summary(fps_series, "fps", true)
	_perf_units_summary.text = _perf_summary(units_series, "units", false)
	_refresh_astar_summary()

func _refresh_astar_summary() -> void:
	if _astar_summary == null or stats == null:
		return
	var a: Dictionary = stats.get_astar_stats()
	if a.is_empty():
		_astar_summary.text = "暂无 A* 调用数据"
		return
	var calls: int = int(a.get("calls_total", 0))
	var alloc: int = int(a.get("alloc_total", 0))
	var avg: float = float(a.get("avg_calls_per_sec", 0.0))
	var peak: int = int(a.get("peak_calls_per_sec", 0))
	_astar_summary.text = "总调用 %d 次 · 预算分配 %d 次 · 平均 %.1f 次/秒 · 峰值 %d 次/秒" % [
		calls, alloc, avg, peak
	]

func _perf_summary(series: Array, metric_id: String, with_min: bool) -> String:
	if series.is_empty():
		return "暂无数据"
	var points: Array = series[0].get("points", [])
	if points.is_empty():
		return "暂无数据"
	var total: float = 0.0
	var lowest: float = INF
	var peak: float = -INF
	for p in points:
		var y: float = float(p.get("y", 0.0))
		total += y
		lowest = minf(lowest, y)
		peak = maxf(peak, y)
	if with_min:
		var avg: float = total / float(points.size())
		return "均值 %s · 最低 %s" % [
			stats.format_value(metric_id, avg),
			stats.format_value(metric_id, lowest),
		]
	return "峰值 %s · 最终 %s" % [
		stats.format_value(metric_id, peak),
		stats.format_value(metric_id, float(series[0].get("final", 0.0))),
	]

func _rebuild_legend(series: Array) -> void:
	for c in legend_box.get_children():
		c.queue_free()
	if series.is_empty():
		var empty := Label.new()
		empty.text = "暂无数据"
		empty.add_theme_font_size_override("font_size", _fs(16))
		empty.add_theme_color_override("font_color", Color(0.6, 0.68, 0.8))
		legend_box.add_child(empty)
		return
	for s in series:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		legend_box.add_child(row)

		var swatch := ColorRect.new()
		swatch.custom_minimum_size = Vector2(16, 16)
		swatch.color = s.get("color", Color.WHITE)
		swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(swatch)

		var name_label := Label.new()
		name_label.text = String(s.get("name", "?"))
		name_label.add_theme_font_size_override("font_size", _fs(17))
		name_label.add_theme_color_override("font_color", Color(0.9, 0.95, 1.0))
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(name_label)

		var peak := 0.0
		for p in s.get("points", []):
			peak = maxf(peak, float(p.get("y", 0.0)))
		var value_box := VBoxContainer.new()
		value_box.add_theme_constant_override("separation", -2)
		row.add_child(value_box)
		var final_label := Label.new()
		final_label.text = "最终 %s" % stats.format_value(metric, float(s.get("final", 0.0)))
		final_label.add_theme_font_size_override("font_size", _fs(15))
		final_label.add_theme_color_override("font_color", s.get("color", Color.WHITE))
		final_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		value_box.add_child(final_label)
		var peak_label := Label.new()
		peak_label.text = "峰值 %s" % stats.format_value(metric, peak)
		peak_label.add_theme_font_size_override("font_size", _fs(12))
		peak_label.add_theme_color_override("font_color", Color(0.6, 0.68, 0.8))
		peak_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		value_box.add_child(peak_label)

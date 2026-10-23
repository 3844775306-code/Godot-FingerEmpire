class_name BattleStatsChart
extends Control

var series: Array = []
var duration: float = 1.0
var metric_id: String = ""

const PAD_LEFT: float = 78.0
const PAD_RIGHT: float = 22.0
const PAD_TOP: float = 18.0
const PAD_BOTTOM: float = 42.0

func _ready() -> void:
	# 主图与性能小图共用同一个 Chart；调用方可以预设较小的尺寸
	if custom_minimum_size == Vector2.ZERO:
		custom_minimum_size = Vector2(980, 420)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func set_data(p_series: Array, p_duration: float, p_metric: String) -> void:
	series = p_series
	duration = maxf(p_duration, 1.0)
	metric_id = p_metric
	queue_redraw()

func _max_value() -> float:
	var m := 0.0
	for s in series:
		for p in s.get("points", []):
			m = maxf(m, float(p.get("y", 0.0)))
	return maxf(m, 1.0)

func _nice_max(raw: float) -> float:
	if raw <= 4.0:
		return 4.0
	var mag: float = pow(10.0, floor(log(raw) / log(10.0)))
	var step: float = ceil(raw / mag)
	if step <= 1.0:
		step = 1.0
	elif step <= 2.0:
		step = 2.0
	elif step <= 5.0:
		step = 5.0
	else:
		step = 10.0
	return step * mag

func _draw() -> void:
	var w := size.x
	var h := size.y
	if w < 40.0 or h < 40.0:
		return
	var bg_rect := Rect2(Vector2.ZERO, size)
	draw_rect(bg_rect, Color(0.018, 0.025, 0.045, 0.96), true)
	var plot := Rect2(
		Vector2(PAD_LEFT, PAD_TOP),
		Vector2(maxf(10.0, w - PAD_LEFT - PAD_RIGHT), maxf(10.0, h - PAD_TOP - PAD_BOTTOM))
	)
	var raw_max := _max_value()
	var y_max := _nice_max(raw_max)
	var font := ThemeDB.fallback_font
	var grid_color := Color(0.22, 0.32, 0.46, 0.45)
	var axis_color := Color(0.55, 0.65, 0.8, 0.7)
	var text_color := Color(0.72, 0.80, 0.92, 0.95)

	# 横向网格与 Y 轴刻度
	for i in range(5):
		var t := float(i) / 4.0
		var y := plot.position.y + plot.size.y * (1.0 - t)
		draw_line(Vector2(plot.position.x, y), Vector2(plot.position.x + plot.size.x, y), grid_color, 1.0)
		var label := "%d" % int(round(y_max * t))
		draw_string(font, Vector2(8.0, y + 5.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, text_color)

	# 纵向网格与时间刻度
	for i in range(5):
		var t := float(i) / 4.0
		var x := plot.position.x + plot.size.x * t
		draw_line(Vector2(x, plot.position.y), Vector2(x, plot.position.y + plot.size.y), grid_color, 1.0)
		var secs := duration * t
		var time_text := "%02d:%02d" % [int(secs / 60.0), int(secs) % 60]
		draw_string(font, Vector2(x - 22.0, plot.position.y + plot.size.y + 24.0), time_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, text_color)

	# 坐标轴
	draw_line(Vector2(plot.position.x, plot.position.y), Vector2(plot.position.x, plot.position.y + plot.size.y), axis_color, 1.5)
	draw_line(Vector2(plot.position.x, plot.position.y + plot.size.y), Vector2(plot.position.x + plot.size.x, plot.position.y + plot.size.y), axis_color, 1.5)

	if series.is_empty():
		draw_string(font, Vector2(plot.position.x + 20.0, plot.position.y + 32.0), "暂无统计数据", HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(0.65, 0.72, 0.85))
		return

	# 曲线
	for s in series:
		var pts := PackedVector2Array()
		for p in s.get("points", []):
			var px := plot.position.x + plot.size.x * clampf(float(p["x"]) / duration, 0.0, 1.0)
			var py := plot.position.y + plot.size.y * (1.0 - clampf(float(p["y"]) / y_max, 0.0, 1.0))
			pts.append(Vector2(px, py))
		var color: Color = s.get("color", Color.WHITE)
		if pts.size() >= 2:
			draw_polyline(pts, color, 2.6, true)
		elif pts.size() == 1:
			draw_circle(pts[0], 4.0, color)
		# 终点圆点，便于识别当前值
		if not pts.is_empty():
			draw_circle(pts[pts.size() - 1], 3.5, color)

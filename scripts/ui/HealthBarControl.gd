# scripts/ui/HealthBarControl.gd
class_name HealthBarControl
extends Control

var max_value: float = 100.0
var current_value: float = 100.0
var team_color: Color = Color.WHITE
var _last_health: float = -1.0
var _last_max_health: float = -1.0

func _ready():
	custom_minimum_size = Vector2(80, 12)

func update_bar(health: float, max_health: float, team: int):
	# 队伍固定颜色（始终更新，避免外部 set_team_color 干扰）
	team_color = Color(1.0, 0.33, 0.264, 1.0) if team == 0 else Color(0.0, 0.886, 1.0, 1.0)if team == 1 else Color(0.0, 0.886, 0.431, 1.0)if team == 2 else Color(0.945, 0.925, 0.251, 1.0)
	# 脏检查：仅在值改变时才重绘
	if health == _last_health and max_health == _last_max_health:
		return
	_last_health = health
	_last_max_health = max_health
	max_value = max_health
	current_value = health
	queue_redraw()

func _draw():
	if current_value <= 0:
		return

	var w = size.x
	var h = size.y
	var ratio = clamp(current_value / max_value, 0.0, 1.0)
	var fill_width = w * ratio

	# 半透明背景
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.4))

	# 上半部分（浅色）
	var top_color = team_color.lightened(0.2)
	draw_rect(Rect2(Vector2.ZERO, Vector2(fill_width, h / 2.0)), top_color)

	# 下半部分（深色）
	var bottom_color = team_color.darkened(0.2)
	draw_rect(Rect2(Vector2(0, h / 2.0), Vector2(fill_width, h / 2.0)), bottom_color)

	# 半透明边框
	var border_color = Color(team_color.r, team_color.g, team_color.b, 0.5)
	draw_rect(Rect2(Vector2.ZERO, size), border_color, false, 1.0)
func set_team_color(color: Color):
	team_color = color
	queue_redraw()

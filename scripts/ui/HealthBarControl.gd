# scripts/ui/HealthBarControl.gd
class_name HealthBarControl
extends Control

var max_value: float = 100.0
var current_value: float = 100.0
var team_color: Color = Color.WHITE
var _last_health: float = -1.0
var _last_max_health: float = -1.0
var _last_color: Color = Color(-1, -1, -1, -1)

func _ready():
	custom_minimum_size = Vector2(80, 12)

func update_bar(health: float, max_health: float, team: int, color: Color = Color(-1, -1, -1, -1)):
	# 传入 color 时（建造=金、升级=紫）优先使用；否则按队伍映射到皇庭语义色
	# 哨兵约定：分量 -1 表示"未传入颜色"（_last_color 初始值即 Color(-1,-1,-1,-1)），Godot 4.5 无 Color.NAN
	if color.r < 0.0:
		match team:
			0: team_color = UITheme.VERMILION
			1: team_color = UITheme.SAPPHIRE
			2: team_color = UITheme.EMERALD
			_: team_color = UITheme.GOLD
	else:
		team_color = color
	# 脏检查：仅在值改变时才重绘
	if health == _last_health and max_health == _last_max_health and team_color == _last_color:
		return
	_last_health = health
	_last_max_health = max_health
	_last_color = team_color
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

	# 暖黑半透明背景
	draw_rect(Rect2(Vector2.ZERO, size), Color(UITheme.INK, 0.55))

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

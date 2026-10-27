class_name TouchDragGuard
extends Node

# 非战斗界面（主菜单 / 联机菜单 / 选关 / 图鉴 / 地图选择弹层）的触屏误点守卫。
#
# 引擎会把单指触摸模拟成鼠标事件（按下 → 拖动 → 抬起）。滚动列表时手指明明是在滑动，
# 但按钮只认「按下 → 抬起」：只要抬起那一刻指针还算在按钮内，就会被当成一次点击
# （典型表现：选择地图界面滑动列表时误选一张图）。
#
# 这里在 _input 里跟踪「按下之后是否真的滑动过」：滑动过的抬起事件直接吞掉，
# 并合成一次屏幕外的移动 + 抬起把按钮按下态复位，滚动列表时可以放心滑动。
# 只统计按下期间的移动，普通鼠标点击/拖动不受影响。

const DRAG_LIMIT_DP: float = 8.0
const OFFSCREEN: Vector2 = Vector2(-4000.0, -4000.0)

var _pressing: bool = false
var _dragged: bool = false
var _start_pos: Vector2 = Vector2.ZERO
var _limit: float = 28.0

func _ready() -> void:
	# 同一场景只保留一个守卫（菜单与弹层都会挂，重复的自行退场）
	if get_tree() != null and get_tree().has_group("touch_drag_guard"):
		queue_free()
		return
	add_to_group("touch_drag_guard")
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process_input(true)
	# 战斗界面会把模拟鼠标关掉（触摸由 TouchGestureRouter 全权翻译）；
	# 回到菜单界面后必须恢复，否则触摸点不动任何按钮。
	Input.emulate_mouse_from_touch = true
	_limit = UILayout.dp(DRAG_LIMIT_DP)

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			_pressing = true
			_dragged = false
			_start_pos = mb.position
		elif _pressing:
			_pressing = false
			if _dragged:
				# 滑动结束：把按下状态挪到屏幕外复位，再吞掉这次抬起，卡片不会被选中
				_cancel_press()
				get_viewport().set_input_as_handled()
			_dragged = false
	elif event is InputEventScreenDrag:
		if _pressing and not _dragged:
			_check_move((event as InputEventScreenDrag).position)
	elif event is InputEventMouseMotion:
		# 浏览器/部分平台可能只给鼠标拖动事件，这里同样按位移判断
		if _pressing and not _dragged:
			_check_move((event as InputEventMouseMotion).position)

func _check_move(pos: Vector2) -> void:
	if pos.distance_to(_start_pos) >= _limit:
		_dragged = true

# 屏幕外合成移动 + 抬起：让已按下的按钮/滑块退出按下态，且不触发 pressed
func _cancel_press() -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = OFFSCREEN
	motion.global_position = OFFSCREEN
	get_viewport().push_input(motion, true)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = OFFSCREEN
	up.global_position = OFFSCREEN
	get_viewport().push_input(up, true)

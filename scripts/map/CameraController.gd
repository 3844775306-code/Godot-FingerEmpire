extends Camera3D

# 相机移动速度（基础值）
var move_speed: float = 30.0
var zoom_speed: float = 5.0
var min_zoom: float = 5.0
var max_zoom: float = 80.0
var edge_margin: int = 20   # 保留边缘滚动（可选）

# 鼠标中键拖拽相关
var drag_start: Vector2
var is_dragging: bool = false

# 触摸拖拽相关
var touch_drag_start: Vector2
var touch_drag_active: bool = false

func _ready():
	if projection == PROJECTION_ORTHOGONAL:
		size = 30.0

func _input(event):
	# ========== PC 鼠标操作 ==========
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			is_dragging = event.pressed
			if event.pressed:
				drag_start = event.position
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			size = max(min_zoom, size - zoom_speed)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			size = min(max_zoom, size + zoom_speed)

	elif event is InputEventMouseMotion and is_dragging:
		# 鼠标中键拖拽移动相机
		var delta = event.position - drag_start
		var factor = size / 30.0
		global_translate(Vector3(-delta.x * 0.1 * factor, 0, -delta.y * 0.1 * factor))
		drag_start = event.position

	# ========== 手机触摸操作 ==========
	# 单指拖拽
	if event is InputEventScreenTouch:
		if event.index == 0:   # 仅处理第一根手指
			touch_drag_active = event.pressed
			if event.pressed:
				touch_drag_start = event.position

	elif event is InputEventScreenDrag and touch_drag_active and event.index == 0:
		# 单指拖动移动相机
		var delta = event.position - touch_drag_start
		var factor = size / 30.0
		global_translate(Vector3(-delta.x * 0.1 * factor, 0, -delta.y * 0.1 * factor))
		touch_drag_start = event.position

	# 双指捏合缩放
	if event is InputEventMagnifyGesture:
		# factor > 1 表示放大（两指分开），factor < 1 表示缩小
		# 通常放大应减小视野大小（size），缩小应增大视野
		size = clamp(size / event.factor, min_zoom, max_zoom)

func _process(delta):
	# 键盘方向键移动（便于PC调试）
	var direction = Vector3.ZERO
	if Input.is_action_pressed("ui_left"): direction.x -= 1
	if Input.is_action_pressed("ui_right"): direction.x += 1
	if Input.is_action_pressed("ui_up"): direction.z -= 1
	if Input.is_action_pressed("ui_down"): direction.z += 1
	var factor = size / 30.0
	global_translate(direction * move_speed * delta * factor)

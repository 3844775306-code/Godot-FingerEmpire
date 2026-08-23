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
var _touch_count: int = 0           # 当前触摸点数
var touch_pan_active: bool = false  # 三指拖拽移动相机
var touch_pan_start: Vector2

# ── 跟随视角（Tab 切换）──
var _follow_target: Node3D = null    # 当前跟随的单位节点
var _follow_saved: Dictionary = {}   # 进入跟随前的相机状态（transform + size）

const FOLLOW_HEIGHT: float = 8.0      # 相机相对单位的高度
const FOLLOW_BACK: float = 12.0       # 相机在单位后方的距离
const FOLLOW_PITCH_DEG: float = 40.0  # 俯角（度）
const FOLLOW_SIZE: float = 18.0       # 跟随时的视野大小

func _ready():
	if projection == PROJECTION_ORTHOGONAL:
		size = 30.0

func _input(event):
	# 跟随视角模式：禁用平移/缩放输入，画面完全由跟随逻辑控制
	if _follow_target:
		return

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
	# 三指拖拽 → 平移地图；单/双指 → 框选（由 SelectionManager 处理）
	if event is InputEventScreenTouch:
		if event.pressed:
			_touch_count += 1
		else:
			_touch_count = max(0, _touch_count - 1)
		# 三指按下时开始平移，松手时停止
		if _touch_count >= 3:
			touch_pan_active = event.pressed
			if event.pressed:
				touch_pan_start = event.position
		else:
			touch_pan_active = false

	elif event is InputEventScreenDrag:
		if touch_pan_active:
			# 三指拖动移动相机
			var delta = event.position - touch_pan_start
			var factor = size / 30.0
			global_translate(Vector3(-delta.x * 0.1 * factor, 0, -delta.y * 0.1 * factor))
			touch_pan_start = event.position

	# 双指捏合缩放
	if event is InputEventMagnifyGesture:
		# factor > 1 表示放大（两指分开），factor < 1 表示缩小
		# 通常放大应减小视野大小（size），缩小应增大视野
		size = clamp(size / event.factor, min_zoom, max_zoom)

func _process(delta):
	# 跟随视角模式：相机位置/朝向由跟随目标决定，禁用键盘移动
	if _follow_target:
		_update_follow()
		return

	# 键盘方向键移动（便于PC调试）
	var direction = Vector3.ZERO
	if Input.is_action_pressed("ui_left"): direction.x -= 1
	if Input.is_action_pressed("ui_right"): direction.x += 1
	if Input.is_action_pressed("ui_up"): direction.z -= 1
	if Input.is_action_pressed("ui_down"): direction.z += 1
	var factor = size / 30.0
	global_translate(direction * move_speed * delta * factor)

# ═══ 跟随视角 ═══
func is_following() -> bool:
	return _follow_target != null

# 切换跟随视角：传入单位节点开始跟随；已在跟随时调用则恢复原视角。返回是否进入跟随
func toggle_follow(target: Node3D) -> bool:
	if _follow_target:
		stop_follow()
		return false
	if target == null or not is_instance_valid(target):
		return false
	_follow_saved = {"transform": global_transform, "size": size}
	_follow_target = target
	size = FOLLOW_SIZE
	return true

# 恢复进入跟随前的相机状态
func stop_follow():
	if _follow_target == null:
		return
	_follow_target = null
	global_transform = _follow_saved.get("transform", global_transform)
	size = _follow_saved.get("size", size)
	_follow_saved = {}

func _update_follow():
	# 单位被销毁/移除 → 自动恢复原视角
	if not is_instance_valid(_follow_target) or _follow_target.is_queued_for_deletion():
		stop_follow()
		return
	# 死亡检测：在线节点用快照 health，单机节点用实体 health 属性（死亡后立即恢复，不等节点销毁）
	if _follow_target.has_meta("snapshot_info"):
		var info = _follow_target.get_meta("snapshot_info", {})
		if info.get("health", 1.0) <= 0.0:
			stop_follow()
			return
	elif "health" in _follow_target and _follow_target.get("health") <= 0.0:
		stop_follow()
		return
	# 相机位于单位后方上方：水平朝向与单位朝向一致，俯角固定
	# 注意绕 X 轴取负角度才是俯视（Godot 右手系正旋转为抬头）
	var basis = Basis(Vector3.UP, _follow_target.rotation.y) * Basis(Vector3.RIGHT, -deg_to_rad(FOLLOW_PITCH_DEG))
	global_transform.basis = basis
	global_position = _follow_target.global_position + basis.z * FOLLOW_BACK + Vector3.UP * FOLLOW_HEIGHT

extends Camera3D

# 相机移动速度（基础值）
var move_speed: float = 30.0
var zoom_speed: float = 0.5

# 虚拟摇杆平移量（世界平面分量：x 向东、y 向南，与方向键同向），每帧叠加进平移
var external_pan: Vector2 = Vector2.ZERO
var min_zoom: float = 15.0
var max_zoom: float = 20.0
var edge_margin: int = 20   # 保留边缘滚动（可选）

# 鼠标中键拖拽相关
var drag_start: Vector2
var is_dragging: bool = false

# Ctrl + 中键拖拽旋转视角：绕拖动开始时屏幕中心的地面点水平旋转
var is_rotating: bool = false
var rotate_center: Vector3 = Vector3.ZERO
var yaw_deg: float = 0.0
const ROTATE_SENSITIVITY: float = 0.30   # 每像素对应的旋转角度（度）

# 触屏多指：记录每个触点位置，双指拖动用来旋转视角
var _fingers: Dictionary = {}
var _two_finger_last: Vector2 = Vector2.ZERO

# 触摸拖拽相关
var _touch_count: int = 0           # 当前触摸点数
var touch_pan_active: bool = false  # 三指拖拽移动相机
var touch_pan_start: Vector2

# ── 跟随视角（Tab 切换）──
var _follow_target: Node3D = null    # 当前跟随的单位节点
var _follow_saved: Dictionary = {}   # 进入跟随前的相机状态（transform + size + projection）
var _follow_hidden_nodes: Array = [] # 跟随期间隐藏的单位模型节点（退出时恢复）

const FOLLOW_EYE_HEIGHT: float = 2.0 # 相机位于单位眼睛处的高度
const FOLLOW_FOV: float = 70.0       # 第一人称透视视野，数值越大周围物体越小

# ── 滚轮缩放联动：越近越低越平、越远越高越俯视 ──
const PITCH_NEAR_DEG: float = 28.0   # size 最小时（贴近地面）的相机俯角
const PITCH_FAR_DEG: float = 78.0    # size 最大时（全景俯瞰）的相机俯角
const HEIGHT_AT_MIN: float = 10.0    # size 最小时相机的离地高度
const HEIGHT_AT_MAX: float = 95.0    # size 最大时相机的离地高度

func _ready():
	if projection == PROJECTION_ORTHOGONAL:
		# 默认视野取缩放范围的中值：原来写死 30，比允许的最远视角（max_zoom 20）还大，
		# 开局视野过大、单位显得很小，而且第一次滚轮/双指缩放会瞬间跳到 20
		size = (min_zoom + max_zoom) * 0.5
	# 开局视角朝太阳（逆光方向）：等场景里的方向光就绪后再摆相机
	call_deferred("_apply_initial_sun_yaw")

# 开局把水平朝向对准太阳，形成逆光：地形和单位有明显的背光明暗对比
func _apply_initial_sun_yaw() -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var sun: Node3D = null
	for n in scene.find_children("*", "DirectionalLight3D", true, false):
		sun = n
		break
	if sun == null:
		return
	# DirectionalLight3D 沿自身 -Z 照射，所以指向太阳的方向是 +Z 轴
	var to_sun: Vector3 = sun.global_transform.basis.z
	to_sun.y = 0.0
	if to_sun.length() < 0.001:
		return
	to_sun = to_sun.normalized()
	# 相机水平视线 fwd = (-sin(yaw), 0, -cos(yaw))，令其等于 to_sun 反解 yaw
	yaw_deg = rad_to_deg(atan2(-to_sun.x, -to_sun.z))
	_rig_over_center(_screen_center_ground())

func _input(event):
	# 跟随视角模式：禁用平移/缩放输入，画面完全由跟随逻辑控制
	if _follow_target:
		return

	# ========== PC 鼠标操作 ==========
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			# 按住 Ctrl 拖动中键 = 旋转视角；单独拖动中键仍是平移地图
			if event.pressed and Input.is_key_pressed(KEY_CTRL):
				is_rotating = true
				is_dragging = false
				rotate_center = _screen_center_ground()
				drag_start = event.position
				return
			is_rotating = false
			is_dragging = event.pressed
			if event.pressed:
				drag_start = event.position
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_apply_zoom_to(size - zoom_speed)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_apply_zoom_to(size + zoom_speed)

	elif event is InputEventMouseMotion and is_rotating:
		# Ctrl + 中键拖动：水平旋转，保持拖动开始时的地面焦点不动
		var rdelta: float = event.position.x - drag_start.x
		yaw_deg = fposmod(yaw_deg + rdelta * ROTATE_SENSITIVITY, 360.0)
		drag_start = event.position
		_rig_over_center(rotate_center)

	elif event is InputEventMouseMotion and is_dragging:
		# 鼠标中键拖拽移动相机：按当前视角方向换算，转视角后拖动仍然跟手
		var delta = event.position - drag_start
		var factor = size / 30.0
		global_translate((-_view_right() * delta.x + _view_forward() * delta.y) * 0.1 * factor)
		drag_start = event.position

	# ========== 手机触摸操作 ==========
	# 三指拖拽 → 平移地图；双指拖拽 → 旋转视角；单指 → 框选（由 SelectionManager 处理）
	if event is InputEventScreenTouch:
		if event.pressed:
			_touch_count += 1
			_fingers[event.index] = event.position
		else:
			_touch_count = max(0, _touch_count - 1)
			_fingers.erase(event.index)
		# 触点数量变化时清掉旋转基准，避免换指/抬指瞬间视角跳一下
		_two_finger_last = Vector2.ZERO
		# 三指按下时开始平移，松手时停止
		if _touch_count >= 3:
			touch_pan_active = event.pressed
			if event.pressed:
				touch_pan_start = event.position
		else:
			touch_pan_active = false

	elif event is InputEventScreenDrag:
		_fingers[event.index] = event.position
		if touch_pan_active:
			# 三指拖动移动相机：同样按当前视角方向换算
			var delta = event.position - touch_pan_start
			var factor = size / 30.0
			global_translate((-_view_right() * delta.x + _view_forward() * delta.y) * 0.1 * factor)
			touch_pan_start = event.position
		elif _fingers.size() == 2:
			# 双指拖动旋转视角：用两指平均位置的水平位移，绕屏幕中心地面点转
			var avg := Vector2.ZERO
			for k in _fingers:
				avg += _fingers[k]
			avg /= float(_fingers.size())
			if _two_finger_last == Vector2.ZERO:
				_two_finger_last = avg
				rotate_center = _screen_center_ground()
			else:
				var fdx: float = avg.x - _two_finger_last.x
				if absf(fdx) > 0.01:
					yaw_deg = fposmod(yaw_deg + fdx * ROTATE_SENSITIVITY, 360.0)
					_rig_over_center(rotate_center)
				_two_finger_last = avg

	# 双指捏合缩放
	if event is InputEventMagnifyGesture:
		# factor > 1 表示放大（两指分开），factor < 1 表示缩小
		# 通常放大应减小视野大小（size），缩小应增大视野
		_apply_zoom_to(size / event.factor)

# 当前视角下的水平右方向与前方向：平移要跟着 Ctrl+中键 转出来的视角走，
# 否则转过镜头以后拖中键的方向会和画面错开。
func _view_right() -> Vector3:
	var yaw := deg_to_rad(yaw_deg)
	return Vector3(cos(yaw), 0.0, -sin(yaw))

func _view_forward() -> Vector3:
	var yaw := deg_to_rad(yaw_deg)
	return Vector3(-sin(yaw), 0.0, -cos(yaw))

# 触屏单指拖动平移：把屏幕位移按当前视野比例换算成世界位移（跟手）
func pan_by_screen_delta(screen_delta: Vector2) -> void:
	if _follow_target:
		return
	var view_h := get_viewport().get_visible_rect().size.y
	var world_per_px := size / maxf(view_h, 1.0)
	global_translate((-_view_right() * screen_delta.x + _view_forward() * screen_delta.y) * world_per_px)

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
	# 虚拟摇杆平移（左下摇杆）：分量已归一化
	if external_pan != Vector2.ZERO:
		direction.x += external_pan.x
		direction.z += external_pan.y
	var factor = size / 30.0
	# 方向键/摇杆也按当前视角换算：x 沿屏幕右、z 正值为后退（-z 为前进）
	var move = _view_right() * direction.x + _view_forward() * (-direction.z)
	global_translate(move * move_speed * delta * factor)

# ═══ 缩放联动（视野大小 ↔ 相机高度/俯角）═══
# 应用缩放：保持屏幕中心的地面点不变，同步调整相机高度与俯角
func _apply_zoom_to(target_size: float):
	var new_size = clamp(target_size, min_zoom, max_zoom)
	if absf(new_size - size) < 0.01:
		return
	var center = _screen_center_ground()
	size = new_size
	_rig_over_center(center)

# 重新摆放相机：以地面焦点 center 为轴，随 size 改变高度与俯角
func _rig_over_center(center: Vector3):
	var t = clamp((size - min_zoom) / max(1.0, max_zoom - min_zoom), 0.0, 1.0)
	var pitch = deg_to_rad(lerpf(PITCH_NEAR_DEG, PITCH_FAR_DEG, t))
	var height = lerpf(HEIGHT_AT_MIN, HEIGHT_AT_MAX, t)
	# 水平视线方向由 yaw 决定：0 度朝北看（相机在南侧），与原来的默认朝向一致
	var yaw = deg_to_rad(yaw_deg)
	var fwd = Vector3(-sin(yaw), 0.0, -cos(yaw))
	var back = height / tan(pitch)  # 相机沿 fwd 反方向退后，使俯角与高度匹配
	global_position = center - fwd * back + Vector3.UP * height
	look_at(center, Vector3.UP)

# 计算屏幕中心投射到地面的点（作为缩放时保持的焦点）
func _screen_center_ground() -> Vector3:
	var vp = get_viewport()
	var vp_size = vp.get_visible_rect().size
	if vp_size.x <= 0.0 or vp_size.y <= 0.0:
		vp_size = Vector2(1280.0, 720.0)
	var center_px = vp_size * 0.5
	var from = project_ray_origin(center_px)
	var dir = project_ray_normal(center_px)
	if dir.y >= -0.0001:
		return Vector3(from.x, 0.0, from.z)
	var dist = -from.y / dir.y
	if dist < 0.0:
		dist = 0.0
	return from + dir * dist

# ═══ 定位到地面某点（小地图点击 / 跳转警报）═══
# 直接改 global_position.x/z 会把“相机眼睛”放到目标点，而屏幕中心在斜前方十几米处。
# 这里保持当前高度与俯角，把相机沿视线方向后退，使目标点正好落在屏幕中心。
func focus_on_ground(world_pos: Vector3) -> void:
	if _follow_target:
		stop_follow()
	var target := Vector3(world_pos.x, 0.0, world_pos.z)
	# 优先用地面碰撞取得真实高度（地形有起伏）
	var space = get_world_3d().direct_space_state
	if space:
		var q = PhysicsRayQueryParameters3D.create(target + Vector3.UP * 200.0, target + Vector3.DOWN * 200.0)
		q.collide_with_bodies = true
		q.collision_mask = 2
		var hit = space.intersect_ray(q)
		if hit:
			target.y = hit.position.y
	var fwd = -global_transform.basis.z
	if fwd.y >= -0.001:
		fwd = Vector3(0.0, -1.0, 0.0)
	# 保持当前俯角：沿视线反推相机到目标的距离，使目标居中且高度不变
	var dist = (global_position.y - target.y) / (-fwd.y)
	dist = maxf(dist, 1.0)
	global_position = target - fwd * dist
	look_at(target, Vector3.UP)
	# 跳转后相机朝向可能变了，同步 yaw，避免之后滚轮缩放把视角转回去
	_sync_yaw_from_camera()

# 用当前相机朝向反推 yaw，保证手动转向（定位跳转/退出跟随）后滚轮缩放不会跳回旧角度
func _sync_yaw_from_camera() -> void:
	var fwd = -global_transform.basis.z
	if absf(fwd.x) < 0.0001 and absf(fwd.z) < 0.0001:
		return
	yaw_deg = rad_to_deg(atan2(-fwd.x, -fwd.z))

# ═══ 跟随视角 ═══
func is_following() -> bool:
	return _follow_target != null

func get_follow_target() -> Node3D:
	return _follow_target

# 切换跟随视角：传入单位节点开始跟随；已在跟随时调用则恢复原视角。返回是否进入跟随
func toggle_follow(target: Node3D) -> bool:
	if _follow_target:
		stop_follow()
		return false
	if target == null or not is_instance_valid(target):
		return false
	_follow_saved = {"transform": global_transform, "size": size, "projection": projection}
	_follow_target = target
	# 隐藏单位自身的模型（含选择环等），第一人称画面中不出现单位本身
	_follow_hidden_nodes = _collect_visible_meshes(target)
	for n in _follow_hidden_nodes:
		n.visible = false
	# 切换透视投影，营造第一人称近大远小、周围物体偏大的效果
	projection = PROJECTION_PERSPECTIVE
	fov = FOLLOW_FOV
	return true

# 恢复进入跟随前的相机状态
func stop_follow():
	if _follow_target == null:
		return
	var dead = _target_is_dead()
	_follow_target = null
	global_transform = _follow_saved.get("transform", global_transform)
	size = _follow_saved.get("size", size)
	projection = _follow_saved.get("projection", PROJECTION_ORTHOGONAL)
	_follow_saved = {}
	# 恢复原视角后同步 yaw，缩放时保持恢复出来的朝向
	_sync_yaw_from_camera()
	# 恢复被隐藏的单位模型；单位已死亡则保持隐藏（交给毁坏模型展示）
	if not dead:
		for n in _follow_hidden_nodes:
			if is_instance_valid(n):
				n.visible = true
	_follow_hidden_nodes.clear()

func _update_follow():
	# 单位被销毁/移除 → 自动恢复原视角
	if not is_instance_valid(_follow_target) or _follow_target.is_queued_for_deletion():
		stop_follow()
		return
	# 死亡检测：在线节点用快照 health，单机节点用实体 health 属性（死亡后立即恢复，不等节点销毁）
	if _target_is_dead():
		stop_follow()
		return
	# 第一人称：相机位于单位眼睛处，水平朝向与单位朝向完全一致（平视前方）
	var basis = Basis(Vector3.UP, _follow_target.rotation.y)
	global_transform.basis = basis
	global_position = _follow_target.global_position + Vector3.UP * FOLLOW_EYE_HEIGHT

# 目标是否已死亡（在线用快照 health，单机用实体 health 属性；目标失效视为死亡）
func _target_is_dead() -> bool:
	if not is_instance_valid(_follow_target):
		return true
	if _follow_target.has_meta("snapshot_info"):
		return _follow_target.get_meta("snapshot_info", {}).get("health", 1.0) <= 0.0
	elif "health" in _follow_target:
		return _follow_target.get("health") <= 0.0
	return false

# 递归收集节点子树中当前可见的 MeshInstance3D（单位模型及其子部件）
# 跳过 SelectionRing：选择环的显隐由选中逻辑管理，避免恢复时与选中状态冲突
func _collect_visible_meshes(root: Node) -> Array:
	var result: Array = []
	for child in root.get_children():
		if child is MeshInstance3D and child.visible and child.name != "SelectionRing":
			result.append(child)
		result.append_array(_collect_visible_meshes(child))
	return result

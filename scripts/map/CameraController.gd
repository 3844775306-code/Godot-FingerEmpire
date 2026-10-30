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
const ROTATE_SENSITIVITY: float = 0.30   # 每像素对应的旋转角度（度），PC 用
# 手机端「按住旋转」按钮：按住期间每帧绕固定焦点匀速转动，松手即停
const HOLD_ROTATE_SPEED: float = 32.0    # 度/秒，慢速微调；按住约 11 秒转一整圈

# 触屏多指：记录每个触点位置（双指只用来捏合缩放，旋转交给命令栏按钮）
var _fingers: Dictionary = {}
var _two_finger_last: Vector2 = Vector2.ZERO
var _two_finger_angle: float = 0.0
var _two_finger_dist: float = 0.0

# 双指捏合缩放：Android/iOS 会由触摸合成 InputEventMagnifyGesture，Web 导出不会，
# 所以这里按两指距离变化自己算一份。TouchGestureRouter 存在时由它统一驱动
# （它能看到全部触摸），一旦调用过 zoom_by_pinch_ratio 就置位，避免两边重复缩放。
var pinch_router_driven: bool = false
# 最近一次自算捏合的时间（毫秒）：同一手势里平台合成的 MagnifyGesture 要屏蔽掉
var _last_touch_pinch_msec: int = 0
const MAGNIFY_DEDUP_MS: int = 300

# 按住旋转状态：+1 顺时针 / -1 逆时针 / 0 停止
var _hold_rotate: float = 0.0
var _hold_rotate_center: Vector3 = Vector3.ZERO

# 相机放大倍数（设置面板滑条）：1.0 基准，越大视野越近。
# 实际生效方式是缩放视野 size 与缩放边界，滚轮/双指缩放的可用区间跟着平移，
# 这样放大倍数只影响"看起来多大"，不会把玩家原有的缩放习惯挤掉。
var _zoom_mult: float = 1.0

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

# ── 开发者全图视角（F10）──
# 仅调试构建 + 单机由 HUD 提供入口；相机拉到整张地图并锁定在中心，
# 不改变视野/迷雾算法，只改变观察范围。
var _dev_full_map: bool = false
var _dev_full_saved: Dictionary = {}

# ── 镜头轻微震动（攻城器械重击/开炮时由特效层触发）──
var _shake_left: float = 0.0
var _shake_total: float = 0.0
var _shake_amp: float = 0.0

func _ready():
	# 暂停时仍允许平移/缩放镜头，方便盯帧微操。
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group("camera_controller")
	# 相机放大倍数：设备默认值（电脑最小、平板居中、手机最大），可在设置面板调
	_zoom_mult = clampf(GameSettings.camera_zoom_mult, GameSettings.CAMERA_ZOOM_MIN, GameSettings.CAMERA_ZOOM_MAX)
	if projection == PROJECTION_ORTHOGONAL:
		# 默认视野取缩放范围的中值：原来写死 30，比允许的最远视角（max_zoom 20）还大，
		# 开局视野过大、单位显得很小，而且第一次滚轮/双指缩放会瞬间跳到 20
		size = (min_zoom + max_zoom) * 0.5 / _zoom_mult
	# 开局视角朝太阳（逆光方向）：等场景里的方向光就绪后再摆相机
	call_deferred("_apply_initial_sun_yaw")

# 放大倍数生效后的缩放边界：倍数越大，允许的 size 越小（看得越近）
func zoom_min() -> float:
	return min_zoom / maxf(_zoom_mult, 0.01)

func zoom_max() -> float:
	return max_zoom / maxf(_zoom_mult, 0.01)

# 设置面板拖动「相机放大倍数」时调用：边拖边生效，不打断当前视野中心
func apply_zoom_mult(mult: float) -> void:
	if _dev_full_map:
		_exit_dev_full_map()
	var m: float = clampf(mult, GameSettings.CAMERA_ZOOM_MIN, GameSettings.CAMERA_ZOOM_MAX)
	if absf(m - _zoom_mult) < 0.001:
		return
	var center: Vector3 = _screen_center_ground()
	# size * 旧倍数 是"基准视野"，除以新倍数就得到新的 size
	size = clampf(size * _zoom_mult / m, min_zoom / m, max_zoom / m)
	_zoom_mult = m
	_rig_over_center(center)

# ═══ 开发者全图视角 ═══
func is_dev_full_map() -> bool:
	return _dev_full_map

# 切换全图视角；返回切换后是否处于全图状态。
func toggle_dev_full_map() -> bool:
	if _dev_full_map:
		_exit_dev_full_map()
		return false
	if _follow_target:
		stop_follow()
	var prev_center: Vector3 = _screen_center_ground()
	_dev_full_saved = {
		"size": size,
		"yaw": yaw_deg,
		"center": prev_center,
	}
	_dev_full_map = true
	var map_size: float = maxf(float(RTSConfig.MAP_SIZE), 1.0)
	# 正交相机 size 是竖直方向的世界高度；HUD 顶部/底部会遮住一部分画面，
	# 留 50% 边距保证整张地图（含边缘城郊）都落在可见区域里。
	size = maxf(zoom_max(), map_size * 1.5)
	yaw_deg = 0.0
	_rig_over_center(Vector3.ZERO)
	return true

func _exit_dev_full_map() -> void:
	if not _dev_full_map:
		return
	_dev_full_map = false
	var prev: Dictionary = _dev_full_saved
	_dev_full_saved = {}
	if prev.is_empty():
		return
	size = clampf(float(prev.get("size", size)), zoom_min(), zoom_max())
	yaw_deg = float(prev.get("yaw", yaw_deg))
	_rig_over_center(prev.get("center", Vector3.ZERO))

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

# 手机端「按住旋转」：命令栏按钮按下 → 传入 +1（顺时针）/-1（逆时针），松开传 0。
# 每个事件都现读，所以松手立刻停住，不需要额外信号。
func set_hold_rotate(dir: float) -> void:
	if _follow_target or _dev_full_map:
		return
	if absf(dir) < 0.001:
		_hold_rotate = 0.0
		return
	# 按下瞬间定住旋转轴：之后每帧只是绕这个地面点转，镜头不会边转边漂
	if _hold_rotate == 0.0:
		_hold_rotate_center = _screen_center_ground()
	_hold_rotate = 1.0 if dir > 0.0 else -1.0

func _input(event):
	# 跟随视角/全图视角：禁用平移/缩放输入，画面完全由对应模式控制
	if _follow_target or _dev_full_map:
		return

	# ========== PC 鼠标操作 ==========
	if event is InputEventMouseButton:
		# 鼠标落在按钮/面板上时不要再缩放或开始拖拽地图；中键松开仍要处理，避免拖拽状态卡住。
		if event.button_index in [MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			if (event.pressed or event.button_index != MOUSE_BUTTON_MIDDLE) and _is_ui_point(event.position):
				return
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
		_two_finger_angle = 0.0
		_two_finger_dist = 0.0
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
			# 双指只负责缩放：按两指距离变化比例自己算捏合（Web 端没有 MagnifyGesture）。
			# 拖两指/扭转都不动视角——旋转改由命令栏的「按住旋转」按钮控制，
			# 免得想缩放却把镜头带歪。
			var keys: Array = _fingers.keys()
			var p1: Vector2 = _fingers[keys[0]]
			var p2: Vector2 = _fingers[keys[1]]
			var dist: float = p1.distance_to(p2)
			# 没有 router 的触屏（桌面触屏本）由相机自己算；有 router 时它已经算过
			if not pinch_router_driven and _two_finger_dist > 1.0:
				_apply_pinch_ratio(dist / _two_finger_dist)
			_two_finger_last = (p1 + p2) * 0.5
			_two_finger_angle = atan2(p2.y - p1.y, p2.x - p1.x)
			_two_finger_dist = dist

	# 双指捏合缩放（平台合成的 MagnifyGesture：Android/iOS 有，Web 没有）。
	# 同一手势已经由触点自算缩放接管时跳过，避免一次捏合被缩放两倍。
	if event is InputEventMagnifyGesture:
		if Time.get_ticks_msec() - _last_touch_pinch_msec >= MAGNIFY_DEDUP_MS:
			# factor > 1 表示放大（两指分开），factor < 1 表示缩小
			# 通常放大应减小视野大小（size），缩小应增大视野
			_apply_zoom_to(size / event.factor)

func _is_ui_point(pos: Vector2) -> bool:
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if bm == null or not bm.has_node("UI"):
		return false
	return UILayout.is_point_over_interactive_ui(bm.get_node("UI"), pos)

# 供 TouchGestureRouter 驱动触屏捏合：ratio > 1 = 两指分开（拉近），< 1 = 收拢（拉远）。
# 只改视野大小，保持屏幕中心地面点不变，手感与滚轮缩放完全一致。
func zoom_by_pinch_ratio(ratio: float) -> void:
	pinch_router_driven = true
	_apply_pinch_ratio(ratio)

# 按捏合比例缩放视野（内部统一入口：自算与 router 驱动都走这里，保证去重时间戳一致）
func _apply_pinch_ratio(ratio: float) -> void:
	if _follow_target or _dev_full_map:
		return
	if not is_finite(ratio) or ratio <= 0.0:
		return
	_last_touch_pinch_msec = Time.get_ticks_msec()
	# 单次比例限幅：换指/触点跳变时不至于把视野一下甩到边界
	_apply_zoom_to(size / clampf(ratio, 0.5, 2.0))

# 供手机端旋转按钮调用：绕当前屏幕中心的地面点转指定角度（正数向右转）
func rotate_by(deg: float) -> void:
	if _follow_target or _dev_full_map:
		return
	rotate_center = _screen_center_ground()
	yaw_deg = fposmod(yaw_deg + deg, 360.0)
	_rig_over_center(rotate_center)

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
	if _follow_target or _dev_full_map:
		return
	var view_h := get_viewport().get_visible_rect().size.y
	var world_per_px := size / maxf(view_h, 1.0)
	global_translate((-_view_right() * screen_delta.x + _view_forward() * screen_delta.y) * world_per_px)

# 攻城器械重击时叠加一个很小的镜头抖动；用 Camera3D 的 h/v_offset 实现，
# 不改相机 transform，不会影响平移、缩放和跟随视角。
func add_shake(amp: float, duration: float) -> void:
	if amp <= 0.0 or duration <= 0.0:
		return
	_shake_amp = maxf(_shake_amp, amp)
	_shake_left = maxf(_shake_left, duration)
	_shake_total = maxf(_shake_total, duration)

func _update_shake(delta: float) -> void:
	if _shake_left <= 0.0:
		if h_offset != 0.0 or v_offset != 0.0:
			h_offset = 0.0
			v_offset = 0.0
		_shake_amp = 0.0
		_shake_total = 0.0
		return
	_shake_left -= delta
	var ratio: float = clampf(_shake_left / maxf(_shake_total, 0.001), 0.0, 1.0)
	var current: float = _shake_amp * ratio * ratio
	h_offset = randf_range(-current, current)
	v_offset = randf_range(-current, current)

func _process(delta):
	_update_shake(delta)
	# 开发者全图视角：锁定在地图中心，不响应平移/缩放/旋转输入。
	if _dev_full_map:
		_rig_over_center(Vector3.ZERO)
		return
	# 设置面板的放大倍数滑条：每帧比对一次，拖动立即生效（面板也会直接调 apply_zoom_mult）
	if absf(GameSettings.camera_zoom_mult - _zoom_mult) > 0.001:
		apply_zoom_mult(GameSettings.camera_zoom_mult)
	# 按住旋转按钮：绕按下瞬间锁定的地面焦点匀速转，松开即停
	if _hold_rotate != 0.0:
		yaw_deg = fposmod(yaw_deg + _hold_rotate * HOLD_ROTATE_SPEED * delta, 360.0)
		_rig_over_center(_hold_rotate_center)
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
	var new_size = clamp(target_size, zoom_min(), zoom_max())
	if absf(new_size - size) < 0.01:
		return
	var center = _screen_center_ground()
	size = new_size
	_rig_over_center(center)

# 重新摆放相机：以地面焦点 center 为轴，随 size 改变高度与俯角
func _rig_over_center(center: Vector3):
	var lo: float = zoom_min()
	var span: float = maxf(0.001, zoom_max() - lo)
	var t = clamp((size - lo) / span, 0.0, 1.0)
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
	if _dev_full_map:
		_exit_dev_full_map()
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
	if _dev_full_map:
		_exit_dev_full_map()
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

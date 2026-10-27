class_name TouchGestureRouter
extends Node

# 触屏手势统一仲裁器（移动端唯一触摸入口）。
#
# 设计原则：不重写选择/下令逻辑，而是把手势翻译成鼠标事件，
# 让 SelectionManager / ClientInput / RTSBattleManager 的既有流程原样运行。
#
#   单指点按          → 合成鼠标左键 pressed + released（选择 / 下令 / 建造放置）
#   单指拖动·框选模式开 → 合成左键按下 + 拖动 + 抬起（走现有框选逻辑）
#   单指拖动·框选模式关 → 直接平移相机
#   单指拖动·建造模式中 → 只合成鼠标移动（预览跟随），点按由建造延迟逻辑放置
#   双指              → 放弃单指手势，按两指距离变化缩放相机视野（自算，兼容 MagnifyGesture）

signal box_select_mode_changed(active: bool)

enum Mode { IDLE, TAP_CANDIDATE, PAN, BOX, BUILD_PREVIEW, LONG_PRESS }

const TAP_MOVE_LIMIT: float = 26.0      # 约 8dp，设计空间单位
const TAP_TIME_LIMIT: float = 0.45      # 秒；超时不再算点按
const LONG_PRESS_MS: int = 500          # 长按阈值：呼出建造菜单（等价桌面右键空地）

var enabled: bool = true
var box_select_mode: bool = false

# 手机端居中建造模式：预览固定在屏幕中央，单指拖动只平移地图；
# 确认/取消由建造浮层上的勾叉按钮负责，触摸不再直接放置建筑。
var centered_build_mode: bool = false

# 由 MobileHUD 注入：判断某个屏幕坐标是否落在移动端 UI 面板上
var is_over_ui: Callable = Callable()

var _mode: int = Mode.IDLE
var _touch_index: int = -1
var _start_pos: Vector2 = Vector2.ZERO
var _last_pos: Vector2 = Vector2.ZERO
var _start_msec: int = 0
var _camera: Camera3D = null
var _bm: Node = null
# 双指捏合缩放：自己记录两个触点的 index → position。
# Web 导出不会合成 InputEventMagnifyGesture，只能按两指距离变化算；
# 只统计落在战场上的手指，按在面板上的触点不参与，避免误缩放。
var _pinch_fingers: Dictionary = {}
var _pinch_dist: float = 0.0
const PINCH_MIN_DIST: float = 1.0   # 两指几乎重合时距离比例会爆掉，这种帧只取基准
# 落在移动端面板上的那根手指：只负责翻译成鼠标事件，不参与手势
var _ui_touch_index: int = -1
var _ui_touch_down: bool = false
var _ui_start_pos: Vector2 = Vector2.ZERO
# 面板手指是否滑动过：滑动后抬起不能当成点击（滚动列表/按钮时最常见）
var _ui_dragged: bool = false
# 面板横向滑动收起（右下指令区向右滑出、左下信息面板向左滑出）
var ui_slide_hit: Callable = Callable()
var ui_slide_drag: Callable = Callable()
var ui_slide_end: Callable = Callable()
var _ui_slide_ctrl: Object = null
const SLIDE_TRIGGER: float = 44.0   # 约 12dp，横向位移超过它才认定为滑动收起
# 转发合成事件时置位，避免 router 自己再次收到合成事件造成递归
var _forwarding: bool = false

func _ready() -> void:
	set_process_input(true)
	set_process(true)
	# 关闭引擎自动模拟鼠标：触摸全部由本路由器翻译，避免一次触摸产生两份鼠标事件
	Input.emulate_mouse_from_touch = false

# 长按检测：手指按住不动超过阈值 → 合成右键呼出建造菜单
func _process(_delta: float) -> void:
	if _mode != Mode.TAP_CANDIDATE or _touch_index == -1:
		return
	# 居中建造时滑动地图，不把长按当成再次打开建造菜单
	if centered_build_mode:
		return
	if Time.get_ticks_msec() - _start_msec < LONG_PRESS_MS:
		return
	if (_last_pos - _start_pos).length() > TAP_MOVE_LIMIT:
		return
	_mode = Mode.LONG_PRESS
	_emit_right_click(_start_pos)

func _emit_right_click(pos: Vector2) -> void:
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_RIGHT
	down.pressed = true
	down.position = pos
	down.global_position = pos
	get_viewport().push_input(down, true)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_RIGHT
	up.pressed = false
	up.position = pos
	up.global_position = pos
	get_viewport().push_input(up, true)

func set_box_select_mode(active: bool) -> void:
	if box_select_mode == active:
		return
	box_select_mode = active
	box_select_mode_changed.emit(active)

func toggle_box_select_mode() -> void:
	set_box_select_mode(not box_select_mode)

# 由 MobileHUD 在进入/退出居中建造时调用
func set_centered_build_mode(active: bool) -> void:
	centered_build_mode = active

func _get_camera() -> Camera3D:
	if _camera == null or not is_instance_valid(_camera):
		_camera = get_viewport().get_camera_3d()
	return _camera

func _get_bm() -> Node:
	if _bm == null or not is_instance_valid(_bm):
		_bm = get_tree().get_first_node_in_group("battle_manager")
	return _bm

func _in_build_mode() -> bool:
	var bm := _get_bm()
	return bm != null and bm.get("build_mode") == true

func _point_on_ui(pos: Vector2) -> bool:
	if is_over_ui.is_valid():
		return is_over_ui.call(pos)
	return false

func _input(event: InputEvent) -> void:
	if not enabled or _forwarding:
		return
	if event is InputEventScreenTouch:
		_handle_touch(event)
	elif event is InputEventScreenDrag:
		_handle_drag(event)

# ==================== 触摸生命周期 ====================

func _handle_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		var on_ui: bool = _point_on_ui(event.position)
		if not on_ui:
			# 战场手指记进捏合表；第二指落下时距离基准归零，这一帧只取基准不缩放
			_pinch_fingers[event.index] = event.position
			if _pinch_fingers.size() >= 2:
				_pinch_dist = 0.0
		# 第二根手指按下：作废单指手势，让双指缩放接管
		if _touch_index != -1 and event.index != _touch_index:
			_abort_gesture()
			return
		if _touch_index != -1 or _ui_touch_index != -1:
			return
		if on_ui:
			# 引擎的触摸→鼠标模拟已被关掉，面板上的按钮/滚动容器需要我们自己补鼠标事件
			_ui_touch_index = event.index
			_ui_touch_down = true
			_ui_start_pos = event.position
			_ui_slide_ctrl = null
			_ui_dragged = false
			_emit_ui_button(event.position, true)
			get_viewport().set_input_as_handled()
			return
		_touch_index = event.index
		_start_pos = event.position
		_last_pos = event.position
		_start_msec = Time.get_ticks_msec()
		_mode = Mode.TAP_CANDIDATE
		get_viewport().set_input_as_handled()
	else:
		# 抬指：先移出捏合表，剩下的手指下次落指时重新取基准
		_pinch_fingers.erase(event.index)
		_pinch_dist = 0.0
		if event.index == _ui_touch_index:
			_ui_touch_index = -1
			_ui_touch_down = false
			if _ui_slide_ctrl != null:
				# 面板滑动结束：按在面板外松开，避免按钮误触
				_forwarding = true
				ui_slide_end.call(_ui_slide_ctrl)
				_emit_ui_motion(Vector2(-200.0, -200.0), Vector2.ZERO)
				_emit_ui_button(Vector2(-200.0, -200.0), false)
				_forwarding = false
				_ui_slide_ctrl = null
			elif _ui_dragged:
				# 面板内滑动过（列表滚动、按钮上滑一下）：抬起若是原地松开会被当成点击，
				# 这里先把指针挪出屏幕再松开，按钮的按下态被取消，不会误触。
				_forwarding = true
				_emit_ui_motion(Vector2(-200.0, -200.0), Vector2.ZERO)
				_emit_ui_button(Vector2(-200.0, -200.0), false)
				_forwarding = false
			else:
				_emit_ui_button(event.position, false)
			_ui_dragged = false
			get_viewport().set_input_as_handled()
			return
		if event.index != _touch_index:
			return
		_finish_gesture(event.position)
		get_viewport().set_input_as_handled()

func _handle_drag(event: InputEventScreenDrag) -> void:
	# 双指缩放：地图手指的每次拖动都刷新两指距离（面板手指不参与）
	if event.index != _ui_touch_index and _pinch_fingers.has(event.index):
		_pinch_fingers[event.index] = event.position
		_update_pinch()
	if event.index == _ui_touch_index:
		# 面板上的拖动：
		#   横向（且起点落在可收起面板上）→ 面板跟着手指滑出屏幕；
		#   纵向 → 内容滚动（ScrollContainer 只认触摸拖动与滚轮，由 UILayout.scroll_at 驱动）；
		#   其余 → 照旧把鼠标拖动转发给按钮/滑块。
		if not _ui_touch_down:
			return
		if _ui_slide_ctrl != null:
			_forwarding = true
			ui_slide_drag.call(_ui_slide_ctrl, event.relative.x)
			_forwarding = false
			return
		var dx: float = event.position.x - _ui_start_pos.x
		var dy: float = event.position.y - _ui_start_pos.y
		if (Vector2(dx, dy)).length() > TAP_MOVE_LIMIT:
			_ui_dragged = true
		if absf(dx) > absf(dy) and absf(dx) > SLIDE_TRIGGER and ui_slide_hit.is_valid():
			var ctrl = ui_slide_hit.call(_ui_start_pos)
			if ctrl != null:
				_ui_slide_ctrl = ctrl
				_forwarding = true
				# 让已按下的按钮失焦，避免滑动被当成点击
				_emit_ui_motion(Vector2(-200.0, -200.0), Vector2.ZERO)
				ui_slide_drag.call(ctrl, dx)
				_forwarding = false
				return
		_forwarding = true
		_emit_ui_motion(event.position, event.relative)
		UILayout.scroll_at(get_tree().root, event.position, event.relative.y)
		_forwarding = false
		return
	if event.index != _touch_index:
		return
	var pos: Vector2 = event.position
	var moved := (pos - _start_pos).length()
	_last_pos = pos

	if _mode == Mode.TAP_CANDIDATE:
		if moved <= TAP_MOVE_LIMIT:
			return
		_begin_drag()

	match _mode:
		Mode.PAN:
			_pan_camera(event.relative)
		Mode.BOX, Mode.BUILD_PREVIEW:
			_push_motion(pos, event.relative)

# 两指距离变化 → 按比例缩放相机视野（相机内部仍走滚轮那套边界/俯角联动，手感一致）
func _update_pinch() -> void:
	if _pinch_fingers.size() != 2:
		_pinch_dist = 0.0
		return
	var keys: Array = _pinch_fingers.keys()
	var p1: Vector2 = _pinch_fingers[keys[0]]
	var p2: Vector2 = _pinch_fingers[keys[1]]
	var dist: float = p1.distance_to(p2)
	if _pinch_dist > PINCH_MIN_DIST and dist > PINCH_MIN_DIST:
		var cam := _get_camera()
		if cam != null and cam.has_method("zoom_by_pinch_ratio"):
			cam.zoom_by_pinch_ratio(dist / _pinch_dist)
	_pinch_dist = dist

func _begin_drag() -> void:
	# 进入拖动时先补齐按下事件，让框选/建造预览等依赖 pressed 的流程就绪
	var target := _decide_drag_mode()
	_mode = target
	if target == Mode.BOX or target == Mode.BUILD_PREVIEW:
		_push_left_button(_start_pos, true)

func _decide_drag_mode() -> int:
	if centered_build_mode:
		return Mode.PAN
	if _in_build_mode():
		return Mode.BUILD_PREVIEW
	if box_select_mode:
		return Mode.BOX
	return Mode.PAN

func _finish_gesture(pos: Vector2) -> void:
	var mode := _mode
	var dist := (pos - _start_pos).length()
	var elapsed := float(Time.get_ticks_msec() - _start_msec) / 1000.0

	match mode:
		Mode.TAP_CANDIDATE:
			# 居中建造只认浮层上的勾叉，点地图不放置建筑
			if dist <= TAP_MOVE_LIMIT and elapsed <= TAP_TIME_LIMIT and not centered_build_mode:
				_emit_tap(pos)
		Mode.BOX:
			_push_motion(pos, Vector2.ZERO)
			_push_left_button(pos, false)
		Mode.BUILD_PREVIEW:
			# 建造模式下抬起即视为确认放置：沉交给 0.1s 延迟放置逻辑
			_push_left_button(pos, false)
		Mode.PAN:
			pass
	_reset_state()

func _abort_gesture() -> void:
	if _mode == Mode.BOX or _mode == Mode.BUILD_PREVIEW:
		_push_left_button(_last_pos, false)
	_reset_state()

func _reset_state() -> void:
	_mode = Mode.IDLE
	_touch_index = -1

# ==================== 动作 ====================

func _emit_tap(pos: Vector2) -> void:
	# 一次完整的点击：按下 → 抬起，与鼠标单击完全等价
	_push_motion(pos, Vector2.ZERO)
	_push_left_button(pos, true)
	_push_left_button(pos, false)

func _pan_camera(delta: Vector2) -> void:
	var cam := _get_camera()
	if cam == null:
		return
	if cam.has_method("pan_by_screen_delta"):
		cam.pan_by_screen_delta(delta)
	else:
		# 兜底：老相机脚本没有该接口时按视野比例直接平移
		var vh := get_viewport().get_visible_rect().size.y
		var wpp := cam.size / maxf(vh, 1.0)
		cam.global_translate(Vector3(-delta.x * wpp, 0.0, -delta.y * wpp))

# ==================== 面板触摸 → 鼠标 ====================

# 与下面的世界点击一样走 get_viewport().push_input(ev, true)：
# 坐标已经是视口坐标，必须显式告诉引擎，否则会被 stretch 变换二次缩放。
func _emit_ui_button(pos: Vector2, pressed: bool) -> void:
	_push_left_button(pos, pressed)

func _emit_ui_motion(pos: Vector2, relative: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	ev.global_position = pos
	ev.relative = relative
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT
	get_viewport().push_input(ev, true)

# ScrollContainer 只响应 ScreenDrag 与滚轮，鼠标拖动不会滚动，所以面板拖动由 UILayout.scroll_at 驱动。

# ==================== 鼠标事件合成 ====================

# 注意 push_input 第二参数必须为 true（in_local_coords）：
# 触摸事件的 position 已经是视口坐标，若按窗口坐标处理会被 stretch 变换二次缩放，
# 合成出来的点击位置就会整体偏移，表现为「点了选不中」。
func _push_left_button(pos: Vector2, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.position = pos
	ev.global_position = pos
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	get_viewport().push_input(ev, true)

func _push_motion(pos: Vector2, relative: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	ev.global_position = pos
	ev.relative = relative
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT if _mode != Mode.IDLE else 0
	get_viewport().push_input(ev, true)

extends Control
# 虚拟摇杆：位于战斗界面左下角，拖动控制镜头平移。
# 由各战斗场景挂在 UI(CanvasLayer) 下实例化，输出归一化分量喂给
# CameraController.external_pan（世界平面分量：右=+x 东，下=+y 南，与方向键同向）。

const CameraControllerScript := preload("res://scripts/map/CameraController.gd")

var _camera: CameraControllerScript = null

var _center: Vector2 = Vector2.ZERO    # 底盘圆心（本控件内坐标）
var _base_radius: float = 120.0        # 底盘半径
var _knob_radius: float = 46.0         # 摇杆头半径
var _travel: float = 74.0              # 摇杆头最大偏移
var _knob: Vector2 = Vector2.ZERO      # 摇杆头当前中心

var _active: bool = false              # 是否正在拖动
var _by_touch: bool = false            # 输入来源是触摸还是鼠标
var _touch_index: int = -1


func _ready() -> void:
	# 吃掉整个摇杆区域的事件，避免误触发地图框选/命令
	mouse_filter = Control.MOUSE_FILTER_STOP
	_center = size * 0.5
	var half := minf(size.x, size.y) * 0.5
	_base_radius = half * 0.86
	_knob_radius = half * 0.34
	_travel = maxf(_base_radius - _knob_radius, 1.0)
	_knob = _center
	_camera = _find_camera()
	queue_redraw()


func _process(_delta: float) -> void:
	# 兜底：鼠标拖拽期间光标事件丢失（例如松手发生在控件外），下一帧自动复位
	if _active and not _by_touch and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_end()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_by_touch = false
			_start(event.position)
		else:
			_end()
	elif event is InputEventMouseMotion and _active and not _by_touch:
		_update(event.position)
	elif event is InputEventScreenTouch:
		if event.pressed:
			_by_touch = true
			_touch_index = event.index
			_start(event.position)
		elif _active and _by_touch and event.index == _touch_index:
			_end()
	elif event is InputEventScreenDrag and _active and _by_touch and event.index == _touch_index:
		_update(event.position)


# ═══ 输入逻辑 ═══

func _start(pos: Vector2) -> void:
	if _active:
		return
	_active = true
	_update(pos)


func _update(pos: Vector2) -> void:
	var off: Vector2 = pos - _center
	var len := off.length()
	if len > _travel:
		off = off / len * _travel
	_knob = _center + off
	# 归一化（0..1 模拟量），直接作为世界平面平移分量交给相机
	if _camera:
		_camera.external_pan = off / _travel
	queue_redraw()


func _end() -> void:
	if not _active:
		return
	_active = false
	_by_touch = false
	_touch_index = -1
	_knob = _center
	if _camera:
		_camera.external_pan = Vector2.ZERO
	queue_redraw()


# ═══ 相机查找 ═══
# 场景约定：本节点挂在 UI(CanvasLayer) 下，相机为场景根的直接子节点 Camera3D
func _find_camera() -> CameraControllerScript:
	var p := get_parent()
	if p and p.get_parent():
		var cam := p.get_parent().get_node_or_null("Camera3D")
		if cam is CameraControllerScript:
			return cam as CameraControllerScript
	# 兜底：在整棵当前场景树中搜索挂载了 CameraController 的相机
	var scene := get_tree().current_scene
	if scene:
		return _search_camera(scene)
	return null


func _search_camera(n: Node) -> CameraControllerScript:
	for c in n.get_children():
		if c is CameraControllerScript:
			return c as CameraControllerScript
		var hit := _search_camera(c)
		if hit:
			return hit
	return null


# ═══ 绘制 ═══
func _draw() -> void:
	# 底盘：半透明暖黑圆 + 金色描边
	draw_circle(_center, _base_radius, Color(0.07, 0.06, 0.05, 0.42))
	draw_arc(_center, _base_radius - 2.0, 0.0, TAU, 64, Color(0.788, 0.659, 0.298, 0.55), 3.0)
	if not _active:
		draw_arc(_center, _base_radius * 0.62, 0.0, TAU, 48, Color(0.831, 0.773, 0.663, 0.35), 2.0)
	# 摇杆头：金色主体 + 羊皮纸内芯
	draw_circle(_knob, _knob_radius, Color(0.788, 0.659, 0.298, 0.92))
	draw_circle(_knob, _knob_radius * 0.48, Color(0.831, 0.773, 0.663, 0.95))

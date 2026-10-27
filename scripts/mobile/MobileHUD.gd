class_name MobileHUD
extends Control

# 移动端战斗界面装配器。
#
# 职责边界：
#   - 不过问游戏逻辑，只做「摆放 + 转发」
#   - 桌面 HUD 继续负责取数，本节点接收 update_data 后渲染
#   - 选择/下令仍走既有 SelectionManager / ClientInput，通过 TouchGestureRouter 合成
#
# 布局分区：态势左上（资源胶囊）、复盘全屏（统计大屏）、看左（单位信息面板）、
#          单位条底部居中（生产按钮在单位信息面板里）、令右（框选模式 + 五个全局指令）。
# 建造入口改为长按地图呼出建造菜单（由 TouchGestureRouter 合成右键触发），不再有底部抽屉。

var hud: Node = null
var router: TouchGestureRouter = null
var capsule: MobileResourceCapsule = null
var command_bar: MobileCommandBar = null
var stats_screen: StatsOverviewScreen = null
var build_overlay: MobileBuildPlacementOverlay = null

var _bm: Node = null
var _refresh_timer: float = 0.0
var _ai_hide_timer: float = 0.0
var _minimap_sized: bool = false
var _last_resources: Dictionary = {}
var _last_population: Dictionary = {}
var _last_limits: Dictionary = {}

# 可横向滑出收起的面板：右下指令区向右、左下单位信息面板向左
const SLIDE_ANIM: float = 0.16
var _slides: Array = []
var _slide_handles: Array = []

const REFRESH_INTERVAL: float = 0.25

func setup(desktop_hud: Node) -> void:
	hud = desktop_hud
	name = "MobileHUD"
	add_to_group("mobile_hud")
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_hide_desktop_controls()
	_create_router()
	_create_components()
	_relayout_shared_nodes()
	# 面板尺寸要等一帧布局完成后才有效
	call_deferred("_setup_slides")
	set_process(true)
	print("[MobileHUD] 触屏界面已装配（设备=%s）" % InputSource.device_kind())

# ==================== 装配 ====================

func _hide_desktop_controls() -> void:
	if hud == null:
		return
	# 桌面端常驻面板改为移动端组件：统计面板、AI 决策面板、外交面板不在战场常驻
	_set_member_visible(hud, "unit_stats_panel", false)
	# 折叠胶囊也不用：手机上已经有一整套资源胶囊
	_set_member_visible(hud, "_stats_capsule", false)
	_set_member_visible(hud, "_diplo_panel", false)
	_set_member_visible(hud, "_diplo_toggle_btn", false)
	_set_member_visible(hud, "auto_attack_btn", false)
	# 全局指令底板（全选/撤退/上船等）在手机上由命令栏与手势替代
	_set_member_visible(hud, "_cmd_panel", false)
	# 桌面版 F1/F2/F3 指令按钮与统计切换按钮（关键字识别，避免改动 HUD 内部结构）
	_hide_desktop_buttons(hud)

func _set_member_visible(target: Node, member: String, visible_value: bool) -> void:
	var value = target.get(member)
	if value is CanvasItem:
		value.visible = visible_value

func _hide_desktop_buttons(node: Node) -> void:
	for child in node.get_children():
		if child is Button:
			var t: String = child.text
			if t.contains("全选") or t.contains("撤退") or t.contains("自动进攻") or t.contains("军需官") or t.contains("统计"):
				child.visible = false
		elif child is Control and child != self:
			_hide_desktop_buttons(child)

func _create_router() -> void:
	router = TouchGestureRouter.new()
	router.name = "TouchGestureRouter"
	router.is_over_ui = Callable(self, "is_point_over_panel")
	# 面板横向拖动收起（右下指令区向右、左下信息面板向左）
	router.ui_slide_hit = Callable(self, "_slide_hit")
	router.ui_slide_drag = Callable(self, "_slide_drag")
	router.ui_slide_end = Callable(self, "_slide_end")
	add_child(router)

func _create_components() -> void:
	capsule = MobileResourceCapsule.new()
	capsule.name = "ResourceCapsule"
	capsule.stats_pressed.connect(_on_stats_requested)
	add_child(capsule)

	command_bar = MobileCommandBar.new()
	command_bar.name = "CommandBar"
	command_bar.hud = hud
	command_bar.router = router
	add_child(command_bar)

	stats_screen = StatsOverviewScreen.new()
	stats_screen.name = "StatsOverview"
	stats_screen.battle_manager_provider = Callable(self, "_get_bm")
	stats_screen.hud = hud
	stats_screen.visible = false
	add_child(stats_screen)

	# 居中建造浮层：勾/叉按钮由这里转发给单机或联机建造后端
	build_overlay = MobileBuildPlacementOverlay.new()
	add_child(build_overlay)
	build_overlay.confirmed.connect(_on_build_confirm)
	build_overlay.cancelled.connect(_on_build_cancel)

	_hide_ai_debug_panels()
	# 视角旋转改为倾斜手机（陀螺仪/重力感应），不再放 ↺/↻ 按钮
	set_process(true)

# 倾斜手机旋转视角（替代原来的 ↺/↻ 按钮）。
# 用重力感应的横向分量判断左右倾斜，留一段死区避免手抖导致镜头乱转。
# 桌面端没有传感器，get_accelerometer 返回零向量，这里会直接返回。
const GYRO_DEADZONE: float = 1.6      # 死区（m/s²）
const GYRO_ROTATE_SPEED: float = 90.0 # 倾斜满量程时每秒转多少度
const GYRO_MAX_TILT: float = 6.5      # 超过这个倾斜量按满速处理

var _gyro_cam: Camera3D = null
var _gyro_was_tilting: bool = false

func _process_gyro_rotate(delta: float) -> void:
	if not InputSource.use_mobile_ui():
		return
	# 命令栏里的开关可以关掉，默认开启
	if not GameSettings.mobile_gyro_rotate:
		return
	if _gyro_cam == null or not is_instance_valid(_gyro_cam):
		_gyro_cam = get_viewport().get_camera_3d() as Camera3D
	if _gyro_cam == null or not _gyro_cam.has_method("rotate_by"):
		return
	var accel: Vector3 = Input.get_accelerometer()
	if accel == Vector3.ZERO:
		return
	# 横屏时 x 轴对应手机的左右倾斜；超过死区才转，且速度随倾斜量递增
	var tilt: float = accel.x
	if absf(tilt) < GYRO_DEADZONE:
		if _gyro_was_tilting:
			_gyro_was_tilting = false
		return
	_gyro_was_tilting = true
	var drive: float = clampf((absf(tilt) - GYRO_DEADZONE) / (GYRO_MAX_TILT - GYRO_DEADZONE), 0.0, 1.0)
	_gyro_cam.call("rotate_by", signf(tilt) * drive * GYRO_ROTATE_SPEED * delta)

# AI 决策面板在移动端改为并入全屏统计大屏，战场上不再常驻显示
func _hide_ai_debug_panels() -> void:
	if hud == null:
		return
	for child in hud.get_children():
		if child is Control and child.name.begins_with("AIDebugPanel") and child.visible:
			child.visible = false

func _relayout_shared_nodes() -> void:
	# 摇杆在移动端不再需要：左下角让给单位信息面板，同时停掉它的输入处理避免和手势路由抢触摸
	var stick := _find_ui_node("VirtualStick")
	if stick is Control:
		stick.visible = false
		stick.set_process(false)
		stick.set_process_input(false)
		stick.set_process_unhandled_input(false)

	# 小地图与单位信息面板复用桌面节点，只重排位置与尺寸
	var minimap := _find_ui_node("Minimap")
	if minimap is Control:
		_apply_minimap_layout(minimap)

	var info := _find_ui_node("InfoPanel")
	if info is Control:
		# 宽度收到原来的 70%，整体再往左下挪一点，给战场腾出中间区域
		UILayout.place_dp(info, "bl", 182.0, 200.0, 20.0)
		info.mouse_filter = Control.MOUSE_FILTER_STOP
		_scale_shared_fonts(info)

# 信息面板是桌面节点，Label/Button 字号按 2400 宽屏定死，手机上要按 dp 比例整体放大。
# RichTextLabel 不在这里处理：它的字号主题项是 normal_font_size，由 InfoPanel 自己按 dp 设置。
func _scale_shared_fonts(root: Control) -> void:
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
			if child is Label or child is Button:
				var cur: int = int(child.get_theme_font_size("font_size"))
				# 已经用 dp 换算过的控件（例如「详细」切换按钮）不再二次放大。
				if cur > 0 and cur <= 28:
					child.add_theme_font_size_override("font_size", int(round(cur * UILayout.DP_RATIO)))

# ==================== 面板横向滑动收起 ====================
# 右下指令区与左下信息面板会挡住战场：手指横向拖动可把面板滑出屏幕，
# 屏幕边缘留一个细把手，点一下即可滑回来。

func _setup_slides() -> void:
	var info := _find_ui_node("InfoPanel")
	if command_bar and is_instance_valid(command_bar):
		_add_slide(command_bar, 1.0, "◀", 190.0)
	if info is Control:
		_add_slide(info, -1.0, "▶", 182.0)

func _add_slide(ctrl: Control, dir: float, handle_text: String, fallback_w_dp: float) -> void:
	var h := Button.new()
	h.text = handle_text
	h.custom_minimum_size = Vector2(UILayout.dp(14.0), UILayout.dp(46.0))
	h.add_theme_font_size_override("font_size", UILayout.font_dp(11.0))
	h.anchor_top = 0.38
	h.anchor_bottom = 0.38
	if dir > 0.0:
		h.anchor_left = 1.0
		h.anchor_right = 1.0
		h.offset_left = -UILayout.dp(14.0)
		h.offset_right = 0.0
	else:
		h.anchor_left = 0.0
		h.anchor_right = 0.0
		h.offset_left = 0.0
		h.offset_right = UILayout.dp(14.0)
	h.offset_top = -UILayout.dp(23.0)
	h.offset_bottom = UILayout.dp(23.0)
	h.modulate = Color(1, 1, 1, 0.45)
	h.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(h)

	var w: float = ctrl.size.x if ctrl.size.x > UILayout.dp(20.0) else UILayout.dp(fallback_w_dp)
	var entry := {
		"ctrl": ctrl,
		"dir": dir,
		"base_l": ctrl.offset_left,
		"base_r": ctrl.offset_right,
		# 面板与屏幕边缘还有一段安全边距，要多滑一点才能彻底移出视野
		"max": w + UILayout.dp(26.0),
		"visual": 0.0,
		"hidden": false,
		"handle": h,
	}
	h.pressed.connect(_toggle_slide.bind(entry))
	_slides.append(entry)
	_slide_handles.append(h)

func _toggle_slide(entry: Dictionary) -> void:
	_animate_slide(entry, 0.0 if entry.get("hidden", false) else float(entry.get("max", 0.0)))

func _animate_slide(entry: Dictionary, target: float) -> void:
	var ctrl = entry.get("ctrl")
	if not is_instance_valid(ctrl):
		return
	entry["hidden"] = target > 0.5
	var from: float = float(entry.get("visual", 0.0))
	var tw := create_tween()
	tw.tween_method(func(v: float) -> void: _apply_slide(entry, v), from, target, SLIDE_ANIM)

func _apply_slide(entry: Dictionary, v: float) -> void:
	entry["visual"] = v
	var ctrl = entry.get("ctrl")
	if not is_instance_valid(ctrl):
		return
	var dx: float = float(entry.get("dir", 1.0)) * v
	ctrl.offset_left = float(entry.get("base_l", 0.0)) + dx
	ctrl.offset_right = float(entry.get("base_r", 0.0)) + dx
	var h = entry.get("handle")
	if h is Control:
		h.modulate = Color(1, 1, 1, 1.0 if v > 0.5 else 0.45)

func _find_slide(ctrl) -> Dictionary:
	for e in _slides:
		if e.get("ctrl") == ctrl:
			return e
	return {}

func _slide_hit(pos: Vector2) -> Object:
	for e in _slides:
		var ctrl = e.get("ctrl")
		if ctrl is Control and ctrl.visible and ctrl.get_global_rect().has_point(pos):
			return ctrl
	return null

func _slide_drag(ctrl, dx: float) -> void:
	var e := _find_slide(ctrl)
	if e.is_empty():
		return
	var v: float = clampf(float(e.get("visual", 0.0)) + dx * float(e.get("dir", 1.0)), 0.0, float(e.get("max", 0.0)))
	_apply_slide(e, v)

func _slide_end(ctrl) -> void:
	var e := _find_slide(ctrl)
	if e.is_empty():
		return
	var v: float = float(e.get("visual", 0.0))
	var mx: float = float(e.get("max", 0.0))
	_animate_slide(e, mx if v > mx * 0.3 else 0.0)

# ==================== 数据 ====================

# 由桌面 HUD 的 update_data 转发
func update_data(resources: Dictionary, population: Dictionary, limits: Dictionary = {},
		gather_counts: Dictionary = {}, income_rate: Dictionary = {}) -> void:
	_last_resources = resources
	_last_population = population
	_last_limits = limits
	if capsule:
		capsule.apply_data(resources, population, limits)
		capsule.apply_rates(gather_counts, income_rate)

func _get_bm() -> Node:
	if _bm == null or not is_instance_valid(_bm):
		_bm = get_tree().get_first_node_in_group("battle_manager")
	return _bm

# 手机端小地图放大到原来的 2 倍（77 → 154dp），贴在屏幕右上角。
# 必须清掉 Minimap 内部写死的 custom_minimum_size=400，否则控件会被撑回原尺寸、
# 直接铺出屏幕外。指令栏已经压矮到 ~170dp（上缘在设计空间 y≈750），
# 小地图占 y 64..613，所以两者不再重叠，不需要再为顶部信息面板让位。
const MINIMAP_DP: float = 154.0

func _apply_minimap_layout(minimap: Control) -> void:
	minimap.custom_minimum_size = Vector2.ZERO
	minimap.size = Vector2(UILayout.dp(MINIMAP_DP), UILayout.dp(MINIMAP_DP))
	UILayout.place_dp(minimap, "tr", MINIMAP_DP, MINIMAP_DP, 6.0)
	minimap.mouse_filter = Control.MOUSE_FILTER_STOP
	_minimap_sized = true

func _find_ui_node(node_name: String) -> Node:
	if hud == null:
		return null
	var direct := hud.get_node_or_null(node_name)
	if direct:
		return direct
	var parent := hud.get_parent()
	if parent:
		return parent.get_node_or_null(node_name)
	return null

# 收集当前选中：单机读 SelectionManager，联机读 ClientInput
func _collect_selection() -> Array:
	var bm := _get_bm()
	if bm and bm.has_node("SelectionManager"):
		var sm := bm.get_node("SelectionManager")
		var selected = sm.get("selected_entities")
		if selected is Array:
			return selected
	var ci := get_tree().get_first_node_in_group("client_input")
	if ci and ci.has_method("get_client_selected_ids"):
		return ci.get_client_selected_ids()
	return []

func is_point_over_panel(pos: Vector2) -> bool:
	if stats_screen and stats_screen.visible and stats_screen.is_point_inside(pos):
		return true
	if build_overlay and build_overlay.visible and build_overlay.is_point_inside(pos):
		return true
	# 对局内设置等全屏模态：整个面板都要拦住触摸，否则按钮点不到、列表也滚不动。
	for modal in get_tree().get_nodes_in_group("mobile_modal_ui"):
		if modal is Control and modal.visible and modal.get_global_rect().has_point(pos):
			return true
	if _point_over_build_menu(pos):
		return true
	for ctrl in [capsule, command_bar]:
		if ctrl is Control and ctrl.visible and ctrl.get_global_rect().has_point(pos):
			return true
	# 顶部警报条（点一下跳到警报位置）
	if hud:
		var alert_bg = hud.get("_alert_bg")
		if alert_bg is Control and alert_bg.visible and alert_bg.get_global_rect().has_point(pos):
			return true
	# 面板收起后的边缘把手
	for h in _slide_handles:
		if h is Control and h.visible and h.get_global_rect().has_point(pos):
			return true
	var info := _find_ui_node("InfoPanel")
	if info is Control and info.visible and info.get_global_rect().has_point(pos):
		return true
	var minimap := _find_ui_node("Minimap")
	if minimap is Control and minimap.visible and minimap.get_global_rect().has_point(pos):
		return true
	return false

# 长按呼出的建造菜单也是触屏面板：命中的触摸要转成 UI 点击，不能漏进世界选择
func _point_over_build_menu(pos: Vector2) -> bool:
	var bm := _get_bm()
	if bm != null:
		var menu = bm.get("current_build_menu")
		if is_instance_valid(menu) and menu is Control and menu.visible:
			return menu.get_global_rect().has_point(pos)
	# 联机客户端没有 battle_manager，建造菜单挂在 ClientRenderer/UI 下
	var renderer := get_tree().get_first_node_in_group("client_renderer")
	if renderer:
		var menu := renderer.get_node_or_null("UI/BuildMenu")
		if menu is Control and menu.visible:
			if menu.has_method("is_point_inside"):
				return bool(menu.call("is_point_inside", pos))
			return menu.get_global_rect().has_point(pos)
	return false

func _process(delta: float) -> void:
	# 倾斜手机旋转视角（替代已移除的 ↺/↻ 按钮）
	_process_gyro_rotate(delta)
	# 居中建造状态每帧同步：预览/勾叉按钮与手势路由必须同时生效
	_sync_build_overlay()
	# AI 面板由 AI 自己创建/重建，定期扫一遍确保移动端始终隐藏
	_ai_hide_timer -= delta
	if _ai_hide_timer <= 0.0:
		_ai_hide_timer = 1.0
		_hide_ai_debug_panels()
	# 小地图的节点可能晚于本界面进入场景（或是被 Minimap._ready 重设过 min size），
	# 缩小没生效时会按 400dp 原尺寸铺到屏幕外，所以这里持续兜底
	if not _minimap_sized:
		var mm := _find_ui_node("Minimap")
		if mm is Control:
			_apply_minimap_layout(mm)
	_refresh_timer -= delta
	if _refresh_timer > 0.0:
		return
	_refresh_timer = REFRESH_INTERVAL
	if capsule:
		_refresh_resources()
		capsule.set_time_text(_format_game_time())

# 单机读 RTSBattleManager，联机读 ClientRenderer；两者都只暴露「居中建造」状态
func _sync_build_overlay() -> void:
	if build_overlay == null:
		return
	var active := false
	var bm := _get_bm()
	if bm != null and bool(bm.get("build_mode")):
		active = bool(bm.get("mobile_centered_build"))
	else:
		var renderer := get_tree().get_first_node_in_group("client_renderer")
		if renderer != null and bool(renderer.get("placement_mode")):
			active = bool(renderer.get("mobile_centered_placement"))
	build_overlay.set_active(active, GameSettings.mobile_continuous_build)
	if router:
		router.set_centered_build_mode(active)

func _on_build_confirm() -> void:
	var bm := _get_bm()
	if bm != null and bool(bm.get("build_mode")) and bm.has_method("confirm_mobile_build"):
		bm.call("confirm_mobile_build")
		return
	var ci := get_tree().get_first_node_in_group("client_input")
	if ci != null and ci.has_method("confirm_mobile_placement"):
		ci.call("confirm_mobile_placement")

func _on_build_cancel() -> void:
	var bm := _get_bm()
	if bm != null and bool(bm.get("build_mode")) and bm.has_method("cancel_mobile_build"):
		bm.call("cancel_mobile_build")
		return
	var ci := get_tree().get_first_node_in_group("client_input")
	if ci != null and ci.has_method("cancel_mobile_placement"):
		ci.call("cancel_mobile_placement")

# 资源数据来源分两种：
#   单机 —— battle_manager 里有 player_resources，直接读（桌面 HUD 的 update_data 只服务桌面标签）
#   联机 —— 客户端没有 battle_manager，数据由 ClientHUD.update_data 转发进来
func _refresh_resources() -> void:
	var bm := _get_bm()
	if bm != null:
		var res = bm.get("player_resources")
		if res is Dictionary and not res.is_empty():
			var pop := {
				"current": int(bm.get("player_pop")),
				"max": int(bm.get("player_max_pop")),
			}
			var lim = bm.get("player_resource_limits")
			if not lim is Dictionary:
				lim = {}
			var gather: Dictionary = {}
			var rate: Dictionary = {}
			if hud:
				var g = hud.get("gather_counts")
				if g is Dictionary:
					gather = g
				var r = hud.get("income_rate")
				if r is Dictionary:
					rate = r
			capsule.apply_data(res, pop, lim)
			capsule.apply_rates(gather, rate)
			return
	if not _last_resources.is_empty():
		capsule.apply_data(_last_resources, _last_population, _last_limits)

func _format_game_time() -> String:
	var bm := _get_bm()
	var seconds := 0.0
	if bm != null and bm.get("game_time") != null:
		seconds = float(bm.get("game_time"))
	var mins := int(seconds / 60.0)
	var secs := int(seconds) % 60
	return "%02d:%02d" % [mins, secs]

func _on_stats_requested() -> void:
	if stats_screen:
		stats_screen.open()

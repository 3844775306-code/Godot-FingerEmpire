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
#          造中（单位条 + 建造抽屉）、令右（框选模式 + 五个全局指令）。

var hud: Node = null
var router: TouchGestureRouter = null
var capsule: MobileResourceCapsule = null
var command_bar: MobileCommandBar = null
var unit_bar: MobileUnitBar = null
var drawer: MobileBuildDrawer = null
var stats_screen: StatsOverviewScreen = null

var _bm: Node = null
var _refresh_timer: float = 0.0
var _last_resources: Dictionary = {}
var _last_population: Dictionary = {}
var _last_limits: Dictionary = {}

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
	set_process(true)
	print("[MobileHUD] 触屏界面已装配（设备=%s）" % InputSource.device_kind())

# ==================== 装配 ====================

func _hide_desktop_controls() -> void:
	if hud == null:
		return
	# 桌面端常驻面板改为移动端组件：统计面板、AI 决策面板、外交面板不在战场常驻
	_set_member_visible(hud, "unit_stats_panel", false)
	_set_member_visible(hud, "_toggle_stats_btn", false)
	_set_member_visible(hud, "_diplo_panel", false)
	_set_member_visible(hud, "_diplo_toggle_btn", false)
	_set_member_visible(hud, "auto_attack_btn", false)
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
			if t.contains("全选") or t.contains("撤退") or t.contains("自动进攻") or t.contains("统计"):
				child.visible = false
		elif child is Control and child != self:
			_hide_desktop_buttons(child)

func _create_router() -> void:
	router = TouchGestureRouter.new()
	router.name = "TouchGestureRouter"
	router.is_over_ui = Callable(self, "is_point_over_panel")
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

	unit_bar = MobileUnitBar.new()
	unit_bar.name = "UnitBar"
	unit_bar.selection_provider = Callable(self, "_collect_selection")
	unit_bar.focus_requested.connect(_on_unit_focus_requested)
	add_child(unit_bar)

	drawer = MobileBuildDrawer.new()
	drawer.name = "BuildDrawer"
	drawer.battle_manager_provider = Callable(self, "_get_bm")
	add_child(drawer)

	stats_screen = StatsOverviewScreen.new()
	stats_screen.name = "StatsOverview"
	stats_screen.battle_manager_provider = Callable(self, "_get_bm")
	stats_screen.hud = hud
	stats_screen.visible = false
	add_child(stats_screen)

	drawer.produce_requested.connect(_on_produce_requested)

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
		UILayout.place_dp(minimap, "tr", 110.0, 110.0)
		minimap.mouse_filter = Control.MOUSE_FILTER_STOP

	var info := _find_ui_node("InfoPanel")
	if info is Control:
		UILayout.place_dp(info, "bl", 260.0, 200.0)
		info.mouse_filter = Control.MOUSE_FILTER_STOP
		_scale_shared_fonts(info)

# 信息面板是桌面节点，字号按 2400 宽屏定死；手机上要按 dp 比例整体放大，否则读不出来
func _scale_shared_fonts(root: Control) -> void:
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
			if child is Label or child is Button or child is RichTextLabel:
				var cur: int = int(child.get_theme_font_size("font_size"))
				if cur > 0:
					child.add_theme_font_size_override("font_size", int(round(cur * UILayout.DP_RATIO)))

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
	for ctrl in [capsule, command_bar, unit_bar, drawer]:
		if ctrl is Control and ctrl.visible and ctrl.get_global_rect().has_point(pos):
			return true
	var info := _find_ui_node("InfoPanel")
	if info is Control and info.visible and info.get_global_rect().has_point(pos):
		return true
	var minimap := _find_ui_node("Minimap")
	if minimap is Control and minimap.visible and minimap.get_global_rect().has_point(pos):
		return true
	return false

func _process(delta: float) -> void:
	_refresh_timer -= delta
	if _refresh_timer > 0.0:
		return
	_refresh_timer = REFRESH_INTERVAL
	if unit_bar:
		unit_bar.refresh(_collect_selection())
	if drawer:
		drawer.refresh(_collect_selection())
	if capsule:
		_refresh_resources()
		capsule.set_time_text(_format_game_time())

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
			var gather: Dictionary = {}
			var rate: Dictionary = {}
			if hud:
				var g = hud.get("gather_counts")
				if g is Dictionary:
					gather = g
				var r = hud.get("income_rate")
				if r is Dictionary:
					rate = r
			capsule.apply_data(res, pop)
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

func _on_produce_requested(building: Node, unit_id: int) -> void:
	var bm := _get_bm()
	if bm and bm.has_method("produce_unit"):
		bm.call("produce_unit", building, unit_id)

# 点按单位条：把镜头移到该单位
func _on_unit_focus_requested(entity) -> void:
	if entity == null or not is_instance_valid(entity):
		return
	var cam := get_viewport().get_camera_3d() if get_viewport() else null
	if cam and cam.has_method("focus_on_ground"):
		cam.call("focus_on_ground", entity.global_position)

func _on_stats_requested() -> void:
	if stats_screen:
		stats_screen.open()

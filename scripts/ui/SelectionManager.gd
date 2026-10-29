# scripts/ui/SelectionManager.gd

class_name SelectionManager
# scripts/ui/SelectionManager.gd
extends Node

# 当前选中的实体列表
var selected_entities: Array = []
var _touch_start_pos: Vector2 = Vector2.ZERO
# 框选相关
var is_box_selecting: bool = false
var box_start: Vector2
var box_end: Vector2
var box_rect: ColorRect

# 双击相关
# 不设强类型：实体可能已经死亡释放，强类型赋值会报 previously freed
var last_clicked_entity = null
var last_click_time: float = 0.0
const DOUBLE_CLICK_THRESHOLD = 0.3   # 双击时间阈值（秒）
var _ref_cleanup_timer: float = 0.0
# 选中单位的目标 ❌：由集中管理器按目标实体/地面位置去重，避免多选时重
# 复生成同一个标记。放在 battle_manager 下，标记跟随世界坐标。
var _target_markers: TargetMarkerManager = null
# 框选/全选时 _add_to_selection 会被连续调用几十上百次；每次立刻重建
# InfoPanel 会让“框选大部队”明显卡顿。合并到本帧结束只刷新一次。
var _info_panel_refresh_pending: bool = false
# 框选几百个单位时，只为前 N 个显示选择环；每个环/路径指引都是一次额外 draw call。
const MAX_SELECTION_RINGS: int = 64

# 编队系统
var control_groups: Dictionary = {}   # int → Array[GameEntity]
var _last_group_key: int = -1         # 双击切图检测
var _last_group_time: float = 0.0

func _ready():
	# 暂停时仍要能框选、右键下令、切换编队；模拟单位则保持冻结。
	process_mode = Node.PROCESS_MODE_ALWAYS
	# 创建框选矩形（半透明蓝色）
	box_rect = ColorRect.new()
	box_rect.color = Color(0.3, 0.6, 1.0, 0.3)
	box_rect.visible = false
	box_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 延迟添加到 UI 层，确保 battle_manager 已就绪
	call_deferred("_add_box_rect_to_ui")

func _process(delta):
	# 选中/编队/双击缓存都可能持有已死亡实体，定期清理，避免后续强类型参数或
	# panel.update_info(selected_entities[0]) 之类的调用触发 previously freed。
	_ref_cleanup_timer -= delta
	if _ref_cleanup_timer <= 0.0:
		_ref_cleanup_timer = 0.2
		if _sanitize_entity_refs():
			_update_info_panel()
	_update_target_markers()

# 只要选中了陆军，就给它画目标 ❌：自己的、队友的、敌方的都显示。
# 敌方单位允许查看但不能下命令，红叉只表示“它当前在打/去哪”，不代表可指挥。
func _update_target_markers() -> void:
	if _target_markers == null or not is_instance_valid(_target_markers):
		var host: Node = get_parent()
		if not (host is Node3D):
			host = self
		_target_markers = TargetMarkerManager.new()
		_target_markers.name = "TargetMarkerManager"
		_target_markers.process_mode = Node.PROCESS_MODE_PAUSABLE
		host.add_child(_target_markers)
		var bm = get_tree().get_first_node_in_group("battle_manager")
		_target_markers.setup(bm)
	var requests: Array = []
	for e in selected_entities:
		if is_instance_valid(e) and e is Army:
			var req: Dictionary = _target_marker_request(e)
			if not req.is_empty():
				requests.append(req)
	_target_markers.refresh_requests(requests)

# 把一个选中陆军的目标整理成 TargetMarkerManager 的请求：
#   - 有攻击/采集目标实体 → 跟随实体，标记放头顶；
#   - 普通移动/攻击移动 → 放 A* 终点；路径还没算好、只剩 1 个航点或已进入最后接近时
#     也要显示，不能只在 astar_path.size() >= 2 时才画。
func _target_marker_request(e: Army) -> Dictionary:
	var target = e.current_target
	if target != null and is_instance_valid(target) and target is Node3D and target != e:
		return {"follow": target}
	var mc: MovementController = e._movement
	if mc == null:
		return {}
	# 攻击移动没有实体目标时，终点是 attack_move_target；即使 A* 还在排队/已走空，
	# 命令目的地仍然存在，应该继续显示 ❌。
	if e.is_attack_moving and e.attack_move_target != Vector3.ZERO:
		return {"pos": e.attack_move_target}
	# 普通移动/建造/交付的终点保存在 astar_target；路径可能在 pending 或已走完，
	# 不能因为 path 为空/只有 1 个点就误判为“没有命令”。
	if mc.move_path_failed:
		return {}
	var pos: Vector3 = mc.astar_target
	if pos == Vector3.ZERO and not mc.astar_path.is_empty():
		pos = mc.astar_path[mc.astar_path.size() - 1]
	if pos == Vector3.ZERO:
		return {}
	return {"pos": pos}

func _sanitize_entity_refs() -> bool:
	var changed := false
	for i in range(selected_entities.size() - 1, -1, -1):
		var e = selected_entities[i]
		if not is_instance_valid(e) or (e is GameEntity and e.health <= 0):
			selected_entities.remove_at(i)
			changed = true
		elif _is_inspect_only(e) and not (e as Node3D).visible:
			# 敌方/中立目标离开视野后不能继续选中/查看旧信息
			selected_entities.remove_at(i)
			if is_instance_valid(e):
				(e as Node3D).set_selected(false)
			changed = true
	if changed:
		_request_info_panel_refresh()
	if last_clicked_entity != null and (not is_instance_valid(last_clicked_entity) or last_clicked_entity.health <= 0):
		last_clicked_entity = null
	for key in control_groups.keys():
		var arr: Array = control_groups[key]
		for i in range(arr.size() - 1, -1, -1):
			var e = arr[i]
			if not is_instance_valid(e) or (e is GameEntity and e.health <= 0):
				arr.remove_at(i)
				changed = true
	return changed

func _add_box_rect_to_ui():
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if bm and bm.has_node("UI"):
		bm.get_node("UI").add_child(box_rect)
	else:
		get_tree().root.add_child(box_rect)

# ---------- 输入事件处理 ----------
func _input(event):
	_sanitize_entity_refs()
	# 建筑模式优先：不进行任何选择操作；Esc 仍要能退出建造模式
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if bm and bm.build_mode:
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			bm._exit_build_mode()
			get_viewport().set_input_as_handled()
		return

	# Don't process clicks on interactive UI panels
	if event is InputEventMouseButton:
		# 移动端：触屏面板上的点击交给 GUI，不做世界选择
		if bm and bm.has_method("is_mobile_ui_point") and bm.is_mobile_ui_point(event.position):
			return
		if bm and bm.has_node("UI/InfoPanel"):
			var ip = bm.get_node("UI/InfoPanel")
			if ip.visible and ip.get_global_rect().has_point(event.position):
				return
		if bm and bm.has_node("UI/BuildMenu"):
			var bmenu = bm.get_node("UI/BuildMenu")
			if bmenu.visible and bmenu.get_global_rect().has_point(event.position):
				return

	# 键盘快捷键
	if event is InputEventKey and event.pressed:
		var key = event.keycode
		var ctrl = event.ctrl_pressed
		var shift = event.shift_pressed

		# Esc：取消下令模式 → 建造菜单 → 当前选择
		if key == KEY_ESCAPE:
			if bm and bm.has_method("handle_cancel"):
				bm.handle_cancel()
				get_viewport().set_input_as_handled()
			return

		# Tab：跟随视角切换（仅单选时；再按 Tab 恢复原视角）
		if key == KEY_TAB:
			var cam = get_viewport().get_camera_3d()
			if cam and cam.has_method("toggle_follow"):
				var target: Node3D = null
				if not cam.is_following() and selected_entities.size() == 1:
					target = selected_entities[0]
				cam.toggle_follow(target)
				get_viewport().set_input_as_handled()
			return

		# U键升级
		if key == KEY_U:
			_upgrade_selected()
			get_viewport().set_input_as_handled()
			return

		# F1~F3 全局命令交给 HUD 处理（屏幕内选择/自动进攻/撤退）

		# 选中建筑 → 命令卡热键（队友建筑只读，不能生产/升级/拆除）
		if selected_entities.size() == 1 and not ctrl and not shift and _is_local_owned(selected_entities[0]):
			var e = selected_entities[0]
			if is_instance_valid(e) and e is Building:
				var produces = e.production_list
				var bid = e.get_instance_id()
				var handled = true
				match key:
					KEY_Q: if produces.size() >= 1: bm.produce_unit(e, produces[0].unit_id)
					KEY_W: if produces.size() >= 2: bm.produce_unit(e, produces[1].unit_id)
					KEY_E: if produces.size() >= 3: bm.produce_unit(e, produces[2].unit_id)
					KEY_R: if produces.size() >= 4: bm.produce_unit(e, produces[3].unit_id)
					KEY_F: if produces.size() >= 5: bm.produce_unit(e, produces[4].unit_id)
					KEY_A: bm.upgrade_building(e)
					KEY_G: if bm.has_method("repair_building"): bm.repair_building(e)
					KEY_S: if e.entity_id != 20: bm.demolish_building(e)
					KEY_D: bm.release_garrisoned(e)
					_: handled = false
				if handled:
					get_viewport().set_input_as_handled(); return

		# 选中军队 → 命令卡热键（只对己方单位生效）
		if not selected_entities.is_empty() and not ctrl and not shift and _selection_all_local():
			var army_selected = false
			for e in selected_entities:
				if is_instance_valid(e) and e is Army: army_selected = true; break
			if army_selected and bm:
				# A / M 进入一次性下令模式：下一次左键执行攻击 / 纯移动；
				# 右键或 Esc 取消，避免和原来的全局进攻热键冲突。
				if key == KEY_A:
					bm.set_pending_command_mode("attack")
					get_viewport().set_input_as_handled()
					return
				if key == KEY_M:
					bm.set_pending_command_mode("move")
					get_viewport().set_input_as_handled()
					return
				var handled = true
				match key:
					KEY_Q: bm.clear_orders_for_selected()
					KEY_W: bm.toggle_attack_move_for_selected()
					KEY_E: bm.garrison_nearest_for_selected()
					KEY_R: _select_all_of_same_type(selected_entities[0])
					KEY_S: bm.global_retreat_selected()
					KEY_D: bm.ungarrison_selected()
					KEY_F: bm.toggle_patrol_mode()
					_: handled = false
				if handled:
					get_viewport().set_input_as_handled(); return

		# 数字键 1-9
		if key >= KEY_1 and key <= KEY_9:
			var num = key - KEY_0  # 1-9
			_handle_number_key(num, ctrl, shift)
			get_viewport().set_input_as_handled()
			return

		# 数字键 0 → 清除当前选中单位的编队
		if key == KEY_0:
			if ctrl:
				_clear_control_groups_for_selected()
			elif not selected_entities.is_empty():
				pass  # 0 = no action when units selected
			else:
				_handle_number_key(0, false, false)
			get_viewport().set_input_as_handled()
			return

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_touch_start_pos = event.position
			# A/M 下令模式：下一次左键直接执行，不再进入选择流程
			if bm and bm.has_method("has_pending_command") and bm.has_pending_command():
				bm.execute_pending_command(event.position)
				return
			# Alt+左键 → 即时处理（设置驻扎点；Ctrl+Alt+左键清除驻扎点）
			if Input.is_key_pressed(KEY_ALT) and not selected_entities.is_empty() and _selection_all_local():
				if bm and bm.has_method("_set_garrison_for_selected"):
					if event.ctrl_pressed:
						bm.clear_garrison_for_selected()
					else:
						bm._set_garrison_for_selected(event.position)
				return
			# Mobile: delegate to battle manager for 0.1s delay
			if bm:
				bm._touch_start_pos = event.position
				bm._left_click_timer = bm.CLICK_DELAY
				bm._pending_left_click = true
				bm._left_click_source = "selection"
			var pos = event.position
			var clicked_entity = _get_entity_under_mouse(pos)
			# 己方城墙/桥/运载船：选中军队时优先作为特殊移动目标，不替换选择。
			if clicked_entity and _selection_has_local_army() and bm \
					and bm.has_method("is_special_move_target") \
					and bm.is_special_move_target(clicked_entity):
				if _selection_all_local():
					bm.command_special_target(clicked_entity)
				return
			# 桥/运载船：已有选中单位时发送移动命令(不选中)，兼容射线未命中实体的桥
			if not selected_entities.is_empty():
				var bypass = (clicked_entity and ((clicked_entity is Army and clicked_entity.entity_id == 9) or (clicked_entity is Building and clicked_entity.entity_id == 7)))
				if not bypass and not clicked_entity:
					var gpos = _get_ground_pos(pos)
					var gg = bm.world_to_grid(gpos)
					for e in get_tree().get_nodes_in_group("entities"):
						if e is Building and e.entity_id == 7 or e.entity_id == 27 and e.health > 0:
							if bm.world_to_grid(e.global_position) == gg:
								bypass = true; break
				if bypass:
					if _selection_all_local():
						bm._command_selected_units(event.position)
					return
			var now = Time.get_ticks_msec() / 1000.0
			# 已选中己方部队时，左键点敌方/中立目标优先执行攻击/采集/移动命令，
			# 不再把目标替换成当前选择；只有空手（或只选中建筑/队友）时才允许查看。
			if clicked_entity and _is_inspect_only(clicked_entity) and _selection_has_local_army():
				if bm:
					bm._command_selected_units(event.position)
				return
			if clicked_entity and _can_inspect(clicked_entity):
				# Official garrison: if selected is official and clicked is building, send garrison command
				if clicked_entity is Building and Input.is_key_pressed(KEY_ALT) and _is_local_owned(clicked_entity) and _selection_all_local():
					for e in selected_entities:
						if e is Army and e.entity_id >= 46 and e.entity_id <= 50:
							e.command_garrison(clicked_entity)
							return
				# 建筑只有在当前没有选中任何陆军时才能被选中；已经选中部队时
				# 左键点建筑不替换部队选择，避免查看建筑把整支部队丢掉。
				# 放在 Alt 进驻之后，保证“选中官员 Alt+左键建筑”仍然是驻扎命令。
				if clicked_entity is Building and _selection_has_army():
					return
				# 双击检测：短时间内再次点击同一个实体
				if last_clicked_entity == clicked_entity and (now - last_click_time) < DOUBLE_CLICK_THRESHOLD:
					# 双击：选中屏幕上所有同类型己方实体
					_select_all_of_same_type(clicked_entity)
					last_clicked_entity = null
					last_click_time = 0.0
					return
				last_clicked_entity = clicked_entity
				last_click_time = now
				# 处理单击：Shift追加，否则替换选择（而非追加）
				if clicked_entity in selected_entities:
					if Input.is_key_pressed(KEY_SHIFT):
						_remove_from_selection(clicked_entity)
					else:
						_clear_selection()
				elif Input.is_key_pressed(KEY_SHIFT):
					_add_to_selection(clicked_entity)
				else:
					_clear_selection()
					_add_to_selection(clicked_entity)
			else:
				# 点击空地或不可被查看的实体
				if not selected_entities:
					last_clicked_entity = null
					_clear_selection()
					is_box_selecting = true
					box_start = pos
					box_end = pos
				else:
					# 有己方陆军：空地=移动；只有建筑/只读目标：空地=取消选中
					if _selection_has_local_army():
						bm._command_selected_units(event.position)
					else:
						_clear_selection()
		else:
			_on_left_mouse_released(event)

	elif event is InputEventMouseMotion and is_box_selecting:
		# 更新框选矩形
		# 触摸框选/点选不在这里处理：移动端统一由 TouchGestureRouter 合成鼠标事件后走同一套逻辑
		box_end = event.position
		var r = Rect2(box_start, box_end - box_start).abs()
		box_rect.position = r.position
		box_rect.size = r.size
		box_rect.visible = true



func _on_left_mouse_released(event):
	if is_box_selecting:
		is_box_selecting = false
		box_rect.visible = false
		var rect = Rect2(box_start, box_end - box_start).abs()
		var cam = get_viewport().get_camera_3d()
		if not cam:
			return
		# 遍历所有实体，选中屏幕矩形内的己方单位
		for entity in get_tree().get_nodes_in_group("entities"):
			var bm = get_tree().get_first_node_in_group("battle_manager")
			if _is_local_owned(entity):
				var screen_pos = cam.unproject_position(entity.global_position)
				if rect.has_point(screen_pos):
					_add_to_selection(entity)

# ---------- 选择同类 ----------
func _select_all_of_same_type(target):
	if target == null or not is_instance_valid(target):
		return
	# 敌方/中立只允许单选查看，不按同类批量选中；双击也只保留当前这一个。
	if _is_inspect_only(target):
		_clear_selection()
		_add_to_selection(target)
		return
	var want_ally := _is_teammate_owned(target)
	_clear_selection()
	if target is Army:
		for entity in get_tree().get_nodes_in_group("entities"):
			if entity is Army and entity.display_name == target.display_name:
				if (want_ally and _is_teammate_owned(entity)) or (not want_ally and _is_local_owned(entity)):
					_add_to_selection(entity)
	elif target is Building:
		for entity in get_tree().get_nodes_in_group("entities"):
			if entity is Building and entity.display_name == target.display_name:
				if (want_ally and _is_teammate_owned(entity)) or (not want_ally and _is_local_owned(entity)):
					_add_to_selection(entity)
	elif target is WorldResource:
		# 资源默认只选中自己
		_add_to_selection(target)

# ---------- 射线检测 ----------
# 单位碰撞球只覆盖脚底（半径 body_radius*0.6），点身体中上部时射线多半打不到单位，
# 而是继续穿过去命中旁边建筑的碰撞盒 —— 表现就是「点建筑旁边的单位却选中建筑」。
# 所以射线之外再叠一层屏幕空间轮廓判定：把实体近似成「脚底→模型顶」的竖直胶囊，
# 点在胶囊内或贴着胶囊就算点中；射线打到建筑但点击落在单位轮廓上时以单位为准。
const PICK_ARMY_MARGIN_PX: float = 9.0      # 单位轮廓外允许的容差
const PICK_BUILDING_MARGIN_PX: float = 14.0  # 建筑轮廓外允许的容差
const PICK_SCAN_RADIUS_PX: float = 160.0     # 轮廓判定前的粗筛半径

func _get_entity_under_mouse(screen_pos: Vector2) -> GameEntity:
	var cam := get_viewport().get_camera_3d()
	if not cam:
		return null
	var ray := _raycast_pick(screen_pos)
	var ray_entity: GameEntity = ray.get("entity")
	var ray_pos: Vector3 = ray.get("position", Vector3.ZERO)
	var screen_entity := _pick_by_silhouette(cam, screen_pos)
	# 点击落在单位轮廓上（且单位没被射线打到的建筑挡在后面）→ 单位优先。
	# 单位的碰撞球只有脚底一小颗，建筑碰撞盒横向却比模型宽，两者重叠时
	# 射线永远先打中建筑，必须靠这条把单位捞回来。
	if screen_entity is Army and _silhouette_gap(cam, screen_entity, screen_pos) <= PICK_ARMY_MARGIN_PX:
		if ray_pos == Vector3.ZERO:
			return screen_entity
		# 单位站在命中实体的碰撞盒里（贴着/嵌进建筑底座）→ 玩家点的就是这个单位
		if _point_inside_pick_volume(ray_entity, screen_entity.global_position):
			return screen_entity
		# 否则只有单位在命中点前面才优先，避免选到建筑背后的单位
		if not _is_farther_than_ray(cam, screen_entity, ray_pos):
			return screen_entity
	if ray_entity != null:
		return ray_entity
	return screen_entity

# 单纯的射线拾取（不含任何兜底），返回 {"entity": GameEntity, "position": Vector3}
func _raycast_pick(screen_pos: Vector2) -> Dictionary:
	var cam := get_viewport().get_camera_3d()
	if not cam:
		return {}
	var from := cam.project_ray_origin(screen_pos)
	var to := from + cam.project_ray_normal(screen_pos) * 2000
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 1   # 只检测单位/建筑所在层
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var result := get_viewport().get_world_3d().direct_space_state.intersect_ray(query)
	if result and result.collider is GameEntity:
		return {"entity": result.collider, "position": result.position}
	return {}

# 世界坐标是否落在实体的拾取碰撞盒里（用于判断单位是不是贴着建筑站）
func _point_inside_pick_volume(entity, world_pos: Vector3) -> bool:
	if entity == null or not is_instance_valid(entity):
		return false
	var col := entity.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col == null or col.shape == null:
		return false
	var local: Vector3 = col.global_transform.affine_inverse() * world_pos
	var shape := col.shape
	if shape is BoxShape3D:
		var half: Vector3 = shape.size * 0.5
		return absf(local.x) <= half.x and absf(local.y) <= half.y and absf(local.z) <= half.z
	if shape is SphereShape3D:
		return local.length() <= shape.radius
	return false

# 实体是否比射线命中点更远（被前面的东西挡住），用于避免选到建筑背后的单位
func _is_farther_than_ray(cam: Camera3D, entity, hit_pos: Vector3) -> bool:
	var cam_pos: Vector3 = cam.global_position
	return (cam_pos - entity.global_position).length() > (cam_pos - hit_pos).length() + 0.5

# 实体在屏幕上的竖直轮廓：底=脚底，顶=模型最高点（模型按 2*body_radius 缩放）
func _silhouette(cam: Camera3D, entity) -> Dictionary:
	var height: float = maxf(0.6, entity.body_radius * 2.0)
	var feet: Vector3 = entity.global_position
	var top: Vector3 = feet + Vector3.UP * height
	if cam.is_position_behind(feet) or cam.is_position_behind(top):
		return {}
	var feet_px := cam.unproject_position(feet)
	var top_px := cam.unproject_position(top)
	# 模型宽度约为高度的一半，再给一个下限，缩小/远景时不至于变成一条线
	var half_w: float = clampf(feet_px.distance_to(top_px) * 0.3, 6.0, 60.0)
	return {"a": feet_px, "b": top_px, "w": half_w}

# 点到实体轮廓的像素距离：轮廓内返回 0，轮廓外返回离轮廓边缘的距离
func _silhouette_gap(cam: Camera3D, entity, screen_pos: Vector2) -> float:
	var s := _silhouette(cam, entity)
	if s.is_empty():
		return INF
	var seg_d: float = _point_segment_distance(screen_pos, s["a"], s["b"])
	return maxf(0.0, seg_d - float(s["w"]))

# 屏幕空间最近的可选中实体（单位优先于建筑）
func _pick_by_silhouette(cam: Camera3D, screen_pos: Vector2) -> GameEntity:
	var best: GameEntity = null
	var best_score: float = INF
	for entity in get_tree().get_nodes_in_group("entities"):
		if not (entity is GameEntity) or entity.health <= 0:
			continue
		if not _can_inspect(entity):
			continue
		var anchor: Vector3 = entity.global_position + Vector3.UP * (entity.body_radius * 1.2)
		if cam.is_position_behind(anchor):
			continue
		# 粗筛：投影锚点离点击点太远的不做轮廓计算
		if cam.unproject_position(anchor).distance_to(screen_pos) > PICK_SCAN_RADIUS_PX:
			continue
		var gap := _silhouette_gap(cam, entity, screen_pos)
		var margin: float = PICK_BUILDING_MARGIN_PX if entity is Building else PICK_ARMY_MARGIN_PX
		if gap > margin:
			continue
		# 单位优先：贴合程度相同时选单位，避免建筑把旁边的单位挤掉
		var score: float = gap - (3.0 if entity is Army else 0.0)
		if score < best_score:
			best_score = score
			best = entity
	return best

# 屏幕坐标 → 地面命中点（射线打到的位置，打不到返回 ZERO）
func _get_ground_pos(screen_pos: Vector2) -> Vector3:
	var cam = get_viewport().get_camera_3d()
	if not cam: return Vector3.ZERO
	var from = cam.project_ray_origin(screen_pos)
	var to = from + cam.project_ray_normal(screen_pos) * 2000
	var res = get_viewport().get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(from, to))
	return res.position if res else Vector3.ZERO

# 点到线段的距离（2D）
static func _point_segment_distance(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var len_sq := ab.length_squared()
	if len_sq <= 0.0001:
		return p.distance_to(a)
	var t: float = clampf((p - a).dot(ab) / len_sq, 0.0, 1.0)
	return p.distance_to(a + ab * t)

# 是否属于本地玩家（2v2/3v3 必须按 owner 判断，不能只看 team）
func _is_local_owned(entity) -> bool:
	if entity == null or not is_instance_valid(entity):
		return false
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if not bm: return false
	if bm.has_method("is_local_player_owned"):
		return bm.is_local_player_owned(entity.owner_peer_id, entity.team)
	return entity.team == bm.get_host_team()

# 队友单位：同队但不属于本地玩家（2v2/3v3 的 AI/人类队友）。
# 只允许查看信息与路径球，不允许下命令（生产/升级/拆除/移动等）。
func _is_teammate_owned(entity) -> bool:
	if entity == null or not is_instance_valid(entity):
		return false
	if not (entity is Army or entity is Building):
		return false
	if _is_local_owned(entity):
		return false
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if not bm: return false
	return entity.team == bm.get_host_team()

# 敌方单位：不同队伍、非中立。允许选中查看信息，但不允许下任何命令。
func _is_enemy_owned(entity) -> bool:
	if entity == null or not is_instance_valid(entity):
		return false
	if not (entity is Army or entity is Building):
		return false
	if _is_local_owned(entity) or _is_teammate_owned(entity):
		return false
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if not bm: return false
	if entity.team == RTSConfig.Team.NEUTRAL:
		return false
	return entity.team != bm.get_host_team()

# 中立目标：资源点、动物、废弃建筑/桥等。允许选中查看信息，但同样不允许任何命令。
func _is_neutral_owned(entity) -> bool:
	if entity == null or not is_instance_valid(entity):
		return false
	if not (entity is GameEntity):
		return false
	return entity.team == RTSConfig.Team.NEUTRAL

# 只看不指挥的目标：敌方和所有中立实体。
func _is_inspect_only(entity) -> bool:
	return _is_enemy_owned(entity) or _is_neutral_owned(entity)

# 可被选中查看的实体：自己的 + 队友的 + 当前可见的敌方 + 已探索区域内的中立目标。
# 敌方/中立只读，命令入口另有 _selection_all_local 防御。
func _can_inspect(entity) -> bool:
	if _is_local_owned(entity) or _is_teammate_owned(entity):
		return true
	if _is_enemy_owned(entity) or _is_neutral_owned(entity):
		# 迷雾里的敌人/中立目标不能通过点击碰撞体“隔雾查看”
		var node := entity as Node3D
		return node != null and node.visible
	return false

func _selection_has_army() -> bool:
	for e in selected_entities:
		if is_instance_valid(e) and e is Army:
			return true
	return false

func _selection_has_teammate() -> bool:
	for e in selected_entities:
		if _is_teammate_owned(e):
			return true
	return false

func _selection_has_enemy() -> bool:
	for e in selected_entities:
		if _is_enemy_owned(e):
			return true
	return false

func _selection_has_neutral() -> bool:
	for e in selected_entities:
		if _is_neutral_owned(e):
			return true
	return false

func _selection_all_local() -> bool:
	if selected_entities.is_empty():
		return false
	for e in selected_entities:
		if not _is_local_owned(e):
			return false
	return true

# 当前是否选中了可指挥的己方陆军。用于区分“点敌人/中立=下达命令”和
# “空手点敌人/中立=查看信息”：有己方部队时左键优先当作攻击/采集命令。
func _selection_has_local_army() -> bool:
	for e in selected_entities:
		if e is Army and _is_local_owned(e):
			return true
	return false

# ---------- 选择列表操作 ----------
# 右键点非空目标（且当前无选中）时用于查看信息，不打开建造菜单。
func inspect_entity(entity) -> void:
	if entity == null or not is_instance_valid(entity):
		return
	if entity is GameEntity and entity.health <= 0:
		return
	_clear_selection()
	_add_to_selection(entity)

func _add_to_selection(entity):
	if entity == null or not is_instance_valid(entity) or entity.health <= 0:
		return
	if not _can_inspect(entity):
		return
	# 敌方/中立只允许单选查看：和己方/队友混选会让右键、热键和范围圈都变得不确定。
	if _is_inspect_only(entity):
		if selected_entities.size() != 1 or selected_entities[0] != entity:
			_clear_selection()
	elif _selection_has_enemy() or _selection_has_neutral():
		_clear_selection()
	# 不允许“自己的单位”和“队友单位”混选：否则右键/热键命令会误发给队友
	var ally := _is_teammate_owned(entity)
	if ally and not selected_entities.is_empty() and not _selection_has_teammate():
		_clear_selection()
	elif not ally and _selection_has_teammate():
		_clear_selection()
	if entity not in selected_entities:
		selected_entities.append(entity)
		# 只给前 MAX_SELECTION_RINGS 个显示选择环，避免几百个单位各画一个环。
		entity.set_selected(selected_entities.size() <= MAX_SELECTION_RINGS)
		# 敌方/中立只读：路径/航点属于不可见信息，不展示
		if entity is Army and entity.has_method("show_waypoints") and not _is_inspect_only(entity):
			entity.show_waypoints()
		_request_info_panel_refresh()

# 直接改写 selected_entities 的旧路径（InfoPanel/联机同步/编队召回）不会走
# _add_to_selection，这里统一按上限刷新环显示。
func _refresh_selection_rings() -> void:
	for i in range(selected_entities.size()):
		var e = selected_entities[i]
		if is_instance_valid(e):
			e.set_selected(i < MAX_SELECTION_RINGS)
	# 贴地范围圈（视野/射程/光环）只在单选时画：多选几十个单位各画两圈会把地面糊成一片。
	# Army 内部还会按选择列表兜底判断；Building 也支持同样的圈，这里一并同步。
	var single: bool = selected_entities.size() == 1
	for e in selected_entities:
		if is_instance_valid(e) and (e is Army or e is Building) and e.has_method("set_range_rings_enabled"):
			# 敌方/中立只读：不展示视野/射程/光环，避免把对方参数当战术信息铺在地上
			e.set_range_rings_enabled(single and not _is_inspect_only(e))

func _remove_from_selection(entity):
	if entity == null or not is_instance_valid(entity):
		return
	if entity in selected_entities:
		selected_entities.erase(entity)
		entity.set_selected(false); if entity is Army and entity.has_method("hide_waypoints"): entity.hide_waypoints()
		_request_info_panel_refresh()
func select_all_military():
	_clear_selection()
	for entity in get_tree().get_nodes_in_group("entities"):
		# 运载船属于军队选择范围（ID 9 不再排除），其余经济单位仍排除。
		if entity is Army and _is_local_owned(entity) and entity.health > 0 and entity.entity_id not in [5,6,10,14,43,44,45,51,46,47,48,49,50]:
			_add_to_selection(entity)
func _clear_selection():
	for e in selected_entities:
		if is_instance_valid(e):
			e.set_selected(false)
			if e is Army and e.has_method("hide_waypoints"): e.hide_waypoints()
	selected_entities.clear()
	_request_info_panel_refresh()

func _request_info_panel_refresh() -> void:
	if _info_panel_refresh_pending:
		return
	_info_panel_refresh_pending = true
	call_deferred("_flush_info_panel_refresh")

func _flush_info_panel_refresh() -> void:
	_info_panel_refresh_pending = false
	_update_info_panel()

# ---------- 同步信息面板 ----------
func _update_info_panel():
	_sanitize_entity_refs()
	_refresh_selection_rings()
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if not bm:
		return
	var panel = bm.get_node_or_null("UI/InfoPanel") as InfoPanel
	if not panel:
		return
	if selected_entities.size() == 1:
		panel.update_info(selected_entities[0])
	elif selected_entities.size() > 1:
		panel.show_multi_selection(selected_entities)
	else:
		panel.visible = false

# ==================== 编队系统 ====================
func _set_control_group(group: int):
	control_groups[group] = []
	var count = 0
	for e in selected_entities:
		if is_instance_valid(e) and (e is Army or e is Building) and _is_local_owned(e):
			control_groups[group].append(e)
			count += 1
	print("编队 %d 已设置，共 %d 个单位" % [group, count])
	# 视觉反馈
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if bm and bm.has_node("UI"):
		var hud = bm.get_node("UI")
		if hud and hud.has_method("show_alert_message"):
			hud.show_alert_message("编队 %d 已设置 (%d 单位)" % [group, count], Color(0.3, 0.7, 1.0))

func _recall_control_group(group: int):
	if not control_groups.has(group):
		return
	_clear_selection()
	var count = 0
	for e in control_groups[group]:
		if is_instance_valid(e) and e.health > 0:
			_add_to_selection(e)
			count += 1
	# 视觉反馈
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if bm and bm.has_node("UI"):
		var hud = bm.get_node("UI")
		if hud and hud.has_method("show_alert_message"):
			hud.show_alert_message("编队 %d (%d 单位)" % [group, count], Color(0.3, 0.7, 1.0))

func get_entity_groups(entity: GameEntity) -> Array:
	var groups = []
	for g in control_groups.keys():
		if entity in control_groups[g]:
			groups.append(g)
	return groups

func _clear_control_groups_for_selected():
	for group in control_groups.keys():
		var arr = control_groups[group]
		var to_remove = []
		for e in arr:
			if not is_instance_valid(e) or e in selected_entities:
				to_remove.append(e)
		for e in to_remove:
			arr.erase(e)

# ---- 数字键统一处理 ----
func _handle_number_key(num: int, ctrl: bool, shift: bool):
	# 0=编队0: 仅在没有选中时使用
	if num == 0:
		if selected_entities.is_empty():
			if shift:
				_add_control_group(0)
			else:
				_recall_or_jump(0)
		return

	# 1) Ctrl+单选建筑 → 批量生产5个（队友建筑只读）
	if ctrl and selected_entities.size() == 1 and selected_entities[0] is Building and _is_local_owned(selected_entities[0]):
		var bld = selected_entities[0] as Building
		if bld.production_list.size() >= num:
			var prod = bld.production_list[num - 1]
			for _i in range(5):
				if not bld.try_produce(prod.unit_id): break
		return

	# 2) Ctrl+多选 → 设置编队（编队只收己方单位，敌方/队友只读不编队）
	if ctrl and not selected_entities.is_empty() and _selection_all_local():
		_set_control_group(num)
		return

	# 2) Shift+无选中 → 追加编队
	if shift and selected_entities.is_empty():
		_add_control_group(num)
		return

	# 3) 无Ctrl/Shift + 单选建筑 → 按数字生产（队友建筑只读）
	if not ctrl and not shift and selected_entities.size() == 1 and selected_entities[0] is Building and _is_local_owned(selected_entities[0]):
		var b = selected_entities[0] as Building
		if b.production_list.size() >= num:
			var prod = b.production_list[num - 1]
			b.try_produce(prod.unit_id)
			return

	# 4) 无Ctrl/Shift → 召回编队（无论是否有选中单位）
	if not ctrl and not shift:
		_recall_or_jump(num)
		return

func _recall_or_jump(num: int):
	var now = Time.get_ticks_msec() / 1000.0
	if _last_group_key == num and (now - _last_group_time) < DOUBLE_CLICK_THRESHOLD:
		_jump_to_group(num)
		_last_group_key = -1
		_last_group_time = 0.0
	else:
		_recall_control_group(num)
		_last_group_key = num
		_last_group_time = now

func _jump_to_group(num: int):
	if not control_groups.has(num): return
	var center = _get_group_center(num)
	if center == Vector3.ZERO: return
	var cam = get_viewport().get_camera_3d()
	if cam:
		cam.global_position = Vector3(center.x, cam.global_position.y, center.z)

func _get_group_center(num: int) -> Vector3:
	if not control_groups.has(num): return Vector3.ZERO
	var sum = Vector3.ZERO
	var count = 0
	for e in control_groups[num]:
		if is_instance_valid(e) and e.health > 0:
			sum += e.global_position
			count += 1
	return sum / count if count > 0 else Vector3.ZERO

func _add_control_group(num: int):
	if not control_groups.has(num): return
	for e in control_groups[num]:
		if is_instance_valid(e) and e.health > 0 and e not in selected_entities:
			selected_entities.append(e)
			e.set_selected(true)
			if e is Army and e.has_method("show_waypoints"): e.show_waypoints()
	_update_info_panel()

func _upgrade_selected():
	for e in selected_entities:
		if is_instance_valid(e) and e is Building and _is_local_owned(e) and e.can_upgrade():
			var bm = get_tree().get_first_node_in_group("battle_manager") as RTSBattleManager
			if bm: e.perform_upgrade(bm)

# Tab/M/,/./Space helpers
func _cycle_same_type_sp():
	if selected_entities.is_empty(): select_all_military(); return
	var current_eid = selected_entities[0].entity_id if selected_entities.size()==1 else -1
	var candidates = []
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if bm:
		bm._ensure_cache_fresh()
		for e in bm._armies:
			if e.health<=0 or e.entity_id==14: continue
			if not _is_local_owned(e): continue
			if e.entity_id == current_eid: candidates.append(e)
	if candidates.size()>0:
		var idx = (candidates.find(selected_entities[0])+1) % candidates.size() if current_eid!=-1 and selected_entities.size()==1 else 0
		_clear_selection()
		selected_entities=[candidates[idx]]; candidates[idx].set_selected(true); _update_info_panel()

func _jump_to_castle_sp():
	var bm = get_tree().get_first_node_in_group("battle_manager"); if not bm: return
	bm._ensure_cache_fresh()
	for e in bm._buildings:
		if e.entity_id==20 and e.team==bm.get_host_team():
			var cam = get_viewport().get_camera_3d()
			if cam: cam.global_position = Vector3(e.global_position.x, cam.global_position.y, e.global_position.z); return

var _sp_last_space: float = 0.0
func _handle_space_sp() -> bool:
	var now = Time.get_ticks_msec()/1000.0
	if now-_sp_last_space < 0.3 and not selected_entities.is_empty():
		_sp_last_space = 0.0
		var cam = get_viewport().get_camera_3d(); if not cam: return true
		var avg=Vector3.ZERO; var cnt=0
		for e in selected_entities:
			if is_instance_valid(e): avg+=e.global_position; cnt+=1
		if cnt>0: cam.global_position=Vector3(avg.x/cnt, cam.global_position.y, avg.z/cnt)
		return true
	_sp_last_space = now
	return false

func _cycle_idle_sp(filter_id: int):
	var bm = get_tree().get_first_node_in_group("battle_manager"); if not bm: return
	bm._ensure_cache_fresh()
	var candidates=[]; var team=bm.get_host_team()
	for e in bm._armies:
		if e.health<=0: continue
		if not _is_local_owned(e): continue
		if filter_id==10 and e.entity_id!=10: continue
		if filter_id==-1 and (e.entity_id==10 or e.entity_id==14): continue
		if e.current_order in ["idle",""]: candidates.append(e)
	if candidates.size()==0: return
	_clear_selection()
	selected_entities=[candidates[0]]; candidates[0].set_selected(true); _update_info_panel()

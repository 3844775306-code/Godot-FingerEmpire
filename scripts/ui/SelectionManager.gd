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
# 框选/全选时 _add_to_selection 会被连续调用几十上百次；每次立刻重建
# InfoPanel 会让“框选大部队”明显卡顿。合并到本帧结束只刷新一次。
var _info_panel_refresh_pending: bool = false
# 框选几百个单位时，只为前 N 个显示选择环；每个环都是一次额外 draw call，
# 而大部队的实际操作路径预览本来就只画第一个单位。
const MAX_SELECTION_RINGS: int = 64

# 编队系统
var control_groups: Dictionary = {}   # int → Array[GameEntity]
var _last_group_key: int = -1         # 双击切图检测
var _last_group_time: float = 0.0

func _ready():
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
	# 建筑模式优先：不进行任何选择操作
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if bm and bm.build_mode:
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

		# 无选中 → 快速建造
		if selected_entities.is_empty() and not ctrl and not shift:
			var build_id = -1
			match key:
				KEY_Q: build_id = 28; 
				KEY_W: build_id = 22; 
				KEY_E: build_id = 41
				KEY_R: build_id = 52; 
				KEY_T: build_id = 42; 
				KEY_Y: build_id = 7;
				KEY_A: build_id = 21; 
				KEY_S: build_id = 23; 
				KEY_D: build_id = 24
				KEY_F: build_id = 29; 
				KEY_G: build_id = 54; 
				KEY_H: build_id = 53
				KEY_Z: build_id = 27; 
				KEY_X: build_id = 64; 
				KEY_C: build_id = 25
				KEY_V: build_id = 26; 
				KEY_B: build_id = 8
			if build_id != -1 and bm and bm.can_afford_building(build_id, bm.get_host_team()):
				bm.enter_build_mode(build_id)
				get_viewport().set_input_as_handled(); return

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
				var handled = true
				match key:
					KEY_Q: bm.clear_orders_for_selected()
					KEY_W: bm.toggle_attack_move_for_selected()
					KEY_E: bm.garrison_nearest_for_selected()
					KEY_R: _select_all_of_same_type(selected_entities[0])
					KEY_A: bm.global_attack_selected()
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
			# Alt+左键 → 即时处理（仅己方单位可设置驻扎点）
			if Input.is_key_pressed(KEY_ALT) and not selected_entities.is_empty() and _selection_all_local():
				if bm and bm.has_method("_set_garrison_for_selected"):
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
					# 有选中单位时点击敌方/中立/空地 → 攻击/移动命令；只读选中则取消查看
					if _selection_has_teammate() or _selection_has_enemy() or _selection_has_neutral():
						# 队友/敌方/中立单位无法指挥：点击空地只取消选中
						_clear_selection()
					else:
						bm._command_selected_units(event.position)
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
# 屏幕空间兜底半径（像素）：单位碰撞球只覆盖脚底，靠射线找单位本来就吃力
const PICK_FALLBACK_PX: float = 26.0
# 建筑视觉体积远大于单位，允许更大的兜底半径
const PICK_FALLBACK_BUILDING_PX: float = 58.0

func _get_entity_under_mouse(screen_pos: Vector2) -> GameEntity:
	var cam = get_viewport().get_camera_3d()
	if not cam:
		return null
	var from = cam.project_ray_origin(screen_pos)
	var to = from + cam.project_ray_normal(screen_pos) * 2000
	var space_state = get_viewport().get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 1   # 只检测单位/建筑所在层
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var result = space_state.intersect_ray(query)
	if result and result.collider is GameEntity:
		return result.collider
	# 射线没打中实体：单位的物理球很小又贴在脚底，相机一俯就完全打不到身体，
	# 点半天选不中或者在建筑边上反复选错。这里退化成逐帧投影的屏幕空间最近判定，
	# 投影像素是当帧算出来的，所以天然跟得上视角旋转和俯仰变化。
	return _nearest_entity_on_screen(cam, screen_pos)

# 找屏幕上离点击点最近的实体。单位和建筑用不同阈值，避免建筑把旁边的单位挤掉。
func _nearest_entity_on_screen(cam: Camera3D, screen_pos: Vector2) -> GameEntity:
	var best: GameEntity = null
	var best_px: float = INF
	for entity in get_tree().get_nodes_in_group("entities"):
		if not (entity is GameEntity) or entity.health <= 0:
			continue
		if not _can_inspect(entity):
			continue
		# 用模型中部做锚点：脚底投影在俯角小时会明显偏后，点身体会选不中
		var anchor: Vector3 = entity.global_position + Vector3.UP * _pick_anchor_height(entity)
		if cam.is_position_behind(anchor):
			continue
		var limit: float = PICK_FALLBACK_PX
		if entity is Building:
			limit = PICK_FALLBACK_BUILDING_PX
		var d: float = cam.unproject_position(anchor).distance_to(screen_pos)
		if d > limit:
			continue
		# 同等距离下单位优先：建筑判定块本来就大，不该抢走单位
		if entity is Army:
			d *= 0.75
		if d < best_px:
			best_px = d
			best = entity
	return best

# 锚点取模型腰部：用脚底投影在俯角小时会明显偏后，点身体中部反而选不中
func _pick_anchor_height(entity) -> float:
	return entity.body_radius * 1.2

func _get_ground_pos(screen_pos: Vector2) -> Vector3:
	var cam = get_viewport().get_camera_3d()
	if not cam: return Vector3.ZERO
	var from = cam.project_ray_origin(screen_pos)
	var to = from + cam.project_ray_normal(screen_pos) * 2000
	var res = get_viewport().get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(from, to))
	return res.position if res else Vector3.ZERO

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

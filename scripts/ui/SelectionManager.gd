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
var last_clicked_entity: GameEntity = null
var last_click_time: float = 0.0
const DOUBLE_CLICK_THRESHOLD = 0.3   # 双击时间阈值（秒）

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

func _add_box_rect_to_ui():
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if bm and bm.has_node("UI"):
		bm.get_node("UI").add_child(box_rect)
	else:
		get_tree().root.add_child(box_rect)

# ---------- 输入事件处理 ----------
func _input(event):
	# 建筑模式优先：不进行任何选择操作
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if bm and bm.build_mode:
		return

	# Don't process clicks on interactive UI panels
	if event is InputEventMouseButton:
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
			if build_id != -1 and bm and bm.can_afford_building(build_id, RTSConfig.Team.BLUE):
				bm.enter_build_mode(build_id)
				get_viewport().set_input_as_handled(); return

		# 选中建筑 → 命令卡热键
		if selected_entities.size() == 1 and not ctrl and not shift:
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
					KEY_S: if e.entity_id != 20: bm.demolish_building(e)
					KEY_D: bm.release_garrisoned(e)
					_: handled = false
				if handled:
					get_viewport().set_input_as_handled(); return

		# 选中军队 → 命令卡热键
		if not selected_entities.is_empty() and not ctrl and not shift:
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
			# Alt+左键 → 即时处理
			if Input.is_key_pressed(KEY_ALT) and not selected_entities.is_empty():
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
					bm._command_selected_units(event.position)
					return
			var now = Time.get_ticks_msec() / 1000.0
			if clicked_entity and _is_local_owned(clicked_entity):
				# Official garrison: if selected is official and clicked is building, send garrison command
				if clicked_entity is Building and Input.is_key_pressed(KEY_ALT):
					for e in selected_entities:
						if e is Army and e.entity_id >= 46 and e.entity_id <= 50:
							e._garrison_target_id = clicked_entity.get_instance_id()
							e.move_to(clicked_entity.global_position)
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
				# 点击空地或非己方实体
				if not selected_entities:
					last_clicked_entity = null
					_clear_selection()
					is_box_selecting = true
					box_start = pos
					box_end = pos
				else:
					# 有选中单位时点击敌方/空地 → 攻击/移动命令
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
func _select_all_of_same_type(target: GameEntity):
	_clear_selection()
	if target is Army:
		for entity in get_tree().get_nodes_in_group("entities"):
			if entity is Army and _is_local_owned(entity) and entity.display_name == target.display_name:
				_add_to_selection(entity)
	elif target is Building:
		for entity in get_tree().get_nodes_in_group("entities"):
			if entity is Building and _is_local_owned(entity) and entity.display_name == target.display_name:
				_add_to_selection(entity)
	elif target is WorldResource:
		# 资源默认只选中自己
		_add_to_selection(target)

# ---------- 射线检测 ----------
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
	return null

func _get_ground_pos(screen_pos: Vector2) -> Vector3:
	var cam = get_viewport().get_camera_3d()
	if not cam: return Vector3.ZERO
	var from = cam.project_ray_origin(screen_pos)
	var to = from + cam.project_ray_normal(screen_pos) * 2000
	var res = get_viewport().get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(from, to))
	return res.position if res else Vector3.ZERO

# 是否属于本地玩家（2v2/3v3 必须按 owner 判断，不能只看 team）
func _is_local_owned(entity: GameEntity) -> bool:
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if not bm: return false
	if bm.has_method("is_local_player_owned"):
		return bm.is_local_player_owned(entity.owner_peer_id, entity.team)
	return entity.team == bm.get_host_team()

# ---------- 选择列表操作 ----------
func _add_to_selection(entity: GameEntity):
	if not _is_local_owned(entity):
		return
	if entity not in selected_entities:
		selected_entities.append(entity)
		entity.set_selected(true); if entity is Army and entity.has_method("show_waypoints"): entity.show_waypoints()
		_update_info_panel()

func _remove_from_selection(entity: GameEntity):
	if entity in selected_entities:
		selected_entities.erase(entity)
		entity.set_selected(false); if entity is Army and entity.has_method("hide_waypoints"): entity.hide_waypoints()
		_update_info_panel()
func select_all_military():
	_clear_selection()
	for entity in get_tree().get_nodes_in_group("entities"):
		if entity is Army and _is_local_owned(entity) and entity.health > 0 and entity.entity_id not in [5,6,9,10,14,43,44,45,51,46,47,48,49,50]:
			_add_to_selection(entity)
func _clear_selection():
	for e in selected_entities:
		if is_instance_valid(e):
			e.set_selected(false)
			if e is Army and e.has_method("hide_waypoints"): e.hide_waypoints()
	selected_entities.clear()
	_update_info_panel()

# ---------- 同步信息面板 ----------
func _update_info_panel():
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

		# 1) Ctrl+单选建筑 → 批量生产5个
		if ctrl and selected_entities.size() == 1 and selected_entities[0] is Building:
			var bld = selected_entities[0] as Building
			if bld.production_list.size() >= num:
				var prod = bld.production_list[num - 1]
				for _i in range(5):
					if not bld.try_produce(prod.unit_id): break
			return

		# 2) Ctrl+多选 → 设置编队
		if ctrl and not selected_entities.is_empty():
			_set_control_group(num)
			return

	# 2) Shift+无选中 → 追加编队
	if shift and selected_entities.is_empty():
		_add_control_group(num)
		return

	# 3) 无Ctrl/Shift + 单选建筑 → 按数字生产
	if not ctrl and not shift and selected_entities.size() == 1 and selected_entities[0] is Building:
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
		if is_instance_valid(e) and e is Building and e.can_upgrade():
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

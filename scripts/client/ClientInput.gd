# scripts/client/ClientInput.gd
class_name client_input
extends Node

# 信号
signal selection_changed(selected_ids: Array)
signal auto_attack_changed(on: bool)
signal build_requested(world_pos: Vector3)

# 当前选中实体
var client_selected_ids: Array = []
var auto_attack_on: bool = false

# Local control groups (mirrored with server)
var local_groups: Dictionary = {}  # int -> Array[int]
var _last_group_key: int = -1
var _last_group_time: float = 0.0
const DOUBLE_TAP_THRESHOLD = 0.3

# 框选状态
var is_box_selecting: bool = false
var box_start: Vector2 = Vector2.ZERO
var box_end: Vector2 = Vector2.ZERO
var box_rect: ColorRect

# 双击全选
var last_clicked_id: int = -1
var last_click_time: float = 0.0
const DOUBLE_CLICK_THRESHOLD = 0.3

# 引用客户端渲染器
var renderer: ClientRenderer = null

# 队伍（从渲染器获取）
var player_team: int:
	get:
		if renderer: return renderer.player_team
		return -1

# 用于建造预览的世界坐标
var last_world_pos: Vector3 = Vector3.ZERO
var _mobile_preview_timer: float = 0.0

# Query which groups an entity belongs to
func get_entity_groups(entity_id: int) -> Array:
	var result = []
	for g in local_groups.keys():
		if entity_id in local_groups[g]:
			result.append(g)
	return result

func get_client_selected_ids() -> Array:
	return client_selected_ids

func set_client_selected_ids(ids: Array):
	client_selected_ids = ids.duplicate()
	_update_selection_visuals()
	emit_signal("selection_changed", client_selected_ids.duplicate())

func _is_node_on_screen(node: Node3D) -> bool:
	var cam = get_viewport().get_camera_3d()
	if cam == null: return false
	if cam.projection != Camera3D.PROJECTION_ORTHOGONAL and cam.is_position_behind(node.global_position):
		return false
	return get_viewport().get_visible_rect().has_point(cam.unproject_position(node.global_position))

func _select_military(screen_only: bool):
	if not renderer: return
	client_selected_ids.clear()
	for node in renderer.entity_nodes.values():
		if not node.has_meta("snapshot_info"): continue
		var info = node.get_meta("snapshot_info")
		if not info: continue
		if info["type"] != 2 or info["health"] <= 0: continue
		# 经济单位不计入军队；运载船是唯一例外：全选军队时一并选中，方便直接上船/护航。
		if info["entity_id"] in [10, 14, 5, 6, 43, 44, 45, 51, 46, 47, 48, 49, 50]: continue
		if renderer.my_peer_id != -1 and info.get("owner_peer_id", -1) != renderer.my_peer_id:
			continue
		if renderer.my_peer_id == -1 and info["team"] != renderer.player_team:
			continue
		if screen_only and not _is_node_on_screen(node): continue
		client_selected_ids.append(info["id"])
	_update_selection_visuals()
	emit_signal("selection_changed", client_selected_ids.duplicate())

func select_all_military():
	_select_military(false)

func select_screen_military():
	_select_military(true)

func toggle_auto_attack():
	auto_attack_on = not auto_attack_on
	NetworkManager.send_command.rpc_id(1, {
		"action": "toggle_auto_attack",
		"enabled": auto_attack_on,
	})
	emit_signal("auto_attack_changed", auto_attack_on)

# 屏幕内军队撤退：向自己的主城发送移动指令
func retreat_screen_units():
	if not renderer: return
	var ids: Array = []
	for node in renderer.entity_nodes.values():
		if not node.has_meta("snapshot_info"): continue
		var info = node.get_meta("snapshot_info")
		if not info or info["type"] != 2 or info["health"] <= 0: continue
		if info["entity_id"] in [10, 14, 5, 6, 9, 43, 44, 45, 51, 46, 47, 48, 49, 50]: continue
		if renderer.my_peer_id != -1 and info.get("owner_peer_id", -1) != renderer.my_peer_id: continue
		if renderer.my_peer_id == -1 and info["team"] != renderer.player_team: continue
		if not _is_node_on_screen(node): continue
		ids.append(info["id"])
	if ids.is_empty(): return
	var home = _own_castle_pos()
	if home == null: return
	NetworkManager.send_command.rpc_id(1, {
		"action": "right_click",
		"selected_ids": ids,
		"target_id": -1,
		"pos_x": home.x, "pos_y": home.y, "pos_z": home.z,
		"shift_held": false,
		"formation_offsets": [],
	})

func _own_castle_pos() -> Variant:
	if not renderer: return null
	for node in renderer.entity_nodes.values():
		if not node.has_meta("snapshot_info"): continue
		var info = node.get_meta("snapshot_info")
		if not info or info["type"] != 1 or info["entity_id"] != 20 or info["health"] <= 0: continue
		if renderer.my_peer_id != -1 and info.get("owner_peer_id", -1) != renderer.my_peer_id: continue
		if renderer.my_peer_id == -1 and info["team"] != renderer.player_team: continue
		return node.global_position
	return null

func _ready():
	set_process_input(true)
	set_process(true)
	add_to_group("client_input")
	await get_tree().process_frame
	renderer = get_tree().get_first_node_in_group("client_renderer")
	if not renderer:
		print("[ClientInput] 警告：未找到 client_renderer！")

	# 创建框选矩形
	box_rect = ColorRect.new()
	box_rect.color = Color(0.3, 0.6, 1.0, 0.3)
	box_rect.visible = false
	box_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ui = get_tree().get_first_node_in_group("client_ui")
	if ui: ui.add_child(box_rect)
	else: get_tree().root.add_child(box_rect)

# ==================== 输入处理（照搬单机版 SelectionManager + RTSBattleManager） ====================
func _input(event):
	if not renderer: return

	# 建造放置模式优先
	if renderer.placement_mode:
		# 手机端居中建造：世界触摸只用于平移地图（由 TouchGestureRouter 处理），
		# 不在这里确认，避免拖动地图或点按钮时误放建筑；勾叉由 MobileHUD 转发。
		if renderer.mobile_centered_placement:
			return
		# 鼠标移动
		if event is InputEventMouseMotion:
			_update_placement_preview(event.position)
		# 鼠标点击
		elif event is InputEventMouseButton:
			if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
				_confirm_placement()
			elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
				_cancel_placement()
		# 触摸
		elif event is InputEventScreenTouch:
			if event.pressed:
				_update_placement_preview(event.position)
			else:
				_confirm_placement()
		elif event is InputEventScreenDrag:
			_update_placement_preview(event.position)
		return  # 建造模式下不再处理其他输入

	# 键盘快捷键（照搬 SelectionManager._input）
	if event is InputEventKey and event.pressed:
		var key = event.keycode
		var ctrl = event.ctrl_pressed
		var shift = event.shift_pressed

		# Tab：跟随视角切换（仅单选时；再按 Tab 恢复原视角）
		if key == KEY_TAB:
			var cam = get_viewport().get_camera_3d()
			if cam and cam.has_method("toggle_follow"):
				var target: Node3D = null
				if not cam.is_following() and client_selected_ids.size() == 1:
					target = renderer.entity_nodes.get(client_selected_ids[0])
				cam.toggle_follow(target)
				get_viewport().set_input_as_handled()
			return

		# Delete键 → 拆除建筑

		# F1~F3 全局命令（不受当前是否已选中影响）
		if key == KEY_F1:
			if ctrl: select_all_military()
			else: select_screen_military()
			get_viewport().set_input_as_handled(); return
		if key == KEY_F2:
			toggle_auto_attack()
			get_viewport().set_input_as_handled(); return
		if key == KEY_F3:
			if ctrl:
				NetworkManager.send_command.rpc_id(1, {"action": "global_retreat", "selected_ids": []})
			else:
				retreat_screen_units()
			get_viewport().set_input_as_handled(); return

		# 无选中时 → 快速建造快捷键
		if client_selected_ids.is_empty() and not ctrl and not shift:
			var build_id = -1
			match key:
				KEY_Q: build_id = 28
				KEY_W: build_id = 22
				KEY_E: build_id = 41
				KEY_R: build_id = 52
				KEY_T: build_id = 42
				KEY_Y: build_id = 7
				KEY_A: build_id = 21
				KEY_S: build_id = 23
				KEY_D: build_id = 24
				KEY_F: build_id = 29
				KEY_G: build_id = 54
				KEY_H: build_id = 53
				KEY_Z: build_id = 27
				KEY_X: build_id = 64
				KEY_C: build_id = 25
				KEY_V: build_id = 26
				KEY_B: build_id = 8
			if build_id != -1 and _can_afford_building(build_id):
				renderer.start_build_placement(build_id)
				get_viewport().set_input_as_handled()
				return

			# F4 全军驻扎  F5 统计面板
			if key == KEY_F4:
				NetworkManager.send_command.rpc_id(1, {"action": "toggle_hold_position"})
				get_viewport().set_input_as_handled(); return
			if key == KEY_F5:
				_toggle_stats_panel()
				get_viewport().set_input_as_handled(); return
			if key == KEY_F6:
				print("[ClientInput] F6: AI决策面板 (未实现)")
				get_viewport().set_input_as_handled(); return
			if key == KEY_F7:
				print("[ClientInput] F7: 外交面板 (未实现)")
				get_viewport().set_input_as_handled(); return
			if key == KEY_F8:
				print("[ClientInput] F8: 设置面板 (未实现)")
				get_viewport().set_input_as_handled(); return

			# Tab 同类循环  M 主城  ,.; 循环闲置
			if key == KEY_TAB and not ctrl:
				_cycle_same_type()
				get_viewport().set_input_as_handled(); return
			if key == KEY_M and not ctrl:
				_jump_to_castle()
				get_viewport().set_input_as_handled(); return
			if key == KEY_COMMA:
				_cycle_idle(10)
				get_viewport().set_input_as_handled(); return
			if key == KEY_PERIOD:
				_cycle_idle(-1)
				get_viewport().set_input_as_handled(); return

			# 双击空格: 视角居中选中
			if key == KEY_SPACE and not ctrl:
				_handle_space()
				get_viewport().set_input_as_handled(); return

		# 命令卡网格热键（选中建筑时；队友建筑只读）
		if client_selected_ids.size() == 1 and not ctrl and not shift and _is_own_id(client_selected_ids[0]):
			var sel_info = _get_entity_info(client_selected_ids[0])
			if sel_info.get("type") == 1:
				# 优先用快照里已按等级解锁的 production_list，回退到配置里的完整 produces，
				# 否则会向服务端发送尚未解锁的单位（服务端静默拒绝，表现为“按了没反应”）
				var produces = []
				if sel_info.has("production_list"):
					produces = sel_info.get("production_list", [])
				else:
					produces = EntityDatabase.get_config(sel_info.get("entity_id", -1)).get("produces", [])
				var bid = client_selected_ids[0]
				match key:
					KEY_Q: if produces.size() >= 1: _send_produce(bid, produces[0]["unit_id"])
					KEY_W: if produces.size() >= 2: _send_produce(bid, produces[1]["unit_id"])
					KEY_E: if produces.size() >= 3: _send_produce(bid, produces[2]["unit_id"])
					KEY_R: if produces.size() >= 4: _send_produce(bid, produces[3]["unit_id"])
					KEY_F: if produces.size() >= 5: _send_produce(bid, produces[4]["unit_id"])
					KEY_A: NetworkManager.send_command.rpc_id(1, {"action":"upgrade","building_id":bid})
					KEY_S: if sel_info.get("entity_id") != 20: NetworkManager.send_command.rpc_id(1, {"action":"demolish","building_id":bid})
					KEY_D: NetworkManager.send_command.rpc_id(1, {"action":"ungarrison_soldiers","selected_ids":[bid]})
					_: pass
				if key in [KEY_Q,KEY_W,KEY_E,KEY_R,KEY_F,KEY_A,KEY_S,KEY_D]:
					get_viewport().set_input_as_handled(); return

		# 命令卡网格热键（选中军队时；队友单位只读）
		if not client_selected_ids.is_empty() and not ctrl and not shift and _selection_all_local():
			var army_selected = false
			for sid in client_selected_ids:
				if _get_entity_info(sid).get("type") == 2:
					army_selected = true; break
			if army_selected:
				var handled = true
				match key:
					KEY_Q: NetworkManager.send_command.rpc_id(1, {"action":"clear_order","selected_ids":client_selected_ids.duplicate()})
					KEY_W: NetworkManager.send_command.rpc_id(1, {"action":"toggle_attack_move","selected_ids":client_selected_ids.duplicate()})
					KEY_E: _garrison_nearest()
					KEY_R: _select_all_of_same_type(client_selected_ids[0], _get_entity_info(client_selected_ids[0]))
					KEY_D: NetworkManager.send_command.rpc_id(1, {"action":"ungarrison_soldiers","selected_ids":client_selected_ids.duplicate()})
					KEY_F: _toggle_patrol_mode()
					_: handled = false
				if handled:
					get_viewport().set_input_as_handled(); return

		if key == KEY_DELETE:
			for eid in client_selected_ids.duplicate():
				if not _is_own_id(eid): continue
				var info = _get_entity_info(eid)
				if info.get("type") == 1 and info.get("entity_id") != 20:
					NetworkManager.send_command.rpc_id(1, {"action": "demolish", "building_id": eid})
					client_selected_ids.erase(eid)
			_update_selection_visuals()
			emit_signal("selection_changed", client_selected_ids.duplicate())
			get_viewport().set_input_as_handled()
			return

		# U键升级选中建筑（队友建筑只读）
		if key == KEY_U:
			for eid in client_selected_ids.duplicate():
				if not _is_own_id(eid): continue
				var info = _get_entity_info(eid)
				if info.get("type") == 1:
					NetworkManager.send_command.rpc_id(1, {"action": "upgrade", "building_id": eid})
			get_viewport().set_input_as_handled()
			return

		# 数字键 1-9：单选建筑 → 快速生产（只对自己的建筑）
		if key >= KEY_1 and key <= KEY_9 and not ctrl and not shift and client_selected_ids.size() == 1 and _is_own_id(client_selected_ids[0]):
			if client_selected_ids.size() == 1:
				var info = _get_entity_info(client_selected_ids[0])
				if info.get("type") == 1:  # Building
					var b_cfg = EntityDatabase.get_config(info["entity_id"])
					if b_cfg and b_cfg.has("produces"):
						var produces = b_cfg["produces"]
						var num = key - KEY_0
						if produces.size() >= num:
							var unit_id = produces[num - 1]["unit_id"]
							NetworkManager.send_command.rpc_id(1, {
								"action": "produce",
								"building_id": client_selected_ids[0],
								"unit_id": unit_id,
								"ctrl_held": false,
								"shift_held": false
							})
							get_viewport().set_input_as_handled()
							return

		# 数字键 0-9：编队系统（照搬 SelectionManager._handle_number_key）
		if key >= KEY_0 and key <= KEY_9:
			var g = key - KEY_0
			if ctrl:
				# 编队只收己方单位：队友单位不能被编入并接受命令
				var group_ids: Array = []
				for sid in client_selected_ids:
					if _is_own_id(sid): group_ids.append(sid)
				if group_ids.is_empty():
					if _selection_has_teammate():
						_notify_teammate_readonly()
					get_viewport().set_input_as_handled()
					return
				if g == 0:
					# Ctrl+0 → 清除编队
					for sid in group_ids:
						for k in local_groups.keys():
							local_groups[k].erase(sid)
					NetworkManager.send_command.rpc_id(1, {"action": "set_group", "group": 0, "selected_ids": group_ids})
				else:
					# Ctrl+数字 → 设置编队
					local_groups[g] = group_ids.duplicate()
					NetworkManager.send_command.rpc_id(1, {"action": "set_group", "group": g, "selected_ids": group_ids})
					var chud = _get_client_hud()
					if chud and chud.has_method("show_alert_message"):
						chud.show_alert_message("编队 %d 已设置 (%d 单位)" % [g, group_ids.size()], Color(0.3, 0.7, 1.0))
			else:
				# 数字 → 召回编队
				var now = Time.get_ticks_msec() / 1000.0
				if local_groups.has(g):
					if _last_group_key == g and (now - _last_group_time) < DOUBLE_TAP_THRESHOLD:
						_jump_camera_to_group(g)
						_last_group_key = -1
						_last_group_time = 0.0
					else:
						client_selected_ids = local_groups[g].duplicate()
						emit_signal("selection_changed", client_selected_ids.duplicate())
						_update_selection_visuals()
						_last_group_key = g
						_last_group_time = now
				NetworkManager.send_command.rpc_id(1, {"action": "recall_group", "group": g})
			get_viewport().set_input_as_handled()
			return

	# ========== 左键处理（照搬 SelectionManager._input） ==========
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		# 移动端：触屏面板上的点击交给 GUI，不做世界选择
		if _is_mobile_ui_point(event.position):
			return
		if event.pressed:
			# Alt+左键 → 设置驻扎点（仅己方单位）
			if Input.is_key_pressed(KEY_ALT) and not client_selected_ids.is_empty() and _selection_all_local():
				var ground_pos = _get_ground_position(event.position)
				if ground_pos != Vector3.ZERO:
					NetworkManager.send_command.rpc_id(1, {
						"action": "set_garrison",
						"selected_ids": client_selected_ids.duplicate(),
						"pos_x": ground_pos.x, "pos_y": ground_pos.y, "pos_z": ground_pos.z
					})
					var chud = _get_client_hud()
					if chud and chud.has_method("show_alert_message"):
						chud.show_alert_message("已设置驻扎点", Color(0.3, 0.7, 1.0))
				get_viewport().set_input_as_handled()
				return

			var pos = event.position
			var clicked_id = _get_entity_id_under_mouse(pos)

			# 桥/运载船：已有选中单位时发送移动命令(不选中)
			if not client_selected_ids.is_empty():
				var bypass = false
				if clicked_id != -1:
					var cinfo = _get_entity_info(clicked_id)
					if cinfo and ((cinfo.get("entity_id") == 9) or (cinfo.get("entity_id") == 7)):
						bypass = true
				if not bypass and clicked_id == -1:
					# 桥可能射线未命中，用grid后备检测
					var gpos = _get_ground_position(pos)
					if gpos != Vector3.ZERO:
						for node in renderer.entity_nodes.values():
							if not node.has_meta("snapshot_info"): continue
							var ninfo = node.get_meta("snapshot_info")
							if ninfo and ninfo.get("entity_id") == 7 and ninfo.get("health", 0) > 0:
								if node.global_position.distance_to(gpos) < 1.5:
									bypass = true; break
				if bypass:
					_send_left_click(event)
					return

			# Ctrl+左键点击己方建筑 → 进驻（官员/农民/军队统一）
			if Input.is_key_pressed(KEY_CTRL) and not client_selected_ids.is_empty() and clicked_id != -1:
				var tgt_info = _get_entity_info(clicked_id)
				if tgt_info and tgt_info.get("health", 0) > 0:
					var is_friendly = false
					if renderer.my_peer_id != -1:
						is_friendly = tgt_info.get("owner_peer_id", -1) == renderer.my_peer_id
					else:
						is_friendly = tgt_info.get("team", -1) == renderer.player_team
					if is_friendly and tgt_info.get("type") == 1:
						_send_left_click(event)
						get_viewport().set_input_as_handled()
						return

			# 点击己方/队友实体 → 选中（队友单位只可查看，不可指挥）
			if clicked_id != -1:
				var info = _get_entity_info(clicked_id)
				if not info: return

				var is_own := _is_own_id(clicked_id)
				var is_ally := _is_teammate_id(clicked_id)
				if not is_own and not is_ally:
					_send_left_click(event)  # 敌方 → 攻击命令
					return

				if info["health"] <= 0: return

				# 双击全选同类
				var now = Time.get_ticks_msec() / 1000.0
				if last_clicked_id == clicked_id and (now - last_click_time) < DOUBLE_CLICK_THRESHOLD:
					_select_all_of_same_type(clicked_id, info)
					last_clicked_id = -1
					last_click_time = 0.0
					return
				last_clicked_id = clicked_id
				last_click_time = now

				# 单击：Shift追加，否则替换选择；己方与队友不混选，避免命令误发
				if Input.is_key_pressed(KEY_SHIFT) and not client_selected_ids.is_empty():
					if _selection_all_local() != is_own:
						client_selected_ids.clear()
				if clicked_id in client_selected_ids:
					if Input.is_key_pressed(KEY_SHIFT):
						client_selected_ids.erase(clicked_id)
					else:
						client_selected_ids.clear()
				elif Input.is_key_pressed(KEY_SHIFT):
					client_selected_ids.append(clicked_id)
				else:
					client_selected_ids.clear()
					client_selected_ids.append(clicked_id)

				emit_signal("selection_changed", client_selected_ids.duplicate())
				_update_selection_visuals()
			else:
				# 点击空地或非己方实体
				if client_selected_ids.is_empty():
					# 无选中 + 空地 → 立即启动框选（照搬单机版）
					last_clicked_id = -1
					client_selected_ids.clear()
					_update_selection_visuals()
					emit_signal("selection_changed", [])
					is_box_selecting = true
					box_start = pos
					box_end = pos
				else:
					# 有选中单位 + 点击空地/敌方 → 攻击/移动命令
					# 队友单位只可查看：取消选中，不发送任何命令
					if _selection_has_teammate():
						client_selected_ids.clear()
						_update_selection_visuals()
						emit_signal("selection_changed", [])
					else:
						_send_left_click(event)
		else:
			# 左键松开 → 处理框选
			_on_left_release(event)

	# ========== 框选更新（照搬 SelectionManager: elif MouseMotion and is_box_selecting） ==========
	elif event is InputEventMouseMotion and is_box_selecting:
		box_end = event.position
		var r = Rect2(box_start, box_end - box_start).abs()
		box_rect.position = r.position
		box_rect.size = r.size
		box_rect.visible = true

func _on_left_release(_event):
	if is_box_selecting:
		is_box_selecting = false
		box_rect.visible = false
		var rect = Rect2(box_start, box_end - box_start).abs()
		var cam = get_viewport().get_camera_3d()
		if not cam: return
		for node in renderer.entity_nodes.values():
			if not node.has_meta("snapshot_info"): continue
			var info = node.get_meta("snapshot_info")
			if not info: continue
			# 2v2 权限过滤
			if renderer.my_peer_id != -1 and info.get("owner_peer_id", -1) != renderer.my_peer_id:
				continue
			# 单机：只能选己方
			if renderer.my_peer_id == -1 and info.get("team", -1) != renderer.player_team:
				continue
			if info["health"] <= 0: continue
			var screen_pos = cam.unproject_position(node.global_position)
			if rect.has_point(screen_pos):
				if info["id"] not in client_selected_ids:
					client_selected_ids.append(info["id"])
		emit_signal("selection_changed", client_selected_ids.duplicate())
		_update_selection_visuals()

func _select_all_of_same_type(target_id: int, info: Dictionary):
	var target_is_ally := _is_teammate_id(target_id)
	client_selected_ids.clear()
	var target_entity_id = info.get("entity_id", -1)
	if target_entity_id == -1: return
	for node in renderer.entity_nodes.values():
		if not node.has_meta("snapshot_info"): continue
		var ent_info = node.get_meta("snapshot_info")
		if not ent_info: continue
		if target_is_ally:
			if int(ent_info.get("team", -1)) != renderer.player_team: continue
			if int(ent_info.get("owner_peer_id", -1)) == renderer.my_peer_id: continue
		else:
			if not _is_own_id(ent_info["id"]): continue
		if ent_info.get("entity_id") == target_entity_id and ent_info["health"] > 0:
			client_selected_ids.append(ent_info["id"])
	emit_signal("selection_changed", client_selected_ids.duplicate())
	_update_selection_visuals()

# ==================== 右键处理（照搬单机版 _handle_right_click） ====================
func _unhandled_input(event):
	if not renderer: return
	# 右键 → 命令/建造（照搬单机版：_unhandled_input 只处理右键）
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		# Alt+右键 → 清除驻扎点（仅己方单位）
		if Input.is_key_pressed(KEY_CTRL) and not client_selected_ids.is_empty() and _selection_all_local():
			var hit_id = _get_entity_id_under_mouse(event.position)
			if hit_id == -1:
				NetworkManager.send_command.rpc_id(1, {"action": "clear_garrison", "selected_ids": client_selected_ids.duplicate()})
			return

		# 无选中 + 右键空地 → 打开建造菜单（照搬单机版 _try_open_build_menu）
		if client_selected_ids.is_empty():
			var ground_pos = _get_ground_position(event.position)
			if ground_pos != Vector3.ZERO:
				emit_signal("build_requested", ground_pos)
			return

		# 右键空地 → 取消选择（照搬单机版：hit==null → clear selection）
		var hit_id = _get_entity_id_under_mouse(event.position)
		if hit_id == -1:
			client_selected_ids.clear()
			_update_selection_visuals()
			emit_signal("selection_changed", [])
		else:
			_send_left_click(event)

# ---------- 命令发送 ----------
func _send_left_click(event):
	if not renderer: return
	# 队友单位只可查看，不能被指挥（防御性拦截，正常选择流程不会走到这里）
	if _selection_has_teammate():
		_notify_teammate_readonly()
		return
	var cam = get_viewport().get_camera_3d()
	if not cam: return
	var from = cam.project_ray_origin(event.position)
	var to = from + cam.project_ray_normal(event.position) * 2000
	var space_state = get_viewport().get_world_3d().direct_space_state

	var query_entity = PhysicsRayQueryParameters3D.create(from, to)
	query_entity.collide_with_bodies = true
	query_entity.collision_mask = 1
	var result_entity = space_state.intersect_ray(query_entity)

	var target_id = -1
	var pos = Vector3.ZERO
	var formation_offsets = []

	if result_entity and result_entity.collider.has_meta("entity_root"):
		var root = result_entity.collider.get_meta("entity_root")
		var info = root.get_meta("snapshot_info", null)
		if info:
			target_id = info["id"]
			pos = root.global_position
	else:
		pos = _get_ground_position(event.position)
		if pos == Vector3.ZERO: return
		# Formation spread for multi-unit ground move
		var count = client_selected_ids.size()
		if count > 1:
			var cols = int(ceil(sqrt(count)))
			var spacing = 1.0
			for i in count:
				var row = i / cols
				var col = i % cols
				var ox = (col - (cols - 1) / 2.0) * spacing
				var oy = (row - (cols / 2.0)) * spacing
				formation_offsets.append(Vector3(ox, 0, oy))

	var cmd = {
		"action": "right_click",
		"selected_ids": client_selected_ids.duplicate(),
		"target_id": target_id,
		"pos_x": pos.x, "pos_y": pos.y, "pos_z": pos.z,
		"shift_held": Input.is_key_pressed(KEY_SHIFT),
		"formation_offsets": formation_offsets,
	}
	NetworkManager.send_command.rpc_id(1, cmd)

# ---------- 工具函数 ----------
func _get_entity_id_under_mouse(screen_pos: Vector2) -> int:
	var cam = get_viewport().get_camera_3d()
	if not cam: return -1
	var from = cam.project_ray_origin(screen_pos)
	var to = from + cam.project_ray_normal(screen_pos) * 2000
	var space_state = get_viewport().get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_bodies = true
	query.collision_mask = 1
	var result = space_state.intersect_ray(query)
	if result and result.collider.has_meta("entity_root"):
		var root = result.collider.get_meta("entity_root")
		var info = root.get_meta("snapshot_info", null)
		if info: return info["id"]
	return -1

func _get_entity_info(id: int) -> Dictionary:
	if not renderer: return {}
	for node in renderer.entity_nodes.values():
		if not node.has_meta("snapshot_info"): continue
		var info = node.get_meta("snapshot_info")
		if info and info["id"] == id:
			return info
	return {}

# ==================== 归属判断（队友可查看、不可指挥） ====================

func _is_own_id(id: int) -> bool:
	var info = _get_entity_info(id)
	if info.is_empty(): return false
	if renderer.my_peer_id != -1:
		return int(info.get("owner_peer_id", -1)) == renderer.my_peer_id
	return int(info.get("team", -1)) == renderer.player_team

# 队友：同队但 owner 不是本地玩家（2v2/3v3）
func _is_teammate_id(id: int) -> bool:
	var info = _get_entity_info(id)
	if info.is_empty(): return false
	if renderer.my_peer_id == -1: return false
	if int(info.get("team", -1)) != renderer.player_team: return false
	return int(info.get("owner_peer_id", -1)) != renderer.my_peer_id

func _selection_all_local() -> bool:
	if client_selected_ids.is_empty(): return false
	for sid in client_selected_ids:
		if not _is_own_id(sid): return false
	return true

func _selection_has_teammate() -> bool:
	for sid in client_selected_ids:
		if _is_teammate_id(sid): return true
	return false

func _notify_teammate_readonly():
	var chud = _get_client_hud()
	if chud and chud.has_method("show_alert_message"):
		chud.show_alert_message("队友单位仅可查看，无法指挥", Color(1.0, 0.75, 0.2))

func _get_ground_position(screen_pos: Vector2) -> Vector3:
	var cam = get_viewport().get_camera_3d()
	if not cam: return Vector3.ZERO
	var from = cam.project_ray_origin(screen_pos)
	var to = from + cam.project_ray_normal(screen_pos) * 2000
	var space_state = get_viewport().get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_bodies = true
	query.collision_mask = 2   # 地面层
	var result = space_state.intersect_ray(query)
	return result.position if result else Vector3.ZERO

func _process(_delta):
	# 每帧更新选择环位置（跟随目标）
	if selection_rings.size() > 0:
		_process_selection_rings()
	# 手机端居中建造：地图平移后，预览重新落到屏幕中心
	if renderer and renderer.placement_mode and renderer.mobile_centered_placement:
		_mobile_preview_timer -= _delta
		if _mobile_preview_timer <= 0.0:
			_mobile_preview_timer = 0.05
			_update_placement_preview(_viewport_center())

func get_last_world_pos() -> Vector3:
	return last_world_pos

func _get_client_hud():
	return get_tree().get_first_node_in_group("client_hud")

# 移动端：判断屏幕坐标是否落在触屏面板上（面板点击由 GUI 处理）
func _is_mobile_ui_point(pos: Vector2) -> bool:
	var mh = get_tree().get_first_node_in_group("mobile_hud")
	if mh and mh.has_method("is_point_over_panel"):
		return bool(mh.call("is_point_over_panel", pos))
	return false

func _jump_camera_to_group(g: int):
	if not local_groups.has(g): return
	var center = Vector3.ZERO
	var count = 0
	for eid in local_groups[g]:
		var node = renderer.entity_nodes.get(eid)
		if node and node.has_meta("snapshot_info"):
			var info = node.get_meta("snapshot_info")
			if info.get("health", 0) > 0:
				center += node.global_position
				count += 1
	if count == 0: return
	center /= count
	var cam = get_viewport().get_camera_3d()
	if cam:
		cam.global_position = Vector3(center.x, cam.global_position.y, center.z)

# ---------- 选择环 ----------
var selection_rings: Dictionary = {}
func _update_selection_visuals():
	for rid in selection_rings.keys():
		if is_instance_valid(selection_rings[rid]):
			selection_rings[rid].queue_free()
	selection_rings.clear()
	for id in client_selected_ids:
		_create_ring_for_entity(id)

func _create_ring_for_entity(id):
	var node = renderer.entity_nodes.get(id)
	if not node: return
	if not node.has_meta("snapshot_info"): return
	var info = node.get_meta("snapshot_info")
	if not info: return
	var radius: float = info.get("body_radius", 0.5)
	var kind: int = int(info.get("type", 0))   # 0=军队 1=建筑 2=资源
	var ring = MeshInstance3D.new()
	ring.name = "ClientSelectionRing"
	ring.mesh = TorusMesh.new()
	# 与单机版保持完全一致：军队/建筑/资源三种半径与贴地高度分别对齐
	match kind:
		1:
			ring.mesh.inner_radius = radius + 0.2
			ring.mesh.outer_radius = radius + 0.35
			ring.position = Vector3(0, radius * 1.5 + 0.1, 0)
		2:
			ring.mesh.inner_radius = radius + 0.1
			ring.mesh.outer_radius = radius + 0.2
			ring.position = Vector3(0, 0.1, 0)
		_:
			ring.mesh.inner_radius = radius + 0.1
			ring.mesh.outer_radius = radius + 0.15
			ring.position = Vector3(0, radius * 2.5 + 0.1, 0)
	ring.material_override = StandardMaterial3D.new()
	# 单机版选中的都是自己的单位（绿色）；联机按"自己队伍"判断，队友也绿色，敌方红色
	var ring_team: int = int(info.get("team", -1))
	var own_team: int = -1
	if renderer and renderer.get("player_team") != null:
		own_team = int(renderer.player_team)
	if own_team == -1:
		ring.material_override.albedo_color = Color.GREEN
	elif ring_team == own_team:
		ring.material_override.albedo_color = Color.GREEN
	else:
		ring.material_override.albedo_color = Color.RED
	ring.material_override.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	node.add_child(ring)
	selection_rings[id] = ring

func _process_selection_rings():
	# 每帧更新选择环的位置（跟随目标移动）
	var to_remove = []
	for id in selection_rings.keys():
		var ring = selection_rings[id]
		if not is_instance_valid(ring):
			to_remove.append(id)
			continue
		var node = renderer.entity_nodes.get(id)
		if not is_instance_valid(node):
			ring.queue_free()
			to_remove.append(id)
			continue
		if not node.has_meta("snapshot_info"):
			ring.queue_free()
			to_remove.append(id)
	for id in to_remove:
		selection_rings.erase(id)

# ---------- 建造放置 ----------
func _update_placement_preview(screen_pos: Vector2):
	var cam = get_viewport().get_camera_3d()
	if not cam or not renderer.placement_preview: return
	var from = cam.project_ray_origin(screen_pos)
	var to = from + cam.project_ray_normal(screen_pos) * 2000
	var space_state = get_viewport().get_world_3d().direct_space_state

	var query = PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_bodies = true
	query.collision_mask = 2
	var result = space_state.intersect_ray(query)

	var ground_pos = Vector3.ZERO
	var hit_ground = false
	if result:
		ground_pos = result.position
		hit_ground = true
	else:
		var plane_normal = Vector3.UP
		var plane_point = Vector3.ZERO
		var dir = (to - from).normalized()
		var denom = dir.dot(plane_normal)
		if abs(denom) > 0.0001:
			var t = (plane_point - from).dot(plane_normal) / denom
			if t > 0:
				ground_pos = from + dir * t
				hit_ground = true

	if hit_ground:
		var pos = ground_pos
		pos.x = round(pos.x)
		pos.z = round(pos.z)
		pos.y = renderer.get_terrain_height(pos)
		last_world_pos = pos

		var in_vision = renderer.is_in_player_vision(pos)
		var terrain_ok = renderer.get_terrain_at(pos) != 2
		if renderer.placement_building_id == 23:
			terrain_ok = renderer.get_terrain_at(pos) == 0 and _check_adjacent_water(pos)
		elif renderer.placement_building_id == 7:
			terrain_ok = _check_bridge_placement(pos)

		renderer.placement_preview.global_position = pos
		renderer.placement_preview.visible = true
		renderer._tint_preview(renderer.placement_preview, Color.GREEN if (in_vision and terrain_ok) else Color.RED)
	else:
		renderer.placement_preview.visible = false

func _confirm_placement():
	var pos = renderer.placement_preview.global_position
	var no_enemy_nearby = true
	for node in renderer.entity_nodes.values():
		if not node.has_meta("snapshot_info"): continue
		var info = node.get_meta("snapshot_info")
		if info and info["team"] != renderer.player_team and info["team"] != RTSConfig.Team.NEUTRAL and info["health"] > 0:
			if node.global_position.distance_to(pos) < 10.0:
				no_enemy_nearby = false; break
	var valid = renderer.is_in_player_vision(pos) and renderer.get_terrain_at(pos) != 2 and no_enemy_nearby
	if renderer.placement_building_id == 23:
		valid = valid and renderer.get_terrain_at(pos) == 0 and _check_adjacent_water(pos)
	elif renderer.placement_building_id == 7:
		# 桥允许建在水上，地形/邻接条件全部交给 _check_bridge_placement
		valid = renderer.is_in_player_vision(pos) and no_enemy_nearby and _check_bridge_placement(pos)
	if not valid: return
	var cmd = {
		"action": "build",
		"building_id": renderer.placement_building_id,
		"pos_x": pos.x, "pos_y": pos.y, "pos_z": pos.z
	}
	NetworkManager.send_command.rpc_id(1, cmd)
	var keep_building := Input.is_key_pressed(KEY_SHIFT)
	if InputSource.use_mobile_ui():
		keep_building = keep_building or GameSettings.mobile_continuous_build
	if not keep_building:
		_cancel_placement()
	else:
		_update_placement_preview(_viewport_center())

func _cancel_placement():
	renderer.placement_mode = false
	renderer.placement_building_id = -1
	renderer.mobile_centered_placement = false
	if renderer.placement_preview:
		renderer.placement_preview.visible = false

# 手机端勾选：在屏幕中央确认放置；连续建造开时保持放置模式
func confirm_mobile_placement() -> void:
	if not renderer or not renderer.placement_mode:
		return
	_update_placement_preview(_viewport_center())
	_confirm_placement()

# 手机端叉号：无条件退出放置模式
func cancel_mobile_placement() -> void:
	if renderer and renderer.placement_mode:
		_cancel_placement()

func update_centered_placement_preview() -> void:
	if renderer and renderer.placement_mode and renderer.mobile_centered_placement:
		_update_placement_preview(_viewport_center())

func _viewport_center() -> Vector2:
	return get_viewport().get_visible_rect().size * 0.5

func _check_adjacent_water(world_pos: Vector3) -> bool:
	var gx = int(world_pos.x + RTSConfig.MAP_SIZE / 2)
	var gz = int(world_pos.z + RTSConfig.MAP_SIZE / 2)
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			if dx == 0 and dy == 0: continue
			if renderer.get_terrain_at_grid(gx+dx, gz+dy) == 2:
				return true
	return false

# 桥(7)：只能建在水上，不能与其他实体重叠（已有桥除外），
# 且至少有一侧正交邻格是陆地或已有桥（与单机 RTSBattleManager._is_valid_build_position 一致）
func _check_bridge_placement(world_pos: Vector3) -> bool:
	if renderer.get_terrain_at(world_pos) != 2: return false
	var gx = int(world_pos.x + RTSConfig.MAP_SIZE / 2)
	var gz = int(world_pos.z + RTSConfig.MAP_SIZE / 2)
	for node in renderer.entity_nodes.values():
		if not is_instance_valid(node) or not node.has_meta("snapshot_info"): continue
		var info = node.get_meta("snapshot_info")
		if info.is_empty() or info.get("health", 0) <= 0: continue
		if info.get("type") == 1 and info.get("entity_id", -1) == 7: continue
		if node.global_position.distance_to(world_pos) < float(info.get("body_radius", 0.0)) + 0.5:
			return false
	for dx in [-1, 0, 1]:
		for dy in [-1, 0, 1]:
			if abs(dx) + abs(dy) != 1: continue
			var nx = gx + dx; var ny = gz + dy
			if nx < 0 or nx >= RTSConfig.MAP_SIZE or ny < 0 or ny >= RTSConfig.MAP_SIZE: continue
			if renderer.get_terrain_at_grid(nx, ny) != 2: return true
			for node in renderer.entity_nodes.values():
				if not is_instance_valid(node) or not node.has_meta("snapshot_info"): continue
				var info = node.get_meta("snapshot_info")
				if info.get("type") != 1 or info.get("entity_id", -1) != 7 or info.get("health", 0) <= 0: continue
				var bgx = int(node.global_position.x + RTSConfig.MAP_SIZE / 2)
				var bgz = int(node.global_position.z + RTSConfig.MAP_SIZE / 2)
				if bgx == nx and bgz == ny: return true
	return false

# ---------- 集结模式 ----------

# 检查是否负担得起建筑
func _can_afford_building(build_id: int) -> bool:
	var cfg = EntityDatabase.get_config(build_id)
	if cfg.is_empty(): return false
	# 解锁检查
	var clv = renderer.get_player_castle_level() if renderer else 1
	const REQ = {64:2, 23:2, 25:2, 26:2, 24:3, 29:3, 52:3, 42:3, 53:4, 54:4}
	if REQ.has(build_id) and clv < REQ[build_id]: return false
	var cost = cfg.get("cost", {})
	if cost.is_empty(): return true
	var hud = _get_client_hud()
	if not hud: return true
	for res in cost:
		var have = hud._get_player_resource(res)
		if have < cost[res]: return false
	return true




# 进驻最近的可进驻建筑/攻城车/运载船
func _garrison_nearest():
	if not renderer: return
	var best_dist = 30.0 * 30.0; var best_target = null; var best_id = -1
	for node in renderer.entity_nodes.values():
		if not node.has_meta("snapshot_info"): continue
		var info = node.get_meta("snapshot_info")
		var eid = info.get("entity_id", -1)
		# 建筑(有进驻槽)、攻城车、运载船
		var garrisonable = (info.get("type") == 1 and eid in [20,21,22,23,24,25,26,29,41,42,52,53,54]) or eid == 18 or eid == 9
		if not garrisonable: continue
		# 检查是否是己方
		var friendly = (renderer.my_peer_id != -1 and info.get("owner_peer_id", -1) == renderer.my_peer_id)
		if not friendly and renderer.my_peer_id == -1: friendly = info.get("team", -1) == renderer.player_team
		if not friendly: continue
		var d = node.global_position.distance_squared_to(_get_avg_selected_pos())
		if d < best_dist: best_dist = d; best_target = node; best_id = info["id"]
	if best_target:
		var cmd = {"action":"right_click","selected_ids":client_selected_ids.duplicate(),"target_id":best_id,"pos_x":best_target.global_position.x,"pos_y":best_target.global_position.y,"pos_z":best_target.global_position.z,"shift_held":false,"formation_offsets":[]}
		NetworkManager.send_command.rpc_id(1, cmd)

func _get_avg_selected_pos() -> Vector3:
	var pos = Vector3.ZERO; var cnt = 0
	for sid in client_selected_ids:
		var node = renderer.entity_nodes.get(sid)
		if node: pos += node.global_position; cnt += 1
	return pos / cnt if cnt > 0 else Vector3.ZERO

# 巡逻模式切换
var _patrol_mode: bool = false
func _toggle_patrol_mode():
	_patrol_mode = not _patrol_mode
	var chud = _get_client_hud()
	if chud and chud.has_method("show_alert_message"):
		chud.show_alert_message("巡逻模式: " + ("开启(点击设置巡逻点)" if _patrol_mode else "关闭"), Color(0.3, 1.0, 0.5) if _patrol_mode else Color(0.5,0.5,0.5))

func _send_produce(bid: int, uid: int):
	# 队友建筑只可查看，不能生产
	if not _is_own_id(bid):
		_notify_teammate_readonly()
		return
	NetworkManager.send_command.rpc_id(1, {"action":"produce","building_id":bid,"unit_id":uid,"ctrl_held":false,"shift_held":false})

# Tab: 同类循环选择
func _cycle_same_type():
	if client_selected_ids.is_empty():
		select_all_military()
		return
	var current_eid = -1
	if client_selected_ids.size() == 1:
		current_eid = _get_entity_info(client_selected_ids[0]).get("entity_id", -1)
	var candidates = []
	for node in renderer.entity_nodes.values():
		if not node.has_meta("snapshot_info"): continue
		var inf = node.get_meta("snapshot_info")
		if inf.get("type") != 2: continue
		if inf.get("health",0) <= 0: continue
		if renderer.my_peer_id != -1 and inf.get("owner_peer_id",-1) != renderer.my_peer_id: continue
		if inf.get("entity_id") == current_eid: candidates.append(inf["id"])
	if candidates.size() > 0:
		client_selected_ids = [candidates[0] if current_eid == -1 else candidates[(candidates.find(client_selected_ids[0])+1) % candidates.size()]]
		_update_selection_visuals()
		emit_signal("selection_changed", client_selected_ids.duplicate())

# M: 跳转主城
func _jump_to_castle():
	var cam = get_viewport().get_camera_3d(); if not cam: return
	for node in renderer.entity_nodes.values():
		if not node.has_meta("snapshot_info"): continue
		var inf = node.get_meta("snapshot_info")
		if inf.get("entity_id") == 20 and inf.get("type") == 1:
			if renderer.my_peer_id != -1 and inf.get("owner_peer_id",-1) != renderer.my_peer_id: continue
			cam.global_position = Vector3(node.global_position.x, cam.global_position.y, node.global_position.z); return

# Space: 单击跳警报 / 双击居中选中
var _last_space_time: float = 0.0
func _handle_space() -> bool:
	var now = Time.get_ticks_msec() / 1000.0
	if now - _last_space_time < DOUBLE_TAP_THRESHOLD and not client_selected_ids.is_empty():
		_last_space_time = 0.0
		var cam = get_viewport().get_camera_3d(); if not cam: return true
		var avg = Vector3.ZERO; var cnt = 0
		for sid in client_selected_ids:
			var node = renderer.entity_nodes.get(sid)
			if node: avg += node.global_position; cnt += 1
		if cnt > 0: cam.global_position = Vector3(avg.x/cnt, cam.global_position.y, avg.z/cnt)
		return true
	_last_space_time = now
	# 单击：跳警报
	var minimap = renderer.get_node_or_null("../Minimap")
	if minimap and minimap.has_method("_on_jump_to_alert"):
		return false  # let HUD handle it
	var chud = _get_client_hud()
	if chud and chud.has_method("_on_jump_to_alert"):
		chud._on_jump_to_alert()
	return true

# , 循环闲置农民 / . 循环闲置军事
var _idle_idx: Dictionary = {}
func _cycle_idle(filter_id: int):
	if not _idle_idx.has(filter_id): _idle_idx[filter_id] = -1
	var candidates = []
	for node in renderer.entity_nodes.values():
		if not node.has_meta("snapshot_info"): continue
		var inf = node.get_meta("snapshot_info")
		if inf.get("type") != 2: continue
		if inf.get("health",0) <= 0: continue
		if renderer.my_peer_id != -1 and inf.get("owner_peer_id",-1) != renderer.my_peer_id: continue
		var eid = inf.get("entity_id", -1)
		if filter_id == 10 and eid != 10: continue  # 仅农民
		if filter_id == -1 and (eid == 10 or eid == 14): continue  # 非农民/采集船
		if inf.get("current_order","") in ["idle",""]: candidates.append(inf["id"])
	if candidates.size() == 0: return
	_idle_idx[filter_id] = (_idle_idx[filter_id] + 1) % candidates.size()
	client_selected_ids = [candidates[_idle_idx[filter_id]]]
	_update_selection_visuals()
	emit_signal("selection_changed", client_selected_ids.duplicate())

# F5: 切换统计面板
func _toggle_stats_panel():
	var hud = _get_client_hud()
	if hud and hud.has_method("_on_toggle_stats_pressed"): hud._on_toggle_stats_pressed()

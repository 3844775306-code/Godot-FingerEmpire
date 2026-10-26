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
# 选中实体清理：敌方走出迷雾/死亡时移除只读选中
var _selection_cleanup_timer: float = 0.0

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

			# F5 统计面板
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
					KEY_G: NetworkManager.send_command.rpc_id(1, {"action":"repair","building_id":bid,"shift_held":Input.is_key_pressed(KEY_SHIFT)})
					KEY_S: if sel_info.get("entity_id") != 20: NetworkManager.send_command.rpc_id(1, {"action":"demolish","building_id":bid})
					KEY_D: NetworkManager.send_command.rpc_id(1, {"action":"ungarrison_soldiers","selected_ids":[bid]})
					_: pass
				if key in [KEY_Q,KEY_W,KEY_E,KEY_R,KEY_F,KEY_A,KEY_G,KEY_S,KEY_D]:
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

			# 桥/运载船：已有己方选中单位时发送移动命令（中立桥改为左键查看，右键仍可过桥）
			if _selection_all_local():
				var bypass = false
				if clicked_id != -1:
					var cinfo = _get_entity_info(clicked_id)
					if cinfo:
						if cinfo.get("entity_id") == 9:
							bypass = true
						elif cinfo.get("entity_id") == 7 and not _is_neutral_id(clicked_id):
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

			# 点击己方/队友/敌方/中立实体 → 选中（非己方只可查看，不可指挥）
			if clicked_id != -1:
				var info = _get_entity_info(clicked_id)
				if not info: return

				var is_own := _is_own_id(clicked_id)
				var is_ally := _is_teammate_id(clicked_id)
				var is_enemy := _is_enemy_id(clicked_id) and int(info.get("type", -1)) in [1, 2]
				var is_neutral := _is_neutral_id(clicked_id)
				if not is_own and not is_ally and not is_enemy and not is_neutral:
					_send_left_click(event)  # 非己方/队友/敌方/中立（或迷雾中的敌人）→ 命令
					return

				# 已选中己方部队时，左键点敌方/中立目标优先执行攻击/采集/移动命令，
				# 不再把目标替换成当前选择；只有空手（或只选中建筑/队友）时才允许查看。
				if (is_enemy or is_neutral) and _selection_has_local_army():
					_send_left_click(event)
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

				# 敌方/中立只允许单选查看：替换当前选择，不参与 Shift 混选、
				# 编队和任何命令；右键移动/攻击仍然只作用于己方选中单位。
				if is_enemy or is_neutral:
					client_selected_ids.clear()
					client_selected_ids.append(clicked_id)
				else:
					# 单击：Shift追加，否则替换选择；己方、队友、敌方、中立不混选
					if not client_selected_ids.is_empty() and (_selection_has_enemy() or _selection_has_neutral() or _selection_all_local() != is_own):
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
					# 有选中单位 + 点击空地/敌方/中立 → 攻击/移动命令
					# 队友/敌方/中立单位只可查看：取消选中，不发送任何命令
					if _selection_has_teammate() or _selection_has_enemy() or _selection_has_neutral():
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
	# 敌方/中立只允许单选查看，双击同类不批量选中
	if _is_enemy_info(target_id) or _is_neutral_info(target_id):
		if int(info.get("health", 0)) > 0:
			client_selected_ids.append(target_id)
		emit_signal("selection_changed", client_selected_ids.duplicate())
		_update_selection_visuals()
		return
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
	if client_selected_ids.is_empty():
		return
	# 只有己方单位可被指挥；队友/敌方选中仅用于查看信息
	if not _selection_all_local():
		_notify_readonly()
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

# 敌方单位：不同队伍、非中立，且在当前视野内。只允许选中查看，不允许指挥。
func _is_enemy_info(id: int) -> bool:
	var info = _get_entity_info(id)
	if info.is_empty(): return false
	if renderer == null or renderer.player_team == -1:
		return false
	var team := int(info.get("team", -1))
	if team == RTSConfig.Team.NEUTRAL:
		return false
	return team != renderer.player_team

func _is_enemy_id(id: int) -> bool:
	if not _is_enemy_info(id):
		return false
	var node = renderer.entity_nodes.get(id) if renderer else null
	return is_instance_valid(node) and node.visible

# 中立目标：资源点、动物、废弃建筑/桥等。只允许选中查看，不允许指挥。
func _is_neutral_info(id: int) -> bool:
	var info = _get_entity_info(id)
	if info.is_empty(): return false
	return int(info.get("team", -1)) == RTSConfig.Team.NEUTRAL

func _is_neutral_id(id: int) -> bool:
	if not _is_neutral_info(id):
		return false
	var node = renderer.entity_nodes.get(id) if renderer else null
	return is_instance_valid(node) and node.visible

func _selection_all_local() -> bool:
	if client_selected_ids.is_empty(): return false
	for sid in client_selected_ids:
		if not _is_own_id(sid): return false
	return true

func _selection_has_teammate() -> bool:
	for sid in client_selected_ids:
		if _is_teammate_id(sid): return true
	return false

func _selection_has_enemy() -> bool:
	for sid in client_selected_ids:
		if _is_enemy_info(sid): return true
	return false

func _selection_has_neutral() -> bool:
	for sid in client_selected_ids:
		if _is_neutral_info(sid): return true
	return false

# 当前是否选中了可指挥的己方陆军。用于区分“点敌人/中立=下达命令”和
# “空手点敌人/中立=查看信息”：有己方部队时左键优先当作攻击/采集命令。
func _selection_has_local_army() -> bool:
	for sid in client_selected_ids:
		var info = _get_entity_info(sid)
		if info.is_empty(): continue
		if int(info.get("type", -1)) == 2 and _is_own_id(sid):
			return true
	return false

func _notify_readonly():
	var chud = _get_client_hud()
	if chud and chud.has_method("show_alert_message"):
		var msg := "敌方单位仅可查看，无法指挥"
		if _selection_has_neutral():
			msg = "中立目标仅可查看，无法指挥"
		elif not _selection_has_enemy():
			msg = "队友单位仅可查看，无法指挥"
		chud.show_alert_message(msg, Color(1.0, 0.75, 0.2))

# 敌方/中立是只读选择：死亡、从快照消失或走出迷雾后立即取消选中，
# 避免信息面板停留在旧数据上，也避免后续右键把只读 id 当成可指挥单位。
func _sanitize_client_selection():
	if client_selected_ids.is_empty() or renderer == null:
		return
	var changed := false
	for i in range(client_selected_ids.size() - 1, -1, -1):
		var sid: int = client_selected_ids[i]
		var node = renderer.entity_nodes.get(sid)
		var info := _get_entity_info(sid)
		if info.is_empty() or not is_instance_valid(node) or int(info.get("health", 0)) <= 0:
			client_selected_ids.remove_at(i)
			changed = true
			continue
		if (_is_enemy_info(sid) or _is_neutral_info(sid)) and not (node as Node3D).visible:
			client_selected_ids.remove_at(i)
			changed = true
	if changed:
		_update_selection_visuals()
		emit_signal("selection_changed", client_selected_ids.duplicate())

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
	# 每帧更新选择环位置（跟随目标）；范围圈挂在实体节点下自己跟随，这里只做失效清理
	if selection_rings.size() > 0 or range_rings.size() > 0:
		_process_selection_rings()
	_selection_cleanup_timer -= _delta
	if _selection_cleanup_timer <= 0.0:
		_selection_cleanup_timer = 0.25
		_sanitize_client_selection()
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
# 已经上了边缘描边的实体节点（id -> Node），改选/取消选中时按这份表清掉
var selection_outlined: Dictionary = {}

# 联机范围圈：选中「单个己方单位」时，在脚下贴地画出视野（细线）与作用范围（粗线）。
# 视觉类在 scripts/effects/GroundRangeRing.gd：网格按局部空间建、每 0.12 秒重采样地形，
# 直接 add_child 到实体节点下就会跟着单位走，不需要每帧同步位置。
var range_rings: Dictionary = {}   # 实体 id -> Array[GroundRangeRing]

# 快照里没有「光环半径」字段，只能查 EntityDatabase 配置 + 少量与服务端一致的硬编码
const CLIENT_AURA_RADII := {
	46: 15.0,   # 县吏：进驻仓库后给附近农民加成，Army.gd 里写死 15 米
}
const CLIENT_AURA_TINT := Color(0.62, 1.0, 0.72, 0.32)
# 近战 0.5 米的作用范围画出来是一团噪点，低于这个值不画
const CLIENT_MIN_ACTION_RING := 1.5

func _update_selection_visuals():
	for rid in selection_rings.keys():
		if is_instance_valid(selection_rings[rid]):
			selection_rings[rid].queue_free()
	selection_rings.clear()
	# 边缘描边也要跟着选择一起清：取消选中/改选另一个单位时不能留下上一份残留
	_clear_selection_outlines()
	# 范围圈跟着选择一起清：取消选中/改选另一个单位时不能留下上一圈的残留
	_clear_range_rings()
	for id in client_selected_ids:
		_create_ring_for_entity(id)

# 建筑模型的实际水平半径，选择环贴着模型轮廓走。
# 快照里的 body_radius 按模型「最大边」算，高瘦的塔类建筑水平方向更窄，
# 直接用会让环大出一圈。返回 0 表示不可用，调用方退回 body_radius。
func _model_horizontal_radius(node: Node3D, fallback: float) -> float:
	if node == null or not is_instance_valid(node) or renderer == null:
		return 0.0
	if not node.has_meta("_model_instance"):
		return 0.0
	var model = node.get_meta("_model_instance")
	if model == null or not is_instance_valid(model) or not (model is Node3D):
		return 0.0
	var inst: Node3D = model
	if absf(inst.scale.x) < 0.001 or not renderer.has_method("_get_model_aabb"):
		return 0.0
	var aabb: AABB = renderer._get_model_aabb(inst)
	var horiz: float = maxf(aabb.size.x, aabb.size.z) * absf(inst.scale.x) * 0.5
	return horiz if horiz > 0.05 else 0.0

func _create_ring_for_entity(id):
	var node = renderer.entity_nodes.get(id)
	if not node: return
	if not node.has_meta("snapshot_info"): return
	var info = node.get_meta("snapshot_info")
	if not info: return
	# 选中指示改成「模型边缘发光」：与单机版一致，不再挂脚下的选中环。
	# 己方亮绿、敌方亮红（原来环的颜色语义原样保留）。
	var ring_team: int = int(info.get("team", -1))
	var own_team: int = -1
	if renderer and renderer.get("player_team") != null:
		own_team = int(renderer.player_team)
	var outline_color: Color = Color.GREEN
	if own_team != -1 and ring_team != own_team:
		outline_color = Color.RED
	SelectionOutline.apply(node, true, outline_color)
	selection_outlined[id] = node
	# 贴地的视野/作用范围圈照旧（只在单选且是自己单位时才会真正创建）
	_create_range_rings_for_entity(int(id))

# 清掉所有已经上过的描边（改选/取消选中时调用）
func _clear_selection_outlines() -> void:
	for id in selection_outlined.keys():
		var node = selection_outlined[id]
		if is_instance_valid(node):
			SelectionOutline.apply(node, false)
	selection_outlined.clear()

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
	# 范围圈：节点挂在实体下会自己跟随，这里只清理失效项，并把视野半径的变化跟上去
	for id in range_rings.keys().duplicate():
		var owner_node = renderer.entity_nodes.get(id) if renderer else null
		if not is_instance_valid(owner_node) or not owner_node.has_meta("snapshot_info"):
			_free_range_rings(int(id))
			continue
		var info: Dictionary = owner_node.get_meta("snapshot_info")
		var vision: float = float(info.get("vision_range", 0.0))
		for ring in range_rings[id]:
			if not is_instance_valid(ring):
				continue
			# 单位升级/科技会改视野，快照里数值一变就把细圈半径跟上去（不重建节点）
			if int(ring.get_meta("_ring_kind", -1)) == GroundRangeRing.Kind.VISION and vision > 0.5:
				ring.set_radius(vision)

# ==================== 联机范围圈 ====================
# 只在「单选 + 自己的单位」时画：队友和敌人的范围属于看不到的信息，多选时几十个单位
# 各画两圈会糊满整张地图。数值来源只有快照 info + EntityDatabase 配置。
func _create_range_rings_for_entity(id: int) -> void:
	if client_selected_ids.size() != 1:
		return
	if renderer == null:
		return
	var node = renderer.entity_nodes.get(id)
	if not is_instance_valid(node) or not node.has_meta("snapshot_info"):
		return
	var info: Dictionary = node.get_meta("snapshot_info")
	# 只画自己队伍的单位：联机里 2v2/3v3 队友的单位也不能指挥，范围同样不展示
	var is_own: bool = false
	if renderer.has_method("_is_own_entity"):
		is_own = bool(renderer._is_own_entity(info))
	else:
		is_own = _is_own_id(id)
	if not is_own:
		return
	var specs: Array = _get_range_ring_specs(info)
	if specs.is_empty():
		return
	var height_fn: Callable
	if renderer.has_method("get_ground_height_fn"):
		height_fn = renderer.get_ground_height_fn()
	else:
		height_fn = GroundStripMesh.height_fn_for(renderer)
	# 客户端地形节点可能还没就绪，或脚本热重载后旧 Callable 失效；
	# 用会退回原始 y 的采样器兜底，避免范围圈重建时调用空 Callable 报错。
	if not height_fn.is_valid():
		height_fn = GroundStripMesh.height_fn_for(null)
	var rings: Array = []
	for s in specs:
		var kind: int = int(s.get("kind", 0))
		var radius: float = float(s.get("radius", 0.0))
		var tint: Color = s.get("tint", Color(0, 0, 0, 0))
		var ring: GroundRangeRing = GroundRangeRing.create(kind, radius, height_fn, tint)
		# 顶点 y 由 GroundRangeRing 自己换算成「相对节点」的局部高度，
		# 直接挂在站在地面上的实体节点下即可，不需要再抵掉实体高度。
		ring.set_meta("_ring_kind", kind)
		node.add_child(ring)
		rings.append(ring)
	if not rings.is_empty():
		range_rings[id] = rings

# 按快照 + 配置算出这一圈要画什么：
#   视野 = 快照 info["vision_range"]（服务端已算过国家加成），缺失时查配置
#   射程 = 配置 attack_range，近战 < 1.5 米不画
#   光环 = 配置 aura_radius（统帅 12 米）/ 服务端写死的半径（县吏 15 米，仅在进驻时有效）
func _get_range_ring_specs(info: Dictionary) -> Array:
	var specs: Array = []
	var entity_id: int = int(info.get("entity_id", -1))
	var cfg: Dictionary = {}
	if entity_id >= 0 and EntityDatabase != null:
		cfg = EntityDatabase.get_config(entity_id)
	var vision: float = float(info.get("vision_range", 0.0))
	if vision <= 0.0:
		vision = float(cfg.get("vision_range", 0.0))
	if vision > 0.5:
		specs.append({"kind": GroundRangeRing.Kind.VISION, "radius": vision})
	var attack_range: float = float(cfg.get("attack_range", 0.0))
	if attack_range >= CLIENT_MIN_ACTION_RING:
		specs.append({"kind": GroundRangeRing.Kind.ACTION, "radius": attack_range})
	var aura: float = float(cfg.get("aura_radius", 0.0))
	if aura <= 0.0:
		aura = float(CLIENT_AURA_RADII.get(entity_id, 0.0))
		# 县吏的光环只在进驻仓库里时生效，没进驻就不画
		if entity_id == 46 and not bool(info.get("is_garrisoned", false)):
			aura = 0.0
	if aura > 0.5:
		specs.append({"kind": GroundRangeRing.Kind.ACTION, "radius": aura, "tint": CLIENT_AURA_TINT})
	return specs

func _free_range_rings(id: int) -> void:
	if not range_rings.has(id):
		return
	for ring in range_rings[id]:
		if is_instance_valid(ring):
			ring.queue_free()
	range_rings.erase(id)

func _clear_range_rings() -> void:
	for id in range_rings.keys().duplicate():
		_free_range_rings(int(id))

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

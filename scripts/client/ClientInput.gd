# scripts/ui/ClientInput.gd
class_name client_input
# scripts/client/ClientInput.gd
extends Node

# 信号
signal selection_changed(selected_ids: Array)
signal build_requested(world_pos: Vector3)

# 当前选中实体
var client_selected_ids: Array = []

	# Local control groups (mirrored with server)
var local_groups: Dictionary = {}  # int -> Array[int]
var _last_group_key: int = -1
var _last_group_time: float = 0.0
const DOUBLE_TAP_THRESHOLD = 0.3
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

func select_all_military():
	if not renderer: return
	client_selected_ids.clear()
	for node in renderer.entity_nodes.values():
		if not node.has_meta("snapshot_info"): continue
		var info = node.get_meta("snapshot_info")
		if not info: continue
		if info["type"] == 2 and info["entity_id"] not in [10, 14] and info["health"] > 0:
			# Check ownership
			if renderer.my_peer_id != -1 and info.get("owner_peer_id", -1) != renderer.my_peer_id:
				continue
			if renderer.my_peer_id == -1 and info["team"] != renderer.player_team:
				continue
			client_selected_ids.append(info["id"])
	_update_selection_visuals()
	emit_signal("selection_changed", client_selected_ids.duplicate())


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

# 集结模式
var rally_mode: bool = false

# 用于建造预览的世界坐标
var last_world_pos: Vector3 = Vector3.ZERO

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

func _unhandled_input(event):
	if not renderer: return

	# 建造放置模式优先  ← 这行保留
	if renderer.placement_mode:
		# 鼠标移动（PC）
		if event is InputEventMouseMotion:
			_update_placement_preview(event.position)
		# 鼠标点击（PC）
		elif event is InputEventMouseButton:
			if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
				_confirm_placement()
			elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
				_cancel_placement()
		# 触摸按下（移动端）
		elif event is InputEventScreenTouch:
			if event.pressed:
				# 手指按下：立即更新预览位置，但不放置
				_update_placement_preview(event.position)
			else:
				# 手指抬起：放置建筑
				_confirm_placement()
		# 触摸拖动（移动端）
		elif event is InputEventScreenDrag:
			_update_placement_preview(event.position)
		return  # 建造模式下不再处理其他输入

	# 普通交互
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				# Ctrl+左键 → 设置驻扎点（仅对已选中的军队/建筑）
				if Input.is_key_pressed(KEY_CTRL) and not client_selected_ids.is_empty():
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
				_try_select(event)
			else:
				_on_left_release(event)
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			# Ctrl+右键空地 → 取消驻扎点
			if Input.is_key_pressed(KEY_CTRL) and not client_selected_ids.is_empty():
				var _hit_id = _get_entity_id_under_mouse(event.position)
				if _hit_id == -1:
					NetworkManager.send_command.rpc_id(1, {"action": "clear_garrison", "selected_ids": client_selected_ids.duplicate()})
					return
			if client_selected_ids.is_empty():
				var ground_pos = _get_ground_position(event.position)
				if ground_pos != Vector3.ZERO:
					emit_signal("build_requested", ground_pos)
			else:
				var hit_id = _get_entity_id_under_mouse(event.position)
				if hit_id == -1:
					client_selected_ids.clear()
					_update_selection_visuals()
					emit_signal("selection_changed", [])
				else:
					_send_left_click(event)

	elif event is InputEventMouseMotion and is_box_selecting:
		box_end = event.position
		var r = Rect2(box_start, box_end - box_start).abs()
		box_rect.position = r.position
		box_rect.size = r.size
		box_rect.visible = true

# ---------- 选择 ----------
func _try_select(event):
	var pos = event.position
	var clicked_id = _get_entity_id_under_mouse(pos)
	if clicked_id != -1:
		var info = _get_entity_info(clicked_id)
		if not info: return

		# 2v2 权限：只能选自己的单位
		if renderer.my_peer_id != -1:
			var owner = info.get("owner_peer_id", -1)
			if owner != renderer.my_peer_id :
				_send_left_click(event)
				return
		else:
			var owner = info.get("team", -1)
			
			renderer = get_tree().get_first_node_in_group("client_renderer")
			
			if owner != renderer.player_team :
				_send_left_click(event)
				return
		# 双击全选同类
		var now = Time.get_ticks_msec() / 1000.0
		if last_clicked_id == clicked_id and (now - last_click_time) < DOUBLE_CLICK_THRESHOLD:
			_select_all_of_same_type(clicked_id, info)
			last_clicked_id = -1
			last_click_time = 0.0
			return
		last_clicked_id = clicked_id
		last_click_time = now

		# 单击
		if clicked_id in client_selected_ids:
			client_selected_ids.clear()
		else:
			client_selected_ids.append(clicked_id)

		emit_signal("selection_changed", client_selected_ids.duplicate())
		_update_selection_visuals()
	else:
		if not client_selected_ids:
			# 点击空地 → 开始框选
			client_selected_ids.clear()
			emit_signal("selection_changed", [])
			_update_selection_visuals()
			is_box_selecting = true
			box_start = pos
			box_end = pos
		else:
			_send_left_click(event)

func _on_left_release(event):
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
			if info["health"] <= 0: continue
			var screen_pos = cam.unproject_position(node.global_position)
			if rect.has_point(screen_pos):
				if info["id"] not in client_selected_ids:
					client_selected_ids.append(info["id"])
		emit_signal("selection_changed", client_selected_ids.duplicate())
		_update_selection_visuals()

func _select_all_of_same_type(target_id: int, info: Dictionary):
	client_selected_ids.clear()
	var target_entity_id = info.get("entity_id", -1)
	if target_entity_id == -1: return
	for node in renderer.entity_nodes.values():
		if not node.has_meta("snapshot_info"): continue
		var ent_info = node.get_meta("snapshot_info")
		if not ent_info: continue
		if renderer.my_peer_id != -1 and ent_info.get("owner_peer_id", -1) != renderer.my_peer_id:
			continue
		if ent_info.get("entity_id") == target_entity_id and ent_info["health"] > 0:
			client_selected_ids.append(ent_info["id"])
	emit_signal("selection_changed", client_selected_ids.duplicate())
	_update_selection_visuals()

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
	if not node.has_meta("snapshot_info"): continue
			var info = node.get_meta("snapshot_info")
	if not info: return
	var radius = info.get("body_radius", 0.5)
	var ring = MeshInstance3D.new()
	ring.mesh = TorusMesh.new()
	ring.mesh.inner_radius = radius + 0.15
	ring.mesh.outer_radius = radius + 0.35
	ring.position = Vector3(0, radius * 2.5 + 0.1, 0)
	ring.material_override = StandardMaterial3D.new()
	# 己方绿色，敌方红色
	var ring_team = info.get("team", -1)
	if ring_team == RTSConfig.Team.BLUE:
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
		# 环跟随实体位置（自动跟随因为是子节点，此处检查有效性）
		if not node.has_meta("snapshot_info"):
			ring.queue_free()
			to_remove.append(id)
	for id in to_remove:
		selection_rings.erase(id)

# ---------- 右键命令 ----------
func _send_left_click(event):
	if not renderer: return
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

	if result_entity and result_entity.collider.has_meta("entity_root"):
		var root = result_entity.collider.get_meta("entity_root")
		var info = root.get_meta("snapshot_info", null)
		if info:
			target_id = info["id"]
			pos = root.global_position
	else:
		pos = _get_ground_position(event.position)
		if pos == Vector3.ZERO: return

	var cmd = {
		"action": "right_click",
		"selected_ids": client_selected_ids.duplicate(),
		"target_id": target_id,
		"pos_x": pos.x, "pos_y": pos.y, "pos_z": pos.z,
		"shift_held": Input.is_key_pressed(KEY_SHIFT)
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

func get_last_world_pos() -> Vector3:
	return last_world_pos

func _get_client_hud():
	return get_tree().get_first_node_in_group("client_hud")

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

# ---------- 建造放置 ----------
func _update_placement_preview(screen_pos: Vector2):
	var cam = get_viewport().get_camera_3d()
	if not cam or not renderer.placement_preview: return
	var from = cam.project_ray_origin(screen_pos)
	var to = from + cam.project_ray_normal(screen_pos) * 2000
	var space_state = get_viewport().get_world_3d().direct_space_state

	# 先尝试射线检测地面碰撞体（层2）
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
		# 后备方案：使用平面求交（Y=0 平面）
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
		pos.y = renderer.get_terrain_height(pos)   # 贴合地形高度
		last_world_pos = pos

		# 合法性检查
		var in_vision = renderer.is_in_player_vision(pos)
		var terrain_ok = renderer.get_terrain_at(pos) != 2   # 不在水中
		if renderer.placement_building_id == 23:  # 船坞特殊
			terrain_ok = renderer.get_terrain_at(pos) == 0 and _check_adjacent_water(pos)

		renderer.placement_preview.global_position = pos
		renderer.placement_preview.visible = true
		var mat = renderer.placement_preview.material_override as StandardMaterial3D
		if mat: mat.albedo_color = Color.GREEN if (in_vision and terrain_ok) else Color.RED
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
	if not valid: return
	var cmd = {
		"action": "build",
		"building_id": renderer.placement_building_id,
		"pos_x": pos.x, "pos_y": pos.y, "pos_z": pos.z
	}
	NetworkManager.send_command.rpc_id(1, cmd)
	if not Input.is_key_pressed(KEY_SHIFT):
			_cancel_placement()

func _cancel_placement():
	renderer.placement_mode = false
	renderer.placement_building_id = -1
	if renderer.placement_preview:
		renderer.placement_preview.visible = false

func _check_adjacent_water(world_pos: Vector3) -> bool:
	var gx = int(world_pos.x + RTSConfig.MAP_SIZE / 2)
	var gz = int(world_pos.z + RTSConfig.MAP_SIZE / 2)
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			if dx == 0 and dy == 0: continue
			if renderer.get_terrain_at_grid(gx+dx, gz+dy) == 2:
				return true
	return false

# ---------- 键盘快捷键 ----------
func _input(event):
	if not event is InputEventKey or not event.pressed:
		return

	if event.keycode == KEY_DELETE:
		for eid in client_selected_ids.duplicate():
			var info = _get_entity_info(eid)
			if info.get("type") == 1 and info.get("entity_id") != 20:
				NetworkManager.send_command.rpc_id(1, {"action": "demolish", "building_id": eid})
				client_selected_ids.erase(eid)
		_update_selection_visuals()
		emit_signal("selection_changed", client_selected_ids.duplicate())
		get_viewport().set_input_as_handled()
		return

	# U键升级选中建筑
	if event.keycode == KEY_U:
		for eid in client_selected_ids.duplicate():
			var info = _get_entity_info(eid)
			if info.get("type") == 1:
				NetworkManager.send_command.rpc_id(1, {"action": "upgrade", "building_id": eid})
		get_viewport().set_input_as_handled()
		return

		# 单选建筑 + 数字 → 快速生产（无Ctrl/Shift）
	if event.keycode >= KEY_1 and event.keycode <= KEY_9 and not event.ctrl_pressed and not event.shift_pressed:
		if client_selected_ids.size() == 1:
			var info = _get_entity_info(client_selected_ids[0])
			if info.get("type") == 1:  # Building
				var b_cfg = EntityDatabase.get_config(info["entity_id"])
				if b_cfg and b_cfg.has("produces"):
					var produces = b_cfg["produces"]
					var num = event.keycode - KEY_0
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

	# 编队系统: Ctrl+数字 = 设置, 数字 = 召回
	if event.keycode >= KEY_0 and event.keycode <= KEY_9:
		var g = event.keycode - KEY_0
		var ctrl = event.ctrl_pressed
		if ctrl and g == 0:
			for sid in client_selected_ids:
				for key in local_groups.keys():
					local_groups[key].erase(sid)
			NetworkManager.send_command.rpc_id(1, {"action": "set_group", "group": 0, "selected_ids": client_selected_ids.duplicate()})
		elif ctrl:
			local_groups[g] = client_selected_ids.duplicate()
			print("[Client] Set group ", g, " with ", client_selected_ids.size(), " units")
			NetworkManager.send_command.rpc_id(1, {"action": "set_group", "group": g, "selected_ids": client_selected_ids.duplicate()})
			var chud = _get_client_hud()
			if chud and chud.has_method("show_alert_message"):
				chud.show_alert_message("编队 %d 已设置 (%d 单位)" % [g, client_selected_ids.size()], Color(0.3, 0.7, 1.0))
		else:
			var now = Time.get_ticks_msec() / 1000.0
			if local_groups.has(g):
				# 双击检测：切图到编队中心
				if _last_group_key == g and (now - _last_group_time) < DOUBLE_TAP_THRESHOLD:
					_jump_camera_to_group(g)
					_last_group_key = -1
					_last_group_time = 0.0
				else:
					client_selected_ids = local_groups[g].duplicate()
					emit_signal("selection_changed", client_selected_ids.duplicate())
					_update_selection_visuals()
					print("[Client] Recalled group ", g, " with ", client_selected_ids.size(), " units")
					var chud2 = _get_client_hud()
					if chud2 and chud2.has_method("show_alert_message"):
						chud2.show_alert_message("编队 %d (%d 单位)" % [g, client_selected_ids.size()], Color(0.3, 0.7, 1.0))
					_last_group_key = g
					_last_group_time = now
			NetworkManager.send_command.rpc_id(1, {"action": "recall_group", "group": g})
		get_viewport().set_input_as_handled()
		return

# ---------- 集结模式 ----------
func enable_rally_mode(): rally_mode = true
func disable_rally_mode(): rally_mode = false

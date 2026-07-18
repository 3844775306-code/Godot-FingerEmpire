class_name ClientRenderer
extends Node3D
var last_applied_seq = -1
# ==================== 玩家信息 ====================
var player_team: int = -1          # 1v1 模式队伍 (BLUE=0, RED=1)
var my_peer_id: int = -1           # 2v2 模式标识（当前未用）
var my_color: Color = Color.WHITE

# ==================== 实体节点池 ====================
var entity_nodes: Dictionary = {}   # instance_id -> Node3D

# ==================== 战争迷雾 ====================
var local_explored_grid: Array = []
var local_visible_grid: Array = []

# ==================== 血条池 ====================
var unit_bars: Dictionary = {}

# ==================== 缓存数据 ====================
var last_resources: Dictionary = {}
var last_limits: Dictionary = {}
var last_population: Dictionary = {"current": 0, "max": 0}

# ==================== 建造预览 ====================
var placement_mode: bool = false
var placement_building_id: int = -1
var placement_preview: MeshInstance3D

# ==================== 定时器 ====================
var health_bar_timer: float = 0.0
const HEALTH_BAR_INTERVAL: float = 0.05  # 20Hz，血条丝滑跟随

# 客户端诊断
var _diag_snap_age: float = 999.0
var _diag_snap_count: int = 0
var _diag_last_snap_time: int = 0
var fog_timer: float = 0.0
var minimap_timer: float = 0.0
var _stale_cleanup_timer: float = 30.0
var _snapshot_cooldown: int = 0
var heavy_work_index: int = 0            # 轮转索引，每帧只做一个重任务
var first_fog_done: bool = false          # 首帧标志，确保初始化立即执行所有任务
var fog_cycle_active: bool = false        # 增量迷雾计算进行中
var fog_units_queue: Array = []           # 待处理的单位队列
var fog_batch_size: int = 5               # 每帧处理的单位数量

var last_snapshot_time = 0
	
@onready var entities_container: Node3D = $Entities
# 新增变量（放在类顶部）

var my_team: int = -1

var stale_snapshot: bool = false

var latest_snapshot: Dictionary = {}    # 必须初始化为空字典
var snapshot_processing: bool = false
var pending_delta: Array = []

	# 如果有最新快照待处理，且当前不忙，则开始处理
	
var player_colors: Dictionary = {}   # peer_id -> Color
func set_all_player_colors(colors: Dictionary):
	player_colors.clear()
	for k in colors: player_colors[k] = colors[k]  # 原地更新，保持引用
	print("[ClientRenderer] 收到全局颜色映射，包含 %d 个玩家" % player_colors.size())
# 新增方法
func set_player_info(peer_id: int, team: int, slot: int, color: Color):
	my_peer_id = peer_id
	my_team = team
	player_team = team          # 兼容1v1代码
	my_color = color
	
	print("[ClientRenderer] 2v2玩家信息：peer_id=%d, team=%d, color=%s" % [peer_id, team, color])
# ==================== 初始化 ====================
func _ready():
	add_to_group("client_renderer")
	_init_fog_grids()

	# 建造预览体
	placement_preview = MeshInstance3D.new()
	var box = BoxMesh.new()
	box.size = Vector3(2, 1.5, 2)
	placement_preview.mesh = box
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(0, 1, 0, 0.5)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.render_priority = 10          # 提高渲染优先级
	mat.no_depth_test = true          # 禁用深度测试，确保不被遮挡
	placement_preview.material_override = mat
	placement_preview.visible = false
	placement_preview.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	placement_preview.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(placement_preview)

	# 将预览体移到所有子节点的最上层（在场景树中）
	move_child(placement_preview, get_child_count() - 1)

	# 选择信号 → InfoPanel
	if $ClientInput:
		$ClientInput.selection_changed.connect(func(ids: Array):
			var panel = $UI/InfoPanel as ClientInfoPanel
			if panel:
				if ids.size() == 1:
					panel.update_info(ids[0])
				
				elif ids.size() > 1:
					panel.show_multi_selection(ids)
				else:
					panel.visible = false
			)

		# 建造请求信号
		$ClientInput.build_requested.connect(func(wpos: Vector3):
			var menu = $UI/BuildMenu as ClientBuildMenu
			if menu:
				var cam = get_viewport().get_camera_3d()
				if cam:
					menu.popup_at(wpos, cam.unproject_position(wpos))
		)

	# 建造菜单发射“放置开始”信号
	if $UI/BuildMenu:
		$UI/BuildMenu.build_placement_started.connect(func(bid: int):
			placement_mode = true
			placement_building_id = bid
			var cfg = EntityDatabase.get_config(bid)
			if not cfg.is_empty():
				var r = cfg.get("body_radius", 1.0)
				var b = placement_preview.mesh as BoxMesh
				if b: b.size = Vector3(r*2, r*1.5, r*2)
			placement_preview.visible = true
		)

# ==================== 外部接口 ====================
func set_player_team(team: int):
	player_team = team
	print("客户端队伍设置为：", team)

func set_castle_pos(pos: Vector3):
	await get_tree().process_frame
	var cam = get_viewport().get_camera_3d()
	if cam:
		cam.global_position = Vector3(pos.x, cam.global_position.y, pos.z)

func get_population() -> Dictionary:
	return last_population

func get_player_resource(res_name: String) -> int:
	return last_resources.get(res_name, 0)

func get_player_castle_level() -> int:
	var max_lv = 1
	for n in entity_nodes.values():
		if not is_instance_valid(n) or not n.has_meta("snapshot_info"):
			continue
		var info = n.get_meta("snapshot_info")
		if info.get("type") == 1 and info.get("entity_id") == 20 and info.get("team") == player_team:
			var lv = info.get("upgrade_level", 1)
			if lv > max_lv:
				max_lv = lv
	return max_lv

func get_entity_info(id: int) -> Dictionary:
	var node = entity_nodes.get(id)
	if node and node.has_meta("snapshot_info"):
		return node.get_meta("snapshot_info")
	return {}

func get_entity_config(entity_id: int) -> Dictionary:
	return EntityDatabase.get_config(entity_id)

func apply_snapshot(data: Dictionary):
	var now = Time.get_ticks_msec()
	var seq = data.get("seq", -1)
	if seq <= last_applied_seq:
		return   # 丢弃过时快照
	if last_applied_seq != -1 and data.get("seq") == last_applied_seq + 1:
		pass #print("连续收到")
	else:
		pass #print("跳号或重传: 期望 ", last_applied_seq+1, " 收到 ", data.get("seq"))
	last_applied_seq = seq
	_diag_snap_count += 1
	_diag_last_snap_time = now
	_diag_snap_age = 0.0
	last_snapshot_time = now
	if player_team == -1:
		return
	# 丢弃未处理的旧快照，只保留最新
	if snapshot_processing:
		pending_delta.clear()
	latest_snapshot = data
	snapshot_processing = true

# 安全快照处理包装器——崩溃循环由 _process 层面的计数器处理
var _snapshot_fail_count: int = 0
func _safe_process_snapshot(data: Dictionary) -> bool:
	if data.is_empty():
		return false
	if not data.has('delta') and not data.has('entities'):
		return false
	_process_snapshot(data)
	return true

func _process_snapshot(data: Dictionary):
	# 缓存人口
	last_population = data.get("population", last_population)
	
	# ---- 实体更新 ----
	if data.has("delta"):
		for ent in data["delta"]:
			_update_single_entity(ent)
	elif data.has("entities"):
		for ent in data["entities"]:
			_update_single_entity(ent)

	# 删除死亡实体
	if data.has("dead_ids"):
		for id in data["dead_ids"]:
			if entity_nodes.has(id):
				entity_nodes[id].queue_free()
				entity_nodes.erase(id)
			_remove_all_bars(id)

			if has_meta("_wp_markers"):
				var all_wp = get_meta("_wp_markers")
				if all_wp.has(id):
					for m in all_wp[id]:
						if is_instance_valid(m): m.queue_free()
					all_wp.erase(id)
	var my_res = {}
	var my_limits = {}
	var my_pop = last_population

	if data.has("player_resources") and my_peer_id != -1:
		my_res = data["player_resources"].get(my_peer_id, {})
		my_pop = data.get("player_population", {}).get(my_peer_id, {"current":0,"max":0})
		my_limits = data.get("player_limits", {}).get(my_peer_id, {})
	elif data.has("resources"):
		my_res = data["resources"]["player"] if player_team == RTSConfig.Team.BLUE else data["resources"]["enemy"]
		my_pop = data["population"]
		my_limits = data.get("limits", {}).get("player" if player_team == RTSConfig.Team.BLUE else "enemy", {})

	# 保存最新资源
	last_resources = my_res
	last_limits = my_limits
	last_population = my_pop

	# ---- HUD 更新 ----
	var gather_counts = data.get("gather_counts", {})
	var income_rate = data.get("income_rate", {})
	# Unwrap peer_id-keyed data for 2v2 mode
	if my_peer_id != -1:
		gather_counts = gather_counts.get(my_peer_id, {})
		income_rate = income_rate.get(my_peer_id, {})
	if has_node("UI/HUD") and not my_res.is_empty():
		$UI/HUD.update_data(my_res, my_pop, my_limits, gather_counts, income_rate, data.get("game_time", 0.0))

	# ---- InfoPanel 资源 ----
	if has_node("UI/InfoPanel"):
		$UI/InfoPanel.set_resources(my_res, my_limits, my_pop)

	# ---- 国家信息 ----
	if has_node("UI/HUD"):
		if data.has("nation"):
			var my_nation = data["nation"] if player_team == RTSConfig.Team.BLUE else data.get("enemy_nation", -1)
			var enemy_nation = data.get("enemy_nation", -1) if player_team == RTSConfig.Team.BLUE else data["nation"]
			$UI/HUD.set_nations(my_nation, enemy_nation)
		elif data.has("team_nations") and my_team != -1:
			var my_team_nation = data["team_nations"].get(my_team, -1)
			var enemy_team = RTSConfig.Team.RED if my_team == RTSConfig.Team.BLUE else RTSConfig.Team.BLUE
			var enemy_nation = data["team_nations"].get(enemy_team, -1)
			$UI/HUD.set_nations(my_team_nation, enemy_nation)

	# ---- 子弹 ----
	# ---- 服务器警报 ----
	if data.has("alerts"):
		var alerts = data["alerts"]
		if alerts is Array and alerts.size() > 0:
			var hud = get_node_or_null("UI/HUD")
			for alert in alerts:
				if hud and hud.has_method("show_alert_message"):
					hud.show_alert_message(alert["msg"], alert.get("color", Color(1.0, 0.2, 0.1)))

	if data.has("bullets"):
		var server_ids = {}
		for b in data["bullets"]:
			if not b.has("id") or not b.has("x"): continue
			var id = b["id"]
			server_ids[id] = true
			var node = entity_nodes.get(id)
			if not node:
				node = _create_bullet_node(b)
				entity_nodes[id] = node
			node.global_position = Vector3(b["x"], b["y"], b["z"])
			node.visible = true

		for id in entity_nodes.keys():
			var n = entity_nodes[id]
			if n.has_meta("is_bullet") and not server_ids.has(id):
				n.queue_free()
				entity_nodes.erase(id)
# ==================== 实体创建与更新 ====================
func _update_single_entity(info: Dictionary):
	if not info.has("id") or not info.has("x") or not info.has("z"):
		return
	var id = info["id"]
	var node = entity_nodes.get(id)
	if not node:
		node = _create_entity_node(info)
		entity_nodes[id] = node
	node.global_position = Vector3(info["x"], info["y"], info["z"])
	node.visible = _should_entity_be_visible(info)
	node.set_meta("snapshot_info", info)
	# Update waypoint markers if present
	_update_waypoint_markers(node, info)

# 在 ClientRenderer.gd 类顶部确保存在以下变量
  # peer_id -> Color

# ---------- 替换原有的 _create_entity_node ----------
func _create_entity_node(info: Dictionary) -> Node3D:
	if not info.has("body_radius") or not info.has("type") or not info.has("team"):
		return Node3D.new()
	var entity = Node3D.new()
	var body = StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	body.name = "ClickableBody"
	body.set_meta("entity_root", entity)
	entity.add_child(body)

	var col_shape = CollisionShape3D.new()
	var r = info["body_radius"]
	if info["type"] == 1:
		var box = BoxShape3D.new()
		box.size = Vector3(r*2, r*1.5, r*2)
		col_shape.shape = box
	else:
		var sphere = SphereShape3D.new()
		sphere.radius = r
		col_shape.shape = sphere
	body.add_child(col_shape)

	# 获取实体颜色：统一使用 player_colors 按 owner_peer_id 着色
	var entity_color: Color
	var owner_id = info.get("owner_peer_id", -1)

	if owner_id != -1 and player_colors.has(owner_id):
		entity_color = player_colors[owner_id]
	elif info["team"] == RTSConfig.Team.BLUE:
		entity_color = Color(0.3, 0.5, 1.0)   # 蓝队基础色
	elif info["team"] == RTSConfig.Team.RED:
		entity_color = Color(1.0, 0.25, 0.2)   # 红队基础色
	else:
		entity_color = Color(0.7, 0.7, 0.7)    # 中立灰色

	# 模型
	var mesh: MeshInstance3D
	match info["type"]:
		0: # 资源
			mesh = MeshInstance3D.new()
			mesh.mesh = SphereMesh.new()
			mesh.mesh.radius = r
			var mat = StandardMaterial3D.new()
			match info["entity_id"]:
				0: mat.albedo_color = Color.YELLOW
				1: mat.albedo_color = Color(0.3,0.8,0.2)
				2: mat.albedo_color = Color.GRAY
				3: mat.albedo_color = Color.SADDLE_BROWN
				4: mat.albedo_color = Color.BLACK
			mesh.material_override = mat
		1: # 建筑
			mesh = MeshInstance3D.new()
			var box = BoxMesh.new()
			box.size = Vector3(r*2, r*1.5, r*2)
			mesh.mesh = box
			var mat = StandardMaterial3D.new()
			mat.albedo_color = entity_color
			mesh.material_override = mat
		2: # 军队
			mesh = MeshInstance3D.new()
			var cap = CapsuleMesh.new()
			cap.radius = r*0.8
			cap.height = r*2.5
			mesh.mesh = cap
			var mat = StandardMaterial3D.new()
			mat.albedo_color = entity_color
			mesh.material_override = mat
	if mesh:
		entity.add_child(mesh)

	# 存储 owner_peer_id 元数据，供后续使用
	entity.set_meta("owner_peer_id", owner_id)
	entities_container.add_child(entity)
	return entity

# ---------- 替换原有的 _create_bullet_node ----------
func _create_bullet_node(info: Dictionary) -> Node3D:
	var n = Node3D.new()
	n.set_meta("is_bullet", true)
	var mesh = MeshInstance3D.new()
	var s = SphereMesh.new()
	s.radius = 0.2; s.height = 0.4
	mesh.mesh = s
	var mat = StandardMaterial3D.new()

	# 子弹颜色也按玩家区分
	var owner_id = info.get("owner_peer_id", -1)
	if owner_id != -1 and player_colors.has(owner_id):
		mat.albedo_color = player_colors[owner_id]
	else:
		mat.albedo_color = Color.RED if info["team"] == RTSConfig.Team.BLUE else Color.BLUE

	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh.material_override = mat
	n.add_child(mesh)
	entities_container.add_child(n)
	return n
func on_map_size_changed():
	_init_fog_grids()

func _init_fog_grids():
	local_explored_grid.clear()
	local_visible_grid.clear()
	for x in range(RTSConfig.MAP_SIZE):
		var exp_col = []
		var vis_col = []
		for y in range(RTSConfig.MAP_SIZE):
			exp_col.append(false)
			vis_col.append(false)
		local_explored_grid.append(exp_col)
		local_visible_grid.append(vis_col)


	

	# 后续迷雾计算...
# ==================== 战争迷雾 ====================


func _start_fog_cycle():
	# 尺寸检查
	if local_explored_grid.size() != RTSConfig.MAP_SIZE or local_visible_grid.size() != RTSConfig.MAP_SIZE:
		_init_fog_grids()
	if local_explored_grid.size() > 0 and local_explored_grid[0].size() != RTSConfig.MAP_SIZE:
		_init_fog_grids()

	# 收集己方单位
	fog_units_queue.clear()
	for node in entity_nodes.values():
		if not node.has_meta("snapshot_info"): continue
		var info = node.get_meta("snapshot_info")
		if not info or info.get("health", 0) <= 0: continue
		var belongs = false
		if my_team != -1:
			belongs = (info["team"] == my_team)
		elif player_team != -1:
			belongs = (info["team"] == player_team)
		if belongs:
			fog_units_queue.append(node)

	# 清除本帧可见性（一次性操作）
	var false_row = []
	false_row.resize(RTSConfig.MAP_SIZE)
	false_row.fill(false)
	for x in range(RTSConfig.MAP_SIZE):
		local_visible_grid[x] = false_row.duplicate()

	if fog_units_queue.is_empty():
		# 没有己方单位，直接完成
		var map = get_node_or_null("Map")
		if map and map.has_method("apply_fog") and not map.base_colors.is_empty():
			map.apply_fog(local_explored_grid, local_visible_grid)
	else:
		fog_cycle_active = true

func _process_fog_batch() -> bool:
	# 返回 true 表示本轮迷雾计算全部完成
	if not fog_cycle_active:
		return false

	var processed = 0
	while fog_units_queue.size() > 0 and processed < fog_batch_size:
		var node = fog_units_queue.pop_front()
		if not is_instance_valid(node):
			continue
		var info = node.get_meta("snapshot_info")
		if not info:
			continue
		var gx = int(info["x"] + RTSConfig.MAP_SIZE / 2)
		var gz = int(info["z"] + RTSConfig.MAP_SIZE / 2)
		var vision = info.get("vision_range", 12)
		for dx in range(-vision, vision + 1):
			for dz in range(-vision, vision + 1):
				if dx*dx + dz*dz > vision*vision: continue
				var nx = gx + dx
				var nz = gz + dz
				if nx >= 0 and nx < RTSConfig.MAP_SIZE and nz >= 0 and nz < RTSConfig.MAP_SIZE:
					local_visible_grid[nx][nz] = true
					local_explored_grid[nx][nz] = true
		processed += 1

	if fog_units_queue.size() == 0:
		# 全部完成，应用到地面纹理
		fog_cycle_active = false
		var map = get_node_or_null("Map")
		if map and map.has_method("apply_fog") and not map.base_colors.is_empty():
			map.apply_fog(local_explored_grid, local_visible_grid)
		return true
	return false

func _update_local_fog():
	# 兼容旧接口：启动增量迷雾周期
	_start_fog_cycle()
func _update_waypoint_markers(node: Node3D, info: Dictionary):
	# Only show waypoints for selected entities
	var inp = get_node_or_null("ClientInput")
	var is_selected = false
	if inp and inp.has_method("get_client_selected_ids"):
		is_selected = info["id"] in inp.get_client_selected_ids()
	if not is_selected:
		# Clear any existing markers for this entity
		if has_meta("_wp_markers"):
			var awp = get_meta("_wp_markers")
			if awp.has(info["id"]):
				for m in awp[info["id"]]:
					if is_instance_valid(m): m.queue_free()
				awp.erase(info["id"])
		return

	# Track all waypoint markers globally (keyed by entity instance id)
	if not has_meta("_wp_markers"):
		set_meta("_wp_markers", {})
	var all_wp = get_meta("_wp_markers")
	var eid = info["id"]

	# Clear previous markers for this entity
	if all_wp.has(eid):
		for m in all_wp[eid]:
			if is_instance_valid(m): m.queue_free()
		all_wp.erase(eid)

	var wps = info.get("waypoints", [])
	if wps.is_empty(): return

	var new_markers: Array = []
	for i in range(wps.size()):
		var wp = wps[i]
		var world_pos = Vector3(wp["x"], wp.get("y", 0), wp["z"])
		var is_loop = wp.get("is_loop", false)

		# Orange for loop waypoints, cyan for normal
		var ring_color = Color(1.0, 0.55, 0.0, 0.9) if is_loop else Color(0, 1, 1, 0.8)
		var pole_color = Color(1.0, 0.55, 0.0, 0.5) if is_loop else Color(0, 1, 1, 0.5)

		# Vertical pole — world space, child of entities_container
		var pole = MeshInstance3D.new()
		var cyl = CylinderMesh.new()
		cyl.top_radius = 0.08; cyl.bottom_radius = 0.08; cyl.height = 2.0
		pole.mesh = cyl
		pole.position = world_pos + Vector3(0, 1.0, 0)
		var pole_mat = StandardMaterial3D.new()
		pole_mat.albedo_color = pole_color
		pole_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		pole_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		pole_mat.render_priority = 10
		pole_mat.no_depth_test = true
		pole.material_override = pole_mat
		entities_container.add_child(pole)
		new_markers.append(pole)

		# Ring marker — world space, child of entities_container
		var marker = MeshInstance3D.new()
		var ring = TorusMesh.new()
		ring.inner_radius = 0.5; ring.outer_radius = 0.7
		marker.mesh = ring
		marker.position = world_pos + Vector3(0, 2.0, 0)
		var mat = StandardMaterial3D.new()
		mat.albedo_color = ring_color
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.render_priority = 10
		mat.no_depth_test = true
		marker.material_override = mat
		entities_container.add_child(marker)
		new_markers.append(marker)

		# Ground dot at exact click position
		var dot = MeshInstance3D.new()
		var sphere = SphereMesh.new()
		sphere.radius = 0.2; sphere.height = 0.4
		dot.mesh = sphere
		dot.position = world_pos + Vector3(0, 0.2, 0)
		var dot_mat = StandardMaterial3D.new()
		dot_mat.albedo_color = ring_color
		dot_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		dot_mat.render_priority = 10
		dot_mat.no_depth_test = true
		dot.material_override = dot_mat
		entities_container.add_child(dot)
		new_markers.append(dot)

		# Number label
		var lbl = Label3D.new()
		lbl.text = str(i + 1); lbl.font_size = 32
		lbl.position = Vector3(0, 0.8, 0); lbl.modulate = Color(1.0, 0.55, 0.0) if is_loop else Color.CYAN
		lbl.render_priority = 11
		lbl.no_depth_test = true
		marker.add_child(lbl)

	all_wp[eid] = new_markers

# Control-group label colors (same as HUD)
# Helper: get control-group prefix string for label
func _get_entity_group_prefix(eid: int) -> String:
	var inp = get_node_or_null("ClientInput")
	if not inp or not inp.has_method("get_entity_groups"): return ""
	var groups = inp.get_entity_groups(eid)
	if groups.is_empty(): return ""
	var s = ""
	for g in groups:
		s += "T%d " % g
	return s

const GROUP_LABEL_COLORS = {
	1: Color(1.0, 0.3, 0.2),   # Red
	2: Color(0.2, 0.6, 1.0),   # Blue
	3: Color(0.2, 1.0, 0.3),   # Green
	4: Color(1.0, 1.0, 0.2),   # Yellow
	5: Color(1.0, 0.5, 0.0),   # Orange
	6: Color(0.7, 0.3, 1.0),   # Purple
	7: Color(0.0, 1.0, 1.0),   # Cyan
	8: Color(1.0, 0.4, 0.7),   # Pink
	9: Color(0.5, 1.0, 0.5),   # Mint
}

# Helper: get color for entity label (by control group first, then owner/team)
func _get_entity_label_color(info: Dictionary) -> Color:
	var eid = info["id"]
	var inp = get_node_or_null("ClientInput")
	if inp and inp.has_method("get_entity_groups"):
		var groups = inp.get_entity_groups(eid)
		if groups.size() > 0 and GROUP_LABEL_COLORS.has(groups[0]):
			return GROUP_LABEL_COLORS[groups[0]]
	
	
	return Color.WHITE

func _should_entity_be_visible(ent: Dictionary) -> bool:
	if ent["team"] == player_team:
		return true
	if ent["team"] == RTSConfig.Team.NEUTRAL:
		var gx = int(ent["x"] + RTSConfig.MAP_SIZE/2)
		var gz = int(ent["z"] + RTSConfig.MAP_SIZE/2)
		if gx<0 or gx>=RTSConfig.MAP_SIZE or gz<0 or gz>=RTSConfig.MAP_SIZE: return false
		return local_explored_grid[gx][gz]
	# 敌方单位
	var gx = int(ent["x"] + RTSConfig.MAP_SIZE/2)
	var gz = int(ent["z"] + RTSConfig.MAP_SIZE/2)
	if gx<0 or gx>=RTSConfig.MAP_SIZE or gz<0 or gz>=RTSConfig.MAP_SIZE: return false
	return local_visible_grid[gx][gz]

func _get_valid_entities() -> Array:
	var arr = []
	for n in entity_nodes.values():
		if n.has_meta("snapshot_info"):
			arr.append(n)
	return arr

# ==================== 血条系统（与单机版风格一致） ====================
# Periodic cleanup of entity nodes that no longer have valid server data
func _cleanup_stale_entities():
	var to_remove = []
	for id in entity_nodes.keys():
		var node = entity_nodes.get(id)
		if not is_instance_valid(node):
			to_remove.append(id)
			continue
		if not node.has_meta("snapshot_info"):
			to_remove.append(id)
	if to_remove.size() > 0:
		for id in to_remove:
			entity_nodes.erase(id)
			_remove_all_bars(id)
		print("[ClientRenderer] Cleaned up ", to_remove.size(), " stale entity nodes")

func _update_health_bars():
	var cam = get_viewport().get_camera_3d()
	if not cam: return
	var viewport_rect = get_viewport().get_visible_rect().grow(50)

	for id in entity_nodes.keys():
		var node = entity_nodes.get(id)
		if not is_instance_valid(node): continue
		if not node.has_meta("snapshot_info"): continue
		var info = node.get_meta("snapshot_info")
		if not info: continue
		if not info.has("health") or not info.has("type"): continue
		if info["health"] <= 0: continue  # 已死亡实体不显示血条
		var hp = info["health"]
		var max_hp = info.get("max_health", hp)
		if max_hp <= 0: max_hp = hp  # 防止除零
		var type = info["type"]
		var team = info.get("team", -1)

		# 建造中
		if type == 1 and info.get("build_timer", 0) > 0:
			var bar = _get_or_create_health_bar(id)
			var lab = _get_or_create_label(id)
			bar.visible = true; lab.visible = true
			bar.update_bar(info["build_timer"], info["max_build_time"], -1)
			var nm2 = info["name"]
			var _gpfx3 = _get_entity_group_prefix(info["id"])
			lab.text = _gpfx3 + "%s (建造中)" % nm2
			var _lbc3 = _get_entity_label_color(info)
			lab.add_theme_color_override("font_color", _lbc3)
			var world_pos = node.global_position + Vector3.UP * (info["body_radius"]*2 + 0.5)
			var screen_pos = cam.unproject_position(world_pos)
			if viewport_rect.has_point(screen_pos):
				bar.position = screen_pos - Vector2(30, 5)
				lab.position = bar.position + Vector2(0, -22)
				lab.visible = true
			else:
				bar.visible = false; lab.visible = false
			continue

		# 生产中
		# Upgrade progress (purple bar matching health bar style, above HP)
		if info.get("upgrade_timer", 0) > 0:
			var upbar = _get_or_create_upgrade_bar(id)
			var uplab = _get_or_create_upgrade_label(id)
			upbar.visible = true; uplab.visible = true
			upbar.update_bar(info["upgrade_timer"], info["max_upgrade_time"], -1)
			upbar.set_team_color(Color(0.6, 0.2, 0.8))
			uplab.text = "升级中"
			uplab.add_theme_color_override("font_color", Color(0.8, 0.4, 1.0))
			var uwp = node.global_position + Vector3.UP * (info["body_radius"]*2 + 0.5)
			var usp = cam.unproject_position(uwp)
			if viewport_rect.has_point(usp):
				upbar.position = usp - Vector2(30, 5) + Vector2(0, -20)
				uplab.position = upbar.position + Vector2(0, -14)
				uplab.visible = true
			else:
				upbar.visible = false; uplab.visible = false
		else:
			_hide_upgrade_bars(id)

		if type == 1 and info.has("production_current_unit") and info["production_current_unit"] != -1:
			var pbar = _get_or_create_prod_bar(id)
			var plab = _get_or_create_prod_label(id)
			pbar.visible = true; plab.visible = true
			pbar.value = info["production_progress"]
			var unit_cfg = EntityDatabase.get_config(info["production_current_unit"])
			plab.text = "%s x%d" % [unit_cfg.get("name","?"), info["production_queue_size"]]
			var world_pos = node.global_position + Vector3.UP * (info["body_radius"]*2 + 0.5)
			var screen_pos = cam.unproject_position(world_pos)
			if viewport_rect.has_point(screen_pos):
				pbar.position = screen_pos - Vector2(30, 0) + Vector2(0, 6)
				plab.position = pbar.position + Vector2(0, -12)
				plab.visible = true
			else:
				pbar.visible = false; plab.visible = false

			if hp < max_hp:
				var bar = _get_or_create_health_bar(id)
				bar.visible = true
				bar.update_bar(hp, max_hp, team)
				if viewport_rect.has_point(screen_pos):
					bar.position = screen_pos - Vector2(30, 5) + Vector2(0, -22)
				else: bar.visible = false
			else:
				if unit_bars.has(id) and unit_bars[id].bar: unit_bars[id].bar.visible = false
			continue

		# 普通实体
		_hide_prod_bars(id)
		var lab = _get_or_create_label(id)
		var nm3 = info["name"]
		var _gpfx1 = _get_entity_group_prefix(info["id"])
		var _res_info2 = ""
		if info.get("entity_id") in [10, 14]:
			var _ord2 = info.get("order", "")
			if _ord2 == "deliver": _res_info2 = "\n返回"
			elif _ord2 == "gather": _res_info2 = "\n采集中"
		lab.text = _gpfx1 + "%s Lv.%d%s" % [nm3, info.get("level", 1), _res_info2]

		var _lbc = _get_entity_label_color(info)
		lab.add_theme_color_override("font_color", _lbc)
		var world_pos = node.global_position + Vector3.UP * (info["body_radius"]*2 + 0.5)
		var screen_pos = cam.unproject_position(world_pos)

		if hp < max_hp:
			var bar = _get_or_create_health_bar(id)
			bar.visible = true
			bar.update_bar(hp, max_hp, team)
			if viewport_rect.has_point(screen_pos):
				bar.position = screen_pos - Vector2(30, 5)
				lab.position = bar.position + Vector2(0, -22)
				lab.visible = true
				var _gpfx2 = _get_entity_group_prefix(info["id"])
				var _res_info = ""
				if info.get("entity_id") in [10, 14]:
					var _ord = info.get("order", "")
					if _ord == "deliver": _res_info = "\n返回"
					elif _ord == "gather": _res_info = "\n采集中"
				lab.text = _gpfx2 + "%s Lv.%d%s\n%d/%d" % [info["name"], info.get("level", 1), _res_info, hp, max_hp]

				var _lbc4 = _get_entity_label_color(info)
				lab.add_theme_color_override("font_color", _lbc4)
			else:
				bar.visible = false; lab.visible = false
		else:
			if unit_bars.has(id) and unit_bars[id].bar: unit_bars[id].bar.visible = false
			if viewport_rect.has_point(screen_pos):
				lab.position = screen_pos - Vector2(30, 15)
				lab.visible = true
			else: lab.visible = false

# ==================== 血条控件创建 ====================
func _get_or_create_health_bar(id) -> HealthBarControl:
	if not unit_bars.has(id):
		unit_bars[id] = { "bar":null, "label":null, "prod_bar":null, "prod_label":null, "order_label":null }
	if not unit_bars[id].bar:
		var b = HealthBarControl.new()
		b.custom_minimum_size = Vector2(60, 10)
		add_child(b)
		unit_bars[id].bar = b
	return unit_bars[id].bar

func _get_or_create_label(id) -> Label:
	if not unit_bars.has(id):
		unit_bars[id] = { "bar":null, "label":null, "prod_bar":null, "prod_label":null, "order_label":null }
	if not unit_bars[id].label:
		var l = Label.new()
		l.add_theme_font_size_override("font_size", 20)
		l.add_theme_color_override("font_color", Color.WHITE)
		l.add_theme_color_override("font_outline_color", Color.BLACK)
		l.add_theme_constant_override("outline_size", 1)
		add_child(l)
		unit_bars[id].label = l
	return unit_bars[id].label

func _get_or_create_prod_bar(id) -> ProgressBar:
	if not unit_bars.has(id):
		unit_bars[id] = { "bar":null, "label":null, "prod_bar":null, "prod_label":null, "order_label":null }
	if not unit_bars[id].prod_bar:
		var p = ProgressBar.new()
		p.custom_minimum_size = Vector2(60, 6)
		p.max_value = 1.0
		p.show_percentage = false
		add_child(p)
		unit_bars[id].prod_bar = p
	return unit_bars[id].prod_bar

func _get_or_create_prod_label(id) -> Label:
	if not unit_bars.has(id):
		unit_bars[id] = { "bar":null, "label":null, "prod_bar":null, "prod_label":null, "order_label":null, "upgrade_bar":null, "upgrade_label":null }
	if not unit_bars[id].has("prod_label") or not unit_bars[id].prod_label:
		var l = Label.new()
		l.add_theme_font_size_override("font_size", 20)
		l.add_theme_color_override("font_color", Color.WHITE)
		add_child(l)
		unit_bars[id].prod_label = l
	return unit_bars[id].prod_label

func _get_or_create_upgrade_bar(id) -> HealthBarControl:
	if not unit_bars.has(id):
		unit_bars[id] = { "bar":null, "label":null, "prod_bar":null, "prod_label":null, "order_label":null, "upgrade_bar":null, "upgrade_label":null }
	if not unit_bars[id].has("upgrade_bar") or not unit_bars[id].upgrade_bar:
		var hb = HealthBarControl.new()
		hb.custom_minimum_size = Vector2(60, 10)
		add_child(hb)
		unit_bars[id].upgrade_bar = hb
	return unit_bars[id].upgrade_bar

func _get_or_create_upgrade_label(id) -> Label:
	if not unit_bars.has(id):
		unit_bars[id] = { "bar":null, "label":null, "prod_bar":null, "prod_label":null, "order_label":null, "upgrade_bar":null, "upgrade_label":null }
	if not unit_bars[id].has("upgrade_label") or not unit_bars[id].upgrade_label:
		var l = Label.new()
		l.add_theme_font_size_override("font_size", 12)
		l.add_theme_color_override("font_color", Color(0.8, 0.4, 1.0))
		add_child(l)
		unit_bars[id].upgrade_label = l
	return unit_bars[id].upgrade_label


	if not unit_bars.has(id):
		unit_bars[id] = { "bar":null, "label":null, "prod_bar":null, "prod_label":null, "order_label":null }
	if not unit_bars[id].prod_label:
		var l = Label.new()
		l.add_theme_font_size_override("font_size", 20)
		l.add_theme_color_override("font_color", Color.WHITE)
		add_child(l)
		unit_bars[id].prod_label = l
	return unit_bars[id].prod_label

func _hide_upgrade_bars(id):
	if unit_bars.has(id):
		if unit_bars[id].has("upgrade_bar") and unit_bars[id].upgrade_bar:
			unit_bars[id].upgrade_bar.visible = false
		if unit_bars[id].has("upgrade_label") and unit_bars[id].upgrade_label:
			unit_bars[id].upgrade_label.visible = false

func _hide_prod_bars(id):
	if unit_bars.has(id):
		if unit_bars[id].prod_bar: unit_bars[id].prod_bar.visible = false
		if unit_bars[id].prod_label: unit_bars[id].prod_label.visible = false

func _remove_all_bars(id):
	if unit_bars.has(id):
		var data = unit_bars[id]
		if data.bar: data.bar.queue_free()
		if data.label: data.label.queue_free()
		if data.prod_bar: data.prod_bar.queue_free()
		if data.prod_label: data.prod_label.queue_free()
		if data.order_label: data.order_label.queue_free()
		unit_bars.erase(id)

# ==================== 小地图数据收集 ====================
func _collect_entity_snapshots() -> Array:
	var list = []
	for node in entity_nodes.values():
		if not node.has_meta("snapshot_info"): continue
		var info = node.get_meta("snapshot_info")
		if info.health > 0:
			list.append(info)
	return list
const MAX_DELTA_PER_FRAME = 15
# ==================== 地形与视野工具 ====================
func is_in_player_vision(world_pos: Vector3) -> bool:
	for node in entity_nodes.values():
		var info = node.get_meta("snapshot_info", null)
		if info and info["team"] == player_team and info["health"] > 0:
			if node.global_position.distance_to(world_pos) <= info.get("vision_range", 12):
				return true
	return false

func get_terrain_at(pos: Vector3) -> int:
	var map = get_node_or_null("Map")
	if map and map.has_method("get_terrain"):
		return map.get_terrain(int(pos.x + RTSConfig.MAP_SIZE/2), int(pos.z + RTSConfig.MAP_SIZE/2))
	return -1

func get_terrain_at_grid(gx: int, gy: int) -> int:
	var map = get_node_or_null("Map")
	if map and map.has_method("get_terrain"):
		return map.get_terrain(gx, gy)
	return -1

func get_terrain_height(world_pos: Vector3) -> float:
	var map = get_node_or_null("Map")
	if map and map.has_method("get_height_at"):
		return map.get_height_at(world_pos)
	return 0.0

# ==================== 游戏结束面板 ====================
func show_game_over(winner_team: int):
	var existing = get_node_or_null("UI/GameOverPanel")
	if existing: existing.queue_free()

	var panel = Control.new()
	panel.name = "GameOverPanel"
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP

	var bg = ColorRect.new()
	bg.color = Color(0, 0, 0, 0.7)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.add_child(bg)

	var vbox = VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	vbox.custom_minimum_size = Vector2(300, 200)
	vbox.add_theme_constant_override("separation", 20)
	panel.add_child(vbox)

	var res_lab = Label.new()
	res_lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	res_lab.add_theme_font_size_override("font_size", 48)
	if winner_team == player_team:
		res_lab.text = "胜利！"
		res_lab.add_theme_color_override("font_color", Color.GREEN)
	else:
		res_lab.text = "失败！"
		res_lab.add_theme_color_override("font_color", Color.RED)
	vbox.add_child(res_lab)

	var btn_restart = Button.new()
	btn_restart.text = "返回联机菜单"
	btn_restart.custom_minimum_size = Vector2(200, 50)
	btn_restart.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/online_menu.tscn"))
	vbox.add_child(btn_restart)

	var btn_quit = Button.new()
	btn_quit.text = "返回主菜单"
	btn_quit.custom_minimum_size = Vector2(200, 50)
	btn_quit.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/main_menu.tscn"))
	vbox.add_child(btn_quit)

	var ui = get_node_or_null("UI")
	if not ui: ui = get_tree().root
	ui.add_child(panel)
func _process(delta):
	# 1. 快照处理 —— 始终优先（带崩溃循环保护）
	if snapshot_processing and not latest_snapshot.is_empty():
		if _snapshot_fail_count > 10:
			# 连续失败太多次，丢弃当前快照并重置
			latest_snapshot.clear()
			snapshot_processing = false
			_snapshot_fail_count = 0
			_snapshot_cooldown = 30
			print('[ClientRenderer] Too many snapshot failures, skipping. Cooldown 30 frames.')
		elif _snapshot_cooldown > 0:
			# 冷却期内丢弃快照，让系统恢复
			latest_snapshot.clear()
			snapshot_processing = false
			_snapshot_cooldown -= 1
		else:
			var snap = latest_snapshot.duplicate()
			latest_snapshot.clear()
			snapshot_processing = false
			_snapshot_fail_count += 1
			_safe_process_snapshot(snap)
			_snapshot_fail_count = 0

	# 2. pending_delta 积压处理
	if pending_delta.size() > 0:
		var count = min(pending_delta.size(), MAX_DELTA_PER_FRAME)
		for i in range(count):
			_update_single_entity(pending_delta.pop_front())

	# 3. 增量迷雾：每帧处理一批单位（不受交错调度限制）
	if fog_cycle_active:
		_process_fog_batch()

	# 4. 计时器更新
	# 快照超时诊断
	_diag_snap_age += delta
	if _diag_snap_age > 2.0 and _diag_last_snap_time > 0:
		print("[Client] ⚠️ 快照超时! %.1fs 未收到快照, seq=%d, 已收=%d" % [_diag_snap_age, last_applied_seq, _diag_snap_count])
		_diag_snap_age = 0.0

	health_bar_timer -= delta
	fog_timer -= delta
	minimap_timer -= delta

	# 5. 启动新迷雾周期
	if fog_timer <= 0 and not fog_cycle_active:
		fog_timer = 2.0
		_start_fog_cycle()

	# 6. Periodic stale entity cleanup (every 30s)
	_stale_cleanup_timer -= delta
	if _stale_cleanup_timer <= 0:
		_stale_cleanup_timer = 30.0
		_cleanup_stale_entities()

	# 血条更新：高频率跟随（20Hz）
	if health_bar_timer <= 0:
		health_bar_timer = HEALTH_BAR_INTERVAL
		_update_health_bars()

	# 小地图更新
	if minimap_timer <= 0:
		minimap_timer = 1.0
		var minimap = get_node_or_null("UI/Minimap")
		if minimap:
			if minimap.terrain_colors.is_empty():
				var minimap_map = get_node_or_null("Map")
				if minimap_map and minimap_map.has_method("get_base_colors"):
					minimap.terrain_colors = minimap_map.get_base_colors()
			minimap.set_data(local_explored_grid, local_visible_grid, _collect_entity_snapshots())

# 7. 建造预览
	if placement_mode:
		var inp = $ClientInput
		if inp and inp.has_method("get_last_world_pos"):
			var pos = inp.get_last_world_pos()
			placement_preview.global_position = pos

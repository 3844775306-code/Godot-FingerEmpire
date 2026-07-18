class_name OnlineBattleManager
extends RTSBattleManager

# ==================== 模式与玩家管理 ====================
var game_mode: int = NetworkManager.GameMode.ONEvONE

# 1v1 专用
var player_teams: Dictionary = {}         # peer_id -> team


# 2v2 专用
var player_info: Dictionary = {}          # peer_id -> { "team": int, "slot": int, "alive": bool, "color": Color, "nation": int }
var player_castles: Dictionary = {}       # peer_id -> Building
   # peer_id -> { "gold": int, "wood": int, ... }
var player_population: Dictionary = {}    # peer_id -> { "current": int, "max": int }
# 删除原来的：var player_resource_limits: Dictionary = {}
# 新增
var player_limits_dict: Dictionary = {}   # 用于 2v2，key = peer_id  # peer_id -> { "gold": int, ... }
# 国家选择暂存
var pending_nations: Dictionary = {}      # peer_id -> nation

# 游戏状态
var has_game_started: bool = false
var snapshot_seq = 0
var player_last_snapshot_ids: Dictionary = {}   # peer_id -> Array[int]  # peer_id -> Array[int]
var player_all_visible_ids: Dictionary = {}     # peer_id -> Dictionary (所有可见实体ID，用于死亡检测)
# 快照系统
var snapshot_timer: float = 0.0
const SNAPSHOT_INTERVAL: float = 0.1
var broadcast_enabled: bool = false
var last_snapshot_cache: Dictionary = {}
var team_explored_resources: Dictionary = {}
var team_gather_paused: Dictionary = {}
var _mp_shift_held: bool = false

# ==================== 警报系统（服务器→客户端） ====================
var _pending_client_alerts: Dictionary = {}   # peer_id or team -> Array of {msg, color}

func _queue_client_alert(target_key, msg: String, color: Color = Color(1.0, 0.2, 0.1)):
	if not _pending_client_alerts.has(target_key):
		_pending_client_alerts[target_key] = []
	_pending_client_alerts[target_key].append({"msg": msg, "color": color})
	print("[AlertBug] Queued alert for key=%s: %s" % [str(target_key), msg])

func _get_and_clear_alerts(target_key) -> Array:
	var alerts = _pending_client_alerts.get(target_key, [])
	_pending_client_alerts[target_key] = []
	return alerts

# Override: queue alerts for clients in online mode
func _show_hud_alert(msg: String, color: Color = Color(1.0, 0.2, 0.1), _target_team: int = -1):
	super._show_hud_alert(msg, color)
	if _target_team >= 0:
		# Entity-specific alert: only for the owner's team
		_queue_client_alert(_target_team, msg, color)
	else:
		# Global alert: all players
		_queue_client_alert(RTSConfig.Team.BLUE, msg, color)
		_queue_client_alert(RTSConfig.Team.RED, msg, color)

# ==================== 采集统计（服务器端统一计算） ====================
var team_gather_counts: Dictionary = {}     # team 或 peer_id -> {"gold":0, "wood":0, ...}
var team_res_snapshots: Dictionary = {}     # 用于计算收入速率的资源快照
var team_income_rates: Dictionary = {}      # team 或 peer_id -> {"gold":0.0, ...}
var _gather_stat_timer: float = 0.0
var _income_calc_timer: float = 0.0

func get_mp_shift() -> bool:
	return _mp_shift_held



func get_resources_for(owner_id: int) -> Dictionary:
	if player_resources.has(owner_id):
		return player_resources[owner_id]
	if owner_id == -1:
		return enemy_resources
	if player_teams.has(owner_id):
		var team = player_teams[owner_id]
		if team == RTSConfig.Team.BLUE:
			return player_resources.get(1, {})
		return enemy_resources
	if player_info.has(owner_id):
		return player_resources.get(owner_id, {})
	return {}

func deduct_resources_for(owner_id: int, cost: Dictionary) -> bool:
	var res = get_resources_for(owner_id)
	if res.is_empty(): return false
	for k in cost:
		if res.get(k, 0) < cost[k]: return false
	for k in cost:
		res[k] -= cost[k]
	return true

func add_resource_for(owner_id: int, type: String, amount: int):
	var res = get_resources_for(owner_id)
	if res.has(type):
		var lim = 99999
		if player_limits_dict.has(owner_id):
			lim = player_limits_dict[owner_id].get(type, 99999)
		res[type] = min(res[type] + amount, lim)

func update_player_limits(peer_id: int):
	if not player_limits_dict.has(peer_id):
		player_limits_dict[peer_id] = {"gold":500, "wood":500, "stone":500, "food":500, "oil":0}
	var limits = player_limits_dict[peer_id]
	var castle = 0
	var warehouse_bonus = 0
	var shipyard = 0
	for entity in entities.get_children():
		if entity is Building and entity.health > 0 and entity.owner_peer_id == peer_id and entity.team == player_info[peer_id].team:
			if entity.entity_id == 20: castle += 1
			elif entity.entity_id == 22 and entity.build_timer <= 0: warehouse_bonus += entity.building_data.get("storage_bonus", 0)
			elif entity.entity_id == 23: shipyard += 1
	limits["gold"] = 500 + castle*300 + warehouse_bonus
	limits["wood"] = 500 + castle*300 + warehouse_bonus
	limits["stone"] = 500 + castle*300 + warehouse_bonus
	limits["food"] = 500 + castle*300 + warehouse_bonus
	limits["oil"] = shipyard * 700
# 增加指定玩家的资源
func add_player_resource(peer_id: int, type: String, amount: int):
	if not player_resources.has(peer_id):
		player_resources[peer_id] = {"gold":100, "wood":100, "stone":100, "food":100, "oil":0}
	var res = player_resources[peer_id]
	var limits = player_limits_dict.get(peer_id, {})
	if res.has(type):
		res[type] = min(res[type] + amount, limits.get(type, 99999))

# 交付资源（玩家农民返回城堡/仓库时调用）
func deliver_player_resources(peer_id: int, cargo: Dictionary):
	for type in cargo:
		add_player_resource(peer_id, type, cargo[type])

# 减少玩家资源
func deduct_player_resources(peer_id: int, cost: Dictionary) -> bool:

	if not player_resources.has(peer_id): return false

	var res = player_resources[peer_id]

	# Check all resources are sufficient first to prevent negative values
	for type in cost:
		if res.get(type, 0) < cost[type]:
			return false

	# All sufficient, deduct
	for type in cost:
		res[type] -= cost[type]
	return true

# 增加指定玩家人口
func increase_player_population(peer_id: int, amount: int = 1):
	if player_population.has(peer_id):
		player_population[peer_id]["current"] += amount

# 减少指定玩家人口
func decrease_player_population(peer_id: int, amount: int = 1):
	if player_population.has(peer_id):
		player_population[peer_id]["current"] = max(0, player_population[peer_id]["current"] - amount)

# 检查该玩家是否可以训练单位（人口未满）
func can_player_train(peer_id: int) -> bool:
	if not player_population.has(peer_id): return false
	var pop = player_population[peer_id]
	return pop["current"] < pop["max"]*2
func update_player_population(peer_id: int):
	if not player_population.has(peer_id):
		player_population[peer_id] = {"current": 0, "max": 20} # 初始城堡20人口
	var max_pop = 0
	var info = player_info[peer_id]
	for entity in entities.get_children():
		if entity is Building and entity.owner_peer_id == peer_id and entity.health > 0:
			if entity.entity_id == 20: max_pop += 20
			elif entity.entity_id == 28: max_pop += 10
	if info:
		max_pop += NationBonuses.get_population_bonus(team_nations[info.team])
	player_population[peer_id]["max"] = max_pop
# ==================== 生命周期 ====================
func _ready():
	game_mode = NetworkManager.selected_mode

	if game_mode == NetworkManager.GameMode.ONEvONE:
		RTSConfig.MAP_SIZE = 100
		
	else:
		RTSConfig.MAP_SIZE = 150
	
	is_online = true
	super._ready()                         # 父类 _ready 因 is_online=true 不会生成实体
	add_to_group("online_battle_manager")
	#set_process_input(false)

	game_mode = NetworkManager.selected_mode
	if game_mode == NetworkManager.GameMode.ONEvONE:
		RTSConfig.MAP_SIZE = 100
		await _init_1v1()
	else:
		RTSConfig.MAP_SIZE = 150
		await _init_2v2()

# ---------- 1v1 初始化 ----------
func _init_1v1():
	# 等待 2 名玩家
	while multiplayer.get_peers().size() < 2:
		await get_tree().process_frame

	var peers = multiplayer.get_peers()
	peers.sort()
	for i in range(peers.size()):
		var team = RTSConfig.Team.BLUE if i == 0 else RTSConfig.Team.RED
		player_teams[peers[i]] = team
		# 如果暂存了国家
		if pending_nations.has(peers[i]):
			team_nations[team] = pending_nations[peers[i]]
			pending_nations.erase(peers[i])

	# 发送地图数据
	_send_map_data(peers)
	# 通知队伍
	for pid in peers:
		NetworkManager._notify_team.rpc_id(pid, player_teams[pid])
	# 等待国家选择
	await _wait_for_nations_1v1()
	# 开始游戏
	has_game_started = true
	



	_init_entities_deferred()   # 父类的实体生成（会用到 team_nations）
	# 修正联机模式的 owner_peer_id（父类用的是硬编码 1/3）
	for pid in peers:
		var team = player_teams[pid]
		var castle = get_castle_by_team(team)
		if castle: castle.owner_peer_id = pid
	_player_colors.clear()
	for pid in peers:
		_player_colors[pid] = RTSConfig.COLOR_POOL[player_teams[pid]]
	set_process(true)
	broadcast_enabled = true
	# 发送城堡位置
	await get_tree().process_frame
	for pid in peers:
		var team = player_teams[pid]
		var castle = get_castle_by_team(team)
		if castle:
			NetworkManager.notify_castle_pos.rpc_id(pid, castle.global_position)
# ---- 颜色调试 ----
var _color_debug_done: bool = false
func _debug_print_colors():
	if _color_debug_done: return
	_color_debug_done = true
	print("[ColorDebug] ===== 玩家颜色分配 =====")
	for pid in player_info.keys():
		var info = player_info[pid]
		print("[ColorDebug] peer=%d team=%s slot=%d color=%s" % [pid, "BLUE" if info.team == RTSConfig.Team.BLUE else "RED", info.slot, str(info.color)])
	#print("[ColorDebug] all_player_colors dict: ", all_player_colors if "all_player_colors" in locals() else "(not built yet)")
	print("[ColorDebug] =========================")
func _wait_for_nations_1v1():
	while true:
		if team_nations[RTSConfig.Team.BLUE] != -1 and team_nations[RTSConfig.Team.RED] != -1:
			return
		await get_tree().process_frame

# ---------- 2v2 初始化 ----------
func _init_2v2():
	
	RTSConfig.MAP_SIZE = 150

	# 完全重新生成地图（不依赖旧的 Map 节点状态）
	# 立即移除旧地图节点（避免引用残留）
	var old_map = $Map
	if old_map:
		remove_child(old_map)
		old_map.queue_free() # 删除旧地图
	var map_node = load("res://scripts/map/Ground.gd").new()
	map_node.name = "Map"
	add_child(map_node)
	# 为新地图设置自定义种子（可选）
	map_node.custom_seed = randi()
	# 手动调用 _ready 来生成地形、城堡、资源
	map_node._ready()
	# 确保 terrain_grid 已经填充
	print("[服务器] 2v2 地图已重建，尺寸:", RTSConfig.MAP_SIZE, " 地形网格大小:", map_node.terrain_grid.size())
	# 计算所需人类玩家数量
	
	var red_slots_free = 2 - NetworkManager.red_ai_count
	var blue_slots_free = 2 - NetworkManager.blue_ai_count
	var required_humans = red_slots_free + blue_slots_free

	print("[2v2] 需要人类玩家数:", required_humans, " 红方AI:", NetworkManager.red_ai_count, " 蓝方AI:", NetworkManager.blue_ai_count)

	# 等待足够的人类玩家连接
	while multiplayer.get_peers().size() < required_humans:
		await get_tree().process_frame

	var peers = multiplayer.get_peers()
	peers.sort()

	var red_assigned = 0
	var blue_assigned = 0

	# ---------- 分配人类玩家到剩余空位 ----------
	for i in range(peers.size()):
		var team: int
		if red_assigned < red_slots_free and (red_assigned <= blue_assigned or blue_assigned >= blue_slots_free):
			team = RTSConfig.Team.RED
		else:
			team = RTSConfig.Team.BLUE

		var slot = red_assigned if team == RTSConfig.Team.RED else blue_assigned
		var color = _pick_player_color()   # 从颜色池随机分配
		var nation = pending_nations.get(peers[i], 0)

		player_info[peers[i]] = {
			"team": team, "slot": slot, "alive": true,
			"color": color, "nation": nation
		}
		player_resources[peers[i]] = { "gold": 100, "wood": 100, "stone": 100, "food": 100, "oil": 0 }
		player_population[peers[i]] = { "current": 3, "max": 20 }

		if team == RTSConfig.Team.RED:
			red_assigned += 1
		else:
			blue_assigned += 1

		print("[2v2] 分配人类 ", peers[i], " 到队伍 ", "红" if team == RTSConfig.Team.RED else "蓝", " 槽位", slot)

	# ---------- 补充 AI 玩家（完全按照菜单设置的数量） ----------
	# 红方 AI
	for i in range(NetworkManager.red_ai_count):
		if red_assigned >= 2: break   # 保险
		var ai_id = _generate_ai_id(RTSConfig.Team.RED, red_assigned)
		_create_ai_player(ai_id, RTSConfig.Team.RED, red_assigned)
		red_assigned += 1
		print("[2v2] 添加红方AI, peer_id=", ai_id, " slot=", red_assigned-1)

	# 蓝方 AI
	for i in range(NetworkManager.blue_ai_count):
		if blue_assigned >= 2: break
		var ai_id = _generate_ai_id(RTSConfig.Team.BLUE, blue_assigned)
		_create_ai_player(ai_id, RTSConfig.Team.BLUE, blue_assigned)
		blue_assigned += 1
		print("[2v2] 添加蓝方AI, peer_id=", ai_id, " slot=", blue_assigned-1)

	print("[2v2] 最终分配: 红方", red_assigned, "人, 蓝方", blue_assigned, "人")

	# 广播颜色、地图、队伍信息等（保持不变）
	var all_player_colors = {}
	for pid in player_info.keys():
		all_player_colors[pid] = player_info[pid].color
	_player_colors = all_player_colors  # 同步到父类，供 Entity 颜色查询
	for pid in player_info.keys():
		NetworkManager.notify_all_player_colors.rpc_id(pid, all_player_colors)

	_send_map_data(player_info.keys())
	for pid in player_info.keys():
		var info = player_info[pid]
		NetworkManager.notify_team_info.rpc_id(pid, pid, info.team, info.slot, info.color)

	has_game_started = true
	



	_init_all_castles_2v2()
	_debug_print_colors()
	set_process(true)
	broadcast_enabled = true

	await get_tree().process_frame
	for pid in player_info.keys():
		var castle = player_castles.get(pid)
		if castle:
			NetworkManager.notify_castle_pos.rpc_id(pid, castle.global_position)
# 辅助函数
func _count_human_players(team: int) -> int:
	var count = 0
	for pid in player_teams.keys():
		if player_teams[pid] == team:
			count += 1
	return count

func _generate_ai_id(team: int, index: int) -> int:
	return 1000 + team * 10 + index

func _create_ai_player(peer_id: int, team: int, slot: int):
	var ai_nation = randi() % 5
	player_info[peer_id] = {
		"team": team,
		"slot": slot,
		"alive": true,
		"color": _get_ai_color(team, slot),
		"nation": ai_nation
	}
	player_resources[peer_id] = {
		"gold": 100, "wood": 100, "stone": 100, "food": 100, "oil": 0
	}
	player_population[peer_id] = {"current": 3, "max": 30}
	team_nations[team] = ai_nation

	

	# 附加 AI 控制器
	var ai_controller = AIController.new()
	ai_controller.my_peer_id = peer_id
	ai_controller.my_team = team
	add_child(ai_controller)
# 根据队伍和槽位为 AI 分配一个独特颜色（避免与人类玩家重复）
var _color_used_count: int = 0

func _pick_player_color() -> Color:
	var c = RTSConfig.COLOR_POOL[_color_used_count % RTSConfig.COLOR_POOL.size()]
	_color_used_count += 1
	return c

func _get_ai_color(team: int, slot: int) -> Color:
	var idx = _color_used_count
	_color_used_count += 1
	return RTSConfig.COLOR_POOL[idx % RTSConfig.COLOR_POOL.size()]
func _get_ai_castle_pos(team: int, slot: int) -> Vector3:
	var map = $Map
	if not map: return Vector3.ZERO

	# 根据队伍使用预设的基准位置
	var base_pos = map.player_castle_pos if team == RTSConfig.Team.BLUE else map.enemy_castle_pos
	# 槽位偏移：槽0在基准左上方，槽1在基准右下方
	var offset = Vector3(0, 0, 0)
	if slot == 0:
		offset = Vector3(-10, 0, -5)
	elif slot == 1:
		offset = Vector3(10, 0, 5)

	var pos = base_pos + offset
	# 确保位置在平原且没有建筑重叠
	return find_valid_build_position(pos, 20)
func find_valid_build_position(near_pos: Vector3, building_id: int) -> Vector3:
	var cfg = EntityDatabase.get_config(building_id)
	var radius = cfg.get("body_radius", 1.0)
	for _try in range(20):
		var angle = randf_range(0, TAU)
		var dist = randf_range(3.0, 10.0)
		var test_pos = near_pos + Vector3(cos(angle) * dist, 0, sin(angle) * dist)
		# 地形检查：必须为平原（0）
		if get_terrain_at(test_pos) != 0:
			continue
		# 高度调整
		var map = $Map
		if map and map.has_method("get_height_at"):
			test_pos.y = map.get_height_at(test_pos)
		# 重叠检测
		var overlap = false
		for entity in entities.get_children():
			if not (entity is GameEntity) or entity.health <= 0: continue
			var d = test_pos.distance_to(entity.global_position) - (radius + entity.body_radius)
			if d < 1.0:
				overlap = true
				break
		if not overlap:
			return test_pos
	# 回退：返回原始位置，但至少在地形上可放置
	near_pos.y = 0
	return near_pos  # 20 是城堡的 ID
func _wait_for_nations_2v2():
	while true:
		var all_ok = true
		for pid in player_info.keys():
			if player_info[pid].nation < 0:
				all_ok = false
				break
		if all_ok: return
		await get_tree().process_frame

# ---------- 地图发送 ----------
func _send_map_data(peers: Array):
	var terrain_copy = $Map.terrain_grid.duplicate(true)
	var res_data = []
	for r in $Map.resource_positions:
		res_data.append({
			"x": r["pos"].x, "y": r["pos"].y, "z": r["pos"].z,
			"type": r["type"]
		})
	for pid in peers:
		NetworkManager.receive_map_data.rpc_id(pid, terrain_copy, res_data)

# ---------- 2v2 城堡生成 ----------
func _init_all_castles_2v2():
	_debug_print_colors()
	var map = $Map
	if not map: return

	var positions = map.get_four_castle_positions()   # 返回 [blue1, blue2, red1, red2]
	var blue1 = positions[0]
	var blue2 = positions[1]
	var red1 = positions[2]
	var red2 = positions[3]

	# 给每位玩家分配城堡
	for pid in player_info.keys():
		var info = player_info[pid]
		var pos: Vector3
		if info.team == RTSConfig.Team.BLUE:
			pos = blue1 if info.slot == 0 else blue2
		else:
			pos = red1 if info.slot == 0 else red2

		_player_colors[pid] = info.color  # 确保城堡创建时颜色可用
		_create_player_castle(pid, info.team, pos)

		# 生成3个初始农民
		var peasant_cfg = EntityDatabase.get_config(10)
		peasant_cfg["team"] = info.team
		for i in range(3):
			var spawn_pos = pos + Vector3(randf_range(-4,4), 0, randf_range(-4,4))
			var cfg = peasant_cfg.duplicate()
			cfg["owner_peer_id"] = pid
			spawn_entity(cfg, info.team, spawn_pos, 1)

	# 资源点生成
	for res in map.resource_positions:
		var cfg = EntityDatabase.get_config(res.type)
		if cfg: spawn_entity(cfg, RTSConfig.Team.NEUTRAL, res.pos)

	_init_fog_grid()
	
func _create_player_castle(peer_id: int, team: int, pos: Vector3):
	var cfg = EntityDatabase.get_config(20)
	cfg["team"] = team
	cfg["produces"] = [{"unit_id": 10, "cooldown": 3.0, "queue_limit": 10}, {"unit_id": 19, "cooldown": 4.0, "queue_limit": 5}]
	cfg["owner_peer_id"] = peer_id
	var castle = spawn_entity(cfg, team, pos, 1)   # 移除了多余的 peer_id 参数
	castle.owner_peer_id = peer_id
	if castle:
		castle.died.connect(_on_castle_died_2v2.bind(peer_id))
		player_castles[peer_id] = castle

func _get_team_players(team: int) -> Array:
	var arr = []
	for pid in player_info.keys():
		if player_info[pid].team == team and player_info[pid].alive:
			arr.append(pid)
	return arr
# ---------- 全局命令实现 ----------

func _stop_gather(team: int):
	var paused = team_gather_paused.get(team, false)
	team_gather_paused[team] = !paused
	if not paused:                         # 暂停
		for entity in entities.get_children():
			if entity is Army and entity.team == team and entity.health > 0:
				if entity.entity_id == 10 or entity.entity_id == 14:
					entity.current_target = null
					entity.current_order = ""
					entity.astar_path.clear()
					entity.is_attack_moving = false
	else:                                   # 恢复
		for entity in entities.get_children():
			if entity is Army and entity.team == team and entity.health > 0:
				if (entity.entity_id == 10 or entity.entity_id == 14) and entity.current_order == "":
					entity._find_nearest_resource()

func _toggle_hold_position(team: int):
	for entity in entities.get_children():
		if entity is Army and entity.team == team and entity.health > 0:
			if entity.entity_id not in [10, 14]:
				entity.hold_position = !entity.hold_position

func _rally(team: int, x: float, y: float, z: float):
	var pos = Vector3(x, y, z)
	for entity in entities.get_children():
		if entity is Army and entity.team == team and entity.health > 0:
			if entity.entity_id == 10 or entity.entity_id == 14: continue
			entity.move_to(pos)

func _global_attack(team: int):
	var target_team = RTSConfig.Team.RED if team == RTSConfig.Team.BLUE else RTSConfig.Team.BLUE
	var target = get_castle_by_team(target_team)
	if not target: return
	for entity in entities.get_children():
		if entity is Army and entity.team == team and entity.target_type > 0:
			entity.attack_move_to(target.global_position)

func _global_retreat(team: int):
	var home = get_castle_by_team(team)
	if not home: return
	for entity in entities.get_children():
		if entity is Army and entity.team == team and entity.target_type > 0:
			entity.move_to(home.global_position + Vector3(randf_range(-3,3), 0, randf_range(-3,3)))

# ---------- 命令处理（兼容两种模式） ----------
func process_command(peer_id: int, data: Dictionary):
	if game_mode == NetworkManager.GameMode.ONEvONE:
		_process_1v1_command(peer_id, data)
	else:
		_process_2v2_command(peer_id, data)

func _process_1v1_command(peer_id: int, data: Dictionary):
	var team = player_teams.get(peer_id, -1)
	if team == -1: return
	match data["action"]:
		"right_click":   _1v1_right_click(team, data)
		"build":         _1v1_build(team, data)
		"upgrade":       _1v1_upgrade(team, data)
		"produce":       _1v1_produce(team, data)
		"global_attack": _global_attack(team)
		"global_retreat": _global_retreat(team)
		"stop_gather":   _stop_gather(team)
		"toggle_hold_position": _toggle_hold_position(team)
		"rally":         _rally(team, data["pos_x"], data["pos_y"], data["pos_z"])
		"set_group":     _1v1_set_group(team, data)
		"recall_group":  _1v1_recall_group(team, data)
		"demolish":      _1v1_demolish(team, data)
		"set_garrison":  _set_garrison_for_team(team, data)
		"clear_garrison": _clear_garrison_for_team(team, data)

func _process_2v2_command(peer_id: int, data: Dictionary):
	if not player_info.has(peer_id) or not player_info[peer_id].alive: return
	match data["action"]:
		"right_click":   _2v2_right_click(peer_id, data)
		"build":         _2v2_build(peer_id, data)
		"upgrade":       _2v2_upgrade(peer_id, data)
		"produce":       _2v2_produce(peer_id, data)
		"global_attack": _2v2_global_attack(peer_id)
		"global_retreat": _2v2_global_retreat(peer_id)
		"stop_gather":   _2v2_stop_gather(peer_id)
		"toggle_hold_position": _2v2_toggle_hold(peer_id)
		"rally":         _2v2_rally(peer_id, data["pos_x"], data["pos_y"], data["pos_z"])
		"set_group":     _2v2_set_group(peer_id, data)
		"demolish":      _2v2_demolish(peer_id, data)
		"recall_group":  _2v2_recall_group(peer_id, data)
		"set_garrison":  _2v2_set_garrison(peer_id, data)
		"clear_garrison": _2v2_clear_garrison(peer_id, data)

# ---------- 1v1 命令实现 ----------
func _1v1_right_click(team: int, data: Dictionary):
	#print("[Server] right_click from team ", team, " targets: ", data.get("selected_ids", []).size(), " pos: ", data.get("pos_x", 0))
	var target_id = data.get("target_id", -1)
	var pos = Vector3(data.get("pos_x",0), data.get("pos_y",0), data.get("pos_z",0))
	var selected_ids = data.get("selected_ids", [])
	var shift_held = data.get("shift_held", false)
	var target: GameEntity = _find_entity_by_id(target_id) if target_id != -1 else null

	for entity in entities.get_children():
		if entity is Army and entity.team == team and entity.get_instance_id() in selected_ids:
			if not is_instance_valid(entity): continue
			if not shift_held:
				entity._clear_command_queue()
			entity._force_queue_next = shift_held
			if target:
				if target is WorldResource:
					entity.gather_at(target)
				elif target.team != entity.team:
					entity.attack_target(target)
				elif entity.entity_id >= 46 and entity.entity_id <= 50 and target is Building:
					entity._garrison_target_id = target.get_instance_id()
					entity.move_to(target.global_position)
				else:
					entity.move_to(target.global_position)
			else:
				entity.move_to(pos)

func _1v1_build(team: int, data: Dictionary):
	var building_id = data["building_id"]
	var pos = Vector3(data["pos_x"], data["pos_y"], data["pos_z"])
	var cfg = EntityDatabase.get_config(building_id)
	if cfg.is_empty(): return
	# Cannot build near enemies
	for e in entities.get_children():
		if e is GameEntity and e.team != team and e.team != RTSConfig.Team.NEUTRAL and e.health > 0:
			if e.global_position.distance_to(pos) < 10.0: return
	var res = player_resources if team == RTSConfig.Team.BLUE else enemy_resources
	var cost = cfg.get("cost", {})
	for r in cost.keys():
		if res[r] < cost[r]: return
	for r in cost.keys():
		res[r] -= cost[r]
	var b = spawn_entity(cfg, team, pos)
	if b: b.start_construction(5.0, cfg)

func _1v1_upgrade(team: int, data: Dictionary):
	var building_id = data["building_id"]
	var n = 999 if data.get("shift_held", false) else 1
	# 升级已全局生效，只需升级目标建筑
	for entity in entities.get_children():
		if entity is Building and entity.team == team and entity.get_instance_id() == building_id:
			for _i in range(n):
				if not entity.can_upgrade() or not entity.perform_upgrade(self): break
			break

func _1v1_produce(team: int, data: Dictionary):
	var building_id = data["building_id"]
	var unit_id = data["unit_id"]
	var n = 5 if data.get("shift_held", false) else 1
	var tid = -1
	for entity in entities.get_children():
		if entity is Building and entity.team == team and entity.get_instance_id() == building_id:
			tid = entity.entity_id; break
	if data.get("ctrl_held", false) and tid != -1:
		for entity in entities.get_children():
			if entity is Building and entity.team == team and entity.entity_id == tid:
				for _i in range(n):
					if not entity.try_produce(unit_id): break
	else:
		for entity in entities.get_children():
			if entity is Building and entity.team == team and entity.get_instance_id() == building_id:
				for _i in range(n): entity.try_produce(unit_id); break

# ---------- 2v2 命令实现 ----------
func _2v2_right_click(peer_id: int, data: Dictionary):
	var selected_ids = data.get("selected_ids", [])
	var target_id = data.get("target_id", -1)
	var pos = Vector3(data.get("pos_x",0), data.get("pos_y",0), data.get("pos_z",0))
	var shift_held = data.get("shift_held", false)
	var target: GameEntity = _find_entity_by_id(target_id) if target_id != -1 else null

	for entity in entities.get_children():
		if entity is Army and entity.get("owner_peer_id") == peer_id and entity.get_instance_id() in selected_ids:
			if not is_instance_valid(entity): continue
			if not shift_held:
				entity._clear_command_queue()
			entity._force_queue_next = shift_held
			if target:
				if target is WorldResource:
					entity.gather_at(target)
				elif target.get("team") != entity.team:
					entity.attack_target(target)
				elif entity.entity_id >= 46 and entity.entity_id <= 50 and target is Building:
					entity._garrison_target_id = target.get_instance_id()
					entity.move_to(target.global_position)
				else:
					entity.move_to(target.global_position)
			else:
				entity.move_to(pos)

func _2v2_build(peer_id: int, data: Dictionary):
	
	
	var building_id = data["building_id"]
	var pos = Vector3(data["pos_x"], data["pos_y"], data["pos_z"])
	var cfg = EntityDatabase.get_config(building_id)
	if cfg.is_empty(): return
	var cost = cfg.get("cost", {})
	# Cannot build near enemies
	for e in entities.get_children():
		if e is GameEntity and e.team != player_info[peer_id].team and e.team != RTSConfig.Team.NEUTRAL and e.health > 0:
			if e.global_position.distance_to(pos) < 10.0: return
	# 人口检查（防御塔）
	var is_defense = (building_id == 25 or building_id == 26)
	if is_defense and not can_player_train(peer_id):
		return
	# 扣除个人资源
	if not deduct_player_resources(peer_id, cost): return
	cfg["owner_peer_id"] = peer_id
	var b = spawn_entity(cfg, player_info[peer_id].team, pos, 1)
	if b:
		b.start_construction(5.0, cfg)
		if is_defense:
			increase_player_population(peer_id, 1)
		update_player_limits(peer_id)
		update_player_population(peer_id)

func _2v2_upgrade(peer_id: int, data: Dictionary):
	var building_id = data["building_id"]
	var n = 999 if data.get("shift_held", false) else 1
	# 升级已全局生效（2v2 按 peer_id 隔离），只需升级目标建筑
	for entity in entities.get_children():
		if entity is Building and entity.get_instance_id() == building_id and entity.owner_peer_id == peer_id:
			for _i in range(n):
				if not entity.can_upgrade() or not entity.perform_upgrade(self): break
			break
	update_player_limits(peer_id)
	update_player_population(peer_id)

func _2v2_produce(peer_id: int, data: Dictionary):
	var building_id = data["building_id"]
	var unit_id = data["unit_id"]
	var n = 5 if data.get("shift_held", false) else 1
	var tid = -1
	for entity in entities.get_children():
		if entity is Building and entity.owner_peer_id == peer_id and entity.get_instance_id() == building_id:
			tid = entity.entity_id; break
	if data.get("ctrl_held", false) and tid != -1:
		for entity in entities.get_children():
			if entity is Building and entity.owner_peer_id == peer_id and entity.entity_id == tid:
				for _i in range(n):
					if not entity.try_produce(unit_id): break
	else:
		for entity in entities.get_children():
			if entity is Building and entity.owner_peer_id == peer_id and entity.get_instance_id() == building_id:
				for _i in range(n): entity.try_produce(unit_id); break

func _2v2_global_attack(peer_id: int):
	var team = player_info[peer_id].team
	var enemy_team = RTSConfig.Team.BLUE if team == RTSConfig.Team.RED else RTSConfig.Team.RED
	var target = _get_first_alive_castle(enemy_team)
	if not target: return
	for entity in entities.get_children():
		if entity is Army and entity.get("owner_peer_id") == peer_id and entity.target_type > 0:
			entity.attack_move_to(target.global_position)

func _2v2_global_retreat(peer_id: int):
	var castle = player_castles.get(peer_id)
	if not castle: return
	for entity in entities.get_children():
		if entity is Army and entity.get("owner_peer_id") == peer_id and entity.target_type > 0:
			entity.move_to(castle.global_position + Vector3(randf_range(-3,3), 0, randf_range(-3,3)))

func _2v2_stop_gather(peer_id: int):
	var paused = team_gather_paused.get(peer_id, false)
	team_gather_paused[peer_id] = !paused
	for entity in entities.get_children():
		if entity is Army and entity.get("owner_peer_id") == peer_id and entity.entity_id in [10,14]:
			if not paused:
				entity.current_target = null
				entity.current_order = ""
				entity.astar_path.clear()
				entity.is_attack_moving = false
			else:
				if entity.current_order == "":
					entity._find_nearest_resource()

func _2v2_toggle_hold(peer_id: int):
	for entity in entities.get_children():
		if entity is Army and entity.get("owner_peer_id") == peer_id and entity.entity_id not in [10,14]:
			entity.hold_position = !entity.hold_position

func _2v2_rally(peer_id: int, x: float, y: float, z: float):
	var pos = Vector3(x, y, z)
	for entity in entities.get_children():
		if entity is Army and entity.get("owner_peer_id") == peer_id and entity.entity_id not in [10,14]:
			entity.move_to(pos)

# ---------- 通用工具 ----------
func _find_entity_by_id(id: int) -> GameEntity:
	for entity in entities.get_children():
		if entity.get_instance_id() == id:
			return entity
	return null

func get_castle_by_team(team: int) -> Building:
	for entity in entities.get_children():
		if entity is Building and entity.entity_id == 20 and entity.team == team:
			return entity
	return null

func _get_first_alive_castle(team: int) -> Building:
	for pid in player_castles.keys():
		if player_info[pid].team == team and player_info[pid].alive:
			return player_castles[pid]
	return null

func get_team_nation(team: int) -> int:
	return team_nations.get(team, -1)

# ---------- 国家分配 RPC ----------
func assign_nation(peer_id: int, nation: int):
	if game_mode == NetworkManager.GameMode.ONEvONE:
		if player_teams.has(peer_id):
			team_nations[player_teams[peer_id]] = nation
		else:
			pending_nations[peer_id] = nation
	else:
		if player_info.has(peer_id):
			player_info[peer_id].nation = nation
			team_nations[player_info[peer_id].team] = nation
		else:
			pending_nations[peer_id] = nation

# ---------- 游戏结束 ----------
func _on_castle_died_2v2(peer_id: int):
	if not player_info.has(peer_id): return
	player_info[peer_id].alive = false
	var team = player_info[peer_id].team
	# 整队检查
	for pid in player_info.keys():
		if player_info[pid].team == team and player_info[pid].alive:
			return   # 还有存活，不结束
	# 全队阵亡
	game_over = true
	var winner = RTSConfig.Team.BLUE if team == RTSConfig.Team.RED else RTSConfig.Team.RED
	for pid in player_info.keys():
		NetworkManager.notify_game_over.rpc_id(pid, winner)

# 1v1 的城堡死亡已在 RTSBattleManager 中通过 _on_castle_died 处理（游戏结束通知玩家）

# ---------- 快照广播 ----------

# ==================== 增量快照（Delta Compression） ====================
# 每个玩家的实体状态哈希表，只发送变化的实体，大幅减少网络流量
var _entity_state_hashes: Dictionary = {}   # key -> {entity_id: hash}
var _full_snapshot_counters: Dictionary = {} # key -> counter
const FULL_SNAPSHOT_EVERY: int = 30          # 每 30 个 delta (~3秒) 发一次全量基线

func _compute_entity_hash(entity: GameEntity) -> int:
	# 只对会变化的字段计算哈希（静态属性不参与）
	var s = "%d,%d,%d,%d,%d,%d,%s,%s,%d" % [
		int(entity.global_position.x * 100),
		int(entity.global_position.z * 100),
		int(entity.health),
		int(entity.max_health),
		entity.level,
		int(entity.attack),
		entity.current_order,
		str(entity.hold_position),
		int(entity.owner_peer_id)
	]
	if entity is Building:
		s += ",%d,%d,%d,%d" % [entity.upgrade_level, entity.production_queue.size(), int(entity.build_timer * 100), int(entity.production_timer * 100), int(entity.upgrade_timer * 100)]
	if entity.current_target and is_instance_valid(entity.current_target):
		s += ",%d" % entity.current_target.get_instance_id()
	return s.hash()

func _should_include_in_delta(snapshot_key, entity_id: int, new_hash: int) -> bool:
	if not _entity_state_hashes.has(snapshot_key):
		_entity_state_hashes[snapshot_key] = {}
	var hashes = _entity_state_hashes[snapshot_key]
	if not hashes.has(entity_id):
		hashes[entity_id] = new_hash
		return true  # 新实体，必须发送
	if hashes[entity_id] != new_hash:
		hashes[entity_id] = new_hash
		return true  # 状态变化，需要发送
	return false  # 无变化，跳过

func _is_full_snapshot(snapshot_key) -> bool:
	# 第一次快照一定是全量的（客户端还没有任何实体）
	if not _full_snapshot_counters.has(snapshot_key):
		_full_snapshot_counters[snapshot_key] = 0
		return true
	# 每 FULL_SNAPSHOT_EVERY 次返回 true，触发一次全量快照
	_full_snapshot_counters[snapshot_key] += 1
	if _full_snapshot_counters[snapshot_key] >= FULL_SNAPSHOT_EVERY:
		_full_snapshot_counters[snapshot_key] = 0
		return true
	return false

func _cleanup_dead_entity_hashes(snapshot_key, alive_ids: Dictionary):
	if not _entity_state_hashes.has(snapshot_key):
		return
	var hashes = _entity_state_hashes[snapshot_key]
	var to_erase = []
	for eid in hashes.keys():
		if not alive_ids.has(eid):
			to_erase.append(eid)
	for eid in to_erase:
		hashes.erase(eid)

func _update_gather_stats(delta: float):
	_gather_stat_timer -= delta
	_income_calc_timer -= delta

	if _gather_stat_timer <= 0:
		_gather_stat_timer = 1.0
		var keys_to_track: Array = []
		if game_mode == NetworkManager.GameMode.ONEvONE:
			keys_to_track = [RTSConfig.Team.BLUE, RTSConfig.Team.RED]
		else:
			keys_to_track = player_info.keys()

		for key in keys_to_track:
			var counts = {"gold": 0, "wood": 0, "stone": 0, "food": 0, "oil": 0}
			for entity in entities.get_children():
				if not (entity is Army): continue
				if entity.health <= 0: continue
				if entity.entity_id not in [10, 14]: continue
				if entity.current_order not in ["gather", "deliver"]: continue

				var belongs = false
				if game_mode == NetworkManager.GameMode.ONEvONE:
					belongs = (entity.team == key)
				else:
					belongs = (entity.owner_peer_id == key)
				if not belongs: continue

				var tgt = entity.current_target
				if is_instance_valid(tgt) and tgt is WorldResource:
					var rt = tgt.resource_type
					if rt in counts:
						counts[rt] += 1

			team_gather_counts[key] = counts

		if _income_calc_timer <= 0:
			_income_calc_timer = 10.0
			if game_mode == NetworkManager.GameMode.ONEvONE:
				var team_keys = [
					{"key": RTSConfig.Team.BLUE, "res": player_resources},
					{"key": RTSConfig.Team.RED, "res": enemy_resources},
				]
				for tk in team_keys:
					var key = tk["key"]
					var res = tk["res"]
					if not team_res_snapshots.has(key):
						team_res_snapshots[key] = res.duplicate()
						team_income_rates[key] = {"gold": 0.0, "wood": 0.0, "stone": 0.0, "food": 0.0, "oil": 0.0}
					else:
						var rates = {}
						var prev = team_res_snapshots[key]
						for rk in ["gold", "wood", "stone", "food", "oil"]:
							var cur = res.get(rk, 0)
							var old = prev.get(rk, cur)
							if cur > old:
								rates[rk] = float(cur - old) / 10.0
							else:
								rates[rk] = 0.0
							prev[rk] = cur
						team_income_rates[key] = rates
			else:
				for key in player_info.keys():
					var res = get_resources_for(key)
					if not team_res_snapshots.has(key):
						team_res_snapshots[key] = res.duplicate()
						team_income_rates[key] = {"gold": 0.0, "wood": 0.0, "stone": 0.0, "food": 0.0, "oil": 0.0}
					else:
						var rates = {}
						var prev = team_res_snapshots[key]
						for rk in ["gold", "wood", "stone", "food", "oil"]:
							var cur = res.get(rk, 0)
							var old = prev.get(rk, cur)
							if cur > old:
								rates[rk] = float(cur - old) / 10.0
							else:
								rates[rk] = 0.0
							prev[rk] = cur
						team_income_rates[key] = rates

func _process(delta):
	super._process(delta)    # 始终执行父类更新（迷雾、小地图、资源限制等）
	if not broadcast_enabled: return
	_update_gather_stats(delta)
	snapshot_timer -= delta
	if snapshot_timer <= 0:
		snapshot_timer = SNAPSHOT_INTERVAL
		broadcast_snapshot()

func broadcast_snapshot():
	if game_mode == NetworkManager.GameMode.ONEvONE:
		_broadcast_1v1()
	else:
		_broadcast_2v2()
# 1v1 视野裁剪快照
func build_snapshot_for_team(team: int) -> Dictionary:
	var current_entities = {}
	var delta = []
	var dead = []

	var team_units: Array[GameEntity] = []
	for entity in entities.get_children():
		if entity is GameEntity and entity.team == team and entity.health > 0 and entity.vision_range > 0:
			team_units.append(entity)

	var snapshot_key = "team_%d" % team
	var is_full = _is_full_snapshot(snapshot_key)

	for entity in entities.get_children():
		if not (entity is GameEntity): continue
		if entity.health <= 0: continue
		var snap = _serialize_entity(entity)
		var id = snap["id"]
		current_entities[id] = snap

		# 增量压缩：只发送变化的实体
		if not is_full:
			var h = _compute_entity_hash(entity)
			if not _should_include_in_delta(snapshot_key, id, h):
				continue


		if entity.team == team:
			delta.append(snap)
			continue

		if entity is WorldResource:
			if not team_explored_resources.has(team):
				team_explored_resources[team] = {}
			if team_explored_resources[team].has(id):
				delta.append(snap)
				continue
			var visible = false
			for unit in team_units:
				if unit.global_position.distance_to(entity.global_position) <= unit.vision_range:
					visible = true
					break
			if visible:
				delta.append(snap)
				team_explored_resources[team][id] = true
		else:
			var visible = false
			for unit in team_units:
				if unit.global_position.distance_to(entity.global_position) <= unit.vision_range:
					visible = true
					break
			if visible:
				delta.append(snap)


	# 确保已死亡的实体被加入dead_ids
	for entity in entities.get_children():
		if entity is GameEntity and entity.health <= 0:
			dead.append(entity.get_instance_id())

	var last_cache = last_snapshot_cache.get(team, {})
	for id in last_cache.keys():
		if not current_entities.has(id):
			dead.append(id)
	last_snapshot_cache[team] = current_entities

	return {
		"delta": delta,
		"dead_ids": dead,
		"resources": {"player": player_resources, "enemy": enemy_resources},
		"limits": {"player": player_resource_limits, "enemy": enemy_resource_limits},
		"population": {"current": player_pop if team == RTSConfig.Team.BLUE else enemy_pop, "max": player_max_pop if team == RTSConfig.Team.BLUE else enemy_max_pop},
		"nation": team_nations.get(team, -1),
		"enemy_nation": team_nations.get(RTSConfig.Team.RED if team == RTSConfig.Team.BLUE else RTSConfig.Team.BLUE, -1),
		"gather_counts": team_gather_counts.get(team, {"gold":0, "wood":0, "stone":0, "food":0, "oil":0}),
		"income_rate": team_income_rates.get(team, {"gold":0.0, "wood":0.0, "stone":0.0, "food":0.0, "oil":0.0}),
		"alerts": _get_and_clear_alerts(team),
		"game_time": game_time,
	}

func _broadcast_1v1():
	for pid in player_teams.keys():
		var team = player_teams[pid]
		var data = build_snapshot_for_team(team)   # 原有的视野裁剪快照
		# 补充子弹
		var bullets_data = []
		for bullet in get_tree().get_nodes_in_group("bullets"):
			if bullet is Bullet:
				bullets_data.append({"id":bullet.get_instance_id(),"x":bullet.global_position.x,"y":bullet.global_position.y,"z":bullet.global_position.z,"team":bullet.team})
		data["bullets"] = bullets_data
		data["seq"] = snapshot_seq
		snapshot_seq += 1
		var bytes = var_to_bytes(data)
		#print("快照大小: ", bytes.size(), " 字节")
		NetworkManager._client_receive_snapshot.rpc_id(pid, data)
func _serialize_entity(entity: GameEntity) -> Dictionary:
	var data = {
		"id": entity.get_instance_id(),
		"type": entity.entity_type,
		"team": entity.team,
		"name": entity.get_display_name() if entity.has_method("get_display_name") else entity.display_name,
		"level": entity.level,
		"x": entity.global_position.x,
		"y": entity.global_position.y,
		"z": entity.global_position.z,
		"health": entity.health,
		"max_health": entity.max_health,
		"attack": entity.attack,
		"attack_speed": entity.attack_speed,
		"attack_range": entity.attack_range,
		"armor": entity.armor,
		"speed": entity.speed,
		"vision_range": entity.vision_range,
		"target_type": entity.target_type,
		"body_radius": entity.body_radius,
		"damage_radius": entity.damage_radius,
		"entity_id": entity.entity_id,
		"order": entity.current_order if entity.current_order != "" else "idle",
		"hold_position": entity.hold_position,
		"owner_peer_id": entity.owner_peer_id,
		"waypoints": _serialize_waypoints(entity)
	}

	# 建筑额外信息
	if entity is Building:
		data["upgrade_level"] = entity.upgrade_level
		data["max_upgrade_level"] = entity.max_upgrade_level
		data["can_upgrade"] = entity.can_upgrade()
		data["get_upgrade_cost"] = entity.get_upgrade_cost()

		var prods = []
		for prod in entity.production_list:
			var unit_cfg = EntityDatabase.get_config(prod.unit_id)
			var base_cost = unit_cfg.get("cost", {})
			var scaled = {}
			for res in base_cost.keys():
				scaled[res] = int(base_cost[res] * (1.0 + (entity.upgrade_level - 1) * 0.2))
			prods.append({
				"unit_id": prod.unit_id,
				"cooldown": prod.cooldown,
				"queue_limit": prod.queue_limit,
				"current_cost": scaled
			})
		data["production_list"] = prods

		# 建造进度
		if entity.build_timer > 0:
			data["build_timer"] = entity.build_timer
			data["max_build_time"] = entity.max_build_time
		else:
			data["build_timer"] = 0
			data["max_build_time"] = 0

		# Upgrade progress
		if entity.upgrade_timer > 0:
			data["upgrade_timer"] = entity.upgrade_timer
			data["max_upgrade_time"] = entity.max_upgrade_time
		else:
			data["upgrade_timer"] = 0
			data["max_upgrade_time"] = 0

		# 生产进度
		if entity.production_queue.size() > 0:
			data["production_current_unit"] = entity.production_queue[0]
			var cd = entity.get_prod_cooldown(entity.production_queue[0])
			data["production_progress"] = 1.0 - (entity.production_timer / cd) if cd > 0 else 0.0
			data["production_queue_size"] = entity.production_queue.size()
		else:
			data["production_current_unit"] = -1
			data["production_progress"] = 0.0
			data["production_queue_size"] = 0

	return data

func _serialize_waypoints(entity: GameEntity) -> Array:
	var wps = []
	if entity is Army and entity.has_method("get_waypoint_positions"):
		wps = entity.get_waypoint_positions()
	var result = []
	for wp in wps:
		if wp is Dictionary:
			result.append(wp.duplicate())
		else:
			result.append({"x": wp.x, "y": wp.y, "z": wp.z, "is_loop": false})
	return result

func _serialize_castles() -> Dictionary:
	var dict = {}
	for pid in player_castles.keys():
		var castle = player_castles[pid]
		if castle and is_instance_valid(castle):
			dict[pid] = {
				"health": castle.health,
				"max_health": castle.max_health,
				"x": castle.global_position.x,
				"y": castle.global_position.y,
				"z": castle.global_position.z
			}
	return dict
func _broadcast_2v2():
	for pid in player_info.keys():
		if not player_info[pid].alive: continue
		var data = build_snapshot_for_player(pid)
		# 补充子弹（视野裁剪）
		var bullets_data = []
		for bullet in get_tree().get_nodes_in_group("bullets"):
			if bullet is Bullet:
				# 子弹如果不可见就不发送（可选）
				bullets_data.append({
					"id": bullet.get_instance_id(),
					"x": bullet.global_position.x,
					"y": bullet.global_position.y,
					"z": bullet.global_position.z,
					"team": bullet.team
				})
		data["bullets"] = bullets_data
		data["seq"] = snapshot_seq
		snapshot_seq += 1
		var bytes = var_to_bytes(data)
		#print("快照大小: ", bytes.size(), " 字节")
		NetworkManager._client_receive_snapshot.rpc_id(pid, data)

func build_snapshot_for_player(peer_id: int) -> Dictionary:
	var team = player_info[peer_id].team
	var team_units: Array[GameEntity] = []
	for entity in entities.get_children():
		if entity is GameEntity and entity.team == team and entity.health > 0 and entity.vision_range > 0:
			team_units.append(entity)

	var delta = []
	var snapshot_key = "player_%d" % peer_id
	var is_full = _is_full_snapshot(snapshot_key)
	for entity in entities.get_children():
		if not (entity is GameEntity): continue
		if entity.health <= 0: continue
		var snap = _serialize_entity(entity)
		var id = snap["id"]

		# 增量压缩：只发送变化的实体
		if not is_full:
			var h = _compute_entity_hash(entity)
			if not _should_include_in_delta(snapshot_key, id, h):
				continue


		if snap.get("owner_peer_id", -1) == peer_id:
			delta.append(snap)
			continue

		if entity is WorldResource:
			if not team_explored_resources.has(team):
				team_explored_resources[team] = {}
			if team_explored_resources[team].has(id):
				delta.append(snap)
				continue
			var visible = false
			for unit in team_units:
				if unit.global_position.distance_to(entity.global_position) <= unit.vision_range:
					visible = true
					break
			if visible:
				delta.append(snap)
				team_explored_resources[team][id] = true
		else:
			var visible = false
			for unit in team_units:
				if unit.global_position.distance_to(entity.global_position) <= unit.vision_range:
					visible = true
					break
			if visible:
				delta.append(snap)

	var current_all_ids = {}
	for entity in entities.get_children():
		if entity is GameEntity:
			current_all_ids[entity.get_instance_id()] = true

	var last_ids = player_last_snapshot_ids.get(peer_id, [])
	var dead = []
	for lid in last_ids:
		if not current_all_ids.has(lid):
			dead.append(lid)

	player_last_snapshot_ids[peer_id] = []
	for snap in delta:
		player_last_snapshot_ids[peer_id].append(snap["id"])

	return {
		"delta": delta,
		"dead_ids": dead,
		"player_resources": { peer_id: player_resources[peer_id] },
		"player_limits": { peer_id: player_limits_dict.get(peer_id, {}) },
		"player_population": { peer_id: player_population[peer_id] },
		"player_castles": _serialize_castles(),
		"team_nations": team_nations,
		"gather_counts": {peer_id: team_gather_counts.get(peer_id, {"gold":0, "wood":0, "stone":0, "food":0, "oil":0})},
		"income_rate": {peer_id: team_income_rates.get(peer_id, {"gold":0.0, "wood":0.0, "stone":0.0, "food":0.0, "oil":0.0})},
		"player_info": player_info,
		"alerts": _get_and_clear_alerts(peer_id)
	}

func _1v1_set_group(team: int, data: Dictionary):
	var sel = selection as SelectionManager
	if not sel: return
	var g = data.get("group", 0)
	var ids = data.get("selected_ids", [])
	# Populate selection from client's selected_ids
	sel.selected_entities.clear()
	for e in entities.get_children():
		if e is GameEntity and e.team == team and e.get_instance_id() in ids:
			sel.selected_entities.append(e)
	if g == 0:
		sel._clear_control_groups_for_selected()
		print("[Server] Cleared groups for team ", team)
	else:
		sel._set_control_group(g)
		print("[Server] Set group ", g, " with ", sel.selected_entities.size(), " units")

func _1v1_demolish(team: int, data: Dictionary):
	var building_id = data.get("building_id", -1)
	if building_id == -1: return
	for e in entities.get_children():
		if e is Building and e.get_instance_id() == building_id and e.team == team and e.entity_id != 20:
			var base_cfg = EntityDatabase.get_config(e.entity_id)
			if not base_cfg.is_empty():
				var cost = base_cfg.get("cost", {})
				var res_dict = player_resources if team == RTSConfig.Team.BLUE else enemy_resources
				for res in cost:
					res_dict[res] += int(cost[res] * 0.5)
			e.queue_free()
			update_resource_limits(team)
			update_population_limits()
			return

func _clear_garrison_for_team(team: int, _data: Dictionary):
	for eid in _data.get("selected_ids", []):
		for e in entities.get_children():
			if e.get_instance_id() == eid and e.team == team:
				if e is Army and e.has_method("_clear_garrison"):
					e._clear_garrison()
				elif e is Building:
					e.garrison_point = Vector3.ZERO

func _set_garrison_for_team(team: int, data: Dictionary):
	var pos = Vector3(data.get("pos_x", 0), data.get("pos_y", 0), data.get("pos_z", 0))
	for eid in data.get("selected_ids", []):
		for e in entities.get_children():
			if e.get_instance_id() == eid and e.team == team:
				if e is Army and e.has_method("_is_military") and e._is_military():
					e.set_garrison(pos)
				elif e is Building:
					e.garrison_point = pos

func _2v2_demolish(peer_id: int, data: Dictionary):
	var building_id = data.get("building_id", -1)
	if building_id == -1: return
	for e in entities.get_children():
		if e is Building and e.get_instance_id() == building_id and e.owner_peer_id == peer_id and e.entity_id != 20:
			var base_cfg = EntityDatabase.get_config(e.entity_id)
			if not base_cfg.is_empty():
				var cost = base_cfg.get("cost", {})
				for res in cost:
					add_player_resource(peer_id, res, int(cost[res] * 0.5))
			e.queue_free()
			update_player_limits(peer_id)
			return

func _2v2_clear_garrison(peer_id: int, _data: Dictionary):
	for eid in _data.get("selected_ids", []):
		for e in entities.get_children():
			if e.get_instance_id() == eid and e.owner_peer_id == peer_id:
				if e is Army and e.has_method("_clear_garrison"):
					e._clear_garrison()
				elif e is Building:
					e.garrison_point = Vector3.ZERO

func _2v2_set_garrison(peer_id: int, data: Dictionary):
	var pos = Vector3(data.get("pos_x", 0), data.get("pos_y", 0), data.get("pos_z", 0))
	for eid in data.get("selected_ids", []):
		for e in entities.get_children():
			if e.get_instance_id() == eid and e.owner_peer_id == peer_id:
				if e is Army and e.has_method("_is_military") and e._is_military():
					e.set_garrison(pos)
				elif e is Building:
					e.garrison_point = pos

func _1v1_recall_group(_t: int, data: Dictionary):
	var sel = selection as SelectionManager
	if sel:
		sel._recall_control_group(data.get("group", 0))
		print("[Server] Recalled group ", data.get("group", 0), " selected ", sel.selected_entities.size(), " units")

func _2v2_set_group(peer_id: int, data: Dictionary):
	var sel = selection as SelectionManager
	if not sel: return
	var ids = data.get("selected_ids", [])
	sel.selected_entities.clear()
	for e in entities.get_children():
		if e is Army and e.owner_peer_id == peer_id and e.get_instance_id() in ids:
			sel.selected_entities.append(e)
	var g = data.get("group", 0)
	if g == 0:
		sel._clear_control_groups_for_selected()
		print("[Server] Peer ", peer_id, " cleared groups")
	else:
		sel._set_control_group(g)
		print("[Server] Peer ", peer_id, " set group ", g, " with ", sel.selected_entities.size(), " units")

func _2v2_recall_group(_peer_id: int, data: Dictionary):
	var sel = selection as SelectionManager
	if sel:
		sel._recall_control_group(data.get("group", 0))
		print("[Server] Team ", _peer_id, " recalled group ", data.get("group", 0), " selected ", sel.selected_entities.size(), " units")

func get_gather_paused(team: int) -> bool:
	return team_gather_paused.get(team, false)

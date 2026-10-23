class_name OnlineBattleManager
extends RTSBattleManager

# ==================== 模式与玩家管理 ====================
var game_mode: int = NetworkManager.GameMode.ONEvONE

# Compact entity array indices (no string keys = faster + smaller)
enum E { ID=0, EID, TYPE, TEAM, X, Y, Z, HEALTH, MAX_HEALTH, ATTACK, ATTACK_SPEED, MELEE_ARMOR, SHIELD_ARMOR, SPEED, VISION, BODY_R, TARGET_TYPE, OWNER, LEVEL, ORDER, HOLD, NAME, ENTITY_ID, WAYPOINTS, ROT_Y, ASTAR_PATH, GARRISONED }
enum EB { UPGRADE=0, MAX_UPGRADE, CAN_UPGRADE, BUILD_TIMER, MAX_BUILD, PROD_CURRENT, PROD_PROGRESS, PROD_QSIZE, UPGRADE_TIMER, MAX_UPGRADE_TIME, GARRISON_COUNT }
const SNAP_VERSION = 4  # 4 = added GARRISONED (Army) + GARRISON_COUNT (Building)

# 1v1 专用
var player_teams: Dictionary = {}         # peer_id -> team
var auto_attack_teams: Dictionary = {}    # 1v1: team -> bool
var auto_attack_peers: Dictionary = {}    # 2v2/3v3: peer_id -> bool

# 2v2 专用
var player_info: Dictionary = {}          # peer_id -> { "team": int, "slot": int, "alive": bool, "color": Color, "nation": int }
var player_castles: Dictionary = {}       # peer_id -> Building
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
const SNAPSHOT_INTERVAL: float = 0.04
var broadcast_enabled: bool = false
var _snap_sent: int = 0
var _snap_sent_rate: int = 0
var _snap_sent_timer: float = 0.0
var last_snapshot_cache: Dictionary = {}
var team_explored_resources: Dictionary = {}
var team_gather_paused: Dictionary = {}
var _mp_shift_held: bool = false
var _bullet_cache: Array = []       # cached bullet list, refreshed once per snap

# ==================== 警报系统（服务器→客户端） ====================
var _pending_client_alerts: Dictionary = {}   # peer_id or team -> Array of {msg, color}

func _queue_client_alert(target_key, msg: String, color: Color = Color(1.0, 0.2, 0.1)):
	if not _pending_client_alerts.has(target_key):
		_pending_client_alerts[target_key] = []
	_pending_client_alerts[target_key].append({"msg": msg, "color": color})

func _get_and_clear_alerts(target_key) -> Array:
	var alerts = _pending_client_alerts.get(target_key, [])
	_pending_client_alerts[target_key] = []
	return alerts

# Override: queue alerts for clients in online mode
func _show_hud_alert(msg: String, color: Color = Color(1.0, 0.2, 0.1), _target_team: int = -1):
	if _target_team < 0:
		# 全局警报（城堡被毁、游戏结束等）：双方都发，房主本地也显示
		super._show_hud_alert(msg, color)
		_queue_client_alert(RTSConfig.Team.BLUE, msg, color)
		_queue_client_alert(RTSConfig.Team.RED, msg, color)
	else:
		# 阵营事件：只发给该阵营；房主仅在本方阵营事件时本地显示，避免看到敌方播报
		if _target_team == _host_player_team():
			super._show_hud_alert(msg, color)
		_queue_client_alert(_target_team, msg, color)

# 房主（peer 1）所在队伍：用于过滤服务器本地 HUD 上的播报
func _host_player_team() -> int:
	if player_info.has(1):
		return int(player_info[1].team)
	if player_teams.has(1):
		return int(player_teams[1])
	return RTSConfig.Team.BLUE

# 统计面板：联机本地玩家是房主 peer 1
func get_local_owner_id() -> int:
	return 1

func get_local_team() -> int:
	return _host_player_team()

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

# HUD/建造 桥接：在线模式返回房主(peer_id=1)数据
func get_host_resources() -> Dictionary:
	return player_resources.get(1, {"gold":0, "wood":0, "stone":0, "food":0, "oil":0})
func get_host_pop() -> int:
	return player_population.get(1, {}).get("current", 0)
func get_host_max_pop() -> int:
	return player_population.get(1, {}).get("max", 20)
func get_host_limits() -> Dictionary:
	return player_limits_dict.get(1, {"gold":500, "wood":500, "stone":500, "food":500, "oil":0})
func get_host_team() -> int:
	if player_info.has(1): return player_info[1].team
	if player_teams.has(1): return player_teams[1]
	return RTSConfig.Team.BLUE

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
	for entity in get_tree().get_nodes_in_group("storage_buildings"):
		if entity.health > 0 and entity.owner_peer_id == peer_id and entity.team == player_info[peer_id].team:
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
	var mult = 1.0
	if player_info.get(peer_id, {}).get("is_ai", false):
		var pinfo = player_info.get(peer_id, {})
		var diff = GameSettings.red_ai_difficulty if pinfo.get("team", -1) == RTSConfig.Team.RED else GameSettings.blue_ai_difficulty
		if diff == GameSettings.AIDifficulty.NORMAL: mult = 2.0
		elif diff >= GameSettings.AIDifficulty.HARD: mult = 3.0
	for type in cargo:
		add_player_resource(peer_id, type, int(cargo[type] * mult))

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
		player_population[peer_id] = {"current": 0, "max": 20}
	var max_pop = 0
	var info = player_info[peer_id]
	for entity in get_tree().get_nodes_in_group("pop_buildings"):
		if entity.owner_peer_id == peer_id and entity.health > 0:
			if entity.entity_id == 20: max_pop += 20
			elif entity.entity_id == 28: max_pop += 10
	if info:
		max_pop += NationBonuses.get_population_bonus(int(info.get("nation", team_nations.get(info.team, -1))))
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
		await _init_team_mode()

# ---------- 1v1 初始化 ----------
func _init_1v1():
	# 等待所需数量的远程客户端（max_players 已减去 AI）
	var needed = maxi(0, NetworkManager.max_players - 1)
	while multiplayer.get_peers().size() < needed:
		await get_tree().process_frame

	var peers = multiplayer.get_peers()
	peers.sort()
	# 房主 (peer_id=1) → BLUE
	player_teams[1] = RTSConfig.Team.BLUE
	player_info[1] = {"team": RTSConfig.Team.BLUE, "slot": 0, "alive": true, "is_ai": false}
	player_resources[1] = {"gold":100, "wood":100, "stone":100, "food":100, "oil":0}
	player_population[1] = {"current": 3, "max": 20}
	if NetworkManager.pending_nations.has(1):
		pending_nations[1] = NetworkManager.pending_nations[1]
	if pending_nations.has(1):
		team_nations[RTSConfig.Team.BLUE] = pending_nations[1]
		pending_nations.erase(1)
	else:
		team_nations[RTSConfig.Team.BLUE] = GameSettings.player_nation
	# 远程客户端 → RED
	for i in range(peers.size()):
		var team = RTSConfig.Team.RED
		player_teams[peers[i]] = team
		if NetworkManager.pending_nations.has(peers[i]):
			pending_nations[peers[i]] = NetworkManager.pending_nations[peers[i]]
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
	# 修正 owner_peer_id（包含房主 peer_id=1）
	for pid in player_teams.keys():
		var team = player_teams[pid]
		var castle = get_castle_by_team(team)
		if castle: castle.owner_peer_id = pid
	_player_colors.clear()
	for pid in player_teams.keys():
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

# ---------- 组队模式初始化（2v2 / 3v3 共用） ----------
func _init_team_mode():

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
	print("[服务器] 组队地图已重建，尺寸:", RTSConfig.MAP_SIZE, " 地形网格大小:", map_node.terrain_grid.size())
	# 计算所需人类玩家数量

	var team_size = NetworkManager.get_team_size()
	var red_slots_free = team_size - NetworkManager.red_ai_count
	var blue_slots_free = team_size - NetworkManager.blue_ai_count
	var required_humans = red_slots_free + blue_slots_free
	var required_remote = maxi(0, required_humans - 1)  # 减去房主

	print("[组队] 需要人类玩家数:", required_humans, " 远程:", required_remote)

	# 等待足够的人类玩家连接
	while multiplayer.get_peers().size() < required_remote:
		await get_tree().process_frame

	var peers = multiplayer.get_peers()
	peers.sort()

	var red_assigned = 0
	var blue_assigned = 0

	# ---------- 房主 (peer_id=1) 分配 ----------
	var host_team = RTSConfig.Team.RED if red_slots_free > 0 else RTSConfig.Team.BLUE
	player_info[1] = {
		"team": host_team, "slot": 0, "alive": true,
		"color": _pick_player_color(host_team, 0),
		"nation": NetworkManager.pending_nations.get(1, GameSettings.player_nation),
		"is_ai": false,
	}
	player_resources[1] = {"gold":100, "wood":100, "stone":100, "food":100, "oil":0}
	player_population[1] = {"current": 3, "max": 20}
	if host_team == RTSConfig.Team.RED: red_assigned += 1
	else: blue_assigned += 1
	print("[组队] 房主 peer_id=1 队伍", "红" if host_team == RTSConfig.Team.RED else "蓝")

	# ---------- 分配远程人类玩家 ----------
	for i in range(peers.size()):
		var team: int
		if red_assigned < red_slots_free and (red_assigned <= blue_assigned or blue_assigned >= blue_slots_free):
			team = RTSConfig.Team.RED
		else:
			team = RTSConfig.Team.BLUE

		var slot = red_assigned if team == RTSConfig.Team.RED else blue_assigned
		var color = _pick_player_color(team, slot)   # 与队友同色系，按槽位区分明度
		var nation = pending_nations.get(peers[i], 0)

		player_info[peers[i]] = {
			"team": team, "slot": slot, "alive": true,
			"color": color, "nation": nation,
			"is_ai": false,
		}
		player_resources[peers[i]] = { "gold": 100, "wood": 100, "stone": 100, "food": 100, "oil": 0 }
		player_population[peers[i]] = { "current": 3, "max": 20 }

		if team == RTSConfig.Team.RED:
			red_assigned += 1
		else:
			blue_assigned += 1

		print("[组队] 分配人类 ", peers[i], " 到队伍 ", "红" if team == RTSConfig.Team.RED else "蓝", " 槽位", slot)

	# ---------- 补充 AI 玩家（完全按照菜单设置的数量） ----------
	# 红方 AI
	for i in range(NetworkManager.red_ai_count):
		if red_assigned >= team_size: break   # 保险
		var ai_id = _generate_ai_id(RTSConfig.Team.RED, red_assigned)
		_create_ai_player(ai_id, RTSConfig.Team.RED, red_assigned)
		red_assigned += 1
		print("[组队] 添加红方AI, peer_id=", ai_id, " slot=", red_assigned-1)

	# 蓝方 AI
	for i in range(NetworkManager.blue_ai_count):
		if blue_assigned >= team_size: break
		var ai_id = _generate_ai_id(RTSConfig.Team.BLUE, blue_assigned)
		_create_ai_player(ai_id, RTSConfig.Team.BLUE, blue_assigned)
		blue_assigned += 1
		print("[组队] 添加蓝方AI, peer_id=", ai_id, " slot=", blue_assigned-1)

	print("[组队] 最终分配: 红方", red_assigned, "人, 蓝方", blue_assigned, "人")

	# 广播颜色、地图、队伍信息等（保持不变）
	var all_player_colors = {}
	for pid in player_info.keys():
		all_player_colors[pid] = player_info[pid].color
	_player_colors.clear()
	for pid in player_info.keys():
		_player_colors[pid] = player_info[pid].color
	for pid in player_info.keys():
		NetworkManager.notify_all_player_colors.rpc_id(pid, all_player_colors)

	# 只向真实客户端发送（跳过AI合成peer_id）
	var real_pids: Array = []
	for pid in player_info.keys():
		if not player_info[pid].is_ai:
			real_pids.append(pid)
	_send_map_data(real_pids)
	for pid in real_pids:
		var info = player_info[pid]
		NetworkManager.notify_team_info.rpc_id(pid, pid, info.team, info.slot, info.color)

	has_game_started = true
	

	_init_all_castles_team()
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

# 每个 AI 独立随机国家，排除玩家国家并尽量不重复
func _pick_ai_nation() -> int:
	var used: Dictionary = {}
	for info in player_info.values():
		used[int(info.get("nation", -1))] = true
	for pid in pending_nations.keys():
		used[int(pending_nations[pid])] = true
	var pool: Array = []
	for n in range(RTSConfig.Nation.size()):
		if n != GameSettings.player_nation and not used.has(n):
			pool.append(n)
	if pool.is_empty():
		for n in range(RTSConfig.Nation.size()):
			if n != GameSettings.player_nation:
				pool.append(n)
	return pool[randi() % pool.size()]

func _create_ai_player(peer_id: int, team: int, slot: int):
	var ai_nation = _pick_ai_nation()
	player_info[peer_id] = {
		"team": team,
		"slot": slot,
		"alive": true,
		"is_ai": true,
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
# 玩家/AI 颜色统一按队伍色系分配（蓝队蓝色系、红队红色系，槽位只影响明暗），
# 避免同队出现一红一蓝的血条与单位颜色
func _pick_player_color(team: int, slot: int) -> Color:
	return RTSConfig.get_team_member_color(team, slot, NetworkManager.get_team_size())

func _get_ai_color(team: int, slot: int) -> Color:
	return RTSConfig.get_team_member_color(team, slot, NetworkManager.get_team_size())
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
	var height_copy = $Map.height_grid.duplicate(true)
	var res_data = []
	for r in $Map.resource_positions:
		res_data.append({
			"x": r["pos"].x, "y": r["pos"].y, "z": r["pos"].z,
			"type": r["type"]
		})
	for pid in peers:
		NetworkManager.receive_map_data.rpc_id(pid, terrain_copy, height_copy, res_data)

# ---------- 组队模式城堡生成（2v2 / 3v3 共用） ----------
func _init_all_castles_team():
	_debug_print_colors()
	var map = $Map
	if not map: return

	var team_size = NetworkManager.get_team_size()
	# 2v2: [blue1, blue2, red1, red2]；3v3: [blue1, blue2, blue3, red1, red2, red3]
	var positions: Array
	if team_size == 3:
		positions = map.get_six_castle_positions()
	else:
		positions = map.get_four_castle_positions()

	# 给每位玩家分配城堡
	for pid in player_info.keys():
		var info = player_info[pid]
		var pos: Vector3
		if info.team == RTSConfig.Team.BLUE:
			pos = positions[info.slot]
		else:
			pos = positions[team_size + info.slot]

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
		castle.died.connect(_on_castle_died_team.bind(peer_id))
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
					entity._movement.astar_path.clear()
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
	# 服务端兜底：剔除任何不属于该玩家的选中实体，禁止操控队友单位
	if data.has("selected_ids"):
		data["selected_ids"] = _owned_selected_ids(peer_id, data["selected_ids"])
	if game_mode == NetworkManager.GameMode.ONEvONE:
		_process_1v1_command(peer_id, data)
	else:
		_process_2v2_command(peer_id, data)

func _owned_selected_ids(peer_id: int, ids: Array) -> Array:
	var team = player_teams.get(peer_id, -1)
	if player_info.has(peer_id):
		team = player_info[peer_id].team
	var out: Array = []
	for id in ids:
		var e = _find_entity_by_id(id)
		if not e: continue
		if game_mode == NetworkManager.GameMode.ONEvONE:
			if e.team == team: out.append(id)
		elif e.owner_peer_id == peer_id:
			out.append(id)
	return out

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
		"ungarrison_soldiers": _ungarrison_soldiers_1v1(team, data)
		"toggle_auto_attack": _1v1_set_auto_attack(team, bool(data.get("enabled", false)))

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
		"ungarrison_soldiers": _ungarrison_soldiers_2v2(peer_id, data)
		"toggle_auto_attack": _2v2_set_auto_attack(peer_id, bool(data.get("enabled", false)))

# ---------- 1v1 命令实现 ----------
func _1v1_right_click(team: int, data: Dictionary):
	#print("[Server] right_click from team ", team, " targets: ", data.get("selected_ids", []).size(), " pos: ", data.get("pos_x", 0))
	var target_id = data.get("target_id", -1)
	var pos = Vector3(data.get("pos_x",0), data.get("pos_y",0), data.get("pos_z",0))
	var selected_ids = data.get("selected_ids", [])
	var shift_held = data.get("shift_held", false)
	var target: GameEntity = _find_entity_by_id(target_id) if target_id != -1 else null
	var offsets = data.get("formation_offsets", [])

	var fi = 0
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
					# 攻击过滤：不可攻击目标（如桥）改为移动
					if entity.has_method("_can_attack_target") and entity._can_attack_target(target):
						entity.attack_target(target)
					else:
						entity.move_to(target.global_position)
				elif entity.entity_id >= 46 and entity.entity_id <= 50 and target is Building:
					entity._garrison_target_id = target.get_instance_id()
					entity.move_to(target.global_position)
				elif entity.has_method("can_soldier_garrison") and entity.can_soldier_garrison(target):
					entity._garrison_target_id = target.get_instance_id()
					entity.move_to(target.global_position)
				else:
					entity.move_to(target.global_position)
			else:
				# 点到空地：移动到目标坐标（多单位按编队偏移散开）
				var fp = pos
				if offsets.size() > fi:
					var off = offsets[fi]
					fp = pos + Vector3(off.x, off.y, off.z)
				entity.move_to(fp)
			fi += 1

func _1v1_build(team: int, data: Dictionary):
	var building_id = data["building_id"]
	var pos = Vector3(data["pos_x"], data["pos_y"], data["pos_z"])
	var cfg = EntityDatabase.get_config(building_id)
	if cfg.is_empty(): return
	if not is_building_unlocked(building_id): return
	# 桥：必须邻接陆地或已建成的桥，且不能与其他实体重叠
	if building_id == 7 and not is_valid_bridge_position(pos): return
	# Cannot build near enemies
	for e in entities.get_children():
		if e is GameEntity and e.team != team and e.team != RTSConfig.Team.NEUTRAL and e.health > 0:
			if e.global_position.distance_to(pos) < 10.0: return
	var res = get_resources_for(1) if team == RTSConfig.Team.BLUE else enemy_resources
	var cost = cfg.get("cost", {})
	for r in cost.keys():
		if res[r] < cost[r]: return

	for r in cost.keys():
		res[r] -= cost[r]
	if building_id == 64:
		for e in entities.get_children():
			if e is Building and e.entity_id == 27 and e.team == team and e.health > 0:
				if Vector2(e.global_position.x - pos.x, e.global_position.z - pos.z).length() < (e.body_radius + 1.0):
					pos.y = e.global_position.y + 4.0
					break
	var b = spawn_entity(cfg, team, pos)
	if b:
		b.start_construction(5.0, cfg)

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
	var offsets = data.get("formation_offsets", [])

	var fi = 0
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
					# 攻击过滤：不可攻击目标（如桥）改为移动
					if entity.has_method("_can_attack_target") and entity._can_attack_target(target):
						entity.attack_target(target)
					else:
						entity.move_to(target.global_position)
				elif entity.entity_id >= 46 and entity.entity_id <= 50 and target is Building:
					entity._garrison_target_id = target.get_instance_id()
					entity.move_to(target.global_position)
				elif entity.has_method("can_soldier_garrison") and entity.can_soldier_garrison(target):
					entity._garrison_target_id = target.get_instance_id()
					entity.move_to(target.global_position)
				else:
					entity.move_to(target.global_position)
			else:
				# 点到空地：移动到目标坐标（多单位按编队偏移散开）
				var fp = pos
				if offsets.size() > fi:
					var off = offsets[fi]
					fp = pos + Vector3(off.x, off.y, off.z)
				entity.move_to(fp)
			fi += 1

func _2v2_build(peer_id: int, data: Dictionary):
	
	
	var building_id = data["building_id"]
	var pos = Vector3(data["pos_x"], data["pos_y"], data["pos_z"])
	var cfg = EntityDatabase.get_config(building_id)
	if cfg.is_empty(): return
	var req_lv = get_building_required_castle_level(building_id)
	if req_lv > 1:
			var castle = player_castles.get(peer_id)
			if not castle or castle.upgrade_level < req_lv: return
	var cost = cfg.get("cost", {})
	# Cannot build near enemies
	for e in entities.get_children():
		if e is GameEntity and e.team != player_info[peer_id].team and e.team != RTSConfig.Team.NEUTRAL and e.health > 0:
			if e.global_position.distance_to(pos) < 10.0: return
	# 桥：必须邻接陆地或已建成的桥，且不能与其他实体重叠
	if building_id == 7 and not is_valid_bridge_position(pos): return
	# 人口检查（防御塔）
	var is_defense = (building_id == 25 or building_id == 26)
	if is_defense and not can_player_train(peer_id):
		return

	# 扣除个人资源
	if not deduct_player_resources(peer_id, cost): return
	cfg["owner_peer_id"] = peer_id
	if building_id == 64:
		for e in entities.get_children():
			if e is Building and e.entity_id == 27 and e.team == player_info[peer_id].team and e.health > 0:
				if Vector2(e.global_position.x - pos.x, e.global_position.z - pos.z).length() < (e.body_radius + 1.0):
					pos.y = e.global_position.y + 4.0
					break
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
				entity._movement.astar_path.clear()
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

# ==================== 自动进攻开关（服务端权威） ====================
func _is_auto_attack_enabled_for(owner: int, team: int) -> bool:
	if game_mode == NetworkManager.GameMode.ONEvONE:
		return auto_attack_teams.get(team, false)
	if owner != -1:
		return auto_attack_peers.get(owner, false)
	return auto_attack_teams.get(team, false)

func _get_auto_attack_target(_owner: int, team: int) -> Building:
	var enemy_team = RTSConfig.Team.RED if team == RTSConfig.Team.BLUE else RTSConfig.Team.BLUE
	return _get_first_alive_castle(enemy_team)

func _1v1_set_auto_attack(team: int, enabled: bool) -> void:
	auto_attack_teams[team] = enabled
	var target = _get_auto_attack_target(-1, team)
	for entity in entities.get_children():
		if not (entity is Army) or entity.team != team or entity.health <= 0: continue
		if not entity._is_military() or entity.entity_id in AUTO_ATTACK_EXCLUDE_IDS: continue
		if enabled:
			if entity.current_target != null: continue
			if target:
				entity._clear_command_queue()
				entity.attack_move_to(target.global_position)
		else:
			if _has_attack_move_order(entity) and entity.current_target == null:
				entity.stop_movement()
				entity._clear_command_queue()

func _2v2_set_auto_attack(peer_id: int, enabled: bool) -> void:
	auto_attack_peers[peer_id] = enabled
	if not player_info.has(peer_id): return
	var team = player_info[peer_id].team
	var target = _get_auto_attack_target(peer_id, team)
	for entity in entities.get_children():
		if not (entity is Army) or entity.get("owner_peer_id") != peer_id or entity.health <= 0: continue
		if not entity._is_military() or entity.entity_id in AUTO_ATTACK_EXCLUDE_IDS: continue
		if enabled:
			if entity.current_target != null: continue
			if target:
				entity._clear_command_queue()
				entity.attack_move_to(target.global_position)
		else:
			if _has_attack_move_order(entity) and entity.current_target == null:
				entity.stop_movement()
				entity._clear_command_queue()

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

	# 1v1 联机：重写父类 _on_castle_died，发送RPC通知客户端
func _on_castle_died(team: int):
	if game_over: return
	game_over = true
	var winner = RTSConfig.Team.BLUE if team == RTSConfig.Team.RED else RTSConfig.Team.RED
	print("[GameOver-1v1] Castle died: team=%d, winner=%d, notifying..." % [team, winner])
	_show_host_game_over(winner)
	for pid in multiplayer.get_peers():
		NetworkManager.notify_game_over.rpc_id(pid, winner)

# 房主也是玩家：RPC 只发给远程客户端，本地必须自己显示结算面板
func _show_host_game_over(winner_team: int) -> void:
	var host_team := RTSConfig.Team.BLUE
	if player_info.has(1):
		host_team = player_info[1].team
	elif player_teams.has(1):
		host_team = player_teams[1]
	var host_won := winner_team == host_team
	AudioManager.play_music("victory" if host_won else "defeat")
	if game_over_label:
		game_over_label.text = "你赢了！" if host_won else "你输了！"
		game_over_label.add_theme_color_override("font_color", Color.GREEN if host_won else Color.RED)
	if game_over_panel:
		game_over_panel.visible = true

func _on_castle_died_team(peer_id: int):
	if not player_info.has(peer_id): return
	player_info[peer_id].alive = false
	var team = player_info[peer_id].team
	print("[GameOver-组队] Castle died: peer=%d team=%d, checking team..." % [peer_id, team])
	var _alive_count = 0
	for _pid in player_info.keys():
		if player_info[_pid].team == team and player_info[_pid].alive:
			_alive_count += 1
	print("[GameOver-组队] Team %d alive players: %d" % [team, _alive_count])

	# 整队检查
	for pid in player_info.keys():
		if player_info[pid].team == team and player_info[pid].alive:
			return   # 还有存活，不结束
	# 全队阵亡
	game_over = true
	print("[GameOver-组队] GAME OVER! Winner team=%d, notifying players..." % [RTSConfig.Team.BLUE if team == RTSConfig.Team.RED else RTSConfig.Team.RED])
	var winner = RTSConfig.Team.BLUE if team == RTSConfig.Team.RED else RTSConfig.Team.RED
	_show_host_game_over(winner)
	for pid in player_info.keys():
		if pid >= 1000 or pid == 1: continue   # 跳过 AI 与房主（房主已本地结算）
		NetworkManager.notify_game_over.rpc_id(pid, winner)

# 1v1 的城堡死亡已在 RTSBattleManager 中通过 _on_castle_died 处理（游戏结束通知玩家）

# ---------- 快照广播 ----------

# ==================== 增量快照（Delta Compression） ====================
# 每个玩家的实体状态哈希表，只发送变化的实体，大幅减少网络流量
var _entity_state_hashes: Dictionary = {}   # key -> {entity_id: hash}
var _full_snapshot_counters: Dictionary = {} # key -> counter
const FULL_SNAPSHOT_EVERY: int = 30          # 每 30 个 delta (~3秒) 发一次全量基线

# 快照走 unreliable 通道（见 NetworkManager._client_receive_snapshot），丢包不会重传。
# 只发一次的"死亡 ID"和"状态变化"一旦丢包，客户端就会永久停留在错误状态
# （残留尸体 / 建造进度条走到底却仍显示"建造中"），所以这里做有限次重发兜底。
const FORCE_RESEND_EVERY: int = 25           # 每个实体至少每 25 次广播(~1秒)重发一次
const DEAD_ID_RESEND_SNAPSHOTS: int = 50     # 死亡 ID 在 ~2 秒内每次广播都重发
const DEAD_ID_MAX: int = 64                  # 单次快照最多携带的死亡 ID 数
var _snap_tick: int = 0                      # 单调递增的广播序号（_snap_sent 每秒会清零，不能当钟用）
var _entity_last_sent: Dictionary = {}       # key -> {entity_id: 最后一次发送时的广播序号}
var _recent_dead_ids: Dictionary = {}        # key -> {entity_id: 过期广播序号}
# 建造/升级完工后的"粘性重发"：完工只产生一次状态变化，丢包会让进度条永久卡住
var _build_phase: Dictionary = {}            # entity_id -> {build: bool, upgrade: bool}
var _sticky_resend_until: Dictionary = {}    # entity_id -> 过期广播序号
const STICKY_RESEND_TICKS: int = 25          # 完工后 ~2.5 秒内每次广播都重发

# ==================== 快照视野网格（复用，仅分配一次） ====================
var _snap_vis_grid: PackedByteArray = []  # flat byte grid (contiguous memory, faster)
var _snap_vis_version: int = 0       # monotonically increasing version counter
var _vis_offsets: Dictionary = {}    # vision_range -> PackedVector2Array (precomputed circle offsets)

func _get_vis_offsets(r: int) -> PackedVector2Array:
	if _vis_offsets.has(r):
		return _vis_offsets[r]
	var arr = PackedVector2Array()
	for dx in range(-r, r + 1):
		for dy in range(-r, r + 1):
			if dx * dx + dy * dy <= r * r:
				arr.append(Vector2(dx, dy))
	_vis_offsets[r] = arr
	return arr

func _init_snap_vis_grid():
	var ms = RTSConfig.MAP_SIZE
	var total = ms * ms
	_snap_vis_grid.resize(total)
	var fill_bytes = PackedByteArray()
	fill_bytes.resize(total)
	_snap_vis_grid = fill_bytes

func _compute_entity_hash(entity: GameEntity) -> int:
	# Integer-only hash — avoids string allocation and .hash() call
	var h: int = int(entity.global_position.x * 100)
	h = ((h << 5) ^ (h >> 27)) ^ int(entity.global_position.z * 100)
	h = ((h << 5) ^ (h >> 27)) ^ int(entity.health)
	h = ((h << 5) ^ (h >> 27)) ^ int(entity.max_health)
	h = ((h << 5) ^ (h >> 27)) ^ entity.level
	h = ((h << 5) ^ (h >> 27)) ^ int(entity.attack)
	h = ((h << 5) ^ (h >> 27)) ^ hash(entity.current_order)
	h = ((h << 5) ^ (h >> 27)) ^ (1 if entity.hold_position else 0)
	h = ((h << 5) ^ (h >> 27)) ^ int(entity.owner_peer_id)
	if entity is Building:
		h = ((h << 5) ^ (h >> 27)) ^ entity.upgrade_level
		h = ((h << 5) ^ (h >> 27)) ^ entity.production_queue.size()
		h = ((h << 5) ^ (h >> 27)) ^ int(entity.build_timer * 100)
		h = ((h << 5) ^ (h >> 27)) ^ int(entity.production_timer * 100)
		h = ((h << 5) ^ (h >> 27)) ^ int(entity.upgrade_timer * 100)
		h = ((h << 5) ^ (h >> 27)) ^ entity.get_garrison_count()
	if entity.current_target and is_instance_valid(entity.current_target):
		h = ((h << 5) ^ (h >> 27)) ^ entity.current_target.get_instance_id()
	# 进驻状态
	if entity is Army:
		h = ((h << 5) ^ (h >> 27)) ^ (1 if entity._soldier_garrison_building and entity._soldier_garrison_building.get_ref() else 0)
	return h & 0x7FFFFFFF

# 建造/升级是"一次性状态切换"：完工瞬间只产生一条增量，丢包/跳帧会让客户端
# 一直停在"建造中"。检测状态切换，并在随后若干次广播内强制重发该实体。
func _track_transition_state(entity: GameEntity) -> bool:
	var id = entity.get_instance_id()
	if not (entity is Building):
		if _build_phase.has(id):
			_build_phase.erase(id)
		return false
	var now_build: bool = entity.build_timer > 0.0
	var now_upgrade: bool = entity.upgrade_timer > 0.0
	var prev = _build_phase.get(id, null)
	if prev != null:
		if (prev["build"] and not now_build) or (prev["upgrade"] and not now_upgrade):
			_sticky_resend_until[id] = _snap_tick + STICKY_RESEND_TICKS
	_build_phase[id] = {"build": now_build, "upgrade": now_upgrade}
	var until: int = int(_sticky_resend_until.get(id, -1))
	if until > _snap_tick:
		return true
	if until != -1:
		_sticky_resend_until.erase(id)
	return false

func _should_include_in_delta(snapshot_key, entity_id: int, new_hash: int, force_resend: bool = false) -> bool:
	if not _entity_state_hashes.has(snapshot_key):
		_entity_state_hashes[snapshot_key] = {}
	var hashes = _entity_state_hashes[snapshot_key]
	if not _entity_last_sent.has(snapshot_key):
		_entity_last_sent[snapshot_key] = {}
	var last_sent = _entity_last_sent[snapshot_key]
	if not hashes.has(entity_id):
		hashes[entity_id] = new_hash
		last_sent[entity_id] = _snap_tick
		return true  # 新实体，必须发送
	# 完工后的粘性重发：即使哈希不变也连续发送若干次，防止单条增量丢失导致客户端卡在"建造中"
	if force_resend:
		hashes[entity_id] = new_hash
		last_sent[entity_id] = _snap_tick
		return true
	# 超时强制重发：delta 只发一次，丢包后客户端状态会永久卡死（例如建筑完工后
	# 一直显示"建造中"）。用 entity_id 取模错开相位，避免同一帧集中重发一大批实体。
	if _snap_tick % FORCE_RESEND_EVERY == entity_id % FORCE_RESEND_EVERY and _snap_tick != int(last_sent.get(entity_id, -1)):
		hashes[entity_id] = new_hash
		last_sent[entity_id] = _snap_tick
		return true
	if hashes[entity_id] != new_hash:
		hashes[entity_id] = new_hash
		last_sent[entity_id] = _snap_tick
		return true  # 状态变化，需要发送
	return false  # 无变化，跳过

# 汇总本次要下发的死亡实体 ID：本次新死亡的 + 仍在重发窗口内的历史死亡 ID。
# 客户端删除是幂等的（节点已不存在就跳过），重复下发没有副作用；
# 这样单次快照丢包也不会让客户端留下"尸体"节点。
func _collect_dead_ids(snapshot_key, dead: Array) -> Array:
	if not _recent_dead_ids.has(snapshot_key):
		_recent_dead_ids[snapshot_key] = {}
	var recent = _recent_dead_ids[snapshot_key]
	for id in dead:
		_build_phase.erase(id)
		_sticky_resend_until.erase(id)
	var expire_at = _snap_tick + DEAD_ID_RESEND_SNAPSHOTS
	for id in dead:
		recent[id] = expire_at
	var expired = []
	for id in recent.keys():
		if int(recent[id]) <= _snap_tick:
			expired.append(id)
	for id in expired:
		recent.erase(id)
	# 大规模阵亡时限制单次携带的数量，避免快照包体过大被整包丢弃
	if recent.size() > DEAD_ID_MAX:
		var ids = recent.keys()
		ids.sort_custom(func(a, b): return int(recent[a]) > int(recent[b]))
		for i in range(DEAD_ID_MAX, ids.size()):
			recent.erase(ids[i])
	if recent.is_empty():
		return dead
	return recent.keys()

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
	# 同步清理"最后发送序号"，避免实体 ID 复用时残留旧时间戳
	if _entity_last_sent.has(snapshot_key):
		var last_sent = _entity_last_sent[snapshot_key]
		for eid in to_erase:
			last_sent.erase(eid)

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
	# snapshot rate tracking
	_snap_sent_timer += delta
	if _snap_sent_timer >= 1.0:
		_snap_sent_rate = _snap_sent
		_snap_sent = 0
		_snap_sent_timer = 0.0

	snapshot_timer -= delta
	if snapshot_timer <= 0:
		snapshot_timer = SNAPSHOT_INTERVAL
		broadcast_snapshot()

func broadcast_snapshot():
	_snap_sent += 1
	_snap_tick += 1
	# Ensure entity cache is fresh for this snap
	_ensure_cache_fresh()
	# Lazy-init the reusable vis_grid
	if _snap_vis_grid.size() == 0:
		_init_snap_vis_grid()
	# Collect bullets ONCE for all players (before timing)
	_bullet_cache.clear()
	for bullet in get_tree().get_nodes_in_group("bullets"):
		if bullet is Bullet:
			_bullet_cache.append(bullet)
	# Time only the actual broadcast work
	var _pt = Time.get_ticks_usec()
	if game_mode == NetworkManager.GameMode.ONEvONE:
		_broadcast_1v1()
	else:
		_broadcast_2v2()
	var _elapsed_snap = (Time.get_ticks_usec() - _pt) / 1000.0
	if _elapsed_snap > 5.0: print("[Profile-Snap] %.1fms" % _elapsed_snap)

# Build bullet data once — reused by all players
func _build_bullets_data() -> Array:
	var bullets_data = []
	for bullet in _bullet_cache:
		if is_instance_valid(bullet):
			# entity_id 供客户端判断弹丸模型（箭/炮弹/巨石），damage_radius 区分范围弹
			bullets_data.append({
				"id": bullet.get_instance_id(),
				"x": bullet.global_position.x,
				"y": bullet.global_position.y,
				"z": bullet.global_position.z,
				"team": bullet.team,
				"entity_id": bullet.source_entity_id,
				"damage_radius": bullet.damage_radius,
			})
	return bullets_data

# 1v1 视野裁剪快照 — optimized: entity cache + version-grid + typed iteration
func build_snapshot_for_team(team: int) -> Dictionary:
	var snapshot_key = "team_%d" % team
	var is_full = _is_full_snapshot(snapshot_key)

	# Build visibility grid using cached team entities (skips neutral/resource entities)
	_snap_vis_version = (_snap_vis_version + 1) & 0xFF
	if _snap_vis_version == 0: _snap_vis_version = 1
	var ver = _snap_vis_version
	var _ms = RTSConfig.MAP_SIZE
	var team_units = _entities_by_team.get(team, [])
	for entity in team_units:
		if is_instance_valid(entity) and entity.health > 0 and entity.vision_range > 0:
			var g = world_to_grid(entity.global_position)
			var r = entity.vision_range
			var offsets = _get_vis_offsets(int(r)); for off in offsets:
					var nx = g.x + int(off.x); var ny = g.y + int(off.y)
					if nx >= 0 and nx < _ms and ny >= 0 and ny < _ms:
						_snap_vis_grid[nx * _ms + ny] = ver

	var current_entities = {}
	var delta = []
	var dead = []

	# --- Own-team entities: delta check (from typed cache) ---
	for entity in _entities_by_team.get(team, []):
		if not is_instance_valid(entity): continue
		if entity.health <= 0:
			dead.append(entity.get_instance_id())
			continue
		var id = entity.get_instance_id()
		current_entities[id] = true
		var force_resend = _track_transition_state(entity)
		if is_full:
			delta.append(_serialize_entity_compact(entity))
		else:
			var h = _compute_entity_hash(entity)
			if _should_include_in_delta(snapshot_key, id, h, force_resend):
				delta.append(_serialize_entity_compact(entity))

	# --- Enemy/neutral team entities: visibility grid check ---
	var enemy_team = RTSConfig.Team.RED if team == RTSConfig.Team.BLUE else RTSConfig.Team.BLUE
	for entity in _entities_by_team.get(enemy_team, []):
		if not is_instance_valid(entity): continue
		if entity.health <= 0:
			dead.append(entity.get_instance_id())
			continue
		var id = entity.get_instance_id()
		current_entities[id] = true
		var g = world_to_grid(entity.global_position)
		if _snap_vis_grid[g.x * _ms + g.y] == ver:
			delta.append(_serialize_entity_compact(entity))

	# --- Neutral entities (from _entities_by_team[NEUTRAL]): only if visible or explored ---
	for entity in _entities_by_team.get(RTSConfig.Team.NEUTRAL, []):
		if not is_instance_valid(entity): continue
		if entity.health <= 0:
			dead.append(entity.get_instance_id())
			continue
		var id = entity.get_instance_id()
		current_entities[id] = true
		var g = world_to_grid(entity.global_position)
		var idx = g.x * _ms + g.y
		if _snap_vis_grid[idx] == ver 			or (g.x > 0 and _snap_vis_grid[idx - _ms] == ver) 			or (g.x < _ms - 1 and _snap_vis_grid[idx + _ms] == ver) 			or (g.y > 0 and _snap_vis_grid[idx - 1] == ver) 			or (g.y < _ms - 1 and _snap_vis_grid[idx + 1] == ver):
			delta.append(_serialize_entity_compact(entity))
		elif entity is WorldResource:
			if not team_explored_resources.has(team):
				team_explored_resources[team] = {}
			if team_explored_resources[team].has(id):
				delta.append(_serialize_entity_compact(entity))
			else:
				team_explored_resources[team][id] = true
				delta.append(_serialize_entity_compact(entity))

	# --- Disappeared entities (in last snapshot but not current) ---
	var last_cache = last_snapshot_cache.get(team, {})
	for id in last_cache.keys():
		if not current_entities.has(id):
			dead.append(id)
	last_snapshot_cache[team] = current_entities

	# --- Cleanup stale hashes ---
	_cleanup_dead_entity_hashes(snapshot_key, current_entities)

	var e = (_snap_sent % 10 == 0)  # 资源数据1Hz降频
	var r = {"delta": delta, "dead_ids": _collect_dead_ids(snapshot_key, dead), "full": is_full, "game_time": game_time}
	if e or is_full:
		r["resources"] = {"player": player_resources, "enemy": enemy_resources}
		r["limits"] = {"player": player_resource_limits, "enemy": enemy_resource_limits}
		r["population"] = {"current": player_pop if team == RTSConfig.Team.BLUE else enemy_pop, "max": player_max_pop if team == RTSConfig.Team.BLUE else enemy_max_pop}
		r["nation"] = team_nations.get(team, -1)
		r["enemy_nation"] = team_nations.get(RTSConfig.Team.RED if team == RTSConfig.Team.BLUE else RTSConfig.Team.BLUE, -1)
		r["gather_counts"] = team_gather_counts.get(team, {"gold":0, "wood":0, "stone":0, "food":0, "oil":0})
		r["income_rate"] = team_income_rates.get(team, {"gold":0.0, "wood":0.0, "stone":0.0, "food":0.0, "oil":0.0})
	r["alerts"] = _get_and_clear_alerts(team)
	return r

func _broadcast_1v1():
	# Collect bullet data ONCE (reused for all players)
	var bullets_data = _build_bullets_data()
	for pid in player_teams.keys():
		var team = player_teams[pid]
		var _pt_build = Time.get_ticks_usec()
		var data = build_snapshot_for_team(team)
		data["bullets"] = bullets_data
		data["seq"] = snapshot_seq
		snapshot_seq += 1
		NetworkManager._client_receive_snapshot.rpc_id(pid, data)
		var _elapsed_p = (Time.get_ticks_usec() - _pt_build) / 1000.0
		if _elapsed_p > 3.0: print("[Profile-Player] pid=%d %.1fms" % [pid, _elapsed_p])

func _serialize_entity_compact(entity: GameEntity) -> Array:
	var a = []
	a.resize(E.size())
	a[E.ID] = entity.get_instance_id()
	a[E.EID] = entity.entity_id
	a[E.TYPE] = entity.entity_type
	a[E.TEAM] = entity.team
	a[E.X] = entity.global_position.x
	a[E.Y] = entity.global_position.y
	a[E.Z] = entity.global_position.z
	a[E.HEALTH] = entity.health
	a[E.MAX_HEALTH] = entity.max_health
	a[E.ATTACK] = entity.attack
	a[E.ATTACK_SPEED] = entity.attack_speed
	a[E.MELEE_ARMOR] = entity.melee_armor
	a[E.SHIELD_ARMOR] = entity.shield_armor
	a[E.SPEED] = entity.speed
	a[E.VISION] = entity.vision_range
	a[E.BODY_R] = entity.body_radius
	a[E.TARGET_TYPE] = entity.target_type
	a[E.OWNER] = entity.owner_peer_id
	a[E.LEVEL] = entity.level
	a[E.ORDER] = entity.current_order if entity.current_order != "" else "idle"
	a[E.HOLD] = entity.hold_position
	a[E.NAME] = entity.get_display_name() if entity.has_method("get_display_name") else entity.display_name
	a[E.ENTITY_ID] = entity.entity_id
	a[E.WAYPOINTS] = _serialize_waypoints(entity)
	a[E.ROT_Y] = entity.rotation.y
	a[E.ASTAR_PATH] = _serialize_astar_path(entity)
	# 进驻状态
	var _is_garrisoned = false
	if entity is Army and entity._soldier_garrison_building and entity._soldier_garrison_building.get_ref():
		_is_garrisoned = true
	a[E.GARRISONED] = _is_garrisoned
	# Building extra
	if entity is Building:
		var ba = []
		ba.resize(EB.size())
		ba[EB.UPGRADE] = entity.upgrade_level
		ba[EB.MAX_UPGRADE] = entity.max_upgrade_level
		ba[EB.CAN_UPGRADE] = entity.can_upgrade()
		ba[EB.BUILD_TIMER] = entity.build_timer
		ba[EB.MAX_BUILD] = entity.max_build_time
		if entity.production_queue.size() > 0:
			ba[EB.PROD_CURRENT] = entity.production_queue[0]
			var cd = entity.get_prod_cooldown(entity.production_queue[0])
			ba[EB.PROD_PROGRESS] = 1.0 - (entity.production_timer / cd) if cd > 0 else 0.0
			ba[EB.PROD_QSIZE] = entity.production_queue.size()
		ba[EB.UPGRADE_TIMER] = entity.upgrade_timer
		ba[EB.MAX_UPGRADE_TIME] = entity.max_upgrade_time
		ba[EB.GARRISON_COUNT] = entity.get_garrison_count()
		a.append(ba)
	else:
		a.append([])
	return a

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
			"melee_armor": entity.melee_armor,
			"shield_armor": entity.shield_armor,
		"speed": entity.speed,
		"vision_range": entity.vision_range,
		"target_type": entity.target_type,
		"body_radius": entity.body_radius,
		"damage_radius": entity.damage_radius,
		"entity_id": entity.entity_id,
		"order": entity.current_order if entity.current_order != "" else "idle",
		"hold_position": entity.hold_position,
		"owner_peer_id": entity.owner_peer_id,
		"waypoints": _serialize_waypoints(entity),
	"astar_path": _serialize_astar_path(entity)
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

func _serialize_astar_path(entity: GameEntity) -> Array:
	var path = []
	if entity is Army and entity.get("_movement") != null and entity._movement:
		path = entity._movement.astar_path
	var result = []
	for wp in path:
		if wp is Vector3:
			result.append({"x": wp.x, "y": wp.y, "z": wp.z})
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
	# Collect bullet data ONCE (reused for all players)
	var bullets_data = _build_bullets_data()
	for pid in player_info.keys():
		if player_info[pid].get("is_ai", false): continue  # 跳过 AI，无客户端
		var _pt_build = Time.get_ticks_usec()
		var data = build_snapshot_for_player(pid)
		data["bullets"] = bullets_data
		data["seq"] = snapshot_seq
		
		snapshot_seq += 1
		NetworkManager._client_receive_snapshot.rpc_id(pid, data)
		var _elapsed_p = (Time.get_ticks_usec() - _pt_build) / 1000.0
		if _elapsed_p > 3.0: print("[Profile-Player] pid=%d %.1fms" % [pid, _elapsed_p])

func build_snapshot_for_player(peer_id: int) -> Dictionary:
	var team = player_info[peer_id].team
	var snapshot_key = "player_%d" % peer_id
	var is_full = _is_full_snapshot(snapshot_key)
	var _t0 = Time.get_ticks_usec()

	# Build visibility grid using cached team entities
	_snap_vis_version = (_snap_vis_version + 1) & 0xFF
	if _snap_vis_version == 0: _snap_vis_version = 1
	var ver = _snap_vis_version
	var _ms = RTSConfig.MAP_SIZE
	var team_units = _entities_by_team.get(team, [])
	for entity in team_units:
		if not entity: continue
		if is_instance_valid(entity) and entity.health > 0 and entity.vision_range > 0:
			var g = world_to_grid(entity.global_position)
			var r = entity.vision_range
			var offsets = _get_vis_offsets(int(r)); for off in offsets:
					var nx = g.x + int(off.x); var ny = g.y + int(off.y)
					if nx >= 0 and nx < _ms and ny >= 0 and ny < _ms:
						_snap_vis_grid[nx * _ms + ny] = ver
	var _t_vis = (Time.get_ticks_usec() - _t0) / 1000.0

	var delta = []
	var current_all_ids = {}
	var dead = []

	# --- Own entities: delta check ---
	var own_team_arr = _entities_by_team.get(team, [])
	for entity in own_team_arr:
		if not is_instance_valid(entity): continue
		if entity.health <= 0:
			dead.append(entity.get_instance_id())
			continue
		var id = entity.get_instance_id()
		current_all_ids[id] = true
		# Same-team entities (own + teammate) all get delta compression
		var force_resend = _track_transition_state(entity)
		if not is_full:
			var h = _compute_entity_hash(entity)
			if not _should_include_in_delta(snapshot_key, id, h, force_resend):
				continue
		delta.append(_serialize_entity_compact(entity))
	var _t_own = (Time.get_ticks_usec() - _t0) / 1000.0

	# --- Enemy team entities: visibility grid check ---
	var enemy_team = RTSConfig.Team.RED if team == RTSConfig.Team.BLUE else RTSConfig.Team.BLUE
	for entity in _entities_by_team.get(enemy_team, []):
		if not is_instance_valid(entity): continue
		if entity.health <= 0:
			dead.append(entity.get_instance_id())
			continue
		var id = entity.get_instance_id()
		current_all_ids[id] = true
		var g = world_to_grid(entity.global_position)
		if _snap_vis_grid[g.x * _ms + g.y] == ver:
			delta.append(_serialize_entity_compact(entity))
	var _t_enemy = (Time.get_ticks_usec() - _t0) / 1000.0

	# --- Neutral entities: visible or explored ---
	for entity in _entities_by_team.get(RTSConfig.Team.NEUTRAL, []):
		if not entity:continue
		if not is_instance_valid(entity): continue
		if entity.health <= 0:
			dead.append(entity.get_instance_id())
			continue
		var id = entity.get_instance_id()
		current_all_ids[id] = true
		var g = world_to_grid(entity.global_position)
		var idx = g.x * _ms + g.y
		if _snap_vis_grid[idx] == ver 			or (g.x > 0 and _snap_vis_grid[idx - _ms] == ver) 			or (g.x < _ms - 1 and _snap_vis_grid[idx + _ms] == ver) 			or (g.y > 0 and _snap_vis_grid[idx - 1] == ver) 			or (g.y < _ms - 1 and _snap_vis_grid[idx + 1] == ver):
			delta.append(_serialize_entity_compact(entity))
		elif entity is WorldResource:
			if not team_explored_resources.has(team):
				team_explored_resources[team] = {}
			if team_explored_resources[team].has(id):
				delta.append(_serialize_entity_compact(entity))
			else:
				team_explored_resources[team][id] = true
				delta.append(_serialize_entity_compact(entity))
	var _t_neutral = (Time.get_ticks_usec() - _t0) / 1000.0

	# --- Disappeared entities ---
	var last_ids = player_last_snapshot_ids.get(peer_id, [])
	for lid in last_ids:
		if not current_all_ids.has(lid):
			dead.append(lid)
	player_last_snapshot_ids[peer_id] = current_all_ids.keys()

	_cleanup_dead_entity_hashes(snapshot_key, current_all_ids)

	var e2 = (_snap_sent % 10 == 0)  # 资源数据1Hz降频
	var result = {
		"delta": delta,
		"dead_ids": _collect_dead_ids(snapshot_key, dead),
		"full": is_full,
		"game_time": game_time,
	}
	if e2 or is_full:
		result["player_resources"] = { peer_id: player_resources[peer_id] }
		result["player_limits"] = { peer_id: player_limits_dict.get(peer_id, {}) }
		result["player_population"] = { peer_id: player_population[peer_id] }
		result["gather_counts"] = {peer_id: team_gather_counts.get(peer_id, {"gold":0, "wood":0, "stone":0, "food":0, "oil":0})}
		result["income_rate"] = {peer_id: team_income_rates.get(peer_id, {"gold":0.0, "wood":0.0, "stone":0.0, "food":0.0, "oil":0.0})}
	if is_full:
		result["team_nations"] = team_nations
		result["player_info"] = player_info
	result["player_castles"] = _serialize_castles()
	result["alerts"] = _get_and_clear_alerts(team)

	# Granular profiling: only print when total > 2.5ms
	var _t_total = (Time.get_ticks_usec() - _t0) / 1000.0
	

	return result
func _1v1_set_group
(team: int, data: Dictionary):
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

	else:
		sel._set_control_group(g)

func _1v1_demolish(team: int, data: Dictionary):
	var building_id = data.get("building_id", -1)
	if building_id == -1: return
	for e in entities.get_children():
		if e is Building and e.get_instance_id() == building_id and e.team == team and e.entity_id != 20:
			var base_cfg = EntityDatabase.get_config(e.entity_id)
			if not base_cfg.is_empty():
				var cost = base_cfg.get("cost", {})
				var res_dict = get_resources_for(1) if team == RTSConfig.Team.BLUE else enemy_resources
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

# ---------- 释放进驻单位 ----------
func _ungarrison_soldiers_1v1(team: int, data: Dictionary):
	for eid in data.get("selected_ids", []):
		for e in entities.get_children():
			if e.get_instance_id() == eid and e.team == team:
				if e is Building and e.garrisoned_soldiers.size() > 0:
					e.release_all_garrisoned()
				elif e is Army and e.entity_id == 18 and e._ram_garrisoned_soldiers.size() > 0:
					for uid in e._ram_garrisoned_soldiers.duplicate():
						var unit = instance_from_id(uid)
						if unit and is_instance_valid(unit):
							unit._exit_soldier_garrison()
				break

func _ungarrison_soldiers_2v2(peer_id: int, data: Dictionary):
	for eid in data.get("selected_ids", []):
		for e in entities.get_children():
			if e.get_instance_id() == eid and e.owner_peer_id == peer_id:
				if e is Building and e.garrisoned_soldiers.size() > 0:
					e.release_all_garrisoned()
				elif e is Army and e.entity_id == 18 and e._ram_garrisoned_soldiers.size() > 0:
					for uid in e._ram_garrisoned_soldiers.duplicate():
						var unit = instance_from_id(uid)
						if unit and is_instance_valid(unit):
							unit._exit_soldier_garrison()
				break

func _1v1_recall_group(_t: int, data: Dictionary):
	var sel = selection as SelectionManager
	if sel:
		sel._recall_control_group(data.get("group", 0))

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

	else:
		sel._set_control_group(g)

func _2v2_recall_group(_peer_id: int, data: Dictionary):
	var sel = selection as SelectionManager
	if sel:
		sel._recall_control_group(data.get("group", 0))

func get_gather_paused(team: int) -> bool:
	return team_gather_paused.get(team, false)

# Override: 联机模式跳过每帧O(n^2)可见性检查（服务端不需要渲染）
func _update_visibility():
	super._update_visibility()    # 调用父类迷雾遮罩逻辑，隐藏视野外单位

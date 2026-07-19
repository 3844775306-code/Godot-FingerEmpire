class_name RTSBattleManager
extends Node3D
var previous_emulate_mouse: bool
# ==================== 资源 ====================
var player_resources: Dictionary = {"gold": 100, "wood": 100, "stone": 100 ,"food": 100, "oil": 0}
var enemy_resources: Dictionary = {"gold": 100, "wood": 100, "stone": 100, "food": 100, "oil": 0}
var player_resource_limits: Dictionary = {"gold": 500, "wood": 500, "stone": 500, "food": 500, "oil": 0}
var enemy_resource_limits: Dictionary = {"gold": 500, "wood": 500, "stone": 500, "food": 500, "oil": 0}
var is_online: bool = false
var team_building_levels: Dictionary = {}  # team -> {building_id: level}
var build_touch_active: bool = false   # 是否正在拖拽建造
var build_drag_started: bool = false   # 是否已开始拖拽（手指按下后）
# ==================== 人口 ====================
var player_pop: int = 0
var player_max_pop: int = 50
var enemy_pop: int = 0
var enemy_max_pop: int = 50
var game_mode_2v2: bool = false               # 是否单机2v2模式
var player_owner_id: int = 1                  # 玩家自己的owner_peer_id (单机2v2=1, 1v1=-1)
var ai_players: Dictionary = {}               # { peer_id: { "team":, "slot":, "castle": } }
var ai_resources: Dictionary = {}             # peer_id -> resources dict
var ai_population: Dictionary = {}            # peer_id -> population dict
var ai_limits: Dictionary = {}                # peer_id -> limits dict
# ==================== 建造 ====================
var building_defs: Array = []
var build_mode: bool = false
var selected_building_id: int = -1
var build_preview: Node3D = null
var current_build_menu: Control = null

# ==================== 迷雾 ====================
var explored_grid: Array = []
var visible_grid: Array = []
var fog_timer: float = 0.0

# ==================== 游戏状态 ====================
var game_over_panel: Control = null
var game_over_label: Label = null
var game_over: bool = false
var game_time: float = 0.0
var game_time_label: Label = null
var gather_paused: bool = false
var rally_mode: bool = false

# ==================== 警报系统 ====================
var _alert_cooldowns: Dictionary = {}
var _enemy_attack_cooldown: float = 0.0

# ==================== 城堡位置 ====================
var player_castle_pos: Vector3
var enemy_castle_pos: Vector3

# ==================== 节点引用 ====================
@onready var entities: Node3D = $Entities
@onready var selection: SelectionManager = $SelectionManager
@onready var info_panel: InfoPanel = $UI/InfoPanel

# ==================== 实体分组缓存 (避免每帧 O(N) 全量扫描) ====================
var _entity_cache_dirty: bool = true
var _all_entities: Array = []           # 所有存活实体
var _armies: Array = []                 # 仅 Army 实体
var _buildings: Array = []              # 仅 Building 实体
var _resources: Array = []              # 仅 WorldResource 实体
var _towers: Array = []                 # 防御塔 (id 25, 26)
var _entities_by_team: Dictionary = {}  # team int → Array
var _entity_lookup: Dictionary = {}     # instance_id → GameEntity (O(1) 查找)
var _cache_refresh_timer: float = 0.0

# ==================== 诊断工具 ====================
var _diag_timer: float = 5.0
var _diag_last_total: int = 0
var _diag_last_bullets: int = 0
var _diag_step: int = 0
var _diag_active_entity: String = ""
var _diag_active_frame: int = 0
var _diag_physics_heartbeat: int = 0
var _fps_label: Label = null

func _create_diag_label():
	_fps_label = Label.new()
	_fps_label.name = "DiagFPS"
	_fps_label.position = Vector2(10, 700)
	_fps_label.add_theme_font_size_override("font_size", 16)
	_fps_label.add_theme_color_override("font_color", Color.LIME_GREEN)
	_fps_label.z_index = 200
	var canvas = CanvasLayer.new()
	canvas.name = "DiagLayer"
	canvas.layer = 100
	canvas.add_child(_fps_label)
	add_child(canvas)

func _rebuild_entity_cache():
	_all_entities.clear()
	_armies.clear()
	_buildings.clear()
	_resources.clear()
	_towers.clear()
	_entities_by_team.clear()
	_entity_lookup.clear()
	if not entities: return
	for child in entities.get_children():
		if not is_instance_valid(child) or not (child is GameEntity) or child.health <= 0:
			continue
		_all_entities.append(child)
		_entity_lookup[child.get_instance_id()] = child
		if child is Army:
			_armies.append(child)
		elif child is Building:
			_buildings.append(child)
			if child.entity_id in [25, 26]:
				_towers.append(child)
		elif child is WorldResource:
			_resources.append(child)
		var t = child.team
		if not _entities_by_team.has(t):
			_entities_by_team[t] = []
		_entities_by_team[t].append(child)
	_entity_cache_dirty = false

func mark_entity_cache_dirty():
	_entity_cache_dirty = true

func _ensure_cache_fresh():
	if _entity_cache_dirty:
		_rebuild_entity_cache()

# 获取范围内敌军实体（仅搜索非己方队伍）
func get_nearby_enemies(from_pos: Vector3, search_range: float, my_team: int) -> Array:
	_ensure_cache_fresh()
	var result: Array = []
	for t in _entities_by_team.keys():
		if t == my_team or t == RTSConfig.Team.NEUTRAL:
			continue
		for entity in _entities_by_team[t]:
			if not is_instance_valid(entity) or entity.health <= 0:
				continue
			var dist = from_pos.distance_squared_to(entity.global_position)
			var max_dist = search_range + entity.body_radius + 1.0
			if dist <= max_dist * max_dist:
				result.append(entity)
	return result

# 获取最近资源
func get_nearest_resource(from_pos: Vector3, search_range: float, resource_types: Array = []) -> WorldResource:
	_ensure_cache_fresh()
	var best_dist = search_range * search_range
	var best: WorldResource = null
	for res in _resources:
		if not is_instance_valid(res) or res.health <= 0:
			continue
		if resource_types.size() > 0 and not res.resource_type in resource_types:
			continue
		var d = from_pos.distance_squared_to(res.global_position)
		if d < best_dist:
			best_dist = d
			best = res
	return best

# 获取附近所有实体（用于碰撞检测等）
func get_nearby_entities(from_pos: Vector3, search_range: float) -> Array:
	_ensure_cache_fresh()
	var result: Array = []
	var sq_range = search_range * search_range
	for entity in _all_entities:
		if not is_instance_valid(entity): continue
		if entity.health <= 0:
			continue
		var d = from_pos.distance_squared_to(entity.global_position)
		if d <= sq_range:
			result.append(entity)
	return result

# ==================== 国家系统 ====================
var team_nations: Dictionary = {
	RTSConfig.Team.BLUE: GameSettings.player_nation,
	RTSConfig.Team.RED: GameSettings.enemy_nation
}


# 玩家颜色映射 — 联机时由 OnlineBattleManager 填充实际 peer_id
var _player_colors: Dictionary = {
	1: Color(0.2, 0.6, 1.0),   # 蓝方玩家（单机默认）
	3: Color(1.0, 0.3, 0.2),   # 红方AI（单机默认）
}
func get_player_colors() -> Dictionary:
	return _player_colors

func get_team_nation(team: int) -> int:
	return team_nations.get(team, -1)

# ==================== 获取主城堡 ====================
func get_player_castle() -> Building:
	_ensure_cache_fresh()
	for entity in _buildings:
		if is_instance_valid(entity) and entity.team == RTSConfig.Team.BLUE and entity.entity_id == 20:
			return entity
	return null

func get_player_castle_level() -> int:
	_ensure_cache_fresh()
	var max_lv = 1
	for e in _buildings:
		if is_instance_valid(e) and e.entity_id == 20 and e.team == RTSConfig.Team.BLUE and e.health > 0:
			if e.upgrade_level > max_lv:
				max_lv = e.upgrade_level
	return max_lv

# 检查建筑是否已由城堡等级解锁
func is_building_unlocked(building_id: int) -> bool:
	var cl = get_player_castle_level()
	match building_id:
		23, 25, 26:  # 船坞、箭塔、炮塔 → 城堡2级
			return cl >= 2
		24, 29, 52:   # 攻城车间、重装武器厂、集市 → 城堡3级
			return cl >= 3
		42:            # 书院 → 主城4级
			return cl >= 4
		53:            # 城堡 → 主城4级
			return cl >= 4
	return true

# 获取某建筑需要的城堡等级描述
func get_building_required_castle_level(building_id: int) -> int:
	match building_id:
		23, 25, 26: return 2
		24, 29: return 3
		42: return 4
	return 1

func get_enemy_castle() -> Building:
	_ensure_cache_fresh()
	for entity in _buildings:
		if is_instance_valid(entity) and entity.team == RTSConfig.Team.RED and entity.entity_id == 20:
			return entity
	return null

# ==================== 游戏结束界面 ====================
func _create_game_over_panel():
	game_over_panel = Control.new()
	game_over_panel.name = "GameOverPanel"
	game_over_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	game_over_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	game_over_panel.visible = false

	var bg = ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0, 0, 0, 0.7)
	game_over_panel.add_child(bg)

	var vbox = VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	vbox.custom_minimum_size = Vector2(300, 200)
	game_over_panel.add_child(vbox)

	game_over_label = Label.new()
	game_over_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	game_over_label.add_theme_font_size_override("font_size", 36)
	vbox.add_child(game_over_label)

	var restart_btn = Button.new()
	restart_btn.text = "重新开始"
	restart_btn.custom_minimum_size = Vector2(150, 40)
	restart_btn.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/rts_battle.tscn"))
	vbox.add_child(restart_btn)

	var quit_btn = Button.new()
	quit_btn.text = "返回主菜单"
	quit_btn.custom_minimum_size = Vector2(150, 40)
	quit_btn.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/main_menu.tscn"))
	vbox.add_child(quit_btn)

	if has_node("UI"):
		$UI.add_child(game_over_panel)
	else:
		add_child(game_over_panel)

func _create_game_timer():
	game_time_label = Label.new()
	game_time_label.name = "GameTimer"
	game_time_label.text = "00:00"
	game_time_label.add_theme_font_size_override("font_size", 28)
	game_time_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
	game_time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	game_time_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	game_time_label.position = Vector2(-60, 8)
	game_time_label.size = Vector2(120, 40)
	if has_node("UI"):
		add_child(game_time_label)
	else:
		add_child(game_time_label)

# ==================== 城堡被摧毁 → 游戏结束 ====================
func _on_castle_died(team: int):
	if game_over: return
	game_over = true
	AudioManager.play_music("defeat" if team == RTSConfig.Team.BLUE else "victory")

	if team == RTSConfig.Team.BLUE:
		_show_hud_alert("我方基地正遭受攻击！", Color(1.0, 0.2, 0.1))
		game_over_label.text = "你输了！"
		game_over_label.add_theme_color_override("font_color", Color.RED)
	else:
		_show_hud_alert("敌军基地已被摧毁！", Color(0.2, 1.0, 0.3))
		game_over_label.text = "你赢了！"
		game_over_label.add_theme_color_override("font_color", Color.GREEN)

	game_over_panel.visible = true

# ==================== 人口上限更新 ====================
func update_population_limits():
	var p_max = 0
	var e_max = 0
	if not entities: return
	for entity in entities.get_children():
		if not (entity is Building) or entity.health <= 0 or entity.build_timer > 0: continue
		if entity.team == RTSConfig.Team.BLUE:
			if entity.entity_id == 20: p_max += 20
			elif entity.entity_id == 28: p_max += 10
		elif entity.team == RTSConfig.Team.RED:
			if entity.entity_id == 20: e_max += 20
			elif entity.entity_id == 28: e_max += 10
	player_max_pop = p_max
	enemy_max_pop = e_max

	player_max_pop += NationBonuses.get_population_bonus(team_nations[RTSConfig.Team.BLUE])
	enemy_max_pop += NationBonuses.get_population_bonus(team_nations[RTSConfig.Team.RED])

func increase_population(team: int, amount: int = 1):
	if team == RTSConfig.Team.BLUE:
		player_pop += amount
	else:
		enemy_pop += amount

func decrease_population(team: int, amount: int = 1):
	if team == RTSConfig.Team.BLUE:
		player_pop = max(0, player_pop - amount)
	else:
		enemy_pop = max(0, enemy_pop - amount)

func can_train_unit(team: int) -> bool:
	return (team == RTSConfig.Team.BLUE and player_pop < player_max_pop) or (team == RTSConfig.Team.RED and enemy_pop < enemy_max_pop*2)

	
# ==================== 初始化 ====================
func _ready():
	
	
	add_to_group("battle_manager")
	_init_building_defs()
	if not is_online:
		if game_mode_2v2:
			_init_2v2_single()
		else:
			call_deferred("_init_entities_deferred")   # 单机1v1原逻辑
	if info_panel: info_panel.battle = self
	_create_game_over_panel()
	_create_game_timer()
	_create_diag_label()
	AudioManager.play_music("battle")
	set_process(true)
	call_deferred("_print_model_animations")


func _print_anim(path, label):
	var s = load(path)
	if s:
		var inst = s.instantiate()
		if inst:
			var ap = inst.get_node_or_null("AnimationPlayer") as AnimationPlayer
			if ap: print("  %s: %s" % [label, str(ap.get_animation_list())])
			inst.queue_free()

	print("===== GLB Animation List =====")
	var dir = DirAccess.open("res://models")
	if not dir: print("Cannot open models/"); return
	dir.list_dir_begin()
	var fname = dir.get_next()
	while fname != "":
		if fname.ends_with(".glb"):
			path = "res://models/" + fname
			s = load(path)
			if s:
				var inst = s.instantiate()
				if inst:
					var ap = inst.get_node_or_null("AnimationPlayer") as AnimationPlayer
					if ap:
						var anims = ap.get_animation_list()
						print("  %s: %s" % [fname, str(anims)])
					inst.queue_free()
		fname = dir.get_next()
	dir.list_dir_end()
	print("==============================")

func _init_2v2_single():
	# 定义四个玩家：玩家槽0(蓝)、AI槽1(蓝)、AI槽0(红)、AI槽1(红)
	var setup = [
		{ "peer_id": 1, "team": RTSConfig.Team.BLUE, "slot": 0, "is_human": true, "nation": GameSettings.player_nation },
		{ "peer_id": 2, "team": RTSConfig.Team.BLUE, "slot": 1, "is_human": false, "nation": randi() % 5 },
		{ "peer_id": 3, "team": RTSConfig.Team.RED, "slot": 0, "is_human": false, "nation": randi() % 5 },
		{ "peer_id": 4, "team": RTSConfig.Team.RED, "slot": 1, "is_human": false, "nation": randi() % 5 },
	]

	var map = $Map
	if not map: return
	var positions = map.get_four_castle_positions()   # [blue1, blue2, red1, red2]

	for info in setup:
		var pid = info.peer_id
		var team = info.team
		var slot = info.slot
		var castle_pos = positions[slot] if team == RTSConfig.Team.BLUE else positions[2 + slot]

		# 初始化资源
		if info.is_human:
			player_resources = {"gold": 500, "wood": 500, "stone": 300, "food": 500, "oil": 0}
			player_pop = 3; player_max_pop = 20
			player_owner_id = pid
		else:
			ai_resources[pid] = {"gold": 500, "wood": 500, "stone": 300, "food": 500, "oil": 0}
			ai_population[pid] = {"current": 3, "max": 20}
			ai_limits[pid] = {"gold": 500, "wood": 500, "stone": 500, "food": 500, "oil": 0}
			# 创建AI控制器
			var ai = AIController.new()
			ai.my_peer_id = pid
			ai.my_team = team
			ai.name = "AIController_%d" % pid
			add_child(ai)

		# 创建城堡
		var castle_cfg = EntityDatabase.get_config(20)
		castle_cfg["team"] = team
		castle_cfg["owner_peer_id"] = pid
		var castle = spawn_entity(castle_cfg, team, castle_pos, 1)
		castle.owner_peer_id = pid
		if castle:
			castle.died.connect(_on_castle_died.bind(team))   # 简化处理，后续可扩展
			ai_players[pid] = {"castle": castle, "team": team, "slot": slot}

		# 生成3个农民
		var peasant_cfg = EntityDatabase.get_config(10)
		peasant_cfg["team"] = team
		for i in range(3):
			var pos = castle_pos + Vector3(randf_range(-3,3), 0, randf_range(-3,3))
			var cfg = peasant_cfg.duplicate()
			cfg["owner_peer_id"] = pid
			spawn_entity(cfg, team, pos, 1)

	# 资源点
	for res in map.resource_positions:
		var cfg = EntityDatabase.get_config(res.type)
		var e = spawn_entity(cfg, RTSConfig.Team.NEUTRAL, res.pos)

	_init_fog_grid()
	# 聚焦玩家城堡
	var player_castle = ai_players[1].castle
	if player_castle:
		var cam = get_viewport().get_camera_3d()
		if cam:
			cam.global_position = Vector3(player_castle.global_position.x, cam.global_position.y, player_castle.global_position.z)
# 根据owner_id获取资源字典
func get_resources_for(owner_id: int) -> Dictionary:
	if owner_id == player_owner_id:
		return player_resources
	if owner_id == -1:
		return enemy_resources
	return ai_resources.get(owner_id, {})

# 根据owner_id扣除资源
func deduct_resources_for(owner_id: int, cost: Dictionary) -> bool:
	var res = get_resources_for(owner_id)
	for k in cost: 
		if res.get(k, 0) < cost[k]: return false
	for k in cost: 
		res[k] -= cost[k]
	return true

# 获取人口
func get_population_for(owner_id: int) -> Dictionary:
	if owner_id == player_owner_id:
		return {"current": player_pop, "max": player_max_pop}
	return ai_population.get(owner_id, {"current":0,"max":20})

# 增加人口
func increase_population_for(owner_id: int, amount: int = 1):
	if owner_id == player_owner_id:
		player_pop += amount
	else:
		if ai_population.has(owner_id):
			ai_population[owner_id]["current"] += amount

# 减少人口
func decrease_population_for(owner_id: int, amount: int = 1):
	if owner_id == player_owner_id:
		player_pop = max(0, player_pop - amount)
	else:
		if ai_population.has(owner_id):
			ai_population[owner_id]["current"] = max(0, ai_population[owner_id]["current"] - amount)

# 检查是否可以训练
func can_train_for(owner_id: int) -> bool:
	var pop = get_population_for(owner_id)
	return pop["current"] < pop["max"]

# 增加资源（采集时调用）
func add_resource_for(owner_id: int, type: String, amount: int):
	var res = get_resources_for(owner_id)
	if res.has(type):
		res[type] = min(res[type] + amount, get_limits_for(owner_id).get(type, 99999))

# 扣除资源（商人和建筑使用）
func deduct_player_resources(owner_id: int, cost: Dictionary) -> bool:
	var res = get_resources_for(owner_id)
	for k in cost:
		if res.get(k, 0) < cost[k]:
			return false
	for k in cost:
		res[k] -= cost[k]
	return true

# 获取上限
func get_limits_for(owner_id: int) -> Dictionary:
	if owner_id == player_owner_id:
		return player_resource_limits
	return ai_limits.get(owner_id, {})
# Global building type upgrade (2v2: per-player via owner_peer_id, 1v1: per-team)
func get_building_type_level(team: int, building_id: int, peer_id: int = -1) -> int:
	var key = peer_id if peer_id != -1 else team
	if not team_building_levels.has(key):
		team_building_levels[key] = {}
	return team_building_levels[key].get(building_id, 1)

func upgrade_building_type(team: int, building_id: int, from_building: Building):
	var pid = from_building.owner_peer_id
	var key = pid if pid != -1 else team
	if not team_building_levels.has(key):
		team_building_levels[key] = {}
	var new_lv = team_building_levels[key].get(building_id, 1) + 1
	team_building_levels[key][building_id] = new_lv
	# Apply to all existing buildings of this type (same owner in 2v2, same team in 1v1)
	var upgrade = from_building.upgrade_data[min(from_building.upgrade_level - 1, from_building.upgrade_data.size() - 1)]
	for e in entities.get_children():
		if e is Building and e.entity_id == building_id and e.health > 0:
			var matches = (pid != -1 and e.owner_peer_id == pid) or (pid == -1 and e.team == team)
			if not matches: continue
			e.upgrade_level = new_lv
			e.level = new_lv
			e.max_health += upgrade.get("health_bonus", 0)
			e.health = min(e.health + upgrade.get("health_bonus", 0), e.max_health)
			e.armor += upgrade.get("armor_bonus", 0)
			e.attack += upgrade.get("attack_bonus", 0)
			# Unlock units
			if e.building_data.has("produces") and e.building_data["produces"] is Array:
				var full = e.building_data["produces"]
				for i in range(min(new_lv, full.size())):
					var prod = full[i].duplicate()
					if not e.production_list.has(prod):
						e.production_list.append(prod)
				# Also add unit from upgrade's unlocks_unit (for Market merchants etc.)
				if upgrade.has("unlocks_unit"):
					var uid = upgrade["unlocks_unit"]
					var uc = EntityDatabase.get_config(uid)
					if not uc.is_empty():
						var uprod = {"unit_id": uid, "cooldown": uc.get("attack_speed", 5.0), "queue_limit": 3}
						if not e.production_list.has(uprod):
							e.production_list.append(uprod)
			# Warehouse bonus
			if e.entity_id == 22 and upgrade.has("storage_bonus"):
				e.building_data["storage_bonus"] = e.building_data.get("storage_bonus", 0) + upgrade["storage_bonus"]
			# Nation units
			if e.entity_id == 53 and new_lv >= 1:
				var nation = get_team_nation(team)
				if nation >= 0:
					e._unlock_nation_units(nation)
	update_resource_limits(team)
	update_population_limits()

func _init_building_defs():
	building_defs.clear()
	for cfg in EntityDatabase.configs.values():
		if cfg.type == 1 and cfg.id != 20:
			building_defs.append(cfg.duplicate())

func _init_entities_deferred():
	var map = $Map
	if not map: return

	player_castle_pos = map.player_castle_pos
	enemy_castle_pos = map.enemy_castle_pos

	# 获取国家
	var player_nation = GameSettings.player_nation
	var enemy_nation = GameSettings.enemy_nation
	if enemy_nation < 0 or enemy_nation > 4:
		enemy_nation = randi() % 5

	team_nations = {
		RTSConfig.Team.BLUE: player_nation,
		RTSConfig.Team.RED: enemy_nation
	}

	# 生成玩家城堡
	var castle_cfg = EntityDatabase.get_config(20)
	castle_cfg["team"] = RTSConfig.Team.BLUE
	var player_castle = spawn_entity(castle_cfg, RTSConfig.Team.BLUE, player_castle_pos)
	if player_castle:
		player_castle.died.connect(_on_castle_died.bind(RTSConfig.Team.BLUE))
		var start_lv = NationBonuses.get_castle_start_level(player_nation)
		player_castle.upgrade_level = start_lv
		player_castle.level = start_lv
		if start_lv >= 3:
			player_castle._unlock_nation_units(player_nation)

	# 生成敌人城堡
	castle_cfg = EntityDatabase.get_config(20)
	castle_cfg["team"] = RTSConfig.Team.RED
	var enemy_castle = spawn_entity(castle_cfg, RTSConfig.Team.RED, enemy_castle_pos)
	if enemy_castle:
		enemy_castle.died.connect(_on_castle_died.bind(RTSConfig.Team.RED))
		var start_lv_enemy = NationBonuses.get_castle_start_level(enemy_nation)
		enemy_castle.upgrade_level = start_lv_enemy
		enemy_castle.level = start_lv_enemy
		if start_lv_enemy >= 3:
			enemy_castle._unlock_nation_units(enemy_nation)

	# 资源点
	for res in map.resource_positions:
		var cfg = EntityDatabase.get_config(res.type)
		var e = spawn_entity(cfg, RTSConfig.Team.NEUTRAL, res.pos)

	# 初始农民
	var peasant_cfg = EntityDatabase.get_config(10)
	for i in 3:
		spawn_entity(peasant_cfg, RTSConfig.Team.BLUE, player_castle_pos + Vector3(2,0,2+i*2))
	for i in 3:
		spawn_entity(peasant_cfg, RTSConfig.Team.RED, enemy_castle_pos + Vector3(-2,0,-2-i*2))

	# 相机聚焦玩家城堡
	var cam = get_viewport().get_camera_3d()
	if cam and player_castle:
		cam.global_position = Vector3(player_castle.global_position.x, cam.global_position.y, player_castle.global_position.z)

# ==================== 实体生成 ====================
func _apply_entity_model(entity: GameEntity) -> bool:
	var model_path = RTSConfig.get_entity_model(entity.entity_id, entity.level)
	# 城墙拐角检测
	if entity.entity_id == 27:
		var has_x = false; var has_z = false
		for e in entities.get_children():
			if e is Building and e.entity_id == 27 and e.health > 0 and e != entity:
				var d = e.global_position - entity.global_position
				if abs(d.x) < 2.0 and abs(d.z) < 0.5: has_x = true
				if abs(d.z) < 2.0 and abs(d.x) < 0.5: has_z = true
		if has_x and has_z: model_path = "res://models/castle/wall-corner.glb"
		else: model_path = "res://models/castle/wall.glb"
	if model_path == "" or not ResourceLoader.exists(model_path):
		return false
	var model_scene = load(model_path)
	if not model_scene: return false
	var model_instance = model_scene.instantiate()
	if not model_instance: return false
	# 移除旧Mesh子节点
	for child in entity.get_children():
		if child is MeshInstance3D and child.name != "SelectionRing":
			child.queue_free()
	# 缩放模型以匹配实体大小
	var target_size = entity.body_radius * 2.0
	var aabb = _get_model_aabb(model_instance)
	var current_size = max(aabb.size.x, max(aabb.size.y, aabb.size.z))
	if current_size > 0.01:
		var scale_factor = target_size / current_size
		model_instance.scale = Vector3.ONE * scale_factor
	entity.add_child(model_instance)
	# 特殊朝向调整
	if entity.entity_id == 16: model_instance.rotation.y = deg_to_rad(180)
	elif entity.entity_id == 17: model_instance.rotation.y = deg_to_rad(90)
	# 存储模型引用用于动画
	entity.set_meta("_model_instance", model_instance)
	# 角色模型启用顶点颜色（编辑器预览依赖此特性）
	if entity.entity_id in [10, 43, 44, 45, 46, 47, 48, 49, 50, 51]:
		_enable_vertex_colors(model_instance)
	return true

func _set_unshaded_recursive(node: Node):
	for child in node.get_children():
		if child is MeshInstance3D and child.mesh:
			for si in child.mesh.get_surface_count():
				var src = child.get_active_material(si)
				if src and "shading_mode" in src:
					var m = src.duplicate()
					m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
					child.set_surface_override_material(si, m)
		_set_unshaded_recursive(child)

func _get_model_aabb(node: Node) -> AABB:
	var aabb = AABB()
	for child in node.get_children():
		if child is MeshInstance3D and child.mesh:
			var child_aabb = child.mesh.get_aabb()
			if child_aabb.size.length() > 0:
				aabb = aabb.merge(child_aabb)
		var child_result = _get_model_aabb(child)
		if child_result.size.length() > 0:
			aabb = aabb.merge(child_result)
	return aabb

# 队伍着色：递归遍历，保留纹理，用 albedo_color 做色调
func _apply_team_tint(entity: GameEntity, tint: Color):
	_tint_recursive(entity, tint)

func _print_mesh_info(node: Node, depth: int):
	for child in node.get_children():
		var indent = "  ".repeat(depth)
		if child is MeshInstance3D and child.mesh:
			var mat = child.get_active_material(0)
			var has_tex = mat and "albedo_texture" in mat and mat.albedo_texture != null
			print(indent + "[Mesh] name=%s alb=%s tex=%s" % [child.name, str(mat.albedo_color), str(has_tex)])
			var vc = child.mesh.get("vertex_color_array") if "vertex_color_array" in child.mesh else "n/a"
			print(indent + "[Mesh] name=%s surf=%d has_tex=%s vc=%s" % [child.name, child.mesh.get_surface_count(), str(has_tex), str(vc != null and vc != "n/a")])
		else:
			print(indent + "[Node] name=%s type=%s" % [child.name, child.get_class()])
		_print_mesh_info(child, depth+1)

func _count_meshes(node: Node) -> int:
	var c = 0
	for child in node.get_children():
		if child is MeshInstance3D and child.mesh: c += 1
		c += _count_meshes(child)
	return c

func _tint_recursive(node: Node, tint: Color):
	for child in node.get_children():
		if child is MeshInstance3D and child.mesh:
			for si in child.mesh.get_surface_count():
				var src = child.get_active_material(si)
				
				if src and "albedo_color" in src:
					var dup = src.duplicate()
					
					dup.albedo_color = src.albedo_color.lerp(tint, 0.5)
					child.set_surface_override_material(si, dup)
		_tint_recursive(child, tint)

func _update_entity_animation(entity: GameEntity):
	if not entity.has_meta("_model_instance"): return
	var model = entity.get_meta("_model_instance")
	var ap = model.get_node_or_null("AnimationPlayer") as AnimationPlayer
	if not ap: return
	var anim = ""
	var is_animal = entity.get("_animal_type") != "" and entity.get("_animal_type") != null
	if entity.health <= 0:
		anim = "die"
	elif entity.current_order == "attack":
		anim = "attack-melee-left"
	elif entity.current_order == "move" or entity.current_order == "deliver":
		anim = "walk" if is_animal else "walk"
	else:
		anim = "idle" if is_animal else "idle"
	if anim != "" and ap.has_animation(anim) and ap.current_animation != anim:
		ap.play(anim)
		

func _enable_vertex_colors(node: Node):
	for child in node.get_children():
		if child is MeshInstance3D and child.mesh:
			for si in child.mesh.get_surface_count():
				var m = child.get_active_material(si)
				if m and "vertex_color_use_as_albedo" in m:
					var dup = m.duplicate()
					dup.vertex_color_use_as_albedo = true
					child.set_surface_override_material(si, dup)
		_enable_vertex_colors(child)

func spawn_entity(config: Dictionary, team: int, pos: Vector3, level: int = 1) -> GameEntity:
	if not entities or config.is_empty(): return null

	# 深拷贝配置，避免建筑之间共享生产列表等可变数据
	var cfg = config.duplicate(true)

	var entity: GameEntity
	match cfg.type:
		0: entity = WorldResource.new()
		1: entity = Building.new()
		2: entity = Army.new()

	cfg["level"] = level
	cfg["team"] = team
	entities.add_child(entity)
	entity.setup(cfg)
	# 尝试加载3D模型
	var model_loaded = _apply_entity_model(entity)
	# 队伍色着色：非资源、非中立实体
	if entity.entity_type != 0 and entity.team != RTSConfig.Team.NEUTRAL:
		var tint = Color(0.3, 0.6, 1.0) if team == RTSConfig.Team.BLUE else Color(1.0, 0.4, 0.4)
		if entity.owner_peer_id != -1 and _player_colors.has(entity.owner_peer_id):
			var pc = _player_colors[entity.owner_peer_id]
			tint = Color(0.2 + pc.r * 0.8, 0.2 + pc.g * 0.8, 0.2 + pc.b * 0.8)
		_apply_team_tint(entity, tint)
	# 资源需要 setup 后再重建 visual
	if entity.entity_type == 0 and not model_loaded and entity.has_method("_create_visual"):
		entity._create_visual()
	entity.global_position = pos
	# 特定建筑旋转90度
	if entity.entity_id in [22, 27, 28]: entity.rotation.y = deg_to_rad(90)
	mark_entity_cache_dirty()

	# 地面高度修正
	if $Map:
		var h = $Map.get_height_at(pos)
		entity.global_position.y = h

	# 人口管理
	if entity is Army:
		if entity.entity_id < 60:  # 动物不占人口
			increase_population(team, 1)
		elif entity is Building:
			if entity.entity_id == 25 or entity.entity_id == 26:
	
				increase_population(team, 1)

	return entity

# ==================== 拆除建筑 ====================
func demolish_building(building: Building) -> bool:
	if not building or not is_instance_valid(building):
		return false
	if building.entity_id == 20:  # 不能拆除城堡
		return false
	if building.build_timer > 0 or building.upgrade_timer > 0:
		return false

	# 返还50%建造费用
	var base_cfg = EntityDatabase.get_config(building.entity_id)
	if not base_cfg.is_empty():
		var cost = base_cfg.get("cost", {})
		if building.owner_peer_id != -1:
			for res in cost:
				var refund = int(cost[res] * 0.5)
				add_resource_for(building.owner_peer_id, res, refund)
		else:
			for res in cost:
				var refund = int(cost[res] * 0.5)
				add_resource(res, refund, building.team)

	

	building.die()
	update_resource_limits(building.team)
	update_population_limits()
	return true

# ==================== 资源系统 ====================
func update_resource_limits(team: int):
	var limits = player_resource_limits if team == RTSConfig.Team.BLUE else enemy_resource_limits
	var castle = 0
	var warehouse = 0
	var shipyard = 0

	if not entities: return
	for e in entities.get_children():
		if e is Building and e.team == team and e.health > 0:
			if e.entity_id == 20: castle += 1
			elif e.entity_id == 22 and e.build_timer <= 0: warehouse += e.building_data.get("storage_bonus", 0)
			elif e.entity_id == 23: shipyard += 1

	limits.gold = 500 + castle*300 + warehouse
	limits.wood = 500 + castle*300 + warehouse
	limits.stone = 500 + castle*300 + warehouse
	limits.food = 500 + castle*300 + warehouse
	limits.oil = shipyard * 700

func add_resource(type: String, amount: int, team: int):
	var res = player_resources if team == RTSConfig.Team.BLUE else enemy_resources
	var lim = player_resource_limits if team == RTSConfig.Team.BLUE else enemy_resource_limits
	if res.has(type):
		res[type] = min(res[type] + amount, lim[type])

func deliver_resources(cargo: Dictionary, team: int):
	for t in cargo:
		add_resource(t, cargo[t], team)

func _input(event):
	# Don't process clicks on interactive UI panels
	if event is InputEventMouseButton:
		if has_node("UI/InfoPanel"):
			var ip = $UI/InfoPanel
			if ip.visible and ip.get_global_rect().has_point(event.position):
				return
		if has_node("UI/BuildMenu"):
			var bm = $UI/BuildMenu
			if bm.visible and bm.get_global_rect().has_point(event.position):
				return

	if build_mode:
		# 移动端触摸建造逻辑
		if event is InputEventScreenTouch:
			if event.pressed:
				# 手指按下
				_start_build_drag(event.position)
			else:
				# 手指抬起 → 尝试放置
				_update_build_preview_from_screen(event.position)
				_end_build_drag_and_place()
		elif event is InputEventScreenDrag and build_touch_active:
			# 手指拖动
			_update_build_preview_from_screen(event.position)
		else:
			_process_build_mode(event)
		return   # 建造模式下不再处理其他输入

func _unhandled_input(event):
	# Game clicks - only fires when no GUI Control consumed the event
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		_handle_right_click(event)


func _place_building_at(pos: Vector3):
	# 检查城堡等级解锁
	if not is_building_unlocked(selected_building_id): return

	var cfg = EntityDatabase.get_config(selected_building_id)
	if not cfg:
		return false

	# 资源检查
	var cost = cfg.get("cost", {})
	for k in cost:
		if player_resources[k] < cost[k]:
			_show_hud_alert({"gold":"黄金","wood":"木材","stone":"石头","food":"食物","oil":"石油"}.get(k, k) + "不足！", Color(1.0, 0.8, 0.1))
			return
	
	# 人口检查（防御塔）
	var is_defense = (selected_building_id == 25 or selected_building_id == 26)
	if is_defense and not can_train_unit(RTSConfig.Team.BLUE):
		return false
	
	# 扣资源
	for k in cost:
		player_resources[k] -= cost[k]

	# 生成建筑（设置所有权用于颜色）
	cfg["owner_peer_id"] = 1 if not is_online else player_owner_id
	var b = spawn_entity(cfg, RTSConfig.Team.BLUE, pos) as Building
	if b:
		b.start_construction(5.0, cfg)	
		AudioManager.play_sfx("build_place")
	# 注意：如果仍需要支持鼠标（PC调试），可以同时保留原鼠标处理
	# 但移动端主要用触摸，PC端继续用鼠标左键命令+右键选择
func _start_build_drag(screen_pos: Vector2):
	if not build_preview:
		return false
	build_touch_active = true
	build_drag_started = true
	# 立即更新一次预览位置
	_update_build_preview_from_screen(screen_pos)

func _update_build_preview_from_screen(screen_pos: Vector2):
	if not build_preview:
		return false
	var cam = get_viewport().get_camera_3d()
	if not cam:
		return false
	var from = cam.project_ray_origin(screen_pos)
	var to = from + cam.project_ray_normal(screen_pos) * 500
	var space = get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(from, to)
	var result = space.intersect_ray(query)
	if result:
		var pos = result.position
		# 网格对齐（如果你希望建筑对齐网格）
		pos.x = round(pos.x)
		pos.z = round(pos.z)
		pos.y = $Map.get_height_at(pos) if $Map else 0
		build_preview.global_position = pos
		build_preview.visible = true
		var valid = is_position_in_player_vision(pos) and _is_valid_build_position(pos)
		_tint_preview(build_preview, Color(0, 1, 0) if valid else Color(1, 0, 0))
	else:
		build_preview.visible = false

func _end_build_drag_and_place():
	if not build_touch_active:
		return false
	build_touch_active = false
	build_drag_started = false
	
	if build_preview and build_preview.visible:
		# 检查当前位置是否有效
		var pos = build_preview.global_position
		if is_position_in_player_vision(pos) and _is_valid_build_position(pos):
			_place_building_at(pos)
	# 无论是否放置成功，都退出建造模式
	_exit_build_mode()
func _handle_right_click(event):
	# Ctrl+右键 → 清除驻扎点
	if Input.is_key_pressed(KEY_CTRL):
		for u in selection.selected_entities:
			if u is Army and u.has_method("_clear_garrison"):
				u._clear_garrison()
			elif u is Building and u.has_method("_hide_garrison_marker"):
				u.garrison_point = Vector3.ZERO
				u._hide_garrison_marker()
		return false

	

	if selection.selected_entities.is_empty():
		_try_open_build_menu(event.position)
		return false

	# 右键空地 → 取消选择
	var hit = _get_entity_under_click(event.position)
	if not hit:
		selection._clear_selection()
		return false

	_command_selected_units(event.position)

func _set_garrison_for_selected(screen_pos: Vector2):
	var pos = _get_ground_pos(screen_pos)
	if pos == Vector3.ZERO: return
	for u in selection.selected_entities:
		if u is Army and u.has_method("_is_military") and u._is_military():
			u.set_garrison(pos)
		elif u is Building:
			u.garrison_point = pos
			if u.has_method("_show_garrison_marker"):
				u._show_garrison_marker()

func _get_ground_pos(screen_pos: Vector2) -> Vector3:
	var cam = get_viewport().get_camera_3d()
	if not cam: return Vector3.ZERO
	var from = cam.project_ray_origin(screen_pos)
	var to = from + cam.project_ray_normal(screen_pos) * 500
	var q = PhysicsRayQueryParameters3D.create(from, to)
	q.collide_with_bodies = true
	q.collision_mask = 2
	var res = get_world_3d().direct_space_state.intersect_ray(q)
	return res.position if res else Vector3.ZERO

func _get_entity_under_click(screen_pos: Vector2):
	var cam = get_viewport().get_camera_3d()
	if not cam: return null
	var from = cam.project_ray_origin(screen_pos)
	var to = from + cam.project_ray_normal(screen_pos) * 500
	var q = PhysicsRayQueryParameters3D.create(from, to)
	q.collide_with_bodies = true
	q.collision_mask = 1
	var res = get_world_3d().direct_space_state.intersect_ray(q)
	if res and res.collider is GameEntity:
		return res.collider
	return null



func _command_selected_units(screen_pos: Vector2):
	var cam = get_viewport().get_camera_3d()
	if not cam: return

	var from = cam.project_ray_origin(screen_pos)
	var to = from + cam.project_ray_normal(screen_pos) * 500
	var space = get_world_3d().direct_space_state
	var q = PhysicsRayQueryParameters3D.create(from, to)
	q.collide_with_bodies = true
	var res = space.intersect_ray(q)

	var target: GameEntity = null
	if res:
		if res.collider is GameEntity:
			target = res.collider
		elif res.collider.has_meta("entity_root"):
			target = res.collider.get_meta("entity_root")
	var pos = res.position if res else _ray_plane_intersection(from,to,Vector3.ZERO,Vector3.UP)

	for u in selection.selected_entities:
		if is_instance_valid(u) and u is Army:
			if target:
				if target is WorldResource:
					# 只有农民(10)、采集船(14)、动物才能采集资源
					if u.entity_id == 10 or u.entity_id == 14 or u.get("_animal_type") != "":
						u.gather_at(target)
					else:
						u.attack_move_to(target.global_position)
				elif target.team != u.team:
					u.attack_target(target)
				elif u.entity_id >= 46 and u.entity_id <= 50 and target is Building:
					u._garrison_target_id = target.get_instance_id()
					u.move_to(target.global_position)
				else:
					u.move_to(target.global_position)
			else:
				u.move_to(pos)

func _try_open_build_menu(screen_pos: Vector2):
	selection.selected_entities.clear()
	var cam = get_viewport().get_camera_3d()
	if not cam: return
	var from = cam.project_ray_origin(screen_pos)
	var to = from + cam.project_ray_normal(screen_pos)*500
	var space = get_world_3d().direct_space_state
	var res = space.intersect_ray(PhysicsRayQueryParameters3D.create(from,to))
	if res and is_position_in_player_vision(res.position):
		_show_build_menu(res.position)

func _set_rally_point_by_click(screen_pos: Vector2):
	var cam = get_viewport().get_camera_3d()
	if not cam: return
	var from = cam.project_ray_origin(screen_pos)
	var to = from + cam.project_ray_normal(screen_pos)*500
	var res = get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(from,to))
	if res:
		execute_rally(res.position)

func is_position_in_player_vision(world_pos: Vector3) -> bool:
	if not entities: return false
	for e in entities.get_children():
		if e is GameEntity and e.team == RTSConfig.Team.BLUE and e.health>0:
			if e.global_position.distance_to(world_pos) <= e.vision_range:
				return true
	return false

# ==================== 建造系统 ====================
func _process_build_mode(event):
	if event is InputEventMouseMotion:
		_update_build_preview(event.position)
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_place_building()
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			_exit_build_mode()

func _update_build_preview(screen_pos: Vector2):
	var cam = get_viewport().get_camera_3d()
	if not cam or not build_preview: return

	var from = cam.project_ray_origin(screen_pos)
	var to = from + cam.project_ray_normal(screen_pos)*500
	var res = get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(from,to))

	if res:
		var pos = res.position
		pos.x = round(pos.x)
		pos.z = round(pos.z)
		pos.y = $Map.get_height_at(pos) if $Map else 0
		build_preview.global_position = pos
		build_preview.visible = true

		var valid = is_position_in_player_vision(pos) and _is_valid_build_position(pos)
		_tint_preview(build_preview, Color(0, 1, 0) if valid else Color(1, 0, 0))
	else:
		build_preview.visible = false

func _is_valid_build_position(pos: Vector3) -> bool:
	# Cannot build near enemy units (10 unit radius)
	for e in entities.get_children():
		if e is GameEntity and e.team != RTSConfig.Team.BLUE and e.team != RTSConfig.Team.NEUTRAL and e.health > 0:
			if e.global_position.distance_to(pos) < 10.0:
				return false
	var t = get_terrain_at(pos)
	if selected_building_id == 23:
		if t != 0: return false
		var g = world_to_grid(pos)
		for dx in [-1,0,1]:
			for dy in [-1,0,1]:
				if dx==0 and dy==0: continue
				if $Map.get_terrain(g.x+dx, g.y+dy) == 2: return true
		return false
	else:
		# Cannot overlap existing buildings/entities
		for e in entities.get_children():
			if e is GameEntity and e.health > 0:
				if e.global_position.distance_to(pos) < (e.body_radius + 0.5):
					return false
		return t != 2

func _place_building():
	if not build_preview or not build_preview.visible: return
	var pos = build_preview.global_position
	if not is_position_in_player_vision(pos): return
	# Cannot build near enemies
	if not _is_valid_build_position(pos): return
	# 检查城堡等级解锁
	if not is_building_unlocked(selected_building_id): return

	var cfg = EntityDatabase.get_config(selected_building_id)
	if not cfg: return

	# 地形检查
	if selected_building_id != 23 and get_terrain_at(pos) == 2: return
	if selected_building_id == 23 and get_terrain_at(pos) != 0: return

	# 资源检查
	var cost = cfg.get("cost", {})
	for k in cost:
		if player_resources[k] < cost[k]:
			_show_hud_alert({"gold":"黄金","wood":"木材","stone":"石头","food":"食物","oil":"石油"}.get(k, k) + "不足！", Color(1.0, 0.8, 0.1))
			return

	# 人口（防御塔）
	var is_defense = (selected_building_id == 25 or selected_building_id == 26)
	if is_defense and not can_train_unit(RTSConfig.Team.BLUE): return

	# 扣费
	for k in cost:
		player_resources[k] -= cost[k]

	# 建造（设置所有权用于颜色）
	cfg["owner_peer_id"] = 1 if not is_online else player_owner_id
	var b = spawn_entity(cfg, RTSConfig.Team.BLUE, pos) as Building
	if b:
		b.start_construction(5.0, cfg)
		AudioManager.play_sfx("build_place")

	if not Input.is_key_pressed(KEY_SHIFT):
			_exit_build_mode()

func _exit_build_mode():
	build_mode = false
	build_touch_active = false
	build_drag_started = false
	selected_building_id = -1
	if build_preview:
		build_preview.queue_free()
		build_preview = null
	if current_build_menu:
		current_build_menu.queue_free()
		current_build_menu = null

func _show_build_menu(world_pos: Vector3):
	if current_build_menu: current_build_menu.queue_free()
	var menu = load("res://scripts/ui/BuildMenu.gd").new()
	menu.building_defs = building_defs
	menu.castle_level = get_player_castle_level()
	var cam = get_viewport().get_camera_3d()
	menu.position = cam.unproject_position(world_pos) - Vector2(65,15)
	menu.z_index = 10
	if has_node("UI"):
		$UI.add_child(menu)
	else:
		add_child(menu)
	current_build_menu = menu
	menu.building_selected.connect(_on_building_selected_for_build)

func _tint_preview(node: Node, color: Color):
	for child in node.get_children():
		if child is MeshInstance3D and child.mesh:
			for si in child.mesh.get_surface_count():
				var existing = child.get_surface_override_material(si)
				if existing and "albedo_color" in existing:
					existing.albedo_color = existing.albedo_color.lerp(color, 0.5)
					continue
				var src = child.get_active_material(si)
				if src and "albedo_color" in src:
					var m = src.duplicate()
					m.albedo_color = src.albedo_color.lerp(color, 0.5)
					child.set_surface_override_material(si, m)
		_tint_preview(child, color)

func _on_building_selected_for_build(building_id: int):
	selected_building_id = building_id
	build_mode = true
	var cfg = EntityDatabase.get_config(building_id)
	if not cfg: return

	# 加载建筑3D模型作为预览
	var model_path = RTSConfig.get_entity_model(building_id)
	if model_path != "" and ResourceLoader.exists(model_path):
		var s = load(model_path)
		if s: build_preview = s.instantiate()
	if not build_preview:
		build_preview = MeshInstance3D.new()
		build_preview.mesh = BoxMesh.new()
		build_preview.mesh.size = Vector3(cfg.body_radius*2, cfg.body_radius*1.5, cfg.body_radius*2)
	# 缩放预览模型匹配实际大小
	var target_size = cfg.body_radius * 2.0
	var aabb = _get_model_aabb(build_preview)
	var current_size = max(aabb.size.x, max(aabb.size.y, aabb.size.z))
	if current_size > 0.01: build_preview.scale = Vector3.ONE * (target_size / current_size)
	build_preview.visible = false
	# 预览旋转（与实际放置一致）
	if building_id in [22, 27, 28]: build_preview.rotation.y = deg_to_rad(90)
	_tint_preview(build_preview, Color(0, 1, 0))
	add_child(build_preview)

# ==================== 战争迷雾 ====================
func _init_fog_grid():
	explored_grid.clear()
	visible_grid.clear()
	for x in range(RTSConfig.MAP_SIZE):
		var col_exp = []
		var col_vis = []
		for y in range(RTSConfig.MAP_SIZE):
			col_exp.append(false)
			col_vis.append(false)
		explored_grid.append(col_exp)
		visible_grid.append(col_vis)

func _update_fog_visibility():
	if visible_grid.is_empty():
		_init_fog_grid()
	for x in range(RTSConfig.MAP_SIZE):
		for y in range(RTSConfig.MAP_SIZE):
			visible_grid[x][y] = false

	if not entities: return
	for e in entities.get_children():
		if e is GameEntity and e.team == RTSConfig.Team.BLUE and e.health > 0:
			var g = world_to_grid(e.global_position)
			var r = e.vision_range
			for dx in range(-r, r+1):
				for dy in range(-r, r+1):
					if dx*dx+dy*dy > r*r: continue
					var nx = g.x+dx
					var ny = g.y+dy
					if nx>=0 and nx<RTSConfig.MAP_SIZE and ny>=0 and ny<RTSConfig.MAP_SIZE:
						visible_grid[nx][ny] = true
						explored_grid[nx][ny] = true

func _apply_fog():
	if $Map and $Map.has_method("apply_fog"):
		$Map.apply_fog(explored_grid, visible_grid)

func _update_visibility():
	if not entities: return
	var players = []
	for e in entities.get_children():
		if e is GameEntity and e.team == RTSConfig.Team.BLUE and e.health > 0:
			players.append(e)

	for e in entities.get_children():
		if not (e is GameEntity): continue
		if e.team == RTSConfig.Team.BLUE:
			e.visible = true
			continue
		if e.team == RTSConfig.Team.NEUTRAL:
			var g = world_to_grid(e.global_position)
			e.visible = explored_grid[g.x][g.y]
			continue
		var seen = false
		for p in players:
			if p.global_position.distance_to(e.global_position) <= p.vision_range:
				seen = true
				break
		e.visible = seen

# ==================== 警报辅助 ====================
func _show_hud_alert(msg: String, color: Color = Color(1.0, 0.2, 0.1), _target_team: int = -1):
	if color == Color(1.0, 0.2, 0.1) or color == Color(1.0, 0.8, 0.1): AudioManager.play_sfx("alert")
	if has_node("UI"):
		var hud = $UI
		if hud and hud.has_method("show_alert_message"):
			hud.show_alert_message(msg, color)

func _is_alert_on_cooldown(key: String, duration: float = 5.0) -> bool:
	return _alert_cooldowns.has(key) and _alert_cooldowns[key] > 0

func _set_alert_cooldown(key: String, duration: float = 5.0):
	_alert_cooldowns[key] = duration

func _detect_enemy_near_base():
	if game_over: return
	var player_castle = get_player_castle()
	if not player_castle: return

	var threat_detected = false
	for e in entities.get_children():
		if e is Army and e.team == RTSConfig.Team.RED and e.health > 0:
			var dist = e.global_position.distance_to(player_castle.global_position)
			if dist < player_castle.vision_range * 1.2:
				threat_detected = true
				break

	if threat_detected and not _is_alert_on_cooldown("enemy_approach"):
		var loc_str = "(%d,%d)" % [int(player_castle.global_position.x), int(player_castle.global_position.z)]
		_show_hud_alert("敌军来袭！接近我方基地方向 %s" % loc_str, Color(1.0, 0.8, 0.1))
		_set_alert_cooldown("enemy_approach", 5.0)

# ==================== 每帧更新 ====================
var _limit_update_timer: float = 0.0
func _process(delta):
	game_time += delta
	if game_time_label:
		var mins = int(game_time / 60)
		var secs = int(game_time) % 60
		game_time_label.text = "%02d:%02d" % [mins, secs]

	# ---- 诊断 FPS + 物理心跳 ----
	if _fps_label and Engine.get_process_frames() % 10 == 0:
		_ensure_cache_fresh()
		var phys_frames = Engine.get_physics_frames()
		var phys_ok = (phys_frames != _diag_physics_heartbeat)
		if not phys_ok and _diag_physics_heartbeat > 0:
			_fps_label.add_theme_color_override("font_color", Color.RED)
			_fps_label.text = "🔴 物理卡死! FPS:%.0f | 实体:%d | 物理帧:%d(停滞)" % [
				Engine.get_frames_per_second(), _all_entities.size(), phys_frames
			]
		else:
			_fps_label.add_theme_color_override("font_color", Color.LIME_GREEN)
			_fps_label.text = "FPS:%.0f | 实体:%d(A%d B%d) | 物理:%d | 步骤:%d" % [
				Engine.get_frames_per_second(),
				_all_entities.size(), _armies.size(), _buildings.size(),
				phys_frames, _diag_step
			]
		_diag_physics_heartbeat = phys_frames
		_diag_step = (_diag_step + 1) % 1000

	# 定期刷新实体缓存 (0.5s间隔，避免过于频繁重建)
	_cache_refresh_timer -= delta
	if _cache_refresh_timer <= 0:
		_cache_refresh_timer = 0.5
		mark_entity_cache_dirty()

	# ---- 诊断：每5秒输出实体统计，检测泄漏 ----
	_diag_timer -= delta
	if _diag_timer <= 0:
		_diag_timer = 5.0
		_ensure_cache_fresh()
		var bullet_count = get_tree().get_nodes_in_group("bullets").size() if false else 0
		# 统计子弹（通过遍历所有节点）
		var bullets = 0
		for c in get_children():
			if c is Bullet: bullets += 1
		for c in entities.get_children():
			if c is Bullet: bullets += 1
		var delta_total = _all_entities.size() - _diag_last_total
		
		if _all_entities.size() > 500:
			print("[DIAG] ⚠️ 实体数量超过500，可能导致性能下降！")
		if _all_entities.size() > 1000:
			print("[DIAG] 🔴 实体数量超过1000，极可能导致卡死！")
		_diag_last_total = _all_entities.size()
		_diag_last_bullets = bullets

	fog_timer -= delta
	if fog_timer <= 0:
		fog_timer = 0.5
		_update_fog_visibility()
		_apply_fog()
		update_population_limits()

	# Update resource limits every second
	_limit_update_timer -= delta
	if _limit_update_timer <= 0:
		_limit_update_timer = 1.0
		update_resource_limits(RTSConfig.Team.BLUE)
		update_resource_limits(RTSConfig.Team.RED)
		if game_mode_2v2:
			for pid in ai_players.keys():
				update_resource_limits(ai_players[pid].team)

		var mm = $UI/Minimap
		if mm:
			mm.explored_grid = explored_grid
			mm.visible_grid = visible_grid

	# 更新警报冷却
	for key in _alert_cooldowns.keys():
		_alert_cooldowns[key] -= delta
		if _alert_cooldowns[key] <= 0:
			_alert_cooldowns.erase(key)

	# 敌军来袭检测
	_enemy_attack_cooldown -= delta
	if _enemy_attack_cooldown <= 0:
		_enemy_attack_cooldown = 5.0
		_detect_enemy_near_base()

	_update_visibility()

# ==================== 工具函数 ====================
func _ray_plane_intersection(ro, re, po, pn):
	var d = (re - ro).normalized()
	var den = d.dot(pn)
	if abs(den) < 0.0001: return Vector3.ZERO
	var t = (po - ro).dot(pn) / den
	return ro + d * t if t >= 0 else Vector3.ZERO

func world_to_grid(pos: Vector3) -> Vector2i:
	var half = RTSConfig.MAP_SIZE / 2.0
	var gx = clampi(round(pos.x + half), 0, RTSConfig.MAP_SIZE-1)
	var gy = clampi(round(pos.z + half), 0, RTSConfig.MAP_SIZE-1)
	return Vector2i(gx, gy)

func get_terrain_at(pos: Vector3) -> int:
	var g = world_to_grid(pos)
	return $Map.get_terrain(g.x, g.y) if $Map else -1

func get_terrain_at_grid(gx: int, gy: int) -> int:
	if not $Map or not $Map.has_method("get_terrain"):
		return -1
	return $Map.get_terrain(gx, gy)
# 将网格坐标 (gx, gy) 转换为世界坐标 (以地图中心为原点)
func grid_to_world(gx: int, gy: int) -> Vector3:
	return Vector3(gx - RTSConfig.MAP_SIZE / 2.0, 0, gy - RTSConfig.MAP_SIZE / 2.0)
# ==================== 快捷功能 ====================
func stop_all_gather():
	gather_paused = !gather_paused
	if gather_paused:
		# 暂停所有己方农民和采集船
		for entity in entities.get_children():
			if entity is Army and entity.team == RTSConfig.Team.BLUE and entity.health > 0:
				if entity.entity_id == 10 or entity.entity_id == 14:
					entity.current_target = null
					entity.current_order = ""
					entity.astar_path.clear()
					entity.is_attack_moving = false
	else:
		# 恢复：让空闲农民重新寻找资源
		for entity in entities.get_children():
			if entity is Army and entity.team == RTSConfig.Team.BLUE and entity.health > 0:
				if (entity.entity_id == 10 or entity.entity_id == 14) and entity.current_order == "":
					entity._find_nearest_resource()

var hold_position_active: bool = false

func toggle_hold_position():
	hold_position_active = !hold_position_active
	if not entities: return
	for e in entities.get_children():
		if e is Army and e.team == RTSConfig.Team.BLUE and e.health > 0:
			if e.entity_id != 10 and e.entity_id != 14:
				e.hold_position = hold_position_active

func set_rally_mode(active: bool):
	rally_mode = active
	var hud = $UI
	if hud and hud.has_method("update_rally_button_style"):
		hud.update_rally_button_style(active)

func execute_rally(target_pos: Vector3):
	if not entities: return
	for e in entities.get_children():
		if e is Army and e.team == RTSConfig.Team.BLUE and e.health > 0:
			if e.entity_id != 10 and e.entity_id != 14:
				e.move_to(target_pos)
	set_rally_mode(false)

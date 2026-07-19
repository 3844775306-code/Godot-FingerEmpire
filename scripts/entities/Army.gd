class_name Army
extends GameEntity

# ÒÆ¶¯ÊôÐÔ
var original_speed: float = 0.0

# ²É¼¯½»¸¶
var cargo: Dictionary = {"gold": 0, "wood": 0, "stone": 0, "food": 0, "oil": 0}
var max_cargo: int = 50
var gatherable_resources: Array = []             
var delivery_target: Building = null
var last_resource_target: WorldResource = null   

# ¹¥»÷ÒÆ¶¯
var is_attack_moving: bool = false
var attack_move_target: Vector3 = Vector3.ZERO

# Shift Á¬ÐøÖ¸Áî¶ÓÁÐ
var command_queue: Array = []           # Command queue [{type, target, pos, is_loop}]
var _loop_cmds: Array = []             # Extracted loop command block
var _loop_step: int = 0                # Current step in loop
var waypoint_markers: Array = []       # Waypoint markers
var _force_queue_next: bool = false    # Server-side flag to force queue mode
# Merchant vars (new system)
var _merchant_state: int = 0  # 0=SELECT,1=BUYING,2=TRAVEL_MARKET,3=SELLING,4=TRAVEL_HOME
var _merchant_resource: String = ""
var _merchant_own_castle: WeakRef = null
var _merchant_assigned_market: WeakRef = null
var _merchant_trade_volume: int = 0  # 本轮交易量（显示用）

# 驻扎系统
var garrison_point: Vector3 = Vector3.ZERO   # 驻扎点（零向量=无驻扎）
var _garrison_marker: MeshInstance3D = null  # 驻扎点标记
const NON_MILITARY_IDS = [10, 14, 43, 44, 45, 51, 46, 47, 48, 49, 50]

func _is_military() -> bool:
	return entity_id not in NON_MILITARY_IDS

# 动物系统
var _animal_type: String = ""         # cow/pig/sheep/fish
var _animal_retaliating: bool = false
var _animal_reproduce_timer: float = 45.0

var _animal_grow_timer: float = 0.0
var _animal_food_reward: int = 0

# Official vars
var _garrison_target_id: int = -1
var _garrison_building: WeakRef = null
var _salary_timer: float = 0.0
var _official_active: bool = true
var _visual_waypoints: Array = []      # Persisted waypoint positions for snapshot
var _current_move_queued: bool = false # Current move originated from queue

# ¾ö²ß½ÚÁ÷
var think_timer: float = 0.0
const THINK_INTERVAL: float = 0.3

# Åö×²·ÖÀë½ÚÁ÷
var collision_timer: float = 0.0
const COLLISION_INTERVAL: float = 0.15

# A* Ñ°Â·
var astar_path: Array = []                     
var astar_target: Vector3 = Vector3.ZERO       
var astar_recalc_timer: float = 0.0
const ASTAR_RECALC_INTERVAL: float = 2.0       

# ÐÂÔö£ºÈ±Ê§µÄ±äÁ¿£¨ÐÞ¸´±¨´í£©
  # Ô­µØ¹ÌÊØ
		# 0=Å©Ãñ / 1=Õ½¶·µ¥Î»


   # Â·¾¶ÖØËã¼ä¸ô
 # Ô­µØ·ÀÊØÄ£Ê½

# ÔÚ _process »ò _find_enemy_in_range Ïà¹ØµÄ×Ô¶¯×·»÷´úÂëÖÐ


func setup(config: Dictionary):
	super.setup(config)
	original_speed = speed
	gatherable_resources = config.get("gatherable_resources", [])
	max_cargo = config.get("max_cargo", 50)

	var lv = config.get("level", 1)
	level = lv
	var scale = 1.0 + (lv - 1) * 0.3
	max_health = int(max_health * scale)
	health = max_health
	attack = int(attack * scale)
	if armor > 0: armor = int(armor * scale)

	# ÉèÖÃÀàÐÍ£ºÅ©Ãñ=0£¬Õ½¶·µ¥Î»=1
	if entity_id in [10, 14]:
		target_type = 0
	else:
		target_type = 1
	_animal_type = config.get("animal_type", "")
	_animal_food_reward = config.get("food_reward", 0)
	call_deferred("_apply_nation_bonus")
func _apply_nation_bonus():
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if not bm or not bm.has_method("get_team_nation"):
		return
	var nation = bm.get_team_nation(team)
	if nation < 0:
		return
	var mults = NationBonuses.get_all_unit_multipliers(nation)
	if mults.has("health"):
		max_health = int(max_health * mults["health"])
		health = max_health
	if mults.has("attack"):
		attack = int(attack * mults["attack"])
	if mults.has("armor"):
		armor += int(mults["armor"])
	if mults.has("speed"):
		speed *= mults["speed"]
		original_speed = speed
	if mults.has("attack_speed"):
		attack_speed *= mults["attack_speed"]
	if mults.has("attack_range"):
		attack_range *= mults["attack_range"]
	if mults.has("vision_range"):
		vision_range *= int(mults["vision_range"])
	  # ²»Ö÷¶¯×·»÷£¬Ö»¹¥»÷½øÈëÉä³ÌµÄµÐÈË
	# Ô­ÓÐ×·»÷Âß¼­...
func _ready():
	super._ready()
	entity_type = 2
	can_move = true
	_create_visual()
	_add_selection_ring()
	_add_collision_shape()



# ----------------- ÊÓ¾õÓëÅö×² -----------------
func _create_visual():
	for child in get_children():
		if child is MeshInstance3D and child.name != "SelectionRing":
			child.queue_free()
	var mesh = MeshInstance3D.new()
	var capsule = CapsuleMesh.new()
	capsule.radius = body_radius * 0.8
	capsule.height = body_radius * 2.5
	mesh.mesh = capsule
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(mesh)
	var mat = StandardMaterial3D.new()
	# 从 battle_manager 获取玩家颜色（联机模式按玩家着色）
	var color = Color(0.3, 0.5, 1.0) if team == RTSConfig.Team.BLUE else Color(1.0, 0.25, 0.2)
	if is_inside_tree() and owner_peer_id != -1:
		var bm2 = get_tree().get_first_node_in_group("battle_manager")
		if bm2 and bm2.has_method("get_player_colors"):
			var pc = bm2.get_player_colors()
			if pc.has(owner_peer_id):
				color = pc[owner_peer_id]
	# 动物仿真颜色
	if _animal_type == "cow":
		color = Color(0.55, 0.35, 0.2)      # 棕色
	elif _animal_type == "pig":
		color = Color(0.95, 0.75, 0.8)      # 粉色
	elif _animal_type == "sheep":
		color = Color(0.9, 0.9, 0.85)       # 米白
	elif _animal_type == "fish":
		color = Color(0.5, 0.7, 0.85)       # 银蓝
	mat.albedo_color = color
	mesh.set_surface_override_material(0, mat)
	# 近战武器
	_add_weapon()

func _add_selection_ring():
	if not has_node("SelectionRing"):
		var ring = MeshInstance3D.new()
		ring.name = "SelectionRing"
		var ring_mesh = TorusMesh.new()
		ring_mesh.inner_radius = body_radius + 0.1
		ring_mesh.outer_radius = body_radius + 0.15
		ring.mesh = ring_mesh
		ring.position = Vector3(0, body_radius * 2.5 + 0.1, 0)
		ring.material_override = StandardMaterial3D.new()
		ring.material_override.albedo_color = Color.GREEN
		ring.visible = false
		add_child(ring)

func _add_weapon():
	var wpath = ""
	if entity_id == 35: wpath = "res://models/arena/weapon-spear.glb"
	elif entity_id == 12: wpath = "res://models/forest/weapon-bow.glb"
	elif entity_id in [36, 37, 38]: wpath = "res://models/arena/shield-round.glb"
	elif entity_id not in [18, 40] and attack_range <= 2.0 and target_type > 0:
		wpath = "res://models/arena/weapon-sword.glb"
	if wpath != "" and ResourceLoader.exists(wpath):
		var ws = load(wpath)
		if ws: var w = ws.instantiate(); if w: w.position = Vector3(0.3, body_radius * 0.6, 0); w.scale = Vector3.ONE * 0.8; add_child(w)
	# 重装单位额外加剑
	if entity_id in [36, 37, 38] and ResourceLoader.exists("res://models/arena/weapon-sword.glb"):
		var sw = load("res://models/arena/weapon-sword.glb")
		if sw: var s = sw.instantiate(); if s: s.position = Vector3(-0.3, body_radius * 0.6, 0); s.scale = Vector3.ONE * 0.8; add_child(s)
	# 骑兵坐骑
	var mpath = ""
	if entity_id in [15, 19, 38]: mpath = "res://models/pets/animal-dog.glb"
	elif entity_id == 34: mpath = "res://models/pets/animal-elephant.glb"
	if mpath != "" and ResourceLoader.exists(mpath):
		var ms = load(mpath)
		if ms: var m = ms.instantiate(); if m: m.position = Vector3(0, -body_radius * 0.1, -body_radius * 1.2); m.scale = Vector3.ONE * 0.9; add_child(m)
		body_radius *= 1.3

func _add_collision_shape():
	if not has_node("CollisionShape3D"):
		var col = CollisionShape3D.new()
		var shape = SphereShape3D.new()
		shape.radius = body_radius * 0.6
		col.shape = shape
		col.name = "CollisionShape3D"
		add_child(col)

# ----------------- Ö÷Ñ­»· -----------------
func _physics_process(delta):
	if health <= 0:
		die_official_cleanup()
		return
	
	# 动物行为
	if _animal_type != "":
		_process_animal(delta)
		return

	# Merchant/official special logic
	if entity_id in [43, 44, 45, 51]:
		_process_merchant(delta)
		return
	

	# ËÙ¶ÈÓëµØÐÎ
	var bm = get_tree().get_first_node_in_group("battle_manager") as RTSBattleManager
	var base_speed = original_speed
	if shock_timer > 0: speed = 0
	elif freeze_timer > 0: speed = max(base_speed * 0.5, 0.1)
	else: speed = base_speed
	
	if bm:
		var terrain = bm.get_terrain_at(global_position)
		# 涉水/航行音效
		if Engine.get_process_frames() % 30 == 0:
			var _in_water = (terrain == 2)
			var _was_in_water = has_meta("_was_in_water") and get_meta("_was_in_water")
			if _in_water != _was_in_water and not water_capable:
				_play_sfx_if_visible("swim")
			elif _in_water and water_capable and current_order == "move":
				_play_sfx_if_visible("sail")
			set_meta("_was_in_water", _in_water)
		if water_capable and terrain != 2:
			speed *= 0.3
		elif terrain == 2 and not water_capable:
			speed = speed / 3.0
		elif terrain == 1:
			speed *= 0.5
	if entity_id >= 46 and entity_id <= 50:
		_process_official(delta)
		# 官员如果正在前往驻军建筑，继续走移动逻辑
		if _garrison_target_id != -1 and current_order == "move":
			_process_action(delta, bm)
			_manual_move(delta)
			if collision_timer <= 0:
				collision_timer = 0.15
				_apply_passive_collision(delta)
			else:
				collision_timer -= delta
		return

	# Ä¿±êÓÐÐ§ÐÔ¼ì²é
		# Ä¿±êÓÐÐ§ÐÔ¼ì²é
	if current_target and not is_instance_valid(current_target):
		current_target = null
		current_order = ""
		is_attack_moving = false
		if target_type == 0:   # Å©ÃñÀà£¬Ñ°ÕÒÐÂ×ÊÔ´
			_find_nearest_resource()
		else:                  # Õ½¶·µ¥Î»£¬Á¢¿ÌËÑË÷µÐÈË
			_find_enemy_in_range()
	if current_order == "attack" or current_order == "gather" :
		if current_target == null:
			current_order = ""
			is_attack_moving = false
			if target_type == 0:   # Å©ÃñÀà£¬Ñ°ÕÒÐÂ×ÊÔ´
				_find_nearest_resource()
			else:                  # Õ½¶·µ¥Î»£¬Á¢¿ÌËÑË÷µÐÈË
				_find_enemy_in_range()
	# ÐÐÎª´¦Àí
	_process_action(delta, bm)

	# ÒÆ¶¯£¨ÊÖ¶¯ÉèÖÃ global_position£©
	_manual_move(delta)

	# Åö×²·ÖÀë
	collision_timer -= delta
	if collision_timer <= 0:
		collision_timer = COLLISION_INTERVAL
		_apply_passive_collision(delta)
		# ÊµÊ±Ñ°µÐ£ºÖ»Òª²»ÔÚ²É¼¯/½»¸¶/¹¥»÷ÒÆ¶¯£¬ÇÒÃ»ÓÐÄ¿±ê£¬¾ÍÁ¢¿ÌËÑË÷µÐÈË
	if target_type != 0 and current_target == null and current_order == "" and not is_attack_moving and entity_id not in [46,47,48,49,50]:
		_find_enemy_in_range()
	# ¾ö²ß½ÚÁ÷
	think_timer -= delta
	if think_timer <= 0:
		think_timer = THINK_INTERVAL
		_think(delta, bm)
		# ÔÚ _physics_process º¯ÊýµÄ×îºó
	
# ----------------- ÐÐÎª´¦Àí -----------------
func _process_action(delta, bm):
	# ½»¸¶×´Ì¬
	if current_order == "deliver" and delivery_target and is_instance_valid(delivery_target):
				# Ê¹ÓÃË®Æ½¾àÀë£¨ºöÂÔ¸ß¶È²î£©£¬±ÜÃâµØÐÎÆð·ü¸ÉÈÅ
		var h_diff = Vector2(delivery_target.global_position.x - global_position.x,
							delivery_target.global_position.z - global_position.z)
		var h_dist = h_diff.length() - body_radius - delivery_target.body_radius
		if h_dist <= 0.8:   # ·Å¿íÖÁ0.8Ã×£¬·ÀÖ¹¿¨±ßÔµ
			if bm and bm.has_method("deliver_player_resources") and owner_peer_id != -1:
				bm.deliver_player_resources(owner_peer_id, cargo)
			else:
				# 1v1 »ØÍË
				
				bm.deliver_resources(cargo, team)
			cargo.clear()
			delivery_target = null
			current_target = null
			current_order = ""
			if is_instance_valid(last_resource_target) and last_resource_target.health > 0:
				gather_at(last_resource_target)
			elif target_type == 0 and not _is_gather_paused():
				_find_nearest_resource()
			last_resource_target = null
		else:
			_set_move_target(delivery_target.global_position)
		return
		# Èç¹ûÊÇÒÆ¶¯ÃüÁîÇÒÒÑ½Ó½üÄ¿±ê£¬Çå³ýÃüÁî£¬×ªÎª¿ÕÏÐ
	if current_order == "move" and not is_attack_moving:
		if astar_target != Vector3.ZERO:
			var h_diff = Vector2(astar_target.x - global_position.x, astar_target.z - global_position.z)
			if h_diff.length() < 0.2:
				current_order = ""
				current_target = null
				astar_path.clear()
				astar_target = Vector3.ZERO
				# Pop completed visual waypoint
				if _current_move_queued and _visual_waypoints.size() > 0:
					_visual_waypoints.pop_front()
					_current_move_queued = false
				# Á¢¼´Ñ°µÐ
				if target_type != 0 and entity_id not in [46,47,48,49,50]:
					_find_enemy_in_range()
				# ²É¼¯µ¥Î»»áÓÉ¿ÕÏÐÂß¼­´¦Àí
	# ¹¥»÷ÒÆ¶¯
	if is_attack_moving:
		_find_enemy_in_range()
		if current_target and is_instance_valid(current_target):
			var dist = global_position.distance_to(current_target.global_position) - body_radius - current_target.body_radius
			if dist <= attack_range:
				_attack(current_target, delta)
			else:
				_set_move_target(current_target.global_position)
		else:
			if global_position.distance_to(attack_move_target) < 0.2:
				is_attack_moving = false
				attack_move_target = Vector3.ZERO
				if _current_move_queued and _visual_waypoints.size() > 0:
					_visual_waypoints.pop_front()
					_current_move_queued = false
			else:
				_set_move_target(attack_move_target)
		return

	# ²É¼¯ / ¹¥»÷
	if current_target and is_instance_valid(current_target):
		var target_radius = 0.0
		if current_target is GameEntity: target_radius = current_target.body_radius
		# Ö»¼ÆËãË®Æ½¾àÀë
		var h_diff = Vector2(global_position.x - current_target.global_position.x,
							global_position.z - current_target.global_position.z)
		var h_dist = h_diff.length() - body_radius - target_radius

		if current_target is WorldResource:
			if h_dist <= 0.5:
				_gather(current_target, delta)
			else:
				_set_move_target(current_target.global_position)
		elif current_target is GameEntity:
			if h_dist <= attack_range:
				_attack(current_target, delta)
			else:
				_set_move_target(current_target.global_position)
var loop_index:int = 0
# ----------------- ¾ö²ß£¨½ÚÁ÷£© -----------------
func _think(delta, bm):
	# 驻扎追击距离限制：敌人离驻扎点超过视野则放弃追击
	if garrison_point != Vector3.ZERO and current_target != null and current_order == "attack":
		if current_target.global_position.distance_to(garrison_point) > 10.0:
			current_target = null
			current_order = ""
			is_attack_moving = false
			move_to(garrison_point)
			return

	# 驻扎行为：空闲时追击视野内敌人，无敌人则返回驻扎点
	if garrison_point != Vector3.ZERO and current_target == null and current_order == "" and not is_attack_moving:
		var enemy = _find_nearest_enemy_in_vision()
		if enemy and is_instance_valid(enemy) and enemy.health > 0:
			if enemy.global_position.distance_to(garrison_point) <= 10.0:
				attack_target(enemy)
			else:
				var gdist = global_position.distance_to(garrison_point)
				if gdist > 2.0:
					move_to(garrison_point)
		else:
			var gdist = global_position.distance_to(garrison_point)
			if gdist > 2.0:
				move_to(garrison_point)
		return

	# If current order done and queue has commands, pop next
	if current_target == null and current_order == "" and not is_attack_moving and command_queue.size() > 0:
		var next_cmd = command_queue[0]
		var is_loop = next_cmd.get("is_loop", false)
		
		if not is_loop:
			
			_execute_command(next_cmd)
			_current_move_queued = true
			command_queue.pop_front()
			if waypoint_markers.size() > 0:
				var m = waypoint_markers.pop_front()
				if is_instance_valid(m): m.queue_free()
		else:
			
			next_cmd = command_queue[loop_index]
			_execute_command(next_cmd)
			loop_index += 1
			if loop_index>=command_queue.size() or not command_queue[loop_index].get("is_loop", false):
				loop_index = 0
		return

	if current_target == null and current_order == "" and not is_attack_moving:
		if _get_cargo_total() > 0:
			_return_to_deliver()
		elif target_type == 0:
			if not _is_gather_paused():
				_find_nearest_resource()
		else:
			_find_enemy_in_range()

# ----------------- Manual movement -----------------
func _manual_move(delta):
	if not can_move or speed <= 0:
		return
	if hold_position and target_type != 0:
		return
	if current_target and is_instance_valid(current_target):
		var target_radius = current_target.body_radius if current_target is GameEntity else 0.0
		var h_dist = Vector2(global_position.x - current_target.global_position.x, global_position.z - current_target.global_position.z).length() - body_radius - target_radius
		if current_target is WorldResource and h_dist <= 0.5:
			return
		elif current_target is GameEntity and h_dist <= attack_range:
			return
	var target_pos = _get_current_move_target()
	if target_pos == Vector3.ZERO:
		return
	# Godot内置导航
	if nav_agent and not nav_agent.is_navigation_finished():
		var np = nav_agent.get_next_path_position()
		var dir = (Vector3(np.x, 0, np.z) - Vector3(global_position.x, 0, global_position.z)).normalized()
		if dir.length() > 0.01:
			velocity.x = dir.x * speed; velocity.z = dir.z * speed; velocity.y = 0
			move_and_slide()
			look_at(Vector3(global_position.x + dir.x, global_position.y, global_position.z + dir.z), Vector3.UP)
	elif nav_agent and nav_agent.is_navigation_finished():
		var dir = (Vector3(target_pos.x, 0, target_pos.z) - Vector3(global_position.x, 0, global_position.z)).normalized()
		if dir.length() > 0.001:
			velocity.x = dir.x * speed; velocity.z = dir.z * speed; velocity.y = 0
			move_and_slide()
	var half_map = RTSConfig.MAP_SIZE / 2.0
	global_position.x = clamp(global_position.x, -half_map, half_map)
	global_position.z = clamp(global_position.z, -half_map, half_map)
	var bm = get_tree().get_first_node_in_group("battle_manager") as RTSBattleManager
	if bm:
		var map = bm.get_node("Map")
		if map and map.has_method("get_height_at"):
			global_position.y = map.get_height_at(global_position)
func _get_current_move_target() -> Vector3:
	if is_instance_valid(current_target):
		return current_target.global_position
	if is_attack_moving:
		return attack_move_target
	if current_order == "move":
		return astar_target
	return Vector3.ZERO

func _set_move_target(pos: Vector3):
	nav_agent.target_position = pos
# ==================== A* Ñ°Â·£¨¿ªÏúÓÅ»¯°æ£© ====================
# ÓÅ»¯Ïî£º
# 1. ×î´óËÑË÷½ÚµãÊýÏÞÖÆ£¨500 ½Úµã£©£¬·ÀÖ¹ÏÝÈë´ó¹æÄ£Ì½Ë÷
# 2. ¼òµ¥¼ÓÈ¨Æô·¢Ê½£¨1.2 ±¶£©£¬ÎþÉüÉÙÐí×îÓÅÐÔ»»È¡¸ü¿ìµÄÊÕÁ²ËÙ¶È
# 3. ½« open_list µÄÅÅÐò¸ÄÎª½öÔÚÐÂ½Úµã¼ÓÈëÊ±°´Ðè²åÈë£¬±ÜÃâÃ¿Ö¡È«ÅÅÐò
# 4. Ê¹ÓÃ Dictionary µÄ¿ìËÙ²éÕÒ

func _calculate_astar_path(target_pos: Vector3) -> Array:
	var bm = get_tree().get_first_node_in_group("battle_manager") as RTSBattleManager
	if not bm: return []
	var start = global_position
	var end = target_pos
	var start_tile = bm.world_to_grid(start)
	var end_tile = bm.world_to_grid(end)

	# Èç¹ûÆðµãµÈÓÚÖÕµã£¬Ö±½Ó·µ»Ø¿Õ
	if start_tile == end_tile:
		return []

	var open_list = []
	var closed_set = {}
	var g_score = {}
	var f_score = {}
	var came_from = {}
	var start_key = _tile_key(start_tile)
	g_score[start_key] = 0.0
	f_score[start_key] = _heuristic(start_tile, end_tile) * 1.2   # Ð¡·ù¼ÓÈ¨
	open_list.append({"tile": start_tile, "f": f_score[start_key]})

	var max_nodes = 500
	var nodes_explored = 0

	while open_list.size() > 0 and nodes_explored < max_nodes:
		# ÕÒµ½ F Öµ×îÐ¡µÄ½Úµã£¨ÊÖ¶¯²éÕÒ£¬±ÜÃâÅÅÐòÕû¸öÁÐ±í£©
		var best_idx = 0
		var best_f = open_list[0].f
		for i in range(1, open_list.size()):
			if open_list[i].f < best_f:
				best_f = open_list[i].f
				best_idx = i
		var current = open_list.pop_at(best_idx)
		var cur_tile: Vector2i = current.tile
		nodes_explored += 1

		if cur_tile == end_tile:
			return _reconstruct_path(came_from, cur_tile)

		var cur_key = _tile_key(cur_tile)
		closed_set[cur_key] = true

		# ¼ì²é 8 ¸öÁÚ¾Ó
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				if dx == 0 and dy == 0: continue
				var neighbor = Vector2i(cur_tile.x + dx, cur_tile.y + dy)

				# ±ß½ç¼ì²é
				if neighbor.x < 0 or neighbor.x >= RTSConfig.MAP_SIZE or neighbor.y < 0 or neighbor.y >= RTSConfig.MAP_SIZE:
					continue

				var neighbor_key = _tile_key(neighbor)
				if closed_set.has(neighbor_key): continue

				var terrain_cost = _get_terrain_cost(neighbor, bm)
				if terrain_cost >= 999.0: continue   # ²»¿ÉÍ¨ÐÐ

				var step_cost = terrain_cost * (1.4 if (dx != 0 and dy != 0) else 1.0)
				var tentative_g = g_score.get(cur_key, 9999.0) + step_cost

				if tentative_g < g_score.get(neighbor_key, 9999.0):
					came_from[neighbor_key] = cur_tile
					g_score[neighbor_key] = tentative_g
					f_score[neighbor_key] = tentative_g + _heuristic(neighbor, end_tile) * 1.2

					# ¼ì²éÊÇ·ñÒÑÔÚ open_list ÖÐ
					var found = false
					for item in open_list:
						if item.tile == neighbor:
							item.f = f_score[neighbor_key]
							found = true
							break
					if not found:
						open_list.append({"tile": neighbor, "f": f_score[neighbor_key]})

	# Èôµ½´ï×î´ó½ÚµãÊýÈÔÎ´ÕÒµ½£¬·µ»Ø¿Õ£¨µ¥Î»½«Ê¹ÓÃÖ±ÏßÒÆ¶¯£©
	return []

static func _tile_key(tile: Vector2i) -> String:
	return str(tile.x) + "," + str(tile.y)

func _get_terrain_cost(tile: Vector2i, bm: RTSBattleManager) -> float:
	var terrain = bm.get_terrain_at_grid(tile.x, tile.y)
	if water_capable:
		if terrain == 2: return 0.8
		else: return 999.0
	else:
		if terrain == 2: return 999.0
		elif terrain == 1: return 2.5
		else:
			# Check for enemy walls blocking the path
			var wp = Vector3(tile.x - RTSConfig.MAP_SIZE/2.0, 0, tile.y - RTSConfig.MAP_SIZE/2.0)
			for e in bm.entities.get_children():
				if e is Building and e.entity_id == 27 and e.health > 0 and e.team != team:
					var g = bm.world_to_grid(e.global_position)
					if g.x == tile.x and g.y == tile.y:
						return 999.0
			return 1.0

func _reconstruct_path(came_from: Dictionary, end_tile: Vector2i) -> Array:
	var path = []
	var current = end_tile
	path.push_front(Vector3(current.x - RTSConfig.MAP_SIZE/2.0, 0, current.y - RTSConfig.MAP_SIZE/2.0))
	for _i in range(200):
		var key = _tile_key(current)
		if not came_from.has(key): break
		current = came_from[key]
		path.push_front(Vector3(current.x - RTSConfig.MAP_SIZE/2.0, 0, current.y - RTSConfig.MAP_SIZE/2.0))
	return path



# ----------------- Åö×²·ÖÀë -----------------
func _apply_passive_collision(delta):
	var bm = _get_bm()
	var entities_nearby = bm.get_nearby_entities(global_position, 5.0) if bm else get_tree().get_nodes_in_group("entities")
	for entity in entities_nearby:
		if entity == self or not is_instance_valid(entity): continue
		if not (entity is GameEntity) or entity.health <= 0: continue
		if entity is WorldResource: continue
		if entity is Building and entity.team == team: continue  # 不阻挡己方/友方建筑

		var dist = global_position.distance_to(entity.global_position)
		var min_dist = body_radius + entity.body_radius
		if dist < min_dist and dist > 0.001:
			var overlap = min_dist - dist
			var push_dir = (global_position - entity.global_position).normalized()
			var push_s = 20.0 if entity is Building and entity.entity_id == 27 else 30.0 if entity is Building else 5.0
			global_position += push_dir * overlap * min(push_s * delta, 0.95)
		elif dist < 0.001:
			global_position += Vector3(randf_range(-0.2,0.2), 0, randf_range(-0.2,0.2))
# ----------------- ¹¥»÷ -----------------
func _attack(target, delta):

	# 攻击音效
	var _sfx = ""
	if entity_id in [12, 26, 33, 13]: _sfx = "arrow_shoot"
	elif entity_id in [16, 17]: _sfx = "cannon_fire" if entity_id == 16 else "treb_fire"
	elif entity_id in [15]: _sfx = "sword_swing"
	elif entity_id in [11, 30, 49, 18, 35]: _sfx = "heavy_swing"
	elif entity_id in [38, 40]: _sfx = "sword_swing"
	if _sfx != "": AudioManager.play_sfx_3d(_sfx, global_position, _get_cam_pos())

	if attack_timer > 0:
		attack_timer -= delta
		return

	# ½üÕ½·¶Î§ÉËº¦£¨³¤Ç¹±øµÈ£©
	if damage_radius > 0 and attack_range <= 2.0:
		var all_entities = get_tree().get_nodes_in_group("entities")
		for entity in all_entities:
			if entity == self or not (entity is GameEntity) or entity.health <= 0:
				continue
			if entity.team == team or entity is WorldResource:
				continue
			var dist = global_position.distance_to(entity.global_position) - body_radius - entity.body_radius
			if dist <= damage_radius:
				var _dmg_r = attack
				# 农民对动物伤害+900%
				if entity_id == 10 and entity.get("_animal_type") != null and str(entity.get("_animal_type")) != "":
					_dmg_r = attack * 10
				entity.take_damage(_dmg_r, self)
		attack_timer = attack_speed
		return

	# Ô¶³Ì¹¥»÷·¢Éä×Óµ¯
	if attack_range > 1.0 or damage_radius > 0:
		var multi = EntityDatabase.get_config(entity_id).get("multiple_process", [])
		var bullet_count = 1
		var spread_angle = 0.0
		if multi.size() >= 2:
			bullet_count = multi[1]
			if multi[0] != 0:
				spread_angle = deg_to_rad(multi[0])

		for i in range(bullet_count):
			var bullet = Bullet.new()
			bullet.team = team
			bullet.damage = attack
			bullet.speed = 8.0
			bullet.target = target
			bullet.source = self
			bullet.damage_radius = damage_radius

			var angle_offset = 0.0
			if bullet_count > 1 and spread_angle > 0:
				angle_offset = (i - (bullet_count - 1) / 2.0) * spread_angle / (bullet_count - 1)

			var spawn_dir = (target.global_position - global_position).normalized()
			var perpendicular = Vector3(spawn_dir.z, 0, -spawn_dir.x)
			var offset = perpendicular * sin(angle_offset) * 0.3
			bullet.global_position = global_position + Vector3(0, body_radius * 2.5, 0) + offset

			get_tree().get_first_node_in_group("battle_manager").add_child(bullet)
	else:
		var _dmg_m = attack
		# 农民对动物伤害+900%
		if entity_id == 10 and target.get("_animal_type") != null and str(target.get("_animal_type")) != "":
			_dmg_m = attack * 10
		target.take_damage(_dmg_m, self)

	attack_timer = attack_speed

# ----------------- ²É¼¯ -----------------
func _gather(resource_node: WorldResource, delta):
	if gather_timer <= 0:
		var res_type = resource_node.resource_type
		if gatherable_resources.size() > 0 and not res_type in gatherable_resources:
			return
		var amount = attack
		var bm = get_tree().get_first_node_in_group("battle_manager")
		if bm and bm.has_method("get_team_nation"):
			var nation = bm.get_team_nation(team)
			amount = int(amount * NationBonuses.get_gather_mult(nation, res_type))
		if _get_cargo_total() + amount > max_cargo:
			_return_to_deliver()
			return
		resource_node.take_damage(amount, self)
		cargo[res_type] = cargo.get(res_type, 0) + amount
		gather_timer = 1.0
	gather_timer -= delta

func _get_cargo_total() -> int:
	var total = 0
	for v in cargo.values(): total += v
	return total

func _return_to_deliver():
	var target = find_delivery_point()
	if target:
		if is_instance_valid(current_target) and current_target is WorldResource :
			last_resource_target = current_target
		delivery_target = target
		current_target = target
		current_order = "deliver"

# ----------------- Ñ°ÕÒ½»¸¶µã -----------------
func find_delivery_point() -> Building:
	var best: Building = null
	var best_dist = vision_range*10
	for entity in get_tree().get_nodes_in_group("entities"):
		if entity is Building and entity.team == team and entity.health > 0:
			if cargo.get("oil", 0) > 0:
				if entity.entity_id == 23:   # ´¬Îë
					var dist = global_position.distance_to(entity.global_position)
					if dist < best_dist: best_dist = dist; best = entity
			else:
				if entity.entity_id == 20 or entity.entity_id == 22:  # ³Ç±¤or²Ö¿â
					var dist = global_position.distance_to(entity.global_position)
					if dist < best_dist: best_dist = dist; best = entity
	return best

# ----------------- Ñ°µÐ / Ñ°×ÊÔ´ -----------------
func _find_nearest_resource():
	var bm = _get_bm()
	if bm:
		var best = bm.get_nearest_resource(global_position, vision_range, gatherable_resources)
		if best: gather_at(best)
		return
	# 回退：如果没有 battle_manager，使用全量扫描
	var best_dist = vision_range
	var best_target: WorldResource = null
	for entity in get_tree().get_nodes_in_group("entities"):
		if entity is WorldResource and entity.health > 0:
			if gatherable_resources.size() > 0 and not entity.resource_type in gatherable_resources:
				continue
			var dist = global_position.distance_to(entity.global_position) - body_radius - entity.body_radius
			if dist < best_dist: best_dist = dist; best_target = entity
	if best_target: gather_at(best_target)

func _find_enemy_in_range():
	if entity_id in [46, 47, 48, 50]: return
	var best_dist = vision_range*1.2
	var best_target: GameEntity = null
	# 优先使用缓存查询
	var bm = _get_bm()
	if bm:
		var enemies = bm.get_nearby_enemies(global_position, vision_range, team)
		for entity in enemies:
			if entity == self or entity.health <= 0: continue
			if entity is WorldResource: continue
			if entity.get("_animal_type") != null and str(entity.get("_animal_type")) != "": continue
			var h_diff = Vector2(entity.global_position.x - global_position.x,
								entity.global_position.z - global_position.z)
			var dist = h_diff.length() - body_radius - entity.body_radius
			if dist <= vision_range and dist < best_dist:
				best_dist = dist
				best_target = entity
	else:
		# 回退：全量扫描
		for entity in get_tree().get_nodes_in_group("entities"):
			if entity == self or entity.health <= 0: continue
			if entity is WorldResource: continue
			if entity.team == team: continue
			if entity is Building and entity.team == team: continue
			if entity.get("_animal_type") != null and str(entity.get("_animal_type")) != "": continue
			var h_diff = Vector2(entity.global_position.x - global_position.x,
								entity.global_position.z - global_position.z)
			var dist = h_diff.length() - body_radius - entity.body_radius
			if dist <= vision_range and dist < best_dist:
				best_dist = dist
				best_target = entity
	if best_target:
		current_target = best_target
		current_order = "attack"
		is_attack_moving = false

# ----------------- Command interface (Shift queue) -----------------
func _should_queue() -> bool:
	if _force_queue_next:
		_force_queue_next = false
		return true
	if Input.is_key_pressed(KEY_SHIFT): return true
	#if current_order != "": return true
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if bm and bm.has_method("get_mp_shift") and bm.get_mp_shift(): return true
	return false

func _queue_command(cmd: Dictionary):
	cmd["is_loop"] = false
	var q = _should_queue()
	if q:
		command_queue.append(cmd)
		var wp = _cmd_position(cmd)
		if wp != Vector3.ZERO:
			_visual_waypoints.append({"x": wp.x, "y": wp.y, "z": wp.z, "is_loop": false})
		_create_waypoint_marker(cmd.get("pos", Vector3.ZERO) if cmd.has("pos") else (cmd["target"].global_position if cmd.has("target") and is_instance_valid(cmd["target"]) else global_position))
		_detect_loops()
	else:
		_clear_command_queue()
		_execute_command(cmd)

func _clear_command_queue():
	command_queue.clear()
	_loop_cmds.clear()
	_loop_step = 0
	_visual_waypoints.clear()
	_current_move_queued = false
	_clear_waypoint_markers()

func _execute_command(cmd: Dictionary):
	
	match cmd["type"]:
		"move":
			current_target = null
			current_order = "move"
			is_attack_moving = false
			_set_move_target(cmd["pos"])
		"attack":
			current_target = cmd["target"]
			current_order = "attack"
			is_attack_moving = false
		"gather":
			current_target = cmd["target"]
			current_order = "gather"
			is_attack_moving = false
		"attack_move":
			attack_move_target = cmd["pos"]
			is_attack_moving = true

# ==================== Waypoint visualization ====================
# Waypoint visibility control
const WAYPOINT_LOOP_DIST = 0.3
var _waypoint_loop_start: int = -1
var _is_selected: bool = false

func show_waypoints():
	_is_selected = true
	for m in waypoint_markers:
		if is_instance_valid(m): m.visible = true

func hide_waypoints():
	_is_selected = false
	for m in waypoint_markers:
		if is_instance_valid(m): m.visible = false

func _create_waypoint_marker(pos: Vector3):
	var marker: Node3D
	if ResourceLoader.exists("res://models/castle/flag.glb"):
		var flag_scene = load("res://models/castle/flag.glb")
		if flag_scene: marker = flag_scene.instantiate()
	if not marker:
		marker = MeshInstance3D.new()
		var ring = TorusMesh.new()
		ring.inner_radius = 0.3; ring.outer_radius = 0.4
		marker.mesh = ring
		var mat = StandardMaterial3D.new()
		mat.albedo_color = Color(0, 1, 1, 0.8)
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		marker.material_override = mat
	marker.position = pos + Vector3(0, 0.2, 0)
	get_parent().add_child(marker)
	waypoint_markers.append(marker)
	# 编号标签
	var label = Label3D.new()
	label.text = str(waypoint_markers.size())
	label.position = Vector3(0, 0.55, 0)
	label.font_size = 24
	label.modulate = Color.CYAN
	marker.add_child(label)
	# Hide initially unless unit is selected
	marker.visible = _is_selected
	# Loop detection: check if this waypoint is near an earlier one
	_check_waypoint_loop(pos)

func _check_waypoint_loop(new_pos: Vector3):
	if _visual_waypoints.size() < 3: return
	var last_idx = _visual_waypoints.size() - 1
	var np = Vector3(new_pos.x, 0, new_pos.z)
	for i in range(last_idx - 1):
		var wpos = Vector3(_visual_waypoints[i]["x"], 0, _visual_waypoints[i]["z"])
		if wpos.distance_to(np) < WAYPOINT_LOOP_DIST:
			_waypoint_loop_start = i + 1
			for j in range(i + 1, last_idx + 1):
				_visual_waypoints[j]["is_loop"] = true
				if j < command_queue.size():
					command_queue[j]["is_loop"] = true
				if j < waypoint_markers.size():
					var m = waypoint_markers[j]
					if m is MeshInstance3D:
						var mat = m.material_override as StandardMaterial3D
						if mat: mat.albedo_color = Color(1.0, 0.55, 0.0, 0.9)
			break

const LOOP_PROXIMITY = 0.3

func _detect_loops():
	if command_queue.size() < 3: return
	for i in range(command_queue.size() - 1):
		var p1 = _cmd_position(command_queue[i])
		var p2 = _cmd_position(command_queue[i + 1])
		if p1 == Vector3.ZERO or p2 == Vector3.ZERO: continue
		var h1 = Vector3(p1.x, 0, p1.z); var h2 = Vector3(p2.x, 0, p2.z)
		if h1.distance_to(h2) < LOOP_PROXIMITY:
			_loop_cmds.clear()
			_loop_step = 0
			for j in range(i, command_queue.size()):
				command_queue[j]["is_loop"] = true
				_loop_cmds.append(command_queue[j])
				if j < _visual_waypoints.size():
					_visual_waypoints[j]["is_loop"] = true
			for j in range(i, min(command_queue.size(), waypoint_markers.size())):
				var m = waypoint_markers[j]
				if is_instance_valid(m):
					if m is MeshInstance3D:
						var mat = m.material_override as StandardMaterial3D
						if mat: mat.albedo_color = Color(1.0, 0.55, 0.0, 0.9)
			return


func get_waypoint_positions() -> Array:
	return _visual_waypoints.duplicate()

func _cmd_position(cmd: Dictionary) -> Vector3:
	if cmd.has("pos"): return cmd["pos"]
	if cmd.has("target") and is_instance_valid(cmd["target"]): return cmd["target"].global_position
	return Vector3.ZERO

func _clear_waypoint_markers():
	for m in waypoint_markers:
		if is_instance_valid(m):
			m.queue_free()
	waypoint_markers.clear()
	_waypoint_loop_start = -1
	current_target = null
	current_order = ""

func move_to(pos: Vector3):
	_queue_command({"type": "move", "pos": pos})

func attack_target(p_target: Node3D):
	_queue_command({"type": "attack", "target": p_target})

func gather_at(source: Node3D):
	_queue_command({"type": "gather", "target": source})

func attack_move_to(pos: Vector3):
	_queue_command({"type": "attack_move", "pos": pos})
# ----------------- ¹¥»÷¡¢²É¼¯¡¢Ñ°µÐµÈ£¨±£³Ö²»±ä£¬ÂÔ£© -----------------
# ÏÂÃæÊÇÄãÔ­ÓÐµÄ _attack, _gather, find_delivery_point, _find_nearest_resource, _find_enemy_in_range µÈº¯Êý
# ÓÉÓÚÆª·ù£¬´Ë´¦²»ÔÙÖØ¸´£¬ÇëÖ±½Ó¸´ÖÆÖ®Ç°Ìá¹©µÄÍêÕû°æ±¾ÖÐ¶ÔÓ¦µÄº¯Êý¼´¿É¡£
# ÔÚ Army.gd Ä©Î²Ìí¼Ó¸¨Öúº¯Êý



# ==================== Merchant Trading AI (集市系统) ====================

# 计算交易量

func _calc_trade_volume(_castle_level: int, distance: float) -> int:
	return mini(80 + 20 * _castle_level, int(distance * 2.0))

func _merchant_get_res(bm):
	if owner_peer_id != -1 and bm.has_method("get_resources_for"):
		return bm.get_resources_for(owner_peer_id)
	return bm.player_resources if team == RTSConfig.Team.BLUE else bm.enemy_resources

func _merchant_get_lim(bm):
	if owner_peer_id != -1 and bm.has_method("get_limits_for"):
		return bm.get_limits_for(owner_peer_id)
	return bm.player_resource_limits if team == RTSConfig.Team.BLUE else bm.enemy_resource_limits

func _merchant_deduct(bm, cost: Dictionary) -> bool:
	if owner_peer_id != -1 and bm.has_method("deduct_player_resources"):
		return bm.deduct_player_resources(owner_peer_id, cost)
	var res = bm.player_resources if team == RTSConfig.Team.BLUE else bm.enemy_resources
	for k in cost: if res.get(k,0) < cost[k]: return false
	for k in cost: res[k] -= cost[k]
	return true

func _merchant_add(bm, type: String, amount: int):
	if owner_peer_id != -1 and bm.has_method("add_resource_for"):
		bm.add_resource_for(owner_peer_id, type, amount)
		return
	var res = bm.player_resources if team == RTSConfig.Team.BLUE else bm.enemy_resources
	var lim = bm.player_resource_limits if team == RTSConfig.Team.BLUE else bm.enemy_resource_limits
	res[type] = min(res[type] + amount, lim.get(type, 99999))


func _process_merchant(delta):
	if _merchant_resource == "":
		match entity_id:
			43: _merchant_resource = "oil"
			44: _merchant_resource = "wood"
			45: _merchant_resource = "stone"
			51: _merchant_resource = "food"

	var bm = get_tree().get_first_node_in_group("battle_manager")
	if not bm: return

	var own = _merchant_own_castle.get_ref() if _merchant_own_castle else null
	if not own or not is_instance_valid(own):
		_find_own_castle()
		own = _merchant_own_castle.get_ref() if _merchant_own_castle else null
		if not own: return

	match _merchant_state:
		0:  # SELECT_MARKET
			var best_market = _find_best_market(bm)
			if not best_market: return
			var old = _merchant_assigned_market.get_ref() if _merchant_assigned_market else null
			if old and is_instance_valid(old) and old != best_market:
				old.assigned_merchants = max(0, old.assigned_merchants - 1)
			_merchant_assigned_market = weakref(best_market)
			best_market.assigned_merchants += 1
			_merchant_trade_volume = _calc_trade_volume(own.upgrade_level, global_position.distance_to(best_market.global_position))
			_merchant_state = 1

		1:  # BUYING at castle: spend resource, get gold
			var amt = _merchant_trade_volume
			var res = _merchant_get_res(bm)
			var lim = _merchant_get_lim(bm)
			amt = mini(amt, res.get(_merchant_resource, 0))
			amt = mini(amt, max(0, lim.get("gold", 99999) - res.get("gold", 0)))
			if amt <= 0: _merchant_state = 0; return
			_merchant_deduct(bm, {_merchant_resource: amt})
			_merchant_add(bm, "gold", int(amt * 1.2))
			_merchant_state = 2

		2:  # TRAVEL_TO_MARKET
			var market = _merchant_assigned_market.get_ref() if _merchant_assigned_market else null
			if not market or not is_instance_valid(market):
				_merchant_state = 0; return
			var d = global_position.distance_to(market.global_position)
			if d < 2.0: _merchant_state = 3
			else: global_position += (market.global_position - global_position).normalized() * speed * delta

		3:  # SELLING at market: spend gold, get resource
			var market2 = _merchant_assigned_market.get_ref() if _merchant_assigned_market else null
			if not market2 or not is_instance_valid(market2):
				_merchant_state = 0; return
			var amt2 = _merchant_trade_volume
			var res2 = _merchant_get_res(bm)
			var lim2 = _merchant_get_lim(bm)
			amt2 = mini(amt2, res2.get("gold", 0))
			amt2 = mini(amt2, max(0, lim2.get(_merchant_resource, 99999) - res2.get(_merchant_resource, 0)))
			if amt2 <= 0: _merchant_state = 4; return
			_merchant_deduct(bm, {"gold": amt2})
			_merchant_add(bm, _merchant_resource, int(amt2 * 0.8))
			_merchant_state = 4

		4:  # TRAVEL_HOME
			var d2 = global_position.distance_to(own.global_position)
			if d2 < 2.0: _merchant_state = 0
			else: global_position += (own.global_position - global_position).normalized() * speed * delta

func _on_merchant_die():
	var market = _merchant_assigned_market.get_ref() if _merchant_assigned_market else null
	if market and is_instance_valid(market):
		market.assigned_merchants = max(0, market.assigned_merchants - 1)

func _find_own_castle():
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if not bm: return
	for e in bm.entities.get_children():
		if e is Building and e.entity_id == 20 and e.health > 0 and e.team == team and e.build_timer <= 0:
			_merchant_own_castle = weakref(e)
			return

func _find_best_market(bm) -> Building:
	var best: Building = null; var best_count = 999
	for e in bm.entities.get_children():
		if e is Building and e.entity_id == 52 and e.health > 0 and e.team == team and e.build_timer <= 0:
			if e.assigned_merchants < best_count:
				best_count = e.assigned_merchants
				best = e
	return best

var _merchant_home_market
var _merchant_target_castle
func _find_home_market(bm):
	var best: Building = null; var best_dist = 9999.0
	for e in bm.entities.get_children():
		if e is Building and e.entity_id == 52 and e.health > 0 and e.team == team and e.build_timer <= 0:
			var d = global_position.distance_to(e.global_position)
			if d < best_dist: best_dist = d; best = e
	if best: _merchant_home_market = weakref(best)

func _find_target_castle(bm):
	for e in bm.entities.get_children():
		if e is Building and e.entity_id == 20 and e.health > 0 and e.team == team:
			_merchant_target_castle = weakref(e)
			return

func _process_official(delta):
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if not bm: return

	# Only garrisoned officials pay salary
	var gb = _garrison_building.get_ref() if _garrison_building else null
	var is_garrisoned = gb != null and is_instance_valid(gb)
	if is_garrisoned:
		_salary_timer -= delta
		if _salary_timer <= 0:
			_salary_timer = 5.0
			var cfg = EntityDatabase.get_config(entity_id)
			var salary = cfg.get("salary", 5)
			var academy_lv = _get_academy_level()
			var eff = 1.0 + academy_lv * 0.1
			salary = int(salary * eff)
			var paid = false
			if owner_peer_id != -1:
				paid = _merchant_deduct(bm, {"gold": salary})
			else:
				var res = bm.player_resources if team == RTSConfig.Team.BLUE else bm.enemy_resources
				if res.get("gold", 0) >= salary:
					res["gold"] -= salary
					paid = true
			if paid:
				if not _official_active:
					_official_active = true
			else:
				if _official_active:
					_official_active = false
					_ungarrison_official()
		if not _official_active:
			return

	# Check garrison target arrival (right-click on building command)
	if _garrison_target_id != -1:
		for e in bm.entities.get_children():
			if e is Building and e.get_instance_id() == _garrison_target_id:
				if global_position.distance_to(e.global_position) < 2.0:
					_do_garrison(e)
					_garrison_target_id = -1
					current_order = ""
					astar_target = Vector3.ZERO
				break

	# If garrisoned but moved far away, auto-ungarrison
	if is_garrisoned and global_position.distance_to(gb.global_position) > 3.0:
		_ungarrison_official()
		

	# Commander (ID 49): aura effect for nearby allies
	if entity_id == 49 and _official_active:
		var aura_r = 12.0
		for e in bm.entities.get_children():
			if e is Army and e != self and e.team == team and e.health > 0:
				if global_position.distance_to(e.global_position) <= aura_r:
					if not e.has_meta("_cmd_aura_%d" % get_instance_id()):
						e.set_meta("_cmd_aura_%d" % get_instance_id(), true)
						e.attack_speed *= 0.8

	# Clerk (ID 46): farmer gather bonus aura when garrisoned in warehouse
	if entity_id == 46 and is_garrisoned and _official_active:
		for e in bm.entities.get_children():
			if e is Army and e.entity_id == 10 and e.team == team and e.health > 0:
				if gb.global_position.distance_to(e.global_position) <= 15.0:
					if not e.has_meta("_clerk_bonus_%d" % get_instance_id()):
						e.set_meta("_clerk_bonus_%d" % get_instance_id(), true)
						e.attack_speed *= 0.8  # 25% faster gather (lower attack_speed = faster)

func _get_academy_level() -> int:
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if not bm: return 0
	for e in bm.entities.get_children():
		if e is Building and e.entity_id == 42 and e.team == team and e.health > 0:
			return e.upgrade_level
	return 0

func _do_garrison(building: Building):
	if not building or building.team != team: return
	if building.build_timer > 0: return
	
	for e in get_tree().get_nodes_in_group("entities"):
		if e is Army and e != self and e.entity_id >= 46 and e.entity_id <= 50:
			var ogb = e.get("_garrison_building")
			if ogb and ogb.get_ref() == building and e.entity_id == entity_id:
				return
	
	_garrison_building = weakref(building)
	building.set_meta("_orig_armor_%d" % entity_id, building.armor)
	building.set_meta("_orig_speed_%d" % entity_id, building.attack_speed)
	if not building.died.is_connected(_on_garrison_building_died):
		building.died.connect(_on_garrison_building_died.bind(get_instance_id()))
	# Move to top of building instead of hiding
	global_position = building.global_position + Vector3(0, building.body_radius * 1.8, 0)
	collision_layer = 0
	stop_movement()
	
	var academy_lv = _get_academy_level()
	var eff = 1.0 + academy_lv * 0.1
	if _has_chancellor_in(building):
		eff *= 2.0
	
	match entity_id:
		46:
			if building.entity_id == 22:
				building.set_meta("_orig_storage", building.building_data.get("storage_bonus", 500))
				building.building_data["storage_bonus"] = int(building.building_data.get("storage_bonus", 500) * (1.0 + 0.5 * eff))
		47:
			building.armor += int(80 * eff)
		48:
			for prod in building.production_list:
				prod["cooldown"] = prod["cooldown"] * max(0.1, 1.0 - 0.5 * eff)
		49:
			_garrison_building = null
			visible = true
			collision_layer = 1
			return
		50:
			# Chancellor: re-garrison all other officials to apply doubled bonuses
			for e in get_tree().get_nodes_in_group("entities"):
				if e is Army and e != self and e.entity_id >= 46 and e.entity_id <= 49:
					var ogb = e.get("_garrison_building")
					if ogb and ogb.get_ref() == building:
						e._ungarrison_official()
						e._do_garrison(building)

func _ungarrison_official():
	var building = _garrison_building.get_ref() if _garrison_building else null
	if building and is_instance_valid(building):
		var academy_lv = _get_academy_level()
		var eff = 1.0 + academy_lv * 0.1
		if _has_chancellor_in(building):
			eff *= 2.0
		
		match entity_id:
			46:
				if building.entity_id == 22 and building.has_meta("_orig_storage"):
					building.building_data["storage_bonus"] = building.get_meta("_orig_storage")
				# Remove clerk aura from farmers
				var my_id = get_instance_id()
				var bm = get_tree().get_first_node_in_group("battle_manager")
				if bm:
					for e in bm.entities.get_children():
						if e is Army and e.has_meta("_clerk_bonus_%d" % my_id):
							e.remove_meta("_clerk_bonus_%d" % my_id)
							e.attack_speed /= 0.8
			47:
				if building.has_meta("_orig_armor_%d" % entity_id):
					building.armor = building.get_meta("_orig_armor_%d" % entity_id)
			48:
				for prod in building.production_list:
					prod["cooldown"] = prod["cooldown"] / max(0.1, 1.0 - 0.5 * eff)
			50:
				for e in get_tree().get_nodes_in_group("entities"):
					if e is Army and e != self and e.entity_id >= 46 and e.entity_id <= 49:
						var ogb = e.get("_garrison_building")
						if ogb and ogb.get_ref() == building:
							e._ungarrison_official()
							e._do_garrison(building)
	
	_garrison_building = null
	# Move to just outside the building
	if building and is_instance_valid(building):
		global_position = building.global_position + Vector3(building.body_radius + body_radius + 1.0, 0, 0)
	collision_layer = 1

func _has_chancellor_in(building: Building) -> bool:
	for e in get_tree().get_nodes_in_group("entities"):
		if e is Army and e != self and e.entity_id == 50:
			var gb = e.get("_garrison_building")
			if gb and gb.get_ref() == building and e._official_active:
				return true
	return false

# Called when a garrisoned building dies - forces official to exit
func _on_garrison_building_died(official_id: int):
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if not bm: return
	for e in bm.entities.get_children():
		if e is Army and e.get_instance_id() == official_id:
			e._ungarrison_official()
			
			e.visible = true
			e.collision_layer = 1
			e._garrison_target_id = -1
			break

func stop_movement():
	current_order = ""
	current_target = null
	astar_path.clear()
	astar_target = Vector3.ZERO
	is_attack_moving = false

# Override die() for official cleanup
func die_official_cleanup():
	# Merchant cleanup
	if entity_id >= 43 and entity_id <= 45:
		_on_merchant_die()
	if entity_id >= 46 and entity_id <= 50:
		_ungarrison_official()
		# Remove commander aura from allies
		if entity_id == 49:
			var my_id = get_instance_id()
			var bm = get_tree().get_first_node_in_group("battle_manager")
			if bm:
				for e in bm.entities.get_children():
					if e is Army and e.has_meta("_cmd_aura_%d" % my_id):
						e.remove_meta("_cmd_aura_%d" % my_id)
						e.attack_speed /= 0.8
		# Remove clerk aura
		if entity_id == 46:
			var my_id2 = get_instance_id()
			var bm2 = get_tree().get_first_node_in_group("battle_manager")
			if bm2:
				for e in bm2.entities.get_children():
					if e is Army and e.has_meta("_clerk_bonus_%d" % my_id2):
						e.remove_meta("_clerk_bonus_%d" % my_id2)
						e.attack_speed /= 0.8


func _is_gather_paused() -> bool:
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if not bm: return false
	# Áª»ú°æÌá¹©ÁË get_gather_paused(team) ·½·¨
	if bm.has_method("get_gather_paused"):
		return bm.get_gather_paused(team)
	# µ¥»ú°æ¿ÉÄÜÊÇ²¼¶ûÖµ
	if bm.get("gather_paused") is bool:
		return bm.gather_paused
	return false

# ==================== Garrison System ====================
func _find_nearest_enemy_in_vision():
	var best_dist = vision_range
	var best_target = null
	for entity in get_tree().get_nodes_in_group("entities"):
		if entity == self or not is_instance_valid(entity) or entity.health <= 0: continue
		if entity is WorldResource: continue
		if entity.team == team: continue
		if not (entity is GameEntity): continue
		if entity.get("_animal_type") != null and str(entity.get("_animal_type")) != "": continue  # 不自动攻击动物
		var h_diff = Vector2(entity.global_position.x - global_position.x, entity.global_position.z - global_position.z)
		var dist = h_diff.length() - body_radius - entity.body_radius
		if dist <= vision_range and dist < best_dist:
			best_dist = dist
			best_target = entity
	return best_target

	garrison_point = Vector3.ZERO
	_hide_garrison_marker()

func _clear_garrison():
	garrison_point = Vector3.ZERO
	_hide_garrison_marker()

func set_garrison(pos: Vector3):
	if not _is_military(): return
	garrison_point = pos
	_show_garrison_marker()

func _show_garrison_marker():
	_hide_garrison_marker()
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if not bm: return
	_garrison_marker = _load_banner(garrison_point + Vector3(0, 0.1, 0))
	if _garrison_marker: bm.add_child(_garrison_marker)

func _hide_garrison_marker():
	if _garrison_marker and is_instance_valid(_garrison_marker):
		_garrison_marker.queue_free()
	_garrison_marker = null
var _animal_attacker :GameEntity = null
# ==================== Animal AI ====================
func _process_animal(delta):
	# 成长计时：升到5级后不可再成长
	_animal_grow_timer -= delta
	if _animal_grow_timer <= 0 and level < 5:
		var hp_pct = float(health) / float(max_health) if max_health > 0 else 1.0
		level += 1
		_animal_grow_timer = 20.0
		var scale = 1.0 + (level - 1) * 0.25
		max_health = int(max_health * scale / (1.0 + (level - 2) * 0.25)) if level > 1 else max_health
		health = int(max_health * hp_pct)
		attack = int(attack * 1.25) if level > 1 else attack
		speed = min(speed * 1.1, 3.0)

	# 反击
	if _animal_retaliating and _animal_attacker and is_instance_valid(_animal_attacker) and _animal_attacker.health > 0:
		var d = global_position.distance_to(_animal_attacker.global_position)
		if d <= attack_range + _animal_attacker.body_radius:
			if attack_timer <= 0:
				_animal_attacker.take_damage(attack, self)
				attack_timer = attack_speed
		else:
			global_position += (_animal_attacker.global_position - global_position).normalized() * speed * delta
		if attack_timer > 0: attack_timer -= delta
		return

	_animal_retaliating = false
	_animal_attacker = null

	# 繁殖：仅5级动物
	if level >= 5:
		_animal_reproduce_timer -= delta
		if _animal_reproduce_timer <= 0:
			_animal_reproduce_timer = 180.0
			# 统计同种动物总数，超过8只不再繁殖
			var same_type_count = 0
			for ent in get_tree().get_nodes_in_group("entities"):
				if ent is Army and ent.health > 0 and ent.get("_animal_type") == _animal_type:
					same_type_count += 1
			if same_type_count < 8:
				_spawn_baby_animal()

	

	# 探测人类 → 逃跑
	var human = _find_nearest_human()
	if human:
		var flee_dir = (global_position - human.global_position).normalized()
		var flee_speed = 0.5
		if _animal_type == "sheep" or _animal_type == "fish":
			flee_speed = 0.8
		# 避免跑进水里（鱼除外）
		var new_pos = global_position + flee_dir * flee_speed * delta
		if _animal_type != "fish":
			var bm = get_tree().get_first_node_in_group("battle_manager")
			if bm and bm.get_terrain_at(new_pos) == 2:
				flee_dir = -flee_dir  # 反向
				new_pos = global_position + flee_dir * flee_speed * delta
		global_position = new_pos
		return

	# 闲逛
	if randf() < 0.05:
		var wander = Vector3(randf_range(-2, 2), 0, randf_range(-2, 2))
		var new_pos = global_position + wander * speed * delta
		if _animal_type == "fish":
			var bm = get_tree().get_first_node_in_group("battle_manager")
			if bm and bm.get_terrain_at(new_pos) != 2:
				return  # 鱼不离开水
		elif not _animal_type == "fish":
			var bm = get_tree().get_first_node_in_group("battle_manager")
			if bm and bm.get_terrain_at(new_pos) == 2:
				return  # 陆地动物不进水
		global_position = new_pos

func _find_nearest_human():
	var best_dist = vision_range * 1.5
	var best = null
	for e in get_tree().get_nodes_in_group("entities"):
		if e == self or not is_instance_valid(e) or e.health <= 0: continue
		if not (e is Army): continue
		if e.team == RTSConfig.Team.NEUTRAL: continue
		if e.get("_animal_type") != null and str(e.get("_animal_type")) != "": continue
		if e.entity_id in [10, 14, 43, 44, 45, 46, 47, 48, 49, 50]: continue
		var dist = global_position.distance_to(e.global_position)
		if dist < best_dist:
			best_dist = dist
			best = e
	return best

func _spawn_baby_animal():
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if not bm: return
	var cfg = EntityDatabase.get_config(entity_id)
	if cfg.is_empty(): return
	var baby = bm.spawn_entity(cfg, team, global_position + Vector3(randf_range(-3,3), 0, randf_range(-3,3)), 1)
	if baby and baby is Army:
		baby.level = 1
		baby._animal_grow_timer = 20.0
		baby.max_health = int(max_health * 0.4)
		baby.health = baby.max_health
		baby.attack = max(1, int(attack * 0.4))
		baby.speed = speed * 0.8
		baby._animal_food_reward = int(_animal_food_reward * 0.4)

func _adult_grow():
	_animal_grow_timer = 0.0
	var cfg = EntityDatabase.get_config(entity_id)
	if not cfg.is_empty():
		max_health = cfg.get("max_health", max_health)
		health = max_health
		attack = cfg.get("attack", attack)
		_animal_food_reward = cfg.get("food_reward", _animal_food_reward)

class_name Building
extends GameEntity

var upgrade_level: int = 1                         # 当前等级
var upgrade_data: Array = []                       # 从配置加载的升级表
var max_upgrade_level: int = 5
var building_data: Dictionary = {}   # 保存原始配置
var build_timer: float = 0.0
var max_build_time: float = 0.0
var upgrade_timer: float = 0.0
var max_upgrade_time: float = 0.0
var assigned_merchants: int = 0                    # 集市分配的商人数量（仅entity_id==52时使用）
var garrison_point: Vector3 = Vector3.ZERO         # 新生产单位的驻扎点
var _garrison_marker: Node3D = null

# 士兵/农民进驻系统
var garrisoned_soldiers: Array = []      # Array of WeakRef — 进驻的单位
var garrison_max: int = 0                # 进驻上限（城堡10/箭塔炮塔5/其他0）

# Hell difficulty speed bonus

func start_construction(time: float, data: Dictionary):
	building_data = data
	var spd = 1.0
	if GameSettings.fast_mode: spd = 2.0
	if owner_peer_id >= 1000 and GameSettings.ai_difficulty >= GameSettings.AIDifficulty.HELL: spd *= 1.2
	max_build_time = data["max_health"] / 75.0 / spd
	build_timer = max_build_time
	max_health = 10
	health = 10
	attack = 0
	production_list = []
	# 建造期间不提供视野
	vision_range = 0
	if building_data.has("produces") and building_data["produces"] is Array:
		var full_produces = building_data["produces"]
		# 清除当前生产列表中所有由升级解锁的单位（保留初始已有的？这里统一刷新）
		
		for i in range(min(upgrade_level, full_produces.size())):
			var prod = full_produces[i].duplicate()
			if not production_list.has(prod):
				production_list.append(prod)
func _process(delta):
	super._process(delta)
	# 城墙动态朝向 + 拐角模型切换
	if entity_id == 27 and Engine.get_process_frames() % 30 == 0:
		var has_x_neg = false; var has_x_pos = false
		var has_z_neg = false; var has_z_pos = false
		var bm = get_tree().get_first_node_in_group("battle_manager")
		if bm:
			# Adjacent wall spacing = body_radius * 2.0; add 20% tolerance
			var half_len = body_radius * 2.0 * 1.2
			var half_wid = body_radius * 0.8
			for e in bm.entities.get_children():
				if e is Building and e.entity_id == 27 and e.health > 0 and e != self:
					var d = e.global_position - global_position
					if abs(d.z) <= half_len and abs(d.x) < half_wid:
						if d.z < 0: has_z_neg = true
						else: has_z_pos = true
					if abs(d.x) <= half_len and abs(d.z) < half_wid:
						if d.x < 0: has_x_neg = true
						else: has_x_pos = true
		var has_x = has_x_neg or has_x_pos
		var has_z = has_z_neg or has_z_pos
		var is_corner = has_x and has_z  # 拐角：两轴各有一个邻居
		if is_corner and not has_meta("_wall_is_corner"):
			set_meta("_wall_is_corner", true)
			_reload_wall_model(bm, "res://models/castle/wall-corner.glb")
		elif not is_corner and has_meta("_wall_is_corner") and get_meta("_wall_is_corner"):
			set_meta("_wall_is_corner", false)
			_reload_wall_model(bm, "res://models/castle/wall.glb")
		# 朝向：直墙/拐角自动判定
		if is_corner:
			if has_x_neg and has_z_neg: rotation.y = deg_to_rad(90 + 180)
			elif has_x_pos and has_z_neg: rotation.y = deg_to_rad(180 + 180)
			elif has_x_pos and has_z_pos: rotation.y = deg_to_rad(270 + 180)
			elif has_x_neg and has_z_pos: rotation.y = deg_to_rad(0 + 180)
		elif has_x_neg or has_x_pos: rotation.y = deg_to_rad(90)
		else: rotation.y = 0

	# 建造计时
	if build_timer > 0.0:
		build_timer -= delta
		if Engine.get_process_frames() % 40 == 0: AudioManager.play_sfx("build_loop")
		if build_timer <= 0.0:
			_finish_construction()

	# 升级计时
	if upgrade_timer > 0.0:
		upgrade_timer -= delta
		if upgrade_timer <= 0.0:
			_finish_upgrade()
			AudioManager.play_sfx("upgrade_done")

	# 生产计时
	if production_queue.size() > 0:
		#var bm = get_tree().get_first_node_in_group("battle_manager") as RTSBattleManager
		var can_produce = true
		var bm = _get_bm()
		if owner_peer_id == -1:
			can_produce = bm.can_train_unit(team)
		elif bm.has_method("can_player_train"):
			can_produce = bm.can_player_train(owner_peer_id)
		else:
			can_produce = bm.can_train_unit(team)  # 1v1 fallback
		if can_produce:
			production_timer -= delta
			if production_timer <= 0.0:
				print("[Spawn] queue=", production_queue.size(), " unit=", production_queue[0] if production_queue.size() > 0 else -1)
				_spawn_produced_unit()
		else:
			print("[Spawn] BLOCKED can_produce=false owner_peer_id=", owner_peer_id)
	else:
		production_timer = 0.0

	# 防御塔自动攻击
	if attack > 0:
		if not current_target or not is_instance_valid(current_target):
			_find_enemy_in_range()
		if current_target:
			var dist = global_position.distance_to(current_target.global_position) - body_radius - current_target.body_radius
			if dist <= attack_range:
				_attack(current_target, delta)
			else:
				current_target = null

func _find_enemy_in_range():
	var best = null
	var best_dist = attack_range + 1
	var bm = _get_bm()
	var candidates = bm.get_nearby_enemies(global_position, attack_range, team, owner_peer_id) if bm else get_tree().get_nodes_in_group("entities")
	for entity in candidates:
		if not (entity is Army) or entity.health <= 0: continue
		# 无外交管理器（非乱斗）→ 退化为纯队伍过滤；乱斗已由 get_nearby_enemies 按 owner 过滤
		if not bm:
			if entity.team == team: continue
		# Buildings don't attack animals
		if str(entity.get("_animal_type")) != "": continue
		var dist = global_position.distance_to(entity.global_position) - body_radius - entity.body_radius
		if dist <= attack_range and dist < best_dist:
			best_dist = dist
			best = entity
	if best:
		current_target = best

func _attack(target, delta):
	if attack_timer > 0:
		attack_timer -= delta
		return
	# 炮台：旋转朝向目标
	if entity_id == 64:
		var dir = target.global_position - global_position
		dir.y = 0
		if dir.length() > 0.01:
			rotation.y = atan2(dir.x, dir.z) + deg_to_rad(90)
	if damage_radius > 0 or attack_range > 1.0:
		var bullet = Bullet.new()
		bullet.team = team
		bullet.owner_peer_id = owner_peer_id
		bullet.damage = attack
		bullet.speed = 6.0
		bullet.target = target
		bullet.source = self
		bullet.damage_radius = damage_radius
		bullet.global_position = global_position + Vector3(0, body_radius * 1.5, 0)
		var bm = _get_bm()
		if bm:
			bm.add_child(bullet)
	else:
		target.take_damage(attack, self)
	attack_timer = attack_speed

func _reload_wall_model(bm, path):
	if not bm or not ResourceLoader.exists(path): return
	for child in get_children():
		if child is MeshInstance3D and child.name != "SelectionRing": child.queue_free()
	if has_meta("_model_instance"):
		var old = get_meta("_model_instance")
		if is_instance_valid(old): old.queue_free()
	var s = load(path)
	if s:
		var inst = s.instantiate()
		if inst:
			add_child(inst); set_meta("_model_instance", inst)
			var tint = Color(0.3, 0.6, 1.0) if team == RTSConfig.Team.BLUE else Color(1.0, 0.4, 0.4)
			bm._apply_team_tint(self, tint)

func _finish_construction():
	build_timer = 0.0
	AudioManager.play_sfx("build_done")
	# Set base stats first
	max_health = building_data["max_health"]
	health = max_health
	# 建造完成后恢复视野
	if building_data.has("vision_range"):
		vision_range = building_data["vision_range"]
	else:
		vision_range = 10.0
		melee_armor = building_data.get("melee_armor", building_data.get("armor", 0))
		shield_armor = building_data.get("shield_armor", building_data.get("armor", 0))
	attack = building_data.get("attack", 0)
	garrison_max = get_garrison_limit()
	# Inherit global building type level - apply bonuses on top of base
	var bm = get_tree().get_first_node_in_group("battle_manager") as RTSBattleManager
	if bm and bm.has_method("get_building_type_level"):
		var glv = bm.get_building_type_level(team, entity_id, owner_peer_id)
		if glv > upgrade_level:
			for lv in range(upgrade_level, glv):
				if lv <= upgrade_data.size():
					var ug = upgrade_data[lv - 1]
					max_health += ug.get("health_bonus", 0)
					health += ug.get("health_bonus", 0)
					melee_armor += ug.get("melee_armor_bonus", ug.get("armor_bonus", 0))
					shield_armor += ug.get("shield_armor_bonus", ug.get("armor_bonus", 0))
					attack += ug.get("attack_bonus", 0)
			upgrade_level = glv
			level = glv
			if building_data.has("produces") and building_data["produces"] is Array:
				var full = building_data["produces"]
				for i in range(min(glv, full.size())):
					var prod = full[i].duplicate()
					if not production_list.has(prod):
						production_list.append(prod)
	
	
	if bm :
		if owner_peer_id == -1:
			bm.update_resource_limits(team)
		elif bm.has_method("update_player_limits"):
			bm.update_player_limits(owner_peer_id)
			bm.update_player_population(owner_peer_id)

	# 建造完成警报（仅人类玩家自己，含位置和编队）
	if bm and bm.has_method("_show_hud_alert") and bm.is_human_owned(owner_peer_id, team):
		var group_str = ""
		var sm = bm.get_node_or_null("SelectionManager")
		if sm and sm.has_method("get_entity_groups"):
			var groups = sm.get_entity_groups(self)
			if groups.size() > 0:
				group_str = " [T%d]" % groups[0]
		var loc_str = "(%d,%d)" % [int(global_position.x), int(global_position.z)]
		bm._show_hud_alert("建造完成: %s%s %s" % [display_name, group_str, loc_str], Color(0.2, 1.0, 0.3), team)
	# 城堡建成立刻解锁民族兵种
	if entity_id == 53 and bm and bm.has_method("get_team_nation"):
		var nation = bm.get_team_nation(team)
		if nation >= 0:
			_unlock_nation_units(nation)

	
func is_under_construction() -> bool:
	return build_timer > 0.0

func _ready():
	super._ready()
	entity_type = 1
	collision_layer = 1
	collision_mask = 1  # 阻挡敌方单位通过
	can_move = false
	_add_selection_ring()
	_add_collision_shape()
	call_deferred("_apply_nation_start_bonus")
	
	
func _apply_nation_start_bonus():
	# 仅对主城(id=20)和城堡(id=53)应用
	if entity_id not in [20, 53] and entity_id != 53:
		return
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if not bm or not bm.has_method("get_team_nation"):
		return
	var nation = bm.get_team_nation(team)
	if nation < 0:
		return
	var start_lv = NationBonuses.get_castle_start_level(nation)
	if start_lv > 1 and upgrade_level == 1:
		upgrade_level = start_lv
		level = start_lv
		# 如果初始等级达到 3，立刻解锁特色兵种
		if upgrade_level >= 3 and entity_id == 53:
			_unlock_nation_units(nation)
# ====================== 修复：建筑选择环 水平贴地 ======================
func _add_selection_ring():
	if not has_node("SelectionRing"):
		var ring = MeshInstance3D.new()
		ring.name = "SelectionRing"
		var torus = TorusMesh.new()
		torus.inner_radius = body_radius + 0.2
		torus.outer_radius = body_radius + 0.35
		ring.mesh = torus

		# 水平圆环 + 贴地面
		ring.position.y = body_radius * 1.5 + 0.1
		#ring.rotation.x = deg_to_rad(90)

		var mat = StandardMaterial3D.new()
		mat.albedo_color = Color.GREEN
		mat.transparency = StandardMaterial3D.TRANSPARENCY_ALPHA
		ring.material_override = mat
		ring.visible = false
		add_child(ring)
		
func _add_collision_shape():
	if not has_node("CollisionShape3D"):
		var col = CollisionShape3D.new()
		var shape = BoxShape3D.new()
		shape.size = Vector3(body_radius*2, body_radius*1.5, body_radius*2)
		col.shape = shape
		col.name = "CollisionShape3D"
		add_child(col)

func setup(config: Dictionary):
	super.setup(config)  # 只调用一次
	upgrade_data = config.get("upgrades", [])
	max_upgrade_level = 1 + upgrade_data.size()

	# Store full produces list for later upgrades
	building_data = config.duplicate(true)
	# Filter production_list by current level
	var full_produces = config.get("produces", [])
	production_list = []
	for i in range(min(level, full_produces.size())):
		production_list.append(full_produces[i].duplicate())

	_create_visual()
	_update_collision_shape()

func _create_visual():
	for child in get_children():
		if child is MeshInstance3D and child.name != "SelectionRing":
			child.queue_free()

	var mesh = MeshInstance3D.new()
	var box = BoxMesh.new()
	var size_x = body_radius * 2.0
	var size_y = body_radius * 1.5
	var size_z = body_radius * 2.0
	box.size = Vector3(size_x, size_y, size_z)
	mesh.mesh = box
	mesh.position = Vector3(0, size_y / 2.0, 0)

	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color.WHITE
	mesh.set_surface_override_material(0, mat)
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(mesh)

func _update_collision_shape():
	if has_node("CollisionShape3D"):
		var col = $CollisionShape3D
		var shape = col.shape as BoxShape3D
		if shape:
			shape.size = Vector3(body_radius*2, body_radius*1.5, body_radius*2)

func get_castle_level() -> int:
	for entity in get_tree().get_nodes_in_group("entities"):
		if entity is Building and entity.team == team and entity.entity_id in [20, 53]:
			return entity.upgrade_level
	return 1

func can_upgrade() -> bool:
	if build_timer > 0: return false
	if upgrade_timer > 0: return false
	if upgrade_level >= max_upgrade_level: return false
	# Cannot upgrade beyond castle level (except castle itself)
	if entity_id not in [20, 53]:
		var bm = get_tree().get_first_node_in_group("battle_manager")
		if bm:
			var castle = null
			if bm.has_method("get_player_castle"): castle = bm.get_player_castle()
			elif bm.has_method("get_castle_by_team"): castle = bm.get_castle_by_team(team)
			if castle and upgrade_level >= castle.upgrade_level:
				return false
	return true

func try_produce(unit_id: int) -> bool:
	if build_timer > 0: return false
	return super.try_produce(unit_id)

func get_upgrade_cost() -> Dictionary:
	if upgrade_level <= upgrade_data.size():
		var cost = upgrade_data[upgrade_level - 1].get("cost", {}).duplicate()
		for k in cost: cost[k] = cost[k] * 2
		return cost
	return {}

func perform_upgrade(bm: RTSBattleManager) -> bool:
	if not can_upgrade(): return false
	var cost = get_upgrade_cost()
	var paid = false
	if owner_peer_id != -1 and bm.has_method("deduct_player_resources"):
		paid = bm.deduct_player_resources(owner_peer_id, cost)
	else:
		var res_dict = bm.player_resources if team == RTSConfig.Team.BLUE else bm.enemy_resources
		var can_pay = true
		for k in cost:
			if res_dict[k] < cost[k]: can_pay = false
		if can_pay:
			for k in cost: res_dict[k] -= cost[k]
			paid = true
	if not paid: return false
	# Start upgrade timer (time = total cost / 20 seconds)
	var total_cost = 0
	for k in cost: total_cost += cost[k]
	var spd2 = 1.0
	if GameSettings.fast_mode: spd2 = 2.0
	if owner_peer_id >= 1000 and GameSettings.ai_difficulty >= GameSettings.AIDifficulty.HELL: spd2 *= 1.2
	max_upgrade_time = max(total_cost / 20.0, 5.0) / spd2
	upgrade_timer = max_upgrade_time
	return true

func _finish_upgrade():
	upgrade_timer = 0.0
	var bm = get_tree().get_first_node_in_group("battle_manager") as RTSBattleManager
	if bm and bm.has_method("upgrade_building_type"):
		bm.upgrade_building_type(team, entity_id, self)

	# 升级完成警报（仅人类玩家自己，含位置和编队）
	if bm and bm.has_method("_show_hud_alert") and bm.is_human_owned(owner_peer_id, team):
		var group_str = ""
		var sm = bm.get_node_or_null("SelectionManager")
		if sm and sm.has_method("get_entity_groups"):
			var groups = sm.get_entity_groups(self)
			if groups.size() > 0:
				group_str = " [T%d]" % groups[0]
		var loc_str = "(%d,%d)" % [int(global_position.x), int(global_position.z)]
		bm._show_hud_alert("升级完成: %s%s %s" % [display_name, group_str, loc_str], Color(0.2, 1.0, 0.3), team)

func get_prod_cooldown(unit_id: int) -> float:
	var spd3 = 1.0
	if GameSettings.fast_mode: spd3 = 2.0
	if owner_peer_id >= 1000 and GameSettings.ai_difficulty >= GameSettings.AIDifficulty.HELL: spd3 *= 1.2
	for prod in production_list:
		if prod.unit_id == unit_id:
			return prod.cooldown / spd3
	return 1.0

	
	

# 添加特色兵种到生产列表（仅添加一次）
func _unlock_nation_units(nation: int):
	# 确保 NationData 已初始化
	NationData._static_init()
	var units = NationData.NATION_UNITS.get(nation, [])
	for u in units:
		# 跳过农民（id 10），因为城堡本来就能生产
		if u["unit_id"] == 10:
			continue
		# 检查是否已存在
		var exists = false
		for prod in production_list:
			if prod.unit_id == u["unit_id"]:
				exists = true
				break
		if not exists:
			production_list.append({"unit_id": u["unit_id"], "cooldown": u.get("cooldown", 5.0), "queue_limit": u.get("queue_limit", 5)})

# ==================== Garrison Marker ====================
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

# ==================== 士兵/农民进驻系统 ====================
func get_garrison_limit() -> int:
	match entity_id:
		53: return 10     # 城堡
		25, 26: return 5  # 箭塔、炮塔
		_: return 0        # 不可进驻

func can_garrison_soldier() -> bool:
	if build_timer > 0: return false
	if entity_id not in [25, 26, 53]: return false
	return _count_valid_garrisoned() < get_garrison_limit()

func get_garrison_count() -> int:
	return _count_valid_garrisoned()

func _count_valid_garrisoned() -> int:
	var cnt = 0
	var clean = []
	for ref in garrisoned_soldiers:
		if ref is WeakRef and ref.get_ref() and is_instance_valid(ref.get_ref()):
			cnt += 1
			clean.append(ref)
	# 清理无效引用
	if clean.size() != garrisoned_soldiers.size():
		garrisoned_soldiers = clean
	return cnt

func _add_soldier_to_garrison(army: Army) -> bool:
	if not can_garrison_soldier(): return false
	if _base_attack <= 0:
		_base_attack = building_data.get("attack", 0)
	garrisoned_soldiers.append(weakref(army))
	_recalc_garrison_attack()
	return true

func _remove_soldier_from_garrison(army: Army):
	var aid = army.get_instance_id()
	for i in range(garrisoned_soldiers.size() - 1, -1, -1):
		var ref = garrisoned_soldiers[i]
		if ref is WeakRef and ref.get_ref() and ref.get_ref().get_instance_id() == aid:
			garrisoned_soldiers.remove_at(i)
			break
	_recalc_garrison_attack()

func _recalc_garrison_attack():
	var cnt = _count_valid_garrisoned()
	if cnt > 0:
		attack = _base_attack * (1.0 + 0.5 * cnt)   # 每人 +50% 基础攻击
	else:
		attack = _base_attack if _base_attack > 0 else building_data.get("attack", 0)
		_base_attack = 0.0  # 重置，下次进驻时重新记录

func release_all_garrisoned():
	var bm = _get_bm()
	var map = bm.get_node_or_null("Map") if bm else null
	for ref in garrisoned_soldiers.duplicate():
		var unit = ref.get_ref() if ref is WeakRef else null
		if not unit or not is_instance_valid(unit): continue
		if unit.has_method("_exit_soldier_garrison"):
			var pos = _find_land_nearby(map)
			unit.global_position = pos
			unit._exit_soldier_garrison()
	garrisoned_soldiers.clear()
	_recalc_garrison_attack()

func _find_land_nearby(map) -> Vector3:
	for _attempt in range(20):
		var angle = randf() * TAU
		var radius = body_radius + randf() * 3.0
		var pos = global_position + Vector3(cos(angle) * radius, 0, sin(angle) * radius)
		if map and map.has_method("get_terrain_at"):
			if map.get_terrain_at(pos) == 0:  # 平原
				return pos
		else:
			return pos
	return global_position + Vector3(2, 0, 2)  # 兜底位置

func die():
	if _is_dead:
		return
	# 先释放所有进驻单位，再执行死亡逻辑
	release_all_garrisoned()
	super.die()

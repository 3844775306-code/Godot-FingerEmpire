
class_name GameEntity
extends CharacterBody3D

signal died

var entity_id: int = 0
var entity_type: int = 0        # 0=资源, 1=建筑, 2=军队
var team: int = 0
var display_name: String = ""
var level: int = 1
var hold_position: bool = false  
var max_health: float = 100.0
var health: float = 100.0
var melee_armor: float = 0.0       # 铠甲：抵挡近战攻击 (target_type=2)
var shield_armor: float = 0.0      # 盾牌：抵挡远程攻击 (target_type=3)
var attack: float = 0.0
var _last_damager: GameEntity = null
var attack_speed: float = 1.0
var attack_range: float = 1.0
var damage_radius: float = 0.0
var target_type: int = 2
var water_capable: bool = false
var _animal_is_baby: bool = false
var speed: float = 0.0
var body_radius: float = 0.5
var can_move: bool = false
var vision_range: float = 10.0

var gather_amount: float = 0.0
var regeneration_rate: float = 0.0

var production_list: Array = []
var production_timer: float = 0.0
var production_queue: Array = []

var attack_timer: float = 0.0
var gather_timer: float = 0.0
var current_target: Node3D = null
var current_order: String = ""
var nav_agent: NavigationAgent3D

var shock_timer: float = 0.0
var freeze_timer: float = 0.0
var owner_peer_id: int = -1
var piercing: bool = false                  # 长枪兵穿透（无视军队护甲）
var ignore_building_armor: bool = false     # 攻城车无视建筑护甲
var _base_attack: float = 0.0               # 驻军前原始攻击力（用于还原）
var _base_attack_speed: float = 0.0         # 驻军前原始攻速（攻城车专用）
var _base_speed: float = 0.0                # 驻军前原始移速（攻城车专用）

# 缓存的 BattleManager 引用 — 避免每帧场景树遍历
var _bm: RTSBattleManager = null
# 死亡幂等标记：围殴时同一帧/死亡动画期间的多次命中不能重复触发 died，
# 否则城堡计数的队伍会重复扣减，导致 2v2/3v3 提前判负
var _is_dead: bool = false

func _get_bm():
	if not is_instance_valid(_bm):
		_bm = get_tree().get_first_node_in_group("battle_manager") as RTSBattleManager
	return _bm

func _get_cam_pos() -> Vector3:
	var cam = get_viewport().get_camera_3d()
	return cam.global_position if cam else Vector3.ZERO

# 仅在玩家视野内播放音效
func _play_sfx_if_visible(key: String):
	var bm = _get_bm()
	if bm and bm.has_method("is_position_in_player_vision"):
		if bm.is_position_in_player_vision(global_position):
			AudioManager.play_sfx_3d(key, global_position, _get_cam_pos())
	else:
		AudioManager.play_sfx_3d(key, global_position, _get_cam_pos())

# 递归设置实体颜色
func apply_color(c: Color):
	_apply_color_recursive(self, c)

func _apply_color_recursive(node: Node, c: Color):
	for child in node.get_children():
		if child is MeshInstance3D:
			var mat = StandardMaterial3D.new()
			mat.albedo_color = c
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
			child.material_override = mat  # 覆盖所有表面
		_apply_color_recursive(child, c)

	# 原有属性赋值...

func _ready():
	add_to_group("entities")
	collision_layer = 1
	collision_mask = 0

func setup(config: Dictionary):
	entity_id = config.get("id", 0)
	entity_type = config.get("type", 2)
	team = config.get("team", 2)
	display_name = config.get("name", "")
	
	max_health = config.get("max_health", 100.0)
	health = max_health
	melee_armor = config.get("melee_armor", config.get("armor", 0))
	shield_armor = config.get("shield_armor", config.get("armor", 0))
	attack = config.get("attack", 0)
	attack_speed = config.get("attack_speed", 1.0)
	attack_range = config.get("attack_range", 1.0)
	damage_radius = config.get("damage_radius", 0.0)
	target_type = config.get("target_type", 2)
	water_capable = config.get("water_capable", false)
	speed = config.get("speed", 0.0)
	body_radius = config.get("body_radius", 0.5)
	can_move = config.get("can_move", false)
	vision_range = config.get("vision_range", 10.0)
	gather_amount = config.get("gather_amount", 0.0)
	regeneration_rate = config.get("regeneration_rate", 0.0)
	production_list = config.get("produces", [])
	collision_layer = 1
	collision_mask = 0
	owner_peer_id = config.get("owner_peer_id", -1)
	piercing = config.get("piercing", false)
	ignore_building_armor = config.get("ignore_building_armor", false)
	# 加入遍历分组 (Godot group)，避免每帧全量扫描 entities.get_children()
	if entity_type != 0 and vision_range > 0:
		add_to_group("vision_providers")
	if entity_type == 1:
		if entity_id == 20 or entity_id == 28:
			add_to_group("pop_buildings")
		if entity_id == 20 or entity_id == 22 or entity_id == 23:
			add_to_group("storage_buildings")
func _process(delta):
	if health <= 0:
		return
	if entity_type == 0 and regeneration_rate > 0:
		health = min(health + regeneration_rate * delta, max_health)
	
	if shock_timer > 0:
		shock_timer -= delta
	if freeze_timer > 0:
		freeze_timer -= delta
	# 模型动画（每30帧更新一次，资源跳过）
	if entity_type != 0 and Engine.get_process_frames() % 30 == 0:
		var bm = _get_bm()
		if bm and bm.has_method("_update_entity_animation"):
			bm._update_entity_animation(self)

func take_damage(amount: float, source: GameEntity = null):
	if _is_dead or health <= 0.0:
		return
	# Officials are immune while garrisoned
	if entity_id >= 46 and entity_id <= 50:
		var gb = get("_garrison_building")
		if gb and gb.get_ref():
			amount *=0.3
	var eff_armor: float = melee_armor
	if source:
		_last_damager = source
		# 动物被攻击后反击
		if self is Army and self.get("_animal_type") != "" and self.get("_animal_type") != null:
			self.set("_animal_retaliating", true)
			self.set("_animal_attacker", source)
			
		# 远程攻击(target_type=3) → 使用盾牌护甲
		if source.target_type == 3:
			eff_armor = shield_armor

		# 长枪兵无视军队护甲
		if source.piercing and self is Army:
			eff_armor = 0
		# 攻城车无视建筑护甲
		if source.ignore_building_armor and self is Building:
			eff_armor = 0
		# 农民减免50%来自动物的伤害
		if entity_id == 10 and source and source.get("_animal_type") != null and str(source.get("_animal_type")) != "":
			amount = amount * 0.7

		# 减法护甲：实际伤害 = max(攻击力 - 护甲, 1)
	var actual_damage = max(amount - eff_armor, 1.0)
	health -= actual_damage
	# 战斗统计：只记录对敌方军队/建筑造成的有效伤害
	if source and actual_damage > 0.0 and source.team != team and source.team != RTSConfig.Team.NEUTRAL and self.team != RTSConfig.Team.NEUTRAL and (self is Army or self is Building):
		var _stats_bm = _get_bm()
		if _stats_bm and _stats_bm.battle_stats:
			_stats_bm.battle_stats.record_damage(source.owner_peer_id, source.team, actual_damage)
	if source and source.attack_range <= 2.0 and actual_damage > 0 and not (self is WorldResource): _play_sfx_if_visible("sword_hit")
	# 战事警报：己方单位被攻击时通知小地图和屏幕提示
	var bm = get_tree().get_first_node_in_group("battle_manager")
	var _is_animal_attacker = source and source.get("_animal_type") != null and str(source.get("_animal_type")) != ""
	var _should_alert = (team == RTSConfig.Team.BLUE) and not _is_animal_attacker
	if bm and bm.get("is_online") == true:
		_should_alert = (team != RTSConfig.Team.NEUTRAL) and not _is_animal_attacker
	if _should_alert and actual_damage > 0:
		if bm:
			# 小地图警报闪光
			if bm.has_node("UI/Minimap"):
				var minimap = bm.get_node("UI/Minimap")
				if minimap and minimap.has_method("add_alert"):
					minimap.add_alert(global_position)
			# 屏幕中央字幕提示（智能分类+位置+编队）
			if bm.has_method("_is_alert_on_cooldown"):
				var cooldown_key = "entity_attacked_%d" % get_instance_id()
				if not bm._is_alert_on_cooldown(cooldown_key, 3.0):
					# 查询编队信息
					var group_str = ""
					var sm = bm.get_node_or_null("SelectionManager")
					if sm and sm.has_method("get_entity_groups"):
						var groups = sm.get_entity_groups(self)
						if groups.size() > 0:
							group_str = " [T%d]" % groups[0]
					# 位置信息
					var loc_str = "(%d,%d)" % [int(global_position.x), int(global_position.z)]
					var msg = ""
					if entity_id == 20:
						msg = "我方基地正遭受攻击！%s%s" % [loc_str, group_str]
					elif self is Building:
						msg = "%s正遭受攻击 %s%s" % [display_name, loc_str, group_str]
					else:
						msg = "我方%s正遭受攻击 %s%s" % [display_name, loc_str, group_str]
					bm._show_hud_alert(msg, Color(1.0, 0.2, 0.1), team)
					bm._set_alert_cooldown(cooldown_key, 3.0)
	# 乱斗 FFA 军事伤害背叛上报：军队对当前仍结盟的盟友造成军事伤害 → 揭发背叛。
	# notify_military_attack 内部会再校验 is_ally；非盟/同国/中立伤害均不产生副作用。
	if actual_damage > 0 and bm and bm.diplomacy and bm.diplomacy.active:
		if source and is_instance_valid(source) and source.owner_peer_id >= 0 and owner_peer_id >= 0 and source.owner_peer_id != owner_peer_id and not (self is WorldResource):
			bm.diplomacy.notify_military_attack(source.owner_peer_id, owner_peer_id)
	if health <= 0:
		die()
func die():
	if _is_dead:
		return
	# 战斗统计：击杀归属最后造成伤害的敌方单位（动物不计入歼敌）
	if _last_damager and is_instance_valid(_last_damager) and self.team != RTSConfig.Team.NEUTRAL:
		if (self is Army or self is Building) and _last_damager.team != team and _last_damager.team != RTSConfig.Team.NEUTRAL:
			if not (self is Army and entity_id >= 60):
				var _stats_bm_kill = _get_bm()
				if _stats_bm_kill and _stats_bm_kill.battle_stats:
					_stats_bm_kill.battle_stats.record_kill(_last_damager.owner_peer_id, _last_damager.team, 1)
	_is_dead = true
	# 死亡状态立即定案：即使后续走“毁坏模型/死亡动画”延迟删除，
	# 从此刻起也按不存活处理（health<=0 是全项目的死亡判据，
	# 缓存重建、人口重算、上限统计、寻敌过滤都据此排除本实体）
	health = 0
	_play_sfx_if_visible("unit_die")
	# 音效触发时立即同步死亡动画
	var _bm_anim = _get_bm()
	if _bm_anim and _bm_anim.has_method("_update_entity_animation"):
		_bm_anim._update_entity_animation(self)
	emit_signal("died")
	# 动物死亡掉落食物
	if self is Army and self.get("_animal_type") != "" and self.get("_animal_type") != null:
		var bm2 = get_tree().get_first_node_in_group("battle_manager")
		if bm2:
			var reward = int(self.get("_animal_food_reward") * (0.25 + 0.25 * self.level))
			# 奖励给击杀者的队伍（而非动物的队伍）
			var reward_team = team
			var reward_owner = owner_peer_id
			if _last_damager and is_instance_valid(_last_damager):
				reward_team = _last_damager.team
				reward_owner = _last_damager.owner_peer_id
			if reward_owner != -1:
				bm2.add_resource_for(reward_owner, "food", reward)
			else:
				bm2.add_resource("food", reward, reward_team)
			if _animal_is_baby:
				bm2.add_resource("food", int(reward * 0.3), reward_team)
	# 商人运输途中被击杀 → 击杀者获得其贸易货物（全量；仅往返途中掉落）
	if self is Army and entity_id in [43, 44, 45, 51]:
		var _m_state = self.get("_merchant_state")
		if _m_state != null and (int(_m_state) == 2 or int(_m_state) == 4):
			var bm_merch = get_tree().get_first_node_in_group("battle_manager")
			if bm_merch:
				var _m_res = str(self.get("_merchant_resource"))
				var _m_amt = int(self.get("_merchant_trade_volume"))
				if _m_res != "" and _m_amt > 0:
					# 货物归击杀者（而非商人所属阵营）
					var loot_team = team
					var loot_owner = owner_peer_id
					if _last_damager and is_instance_valid(_last_damager):
						loot_team = _last_damager.team
						loot_owner = _last_damager.owner_peer_id
					if loot_owner != -1:
						if bm_merch.has_method("add_resource_for"):
							bm_merch.add_resource_for(loot_owner, _m_res, _m_amt)
					else:
						bm_merch.add_resource(_m_res, _m_amt, loot_team)
	# 只有“占用人口额度”的实体死亡才扣人口（动物 id>=60 是 Army 但从不占人口，见 spawn 口径）
	if (self is Army and entity_id < 60) or (self is Building and (entity_id == 25 or entity_id == 26)):
		var bm = get_tree().get_first_node_in_group("battle_manager") as RTSBattleManager
		if owner_peer_id != -1:
			if bm.has_method("decrease_player_population"):
				bm.decrease_player_population(owner_peer_id, 1)
			elif bm.has_method("decrease_population"):
				bm.decrease_population(team, 1)
		else:
			bm.decrease_population(team, 1)
	_hide_garrison_marker()
	# 切换到毁坏模型
	var dem_path = RTSConfig.get_demolished_model(entity_id)
	if dem_path != "" and ResourceLoader.exists(dem_path):
		collision_layer = 0
		# 隐藏原有视觉模型
		for child in get_children():
			if child is MeshInstance3D:
				child.visible = false
			if child.has_meta("_model_instance"):
				var m = child.get_meta("_model_instance")
				if is_instance_valid(m): m.visible = false
		# 加载毁坏模型
		var s = load(dem_path)
		if s:
			var inst = s.instantiate()
			inst.name = "DemolishedModel"
			add_child(inst)
		var t = Timer.new(); t.one_shot = true; t.wait_time = 1.0
		t.timeout.connect(queue_free); add_child(t); t.start()
		return
	# 播放死亡动画后再删除
	if has_meta("_model_instance"):
		var model = get_meta("_model_instance")
		var ap = model.get_node_or_null("AnimationPlayer") as AnimationPlayer
		if ap and ap.has_animation("die"):
			ap.play("die")
			collision_layer = 0
			var t = Timer.new(); t.one_shot = true
			t.wait_time = ap.get_animation("die").length + 0.2
			t.timeout.connect(queue_free); add_child(t); t.start()
			return
	queue_free()

# 驻扎标记桩方法（子类覆盖）
func _show_garrison_marker(): pass
func _hide_garrison_marker(): pass

func _load_banner(pos: Vector3) -> Node3D:
	if ResourceLoader.exists("res://models/arena/banner.glb"):
		var s = load("res://models/arena/banner.glb")
		if s: var b = s.instantiate(); if b: b.position = pos; return b
	var m = MeshInstance3D.new()
	m.mesh = CylinderMesh.new()
	m.mesh.top_radius = 0.35; m.mesh.bottom_radius = 0.35; m.mesh.height = 0.05
	m.position = pos
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 1.0, 0.4, 0.7)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.material_override = mat
	return m

const GROUP_COLORS = [Color.RED, Color.BLUE, Color.GREEN, Color.YELLOW, Color.ORANGE, Color.PURPLE, Color.CYAN, Color.MAGENTA, Color.WHITE, Color.GRAY]

func set_selected(selected: bool):
	if has_node("SelectionRing"):
		$SelectionRing.visible = selected
	# 驻扎标记
	if selected:
		if "garrison_point" in self and self.garrison_point != Vector3.ZERO:
			_show_garrison_marker()
	else:
		_hide_garrison_marker()

func _spawn_produced_unit():
	AudioManager.play_sfx("produce")
	if production_queue.is_empty():
		return

	var unit_id = production_queue.pop_front()
	var config = EntityDatabase.get_config(unit_id)
	if not config:
		return

	var bm = get_tree().get_first_node_in_group("battle_manager") as RTSBattleManager
	if not bm:
		return

	# Check if unit is water-capable and choose appropriate spawn
	var is_water_unit = config.get("water_capable", false)
	var spawn_pos = Vector3.ZERO
	if is_water_unit:
		spawn_pos = _find_water_spawn_near(global_position)
	else:
		spawn_pos = _find_land_spawn_pos()
	if spawn_pos == Vector3.ZERO:
		spawn_pos = global_position + Vector3(randf_range(-2,2), 0, randf_range(-2,2))
	config["owner_peer_id"] = self.owner_peer_id  # 继承建筑所有权
	var entity = bm.spawn_entity(config, team, spawn_pos, self.level)
	if entity:
		entity.owner_peer_id = self.owner_peer_id   # 继承建筑所有权
		if bm.battle_stats:
			bm.battle_stats.record_produced_unit(self.owner_peer_id, team, unit_id)

		# 在线模式：按玩家统计人口（单人模式 spawn_entity 已处理，避免双计）
		if owner_peer_id != -1 and bm is OnlineBattleManager:
			bm.increase_player_population(owner_peer_id, 1)
		# 训练完成警报（仅人类玩家自己，含编队和位置）
		if bm.has_method("_show_hud_alert") and bm.is_human_owned(owner_peer_id, team):
			var unit_name = config.get("name", "单位")
			var group_str = ""
			var sm = bm.get_node_or_null("SelectionManager")
			if sm and sm.has_method("get_entity_groups"):
				var groups = sm.get_entity_groups(self)
				if groups.size() > 0:
					group_str = " [T%d]" % groups[0]
			var loc_str = "(%d,%d)" % [int(global_position.x), int(global_position.z)]
			bm._show_hud_alert("训练完成: %s%s %s" % [unit_name, group_str, loc_str], Color(0.2, 1.0, 0.3), team)
	# 继承建筑的驻扎点
	if self is Building and self.garrison_point != Vector3.ZERO:
		if entity is Army and entity.has_method("_is_military") and entity._is_military():
			entity.set_garrison(self.garrison_point)

	if production_queue.size() > 0:
		var next_id = production_queue[0]
		for prod in production_list:
			if prod.unit_id == next_id:
				production_timer = prod.cooldown
				break


# Find spawn position on LAND (terrain != water)
func _find_land_spawn_pos() -> Vector3:
	var bm = get_tree().get_first_node_in_group("battle_manager") as RTSBattleManager
	var attempts = 0
	var max_attempts = 30
	while attempts < max_attempts:
		var angle = randf_range(0, TAU)
		var dist = randf_range(2.0, 4.0)
		var test_pos = global_position + Vector3(cos(angle) * dist, 0, sin(angle) * dist)
		# Check terrain: must be passable for land units
		if bm and bm.get_terrain_at(test_pos) == 2:  # water
			attempts += 1; continue
		# Check no entity overlap
		var conflict = false
		for entity in get_tree().get_nodes_in_group("entities"):
			if entity == self or not is_instance_valid(entity): continue
			if entity is GameEntity and entity.health > 0:
				if test_pos.distance_to(entity.global_position) < 1.5:
					conflict = true; break
		if not conflict: return test_pos
		attempts += 1
	return Vector3.ZERO  # fallback: caller will use default position
func _find_outside_spawn_pos() -> Vector3:
	var best_pos = Vector3.ZERO
	var attempts = 0
	var max_attempts = 30
	var search_radius = 2.0
	var required_clearance = 1.2

	while attempts < max_attempts:
		var angle = randf_range(0, TAU)
		var dist = randf_range(search_radius, search_radius + 2.0)
		var test_pos = global_position + Vector3(cos(angle) * dist, 0, sin(angle) * dist)

		var conflict = false
		for entity in get_tree().get_nodes_in_group("entities"):
			if entity == self or not is_instance_valid(entity):
				continue
			if not (entity is GameEntity) or entity.health <= 0:
				continue
			var d = test_pos.distance_to(entity.global_position) - (body_radius + entity.body_radius)
			if d < required_clearance:
				conflict = true
				break

		if not conflict:
			best_pos = test_pos
			break
		attempts += 1

	return best_pos

func try_produce(unit_id: int) -> bool:
	if unit_id == 10:
		var _ids = []
		for _p in production_list: _ids.append(_p.unit_id)
	if entity_type != 1:
		return false
	
	var prod_config = null
	for prod in production_list:
		if prod.unit_id == unit_id:
			prod_config = prod
			break
	if not prod_config:
		return false
	
	var current_in_queue = 0
	for id in production_queue:
		if id == unit_id:
			current_in_queue += 1
	if current_in_queue >= prod_config.queue_limit:
		print("[TryProduce] queue full: ", unit_id, " limit=", prod_config.queue_limit)
		return false
	print("[TryProduce] SUCCESS: ", unit_id, " queue=", current_in_queue + 1)
	
	var unit_cfg = EntityDatabase.get_config(unit_id)
	if not unit_cfg:
		return false
	
	var base_cost = unit_cfg.get("cost", {})
	var scaled_cost = {}
	for res in base_cost:
		scaled_cost[res] = int(base_cost[res] * (1.0 + (level - 1) * 0.2))
	
	var bm = get_tree().get_first_node_in_group("battle_manager") as RTSBattleManager
	if not bm:
		return false

	# 根据建筑所属队伍和 owner_peer_id 选择资源库
	var res_dict = null
	if owner_peer_id != -1 and bm.has_method("deduct_player_resources"):
		
		var cost = scaled_cost
		if bm.deduct_player_resources(owner_peer_id, cost):
			# 成功扣除，继续生产
			pass
		else:
			return false
	else:
		# 原有 1v1 逻辑
		
		res_dict = bm.player_resources if team == RTSConfig.Team.BLUE else bm.enemy_resources
		for res in scaled_cost.keys():
			if res_dict[res] < scaled_cost[res]: return false
		for res in scaled_cost.keys():
			res_dict[res] -= scaled_cost[res]
	
	production_queue.append(unit_id)
	if production_queue.size() == 1:
		production_timer = prod_config.cooldown
	return true

func shock(duration: float):
	shock_timer = duration

func freeze(duration: float):
	freeze_timer = duration

func _find_water_spawn_near(center: Vector3) -> Vector3:
	var bm = get_tree().get_first_node_in_group("battle_manager") as RTSBattleManager
	if not bm:
		return center + Vector3(0, 0, 2)
	
	for radius in [3, 5, 7]:
		for _try in range(30):
			var angle = randf_range(0, TAU)
			var dist = randf_range(1, radius)
			var test_pos = center + Vector3(cos(angle) * dist, 0, sin(angle) * dist)
			var terrain = bm.get_terrain_at(test_pos)
			if terrain == 2:
				return test_pos
	return center + Vector3(0, 0, 3)

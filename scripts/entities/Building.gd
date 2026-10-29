class_name Building
extends GameEntity

const LevelVisualScript = preload("res://scripts/effects/BuildingLevelVisual.gd")

var upgrade_level: int = 1                         # 当前等级
var upgrade_data: Array = []                       # 从配置加载的升级表
var max_upgrade_level: int = 5
var building_data: Dictionary = {}   # 保存原始配置
var build_timer: float = 0.0
var max_build_time: float = 0.0
# ── 建造/修理需要农民到场 ──
# builders 存 WeakRef：农民死亡或改派后由 _prune_builders() 自动剔除。
var builders: Array = []
var awaiting_builder: bool = false          # 已开工但还没有农民到达现场
var repair_pending: bool = false            # 已扣修理费、等待农民到场
var builder_count_cache: int = 0            # 当前登记的农民数（含赶路中）
var active_builder_count_cache: int = 0     # 已到现场、正在施工的农民数
var _builder_cache_timer: float = 0.0
var upgrade_timer: float = 0.0
var max_upgrade_time: float = 0.0
var assigned_merchants: int = 0                    # 集市分配的商人数量（仅entity_id==52时使用）
var garrison_point: Vector3 = Vector3.ZERO         # 新生产单位的驻扎点
var _garrison_marker: Node3D = null

# 士兵/农民进驻系统
var garrisoned_soldiers: Array = []      # Array of WeakRef — 进驻的单位
var garrison_max: int = 0                # 进驻上限（城堡10/箭塔炮塔5/其他0）
# 防御塔索敌：每帧扫描在后期几百实体时会形成稳定热点，改为错峰低频扫描。
var _target_scan_timer: float = randf_range(0.0, 0.25)

# Hell difficulty speed bonus

# 该建筑的拥有者是否为 AI：联机客户端的 peer_id 是随机大整数（实测见过 385949886），
# 不能简单用 >= 1000 判断，否则人类客户端会被当成 AI 吃 HELL 难度加成。
# 单机 AI 的 my_peer_id / 建筑 owner_peer_id 常为 -1，需要用队伍上是否有
# AIController 来区分；联机里 owner=-1 可能是真人客户端，不能这样判断。
func _owner_is_ai() -> bool:
	var bm = _get_bm()
	if owner_peer_id < 0:
		if bm == null or bm.is_online:
			return false
		for c in bm.get_children():
			if c is AIController and int(c.my_team) == team:
				return true
		return false
	if bm and bm.is_online and bm.has_method("is_ai_peer"):
		return bool(bm.call("is_ai_peer", owner_peer_id))
	return owner_peer_id >= 1000

func start_construction(time: float, data: Dictionary):
	building_data = data
	_release_builders()
	repair_pending = false
	repair_timer = 0.0
	max_repair_time = 0.0
	awaiting_builder = true
	builder_count_cache = 0
	active_builder_count_cache = 0
	var spd = 1.0
	if GameSettings.fast_mode: spd = 2.0
	if _owner_is_ai() and GameSettings.ai_difficulty >= GameSettings.AIDifficulty.HELL: spd *= 1.2
	var cbm = _get_bm()
	if cbm != null and cbm.has_method("is_research_mode") and cbm.is_research_mode():
		spd *= 1.0 + float(cbm.get_research_mods(owner_peer_id, team).get("construction_speed_pct", 0.0)) / 100.0
	max_build_time = data["max_health"] / 75.0 / spd
	build_timer = max_build_time
	max_health = 10
	health = 10
	attack = 0
	production_list = []
	# 建造期间不提供视野
	vision_range = 0
	BuildingConstructionVisual.begin(self)
	# 建造期间先隐藏等级旗帜/徽章，等脚手架撤掉、等级确定后再显示。
	LevelVisualScript.set_visible(self, false)
func _process(delta):
	super._process(delta)
	# 城墙动态朝向 + 拐角模型切换
	if entity_id == 27 and Engine.get_process_frames() % 30 == 0:
		var has_x_neg = false; var has_x_pos = false
		var has_z_neg = false; var has_z_pos = false
		var bm = _get_bm()
		if bm:
			# Adjacent wall spacing = body_radius * 2.0; add 20% tolerance
			var half_len = body_radius * 2.0 * 1.2
			var half_wid = body_radius * 0.8
			# 只查空间索引附近的墙，避免每面墙每 30 帧遍历全场实体
			for e in bm.get_nearby_entities(global_position, body_radius * 3.0):
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

	# 建造计时：必须有农民站在旁边才会推进；没人到场时进度暂停并保持脚手架
	if build_timer > 0.0:
		_refresh_builder_cache(delta)
		var build_progress := clampf(1.0 - build_timer / maxf(max_build_time, 0.001), 0.0, 1.0)
		BuildingConstructionVisual.update(self, build_progress)
		if active_builder_count_cache > 0:
			awaiting_builder = false
			var speed_mult: float = BUILDER_SPEED_MULT[clampi(active_builder_count_cache - 1, 0, BUILDER_SPEED_MULT.size() - 1)]
			build_timer -= delta * speed_mult
			if Engine.get_process_frames() % 40 == 0: AudioManager.play_sfx("build_loop")
			if build_timer <= 0.0:
				_finish_construction()
		else:
			awaiting_builder = true

	# 升级计时
	if upgrade_timer > 0.0:
		upgrade_timer -= delta
		if upgrade_timer <= 0.0:
			_finish_upgrade()
			AudioManager.play_sfx("upgrade_done")

	# 修理计时 + AI 附近敌人扫描（每 0.5 秒一次，避免每次快照都做空间查询）
	_tick_repair_scan(delta)
	if repair_pending or repair_timer > 0.0:
		_tick_repair(delta)

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
				_spawn_produced_unit()
		# 注意：人口满时这里不能每帧 print，否则成百上千座兵营会把日志刷爆并拖死主线程
	else:
		production_timer = 0.0

	# 防御塔自动攻击
	if attack > 0:
		# 目标被销毁后引用不是 null（已释放实例 == null 反而为真），
		# 直接对已释放实例做 is 判断会报 previously freed instance，必须先 is_instance_valid
		if not is_instance_valid(current_target):
			current_target = null
			_target_scan_timer = 0.0
		if is_instance_valid(current_target) and current_target is Army and current_target.is_immune_to_damage(self):
			current_target = null
			_target_scan_timer = 0.0
		if current_target == null:
			# 每帧 find_enemy 在后期几十座塔时会持续做空间查询；0.25 秒一次足够，
			# 初始相位已在变量声明时随机打散。
			_target_scan_timer -= delta
			if _target_scan_timer <= 0.0:
				_target_scan_timer = 0.25
				_find_enemy_in_range()
		else:
			_target_scan_timer = 0.0
		if current_target != null:
			var dist = global_position.distance_to(current_target.global_position) - body_radius - current_target.body_radius
			if dist <= attack_range:
				_attack(current_target, delta)
			else:
				current_target = null

func _find_enemy_in_range():
	var best = null
	var best_dist = attack_range + 1
	var bm = _get_bm()
	var candidates = bm.get_nearby_enemies(global_position, attack_range, team, owner_peer_id, true) if bm else get_tree().get_nodes_in_group("entities")
	for entity in candidates:
		if not (entity is Army) or entity.health <= 0: continue
		if bm != null and bm.has_method("is_target_visible_from") and not bm.is_target_visible_from(self, entity): continue
		# 无外交管理器（非乱斗）→ 退化为纯队伍过滤；乱斗已由 get_nearby_enemies 按 owner 过滤
		if not bm:
			if entity.team == team: continue
		# Buildings don't attack animals
		if str(entity.get("_animal_type")) != "": continue
		# 船上的单位仍免疫；墙顶单位对远程防御塔不再免疫，可以被射击。
		if entity.is_immune_to_damage(self): continue
		var dist = global_position.distance_to(entity.global_position) - body_radius - entity.body_radius
		if dist <= attack_range and dist < best_dist:
			best_dist = dist
			best = entity
	if best:
		current_target = best

# 墙顶炮台：脚下城墙存活时只吃远程伤害；近战必须先拆墙。
# 墙被摧毁后由 die() 里的 _destroy_wall_cannons() 连带拆除。
func is_immune_to_damage(source = null) -> bool:
	if entity_id != 64:
		return false
	var bm = _get_bm()
	if bm == null:
		return false
	bm._ensure_cache_fresh()
	if bm._wall_entity_grid.is_empty():
		return false
	var wall = bm._wall_entity_grid.get(bm.world_to_grid(global_position))
	if wall == null or not is_instance_valid(wall) or not (wall is Building):
		return false
	if wall.health <= 0 or wall.build_timer > 0.0 or wall.team != team:
		return false
	if source == null:
		return true
	if source is GameEntity:
		return not source.is_ranged_attacker()
	return true

func _attack(target, delta):
	# 箭塔/炮塔/墙顶炮台由 is_wall_blocking_shot 放行；普通远程建筑不能隔墙开火。
	if target_type == 3:
		var bm_wall = _get_bm()
		if bm_wall != null and bm_wall.has_method("is_wall_blocking_shot") \
				and bm_wall.is_wall_blocking_shot(self, target):
			current_target = null
			return
	if attack_timer > 0:
		attack_timer -= delta
		return
	# 炮台：旋转朝向目标
	if entity_id == 64:
		var dir = target.global_position - global_position
		dir.y = 0
		if dir.length() > 0.01:
			rotation.y = atan2(dir.x, dir.z) + deg_to_rad(90)
		if has_meta("_model_instance"):
			var cannon_model = get_meta("_model_instance")
			if cannon_model is Node3D:
				CannonTowerAnim.play(cannon_model)
	if damage_radius > 0 or attack_range > 1.0:
		var bm = _get_bm()
		if bm == null:
			attack_timer = attack_speed
			return
		var bullet = bm.acquire_bullet(self, damage_radius, team)
		bullet.team = team
		bullet.owner_peer_id = owner_peer_id
		bullet.damage = attack * (volley_mult if volley_count > 1 else 1.0)
		bullet.speed = 12.0
		bullet.target = target
		bullet.source = self
		bullet.damage_radius = damage_radius
		bullet.splash_damage_mult = splash_damage_mult
		# 从模型朝目标一侧的上沿出手：箭塔射箭、炮塔/城墙炮台打炮都不再从建筑中心冒出。
		bullet.global_position = WeaponAttachment.projectile_origin(self, entity_id, target.global_position)
		bullet.aim_initial(target.global_position)
		# B7 三矢齐发：主城/城堡一次攻击连射 3 支，每支 100% 伤害。
		var extra_shots: int = maxi(0, volley_count - 1) if entity_id in [20, 53] else 0
		for _i in range(extra_shots):
			var extra = bm.acquire_bullet(self, damage_radius, team)
			extra.team = team
			extra.owner_peer_id = owner_peer_id
			extra.damage = attack * volley_mult
			extra.speed = 12.0
			extra.target = target
			extra.source = self
			extra.damage_radius = damage_radius
			extra.splash_damage_mult = splash_damage_mult
			extra.global_position = bullet.global_position + Vector3(randf_range(-0.35, 0.35), 0, randf_range(-0.35, 0.35))
	else:
		target.take_damage(attack, self)
	attack_timer = attack_speed
	attack_seq += 1

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
			# 和服务端首次生成、直墙/拐角切换共用同一套缩放：
			# 城墙要分别按占地和高度缩放，不能按最大边等比缩放，否则换拐角后
			# 会比旁边直墙窄一截。普通建筑仍走通用等比缩放。
			var aabb: AABB = bm._get_model_aabb(inst)
			if bm.has_method("_model_scale_for"):
				inst.scale = bm._model_scale_for(entity_id, body_radius, aabb)
			else:
				var target_size: float = body_radius * 2.0
				var current_size: float = maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z))
				if current_size > 0.01:
					inst.scale = RTSConfig.get_model_scale_vector(entity_id, target_size / current_size * RTSConfig.get_model_scale(entity_id))
			add_child(inst); set_meta("_model_instance", inst)
			# 换模型后视觉尺寸可能变化，土色贴花跟着重算
			_refresh_ground_patch_size()
			BuildingConstructionVisual.rebind(self)
			var tint: Color = bm.get_entity_color(self) if bm.has_method("get_entity_color") else (Color(0.3, 0.6, 1.0) if team == RTSConfig.Team.BLUE else Color(1.0, 0.4, 0.4))
			bm._apply_team_tint(self, tint)
			WallTierVisual.apply(self, maxi(upgrade_level, level), tint)

func _finish_construction():
	BuildingConstructionVisual.finish(self)
	build_timer = 0.0
	awaiting_builder = false
	_release_builders()
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
	# 梯子完工前不提供翻墙通道（见 RTSBattleManager._ensure_cache_fresh），
	# 完工时必须让寻路缓存立刻失效，否则部队会继续按旧路径去拆墙。
	if bm and int(entity_id) == 8 and bm.has_method("notify_ladder_ready"):
		bm.notify_ladder_ready()
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
			_sync_production_unlocks()
	# start_construction 为了隐藏施工期生产入口清空了 production_list；
	# 1 级建筑 glv == upgrade_level，不会进入上面的分支，必须在这里无条件重建，
	# 否则新建的 1 级兵营建好后生产列表仍为空，无法训练步兵。
	_sync_production_unlocks()
	
	
	if bm :
		if owner_peer_id == -1:
			bm.update_resource_limits(team)
		elif bm.has_method("update_player_limits"):
			bm.update_player_limits(owner_peer_id)
			bm.update_player_population(owner_peer_id)

	# 建造完成警报（仅人类玩家自己，含位置和编队）
	if bm and bm.has_method("_show_hud_alert") and bm.is_progress_reportable(owner_peer_id, team):
		var group_str = ""
		var sm = bm.get_node_or_null("SelectionManager")
		if sm and sm.has_method("get_entity_groups"):
			var groups = sm.get_entity_groups(self)
			if groups.size() > 0:
				group_str = " [T%d]" % groups[0]
		var loc_str = "(%d,%d)" % [int(global_position.x), int(global_position.z)]
		bm._show_hud_alert("建造完成: %s%s %s" % [display_name, group_str, loc_str], Color(0.2, 1.0, 0.3), [team], team, GameSettings.AlertKind.BUILD, false, bm.get_alert_nations(self), global_position, owner_peer_id)
	# 城堡建成立刻解锁民族兵种
	if entity_id == 53 and bm:
		var nation := _get_nation_for_bonus()
		if nation >= 0:
			_unlock_nation_units(nation)
	# 科研模式：先记录基础数值，再套用全玩家科技加成；最后按科技解锁重排生产列表。
	_capture_base_stats()
	_capture_research_base()
	_capture_stats_before_official()
	if bm and bm.has_method("is_research_mode") and bm.is_research_mode():
		_capture_research_base()
		if bm.has_method("apply_research_bonuses"):
			bm.apply_research_bonuses(self)
		_sync_production_unlocks()
		# 科研模式的生产列表会被上面的 sync 重置，特色兵种要在重置之后再补一次。
		if entity_id == 53 and bm.has_method("_unlock_nation_units"):
			var rn: int = _get_nation_for_bonus()
			if rn >= 0:
				_unlock_nation_units(rn)
	# 建造期间视野为 0，完成后恢复；若建筑正被选中，立即补上视野/射程圈
	_sync_range_rings()
	# 建造完成、全局等级同步后重建一次等级外观。
	refresh_level_visual()

func refresh_level_visual() -> void:
	var bm = _get_bm()
	var color := Color.WHITE
	if bm != null and bm.has_method("get_entity_color"):
		color = bm.get_entity_color(self)
	LevelVisualScript.apply(self, maxi(upgrade_level, level), 0.0, color, build_timer <= 0.0)
	# 城墙按等级换木/粗石/精石材质；普通建筑由 LevelVisual 处理。
	WallTierVisual.apply(self, maxi(upgrade_level, level), color)

	
func is_under_construction() -> bool:
	return build_timer > 0.0

# ==================== 建造/修理农民系统 ====================
# 每座建筑最多登记 3 个农民；只有已经站在建筑旁边的农民才算「正在施工」。
func register_builder(u) -> int:
	if u == null or not is_instance_valid(u) or not (u is Army):
		return -1
	if u.entity_id != 10 or u.health <= 0:
		return -1
	_prune_builders()
	var uid: int = u.get_instance_id()
	for i in range(builders.size()):
		var ref = builders[i]
		var old = ref.get_ref() if ref is WeakRef else null
		if old != null and is_instance_valid(old) and old.get_instance_id() == uid:
			return i
	if builders.size() >= MAX_BUILDERS:
		return -1
	builders.append(weakref(u))
	builder_count_cache = builders.size()
	return builders.size() - 1

func _prune_builders() -> void:
	var kept: Array = []
	for ref in builders:
		if not (ref is WeakRef):
			continue
		var u = ref.get_ref()
		if u != null and is_instance_valid(u) and u is Army and u.health > 0:
			kept.append(ref)
	builders = kept

func remove_builder(u) -> void:
	if u == null or not is_instance_valid(u):
		return
	var uid: int = u.get_instance_id()
	var kept: Array = []
	for ref in builders:
		if not (ref is WeakRef):
			continue
		var old = ref.get_ref()
		if old != null and is_instance_valid(old) and old.get_instance_id() == uid:
			continue
		kept.append(ref)
	builders = kept
	builder_count_cache = builders.size()
	active_builder_count_cache = active_builder_count()

func _release_builders() -> void:
	var old := builders.duplicate()
	builders.clear()
	builder_count_cache = 0
	active_builder_count_cache = 0
	for ref in old:
		if not (ref is WeakRef):
			continue
		var u = ref.get_ref()
		if u != null and is_instance_valid(u) and u.health > 0 and u.has_method("stop_working_for"):
			u.stop_working_for(self)

func builder_count() -> int:
	_prune_builders()
	builder_count_cache = builders.size()
	return builder_count_cache

func _builder_reach() -> float:
	return body_radius + BUILDER_ARRIVE_PAD

func active_builder_count() -> int:
	_prune_builders()
	var n: int = 0
	for ref in builders:
		var u = ref.get_ref() if ref is WeakRef else null
		if u == null or not is_instance_valid(u) or u.health <= 0:
			continue
		if String(u.current_order) != "build":
			continue
		if int(u._work_target_id) != get_instance_id():
			continue
		# _at_work_site 由 Army 在真正走到施工位附近时置位。到场半径本身
		# 允许农民离施工位还有约 0.6 米，不能再用“农民到建筑中心的距离”
		# 卡一次：斜向施工位本来就在外缘外约 1 米，双重距离叠加后会把
		# 正常到场的农民误判成没到场，出现播放施工动作但进度条为 0。
		# 这里改为校验“施工位本身贴着外缘”+“农民就在施工位旁边”，
		# 既允许正常的施工位半径，也能挡住异常回退到建筑中心的远施工位。
		if bool(u._at_work_site) and u._work_slot_pos != Vector3.ZERO:
			var slot_dx: float = u._work_slot_pos.x - global_position.x
			var slot_dz: float = u._work_slot_pos.z - global_position.z
			var slot_edge_gap: float = sqrt(slot_dx * slot_dx + slot_dz * slot_dz) - body_radius
			var unit_dx: float = u.global_position.x - u._work_slot_pos.x
			var unit_dz: float = u.global_position.z - u._work_slot_pos.z
			var unit_to_slot: float = sqrt(unit_dx * unit_dx + unit_dz * unit_dz)
			if slot_edge_gap <= 1.8 and unit_to_slot <= 1.2:
				n += 1
	return n

func _refresh_builder_cache(delta: float) -> void:
	_builder_cache_timer -= delta
	if _builder_cache_timer > 0.0:
		return
	_builder_cache_timer = 0.25
	builder_count_cache = builder_count()
	active_builder_count_cache = active_builder_count()

# 施工站位：普通建筑沿外缘，桥/梯子/城墙炮台向外多找几圈陆地，
# 保证农民能站在桥边、墙边施工，而不是被要求站到建筑中心。
func get_builder_slot(index: int) -> Vector3:
	var bm = _get_bm()
	if bm == null:
		return global_position
	var base_angle: float = rotation.y + TAU * float(index % MAX_BUILDERS) / float(MAX_BUILDERS)
	var max_r: float = body_radius + (4.5 if entity_id == 7 else 3.2)
	var r: float = maxf(body_radius + 1.1, 1.5)
	while r <= max_r:
		for k in range(12):
			var ang: float = base_angle + TAU * float(k) / 12.0
			var p: Vector3 = global_position + Vector3(cos(ang), 0.0, sin(ang)) * r
			var g: Vector2i = bm.world_to_grid(p)
			if not _is_builder_tile_valid(bm, g.x, g.y):
				continue
			var wp: Vector3 = bm.grid_to_world(g.x, g.y)
			wp.y = bm.get_height_at_grid(g.x, g.y)
			return wp
		r += 0.6
	return global_position

# 给某个农民挑最近的合法建筑外缘：从农民所在方向开始绕一圈采样，
# 比较所有能站人的边缘点到农民的距离，取代以前按编号固定朝向的站位。
# 农民从哪边来就站哪边，不用绕到建筑背面，长条建筑/城墙也不会被固定点坑到。
#
# 关键：只在“最靠近建筑的第一圈可站点”里挑，不能把所有半径都扫一遍再取
# 离农民最近的点。后者在数学上总会选到最外圈（r 越大离农民越近），
# 结果就是农民隔着好几米就开始建造/修理。只有第一圈全被水/山/别的建筑
# 挡住时才逐圈向外退，保证施工位贴着建筑外缘。
func get_builder_slot_for(from_pos: Vector3, index: int = 0, for_unit = null) -> Vector3:
	var bm = _get_bm()
	if bm == null:
		return global_position
	var to_unit := from_pos - global_position
	to_unit.y = 0.0
	var start_ang: float = rotation.y
	if to_unit.length_squared() > 0.01:
		start_ang = atan2(to_unit.z, to_unit.x)
	var max_r: float = body_radius + (4.5 if entity_id == 7 else 3.2)
	var min_r: float = maxf(body_radius + 0.8, 1.2)
	var samples: int = 48 if entity_id == 7 else 36
	# 已经登记的其他农民占住的施工位：三个农民从同一侧过来时不要挤到同一个点，
	# 否则后面的人会被前一个人顶在圈外，看起来像“站在远处施工”。
	var reserved: Array = []
	for ref in builders:
		if not (ref is WeakRef):
			continue
		var u = ref.get_ref()
		if u == null or not is_instance_valid(u) or not (u is Army) or u == for_unit:
			continue
		if int(u._work_target_id) != get_instance_id():
			continue
		var used_pos: Vector3 = u._work_slot_pos
		if used_pos != Vector3.ZERO:
			reserved.append(used_pos)
	var r := min_r
	while r <= max_r:
		var ring_best := Vector3.ZERO
		var ring_best_d := INF
		var ring_found := false
		for k in range(samples):
			var ang: float = start_ang + TAU * float(k) / float(samples)
			var p: Vector3 = global_position + Vector3(cos(ang), 0.0, sin(ang)) * r
			var g: Vector2i = bm.world_to_grid(p)
			if not _is_builder_tile_valid(bm, g.x, g.y):
				continue
			var wp: Vector3 = bm.grid_to_world(g.x, g.y)
			wp.y = bm.get_height_at_grid(g.x, g.y)
			var occupied := false
			for rp in reserved:
				if Vector2(wp.x - rp.x, wp.z - rp.z).length_squared() < 0.81:
					occupied = true
					break
			if occupied:
				continue
			var dx: float = wp.x - from_pos.x
			var dz: float = wp.z - from_pos.z
			var d: float = dx * dx + dz * dz
			if d < ring_best_d:
				ring_best_d = d
				ring_best = wp
				ring_found = true
		if ring_found:
			return ring_best
		r += 0.7
	# 没有合法边缘（被水/山/其他建筑围死）时退回旧逻辑，至少给个可达目标
	return get_builder_slot(index)

func _is_builder_tile_valid(bm, gx: int, gy: int) -> bool:
	if gx < 0 or gy < 0 or gx >= RTSConfig.MAP_SIZE or gy >= RTSConfig.MAP_SIZE:
		return false
	var terrain: int = bm.get_terrain_at_grid(gx, gy)
	if terrain == 2:
		# 桥可以从岸边或已有桥面上继续往前修，施工位允许站在浅滩或桥面上。
		# 不能只认浅滩：河心深水段的桥面地形仍是水，否则农民永远找不到落脚点，
		# 桥只会搭出岸边一两段，后面的桥段一直停在施工中。
		var on_bridge := false
		if entity_id == 7 and bm.has_method("is_bridge_at"):
			on_bridge = bm.is_bridge_at(bm.grid_to_world(gx, gy))
		if entity_id == 7 and (on_bridge or bm.get_overlay_at_grid(gx, gy) == 3):
			pass
		else:
			return false
	if terrain == 1 and bm.has_method("is_blocked_mountain_tile") and bm.is_blocked_mountain_tile(gx, gy):
		return false
	# 普通建筑：别把施工位选到别的建筑里（否则农民永远走不进去，工地会卡在等待）
	if entity_id in [7, 8, 64]:
		return true
	var wp: Vector3 = bm.grid_to_world(gx, gy)
	# 也不要选到建筑自己的碰撞盒里。建筑碰撞是 2B×2B 的方盒，而候选点按
	# “半径 B+0.8”的圆环生成，再取最近格心时可能向内偏最多 0.7 米；
	# 斜向施工位因此会落进方盒拐角，农民被碰撞体顶在外面，永远到不了施工位。
	if _builder_slot_blocked_by_self(wp):
		return false
	if not bm.has_method("get_nearby_entities"):
		return true
	for e in bm.get_nearby_entities(wp, 2.0):
		if e == self or not (e is Building) or e.health <= 0:
			continue
		var d: float = Vector2(e.global_position.x - wp.x, e.global_position.z - wp.z).length()
		if d < maxf(0.8, e.body_radius * 0.75):
			return false
	return true

# 施工位不能落在建筑自身碰撞盒内；这里用旋转后的本地坐标判断，
# 并留出农民半径 + 余量，避免农民贴着盒子边缘反复被推开。
func _builder_slot_blocked_by_self(wp: Vector3) -> bool:
	var local := wp - global_position
	local = local.rotated(Vector3.UP, -rotation.y)
	var margin: float = 0.55
	return absf(local.x) < body_radius + margin and absf(local.z) < body_radius + margin

func is_waiting_for_builder() -> bool:
	return (build_timer > 0.0 and awaiting_builder) or repair_pending

func cancel_repair_visual() -> void:
	repair_pending = false
	repair_timer = 0.0
	max_repair_time = 0.0
	BuildingConstructionVisual.cancel(self)

func _ready():
	super._ready()
	entity_type = 1
	collision_layer = 1
	collision_mask = 1  # 阻挡敌方单位通过
	can_move = false
	# add_child 时 _ready 会立即执行，而 setup() 还没调用：此时 entity_id 仍是 0、
	# body_radius 还是默认值、模型也还没挂上。选择环和土色都依赖这些数据，
	# 必须等 setup 和模型加载完成后再建，否则会出现「炮台也铺土色」「土色大小不对」。
	_add_collision_shape()
	call_deferred("_add_selection_ring")
	call_deferred("_spawn_ground_patch")
	call_deferred("_apply_nation_start_bonus")
	call_deferred("_capture_initial_stats")

# ==================== 建筑脚下的土色地面 ====================
# 建筑压住的那块地面泛出土色，范围比实际占地略大一圈，
# 让建筑看起来是「坐」在土地上而不是浮在草皮上。
# 建筑被摧毁后土色在几秒内慢慢褪去，留下一点被翻动过的痕迹再消失。
#
# 用 Decal 而不是贴地薄片：Decal 会贴合地形起伏，建在坡上也不会一半埋进土里。
const GROUND_PATCH_MARGIN: float = 1.2      # 比模型实际水平尺寸外扩多少米
const GROUND_PATCH_FADE_TIME: float = 3.5   # 摧毁后淡出耗时（秒）
const GROUND_PATCH_COLOR: Color = Color(0.42, 0.31, 0.19, 0.85)
# 城墙、炮台、桥、梯子这些构件贴在城墙/水面上，脚下不该有土色。
# 单独列一份而不只依赖 RTSConfig 的放大排除表，避免两处定义将来分叉。
const GROUND_PATCH_EXCLUDE_IDS := [7, 8, 25, 26, 27, 41, 64]

static var _ground_patch_tex: ImageTexture = null

var _ground_patch: Decal = null

# 程序生成一张柔边方形贴图当贴花底图：中间实、四边渐隐，
# 这样土色边缘不会出现生硬的方框。全项目共用一张，用完缓存。
static func _ground_patch_texture() -> ImageTexture:
	if _ground_patch_tex != null:
		return _ground_patch_tex
	var n: int = 64
	var feather: float = 12.0
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var edge: float = minf(minf(float(x), float(n - 1 - x)), minf(float(y), float(n - 1 - y)))
			var a: float = clampf(edge / feather, 0.0, 1.0)
			# 轻微随机，避免整块土色像刷子刷出来的一样均匀
			var shade: float = 0.88 + float((x * 7 + y * 13) % 11) * 0.012
			img.set_pixel(x, y, Color(shade, shade, shade, a))
	_ground_patch_tex = ImageTexture.create_from_image(img)
	return _ground_patch_tex

func _spawn_ground_patch() -> void:
	if _ground_patch != null and is_instance_valid(_ground_patch):
		return
	# 城墙/炮台/桥/梯子这类贴在城墙或水面上的构件不铺土色：
	# 它们本来就没压在地面上，铺一层土反倒像浮在空中
	if entity_id in GROUND_PATCH_EXCLUDE_IDS:
		return
	var half: float = _ground_patch_half_size()
	var decal := Decal.new()
	decal.name = "GroundPatch"
	decal.texture_albedo = _ground_patch_texture()
	# size.y 是垂直投射深度，给足高度以覆盖脚下的坡度起伏
	decal.size = Vector3(half * 2.0, 12.0, half * 2.0)
	decal.modulate = GROUND_PATCH_COLOR
	decal.albedo_mix = 1.0
	decal.upper_fade = 1.2
	decal.lower_fade = 1.2
	decal.position = Vector3.ZERO
	add_child(decal)
	_ground_patch = decal

# 模型实际的水平半径，土色与选择环共用同一判据。
# body_radius 是把模型「最大边」缩放到 2 倍半径算出来的，高瘦的塔类建筑
# 水平方向比它窄不少，直接拿它当半径会让土色和选择环都明显偏大。
func _model_horizontal_radius() -> float:
	var r: float = body_radius * RTSConfig.get_model_scale(entity_id)
	var inst = get_meta("_model_instance", null) if has_meta("_model_instance") else null
	if inst != null and is_instance_valid(inst) and inst is Node3D:
		var bm = get_tree().get_first_node_in_group("battle_manager") if get_tree() != null else null
		if bm != null and bm.has_method("_get_model_aabb"):
			var aabb: AABB = bm._get_model_aabb(inst)
			var horiz: float = maxf(aabb.size.x, aabb.size.z) * absf(inst.scale.x) * 0.5
			if horiz > 0.05:
				r = horiz
	return r

# 土色半宽：模型水平半径 + 一小圈外扩
func _ground_patch_half_size() -> float:
	return _model_horizontal_radius() + GROUND_PATCH_MARGIN

# 模型被替换（城墙换拐角、升级换外观）后重算土色尺寸
func _refresh_ground_patch_size() -> void:
	if _ground_patch == null or not is_instance_valid(_ground_patch):
		return
	var half: float = _ground_patch_half_size()
	_ground_patch.size = Vector3(half * 2.0, 12.0, half * 2.0)

# 建筑死亡时调用：土色贴花脱离建筑挂在场景里继续淡出，
# 直接挂在建筑上会跟着一起被 queue_free，看不到褪色过程。
func _fade_ground_patch() -> void:
	if _ground_patch == null or not is_instance_valid(_ground_patch):
		_ground_patch = null
		return
	var decal := _ground_patch
	_ground_patch = null
	var parent := get_parent()
	if parent != null:
		decal.reparent(parent, true)
	var tw := decal.create_tween()
	tw.tween_property(decal, "modulate:a", 0.0, GROUND_PATCH_FADE_TIME)
	tw.tween_callback(Callable(decal, "queue_free"))
	
	
func _get_nation_for_bonus() -> int:
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if bm == null:
		return -1
	if bm.has_method("get_entity_nation"):
		var n = int(bm.get_entity_nation(self))
		if n >= 0:
			return n
	if bm.has_method("get_team_nation"):
		return int(bm.get_team_nation(team))
	return -1

func _apply_nation_start_bonus():
	# 仅对主城(id=20)和城堡(id=53)应用
	if entity_id not in [20, 53] and entity_id != 53:
		return
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if not bm or not bm.has_method("get_team_nation"):
		return
	var nation := _get_nation_for_bonus()
	if nation < 0:
		return
	var start_lv = NationBonuses.get_castle_start_level(nation)
	if start_lv > 1 and upgrade_level == 1:
		upgrade_level = start_lv
		level = start_lv
		# 如果初始等级达到 3，立刻解锁特色兵种
		if upgrade_level >= 3 and entity_id == 53:
			_unlock_nation_units(nation)
		refresh_level_visual()

# 开局自带的建筑（主城/城堡）没有走 _finish_construction，必须补一次快照，
# 否则信息面板无法把后续科研、官员和基础属性拆开显示。
func _capture_initial_stats() -> void:
	if build_timer > 0.0:
		return
	_capture_base_stats()
	_capture_research_base()
	_capture_stats_before_official()

# ====================== 修复：建筑选择环 水平贴地 ======================
func _add_selection_ring():
	if not has_node("SelectionRing"):
		# 环形贴着模型轮廓走：用模型实际水平半径，而不是 body_radius（按最大边算，偏大）
		var visual_r: float = _model_horizontal_radius()
		var ring = MeshInstance3D.new()
		ring.name = "SelectionRing"
		var torus = TorusMesh.new()
		torus.inner_radius = visual_r + 0.12
		torus.outer_radius = visual_r + 0.22
		ring.mesh = torus

		# 水平圆环 + 贴地面
		ring.position.y = visual_r * 1.2 + 0.1
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
		# 原来是一个 body_radius*2 见方、以脚底为中心的扁盒子：水平铺得比建筑底座宽，
		# 竖直却只到腰高、一半还埋在地下。结果是点建筑旁边的空地会误选建筑，
		# 点建筑上部又打不中。这里收窄水平、加高竖直，并把盒子抬到底面贴地。
		shape.size = Vector3(body_radius * 1.4, body_radius * 2.2, body_radius * 1.4)
		col.shape = shape
		col.position.y = body_radius * 1.1
		col.name = "CollisionShape3D"
		add_child(col)

func setup(config: Dictionary):
	super.setup(config)  # 只调用一次
	upgrade_data = config.get("upgrades", [])
	max_upgrade_level = 1 + upgrade_data.size()

	# Store full produces list for later upgrades
	building_data = config.duplicate(true)
	# Filter production_list by current level / unlock_level
	production_list = []
	_sync_production_unlocks()

	_create_visual()
	_update_collision_shape()

# 按 unlock_level 同步生产列表：
# 旧数据没有 unlock_level 时仍按数组下标推导等级；
# 同一等级可以一次解锁多个单位（如船坞4级的炮艇+爆破船）。
func _sync_production_unlocks():
	if not is_inside_tree():
		return
	var full: Array = building_data.get("produces", [])
	if full.is_empty():
		return
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if bm and bm.has_method("is_research_mode") and bm.is_research_mode():
		# 科研模式：生产列表完全由已研究科技决定，不再看建筑等级。
		production_list = []
		for i in range(full.size()):
			var prod: Dictionary = full[i]
			var uid: int = int(prod.get("unit_id", -1))
			if uid >= 0 and bm.is_unit_unlocked(uid, owner_peer_id, team):
				if bm.has_method("is_training_unit_allowed") and not bm.is_training_unit_allowed(uid):
					continue
				production_list.append(prod.duplicate())
		return
	for i in range(full.size()):
		var prod: Dictionary = full[i]
		var unlock_lv: int = int(prod.get("unlock_level", i + 1))
		if unlock_lv > upgrade_level:
			continue
		var uid: int = int(prod.get("unit_id", -1))
		if bm and bm.has_method("is_training_unit_allowed") and not bm.is_training_unit_allowed(uid):
			continue
		var exists: bool = false
		for old in production_list:
			if int(old.get("unit_id", -1)) == uid:
				exists = true
				break
		if not exists:
			production_list.append(prod.duplicate())

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

# 找到本建筑所属玩家/阵营的主城。不能无条件用 get_player_castle()：
# 那里只返回 BLUE 玩家主城，会让 AI 的兵营等建筑永远被人类玩家主城等级卡在 1 级。
func _get_upgrade_castle() -> Building:
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if bm == null:
		return null
	var best: Building = null
	var nodes = bm.get("entities")
	if nodes != null:
		for e in nodes.get_children():
			if not (e is Building) or e.health <= 0 or int(e.entity_id) not in [20, 53]:
				continue
			if int(e.team) != team:
				continue
			# owner 未分配的建筑按同队匹配；有 owner 时必须同 owner，避免 2v2 同队串用主城等级
			if owner_peer_id != -1 and int(e.owner_peer_id) not in [-1, owner_peer_id]:
				continue
			if best == null or int(e.upgrade_level) > int(best.upgrade_level):
				best = e
	if best != null:
		return best
	if bm.has_method("get_castle_by_team"):
		return bm.get_castle_by_team(team)
	if team == RTSConfig.Team.BLUE and bm.has_method("get_player_castle"):
		return bm.get_player_castle()
	if team == RTSConfig.Team.RED and bm.has_method("get_enemy_castle"):
		return bm.get_enemy_castle()
	return null

func can_upgrade() -> bool:
	if build_timer > 0: return false
	if upgrade_timer > 0: return false
	# 科研模式没有建筑等级升级；成长全部来自科技树。
	var rbm = _get_bm()
	if rbm != null and rbm.has_method("is_research_mode") and rbm.is_research_mode():
		return false
	# 修理中不开新工程：两套计时同时跑会让进度条和脚手架状态互相打架
	if repair_timer > 0: return false
	if upgrade_level >= max_upgrade_level: return false
	# 同一国家/玩家的一种建筑同时只能有一个升级工程。
	# 本作升级是全局生效的（升级完成后同类型建筑一起提升），
	# 若允许两座同时读条，会重复扣费并让 team_building_levels 连升两级。
	if _other_same_type_is_upgrading():
		return false
	# Cannot upgrade beyond own castle level (except castle itself)
	if entity_id not in [20, 53]:
		var castle = _get_upgrade_castle()
		if castle and upgrade_level >= castle.upgrade_level:
			return false
	return true

# 与 upgrade_building_type 使用的归属键保持一致：
# 有 owner_peer_id 时按玩家区分（2v2/3v3/FFA），否则按阵营区分（1v1）。
func _upgrade_owner_key() -> int:
	return owner_peer_id if owner_peer_id != -1 else team

func _other_same_type_is_upgrading() -> bool:
	var bm = _get_bm()
	if not bm:
		return false
	if bm.has_method("_ensure_cache_fresh"):
		bm._ensure_cache_fresh()
	var my_key: int = _upgrade_owner_key()
	for other in bm._buildings:
		if other == self or not is_instance_valid(other) or not (other is Building):
			continue
		if other.health <= 0 or other.entity_id != entity_id:
			continue
		if other.upgrade_timer <= 0.0:
			continue
		var other_key: int = other.owner_peer_id if other.owner_peer_id != -1 else other.team
		if other_key == my_key:
			return true
	return false

func try_produce(unit_id: int) -> bool:
	if build_timer > 0: return false
	# 官员总数受“可进驻建筑数”限制，必须在扣资源/入队之前拦截。
	# 联机时该判断在服务端执行，客户端 UI 只做同样的置灰提示。
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if bm and bm.has_method("can_produce_official") and not bm.can_produce_official(unit_id, self):
		return false
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
		var res_dict = bm.get_team_resources(team) if bm.has_method("get_team_resources") else (bm.player_resources if team == RTSConfig.Team.BLUE else bm.enemy_resources)
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
	if _owner_is_ai() and GameSettings.ai_difficulty >= GameSettings.AIDifficulty.HELL: spd2 *= 1.2
	max_upgrade_time = max(total_cost / 20.0, 5.0) / spd2
	upgrade_timer = max_upgrade_time
	return true

func _finish_upgrade():
	upgrade_timer = 0.0
	var bm = get_tree().get_first_node_in_group("battle_manager") as RTSBattleManager
	if bm and bm.has_method("upgrade_building_type"):
		bm.upgrade_building_type(team, entity_id, self)
	# 升级可能改变视野/攻击力，若建筑正被选中，范围圈同步刷新
	_sync_range_rings()

	# 升级完成警报（仅人类玩家自己，含位置和编队）
	if bm and bm.has_method("_show_hud_alert") and bm.is_progress_reportable(owner_peer_id, team):
		var group_str = ""
		var sm = bm.get_node_or_null("SelectionManager")
		if sm and sm.has_method("get_entity_groups"):
			var groups = sm.get_entity_groups(self)
			if groups.size() > 0:
				group_str = " [T%d]" % groups[0]
		var loc_str = "(%d,%d)" % [int(global_position.x), int(global_position.z)]
		# 主城（entity_id 20）升级是重要节点，标记出来让它不受队友筛选影响
		bm._show_hud_alert("升级完成: %s%s %s" % [display_name, group_str, loc_str], Color(0.2, 1.0, 0.3), [team], team, GameSettings.AlertKind.UPGRADE, entity_id == 20, bm.get_alert_nations(self), global_position, owner_peer_id)

func get_prod_cooldown(unit_id: int) -> float:
	var spd3 = 1.0
	if GameSettings.fast_mode: spd3 = 2.0
	if _owner_is_ai() and GameSettings.ai_difficulty >= GameSettings.AIDifficulty.HELL: spd3 *= 1.2
	for prod in production_list:
		if prod.unit_id == unit_id:
			return prod.cooldown / spd3
	return 1.0

# ==================== 贴地范围圈（视野 / 射程） ====================
# 单选建筑时和单位一样画两圈：视野细线、攻击射程粗线。建筑不能移动，
# 圈直接挂在建筑节点下即可；地形逐顶点采样由 GroundRangeRing 负责。
var _range_rings: Array = []
var _range_rings_selected: bool = false
var _range_rings_flag: int = -1
var _range_ring_height_fn: Callable
const RANGE_RING_MIN_ATTACK: float = 1.5

func set_selected(selected: bool) -> void:
	super.set_selected(selected)
	_range_rings_selected = selected
	_sync_range_rings()

# SelectionManager 在单选/多选/取消选中时显式同步；多选时不画，避免地面糊成一片
func set_range_rings_enabled(enabled: bool) -> void:
	_range_rings_flag = 1 if enabled else 0
	_sync_range_rings()

func _sync_range_rings() -> void:
	if not _range_rings_selected or _range_rings_flag == 0:
		_set_range_rings_visible(false)
		return
	var specs: Array = get_range_ring_specs()
	if specs.is_empty():
		_set_range_rings_visible(false)
		return
	if _range_ring_layout_changed(specs):
		_rebuild_range_rings(specs)
	else:
		for i in range(specs.size()):
			_range_rings[i].set_radius(float(specs[i]["radius"]))
	_set_range_rings_visible(true)

func get_range_ring_specs() -> Array:
	var specs: Array = []
	if health <= 0:
		return specs
	if vision_range >= RANGE_RING_MIN_ATTACK:
		var eff_vision: float = vision_range
		var bm = _get_bm()
		if bm != null and bm.has_method("get_effective_vision"):
			eff_vision = float(bm.get_effective_vision(self))
		if eff_vision >= RANGE_RING_MIN_ATTACK:
			specs.append({
				"kind": GroundRangeRing.Kind.VISION,
				"radius": eff_vision,
				"outline": Callable(self, "_vision_outline"),
			})
	if attack_range >= RANGE_RING_MIN_ATTACK:
		specs.append({"kind": GroundRangeRing.Kind.ACTION, "radius": attack_range})
	return specs

# 视野轮廓回调：建筑也从模型顶部（烟囱/屋顶）向下看，山脊和森林挡住的
# 方向会按真实视线缩回来。
func _vision_outline(center: Vector3, radius: float) -> Array:
	var bm = _get_bm()
	var map = VisionSystem.resolve_map(bm) if bm != null else null
	if map == null:
		return GroundStripMesh.circle_points(center, radius)
	var live_radius: float = radius
	if bm != null and bm.has_method("get_effective_vision"):
		live_radius = float(bm.get_effective_vision(self))
	return VisionSystem.compute_visibility_outline(map, get_vision_origin(), live_radius, 80)

func _range_ring_layout_changed(specs: Array) -> bool:
	if _range_rings.size() != specs.size():
		return true
	for i in range(specs.size()):
		var ring = _range_rings[i]
		if not is_instance_valid(ring):
			return true
		if int(ring.kind) != int(specs[i]["kind"]):
			return true
	return false

func _rebuild_range_rings(specs: Array) -> void:
	_clear_range_rings()
	if not is_inside_tree():
		return
	if not _range_ring_height_fn.is_valid():
		_range_ring_height_fn = GroundStripMesh.height_fn_for(_get_bm())
	for spec in specs:
		var outline: Callable = spec.get("outline", Callable())
		var ring = GroundRangeRing.create(int(spec["kind"]), float(spec["radius"]), _range_ring_height_fn, Color(0, 0, 0, 0), outline)
		ring.visible = false
		add_child(ring)
		_range_rings.append(ring)

func _clear_range_rings() -> void:
	for ring in _range_rings:
		if is_instance_valid(ring):
			ring.set_ring_visible(false)
			ring.queue_free()
	_range_rings.clear()

func _set_range_rings_visible(on: bool) -> void:
	for ring in _range_rings:
		if is_instance_valid(ring):
			ring.set_ring_visible(on)

# ==================== 修理 ====================
# 规则：残破建筑可以修理（主城除外）。玩家在敌军附近也能修理；
# AI 为了尽量保证修理成功，仍会避开附近 10 米内有敌方部队的建筑。
# 花钱 = 已损生命百分比 × 原价，耗时 = 已损生命百分比 × 建造时间（建造时间沿用 start_construction 的公式）。
# 修理过程复用建造那套脚手架/扬尘/进度表现，服务端与联机客户端共用 BuildingConstructionVisual。
const REPAIR_BLOCK_RADIUS: float = 10.0        # AI 的修理安全半径：这个范围内有敌方部队就放弃
const REPAIR_SCAN_INTERVAL: float = 0.5        # AI 附近敌人扫描频率（秒）
const BUILD_TIME_PER_HP: float = 75.0          # 与 start_construction 一致：满血建造耗时 = max_health / 75
const MAX_BUILDERS: int = 3                    # 单座建筑最多登记 3 个农民
const BUILDER_ARRIVE_PAD: float = 2.2          # 到建筑外缘多近才算「站在旁边」
const BUILDER_SPEED_MULT: Array = [1.0, 1.5, 2.0]  # 1/2/3 个农民同时到场时的施工速度

var repair_timer: float = 0.0                  # >0 表示正在修理
var max_repair_time: float = 0.0
var _repair_from_health: int = 0
var _repair_to_health: int = 0
var _repair_enemy_near: bool = false
var _repair_scan_timer: float = randf_range(0.0, REPAIR_SCAN_INTERVAL)

func is_under_repair() -> bool:
	return repair_pending or repair_timer > 0.0

func _repair_forbidden() -> bool:
	# 主城（20）和主城系（53）关系整局胜负，不允许修理
	return entity_id in [20, 53]

func _model_health_max() -> int:
	# 建筑本身的血量上限（升级会提高它），不是配置里的初始值
	return maxi(int(max_health), 1)

# 已损生命百分比：0 = 满血，1 = 空血
func repair_damage_ratio() -> float:
	return clampf(1.0 - float(health) / float(_model_health_max()), 0.0, 1.0)

func _repair_base_cost() -> Dictionary:
	var cfg: Dictionary = building_data if not building_data.is_empty() else EntityDatabase.get_config(entity_id)
	var cost = cfg.get("cost", {})
	return cost if cost is Dictionary else {}

# 修理费 = 已损生命百分比 × 原价（向上取整，避免残血修理免费）
func repair_cost() -> Dictionary:
	var ratio := repair_damage_ratio()
	var out := {}
	if ratio <= 0.0:
		return out
	var base := _repair_base_cost()
	var discount := 0.0
	var rbm = _get_bm()
	if rbm != null and rbm.has_method("is_research_mode") and rbm.is_research_mode():
		var mods: Dictionary = rbm.get_research_mods(owner_peer_id, team)
		discount = float(mods.get("repair_cost_pct", 0.0)) / 100.0
	for k in base:
		var v: int = int(ceil(float(base[k]) * ratio * (1.0 + discount)))
		if v > 0:
			out[k] = v
	return out

# 满血建造耗时：与 start_construction 的 max_build_time 同源
func _repair_full_build_time() -> float:
	var cfg: Dictionary = building_data if not building_data.is_empty() else EntityDatabase.get_config(entity_id)
	var hp: float = float(cfg.get("max_health", _model_health_max()))
	return maxf(hp / BUILD_TIME_PER_HP, 0.1)

# 修理耗时 = 已损生命百分比 × 建造时间（快进/地狱难度与建造同倍率加速）
func repair_time_total() -> float:
	var spd := 1.0
	if GameSettings.fast_mode: spd = 2.0
	if _owner_is_ai() and GameSettings.ai_difficulty >= GameSettings.AIDifficulty.HELL: spd *= 1.2
	return maxf(repair_damage_ratio() * _repair_full_build_time() / spd, 0.1)

func _has_enemy_near_repair() -> bool:
	var bm = _get_bm()
	if bm == null or not bm.has_method("get_nearby_enemies"):
		return false
	var radius := REPAIR_BLOCK_RADIUS + body_radius
	var found = bm.get_nearby_enemies(global_position, radius, team, owner_peer_id, true)
	if found == null:
		return false
	for e in found:
		# AI 只把敌方「部队」算作威胁：敌方建筑在 10 米内是正常前线，不该阻止 AI 修墙
		if is_instance_valid(e) and e is Army and e.health > 0:
			return true
	return false

func _tick_repair_scan(delta: float) -> void:
	_repair_scan_timer -= delta
	if _repair_scan_timer > 0.0:
		return
	_repair_scan_timer = REPAIR_SCAN_INTERVAL
	# 玩家修理不受附近敌军限制，不需要为玩家建筑反复扫描敌人。
	if not _owner_is_ai():
		return
	_repair_enemy_near = _has_enemy_near_repair()

func can_repair() -> bool:
	var rbm = _get_bm()
	if rbm != null and rbm.has_method("is_research_mode") and rbm.is_research_mode():
		var rs = rbm.get_research_state(owner_peer_id, team)
		if not bool(rs.get("mods", {}).get("repair_enabled", 0.0) > 0.0):
			return false
	if _repair_forbidden():
		return false
	if health <= 0:
		return false
	# 建造中/升级中/已经在修：都不允许再开一个工程
	if build_timer > 0.0 or upgrade_timer > 0.0 or repair_timer > 0.0 or repair_pending:
		return false
	if health >= _model_health_max():
		return false
	# 玩家可以在敌军旁边强行修理；AI 仍避开附近有敌方部队的建筑，减少修到一半被拆。
	if _owner_is_ai() and _repair_enemy_near:
		return false
	return true

# 扣除修理费并登记为「等待农民」。真正开始计时由 _tick_repair 在农民到场后推进。
# 联机时只在服务端调用（客户端 UI 只做同样的置灰提示）。
func begin_repair(bm) -> bool:
	if not can_repair():
		return false
	if bm == null:
		return false
	var cost := repair_cost()
	if not cost.is_empty():
		var paid := false
		if owner_peer_id != -1 and bm.has_method("deduct_player_resources"):
			paid = bm.deduct_player_resources(owner_peer_id, cost)
		elif bm.has_method("deduct_resources_for"):
			paid = bm.deduct_resources_for(owner_peer_id if owner_peer_id != -1 else team, cost)
		if not paid:
			return false
	_repair_from_health = health
	_repair_to_health = _model_health_max()
	max_repair_time = repair_time_total()
	repair_timer = 0.0
	repair_pending = true
	# 建造那套脚手架 + 扬尘，但模型保持完整（repair=true 时不缩模型）
	BuildingConstructionVisual.begin(self, null, true)
	return true

# 兼容旧调用：现在只登记工程，等农民到场才真正开始计时。
func perform_repair(bm) -> bool:
	return begin_repair(bm)

func _tick_repair(delta: float) -> void:
	if health <= 0:
		# 修理途中被拆掉：清掉施工外观
		BuildingConstructionVisual.cancel(self)
		repair_timer = 0.0
		max_repair_time = 0.0
		repair_pending = false
		_release_builders()
		return
	_refresh_builder_cache(delta)
	if repair_pending:
		if active_builder_count_cache <= 0:
			# 已扣费但农民还在路上：保持等待，不推进进度
			return
		repair_pending = false
		repair_timer = max_repair_time
	if repair_timer <= 0.0:
		return
	# 农民中途离开/死亡：暂停计时，保留已修好的血量
	if active_builder_count_cache <= 0:
		return
	var speed_mult: float = BUILDER_SPEED_MULT[clampi(active_builder_count_cache - 1, 0, BUILDER_SPEED_MULT.size() - 1)]
	repair_timer -= delta * speed_mult
	var total := maxf(max_repair_time, 0.001)
	var progress := clampf(1.0 - repair_timer / total, 0.0, 1.0)
	BuildingConstructionVisual.update(self, progress)
	# 血量随进度回升：中途被打断也保留了已经修好的部分
	var target := int(round(lerpf(float(_repair_from_health), float(_repair_to_health), progress)))
	if target > health:
		health = mini(target, _model_health_max())
	if Engine.get_process_frames() % 40 == 0:
		AudioManager.play_sfx("build_loop")
	if repair_timer <= 0.0:
		_finish_repair()

func _finish_repair() -> void:
	repair_timer = 0.0
	max_repair_time = 0.0
	repair_pending = false
	health = clampi(maxi(health, _repair_to_health), 1, _model_health_max())
	BuildingConstructionVisual.finish(self)
	_release_builders()
	AudioManager.play_sfx("upgrade_done")
	var bm = _get_bm()
	if bm and bm.has_method("_show_hud_alert") and bm.is_progress_reportable(owner_peer_id, team):
		var loc_str := "(%d,%d)" % [int(global_position.x), int(global_position.z)]
		bm._show_hud_alert("修理完成: %s %s" % [display_name, loc_str], Color(0.35, 0.95, 0.45), [team], team, GameSettings.AlertKind.UPGRADE, false, bm.get_alert_nations(self), global_position, owner_peer_id)

	
	

# 添加特色兵种到生产列表（仅添加一次）
func _unlock_nation_units(nation: int):
	# 确保 NationData 已初始化
	NationData._static_init()
	var bm = get_tree().get_first_node_in_group("battle_manager")
	var research: bool = bm != null and bm.has_method("is_research_mode") and bm.is_research_mode()
	var units = NationData.NATION_UNITS.get(nation, [])
	for u in units:
		# 跳过农民（id 10），因为城堡本来就能生产
		if u["unit_id"] == 10:
			continue
		# 科研模式：特色兵种由对应通用科技解锁，城堡只负责提供生产建筑。
		if research and not bm.is_unit_unlocked(int(u["unit_id"]), owner_peer_id, team):
			continue
		# 检查是否已存在
		var exists = false
		for prod in production_list:
			if prod.unit_id == u["unit_id"]:
				exists = true
				break
		if not exists:
			if bm and bm.has_method("is_training_unit_allowed") and not bm.is_training_unit_allowed(int(u["unit_id"])):
				continue
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

# 一面墙最多挂一座炮台，位置与墙同格；墙体消失时炮台不能悬空。
func _destroy_wall_cannons() -> void:
	var bm = _get_bm()
	if bm == null or bm.entities == null:
		return
	var wall_grid: Vector2i = bm.world_to_grid(global_position)
	for e in bm.entities.get_children():
		if e == self or not (e is Building) or e.health <= 0:
			continue
		if int(e.entity_id) != 64 or e.team != team:
			continue
		if bm.world_to_grid(e.global_position) != wall_grid:
			continue
		e.die()

func die():
	if _is_dead:
		return
	# 城墙被摧毁时，墙顶炮台失去支撑，自动一起摧毁。
	if entity_id == 27:
		_destroy_wall_cannons()
	# 先释放所有进驻单位，再执行死亡逻辑
	release_all_garrisoned()
	# 修理中被打掉：清掉施工脚手架，别让残骸挂着木头架子
	if repair_timer > 0.0 or repair_pending:
		repair_timer = 0.0
		max_repair_time = 0.0
		repair_pending = false
		BuildingConstructionVisual.cancel(self)
	_release_builders()
	# 脚下的土色脱离建筑独立淡出，不会跟着模型一起瞬间消失
	_fade_ground_patch()
	super.die()

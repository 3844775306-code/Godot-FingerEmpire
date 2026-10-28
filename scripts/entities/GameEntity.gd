
class_name GameEntity
extends CharacterBody3D

signal died

const BuildingDeathEffect = preload("res://scripts/effects/BuildingDeathEffect.gd")
const BuildingConstructionVisual = preload("res://scripts/effects/BuildingConstructionVisual.gd")
const TreeFallEffect = preload("res://scripts/effects/TreeFallEffect.gd")
const EntityDamageVisual = preload("res://scripts/effects/EntityDamageVisual.gd")

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
# 推挤质量：0 表示按体半径自动推导（体积近似）；配置里可填 mass 覆盖
var mass: float = 0.0
var can_move: bool = false
var vision_range: float = 10.0
# 模型顶部高度缓存：视野起点 = 脚底 + 这个高度。模型换装/升级后要重置。
var _vision_head_height: float = -1.0

var gather_amount: float = 0.0
var regeneration_rate: float = 0.0

var production_list: Array = []
var production_timer: float = 0.0
var production_queue: Array = []

var attack_timer: float = 0.0
# 每次真正出手递增；联机快照用它让客户端“一次攻击只播一次”攻击动画
var attack_seq: int = 0
var gather_timer: float = 0.0
# 目标引用不设静态类型：实体可能在同一帧被击杀并 queue_free，强类型赋值会直接
# 报 "Trying to assign invalid previously freed instance"。使用处统一用
# is_instance_valid 判断，命令队列里的旧目标也要在执行前校验。
var current_target = null
var current_order: String = ""
var nav_agent: NavigationAgent3D

var shock_timer: float = 0.0
var freeze_timer: float = 0.0
var owner_peer_id: int = -1
var piercing: bool = false                  # 长枪兵穿透（无视军队护甲）
var ignore_building_armor: bool = false     # 攻城车无视建筑护甲
var ignore_armor: bool = false               # 无视目标护甲（爆破船等）
# ── 科研模式运行时加成（由 RTSBattleManager.apply_research_bonuses 写入）──
# 这些字段只影响结算，不改变经典模式的任何行为（科研关闭时保持默认值）。
var shield_pierce: float = 0.0               # 0~1，弓箭类对盾甲的穿透比例
var melee_pierce: float = 0.0                # 0~1，步兵类对近战护甲的穿透比例
var building_damage_pct: float = 0.0         # 对建筑伤害加成（0.2 = +20%）
var vs_archer_pct: float = 0.0               # 对弓箭类伤害加成
var vs_cavalry_pct: float = 0.0              # 对骑兵类伤害加成
var vs_ship_pct: float = 0.0                 # 对船只伤害加成
var spell_power_mult: float = 1.0            # 法术强度倍率（治疗/长老/宗师）
var spell_resist: float = 0.0                # 受到法术伤害/降攻的减免比例
var accuracy_mult: float = 1.0               # 投石机散布倍率（越小越准）
var splash_damage_mult: float = 0.0          # 炮弹溅射倍率；0 = 沿用默认 30%
var volley_count: int = 1                    # 主城/城堡齐射箭数
var volley_mult: float = 1.0                 # 每支箭的伤害倍率
var _research_base_stats: Dictionary = {}    # 科研加成前的基础数值快照
# 信息面板分项显示用：基础值快照（等级/升级已计入，国家加成之前）
var _base_stats_raw: Dictionary = {}
# 套用科研、但尚未套用官员效果时的属性快照；当前值减它 = 官员加成
var _stats_before_official: Dictionary = {}
var _base_attack: float = 0.0               # 驻军前原始攻击力（用于还原）
var _base_attack_speed: float = 0.0         # 驻军前原始攻速（攻城车专用）
var _base_speed: float = 0.0                # 驻军前原始移速（攻城车专用）

# 缓存的 BattleManager 引用 — 避免每帧场景树遍历
var _bm: RTSBattleManager = null
# 死亡幂等标记：围殴时同一帧/死亡动画期间的多次命中不能重复触发 died，
# 否则城堡计数的队伍会重复扣减，导致 2v2/3v3 提前判负
var _is_dead: bool = false
# 正在播放沉水动画：水面着色器据此在落水点生成涟漪，平面反射也会排除该模型
var is_sinking: bool = false
# 沉水模型要移出的渲染层（与 Ground.gd 的 REFLECT_SKIP_LAYER 保持一致）
const REFLECT_SKIP_LAYER: int = 18

func _get_bm():
	if not is_instance_valid(_bm):
		_bm = get_tree().get_first_node_in_group("battle_manager") as RTSBattleManager
	return _bm

func _exit_tree() -> void:
	# 任何实体离开场景树都让实体缓存失效。相比只依赖 die()，这里还能覆盖
	# queue_free、运输船销毁、场景切换等没有走正常死亡流程的移除。
	if is_instance_valid(_bm) and _bm.is_inside_tree():
		_bm.mark_entity_cache_dirty()

func _get_cam_pos() -> Vector3:
	var cam = get_viewport().get_camera_3d()
	return cam.global_position if cam else Vector3.ZERO

# ==================== 视野 ====================
# 实际模型顶部高度（单位/建筑统一）。模型还没挂上时按体型兜底，但不写缓存，
# 等模型就绪后再算一次真实高度。
func get_vision_head_height() -> float:
	if _vision_head_height > 0.05:
		return _vision_head_height
	var h: float = VisionSystem.node_head_height(self)
	if h > 0.05:
		_vision_head_height = h
		return h
	return maxf(1.2, body_radius * 2.0)

func reset_vision_head_height() -> void:
	_vision_head_height = -1.0

# 视野判定起点：脚底 + 头顶高度，不是脚底。
func get_vision_origin() -> Vector3:
	return global_position + Vector3.UP * get_vision_head_height()

# 目标是否在头顶 1.5 米以内：先做便宜的高度过滤，再做地形/森林视线。
func can_see_target_height(target_pos: Vector3) -> bool:
	return target_pos.y <= get_vision_origin().y + VisionSystem.HEAD_CLEARANCE

# 仅在玩家视野内播放音效
func _play_sfx_if_visible(key: String, pitch: float = 1.0):
	var bm = _get_bm()
	if bm and bm.has_method("is_position_in_player_vision"):
		if bm.is_position_in_player_vision(global_position):
			AudioManager.play_sfx_3d(key, global_position, _get_cam_pos(), pitch)
	else:
		AudioManager.play_sfx_3d(key, global_position, _get_cam_pos(), pitch)

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
	mass = config.get("mass", 0.0)
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
	ignore_armor = config.get("ignore_armor", false)
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
	# 血量变化需要同时反映到建筑残破/资源枯竭外观；低频刷新也能覆盖回血和升级。
	if Engine.get_process_frames() % 30 == 0:
		_refresh_damage_visual()

# 只处理建筑和资源；军队的外观由模型动画负责。
func _refresh_damage_visual() -> void:
	if health <= 0.0 or max_health <= 0.0:
		return
	var ratio := clampf(health / max_health, 0.0, 1.0)
	if self is Building:
		# 建造中模型被施工动画压扁/缩放；完成复位后再启用受损外观，避免两套变换打架。
		if float(get("build_timer")) > 0.0:
			return
		EntityDamageVisual.update_building(self, ratio)
	elif self is WorldResource:
		EntityDamageVisual.update_resource(self, ratio)

# 远程判定：攻击距离超过近战上限的单位可以射击墙顶/船上的目标。
# 近战单位（步兵、骑兵、攻城车等）必须先拆掉保护物。
func is_ranged_attacker() -> bool:
	return attack_range > 1.5

# 子类覆盖：运载船上的单位、城墙上的单位在保护物存活时免疫伤害。
# source 用于区分攻击类型：远程攻击可以打墙顶单位，近战不行。
func is_immune_to_damage(_source = null) -> bool:
	return false

func _stat_snapshot() -> Dictionary:
	return {
		"max_health": max_health,
		"attack": attack,
		"attack_speed": attack_speed,
		"attack_range": attack_range,
		"speed": speed,
		"vision_range": vision_range,
		"melee_armor": melee_armor,
		"shield_armor": shield_armor,
		"damage_radius": damage_radius,
	}

func _capture_research_base() -> void:
	_research_base_stats = _stat_snapshot()

# 等级缩放后的原始基础值。必须在国家加成之前调用。
func _capture_base_stats() -> void:
	_base_stats_raw = _stat_snapshot()

# 科研之后、官员光环之前。官员加成 = 当前值 - 该快照。
func _capture_stats_before_official() -> void:
	_stats_before_official = _stat_snapshot()

# 建筑升级会直接加基础属性：把升级增量同步进三份快照，
# 这样面板里的“基础/国家/科研/官员”分项不会把升级算进科研或官员。
func apply_upgrade_stat_delta(upgrade: Dictionary) -> void:
	var delta := {
		"max_health": float(upgrade.get("health_bonus", 0)),
		"attack": float(upgrade.get("attack_bonus", 0)),
		"melee_armor": float(upgrade.get("melee_armor_bonus", upgrade.get("armor_bonus", 0))),
		"shield_armor": float(upgrade.get("shield_armor_bonus", upgrade.get("armor_bonus", 0))),
	}
	for snap in [_base_stats_raw, _research_base_stats, _stats_before_official]:
		if not (snap is Dictionary) or snap.is_empty():
			continue
		for key in delta:
			if snap.has(key):
				snap[key] = float(snap[key]) + float(delta[key])

func take_damage(amount: float, source = null):
	if _is_dead or health <= 0.0:
		return
	# source 可能来自已经消失的弹丸/旧目标；先清空失效引用，避免后面强类型属性访问
	if source != null and not is_instance_valid(source):
		source = null
	if is_immune_to_damage(source):
		return
	# Officials are immune while garrisoned
	if entity_id >= 46 and entity_id <= 50:
		var gb = get("_garrison_building")
		if gb and gb.get_ref():
			amount *=0.3
	var eff_armor: float = melee_armor
	if source:
		_last_damager = source
		# 科研模式目标类型加成：对建筑/弓箭/骑兵/船只的额外伤害。
		if self is Building and source.building_damage_pct > 0.0:
			amount *= 1.0 + source.building_damage_pct
		elif self is Army:
			if source.vs_archer_pct > 0.0 and TechTreeData.unit_has_class(entity_id, "archer"):
				amount *= 1.0 + source.vs_archer_pct
			if source.vs_cavalry_pct > 0.0 and TechTreeData.unit_has_class(entity_id, "cavalry"):
				amount *= 1.0 + source.vs_cavalry_pct
			if source.vs_ship_pct > 0.0 and TechTreeData.unit_has_class(entity_id, "ship"):
				amount *= 1.0 + source.vs_ship_pct
		# 动物被攻击后反击
		if self is Army and self.get("_animal_type") != "" and self.get("_animal_type") != null:
			self.set("_animal_retaliating", true)
			self.set("_animal_attacker", source)
			
		# 远程攻击(target_type=3) → 使用盾牌护甲
		if source.target_type == 3:
			eff_armor = shield_armor
			if source.shield_pierce > 0.0:
				eff_armor *= 1.0 - clampf(source.shield_pierce, 0.0, 1.0)
		elif source.melee_pierce > 0.0:
			eff_armor *= 1.0 - clampf(source.melee_pierce, 0.0, 1.0)

		# 爆破船等特殊单位无视护甲
		if source.ignore_armor:
			eff_armor = 0.0
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
	var _should_alert = (bm != null and team == bm.get_host_team()) and not _is_animal_attacker
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
					# 文案里不写「我方」：这条警报对任何队伍的单位都会触发，
					# 是谁被攻击交给前面的彩色国家前缀说明，否则队友挨打会误写成「我方」
					var msg = ""
					if entity_id == 20:
						msg = "基地正遭受攻击！%s%s" % [loc_str, group_str]
					else:
						msg = "%s正遭受攻击 %s%s" % [display_name, loc_str, group_str]
					# 攻守双方都带上：攻击方在前、被攻击方在后。
					# 同时给国家索引，2v2 里同队不同国才不会把队友的战报说成「我方」
					var atk_team: int = int(source.team) if source and is_instance_valid(source) else -1
					var atk_nation: int = int(bm.get_entity_nation(source)) if source and is_instance_valid(source) else -1
					var my_nation: int = int(bm.get_entity_nation(self))
					bm._show_hud_alert(msg, Color(1.0, 0.2, 0.1), [atk_team, team], team,
						GameSettings.AlertKind.COMBAT, false, [atk_nation, my_nation])
					bm._set_alert_cooldown(cooldown_key, 3.0)
	# 乱斗 FFA 军事伤害背叛上报：军队对当前仍结盟的盟友造成军事伤害 → 揭发背叛。
	# notify_military_attack 内部会再校验 is_ally；非盟/同国/中立伤害均不产生副作用。
	if actual_damage > 0 and bm and bm.diplomacy and bm.diplomacy.active:
		if source and is_instance_valid(source) and source.owner_peer_id >= 0 and owner_peer_id >= 0 and source.owner_peer_id != owner_peer_id and not (self is WorldResource):
			bm.diplomacy.notify_military_attack(source.owner_peer_id, owner_peer_id)
	if health <= 0:
		die()
	else:
		_refresh_damage_visual()
# 子类（Army）覆盖：是否播放沉水动画而不是毁坏模型/死亡动作
func _should_sink_death() -> bool:
	return false

# 沉水动画：关闭碰撞与行为，1 秒内下沉并轻微倾斜，随后移除。
# 死亡状态在 die() 中已立即生效（health=0、_is_dead=true），
# 因此动画期间不会被选中、索敌或再次受伤。
# 递归给所有可见网格加/去反射排除层（模型可能是多层嵌套的子节点）
func _set_reflection_hidden(hidden: bool) -> void:
	_apply_reflection_bit(self, hidden)

func _apply_reflection_bit(node: Node, hidden: bool) -> void:
	if node is GeometryInstance3D:
		if hidden:
			node.layers |= 1 << REFLECT_SKIP_LAYER
		else:
			node.layers &= ~(1 << REFLECT_SKIP_LAYER)
	for child in node.get_children():
		_apply_reflection_bit(child, hidden)

func _start_sink_death() -> void:
	collision_layer = 0
	collision_mask = 0
	is_sinking = true
	set_selected(false)
	# 沉入水下的模型会被水面下的镜像相机看到，倒影会"浮"到水面上方，
	# 所以把下沉中的模型移出反射层，只保留主相机可见
	_set_reflection_hidden(true)
	for child in get_children():
		if child is CollisionShape3D:
			child.set_deferred("disabled", true)
	var sink_depth: float = maxf(2.0, body_radius * 4.0)
	var tween := create_tween()
	tween.set_parallel(true)
	var down_tw = tween.tween_property(self, "global_position:y", global_position.y - sink_depth, 1.0)
	down_tw.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	var roll_tw = tween.tween_property(self, "rotation:z", rotation.z + deg_to_rad(18.0), 1.0)
	roll_tw.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.chain().tween_callback(queue_free)

# 动物死亡表现：模型侧倒并下沉一点，动画结束后再释放，
# 避免被一箭射死后直接凭空消失。鱼的死亡走沉水逻辑，这里不处理。
func _play_animal_death() -> void:
	collision_layer = 0
	collision_mask = 0
	var model: Node3D = null
	if has_meta("_model_instance") and is_instance_valid(get_meta("_model_instance")):
		model = get_meta("_model_instance")
	if model == null:
		queue_free()
		return
	var dur: float = 0.85
	var tween := create_tween()
	tween.set_parallel(true)
	# 绕侧向轴倒下 86 度，最后一帧看着像躺在地上
	tween.tween_property(model, "rotation:z", model.rotation.z + deg_to_rad(86.0), dur * 0.65) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_property(model, "position:y", model.position.y - 0.3, dur) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tween.chain().tween_callback(queue_free)

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
	# 立即让实体缓存失效，避免 AI 在本帧后续查询中继续拿到已死亡/即将释放的对象
	var _bm_cache = _get_bm()
	if _bm_cache and _bm_cache.has_method("mark_entity_cache_dirty"):
		_bm_cache.mark_entity_cache_dirty()
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
	# 建筑统一走程序化倒塌：模型倾斜下沉、碎屑尘土，动画结束后再释放实体。
	# 死亡状态、人口扣除和缓存失效已在上面立即完成，动画不会影响战斗判定。
	if self is Building:
		# 建造中被打爆时先收起脚手架并恢复模型，避免死亡特效从压扁状态开始。
		BuildingConstructionVisual.cancel(self)
		var model_ref: Node3D = null
		if has_meta("_model_instance") and is_instance_valid(get_meta("_model_instance")):
			model_ref = get_meta("_model_instance")
		var effect_duration: float = BuildingDeathEffect.play(self, entity_id, body_radius, model_ref)
		if effect_duration > 0.0:
			return
	# 木材资源被采空：整棵树绕根部倒下，扬尘/落叶后释放。
	if self is WorldResource and (entity_id == 1 or str(get("resource_type")) == "wood"):
		var tree_model_ref: Node3D = null
		if has_meta("_model_instance") and is_instance_valid(get_meta("_model_instance")):
			tree_model_ref = get_meta("_model_instance")
		var tree_effect_duration: float = TreeFallEffect.play(self, body_radius, tree_model_ref)
		if tree_effect_duration > 0.0:
			return
	# 船只被击沉 / 陆地单位落水：沉入水中 1 秒后移除。
	# 此时 health 已为 0、碰撞已关闭，敌方无法再选中或攻击它。
	if _should_sink_death():
		_start_sink_death()
		return
	# 动物死亡：侧倒并下沉后释放（鱼走上面的沉水逻辑，这里排除）
	if self is Army and str(get("_animal_type")) != "" and str(get("_animal_type")) != "fish":
		_play_animal_death()
		return
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
			# 毁坏模型也要按国家/队伍色染色，和正常模型保持一致
			var bm_tint = _get_bm()
			if bm_tint and bm_tint.has_method("_apply_team_tint") and entity_type != 0 and team != RTSConfig.Team.NEUTRAL:
				var tint: Color = bm_tint.get_entity_color(self)
				tint = Color(0.2 + tint.r * 0.8, 0.2 + tint.g * 0.8, 0.2 + tint.b * 0.8)
				bm_tint._apply_team_tint(self, tint)
		var t = Timer.new(); t.one_shot = true; t.wait_time = 0.3
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
	# 既没有毁坏模型、模型也没有 die 动画：程序化倒地再释放，避免单位凭空消失
	_play_generic_death()

# 通用死亡动作：模型侧倒并下沉一点，动画结束后释放。
# 建筑走倒塌特效、木材走倒树、船走沉水、动物走动物动画，都到不了这里；
# 剩下的普通单位（步兵/弓手/炮兵等）以前是直接 queue_free，看着像凭空消失。
func _play_generic_death() -> void:
	collision_layer = 0
	collision_mask = 0
	var model: Node3D = null
	if has_meta("_model_instance") and is_instance_valid(get_meta("_model_instance")):
		model = get_meta("_model_instance")
	if model == null:
		# 没有 3D 模型（占位可视的实体）：直接移除
		queue_free()
		return
	var dur: float = 0.8
	var tween := create_tween()
	tween.set_parallel(true)
	# 绕侧向轴倒下 84 度，同时整体下沉 0.35 米
	tween.tween_property(model, "rotation:z", model.rotation.z + deg_to_rad(84.0), dur * 0.6) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_property(model, "position:y", model.position.y - 0.35, dur) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tween.chain().tween_callback(queue_free)

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
	# 选中指示改成「模型边缘发光」（反向外壳描边），脚下的绿色选中环不再显示：
	# 环贴在地面上，单位一跑就露馅；描边挂在模型表面，跟着骨骼动画一起动，
	# 与战场融合得更好。环节点保留（模型里可能已经建好），只是永远隐藏。
	if has_node("SelectionRing"):
		$SelectionRing.visible = false
	SelectionOutline.apply(self, selected, _selection_outline_color())
	# 驻扎标记
	if selected:
		if "garrison_point" in self and self.garrison_point != Vector3.ZERO:
			_show_garrison_marker()
	else:
		_hide_garrison_marker()

# 描边颜色：己方亮绿、其它亮红，和原来选中环的语义一致。
# 单机里 player_team 由 battle_manager 提供（联机按自己的队伍），拿不到时退回 team 0。
func _selection_outline_color() -> Color:
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if bm != null and "player_team" in bm:
		if team == int(bm.get("player_team")):
			return SelectionOutline.DEFAULT_COLOR
		return Color(1.00, 0.55, 0.50, 0.88)
	if team == int(RTSConfig.Team.RED):
		return SelectionOutline.DEFAULT_COLOR
	return Color(1.00, 0.55, 0.50, 0.88)

func _spawn_produced_unit():
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
	var spawn_margin: float = maxf(1.0, float(config.get("body_radius", 0.5)) + 0.5)
	var spawn_pos = Vector3.ZERO
	if is_water_unit:
		spawn_pos = _find_water_spawn_near(global_position, spawn_margin)
	else:
		spawn_pos = _find_land_spawn_pos(spawn_margin)
	if spawn_pos == Vector3.ZERO:
		# 没有安全落点时不要把单位刷到未校验的随机坐标（那里可能是山腰/水里）。
		# 把队列推回队首，稍后重试；资源已扣，但绝不会生成在非法地形上。
		production_queue.push_front(unit_id)
		production_timer = 1.0
		return
	spawn_pos = _clamp_spawn_to_map(spawn_pos, spawn_margin)
	# 最后再校验一次：防止未来改动/兜底分支把单位放到山腰或深水
	if not _is_safe_production_spawn(bm, spawn_pos, is_water_unit):
		production_queue.push_front(unit_id)
		production_timer = 1.0
		return
	config["owner_peer_id"] = self.owner_peer_id  # 继承建筑所有权
	var entity = bm.spawn_entity(config, team, spawn_pos, self.level)
	if entity == null:
		# 生成失败同样重试，避免资源已扣却静默丢兵
		production_queue.push_front(unit_id)
		production_timer = 1.0
		return
	AudioManager.play_sfx("produce")
	if entity:
		entity.owner_peer_id = self.owner_peer_id   # 继承建筑所有权
		if bm.battle_stats:
			bm.battle_stats.record_produced_unit(self.owner_peer_id, team, unit_id)

		# 在线模式：按玩家统计人口（单人模式 spawn_entity 已处理，避免双计）
		if owner_peer_id != -1 and bm is OnlineBattleManager:
			bm.increase_player_population(owner_peer_id, 1)
		# 训练完成警报（仅人类玩家自己，含编队和位置）
		if bm.has_method("_show_hud_alert") and bm.is_progress_reportable(owner_peer_id, team):
			var unit_name = config.get("name", "单位")
			var group_str = ""
			var sm = bm.get_node_or_null("SelectionManager")
			if sm and sm.has_method("get_entity_groups"):
				var groups = sm.get_entity_groups(self)
				if groups.size() > 0:
					group_str = " [T%d]" % groups[0]
			var loc_str = "(%d,%d)" % [int(global_position.x), int(global_position.z)]
			bm._show_hud_alert("训练完成: %s%s %s" % [unit_name, group_str, loc_str], Color(0.2, 1.0, 0.3), [team], team, GameSettings.AlertKind.PRODUCE, false, bm.get_alert_nations(self), global_position, owner_peer_id)
	# 继承建筑的驻扎点
	if self is Building and self.garrison_point != Vector3.ZERO:
		if entity is Army and entity.has_method("_is_military") and entity._is_military():
			entity.set_garrison(self.garrison_point)

	if production_queue.size() > 0:
		var next_id = production_queue[0]
		for prod in production_list:
			if prod.unit_id == next_id:
				production_timer = _research_prod_cooldown(float(prod.cooldown), int(next_id))
				break

# 科研模式生产加速：I6 只加速军事单位；国家科技还可按兵种/具体单位加速训练。
func _research_prod_cooldown(base_cd: float, unit_id: int) -> float:
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if bm == null or not bm.has_method("is_research_mode") or not bm.is_research_mode():
		return base_cd
	var mods: Dictionary = bm.get_research_mods(owner_peer_id, team)
	var speed := 0.0
	var classes: Array = TechTreeData.UNIT_CLASSES.get(unit_id, [])
	var military := false
	for cls in classes:
		if cls in ["infantry", "archer", "cavalry", "siege", "ship", "caster", "heavy"]:
			military = true
		speed += float(mods.get("class_training_speed_pct:%s" % cls, 0.0)) / 100.0
	speed += float(mods.get("unit_training_speed_pct:%d" % unit_id, 0.0)) / 100.0
	if military:
		speed += float(mods.get("production_speed_pct", 0.0)) / 100.0
	return base_cd / maxf(0.2, 1.0 + speed)


# 将生产坐标夹到地图内部并留出单位体积，避免贴边建筑把单位刷到地图外
func _clamp_spawn_to_map(pos: Vector3, margin: float) -> Vector3:
	var half: float = RTSConfig.MAP_SIZE / 2.0
	var safe: float = maxf(0.5, margin)
	return Vector3(clampf(pos.x, -half + safe, half - safe), pos.y, clampf(pos.z, -half + safe, half - safe))

# 随机候选都失败时，从建筑中心向外按环搜索最近的可出生格子；保证落点仍在地图内
func _find_nearest_spawn_tile(center: Vector3, want_water: bool, margin: float) -> Vector3:
	var bm = get_tree().get_first_node_in_group("battle_manager") as RTSBattleManager
	if not bm or not bm.has_method("world_to_grid"):
		return Vector3.ZERO
	var center_tile: Vector2i = bm.world_to_grid(center)
	var half: float = RTSConfig.MAP_SIZE / 2.0
	var tile_margin: int = maxi(1, int(ceil(margin)))
	for r in range(0, RTSConfig.MAP_SIZE):
		# 只遍历当前环的边界，越靠近建筑越先找到
		for dx in range(-r, r + 1):
			var tiles: Array[Vector2i] = [
				Vector2i(center_tile.x + dx, center_tile.y - r),
				Vector2i(center_tile.x + dx, center_tile.y + r)
			]
			for tile in tiles:
				if tile.x < tile_margin or tile.x > RTSConfig.MAP_SIZE - 1 - tile_margin:
					continue
				if tile.y < tile_margin or tile.y > RTSConfig.MAP_SIZE - 1 - tile_margin:
					continue
				var terrain: int = bm.get_terrain_at_grid(tile.x, tile.y)
				if want_water:
					if terrain != 2:
						continue
				elif _is_spawn_blocked_terrain(terrain):
					continue
				elif bm.is_cliff_tile(tile.x, tile.y):
					continue
				var world_pos := Vector3(tile.x - half, 0.0, tile.y - half)
				if not want_water and not _is_flat_spawn_pos(bm, world_pos):
					continue
				if not want_water and _spawn_pos_blocked(world_pos):
					continue
				return _clamp_spawn_to_map(world_pos, margin)
		if r > 0:
			for dy in range(-r + 1, r):
				var side_tiles: Array[Vector2i] = [
					Vector2i(center_tile.x - r, center_tile.y + dy),
					Vector2i(center_tile.x + r, center_tile.y + dy)
				]
				for tile in side_tiles:
					if tile.x < tile_margin or tile.x > RTSConfig.MAP_SIZE - 1 - tile_margin:
						continue
					if tile.y < tile_margin or tile.y > RTSConfig.MAP_SIZE - 1 - tile_margin:
						continue
					var terrain: int = bm.get_terrain_at_grid(tile.x, tile.y)
					if want_water:
						if terrain != 2:
							continue
					elif _is_spawn_blocked_terrain(terrain):
						continue
					elif bm.is_cliff_tile(tile.x, tile.y):
						continue
					var world_pos := Vector3(tile.x - half, 0.0, tile.y - half)
					if not want_water and not _is_flat_spawn_pos(bm, world_pos):
						continue
					if not want_water and _spawn_pos_blocked(world_pos):
						continue
					return _clamp_spawn_to_map(world_pos, margin)
	return Vector3.ZERO

# 出生点地形判定：山（1）是陆军不能直接上去的高地形，水（2）只有水军能待。
# 即使山上有缓坡/台地，也不在坡面或台地上刷兵，避免部队卡在窄坡或孤岛台地。
func _is_spawn_blocked_terrain(terrain: int) -> bool:
	return terrain < 0 or terrain == 1 or terrain == 2

# 生产落点的最终校验：陆地单位不能在山/水/斜坡/半山腰，也不能压在已有实体上。
# 水面单位只要求是水域；具体深浅由海军寻路/移动再判断。
func _is_safe_production_spawn(bm: RTSBattleManager, pos: Vector3, is_water_unit: bool) -> bool:
	if bm == null:
		return true
	var terrain: int = bm.get_terrain_at(pos)
	if is_water_unit:
		return terrain == 2
	if _is_spawn_blocked_terrain(terrain):
		return false
	if not _is_flat_spawn_pos(bm, pos):
		return false
	if _spawn_pos_blocked(pos):
		return false
	return true

# 生产单位落点要检查一小片地面的高差，避免刷在坡面/台地边缘。
# 半径覆盖单位脚底，至少检查相邻一格；水面单位不适用。
func _spawn_flat_radius() -> float:
	return maxf(1.0, body_radius + 0.5)

func _is_flat_spawn_pos(bm: RTSBattleManager, pos: Vector3) -> bool:
	if bm == null:
		return true
	return bm._is_terrain_flat(pos, _spawn_flat_radius())

# 建筑自身的净空半径。建筑模型按 2 倍缩放，实际轮廓比配置里的 body_radius
# 大一倍多，只按 body_radius 算会让单位生成在建筑模型内部。
func _spawn_self_clearance() -> float:
	if entity_type == 1:
		return maxf(2.6, body_radius * 2.4)
	return maxf(0.8, body_radius)

# 出生点是否压到已有实体（含自己这栋建筑）：按双方体积半径算间距，
# 而不是原来写死的 1.5 米，也不会把自己排除在检查之外。
func _spawn_pos_blocked(pos: Vector3) -> bool:
	for entity in get_tree().get_nodes_in_group("entities"):
		if not is_instance_valid(entity):
			continue
		if not (entity is GameEntity) or entity.health <= 0:
			continue
		var other_r: float = float(entity.body_radius)
		if entity.entity_type == 1:
			other_r = maxf(2.6, other_r * 2.4)
		var need: float = maxf(0.8, body_radius) + other_r + 0.3
		if Vector2(pos.x - entity.global_position.x, pos.z - entity.global_position.z).length() < need:
			return true
	return false

# Find spawn position on LAND (terrain must be walkable, never mountain or water)
func _find_land_spawn_pos(margin: float = 1.2) -> Vector3:
	var bm = get_tree().get_first_node_in_group("battle_manager") as RTSBattleManager
	var attempts = 0
	var max_attempts = 30
	# 起始距离要盖过建筑自身的视觉半径 + 单位自身半径，否则单位会生成在建筑模型里
	var min_dist: float = _spawn_self_clearance() + maxf(0.8, body_radius) + 0.4
	while attempts < max_attempts:
		var angle = randf_range(0, TAU)
		var dist = randf_range(min_dist, min_dist + 2.0)
		var test_pos = _clamp_spawn_to_map(global_position + Vector3(cos(angle) * dist, 0, sin(angle) * dist), margin)
		# 地形：山和水都不能用来出生
		if bm and _is_spawn_blocked_terrain(bm.get_terrain_at(test_pos)):
			attempts += 1; continue
		# 落点周围必须是平地，避免单位卡在斜坡上
		if bm and not _is_flat_spawn_pos(bm, test_pos):
			attempts += 1; continue
		# 和已有实体（含自己这栋建筑）保持体积间距
		if _spawn_pos_blocked(test_pos):
			attempts += 1; continue
		return test_pos
	return _find_nearest_spawn_tile(global_position, false, margin)
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
		return false
	
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
	if bm.has_method("is_research_mode") and bm.is_research_mode() \
			and bm.has_method("is_unit_unlocked") and not bm.is_unit_unlocked(unit_id, owner_peer_id, team):
		return false
	if bm.has_method("is_training_unit_allowed") and not bm.is_training_unit_allowed(unit_id):
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
		
		res_dict = bm.get_team_resources(team) if bm.has_method("get_team_resources") else (bm.player_resources if team == RTSConfig.Team.BLUE else bm.enemy_resources)
		for res in scaled_cost.keys():
			if res_dict[res] < scaled_cost[res]: return false
		for res in scaled_cost.keys():
			res_dict[res] -= scaled_cost[res]
	
	production_queue.append(unit_id)
	if production_queue.size() == 1:
		production_timer = _research_prod_cooldown(float(prod_config.cooldown), int(unit_id))
	return true

func shock(duration: float):
	shock_timer = duration

func freeze(duration: float):
	freeze_timer = duration

func _find_water_spawn_near(center: Vector3, margin: float = 1.5) -> Vector3:
	var bm = get_tree().get_first_node_in_group("battle_manager") as RTSBattleManager
	if not bm:
		return _clamp_spawn_to_map(center + Vector3(0, 0, 2), margin)
	
	for radius in [3, 5, 7]:
		for _try in range(30):
			var angle = randf_range(0, TAU)
			var dist = randf_range(1, radius)
			var test_pos = _clamp_spawn_to_map(center + Vector3(cos(angle) * dist, 0, sin(angle) * dist), margin)
			var terrain = bm.get_terrain_at(test_pos)
			if terrain == 2:
				return test_pos
	return _find_nearest_spawn_tile(center, true, margin)

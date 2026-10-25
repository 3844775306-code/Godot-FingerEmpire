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
# 防御塔索敌：每帧扫描在后期几百实体时会形成稳定热点，改为错峰低频扫描。
var _target_scan_timer: float = randf_range(0.0, 0.25)

# Hell difficulty speed bonus

# 该建筑的拥有者是否为 AI：联机客户端的 peer_id 是随机大整数（实测见过 385949886），
# 不能简单用 >= 1000 判断，否则人类客户端会被当成 AI 吃 HELL 难度加成
func _owner_is_ai() -> bool:
	if owner_peer_id < 0:
		return false
	var bm = _get_bm()
	if bm and bm.is_online and bm.has_method("is_ai_peer"):
		return bool(bm.call("is_ai_peer", owner_peer_id))
	return owner_peer_id >= 1000

func start_construction(time: float, data: Dictionary):
	building_data = data
	var spd = 1.0
	if GameSettings.fast_mode: spd = 2.0
	if _owner_is_ai() and GameSettings.ai_difficulty >= GameSettings.AIDifficulty.HELL: spd *= 1.2
	max_build_time = data["max_health"] / 75.0 / spd
	build_timer = max_build_time
	max_health = 10
	health = 10
	attack = 0
	production_list = []
	# 建造期间不提供视野
	vision_range = 0
	if building_data.has("produces") and building_data["produces"] is Array:
		_sync_production_unlocks()
	BuildingConstructionVisual.begin(self)
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

	# 建造计时
	if build_timer > 0.0:
		var build_progress := clampf(1.0 - build_timer / maxf(max_build_time, 0.001), 0.0, 1.0)
		BuildingConstructionVisual.update(self, build_progress)
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
		if is_instance_valid(current_target) and current_target is Army and current_target.is_immune_to_damage():
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
	var candidates = bm.get_nearby_enemies(global_position, attack_range, team, owner_peer_id) if bm else get_tree().get_nodes_in_group("entities")
	for entity in candidates:
		if not (entity is Army) or entity.health <= 0: continue
		# 无外交管理器（非乱斗）→ 退化为纯队伍过滤；乱斗已由 get_nearby_enemies 按 owner 过滤
		if not bm:
			if entity.team == team: continue
		# Buildings don't attack animals
		if str(entity.get("_animal_type")) != "": continue
		# 船/墙保护下的单位免疫，防御塔直接忽略，避免把炮弹浪费在无敌目标上
		if entity.is_immune_to_damage(): continue
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
		var bm = _get_bm()
		if bm == null:
			attack_timer = attack_speed
			return
		var bullet = bm.acquire_bullet(self, damage_radius, team)
		bullet.team = team
		bullet.owner_peer_id = owner_peer_id
		bullet.damage = attack
		bullet.speed = 6.0
		bullet.target = target
		bullet.source = self
		bullet.damage_radius = damage_radius
		# acquire_bullet 已把弹丸挂到 BattleManager 下，这里只设置入树后的全局坐标
		# 模型乘了 ENTITY_MODEL_SCALE，出手高度也要按放大后的实际尺寸算
		bullet.global_position = global_position + Vector3(0, body_radius * RTSConfig.get_model_scale(entity_id) * 1.5, 0)
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
			# 和服务端首次生成、客户端换拐角模型保持同一套缩放：
			# wall.glb 原始高度 1.31，按 body_radius 自动缩放到约 2 米。
			# 原来换拐角后直接使用原始模型，会比直墙矮一截，墙顶单位也会悬空/陷墙。
			var target_size: float = body_radius * 2.0
			var aabb: AABB = bm._get_model_aabb(inst)
			var current_size: float = maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z))
			if current_size > 0.01:
				inst.scale = Vector3.ONE * (target_size / current_size * RTSConfig.get_model_scale(entity_id))
			add_child(inst); set_meta("_model_instance", inst)
			# 换模型后视觉尺寸可能变化，土色贴花跟着重算
			_refresh_ground_patch_size()
			BuildingConstructionVisual.rebind(self)
			var tint: Color = bm.get_entity_color(self) if bm.has_method("get_entity_color") else (Color(0.3, 0.6, 1.0) if team == RTSConfig.Team.BLUE else Color(1.0, 0.4, 0.4))
			bm._apply_team_tint(self, tint)

func _finish_construction():
	BuildingConstructionVisual.finish(self)
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
			_sync_production_unlocks()
	
	
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
		bm._show_hud_alert("建造完成: %s%s %s" % [display_name, group_str, loc_str], Color(0.2, 1.0, 0.3), [team], team, GameSettings.AlertKind.BUILD)
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
	_spawn_ground_patch()
	call_deferred("_apply_nation_start_bonus")

# ==================== 建筑脚下的土色地面 ====================
# 建筑压住的那块地面泛出土色，范围比实际占地略大一圈，
# 让建筑看起来是「坐」在土地上而不是浮在草皮上。
# 建筑被摧毁后土色在几秒内慢慢褪去，留下一点被翻动过的痕迹再消失。
#
# 不用 Decal：本项目的地形网格上 Decal 投射不稳定，实测看不见。
# 改用和脚印（GroundTrailManager）同一套做法——一张柔边贴图贴在贴地薄片上，
# 这套渲染路径是确认可见的。
const GROUND_PATCH_MARGIN: float = 1.6      # 比占地外扩多少米
const GROUND_PATCH_FADE_TIME: float = 3.5   # 摧毁后淡出耗时（秒）
const GROUND_PATCH_COLOR: Color = Color(0.42, 0.31, 0.19, 1.0)
const GROUND_PATCH_ALPHA: float = 0.85      # 正常状态的最高不透明度
const GROUND_PATCH_LIFT: float = 0.06       # 贴地薄片抬高，避免与地面 z-fighting

static var _ground_patch_tex: ImageTexture = null
static var _ground_patch_shader: Shader = null

var _ground_patch: MeshInstance3D = null
var _ground_patch_mat: ShaderMaterial = null

# 程序生成一张柔边方形贴图：中间实、四边渐隐，
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

static func _ground_patch_material_shader() -> Shader:
	if _ground_patch_shader != null:
		return _ground_patch_shader
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled;

uniform sampler2D patch_texture : source_color, filter_linear;
uniform vec3 tint : source_color = vec3(0.42, 0.31, 0.19);
uniform float base_alpha = 0.85;

void fragment() {
	vec4 tex = texture(patch_texture, UV);
	ALBEDO = tint;
	ALPHA = base_alpha * tex.a;
}
"""
	_ground_patch_shader = sh
	return _ground_patch_shader

func _spawn_ground_patch() -> void:
	if _ground_patch != null and is_instance_valid(_ground_patch):
		return
	# 城墙/炮台/桥/梯子这类贴在城墙或水面上的构件不铺土色：
	# 它们本来就没压在地面上，铺一层土反倒像浮在空中
	if entity_id in RTSConfig.BUILDING_BODY_SCALE_EXCLUDED:
		return
	var half: float = _ground_patch_half_size()
	var quad := PlaneMesh.new()
	quad.size = Vector2(half * 2.0, half * 2.0)
	var mat := ShaderMaterial.new()
	mat.shader = _ground_patch_material_shader()
	mat.set_shader_parameter("patch_texture", _ground_patch_texture())
	mat.set_shader_parameter("tint", Vector3(GROUND_PATCH_COLOR.r, GROUND_PATCH_COLOR.g, GROUND_PATCH_COLOR.b))
	mat.set_shader_parameter("base_alpha", GROUND_PATCH_ALPHA)
	quad.material = mat

	var mi := MeshInstance3D.new()
	mi.name = "GroundPatch"
	mi.mesh = quad
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = Vector3(0.0, GROUND_PATCH_LIFT, 0.0)
	add_child(mi)
	_ground_patch = mi
	_ground_patch_mat = mat

# 土色半宽：body_radius 只是碰撞半径，模型还会再乘 ENTITY_MODEL_SCALE
# （巨型投石机、主城这类特殊体型）。用模型真实缩放后的水平尺寸算，
# 大建筑的地面痕迹才会跟着一起变大，不会出现小土圈套大房子。
func _ground_patch_half_size() -> float:
	var visual_radius: float = body_radius * RTSConfig.get_model_scale(entity_id)
	return visual_radius + GROUND_PATCH_MARGIN

# 模型被替换（城墙换拐角、升级换外观）后重算土色尺寸
func _refresh_ground_patch_size() -> void:
	if _ground_patch == null or not is_instance_valid(_ground_patch):
		return
	var half: float = _ground_patch_half_size()
	var quad := _ground_patch.mesh as PlaneMesh
	if quad != null:
		quad.size = Vector2(half * 2.0, half * 2.0)

# 建筑死亡时调用：土色薄片脱离建筑挂在场景里继续淡出，
# 直接挂在建筑上会跟着一起被 queue_free，看不到褪色过程。
func _fade_ground_patch() -> void:
	if _ground_patch == null or not is_instance_valid(_ground_patch):
		_ground_patch = null
		_ground_patch_mat = null
		return
	var mi := _ground_patch
	var mat := _ground_patch_mat
	_ground_patch = null
	_ground_patch_mat = null
	var parent := get_parent()
	if parent != null:
		mi.reparent(parent, true)
	if mat == null:
		mi.queue_free()
		return
	var tw := mi.create_tween()
	tw.tween_method(func(v: float): mat.set_shader_parameter("base_alpha", v), GROUND_PATCH_ALPHA, 0.0, GROUND_PATCH_FADE_TIME)
	tw.tween_callback(Callable(mi, "queue_free"))
	
	
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
		# 环径与高度都按模型放大后的尺寸算，否则大建筑的选择环会陷在模型里
		var visual_r: float = body_radius * RTSConfig.get_model_scale(entity_id)
		var ring = MeshInstance3D.new()
		ring.name = "SelectionRing"
		var torus = TorusMesh.new()
		torus.inner_radius = visual_r + 0.2
		torus.outer_radius = visual_r + 0.35
		ring.mesh = torus

		# 水平圆环 + 贴地面
		ring.position.y = visual_r * 1.5 + 0.1
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
	var full: Array = building_data.get("produces", [])
	if full.is_empty():
		return
	for i in range(full.size()):
		var prod: Dictionary = full[i]
		var unlock_lv: int = int(prod.get("unlock_level", i + 1))
		if unlock_lv > upgrade_level:
			continue
		var uid: int = int(prod.get("unit_id", -1))
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

	# 升级完成警报（仅人类玩家自己，含位置和编队）
	if bm and bm.has_method("_show_hud_alert") and bm.is_human_owned(owner_peer_id, team):
		var group_str = ""
		var sm = bm.get_node_or_null("SelectionManager")
		if sm and sm.has_method("get_entity_groups"):
			var groups = sm.get_entity_groups(self)
			if groups.size() > 0:
				group_str = " [T%d]" % groups[0]
		var loc_str = "(%d,%d)" % [int(global_position.x), int(global_position.z)]
		# 主城（entity_id 20）升级是重要节点，标记出来让它不受队友筛选影响
		bm._show_hud_alert("升级完成: %s%s %s" % [display_name, group_str, loc_str], Color(0.2, 1.0, 0.3), [team], team, GameSettings.AlertKind.UPGRADE, entity_id == 20)

func get_prod_cooldown(unit_id: int) -> float:
	var spd3 = 1.0
	if GameSettings.fast_mode: spd3 = 2.0
	if _owner_is_ai() and GameSettings.ai_difficulty >= GameSettings.AIDifficulty.HELL: spd3 *= 1.2
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
	# 脚下的土色脱离建筑独立淡出，不会跟着模型一起瞬间消失
	_fade_ground_patch()
	super.die()

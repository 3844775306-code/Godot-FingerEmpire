class_name Army
extends GameEntity

enum UnitState { IDLE, MOVING, ATTACKING, GATHERING, DELIVERING, ATTACK_MOVING }
const _STATE_NAMES = {UnitState.IDLE: "", UnitState.MOVING: "move", UnitState.ATTACKING: "attack", UnitState.GATHERING: "gather", UnitState.DELIVERING: "deliver", UnitState.ATTACK_MOVING: "attack_move"}

# ÒÆ¶¯ÊôÐÔ
var original_speed: float = 0.0
var loop_index:int = 0
# Cached terrain/speed lookups — avoid per-frame grid queries when stationary
var _cached_bm = null
var _last_grid_pos: Vector2i = Vector2i(-999, -999)
var _cached_terrain: int = 0
var _cached_speed_mod: float = 1.0
# 落水伤害：陆地单位在深水、且未上桥/运载船时，每秒损失 20% 最大生命
const WATER_DAMAGE_INTERVAL: float = 1.0
const WATER_DAMAGE_RATIO: float = 0.2
var _water_damage_timer: float = WATER_DAMAGE_INTERVAL
# ²É¼¯½»¸¶
var cargo: Dictionary = {"gold": 0, "wood": 0, "stone": 0, "food": 0, "oil": 0}
var max_cargo: int = 50
var gatherable_resources: Array = []             
# 自动搜索资源点的半径（默认与视野一致，农民在 setup 里取视野的一半）
var gather_search_range: float = 0.0
var delivery_target: Building = null
var last_resource_target: WorldResource = null   
# 采集时朝资源点移动的累计时长：走不到就放弃重找，避免永久假采集
var _gather_approach_time: float = 0.0
# 交付时朝仓库/主城移动的累计时长与失败次数：走不到就重算路径、换交付点
var _deliver_approach_time: float = 0.0
var _deliver_retry_count: int = 0
# 交付时"距离是否在缩短"的检测（卡住时强制重算 A* 路径）
var _deliver_check_timer: float = 0.0
var _deliver_last_dist: float = -1.0

# ¹¥»÷ÒÆ¶¯
var is_attack_moving: bool = false
var attack_move_target: Vector3 = Vector3.ZERO
# 攻击目标寻路持续失败（目标在墙后/河对岸/山崖上）时，不要一直原地播放走路，
# 改为尝试攻击最近的敌方建筑（拆墙）或放弃该目标。
const ATTACK_APPROACH_STUCK_TIME: float = 1.2
const UNREACHABLE_TARGET_MEMORY_MS: int = 5000
const TARGET_VALIDATE_INTERVAL: float = 0.5
var _attack_stall_time: float = 0.0
var _attack_watch_target_id: int = -1
var _target_validate_timer: float = 0.0
var _unreachable_targets: Dictionary = {}  # instance_id -> expire msec

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
var _garrison_marker: Node3D = null  # 驻扎点标记
const NON_MILITARY_IDS = [10, 14, 43, 44, 45, 51, 46, 47, 48, 49, 50]

func _is_military() -> bool:
	return entity_id not in NON_MILITARY_IDS

# 动物系统
var _animal_type: String = ""         # cow/pig/sheep/fish
var _animal_retaliating: bool = false
var _animal_reproduce_timer: float = 45.0

var _animal_grow_timer: float = 0.0
var _animal_food_reward: int = 0

# Cart vars
enum CartState { IDLE, CHASING, FOLLOWING }
var _cart_state: int = CartState.IDLE
var _cart_owner: WeakRef = null
var _cart_search_timer: float = 0.0
const CART_FOLLOW_DIST: float = 1.5     # 后方跟随距离
const CART_CHASE_SPEED_MULT: float = 2.0 # 追赶速度倍数

# 爆破船/运载船 vars
var _has_exploded: bool = false
var _death_cleanup_done: bool = false
var _boarded_units: Array = []       # 运载船上的单位
var _boarded_on: int = -1            # 登上的运载船instance_id

# Official vars
var _garrison_target_id: int = -1
var _garrison_building: WeakRef = null

# 士兵/农民进驻
var _soldier_garrison_building: WeakRef = null   # 进驻的建筑或攻城车
var _ram_garrisoned_soldiers: Array = []          # 攻城车存储的进驻兵（仅 entity_id==18）
var _salary_timer: float = 0.0
var _official_active: bool = true
var _visual_waypoints: Array = []      # Persisted waypoint positions for snapshot
var _current_move_queued: bool = false # Current move originated from queue

# ¾ö²ß½ÚÁ÷
var think_timer: float = 0.0
const THINK_INTERVAL: float = 0.3

# 目标重选：锁定目标不在攻击范围时，每秒找一次更近的敌人
const TARGET_RETARGET_INTERVAL: float = 1.0
var _retarget_timer: float = TARGET_RETARGET_INTERVAL
var _retarget_target_id: int = -1
# 攻击移动时不必每帧全量搜敌；0.4s 一次足够跟随战场变化
const ATTACK_MOVE_SEARCH_INTERVAL: float = 0.4
var _attack_move_search_timer: float = 0.0

# 驻扎防御：驻扎点附近这个半径内的敌人优先清掉，再返回驻扎点
const GARRISON_DEFEND_RADIUS: float = 10.0
# 采集时向资源点移动的最长容忍时间，超时放弃该目标并重找
const GATHER_APPROACH_TIMEOUT: float = 8.0
# 交付时向仓库移动的最长容忍时间，超时先重算路径，再次超时就换交付点
const DELIVER_APPROACH_TIMEOUT: float = 10.0
# 交付判定在建筑碰撞边缘外额外放宽的距离（农民会被碰撞体挡住，不能要求贴到 0.8 米内）
const DELIVER_CONTACT_SLACK: float = 1.2
# 采集船自动搜索油井的半径：石油现在通常位于水域中央，离岸较远，
# 需要比普通农民更大的搜索半径，否则船停在岸边找不到中心油井。
const BOAT_GATHER_SEARCH_RANGE: float = 32.0

# Åö×²·ÖÀë½ÚÁ÷

# A* Ñ°Â·
var _movement: MovementController = null

# 选择环按半径共享 Mesh/材质：后期几十上百个单位同时被框选时，
# 每个单位各建一份 TorusMesh + StandardMaterial3D 会造成大量重复资源与状态切换。
static var _selection_ring_meshes: Dictionary = {}
static var _selection_ring_material: StandardMaterial3D = null

# 动画 LOD：相机远处/屏幕外单位由战斗管理器停掉 AnimationPlayer，
# 避免几百个角色每帧更新骨骼动画；重新进入视野时恢复。
var _anim_player: AnimationPlayer = null
var _anim_lod_off: bool = false
# (moved to MovementController)
# (moved to MovementController)
# (moved to MovementController)

# ÐÂÔö£ºÈ±Ê§µÄ±äÁ¿£¨ÐÞ¸´±¨´í£©
  # Ô­µØ¹ÌÊØ
		# 0=Å©Ãñ / 1=Õ½¶·µ¥Î»

   # Â·¾¶ÖØËã¼ä¸ô
 # Ô­µØ·ÀÊØÄ£Ê½

# ÔÚ _process »ò _find_enemy_in_range Ïà¹ØµÄ×Ô¶¯×·»÷´úÂëÖÐ

func setup(config: Dictionary):
	super.setup(config)
	_add_weapon()  # now entity_id is set
	original_speed = speed
	gatherable_resources = config.get("gatherable_resources", [])
	max_cargo = config.get("max_cargo", 50)

	var lv = config.get("level", 1)
	level = lv
	var scale = 1.0 + (lv - 1) * 0.3
	max_health = int(max_health * scale)
	health = max_health
	attack = int(attack * scale)
	if melee_armor > 0: melee_armor = (melee_armor * scale)
	if shield_armor > 0: shield_armor = (shield_armor * scale)

	# ÉèÖÃÀàÐÍ£ºÅ©Ãñ=0£¬Õ½¶·µ¥Î»=1
	if entity_id in [10, 14]:
		target_type = 0
	else:
		target_type = 1
	# 农民自动找资源点的半径：取视野的一半，采集距离更短、更贴近身边
	gather_search_range = vision_range * 0.5
	if entity_id == 14:
		gather_search_range = maxf(gather_search_range, BOAT_GATHER_SEARCH_RANGE)
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
	if mults.has("melee_armor"):
		melee_armor += int(mults["melee_armor"])
	if mults.has("shield_armor"):
		shield_armor += int(mults["shield_armor"])
	if mults.has("speed"):
		speed *= mults["speed"]
		original_speed = speed
	if mults.has("attack_speed"):
		attack_speed *= mults["attack_speed"]
	if mults.has("attack_range"):
		attack_range *= mults["attack_range"]
	if mults.has("vision_range"):
		vision_range *= int(mults["vision_range"])
		# 国家加成改视野后，采集搜索半径同步取新视野的一半
		gather_search_range = vision_range * 0.5
		if entity_id == 14:
			gather_search_range = maxf(gather_search_range, BOAT_GATHER_SEARCH_RANGE)
	  # ²»Ö÷¶¯×·»÷£¬Ö»¹¥»÷½øÈëÉä³ÌµÄµÐÈË
	# Ô­ÓÐ×·»÷Âß¼­...
func _ready():
	super._ready()
	_movement = MovementController.new(self)
	entity_type = 2
	can_move = true
	_create_visual()
	_add_selection_ring()
	_add_collision_shape()

# 走路扬尘：陆军（含牲畜）在地面前进时脚下冒起尘土，停下来就消失。
# 用挂载式粒子而不是每次生成节点，避免几百个单位走位时反复创建销毁。
var _walk_dust: CPUParticles3D = null
var _walk_dust_last_pos: Vector3 = Vector3.ZERO

func _setup_walk_dust() -> void:
	if _walk_dust != null:
		return
	var p := CPUParticles3D.new()
	# 扬尘只能贴着地面形成薄薄一层：颗粒小、初速低、几乎不上飘，
	# 否则会糊住单位本身，把整个模型染成土黄色。
	p.amount = 10
	p.lifetime = 0.8
	p.emitting = false
	p.local_coords = false
	p.direction = Vector3.UP
	p.spread = 80.0
	p.initial_velocity_min = 0.12
	p.initial_velocity_max = 0.5
	p.gravity = Vector3(0.0, 0.12, 0.0)
	p.scale_amount_min = 1.0
	p.scale_amount_max = 1.6
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 0.55
	var mesh := SphereMesh.new()
	mesh.radius = 0.10
	mesh.height = 0.20
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# 透明度压到很低：只是地面上一层淡尘，不能盖住单位
	mat.albedo_color = Color(0.80, 0.77, 0.70, 0.34)
	mesh.material = mat
	p.mesh = mesh
	var grad := Gradient.new()
	grad.set_color(0, Color(1.0, 1.0, 1.0, 0.34))
	grad.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
	p.color_ramp = grad
	p.position = Vector3(0.0, 0.05, 0.0)
	# 显式给足包围盒，否则粒子飞出默认范围会被视锥剔除，看起来就像"完全没发射"
	p.visibility_aabb = AABB(Vector3(-3.0, -3.0, -3.0), Vector3(6.0, 6.0, 6.0))
	add_child(p)
	_walk_dust = p

# ── 脚印 / 车辙 ──
# 粒子一闪就消失，远不如留在地面上的痕迹有存在感。
# 每个单位循环使用 10 个贴地面片，挂在场景根下（不能挂在单位下，否则会跟着人走）。
var _prints: Array[MeshInstance3D] = []
var _print_idx: int = 0
var _print_timer: float = 0.0

func _setup_prints() -> void:
	if not _prints.is_empty():
		return
	var root := get_tree().current_scene as Node3D
	if root == null:
		# 场景还没就绪时先放弃，下一次移动会再次尝试
		return
	# 车轮留下的是一整条宽车辙，步兵是窄脚印
	var vehicle: bool = entity_id in [5, 6, 16, 17, 18, 59]
	var pmat := StandardMaterial3D.new()
	pmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	pmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	pmat.cull_mode = BaseMaterial3D.CULL_DISABLED
	# 比之前更暗更实：太淡的深色贴花在草地上几乎看不见
	pmat.albedo_color = Color(0.18, 0.16, 0.12, 0.62) if vehicle else Color(0.22, 0.19, 0.14, 0.52)
	for i in 14:
		var mi := MeshInstance3D.new()
		mi.name = "GroundPrint"
		var quad := PlaneMesh.new()
		# PlaneMesh 默认平躺在 XZ 平面，正好贴地
		quad.size = Vector2(0.85, 1.50) if vehicle else Vector2(0.36, 0.55)
		quad.material = pmat
		mi.mesh = quad
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		root.add_child(mi)
		_prints.append(mi)

func _update_prints(delta: float, move_dir: Vector3) -> void:
	if _prints.is_empty():
		_setup_prints()
		if _prints.is_empty():
			return
	# 每 0.2 米左右留一个脚印，按移动距离而不是时间，速度快也不会变成虚线
	_print_timer -= delta
	if _print_timer > 0.0:
		return
	_print_timer = 0.22
	var mi: MeshInstance3D = _prints[_print_idx]
	if not is_instance_valid(mi):
		return
	_print_idx = (_print_idx + 1) % _prints.size()
	# 抬到地面上方 4 厘米，避免与地形共面产生 z-fighting 而闪烁不可见
	mi.global_position = Vector3(global_position.x, global_position.y + 0.04, global_position.z)
	if move_dir.length_squared() > 0.0001:
		mi.rotation.y = atan2(move_dir.x, move_dir.z)
	mi.visible = true

func _exit_tree() -> void:
	# 单位被销毁时把它留在场景根下的脚印一起清掉
	for mi in _prints:
		if is_instance_valid(mi):
			mi.queue_free()
	_prints.clear()

func _update_walk_dust(delta: float) -> void:
	# 船只在水中前进不该有扬尘；鱼也排除
	if entity_id in [9, 13, 14, 39, 40]:
		return
	if _animal_type == "fish":
		return
	# 用实际位置变化来判断是否在走：单位移动是直接写 global_position 的，
	# velocity 常常是零，is_on_floor() 也永远是 false，拿它们判断会一直不发射。
	var delta_pos := Vector3.ZERO
	var moved: float = 0.0
	if _walk_dust_last_pos != Vector3.ZERO:
		delta_pos = global_position - _walk_dust_last_pos
		moved = Vector2(delta_pos.x, delta_pos.z).length()
	_walk_dust_last_pos = global_position
	var moving: bool = moved > 0.012
	if not moving:
		if _walk_dust != null:
			_walk_dust.emitting = false
		return
	# 懒创建：只有真正走起来才建粒子节点，待命单位不占开销
	if _walk_dust == null:
		_setup_walk_dust()
	if _walk_dust != null:
		_walk_dust.emitting = true
	_update_prints(delta, delta_pos)

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
		# Weapons added after setup() in spawn_entity

func _add_selection_ring():
	if not has_node("SelectionRing"):
		var ring = MeshInstance3D.new()
		ring.name = "SelectionRing"
		# 相同体型共用同一份环 Mesh；材质也全局共用，框选几百个单位时只增加实例，
		# 不再为每个单位分配一份网格/材质资源。
		var ring_key: String = "%.2f" % body_radius
		var ring_mesh: TorusMesh = _selection_ring_meshes.get(ring_key)
		if ring_mesh == null:
			ring_mesh = TorusMesh.new()
			ring_mesh.inner_radius = body_radius + 0.1
			ring_mesh.outer_radius = body_radius + 0.15
			_selection_ring_meshes[ring_key] = ring_mesh
		ring.mesh = ring_mesh
		ring.position = Vector3(0, body_radius * 2.5 + 0.1, 0)
		if _selection_ring_material == null:
			_selection_ring_material = StandardMaterial3D.new()
			_selection_ring_material.albedo_color = Color.GREEN
			_selection_ring_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		ring.material_override = _selection_ring_material
		# 选择环只是操作提示，不参与阴影/GI；框选几百个单位时避免额外 shadow pass。
		ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		ring.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		ring.visible = false
		add_child(ring)

# 模型替换后重新绑定 AnimationPlayer；新模型默认播放，LOD 状态复位。
func bind_animation_player(ap: AnimationPlayer) -> void:
	_anim_player = ap
	_anim_lod_off = false
	if ap != null and is_instance_valid(ap):
		ap.active = true

# 远景/屏幕外动画 LOD：只停/恢复 AnimationPlayer 的推进，不销毁动画或模型。
func set_animation_lod(disable: bool) -> void:
	if _anim_player == null or not is_instance_valid(_anim_player):
		return
	if _anim_lod_off == disable:
		return
	_anim_lod_off = disable
	_anim_player.active = not disable

func _add_weapon():
	var wpath = ""
	# Bow: archers only
	if entity_id in [12, 31, 37]: wpath = "res://models/forest/weapon-bow.glb"
	# Spear
	elif entity_id == 35: wpath = "res://models/arena/weapon-spear.glb"
	# Sword: all infantry + cavalry + specials
	elif entity_id in [11, 15, 19, 30, 32, 34, 36, 38, 65, 66]:
		wpath = "res://models/arena/weapon-sword.glb"
	if wpath != "" and ResourceLoader.exists(wpath):
		var ws = load(wpath)
		if ws:
			var w = ws.instantiate()
			if w:
				w.position = Vector3(body_radius * 1.2, body_radius * 0.4, 0)
				w.scale = Vector3.ONE 
				if entity_id in [12, 31, 37]: w.rotation_degrees = Vector3(0, 180, 0)
				add_child(w)
	if entity_id in [36, 37, 38] and ResourceLoader.exists("res://models/arena/shield-round.glb"):
		var sh = load("res://models/arena/shield-round.glb")
		if sh: var s = sh.instantiate(); if s: s.position = Vector3(-0.3, body_radius * 0.6, 0); s.scale = Vector3.ONE * 0.8; add_child(s)
	var mpath = ""
	if entity_id in [15, 19, 38, 66]: mpath = "res://models/pets/animal-dog.glb"

	elif entity_id == 34: mpath = "res://models/pets/animal-elephant.glb"
	if mpath != "" and ResourceLoader.exists(mpath):
		var ms = load(mpath)
		if ms: var m = ms.instantiate(); if m: m.position = Vector3(0, -body_radius * 1.2, 0); m.scale = Vector3.ONE * 0.7; add_child(m)
		body_radius *= 1.2  # make cavalry visibly larger

func _add_collision_shape():
	if not has_node("CollisionShape3D"):
		var col = CollisionShape3D.new()
		var shape = SphereShape3D.new()
		shape.radius = body_radius * 0.6 
		col.shape = shape
		col.name = "CollisionShape3D"
		add_child(col)

# ----------------- Ö÷Ñ­»· -----------------

func set_selected(selected: bool):
	super.set_selected(selected)
	if _movement: _movement.set_selected(selected)
func _set_order(state: UnitState):
	var new_order: String = _STATE_NAMES.get(state, "")
	if current_order == new_order:
		return
	current_order = new_order
	# 主机端也即时切换动画，避免只靠每 30 帧轮询导致走/停/攻击动作延迟半秒
	if not is_inside_tree():
		return
	var bm = _get_bm()
	if bm and bm.has_method("_update_entity_animation"):
		bm._update_entity_animation(self)
func _order_is(state: UnitState) -> bool:
	return current_order == _STATE_NAMES.get(state, "___")
func _order_in(states: Array) -> bool:
	for s in states:
		if _order_is(s): return true
	return false

# 目标是否已经失效：节点被释放或血量归零（死亡动画期间节点仍可能存在）。
func _is_target_gone(target) -> bool:
	if target == null:
		return true
	if not is_instance_valid(target):
		return true
	if target is Node and target.is_queued_for_deletion():
		return true
	if target is GameEntity and target.health <= 0:
		return true
	return false

# 立即刷新动画，避免目标阵亡后仍停留在攻击动作。
func _refresh_animation_now() -> void:
	if not is_inside_tree():
		return
	var bm = _get_bm()
	if bm and bm.has_method("_update_entity_animation"):
		bm._update_entity_animation(self)

# 清除已阵亡目标：普通攻击/采集回到待机，攻击移动则保留状态继续前进。
func _clear_dead_target() -> bool:
	if current_target == null or not _is_target_gone(current_target):
		return false
	var was_attack_moving: bool = is_attack_moving
	current_target = null
	_attack_move_search_timer = 0.0
	if not was_attack_moving:
		_set_order(UnitState.IDLE)
		# 清掉朝尸体/已消失资源点计算的路径，避免继续滑过去
		if _movement:
			_movement.stop()
	_refresh_animation_now()
	return true

# 陆地单位在深水且不在桥/运载船上时，每秒损失 20% 最大生命。
# 浅滩（overlay=3）是给陆军涉水通过的，不算落水。
func _is_deep_water_position(bm) -> bool:
	if bm == null:
		return false
	if bm.get_terrain_at(global_position) != 2:
		return false
	var gpos: Vector2i = bm.world_to_grid(global_position)
	if bm.get_overlay_at_grid(gpos.x, gpos.y) == 3:
		return false
	if bm.is_bridge_at(global_position):
		return false
	return true

# 陆地动物（牛/猪/羊）掉进深水也要按落水处理；鱼本身是 water_capable，不算陆地动物。
func _is_land_animal() -> bool:
	return _animal_type != "" and _animal_type != "fish"

func _tick_water_damage(delta: float) -> void:
	if _boarded_on != -1:
		_water_damage_timer = WATER_DAMAGE_INTERVAL
		return
	# 陆地动物即使配置误标成 water_capable，也强制按落水受伤，保证动物不会在水里安然无恙。
	if water_capable and not _is_land_animal():
		_water_damage_timer = WATER_DAMAGE_INTERVAL
		return
	_water_damage_timer -= delta
	if _water_damage_timer > 0.0:
		return
	_water_damage_timer = WATER_DAMAGE_INTERVAL
	var bm = _get_bm()
	if not _is_deep_water_position(bm):
		return
	health = maxf(health - max_health * WATER_DAMAGE_RATIO, 0.0)
	if health <= 0.0:
		die()

# 船只被击沉、陆地单位落水时使用沉水动画，而不是毁坏模型/原地消失。
func _should_sink_death() -> bool:
	if _boarded_on != -1:
		return false
	var bm = _get_bm()
	if not _is_deep_water_position(bm):
		return false
	if not water_capable or _is_land_animal():
		return true
	return entity_id in [9, 13, 14, 39, 40]

func _physics_process(delta):
	if health <= 0:
		die_official_cleanup()
		return

	# 进驻中的士兵跳过所有行为
	if _soldier_garrison_building and _soldier_garrison_building.get_ref() and is_instance_valid(_soldier_garrison_building.get_ref()):
		return

	# 城墙上的单位即使已停止移动，也要把高度平滑到墙顶；墙被毁后落回地面。
	# 只有墙上的单位/AI 守墙单位才需要走这段，避免全军每帧取地图高度。
	if has_meta("ai_wall_guard") or _is_unit_on_wall():
		_update_wall_height(delta)

	# 陆地单位落水持续伤害（上桥、进运载船、浅滩涉水不受伤）
	_tick_water_damage(delta)
	if health <= 0:
		return

	# 走动时脚下扬尘、地面留脚印/车辙，停下自动消失（内部已排除船只与鱼）
	_update_walk_dust(delta)

	# 爆破船/运载船/手推车/贸易车 特殊行为
	if entity_id == 40:
		_process_demolition(delta)
		return
	if entity_id == 9:
		_process_transport(delta)
		return
	if entity_id in [5, 6]:
		_process_cart(delta)
		return
	# 登船单位：位置跟随运载船
	if _boarded_on != -1:
		var transport = instance_from_id(_boarded_on)
		if is_instance_valid(transport):
			global_position = transport.global_position
		return

	# 动物行为（每5帧处理一次）
	if _animal_type != "":
		if Engine.get_process_frames() % 5 == 0:
			_process_animal(delta * 5.0)
		return

	# Merchant/official special logic
	if entity_id in [43, 44, 45, 51]:
		_process_merchant(delta)
		return
	

	# ËÙ¶ÈÓëµØÐÎ
	
	# Cache bm reference (avoid per-frame scene-tree search)
	if not _cached_bm:
		_cached_bm = get_tree().get_first_node_in_group("battle_manager")
	var bm = _cached_bm
	var base_speed = original_speed
	if shock_timer > 0: speed = 0
	elif freeze_timer > 0: speed = max(base_speed * 0.5, 0.1)
	else: speed = base_speed

	# 完全空闲且没有队列/路径的单位只需要按决策节流跑 _think；
	# 后期大量待命部队如果仍然每帧走 _process_action + process_move + 碰撞，
	# 会在 300~500 单位时占掉大部分主线程时间。
	var simple_idle: bool = (
		(_order_is(UnitState.IDLE) or current_order == "") and current_target == null
		and not is_attack_moving and command_queue.is_empty()
		and _movement.astar_target == Vector3.ZERO and _movement.astar_path.is_empty()
		and velocity.length_squared() <= 0.04
	)
	if simple_idle:
		# 完全空闲单位也不能永远不做分离，否则停下来的部队会互相穿模。
		# 用 0.8s 的低频查询，成本远低于每帧碰撞，但能慢慢把重叠推开。
		_movement.collision_timer -= delta
		if _movement.collision_timer <= 0.0:
			_movement.collision_timer = 0.8
			_movement.apply_collision(delta)
		_tick_think(delta, bm)
		return

	if bm:
		# Only recompute terrain/speed-mod when grid position changes
		var gpos = bm.world_to_grid(global_position)
		if gpos != _last_grid_pos:
			_last_grid_pos = gpos
			_cached_terrain = bm.get_terrain_at(global_position)
			var all_water = true
			var all_land = true
			for dx in [-1, 0, 1]:
				for dy in [-1, 0, 1]:
					if dx == 0 and dy == 0: continue
					var t = bm.get_terrain_at_grid(gpos.x + dx, gpos.y + dy)
					var ov = bm.get_overlay_at_grid(gpos.x + dx, gpos.y + dy)
					if t != 2 or ov == 3: all_water = false
					if t == 2 and ov != 3: all_land = false
			var here_overlay: int = bm.get_overlay_at_grid(gpos.x, gpos.y)
			if not water_capable and all_water:
				_cached_speed_mod = 0.01
			elif water_capable and all_land:
				_cached_speed_mod = 0.01
			elif not water_capable and here_overlay == 3:
				_cached_speed_mod = float(bm.map_modifiers.get("ford_speed", 0.55))
			elif not water_capable and here_overlay == 2:
				_cached_speed_mod = float(bm.map_modifiers.get("marsh_speed", 0.6))
			elif not water_capable and here_overlay == 1:
				_cached_speed_mod = 0.9
			elif _cached_terrain == 1:
				_cached_speed_mod = 0.5
			else:
				_cached_speed_mod = 1.0
			speed = base_speed * _cached_speed_mod
			# Movement sounds (every 20 frames, when position changed)
			if Engine.get_process_frames() % 10 == 0 and health > 0:
					if _cached_terrain == 2:
						_play_sfx_if_visible("sail")
					else:
						_play_sfx_if_visible("walk")
					# 移动音效触发时立即同步行走动画
					if bm.has_method("_update_entity_animation"):
						bm._update_entity_animation(self)
			# Water transition sounds (every 30 frames)
			if Engine.get_process_frames() % 30 == 0:
				var _in_water = (_cached_terrain == 2)
				var _was_in_water = has_meta("_was_in_water") and get_meta("_was_in_water")
				if _in_water != _was_in_water and not water_capable:
					_play_sfx_if_visible("swim")
					# 涉水音效触发时立即同步行走动画
					if bm.has_method("_update_entity_animation"):
						bm._update_entity_animation(self)
				set_meta("_was_in_water", _in_water)

	if entity_id >= 46 and entity_id <= 50:
		_process_official(delta)
		# 官员如果正在前往驻军建筑，继续走移动逻辑
		if _garrison_target_id != -1 and _order_is(UnitState.MOVING):
			_process_action(delta, bm)
			_set_order(UnitState.MOVING)
			_movement.process_move(delta, bm)
			if _movement.collision_timer <= 0:
				_movement.collision_timer = 0.15
				_movement.apply_collision(delta)
			else:
				_movement.collision_timer -= delta
		return

	# 目标有效性检查：阵亡目标也要立即清空，不能等节点真正释放；
	# 否则单位会继续朝尸体移动或保持攻击动作。
	if _clear_dead_target():
		# 攻击移动保留 is_attack_moving，由 _process_action 继续朝原目的地推进并搜索新敌人。
		if not is_attack_moving:
			if _is_healer():       # 僧侣：目标没了就重新找伤兵
				_find_wounded_ally()
			elif target_type == 0:   # 农民类，寻找新资源
				_find_nearest_resource()
			else:                  # 战斗单位，立即搜索敌人
				_find_enemy_in_range()
	if _order_in([UnitState.ATTACKING, UnitState.GATHERING]) :
		if current_target == null:
			_set_order(UnitState.IDLE)
			is_attack_moving = false
			if _is_healer():       # 僧侣：治疗目标消失后继续找伤兵
				_find_wounded_ally()
			elif target_type == 0:   # Å©ÃñÀà£¬Ñ°ÕÒÐÂ×ÊÔ´
				_find_nearest_resource()
			else:                  # Õ½¶·µ¥Î»£¬Á¢¿ÌËÑË÷µÐÈË
				_find_enemy_in_range()
	# ÐÐÎª´¦Àí
	_process_action(delta, bm)

	# ÒÆ¶¯£¨ÊÖ¶¯ÉèÖÃ global_position£©
	# 已经在攻击射程内站定的单位不必每帧再跑 process_move：后者会重复算一次
	# 目标距离、清速度并做边界/地形检查；几百个单位混战时这是稳定的每帧开销。
	var _stationary_in_range := false
	if not is_attack_moving and current_target != null and is_instance_valid(current_target) and current_target is GameEntity:
		var _sd := Vector2(global_position.x - current_target.global_position.x,
							global_position.z - current_target.global_position.z)
		_stationary_in_range = (_sd.length() - body_radius - current_target.body_radius) <= attack_range
	if _stationary_in_range:
		_movement.cancel_pending_path()
		_movement.astar_path.clear()
		_movement.astar_target = Vector3.ZERO
		_movement.attack_path_failed = false
		_movement.move_path_failed = false
		_movement.blocking_building = null
		_attack_stall_time = 0.0
		_movement._hide_path()
		var _had_velocity: bool = velocity.length_squared() > 0.04
		velocity = Vector3.ZERO
		if _had_velocity:
			_refresh_animation_now()
	else:
		_movement.process_move(delta, bm)

	# 碰撞分离：移动单位保持较高频率；站桩/驻守单位也不能完全跳过，
	# 否则远程单位挤在射程边缘会叠在一起。站桩时降到约 0.35s 一次，
	# 既避免每帧近邻查询，又能把重叠慢慢推开。
	var moving_collision: bool = (
		is_attack_moving
		or _movement.astar_target != Vector3.ZERO or _movement.astar_path.size() > 0
		or velocity.length_squared() > 0.04
	)
	if moving_collision and _movement.collision_timer > _movement.COLLISION_INTERVAL:
		_movement.collision_timer = _movement.COLLISION_INTERVAL
	_movement.collision_timer -= delta
	if _movement.collision_timer <= 0.0:
		# 后期单位多时降低碰撞分离频率：每次 apply_collision 都会做近邻空间查询，
		# 几百个单位 × 每秒 6~7 次是稳定的 CPU 热点；移动单位略拉长间隔，
		# 站桩单位用更长间隔，避免完全不做分离导致模型穿模。
		var collision_interval: float = _movement.COLLISION_INTERVAL
		if moving_collision:
			if bm and bm._all_entities.size() > 300:
				collision_interval *= 1.5
		else:
			collision_interval = 0.35
		_movement.collision_timer = collision_interval
		_movement.apply_collision(delta)
	
	# 决策节流
	_tick_think(delta, bm)

func _tick_think(delta, bm) -> void:
	think_timer -= delta
	if think_timer <= 0:
		# 后期单位数量多时，降低每个单位的决策频率。绝大多数闲置单位的
		# 目标搜索每 0.3s 做一次空间查询，几百个单位会形成稳定 CPU 负担；
		# 按规模拉开到 0.45~0.75s，对操作手感影响很小，却能明显降低后期开销。
		var think_interval: float = THINK_INTERVAL
		if bm:
			var entity_total: int = bm._all_entities.size()
			if entity_total > 450:
				think_interval = 0.75
			elif entity_total > 360:
				think_interval = 0.6
			elif entity_total > 240:
				think_interval = 0.45
		think_timer = think_interval
		_think(delta, bm)
	
	
# 暂时记下“寻路到不了”的目标，避免自动索敌反复锁回同一个墙后/对岸目标。
func _is_target_marked_unreachable(target) -> bool:
	if target == null or not is_instance_valid(target) or not (target is GameEntity):
		return false
	var tid: int = target.get_instance_id()
	var until: int = int(_unreachable_targets.get(tid, 0))
	if until <= 0:
		return false
	if Time.get_ticks_msec() >= until:
		_unreachable_targets.erase(tid)
		return false
	return true

func _mark_target_unreachable(target) -> void:
	if target == null or not is_instance_valid(target) or not (target is GameEntity):
		return
	_unreachable_targets[target.get_instance_id()] = Time.get_ticks_msec() + UNREACHABLE_TARGET_MEMORY_MS

# 阵营/敌对关系是否仍允许攻击。中立动物是手动狩猎的合法目标，不按敌对判定。
func _is_target_team_valid(target) -> bool:
	if target == null or not is_instance_valid(target) or not (target is GameEntity):
		return false
	if target.health <= 0:
		return false
	if target.team == RTSConfig.Team.NEUTRAL:
		return true
	return _is_hostile_to(target)

# 完整校验目标：阵营 + 攻击类型（上墙、上船、僧侣不攻击建筑等）。
func _is_target_attackable_now(target) -> bool:
	if not _is_target_team_valid(target):
		return false
	if target is WorldResource:
		return false
	return _can_attack_target(target)

# 敌方建筑是否正挡在前往目的地的方向上（且已经贴身）。
# A* 把建筑格当作高成本可通行格，普通移动/攻击移动的目的地在墙后时，
# 单位会一直顶在墙上；用方向点积把“挡路的墙”和“从旁边擦过”区分开。
func _is_blocking_building_ahead(blocker: Building, dest: Vector3) -> bool:
	if blocker == null or not is_instance_valid(blocker) or blocker.health <= 0:
		return false
	if not _is_hostile_to(blocker):
		return false
	if global_position.distance_to(blocker.global_position) > body_radius + blocker.body_radius + 1.0:
		return false
	var to_dest := Vector3(dest.x - global_position.x, 0.0, dest.z - global_position.z)
	if to_dest.length_squared() < 0.25:
		return false
	var to_block := Vector3(blocker.global_position.x - global_position.x, 0.0,
							blocker.global_position.z - global_position.z)
	if to_block.length_squared() < 0.0001:
		return true
	return to_dest.normalized().dot(to_block.normalized()) >= 0.6

# 目标换阵营/上墙/上船/不再可攻击时立即放弃，避免长老/宗师把已招降的友军继续当目标。
func _drop_current_attack_target() -> void:
	current_target = null
	_target_validate_timer = 0.0
	_attack_watch_target_id = -1
	_attack_stall_time = 0.0
	_retarget_target_id = -1
	if _movement:
		_movement.stop()
	if is_attack_moving:
		_attack_move_search_timer = 0.0
		return
	_set_order(UnitState.IDLE)
	_find_enemy_in_range()

# 目标打不到时，优先改打最近的敌方建筑（城墙/建筑），让近战单位去拆挡路物，
# 而不是站在原地看着目标播放走路动画。
func _find_attack_fallback_building(bm: RTSBattleManager) -> Building:
	if bm == null:
		return null
	var candidates: Array = bm.get_nearby_enemies(global_position, vision_range, team, owner_peer_id)
	var best: Building = null
	var best_dist: float = INF
	for e in candidates:
		if not is_instance_valid(e) or e.health <= 0:
			continue
		if not (e is Building) or e == current_target:
			continue
		if not _can_attack_target(e):
			continue
		if _is_target_marked_unreachable(e):
			continue
		var h_diff = Vector2(e.global_position.x - global_position.x,
							e.global_position.z - global_position.z)
		var dist: float = h_diff.length() - body_radius - e.body_radius
		if dist < best_dist:
			best_dist = dist
			best = e
	return best

func _handle_unreachable_attack_target(bm: RTSBattleManager, preserve_attack_move: bool = false) -> void:
	if hold_position:
		current_target = null
		_attack_watch_target_id = -1
		_attack_stall_time = 0.0
		_set_order(UnitState.IDLE)
		_movement.stop()
		return
	var old_target = current_target
	if old_target != null and is_instance_valid(old_target):
		_mark_target_unreachable(old_target)
	var fallback: Building = _find_attack_fallback_building(bm)
	if fallback != null:
		current_target = fallback
		_retarget_target_id = fallback.get_instance_id()
		_retarget_timer = _retarget_interval(bm)
		_attack_watch_target_id = fallback.get_instance_id()
		_attack_stall_time = 0.0
		if preserve_attack_move:
			# 攻击移动中撞到墙/建筑：先拆挡路物，拆完后仍继续去原目的地
			is_attack_moving = true
			_set_order(UnitState.ATTACK_MOVING)
		else:
			is_attack_moving = false
			_set_order(UnitState.ATTACKING)
		_movement.set_move_target(fallback.global_position, attack_range)
		return
	current_target = null
	_attack_watch_target_id = -1
	_attack_stall_time = 0.0
	if preserve_attack_move:
		# 攻击移动只是暂时锁了一个到不了的目标：丢掉目标，继续向目的地推进
		_attack_move_search_timer = 0.0
		return
	_set_order(UnitState.IDLE)
	is_attack_moving = false
	_movement.stop()
	_find_enemy_in_range()

# 攻击目标不在射程内且 A* 持续无路时，1.2 秒后触发兜底处理。
func _check_attack_approach(delta: float, bm: RTSBattleManager, preserve_attack_move: bool = false) -> void:
	if current_target == null or not is_instance_valid(current_target) or _movement == null:
		return
	var tid: int = current_target.get_instance_id()
	if tid != _attack_watch_target_id:
		_attack_watch_target_id = tid
		_attack_stall_time = 0.0
		# 换目标后旧目标的寻路失败标记不能沿用，否则会提前触发新目标的兜底
		_movement.attack_path_failed = false
	if _movement._pending_path:
		return
	if not _movement.attack_path_failed:
		_attack_stall_time = 0.0
		return
	_attack_stall_time += delta
	if _attack_stall_time < ATTACK_APPROACH_STUCK_TIME:
		return
	_attack_stall_time = 0.0
	_handle_unreachable_attack_target(bm, preserve_attack_move)

# ----------------- ÐÐÎª´¦Àí -----------------
func _process_action(delta, bm):
	# ½»¸¶×´Ì¬
	if _order_is(UnitState.DELIVERING):
		if delivery_target == null or not is_instance_valid(delivery_target):
			# 交付点失效（主城被拆/引用被清空）：重找一个；实在没有可送的地方就回空闲（货物保留）
			delivery_target = null
			_deliver_approach_time = 0.0
			_deliver_retry_count = 0
			current_target = null
			if not _return_to_deliver():
				_set_order(UnitState.IDLE)
			return
				# Ê¹ÓÃË®Æ½¾àÀë£¨ºöÂÔ¸ß¶È²î£©£¬±ÜÃâµØÐÎÆð·ü¸ÉÈÅ
		var h_diff = Vector2(delivery_target.global_position.x - global_position.x,
							delivery_target.global_position.z - global_position.z)
		# 用原始距离判断是否够近：农民会被建筑碰撞体挡在边缘（约 2.4~2.6 米），
		# 老代码用 h_dist <= 0.8 会把「已到达但差几十厘米」误判成没到，导致永远交不了货
		if h_diff.length() <= body_radius + delivery_target.body_radius + DELIVER_CONTACT_SLACK:
			if bm and bm.has_method("deliver_player_resources") and owner_peer_id != -1:
				bm.deliver_player_resources(owner_peer_id, cargo)
			else:
				# 1v1 »ØÍË
				
				bm.deliver_resources(cargo, team)
			cargo.clear()
			delivery_target = null
			current_target = null
			_deliver_approach_time = 0.0
			_deliver_retry_count = 0
			_set_order(UnitState.IDLE)
			if is_instance_valid(last_resource_target) and last_resource_target.health > 0:
				gather_at(last_resource_target)
			elif target_type == 0 and not _is_gather_paused():
				_find_nearest_resource()
			last_resource_target = null
		else:
			_deliver_approach_time += delta
			var cur_dist: float = h_diff.length()
			# 每 1.5 秒检查一次：距离没有明显缩短就强制重算路径。
			# 农民可能因为 A* 失败/建筑格被 blacklist/目标点仍停在旧值而原地不动，
			# 此时 set_move_target 会被内部提前 return 掉，必须靠这里兜底。
			_deliver_check_timer += delta
			if _deliver_check_timer >= 1.5:
				_deliver_check_timer = 0.0
				var moved_enough: bool = _deliver_last_dist < 0.0 or absf(cur_dist - _deliver_last_dist) > 0.4
				_deliver_last_dist = cur_dist
				if not moved_enough and _movement:
					_movement.recalculate()
			if _deliver_approach_time > DELIVER_APPROACH_TIMEOUT:
				_deliver_approach_time = 0.0
				_deliver_retry_count += 1
				if _deliver_retry_count >= 2:
					# 反复走不到：换一个交付点；没有别的仓库就回空闲等玩家处理
					_deliver_retry_count = 0
					delivery_target = null
					current_target = null
					if not _return_to_deliver():
						_set_order(UnitState.IDLE)
				elif _movement:
					# 主城周围被建筑/单位围住时 A* 会算不出完整路径，强制重算一次
					_movement.recalculate()
			else:
				# 目标点取建筑外缘（走到城堡中心会导致路径不可达而原地卡住）
				var arrive: float = delivery_target.body_radius + body_radius + 0.5
				if delivery_target.global_position != _movement.astar_target:
					_movement.set_move_target(delivery_target.global_position, arrive)
		return
		# Èç¹ûÊÇÒÆ¶¯ÃüÁîÇÒÒÑ½Ó½üÄ¿±ê£¬Çå³ýÃüÁî£¬×ªÎª¿ÕÏÐ
	if _order_is(UnitState.MOVING) and not is_attack_moving:
		if _movement.astar_target != Vector3.ZERO:
			var h_diff = Vector2(_movement.astar_target.x - global_position.x, _movement.astar_target.z - global_position.z)
			if h_diff.length() < 0.2:
				_set_order(UnitState.IDLE)
				current_target = null
				_movement.astar_path.clear()
				_movement.astar_target = Vector3.ZERO
				# Pop completed visual waypoint
				if _current_move_queued and _visual_waypoints.size() > 0:
					_visual_waypoints.pop_front()
					_current_move_queued = false
				
				# ²É¼¯µ¥Î»»áÓÉ¿ÕÏÐÂß¼­´¦Àí
		if _movement.move_path_failed:
			# 目的地本身无路可走：取消移动，避免一直保持 MOVING 播放走路动画
			current_target = null
			_set_order(UnitState.IDLE)
			_movement.stop()
			return
		if _movement.blocking_building != null \
				and _is_blocking_building_ahead(_movement.blocking_building, _movement.astar_target):
			# 普通移动被敌方建筑挡住：停在墙前转空闲，由索敌逻辑决定是否反击，
			# 不要保持 MOVING 一直顶着墙播放走路动画。
			current_target = null
			_set_order(UnitState.IDLE)
			_movement.stop()
			return
	# ¹¥»÷ÒÆ¶¯
	if is_attack_moving:
		_attack_move_search_timer -= delta
		# 目标死亡/被释放时立即清空并允许下一帧重选；无目标时也必须等
		# 搜索间隔，不能每帧都做一次空间查询（后期大军攻击移动会形成热点）。
		if current_target != null and not is_instance_valid(current_target):
			current_target = null
			_attack_move_search_timer = 0.0
		# 目标中途换阵营/上墙/上船后不能再追，丢弃目标并继续攻击移动
		if current_target != null and is_instance_valid(current_target) \
				and not _is_target_team_valid(current_target):
			current_target = null
			_attack_watch_target_id = -1
			_attack_stall_time = 0.0
			_attack_move_search_timer = 0.0
		if _attack_move_search_timer <= 0.0:
			_attack_move_search_timer = ATTACK_MOVE_SEARCH_INTERVAL
			_find_enemy_in_range()
			# _find_enemy_in_range 会按普通攻击把 is_attack_moving 置 false；
			# 攻击移动必须保留状态，清掉目标后继续去目的地。
			if current_target != null and is_instance_valid(current_target):
				is_attack_moving = true
				_set_order(UnitState.ATTACK_MOVING)
				_target_validate_timer = 0.0
		# 攻击移动的目标也做低频完整校验（上墙/上船/建筑类型变化），避免对无效目标挥击
		if current_target != null and is_instance_valid(current_target):
			_target_validate_timer -= delta
			if _target_validate_timer <= 0.0:
				_target_validate_timer = TARGET_VALIDATE_INTERVAL
				if not _can_attack_target(current_target):
					current_target = null
					_attack_watch_target_id = -1
					_attack_stall_time = 0.0
					_attack_move_search_timer = 0.0
		if current_target and is_instance_valid(current_target):
			# 与普通攻击一致用水平距离，避免目标站在高地时 3D 距离永远进不了射程
			var _td := Vector2(current_target.global_position.x - global_position.x,
							current_target.global_position.z - global_position.z)
			var dist: float = _td.length() - body_radius - current_target.body_radius
			if dist <= attack_range:
				_attack_tick(current_target, delta, bm)
			else:
				var blocker: Building = _movement.blocking_building
				if blocker != null and is_instance_valid(blocker) and blocker != current_target \
						and blocker.health > 0 and _can_attack_target(blocker) \
						and global_position.distance_to(blocker.global_position) <= body_radius + blocker.body_radius + 1.0:
					current_target = blocker
					_retarget_target_id = blocker.get_instance_id()
					_retarget_timer = _retarget_interval(bm)
					_attack_watch_target_id = blocker.get_instance_id()
					_attack_stall_time = 0.0
					_movement.set_move_target(blocker.global_position, attack_range)
					return
				_check_attack_approach(delta, bm, true)
				if current_target != null and is_instance_valid(current_target):
					_movement.set_move_target(current_target.global_position, attack_range)
		else:
			var _dest_blocker: Building = _movement.blocking_building
			if _dest_blocker != null and _can_attack_target(_dest_blocker) \
					and _is_blocking_building_ahead(_dest_blocker, attack_move_target):
				# 攻击移动被敌方建筑挡住：先拆挡路建筑，拆完继续去目的地
				current_target = _dest_blocker
				_retarget_target_id = _dest_blocker.get_instance_id()
				_retarget_timer = _retarget_interval(bm)
				_attack_watch_target_id = _dest_blocker.get_instance_id()
				_attack_stall_time = 0.0
				_movement.set_move_target(_dest_blocker.global_position, attack_range)
				return
			if _movement.move_path_failed:
				# 攻击移动的终点被城墙/建筑封锁时，先改打视野内最近的敌方建筑；
				# 拆掉挡路物后目标死亡，攻击移动状态会继续把部队送往原目的地。
				var fallback: Building = _find_attack_fallback_building(bm)
				if fallback != null and is_instance_valid(fallback) and _can_attack_target(fallback):
					current_target = fallback
					_retarget_target_id = fallback.get_instance_id()
					_retarget_timer = _retarget_interval(bm)
					_attack_watch_target_id = fallback.get_instance_id()
					_attack_stall_time = 0.0
					is_attack_moving = true
					_set_order(UnitState.ATTACK_MOVING)
					_movement.set_move_target(fallback.global_position, attack_range)
					return
				is_attack_moving = false
				attack_move_target = Vector3.ZERO
				_set_order(UnitState.IDLE)
				_movement.stop()
				return
			if global_position.distance_to(attack_move_target) < body_radius + 0.5:
				is_attack_moving = false
				attack_move_target = Vector3.ZERO
				if _current_move_queued and _visual_waypoints.size() > 0:
					_visual_waypoints.pop_front()
					_current_move_queued = false
				# 攻击移动已经到达终点且没有可打目标，必须显式回到 IDLE。
				# 否则 current_order 会一直停在 attack_move：命令队列不会弹出，
				# 空闲索敌也不会执行，单位会原地站着不还手。
				_set_order(UnitState.IDLE)
			else:
				_movement.set_move_target(attack_move_target)
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
				_gather_approach_time = 0.0
				_gather(current_target, delta)
			else:
				# 超过 GATHER_APPROACH_TIMEOUT 秒还没走到资源点（地形阻挡/被单位挤住/不可达）：
				# 放弃并重找，否则农民会一直停在原地显示「采集」却收获不到任何资源
				_gather_approach_time += delta
				if _gather_approach_time > GATHER_APPROACH_TIMEOUT:
					_gather_approach_time = 0.0
					current_target = null
					_set_order(UnitState.IDLE)
					return
				_movement.set_move_target(current_target.global_position)
		elif _order_is(UnitState.GATHERING):
			# 采集状态却锁着非资源目标（命令误给/资源点被替换）：清掉回空闲，避免永久假采集
			current_target = null
			_set_order(UnitState.IDLE)
		elif current_target is GameEntity:
			# 目标换阵营/上墙/上船后立即放弃；攻击类型（建筑/梯子/桥等）变化较慢，
			# 每 0.5 秒完整校验一次，避免每帧扫描建筑造成性能回退。
			if not _is_healer():
				_target_validate_timer -= delta
				if not _is_target_team_valid(current_target):
					_drop_current_attack_target()
					return
				if _target_validate_timer <= 0.0:
					_target_validate_timer = TARGET_VALIDATE_INTERVAL
					if not _can_attack_target(current_target):
						_drop_current_attack_target()
						return
			var target_id: int = current_target.get_instance_id()
			if target_id != _retarget_target_id:
				_retarget_target_id = target_id
				_retarget_timer = _retarget_interval(bm)
				_target_validate_timer = 0.0
			if h_dist <= attack_range:
				_retarget_timer = _retarget_interval(bm)
				_attack_stall_time = 0.0
				if _movement:
					_movement.attack_path_failed = false
				_attack_tick(current_target, delta, bm)
			else:
				# 原地防守单位不追出射程，否则目标在墙后时会站在原地播放走路动画
				if hold_position:
					current_target = null
					_attack_watch_target_id = -1
					_attack_stall_time = 0.0
					_set_order(UnitState.IDLE)
					_movement.stop()
					return
				# A* 允许穿过建筑格（成本较高），追击墙后目标时单位会实际顶在墙上。
				# 已经撞到敌方建筑就改打这面挡路的墙/建筑，不要对着墙原地踏步。
				var blocker: Building = _movement.blocking_building
				if blocker != null and is_instance_valid(blocker) and blocker != current_target \
						and blocker.health > 0 and _can_attack_target(blocker) \
						and global_position.distance_to(blocker.global_position) <= body_radius + blocker.body_radius + 1.0:
					if current_target != null and is_instance_valid(current_target):
						_mark_target_unreachable(current_target)
					current_target = blocker
					_retarget_target_id = blocker.get_instance_id()
					_retarget_timer = _retarget_interval(bm)
					_attack_watch_target_id = blocker.get_instance_id()
					_attack_stall_time = 0.0
					_set_order(UnitState.ATTACKING)
					is_attack_moving = false
					_movement.set_move_target(blocker.global_position, attack_range)
					return
				# 目标不在攻击范围：每秒检查一次是否有更近的敌人，避免一直追远目标
				_retarget_timer -= delta
				if _retarget_timer <= 0.0:
					_retarget_timer = _retarget_interval(bm)
					_try_retarget_closer(h_dist)
				if current_target != null and is_instance_valid(current_target):
					_check_attack_approach(delta, bm)
				if current_target != null and is_instance_valid(current_target):
					_movement.set_move_target(current_target.global_position, attack_range)

# 当前目标不在射程内时，重选更近目标会做一次空间查询。后期单位多时
# 把它从 1s 放宽到 2~3s，避免几百个单位持续做密集查询。
func _retarget_interval(bm) -> float:
	if bm != null:
		var total: int = bm._all_entities.size()
		if total > 450:
			return 3.0
		if total > 300:
			return 2.0
	return TARGET_RETARGET_INTERVAL

# 当前目标不在攻击范围时，每秒最多切换一次：只在确实存在更近的敌人时改锁。
# 驻扎单位只在驻扎防御圈内找目标，避免被视野边缘的敌人引走。
func _try_retarget_closer(current_dist: float) -> void:
	# 僧侣的目标是友方伤兵，不能被「换更近的敌人」逻辑替换
	if _is_healer():
		return
	if current_target == null or not is_instance_valid(current_target):
		return
	if not (current_target is GameEntity) or current_target.health <= 0:
		return
	var best = null
	if garrison_point != Vector3.ZERO:
		best = _find_nearest_enemy_near(garrison_point, GARRISON_DEFEND_RADIUS)
	else:
		# 只可能换到“更近”的目标，搜索半径不需要覆盖整个视野。
		# 混战时把 15m 视野缩到当前目标距离附近，候选数量会少一个数量级。
		var search_radius: float = minf(vision_range, current_dist + body_radius + 3.0)
		best = _find_nearest_enemy_near(global_position, search_radius)
	if best == null or not is_instance_valid(best) or best == current_target:
		return
	if not _can_attack_target(best):
		return
	if _is_target_marked_unreachable(best):
		return
	var h_diff = Vector2(best.global_position.x - global_position.x,
						best.global_position.z - global_position.z)
	var best_dist = h_diff.length() - body_radius - best.body_radius
	if best_dist + 0.05 < current_dist:
		current_target = best
		_set_order(UnitState.ATTACKING)
		is_attack_moving = false
		_retarget_target_id = best.get_instance_id()
		_retarget_timer = _retarget_interval(_cached_bm)

# 只有“正在回驻扎点”的移动才允许被驻扎防御逻辑接管；
# 玩家/AI 的其他移动命令仍然优先，避免驻扎点把单位永久拉回去。
func _is_returning_to_garrison() -> bool:
	if not _order_is(UnitState.MOVING) or _movement == null:
		return false
	var dest: Vector3 = _movement.astar_target
	if dest == Vector3.ZERO:
		return false
	return dest.distance_to(garrison_point) <= 3.0

# ----------------- ¾ö²ß£¨½ÚÁ÷£© -----------------

func _think(delta, bm):
	if current_target != null and not is_instance_valid(current_target):
		current_target = null
		_set_order(UnitState.IDLE)
		is_attack_moving = false
	# 队列里可能还有已采空/被摧毁的目标；整队清掉，避免循环命令反复撞失效目标
	for cmd in command_queue:
		if cmd.has("target") and not _is_valid_command_target(cmd["target"]):
			_clear_command_queue()
			break
	# 驻扎防御：驻扎点附近有敌人时先清敌，不要立刻回驻扎点；
	# 清空驻扎防御圈后再返回。追击目标跑出防御圈则放弃并回防。
	if garrison_point != Vector3.ZERO:
		var defend_radius: float = GARRISON_DEFEND_RADIUS
		# AI 建筑被攻击时给附近驻扎部队下的临时反击命令，允许它们离开
		# 原驻扎圈去追攻击者；15 秒后自动恢复普通驻扎逻辑。
		if has_meta("ai_building_defense_until"):
			var until: float = float(get_meta("ai_building_defense_until"))
			if bm != null and float(bm.game_time) < until:
				defend_radius = 45.0
			else:
				remove_meta("ai_building_defense_until")
		if current_target != null and _order_is(UnitState.ATTACKING):
			if current_target.global_position.distance_to(garrison_point) > defend_radius:
				current_target = null
				_set_order(UnitState.IDLE)
				is_attack_moving = false
				move_to(garrison_point)
				return
		if current_target == null and not is_attack_moving and (_order_is(UnitState.IDLE) or _is_returning_to_garrison()):
			var enemy = _find_nearest_enemy_near(garrison_point, defend_radius)
			if enemy and is_instance_valid(enemy) and enemy.health > 0:
				attack_target(enemy)
			else:
				var gdist = global_position.distance_to(garrison_point)
				# 已经在回驻扎点的路上就不要每 0.3s 重设一次路径，避免反复重算 A*
				if gdist > 2.0 and not _is_returning_to_garrison():
					move_to(garrison_point)
			return

	# If current order done and queue has commands, pop next
	if current_target == null and _order_is(UnitState.IDLE) and not is_attack_moving and command_queue.size() > 0:
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

	if current_target == null and _order_is(UnitState.IDLE) and not is_attack_moving:
		if _get_cargo_total() > 0:
			_return_to_deliver()
		elif _is_healer():
			# 僧侣空闲时只找伤兵治疗，不去采集
			_find_wounded_ally()
		elif target_type == 0:
			if not _is_gather_paused():
				_find_nearest_resource()
		else:
			_find_enemy_in_range()

		# ¸ù¾ÝµØÐÎ¸ß¶ÈÆ½»¬¸üÐÂ Y ×ø±ê
	
	if bm:
		var map = bm.get_node("Map")
		if map and map.has_method("get_height_at"):
			var target_height = map.get_height_at(global_position)
			# Ã¿Ãë×î´óÉý½µËÙ¶È
			var elevation_speed = 5.0
			global_position.y = move_toward(global_position.y, target_height, elevation_speed * delta)

func recalculate_path():
	# 建筑布局变化后，之前“打不到”的目标可能已经可达
	_unreachable_targets.clear()
	_attack_stall_time = 0.0
	if _movement: _movement.recalculate()

# 大规模交战时把每个单位的攻击更新错峰到 2~3 帧一次，并用累积 delta 保持
# 相同攻击频率。攻击本身的冷却、音效和弹丸数量不变，只减少每帧 GDScript 调用。
func _attack_tick(target, delta, bm) -> void:
	if target == null or not is_instance_valid(target):
		return
	# 目标可能在锁定后上墙/上船/被招降；这里只用廉价校验（每帧都会调用），
	# 建筑/梯子等完整攻击类型校验由 _process_action 每 0.5 秒做一次。
	if not _is_healer():
		var _cheap_invalid: bool = not _is_target_team_valid(target)
		if not _cheap_invalid and _is_land_melee() and target is Army and target.water_capable:
			_cheap_invalid = true
		if _cheap_invalid:
			if target == current_target:
				if is_attack_moving:
					current_target = null
					_attack_move_search_timer = 0.0
				else:
					_drop_current_attack_target()
			return
	# 站定攻击时每帧保持面向目标；目标绕后/移动后不能还朝旧方向挥击。
	_face_attack_target(target)
	var stride: int = 1
	if bm:
		var total: int = bm._all_entities.size()
		if total > 600:
			stride = 3
		elif total > 420:
			stride = 2
	if stride > 1 and (Engine.get_physics_frames() + get_instance_id()) % stride != 0:
		return
	_attack(target, delta * stride)

# 攻击时面向目标。只转水平方向，避免目标高低差导致单位俯仰。
func _face_attack_target(target) -> void:
	if target == null or not is_instance_valid(target):
		return
	var to_target: Vector3 = target.global_position - global_position
	to_target.y = 0.0
	if to_target.length_squared() < 0.0001:
		return
	look_at(global_position + to_target, Vector3.UP)

func _attack(target, delta):
	if _is_target_gone(target):
		if current_target == target or current_target == null:
			current_target = null
			_attack_move_search_timer = 0.0
			if not is_attack_moving:
				_set_order(UnitState.IDLE)
				if _movement:
					_movement.stop()
			_refresh_animation_now()
		return

	# 特殊攻击类型：僧侣治疗 / 长老百分比伤害 / 宗师降攻招降
	if entity_id == 55:
		if attack_timer <= 0.0:
			_play_attack_feedback()
		_monk_heal(target, delta)
		return
	if entity_id == 56:
		if attack_timer <= 0.0:
			_play_attack_feedback()
		_elder_attack(target, delta)
		return
	if entity_id == 57:
		if attack_timer <= 0.0:
			_play_attack_feedback()
		_grandmaster_attack(target, delta)
		return

	if attack_timer > 0:
		attack_timer -= delta
		return
	_play_attack_feedback()

	# ½üÕ½·¶Î§ÉËº¦£¨³¤Ç¹±øµÈ£©
	if damage_radius > 0 and attack_range <= 2.0:
		var bm_aoe = _get_bm()
		var all_entities = bm_aoe.get_nearby_entities(global_position, damage_radius + 4.0) if bm_aoe else get_tree().get_nodes_in_group("entities")
		for entity in all_entities:
			if entity == self or not (entity is GameEntity) or entity.health <= 0:
				continue
			if not _is_hostile_to(entity):
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

		var bullet_bm = _get_bm()
		if bullet_bm == null:
			attack_timer = attack_speed
			return
		for i in range(bullet_count):
			var bullet = bullet_bm.acquire_bullet(self, damage_radius, team)
			bullet.team = team
			bullet.owner_peer_id = owner_peer_id
			bullet.damage = attack
			bullet.speed = 8.0
			bullet.source = self
			bullet.damage_radius = damage_radius

			# 投石车(17) / 巨型投石机(59)：子弹飞向固定位置，不追踪目标
			if entity_id == 17 or entity_id == 59:
				var tpos = target.global_position
				# 巨型投石机50%概率打偏
				if entity_id == 59 and randf() < 0.5:
					var miss_offset = Vector3(randf_range(-attack_range, attack_range), 0, randf_range(-attack_range, attack_range))
					tpos += miss_offset
				bullet.target_pos = tpos
			else:
				bullet.target = target

			var angle_offset = 0.0
			if bullet_count > 1 and spread_angle > 0:
				angle_offset = (i - (bullet_count - 1) / 2.0) * spread_angle / (bullet_count - 1)

			var spawn_dir = (target.global_position - global_position).normalized()
			var perpendicular = Vector3(spawn_dir.z, 0, -spawn_dir.x)
			var offset = perpendicular * sin(angle_offset) * 0.3
			# acquire_bullet 已把弹丸挂到 BattleManager 下，这里只设置入树后的全局坐标
			bullet.global_position = global_position + Vector3(0, body_radius * 2.5, 0) + offset
	else:
		var _dmg_m = attack
		# 农民对动物伤害+900%
		if entity_id == 10 and target.get("_animal_type") != null and str(target.get("_animal_type")) != "":
			_dmg_m = attack * 10
		target.take_damage(_dmg_m, self)

	attack_timer = attack_speed

# 攻击音效/动画只在真正出手时触发；此前每帧调用会让上百个交战单位
# 每秒尝试播放几千次音效，同时反复刷新动画状态。
func _play_attack_feedback() -> void:
	var _sfx = ""
	if entity_id in [12, 26, 33, 58]: _sfx = "arrow_shoot"
	elif entity_id == 16 or entity_id in [13, 39]: _sfx = "cannon_fire"
	elif entity_id in [17, 59]: _sfx = "treb_fire"
	elif entity_id in [15]: _sfx = "sword_swing"
	elif entity_id in [11, 30, 49, 18, 35]: _sfx = "heavy_swing"
	elif entity_id in [38, 40]: _sfx = "sword_swing"
	if _sfx != "":
		AudioManager.play_sfx_3d(_sfx, global_position, _get_cam_pos())
	# 真正出手时刷新一次动画：单位可能刚进入攻击距离，不能只等 30 帧轮询
	# 才从走路切到攻击；这里每次攻击只调用一次，不会形成每帧音效/动画刷新。
	# 只有攻城六件套需要联机端按“真实出手次数”播放动画；其他兵种不递增，
	# 避免每次普攻都改变快照哈希、平白增加同步带宽。
	if SiegeAttackAnim.is_siege(entity_id):
		attack_seq += 1
	var bm = _get_bm()
	if bm:
		# 攻城器械在这里直接播放一次分层动画；联机客户端没有 Army，
		# 会在快照里检测 attack_seq 变化后播放一次。
		if bm.has_method("_on_entity_attack_started"):
			bm._on_entity_attack_started(self)
		if bm.has_method("_update_entity_animation"):
			bm._update_entity_animation(self)

# ==================== 特殊攻击 ====================

# 僧侣：治疗周围范围内血量百分比最低的己方军队（百分比回血）
func _monk_heal(_target, delta):
	if attack_timer > 0:
		attack_timer -= delta
		return
	var lowest = null
	var lowest_pct: float = 2.0
	var bm_heal = _get_bm()
	var heal_candidates = bm_heal.get_nearby_entities(global_position, attack_range + 4.0) if bm_heal else get_tree().get_nodes_in_group("entities")
	for entity in heal_candidates:
		if not (entity is Army) or entity == self or entity.health <= 0: continue
		if entity.team != team: continue
		var dist = global_position.distance_to(entity.global_position)
		if dist <= attack_range + entity.body_radius:
			var hp_pct = entity.health / entity.max_health
			if hp_pct < lowest_pct and hp_pct < 1.0:
				lowest_pct = hp_pct
				lowest = entity
	if lowest:
		var heal_amt = min(attack, lowest.max_health - lowest.health)
		lowest.health += heal_amt
		attack_timer = attack_speed
		_spawn_effect_marker(lowest, Color.GREEN)

# 长老：对目标军队造成5%最大生命值伤害，远程，无视护甲
func _elder_attack(target, delta):
	if attack_timer > 0:
		attack_timer -= delta
		return
	if not is_instance_valid(target) or target.health <= 0: return
	if not (target is Army):
		current_target = null
		return
	var dmg = target.max_health * 0.05
	target.health -= dmg
	_spawn_effect_marker(target, Color.RED)
	if target.health <= 0:
		target.die()
	attack_timer = attack_speed

# 宗师：降低目标攻击力（2格内翻倍），攻击<0时招降
func _grandmaster_attack(target, delta):
	if attack_timer > 0:
		attack_timer -= delta
		return
	if not is_instance_valid(target) or target.health <= 0: return
	if not (target is Army):
		current_target = null
		return
	var reduce = attack
	var dist = global_position.distance_to(target.global_position)
	if dist <= 2.0 + body_radius + target.body_radius:
		reduce *= 2
	if not target.has_meta("_original_attack"):
		target.set_meta("_original_attack", target.attack)
	target.attack -= reduce
	_spawn_effect_marker(target, Color.YELLOW)
	if target.attack < 0:
		# 招降：先恢复攻击力，再完整转移阵营/所有权并清理旧命令与仇恨目标
		target.attack = target.get_meta("_original_attack")
		target.remove_meta("_original_attack")
		target.convert_to_team(team, owner_peer_id)
		_spawn_effect_marker(target, Color.YELLOW)
	attack_timer = attack_speed

# 完整转换单位的阵营与所有权。只改 team/owner 不够：
# 旧目标的攻击者仍会锁着它，它自己也可能还锁着原友军；缓存和颜色也要同步刷新。
func convert_to_team(new_team: int, new_owner: int) -> void:
	if new_team == team and new_owner == owner_peer_id:
		return
	var bm = _get_bm()
	# 清理自身旧命令、目标、驻扎点和路径
	current_target = null
	attack_move_target = Vector3.ZERO
	is_attack_moving = false
	garrison_point = Vector3.ZERO
	_garrison_target_id = -1
	delivery_target = null
	last_resource_target = null
	_clear_command_queue()
	_set_order(UnitState.IDLE)
	if _movement:
		_movement.astar_target = Vector3.ZERO
		_movement.astar_path.clear()
	for meta_key in ["ai_home_guard", "ai_resource_guard", "ai_harass", "ai_flee_until"]:
		if has_meta(meta_key):
			remove_meta(meta_key)

	team = new_team
	owner_peer_id = new_owner

	if bm:
		if bm.has_method("mark_entity_cache_dirty"):
			bm.mark_entity_cache_dirty()
		var tint: Color = Color(0.3, 0.6, 1.0) if new_team == RTSConfig.Team.BLUE else Color(1.0, 0.4, 0.4)
		if bm.has_method("get_entity_color"):
			tint = bm.get_entity_color(self)
		if bm.has_method("_apply_team_tint"):
			bm._apply_team_tint(self, tint)
		# 解除所有仍把本单位当作目标的攻击锁定，并丢掉针对它的排队攻击命令。
		# 否则转换后的第一秒内，我方部队仍会继续攻击这个新友军。
		for other in bm.entities.get_children():
			if other == self or not (other is Army) or not is_instance_valid(other):
				continue
			var other_army := other as Army
			if other_army.command_queue.size() > 0:
				var kept: Array = []
				for cmd in other_army.command_queue:
					if cmd.get("target") == self:
						continue
					kept.append(cmd)
				other_army.command_queue = kept
				if other_army.loop_index >= kept.size():
					other_army.loop_index = 0
			if other_army.current_target == self:
				other_army.current_target = null
				other_army.is_attack_moving = false
				if other_army.current_order == "attack" or other_army.current_order == "attack_move":
					other_army._set_order(UnitState.IDLE)
				if other_army._movement:
					other_army._movement.astar_target = Vector3.ZERO
					other_army._movement.astar_path.clear()
		if bm.has_method("_update_entity_animation"):
			bm._update_entity_animation(self)

# 特效标记：在目标头顶生成彩色球体，1秒后消失
func _spawn_effect_marker(target, color: Color):
	var marker = MeshInstance3D.new()
	var sphere = SphereMesh.new()
	sphere.radius = 0.3; sphere.height = 0.6
	marker.mesh = sphere
	marker.position = target.global_position + Vector3(0, target.body_radius * 3.0, 0)
	var mat = StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.render_priority = 10; mat.no_depth_test = true
	marker.material_override = mat
	var bm = _get_bm()
	if bm: bm.add_child(marker)
	var t = Timer.new(); t.one_shot = true; t.wait_time = 1.0
	t.timeout.connect(marker.queue_free)
	marker.add_child(t); t.start()

func _gather(resource_node, delta):
	if resource_node == null or not is_instance_valid(resource_node) or resource_node.health <= 0:
		current_target = null
		_set_order(UnitState.IDLE)
		return
	if gather_timer <= 0:
		var res_type = resource_node.resource_type
		if gatherable_resources.size() > 0 and not res_type in gatherable_resources:
			# 这类资源单位采不了（例如误派它去采不支持的种类）：
			# 清掉目标重找一个能采的，否则会一直站在资源点旁显示「采集」却零产出
			current_target = null
			_set_order(UnitState.IDLE)
			_find_nearest_resource()
			return
		var amount = int(attack)
		if GameSettings.fast_mode: amount *= 3
		var bm = get_tree().get_first_node_in_group("battle_manager")
		if bm and bm.has_method("get_team_nation"):
			var nation = bm.get_team_nation(team)
			amount = int(amount * NationBonuses.get_gather_mult(nation, res_type))
		if _get_cargo_total() + amount > max_cargo:
			# 满载回城交付；找不到交付点（基地被拆/附近没有仓库）时不能停在原地假采集
			if not _return_to_deliver():
				current_target = null
				_set_order(UnitState.IDLE)
			return
		resource_node.take_damage(amount, self)
		cargo[res_type] = cargo.get(res_type, 0) + amount
		# 采集音效 + 立即同步攻击动画
		AudioManager.play_sfx_3d("sword_swing", global_position, _get_cam_pos())
		if bm and bm.has_method("_update_entity_animation"):
			bm._update_entity_animation(self)
		gather_timer = 1.0
	gather_timer -= delta

func _get_cargo_total() -> int:
	var total = 0
	for v in cargo.values(): total += v
	return total

# 回城交付；找不到可交付的建筑时返回 false（调用方据此退出采集状态）
func _return_to_deliver() -> bool:
	var target = find_delivery_point()
	if target != null and is_instance_valid(target):
		if is_instance_valid(current_target) and current_target is WorldResource :
			last_resource_target = current_target
		delivery_target = target
		current_target = target
		_deliver_approach_time = 0.0
		_deliver_retry_count = 0
		_deliver_check_timer = 0.0
		_deliver_last_dist = -1.0
		_set_order(UnitState.DELIVERING)
		return true
	return false

# ----------------- Ñ°ÕÒ½»¸¶µã -----------------
func find_delivery_point() -> Building:
	var best: Building = null
	var best_dist = vision_range*10
	# 农民每次回城交付都会调用；优先使用 battle 的 Building 缓存，避免全实体扫描
	var bm = _get_bm()
	var candidates = bm._buildings if bm else get_tree().get_nodes_in_group("entities")
	for entity in candidates:
		if not is_instance_valid(entity):
			continue
		if entity is Building and entity.team == team and entity.health > 0:
			if cargo.get("oil", 0) > 0:
				if entity.entity_id == 23:   # ´¬Îë
					var dist = global_position.distance_to(entity.global_position)
					if dist < best_dist: best_dist = dist; best = entity
			else:
				if entity.entity_id == 20 or entity.entity_id == 22:  # ³Ç±¤or²Ö¿â
					var dist = global_position.distance_to(entity.global_position)
					if dist < best_dist: best_dist = dist; best = entity
	if best != null and not is_instance_valid(best):
		return null
	return best

# ----------------- Ñ°µÐ / Ñ°×ÊÔ´ -----------------
func _find_nearest_resource():
	var search_r: float = gather_search_range if gather_search_range > 0.0 else vision_range
	var bm = _get_bm()
	if bm:
		var best = bm.get_nearest_resource(global_position, search_r, gatherable_resources)
		if best: gather_at(best)
		return
	# 回退：如果没有 battle_manager，使用全量扫描
	var best_dist = search_r
	var best_target: WorldResource = null
	for entity in get_tree().get_nodes_in_group("entities"):
		if entity is WorldResource and entity.health > 0:
			if gatherable_resources.size() > 0 and not entity.resource_type in gatherable_resources:
				continue
			var dist = global_position.distance_to(entity.global_position) - body_radius - entity.body_radius
			if dist < best_dist: best_dist = dist; best_target = entity
	if best_target: gather_at(best_target)

# Unified entity search: finds nearest entity matching filter within range
func _find_nearest_entity(search_range: float, filter_func: Callable, use_cache: bool = true) -> GameEntity:
	var best_dist = search_range
	var best_target: GameEntity = null
	var bm = _get_bm()
	var candidates: Array = []
	if bm and use_cache:
		candidates = bm.get_nearby_enemies(global_position, search_range, team, owner_peer_id)
	else:
		candidates = get_tree().get_nodes_in_group("entities")
	for entity in candidates:
		if entity == self or not is_instance_valid(entity) or entity.health <= 0: continue
		if not filter_func.call(entity): continue
		var h_diff = Vector2(entity.global_position.x - global_position.x, entity.global_position.z - global_position.z)
		var dist = h_diff.length() - body_radius - entity.body_radius
		if dist <= search_range and dist < best_dist:
			best_dist = dist
			best_target = entity
	return best_target
# 僧侣专用：找附近血量百分比最低的友方非建筑单位，走过去治疗
func _find_wounded_ally() -> void:
	var bm = _get_bm()
	var cands: Array = []
	if bm and bm.has_method("get_nearby_entities"):
		cands = bm.get_nearby_entities(global_position, vision_range + 4.0)
	else:
		cands = get_tree().get_nodes_in_group("entities")
	var best = null
	var best_pct: float = 1.0
	for e in cands:
		if e == self or not is_instance_valid(e) or not (e is Army):
			continue
		if e.team != team or e.health <= 0:
			continue
		var pct: float = e.health / maxf(1.0, e.max_health)
		if pct < 0.999 and pct < best_pct:
			best_pct = pct
			best = e
	if best != null:
		current_target = best
		_set_order(UnitState.ATTACKING)
		is_attack_moving = false
		_movement.set_move_target(best.global_position, attack_range)

func _find_enemy_in_range():
	# 僧侣不索敌：它的目标是受伤的友军（由 _find_wounded_ally 处理）
	if _is_healer(): return
	if entity_id in [46, 47, 48, 50]: return
	var best_dist = vision_range * 1.2
	var best_target: GameEntity = null
	var bm = _get_bm()
	var enemies: Array = []
	if bm:
		enemies = bm.get_nearby_enemies(global_position, vision_range, team, owner_peer_id)
	else:
		enemies = get_tree().get_nodes_in_group("entities")
	for entity in enemies:
		if entity == self or not is_instance_valid(entity) or entity.health <= 0: continue
		if entity is WorldResource: continue
		if entity.get("_animal_type") != null and str(entity.get("_animal_type")) != "": continue
		# 攻击类型过滤
		if not _can_attack_target(entity): continue
		if _is_target_marked_unreachable(entity): continue
		if not bm:  # fallback: filter by team
			if entity.team == team: continue
			if entity is Building and entity.team == team: continue
		var h_diff = Vector2(entity.global_position.x - global_position.x, entity.global_position.z - global_position.z)
		var dist = h_diff.length() - body_radius - entity.body_radius
		# 只要发现射程内敌人就立即锁定，不必在几百个候选里继续找“最近”的。
		# 大规模混战时这会显著缩短每个单位的目标搜索循环。
		if dist <= attack_range:
			current_target = entity
			_set_order(UnitState.ATTACKING)
			is_attack_moving = false
			return
		if hold_position:
			continue
		if dist <= vision_range and dist < best_dist:
			best_dist = dist
			best_target = entity
	if best_target:
		current_target = best_target
		_set_order(UnitState.ATTACKING)
		is_attack_moving = false
func _should_queue() -> bool:
	if _force_queue_next:
		_force_queue_next = false
		return true
	if Input.is_key_pressed(KEY_SHIFT): return true
	#if not _order_is(UnitState.IDLE): return true
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if bm and bm.has_method("get_mp_shift") and bm.get_mp_shift(): return true
	return false

# 命令里保存的是实体引用；目标可能在排队期间被击杀/采空并释放。
# 在执行和入队前都必须先校验，否则给 current_target 赋值会触发 previously freed。
func _is_valid_command_target(target) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	if target is GameEntity and target.health <= 0:
		return false
	return true

func _queue_command(cmd: Dictionary):
	if cmd.has("target") and not _is_valid_command_target(cmd["target"]):
		return
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
			attack_move_target = Vector3.ZERO
			_set_order(UnitState.MOVING)
			is_attack_moving = false
			_movement.set_move_target(cmd["pos"])
		"attack":
			var attack_cmd_target = cmd.get("target")
			if not _is_valid_command_target(attack_cmd_target):
				return
			# 命令入队到执行之间目标可能已被招降/上墙/上船，执行时再校验一次
			if not _is_target_attackable_now(attack_cmd_target):
				return
			current_target = attack_cmd_target
			attack_move_target = Vector3.ZERO
			_set_order(UnitState.ATTACKING)
			is_attack_moving = false
			_movement.set_move_target(attack_cmd_target.global_position, attack_range)
		"gather":
			var gather_cmd_target = cmd.get("target")
			if not _is_valid_command_target(gather_cmd_target):
				return
			current_target = gather_cmd_target
			_gather_approach_time = 0.0
			_set_order(UnitState.GATHERING)
			is_attack_moving = false
			_movement.set_move_target(gather_cmd_target.global_position)
		"attack_move":
			attack_move_target = cmd["pos"]
			current_target = null
			is_attack_moving = true
			_set_order(UnitState.ATTACK_MOVING)
			_movement.set_move_target(cmd["pos"])

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
	_set_order(UnitState.IDLE)

func move_to(pos: Vector3):
	_queue_command({"type": "move", "pos": pos})

func attack_target(p_target):
	if not _is_valid_command_target(p_target):
		return
	# 手动指定目标时也拒绝陆军近战攻击海军，避免单位一直追到岸边
	if _is_land_melee() and p_target is Army and p_target.water_capable:
		return
	# 拒绝友军/盟友、上墙/上船、僧侣/修道院不能攻击的建筑等无效目标。
	# 中立动物仍允许手动狩猎，所以这里用 _is_target_attackable_now 而不是单纯敌对判断。
	if not _is_target_attackable_now(p_target):
		return
	# 玩家手动重新指定目标时清除“不可达”记忆，允许再试一次
	if p_target is GameEntity:
		_unreachable_targets.erase(p_target.get_instance_id())
	_queue_command({"type": "attack", "target": p_target})

func gather_at(source):
	if not _is_valid_command_target(source):
		return
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
	return bm.get_team_resources(team) if bm.has_method("get_team_resources") else (bm.player_resources if team == RTSConfig.Team.BLUE else bm.enemy_resources)

func _merchant_get_lim(bm):
	if owner_peer_id != -1 and bm.has_method("get_limits_for"):
		return bm.get_limits_for(owner_peer_id)
	return bm.get_team_resource_limits(team) if bm.has_method("get_team_resource_limits") else (bm.player_resource_limits if team == RTSConfig.Team.BLUE else bm.enemy_resource_limits)

func _merchant_deduct(bm, cost: Dictionary) -> bool:
	if owner_peer_id != -1 and bm.has_method("deduct_player_resources"):
		return bm.deduct_player_resources(owner_peer_id, cost)
	var res = bm.get_team_resources(team) if bm.has_method("get_team_resources") else (bm.player_resources if team == RTSConfig.Team.BLUE else bm.enemy_resources)
	for k in cost: if res.get(k,0) < cost[k]: return false
	for k in cost: res[k] -= cost[k]
	return true

func _merchant_add(bm, type: String, amount: int):
	if owner_peer_id != -1 and bm.has_method("add_resource_for"):
		bm.add_resource_for(owner_peer_id, type, amount)
		return
	var res = bm.get_team_resources(team) if bm.has_method("get_team_resources") else (bm.player_resources if team == RTSConfig.Team.BLUE else bm.enemy_resources)
	var lim = bm.get_team_resource_limits(team) if bm.has_method("get_team_resource_limits") else (bm.player_resource_limits if team == RTSConfig.Team.BLUE else bm.enemy_resource_limits)
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
			# Use A* path length for trade distance (not straight-line)
			var astar_dist = global_position.distance_to(best_market.global_position)
			if _movement:
				var path = _movement._calculate_astar_path(best_market.global_position)
				if path.size() > 1:
					astar_dist = 0.0
					for j in range(1, path.size()): astar_dist += path[j-1].distance_to(path[j])
			_merchant_trade_volume = _calc_trade_volume(own.upgrade_level, astar_dist)
			if has_meta("_cart_trade_bonus"): _merchant_trade_volume += get_meta("_cart_trade_bonus")
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
			if d < 5.0: _merchant_state = 3
			else:
				if _movement and _movement.astar_target.distance_squared_to(market.global_position) > 0.5:
					_movement.set_move_target(market.global_position)
					_set_order(UnitState.MOVING)
				_movement.process_move(delta, bm)

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
			else: 
				if _movement and _movement.astar_target.distance_squared_to(own.global_position) > 0.5:
					_movement.set_move_target(own.global_position)
					_set_order(UnitState.MOVING)
				_movement.process_move(delta, bm)

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
				var res = bm.get_team_resources(team) if bm.has_method("get_team_resources") else (bm.player_resources if team == RTSConfig.Team.BLUE else bm.enemy_resources)
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
				var dist = global_position.distance_to(e.global_position)
				if entity_id >= 46 and entity_id <= 50:
					# 官员进驻：距离 < 2
					if dist < 2.0:
						_do_garrison(e)
						_garrison_target_id = -1
						_set_order(UnitState.IDLE)
						_movement.astar_target = Vector3.ZERO
				elif _is_garrisonable_unit() and dist < 4.0:
					# 士兵/农民进驻：距离 < 4
					_do_soldier_garrison(e)
					_garrison_target_id = -1
					_set_order(UnitState.IDLE)
					_movement.astar_target = Vector3.ZERO
				break
			elif e is Army and e.entity_id == 18 and e.get_instance_id() == _garrison_target_id:
				var dist = global_position.distance_to(e.global_position)
				if _is_garrisonable_unit() and dist < 4.0:
					# 攻城车进驻
					_do_soldier_garrison(e)
					_garrison_target_id = -1
					_set_order(UnitState.IDLE)
					_movement.astar_target = Vector3.ZERO
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
	building.set_meta("_orig_melee_armor_%d" % entity_id, building.melee_armor)
	building.set_meta("_orig_shield_armor_%d" % entity_id, building.shield_armor)
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
				building.melee_armor += int(5 * eff)
				building.shield_armor += int(5 * eff)
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
				if building.has_meta("_orig_melee_armor_%d" % entity_id):
					building.melee_armor = building.get_meta("_orig_melee_armor_%d" % entity_id)
					building.shield_armor = building.get_meta("_orig_shield_armor_%d" % entity_id)
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
	_set_order(UnitState.IDLE)
	current_target = null
	attack_move_target = Vector3.ZERO
	_attack_watch_target_id = -1
	_attack_stall_time = 0.0
	_target_validate_timer = 0.0
	if _movement:
		_movement.stop()
	is_attack_moving = false
	# 停止的语义是清空当前行动和后续排队命令。只清路径的话，
	# 下一次 _think 会立刻执行队列里的下一条命令，表现为“点了停止又自己走”。
	_clear_command_queue()

# Override die() for official cleanup
func die_official_cleanup():
	# 沉降动画会让死亡实体多存活 1 秒，清理逻辑只能执行一次，
	# 否则商人会重复扣减市场名额、官员会重复移除光环。
	if _death_cleanup_done:
		return
	_death_cleanup_done = true
	# 爆破船死亡时未爆炸则立即爆炸
	if entity_id == 40 and not _has_exploded:
		_demolition_explode()
		return
	# Cart cleanup
	if entity_id in [5, 6]:
		_clear_cart_owner()
	# 运载船死亡时船上单位也死亡
	if entity_id == 9:
		for u in _boarded_units:
			if is_instance_valid(u): u.health = 0; u.die()
		_boarded_units.clear()
	# Merchant cleanup（油/木/石/粮商人）
	if entity_id in [43, 44, 45, 51]:
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


# ==================== Cart System (手推车/贸易车) ====================

func _process_cart(delta):
	var bm = _get_bm()
	if not bm: return

	var owner = _cart_owner.get_ref() if _cart_owner else null
	if owner and not is_instance_valid(owner):
		_clear_cart_owner()
		owner = null

	match _cart_state:
		CartState.IDLE:
			_cart_search_timer -= delta
			if _cart_search_timer <= 0:
				_cart_search_timer = 1.0
				var new_owner = _find_cart_owner()
				if new_owner:
					_cart_owner = weakref(new_owner)
					new_owner.set_meta("_has_cart", get_instance_id())
					_cart_state = CartState.CHASING

		CartState.CHASING:
			if not owner:
				_cart_state = CartState.IDLE
				return
			var dist = global_position.distance_to(owner.global_position)
			if dist < 3.0:
				_cart_state = CartState.FOLLOWING
			else:
				var chase_speed = owner.speed * CART_CHASE_SPEED_MULT
				var dir = (owner.global_position - global_position).normalized()
				global_position += dir * chase_speed * delta
				look_at(Vector3(owner.global_position.x, global_position.y, owner.global_position.z), Vector3.UP)
				_apply_cart_buff(owner)

		CartState.FOLLOWING:
			if not owner:
				_cart_state = CartState.IDLE
				return
			# Godot 单位前方是 -Z：rotation.y 后的前方向为 (-sin, 0, -cos)，
			# 取反即正后方 (sin, 0, cos)。旧代码用的是 (-cos, 0, sin)，实际是左侧。
			var back_dir := Vector3(sin(owner.rotation.y), 0, cos(owner.rotation.y))
			var target_pos = owner.global_position + back_dir * CART_FOLLOW_DIST
			target_pos.y = global_position.y
			global_position = global_position.lerp(target_pos, min(delta * 3.0, 1.0))
			rotation.y = owner.rotation.y 
			_apply_cart_buff(owner)

func _find_cart_owner() -> GameEntity:
	var bm = _get_bm()
	if not bm: return null
	var best: GameEntity = null
	var best_dist = 10.0
	var my_team = team
	for e in bm.entities.get_children():
		if not (e is Army) or e.health <= 0 or e.team != my_team: continue
		if e.has_meta("_has_cart"): continue
		if entity_id == 5:
			if e.entity_id != 10: continue
		elif entity_id == 6:
			if e.entity_id not in [43, 44, 45, 51]: continue
		var d = global_position.distance_to(e.global_position)
		if d < best_dist:
			best_dist = d
			best = e
	return best

func _apply_cart_buff(owner):
	if not is_instance_valid(owner): return
	if entity_id == 5 and owner.entity_id == 10:
		if not owner.has_meta("_cart_orig_speed"):
			owner.set_meta("_cart_orig_speed", owner.speed)
			owner.set_meta("_cart_orig_max_cargo", owner.max_cargo)
		owner.speed = owner.get_meta("_cart_orig_speed") * 1.5
		owner.max_cargo = owner.get_meta("_cart_orig_max_cargo") + 50
	elif entity_id == 6 and owner.entity_id in [43, 44, 45, 51]:
		if not owner.has_meta("_cart_orig_speed"):
			owner.set_meta("_cart_orig_speed", owner.speed)
		owner.speed = owner.get_meta("_cart_orig_speed") * 1.5
		if not owner.has_meta("_cart_trade_bonus"):
			owner.set_meta("_cart_trade_bonus", 80)

func _clear_cart_owner():
	var owner = _cart_owner.get_ref() if _cart_owner else null
	if owner and is_instance_valid(owner):
		if owner.has_meta("_cart_orig_speed"):
			owner.speed = owner.get_meta("_cart_orig_speed")
			owner.remove_meta("_cart_orig_speed")
		if owner.has_meta("_cart_orig_max_cargo"):
			owner.max_cargo = owner.get_meta("_cart_orig_max_cargo")
			owner.remove_meta("_cart_orig_max_cargo")
		if owner.has_meta("_cart_trade_bonus"):
			owner.remove_meta("_cart_trade_bonus")
		owner.remove_meta("_has_cart")
	_cart_owner = null
	_cart_state = CartState.IDLE

func die_cart_cleanup():
	_clear_cart_owner()

# ==================== Attack filtering ====================

# owner 感知敌对判定（乱斗 FFA：同国/盟友/中立一律不可攻击；无外交管理器时按队伍）
func _is_hostile_to(entity) -> bool:
	var bm = _get_bm()
	if bm and bm.has_method("is_hostile_to"):
		return bm.is_hostile_to(team, owner_peer_id, entity)
	return entity.team != team and not (entity is WorldResource)

# 修道院生产的单位（僧侣/长老/宗师）：索敌时跳过建筑，只打单位
func _is_monastery_unit() -> bool:
	return entity_id in [55, 56, 57]

# 僧侣：永不攻击敌人，只找友方非建筑单位治疗
func _is_healer() -> bool:
	return entity_id == 55

# 陆军近战：不能攻击水上的海军单位（远程陆军/海军自身不受此限制）
func _is_land_melee() -> bool:
	return not water_capable and attack_range <= 1.0

func _can_attack_target(target: GameEntity) -> bool:
	if not is_instance_valid(target) or target.health <= 0: return false
	# 在运载船/城墙保护下的单位不能直接攻击，必须先把船或城墙打掉
	if target is Army and target.is_immune_to_damage():
		return false
	# 僧侣不参与任何攻击（包括手动指派的敌人目标）
	if _is_healer():
		return false
	# 修道院单位跳过攻击建筑
	if _is_monastery_unit() and target is Building:
		return false
	# 陆军近战够不到水上的海军单位，自动索敌时直接跳过；
	# 远程陆军和海军单位仍可正常攻击。
	if _is_land_melee() and target is Army and target.water_capable:
		return false
	# 近战不能攻击城墙上的敌人（包括炮台）
	if attack_range <= 1.0 and target is not Building:
		var bm = _get_bm()
		if bm:
			var tg = bm.world_to_grid(target.global_position)
			for e in bm.entities.get_children():
				if e is Building and e.entity_id == 27 and e.health > 0:
					var wg = bm.world_to_grid(e.global_position)
					if wg.x == tg.x and wg.y == tg.y: return false
				if e is Building and e.entity_id == 64 and e.health > 0:
					var wg = bm.world_to_grid(e.global_position)
					if wg.x == tg.x and wg.y == tg.y: return false
	# 不在城墙上的单位不能攻击梯子
	if target is Building and target.entity_id == 8:
		var on_wall = _is_unit_on_wall()
		if not on_wall: return false
	# 桥只能被火炮/投石车/巨型投石机/爆破船攻击
	if target is Building and target.entity_id == 7:
		if entity_id not in [16, 17, 40, 59]: return false
	# 爆破船只攻击非动物敌人
	if entity_id == 40:
		var at = target.get("_animal_type") if target is Army else ""
		if at != null and str(at) != "": return false
	return true

func _is_unit_on_wall() -> bool:
	var bm = _get_bm()
	if not bm: return false
	var wall = bm._wall_entity_grid.get(bm.world_to_grid(global_position))
	if wall == null or not is_instance_valid(wall):
		return false
	return wall.health > 0 and wall.build_timer <= 0.0 and wall.team == team

# 单位停在墙格上后不会再走 process_move 的高度平滑，这里补一帧级修正：
# 墙在时抬到墙顶，墙被拆掉后落回地面。只处理已经离地/正在墙格的单位，正常地面单位直接返回。
func _update_wall_height(delta: float) -> void:
	var bm = _get_bm()
	if bm == null or bm._wall_entity_grid.is_empty():
		return
	var map = bm.get_node_or_null("Map")
	if map == null or not map.has_method("get_height_at"):
		return
	var ground_y: float = map.get_height_at(global_position)
	var wall = bm._wall_entity_grid.get(bm.world_to_grid(global_position))
	var on_wall: bool = wall != null and is_instance_valid(wall) and wall.health > 0 and wall.build_timer <= 0.0
	var target_y: float = ground_y
	if on_wall:
		target_y = ground_y + 4.5
	elif global_position.y <= ground_y + 0.8:
		return
	global_position.y = move_toward(global_position.y, target_y, 5.0 * delta)

# 运载船上的单位随船免疫；城墙上的单位随墙免疫。保护物被摧毁后自动失效。
func is_immune_to_damage() -> bool:
	if _boarded_on != -1:
		var transport = instance_from_id(_boarded_on)
		return is_instance_valid(transport) and transport.health > 0
	return _is_unit_on_wall()

# ==================== Garrison System ====================
func _find_nearest_enemy_in_vision():
	return _find_nearest_enemy_near(global_position, vision_range)

# 以任意位置为中心找最近的敌人；驻扎单位用驻扎点做中心，
# 这样即使敌人不在本单位视野内，只要靠近驻扎点也会被发现并清掉。
func _find_nearest_enemy_near(center: Vector3, radius: float):
	var best_dist: float = radius
	var best_target = null
	# 驻扎/守军单位空闲时每 0.3s 都会调用此函数。后期几十上百个守军若每个
	# 都全量扫描 entities，会形成 O(n²) 的主线程热点；优先走空间索引。
	var bm = _get_bm()
	var candidates: Array = bm.get_nearby_enemies(center, radius, team, owner_peer_id) if bm else get_tree().get_nodes_in_group("entities")
	for entity in candidates:
		if entity == self or not is_instance_valid(entity) or entity.health <= 0: continue
		if not (entity is GameEntity): continue
		if entity is WorldResource: continue
		if not _is_hostile_to(entity): continue
		if entity.get("_animal_type") != null and str(entity.get("_animal_type")) != "": continue  # 不自动攻击动物
		if not _can_attack_target(entity): continue
		if _is_target_marked_unreachable(entity): continue
		var h_diff = Vector2(entity.global_position.x - center.x, entity.global_position.z - center.z)
		var dist = h_diff.length() - body_radius - entity.body_radius
		if dist <= attack_range:
			# 射程内敌人已经是“最近”的可攻击目标，直接返回，避免在密集人群里
			# 为一次重选目标遍历几十上百个候选。
			return entity
		if dist <= radius and dist < best_dist:
			best_dist = dist
			best_target = entity
	return best_target

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
		var is_fish = (_animal_type == "fish")
		var bm = get_tree().get_first_node_in_group("battle_manager")
		for angle_offset in [0, 45, -45, 90, -90, 135, -135, 180]:
			var test_dir = flee_dir.rotated(Vector3.UP, deg_to_rad(angle_offset))
			var new_pos = global_position + test_dir * flee_speed * delta
			if bm:
				var t = bm.get_terrain_at(new_pos)
				if (is_fish and t == 2) or (not is_fish and t != 2):
					global_position = new_pos; return
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
	if baby != null and is_instance_valid(baby) and baby is Army:
		baby.level = 1
		baby._animal_grow_timer = 20.0
		baby.max_health = int(max_health * 0.4)
		baby.health = baby.max_health
		baby.attack = max(1, int(attack * 0.4))
		baby.speed = speed * 0.8
		baby._animal_food_reward = int(_animal_food_reward * 0.4)

# ==================== Demolition Ship ====================
func _process_demolition(delta):
	if _has_exploded: return
	# 正常陆军逻辑：追赶目标
	var bm = _get_bm()
	if not bm: return
	if current_target and is_instance_valid(current_target) and _can_attack_target(current_target):
		var dist = global_position.distance_to(current_target.global_position) - body_radius - current_target.body_radius
		if dist <= attack_range:
			_demolition_explode()
		else:
			_movement.set_move_target(current_target.global_position, attack_range)
			_movement.process_move(delta, bm)
	elif is_attack_moving and attack_move_target != Vector3.ZERO:
		if global_position.distance_to(attack_move_target) < 1.0:
			is_attack_moving = false; attack_move_target = Vector3.ZERO
		else:
			_movement.set_move_target(attack_move_target)
			_movement.process_move(delta, bm)
	elif _order_is(UnitState.MOVING):
		# 爆破船也需要响应玩家右键移动，不能只处理攻击/攻击移动
		_movement.process_move(delta, bm)
	else:
		_find_enemy_in_range()

func _demolition_explode():
	if _has_exploded: return
	_has_exploded = true
	_play_sfx_if_visible("cannon_hit")
	_spawn_demolition_blast()
	var bm = _get_bm()
	if bm:
		for e in bm.entities.get_children():
			if not (e is GameEntity) or e == self or e.health <= 0:
				continue
			# 爆炸只伤害真正的敌方军队/建筑：不误伤盟友、中立资源、动物
			if not (e is Army or e is Building):
				continue
			var hostile: bool = false
			if bm.has_method("is_hostile_to"):
				hostile = bm.is_hostile_to(team, owner_peer_id, e)
			else:
				hostile = e.team != team and e.team != RTSConfig.Team.NEUTRAL
			if not hostile:
				continue
			if not _can_attack_target(e):
				continue
			var d = global_position.distance_to(e.global_position) - e.body_radius
			if d <= damage_radius:
				e.take_damage(attack, self)
	die()

# 简单的爆炸球特效；不依赖外部资源，避免爆破船只有音效没有视觉反馈
func _spawn_demolition_blast():
	var bm = _get_bm()
	if bm == null:
		return
	var marker = MeshInstance3D.new()
	var sphere = SphereMesh.new()
	sphere.radius = maxf(damage_radius * 0.65, 1.0)
	sphere.height = sphere.radius * 2.0
	marker.mesh = sphere
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.35, 0.05, 0.65)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	marker.material_override = mat
	bm.add_child(marker)
	marker.global_position = global_position + Vector3(0, 1.0, 0)
	var t = Timer.new()
	t.one_shot = true
	t.wait_time = 0.35
	t.timeout.connect(marker.queue_free)
	marker.add_child(t)
	t.start()

# ==================== Transport Ship ====================
const BOARD_CAPACITY: int = 8  # 运载船最大载员

func get_board_capacity() -> int:
	return BOARD_CAPACITY

func _process_transport(delta):
	var bm = _get_bm()
	if not bm: return
	# 移动逻辑
	_movement.process_move(delta, bm)
	# 更新登船单位位置
	for u in _boarded_units:
		if is_instance_valid(u):
			u.global_position = global_position

func board_unit(unit):
	if unit == null or not is_instance_valid(unit):
		return
	# 水上单位（战船/渔船/爆破船等）不能上运载船，只有陆地单位能上
	if bool(unit.get("water_capable")):
		return
	if _boarded_units.size() >= BOARD_CAPACITY: return
	_boarded_units.append(unit)
	unit.visible = false
	unit.collision_layer = 0
	unit.set_meta("_boarded_on", get_instance_id())
	if unit is Army: unit._boarded_on = get_instance_id()

func unboard_at(pos: Vector3):
	for u in _boarded_units:
		if is_instance_valid(u):
			u.global_position = pos + Vector3(randf_range(-2,2), 0, randf_range(-2,2))
			u.visible = true
			u.collision_layer = 1
			u.remove_meta("_boarded_on")
			if u is Army: u._boarded_on = -1
	_boarded_units.clear()

func get_boarded_count() -> int:
	return _boarded_units.size()

func _adult_grow():
	_animal_grow_timer = 0.0
	var cfg = EntityDatabase.get_config(entity_id)
	if not cfg.is_empty():
		max_health = cfg.get("max_health", max_health)
		health = max_health
		attack = cfg.get("attack", attack)
		_animal_food_reward = cfg.get("food_reward", _animal_food_reward)

# ==================== 士兵/农民进驻系统 ====================
func _is_garrisonable_unit() -> bool:
	# 水军不能进驻，官员用独立系统
	if entity_id in [9, 13, 14, 39, 40]: return false  # 船
	if entity_id >= 46 and entity_id <= 50: return false  # 官员
	return entity_id == 10 or target_type > 0  # 农民或战斗单位

func can_soldier_garrison(target) -> bool:
	if not is_instance_valid(target): return false
	if not _is_garrisonable_unit(): return false
	if _soldier_garrison_building and _soldier_garrison_building.get_ref(): return false
	if target is Building:
		return target.can_garrison_soldier() if target.has_method("can_garrison_soldier") else false
	if target is Army and target.entity_id == 18:
		return target._ram_garrisoned_soldiers.size() < 5
	return false

func _do_soldier_garrison(target):
	if not is_instance_valid(target): return
	if target is Building:
		if not target._add_soldier_to_garrison(self): return
		_soldier_garrison_building = weakref(target)
		if not target.died.is_connected(_on_soldier_garrison_building_died):
			target.died.connect(_on_soldier_garrison_building_died.bind(get_instance_id()))
	elif target is Army and target.entity_id == 18:
		_soldier_garrison_building = weakref(target)
		target._ram_garrisoned_soldiers.append(get_instance_id())
		if not target.died.is_connected(_on_soldier_garrison_building_died):
			target.died.connect(_on_soldier_garrison_building_died.bind(get_instance_id()))
		target._recalc_ram_garrison_bonus()
	else:
		return
	visible = false
	collision_layer = 0
	stop_movement()
	current_target = null
	current_order = ""

func _exit_soldier_garrison():
	var target = _soldier_garrison_building.get_ref() if _soldier_garrison_building else null
	if not target or not is_instance_valid(target):
		_soldier_garrison_building = null
		visible = true
		collision_layer = 1
		return
	if target is Building:
		target._remove_soldier_from_garrison(self)
	elif target is Army and target.entity_id == 18:
		if target.has_method("_recalc_ram_garrison_bonus"):
			var my_id = get_instance_id()
			target._ram_garrisoned_soldiers.erase(my_id)
			target._recalc_ram_garrison_bonus()
	visible = true
	collision_layer = 1
	_soldier_garrison_building = null

func _on_soldier_garrison_building_died(my_id: int):
	if _soldier_garrison_building:
		var target = _soldier_garrison_building.get_ref()
		if target and target.died.is_connected(_on_soldier_garrison_building_died):
			target.died.disconnect(_on_soldier_garrison_building_died)
	_soldier_garrison_building = null
	visible = true
	collision_layer = 1
	# 释放到附近随机位置
	var bm = _get_bm()
	var map = bm.get_node_or_null("Map") if bm else null
	for _attempt in range(20):
		var angle = randf() * TAU
		var pos = global_position + Vector3(cos(angle) * 2, 0, sin(angle) * 2)
		if map and map.has_method("get_terrain_at"):
			if map.get_terrain_at(pos) == 0:
				global_position = pos
				break

# ==================== 攻城车进驻（攻速/移速加成） ====================
func _recalc_ram_garrison_bonus():
	if entity_id != 18: return
	var cnt = _ram_garrisoned_soldiers.size()
	if cnt == 0:
		if _base_attack_speed > 0:
			attack_speed = _base_attack_speed
			_base_attack_speed = 0.0
		if _base_speed > 0:
			speed = _base_speed
			_base_speed = 0.0
		return
	if _base_attack_speed <= 0:
		_base_attack_speed = attack_speed
	if _base_speed <= 0:
		_base_speed = speed
	var bonus = 1.0 + 0.05 * cnt
	attack_speed = _base_attack_speed * bonus
	speed = _base_speed * bonus

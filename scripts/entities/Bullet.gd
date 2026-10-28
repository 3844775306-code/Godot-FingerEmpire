# scripts/entities/Bullet.gd
class_name Bullet
extends Area3D

var team: int
var owner_peer_id: int = -1   # 发射方 owner_peer_id（乱斗 FFA 溅射/命中按 owner 过滤敌对）
var damage: float
var speed: float = 6.0
var target: GameEntity = null
var source: GameEntity = null
var source_entity_id: int = -1   # 发射方 entity_id（创建时缓存，供联机快照还原弹丸模型）
var damage_radius: float = 0.0
var attack_type: int = 1          # 1=普通, 2=电击, 3=冰冻, 4=灼烧
var time_alive: float = 0.0
var max_lifetime: float = 10.0
var hit: bool = false
var target_pos: Vector3 = Vector3.ZERO   # 固定目标点（非追踪模式）
var _saved_dir: Vector3 = Vector3.ZERO
var _pool_key: String = ""                # 对象池键；由 BattleManager 设置

# 抛物线弹道：炮弹、投石车巨石等重弹走抛物线，箭矢保持直线飞行。
# _arc_span 是发射时到目标的水平距离，用来把水平飞行进度映射成抛物线参数 t。
var _arc_active: bool = false
var _arc_start: Vector3 = Vector3.ZERO
var _arc_span: float = 1.0
var _arc_apex: float = 1.0
var _prev_pos: Vector3 = Vector3.ZERO
const BALLISTIC_HIT_RADIUS: float = 0.45
# 弹丸绕障：路径上有建筑/山体时抬高抛物线，尽量避免从模型内部穿过去。
# 检查按固定间隔做，避免每帧对每发箭都扫一遍建筑格。
const OBSTACLE_CLEARANCE: float = 0.32
const OBSTACLE_CHECK_INTERVAL: float = 0.12
const MAX_ARC_APEX: float = 16.0
var _obstacle_timer: float = 0.0
var _avoidance_checked: bool = false

# 箭矢命中后不立即消失：插在目标身上保留一段时间，让中箭有个明确的视觉反馈。
const ARROW_STICK_TIME: float = 1.5
var _stuck_to: Node3D = null          # 命中后箭矢附着的目标
var _stuck_offset: Vector3 = Vector3.ZERO  # 命中瞬间相对目标的偏移，跟着目标一起动
var _stuck_timer: float = 0.0
# 石头类弹丸（投石车 17、巨型投石机 59）：保留原线性衰减，
# 落点中心 100%，向外线性衰减到 damage_radius 边缘的 0。
const STONE_SOURCE_IDS: Array[int] = [17, 59]
const STONE_CENTER_MULT: float = 1.0
const STONE_EDGE_MULT: float = 0.0
# 其它炮弹类弹丸：锁定目标承受 100%，溅射范围内其它目标只承受 30%。
const SPLASH_DAMAGE_MULT: float = 0.3
# 科研模式 F9 加长炮管：炮弹溅射倍率由发射者携带，0 = 沿用默认 30%。
var splash_damage_mult: float = 0.0

# 弹丸模型缓存：后期每秒会生成几十到上百发子弹，不能每发都做
# ResourceLoader.exists + load + GLB 实例化。PackedScene 只加载一次，之后只 instantiate。
static var _scene_cache: Dictionary = {}
static func _cached_scene(path: String) -> PackedScene:
	if _scene_cache.has(path):
		return _scene_cache[path] as PackedScene
	var ps: PackedScene = load(path) if ResourceLoader.exists(path) else null
	_scene_cache[path] = ps
	return ps

# 只有炮弹/巨石这一类推重弹走抛物线；弓箭、弩矢无论配置是否带溅射都保持直线。
# 弓手 12/31/33/37/58、箭塔 25、战船 13 是箭矢来源，显式排除。
func _is_ballistic_projectile() -> bool:
	if source_entity_id in [12, 13, 25, 31, 33, 37, 58]:
		return false
	# 只有石头类（投石车 17、巨型投石机 59）走抛物线；
	# 火炮 16、炮塔 26、炮艇 39、炮台 64 的炮弹一律直射
	return source_entity_id in [17, 59]

func _reset_ballistic_state() -> void:
	_arc_active = false
	_arc_start = Vector3.ZERO
	_arc_span = 1.0
	_arc_apex = 1.0
	_prev_pos = Vector3.ZERO
	_obstacle_timer = 0.0
	_avoidance_checked = false

# 弓箭类弹丸：命中后要插在目标身上。弓手 12/31/33/37/58、箭塔 25、战船 13。
func _is_arrow_bullet() -> bool:
	return source_entity_id in [12, 13, 25, 31, 33, 37, 58]

# 投石车/巨型投石机保留距离线性衰减；其它炮弹类只让直击目标吃满伤害，
# 其余溅射目标固定 30%。普通箭矢 damage_radius=0，仍由命中目标承受 100%。
func _damage_multiplier(dist: float, is_primary: bool) -> float:
	if source_entity_id in STONE_SOURCE_IDS:
		var t: float = clampf(dist / maxf(damage_radius, 0.01), 0.0, 1.0)
		return lerpf(STONE_CENTER_MULT, STONE_EDGE_MULT, t)
	return 1.0 if is_primary else (splash_damage_mult if splash_damage_mult > 0.0 else SPLASH_DAMAGE_MULT)

# AOE 伤害入口：石头弹丸按距离衰减，其它炮弹的溅射目标固定 30%。
func _deal_aoe_damage(entity: GameEntity, src: GameEntity, dist: float,
		is_primary: bool = false) -> void:
	var mult := _damage_multiplier(dist, is_primary)
	if mult <= 0.0:
		return
	entity.take_damage(damage * mult, src)

# 炮弹与巨石的命中特效：一次性尘土/碎屑爆发，节点播完自行销毁
func _spawn_impact_effect(pos: Vector3, big: bool) -> void:
	var bm = _get_bm()
	var parent: Node3D = bm as Node3D
	if parent == null:
		parent = get_tree().current_scene as Node3D
	if parent == null:
		return
	# 统一用 position 而不是 global_position：父节点（战斗管理器 / 场景根）就在原点，
	# 局部坐标即世界坐标；而在 add_child 的同一帧设置 global_position 会依赖父级的
	# transform 缓存，粒子常常全在原点（地图正中央）发射。
	# ── 1) 碎屑粒子：往外炸开的不规则小石块 ──
	# 逼真感来自三点：碎块形状不规则（方块而不是圆球）、飞行中翻滚（角速度）、
	# 尺寸随存活时间收缩（scale_amount_curve），单靠多个圆球会像"气泡"。
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.amount = 24 if big else 16
	p.lifetime = 0.8
	p.explosiveness = 1.0
	p.direction = Vector3.UP
	p.spread = 180.0
	p.initial_velocity_min = 2.5
	p.initial_velocity_max = 7.0 if big else 5.0
	p.gravity = Vector3(0.0, -14.0, 0.0)
	p.angle_min = 0.0
	p.angle_max = 360.0
	# 碎片翻滚：角速度范围越大，看起来越像被炸飞的石块
	p.angular_velocity_min = -540.0
	p.angular_velocity_max = 540.0
	p.scale_amount_min = 1.0
	p.scale_amount_max = 1.5 if big else 1.25
	# 尺寸随生命期收缩：飞出去的同时变小，避免像悬浮的方块
	var size_curve := Curve.new()
	size_curve.add_point(Vector2(0.0, 1.0))
	size_curve.add_point(Vector2(0.55, 0.85))
	size_curve.add_point(Vector2(1.0, 0.2))
	p.scale_amount_curve = size_curve
	var mesh := BoxMesh.new()
	# 注意：scale_amount 是相对网格尺寸的倍率，不是绝对大小。
	# 长宽高不一致，碎片才不会是统一的立方体。
	mesh.size = Vector3(0.17, 0.11, 0.21) if big else Vector3(0.11, 0.08, 0.14)
	var mat := StandardMaterial3D.new()
	if big:
		# 石头：浅灰色碎块，受光照影响才能看出棱角；略加自发光避免阴影里全黑
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		mat.albedo_color = Color(0.80, 0.79, 0.74)
		mat.emission_enabled = true
		mat.emission = Color(0.3, 0.3, 0.3)
		mat.emission_energy_multiplier = 0.35
	else:
		# 炮弹：深灰近黑的火药碎屑；受光照影响，暗处自然不会发亮
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		mat.albedo_color = Color(0.10, 0.10, 0.11)
		mat.emission_enabled = false
	mesh.material = mat
	p.mesh = mesh
	# 初始颜色在灰阶范围内随机，碎块深浅不一
	var shard_grad := Gradient.new()
	if big:
		shard_grad.set_color(0, Color(0.88, 0.87, 0.82))
		shard_grad.set_color(1, Color(0.62, 0.60, 0.55))
	else:
		shard_grad.set_color(0, Color(0.16, 0.16, 0.17))
		shard_grad.set_color(1, Color(0.05, 0.05, 0.06))
	p.color_initial_ramp = shard_grad
	# 顺序很关键：先设好 position 再 add_child，并且延迟一帧才开始发射。
	# CPUParticles3D 在同一帧里 transform 还没同步，直接用 emitting = true
	# 会用旧位置（原点，也就是地图正中央）发射第一批粒子。
	p.position = pos
	parent.add_child(p)
	p.set_deferred("emitting", true)
	get_tree().create_timer(1.4, false).timeout.connect(func():
		if is_instance_valid(p):
			p.queue_free())

	# ── 1b) 扬尘：一团膨胀后淡出的灰雾，是"砸出坑"的关键观感 ──
	var dust := CPUParticles3D.new()
	dust.one_shot = true
	dust.amount = 9 if big else 6
	dust.lifetime = 1.1
	dust.explosiveness = 1.0
	dust.direction = Vector3.UP
	dust.spread = 180.0
	dust.initial_velocity_min = 0.5
	dust.initial_velocity_max = 1.8
	# 烟往上飘，重力取正值
	dust.gravity = Vector3(0.0, 0.8, 0.0)
	dust.scale_amount_min = 1.0
	dust.scale_amount_max = 1.8
	var dust_curve := Curve.new()
	dust_curve.add_point(Vector2(0.0, 0.45))
	dust_curve.add_point(Vector2(1.0, 1.6))
	dust.scale_amount_curve = dust_curve
	var dmesh := SphereMesh.new()
	dmesh.radius = 0.34 if big else 0.26
	dmesh.height = 0.68 if big else 0.52
	var dmat := StandardMaterial3D.new()
	dmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dmat.albedo_color = Color(0.74, 0.73, 0.68, 1.0) if big else Color(0.42, 0.41, 0.40, 1.0)
	dmesh.material = dmat
	dust.mesh = dmesh
	# 生命周期内从半透明淡出到完全消失
	var dust_grad := Gradient.new()
	dust_grad.set_color(0, Color(1.0, 1.0, 1.0, 0.45))
	dust_grad.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
	dust.color_ramp = dust_grad
	dust.position = pos
	parent.add_child(dust)
	dust.set_deferred("emitting", true)
	get_tree().create_timer(1.6, false).timeout.connect(func():
		if is_instance_valid(dust):
			dust.queue_free())

	# ── 1c) 火星：只有炮弹有，亮橙色高速小点，模拟火药爆燃 ──
	if not big:
		var spark := CPUParticles3D.new()
		spark.one_shot = true
		spark.amount = 10
		spark.lifetime = 0.38
		spark.explosiveness = 1.0
		spark.direction = Vector3.UP
		spark.spread = 180.0
		spark.initial_velocity_min = 3.5
		spark.initial_velocity_max = 8.0
		spark.gravity = Vector3(0.0, -20.0, 0.0)
		spark.scale_amount_min = 1.0
		spark.scale_amount_max = 1.4
		var smesh := SphereMesh.new()
		smesh.radius = 0.045
		smesh.height = 0.09
		var smat := StandardMaterial3D.new()
		smat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		smat.albedo_color = Color(1.0, 0.72, 0.32)
		smat.emission_enabled = true
		smat.emission = Color(1.0, 0.55, 0.18)
		smat.emission_energy_multiplier = 3.0
		smesh.material = smat
		spark.mesh = smesh
		var spark_grad := Gradient.new()
		spark_grad.set_color(0, Color(1.0, 0.85, 0.5, 1.0))
		spark_grad.set_color(1, Color(0.85, 0.25, 0.05, 0.0))
		spark.color_ramp = spark_grad
		spark.position = pos
		parent.add_child(spark)
		spark.set_deferred("emitting", true)
		get_tree().create_timer(1.0, false).timeout.connect(func():
			if is_instance_valid(spark):
				spark.queue_free())

	# ── 2) 闪光球：命中瞬间炸亮一下再迅速缩掉，是最直观的"打中了"反馈 ──
	var flash := MeshInstance3D.new()
	var fmesh := SphereMesh.new()
	fmesh.radius = 0.32 if big else 0.22
	fmesh.height = 0.64 if big else 0.44
	var fmat := StandardMaterial3D.new()
	fmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fmat.albedo_color = Color(1.0, 0.92, 0.7, 0.85)
	fmat.emission_enabled = true
	fmat.emission = Color(1.0, 0.7, 0.3)
	fmat.emission_energy_multiplier = 5.0
	fmesh.material = fmat
	flash.mesh = fmesh
	flash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	flash.position = pos
	parent.add_child(flash)
	var ftw := flash.create_tween()
	ftw.set_parallel(true)
	ftw.tween_property(flash, "scale", Vector3(2.2, 2.2, 2.2), 0.22) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	ftw.tween_property(fmat, "albedo_color:a", 0.0, 0.28)
	ftw.chain().tween_callback(func():
		if is_instance_valid(flash):
			flash.queue_free())

	# ── 3) 地面冲击环：贴着地面向外扩散的一圈亮边 ──
	var ring := MeshInstance3D.new()
	var rmesh := TorusMesh.new()
	rmesh.inner_radius = 0.30
	rmesh.outer_radius = 0.45
	var rmat := StandardMaterial3D.new()
	rmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	rmat.albedo_color = Color(1.0, 0.8, 0.45, 0.8)
	rmat.emission_enabled = true
	rmat.emission = Color(1.0, 0.72, 0.35)
	rmat.emission_energy_multiplier = 2.5
	rmesh.material = rmat
	ring.mesh = rmesh
	# TorusMesh 默认就平躺在 XZ 平面上（环轴朝上），不要再绕 X 轴旋转，
	# 否则冲击环会立起来变成竖直的一圈。
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ring.position = Vector3(pos.x, pos.y + 0.06, pos.z)
	parent.add_child(ring)
	var rtw := ring.create_tween()
	rtw.set_parallel(true)
	rtw.tween_property(ring, "scale", Vector3(3.2 if big else 2.2, 1.0, 3.2 if big else 2.2), 0.4) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	rtw.tween_property(rmat, "albedo_color:a", 0.0, 0.45)
	rtw.chain().tween_callback(func():
		if is_instance_valid(ring):
			ring.queue_free())

	# ── 4) 点光源：短暂照亮周围，阴暗地形/逆光下也能看清 ──
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.75, 0.4)
	light.light_energy = 6.0 if big else 3.5
	light.omni_range = 6.0 if big else 4.0
	light.position = pos + Vector3.UP * 0.5
	parent.add_child(light)
	var ltw := light.create_tween()
	ltw.tween_property(light, "light_energy", 0.0, 0.3)
	ltw.chain().tween_callback(func():
		if is_instance_valid(light):
			light.queue_free())

func _ready():
	add_to_group("bullets")
	# 弹丸命中由 _physics_process 里的空间索引查询判定，不依赖物理碰撞信号。
	# 关闭 Area3D 的物理监测，避免大量弹丸每帧进入物理 broadphase。
	monitoring = false
	monitorable = false
	collision_layer = 0
	collision_mask = 0
	# 快照序列化时 source 可能已被销毁，创建时先缓存发射方 entity_id
	var source_valid: bool = source != null and is_instance_valid(source)
	var source_id: int = int(source.entity_id) if source_valid else -1
	if source_valid:
		source_entity_id = source_id
	if damage_radius > 0 or source_id in [16,17,26,39]:
		# 投石车/巨型投石机用巨石
		if source_id in [17, 59]:
			var boulder = _cached_scene("res://models/defense/weapon-ammo-boulder.glb")
			if boulder:
				var s = boulder.instantiate()
				if s:
					s.scale = Vector3.ONE * (3.5 if source_id == 59 else 2.5)
					add_child(s)
			else:
				var cannon_fallback = _cached_scene("res://models/pirate/cannon-ball.glb")
				if cannon_fallback:
					var cf = cannon_fallback.instantiate()
					if cf: add_child(cf)
		else:
			var cannon = _cached_scene("res://models/pirate/cannon-ball.glb")
			if cannon:
				var c = cannon.instantiate()
				if c: add_child(c)
	else:
		var arrow_scene = _cached_scene("res://models/forest/weapon-arrow.glb")
		if arrow_scene:
			var arrow = arrow_scene.instantiate()
			# 模型自身箭头朝向与飞行方向相反，绕 Y 轴掉头 180°
			if arrow:
				arrow.scale = Vector3.ONE
				arrow.rotation.y = deg_to_rad(180)
				add_child(arrow)
	if get_child_count() == 0:
		var mesh = MeshInstance3D.new()
		var sphere = SphereMesh.new()
		sphere.radius = 0.25
		mesh.mesh = sphere
		add_child(mesh)
		var mat = StandardMaterial3D.new()
		mat.albedo_color = Color.RED if team == 0 else Color.BLUE
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mesh.set_surface_override_material(0, mat)

	var col_shape = CollisionShape3D.new()
	col_shape.shape = SphereShape3D.new()
	col_shape.shape.radius = 0.15
	add_child(col_shape)

func reset_for_reuse(new_source, p_damage_radius: float, p_team: int, p_key: String) -> void:
	source = new_source
	if new_source != null and is_instance_valid(new_source):
		source_entity_id = int(new_source.entity_id)
	else:
		source_entity_id = -1
	damage_radius = p_damage_radius
	splash_damage_mult = float(new_source.get("splash_damage_mult")) if new_source != null and is_instance_valid(new_source) else 0.0
	team = p_team
	_pool_key = p_key
	target = null
	target_pos = Vector3.ZERO
	_saved_dir = Vector3.ZERO
	hit = false
	_stuck_to = null
	_stuck_offset = Vector3.ZERO
	_stuck_timer = 0.0
	time_alive = 0.0
	attack_type = 1
	rotation = Vector3.ZERO
	visible = true
	_reset_ballistic_state()
	if not is_in_group("bullets"):
		add_to_group("bullets")
	set_physics_process(true)

func recycle() -> void:
	if not is_inside_tree():
		queue_free()
		return
	hit = true
	visible = false
	set_physics_process(false)
	_stuck_to = null
	_stuck_offset = Vector3.ZERO
	_stuck_timer = 0.0
	target = null
	source = null
	source_entity_id = -1
	target_pos = Vector3.ZERO
	_saved_dir = Vector3.ZERO
	time_alive = 0.0
	_reset_ballistic_state()
	remove_from_group("bullets")
	var bm = _get_bm()
	if bm and bm.has_method("recycle_bullet"):
		bm.recycle_bullet(self)
	else:
		queue_free()

var _cached_bm = null

func _get_bm():
	if not is_instance_valid(_cached_bm):
		_cached_bm = get_tree().get_first_node_in_group("battle_manager")
	return _cached_bm

func _start_arc(goal: Vector3, required_apex: float = -1.0) -> void:
	_arc_active = true
	_arc_start = global_position
	var flat_vec := Vector3(goal.x - _arc_start.x, 0.0, goal.z - _arc_start.z)
	_arc_span = maxf(flat_vec.length(), 0.5)
	if required_apex < 0.0:
		required_apex = _required_arc_apex(goal)
	# 巨石比炮弹抛得更高；限制顶点高度，避免远程弹道飞出画面。
	var apex_ratio: float = 0.42 if source_entity_id in [17, 59] else 0.30
	var base_apex: float = clampf(_arc_span * apex_ratio, 0.9, 6.0)
	_arc_apex = clampf(maxf(base_apex, required_apex), 0.9, MAX_ARC_APEX)
	_prev_pos = global_position

# 沿“起点到目标”的直线采样地形和建筑顶，算出抛物线至少要多高才能不穿模。
# 距离起点/终点太近的采样跳过：那是发射者脚下或目标身上的建筑。
func _required_arc_apex(goal: Vector3) -> float:
	var bm = _get_bm()
	if bm == null or not bm.has_method("get_projectile_obstacle_height"):
		return 0.0
	var start_pos: Vector3 = _arc_start if _arc_active else global_position
	var flat_span := Vector2(goal.x - start_pos.x, goal.z - start_pos.z).length()
	if flat_span < 1.0:
		return 0.0
	var samples: int = clampi(int(flat_span / 3.0), 3, 10)
	var goal_clear: float = _goal_obstacle_clearance()
	var apex: float = 0.0
	for i in range(1, samples):
		var t := float(i) / float(samples)
		if t > 0.92:
			break
		var sample := start_pos.lerp(goal, t)
		if sample.distance_to(start_pos) < 1.5 or sample.distance_to(goal) < goal_clear:
			continue
		var obstacle_top: float = bm.get_projectile_obstacle_height(
			sample, 0.3
		)
		if obstacle_top <= -100000.0:
			continue
		var base_y: float = start_pos.y + (goal.y - start_pos.y) * t
		var needed_y: float = obstacle_top + OBSTACLE_CLEARANCE
		if needed_y <= base_y:
			continue
		var denom: float = 4.0 * t * (1.0 - t)
		if denom < 0.05:
			continue
		apex = maxf(apex, (needed_y - base_y) / denom)
	return apex

# 目标自身（尤其是主城/城堡）的模型半径可能大于 2 米；靠近终点的采样要按
# 目标体型放宽，否则弹丸会把“目标建筑本人的外墙”当成路障而提前消失。
func _goal_obstacle_clearance() -> float:
	if target is Building:
		return maxf(2.0, float(target.body_radius) + 0.8)
	return 2.0

# 当前这一步是否会撞进建筑/山体。只查中点：检查间隔 0.12s，8m/s 的箭也只前进
# 不到 1 米，建筑/城墙直径普遍在 2 米以上，不会被整段跨过去。
func _segment_hits_obstacle(from_pos: Vector3, to_pos: Vector3, goal: Vector3) -> bool:
	var bm = _get_bm()
	if bm == null or not bm.has_method("get_projectile_obstacle_height"):
		return false
	var point := from_pos.lerp(to_pos, 0.5)
	if point.distance_to(goal) < _goal_obstacle_clearance():
		return false
	var obstacle_top: float = bm.get_projectile_obstacle_height(
		point, 0.25
	)
	if obstacle_top <= -100000.0:
		return false
	return point.y < obstacle_top + OBSTACLE_CLEARANCE

# 只有投石车/巨型投石机需要预先计算绕障抛物线。普通箭矢和直射炮弹保持直线，
# 由 _segment_hits_obstacle 在撞上建筑/山体时停止；这样不会给每发箭都做路径采样。
func _maybe_start_avoidance_arc(goal: Vector3) -> void:
	if _arc_active or _avoidance_checked:
		return
	_avoidance_checked = true
	if _is_ballistic_projectile():
		_start_arc(goal)

# 弹丸撞到路径上的建筑/山体：只播放落点特效并回收，不对障碍物造成伤害，
# 避免自动索敌/普通箭矢意外拆建筑；真正命中目标仍走 _on_hit/_on_hit_pos。
func _on_obstacle_hit() -> void:
	if hit:
		return
	hit = true
	if damage_radius > 0.0:
		_spawn_impact_effect(global_position, source_entity_id in STONE_SOURCE_IDS)
	recycle()

# 水平方向匀速逼近目标，竖直方向按抛物线偏移。
# 返回当前到目标的水平距离，供命中判定使用。
func _step_ballistic(goal: Vector3, delta: float) -> float:
	var flat_vec := Vector3(goal.x - global_position.x, 0.0, goal.z - global_position.z)
	var flat_dist := flat_vec.length()
	if flat_dist > 0.0001:
		var step := minf(speed * delta, flat_dist)
		global_position += flat_vec / flat_dist * step
	var remaining := Vector3(goal.x - global_position.x, 0.0, goal.z - global_position.z).length()
	var t := 1.0 - clampf(remaining / _arc_span, 0.0, 1.0)
	global_position.y = _arc_start.y + (goal.y - _arc_start.y) * t + 4.0 * _arc_apex * t * (1.0 - t)
	if _prev_pos != Vector3.ZERO:
		var flight_dir := global_position - _prev_pos
		if flight_dir.length_squared() > 0.000001:
			_orient_to_dir(flight_dir)
	_prev_pos = global_position
	return remaining

func _physics_process(delta):
	if hit:
		# 箭矢命中后插在目标身上：跟着目标移动，到时间再回收
		if _stuck_to != null:
			if is_instance_valid(_stuck_to):
				global_position = _stuck_to.global_position + _stuck_offset
			_stuck_timer -= delta
			if _stuck_timer <= 0.0 or not is_instance_valid(_stuck_to):
				recycle()
		else:
			# 没有附着目标的异常路径也不能让弹丸永久留在场上
			recycle()
		return
	time_alive += delta
	if time_alive > max_lifetime:
		recycle()
		return

	# 固定目标点模式（投石车/巨型投石机）：飞向固定位置
	var check_obstacles := false
	_obstacle_timer -= delta
	if _obstacle_timer <= 0.0:
		_obstacle_timer = OBSTACLE_CHECK_INTERVAL
		check_obstacles = true
	if target_pos != Vector3.ZERO:
		_maybe_start_avoidance_arc(target_pos)
		if _arc_active:
			var prev := global_position
			var remaining := _step_ballistic(target_pos, delta)
			if check_obstacles and _segment_hits_obstacle(prev, global_position, target_pos):
				_on_obstacle_hit()
				return
			if remaining < BALLISTIC_HIT_RADIUS:
				global_position = target_pos
				_on_hit_pos()
		else:
			if _saved_dir == Vector3.ZERO:
				_saved_dir = (target_pos - global_position).normalized()
			var next_pos: Vector3 = global_position + _saved_dir * speed * delta
			if check_obstacles and _segment_hits_obstacle(global_position, next_pos, target_pos):
				_on_obstacle_hit()
				return
			global_position = next_pos
			_orient_to_dir(_saved_dir)
			# 到达目标点 → 原目标 100% 直击，周围敌人 30% 溅射
			if global_position.distance_to(target_pos) < 0.5:
				_on_hit_pos()
		return
	# 追踪模式：飞向目标单位。命中判定只看锁定目标本身：
	# 后期几十上百发弹丸如果每帧都做一次空间查询，会扫描周围整片单位，
	# 是战斗帧率最大的 CPU 热点；路径上的顺带命中改为由锁定目标承受。
	elif target and is_instance_valid(target):
		var goal: Vector3 = target.global_position
		_maybe_start_avoidance_arc(goal)
		if _arc_active:
			var prev := global_position
			var remaining := _step_ballistic(goal, delta)
			if check_obstacles and _segment_hits_obstacle(prev, global_position, goal):
				_on_obstacle_hit()
				return
			if remaining < BALLISTIC_HIT_RADIUS:
				global_position = goal
				_on_hit(target)
		else:
			var dir = (goal - global_position).normalized()
			var next_pos: Vector3 = global_position + dir * speed * delta
			if check_obstacles and _segment_hits_obstacle(global_position, next_pos, goal):
				_on_obstacle_hit()
				return
			global_position = next_pos
			_orient_to_dir(dir)
			# 检查是否足够近（命中）
			if global_position.distance_to(goal) < 0.3:
				_on_hit(target)
	else:
		recycle()

func _on_hit(entity: GameEntity):
	if hit: return
	# 命中音效
	if damage_radius > 0: AudioManager.play_sfx("cannon_hit")
	else: AudioManager.play_sfx("arrow_hit")

	hit = true

	# 确保 source 有效，无效则不传
	var src = source if is_instance_valid(source) else null
	# 直接命中的锁定目标承受 100% 伤害；周围其它敌人按弹种结算溅射。
	_deal_aoe_damage(entity, src, 0.0, true)

	if damage_radius > 0:
		_spawn_impact_effect(global_position, source_entity_id in STONE_SOURCE_IDS)
		var bm = _get_bm()
		if bm:
			var nearby = bm.get_nearby_enemies(global_position, damage_radius, team, owner_peer_id)
			for e in nearby:
				if e == entity or e == src: continue
				var d: float = e.global_position.distance_to(global_position)
				if d <= damage_radius:
					_deal_aoe_damage(e, src, d, false)
		else:
			for e in get_tree().get_nodes_in_group("entities"):
				if e == entity or e == src: continue
				if e is GameEntity and e.team != team:
					var d: float = e.global_position.distance_to(global_position)
					if d <= damage_radius:
						_deal_aoe_damage(e, src, d, false)

	if attack_type == 2: entity.shock(0.5)
	elif attack_type == 3: entity.freeze(3.0)

	# 箭矢：不立刻回收，插在目标身上保留 1.5 秒
	if _is_arrow_bullet() and is_instance_valid(entity):
		_stuck_to = entity
		# 箭只能插在表面：按目标体型把附着点推到身体外缘，
		# 不能直接用命中瞬间的位置（大单位会整支箭陷进去，小单位又会飘在外面）
		var er: float = float(entity.body_radius)
		var to_arrow: Vector3 = global_position - entity.global_position
		to_arrow.y = 0.0
		var hdir: Vector3 = to_arrow.normalized() if to_arrow.length() > 0.01 else Vector3.RIGHT
		# 多支箭命中同一目标时绕竖直轴随机偏转，让箭散布在身体表面而不是叠在一处
		hdir = hdir.rotated(Vector3.UP, randf_range(-0.7, 0.7))
		# 竖直方向保留命中时的高度差，但限制在目标身体高度范围内（最高约 1.8 倍半径）
		var rel_y: float = clampf(global_position.y - entity.global_position.y, -0.05, er * 1.8)
		_stuck_offset = hdir * (er * 1.02) + Vector3(0.0, rel_y, 0.0)
		_stuck_timer = ARROW_STICK_TIME
		return
	recycle()

# 让弹丸模型朝向飞行方向；方向接近竖直时换用备用 up 向量避免万向锁翻转
func _orient_to_dir(dir: Vector3):
	var up = Vector3.UP if absf(dir.y) < 0.99 * dir.length() else Vector3.FORWARD
	look_at(global_position + dir, up)

# 固定目标点命中：投石车/巨型投石机按落点距离线性衰减伤害。
func _on_hit_pos():
	if hit: return
	hit = true
	if damage_radius > 0: AudioManager.play_sfx("cannon_hit")
	var src = source if is_instance_valid(source) else null

	# 炮弹/巨石砸地：先放命中特效，巨石带更大的碎屑爆发
	if damage_radius > 0:
		_spawn_impact_effect(global_position, source_entity_id in STONE_SOURCE_IDS)

	if damage_radius > 0:
		var bm = _get_bm()
		if bm:
			var nearby = bm.get_nearby_enemies(global_position, damage_radius, team, owner_peer_id)
			for e in nearby:
				if e == src: continue
				var d: float = e.global_position.distance_to(global_position)
				if d <= damage_radius:
					_deal_aoe_damage(e, src, d, false)
		else:
			for e in get_tree().get_nodes_in_group("entities"):
				if e == src: continue
				if e is GameEntity and e.team != team:
					var d: float = e.global_position.distance_to(global_position)
					if d <= damage_radius:
						_deal_aoe_damage(e, src, d, false)
	recycle()

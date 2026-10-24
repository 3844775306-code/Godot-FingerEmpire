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

# 箭矢命中后不立即消失：插在目标身上保留一段时间，让中箭有个明确的视觉反馈。
const ARROW_STICK_TIME: float = 1.5
var _stuck_to: Node3D = null          # 命中后箭矢附着的目标
var _stuck_offset: Vector3 = Vector3.ZERO  # 命中瞬间相对目标的偏移，跟着目标一起动
var _stuck_timer: float = 0.0
# 巨石的伤害倍率：命中中心 1.5 倍，扩散到边缘降到 0.45 倍
const BOULDER_CENTER_MULT: float = 1.5
const BOULDER_EDGE_MULT: float = 0.45
const BOULDER_SOURCE_ID: int = 59     # 巨型投石机：唯一走距离衰减的巨石

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

# 弓箭类弹丸：命中后要插在目标身上。弓手 12/31/33/37/58、箭塔 25、战船 13。
func _is_arrow_bullet() -> bool:
	return source_entity_id in [12, 13, 25, 31, 33, 37, 58]

# 巨型投石机的巨石按落点距离衰减伤害；其它弹丸保持原样
func _damage_multiplier(dist: float) -> float:
	if source_entity_id != BOULDER_SOURCE_ID:
		return 1.0
	var t: float = clampf(dist / maxf(damage_radius, 0.01), 0.0, 1.0)
	return lerpf(BOULDER_CENTER_MULT, BOULDER_EDGE_MULT, t)

# 炮弹与巨石的命中特效：一次性尘土/碎屑爆发，节点播完自行销毁
func _spawn_impact_effect(pos: Vector3, big: bool) -> void:
	var bm = _get_bm()
	var parent: Node = bm if bm != null else get_tree().current_scene
	if parent == null:
		return
	# ── 1) 碎屑粒子：往外炸开的亮色颗粒 ──
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.amount = 18 if big else 12
	p.lifetime = 0.75
	p.explosiveness = 1.0
	p.direction = Vector3.UP
	p.spread = 180.0
	p.initial_velocity_min = 3.0
	p.initial_velocity_max = 8.0 if big else 5.5
	p.gravity = Vector3(0.0, -14.0, 0.0)
	p.scale_amount_min = 0.18
	p.scale_amount_max = 0.55 if big else 0.38
	var mesh := SphereMesh.new()
	mesh.radius = 0.13
	mesh.height = 0.26
	var mat := StandardMaterial3D.new()
	if big:
		# 石头：白色碎屑，带一点自发光，阴影里也能看清
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(0.93, 0.93, 0.95)
		mat.emission_enabled = true
		mat.emission = Color(0.7, 0.7, 0.75)
		mat.emission_energy_multiplier = 1.0
	else:
		# 炮弹：黑色火药碎屑；受光照影响，暗处自然不会发亮
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		mat.albedo_color = Color(0.05, 0.05, 0.06)
		mat.emission_enabled = false
	mesh.material = mat
	p.mesh = mesh
	parent.add_child(p)
	p.global_position = pos
	p.emitting = true
	get_tree().create_timer(1.4).timeout.connect(func():
		if is_instance_valid(p):
			p.queue_free())

	# ── 2) 闪光球：命中瞬间炸亮一下再迅速缩掉，是最直观的"打中了"反馈 ──
	var flash := MeshInstance3D.new()
	var fmesh := SphereMesh.new()
	fmesh.radius = 0.45 if big else 0.28
	fmesh.height = 0.9 if big else 0.56
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
	parent.add_child(flash)
	flash.global_position = pos
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
	rmesh.inner_radius = 0.35
	rmesh.outer_radius = 0.5
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
	parent.add_child(ring)
	ring.global_position = Vector3(pos.x, pos.y + 0.08, pos.z)
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
	parent.add_child(light)
	light.global_position = pos + Vector3.UP * 0.6
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

func _start_arc(goal: Vector3) -> void:
	_arc_active = true
	_arc_start = global_position
	var flat_vec := Vector3(goal.x - _arc_start.x, 0.0, goal.z - _arc_start.z)
	_arc_span = maxf(flat_vec.length(), 0.5)
	# 巨石比炮弹抛得更高；限制顶点高度，避免远程弹道飞出画面。
	var apex_ratio: float = 0.42 if source_entity_id in [17, 59] else 0.30
	_arc_apex = clampf(_arc_span * apex_ratio, 0.9, 6.0)
	_prev_pos = global_position

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
	if target_pos != Vector3.ZERO:
		if _is_ballistic_projectile():
			if not _arc_active:
				_start_arc(target_pos)
			if _step_ballistic(target_pos, delta) < BALLISTIC_HIT_RADIUS:
				global_position = target_pos
				_on_hit_pos()
		else:
			if _saved_dir == Vector3.ZERO:
				_saved_dir = (target_pos - global_position).normalized()
			global_position += _saved_dir * speed * delta
			_orient_to_dir(_saved_dir)
			# 到达目标点 → 对周围敌人造成AOE伤害
			if global_position.distance_to(target_pos) < 0.5:
				_on_hit_pos()
		return
	# 追踪模式：飞向目标单位。命中判定只看锁定目标本身：
	# 后期几十上百发弹丸如果每帧都做一次空间查询，会扫描周围整片单位，
	# 是战斗帧率最大的 CPU 热点；路径上的顺带命中改为由锁定目标承受。
	elif target and is_instance_valid(target):
		if _is_ballistic_projectile():
			if not _arc_active:
				_start_arc(target.global_position)
			if _step_ballistic(target.global_position, delta) < BALLISTIC_HIT_RADIUS:
				global_position = target.global_position
				_on_hit(target)
		else:
			var dir = (target.global_position - global_position).normalized()
			global_position += dir * speed * delta
			_orient_to_dir(dir)
			# 检查是否足够近（命中）
			if global_position.distance_to(target.global_position) < 0.3:
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
	entity.take_damage(damage * _damage_multiplier(0.0), src)

	if damage_radius > 0:
		_spawn_impact_effect(global_position, source_entity_id in [17, 59])
		var bm = _get_bm()
		if bm:
			var nearby = bm.get_nearby_enemies(global_position, damage_radius, team, owner_peer_id)
			for e in nearby:
				if e == entity or e == src: continue
				if e.global_position.distance_to(global_position) <= damage_radius:
					e.take_damage(damage * _damage_multiplier(e.global_position.distance_to(global_position)), src)
		else:
			for e in get_tree().get_nodes_in_group("entities"):
				if e == entity or e == src: continue
				if e is GameEntity and e.team != team:
					if e.global_position.distance_to(global_position) <= damage_radius:
						e.take_damage(damage * _damage_multiplier(e.global_position.distance_to(global_position)), src)

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

# 固定目标点命中：对落点周围所有敌人造成AOE伤害
func _on_hit_pos():
	if hit: return
	hit = true
	if damage_radius > 0: AudioManager.play_sfx("cannon_hit")
	var src = source if is_instance_valid(source) else null

	# 炮弹/巨石砸地：先放命中特效，巨石带更大的碎屑爆发
	if damage_radius > 0:
		_spawn_impact_effect(global_position, source_entity_id in [17, 59])

	if damage_radius > 0:
		var bm = _get_bm()
		if bm:
			var nearby = bm.get_nearby_enemies(global_position, damage_radius, team, owner_peer_id)
			for e in nearby:
				if e == src: continue
				var d: float = e.global_position.distance_to(global_position)
				if d <= damage_radius:
					e.take_damage(damage * _damage_multiplier(d), src)
		else:
			for e in get_tree().get_nodes_in_group("entities"):
				if e == src: continue
				if e is GameEntity and e.team != team:
					var d: float = e.global_position.distance_to(global_position)
					if d <= damage_radius:
						e.take_damage(damage * _damage_multiplier(d), src)
	recycle()

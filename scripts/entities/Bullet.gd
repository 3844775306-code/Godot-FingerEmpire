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
	return damage_radius > 0.0 or source_entity_id in [16, 17, 26, 39, 59, 64]

func _reset_ballistic_state() -> void:
	_arc_active = false
	_arc_start = Vector3.ZERO
	_arc_span = 1.0
	_arc_apex = 1.0
	_prev_pos = Vector3.ZERO

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
	entity.take_damage(damage, src)

	if damage_radius > 0:
		var bm = _get_bm()
		if bm:
			var nearby = bm.get_nearby_enemies(global_position, damage_radius, team, owner_peer_id)
			for e in nearby:
				if e == entity or e == src: continue
				if e.global_position.distance_to(global_position) <= damage_radius:
					e.take_damage(damage, src)
		else:
			for e in get_tree().get_nodes_in_group("entities"):
				if e == entity or e == src: continue
				if e is GameEntity and e.team != team:
					if e.global_position.distance_to(global_position) <= damage_radius:
						e.take_damage(damage, src)

	if attack_type == 2: entity.shock(0.5)
	elif attack_type == 3: entity.freeze(3.0)

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

	if damage_radius > 0:
		var bm = _get_bm()
		if bm:
			var nearby = bm.get_nearby_enemies(global_position, damage_radius, team, owner_peer_id)
			for e in nearby:
				if e == src: continue
				if e.global_position.distance_to(global_position) <= damage_radius:
					e.take_damage(damage, src)
		else:
			for e in get_tree().get_nodes_in_group("entities"):
				if e == src: continue
				if e is GameEntity and e.team != team:
					if e.global_position.distance_to(global_position) <= damage_radius:
						e.take_damage(damage, src)
	recycle()

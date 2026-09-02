# scripts/entities/Bullet.gd
class_name Bullet
extends Area3D

var team: int
var owner_peer_id: int = -1   # 发射方 owner_peer_id（乱斗 FFA 溅射/命中按 owner 过滤敌对）
var damage: float
var speed: float = 6.0
var target: GameEntity = null
var source: GameEntity = null
var damage_radius: float = 0.0
var attack_type: int = 1          # 1=普通, 2=电击, 3=冰冻, 4=灼烧
var time_alive: float = 0.0
var max_lifetime: float = 10.0
var hit: bool = false
var target_pos: Vector3 = Vector3.ZERO   # 固定目标点（非追踪模式）
var _saved_dir: Vector3 = Vector3.ZERO

func _ready():
	add_to_group("bullets")
	if damage_radius > 0 or (source and source.entity_id in [16,17,26,39]):
		# 投石车/巨型投石机用巨石
		if source and source.entity_id in [17, 59] and ResourceLoader.exists("res://models/defense/weapon-ammo-boulder.glb"):
			var st = load("res://models/defense/weapon-ammo-boulder.glb")
			if st: var s = st.instantiate(); if s: s.scale = Vector3.ONE * (3.5 if source.entity_id == 59 else 2.5); add_child(s)
		elif ResourceLoader.exists("res://models/pirate/cannon-ball.glb"):
			var cb = load("res://models/pirate/cannon-ball.glb")
			if cb: var c = cb.instantiate(); if c: add_child(c)
	else:
		if ResourceLoader.exists("res://models/forest/weapon-arrow.glb"):
			var arrow_scene = load("res://models/forest/weapon-arrow.glb")
			if arrow_scene:
				var arrow = arrow_scene.instantiate()
				# 模型本身沿 Z 轴水平（顶点包围盒在 Z 方向最长），无需额外旋转
				if arrow: arrow.scale = Vector3.ONE; add_child(arrow)
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

var _cached_bm = null

func _get_bm():
	if not is_instance_valid(_cached_bm):
		_cached_bm = get_tree().get_first_node_in_group("battle_manager")
	return _cached_bm

func _physics_process(delta):
	if hit:
		return
	time_alive += delta
	if time_alive > max_lifetime:
		queue_free()
		return

	# 固定目标点模式（投石车/巨型投石机）：飞向固定位置
	if target_pos != Vector3.ZERO:
		if _saved_dir == Vector3.ZERO:
			_saved_dir = (target_pos - global_position).normalized()
		global_position += _saved_dir * speed * delta
		_orient_to_dir(_saved_dir)
		# 到达目标点 → 对周围敌人造成AOE伤害
		if global_position.distance_to(target_pos) < 0.5:
			_on_hit_pos()
			return
	# 追踪模式：飞向目标单位
	elif target and is_instance_valid(target):
		var dir = (target.global_position - global_position).normalized()
		global_position += dir * speed * delta
		_orient_to_dir(dir)
		# 检查是否足够近（命中）
		if global_position.distance_to(target.global_position) < 0.3:
			_on_hit(target)
	else:
		queue_free()
		return

	# 使用缓存的 battle_manager 做碰撞检测
	var bm = _get_bm()
	if bm:
		var nearby = bm.get_nearby_enemies(global_position, 0.5, team, owner_peer_id)
		for entity in nearby:
			if entity == self or entity == source: continue
			if global_position.distance_to(entity.global_position) < 0.3:
				_on_hit(entity)
				return
	else:
		# 回退：全量扫描
		for entity in get_tree().get_nodes_in_group("entities"):
			if entity == self or entity == source: continue
			if not (entity is GameEntity): continue
			if entity.team == team: continue
			if global_position.distance_to(entity.global_position) < 0.3:
				_on_hit(entity)
				break

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

	queue_free()

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
	queue_free()

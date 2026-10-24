# 建筑被摧毁时的通用表现特效。
# 只负责视觉：倾斜、下沉、压缩、碎屑和尘土；实体死亡判定与缓存清理仍由调用方立即完成。
# 单机与联机主机由 GameEntity.die() 调用，联机客户端由 ClientRenderer 的 dead_ids 分支调用。
extends RefCounted

const TIER_WALL := 0
const TIER_BUILDING := 1
const TIER_CASTLE := 2

# 城墙倒塌很快，普通建筑稍慢，主城最有分量。
const WALL_COLLAPSE := 0.35
const BUILDING_COLLAPSE := 0.85
const CASTLE_COLLAPSE := 1.25
# 倒塌动作结束后只留极短时间让尘土收尾，然后释放实体。
const POST_COLLAPSE_LINGER := 0.12

static var _dust_texture: Texture2D = null
static var _debris_mesh: BoxMesh = null

# 返回本次特效总时长；返回 0 表示没有播放（无头服务器、节点无效）。
static func play(host: Node3D, entity_id: int, body_radius: float, model_override: Node3D = null) -> float:
	if not is_instance_valid(host) or not host.is_inside_tree():
		return 0.0
	if DisplayServer.get_name() == "headless":
		return 0.0
	if host.has_meta("_building_death_effect_played"):
		# 已经播放过：返回时长，让调用方不要回退到旧的立即删除逻辑。
		return _get_total_time(_get_tier(entity_id))
	host.set_meta("_building_death_effect_played", true)
	# 建筑死亡动画期间不再跑建造/城墙朝向等逻辑，避免死亡后重新生成模型把倒塌特效盖掉。
	host.set_process(false)
	host.set_physics_process(false)

	var tier := _get_tier(entity_id)
	var radius := maxf(0.35, body_radius)
	var collapse_time := _get_collapse_time(tier)
	var total_time := _get_total_time(tier)
	var visual := _find_visual_root(host, model_override)
	var base_pos := Vector3.ZERO
	var base_rot := Vector3.ZERO
	var base_scale := Vector3.ONE

	_disable_collision(host)
	if host.has_method("set_selected"):
		host.call("set_selected", false)
	for child in host.get_children():
		if String(child.name) == "SelectionRing":
			child.visible = false

	if visual != null:
		base_pos = visual.position
		base_rot = visual.rotation
		base_scale = visual.scale
		_start_collapse_tween(host, visual, base_pos, base_rot, base_scale, radius, tier, collapse_time)

	_spawn_debris(host, radius, tier)
	_spawn_dust(host, radius, tier)

	# 倒塌完成后隐藏模型，短暂保留尘土，然后释放整个实体。
	var collapse_timer := Timer.new()
	collapse_timer.one_shot = true
	collapse_timer.wait_time = collapse_time
	collapse_timer.timeout.connect(_on_collapsed.bind(host, visual))
	host.add_child(collapse_timer)
	collapse_timer.start()

	var free_timer := Timer.new()
	free_timer.one_shot = true
	free_timer.wait_time = total_time
	free_timer.timeout.connect(host.queue_free)
	host.add_child(free_timer)
	free_timer.start()
	return total_time

static func _get_tier(entity_id: int) -> int:
	if entity_id == 27:
		return TIER_WALL
	if entity_id in [20, 53]:
		return TIER_CASTLE
	return TIER_BUILDING

static func _get_collapse_time(tier: int) -> float:
	if tier == TIER_WALL:
		return WALL_COLLAPSE
	if tier == TIER_CASTLE:
		return CASTLE_COLLAPSE
	return BUILDING_COLLAPSE

static func _get_total_time(tier: int) -> float:
	return _get_collapse_time(tier) + POST_COLLAPSE_LINGER

# 服务端模型在 _model_instance；客户端模型是实体的直接子节点。
static func _find_visual_root(host: Node3D, override: Node3D) -> Node3D:
	if is_instance_valid(override):
		return override
	if host.has_meta("_model_instance"):
		var meta_model = host.get_meta("_model_instance")
		if is_instance_valid(meta_model) and meta_model is Node3D:
			return meta_model
	for child in host.get_children():
		if child is Node3D and _has_visual_mesh(child):
			var cname := String(child.name)
			if cname == "SelectionRing" or cname == "ClickableBody":
				continue
			return child
	return null

static func _has_visual_mesh(node: Node) -> bool:
	if node is MeshInstance3D and node.mesh != null:
		return true
	for child in node.get_children():
		if _has_visual_mesh(child):
			return true
	return false

static func _disable_collision(host: Node3D) -> void:
	if host is CollisionObject3D:
		host.collision_layer = 0
		host.collision_mask = 0
	for child in host.get_children():
		if child is CollisionShape3D:
			child.set_deferred("disabled", true)
		elif child is StaticBody3D:
			child.collision_layer = 0
			child.collision_mask = 0
			for sub in child.get_children():
				if sub is CollisionShape3D:
					sub.set_deferred("disabled", true)

static func _start_collapse_tween(host: Node3D, visual: Node3D, base_pos: Vector3, base_rot: Vector3, base_scale: Vector3, radius: float, tier: int, collapse_time: float) -> void:
	var lean_axis := Vector3.RIGHT if randf() < 0.5 else Vector3.BACK
	var lean_sign := 1.0 if randf() < 0.5 else -1.0
	var lean_angle := deg_to_rad(randf_range(8.0, 14.0)) * lean_sign
	var target_rot := base_rot + lean_axis * lean_angle
	var sink := radius * (0.25 if tier == TIER_WALL else 0.45)
	var squash_y := 0.45 if tier == TIER_WALL else 0.14
	var target_pos := base_pos + Vector3.DOWN * sink
	var target_scale := Vector3(base_scale.x * 1.04, base_scale.y * squash_y, base_scale.z * 1.04)

	var tween := host.create_tween()
	tween.set_parallel(true)
	var rot_tw := tween.tween_property(visual, "rotation", target_rot, collapse_time)
	rot_tw.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	var pos_tw := tween.tween_property(visual, "position", target_pos, collapse_time)
	pos_tw.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	var scale_tw := tween.tween_property(visual, "scale", target_scale, collapse_time)
	scale_tw.set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_IN)

static func _on_collapsed(host: Node3D, visual: Node3D) -> void:
	if not is_instance_valid(host):
		return
	if is_instance_valid(visual):
		visual.visible = false

static func _spawn_debris(host: Node3D, radius: float, tier: int) -> void:
	var particles := CPUParticles3D.new()
	particles.name = "BuildingDebris"
	particles.amount = 8 if tier == TIER_WALL else (16 if tier == TIER_BUILDING else 28)
	particles.lifetime = 0.85
	particles.one_shot = true
	particles.explosiveness = 0.92
	particles.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	particles.emission_sphere_radius = maxf(0.25, radius * 0.55)
	particles.direction = Vector3.UP
	particles.spread = 68.0
	particles.initial_velocity_min = 1.8
	particles.initial_velocity_max = 4.8
	particles.gravity = Vector3(0, -15.0, 0)
	particles.scale_amount_min = 0.5
	particles.scale_amount_max = 1.5
	particles.angular_velocity_min = -360.0
	particles.angular_velocity_max = 360.0
	particles.mesh = _get_debris_mesh()
	particles.position = Vector3(0, radius * 0.6, 0)
	host.add_child(particles)
	particles.emitting = true

static func _spawn_dust(host: Node3D, radius: float, tier: int) -> void:
	var particles := CPUParticles3D.new()
	particles.name = "BuildingDust"
	particles.amount = 5 if tier == TIER_WALL else (10 if tier == TIER_BUILDING else 16)
	particles.lifetime = 1.0
	particles.one_shot = true
	particles.explosiveness = 0.85
	particles.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	particles.emission_sphere_radius = maxf(0.3, radius * 0.7)
	particles.direction = Vector3.UP
	particles.spread = 80.0
	particles.initial_velocity_min = 0.6
	particles.initial_velocity_max = 2.0
	particles.gravity = Vector3(0, 0.6, 0)
	particles.scale_amount_min = 0.8
	particles.scale_amount_max = 1.6
	particles.mesh = _get_dust_mesh(radius)
	particles.position = Vector3(0, maxf(0.4, radius * 0.4), 0)
	host.add_child(particles)
	particles.emitting = true

static func _get_debris_mesh() -> BoxMesh:
	if _debris_mesh == null:
		var box := BoxMesh.new()
		box.size = Vector3(0.14, 0.14, 0.14)
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.36, 0.31, 0.25)
		mat.roughness = 1.0
		box.material = mat
		_debris_mesh = box
	return _debris_mesh

static func _get_dust_mesh(radius: float) -> QuadMesh:
	var quad := QuadMesh.new()
	quad.size = Vector2(maxf(0.8, radius * 1.3), maxf(0.8, radius * 1.3))
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(0.68, 0.62, 0.52, 0.5)
	mat.albedo_texture = _get_dust_texture()
	quad.material = mat
	return quad

static func _get_dust_texture() -> Texture2D:
	if _dust_texture == null:
		var gradient := Gradient.new()
		gradient.set_color(0, Color(1, 1, 1, 1))
		gradient.set_color(1, Color(1, 1, 1, 0))
		var tex := GradientTexture2D.new()
		tex.gradient = gradient
		tex.fill = GradientTexture2D.FILL_RADIAL
		tex.fill_from = Vector2(0.5, 0.5)
		tex.fill_to = Vector2(1.0, 0.5)
		tex.width = 64
		tex.height = 64
		_dust_texture = tex
	return _dust_texture

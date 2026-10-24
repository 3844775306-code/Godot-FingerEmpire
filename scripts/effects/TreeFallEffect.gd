# 木材资源被采集完时的树木倒地特效。
# 只负责视觉：树木绕根部倒下、落地扬尘/落叶，短暂停留后释放实体。
# 单机/联机主机由 GameEntity.die() 调用，联机客户端由 ClientRenderer 的 dead_ids 分支调用。
extends RefCounted

const EntityDamageVisual = preload("res://scripts/effects/EntityDamageVisual.gd")

const FALL_TIME := 0.85
const SETTLE_TIME := 0.12
const LINGER_TIME := 0.55
const TOTAL_TIME := FALL_TIME + SETTLE_TIME + LINGER_TIME
const FALL_ANGLE_DEG := 86.0
const IMPACT_DELAY := 0.78

static var _dust_texture: Texture2D = null

# 返回本次特效总时长；返回 0 表示没有播放（无头服务器、节点无效、没有模型）。
static func play(host: Node3D, body_radius: float, model_override: Node3D = null) -> float:
	if not is_instance_valid(host) or not host.is_inside_tree():
		return 0.0
	if DisplayServer.get_name() == "headless":
		return 0.0
	if host.has_meta("_wood_fall_played"):
		return TOTAL_TIME
	host.set_meta("_wood_fall_played", true)
	host.set_process(false)
	host.set_physics_process(false)
	if "collision_layer" in host:
		host.set("collision_layer", 0)
	if host.has_method("set_selected"):
		host.call("set_selected", false)
	for child in host.find_children("*", "CollisionShape3D", true, false):
		child.set_deferred("disabled", true)
	for child in host.get_children():
		if String(child.name) == "SelectionRing":
			child.visible = false

	# 采集到最后一击时，资源外观可能已经缩得很小；倒地前恢复完整尺寸。
	EntityDamageVisual.reset_resource(host)

	var visual := _find_visual_root(host, model_override)
	if visual == null:
		return 0.0
	var radius := maxf(0.35, body_radius)
	var base_rotation := visual.rotation
	var fall_sign: float = -1.0 if host.get_instance_id() % 2 == 0 else 1.0
	var fall_rotation := base_rotation.z + deg_to_rad(FALL_ANGLE_DEG) * fall_sign

	var tween := host.create_tween()
	var fall_tw := tween.tween_property(visual, "rotation:z", fall_rotation, FALL_TIME)
	fall_tw.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	var settle_tw := tween.tween_property(visual, "rotation:z", fall_rotation - deg_to_rad(3.0) * fall_sign, SETTLE_TIME)
	settle_tw.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.tween_interval(LINGER_TIME)
	tween.tween_callback(host.queue_free)

	_spawn_dust(host, radius)
	_spawn_leaves(host, radius)
	return TOTAL_TIME

static func _find_visual_root(host: Node3D, model_override: Node3D) -> Node3D:
	if model_override != null and is_instance_valid(model_override):
		return model_override
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

static func _spawn_dust(host: Node3D, radius: float) -> void:
	var particles := CPUParticles3D.new()
	particles.name = "TreeFallDust"
	particles.amount = 14
	particles.lifetime = 1.2
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	particles.emission_sphere_radius = maxf(0.2, radius * 0.7)
	particles.direction = Vector3.UP
	particles.spread = 80.0
	particles.initial_velocity_min = 0.2
	particles.initial_velocity_max = 0.8
	particles.gravity = Vector3(0, 0.15, 0)
	particles.scale_amount_min = 0.6
	particles.scale_amount_max = 1.4
	particles.mesh = _get_dust_mesh(radius)
	particles.position = Vector3(0, 0.15, 0)
	particles.emitting = false
	host.add_child(particles)
	_trigger_later(host, particles, IMPACT_DELAY)

static func _spawn_leaves(host: Node3D, radius: float) -> void:
	var particles := CPUParticles3D.new()
	particles.name = "TreeFallLeaves"
	particles.amount = 10
	particles.lifetime = 1.3
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	particles.emission_sphere_radius = maxf(0.25, radius * 0.8)
	particles.direction = Vector3.UP
	particles.spread = 65.0
	particles.initial_velocity_min = 0.35
	particles.initial_velocity_max = 1.1
	particles.gravity = Vector3(0, -1.1, 0)
	particles.scale_amount_min = 0.6
	particles.scale_amount_max = 1.2
	particles.mesh = _get_leaf_mesh(radius)
	particles.position = Vector3(0, radius * 1.4, 0)
	particles.emitting = false
	host.add_child(particles)
	_trigger_later(host, particles, IMPACT_DELAY * 0.9)

static func _trigger_later(host: Node3D, particles: CPUParticles3D, delay: float) -> void:
	var timer := Timer.new()
	timer.one_shot = true
	timer.wait_time = maxf(0.05, delay)
	timer.timeout.connect(_restart_particles.bind(particles))
	host.add_child(timer)
	timer.start()

static func _restart_particles(particles: CPUParticles3D) -> void:
	if not is_instance_valid(particles):
		return
	particles.restart()
	particles.emitting = true

static func _get_dust_mesh(radius: float) -> QuadMesh:
	var quad := QuadMesh.new()
	var size := maxf(0.4, radius * 0.8)
	quad.size = Vector2(size, size)
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(0.42, 0.34, 0.22, 0.34)
	mat.albedo_texture = _get_dust_texture()
	quad.material = mat
	return quad

static func _get_leaf_mesh(radius: float) -> QuadMesh:
	var quad := QuadMesh.new()
	var size := maxf(0.1, radius * 0.16)
	quad.size = Vector2(size, size * 1.4)
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(0.32, 0.62, 0.18, 0.9)
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

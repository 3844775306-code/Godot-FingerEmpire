class_name SiegeAttackFx
extends RefCounted

# 攻城单位开火/撞击时的轻量程序化特效。
# 不依赖外部贴图：全部用一次性 CPUParticles3D 和简单网格拼出来，
# 只在镜头附近触发，避免大规模交战时堆满粒子。

const FLASH_CORE := Color(1.0, 0.94, 0.70, 0.95)
const FLASH_EDGE := Color(1.0, 0.62, 0.20, 0.75)
const SMOKE_DARK := Color(0.22, 0.20, 0.18, 0.48)
const SMOKE_GREY := Color(0.42, 0.40, 0.36, 0.38)
const DUST_COLOR := Color(0.62, 0.54, 0.38, 0.45)
const WOOD_COLOR := Color(0.46, 0.30, 0.16, 0.95)
const WATER_COLOR := Color(0.68, 0.85, 0.92, 0.70)

# 复用网格/材质：每次开火都 new 一套 SphereMesh + StandardMaterial3D 会造成
# 明显的分配和材质切换开销，多台攻城器同时开火时尤其明显。
static var _sphere_cache: Dictionary = {}
static var _mat_cache: Dictionary = {}
static var _torus_mesh: TorusMesh = null
static var _ring_mat_cache: Dictionary = {}

# 延迟到动作真正“出手”的瞬间再冒烟/起尘，避免蓄力阶段就喷火
static func play(entity_id: int, model: Node3D, opts: Dictionary = {}) -> void:
	if not _can_show(model):
		return
	match entity_id:
		18:
			_after(model, 0.30, func() -> void: _spawn(18, model, opts))
		16:
			_spawn(16, model, opts)
		17:
			_after(model, 0.55, func() -> void: _spawn(17, model, opts))
		59:
			_after(model, 0.82, func() -> void: _spawn(59, model, opts))
		13:
			_spawn(13, model, opts)
		39:
			_spawn(39, model, opts)

static func _spawn(entity_id: int, model: Node3D, opts: Dictionary) -> void:
	if not _can_show(model):
		return
	var root := _effect_root(model)
	if root == null:
		return
	var forward: Vector3 = opts.get("forward", -model.global_transform.basis.z)
	forward.y = 0.0
	if forward.length_squared() < 0.001:
		forward = Vector3.FORWARD
	forward = forward.normalized()
	var right: Vector3 = opts.get("right", model.global_transform.basis.x)
	right.y = 0.0
	if right.length_squared() < 0.001:
		right = Vector3.RIGHT
	right = right.normalized()
	var radius: float = maxf(float(opts.get("body_radius", 0.8)), 0.2)
	var side: int = int(opts.get("side", 1 if model.get_instance_id() % 2 == 0 else -1))
	var origin: Vector3 = model.global_position

	match entity_id:
		18:
			_ram_impact(root, model, origin, forward, radius)
		16:
			_cannon_shot(root, model, origin, forward, radius)
		17:
			_catapult_shot(root, model, origin, forward, radius)
		59:
			_trebuchet_shot(root, model, origin, forward, radius)
		13:
			_broadside(root, model, origin, forward, right, radius, side, false)
		39:
			_broadside(root, model, origin, forward, right, radius, side, true)

static func _ram_impact(root: Node3D, model: Node3D, origin: Vector3, forward: Vector3, radius: float) -> void:
	var hit := origin + forward * (radius * 1.35 + 0.35) + Vector3.UP * 0.35
	_dust(root, hit, radius * 1.05, 16)
	_burst(root, hit, {
		"amount": 13, "lifetime": 0.65, "color": WOOD_COLOR,
		"direction": forward + Vector3.UP * 0.5, "spread": 55.0,
		"velocity_min": 1.8, "velocity_max": 4.4, "gravity": Vector3(0.0, -9.0, 0.0),
		"size": 0.055, "radius": 0.22,
	})
	_shake(model, 0.040, 0.18)

static func _cannon_shot(root: Node3D, model: Node3D, origin: Vector3, forward: Vector3, radius: float) -> void:
	var muzzle := origin + forward * (radius * 1.5 + 0.55) + Vector3.UP * (radius * 0.7 + 0.75)
	_burst(root, muzzle, {
		"amount": 10, "lifetime": 0.22, "color": FLASH_CORE,
		"direction": forward, "spread": 48.0,
		"velocity_min": 3.5, "velocity_max": 8.0, "gravity": Vector3.ZERO,
		"size": 0.16, "radius": 0.10, "emission": Color(1.0, 0.68, 0.24),
	})
	_burst(root, muzzle + forward * 0.15, {
		"amount": 6, "lifetime": 0.30, "color": FLASH_EDGE,
		"direction": forward, "spread": 70.0,
		"velocity_min": 1.5, "velocity_max": 3.8, "gravity": Vector3.ZERO,
		"size": 0.22, "radius": 0.18,
	})
	_burst(root, muzzle + forward * 0.2 + Vector3.UP * 0.1, {
		"amount": 18, "lifetime": 1.05, "color": SMOKE_DARK,
		"direction": forward + Vector3.UP * 0.25, "spread": 38.0,
		"velocity_min": 0.5, "velocity_max": 1.8, "gravity": Vector3(0.0, 0.45, 0.0),
		"size": 0.32, "radius": 0.24, "grow": 2.4,
	})
	_dust(root, origin + forward * (radius * 0.8), radius * 0.75, 10)
	_shake(model, 0.030, 0.14)

static func _catapult_shot(root: Node3D, model: Node3D, origin: Vector3, forward: Vector3, radius: float) -> void:
	var base := origin + forward * 0.2
	_dust(root, base, radius * 1.25, 20)
	_burst(root, base + Vector3.UP * 0.25, {
		"amount": 9, "lifetime": 0.95, "color": SMOKE_GREY,
		"direction": Vector3.UP, "spread": 55.0,
		"velocity_min": 0.6, "velocity_max": 2.0, "gravity": Vector3(0.0, 0.5, 0.0),
		"size": 0.30, "radius": 0.32, "grow": 2.0,
	})
	_shake(model, 0.030, 0.16)

static func _trebuchet_shot(root: Node3D, model: Node3D, origin: Vector3, forward: Vector3, radius: float) -> void:
	var base := origin + forward * 0.15
	_dust(root, base, radius * 1.8, 30)
	_burst(root, base + Vector3.UP * 0.4, {
		"amount": 16, "lifetime": 1.4, "color": SMOKE_GREY,
		"direction": Vector3.UP, "spread": 62.0,
		"velocity_min": 0.8, "velocity_max": 2.6, "gravity": Vector3(0.0, 0.35, 0.0),
		"size": 0.42, "radius": 0.5, "grow": 2.6,
	})
	_shockwave(root, base + Vector3.UP * 0.05, radius * 3.0, Color(0.78, 0.66, 0.44, 0.55))
	_shake(model, 0.060, 0.28)

static func _broadside(root: Node3D, model: Node3D, origin: Vector3, forward: Vector3, right: Vector3,
		radius: float, side: int, heavy: bool) -> void:
	var side_dir := right * float(side)
	var count: int = 3 if heavy else 2
	for i in range(count):
		var along := forward * ((float(i) - float(count - 1) * 0.5) * radius * 0.75)
		var muzzle := origin + side_dir * (radius * 1.25) + along + Vector3.UP * (radius * 0.55 + 0.55)
		_burst(root, muzzle, {
			"amount": 5 if not heavy else 7, "lifetime": 0.20, "color": FLASH_CORE,
			"direction": side_dir + forward * 0.15, "spread": 45.0,
			"velocity_min": 2.2, "velocity_max": 5.2, "gravity": Vector3.ZERO,
			"size": 0.12 if not heavy else 0.17, "radius": 0.10,
		})
		_burst(root, muzzle + side_dir * 0.2, {
			"amount": 9 if not heavy else 14, "lifetime": 0.85 if not heavy else 1.15,
			"color": SMOKE_DARK, "direction": side_dir + Vector3.UP * 0.2, "spread": 40.0,
			"velocity_min": 0.6, "velocity_max": 2.1, "gravity": Vector3(0.0, 0.4, 0.0),
			"size": 0.24 if not heavy else 0.34, "radius": 0.20, "grow": 2.2,
		})
	_water(root, origin + side_dir * (radius * 1.55) + Vector3.UP * 0.05, radius * (1.15 if not heavy else 1.6), heavy)
	_shake(model, 0.020 if not heavy else 0.040, 0.14 if not heavy else 0.22)

static func _dust(root: Node3D, pos: Vector3, radius: float, amount: int) -> void:
	_burst(root, pos + Vector3.UP * 0.08, {
		"amount": amount, "lifetime": 0.75, "color": DUST_COLOR,
		"direction": Vector3.UP, "spread": 78.0,
		"velocity_min": 0.5, "velocity_max": 2.0, "gravity": Vector3(0.0, -1.4, 0.0),
		"size": maxf(radius * 0.18, 0.09), "radius": maxf(radius * 0.4, 0.18), "grow": 1.8,
	})

static func _water(root: Node3D, pos: Vector3, radius: float, heavy: bool) -> void:
	_burst(root, pos, {
		"amount": 20 if heavy else 12, "lifetime": 0.85 if heavy else 0.62,
		"color": WATER_COLOR, "direction": Vector3.UP, "spread": 52.0,
		"velocity_min": 1.4 if heavy else 0.9, "velocity_max": 4.0 if heavy else 2.6,
		"gravity": Vector3(0.0, -5.5, 0.0),
		"size": 0.10 if heavy else 0.075, "radius": maxf(radius * 0.25, 0.15),
	})
	_shockwave(root, pos, radius * (1.5 if heavy else 1.1), Color(0.72, 0.88, 0.94, 0.42), 0.42)

static func _burst(root: Node3D, pos: Vector3, cfg: Dictionary) -> void:
	var p := CPUParticles3D.new()
	p.one_shot = true
	# 粒子量压到原来的 80%：远看仍是烟团，但多台齐射时 CPU 模拟和绘制压力更低
	p.amount = maxi(3, int(float(cfg.get("amount", 10)) * 0.8))
	p.lifetime = float(cfg.get("lifetime", 0.6))
	p.explosiveness = 1.0
	p.direction = Vector3(cfg.get("direction", Vector3.UP))
	p.spread = float(cfg.get("spread", 45.0))
	p.gravity = Vector3(cfg.get("gravity", Vector3.ZERO))
	p.initial_velocity_min = float(cfg.get("velocity_min", 1.0))
	p.initial_velocity_max = float(cfg.get("velocity_max", 2.5))
	p.scale_amount_min = 1.0
	p.scale_amount_max = float(cfg.get("grow", 1.0))
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = float(cfg.get("radius", 0.15))
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var color: Color = cfg.get("color", Color.WHITE)
	var has_emission: bool = cfg.has("emission")
	var emission: Color = cfg.get("emission", Color.WHITE)
	var mat_key := "%s|%s|%s" % [color.to_html(true), has_emission, emission.to_html(true)]
	var mat: StandardMaterial3D = _mat_cache.get(mat_key)
	if mat == null:
		mat = StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = color
		if has_emission:
			mat.emission_enabled = true
			mat.emission = emission
			mat.emission_energy_multiplier = 2.0
		_mat_cache[mat_key] = mat
	var size_key := "%.2f" % float(cfg.get("size", 0.12))
	var mesh_key := "%s|%s" % [size_key, mat_key]
	var mesh: SphereMesh = _sphere_cache.get(mesh_key)
	if mesh == null:
		mesh = SphereMesh.new()
		mesh.radius = float(cfg.get("size", 0.12))
		mesh.height = mesh.radius * 2.0
		mesh.radial_segments = 6
		mesh.rings = 3
		mesh.material = mat
		_sphere_cache[mesh_key] = mesh
	p.mesh = mesh
	root.add_child(p)
	p.global_position = pos
	p.set_deferred("emitting", true)
	_free_later(p, p.lifetime + 1.0)

static func _shockwave(root: Node3D, pos: Vector3, max_radius: float, color: Color, duration: float = 0.55) -> void:
	var ring := MeshInstance3D.new()
	if _torus_mesh == null:
		_torus_mesh = TorusMesh.new()
		_torus_mesh.inner_radius = 0.78
		_torus_mesh.outer_radius = 1.0
		_torus_mesh.rings = 32
		_torus_mesh.ring_segments = 8
	var mat_key := color.to_html(true)
	var mat: StandardMaterial3D = _ring_mat_cache.get(mat_key)
	if mat == null:
		mat = StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = color
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		_ring_mat_cache[mat_key] = mat
	ring.mesh = _torus_mesh
	ring.material_override = mat
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(ring)
	ring.global_position = pos
	ring.scale = Vector3.ONE * 0.18
	var final_scale := Vector3.ONE * maxf(max_radius, 0.3)
	var tw := ring.create_tween()
	tw.set_parallel(true)
	tw.tween_property(ring, "scale", final_scale, duration) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	# 用实例透明度淡出，避免修改共享材质
	tw.tween_property(ring, "transparency", 1.0, duration) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(func() -> void:
		if is_instance_valid(ring):
			ring.queue_free())

static func _free_later(node: Node, delay: float) -> void:
	if node.get_tree() == null:
		return
	node.get_tree().create_timer(delay).timeout.connect(func() -> void:
		if is_instance_valid(node):
			node.queue_free())

static func _after(model: Node3D, delay: float, callback: Callable) -> void:
	if not is_instance_valid(model) or model.get_tree() == null:
		return
	model.get_tree().create_timer(delay).timeout.connect(callback)

static func _shake(model: Node3D, amp: float, duration: float) -> void:
	if not is_instance_valid(model) or model.get_viewport() == null:
		return
	var cam := model.get_viewport().get_camera_3d()
	if cam == null or not cam.has_method("add_shake"):
		return
	if cam.global_position.distance_to(model.global_position) > 75.0:
		return
	cam.call("add_shake", amp, duration)

static func _effect_root(model: Node3D) -> Node3D:
	if not is_instance_valid(model) or model.get_tree() == null:
		return null
	var scene := model.get_tree().current_scene
	if scene is Node3D:
		return scene as Node3D
	var parent := model.get_parent()
	if parent is Node3D:
		return parent as Node3D
	return null

static func _can_show(model: Node3D) -> bool:
	if not is_instance_valid(model) or not model.is_inside_tree():
		return false
	var vp := model.get_viewport()
	if vp == null:
		return false
	var cam := vp.get_camera_3d()
	if cam == null:
		return false
	return cam.global_position.distance_to(model.global_position) <= 70.0

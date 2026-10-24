# 建筑建造过程视觉：模型从地基高度逐步升起，外围带木脚手架和尘土，完成后淡出并复位。
# 只影响外观；建造计时、生命值、视野和战斗判定仍由服务端立即处理。
# 服务端/单机由 Building 调用，联机客户端由 ClientRenderer 根据 build_timer 调用。
extends RefCounted

const STATE_META := "_construction_visual"
const MIN_HEIGHT := 0.04
const START_WIDTH := 0.82
const SCAFFOLD_FADE_START := 0.78

static var _dust_texture: Texture2D = null

# 建造开始：记录模型原始变换并铺好脚手架/地基。
static func begin(host: Node3D, model_override: Node3D = null) -> void:
	if not _can_update(host):
		return
	var state = _get_state(host)
	if state is Dictionary:
		if is_instance_valid(state.get("model")):
			return
		_destroy_state(host, state, false)
	_init_state(host, model_override)

# progress 为 0~1 的建造进度。
static func update(host: Node3D, progress: float, model_override: Node3D = null) -> void:
	if not _can_update(host):
		return
	var state = _get_state(host)
	if state is Dictionary and not is_instance_valid(state.get("model")):
		_destroy_state(host, state, false)
		state = null
	if not (state is Dictionary):
		_init_state(host, model_override)
		state = _get_state(host)
	if not (state is Dictionary):
		return
	var model = state.get("model")
	if not is_instance_valid(model):
		return
	var normalized := clampf(progress, 0.0, 1.0)
	_apply_model(state, normalized)
	_apply_scaffold(state, normalized)
	_update_dust(state, normalized)
	state["progress"] = normalized

# 建造完成：恢复模型、移除脚手架，并补一圈完成扬尘。
static func finish(host: Node3D) -> void:
	if not is_instance_valid(host):
		return
	var state = _get_state(host)
	if not (state is Dictionary):
		return
	_restore_model(state)
	_spawn_finish_burst(host, float(state.get("radius", 1.0)))
	_destroy_state(host, state, false)

# 建造中死亡/拆除：静默恢复模型并清理施工道具，交给死亡特效。
static func cancel(host: Node3D) -> void:
	if not is_instance_valid(host):
		return
	var state = _get_state(host)
	if not (state is Dictionary):
		return
	_restore_model(state)
	_destroy_state(host, state, false)

# 墙体模型在建造中切换（直墙/拐角）后，下一帧按新模型重建施工外观。
static func rebind(host: Node3D) -> void:
	if not is_instance_valid(host):
		return
	var state = _get_state(host)
	if not (state is Dictionary):
		return
	_destroy_state(host, state, false)

static func _init_state(host: Node3D, model_override: Node3D) -> void:
	var model := _find_model(host, model_override)
	if model == null:
		return
	var radius := _body_radius(host)
	var aabb := _model_local_aabb(model)
	var base_scale: Vector3 = model.scale
	var height := maxf(radius * 1.8, aabb.size.y * absf(base_scale.y) * 1.08)
	var scaffold := _create_scaffold(host, radius, height)
	var dust := _create_dust(host, radius)
	var state := {
		"model": model,
		"base_scale": base_scale,
		"base_position": model.position,
		"base_rotation": model.rotation,
		"bottom_y": aabb.position.y,
		"radius": radius,
		"scaffold": scaffold,
		"dust": dust,
		"progress": 0.0,
	}
	host.set_meta(STATE_META, state)
	_apply_model(state, 0.0)
	_apply_scaffold(state, 0.0)
	_update_dust(state, 0.0)

static func _apply_model(state: Dictionary, progress: float) -> void:
	var model = state.get("model")
	if not is_instance_valid(model):
		return
	var base_scale: Vector3 = state.get("base_scale", Vector3.ONE)
	var base_position: Vector3 = state.get("base_position", Vector3.ZERO)
	var bottom_y := float(state.get("bottom_y", 0.0))
	var height_factor := lerpf(MIN_HEIGHT, 1.0, pow(progress, 0.62))
	var width_factor := lerpf(START_WIDTH, 1.0, clampf(progress * 4.0, 0.0, 1.0))
	model.scale = base_scale * Vector3(width_factor, height_factor, width_factor)
	var bottom_shift := -bottom_y * absf(base_scale.y) * (1.0 - height_factor)
	model.position = base_position + Vector3(0, bottom_shift, 0)

static func _apply_scaffold(state: Dictionary, progress: float) -> void:
	var scaffold = state.get("scaffold")
	if not is_instance_valid(scaffold):
		return
	scaffold.visible = progress < 0.995
	var fade := smoothstep(SCAFFOLD_FADE_START, 0.995, progress)
	for mesh in scaffold.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := mesh as MeshInstance3D
		if mesh_instance != null:
			mesh_instance.transparency = fade

static func _update_dust(state: Dictionary, progress: float) -> void:
	var dust = state.get("dust")
	if is_instance_valid(dust):
		dust.emitting = progress < 0.92

static func _restore_model(state: Dictionary) -> void:
	var model = state.get("model")
	if not is_instance_valid(model):
		return
	model.scale = state.get("base_scale", Vector3.ONE)
	model.position = state.get("base_position", Vector3.ZERO)
	model.rotation = state.get("base_rotation", Vector3.ZERO)

static func _destroy_state(host: Node3D, state: Dictionary, restore_model: bool) -> void:
	if restore_model:
		_restore_model(state)
	for key in ["scaffold", "dust"]:
		var node = state.get(key)
		if is_instance_valid(node):
			node.queue_free()
	if host.has_meta(STATE_META):
		host.remove_meta(STATE_META)

static func _find_model(host: Node3D, model_override: Node3D) -> Node3D:
	if model_override != null and is_instance_valid(model_override):
		return model_override
	if host.has_meta("_model_instance"):
		var meta_model = host.get_meta("_model_instance")
		if is_instance_valid(meta_model) and meta_model is Node3D:
			return meta_model
	for child in host.get_children():
		if child is Node3D and _has_visual_mesh(child):
			var cname := String(child.name)
			if cname == "SelectionRing" or cname == "ClickableBody" or cname == "ConstructionScaffold":
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

static func _model_local_aabb(node: Node3D) -> AABB:
	return _aabb_recursive(node, Transform3D.IDENTITY)

static func _aabb_recursive(node: Node, xform: Transform3D) -> AABB:
	var result := AABB()
	for child in node.get_children():
		var child_xform := xform
		if child is Node3D:
			child_xform = xform * child.transform
		if child is MeshInstance3D and child.mesh:
			var aabb: AABB = child_xform * child.mesh.get_aabb()
			if aabb.size.length() > 0.0001:
				result = result.merge(aabb)
		var child_aabb := _aabb_recursive(child, child_xform)
		if child_aabb.size.length() > 0.0001:
			result = result.merge(child_aabb)
	return result

static func _create_scaffold(host: Node3D, radius: float, height: float) -> Node3D:
	var root := Node3D.new()
	root.name = "ConstructionScaffold"
	var half := radius * 1.05
	var post_thickness := clampf(radius * 0.08, 0.06, 0.2)
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.4, 0.25, 0.12)
	wood.roughness = 1.0
	var corners := [
		Vector3(-half, 0, -half),
		Vector3(half, 0, -half),
		Vector3(half, 0, half),
		Vector3(-half, 0, half),
	]
	for corner in corners:
		_add_box(root, Vector3(post_thickness, height, post_thickness), Vector3(corner.x, height * 0.5, corner.z), wood)
	for level in [0.45, 0.9]:
		var y: float = height * float(level)
		for z in [-half, half]:
			_add_box(root, Vector3(half * 2.0 + post_thickness, post_thickness * 0.8, post_thickness * 0.8), Vector3(0, y, z), wood)
		for x in [-half, half]:
			_add_box(root, Vector3(post_thickness * 0.8, post_thickness * 0.8, half * 2.0 + post_thickness), Vector3(x, y, 0), wood)
	# 施工地基，让刚放下的建筑也有明确落点
	var foundation := MeshInstance3D.new()
	foundation.name = "ConstructionFoundation"
	var box := BoxMesh.new()
	box.size = Vector3(half * 2.1, 0.12, half * 2.1)
	foundation.mesh = box
	var stone := StandardMaterial3D.new()
	stone.albedo_color = Color(0.36, 0.35, 0.32)
	stone.roughness = 1.0
	foundation.material_override = stone
	foundation.position.y = 0.06
	foundation.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	root.add_child(foundation)
	host.add_child(root)
	return root

static func _add_box(parent: Node3D, size: Vector3, pos: Vector3, material: Material) -> void:
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.material_override = material
	mesh.position = pos
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	parent.add_child(mesh)

static func _create_dust(host: Node3D, radius: float) -> CPUParticles3D:
	var particles := CPUParticles3D.new()
	particles.name = "ConstructionDust"
	particles.amount = 10
	particles.lifetime = 1.4
	particles.one_shot = false
	particles.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	particles.emission_sphere_radius = maxf(0.2, radius * 0.8)
	particles.direction = Vector3.UP
	particles.spread = 60.0
	particles.initial_velocity_min = 0.1
	particles.initial_velocity_max = 0.4
	particles.gravity = Vector3(0, 0.15, 0)
	particles.scale_amount_min = 0.5
	particles.scale_amount_max = 1.1
	particles.mesh = _get_dust_mesh(radius)
	particles.position = Vector3(0, 0.12, 0)
	particles.emitting = true
	host.add_child(particles)
	return particles

static func _spawn_finish_burst(host: Node3D, radius: float) -> void:
	var particles := CPUParticles3D.new()
	particles.name = "ConstructionFinishDust"
	particles.amount = 18
	particles.lifetime = 1.1
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	particles.emission_sphere_radius = maxf(0.25, radius * 0.9)
	particles.direction = Vector3.UP
	particles.spread = 80.0
	particles.initial_velocity_min = 0.3
	particles.initial_velocity_max = 1.0
	particles.gravity = Vector3(0, 0.1, 0)
	particles.scale_amount_min = 0.6
	particles.scale_amount_max = 1.4
	particles.mesh = _get_dust_mesh(radius)
	particles.position = Vector3(0, 0.12, 0)
	particles.emitting = true
	host.add_child(particles)
	var timer := Timer.new()
	timer.one_shot = true
	timer.wait_time = 1.4
	timer.timeout.connect(particles.queue_free)
	host.add_child(timer)
	timer.start()

static func _get_dust_mesh(radius: float) -> QuadMesh:
	var quad := QuadMesh.new()
	var size := maxf(0.35, radius * 0.7)
	quad.size = Vector2(size, size)
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(0.46, 0.38, 0.27, 0.32)
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

static func _body_radius(host: Node3D) -> float:
	var value = host.get("body_radius")
	if value == null and host.has_meta("_body_radius"):
		value = host.get_meta("_body_radius")
	if value == null:
		return 1.0
	return maxf(0.45, float(value))

static func _get_state(host: Node3D):
	if host.has_meta(STATE_META):
		return host.get_meta(STATE_META)
	return null

static func _can_update(host: Node3D) -> bool:
	if not is_instance_valid(host) or not host.is_inside_tree():
		return false
	return DisplayServer.get_name() != "headless"

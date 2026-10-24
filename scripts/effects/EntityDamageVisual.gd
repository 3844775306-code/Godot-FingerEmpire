# 建筑受损与资源枯竭的通用外观更新。
# 只改视觉：建筑叠加程序化裂纹/熏黑和烟尘，资源按剩余比例缩小、下沉、变暗。
# 联机不需要新增字段：两端都使用快照里的 health / max_health。
extends RefCounted

const DAMAGE_SHADER := preload("res://scripts/effects/building_damage.gdshader")

const BUILDING_OVERLAY_META := "_damage_overlay"
const BUILDING_OVERLAY_ROOT_META := "_damage_overlay_root"
const BUILDING_TRANSFORM_META := "_damage_transform"
const BUILDING_SMOKE_META := "_damage_smoke"
const BUILDING_FIRE_META := "_damage_fire"
const RESOURCE_BASE_META := "_depletion_base"
const RESOURCE_MATERIALS_META := "_depletion_materials"
const LAST_RATIO_META := "_damage_visual_ratio"

const RATIO_EPSILON := 0.002
const SMOKE_RATIO := 0.55
const FIRE_RATIO := 0.22
const RESOURCE_MIN_SCALE := 0.35

static var _smoke_texture: Texture2D = null

# 建筑：裂纹覆盖层 + 低血量烟尘/火星 + 重残时轻微倾斜下沉。
static func update_building(host: Node3D, ratio: float) -> void:
	if not _can_update(host):
		return
	var normalized := clampf(ratio, 0.0, 1.0)
	var ratio_due := _should_update(host, normalized)
	var root := _find_building_root(host)
	if root == null:
		return
	var existing_overlay = _get_optional_meta(host, BUILDING_OVERLAY_META)
	var overlay_root_id := int(host.get_meta(BUILDING_OVERLAY_ROOT_META, 0))
	var root_changed: bool = not (existing_overlay is ShaderMaterial) or overlay_root_id != root.get_instance_id()
	if not ratio_due and not root_changed:
		return
	if normalized >= 0.995 and not ratio_due:
		# 满血时只补一次模型引用，不需要重新生成覆盖层。
		return
	var overlay := _ensure_building_overlay(host, root)
	if overlay != null:
		overlay.set_shader_parameter("damage", 1.0 - normalized)
	_update_building_transform(host, root, normalized)
	_update_building_particles(host, normalized)
	host.set_meta(LAST_RATIO_META, normalized)

# 资源：按剩余比例连续缩放、下沉，并把材质压暗/去饱和。
static func update_resource(host: Node3D, ratio: float) -> void:
	if not _can_update(host):
		return
	var normalized := clampf(ratio, 0.0, 1.0)
	if not _should_update(host, normalized):
		return
	var roots := _collect_visual_roots(host)
	if roots.is_empty():
		return
	var base_state: Dictionary = host.get_meta(RESOURCE_BASE_META, {})
	if base_state.is_empty():
		base_state = {}
		for root in roots:
			base_state[root.get_instance_id()] = {"pos": root.position, "scale": root.scale}
		host.set_meta(RESOURCE_BASE_META, base_state)
	var radius := _get_body_radius(host)
	var scale_factor := lerpf(RESOURCE_MIN_SCALE, 1.0, normalized)
	var sink := radius * 0.18 * (1.0 - normalized)
	for root in roots:
		var key: int = root.get_instance_id()
		if not base_state.has(key):
			base_state[key] = {"pos": root.position, "scale": root.scale}
		var base: Dictionary = base_state[key]
		root.scale = base["scale"] * scale_factor
		root.position = base["pos"] + Vector3.DOWN * sink
	_apply_resource_materials(host, roots, normalized)
	host.set_meta(LAST_RATIO_META, normalized)

static func _can_update(host: Node3D) -> bool:
	if not is_instance_valid(host) or not host.is_inside_tree():
		return false
	return DisplayServer.get_name() != "headless"

static func _should_update(host: Node3D, ratio: float) -> bool:
	var last := float(host.get_meta(LAST_RATIO_META, -1.0))
	if last < 0.0:
		# 满血时不做任何事，避免给所有新建筑预先生成覆盖材质。
		if ratio >= 0.995:
			host.set_meta(LAST_RATIO_META, ratio)
			return false
		return true
	return absf(last - ratio) >= RATIO_EPSILON

static func _find_building_root(host: Node3D) -> Node3D:
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

static func _collect_visual_roots(host: Node3D) -> Array:
	var roots: Array = []
	for child in host.get_children():
		if child is MeshInstance3D and String(child.name) != "SelectionRing":
			roots.append(child)
		elif child is Node3D and _has_visual_mesh(child):
			var cname := String(child.name)
			if cname == "SelectionRing" or cname == "ClickableBody":
				continue
			roots.append(child)
	return roots

static func _has_visual_mesh(node: Node) -> bool:
	if node is MeshInstance3D and node.mesh != null:
		return true
	for child in node.get_children():
		if _has_visual_mesh(child):
			return true
	return false

static func _ensure_building_overlay(host: Node3D, root: Node3D) -> ShaderMaterial:
	var overlay = null
	if host.has_meta(BUILDING_OVERLAY_META):
		overlay = host.get_meta(BUILDING_OVERLAY_META)
	if not (overlay is ShaderMaterial) or not is_instance_valid(overlay):
		overlay = ShaderMaterial.new()
		overlay.shader = DAMAGE_SHADER
		overlay.set_shader_parameter("damage", 0.0)
		overlay.set_shader_parameter("seed", randf() * 37.0)
		host.set_meta(BUILDING_OVERLAY_META, overlay)
	var root_id: int = root.get_instance_id()
	if int(host.get_meta(BUILDING_OVERLAY_ROOT_META, 0)) != root_id:
		overlay.set_shader_parameter("local_scale", _estimate_crack_scale(root))
		_attach_overlay_recursive(root, overlay)
		host.set_meta(BUILDING_OVERLAY_ROOT_META, root_id)
	return overlay

static func _estimate_crack_scale(root: Node3D) -> float:
	var max_dim := 0.0
	if root is MeshInstance3D and root.mesh != null:
		var root_aabb: AABB = root.get_aabb()
		max_dim = maxf(root_aabb.size.x, maxf(root_aabb.size.y, root_aabb.size.z))
	for child in root.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := child as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		var aabb: AABB = mesh_instance.get_aabb()
		max_dim = maxf(max_dim, maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z)))
	# 让裂纹频率与模型原始尺寸无关：大模型用更小的缩放，保持大约 3 个噪声周期覆盖全身。
	return clampf(3.0 / maxf(0.25, max_dim), 0.005, 8.0)

static func _attach_overlay_recursive(node: Node, overlay: ShaderMaterial) -> void:
	if node is MeshInstance3D and node.mesh != null:
		for surface_index in node.mesh.get_surface_count():
			var src = node.get_active_material(surface_index)
			if src == null:
				continue
			var material: Material = src.duplicate()
			if material == null:
				continue
			material.next_pass = overlay
			node.set_surface_override_material(surface_index, material)
	for child in node.get_children():
		_attach_overlay_recursive(child, overlay)

static func _update_building_transform(host: Node3D, root: Node3D, ratio: float) -> void:
	var transform_state: Dictionary = host.get_meta(BUILDING_TRANSFORM_META, {})
	var root_id: int = root.get_instance_id()
	if transform_state.is_empty() or int(transform_state.get("root", 0)) != root_id:
		transform_state = {"root": root_id, "pos": root.position, "rot": root.rotation}
		host.set_meta(BUILDING_TRANSFORM_META, transform_state)
	var damage := 1.0 - ratio
	# 只在低于 45% 血后开始倾斜/下沉，避免轻微掉血就让整栋建筑歪掉。
	var heavy := clampf((damage - 0.55) / 0.45, 0.0, 1.0)
	var radius := _get_body_radius(host)
	var sink := radius * 0.1 * heavy
	var lean := deg_to_rad(5.0) * heavy
	root.position = transform_state["pos"] + Vector3.DOWN * sink
	root.rotation = Vector3(transform_state["rot"].x + lean * 0.6, transform_state["rot"].y, transform_state["rot"].z - lean)

static func _update_building_particles(host: Node3D, ratio: float) -> void:
	if ratio < SMOKE_RATIO:
		var smoke := _ensure_smoke(host)
		if smoke != null:
			smoke.emitting = true
	else:
		var old_smoke = _get_optional_meta(host, BUILDING_SMOKE_META)
		if is_instance_valid(old_smoke):
			old_smoke.emitting = false
	if ratio < FIRE_RATIO:
		var fire := _ensure_fire(host)
		if fire != null:
			fire.emitting = true
	else:
		var old_fire = _get_optional_meta(host, BUILDING_FIRE_META)
		if is_instance_valid(old_fire):
			old_fire.emitting = false

static func _ensure_smoke(host: Node3D) -> CPUParticles3D:
	var old = _get_optional_meta(host, BUILDING_SMOKE_META)
	if is_instance_valid(old) and old is CPUParticles3D:
		return old
	var radius := _get_body_radius(host)
	var particles := CPUParticles3D.new()
	particles.name = "DamageSmoke"
	particles.amount = 6
	particles.lifetime = 1.7
	particles.one_shot = false
	particles.explosiveness = 0.1
	particles.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	particles.emission_sphere_radius = maxf(0.15, radius * 0.4)
	particles.direction = Vector3.UP
	particles.spread = 35.0
	particles.initial_velocity_min = 0.25
	particles.initial_velocity_max = 0.7
	particles.gravity = Vector3(0, 0.7, 0)
	particles.scale_amount_min = 0.7
	particles.scale_amount_max = 1.5
	particles.mesh = _get_smoke_mesh(radius)
	particles.position = Vector3(0, radius * 0.8, 0)
	particles.emitting = false
	host.add_child(particles)
	host.set_meta(BUILDING_SMOKE_META, particles)
	return particles

static func _ensure_fire(host: Node3D) -> CPUParticles3D:
	var old = _get_optional_meta(host, BUILDING_FIRE_META)
	if is_instance_valid(old) and old is CPUParticles3D:
		return old
	var radius := _get_body_radius(host)
	var particles := CPUParticles3D.new()
	particles.name = "DamageFire"
	particles.amount = 5
	particles.lifetime = 0.45
	particles.one_shot = false
	particles.explosiveness = 0.25
	particles.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	particles.emission_sphere_radius = maxf(0.1, radius * 0.3)
	particles.direction = Vector3.UP
	particles.spread = 28.0
	particles.initial_velocity_min = 0.4
	particles.initial_velocity_max = 1.1
	particles.gravity = Vector3(0, 0.8, 0)
	particles.scale_amount_min = 0.5
	particles.scale_amount_max = 1.0
	particles.mesh = _get_fire_mesh(radius)
	particles.position = Vector3(0, radius * 0.35, 0)
	particles.emitting = false
	host.add_child(particles)
	host.set_meta(BUILDING_FIRE_META, particles)
	return particles

static func _get_smoke_mesh(radius: float) -> QuadMesh:
	var quad := QuadMesh.new()
	var size := maxf(0.45, radius * 0.65)
	quad.size = Vector2(size, size)
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(0.19, 0.18, 0.17, 0.32)
	mat.albedo_texture = _get_smoke_texture()
	quad.material = mat
	return quad

static func _get_fire_mesh(radius: float) -> QuadMesh:
	var quad := QuadMesh.new()
	var size := maxf(0.28, radius * 0.35)
	quad.size = Vector2(size, size)
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.albedo_color = Color(1.0, 0.42, 0.08, 0.7)
	mat.albedo_texture = _get_smoke_texture()
	quad.material = mat
	return quad

static func _get_smoke_texture() -> Texture2D:
	if _smoke_texture == null:
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
		_smoke_texture = tex
	return _smoke_texture

static func _apply_resource_materials(host: Node3D, roots: Array, ratio: float) -> void:
	var entries: Array = host.get_meta(RESOURCE_MATERIALS_META, [])
	if entries.is_empty():
		entries = []
		for root in roots:
			_collect_resource_materials_recursive(root, entries)
		host.set_meta(RESOURCE_MATERIALS_META, entries)
	if entries.is_empty():
		return
	var tint := lerpf(1.0, 0.55, 1.0 - ratio)
	for entry in entries:
		var mat = entry.get("mat")
		if not is_instance_valid(mat):
			continue
		if "albedo_color" in mat:
			var base: Color = entry["base"]
			mat.set("albedo_color", Color(base.r * tint, base.g * tint, base.b * tint, base.a))

static func _collect_resource_materials_recursive(node: Node, entries: Array) -> void:
	if node is MeshInstance3D and node.mesh != null:
		for surface_index in node.mesh.get_surface_count():
			var src = node.get_active_material(surface_index)
			if src == null or not ("albedo_color" in src):
				continue
			var material: Material = src.duplicate()
			if material == null:
				continue
			node.set_surface_override_material(surface_index, material)
			entries.append({"mat": material, "base": src.get("albedo_color")})
	for child in node.get_children():
		_collect_resource_materials_recursive(child, entries)

static func _get_optional_meta(host: Node3D, key: String):
	if host.has_meta(key):
		return host.get_meta(key)
	return null

static func _get_body_radius(host: Node3D) -> float:
	var meta_radius = _get_optional_meta(host, "_body_radius")
	if meta_radius != null:
		return maxf(0.3, float(meta_radius))
	var value = host.get("body_radius")
	if value == null:
		return 0.8
	return maxf(0.3, float(value))

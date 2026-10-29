class_name WeaponAttachment
extends RefCounted

# 武器/盾牌统一挂到士兵骨骼上，让挥砍、走路时武器跟着手臂动。
# 之前武器挂在单位根节点，位置固定，手臂动画一动就穿帮。
# 没有骨骼的模型（攻城器械、船只等）保持旧逻辑：直接挂根节点。

const SWORD_IDS := [11, 15, 19, 30, 32, 34, 36, 38, 65, 66, 68]
const SPEAR_IDS := [35, 69]
const BOW_IDS := [12, 31, 37, 67]
const SHIELD_IDS := [36, 37, 38, 68, 69]

const SWORD_PATH := "res://models/arena/weapon-sword.glb"
const SPEAR_PATH := "res://models/arena/weapon-spear.glb"
const BOW_PATH := "res://models/forest/weapon-bow.glb"
const SHIELD_PATH := "res://models/arena/shield-round.glb"

# 士兵模型的骨骼是“手臂沿 X 轴伸出”的，肩到手约 0.29；挂点必须沿骨骼
# 局部 X 轴偏移，不能沿 Y 轴往下压，否则武器会挂到脚边而不是手上。
const HAND_REACH := 0.29
const SHIELD_REACH := 0.20
# 剑模型是剑尖朝 -Y 建的；转 180° 让剑尖朝上，避免剑尖插进地面。
const SWORD_ROT := Vector3(PI, 0.0, 0.0)
const SPEAR_ROT := Vector3(-0.14, 0.0, 0.0)
# 弓和矛的原点不在握把中心：往下挪一点，让手握在弓腰/矛杆中段。
const BOW_GRIP_OFFSET := Vector3(0.0, -0.22, 0.0)
const SPEAR_GRIP_OFFSET := Vector3(0.0, -0.10, 0.0)

static func attach(entity: Node3D, entity_id: int, _body_radius: float) -> void:
	if entity == null or not is_instance_valid(entity):
		return
	if entity.has_meta("_weapon_attached_for") and int(entity.get_meta("_weapon_attached_for")) == entity_id:
		return
	entity.set_meta("_weapon_attached_for", entity_id)
	var skeleton := _find_skeleton(entity)
	if entity_id in BOW_IDS:
		_attach_weapon(entity, skeleton, BOW_PATH, "arm-left",
				Vector3(HAND_REACH, 0.0, 0.02), Vector3.ZERO, 1.0, BOW_GRIP_OFFSET)
	elif entity_id in SPEAR_IDS:
		_attach_weapon(entity, skeleton, SPEAR_PATH, "arm-right",
				Vector3(-HAND_REACH, 0.0, 0.02), SPEAR_ROT, 1.0, SPEAR_GRIP_OFFSET)
	elif entity_id in SWORD_IDS:
		_attach_weapon(entity, skeleton, SWORD_PATH, "arm-right",
				Vector3(-HAND_REACH, 0.0, 0.02), SWORD_ROT, 1.0, Vector3.ZERO)
	if entity_id in SHIELD_IDS:
		# 弓手左手持弓，盾改挂右前臂；近战右手持武器，盾挂左前臂。
		var shield_bone := "arm-right" if entity_id in BOW_IDS else "arm-left"
		var shield_side: float = -1.0 if shield_bone == "arm-right" else 1.0
		_attach_weapon(entity, skeleton, SHIELD_PATH, shield_bone,
				Vector3(shield_side * SHIELD_REACH, 0.0, 0.04), Vector3.ZERO, 1.0, Vector3.ZERO)

# 弹丸发射点：弓箭用弓的位置，炮弹/石头按模型朝目标一侧的上沿出手，
# 避免所有远程单位都从身体正上方/头顶发射。
static func projectile_origin(source: Node3D, entity_id: int, target_pos: Vector3) -> Vector3:
	if source == null or not is_instance_valid(source):
		return target_pos
	var dir := target_pos - source.global_position
	dir.y = 0.0
	if dir.length_squared() < 0.0001:
		dir = -source.global_transform.basis.z
	else:
		dir = dir.normalized()
	if entity_id in BOW_IDS:
		var bow := source.find_child("WeaponBone_arm_left", true, false)
		if bow is Node3D and bow.get_child_count() > 0:
			var weapon := bow.get_child(0) as Node3D
			# 刚生成的那一帧骨骼姿态可能还没刷新，弓还在原点；此时走模型包围盒兜底。
			if weapon != null and weapon.global_position.distance_to(source.global_position) > 0.05:
				# 箭从弓身前方一点出，既贴着弓又不从手心里钻出来。
				return weapon.global_position + dir * 0.20 + Vector3.UP * 0.04
	var model := _find_entity_model(source)
	if model != null:
		var box := _model_local_aabb(model)
		if box.size.length_squared() > 0.0001:
			var center := box.get_center()
			var local_target := model.to_local(target_pos)
			var flat := Vector3(local_target.x - center.x, 0.0, local_target.z - center.z)
			var point := center
			if flat.length_squared() > 0.0001:
				flat = flat.normalized()
				var half := box.size * 0.5
				var tx: float = half.x / maxf(absf(flat.x), 0.0001)
				var tz: float = half.z / maxf(absf(flat.z), 0.0001)
				point += flat * minf(tx, tz)
				point += flat * 0.04
			# 石头从投石臂顶端出；塔楼箭从塔身上部出；炮弹从炮口高度出。
			var ratio: float = 0.90
			if entity_id not in [17, 59]:
				ratio = 0.80 if entity_id in [20, 25, 26, 53] else 0.62
			point.y = lerpf(box.position.y, box.end.y, ratio)
			return model.to_global(point)
	var body_r: float = 0.5
	var br_value = source.get("body_radius")
	if br_value != null:
		body_r = float(br_value)
	var rise: float = body_r * (4.0 if entity_id in [17, 59] else 3.0)
	return source.global_position + Vector3.UP * rise + dir * body_r * 0.6

static func _find_entity_model(node: Node) -> Node3D:
	if node.has_meta("_model_instance"):
		var cached = node.get_meta("_model_instance")
		if cached is Node3D and is_instance_valid(cached):
			return cached as Node3D
	if node.has_meta("entity_model") and node is Node3D:
		return node as Node3D
	for child in node.get_children():
		var found := _find_entity_model(child)
		if found != null:
			return found
	return null

static func _model_local_aabb(model: Node3D) -> AABB:
	var acc := [null]
	_merge_world_mesh_aabb(model, acc)
	if acc[0] == null:
		return AABB()
	return model.global_transform.affine_inverse() * (acc[0] as AABB)

static func _merge_world_mesh_aabb(node: Node, acc: Array) -> void:
	if node is MeshInstance3D and node.mesh != null:
		var box: AABB = node.global_transform * node.get_aabb()
		if acc[0] == null:
			acc[0] = box
		else:
			acc[0] = (acc[0] as AABB).merge(box)
	for child in node.get_children():
		_merge_world_mesh_aabb(child, acc)

static func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D
	for child in node.get_children():
		var found := _find_skeleton(child)
		if found != null:
			return found
	return null

static func _attach_weapon(entity: Node3D, skeleton: Skeleton3D, path: String,
		bone_name: String, offset: Vector3, rotation: Vector3,
		weapon_scale: float, grip_offset: Vector3 = Vector3.ZERO) -> void:
	if not ResourceLoader.exists(path):
		return
	var scene := load(path)
	if scene == null:
		return
	var weapon = scene.instantiate()
	if weapon == null:
		return
	weapon.scale = Vector3.ONE * weapon_scale
	# BoneAttachment3D 每帧会被骨骼姿态覆盖，偏移/旋转必须写在武器本身上，
	# 写在 attachment 上会被重置，表现为武器永远卡在肩膀。
	weapon.position = grip_offset + offset
	weapon.rotation = rotation
	if skeleton != null and skeleton.find_bone(bone_name) >= 0:
		var attachment := BoneAttachment3D.new()
		attachment.name = "WeaponBone_" + bone_name.replace("-", "_")
		attachment.bone_name = bone_name
		skeleton.add_child(attachment)
		attachment.add_child(weapon)
	else:
		# 无骨骼模型回退：保持原来的固定挂点，至少不会消失。
		weapon.position = Vector3(0.6, 0.2, 0.0) + grip_offset
		entity.add_child(weapon)

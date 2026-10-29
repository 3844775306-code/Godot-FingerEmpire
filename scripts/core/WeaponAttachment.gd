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

static func attach(entity: Node3D, entity_id: int, body_radius: float) -> void:
	if entity == null or not is_instance_valid(entity):
		return
	if entity.has_meta("_weapon_attached_for") and int(entity.get_meta("_weapon_attached_for")) == entity_id:
		return
	entity.set_meta("_weapon_attached_for", entity_id)
	var skeleton := _find_skeleton(entity)
	if entity_id in BOW_IDS:
		_attach_weapon(entity, skeleton, BOW_PATH, "arm-left", body_radius,
				Vector3(0.0, -body_radius * 0.50, 0.02), Vector3.ZERO, 1.0)
	elif entity_id in SPEAR_IDS:
		_attach_weapon(entity, skeleton, SPEAR_PATH, "arm-right", body_radius,
				Vector3(0.0, -body_radius * 0.52, 0.02), Vector3.ZERO, 1.0)
	elif entity_id in SWORD_IDS:
		_attach_weapon(entity, skeleton, SWORD_PATH, "arm-right", body_radius,
				Vector3(0.0, -body_radius * 0.52, 0.02), Vector3.ZERO, 1.0)
	if entity_id in SHIELD_IDS:
		# 弓手左手持弓，盾改挂右前臂；近战右手持武器，盾挂左前臂。
		var shield_bone := "arm-right" if entity_id in BOW_IDS else "arm-left"
		_attach_weapon(entity, skeleton, SHIELD_PATH, shield_bone, body_radius,
				Vector3(0.0, -body_radius * 0.42, -0.03), Vector3.ZERO, 0.8)

static func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D
	for child in node.get_children():
		var found := _find_skeleton(child)
		if found != null:
			return found
	return null

static func _attach_weapon(entity: Node3D, skeleton: Skeleton3D, path: String,
		bone_name: String, body_radius: float, offset: Vector3,
		rotation: Vector3, weapon_scale: float) -> void:
	if not ResourceLoader.exists(path):
		return
	var scene := load(path)
	if scene == null:
		return
	var weapon = scene.instantiate()
	if weapon == null:
		return
	weapon.scale = Vector3.ONE * weapon_scale
	if skeleton != null and skeleton.find_bone(bone_name) >= 0:
		var attachment := BoneAttachment3D.new()
		attachment.name = "WeaponBone_" + bone_name.replace("-", "_")
		attachment.bone_name = bone_name
		attachment.position = offset
		attachment.rotation = rotation
		skeleton.add_child(attachment)
		attachment.add_child(weapon)
	else:
		# 无骨骼模型回退：保持原来的固定挂点，至少不会消失。
		weapon.position = Vector3(body_radius * 1.2, body_radius * 0.4, 0.0)
		entity.add_child(weapon)

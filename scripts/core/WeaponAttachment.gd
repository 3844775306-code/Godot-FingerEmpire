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
const ARROW_PATH := "res://models/forest/weapon-arrow.glb"
# 搭在弓上的待发箭：跟随弓移动，射击瞬间隐藏，拉弓动作结束后再补一支。
# 箭模型自身箭尖朝 +Z，弓模型前方也是 +Z；弓由 WeaponAim 固定朝向单位正前方，
# 所以箭不用再掉头，箭尾留在弓弦附近、箭尖朝前即可。
const NOCKED_ARROW_POS := Vector3(-0.035, 0.239, 0.18)
const NOCKED_ARROW_SCALE := 0.72
const NOCKED_ARROW_ROT := Vector3.ZERO

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
				Vector3(HAND_REACH, 0.0, 0.02), Vector3.ZERO, 1.0, BOW_GRIP_OFFSET, true)
		_add_nocked_arrow(_find_weapon(entity, "arm-left"))
	elif entity_id in SPEAR_IDS:
		_attach_weapon(entity, skeleton, SPEAR_PATH, "arm-right",
				Vector3(-HAND_REACH, 0.0, 0.02), SPEAR_ROT, 1.0, SPEAR_GRIP_OFFSET)
	elif entity_id in SWORD_IDS:
		_attach_weapon(entity, skeleton, SWORD_PATH, "arm-right",
				Vector3(-HAND_REACH, 0.0, 0.02), SWORD_ROT, 1.0, Vector3.ZERO, true)
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
		var bow := _find_weapon(source, "arm-left")
		if bow != null:
			# 刚生成的那一帧骨骼姿态可能还没刷新，弓还在原点；此时走模型包围盒兜底。
			if bow.global_position.distance_to(source.global_position) > 0.05:
				# 箭从弓身前方一点出，既贴着弓又不从手心里钻出来。
				return bow.global_position + dir * 0.20 + Vector3.UP * 0.04
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

static func _find_weapon(entity: Node3D, bone_name: String) -> Node3D:
	if entity == null or not is_instance_valid(entity):
		return null
	var attachment := entity.find_child("WeaponBone_" + bone_name.replace("-", "_"), true, false)
	if attachment == null:
		return null
	# 弓的挂点下多了 WeaponHand/WeaponAim 两层，不能再假设武器是 attachment 的第一个子节点。
	var weapon := attachment.find_child("Weapon", true, false)
	if weapon is Node3D:
		return weapon as Node3D
	return null

static func _add_nocked_arrow(bow: Node3D) -> void:
	if bow == null or not is_instance_valid(bow) or bow.has_meta("_wa_nocked_arrow"):
		return
	var scene: PackedScene = load(ARROW_PATH)
	if scene == null:
		return
	var arrow := scene.instantiate() as Node3D
	if arrow == null:
		return
	arrow.name = "NockedArrow"
	arrow.scale = Vector3.ONE * NOCKED_ARROW_SCALE
	arrow.position = NOCKED_ARROW_POS
	arrow.rotation = NOCKED_ARROW_ROT
	bow.add_child(arrow)
	bow.set_meta("_wa_nocked_arrow", arrow)

# 只有手持武器需要程序化动作；攻城器械由 SiegeAttackAnim 专门负责。
static func has_custom_attack(entity_id: int) -> bool:
	return entity_id in BOW_IDS or entity_id in SWORD_IDS or entity_id in SPEAR_IDS

# 怪物/单位攻击时，除了骨骼攻击动作，再给武器本身叠一层动作：
# 弓拉弦后回弹、剑补一记横斩、矛向前突刺、盾轻微前顶。
static func play_attack(entity: Node3D, entity_id: int, swing_duration: float = 0.0) -> void:
	if entity == null or not is_instance_valid(entity) or not has_custom_attack(entity_id):
		return
	if not entity.is_inside_tree():
		return
	var weapon_bone := "arm-left" if entity_id in BOW_IDS else "arm-right"
	var weapon := _find_weapon(entity, weapon_bone)
	if weapon != null:
		if entity_id in BOW_IDS:
			_play_bow_attack(weapon, swing_duration)
		elif entity_id in SPEAR_IDS:
			_play_spear_attack(weapon, swing_duration)
		else:
			_play_sword_attack(weapon, swing_duration)
	var shield_bone := "arm-right" if entity_id in BOW_IDS else "arm-left"
	var shield := _find_weapon(entity, shield_bone)
	if shield != null:
		_play_shield_bump(shield, swing_duration)

static func _weapon_base(weapon: Node3D) -> Array:
	if not weapon.has_meta("_wa_base"):
		weapon.set_meta("_wa_base", [weapon.position, weapon.rotation])
	return weapon.get_meta("_wa_base")

static func _kill_weapon_tween(weapon: Node3D) -> void:
	if not weapon.has_meta("_wa_tween"):
		return
	var old = weapon.get_meta("_wa_tween")
	if old is Tween and old.is_valid():
		old.kill()

static func _begin_weapon_anim(weapon: Node3D) -> Array:
	_kill_weapon_tween(weapon)
	var base := _weapon_base(weapon)
	weapon.position = base[0]
	weapon.rotation = base[1]
	return base

# 武器补间默认按 0.3~0.4 秒设计；实际攻击动作被拉伸到整个攻击冷却，
# 武器也必须按同一倍率放慢，否则手还在抬剑、剑已经劈完了。
static func _period_scale(swing_duration: float, base_duration: float) -> float:
	if swing_duration <= 0.01:
		return 1.0
	return clampf(swing_duration / base_duration, 0.35, 6.0)

static func _play_bow_attack(bow: Node3D, swing_duration: float = 0.0) -> void:
	var base := _begin_weapon_anim(bow)
	var base_pos: Vector3 = base[0]
	var base_rot: Vector3 = base[1]
	var k := _period_scale(swing_duration, 0.32)
	var arrow = bow.get_meta("_wa_nocked_arrow", null)
	# 箭离弦：先隐藏搭在弓上的那支，动作结束再补一支。
	if is_instance_valid(arrow) and arrow is Node3D:
		arrow.visible = false
	var tw := bow.create_tween()
	bow.set_meta("_wa_tween", tw)
	tw.tween_property(bow, "position", base_pos + Vector3(0.0, 0.0, 0.07), 0.07 * k)
	tw.parallel().tween_property(bow, "rotation", base_rot + Vector3(0.10, 0.0, 0.0), 0.07 * k)
	tw.tween_property(bow, "position", base_pos - Vector3(0.0, 0.0, 0.05), 0.05 * k)
	tw.parallel().tween_property(bow, "rotation", base_rot - Vector3(0.05, 0.0, 0.0), 0.05 * k)
	tw.tween_property(bow, "position", base_pos, 0.20 * k)
	tw.parallel().tween_property(bow, "rotation", base_rot, 0.20 * k)
	tw.tween_callback(func() -> void:
		if is_instance_valid(bow) and is_instance_valid(arrow) and arrow is Node3D:
			arrow.visible = true)

static func _play_sword_attack(sword: Node3D, swing_duration: float = 0.0) -> void:
	var base := _begin_weapon_anim(sword)
	var base_pos: Vector3 = base[0]
	var base_rot: Vector3 = base[1]
	var k := _period_scale(swing_duration, 0.35)
	var tw := sword.create_tween()
	sword.set_meta("_wa_tween", tw)
	# 剑只能绕握把旋转，不能靠平移把整把剑“送”出去；否则补间一开始
	# 剑就会离开手心。向前够的距离由手臂攻击动作负责，这里只做手腕的
	# 小幅前压和剑身旋转，保证握把始终贴着骨骼挂点。
	tw.tween_property(sword, "rotation", base_rot + Vector3(-0.24, 0.0, -0.58), 0.07 * k)
	tw.parallel().tween_property(sword, "position", base_pos + Vector3(0.0, 0.02, 0.0), 0.07 * k)
	tw.tween_property(sword, "rotation", base_rot + Vector3(1.35, 0.0, 0.18), 0.10 * k)
	tw.parallel().tween_property(sword, "position", base_pos + Vector3(0.0, -0.01, 0.02), 0.10 * k)
	tw.tween_property(sword, "rotation", base_rot, 0.18 * k)
	tw.parallel().tween_property(sword, "position", base_pos, 0.18 * k)

static func _play_spear_attack(spear: Node3D, swing_duration: float = 0.0) -> void:
	var base := _begin_weapon_anim(spear)
	var base_pos: Vector3 = base[0]
	var base_rot: Vector3 = base[1]
	var k := _period_scale(swing_duration, 0.42)
	var tw := spear.create_tween()
	spear.set_meta("_wa_tween", tw)
	tw.tween_property(spear, "position", base_pos + Vector3(0.0, 0.0, 0.10), 0.08 * k)
	tw.parallel().tween_property(spear, "rotation", base_rot + Vector3(0.12, 0.0, 0.0), 0.08 * k)
	tw.tween_property(spear, "position", base_pos - Vector3(0.0, 0.0, 0.20), 0.10 * k)
	tw.parallel().tween_property(spear, "rotation", base_rot - Vector3(0.08, 0.0, 0.0), 0.10 * k)
	tw.tween_property(spear, "position", base_pos, 0.24 * k)
	tw.parallel().tween_property(spear, "rotation", base_rot, 0.24 * k)

static func _play_shield_bump(shield: Node3D, swing_duration: float = 0.0) -> void:
	var base := _begin_weapon_anim(shield)
	var base_pos: Vector3 = base[0]
	var base_rot: Vector3 = base[1]
	var k := _period_scale(swing_duration, 0.30)
	var tw := shield.create_tween()
	shield.set_meta("_wa_tween", tw)
	tw.tween_property(shield, "position", base_pos - Vector3(0.0, 0.0, 0.09), 0.08 * k)
	tw.tween_property(shield, "position", base_pos, 0.22 * k)
	tw.parallel().tween_property(shield, "rotation", base_rot, 0.22 * k)

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
		weapon_scale: float, grip_offset: Vector3 = Vector3.ZERO,
		aim_forward: bool = false) -> Node3D:
	if not ResourceLoader.exists(path):
		return null
	var scene := load(path)
	if scene == null:
		return null
	var weapon = scene.instantiate()
	if weapon == null:
		return null
	weapon.name = "Weapon"
	weapon.scale = Vector3.ONE * weapon_scale
	# BoneAttachment3D 每帧会被骨骼姿态覆盖，偏移/旋转必须写在武器本身上，
	# 写在 attachment 上会被重置，表现为武器永远卡在肩膀。
	weapon.rotation = rotation
	if skeleton != null and skeleton.find_bone(bone_name) >= 0:
		var attachment := BoneAttachment3D.new()
		attachment.name = "WeaponBone_" + bone_name.replace("-", "_")
		attachment.bone_name = bone_name
		skeleton.add_child(attachment)
		if aim_forward:
			# 手部只提供位置；武器朝向由 WeaponAim 固定到单位正前方。
			var hand := Node3D.new()
			hand.name = "WeaponHand"
			hand.position = offset
			attachment.add_child(hand)
			var pivot := Node3D.new()
			pivot.name = "WeaponAim"
			pivot.set_script(WeaponAim)
			pivot.set("owner_entity", entity)
			pivot.set("hand_marker", hand)
			hand.add_child(pivot)
			weapon.position = grip_offset
			pivot.add_child(weapon)
		else:
			weapon.position = grip_offset + offset
			attachment.add_child(weapon)
	else:
		# 无骨骼模型回退：保持原来的固定挂点，至少不会消失。
		weapon.position = Vector3(0.6, 0.2, 0.0) + grip_offset
		entity.add_child(weapon)
	return weapon as Node3D

class_name CasterAttackAnim
extends RefCounted

# 僧侣/长老/宗师的施法攻击动画。
#
# 这三个是远程法术单位（射程 4~5 米），原来共用近战的 _procedural_attack：
# 整身向前刺出 0.9 米再回抽，看起来就是拿空气捅人，和他们的身份完全不搭。
#
# 这里改成「上举蓄力 → 前送释放 → 阻尼回正」三段式，并在身前放出一颗
# 带颜色的法球飞向目标。法球颜色按兵种区分，和脚下光环同色系。
# 单机 RTSBattleManager 与联机 ClientRenderer 共用。

const CASTER_IDS := [55, 56, 57]

const META_RUNNING := "_caster_atk_running"

# 每个兵种的法术色：僧侣金、长老紫、宗师赤金
const CASTER_COLOR := {
	55: Color(1.0, 0.86, 0.38),
	56: Color(0.74, 0.48, 1.0),
	57: Color(1.0, 0.45, 0.20),
}

static func is_caster(entity_id: int) -> bool:
	return entity_id in CASTER_IDS

static func color_for(entity_id: int) -> Color:
	return CASTER_COLOR.get(entity_id, Color(1.0, 0.86, 0.38))

static func play(entity_id: int, model: Node3D, opts: Dictionary = {}) -> bool:
	if not is_caster(entity_id) or not _valid(model):
		return false
	if bool(model.get_meta(META_RUNNING, false)):
		return false
	model.set_meta(META_RUNNING, true)

	var base_pos: Vector3 = model.position
	var base_rot: Vector3 = model.rotation
	var tw := model.create_tween()

	# 蓄力：身体上抬、后仰，法球在身前凝聚
	tw.set_parallel(true)
	tw.tween_property(model, "position", base_pos + Vector3(0.0, 0.16, 0.14), 0.34) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(model, "rotation:x", base_rot.x + 0.30, 0.34) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

	# 释放：向前送出、低头前压
	tw.chain().set_parallel(true)
	tw.tween_property(model, "position", base_pos + Vector3(0.0, 0.02, -0.24), 0.16) \
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_IN)
	tw.tween_property(model, "rotation:x", base_rot.x - 0.42, 0.16) \
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_IN)

	# 回正
	tw.chain().set_parallel(true)
	tw.tween_property(model, "position", base_pos, 0.44) \
		.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(model, "rotation:x", base_rot.x, 0.44) \
		.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)

	# 出手瞬间才放法球：太早会和蓄力姿态脱节
	var tree := model.get_tree()
	if tree != null:
		var timer := tree.create_timer(0.34)
		timer.timeout.connect(func() -> void: _fire_mote(entity_id, model, opts))

	var finish := tree.create_timer(1.0) if tree != null else null
	if finish != null:
		finish.timeout.connect(func() -> void:
			if _valid(model):
				model.set_meta(META_RUNNING, false))
	return true

# 身前放出一颗发光法球飞向目标方向，命中处散开一圈细碎光点。
static func _fire_mote(entity_id: int, model: Node3D, opts: Dictionary) -> void:
	if not _valid(model):
		return
	var root := model.get_tree().current_scene as Node3D
	if root == null:
		return
	var color: Color = color_for(entity_id)

	var fwd: Vector3 = -model.global_transform.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.01:
		fwd = Vector3.FORWARD
	fwd = fwd.normalized()
	var range_m: float = float(opts.get("range", 4.5))
	var origin: Vector3 = model.global_position + fwd * 0.5 + Vector3.UP * 1.0

	var mote := MeshInstance3D.new()
	mote.name = "CasterMote"
	var sphere := SphereMesh.new()
	sphere.radius = 0.13
	sphere.height = 0.26
	mote.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 3.0
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mote.material_override = mat
	mote.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mote)
	mote.global_position = origin

	var end_pos: Vector3 = origin + fwd * range_m + Vector3.UP * 0.15
	var tw := mote.create_tween()
	tw.set_parallel(true)
	tw.tween_property(mote, "global_position", end_pos, 0.38) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_property(mote, "scale", Vector3.ONE * 1.8, 0.38)
	tw.chain().tween_callback(func() -> void:
		if is_instance_valid(mote):
			_spawn_burst(root, mote.global_position, color)
			mote.queue_free())

# 命中处的扩散光点：数量少、寿命短，几十个单位同时开火也不会堆出成百上千个粒子
static func _spawn_burst(root: Node3D, pos: Vector3, color: Color) -> void:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.amount = 8
	p.lifetime = 0.42
	p.explosiveness = 0.95
	p.local_coords = false
	p.spread = 180.0
	p.initial_velocity_min = 1.0
	p.initial_velocity_max = 2.2
	p.gravity = Vector3(0.0, 2.0, 0.0)
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.5
	p.visibility_aabb = AABB(Vector3(-4, -4, -4), Vector3(8, 8, 8))
	var quad := QuadMesh.new()
	quad.size = Vector2(0.22, 0.22)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 2.2
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	quad.material = mat
	p.mesh = quad
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1, 1, 1, 1))
	ramp.set_color(1, Color(1, 1, 1, 0))
	p.color_ramp = ramp
	root.add_child(p)
	p.global_position = pos
	p.emitting = true
	var timer := p.get_tree().create_timer(p.lifetime + 0.4)
	timer.timeout.connect(func() -> void:
		if is_instance_valid(p):
			p.queue_free())

static func _valid(model: Node3D) -> bool:
	return model != null and is_instance_valid(model) and model.is_inside_tree()

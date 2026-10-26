class_name CasterAttackAnim
extends Node3D

# 僧侣(55)/长老(56)/宗师(57) 的法术弹攻击。
#
# 这三个单位没有实体子弹，但也不应该“隔空结算”：施法时从法杖/身前射出一枚
# 带兵种颜色、弹头指向目标的法术弹，飞到目标身上再结算治疗/伤害/降攻，
# 命中点同时播放对应的法术特效。伤害结算仍在 Army 里，通过 on_impact 回调完成，
# 所以视觉飞行时间和实际生效时间一致，不会出现“目标已经掉血，法术弹还在半路”。
#
# 三种命中特效都从目标身高一半处（胸口/腰腹）展开，不再贴着脚底：
#   僧侣：绿色加号环绕治疗，配合半身高度的治疗光环；
#   长老：紫色灵魂法阵 + 上升的晶片/灵魂光柱，表现“抽离生命”；
#   宗师：赤金王印 + 降下的锁链/王冠，表现“压制与招降”。

const CASTER_IDS: Array[int] = [55, 56, 57]

# 与 CasterMarker 同色系；僧侣用治疗绿，不再用原来的金色。
const CASTER_COLOR := {
	55: Color(0.30, 1.00, 0.45),
	56: Color(0.58, 0.32, 1.00),
	57: Color(1.00, 0.36, 0.12),
}

const BOLT_SPEED: float = 15.0
const IMPACT_DISTANCE: float = 0.38

var _entity_id: int = 55
var _target: Node3D = null
var _source: Node3D = null
var _on_impact: Callable = Callable()
var _root: Node3D = null
var _color: Color = Color.WHITE
var _last_target_pos: Vector3 = Vector3.ZERO
var _last_impact_pos: Vector3 = Vector3.ZERO
var _visual: Node3D = null
var _core: MeshInstance3D = null
var _tail_fins: Array[MeshInstance3D] = []
var _rune_holder: Node3D = null
var _elapsed: float = 0.0
var _done: bool = false

static func is_caster(entity_id: int) -> bool:
	return entity_id in CASTER_IDS

static func color_for(entity_id: int) -> Color:
	return CASTER_COLOR.get(entity_id, Color(1.0, 0.86, 0.38))

# 从 source 向 target 发射法术弹；到达后调用 on_impact()，并播放命中特效。
# on_impact 返回 Dictionary 时可带 "converted": true，用于播放宗师招降的额外金光。
static func cast(entity_id: int, source: Node3D, target: Node3D, on_impact: Callable) -> bool:
	if not is_caster(entity_id) or not _valid(source) or not _valid(target):
		return false
	var tree := source.get_tree()
	if tree == null:
		return false
	var root := tree.current_scene as Node3D
	if root == null or not is_instance_valid(root):
		return false

	var bolt := CasterAttackAnim.new()
	bolt.name = "CasterSpellBolt"
	bolt._entity_id = entity_id
	bolt._source = source
	bolt._target = target
	bolt._on_impact = on_impact
	bolt._root = root
	bolt._color = color_for(entity_id)
	bolt._last_impact_pos = _body_center(target)
	bolt._last_target_pos = _body_center(target)
	bolt._build_visual()
	root.add_child(bolt)
	bolt.global_position = _muzzle_position(source)
	return true

# 联机客户端没有真实目标引用，只能按朝向和射程放一枚视觉法术弹。
# 落点用临时 Node3D 代理，命中后自动释放，不参与任何伤害结算。
static func cast_point(entity_id: int, source: Node3D, end_pos: Vector3) -> bool:
	if not is_caster(entity_id) or not _valid(source):
		return false
	var tree := source.get_tree()
	if tree == null:
		return false
	var root := tree.current_scene as Node3D
	if root == null or not is_instance_valid(root):
		return false
	var proxy := Node3D.new()
	proxy.name = "CasterSpellTarget"
	root.add_child(proxy)
	proxy.global_position = end_pos
	var ok: bool = cast(entity_id, source, proxy, func() -> Dictionary:
		if is_instance_valid(proxy):
			proxy.queue_free()
		return {})
	if not ok and is_instance_valid(proxy):
		proxy.queue_free()
	return ok

# 目标身高一半附近（胸口/腰腹）。所有命中特效都从这里展开，不能贴脚底。
static func _body_center(target: Node3D) -> Vector3:
	var radius: float = 0.4
	if target is GameEntity:
		radius = (target as GameEntity).body_radius
	return target.global_position + Vector3.UP * maxf(0.85, radius * 1.7)

static func _muzzle_position(source: Node3D) -> Vector3:
	var fwd: Vector3 = -source.global_transform.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.01:
		fwd = Vector3.FORWARD
	var radius: float = 0.4
	if source is GameEntity:
		radius = (source as GameEntity).body_radius
	return source.global_position + fwd.normalized() * (radius + 0.45) + Vector3.UP * 1.05

func _build_visual() -> void:
	_visual = Node3D.new()
	_visual.name = "BoltVisual"
	add_child(_visual)

	var glow_mat := _make_material(_color, 0.95, 4.6)
	var core_mesh := SphereMesh.new()
	core_mesh.radius = 0.155
	core_mesh.height = 0.31
	core_mesh.radial_segments = 12
	core_mesh.rings = 6
	_core = MeshInstance3D.new()
	_core.mesh = core_mesh
	_core.material_override = glow_mat
	_core.position = Vector3(0.0, 0.0, 0.02)
	_core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_visual.add_child(_core)

	# 弹头：细长光锥指向正前方（-Z），look_at 后正好指着目标。
	var tip := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.105
	cone.height = 0.30
	cone.radial_segments = 10
	tip.mesh = cone
	tip.material_override = _make_material(_color.lightened(0.18), 0.95, 4.2)
	tip.rotation.x = -PI * 0.5
	tip.position = Vector3(0.0, 0.0, -0.19)
	tip.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_visual.add_child(tip)

	# 尾部四片小尾翼 + 一圈尾焰：让弹体有明确的飞行朝向，而不是一团光。
	for i in range(4):
		var fin := MeshInstance3D.new()
		var fin_box := BoxMesh.new()
		fin_box.size = Vector3(0.035, 0.22, 0.13)
		fin.mesh = fin_box
		fin.material_override = _make_material(_color, 0.82, 2.8)
		var ang: float = TAU * float(i) / 4.0
		fin.position = Vector3(cos(ang) * 0.10, sin(ang) * 0.10, 0.17)
		fin.rotation.z = ang + PI * 0.5
		fin.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_visual.add_child(fin)
		_tail_fins.append(fin)

	var tail_ring := MeshInstance3D.new()
	var tail_torus := TorusMesh.new()
	tail_torus.inner_radius = 0.10
	tail_torus.outer_radius = 0.15
	tail_torus.rings = 20
	tail_torus.ring_segments = 5
	tail_ring.mesh = tail_torus
	tail_ring.material_override = _make_material(_color, 0.55, 3.0)
	tail_ring.rotation.x = PI * 0.5
	tail_ring.position = Vector3(0.0, 0.0, 0.24)
	tail_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_visual.add_child(tail_ring)
	_tail_fins.append(tail_ring)

	# 长老用绕飞的菱形符文，宗师用方形王印框；僧侣保持纯净的弹体。
	if _entity_id == 56:
		_rune_holder = Node3D.new()
		_rune_holder.name = "ElderRunes"
		_visual.add_child(_rune_holder)
		for i in range(3):
			var rune := MeshInstance3D.new()
			var box := BoxMesh.new()
			box.size = Vector3(0.11, 0.11, 0.035)
			rune.mesh = box
			rune.material_override = glow_mat
			rune.rotation.z = PI * 0.25
			var ang: float = TAU * float(i) / 3.0
			rune.position = Vector3(cos(ang) * 0.34, sin(ang) * 0.34, 0.02)
			rune.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_rune_holder.add_child(rune)
	elif _entity_id == 57:
		_rune_holder = Node3D.new()
		_rune_holder.name = "GrandmasterSeal"
		_visual.add_child(_rune_holder)
		for i in range(4):
			var bar := MeshInstance3D.new()
			var box := BoxMesh.new()
			box.size = Vector3(0.36, 0.055, 0.035)
			bar.mesh = box
			bar.material_override = glow_mat
			var ang: float = TAU * float(i) / 4.0
			bar.position = Vector3(cos(ang) * 0.28, sin(ang) * 0.28, 0.0)
			bar.rotation.z = ang + PI * 0.5
			bar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_rune_holder.add_child(bar)

	_attach_trail()

func _attach_trail() -> void:
	var trail := CPUParticles3D.new()
	trail.name = "SpellTrail"
	trail.amount = 18
	trail.lifetime = 0.28
	# 粒子跟着弹体局部坐标向后喷，弹体转向时尾迹也跟着转向。
	trail.local_coords = true
	trail.emitting = true
	trail.direction = Vector3(0.0, 0.0, 1.0)
	trail.spread = 28.0
	trail.initial_velocity_min = 0.8
	trail.initial_velocity_max = 1.6
	trail.gravity = Vector3.ZERO
	trail.scale_amount_min = 0.4
	trail.scale_amount_max = 0.8
	trail.visibility_aabb = AABB(Vector3(-3.0, -3.0, -3.0), Vector3(6.0, 6.0, 6.0))
	var quad := QuadMesh.new()
	quad.size = Vector2(0.14, 0.14)
	var mat := _make_material(_color, 0.9, 3.0)
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	quad.material = mat
	trail.mesh = quad
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1, 1, 1, 0.95))
	ramp.set_color(1, Color(1, 1, 1, 0.0))
	trail.color_ramp = ramp
	add_child(trail)

func _process(delta: float) -> void:
	if _done:
		return
	_elapsed += delta
	if is_instance_valid(_target):
		_last_impact_pos = _body_center(_target)
		_last_target_pos = _last_impact_pos

	var to_target: Vector3 = _last_target_pos - global_position
	var dist: float = to_target.length()
	var step: float = BOLT_SPEED * delta
	if dist <= maxf(IMPACT_DISTANCE, step):
		global_position = _last_target_pos
		_finish()
		return
	if dist < 0.001:
		_finish()
		return

	var dir: Vector3 = to_target / dist
	global_position += dir * step
	if dir.length_squared() > 0.0001:
		# 弹头始终指向飞行方向；目标在正上方/正下方时用 FORWARD 当临时 up，
		# 避免 look_at 的 up 与 forward 平行导致朝向失效。
		var look_up := Vector3.UP
		if absf(dir.normalized().dot(look_up)) > 0.98:
			look_up = Vector3.FORWARD
		look_at(global_position + dir, look_up)

	# 飞行途中让核心轻微搏动、尾环轻微呼吸，避免看起来像一颗死弹丸。
	if _core != null and is_instance_valid(_core):
		var pulse: float = 1.0 + sin(_elapsed * 18.0) * 0.14
		_core.scale = Vector3.ONE * pulse
	for i in range(_tail_fins.size()):
		var fin: MeshInstance3D = _tail_fins[i]
		if fin != null and is_instance_valid(fin) and i == _tail_fins.size() - 1:
			fin.scale = Vector3.ONE * (1.0 + sin(_elapsed * 13.0) * 0.12)
	if _rune_holder != null and is_instance_valid(_rune_holder):
		_rune_holder.rotation.z = -_elapsed * 7.0

func _finish() -> void:
	if _done:
		return
	_done = true
	var result: Dictionary = {}
	if _on_impact.is_valid():
		var ret = _on_impact.call()
		if ret is Dictionary:
			result = ret
	_spawn_impact(result)
	queue_free()

func _spawn_impact(result: Dictionary) -> void:
	if _root == null or not is_instance_valid(_root):
		return
	# 命中特效统一从目标身高一半处展开，而不是脚底。
	var center: Vector3 = _last_impact_pos
	match _entity_id:
		55:
			_impact_monk(center)
		56:
			_impact_elder(center)
		57:
			_impact_grandmaster(center, bool(result.get("converted", false)))

# ── 僧侣：绿色治疗加号 ─────────────────────────────────────────────
func _impact_monk(center: Vector3) -> void:
	var ring := _make_ring(center, _color, 0.72, 0.11)
	var ring_mat := ring.material_override as StandardMaterial3D
	var ring_tw := _root.create_tween()
	ring_tw.set_parallel(true)
	ring_tw.tween_property(ring, "scale", Vector3.ONE * 1.55, 0.65) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	ring_tw.tween_property(ring_mat, "albedo_color", _alpha(_color, 0.0), 0.65)
	ring_tw.chain().tween_callback(ring.queue_free)

	# 六枚绿色加号围绕目标半身高处展开，大小错开，形成“治疗弹开”的层次。
	for i in range(6):
		var ang: float = TAU * float(i) / 6.0 + 0.25
		var radius: float = 0.62 + float(i % 3) * 0.16
		var plus := _make_plus_mark(_color)
		var mat: StandardMaterial3D = plus.get_meta("mat")
		plus.position = center + Vector3(cos(ang) * radius, 0.06 + float(i % 3) * 0.10, sin(ang) * radius)
		plus.scale = Vector3.ONE * 0.12
		_root.add_child(plus)

		var tw := _root.create_tween()
		tw.set_parallel(true)
		tw.tween_property(plus, "scale", Vector3.ONE * (0.85 + float(i % 2) * 0.22), 0.20) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tw.tween_property(plus, "position", plus.position + Vector3.UP * (0.45 + float(i % 3) * 0.14), 0.72) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tw.tween_property(mat, "albedo_color", _alpha(_color, 0.0), 0.72)
		tw.chain().tween_callback(plus.queue_free)

	_spawn_sparkles(_root, center + Vector3.UP * 0.05, _color, 12, 0.65, 1.2, 2.6)

# ── 长老：紫色灵魂法阵、晶片与回流灵魂 ───────────────────────────────
func _impact_elder(center: Vector3) -> void:
	var ring := _make_ring(center, _color, 0.82, 0.10)
	var ring_mat := ring.material_override as StandardMaterial3D
	var ring_tw := _root.create_tween()
	ring_tw.set_parallel(true)
	ring_tw.tween_property(ring, "scale", Vector3.ONE * 0.42, 0.55) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	ring_tw.tween_property(ring_mat, "albedo_color", _alpha(_color, 0.0), 0.55)
	ring_tw.chain().tween_callback(ring.queue_free)

	# 法阵上的六根辐条：先向外展开，再随法阵一起收束。
	for i in range(6):
		var ang: float = TAU * float(i) / 6.0
		var bar := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.52, 0.025, 0.035)
		bar.mesh = box
		bar.material_override = _make_material(_color, 0.85, 2.2)
		bar.position = center + Vector3(cos(ang) * 0.72, 0.04, sin(ang) * 0.72)
		bar.rotation.y = -ang
		bar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_root.add_child(bar)
		var bar_mat := bar.material_override as StandardMaterial3D
		var tw := _root.create_tween()
		tw.set_parallel(true)
		tw.tween_property(bar, "position", center + Vector3(cos(ang) * 0.34, 0.04, sin(ang) * 0.34), 0.55) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tw.tween_property(bar_mat, "albedo_color", _alpha(_color, 0.0), 0.55)
		tw.chain().tween_callback(bar.queue_free)

	# 半透明灵魂光柱：从地面升起后迅速消散，表现生命力被抽离。
	var pillar := MeshInstance3D.new()
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 0.34
	cylinder.bottom_radius = 0.42
	cylinder.height = 2.4
	cylinder.radial_segments = 10
	pillar.mesh = cylinder
	pillar.material_override = _make_material(_color, 0.20, 1.6)
	pillar.position = center + Vector3.UP * 1.2
	pillar.scale = Vector3(1.0, 0.05, 1.0)
	pillar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_root.add_child(pillar)
	var pillar_mat := pillar.material_override as StandardMaterial3D
	var pillar_tw := _root.create_tween()
	pillar_tw.tween_property(pillar, "scale", Vector3(1.0, 1.0, 1.0), 0.18) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	pillar_tw.parallel().tween_property(pillar_mat, "albedo_color", _alpha(_color, 0.0), 0.55) \
		.set_delay(0.12)
	pillar_tw.chain().tween_callback(pillar.queue_free)

	# 晶片从四周向目标汇聚并上浮，像被抽走的灵魂碎片。
	for i in range(7):
		var ang: float = TAU * float(i) / 7.0 + 0.2
		var shard := MeshInstance3D.new()
		var gem := SphereMesh.new()
		gem.radius = 0.075
		gem.height = 0.20
		gem.radial_segments = 4
		gem.rings = 2
		shard.mesh = gem
		shard.material_override = _make_material(_color, 0.9, 3.0)
		shard.position = center + Vector3(cos(ang) * 0.95, 0.04, sin(ang) * 0.95)
		shard.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_root.add_child(shard)
		var shard_mat := shard.material_override as StandardMaterial3D
		var tw := _root.create_tween()
		tw.set_parallel(true)
		tw.tween_property(shard, "position",
			center + Vector3(cos(ang) * 0.30, 0.45 + float(i % 3) * 0.22, sin(ang) * 0.30), 0.55) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tw.tween_property(shard, "scale", Vector3(0.2, 0.2, 0.2), 0.55)
		tw.tween_property(shard_mat, "albedo_color", _alpha(_color, 0.0), 0.55)
		tw.chain().tween_callback(shard.queue_free)

	# 三颗灵魂光点飞回施法者：如果长老在飞行途中死亡则只在原地消散。
	if is_instance_valid(_source):
		for i in range(3):
			var orb := MeshInstance3D.new()
			var sphere := SphereMesh.new()
			sphere.radius = 0.06
			sphere.height = 0.12
			orb.mesh = sphere
			orb.material_override = _make_material(_color.lightened(0.25), 0.95, 3.8)
			orb.position = center + Vector3(0.0, 0.10 + float(i) * 0.12, 0.0)
			orb.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_root.add_child(orb)
			var orb_mat := orb.material_override as StandardMaterial3D
			var tw := _root.create_tween()
			tw.set_parallel(true)
			tw.tween_property(orb, "position", _body_center(_source), 0.38 + float(i) * 0.06) \
				.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
			tw.tween_property(orb_mat, "albedo_color", _alpha(_color, 0.0), 0.42 + float(i) * 0.06)
			tw.chain().tween_callback(orb.queue_free)

	_spawn_sparkles(_root, center + Vector3.UP * 0.2, _color, 10, 0.7, 0.5, 1.5)

# ── 宗师：赤金王印、锁链与招降王冠 ──────────────────────────────────
func _impact_grandmaster(center: Vector3, converted: bool) -> void:
	var ring := _make_ring(center, _color, 0.90, 0.11)
	var ring_mat := ring.material_override as StandardMaterial3D
	var ring_tw := _root.create_tween()
	ring_tw.set_parallel(true)
	ring_tw.tween_property(ring, "scale", Vector3.ONE * 1.75, 0.55) \
		.set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	ring_tw.tween_property(ring_mat, "albedo_color", _alpha(_color, 0.0), 0.55)
	ring_tw.chain().tween_callback(ring.queue_free)

	# 四道锁链从半身高度上方向下压到目标周围；用细长金柱表现“压制”。
	for i in range(4):
		var ang: float = TAU * float(i) / 4.0 + PI * 0.25
		var chain := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.075, 2.1, 0.075)
		chain.mesh = box
		chain.material_override = _make_material(_color.lightened(0.18), 0.9, 2.8)
		chain.position = center + Vector3(cos(ang) * 0.86, 2.2, sin(ang) * 0.86)
		chain.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_root.add_child(chain)
		var chain_mat := chain.material_override as StandardMaterial3D
		var tw := _root.create_tween()
		tw.set_parallel(true)
		tw.tween_property(chain, "position",
			center + Vector3(cos(ang) * 0.78, 0.10, sin(ang) * 0.78), 0.20) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tw.tween_property(chain_mat, "albedo_color", _alpha(_color, 0.0), 0.58) \
			.set_delay(0.16)
		tw.chain().tween_callback(chain.queue_free)

	# 悬浮王冠：一圈金环 + 五个向上的冠齿，缓慢旋转后升空消失。
	var crown := Node3D.new()
	crown.name = "GrandmasterCrown"
	var crown_mat := _make_material(_color.lightened(0.28), 0.95, 3.6)
	var crown_ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.22
	torus.outer_radius = 0.29
	torus.rings = 24
	torus.ring_segments = 5
	crown_ring.mesh = torus
	crown_ring.material_override = crown_mat
	crown_ring.rotation.x = PI * 0.5
	crown_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	crown.add_child(crown_ring)
	for i in range(5):
		var prong := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.055, 0.20 + float(i % 2) * 0.08, 0.04)
		prong.mesh = box
		prong.material_override = crown_mat
		var ang: float = TAU * float(i) / 5.0
		prong.position = Vector3(cos(ang) * 0.255, 0.13, sin(ang) * 0.255)
		prong.rotation.z = -ang
		prong.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		crown.add_child(prong)
	crown.position = center + Vector3.UP * 1.55
	crown.scale = Vector3.ONE * 0.25
	_root.add_child(crown)
	var crown_tw := _root.create_tween()
	crown_tw.set_parallel(true)
	crown_tw.tween_property(crown, "position", center + Vector3.UP * 0.85, 0.28) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	crown_tw.tween_property(crown, "scale", Vector3.ONE * 1.0, 0.28) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	crown_tw.tween_property(crown_mat, "albedo_color", _alpha(_color.lightened(0.28), 0.0), 0.60) \
		.set_delay(0.24)
	crown_tw.chain().tween_callback(crown.queue_free)

	# 招降成功时再加一圈金色扩散和更密的粒子，和普通降攻区分开。
	if converted:
		var convert_ring := _make_ring(center, Color(1.0, 0.88, 0.35), 1.05, 0.08)
		var cmat := convert_ring.material_override as StandardMaterial3D
		var ctw := _root.create_tween()
		ctw.set_parallel(true)
		ctw.tween_property(convert_ring, "scale", Vector3.ONE * 2.4, 0.7) \
			.set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
		ctw.tween_property(cmat, "albedo_color", _alpha(Color(1.0, 0.88, 0.35), 0.0), 0.7)
		ctw.chain().tween_callback(convert_ring.queue_free)
		_spawn_sparkles(_root, center + Vector3.UP * 0.10, Color(1.0, 0.82, 0.30), 22, 0.85, 1.8, 4.2)
	else:
		_spawn_sparkles(_root, center + Vector3.UP * 0.05, _color, 12, 0.65, 1.0, 2.6)

# ── 通用特效工具 ────────────────────────────────────────────────────
func _make_ring(center: Vector3, color: Color, radius: float, tube: float) -> MeshInstance3D:
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = radius - tube
	torus.outer_radius = radius + tube
	torus.rings = 40
	torus.ring_segments = 5
	ring.mesh = torus
	ring.material_override = _make_material(color, 0.9, 2.6)
	# 环面保持水平，但中心抬到目标半身高处。
	ring.position = center
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_root.add_child(ring)
	return ring

func _make_plus_mark(color: Color) -> Node3D:
	var plus := Node3D.new()
	plus.name = "HealPlus"
	var mat := _make_material(color, 0.95, 3.2)
	var h := MeshInstance3D.new()
	var h_box := BoxMesh.new()
	h_box.size = Vector3(0.42, 0.10, 0.035)
	h.mesh = h_box
	h.material_override = mat
	h.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	plus.add_child(h)
	var v := MeshInstance3D.new()
	var v_box := BoxMesh.new()
	v_box.size = Vector3(0.10, 0.42, 0.035)
	v.mesh = v_box
	v.material_override = mat
	v.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	plus.add_child(v)
	plus.set_meta("mat", mat)
	return plus

func _spawn_sparkles(root: Node3D, pos: Vector3, color: Color, amount: int,
		lifetime: float, speed_min: float, speed_max: float) -> void:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.amount = amount
	p.lifetime = lifetime
	p.explosiveness = 0.9
	p.local_coords = false
	p.spread = 180.0
	p.initial_velocity_min = speed_min
	p.initial_velocity_max = speed_max
	p.gravity = Vector3(0.0, 1.2, 0.0)
	p.scale_amount_min = 0.5
	p.scale_amount_max = 1.2
	p.visibility_aabb = AABB(Vector3(-5.0, -5.0, -5.0), Vector3(10.0, 10.0, 10.0))
	var quad := QuadMesh.new()
	quad.size = Vector2(0.14, 0.14)
	var mat := _make_material(color, 0.95, 2.8)
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	quad.material = mat
	p.mesh = quad
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1, 1, 1, 1.0))
	ramp.set_color(1, Color(1, 1, 1, 0.0))
	p.color_ramp = ramp
	root.add_child(p)
	p.global_position = pos
	p.emitting = true
	var timer := root.get_tree().create_timer(lifetime + 0.4)
	timer.timeout.connect(func() -> void:
		if is_instance_valid(p):
			p.queue_free())

func _make_material(color: Color, alpha: float, energy: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = _alpha(color, alpha)
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = energy
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat

func _alpha(color: Color, alpha: float) -> Color:
	return Color(color.r, color.g, color.b, alpha)

static func _valid(node: Node3D) -> bool:
	return node != null and is_instance_valid(node) and node.is_inside_tree()

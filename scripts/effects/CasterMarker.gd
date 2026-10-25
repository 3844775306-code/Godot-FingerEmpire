class_name CasterMarker
extends Node3D

# 僧侣(55)/长老(56)/宗师(57) 的战场标识。
#
# 这三个兵种和农民共用「随机人物模型」，光看身材和衣服在混战里分不出来。
# 而且以前客户端（联机）根本没给它们挂任何标识，只有单机服务端有光环，
# 联机时更加认不出来。这里统一做一套服务端 / 客户端共用的标识：
#   1. 脚下双层法阵：外环慢转、内环绕反方向快转，俯视视角一眼可见；
#   2. 头顶悬浮职业符号：十字(僧侣) / 法轮(长老) / 菱晶(宗师)，
#      单位站在建筑后面、模型被挡住时也能看见。
# 全部动画在本节点的 _process 里跑，Army 不需要每帧再调用。

const CASTER_IDS: Array[int] = [55, 56, 57]

# 与 CasterAttackAnim.CASTER_COLOR 同色系，法球和标识颜色对得上
const CASTER_COLOR := {
	55: Color(1.0, 0.86, 0.38),   # 僧侣：金
	56: Color(0.74, 0.48, 1.0),   # 长老：紫
	57: Color(1.0, 0.45, 0.20),   # 宗师：赤金
}

var _ring_outer: MeshInstance3D = null
var _ring_inner: MeshInstance3D = null
var _glyph: Node3D = null
var _base_height: float = 1.5
var _time: float = 0.0

static func is_caster(entity_id: int) -> bool:
	return entity_id in CASTER_IDS

static func color_for(entity_id: int) -> Color:
	return CASTER_COLOR.get(entity_id, Color(1.0, 0.86, 0.38))

static func create(entity_id: int, body_radius: float) -> CasterMarker:
	var marker := CasterMarker.new()
	marker.name = "CasterMarker"
	marker._build(entity_id, body_radius)
	return marker

func _build(entity_id: int, body_radius: float) -> void:
	var color: Color = color_for(entity_id)
	# 环半径比原来的 1.25~1.75 倍大一截：俯视角下原来那圈只有 0.5 米，
	# 旁边站两个人就完全看不见了。
	_ring_outer = _make_ring(body_radius * 2.60, body_radius * 3.05, color, 0.55, 0.07)
	add_child(_ring_outer)
	_ring_inner = _make_ring(body_radius * 1.50, body_radius * 1.86, color, 0.75, 0.11)
	add_child(_ring_inner)

	_base_height = maxf(1.45, body_radius * 3.2)
	_glyph = _make_glyph(entity_id, body_radius, color)
	if _glyph != null:
		_glyph.position = Vector3(0.0, _base_height, 0.0)
		add_child(_glyph)

func _make_ring(inner_r: float, outer_r: float, color: Color, alpha: float, y: float) -> MeshInstance3D:
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = inner_r
	torus.outer_radius = outer_r
	torus.rings = 36
	torus.ring_segments = 5
	ring.mesh = torus
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(color.r, color.g, color.b, alpha)
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 1.8
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	ring.material_override = mat
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ring.position = Vector3(0.0, y, 0.0)
	return ring

# 头顶符号：三个兵种各用一种几何体，形状差异比颜色差异更容易在远处分辨
func _make_glyph(entity_id: int, body_radius: float, color: Color) -> Node3D:
	var holder := Node3D.new()
	holder.name = "CasterGlyph"
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 2.6
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var size: float = maxf(0.16, body_radius * 0.62)

	if entity_id == 55:
		# 僧侣：十字
		var v := _make_box(Vector3(size * 0.26, size * 1.10, size * 0.26), mat)
		holder.add_child(v)
		var h := _make_box(Vector3(size * 0.80, size * 0.26, size * 0.26), mat)
		h.position = Vector3(0.0, size * 0.22, 0.0)
		holder.add_child(h)
	elif entity_id == 56:
		# 长老：法轮（两个细环垂直交叉）
		for i in range(2):
			var ring := MeshInstance3D.new()
			var torus := TorusMesh.new()
			torus.inner_radius = size * 0.52
			torus.outer_radius = size * 0.72
			torus.rings = 20
			torus.ring_segments = 4
			ring.mesh = torus
			ring.material_override = mat
			ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			ring.rotation.x = deg_to_rad(90.0)
			ring.rotation.z = deg_to_rad(90.0 if i == 1 else 0.0)
			holder.add_child(ring)
	else:
		# 宗师：菱形晶石（低分段球体做出八面体观感）
		var gem := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = size * 0.55
		sphere.height = size * 1.30
		sphere.radial_segments = 4
		sphere.rings = 2
		gem.mesh = sphere
		gem.material_override = mat
		gem.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		holder.add_child(gem)
	return holder

func _make_box(size: Vector3, mat: Material) -> MeshInstance3D:
	var box := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	box.mesh = mesh
	box.material_override = mat
	box.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return box

func _process(delta: float) -> void:
	_time += delta
	# 外环慢转、内环反向快转：两圈相对运动才看得出"法阵在运转"
	if _ring_outer != null and is_instance_valid(_ring_outer):
		_ring_outer.rotation.y = _time * 0.55
		var pulse: float = 1.0 + sin(_time * 1.9) * 0.05
		_ring_outer.scale = Vector3(pulse, 1.0, pulse)
	if _ring_inner != null and is_instance_valid(_ring_inner):
		_ring_inner.rotation.y = -_time * 1.35
	if _glyph != null and is_instance_valid(_glyph):
		_glyph.rotation.y = _time * 1.6
		_glyph.position.y = _base_height + sin(_time * 2.4) * 0.07

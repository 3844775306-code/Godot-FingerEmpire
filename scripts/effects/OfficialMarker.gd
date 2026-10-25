class_name OfficialMarker
extends Node3D

# 官员（46-50）与农民共用同一套「随机人物模型」，只看衣服和脸很难在
# 混战里分辨。这里给官员加一套与农民完全不同的金色标识：
#   1. 脚下金色圆环，保证从俯视视角一眼看到；
#   2. 头顶悬浮旋转的金色菱形，即使官员站在建筑顶上、模型被遮挡也能看见。
# 服务端 Army 和联机 ClientRenderer 共用本脚本，保证单机/联机外观一致。

const OFFICIAL_IDS: Array[int] = [46, 47, 48, 49, 50]
const GOLD: Color = Color(1.0, 0.78, 0.16)
const GOLD_LIGHT: Color = Color(1.0, 0.9, 0.45)

var _diamond: MeshInstance3D = null
var _ring: MeshInstance3D = null
var _base_height: float = 1.7
var _time: float = 0.0

static func is_official(entity_id: int) -> bool:
	return entity_id in OFFICIAL_IDS

static func create(body_radius: float) -> OfficialMarker:
	var marker := OfficialMarker.new()
	marker.name = "OfficialMarker"
	marker._build(body_radius)
	return marker

func _build(body_radius: float) -> void:
	# 人物模型缩放后高度约 0.75~0.85 米；标识略高于头顶，既不会被模型挡住，
	# 也不会飘得太高显得脱离单位。统帅体型更大，按 body_radius 等比抬高。
	_base_height = maxf(1.05, body_radius * 2.6)

	var ring := MeshInstance3D.new()
	ring.name = "OfficialRing"
	var torus := TorusMesh.new()
	torus.inner_radius = maxf(0.24, body_radius * 1.35)
	torus.outer_radius = maxf(0.34, body_radius * 1.75)
	torus.rings = 28
	torus.ring_segments = 5
	ring.mesh = torus
	var ring_mat := StandardMaterial3D.new()
	ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring_mat.albedo_color = Color(GOLD.r, GOLD.g, GOLD.b, 0.62)
	ring_mat.emission_enabled = true
	ring_mat.emission = GOLD
	ring_mat.emission_energy_multiplier = 1.5
	ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ring_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	ring.material_override = ring_mat
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ring.position = Vector3(0.0, 0.08, 0.0)
	add_child(ring)
	_ring = ring

	var diamond := MeshInstance3D.new()
	diamond.name = "OfficialDiamond"
	var gem := BoxMesh.new()
	gem.size = Vector3.ONE * maxf(0.18, body_radius * 0.5)
	diamond.mesh = gem
	diamond.rotation = Vector3(deg_to_rad(45.0), deg_to_rad(45.0), 0.0)
	var gem_mat := StandardMaterial3D.new()
	gem_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	gem_mat.albedo_color = GOLD_LIGHT
	gem_mat.emission_enabled = true
	gem_mat.emission = GOLD
	gem_mat.emission_energy_multiplier = 2.4
	diamond.material_override = gem_mat
	diamond.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	diamond.position = Vector3(0.0, _base_height, 0.0)
	add_child(diamond)
	_diamond = diamond

func _process(delta: float) -> void:
	_time += delta
	if _diamond != null and is_instance_valid(_diamond):
		_diamond.rotation.y = deg_to_rad(45.0) + _time * 2.0
		_diamond.position.y = _base_height + sin(_time * 2.6) * 0.06
	if _ring != null and is_instance_valid(_ring):
		var pulse: float = 1.0 + sin(_time * 2.2) * 0.05
		_ring.scale = Vector3(pulse, 1.0, pulse)

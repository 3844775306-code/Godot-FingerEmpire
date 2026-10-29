class_name MerchantMarker
extends Node3D

# 商人（43 油商 / 44 木商 / 45 石商 / 51 食商）与农民共用同一套人物骨骼和体型，
# 即使模型池已经分开，混战里仍然很难一眼认出谁是商人。这里给商人加一套
# 独立于官员、法师的视觉标识：
#   1. 脚下青色圆环（官员是金色、法师是彩色双层法阵，颜色/层数都不同）；
#   2. 头顶悬浮的金色铜钱，绕竖轴旋转，远处也能看到。
# 服务端 Army 与联机 ClientRenderer 共用本脚本，单机/联机外观一致。

const MERCHANT_IDS: Array[int] = [43, 44, 45, 51]
const RING_COLOR := Color(0.24, 0.84, 0.94)
const COIN_COLOR := Color(1.0, 0.82, 0.20)

var _ring: MeshInstance3D = null
var _coin_holder: Node3D = null
var _base_height: float = 1.2
var _time: float = 0.0

static func is_merchant(entity_id: int) -> bool:
	return entity_id in MERCHANT_IDS

static func create(body_radius: float) -> MerchantMarker:
	var marker := MerchantMarker.new()
	marker.name = "MerchantMarker"
	marker._build(body_radius)
	return marker

func _build(body_radius: float) -> void:
	# 青色脚环。和法师环一样略微抬离地面，避免地形起伏时半圈陷进土里。
	var ring := MeshInstance3D.new()
	ring.name = "MerchantRing"
	var torus := TorusMesh.new()
	torus.inner_radius = maxf(0.24, body_radius * 1.32)
	torus.outer_radius = maxf(0.34, body_radius * 1.72)
	torus.rings = 28
	torus.ring_segments = 5
	ring.mesh = torus
	var ring_mat := StandardMaterial3D.new()
	ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring_mat.albedo_color = Color(RING_COLOR.r, RING_COLOR.g, RING_COLOR.b, 0.68)
	ring_mat.emission_enabled = true
	ring_mat.emission = RING_COLOR
	ring_mat.emission_energy_multiplier = 1.7
	ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ring_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	ring.material_override = ring_mat
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ring.position = Vector3(0.0, 0.16, 0.0)
	add_child(ring)
	_ring = ring

	# 头顶铜钱：铜钱竖直立起，绕竖直轴旋转。官员是金色菱形、法师是职业符号，
	# 形状与位置都不同，不会混淆。
	_base_height = maxf(1.12, body_radius * 2.9)
	_coin_holder = Node3D.new()
	_coin_holder.name = "MerchantCoin"
	_coin_holder.position = Vector3(0.0, _base_height, 0.0)
	add_child(_coin_holder)

	var coin := MeshInstance3D.new()
	var coin_mesh := CylinderMesh.new()
	coin_mesh.top_radius = maxf(0.13, body_radius * 0.34)
	coin_mesh.bottom_radius = coin_mesh.top_radius
	coin_mesh.height = maxf(0.028, body_radius * 0.075)
	coin_mesh.radial_segments = 18
	coin.mesh = coin_mesh
	coin.rotation.x = deg_to_rad(90.0)
	var coin_mat := StandardMaterial3D.new()
	coin_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	coin_mat.albedo_color = COIN_COLOR
	coin_mat.emission_enabled = true
	coin_mat.emission = COIN_COLOR
	coin_mat.emission_energy_multiplier = 2.2
	coin.material_override = coin_mat
	coin.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_coin_holder.add_child(coin)

func _process(delta: float) -> void:
	_time += delta
	if _ring != null and is_instance_valid(_ring):
		var pulse: float = 1.0 + sin(_time * 2.3) * 0.05
		_ring.scale = Vector3(pulse, 1.0, pulse)
	if _coin_holder != null and is_instance_valid(_coin_holder):
		_coin_holder.rotation.y = _time * 2.4
		_coin_holder.position.y = _base_height + sin(_time * 2.8) * 0.07

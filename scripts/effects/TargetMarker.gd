class_name TargetMarker
extends Node3D

# 选中单位的目标点标记：一个立体的红色 ❌，绕竖直轴缓慢旋转。
# 地面目标放在地表上方一点；单位目标由 TargetMarkerManager 放到头顶。
# 用 BoxMesh 拼成两根交叉的横梁，而不是 Sprite3D/Label3D，所以有厚度、会随视角变化。

const BAR_LENGTH: float = 1.45
const BAR_WIDTH: float = 0.22
const BAR_THICKNESS: float = 0.16
const ROTATE_SPEED: float = 0.95  # 弧度/秒，约 6.6 秒一圈
const MARKER_COLOR: Color = Color(1.0, 0.16, 0.10, 0.96)

var _material: StandardMaterial3D

func _ready() -> void:
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.albedo_color = MARKER_COLOR
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.no_depth_test = true
	_material.render_priority = 14
	_material.emission_enabled = true
	_material.emission = Color(1.0, 0.08, 0.03)
	_material.emission_energy_multiplier = 1.6
	_add_bar(PI * 0.25)
	_add_bar(-PI * 0.25)
	set_process(true)

func _add_bar(angle: float) -> void:
	var bar := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(BAR_LENGTH, BAR_THICKNESS, BAR_WIDTH)
	bar.mesh = box
	bar.rotation.y = angle
	bar.material_override = _material
	bar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	bar.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(bar)

func _process(delta: float) -> void:
	rotation.y += ROTATE_SPEED * delta

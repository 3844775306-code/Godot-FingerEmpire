class_name WeaponAim
extends Node3D

# 弓和剑挂到手臂骨骼后，攻击/射击动作会把手腕转成侧向，武器跟着歪掉。
# 这个节点只跟随手的位置，朝向固定为单位正前方：武器模型局部 +Z 是前方，
# 单位正前方是 -Z，所以基准旋转要再绕 Y 轴 180°。
# 剑的左右挥砍/前后劈砍仍由武器自身的 tween 叠加，方向不会随手臂乱转。
var owner_entity: Node3D
var hand_marker: Node3D

func _ready() -> void:
	top_level = true

func _process(_delta: float) -> void:
	if not is_instance_valid(owner_entity) or not is_instance_valid(hand_marker):
		return
	var yaw: float = owner_entity.global_rotation.y + PI
	var hand_scale: Vector3 = hand_marker.global_transform.basis.get_scale()
	# 只取朝向和模型缩放，不继承手臂骨骼的俯仰/翻滚，否则拉弓时弓会甩向侧面。
	global_transform = Transform3D(
			Basis(Vector3.UP, yaw).scaled(hand_scale),
			hand_marker.global_position)

class_name CannonTowerAnim
extends RefCounted

# 墙顶炮台（ID 64）没有骨骼动画，开火时用炮身短促后坐 + 炮架摆动补足反馈。
# 单机由 Building 直接调用；联机客户端根据快照 attack_seq 变化调用，两端共用。
const CANNON_TOWER_ID := 64
const META_RUNNING := "_cannon_tower_anim_running"

static func is_cannon_tower(entity_id: int) -> bool:
	return entity_id == CANNON_TOWER_ID

static func play(model: Node3D) -> void:
	if model == null or not is_instance_valid(model) or not model.is_inside_tree():
		return
	if bool(model.get_meta(META_RUNNING, false)):
		return
	model.set_meta(META_RUNNING, true)
	var base_pos: Vector3 = model.position
	var tw := model.create_tween()
	# 炮身向后退并轻微上抬，再阻尼回位；0.3 秒内完成，匹配炮台攻击间隔。
	tw.tween_property(model, "position", base_pos + Vector3(0.0, 0.045, 0.22), 0.07) \
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_property(model, "position", base_pos, 0.24) \
		.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	# 两条炮架腿被后坐力带得一前一后小幅摆动。
	var legs := model.find_children("Group*", "Node3D", true)
	for i in range(legs.size()):
		var leg := legs[i] as Node3D
		if leg == null:
			continue
		var base_rot: Vector3 = leg.rotation
		var swing: float = 0.05 if i % 2 == 0 else -0.05
		var leg_tw := leg.create_tween()
		leg_tw.tween_property(leg, "rotation", base_rot + Vector3(swing, 0.0, 0.0), 0.07) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		leg_tw.tween_property(leg, "rotation", base_rot, 0.22) \
			.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	tw.tween_callback(func() -> void:
		if is_instance_valid(model):
			model.position = base_pos
			model.set_meta(META_RUNNING, false))

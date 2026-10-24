class_name AnimationHelper
extends RefCounted

# 项目里的 GLB 动画导入后 loop_mode 都是 LOOP_NONE；如果只调用 play()，
# idle/walk/attack 播放一遍就会停在最后一帧。这里统一给循环型动作打开循环。
# die 保持一次性，不能循环。
const LOOPED_ANIMATIONS := ["idle", "walk", "attack-melee-left"]

static func find_player(root: Node) -> AnimationPlayer:
	if root == null:
		return null
	if root is AnimationPlayer:
		return root as AnimationPlayer
	for child in root.get_children():
		var found := find_player(child)
		if found != null:
			return found
	return null

# 返回模型里的 AnimationPlayer，并确保循环动作已标记为循环。
# Animation 资源来自 GLB 导入缓存，同一模型的所有实例共享；重复调用无副作用。
static func configure_loops(root: Node) -> AnimationPlayer:
	var ap := find_player(root)
	if ap == null:
		return null
	for anim_name in LOOPED_ANIMATIONS:
		if not ap.has_animation(anim_name):
			continue
		var anim := ap.get_animation(anim_name)
		if anim != null and anim.loop_mode == Animation.LOOP_NONE:
			anim.loop_mode = Animation.LOOP_LINEAR
	return ap

# 攻击动作一个循环 ≈ 一次攻击冷却；否则攻击间隔慢的单位反而播放得飞快，
# 攻击间隔快的单位又会长时间停在最后一帧。
static func attack_speed_scale(ap: AnimationPlayer, anim_name: String, cooldown: float) -> float:
	if ap == null or not ap.has_animation(anim_name):
		return 1.0
	var anim := ap.get_animation(anim_name)
	if anim == null or anim.length <= 0.001:
		return 1.0
	# 冷却极短时限制最大播放速度，避免动作糊成一片；冷却极长时保留慢动作。
	return clampf(anim.length / maxf(cooldown, 0.1), 0.1, 5.0)

class_name AnimationHelper
extends RefCounted

# 项目里的 GLB 动画导入后 loop_mode 都是 LOOP_NONE；如果只调用 play()，
# idle/walk/attack 播放一遍就会停在最后一帧。这里统一给循环型动作打开循环。
# die 保持一次性，不能循环。
const LOOPED_ANIMATIONS := [
	"idle", "walk", "attack-melee-left", "attack-melee-right",
	"holding-left-shoot", "holding-right-shoot", "holding-both-shoot",
	"interact-left", "interact-right",
]

# 人物系兵种的出手动作。以前所有人物统一播 attack-melee-left（左勾拳），
# 僧侣/长老/宗师这类法术单位和弓箭手挥拳完全不像。character 模型自带 32 个
# 动作，这里按兵种挑对应的姿态；表里没有的仍回落到近战挥击。
const ATTACK_ANIM_BY_ID := {
	55: "interact-right",       # 僧侣：单手上抬抚出，像在引导法术
	56: "holding-both-shoot",   # 长老：双手前送
	57: "attack-melee-right",   # 宗师：右掌直击（与农民左勾拳区分开）
	12: "holding-left-shoot",   # 弓箭手：拉弓
	31: "holding-left-shoot",   # 长弓兵
	37: "holding-left-shoot",   # 重装弓箭手
	33: "holding-both-shoot",   # 诸葛连弩：双手连射
	58: "holding-both-shoot",   # 连弩
}

# GLB 自带的拉弓动作只有 0.2 秒、骨骼摆幅很小，远看像没动。
# 这里把关键帧相对“起手姿态”的旋转角度放大，保留原动作节奏和首尾姿态，
# 只让拉弓/送臂的弧线更明显。所有弓箭手共用同一个 Animation 资源，
# 用 metadata 保证只放大一次，避免每个实例重复乘。
const ARCHER_ATTACK_ANIM := "holding-left-shoot"
const ARCHER_ARM_AMPLIFY := 2.4
const ARCHER_BODY_AMPLIFY := 1.7

static func attack_anim_for(entity_id: int) -> String:
	return String(ATTACK_ANIM_BY_ID.get(entity_id, "attack-melee-left"))

# 放大弓箭手拉弓动作的旋转幅度。每个旋转轨道以第 0 帧为基准姿态，
# 只放大第 1 帧之后相对基准的旋转，结束时自然回到原姿态。
static func amplify_archer_attack(ap: AnimationPlayer) -> void:
	if ap == null or not ap.has_animation(ARCHER_ATTACK_ANIM):
		return
	var anim := ap.get_animation(ARCHER_ATTACK_ANIM)
	if anim == null or anim.has_meta("_archer_amplified"):
		return
	anim.set_meta("_archer_amplified", true)
	for t in range(anim.get_track_count()):
		if anim.track_get_type(t) != Animation.TYPE_ROTATION_3D:
			continue
		var key_count: int = anim.track_get_key_count(t)
		if key_count < 2:
			continue
		var path := String(anim.track_get_path(t))
		var factor: float = ARCHER_ARM_AMPLIFY if path.contains("arm") else ARCHER_BODY_AMPLIFY
		var first_q: Quaternion = anim.track_get_key_value(t, 0)
		first_q = first_q.normalized()
		for k in range(1, key_count):
			var q: Quaternion = anim.track_get_key_value(t, k)
			q = q.normalized()
			var delta: Quaternion = q * first_q.inverse()
			# 四元数 q 与 -q 表示同一旋转；统一取 w>=0 的半球，
			# 否则 get_angle() 会得到 300° 这种大角，放大后直接扭断。
			if delta.w < 0.0:
				delta = Quaternion(-delta.x, -delta.y, -delta.z, -delta.w)
			var angle: float = delta.get_angle()
			if angle < 0.001:
				continue
			var amplified := Quaternion(delta.get_axis(), clampf(angle * factor, 0.0, PI * 0.98))
			anim.track_set_key_value(t, k, (amplified * first_q).normalized())

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
	amplify_archer_attack(ap)
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

# 统一切换循环动作。walk 首次进入时随机相位，避免几十个单位同手同脚；
# 已在播放同一个 walk 时不重新 seek，否则会不断把脚步卡回起点。
static func play_looped(ap: AnimationPlayer, anim_name: String, randomize_walk: bool = true) -> void:
	if ap == null or anim_name == "" or not ap.has_animation(anim_name):
		return
	if ap.current_animation == anim_name:
		return
	ap.play(anim_name)
	if randomize_walk and anim_name == "walk":
		var length := ap.current_animation_length
		if length > 0.01:
			ap.seek(randf_range(0.0, length * 0.9), true)

# 用实际位移速度换算步频；单位被地形减速或撞住时，脚步不会继续原地滑动。
static func walk_speed_scale(actual_speed: float) -> float:
	return clampf(actual_speed * 0.6, 0.2, 3.0)

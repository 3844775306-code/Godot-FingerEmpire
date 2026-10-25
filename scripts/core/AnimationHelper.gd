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

static func attack_anim_for(entity_id: int) -> String:
	return String(ATTACK_ANIM_BY_ID.get(entity_id, "attack-melee-left"))

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

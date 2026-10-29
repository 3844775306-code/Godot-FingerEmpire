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
# 僧侣/长老/宗师这类法术单位和弓箭手挥拳完全不像。character / archer / soldier
# 模型分别自带 32 / 32 / 25 个原生动作，这里按兵种直接挑模型原生的姿态，
# 一律原样播放，不再改写任何动画关键帧；表里没有的仍回落到近战挥击。
#
# 弓箭手系（12 弓箭手 / 31 长弓兵 / 37 重装弓箭手）按玩家要求改回近战挥击动作
# attack-melee-left：holding-left-shoot 虽然是模型原生的拉弓动作，但看着像「举弓不动」，
# 出手瞬间没有力度，实战里不如挥击读得出来。所以不再单独映射，直接走下面的默认值。
# 33 诸葛连弩 / 58 连弩 用的是 ballista 模型，GLB 里根本没有 AnimationPlayer，
# 映射只是保持原状（不会播骨骼动作），开火表现靠箭矢/音效。
const ATTACK_ANIM_BY_ID := {
	55: "interact-right",       # 僧侣：单手上抬抚出，像在引导法术
	56: "holding-both-shoot",   # 长老：双手前送
	57: "attack-melee-right",   # 宗师：右掌直击（与农民左勾拳区分开）
	33: "holding-both-shoot",   # 诸葛连弩：ballista 模型无 AnimationPlayer，实际不播
	58: "holding-both-shoot",   # 连弩：weapon-ballista 模型无 AnimationPlayer
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
# 这里只改 loop_mode（播放方式），不动任何关键帧数值。
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
# 弓箭手改回 attack-melee-left 后，原始动作长 0.42 秒，按各自的冷却换算播放速率
# 就能正好填满一次出手间隔，既不改关键帧又能把原版动作看全。
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
	# 旧的 0.6 倍率会让脚步明显慢于实际位移，看起来像贴地滑行；提高到接近 1:1。
	return clampf(actual_speed * 0.85, 0.35, 2.8)

class_name AIConfig
extends RefCounted

# P1 基础设施：AI 配置表（唯一参数来源）。
#
# 现状：先收敛本次复审涉及的少量常量，其余仍留在 AI.gd；
# 后续 P4/P6 把兵种表、建筑表、难度参数、排除表逐步搬进来，
# 让"改 AI 强弱"只动这一个文件，而不是在 6000 行里找魔法数字。

# ── 阶段 ──
# 进入 ASSAULT 的总陆军门槛。
# 旧版用 count_field_military() >= 30：军队账本接管后单位普遍带角色，
# field 计数被扣到个位数，ASSAULT 实际永远不触发（自对弈基线 12 分钟仍停在 DEVELOPMENT）。
# 实测 3v3 HELL：总陆军 14 在 t≈8~9 分钟出现，18 要到 12 分钟，故取 14。
const ASSAULT_LAND_ARMY_THRESHOLD: int = 14

# ── 决策调度 ──
const DECIDE_BUDGET_USEC: int = 7000
const DECIDE_LAST_STEP: int = 14

# ── 难度 ──
# 思考间隔（秒）。难度只影响频率与资源倍率，不影响战术集合。
const THINK_EASY: float = 2.0
const THINK_NORMAL: float = 1.75
const THINK_HARD: float = 1.5
const THINK_HELL: float = 1.0

static func think_interval(difficulty: int) -> float:
	match difficulty:
		GameSettings.AIDifficulty.EASY:
			return THINK_EASY
		GameSettings.AIDifficulty.NORMAL:
			return THINK_NORMAL
		GameSettings.AIDifficulty.HARD:
			return THINK_HARD
		_:
			return THINK_HELL

# 阶段在 PRODUCTION 之后的农民目标数（与 AI.gd 现有行为一致）。
static func desired_worker_count(phase: int) -> int:
	return 15 if phase >= 1 else 8

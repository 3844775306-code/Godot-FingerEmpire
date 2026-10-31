class_name AIRng
extends RefCounted

# P1 基础设施：AI 专用确定性随机流。
#
# 目标：AI 的每个决策模块拿到**互不干扰**的独立随机序列，且整局可复现。
# 现阶段策略（改造期行为不变）：
#  - `GameSettings.deterministic_sim == true`：使用本实例自己的 RandomNumberGenerator 流；
#  - 否则：降级到全局 RNG（与改造前的 randi/randf_range 行为完全一致），便于逐步替换。
#
# 用法：
#	var rng := AIRng.new("defense")
#	rng.reseed(SimRandom.get_seed(), my_peer_id)
#	var n := rng.randi_range(0, 3)
#	var p := rng.chance(0.35)
#
# 播种：`reseed(base, salt)`，salt 建议用 peer_id 或模块序号，保证同 seed 同局可复现。

var _rng := RandomNumberGenerator.new()
var _draws: int = 0
var _label: String = ""
var _seeded: bool = false

func _init(label: String = "") -> void:
	_label = label

func label() -> String:
	return _label

func reseed(base_seed: int, salt: int) -> void:
	var text: String = "%d|%d|%s" % [int(base_seed), int(salt), _label]
	var s: int = int(hash(text))
	if s == 0:
		s = 1
	_rng.seed = s
	_draws = 0
	_seeded = true

func is_seeded() -> bool:
	return _seeded

func draws() -> int:
	return _draws

func deterministic() -> bool:
	return GameSettings.deterministic_sim

func randi_range(a: int, b: int) -> int:
	_draws += 1
	if deterministic():
		return _rng.randi_range(a, b)
	return @GlobalScope.randi_range(a, b)

func randi() -> int:
	_draws += 1
	if deterministic():
		return _rng.randi()
	return @GlobalScope.randi()

func randf() -> float:
	_draws += 1
	if deterministic():
		return _rng.randf()
	return @GlobalScope.randf()

func randf_range(a: float, b: float) -> float:
	_draws += 1
	if deterministic():
		return _rng.randf_range(a, b)
	return @GlobalScope.randf_range(a, b)

func chance(p: float) -> bool:
	return randf() < clampf(p, 0.0, 1.0)

func pick(arr: Array):
	if arr.is_empty():
		return null
	return arr[randi_range(0, arr.size() - 1)]

func shuffle(arr: Array) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j: int = randi_range(0, i)
		var tmp = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp

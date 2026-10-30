extends RefCounted

# 确定性模拟随机源：只用于会改变对局状态的随机。
# 特效、音效、镜头等表现层随机继续使用全局 randi/randf，避免消耗本 RNG 的序列。

static var _rng := RandomNumberGenerator.new()
static var _seeded: bool = false
static var _seed: int = 0
static var _draws: int = 0
static var _trace: int = 0

static func reset(s: int) -> void:
	_seed = int(s)
	_rng.seed = _seed
	_draws = 0
	_trace = 0
	_seeded = true

static func count() -> int:
	return _draws

static func trace() -> int:
	return _trace

static func state() -> int:
	return _rng.state

static func get_seed() -> int:
	return _seed

static func is_seeded() -> bool:
	return _seeded

static func _note(v) -> void:
	_trace = hash(str(_trace) + ":" + str(v))

static func randi() -> int:
	_draws += 1
	var v := _rng.randi()
	_note(v)
	return v

static func randf() -> float:
	_draws += 1
	var v := _rng.randf()
	_note(v)
	return v

static func randi_range(a: int, b: int) -> int:
	_draws += 1
	var v := _rng.randi_range(a, b)
	_note(v)
	return v

static func randf_range(a: float, b: float) -> float:
	_draws += 1
	var v := _rng.randf_range(a, b)
	_note(v)
	return v

static func shuffle(arr: Array) -> void:
	for i in range(arr.size() - 1, 0, -1):
		_draws += 1
		var j := _rng.randi_range(0, i)
		_note(j)
		var tmp = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp

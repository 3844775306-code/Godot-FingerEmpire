extends RefCounted

# A6：决策流水线（顺序显式化）。
#
# 目的（见 docs/AI架构总设计.md §5）：一轮决策由哪些阶段组成、按什么顺序执行，
# 不能再靠人肉记住 `_run_decide_step` 里的 match 数字。这里把阶段名变成数据，
# AI.gd 只需按名字注册，profile 日志也直接打印阶段名。
#
# 当前阶段只负责"名字与顺序"这一层：真正的执行仍是 AI.gd 的 _run_decide_step(step)。
# 下一步（A6 收尾）会把每个分支抽成方法，注册成 Callable，由本类直接 run()。

var _names: PackedStringArray = PackedStringArray()
var _t_total: float = 0.0
var _t_stage: PackedFloat32Array = PackedFloat32Array()
var _runs: int = 0

func register(names: Array) -> void:
	_names = PackedStringArray()
	for n in names:
		_names.append(String(n))
	_t_stage.resize(_names.size())
	_t_stage.fill(0.0)

func last_step() -> int:
	return _names.size() - 1

func size() -> int:
	return _names.size()

func name_of(step: int) -> String:
	if step < 0 or step >= _names.size():
		return "out_of_range"
	return _names[step]

func names() -> PackedStringArray:
	return _names

# 记录单阶段耗时（由 AI.gd 在每步前后调用；单位毫秒）。
func record(step: int, ms: float) -> void:
	if step >= 0 and step < _t_stage.size():
		_t_stage[step] = float(_t_stage[step]) + ms

func begin_round() -> void:
	_runs += 1
	_t_total = 0.0
	_t_stage.fill(0.0)

func end_round(total_ms: float) -> void:
	_t_total = total_ms

# "limits=3ms visibility=1ms ..." 形式，profile 日志直接可用。
func format_stages() -> String:
	var parts: PackedStringArray = PackedStringArray()
	for i in range(_names.size()):
		parts.append("%s=%.0f" % [_names[i], float(_t_stage[i])])
	return " ".join(parts)

# 找出耗时最高的阶段名，profile 里一句话指出瓶颈。
func slowest() -> String:
	var best_i: int = -1
	var best_v: float = -1.0
	for i in range(_t_stage.size()):
		if float(_t_stage[i]) > best_v:
			best_v = float(_t_stage[i])
			best_i = i
	return name_of(best_i) if best_i >= 0 else "none"

func debug_snapshot() -> Dictionary:
	return {
		"stages": Array(_names),
		"count": _names.size(),
		"runs": _runs,
		"last_total_ms": snappedf(_t_total, 0.1),
		"slowest": slowest(),
	}

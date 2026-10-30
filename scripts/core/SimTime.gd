extends RefCounted

# 确定性模拟时间：指令回放模式下用固定物理步时钟，避免真实墙钟进入 AI/冷却判断。
# 普通对局仍返回真实时间，不影响现有手感。

static var _start_frame: int = -1

static func reset(start_frame: int) -> void:
	_start_frame = start_frame

static func frame() -> int:
	if _start_frame < 0:
		return Engine.get_physics_frames()
	return Engine.get_physics_frames() - _start_frame

static func now_ms() -> int:
	if GameSettings.deterministic_sim:
		return int(frame() * 1000 / maxi(Engine.physics_ticks_per_second, 1))
	return Time.get_ticks_msec()

static func now_sec() -> float:
	return float(now_ms()) / 1000.0

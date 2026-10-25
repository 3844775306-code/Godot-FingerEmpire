class_name ShipSailAnimator
extends Node3D

# 船桨 / 船帆的随动动画。
# 挂在船只模型实例下面，自己根据父节点位移判断是否在行驶，服务端与客户端都能直接用：
#   - 采集船（划艇 boat-row-small）模型里有一块 paddles 网格，行驶时来回摆动模拟双桨划水；
#   - 有帆的船（sail-a / sail-b）按全局风向转动帆面，表现「风推着帆」。
# 两者都只是视觉，不参与任何战斗或移动逻辑。

# ==================== 全局风 ====================
# 两个不同周期的正弦叠加：风向缓慢转向，强度也在起伏，不会规律到一眼看穿。
static var wind_angle: float = 0.0      # 世界坐标系 XZ 平面的风向（弧度）
static var wind_strength: float = 1.0   # 0.3 ~ 1.0
static var _wind_time: float = 0.0

const WIND_TURN_SLOW: float = 0.011
const WIND_TURN_FAST: float = 0.037

# ==================== 桨 ====================
const ROW_SPEED: float = 5.2        # 划桨角速度（弧度/秒）
const ROW_AMPLITUDE: float = 0.30   # 绕船体纵轴的摆幅（弧度）
const ROW_PITCH: float = 0.12       # 绕横轴的附加俯仰，让桨看起来是插进水里划
const ROW_BOB: float = 0.030        # 桨架的轻微上下起伏
const ROW_STOP_SPEED: float = 0.35  # 减速到这个倍率以下桨就慢慢停

# ==================== 帆 ====================
const SAIL_MAX_YAW_DEG: float = 38.0  # 帆相对船体的最大转角，过大就不像固定在桅杆上
const SAIL_LERP: float = 2.4          # 帆转到目标角度的速度
const SAIL_FLUTTER_DEG: float = 7.0   # 视风很弱时帆的飘摆幅度
# 风的绝对速度（m/s）。船自身速度大约 1.2~2.5，取 3.0 让「视风」有明显变化：
# 顺风全速时相对气流只剩约 1 m/s，帆会明显松下来。
const WIND_SPEED: float = 3.0
const APPARENT_MIN_SPEED: float = 0.25  # 低于这个视风速度就当没风，帆不转向

var _paddles: Node3D = null
var _paddles_base_pos: Vector3 = Vector3.ZERO
var _sails: Array = []       # [{ "node": Node3D, "base": float, "cur": float }]
var _last_pos: Vector3 = Vector3.ZERO
var _ship_vel: Vector3 = Vector3.ZERO
var _row_phase: float = 0.0
var _move_factor: float = 0.0
var _has_host: bool = false

# 找模型里的桨与帆并缓存，找不到就整块不启用（老模型没有这些节点也不会报错）
func setup(model_root: Node) -> void:
	if model_root == null:
		return
	_paddles = model_root.find_child("paddles", true, false) as Node3D
	if _paddles != null:
		_paddles_base_pos = _paddles.position
	_sails.clear()
	for sail_name in ["sail-a", "sail-b"]:
		var node := model_root.find_child(sail_name, true, false) as Node3D
		if node != null:
			_sails.append({"node": node, "base": node.rotation.y, "cur": 0.0})
	var host := get_parent() as Node3D
	if host != null:
		_last_pos = host.global_position
		_has_host = true
	set_process(_paddles != null or not _sails.is_empty())

func _process(delta: float) -> void:
	if not _has_host:
		return
	var host := get_parent() as Node3D
	if host == null or not is_instance_valid(host):
		return

	# 全局风缓慢转向（挂在任意一条船上推进都行，用的是静态量）
	_wind_time += delta
	wind_angle = sin(_wind_time * WIND_TURN_SLOW) * 1.9 + sin(_wind_time * WIND_TURN_FAST + 1.7) * 1.2
	wind_strength = 0.65 + 0.35 * (0.5 + 0.5 * sin(_wind_time * 0.21))

	# 用位移判断是否在行驶：不依赖服务端的 velocity，客户端也算得出来
	var pos := host.global_position
	var step_vec: Vector3 = pos - _last_pos
	_last_pos = pos
	_ship_vel = step_vec / maxf(delta, 0.000001)
	var speed_sq := step_vec.length_squared() / maxf(delta * delta, 0.000001)
	var target_factor: float = clampf(speed_sq / 0.25, 0.0, 1.0)
	_move_factor = lerpf(_move_factor, target_factor, clampf(delta * 4.0, 0.0, 1.0))

	if _paddles != null:
		_update_paddles(delta)
	if not _sails.is_empty():
		_update_sails(host, delta)

func _update_paddles(delta: float) -> void:
	if _move_factor > 0.05:
		_row_phase += delta * ROW_SPEED * _move_factor
	var amp: float = ROW_AMPLITUDE * _move_factor
	# 绕纵轴左右摆（双桨一起），再用余弦给一点俯仰，看起来是桨叶入水再抬出
	_paddles.rotation.z = sin(_row_phase) * amp
	_paddles.rotation.x = cos(_row_phase) * ROW_PITCH * _move_factor
	_paddles.position.y = _paddles_base_pos.y + sin(_row_phase * 2.0) * ROW_BOB * _move_factor

# 帆看的是「视风」——风相对船的速度，不是风的绝对速度。
# 顺风行驶时船跟着风跑，帆上感受到的气流变弱，帆会松开飘一下；
# 逆风或横风时相对气流变大，帆绷紧并对准视风方向。
func _update_sails(host: Node3D, delta: float) -> void:
	var wind_vec: Vector3 = Vector3(sin(wind_angle), 0.0, cos(wind_angle)) * WIND_SPEED * wind_strength
	# 视风 = 风的速度 - 船自身速度（船冲起来等于迎面多了一股气流）
	var apparent: Vector3 = wind_vec - _ship_vel
	var apparent_speed: float = apparent.length()
	var ship_yaw: float = host.global_rotation.y
	var want_deg: float = 0.0
	if apparent_speed > APPARENT_MIN_SPEED:
		var apparent_angle: float = atan2(apparent.x, apparent.z)
		var rel: float = wrapf(apparent_angle - ship_yaw, -PI, PI)
		# 帆默认朝船头，转到垂直视风需要再偏 90°
		want_deg = clampf(rad_to_deg(wrapf(rel + PI * 0.5, -PI, PI)), -SAIL_MAX_YAW_DEG, SAIL_MAX_YAW_DEG)
	# 视风越弱帆越飘：完全无风时帆只是随船身轻微晃动
	var slack: float = clampf(1.0 - apparent_speed / (WIND_SPEED * 0.9), 0.0, 1.0)
	var gust: float = sin(_wind_time * 1.9) * slack * SAIL_FLUTTER_DEG
	var want: float = deg_to_rad(want_deg + gust)
	var step: float = clampf(SAIL_LERP * delta, 0.0, 1.0)
	for entry in _sails:
		var node: Node3D = entry["node"]
		if node == null or not is_instance_valid(node):
			continue
		entry["cur"] = lerpf(float(entry["cur"]), want, step)
		node.rotation.y = float(entry["base"]) + float(entry["cur"])

# 供外部查询当前风向（度），调试或 UI 指示用
static func wind_degrees() -> float:
	return rad_to_deg(wind_angle)

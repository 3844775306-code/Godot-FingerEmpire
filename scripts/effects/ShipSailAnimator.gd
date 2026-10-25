class_name ShipSailAnimator
extends Node3D

# 船桨 / 船帆的随动动画。
# 挂在船只模型实例下面，自己根据父节点位移判断是否在行驶，服务端与客户端都能直接用：
#   - 采集船（划艇 boat-row-small）模型里有一块 paddles 网格，行驶时来回摆动模拟双桨划水；
#   - 有帆的船（sail-a / sail-b）按船自身航速产生的相对气流转动帆面。
# 两者都只是视觉，不参与任何战斗或移动逻辑。

# ==================== 桨 ====================
const ROW_SPEED: float = 5.2        # 划桨角速度（弧度/秒）
const ROW_AMPLITUDE: float = 0.30   # 绕船体纵轴的摆幅（弧度）
const ROW_PITCH: float = 0.12       # 绕横轴的附加俯仰，让桨看起来是插进水里划
const ROW_BOB: float = 0.030        # 桨架的轻微上下起伏
const ROW_STOP_SPEED: float = 0.35  # 减速到这个倍率以下桨就慢慢停

# ==================== 帆 ====================
const SAIL_MAX_YAW_DEG: float = 38.0  # 帆相对船体的最大转角，过大就不像固定在桅杆上
const SAIL_LERP: float = 2.4          # 帆转到目标角度的速度
const SAIL_FLUTTER_DEG: float = 7.0   # 航速很低时帆的飘摆幅度
const SAIL_MIN_SPEED: float = 0.25    # 低于这个航速就当没有相对气流，帆回正
const SAIL_FULL_SPEED: float = 2.4    # 达到这个航速时相对气流最强，帆完全绷紧

var _paddles: Node3D = null
var _paddles_base_pos: Vector3 = Vector3.ZERO
var _sails: Array = []       # [{ "node": Node3D, "base": float, "cur": float }]
var _last_pos: Vector3 = Vector3.ZERO
var _ship_vel: Vector3 = Vector3.ZERO
var _row_phase: float = 0.0
var _move_factor: float = 0.0
var _has_host: bool = false
var _time: float = 0.0

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
	_time += delta

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

# 帆只看船自身航速产生的相对气流，不引入任何全局风。
# 船笔直前进时气流正对船头，帆保持基准角；转弯、侧滑或倒退时气流方向
# 与船体轴线有夹角，帆就顺着这股气流偏转。航速越低气流越弱，帆自行飘摆。
func _update_sails(host: Node3D, delta: float) -> void:
	var flat_vel := Vector3(_ship_vel.x, 0.0, _ship_vel.z)
	var speed: float = flat_vel.length()
	var want_deg: float = 0.0
	if speed > SAIL_MIN_SPEED:
		# 空气静止、船在跑，船上感受到的气流速度是 -船速，也就是从船头迎面吹来。
		# 所以相对气流的来向就是船的实际行进方向；把它和船头朝向比较，
		# 正前方航行时差 0°，侧滑/掉头时才出现夹角，帆跟着这股气流偏转。
		var fwd := -host.global_transform.basis.z
		fwd.y = 0.0
		if fwd.length_squared() > 0.000001:
			var rel: float = fwd.normalized().signed_angle_to(flat_vel / speed, Vector3.UP)
			want_deg = clampf(rad_to_deg(rel), -SAIL_MAX_YAW_DEG, SAIL_MAX_YAW_DEG)
	# 帆的松紧：全速航行时被气流吹得绷紧，只有一点点微晃；
	# 慢速时气流托不住帆，飘摆明显；完全静止时根本没有气流，
	# 只剩船身随水面起伏带动的轻微晃动，不能再按满幅飘。
	var slack: float = clampf(1.0 - speed / SAIL_FULL_SPEED, 0.0, 1.0)
	var flow_on: float = clampf(speed / SAIL_MIN_SPEED, 0.0, 1.0)
	var flutter_amp: float = 1.2 + SAIL_FLUTTER_DEG * slack * flow_on
	var flutter: float = sin(_time * 1.9) * flutter_amp
	var want: float = deg_to_rad(want_deg + flutter)
	var step: float = clampf(SAIL_LERP * delta, 0.0, 1.0)
	for entry in _sails:
		var node: Node3D = entry["node"]
		if node == null or not is_instance_valid(node):
			continue
		entry["cur"] = lerpf(float(entry["cur"]), want, step)
		node.rotation.y = float(entry["base"]) + float(entry["cur"])

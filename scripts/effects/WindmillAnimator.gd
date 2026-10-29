class_name WindmillAnimator
extends Node3D

# 仓库（实体 22）的模型是 unit-mill.glb，GLB 里风车叶片节点名为 rotate-x。
# 建筑不走单位 AnimationPlayer 的播放流程（GameEntity 每帧只给单位切 idle/walk），
# 所以这里直接程序化旋转叶片节点，服务端、联机客户端和建造完成后的模型共用。
# 纯视觉，不影响采集/仓储等任何数值。

const NODE_NAME := "WindmillAnimator"
const BLADE_NODE := "rotate-x"
# 约 8 秒转一圈：常速缓慢旋转，不做阵风变速。
const SPIN_SPEED: float = 0.785

var _blades: Node3D = null
var _base_rotation: Vector3 = Vector3.ZERO
var _angle: float = 0.0

# 给建筑模型挂上风车动画；重复调用不会叠加。
static func attach(model_root: Node3D) -> void:
	if model_root == null or not is_instance_valid(model_root):
		return
	if model_root.get_node_or_null(NODE_NAME) != null:
		return
	var animator := WindmillAnimator.new()
	animator.name = NODE_NAME
	animator.setup(model_root)
	model_root.add_child(animator)

func setup(model_root: Node3D) -> void:
	if model_root == null:
		return
	_blades = model_root.find_child(BLADE_NODE, true, false) as Node3D
	if _blades == null:
		# 模型结构变化时不要让整个场景报错，静默退化成无动画。
		set_process(false)
		return
	_base_rotation = _blades.rotation
	set_process(true)

func _process(delta: float) -> void:
	if _blades == null or not is_instance_valid(_blades):
		return
	# 常速缓慢旋转，不再叠加阵风起伏。
	_angle = fposmod(_angle + SPIN_SPEED * delta, TAU)
	_blades.rotation.x = _base_rotation.x + _angle

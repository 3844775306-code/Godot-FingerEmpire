class_name FlagFlutter
extends Node3D

# 建筑等级旗帜的随风飘动。
#
# 旗面使用 billboard（始终正对相机），只靠旋转旗面在远处几乎看不出来；
# 这里同时做三件事，俯视 RTS 视角下也能读出“风在吹”：
#   1. 旗杆枢轴绕本地 Z 轴轻微往复摆动；
#   2. 旗面横向宽度按风势伸缩，模拟布料被吹紧/放松；
#   3. 旗面上下小幅浮动，和杆头摆动错开相位。
# 每个 LevelVisual 只挂一个控制器，避免为每面旗各跑一个 _process。
# 纯视觉，建筑倒塌前会被 BuildingLevelVisual.play_collapse 移除。

const NODE_NAME := "FlagFlutter"
const FLAG_ROOT_PREFIX := "FlagRoot"
const FLAG_PIVOT_NAME := "FlagPolePivot"
const FLAG_CLOTH_NAME := "FlagCloth"

# 杆头摆幅与布面伸缩幅度都压得比较小：旗帜是建筑等级标识，不能晃成彩带。
const POLE_SWAY_DEG: float = 2.2
const POLE_SWAY_X_DEG: float = 0.9
const CLOTH_STRETCH: float = 0.12
const CLOTH_BOB: float = 0.012

var _flags: Array = []
var _time: float = 0.0

static func create() -> FlagFlutter:
	var flutter := FlagFlutter.new()
	flutter.name = NODE_NAME
	return flutter

func _ready() -> void:
	_collect_flags()
	set_process(not _flags.is_empty())

func _collect_flags() -> void:
	_flags.clear()
	var root := get_parent() as Node3D
	if root == null:
		return
	var index := 0
	for child in root.get_children():
		if not (child is Node3D):
			continue
		if not String(child.name).begins_with(FLAG_ROOT_PREFIX):
			continue
		var pivot := child.get_node_or_null(FLAG_PIVOT_NAME) as Node3D
		if pivot == null:
			continue
		var cloth := pivot.get_node_or_null(FLAG_CLOTH_NAME) as MeshInstance3D
		if cloth == null:
			continue
		# 每面旗给不同相位，风从建筑一侧扫过去时不会所有旗同时朝一个方向倒。
		_flags.append({
			"pivot": pivot,
			"pivot_base": pivot.rotation,
			"cloth": cloth,
			"cloth_base_pos": cloth.position,
			"phase": float(index) * 0.9 + randf_range(0.0, 0.5),
		})
		index += 1

func _process(delta: float) -> void:
	_time += delta
	for entry in _flags:
		var pivot: Node3D = entry["pivot"]
		var cloth: MeshInstance3D = entry["cloth"]
		if pivot == null or not is_instance_valid(pivot):
			continue
		if cloth == null or not is_instance_valid(cloth):
			continue
		var phase: float = float(entry["phase"])
		# 两个不同频率叠加：慢速主阵风 + 快速小抖动，读起来更像自然风。
		var gust: float = sin(_time * 1.85 + phase) * 0.65 + sin(_time * 3.6 + phase * 1.7) * 0.35
		var base_rot: Vector3 = entry["pivot_base"]
		pivot.rotation.z = base_rot.z + deg_to_rad(POLE_SWAY_DEG) * gust
		pivot.rotation.x = base_rot.x + deg_to_rad(POLE_SWAY_X_DEG) * sin(_time * 2.35 + phase * 1.3)

		var base_pos: Vector3 = entry["cloth_base_pos"]
		cloth.scale.x = 1.0 + CLOTH_STRETCH * gust
		cloth.position.y = base_pos.y + CLOTH_BOB * sin(_time * 4.2 + phase)

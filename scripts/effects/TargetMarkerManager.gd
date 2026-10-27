class_name TargetMarkerManager
extends Node3D

# 单机/联机共用的目标 ❌ 管理器：
#   - 调用方把每个被选中单位的目标整理成请求（跟随实体或地面坐标）；
#   - 相同目标实体、相同地面位置只保留一个标记；
#   - 目标实体移动时标记跟着它的头顶走，目标地点则贴在地表上方。

const GROUND_CLEARANCE: float = 0.32
const ENTITY_HEAD_CLEARANCE: float = 1.0
# 地面目标按 0.5 米量化去重；多个单位点同一位置时只留一个 ❌
const GROUND_MERGE_CELL: float = 0.5

var _battle_manager: Node = null
var _height_fn: Callable = Callable()
var _markers: Dictionary = {}  # key(String) -> TargetMarker

func setup(p_battle_manager: Node) -> void:
	_battle_manager = p_battle_manager
	# 战场还没进树/还没生成地形时不要抓一个永远返回原 y 的兜底闭包；
	# 等 _ensure_height_fn 找到真正的 battle_manager 后再建采样器。
	if _battle_manager != null and is_instance_valid(_battle_manager):
		_height_fn = GroundStripMesh.height_fn_for(_battle_manager)

func refresh_requests(requests: Array) -> void:
	_ensure_height_fn()
	var wanted: Dictionary = {}
	for req in requests:
		if not (req is Dictionary):
			continue
		var key: String = _request_key(req)
		if not wanted.has(key):
			wanted[key] = req
	# 先移除已经失效/不再被选中的标记
	for key in _markers.keys().duplicate():
		if not wanted.has(key):
			var old = _markers[key]
			if is_instance_valid(old):
				old.queue_free()
			_markers.erase(key)
	# 再更新或新建；同一个目标只创建一次
	for key in wanted:
		var req: Dictionary = wanted[key]
		var marker = _markers.get(key)
		if marker == null or not is_instance_valid(marker):
			marker = TargetMarker.new()
			marker.name = "TargetMarker"
			add_child(marker)
			_markers[key] = marker
		_place_marker(marker, req)

func _ensure_height_fn() -> void:
	if _height_fn.is_valid():
		return
	if _battle_manager == null or not is_instance_valid(_battle_manager):
		var tree := get_tree()
		if tree != null:
			_battle_manager = tree.get_first_node_in_group("battle_manager")
	if _battle_manager != null and is_instance_valid(_battle_manager):
		_height_fn = GroundStripMesh.height_fn_for(_battle_manager)

func _request_key(req: Dictionary) -> String:
	if req.has("follow"):
		var follow = req["follow"]
		if is_instance_valid(follow):
			return "e:%d" % follow.get_instance_id()
		return "e:invalid"
	var p: Vector3 = req.get("pos", Vector3.ZERO)
	var gx: int = int(round(p.x / GROUND_MERGE_CELL))
	var gz: int = int(round(p.z / GROUND_MERGE_CELL))
	return "p:%d:%d" % [gx, gz]

func _place_marker(marker, req: Dictionary) -> void:
	var p: Vector3
	if req.has("follow"):
		var follow = req["follow"]
		if not is_instance_valid(follow):
			marker.visible = false
			return
		var head: float = 1.5
		if follow.has_method("get_vision_head_height"):
			head = float(follow.get_vision_head_height())
		p = (follow as Node3D).global_position + Vector3(0.0, head + ENTITY_HEAD_CLEARANCE, 0.0)
	else:
		p = req.get("pos", Vector3.ZERO)
		if _height_fn.is_valid():
			var ground_y: float = float(_height_fn.call(Vector3(p.x, 0.0, p.z)))
			if is_finite(ground_y):
				p.y = ground_y + GROUND_CLEARANCE
	marker.global_position = p
	marker.visible = true

extends Node

# 严格指令回放录制器：管理器中每个“玩家命令”调用 record。
# 结束时写 user://replays/cmd_*.cmdr，回放时由 CommandPlayer 重演。

const CommandReplayScript = preload("res://scripts/replay/CommandReplay.gd")

var _manager: Node = null
var _active: bool = false
var _saved: bool = false
var _data = CommandReplayScript.new()
var _started_at: float = 0.0

func start(manager: Node) -> void:
	if _active:
		return
	_manager = manager
	_active = true
	process_mode = Node.PROCESS_MODE_ALWAYS
	_data.setup_header(manager)
	_started_at = Time.get_ticks_msec()

func record(tick: int, action: String, payload: Dictionary) -> void:
	if not _active:
		return
	_data.add_command(tick, action, payload)

func is_active() -> bool:
	return _active

func finish(reason: String = "对局结束") -> void:
	if not _active:
		return
	_active = false
	if _saved:
		return
	_saved = true
	_data.header["duration"] = float(_manager.game_time) if _manager != null and is_instance_valid(_manager) else 0.0
	_data.header["result"] = reason
	var path := CommandReplayScript.new_path(_data.header)
	if CommandReplayScript.save_file(path, _data.to_dict()):
		print("[指令回放] 已保存: ", path, "  命令 ", _data.commands.size(), "  时长 ", snappedf(float(_data.header.get("duration", 0.0)), 0.1), "s")

func _process(_delta: float) -> void:
	if not _active:
		return
	if _manager == null or not is_instance_valid(_manager):
		finish("场景结束")
		return
	if bool(_manager.get("game_over")):
		finish("对局结束")

func _exit_tree() -> void:
	finish("中途退出")

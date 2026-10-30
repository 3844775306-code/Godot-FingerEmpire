extends RefCounted

# 严格指令回放播放器：在固定物理帧上重演玩家命令。
# 不依赖快照插值；实体位置/血量全部由重跑的模拟产生。

const CommandReplayScript = preload("res://scripts/replay/CommandReplay.gd")

var header: Dictionary = {}
var commands: Array = []
var _idx: int = 0

static func load_from(path: String) -> RefCounted:
	var raw := CommandReplayScript.load_file(path)
	if raw.is_empty():
		return null
	var p = load("res://scripts/replay/CommandPlayer.gd").new()
	p.header = raw.get("header", {})
	p.commands = raw.get("commands", [])
	return p

func tick(manager) -> void:
	if commands.is_empty():
		return
	var now := int(manager.get_sim_tick())
	while _idx < commands.size():
		var c: Dictionary = commands[_idx]
		if int(c.get("t", 0)) > now:
			break
		_idx += 1
		_apply(manager, String(c.get("a", "")), c.get("d", {}))

func _decode_vec(v) -> Vector3:
	if v is Array and v.size() >= 3:
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	return Vector3.ZERO

func _apply(manager, action: String, data: Dictionary) -> void:
	match action:
		"army":
			var e = manager.get_entity_by_sim_uid(int(data.get("uid", -1)))
			if e != null:
				manager.replay_army_command(e, data.get("cmd", {}))
		"build":
			manager.replay_build(int(data.get("id", -1)), _decode_vec(data.get("pos", [])))
		"produce":
			manager.replay_produce(int(data.get("uid", -1)), int(data.get("unit", -1)))
		"upgrade":
			manager.replay_upgrade(int(data.get("uid", -1)))
		"demolish":
			manager.replay_demolish(int(data.get("uid", -1)))
		"stop":
			manager.replay_stop(int(data.get("uid", -1)))
		"garrison":
			manager.replay_garrison(int(data.get("uid", -1)), int(data.get("target_uid", -1)))

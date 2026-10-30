extends Node

# 启动器：真正的自对弈 runner 必须挂在 SceneTree root 下，
# 否则 change_scene_to_file() 时当前场景（含本节点）会被释放，runner 中途断开。
func _ready() -> void:
	var runner := Node.new()
	runner.name = "AISelfPlayRunner"
	runner.set_script(load("res://tools/ai_selfplay_runner.gd"))
	get_tree().root.add_child.call_deferred(runner)
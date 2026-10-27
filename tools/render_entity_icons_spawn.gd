extends Node

# 场景可能在渲染途中被别的自动加载脚本切走，所以把生成器挂到 root 上，避免被一起释放。
func _ready() -> void:
	var r = load("res://tools/render_entity_icons.gd").new()
	r.process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().root.add_child.call_deferred(r)

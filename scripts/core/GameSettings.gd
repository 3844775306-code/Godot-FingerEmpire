extends Node
var player_nation: int = RTSConfig.Nation.VIKING   # 默认
var enemy_nation: int = RTSConfig.Nation.ENGLAND   # AI / 敌方
# GameSettings.gd 中添加
var is_single_2v2: bool = false
# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass # Replace with function body.


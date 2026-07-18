extends Node

enum GameState { MENU, PLAYING, GAME_OVER }
var current_state = GameState.MENU

func _ready():
	# 客户端模式下不自动切换场景
	if NetworkManager.mode == NetworkManager.Mode.CLIENT:
		return
	# 延迟到下一帧切换，避免场景树忙
	call_deferred("change_state", GameState.MENU)

func change_state(new_state: int):
	current_state = new_state
	match new_state:
		GameState.MENU:
			get_tree().change_scene_to_file("res://scenes/main_menu.tscn")   # 确保路径正确
		GameState.PLAYING:
			get_tree().change_scene_to_file("res://scenes/rts_battle.tscn")

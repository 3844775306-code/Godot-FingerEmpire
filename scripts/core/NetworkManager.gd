# scripts/core/NetworkManager.gd
extends Node

static var red_ai_count: int = 0
static var blue_ai_count: int = 0
enum Mode { NONE, SERVER, CLIENT }
var mode: int = Mode.NONE
var peer = ENetMultiplayerPeer.new()
const PORT = 9000

enum GameMode { ONEvONE, TWOVTWO }
static var selected_mode: int = GameMode.ONEvONE
var game_started: bool = false
var max_players
signal connection_success()
signal connection_failed(reason: String)
signal player_joined(peer_id: int)
signal player_left(peer_id: int)

# 缓存的节点引用 — 避免每次 RPC 都遍历场景树
var _cached_renderer = null
var _cached_battle = null
var _cached_map = null

func _ready():
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)

func _get_renderer():
	if not is_instance_valid(_cached_renderer):
		_cached_renderer = get_tree().get_first_node_in_group("client_renderer")
	return _cached_renderer

func _get_battle():
	if not is_instance_valid(_cached_battle):
		_cached_battle = get_tree().get_first_node_in_group("online_battle_manager")
	return _cached_battle

func _get_map():
	if not is_instance_valid(_cached_map):
		_cached_map = get_tree().get_first_node_in_group("client_map")
	return _cached_map

func _invalidate_cache():
	_cached_renderer = null
	_cached_battle = null
	_cached_map = null

func start_server():
	max_players = 2 if selected_mode == GameMode.ONEvONE else 4
	var err = peer.create_server(PORT, max_players)
	if err != OK:
		emit_signal("connection_failed", "创建服务器失败: " + str(err))
		return
	multiplayer.multiplayer_peer = peer
	mode = Mode.SERVER
	game_started = false
	print("服务器已启动，等待连接...")

func start_client(address: String = "127.0.0.1"):
	var err = peer.create_client(address, PORT)
	if err != OK:
		emit_signal("connection_failed", "连接失败: " + str(err))
		return
	multiplayer.multiplayer_peer = peer
	mode = Mode.CLIENT
	print("正在连接服务器...")

func _on_peer_connected(id):
	print("玩家已连接: ", id)
	if mode == Mode.SERVER:
		emit_signal("player_joined", id)
		if multiplayer.get_peers().size() >= max_players - red_ai_count - blue_ai_count and not game_started:
			game_started = true
			print("所有玩家就绪，开始游戏")
			for peer_id in multiplayer.get_peers():
				rpc_id(peer_id, "_load_battle_scene")
			get_tree().change_scene_to_file("res://scenes/rts_battle_online_server.tscn")
	if mode == Mode.CLIENT:
		send_nation_choice.rpc_id(1, GameSettings.player_nation)
		print("已发送国家选择: ", GameSettings.player_nation)

func _on_peer_disconnected(id):
	print("玩家已断开: ", id)
	if mode == Mode.SERVER:
		emit_signal("player_left", id)

@rpc("any_peer", "call_remote", "reliable")
func send_command(data: Dictionary):
	if mode == Mode.SERVER:
		var sender = multiplayer.get_remote_sender_id()
		var battle = _get_battle()
		if battle:
			battle.process_command(sender, data)
		else:
			print("错误：未找到 online_battle_manager！")

@rpc("any_peer", "call_remote", "unreliable")
func _client_receive_snapshot(data: Dictionary):
	if mode == Mode.CLIENT:
		var renderer = _get_renderer()
		if renderer:
			renderer.apply_snapshot(data)

@rpc("authority", "call_remote", "reliable")
func notify_all_player_colors(colors: Dictionary):
	if mode == Mode.CLIENT:
		var renderer = _get_renderer()
		if renderer: renderer.set_all_player_colors(colors)

@rpc("authority", "call_remote", "reliable")
func _notify_team(team: int):
	if mode == Mode.CLIENT:
		var renderer = _get_renderer()
		if renderer: renderer.set_player_team(team)

@rpc("authority", "call_remote", "reliable")
func notify_team_info(peer_id: int, team: int, slot: int, color: Color):
	if mode == Mode.CLIENT:
		var renderer = _get_renderer()
		if renderer: renderer.set_player_info(peer_id, team, slot, color)

@rpc("authority", "call_remote", "reliable")
func _load_battle_scene():
	if mode == Mode.CLIENT:
		_invalidate_cache()
		get_tree().change_scene_to_file("res://scenes/rts_battle_client.tscn")

@rpc("any_peer", "call_remote", "reliable")
func receive_map_data(terrain: Array, resources: Array):
	if mode == Mode.CLIENT:
		RTSConfig.MAP_SIZE = terrain.size()
		var map = _get_map()
		if map:
			map.apply_received_map(terrain, resources)
			var renderer = _get_renderer()
			if renderer: renderer.on_map_size_changed(); renderer._init_fog_grids()

@rpc("authority", "call_remote", "reliable")
func notify_game_over(winner_team: int):
	if mode == Mode.CLIENT:
		var renderer = _get_renderer()
		if renderer: renderer.show_game_over(winner_team)

@rpc("authority", "call_remote", "reliable")
func notify_castle_pos(pos: Vector3):
	if mode == Mode.CLIENT:
		var renderer = _get_renderer()
		if renderer: renderer.set_castle_pos(pos)

@rpc("any_peer", "call_remote", "reliable")
func send_nation_choice(nation: int):
	if mode == Mode.SERVER:
		var peer_id = multiplayer.get_remote_sender_id()
		var battle = _get_battle()
		if battle: battle.assign_nation(peer_id, nation)

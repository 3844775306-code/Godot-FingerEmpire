# scripts/core/NetworkManager.gd
extends Node

static var red_ai_count: int = 0
static var blue_ai_count: int = 0
enum Mode { NONE, SERVER, CLIENT }
var mode: int = Mode.NONE
var peer = ENetMultiplayerPeer.new()
var ws_peer: WebSocketMultiplayerPeer = null
const PORT = 9000
const WS_PORT = 8080

enum GameMode { ONEvONE, TWOVTWO, THREEvTHREE }
static var selected_mode: int = GameMode.ONEvONE

# 每队人数（1v1 无队伍概念，沿用 2 作为 AI 上限参考）
static func get_team_size() -> int:
	return 3 if selected_mode == GameMode.THREEvTHREE else 2

# 总槽位数：1v1=2，2v2=4，3v3=6
static func get_total_slots() -> int:
	return 2 if selected_mode == GameMode.ONEvONE else get_team_size() * 2

# 需要的人类玩家数（总槽位 - AI 数量）
static func get_max_players() -> int:
	return get_total_slots() - red_ai_count - blue_ai_count
static var use_steam: bool = false
enum TransportMode { ENET, WEBSOCKET }
static var use_websocket: bool = false
static var pending_nations: Dictionary = {}  # 缓存场景加载前的国家选择
var game_started: bool = false
var max_players: int = 2   # 默认按 1v1 计算；开局前由 start_server/start_client 按所选模式刷新
signal connection_success()
signal connection_failed(reason: String)
signal player_joined(peer_id: int)
signal player_left(peer_id: int)
signal player_count_updated()
signal upnp_ready(public_ip: String)
signal upnp_failed(reason: String)

# UPnP
var _upnp: UPNP = null
var _public_ip: String = ""
var _upnp_mapped: bool = false
var _steam_retry: bool = false

# 缓存的节点引用 — 避免每次 RPC 都遍历场景树
var _cached_renderer = null
var _cached_battle = null
var _cached_map = null

# 开局握手：客户端战斗场景就绪后才发地图/队伍，避免数据早到被丢弃（表现为客户端黑屏）
var _scene_ready_peers: Dictionary = {}
var pending_map_data: Dictionary = {}   # 场景未就绪时暂存的地图数据
var map_data_applied: bool = false      # 本次战斗的地图是否已应用到客户端

func _ready():
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

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

func start_steam_server():
	use_steam = true
	max_players = get_max_players()
	var impl = SteamManager.get_implementation_info()
	print("[Steam] Starting P2P server, impl=", impl)
	peer = SteamMultiplayerPeer.new()
	print("[Steam] Host SteamMultiplayerPeer instance class: ", peer.get_class())
	var err = peer.create_host(0)
	if err != OK:
		print("[Steam] P2P create_host FAILED: err=", err)
		emit_signal("connection_failed", "Steam server failed (err=%d): unable to create listen socket" % err)
		return
	multiplayer.multiplayer_peer = peer
	mode = Mode.SERVER
	game_started = false
	print("[Steam] P2P server started, Steam ID: ", SteamManager.get_my_steam_id(), " peers=", multiplayer.get_peers())

func start_client_steam(host_steam_id: int = 0):
	use_steam = true
	var impl = SteamManager.get_implementation_info()
	print("[Steam] P2P client connecting to host: ", host_steam_id)
	print("[Steam] Using: ", impl)
	_steam_connect_with_retry(host_steam_id, 0)

func _steam_connect_with_retry(host_id: int, attempt: int):
	peer = SteamMultiplayerPeer.new()
	# 检测实例类名
	print("[Steam] SteamMultiplayerPeer instance class: ", peer.get_class())
	var err = peer.create_client(host_id, 0)
	if err != OK:
		if attempt < 8:
			print("[Steam] P2P retry ", attempt+1, "/8, err=", err, " class=", peer.get_class())
			await get_tree().create_timer(2.0).timeout
			_steam_connect_with_retry(host_id, attempt + 1)
			return
		print("[Steam] P2P create_client failed after 8 retries: err=", err, " class=", peer.get_class())
		# 尝试诊断
		_print_steam_connection_diag(host_id, err)
		emit_signal("connection_failed", "Steam P2P failed (err=%d): unable to reach host. Ensure both players are online and Steam relay is working." % err)
		return
	multiplayer.multiplayer_peer = peer
	mode = Mode.CLIENT
	print("[Steam] P2P connected to host Steam ID: ", host_id)

func _print_steam_connection_diag(host_id: int, err: int):
	print("[Steam] ═══ P2P Connection Diagnostic ═══")
	print("[Steam] Target host Steam ID: ", host_id)
	print("[Steam] My Steam ID: ", SteamManager.get_my_steam_id())
	print("[Steam] Error code: ", err, " (", _p2p_error_string(err), ")")
	print("[Steam] SteamMultiplayerPeer impl: ", SteamManager.get_implementation_info())
	print("[Steam] Lobby members: ", SteamManager.lobby_members)
	print("[Steam] Common causes:")
	print("[Steam]   1. Both players must be online in Steam")
	print("[Steam]   2. Steam relay network may be blocked (firewall/ISP)")
	print("[Steam]   3. SteamMultiplayerPeer class conflict (check logs above)")
	print("[Steam]   4. Virtual port mismatch or host not listening")
	print("[Steam] ════════════════════════════════════")

func _p2p_error_string(err: int) -> String:
	# Steam k_EResult codes
	match err:
		20: return "k_EResultNoConnection"
		2: return "k_EResultFail"
		9: return "k_EResultInvalidParam"
		11: return "k_EResultBusy"
		15: return "k_EResultAccessDenied"
		16: return "k_EResultLimitExceeded"
		_: return "unknown"

func start_server():
	max_players = get_max_players()
	var err = peer.create_server(PORT, max_players)
	if err != OK:
		emit_signal("connection_failed", "创建服务器失败: " + str(err))
		return
	multiplayer.multiplayer_peer = peer
	mode = Mode.SERVER
	game_started = false
	print("服务器已启动，等待连接...")
	_upnp_setup()

func start_ws_server():
	use_websocket = true
	max_players = get_max_players()
	ws_peer = WebSocketMultiplayerPeer.new()
	var err = ws_peer.create_server(WS_PORT)
	if err != OK:
		emit_signal("connection_failed", "WS服务器创建失败: " + str(err))
		return
	multiplayer.multiplayer_peer = ws_peer
	mode = Mode.SERVER
	game_started = false
	print("WebSocket 服务器已启动，端口: ", WS_PORT)
	_upnp_setup()

func start_ws_client(url: String = "ws://127.0.0.1:8080"):
	use_websocket = true
	print("[NetworkManager] WebSocket 客户端连接: ", url)
	ws_peer = WebSocketMultiplayerPeer.new()
	var err = ws_peer.create_client(url)
	if err != OK:
		emit_signal("connection_failed", "WS连接失败: " + str(err))
		return
	multiplayer.multiplayer_peer = ws_peer
	mode = Mode.CLIENT
	print("正在连接 WebSocket 服务器...")

func stop_server():
	if _upnp_mapped:
		var _port = WS_PORT if use_websocket else PORT
		_upnp.remove_port_mapping(_port)
		_upnp_mapped = false
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	peer = ENetMultiplayerPeer.new()
	ws_peer = null
	use_websocket = false
	mode = Mode.NONE
	game_started = false

func get_public_ip() -> String:
	return _public_ip

func _upnp_setup():
	_upnp = UPNP.new()
	var discover_err = _upnp.discover()
	if discover_err != OK:
		emit_signal("upnp_failed", "UPnP not found")
		return
	var elapsed = 0.0
	while _upnp.get_gateway() == null and elapsed < 3.0:
		await get_tree().process_frame
		elapsed += get_process_delta_time()
	var gateway = _upnp.get_gateway()
	if gateway == null or not gateway.is_valid_gateway():
		emit_signal("upnp_failed", "No UPnP gateway")
		return
	var _port = WS_PORT if use_websocket else PORT
	var _proto = "TCP" if use_websocket else "UDP"
	var map_err = _upnp.add_port_mapping(_port, 0, "", _proto, 0)
	if map_err != OK:
		emit_signal("upnp_failed", "Port mapping failed")
		return
	_upnp_mapped = true
	_public_ip = _upnp.query_external_address()
	print("[UPnP] OK, public IP: ", _public_ip, " port: ", _port, " proto: ", _proto)
	emit_signal("upnp_ready", _public_ip)

func start_client(address: String = "127.0.0.1"):
	print("[NetworkManager] start_client connecting to ", address, ":", PORT)
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
		player_count_updated.emit()
	if mode == Mode.CLIENT:
		send_nation_choice.rpc_id(1, GameSettings.player_nation)
		print("已发送国家选择: ", GameSettings.player_nation)

func _on_peer_disconnected(id):
	print("玩家已断开: ", id)
	if mode == Mode.SERVER:
		emit_signal("player_left", id)
		player_count_updated.emit()

func _on_connection_failed():
	print("[NetworkManager] Connection FAILED")
	emit_signal("connection_failed", "Connection failed")
	print("[NetworkManager] ENet connection FAILED")
	emit_signal("connection_failed", "ENet connection failed - check firewall / port 9000")

func _on_connected_to_server():
	print("[NetworkManager] ENet connected to server OK!")
	emit_signal("connection_success")

func _on_server_disconnected():
	print("[NetworkManager] ENet server disconnected")

func can_start_game() -> bool:
	if not mode == Mode.SERVER:
		return false
	if game_started:
		return false
	if use_steam:
		var lobby_count = SteamManager.lobby_members.size()
		var peer_count = multiplayer.get_peers().size()
		var need_humans = max_players
		# 如果所有人类槽都只需要房主自己（AI 填满其他），不需要 P2P 对等连接
		if need_humans <= 1:
			return true
		# 多人：需要大厅人数到位 + P2P 连接已建立
		return lobby_count >= need_humans and peer_count > 0
	# 非 Steam 模式：对等连接 + 房主自身 >= 需要人数
	return (multiplayer.get_peers().size() + 1) >= max_players

func get_connected_count() -> int:
	return (multiplayer.get_peers().size() + 1) if mode == Mode.SERVER else 0

func get_max_humans() -> int:
	return max_players

func get_block_reason() -> String:
	if not mode == Mode.SERVER:
		return "Not the server host"
	if game_started:
		return "Game already started"
	if use_steam:
		var lobby_count = SteamManager.lobby_members.size()
		var peer_count = multiplayer.get_peers().size()
		if max_players <= 1:
			return ""  # 可以开始
		if lobby_count < max_players:
			return "Waiting for players (%d/%d in lobby)" % [lobby_count, max_players]
		if peer_count == 0:
			return "P2P not connected — check Steam network"
		return ""  # 可以开始
	else:
		var count = multiplayer.get_peers().size() + 1
		if count < max_players:
			return "Waiting for players (%d/%d connected)" % [count, max_players]
		return ""  # 可以开始

# 团队模式地图更大：必须在场景加载前设定——Ground 在自己 _ready（子节点先于场景根）里就按当时尺寸生成
func _apply_map_size_for_mode() -> void:
	RTSConfig.MAP_SIZE = 100 if selected_mode == GameMode.ONEvONE else 150

func start_game():
	var reason = get_block_reason()
	if reason != "":
		print("[NetworkManager] start_game blocked: ", reason)
		return reason  # 返回阻止原因给调用方
	game_started = true
	_scene_ready_peers.clear()
	_apply_map_size_for_mode()
	print("[NetworkManager] Starting game, use_steam=", use_steam, " peers=", multiplayer.get_peers().size())
	if use_steam:
		SteamManager.set_lobby_data("game_status", "starting")
	for peer_id in multiplayer.get_peers():
		rpc_id(peer_id, "_load_battle_scene")
	var _t = get_tree(); if _t: _t.change_scene_to_file("res://scenes/rts_battle_online_server.tscn")
	return ""  # 成功

@rpc("any_peer", "call_remote", "reliable")
func send_command(data: Dictionary):
	if mode == Mode.SERVER:
		var sender = multiplayer.get_remote_sender_id()
		if sender == 0: sender = 1  # 房主本地调用 → 映射为 peer_id=1
		var battle = _get_battle()
		if battle:
			battle.process_command(sender, data)
		else:
			print("错误：未找到 online_battle_manager！")

@rpc("authority", "call_remote", "unreliable", 1)
func _client_receive_snapshot(data: Dictionary):
	if mode == Mode.CLIENT:
		var renderer = _get_renderer()
		if renderer and renderer.has_method("apply_snapshot"):
			renderer.apply_snapshot(data)
		else:
			print("[NetworkManager] 警告: ClientRenderer 未就绪，快照被丢弃")

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
		pending_map_data = {}
		map_data_applied = false
		_apply_map_size_for_mode()
		var _t = get_tree(); if _t: _t.change_scene_to_file("res://scenes/rts_battle_client.tscn")

# 客户端战斗场景进树后主动上报；主机收到后再下发地图/队伍，避免地图数据早到被丢弃
@rpc("any_peer", "call_remote", "reliable")
func client_scene_ready():
	if mode == Mode.SERVER:
		var sender := multiplayer.get_remote_sender_id()
		if sender == 0: sender = 1
		_scene_ready_peers[sender] = true

# 主机等待所有真实客户端场景就绪（带超时兜底，避免旧客户端卡死开局）
func wait_clients_scene_ready(peers: Array, timeout_sec: float = 8.0) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	var pending: Array = peers.duplicate()
	while not pending.is_empty() and Time.get_ticks_msec() < deadline:
		pending = pending.filter(func(pid): return not _scene_ready_peers.has(pid))
		if pending.is_empty():
			break
		await get_tree().create_timer(0.05).timeout
	if not pending.is_empty():
		print("[NetworkManager] 等待客户端场景就绪超时，仍继续开局: ", str(pending))

# 客户端场景就绪后的兜底：先吃暂存地图，迟一点还没收到就主动补请（最多 3 次）
func _client_map_ready() -> void:
	if mode != Mode.CLIENT:
		return
	if consume_pending_map():
		return
	for attempt in range(3):
		for _i in range(20):
			await get_tree().create_timer(0.1).timeout
			if mode != Mode.CLIENT or map_data_applied:
				return
			if consume_pending_map():
				return
		print("[NetworkManager] 客户端未收到地图数据，请求补发（第 %d 次）" % (attempt + 1))
		request_map_data()

@rpc("any_peer", "call_remote", "reliable")
func _request_map_data():
	if mode == Mode.SERVER:
		var sender := multiplayer.get_remote_sender_id()
		if sender == 0: sender = 1
		var battle = _get_battle()
		if battle and battle.has_method("_send_map_data"):
			print("[NetworkManager] 客户端请求补发地图: ", sender)
			battle._send_map_data([sender])

func request_map_data() -> void:
	if mode != Mode.CLIENT:
		return
	var peer = multiplayer.multiplayer_peer
	if peer == null or peer is OfflineMultiplayerPeer:
		return
	if peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return
	rpc_id(1, "_request_map_data")

@rpc("any_peer", "call_remote", "reliable")
func receive_map_data(terrain: Array, height_data: Array, resources: Array, map_id: String, overlay_zip: PackedByteArray):
	if mode != Mode.CLIENT:
		return
	RTSConfig.MAP_SIZE = terrain.size()
	GameSettings.map_id = map_id
	var payload := {
		"terrain": terrain, "height": height_data, "resources": resources,
		"map_id": map_id, "overlay_zip": overlay_zip,
	}
	# 客户端场景可能还没加载完（Ground 还没进树）：先暂存，等场景就绪后再应用
	if _get_map() == null or _get_renderer() == null:
		pending_map_data = payload
		print("[NetworkManager] 地图数据早到，暂存待客户端场景就绪后应用")
		return
	_apply_received_map_data(payload)

func has_pending_map() -> bool:
	return not pending_map_data.is_empty()

func consume_pending_map() -> bool:
	if pending_map_data.is_empty():
		return false
	if _get_map() == null or _get_renderer() == null:
		return false
	var payload: Dictionary = pending_map_data
	pending_map_data = {}
	_apply_received_map_data(payload)
	return true

func _apply_received_map_data(payload: Dictionary) -> void:
	var terrain: Array = payload.get("terrain", [])
	var height_data: Array = payload.get("height", [])
	var resources: Array = payload.get("resources", [])
	var map_id: String = String(payload.get("map_id", "classic"))
	var overlay_zip: PackedByteArray = payload.get("overlay_zip", PackedByteArray())
	var size: int = terrain.size()
	if size <= 0:
		return
	# 覆盖层随地图下发（压缩字节流）；缺失时按全 0 处理，兼容旧格式
	var overlay := PackedByteArray()
	if overlay_zip.size() > 0:
		overlay = overlay_zip.decompress(size * size, FileAccess.COMPRESSION_ZSTD)
	var map = _get_map()
	if map == null:
		pending_map_data = payload
		return
	map.apply_received_map(terrain, height_data, resources, overlay, map_id)
	map_data_applied = true
	var renderer = _get_renderer()
	if renderer and renderer.has_method("_add_water_box"):
		var fog_tex = null
		if map.has_method("get_terrain_texture"):
			fog_tex = map.get_terrain_texture()
		renderer._add_water_box(size, fog_tex)
	if renderer:
		# 客户端迷雾与主机同口径：地图倍率/高地/森林修正
		if map.map_preset is Dictionary:
			renderer.map_modifiers = map.map_preset.get("modifiers", {})
		renderer.on_map_size_changed()
		renderer._init_fog_grids()
	print("[NetworkManager] 客户端地图已应用: %s %dx%d" % [map_id, size, size])




@rpc("authority", "call_remote", "reliable")
func show_results(history: Array, player_is_blue: bool):
	if mode == Mode.CLIENT:
		GameSettings.post_game_data = {"history": history, "is_blue": player_is_blue}
		var _t = get_tree(); if _t: _t.change_scene_to_file("res://scenes/main_menu.tscn")

@rpc("authority", "call_remote", "reliable")
func notify_game_over(winner_team: int, stats_payload: Dictionary = {}):
	if mode == Mode.CLIENT:
		var renderer = _get_renderer()
		if renderer: renderer.show_game_over(winner_team, stats_payload)

@rpc("authority", "call_remote", "reliable")
func notify_castle_pos(pos: Vector3):
	if mode == Mode.CLIENT:
		var renderer = _get_renderer()
		if renderer: renderer.set_castle_pos(pos)
@rpc("any_peer", "call_remote", "reliable")
func ping_server(client_time: int):
	pong_client.rpc_id(multiplayer.get_remote_sender_id(), client_time)

@rpc("authority", "call_remote", "reliable")
func pong_client(client_time: int):
	var hud = get_tree().get_first_node_in_group("client_hud")
	if hud: hud._ping_rtt = Time.get_ticks_msec() - client_time


@rpc("any_peer", "call_remote", "reliable")
func send_nation_choice(nation: int):
	if mode == Mode.SERVER:
		var peer_id = multiplayer.get_remote_sender_id()
		if peer_id == 0: peer_id = 1  # 房主本地调用 → 映射为 peer_id=1
		pending_nations[peer_id] = nation  # 始终缓存（场景可能尚未加载）
		var battle = _get_battle()
		if battle: battle.assign_nation(peer_id, nation)

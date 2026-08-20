# scripts/core/SteamManager.gd
# Steam 管理器 — 初始化、大厅、P2P 网络
extends Node

enum LobbyState { NONE, CREATING, IN_LOBBY, JOINING }

var lobby_state: int = LobbyState.NONE
var lobby_id: int = 0
var lobby_members: Dictionary = {}
var steam_initialized: bool = false
var _game_started: bool = false
var _steam_tick: float = 0.0
var _p2p_session_count: int = 0
var _using_steam_sockets: bool = false  # true = steam-multiplayer-peer (Steam Sockets), false = GodotSteam 内置

const MAX_MEMBERS: int = 6
const STEAM_APP_ID: int = 480  # Spacewar test App ID（正式发布需替换）

# 信号
signal steam_ready()
signal steam_init_failed(reason: String)
signal lobby_created(lobby_id: int)
signal lobby_joined(lobby_id: int)
signal lobby_join_failed(reason: String)
signal lobby_list_received(lobbies: Array)
signal lobby_member_joined(steam_id: int, name: String)
signal lobby_member_left(steam_id: int)
signal p2p_packet_received(steam_id: int, data: PackedByteArray, channel: int)
signal game_starting()

func _ready():
	if not Engine.has_singleton("Steam"):
		print("[Steam] Steam singleton not available (export missing steam_api64.dll?)")
		emit_signal("steam_init_failed", "Steam SDK not loaded, check export files")
		return
	
	print("[Steam] initializing...")
	var init_result = Steam.steamInitEx(false, STEAM_APP_ID)
	print("[Steam] steamInitEx returned: ", init_result, " type=", typeof(init_result))
	var err: int = 1
	if init_result is Dictionary:
		err = init_result.get("status", 1)
		print("[Steam] init dict keys: ", init_result.keys())
	elif init_result is int:
		err = init_result
	if err != OK:
		var msg = "Steam init failed (err=%d), make sure Steam client is running" % err
		print("[Steam] ", msg)
		emit_signal("steam_init_failed", msg)
		return
	steam_initialized = true
	Steam.allowP2PPacketRelay(true)
	print("[Steam] init OK, relay enabled, user: ", Steam.getPersonaName())
	_connect_signals()
	emit_signal("steam_ready")
	detect_peer_implementation()

func _connect_signals():
	# 大厅回调
	Steam.lobby_created.connect(_on_lobby_created)
	Steam.lobby_joined.connect(_on_lobby_joined)
	Steam.lobby_match_list.connect(_on_lobby_match_list)
	Steam.lobby_data_update.connect(_on_lobby_data_update)
	Steam.lobby_chat_update.connect(_on_lobby_chat_update)
	# P2P 会话 — 注意：SteamMultiplayerPeer 内部自行管理 P2P 会话
	# 这里仅监听 connect_fail 用于诊断，不再手动 AcceptP2PSession
	Steam.p2p_session_connect_fail.connect(_on_p2p_session_fail)
	_p2p_session_count = 0

func _process(_delta):
	if not steam_initialized:
		return
	# run_callbacks 必须每帧调用（GodotSteam 官方要求）——节流会导致可靠消息 ack 与连接事件
	# 延迟最多 100ms，是 Steam 联机延迟的来源之一
	Steam.run_callbacks()
	_steam_tick += _delta
	if _steam_tick > 0.1:
		_steam_tick = 0.0
		_read_p2p_packets()

# ═══ 大厅创建 ═══
func create_lobby(lobby_type: int = 2):
	if not steam_initialized:
		return
	lobby_state = LobbyState.CREATING
	Steam.createLobby(lobby_type, MAX_MEMBERS - NetworkManager.red_ai_count - NetworkManager.blue_ai_count)

func _on_lobby_created(connect: int, id: int):
	if connect == 1:
		lobby_id = id
		lobby_state = LobbyState.IN_LOBBY
		# 设置大厅数据
		Steam.setLobbyData(lobby_id, "game", "FingerEmpire")
		var mode_str = "1v1"
		if NetworkManager.selected_mode == NetworkManager.GameMode.TWOVTWO:
			mode_str = "2v2"
		elif NetworkManager.selected_mode == NetworkManager.GameMode.THREEvTHREE:
			mode_str = "3v3"
		Steam.setLobbyData(lobby_id, "mode", mode_str)
		Steam.setLobbyData(lobby_id, "host_name", Steam.getPersonaName())
		_refresh_members()
		print("[Steam] 大厅创建成功: ", lobby_id)
		emit_signal("lobby_created", lobby_id)
	else:
		print("[Steam] 大厅创建失败: ", connect)
		lobby_state = LobbyState.NONE
		emit_signal("lobby_join_failed", "创建大厅失败")

# ═══ 大厅搜索 ═══
func search_lobbies():
	if not steam_initialized:
		return
	# 用 "game" 键过滤 FingerEmpire 大厅
	Steam.addRequestLobbyListStringFilter("game", "FingerEmpire", 0)
	Steam.requestLobbyList()

func _on_lobby_match_list(lobbies: Array):
	print("[Steam] 收到大厅列表: ", lobbies.size(), " 个")
	var result: Array = []
	for lid in lobbies:
		var info: Dictionary = {
			"id": lid,
			"host_name": Steam.getLobbyData(lid, "host_name"),
			"mode": Steam.getLobbyData(lid, "mode"),
			"members": Steam.getNumLobbyMembers(lid),
			"max_members": Steam.getLobbyMemberLimit(lid),
		}
		result.append(info)
	emit_signal("lobby_list_received", result)

# ═══ 加入大厅 ═══
func join_lobby(id: int):
	if not steam_initialized:
		return
	lobby_state = LobbyState.JOINING
	Steam.joinLobby(id)

func _on_lobby_joined(id: int, _permissions: int, _locked: bool, response: int):
	if response == 1:
		lobby_id = id
		lobby_state = LobbyState.IN_LOBBY
		_refresh_members()
		print("[Steam] 加入大厅成功: ", lobby_id)
		emit_signal("lobby_joined", lobby_id)
	else:
		lobby_state = LobbyState.NONE
		var msg = "加入大厅失败 (code=%d)" % response
		print("[Steam] ", msg)
		emit_signal("lobby_join_failed", msg)

func leave_lobby():
	if lobby_id != 0:
		Steam.leaveLobby(lobby_id)
	lobby_id = 0
	lobby_state = LobbyState.NONE
	lobby_members.clear()

func _refresh_members():
	if lobby_id == 0:
		return
	lobby_members.clear()
	var count = Steam.getNumLobbyMembers(lobby_id)
	for i in range(count):
		var sid = Steam.getLobbyMemberByIndex(lobby_id, i)
		lobby_members[sid] = Steam.getFriendPersonaName(sid)

func _on_lobby_data_update(_success: int, lid: int, _member: int):
	if lid == lobby_id:
		var status = Steam.getLobbyData(lobby_id, "game_status")
		if status == "starting" and not _game_started:
			_game_started = true
			print("[Steam] Game starting signal from host!")
			emit_signal("game_starting")
		lobby_members.clear()
		var count = Steam.getNumLobbyMembers(lobby_id)
		for i in range(count):
			var sid = Steam.getLobbyMemberByIndex(lobby_id, i)
			lobby_members[sid] = Steam.getFriendPersonaName(sid)

func _on_lobby_chat_update(lid: int, changed_id: int, making_change_id: int, chat_state: int):
	if lid != lobby_id:
		return
	match chat_state:
		1:
			var pname = Steam.getFriendPersonaName(changed_id)
			lobby_members[changed_id] = pname
			print("[Steam] 成员加入: ", pname)
			emit_signal("lobby_member_joined", changed_id, pname)
		2, 4, 8:
			lobby_members.erase(changed_id)
			print("[Steam] 成员离开: ", changed_id)
			emit_signal("lobby_member_left", changed_id)

# ═══ Steam P2P 网络 ═══
# 注意：不再手动 AcceptP2PSessionWithUser，由 SteamMultiplayerPeer 内部管理
# 旧 P2P API (ISteamNetworking) 的回调仅用于诊断日志
func _on_p2p_session_request(remote_id: int):
	_p2p_session_count += 1
	print("[Steam] P2P session request from: ", remote_id, " (count=", _p2p_session_count, ") — handled by SteamMultiplayerPeer")


func _on_p2p_session_fail(steam_id: int, session_error: int):
	print("[Steam] P2P 会话失败: ", steam_id, " err=", session_error)

func send_p2p_packet(target: int, data: PackedByteArray, reliable: bool = true, channel: int = 0):
	if not steam_initialized:
		return false
	var send_type = 0 if reliable else 1
	return Steam.sendP2PPacket(target, data, send_type, channel)

func broadcast_p2p(data: PackedByteArray, reliable: bool = true, channel: int = 0):
	for sid in lobby_members.keys():
		if sid == Steam.getSteamID():
			continue
		send_p2p_packet(sid, data, reliable, channel)

func _read_p2p_packets():
	while Steam.getAvailableP2PPacketSize(0) > 0:
		var packet = Steam.readP2PPacket(0)
		if packet.size() > 0 and packet.has("data") and packet.has("steam_id"):
			emit_signal("p2p_packet_received", packet["steam_id"], packet["data"], 0)

# ═══ 工具 ═══
func get_lobby_owner() -> int:
	if lobby_id == 0:
		return 0
	var owner = Steam.getLobbyOwner(lobby_id)
	print("[SteamManager] lobby owner Steam ID: ", owner, " my Steam ID: ", Steam.getSteamID())
	return owner

func is_lobby_owner() -> bool:
	if lobby_id == 0:
		return false
	return Steam.getLobbyOwner(lobby_id) == Steam.getSteamID()

func get_my_steam_id() -> int:
	return Steam.getSteamID()

func get_my_name() -> String:
	return Steam.getPersonaName()

func get_lobby_data(key: String) -> String:
	if lobby_id == 0:
		return ""
	return Steam.getLobbyData(lobby_id, key)

func set_lobby_data(key: String, value: String):
	if lobby_id == 0 or not is_lobby_owner():
		return
	Steam.setLobbyData(lobby_id, key, value)

# 检测使用的是哪个 SteamMultiplayerPeer 实现
func detect_peer_implementation():
	if not steam_initialized:
		return
	# 通过 ClassDB 检查类是否存在
	if not ClassDB.class_exists("SteamMultiplayerPeer"):
		print("[Steam] ERROR: SteamMultiplayerPeer class not registered!")
		print("[Steam] Make sure steam-multiplayer-peer or GodotSteam GDExtension is loaded.")
		return

	# 获取类的原生基类信息来推断实现
	var methods = ClassDB.class_get_method_list("SteamMultiplayerPeer")
	var has_socket_methods = false
	var has_message_methods = false
	for m in methods:
		var mname = m.get("name", "")
		if mname.to_lower().contains("socket"):
			has_socket_methods = true
		if mname.to_lower().contains("message"):
			has_message_methods = true

	# 尝试通过类路径推断
	var parent = ClassDB.get_parent_class("SteamMultiplayerPeer")
	print("[Steam] SteamMultiplayerPeer parent class: ", parent)
	print("[Steam] SteamMultiplayerPeer method count: ", methods.size())

	# steam-multiplayer-peer GDExtension 路径检测
	var has_steam_mp_gdext = FileAccess.file_exists("res://addons/steam-multiplayer-peer/steam-multiplayer-peer.gdextension")
	if has_steam_mp_gdext:
		_using_steam_sockets = true
		print("[Steam] Detected: steam-multiplayer-peer GDExtension (Steam Sockets)")
	else:
		_using_steam_sockets = false
		print("[Steam] Using: GodotSteam built-in SteamMultiplayerPeer (Steam Networking Messages)")

	# 验证虚拟端口参数
	print("[Steam] ── P2P config: relay enabled, sockets=", _using_steam_sockets)

func get_implementation_info() -> String:
	if not steam_initialized:
		return "Steam not initialized"
	if not ClassDB.class_exists("SteamMultiplayerPeer"):
		return "SteamMultiplayerPeer NOT REGISTERED"
	if _using_steam_sockets:
		return "steam-multiplayer-peer (Steam Sockets v0.2.0)"
	return "GodotSteam built-in (Steam Networking Messages)"

func shutdown():
	if not steam_initialized:
		return
	leave_lobby()
	Steam.steamShutdown()
	steam_initialized = false
	print("[Steam] 已关闭")

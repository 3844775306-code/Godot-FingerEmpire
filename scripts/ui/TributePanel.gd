class_name TributePanel
extends Panel

# 多人/团队模式进贡面板：只能给同队队友（含 AI 队友）进贡，系统扣 20% 税。
# 客户端走 RPC 交给服务器结算；单机/房主本地直接调用 RTSBattleManager.tribute_resources。
const TAX_RATE: float = 0.20
const RES_LABELS: Dictionary = {"gold": "黄金", "wood": "木材", "stone": "石头", "food": "食物", "oil": "石油"}
const AMOUNTS: Array = [100, 300, 500, 1000, 2000]

var _bm = null
var _local_owner: int = -1
var _local_team: int = -1
var _remote_roster: Dictionary = {}
var _targets: Array = []

var _target_opt: OptionButton = null
var _res_opt: OptionButton = null
var _amount_opt: OptionButton = null
var _preview: Label = null
var _status: Label = null
var _refresh_timer: float = 0.0

func setup(bm, local_owner: int, remote_roster: Dictionary = {}, local_team: int = -1) -> void:
	_bm = bm
	_local_owner = local_owner
	_local_team = local_team
	_remote_roster = remote_roster
	_build_ui()
	refresh()

func _build_ui() -> void:
	name = "TributePanel"
	z_index = 250
	size = Vector2(430, 270)
	custom_minimum_size = size
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_theme_stylebox_override("panel", UITheme.panel_style(UITheme.RADIUS_LG, UITheme.BORDER_MED, 0.96))
	visible = false

	var title := Label.new()
	title.text = "🤝 进贡队友（扣 20% 税）"
	title.position = Vector2(18, 10)
	title.add_theme_font_size_override("font_size", UITheme.FONT_XL)
	title.add_theme_color_override("font_color", UITheme.GOLD)
	add_child(title)

	var close := Button.new()
	close.text = "✕"
	close.position = Vector2(size.x - 42, 8)
	close.custom_minimum_size = Vector2(30, 28)
	UITheme.apply_muted_button(close, UITheme.FONT_MD)
	close.pressed.connect(func(): visible = false)
	add_child(close)

	var tip := Label.new()
	tip.text = "发送方扣除所选数量，队友只收到 80%；仅限同队队友。"
	tip.position = Vector2(18, 42)
	tip.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	tip.add_theme_color_override("font_color", Color(0.78, 0.78, 0.78))
	add_child(tip)

	var target_lb := Label.new()
	target_lb.text = "队友"
	target_lb.position = Vector2(18, 76)
	target_lb.size = Vector2(52, 28)
	target_lb.add_theme_font_size_override("font_size", UITheme.FONT_MD)
	add_child(target_lb)
	_target_opt = OptionButton.new()
	_target_opt.position = Vector2(74, 72)
	_target_opt.size = Vector2(330, 32)
	UITheme.apply_muted_button(_target_opt, UITheme.FONT_MD)
	_target_opt.item_selected.connect(func(_i): _update_preview())
	add_child(_target_opt)

	var res_lb := Label.new()
	res_lb.text = "资源"
	res_lb.position = Vector2(18, 116)
	res_lb.size = Vector2(52, 28)
	res_lb.add_theme_font_size_override("font_size", UITheme.FONT_MD)
	add_child(res_lb)
	_res_opt = OptionButton.new()
	_res_opt.position = Vector2(74, 112)
	_res_opt.size = Vector2(150, 32)
	UITheme.apply_muted_button(_res_opt, UITheme.FONT_MD)
	for rk in ["gold", "wood", "stone", "food", "oil"]:
		_res_opt.add_item("%s %s" % [UITheme.RESOURCE_ICONS.get(rk, ""), RES_LABELS[rk]])
		_res_opt.set_item_metadata(_res_opt.item_count - 1, rk)
	_res_opt.item_selected.connect(func(_i): _update_preview())
	add_child(_res_opt)

	var amount_lb := Label.new()
	amount_lb.text = "数量"
	amount_lb.position = Vector2(18, 156)
	amount_lb.size = Vector2(52, 28)
	amount_lb.add_theme_font_size_override("font_size", UITheme.FONT_MD)
	add_child(amount_lb)
	_amount_opt = OptionButton.new()
	_amount_opt.position = Vector2(74, 152)
	_amount_opt.size = Vector2(150, 32)
	UITheme.apply_muted_button(_amount_opt, UITheme.FONT_MD)
	for n in AMOUNTS:
		_amount_opt.add_item(str(n))
	_amount_opt.select(1)
	_amount_opt.item_selected.connect(func(_i): _update_preview())
	add_child(_amount_opt)

	_preview = Label.new()
	_preview.position = Vector2(240, 158)
	_preview.size = Vector2(170, 24)
	_preview.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_preview.add_theme_color_override("font_color", Color(0.55, 0.9, 0.7))
	add_child(_preview)

	_status = Label.new()
	_status.position = Vector2(18, 194)
	_status.size = Vector2(392, 24)
	_status.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_status.add_theme_color_override("font_color", Color(1.0, 0.8, 0.3))
	add_child(_status)

	var send := Button.new()
	send.text = "发送进贡"
	send.position = Vector2(18, 222)
	send.size = Vector2(394, 34)
	UITheme.apply_primary_button(send, UITheme.FONT_MD)
	send.pressed.connect(_on_send)
	add_child(send)

func open() -> void:
	refresh()
	var vp := get_viewport().get_visible_rect().size
	position = (vp - size) * 0.5
	visible = true
	move_to_front()

func _process(delta: float) -> void:
	if not visible:
		return
	_refresh_timer -= delta
	if _refresh_timer <= 0.0:
		_refresh_timer = 2.0
		refresh()

func refresh() -> void:
	if _target_opt == null:
		return
	var old_target: int = -1
	if _target_opt.selected >= 0 and _target_opt.selected < _targets.size():
		old_target = int(_targets[_target_opt.selected])
	_target_opt.clear()
	_targets.clear()
	var roster: Dictionary = _remote_roster if not _remote_roster.is_empty() else _get_local_roster()
	var my_team: int = _local_team
	if my_team < 0 and _bm != null and _bm.has_method("get_team_of_owner"):
		my_team = int(_bm.get_team_of_owner(_local_owner))
	var pids: Array = roster.keys()
	pids.sort()
	for pid in pids:
		var info: Dictionary = roster.get(pid, {})
		if int(pid) == _local_owner or not bool(info.get("alive", true)):
			continue
		var team: int = int(info.get("team", -1))
		if my_team >= 0 and team != my_team:
			continue
		var nation: int = int(info.get("nation", -1))
		var nation_name: String = ""
		if nation >= 0 and nation < BattleStats.NATION_NAMES.size():
			nation_name = String(BattleStats.NATION_NAMES[nation])
		var tag: String = "AI队友" if bool(info.get("is_ai", false)) else "队友"
		var text: String = "%s %s" % [tag, nation_name if nation_name != "" else ("P%d" % int(pid))]
		_target_opt.add_item(text)
		_targets.append(int(pid))
		if old_target == int(pid):
			_target_opt.select(_target_opt.item_count - 1)
	if _targets.is_empty():
		_target_opt.add_item("没有可进贡的队友（仅 2v2/3v3）")
		_target_opt.disabled = true
	else:
		_target_opt.disabled = false
		if _target_opt.selected < 0:
			_target_opt.select(0)
	_update_preview()

func _get_local_roster() -> Dictionary:
	if _bm != null and _bm.has_method("get_player_roster"):
		return _bm.get_player_roster()
	return {}

func _update_preview() -> void:
	if _preview == null:
		return
	var amount: int = 0
	if _amount_opt != null and _amount_opt.selected >= 0:
		amount = int(AMOUNTS[_amount_opt.selected])
	var received: int = int(floor(float(amount) * (1.0 - TAX_RATE)))
	_preview.text = "实收 %d（税 %d）" % [received, amount - received]

func _on_send() -> void:
	if _targets.is_empty() or _target_opt == null or _target_opt.disabled:
		_status.text = "当前没有可进贡的队友"
		return
	var target: int = int(_targets[_target_opt.selected])
	var rk: String = String(_res_opt.get_item_metadata(_res_opt.selected))
	var amount: int = int(AMOUNTS[_amount_opt.selected])
	if NetworkManager.mode == NetworkManager.Mode.CLIENT:
		NetworkManager.send_command.rpc_id(1, {
			"action": "tribute", "target_peer": target, "resource": rk, "amount": amount,
		})
		_status.text = "已发送，服务器结算后会在战况栏提示"
		return
	if _bm == null or not _bm.has_method("tribute_resources"):
		_status.text = "当前模式不支持进贡"
		return
	var result: Dictionary = _bm.tribute_resources(_local_owner, target, rk, amount)
	if bool(result.get("ok", false)):
		_status.text = "已进贡 %d %s，对方实收 %d" % [int(result["sent"]), RES_LABELS.get(rk, rk), int(result["received"])]
		refresh()
	else:
		_status.text = "进贡失败：%s" % String(result.get("reason", "未知原因"))

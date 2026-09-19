# scripts/client/CommandCard.gd
# 独立命令卡覆盖层 — O 键切换显示/隐藏，4×5 网格，全部建造热键
class_name CommandCard
extends Control

const BTN_W = 130; const BTN_H = 48; const COLS = 5; const ROWS = 4
var _buttons: Array[Button] = []
var _grid: GridContainer
var _bg: Panel

func _ready():
	_bg = Panel.new(); _bg.size = Vector2(BTN_W*COLS + 16, BTN_H*ROWS + 16)
	_bg.add_theme_stylebox_override("panel", UITheme.card_style(UITheme.GOLD)); add_child(_bg)

	_grid = GridContainer.new(); _grid.position = Vector2(8, 8)
	_grid.columns = COLS
	_grid.add_theme_constant_override("h_separation", 4)
	_grid.add_theme_constant_override("v_separation", 3); add_child(_grid)

	for i in range(ROWS * COLS):
		var btn = _make_btn(); _grid.add_child(btn); _buttons.append(btn)

	position = Vector2(450, 1080); visible = false

func _make_btn() -> Button:
	var b = Button.new(); b.custom_minimum_size = Vector2(BTN_W, BTN_H)
	UITheme.apply_command_button(b, UITheme.FONT_XS)
	b.disabled = true
	return b

const COST_NAMES = {"food":"食","wood":"木","stone":"石","gold":"金","oil":"油"}

func _cost_str(cost: Dictionary) -> String:
	var p = []; for k in cost: p.append("%d%s" % [cost[k], COST_NAMES.get(k,k)])
	return " ".join(p)

func _can_build(bid: int, res: Dictionary, castle_lv: int, bm) -> bool:
	var cfg = EntityDatabase.get_config(bid)
	if cfg.is_empty(): return false
	var cost = cfg.get("cost",{})
	for k in cost: if res.get(k,0) < cost[k]: return false
	if bm and bm.has_method("is_building_unlocked"): return bm.is_building_unlocked(bid)
	return true

# ==================== 无选中：全部建造热键 ====================
func show_construct(res: Dictionary, castle_lv: int, bm):
	var entries = [
		["Q",28,"民居"], ["W",22,"仓库"], ["E",41,"瞭望塔"], ["R",52,"集市"], ["T",42,"书院"],
		["Y",7,"桥"],   ["U",8,"梯子"],
		["A",21,"兵营"], ["S",23,"船坞"], ["D",24,"攻城车间"], ["F",29,"重装厂"], ["G",54,"修道院"],
		["H",53,"城堡"],
		["Z",27,"城墙"], ["X",64,"炮台"], ["C",25,"箭塔"],   ["V",26,"炮塔"], ["B",8,"梯子"],
	]
	for i in range(_buttons.size()):
		var btn = _buttons[i]; btn.visible = true; btn.modulate = Color.WHITE
		if i < entries.size():
			var e = entries[i]; var bid = e[1]
			var cfg = EntityDatabase.get_config(bid); var cost = cfg.get("cost",{})
			var ok = _can_build(bid, res, castle_lv, bm)
			btn.disabled = not ok; btn.modulate = Color.WHITE if ok else Color(0.5,0.5,0.5)
			btn.text = "[%s]%s %s" % [e[0], e[2], _cost_str(cost)]
			if btn.pressed.is_connected(_d): btn.pressed.disconnect(_d)
			btn.pressed.connect(func(): _start_build(bid), CONNECT_ONE_SHOT)
		else:
			btn.visible = false; btn.disabled = true

# ==================== 选中建筑：生产 + 操作 ====================
func show_building(produces: Array, bid: int, eid: int, bm):
	var res = bm.get_host_resources() if bm else {}
	for i in range(_buttons.size()):
		var btn = _buttons[i]; btn.visible = true
		if i < produces.size():
			var pid = produces[i]["unit_id"]; var uc = EntityDatabase.get_config(pid)
			# production_list 里带的是按建筑等级加成后的 current_cost，优先用它
			var cost = produces[i].get("current_cost", uc.get("cost",{}))
			var hk = ["Q","W","E","R","F"][min(i,4)]
			var ok = true; for k in cost: if res.get(k,0) < cost[k]: ok = false
			btn.disabled = not ok; btn.modulate = Color.WHITE if ok else Color(0.5,0.5,0.5)
			btn.text = "[%s]%s %s" % [hk, uc.get("name","?"), _cost_str(cost)]
			if btn.pressed.is_connected(_d): btn.pressed.disconnect(_d)
			btn.pressed.connect(func(): _send_produce(bid, pid), CONNECT_ONE_SHOT)
		elif i == 5:
			var upg = EntityDatabase.get_config(eid).get("upgrades",[])
			btn.text = "[A]升级"; btn.disabled = (upg.size()==0)
			btn.modulate = Color.WHITE if upg.size()>0 else Color(0.5,0.5,0.5)
			if btn.pressed.is_connected(_d): btn.pressed.disconnect(_d)
			if upg.size()>0: btn.pressed.connect(func(): _send_upgrade(bid), CONNECT_ONE_SHOT)
		elif i == 6:
			btn.text = "[S]拆除"; btn.disabled = (eid==20)
			btn.modulate = Color(1,0.3,0.3) if eid!=20 else Color(0.5,0.5,0.5)
			if btn.pressed.is_connected(_d): btn.pressed.disconnect(_d)
			if eid!=20: btn.pressed.connect(func(): _send_demolish(bid), CONNECT_ONE_SHOT)
		elif i == 7:
			btn.text = "[D]释放"; btn.disabled = false; btn.modulate = Color.WHITE
			if btn.pressed.is_connected(_d): btn.pressed.disconnect(_d)
			btn.pressed.connect(func(): _send_ungarrison(bid), CONNECT_ONE_SHOT)
		else:
			btn.visible = false; btn.disabled = true

# ==================== 选中军队 ====================
func show_army():
	var labels = ["[Q]清除状态","[W]移动攻击","[E]进驻最近","[R]全选同类","[F]巡逻模式"]
	var labels2 = ["[A]攻敌主城","[S]撤回主城","[D]释放进驻"]
	for i in range(_buttons.size()):
		var btn = _buttons[i]; btn.visible = true; btn.disabled = false; btn.modulate = Color.WHITE
		if i < labels.size(): btn.text = labels[i]
		elif i >= 5 and i-5 < labels2.size(): btn.text = labels2[i-5]
		else: btn.visible = false

func hide_all():
	for btn in _buttons: btn.visible = false

# ---- 发送命令 ----
func _send_produce(bid: int, uid: int):
	var cr = get_tree().get_first_node_in_group("client_renderer")
	if cr: NetworkManager.send_command.rpc_id(1, {"action":"produce","building_id":bid,"unit_id":uid,"ctrl_held":false,"shift_held":false})
	else: _call_bm("produce_unit", [bid, uid])

func _send_upgrade(bid: int):
	var cr = get_tree().get_first_node_in_group("client_renderer")
	if cr: NetworkManager.send_command.rpc_id(1, {"action":"upgrade","building_id":bid})
	else: _call_bm("upgrade_building", [bid])

func _send_demolish(bid: int):
	var cr = get_tree().get_first_node_in_group("client_renderer")
	if cr: NetworkManager.send_command.rpc_id(1, {"action":"demolish","building_id":bid})
	else: _call_bm("demolish_building", [bid])

func _send_ungarrison(bid: int):
	var cr = get_tree().get_first_node_in_group("client_renderer")
	if cr: NetworkManager.send_command.rpc_id(1, {"action":"ungarrison_soldiers","selected_ids":[bid]})
	else: _call_bm("release_garrisoned", [bid])

func _call_bm(method: String, args: Array):
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if not bm: return
	var e = bm._entity_lookup.get(args[0]) if args.size()>0 else null
	if e: bm.call(method, e)

func _start_build(bid: int):
	var cr = get_tree().get_first_node_in_group("client_renderer")
	if cr and cr.has_method("start_build_placement"): cr.start_build_placement(bid)
	else:
		var bm = get_tree().get_first_node_in_group("battle_manager")
		if bm and bm.has_method("enter_build_mode"): bm.enter_build_mode(bid)

func _d(): pass

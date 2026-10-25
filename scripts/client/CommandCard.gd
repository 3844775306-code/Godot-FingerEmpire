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
		var btn = _buttons[i]; btn.visible = true; btn.modulate = Color.WHITE; btn.tooltip_text = ""
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
		var btn = _buttons[i]; btn.visible = true; btn.tooltip_text = ""
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
		elif i == 8:
			# 修理：主城(20/53)、满血、建造中、升级中、正在修理、附近有敌兵时按钮不出现；
			# 资源不够时保留按钮但置灰，tooltip 里写清费用/耗时/不可用原因
			var rep := _get_repair_state(bid, eid, bm)
			var show_repair := bool(rep["known"]) and eid not in [20, 53] and not bool(rep["busy"])
			show_repair = show_repair and (float(rep["damaged"]) > 0.001 or bool(rep["under_repair"]))
			btn.visible = show_repair
			# 联机快照的 can_repair 只算「建筑状态」，不含资源是否够，这里按最新资源再核一遍
			var can_click := bool(rep["can_repair"])
			if can_click and not (bm is RTSBattleManager):
				var rcost: Dictionary = rep["cost"]
				for k in rcost:
					if int(res.get(k, 0)) < int(rcost[k]):
						can_click = false
						break
			btn.disabled = not can_click
			btn.modulate = Color.WHITE if can_click else Color(0.5, 0.5, 0.5)
			if btn.pressed.is_connected(_d): btn.pressed.disconnect(_d)
			if bool(rep["under_repair"]):
				btn.text = "[G]修理中 %d%%" % int(float(rep["progress"]) * 100.0)
			else:
				btn.text = "[G]修理 %s" % _cost_str(rep["cost"])
			btn.tooltip_text = _repair_tooltip(rep)
			if can_click:
				btn.pressed.connect(func(): _send_repair(bid), CONNECT_ONE_SHOT)
		else:
			btn.visible = false; btn.disabled = true

# ==================== 修理 ====================
# 单机：bm 是 RTSBattleManager，从 _entity_lookup 取真实 Building，读权威 API。
# 联机：bm 是 ClientRenderer，只能读快照 info；ClientRenderer 已补齐
# repair_timer / max_repair_time / can_repair / repair_cost / repair_damage_ratio。
# 老快照缺字段时按「已损比例 × 原价/建造时间」本地兜底，与服务端公式一致。
func _get_repair_state(bid: int, eid: int, bm) -> Dictionary:
	var st := {
		"known": false,          # 是否拿到了建筑数据（拿不到就完全不画按钮）
		"damaged": 0.0,          # 已损比例：0 = 满血，1 = 空血
		"cost": {},              # 修理费 {"wood":12,"stone":6}
		"time": 0.0,             # 预计耗时（秒）
		"under_repair": false,   # 正在修理
		"progress": 0.0,         # 修理进度 0~1
		"busy": false,           # 建造中/升级中（这两种状态不允许开修理工程）
		"can_repair": false,     # 能否修理（含资源是否够）
	}
	if bm == null:
		return st
	# ---------- 单机：直接读真实 Building ----------
	if bm is RTSBattleManager:
		if not bm._entity_lookup.has(bid):
			return st
		var b = bm._entity_lookup[bid]
		if not (b is Building) or not is_instance_valid(b):
			return st
		st["known"] = true
		st["damaged"] = b.repair_damage_ratio()
		st["cost"] = b.repair_cost()
		st["time"] = b.repair_time_total()
		st["under_repair"] = b.is_under_repair()
		st["busy"] = b.build_timer > 0.0 or b.upgrade_timer > 0.0
		st["can_repair"] = bm.can_repair_building(b) if bm.has_method("can_repair_building") else b.can_repair()
		if st["under_repair"] and b.max_repair_time > 0.0:
			st["progress"] = clampf(1.0 - b.repair_timer / b.max_repair_time, 0.0, 1.0)
		return st
	# ---------- 联机：只能读快照 info ----------
	if not bm.has_method("get_entity_info"):
		return st
	var info: Dictionary = bm.get_entity_info(bid)
	if info.is_empty() or int(info.get("type", -1)) != 1:
		return st
	st["known"] = true
	var hp := float(info.get("health", 0))
	var mhp := maxf(float(info.get("max_health", 1)), 1.0)
	st["damaged"] = clampf(float(info.get("repair_damage_ratio", 1.0 - hp / mhp)), 0.0, 1.0)
	st["under_repair"] = float(info.get("repair_timer", 0.0)) > 0.0
	st["busy"] = float(info.get("build_timer", 0.0)) > 0.0 or float(info.get("upgrade_timer", 0.0)) > 0.0
	var mrt := float(info.get("max_repair_time", 0.0))
	var dmg := float(st["damaged"])
	if st["under_repair"] and mrt > 0.0:
		st["progress"] = clampf(1.0 - float(info["repair_timer"]) / mrt, 0.0, 1.0)
	var rcost = info.get("repair_cost", {})
	var cost: Dictionary = rcost.duplicate() if rcost is Dictionary else {}
	if cost.is_empty() and dmg > 0.001:
		# 老快照兜底：已损比例 × 建筑原价，向上取整
		var cfg := EntityDatabase.get_config(eid)
		var base_cost = cfg.get("cost", {})
		for k in base_cost:
			var v := int(ceil(float(base_cost[k]) * dmg))
			if v > 0:
				cost[k] = v
	st["cost"] = cost
	var ctime := float(info.get("repair_time_total", 0.0))
	if ctime <= 0.0:
		# 快照没有耗时字段：已损比例 × 原建造时间（max_health / 75），快进模式减半
		var cfg2 := EntityDatabase.get_config(eid)
		var base_hp := float(cfg2.get("max_health", mhp))
		var spd := 2.0 if GameSettings.fast_mode else 1.0
		ctime = dmg * (base_hp / 75.0) / spd
	st["time"] = maxf(ctime, 0.0)
	if info.has("can_repair"):
		st["can_repair"] = int(info.get("can_repair", 0)) != 0
	else:
		# 老快照没有 can_repair：按客户端可见条件保守估算（敌人靠近/资源不足由服务端拒绝）
		st["can_repair"] = dmg > 0.001 and not st["under_repair"] and not st["busy"]
	return st

func _repair_tooltip(rep: Dictionary) -> String:
	var lines: Array[String] = []
	lines.append("修理残破建筑：修完回复到满血（主城不可修理）")
	var cost: Dictionary = rep["cost"]
	lines.append("费用：%s" % (_cost_str(cost) if not cost.is_empty() else "免费"))
	lines.append("耗时：%.1f 秒" % float(rep["time"]))
	if not bool(rep["known"]):
		lines.append("（尚未收到该建筑的快照数据）")
	elif bool(rep["under_repair"]):
		lines.append("状态：修理中 %d%%" % int(float(rep["progress"]) * 100.0))
	elif not bool(rep["can_repair"]):
		if float(rep["damaged"]) <= 0.001:
			lines.append("状态：建筑完好，无需修理")
		elif bool(rep["busy"]):
			lines.append("状态：建造/升级中，暂不可修理")
		else:
			lines.append("状态：附近有敌军或资源不足，暂不可修理")
	return "\n".join(lines)

# ==================== 选中军队 ====================
func show_army():
	var labels = ["[Q]清除状态","[W]移动攻击","[E]进驻最近","[R]全选同类","[F]巡逻模式"]
	var labels2 = ["[A]攻敌主城","[S]撤回主城","[D]释放进驻"]
	for i in range(_buttons.size()):
		var btn = _buttons[i]; btn.visible = true; btn.disabled = false; btn.modulate = Color.WHITE; btn.tooltip_text = ""
		if i < labels.size(): btn.text = labels[i]
		elif i >= 5 and i-5 < labels2.size(): btn.text = labels2[i-5]
		else: btn.visible = false

func hide_all():
	for btn in _buttons: btn.visible = false

# ---- 发送命令 ----
# 队友单位只可查看：命令卡理论上已隐藏，这里再做一层防御
func _can_command(bid: int) -> bool:
	var cr = get_tree().get_first_node_in_group("client_renderer")
	if not cr: return false
	var info = cr.get_entity_info(bid)
	if info.is_empty(): return true
	return cr.is_local_owned_info(info)

func _send_produce(bid: int, uid: int):
	if not _can_command(bid): return
	var cr = get_tree().get_first_node_in_group("client_renderer")
	if cr: NetworkManager.send_command.rpc_id(1, {"action":"produce","building_id":bid,"unit_id":uid,"ctrl_held":false,"shift_held":false})
	else: _call_bm("produce_unit", [bid, uid])

func _send_upgrade(bid: int):
	if not _can_command(bid): return
	var cr = get_tree().get_first_node_in_group("client_renderer")
	if cr: NetworkManager.send_command.rpc_id(1, {"action":"upgrade","building_id":bid})
	else: _call_bm("upgrade_building", [bid])

# 修理：联机走服务端权威命令（服务端扣费/校验），单机直接调 RTSBattleManager.repair_building
func _send_repair(bid: int):
	var cr = get_tree().get_first_node_in_group("client_renderer")
	if cr:
		if not _can_command(bid): return
		NetworkManager.send_command.rpc_id(1, {"action":"repair","building_id":bid,"shift_held":Input.is_key_pressed(KEY_SHIFT)})
		# 命令卡只在选中变化时重建：先本地置灰，避免连点重复下单（快照回来后会重算权威状态）
		if _buttons.size() > 8:
			var rbtn: Button = _buttons[8]
			if rbtn.visible:
				rbtn.disabled = true
				rbtn.modulate = Color(0.5, 0.5, 0.5)
				rbtn.text = "[G]修理中…"
				rbtn.tooltip_text = "修理已提交，等待服务端快照确认"
	else:
		_call_bm("repair_building", [bid])

func _send_demolish(bid: int):
	if not _can_command(bid): return
	var cr = get_tree().get_first_node_in_group("client_renderer")
	if cr: NetworkManager.send_command.rpc_id(1, {"action":"demolish","building_id":bid})
	else: _call_bm("demolish_building", [bid])

func _send_ungarrison(bid: int):
	if not _can_command(bid): return
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

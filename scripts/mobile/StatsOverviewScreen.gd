class_name StatsOverviewScreen
extends Control

# 全屏统计大屏：一卡一国（玩家 + 全部 AI），右侧挂外交面板。
# 移动端取代战场常驻的 AI 决策面板，因此每张卡片的数据项与它保持一致：
# 阶段/战术、国家特色、人口、主城等级血量、五项资源、经济/军队/建筑明细、历史累计。
# 数据来源：玩家读 battle_manager，AI 读各自的 AIController（同源，保证和桌面决策面板一样多）。

var battle_manager_provider: Callable = Callable()
var hud: Node = null

var _dim: ColorRect = null
var _title: Label = null
var _close_btn: Button = null
var _grid: GridContainer = null
var _diplo_host: Control = null
var _diplo_hint: Label = null
var _diplo_panel: Control = null
var _diplo_original_parent: Node = null

const ECO_UNITS := [[10, "农"], [14, "采船"], [5, "推车"], [6, "贸车"], [9, "运载"],
	[43, "油商"], [44, "木商"], [45, "石商"], [51, "食商"], [46, "县吏"], [47, "上校"],
	[48, "尚书"], [49, "统帅"], [50, "丞相"]]
const MIL_UNITS := [[11, "步"], [12, "弓"], [13, "战船"], [15, "骑"], [16, "炮"], [17, "投石"],
	[18, "攻城"], [19, "侦察"], [30, "狂战"], [31, "长弓"], [32, "法骑"], [33, "木牛"],
	[34, "象骑"], [35, "长枪"], [36, "重步"], [37, "重弓"], [38, "重骑"], [39, "炮艇"],
	[40, "爆破"], [58, "连弩"], [59, "巨投"], [55, "僧侣"], [56, "长老"], [57, "宗师"],
	[65, "武士"], [66, "甲骑"], [67, "蒙弓"], [68, "长生"], [69, "方阵"]]
const BLD_UNITS := [[20, "城"], [21, "营"], [22, "仓"], [23, "坞"], [24, "攻城车"], [25, "箭塔"],
	[26, "炮塔"], [27, "墙"], [28, "民"], [29, "重工"], [41, "瞭望"], [42, "书院"],
	[52, "集市"], [53, "城堡"], [64, "炮台"], [7, "桥"], [8, "梯子"], [54, "修道"]]
const PHASE_NAMES := ["🌱 生产", "🏗️ 发展", "⚔️ 进攻"]

func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()

func _build() -> void:
	_dim = ColorRect.new()
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.color = Color(0.02, 0.03, 0.05, 0.94)
	_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_dim)

	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.offset_left = UILayout.dp(14.0)
	root.offset_right = -UILayout.dp(14.0)
	root.offset_top = UILayout.dp(10.0)
	root.offset_bottom = -UILayout.dp(12.0)
	root.add_theme_constant_override("separation", int(UILayout.dp(6.0)))
	add_child(root)

	var header := HBoxContainer.new()
	root.add_child(header)

	_title = Label.new()
	_title.text = "📊 国家统计"
	_title.add_theme_font_size_override("font_size", UILayout.font_dp(16.0))
	_title.add_theme_color_override("font_color", Color(UITheme.PARCHMENT))
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title.clip_text = true
	header.add_child(_title)

	# 关闭按钮直接锚在屏幕右上角（不进 header 的 HBox）：
	# 竖屏卡片最小宽度会把 header 撑出屏幕，按钮如果跟着 HBox 走就会被挤出右边缘看不见。
	_close_btn = Button.new()
	_close_btn.text = "✕ 关闭"
	_close_btn.custom_minimum_size = Vector2(UILayout.dp(76.0), UILayout.dp(36.0))
	UITheme.apply_button(_close_btn, UILayout.font_dp(13.0))
	_close_btn.pressed.connect(close)
	_close_btn.z_index = 20
	add_child(_close_btn)
	UILayout.place_dp(_close_btn, "tr", 76.0, 36.0, 12.0)

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", int(UILayout.dp(8.0)))
	root.add_child(body)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_stretch_ratio = 1.7
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(scroll)

	_grid = GridContainer.new()
	# 竖屏一行只放一张国家卡：手机逻辑宽度放不下两张卡并排，硬塞会把整体最小宽度撑出屏幕
	_grid.columns = 1 if UILayout.is_portrait() else 2
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.add_theme_constant_override("h_separation", int(UILayout.dp(6.0)))
	_grid.add_theme_constant_override("v_separation", int(UILayout.dp(6.0)))
	scroll.add_child(_grid)

	_diplo_host = Control.new()
	_diplo_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_diplo_host.size_flags_stretch_ratio = 1.0
	body.add_child(_diplo_host)

	_diplo_hint = Label.new()
	_diplo_hint.text = "外交：仅乱斗模式可用"
	_diplo_hint.add_theme_font_size_override("font_size", UILayout.font_dp(10.0))
	_diplo_hint.add_theme_color_override("font_color", Color(UITheme.PARCHMENT, 0.6))
	_diplo_host.add_child(_diplo_hint)

func open() -> void:
	visible = true
	_refresh()
	_attach_diplo(true)
	move_to_front()
	if hud != null and hud.has_method("_on_stats_overlay_toggled"):
		hud.call("_on_stats_overlay_toggled", true)

func close() -> void:
	_attach_diplo(false)
	visible = false
	if hud != null and hud.has_method("_on_stats_overlay_toggled"):
		hud.call("_on_stats_overlay_toggled", false)

# 横竖屏切换会直接重建 MobileHUD；如果统计大屏还开着，先恢复顶部信息，避免一直隐藏
func _exit_tree() -> void:
	if visible and hud != null and is_instance_valid(hud) and hud.is_inside_tree() and hud.has_method("_on_stats_overlay_toggled"):
		hud.call("_on_stats_overlay_toggled", false)

func is_point_inside(pos: Vector2) -> bool:
	return visible and get_global_rect().has_point(pos)

func _get_bm() -> Node:
	if battle_manager_provider.is_valid():
		return battle_manager_provider.call()
	return get_tree().get_first_node_in_group("battle_manager")

# 实体上并非每个属性都存在（资源节点没有 health 等），统一走安全转换
func _i(v) -> int:
	return 0 if v == null else int(v)

func _f(v) -> float:
	return 0.0 if v == null else float(v)

# ==================== 数据收集 ====================

func _refresh() -> void:
	for child in _grid.get_children():
		child.queue_free()

	var bm := _get_bm()
	if bm == null:
		_diplo_host.visible = false
		var empty := Label.new()
		empty.text = "暂无统计数据"
		empty.add_theme_font_size_override("font_size", UILayout.font_dp(13.0))
		_grid.add_child(empty)
		return
	_diplo_host.visible = true

	var reports: Array = []
	reports.append(_player_report(bm))
	for child in bm.get_children():
		if _is_ai_controller(child):
			reports.append(_ai_report(child, bm))
	for r in reports:
		_grid.add_child(_make_card(r))

func _is_ai_controller(node: Node) -> bool:
	return node.has_method("count_unit") and node.has_method("_get_population") and node.get("my_team") != null

func _belongs(entity: Node, owner: int, team: int, peer_id: int) -> bool:
	# 单机 1v1 里实体 owner_peer_id 全是 -1，只能按 team 归属；
	# 多人模式实体带 owner_peer_id，用 owner 严格区分同队玩家。
	var e_owner := _i(entity.get("owner_peer_id"))
	if peer_id != -1 and e_owner != -1:
		return e_owner == peer_id
	return _i(entity.get("team")) == team

# 从实体一次性汇总该归属下的单位与建筑，避免按兵种反复遍历
func _detail_scan(bm: Node, owner: int, team: int, peer_id: int) -> Dictionary:
	var units := {}
	var buildings := {}
	var under_construction := 0
	for e in bm.get_node("Entities").get_children():
		if not is_instance_valid(e) or _i(e.get("health")) <= 0:
			continue
		if not _belongs(e, owner, team, peer_id):
			continue
		if e is Building:
			var bid := _i(e.get("entity_id"))
			var info: Dictionary = buildings.get(bid, {"count": 0, "level": 1})
			info["count"] = int(info["count"]) + 1
			info["level"] = maxi(int(info["level"]), _i(e.get("upgrade_level")))
			buildings[bid] = info
			if _f(e.get("build_timer")) > 0.0:
				under_construction += 1
		elif e is Army:
			var uid := _i(e.get("entity_id"))
			units[uid] = int(units.get(uid, 0)) + 1
	return {"units": units, "buildings": buildings, "under_construction": under_construction}

func _player_report(bm: Node) -> Dictionary:
	var castle = null
	if bm.has_method("get_player_castle"):
		castle = bm.call("get_player_castle")
	var owner := _i(bm.get("player_owner_id"))
	var team := _i(bm.call("get_host_team")) if bm.has_method("get_host_team") else 0
	var detail := _detail_scan(bm, owner, team, -1 if owner == -1 else owner)
	return {
		"kind": "player",
		"owner": owner,
		"team": team,
		"nation": _i(GameSettings.player_nation),
		"phase": -1,
		"tactic": -1,
		"pop": {
			"current": _i(bm.get("player_pop")),
			"max": _i(bm.get("player_max_pop")),
		},
		"res": bm.get("player_resources") if bm.get("player_resources") is Dictionary else {},
		"limits": bm.get("player_resource_limits") if bm.get("player_resource_limits") is Dictionary else {},
		"castle": _castle_info(castle),
		"units": detail["units"],
		"buildings": detail["buildings"],
		"under_construction": detail["under_construction"],
		"stats": _final_stats(bm, owner, team),
	}

func _ai_report(ai: Node, bm: Node) -> Dictionary:
	var peer := _i(ai.get("my_peer_id"))
	var team := _i(ai.get("my_team"))
	var nation := -1
	if ai.has_method("_my_nation_index"):
		nation = _i(ai.call("_my_nation_index"))
	var castle = null
	if peer != -1 and ai.has_method("get_peer_castle"):
		castle = ai.call("get_peer_castle", peer)
	elif ai.has_method("get_team_castle"):
		castle = ai.call("get_team_castle", team)
	var pop := {"current": 0, "max": 0}
	if ai.has_method("_get_population"):
		pop = ai.call("_get_population")
	var res: Dictionary = {}
	if ai.has_method("_get_resources"):
		res = ai.call("_get_resources")
	var detail := _detail_scan(bm, peer, team, peer)
	return {
		"kind": "ai",
		"owner": peer,
		"team": team,
		"nation": nation,
		"phase": _i(ai.get("phase")),
		"tactic": _i(ai.get("current_tactic")),
		"defense": _defense_text(ai),
		"hunt": _f(ai.get("_hunt_timer")),
		"pop": pop,
		"res": res,
		"limits": {},
		"castle": _castle_info(castle),
		"units": detail["units"],
		"buildings": detail["buildings"],
		"under_construction": detail["under_construction"],
		"stats": _final_stats(bm, peer, team),
	}

func _defense_text(ai: Node) -> String:
	var d = ai.get("_defense")
	if d == null or not is_instance_valid(d) or not d.has_method("get_status_text"):
		return ""
	return String(d.call("get_status_text"))

func _castle_info(castle) -> Dictionary:
	if castle == null or not is_instance_valid(castle):
		return {}
	return {
		"level": _i(castle.get("upgrade_level")),
		"health": _i(castle.get("health")),
		"max": _i(castle.get("max_health")),
	}

# 历史累计仍取 BattleStats 采样，保证和结算数据一致
func _final_stats(bm: Node, owner: int, team: int) -> Dictionary:
	var stats = bm.get("battle_stats")
	if stats == null:
		return {}
	if stats.samples.is_empty():
		stats.sample_now()
	if stats.samples.is_empty():
		return {}
	var owners: Dictionary = stats.samples[-1].get("owners", {})
	for key in owners.keys():
		var e: Dictionary = owners[key]
		if _i(e.get("owner", -2)) == owner and _i(e.get("team", -2)) == team:
			return e
	for key in owners.keys():
		var e2: Dictionary = owners[key]
		if _i(e2.get("team", -2)) == team and owner == -1:
			return e2
	return {}

# ==================== 渲染 ====================

func _make_card(r: Dictionary) -> PanelContainer:
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var style := StyleBoxFlat.new()
	style.bg_color = Color(UITheme.INK, 0.92)
	style.border_color = Color(UITheme.GOLD, 0.3)
	style.set_border_width_all(1)
	style.set_corner_radius_all(int(UILayout.dp(8.0)))
	card.add_theme_stylebox_override("panel", style)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", int(UILayout.dp(3.0)))
	card.add_child(vb)

	var nation := int(r.get("nation", -1))
	var team := int(r.get("team", -1))
	var nation_name := "中立"
	if nation >= 0 and nation < BattleStats.NATION_NAMES.size():
		nation_name = BattleStats.NATION_NAMES[nation]
	var team_name := "蓝方" if team == RTSConfig.Team.BLUE else ("红方" if team == RTSConfig.Team.RED else "中立")
	var team_color := Color(0.35, 0.62, 1.0) if team == RTSConfig.Team.BLUE else Color(0.92, 0.35, 0.32)

	var is_player := String(r.get("kind", "")) == "player"

	var header := HBoxContainer.new()
	vb.add_child(header)

	var dot := ColorRect.new()
	dot.custom_minimum_size = Vector2(UILayout.dp(10.0), UILayout.dp(10.0))
	dot.color = team_color
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header.add_child(dot)

	var title := Label.new()
	var owner := int(r.get("owner", -1))
	var owner_tag := "玩家" if is_player else ("AI-%d" % owner if owner != -1 else "AI")
	title.text = "  %s · %s  %s" % [nation_name, team_name, owner_tag]
	title.add_theme_font_size_override("font_size", UILayout.font_dp(13.0))
	title.add_theme_color_override("font_color", team_color)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)

	# 阶段 / 战术（AI 才有，和决策面板一致）
	if String(r.get("kind", "")) == "ai":
		var phase := int(r.get("phase", -1))
		var tactic := int(r.get("tactic", -1))
		var phase_txt: String = PHASE_NAMES[phase] if phase >= 0 and phase < PHASE_NAMES.size() else "—"
		var tactic_txt := _tactic_name(tactic)
		var line := Label.new()
		line.text = "▸ %s ｜ %s" % [phase_txt, tactic_txt]
		var dtxt := String(r.get("defense", ""))
		if dtxt != "":
			line.text += " ｜ 🛡 %s" % dtxt
		line.add_theme_font_size_override("font_size", UILayout.font_dp(10.0))
		line.add_theme_color_override("font_color", Color(0.6, 0.85, 1.0))
		vb.add_child(line)

	# 国家特色
	if nation >= 0:
		var trait_rtl := RichTextLabel.new()
		trait_rtl.bbcode_enabled = true
		trait_rtl.fit_content = true
		trait_rtl.add_theme_font_size_override("normal_font_size", UILayout.font_dp(9.0))
		trait_rtl.text = "[color=#cba]%s[/color]" % NationBonuses.get_trait_full(nation)
		vb.add_child(trait_rtl)

	# 人口 / 主城
	var pop: Dictionary = r.get("pop", {})
	var castle: Dictionary = r.get("castle", {})
	var pop_txt := "👥 %d/%d" % [int(pop.get("current", 0)), int(pop.get("max", 0))]
	var castle_txt := "🏰 已失守"
	if not castle.is_empty():
		castle_txt = "🏰 Lv.%d %d/%d" % [int(castle.get("level", 1)),
			int(castle.get("health", 0)), int(castle.get("max", 1))]
	var vital := Label.new()
	vital.text = "%s   %s" % [pop_txt, castle_txt]
	vital.add_theme_font_size_override("font_size", UILayout.font_dp(10.0))
	vital.add_theme_color_override("font_color", Color(UITheme.PARCHMENT))
	vb.add_child(vital)

	# 资源
	var res: Dictionary = r.get("res", {})
	var res_line := HBoxContainer.new()
	res_line.add_theme_constant_override("separation", int(UILayout.dp(5.0)))
	for key in ["gold", "wood", "stone", "food", "oil"]:
		var lbl := Label.new()
		lbl.text = "%s%d" % [String(UITheme.RESOURCE_ICONS.get(key, "◆")), int(res.get(key, 0))]
		lbl.add_theme_font_size_override("font_size", UILayout.font_dp(9.0))
		lbl.add_theme_color_override("font_color", UITheme.RESOURCE_COLORS.get(key, Color.WHITE))
		res_line.add_child(lbl)
	vb.add_child(res_line)

	# 明细：经济 / 军队 / 建筑
	var units: Dictionary = r.get("units", {})
	var buildings: Dictionary = r.get("buildings", {})
	vb.add_child(_detail_line("💰 经济", ECO_UNITS, units, Color(0.6, 0.9, 0.6)))
	vb.add_child(_detail_line("⚔️ 军队", MIL_UNITS, units, Color(0.85, 0.85, 0.85)))
	vb.add_child(_building_line(buildings, int(r.get("under_construction", 0))))

	# 历史累计
	var st: Dictionary = r.get("stats", {})
	if not st.is_empty():
		var accum := Label.new()
		accum.text = "采集 %d · 生产 %d · 歼敌 %d · 伤害 %d" % [
			int(st.get("gathered", 0)), int(st.get("produced", 0)),
			int(st.get("kills", 0)), int(st.get("damage", 0))]
		accum.add_theme_font_size_override("font_size", UILayout.font_dp(9.0))
		accum.add_theme_color_override("font_color", Color(UITheme.PARCHMENT, 0.75))
		vb.add_child(accum)
	# 狩猎计时（AI 决策面板里也有这一项）
	if String(r.get("kind", "")) == "ai" and _f(r.get("hunt")) > 0.0:
		var hunt := Label.new()
		hunt.text = "🏹 狩猎 %.0fs" % _f(r.get("hunt"))
		hunt.add_theme_font_size_override("font_size", UILayout.font_dp(9.0))
		hunt.add_theme_color_override("font_color", Color(1.0, 0.85, 0.5))
		vb.add_child(hunt)
	return card

func _detail_line(title: String, table: Array, counts: Dictionary, color: Color) -> RichTextLabel:
	var rtl := RichTextLabel.new()
	rtl.bbcode_enabled = true
	rtl.fit_content = true
	rtl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rtl.add_theme_font_size_override("normal_font_size", UILayout.font_dp(9.0))
	var total := 0
	var parts: Array = []
	for entry in table:
		var cnt := int(counts.get(int(entry[0]), 0))
		total += cnt
		if cnt > 0:
			parts.append("%s%s:%d" % [UITheme.entity_emoji(int(entry[0]), 2), String(entry[1]), cnt])
	var head := "[color=#5af]%s %d[/color]  " % [title, total]
	if parts.is_empty():
		rtl.text = head + "[color=gray](无)[/color]"
	else:
		rtl.text = head + "[color=#%s]%s[/color]" % [color.to_html(), "  ".join(parts)]
	return rtl

func _building_line(buildings: Dictionary, under: int) -> RichTextLabel:
	var rtl := RichTextLabel.new()
	rtl.bbcode_enabled = true
	rtl.fit_content = true
	rtl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rtl.add_theme_font_size_override("normal_font_size", UILayout.font_dp(9.0))
	var total := 0
	var parts: Array = []
	for entry in BLD_UNITS:
		var bid := int(entry[0])
		if not buildings.has(bid):
			continue
		var info: Dictionary = buildings[bid]
		var cnt := int(info.get("count", 0))
		total += cnt
		parts.append("%s【%d】%s:%d" % [UITheme.entity_emoji(bid, 1), int(info.get("level", 1)),
			String(entry[1]), cnt])
	var head := "[color=#5af]▸ 🏰 建筑 %d[/color]" % total
	if under > 0:
		head += "  [color=#caa]🏗️ 在建 %d[/color]" % under
	if parts.is_empty():
		rtl.text = head + "  [color=gray](无)[/color]"
	else:
		rtl.text = head + "  [color=#888]%s[/color]" % "  ".join(parts)
	return rtl

func _tactic_name(tactic: int) -> String:
	match tactic:
		1: return "🔥 骚扰"
		2: return "⚔️ 压制"
		3: return "⚡ 突袭"
		4: return "🛡️ 防守"
		_: return "—"

# 外交面板复用桌面 HUD 的现成节点：打开时临时挂到右栏，关闭时归还原位
func _attach_diplo(on: bool) -> void:
	if hud == null:
		return
	if on:
		var panel = hud.get("_diplo_panel")
		if is_instance_valid(panel) and panel is Control:
			_diplo_panel = panel
			_diplo_original_parent = panel.get_parent()
			panel.reparent(_diplo_host)
			panel.visible = true
			panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			_diplo_hint.visible = false
		else:
			_diplo_hint.visible = true
	else:
		if _diplo_panel and is_instance_valid(_diplo_panel) and _diplo_original_parent:
			_diplo_panel.reparent(_diplo_original_parent)
			_diplo_panel.visible = false
		_diplo_panel = null
		_diplo_original_parent = null
		_diplo_hint.visible = true

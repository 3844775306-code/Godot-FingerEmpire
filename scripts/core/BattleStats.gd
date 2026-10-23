class_name BattleStats
extends RefCounted

# 战斗统计：累计指标在事件发生时累加，实时指标每 5 秒采样一次。
# 结算面板按“国家”或“阵营”聚合，并提供全部 8 条曲线。

const SAMPLE_INTERVAL: float = 5.0

const METRICS: Array = [
	{ "id": "gathered", "label": "资源累计获取", "short": "资源累计", "unit": "资源", "cumulative": true },
	{ "id": "produced", "label": "军队生产累计", "short": "生产累计", "unit": "单位", "cumulative": true },
	{ "id": "kills", "label": "歼敌累计", "short": "歼敌累计", "unit": "个", "cumulative": true },
	{ "id": "damage", "label": "造成伤害累计", "short": "伤害累计", "unit": "伤害", "cumulative": true },
	{ "id": "buildings", "label": "建筑实时总量", "short": "建筑实时", "unit": "座", "cumulative": false },
	{ "id": "resources", "label": "资源实时总量", "short": "资源实时", "unit": "资源", "cumulative": false },
	{ "id": "army", "label": "军队实时总量", "short": "军队实时", "unit": "人", "cumulative": false },
	{ "id": "vision", "label": "视野面积实时总量", "short": "视野实时", "unit": "格", "cumulative": false },
]

const NATION_COLORS: Array = [
	Color(0.95, 0.32, 0.24),   # 维京
	Color(0.30, 0.62, 1.00),   # 英格兰
	Color(0.96, 0.70, 0.20),   # 法兰西
	Color(0.95, 0.32, 0.52),   # 中国
	Color(0.40, 0.84, 0.36),   # 匈牙利
	Color(0.78, 0.48, 0.95),   # 日本
	Color(0.28, 0.84, 0.84),   # 拜占庭
]
const NATION_NAMES: Array = ["维京", "英格兰", "法兰西", "中国", "匈牙利", "日本", "拜占庭"]

var battle = null
var samples: Array = []
var duration: float = 0.0

var _totals: Dictionary = {}      # key -> { gathered, produced, kills, damage }
var _metas: Dictionary = {}       # key -> { owner, team, nation }
var _timer: float = 0.0
var _finalized: bool = false

func _init(p_battle = null) -> void:
	battle = p_battle

func tick(delta: float) -> void:
	if _finalized or battle == null:
		return
	if samples.is_empty():
		sample_now()
		_timer = 0.0
		return
	_timer += delta
	if _timer >= SAMPLE_INTERVAL:
		_timer = 0.0
		sample_now()

func finalize() -> void:
	_finalized = true
	if battle:
		duration = float(battle.game_time)

func _owner_key(owner: int, team: int) -> String:
	if owner != -1:
		return "o:%d" % owner
	return "t:%d" % team

func _ensure_meta(owner: int, team: int) -> String:
	var key := _owner_key(owner, team)
	if not _metas.has(key):
		_metas[key] = { "owner": owner, "team": team, "nation": -1 }
	else:
		var meta: Dictionary = _metas[key]
		if team >= 0:
			meta["team"] = team
	return key

func _team_for_owner(owner: int) -> int:
	if owner == -1 or battle == null:
		return -1
	if battle.ai_players.has(owner):
		return int(battle.ai_players[owner].get("team", -1))
	var pinfo = battle.get("player_info")
	if pinfo is Dictionary and pinfo.has(owner):
		return int(pinfo[owner].get("team", -1))
	var pteams = battle.get("player_teams")
	if pteams is Dictionary and pteams.has(owner):
		return int(pteams[owner])
	return -1

func _nation_for_owner(owner: int, team: int) -> int:
	if battle == null:
		return -1
	if owner != -1:
		var info: Dictionary = battle.ai_players.get(owner, {})
		if info.has("nation"):
			return int(info.get("nation", -1))
		var pinfo = battle.get("player_info")
		if pinfo is Dictionary and pinfo.has(owner):
			return int(pinfo[owner].get("nation", -1))
		if owner == int(battle.player_owner_id):
			return int(GameSettings.player_nation)
	if team >= 0:
		return int(battle.get_team_nation(team))
	return -1

func _refresh_meta(key: String) -> Dictionary:
	var meta: Dictionary = _metas.get(key, {})
	if meta.is_empty():
		return meta
	var owner := int(meta.get("owner", -1))
	var team := int(meta.get("team", -1))
	if owner != -1 and team < 0:
		team = _team_for_owner(owner)
		meta["team"] = team
	meta["nation"] = _nation_for_owner(owner, team)
	return meta

func _record(owner: int, team: int, field: String, amount: float) -> void:
	if amount <= 0.0:
		return
	var key := _ensure_meta(owner, team)
	if not _totals.has(key):
		_totals[key] = { "gathered": 0.0, "produced": 0.0, "kills": 0.0, "damage": 0.0 }
	_totals[key][field] = float(_totals[key].get(field, 0.0)) + amount

func record_gathered(owner: int, team: int, amount: float) -> void:
	_record(owner, team, "gathered", amount)

func record_produced(owner: int, team: int, amount: int = 1) -> void:
	_record(owner, team, "produced", float(amount))

func record_kill(owner: int, team: int, amount: int = 1) -> void:
	_record(owner, team, "kills", float(amount))

func record_damage(owner: int, team: int, amount: float) -> void:
	_record(owner, team, "damage", amount)

func _resources_for(owner: int, team: int) -> Dictionary:
	if battle == null:
		return {}
	if owner != -1 and battle.has_method("get_resources_for"):
		return battle.get_resources_for(owner)
	if team == RTSConfig.Team.BLUE:
		return battle.player_resources
	if team == RTSConfig.Team.RED:
		return battle.enemy_resources
	return {}

func _resource_sum(owner: int, team: int) -> int:
	var total := 0
	for v in _resources_for(owner, team).values():
		total += int(v)
	return total

func _team_label(team: int) -> String:
	match team:
		RTSConfig.Team.BLUE: return "蓝方"
		RTSConfig.Team.RED: return "红方"
		RTSConfig.Team.NEUTRAL: return "中立"
	return "阵营 %d" % team

func _team_color(team: int) -> Color:
	if team == RTSConfig.Team.BLUE:
		return Color(0.24, 0.64, 1.0)
	if team == RTSConfig.Team.RED:
		return Color(1.0, 0.33, 0.26)
	var pool: Array = RTSConfig.COLOR_POOL
	return pool[posmod(team, pool.size())]

func _nation_color(nation: int) -> Color:
	if nation >= 0 and nation < NATION_COLORS.size():
		return NATION_COLORS[nation]
	return Color(0.7, 0.7, 0.7)

func _nation_label(nation: int) -> String:
	if battle and battle.has_method("get_nation_name"):
		return battle.get_nation_name(nation)
	if nation >= 0 and nation < NATION_NAMES.size():
		return String(NATION_NAMES[nation])
	return "未知"

func _collect_participants(metas: Dictionary) -> void:
	if battle == null:
		return
	for pid in battle.ai_players.keys():
		var team := int(battle.ai_players[pid].get("team", -1))
		metas[_owner_key(int(pid), team)] = { "owner": int(pid), "team": team }
	var pinfo = battle.get("player_info")
	if pinfo is Dictionary:
		for pid in pinfo.keys():
			var team := int(pinfo[pid].get("team", -1))
			metas[_owner_key(int(pid), team)] = { "owner": int(pid), "team": team }
	var pteams = battle.get("player_teams")
	if pteams is Dictionary:
		for pid in pteams.keys():
			var team := int(pteams[pid])
			metas[_owner_key(int(pid), team)] = { "owner": int(pid), "team": team }

	var entities = battle.get_tree().get_nodes_in_group("entities")
	for e in entities:
		if not (e is GameEntity) or e.health <= 0 or e.team == RTSConfig.Team.NEUTRAL:
			continue
		var owner := int(e.owner_peer_id)
		var team := int(e.team)
		metas[_owner_key(owner, team)] = { "owner": owner, "team": team }

	if metas.is_empty():
		for team in [RTSConfig.Team.BLUE, RTSConfig.Team.RED]:
			metas[_owner_key(-1, team)] = { "owner": -1, "team": team }

func _ensure_vision(sets: Dictionary, key: String) -> Dictionary:
	if not sets.has(key):
		sets[key] = {}
	return sets[key]

func sample_now() -> void:
	if battle == null:
		return
	var duration_now := float(battle.game_time)
	var metas: Dictionary = {}
	_collect_participants(metas)
	for key in _totals.keys():
		if not metas.has(key):
			var m: Dictionary = _metas.get(key, {})
			metas[key] = { "owner": int(m.get("owner", -1)), "team": int(m.get("team", -1)) }

	var owner_data: Dictionary = {}
	for key in metas.keys():
		owner_data[key] = { "buildings": 0, "army": 0, "resources": 0, "vision": 0 }

	# 实时数量：建筑、非动物军队、资源库存
	for e in battle.get_tree().get_nodes_in_group("entities"):
		if not (e is GameEntity) or e.health <= 0 or e.team == RTSConfig.Team.NEUTRAL:
			continue
		var owner := int(e.owner_peer_id)
		var team := int(e.team)
		var key := _owner_key(owner, team)
		if not owner_data.has(key):
			owner_data[key] = { "buildings": 0, "army": 0, "resources": 0, "vision": 0 }
			metas[key] = { "owner": owner, "team": team }
		if e is Building:
			owner_data[key]["buildings"] += 1
		elif e is Army and int(e.entity_id) < 60:
			owner_data[key]["army"] += 1

	# 视野：每个 owner / 阵营 / 国家各维护一份格子集合，阵营与国家取并集
	var owner_vision: Dictionary = {}
	var team_vision: Dictionary = {}
	var nation_vision: Dictionary = {}
	var map_size: int = int(RTSConfig.MAP_SIZE)
	for e in battle.get_tree().get_nodes_in_group("vision_providers"):
		if not (e is GameEntity) or e.health <= 0 or e.team == RTSConfig.Team.NEUTRAL:
			continue
		if not (e is Army or e is Building):
			continue
		var vr := float(e.vision_range)
		if vr <= 0.0:
			continue
		var owner := int(e.owner_peer_id)
		var team := int(e.team)
		var key := _owner_key(owner, team)
		var nation := _nation_for_owner(owner, team)
		var oset := _ensure_vision(owner_vision, key)
		var tset := _ensure_vision(team_vision, "t:%d" % team)
		var nset := _ensure_vision(nation_vision, "n:%d" % nation)
		var g: Vector2i = battle.world_to_grid(e.global_position)
		var radius := int(ceil(vr))
		for dx in range(-radius, radius + 1):
			for dz in range(-radius, radius + 1):
				if dx * dx + dz * dz > vr * vr:
					continue
				var gx := g.x + dx
				var gz := g.y + dz
				if gx < 0 or gx >= map_size or gz < 0 or gz >= map_size:
					continue
				var idx := gx * map_size + gz
				oset[idx] = true
				tset[idx] = true
				nset[idx] = true

	for key in owner_data.keys():
		var meta: Dictionary = metas.get(key, {})
		var owner := int(meta.get("owner", -1))
		var team := int(meta.get("team", -1))
		owner_data[key]["resources"] = _resource_sum(owner, team)
		owner_data[key]["vision"] = owner_vision.get(key, {}).size()

	var sample := {
		"time": duration_now,
		"owners": {},
		"team_vision": {},
		"nation_vision": {},
	}
	for key in owner_data.keys():
		var meta: Dictionary = metas.get(key, {})
		var owner := int(meta.get("owner", -1))
		var team := int(meta.get("team", -1))
		if owner != -1 and team < 0:
			team = _team_for_owner(owner)
		var nation := _nation_for_owner(owner, team)
		meta["team"] = team
		meta["nation"] = nation
		_metas[key] = meta
		var totals: Dictionary = _totals.get(key, {})
		sample["owners"][key] = {
			"owner": owner,
			"team": team,
			"nation": nation,
			"gathered": float(totals.get("gathered", 0.0)),
			"produced": float(totals.get("produced", 0.0)),
			"kills": float(totals.get("kills", 0.0)),
			"damage": float(totals.get("damage", 0.0)),
			"buildings": int(owner_data[key].get("buildings", 0)),
			"resources": int(owner_data[key].get("resources", 0)),
			"army": int(owner_data[key].get("army", 0)),
			"vision": int(owner_data[key].get("vision", 0)),
		}
	for team_key in team_vision.keys():
		sample["team_vision"][String(team_key).trim_prefix("t:")] = team_vision[team_key].size()
	for nation_key in nation_vision.keys():
		sample["nation_vision"][String(nation_key).trim_prefix("n:")] = nation_vision[nation_key].size()

	if not samples.is_empty() and absf(float(samples[-1].get("time", -999.0)) - duration_now) < 0.01:
		samples[-1] = sample
	else:
		samples.append(sample)
	duration = duration_now

func get_metric(metric_id: String) -> Dictionary:
	for m in METRICS:
		if m["id"] == metric_id:
			return m
	return METRICS[0]

func get_series(metric_id: String, mode: String) -> Array:
	var groups: Dictionary = {}
	var group_order: Array = []
	for s in samples:
		for key in s["owners"].keys():
			var o: Dictionary = s["owners"][key]
			var gkey: String
			var name: String
			var color: Color
			if mode == "nation":
				var nation := int(o.get("nation", -1))
				gkey = "n:%d" % nation
				name = _nation_label(nation)
				color = _nation_color(nation)
			else:
				var team := int(o.get("team", -1))
				gkey = "t:%d" % team
				name = _team_label(team)
				color = _team_color(team)
			if not groups.has(gkey):
				groups[gkey] = {
					"key": gkey, "name": name, "color": color,
					"points": [], "final": 0.0, "nation": o.get("nation", -1), "team": o.get("team", -1),
				}
				group_order.append(gkey)

	for gkey in group_order:
		var group: Dictionary = groups[gkey]
		for s in samples:
			var value := 0.0
			var vision_key := ""
			if mode == "nation":
				vision_key = str(int(group["nation"]))
				for key in s["owners"].keys():
					var o: Dictionary = s["owners"][key]
					if int(o.get("nation", -1)) == int(group["nation"]):
						value += float(o.get(metric_id, 0))
				if metric_id == "vision":
					value = float(s["nation_vision"].get(vision_key, 0))
			else:
				vision_key = str(int(group["team"]))
				for key in s["owners"].keys():
					var o: Dictionary = s["owners"][key]
					if int(o.get("team", -1)) == int(group["team"]):
						value += float(o.get(metric_id, 0))
				if metric_id == "vision":
					value = float(s["team_vision"].get(vision_key, 0))
			group["points"].append({ "x": float(s["time"]), "y": value })
			group["final"] = value
	# 最终值高的排前面，图例更好读
	group_order.sort_custom(func(a, b): return float(groups[a]["final"]) > float(groups[b]["final"]))
	var result: Array = []
	for gkey in group_order:
		result.append(groups[gkey])
	return result

func format_value(metric_id: String, value: float) -> String:
	if metric_id in ["gathered", "produced", "kills", "damage", "resources", "buildings", "army", "vision"]:
		return "%d" % int(round(value))
	return "%.1f" % value

# 联机结算：只传采样结果，客户端不需要拥有战斗实体也能绘制曲线
func export_payload() -> Dictionary:
	return { "duration": duration, "samples": samples }

func load_payload(payload: Dictionary) -> void:
	duration = float(payload.get("duration", 0.0))
	samples = payload.get("samples", [])
	_finalized = true


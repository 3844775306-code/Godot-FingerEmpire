# scripts/ui/EntityBonusText.gd
# 单位信息面板的“加成来源”文本：国家特色 + 已生效科研 + 官员效果。
# 属性数值按“基础（白）+ 国家（橙）+ 科研（绿）+ 官员（黄）”分项显示；
# 单机版直接对比实体快照，准确反映实际套用的加成。
class_name EntityBonusText
extends RefCounted

const C_NATION_TITLE := Color(1.0, 0.62, 0.26)
const C_RESEARCH_TITLE := Color(0.49, 0.86, 0.53)
const C_BODY := Color(0.84, 0.79, 0.70)
# 属性分项：基础白、国家橙、科研绿、官员黄
const C_BASE := Color(1.0, 1.0, 1.0)
const C_NATION := Color(1.0, 0.62, 0.26)
const C_RESEARCH := Color(0.49, 0.86, 0.53)
const C_OFFICIAL := Color(1.0, 0.84, 0.30)

# 把当前属性拆成“基础 + 国家 + 科研 + 官员”四段带色数值。
# 快照缺失时退回单段当前值，保证旧实体/联机快照也能正常显示。
static func stat_breakdown_text(e, key: String, decimals: int = 0) -> String:
	var br := _stat_breakdown(e, key)
	if not bool(br.get("ok", false)):
		return _colored_number(float(br.get("current", 0.0)), decimals, C_BASE, false)
	var out := _colored_number(float(br["base"]), decimals, C_BASE, false)
	out = _append_component(out, float(br["nation"]), decimals, C_NATION)
	out = _append_component(out, float(br["research"]), decimals, C_RESEARCH)
	out = _append_component(out, float(br["official"]), decimals, C_OFFICIAL)
	return out

# 攻速按“次/秒”显示，避免攻击间隔越小越快造成误读。
static func attack_speed_breakdown_text(e) -> String:
	var br := _stat_breakdown(e, "attack_speed")
	if not bool(br.get("ok", false)):
		var cur := float(br.get("current", 0.0))
		if cur <= 0.001:
			return _colored_number(0.0, 2, C_BASE, false)
		return _colored_number(1.0 / cur, 2, C_BASE, false)
	var base_i := float(br["base"])
	var nation_i := base_i + float(br["nation"])
	var research_i := nation_i + float(br["research"])
	var current_i := research_i + float(br["official"])
	if base_i <= 0.001 or nation_i <= 0.001 or research_i <= 0.001 or current_i <= 0.001:
		return _colored_number(0.0, 2, C_BASE, false)
	var base_aps := 1.0 / base_i
	var nation_aps := 1.0 / nation_i
	var research_aps := 1.0 / research_i
	var current_aps := 1.0 / current_i
	var out := _colored_number(base_aps, 2, C_BASE, false)
	out = _append_component(out, nation_aps - base_aps, 2, C_NATION)
	out = _append_component(out, research_aps - nation_aps, 2, C_RESEARCH)
	out = _append_component(out, current_aps - research_aps, 2, C_OFFICIAL)
	return out

# 值得优先展示的官员效果（不含已经进入属性分项的光环）。
static func official_block(e) -> String:
	if e == null or not is_instance_valid(e):
		return ""
	var parts: Array = []
	var meta_list: Array = e.get_meta_list()
	for m in meta_list:
		var key := String(m)
		if key.begins_with("_cmd_aura_"):
			parts.append("指挥官光环：攻速提升")
		elif key.begins_with("_clerk_bonus_"):
			parts.append("书记官光环：采集速度提升")
	# 官员自身：说明他能提供什么效果
	var eid := int(_num(e, "entity_id", 0))
	if eid >= 46 and eid <= 50:
		var own := _official_effect_text(eid)
		if own != "":
			parts.append(own)
	# 建筑：列出正在驻扎的官员，覆盖护甲之外的仓储/生产/宰相倍率
	if int(_num(e, "entity_type", 0)) == 1:
		var tree: SceneTree = e.get_tree()
		if tree != null:
			for n in tree.get_nodes_in_group("entities"):
				if n is Army and int(n.entity_id) >= 46 and int(n.entity_id) <= 50 and bool(n.get("_official_active")):
					var gb = n.get("_garrison_building")
					if gb != null and gb.get_ref() == e:
						var txt := _official_effect_text(int(n.entity_id), int(_num(e, "entity_id", 0)))
						if txt != "" and not parts.has(txt):
							parts.append(txt)
	if parts.is_empty():
		return ""
	return "\n\n[color=#%s]👑 官员效果[/color]  [color=#%s]%s[/color]" % [
		C_OFFICIAL.to_html(false), C_BODY.to_html(false), " · ".join(parts)]

static func _official_effect_text(eid: int, building_id: int = -1) -> String:
	match eid:
		46:
			if building_id >= 0:
				return "书记官：仓储 +50%" if building_id == 22 else ""
			return "书记官：农民采集 +25%，仓库仓储 +50%"
		47:
			return "校尉：驻守建筑双护甲 +5"
		48:
			return "大臣：驻守建筑生产速度 +50%"
		49:
			return "指挥官：周围友军攻速 +25%"
		50:
			return "宰相：同建筑其他官员效果 ×2"
	return ""

static func _stat_breakdown(e, key: String) -> Dictionary:
	var current := _num(e, key, 0.0)
	var base_snap = e.get("_base_stats_raw")
	var pre_snap = e.get("_stats_before_official")
	var nation_snap = e.get("_research_base_stats")
	if not (base_snap is Dictionary) or not (pre_snap is Dictionary):
		return {"ok": false, "current": current}
	var base_d: Dictionary = base_snap
	var pre_d: Dictionary = pre_snap
	var nation_d: Dictionary = nation_snap if nation_snap is Dictionary else {}
	if base_d.is_empty() or pre_d.is_empty() or not base_d.has(key):
		return {"ok": false, "current": current}
	var base := float(base_d.get(key, current))
	var nation_base := base
	if nation_d.has(key):
		nation_base = float(nation_d.get(key, base))
	var before_official := float(pre_d.get(key, current))
	return {
		"ok": true,
		"base": base,
		"nation": nation_base - base,
		"research": before_official - nation_base,
		"official": current - before_official,
		"current": current,
	}

static func _append_component(out: String, value: float, decimals: int, color: Color) -> String:
	var epsilon := 0.005 if decimals > 0 else 0.5
	if absf(value) < epsilon:
		return out
	return out + _colored_number(value, decimals, color, true)

static func _colored_number(value: float, decimals: int, color: Color, signed: bool) -> String:
	var txt := ""
	if decimals <= 0:
		txt = ("%+d" % int(round(value))) if signed else ("%d" % int(round(value)))
	elif decimals == 1:
		txt = ("%+.1f" % value) if signed else ("%.1f" % value)
	else:
		txt = ("%+.2f" % value) if signed else ("%.2f" % value)
	return "[color=#%s]%s[/color]" % [color.to_html(false), txt]


# 国家特色：直接从 NationBonuses 的实际数值生成，避免描述文案和结算数值不一致。
static func nation_block(nation: int) -> String:
	if nation < 0:
		return ""
	var body := _nation_body(nation)
	if body.is_empty():
		return ""
	var nation_name := ""
	if nation < TechTreeData.NATION_NAMES.size():
		nation_name = String(TechTreeData.NATION_NAMES[nation])
	if nation_name.is_empty():
		nation_name = "未知"
	return _section("🏳️ 国家特色 · %s" % nation_name, body)

static func _nation_body(nation: int) -> String:
	var parts: Array = []
	var names := {
		"health": "生命", "attack": "攻击", "melee_armor": "近战护甲",
		"shield_armor": "盾甲", "speed": "移速", "attack_speed": "攻速",
		"attack_range": "射程", "vision_range": "视野",
	}
	var mults: Dictionary = NationBonuses.get_all_unit_multipliers(nation)
	for key in mults:
		var value := float(mults[key])
		var label := String(names.get(key, key))
		if key in ["melee_armor", "shield_armor"]:
			parts.append("%s %+.0f" % [label, value])
		else:
			parts.append("%s %+.0f%%" % [label, (value - 1.0) * 100.0])
	var pop_bonus := NationBonuses.get_population_bonus(nation)
	if pop_bonus > 0:
		parts.append("人口上限 +%d" % pop_bonus)
	var castle_lv := NationBonuses.get_castle_start_level(nation)
	if castle_lv > 1:
		parts.append("开局城堡 Lv.%d" % castle_lv)
	var res_names := {"wood": "木材", "stone": "石材", "gold": "黄金", "food": "食物", "oil": "石油"}
	for res in ["wood", "stone", "gold", "food", "oil"]:
		var mult := NationBonuses.get_gather_mult(nation, res)
		if mult > 1.0001:
			parts.append("%s采集 %+.0f%%" % [res_names.get(res, res), (mult - 1.0) * 100.0])
	return " · ".join(parts)

# 单机实体：科研基础快照是套用国家加成之后、科研之前的值。
static func research_block_from_entity(e) -> String:
	if e == null or not is_instance_valid(e):
		return ""
	var base: Dictionary = {}
	var raw = e.get("_research_base_stats")
	if raw is Dictionary:
		base = raw
	if base.is_empty():
		return _research_section("暂无科研基础数据")
	var parts := _entity_research_parts(e, base)
	if parts.is_empty():
		return _research_section("暂无已生效科技")
	return _research_section(" · ".join(parts))

# 联机本地玩家：服务端快照只下发本地科研，按服务端同一套公式概括。
static func research_block_from_mods(uid: int, mods: Dictionary, entity_type: int = 2) -> String:
	if mods.is_empty():
		return _research_section("暂无已生效科技")
	var parts: Array = []
	if entity_type == 1:
		_building_mods_parts(parts, uid, mods)
	else:
		_unit_mods_parts(parts, uid, mods)
	if parts.is_empty():
		return _research_section("暂无已生效科技")
	return _research_section(" · ".join(parts))

# 敌方 / 队友的科研由各自玩家维护，客户端没有完整快照，不冒充显示。
static func research_unavailable_block(reason: String) -> String:
	return _research_section(reason)

static func _section(title: String, body: String) -> String:
	return "\n\n[color=#%s]%s[/color]  [color=#%s]%s[/color]" % [
		C_NATION_TITLE.to_html(false), title,
		C_BODY.to_html(false), body]

static func _research_section(body: String) -> String:
	return "\n\n[color=#%s]🔬 科研加成[/color]  [color=#%s]%s[/color]" % [
		C_RESEARCH_TITLE.to_html(false), C_BODY.to_html(false), body]

# ==================== 单机：按实际属性差计算 ====================

static func _entity_research_parts(e, base: Dictionary) -> Array:
	var parts: Array = []
	# 科研结果按“官员生效前”的快照对比，避免把指挥官光环等官员效果算进科研。
	var pre = e.get("_stats_before_official")
	var observed: Dictionary = pre if pre is Dictionary and not pre.is_empty() else {}
	var max_hp_now := float(observed.get("max_health", _num(e, "max_health", 0.0)))
	var attack_now := float(observed.get("attack", _num(e, "attack", 0.0)))
	var attack_speed_now := float(observed.get("attack_speed", _num(e, "attack_speed", 0.0)))
	var attack_range_now := float(observed.get("attack_range", _num(e, "attack_range", 0.0)))
	var speed_now := float(observed.get("speed", _num(e, "speed", 0.0)))
	var vision_now := float(observed.get("vision_range", _num(e, "vision_range", 0.0)))
	var melee_armor_now := float(observed.get("melee_armor", _num(e, "melee_armor", 0.0)))
	var shield_armor_now := float(observed.get("shield_armor", _num(e, "shield_armor", 0.0)))
	_add_pct(parts, "生命", float(base.get("max_health", 0.0)), max_hp_now)
	_add_pct(parts, "攻击", float(base.get("attack", 0.0)), attack_now)
	_add_attack_speed(parts, float(base.get("attack_speed", 0.0)), attack_speed_now)
	_add_flat(parts, "射程", float(base.get("attack_range", 0.0)), attack_range_now, 1)
	_add_pct(parts, "移速", float(base.get("speed", 0.0)), speed_now)
	_add_pct(parts, "视野", float(base.get("vision_range", 0.0)), vision_now)
	_add_flat(parts, "近战护甲", float(base.get("melee_armor", 0.0)), melee_armor_now, 0)
	_add_flat(parts, "盾甲", float(base.get("shield_armor", 0.0)), shield_armor_now, 0)

	var shield_pierce := _num(e, "shield_pierce", 0.0)
	if shield_pierce > 0.001:
		parts.append("破盾 %+.0f%%" % (shield_pierce * 100.0))
	var melee_pierce := _num(e, "melee_pierce", 0.0)
	if melee_pierce > 0.001:
		parts.append("破甲 %+.0f%%" % (melee_pierce * 100.0))
	_add_ratio(parts, "对建筑", _num(e, "building_damage_pct", 0.0))
	_add_ratio(parts, "对弓兵", _num(e, "vs_archer_pct", 0.0))
	_add_ratio(parts, "对骑兵", _num(e, "vs_cavalry_pct", 0.0))
	_add_ratio(parts, "对船只", _num(e, "vs_ship_pct", 0.0))

	var spell_power := _num(e, "spell_power_mult", 1.0)
	if absf(spell_power - 1.0) > 0.005:
		parts.append("法术强度 %+.0f%%" % ((spell_power - 1.0) * 100.0))
	var spell_resist := _num(e, "spell_resist", 0.0)
	if spell_resist > 0.001:
		parts.append("法术减伤 %+.0f%%" % (spell_resist * 100.0))
	var accuracy := _num(e, "accuracy_mult", 1.0)
	if accuracy > 0.001 and absf(accuracy - 1.0) > 0.005:
		parts.append("投石精度 %+.0f%%" % ((1.0 - accuracy) * 100.0))
	var splash := _num(e, "splash_damage_mult", 0.0)
	if splash > 0.001:
		parts.append("溅射 %.0f%%" % (splash * 100.0))
	var volley_count := int(_num(e, "volley_count", 1.0))
	if volley_count > 1:
		parts.append("齐射 ×%d" % volley_count)
	var volley_mult := _num(e, "volley_mult", 1.0)
	if volley_mult > 1.001:
		parts.append("齐射伤害 %+.0f%%" % ((volley_mult - 1.0) * 100.0))
	return parts

static func _num(e, key: String, default: float) -> float:
	var v = e.get(key)
	if v == null:
		return default
	return float(v)

static func _add_pct(parts: Array, label: String, base: float, cur: float) -> void:
	if base <= 0.001:
		return
	var pct := (cur / base - 1.0) * 100.0
	if absf(pct) < 0.5:
		return
	parts.append("%s %+.0f%%" % [label, pct])

# 攻击间隔越小越快：用基础间隔 / 当前间隔换算成“攻速提升”。
static func _add_attack_speed(parts: Array, base: float, cur: float) -> void:
	if base <= 0.001 or cur <= 0.001:
		return
	var pct := (base / cur - 1.0) * 100.0
	if absf(pct) < 0.5:
		return
	parts.append("攻速 %+.0f%%" % pct)

static func _add_flat(parts: Array, label: String, base: float, cur: float, decimals: int) -> void:
	var diff := cur - base
	if absf(diff) < 0.05:
		return
	if decimals > 0:
		parts.append("%s %+.1f" % [label, diff])
	else:
		parts.append("%s %+.0f" % [label, diff])

static func _add_ratio(parts: Array, label: String, ratio: float) -> void:
	if ratio > 0.001:
		parts.append("%s %+.0f%%" % [label, ratio * 100.0])

# ==================== 联机：按本地科研 mods 汇总 ====================

static func _unit_mods_parts(parts: Array, uid: int, mods: Dictionary) -> void:
	var classes: Array = TechTreeData.UNIT_CLASSES.get(uid, [])
	var hp := _pct(mods, "all_hp_pct")
	var atk := 0.0
	var spd := _pct(mods, "all_speed_pct")
	var aspd := 0.0
	var vision := 0.0
	for cls in classes:
		hp += _pct(mods, "class_hp_pct:%s" % cls)
		atk += _pct(mods, "class_attack_pct:%s" % cls)
		spd += _pct(mods, "class_speed_pct:%s" % cls)
		aspd += _pct(mods, "class_attack_speed_pct:%s" % cls)
		vision += _pct(mods, "class_vision_pct:%s" % cls)
	hp += _pct(mods, "unit_hp_pct:%d" % uid)
	atk += _pct(mods, "unit_attack_pct:%d" % uid)
	spd += _pct(mods, "unit_speed_pct:%d" % uid)
	aspd += _pct(mods, "unit_attack_speed_pct:%d" % uid)
	vision += _pct(mods, "unit_vision_pct:%d" % uid)
	_add_pct_ratio(parts, "生命", hp)
	_add_pct_ratio(parts, "攻击", atk)
	_add_pct_ratio(parts, "攻速", aspd)
	_add_pct_ratio(parts, "移速", spd)
	_add_pct_ratio(parts, "视野", vision)

	var melee := 0
	var shield := 0
	for cls in classes:
		melee += int(mods.get("class_melee_armor:%s" % cls, 0))
		shield += int(mods.get("class_shield_armor:%s" % cls, 0))
	melee += int(mods.get("class_melee_armor:%d" % uid, 0))
	shield += int(mods.get("class_shield_armor:%d" % uid, 0))
	melee += int(mods.get("unit_melee_armor:%d" % uid, 0))
	shield += int(mods.get("unit_shield_armor:%d" % uid, 0))
	_add_flat_ratio(parts, "近战护甲", melee)
	_add_flat_ratio(parts, "盾甲", shield)

	if uid in [12, 31, 37, 58]:
		_add_flat_ratio(parts, "射程", float(mods.get("archer_range", 0.0)), true)
	if uid in TechTreeData.CANNON_UNIT_IDS:
		_add_pct_ratio(parts, "炮伤", _pct(mods, "cannon_damage_pct"))
		_add_flat_ratio(parts, "炮程", float(mods.get("cannon_range", 0.0)), true)
		var cannon_splash := float(mods.get("cannon_splash", 0.0))
		if cannon_splash > 0.0:
			parts.append("溅射 %.0f%%" % cannon_splash)
	if uid in TechTreeData.STONE_UNIT_IDS:
		_add_pct_ratio(parts, "石弹伤害", _pct(mods, "stone_damage_pct"))
		_add_pct_ratio(parts, "溅射范围", _pct(mods, "stone_splash_pct"))
		var acc_mult := 1.0 + _pct(mods, "treb_accuracy_pct")
		if absf(acc_mult - 1.0) > 0.005:
			parts.append("投石精度 %+.0f%%" % ((1.0 - acc_mult) * 100.0))

	var shield_pierce := _raw_pct(mods, "class_shield_pierce", classes)
	if uid in [12, 31, 37, 58]:
		shield_pierce = maxf(shield_pierce, float(mods.get("archer_shield_pierce", 0.0)))
	if shield_pierce > 0.001:
		parts.append("破盾 %+.0f%%" % (shield_pierce * 100.0))
	var melee_pierce := _raw_pct(mods, "class_melee_pierce", classes)
	if melee_pierce > 0.001:
		parts.append("破甲 %+.0f%%" % (melee_pierce * 100.0))

	var building_dmg := 0.0
	var vs_archer := 0.0
	var vs_cavalry := 0.0
	for cls in classes:
		building_dmg += _pct(mods, "class_building_damage_pct:%s" % cls)
		vs_archer += _pct(mods, "class_vs_archer_pct:%s" % cls)
		vs_cavalry += _pct(mods, "class_vs_cavalry_pct:%s" % cls)
	_add_pct_ratio(parts, "对建筑", building_dmg)
	_add_pct_ratio(parts, "对弓兵", vs_archer)
	_add_pct_ratio(parts, "对骑兵", vs_cavalry)
	_add_pct_ratio(parts, "对船只", _pct(mods, "unit_vs_ship_pct:%d" % uid))

	if uid in [55, 56, 57]:
		_add_pct_ratio(parts, "法术强度", _pct(mods, "spell_power_pct"))
		_add_pct_ratio(parts, "法术减伤", _pct(mods, "spell_resist_pct"))

	# 生产/训练加速：对军事单位有意义，显示出来便于判断该单位该不该优先出。
	var military := false
	for cls in classes:
		if cls in ["infantry", "archer", "cavalry", "siege", "ship", "caster", "heavy"]:
			military = true
	var training := _pct(mods, "unit_training_speed_pct:%d" % uid)
	for cls in classes:
		training += _pct(mods, "class_training_speed_pct:%s" % cls)
	if military:
		training += _pct(mods, "production_speed_pct")
	_add_pct_ratio(parts, "训练速度", training)

static func _building_mods_parts(parts: Array, uid: int, mods: Dictionary) -> void:
	var hp := _pct(mods, "building_hp_pct") + _pct(mods, "building_hp_pct:%d" % uid)
	if uid in [27, 53]:
		hp += _pct(mods, "castle_wall_hp_pct")
	_add_pct_ratio(parts, "生命", hp)
	var armor := int(mods.get("building_armor", 0))
	if uid in [27, 53]:
		armor += int(mods.get("castle_wall_armor", 0))
	_add_flat_ratio(parts, "双护甲", armor)
	_add_pct_ratio(parts, "攻击", _pct(mods, "building_attack_pct:%d" % uid))
	if uid in [20, 53]:
		_add_pct_ratio(parts, "主城攻击", _pct(mods, "main_castle_attack_pct"))
		if float(mods.get("main_city_attack", 0.0)) > 0.0:
			parts.append("主城攻击 %d" % int(mods.get("main_city_attack", 0.0)))
		_add_flat_ratio(parts, "主城射程", float(mods.get("main_city_range", 0.0)), true)
	if uid in [25, 26]:
		_add_flat_ratio(parts, "塔射程", float(mods.get("tower_range", 0.0)), true)
		_add_pct_ratio(parts, "塔攻速", _pct(mods, "tower_attack_speed_pct"))
	if uid in TechTreeData.CANNON_UNIT_IDS:
		_add_pct_ratio(parts, "炮伤", _pct(mods, "cannon_damage_pct"))
		_add_flat_ratio(parts, "炮程", float(mods.get("cannon_range", 0.0)), true)
		if float(mods.get("cannon_splash", 0.0)) > 0.0:
			parts.append("溅射 %.0f%%" % float(mods.get("cannon_splash", 0.0)))
	if uid in [20, 53] and int(mods.get("volley_count", 1)) > 1:
		parts.append("齐射 ×%d" % int(mods.get("volley_count", 1)))

static func _pct(mods: Dictionary, key: String) -> float:
	return float(mods.get(key, 0.0)) / 100.0

static func _raw_pct(mods: Dictionary, prefix: String, classes: Array) -> float:
	var total := 0.0
	for cls in classes:
		total += float(mods.get("%s:%s" % [prefix, cls], 0.0))
	return total

static func _add_pct_ratio(parts: Array, label: String, ratio: float) -> void:
	if absf(ratio) < 0.005:
		return
	parts.append("%s %+.0f%%" % [label, ratio * 100.0])

static func _add_flat_ratio(parts: Array, label: String, value: float, decimal: bool = false) -> void:
	if absf(value) < 0.05:
		return
	if decimal:
		parts.append("%s %+.1f" % [label, value])
	else:
		parts.append("%s %+.0f" % [label, value])

# scripts/data/ResearchAdvisor.gd
# 智能科研官的纯规则：默认配置、分类优先级清洗、升时代所需科技。
# 不持有对局状态；真正的自动研究由 RTSBattleManager 按玩家状态执行。
class_name ResearchAdvisor
extends RefCounted

# 通用科技分类 A~I，外加 N（国家特色科技）。
const CATEGORY_IDS: Array = ["A", "B", "C", "D", "E", "F", "G", "H", "I", "N"]
const DEFAULT_PRIORITY: Array = ["A", "B", "C", "D", "E", "F", "G", "H", "I", "N"]

static func default_config() -> Dictionary:
	return {
		"enabled": false,
		"auto_age": true,
		"priority": DEFAULT_PRIORITY.duplicate(),
	}

# 兼容旧状态/恶意客户端：只接受已知分类，去重，缺失分类补到末尾。
static func normalize_config(raw) -> Dictionary:
	var cfg := default_config()
	if not (raw is Dictionary):
		return cfg
	var src: Dictionary = raw
	cfg["enabled"] = bool(src.get("enabled", false))
	cfg["auto_age"] = bool(src.get("auto_age", true))
	cfg["priority"] = normalize_priority(src.get("priority", []))
	return cfg

static func normalize_priority(raw) -> Array:
	var out: Array = []
	if raw is Array:
		for v in raw:
			var cid := String(v)
			if CATEGORY_IDS.has(cid) and not out.has(cid):
				out.append(cid)
	for cid in CATEGORY_IDS:
		if not out.has(cid):
			out.append(cid)
	return out

static func priority_rank(priority: Array, cid: String) -> int:
	var idx := priority.find(cid)
	return idx if idx >= 0 else CATEGORY_IDS.size()

static func category_name(cid: String) -> String:
	if cid == "N":
		return "国家特色"
	for cat in TechTreeData.CATEGORIES:
		if String(cat.get("id", "")) == cid:
			return String(cat.get("name", cid))
	return cid

# 升时代除人口外还有建筑条件；这些科技解锁对应建筑，科研官在条件未满足时
# 会优先补它们，避免玩家明明开着自动升时代却永远卡在建筑条件上。
# 这里递归带上前置科技（例如 B6 需要 B1/B2），防止玩家把对应分类排到后面时卡住。
static func age_requirement_techs(target_age: int) -> Array:
	var base: Array = []
	match target_age:
		2:
			# 3 座封建建筑：攻城车间(24)/集市(52)/修道院(54)/箭塔(25)
			base = ["F1", "I5", "H1", "B6"]
		3:
			# 4 座城堡建筑且至少 2 座城堡：城堡(53)/重装武器厂(29)/书院(42)
			base = ["A4", "A2", "B6", "G1", "C3", "I1"]
	var out: Array = []
	for tid in base:
		_add_tech_with_prereq(String(tid), out)
	return out

static func _add_tech_with_prereq(tid: String, out: Array) -> void:
	if tid.is_empty() or out.has(tid):
		return
	var t := TechTreeData.get_tech(tid)
	if t.is_empty():
		return
	for p in t.get("prereq", []):
		var pid := String(p)
		if not pid.begins_with("N"):
			_add_tech_with_prereq(pid, out)
	out.append(tid)

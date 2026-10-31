class_name RoleLedger
extends RefCounted

# P3.1 统一角色账本：一个单位同时最多一条 claim，谁占用、为什么占用、什么时候到期都只有一处记录。
#
# 现阶段是「影子账本」：AI 原有的 _roles 继续作为唯一事实来源，写入时同步镜像到这里，
# 每 5 秒对账一次（[LEDGER] MISMATCH）。确认无误后再把读取点切过来（P3.1 第二步）。

const SimTime = preload("res://scripts/core/SimTime.gd")

var _claims: Dictionary = {}      # uid:int -> {kind:int, source:String, since:float, until:float}
var _by_source: Dictionary = {}   # source:String -> {uid:int: true}

var claims: int = 0
var releases: int = 0
var rejected: int = 0             # 已有其他来源占用时被拒绝的次数
var expired: int = 0

func has(uid: int) -> bool:
	return _claims.has(uid)

func get_claim(uid: int) -> Dictionary:
	return _claims.get(uid, {})

func kind_of(uid: int) -> int:
	return int(_claims.get(uid, {}).get("kind", -1))

func source_of(uid: int) -> String:
	return String(_claims.get(uid, {}).get("source", ""))

# lease <= 0 表示不设到期时间（由调用方显式释放）。
func claim(uid: int, kind: int, source: String, now: float, lease: float = -1.0) -> bool:
	var cur: Dictionary = _claims.get(uid, {})
	if not cur.is_empty() and String(cur.get("source", "")) != source:
		rejected += 1
		return false
	var until: float = (now + lease) if lease > 0.0 else -1.0
	_claims[uid] = {"kind": kind, "source": source, "since": now, "until": until}
	var src: Dictionary = _by_source.get(source, {})
	src[uid] = true
	_by_source[source] = src
	claims += 1
	return true

func release(uid: int) -> bool:
	var cur: Dictionary = _claims.get(uid, {})
	if cur.is_empty():
		return false
	var source: String = String(cur.get("source", ""))
	_claims.erase(uid)
	var src: Dictionary = _by_source.get(source, {})
	src.erase(uid)
	if src.is_empty():
		_by_source.erase(source)
	else:
		_by_source[source] = src
	releases += 1
	return true

func release_by_source(source: String) -> int:
	var src: Dictionary = _by_source.get(source, {})
	if src.is_empty():
		return 0
	var freed: int = 0
	for uid in src.keys():
		if release(int(uid)):
			freed += 1
	return freed

# 回收过期租约；调用方负责处理单位死亡（先判存活再 release）。
func sweep(now: float) -> int:
	var dead: Array = []
	for uid in _claims.keys():
		var ent: Dictionary = _claims[uid]
		var until: float = float(ent.get("until", -1.0))
		if until >= 0.0 and until <= now:
			dead.append(int(uid))
	for uid in dead:
		if release(uid):
			expired += 1
	return dead.size()

func holders(kind: int) -> Array:
	var out: Array = []
	for uid in _claims.keys():
		if int(_claims[uid].get("kind", -1)) == kind:
			out.append(int(uid))
	return out

func count(kind: int) -> int:
	return holders(kind).size()

# 按来源统计：同一本账里有 director / worker / defense 多个来源，
# 对账与摘要必须只看自己那一份，否则表里的数字会互相污染。
func size_of(source: String) -> int:
	return (_by_source.get(source, {}) as Dictionary).size()

func counts_of(source: String) -> Dictionary:
	var out: Dictionary = {}
	var src: Dictionary = _by_source.get(source, {})
	for uid in src.keys():
		var kind: int = int(_claims[uid].get("kind", -1))
		out[kind] = int(out.get(kind, 0)) + 1
	return out

func count_of(source: String, kind: int) -> int:
	var n: int = 0
	var src: Dictionary = _by_source.get(source, {})
	for uid in src.keys():
		if int(_claims[uid].get("kind", -1)) == kind:
			n += 1
	return n

func entries_of(source: String) -> Dictionary:
	var out: Dictionary = {}
	var src: Dictionary = _by_source.get(source, {})
	for uid in src.keys():
		out[int(uid)] = _claims[uid].duplicate()
	return out

func counts() -> Dictionary:
	var out: Dictionary = {}
	for uid in _claims.keys():
		var k: int = int(_claims[uid].get("kind", 0))
		out[k] = int(out.get(k, 0)) + 1
	return out

func size() -> int:
	return _claims.size()

func snapshot() -> Dictionary:
	return {
		"size": _claims.size(),
		"claims": claims,
		"releases": releases,
		"rejected": rejected,
		"expired": expired,
		"by_source": _by_source.duplicate(true),
	}

extends Node

static var MAP_SIZE: int = 100
const GRID_SIZE = 1.0
# ── 统一坡度通行 ──
# 坡度 s = |高差| / 水平距离。实际移速 = 基础速度 / (1 + 权重 * s²)，
# A* 的单步时间成本 = 水平距离 * (1 + 权重 * s²)。
# 这样“速度平方级下降”和“寻路成本平方级上升”严格互为倒数。
# 坡度只负责在可走地形上调整速度；普通山体是否可通行仍由 terrain/overlay 决定：
# 山地(1)默认封闭，只有缓坡(4)/山顶台地(5)能走。
const SLOPE_TIME_WEIGHT: float = 2.0
# 可通行最大坡度。超过这个坡度的台阶（悬崖）上下都不允许走：
# 军队不能下陡坡，也不能爬绝壁。这个值同时用于 A*、实际移动、地图可达性。
const MAX_WALK_SLOPE: float = 1.5

static func slope_time_multiplier(dh: float, run_distance: float) -> float:
	var run: float = maxf(run_distance, 0.001)
	var slope: float = absf(dh) / run
	return 1.0 + SLOPE_TIME_WEIGHT * slope * slope

static func is_cliff_slope(dh: float, run_distance: float) -> bool:
	var run: float = maxf(run_distance, 0.001)
	return absf(dh) / run > MAX_WALK_SLOPE
enum Team { BLUE = 1, RED = 0, NEUTRAL = 2 }
enum Nation { VIKING, ENGLAND, FRANCE, CHINA, HUNGARY, JAPAN, BYZANTINE, MONGOL, PERSIA, SPAIN }
const MAX_PLAYERS = 6

enum PlayerSlot { SLOT_0 = 0, SLOT_1 = 1, SLOT_2 = 2 }

const COLOR_POOL = [
	Color(1.0, 0.2, 0.1),
	Color(0.2, 0.6, 1.0),
	Color(1.0, 0.65, 0.0),
	Color(0.5, 0.3, 0.9),
	Color(0.2, 0.85, 0.4),
	Color(1.0, 0.45, 0.75),
	Color(0.0, 0.85, 0.85),   # 青
	Color(0.95, 0.85, 0.2),   # 明黄，蒙古
	Color(0.45, 0.85, 0.25),  # 草绿，波斯
	Color(0.85, 0.2, 0.85),   # 品红，西班牙
]

# 国家颜色不再绑定 Nation 枚举，而是每局开始时随机打乱颜色池后分配。
# 颜色池容量 >= 国家数量，按排列分配即可保证同一局内所有国家颜色唯一。
static var _nation_colors: Dictionary = {}

# 每局初始化时调用一次：随机打乱颜色池，再把前 N 个颜色分配给 N 个国家。
static func randomize_nation_colors() -> void:
	var pool: Array = COLOR_POOL.duplicate()
	pool.shuffle()
	_nation_colors.clear()
	for i in range(mini(pool.size(), Nation.size())):
		_nation_colors[i] = pool[i]

# 联机客户端从服务器快照恢复同一套国家配色。
static func set_nation_colors(colors: Dictionary) -> void:
	_nation_colors.clear()
	for key in colors:
		_nation_colors[int(key)] = colors[key]

static func get_nation_colors() -> Dictionary:
	return _nation_colors.duplicate()

static func has_nation_color(nation: int) -> bool:
	return _nation_colors.has(nation)

static func get_nation_color(nation: int, fallback: Color = Color(0.7, 0.7, 0.7)) -> Color:
	if _nation_colors.has(nation):
		return _nation_colors[nation]
	return fallback

# 队伍基准色：同队玩家/单位统一使用同一色系（蓝队蓝色系、红队红色系）
const TEAM_BASE_COLORS = {
	Team.BLUE: Color(0.2, 0.6, 1.0),
	Team.RED: Color(1.0, 0.3, 0.2),
}

# 同队成员色：保持色相基本不变，仅调整明度/饱和度，
# 让友军之间既能区分、又不会出现「一个红血条一个蓝血条」的混色
static func get_team_member_color(team: int, slot: int, team_size: int = 2) -> Color:
	var base: Color = TEAM_BASE_COLORS.get(team, Color(0.7, 0.7, 0.7))
	var n: int = maxi(team_size, 1)
	if n <= 1:
		return base
	var idx: int = clampi(slot, 0, n - 1)
	var t: float = float(idx) / float(n - 1)          # 0=最暗, 1=最亮
	var h: float = fposmod(base.h + (t - 0.5) * 0.015, 1.0)
	var v: float = clampf(base.v * (0.8 + 0.2 * t), 0.25, 1.0)
	return Color.from_hsv(h, base.s, v, 1.0)

# 阵营色（信息面板血条用）：常规对局只看红蓝两方，混战模式每一方各占一个国家，
# 就改用国家色区分，否则五六方混战时血条全是一个红一个蓝，根本分不清谁打谁。
# 中立 / 未知队伍仍退回灰色。
static func faction_color(team: int, nation: int = -1, ffa: bool = false) -> Color:
	var base: Color = TEAM_BASE_COLORS.get(team, Color(0.7, 0.7, 0.7))
	if ffa and nation >= 0:
		return get_nation_color(nation, base)
	return base

static func get_player_color(peer_id: int) -> Color:
	return COLOR_POOL[peer_id % COLOR_POOL.size()]

const ENTITY_MODELS = {
	# 建筑 (hexagon)
	5: "res://models/town/cart.glb",
	6: "res://models/town/cart-high.glb",
	7: "res://models/forest/bridge.glb",
	8: "res://models/forest/ladder.glb",
	20: "res://models/hexagon/castle.glb",
	21: "res://models/hexagon/barracks.glb",
	22: "res://models/hexagon/unit-mill.glb",
	23: "res://models/hexagon/shipyard.glb",
	25: "res://models/hexagon/arrow-tower.glb",
	27: "res://models/castle/wall.glb",
	28: "res://models/hexagon/unit-mansion.glb",
	41: "res://models/castle/tower.glb",
	42: "res://models/hexagon/academy.glb",
	52: "res://models/hexagon/market.glb",
	53: "res://models/hexagon/building-walls.glb",
	54: "res://models/hexagon/building-village.glb",
	# 建筑 (castle)
	26: "res://models/castle/tower-complete-large.glb",
	# 建筑 (hexagon cabin)
	24: "res://models/hexagon/building-cabin.glb",
	29: "res://models/hexagon/building-cabin.glb",
	# 军队
	10: "",
	11: "res://models/arena/soldier.glb",
	12: "res://models/forest/archer.glb",
	13: "res://models/pirate/ship-medium.glb",
	14: "res://models/pirate/boat-row-small.glb",
	15: "res://models/arena/soldier.glb",
	16: "res://models/pirate/cannon-mobile.glb",
	17: "res://models/castle/catapult.glb",
	18: "res://models/castle/ram.glb",
	19: "res://models/arena/soldier.glb",
	30: "res://models/arena/soldier.glb",
	31: "res://models/arena/soldier.glb",
	32: "res://models/arena/soldier.glb",
	33: "res://models/town/wooden-ox.tscn",
	34: "res://models/arena/soldier.glb",
	35: "res://models/arena/soldier.glb",
	36: "res://models/arena/soldier.glb",
	37: "res://models/arena/soldier.glb",
	38: "res://models/arena/soldier.glb",
	65: "res://models/arena/soldier.glb",
	66: "res://models/arena/soldier.glb",
	67: "res://models/forest/archer.glb",
	68: "res://models/arena/soldier.glb",
	69: "res://models/arena/soldier.glb",
	39: "res://models/pirate/ship-large.glb",
	9: "res://models/pirate/ship-wreck.glb",
	40: "res://models/pirate/ship-small.glb",
	64: "res://models/pirate/cannon.glb",
	58: "res://models/castle/ballista.glb",
	59: "res://models/castle/siege-trebuchet.glb",
	# 商人/官员
	43: "", 44: "", 45: "", 51: "",
	46: "", 47: "", 48: "", 49: "", 50: "",
	# 资源
	3: "res://models/hexagon/farm.glb",
	4: "res://models/hexagon/water-rocks.glb",
	# 动物
	60: "res://models/pets/animal-cow.glb",
	61: "res://models/pets/animal-pig.glb",
	62: "res://models/pets/animal-polar.glb",
	63: "res://models/survival/fish.glb",
}

const CHARACTERS = ["character-female-a","character-female-b","character-female-c","character-female-d","character-female-e","character-female-f","character-male-a","character-male-b","character-male-c","character-male-d","character-male-e","character-male-f"]

static func _random_character() -> String:
	var c = CHARACTERS[randi() % CHARACTERS.size()]
	return "res://models/characters/%s.glb" % c

# 人物类按职业分池。原来农民、商人、官员、僧侣/长老/宗师这 13 个 ID 全部从同一套
# 12 个模型里随机挑，农民和宗师完全可能长得一模一样，战场上根本分不出谁是谁。
# 现在拆成四组互不重叠的池子：跨职业绝不会撞脸，同类内部仍随机保留一点变化。
static func _character_pool_for(entity_id: int) -> Array:
	if entity_id == 10:
		# 农民：朴素装束
		return ["character-male-a", "character-female-a", "character-male-b", "character-female-b"]
	if entity_id in [43, 44, 45, 51]:
		# 商人
		return ["character-male-c", "character-female-c"]
	if entity_id in [46, 47, 48, 49, 50]:
		# 官员
		return ["character-male-d", "character-female-d", "character-male-e", "character-female-e"]
	if entity_id in [55, 56, 57]:
		# 僧侣/长老/宗师：除模型外还有脚下法阵光环，颜色各不相同
		return ["character-male-f", "character-female-f"]
	return []

static func get_entity_model(entity_id: int, level: int = 1) -> String:
	var pool := _character_pool_for(entity_id)
	if not pool.is_empty():
		return "res://models/characters/%s.glb" % pool[randi() % pool.size()]
	if entity_id == 1:
		return "res://models/town/tree-high-round.glb" if level >= 5 else ("res://models/town/tree-high.glb" if level >= 3 else "res://models/town/tree.glb")
	if entity_id == 0:
		return "res://models/survival/rocks-sand-c.glb" if level >= 4 else ("res://models/survival/rocks-sand-b.glb" if level >= 2 else "res://models/survival/rocks-sand-a.glb")
	if entity_id == 2:
		return "res://models/survival/rocks-c.glb" if level >= 4 else ("res://models/survival/rocks-b.glb" if level >= 2 else "res://models/survival/rocks-a.glb")
	return ENTITY_MODELS.get(entity_id, "")

# character、步兵（arena/soldier）与弓箭手（forest/archer）模型的默认朝向与游戏逻辑相反，加载后需绕 Y 轴旋转 180° 掉头
static func model_needs_flip(model_path: String) -> bool:
	return model_path.contains("models/characters/") or model_path.ends_with("soldier.glb") or model_path.ends_with("archer.glb")

# 特殊实体模型缩放系数：在“按体半径自动缩放”之后再乘一次，用于调整观感（1.0 = 不调整）
# 服务端、客户端、放置预览三处共用，避免联机时两边大小不一致
const ENTITY_MODEL_SCALE := {
	# 船只：运载船、战船、采集船、炮艇、爆破船统一放大 2 倍
	9: 2.0,    # 运载船
	13: 2.0,   # 战船
	14: 2.0,   # 采集船
	25: 1.5,   # 箭塔：塔身放大 1.5 倍
	26: 1.5,   # 炮塔：塔身放大 1.5 倍
	39: 2.0,   # 炮艇
	40: 2.0,   # 爆破船
	41: 3.0,   # 瞭望塔：塔身放大三倍，功能性建筑更醒目
	60: 0.6,   # 牛
	61: 0.6,   # 猪
	62: 0.6,   # 羊
}

static func get_model_scale(entity_id: int) -> float:
	return float(ENTITY_MODEL_SCALE.get(entity_id, 1.0))

# 这些兵种按“步兵视觉高度”缩放，而不是跟随各自较小的 body_radius：
# 农民、弓箭手、商人、法师（僧侣/长老/宗师）和官员的碰撞半径较小，
# 若继续按半径自动缩放，模型会明显比步兵矮一截。
# 注意：这是纯视觉缩放，不影响碰撞、射程、靶心等战斗数值。
const INFANTRY_VISUAL_HEIGHT: float = 1.0
const INFANTRY_VISUAL_BODY_RADIUS: float = 0.5
const VISUAL_MATCH_INFANTRY_IDS: Array[int] = [
	10, 12, 31, 37,
	43, 44, 45, 51,
	46, 47, 48, 49, 50,
	55, 56, 57,
]

static func uses_infantry_visual_size(entity_id: int) -> bool:
	return entity_id in VISUAL_MATCH_INFANTRY_IDS

# 统一模型缩放：服务端、客户端、放置预览都走这里，避免联机两边大小不一致。
static func get_uniform_model_scale(entity_id: int, body_radius: float, aabb: AABB) -> float:
	var model_scale: float = get_model_scale(entity_id)
	if uses_infantry_visual_size(entity_id):
		return INFANTRY_VISUAL_HEIGHT / maxf(aabb.size.y, 0.01) * model_scale
	var target_size: float = body_radius * 2.0
	var current_size: float = maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z))
	if current_size <= 0.01:
		return model_scale
	return target_size / current_size * model_scale

# 法师/官员/商人的脚环、头顶标识也挂在实体根节点上，需要按同一视觉体型放大，
# 否则模型变大后标识会显得偏小、偏低。
static func get_visual_body_radius(entity_id: int, body_radius: float) -> float:
	if uses_infantry_visual_size(entity_id):
		return INFANTRY_VISUAL_BODY_RADIUS
	return body_radius

# 只放大模型高度、不改变横向占地的特殊缩放。
# 瞭望塔当前整体放大 3 倍，再乘 1.5 后实际塔高为原来的 4.5 倍，
# 但塔基占道宽度仍是 3 倍，避免拉高时把路口挤得更窄。
const ENTITY_MODEL_HEIGHT_SCALE := {
	41: 1.5,  # 瞭望塔
}

static func get_model_height_scale(entity_id: int) -> float:
	return float(ENTITY_MODEL_HEIGHT_SCALE.get(entity_id, 1.0))

# 服务端生成、客户端渲染、建造预览共用的模型缩放向量。
static func get_model_scale_vector(entity_id: int, uniform_scale: float) -> Vector3:
	return Vector3(uniform_scale, uniform_scale * get_model_height_scale(entity_id), uniform_scale)

# 城墙横向咬合余量：墙段中心间距是 body_radius*2，模型横向略放大一点，
# 让相邻墙段边缘真正重叠。服务端生成、客户端渲染、建造预览必须共用。
const WALL_JOIN_OVERLAP: float = 0.12

# 城墙不能按最大边等比缩放：模型高度大于占地宽度，等比缩放会让墙段
# 横向只有约 1.5 米，和 2 米中心间距对不上；这里分别按占地和高度缩放。
static func get_wall_model_scale(body_radius: float, aabb: AABB) -> Vector3:
	var target_size: float = body_radius * 2.0
	var footprint: float = maxf(aabb.size.x, aabb.size.z)
	var width_scale: float = (target_size + WALL_JOIN_OVERLAP) / maxf(footprint, 0.01)
	var height_scale: float = target_size / maxf(aabb.size.y, 0.01)
	return Vector3(width_scale, height_scale, width_scale)

# 建筑生成时的整体半径倍率。这些建筑与地形/城墙拼接尺寸绑定，不能放大：
# 瞭望塔、城墙、炮台、桥、梯子、箭塔、炮塔。
const BUILDING_BODY_SCALE := 2.0
const BUILDING_BODY_SCALE_EXCLUDED := [41, 27, 64, 7, 8, 25, 26]

static func get_building_body_scale(entity_id: int) -> float:
	if entity_id in BUILDING_BODY_SCALE_EXCLUDED:
		return 1.0
	return BUILDING_BODY_SCALE

# 船只模型按 ENTITY_MODEL_SCALE 放大了一倍，但配置里的 body_radius 仍是旧值。
# 推挤/碰撞半径用单独倍率补偿，避免船只视觉上互相大面积重叠；不直接改
# body_radius，避免同时改变攻击距离、靶心大小等战斗数值。
const SHIP_IDS := [9, 13, 14, 39, 40]
const SHIP_COLLISION_SCALE := 2.0

static func get_ship_collision_scale(entity_id: int) -> float:
	if entity_id in SHIP_IDS:
		return SHIP_COLLISION_SCALE
	return 1.0

# 动物（牛/猪/羊/鱼）。它们不走普通指令流，行为完全由 Army._process_animal 驱动：
# 在出生点附近游走、挨打才反击。服务端动画和客户端动画都需要单独判断，
# 否则快照里 order 恒为 idle，动物会滑行不迈腿。
const ANIMAL_IDS := [60, 61, 62, 63]

static func is_animal(entity_id: int) -> bool:
	return entity_id in ANIMAL_IDS

# 骑乘单位：主模型是士兵，坐骑（狗/象）作为子节点。动物 GLB 的朝向是 +Z，
# 而游戏单位前方是 -Z；坐骑必须绕 Y 轴转 180°，否则单位向前走时坐骑看起来在倒退。
const MOUNTED_ENTITY_IDS := [15, 19, 34, 38, 66, 67]
const MOUNT_YAW_DEG := 180.0

static func is_mounted(entity_id: int) -> bool:
	return entity_id in MOUNTED_ENTITY_IDS

# 坐骑顶面高度（相对 parent 的局部 Y）。坐骑按固定 0.7 缩放、位置又随体半径下压，
# 小体半径的侦察兵不能只按 0.5*body_radius 抬人，否则士兵整个人会陷进狗身体里。
static func get_model_top_in_parent(parent: Node3D, model: Node3D) -> float:
	if parent == null or model == null:
		return 0.0
	var inv := parent.global_transform.affine_inverse()
	var top := -INF
	for n in model.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var a: AABB = (inv * mi.global_transform) * mi.get_aabb()
		top = maxf(top, a.position.y + a.size.y)
	return top if top > -INF else 0.0

# 坐骑最低点（相对 parent 的局部 Y），用于把坐骑底面贴到单位脚下，避免整只陷进地里。
static func get_model_bottom_in_parent(parent: Node3D, model: Node3D) -> float:
	if parent == null or model == null:
		return 0.0
	var inv := parent.global_transform.affine_inverse()
	var bottom := INF
	for n in model.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var a: AABB = (inv * mi.global_transform) * mi.get_aabb()
		bottom = minf(bottom, a.position.y)
	return bottom if bottom < INF else 0.0

# 骑乘单位主模型（士兵）的局部 Y：默认抬高半个体半径；侦察兵这类坐骑顶面
# 高于默认值，按坐骑顶面继续抬高，只让小腿略微陷进坐骑，避免整个人卡进去。
static func get_rider_base_y(entity_id: int, body_radius: float, mount_top: float) -> float:
	if not is_mounted(entity_id):
		return 0.0
	var base: float = body_radius * 0.5
	if mount_top > 0.0:
		base = maxf(base, mount_top - body_radius * 0.25)
	return base

const DEMOLISHED_MODELS = {
	17: "res://models/castle/siege-catapult-demolished.glb",
	18: "res://models/castle/siege-ram-demolished.glb",
	27: "res://models/arena/bricks.glb",
	58: "res://models/castle/siege-ballista-demolished.glb",
	59: "res://models/castle/siege-trebuchet-demolished.glb",
	41: "res://models/castle/siege-tower-demolished.glb",
}

static func get_demolished_model(entity_id: int) -> String:
	return DEMOLISHED_MODELS.get(entity_id, "")

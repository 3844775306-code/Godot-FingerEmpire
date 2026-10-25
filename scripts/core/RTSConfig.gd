extends Node

static var MAP_SIZE: int = 100
const GRID_SIZE = 1.0
# ── 统一坡度通行 ──
# 坡度 s = |高差| / 水平距离。实际移速 = 基础速度 / (1 + 权重 * s²)，
# A* 的单步时间成本 = 水平距离 * (1 + 权重 * s²)。
# 这样“速度平方级下降”和“寻路成本平方级上升”严格互为倒数，
# 平原、丘陵、山地共用同一套规则，不再依赖地形类型或 overlay 标记。
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
enum Nation { VIKING, ENGLAND, FRANCE, CHINA, HUNGARY, JAPAN, BYZANTINE }
const MAX_PLAYERS = 6

enum PlayerSlot { SLOT_0 = 0, SLOT_1 = 1, SLOT_2 = 2 }

const COLOR_POOL = [
	Color(1.0, 0.2, 0.1),
	Color(0.2, 0.6, 1.0),
	Color(1.0, 0.65, 0.0),
	Color(0.5, 0.3, 0.9),
	Color(0.2, 0.85, 0.4),
	Color(1.0, 0.45, 0.75),
	Color(0.0, 0.85, 0.85),   # 青，补足 7 国所需的 7 个不重复颜色
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
	33: "res://models/castle/ballista.glb",
	34: "res://models/arena/soldier.glb",
	35: "res://models/arena/soldier.glb",
	36: "res://models/arena/soldier.glb",
	37: "res://models/arena/soldier.glb",
	38: "res://models/arena/soldier.glb",
	65: "res://models/arena/soldier.glb",
	66: "res://models/arena/soldier.glb",
	39: "res://models/pirate/ship-large.glb",
	9: "res://models/pirate/ship-wreck.glb",
	40: "res://models/pirate/ship-small.glb",
	64: "res://models/pirate/cannon.glb",
	58: "res://models/defense/weapon-ballista.glb",
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

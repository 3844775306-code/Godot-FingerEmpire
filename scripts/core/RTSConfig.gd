extends Node

static var MAP_SIZE: int = 100
const GRID_SIZE = 1.0
enum Team { BLUE = 1, RED = 0, NEUTRAL = 2 }
enum Nation {
	VIKING,
	ENGLAND,
	FRANCE,
	CHINA,
	HUNGARY
}
const MAX_PLAYERS = 4

enum PlayerSlot {
	SLOT_0 = 0,
	SLOT_1 = 1
}

const COLOR_POOL = [
	Color(1.0, 0.2, 0.1),
	Color(0.2, 0.6, 1.0),
	Color(1.0, 0.65, 0.0),
	Color(0.5, 0.3, 0.9),
]

static func get_player_color(peer_id: int) -> Color:
	return COLOR_POOL[peer_id % COLOR_POOL.size()]

const ENTITY_MODELS = {
	# 建筑
	20: "res://models/castle.glb",
	21: "res://models/barracks.glb",
	22: "res://models/unit-mill.glb",
	23: "res://models/shipyard.glb",
	24: "res://models/siege_workshop.glb",
	25: "res://models/arrow-tower.glb",
	26: "res://models/tower-complete-large.glb",
	28: "res://models/unit-mansion.glb",
	29: "res://models/building-cabin.glb",
	41: "res://models/tower.glb",
	42: "res://models/academy.glb",
	52: "res://models/market.glb",
	53: "res://models/building-walls.glb",
	# 军队
	10: "res://models/soldier.glb",
	11: "res://models/soldier.glb",
	12: "res://models/archer.glb",
	13: "res://models/ship-medium.glb",
	14: "res://models/ship-small.glb",
	16: "res://models/cannon-mobile.glb",
	17: "res://models/catapult.glb",
	18: "res://models/ram.glb",
	33: "res://models/ballista.glb",
	39: "res://models/ship-large.glb",
	40: "res://models/ship-small.glb",
	# 资源
	3: "res://models/farm.glb",
	4: "res://models/water-rocks.glb",
	# 动物
	60: "res://models/animal-cow.glb",
	61: "res://models/animal-pig.glb",
	62: "res://models/animal-polar.glb",
	63: "res://models/fish.glb",
}

static func get_entity_model(entity_id: int, level: int = 1) -> String:
	if entity_id == 1:
		return "res://models/tree-high-round.glb" if level >= 5 else ("res://models/tree-high.glb" if level >= 3 else "res://models/tree.glb")
	if entity_id == 0:
		return "res://models/rocks-sand-c.glb" if level >= 4 else ("res://models/rocks-sand-b.glb" if level >= 2 else "res://models/rocks-sand-a.glb")
	if entity_id == 2:
		return "res://models/rocks-c.glb" if level >= 4 else ("res://models/rocks-b.glb" if level >= 2 else "res://models/rocks-a.glb")
	return ENTITY_MODELS.get(entity_id, "")

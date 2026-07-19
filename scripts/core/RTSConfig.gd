extends Node

static var MAP_SIZE: int = 100
const GRID_SIZE = 1.0
enum Team { BLUE = 1, RED = 0, NEUTRAL = 2 }
enum Nation { VIKING, ENGLAND, FRANCE, CHINA, HUNGARY }
const MAX_PLAYERS = 4

enum PlayerSlot { SLOT_0 = 0, SLOT_1 = 1 }

const COLOR_POOL = [
	Color(1.0, 0.2, 0.1),
	Color(0.2, 0.6, 1.0),
	Color(1.0, 0.65, 0.0),
	Color(0.5, 0.3, 0.9),
]

static func get_player_color(peer_id: int) -> Color:
	return COLOR_POOL[peer_id % COLOR_POOL.size()]

const ENTITY_MODELS = {
	# 建筑 (hexagon)
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
	39: "res://models/pirate/ship-large.glb",
	40: "res://models/pirate/ship-small.glb",
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

static func get_entity_model(entity_id: int, level: int = 1) -> String:
	if entity_id in [10, 43, 44, 45, 46, 47, 48, 49, 50, 51]:
		return _random_character()
	if entity_id == 1:
		return "res://models/town/tree-high-round.glb" if level >= 5 else ("res://models/town/tree-high.glb" if level >= 3 else "res://models/town/tree.glb")
	if entity_id == 0:
		return "res://models/pirate/rocks-sand-c.glb" if level >= 4 else ("res://models/pirate/rocks-sand-b.glb" if level >= 2 else "res://models/pirate/rocks-sand-a.glb")
	if entity_id == 2:
		return "res://models/pirate/rocks-c.glb" if level >= 4 else ("res://models/pirate/rocks-b.glb" if level >= 2 else "res://models/pirate/rocks-a.glb")
	return ENTITY_MODELS.get(entity_id, "")

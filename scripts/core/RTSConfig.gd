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
	22: "res://models/warehouse.glb",
	23: "res://models/shipyard.glb",
	24: "res://models/siege_workshop.glb",
	25: "res://models/arrow_tower.glb",
	26: "res://models/cannon_tower.glb",
	28: "res://models/house.glb",
	29: "res://models/siege_workshop.glb",
	41: "res://models/tower.glb",
	42: "res://models/academy.glb",
	52: "res://models/market.glb",
	53: "res://models/castle.glb",
	# 军队
	10: "res://models/soldier.glb",
	11: "res://models/soldier.glb",
	12: "res://models/archer.glb",
	13: "res://models/warship.glb",
	14: "res://models/boat_small.glb",
	16: "res://models/cannon.glb",
	17: "res://models/catapult.glb",
	18: "res://models/ram.glb",
	33: "res://models/ballista.glb",
	40: "res://models/boat_large.glb",
	# 资源
	2: "res://models/stones.glb",
	3: "res://models/farm.glb",
}

static func get_entity_model(entity_id: int, level: int = 1, pos: Vector3 = Vector3.ZERO) -> String:
	if entity_id == 1:
		return "res://models/tree-large.glb" if level >= 4 else "res://models/tree-small.glb"
	if entity_id == 0:
		return "res://models/rocks-large.glb" if level >= 4 else "res://models/rocks-small.glb"
	if entity_id == 27:
		var bm = Engine.get_main_loop().get_first_node_in_group("battle_manager")
		if bm:
			var has_x = false; var has_z = false
			for e in bm.entities.get_children():
				if e is Building and e.entity_id == 27 and e.health > 0:
					var d = e.global_position - pos
					if abs(d.x) < 2.0 and abs(d.z) < 0.5: has_x = true
					if abs(d.z) < 2.0 and abs(d.x) < 0.5: has_z = true
			if has_x and has_z: return "res://models/wall-corner.glb"
		return "res://models/wall.glb"
	return ENTITY_MODELS.get(entity_id, "")

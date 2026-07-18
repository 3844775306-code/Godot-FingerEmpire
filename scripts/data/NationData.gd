# scripts/data/NationData.gd
class_name NationData
extends RefCounted

static var NATION_UNITS: Dictionary = {}

static func _static_init():
	if not NATION_UNITS.is_empty():
		return
	
	NATION_UNITS = {
		0: [ # VIKING
			{ "unit_id": 10, "cooldown": 3.0, "queue_limit": 10 },
			{ "unit_id": 30, "cooldown": 5.0, "queue_limit": 6 }
		],
		1: [ # ENGLAND
			{ "unit_id": 10, "cooldown": 3.0, "queue_limit": 10 },
			{ "unit_id": 31, "cooldown": 4.0, "queue_limit": 8 }
		],
		2: [ # FRANCE
			{ "unit_id": 10, "cooldown": 3.0, "queue_limit": 10 },
			{ "unit_id": 32, "cooldown": 6.0, "queue_limit": 5 }
		],
		3: [ # CHINA
			{ "unit_id": 10, "cooldown": 3.0, "queue_limit": 10 },
			{ "unit_id": 33, "cooldown": 3.5, "queue_limit": 10 }
		],
		4: [ # Hungary
			{ "unit_id": 10, "cooldown": 3.0, "queue_limit": 10 },
			{ "unit_id": 34, "cooldown": 8.5, "queue_limit": 5 }
		]
	}

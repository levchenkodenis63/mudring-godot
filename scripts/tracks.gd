extends RefCounted
## Трассы: кольцо из прямых с ваннами и поворотов в одну сторону (камера снаружи, едем слева направо).
## У каждой прямой — свой постоянный сид и число ванн: раскладка ванн и стенок у трассы всегда одна и та же,
## поэтому рекорды на ней сравнимы (таблица рекордов — по трассе и уровню).
##   R — радиус поворотов, straights — прямые по порядку (поворот после каждой — на 360°/их число).

const TRACKS := [
	{"id": "oval", "name": "Овал", "R": 16.0,
		"straights": [{"seed": 101, "baths": 3}, {"seed": 102, "baths": 3}]},
	{"id": "long", "name": "Длинный овал", "R": 20.0,
		"straights": [{"seed": 201, "baths": 4}, {"seed": 202, "baths": 4}]},
	{"id": "triangle", "name": "Треугольник", "R": 14.0,
		"straights": [{"seed": 301, "baths": 2}, {"seed": 302, "baths": 2}, {"seed": 303, "baths": 2}]},
	{"id": "square", "name": "Квадрат", "R": 12.0,
		"straights": [{"seed": 401, "baths": 2}, {"seed": 402, "baths": 1}, {"seed": 403, "baths": 2}, {"seed": 404, "baths": 1}]},
	{"id": "pentagon", "name": "Пятиугольник", "R": 11.0,
		"straights": [{"seed": 501, "baths": 2}, {"seed": 502, "baths": 1}, {"seed": 503, "baths": 2}, {"seed": 504, "baths": 1}, {"seed": 505, "baths": 1}]},
]


static func by_id(id: String) -> Dictionary:
	for t in TRACKS:
		if t["id"] == id:
			return t
	return TRACKS[0]


static func ids() -> Array:
	var out: Array = []
	for t in TRACKS:
		out.append(t["id"])
	return out

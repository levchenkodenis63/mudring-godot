extends RefCounted
## Кольцо из прямых и поворотов (описание — scripts/tracks.gd): прямая 0 → поворот → прямая 1 → поворот → …
## Ванны и стенки с лебёдкой — на прямых (у каждой своя трасса core.make_straight), повороты — ровная грязь
## с ограничением скорости. Все повороты в одну сторону: камера стоит снаружи кольца, квадроцикл едет слева направо.
##
## Физика (core.gd) считает одну координату x вдоль участка. Здесь — перевод «участок + x» в 3D-точку,
## направление и наружную нормаль; положение на круге; профиль колеи поперёк для рельефа.

const MR = preload("res://scripts/core.gd")

const XS := -12.0           # начало прямой по физике: за стартовой линией помещается сетка участников
const VTURN := 9.0          # предел скорости в повороте, м/с (~32 км/ч)
const HALF := 1.6           # полуширина колеи
const BANK := 2.8           # бровка
const EDGE := 3.2           # край насыпи
const ZS := [-EDGE, -BANK, -HALF, HALF, BANK, EDGE]   # профиль поперёк: минус — внутрь кольца, плюс — наружу
const BERM := 0.35          # внешняя бровка в повороте приподнята

var def: Dictionary         # описание трассы (tracks.gd)
var segs: Array = []        # участки: {turn, len, p0, phi, …}; у прямой — track (физика) и base (с настоящим финишем)
var off: Array = []         # начало участков на круге
var lap := 0.0              # длина круга
var centroid := Vector3.ZERO
var turn_track: Dictionary  # ровная трасса для физики поворотов


static func _head(phi: float) -> Vector3:
	return Vector3(cos(phi), 0, -sin(phi))


static func _norm(phi: float) -> Vector3:          # наружу кольца (справа по ходу)
	return Vector3(sin(phi), 0, cos(phi))


func _init(def_: Dictionary) -> void:
	def = def_
	var sts: Array = def["straights"]
	var ns := sts.size()
	var bases: Array = []
	var lens: Array = []
	for st in sts:
		var t: Dictionary = MR.make_straight(st["seed"], st["baths"])
		bases.append(t)
		lens.append(float(t["finish"]) + 6.0 - XS)
	# кольцо замыкается, если у правильной фигуры стороны равны, у прямоугольника — противоположные
	if ns == 4:
		var a := maxf(lens[0], lens[2])
		var b := maxf(lens[1], lens[3])
		lens = [a, b, a, b]
	else:
		var m: float = lens.max()
		for i in ns:
			lens[i] = m
	var R: float = def["R"]
	var ang := TAU / ns
	var phi := 0.0
	var p := Vector3(XS, 0, 0)
	for i in ns:
		var rt: Dictionary = bases[i].duplicate()
		rt["finish"] = 1e9                                  # финиш ведёт race.gd, а не ядро
		segs.append({"turn": false, "len": lens[i], "xe": XS + lens[i], "p0": p, "phi": phi, "track": rt, "base": bases[i]})
		p = p + _head(phi) * lens[i]
		var c := p - _norm(phi) * R
		segs.append({"turn": true, "len": R * ang, "p0": p, "phi": phi, "R": R, "c": c})
		phi += ang
		p = c + _norm(phi) * R
	var acc := 0.0
	for sg in segs:
		off.append(acc)
		acc += sg["len"]
	lap = acc
	var n := int(ceil((R * ang + 40.0 - MR.X0) / MR.STEP)) + 1
	var h := PackedFloat32Array()
	h.resize(n)
	var far := {"x0": 1e6, "x1": 1e6 + 1.0}
	turn_track = {"seed": 0, "baths": [far], "gaps": [], "finish": 1e9, "end": 1e9, "lanes": [{"h": h, "n": n}], "winches": [[]]}
	var sum := Vector3.ZERO
	var cnt := 0
	for row in samples(4.0, 2.0):
		sum += row[2]
		cnt += 1
	centroid = sum / maxf(1.0, cnt)


func count() -> int:
	return segs.size()


func is_turn(seg: int) -> bool:
	return segs[seg]["turn"]


## дорожка в трассе прямой (у каждой прямой она одна)
static func lane_of(_seg: int) -> int:
	return 0


func straights() -> Array:
	var out: Array = []
	for i in segs.size():
		if not segs[i]["turn"]:
			out.append(i)
	return out


## трасса прямой с настоящим финишем (ванны, стенки, высоты) — для рельефа, воды, столбиков
func seg_track(seg: int) -> Dictionary:
	return segs[seg]["base"]


func seg_start(seg: int) -> float:
	return 0.0 if segs[seg]["turn"] else XS


func seg_end(seg: int) -> float:
	return segs[seg]["len"] if segs[seg]["turn"] else segs[seg]["xe"]


func physics_track(seg: int) -> Dictionary:
	return turn_track if segs[seg]["turn"] else segs[seg]["track"]


func lap_pos(seg: int, x: float) -> float:
	return off[seg] + x - seg_start(seg)


## положение на круге → [участок, x]
func locate(s: float) -> Array:
	s = fposmod(s, lap)
	for seg in range(segs.size() - 1, -1, -1):
		if s >= off[seg]:
			return [seg, seg_start(seg) + s - off[seg]]
	return [0, XS]


## [точка оси колеи на высоте 0, касательная, наружная нормаль]
func frame(seg: int, x: float) -> Array:
	var sg: Dictionary = segs[seg]
	if sg["turn"]:
		var ph: float = sg["phi"] + x / sg["R"]
		return [(sg["c"] as Vector3) + _norm(ph) * sg["R"], _head(ph), _norm(ph)]
	return [(sg["p0"] as Vector3) + _head(sg["phi"]) * (x - XS), _head(sg["phi"]), _norm(sg["phi"])]


func frame_at(s: float) -> Array:
	var lx := locate(s)
	return frame(lx[0], lx[1])


func world(seg: int, x: float, y: float, dz: float) -> Vector3:
	var f := frame(seg, x)
	return (f[0] as Vector3) + (f[2] as Vector3) * dz + Vector3(0, y, 0)


static func yaw_of(t: Vector3) -> float:
	return atan2(-t.z, t.x)


func ground_y(seg: int, x: float) -> float:
	return 0.0 if segs[seg]["turn"] else MR.ground_at(segs[seg]["base"], 0, x)


## профиль поперёк колеи: высоты в точках ZS
func profile(seg: int, x: float) -> Array:
	var sg: Dictionary = segs[seg]
	if sg["turn"]:
		var k := smoothstep(0.0, 10.0, x) * smoothstep(sg["len"], sg["len"] - 10.0, x)
		return [-0.04, 0.0, 0.0, 0.0, BERM * k, -0.04]
	var tr: Dictionary = sg["base"]
	var h := MR.h_at(tr["lanes"][0], x)
	var b := h
	if MR.bath_at(tr, x) >= 0:
		b = maxf(h, 0.0) + 0.16
	return [-0.04, b, h, h, b, -0.04]


func surface_y(seg: int, x: float, dz: float) -> float:
	if dz <= -EDGE or dz >= EDGE:
		return -0.04
	var p := profile(seg, x)
	for j in ZS.size() - 1:
		var z0: float = ZS[j]
		var z1: float = ZS[j + 1]
		if dz >= z0 and dz <= z1:
			return lerpf(p[j], p[j + 1], (dz - z0) / (z1 - z0))
	return -0.04


## отсчёты вдоль круга: [участок, x, точка, касательная, нормаль]
func samples(step_straight: float, step_turn: float) -> Array:
	var out: Array = []
	for seg in segs.size():
		var x0 := seg_start(seg)
		var x1 := seg_end(seg)
		var st := step_turn if is_turn(seg) else step_straight
		var n := maxi(1, int(ceil((x1 - x0) / st)))
		for i in n:
			var x := x0 + (x1 - x0) * i / n
			var f := frame(seg, x)
			out.append([seg, x, f[0], f[1], f[2]])
	return out


## контур трассы в плане (x, z) — для схемы на экране выбора
func outline(step := 3.0) -> PackedVector2Array:
	var out := PackedVector2Array()
	for row in samples(step, step):
		var p: Vector3 = row[2]
		out.append(Vector2(p.x, p.z))
	return out


## точка внутри кольца дальше d от оси колеи (для поля, шатров, деревьев): контур трассы, сжатый внутрь на d
## (встроенными функциями Godot — быстро даже для тысяч точек)
var _inner := {}


func inside(p: Vector3, d: float) -> bool:
	if not _inner.has(d):
		var res := Geometry2D.offset_polygon(outline(2.0), -d)
		_inner[d] = res[0] if res.size() > 0 else PackedVector2Array()
	var poly: PackedVector2Array = _inner[d]
	return poly.size() > 2 and Geometry2D.is_point_in_polygon(Vector2(p.x, p.z), poly)


## центры поворотов (внутри кольца) — для деревьев в «углах»
func turn_centers() -> Array:
	var out: Array = []
	for sg in segs:
		if sg["turn"]:
			out.append([sg["c"], sg["R"]])
	return out

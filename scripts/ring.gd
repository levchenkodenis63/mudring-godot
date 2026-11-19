extends RefCounted
## Кольцо-«стадион»: прямая 0 (вдоль +X, снаружи кольца — +Z) → поворот A → прямая 1 (обратно, вдоль −X)
## → поворот B → снова прямая 0. Ванны и стенки с лебёдкой — на прямых (верхняя/нижняя дорожки трассы core.gd),
## повороты — ровная грязь с ограничением скорости.
##
## Физика (core.gd) считает одну координату x вдоль участка. Здесь — перевод «участок + x» в 3D-точку,
## направление и наружную нормаль; положение на круге; профиль колеи поперёк для рельефа.
## Камера стоит снаружи кольца, поэтому на экране квадроцикл всегда едет слева направо.

const MR = preload("res://scripts/core.gd")

const R := 16.0             # радиус поворотов, м (между осями прямых — 2R)
const XS := -12.0           # начало прямой по физике: за стартовой линией помещается сетка из 5 квадроциклов
const VTURN := 9.0          # предел скорости в повороте, м/с (~32 км/ч)
const HALF := 1.6           # полуширина колеи
const BANK := 2.8           # бровка
const EDGE := 3.2           # край насыпи
const ZS := [-EDGE, -BANK, -HALF, HALF, BANK, EDGE]   # профиль поперёк: минус — внутрь кольца, плюс — наружу
const BERM := 0.35          # внешняя бровка в повороте приподнята

var track: Dictionary       # трасса core.gd (две прямые)
var ring_track: Dictionary  # она же для физики на кольце: финиш не срабатывает, заезд ведёт race.gd
var turn_track: Dictionary  # ровная трасса для физики поворотов
var xe: float               # конец прямой по физике
var ls: float               # длина прямой
var lt: float               # длина поворота
var lap: float              # длина круга
var off: Array              # начало участков на круге


func _init(track_: Dictionary) -> void:
	track = track_
	xe = float(track["finish"]) + 6.0
	ls = xe - XS
	lt = PI * R
	off = [0.0, ls, ls + lt, 2.0 * ls + lt]
	lap = 2.0 * (ls + lt)
	ring_track = track.duplicate()
	ring_track["finish"] = 1e9
	var n := int(ceil((lt + 40.0 - MR.X0) / MR.STEP)) + 1
	var h := PackedFloat32Array()
	h.resize(n)
	var far := {"x0": 1e6, "x1": 1e6 + 1.0}
	turn_track = {"seed": 0, "baths": [far, far, far], "gaps": [], "finish": 1e9, "end": 1e9,
		"lanes": [{"h": h, "n": n}, {"h": h, "n": n}], "winches": [[], []]}


static func is_turn(seg: int) -> bool:
	return seg % 2 == 1


## дорожка трассы core.gd для прямой (0 — первая, 1 — вторая); для поворота — 0
static func lane_of(seg: int) -> int:
	return 1 if seg == 2 else 0


func seg_start(seg: int) -> float:
	return 0.0 if is_turn(seg) else XS


func seg_end(seg: int) -> float:
	return lt if is_turn(seg) else xe


func physics_track(seg: int) -> Dictionary:
	return turn_track if is_turn(seg) else ring_track


## положение на круге 0..lap
func lap_pos(seg: int, x: float) -> float:
	return off[seg] + x - seg_start(seg)


## положение на круге → [участок, x]
func locate(s: float) -> Array:
	s = fposmod(s, lap)
	for seg in [3, 2, 1, 0]:
		if s >= off[seg]:
			return [seg, seg_start(seg) + s - off[seg]]
	return [0, XS]


## [точка оси колеи на высоте 0, касательная, наружная нормаль]
func frame(seg: int, x: float) -> Array:
	match seg:
		0:
			return [Vector3(x, 0, R), Vector3(1, 0, 0), Vector3(0, 0, 1)]
		1:
			var th := PI / 2.0 - x / R
			return [Vector3(xe + R * cos(th), 0, R * sin(th)), Vector3(sin(th), 0, -cos(th)), Vector3(cos(th), 0, sin(th))]
		2:
			return [Vector3(XS + xe - x, 0, -R), Vector3(-1, 0, 0), Vector3(0, 0, -1)]
		_:
			var th := -PI / 2.0 - x / R
			return [Vector3(XS + R * cos(th), 0, R * sin(th)), Vector3(sin(th), 0, -cos(th)), Vector3(cos(th), 0, sin(th))]


func frame_at(s: float) -> Array:
	var lx := locate(s)
	return frame(lx[0], lx[1])


## точка в мире: участок, x, высота, смещение поперёк (плюс — наружу кольца)
func world(seg: int, x: float, y: float, dz: float) -> Vector3:
	var f := frame(seg, x)
	return (f[0] as Vector3) + (f[2] as Vector3) * dz + Vector3(0, y, 0)


## поворот вокруг вертикали, чтобы локальная +X смотрела по касательной
static func yaw_of(t: Vector3) -> float:
	return atan2(-t.z, t.x)


## высота земли на оси колеи (для камеры)
func ground_y(seg: int, x: float) -> float:
	return 0.0 if is_turn(seg) else MR.ground_at(track, lane_of(seg), x)


## профиль поперёк колеи: высоты в точках ZS
func profile(seg: int, x: float) -> Array:
	if is_turn(seg):
		var k := smoothstep(0.0, 10.0, x) * smoothstep(lt, lt - 10.0, x)
		return [-0.04, 0.0, 0.0, 0.0, BERM * k, -0.04]
	var l := lane_of(seg)
	var h := MR.h_at(track["lanes"][l], x)
	var b := h
	if MR.bath_at(track, x) >= 0:
		b = maxf(h, 0.0) + 0.16
	return [-0.04, b, h, h, b, -0.04]


## высота поверхности в точке со смещением поперёк dz (линейно по профилю; за краем — земля)
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


## отсчёты вдоль круга с шагом ~step: [участок, x, точка, касательная, нормаль]
func samples(step_straight: float, step_turn: float) -> Array:
	var out: Array = []
	for seg in 4:
		var x0 := seg_start(seg)
		var x1 := seg_end(seg)
		var st := step_turn if is_turn(seg) else step_straight
		var n := int(ceil((x1 - x0) / st))
		for i in n:
			var x := x0 + (x1 - x0) * i / n
			var f := frame(seg, x)
			out.append([seg, x, f[0], f[1], f[2]])
	return out

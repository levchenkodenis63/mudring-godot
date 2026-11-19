extends RefCounted
## MUD RING — ядро: трасса, физика, лебёдка, ИИ ботов.
## Начиналось как перенос ../mudring/src/core.js (веб-версия), дальше развивается самостоятельно:
## въезд в воду по скорости и газу, глиссер, плавность оборотов. Проверка — tests/smoke.sh.
## Без узлов сцены: работает и в headless-тестах.

# ---------- константы ----------
const DT := 1.0 / 120.0
const WATER := -0.22      # уровень воды относительно песка, м
const FLOAT := 1.0        # глубина, с которой квадроцикл всплывает, м
const STEP := 0.1
const X0 := -30.0
const START := -1.3       # центр квадроцикла на старте (линия старта x=0)
const PENALTY := 2.0      # штраф за фальстарт, с
const IDLE := 0.12
const WB := 1.45          # колёсная база
const WR := 0.44          # радиус колеса
const TLIMIT := 90.0
const RESTART := 0.8      # «Экстрим»: завести снова можно не раньше, с
const DROWN := 2.0        # «Экстрим»: мотор стоит в воде столько — тонет, с
const PASSES := [0, 1, 0, 1]   # кольцо: верхняя, нижняя, верхняя, нижняя (2 круга)
const WINCH_V := 1.0
const WINCH_REACH := 4.0
const WINCH_ZONE := [0.46, 0.74]
const WINCH_HEAT := 5.0
const ROLLBACK := 2.6
const BREAK_STALLS := 2

const ZW := {"easy": 0.08, "normal": 0.04, "hard": 0.0, "extreme": 0.0}
const TYRES := {
	"mudlite": {"id": "mudlite", "name": "MudLite", "zw": 0.05, "water": 0.92, "slope": 1.0, "winch": 1.0, "drive": 0, "err": 0.6},
	"assassinator": {"id": "assassinator", "name": "Assassinator", "zw": -0.04, "water": 1.08, "slope": 0.6, "winch": 1.15, "drive": 2, "err": 1.3},
}
const AI_WATER_ERR := 0.10
# въезд в воду — по скорости и газу
const VLAND := 18.5        # максимум на суше, м/с (≈67 км/ч)
const ALAND := 0.8         # разгон на суше: доля недостающей скорости в секунду (мягче — нужен длинный разгон)
const GLIDE_V := 13.9      # на газу от этой скорости (50 км/ч) — глиссер: только после длинного разгона
const GLIDE_MIN := 2.0     # длина глиссирования, м (растёт со скоростью до GLIDE_MAX)
const GLIDE_MAX := 3.5
const NOSE_V := 4.0        # бросил газ перед водой на такой скорости — «клюнул носом» (перелив)
const NO_TYRE := {"zw": 0.0, "water": 1.0, "slope": 1.0, "winch": 1.0, "drive": 0, "err": 1.0}

static func lerp_(a: float, b: float, t: float) -> float:
	return a + (b - a) * t


static func smooth(t: float) -> float:
	t = clampf(t, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


static func tyre_of(r) -> Dictionary:
	return r.tyre if r.tyre != null else NO_TYRE


static func zw_of(r) -> float:
	return r.zw + tyre_of(r)["zw"]


# ---------- ГСЧ mulberry32, бит в бит как в JS ----------
class Rng extends RefCounted:
	var a: int

	func _init(seed: int) -> void:
		a = seed & 0xFFFFFFFF

	## Math.imul: младшие 32 бита произведения (разбито на половины, чтобы не переполнить int64)
	static func imul(x: int, y: int) -> int:
		x &= 0xFFFFFFFF
		y &= 0xFFFFFFFF
		var lo := (x * (y & 0xFFFF)) & 0xFFFFFFFF
		var hi := ((x * (y >> 16)) & 0xFFFF) << 16
		return (lo + hi) & 0xFFFFFFFF

	func next() -> float:
		a = (a + 0x6D2B79F5) & 0xFFFFFFFF
		var t := imul(a ^ (a >> 15), 1 | a)
		t = ((t + imul(t ^ (t >> 7), 61 | t)) & 0xFFFFFFFF) ^ t
		return float((t ^ (t >> 14)) & 0xFFFFFFFF) / 4294967296.0


static func rng(seed: int) -> Rng:
	return Rng.new(seed)


static func _r(rnd: Rng, a: float, b: float) -> float:
	return a + (b - a) * rnd.next()


## Фишер — Йейтс, как MR.shuffle
static func shuffle(a: Array, rnd: Rng) -> Array:
	for i in range(a.size() - 1, 0, -1):
		var j := int(floor(rnd.next() * (i + 1)))
		var t = a[i]
		a[i] = a[j]
		a[j] = t
	return a


static func _near(used: Array, c: float, d: float) -> bool:
	for u in used:
		if absf(u - c) < d:
			return true
	return false


static func _gauss(x: float, c: float, s: float) -> float:
	var dx := x - c
	return exp(-(dx * dx) / (2.0 * s * s))


# ---------- трасса ----------
static func make_track(seed: int) -> Dictionary:
	var rnd := Rng.new(seed)
	var WALL := 1.7
	var TOP := 0.55
	var PLAT := 1.8
	var DOWN := 1.0
	var baths: Array = []
	var gaps: Array = []
	var x := 5.5
	for i in 3:
		var L := roundf(_r(rnd, 30, 36))
		baths.append({"x0": x, "x1": x + L})
		x += L
		if i < 2:
			var g := roundf(_r(rnd, 3, 5) * 2.0) / 2.0
			gaps.append({"x0": x, "x1": x + g})
			x += g
	var finish := x + 7.0
	var end_ := finish + 45.0
	var n := int(ceil((end_ - X0) / STEP)) + 1
	var lanes: Array = []
	var winches: Array = []
	for l in 2:
		# крутые выезды: 1–2 из трёх ванн на каждой дорожке
		var order := [0, 1, 2]
		for i in range(2, 0, -1):
			var j := int(floor(rnd.next() * (i + 1)))
			var t = order[i]
			order[i] = order[j]
			order[j] = t
		var steep: Array = order.slice(0, 1 if rnd.next() < 0.5 else 2)
		steep.sort()
		var feats: Array = []
		for b in baths:
			var f := {"b": b, "base": _r(rnd, 0.62, 0.82), "g": []}
			var np := 2 if rnd.next() < 0.55 else 1
			var used: Array = []
			for k in np:
				var c := 0.0
				var tries := 0
				while true:
					c = _r(rnd, b["x0"] + 7.0, b["x1"] - 8.0)
					tries += 1
					if not (_near(used, c, 7.0) and tries < 30):
						break
				used.append(c)
				var s := _r(rnd, 1.6, 2.8)
				var a := _r(rnd, 0.5, 0.75)
				f["g"].append({"c": c, "s": s, "a": a})          # яма
			var c2 := 0.0
			var tries2 := 0
			while true:
				c2 = _r(rnd, b["x0"] + 6.0, b["x1"] - 7.0)
				tries2 += 1
				if not (_near(used, c2, 6.0) and tries2 < 30):
					break
			var s2 := _r(rnd, 1.8, 3.0)
			var a2 := -_r(rnd, 0.3, 0.42)
			f["g"].append({"c": c2, "s": s2, "a": a2})            # отмель
			feats.append(f)
		var h := PackedFloat32Array()
		h.resize(n)
		for i in n:
			var xx := X0 + i * STEP
			var y := 0.0
			for f in feats:
				var b: Dictionary = f["b"]
				if xx > b["x0"] and xx < b["x1"]:
					var dpt: float = f["base"]
					for g in f["g"]:
						dpt += g["a"] * _gauss(xx, g["c"], g["s"])
					dpt = maxf(0.3, dpt)
					var env := minf(smooth((xx - b["x0"]) / 2.4), smooth((b["x1"] - xx) / 3.2))
					y = -dpt * env
			var on_wall := false
			for bi in steep:
				var b: Dictionary = baths[bi]
				var f: Dictionary = feats[bi]
				var w0: float = b["x1"] - WALL
				if xx < w0 - 0.6 or xx > b["x1"] + PLAT + DOWN:
					continue
				on_wall = true
				if xx < w0:
					y = minf(y, -f["base"] * 0.9)                                     # дно перед стенкой не мелеет
				elif xx < b["x1"]:
					y = lerp_(-f["base"], TOP, smooth((xx - w0) / WALL))             # крутой подъём
				elif xx < b["x1"] + PLAT:
					y = TOP                                                          # площадка со столбиком
				else:
					y = lerp_(TOP, 0.0, smooth((xx - b["x1"] - PLAT) / DOWN))        # спуск на песок
			for g in gaps:
				if on_wall:
					break
				var c: float = (g["x0"] + g["x1"]) / 2.0
				var s: float = (g["x1"] - g["x0"]) / 3.2
				y += 0.3 * _gauss(xx, c, s)
			var bx: float = baths[0]["x0"] - 1.1
			var dx := xx - bx
			y += 0.16 * exp(-(dx * dx) / (2.0 * 0.8 * 0.8))
			h[i] = y
		lanes.append({"h": h, "n": n})
		var ws: Array = []
		for bi in steep:
			var b: Dictionary = baths[bi]
			ws.append({"id": l * 3 + bi, "bath": bi, "x0": b["x1"] - WALL - 0.75, "x1": b["x1"] + 0.05, "post": b["x1"] + 1.65})
		winches.append(ws)
	return {"seed": seed, "baths": baths, "gaps": gaps, "finish": finish, "end": end_, "lanes": lanes, "winches": winches}


static func h_at(lane: Dictionary, x: float) -> float:
	var hh: PackedFloat32Array = lane["h"]
	var n: int = lane["n"]
	var f := (x - X0) / STEP
	var i := int(floor(f))
	if i < 0:
		return hh[0]
	if i >= n - 1:
		return hh[n - 1]
	var t := f - i
	return hh[i] * (1.0 - t) + hh[i + 1] * t


static func bath_at(track: Dictionary, x: float) -> int:
	for i in 3:
		var b: Dictionary = track["baths"][i]
		if x >= b["x0"] and x <= b["x1"]:
			return i
	return -1


static func depth_at(track: Dictionary, l: int, x: float) -> float:
	if bath_at(track, x) < 0:
		return 0.0
	return maxf(0.0, WATER - h_at(track["lanes"][l], x))


static func ground_at(track: Dictionary, l: int, x: float) -> float:
	var h := h_at(track["lanes"][l], x)
	if bath_at(track, x) < 0:
		return h
	return maxf(h, WATER - FLOAT)


static func next_bath_dist(track: Dictionary, x: float) -> float:
	for i in 3:
		var b: Dictionary = track["baths"][i]
		if b["x0"] >= x:
			return b["x0"] - x
	return 1e9


static func zone(d: float, w: float = 0.0) -> Array:
	if d <= 0.02:
		return [maxf(IDLE + 0.05, 0.55 - w), 1.0]
	return [maxf(IDLE + 0.05, lerp_(0.52, 0.36, d) - w), minf(1.0, lerp_(0.88, 0.60, d) + w)]


static func winch_zone(w: float = 0.0) -> Array:
	return [WINCH_ZONE[0] - w, minf(0.97, WINCH_ZONE[1] + w)]


# ---------- гонщик ----------
class Rider extends RefCounted:
	var x := -1.3
	var v := 0.0
	var y := 0.0
	var vy := 0.0
	var fly := false
	var air := false
	var rpm := 0.12
	var heat := 0.0
	var dig := 0.0
	var cut := 0.0
	var go := false
	var fin := false
	var time := 0.0
	var lo := 0.55
	var hi := 1.0
	var d := 0.0
	var depth := 0.0
	var spin := false
	var float_ := false
	var wheel := 0.0
	var pitch := 0.0
	var entered := [false, false, false]
	var ev: Array = []
	var top := 0.0
	var clean := 0
	var floods := 0
	var heats := 0
	var gas := false
	var extreme := false
	var dead := false
	var dead_t := 0.0
	var prev_gas := false
	var drowned := false
	var sink_t := 0.0
	var zw := 0.0
	var spot = null                  # ближайший выезд с лебёдкой (Dictionary) или null
	var cable := false
	var at_top := false
	var roll := 0.0
	var winch_stalls := 0
	var broken := false
	var done := {}
	var blocked := false
	var winches := 0
	var wstalls := 0
	var tyre = null                  # Dictionary из TYRES или null
	var water_stalls := 0
	var drive_out := false
	var rev := 1.0               # скорость набора/сброса оборотов (race.gd задаёт плавнее)
	var glide := 0.0             # осталось проскользить по воде, м
	var glides := 0

	## переход на следующий отрезок кольца
	func next_pass() -> void:
		fin = false
		x = -1.3
		entered = [false, false, false]
		done = {}
		cable = false
		at_top = false
		spot = null
		roll = 0.0


static func new_rider() -> Rider:
	return Rider.new()


static func step_rider(r: Rider, track: Dictionary, l: int, gas: bool, dt: float, t: float) -> void:
	# утонул: только медленно уходит под воду
	if r.drowned:
		r.sink_t += dt
		r.v = 0.0
		r.gas = false
		r.spin = false
		r.rpm = maxf(IDLE, r.rpm - dt)
		if r.sink_t < 2.5:
			r.y -= 0.45 * dt
		r.pitch += (0.18 - r.pitch) * minf(1.0, dt * 2.0)
		return
	# привод сломан: стоит в воде, мотор глохнет
	if r.drive_out:
		r.v = 0.0
		r.gas = false
		r.spin = false
		r.rpm = maxf(IDLE, r.rpm - dt)
		return
	var pressed := gas
	var fresh := pressed and not r.prev_gas
	r.prev_gas = pressed
	var depth := depth_at(track, l, r.x)
	var d := clampf(depth / FLOAT, 0.0, 1.0)
	r.d = d
	r.depth = depth
	r.float_ = depth > FLOAT
	if d <= 0.02 and not r.dead:
		r.water_stalls = 0
	var ty := tyre_of(r)
	if r.dead:
		# «Экстрим»: заглох в воде — завести можно только новым нажатием газа
		r.dead_t += dt
		r.cut = 1.0
		gas = false
		if r.dead_t >= RESTART and fresh:
			r.dead = false
			r.cut = 0.0
			r.ev.append({"t": "restart"})
		elif d > 0.02 and r.dead_t >= DROWN:
			r.dead = false
			r.cut = 0.0
			r.drowned = true
			r.sink_t = 0.0
			r.v = 0.0
			r.ev.append({"t": "drown"})
			return
		elif d <= 0.02 and r.dead_t >= 1.6:
			r.dead = false
			r.cut = 0.0
	elif r.cut > 0.0:
		r.cut -= dt
		gas = false
	if r.fin:
		gas = false
	r.gas = gas
	# ближайший ещё не пройденный выезд с лебёдкой
	var ws: Array = track["winches"][l]
	r.spot = null
	for sp in ws:
		if not r.done.has(sp["id"]) and r.x > sp["x0"] - 12.0 and r.x <= sp["x1"] + 0.01:
			r.spot = sp
			break
	if r.spot != null and r.cable and r.go:
		winch_step(r, track, l, gas, dt)
		return
	var z := zone(d, zw_of(r))
	var lo: float = z[0]
	var hi: float = z[1]
	r.lo = lo
	r.hi = hi

	if gas:
		r.rpm += (1.5 if r.air else 0.9) * dt * r.rev
	else:
		r.rpm -= 0.8 * dt * r.rev
	r.rpm = clampf(r.rpm, IDLE, 1.0)

	if not r.go:
		r.v = 0.0
		r.spin = false
		return

	if r.glide > 0.0:
		_glide_step(r, track, l, gas, dt, t)
		return

	var over := maxf(0.0, r.rpm - hi)
	var eff: float
	if r.rpm < lo:
		eff = 0.88 * clampf((r.rpm - IDLE) / (lo - IDLE), 0.0, 1.0)
	elif r.rpm <= hi:
		eff = 0.88 + 0.12 * (r.rpm - lo) / (hi - lo)
	else:
		eff = maxf(0.3, 1.0 - over * 4.5)

	var in_water := d > 0.02
	if not r.air:
		r.spin = over > 0.0
		if over > 0.0:
			if in_water:
				r.dig = minf(1.0, r.dig + over * 3.5 * dt)
			r.heat += (0.10 + over * 2.5) * dt
		else:
			r.dig = maxf(0.0, r.dig - 0.9 * dt)
			r.heat = maxf(0.0, r.heat - 0.11 * dt)
		if r.heat >= 1.0 and r.cut <= 0.0 and not r.dead and not r.fin:
			r.heat = 0.6
			r.heats += 1
			if r.extreme and in_water:
				r.dead = true
				r.dead_t = 0.0
				r.cut = 1.0
				r.water_stalls += 1
			else:
				r.cut = 1.6
			r.ev.append({"t": "overheat", "dead": r.dead, "n": r.water_stalls})
			if r.dead and ty["drive"] and r.water_stalls >= ty["drive"]:   # Assassinator: привод не выдержал
				r.dead = false
				r.drive_out = true
				r.v = 0.0
				r.ev.append({"t": "drive"})
				return
		var gF := ground_at(track, l, r.x + 0.6)
		var gR := ground_at(track, l, r.x - 0.6)
		var slope := (gF - gR) / 1.2
		var vmax: float = lerp_(10.5, 4.6, pow(d, 0.8)) * ty["water"] if in_water else VLAND
		if slope > 0.0:
			vmax *= 1.0 - 0.45 * ty["slope"] * minf(1.0, slope / 0.5)
		var vt := vmax * eff * (1.0 - 0.45 * r.dig)
		var a: float
		if vt > r.v:
			a = minf((vt - r.v) * (1.8 if in_water else ALAND), 5.5 if in_water else 6.0)
		else:
			a = (vt - r.v) * (1.0 + 1.8 * d if in_water else 0.45)
		if not r.float_:
			a -= 9.8 * slope / sqrt(1.0 + slope * slope) * 0.55
		if r.fin:
			a -= 7.0
		r.v += a * dt
		if gas and r.rpm > 0.3 and r.v < 0.9:
			r.v = 0.9
	else:
		r.spin = false
	if r.v < 0.0:
		r.v = 0.0
	if r.v > r.top:
		r.top = r.v

	# продольное и вертикальное движение
	r.x += r.v * dt
	if r.spot != null and not r.cable and r.x > r.spot["x0"]:   # крутой выезд: без лебёдки не подняться
		r.x = r.spot["x0"]
		if r.v > 0.5:
			r.ev.append({"t": "bump", "p": r.v})
		r.v = 0.0
		r.blocked = true
	elif r.spot == null:
		r.blocked = false
	var g2 := ground_at(track, l, r.x)
	if r.fly:
		r.vy -= 9.8 * dt
		r.y += r.vy * dt
		if r.y <= g2:
			var impact := -r.vy
			r.y = g2
			r.fly = false
			r.vy = 0.0
			if impact > 1.6:
				r.ev.append({"t": "land", "p": impact})
	else:
		var nvy := (g2 - r.y) / dt
		if nvy < r.vy - 9.8 * dt * 1.6 and r.v > 2.5:
			r.fly = true
			r.vy = minf(r.vy, 6.0) - 9.8 * dt
			r.y += r.vy * dt
			if r.y < g2:
				r.y = g2
				r.fly = false
				r.vy = nvy
		else:
			r.y = g2
			r.vy = clampf(nvy, -12.0, 12.0)
	r.air = r.fly and (r.y - g2 > 0.05)

	# вход в воду
	var bi := bath_at(track, r.x)
	if bi >= 0 and not r.entered[bi] and not r.air:
		var dep := depth_at(track, l, r.x)
		if dep > 0.1:
			r.entered[bi] = true
			var kind := _entry(r)
			r.ev.append({"t": "entry", "kind": kind, "p": r.v})

	# наклон корпуса и вращение колёс
	var pt: float
	if r.air:
		pt = clampf(r.vy * 0.05, -0.3, 0.22)
	else:
		pt = atan2(ground_at(track, l, r.x + WB / 2.0) - ground_at(track, l, r.x - WB / 2.0), WB)
	r.pitch += (pt - r.pitch) * minf(1.0, dt * 12.0)
	var wv := maxf(r.v, r.rpm * 22.0) if (r.spin or r.air) else r.v
	r.wheel += (wv / WR) * dt

	if not r.fin and r.x >= track["finish"]:
		r.fin = true
		r.time = t - (r.x - track["finish"]) / maxf(r.v, 0.5)


# ---------- въезд в воду и глиссер ----------
## на газу и быстро — глиссер; бросил газ на скорости — перелив; иначе — чисто / малым ходом
static func _entry(r: Rider) -> String:
	if r.gas and r.v >= GLIDE_V:
		r.glide = clampf(GLIDE_MIN + (r.v - GLIDE_V) / 3.0, GLIDE_MIN, GLIDE_MAX)
		r.glides += 1
		return "glide"
	if not r.gas and r.v >= NOSE_V:
		r.v *= 0.6
		r.heat = minf(0.97, r.heat + 0.15)
		r.floods += 1
		return "flood"
	if r.v < 3.0:
		r.v *= 0.9
		return "soft"
	r.v *= 0.94
	r.clean += 1
	return "clean"


## скольжение по поверхности: скорость почти держится на газу, без газа гаснет; потом — плюх на дно
static func _glide_step(r: Rider, track: Dictionary, l: int, gas: bool, dt: float, t: float) -> void:
	r.spin = false
	r.v = maxf(0.0, r.v - (0.7 if gas else 2.5) * dt)
	var dx := r.v * dt
	r.x += dx
	r.glide -= dx
	r.y = maxf(ground_at(track, l, r.x), WATER - 0.06)
	r.vy = 0.0
	r.fly = false
	r.air = false
	r.pitch += (0.07 - r.pitch) * minf(1.0, dt * 6.0)
	r.wheel += (maxf(r.v, r.rpm * 22.0) / WR) * dt
	if r.glide <= 0.0 or r.v < NOSE_V:
		r.glide = 0.0
		r.v *= 0.9
		r.fly = true                      # садится в воду и опускается на дно
		r.ev.append({"t": "glide_end"})
	if not r.fin and r.x >= track["finish"]:
		r.fin = true
		r.time = t - (r.x - track["finish"]) / maxf(r.v, 0.5)


# ---------- лебёдка ----------
static func winch_step(r: Rider, track: Dictionary, l: int, gas: bool, dt: float) -> void:
	var sp: Dictionary = r.spot
	var z := winch_zone(zw_of(r))
	var lo: float = z[0]
	var hi: float = z[1]
	var wv: float = WINCH_V * tyre_of(r)["winch"]
	r.lo = lo
	r.hi = hi
	if r.cut > 0.0 or r.at_top:
		gas = gas if r.at_top else false
	if r.cut > 0.0:
		r.cut -= dt
	r.gas = gas
	if gas:
		r.rpm += 0.9 * dt * r.rev
	else:
		r.rpm -= 0.8 * dt * r.rev
	r.rpm = clampf(r.rpm, IDLE, 1.0)
	r.d = clampf(depth_at(track, l, r.x) / FLOAT, 0.0, 1.0)
	r.depth = depth_at(track, l, r.x)
	var v := 0.0
	if r.at_top:
		v = 0.0
		r.heat = maxf(0.0, r.heat - 0.2 * dt)
	elif r.roll > 0.0:
		v = -3.2                                              # откат после заглохания
		if r.x <= r.roll:
			r.roll = 0.0
			v = 0.0
	elif r.cut > 0.0:
		v = 0.0
	else:
		var over := maxf(0.0, r.rpm - hi)
		if r.rpm < lo:
			v = WINCH_V * (0.75 * (r.rpm - IDLE) / (lo - IDLE) - 0.35)   # мало оборотов — сползает
		else:
			v = wv * (maxf(0.35, 1.0 - over * 3.0) if over > 0.0 else 1.0)
		if over > 0.0:
			r.heat += (0.35 + over * WINCH_HEAT) * dt
		else:
			r.heat = maxf(0.0, r.heat - 0.25 * dt)
		if r.heat >= 1.0:                                     # перекрутил — заглох, откат
			r.heat = 0.55
			r.cut = 1.6
			r.heats += 1
			r.wstalls += 1
			r.winch_stalls += 1
			r.roll = maxf(sp["x0"] - ROLLBACK, r.x - ROLLBACK)
			r.ev.append({"t": "winchstall", "n": r.winch_stalls})
			if r.extreme and r.winch_stalls >= BREAK_STALLS:
				r.broken = true
				r.ev.append({"t": "break"})
	r.v = maxf(0.0, v)
	r.x += v * dt
	if r.x >= sp["x1"] and not r.at_top:
		r.x = sp["x1"]
		r.at_top = true
		r.winch_stalls = 0
		r.ev.append({"t": "top"})
	r.spin = not r.at_top and gas and r.rpm > lo
	r.y = ground_at(track, l, r.x)
	r.vy = 0.0
	r.fly = false
	r.air = false
	var pt := atan2(ground_at(track, l, r.x + WB / 2.0) - ground_at(track, l, r.x - WB / 2.0), WB)
	r.pitch += (pt - r.pitch) * minf(1.0, dt * 10.0)
	r.wheel += (absf(v) / WR) * dt


## зацепить / отцепить трос. Возвращает: none, far, attach, busy, detach
static func winch_tap(r: Rider) -> String:
	var sp = r.spot
	if sp == null or r.fin or r.drowned or r.broken or r.drive_out:
		return "none"
	if not r.cable:
		if r.air or r.x < sp["x0"] - WINCH_REACH:
			return "far"
		r.cable = true
		r.at_top = false
		r.roll = 0.0
		r.winch_stalls = 0
		r.v = 0.0
		r.winches += 1
		return "attach"
	if not r.at_top:
		return "busy"
	r.cable = false
	r.at_top = false
	r.done[sp["id"]] = true
	r.spot = null
	r.v = 0.0
	r.blocked = false
	return "detach"


# ---------- соперники (ИИ) ----------
static func make_ai(skill: float, rnd: Rng, extreme: bool) -> Dictionary:
	var s := clampf(skill + (rnd.next() - 0.5) * 0.12, 0.05, 1.0)
	var ai := {"skill": s, "rnd": rnd, "pass": 0, "n": 0.0, "nT": 0.0, "nt": 0.0, "w": null, "stalls": 0, "wb": null}
	ai["react"] = 0.17 + rnd.next() * 0.42 * (1.25 - s)
	ai["aim"] = 0.42 + 0.42 * s
	ai["amp"] = 0.17 - 0.13 * s
	ai["fs"] = rnd.next() < 0.05 * (1.0 - s)
	ai["careful"] = rnd.next() < 0.35 + 0.6 * s
	ai["restartAt"] = RESTART + 0.1 + rnd.next() * 0.5
	ai["sink"] = null
	if extreme and rnd.next() < 0.06 * (1.15 - s):
		var p := int(floor(rnd.next() * 4))
		var b := int(floor(rnd.next() * 3))
		ai["sink"] = {"pass": p, "bath": b}
	return ai


## решение бота на кадр: {gas, tap}
static func ai_step(ai: Dictionary, r: Rider, track: Dictionary, t: float, dt: float) -> Dictionary:
	var rnd: Rng = ai["rnd"]
	var none := {"gas": false, "tap": false}
	if not r.go or t < (0.0 if ai["fs"] else ai["react"]):
		return none
	ai["nt"] -= dt
	if ai["nt"] <= 0.0:
		ai["nt"] = 0.25 + rnd.next() * 0.5
		ai["nT"] = (rnd.next() * 2.0 - 1.0) * ai["amp"]
	ai["n"] += (ai["nT"] - ai["n"]) * minf(1.0, dt * 6.0)
	var sink_now: bool = ai["sink"] != null and ai["sink"]["pass"] == ai["pass"]
	if r.dead:
		return {"gas": not sink_now and r.dead_t >= ai["restartAt"], "tap": false}
	var err: float = r.tyre["err"] if r.tyre != null else 1.0
	var bi := bath_at(track, r.x)
	var key: int = ai["pass"] * 3 + bi
	if bi >= 0 and r.tyre != null and (ai["wb"] == null or ai["wb"]["key"] != key):
		var mist := 0
		if rnd.next() < AI_WATER_ERR * (1.1 - ai["skill"]) * err:
			mist = 2 if rnd.next() < 0.35 else 1
		ai["wb"] = {"key": key, "mist": mist, "seen": r.water_stalls}
	var wb = ai["wb"] if (bi >= 0 and ai["wb"] != null and ai["wb"]["key"] == key) else null
	if wb != null and r.water_stalls != wb["seen"]:
		if r.water_stalls > wb["seen"] and wb["mist"] > 0:
			wb["mist"] -= 1
		wb["seen"] = r.water_stalls
	var sp = r.spot
	if sp != null and (r.cable or r.x >= sp["x0"] - 0.6):
		if ai["w"] == null or ai["w"]["id"] != sp["id"]:
			var mist := 0
			if rnd.next() < 0.25 * (1.1 - ai["skill"]) * err:
				mist = 2 if rnd.next() < 0.3 else 1
			var wait: float = 0.2 + rnd.next() * 0.6 * (1.2 - ai["skill"])
			var top: float = 0.25 + rnd.next() * 0.7 * (1.2 - ai["skill"])
			ai["w"] = {"id": sp["id"], "wait": wait, "mist": mist, "top": top}
		var w: Dictionary = ai["w"]
		if not r.cable:
			w["wait"] -= dt
			return {"gas": false, "tap": w["wait"] <= 0.0}
		if r.at_top:
			w["top"] -= dt
			return {"gas": false, "tap": w["top"] <= 0.0}
		if r.wstalls != ai["stalls"]:
			ai["stalls"] = r.wstalls
			if w["mist"] > 0:
				w["mist"] -= 1
		if r.cut > 0.0 or r.roll > 0.0:
			return none
		var target_w: float = 1.0 if w["mist"] > 0 else r.lo + (r.hi - r.lo) * ai["aim"] + ai["n"] * 0.6
		return {"gas": r.rpm < target_w, "tap": false}
	if sink_now and bi == ai["sink"]["bath"] and r.d > 0.3:
		return {"gas": true, "tap": false}
	if wb != null and wb["mist"] > 0 and r.d > 0.3 and r.cut <= 0.0:
		return {"gas": true, "tap": false}
	var target: float = r.lo + (r.hi - r.lo) * ai["aim"] + ai["n"]
	if sp != null and r.x > sp["x0"] - 3.0:
		target = minf(target, r.lo)
	var pending: bool = bi >= 0 and not r.entered[bi]           # уже над ванной, но въезд ещё не засчитан (мелко)
	if not r.cable and (r.d <= 0.02 or pending):
		# в воду — на газу (глиссер); неопытные иногда бросают газ перед водой
		var dist := 0.0 if pending else next_bath_dist(track, r.x)
		if dist < maxf(3.0, r.v * 0.5):
			var nb := bi if pending else bath_at(track, r.x + dist + 0.01)
			var pkey: int = ai["pass"] * 3 + nb
			if ai.get("pre") == null or ai["pre"]["key"] != pkey:
				ai["pre"] = {"key": pkey, "drop": rnd.next() < (0.06 if ai["careful"] else 0.35) * (1.1 - ai["skill"])}
			# ошибка «бросил газ» — только на скорости; встал — газует снова (иначе стоял бы перед водой вечно)
			target = IDLE if ai["pre"]["drop"] and r.v > NOSE_V else 1.01
	if r.air:
		target = minf(target, 0.7 if ai["careful"] else 0.95)
	return {"gas": r.rpm < target, "tap": false}

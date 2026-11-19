extends RefCounted
## Заезд: масстарт с ботами, 2 круга по кольцу (ring.gd), итоги. Логика из ../mudring/src/game.js,
## но вместо переноса между дорожками — непрерывное кольцо: прямая → поворот → прямая → поворот.
## Сцена читает состояние и забирает сообщения из msgs, эффекты из fx, звуки из sfx.

const MR = preload("res://scripts/core.gd")
const Ring = preload("res://scripts/ring.gd")
const Tracks = preload("res://scripts/tracks.gd")
const LAPS := 2
const REV := 0.7             # обороты набираются плавно (отзыв: газ был слишком чувствительный)

const SKILL := {"easy": [0.10, 0.40], "normal": [0.36, 0.72], "hard": [0.66, 1.0], "extreme": [0.66, 1.0]}
const DIFFNAME := {"easy": "Новички", "normal": "Любители", "hard": "Профи", "extreme": "Экстрим"}
const NAMES := ["Болотный", "Дизель", "Профессор", "Барс", "Механик", "Шторм", "Тапок", "Кувалда", "Вихрь", "Гряземес", "Сапёр", "Боцман"]
const BOTS := 5              # 6 участников
const GRID := 1.7
const TIME_LIMIT := 900.0
const FAILNAME := {"break": "ОБРЫВ ТРОСА", "drown": "УТОНУЛ", "drive": "ПРИВОД ВЫШЕЛ ИЗ ЧАТА", "time": "НЕ УЛОЖИЛСЯ В 15 МИНУТ"}

## menu → countdown → racing → final | fail
var screen := "menu"
var diff := "normal"
var tyre := "mudlite"
var track: Dictionary       # прямая 0 (стартовая) — для совместимости; трасса целиком — ring
var track_id := "oval"
var me                      # MR.Rider
var name := "ВЫ"
var bots: Array = []        # {r, ai, name, look, st, total, out, pen, slot}
var ring                    # Ring: геометрия кольца
var st := {}                # состояние игрока на кольце: {seg, laps, nst}
var lane := 0               # участок кольца текущей прямой (для лебёдки и столбиков)
var seg := 0                # участок кольца: 0, 2 — прямые, 1, 3 — повороты
var t := 0.0
var pre := 0.0
var lights := 0
var light_a := 0.0
var started := false
var pen := 0.0
var fs := false
var laps: Array = []
var ended := false
var end_t := 0.0
var fail_why := ""
var place := 0
var split = null
var grid_slot := 0
var _hud_t := 0.0           # места и отрыв пересчитываются 10 раз в секунду, а не на каждом шаге физики
var msgs: Array = []        # {text, color, big}
var fx: Array = []          # {kind: shake|burst|splat, p, type}
var sfx: Array = []         # [имя, параметр] — звуки для synth.gd


func is_extreme() -> bool:
	return diff == "extreme"


## track_id — id из tracks.gd или "random"
func setup(diff_: String, tyre_: String, track_id_: String = "random") -> void:
	diff = diff_
	tyre = tyre_
	track_id = track_id_
	if not track_id in Tracks.ids():
		track_id = Tracks.ids().pick_random()
	ring = Ring.new(Tracks.by_id(track_id))
	track = ring.seg_track(0)
	st = _new_st()
	seg = 0
	lane = 0
	laps = []
	fail_why = ""
	me = MR.new_rider()
	me.zw = MR.ZW[diff]
	me.rev = REV
	me.extreme = is_extreme()
	me.tyre = MR.TYRES[tyre] if is_extreme() else null
	# масстарт: BOTS + 1 квадроциклов сеткой за стартовой линией, место игрока — случайное
	var rnd = MR.rng(int(Time.get_unix_time_from_system() * 1000.0) % 1000000000)
	var sk: Array = SKILL[diff]
	var names: Array = MR.shuffle(NAMES.duplicate(), rnd)
	var slots: Array = []
	for i in BOTS + 1:
		slots.append(i)
	MR.shuffle(slots, rnd)
	grid_slot = slots[0]
	me.x = MR.START - slots[0] * GRID
	bots = []
	for i in BOTS:
		var br = MR.new_rider()
		br.extreme = is_extreme()
		br.rev = REV
		br.x = MR.START - slots[i + 1] * GRID
		var brnd = MR.rng(int(floor(rnd.next() * 1e9)) + i)
		if is_extreme():
			br.tyre = MR.TYRES["mudlite" if brnd.next() < 0.5 else "assassinator"]
		var ai: Dictionary = MR.make_ai(sk[0] + (sk[1] - sk[0]) * brnd.next(), brnd, is_extreme())
		bots.append({"r": br, "ai": ai, "name": names[i], "look": 1 + i, "st": _new_st(),
			"total": null, "out": "", "pen": 0.0, "slot": slots[i + 1]})
	place = 0
	split = null
	pen = 0.0
	fs = false
	t = 0.0
	pre = 0.0
	lights = 1
	light_a = 1.0
	started = false
	ended = false
	end_t = 0.0
	msgs.clear()
	fx.clear()
	sfx.clear()
	screen = "ready"


func begin_countdown() -> void:
	screen = "countdown"
	pre = 0.0
	lights = 1
	light_a = 1.0
	t = 0.0


func _start_race() -> void:
	started = true
	t = 0.0
	lights = 3
	sfx.append(["light", 3])
	me.go = true
	for b in bots:
		b["r"].go = true
		b["pen"] = MR.PENALTY if b["ai"]["fs"] else 0.0
	if fs:
		pen = MR.PENALTY
		msg("ФАЛЬСТАРТ +2.00", Color("#ff5a4a"), true)
		fx.append({"kind": "shake", "p": 0.6})
	screen = "racing"


func msg(text: String, color: Color, big: bool) -> void:
	msgs.append({"text": text, "color": color, "big": big})


## подсказка по лебёдке: что сейчас сделает тап
func winch_cue():
	var r = me
	if r == null or r.spot == null or screen != "racing":
		return null
	var sp: Dictionary = r.spot
	if not r.cable and r.x >= sp["x0"] - MR.WINCH_REACH:
		return {"lane": lane, "id": sp["id"], "mode": "attach", "sp": sp}
	if r.cable and r.at_top:
		return {"lane": lane, "id": sp["id"], "mode": "detach", "sp": sp}
	return null


## как в жизни: к лебёдке — только отпустив газ
func winch_action(gas := false) -> void:
	if me == null or screen != "racing" or ended:
		return
	if gas and winch_cue() != null:
		msg("Отпусти газ", Color("#ffd23e"), false)
		return
	var res: String = MR.winch_tap(me)
	if res == "attach":
		sfx.append(["clean", 0])
		msg("ТРОС ЗАЦЕПЛЕН", Color("#7dffa8"), false)
	elif res == "detach":
		sfx.append(["ui", 0])
		msg("ТРОС ОТЦЕПЛЕН — ВПЕРЁД!", Color("#7dffa8"), false)
	elif res == "far":
		msg("Подъедь ближе к стенке", Color("#ffd23e"), false)
	elif res == "busy":
		msg("Сначала вытяни наверх", Color("#ffd23e"), false)


func _handle_events(r) -> void:
	for ev in r.ev:
		var k: String = ev["t"]
		if k == "entry":
			if ev["kind"] == "glide":
				msg("ГЛИССЕР!", Color("#7dffa8"), false)
				fx.append({"kind": "burst", "type": "light", "p": 20})
			elif ev["kind"] == "clean":
				sfx.append(["clean", 0])
				msg("ЧИСТО!", Color("#7dffa8"), false)
				fx.append({"kind": "burst", "type": "light", "p": 16})
			elif ev["kind"] == "flood":
				sfx.append(["flood", 0])
				msg("Бросил газ", Color("#ff7a5a"), false)
				fx.append({"kind": "shake", "p": 0.45})
				fx.append({"kind": "burst", "type": "mud", "p": 26})
				fx.append({"kind": "splat"})
			else:
				sfx.append(["splash", ev["p"]])
				msg("малым ходом", Color("#ffd23e"), false)
				fx.append({"kind": "burst", "type": "light", "p": 8})
		elif k == "overheat":
			sfx.append(["overheat", 0])
			var last: bool = ev["dead"] and r.tyre != null and r.tyre["drive"] > 0 and ev["n"] == r.tyre["drive"] - 1
			msg("ЗАГЛОХ! Ещё раз в воде — привод не выдержит" if last else ("ЗАГЛОХ! Отпусти газ и жми снова" if ev["dead"] else "ЗАГЛОХ! −1.6 с"), Color("#ff5a4a"), false)
			fx.append({"kind": "shake", "p": 0.55})
			fx.append({"kind": "splat"})
		elif k == "restart":
			msg("ЗАВЁЛСЯ!", Color("#7dffa8"), false)
		elif k == "drown":
			sfx.append(["flood", 0])
			msg("УТОНУЛ", Color("#ff5a4a"), true)
			fx.append({"kind": "shake", "p": 0.8})
			fx.append({"kind": "burst", "type": "mud", "p": 30})
		elif k == "bump":
			sfx.append(["bump", ev["p"]])
			msg("Крутой выезд — нужна лебёдка!", Color("#ffd23e"), false)
			fx.append({"kind": "shake", "p": 0.35})
			fx.append({"kind": "burst", "type": "mud", "p": 12})
		elif k == "winchstall":
			sfx.append(["overheat", 0])
			msg("ЗАГЛОХ НА ЛЕБЁДКЕ! Ещё раз — обрыв троса" if is_extreme() and ev["n"] == 1 else "ЗАГЛОХ НА ЛЕБЁДКЕ — откат", Color("#ff5a4a"), false)
			fx.append({"kind": "shake", "p": 0.5})
			fx.append({"kind": "burst", "type": "mud", "p": 14})
		elif k == "break":
			sfx.append(["snap", 0])
			sfx.append(["flood", 0])
			msg("ОБРЫВ ТРОСА!", Color("#ff5a4a"), true)
			fx.append({"kind": "shake", "p": 1.0})
		elif k == "drive":
			sfx.append(["flood", 0])
			sfx.append(["overheat", 0])
			msg("ПРИВОД ВЫШЕЛ ИЗ ЧАТА", Color("#ff5a4a"), true)
			fx.append({"kind": "shake", "p": 1.0})
		elif k == "top":
			sfx.append(["ui", 0])
			msg("НАВЕРХУ! Отцепи трос", Color("#7dffa8"), false)
		elif k == "land":
			sfx.append(["land", ev["p"]])
			fx.append({"kind": "burst", "type": "light", "p": 8})
	r.ev.clear()


static func _new_st() -> Dictionary:
	return {"seg": 0, "laps": 0, "nst": 0}


## пройденная дистанция от стартовой линии (прямая 0, x = 0)
func progress(s: Dictionary, r) -> float:
	return s["laps"] * ring.lap + ring.lap_pos(s["seg"], r.x) - ring.lap_pos(0, 0.0)


## шаг гонщика по кольцу: физика участка + переход на следующий участок без переноса
func _step(r, s: Dictionary, gas: bool, dt: float, tt: float) -> void:
	var sg: int = s["seg"]
	MR.step_rider(r, ring.physics_track(sg), Ring.lane_of(sg), gas, dt, tt)
	if ring.is_turn(sg) and r.v > Ring.VTURN:
		r.v -= (r.v - Ring.VTURN) * minf(1.0, dt * 3.0)     # в повороте не разогнаться
	var end: float = ring.seg_end(sg)
	if r.x >= end:
		var carry: float = r.x - end
		sg = (sg + 1) % ring.count()
		if sg == 0:
			s["laps"] += 1
		s["seg"] = sg
		r.x = ring.seg_start(sg) + carry
		r.entered = [false, false, false, false, false, false, false, false]
		r.done = {}
		r.cable = false
		r.at_top = false
		r.spot = null
		r.roll = 0.0
		r.blocked = false
		if not ring.is_turn(sg):
			s["nst"] += 1


## финиш: прошёл LAPS кругов от стартовой линии — время с поправкой на перелёт за линию
func _check_finish(r, s: Dictionary, tt: float) -> bool:
	if r.fin:
		return false
	var over: float = progress(s, r) - LAPS * ring.lap
	if over < 0.0:
		return false
	r.fin = true
	r.time = tt - over / maxf(r.v, 0.5)
	return true


func lap_num() -> int:
	return clampi(int(floor(maxf(0.0, progress(st, me)) / ring.lap)) + 1, 1, LAPS)


func _step_bot(b: Dictionary, dt: float, tt: float) -> void:
	var r = b["r"]
	if b["total"] != null or b["out"] != "":
		return
	var s: Dictionary = b["st"]
	b["ai"]["pass"] = s["nst"]
	var a: Dictionary = MR.ai_step(b["ai"], r, ring.physics_track(s["seg"]), tt, dt)
	if a["tap"]:
		MR.winch_tap(r)
	_step(r, s, a["gas"], dt, tt)
	for ev in r.ev:
		var k: String = ev["t"]
		if (k == "break" or k == "drown" or k == "drive") and b["out"] == "":
			b["out"] = "обрыв троса" if k == "break" else ("привод вышел из чата" if k == "drive" else "утонул")
			if screen == "racing" and not ended:
				msg(b["name"] + ": " + b["out"], Color("#ffd23e"), false)
	r.ev.clear()
	if _check_finish(r, s, tt):
		b["total"] = r.time + b["pen"]
	if b["out"] == "" and b["total"] == null and tt > TIME_LIMIT:
		b["out"] = "не уложился"


## игрок финишировал — оставшиеся доезжают «за кадром»
func _finish_bots() -> void:
	var tt := t
	while tt < TIME_LIMIT + 1.0:
		var any := false
		for b in bots:
			if b["total"] == null and b["out"] == "":
				any = true
		if not any:
			break
		tt += MR.DT
		for b in bots:
			_step_bot(b, MR.DT, tt)


## места: финишировавшие по времени, остальные по дистанции, сошедшие в конце
func standings() -> Array:
	var all: Array = [{"me": true, "name": name, "total": (me.time + pen) if ended and fail_why == "" else null,
		"out": "сошёл" if fail_why != "" else "", "prog": progress(st, me), "look": 0}]
	for b in bots:
		all.append({"me": false, "name": b["name"], "total": b["total"], "out": b["out"], "prog": progress(b["st"], b["r"]), "look": b["look"]})
	all.sort_custom(func(a, b): return _key(a) < _key(b))
	return all


func _key(e: Dictionary) -> float:
	if e["out"] != "":
		return 3e6 - e["prog"]
	if e["total"] != null:
		return e["total"]
	return 1e6 - e["prog"]


func _live_hud() -> void:
	var st := standings()
	var i := 0
	for k in st.size():
		if st[k]["me"]:
			i = k
	place = i + 1
	var mine: float = st[i]["prog"]
	var ahead = null
	for k in range(i - 1, -1, -1):
		if st[k]["out"] == "" and st[k]["total"] == null:
			ahead = st[k]
			break
	var behind = null
	for k in range(i + 1, st.size()):
		if st[k]["out"] == "":
			behind = st[k]
			break
	split = (ahead["prog"] - mine) if ahead != null else ((-(mine - behind["prog"])) if behind != null else null)


## пересечение стартовой линии: круг пройден / финиш
func _lap_check(r) -> void:
	if r.fin:
		laps.append(r.time - _sum(laps))
		ended = true
		end_t = 0.0
		sfx.append(["finish", 0])
		msg("ФИНИШ " + ("%.2f" % (r.time + pen)), Color("#7dffa8"), true)
		return
	var p := progress(st, r)
	if p >= (laps.size() + 1) * ring.lap:
		laps.append(t - (p - (laps.size() + 1) * ring.lap) / maxf(r.v, 0.5) - _sum(laps))
		sfx.append(["light", 2])
		msg("КРУГ %d" % (laps.size() + 1), Color.WHITE, true)


static func _sum(a: Array) -> float:
	var x := 0.0
	for v in a:
		x += v
	return x


func update(dt: float, gas: bool) -> void:
	var r = me
	if screen == "countdown":
		pre += dt
		var lv := 1 if pre < 0.9 else (2 if pre < 1.9 else 3)
		if lv != lights:
			lights = lv
			if lv < 3:
				sfx.append(["light", lv])
		if gas and not started and pre > 0.35:
			fs = true
		if pre >= 1.9:
			_start_race()
		_step(r, st, gas, dt, 0.0)
		r.ev.clear()
		for b in bots:
			_step(b["r"], b["st"], false, dt, 0.0)
			b["r"].ev.clear()
	elif screen == "racing":
		if not ended:
			t += dt
		_step(r, st, gas, dt, t)
		seg = st["seg"]
		lane = seg
		_handle_events(r)
		if not ended:
			for b in bots:
				_step_bot(b, dt, t)
		if not ended:
			_check_finish(r, st, t)
			_lap_check(r)
		_hud_t -= dt
		if not ended and _hud_t <= 0.0:
			_hud_t = 0.1
			_live_hud()
		if light_a > 0.0:
			light_a = maxf(0.0, light_a - dt * 0.7)
		if not ended and (r.broken or r.drowned or r.drive_out or t > TIME_LIMIT):
			ended = true
			end_t = 0.0
			fail_why = "break" if r.broken else ("drown" if r.drowned else ("drive" if r.drive_out else "time"))
		if ended:
			end_t += dt
			if end_t > (1.8 if fail_why != "" else 1.4):
				if fail_why != "":
					screen = "fail"
				else:
					_finish_bots()
					screen = "final"

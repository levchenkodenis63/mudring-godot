extends RefCounted
## Процедурный звук без файлов (развитие ../mudring/src/sound.js): синтез по сэмплам.
## Мотор игрока — одноцилиндровый: вспышка на каждом такте + пила + хрип под нагрузкой, фильтр открывается
## с оборотами и глохнет в воде; выше зелёной зоны — отсечка. Плюс мотор ближайшего бота, бульканье в воде,
## вой лебёдки и разовые эффекты (всплеск, перелив, заглох, светофор, финиш...).
## Без узлов: render(n) отдаёт кадры — так звук можно проверить headless и записать в WAV (tests/sound_dump.gd).

const RATE := 22050.0
const TAU_R := TAU / RATE

# ---- состояние, которое задаёт игра каждый кадр ----
var active := false        # идёт заезд (в меню мотор молчит)
var running := true        # мотор работает (false — заглох / утонул / привод)
var rpm := 0.12
var load := false          # газ нажат
var water := false
var over := false          # обороты выше зелёной зоны — отсечка
var winch := 0.0           # 0..1 — лебёдка тянет
var bot_rpm := 0.12
var bot_gain := 0.0        # громкость ближайшего бота (0 — далеко)
var muted := false
var gurgle := false         # бульканье в воде (выключено: в игре только мотор и лебёдка)
var master := 3.6

# ---- внутреннее ----
var _f := 40.0
var _g := 0.0
var _cut := 600.0
var _bf := 40.0
var _bg := 0.0
var _wg := 0.0
var _wf := 520.0
var _gurg := 0.0
var _ph := 0.0
var _bph := 0.0
var _wph := 0.0
var _lp := 0.0
var _lp2 := 0.0
var _blp := 0.0
var _glp := 0.0
var _gamp := 0.0
var _t := 0.0
var _voices: Array = []


static func _alpha(fc: float) -> float:
	return clampf(1.0 - exp(-TAU_R * fc), 0.0, 1.0)


func render(n: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(n)
	if n <= 0:
		return out
	var dt := n / RATE
	var on := active and not muted
	# цели на блок; внутри блока — линейно, чтобы не было щелчков
	var tf := (36.0 + rpm * 140.0) if running else 18.0
	var tg := 0.0
	if on and running:
		tg = 0.15 if load else 0.06
	var tcut := 240.0 + rpm * 1500.0 - (170.0 if water else 0.0)
	var k := 1.0 - exp(-dt / 0.05)
	var f0 := _f
	var g0 := _g
	_f += (tf - _f) * k
	_g += (tg - _g) * (1.0 - exp(-dt / (0.04 if tg > _g else 0.09)))
	_cut += (tcut - _cut) * (1.0 - exp(-dt / 0.07))
	var df := (_f - f0) / n
	var dg := (_g - g0) / n
	var a_eng := _alpha(_cut)
	# бот
	var bg0 := _bg
	var bf0 := _bf
	_bf += ((36.0 + bot_rpm * 140.0) * 0.985 - _bf) * k
	_bg += ((bot_gain if on else 0.0) - _bg) * (1.0 - exp(-dt / 0.15))
	var dbf := (_bf - bf0) / n
	var dbg := (_bg - bg0) / n
	var a_bot := _alpha(300.0 + bot_rpm * 900.0)
	# лебёдка
	var wg0 := _wg
	_wg += ((0.05 * winch if on else 0.0) - _wg) * (1.0 - exp(-dt / 0.08))
	var dwg := (_wg - wg0) / n
	_wf += ((480.0 + winch * 420.0) - _wf) * k
	# бульканье
	_gurg += (((0.35 + (0.4 if load else 0.0)) if (on and water and running and gurgle) else 0.0) - _gurg) * (1.0 - exp(-dt / 0.2))
	var bubble_p := 28.0 / RATE
	var lim := over and running and load
	var f := f0
	var g := g0
	var bf := bf0
	var bgv := bg0
	var wg := wg0
	var noise_amt := 0.22 + (0.3 if load else 0.0)
	for i in n:
		f += df
		g += dg
		bf += dbf
		bgv += dbg
		wg += dwg
		_t += 1.0 / RATE
		var s := 0.0
		# --- мотор игрока ---
		if g > 0.0005:
			_ph += f / RATE
			if _ph >= 1.0:
				_ph -= 1.0
			var q := 1.0 - _ph
			var q2 := q * q
			var q4 := q2 * q2
			var pulse := q4 * q4 * 2.0 - 0.4          # вспышка в цилиндре
			var nz := randf() * 2.0 - 1.0
			var x := pulse * 0.7 + (2.0 * _ph - 1.0) * 0.35 + nz * noise_amt * q4 * q
			_lp += a_eng * (x - _lp)
			_lp2 += a_eng * (_lp - _lp2)
			var gate := 1.0
			if lim:                                     # отсечка: «ба-ба-ба»
				gate = 1.0 if fmod(_t * 13.0, 1.0) < 0.55 else 0.2
			s += _lp2 * g * gate
		# --- ближайший бот ---
		if bgv > 0.0005:
			_bph += bf / RATE
			if _bph >= 1.0:
				_bph -= 1.0
			var bq := 1.0 - _bph
			var bq2 := bq * bq
			var bx := bq2 * bq2 * 1.6 - 0.35 + (2.0 * _bph - 1.0) * 0.3
			_blp += a_bot * (bx - _blp)
			s += _blp * bgv
		# --- бульканье в воде ---
		if _gurg > 0.001:
			if randf() < bubble_p:
				_gamp = randf() * _gurg
			_gamp *= 0.9992
			_glp += 0.05 * ((randf() * 2.0 - 1.0) - _glp)
			s += _glp * _gamp * 0.9
		# --- лебёдка: вой электромотора ---
		if wg > 0.0005:
			_wph += (_wf + sin(_t * 31.0) * 12.0) / RATE
			if _wph >= 1.0:
				_wph -= 1.0
			s += (sin(TAU * _wph) * 0.7 + (2.0 * _wph - 1.0) * 0.3) * wg
		out[i] = Vector2(s, s)
	# --- разовые эффекты ---
	if not muted:
		for v in _voices:
			_render_voice(v, out, n)
	_voices = _voices.filter(func(v): return v["left"] > 0)
	# громкость и мягкое ограничение
	for i in n:
		var y := out[i].x * master
		y = y / (1.0 + absf(y))
		out[i] = Vector2(y, y)
	return out


func _render_voice(v: Dictionary, out: PackedVector2Array, n: int) -> void:
	var start := 0
	if v["delay"] > 0:
		start = mini(n, v["delay"])
		v["delay"] -= start
		if start >= n:
			return
	var f: float = v["f"]
	var fr: float = v["fr"]
	var env: float = v["env"]
	var att: int = v["att"]
	var dec: float = v["dec"]
	var gain: float = v["gain"]
	var lp: float = v["lp"]
	var lp2: float = v["lp2"]
	var ph: float = v["ph"]
	var kind: String = v["kind"]
	var left: int = v["left"]
	for i in range(start, n):
		if left <= 0:
			break
		left -= 1
		if att > 0:
			att -= 1
			env = minf(1.0, env + 1.0 / 330.0)
		else:
			env *= dec
		f *= fr
		var s := 0.0
		if kind == "band" or kind == "low":
			var nz := randf() * 2.0 - 1.0
			var a := minf(1.0, TAU_R * f)
			lp += a * (nz - lp)
			if kind == "band":
				lp2 += (a * 0.45) * (lp - lp2)
				s = (lp - lp2) * 2.2
			else:
				s = lp * 1.4
		else:
			ph += f / RATE
			if ph >= 1.0:
				ph -= 1.0
			if kind == "square":
				s = 1.0 if ph < 0.5 else -1.0
			elif kind == "triangle":
				s = 4.0 * absf(ph - 0.5) - 1.0
			else:
				s = 2.0 * ph - 1.0
		var y := s * env * gain
		out[i] = Vector2(out[i].x + y, out[i].y + y)
	v["f"] = f
	v["env"] = env
	v["att"] = att
	v["lp"] = lp
	v["lp2"] = lp2
	v["ph"] = ph
	v["left"] = left


## разовый звук: kind — band|low (шум через фильтр) или square|triangle|saw (тон)
func _voice(kind: String, dur: float, f0: float, f1: float, gain: float, delay := 0.0) -> void:
	if muted:
		return
	var samples := maxi(1, int(dur * RATE))
	_voices.append({
		"kind": kind, "f": f0, "fr": pow(maxf(f1, 40.0) / f0, 1.0 / samples), "env": 0.0, "att": int(0.015 * RATE),
		"dec": pow(0.0001, 1.0 / samples), "gain": gain, "lp": 0.0, "lp2": 0.0, "ph": 0.0,
		"left": samples + int(0.015 * RATE), "delay": int(delay * RATE)})


# ---- эффекты, как в sound.js ----
func splash(p: float) -> void:
	_voice("band", 0.35 + p * 0.02, 1400, 260, minf(0.32, 0.1 + p * 0.015))


func flood() -> void:
	_voice("low", 0.5, 700, 160, 0.4)


func clean() -> void:
	_voice("triangle", 0.09, 880, 880, 0.08)
	_voice("triangle", 0.12, 1320, 1320, 0.06, 0.03)


func overheat() -> void:
	_voice("low", 0.6, 500, 90, 0.36)
	_voice("saw", 0.25, 120, 70, 0.08)


func light(n: int) -> void:
	_voice("square", 0.22 if n == 3 else 0.1, 900 if n == 3 else 520, 900 if n == 3 else 520, 0.1)


func finish() -> void:
	_voice("square", 0.1, 660, 660, 0.09)
	_voice("square", 0.18, 990, 990, 0.09, 0.11)


func ui() -> void:
	_voice("triangle", 0.06, 440, 440, 0.06)


## новые: удар о стенку, приземление, обрыв троса
func bump(p: float) -> void:
	_voice("low", 0.25, 260, 60, minf(0.45, 0.2 + p * 0.05))


func land(p: float) -> void:
	_voice("low", 0.18, 320, 80, minf(0.35, 0.1 + p * 0.04))


func snap() -> void:
	_voice("band", 0.12, 3200, 900, 0.3)
	_voice("saw", 0.3, 400, 90, 0.08, 0.02)

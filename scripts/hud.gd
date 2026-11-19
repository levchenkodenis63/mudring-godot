extends Control
## HUD поверх 3D: время, отрезок, место, тахометр с зелёной зоной, перегрев, светофор, сообщения.
## Рисуется целиком в _draw() — ничего не ловит мышью (mouse_filter = IGNORE).

const MR = preload("res://scripts/core.gd")

var race                    # race.gd
var font: Font
var msgs: Array = []        # {text, color, big, age}
var us := 0                 # время отрисовки HUD, мкс (для замера)
var needle := 0.12          # стрелка тахометра — сглаженные обороты, чтобы не дёргалась


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func push(m: Dictionary) -> void:
	m["age"] = 0.0
	if m["big"]:
		msgs = msgs.filter(func(x): return not x["big"])
	else:
		msgs = msgs.filter(func(x): return x["big"])
	msgs.append(m)


func _process(delta: float) -> void:
	if race != null and race.me != null:
		needle += (race.me.rpm - needle) * minf(1.0, delta * 10.0)
	for m in msgs:
		m["age"] += delta
	msgs = msgs.filter(func(x): return x["age"] < (2.2 if x["big"] else 1.6))
	queue_redraw()


func _txt(s: String, pos: Vector2, px: int, col: Color, align := HORIZONTAL_ALIGNMENT_LEFT, w := -1.0) -> void:
	if align == HORIZONTAL_ALIGNMENT_RIGHT and w < 0.0:
		pos.x -= font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, maxi(px, 6)).x
		align = HORIZONTAL_ALIGNMENT_LEFT
	px = maxi(px, 6)
	draw_string_outline(font, pos, s, align, w, px, maxi(3, px / 6), Color(0, 0, 0, 0.75 * col.a))
	draw_string(font, pos, s, align, w, px, col)


func _draw() -> void:
	var t0 := Time.get_ticks_usec()
	_draw_hud()
	us += Time.get_ticks_usec() - t0


func _draw_hud() -> void:
	if race == null or race.me == null or not (race.screen in ["countdown", "racing"]):
		return
	var r = race.me
	var S := get_viewport_rect().size
	if S.x < 64.0 or S.y < 64.0:
		return
	var U := minf(S.x, S.y) / 720.0      # масштаб под экран
	# --- слева сверху: время, отрезок, место ---
	var tt: float = race.t if race.started else 0.0
	if race.ended and race.fail_why == "":
		tt = r.time
	_txt("%.2f" % tt, Vector2(28 * U, 70 * U), int(54 * U), Color.WHITE)
	if race.pen > 0.0:
		_txt("+%.2f фальстарт" % race.pen, Vector2(30 * U, 102 * U), int(22 * U), Color("#ff7a5a"))
	_txt("КРУГ %d/%d%s" % [race.lap_num(), race.LAPS, " · поворот" if race.seg % 2 == 1 else ""], Vector2(30 * U, 132 * U), int(22 * U), Color(1, 1, 1, 0.85))
	if race.place > 0:
		_txt("МЕСТО %d / %d" % [race.place, race.bots.size() + 1], Vector2(S.x - 28 * U, 64 * U), int(40 * U), Color("#ffd23e"), HORIZONTAL_ALIGNMENT_RIGHT, -1)
		if race.split != null:
			var sp: float = race.split
			var s := ("до соперника %.1f м" % sp) if sp > 0 else ("отрыв %.1f м" % -sp)
			_txt(s, Vector2(S.x - 28 * U, 96 * U), int(22 * U), Color(1, 1, 1, 0.85), HORIZONTAL_ALIGNMENT_RIGHT, -1)
	if r.tyre != null:
		_txt("резина " + r.tyre["name"], Vector2(S.x - 28 * U, 124 * U), int(20 * U), Color(1, 1, 1, 0.7), HORIZONTAL_ALIGNMENT_RIGHT, -1)

	# --- тахометр: внизу по центру — между большими пальцами, не отвлекает от трассы ---
	var R := 100.0 * U
	var c := Vector2(S.x / 2.0, S.y - R - 22 * U)
	var a0 := deg_to_rad(150.0)
	var a1 := deg_to_rad(390.0)
	var ang := func(v: float) -> float: return a0 + (a1 - a0) * v
	draw_circle(c, R + 14 * U, Color(0, 0, 0, 0.45))
	draw_arc(c, R, a0, a1, 64, Color(1, 1, 1, 0.18), 16 * U, true)
	var lo: float = r.lo
	var hi: float = r.hi
	draw_arc(c, R, ang.call(lo), ang.call(hi), 32, Color("#3ddc6e"), 16 * U, true)
	if hi < 0.995:
		draw_arc(c, R, ang.call(hi), a1, 24, Color("#e0453a"), 16 * U, true)
	var na: float = ang.call(needle)
	var inzone: bool = r.rpm >= lo and r.rpm <= hi
	draw_line(c, c + Vector2(cos(na), sin(na)) * (R + 6 * U), Color("#7dffa8") if inzone else Color.WHITE, 5 * U, true)
	draw_circle(c, 9 * U, Color.WHITE)
	_txt("%d" % int(r.v * 3.6), c + Vector2(-R, 52 * U), int(40 * U), Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER, R * 2.0)
	_txt("км/ч", c + Vector2(-R, 76 * U), int(18 * U), Color(1, 1, 1, 0.7), HORIZONTAL_ALIGNMENT_CENTER, R * 2.0)
	var mode := "ЛЕБЁДКА" if r.cable else ("ВОДА" if r.d > 0.02 else "")
	if mode != "":
		_txt(mode, c + Vector2(-R, -34 * U), int(20 * U), Color("#7dffa8"), HORIZONTAL_ALIGNMENT_CENTER, R * 2.0)
	# перегрев
	var hb := Rect2(c.x - R, c.y + R + 4 * U, R * 2.0, 10 * U)
	if hb.end.y > S.y - 2:
		hb.position.y = c.y - R - 34 * U
	draw_rect(hb, Color(1, 1, 1, 0.18))
	var hc := Color("#ffd23e").lerp(Color("#ff3a2a"), clampf(r.heat, 0.0, 1.0))
	draw_rect(Rect2(hb.position, Vector2(hb.size.x * clampf(r.heat, 0.0, 1.0), hb.size.y)), hc)

	# --- светофор ---
	if race.screen == "countdown" or race.light_a > 0.0:
		var al: float = 1.0 if race.screen == "countdown" else race.light_a
		var cx := S.x / 2.0
		var y := S.y * 0.40
		draw_rect(Rect2(cx - 110 * U, y - 40 * U, 220 * U, 80 * U), Color(0.05, 0.05, 0.06, 0.8 * al))
		for i in 3:
			var on: bool = race.lights > i
			var col := Color("#3ddc6e") if race.lights == 3 else Color("#ff3a2a")
			draw_circle(Vector2(cx + (i - 1) * 70 * U, y), 26 * U, Color(col.r, col.g, col.b, al) if on else Color(0.2, 0.2, 0.22, al))

	# --- «Экстрим»: заглох в воде ---
	if r.dead:
		var left: float = MR.DROWN - r.dead_t
		_txt("ЗАГЛОХ — отпусти и жми газ! %.1f" % maxf(0.0, left), Vector2(0, S.y * 0.58), int(30 * U), Color("#ff5a4a"), HORIZONTAL_ALIGNMENT_CENTER, S.x)

	# --- сообщения ---
	for m in msgs:
		var life: float = 2.2 if m["big"] else 1.6
		var a := clampf((life - m["age"]) / 0.4, 0.0, 1.0)
		var col: Color = m["color"]
		col.a = a
		var px := int((64 if m["big"] else 34) * U)
		var y: float = S.y * (0.36 if m["big"] else 0.48) - m["age"] * 14 * U
		_txt(m["text"], Vector2(0, y), px, col, HORIZONTAL_ALIGNMENT_CENTER, S.x)

	if race.screen == "countdown":
		_txt("Держи палец на экране — газ. Жми только после зелёного!", Vector2(0, S.y * 0.58), int(24 * U), Color(1, 1, 1, 0.9), HORIZONTAL_ALIGNMENT_CENTER, S.x)

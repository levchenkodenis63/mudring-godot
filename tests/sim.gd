extends SceneTree
## Сценарий для проверки ядра scripts/core.gd: трассы, автопилот, боты на всех уровнях.
## godot --headless --path . -s tests/sim.gd   (входит в tests/smoke.sh)

const MR = preload("res://scripts/core.gd")

var out: PackedStringArray = []


func f(v: float, n: int) -> String:
	return ("%." + str(n) + "f") % v


func _init() -> void:
	var r0 = MR.rng(12345)
	var a: PackedStringArray = []
	for i in 5:
		a.append(f(r0.next(), 8))
	out.append("rng " + " ".join(a))

	for s in range(1, 6):
		var tr: Dictionary = MR.make_track(s)
		var bs: PackedStringArray = []
		for b in tr["baths"]:
			bs.append(f(b["x0"], 2) + "-" + f(b["x1"], 2))
		var wl: PackedStringArray = []
		for w in tr["winches"]:
			var ps: PackedStringArray = []
			for p in w:
				ps.append(str(p["id"]) + "@" + f(p["post"], 2))
			wl.append("/".join(ps))
		out.append("track %d baths %s finish %s h %s %s winch %s" % [s, ",".join(bs), f(tr["finish"], 2),
			f(_sum(tr["lanes"][0]), 4), f(_sum(tr["lanes"][1]), 4), " | ".join(wl)])

	for s in range(1, 6):
		out.append("good %d %s" % [s, run(s, func(r): return {"tap": tap_near(r), "gas": r.rpm < r.lo + (r.hi - r.lo) * 0.85}, "normal", false, "")])
	out.append("notap 3 " + run(3, func(r): return {"tap": false, "gas": r.rpm < r.lo + (r.hi - r.lo) * 0.85}, "normal", false, ""))
	var full := func(r): return {"tap": tap_near(r), "gas": true if r.cable else r.rpm < r.lo + (r.hi - r.lo) * 0.85}
	out.append("fullgas 3 " + run(3, full, "normal", false, ""))
	out.append("fullgasX 3 " + run(3, full, "extreme", true, "assassinator"))
	out.append("over 2 " + run(2, func(r): return {"tap": tap_near(r), "gas": true}, "extreme", true, "mudlite"))

	var SK := {"easy": [0.10, 0.40], "normal": [0.36, 0.72], "hard": [0.66, 1.0], "extreme": [0.66, 1.0]}
	for pair in [["easy", ""], ["normal", ""], ["hard", ""], ["extreme", "mudlite"], ["extreme", "assassinator"]]:
		var diff: String = pair[0]
		var tyre: String = pair[1]
		var res: PackedStringArray = []
		for i in 12:
			var rnd = MR.rng(1000 + i * 7)
			var tr: Dictionary = MR.make_track(1 + (i % 5))
			var sk: Array = SK[diff]
			var ai: Dictionary = MR.make_ai(sk[0] + (sk[1] - sk[0]) * rnd.next(), rnd, diff == "extreme")
			var r = MR.new_rider()
			r.extreme = diff == "extreme"
			r.go = true
			r.tyre = MR.TYRES[tyre] if tyre != "" else null
			var t := 0.0
			var l: int = MR.PASSES[0]
			while t < 900.0:
				t += MR.DT
				var act: Dictionary = MR.ai_step(ai, r, tr, t, MR.DT)
				if act["tap"]:
					MR.winch_tap(r)
				MR.step_rider(r, tr, l, act["gas"], MR.DT, t)
				r.ev.clear()
				if r.broken or r.drowned or r.drive_out:
					break
				if r.fin:
					if ai["pass"] < 3:
						ai["pass"] += 1
						l = MR.PASSES[ai["pass"]]
						r.fin = false
						r.x = MR.START
						r.entered = [false, false, false]
						r.done = {}
					else:
						break
			res.append(f(r.time, 2) if r.fin else ("B" if r.broken else "D" if r.drowned else "P" if r.drive_out else "S"))
		out.append("bots %s%s %s" % [diff, ("-" + tyre) if tyre != "" else "", " ".join(res)])

	print("\n".join(out))
	quit()


func _sum(lane: Dictionary) -> float:
	var x := 0.0
	var h: PackedFloat32Array = lane["h"]
	for i in lane["n"]:
		x += h[i]
	return x


func tap_near(r) -> bool:
	return (r.spot != null and not r.cable and r.x > r.spot["x0"] - 1.0) or (r.cable and r.at_top)


func run(seed: int, policy: Callable, diff: String, extreme: bool, tyre: String) -> String:
	var tr: Dictionary = MR.make_track(seed)
	var r = MR.new_rider()
	r.go = true
	r.zw = MR.ZW[diff]
	r.extreme = extreme
	if tyre != "":
		r.tyre = MR.TYRES[tyre]
	var t := 0.0
	var pass_ := 0
	var l: int = MR.PASSES[0]
	var ev := 0
	while t < 600.0:
		t += MR.DT
		var act: Dictionary = policy.call(r)
		if act["tap"]:
			MR.winch_tap(r)
		MR.step_rider(r, tr, l, act["gas"], MR.DT, t)
		ev += r.ev.size()
		r.ev.clear()
		if r.broken or r.drowned or r.drive_out:
			return "%s t=%s x=%s pass=%d" % ["BROKEN" if r.broken else "DROWNED" if r.drowned else "DRIVE", f(t, 2), f(r.x, 3), pass_]
		if r.fin:
			if pass_ < 3:
				pass_ += 1
				l = MR.PASSES[pass_]
				r.fin = false
				r.x = MR.START
				r.entered = [false, false, false]
				r.done = {}
			else:
				return "FINISH %s winches=%d stalls=%d heats=%d clean=%d floods=%d top=%s ev=%d" % [f(r.time, 3), r.winches, r.wstalls, r.heats, r.clean, r.floods, f(r.top, 3), ev]
	return "TIMEOUT x=%s pass=%d" % [f(r.x, 3), pass_]

extends Node3D
## MUD RING 3D — прототип 2.5D. Логика вдоль трассы (core.gd/race.gd), картинка в 3D: кольцо-«стадион»
## (ring.gd) — две прямые с ваннами и стенками, повороты между ними. Камера сбоку, снаружи кольца,
## едет за игроком по кривой. Трасса, земля и окружение собираются кодом.

const MR = preload("res://scripts/core.gd")
const Race = preload("res://scripts/race.gd")
const Quad = preload("res://scripts/quad.gd")
const Hud = preload("res://scripts/hud.gd")
const WATER_SHADER = preload("res://shaders/water.gdshader")
const Sound = preload("res://scripts/sound.gd")
const Env = preload("res://scripts/env.gd")
const Ring = preload("res://scripts/ring.gd")
const GROUND_SHADER = preload("res://shaders/ground.gdshader")

const HALF := Ring.HALF       # полуширина колеи
const BANK := Ring.BANK       # бровка
const EDGE := Ring.EDGE       # край насыпи
const ME_DZ := 0.6            # игрок — по внешней (к камере) стороне колеи, боты — по внутренней (столкновений нет)

var race
var world: Node3D
var cam: Camera3D
var cam_s := 0.0              # положение камеры на круге (без сброса между кругами)
var shake := 0.0
var acc := 0.0
var me_quad
var bot_quads: Array = []
var posts: Array = []         # {lane, id, node, ring}
var cable: MeshInstance3D
var water_mats: Array = []    # [lane] -> ShaderMaterial
var ui: Control
var hud
var winch_btn: Button
var gas_btn: Button
var gas_now := false
var overlay: Control
var font: Font
var touches := {}
var sound
var sound_btn: Button
var menu_t := 0.0
## автопилот для проверок: godot --path . -- --auto=extreme:assassinator [--quit]
var auto := false
var auto_quit := false
var quality := 2               # 2 — высокое (ПК), 1 — среднее, 0 — низкое
var quality_fixed := false     # задано вручную — не подстраивать
var env: Environment
var sun: DirectionalLight3D
var shot_dir := ""             # --shot=папка: скриншоты на автопилоте в моменты SHOTS (с от старта)
const SHOTS := [1.0, 2.6, 3.2, 14.0, 30.0, 44.0, 52.0, 56.0, 70.0]
var shot_i := 0
var dbg_noenv := false         # замеры: без окружения
var dbg_nobots := false        # замеры: без квадроциклов ботов


func _ready() -> void:
	_setup_input()
	_build_env()
	sound = Sound.new()
	add_child(sound)
	cam = Camera3D.new()
	cam.fov = 46.0
	cam.far = 500.0
	add_child(cam)
	cam.current = true
	_build_ui()
	race = Race.new()
	race.setup("normal", "mudlite", 1)
	race.screen = "menu"
	hud.race = race
	_build_world()
	_show_menu()
	var args := Array(OS.get_cmdline_user_args())
	# автотест на телефоне: adb кладёт user://auto.txt со строкой «normal 1» (уровень, качество)
	var af := FileAccess.open("user://auto.txt", FileAccess.READ)
	if af != null:
		var line := af.get_as_text().strip_edges().split(" ")
		af.close()
		args.append("--auto=" + line[0])
		if line.size() > 1:
			args.append("--quality=" + line[1])
		for extra in line.slice(2):                 # отладка: noenv, nobots
			args.append("--" + extra)
	var q := 0 if OS.has_feature("mobile") else 2      # телефон — с низкого, повышается, если тянет с запасом
	for a: String in args:
		if a.begins_with("--quality="):
			q = int(a.get_slice("=", 1))
			quality_fixed = true
		dbg_noenv = dbg_noenv or a == "--noenv"
		dbg_nobots = dbg_nobots or a == "--nobots"
	_apply_quality(q)
	for a: String in args:
		if a.begins_with("--auto"):
			auto = true
			var spec := a.get_slice("=", 1) if a.contains("=") else "normal"
			var parts := spec.split(":")
			_start(parts[0], parts[1] if parts.size() > 1 else "mudlite")
			_go()
		elif a == "--quit":
			auto_quit = true
		elif a.begins_with("--shot="):
			shot_dir = a.get_slice("=", 1)


# ---------- ввод ----------
func _setup_input() -> void:
	_action("gas", [KEY_UP, KEY_W, KEY_SPACE, KEY_D, KEY_RIGHT])
	_action("winch", [KEY_E])


func _action(n: String, keys: Array) -> void:
	if not InputMap.has_action(n):
		InputMap.add_action(n)
	for k in keys:
		var e := InputEventKey.new()
		e.physical_keycode = k
		InputMap.action_add_event(n, e)


func _on_ui(pos: Vector2) -> bool:
	if overlay != null and overlay.visible:
		return true
	return sound_btn.get_global_rect().grow(8).has_point(pos)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			if _on_ui(event.position):
				return
			# кнопки ГАЗ и ЛЕБЁДКА — свои касания (не Button): второй палец работает, пока первый держит газ
			if winch_btn.visible and winch_btn.get_global_rect().grow(10).has_point(event.position):
				if race.winch_cue() != null:
					race.winch_action(touches.size() > 0 or Input.is_action_pressed("gas"))
				return
			if _hit_post(event.position):        # тап по столбику — как в веб-версии
				race.winch_action(touches.size() > 0 or Input.is_action_pressed("gas"))
				return
			touches[event.index] = true
		else:
			touches.erase(event.index)
	elif event.is_action_pressed("winch"):
		race.winch_action(Input.is_action_pressed("gas") or touches.size() > 0)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_APPLICATION_PAUSED:
		touches.clear()            # свернули приложение — газ не залипает


func _hit_post(pos: Vector2) -> bool:
	var cue = race.winch_cue()
	if cue == null:
		return false
	for p in posts:
		if p["lane"] == race.lane and p["id"] == cue["id"]:
			var wp: Vector3 = p["node"].global_position + Vector3(0, 0.8, 0)
			if cam.is_position_behind(wp):
				return false
			return cam.unproject_position(wp).distance_to(pos) < 90.0 * _u()
	return false


func _u() -> float:
	var s := get_viewport().get_visible_rect().size
	return minf(s.x, s.y) / 720.0


func _gas() -> bool:
	if auto and race.screen == "racing":
		var r = race.me
		var cue = race.winch_cue()
		if cue != null and (cue["mode"] == "detach" or r.x > cue["sp"]["x0"] - 1.0):
			race.winch_action(false)          # автопилот тоже отпускает газ перед лебёдкой
			return false
		var trk: Dictionary = race.ring.physics_track(race.seg)
		var bi := MR.bath_at(trk, r.x)
		if not r.cable and ((r.d <= 0.02 and MR.next_bath_dist(trk, r.x) < 4.0) or (bi >= 0 and not r.entered[bi])):
			return true                       # в воду — на газу (глиссер), пока въезд не засчитан
		return r.rpm < r.lo + (r.hi - r.lo) * 0.85
	return touches.size() > 0 or Input.is_action_pressed("gas")


# ---------- цикл ----------
func _process(delta: float) -> void:
	var gas := _gas()
	gas_now = gas
	if race.screen == "countdown" or race.screen == "racing":
		acc += minf(delta, 0.1)
		var t0 := Time.get_ticks_usec()
		while acc >= MR.DT:
			acc -= MR.DT
			race.update(MR.DT, gas)
		_us_logic += Time.get_ticks_usec() - t0
		if race.screen == "final":
			race.screen = "results"
			_show_final()
			_auto_done()
		elif race.screen == "fail":
			race.screen = "results"
			_show_fail()
			_auto_done()
	for m in race.msgs:
		hud.push(m)
	race.msgs.clear()
	for f in race.fx:
		if f["kind"] == "shake":
			shake = maxf(shake, f["p"])
		elif f["kind"] == "burst":
			me_quad.splash(f["p"])
	race.fx.clear()
	var t1 := Time.get_ticks_usec()
	_sound()
	_sync(delta)
	_us_sync += Time.get_ticks_usec() - t1
	_perf(delta)
	if shot_dir != "" and race.screen == "racing" and shot_i < SHOTS.size() and race.t >= SHOTS[shot_i]:
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("%s/shot_%02d.png" % [shot_dir, shot_i])
		shot_i += 1
		if shot_i >= SHOTS.size() and auto_quit:
			get_tree().quit()


## качество картинки: на слабых телефонах упирается в закраску пикселей — снижаем разрешение 3D,
## убираем MSAA, свечение, тени, часть брызг. HUD рисуется в полном разрешении всегда.
func _apply_quality(q: int) -> void:
	quality = clampi(q, 0, 2)
	var vp := get_viewport()
	vp.msaa_3d = Viewport.MSAA_2X if quality == 2 else Viewport.MSAA_DISABLED
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = [0.6, 0.7, 1.0][quality]
	env.glow_enabled = quality == 2
	env.fog_enabled = true                          # дёшево и прячет обрез дальности камеры
	cam.far = [120.0, 160.0, 400.0][quality]        # за кольцом лес; дальше всё равно туман
	sun.shadow_enabled = quality == 2
	Quad.blob_shadows = quality < 2
	RenderingServer.directional_shadow_atlas_set_size(4096 if quality == 2 else 1024, true)
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL if quality < 2 else DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 45.0 if quality == 2 else 25.0
	Quad.particle_scale = [0.4, 0.7, 1.0][quality]
	if me_quad != null:
		for qd in [me_quad] + bot_quads:
			qd.blob.visible = Quad.blob_shadows
	print("QUALITY ", quality)


## замер на устройстве: раз в 5 с в лог (adb logcat -s godot) — FPS, худший кадр, доля синтеза звука
var _pt := 0.0
var _pn := 0
var _pmax := 0.0
var _fast := 0                 # сколько окон подряд FPS с запасом (повышение качества)
var _us_logic := 0
var _us_sync := 0
func _perf(delta: float) -> void:
	_pt += delta
	_pn += 1
	_pmax = maxf(_pmax, delta)
	if _pt >= 5.0:
		var fps := _pn / _pt
		if race.screen == "racing" and not quality_fixed and quality > 0 and fps < 45.0:
			_apply_quality(quality - 1)             # не тянет — на ступень ниже
			_fast = -99                             # и больше не повышать
		elif race.screen == "racing" and not quality_fixed and fps > 58.0:
			_fast += 1
			var top := 1 if OS.has_feature("mobile") else 2
			if _fast >= 2 and quality < top:       # 10 с с запасом — на ступень выше
				_apply_quality(quality + 1)
				_fast = 0
		else:
			_fast = mini(_fast, 0)
		print("PERF q=%d %s fps=%.1f avg=%.1fms worst=%.1fms sound=%.1f%% logic=%.1fms sync=%.1fms hud=%.1fms draw_calls=%d prims=%dk" % [quality, race.screen, fps, _pt / _pn * 1000.0,
			_pmax * 1000.0, sound.synth_us / (_pt * 1e6) * 100.0, _us_logic / 1000.0 / _pn, _us_sync / 1000.0 / _pn, hud.us / 1000.0 / _pn,
			RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
			RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME) / 1000])
		_pt = 0.0
		_pn = 0
		_pmax = 0.0
		sound.synth_us = 0
		_us_logic = 0
		_us_sync = 0
		hud.us = 0


## звук: мотор игрока, ближайший бот, лебёдка, разовые эффекты
func _sound() -> void:
	var sy = sound.synth
	for e in race.sfx:
		var nm: String = e[0]
		match nm:       # звуки грязи (всплеск, перелив, удар, приземление, заглох) убраны по отзыву — только мотор и лебёдка
			"clean": sy.clean()
			"light": sy.light(e[1])
			"finish": sy.finish()
			"ui": sy.ui()
	race.sfx.clear()
	var r = race.me
	sy.active = race.screen == "countdown" or race.screen == "racing"
	sy.running = not (r.dead or r.drowned or r.drive_out or r.cut > 0.0)
	sy.rpm = r.rpm
	sy.load = r.gas
	sy.water = r.d > 0.02
	sy.over = r.rpm > r.hi + 0.01
	sy.winch = clampf(r.v / 1.15, 0.0, 1.0) if (r.cable and not r.at_top) else 0.0
	# ближайший бот на той же дорожке
	var best := 1e9
	sy.bot_gain = 0.0
	for b in race.bots:
		if b["total"] != null or b["out"] != "":
			continue
		var d: float = absf(race.progress(b["st"], b["r"]) - race.progress(race.st, r))
		if d < best:
			best = d
			sy.bot_rpm = b["r"].rpm
	if best < 25.0:
		sy.bot_gain = 0.06 * (1.0 - best / 25.0)


func _sync(delta: float) -> void:
	var r = race.me
	var ring = race.ring
	var st: Dictionary = race.st
	var f: Array = ring.frame(st["seg"], r.x)
	me_quad.sync(r, ring.world(st["seg"], r.x, r.y, ME_DZ), Ring.yaw_of(f[1]), delta)
	for i in bot_quads.size():
		var b: Dictionary = race.bots[i]
		var q = bot_quads[i]
		q.visible = b["total"] == null and not dbg_nobots
		# боты без столкновений; разводим по внутренней стороне колеи в 4 ряда, чтобы не закрывали игрока
		var dz := -1.15 + float(b["slot"] % 4) * 0.33
		var bs: Dictionary = b["st"]
		var fb: Array = ring.frame(bs["seg"], b["r"].x)
		q.sync(b["r"], ring.world(bs["seg"], b["r"].x, b["r"].y, dz), Ring.yaw_of(fb[1]), delta)
	# камера: снаружи кольца, едет по кривой за игроком (положение на круге без сброса на новом круге)
	var target: float = race.progress(st, r) + ring.lap_pos(0, 0.0)
	if race.screen == "menu" or race.screen == "ready":
		menu_t += delta
		target = menu_t * 5.0
		cam_s = target
	cam_s += (target - cam_s) * minf(1.0, delta * 7.0)
	var lead := clampf(r.v * 0.25, 0.0, 3.0)
	var fp: Array = ring.frame_at(cam_s + 0.2 + lead * 0.4)
	var fl: Array = ring.frame_at(cam_s + 1.3 + lead * 0.6)
	var lx: Array = ring.locate(cam_s)
	var base_y: float = ring.ground_y(lx[0], lx[1]) * 0.6
	var pos: Vector3 = (fp[0] as Vector3) + (fp[2] as Vector3) * 6.6 + Vector3(0, base_y + 2.1, 0)
	if shake > 0.0:
		pos += Vector3(randf_range(-1, 1), randf_range(-1, 1), 0) * shake * 0.18
		shake = maxf(0.0, shake - delta * 1.8)
	cam.global_position = pos
	cam.look_at((fl[0] as Vector3) + Vector3(0, base_y + 0.45, 0), Vector3.UP)
	# лебёдка: подсветка столбика и трос
	var cue = race.winch_cue()
	var post = null
	for p in posts:
		var on: bool = cue != null and p["lane"] == race.lane and p["id"] == cue["id"]
		p["ring"].visible = on
		if on:
			var s := 1.0 + 0.15 * sin(Time.get_ticks_msec() / 120.0)
			p["ring"].scale = Vector3(s, 1, s)
		if r.spot != null and p["lane"] == race.lane and p["id"] == r.spot["id"]:
			post = p
	cable.visible = r.cable and post != null
	if cable.visible:
		var a: Vector3 = me_quad.to_global(Vector3(MR.WB / 2.0 + 0.45, MR.WR + 0.2, 0))
		var b: Vector3 = (post["node"] as Node3D).global_position + Vector3(0, 0.75, 0)
		var d := b - a
		var qt := Quaternion(Vector3.UP, d.normalized())
		cable.global_transform = Transform3D(Basis(qt) * Basis.from_scale(Vector3(1, d.length(), 1)), (a + b) / 2.0)
	# кнопки видны весь заезд; лебёдка активна только у стенки (как раньше появлялась)
	var playing: bool = race.screen == "racing" or race.screen == "countdown"
	winch_btn.visible = playing
	gas_btn.visible = playing
	winch_btn.disabled = cue == null
	winch_btn.text = "ОТЦЕПИТЬ" if cue != null and cue["mode"] == "detach" else "ЛЕБЁДКА"
	gas_btn.button_pressed = gas_now
	# круги на воде вокруг игрока
	var mp: Vector3 = me_quad.position + (f[1] as Vector3) * 0.3
	var wk := Vector4(mp.x, mp.z, 0, 0)
	if r.d > 0.02 and not r.drowned:
		wk.w = clampf(r.v / 7.0 + (0.6 if r.spin else 0.0), 0.15, 1.0)
	var on_straight := not Ring.is_turn(st["seg"])
	for l in 2:
		water_mats[l].set_shader_parameter("wake", wk if (on_straight and l == race.lane) else Vector4.ZERO)


# ---------- окружение ----------
func _build_env() -> void:
	env = Environment.new()
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color("#8297ad")            # пасмурно, как на фото соревнований
	sm.sky_horizon_color = Color("#d3d8dc")
	sm.ground_horizon_color = Color("#9a9a84")
	sm.ground_bottom_color = Color("#4a4a3a")
	sm.sun_angle_max = 30.0
	sky.sky_material = sm
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.9
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.05
	env.fog_enabled = true
	env.fog_light_color = Color("#c8ced2")
	env.fog_density = 0.009
	env.glow_enabled = true
	env.glow_intensity = 0.4
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, -35, 0)
	sun.light_energy = 1.0
	sun.light_color = Color("#f4f1ea")
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 45.0
	add_child(sun)


# ---------- трасса: кольцо ----------
func _build_world() -> void:
	if world != null:
		world.queue_free()
	world = Node3D.new()
	add_child(world)
	posts.clear()
	water_mats.clear()
	var ring = race.ring
	var tr: Dictionary = race.track
	var gmat := _ground_shader()
	var rows: Array = ring.samples(0.2, 0.4)
	var mi := MeshInstance3D.new()
	mi.mesh = _ring_mesh(ring, rows)
	mi.material_override = gmat
	world.add_child(mi)
	var gr := MeshInstance3D.new()
	gr.mesh = _ground_mesh(ring, rows)
	gr.material_override = gmat
	world.add_child(gr)
	# вода и столбики лебёдки — на прямых (участки 0 и 2 = дорожки 0 и 1 трассы core.gd)
	for l in 2:
		var sg := 0 if l == 0 else 2
		var wm := ShaderMaterial.new()
		wm.shader = WATER_SHADER
		water_mats.append(wm)
		for b in tr["baths"]:
			var L: float = b["x1"] - b["x0"]
			var f: Array = ring.frame(sg, (b["x0"] + b["x1"]) / 2.0)
			var w := MeshInstance3D.new()
			var pm := PlaneMesh.new()
			pm.size = Vector2(L, BANK * 2.0)
			pm.subdivide_width = int(L * 2.0)
			pm.subdivide_depth = 8
			w.mesh = pm
			w.material_override = wm
			w.position = (f[0] as Vector3) + Vector3(0, MR.WATER, 0)
			w.rotation.y = Ring.yaw_of(f[1])
			w.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			world.add_child(w)
		_lane_props(tr, l)
	_start_arch(ring, tr)
	if not dbg_noenv:
		Env.new().build(world, ring, quality)
	# трос
	cable = MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.018
	cm.bottom_radius = 0.018
	cm.height = 1.0
	cm.radial_segments = 6
	cable.mesh = cm
	cable.material_override = _flat(Color("#d8d8d8"))
	cable.visible = false
	world.add_child(cable)
	# квадроциклы
	me_quad = Quad.new()
	me_quad.build(0, false)
	world.add_child(me_quad)
	bot_quads.clear()
	for b in race.bots:
		var q = Quad.new()
		q.build(b["look"], true)
		world.add_child(q)
		bot_quads.append(q)


## рельеф колеи — замкнутая лента вдоль кольца: профиль поперёк (Ring.ZS) в каждом отсчёте
func _ring_mesh(ring, rows: Array) -> ArrayMesh:
	var tr: Dictionary = race.track
	var nr := rows.size()
	var nz: int = Ring.ZS.size()
	var P := PackedVector3Array()
	P.resize(nr * nz)
	var cols := PackedColorArray()
	cols.resize(nr * nz)
	for i in nr:
		var row: Array = rows[i]
		var sg: int = row[0]
		var x: float = row[1]
		var prof: Array = ring.profile(sg, x)
		var inb: bool = not Ring.is_turn(sg) and MR.bath_at(tr, x) >= 0
		for j in nz:
			var dz: float = Ring.ZS[j]
			P[i * nz + j] = (row[2] as Vector3) + (row[4] as Vector3) * dz + Vector3(0, prof[j], 0)
			# r — доля травы, g — влажность, b — положение поперёк (колеи): см. shaders/ground.gdshader
			var b: float = (dz + EDGE) / (2.0 * EDGE)
			var c: Color
			if j == 0 or j == nz - 1:
				c = Color(1.0, 0.0, b)
			elif j == 1 or j == nz - 2:
				c = Color(0.55, 0.5 if inb else 0.2, b)
			elif inb:
				c = Color(0.0, 1.0, b)
			else:
				c = Color(0.0, 0.45, b)
			cols[i * nz + j] = c
	var norms := PackedVector3Array()
	norms.resize(nr * nz)
	for i in nr:
		for j in nz:
			var along: Vector3 = P[((i + 1) % nr) * nz + j] - P[((i - 1 + nr) % nr) * nz + j]
			var across: Vector3 = P[i * nz + mini(j + 1, nz - 1)] - P[i * nz + maxi(j - 1, 0)]
			var n := across.cross(along).normalized()
			norms[i * nz + j] = n if n.y >= 0.0 else -n
	var idx := PackedInt32Array()
	for i in nr:
		var i2 := (i + 1) % nr
		for j in nz - 1:
			var a := i * nz + j
			var b := i2 * nz + j
			var c := i2 * nz + j + 1
			var d := i * nz + j + 1
			for k in [a, b, c, a, c, d]:
				idx.append(k)
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = P
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_COLOR] = cols
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh


## земля вокруг колеи: поле внутри кольца (веер от центра) и широкое кольцо снаружи — без дыр над ваннами
func _ground_mesh(ring, rows: Array) -> ArrayMesh:
	var tris: Array = []          # Array, а не Packed*: лямбда захватывает packed-массивы по значению
	var y := Vector3(0, -0.04, 0)
	var c := Vector3((Ring.XS + ring.xe) / 2.0, 0, 0) + y
	var nr := rows.size()
	# лицевая сторона в Godot — обход по часовой стрелке, если смотреть сверху (нормаль обхода вниз)
	var tri := func(a: Vector3, b: Vector3, d: Vector3) -> void:
		if (b - a).cross(d - a).y > 0.0:
			tris.append_array([a, d, b])
		else:
			tris.append_array([a, b, d])
	for i in nr:
		var r0: Array = rows[i]
		var r1: Array = rows[(i + 1) % nr]
		var p0: Vector3 = (r0[2] as Vector3) + y
		var p1: Vector3 = (r1[2] as Vector3) + y
		var n0: Vector3 = r0[4]
		var n1: Vector3 = r1[4]
		tri.call(c, p0 - n0 * EDGE, p1 - n1 * EDGE)
		var a0 := p0 + n0 * EDGE
		var a1 := p1 + n1 * EDGE
		var b0 := p0 + n0 * 220.0
		var b1 := p1 + n1 * 220.0
		tri.call(a0, a1, b1)
		tri.call(a0, b1, b0)
	var verts := PackedVector3Array(tris)
	var norms := PackedVector3Array()
	norms.resize(verts.size())
	norms.fill(Vector3.UP)
	var cols := PackedColorArray()
	cols.resize(verts.size())
	cols.fill(Color(1, 0, 0))
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_COLOR] = cols
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh


## материал земли: грязь колеи и трава (shaders/ground.gdshader) — общий для дорожек и поля
func _ground_shader() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = GROUND_SHADER
	var nt := NoiseTexture2D.new()
	nt.width = 512
	nt.height = 512
	nt.seamless = true
	nt.generate_mipmaps = true
	var n := FastNoiseLite.new()
	n.frequency = 0.012
	n.fractal_octaves = 5
	nt.noise = n
	m.set_shader_parameter("noise_tex", nt)
	return m


func _flat(col: Color, emit := false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = 0.7
	if emit:
		m.emission_enabled = true
		m.emission = col
		m.emission_energy_multiplier = 1.5
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return m


func _mesh(mesh: Mesh, pos: Vector3, mat: Material, parent: Node3D = null) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	(parent if parent != null else world).add_child(mi)
	return mi


func _boxm(size: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = size
	return b


func _cylm(r: float, h: float) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = r
	c.bottom_radius = r
	c.height = h
	c.radial_segments = 12
	return c


## столбики лебёдки на прямой дорожки l
func _lane_props(tr: Dictionary, l: int) -> void:
	var ring = race.ring
	var sg := 0 if l == 0 else 2
	var lane: Dictionary = tr["lanes"][l]
	var yellow := _flat(Color("#f2c418"))
	var black := _flat(Color("#1b1b20"))
	for sp in tr["winches"][l]:
		var px: float = sp["post"]
		var f: Array = ring.frame(sg, px)
		var node := Node3D.new()
		node.position = (f[0] as Vector3) + Vector3(0, MR.h_at(lane, px), 0)
		node.rotation.y = Ring.yaw_of(f[1])
		world.add_child(node)
		_mesh(_cylm(0.11, 1.4), Vector3(0, 0.7, 0), yellow, node)
		for k in 3:
			_mesh(_cylm(0.115, 0.12), Vector3(0, 0.3 + k * 0.4, 0), black, node)
		_mesh(_boxm(Vector3(0.34, 0.26, 0.3)), Vector3(-0.12, 0.85, 0), black, node)      # барабан лебёдки
		var rg := MeshInstance3D.new()
		var tm := TorusMesh.new()
		tm.inner_radius = 0.42
		tm.outer_radius = 0.55
		rg.mesh = tm
		rg.material_override = _flat(Color("#7dffa8"), true)
		rg.position = Vector3(0, 0.05, 0)
		rg.visible = false
		node.add_child(rg)
		posts.append({"lane": l, "id": sp["id"], "node": node, "ring": rg})


## линия старта и арка «СТАРТ · ФИНИШ» — одна на кольце, на прямой 0 в x = 0
func _start_arch(ring, tr: Dictionary) -> void:
	var white := _flat(Color("#f2f2ee"))
	var red := _flat(Color("#d8352a"))
	var f: Array = ring.frame(0, 0.0)
	var p: Vector3 = f[0]
	var n: Vector3 = f[2]
	var y := MR.h_at(tr["lanes"][0], 0.0)
	var node := Node3D.new()
	node.position = p + Vector3(0, y, 0)
	node.rotation.y = Ring.yaw_of(f[1])
	world.add_child(node)
	_mesh(_boxm(Vector3(0.25, 0.03, HALF * 2.0)), Vector3(0, 0.01, 0), white, node)
	for s in [-1.0, 1.0]:
		_mesh(_boxm(Vector3(0.3, 3.4, 0.3)), Vector3(0, 1.7, s * (BANK + 0.2)), red, node)
	_mesh(_boxm(Vector3(0.4, 0.7, BANK * 2.0 + 0.7)), Vector3(0, 3.4, 0), red, node)
	for side in [[Vector3(0.21, 3.4, 0), 90.0], [Vector3(0, 3.4, BANK + 0.36), 0.0]]:
		var lab := Label3D.new()
		lab.text = "СТАРТ · ФИНИШ"
		lab.font = font
		lab.font_size = 110
		lab.outline_size = 18
		lab.pixel_size = 0.004
		lab.position = side[0]
		lab.rotation_degrees = Vector3(0, side[1], 0)
		node.add_child(lab)



# ---------- интерфейс ----------
func _build_ui() -> void:
	var sf := SystemFont.new()
	sf.font_names = PackedStringArray(["Helvetica Neue", "Roboto", "Arial", "sans-serif"])
	sf.font_weight = 700
	font = sf
	var layer := CanvasLayer.new()
	add_child(layer)
	ui = Control.new()
	ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var th := Theme.new()
	th.default_font = sf
	th.default_font_size = 26
	ui.theme = th
	layer.add_child(ui)
	hud = Hud.new()
	hud.font = sf
	ui.add_child(hud)
	winch_btn = Button.new()
	winch_btn.text = "ЛЕБЁДКА"
	winch_btn.focus_mode = Control.FOCUS_NONE
	winch_btn.add_theme_font_size_override("font_size", 34)
	winch_btn.add_theme_stylebox_override("normal", _style(Color("#2f9e55"), 18))
	winch_btn.add_theme_stylebox_override("hover", _style(Color("#38b862"), 18))
	winch_btn.add_theme_stylebox_override("pressed", _style(Color("#257d43"), 18))
	winch_btn.custom_minimum_size = Vector2(260, 110)
	winch_btn.anchor_top = 1.0
	winch_btn.anchor_bottom = 1.0
	winch_btn.offset_top = -140
	winch_btn.offset_bottom = -30
	winch_btn.offset_left = 30
	winch_btn.offset_right = 290
	winch_btn.add_theme_stylebox_override("disabled", _style(Color(0.25, 0.25, 0.27, 0.55), 18))
	winch_btn.add_theme_color_override("font_disabled_color", Color(1, 1, 1, 0.35))
	winch_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE      # нажатия — в _unhandled_input (мультитач)
	winch_btn.visible = false
	ui.add_child(winch_btn)
	gas_btn = Button.new()
	gas_btn.text = "ГАЗ"
	gas_btn.toggle_mode = true
	gas_btn.focus_mode = Control.FOCUS_NONE
	gas_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
	gas_btn.add_theme_font_size_override("font_size", 38)
	gas_btn.add_theme_stylebox_override("normal", _style(Color(0.88, 0.71, 0.09, 0.55), 18))
	gas_btn.add_theme_stylebox_override("pressed", _style(Color("#f2c418"), 18))
	gas_btn.add_theme_stylebox_override("hover", _style(Color(0.88, 0.71, 0.09, 0.55), 18))
	gas_btn.add_theme_stylebox_override("hover_pressed", _style(Color("#f2c418"), 18))
	gas_btn.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
	gas_btn.add_theme_color_override("font_pressed_color", Color("#17171b"))
	gas_btn.add_theme_color_override("font_hover_pressed_color", Color("#17171b"))
	gas_btn.anchor_left = 1.0
	gas_btn.anchor_right = 1.0
	gas_btn.anchor_top = 1.0
	gas_btn.anchor_bottom = 1.0
	gas_btn.offset_left = -290
	gas_btn.offset_right = -30
	gas_btn.offset_top = -140
	gas_btn.offset_bottom = -30
	gas_btn.visible = false
	ui.add_child(gas_btn)
	sound_btn = Button.new()
	sound_btn.text = "ЗВУК"
	sound_btn.focus_mode = Control.FOCUS_NONE
	sound_btn.add_theme_font_size_override("font_size", 18)
	sound_btn.add_theme_stylebox_override("normal", _style(Color(0, 0, 0, 0.4), 10))
	sound_btn.add_theme_stylebox_override("hover", _style(Color(0, 0, 0, 0.55), 10))
	sound_btn.add_theme_stylebox_override("pressed", _style(Color(0, 0, 0, 0.6), 10))
	sound_btn.anchor_left = 1.0
	sound_btn.anchor_right = 1.0
	sound_btn.offset_left = -150
	sound_btn.offset_right = -28
	sound_btn.offset_top = 150
	sound_btn.offset_bottom = 194
	sound_btn.pressed.connect(_toggle_sound)
	ui.add_child(sound_btn)


func _toggle_sound() -> void:
	sound.synth.muted = not sound.synth.muted
	sound_btn.text = "БЕЗ ЗВУКА" if sound.synth.muted else "ЗВУК"


func _style(col: Color, radius: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = col
	s.set_corner_radius_all(radius)
	s.content_margin_left = 22
	s.content_margin_right = 22
	s.content_margin_top = 12
	s.content_margin_bottom = 12
	return s


## экран поверх игры: заголовок, текст, кнопки [[текст, основная, Callable], ...]
func _overlay(title: String, sub: String, buttons: Array, title_col := Color.WHITE) -> void:
	if overlay != null:
		overlay.queue_free()
	touches.clear()
	overlay = Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.45)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(center)
	var panel := PanelContainer.new()
	var ps := _style(Color(0.08, 0.08, 0.09, 0.9), 22)
	ps.content_margin_left = 40
	ps.content_margin_right = 40
	ps.content_margin_top = 30
	ps.content_margin_bottom = 30
	panel.add_theme_stylebox_override("panel", ps)
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	panel.add_child(box)
	var t := Label.new()
	t.text = title
	t.add_theme_font_size_override("font_size", 52)
	t.add_theme_color_override("font_color", title_col)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(t)
	if sub != "":
		var s := Label.new()
		s.text = sub
		s.add_theme_font_size_override("font_size", 22)
		s.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
		s.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		s.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		s.custom_minimum_size = Vector2(620, 0)
		box.add_child(s)
	var row := HFlowContainer.new()
	row.alignment = FlowContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("h_separation", 12)
	row.add_theme_constant_override("v_separation", 12)
	box.add_child(row)
	for bd in buttons:
		var b := Button.new()
		b.text = bd[0]
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(180, 70)
		var main: bool = bd[1]
		var col := Color("#e0b418") if main else Color("#3a3a42")
		b.add_theme_stylebox_override("normal", _style(col, 14))
		b.add_theme_stylebox_override("hover", _style(col.lightened(0.12), 14))
		b.add_theme_stylebox_override("pressed", _style(col.darkened(0.15), 14))
		if main:
			b.add_theme_color_override("font_color", Color("#17171b"))
			b.add_theme_color_override("font_hover_color", Color("#17171b"))
			b.add_theme_color_override("font_pressed_color", Color("#17171b"))
		b.pressed.connect(bd[2])
		row.add_child(b)
	ui.add_child(overlay)


func _hide_overlay() -> void:
	if overlay != null:
		overlay.queue_free()
		overlay = null


func _show_menu() -> void:
	race.screen = "menu"
	_overlay("MUD RING 3D", "Прототип 2.5D. Масстарт 6 квадроциклов, 2 круга по кольцу.\nДержи ГАЗ (кнопка справа, любое место экрана или пробел) — стрелка тахометра в зелёной зоне. У крутой стенки загорится ЛЕБЁДКА (кнопка слева или E).", [
		["Новички", false, func(): _pick("easy")],
		["Любители", true, func(): _pick("normal")],
		["Профи", false, func(): _pick("hard")],
		["Экстрим", false, func(): _pick("extreme")],
	], Color("#ffd23e"))


func _pick(diff: String) -> void:
	if diff == "extreme":
		_overlay("РЕЗИНА", "MudLite — зелёная зона шире, в воде −8 % скорости.\nAssassinator — в воде +8 %, лебёдка быстрее, зона уже; два заглоха подряд в воде ломают привод.", [
			["MudLite", true, func(): _start("extreme", "mudlite")],
			["Assassinator", true, func(): _start("extreme", "assassinator")],
			["Назад", false, func(): _show_menu()],
		])
	else:
		_start(diff, "mudlite")


func _start(diff: String, tyre: String) -> void:
	race.setup(diff, tyre)
	_build_world()
	cam_s = race.progress(race.st, race.me) + race.ring.lap_pos(0, 0.0)
	acc = 0.0
	var r = race.me
	var sub := "%s%s · ты в сетке %d-м · лебёдок: %d.\nГаз только после зелёного: фальстарт +2.00 с." % [
		Race.DIFFNAME[diff], (" · резина " + r.tyre["name"]) if r.tyre != null else "", race.grid_slot + 1,
		race.track["winches"][0].size() * 2 + race.track["winches"][1].size() * 2]
	if diff == "extreme":
		sub += "\nЭкстрим: заглох в воде — отпусти газ и нажми снова, иначе через 2 с утонешь. Два заглоха подряд на лебёдке — обрыв троса."
	_overlay("ГОТОВ?", sub, [["ГОТОВ", true, func(): _go()], ["Меню", false, func(): _show_menu()]])


func _go() -> void:
	_hide_overlay()
	race.begin_countdown()


func _show_final() -> void:
	var r = race.me
	var st: Array = race.standings()
	var place := 0
	for i in st.size():
		if st[i]["me"]:
			place = i + 1
	var win: float = st[0]["total"] if st[0]["total"] != null else 0.0
	var lines: PackedStringArray = []
	for i in st.size():
		var e: Dictionary = st[i]
		var mark := "▶ " if e["me"] else "   "
		if e["out"] != "":
			lines.append("%s—  %s — %s" % [mark, e["name"], e["out"]])
		else:
			lines.append("%s%d.  %s  %.2f%s" % [mark, i + 1, e["name"], e["total"], "" if i == 0 else "  +%.2f" % (e["total"] - win)])
	var title := "ПОБЕДА!" if place == 1 else ("ПОДИУМ" if place <= 3 else "%d МЕСТО" % place)
	var col := Color("#7dffa8") if place == 1 else (Color("#ffd23e") if place <= 3 else Color("#ff8a6a"))
	var sub := "%.2f  (круги %.2f + %.2f%s)\n\n%s\n\nЛебёдок: %d · заглохов на лебёдке: %d · перегревов: %d · чистых входов: %d" % [
		r.time + race.pen, race.laps[0], race.laps[1], (" · фальстарт +%.2f" % race.pen) if race.pen > 0 else "",
		"\n".join(lines), r.winches, r.wstalls, r.heats, r.clean]
	_overlay(title, sub, [["Ещё раз", true, func(): _start(race.diff, race.tyre)], ["Меню", false, func(): _show_menu()]], col)


func _auto_done() -> void:
	if not auto:
		return
	var r = race.me
	print("AUTO %s %s: %s time=%.2f place=%d winches=%d glides=%d floods=%d clean=%d laps=%s" % [race.diff, race.tyre, race.fail_why if race.fail_why != "" else "finish",
		r.time + race.pen, race.place, r.winches, r.glides, r.floods, r.clean, str(race.laps)])
	for e in race.standings():
		print("  ", e["name"], " ", e["total"], " ", e["out"])
	if auto_quit:
		get_tree().quit()


func _show_fail() -> void:
	_overlay("ПОТРАЧЕНО", Race.FAILNAME.get(race.fail_why, "") + "\nВремя не засчитывается.", [
		["Ещё раз", true, func(): _start(race.diff, race.tyre)], ["Меню", false, func(): _show_menu()]], Color("#ff5a4a"))

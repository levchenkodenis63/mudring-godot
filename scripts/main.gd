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
const Store = preload("res://scripts/store.gd")
const Tracks = preload("res://scripts/tracks.gd")
const GROUND_SHADER = preload("res://shaders/ground.gdshader")
const FAIL_PHOTO = preload("res://img/fail.jpg")     # экран «Потрачено» — фото из веб-версии

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
var store                       # имя игрока и рекорды (store.gd)
var net_label: Label           # строка про общую таблицу на экране итогов
var music: AudioStreamPlayer   # музыка меню и гаража (первый трек из res://music)
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
var dbg_track := ""            # отладка: трасса для автопилота (--track=oval|long|triangle|square|pentagon)


func _ready() -> void:
	_setup_input()
	_build_env()
	sound = Sound.new()
	add_child(sound)
	store = Store.new()
	add_child(store)
	# отладочные запуски (автопилот, снимки экранов, замеры на планшете) не трогают общую таблицу
	if OS.get_cmdline_user_args().size() > 0 or FileAccess.file_exists("user://auto.txt"):
		store.online = false
	_setup_music()
	cam = Camera3D.new()
	cam.fov = 46.0
	cam.far = 500.0
	add_child(cam)
	cam.current = true
	_build_ui()
	race = Race.new()
	race.setup("normal", "mudlite", "oval")
	race.screen = "menu"
	hud.race = race
	_build_world()
	if store.player_name == "":
		_ask_name(_show_menu)                   # первый запуск — сначала имя
	else:
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
		if a.begins_with("--track="):
			dbg_track = a.get_slice("=", 1)
		dbg_nobots = dbg_nobots or a == "--nobots"
	_apply_quality(q)
	for a: String in args:
		if a.begins_with("--auto"):
			auto = true
			store.online = false               # тесты не пишут в общую таблицу
			var spec := a.get_slice("=", 1) if a.contains("=") else "normal"
			var parts := spec.split(":")
			_start(parts[0], parts[1] if parts.size() > 1 else "mudlite", dbg_track)
			_go()
		elif a == "--quit":
			auto_quit = true
		elif a.begins_with("--shot="):
			shot_dir = a.get_slice("=", 1)
		elif a.begins_with("--ui="):              # отладка: снимок экрана интерфейса и выход (name|menu|records|records_all)
			_ui_shot(a.get_slice("=", 1))


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
	_music(delta)
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


## музыка меню: первый трек из res://music (в сборке файлы лежат как *.import — имя без суффикса)
func _setup_music() -> void:
	music = AudioStreamPlayer.new()
	music.volume_db = -60.0
	add_child(music)
	var dir := DirAccess.open("res://music")
	if dir == null:
		return
	var names := Array(dir.get_files())
	names.sort()
	for f in names:
		var n: String = f.trim_suffix(".import").trim_suffix(".remap")
		if n.get_extension() in ["mp3", "ogg", "wav"]:
			var st = load("res://music/" + n)
			if st is AudioStream:
				if "loop" in st:
					st.loop = true
				music.stream = st
				print("MUSIC ", n)
				return


## во всех меню играет, в заезде плавно затихает; кнопка «ЗВУК» выключает и её
func _music(delta: float) -> void:
	if music == null or music.stream == null:
		return
	# во всех меню (главное, гараж, «Готов?», итоги и «Потрачено»); в заезде — тишина, только мотор
	var on: bool = race.screen in ["menu", "garage", "ready", "results"] and not sound.synth.muted and not auto
	var target := -7.0 if on else -60.0
	music.volume_db = move_toward(music.volume_db, target, delta * (25.0 if on else 35.0))
	if on and not music.playing:
		music.play()
	elif not on and music.playing and music.volume_db <= -59.0:
		music.stop()


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
	if race.screen == "garage":
		_garage_sync(delta)
		return
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
	var on_straight: bool = not race.ring.is_turn(st["seg"])
	var sts: Array = race.ring.straights()
	for i in sts.size():
		water_mats[i].set_shader_parameter("wake", wk if (on_straight and sts[i] == race.lane) else Vector4.ZERO)


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
	# вода и столбики лебёдки — на каждой прямой (у прямой своя трасса core.make_straight)
	for sg in ring.straights():
		var tr: Dictionary = ring.seg_track(sg)
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
		_lane_props(tr, sg)
	_start_arch(ring, ring.seg_track(0))
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
	# квадроциклы: сгенерированные модели раздаются случайно (каждая поровну), повтор модели — со сдвигом оттенка
	var nm: int = Quad.gen_count()
	var pick: Array = []
	for i in race.bots.size() + 1:
		pick.append(i % nm if nm > 0 else -1)
	pick.shuffle()
	var car := int(store.data["car"])                 # выбор в гараже: модель игрока — первой
	if car >= 0 and car < nm:
		var j := pick.find(car)
		pick[j] = pick[0]
		pick[0] = car
	var used := {}                                     # модель → занятые оттенки: соперник не совпадёт с игроком
	var hues: Array = []
	for i in pick.size():
		var m: int = pick[i]
		var h := 0.0
		if i == 0 and car >= 0:
			h = float(store.data["car_hue"])
		else:
			for c in [0.0, 0.5, 0.25, 0.75, 0.15, 0.85]:
				h = c
				var free := true
				for u in used.get(m, []):
					if absf(fposmod(u - c + 0.5, 1.0) - 0.5) < 0.1:
						free = false
				if free:
					break
		used[m] = used.get(m, []) + [h]
		hues.append(h)
	me_quad = Quad.new()
	me_quad.build(0, false, pick[0], hues[0])
	world.add_child(me_quad)
	bot_quads.clear()
	for i in race.bots.size():
		var q = Quad.new()
		q.build(race.bots[i]["look"], true, pick[i + 1], hues[i + 1])
		world.add_child(q)
		bot_quads.append(q)


## рельеф колеи — замкнутая лента вдоль кольца: профиль поперёк (Ring.ZS) в каждом отсчёте
func _ring_mesh(ring, rows: Array) -> ArrayMesh:
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
		var inb: bool = not ring.is_turn(sg) and MR.bath_at(ring.seg_track(sg), x) >= 0
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
	var c: Vector3 = ring.centroid + y
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
## столбики лебёдки на прямой sg (трасса прямой tr; ключ столбика — участок и номер стенки)
func _lane_props(tr: Dictionary, sg: int) -> void:
	var ring = race.ring
	var l := sg
	var lane: Dictionary = tr["lanes"][0]
	var yellow := _flat(Color("#f2c418"))
	var black := _flat(Color("#1b1b20"))
	for sp in tr["winches"][0]:
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
func _overlay(title: String, sub: String, buttons: Array, title_col := Color.WHITE, extra: Control = null, left: Control = null, right: Control = null, photo: Texture2D = null) -> void:
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
	if photo != null:                                  # фото сверху во всю ширину панели (как в веб-версии)
		var tr := TextureRect.new()
		tr.texture = photo
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		tr.custom_minimum_size = Vector2(560, 560.0 * photo.get_height() / photo.get_width())
		box.add_child(tr)
	var t := Label.new()
	t.text = title
	t.add_theme_font_size_override("font_size", 52)
	t.add_theme_color_override("font_color", title_col)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if left != null or right != null:
		# строка заголовка: кнопка слева, название, кнопка справа (пустые места — для симметрии)
		var head := HBoxContainer.new()
		head.add_theme_constant_override("separation", 18)
		t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		for c in [left, t, right]:
			if c == null:
				c = Control.new()
				c.custom_minimum_size = Vector2(200, 0)
			head.add_child(c)
		box.add_child(head)
	else:
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
	if extra != null:
		box.add_child(extra)
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


## небольшая кнопка для строки заголовка
func _small_btn(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(200, 52)
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.add_theme_font_size_override("font_size", 20)
	b.add_theme_stylebox_override("normal", _style(Color("#3a3a42"), 12))
	b.add_theme_stylebox_override("hover", _style(Color("#46464f"), 12))
	b.add_theme_stylebox_override("pressed", _style(Color("#2c2c33"), 12))
	b.pressed.connect(cb)
	return b


func _hide_overlay() -> void:
	if overlay != null:
		overlay.queue_free()
		overlay = null


func _show_menu() -> void:
	race.screen = "menu"
	var d: String = store.data["diff"]
	var car := int(store.data["car"])
	var setup := "Уровень: %s%s · модель: %s" % [Race.DIFFNAME.get(d, "Любители"),
		(" · резина " + MR.TYRES[store.data["tyre"]]["name"]) if d == "extreme" else "",
		"случайная" if car < 0 else _car_name(car)]
	_overlay("MUD RING 3D", setup + "\n\nДержи ГАЗ (кнопка справа, любое место экрана или пробел) — стрелка тахометра в зелёной зоне. У крутой стенки загорится ЛЕБЁДКА (кнопка слева или E).", [
		["СТАРТ", true, func(): _start(store.data["diff"], store.data["tyre"] if store.data["diff"] == "extreme" else "mudlite")],
		["Гараж", false, func(): _show_garage()],
		["Трасса: " + ("случайная" if store.data["track"] == "random" else Tracks.by_id(store.data["track"])["name"]), false, func(): _show_tracks()],
		["Результаты", false, func(): _show_records(store.data["track"] if store.data["track"] != "random" else "oval", store.data["diff"], "mine")],
	], Color("#ffd23e"), null,
		_small_btn(store.player_name if store.player_name != "" else "Указать имя", func(): _ask_name(_show_menu)),
		null if OS.has_feature("ios") else _small_btn("Выход", func(): get_tree().quit()))   # iOS запрещает приложению закрываться самому
	if not auto:
		store.sync()                            # дослать результаты, не ушедшие без сети


## track — id трассы; пусто — из настроек (выбранная или случайная)
func _start(diff: String, tyre: String, track := "") -> void:
	race.setup(diff, tyre, track if track != "" else store.data["track"])
	race.name = store.player_name if store.player_name != "" else "ВЫ"
	_build_world()
	cam_s = race.progress(race.st, race.me) + race.ring.lap_pos(0, 0.0)
	acc = 0.0
	var r = race.me
	var nw := 0
	for sg in race.ring.straights():
		nw += race.ring.seg_track(sg)["winches"][0].size()
	var sub := "Трасса «%s» · %s%s · ты в сетке %d-м · лебёдок за заезд: %d.\nГаз только после зелёного: фальстарт +2.00 с." % [
		race.ring.def["name"], Race.DIFFNAME[diff], (" · резина " + r.tyre["name"]) if r.tyre != null else "", race.grid_slot + 1,
		nw * Race.LAPS]
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
	var best: float = race.laps.min()
	var rank: int = 0 if auto else store.add(race.diff, race.track_id, r.time + race.pen, best, place)
	sub += "\n\n" + ("🏆 Личный рекорд: «%s», %s!" % [race.ring.def["name"], Race.DIFFNAME[race.diff]] if rank == 1 else "Твой %d-й результат: «%s», %s." % [rank, race.ring.def["name"], Race.DIFFNAME[race.diff]])
	net_label = Label.new()
	net_label.add_theme_font_size_override("font_size", 20)
	net_label.add_theme_color_override("font_color", Color("#ffd23e"))
	net_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	net_label.text = "Общая таблица…" if store.online else ""
	_overlay(title, sub, [["Ещё раз", true, func(): _start(race.diff, race.tyre, race.track_id)], ["Рекорды", false, func(): _show_records(race.track_id, race.diff, "all")],
		["Меню", false, func(): _show_menu()]], col, net_label)
	store.sync(_on_synced.bind(net_label))


func _on_synced(res: Dictionary, label: Label) -> void:
	if not is_instance_valid(label):
		return
	if res.get("ok", false):
		label.text = "Общая таблица: %d-е место на этой трассе и уровне" % res.get("rank", 0)
	elif res.get("error", "") == "offline":
		label.text = ""
	else:
		label.text = "Нет связи с общей таблицей — результат отправится позже"


# ---------- гараж: выбор модели и окраски, модель вращается на площадке ----------
const GARAGE_AT := Vector3(-2000, 0, 0)            # далеко от трассы — там пусто
const CAR_NAMES := ["«Болотник»", "«Триколор»", "«Песчаник»", "Модель 4", "Модель 5"]
const PAINTS := [0.0, 0.15, 0.33, 0.5, 0.66, 0.83]   # сдвиги оттенка
var garage: Node3D
var garage_car: Node3D
var garage_ui: Control
var garage_label: Label
var g_model := 0
var g_hue := 0.0
var g_random := false
var g_turn := 0.0
var g_diff := "normal"
var g_tyre := "mudlite"
var g_diff_btns := {}
var g_tyre_btns := {}
var g_tyre_box: Control
var g_tyre_info: Label
const TYRE_INFO := {"mudlite": "MudLite — зелёная зона шире, в воде на 8 % медленнее.",
	"assassinator": "Assassinator — в воде на 8 % быстрее, лебёдка быстрее, зона уже; два заглоха подряд в воде ломают привод."}


func _car_name(m: int) -> String:
	return CAR_NAMES[m] if m < CAR_NAMES.size() else "Модель %d" % (m + 1)


func _show_garage() -> void:
	_hide_overlay()
	race.screen = "garage"
	var nm: int = Quad.gen_count()
	g_random = int(store.data["car"]) < 0
	g_model = clampi(int(store.data["car"]), 0, maxi(nm - 1, 0))
	g_hue = float(store.data["car_hue"])
	g_diff = store.data["diff"]
	g_tyre = store.data["tyre"]
	garage = Node3D.new()
	garage.position = GARAGE_AT
	add_child(garage)
	var plat := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 2.6
	cm.bottom_radius = 2.8
	cm.height = 0.2
	cm.radial_segments = 48
	plat.mesh = cm
	plat.position = Vector3(0, -0.1, 0)
	plat.material_override = _flat(Color("#2a2b30"))
	garage.add_child(plat)
	var floor := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(80, 80)
	floor.mesh = pm
	floor.position = Vector3(0, -0.2, 0)
	floor.material_override = _flat(Color("#4a4c50"))
	garage.add_child(floor)
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 2.55
	tm.outer_radius = 2.65
	tm.rings = 48
	ring.mesh = tm
	ring.position = Vector3(0, 0.0, 0)
	ring.material_override = _flat(Color("#f2c418"), true)
	garage.add_child(ring)
	var lamp := OmniLight3D.new()
	lamp.position = Vector3(2.5, 3.5, 3.0)
	lamp.omni_range = 12.0
	lamp.light_energy = 2.0
	garage.add_child(lamp)
	_garage_ui()
	_garage_car()


func _garage_car() -> void:
	if garage_car != null:
		garage_car.queue_free()
	garage_car = Quad.new()
	garage_car.build(0, false, g_model, g_hue)
	garage.add_child(garage_car)
	garage_car.rotation.y = g_turn
	var nm: int = Quad.gen_count()
	garage_label.text = "СЛУЧАЙНАЯ МОДЕЛЬ" if g_random else "%s  ·  %d / %d" % [_car_name(g_model), g_model + 1, nm]


func _garage_sync(delta: float) -> void:
	g_turn += delta * 0.45
	if garage_car != null:
		garage_car.rotation.y = g_turn
	cam.global_position = GARAGE_AT + Vector3(4.9, 1.6, 4.9)
	cam.look_at(GARAGE_AT + Vector3(0, -0.15, 0), Vector3.UP)      # точка ниже модели — модель выше в кадре, над панелью


func _garage_ui() -> void:
	garage_ui = Control.new()
	garage_ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	garage_ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(garage_ui)
	var title := Label.new()
	title.text = "ГАРАЖ"
	title.add_theme_font_size_override("font_size", 52)
	title.add_theme_color_override("font_color", Color("#ffd23e"))
	title.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
	title.add_theme_constant_override("outline_size", 10)
	title.position = Vector2(40, 24)
	garage_ui.add_child(title)
	# уровни соперников — сверху в одну строку
	var top := HBoxContainer.new()
	top.alignment = BoxContainer.ALIGNMENT_CENTER
	top.add_theme_constant_override("separation", 12)
	top.anchor_left = 0.5
	top.anchor_right = 0.5
	top.grow_horizontal = Control.GROW_DIRECTION_BOTH
	top.offset_top = 22
	garage_ui.add_child(top)
	g_diff_btns.clear()
	for d in ["easy", "normal", "hard", "extreme"]:
		var b := _gbtn(Race.DIFFNAME[d], Color("#3a3a42"), func(): _garage_diff(d), Vector2(170, 64))
		g_diff_btns[d] = b
		top.add_child(b)
	var bar := PanelContainer.new()
	var ps := _style(Color(0.08, 0.08, 0.09, 0.85), 22)
	bar.add_theme_stylebox_override("panel", ps)
	bar.anchor_left = 0.5
	bar.anchor_right = 0.5
	bar.anchor_top = 1.0
	bar.anchor_bottom = 1.0
	bar.grow_horizontal = Control.GROW_DIRECTION_BOTH
	bar.grow_vertical = Control.GROW_DIRECTION_BEGIN
	bar.offset_bottom = -20
	garage_ui.add_child(bar)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	bar.add_child(box)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 16)
	box.add_child(row)
	row.add_child(_gbtn("‹", Color("#3a3a42"), func(): _garage_step(-1), Vector2(90, 70)))
	garage_label = Label.new()
	garage_label.add_theme_font_size_override("font_size", 30)
	garage_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	garage_label.custom_minimum_size = Vector2(420, 0)
	row.add_child(garage_label)
	row.add_child(_gbtn("›", Color("#3a3a42"), func(): _garage_step(1), Vector2(90, 70)))
	var paints := HBoxContainer.new()
	paints.alignment = BoxContainer.ALIGNMENT_CENTER
	paints.add_theme_constant_override("separation", 12)
	box.add_child(paints)
	for h in PAINTS:
		# образец цвета: «основной» красный пластик модели после сдвига оттенка
		var sw := _gbtn("", Color.from_hsv(fposmod(0.0 + h, 1.0), 0.7, 0.85), func(): _garage_paint(h), Vector2(64, 50))
		paints.add_child(sw)
	# резина — только для Экстрима, под цветами
	var tb := VBoxContainer.new()
	tb.add_theme_constant_override("separation", 6)
	box.add_child(tb)
	g_tyre_box = tb
	var trow := HBoxContainer.new()
	trow.alignment = BoxContainer.ALIGNMENT_CENTER
	trow.add_theme_constant_override("separation", 12)
	tb.add_child(trow)
	g_tyre_btns.clear()
	for t in ["mudlite", "assassinator"]:
		var b := _gbtn(MR.TYRES[t]["name"], Color("#3a3a42"), func(): _garage_tyre(t), Vector2(230, 60))
		g_tyre_btns[t] = b
		trow.add_child(b)
	g_tyre_info = Label.new()
	g_tyre_info.add_theme_font_size_override("font_size", 18)
	g_tyre_info.add_theme_color_override("font_color", Color(1, 1, 1, 0.8))
	g_tyre_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	g_tyre_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	g_tyre_info.custom_minimum_size = Vector2(620, 0)
	tb.add_child(g_tyre_info)
	var acts := HBoxContainer.new()
	acts.alignment = BoxContainer.ALIGNMENT_CENTER
	acts.add_theme_constant_override("separation", 14)
	box.add_child(acts)
	acts.add_child(_gbtn("ГОТОВО", Color("#e0b418"), func(): _garage_done(), Vector2(240, 70), true))
	acts.add_child(_gbtn("Случайная модель", Color("#3a3a42"), func(): _garage_random(), Vector2(280, 70)))
	_garage_marks()


func _gbtn(text: String, col: Color, cb: Callable, size: Vector2, dark_text := false) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = size
	b.add_theme_font_size_override("font_size", 30)
	b.add_theme_stylebox_override("normal", _style(col, 14))
	b.add_theme_stylebox_override("hover", _style(col.lightened(0.12), 14))
	b.add_theme_stylebox_override("pressed", _style(col.darkened(0.15), 14))
	if dark_text:
		for k in ["font_color", "font_hover_color", "font_pressed_color"]:
			b.add_theme_color_override(k, Color("#17171b"))
	b.pressed.connect(cb)
	return b


func _garage_step(d: int) -> void:
	var nm: int = Quad.gen_count()
	if nm == 0:
		return
	g_random = false
	g_model = posmod(g_model + d, nm)
	g_hue = 0.0
	_garage_car()


func _garage_paint(h: float) -> void:
	g_random = false
	g_hue = h
	_garage_car()


## подсветка выбранного уровня и резины; резина видна только на Экстриме
func _garage_marks() -> void:
	for d in g_diff_btns:
		_mark(g_diff_btns[d], d == g_diff)
	for t in g_tyre_btns:
		_mark(g_tyre_btns[t], t == g_tyre)
	g_tyre_box.visible = g_diff == "extreme"
	g_tyre_info.text = TYRE_INFO[g_tyre]


func _mark(b: Button, on: bool) -> void:
	var col := Color("#e0b418") if on else Color("#3a3a42")
	b.add_theme_stylebox_override("normal", _style(col, 14))
	b.add_theme_stylebox_override("hover", _style(col.lightened(0.12), 14))
	for k in ["font_color", "font_hover_color", "font_pressed_color"]:
		b.add_theme_color_override(k, Color("#17171b") if on else Color.WHITE)


func _garage_diff(d: String) -> void:
	g_diff = d
	_garage_marks()


func _garage_tyre(t: String) -> void:
	g_tyre = t
	_garage_marks()


func _garage_random() -> void:
	g_random = true
	_garage_car()


func _garage_done() -> void:
	store.set_garage(-1 if g_random else g_model, 0.0 if g_random else g_hue, g_diff, g_tyre)
	_garage_close()


func _garage_close() -> void:
	if garage != null:
		garage.queue_free()
		garage = null
		garage_car = null
	if garage_ui != null:
		garage_ui.queue_free()
		garage_ui = null
	_build_world()                                      # квадроциклы в меню — уже с выбранной моделью
	_show_menu()


## имя игрока: поле ввода (на телефоне откроется клавиатура)
func _ask_name(next: Callable) -> void:
	var le := LineEdit.new()
	le.text = store.player_name
	le.placeholder_text = "Имя (2–14 букв)"
	le.max_length = 14
	le.alignment = HORIZONTAL_ALIGNMENT_CENTER
	le.add_theme_font_size_override("font_size", 34)
	le.custom_minimum_size = Vector2(420, 70)
	var done := func() -> void:
		var n: String = Store.clean_name(le.text, "")
		if n == "":
			le.text = ""
			le.placeholder_text = "Нужно хотя бы 2 буквы"
			return
		store.player_name = n
		next.call()
	le.text_submitted.connect(func(_t): done.call())
	_overlay("ИМЯ ИГРОКА", "", [["Готово", true, done]], Color("#ffd23e"), le)
	le.call_deferred("grab_focus")


## результаты: трасса, уровень и источник (mine — свои на телефоне, all — общая таблица)
func _show_records(track: String, diff: String, src: String) -> void:
	if not track in Tracks.ids():
		track = Tracks.ids()[0]
	var ids: Array = Tracks.ids()
	var next_track: String = ids[(ids.find(track) + 1) % ids.size()]
	var tabs: Array = [["Трасса: %s ›" % Tracks.by_id(track)["name"], false, func(): _show_records(next_track, diff, src)]]
	for d in ["easy", "normal", "hard", "extreme"]:
		tabs.append([Race.DIFFNAME[d], d == diff, func(): _show_records(track, d, src)])
	tabs.append(["Общие" if src == "mine" else "Мои", false, func(): _show_records(track, diff, "all" if src == "mine" else "mine")])
	tabs.append(["Назад", false, func(): _show_menu()])
	var title := "РЕЗУЛЬТАТЫ · " + ("МОИ" if src == "mine" else "ОБЩИЕ")
	var head := "Трасса «%s» · %s\n\n" % [Tracks.by_id(track)["name"], Race.DIFFNAME[diff]]
	if src == "mine":
		_overlay(title, head + _records_text(store.local_top(diff, track, 10), false, null), tabs, Color("#ffd23e"))
		return
	_overlay(title, head + "Загрузка…", tabs, Color("#ffd23e"))
	var shown := overlay
	store.fetch(diff, track, func(res: Dictionary) -> void:
		if overlay != shown or not is_instance_valid(shown):
			return                          # уже ушли с этого экрана
		var text: String = "Нет связи с общей таблицей." if not res.get("ok", false) else _records_text(res.get("top", []), true, res.get("mine")) + "\n\nВсего гонщиков: %d" % res.get("count", 0)
		_overlay(title, head + text, tabs, Color("#ffd23e")))


func _records_text(list: Array, online: bool, mine) -> String:
	if list.is_empty():
		return "Пока пусто — проедь заезд!"
	var lines: PackedStringArray = []
	for i in list.size():
		var r: Dictionary = list[i]
		var me: bool = r.get("me", false)
		lines.append("%s%d.  %s  %.2f" % ["▶ " if me else "", i + 1, r.get("n", "?") if online else r.get("n", ""), float(r.get("t", 0.0))])
	if mine != null and typeof(mine) == TYPE_DICTIONARY:
		lines.append("…")
		lines.append("▶ %d.  %s  %.2f" % [int(mine.get("rank", 0)), mine.get("n", ""), float(mine.get("t", 0.0))])
	return "\n".join(lines)


# ---------- выбор трассы: карточки со схемой ----------
## схема трассы: контур кольца в плане, вписанный в прямоугольник; жёлтая точка — старт
class TrackMap extends Control:
	var pts := PackedVector2Array()
	var col := Color.WHITE

	func _draw() -> void:
		if pts.size() < 2:
			return
		var lo := pts[0]
		var hi := pts[0]
		for p in pts:
			lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
			hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
		var sz := hi - lo
		var k := minf((size.x - 16) / maxf(sz.x, 1.0), (size.y - 16) / maxf(sz.y, 1.0))
		var o := (size - sz * k) / 2.0
		var q := PackedVector2Array()
		for p in pts:
			q.append(o + (p - lo) * k)
		q.append(q[0])
		draw_polyline(q, Color(0.2, 0.17, 0.13), 9.0, true)
		draw_polyline(q, col, 4.0, true)
		draw_circle(q[0], 6.0, Color("#f2c418"))


static var _outlines := {}


func _track_outline(id: String) -> PackedVector2Array:
	if not _outlines.has(id):
		_outlines[id] = Ring.new(Tracks.by_id(id)).outline(4.0)
	return _outlines[id]


func _show_tracks() -> void:
	var cur: String = store.data["track"]
	var cards := HFlowContainer.new()
	cards.alignment = FlowContainer.ALIGNMENT_CENTER
	cards.add_theme_constant_override("h_separation", 12)
	cards.add_theme_constant_override("v_separation", 12)
	cards.custom_minimum_size = Vector2(760, 0)
	for t in Tracks.TRACKS + [{"id": "random", "name": "Случайная"}]:
		var id: String = t["id"]
		var b := Button.new()
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(236, 190)
		var col := Color("#e0b418") if id == cur else Color("#3a3a42")
		b.add_theme_stylebox_override("normal", _style(col, 14))
		b.add_theme_stylebox_override("hover", _style(col.lightened(0.12), 14))
		b.add_theme_stylebox_override("pressed", _style(col.darkened(0.15), 14))
		b.pressed.connect(func(): _pick_track(id))
		var lab := Label.new()
		lab.add_theme_font_size_override("font_size", 22)
		lab.add_theme_color_override("font_color", Color("#17171b") if id == cur else Color.WHITE)
		lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lab.position = Vector2(0, 142)
		lab.size = Vector2(236, 44)
		lab.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if id == "random":
			lab.text = "Случайная"
			var q := Label.new()
			q.text = "?"
			q.add_theme_font_size_override("font_size", 90)
			q.add_theme_color_override("font_color", Color("#17171b") if id == cur else Color("#f2c418"))
			q.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			q.position = Vector2(0, 10)
			q.size = Vector2(236, 130)
			q.mouse_filter = Control.MOUSE_FILTER_IGNORE
			b.add_child(q)
		else:
			var baths := 0
			for st in t["straights"]:
				baths += st["baths"]
			var m := TrackMap.new()
			m.pts = _track_outline(id)
			m.col = Color("#17171b") if id == cur else Color("#d8c9a8")
			m.position = Vector2(10, 8)
			m.size = Vector2(216, 132)
			m.mouse_filter = Control.MOUSE_FILTER_IGNORE
			b.add_child(m)
			lab.text = "%s · %d ванн" % [t["name"], baths]
		b.add_child(lab)
		cards.add_child(b)
	_overlay("ТРАССА", "", [["Назад", false, func(): _show_menu()]], Color("#ffd23e"), cards)


func _pick_track(id: String) -> void:
	store.data["track"] = id
	store.player_name = store.player_name              # сохранить настройки
	_show_menu()


func _ui_shot(what: String) -> void:
	match what:
		"name": _ask_name(_show_menu)
		"menu": _show_menu()
		"records": _show_records("oval", "normal", "mine")
		"records_all": _show_records("oval", "normal", "all")
		"tracks": _show_tracks()
		"garage": _show_garage()
		"fail":
			race.fail_why = "break"
			_show_fail()
		"garage_x":
			_show_garage()
			_garage_diff("extreme")
	await get_tree().create_timer(2.5).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("%s/ui_%s.png" % [shot_dir if shot_dir != "" else ".", what])
	get_tree().quit()


func _auto_done() -> void:
	if not auto:
		return
	var r = race.me
	print("AUTO %s %s %s: %s time=%.2f place=%d winches=%d glides=%d floods=%d clean=%d laps=%s" % [race.track_id, race.diff, race.tyre, race.fail_why if race.fail_why != "" else "finish",
		r.time + race.pen, race.place, r.winches, r.glides, r.floods, r.clean, str(race.laps)])
	for e in race.standings():
		print("  ", e["name"], " ", e["total"], " ", e["out"])
	if auto_quit:
		get_tree().quit()


func _show_fail() -> void:
	# на фото уже написано «потрачено» — заголовком причина схода
	_overlay(Race.FAILNAME.get(race.fail_why, "ПОТРАЧЕНО"), "Время не засчитывается.", [
		["Ещё раз", true, func(): _start(race.diff, race.tyre, race.track_id)], ["Меню", false, func(): _show_menu()]], Color("#ff6a55"),
		null, null, null, FAIL_PHOTO)

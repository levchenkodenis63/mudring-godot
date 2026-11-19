extends RefCounted
## Окружение кольца по фото соревнований. Камера стоит снаружи кольца и смотрит внутрь, поэтому:
## снаружи у колеи — только низкая трава (передний план), дальше за камерой — опушка и лес (их видно за
## противоположной прямой); внутри кольца — поле: трава, шатры у старта, флаги и зрители у внутренней ленты,
## немного берёз и кустов в закруглениях. Ленты на кольях — по обе стороны колеи по всему кругу.
## Ассеты — models/env.glb (tools/blender/env.py). Каждый вид — MultiMesh, порезанный на квадраты 40×40 м,
## чтобы камера отсекала невидимое (одна отрисовка на квадрат).

const MR = preload("res://scripts/core.gd")
const Ring = preload("res://scripts/ring.gd")
const ENV_PATH := "res://models/env.glb"
const ENV_SHADER = preload("res://shaders/env.gdshader")
const CHUNK := 40.0

var meshes := {}
var mat: ShaderMaterial
var parent: Node3D
var ring
var rnd := RandomNumberGenerator.new()
var items := {}               # имя ассета → [[Transform3D, Color|null], ...]
var grass_range := 50.0       # трава дальше не рисуется: вдали её изображает шейдер земли


func build(parent_: Node3D, ring_, quality: int) -> void:
	parent = parent_
	ring = ring_
	rnd.seed = 1234
	var scene: PackedScene = load(ENV_PATH)
	var inst := scene.instantiate()
	for n in inst.find_children("*", "MeshInstance3D", true, false):
		meshes[n.name] = (n as MeshInstance3D).mesh
	inst.free()
	mat = ShaderMaterial.new()
	mat.shader = ENV_SHADER
	var dens: float = [0.3, 0.5, 1.0][quality]
	grass_range = [25.0, 32.0, 60.0][quality]
	_along(dens)
	_infield(dens)
	_outside(dens)
	_tape()
	for k in items:
		_place(k, items[k], k == "Person")


func _add(kind: String, pos: Vector3, s: float, yaw: float, custom = null) -> void:
	if not items.has(kind):
		items[kind] = []
	items[kind].append([Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3(s, s, s)), pos), custom])


## точка у кольца: положение на круге s, смещение поперёк dz (плюс — наружу), на поверхности
func _at(s: float, dz: float) -> Vector3:
	var lx: Array = ring.locate(s)
	var f: Array = ring.frame(lx[0], lx[1])
	return (f[0] as Vector3) + (f[2] as Vector3) * dz + Vector3(0, ring.surface_y(lx[0], lx[1], dz) - 0.02, 0)


func _place(mesh_name: String, list: Array, custom := false, material: Material = null) -> void:
	var mesh: Mesh = meshes.get(mesh_name)
	if mesh == null or list.is_empty():
		return
	var grass := mesh_name.begins_with("Grass")
	var size := CHUNK / 2.0 if grass else CHUNK          # трава — куски мельче, чтобы точнее отсекалась по дальности
	var chunks := {}
	for it in list:
		var o: Vector3 = (it[0] as Transform3D).origin
		var k := Vector2i(int(floor(o.x / size)), int(floor(o.z / size)))
		if not chunks.has(k):
			chunks[k] = []
		chunks[k].append(it)
	for k in chunks:
		var part: Array = chunks[k]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = custom
		mm.mesh = mesh
		mm.instance_count = part.size()
		for i in part.size():
			mm.set_instance_transform(i, part[i][0])
			if custom:
				mm.set_instance_custom_data(i, part[i][1])
		var mi := MultiMeshInstance3D.new()
		mi.multimesh = mm
		mi.material_override = material if material != null else mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if grass:
			mi.visibility_range_end = grass_range
		parent.add_child(mi)


## трава на бровках по всему кругу: внутри (фон) — гуще и выше, снаружи (перед камерой) — редкая и низкая;
## флаги и зрители у внутренней ленты на прямых
func _along(dens: float) -> void:
	var s := 0.0
	while s < ring.lap:
		s += rnd.randf_range(0.22, 0.5) / dens
		for side in [-1.0, 1.0]:
			if side > 0.0 and rnd.randf() < 0.55:
				continue
			var a := rnd.randf_range(Ring.HALF + 0.35, Ring.EDGE + 1.2)
			var kind := "Grass" if rnd.randf() < 0.55 else "GrassDry"
			var sc := rnd.randf_range(0.7, 1.4)
			if side < 0.0 and rnd.randf() < 0.3:
				kind = "GrassTall"
			if side > 0.0:
				sc = rnd.randf_range(0.4, 0.7)
			_add(kind, _at(s, a * side), sc, rnd.randf() * TAU)
	var jackets := [Color("#2d66cc"), Color("#d43a30"), Color("#1b1b20"), Color("#3c5a2a"), Color("#e0b418"), Color("#5a5f6a"), Color("#e8792a"), Color("#f2f2ee")]
	for sg in ring.straights():
		var x := Ring.XS + 8.0
		var i := 0
		while x < ring.seg_end(sg) - 4.0:
			var f: Array = ring.frame(sg, x)
			var p: Vector3 = f[0]
			var t: Vector3 = f[1]
			var n: Vector3 = f[2]
			if i % 2 == 0:
				_add("FlagRed" if (i / 2) % 2 == 0 else "FlagBlack", p - n * (Ring.EDGE + 1.6) + Vector3(0, -0.04, 0), 1.0, Ring.yaw_of(t) + rnd.randf_range(-0.3, 0.3))
			for k in rnd.randi_range(1, 4):
				var pp := p - n * rnd.randf_range(Ring.EDGE + 1.2, Ring.EDGE + 3.5) + t * rnd.randf_range(-2.0, 2.0) + Vector3(0, -0.04, 0)
				var j: Color = jackets[rnd.randi() % jackets.size()]
				_add("Person", pp, rnd.randf_range(0.92, 1.08), Ring.yaw_of(n) + rnd.randf_range(-0.6, 0.6), Color(j.r, j.g, j.b, 1.0))
			x += rnd.randf_range(9.0, 16.0)
			i += 1


## поле внутри кольца: трава, деревья и кусты в «углах» (у центров поворотов), шатры у старта
func _infield(dens: float) -> void:
	var lim := Ring.EDGE + 0.8
	var poly: PackedVector2Array = ring.outline(4.0)
	var lo := Vector2(1e9, 1e9)
	var hi := Vector2(-1e9, -1e9)
	for q in poly:
		lo = Vector2(minf(lo.x, q.x), minf(lo.y, q.y))
		hi = Vector2(maxf(hi.x, q.x), maxf(hi.y, q.y))
	var n := int((hi.x - lo.x) * (hi.y - lo.y) * 0.5 * dens)
	for i in n:
		var p := Vector3(rnd.randf_range(lo.x, hi.x), -0.04, rnd.randf_range(lo.y, hi.y))
		if not ring.inside(p, lim):
			continue
		var kind: String = ["Grass", "GrassDry", "GrassDry", "GrassTall"][rnd.randi() % 4]
		_add(kind, p, rnd.randf_range(0.8, 1.5), rnd.randf() * TAU)
	# берёзы и кусты — у центров поворотов, чтобы не закрывать противоположные прямые
	for tc in ring.turn_centers():
		var c: Vector3 = tc[0]
		for k in 4:
			var a := rnd.randf() * TAU
			var p := c + Vector3(cos(a), 0, sin(a)) * rnd.randf_range(0.0, maxf(1.0, tc[1] - Ring.EDGE - 3.0))
			p.y = -0.04
			if ring.inside(p, Ring.EDGE + 2.5):
				_add("Birch" if k % 2 == 0 else "Bush", p, rnd.randf_range(0.8, 1.2), rnd.randf() * TAU)
	# шатры у старта, внутри кольца
	for k in 3:
		var f: Array = ring.frame(0, 4.0 + k * 4.4)
		var p: Vector3 = (f[0] as Vector3) - (f[2] as Vector3) * (Ring.EDGE + 6.5 + (k % 2) * 1.2)
		p.y = -0.04
		if ring.inside(p, Ring.EDGE + 2.0):
			_add("Tent", p, 1.0, Ring.yaw_of(f[1]) + rnd.randf_range(-0.1, 0.1))


## снаружи кольца: трава, опушка, хвойный лес
func _outside(dens: float) -> void:
	var s := 0.0
	while s < ring.lap:
		s += rnd.randf_range(0.5, 1.1) / dens
		var a := rnd.randf_range(Ring.EDGE + 0.4, Ring.EDGE + 16.0)
		var near := a < Ring.EDGE + 3.0
		var kind: String
		if near:
			kind = "Grass" if rnd.randf() < 0.6 else "GrassDry"
		else:
			kind = ["Grass", "GrassDry", "GrassTall"][rnd.randi() % 3]
		_add(kind, _at(s, a), rnd.randf_range(0.4, 0.7) if near else rnd.randf_range(0.8, 1.5), rnd.randf() * TAU)
	s = 0.0
	while s < ring.lap:
		s += rnd.randf_range(6.0, 11.0)
		_add("Birch" if rnd.randf() < 0.6 else "Oak", _at(s, rnd.randf_range(13.0, 28.0)), rnd.randf_range(0.8, 1.25), rnd.randf() * TAU)
		if rnd.randf() < 0.5:
			_add("Bush", _at(s + rnd.randf_range(-2.0, 2.0), rnd.randf_range(9.0, 13.0)), rnd.randf_range(0.8, 1.5), rnd.randf() * TAU)
	s = 0.0
	while s < ring.lap:
		s += rnd.randf_range(3.0, 5.0)
		for k in 2:
			_add("Pine", _at(s + rnd.randf_range(-1.5, 1.5), rnd.randf_range(32.0, 60.0)), rnd.randf_range(1.2, 2.0), rnd.randf() * TAU)


## лента на кольях по обе стороны колеи: красно-белые отрезки по 0.5 м с провисом, колья каждые 4 м
func _tape() -> void:
	var red := []
	var white := []
	for dz in [-(Ring.EDGE + 0.45), Ring.EDGE + 0.45]:
		# ломаная по кривой со смещением: шаг — по длине именно этой кривой (внутри поворота она короче)
		var pts: Array = []
		var s := 0.0
		while s <= ring.lap:
			var lx: Array = ring.locate(s)
			var f: Array = ring.frame(lx[0], lx[1])
			pts.append((f[0] as Vector3) + (f[2] as Vector3) * dz)
			s += 0.25
		var acc := 0.0
		var next_seg := 0.0
		var next_stake := 0.0
		var k := 0
		for i in range(1, pts.size()):
			var a: Vector3 = pts[i - 1]
			var b: Vector3 = pts[i]
			acc += a.distance_to(b)
			if acc >= next_stake:
				_add("Stake", b + Vector3(0, -0.04, 0), 1.0, rnd.randf_range(-0.2, 0.2))
				next_stake += 4.0
			if acc >= next_seg:
				var sag := 0.07 * sin(PI * fmod(acc, 4.0) / 4.0)
				var tr := Transform3D(Basis(Vector3.UP, Ring.yaw_of(b - a)), b + Vector3(0, 0.88 - sag, 0))
				(red if k % 2 == 0 else white).append([tr, null])
				k += 1
				next_seg += 0.5
	var bm := BoxMesh.new()
	bm.size = Vector3(0.5, 0.05, 0.008)
	meshes["_tape"] = bm
	for pair in [[red, Color("#d8352a")], [white, Color("#f2f2ee")]]:
		var m := StandardMaterial3D.new()
		m.albedo_color = pair[1]
		m.roughness = 0.6
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		_place("_tape", pair[0], false, m)

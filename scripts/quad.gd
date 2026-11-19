extends Node3D
## Квадроцикл с гонщиком из примитивов (заглушка до настоящей модели из Blender).
## Начало координат — точка на земле под центром, нос смотрит в +X.
## sync() каждый кадр переносит состояние гонщика из ядра: положение, наклон, колёса, грязь, брызги.

const MR = preload("res://scripts/core.gd")

## расцветки: корпус, акцент, джерси, шлем
## расцветки команд (по фото соревнований): панели пластика, акцент (кенгурятник, пружины, бэдлоки, защиты рук), куртка, шлем
const LOOKS := [
	[Color("#e0b418"), Color("#f2c418"), Color("#2b2d33"), Color("#17171b")],   # игрок: чёрно-жёлтый
	[Color("#e3e0d5"), Color("#ff6a1f"), Color("#2d66cc"), Color("#f6f4ec")],   # белый с оранжевым
	[Color("#b3261e"), Color("#d43a30"), Color("#1b1b20"), Color("#d43a30")],   # чёрно-красный
	[Color("#5a6a3a"), Color("#c9a227"), Color("#4b5a32"), Color("#2b2d22")],   # камуфляж
	[Color("#6c2a72"), Color("#c063cb"), Color("#3a2a5c"), Color("#e8dceb")],   # фиолетовый
	[Color("#1f4fa8"), Color("#ffd23e"), Color("#1f4fa8"), Color("#ffd23e")],   # синий с жёлтым
	[Color("#3c3c42"), Color("#7dffa8"), Color("#3c3c42"), Color("#7dffa8")],   # чёрный с салатовым
	[Color("#d9762b"), Color("#f2f2f2"), Color("#d43a30"), Color("#f2f2f2")],   # оранжевый
]
const MUD := Color(0.30, 0.23, 0.14)
static var blob_shadows := false    # пятно тени вместо настоящих теней (низкое/среднее качество)
const MODEL_PATH := "res://models/atv.glb"
# сгенерированные модели (amiodel.ru → tools/blender/import_gen.py); если их нет — своя модель MODEL_PATH
const GEN_PATHS := ["res://models/atv_gen.glb", "res://models/atv_gen_2.glb", "res://models/atv_gen_3.glb"]
const TEX_SHADER = preload("res://shaders/atv_tex.gdshader")
const LOD_DIST := 25.0          # боты: вблизи — *_LOD1, дальше — *_LOD2; игрок — всегда полная модель
const ATV_SHADER = preload("res://shaders/atv.gdshader")
static var _models := {}
static var particle_scale := 1.0   # меньше брызг на слабых устройствах (main._apply_quality)

var ghost := false
var dirt := 0.0
var wheels: Array = []
var mat: StandardMaterial3D     # запасная модель из примитивов: один материал, цвета в вершинах
var smat: ShaderMaterial        # модель из Blender: перекраска и грязь в шейдере
var rider: Node3D
var blob: MeshInstance3D
var spray: GPUParticles3D
var burst: GPUParticles3D
var _alpha := 1.0


## Детали собираются в списки [меш, трансформ, цвет] и сливаются в 6 мешей: корпус, 4 колеса
## (один общий меш), гонщик. Раньше было ~55 узлов на квадроцикл — слабым телефонам тяжело от числа вызовов отрисовки.
## model — номер сгенерированной модели (GEN_PATHS), hue — сдвиг оттенка (повтор модели на трассе)
func build(look: int, ghost_: bool, model := 0, hue := 0.0) -> void:
	ghost = ghost_
	_alpha = 1.0    # боты непрозрачные: прозрачность и дизеринг на телефоне дороги и «шумят»; их разводит по колее main.gd
	var c: Array = LOOKS[look % LOOKS.size()]
	var body: Color = c[0]
	var accent: Color = c[1]
	var jersey: Color = c[2]
	var helmet: Color = c[3]
	var dark := Color("#1c1c20")
	var tyre := Color("#141416")
	var steel := Color("#8a8d93")
	var hw := MR.WB / 2.0
	if not _build_model(c, model, hue):
		_build_primitives(c, body, accent, jersey, helmet, dark, tyre, steel)
	# пятно тени: мягкий тёмный овал под квадроциклом
	blob = MeshInstance3D.new()
	var bp := PlaneMesh.new()
	bp.size = Vector2(2.3, 1.4)
	blob.mesh = bp
	var bm := StandardMaterial3D.new()
	bm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	bm.albedo_color = Color(0, 0, 0, 0.45 * _alpha)
	var gt := GradientTexture2D.new()
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.5)
	gt.fill_to = Vector2(1.0, 0.5)
	var gr := Gradient.new()
	gr.set_color(0, Color(1, 1, 1, 1))
	gr.set_color(1, Color(1, 1, 1, 0))
	gt.gradient = gr
	bm.albedo_texture = gt
	blob.material_override = bm
	blob.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	blob.position = Vector3(0, 0.03, 0)
	blob.visible = blob_shadows
	add_child(blob)
	# брызги из-под колёс: постоянный поток и разовый выброс
	if not ghost:
		spray = _particles(90, 0.9, Vector3(-1, 1.3, 0), 28.0, 1.5, 4.5, 0.05)
		spray.position = Vector3(-hw, 0.15, 0)
		burst = _particles(70, 1.1, Vector3(-0.4, 1.0, 0), 55.0, 2.5, 7.0, 0.07)
		burst.position = Vector3(0.4, 0.25, 0)
		burst.one_shot = true
		burst.emitting = false
	else:
		spray = _particles(24, 0.7, Vector3(-1, 1.3, 0), 28.0, 1.2, 3.5, 0.045)
		spray.position = Vector3(-hw, 0.15, 0)



## запасной вариант — квадроцикл из примитивов (если нет models/atv.glb)
func _build_primitives(c: Array, body: Color, accent: Color, jersey: Color, helmet: Color, dark: Color, tyre: Color, steel: Color) -> void:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true
	m.roughness = 0.55
	mat = m
	var wy := MR.WR
	var hw := MR.WB / 2.0
	# корпус
	var P: Array = []
	_box(P, Vector3(1.55, 0.26, 0.62), Vector3(0, wy + 0.18, 0), dark)
	_box(P, Vector3(0.62, 0.20, 1.08), Vector3(hw - 0.05, wy + 0.42, 0), body)      # переднее крыло
	_box(P, Vector3(0.70, 0.20, 1.08), Vector3(-hw + 0.02, wy + 0.42, 0), body)     # заднее крыло
	_box(P, Vector3(0.80, 0.30, 0.66), Vector3(0.10, wy + 0.42, 0), body)           # бак
	_box(P, Vector3(0.75, 0.14, 0.42), Vector3(-0.32, wy + 0.62, 0), dark)          # сиденье
	_box(P, Vector3(0.55, 0.05, 0.95), Vector3(hw + 0.02, wy + 0.56, 0), steel)     # передний багажник
	_box(P, Vector3(0.55, 0.05, 0.95), Vector3(-hw - 0.02, wy + 0.56, 0), steel)    # задний багажник
	_box(P, Vector3(0.10, 0.14, 1.18), Vector3(hw + 0.42, wy + 0.10, 0), steel)     # бампер
	_box(P, Vector3(0.62, 0.06, 0.10), Vector3(0.10, wy + 0.58, 0.30), accent)      # полосы
	_box(P, Vector3(0.62, 0.06, 0.10), Vector3(0.10, wy + 0.58, -0.30), accent)
	_cyl(P, 0.045, 0.9, Vector3(0.28, wy + 0.95, -0.24), Vector3(0, 0, 0.12), dark)  # шноркель
	_cyl(P, 0.06, 0.12, Vector3(0.33, wy + 1.42, -0.24), Vector3.ZERO, accent)
	_cyl(P, 0.025, 0.78, Vector3(0.48, wy + 0.86, 0), Vector3(PI / 2.0, 0, 0), steel)   # руль
	_cyl(P, 0.035, 0.32, Vector3(0.45, wy + 0.70, 0), Vector3(0, 0, -0.35), steel)
	_add_mesh(self, P)
	# колесо: шина, грунтозацепы, диск — один меш на все четыре
	var W: Array = []
	_cyl(W, MR.WR, 0.30, Vector3.ZERO, Vector3(PI / 2.0, 0, 0), tyre, 18)
	for k in 6:
		var ang := k * TAU / 6.0
		_box(W, Vector3(0.10, 0.06, 0.32), Vector3(cos(ang), sin(ang), 0) * (MR.WR - 0.01), Color("#26262a"), ang)
	_cyl(W, 0.2, 0.32, Vector3.ZERO, Vector3(PI / 2.0, 0, 0), accent)
	var wmesh := _merge(W)
	for p in [Vector3(hw, wy, 0.44), Vector3(hw, wy, -0.44), Vector3(-hw, wy, 0.44), Vector3(-hw, wy, -0.44)]:
		var w := MeshInstance3D.new()
		w.mesh = wmesh
		w.material_override = mat
		w.position = p
		add_child(w)
		wheels.append(w)
	# гонщик
	rider = Node3D.new()
	rider.position = Vector3(-0.25, wy + 0.68, 0)
	add_child(rider)
	var R: Array = []
	_box(R, Vector3(0.30, 0.62, 0.42), Vector3(0.12, 0.38, 0), jersey, -0.45)       # торс
	_box(R, Vector3(0.50, 0.16, 0.16), Vector3(0.10, 0.06, 0.15), dark, -0.2)       # бёдра
	_box(R, Vector3(0.50, 0.16, 0.16), Vector3(0.10, 0.06, -0.15), dark, -0.2)
	_box(R, Vector3(0.48, 0.10, 0.10), Vector3(0.48, 0.45, 0.22), jersey, 0.35)     # руки
	_box(R, Vector3(0.48, 0.10, 0.10), Vector3(0.48, 0.45, -0.22), jersey, 0.35)
	var hm := SphereMesh.new()
	hm.radius = 0.17
	hm.height = 0.34
	hm.radial_segments = 12
	hm.rings = 6
	R.append([hm, Transform3D(Basis(), Vector3(0.36, 0.80, 0)), helmet])
	_box(R, Vector3(0.10, 0.08, 0.26), Vector3(0.50, 0.80, 0), dark)                # визор
	_add_mesh(rider, R)



## модель из Blender (tools/blender/atv.py → models/atv.glb): Body, Wheel_FL/FR/RL/RR, Rider.
## Один ShaderMaterial на квадроцикл: перекраска по коду в вершинах и грязь (shaders/atv.gdshader).
static func gen_count() -> int:
	var n := 0
	for p in GEN_PATHS:
		if ResourceLoader.exists(p):
			n += 1
	return n


func _build_model(c: Array, model: int, hue: float) -> bool:
	var gen := model >= 0 and model < GEN_PATHS.size() and ResourceLoader.exists(GEN_PATHS[model])
	var path: String = GEN_PATHS[model] if gen else MODEL_PATH
	if not ResourceLoader.exists(path):
		return false
	if not _models.has(path):
		_models[path] = load(path)
	var inst: Node3D = _models[path].instantiate()
	var sm := ShaderMaterial.new()
	if gen:
		# текстуры — из материала, который импортировал Godot
		var bm: MeshInstance3D = inst.find_child("Body", true, false)
		var std := bm.mesh.surface_get_material(0) as BaseMaterial3D
		sm.shader = TEX_SHADER
		sm.set_shader_parameter("albedo_tex", std.albedo_texture)
		sm.set_shader_parameter("normal_tex", std.normal_texture)
		sm.set_shader_parameter("hue", hue)
	else:
		sm.shader = ATV_SHADER
		sm.set_shader_parameter("paint", c[0])
		sm.set_shader_parameter("accent", c[1])
		sm.set_shader_parameter("jersey", c[2])
		sm.set_shader_parameter("helmet", c[3])
	smat = sm
	var body_mi: MeshInstance3D = null
	for n in ["Body", "Wheel_FL", "Wheel_FR", "Wheel_RL", "Wheel_RR", "Rider"]:
		var mi: MeshInstance3D = inst.find_child(n, true, false)
		if mi == null and n == "Rider" and gen:
			rider = Node3D.new()              # у сгенерированной модели гонщик — часть кузова
			add_child(rider)
			continue
		if mi == null:
			push_warning("atv.glb: нет узла " + n)
			inst.free()
			return false
		var t := mi.global_transform if mi.is_inside_tree() else _local_to(inst, mi)
		mi.get_parent().remove_child(mi)
		mi.owner = null
		mi.transform = t
		mi.material_override = sm
		if n == "Rider":
			rider = mi
		elif n.begins_with("Wheel"):
			wheels.append(mi)
		else:
			body_mi = mi
		add_child(mi)
	# упрощённые копии для дальних квадроциклов: полная модель до LOD_DIST, дальше — *_LOD
	var lod := {}
	for n in ["Body_LOD1", "Rider_LOD1", "Wheel_LOD1", "Body_LOD2", "Rider_LOD2", "Wheel_LOD2"]:
		var lm: MeshInstance3D = inst.find_child(n, true, false)
		if lm != null:
			lod[n] = lm.mesh
	inst.free()
	if lod.size() == 6 and ghost:                 # ghost = бот: вместо полной модели — LOD1, дальше — LOD2
		body_mi.mesh = lod["Body_LOD1"]
		rider.mesh = lod["Rider_LOD1"]
		for w in wheels:
			w.mesh = lod["Wheel_LOD1"]
		_add_lod(body_mi, body_mi, lod["Body_LOD2"], Transform3D())
		_add_lod(rider, rider, lod["Rider_LOD2"], Transform3D())
		for w in wheels:
			_add_lod(w, w, lod["Wheel_LOD2"], Transform3D())
	return true


func _add_lod(parent: Node3D, full: MeshInstance3D, mesh: Mesh, t: Transform3D) -> void:
	full.visibility_range_end = LOD_DIST
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = smat
	mi.transform = t
	mi.visibility_range_begin = LOD_DIST
	parent.add_child(mi)


## трансформ узла относительно корня сцены модели
func _local_to(root: Node3D, n: Node3D) -> Transform3D:
	var t := n.transform
	var p := n.get_parent()
	while p != null and p != root:
		t = (p as Node3D).transform * t
		p = p.get_parent()
	return t


func _box(list: Array, size: Vector3, pos: Vector3, col: Color, rot_z := 0.0) -> void:
	var bm := BoxMesh.new()
	bm.size = size
	list.append([bm, Transform3D(Basis(Vector3.BACK, rot_z), pos), col])


func _cyl(list: Array, r: float, h: float, pos: Vector3, rot: Vector3, col: Color, seg := 10) -> void:
	var cm := CylinderMesh.new()
	cm.top_radius = r
	cm.bottom_radius = r
	cm.height = h
	cm.radial_segments = seg
	cm.rings = 1
	list.append([cm, Transform3D(Basis.from_euler(rot), pos), col])


## слить детали в один меш: вершины и нормали в общих координатах, цвет детали — в вершины
func _merge(parts: Array) -> ArrayMesh:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	for part in parts:
		var arr: Array = (part[0] as PrimitiveMesh).get_mesh_arrays()
		var tr: Transform3D = part[1]
		var col: Color = part[2]
		var base := verts.size()
		var pv: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var pn: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		for i in pv.size():
			verts.append(tr * pv[i])
			norms.append((tr.basis * pn[i]).normalized())
			cols.append(col)
		var pi: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		for i in pi.size():
			idx.append(pi[i] + base)
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = verts
	out[Mesh.ARRAY_NORMAL] = norms
	out[Mesh.ARRAY_COLOR] = cols
	out[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out)
	return m


func _add_mesh(parent: Node3D, parts: Array) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = _merge(parts)
	mi.material_override = mat
	parent.add_child(mi)


func _particles(amount: int, life: float, dir: Vector3, spread: float, v0: float, v1: float, size: float) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = amount
	p.lifetime = life
	p.local_coords = false
	p.explosiveness = 0.0
	var pm := ParticleProcessMaterial.new()
	pm.direction = dir
	pm.spread = spread
	pm.initial_velocity_min = v0
	pm.initial_velocity_max = v1
	pm.gravity = Vector3(0, -9.8, 0)
	pm.scale_min = 0.5
	pm.scale_max = 1.6
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(0.25, 0.05, 0.55)
	p.process_material = pm
	var sm := SphereMesh.new()
	sm.radius = size
	sm.height = size * 2.0
	sm.radial_segments = 6
	sm.rings = 3
	var mm := StandardMaterial3D.new()
	mm.albedo_color = Color(0.42, 0.34, 0.22, _alpha)
	mm.roughness = 0.3
	if ghost:
		mm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.material = mm
	p.draw_pass_1 = sm
	p.emitting = false
	add_child(p)
	return p


## выброс грязи (перелив, удар о стенку, утонул)
func splash(n: int) -> void:
	if burst == null:
		return
	burst.amount_ratio = clampf(n / 30.0, 0.2, 1.0) * particle_scale
	burst.restart()
	burst.emitting = true


## pos — точка на кольце (ring.world), yaw — направление касательной (ring.yaw_of)
func sync(r, pos: Vector3, yaw: float, delta: float) -> void:
	position = pos
	rotation = Vector3(0.0, yaw, r.pitch)
	for w in wheels:
		w.rotation.z = -r.wheel
	# гонщик подаётся вперёд на газу и откидывается на подъёме лебёдкой
	var lean := (-0.18 if r.gas else 0.0) + (0.12 if r.cable else 0.0)
	rider.rotation.z = lerpf(rider.rotation.z, lean, minf(1.0, delta * 6.0))
	# грязь налипает в воде
	if r.d > 0.05:
		dirt = minf(0.85, dirt + delta * (0.05 + r.v * 0.02 + (0.2 if r.spin else 0.0)))
	if smat != null:
		smat.set_shader_parameter("dirt", dirt)
	else:
		var tint := Color.WHITE.lerp(Color(0.62, 0.50, 0.34), dirt)     # грязь затемняет и «рыжит» весь квадроцикл
		mat.albedo_color = Color(tint.r, tint.g, tint.b, _alpha)
	# брызги: в воде на ходу или при пробуксовке
	var wet: bool = r.d > 0.02 and not r.drowned
	var k := 0.0
	if wet:
		k = clampf(r.v / 8.0, 0.0, 1.0)
		if r.spin:
			k = maxf(k, 0.8)
	spray.emitting = k > 0.05
	spray.amount_ratio = maxf(k, 0.05) * particle_scale

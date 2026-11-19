# Обработка сгенерированной модели квадроцикла (amiodel.ru → .glb одним куском, ~30 тыс. треугольников) под игру.
#
#   Blender -b --factory-startup -P tools/blender/import_gen.py -- tmp/<модель>.glb models/atv_gen.glb [-y|-x|+x|+y] [папка_превью]
#
# Третий параметр — куда у исходной модели смотрит нос (по умолчанию −y; у model-2/3 — −x).
#
# Сгенерированный меш — «суп» из треугольников с плотной UV-раскладкой: простое упрощение рвёт его или
# растягивает текстуру. Поэтому — как для игр делают обычно — «запекание»:
#   1) лёгкая модель: кузов (с гонщиком) упрощается до ~6 тыс. треугольников, колёса — чистые цилиндры по
#      размеру шин; у всех частей — новая общая UV-развёртка на одну текстуру;
#   2) с исходной тяжёлой модели на лёгкую проецируются цвет и рельеф (карта нормалей) — зацепы, складки,
#      грязь видны, хотя геометрии нет;
#   3) разворот носом в +X, масштаб под колёсную базу физики (1.45 м), на землю (z = 0), начало — между осями;
#      колёса — отдельные объекты с центром на оси; копии LOD1/LOD2 для ботов.
# Гонщик остаётся частью кузова (наклон гонщика у этой модели не работает).
import bpy, bmesh, sys, os, math
from mathutils import Vector, Matrix

argv = sys.argv[sys.argv.index("--") + 1:]
SRC, OUT = os.path.abspath(argv[0]), os.path.abspath(argv[1])
FRONT = argv[2] if len(argv) > 2 and argv[2] in ("-y", "-x", "+x", "+y") else "-y"
rest = argv[3:] if len(argv) > 2 and argv[2] in ("-y", "-x", "+x", "+y") else argv[2:]
PREVIEW = os.path.abspath(rest[0]) if rest else ""
WB = 1.45                 # колёсная база в физике игры
BODY_TRIS = 6000
TEX = 1024                # размер запечённых текстур

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=SRC)
high = [o for o in bpy.context.scene.objects if o.type == "MESH"][0]
# к общему виду: нос в −Y, ось колёс — X (дальше скрипт рассчитан на это)
ROT = {"-y": 0.0, "-x": math.pi / 2, "+x": -math.pi / 2, "+y": math.pi}[FRONT]
high.data.transform(Matrix.Rotation(ROT, 4, "Z") @ high.matrix_world)
high.matrix_world = Matrix.Identity(4)
high.name = "High"
scn = bpy.context.scene
coll = scn.collection


def tris(o):
    return sum(len(p.vertices) - 2 for p in o.data.polygons)


def select_only(objs, active):
    for o in scn.objects:
        o.select_set(o in objs)
    bpy.context.view_layer.objects.active = active


# ---------- колёса: по нижней половине шины (ничем не закрыта) ----------
V = [v.co.copy() for v in high.data.vertices]
xs = [v.x for v in V]
W = max(-min(xs), max(xs))
zmin = min(v.z for v in V)
wheels = {}
# нос модели — в −Y; ось колёс — X
for name, sx, sy in (("Wheel_FL", -1, -1), ("Wheel_FR", 1, -1), ("Wheel_RL", -1, 1), ("Wheel_RR", 1, 1)):
    cl = [v for v in V if v.x * sx > 0.6 * W and v.y * sy > 0.2 and v.z < zmin + 0.75]
    zb = min(v.z for v in cl)
    r = 0.35
    for it in range(3):
        low = [v for v in cl if v.z < zb + r]
        ylo, yhi = min(v.y for v in low), max(v.y for v in low)
        r = (yhi - ylo) / 2
    tire = [v for v in cl if math.hypot(v.y - (ylo + yhi) / 2, v.z - (zb + r)) < r * 1.02]
    x0, x1 = min(abs(v.x) for v in tire), max(abs(v.x) for v in tire)
    wheels[name] = {"s": sx, "y": (ylo + yhi) / 2, "z": zb + r, "r": r, "x": sx * (x0 + x1) / 2, "w": x1 - x0}
    print("WHEEL %s y=%.3f z=%.3f r=%.3f x=%.3f w=%.3f" % (name, wheels[name]["y"], wheels[name]["z"], r, wheels[name]["x"], x1 - x0))

# ---------- лёгкий кузов: копия, склейка вершин, без колёс, упрощение ----------
low = high.copy()
low.data = high.data.copy()
low.name = "Body"
coll.objects.link(low)
bm = bmesh.new()
bm.from_mesh(low.data)
bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=0.0005)
cut = [f for f in bm.faces for wd in [None] if any(
    all(v.co.x * w["s"] >= abs(w["x"]) - w["w"] / 2 - 0.02 and math.hypot(v.co.y - w["y"], v.co.z - w["z"]) <= w["r"] * 1.03 for v in f.verts)
    for w in wheels.values())]
bmesh.ops.delete(bm, geom=cut, context="FACES")
bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_faces], context="VERTS")
bm.to_mesh(low.data)
bm.free()
m = low.modifiers.new("dec", "DECIMATE")
m.ratio = BODY_TRIS / max(1, tris(low))
select_only([low], low)
bpy.ops.object.modifier_apply(modifier="dec")
print("BODY tris %d" % tris(low))

# ---------- колёса — цилиндры по размеру шин ----------
parts = [low]
for name, w in wheels.items():
    bmw = bmesh.new()
    bmesh.ops.create_cone(bmw, cap_ends=True, cap_tris=False, segments=28, radius1=w["r"], radius2=w["r"], depth=w["w"])
    bmesh.ops.bevel(bmw, geom=[e for e in bmw.edges if len(e.link_faces) == 2 and abs(e.calc_face_angle(0)) > 1.2],
                    offset=w["w"] * 0.18, segments=2, affect="EDGES")
    me = bpy.data.meshes.new(name)
    bmw.to_mesh(me)
    bmw.free()
    o = bpy.data.objects.new(name, me)
    coll.objects.link(o)
    o.data.transform(Matrix.Translation((w["x"], w["y"], w["z"])) @ Matrix.Rotation(math.pi / 2, 4, "Y"))
    parts.append(o)

# ---------- общая UV-развёртка на одну текстуру ----------
for o in parts:
    o.data.uv_layers.new(name="Bake")
    o.data.uv_layers.active = o.data.uv_layers["Bake"]
    o.data.uv_layers["Bake"].active_render = True
select_only(parts, low)
bpy.ops.object.mode_set(mode="EDIT")
bpy.ops.mesh.select_all(action="SELECT")
bpy.ops.uv.smart_project(angle_limit=math.radians(60), island_margin=0.004)
bpy.ops.object.mode_set(mode="OBJECT")

# ---------- запекание цвета и нормалей с тяжёлой модели ----------
img_col = bpy.data.images.new("atv_color", TEX, TEX)
img_nrm = bpy.data.images.new("atv_normal", TEX, TEX, is_data=True)
img_nrm.colorspace_settings.name = "Non-Color"
bake = bpy.data.materials.new("ATV_gen")
bake.use_nodes = True
nt = bake.node_tree
bsdf = nt.nodes["Principled BSDF"]
tcol = nt.nodes.new("ShaderNodeTexImage")
tcol.image = img_col
tnrm = nt.nodes.new("ShaderNodeTexImage")
tnrm.image = img_nrm
for o in parts:
    o.data.materials.clear()
    o.data.materials.append(bake)
scn.render.engine = "CYCLES"
scn.cycles.samples = 4
scn.cycles.device = "CPU"
scn.render.bake.use_selected_to_active = True
scn.render.bake.cage_extrusion = 0.03
scn.render.bake.max_ray_distance = 0.12
scn.render.bake.margin = 6
for img, node, kind in ((img_col, tcol, "DIFFUSE"), (img_nrm, tnrm, "NORMAL")):
    nt.nodes.active = node
    for o in parts:
        select_only([high, o], o)
        if kind == "DIFFUSE":
            bpy.ops.object.bake(type="DIFFUSE", pass_filter={"COLOR"}, use_clear=(o is low))
        else:
            bpy.ops.object.bake(type="NORMAL", normal_space="TANGENT", use_clear=(o is low))
    print("BAKED", kind)
# материал для экспорта: цвет + карта нормалей, шероховатость постоянная
nt.links.new(tcol.outputs["Color"], bsdf.inputs["Base Color"])
nmap = nt.nodes.new("ShaderNodeNormalMap")
nt.links.new(tnrm.outputs["Color"], nmap.inputs["Color"])
nt.links.new(nmap.outputs["Normal"], bsdf.inputs["Normal"])
bsdf.inputs["Roughness"].default_value = 0.75
bsdf.inputs["Metallic"].default_value = 0.0
for o in parts:                              # только новая развёртка
    for uv in list(o.data.uv_layers):
        if uv.name != "Bake":
            o.data.uv_layers.remove(uv)
bpy.data.objects.remove(high)

# ---------- разворот, масштаб, земля, начало координат колёс ----------
front = (wheels["Wheel_FL"]["y"] + wheels["Wheel_FR"]["y"]) / 2
rear = (wheels["Wheel_RL"]["y"] + wheels["Wheel_RR"]["y"]) / 2
s = WB / abs(rear - front)
mid = (front + rear) / 2
ground = min(min(v.co.z for v in o.data.vertices) for o in parts)
T = Matrix.Rotation(math.pi / 2, 4, "Z") @ Matrix.Scale(s, 4) @ Matrix.Translation((0, -mid, -ground))
print("SCALE %.3f wheel r -> %s" % (s, ", ".join("%.3f" % (w["r"] * s) for w in wheels.values())))
for o in parts:
    o.data.transform(T)
for o in parts[1:]:
    w = wheels[o.name]
    c = T @ Vector((w["x"], w["y"], w["z"]))
    o.data.transform(Matrix.Translation(-c))
    o.location = c


def lod(src, name, target):
    o = bpy.data.objects.new(name, src.data.copy())
    coll.objects.link(o)
    o.matrix_world = src.matrix_world.copy()
    if target:
        md = o.modifiers.new("dec", "DECIMATE")
        md.ratio = target / max(1, tris(o))
        select_only([o], o)
        bpy.ops.object.modifier_apply(modifier="dec")
    return o


# LOD для ботов не делаем: из-за множества швов развёртки Decimate почти не упрощает, а 6 × ~7 тыс.
# треугольников — столько же, сколько у своей модели с LOD
lods = []
for o in parts + lods:
    o.data.shade_smooth()
    print("TRIS %s %d" % (o.name, tris(o)))

# ---------- экспорт ----------
os.makedirs(os.path.dirname(OUT), exist_ok=True)
img_col.file_format = "JPEG"
select_only(parts + lods, low)
bpy.ops.export_scene.gltf(filepath=OUT, export_format="GLB", use_selection=True, export_apply=True, export_yup=True,
                          export_image_format="JPEG", export_jpeg_quality=88, export_texcoords=True, export_normals=True)
print("GLB", OUT, os.path.getsize(OUT))
BLEND = os.path.join(os.path.dirname(OUT), "src", os.path.splitext(os.path.basename(OUT))[0] + ".blend")
os.makedirs(os.path.dirname(BLEND), exist_ok=True)
img_col.pack()
img_nrm.pack()
bpy.ops.wm.save_as_mainfile(filepath=BLEND, copy=True)
print("BLEND", BLEND)

if PREVIEW:
    os.makedirs(PREVIEW, exist_ok=True)
    for o in lods:
        o.hide_render = True
    scn.render.engine = "BLENDER_EEVEE_NEXT"
    scn.render.resolution_x, scn.render.resolution_y = 900, 600
    wd = bpy.data.worlds.new("w")
    scn.world = wd
    wd.use_nodes = True
    wd.node_tree.nodes["Background"].inputs[0].default_value = (0.8, 0.82, 0.85, 1)
    sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
    coll.objects.link(sun)
    sun.rotation_euler = (0.8, 0.2, 0.6)
    sun.data.energy = 3
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    coll.objects.link(cam)
    scn.camera = cam
    for nm, pos in {"side": (0.0, -6.0, 1.2), "front34": (4.0, -4.0, 2.2)}.items():
        cam.location = pos
        cam.rotation_euler = (Vector((0, 0, 0.8)) - Vector(pos)).to_track_quat("-Z", "Y").to_euler()
        scn.render.filepath = os.path.join(PREVIEW, nm + ".png")
        bpy.ops.render.render(write_still=True)

# MUD RING — генератор ассетов окружения для Blender 4.5 (по фото соревнований, low-poly под мобильные).
#
#   Blender -b --factory-startup -P tools/blender/env.py -- models/env.glb [папка_для_превью]
#
# Каждый ассет — отдельный объект с началом координат у земли. Godot расставляет их через MultiMesh (scripts/env.gd).
# Цвет — в вершинах (COLOR_0). UV: u — 1 свой цвет / 0 цвет экземпляра (INSTANCE_CUSTOM, куртки зрителей),
# v — сила качания на ветру (трава, флаги, кроны). Нос ассетов — по +X, Y — поперёк, Z — вверх.
import bpy, bmesh, math, sys, os, random
from mathutils import Vector, Matrix

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OUT = os.path.abspath(argv[0] if argv else "models/env.glb")
RENDER = os.path.abspath(argv[1]) if len(argv) > 1 else ""
random.seed(42)


def hexc(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))


def jit(c, a=0.06):
    return tuple(max(0, min(1, x + random.uniform(-a, a))) for x in c)


bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
col = scene.collection


class Asset:
    """накопитель геометрии одного ассета: вершины, цвета и UV по углам граней"""

    def __init__(self, name):
        self.name = name
        self.bm = bmesh.new()
        self.c = self.bm.loops.layers.color.new("Col")
        self.uv = self.bm.loops.layers.uv.new("UV")

    def face(self, pts, cols, code=1.0, sway=0.0):
        vs = [self.bm.verts.new(p) for p in pts]
        f = self.bm.faces.new(vs)
        for lp, cc in zip(f.loops, cols):
            lp[self.c] = (cc[0], cc[1], cc[2], 1.0)
            lp[self.uv].uv = (code, sway)
        return f

    def mesh(self, bm2, color_fn, code=1.0, sway_fn=None, M=Matrix.Identity(4)):
        """добавить готовый bmesh-примитив; color_fn(vertex_co) → цвет, sway_fn(co) → качание"""
        for v in bm2.verts:
            v.co = M @ v.co
        for f in bm2.faces:
            pts = [v.co.copy() for v in f.verts]
            self.face(pts, [color_fn(p) for p in pts], code, 0.0 if sway_fn is None else sway_fn(f.calc_center_median()))
        bm2.free()

    def finish(self):
        me = bpy.data.meshes.new(self.name)
        bmesh.ops.recalc_face_normals(self.bm, faces=self.bm.faces[:])
        self.bm.to_mesh(me)
        self.bm.free()
        ca = me.color_attributes.get("Col")
        if ca is not None:                      # без этого рендер и экспорт glTF цвет вершин не видят
            me.color_attributes.active_color = ca
            me.color_attributes.render_color_index = me.color_attributes.find("Col")
        me.shade_smooth()
        me.set_sharp_from_angle(angle=math.radians(50))
        ob = bpy.data.objects.new(self.name, me)
        col.objects.link(ob)
        return ob


def cone(r1, r2, h, seg):
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=seg, radius1=r1, radius2=r2, depth=h)
    bmesh.ops.translate(bm, vec=(0, 0, h / 2), verts=bm.verts)
    return bm


def blob(r, sub=2, squash=0.8, rough=0.14):
    bm = bmesh.new()
    bmesh.ops.create_icosphere(bm, subdivisions=sub, radius=r)
    for v in bm.verts:
        v.co.z *= squash
        v.co *= 1 + random.uniform(-rough, rough)
    return bm


def boxm(sx, sy, sz):
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1)
    bmesh.ops.scale(bm, vec=(sx, sy, sz), verts=bm.verts)
    bmesh.ops.translate(bm, vec=(0, 0, sz / 2), verts=bm.verts)
    return bm


objs = []

# ---------------- трава: пучки треугольных травинок, качаются ----------------
def grass(name, n, h0, h1, base, tip, spread=0.18):
    a = Asset(name)
    for i in range(n):
        ang = random.uniform(0, math.tau)
        r = random.uniform(0, spread)
        x, y = r * math.cos(ang), r * math.sin(ang)
        h = random.uniform(h0, h1)
        w = random.uniform(0.018, 0.03)
        d = random.uniform(0, math.tau)
        px, py = -math.sin(d) * w, math.cos(d) * w
        lean = random.uniform(0.15, 0.45) * h
        tx, ty = x + math.cos(ang) * lean, y + math.sin(ang) * lean
        b = jit(base, 0.04)
        t = jit(tip, 0.06)
        a.face([(x - px, y - py, 0), (x + px, y + py, 0), (tx, ty, h)], [b, b, t], 1.0, 1.0)
    return a.finish()


objs.append(grass("Grass", 11, 0.22, 0.45, hexc("3d5a26"), hexc("8aa54a")))
objs.append(grass("GrassDry", 11, 0.30, 0.60, hexc("6d6a3a"), hexc("c8b67a")))
objs.append(grass("GrassTall", 14, 0.55, 1.05, hexc("4f5a2e"), hexc("b9b06a"), 0.25))

# ---------------- деревья ----------------
def birch():
    a = Asset("Birch")
    h = 7.0
    bm = cone(0.11, 0.05, h, 6)
    for v in bm.verts:
        v.co.x += math.sin(v.co.z * 0.6) * 0.12
    a.mesh(bm, lambda p: hexc("2a2a28") if random.random() < 0.22 else jit(hexc("e8e6dc"), 0.04))
    for i in range(7):
        z = random.uniform(3.4, 6.6)
        c = (random.uniform(-0.6, 0.6), random.uniform(-0.6, 0.6), z)
        base = jit(hexc("5f8a36"), 0.08)
        a.mesh(blob(random.uniform(0.75, 1.15), 2, 0.85), lambda p, b=base: jit(b, 0.05), 1.0,
               lambda p: 0.35, Matrix.Translation(c))
    return a.finish()


def oak():
    a = Asset("Oak")
    a.mesh(cone(0.22, 0.12, 4.0, 7), lambda p: jit(hexc("4a3a2a"), 0.04))
    for i in range(8):
        c = (random.uniform(-1.3, 1.3), random.uniform(-1.3, 1.3), random.uniform(3.6, 6.2))
        base = jit(hexc("3f6229"), 0.07)
        a.mesh(blob(random.uniform(1.1, 1.7), 2, 0.8), lambda p, b=base: jit(b, 0.05), 1.0,
               lambda p: 0.25, Matrix.Translation(c))
    return a.finish()


def pine():
    a = Asset("Pine")
    a.mesh(cone(0.16, 0.08, 3.0, 6), lambda p: jit(hexc("4a3626"), 0.03))
    z = 1.6
    for i, r in enumerate((2.0, 1.6, 1.2, 0.8)):
        bm = cone(r, 0.0, 2.6, 9)
        for v in bm.verts:
            if v.co.z < 0.1:
                v.co.x *= 1 + random.uniform(-0.25, 0.15)
                v.co.y *= 1 + random.uniform(-0.25, 0.15)
                v.co.z -= random.uniform(0, 0.35)
        base = jit(hexc("26402a"), 0.05)
        a.mesh(bm, lambda p, b=base: jit(b, 0.04), 1.0, None, Matrix.Translation((0, 0, z)) @ Matrix.Rotation(i * 0.7, 4, "Z"))
        z += 1.5
    return a.finish()


def bush():
    a = Asset("Bush")
    for i in range(4):
        c = (random.uniform(-0.6, 0.6), random.uniform(-0.6, 0.6), random.uniform(0.35, 0.7))
        base = jit(hexc("4a6a2e"), 0.07)
        a.mesh(blob(random.uniform(0.5, 0.85), 2, 0.75), lambda p, b=base: jit(b, 0.05), 1.0, lambda p: 0.3, Matrix.Translation(c))
    return a.finish()


objs += [birch(), oak(), pine(), bush()]

# ---------------- флаг-«перо» (рекламные флаги на фото) ----------------
def flag(name, cbase, cstripe):
    a = Asset(name)
    a.mesh(cone(0.025, 0.02, 3.6, 6), lambda p: hexc("b8b8b8"))
    # полотнище: изогнутая полоса вдоль шеста, верх закруглён
    n = 10
    pts = []
    for i in range(n + 1):
        t = i / n
        z = 0.9 + t * 2.6
        w = 0.62 if t < 0.82 else 0.62 * math.cos((t - 0.82) / 0.18 * math.pi / 2) + 0.05
        pts.append((z, w))
    for i in range(n):
        (z0, w0), (z1, w1) = pts[i], pts[i + 1]
        for side in (0,):
            q = [(0.03, 0, z0), (0.03 + w0, 0.04 * math.sin(z0 * 1.3), z0), (0.03 + w1, 0.04 * math.sin(z1 * 1.3), z1), (0.03, 0, z1)]
            cs = []
            for (x, y, z) in q:
                u = x / 0.65
                stripe = abs((z - 0.9) / 2.6 - 0.75 + u * 0.35) < 0.07 or (0.25 < (z - 0.9) / 2.6 < 0.6 and 0.25 < u < 0.75 and int(z * 9) % 2 == 0)
                cs.append(cstripe if stripe else cbase)
            a.face(q, cs, 1.0, 0.6)
    return a.finish()


objs += [flag("FlagRed", hexc("d22a22"), hexc("f4f1ea")), flag("FlagBlack", hexc("1d2230"), hexc("f4f1ea"))]

# ---------------- белый шатёр ----------------
def tent():
    a = Asset("Tent")
    wv = hexc("f2f2ee")
    s, h = 1.5, 2.2
    for (x, y) in ((s, s), (-s, s), (-s, -s), (s, -s)):
        a.mesh(cone(0.03, 0.03, h, 5), lambda p: hexc("cfcfcf"), 1.0, None, Matrix.Translation((x, y, 0)))
    top = (0, 0, h + 0.9)
    cs = [(s, s, h), (-s, s, h), (-s, -s, h), (s, -s, h)]
    for i in range(4):
        a.face([cs[i], cs[(i + 1) % 4], top], [wv, wv, jit(wv, 0.02)])
        p0, p1 = cs[i], cs[(i + 1) % 4]
        a.face([p0, p1, (p1[0], p1[1], h - 0.25), (p0[0], p0[1], h - 0.25)], [wv] * 4)   # подзор
    return a.finish()


objs.append(tent())

# ---------------- зритель: куртка — цвет экземпляра ----------------
def person():
    a = Asset("Person")
    dark = hexc("26272c")
    for s in (1, -1):
        a.mesh(boxm(0.13, 0.13, 0.82), lambda p: jit(dark, 0.02), 1.0, None, Matrix.Translation((0, 0.09 * s, 0)))
    bm = boxm(0.26, 0.42, 0.62)
    for v in bm.verts:
        if v.co.z > 0.3:
            v.co.y *= 0.92
    a.mesh(bm, lambda p: (1, 1, 1), 0.0, None, Matrix.Translation((0, 0, 0.82)))
    for s in (1, -1):
        a.mesh(boxm(0.10, 0.10, 0.58), lambda p: (1, 1, 1), 0.0, None,
               Matrix.Translation((0.02, 0.25 * s, 0.86)) @ Matrix.Rotation(0.12 * s, 4, "X"))
    head = bmesh.new()
    bmesh.ops.create_icosphere(head, subdivisions=1, radius=0.12)
    a.mesh(head, lambda p: hexc("d6a98a") if p.x > -0.02 else hexc("2a2622"), 1.0, None, Matrix.Translation((0, 0, 1.58)))
    return a.finish()


objs.append(person())

# ---------------- кол для ленты ----------------
st = Asset("Stake")
st.mesh(boxm(0.04, 0.04, 1.0), lambda p: jit(hexc("8a6a48"), 0.04))
objs.append(st.finish())

# ---------------- материал и экспорт ----------------
mat = bpy.data.materials.new("Env")
mat.use_nodes = True
nt = mat.node_tree
vc = nt.nodes.new("ShaderNodeVertexColor")
vc.layer_name = "Col"
nt.links.new(vc.outputs["Color"], nt.nodes["Principled BSDF"].inputs["Base Color"])
for o in objs:
    o.data.materials.append(mat)
    print("ASSET %-10s tris %d" % (o.name, sum(len(p.vertices) - 2 for p in o.data.polygons)))
# исходник для ручной правки: models/src/env.blend — ассеты разложены по сетке, чтобы не мешали друг другу;
# export.py выгружает их в начало координат (свойство export_at_origin). Повторный запуск генератора перезапишет .blend.
os.makedirs(os.path.dirname(OUT), exist_ok=True)
for i, o in enumerate(objs):
    o["export_at_origin"] = True
    o.location = ((i % 6) * 5.0, (i // 6) * 8.0, 0)
BLEND = os.path.join(os.path.dirname(OUT), "src", os.path.splitext(os.path.basename(OUT))[0] + ".blend")
os.makedirs(os.path.dirname(BLEND), exist_ok=True)
bpy.ops.wm.save_as_mainfile(filepath=BLEND, copy=True)
print("BLEND", BLEND)
for o in objs:
    o.location = (0, 0, 0)
# в экспорте все стоят в нуле
for o in bpy.context.selected_objects:
    o.select_set(False)
for o in objs:
    o.select_set(True)
kw = dict(filepath=OUT, export_format="GLB", use_selection=True, export_apply=True, export_yup=True,
          export_materials="EXPORT", export_normals=True, export_texcoords=True)
try:
    bpy.ops.export_scene.gltf(**kw, export_vertex_color="ACTIVE")
except TypeError:
    bpy.ops.export_scene.gltf(**kw, export_colors=True)
print("GLB", OUT, os.path.getsize(OUT))

if RENDER:
    os.makedirs(RENDER, exist_ok=True)
    for i, o in enumerate(objs):
        o.location = ((i % 6) * 5.0 - 12.5, (i // 6) * 8, 0)
    scene.render.engine = "BLENDER_WORKBENCH"
    sh = scene.display.shading
    sh.light = "STUDIO"
    sh.color_type = "VERTEX"
    sh.show_shadows = True
    scene.render.resolution_x = 1200
    scene.render.resolution_y = 600
    w = bpy.data.worlds.new("w")
    scene.world = w
    w.color = (0.75, 0.8, 0.85)
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    col.objects.link(cam)
    scene.camera = cam
    cam.location = (0, -20, 7)
    d = Vector((0, 4, 2.5)) - cam.location
    cam.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()
    scene.render.filepath = os.path.join(RENDER, "env.png")
    bpy.ops.render.render(write_still=True)

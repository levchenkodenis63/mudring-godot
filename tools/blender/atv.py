# MUD RING — генератор квадроцикла с гонщиком для Blender 4.5 (low-poly, под мобильные).
# v2 — по фото соревнований (example/): спортивный грязевой квадроцикл, резина 35" на дисках 14",
# вынесенный радиатор в коробе над передним багажником, кенгурятник, рубленый пластик, гонщик с рюкзаком.
#
#   Blender -b --factory-startup -P tools/blender/atv.py -- models/atv.glb [папка_для_рендеров]
#
# Всё строится кодом: правишь размеры/форму здесь и перегенерируешь. Единицы — метры, нос по +X,
# ось Y — поперёк (в Godot станет -Z), Z — вверх. Начало координат — земля под центром квадроцикла.
# Размеры совпадают с физикой игры: колёсная база 1.45 м, радиус колеса 0.44 м.
#
# Объекты в .glb: Body, Wheel_FL/FR/RL/RR (начало — на оси колеса), Rider (начало — в тазу, для наклона).
# Один материал на объект: цвет — в вершинах (COLOR_0), код перекраски — в UV (TEXCOORD_0.x):
#   1.0 — свой цвет, 0.0 — краска корпуса, 0.25 — акцент, 0.5 — джерси, 0.75 — шлем.
import bpy, bmesh, math, sys, os
from mathutils import Vector, Matrix

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OUT = os.path.abspath(argv[0] if argv else "models/atv.glb")
RENDER = os.path.abspath(argv[1]) if len(argv) > 1 else ""

WR, WB = 0.44, 1.45
HW = WB / 2
TRACK = 0.46                     # половина колеи (центр колеса по Y)
FIXED, PAINT, ACCENT, JERSEY, HELMET = 1.0, 0.0, 0.25, 0.5, 0.75


def hexc(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))


C = dict(
    paint=hexc("e0b418"), accent=hexc("f2c418"), dark=hexc("1c1c20"), plastic=hexc("2b2b30"),
    metal=hexc("9a9da3"), seat=hexc("232326"), tire=hexc("161618"), lug=hexc("1f1f22"),
    spring=hexc("d43a30"), light=hexc("f4f1e0"), lens=hexc("ffe9a8"), jersey=hexc("f2cf46"),
    pants=hexc("2a2b33"), helmet=hexc("17171b"), visor=hexc("3a4f63"), glove=hexc("111113"), boot=hexc("26262b"),
    rim=hexc("1a1a1d"), metal2=hexc("3c3d42"), rope=hexc("e8792a"), pack=hexc("1f2024"),
)

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
col = scene.collection
parts = {"body": [], "wheel": [], "rider": []}


# ---------------- примитивы ----------------
def new_obj(name, bm):
    me = bpy.data.meshes.new(name)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new(name, me)
    col.objects.link(ob)
    return ob


def bevel(ob, w, seg=2, angle=40):
    if w <= 0:
        return ob
    m = ob.modifiers.new("bevel", "BEVEL")
    m.width = w
    m.segments = seg
    m.limit_method = "ANGLE"
    m.angle_limit = math.radians(angle)
    m.harden_normals = False
    return ob


def bake(ob):
    """применить модификаторы и трансформацию — меш в мировых координатах"""
    dg = bpy.context.evaluated_depsgraph_get()
    me = bpy.data.meshes.new_from_object(ob.evaluated_get(dg))
    me.transform(ob.matrix_world)
    old = ob.data
    ob.modifiers.clear()
    ob.data = me
    ob.matrix_world = Matrix.Identity(4)
    bpy.data.meshes.remove(old)


def paint(ob, rgb, code):
    me = ob.data
    at = me.color_attributes.get("Col") or me.color_attributes.new("Col", "BYTE_COLOR", "CORNER")
    for d in at.data:
        d.color_srgb = (rgb[0], rgb[1], rgb[2], 1.0)
    # код перекраски — в UV (u = код): альфу цвета вершин экспортёр glTF отбрасывает
    uv = me.uv_layers.get("Code") or me.uv_layers.new(name="Code")
    for d in uv.data:
        d.uv = (code, 0.0)


def add(group, ob, rgb, code=FIXED):
    bake(ob)
    paint(ob, rgb, code)
    parts[group].append(ob)
    return ob


def prism(pts, y0, y1, bev=0.02):
    """боковой силуэт (x, z), выдавленный по Y от y0 до y1"""
    bm = bmesh.new()
    a = [bm.verts.new((x, y0, z)) for x, z in pts]
    b = [bm.verts.new((x, y1, z)) for x, z in pts]
    bm.faces.new(a)
    bm.faces.new(list(reversed(b)))
    n = len(pts)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((a[i], a[j], b[j], b[i]))
    return bevel(new_obj("prism", bm), bev, 2, 35)


def box(center, size, rot=(0, 0, 0), bev=0.015):
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    bmesh.ops.scale(bm, vec=size, verts=bm.verts)
    ob = new_obj("box", bm)
    ob.rotation_euler = rot
    ob.location = center
    return bevel(ob, bev, 2, 40)


def tube(p1, p2, r, seg=8, caps=True):
    p1, p2 = Vector(p1), Vector(p2)
    d = p2 - p1
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=caps, cap_tris=False, segments=seg, radius1=r, radius2=r, depth=d.length)
    ob = new_obj("tube", bm)
    ob.matrix_world = Matrix.Translation((p1 + p2) / 2) @ d.to_track_quat("Z", "Y").to_matrix().to_4x4()
    return ob


def cyl(center, r, depth, axis="Y", seg=16, bev=0.0):
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=seg, radius1=r, radius2=r, depth=depth)
    ob = new_obj("cyl", bm)
    rot = {"X": (0, math.pi / 2, 0), "Y": (math.pi / 2, 0, 0), "Z": (0, 0, 0)}[axis]
    ob.rotation_euler = rot
    ob.location = center
    return bevel(ob, bev, 2, 30)


def sphere(center, r, seg=10, rings=6):
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=seg, v_segments=rings, radius=r)
    ob = new_obj("sphere", bm)
    ob.location = center
    return ob


def arc(cx, cz, r, a0, a1, n):
    return [(cx + r * math.cos(math.radians(a0 + (a1 - a0) * i / n)), cz + r * math.sin(math.radians(a0 + (a1 - a0) * i / n))) for i in range(n + 1)]


def both(fn):
    """деталь с двух сторон: fn(s) для s = +1 и -1"""
    for s in (1, -1):
        fn(s)


# ---------------- корпус (v2: по фото соревнований — спортивный грязевой квадроцикл) ----------------
B = "body"


def place(ob, M):
    """поставить деталь, построенную в локальных координатах узла M"""
    ob.matrix_world = M @ ob.matrix_basis      # matrix_world до пересчёта сцены устаревшая — берём из loc/rot/scale
    return ob


def torus(center, R, r, seg=16, sides=6):
    bm = bmesh.new()
    rings = []
    for i in range(seg):
        a = 2 * math.pi * i / seg
        ring = []
        for j in range(sides):
            b = 2 * math.pi * j / sides
            ring.append(bm.verts.new(((R + r * math.cos(b)) * math.cos(a), (R + r * math.cos(b)) * math.sin(a), r * math.sin(b))))
        rings.append(ring)
    for i in range(seg):
        for j in range(sides):
            a, b = rings[i], rings[(i + 1) % seg]
            bm.faces.new((a[j], b[j], b[(j + 1) % sides], a[(j + 1) % sides]))
    ob = new_obj("torus", bm)
    ob.location = center
    return ob


add(B, box((0, 0, 0.42), (1.50, 0.40, 0.16)), C["dark"])                        # рама
add(B, prism([(0.85, 0.30), (1.30, 0.42), (1.33, 0.48), (0.85, 0.37)], -0.30, 0.30, 0.01), C["metal"])   # защита днища спереди
add(B, box((-0.05, 0, 0.32), (1.10, 0.46, 0.035)), C["metal"])                  # защита днища
# передние крылья: рубленый силуэт с острым носом, цвет команды; тёмные расширители по арке
inner = arc(HW, WR, 0.52, 15, 165, 8)
front = [(0.15, 0.60), (0.20, 0.80), (0.34, 0.97), (0.62, 1.03), (0.92, 1.02), (1.14, 0.95), (1.32, 0.83), (1.37, 0.75), (1.30, 0.64)] + inner
flare_f = arc(HW, WR, 0.60, 8, 172, 10) + arc(HW, WR, 0.515, 172, 8, 10)
panel_f = [(0.24, 0.82), (0.36, 0.96), (0.62, 1.02), (0.92, 1.01), (1.13, 0.94), (1.31, 0.83), (1.20, 0.80), (1.00, 0.88), (0.70, 0.93), (0.42, 0.90), (0.30, 0.80)]
for s in (1, -1):                                   # пластик чёрный, цвет команды — панелью по верхней кромке
    add(B, prism(front, 0.30 * s, 0.64 * s, 0.03), C["plastic"])
    add(B, prism(panel_f, 0.641 * s, 0.648 * s, 0.0), C["paint"], PAINT)
    add(B, prism(flare_f, 0.58 * s, 0.69 * s, 0.015), C["dark"])
add(B, prism([(0.30, 0.62), (0.38, 0.95), (0.70, 1.00), (1.05, 0.95), (1.28, 0.80), (1.30, 0.66), (1.20, 0.60)], -0.30, 0.30, 0.03), C["dark"])  # капот
for s in (1, -1):                                                                # фары-щели
    add(B, box((1.215, 0.16 * s, 0.84), (0.035, 0.15, 0.05), (0, 0.6, 0), 0.0), C["lens"])
# задние крылья: длинный хвост вверх
inner_r = arc(-HW, WR, 0.52, 165, 15, 8)
rear = [(-0.15, 0.60), (-0.20, 0.82), (-0.32, 0.96), (-0.62, 1.00), (-0.95, 1.02), (-1.20, 1.07), (-1.37, 1.03), (-1.39, 0.90), (-1.31, 0.72), (-1.26, 0.62)] + inner_r
flare_r = arc(-HW, WR, 0.60, 8, 172, 10) + arc(-HW, WR, 0.515, 172, 8, 10)
panel_r = [(-0.30, 0.80), (-0.40, 0.88), (-0.70, 0.92), (-1.05, 0.95), (-1.28, 0.95), (-1.35, 1.02), (-1.20, 1.06), (-0.95, 1.01), (-0.62, 0.99), (-0.34, 0.95), (-0.24, 0.84)]
for s in (1, -1):
    add(B, prism(rear, 0.30 * s, 0.64 * s, 0.03), C["plastic"])
    add(B, prism(panel_r, 0.641 * s, 0.648 * s, 0.0), C["paint"], PAINT)
    add(B, prism(flare_r, 0.58 * s, 0.69 * s, 0.015), C["dark"])
    add(B, box((-1.33, 0.47 * s, 0.56), (0.02, 0.26, 0.28), bev=0.0), C["dark"])  # брызговик
add(B, prism([(-0.25, 0.60), (-0.30, 0.92), (-0.70, 0.98), (-1.15, 1.03), (-1.34, 0.97), (-1.30, 0.62)], -0.30, 0.30, 0.03), C["dark"])
# бока под сиденьем: тёмный пластик с полосой цвета команды
add(B, prism([(-0.42, 0.50), (0.30, 0.50), (0.33, 0.82), (-0.42, 0.84)], -0.36, 0.36, 0.02), C["plastic"])
for s in (1, -1):
    add(B, prism([(-0.36, 0.70), (0.22, 0.73), (0.24, 0.78), (-0.36, 0.76)], 0.362 * s, 0.368 * s, 0.0), C["paint"], PAINT)
add(B, prism([(-0.20, 0.80), (0.36, 0.85), (0.40, 1.00), (0.20, 1.10), (-0.10, 1.08)], -0.28, 0.28, 0.035), C["paint"], PAINT)  # бак
add(B, prism([(-1.05, 1.02), (-0.18, 1.02), (-0.05, 1.08), (-0.18, 1.15), (-0.60, 1.16), (-1.02, 1.14)], -0.20, 0.20, 0.035), C["seat"])  # сиденье
both(lambda s: add(B, box((-0.05, 0.44 * s, 0.42), (0.62, 0.17, 0.035)), C["dark"]))   # подножки

# вынесенный радиатор со шноркелями — высокий чёрный короб над передним багажником
M = Matrix.Translation((0.80, 0, 1.30)) @ Matrix.Rotation(-0.15, 4, "Y")
add(B, place(box((0, 0, 0), (0.32, 0.62, 0.44), bev=0.025), M), C["dark"])
for k in range(5):                                                               # решётка спереди
    add(B, place(box((0.165, 0, -0.15 + k * 0.075), (0.02, 0.52, 0.035), bev=0.0), M), C["metal"])
for s in (1, -1):                                                                # наклейки по бокам
    add(B, place(box((0.0, 0.312 * s, 0.03), (0.22, 0.006, 0.17), bev=0.0), M), C["light"])
    add(B, place(box((0.0, 0.316 * s, 0.03), (0.18, 0.004, 0.05), bev=0.0), M), C["paint"], PAINT)
add(B, place(box((0.03, 0, 0.255), (0.10, 0.52, 0.07), bev=0.01), M), C["dark"])          # светодиодная балка
add(B, place(box((0.085, 0, 0.255), (0.012, 0.48, 0.04), bev=0.0), M), C["lens"])
for s in (1, -1):                                                                # стойки короба
    add(B, tube((0.66, 0.24 * s, 1.04), (0.70, 0.24 * s, 1.10), 0.02), C["metal"])
    add(B, tube((0.95, 0.24 * s, 1.00), (0.92, 0.24 * s, 1.10), 0.02), C["metal"])
# кенгурятник цвета команды: от бампера вверх к коробу
for s in (1, -1):
    y = 0.22 * s
    add(B, tube((1.18, 0.28 * s, 0.46), (1.42, y, 0.50), 0.033, 8), C["accent"], ACCENT)
    add(B, tube((1.42, y, 0.50), (1.32, y, 0.88), 0.033, 8), C["accent"], ACCENT)
    add(B, tube((1.32, y, 0.88), (1.02, 0.20 * s, 1.10), 0.033, 8), C["accent"], ACCENT)
    add(B, sphere((1.42, y, 0.50), 0.034, 8, 4), C["accent"], ACCENT)
    add(B, sphere((1.32, y, 0.88), 0.034, 8, 4), C["accent"], ACCENT)
add(B, tube((1.42, -0.22, 0.50), (1.42, 0.22, 0.50), 0.033, 8), C["accent"], ACCENT)
add(B, tube((1.32, -0.22, 0.88), (1.32, 0.22, 0.88), 0.03, 8), C["accent"], ACCENT)
add(B, cyl((1.28, 0, 0.58), 0.075, 0.36, "Y", 12, 0.01), C["dark"])            # лебёдка
add(B, box((1.40, 0, 0.60), (0.04, 0.14, 0.08)), C["metal"])
add(B, torus((0.60, 0, 1.11), 0.16, 0.028, 14, 5), C["rope"])                   # бухта стропы на багажнике
# руль, большие защиты рук, номер
add(B, tube((0.30, 0, 0.88), (0.40, 0, 1.15), 0.03), C["metal"])
add(B, tube((0.42, -0.42, 1.18), (0.42, 0.42, 1.18), 0.022, 8), C["metal"])
for s in (1, -1):
    add(B, tube((0.42, 0.32 * s, 1.18), (0.42, 0.44 * s, 1.18), 0.032, 8), C["dark"])
    add(B, prism([(0.38, 1.14), (0.56, 1.13), (0.62, 1.24), (0.44, 1.28)], 0.44 * s, 0.30 * s, 0.012), C["accent"], ACCENT)
add(B, box((0.50, 0, 1.27), (0.02, 0.16, 0.20), (0, -0.25, 0), 0.006), C["light"])  # номерной щиток
# подвеска: рычаги и цветные пружины
def susp(xc, sgn):
    for s in (1, -1):
        add(B, tube((xc - 0.28 * sgn, 0.18 * s, 0.48), (xc, 0.30 * s, WR + 0.02), 0.022), C["metal"])
        add(B, tube((xc - 0.18 * sgn, 0.18 * s, 0.39), (xc, 0.30 * s, WR - 0.04), 0.022), C["metal"])
        add(B, tube((xc - 0.17 * sgn, 0.24 * s, 0.86), (xc - 0.03 * sgn, 0.31 * s, 0.50), 0.025), C["metal"])
        add(B, tube((xc - 0.15 * sgn, 0.25 * s, 0.80), (xc - 0.05 * sgn, 0.30 * s, 0.56), 0.05, 8), C["accent"], ACCENT)


susp(HW, 1)
susp(-HW, -1)
# задний багажник
for s in (1, -1):
    add(B, tube((-1.30, 0.30 * s, 1.12), (-0.98, 0.30 * s, 1.12), 0.018), C["metal"])
for x in (-1.30, -1.14, -0.98):
    add(B, tube((x, -0.30, 1.12), (x, 0.30, 1.12), 0.018), C["metal"])

# ---------------- колесо (v2: грязевая резина 35", маленький диск 14" с бэдлоком) ----------------
W = "wheel"
add(W, cyl((0, 0, 0), 0.37, 0.30, "Y", 18, 0.07), C["tire"])                    # каркас шины со скруглёнными плечами
N = 12
for k in range(N):
    for half, s in ((0, 1), (1, -1)):
        th = 2 * math.pi * (k + 0.5 * half) / N
        ob = box((0, 0, 0), (0.13, 0.16, 0.07), bev=0.0)                         # зацеп на беговой
        bake(ob)
        ob.data.transform(Matrix.Rotation(th, 4, "Y") @ Matrix.Translation((0, 0.07 * s, 0.405)) @ Matrix.Rotation(0.5 * s, 4, "Z"))
        paint(ob, C["lug"], FIXED)
        parts[W].append(ob)
        ob = box((0, 0, 0), (0.075, 0.03, 0.075), bev=0.0)                       # зацеп заходит на плечо боковины
        bake(ob)
        ob.data.transform(Matrix.Rotation(th + 0.10 * s, 4, "Y") @ Matrix.Translation((0, 0.150 * s, 0.375)) @ Matrix.Rotation(0.35 * s, 4, "X"))
        paint(ob, C["lug"], FIXED)
        parts[W].append(ob)
add(W, cyl((0, 0, 0), 0.215, 0.318, "Y", 16), C["accent"], ACCENT)              # бэдлок-кольцо
add(W, cyl((0, 0, 0), 0.195, 0.322, "Y", 16), C["rim"])                          # диск
for k in range(8):                                                               # спицы
    a = 2 * math.pi * k / 8
    for s in (1, -1):
        ob = box((0, 0, 0), (0.022, 0.008, 0.13), bev=0.0)
        bake(ob)
        ob.data.transform(Matrix.Rotation(a, 4, "Y") @ Matrix.Translation((0, 0.163 * s, 0.11)))
        paint(ob, C["metal2"], FIXED)
        parts[W].append(ob)
add(W, cyl((0, 0, 0), 0.055, 0.34, "Y", 10), C["metal"])                         # ступица

# ---------------- гонщик (v2: крупнее, прямее, локти в стороны, рюкзак, кроссовый шлем) ----------------
R = "rider"
HIP = Vector((-0.32, 0, 1.14))
LEAN = 0.35
add(R, box((-0.32, 0, 1.21), (0.32, 0.38, 0.17), bev=0.05), C["pants"])         # таз
TORSO = Vector((-0.22, 0, 1.50))
MT = Matrix.Translation(TORSO) @ Matrix.Rotation(LEAN, 4, "Y")
add(R, place(box((0, 0, 0), (0.31, 0.46, 0.58), bev=0.07), MT), C["jersey"], JERSEY)               # куртка
for s in (1, -1):
    add(R, place(box((0.0, 0.232 * s, 0.0), (0.14, 0.008, 0.50), bev=0.0), MT), C["accent"], ACCENT)  # полосы
add(R, place(box((-0.215, 0, 0.05), (0.11, 0.32, 0.36), bev=0.04), MT), C["pack"])                  # рюкзак
add(R, place(tube((-0.20, 0.13, 0.20), (-0.20, 0.13, -0.10), 0.012, 6), MT), C["pack"])
add(R, sphere((-0.10, 0, 1.79), 0.075, 8, 5), C["dark"])                       # шея
helm = sphere((-0.06, 0, 1.93), 0.155, 14, 8)
helm.scale = (1.12, 1.0, 1.0)
add(R, helm, C["helmet"], HELMET)                                               # шлем
add(R, box((0.09, 0, 1.84), (0.13, 0.20, 0.11), (0, -0.45, 0), 0.03), C["helmet"], HELMET)   # подбородок
add(R, box((0.08, 0, 2.02), (0.28, 0.28, 0.02), (0, -0.16, 0), 0.01), C["helmet"], HELMET)  # длинный козырёк
add(R, box((0.075, 0, 1.935), (0.07, 0.27, 0.08), bev=0.02), C["visor"])       # очки
add(R, box((-0.06, 0, 1.935), (0.24, 0.30, 0.035), bev=0.0), C["dark"])        # ремешок очков
for s in (1, -1):
    sh = (-0.13, 0.25 * s, 1.73)
    el = (0.10, 0.41 * s, 1.46)
    gr = (0.42, 0.38 * s, 1.18)
    add(R, sphere(sh, 0.08, 8, 5), C["jersey"], JERSEY)
    add(R, tube(sh, el, 0.068, 8), C["jersey"], JERSEY)
    add(R, sphere(el, 0.065, 8, 5), C["jersey"], JERSEY)
    add(R, tube(el, gr, 0.058, 8), C["jersey"], JERSEY)
    add(R, sphere(gr, 0.058, 8, 5), C["glove"])
    hp = (-0.28, 0.13 * s, 1.16)
    kn = (0.08, 0.38 * s, 1.04)
    an = (-0.05, 0.43 * s, 0.58)
    add(R, tube(hp, kn, 0.088, 8), C["pants"])
    add(R, sphere(kn, 0.085, 8, 5), C["pants"])
    add(R, tube(kn, an, 0.072, 8), C["pants"])
    add(R, box((0.0, 0.43 * s, 0.50), (0.29, 0.14, 0.18), bev=0.035), C["boot"])


# ---------------- сборка ----------------
def join(objs, name):
    for o in bpy.context.selected_objects:
        o.select_set(False)
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.join()
    ob = bpy.context.view_layer.objects.active
    ob.name = name
    ob.data.name = name
    me = ob.data
    me.shade_smooth()
    me.set_sharp_from_angle(angle=math.radians(38))
    return ob


mat = bpy.data.materials.new("ATV")
mat.use_nodes = True
nt = mat.node_tree
bsdf = nt.nodes["Principled BSDF"]
ca = nt.nodes.new("ShaderNodeVertexColor")
ca.layer_name = "Col"
nt.links.new(ca.outputs["Color"], bsdf.inputs["Base Color"])
bsdf.inputs["Roughness"].default_value = 0.55

body = join(parts["body"], "Body")
wheel = join(parts["wheel"], "Wheel_FL")
rider = join(parts["rider"], "Rider")
for o in (body, wheel, rider):
    o.data.materials.clear()
    o.data.materials.append(mat)
# начало координат гонщика — в тазу (вокруг него наклон)
rider.data.transform(Matrix.Translation(-HIP))
rider.location = HIP
# четыре колеса с общим мешем, начало — на оси
wheels = {"Wheel_FL": (HW, TRACK), "Wheel_FR": (HW, -TRACK), "Wheel_RL": (-HW, TRACK), "Wheel_RR": (-HW, -TRACK)}
wheel.location = (HW, TRACK, WR)
objs = [body, rider, wheel]
for nm, (x, y) in wheels.items():
    if nm == "Wheel_FL":
        continue
    o = bpy.data.objects.new(nm, wheel.data)
    o.location = (x, y, WR)
    col.objects.link(o)
    objs.append(o)


def tris(o):
    return sum(len(p.vertices) - 2 for p in o.data.polygons)


total = tris(body) + tris(rider) + 4 * tris(wheel)
print("TRIS body=%d rider=%d wheel=%d total=%d" % (tris(body), tris(rider), tris(wheel), total))


# ---------------- упрощённые копии для дальних квадроциклов (LOD) ----------------
# Body/Rider/Wheel + _LOD1/_LOD2 — Decimate; ботам игра показывает LOD1 вблизи и LOD2 дальше 25 м (quad.gd).
def lod(src, name, ratio):
    me = src.data.copy()
    o = bpy.data.objects.new(name, me)
    col.objects.link(o)
    o.matrix_world = src.matrix_world.copy()
    m = o.modifiers.new("dec", "DECIMATE")
    m.decimate_type = "COLLAPSE"
    m.ratio = ratio
    dg = bpy.context.evaluated_depsgraph_get()
    nm = bpy.data.meshes.new_from_object(o.evaluated_get(dg))
    o.modifiers.clear()
    o.data = nm
    nm.name = name
    nm.validate(clean_customdata=False)        # после Decimate бывают вырожденные грани — экспортёр на них ругается
    nm.update()
    nm.shade_smooth()
    nm.set_sharp_from_angle(angle=math.radians(38))
    return o


# LOD1 — боты вблизи (полная модель только у игрока), LOD2 — боты дальше 25 м
for suffix, rb, rr, rw in (("_LOD1", 0.45, 0.6, 0.45), ("_LOD2", 0.22, 0.3, 0.2)):
    lods = [lod(body, "Body" + suffix, rb), lod(rider, "Rider" + suffix, rr), lod(wheel, "Wheel" + suffix, rw)]
    objs += lods
    print("%s body=%d rider=%d wheel=%d total=%d" % (suffix, tris(lods[0]), tris(lods[1]), tris(lods[2]), tris(lods[0]) + tris(lods[1]) + 4 * tris(lods[2])))

# ---------------- исходник для ручной правки ----------------
# models/src/atv.blend — открыть в Blender, поправить, выгрузить tools/blender/export.py.
# Внимание: повторный запуск этого генератора перезапишет и .blend, и .glb.
os.makedirs(os.path.dirname(OUT), exist_ok=True)
BLEND = os.path.join(os.path.dirname(OUT), "src", os.path.splitext(os.path.basename(OUT))[0] + ".blend")
os.makedirs(os.path.dirname(BLEND), exist_ok=True)
bpy.ops.wm.save_as_mainfile(filepath=BLEND, copy=True)
print("BLEND", BLEND)

# ---------------- экспорт ----------------
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
print("GLB", OUT, os.path.getsize(OUT), "bytes")

# ---------------- превью ----------------
if RENDER:
    os.makedirs(RENDER, exist_ok=True)
    bpy.ops.mesh.primitive_plane_add(size=12, location=(0, 0, 0))
    g = bpy.context.active_object
    gm = bpy.data.materials.new("ground")
    gm.diffuse_color = (0.55, 0.5, 0.42, 1)
    g.data.materials.append(gm)
    scene.render.engine = "BLENDER_WORKBENCH"
    sh = scene.display.shading
    sh.light = "STUDIO"
    sh.color_type = "VERTEX"
    sh.show_shadows = True
    sh.show_cavity = True
    sh.cavity_type = "BOTH"
    scene.display.shadow_focus = 0.6
    scene.render.resolution_x = 960
    scene.render.resolution_y = 600
    scene.render.film_transparent = False
    w = bpy.data.worlds.new("w")
    scene.world = w
    w.color = (0.75, 0.8, 0.85)
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    col.objects.link(cam)
    scene.camera = cam
    cam.data.lens = 50
    views = {"side": ((0.2, -6.2, 1.5), (0.1, 0, 0.85)), "front34": ((3.6, -3.4, 2.2), (0.1, 0, 0.8)),
             "rear34": ((-3.6, -3.0, 2.3), (0, 0, 0.8)), "front": ((5.5, 0, 1.3), (0, 0, 0.8))}
    for nm, (pos, tgt) in views.items():
        cam.location = pos
        d = Vector(tgt) - Vector(pos)
        cam.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()
        scene.render.filepath = os.path.join(RENDER, nm + ".png")
        bpy.ops.render.render(write_still=True)
    print("RENDER", RENDER)

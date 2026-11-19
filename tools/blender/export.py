# Экспорт .blend → .glb для игры (после ручной правки модели в Blender).
#
# Из Blender: открыть models/src/atv.blend (или env.blend) → вкладка Scripting → Open → этот файл → Run Script.
# Из терминала:
#   /Applications/Blender.app/Contents/MacOS/Blender -b models/src/atv.blend -P tools/blender/export.py
#
# Куда пишет: models/src/atv.blend → models/atv.glb (рядом с папкой src). Можно указать путь: ... -P export.py -- путь.glb
# Выгружаются все видимые меш-объекты. Объекты со свойством export_at_origin (ассеты окружения, разложенные
# по сцене для удобства) выгружаются так, будто стоят в начале координат.
import bpy, os, sys

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
blend = bpy.data.filepath
if argv:
    out = os.path.abspath(argv[0])
else:
    if not blend:
        raise SystemExit("Сначала сохраните .blend — путь .glb берётся из его имени")
    src = os.path.dirname(blend)
    out = os.path.join(os.path.dirname(src), os.path.splitext(os.path.basename(blend))[0] + ".glb")

if bpy.context.mode != "OBJECT":
    bpy.ops.object.mode_set(mode="OBJECT")
objs = [o for o in bpy.context.scene.objects if o.type == "MESH" and o.visible_get()]
saved = {}
for o in objs:
    if o.get("export_at_origin"):
        saved[o.name] = o.location.copy()
        o.location = (0, 0, 0)
for o in bpy.context.selected_objects:
    o.select_set(False)
for o in objs:
    o.select_set(True)
bpy.context.view_layer.objects.active = objs[0]
kw = dict(filepath=out, export_format="GLB", use_selection=True, export_apply=True, export_yup=True,
          export_materials="EXPORT", export_normals=True, export_texcoords=True)
try:
    bpy.ops.export_scene.gltf(**kw, export_vertex_color="ACTIVE")
except TypeError:
    bpy.ops.export_scene.gltf(**kw, export_colors=True)
for name, loc in saved.items():
    bpy.data.objects[name].location = loc
print("EXPORT", out, len(objs), "объектов")

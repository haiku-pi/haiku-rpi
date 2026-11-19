# blender-m5-scene.py — a small lit scene with several materials for the EEVEE test of Blender milestone M5
# (docs/design/blender.md §7; tools/pi-tests/blender-m5.sh): a red glossy cube, a metallic sphere, a glass-like
# (transmission) monkey, a subsurface sphere (which renders as diffuse on 4 color attachments, with a one-time
# message), a ground plane, a sun and an area light. Renders at 960x540 with the engine of the command line.
#
#   blender -b --factory-startup --python blender-m5-scene.py -E BLENDER_EEVEE -o OUT -f 1
import bpy

scene = bpy.context.scene
for ob in list(bpy.data.objects):
    if ob.type == 'MESH':
        bpy.data.objects.remove(ob)


def material(name, color, metallic=0.0, roughness=0.4, transmission=0.0, subsurface=0.0):
    ma = bpy.data.materials.new(name)
    ma.use_nodes = True
    bsdf = ma.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*color, 1.0)
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Transmission"].default_value = transmission
    bsdf.inputs["Subsurface"].default_value = subsurface
    return ma


def add(op, location, ma, **kwargs):
    op(location=location, **kwargs)
    ob = bpy.context.active_object
    ob.data.materials.append(ma)
    return ob


add(bpy.ops.mesh.primitive_plane_add, (0, 0, -1), material("Ground", (0.6, 0.6, 0.55)), size=12)
add(bpy.ops.mesh.primitive_cube_add, (-2.2, 0, 0), material("Red", (0.8, 0.05, 0.03), roughness=0.25))
add(bpy.ops.mesh.primitive_uv_sphere_add, (0, 0, 0), material("Metal", (0.9, 0.75, 0.4), metallic=1.0,
    roughness=0.2), segments=48, ring_count=24)
add(bpy.ops.mesh.primitive_monkey_add, (2.2, 0, 0), material("Glass", (0.6, 0.8, 1.0), roughness=0.05,
    transmission=1.0))
add(bpy.ops.mesh.primitive_uv_sphere_add, (0, 2.2, -0.4), material("Skin", (0.9, 0.6, 0.5),
    subsurface=0.5), segments=32, ring_count=16, radius=0.6)
for ob in bpy.data.objects:
    if ob.type == 'MESH':
        for poly in ob.data.polygons:
            poly.use_smooth = ob.name.startswith(("Sphere", "Suzanne"))

bpy.ops.object.light_add(type='SUN', location=(4, -4, 6))
bpy.context.active_object.data.energy = 3.0
bpy.context.active_object.rotation_euler = (0.7, 0.2, 0.6)
bpy.ops.object.light_add(type='AREA', location=(-3, -3, 3))
bpy.context.active_object.data.energy = 300.0

cam = scene.camera
cam.location = (0.0, -8.5, 3.2)
cam.rotation_euler = (1.22, 0.0, 0.0)
scene.render.resolution_x = 960
scene.render.resolution_y = 540
scene.render.resolution_percentage = 100
scene.eevee.taa_render_samples = 32
scene.eevee.use_ssr = True
scene.cycles.samples = 32
print("BM5SCENE objects", len(bpy.data.objects), "materials", len(bpy.data.materials), flush=True)

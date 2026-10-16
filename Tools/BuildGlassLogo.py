"""Restyle the supplied Blender logo and bake camera-space normals for native glass."""
import bpy, json, math
from pathlib import Path
from mathutils import Vector

ROOT=Path('/Volumes/MacOSDisk/Oath App')
OUT=ROOT/'Design/Blender'
OUT.mkdir(parents=True,exist_ok=True)
s=bpy.context.scene
rings=[o for o in s.objects if o.type=='CURVE' and o.name.startswith('Oath / original')]
assert len(rings)==2, 'Expected the two original logo contours'
source_shape={o.name:{'splines':[len(sp.points) for sp in o.data.splines], 'dimensions':list(o.dimensions)} for o in rings}
# Preserve the source splines. A modestly broader bevel softens the glass
# while avoiding inset self-intersections in the tightly linked contours.
for o in rings:
    o.data.offset=0.0
    o.data.bevel_depth=0.12
    o.data.extrude=0.22
    o.data.bevel_resolution=32
bpy.context.view_layer.update()
restyled_shape={o.name:list(o.dimensions) for o in rings}
material=bpy.data.materials.new('Oath / Opaque White Glass Finish')
material.use_nodes=True
p=material.node_tree.nodes.get('Principled BSDF')
p.inputs['Base Color'].default_value=(0.965,0.980,1.0,1)
p.inputs['Metallic'].default_value=0.0
p.inputs['Roughness'].default_value=0.115
p.inputs['IOR'].default_value=1.46
p.inputs['Transmission Weight'].default_value=0.0
p.inputs['Alpha'].default_value=1.0
p.inputs['Coat Weight'].default_value=0.38
p.inputs['Coat Roughness'].default_value=0.065
p.inputs['Subsurface Weight'].default_value=0.025
material.diffuse_color=(0.965,0.980,1,1)
for o in rings:
    o.data.materials.clear()
    o.data.materials.append(material)
for light in [o for o in s.objects if o.type=='LIGHT']:
    light.data.color=(1.0,1.0,1.0)
    if 'sapphire' in light.name: light.name='Right / white rim'
    light.data.energy*=0.8
s.world.node_tree.nodes['Background'].inputs['Color'].default_value=(0.70,0.74,0.78,1)
s.world.node_tree.nodes['Background'].inputs['Strength'].default_value=0.26
camera=s.camera
camera.location=(0,-1.1,18)
camera.rotation_euler=(Vector((0,0,0))-camera.location).to_track_quat('-Z','Y').to_euler()
camera.data.ortho_scale=9.5
s.render.engine='CYCLES'
s.cycles.device='CPU'
s.cycles.samples=128
s.cycles.use_denoising=True
s.cycles.max_bounces=12
s.cycles.transmission_bounces=8
s.render.threads_mode='FIXED';s.render.threads=10
s.render.resolution_x=4096;s.render.resolution_y=3072;s.render.resolution_percentage=100
s.render.film_transparent=True
s.render.image_settings.file_format='PNG'
s.render.image_settings.color_mode='RGBA'
s.render.image_settings.color_depth='16'
s.view_settings.view_transform='AgX'
s.view_settings.look='AgX - Medium High Contrast'
s.view_settings.exposure=0.3
s.frame_set(1)
s.render.filepath=str(OUT/'Oath-White-Glass-4K.png')
# Save the editable material scene, with original geometry and neutral lighting.
bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'Oath-White-Liquid-Glass.blend'))
bpy.ops.render.render(write_still=True)

# An unlit, camera-space normal atlas preserves the actual Blender silhouette,
# bevel and thickness. iOS uses it to light an opaque white surface.
normal=bpy.data.materials.new('Oath / camera normal bake')
normal.use_nodes=True
nodes=normal.node_tree.nodes;nodes.clear();links=normal.node_tree.links
geo=nodes.new('ShaderNodeNewGeometry')
transform=nodes.new('ShaderNodeVectorTransform')
transform.vector_type='NORMAL';transform.convert_from='WORLD';transform.convert_to='CAMERA'
links.new(geo.outputs['Normal'],transform.inputs['Vector'])
scale=nodes.new('ShaderNodeVectorMath');scale.operation='SCALE';scale.inputs[3].default_value=0.5
links.new(transform.outputs['Vector'],scale.inputs[0])
add=nodes.new('ShaderNodeVectorMath');add.operation='ADD';add.inputs[1].default_value=(0.5,0.5,0.5)
links.new(scale.outputs['Vector'],add.inputs[0])
emission=nodes.new('ShaderNodeEmission');links.new(add.outputs['Vector'],emission.inputs['Color'])
output=nodes.new('ShaderNodeOutputMaterial');links.new(emission.outputs[0],output.inputs['Surface'])
for o in rings:o.data.materials[0]=normal
s.view_settings.view_transform='Raw'
s.view_settings.look='None'
s.view_settings.exposure=0
s.view_settings.gamma=1
s.cycles.samples=128;s.cycles.use_denoising=False
s.render.resolution_x=4096;s.render.resolution_y=3072
s.render.image_settings.color_depth='8'
s.render.filepath=str(ROOT/'OathApp/Resources/OathGlassNormals.png')
bpy.ops.render.render(write_still=True)
(OUT/'logo-export.json').write_text(json.dumps({
 'source':'oath-glass-light.blend','source_geometry':source_shape,
 'contours_preserved':True,'restyled_dimensions':restyled_shape,'material':'opaque white polished glass finish','ior':1.46,
 'transmission':0.0,'alpha':1.0,'roughness':0.115,
 'normal_map':'camera space; linear RGB remapped from [-1,1] to [0,1]; alpha coverage',
 'normal_size':[4096,3072], 'beauty_size':[4096,3072], 'camera_ortho_width':9.5,
 'saved_blend':'Oath-White-Liquid-Glass.blend'
},indent=2))
print('OATH_GLASS_EXPORT_COMPLETE')

import bpy, json
from mathutils import Vector
result={'scene':bpy.context.scene.name,'engine':bpy.context.scene.render.engine,'camera':bpy.context.scene.camera.name if bpy.context.scene.camera else None,'objects':[],'materials':[]}
for o in bpy.context.scene.objects:
    item={'name':o.name,'type':o.type,'location':list(o.location),'rotation':list(o.rotation_euler),'scale':list(o.scale),'dimensions':list(o.dimensions),'hide_render':o.hide_render}
    if o.type in ('MESH','CURVE','FONT'):
        item['materials']=[m.name for m in o.data.materials if m]
        item['modifiers']=[{'name':m.name,'type':m.type} for m in o.modifiers]
        item['bounds_world']=[list(o.matrix_world@Vector(v)) for v in o.bound_box]
    if o.type=='CAMERA': item.update({'lens':o.data.lens,'camera_type':o.data.type,'ortho_scale':o.data.ortho_scale})
    result['objects'].append(item)
for m in bpy.data.materials:
    d={'name':m.name,'diffuse':list(m.diffuse_color)}
    if m.use_nodes:
        d['nodes']=[{'name':n.name,'type':n.type} for n in m.node_tree.nodes]
    result['materials'].append(d)
print('OATH_SCENE_DATA='+json.dumps(result))

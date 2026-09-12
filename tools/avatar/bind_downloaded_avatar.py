"""Bind Blender Studio's CC0 realistic male base mesh to CoachMe's display rig.
No body geometry is generated. Source: human-base-meshes-bundle-v1.2.0.zip.
Usage: blender -b --python bind_downloaded_avatar.py -- source.blend rest.json out
"""
import bpy, json, sys, math
from pathlib import Path
from mathutils import Vector, Matrix
args=sys.argv[sys.argv.index('--')+1:]
source=Path(args[0]);rest=json.loads(Path(args[1]).read_text());out=Path(args[2]);out.mkdir(parents=True,exist_ok=True)
bpy.ops.object.select_all(action='SELECT');bpy.ops.object.delete(use_global=False)
with bpy.data.libraries.load(str(source),link=False) as (a,b):
 b.objects=[n for n in a.objects if n=='GEO-body_male_realistic' or n.startswith('GEO-body_male_realistic.eye')]
body=next(o for o in b.objects if o.name=='GEO-body_male_realistic')
for o in b.objects:
 bpy.context.collection.objects.link(o);o.parent=None
 for m in list(o.modifiers):o.modifiers.remove(m)
bpy.context.view_layer.update()
pts=[body.matrix_world@v.co for v in body.data.vertices];cx=(min(p.x for p in pts)+max(p.x for p in pts))/2
for o in b.objects:
 mat=o.matrix_world.copy()
 for v in o.data.vertices:
  p=mat@v.co;v.co=(p.x-cx,p.z,-p.y)
 o.matrix_world=Matrix.Identity(4);o.select_set(True)
bpy.context.view_layer.objects.active=body;bpy.ops.object.join();body.name='BlenderStudio_RealisticMale_Golf'
body.data.materials.clear()
# Locate an anatomical rig in the downloaded A-pose. Coordinates are metres, Y-up.
source_bones=[dict(name='pelvis',start=[0,.80,0],end=[0,1.04,0]),
 dict(name='spine',start=[0,.87,0],end=[0,1.325,0]),
 dict(name='head',start=[0,1.395,.005],end=[0,1.67,.015])]
for name,s in [('left',-1),('right',1)]:
 sh=[s*.185,1.325,0];el=[s*.282,1.105,.012];wr=[s*.377,.853,.025]
 hip=[s*.105,.87,0];kn=[s*.140,.465,.005];an=[s*.175,.082,.005]
 for suffix,a,z in [('UpperArm',sh,el),('Forearm',el,wr),('Hand',wr,[s*.419,.732,.034]),('Thigh',hip,kn),('Shin',kn,an),('Foot',an,[s*.194,.04,.158])]:
  source_bones.append(dict(name=name+suffix,start=a,end=z))
bones=rest['bones'];bone_by={b['name']:b for b in bones}
assert [b['name'] for b in source_bones]==[b['name'] for b in bones]
def frame_matrix(b):
 a=Vector(b['start']);d=Vector(b['end'])-a;y=d.normalized()
 # Must match SceneKit's torso across-axis frame, including the roll.
 raw=Vector((1,0,0));x=(raw-y*raw.dot(y)).normalized();z=x.cross(y)
 m=Matrix((x,y,z)).transposed().to_4x4()
 m.translation=a;return m
arm_data=bpy.data.armatures.new('CoachMeRig');arm=bpy.data.objects.new('CoachMeRig',arm_data);bpy.context.collection.objects.link(arm)
bpy.context.view_layer.objects.active=arm;arm.select_set(True);body.select_set(False)
bpy.ops.object.mode_set(mode='EDIT')
for b in source_bones:
 bone=arm_data.edit_bones.new(b['name']);bone.head=b['start'];bone.tail=b['end']
bpy.ops.object.mode_set(mode='OBJECT')
body.select_set(True);bpy.context.view_layer.objects.active=arm
bpy.ops.object.parent_set(type='ARMATURE_AUTO')
# Retain the strongest four heat-map weights (mobile skinning limit), normalized.
weights=[];indices=[]
for v in body.data.vertices:
 influences=sorted([(g.weight,g.group) for g in v.groups if g.weight>1e-8],reverse=True)[:4]
 if not influences and v.index>=10582:
  body.vertex_groups['head'].add([v.index],1,'REPLACE');influences=[(1,2)]
 if not influences:raise RuntimeError('Automatic binding left an unweighted vertex: '+str(v.index))
 total=sum(w for w,i in influences)
 while len(influences)<4:influences.append((0,0))
 weights.extend([w/total for w,i in influences]);indices.extend([i for w,i in influences])
assert [g.name for g in body.vertex_groups]==[b['name'] for b in bones]
# Adapt the existing mesh to the app's fixed-proportion bind rig, preserving topology.
transforms=[]
for src,dst in zip(source_bones,bones):
 scale=(Vector(dst['end'])-Vector(dst['start'])).length/(Vector(src['end'])-Vector(src['start'])).length
 transforms.append(frame_matrix(dst)@Matrix.Diagonal((1,scale,1,1))@frame_matrix(src).inverted())
for v in body.data.vertices:
 p=v.co.copy();v.co=sum(((transforms[indices[v.index*4+k]]@p)*weights[v.index*4+k] for k in range(4)),Vector((0,0,0)))
# Rebuild armature rest state to agree exactly with the mobile rig.
bpy.ops.object.select_all(action='DESELECT');arm.select_set(True);bpy.context.view_layer.objects.active=arm
bpy.ops.object.mode_set(mode='EDIT')
for b in bones:
 bone=arm.data.edit_bones[b['name']];bone.head=b['start'];bone.tail=b['end']
bpy.ops.object.mode_set(mode='OBJECT')
# One subdivision improves the existing face and joint contours; it also interpolates weights.
bpy.context.view_layer.objects.active=body
sub=body.modifiers.new('Mobile smooth surface','SUBSURF');sub.levels=1
# Apply subdivision without applying the rest-state armature modifier.
bpy.ops.object.modifier_apply(modifier=sub.name)
weights=[];indices=[]
for v in body.data.vertices:
 inf=sorted([(g.weight,g.group) for g in v.groups if g.weight>1e-8],reverse=True)[:4];total=sum(w for w,i in inf)
 while len(inf)<4:inf.append((0,0))
 weights.extend([round(w/total,7) for w,i in inf]);indices.extend([i for w,i in inf])
for p in body.data.polygons:p.use_smooth=True
body.data.update();body.data.calc_loop_triangles()
mesh={'version':1,'source':'Blender Studio Human Base Meshes v1.2.0 — realistic male','license':'CC0-1.0','boneNames':[b['name'] for b in bones],
'positions':[round(x,6) for v in body.data.vertices for x in v.co],
'normals':[round(x,6) for v in body.data.vertices for x in v.normal],
 'triangles':[int(i) for t in body.data.loop_triangles for i in t.vertices], 'weights':weights,'boneIndices':indices}
(out/'GolfAvatar.mesh.json').write_text(json.dumps(mesh,separators=(',',':')))
for b in rest['previewBones']:
 old=bone_by[b['name']];arm.pose.bones[b['name']].matrix=frame_matrix(b)@frame_matrix(old).inverted()@arm.data.bones[b['name']].matrix_local
bpy.context.view_layer.update()
material=bpy.data.materials.new('Blue anatomical glass'); material.diffuse_color=(0.13,0.40,0.82,0.55); material.use_nodes=True
bs=material.node_tree.nodes.get('Principled BSDF'); bs.inputs['Base Color'].default_value=(0.13,0.40,0.82,1); bs.inputs['Metallic'].default_value=0.08; bs.inputs['Roughness'].default_value=0.25
body.data.materials.append(material)
# Neutral studio preview of the actual modeled surface.
scene=bpy.context.scene; scene.render.engine='BLENDER_EEVEE_NEXT'; scene.world.color=(0.7,0.7,0.7)
bpy.ops.object.camera_add(location=(2.2,1.6,3.5)); camera=bpy.context.object; forward=(Vector((0,0.9,0))-camera.location).normalized(); right=forward.cross(Vector((0,1,0))).normalized(); vertical=right.cross(forward).normalized(); camera.rotation_euler=Matrix((right,vertical,-forward)).transposed().to_euler(); camera.data.type='ORTHO'; camera.data.ortho_scale=2.2; scene.camera=camera
for name,loc,power,size in [('Key',(-3,4,4),650,5),('Fill',(3,2,2),450,4),('Rim',(0,3,-3),750,3)]:
    bpy.ops.object.light_add(type='AREA',location=loc); light=bpy.context.object; light.name=name; light.data.energy=power; light.data.shape='DISK'; light.data.size=size; light.rotation_euler=(Vector((0,0.9,0))-light.location).to_track_quat('-Z','Y').to_euler()
scene.render.resolution_x=800; scene.render.resolution_y=1000; scene.render.resolution_percentage=100
scene.render.image_settings.file_format='PNG'; scene.render.filepath=str(out/'standard-human.png')
scene.render.film_transparent=True
bpy.ops.wm.save_as_mainfile(filepath=str(out/'CoachMe_StandardHuman.blend'))
bpy.ops.render.render(write_still=True)
print('AVATAR_EXPORT',len(body.data.vertices),'vertices',len(body.data.loop_triangles),'triangles')

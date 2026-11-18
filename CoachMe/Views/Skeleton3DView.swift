import SwiftUI
import SceneKit
import CoachMeCore
import simd

@MainActor
struct Skeleton3DView: View {
    let frame: PoseFrame?
    let handedness: Handedness
    @State private var standardPose = false
    @State private var showBones = true
    @State private var angle: Double = 0.35
    @State private var reset = 0

    var body: some View {
        VStack(spacing:10) {
            HStack {
                Text(standardPose ? "标准人形 · 准备姿势" : "动作映射")
                    .font(.caption.weight(.medium))
                Spacer()
                Toggle("骨骼",isOn:$showBones).toggleStyle(.button).font(.caption)
            }
            AvatarSceneView(frame:standardPose ? nil : frame, angle:angle, reset:reset, showBones:showBones)
                .clipShape(RoundedRectangle(cornerRadius:18))
                .accessibilityLabel("半透明三维人体，可拖动旋转、双指缩放")
            HStack(spacing:12) {
                Button("正面") { angle=0; reset += 1 }
                Button("侧面") { angle = .pi/2; reset += 1 }
                Button("斜侧") { angle=0.65; reset += 1 }
                Spacer()
                Toggle("标准姿势",isOn:$standardPose).toggleStyle(.button)
            }.font(.caption).buttonStyle(.bordered)
            Text(frame == nil || standardPose ? "标准体型与球杆示意，不代表个人动作。" : "固定体型由动作数据驱动；遮挡与异常姿态使用约束补位，仅供观察。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

@MainActor
struct AvatarSceneView: UIViewRepresentable {
    let frame: PoseFrame?
    let angle: Double
    let reset: Int
    let showBones: Bool
    /// Draws on the workbench's dark video panel instead of the grouped background.
    var darkStage = false

    func makeCoordinator() -> AvatarSceneCoordinator { AvatarSceneCoordinator() }
    func makeUIView(context:Context) -> SCNView {
        let view=SCNView()
        view.scene=context.coordinator.scene
        view.pointOfView=context.coordinator.camera
        view.backgroundColor=UIColor.secondarySystemGroupedBackground
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl=true
        view.defaultCameraController.target=SCNVector3(0,0.95,0)
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.preferredFramesPerSecond=30
        view.autoenablesDefaultLighting=false
        if darkStage {
            view.backgroundColor=UIColor(hex:0x0E1311)
            context.coordinator.scene.background.contents=UIColor(hex:0x0E1311)
        }
        return view
    }
    func updateUIView(_ view:SCNView,context:Context) {
        context.coordinator.update(frame:frame,showBones:showBones)
        if context.coordinator.lastReset != reset {
            context.coordinator.lastReset=reset
            context.coordinator.camera.position=SCNVector3(Float(sin(angle)*3.4),1.4,Float(cos(angle)*3.4))
            context.coordinator.camera.look(at:SCNVector3(0,0.92,0))
            view.pointOfView=context.coordinator.camera
        }
    }
}

@MainActor
final class AvatarSceneCoordinator {
    let scene=SCNScene()
    let camera=SCNNode()
    var lastReset = -1
    private let rig=SCNNode()
    private var boneNodes:[SCNNode]=[]
    private var innerBones:[SCNNode]=[]
    private let internalRoot=SCNNode()
    private let standardClub=SCNNode()
    private let rest=GolfAvatarPose.bindPose
    private var initialized=false
    private var previousTimestamp:Double?
    private var hadFrame=false

    init() {
        scene.background.contents=UIColor.secondarySystemGroupedBackground
        camera.camera=SCNCamera()
        camera.camera?.usesOrthographicProjection=true
        camera.camera?.orthographicScale=1.08
        camera.camera?.zNear=0.01; camera.camera?.zFar=30
        scene.rootNode.addChildNode(camera)
        scene.rootNode.addChildNode(rig)
        rig.addChildNode(internalRoot)
        addLight(type:.ambient,position:SCNVector3(0,2,0),intensity:180)
        addLight(type:.omni,position:SCNVector3(-2,3,4),intensity:450)
        addLight(type:.omni,position:SCNVector3(2,2,-2),intensity:250)
        let base=SCNCylinder(radius:0.65,height:0.018)
        base.firstMaterial=material(UIColor.systemGray5,metal:0,rough:0.85)
        let baseNode=SCNNode(geometry:base); baseNode.position=SCNVector3(0,-0.025,0)
        scene.rootNode.addChildNode(baseNode)
        for bone in rest.bones {
            let node=SCNNode(); node.name=bone.name; node.simdTransform=Self.transform(bone)
            rig.addChildNode(node); boneNodes.append(node)
            let length=(bone.end-bone.start).length
            let geometry=SCNCapsule(capRadius:bone.name == "spine" ? 0.013 : 0.011,height:CGFloat(length))
            geometry.radialSegmentCount=10
            geometry.firstMaterial=material(UIColor(red:0.87,green:0.94,blue:1,alpha:1),metal:0,rough:0.6)
            let inner=SCNNode(geometry:geometry); inner.simdTransform=Self.transform(bone)
            let center=SIMD3<Float>(0,Float(length/2),0)
            let local=SCNNode(geometry:geometry); local.simdPosition=center
            inner.geometry=nil; inner.addChildNode(local)
            inner.opacity=0.45
            internalRoot.addChildNode(inner); innerBones.append(inner)
        }
        addRibs()
        addStandardClub()
        loadSkin()
        update(frame:nil,showBones:true)
    }

    private func addStandardClub() {
        let pose=GolfAvatarPose(frame:nil)
        let hands=(pose.joints[.leftWrist]!+pose.joints[.rightWrist]!)/2
        let end=Vector3(0.22,0.05,0.82)
        let bone=GolfAvatarBone("demonstrationClub",hands,end)
        standardClub.simdTransform=Self.transform(bone)
        let length=(end-hands).length
        let shaft=SCNCylinder(radius:0.007,height:CGFloat(length)); shaft.radialSegmentCount=12
        shaft.firstMaterial=material(UIColor.systemGray,metal:0.6,rough:0.3)
        let rod=SCNNode(geometry:shaft); rod.position=SCNVector3(0,Float(length/2),0); standardClub.addChildNode(rod)
        let grip=SCNCylinder(radius:0.014,height:0.14); grip.firstMaterial=material(UIColor.darkGray,metal:0,rough:0.8)
        let handle=SCNNode(geometry:grip); handle.position=SCNVector3(0,0.04,0); standardClub.addChildNode(handle)
        let head=SCNBox(width:0.12,height:0.045,length:0.065,chamferRadius:0.018)
        head.firstMaterial=material(UIColor.systemGray3,metal:0.5,rough:0.3)
        let headNode=SCNNode(geometry:head); headNode.position=SCNVector3(0.04,Float(length),0); standardClub.addChildNode(headNode)
        scene.rootNode.addChildNode(standardClub)
    }

    private func addLight(type:SCNLight.LightType,position:SCNVector3,intensity:CGFloat) {
        let node=SCNNode(); node.light=SCNLight(); node.light?.type=type; node.light?.intensity=intensity
        node.position=position; scene.rootNode.addChildNode(node)
    }
    private func material(_ color:UIColor,metal:CGFloat,rough:CGFloat) -> SCNMaterial {
        let m=SCNMaterial(); m.lightingModel = .physicallyBased; m.diffuse.contents=color
        m.metalness.contents=metal; m.roughness.contents=rough; return m
    }
    private func addRibs() {
        // Stylized inner structure, not a medical anatomical model.
        guard innerBones.count>2 else{return}
        for i in 0..<7 {
            let radius=CGFloat(0.12+0.04*sin(Double(i)/6 * .pi))
            let shape=SCNTorus(ringRadius:radius,pipeRadius:0.0045)
            shape.ringSegmentCount=32; shape.pipeSegmentCount=6
            shape.firstMaterial=material(UIColor(red:0.79,green:0.89,blue:1,alpha:1),metal:0,rough:0.65)
            let node=SCNNode(geometry:shape); node.position=SCNVector3(0,0.17+Float(i)*0.04,0)
            node.scale=SCNVector3(1,1,0.57); innerBones[1].addChildNode(node)
        }

    }

    private struct Mesh:Decodable {
        let boneNames:[String]
        let positions:[Float]
        let normals:[Float]
        let triangles:[UInt32]
        let weights:[Float]
        let boneIndices:[UInt16]
    }
    private func loadSkin() {
        guard let url=Bundle.main.url(forResource:"GolfAvatar.mesh",withExtension:"json"),
              let data=try? Data(contentsOf:url),let mesh=try? JSONDecoder().decode(Mesh.self,from:data),
              mesh.boneNames == rest.bones.map(\.name),mesh.positions.count % 3 == 0,
              mesh.normals.count == mesh.positions.count,mesh.weights.count == mesh.positions.count/3*4,
              mesh.boneIndices.count == mesh.weights.count else { return }
        let count=mesh.positions.count/3
        let vertices=(0..<count).map { i in SCNVector3(mesh.positions[i*3],mesh.positions[i*3+1],mesh.positions[i*3+2]) }
        let normals=(0..<count).map { i in SCNVector3(mesh.normals[i*3],mesh.normals[i*3+1],mesh.normals[i*3+2]) }
        let geometry=SCNGeometry(sources:[SCNGeometrySource(vertices:vertices),SCNGeometrySource(normals:normals)],
            elements:[SCNGeometryElement(indices:mesh.triangles,primitiveType:.triangles)])
        let skin=material(UIColor(red:0.18,green:0.45,blue:0.92,alpha:1),metal:0.12,rough:0.28)
        skin.lightingModel = .blinn
        skin.specular.contents=UIColor(white:0.3,alpha:1); skin.shininess=24
        skin.transparency=0.86; skin.transparencyMode = .dualLayer; skin.isDoubleSided=false
        skin.writesToDepthBuffer=true
        geometry.firstMaterial=skin
        let weights=SCNGeometrySource(data:mesh.weights.withUnsafeBytes { Data($0) },semantic:.boneWeights,
            vectorCount:count,usesFloatComponents:true,componentsPerVector:4,bytesPerComponent:4,dataOffset:0,dataStride:16)
        let indices=SCNGeometrySource(data:mesh.boneIndices.withUnsafeBytes { Data($0) },semantic:.boneIndices,
            vectorCount:count,usesFloatComponents:false,componentsPerVector:4,bytesPerComponent:2,dataOffset:0,dataStride:8)
        let node=SCNNode(geometry:geometry)
        node.skinner=SCNSkinner(baseGeometry:geometry,bones:boneNodes,
            boneInverseBindTransforms:rest.bones.map { NSValue(scnMatrix4:SCNMatrix4(simd_inverse(Self.transform($0)))) },
            boneWeights:weights,boneIndices:indices)
        node.skinner?.skeleton=rig
        node.renderingOrder=10
        rig.addChildNode(node)
    }
    func update(frame:PoseFrame?,showBones:Bool) {
        internalRoot.isHidden = !showBones
        standardClub.isHidden = frame != nil
        guard !initialized || frame?.timestampSeconds != previousTimestamp || hadFrame != (frame != nil) else{return}
        initialized=true
        previousTimestamp=frame?.timestampSeconds; hadFrame=frame != nil
        let pose=GolfAvatarPose(frame:frame)
        SCNTransaction.begin(); SCNTransaction.animationDuration=0
        for (index,bone) in pose.bones.enumerated() {
            boneNodes[index].simdTransform=Self.transform(bone)
            innerBones[index].simdTransform=Self.transform(bone)
        }
        SCNTransaction.commit()
    }
    static func transform(_ bone:GolfAvatarBone) -> simd_float4x4 {
        let start=SIMD3<Float>(Float(bone.start.x),Float(bone.start.y),Float(bone.start.z))
        let end=SIMD3<Float>(Float(bone.end.x),Float(bone.end.y),Float(bone.end.z))
        if let across=bone.across {
            let y=simd_normalize(end-start)
            let rawX=SIMD3<Float>(Float(across.x),Float(across.y),Float(across.z))
            let projected=rawX-y*simd_dot(rawX,y)
            if simd_length(projected)>0.0001 {
                let x=simd_normalize(projected),z=simd_cross(x,y)
                return simd_float4x4(columns:(SIMD4<Float>(x,0),SIMD4<Float>(y,0),SIMD4<Float>(z,0),SIMD4<Float>(start,1)))
            }
        }
        let q=simd_quatf(from:SIMD3<Float>(0,1,0),to:simd_normalize(end-start))
        var matrix=simd_float4x4(q); matrix.columns.3=SIMD4<Float>(start,1); return matrix
    }
}

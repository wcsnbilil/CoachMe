import XCTest
import SceneKit
import Metal
import CoachMeCore
@testable import CoachMe

final class AvatarRenderingTests:XCTestCase {
    @MainActor func testBundledBlenderSkinIsBoundAndRenders() throws {
        let avatar=AvatarSceneCoordinator()
        var skin:SCNNode?
        avatar.scene.rootNode.enumerateChildNodes { node,_ in if node.skinner != nil { skin=node } }
        let node=try XCTUnwrap(skin)
        XCTAssertEqual(node.skinner?.bones.count,15)
        XCTAssertGreaterThan(node.geometry?.sources(for:.vertex).first?.vectorCount ?? 0,5000)
        avatar.camera.position=SCNVector3(2,1.4,3.4)
        avatar.camera.look(at:SCNVector3(0,0.9,0))
        let renderer=SCNRenderer(device:MTLCreateSystemDefaultDevice(),options:nil)
        renderer.scene=avatar.scene; renderer.pointOfView=avatar.camera
        XCTAssertTrue(renderer.prepare(avatar.scene,shouldAbortBlock:nil))
        _=renderer.snapshot(atTime:0,with:CGSize(width:700,height:850),antialiasingMode:.multisampling4X)
        let image=renderer.snapshot(atTime:0,with:CGSize(width:700,height:850),antialiasingMode:.multisampling4X)
        let directory=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("avatar-review")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try XCTUnwrap(image.pngData()).write(to:directory.appendingPathComponent("standard-avatar.png"))
        // Also render an opaque surface to distinguish skinning errors from glass compositing.
        let surface=try XCTUnwrap(node.geometry?.firstMaterial)
        let opacity=surface.transparency
        surface.transparency=1
        avatar.update(frame:nil,showBones:false)
        let solid=renderer.snapshot(atTime:0,with:CGSize(width:700,height:850),antialiasingMode:.multisampling4X)
        try XCTUnwrap(solid.pngData()).write(to:directory.appendingPathComponent("solid-avatar.png"))
        surface.transparency=opacity
        let library=SwingLibrary()
        if let record=library.swings.first,let cache=library.analysis(for:record),
           let frame=cache.frames.first(where:{ $0.worldLandmarks?.isEmpty == false && $0.timestampSeconds>2 }) {
            avatar.update(frame:frame,showBones:true)
            let posed=renderer.snapshot(atTime:0,with:CGSize(width:700,height:850),antialiasingMode:.multisampling4X)
            try XCTUnwrap(posed.pngData()).write(to:directory.appendingPathComponent("driven-avatar.png"))
        }
    }
}

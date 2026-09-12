import Foundation
@main struct Export {
 static func main() throws {
  let pose=GolfAvatarPose.bindPose
  func arr(_ v:Vector3)->[Double] {[v.x,v.y,v.z]}
  let data:[String:Any] = ["joints":Dictionary(uniqueKeysWithValues:pose.joints.map { (String($0.key.rawValue),arr($0.value)) }),"previewBones":GolfAvatarPose(frame:nil).bones.map { ["name":$0.name,"start":arr($0.start),"end":arr($0.end)] },"bones":pose.bones.map { ["name":$0.name,"start":arr($0.start),"end":arr($0.end)] }]
  print(String(decoding:try JSONSerialization.data(withJSONObject:data,options:[.sortedKeys]),as:UTF8.self))
 }
}

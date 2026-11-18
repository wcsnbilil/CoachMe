import Foundation

/// The authoritative definitions for every metric CoachMe computes.
///
/// The wording here is what the app shows and what a coach's reference range is
/// bound to. Nothing in this file claims anatomical measurement beyond what the
/// three landmark positions can support.
public enum MetricCatalog {

    public static let all: [MetricDefinition] = [
        elbowInteriorAngle,
        upperArmToTorsoAngle,
        betweenUpperArmsAngle,
        kneeInteriorAngle,
        wristPathBodyReferenced,
        shoulderLineRotation,
        hipLineRotation,
        shoulderHipSeparation
    ]

    public static func definition(for id: MetricID) -> MetricDefinition {
        // Total over MetricID by construction; `all` is kept in sync by a test.
        all.first { $0.id == id }!
    }

    // MARK: - Group 1

    public static let elbowInteriorAngle = MetricDefinition(
        id: .elbowInteriorAngle,
        nameZH: "肘部内夹角",
        nameEN: "Elbow interior angle",
        joints: [.leftShoulder, .leftElbow, .leftWrist],
        formula: "angle at ELBOW between (SHOULDER - ELBOW) and (WRIST - ELBOW)",
        space: .worldEstimate3D,
        referenceFrameZH: "无需外部参考，仅由肩、肘、腕三点相对位置决定",
        projectionZH: "三维向量夹角，不做平面投影",
        zeroAndSignZH: "手臂完全伸直约 180°，弯曲时减小；始终为非负值，无方向性",
        range: 0...180,
        unit: "°",
        applicableViews: [.faceOn, .downTheLine, .unknown],
        requiresAddressReference: false,
        caveatZH: "屈曲角 = 180° − 内夹角。此值不代表前臂旋前/旋后，也不代表手腕屈伸。"
    )

    public static let upperArmToTorsoAngle = MetricDefinition(
        id: .upperArmToTorsoAngle,
        nameZH: "上臂与躯干夹角",
        nameEN: "Upper arm to torso angle",
        joints: [.leftShoulder, .leftElbow, .leftHip, .rightHip, .rightShoulder],
        formula: "angle between (ELBOW - SHOULDER) and (hipCentre - shoulderCentre)",
        space: .worldEstimate3D,
        referenceFrameZH: "躯干长轴：肩中点 → 髋中点（向下为参考方向）",
        projectionZH: "三维向量夹角，不做平面投影",
        zeroAndSignZH: "上臂沿躯干向下自然下垂时约 0°，向上举起时增大至约 180°；无正负方向",
        range: 0...180,
        unit: "°",
        applicableViews: [.faceOn, .downTheLine, .unknown],
        requiresAddressReference: false,
        caveatZH: "这是上臂方向与躯干长轴的夹角，不是解剖学意义上的肩关节外展或旋转，无法区分手臂向前、向侧或向后抬起。"
    )

    public static let betweenUpperArmsAngle = MetricDefinition(
        id: .betweenUpperArmsAngle,
        nameZH: "双上臂夹角",
        nameEN: "Angle between upper arms",
        joints: [.leftShoulder, .leftElbow, .rightShoulder, .rightElbow],
        formula: "angle between (leftELBOW - leftSHOULDER) and (rightELBOW - rightSHOULDER)",
        space: .worldEstimate3D,
        referenceFrameZH: "无需外部参考，由两侧上臂方向决定",
        projectionZH: "三维向量夹角，不做平面投影",
        zeroAndSignZH: "两上臂方向一致时 0°，反向时 180°；无正负方向",
        range: 0...180,
        unit: "°",
        applicableViews: [.faceOn, .downTheLine, .unknown],
        requiresAddressReference: false,
        caveatZH: "仅反映两侧上臂方向差异，不代表双臂三角形的形状或手部关系。"
    )

    public static let kneeInteriorAngle = MetricDefinition(
        id: .kneeInteriorAngle,
        nameZH: "膝部内夹角",
        nameEN: "Knee interior angle",
        joints: [.leftHip, .leftKnee, .leftAnkle],
        formula: "angle at KNEE between (HIP - KNEE) and (ANKLE - KNEE)",
        space: .worldEstimate3D,
        referenceFrameZH: "无需外部参考，仅由髋、膝、踝三点相对位置决定",
        projectionZH: "三维向量夹角，不做平面投影",
        zeroAndSignZH: "腿完全伸直约 180°，弯曲时减小；无正负方向",
        range: 0...180,
        unit: "°",
        applicableViews: [.faceOn, .downTheLine, .unknown],
        requiresAddressReference: false,
        caveatZH: "下肢常被身体或球杆遮挡，读数前请检查该帧的可见度标识。"
    )

    public static let wristPathBodyReferenced = MetricDefinition(
        id: .wristPathBodyReferenced,
        nameZH: "手腕相对躯干位置",
        nameEN: "Wrist position relative to torso",
        joints: [.leftWrist, .leftHip, .rightHip, .leftShoulder, .rightShoulder],
        formula: "(WRIST - hipCentre) projected onto (lateral, forward, up) of the torso frame, divided by torso length",
        space: .worldEstimate3D,
        referenceFrameZH: "躯干坐标系：原点为髋中点，up = 髋中点→肩中点，lateral = 左髋→右髋（对 up 正交化），forward = up × lateral",
        projectionZH: "三维分量，按躯干长度归一化（无量纲）",
        zeroAndSignZH: "原点为髋中点；lateral 正方向指向右髋侧，up 正方向指向肩部，forward 由右手定则确定",
        range: -5...5,
        unit: "torso lengths",
        applicableViews: [.faceOn, .downTheLine, .unknown],
        requiresAddressReference: false,
        caveatZH: "因原点与坐标轴随躯干移动旋转，人物整体走动或镜头移动不会计入。这与画面轨迹不同，画面轨迹包含身体整体位移。"
    )

    // MARK: - Group 2 — estimates with stated limits

    public static let shoulderLineRotation = MetricDefinition(
        id: .shoulderLineRotation,
        nameZH: "肩线转角（相对准备姿势）",
        nameEN: "Shoulder line rotation relative to address",
        joints: [.leftShoulder, .rightShoulder, .leftHip, .rightHip],
        formula: "signed angle from address (rightSHOULDER - leftSHOULDER) to current (rightSHOULDER - leftSHOULDER), both projected onto the plane perpendicular to the address torso axis",
        space: .worldEstimate3D,
        referenceFrameZH: "以准备姿势那一帧的躯干长轴为旋转轴，以该帧肩线为 0° 基准",
        projectionZH: "投影到与准备姿势躯干长轴垂直的平面（横断面）后测量带符号夹角",
        zeroAndSignZH: "准备姿势为 0°；绕躯干长轴按右手定则为正。上杆与下杆方向符号相反",
        range: -180...180,
        unit: "°",
        applicableViews: [.faceOn, .downTheLine, .unknown],
        requiresAddressReference: true,
        caveatZH: "这是相对准备姿势的转角，不是相对目标线的转角——未经标定时球场目标线与地面方向均为未知。投影已剔除肩线倾斜分量，但肩线方向仍不等同于胸廓解剖学旋转。数值来自模型三维估计，未经动作捕捉验证。"
    )

    public static let hipLineRotation = MetricDefinition(
        id: .hipLineRotation,
        nameZH: "髋线转角（相对准备姿势）",
        nameEN: "Hip line rotation relative to address",
        joints: [.leftHip, .rightHip, .leftShoulder, .rightShoulder],
        formula: "signed angle from address (rightHIP - leftHIP) to current (rightHIP - leftHIP), both projected onto the plane perpendicular to the address torso axis",
        space: .worldEstimate3D,
        referenceFrameZH: "以准备姿势那一帧的躯干长轴为旋转轴，以该帧髋线为 0° 基准",
        projectionZH: "投影到与准备姿势躯干长轴垂直的平面（横断面）后测量带符号夹角",
        zeroAndSignZH: "准备姿势为 0°；绕躯干长轴按右手定则为正，与肩线转角同向为正",
        range: -180...180,
        unit: "°",
        applicableViews: [.faceOn, .downTheLine, .unknown],
        requiresAddressReference: true,
        caveatZH: "与肩线转角同样为相对准备姿势的估计值，非相对目标线，未经动作捕捉验证。"
    )

    public static let shoulderHipSeparation = MetricDefinition(
        id: .shoulderHipSeparation,
        nameZH: "肩髋分离角",
        nameEN: "Shoulder-hip separation",
        joints: [.leftShoulder, .rightShoulder, .leftHip, .rightHip],
        formula: "shoulderLineRotation - hipLineRotation, both defined relative to the same address torso axis",
        space: .worldEstimate3D,
        referenceFrameZH: "与肩线转角、髋线转角完全相同的准备姿势躯干长轴",
        projectionZH: "两个转角在同一横断面内相减",
        zeroAndSignZH: "两者转角相等时为 0°；肩比髋转得更多时为正",
        range: -180...180,
        unit: "°",
        applicableViews: [.faceOn, .downTheLine, .unknown],
        requiresAddressReference: true,
        caveatZH: "此定义为「肩线转角 − 髋线转角」，两者均相对准备姿势。引用任何参考范围前，必须确认该范围也是按同一定义得出的；不同教学体系对 X-Factor 的定义并不一致。"
    )
}

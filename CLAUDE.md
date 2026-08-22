# CLAUDE.md

## 项目简介

互动生日蛋糕 AR 体验：iOS ARKit + Vision 手部姿态检测。检测到手掌张开朝上时，在掌心生成一个体素（voxel）生日蛋糕；蛋糕生成后以世界锚点固定，不跟手移动。点击屏幕对蛋糕发射射线，命中处按球形范围炸开体素，被炸开的体素向四周飞散；蛋糕内部藏有 "HAPPY BIRTHDAY" 体素文字，不受爆炸影响，外层体素被炸开后逐渐显露出来。

## 约束（Constraints）— 平台/SDK 层面不明显、但长期成立的限制

- **iOS 上的 ARKit 没有原生手部骨骼追踪 API。** `ARHandTrackingProvider` 只存在于 visionOS。iOS/iPadOS 上做手势识别必须自己用 Vision 框架的 `VNDetectHumanHandPoseRequest` 逐帧处理 `ARFrame.capturedImage`，拿到 21 个 2D 关键点后自行做几何判定（手指伸展度、掌心法线方向）。这个坑容易被"ARKit 应该自带手部追踪"的直觉误导。
- **体素蛋糕数据用 JSON（不是 `.vox`），但拿到的具体文件不能假设是干净的。** 生成体素数据的上游工具会在 `materials` 数组里留下重复的占位 `id`（例如同一个 `id` 先是模板默认色，后面又被真正的配色覆盖一次）——解析时必须显式约定"重复 `id` 取最后一个"，不能假设 `id` 唯一。见 [.ai/decisions/voxel-data-format-json.md](.ai/decisions/voxel-data-format-json.md)。
- **JSON 里不同图层的体素坐标会重叠，同一个坐标必须有人赢。** 实测 6965 条体素记录只对应 6805 个不同坐标：118 个文字体素全部嵌在 `Bottom_Tier` 里，另有 42 个蜡烛体素插进上层。`VoxelGrid.init` 显式规定**受保护体素永远赢**——如果改成按图层顺序决定，整段文字会在图层被重排时静默变成可破坏的蛋糕体素、永远不显示，而且没有任何报错指向原因。改这段代码前先跑 `./Tools/VerifyVoxelLogic/run.sh`。
- **本项目仅面向 LiDAR 机型**（iPhone 12 Pro 及以上 Pro 系列 / iPad Pro），依赖 `sceneDepth`/`smoothedSceneDepth` 做手心的 3D 反投影定位。非 LiDAR 机型未做适配：`ARCakeCoordinator.attach(to:)` 检测不到深度支持时会进入 `.unsupportedDevice` 状态并停在提示界面。
- **这个 target 编译时开了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`**，所以不写标注的类型默认是主线程隔离的。`HandGestureDetector` 因此显式标了 `nonisolated`——它跑在 ARKit 的后台回调队列上。新写在 AR 回调路径上的类型都要注意这一点，Swift 5 语言模式下这类违规只是警告，不会拦住你。

## 验证

`./Tools/VerifyVoxelLogic/run.sh` 用真实蛋糕数据跑体素管线的纯逻辑部分（网格构建、文字保护、射线步进、爆炸挖洞），不需要真机或模拟器，几秒钟出结果。动过 `WillBirthCake/Voxel/` 之后跑一下。

## 相关文档

详见 [.ai/README.md](.ai/README.md)——里面有完整的路由表，说明新的发现该写到哪个文件。

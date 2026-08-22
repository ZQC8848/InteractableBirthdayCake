# CLAUDE.md

## 项目简介

互动生日蛋糕 AR 体验：iOS ARKit + Vision 手部姿态检测。检测到手掌张开朝上时，在掌心生成一个体素（voxel）生日蛋糕；蛋糕生成后以世界锚点固定，不跟手移动。点击屏幕对蛋糕发射射线，命中处按球形范围炸开体素，被炸开的体素向四周飞散；蛋糕内部藏有 "HAPPY BIRTHDAY" 体素文字，不受爆炸影响，外层体素被炸开后逐渐显露出来。

## 约束（Constraints）— 平台/SDK 层面不明显、但长期成立的限制

- **iOS 上的 ARKit 没有原生手部骨骼追踪 API。** `ARHandTrackingProvider` 只存在于 visionOS。iOS/iPadOS 上做手势识别必须自己用 Vision 框架的 `VNDetectHumanHandPoseRequest` 逐帧处理 `ARFrame.capturedImage`，拿到 21 个 2D 关键点后自行做几何判定（手指伸展度、掌心法线方向）。这个坑容易被"ARKit 应该自带手部追踪"的直觉误导。
- **RealityKit 的 GPU instancing（`LowLevelMesh` + `MeshInstancesComponent`）是 WWDC25（iOS 26+）才引入的。** 如果项目需要兼容更早的 iOS 版本，体素合并渲染只能用手写的 chunk `MeshDescriptor` 合并方案，不能依赖原生 instancing。
- **体素蛋糕数据用 JSON（不是 `.vox`），但拿到的具体文件不能假设是干净的。** 生成体素数据的上游工具会在 `materials` 数组里留下重复的占位 `id`（例如同一个 `id` 先是模板默认色，后面又被真正的配色覆盖一次）——解析时必须显式约定"重复 `id` 取最后一个"，不能假设 `id` 唯一。见 [.ai/decisions/voxel-data-format-json.md](.ai/decisions/voxel-data-format-json.md)。
- **本项目仅面向 LiDAR 机型**（iPhone 12 Pro 及以上 Pro 系列 / iPad Pro），依赖 `sceneDepth`/`smoothedSceneDepth` 做手心的 3D 反投影定位。非 LiDAR 机型未做适配，运行时行为未定义。

## 相关文档

详见 [.ai/README.md](.ai/README.md)——里面有完整的路由表，说明新的发现该写到哪个文件。

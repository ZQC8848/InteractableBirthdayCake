---
name: hand-pose-reference-projects
description: iOS Vision 手部姿态检测相关的官方文档和开源参考项目
metadata:
  type: memory
---

做 iOS 端手势识别（`VNDetectHumanHandPoseRequest` + ARKit）时，可以参考以下资料，不用从零摸索 API 用法：

- Apple 官方 WWDC20 session《Detect Body and Hand Pose with Vision》——官方讲解 API 用法的第一手资料。
- 开源项目 `r4ghu/iOS-Vision-HandPose`——纯 Vision 框架的手部姿态估计示例。
- 开源项目 `kentvchr/HandTrackingSandbox`——ARKit + RealityKit 结合手部追踪做交互的 sandbox，思路上和本项目"检测手势后在手心生成内容"最接近。
- Apple 开发者论坛帖子《Vision + RealityKit: Convert a point in ARFrame.capturedImage to 3D World Transform》——讲怎么把 Vision 检测到的 2D 点换算成 RealityKit 世界坐标，是 [architecture.md](../architecture.md) 里"3D 定位"步骤要解决的核心问题。

**Why it matters**：手势 3D 定位这一步是整个项目最大的不确定性来源（见 [handoff.md](../handoff.md)），验证时优先去看这几处，而不是重新搜索一遍。

**How to apply**：实现 [architecture.md](../architecture.md) 里"逐帧手势识别"和"3D 定位"这两个步骤时，先对照这些资料确认 API 调用方式，再动手写。

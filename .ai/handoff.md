# 当前状态

**最后更新：2026-08-22**

> 本文件会过期——这是它的作用。每次工作阶段结束时更新它。想要长期保留的内容应该写到别处，见 [README](README.md) 里的路由表。

## 目前进展

第一版实现全部写完，`xcodebuild` 对 `iphoneos` SDK 零警告通过。**但整个 app 还没有在任何真机上运行过一次。**

- 体素数据已经进工程：`WillBirthCake/Resources/cake_voxels.json`（file-system-synchronized group，自动进 target，不用改 pbxproj）。原始未加工版本留在 `art-source/cake_voxels_original.json`，在 app bundle 之外。
- 八个源文件分四个模块，见 [architecture.md](architecture.md) 的模块表。
- 模板遗留的 `AppDelegate.swift` 已经换成 SwiftUI App 生命周期（`WillBirthCakeApp.swift`）。原来手工创建的 `UIWindow` 没有 scene，`window.windowScene` 恒为 nil，会让 Vision 的方向映射永远静默退回竖屏。
- Info.plist 的相机权限描述原本是占位符 `CAMERA_USAGE_DESCRIPTION`（会原样弹给用户），已改成中文说明。
- 体素逻辑有可跑的验证：`./Tools/VerifyVoxelLogic/run.sh`，21 项检查全过。

## 下一步

**在真机上跑起来，先只看手部标记那一段。** 调试脚手架已经写好了（见下方"临时调试脚手架"），app 一启动默认就开着。

看什么：

1. **21 个小球是不是贴在真实的手指关节上。** 骨骼连线会把它们连成手的形状——如果连出来的手是镜像的（红色拇指跑到小指那侧）或者整体转了 90°，那就是 `HandGestureDetector.nativeNormalizedPoint(from:orientation:)` 的方向映射写错了。这是最可能出问题的一处。
2. **"手腕距相机"读数**是否和实际距离相符。如果小球在画面上的位置对、但整体浮在手的前面或后面，那是深度采样的问题，不是方向映射的问题——这两者从蛋糕最终位置上完全分不出来。
3. **状态行说的拒绝原因。** 把手摆成张开朝上却没触发时，它会直接告诉你卡在哪一步（手指没伸直 / 倾角超阈值多少度 / 取不到深度 / 置信度不够），而不用靠猜。倾角那条会连实测角度一起给出，可以直接拿来定 `maxTiltFromUpDegrees` 该放宽到多少。

这么做的理由：[architecture.md](architecture.md) 里列的头两条未验证项（Vision 方向映射、掌心法线符号）**都属于"算错了也会得到看起来合理的结果"**的那类 bug。直接看蛋糕生成得对不对的话，蛋糕出现在错误位置时你分不清是方向映射、法线符号、深度采样还是阈值的问题。

## 临时调试脚手架（验证完就删）

手部关节标记 + 状态读数，仅用于上面这轮验证。

**删除方法**：
1. 删掉 `WillBirthCake/Debug/HandJointDebugOverlay.swift` 整个文件
2. 删掉 `ARCakeCoordinator.swift` 里所有标了 `// DEBUG:` 的行，以及 `debugOverlay` / `debugArmed` / `showHandJoints` / `handStatus` / `handWristDepth` / `setHandJointsVisible(_:)` 这些成员
3. 删掉 `ContentView.swift` 里的 `handDebugPanel`
4. `HandGestureDetector.swift` 里：`process` 的 `includeAllJoints` 参数、`HandFrameResult` 的 `joints` 和 `wristDepth` 字段、以及整个 `HandPoseStatus` 枚举

注意 `gestureArmed` 和 `debugArmed` 是**故意拆成两个**的：蛋糕放置后手势要停止触发，但标记要继续跟踪，这样才能对着已经放好的蛋糕继续检查手部识别。删除脚手架时把 `debugArmed` 一并去掉，`session(_:didUpdate:)` 就退回只由 `gestureArmed` 控制。

## 进行中 / 待定

- 手势阈值目前**刻意放得很宽**（倾角容差 80°、伸展比 1.05、置信度 0.3、保持 0.3s），目的是先确认它能触发。80° 意味着接近竖直的手掌也算「朝上」，确认识别正常之后应该先收紧这一条。
- 爆炸半径 6.4，实测一次清掉 727 个体素（占可破坏体素的 10% 以上），从中随机抛出最多 200 个碎片。**200 个刚体同时模拟是目前最大的性能风险**，掉帧就先调小 `ExplosionController.Tuning.maxDebrisPerBlast`——它不影响洞的大小。
- `SceneLighting` 的主光/补光强度（12000 / 3000 lux）是初值，AR 画面合成在明亮的相机图像上，需要实机看曝光。
- 碎片会穿过剩余的蛋糕本体（蛋糕没有碰撞体，这是 [射线步进命中检测](decisions/hit-testing-by-ray-marching.md) 明确接受的代价）。碎片之间会互相碰撞。
- 碎片 4 秒后**直接消失**，没有淡出。做淡出要逐个改材质，成本不低，先看实机观感值不值得。
- 场景里没有地面，碎片会一直往下掉到超时为止。要不要在掌心高度放一个不可见地面，等真机看了观感再定。
- `HappyBirthdayText` 是程序生成的占位字体（简易 3×5 点阵），不是美术精修。要提升观感就整体替换这个 model，不影响其他图层。

## 容易踩坑的地方

- **这个 target 开了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`**，不写标注的类型默认主线程隔离。`HandGestureDetector` 显式标了 `nonisolated` 才能在 ARKit 后台队列上跑。Swift 5 语言模式下违规只是警告，很容易一路编译通过然后在真机上出诡异问题。
- **命中检测和渲染是两套独立的几何表示**（体素网格 vs 合并 mesh）。`VoxelGrid.localCentre(of:)` 和 `CakeEntity.originOffset` 必须用同一个偏移公式，改一个不改另一个，点击位置就会和看到的蛋糕错开——而且不会报错。
- 改过 `WillBirthCake/Voxel/` 下的任何东西之后跑一下 `./Tools/VerifyVoxelLogic/run.sh`。
- **测试机 iPhone 16 Plus 没有 LiDAR**，走的是人体分割估算深度那条路（界面上"深度来源"那行会显示当前用的是哪个）。这条路噪声比 LiDAR 大，而且分割网络主要是为整个人训练的，**只有一只手入镜时质量如何还没验证过**——如果标记抖得厉害或者深度不稳，先怀疑这里，再怀疑方向映射。
- 开了 `personSegmentationWithDepth` 之后 RealityKit 会同时启用人体遮挡，手指会挡住蛋糕。物理上是对的，但估算深度有噪声时可能闪烁，未验证。

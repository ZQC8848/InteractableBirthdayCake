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

手部关节标记 + 状态读数。**默认收起**：左上角一个小按钮，点开才展开面板，再点收起；关节标记默认关闭，要在面板里单独打开。面板关着的时候检测器不会为它多跑任何东西。

**删除方法**：
1. 删掉 `WillBirthCake/Debug/HandJointDebugOverlay.swift` 整个文件
2. 删掉 `ARCakeCoordinator.swift` 里所有标了 `// DEBUG:` 的行，以及 `DebugFlags` / `debugOverlay` / `showHandJoints` / `handStatus` / `handWristDepth` / `depthSourceName` / `setHandJointsVisible(_:)` / `setDebugPanelOpen(_:)` 这些成员
3. 删掉 `ContentView.swift` 里的 `debugCorner` 和 `handDebugPanel`
4. `HandGestureDetector.swift` 里：`process` 的 `includeAllJoints` 参数、`HandFrameResult` 的 `joints` 和 `wristDepth` 字段、以及整个 `HandPoseStatus` 枚举

注意 `gestureArmed` 和 `DebugFlags` 是**故意分开**的：蛋糕放置后手势要停止触发，但标记要继续跟踪，这样才能对着已经放好的蛋糕继续检查手部识别。`DebugFlags` 内部又分 `panelOpen` 和 `markers` 两个标志，因为开销不同——读数只要检测器在跑，标记还要额外反投影全部 21 个关键点（掌心只需 5 个）。删除脚手架时整个去掉，`session(_:didUpdate:)` 就退回只由 `gestureArmed` 控制。

## 进行中 / 待定

- 姿势判定只保留**五指伸展**，掌心朝向不判（`maxTiltFromUpDegrees` 及相关的法线/`chirality` 计算已删除）。张开手才触发，握拳或随手入镜不会。
- 爆炸半径 6.4，实测一次清掉 727 个体素（占可破坏体素的 10% 以上），从中随机抛出碎片。**真机实测 200 个刚体会掉帧，已降到 160。** 还掉就继续调小 `ExplosionController.Tuning.maxDebrisPerBlast`——它不影响洞的大小。
- 光照 = **面向明暗烘焙（底子）+ 一盏聚光灯（高光）**，聚光灯不投影。强度 5500 流明是真机实测定下来的，调试滑杆已删。**要改就靠眼睛改，不要靠算**——RealityKit 的流明标度和物理估算差两个数量级。
- 文字带自发光 + 内部一盏 `PointLight`（300 流明 / 衰减半径 0.2m），这两个数**未经真机验证**，是从聚光灯那 5500 按距离和光锥立体角折算出来的估算值。看着不对就直接调，别重新推导。
- 人体遮挡已用 `renderOptions.disablePersonOcclusion` 关掉：`personSegmentationWithDepth` 这个 frame semantic 是手部深度的唯一来源，但 ARView 会顺带把人合成到虚拟内容之前，手会挡住蛋糕。深度要留，遮挡不要。
- 界面文案已全部改为英文。
- 碎片会穿过剩余的蛋糕本体（蛋糕没有碰撞体，这是 [射线步进命中检测](decisions/hit-testing-by-ray-marching.md) 明确接受的代价）。碎片之间会互相碰撞。
- 碎片 4 秒后**直接消失**，没有淡出。做淡出要逐个改材质，成本不低，先看实机观感值不值得。
- 场景里没有地面，碎片会一直往下掉到超时为止。要不要在掌心高度放一个不可见地面，等真机看了观感再定。
- 文字内容改成了 `HAPPY / BIRTHDAY / WILL`，改由 Swift 在 `Cake/VoxelTextLayout.swift` 里生成（不再烘在 JSON 里），字体仍是简易 3×5 点阵。改文案就改那里的 `lines`，然后**跑 `./Tools/VerifyVoxelLogic/run.sh`**——它会验证每个字符格是否仍被实心蛋糕包住。
- 文字用 0.6 倍的独立细网格，原因是 `BIRTHDAY` 在原网格上放不下（31 列 vs 可用 23 列），实测见 [architecture.md](architecture.md)。
- 蛋糕放置时会绕 Y 轴转，让文字平面正对使用者。这会让面向明暗烘焙的 X/Z 两档跟着转——顶/底面不受影响，视觉上仍然成立，但值得知道。

- 文字暴露到 80% 时底部提示切成 "Happy Birthday Will!"。实测需要约 9 次点击，而且必须**换位置打**——同一个点反复戳会停在 62.5%。觉得太久就调低 `ARCakeCoordinator.celebrationThreshold`。

## 容易踩坑的地方

- **这个 target 开了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`**，不写标注的类型默认主线程隔离。`HandGestureDetector` 显式标了 `nonisolated` 才能在 ARKit 后台队列上跑。Swift 5 语言模式下违规只是警告，很容易一路编译通过然后在真机上出诡异问题。
- **命中检测和渲染是两套独立的几何表示**（体素网格 vs 合并 mesh）。`VoxelGrid.localCentre(of:)` 和 `CakeEntity.originOffset` 必须用同一个偏移公式，改一个不改另一个，点击位置就会和看到的蛋糕错开——而且不会报错。
- 改过 `WillBirthCake/Voxel/` 或 `Cake/VoxelTextLayout.swift` 之后跑一下 `./Tools/VerifyVoxelLogic/run.sh`。
- **「暴露」的判定不是「体素没了」**，是「沿 ±Z 能直通到模型外」。改这个逻辑前先想清楚：文字格子被挖空但前面还挡着蛋糕的情况很常见，用前者会在文字还埋着的时候就宣布通关。
- **测试机 iPhone 16 Plus 没有 LiDAR**，走的是人体分割估算深度那条路（界面上"深度来源"那行会显示当前用的是哪个）。这条路噪声比 LiDAR 大，而且分割网络主要是为整个人训练的，**只有一只手入镜时质量如何还没验证过**——如果标记抖得厉害或者深度不稳，先怀疑这里，再怀疑方向映射。
- 开了 `personSegmentationWithDepth` 之后 RealityKit 会同时启用人体遮挡，手指会挡住蛋糕。物理上是对的，但估算深度有噪声时可能闪烁，未验证。

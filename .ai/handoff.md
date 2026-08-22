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

**在真机上跑起来，先只验证手势那一段。** 具体做法：在 `ARCakeCoordinator` 的 `placeCake(at:)` 之外，先加一个临时的调试可视化——把 `HandGestureDetector` 反投影出的三个关键点（手腕、食指根、小指根）各放一个小球在世界坐标里，看它们是不是真的贴在手上。

这么做的理由：[architecture.md](architecture.md) 里列的头两条未验证项（Vision 方向映射、掌心法线符号）**都属于"算错了也会得到看起来合理的结果"**的那类 bug。如果直接看蛋糕生成得对不对，蛋糕出现在错误位置时你分不清是方向映射错了、法线符号错了、深度采样错了，还是阈值不合适。先把中间量画出来，一眼就能定位。

## 进行中 / 待定

- 手势相关的四个阈值（`maxTiltFromUpDegrees` / `extensionRatio` / `requiredHoldDuration` / `frameStride`）全是拍脑袋的初值，等真机调。
- 单次爆炸的刚体数量上限 160 还没有实测依据，半径 3.2 实测挖出 103 个。
- 碎片会穿过剩余的蛋糕本体（蛋糕没有碰撞体，这是 [射线步进命中检测](decisions/hit-testing-by-ray-marching.md) 明确接受的代价）。碎片之间会互相碰撞。
- 碎片 4 秒后**直接消失**，没有淡出。做淡出要逐个改材质，成本不低，先看实机观感值不值得。
- 场景里没有地面，碎片会一直往下掉到超时为止。要不要在掌心高度放一个不可见地面，等真机看了观感再定。
- `HappyBirthdayText` 是程序生成的占位字体（简易 3×5 点阵），不是美术精修。要提升观感就整体替换这个 model，不影响其他图层。

## 容易踩坑的地方

- **这个 target 开了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`**，不写标注的类型默认主线程隔离。`HandGestureDetector` 显式标了 `nonisolated` 才能在 ARKit 后台队列上跑。Swift 5 语言模式下违规只是警告，很容易一路编译通过然后在真机上出诡异问题。
- **命中检测和渲染是两套独立的几何表示**（体素网格 vs 合并 mesh）。`VoxelGrid.localCentre(of:)` 和 `CakeEntity.originOffset` 必须用同一个偏移公式，改一个不改另一个，点击位置就会和看到的蛋糕错开——而且不会报错。
- 改过 `WillBirthCake/Voxel/` 下的任何东西之后跑一下 `./Tools/VerifyVoxelLogic/run.sh`。
- 真机需要 LiDAR。没有深度支持的设备会停在 `.unsupportedDevice` 提示页，不会崩，但也什么都不会发生——不要误以为是别的地方坏了。

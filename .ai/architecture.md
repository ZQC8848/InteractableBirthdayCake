# 系统架构

**最后核对日期：2026-08-22（第一版实现完成，尚未在真机上跑过）**

> 下面描述的是**已经写出来的代码**。但是：整条链路还没有在任何真机上运行过。体素部分（网格构建、文字保护、射线步进、爆炸挖洞）已经用 `./Tools/VerifyVoxelLogic/run.sh` 对真实数据验证过；**AR 和手势部分完全没有验证**，见文末"尚未验证的部分"。

## 一个体素从生成到爆炸的完整流程

1. **AR 会话启动** — `ARCakeCoordinator.attach(to:)` 配置 `ARWorldTrackingConfiguration`，优先 `.smoothedSceneDepth`，退回 `.sceneDepth`，两者都不支持就进入 `.unsupportedDevice` 停住。同时**提前**把整个蛋糕 mesh 建好（约 7000 体素，等手势识别到再建会有可见卡顿）。
2. **逐帧手势识别** — ARKit 在后台串行队列 `visionQueue` 上回调 `session(_:didUpdate:)`，`HandGestureDetector` 每 6 帧跑一次 `VNDetectHumanHandPoseRequest`（60fps 下约 10Hz），判定五指伸展 + 掌心朝上。
3. **3D 定位** — 把 Vision 的 2D 关键点（手腕、食指根、小指根）通过 LiDAR 深度图 + 相机内参反投影成世界坐标。深度取 3×3 窗口的中位数——手在 256×192 的深度图里是个又小又噪的目标，单点采样一旦落在轮廓外就会把蛋糕放到几米之外。掌心法线由两个跨掌向量叉乘得到，符号按 `chirality` 翻转。姿势要连续保持 0.6 秒才触发。
4. **生成蛋糕** — `AnchorEntity(world:)` 锚在掌心位置，蛋糕挂上去，然后**关闭手势检测**。锚点和手部数据自此完全解耦，手移开蛋糕不动。
5. **点击交互** — 点击 → `ARView.ray(through:)` → 变换到蛋糕本地空间 → `VoxelGrid.firstSolidVoxel` 做 DDA 射线步进找到第一个实心体素。不走 RealityKit 碰撞体，原因见 [decisions/hit-testing-by-ray-marching.md](decisions/hit-testing-by-ray-marching.md)。
6. **爆炸** — 以命中体素为球心，半径 3.2 体素范围内的**可破坏**体素被移除（上限 160 个），只重建被弄脏的 chunk → 每个被移除的体素生成一个独立 `ModelEntity`，挂 `PhysicsBodyComponent`，获得径向冲量 + 随机扰动 + 向上偏置，交给 RealityKit 物理引擎，4 秒后回收。

## 模块划分

| 文件 | 负责 | 关键点 |
|---|---|---|
| `Voxel/VoxelSceneData.swift` | JSON 解码 | `materialsByID` 实现"重复 id 取最后一个" |
| `Voxel/VoxelGrid.swift` | 运行时体素状态 | chunk 分组、球形挖除、DDA 射线步进；**受保护体素赢得坐标冲突** |
| `Voxel/VoxelMeshBuilder.swift` | 网格生成 | 隐面剔除；按材质拆分 mesh part |
| `Cake/CakeEntity.swift` | 实体组装 | 蛋糕分 chunk 可重建；文字只建一次 |
| `Cake/ExplosionController.swift` | 碎片物理 | 冲量、数量上限、生命周期 |
| `Hand/HandGestureDetector.swift` | 手势 + 3D 定位 | `nonisolated`，跑在后台队列 |
| `AR/ARCakeCoordinator.swift` | 会话与状态编排 | 主线程隔离；跨线程状态用 `OSAllocatedUnfairLock` |
| `AR/ARViewContainer.swift` | SwiftUI 桥接 | 用 `ARView` 而非 `RealityView`，因为需要自定义 session 配置、session delegate、`ray(through:)` |

## 为什么隐面剔除是必需的而不是优化

蛋糕是**实心**的。6805 个体素如果六个面全画，是 40830 个面（81660 三角形），其中绝大多数埋在模型内部永远看不见。只在邻居为空时才生成面，实测降到 **2886 个面（5772 三角形），减少 93%**。

这也正是爆炸必须**重建 chunk** 而不是简单删几何的原因：挖掉一块会**暴露出**原本从未生成过的内部面。同理，弄脏的 chunk 集合必须包含被移除体素的**邻居**所在的 chunk——在 chunk 边界上挖洞会暴露相邻 chunk 的面，漏掉就会看到穿透的空洞。

蛋糕和文字用两套不同的遮挡判据：
- 蛋糕面：邻居是**任何**体素就剔除（文字永不消失，是合法遮挡物）
- 文字面：只有邻居也是**文字**才剔除 —— 所以文字从一开始就带着完整外表面，埋在蛋糕里，随着周围被炸开自然显露

## 尚未验证的部分

**这些是真机测试的第一批目标，不要当成已知正确的东西继续往上盖：**

- **Vision 坐标 → 原生缓冲区的方向映射**（`HandGestureDetector.nativeNormalizedPoint(from:orientation:)`）。这段是按 `.right` 方向下"原生横向缓冲区顺时针转 90°"推导出来的，纸面上成立，但映射写错了照样会算出看起来合理的 3D 点，只是位置不对。**这是最可能出问题的一处。**
- **掌心法线的符号**是否对左右手都指向掌心外侧（`chirality` 翻转那一行）。
- **手势判定的阈值**：`maxTiltFromUpDegrees = 40`、`extensionRatio = 1.15`、`requiredHoldDuration = 0.6s`、`frameStride = 6` 全部是拍脑袋的初值，需要实测调。
- **单次爆炸 160 个刚体**会不会掉帧。半径 3.2 实测挖出 103 个体素，上限 160 主要在多次点击重叠时才会触发。
- **蛋糕物理尺寸** 16.3 × 14.3 × 16.3 cm（`voxelSize = 0.0065`）在掌心里看着合不合适。

## 相关决策

见 [decisions/](decisions/)：[仅 LiDAR 机型](decisions/device-scope-lidar-only.md)、[JSON 数据格式](decisions/voxel-data-format-json.md)、[真实物理爆炸](decisions/explosion-physics-real.md)、[RealityKit 渲染](decisions/render-engine-realitykit.md)、[射线步进命中检测](decisions/hit-testing-by-ray-marching.md)。

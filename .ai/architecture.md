# 系统架构（当前为设计阶段，代码尚未开始编写）

**最后核对日期：2026-08-22**

> 本文档描述的是已经拍板的设计方案，**不是已实现的行为**。截至写就这份文档时，仓库里只有 Xcode 默认模板（`AppDelegate.swift`、`ContentView.swift`），没有一行 AR/体素相关代码。等关键模块（尤其是手势识别）跑起来之后，回来核对这里的描述是否还准确——不要想当然地认为"设计写了"就等于"代码是这么做的"。

## 一个体素从生成到爆炸的完整流程

1. **AR 会话启动** — `ARWorldTrackingConfiguration` 开启 `sceneDepth`（依赖 LiDAR，见 [decisions/device-scope-lidar-only.md](decisions/device-scope-lidar-only.md)）。
2. **逐帧手势识别** — `ARSessionDelegate` 拿到 `ARFrame.capturedImage` → `VNDetectHumanHandPoseRequest` 输出 21 个 2D 关键点 → 判定"五指伸展 + 掌心法线朝上"。判定用的具体阈值还没有值，见下方"尚未验证的部分"。
3. **3D 定位** — 判定为真后，用 LiDAR 深度图把掌心的 2D 点反投影成 3D 世界坐标；加一个短暂的 hold 计时防抖，避免手势晃动导致误触发。
4. **生成蛋糕** — 用这个 3D 位置创建 `AnchorEntity(world:)`，加载解析好的体素数据（见 [decisions/voxel-data-format-json.md](decisions/voxel-data-format-json.md)），渲染成按 chunk 合并的静态 mesh，外加一份不可破坏的文字体素 mesh。生成后与手部追踪数据完全解耦，不再跟手移动。
5. **点击交互** — 屏幕点击 → 从相机位置发射射线 → 命中蛋糕碰撞体 → 命中点换算为体素网格坐标。
6. **爆炸** — 以命中点为球心做半径范围查询，取出球内的体素 → 从对应 chunk 的静态 mesh 里移除这些体素（只重建受影响的 chunk，不做整体重建）→ 每个被移除的体素生成一个独立实体，挂 `PhysicsBodyComponent`，沿"爆炸中心 → 体素位置"方向获得径向初始冲量，交给 RealityKit 物理引擎模拟（见 [decisions/explosion-physics-real.md](decisions/explosion-physics-real.md)）；标记为"文字体素"的部分永远跳过这一步，随着外层体素消失而显露出来。

## 模块划分（对应上面的步骤）

| 模块 | 负责的步骤 | 关键依赖 |
|---|---|---|
| `HandGestureTracker` | 2、3 | Vision、ARKit `sceneDepth` |
| `VoxelDataLoader` | 4（数据准备） | JSON `Codable` 解析；按图层名区分可破坏/不可破坏体素 |
| `VoxelCakeEntity` | 4（渲染） | RealityKit `MeshDescriptor`，按 chunk 合并 |
| `ExplosionController` | 5、6 | RealityKit hit-test + `PhysicsBodyComponent` |

## 尚未验证的部分

- 手势判定的具体阈值（手指伸展度、掌心法线与世界 up 向量的夹角）——需要在真机上实测调参，目前只是设计意图，没有任何数值。
- 单次爆炸同时产生多少个动态刚体会开始掉帧——需要真机实测，目前的"几百个"只是猜测的量级，不是测量结果。
- "HAPPY BIRTHDAY" 文字体素怎么标记为不可破坏——现在数据里有了（`HappyBirthdayText` model，按图层名识别即可），但还没有代码去消费它，"按图层名区分可破坏/不可破坏"这条解析逻辑本身仍未实现，见 [decisions/voxel-data-format-json.md](decisions/voxel-data-format-json.md)。

## 相关决策

见 [decisions/](decisions/) 目录，已确定的技术决策都在这里，包括每个决策否决了哪些备选方案（体素数据格式已经从 `.vox` 改成 JSON，见 [voxel-data-format-json.md](decisions/voxel-data-format-json.md)）。

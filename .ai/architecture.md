# 系统架构

**最后核对日期：2026-08-22（第一版实现完成，尚未在真机上跑过）**

> 下面描述的是**已经写出来的代码**。但是：整条链路还没有在任何真机上运行过。体素部分（网格构建、文字保护、射线步进、爆炸挖洞）已经用 `./Tools/VerifyVoxelLogic/run.sh` 对真实数据验证过；**AR 和手势部分完全没有验证**，见文末"尚未验证的部分"。

## 一个体素从生成到爆炸的完整流程

1. **AR 会话启动** — `ARCakeCoordinator.attach(to:)` 配置 `ARWorldTrackingConfiguration`，深度来源按 `.smoothedSceneDepth` → `.sceneDepth` → `.personSegmentationWithDepth` 降级，全都不支持才进入 `.unsupportedDevice`。同时**提前**把整个蛋糕 mesh 建好（约 7000 体素，等手势识别到再建会有可见卡顿）。场景里**没有任何显式光源**，见下节。
2. **逐帧手部识别** — ARKit 在后台串行队列 `visionQueue` 上回调 `session(_:didUpdate:)`，`HandGestureDetector` 每 3 帧跑一次 `VNDetectHumanHandPoseRequest`（60fps 下约 20Hz）。**没有姿势判定**：不看掌心朝向，也不看手指是否伸直，能定位到掌心就算数。
3. **3D 定位** — 掌心取手腕 + 四个指根（`indexMCP`/`middleMCP`/`ringMCP`/`littleMCP`）中**凡是能反投影成功的那些**的平均值，至少两个才采信——不强求固定三个点，个别点被遮挡或深度有洞不该导致整次识别失败。反投影用深度图 + 相机内参；深度取窗口中位数（LiDAR 3×3，估算深度 5×5），因为手在 256×192 的深度图里是个又小又噪的目标，单点采样一旦落在轮廓外就会把蛋糕放到几米之外；估算深度还要用人体分割蒙版过滤，蒙版外的值没有意义。掌心要连续可见 0.3 秒才触发——**这一条不是姿势判定，是稳定性保险**：蛋糕是世界锚定的，一帧噪声就会把它永久钉在错误位置，只能按 Place Again 重来。
4. **生成蛋糕** — `AnchorEntity(world:)` 锚在掌心位置，蛋糕挂上去并播放出场动画（缩放 0 → 1.1 → 1，0.55s），然后**关闭手势检测**。锚点和手部数据自此完全解耦，手移开蛋糕不动。
5. **点击交互** — 点击 → `ARView.ray(through:)` → 变换到蛋糕本地空间 → `VoxelGrid.firstSolidVoxel` 做 DDA 射线步进找到第一个实心体素。不走 RealityKit 碰撞体，原因见 [decisions/hit-testing-by-ray-marching.md](decisions/hit-testing-by-ray-marching.md)。
6. **爆炸** — 以命中体素为球心，半径 6.4 体素范围内的**可破坏**体素全部被移除（实测 727 个，挖洞不设上限），只重建被弄脏的 chunk（实测 12 个）→ 从中**随机抽最多 200 个**生成独立 `ModelEntity`，挂 `PhysicsBodyComponent`，获得径向冲量 + 随机扰动 + 向上偏置，交给 RealityKit 物理引擎，4 秒后回收；其余体素跟着几何直接消失。

## 模块划分

| 文件 | 负责 | 关键点 |
|---|---|---|
| `Voxel/VoxelSceneData.swift` | JSON 解码 | `materialsByID` 实现"重复 id 取最后一个" |
| `Voxel/VoxelGrid.swift` | 运行时体素状态 | chunk 分组、球形挖除、DDA 射线步进；**受保护体素赢得坐标冲突** |
| `Voxel/VoxelMeshBuilder.swift` | 网格生成 | 隐面剔除；按材质拆分 mesh part |
| `Cake/CakeEntity.swift` | 实体组装 | 蛋糕分 chunk 可重建；文字只建一次 |
| `Cake/VoxelTextLayout.swift` | 隐藏文字的字形与摆位 | 独立细网格，纯 Foundation 以便被验证脚本覆盖 |
| `Cake/CakeSpawnAnimation.swift` | 出场动画 | `easeOutBack`，单条曲线完成过冲回弹 |
| `Cake/ExplosionController.swift` | 碎片物理 | 冲量、**碎片**数量上限（与洞的大小解耦）、生命周期 |
| `Hand/HandDepthSource.swift` | 深度来源抽象 | LiDAR 优先，退回人体分割估算深度 |
| `Hand/HandGestureDetector.swift` | 手势 + 3D 定位 | `nonisolated`，跑在后台队列 |
| `Voxel/VoxelMeshBuilder.swift` 的 `FaceShadingTier` | 面向明暗烘焙 | 保证面的区分度不依赖光照，见下节 |
| `AR/CakeSpotLight.swift` | 聚光灯 | 挂在蛋糕锚点下；**强度靠真机滑杆调**，不是推算出来的 |
| `AR/ARCakeCoordinator.swift` | 会话与状态编排 | 主线程隔离；跨线程状态用 `OSAllocatedUnfairLock` |
| `AR/ARViewContainer.swift` | SwiftUI 桥接 | 用 `ARView` 而非 `RealityView`，因为需要自定义 session 配置、session delegate、`ray(through:)` |

## 光照：烘焙打底 + 一盏聚光灯

体素面之间的明暗**烘在材质里**：每个源材质展开成四个变体，按面朝向选用——顶面 1.0、X 侧面 0.80、Z 侧面 0.66、底面 0.50（X 和 Z 分开是为了让转角处两面墙仍能分辨）。

一开始的做法是加主光 + 补光，因为相机推出来的环境光柔和且近乎均匀，立方体六个面受光几乎一样，模型看着像剪影。但那是**用光照手段修一个材质层面的问题**，代价有两个：定向光的贡献叠加在环境光之上导致过曝，而 iOS 上 `DirectionalLightComponent.Shadow` 没有暴露软化参数，硬阴影调不动。

烘焙让明暗关系变成**相对**的：房间多亮多暗，面与面的层次都在，也不会过曝。这一层是底子，不依赖任何光源。

在此之上加了一盏 `SpotLight`（`AR/CakeSpotLight.swift`），挂在蛋糕锚点下，从斜上方照向蛋糕中心，给高光和光源感。不投影——聚光灯的阴影和被移除的定向光一样硬，接触阴影仍然交给 ARView 自带的 grounding shadow。

**它的强度不要靠推算。** RealityKit 的聚光灯强度单位是流明，但标度和物理直觉对不上：Apple 官方建议是「10000 流明配 6 米衰减半径」，而按光度学估算一盏 45cm 外照 16cm 蛋糕的灯只需约 120 流明——差两个数量级。上一版光照过曝就是因为数值是推出来的而不是看出来的。所以初值 1500 流明只是起点，调试面板上有实时滑杆（0–10000），在真机上调好之后再把 `CakeSpotLight.Tuning.defaultIntensity` 改成实测值。

代价：明暗固定绑在世界轴上，模型旋转时不会跟着变。蛋糕是世界锚定且不旋转的，所以不受影响——**如果以后要让蛋糕转起来，这一条会穿帮**。

## 为什么隐面剔除是必需的而不是优化

蛋糕是**实心**的。6805 个体素如果六个面全画，是 40830 个面（81660 三角形），其中绝大多数埋在模型内部永远看不见。只在邻居为空时才生成面，实测降到 **2886 个面（5772 三角形），减少 93%**。

这也正是爆炸必须**重建 chunk** 而不是简单删几何的原因：挖掉一块会**暴露出**原本从未生成过的内部面。同理，弄脏的 chunk 集合必须包含被移除体素的**邻居**所在的 chunk——在 chunk 边界上挖洞会暴露相邻 chunk 的面，漏掉就会看到穿透的空洞。

文字面只有邻居也是**文字**才剔除，所以它从一开始就带着完整外表面，埋在蛋糕里，随着周围被炸开自然显露。

## 隐藏文字为什么不在体素网格上

内容是 `HAPPY / BIRTHDAY / WILL`。`BIRTHDAY` 八个字母，3 格宽字形 + 1 格间距 = **31 列**，而蛋糕内部被完全包住的区域最宽只有 **23 列**。对真实模型实测：网格对齐的竖直排布有 152 个字符体素中的 50 个露在外面，平躺排布露 22 个——这个词就是比蛋糕宽，换什么朝向都一样。把字形压到 2 格宽能让 `BIRTHDAY` 正好 23 列，但 23 列宽的行只存在于 y=7、8 两层，而一行字需要 5 层。

所以文字自带一套更细的网格，`VoxelTextLayout.scale = 0.6` 个蛋糕体素对应一个字符格。丢掉网格对齐反而**简化了实现**：文字不再是被标记为 indestructible 的体素，而是一个爆炸根本触及不到的独立网格——保护从「标记」变成了「结构性的」。缩放系数 0.65 是临界值，取 0.6 留余量。

摆位上有个巧合帮了忙：`BIRTHDAY` 这条最宽的行正好落在 y 5–8，也就是蛋糕最宽的高度（需要 19 列，可用 23 列），而短的 `HAPPY` 落在上层较窄处只需 12 列。`Tools/VerifyVoxelLogic` 会验证每一个字符格都被实心蛋糕完全包住——改文案或改缩放后跑一下，它会直接告诉你还塞不塞得下。

文字是一个平面，所以蛋糕放置时会绕 Y 轴旋转，让这个平面正对使用者；否则锚点保持世界轴朝向，文字可能侧对甚至背对着人。

### 文字的发光

**RealityKit 没有内置 bloom，`emissiveColor` 本身也不产生光晕**——它只让表面渲染得亮、不受光照影响。真 bloom 只能走 `ARView.renderCallbacks.postProcess` 写 Metal 后处理，那有两个坑：后处理拿到的纹理里**包含 AR 相机画面**，直接做亮度提取会把真实世界里的窗户和灯一起 bloom，必须用 `sourceDepthTexture` 做遮罩；而且它是**恒定**每帧开销，会和爆炸瞬间 160 个刚体的负载撞在同一帧上——恰恰是最想看到辉光的那一帧。

目前的做法不做后处理，而是两层：
1. 文字材质带自发光（暖白色，`emissiveIntensity = 2.5`），保证它在聚光灯照不到的洞里也够亮。面向明暗的四档对自发光通道压缩到 1/4 强度——自发光表面本来就更平，但压平到没有会丢掉方块的棱角。
2. 文字中心放一盏 `PointLight`。这一层才是「发光」的观感来源，而且它成立是因为构图特殊：**文字是从炸开的空腔里看进去的，四周是朝内的蛋糕内壁**，中心的灯正好照亮它们。蛋糕的**外壳法线朝外、背对这盏灯，不会被照亮**，所以不需要阴影也不会漏光出去。

## 尚未验证的部分

**这些是真机测试的第一批目标，不要当成已知正确的东西继续往上盖：**

- **Vision 坐标 → 原生缓冲区的方向映射**（`HandGestureDetector.nativeNormalizedPoint(from:orientation:)`）。这段是按 `.right` 方向下"原生横向缓冲区顺时针转 90°"推导出来的，纸面上成立，但映射写错了照样会算出看起来合理的 3D 点，只是位置不对。**这是最可能出问题的一处。**
- **掌心法线的符号**是否对左右手都指向掌心外侧（`chirality` 翻转那一行）。
- 姿势判定已全部移除，只剩 `minJointConfidence = 0.3`、`minPalmLandmarks = 2`、`requiredHoldDuration = 0.3s`。代价是**只要有手入镜就会生成蛋糕**，没有任何姿势可以用来表达"我还不想放"——0.3 秒的保持是唯一的门槛。
- **人体分割估算深度在只有一只手入镜时的质量**——分割网络主要是为整个人训练的。
- 碎片上限从 200 降到 **160**（真机实测 200 会掉帧）。160 是否够稳还需继续观察。
- **聚光灯强度**：初值 1500 流明未经验证，用调试面板的滑杆在真机上调定，然后把结果写回 `CakeSpotLight.Tuning.defaultIntensity`。
- **面向明暗的四档系数**（1.0 / 0.80 / 0.66 / 0.50）是初值，实机看层次够不够。
- **蛋糕物理尺寸** 16.3 × 14.3 × 16.3 cm（`voxelSize = 0.0065`）在掌心里看着合不合适。

## 相关决策

见 [decisions/](decisions/)：[仅 LiDAR 机型](decisions/device-scope-lidar-only.md)、[JSON 数据格式](decisions/voxel-data-format-json.md)、[真实物理爆炸](decisions/explosion-physics-real.md)、[RealityKit 渲染](decisions/render-engine-realitykit.md)、[射线步进命中检测](decisions/hit-testing-by-ray-marching.md)。其中设备范围那条已经从「仅 LiDAR」改为降级链，原文档内标了 superseded。

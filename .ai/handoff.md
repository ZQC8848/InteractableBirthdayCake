# 当前状态

**最后更新：2026-08-22**

> 本文件会过期——这是它的作用。每次工作阶段结束时更新它。想要长期保留的内容应该写到别处，见 [README](README.md) 里的路由表。

## 目前进展

- 项目仍处于设计/可行性讨论阶段，仓库里只有 Xcode 默认模板（`AppDelegate.swift`、`ContentView.swift`），没有任何 AR/体素相关代码。
- 已经确定了四个关键技术决策，都在 [decisions/](decisions/) 里：
  - [仅支持 LiDAR 机型](decisions/device-scope-lidar-only.md)
  - [体素数据用 JSON 文件](decisions/voxel-data-format-json.md)（2026-08-22 从 `.vox` 改过来，原决策见 [voxel-data-format-vox.md](decisions/voxel-data-format-vox.md)，已标记 superseded）
  - [爆炸用真实物理模拟](decisions/explosion-physics-real.md)
  - [渲染引擎用 RealityKit](decisions/render-engine-realitykit.md)
- 用户提供了第一版蛋糕体素数据 `A_solid_Minecraft-style_voxel_birthday_c.json`（项目根目录，**在 `WillBirthCake` git 仓库之外**，还没挪进 Xcode 工程）。检查后发现两个问题（materials 重复 id、缺文字层），已经处理：materials 重复问题定为解析约定（重复 id 取最后一个），文字层用脚本生成了占位版 `HappyBirthdayText` model（118 个体素，3 行 3×5 像素字："HAPPY"/"BIRTH"/"DAY"，材质新增 `id 14 text_gold`，已验证全部嵌在 `Bottom_Tier` 现有实心体积内部）。现在文件是 7 个 model、共 6965 个体素、17 种材质。修改前的原始文件备份为同目录下的 `.bak` 文件。详见 [voxel-data-format-json.md](decisions/voxel-data-format-json.md)。
- 已经梳理出完整的模块划分和数据流，见 [architecture.md](architecture.md)（设计阶段，还没有对应实现）。

## 下一步

从风险最高、最不确定的模块开始验证：跑通 ARSession + Vision 手势识别，实测"张开手掌朝上"判定在真机上是否可靠、掌心 3D 定位精度是否够用。这一步的结果会直接影响 [仅支持 LiDAR 机型](decisions/device-scope-lidar-only.md) 这个决策是否站得住——如果先做别的模块，等做到手势识别才发现精度不够，前面的工作会有一部分要推倒重来。

## 进行中 / 待定

- `HappyBirthdayText` 是程序生成的占位字体（简易 3×5 像素点阵），不是美术精修；如果后续要提升视觉质量，需要整体替换这个 model。
- 该 JSON 文件目前放在项目根目录，在 `WillBirthCake` git 仓库之外，还没决定最终放进 Xcode 工程的哪个位置（bundle resource？）。
- 手势判定的具体阈值（手指伸展度、掌心法线夹角）还没有值，需要真机实测调参。
- 单次爆炸同时产生多少个动态刚体会开始掉帧，还没有实测数据。

## 容易踩坑的地方

- 这是全新工程，没有历史包袱，但也意味着 `.ai/debug/` 目录目前是空的（还没发生过值得记录的事故）——不要为了"结构齐全"提前建空文件夹，等真的踩坑了再建。
- 四个决策目前都还没被代码验证过，是纯讨论阶段的产物。如果实现过程中发现某个假设不成立，记得回到对应的决策文件里原地编辑更新（改 status、写清楚为什么原来的理由不再适用），而不是直接绕过去、留一个和文档矛盾的实现。

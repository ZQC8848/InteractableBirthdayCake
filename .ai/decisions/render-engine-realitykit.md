# 渲染引擎用 RealityKit，不用 SceneKit

**2026-08-22 ・ status: standing ・ scope: 不覆盖是否使用 RealityKit 最新的 GPU instancing API（`LowLevelMesh` + `MeshInstancesComponent`）——那取决于项目的最低支持 iOS 版本，目前还没定论**

## 促成这个决定的原因

需要在 RealityKit 和 SceneKit 之间选一个，作为整个 AR 场景搭建、体素 mesh 渲染、爆炸物理模拟的底层引擎。

## 决策

使用 RealityKit 承载 ARKit 会话集成（`AnchorEntity`）、体素 mesh 渲染（按 chunk 合并的 `MeshDescriptor`）和爆炸物理模拟（`PhysicsBodyComponent`）。

## 为什么不用其他方案

| 备选方案 | 它的优势 | 为什么没选 |
|---|---|---|
| SceneKit | 更成熟，网上教程/范例更多；对每个几何体的手动控制更直接 | 苹果已经把 SceneKit 标记为逐步淘汰方向（WWDC25 提到向 RealityKit 迁移），与最新 ARKit 特性的原生集成不如 RealityKit；体素合并/局部重建 mesh 用 `MeshDescriptor` 在两个引擎上的工作量相近，SceneKit 没有明显优势能抵消长期维护风险 |

## 这个决定依赖的假设

| 假设 | 状态 | 依据 / 需要的验证 |
|---|---|---|
| RealityKit 的 `MeshDescriptor` 分 chunk 合并 + 局部重建方案，在预期体素规模（上千个）下渲染性能可接受 | 未验证 | 需要拿到真实体素数据后，在真机上实测合并 mesh 的构建耗时和渲染帧率 |

## 接受的代价

放弃了 SceneKit 更丰富的现成范例和更细粒度的手动节点控制。如果后续想用 RealityKit 原生 GPU instancing 来提升渲染性能，还需要接受更高的最低 iOS 版本要求（iOS 26+，见 `CLAUDE.md` 里的约束说明），这是在 [device-scope-lidar-only.md](device-scope-lidar-only.md) 的 LiDAR 机型限制之外的额外版本约束。

## 什么情况下会推翻这个决定

RealityKit 在实测中暴露出体素合并/局部重建方案无法解决的性能或稳定性问题，并且 SceneKit 有明确更优的替代实现路径。

---

## 被推翻时怎么处理

原地编辑本文件，把上面的 status 行改成指向替代方案，并补充：新决策是什么、原来的理由为什么不再适用。不要删除原记录，也不要另开一份和它默默矛盾的新文件。

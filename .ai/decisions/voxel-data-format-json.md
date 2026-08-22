# 体素数据用 JSON 文件，不再用 MagicaVoxel `.vox`

**2026-08-22 ・ status: standing ・ scope: 只覆盖数据格式本身，不代表当前这份具体文件已经可以直接拿来用——见下方"这个决定依赖的假设"**

## 促成这个决定的原因

之前定的方案是直接读 `.vox`（见 [voxel-data-format-vox.md](voxel-data-format-vox.md)），前提是用户会在 MagicaVoxel 里做模型。但用户实际提供的是 `A_solid_Minecraft-style_voxel_birthday_c.json`，源头本来就不是 MagicaVoxel 工作流，原来"不要打断 MagicaVoxel 编辑流程"这条理由已经不适用。检查了这份 JSON 的结构后，发现它比 `.vox` 更容易用。

## 决策

体素数据用 JSON 格式，直接解析，不再自己写 `.vox` 二进制 chunk 解析器。

具体 schema（来自 `A_solid_Minecraft-style_voxel_birthday_c.json` 实测）：

```
{
  "version": 1,
  "projectName": "...",
  "models": [
    {
      "id": "uuid",
      "name": "Bottom_Tier",       // 图层名，天然可以用来区分"可破坏"和"不可破坏"体素
      "visible": true,
      "origin": [x, y, z],         // 该图层相对整体的偏移
      "voxels": [ { "x": .., "y": .., "z": .., "materialId": N }, ... ]
    }, ...
  ],
  "materials": [
    { "id": N, "name": "...", "r": .., "g": .., "b": .., "roughness": .., "metallic": .., "emissive": .., "emissiveIntensity": .. }, ...
  ]
}
```

## 为什么不用其他方案

| 备选方案 | 它的优势 | 为什么没选 |
|---|---|---|
| 继续用 `.vox`（[原决策](voxel-data-format-vox.md)） | 能直接对接 MagicaVoxel 编辑工作流 | 用户提供的源文件本来就不是从 MagicaVoxel 导出的，这个优势不存在；而且 `.vox` 需要自己写二进制 chunk 解析器（PACK/SIZE/XYZI/RGBA），JSON 用 `Codable` 几行代码就能解析，工作量明显更小 |

## 这个决定依赖的假设

| 假设 | 状态 | 依据 / 需要的验证 |
|---|---|---|
| JSON 结构本身能被 Swift `Codable` 直接解析（字段规整、类型一致） | 已验证 | 2026-08-22 用 Python 读取 `A_solid_Minecraft-style_voxel_birthday_c.json` 全文，6 个 model、共 6847 个体素，每个体素字段固定为 `x/y/z/materialId`，结构一致 |
| `materials` 数组里的 `id` 在同一份文件内唯一，不会有重复定义 | 不成立，但已有约定解决 | 实测 `materials` 数组里 `id: 1/2/3` 各出现两次：先是模板残留的 `Red`/`Green`/`Blue`（明显是占位色），后面才是真正的蛋糕配色 `cake_pink`/`frosting_white`/`frosting_pink`，影响 `Bottom_Tier`/`Top_Tier`/`Frosting` 三层（98% 的体素）。**2026-08-22 拍板**：解析时按数组顺序遍历，同一个 `id` 出现多次时用最后一次出现的定义覆盖前面的——不去改动源文件，靠解析代码里的显式约定处理，写代码时这一条不能省略，否则默认拿第一个匹配就会整个蛋糕变成红/绿/蓝。 |
| 文件里包含"HAPPY BIRTHDAY"文字体素，且能通过图层名等信息区分出来、标记为不可破坏 | 已解决（程序生成占位版） | 原文件确实不含文字层（6 个 model 里最像的是 `Model`，实际是 5 支蜡烛的火苗，材质 `flame_core`）。2026-08-22 用脚本在 `Bottom_Tier` 的实心圆柱体内部生成了一个新图层 `HappyBirthdayText`（3×5 像素方块字体，118 个体素，材质新增 `id 14 text_gold`），分三行嵌在 z=-3/0/3："HAPPY"/"BIRTH"/"DAY"，全部坐标已验证落在 `Bottom_Tier` 现有实心体素范围内，不会露出蛋糕表面。**这是程序生成的占位字体，不是美术精修**，字形是手写的简易 3×5 点阵，可读但比较朴素；如果之后有专门制作的文字体素（比如美术在建模工具里重新做一版），应该整体替换掉 `HappyBirthdayText` 这个 model，而不是在这个占位版本上继续改。 |

## 接受的代价

放弃了"能直接对接 MagicaVoxel 编辑流程"这一点（但反正当前工作流也用不上）。换来的是更简单的解析代码，以及不再需要 `.vox` 场景图（`nTRN`/`nGRP`/`nSHP`）相关的复杂度——JSON 里图层名（`model.name`）直接就能用来分辨"可破坏"和"不可破坏"体素，比 `.vox` 的场景图解析简单得多。

## 什么情况下会推翻这个决定

如果后续发现 JSON 生成工具产出的文件在结构上不稳定（比如字段类型经常变化、每次生成 schema 都不一样），导致 `Codable` 解析要频繁跟着改，可能需要重新评估。目前没有出现这种情况。

---

## 2026-08-22 处理记录

上面两项待处理事项都已经处理：

1. **`materials` 重复 id** — 不改文件，改为解析约定："遍历 `materials` 数组时，同一个 `id` 后出现的定义覆盖先出现的"。写 `VoxelDataLoader` 时这条约定要落实成代码逻辑（比如用 `Dictionary(materials.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })`），不能假设 `id` 天然唯一。
2. **缺文字层** — 已用脚本在原 JSON 里追加了 `HappyBirthdayText` model 和 `id 14 text_gold` 材质，细节见上表。这是占位字体，后续如果要提升视觉质量，替换整个 model 即可，不影响其他图层。

修改前的原始文件备份在 `A_solid_Minecraft-style_voxel_birthday_c.json.bak`（项目根目录，和原文件同级）。

见 [handoff.md](../handoff.md) 了解当前整体进展。

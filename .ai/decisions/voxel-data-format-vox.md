# 体素数据直接用 MagicaVoxel `.vox` 文件

**2026-08-22 ・ status: superseded by [voxel-data-format-json.md](voxel-data-format-json.md)（2026-08-22 当天推翻）・ scope: 不覆盖运行时动态生成体素数据的场景**

## 促成这个决定的原因

蛋糕的体素数据由用户在 MagicaVoxel 里制作，需要决定用什么格式导入到 iOS 工程里。

## 决策

直接读取 MagicaVoxel 导出的 `.vox` 二进制文件，自己实现一个 chunk 解析器（PACK/SIZE/XYZI/RGBA），不做额外的格式转换步骤。

## 为什么不用其他方案

| 备选方案 | 它的优势 | 为什么没选 |
|---|---|---|
| 自定义 JSON/数组格式（从 MagicaVoxel 导出后手动转换一次） | 省去写二进制解析器的工作量，格式完全可控，能直接标注哪些体素是"文字"、不可破坏 | 会打断用户在 MagicaVoxel 里的原生编辑工作流（改了模型要重新手动转换一次）；用户明确选择了保留 `.vox` 直接读取，愿意承担多写一个解析器的成本 |

## 这个决定依赖的假设

| 假设 | 状态 | 依据 / 需要的验证 |
|---|---|---|
| 没有现成的 Swift `.vox` 解析库可以直接用 | 已验证 | 2026-08-22 网络检索：只找到 JS（`parse-magica-voxel`）、Rust（`vox-format`）、C#（`VoxReader`）、Java（`VoxFileParser`）、Haxe（`sh-dave/haxe-format-vox`）版本，没有维护中的 Swift 实现 |
| "HAPPY BIRTHDAY" 文字体素能在 `.vox` 里通过独立 layer/object 或专门的调色板色段区分出来，从而在解析时标记为不可破坏 | 未验证 | 需要拿到实际的 `.vox` 文件后，检查它的场景图（`nTRN`/`nGRP`/`nSHP` chunk）或调色板分配是否满足这个假设；如果不满足，需要请用户重新组织 MagicaVoxel 工程（比如把文字放到独立 object） |

## 接受的代价

需要自己实现并维护一个 `.vox` 二进制解析器（PACK/SIZE/XYZI/RGBA chunk），比直接读 JSON 多一块工作量和潜在的解析 bug 面。

## 什么情况下会推翻这个决定

拿到实际 `.vox` 文件后，如果发现场景图/调色板不足以区分"文字体素"和"蛋糕体素"，且用户不愿意重新组织 MagicaVoxel 工程，就需要改用能显式标注保护区域的自定义格式。

---

## 被推翻时怎么处理

原地编辑本文件，把上面的 status 行改成指向替代方案，并补充：新决策是什么、原来的理由为什么不再适用。不要删除原记录，也不要另开一份和它默默矛盾的新文件。

## 这次是怎么被推翻的

用户实际提供的蛋糕体素数据不是从 MagicaVoxel 导出的 `.vox`，而是一份 JSON 文件（`A_solid_Minecraft-style_voxel_birthday_c.json`，projectName 显示是另一个体素建模工具/流程生成的）。当初否决 JSON 方案的理由——"会打断用户在 MagicaVoxel 里的原生编辑工作流"——不成立了，因为源头本来就不是 MagicaVoxel 工作流。检查这份 JSON 后发现它结构清晰、易解析（见 [voxel-data-format-json.md](voxel-data-format-json.md)），原来"自己写 `.vox` 二进制解析器"这个代价现在是完全可以避免的，所以改用 JSON。

`.vox` 解析器相关的代码目前还没有开始写，所以这次推翻没有代码层面的回滚成本，只是文档层面的决策修正。

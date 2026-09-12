# 主题规范审计：新增 UI 对照「柑橘晨光 Citrus Morning」

> 日期：2026-09-06　范围：仅审计本轮开发新增的 UI（模型弹层改版、用量缓存/构成两卡、文件变更弹层文案）
> 主题源：/d/skills/frontend-design/SKILL.md（frontend-design 技能）+ lib/theme.dart 头注
> 结论：**全部合规，无需改码**

## 主题口径（复核基准）

- 方向：neo-brutalist light —— 奶油底(#FFF6E9) + 墨线硬阴影 + 蜜橘主色(#FF6B1A)
- 状态色：running=橘 / done=青 / error=玫红 / queued=柠黄 / thinking=葡萄紫
- 骨架：ZT.inkSide 墨线边框 + ZT.radius 圆角 + ZT.hard 硬阴影（blur=0）
- frontend-design 技能要求映射：明确的美学方向（neo-brutalist + citrus）✓、主色配尖锐强调 ✓、反通用 AI 脸（无紫渐变白底/无 Inter）✓

## 逐项核对（新增 UI）

| 项 | 核对结果 |
|---|---|
| 模型弹层改版（手风琴/思考药丸/完成按钮） | ✓ 全 ZT 色板；思考=grape 正对"thinking=葡萄紫"语义；选中=primaryDeep；墨线+硬阴影只在展开态（ZT.hard alpha0.2）；BigButton 为主题既有组件 |
| 用量·缓存命中率卡 | ✓ surface 底+墨线 1.4+radius；数字 19pt（对齐 h1 刻度）；aqua/primaryDeep 双格对比；裸 Material 色零使用 |
| 用量·上下文构成卡 | ✓ grape 进度条与 PlanPanel 进度条同构；inkFaint/inkSoft 层级正确 |
| 文件变更弹层文案 | ✓ 仅文字替换，样式未动 |
| Colors.white 使用 | ✓ 仅选中实色药丸上的文字，与旧版 _OptionChip 既有模式一致（onInk 奶油用于墨底气泡） |

## 备注

- 全库此前 UI 均按规范设计，未在本次范围内重复审计。
- 后续若做深色模式（Citrus Night），需先把 ZT 常量改造为可切换（ThemeExtension 或双 const 类）。

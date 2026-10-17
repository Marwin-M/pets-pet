# Pet's Pet 1.2.0 图标来源

- `icon-reference.png`：用户指定的原始参考图，原样保留。
- `AppIcon.png`：通过内置 Imagegen 从参考中提取蓝色圆角底板与白色猫耳双 C；再次处理透明边缘。此为图形提取结果，需随样式一起评审，不声称与参考逐像素一致。
- `MenuBarIcon.png`：通过内置 Imagegen 制作同造型的纯黑透明模板；运行时由 macOS 依据菜单栏背景着色。
- `Scripts/icons.sh` 仅用系统工具做尺寸与格式转换，导出多尺寸 `Resources/AppIcon.icns` 和 44 像素 `Resources/MenuBarIcon.png`。正式包不包含原始参考和高分辨率制作素材。

最终应用图标提示词：

> Precise alpha-edge cleanup of this approved app icon ONLY. Preserve all artwork INSIDE the large blue rounded square exactly unchanged. Remove ALL stray white/blue fragments, speckles, disconnected highlights and irregular halo OUTSIDE the smooth rounded-square boundary. Everything outside the clean rounded-square tile must be fully transparent. The silhouette must be a perfectly smooth continuous macOS rounded square with tiny soft drop shadow only. Keep white cat-ear double-C logo, blue gradient, materials and layout unchanged. Output a single icon centered on transparent square canvas, no other elements.

最终菜单栏图标提示词：

> Create a production macOS menu bar TEMPLATE icon using the exact cat-ear double C logo in the attached reference. Reproduce its silhouette as SOLID PURE BLACK ink on a TRANSPARENT background. BLACK, not white. Two separate mirrored C shapes opening inward, each C with a rounded triangular cat ear at its top outer shoulder. Ear has transparent triangular inner cutout. Smooth mathematical vector-quality boundaries, no texture, no speckles, no anti-alias noise outside the actual edges. Absolutely NO white, NO gray, NO blue, NO shadows, NO blur, NO frame, NO background. Logo centered occupying 75% of square canvas width, no other objects or labels. Tiny gaps between the two C tips must remain transparent. This is a flat monochrome asset, not a material rendering.

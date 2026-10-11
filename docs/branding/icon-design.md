# LINUX DO 光感图标

## 最终资产

- 桌面与启动资源：AppScope 和 entry 的 `app_icon.png`，1254×1254 RGB PNG。
- 预览：`docs/branding/app-icon.png`。
- 采用完整、不透明的第一版成图，保留一致的玻璃边缘和安全留白。透明前景尝试出现外围抠边残留，未接入应用或发布。
- 分层图标的背景使用本项目浅珍珠色 SVG，前景、启动页及关于页面使用同一成图。

## 参考与生成方式

参考官网当前三段圆形图标：黑色上段、白色中段和黄橙下段。官网首页实际 apple-touch 图标：

[官网 CDN 图标](https://cdn3.ldstatic.com/optimized/4X/6/a/6/6a6affc7b1ce8140279e959d32671304db06d5ab_2_180x180.png)

[Neo 发布的品牌 SVG](https://linux.do/t/topic/273378) · [官方 Wiki](https://wiki.linux.do/LinuxDo/culture)

生成使用内置 ImageGen，未调用 CLI 或第三方模型服务。用户指定 image-2.5，但内置接口没有模型选择参数，也未返回模型版本；这里不把无法验证的模型版本标为已锁定。

图像为品牌标识的材质风格演绎，原始 LINUX DO 标识的权利仍归对应权利人，本仓库 Apache-2.0 不授予品牌或原标志许可。

## 最终成图提示词

```text
Use case: style-transfer / production app icon.
Asset type: final square launcher icon for a HarmonyOS NEXT / HarmonyOS 7 native LINUX DO client.
Input image 1 is the CURRENT official LINUX DO brand reference, not a style board: a precise circular medallion with a black upper segment (#1C1C1E), broad pearl-white middle segment (#F0F0F0), amber-gold lower segment (#FFB003), and a thin pearl-white outer ring. Preserve this EXACT circular identity and the three horizontal segment boundaries, orientation, shape and relative proportions. Do not replace it with a letter L, diagonal bars, check mark, penguin, or any other symbol.
Primary request: redesign the finish as refined HarmonyOS immersive light material: a shallow optical-glass circular medallion, crisp brand geometry embedded under translucent polished glass, delicate glass rim highlights, restrained light refraction, a warm amber internal glow in the bottom segment, soft pearl midtone and deep charcoal upper segment. Elegant tactile depth and nuanced reflected light, smooth polished edges, believable premium material. A subtle cool pearly edge tint may balance the warm amber, with minimal saturation.
Composition: straight-on orthographic view, perfectly centered single logo medallion, occupying approximately 70% of the full square canvas, generous even safe margins for platform icon masks. No dramatic perspective. Background is a quiet full-bleed pearl-gray (#F1F3F7) square with subtle luminous gradient, extremely soft ambient shadow only directly under the medallion. All four corners are filled opaque, do not bake in rounded outer corners or include an outer white frame. HarmonyOS supplies the final icon mask.
Output: one polished high-resolution 1024x1024 application icon asset, no presentation sheet, no phone, no desktop, no multiple alternatives. No text, letters, captions, badge, notification count, watermark, slogan, decorative particles, neon halo, excessive bloom or a large cast shadow. Keep the black/white/amber brand legible at 48 pixels. The reference logo geometry is invariant; only finish, material, lighting and icon background are redesigned.
```


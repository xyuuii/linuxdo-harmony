# 参考、许可与归属

## 衍生项目关系

本项目是 [xuemk/linuxdo-android](https://github.com/xuemk/linuxdo-android) 的 HarmonyOS NEXT 功能衍生实现。感谢原作者 [xuemk](https://github.com/xuemk) 提供 Android 客户端与功能参考；原介绍帖：[LINUX DO](https://linux.do/t/topic/2998703)。

- 固定参考提交：`e31fe8e3a06a5de2e9c013925dd1c40a7743d30e`。
- 参考源码版本：1.1.1 / versionCode 9，原 README 标注 1.1.0。
- 2026-10-11 检查时，原仓库未声明 LICENSE、COPYING 或 NOTICE。本仓库的 Apache-2.0 不适用于原 Android 仓库，也不代表取得其代码或资产的再许可。
- 鸿蒙 ArkTS / ArkUI 模块与图标独立实现；未包含原 Android / Gradle 工程或其图形资产。本地 `.reference/` 仅作只读行为参考，不进入 Git、源码包或 HAP。

## 本仓库许可

本项目以 [Apache License 2.0](LICENSE) 发布，版权归 xyuuii 与贡献者；已有第三方版权声明保留。完整归属见 [NOTICE](NOTICE)。

DevEco CLI 生成的 `EntryAbility.ets` 和 `EntryBackupAbility.ets` 保留 Huawei Device Co., Ltd. 的 Apache-2.0 头。EntryAbility 的启动配置已按本应用需求调整。未使用的模板 PNG 已移除，预览背景使用本项目 SVG。应用图标的三色圆形品牌结构参考 LINUX DO 官网，由内置 ImageGen 生成材质风格演绎；详见 `docs/branding/icon-design.md`。原始品牌标识的权利不因本仓库 Apache-2.0 许可而转让。

HarmonyOS SDK、HDS/ArkUI 系统组件、DevEco Studio 与 DevEco CLI 不随仓库分发，需要开发者自行安装并遵守各自使用条款。测试可以调用已安装的 TypeScript 编译运行时；CI 仅安装公开 TypeScript 4.9.5 执行离线逻辑 fixture，不分发 Huawei SDK。

## 阅读操作图标

`ic_more_horiz.svg` 和 `ic_boost_rocket.svg` 来自 Google [Material Design Icons / Material Symbols](https://github.com/google/material-design-icons)，分别使用 `more_horiz` 和 `rocket_launch` 的 outlined 24px 原始 SVG，仅由 ArkUI 按主题着色。采用 Apache-2.0；完整原文随 HAP 内嵌于 `resources/rawfile/MATERIAL_SYMBOLS_LICENSE.txt`。

## ECH 可行性原型

`experiments/ech-probe/` 是独立的开源 TLS 验证代码，使用 Rustls 0.23.45 / AWS-LC、WebPKI roots、Hickory protocol 0.26.3、httparse、chunked-transfer、base64 和 serde_json；精确版本与校验和见该目录 Cargo.lock。v0.3.1 起另附开发调试签名的 edge DoH/ECH 试验 HAP，其中 Rustls 库用于诊断，业务请求仍经 ArkWeb，不作为普通版网络层发布。锁定依赖、AWS-LC 内含第三方代码及 SDK 提供的 libc++ 运行库的许可/归属原文汇总见 [THIRD_PARTY_LICENSES.txt](experiments/ech-probe/THIRD_PARTY_LICENSES.txt)，同时随试验 HAP 内嵌并作为 Release 附件提供。

原型读取了 Android 项目提交 `a7e6c81bccee1eec8f75542a91fcd6c0f24e11b5` 的公开 DoH 预设地址作为连接对照；没有复用、移植或分发其闭源 AAR / native 库。实现与复现入口见 [实验说明](experiments/ech-probe/README.md)。

## 名称与内容

这是社区开发的第三方客户端。LINUX DO、HarmonyOS、Huawei 名称，以及论坛内容与账号，归对应权利人；本仓库的软件许可不授予品牌或论坛内容许可。公开截图展示本应用首页、目录、搜索筛选、公开帖子、空白编辑器、功能入口及外观设置；论坛内容仅用于说明客户端呈现效果，权利仍归原作者。截图不包含登录信息、私信或账号资料。

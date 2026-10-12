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

## 名称与内容

这是社区开发的第三方客户端。LINUX DO、HarmonyOS、Huawei 名称，以及论坛内容与账号，归对应权利人；本仓库的软件许可不授予品牌或论坛内容许可。公开截图展示本应用首页、分类、公开帖子、空白编辑器及外观设置；论坛内容仅用于说明客户端呈现效果，权利仍归原作者。截图不包含登录信息、私信或账号资料。

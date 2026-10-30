# 开发与验证

本文保留原 README 中的实现、构建和历史验证说明；设备结论按各自日期与版本理解。返回 [项目首页](../README.md)。

## 鸿蒙 7 原生设计

使用 `HdsNavigation` 组织页面、`HdsTabs` 切换主页面内容。帖子在 `NavDestination` 内绘制固定的作者/话题双行标题，高度为动态顶部避让加56vp。首页与帖子顶栏采用透明背景模糊，让滚动文字和图片成为背景采样；关闭效果或高对比时使用实色。

主导航与帖子阅读胶囊由透明的原生 `Tabs` / `TabBar` 展示宿主承载，在 API26 支持的底部 TabBar 区域内通过 `systemMaterial` 使用 `uiMaterial.ImmersiveMaterial`。宿主关闭默认材质和模糊，子按钮使用 `Material.empty`，由胶囊单独承担原生材质与触点光感。原生路径与兼容模糊、染色背板互斥。通知筛选、外观预览等普通内容区域，以及不支持原生材质或构造失败时，使用兼容背景模糊、主题染色和触点层；预览背景仍是独立静态 SVG。其余控件按 `MaterialPolicy` 申请通用系统材质。

`AdaptiveNavigationBar` 主导航展开时最大280×52vp、居中显示，图标21vp、标签11vp；收起为48vp圆钮，底部只保留系统避让。选中项通过图标、文字着色和无障碍选中状态表达，不再添加单项圆形底。2026年10月20日在同一台 Pura X View 对照 IT之家9.01主页实测，客户端展开宽度和底缘与其280×56vp栏对齐。主导航保留一个材质表面和五个稳定 key 的图标节点，由同一个弹簧 progress 连续驱动宽高、位置、图标位移与文字透明度；展开使用完整窗口宽居中，收起仍靠真实左右手侧。`HdsTabs` 的 `barHeight` 为0，只负责业务内容切换；展示宿主不接管原有导航、收放和双击回顶逻辑。

首页顶部固定品牌/搜索/发帖与文字标签，选中加粗及短下划线，消息从底栏进入。内容采用原生 `Swiper` 连续跟手分页，拖动中同时显示当前页与邻页；五页分别保留内容、分页及滚动位置，预加载相邻页和点选目标。普通模式点击标签也有过渡，减少动态仍保留手指直接拖动，没有额外手写 Pan 与列表争抢手势。参考截图只保留在本机，未复制其它 App 的源码、图标或媒体资源。

握姿适配使用官方 `motion.on('holdingHandChanged')`，只依据系统明确的左手/右手结果调整收起按钮侧别，不根据触点、设备倾斜或模拟数据猜测。前台订阅、后台和销毁取消；未握持、双手和未知保持上次明确侧别，没有明确结果时默认右边。机型不支持返回801时保留布局，模拟器无法验证握姿硬件。实现依据[智感握姿最佳实践](https://developer.huawei.com/consumer/cn/doc/best-practices/bpta-smart-reach)及[获取用户动作指导](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/motion-guidelines)。

| 等级 | 通用系统材质配置 | 原生底栏配置 | 兼容表面 |
| --- | --- | --- | --- |
| 关闭 | 实色、`Material.empty` | 实色、`Material.empty` | 实色 |
| 轻柔 | `REGULAR`，无交互形变，`lightEffect: null` | `THIN`，无交互形变，`lightEffect: null` | 背景模糊 radius 12、主题染色，无触点流光 |
| 标准 | `REGULAR`，无交互形变，`lightEffect: {}` | `THIN`，无交互形变，`lightEffect: {}` | 背景模糊 radius 10、主题染色和触点流光 |
| 丰富 | `THIN`，交互形变，`lightEffect: {}` | `ULTRA_THIN`，交互形变，`lightEffect: {}` | 背景模糊 radius 8、主题染色和触点流光 |

启用的原生沉浸材质均设置 `applyShadow: false`。高对比覆盖材质选择，使用实色和清晰边框。减少动态关闭交互形变及页签自动过渡，并让主导航保持展开；标准/丰富等级仍保留直接随触点移动的高光，不加入自主循环动画，不宣称停止帖子 GIF。2026年10月20日的 Pura X View 与 CodexPhone 验证观察到栏内触点提亮，真机减少动态开启时高光仍能从“话题”移动到“分类”“搜索”，释放后恢复；具体配置和验收边界见[验证记录](acceptance.md)。本应用不修改系统材质等级。

启动时先获取主窗口并等待 `setWindowLayoutFullScreen(true)` 完成，再加载页面；任一步失败仍按默认布局继续加载，窗口布局失败只记录安全错误码。Index 通过 `@Env(SystemProperties.WINDOW_AVOID_AREA)` 获取以 vp 表示的动态避让信息：顶部取状态栏与挖孔高度的最大值，底部取手势指示条、系统栏与挖孔高度的最大值，不相加，也不把键盘高度计入系统栏避让。

Root / Navigation 负责扩展系统区，子 List / Refresh 不重复叠加 `ignoreLayoutSafeArea`。首页列表从固定顶栏后方滚动，`contentStartOffset` 使用 `topInset + 实测顶栏高度`，回到顶部的判断也计入同一偏移；帖子列表使用 `topInset + 56vp`。消息列表保留独立滚动位置并为浮动底栏预留末端空间。状态区 `EdgeBackdrop` 使用普通背景模糊和由主题色到透明的渐变染色，轻柔、标准、丰富的 radius 分别为12、10、8，不使用 `OFFSCREEN` 混合遮罩；关闭效果或高对比时使用实色，该层不响应触摸或交互光晕。Root 使用100%高度，普通页面采用 UIContext 的 `RESIZE`，键盘可见时隐藏主导航。半模态编辑器期间暂用 `OFFSET`，由 Sheet 自身的 `RESIZE_ONLY` 压缩输入内容；真正退场后恢复 `RESIZE`。

[华为设计规范](https://developer.huawei.com/consumer/cn/design/) · [HarmonyOS 7 / API 26 升级指导](https://developer.huawei.com/consumer/en/doc/harmonyos-releases/upgrade-adaptation) · [官方沉浸光感方案](https://developer.huawei.com/consumer/cn/doc/guidebook/solution-0000002784570841)

实现依据[沉浸光感开启说明](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/arkts-immersive-light-sense-enable)、[沉浸光感最佳实践](https://developer.huawei.com/consumer/cn/doc/best-practices/bpta-spatiality-immersive)和[页签点击响应 FAQ](https://developer.huawei.com/consumer/cn/doc/doccenter-dev-faq/faqs-performance-20)。设计参考[IT之家鸿蒙版9.0官方介绍](https://www.ithome.com/1/003/407.htm)，并在上述真机上对照9.01主页尺寸与文章栏按压反馈；参考交互与层次，不复制素材。

## 登录与数据边界

- API / 原生桥只面向 `https://linux.do`，Cookie 从本应用 ArkWeb 读取，HttpOnly 可同步，密码和两步码不持久化。
- 原生请求禁止自动重定向。公共外域图片不带论坛 Cookie / CSRF。
- 网页认证精确允许当前站点展示的身份提供方，显示真实 origin。GitHub 跳转已在模拟器确认到 `github.com` 的真实登录页。
- 认证弹窗使用独立 controller / 原生面板，保留 POST、window.name 与 opener，子窗口不注册原生桥。
- 用户完成网页验证，或同源只读 CSRF 探测获得有效 JSON 回执后，才启用浏览器传输。遇盾的读取请求共用一次限时恢复，最多重试一次；不自动解验证码，不自动重放写请求。
- 登录、论坛会话及过盾 Cookie 从原生响应更新时及时请求 ArkWeb 落盘，恢复成功也请求落盘；不另存或回灌旧过盾凭据。切后台、换账号、打开手动登录页会取消自动恢复，仍需人机交互时保留网页验证入口。
- 换账号立即取消旧请求、清显示数据和缓存；图片按账号、会话代数及进程隔离。
- 缺失编辑/删除/回复权限按不允许处理，提交前再次向服务器核实。写请求超时提示结果未确认，避免自动重复提交。
- 静态声明 `INTERNET` 和用于前台握姿感知的 `DETECT_GESTURE`，后者为普通级 `system_grant` 权限，不额外弹出动态授权；选文件走系统选择器，图片保存通过安全控件临时授权。

“我的 → 关于与连接诊断 → 检测连接能力”可以对比系统 DNS、加密 DNS 及 Cloudflare 对照站点下的原生请求与 ArkWeb 连接。探测不发送论坛凭据，网页使用独立隐私模式，仅显示服务端的 TLS / SNI 结果；退出或完成后撤销临时 ArkWeb DoH 配置。该入口用于验证能力，当前未开启应用全链路的 DoH + ECH 免代理直连；DoH 可用不等于 ECH 生效。

2026-10-18 的独立原型已在关闭 VPN/代理的真机 Wi-Fi 下确认 Rustls 与 ArkWeb 的 ECH 回执，跑通现有登录会话的首页、帖子读取及进程重启自动恢复。10月19日补齐论坛与已验证 CDN 的浏览器图片读取，真机成功解码且用户确认恢复；上传、长期过盾及完整接入仍待验收，见 [ECH 方案验证](ech-feasibility.md)。实验源码与复现步骤在 [experiments/ech-probe](../experiments/ech-probe/README.md)，不作为当前普通调试版已支持全功能直连的声明。

## 工程与构建

本机验证环境：DevEco Studio 26.0.0.821、HarmonyOS SDK 26.0.0.105 Release、DevEco CLI 1.3.0-stable、CodexPhone API 26 模拟器。

安装 DevEco Studio、HarmonyOS 7 / API 26 SDK 和 devecocli；完整 ArkTS / ArkUI 编译需要官方工具。随后：

```sh
git clone https://github.com/xyuuii/linuxdo-harmony.git
cd linuxdo-harmony
./scripts/build.sh
node --test tests/*.test.mjs
```

macOS 默认从 DevEco 的内置 TypeScript 路径执行测试；其他安装位置可设置 `DEVECO_TYPESCRIPT_PATH=/path/to/typescript/lib/typescript.js`。

在没有 HarmonyOS SDK 的机器上，仅执行离线逻辑测试：

```sh
npm install --prefix .local-test-runtime --no-save --package-lock=false --ignore-scripts typescript@4.9.5
DEVECO_TYPESCRIPT_PATH="$PWD/.local-test-runtime/node_modules/typescript/lib/typescript.js" node --test tests/*.test.mjs
```

离线回归读取实际生产方法，覆盖首页信号消费、刷新并发、置顶分组、喜欢反馈、简评展示与握姿生命周期等。GitHub Actions 使用 TypeScript 4.9.5 和 Node 22 执行同一测试集；测试只读取源码和编译运行时，不访问真实论坛或设备存储。它不编译 ArkUI、不登录论坛，不替代 SDK 编译及设备验收；各版本实际结果见[验收记录](acceptance.md)。

本机 `app/build-profile.json5` 不进入 Git；仓库提供无凭据的 `build-profile.example.json5`，首次执行 build.sh 会复制模板。需要安装到自己的设备时，以自己的开发者账号生成包含目标设备的调试签名：

```sh
cd app
devecocli auth login
devecocli signature generate --product default
devecocli run --module entry --device CodexPhone
```

macOS 上如遇 CLI 把已有镜像误判未下载，可用 `./scripts/start-emulator.sh <已有实例名>` 调用官方底层 Emulator。脚本默认使用当前用户的镜像和实例目录，可通过 `DEVECO_STUDIO_CONTENTS`、`HARMONY_SYSTEM_IMAGE_ROOT`、`HARMONY_EMULATOR_INSTANCE_ROOT` 覆盖；只启动既有实例，不修改镜像 metadata 或清除 userdata。

## 验证

- 完整 SDK 编译、调试签名、安装、启动通过；模拟器 HDC 地址 `127.0.0.1:5555`，API 26 Release。
- 本地测试读取实际 .ets：响应映射、权限缺省、分页、通知口径、Unicode 简评、写 payload、401/403/429、取消、账号切换、图片隔离和认证域名。
- 已看到真实服务器最新话题，未使用模拟帖子填充应用。
- 0.2.1 的81项离线回归通过；当时的主导航收拢、点击展开与正文滚动已在模拟器观察。帖子末尾继续上拉反馈、尾部分页回首楼等阅读控制有模拟器记录与方法回归。
- Pura X View / HarmonyOS 7 真机用于观察酷安鸿蒙版7.1.1的实际交互；0.2.7本客户端的兼容底栏也有真机视觉记录。0.2.8逐项结果以验收记录为准，不将兼容视觉观察扩大为原生光学、握姿硬件或功耗验证。
- GitHub 认证入口已实测跳转成功；用户完成授权后，原生个人页确认会话有效，重启后仍可读取真实帖子。搜索“鸿蒙”已返回真实结果。
- 0.2.8在模拟器实测喜欢与撤销，并以Chrome回读确认恢复未赞；我点赞过可读到新记录。未发帖、上传、删除或改变通知已读状态。第二账号切换、握姿传感器及本轮物理设备光感仍未端到端验证，详见验收记录。
- `devecocli check lint` 当前返回 Files checked:0，不能作为 lint 有效通过；静态依据是 SDK 编译。
- SaveButton 调用 createAsset 的静态权限提示与官方临时授权场景对应，不为消除提示增加广域图库权限；相关文件/网络异常有释放和失败处理。

验证记录见 [docs/acceptance.md](acceptance.md)。本机日志、账号界面、签名私钥和配置不随公开源码分发；调试签名安装包单独提供在 GitHub Release，其他开发者需使用自己的 SDK 和设备签名构建。

## 与 Android 版本的区别

- 页面和系统能力全部为鸿蒙原生；网页登录只用于身份认证/站点验证。
- 原 Android APK 版本源不用于鸿蒙更新。GitHub Release 提供手动下载HAP，应用内尚未接入自动更新或应用商店渠道。
- 原外部浏览器 RSA user-api-key 授权由本应用 ArkWeb 身份提供方登录和同源传输替代；没有注册 Android 的 discourse:// 授权回调。
- 话题读取仍使用 `track_visit=false`；阅读页新增基于真实可见楼层、前台与遮挡状态的 `/topics/timings` 毫秒计时上报。失败批次不自动重放，网站阅读统计是否增加需以实际服务器回执与账号记录验证。
- Android 参考克隆只保留在本地 .reference，排除 Git 和交付包。公开仓库为独立鸿蒙实现，归属及许可范围见 [THIRD_PARTY.md](../THIRD_PARTY.md)。

## 工程结构

- `app/entry/src/main/ets/pages/`：原生页面与导航。
- `components/`：话题列表、富文本、原生图片和材质预览。
- `models/`：论坛数据、会话及持久化外观设置。
- `services/`：论坛协议、网络/浏览器传输、媒体缓存与材质策略。
- `tests/`：读取实际 .ets 的离线 fixture。
- `scripts/`：构建入口和既有模拟器启动。

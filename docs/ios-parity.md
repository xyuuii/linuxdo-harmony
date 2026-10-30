# iOS 客户端对照与鸿蒙重构记录

日期：2026-10-28。参考客户端为本机已安装的 LINUX DO iOS **1.0.3，build 6**。版本来自应用的 `Info.plist`；功能观察来自实际客户端 UI，资源候选来自其本地化文案。本文件不包含账号、设备标识、凭据、私信、论坛帖子内容或参考客户端素材。

本轮目标是对齐常用功能、信息层级和交互，并把 iOS 液态玻璃转换为鸿蒙沉浸光感。当前仍有明确缺口，不能表述为已经 100% 复刻全部 iOS 功能。

## 证据和状态口径

| 标记 | 含义 |
| --- | --- |
| UI 已观察 | 本轮实际打开参考客户端并观察到了对应入口、页面或交互；不代表对该入口下的全部服务端操作完成验证。 |
| 资源候选 | 安装包内存在相关文案；尚不能据此确认当前账号权限、站点配置或完整流程。 |
| 本地已实现 | 当前 ArkTS/ArkUI 源码已经有可执行路径，并有对应离线 fixture、生产方法测试或 SDK 编译证据。 |
| 待设备验收 | 仍需在本轮安装包、实际网络、当前账号和目标设备上确认表现；不沿用旧版截图或旧版测试结论作为本轮通过证据。 |

离线测试使用受控响应和系统能力替身，执行实际生产逻辑。它能验证参数、状态、分页、取消和回执处理；真实论坛权限、原生键盘、分享面板、动画与光学材质仍需设备证据。

## 本轮统一验证快照

| 项目 | 当前证据 | 边界 |
| --- | --- | --- |
| 完整离线回归 | 429 项通过，0 失败 | 包含后续官网预览、编辑历史、个人插件记录和视区锚点回归；不等于 429 个功能已完成真机验收。 |
| 普通包 SDK 构建 | HarmonyOS 7 / API 26 编译及调试签名成功 | 普通签名 HAP；未据此宣布发布、上架或全部功能生效。 |
| 真机安装 | 普通包 0.4.0 / 400 已保留数据安装并启动于 Pura X View | 安装成功不代表网络、登录会话及全部业务交互通过。 |
| 当前网络 | 普通包和手机浏览器均无法访问社区，后者由用户确认；后续 DoH/ECH 候选已读出真实首页、头像、未读数、帖子及目录 | 这是本轮具体网络与安装包的结果，不保证其它网络或长期连接表现；最终更新另记录启动状态。 |
| 原生沉浸光感 | Pura X View / API 26 已验证主导航按住、同次按压跨按钮移动、松开恢复；深浅色、标准/丰富、减少动态、高对比及轻柔有实际画面；阅读单胶囊也已验证正文透底模糊与按住提亮 | 结论限定本次机型、系统和配置，不以能力查询代替显示证据。 |
| 对外发布 | 本轮未发布 | 本地改动、构建和安装分别记录。 |

统一检查入口：`node --test tests/*.test.mjs`、`./scripts/build.sh`。旧版设备记录保留在 [acceptance.md](acceptance.md)，应按其版本、日期和场景理解。

## UI 已观察的核心路径与当前实现

下表“本地已实现”均指源码及离线证据；最后一列列出本轮仍需完成的设备检查。

| 参考客户端中已观察的路径 | 鸿蒙当前实现与源码 | 本地验证依据 | 本轮设备状态 |
| --- | --- | --- | --- |
| 主页：最新 / 新 / 未读 / 热门 / 排行五筛选 | [HomeTopicFeed.ets](../app/entry/src/main/ets/components/HomeTopicFeed.ets)、[TopicFeed.ets](../app/entry/src/main/ets/components/TopicFeed.ets)；保留独立筛选状态、刷新与分页，切换和横滑使用现有原生容器 | [home-topic-feed.test.mjs](../tests/home-topic-feed.test.mjs)、[topic-feed.test.mjs](../tests/topic-feed.test.mjs) | 五筛选真实内容、来回切换和阅读位置待验 |
| 主页：分类、标签与排序；排行时段 | [ForumApi.ets](../app/entry/src/main/ets/services/ForumApi.ets) 的 `fetchTopicFeed` 与浏览条件；分类路径、标签、排序和时段随分页保留 | [topic-browse-actions.test.mjs](../tests/topic-browse-actions.test.mjs) | 组合条件、长列表分页、服务端排序结果待验 |
| 目录：分类 / 标签 / 徽章 / 群组四段 | [CategoriesPage.ets](../app/entry/src/main/ets/pages/CategoriesPage.ets)、[DirectoryModels.ets](../app/entry/src/main/ets/models/DirectoryModels.ets)、[DirectoryWire.ets](../app/entry/src/main/ets/services/DirectoryWire.ets)；四段均读取真实目录数据，没有空的占位入口 | [directory.test.mjs](../tests/directory.test.mjs) | 目录显示、当前权限及空态待验；群组成员和加入流程不在已完成范围 |
| 目录分类：查找分类或子分类、连续行、简介、话题数、独立展开子分类 | 本地搜索保留匹配子分类的祖先；按层级独立收展，展示分类简介及包含子分类的话题计数；点击分类进入话题列表 | 分类展开、搜索上下文和计数 fixture | 真实分类树、长名称、折叠与点击区域待验 |
| 目录标签：查找、按名称或话题数排序、进入标签话题 | 完整聚合 `/tags.json` 的普通及分组标签，去重后搜索、排序及每 100 项分页；按标签路由到话题列表 | 分组聚合、去重、分页、会话隔离 fixture | 真实标签数量、受限标签及按标签浏览待验 |
| 阅读：单个底部胶囊内的回复、收藏和楼层进度 | [TopicPage.ets](../app/entry/src/main/ets/pages/TopicPage.ets) 的统一阅读操作栏；共用一层材质，显示可见楼层、总楼层和进度，接入跳楼与回复 | [topic-reader.test.mjs](../tests/topic-reader.test.mjs)、[topic-back-control.test.mjs](../tests/topic-back-control.test.mjs)、[post-actions.test.mjs](../tests/post-actions.test.mjs) | 控件尺寸、遮挡、按压、收放、进度及键盘避让待验 |
| 阅读：话题与楼层收藏、撤销收藏 | 话题入口收藏首楼；楼层入口收藏该帖子。只有明确成功回执才更新状态，撤销使用服务器返回的 bookmark ID；我的收藏读取现有服务器记录 | 收藏成功、未知结果、元数据缺失、切账号与隐藏页面 fixture | 实际收藏、撤销及列表同步待验；备注和提醒管理尚未完成 |
| 阅读更多：话题通知级别、分享和复制链接 | [TopicNotificationOptions.ets](../app/entry/src/main/ets/components/TopicNotificationOptions.ets)、[PostSharing.ets](../app/entry/src/main/ets/services/PostSharing.ets)；通知级别提交检查回执，链接为规范 HTTPS 话题/楼层地址，使用系统分享能力 | [topic-browse-actions.test.mjs](../tests/topic-browse-actions.test.mjs)、[post-actions.test.mjs](../tests/post-actions.test.mjs) | 真实通知设置与系统分享面板待验；打开分享面板不代表已向他人发送 |
| 楼层更多：引用回复和举报 | 引用先取得真实原文并带上用户名、话题和楼层，再进入本机编辑草稿；[FlagPostSheet.ets](../app/entry/src/main/ets/components/FlagPostSheet.ets) 仅呈现服务端允许的举报类型 | 引用原文、权限变化、迟到响应、举报类型及回执 fixture | 本轮未据离线结果宣称实际发出引用回复或举报；实际服务端流程待验 |
| 阅读：头像或用户名进入成员资料 | [UserProfilePage.ets](../app/entry/src/main/ets/pages/UserProfilePage.ets)、[UserProfileWire.ets](../app/entry/src/main/ets/services/UserProfileWire.ets)；真实头像、用户名、名称、信任等级、简介、统计和话题/回复活动；隐藏资料和未公开数值保留未知 | [user-profile.test.mjs](../tests/user-profile.test.mjs) | 公开/隐藏资料、游客限制、长简介、返回位置及账号切换待验 |
| 阅读：话题内搜索与精确楼层定位 | [SearchPage.ets](../app/entry/src/main/ets/pages/SearchPage.ets) 的 `topicScopeId` 路径；明确显示“搜索本话题”，逐条显示命中帖子，检查结果没有退回全站范围 | [search-experience.test.mjs](../tests/search-experience.test.mjs) | 同话题多个命中、分页、回到指定楼层待验 |
| 编辑器：新建话题、回复、编辑、分类和标签及工具栏 | [ComposerPage.ets](../app/entry/src/main/ets/pages/ComposerPage.ets)；保留原生半模态、键盘布局和权限重查；图片/附件、表情、粗体、列表、代码块及链接插入；实际发表才上传 | [composer-lifecycle.test.mjs](../tests/composer-lifecycle.test.mjs)、[composer-sheet.test.mjs](../tests/composer-sheet.test.mjs)、[forum-wire.test.mjs](../tests/forum-wire.test.mjs) | 键盘、选择器、长正文、审核回执等真实流程待验；官网 cooker 预览源码和专项验证已完成，真实模块能力仍需设备确认 |
| Me：统计、我的话题、回复、已读、喜欢、收藏及草稿入口 | [ProfilePage.ets](../app/entry/src/main/ets/pages/ProfilePage.ets)、[ProfileSectionPage.ets](../app/entry/src/main/ets/pages/ProfileSectionPage.ets)；使用真实统计和记录，送出与收到的喜欢区分口径，未知数值不补零 | [profile-page.test.mjs](../tests/profile-page.test.mjs)、[forum-wire.test.mjs](../tests/forum-wire.test.mjs) | 实际记录数量、分页、收藏来源及首未读定位待验 |
| Me：我的投票、我的方案、我的 Boost | [ProfilePage.ets](../app/entry/src/main/ets/pages/ProfilePage.ets)、[ProfileSectionPage.ets](../app/entry/src/main/ets/pages/ProfileSectionPage.ets) 与 [ForumApi.ets](../app/entry/src/main/ets/services/ForumApi.ets)；新增三个原生记录入口。投票读取未归档的话题投票；方案读取该用户被采纳的回复；Boost 分“我发出的 / 我收到的”，保留各自分页及准确楼层。插件未开放、权限拒绝、缺少楼层和异常响应均明确报错，不补成空记录 | [profile-plugin-records.test.mjs](../tests/profile-plugin-records.test.mjs) 的 8 项专项通过，并通过受影响的个人页、协议回归；SDK 集成结果随统一验证更新 | 目标站点实际插件版本、权限、真实记录、分页及跳楼均待设备验收；这三个列表不代表完整投票、解答或 Boost 插件功能已全部实现 |
| Me：草稿列表、继续编辑和删除 | [DraftsPage.ets](../app/entry/src/main/ets/pages/DraftsPage.ets)、[DraftRepository.ets](../app/entry/src/main/ets/services/DraftRepository.ets)；发现既有本机草稿、恢复原场景并按账号隔离，异常草稿保留可见，删除精确定位记录 | [drafts.test.mjs](../tests/drafts.test.mjs) | 真实旧草稿、新话题/回复/编辑草稿往返、删除及重启持久化待验；云端同步未实现 |
| 设置：默认话题列表、沉浸话题、打开首个未读 | [AppearancePage.ets](../app/entry/src/main/ets/pages/AppearancePage.ets)、[ReadingPreferences.ets](../app/entry/src/main/ets/services/ReadingPreferences.ets)；持久化沿用原设置存储，首未读限制在服务器真实进度范围内，明确楼层链接保留原目标 | [reading-preferences.test.mjs](../tests/reading-preferences.test.mjs) | 重启恢复、不同话题进度、沉浸收放及无障碍优先级待验 |

## 后续补齐的预览与编辑历史

- 编辑预览：只在点击“预览”时调用固定官方网页模块，独立 nonce、结果类型、限长和取消，不执行 HTTP 发表或附件上传。导航、后台、切账号均取消；切回编辑保留草稿。`composer-preview.test.mjs` 的 11 项专项执行真实注入脚本及页面生产方法。
- 编辑历史：仅在 `can_view_edit_history === true` 且公开版本大于 1 时出现；使用专用 latest 接口及服务端前后版本指针，尊重隐藏历史，不枚举或重建隐藏正文。原生显示编辑者、时间、原因和安全差异，不提供回滚或修改。`post-revisions.test.mjs` 与官方 API fixture 覆盖权限、跳版、安全渲染和迟到响应。

## 其他已实现路径及其边界

| 路径 | 本地实现 | 仍需确认 |
| --- | --- | --- |
| 全站搜索的最近项与高级筛选 | [SearchPolicy.ets](../app/entry/src/main/ets/services/SearchPolicy.ets)、[SearchHistoryStore.ets](../app/entry/src/main/ets/services/SearchHistoryStore.ets)、[SearchHistoryPreferences.ets](../app/entry/src/main/ets/services/SearchHistoryPreferences.ets)；仅标题、分类、标签和发帖人组合条件，保留六排序；最近项可单删、清空和复搜。记录按账号持久化，话题内搜索另分范围存储 | 参考端完整高级搜索仍应逐项核验；当前不是完整用户、群组、分类等跨对象搜索 |
| 阅读时长与已读进度上报 | [TopicReadTracker.ets](../app/entry/src/main/ets/services/TopicReadTracker.ets)、`ForumApi.recordTopicReadTimings`；只统计登录、前台、页面可见且真实可见楼层的时间；弹层、后台和切账号暂停或清理，已消费批次失败不自动重放 | [topic-read-tracker.test.mjs](../tests/topic-read-tracker.test.mjs) 与 [reader-tracking.test.mjs](../tests/reader-tracking.test.mjs) 验证本地规则；网站阅读统计真实增量仍待验 |
| 消息和已有私信 | 保留全部 / 回复 / 收到的赞 / 私信筛选、真实历史 offset、未读角标及通知楼层定位；私信可读取已有会话 | 新建私信、成员管理、私信标签/归档及系统后台通知不在已完成范围 |
| 登录、会话和媒体 | 复用既有 `ForumApi`、`ForumSession`、`BrowserTransportAdapter` 与原生媒体加载；不另建网络层，保留鉴权、外域媒体凭据边界和只读恢复，写操作不自动重放 | 本轮网络恢复后仍需重验登录会话、站点验证、图片/GIF与原图查看；旧版设备记录不自动成为本轮通过结果 |

## 液态玻璃到沉浸光感的映射

| iOS 中的材质/交互位置 | 鸿蒙实现 | 本轮验收边界 |
| --- | --- | --- |
| 主导航与阅读底部浮动胶囊 | [MaterialBarHost.ets](../app/entry/src/main/ets/components/MaterialBarHost.ets) 承载真实底部 TabBar 区域；[ReaderGlassSurface.ets](../app/entry/src/main/ets/components/ReaderGlassSurface.ets) 与 [MaterialPolicy.ets](../app/entry/src/main/ets/services/MaterialPolicy.ets) 复用原生沉浸材质路径 | 主导航真机结果见下节；阅读页仍需单独确认 |
| 普通菜单、筛选与半模态 | 使用现有主题、系统材质策略和兼容背景；子按钮不重复叠加一层玻璃 | 各层是否正确采样、弹层高度、文字对比和键盘避让待验 |
| 按压提亮、收拢和过渡 | 沿用系统 `lightEffect` 或兼容触点反馈；减少动态、高对比与关闭效果分别使用既有策略 | 源码参数与静态截图不直接证明动态光效完整；长按、拖移、释放及深浅色仍需观察 |

材料指南依据：[华为沉浸光感方案](https://developer.huawei.com/consumer/cn/doc/guidebook/solution-0000002784570841)。具体设备结果后续写入本文件或 [acceptance.md](acceptance.md)。

### Pura X View 主导航实际验证

普通 0.4.0 / 400 签名包在 API 26 真机上验证，随后通过同一台手机的无线调试继续。主导航实测边界为 280 × 52 vp；子按钮关闭普通按压态，并为空材质，局部提亮来自共用的原生沉浸材质路径。

- 深色/丰富：按住“我的”时右端出现局部高光；同一次触摸横移到“搜索”和“话题”，高光连续跟随；释放后恢复。
- 减少动态开启：直接跟手高光仍可见；关闭弹性及收拢策略另有生产逻辑回归覆盖。
- 高对比：实色背景及清晰边框，按住时没有触点高光。
- 轻柔：保持可见表面，按住时没有触点高光。
- 标准：按住时出现局部高光。
- 浅色/丰富：页面、文字和材质切换为浅色，按压反馈可见。测试后恢复原来的深色、丰富、减少动态关闭及高对比关闭。

本机证据保留于忽略的 `artifacts/`：`ios-parity-pura-native-before-final.png`、`ios-parity-pura-native-held-final.png`、`ios-parity-pura-native-moving-right.png`、`ios-parity-pura-native-moving-left.png`、`ios-parity-pura-native-released-final.png`、`ios-parity-pura-reduced-held.png`、`ios-parity-pura-contrast-held.png`、`ios-parity-pura-gentle-held.png`、`ios-parity-pura-standard-held.png`、`ios-parity-pura-light-held.png`。阅读页的 `ios-parity-pura-reader-ready.png` 和 `ios-parity-pura-reader-held.png` 分别记录正常与按住状态，正文与头像从材质后方真实透出并模糊，按住时局部提亮。这些文件未随公开源码分发。

### 本轮在线界面验收

DoH/ECH 候选在真机恢复既有会话后，首页出现真实话题、头像和未读角标；目录四段分别读出分类、2050 个标签、徽章及受权限约束的群组。分类独立展开可见当前账号允许的子分类；从“人工智能”标签进入独立话题页，页标题和内容均可用。真实阅读页展示同一材质胶囊内的回复、收藏、楼层进度，以及顶部搜索/更多。证据包括 `ios-parity-pura-trial-home-loaded.png`、`ios-parity-pura-directory.png` 和阅读页画面。

此阶段还发现并修复了视区锚点错误：原实现用最后可见行，少量露出的嵌套楼层会覆盖显式跳楼目标。最终源码改用原生视区中间项映射真实楼号，并在实际用户滚动前保留显式目标；三项新增生产方法回归通过。最终包需再次确认该定位行为，不能用修复前的截图作为通过依据。

## 本地资源候选与明确缺口

以下项目在参考客户端本地化资源中有相关文案，或本轮已经确认当前鸿蒙实现未覆盖完整流程。资源位置为 `zh-Hans.lproj/Localizable.strings`、`Content.strings`、`Common.strings`；文案不能单独证明每个入口对当前账号可用。

| 候选功能 / 缺口 | 资源例子或参考范围 | 当前鸿蒙状态 |
| --- | --- | --- |
| 云端草稿同步、冲突比较及跨设备恢复 | `草稿同步`、`查看并比较云端草稿` | 仅本机草稿与草稿列表已实现；没有完整服务器草稿同步和冲突解决 |
| 完整 Markdown 编辑与预览 | 编辑器预览、投票、复杂排版等相关资源 | 已新增主动 Edit/Preview：通过固定官方 `discourse/lib/text.generateCookFunction` 生成排版后交给安全原生渲染；模块不可用明确报错。不是离线完整 Discourse 引擎，也没有全部插入工具与插件交互 |
| 站内聊天 | `频道`、`最近私聊`、`频道线程`、`加入频道` | 未实现频道/私聊/讨论串、加入退出、聊天消息及其未读和附件流程 |
| 投票 | `创建投票`、`撤回投票`、`查看投票者`、`更改投票` | 未实现原生投票创建、投票、排序投票、结果与投票人列表 |
| 完整账户偏好和资料编辑 | `个人设置`、`安全与登录`、`用户与隐私`、`邮件`、`通知时段` | 已有只读资料及部分本机阅读设置；完整资料编辑、登录设备、安全、隐私、邮件、通知时段、分类/标签订阅等仍未完成 |
| 关注与新建私信 | `关注`、`取消关注`、`新建私信`、`邀请成员或群组` | 用户资料当前为只读；没有关注写操作、新建私信、收件人管理、群组私信、归档/退出及私信标签流程 |
| 后台系统推送 | `推送通知`、通知权限/时段/提示音相关资源 | 当前保留前台未读读取与轮询；没有完整鸿蒙后台推送注册、系统通知点击恢复和时段管理 |
| 完整收藏管理 | `收藏备注`、`收藏提醒`、`搜索收藏内容或备注` | 已有帖子收藏/撤销和服务器收藏列表；备注、提醒、自动删除策略、置顶/批量管理、收藏搜索和聊天来源书签尚未完整对齐 |
| 群组和徽章深入页面 | 成员、群组加入退出、徽章获得者等资源 | 四段目录及说明已实现；成员列表、加入申请/退出、徽章获得者和完整群组管理尚未完成 |
| 活动、提醒和日历 | `LINUX DO 活动`、`日历订阅`、`添加到日历` | 未实现完整活动列表、报名、提醒和日历订阅/导出 |
| 搜索的其余对象与高级条件 | 用户、群组、收藏搜索及更广泛筛选资源 | 当前主要是话题/帖子搜索及四种常用条件；其他对象、全部高级条件和服务器最近搜索同步未完成 |
| 阅读的其余扩展操作 | `编辑历史`、`显示翻译`、`复制公式`、`生成分享卡片` | 已新增按服务器权限和前后版本指针的原生只读编辑历史；翻译、完整公式专用处理、分享长图/卡片及其它插件交互仍有缺口 |
| 本机外观与系统能力设置 | `文字大小`、`语言`、`本机强调色`、`紧凑 · 一眼更多`、`识别剪贴板链接`、`本机存储` | 已有主题、沉浸光感、无障碍与部分阅读偏好；独立字号/语言/强调色、紧凑密度、剪贴板识别、完整存储清理和网络统计设置未全部完成 |
| iOS 特有登录与扩展入口 | Apple、通行密钥、设备授权及分享扩展等资源 | 继续使用鸿蒙现有登录/验证流程；没有宣称逐项移植 iOS 的全部认证和系统扩展能力 |
| 管理员、审核与处罚工具 | 举报审核、封禁/禁言、用户合并、授予徽章等资源 | 不属于本轮已完成路径；不能因资源存在就给普通账号展示或执行管理操作 |

## 后续设备验收清单

| 范围 | 需要的实际证据 | 当前状态 |
| --- | --- | --- |
| 启动与主页 | 当前包冷启动、会话恢复、五筛选及分类/标签/排序组合；分页条件和独立位置保持 | 网络恢复后待验 |
| 目录与搜索 | 分类收展和查找、四段数据、标签跳转、全站/话题内搜索、多个楼层命中、最近项重启与账号隔离 | 网络恢复后待验 |
| 阅读与用户资料 | 统一胶囊、真实进度、头像进入公开/隐藏用户资料、返回阅读位置、分享/复制与错误反馈 | 网络恢复后待验 |
| 阅读统计 | 实际可见楼层、弹层/后台暂停、前台恢复、远端阅读统计变化；不把计时器运行本身当作成功 | 网络恢复后待验 |
| 编辑器与草稿 | 原生半模态、键盘、工具、原文引用、草稿继续/删除/重启；发表和举报的离线回执不记为真实发送通过 | 部分依赖真实网络，待验 |
| 设置与材质 | 首未读、默认筛选、沉浸收放、深浅色、高对比、减少动态、按压移动/释放、状态区与手势区避让 | 光感验收进行中，结果待补充 |

## 官方接口依据

服务端权限和返回值继续是数据与操作边界。以下链接用于核对端点和参数，不代替目标站点当前响应的验收。

| 范围 | 官方来源与使用点 |
| --- | --- |
| 首页、分类和标签路由 | [Discourse routes](https://github.com/discourse/discourse/blob/main/config/routes.rb)、[CategoriesController](https://github.com/discourse/discourse/blob/main/app/controllers/categories_controller.rb)、[TagsController](https://github.com/discourse/discourse/blob/main/app/controllers/tags_controller.rb)；`/categories.json`、`/tags.json` 及标签话题路径，目录包含分组标签 |
| 徽章与群组 | [BadgesController](https://github.com/discourse/discourse/blob/main/app/controllers/badges_controller.rb)、[GroupsController](https://github.com/discourse/discourse/blob/main/app/controllers/groups_controller.rb)、[BasicGroupSerializer](https://github.com/discourse/discourse/blob/main/app/serializers/basic_group_serializer.rb)；徽章列表、群组搜索/分页、未公开成员数不补零 |
| 搜索 | [Search 实现](https://github.com/discourse/discourse/blob/main/lib/search.rb)、[官方搜索说明](https://meta.discourse.org/t/searching-for-content-effectively/273328)；`in:title`、数字分类、标签、用户名、排序及 `topic:ID`，按服务器返回的命中楼层导航 |
| 用户资料与统计 | [UsersController](https://github.com/discourse/discourse/blob/main/app/controllers/users_controller.rb)、[HiddenProfileSerializer](https://github.com/discourse/discourse/blob/main/app/serializers/hidden_profile_serializer.rb)、[UserSummarySerializer](https://github.com/discourse/discourse/blob/main/app/serializers/user_summary_serializer.rb)；公开资料读取使用 `skip_track_visit=true`，尊重隐藏资料与统计可见字段 |
| 用户话题和回复 | [UserActionsController](https://github.com/discourse/discourse/blob/main/app/controllers/user_actions_controller.rb)、[UserAction](https://github.com/discourse/discourse/blob/main/app/models/user_action.rb)；`username`、真实 offset/limit，话题类型 4 与回复类型 5 |
| 我的投票 | [Topic Voting 列表控制器](https://github.com/discourse/discourse/blob/main/plugins/discourse-topic-voting/lib/discourse_topic_voting/list_controller_extension.rb)、[投票查询](https://github.com/discourse/discourse/blob/main/plugins/discourse-topic-voting/lib/discourse_topic_voting/topic_query_extension.rb)；`/topics/voted-by/{username}.json?page=` 只包含该用户未归档的话题投票，不代表正文投票历史 |
| 我的方案 | [Solved 路由](https://github.com/discourse/discourse/blob/main/plugins/discourse-solved/config/routes.rb)、[被采纳方案查询](https://github.com/discourse/discourse/blob/main/plugins/discourse-solved/app/controllers/discourse_solved/solved_topics_controller.rb)、[方案序列化](https://github.com/discourse/discourse/blob/main/plugins/discourse-solved/app/serializers/discourse_solved/solved_post_serializer.rb)；`/solution/by_user.json` 的 `user_solved_posts` 为该用户自己的被采纳回复，使用真实 offset/limit 和 post_number |
| 我的 Boost | [Boost 路由](https://github.com/discourse/discourse-boosts/blob/main/config/routes.rb)、[列表服务](https://github.com/discourse/discourse-boosts/blob/main/app/services/discourse_boosts/boost/list.rb)、[目标帖子序列化](https://github.com/discourse/discourse-boosts/blob/main/app/serializers/discourse_boosts/boost_list_post_serializer.rb)、[核心帖子 URL](https://github.com/discourse/discourse/blob/main/app/models/post.rb)；given/received 分端点，20 条一页、before_boost_id 游标，收到的记录有通知可见权限检查；目标楼层从经过同源及话题 ID 核对的规范帖子 URL 读取 |
| 收藏 | [BookmarksController](https://github.com/discourse/discourse/blob/main/app/controllers/bookmarks_controller.rb)；创建传 bookmarkable 类型和 ID，撤销按 bookmark ID，成功回执后更新状态 |
| 通知 | [NotificationsController](https://github.com/discourse/discourse/blob/main/app/controllers/notifications_controller.rb)、[TopicsController](https://github.com/discourse/discourse/blob/main/app/controllers/topics_controller.rb)；历史 offset、未读口径与话题通知级别 |
| 阅读计时 | [TopicsController.timings](https://github.com/discourse/discourse/blob/main/app/controllers/topics_controller.rb)；`/topics/timings` 使用话题时间及以楼层号为键的时间映射，服务器检查话题可见性，成功响应可以没有正文 |
| 举报 | [PostActionsController](https://github.com/discourse/discourse/blob/main/app/controllers/post_actions_controller.rb)；帖子 ID、举报类型与必要说明，仍由服务器检查权限 |

后续追加设备结果时记录日期、包版本/构建及实际步骤和可见结果；保留上述未完成项，直到对应实现与验收均有证据。

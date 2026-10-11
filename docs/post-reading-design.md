# 帖子阅读交互（0.2.8）

0.2.1参考实际手机上的酷安鸿蒙版7.1.1（com.coolapk.hmclient）：通过HDC观察用户Pura X View / HarmonyOS 7 / API 26的真实界面，采用顶部作者信息、自然铺开的正文与底部左侧评论入口、右侧常用动作组。酷安向下长滑时隐藏整条导航、反向滚动复原；本项目结合用户要求保留单按钮收起形态。参考截图只留在本机被忽略的artifacts目录，未复制酷安源码、图标或媒体资源。

0.2.0的阅读层级曾参考[贴吧官方 App Store 页面](https://apps.apple.com/cn/app/id477927812)截图。现有楼中楼、全屏画廊和缩放继续由本项目原生实现，不宣称完整复刻参考客户端。

## 页面层级

- NavDestination隐藏原生标题占位，内容区自绘固定作者/话题双行标题，高度为topInset+56vp；返回按钮与文字放在状态区下方，单层系统背景模糊覆盖标题与状态区。关闭效果或高对比时使用实色。标题返回沿NavPathStack退回，系统返回保留NavDestination语义，看图时优先关闭看图层。
- 主楼保留作者头像、楼主标记、楼层与完整标题，正文满宽。
- 回复连续排列并用细分隔线区分，楼中楼内缩且用浅底呈现，三条预览与展开收起保留真实树形语义。
- 喜欢及回复常用操作在正文后；长按喜欢选择其他回应，更多菜单按真实权限提供编辑、删除、简评及解决方案。
- 底部左侧“写回复”胶囊一次打开半屏编辑面板，右侧HdsActionBar提供楼层、回顶与展开收起控制。工具层的底部避让为4vp+bottomInset，不把操作控件延伸进手势区。关闭、归档或无回复权限时禁用回复，并通过文字和无障碍标签说明状态。

## 窗口、系统区与输入法

EntryAbility先获取主窗口、等待setWindowLayoutFullScreen(true)成功，再loadContent；获取窗口或布局设置失败仍继续加载默认布局，窗口布局失败只记录安全错误码。Index使用@Env(SystemProperties.WINDOW_AVOID_AREA)的vp值计算动态避让：顶部取statusBar/cutout最大值，底部取navigationIndicator/statusBar/cutout最大值，重叠区域不相加；键盘高度单独处理。

Root与Navigation负责全窗口区域扩展，子List/Refresh不重复叠加ignoreLayoutSafeArea，保持继承的100%滚动视口。最新、分类、搜索和我的内容延伸到系统栏后方，首尾内容与控件各按对应边界避让一次。帖子首尾使用contentStartOffset(topInset+56)与contentEndOffset(84+bottomInset)，正文可从固定标题和底部工具背后滚过。

主页面顶部EdgeBackdrop仅对背景做高斯模糊与主题渐隐，backgroundEffect的radius按轻柔/标准/丰富取3/5/7并以局部原生alpha蒙版使模糊与少量主题色一起渐隐，关闭时为0，高对比时为实色。该层只读，不响应触摸或交互光晕。帖子固定标题使用一层backgroundBlurStyle，控件沉浸材质仍由materialFor负责。Root保持100%高度并采用UIContext RESIZE，键盘可见时隐藏主导航。普通设置、分类详情、编辑器、登录、关于、通知和用户页面在其原生NavDestination上避让，原生标题和返回控件一起放到状态区下方；帖子自绘标题只避让一次。

## 阅读动效

使用官方有主按钮的 HdsActionBar 展开/收缩动效。向话题尾部累计滚动32vp后收缩，左侧写回复入口同步淡出并收窄；反向回读16vp后展开，点击浮动主按钮也可手动恢复。浮层不改变列表视口高度，避免收缩时跳动。ReaderGlassSurface包含真实按钮，负责兼容玻璃表面与触点流光；子按钮的ButtonModifier使用Material.empty，HDS自身背板透明且关闭重复模糊。禁用状态只作用于前景按钮，不使材质面消失。开启减少动态效果时移除收缩主按钮，写回复、楼层与回顶保持静态可见。

末尾不保留静态提示区。List启用末端Spring回弹；onWillScroll只有在真实话题加载完成、没有下一页且用户到末尾继续上拉时才跟手显示提示。单纯触底、程序滚动、惯性和回弹不触发提示；松手后使用springMotion回归，保留约3.2秒后淡出。提示带回顶按钮，工具栏也提供回顶，长首楼同样可用。尾部分页模式下重新加载首批楼层；完整首批内容已在列表中时使用scrollEdge(Edge.Top)平滑回到真实顶部，减少动态时直接回顶。看图、换账号、重新加载或离开页面清理提示及定时器。

0.2.1的标题曾使用NavDestinationCustomTitle；0.2.2将标题绘制到全窗口内容上的固定层中。工具栏与动效依据HdsActionBar.d.ets及官方文档[有主按钮的核心操作栏](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ui-design-actionbar-main-buttons)、[滚动组件通用接口](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/ts-container-scrollable-common)和[弹簧曲线](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-spring-curve)。论坛分页、身份与权限继续使用原有实现。

## 主页面导航

首页、分类、搜索和我的使用常驻AdaptiveNavigationBar。向下浏览时，同一个材质表面收拢为当前页图标按钮，默认靠右，并可根据明确的系统握姿侧别调整；反向浏览或点击按钮展开为完整页签。表面使用ReaderGlassSurface兼容玻璃，四个图标节点使用稳定key，收拢与展开共享一个弹簧progress：表面宽高与位置、图标位移和文字透明度连续变化。开启减少动态效果或高对比时主导航保持静态展开。

HdsTabs仅负责主页面内容切换，barHeight设为0。四页保留独立Scroller和原始阅读偏移，只有当前可见主页面的用户滚动参与方向累计；网页认证、子路由或程序滚动不收起主导航。最新/分类的原始初始偏移为负topInset，搜索/我的初始偏移为0；方向判断按实际contentStartOffset归一化，避免把已经向下阅读的负偏移误判成起点。AdaptiveNavigationBar从完整胶囊到单按钮都使用同一个Stack，图标节点持续存在。离开主页面时隐藏主导航，返回时展开并清理方向累计；键盘显示时也隐藏主导航。

离线回归覆盖主导航控制、变形几何、系统区避让、窗口启动、回顶持久控件以及新增刷新、喜欢和握姿政策；它不替代原生视口、手势、输入法及光感验收。版本执行结果见[验收记录](acceptance.md)。Pura X View上的本客户端安装与底栏兼容视觉观察见0.2.7验收记录；不据此新增原生光学或功耗结论。

## 图片

正文图片保留 HTML/原图宽高，解码后用自然尺寸校正。横图、方图与普通竖图占满正文宽度；长图提供顶部大预览和完整查看提示。emoji 和小站点图标仍是行内尺寸，默认“帖子图片”图注不再占空间。

点开图片后采用全窗口黑底，画廊只包含当前楼层原图并去重。图片背景覆盖上下系统区，顶部返回/页码和底部保存/翻图控件分别加topInset与bottomInset避让。单击显隐控件，双击1/2.5倍切换，双指1～5倍缩放；放大时限制平移且关闭翻页手势，原始倍率可左右换图。保存由系统 SaveButton 临时授权触发。

关闭按钮与系统返回仅关闭看图层，恢复打开时的滚动偏移，不重载或跳到首楼；看图期间不触发底层自动加载。换账号清空画廊并取消旧图片回调。网络、凭据及论坛权限边界保持原有实现。

0.2.2 主导航在同一材质Stack内保留独立的只读模糊背板：轻柔/标准/丰富的radius分别为16/24/32，背景染色随主题变化；光感由外层系统沉浸材质提供。模糊不因减少动态效果关闭，收起和展开共用同一个背板。回顶使用持久ActionBarButton模型更新Trace状态，加载完成后恢复可点击。


## 0.2.3 半模态回复

Index使用独立的bindSheet绑定在Navigation层，原有认证Sheet仍绑定Root，避免同一节点覆盖两个Sheet。默认detents为50%/85%，正文话题与NavPathStack保持；键盘出现时选择85%并使用SheetKeyboardAvoidMode.RESIZE_ONLY，半模态期间页面改为OFFSET，原生退场完成后才恢复RESIZE。键盘收起后仍为半模态；用户也可上拉到较高档位。

ComposerPage复用唯一editorContent，半模态分支不含NavDestination；图标工具为图片、附件、表情、粗体、链接，带48vp命中区域和无障碍说明。表情在内容内展开，开启时停止TextArea编辑收起输入法；不再嵌套另一个Sheet。底部仅在没有键盘时避让手势区，普通页面分支不重复加inset。

系统返回、蒙层、下拉和关闭图标统一请求原编辑器的leave保护；未选择保留/丢弃前不清场景，选择附件与提交时拒绝退出。draftLoaded保护首轮恢复，未完成store.get时不将空值写回；同账号同key权限重试保留已有文本/附件。成功回执和明确丢弃都阻止退场重新写空草稿。提交成功递增replyRevision，消费者重新获取正文；编辑同楼也会刷新，普通跳楼继续只定位。

新增半模态状态4项、编辑生命周期4项、正文刷新消费者1项回归；完整离线回归102项。模拟器实际记录与尚未验收边界见acceptance.md，未执行真实发表或上传。


## 0.2.4 阅读操作玻璃层

ReaderGlassSurface是非交互的兄弟背板，真实背景模糊radius按轻柔/标准/丰富为16/24/32，浅色与深色各有独立tint、高光边、阴影颜色。该表面不用systemMaterial，以免系统材质接管手工背景/边框/阴影；原按钮继续使用系统材质承担触摸反馈。关闭效果时实色且无装饰阴影，高对比为实色加1vp主文字色边，减少动态仍保留静态玻璃。

左背板跟随52vp回复胶囊宽度淡出收窄；右背板展开为60vp高、宽度跟随原生168/104vp frame，收起为52vp圆形，始终按native主按钮中心对齐。没有把168vp HDS frame缩到52，也没有扩大交互区域覆盖正文。原按钮的额外shadowStyle设为零半径透明，整体阴影由背板提供。业务、权限、分页、半模态回复和草稿保护未改；102项既有回归通过。


## 0.2.5 单一材质与阴影

对照[沉浸光感指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-immersive-light-sense)和[沉浸光感FAQ](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-immersive-light-sense-faq)：系统材质的applyShadow为true时，自带阴影优先于通用shadow，设置透明shadowStyle无法关闭它；使用系统阴影时不再额外叠加手工阴影。

ReaderGlassSurface改为包含真实控件的材质容器，用无参LocalBuilder保留TopicPage的状态归属。子按钮显式使用Material.empty；材质容器保持默认触摸测试，没有兄弟只读背板或父级点击竞争。正常设备仅systemMaterial承担背景、边缘、阴影与交互；减少动态仍通过既有materialFor关闭交互光效和形变。手工渐变高光已移除。

当前API26模拟器productModel为emulator，支持查询为true且报告EXQUISITE，但实测只设置systemMaterial时没有可见材质。对此模拟器以及不支持材质的设备使用互斥后备：单层backgroundEffect，主题tint、细边缘和radius6px/offsetY2px的外阴影，fill:false；轻柔、关闭和高对比不加装饰阴影。不强行改变系统材质等级，也不把模拟器后备称为真机光学效果。

HdsActionBar保持168/104vp定宽与76vp外框高度；父材质面展开高60vp、收起为52vp圆形。外框高度显式保留，防止窄父容器令原生margin把图标向下推。收起面与主按钮设备实测均为[815,2424,997,2606]。真机光感仍需物理设备复验。


## 0.2.6 触点流光

官方[沉浸光感示例4](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-immersive-light-sense)与[开发者问答](https://developer.huawei.com/consumer/cn/forum/topic/0201220291481156105)将手指跟随效果对应到ImmersiveOptions.lightEffect。lightEffect有效对象启用流光，interactive只控制弹性形变；固定点光源和pressShadow不替代触点跟随。

主导航现在复用ReaderGlassSurface，四个稳定key的真实Button仍由原AdaptiveNavigationBar拥有，无参LocalBuilder保持状态归属。原生路径只有材质容器，不再始终覆盖后备模糊Row；材质只在外观变化时更新缓存，收放与触摸不会持续重建原生材质。子按钮透明、空材质且关闭固定按压色块，标准与丰富使用lightEffect:{}；减少动态只关闭形变与转场，保留直接跟手高光，轻柔、关闭、高对比关闭流光。

模拟器或不支持原生材质时，TouchLightState从同一父容器收到Down/Move/Up/Cancel：用windowX/Y减同窗口vp的Area.globalPosition，锁定首指，连续更新局部触点；第二指不抢光，抬起主指、取消、失效坐标、禁用与几何改变会清空。此为后备视觉，不冒充原生光学渲染。静态毛玻璃背板与裁剪光层分开，投影只在静态背板上，透明渐变末端保留光色RGB，避免生成随触点移动的暗圈。高光位于文字/图标下方，光层HitTest.None，无点击转发、PanGesture或stopPropagation。

依据[官方触摸测试控制](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/ts-universal-attributes-hit-test-behavior)，仅胶囊区域使用BLOCK_HIERARCHY，使子按钮和材质父容器响应，阻止下方内容参与长按拖拽；满屏定位容器仍Transparent，正文可正常滑动。触点状态8项与材质策略5项生产方法fixture新增，共115项；设备观察见acceptance.md。


## 0.2.7 真机透明修复

Pura X View上的对照日志显示isImmersiveMaterialSupported为true、材质创建成功、EXQUISITE、模块DEFAULT；原生路径仍无可见滤镜。临时ENABLE、直接调用工厂以及默认REGULAR材质均未恢复，已恢复DEFAULT并移除探针。不把该结果归因于低算力或V2缓存，也不修改系统沉浸档位。

浮动导航/阅读工具的ReaderGlassSurface现在统一保留兼容表面：背景模糊Row与独立主题染色Row组成一个静态玻璃背板，静态边缘与外阴影不随光源移动。染色采用backgroundColor普通绘制，不依赖backgroundEffect的输出；容器高度由圆角半径的两倍明确给出，保持52/56/60vp原几何。根容器不调用原生systemMaterial，避免可见背景被清除而滤镜没有输出；通用控件的MaterialPolicy没有改动。

标准/丰富触点光效继续由TouchLightState驱动，关闭、高对比和轻柔不启用流光。手机与模拟器使用同一路径，不再按产品型号或能力查询区分可见背板。该兼容视觉不宣称原生折射、硬件光学或功耗等价；后续原生路径需以实机实际绘制验证为前提。


## 0.2.8 首页、阅读与握姿

双击已选中的“最新”将信号交给同一个TopicFeed和Scroller，立即回到原生List顶部边缘，再刷新第0页；contentStartOffset保留真实安全区起点。普通单击页签仍立即切换，忙时多次刷新意图合并，原生Refresh回调不重复取消并重开请求，隐藏期间等待当前页激活。依据[页签点击响应FAQ](https://developer.huawei.com/consumer/cn/doc/doccenter-dev-faq/faqs-performance-20)避免在整个页签切换上加入双击优先互斥识别导致300ms延迟。

置顶话题集中在一个紧凑块：默认显示前三条完整标题，超过三条提供展开全部与收起。保留服务端顺序，每条可进入原帖，普通列表不再重复渲染；这是展示分组，不改变服务器置顶或已读状态。帖子固定标题的文字及空白区域绑定双击回顶，返回按钮独立保留单击返回，正文选择与图片缩放手势不受影响。

对照登录网站的真实简评，简评采用24vp头像与安全富文本组成32vp最小高度的胶囊，多条自然换行，保留行内emoji、链接及服务器删除权限；昵称进入无障碍说明，移除逐条名字列与常驻删除文字。喜欢或取消回应等待服务器返回后更新当前楼层并显示结果提示，失败即时反馈；“我的 → 我点赞过”读取送出的喜欢，通知“收到的赞”只表示收到的互动，二者使用不同服务端口径。

导航与阅读浮层继续共用ReaderGlassSurface的兼容模糊、主题染色、独立跟手高光。对照[官方沉浸光感最佳实践](https://developer.huawei.com/consumer/cn/doc/best-practices/bpta-spatiality-immersive)与[IT之家鸿蒙版9.0官方介绍](https://www.ithome.com/1/003/407.htm)的悬浮底栏、评论弹窗和底部工具栏跟手展示，保持内容可见与前景可读。兼容绘制不冒充已完整实测的原生折射或系统硬件光效。

握姿依据[智感握姿最佳实践](https://developer.huawei.com/consumer/cn/doc/best-practices/bpta-smart-reach)和[获取用户动作指导](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/motion-guidelines)，仅监听系统holdingHandChanged：明确LEFT_HAND_HELD靠左，RIGHT_HAND_HELD靠右；NOT_HELD、BOTH_HANDS_HELD和UNKNOWN_STATUS保留上次明确位置，初始或不支持时默认右边。DETECT_GESTURE为普通级system_grant权限，不申请ACTIVITY_MOTION或弹授权。EntryAbility前台订阅，后台与销毁用原回调取消，过期回调不更新布局；801表示设备不支持并正常降级，模拟器无法测握姿硬件。侧别政策测试与机型实际感知能力分开记录，0.2.8各项设备结果以验收记录为准。

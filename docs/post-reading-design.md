# 帖子阅读交互（0.2.6）

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

使用官方有主按钮的 HdsActionBar 展开/收缩动效。向话题尾部累计滚动32vp后收缩，左侧写回复入口同步淡出并收窄；反向回读16vp后展开，点击浮动主按钮也可手动恢复。浮层不改变列表视口高度，避免收缩时跳动。ReaderGlassSurface包含真实按钮并承担唯一材质，子按钮的ButtonModifier使用Material.empty，HDS自身背板透明且关闭重复模糊。禁用状态只作用于前景按钮，不使材质面消失。开启减少动态效果时移除收缩主按钮，写回复、楼层与回顶保持静态可见。

末尾不保留静态提示区。List启用末端Spring回弹；onWillScroll只有在真实话题加载完成、没有下一页且用户到末尾继续上拉时才跟手显示提示。单纯触底、程序滚动、惯性和回弹不触发提示；松手后使用springMotion回归，保留约3.2秒后淡出。提示带回顶按钮，工具栏也提供回顶，长首楼同样可用。尾部分页模式下重新加载首批楼层；完整首批内容已在列表中时使用scrollEdge(Edge.Top)平滑回到真实顶部，减少动态时直接回顶。看图、换账号、重新加载或离开页面清理提示及定时器。

0.2.1的标题曾使用NavDestinationCustomTitle；0.2.2将标题绘制到全窗口内容上的固定层中。工具栏与动效依据HdsActionBar.d.ets及官方文档[有主按钮的核心操作栏](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ui-design-actionbar-main-buttons)、[滚动组件通用接口](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/ts-container-scrollable-common)和[弹簧曲线](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-spring-curve)。论坛分页、身份与权限继续使用原有实现。

## 主页面导航

首页、分类、搜索和我的使用常驻AdaptiveNavigationBar。向下浏览时，同一个材质表面收拢为右下当前页图标按钮；反向浏览或点击按钮展开为完整页签。表面使用materialFor系统材质，四个图标节点使用稳定key，收拢与展开共享一个弹簧progress：表面宽高与位置、图标位移和文字透明度连续变化。开启减少动态效果或高对比时主导航保持静态展开。

HdsTabs仅负责主页面内容切换，barHeight设为0。四页保留独立Scroller和原始阅读偏移，只有当前可见主页面的用户滚动参与方向累计；网页认证、子路由或程序滚动不收起主导航。最新/分类的原始初始偏移为负topInset，搜索/我的初始偏移为0；方向判断按实际contentStartOffset归一化，避免把已经向下阅读的负偏移误判成起点。AdaptiveNavigationBar从完整胶囊到单按钮都使用同一个Stack，图标节点持续存在。离开主页面时隐藏主导航，返回时展开并清理方向累计；键盘显示时也隐藏主导航。

当前102项离线回归已通过，其中主导航控制5项、变形几何4项、系统区避让4项、窗口启动3项、回顶持久控件3项；离线回归不替代原生视口、手势、输入法及光感验收。版本设备结果见[验收记录](acceptance.md)。Pura X View用于观察酷安，本客户端的设备观察仍来自模拟器，未增加物理设备光感或功耗结论。

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

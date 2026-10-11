import { HdsNavigation, HdsTabs, HdsTabsController } from '@kit.UIDesignKit';
import { SymbolGlyphModifier, window, KeyboardAvoidMode as UIKeyboardAvoidMode } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppearanceSettings, loadAppearanceSettings } from '../models/AppearanceSettings';
import { Category, ProfileSection } from '../models/ForumModels';
import { forumSession } from '../models/ForumSession';
import { forumApi, BrowserRequest, RequestCancellation, BrowserResponse } from '../services/ForumApi';
import { BrowserTransportAdapter } from '../services/BrowserTransportAdapter';
import { allowedLoginNavigation, loginOrigin, loginPageTitle } from '../services/AuthNavigation';
import { TopicScrollPolicy } from '../services/TopicScrollPolicy';
import { handednessState } from '../services/HandednessState';
import { TopicFeed } from '../components/TopicFeed';
import { AdaptiveNavigationBar } from '../components/AdaptiveNavigationBar';
import { EdgeBackdrop } from '../components/EdgeBackdrop';
import { topWindowInset, bottomWindowInset } from '../services/WindowEdgeInsets';
import { CategoriesPage } from './CategoriesPage';
import { SearchPage } from './SearchPage';
import { ProfilePage } from './ProfilePage';
import { ProfileSectionPage } from './ProfileSectionPage';
import { NotificationsPage } from './NotificationsPage';
import { AppearancePage } from './AppearancePage';
import { TopicPage } from './TopicPage';
import { ComposerPage } from './ComposerPage';
import { LoginPage } from './LoginPage';
import { AboutPage } from './AboutPage';

@ObservedV2
class ForumRoute {
  topicId: number = 0;
  @Trace postNumber: number = 1;
  @Trace replyRevision: number = 0;
  replyTo: number = 0;
  postId: number = 0;
  categoryId: number = 0;
  categorySlug: string = '';
  categoryName: string = '';
  section: ProfileSection = ProfileSection.Summary;
  returnTopic: ForumRoute | undefined = undefined;
}

@Entry
@ComponentV2
struct Index {
  @Env(SystemProperties.WINDOW_AVOID_AREA) windowAreas: window.UIEnvWindowAvoidAreaInfoVP;
  @Local appearance: AppearanceSettings = loadAppearanceSettings();
  @Local currentIndex: number = 0;
  @Local paths: NavPathStack = new NavPathStack();
  @Local dataVersion: number = 0;
  @Local latestRefreshSignal: number = 0;
  @Local showBrowser: boolean = false;
  @Local showComposer: boolean = false;
  @Local composerRoute: ForumRoute | undefined = undefined;
  @Local composerDismissSignal: number = 0;
  @Local composerDismissAllowed: boolean = true;
  @Local browserBusy: boolean = false;
  @Local browserError: string = '';
  @Local browserOrigin: string = 'https://linux.do';
  @Local browserTitle: string = 'LINUX DO 登录与验证';
  @Local authPopupController: webview.WebviewController | undefined = undefined;
  @Local showAuthPopup: boolean = false;
  @Local navigationCollapsed: boolean = false;
  @Local mainPageVisible: boolean = true;
  @Local authPopupOrigin: string = '正在打开认证页面';
  @Local authPopupTitle: string = '认证登录';
  @Local authPopupError: string = '';
  private controller: HdsTabsController = new HdsTabsController();
  private readonly latestScroller: Scroller = new Scroller();
  private readonly categoriesScroller: Scroller = new Scroller();
  private readonly searchScroller: Scroller = new Scroller();
  private readonly profileScroller: Scroller = new Scroller();
  private readonly navigationScrollPolicy: TopicScrollPolicy = new TopicScrollPolicy();
  private webController: webview.WebviewController = new webview.WebviewController();
  private browserAdapter: BrowserTransportAdapter = new BrowserTransportAdapter(this.webController);
  private webAttached: boolean = false;
  private initialized: boolean = false;
  private loginOwnerId: number = 0;

  @Computed
  get topInset(): number { return topWindowInset(this.windowAreas); }

  @Computed
  get bottomInset(): number { return bottomWindowInset(this.windowAreas); }

  @Computed
  get keyboardVisible(): boolean { return (this.windowAreas?.keyboard?.bottomRect?.height ?? 0) > 0; }

  private navigationScroller(index: number): Scroller {
    if (index === 1) { return this.categoriesScroller; }
    if (index === 2) { return this.searchScroller; }
    if (index === 3) { return this.profileScroller; }
    return this.latestScroller;
  }

  private setNavigationCollapsed(collapsed: boolean): void {
    if (collapsed && (this.appearance.reduceMotion || this.appearance.highContrast)) { return; }
    if (this.navigationCollapsed === collapsed) { return; }
    this.navigationCollapsed = collapsed;
  }

  private resetNavigation(): void {
    this.navigationScrollPolicy.reset();
    this.setNavigationCollapsed(false);
  }

  private rootVisibilityChanged(visible: boolean): void {
    this.mainPageVisible = visible;
    if (visible) { this.resetNavigation(); }
  }

  private readNavigationScroll(index: number, offset: number, _state: ScrollState, source: ScrollSource): void {
    if (index !== this.currentIndex) { return; }
    const blocked: boolean = !this.mainPageVisible || this.showBrowser || this.paths.size() > 0 ||
      this.appearance.reduceMotion || this.appearance.highContrast;
    const userDriven: boolean = source === ScrollSource.DRAG || source === ScrollSource.FLING ||
      source === ScrollSource.OTHER_USER_INPUT;
    const expanded: boolean | undefined = this.navigationScrollPolicy.update(offset, userDriven,
      this.navigationScroller(index).currentOffset().yOffset + (index < 2 ? this.topInset : 0) <= 1, blocked);
    if (expanded !== undefined) { this.setNavigationCollapsed(!expanded); }
  }

  @Monitor('appearance.reduceMotion', 'appearance.highContrast')
  navigationAccessibilityChanged(): void { this.resetNavigation(); }

  @Monitor('appearance.themeMode')
  themeChanged(): void { this.applyTheme(); }

  private applyTheme(): void {
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const mode: ConfigurationConstant.ColorMode = this.appearance.themeMode === 1 ?
        ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT : this.appearance.themeMode === 2 ?
          ConfigurationConstant.ColorMode.COLOR_MODE_DARK : ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
      context.getApplicationContext().setColorMode(mode);
      // Resolve theme resources instead of fixing a light status bar in dark mode.
      void window.getLastWindow(context).then((main: window.Window): void => {
        const foreground: number = context.resourceManager.getColorSync($r('app.color.text_primary').id);
        const foregroundHex: string = '#' + (foreground >>> 0).toString(16).padStart(8, '0');
        void main.setWindowSystemBarProperties({ statusBarColor: '#00000000', navigationBarColor: '#00000000',
          statusBarContentColor: foregroundHex, navigationBarContentColor: foregroundHex });
      }).catch(() => {});
    } catch {}
  }

  private pushRoute(name: string, route: ForumRoute): void {
    this.mainPageVisible = false;
    this.paths.pushPath({ name: name, param: route });
  }

  private openTopic(id: number, postNumber: number): void {
    if (!Number.isSafeInteger(id) || id <= 0) { return; }
    this.resetNavigation();
    const route: ForumRoute = new ForumRoute();
    route.topicId = id; route.postNumber = Math.max(1, postNumber);
    this.pushRoute('topic', route);
  }

  private compose(topicId: number, replyTo: number, postId: number, returnTopic: ForumRoute): void {
    if (forumSession.user === undefined) { this.openLogin(); return; }
    const route: ForumRoute = new ForumRoute();
    route.topicId = topicId; route.replyTo = replyTo; route.postId = postId;
    route.returnTopic = returnTopic;
    if (this.composerRoute !== undefined) { return; }
    this.composerRoute = route;
    this.setComposerKeyboardMode(true);
    this.composerDismissSignal = 0;
    this.composerDismissAllowed = true;
    this.showComposer = true;
  }

  private setComposerKeyboardMode(active: boolean): void {
    try {
      // The native sheet handles its own keyboard; avoid applying the page RESIZE policy a second time.
      this.getUIContext().setKeyboardAvoidMode(active ? UIKeyboardAvoidMode.OFFSET : UIKeyboardAvoidMode.RESIZE);
    } catch {}
  }

  private requestComposerDismiss(): void {
    if (!this.showComposer) { return; }
    if (!this.composerDismissAllowed) {
      this.getUIContext().getPromptAction().showToast({ message: '请先完成提交或附件选择' });
      return;
    }
    // The editor owns dirty-draft confirmation and the picking/submitting guard.
    this.composerDismissSignal++;
  }

  private closeComposer(): void { this.showComposer = false; }

  private composerDisappeared(): void {
    this.showComposer = false;
    this.composerRoute = undefined;
    this.setComposerKeyboardMode(false);
    this.composerDismissAllowed = true;
    this.composerDismissSignal = 0;
  }

  private composerSubmitted(number: number): void {
    const topic: ForumRoute | undefined = this.composerRoute?.returnTopic;
    if (topic !== undefined) { topic.postNumber = number; topic.replyRevision++; }
  }

  @Builder
  replyEditor() {
    if (this.composerRoute !== undefined) {
      ComposerPage({ presentedAsSheet: true, dismissSignal: this.composerDismissSignal,
        bottomInset: this.keyboardVisible ? 0 : this.bottomInset,
        topicId: this.composerRoute.topicId, replyTo: this.composerRoute.replyTo, postId: this.composerRoute.postId,
        appearance: this.appearance,
        onDismissAllowedChange: (allowed: boolean): void => { this.composerDismissAllowed = allowed; },
        onSubmitted: (number: number): void => { this.composerSubmitted(number); },
        onDone: (): void => { this.closeComposer(); } })
    }
  }

  private openLogin(): void {
    this.resetNavigation();
    this.loginOwnerId = forumSession.user?.id || 0;
    this.pushRoute('login', new ForumRoute());
  }
  private openNotifications(): void {
    if (forumSession.user === undefined) { this.openLogin(); return; }
    this.resetNavigation();
    this.pushRoute('notifications', new ForumRoute());
  }
  private openCategory(category: Category): void {
    this.resetNavigation();
    const route: ForumRoute = new ForumRoute();
    route.categoryId = category.id; route.categorySlug = category.slug; route.categoryName = category.name;
    this.pushRoute('category', route);
  }
  private openProfile(section: ProfileSection): void {
    if (section === ProfileSection.Notifications) { this.openNotifications(); return; }
    this.resetNavigation();
    const route: ForumRoute = new ForumRoute(); route.section = section;
    this.pushRoute('profile', route);
  }

  private authenticated(): void {
    if (this.loginOwnerId !== (forumSession.user?.id || 0)) { this.paths.clear(); }
    else { this.paths.pop(); }
    this.dataVersion++;
  }

  private openBrowser(): void {
    if (!this.webAttached) { this.getUIContext().getPromptAction().showToast({ message: '网页登录正在准备，请稍后重试' }); return; }
    this.resetNavigation();
    forumApi.setBrowserTransportEnabled(false);
    forumSession.stopPolling();
    this.browserError = ''; this.showBrowser = true;
    this.browserOrigin = 'https://linux.do'; this.browserTitle = 'LINUX DO 登录与验证';
    this.webController.loadUrl('https://linux.do/login');
  }

  private async finishBrowser(): Promise<void> {
    if (this.browserBusy) { return; }
    this.browserBusy = true; this.browserError = '';
    const previousUserId: number = forumSession.user?.id || 0;
    try {
      if (!/^https:\/\/linux\.do(?::443)?(?:[/?#]|$)/.test(this.webController.getUrl())) {
        this.browserError = '请先打开 LINUX DO 的网页完成登录或验证。'; return;
      }
      forumApi.setBrowserTransportEnabled(true);
      await forumSession.refresh();
      if (forumSession.lastError) { this.browserError = forumSession.lastError; return; }
      await webview.WebCookieManager.saveCookieAsync();
      this.showBrowser = false;
      forumSession.startPolling();
      this.dataVersion++;
      const currentUserId: number = forumSession.user?.id || 0;
      if (previousUserId !== currentUserId) { this.paths.clear(); }
      else if (this.paths.getAllPathName().slice(-1)[0] === 'login' && currentUserId > 0) { this.paths.pop(); }
    } catch { this.browserError = '尚未确认网页会话，请完成页面中的验证后再试。'; }
    finally { this.browserBusy = false; }
  }

  private closeAuthPopup(): void {
    this.showAuthPopup = false;
    this.authPopupController = undefined;
    this.authPopupError = '';
  }

  private createAuthPopup(event: OnWindowNewEvent): void {
    const source: string = loginOrigin(this.webController.getUrl());
    const allowed: boolean = allowedLoginNavigation(event.targetUrl, true);
    if (!this.showBrowser || !source || this.authPopupController !== undefined || !allowed) {
      event.handler.setWebController(null);
      if (!allowed) { this.browserError = '此认证窗口地址暂不支持。'; }
      return;
    }
    // Bind the native window itself so POST bodies, window.name and opener survive.
    // Do not convert this event into loadUrl(targetUrl).
    const child: webview.WebviewController = new webview.WebviewController();
    event.handler.setWebController(child);
    this.authPopupController = child;
    this.authPopupOrigin = loginOrigin(event.targetUrl) || '正在打开认证页面';
    this.authPopupTitle = loginPageTitle(event.targetUrl);
    this.authPopupError = '';
    this.showAuthPopup = true;
    hilog.info(0x0000, 'LinuxDoAuth', 'Visible authentication window opened');
  }

  @Builder
  authenticationWindow() {
    if (this.authPopupController !== undefined) {
      Column({ space: 8 }) {
        Row({ space: 12 }) {
          Column({ space: 4 }) {
            Text(this.authPopupTitle).fontSize(20).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
            Text(this.authPopupOrigin).fontSize(13).fontColor($r('app.color.text_secondary'))
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Button('关闭', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontColor($r('app.color.accent'))
            .onClick(() => { this.closeAuthPopup(); })
        }.width('100%').padding({ left: 20, right: 12, top: 12, bottom: 8 })
        Web({ src: '', controller: this.authPopupController }).width('100%').layoutWeight(1)
          .javaScriptAccess(true).domStorageAccess(true).fileAccess(false).mixedMode(MixedMode.None)
          .multiWindowAccess(false)
          .onPageBegin((event: OnPageBeginEvent) => {
            const origin: string = loginOrigin(event.url);
            if (origin) { this.authPopupOrigin = origin; this.authPopupTitle = loginPageTitle(event.url); }
          })
          .onLoadIntercept((event: OnLoadInterceptEvent) => {
            if (!event.data.isMainFrame()) { return false; }
            const allowed: boolean = allowedLoginNavigation(event.data.getRequestUrl(), true);
            if (!allowed) { this.authPopupError = '认证窗口无法打开该地址。'; }
            return !allowed;
          })
          .onWindowExit(() => { this.closeAuthPopup(); })
        if (this.authPopupError) {
          Text(this.authPopupError).fontSize(13).fontColor($r('app.color.error')).padding(12)
        }
      }.width('100%').height('100%').backgroundColor($r('app.color.page_background'))
    }
  }

  onPageShow(): void { forumSession.startPolling(); }
  onPageHide(): void { forumSession.stopPolling(); }
  aboutToDisappear(): void {
    forumSession.dispose(); forumApi.setBrowserTransportEnabled(false); forumApi.dispose(); this.browserAdapter.dispose();
  }

  @Builder
  destination(name: string, param: Object) {
    if (name === 'topic') {
      TopicPage({ topicId: (param as ForumRoute).topicId,
        postNumber: (param as ForumRoute).postNumber, reloadSignal: (param as ForumRoute).replyRevision,
        topInset: this.topInset, bottomInset: this.bottomInset,
        onBack: (): void => { this.paths.pop(); },
        appearance: this.appearance, treeView: this.appearance.treeView,
        onCompose: (topicId: number, replyTo: number, postId: number): void => { this.compose(topicId, replyTo, postId, param as ForumRoute); },
        onOpenTopic: (id: number, number: number): void => { this.openTopic(id, number); }, onLogin: (): void => { this.openLogin(); } })
    } else if (name === 'composer') {
      ComposerPage({ topInset: this.topInset, bottomInset: this.bottomInset, topicId: (param as ForumRoute).topicId, replyTo: (param as ForumRoute).replyTo,
        postId: (param as ForumRoute).postId, appearance: this.appearance,
        onSubmitted: (number: number): void => {
          const route: ForumRoute = param as ForumRoute;
          if (route.returnTopic !== undefined) { route.returnTopic.postNumber = number; }
        },
        onDone: (): void => { this.paths.pop(); } })
    } else if (name === 'category') {
      NavDestination() {
        TopicFeed({ title: (param as ForumRoute).categoryName, categoryId: (param as ForumRoute).categoryId,
          categorySlug: (param as ForumRoute).categorySlug, appearance: this.appearance,
          bottomInset: this.bottomInset,
          reloadSignal: this.dataVersion + forumSession.revision,
          onOpenTopic: (id: number, number: number): void => { this.openTopic(id, number); }, onVerify: (): void => { this.openBrowser(); } })
      }.title((param as ForumRoute).categoryName).padding({ top: this.topInset }).backgroundColor($r('app.color.page_background'))
    } else if (name === 'notifications') {
      NotificationsPage({ topInset: this.topInset, bottomInset: this.bottomInset, onOpenTopic: (id: number, number: number): void => { this.openTopic(id, number); }, onLogin: (): void => { this.openLogin(); } })
    } else if (name === 'profile') {
      ProfileSectionPage({ topInset: this.topInset, bottomInset: this.bottomInset, section: (param as ForumRoute).section,
        onOpenTopic: (id: number, number: number): void => { this.openTopic(id, number); }, onLogin: (): void => { this.openLogin(); } })
    } else if (name === 'settings') {
      NavDestination() { AppearancePage({ appearance: this.appearance }) }.title('设置').padding({ top: this.topInset, bottom: this.bottomInset }).backgroundColor($r('app.color.page_background'))
    } else if (name === 'login') {
      LoginPage({ topInset: this.topInset, bottomInset: this.bottomInset, onAuthenticated: (): void => { this.authenticated(); }, onBrowser: (): void => { this.openBrowser(); } })
    } else if (name === 'about') {
      AboutPage({ topInset: this.topInset, bottomInset: this.bottomInset, onVerify: (): void => { this.openBrowser(); } })
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      HdsNavigation(this.paths) {
        HdsTabs({ controller: this.controller, index: this.currentIndex }) {
          TabContent() {
            TopicFeed({ appearance: this.appearance, reloadSignal: this.dataVersion + forumSession.revision,
              refreshTopSignal: this.latestRefreshSignal,
              topInset: this.topInset, bottomInset: this.bottomInset, immersiveTop: true,
              listScroller: this.latestScroller,
              onReadScroll: (offset: number, state: ScrollState, source: ScrollSource): void => {
                this.readNavigationScroll(0, offset, state, source);
              },
              active: this.currentIndex === 0 && !this.showBrowser && this.paths.size() === 0,
              onOpenTopic: (id: number, number: number): void => { this.openTopic(id, number); },
              onVerify: (): void => { this.openBrowser(); }, onNotifications: (): void => { this.openNotifications(); } })
          }.height('100%')
            .tabBar(new BottomTabBarStyle({ normal: new SymbolGlyphModifier($r('sys.symbol.house')) }, '最新'))
          TabContent() {
            CategoriesPage({ reloadSignal: this.dataVersion + forumSession.revision,
              topInset: this.topInset, bottomInset: this.bottomInset,
              listScroller: this.categoriesScroller,
              onReadScroll: (offset: number, state: ScrollState, source: ScrollSource): void => {
                this.readNavigationScroll(1, offset, state, source);
              },
              onOpenCategory: (category: Category): void => { this.openCategory(category); }, onVerify: (): void => { this.openBrowser(); } })
          }.height('100%')
            .tabBar(new BottomTabBarStyle({ normal: new SymbolGlyphModifier($r('sys.symbol.square_grid_2x2')) }, '分类'))
          TabContent() {
            SearchPage({ reloadSignal: this.dataVersion + forumSession.revision,
              topInset: this.topInset, bottomInset: this.bottomInset,
              listScroller: this.searchScroller,
              onReadScroll: (offset: number, state: ScrollState, source: ScrollSource): void => {
                this.readNavigationScroll(2, offset, state, source);
              },
              onOpenTopic: (id: number, number: number): void => { this.openTopic(id, number); }, onVerify: (): void => { this.openBrowser(); } })
          }.height('100%')
            .tabBar(new BottomTabBarStyle({ normal: new SymbolGlyphModifier($r('sys.symbol.magnifyingglass')) }, '搜索'))
          TabContent() {
            ProfilePage({ listScroller: this.profileScroller,
              topInset: this.topInset, bottomInset: this.bottomInset,
              onReadScroll: (offset: number, state: ScrollState, source: ScrollSource): void => {
                this.readNavigationScroll(3, offset, state, source);
              },
              onLogin: (): void => { this.openLogin(); }, onOpenSection: (section: ProfileSection): void => { this.openProfile(section); },
              onSettings: (): void => { this.resetNavigation(); this.pushRoute('settings', new ForumRoute()); },
              onDiagnostics: (): void => { this.resetNavigation(); this.pushRoute('about', new ForumRoute()); },
              onLoggedOut: (): void => { this.paths.clear(); this.dataVersion++; } })
          }.height('100%')
            .tabBar(new BottomTabBarStyle({ normal: new SymbolGlyphModifier($r('sys.symbol.person')) }, '我的'))
        }.width('100%').height('100%')
          .barPosition(BarPosition.End).barOverlap(true).vertical(false).barHeight(0)
          .barBackgroundBlurStyle(BlurStyle.NONE).barBackgroundColor(Color.Transparent)
          .animationDuration(this.appearance.reduceMotion ? 0 : 240).onChange((index: number) => {
            this.currentIndex = index;
            this.resetNavigation();
          })
      }.width('100%').height('100%')
        .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
        .mode(NavigationMode.Stack).hideTitleBar(true).hideToolBar(true)
        .navDestination(this.destination).backgroundColor($r('app.color.page_background'))
        .onNavBarStateChange((visible: boolean): void => { this.rootVisibilityChanged(visible); })
        .bindSheet(this.showComposer, this.replyEditor, {
          detents: ['50%', '85%'], detentSelection: this.keyboardVisible ? '85%' : '50%',
          preferType: SheetType.BOTTOM, dragBar: true, showClose: false,
          enableOutsideInteractive: false, backgroundColor: $r('app.color.surface'),
          blurStyle: this.appearance.effectLevel === 0 || this.appearance.highContrast ? BlurStyle.NONE : BlurStyle.COMPONENT_THIN,
          keyboardAvoidMode: SheetKeyboardAvoidMode.RESIZE_ONLY,
          onWillDismiss: (_action: DismissSheetAction): void => { this.requestComposerDismiss(); },
          onDisappear: (): void => { this.composerDisappeared(); }
        })

      EdgeBackdrop({ heightVp: this.topInset, appearance: this.appearance,
        visible: this.mainPageVisible && !this.showBrowser })
        .width('100%').height(this.topInset).position({ x: 0, y: 0 })
        .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP])
        .hitTestBehavior(HitTestMode.None).accessibilityLevel('no-hide-descendants').zIndex(1)

      AdaptiveNavigationBar({ currentIndex: this.currentIndex, collapsed: this.navigationCollapsed,
        sideLeft: handednessState.sideLeft,
        appearance: this.appearance,
        bottomInset: this.bottomInset,
        onSelect: (index: number): void => {
          this.resetNavigation(); this.currentIndex = index; this.controller.changeIndex(index);
        },
        onLatestDoubleTap: (): void => {
          this.resetNavigation();
          this.latestRefreshSignal++;
        },
        onExpand: (): void => { this.resetNavigation(); } })
        .visibility(this.mainPageVisible && !this.showBrowser && !this.keyboardVisible ? Visibility.Visible : Visibility.Hidden)
        .height('100%')
        .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
        .hitTestBehavior(HitTestMode.Transparent).zIndex(2)

      Column({ space: 8 }) {
        Row({ space: 12 }) {
          Button('返回', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontColor($r('app.color.accent'))
            .onClick(() => { this.showBrowser = false; forumSession.startPolling(); })
          Column({ space: 3 }) {
            Text(this.browserTitle).fontSize(17).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
            Text(this.browserOrigin).fontSize(12).fontColor($r('app.color.text_secondary'))
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        }.width('100%').padding({ left: 10, right: 16 })
        Web({ src: 'about:blank', controller: this.webController }).width('100%').layoutWeight(1)
          .javaScriptAccess(true).domStorageAccess(true).fileAccess(false).mixedMode(MixedMode.None)
          .multiWindowAccess(this.showBrowser).allowWindowOpenMethod(this.showBrowser)
          .onWindowNew((event: OnWindowNewEvent) => { this.createAuthPopup(event); })
          .javaScriptProxy({ object: this.browserAdapter.bridge, name: this.browserAdapter.bridgeName,
            methodList: ['receive'], controller: this.webController, permission: this.browserAdapter.permission })
          .onControllerAttached(() => {
            this.webAttached = true;
            forumApi.setUserAgent(webview.WebviewController.getDefaultUserAgent());
            forumApi.registerBrowserTransport((request: BrowserRequest, cancellation?: RequestCancellation): Promise<BrowserResponse> =>
              this.browserAdapter.request(request, cancellation));
          })
          .onPageBegin((event: OnPageBeginEvent) => {
            const origin: string = loginOrigin(event.url);
            if (origin) { this.browserOrigin = origin; this.browserTitle = loginPageTitle(event.url); }
          })
          .onLoadIntercept((event: OnLoadInterceptEvent) => {
            if (!event.data.isMainFrame()) { return false; }
            const url: string = event.data.getRequestUrl();
            const allowed: boolean = allowedLoginNavigation(url, true);
            if (!allowed) { this.browserError = '此认证地址暂不支持在应用中打开。'; }
            return !allowed;
          })
        if (this.browserError) {
          Text(this.browserError).fontSize(13).fontColor($r('app.color.error')).lineHeight(20).width('100%').padding(12)
        }
        Button(this.browserBusy ? '正在确认会话' : '已完成登录或验证，返回应用', { type: ButtonType.Capsule })
          .height(48).width('92%').margin({ bottom: 12 }).enabled(!this.browserBusy)
          .backgroundColor($r('app.color.accent')).fontColor($r('app.color.on_accent')).onClick(() => { void this.finishBrowser(); })
      }.width('100%').height('100%').backgroundColor($r('app.color.page_background'))
        .padding({ top: this.topInset })
        .visibility(this.showBrowser ? Visibility.Visible : Visibility.Hidden).zIndex(this.showBrowser ? 10 : -1)
    }.width('100%').height('100%')
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
      .id('app_window')
      .backgroundColor($r('app.color.page_background'))
      .bindSheet(this.showAuthPopup, this.authenticationWindow, {
        height: SheetSize.LARGE, showClose: false, dragBar: true,
        onDisappear: (): void => { this.closeAuthPopup(); }
      })
      .onAppear(() => {
        this.getUIContext().setKeyboardAvoidMode(UIKeyboardAvoidMode.RESIZE);
        this.applyTheme();
        if (!this.initialized) { this.initialized = true; void forumSession.refresh(); }
        forumSession.startPolling();
      })
  }
}

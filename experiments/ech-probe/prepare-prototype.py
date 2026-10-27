#!/usr/bin/env python3
"""Make an ignored app copy for native ECH checks without changing the normal app build."""
import json
import shutil
import subprocess
import sys
from pathlib import Path

probe = Path(__file__).resolve().parent
project = probe.parent.parent
output = project / 'artifacts/ech-native-20261018/prototype-app'
rust_lib = project / 'artifacts/ech-native-20261018/cargo-target/aarch64-unknown-linux-ohos/release/libech_probe_core.a'
if not rust_lib.is_file():
    raise SystemExit('Run build-ohos.sh --lib first')
shutil.copytree(project / 'app', output, dirs_exist_ok=True,
                ignore=shutil.ignore_patterns('build', 'oh_modules', 'node_modules', '.hvigor', '.idea'))
entry = output / 'entry'
profile = entry / 'build-profile.json5'
text = profile.read_text()
anchor = '"buildOption": {'
assert text.count(anchor) == 1
text = text.replace(anchor, anchor + '\n    "externalNativeOptions": ' + json.dumps({
    'path': './src/main/cpp/CMakeLists.txt',
    'arguments': '-DECH_RUST_LIB=' + str(rust_lib),
    'abiFilters': ['arm64-v8a'],
}) + ',', 1)
profile.write_text(text)
shutil.copytree(probe / 'native', entry / 'src/main/cpp', dirs_exist_ok=True)
package_path = entry / 'oh-package.json5'
package = json.loads(package_path.read_text())
package['dependencies']['libechprobe.so'] = 'file:./src/main/cpp/types/libechprobe'
package_path.write_text(json.dumps(package, indent=2) + '\n')
pages = entry / 'src/main/ets/pages'
shutil.copy2(probe / 'NativeEchProbePage.ets', pages / 'NativeEchProbePage.ets')
index_path = pages / 'Index.ets'
index = index_path.read_text()
index = index.replace("import { ConnectionProbePage } from './ConnectionProbePage';", "import { ConnectionProbePage } from './ConnectionProbePage';\nimport { NativeEchProbePage } from './NativeEchProbePage';")
index = index.replace("} else if (name === 'connection-probe') {\n      ConnectionProbePage({ topInset: this.topInset, bottomInset: this.bottomInset })", "} else if (name === 'connection-probe') {\n      NativeEchProbePage({ topInset: this.topInset, bottomInset: this.bottomInset, onWebCheck: (): void => { this.pushRoute('web-ech-probe', new ForumRoute()); } })\n    } else if (name === 'web-ech-probe') {\n      ConnectionProbePage({ topInset: this.topInset, bottomInset: this.bottomInset })")
trial = '--browser-trial' in sys.argv
trial_doh = 'https://edge.1molchuan.top/linuxdo' if '--edge-doh' in sys.argv else 'https://kudo.ddd.oaifree.com/query-dns'
trial_doh_label = 'edge 社区 DNS' if '--edge-doh' in sys.argv else 'kudo 社区 DNS'
if trial:
    index = index.replace("import { ConnectionProbePage } from './ConnectionProbePage';",
                          "import { ConnectionProbePage } from './ConnectionProbePage';\nimport { connectionTraceSummary } from '../services/ConnectionProbe';")
    # Load the engine and configure DNS before the normal browser profile is created.
    # API26 logs a null engine and silently ignores setHttpDns before initialization.
    ability_path = entry / 'src/main/ets/entryability/EntryAbility.ets'
    ability = ability_path.read_text()
    ability = "import { webview } from '@kit.ArkWeb';\n" + ability
    anchor = '  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {'
    assert ability.count(anchor) == 1
    ability = ability.replace(anchor, anchor + '''
    try {
      webview.WebviewController.initializeWebEngine();
      webview.WebviewController.setHttpDns(webview.SecureDnsMode.SECURE_ONLY, '__TRIAL_DOH__');
      hilog.info(DOMAIN, 'LinuxDoWebTrial', 'DNS configured before Web creation');
    } catch (error) {
      const code: number = (error as BusinessError).code;
      hilog.warn(DOMAIN, 'LinuxDoWebTrial', 'DNS configuration failed code=%{public}d', Number.isFinite(code) ? code : -1);
    }
'''.replace('__TRIAL_DOH__', trial_doh))
    ability_path.write_text(ability)
    anchor = '  private openBrowser(): void {'
    index = index.replace(anchor, '''  private async checkTrialBrowserTrace(): Promise<void> {
    try {
      const response: BrowserResponse = await this.browserAdapter.request({
        path: '/cdn-cgi/trace', method: 'GET', body: '', csrf: ''
      });
      const summary: string = response.status === 200 ? connectionTraceSummary(response.body) : `HTTP ${response.status}`;
      hilog.info(0x0000, 'LinuxDoWebTrial', 'Session trace %{public}s', summary);
    } catch { hilog.info(0x0000, 'LinuxDoWebTrial', 'Session trace unavailable'); }
  }

  private async restoreBrowserTrial(): Promise<void> {
    const token: RequestCancellation = new RequestCancellation();
    const recovered: boolean = await forumApi.recoverReadSession(token);
    hilog.info(0x0000, 'LinuxDoWebTrial', 'Automatic recovery=%{public}d', recovered ? 1 : 0);
    if (recovered) {
      void this.checkTrialBrowserTrace();
      await forumSession.refresh();
      this.dataVersion++;
    }
  }

''' + anchor)
    anchor = '      this.showBrowser = false;\n      forumSession.startPolling();'
    assert index.count(anchor) == 1
    index = index.replace(anchor, '      void this.checkTrialBrowserTrace();\n' + anchor)
    anchor = '            this.webAttached = true;'
    assert index.count(anchor) == 1
    index = index.replace(anchor, anchor + "\n            hilog.info(0x0000, 'LinuxDoWebTrial', 'Web attached');")
    anchor = '              return this.browserAdapter.recoverSession(cancellation);\n            });'
    assert index.count(anchor) == 1
    index = index.replace(anchor, anchor + '\n            setTimeout((): void => { void this.restoreBrowserTrial(); }, 0);')
    api_path = entry / 'src/main/ets/services/ForumApi.ets'
    api = api_path.read_text()
    api = "import { hilog } from '@kit.PerformanceAnalysisKit';\n" + api
    anchor = '      const recoveredBeforeRequest: number = this.recoveryVersion;'
    assert api.count(anchor) == 1
    api = api.replace(anchor, '''      if (!this.browserTransportEnabled && this.browserRecovery && spec.method === http.RequestMethod.GET) {
        await this.recoverReadSession(cancellation);
        this.ensureSessionGeneration(generation);
        if (cancellation.isCancelled) { throw cancelledError(); }
      }
''' + anchor)
    anchor = '      const response: BrowserResponse = this.browserTransportEnabled'
    assert api.count(anchor) == 1
    api = api.replace(anchor, '''      const usedBrowser: boolean = this.browserTransportEnabled && this.browserTransport !== undefined && !spec.multipart;
''' + anchor)
    anchor = '      this.checkResponse(response, writing);'
    api = api.replace(anchor, '''      hilog.info(0x0000, 'LinuxDoWebTrial', 'browser=%{public}d read=%{public}d status=%{public}d bytes=%{public}d',
        usedBrowser ? 1 : 0, writing ? 0 : 1, response.status, response.body.length);
''' + anchor)
    api_path.write_text(api)
    # Detailed media diagnostics are opt-in and omitted from distributed trial builds.
    if '--media-diagnostics' in sys.argv:
        media_path = entry / 'src/main/ets/services/ForumMedia.ets'
        media = "import { hilog } from '@kit.PerformanceAnalysisKit';\n" + media_path.read_text()
        anchor = '  ensureScope(scope, cancellation);\n  if (forumApi.canUseBrowserMedia()'
        assert media.count(anchor) == 1
        media = media.replace(anchor, '''  hilog.info(0x0000, 'LinuxDoMediaTrial', 'Image host=%{public}s browserReady=%{public}d',
        parsed.hostname, forumApi.canUseBrowserMedia() ? 1 : 0);
    ''' + anchor)
        anchor = '    return checkMediaBytes(response.bytes, response.status);'
        assert media.count(anchor) == 1
        media = media.replace(anchor, '''    hilog.info(0x0000, 'LinuxDoMediaTrial', 'Image browser=1 status=%{public}d bytes=%{public}d',
          response.status, response.bytes.byteLength);
    ''' + anchor)
        media_path.write_text(media)
        image_path = entry / 'src/main/ets/components/NativeForumImage.ets'
        image = "import { hilog } from '@kit.PerformanceAnalysisKit';\n" + image_path.read_text()
        image = image.replace('interface LoadedImageIdentity {', 'interface AnimationKindProbe { typeName?: string; }\n\ninterface LoadedImageIdentity {')
        anchor = '    } catch { /* Keep the ordinary image path when animation metadata is unavailable. */ }'
        assert image.count(anchor) == 1
        image = image.replace(anchor, '''    } catch (error) {
          hilog.info(0x0000, 'LinuxDoMediaTrial', 'Animation source failed code=%{public}d',
            (error as BusinessError).code || 0);
        }''')
        image = "import { BusinessError } from '@kit.BasicServicesKit';\n" + image
        anchor = '        this.animatedSource = animation;'
        assert image.count(anchor) == 1
        image = image.replace(anchor, '''        if (/\\.(gif|webp)(?:[?#]|$)/i.test(url)) {
              hilog.info(0x0000, 'LinuxDoMediaTrial', 'Avatar file=%{public}s animated=%{public}d',
                url.split(/[?#]/)[0].split('/').pop() || '', animation ? 1 : 0);
              if (animation) {
                hilog.info(0x0000, 'LinuxDoMediaTrial', 'Descriptor type=%{public}s',
                  ((animation as Object) as AnimationKindProbe).typeName || 'missing');
              }
            }
    ''' + anchor)
        anchor = '      const frames: number = await source.getFrameCount();'
        assert image.count(anchor) == 1
        image = image.replace(anchor, anchor + '''
          hilog.info(0x0000, 'LinuxDoMediaTrial', 'Animation metadata frames=%{public}d cancelled=%{public}d',
            frames, cancellation.isCancelled ? 1 : 0);
    ''')
        anchor = '    const status: AnimationStatus = controller.getStatus();'
        assert image.count(anchor) == 1
        image = image.replace(anchor, anchor + '''
        if (/\\.(gif|webp)(?:[?#]|$)/i.test(identity.source)) {
          hilog.info(0x0000, 'LinuxDoMediaTrial', 'Avatar visibility=%{public}d status=%{public}d file=%{public}s',
            visible ? 1 : 0, status, identity.source.split(/[?#]/)[0].split('/').pop() || '');
        }
    ''')
        anchor = '    if (!this.matchesDecodedImage(identity)) { return; }\n    const controller = this.animatedSource?.getAnimationController();'
        assert image.count(anchor) == 1
        image = image.replace(anchor, '''    if (/\\.(gif|webp)(?:[?#]|$)/i.test(identity.source)) {
          hilog.info(0x0000, 'LinuxDoMediaTrial', 'Animation callback visible=%{public}d current=%{public}d descriptor=%{public}d',
            visible ? 1 : 0, this.matchesDecodedImage(identity) ? 1 : 0, this.animatedSource ? 1 : 0);
        }
    ''' + anchor)
        anchor = '  private naturalSize(width: number, height: number, identity: LoadedImageIdentity): void {'
        assert image.count(anchor) == 1
        image = image.replace(anchor, '''  private auditedAnimations: Set<string> = new Set<string>();
      private async auditAnimation(identity: LoadedImageIdentity): Promise<void> {
        if (this.auditedAnimations.has(identity.uri) || !/\\.(gif|webp)(?:[?#]|$)/i.test(identity.source) ||
          !this.matchesDecodedImage(identity)) { return; }
        this.auditedAnimations.add(identity.uri);
        let source: image.ImageSource | undefined = undefined;
        try {
          source = image.createImageSource(new fileUri.FileUri(identity.uri).path);
          const count: number = await source.getFrameCount();
          hilog.info(0x0000, 'LinuxDoMediaTrial', 'Animation avatar=%{public}d frames=%{public}d',
            identity.source.indexOf('/user_avatar/') >= 0 ? 1 : 0, count);
        } catch { hilog.info(0x0000, 'LinuxDoMediaTrial', 'Animation frame audit unavailable'); }
        finally { if (source) { try { await source.release(); } catch { /* Diagnostic resource cleanup only. */ } } }
      }

    ''' + anchor)
        anchor = '      this.onNaturalSize(width, height);'
        assert image.count(anchor) == 1
        image = image.replace(anchor, '''      hilog.info(0x0000, 'LinuxDoMediaTrial', 'Image decoded width=%{public}d height=%{public}d', width, height);
          if (/^(hugs|bili_057) 表情$/.test(this.accessibleLabel)) {
            hilog.info(0x0000, 'LinuxDoMediaTrial', 'Reaction image=%{public}s source=%{public}s',
              this.accessibleLabel.split(' ')[0], identity.source.split(/[?#]/)[0].slice(0, 300));
          }
          void this.auditAnimation(identity);
    ''' + anchor)
        image_path.write_text(image)
        wire_path = entry / 'src/main/ets/services/ForumWire.ets'
        wire = "import { hilog } from '@kit.PerformanceAnalysisKit';\n" + wire_path.read_text()
        anchor = 'export function postFromWire(value: PostWire): Post {'
        assert wire.count(anchor) == 1
        wire = wire.replace(anchor, anchor + '''
      if (value.id === 23547866) {
        hilog.info(0x0000, 'LinuxDoMediaTrial', 'Avatar sample metadata=%{public}s template=%{public}s',
          text(value.animated_avatar).split(/[?#]/)[0].split('.').pop() || '',
          text(value.avatar_template).split(/[?#]/)[0].split('/').pop() || '');
      }
    ''')
        wire_path.write_text(wire)
    adapter_path = entry / 'src/main/ets/services/BrowserTransportAdapter.ets'
    adapter = "import { hilog } from '@kit.PerformanceAnalysisKit';\n" + adapter_path.read_text()
    anchor = '  async recoverSession(cancellation: RequestCancellation): Promise<boolean> {'
    assert adapter.count(anchor) == 1
    adapter = adapter.replace(anchor, anchor + "\n    hilog.info(0x0000, 'LinuxDoWebTrial', 'Recovery entered');")
    anchor = '      try { response = await this.probeSession(cancellation, deadline); }'
    assert adapter.count(anchor) == 1
    adapter = adapter.replace(anchor, "      hilog.info(0x0000, 'LinuxDoWebTrial', 'CSRF probe started');\n" + anchor)
    anchor = '      if (response.status === 200 && !(response.headers'
    adapter = adapter.replace(anchor, "      hilog.info(0x0000, 'LinuxDoWebTrial', 'CSRF status=%{public}d', response.status);\n" + anchor)
    anchor = '      catch (error) {\n        if (this.disposed || cancellation.isCancelled'
    assert adapter.count(anchor) == 1
    adapter = adapter.replace(anchor, '''      catch (error) {
        hilog.info(0x0000, 'LinuxDoWebTrial', 'CSRF failed kind=%{public}s status=%{public}d cancelled=%{public}d',
          error instanceof ForumApiError ? error.kind : 'unknown',
          error instanceof ForumApiError ? error.status : 0, cancellation.isCancelled ? 1 : 0);
        if (this.disposed || cancellation.isCancelled''')
    anchor = '        retriedNavigation = true;'
    assert adapter.count(anchor) == 1
    adapter = adapter.replace(anchor, "        hilog.info(0x0000, 'LinuxDoStartupTrial', 'Retry navigation after reset');\n" + anchor)
    if '--startup-diagnostics' in sys.argv:
        anchor = '  private async requestToken(): Promise<string> {'
        assert adapter.count(anchor) == 1
        adapter = adapter.replace(anchor, '''  private async traceStartupDocument(stage: string): Promise<void> {
    try {
      const state: string = await this.controller.runJavaScript(`(() => [
        location.origin === 'https://linux.do' ? 'forum' : location.href === 'about:blank' ? 'blank' :
          location.protocol === 'chrome-error:' ? 'error' : 'other',
        document.readyState, window === window.top ? 1 : 0,
        window.LinuxDoNativeResponse && typeof window.LinuxDoNativeResponse.receive === 'function' ? 1 : 0
      ].join('|'))();`);
      hilog.info(0x0000, 'LinuxDoStartupTrial', 'Document stage=%{public}s state=%{public}s', stage, state.slice(0, 160));
    } catch { hilog.info(0x0000, 'LinuxDoStartupTrial', 'Document stage=%{public}s unavailable', stage); }
  }

''' + anchor)
        anchor = "      hilog.info(0x0000, 'LinuxDoWebTrial', 'CSRF probe started');"
        assert adapter.count(anchor) == 1
        adapter = adapter.replace(anchor, "      await this.traceStartupDocument('probe');\n" + anchor)
        deadline_anchor = '    return false;\n  }\n\n  private async probeSession('
        assert adapter.count(deadline_anchor) == 1
        adapter = adapter.replace(deadline_anchor, "    await this.traceStartupDocument('deadline');\n" + deadline_anchor)
        anchor = '  pageStarted(): void {'
        assert adapter.count(anchor) == 1
        adapter = adapter.replace(anchor, anchor + "\n    hilog.info(0x0000, 'LinuxDoStartupTrial', 'Adapter page began');")
        index_anchor = '  private async checkTrialBrowserTrace(): Promise<void> {'
        assert index.count(index_anchor) == 1
        index = index.replace(index_anchor, '''  private startupUrlKind(value: string): string {
    return value === 'about:blank' ? 'blank' : /^https:\\/\\/linux\\.do(?::443)?(?:[/?#]|$)/.test(value) ? 'forum' : 'other';
  }

''' + index_anchor)
        anchor = '            this.browserAdapter.pageStarted();'
        assert index.count(anchor) == 1
        index = index.replace(anchor, "            hilog.info(0x0000, 'LinuxDoStartupTrial', 'Page begin kind=%{public}s', this.startupUrlKind(event.url));\n" + anchor)
        anchor = '          .onNavigationEntryCommitted((event: LoadCommittedDetails) => {'
        assert index.count(anchor) == 1
        index = index.replace(anchor, '''          .onPageEnd((event: OnPageEndEvent) => {
            hilog.info(0x0000, 'LinuxDoStartupTrial', 'Page end kind=%{public}s', this.startupUrlKind(event.url));
          })
          .onNavigationEntryCommitted((event: LoadCommittedDetails) => {
            hilog.info(0x0000, 'LinuxDoStartupTrial', 'Commit main=%{public}d same=%{public}d kind=%{public}s',
              event.isMainFrame ? 1 : 0, event.isSameDocument ? 1 : 0, this.startupUrlKind(event.url));
''')
        anchor = '            if (event.request.isMainFrame()) { this.browserAdapter.pageFailed(event.error.getErrorCode()); }'
        assert index.count(anchor) == 1
        index = index.replace(anchor, '''            if (event.request.isMainFrame()) {
              hilog.info(0x0000, 'LinuxDoStartupTrial', 'Main error code=%{public}d kind=%{public}s',
                event.error.getErrorCode(), this.startupUrlKind(event.request.getRequestUrl()));
              this.browserAdapter.pageFailed(event.error.getErrorCode());
            }''')
        anchor = '          .onLoadIntercept((event: OnLoadInterceptEvent) => {\n            if (!event.data.isMainFrame()) { return false; }\n            const url: string = event.data.getRequestUrl();\n            if (!this.showBrowser'
        assert index.count(anchor) == 1
        index = index.replace(anchor, '''          .onHttpErrorReceive((event: OnHttpErrorReceiveEvent) => {
            if (event.request.isMainFrame()) {
              hilog.info(0x0000, 'LinuxDoStartupTrial', 'Main HTTP status=%{public}d', event.response.getResponseCode());
            }
          })
''' + anchor)
    adapter_path.write_text(adapter)
index_path.write_text(index)
web_probe = entry / 'src/main/ets/services/ConnectionProbe.ets'
web_probe.write_text(web_probe.read_text().replace('https://dns.alidns.com/dns-query', trial_doh)
                     .replace('document.body.innerText', 'document.body.textContent'))
web_page = pages / 'ConnectionProbePage.ets'
page = web_page.read_text().replace('阿里公共 DNS', trial_doh_label)
if trial:
    page = page.replace('setHttpDns(webview.SecureDnsMode.OFF, CONNECTION_PROBE_DOH)',
                        'setHttpDns(webview.SecureDnsMode.SECURE_ONLY, CONNECTION_PROBE_DOH)')
anchor = '.onPageEnd(() => { void this.pageFinished(); })'
page = page.replace(anchor, anchor + '''
            .onErrorReceive((event: OnErrorReceiveEvent) => {
              if (!this.webEnabled || this.browserDone || !event.request.isMainFrame() ||
                event.request.getRequestUrl() !== (this.control ? CONNECTION_CONTROL_URL : CONNECTION_PROBE_URL)) { return; }
              this.browserResult = `网页网络错误（${event.error.getErrorCode()}）`;
              this.browserDone = true;
              this.complete();
            })''')
web_page.write_text(page)
raw = entry / 'src/main/resources/rawfile'
raw.mkdir(exist_ok=True)
shutil.copy2(probe / 'THIRD_PARTY_LICENSES.txt', raw / 'THIRD_PARTY_LICENSES.txt')
subprocess.run([sys.executable, str(probe / 'fetch-seed.py'), 'linux.do', str(raw / 'ech-seed-linuxdo.json')], check=True)
print(output)

import { webview } from '@kit.ArkWeb';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import {
  BrowserRequest, BrowserResponse, BrowserMediaResponse, RequestCancellation, ForumApiError, ForumErrorKind,
  READ_SESSION_RECOVERY_TIMEOUT_MS
} from './ForumApi';
import { BrowserMediaTransfer } from './BrowserMediaTransfer';
import { browserMediaUrl, MAX_BROWSER_MEDIA_BYTES, BROWSER_MEDIA_CHUNK_BYTES } from './BrowserMediaPolicy';

const FORUM_ORIGIN: string = 'https://linux.do';
const REQUEST_TIMEOUT_MS: number = 25000;
const MAX_RESPONSE_BYTES: number = 6 * 1024 * 1024;
const MAX_SERIALIZED_CHARS: number = 12 * 1024 * 1024;
const MAX_REQUEST_CHARS: number = 1024 * 1024;
const MAX_ACTIVE_REQUESTS: number = 8;
const REQUEST_SLOT: string = '__linuxDoNativePendingFetches';
const MAX_PREVIEW_RAW_CHARS: number = 65536;
const MAX_PREVIEW_COOKED_CHARS: number = 262144;
const MAX_PREVIEW_SERIALIZED_CHARS: number = 2 * 1024 * 1024;
const PREVIEW_TIMEOUT_MS: number = 15000;

interface BridgeHeaders {
  contentType?: string;
  mitigated?: string;
  retryAfter?: string;
}

interface BridgeResult {
  status?: number;
  body?: string;
  headers?: BridgeHeaders;
  error?: string;
}
interface CsrfProbe { csrf?: string; }

interface PendingRequest {
  request: BrowserRequest;
  resolve: (response: BrowserResponse) => void;
  reject: (reason: ForumApiError) => void;
  timer: number;
  cancellation?: RequestCancellation;
  cancelHandler: () => void;
}
interface PendingMediaRequest {
  transfer: BrowserMediaTransfer;
  resolve: (response: BrowserMediaResponse) => void;
  reject: (reason: ForumApiError) => void;
  timer: number;
  cancellation: RequestCancellation;
  cancelHandler: () => void;
}
interface CookBridgeResult { type?: string; cooked?: string; error?: string; }
interface PendingCookRequest {
  resolve: (cooked: string) => void;
  reject: (reason: ForumApiError) => void;
  timer: number;
  cancellation: RequestCancellation;
  cancelHandler: () => void;
  documentRevision: number;
  navigationRevision: number;
}

/** The only page-callable method accepts the result of an existing native request. */
export class BrowserResponseBridge {
  private handler: (id: string, serialized: string) => void;

  constructor(handler: (id: string, serialized: string) => void) {
    this.handler = handler;
  }

  receive(id: string, serialized: string): void {
    this.handler(id, serialized);
  }
}

function cancelledError(): ForumApiError {
  return new ForumApiError(ForumErrorKind.Cancelled, 0, '请求已取消');
}

function safePath(path: string): boolean {
  if (path.length === 0 || path.length > 8192 || !path.startsWith('/') || path.startsWith('//') ||
    /[\\#\u0000-\u0020\u007F]/.test(path)) {
    return false;
  }
  const pathname: string = path.split('?')[0];
  try {
    const decoded: string = decodeURIComponent(pathname);
    return !decoded.startsWith('//') && !/[\\\u0000-\u001F\u007F]/.test(decoded) &&
      !decoded.split('/').some((segment: string): boolean => segment === '.' || segment === '..');
  } catch {
    return false;
  }
}

function validateRequest(request: BrowserRequest): void {
  if (typeof request.path !== 'string' || !safePath(request.path) ||
    ['GET', 'POST', 'PUT', 'DELETE'].indexOf(request.method) < 0 ||
    typeof request.body !== 'string' || request.body.length > MAX_REQUEST_CHARS ||
    typeof request.csrf !== 'string' || request.csrf.length > 4096 || /[\r\n]/.test(request.csrf) ||
    (request.method === 'GET' && request.body.length > 0)) {
    throw new ForumApiError(ForumErrorKind.Rejected, 0, '网页请求参数不正确');
  }
}

function jsonLiteral(value: string | BrowserRequest): string {
  return JSON.stringify(value).replace(/\u2028/g, '\\u2028').replace(/\u2029/g, '\\u2029');
}

/**
 * ArkWeb transport enabled after explicit verification or a successful read-only CSRF probe.
 * Registration alone never enables it; ForumApi owns that decision.
 * No native request, file, navigation, or cookie operation is exposed to the page.
 */
export class BrowserTransportAdapter {
  readonly bridgeName: string = 'LinuxDoNativeResponse';
  readonly permission: string = '{"javascriptProxyPermission":{"urlPermissionList":' +
    '[{"scheme":"https","host":"linux.do","port":"","path":"/"}]}}';
  readonly bridge: BrowserResponseBridge;
  private controller: webview.WebviewController;
  private pending: Map<string, PendingRequest> = new Map<string, PendingRequest>();
  private mediaPending: Map<string, PendingMediaRequest> = new Map<string, PendingMediaRequest>();
  private cookPending: Map<string, PendingCookRequest> = new Map<string, PendingCookRequest>();
  private disposed: boolean = false;
  private documentRevision: number = 0;
  private navigationRevision: number = 0;
  private navigationCommitted: boolean = false;
  private navigationReset: boolean = false;

  constructor(controller: webview.WebviewController) {
    this.controller = controller;
    this.bridge = new BrowserResponseBridge((id: string, serialized: string): void => {
      this.receive(id, serialized);
    });
  }

  private isTrustedPage(): boolean {
    try {
      return /^https:\/\/linux\.do(?::443)?(?:[/?#]|$)/.test(this.controller.getUrl());
    } catch {
      return false;
    }
  }

  pageStarted(): void {
    // ArkWeb can deliver PageBegin after the corresponding commit notification.
    // Only an explicit load resets commit state; the revision invalidates in-flight probes.
    this.navigationRevision++;
    this.cookPending.forEach((_entry: PendingCookRequest, id: string): void => this.failCook(id, cancelledError(), true));
    this.pending.forEach((entry: PendingRequest, id: string): void => {
      if (entry.request.method === 'GET') { this.fail(id, this.transportError(entry.request, false), false); }
    });
    this.mediaPending.forEach((_entry: PendingMediaRequest, id: string): void => this.failMedia(id, cancelledError(), true));
  }
  pageCommitted(): void {
    this.documentRevision++; this.navigationCommitted = true;
    this.cookPending.forEach((_entry: PendingCookRequest, id: string): void => this.failCook(id, cancelledError(), true));
  }
  pageFailed(code: number): void {
    // ArkWeb's ERR_CONNECTION_RESET can leave an error document under the requested URL.
    if (code === -101) { this.navigationReset = true; }
  }

  private async canProbeDocument(): Promise<boolean> {
    try {
      const result: string = await this.controller.runJavaScript(`(() =>
        location.origin === '${FORUM_ORIGIN}' && window === window.top &&
        (document.readyState === 'interactive' || document.readyState === 'complete') &&
        !!window.${this.bridgeName} && typeof window.${this.bridgeName}.receive === 'function')();`);
      return result === 'true';
    } catch { return false; }
  }

  private async recoveryPause(cancellation: RequestCancellation): Promise<void> {
    let timer: number = 0;
    let handler: () => void = (): void => {};
    try {
      await new Promise<void>((resolve: () => void): void => {
        handler = (): void => { clearTimeout(timer); resolve(); };
        timer = setTimeout(resolve, 250);
        cancellation.onCancel(handler);
      });
    } finally { clearTimeout(timer); cancellation.offCancel(handler); }
  }

  /** A successful same-origin JSON/CSRF response, not a title or cookie, proves readiness. */
  async recoverSession(cancellation: RequestCancellation): Promise<boolean> {
    const deadline: number = Date.now() + READ_SESSION_RECOVERY_TIMEOUT_MS;
    const drainDeadline: number = Math.min(deadline, Date.now() + 3000);
    // Navigating would destroy pending fetches, including possibly committed writes.
    while (this.pending.size + this.mediaPending.size + this.cookPending.size > 0 && !cancellation.isCancelled && Date.now() < drainDeadline) {
      await this.recoveryPause(cancellation);
    }
    if (this.disposed || cancellation.isCancelled || this.pending.size + this.mediaPending.size + this.cookPending.size > 0) { return false; }
    const previousDocument: number = this.documentRevision;
    this.navigationCommitted = false;
    this.navigationReset = false;
    try { this.controller.loadUrl(FORUM_ORIGIN + '/'); } catch { return false; }
    let probes: number = 0;
    let retriedNavigation: boolean = false;
    let nextProbeAt: number = 0;
    while (probes < 3 && !this.disposed && !cancellation.isCancelled && Date.now() < deadline) {
      await this.recoveryPause(cancellation);
      if (this.disposed || cancellation.isCancelled || Date.now() >= deadline) { return false; }
      if (this.navigationReset) {
        if (retriedNavigation || this.pending.size + this.mediaPending.size + this.cookPending.size > 0) { return false; }
        retriedNavigation = true;
        this.navigationReset = false;
        this.navigationCommitted = false;
        try { this.controller.loadUrl(FORUM_ORIGIN + '/'); } catch { return false; }
        continue;
      }
      if (cancellation.isCancelled || !this.isTrustedPage() || !this.navigationCommitted ||
        this.documentRevision <= previousDocument || Date.now() < nextProbeAt) { continue; }
      // A controller URL or a completed load can also describe a browser error page.
      // Require the newly committed document and its bridge, even after a page-end event.
      const document: number = this.documentRevision;
      const navigation: number = this.navigationRevision;
      if (!await this.canProbeDocument()) { continue; }
      if (this.disposed || cancellation.isCancelled || !this.isTrustedPage()) { return false; }
      if (!this.navigationCommitted || document !== this.documentRevision || navigation !== this.navigationRevision) { continue; }
      if (Date.now() >= deadline) { return false; }
      let response: BrowserResponse;
      probes++;
      try { response = await this.probeSession(cancellation, deadline); }
      catch (error) {
        if (this.disposed || cancellation.isCancelled || Date.now() >= deadline) { return false; }
        if (!(error instanceof ForumApiError) ||
          [ForumErrorKind.Network, ForumErrorKind.Timeout, ForumErrorKind.VerificationRequired].indexOf(error.kind) < 0 ||
          probes >= 3) { return false; }
        nextProbeAt = Date.now() + 2000;
        continue;
      }
      if (cancellation.isCancelled) { return false; }
      if (!this.navigationCommitted || document !== this.documentRevision || navigation !== this.navigationRevision) { continue; }
      if (response.status === 200 && !(response.headers['cf-mitigated'] ?? '') &&
        (response.headers['content-type'] ?? '').toLowerCase().indexOf('application/json') >= 0) {
        try {
          const value: CsrfProbe = JSON.parse(response.body) as CsrfProbe;
          if (typeof value.csrf === 'string' && value.csrf.length > 0 && value.csrf.length <= 4096 && !/[\r\n]/.test(value.csrf)) {
            // Keep ArkWeb as the only cookie owner; never restore an old clearance backup.
            try { await webview.WebCookieManager.saveCookieAsync(); } catch { /* The valid live session is still usable. */ }
            if (this.disposed || cancellation.isCancelled || Date.now() >= deadline) { return false; }
            if (!this.navigationCommitted || document !== this.documentRevision || navigation !== this.navigationRevision ||
              !this.isTrustedPage() || !await this.canProbeDocument()) { continue; }
            return !this.disposed && !cancellation.isCancelled && Date.now() < deadline && this.navigationCommitted &&
              document === this.documentRevision && navigation === this.navigationRevision && this.isTrustedPage();
          }
        } catch { /* HTML, malformed JSON and incomplete challenge responses are not success. */ }
      }
      if (probes >= 3) { return false; }
      nextProbeAt = Date.now() + 2000;
    }
    return false;
  }

  private async probeSession(cancellation: RequestCancellation, deadline: number): Promise<BrowserResponse> {
    const probe: RequestCancellation = new RequestCancellation();
    const cancel: () => void = (): void => probe.cancel();
    cancellation.onCancel(cancel);
    const timer: number = setTimeout(cancel, Math.max(0, deadline - Date.now()));
    try {
      return await this.request({ path: '/session/csrf.json', method: 'GET', body: '', csrf: '' }, probe);
    } finally { clearTimeout(timer); cancellation.offCancel(cancel); }
  }

  private async requestToken(): Promise<string> {
    try {
      if (!canIUse('SystemCapability.Security.CryptoFramework.Rand')) {
        throw new ForumApiError(ForumErrorKind.Unsupported, 0, '当前设备暂不支持安全网页请求');
      }
      const blob: cryptoFramework.DataBlob = await cryptoFramework.createRandom().generateRandom(16);
      let value: string = '';
      for (let index: number = 0; index < blob.data.length; index++) {
        value += blob.data[index].toString(16).padStart(2, '0');
      }
      if (value.length !== 32 || this.pending.has(value) || this.mediaPending.has(value) || this.cookPending.has(value)) {
        throw new ForumApiError(ForumErrorKind.Network, 0, '无法创建网页请求');
      }
      return value;
    } catch (error) {
      if (error instanceof ForumApiError) { throw error; }
      throw new ForumApiError(ForumErrorKind.Network, 0, '无法创建网页请求');
    }
  }

  async request(request: BrowserRequest, cancellation?: RequestCancellation): Promise<BrowserResponse> {
    validateRequest(request);
    const snapshot: BrowserRequest = {
      path: request.path, method: request.method, body: request.body, csrf: request.csrf
    };
    if (this.disposed || cancellation?.isCancelled) { throw cancelledError(); }
    if (!this.isTrustedPage()) {
      throw new ForumApiError(ForumErrorKind.VerificationRequired, 0, '请先在社区网页中完成验证');
    }
    if (this.pending.size + this.mediaPending.size + this.cookPending.size >= MAX_ACTIVE_REQUESTS) {
      throw new ForumApiError(ForumErrorKind.Network, 0, '网页请求较多，请稍后重试');
    }
    let id: string = '';
    try { id = await this.requestToken(); }
    catch (error) {
      if (error instanceof ForumApiError) { throw error; }
      throw new ForumApiError(ForumErrorKind.Network, 0, '无法创建网页请求');
    }
    if (this.disposed || cancellation?.isCancelled) { throw cancelledError(); }
    if (!this.isTrustedPage()) {
      throw new ForumApiError(ForumErrorKind.VerificationRequired, 0, '网页会话已变化，请重新完成验证');
    }
    if (this.pending.size + this.mediaPending.size + this.cookPending.size >= MAX_ACTIVE_REQUESTS) {
      throw new ForumApiError(ForumErrorKind.Network, 0, '网页请求较多，请稍后重试');
    }

    return new Promise<BrowserResponse>(
      (resolve: (response: BrowserResponse) => void, reject: (reason: ForumApiError) => void): void => {
        const cancelHandler: () => void = (): void => { this.fail(id, cancelledError(), true); };
        const entry: PendingRequest = {
          request: snapshot, resolve: resolve, reject: reject, timer: 0,
          cancellation: cancellation, cancelHandler: cancelHandler
        };
        this.pending.set(id, entry);
        entry.timer = setTimeout((): void => {
          this.fail(id, this.transportError(snapshot, true), true);
        }, REQUEST_TIMEOUT_MS);
        cancellation?.onCancel(cancelHandler);
        if (!this.pending.has(id)) { return; }

        try {
          // This Promise only reports script injection, not the fetch() result.
          this.controller.runJavaScript(this.fetchScript(id, snapshot)).then((result: string): void => {
            if (result === 'wrong_origin' || result === '"wrong_origin"') {
              this.fail(id, new ForumApiError(ForumErrorKind.VerificationRequired, 0,
                '网页会话已变化，请重新完成验证'), true);
            } else if (result === 'missing_bridge' || result === '"missing_bridge"') {
              this.fail(id, new ForumApiError(ForumErrorKind.Network, 0, '网页通信尚未就绪，请重新打开验证页'), true);
            }
          }).catch((): void => { this.fail(id, this.transportError(snapshot, false), true); });
        } catch {
          this.fail(id, this.transportError(snapshot, false), true);
        }
      });
  }

  private transportError(request: BrowserRequest, timeout: boolean): ForumApiError {
    if (request.method !== 'GET') {
      return new ForumApiError(ForumErrorKind.UnknownResult, 0, '提交结果未确认，请刷新后检查，避免重复提交');
    }
    return new ForumApiError(timeout ? ForumErrorKind.Timeout : ForumErrorKind.Network, 0,
      timeout ? '网页请求超时，请检查网络后重试' : '网页请求未完成，请检查网络或重新验证');
  }

  private remove(id: string): PendingRequest | undefined {
    const entry: PendingRequest | undefined = this.pending.get(id);
    if (entry === undefined) { return undefined; }
    this.pending.delete(id);
    clearTimeout(entry.timer);
    entry.cancellation?.offCancel(entry.cancelHandler);
    return entry;
  }

  private abort(id: string): void {
    if (!this.isTrustedPage()) { return; }
    const script: string = '(() => { if (location.origin !== "https://linux.do") return; ' +
      `const requests = window[${jsonLiteral(REQUEST_SLOT)}]; ` +
      `const controller = requests instanceof Map ? requests.get(${jsonLiteral(id)}) : undefined; ` +
      'if (controller) { controller.abort(); } })();';
    try { this.controller.runJavaScript(script).catch((): void => {}); }
    catch { /* Navigation may have already destroyed the page's fetch context. */ }
  }

  private fail(id: string, reason: ForumApiError, abort: boolean): void {
    const entry: PendingRequest | undefined = this.remove(id);
    if (entry === undefined) { return; }
    if (abort) { this.abort(id); }
    entry.reject(reason);
  }

  private receive(id: string, serialized: string): void {
    if (!this.disposed && typeof id === 'string' && /^[0-9a-f]{32}$/.test(id) && this.cookPending.has(id)) {
      this.receiveCook(id, serialized); return;
    }
    if (!this.disposed && typeof id === 'string' && /^[0-9a-f]{32}$/.test(id) && this.mediaPending.has(id)) {
      this.receiveMedia(id, serialized); return;
    }
    if (this.disposed || typeof id !== 'string' || !/^[0-9a-f]{32}$/.test(id) || !this.pending.has(id)) { return; }
    const entry: PendingRequest | undefined = this.pending.get(id);
    if (entry === undefined) { return; }
    if (!this.isTrustedPage()) {
      this.fail(id, new ForumApiError(ForumErrorKind.VerificationRequired, 0, '网页会话已变化，请重新完成验证'), true);
      return;
    }
    if (typeof serialized !== 'string' || serialized.length > MAX_SERIALIZED_CHARS) {
      this.fail(id, new ForumApiError(ForumErrorKind.InvalidResponse, 0, '社区响应过大，已停止读取'), true);
      return;
    }
    try {
      const value: BridgeResult = JSON.parse(serialized) as BridgeResult;
      if (value === null || typeof value !== 'object' || Array.isArray(value)) { throw new Error('Invalid result'); }
      if (typeof value.error === 'string' && value.error.length > 0) {
        const reason: ForumApiError = value.error === 'too_large' ?
          new ForumApiError(ForumErrorKind.InvalidResponse, 0, '社区响应过大，已停止读取') :
          value.error === 'wrong_origin' ? new ForumApiError(ForumErrorKind.VerificationRequired, 0,
            '网页会话已变化，请重新完成验证') : this.transportError(entry.request, value.error === 'timeout');
        this.fail(id, reason, true);
        return;
      }
      if (typeof value.status !== 'number' || !Number.isInteger(value.status) || value.status < 100 || value.status > 599 ||
        typeof value.body !== 'string' || value.body.length > MAX_RESPONSE_BYTES ||
        value.headers === null || typeof value.headers !== 'object' || Array.isArray(value.headers)) {
        throw new Error('Invalid response');
      }
      const headers: Record<string, string> = {};
      const values: BridgeHeaders = value.headers;
      if (typeof values.contentType === 'string') { headers['content-type'] = values.contentType.slice(0, 1024); }
      if (typeof values.mitigated === 'string') { headers['cf-mitigated'] = values.mitigated.slice(0, 1024); }
      if (typeof values.retryAfter === 'string') { headers['retry-after'] = values.retryAfter.slice(0, 1024); }
      const completed: PendingRequest | undefined = this.remove(id);
      completed?.resolve({ status: value.status, body: value.body, headers: headers });
    } catch {
      this.fail(id, new ForumApiError(ForumErrorKind.InvalidResponse, 0, '网页响应格式不正确，请重新验证'), true);
    }
  }

  /** Only the fixed official Discourse text module can cook this bounded raw text. */
  async cookPreview(raw: string, cancellation: RequestCancellation): Promise<string> {
    if (typeof raw !== 'string' || raw.length === 0 || raw.length > MAX_PREVIEW_RAW_CHARS) {
      throw new ForumApiError(ForumErrorKind.Rejected, 0, '预览内容为空或过长');
    }
    if (this.disposed || cancellation.isCancelled) { throw cancelledError(); }
    if (!this.isTrustedPage()) { throw new ForumApiError(ForumErrorKind.VerificationRequired, 0, '请先完成社区网页验证，再重试预览'); }
    const documentRevision: number = this.documentRevision;
    const navigationRevision: number = this.navigationRevision;
    const id: string = await this.requestToken();
    if (this.disposed || cancellation.isCancelled || documentRevision !== this.documentRevision ||
      navigationRevision !== this.navigationRevision) { throw cancelledError(); }
    if (!this.isTrustedPage()) { throw new ForumApiError(ForumErrorKind.VerificationRequired, 0, '网页会话已变化，请重新完成验证'); }
    if (this.pending.size + this.mediaPending.size + this.cookPending.size >= MAX_ACTIVE_REQUESTS) {
      throw new ForumApiError(ForumErrorKind.Network, 0, '网页正在处理其他请求，请稍后重试预览');
    }
    return new Promise<string>((resolve: (cooked: string) => void, reject: (reason: ForumApiError) => void): void => {
      const cancelHandler: () => void = (): void => this.failCook(id, cancelledError(), true);
      const entry: PendingCookRequest = { resolve: resolve, reject: reject, timer: 0, cancellation: cancellation,
        cancelHandler: cancelHandler, documentRevision: documentRevision, navigationRevision: navigationRevision };
      this.cookPending.set(id, entry);
      entry.timer = setTimeout((): void => this.failCook(id,
        new ForumApiError(ForumErrorKind.Timeout, 0, '预览超时，请重试或返回编辑'), true), PREVIEW_TIMEOUT_MS);
      cancellation.onCancel(cancelHandler);
      if (!this.cookPending.has(id)) { return; }
      try {
        this.controller.runJavaScript(this.cookScript(id, raw)).then((result: string): void => {
          if (result === 'wrong_origin' || result === '"wrong_origin"' || result === 'missing_bridge' || result === '"missing_bridge"') {
            this.failCook(id, new ForumApiError(ForumErrorKind.VerificationRequired, 0, '社区网页尚未就绪，请完成验证后重试预览'), true);
          } else if (result === 'unsupported' || result === '"unsupported"') {
            this.failCook(id, new ForumApiError(ForumErrorKind.Unsupported, 0, '社区排版模块尚未就绪，请稍后重试或返回编辑'), false);
          }
        }).catch((): void => this.failCook(id, new ForumApiError(ForumErrorKind.Network, 0, '预览暂时无法生成，请重试或返回编辑'), true));
      } catch { this.failCook(id, new ForumApiError(ForumErrorKind.Network, 0, '预览暂时无法生成，请重试或返回编辑'), true); }
    });
  }

  private removeCook(id: string): PendingCookRequest | undefined {
    const entry: PendingCookRequest | undefined = this.cookPending.get(id);
    if (entry !== undefined) {
      this.cookPending.delete(id); clearTimeout(entry.timer); entry.cancellation.offCancel(entry.cancelHandler);
    }
    return entry;
  }

  private failCook(id: string, error: ForumApiError, abort: boolean): void {
    const entry: PendingCookRequest | undefined = this.removeCook(id);
    if (entry === undefined) { return; }
    if (abort) { this.abort(id); }
    entry.reject(error);
  }

  private receiveCook(id: string, serialized: string): void {
    const entry: PendingCookRequest | undefined = this.cookPending.get(id);
    if (entry === undefined) { return; }
    if (!this.isTrustedPage() || entry.documentRevision !== this.documentRevision ||
      entry.navigationRevision !== this.navigationRevision || entry.cancellation.isCancelled) {
      this.failCook(id, cancelledError(), true); return;
    }
    try {
      if (typeof serialized !== 'string' || serialized.length > MAX_PREVIEW_SERIALIZED_CHARS) { throw new Error('Invalid preview'); }
      const result: CookBridgeResult = JSON.parse(serialized) as CookBridgeResult;
      if (result === null || typeof result !== 'object' || Array.isArray(result)) { throw new Error('Invalid preview'); }
      if (result.type === 'cook_error') {
        this.failCook(id, new ForumApiError(result.error === 'too_large' ? ForumErrorKind.InvalidResponse :
          result.error === 'timeout' ? ForumErrorKind.Timeout : ForumErrorKind.Unsupported, 0,
          result.error === 'too_large' ? '排版后的内容过长，无法完整预览' : result.error === 'timeout' ?
            '预览超时，请重试或返回编辑' : '社区排版模块暂不可用，请重试或返回编辑'), true); return;
      }
      if (result.type !== 'cook' || typeof result.cooked !== 'string' || result.cooked.length > MAX_PREVIEW_COOKED_CHARS) {
        throw new Error('Invalid preview');
      }
      this.removeCook(id)?.resolve(result.cooked);
    } catch { this.failCook(id, new ForumApiError(ForumErrorKind.InvalidResponse, 0, '社区预览格式不正确，请返回编辑后重试'), true); }
  }

  private cookScript(id: string, raw: string): string {
    return `(() => {
      if (location.origin !== ${jsonLiteral(FORUM_ORIGIN)} || window !== window.top) return 'wrong_origin';
      const bridge = window[${jsonLiteral(this.bridgeName)}];
      if (!bridge || typeof bridge.receive !== 'function') return 'missing_bridge';
      if (typeof window.require !== 'function' || typeof window.require.has !== 'function' ||
          !window.require.has('discourse/lib/text')) return 'unsupported';
      let textModule;
      try { textModule = window.require('discourse/lib/text'); } catch { return 'unsupported'; }
      if (!textModule || typeof textModule.generateCookFunction !== 'function') return 'unsupported';
      const id = ${jsonLiteral(id)}, slot = ${jsonLiteral(REQUEST_SLOT)};
      const active = window[slot] instanceof Map ? window[slot] : new Map(); window[slot] = active;
      let stopped = false, timer = 0;
      const control = { abort() { stopped = true; clearTimeout(timer); active.delete(id); } };
      active.set(id, control);
      const finish = result => {
        if (stopped) return;
        stopped = true; clearTimeout(timer); active.delete(id);
        if (location.origin === ${jsonLiteral(FORUM_ORIGIN)} && window === window.top) bridge.receive(id, JSON.stringify(result));
      };
      timer = setTimeout(() => finish({ type: 'cook_error', error: 'timeout' }), ${PREVIEW_TIMEOUT_MS - 500});
      (async () => {
        try {
          const cook = await textModule.generateCookFunction({ previewing: true });
          if (stopped) return;
          if (typeof cook !== 'function') { finish({ type: 'cook_error', error: 'unsupported' }); return; }
          const cooked = cook(${jsonLiteral(raw)});
          if (typeof cooked !== 'string') { finish({ type: 'cook_error', error: 'invalid' }); return; }
          if (cooked.length > ${MAX_PREVIEW_COOKED_CHARS}) { finish({ type: 'cook_error', error: 'too_large' }); return; }
          finish({ type: 'cook', cooked });
        } catch { finish({ type: 'cook_error', error: 'failed' }); }
      })();
      return 'started';
    })();`;
  }

  async requestImage(url: string, cancellation: RequestCancellation): Promise<BrowserMediaResponse> {
    const destination: string = browserMediaUrl(url);
    if (!destination) { throw new ForumApiError(ForumErrorKind.Rejected, 0, '图片地址不支持网页加载'); }
    if (this.disposed || cancellation.isCancelled) { throw cancelledError(); }
    if (!this.isTrustedPage()) { throw new ForumApiError(ForumErrorKind.VerificationRequired, 0, '请先完成网页验证'); }
    const id: string = await this.requestToken();
    if (this.disposed || cancellation.isCancelled) { throw cancelledError(); }
    if (!this.isTrustedPage()) { throw new ForumApiError(ForumErrorKind.VerificationRequired, 0, '网页会话已变化，请重新验证'); }
    if (this.pending.size + this.mediaPending.size + this.cookPending.size >= MAX_ACTIVE_REQUESTS) {
      throw new ForumApiError(ForumErrorKind.Network, 0, '网页图片请求较多，请稍后重试');
    }
    return new Promise<BrowserMediaResponse>((resolve, reject): void => {
      const cancelHandler: () => void = (): void => this.failMedia(id, cancelledError(), true);
      const entry: PendingMediaRequest = { transfer: new BrowserMediaTransfer(), resolve: resolve, reject: reject,
        timer: 0, cancellation: cancellation, cancelHandler: cancelHandler };
      this.mediaPending.set(id, entry);
      entry.timer = setTimeout((): void => this.failMedia(id,
        new ForumApiError(ForumErrorKind.Timeout, 0, '图片加载超时，请稍后重试'), true), REQUEST_TIMEOUT_MS);
      cancellation.onCancel(cancelHandler);
      if (!this.mediaPending.has(id)) { return; }
      try {
        this.controller.runJavaScript(this.mediaScript(id, destination)).then((result: string): void => {
          if (result === 'wrong_origin' || result === '"wrong_origin"' || result === 'missing_bridge' || result === '"missing_bridge"') {
            this.failMedia(id, new ForumApiError(ForumErrorKind.VerificationRequired, 0, '网页图片会话尚未就绪'), true);
          }
        }).catch((): void => this.failMedia(id, new ForumApiError(ForumErrorKind.Network, 0, '图片请求未完成，请重试'), true));
      } catch { this.failMedia(id, new ForumApiError(ForumErrorKind.Network, 0, '图片请求未完成，请重试'), true); }
    });
  }

  private removeMedia(id: string): PendingMediaRequest | undefined {
    const entry: PendingMediaRequest | undefined = this.mediaPending.get(id);
    if (entry) {
      this.mediaPending.delete(id); clearTimeout(entry.timer);
      entry.cancellation.offCancel(entry.cancelHandler);
    }
    return entry;
  }
  private failMedia(id: string, error: ForumApiError, abort: boolean): void {
    const entry: PendingMediaRequest | undefined = this.removeMedia(id);
    if (!entry) { return; }
    entry.transfer.dispose();
    if (abort) { this.abort(id); }
    entry.reject(error);
  }
  private receiveMedia(id: string, serialized: string): void {
    const entry: PendingMediaRequest | undefined = this.mediaPending.get(id);
    if (!entry) { return; }
    if (!this.isTrustedPage()) { this.failMedia(id, cancelledError(), true); return; }
    try {
      const response: BrowserMediaResponse | undefined = entry.transfer.accept(serialized);
      if (response) { this.removeMedia(id)?.resolve(response); }
    } catch (error) {
      this.failMedia(id, error instanceof ForumApiError ? error :
        new ForumApiError(ForumErrorKind.InvalidResponse, 0, '图片传输不完整，请重试'), true);
    }
  }

  private mediaScript(id: string, url: string): string {
    return `(() => {
      if (location.origin !== ${jsonLiteral(FORUM_ORIGIN)} || window !== window.top) return 'wrong_origin';
      const bridge = window[${jsonLiteral(this.bridgeName)}];
      if (!bridge || typeof bridge.receive !== 'function') return 'missing_bridge';
      const destination = new URL(${jsonLiteral(url)});
      if (destination.protocol !== 'https:' || destination.username || destination.password ||
          !['linux.do', 'cdn3.ldstatic.com'].includes(destination.hostname) || (destination.port && destination.port !== '443')) return 'wrong_origin';
      const id = ${jsonLiteral(id)}, slot = ${jsonLiteral(REQUEST_SLOT)};
      const active = window[slot] instanceof Map ? window[slot] : new Map(); window[slot] = active;
      const aborter = new AbortController(); active.set(id, aborter);
      let finished = false, timer = 0;
      const send = value => { if (!finished) bridge.receive(id, JSON.stringify(value)); };
      const finish = value => { if (finished) return; send(value); finished = true; clearTimeout(timer); active.delete(id); };
      timer = setTimeout(() => { aborter.abort(); finish({ type: 'error', error: 'timeout' }); }, ${REQUEST_TIMEOUT_MS - 500});
      (async () => {
        let reader;
        try {
          const local = destination.origin === ${jsonLiteral(FORUM_ORIGIN)};
          const response = await fetch(destination.href, { method: 'GET', headers: { Accept: 'image/*' },
            credentials: local ? 'include' : 'omit', mode: local ? 'same-origin' : 'cors', redirect: 'error',
            referrerPolicy: local ? 'same-origin' : 'no-referrer', cache: 'no-store', signal: aborter.signal });
          if (new URL(response.url).origin !== destination.origin) throw new Error('wrong_origin');
          const headers = { contentType: (response.headers.get('content-type') || '').slice(0, 1024),
            mitigated: (response.headers.get('cf-mitigated') || '').slice(0, 1024) };
          send({ type: 'start', status: response.status, headers });
          if (!response.ok || headers.mitigated || !/^(image\\/|application\\/octet-stream)/i.test(headers.contentType)) {
            aborter.abort(); finish({ type: 'error', error: 'invalid_image' }); return;
          }
          if (Number(response.headers.get('content-length') || '0') > ${MAX_BROWSER_MEDIA_BYTES}) throw new Error('too_large');
          if (!response.body) throw new Error('invalid_image');
          reader = response.body.getReader();
          const buffer = new Uint8Array(${BROWSER_MEDIA_CHUNK_BYTES});
          let used = 0, total = 0, sent = 0, index = 0;
          const flush = () => {
            let text = ''; for (let i = 0; i < used; i++) text += String.fromCharCode(buffer[i]);
            send({ type: 'chunk', index: index++, offset: sent, data: btoa(text) }); sent += used; used = 0;
          };
          while (true) {
            const chunk = await reader.read(); if (chunk.done) break;
            total += chunk.value.byteLength;
            if (total > ${MAX_BROWSER_MEDIA_BYTES}) throw new Error('too_large');
            let offset = 0;
            while (offset < chunk.value.byteLength) {
              const count = Math.min(buffer.length - used, chunk.value.byteLength - offset);
              buffer.set(chunk.value.subarray(offset, offset + count), used); used += count; offset += count;
              if (used === buffer.length) flush();
            }
          }
          if (used) flush(); finish({ type: 'done', total });
        } catch (error) {
          if (reader) reader.cancel().catch(() => {}); aborter.abort();
          finish({ type: 'error', error: error && error.message === 'too_large' ? 'too_large' : 'network' });
        }
      })();
      return 'started';
    })();`;
  }

  private fetchScript(id: string, request: BrowserRequest): string {
    return `(() => {
      if (location.origin !== ${jsonLiteral(FORUM_ORIGIN)} || window !== window.top) return 'wrong_origin';
      const bridge = window[${jsonLiteral(this.bridgeName)}];
      if (!bridge || typeof bridge.receive !== 'function') return 'missing_bridge';
      const id = ${jsonLiteral(id)};
      const request = ${jsonLiteral(request)};
      const slot = ${jsonLiteral(REQUEST_SLOT)};
      const destination = new URL(request.path, ${jsonLiteral(FORUM_ORIGIN)});
      if (destination.origin !== ${jsonLiteral(FORUM_ORIGIN)} || destination.username || destination.password) return 'wrong_origin';
      const active = window[slot] instanceof Map ? window[slot] : new Map();
      window[slot] = active;
      const aborter = new AbortController();
      active.set(id, aborter);
      let finished = false;
      let timer = 0;
      const finish = (value) => {
        if (finished) return;
        finished = true;
        clearTimeout(timer);
        active.delete(id);
        let serialized = JSON.stringify(value);
        if (serialized.length > ${MAX_SERIALIZED_CHARS}) serialized = JSON.stringify({ error: 'too_large' });
        bridge.receive(id, serialized);
      };
      timer = setTimeout(() => { aborter.abort(); finish({ error: 'timeout' }); }, ${REQUEST_TIMEOUT_MS - 500});
      (async () => {
        try {
          const headers = { 'Accept': 'application/json', 'X-Requested-With': 'XMLHttpRequest' };
          if (request.csrf) headers['X-CSRF-Token'] = request.csrf;
          const options = { method: request.method, headers, credentials: 'include',
            mode: 'same-origin', redirect: 'error', cache: 'no-store', signal: aborter.signal };
          if (request.method !== 'GET') {
            headers['Content-Type'] = 'application/json; charset=utf-8';
            options.body = request.body;
          }
          const response = await fetch(destination.href, options);
          if (new URL(response.url).origin !== ${jsonLiteral(FORUM_ORIGIN)}) throw new Error('wrong_origin');
          const declared = Number(response.headers.get('content-length') || '0');
          if (declared > ${MAX_RESPONSE_BYTES}) { aborter.abort(); throw new Error('too_large'); }
          const pieces = [];
          let bytes = 0;
          if (response.body) {
            const reader = response.body.getReader();
            const decoder = new TextDecoder();
            while (true) {
              const chunk = await reader.read();
              if (chunk.done) break;
              bytes += chunk.value.byteLength;
              if (bytes > ${MAX_RESPONSE_BYTES}) { reader.cancel().catch(() => {}); aborter.abort(); throw new Error('too_large'); }
              pieces.push(decoder.decode(chunk.value, { stream: true }));
            }
            pieces.push(decoder.decode());
          }
          finish({ status: response.status, body: pieces.join(''), headers: {
            contentType: (response.headers.get('content-type') || '').slice(0, 1024),
            mitigated: (response.headers.get('cf-mitigated') || '').slice(0, 1024),
            retryAfter: (response.headers.get('retry-after') || '').slice(0, 1024)
          } });
        } catch (error) {
          const code = error && (error.message === 'too_large' || error.message === 'wrong_origin') ? error.message : 'network';
          finish({ error: code });
        }
      })();
      return 'started';
    })();`;
  }

  dispose(): void {
    if (this.disposed) { return; }
    this.disposed = true;
    this.pending.forEach((_entry: PendingRequest, id: string): void => { this.fail(id, cancelledError(), true); });
    this.mediaPending.forEach((_entry: PendingMediaRequest, id: string): void => { this.failMedia(id, cancelledError(), true); });
    this.cookPending.forEach((_entry: PendingCookRequest, id: string): void => { this.failCook(id, cancelledError(), true); });
    try { this.controller.deleteJavaScriptRegister(this.bridgeName); }
    catch { /* The Web component may already have been released. */ }
  }
}

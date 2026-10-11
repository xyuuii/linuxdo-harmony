import { webview } from '@kit.ArkWeb';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import {
  BrowserRequest, BrowserResponse, RequestCancellation, ForumApiError, ForumErrorKind
} from './ForumApi';

const FORUM_ORIGIN: string = 'https://linux.do';
const REQUEST_TIMEOUT_MS: number = 25000;
const MAX_RESPONSE_BYTES: number = 6 * 1024 * 1024;
const MAX_SERIALIZED_CHARS: number = 12 * 1024 * 1024;
const MAX_REQUEST_CHARS: number = 1024 * 1024;
const MAX_ACTIVE_REQUESTS: number = 8;
const REQUEST_SLOT: string = '__linuxDoNativePendingFetches';

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

interface PendingRequest {
  request: BrowserRequest;
  resolve: (response: BrowserResponse) => void;
  reject: (reason: ForumApiError) => void;
  timer: number;
  cancellation?: RequestCancellation;
  cancelHandler: () => void;
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
 * ArkWeb transport for a page the user has explicitly finished verifying.
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
  private disposed: boolean = false;

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
      if (value.length !== 32 || this.pending.has(value)) {
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
    if (this.pending.size >= MAX_ACTIVE_REQUESTS) {
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
    if (this.pending.size >= MAX_ACTIVE_REQUESTS) {
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
    try { this.controller.deleteJavaScriptRegister(this.bridgeName); }
    catch { /* The Web component may already have been released. */ }
  }
}

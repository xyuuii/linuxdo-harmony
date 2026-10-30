import { http } from '@kit.NetworkKit';
import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { url as urlUtils } from '@kit.ArkTS';
import { TopicReadBatch, TopicReadTiming } from './TopicReadTracker';
import { PostRevisionRecord } from '../models/PostRevisionModels';
import { PostRevisionWire, postRevisionFromWire } from './PostRevisionWire';
import { ForumUserProfile, ForumUserSummary, ForumUserActivityFilter, ForumUserActivityPage } from '../models/UserProfileModels';
import {
  ForumUserProfileResponseWire, ForumUserSummaryResponseWire, ForumUserActivityResponseWire,
  forumUserProfileFromWire, forumUserSummaryFromWire, forumUserActivityFromWire
} from './UserProfileWire';
import { DirectoryTag, DirectoryTagPage, DirectoryBadge, DirectoryGroupPage, directoryTagPage } from '../models/DirectoryModels';
import {
  DirectoryTagsResponseWire, DirectoryBadgesResponseWire, DirectoryGroupsResponseWire,
  directoryTagsFromWire, directoryBadgesFromWire, directoryGroupsFromWire
} from './DirectoryWire';
import {
  Topic, Category, DiscourseUser, Post, Boost, TopicDetail, TopicListItem, TopicPage, TopicFeedFilter, TopicBrowseOptions,
  SearchPage, SearchOrder, ForumSearchPostMatch, NotificationFilter, ForumNotification, NotificationPage, UnreadSummary,
  ProfileSection, ProfileBoostDirection, ProfileOrder, ProfilePage, ProfileEntry, ProfileField, UploadedFile, TopicCreationResult,
  flattenCategories, notificationIncludes, measureBoost, safeForumUrl, avatarUrlOf
} from '../models/ForumModels';
import {
  TopicListResponseWire, CategoryResponseWire, CurrentUserWire, TopicDetailWire, PostStreamResponseWire,
  SearchResponseWire, PostWire, PostResponseWire, BoostWire, NotificationResponseWire, CsrfWire,
  UploadResponseWire, LoginResponseWire, UserResponseWire, SummaryResponseWire, SummaryWire, EmailsWire,
  ActionsResponseWire, ActionWire, UserWire, EmojiWire, TopicCreationWire, BookmarksResponseWire, BookmarkWire, TopicWire,
  ProfileSolvedResponseWire, ProfileSolvedPostWire, ProfileBoostsResponseWire, ProfileBoostEntryWire, ProfileBoostPostWire,
  decodeObject, decodeArray, text, numberValue, bool, list, plainText, topicFromWire, userFromWire,
  categoryFromWire, detailFromWire, postFromWire, boostFromWire, streamFromWire, notificationFromWire
} from './ForumWire';

const FORUM_ORIGIN: string = 'https://linux.do';
const UPLOAD_MAX_BYTES: number = 4 * 1024 * 1024;
const UPLOAD_EXTENSIONS: string[] = ['jpg', 'jpeg', 'png', 'gif', 'heic', 'heif', 'webp', 'avif', 'svg',
  'txt', 'pdf', 'doc', 'docx', 'csv', 'zip', '7z', 'gz', 'xz', 'jxl', 'md'];

export enum ForumErrorKind {
  AuthenticationRequired = 'authentication_required', VerificationRequired = 'verification_required',
  Forbidden = 'forbidden', RateLimited = 'rate_limited', NotFound = 'not_found', Rejected = 'rejected',
  Network = 'network', Timeout = 'timeout', Cancelled = 'cancelled', InvalidResponse = 'invalid_response',
  SecondFactorRequired = 'second_factor_required', UnknownResult = 'unknown_result', Unsupported = 'unsupported'
}
export class ForumApiError extends Error {
  kind: ForumErrorKind;
  status: number;
  retryAfterSeconds: number;
  totpEnabled: boolean;
  backupEnabled: boolean;
  constructor(kind: ForumErrorKind, status: number, message: string, retryAfterSeconds: number = 0,
    totpEnabled: boolean = false, backupEnabled: boolean = false) {
    super(message);
    this.name = 'ForumApiError';
    this.kind = kind;
    this.status = status;
    this.retryAfterSeconds = retryAfterSeconds;
    this.totpEnabled = totpEnabled;
    this.backupEnabled = backupEnabled;
  }
}
export const READ_SESSION_RECOVERY_TIMEOUT_MS: number = 25000;

export class RequestCancellation {
  private cancelled: boolean = false;
  private handlers: Set<() => void> = new Set<() => void>();
  get isCancelled(): boolean { return this.cancelled; }
  cancel(): void {
    if (this.cancelled) { return; }
    this.cancelled = true;
    this.handlers.forEach((handler: () => void): void => handler());
    this.handlers.clear();
  }
  onCancel(handler: () => void): void {
    if (this.cancelled) { handler(); } else { this.handlers.add(handler); }
  }
  offCancel(handler: () => void): void { this.handlers.delete(handler); }
}
export interface BrowserRequest { path: string; method: string; body: string; csrf: string; }
export interface BrowserResponse { status: number; body: string; headers: Record<string, string>; }
export interface BrowserMediaResponse { status: number; bytes: ArrayBuffer; headers: Record<string, string>; }
export type BrowserRequestTransport = (request: BrowserRequest, cancellation?: RequestCancellation) => Promise<BrowserResponse>;
export type BrowserMediaTransport = (url: string, cancellation: RequestCancellation) => Promise<BrowserMediaResponse>;
export type BrowserCookTransport = (raw: string, cancellation: RequestCancellation) => Promise<string>;
export type BrowserSessionRecovery = (cancellation: RequestCancellation) => Promise<boolean>;
type ResponseHeaderValue = string | string[];
interface RequestSpec { path: string; method: http.RequestMethod; body?: string; csrf?: string; requiresForeground?: boolean;
  multipart?: http.MultiFormData[]; cancellation?: RequestCancellation; }
interface PasswordLoginBody { login: string; password: string; second_factor_method: number; second_factor_token?: string; }
interface EmailLoginBody { login: string; }
interface TwoFactorBody { second_factor_token?: string; second_factor_method: number; }
interface CreatePostBody { raw: string; topic_id: number; reply_to_post_number?: number; }
interface CreateTopicTagBody { name: string; }
interface CreateTopicBody { title: string; raw: string; category: number; tags: CreateTopicTagBody[]; nested_post: boolean; }
interface RawPostBody { raw: string; }
interface TopicReadTimingsBody { topic_id: number; topic_time: number; timings: Record<string, number>; }
interface EditPostBody { post: RawPostBody; }
interface IdBody { id: number; }
interface BookmarkPostBody { bookmarkable_id: number; bookmarkable_type: string; }
interface BookmarkMutationWire { id?: number; success?: string | boolean; errors?: string[]; }
interface TopicNotificationBody { notification_level: number; }
interface PostFlagBody { id: number; post_action_type_id: number; message: string; }

function cancelledError(): ForumApiError { return new ForumApiError(ForumErrorKind.Cancelled, 0, '请求已取消'); }
function validateId(value: number): void {
  if (!Number.isSafeInteger(value) || value <= 0) { throw new ForumApiError(ForumErrorKind.Rejected, 0, '无效的社区条目'); }
}
function validateCursor(value: number): void {
  if (!Number.isSafeInteger(value) || value < 0) { throw new ForumApiError(ForumErrorKind.Rejected, 0, '无效的分页位置'); }
}
function validateRaw(raw: string): string {
  const value: string = raw.trim();
  if (value.length === 0) { throw new ForumApiError(ForumErrorKind.Rejected, 0, '回复内容不能为空'); }
  return value;
}
function metric(value: number | undefined): string {
  return typeof value === 'number' && Number.isFinite(value) ? String(value) : '—';
}
function serverValidationMessage(raw: string): string {
  try {
    const response: TopicCreationWire = decodeObject<TopicCreationWire>(raw);
    const errors: string[] = list(response.errors).filter((value: string): boolean => typeof value === 'string');
    return plainText(errors.join('；') || text(response.error)).slice(0, 600);
  } catch { return ''; }
}

/** Emoji catalog URLs are image sources, not destinations for authenticated API calls. */
export function emojiImageUrl(value: string): string {
  if (!value || /[\u0000-\u0020\u007f\\]/.test(value)) { return ''; }
  try {
    const parsed: urlUtils.URL = new urlUtils.URL(value, FORUM_ORIGIN);
    if (parsed.protocol !== 'https:' || !parsed.hostname || parsed.username || parsed.password ||
      (parsed.port && parsed.port !== '443')) { return ''; }
    parsed.hash = '';
    return parsed.href;
  } catch { return ''; }
}

export class ForumApi {
  private directoryTagsCache: DirectoryTag[] | undefined = undefined;
  private directoryTagsLoadedAt: number = 0;
  private categoryCache: Category[] | undefined = undefined;
  private categoryInFlight: Promise<Category[]> | undefined = undefined;
  private emojiCache: Map<string, string> | undefined = undefined;
  private emojiInFlight: Promise<Map<string, string>> | undefined = undefined;
  private activeRequests: Set<() => void> = new Set<() => void>();
  private nextRequestAt: number = 0;
  private browserTransport: BrowserRequestTransport | undefined = undefined;
  private browserMediaTransport: BrowserMediaTransport | undefined = undefined;
  private browserCookTransport: BrowserCookTransport | undefined = undefined;
  private previewRequests: Set<RequestCancellation> = new Set<RequestCancellation>();
  private browserTransportEnabled: boolean = false;
  private browserRecovery: BrowserSessionRecovery | undefined = undefined;
  private recoveryTask: Promise<boolean> | undefined = undefined;
  private recoveryCancellation: RequestCancellation | undefined = undefined;
  private nextRecoveryAt: number = 0;
  private recoveryVersion: number = 0;
  private writesInFlight: number = 0;
  private foreground: boolean = true;
  private readTimingRequests: Set<RequestCancellation> = new Set<RequestCancellation>();
  private userAgent: string = '';
  private sessionGeneration: number = 0;
  private sessionResetHandlers: Set<() => void> = new Set<() => void>();

  setUserAgent(value: string): void {
    if (value.length > 0 && value.length <= 1024 && !/[\r\n]/.test(value)) { this.userAgent = value; }
  }
  getUserAgent(): string {
    if (this.userAgent.length === 0) {
      try { this.userAgent = webview.WebviewController.getDefaultUserAgent(); } catch { /* ArkWeb is not initialized yet. */ }
    }
    return this.userAgent;
  }
  registerBrowserTransport(transport: BrowserRequestTransport): void { this.browserTransport = transport; }
  registerBrowserMediaTransport(transport: BrowserMediaTransport): void { this.browserMediaTransport = transport; }
  registerBrowserCookTransport(transport: BrowserCookTransport | undefined): void { this.browserCookTransport = transport; }
  /** User-requested local cooking in the already verified forum Web context.
   * This does not send a draft to a publishing or upload endpoint.
   */
  async previewDraft(raw: string, cancellation: RequestCancellation): Promise<string> {
    if (typeof raw !== 'string' || raw.length === 0 || raw.length > 65536) {
      throw new ForumApiError(ForumErrorKind.Rejected, 0, '预览内容为空或过长');
    }
    const generation: number = this.sessionGeneration;
    if (cancellation.isCancelled || !this.foreground) { throw cancelledError(); }
    const cancel: () => void = (): void => cancellation.cancel();
    this.activeRequests.add(cancel); this.previewRequests.add(cancellation);
    try {
      if (this.recoveryTask !== undefined) { await this.waitForRecovery(this.recoveryTask, cancellation); }
      this.ensureSessionGeneration(generation);
      if (cancellation.isCancelled || !this.foreground) { throw cancelledError(); }
      const transport: BrowserCookTransport | undefined = this.browserCookTransport;
      if (!this.browserTransportEnabled || transport === undefined) {
        throw new ForumApiError(ForumErrorKind.VerificationRequired, 0, '请先完成社区网页验证，再重试预览');
      }
      const cooked: string = await transport(raw, cancellation);
      this.ensureSessionGeneration(generation);
      if (cancellation.isCancelled || !this.foreground) { throw cancelledError(); }
      if (typeof cooked !== 'string' || cooked.length > 262144) {
        throw new ForumApiError(ForumErrorKind.InvalidResponse, 0, '排版后的内容过长或格式不正确，无法完整预览');
      }
      return cooked;
    } finally { this.activeRequests.delete(cancel); this.previewRequests.delete(cancellation); }
  }
  canUseBrowserMedia(): boolean { return this.browserTransportEnabled && this.browserMediaTransport !== undefined; }
  getReadRecoveryVersion(): number { return this.recoveryVersion; }
  async requestBrowserMedia(url: string, cancellation: RequestCancellation): Promise<BrowserMediaResponse> {
    const generation: number = this.sessionGeneration;
    const cancel: () => void = (): void => cancellation.cancel();
    this.activeRequests.add(cancel);
    try {
      if (this.recoveryTask !== undefined) { await this.waitForRecovery(this.recoveryTask, cancellation); }
      this.ensureSessionGeneration(generation);
      if (cancellation.isCancelled) { throw cancelledError(); }
      const transport: BrowserMediaTransport | undefined = this.browserMediaTransport;
      if (!this.browserTransportEnabled || !transport) {
        throw new ForumApiError(ForumErrorKind.VerificationRequired, 0, '请先完成网页验证以加载图片');
      }
      const response: BrowserMediaResponse = await transport(url, cancellation);
      this.ensureSessionGeneration(generation);
      if (cancellation.isCancelled) { throw cancelledError(); }
      return response;
    } finally { this.activeRequests.delete(cancel); }
  }
  registerBrowserRecovery(recovery: BrowserSessionRecovery | undefined): void {
    this.cancelSessionRecovery();
    this.browserRecovery = recovery;
    this.nextRecoveryAt = 0;
  }
  cancelSessionRecovery(): void {
    this.recoveryCancellation?.cancel();
    this.recoveryCancellation = undefined;
    this.recoveryTask = undefined;
  }
  setForeground(active: boolean): void {
    this.foreground = active;
    if (!active) {
      this.cancelSessionRecovery();
      this.readTimingRequests.forEach((request: RequestCancellation): void => { request.cancel(); });
      this.previewRequests.forEach((request: RequestCancellation): void => { request.cancel(); });
    }
  }
  setBrowserTransportEnabled(enabled: boolean): void { this.browserTransportEnabled = enabled; }
  dispose(): void {
    this.cancelSessionRecovery();
    this.activeRequests.forEach((cancel: () => void): void => cancel());
    this.activeRequests.clear();
    this.nextRequestAt = 0;
  }

  private async waitForRecovery(task: Promise<boolean>, cancellation: RequestCancellation): Promise<boolean> {
    if (cancellation.isCancelled) { throw cancelledError(); }
    let handler: () => void = (): void => {};
    try {
      return await new Promise<boolean>((resolve: (value: boolean) => void, reject: (error: ForumApiError) => void): void => {
        handler = (): void => reject(cancelledError());
        cancellation.onCancel(handler);
        task.then(resolve).catch(() => resolve(false));
      });
    } finally { cancellation.offCancel(handler); }
  }

  /** Share one bounded browser recovery across API and image reads. Never replay a write. */
  async recoverReadSession(cancellation: RequestCancellation): Promise<boolean> {
    if (cancellation.isCancelled) { throw cancelledError(); }
    if (this.recoveryTask !== undefined) { return this.waitForRecovery(this.recoveryTask, cancellation); }
    if (!this.foreground || !this.browserRecovery || this.writesInFlight > 0 || Date.now() < this.nextRecoveryAt) { return false; }
    const recovery: BrowserSessionRecovery = this.browserRecovery;
    const generation: number = this.sessionGeneration;
    const token: RequestCancellation = new RequestCancellation();
    this.recoveryCancellation = token;
    this.nextRecoveryAt = Date.now() + 30000;
    // Install the task before invoking the handler so concurrent requests join it.
    const task: Promise<boolean> = Promise.resolve().then(async (): Promise<boolean> => {
      const timer: number = setTimeout((): void => { token.cancel(); }, READ_SESSION_RECOVERY_TIMEOUT_MS);
      try {
        const recovered: boolean = await this.waitForRecovery(recovery(token), token);
        if (!recovered || token.isCancelled || generation !== this.sessionGeneration) { return false; }
        this.browserTransportEnabled = true;
        this.recoveryVersion++;
        return true;
      } catch { return false; }
      finally {
        clearTimeout(timer);
        if (this.recoveryCancellation === token) {
          this.recoveryCancellation = undefined;
          this.recoveryTask = undefined;
        }
      }
    });
    this.recoveryTask = task;
    return this.waitForRecovery(task, cancellation);
  }
  resetSessionContext(): void {
    this.sessionGeneration++;
    this.dispose();
    this.nextRecoveryAt = 0;
    this.categoryCache = undefined;
    this.categoryInFlight = undefined;
    this.directoryTagsCache = undefined;
    this.directoryTagsLoadedAt = 0;
    this.emojiCache = undefined;
    this.emojiInFlight = undefined;
    this.sessionResetHandlers.forEach((handler: () => void): void => handler());
  }
  getSessionGeneration(): number { return this.sessionGeneration; }
  onSessionReset(handler: () => void): void { this.sessionResetHandlers.add(handler); }
  offSessionReset(handler: () => void): void { this.sessionResetHandlers.delete(handler); }
  private ensureSessionGeneration(generation: number): void {
    if (generation !== this.sessionGeneration) { throw cancelledError(); }
  }

  private async waitForSlot(cancellation?: RequestCancellation): Promise<void> {
    if (cancellation?.isCancelled) { throw cancelledError(); }
    const scheduled: number = Math.max(Date.now(), this.nextRequestAt);
    this.nextRequestAt = scheduled + 1000;
    const delay: number = scheduled - Date.now();
    if (delay <= 0) { return; }
    let timer: number = 0;
    let handler: () => void = (): void => {};
    try {
      await new Promise<void>((resolve: () => void, reject: (reason: ForumApiError) => void): void => {
        handler = (): void => { clearTimeout(timer); reject(cancelledError()); };
        this.activeRequests.add(handler);
        timer = setTimeout((): void => resolve(), delay);
        cancellation?.onCancel(handler);
      });
    } finally { this.activeRequests.delete(handler); cancellation?.offCancel(handler); clearTimeout(timer); }
  }

  private async nativeRequest(spec: RequestSpec): Promise<BrowserResponse> {
    const url: string = safeForumUrl(spec.path);
    if (!url || !spec.path.startsWith('/') || spec.path.startsWith('//')) {
      throw new ForumApiError(ForumErrorKind.Rejected, 0, '请求地址不属于 LINUX DO');
    }
    let cookies: string = '';
    try { cookies = await webview.WebCookieManager.fetchCookie(url, false, true); }
    catch (error) {
      const code: number = (error as BusinessError).code;
      if (code !== 17100002) {
        throw new ForumApiError(ForumErrorKind.VerificationRequired, 0, '网页会话尚未就绪，请打开网页验证');
      }
    }
    if (spec.cancellation?.isCancelled) { throw cancelledError(); }
    const headers: Record<string, string> = {
      'Accept': 'application/json', 'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      'X-Requested-With': 'XMLHttpRequest', 'Referer': FORUM_ORIGIN + '/',
      'Content-Type': spec.multipart ? 'multipart/form-data' : 'application/json; charset=utf-8'
    };
    if (cookies.length > 0) { headers['Cookie'] = cookies; }
    if (spec.csrf) { headers['X-CSRF-Token'] = spec.csrf; headers['Origin'] = FORUM_ORIGIN; }
    const ua: string = this.getUserAgent();
    if (ua.length > 0) { headers['User-Agent'] = ua; }
    const request: http.HttpRequest = http.createHttp();
    let timer: number = 0;
    let settled: boolean = false;
    let cancel: () => void = (): void => {};
    try {
      const response: http.HttpResponse = await new Promise<http.HttpResponse>(
        (resolve: (value: http.HttpResponse) => void, reject: (reason: ForumApiError) => void): void => {
          cancel = (): void => {
            if (settled) { return; }
            settled = true;
            try { request.destroy(); } catch { /* Already released. */ }
            reject(cancelledError());
          };
          this.activeRequests.add(cancel);
          spec.cancellation?.onCancel(cancel);
          if (settled) { return; }
          timer = setTimeout((): void => {
            if (settled) { return; }
            settled = true;
            try { request.destroy(); } catch { /* Already released. */ }
            reject(new ForumApiError(spec.method === http.RequestMethod.GET ? ForumErrorKind.Timeout : ForumErrorKind.UnknownResult,
              0, spec.method === http.RequestMethod.GET ? '连接超时，请检查网络' : '提交结果未确认，请刷新后检查，避免重复提交'));
          }, 25000);
          const options: http.HttpRequestOptions = {
            method: spec.method, header: headers, expectDataType: http.HttpDataType.STRING,
            usingCache: false, connectTimeout: 6000, readTimeout: 20000,
            maxRedirects: 0, maxLimit: 6 * 1024 * 1024
          };
          // NetStack rejects extraData='' before sending. Omit it for bodyless mutations.
          if (spec.body !== undefined && spec.body.length > 0) { options.extraData = spec.body; }
          if (spec.multipart !== undefined) { options.multiFormDataList = spec.multipart; }
          request.request(url, options).then((value: http.HttpResponse): void => {
            if (!settled) { settled = true; resolve(value); }
          }).catch((error: BusinessError): void => {
            if (settled) { return; }
            settled = true;
            if (error.code === 401) {
              reject(new ForumApiError(ForumErrorKind.Rejected, 0, '请求配置无效，未提交，请更新应用'));
              return;
            }
            const writing: boolean = spec.method !== http.RequestMethod.GET;
            const kind: ForumErrorKind = writing ? ForumErrorKind.UnknownResult :
              (error.code === 2300047 ? ForumErrorKind.VerificationRequired :
                error.code === 2300028 ? ForumErrorKind.Timeout : ForumErrorKind.Network);
            reject(new ForumApiError(kind, 0, writing ? '提交结果未确认，请刷新后检查，避免重复提交' :
              error.code === 2300047 ? '社区请求需要网页跳转，请打开网页验证' : '无法连接社区，请检查网络后重试'));
          });
        });
      const responseHeaders: Record<string, ResponseHeaderValue> = typeof response.header === 'string' ?
        decodeObject<Record<string, ResponseHeaderValue>>(response.header) : response.header as Record<string, ResponseHeaderValue>;
      const normalizedHeaders: Record<string, string> = {};
      Object.keys(responseHeaders).forEach((key: string): void => {
        const value: ResponseHeaderValue = responseHeaders[key];
        normalizedHeaders[key.toLowerCase()] = typeof value === 'string' ? value : list(value).join('\n');
      });
      const setCookie: string = normalizedHeaders['set-cookie'] ?? '';
      if (spec.cancellation?.isCancelled) { throw cancelledError(); }
      if (setCookie.length > 0) {
        const values: string[] = setCookie.split(/\r?\n|,(?=\s*[^\s;,=]+=[^;,]*)/);
        for (const cookie of values) {
          if (cookie.trim().length > 0) { webview.WebCookieManager.configCookieSync(url, cookie.trim(), false, true); }
        }
        if (values.some((cookie: string): boolean => /^\s*(?:_t|_forum_session|cf_clearance)=/.test(cookie))) {
          // ArkWeb normally flushes every 30 seconds; persist important rotations before a quick app exit.
          try { await webview.WebCookieManager.saveCookieAsync(); }
          catch { /* Persistence failure must not turn a completed write into a retryable failure. */ }
        }
      }
      if (typeof response.result !== 'string') { throw new ForumApiError(ForumErrorKind.InvalidResponse, response.responseCode, '社区响应格式不正确'); }
      return { status: response.responseCode, body: response.result, headers: normalizedHeaders };
    } catch (error) {
      if (error instanceof ForumApiError) { throw error; }
      throw new ForumApiError(ForumErrorKind.InvalidResponse, 0, '社区响应处理失败，请重新打开网页会话');
    } finally {
      clearTimeout(timer);
      spec.cancellation?.offCancel(cancel);
      this.activeRequests.delete(cancel);
      try { request.destroy(); } catch { /* Released by cancellation or timeout. */ }
    }
  }

  private checkResponse(response: BrowserResponse, writing: boolean): void {
    const status: number = response.status;
    const head: string = response.body.slice(0, 4000).toLowerCase();
    const challenged: boolean = (response.headers['cf-mitigated'] ?? '').length > 0 ||
      head.indexOf('challenge-platform') >= 0 || head.indexOf('cf-chl') >= 0 || head.indexOf('just a moment') >= 0;
    if (challenged) { throw new ForumApiError(ForumErrorKind.VerificationRequired, status, '需要在网页中完成人机验证'); }
    if (status === 401) { throw new ForumApiError(ForumErrorKind.AuthenticationRequired, status, '登录已过期，请重新登录'); }
    if (status === 403) {
      const kind: ForumErrorKind = head.trim().startsWith('{') ? ForumErrorKind.Forbidden : ForumErrorKind.VerificationRequired;
      throw new ForumApiError(kind, status, kind === ForumErrorKind.Forbidden ? '账号没有此操作的权限，请检查登录状态' : '访问被安全验证拦截，请打开网页验证');
    }
    if (status === 429) {
      const retry: number = Number(response.headers['retry-after'] ?? '0');
      throw new ForumApiError(ForumErrorKind.RateLimited, status, '请求过于频繁，请稍后重试', Number.isFinite(retry) ? Math.max(0, retry) : 0);
    }
    if (status === 404) { throw new ForumApiError(ForumErrorKind.NotFound, status, '内容不存在或当前账号无法访问'); }
    if (status >= 300 && status < 400) { throw new ForumApiError(ForumErrorKind.VerificationRequired, status, '社区要求网页跳转，请在网页中完成登录或验证'); }
    if (status < 200 || status >= 300) {
      throw new ForumApiError(writing && status >= 500 ? ForumErrorKind.UnknownResult : ForumErrorKind.Rejected,
        status, writing && status >= 500 ? '提交结果未确认，请刷新后检查' :
          serverValidationMessage(response.body) || '社区拒绝了此次请求，请检查输入与权限');
    }
  }

  private async request(spec: RequestSpec): Promise<string> {
    if (!safeForumUrl(spec.path) || !spec.path.startsWith('/') || spec.path.startsWith('//')) {
      throw new ForumApiError(ForumErrorKind.Rejected, 0, '请求地址不属于 LINUX DO');
    }
    const generation: number = this.sessionGeneration;
    const cancellation: RequestCancellation = spec.cancellation ?? new RequestCancellation();
    const cancel: () => void = (): void => cancellation.cancel();
    spec.cancellation = cancellation;
    this.activeRequests.add(cancel);
    try {
      await this.waitForSlot(cancellation);
      if (this.recoveryTask !== undefined) { await this.waitForRecovery(this.recoveryTask, cancellation); }
      this.ensureSessionGeneration(generation);
      if (cancellation.isCancelled) { throw cancelledError(); }
      const recoveredBeforeRequest: number = this.recoveryVersion;
      try { return await this.sendRequest(spec, generation, cancellation); }
      catch (error) {
        if (!(error instanceof ForumApiError)) {
          const reading: boolean = spec.method === http.RequestMethod.GET;
          throw new ForumApiError(reading ? ForumErrorKind.Network : ForumErrorKind.UnknownResult, 0,
            reading ? '社区请求未完成，请稍后重试' : '提交结果未确认，请刷新后检查，避免重复提交');
        }
        if (error.kind !== ForumErrorKind.VerificationRequired || spec.method !== http.RequestMethod.GET) { throw error; }
        // Another read may have restored this context while the old response was still in flight.
        if ((!this.browserTransportEnabled || this.recoveryVersion === recoveredBeforeRequest) &&
          !await this.recoverReadSession(cancellation)) { throw error; }
        this.ensureSessionGeneration(generation);
        await this.waitForSlot(cancellation);
        this.ensureSessionGeneration(generation);
        if (cancellation.isCancelled) { throw cancelledError(); }
        // Exactly one replay, using the verified browser context. No recursive retries.
        return await this.sendRequest(spec, generation, cancellation);
      }
    } finally { this.activeRequests.delete(cancel); }
  }

  private async sendRequest(spec: RequestSpec, generation: number, cancellation: RequestCancellation): Promise<string> {
    if (spec.requiresForeground && !this.foreground) { throw cancelledError(); }
    const writing: boolean = spec.method !== http.RequestMethod.GET;
    if (writing) { this.writesInFlight++; }
    try {
      const response: BrowserResponse = this.browserTransportEnabled && this.browserTransport && !spec.multipart ?
        await this.browserTransport({ path: spec.path, method: spec.method, body: spec.body ?? '', csrf: spec.csrf ?? '' }, cancellation) :
        await this.nativeRequest(spec);
      this.ensureSessionGeneration(generation);
      if (cancellation.isCancelled) { throw cancelledError(); }
      this.checkResponse(response, writing);
      return response.body;
    } finally { if (writing) { this.writesInFlight--; } }
  }
  private async get(path: string, cancellation?: RequestCancellation): Promise<string> {
    return this.request({ path: path, method: http.RequestMethod.GET, cancellation: cancellation });
  }
  private parse<T extends object>(raw: string): T {
    try { return decodeObject<T>(raw); }
    catch { throw new ForumApiError(ForumErrorKind.InvalidResponse, 0, '社区响应数据不完整，请刷新后重试'); }
  }
  private async mutate(path: string, method: http.RequestMethod, body: string = '', cancellation?: RequestCancellation): Promise<string> {
    const generation: number = this.sessionGeneration;
    const csrf: string = await this.fetchCsrf(cancellation);
    this.ensureSessionGeneration(generation);
    return this.request({ path: path, method: method, body: body, csrf: csrf, cancellation: cancellation });
  }

  async fetchCsrf(cancellation?: RequestCancellation): Promise<string> {
    const response: CsrfWire = this.parse<CsrfWire>(await this.get('/session/csrf.json', cancellation));
    const csrf: string = text(response.csrf);
    if (csrf.length === 0 || /[\r\n]/.test(csrf)) { throw new ForumApiError(ForumErrorKind.InvalidResponse, 0, '无法获取会话保护令牌，请重新登录'); }
    return csrf;
  }
  async recordTopicReadTimings(batch: TopicReadBatch, cancellation: RequestCancellation): Promise<void> {
    validateId(batch.topicId);
    if (!Number.isSafeInteger(batch.ownerId) || batch.ownerId <= 0 ||
      !Number.isSafeInteger(batch.topicTimeMs) || batch.topicTimeMs <= 0 || batch.topicTimeMs > 60000 ||
      !Array.isArray(batch.postTimings) || batch.postTimings.length === 0 || batch.postTimings.length > 100) {
      throw new ForumApiError(ForumErrorKind.Rejected, 0, '阅读记录无效，未提交');
    }
    const timings: Record<string, number> = {};
    batch.postTimings.forEach((timing: TopicReadTiming): void => {
      validateId(timing.postNumber);
      if (!Number.isSafeInteger(timing.milliseconds) || timing.milliseconds <= 0 || timing.milliseconds > batch.topicTimeMs ||
        timings[String(timing.postNumber)] !== undefined) {
        throw new ForumApiError(ForumErrorKind.Rejected, 0, '阅读时间无效，未提交');
      }
      timings[String(timing.postNumber)] = timing.milliseconds;
    });
    this.ensureSessionGeneration(batch.sessionGeneration);
    if (!this.foreground || cancellation.isCancelled) { throw cancelledError(); }
    this.readTimingRequests.add(cancellation);
    try {
      const csrf: string = await this.fetchCsrf(cancellation);
      this.ensureSessionGeneration(batch.sessionGeneration);
      if (!this.foreground || cancellation.isCancelled) { throw cancelledError(); }
      // Discourse TopicsController.timings accepts milliseconds under `timings`,
      // keyed by post number. Its confirmed 2xx response has an empty body.
      // The caller owns cancellation on covering/leaving the reader. No replay.
      const body: TopicReadTimingsBody = { topic_id: batch.topicId, topic_time: batch.topicTimeMs, timings: timings };
      await this.request({ path: '/topics/timings', method: http.RequestMethod.POST,
        body: JSON.stringify(body),
        csrf: csrf, cancellation: cancellation, requiresForeground: true });
    } finally { this.readTimingRequests.delete(cancellation); }
  }
  async fetchCategories(force: boolean = false, cancellation?: RequestCancellation): Promise<Category[]> {
    if (!force && this.categoryCache) { return this.categoryCache; }
    if (!force && this.categoryInFlight && !cancellation) { return this.categoryInFlight; }
    const operation: Promise<Category[]> = this.loadCategories(cancellation);
    if (!cancellation) { this.categoryInFlight = operation; }
    try { return await operation; }
    finally { if (this.categoryInFlight === operation) { this.categoryInFlight = undefined; } }
  }
  private async loadCategories(cancellation?: RequestCancellation): Promise<Category[]> {
    const generation: number = this.sessionGeneration;
    const response: CategoryResponseWire = this.parse<CategoryResponseWire>(await this.get('/categories.json?include_subcategories=true', cancellation));
    this.ensureSessionGeneration(generation);
    if (!response.category_list || !Array.isArray(response.category_list.categories)) {
      throw new ForumApiError(ForumErrorKind.InvalidResponse, 0, '社区未返回分类列表');
    }
    const categories: Category[] = response.category_list.categories.map((category): Category => categoryFromWire(category));
    this.categoryCache = categories;
    return categories;
  }
  cachedCategories(): Category[] { return this.categoryCache ?? []; }
  /** /tags.json returns the complete permission-filtered catalog, including grouped tags. */
  async fetchDirectoryTags(query: string = '', page: number = 0, cancellation?: RequestCancellation,
    alphabetical: boolean = false, force: boolean = false): Promise<DirectoryTagPage> {
    validateCursor(page);
    if (query.length > 200) { throw new ForumApiError(ForumErrorKind.Rejected, 0, '标签搜索内容过长'); }
    if (cancellation?.isCancelled) { throw cancelledError(); }
    const generation: number = this.sessionGeneration;
    let tags: DirectoryTag[] | undefined = force ? undefined : this.directoryTagsCache;
    if (tags === undefined || Date.now() - this.directoryTagsLoadedAt > 300000) {
      const response: DirectoryTagsResponseWire = this.parse<DirectoryTagsResponseWire>(await this.get('/tags.json', cancellation));
      this.ensureSessionGeneration(generation);
      if (cancellation?.isCancelled) { throw cancelledError(); }
      if (!Array.isArray(response.tags)) {
        throw new ForumApiError(ForumErrorKind.InvalidResponse, 0, '社区未返回标签目录');
      }
      tags = directoryTagsFromWire(response);
      this.directoryTagsCache = tags; this.directoryTagsLoadedAt = Date.now();
    }
    this.ensureSessionGeneration(generation);
    return directoryTagPage(tags, query, page, alphabetical);
  }
  async fetchDirectoryBadges(cancellation?: RequestCancellation): Promise<DirectoryBadge[]> {
    const generation: number = this.sessionGeneration;
    const response: DirectoryBadgesResponseWire = this.parse<DirectoryBadgesResponseWire>(await this.get('/badges.json?only_listable=true', cancellation));
    this.ensureSessionGeneration(generation);
    if (cancellation?.isCancelled) { throw cancelledError(); }
    if (!Array.isArray(response.badges)) {
      throw new ForumApiError(ForumErrorKind.InvalidResponse, 0, '社区未返回徽章目录');
    }
    return directoryBadgesFromWire(response);
  }
  async fetchDirectoryGroups(query: string = '', page: number = 0, cancellation?: RequestCancellation): Promise<DirectoryGroupPage> {
    validateCursor(page);
    if (query.length > 200) { throw new ForumApiError(ForumErrorKind.Rejected, 0, '群组搜索内容过长'); }
    const generation: number = this.sessionGeneration;
    const path: string = `/groups.json?page=${page}&order=name&asc=true&filter=${encodeURIComponent(query.trim())}`;
    const response: DirectoryGroupsResponseWire = this.parse<DirectoryGroupsResponseWire>(await this.get(path, cancellation));
    this.ensureSessionGeneration(generation);
    if (cancellation?.isCancelled) { throw cancelledError(); }
    if (!Array.isArray(response.groups)) {
      throw new ForumApiError(ForumErrorKind.InvalidResponse, 0, '社区未返回群组目录');
    }
    return directoryGroupsFromWire(response);
  }
  async fetchCreateTopicCategories(cancellation?: RequestCancellation): Promise<Category[]> {
    const generation: number = this.sessionGeneration;
    // Permissions are account-scoped and can change while the composer is open.
    const categories: Category[] = await this.fetchCategories(true, cancellation);
    this.ensureSessionGeneration(generation);
    if (cancellation?.isCancelled) { throw cancelledError(); }
    return flattenCategories(categories).filter((category: Category): boolean => category.canCreateTopic === true);
  }
  private topicPage(response: TopicListResponseWire): TopicPage {
    if (!response.topic_list || !Array.isArray(response.topic_list.topics)) {
      throw new ForumApiError(ForumErrorKind.InvalidResponse, 0, '社区未返回话题列表');
    }
    const users: DiscourseUser[] = list(response.users).map((user: UserWire): DiscourseUser => userFromWire(user));
    const categories: Category[] = flattenCategories(this.categoryCache ?? []);
    const items: TopicListItem[] = response.topic_list.topics.map((wire): TopicListItem => {
      const topic: Topic = topicFromWire(wire);
      const firstUserId: number = topic.posters.length > 0 ? topic.posters[0].userId : 0;
      const author: DiscourseUser | undefined = users.find((user: DiscourseUser): boolean => user.id === firstUserId);
      return { topic: topic, authorUsername: author?.username ?? topic.lastPosterUsername,
        avatarUrl: author?.avatarUrl ?? '', category: categories.find((category: Category): boolean => category.id === topic.categoryId) };
    });
    return { items: items, hasMore: text(response.topic_list.more_topics_url).length > 0 && items.length > 0 };
  }
  async fetchLatest(page: number = 0, cancellation?: RequestCancellation): Promise<TopicPage> {
    return this.fetchTopicFeed(TopicFeedFilter.Latest, page, cancellation);
  }
  async fetchTopicFeed(filter: TopicFeedFilter, page: number = 0, cancellation?: RequestCancellation,
    options?: TopicBrowseOptions): Promise<TopicPage> {
    validateCursor(page);
    if (filter !== TopicFeedFilter.Latest && filter !== TopicFeedFilter.New && filter !== TopicFeedFilter.Unread &&
      filter !== TopicFeedFilter.Hot && filter !== TopicFeedFilter.Top) {
      throw new ForumApiError(ForumErrorKind.Rejected, 0, '话题筛选不受支持');
    }
    const period: string = options?.topPeriod || 'weekly';
    if (['daily', 'weekly', 'monthly', 'quarterly', 'yearly', 'all'].indexOf(period) < 0 ||
      (options !== undefined && (!Number.isSafeInteger(options.categoryId) || options.categoryId < 0 ||
      options.tagName.length > 100 || /[\u0000-\u001f\u007f]/.test(options.tagName) ||
      ['', 'activity', 'created', 'posts', 'likes', 'views'].indexOf(options.sortOrder) < 0))) {
      throw new ForumApiError(ForumErrorKind.Rejected, 0, '话题筛选条件无效');
    }
    // Carry the same taxonomy, sort and ranking period through every page.
    let suffix: string = filter === TopicFeedFilter.Top ? `&period=${period}` : '';
    if (options !== undefined) {
      if (options.categoryId > 0) { suffix += `&category=${options.categoryId}`; }
      if (options.tagName.length > 0) { suffix += `&tags%5B%5D=${encodeURIComponent(options.tagName)}`; }
      if (options.sortOrder.length > 0) { suffix += `&order=${options.sortOrder}&ascending=false`; }
    }
    try {
      return this.topicPage(this.parse<TopicListResponseWire>(await this.get(`/${filter}.json?page=${page}${suffix}`, cancellation)));
    } catch (error) {
      if (error instanceof ForumApiError && error.kind === ForumErrorKind.NotFound) {
        throw new ForumApiError(ForumErrorKind.Unsupported, error.status, '社区暂未开放此话题筛选，请切换其他标签。');
      }
      if (error instanceof Error) { throw error; }
      throw new ForumApiError(ForumErrorKind.Network, 0, '话题暂时无法加载，请稍后重试。');
    }
  }
  private canonicalCategoryPath(categoryId: number, categories: Category[]): string {
    const byId: Map<number, Category> = new Map<number, Category>();
    flattenCategories(categories).forEach((category: Category): void => { byId.set(category.id, category); });
    const segments: string[] = [];
    const seen: Set<number> = new Set<number>();
    let current: Category | undefined = byId.get(categoryId);
    for (let depth: number = 0; depth < 16; depth++) {
      if (!current || seen.has(current.id)) {
        throw new ForumApiError(ForumErrorKind.InvalidResponse, 0, '分类路径不完整，请刷新分类后重试');
      }
      seen.add(current.id);
      segments.unshift(encodeURIComponent(current.slug || `${current.id}-category`));
      if (current.parentCategoryId === 0) { return `/c/${segments.join('/')}/${categoryId}.json`; }
      current = byId.get(current.parentCategoryId);
    }
    throw new ForumApiError(ForumErrorKind.InvalidResponse, 0, '分类层级异常，请刷新分类后重试');
  }
  async fetchCategoryTopics(slug: string, categoryId: number, page: number = 0, cancellation?: RequestCancellation): Promise<TopicPage> {
    validateId(categoryId); validateCursor(page);
    const generation: number = this.sessionGeneration;
    const categories: Category[] = await this.fetchCategories(false, cancellation);
    this.ensureSessionGeneration(generation);
    if (cancellation?.isCancelled) { throw cancelledError(); }
    // A category's API slug is only one segment. Discourse's canonical path
    // includes every parent slug; the cached tree is authoritative over a stale UI slug.
    const path: string = this.canonicalCategoryPath(categoryId, categories);
    return this.topicPage(this.parse<TopicListResponseWire>(await this.get(`${path}?page=${page}`, cancellation)));
  }
  async fetchTopic(id: number, postNumber?: number, cancellation?: RequestCancellation): Promise<TopicDetail> {
    validateId(id);
    if (postNumber !== undefined) { validateId(postNumber); }
    const position: string = postNumber !== undefined && postNumber > 1 ? '/' + postNumber : '';
    return detailFromWire(this.parse<TopicDetailWire>(await this.get(`/t/${id}${position}.json?track_visit=false`, cancellation)));
  }
  async fetchPosts(topicId: number, ids: number[], cancellation?: RequestCancellation): Promise<Post[]> {
    validateId(topicId);
    if (ids.length < 1 || ids.length > 20) { throw new ForumApiError(ForumErrorKind.Rejected, 0, '每次只能加载 1 至 20 个楼层'); }
    ids.forEach((id: number): void => validateId(id));
    const query: string = ids.map((id: number): string => `post_ids%5B%5D=${id}`).join('&');
    const response: PostStreamResponseWire = this.parse<PostStreamResponseWire>(await this.get(`/t/${topicId}/posts.json?${query}&track_visit=false`, cancellation));
    if (!response.post_stream) { throw new ForumApiError(ForumErrorKind.InvalidResponse, 0, '社区未返回楼层'); }
    return streamFromWire(response.post_stream).posts;
  }
  async fetchReplies(postId: number, after: number = 0, cancellation?: RequestCancellation): Promise<Post[]> {
    validateId(postId); validateCursor(after);
    const body: string = await this.get(`/posts/${postId}/replies.json?after=${after}`, cancellation);
    let posts: PostWire[];
    if (body.trim().startsWith('[')) { posts = decodeArray<PostWire>(body); }
    else {
      const response: PostStreamResponseWire = this.parse<PostStreamResponseWire>(body);
      posts = list(response.post_stream?.posts ?? response.replies ?? response.posts);
    }
    return posts.map((post: PostWire): Post => postFromWire(post));
  }
  async fetchCurrentUser(cancellation?: RequestCancellation): Promise<DiscourseUser | undefined> {
    try {
      const response: CurrentUserWire = this.parse<CurrentUserWire>(await this.get('/session/current.json', cancellation));
      return response.current_user ? userFromWire(response.current_user) : undefined;
    } catch (error) {
      if (error instanceof ForumApiError) {
        if (error.status === 404 || error.status === 401) { return undefined; }
        throw error;
      }
      throw new ForumApiError(ForumErrorKind.InvalidResponse, 0, '社区未返回有效的登录用户信息');
    }
  }
  async search(query: string, page: number = 1, order: SearchOrder = SearchOrder.Relevance, cancellation?: RequestCancellation): Promise<SearchPage> {
    const generation: number = this.sessionGeneration;
    validateCursor(page);
    const trimmed: string = query.trim();
    if (trimmed.length === 0 || trimmed.length > 1000) { throw new ForumApiError(ForumErrorKind.Rejected, 0, '请输入有效的搜索词'); }
    const ordered: string = order === SearchOrder.Relevance ? trimmed : trimmed.replace(/(?:^|\s)order:\S+/g, ' ').trim() + ' order:' + order;
    const response: SearchResponseWire = this.parse<SearchResponseWire>(await this.get(`/search.json?q=${encodeURIComponent(ordered)}&page=${page}`, cancellation));
    this.ensureSessionGeneration(generation);
    if (cancellation?.isCancelled) { throw cancelledError(); }
    const posts: Post[] = list(response.posts).map((post: PostWire): Post => postFromWire(post));
    const categories: Category[] = flattenCategories(this.categoryCache ?? []);
    const excerpts: Map<number, string> = new Map<number, string>();
    const postNumbers: Map<number, number> = new Map<number, number>();
    const items: TopicListItem[] = list(response.topics).map((wire): TopicListItem => {
      const topic: Topic = topicFromWire(wire);
      const post: Post | undefined = posts.find((item: Post): boolean => item.topicId === topic.id);
      excerpts.set(topic.id, post?.blurb ?? '');
      const postNumber: number = post?.postNumber ?? 1;
      postNumbers.set(topic.id, Number.isSafeInteger(postNumber) && postNumber > 0 ? postNumber : 1);
      return { topic: topic, authorUsername: post?.username ?? '', avatarUrl: post?.avatarUrl ?? '',
        category: categories.find((category: Category): boolean => category.id === topic.categoryId) };
    });
    const postMatches: ForumSearchPostMatch[] = posts.filter((post: Post): boolean => post.topicId > 0 && post.postNumber > 0)
      .map((post: Post): ForumSearchPostMatch => {
        return { id: `${post.topicId}:${post.id}:${post.postNumber}`, topicId: post.topicId, postNumber: post.postNumber,
          username: post.username, avatarUrl: post.avatarUrl, excerpt: plainText(post.blurb || post.cooked), createdAt: post.createdAt };
      });
    return { items: items, excerpts: excerpts, postNumbers: postNumbers, postMatches: postMatches,
      hasMore: bool(response.grouped_search_result?.more_full_page_results) && items.length > 0 };
  }

  async fetchNotifications(offset: number = 0, filter: NotificationFilter = NotificationFilter.All,
    cancellation?: RequestCancellation): Promise<NotificationPage> {
    const generation: number = this.sessionGeneration;
    validateCursor(offset);
    const notifications: ForumNotification[] = [];
    const seen: Set<number> = new Set<number>();
    let nextOffset: number = offset;
    let hasMore: boolean = true;
    let rounds: number = 0;
    // Discourse only applies filter_by_types to recent=true, which has no history
    // pagination. History is filtered locally; stop at the first matching page.
    // A bounded empty batch with hasMore=true must remain resumable by the caller.
    while (hasMore && notifications.length === 0 && rounds < 5) {
      if (cancellation?.isCancelled) { throw cancelledError(); }
      rounds++;
      const response: NotificationResponseWire = this.parse<NotificationResponseWire>(
        await this.get(`/notifications.json?offset=${nextOffset}&limit=60`, cancellation));
      this.ensureSessionGeneration(generation);
      if (cancellation?.isCancelled) { throw cancelledError(); }
      if (!Array.isArray(response.notifications)) { throw new ForumApiError(ForumErrorKind.InvalidResponse, 0, '社区未返回通知列表'); }
      nextOffset += 60;
      const total: number = numberValue(response.total_rows_notifications, -1);
      hasMore = total >= 0 ? nextOffset < total : response.notifications.length >= 60;
      let freshCount: number = 0;
      response.notifications.forEach((wire): void => {
        const notification: ForumNotification = notificationFromWire(wire);
        if (seen.has(notification.id)) { return; }
        seen.add(notification.id); freshCount++;
        if (notificationIncludes(filter, notification.type)) { notifications.push(notification); }
      });
      if (response.notifications.length > 0 && freshCount === 0) {
        throw new ForumApiError(ForumErrorKind.InvalidResponse, 0, '通知分页未推进，请稍后刷新');
      }
    }
    return { notifications: notifications, hasMore: hasMore, nextOffset: nextOffset };
  }
  async fetchUnreadSummary(cancellation?: RequestCancellation): Promise<UnreadSummary> {
    const generation: number = this.sessionGeneration;
    const seen: Set<number> = new Set<number>();
    const filters: NotificationFilter[] = [NotificationFilter.All, NotificationFilter.Replies, NotificationFilter.Likes, NotificationFilter.Messages];
    const byFilter: Map<NotificationFilter, number> = new Map<NotificationFilter, number>();
    filters.forEach((filter: NotificationFilter): void => { byFilter.set(filter, 0); });
    let offset: number = 0;
    let count: number = 0;
    for (let round: number = 0; round < 100; round++) {
      const response: NotificationResponseWire = this.parse<NotificationResponseWire>(
        await this.get(`/notifications.json?filter=unread&limit=60&offset=${offset}`, cancellation));
      this.ensureSessionGeneration(generation);
      if (!Array.isArray(response.notifications)) { throw new ForumApiError(ForumErrorKind.InvalidResponse, 0, '社区未返回未读通知'); }
      let freshCount: number = 0;
      response.notifications.forEach((wire): void => {
        const notice: ForumNotification = notificationFromWire(wire);
        if (seen.has(notice.id)) { return; }
        seen.add(notice.id); freshCount++;
        if (notice.read) { return; }
        if (notificationIncludes(NotificationFilter.Replies, notice.type) || notificationIncludes(NotificationFilter.Messages, notice.type)) { count++; }
        filters.forEach((filter: NotificationFilter): void => {
          if (notificationIncludes(filter, notice.type)) { byFilter.set(filter, (byFilter.get(filter) ?? 0) + 1); }
        });
      });
      if (response.notifications.length > 0 && freshCount === 0) { throw new ForumApiError(ForumErrorKind.InvalidResponse, 0, '未读通知分页未推进，请稍后刷新'); }
      offset += 60;
      const total: number = numberValue(response.total_rows_notifications, -1);
      const hasMore: boolean = total >= 0 ? offset < total : response.notifications.length >= 60;
      if (!hasMore) {
        return { count: count, unreadFilters: filters.filter((filter: NotificationFilter): boolean => (byFilter.get(filter) ?? 0) > 0), unreadByFilter: byFilter };
      }
    }
    throw new ForumApiError(ForumErrorKind.InvalidResponse, 0, '未读通知数量过多，请在网页中检查');
  }
  async unreadCount(cancellation?: RequestCancellation): Promise<number> { return (await this.fetchUnreadSummary(cancellation)).count; }
  async markNotificationRead(id: number, cancellation?: RequestCancellation): Promise<void> {
    validateId(id);
    const body: IdBody = { id: id };
    await this.mutate('/notifications/mark-read.json', http.RequestMethod.PUT, JSON.stringify(body), cancellation);
  }
  async fetchPostRaw(postId: number, cancellation?: RequestCancellation): Promise<string> {
    validateId(postId);
    const response: PostWire = this.parse<PostWire>(await this.get(`/posts/${postId}.json`, cancellation));
    if (typeof response.raw !== 'string') { throw new ForumApiError(ForumErrorKind.InvalidResponse, 0, '社区未返回可编辑的原文'); }
    return response.raw;
  }
  async fetchPostRevision(postId: number, revision: number = 0, cancellation?: RequestCancellation): Promise<PostRevisionRecord> {
    validateId(postId);
    if (!Number.isSafeInteger(revision) || (revision !== 0 && revision < 2)) {
      throw new ForumApiError(ForumErrorKind.Rejected, 0, '无效的历史版本');
    }
    const target: string = revision === 0 ? 'latest' : String(revision);
    const response: PostRevisionWire = this.parse<PostRevisionWire>(await this.get(`/posts/${postId}/revisions/${target}.json`, cancellation));
    try { return postRevisionFromWire(response, postId, revision); }
    catch { throw new ForumApiError(ForumErrorKind.InvalidResponse, 0, '编辑历史数据不完整，请刷新后重试'); }
  }
  async createPost(topicId: number, raw: string, replyToPostNumber?: number, cancellation?: RequestCancellation): Promise<Post> {
    validateId(topicId);
    const body: CreatePostBody = { topic_id: topicId, raw: validateRaw(raw) };
    if (replyToPostNumber !== undefined) { validateId(replyToPostNumber); body.reply_to_post_number = replyToPostNumber; }
    return postFromWire(this.parse<PostWire>(await this.mutate('/posts.json', http.RequestMethod.POST, JSON.stringify(body), cancellation)));
  }
  async createTopic(title: string, raw: string, categoryId: number, tags: string[] = [],
    cancellation?: RequestCancellation): Promise<TopicCreationResult> {
    const generation: number = this.sessionGeneration;
    validateId(categoryId);
    const cleanTitle: string = title.trim();
    const cleanRaw: string = raw.trim();
    if (cleanTitle.length === 0) { throw new ForumApiError(ForumErrorKind.Rejected, 0, '标题不能为空'); }
    if (cleanRaw.length === 0) { throw new ForumApiError(ForumErrorKind.Rejected, 0, '正文不能为空'); }
    const names: string[] = [];
    tags.forEach((tag: string): void => {
      const name: string = tag.trim();
      if (name.length > 0 && !names.includes(name)) { names.push(name); }
    });
    const body: CreateTopicBody = { title: cleanTitle, raw: cleanRaw, category: categoryId,
      tags: names.map((name: string): CreateTopicTagBody => { return { name: name }; }), nested_post: true };
    const rawResponse: string = await this.mutate('/posts.json', http.RequestMethod.POST, JSON.stringify(body), cancellation);
    this.ensureSessionGeneration(generation);
    if (cancellation?.isCancelled) { throw cancelledError(); }
    let response: TopicCreationWire;
    try { response = decodeObject<TopicCreationWire>(rawResponse); }
    catch { throw new ForumApiError(ForumErrorKind.UnknownResult, 0, '发帖结果未确认，请先检查个人话题，避免重复发布'); }
    const validationMessage: string = serverValidationMessage(rawResponse);
    if (response.success === false || validationMessage.length > 0) {
      throw new ForumApiError(ForumErrorKind.Rejected, 0, validationMessage || '社区拒绝了此次发帖，请检查输入与权限');
    }
    if (response.action === 'enqueued' && response.success === true) {
      return { queued: true, topicId: 0, postNumber: 0,
        pendingCount: Math.max(0, numberValue(response.pending_count)) };
    }
    const post: PostWire = response.post ?? response;
    const topicId: number = numberValue(post.topic_id);
    const postId: number = numberValue(post.id);
    if ((response.action === undefined || response.action === 'create_post') &&
      (response.post === undefined || response.success === true) &&
      Number.isSafeInteger(topicId) && topicId > 0 && Number.isSafeInteger(postId) && postId > 0 && post.post_number === 1) {
      return { queued: false, topicId: topicId, postNumber: 1, pendingCount: 0 };
    }
    throw new ForumApiError(ForumErrorKind.UnknownResult, 0, '发帖结果未确认，请先检查个人话题，避免重复发布');
  }
  async updatePost(postId: number, raw: string, cancellation?: RequestCancellation): Promise<Post> {
    validateId(postId);
    const body: EditPostBody = { post: { raw: validateRaw(raw) } };
    const response: PostResponseWire = this.parse<PostResponseWire>(await this.mutate(`/posts/${postId}.json`, http.RequestMethod.PUT, JSON.stringify(body), cancellation));
    if (!response.post) { throw new ForumApiError(ForumErrorKind.InvalidResponse, 0, '编辑结果缺少楼层，请刷新后确认'); }
    return postFromWire(response.post);
  }
  async deletePost(postId: number, cancellation?: RequestCancellation): Promise<void> {
    validateId(postId); await this.mutate(`/posts/${postId}.json`, http.RequestMethod.DELETE, '', cancellation);
  }
  async setTopicNotificationLevel(topicId: number, level: number, cancellation?: RequestCancellation): Promise<void> {
    validateId(topicId);
    if (!Number.isInteger(level) || level < 0 || level > 3) {
      throw new ForumApiError(ForumErrorKind.Rejected, 0, '话题通知级别无效');
    }
    const body: TopicNotificationBody = { notification_level: level };
    const raw: string = await this.mutate(`/t/${topicId}/notifications.json`, http.RequestMethod.POST,
      JSON.stringify(body), cancellation);
    let response: BookmarkMutationWire;
    try { response = decodeObject<BookmarkMutationWire>(raw); }
    catch { throw new ForumApiError(ForumErrorKind.UnknownResult, 0, '通知设置结果未确认，请重新打开话题核对'); }
    if (response.success !== 'OK' && response.success !== true) {
      throw new ForumApiError(response.success === false ? ForumErrorKind.Rejected : ForumErrorKind.UnknownResult,
        0, serverValidationMessage(raw) || '通知设置结果未确认，请重新打开话题核对');
    }
  }
  async createPostBookmark(postId: number, cancellation?: RequestCancellation): Promise<number> {
    validateId(postId);
    const body: BookmarkPostBody = { bookmarkable_id: postId, bookmarkable_type: 'Post' };
    const raw: string = await this.mutate('/bookmarks.json', http.RequestMethod.POST, JSON.stringify(body), cancellation);
    let response: BookmarkMutationWire;
    try { response = decodeObject<BookmarkMutationWire>(raw); }
    catch { throw new ForumApiError(ForumErrorKind.UnknownResult, 0, '收藏结果未确认，请刷新帖子或查看我的收藏，避免重复提交'); }
    if (response.success === false) {
      throw new ForumApiError(ForumErrorKind.Rejected, 0, serverValidationMessage(raw) || '社区未接受此次收藏');
    }
    const id: number = numberValue(response.id);
    if ((response.success !== true && response.success !== 'OK') || !Number.isSafeInteger(id) || id <= 0) {
      throw new ForumApiError(ForumErrorKind.UnknownResult, 0, '收藏结果未确认，请刷新帖子或查看我的收藏，避免重复提交');
    }
    return id;
  }
  async flagPost(postId: number, actionType: number, message: string, cancellation?: RequestCancellation): Promise<Post> {
    validateId(postId);
    if ([3, 4, 7, 8].indexOf(actionType) < 0 || message.length > 8000 || (actionType === 8 && !message.trim())) {
      throw new ForumApiError(ForumErrorKind.Rejected, 0, '请选择举报原因，并填写必要的说明');
    }
    const body: PostFlagBody = { id: postId, post_action_type_id: actionType, message: message.trim() };
    const raw: string = await this.mutate('/post_actions.json', http.RequestMethod.POST, JSON.stringify(body), cancellation);
    try {
      const response: PostWire = this.parse<PostWire>(raw);
      if (response.id !== postId || numberValue(response.topic_id) <= 0 || numberValue(response.post_number) <= 0 ||
        typeof response.cooked !== 'string') { throw new Error('Unconfirmed flag receipt'); }
      return postFromWire(response);
    } catch {
      throw new ForumApiError(ForumErrorKind.UnknownResult, 0, '举报结果未确认，请先核对楼层状态，避免重复提交');
    }
  }
  async deleteBookmark(bookmarkId: number, cancellation?: RequestCancellation): Promise<void> {
    validateId(bookmarkId);
    const raw: string = await this.mutate(`/bookmarks/${bookmarkId}.json`, http.RequestMethod.DELETE, '', cancellation);
    let response: BookmarkMutationWire;
    try { response = decodeObject<BookmarkMutationWire>(raw); }
    catch { throw new ForumApiError(ForumErrorKind.UnknownResult, 0, '取消收藏结果未确认，请刷新帖子或查看我的收藏'); }
    if (response.success === false) {
      throw new ForumApiError(ForumErrorKind.Rejected, 0, serverValidationMessage(raw) || '社区未接受此次取消收藏');
    }
    if (response.success !== true && response.success !== 'OK') {
      throw new ForumApiError(ForumErrorKind.UnknownResult, 0, '取消收藏结果未确认，请刷新帖子或查看我的收藏');
    }
  }
  async toggleReaction(postId: number, reaction: string, cancellation?: RequestCancellation): Promise<Post> {
    validateId(postId);
    if (!/^[a-zA-Z0-9_+:\-]+$/.test(reaction)) { throw new ForumApiError(ForumErrorKind.Rejected, 0, '无效的表情回应'); }
    const raw: string = await this.mutate(
      `/discourse-reactions/posts/${postId}/custom-reactions/${encodeURIComponent(reaction)}/toggle.json`, http.RequestMethod.PUT, '', cancellation);
    try {
      const wire: PostWire = this.parse<PostWire>(raw);
      if (wire.id !== postId || numberValue(wire.topic_id) <= 0 || numberValue(wire.post_number) <= 0 ||
        typeof wire.cooked !== 'string' || !Array.isArray(wire.reactions) || wire.current_user_reaction === undefined) {
        throw new Error('Incomplete reaction result');
      }
      const post: Post = postFromWire(wire);
      return post;
    } catch {
      // A successful HTTP write with a malformed receipt is not safe to repeat:
      // this endpoint toggles, so repeating it could undo the original action.
      throw new ForumApiError(ForumErrorKind.UnknownResult, 0, '回应结果未确认，请刷新帖子后查看，避免重复提交');
    }
  }
  async createBoost(postId: number, raw: string, cancellation?: RequestCancellation): Promise<Boost> {
    validateId(postId);
    if (!measureBoost(raw).submittable) { throw new ForumApiError(ForumErrorKind.Rejected, 0, '简评最多 16 个可见字符、5 个表情'); }
    const body: RawPostBody = { raw: raw.trim() };
    return boostFromWire(this.parse<BoostWire>(await this.mutate(`/discourse-boosts/posts/${postId}/boosts.json`, http.RequestMethod.POST, JSON.stringify(body), cancellation)));
  }
  async deleteBoost(boostId: number, cancellation?: RequestCancellation): Promise<void> {
    validateId(boostId); await this.mutate(`/discourse-boosts/boosts/${boostId}.json`, http.RequestMethod.DELETE, '', cancellation);
  }
  async setSolution(postId: number, accepted: boolean, cancellation?: RequestCancellation): Promise<void> {
    validateId(postId);
    const body: IdBody = { id: postId };
    await this.mutate(`/solution/${accepted ? 'accept' : 'unaccept'}.json`, http.RequestMethod.POST, JSON.stringify(body), cancellation);
  }
  async uploadFile(fileName: string, mimeType: string, bytes: ArrayBuffer, cancellation?: RequestCancellation): Promise<UploadedFile> {
    const generation: number = this.sessionGeneration;
    const extension: string = fileName.split('.').pop()?.toLowerCase() ?? '';
    if (!fileName || /[\r\n"\/\\]/.test(fileName) || UPLOAD_EXTENSIONS.indexOf(extension) < 0) {
      throw new ForumApiError(ForumErrorKind.Rejected, 0, '不支持的文件类型或文件名');
    }
    if (bytes.byteLength === 0 || bytes.byteLength > UPLOAD_MAX_BYTES) { throw new ForumApiError(ForumErrorKind.Rejected, 0, '文件需大于 0 字节且不超过 4 MB'); }
    if (!/^[a-zA-Z0-9.+\-]+\/[a-zA-Z0-9.+\-]+$/.test(mimeType)) { throw new ForumApiError(ForumErrorKind.Rejected, 0, '无效的文件类型'); }
    const multipart: http.MultiFormData[] = [
      { name: 'type', contentType: 'text/plain', data: 'composer' },
      { name: 'synchronous', contentType: 'text/plain', data: 'true' },
      { name: 'files[]', contentType: mimeType, remoteFileName: fileName, data: bytes }
    ];
    const csrf: string = await this.fetchCsrf(cancellation);
    this.ensureSessionGeneration(generation);
    const response: UploadResponseWire = this.parse<UploadResponseWire>(await this.request({
      path: '/uploads.json', method: http.RequestMethod.POST, csrf: csrf, multipart: multipart, cancellation: cancellation
    }));
    const url: string = text(response.short_url) || text(response.url);
    if (!/^upload:\/\/[a-zA-Z0-9_.\-]+$/.test(url) && !safeForumUrl(url)) {
      throw new ForumApiError(ForumErrorKind.InvalidResponse, 0, '上传结果缺少安全的文件地址，请刷新后确认');
    }
    return { shortUrl: url, fileName: text(response.original_filename, fileName), width: numberValue(response.width), height: numberValue(response.height) };
  }

  private readLoginResponse(response: LoginResponseWire, tokenProvided: boolean, emailFlow: boolean = false): void {
    const totp: boolean = bool(response.totp_enabled);
    const backup: boolean = bool(response.backup_enabled);
    const required: boolean = totp || backup || bool(response.second_factor_required) ||
      response.multiple_second_factor_methods !== undefined || text(response.reason) === 'invalid_second_factor';
    if (required && !tokenProvided) {
      throw new ForumApiError(ForumErrorKind.SecondFactorRequired, 200, '该账号已开启两步验证，请输入验证码', 0,
        totp || !backup, backup || (emailFlow && !totp && !backup));
    }
    if (required || text(response.error).length > 0) {
      throw new ForumApiError(ForumErrorKind.Rejected, 200, tokenProvided ? '两步验证码错误或已过期，请重试' : '登录未成功，请检查账号和密码');
    }
  }
  async loginWithPassword(login: string, password: string, secondFactorToken?: string, method: number = 1,
    cancellation?: RequestCancellation): Promise<boolean> {
    if (!login.trim() || !password || (method !== 1 && method !== 2)) { throw new ForumApiError(ForumErrorKind.Rejected, 0, '请填写账号、密码和正确的验证方式'); }
    const body: PasswordLoginBody = { login: login.trim(), password: password, second_factor_method: method };
    const token: string = secondFactorToken?.trim() ?? '';
    if (token) { body.second_factor_token = token; }
    const response: LoginResponseWire = this.parse<LoginResponseWire>(await this.mutate('/session.json', http.RequestMethod.POST, JSON.stringify(body), cancellation));
    this.readLoginResponse(response, token.length > 0);
    return response.user !== undefined;
  }
  async sendLoginEmail(email: string, cancellation?: RequestCancellation): Promise<void> {
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email.trim())) { throw new ForumApiError(ForumErrorKind.Rejected, 0, '请输入有效的邮箱地址'); }
    const body: EmailLoginBody = { login: email.trim() };
    const raw: string = await this.mutate('/u/email-login.json', http.RequestMethod.POST, JSON.stringify(body), cancellation);
    if (raw.trim().length > 0) {
      const response: LoginResponseWire = this.parse<LoginResponseWire>(raw);
      if (text(response.error).length > 0) { throw new ForumApiError(ForumErrorKind.Rejected, 200, '登录邮件未发送，请稍后重试'); }
    }
  }
  async loginWithEmailCode(token: string, email?: string, secondFactorToken?: string, method: number = 1,
    cancellation?: RequestCancellation): Promise<void> {
    // The endpoint uses only the token; email remains a UI aid and is not sent.
    if (email !== undefined && email.length > 320) { throw new ForumApiError(ForumErrorKind.Rejected, 0, '邮箱地址过长'); }
    const cleanToken: string = token.trim();
    if (!/^[a-zA-Z0-9_\-]{6,256}$/.test(cleanToken) || (method !== 1 && method !== 2)) {
      throw new ForumApiError(ForumErrorKind.Rejected, 0, '登录码格式不正确，请复制邮件中的登录码');
    }
    const body: TwoFactorBody = { second_factor_method: method };
    const factor: string = secondFactorToken?.trim() ?? '';
    if (factor) { body.second_factor_token = factor; }
    const raw: string = await this.mutate(`/session/email-login/${encodeURIComponent(cleanToken)}`, http.RequestMethod.POST, JSON.stringify(body), cancellation);
    if (raw.trim()) { this.readLoginResponse(this.parse<LoginResponseWire>(raw), factor.length > 0, true); }
  }
  async logout(): Promise<void> {
    // Matches the Android source: leave the local session, clear app-owned cookies.
    this.resetSessionContext();
    this.browserTransportEnabled = false;
    await webview.WebCookieManager.clearAllCookies();
  }

  private publicProfileUsername(username: string): string {
    const clean: string = username.trim().replace(/^@/, '');
    if (!/^[\p{L}\p{N}_.-]{1,60}$/u.test(clean)) {
      throw new ForumApiError(ForumErrorKind.Rejected, 0, '无效的社区用户名');
    }
    return clean;
  }
  async fetchUserProfile(username: string, cancellation?: RequestCancellation): Promise<ForumUserProfile> {
    const clean: string = this.publicProfileUsername(username);
    const generation: number = this.sessionGeneration;
    // Public profile inspection must not register a visit to another member.
    const response: ForumUserProfileResponseWire = this.parse<ForumUserProfileResponseWire>(
      await this.get(`/u/${encodeURIComponent(clean)}.json?skip_track_visit=true`, cancellation));
    this.ensureSessionGeneration(generation);
    if (cancellation?.isCancelled) { throw cancelledError(); }
    if (!response.user || numberValue(response.user.id) <= 0 || text(response.user.username).toLocaleLowerCase() !== clean.toLocaleLowerCase()) {
      throw new ForumApiError(ForumErrorKind.InvalidResponse, 0, '社区未返回此用户的资料');
    }
    return forumUserProfileFromWire(response.user);
  }
  async fetchUserProfileSummary(username: string, cancellation?: RequestCancellation): Promise<ForumUserSummary> {
    const clean: string = this.publicProfileUsername(username);
    const generation: number = this.sessionGeneration;
    const response: ForumUserSummaryResponseWire = this.parse<ForumUserSummaryResponseWire>(
      await this.get(`/u/${encodeURIComponent(clean)}/summary.json`, cancellation));
    this.ensureSessionGeneration(generation);
    if (cancellation?.isCancelled) { throw cancelledError(); }
    if (!response.user_summary) { throw new ForumApiError(ForumErrorKind.InvalidResponse, 0, '社区未返回此用户的统计'); }
    return forumUserSummaryFromWire(response.user_summary);
  }
  async fetchUserProfileActivity(username: string, filter: ForumUserActivityFilter = ForumUserActivityFilter.Topics,
    offset: number = 0, cancellation?: RequestCancellation): Promise<ForumUserActivityPage> {
    const clean: string = this.publicProfileUsername(username);
    validateCursor(offset);
    if (filter !== ForumUserActivityFilter.Topics && filter !== ForumUserActivityFilter.Replies && filter !== ForumUserActivityFilter.All) {
      throw new ForumApiError(ForumErrorKind.Rejected, 0, '用户活动筛选不受支持');
    }
    const generation: number = this.sessionGeneration;
    const response: ForumUserActivityResponseWire = this.parse<ForumUserActivityResponseWire>(
      await this.get(`/user_actions.json?username=${encodeURIComponent(clean)}&offset=${offset}&limit=30&filter=${encodeURIComponent(filter)}`, cancellation));
    this.ensureSessionGeneration(generation);
    if (cancellation?.isCancelled) { throw cancelledError(); }
    if (!Array.isArray(response.user_actions)) { throw new ForumApiError(ForumErrorKind.InvalidResponse, 0, '社区未返回此用户的活动'); }
    return forumUserActivityFromWire(response.user_actions, filter, offset);
  }

  private async readProfilePlugin(path: string, label: string, cancellation?: RequestCancellation): Promise<string> {
    try { return await this.get(path, cancellation); }
    catch (error) {
      if (error instanceof ForumApiError) {
        if (error.kind === ForumErrorKind.NotFound) {
          throw new ForumApiError(ForumErrorKind.Unsupported, error.status, `当前社区未开放${label}，或此账号无权查看`);
        }
        throw error;
      }
      throw new ForumApiError(ForumErrorKind.Network, 0, `${label}暂时无法加载，请重试`);
    }
  }
  private boostPostFloor(post: ProfileBoostPostWire): number {
    const safe: string = safeForumUrl(text(post.url));
    const route: string = safe.startsWith(FORUM_ORIGIN) ? safe.substring(FORUM_ORIGIN.length).split(/[?#]/)[0] : '';
    // BoostListPostSerializer uses Post.url without share_url/without_slug:
    // /t/{slug}/{topic_id}/{post_number}, including an explicit /1 for the OP.
    const match: RegExpMatchArray | null = route.match(/^\/t\/[^/]+\/(\d+)\/(\d+)\/?$/);
    const topicId: number = numberValue(post.topic_id);
    if (match === null || Number(match[1]) !== topicId || !Number.isSafeInteger(topicId) || topicId <= 0) {
      throw new ForumApiError(ForumErrorKind.InvalidResponse, 0, 'Boost 记录缺少可确认的话题楼层，请重试');
    }
    const floor: number = Number(match[2]);
    if (!Number.isSafeInteger(floor) || floor < 1) {
      throw new ForumApiError(ForumErrorKind.InvalidResponse, 0, 'Boost 记录的楼层无效，请重试');
    }
    return floor;
  }
  async fetchProfile(username: string, section: ProfileSection, cursor: number = 0,
    order: ProfileOrder = ProfileOrder.Latest, filter: NotificationFilter = NotificationFilter.All,
    cancellation?: RequestCancellation, boostDirection: ProfileBoostDirection = ProfileBoostDirection.Given): Promise<ProfilePage> {
    validateCursor(cursor);
    if (!username.trim() || username.length > 200 || order !== ProfileOrder.Latest) {
      throw new ForumApiError(ForumErrorKind.Rejected, 0, '无效的社区用户');
    }
    const path: string = encodeURIComponent(username);
    const empty: ProfilePage = { fields: [], entries: [], hasMore: false, nextCursor: cursor };
    if (section === ProfileSection.Votes) {
      const generation: number = this.sessionGeneration;
      // TopicQueryExtension.list_voted_by selects this user's unarchived topic votes.
      // It is not a history of votes cast inside poll posts.
      const raw: string = await this.readProfilePlugin(`/topics/voted-by/${path}.json?page=${cursor}`, '话题投票记录', cancellation);
      this.ensureSessionGeneration(generation);
      if (cancellation?.isCancelled) { throw cancelledError(); }
      const page: TopicPage = this.topicPage(this.parse<TopicListResponseWire>(raw));
      const entries: ProfileEntry[] = page.items.map((item: TopicListItem): ProfileEntry => {
        if (!Number.isSafeInteger(item.topic.id) || item.topic.id <= 0) {
          throw new ForumApiError(ForumErrorKind.InvalidResponse, 0, '社区返回了无效的话题投票记录');
        }
        return { id: `vote:${item.topic.id}`, title: item.topic.title,
          subtitle: ['有效话题投票', item.topic.lastPostedAt ? '话题更新于 ' + item.topic.lastPostedAt.slice(0, 10) : '']
            .filter((value: string): boolean => value.length > 0).join(' · '),
          topicId: item.topic.id, postNumber: 1, unread: false, notificationType: 0,
          actor: item.authorUsername, avatarUrl: item.avatarUrl };
      });
      return { fields: [], entries: entries, hasMore: page.hasMore, nextCursor: cursor + 1 };
    }
    if (section === ProfileSection.Solutions) {
      const generation: number = this.sessionGeneration;
      // SolvedTopicsController.by_user joins accepted answer_post_id and filters
      // the answer author's user_id. Solved participation is not this record.
      const raw: string = await this.readProfilePlugin(`/solution/by_user.json?username=${path}&offset=${cursor}&limit=30`, '被采纳方案记录', cancellation);
      this.ensureSessionGeneration(generation);
      if (cancellation?.isCancelled) { throw cancelledError(); }
      const response: ProfileSolvedResponseWire = this.parse<ProfileSolvedResponseWire>(raw);
      if (!Array.isArray(response.user_solved_posts)) {
        throw new ForumApiError(ForumErrorKind.InvalidResponse, 0, '社区未返回被采纳方案记录，请重试');
      }
      const posts: ProfileSolvedPostWire[] = response.user_solved_posts;
      const entries: ProfileEntry[] = posts.map((post: ProfileSolvedPostWire): ProfileEntry => {
        const postId: number = numberValue(post.post_id);
        const topicId: number = numberValue(post.topic_id);
        const floor: number = numberValue(post.post_number);
        if (!Number.isSafeInteger(postId) || postId <= 0 || !Number.isSafeInteger(topicId) || topicId <= 0 ||
          !Number.isSafeInteger(floor) || floor <= 0 || text(post.username).toLocaleLowerCase() !== username.toLocaleLowerCase()) {
          throw new ForumApiError(ForumErrorKind.InvalidResponse, 0, '方案记录的作者或楼层无法确认，请重试');
        }
        return { id: `solution:${postId}`, title: plainText(text(post.topic_title)) || '被采纳的方案',
          subtitle: ['已被采纳', `#${floor}`, plainText(text(post.excerpt) || text(post.cooked) || text(post.raw)),
            text(post.created_at) ? '回复于 ' + text(post.created_at).slice(0, 10) : '']
            .filter((value: string): boolean => value.length > 0).join(' · '),
          topicId: topicId, postNumber: floor, unread: false, notificationType: 0,
          actor: text(post.username), avatarUrl: avatarUrlOf(text(post.avatar_template)) };
      });
      return { fields: [], entries: entries, hasMore: posts.length >= 30, nextCursor: cursor + posts.length };
    }
    if (section === ProfileSection.Boosts) {
      if (boostDirection !== ProfileBoostDirection.Given && boostDirection !== ProfileBoostDirection.Received) {
        throw new ForumApiError(ForumErrorKind.Rejected, 0, 'Boost 记录类型无效');
      }
      const generation: number = this.sessionGeneration;
      const before: string = cursor > 0 ? `?before_boost_id=${cursor}` : '';
      const route: string = `/discourse-boosts/users/${path}/boosts-${boostDirection}.json${before}`;
      const raw: string = await this.readProfilePlugin(route, 'Boost 记录', cancellation);
      this.ensureSessionGeneration(generation);
      if (cancellation?.isCancelled) { throw cancelledError(); }
      const response: ProfileBoostsResponseWire = this.parse<ProfileBoostsResponseWire>(raw);
      if (!Array.isArray(response.boosts)) {
        throw new ForumApiError(ForumErrorKind.InvalidResponse, 0, '社区未返回 Boost 记录，请重试');
      }
      const boosts: ProfileBoostEntryWire[] = response.boosts;
      let nextCursor: number = 0;
      const entries: ProfileEntry[] = boosts.map((boost: ProfileBoostEntryWire): ProfileEntry => {
        const id: number = numberValue(boost.id);
        const post: ProfileBoostPostWire | undefined = boost.post;
        if (!Number.isSafeInteger(id) || id <= 0 || (cursor > 0 && id >= cursor) || post === undefined) {
          throw new ForumApiError(ForumErrorKind.InvalidResponse, 0, 'Boost 分页结果无效，请重试');
        }
        const given: boolean = boostDirection === ProfileBoostDirection.Given;
        const owner: string = given ? text(boost.user?.username) : text(post.username);
        if (owner.toLocaleLowerCase() !== username.toLocaleLowerCase()) {
          throw new ForumApiError(ForumErrorKind.InvalidResponse, 0, 'Boost 记录与当前账号不符，请重试');
        }
        const floor: number = this.boostPostFloor(post);
        const actor: string = given ? text(post.username) : text(boost.user?.username);
        nextCursor = nextCursor === 0 ? id : Math.min(nextCursor, id);
        return { id: `boost:${id}`, title: plainText(text(post.topic_title)) || 'Boost',
          subtitle: [given ? `发给 @${actor}` : `来自 @${actor}`, plainText(text(boost.cooked) || text(boost.raw)),
            `#${floor}`, text(boost.created_at).slice(0, 10)].filter((value: string): boolean => value.length > 0).join(' · '),
          topicId: numberValue(post.topic_id), postNumber: floor, unread: false, notificationType: 0, actor: actor,
          avatarUrl: avatarUrlOf(given ? text(post.avatar_template) : text(boost.user?.avatar_template)) };
      });
      return { fields: [], entries: entries, hasMore: boosts.length >= 20 && nextCursor > 0,
        nextCursor: nextCursor > 0 ? nextCursor : cursor };
    }
    if (section === ProfileSection.Summary) {
      const response: SummaryResponseWire = this.parse<SummaryResponseWire>(await this.get(`/u/${path}/summary.json`, cancellation));
      if (!response.user_summary) { throw new ForumApiError(ForumErrorKind.InvalidResponse, 0, '社区未返回个人统计'); }
      const summary: SummaryWire = response.user_summary;
      const fields: ProfileField[] = [
        { label: '访问天数', value: metric(summary.days_visited) },
        { label: '阅读时长', value: typeof summary.time_read === 'number' ? Math.floor(summary.time_read / 60) + ' 分钟' : '—' },
        { label: '浏览话题', value: metric(summary.topics_entered) },
        { label: '已读帖子', value: metric(summary.posts_read_count) },
        { label: '送出赞', value: metric(summary.likes_given) },
        { label: '收到赞', value: metric(summary.likes_received) },
        { label: '发表话题', value: metric(summary.topic_count) },
        { label: '回复数量', value: metric(summary.post_count) }
      ];
      empty.fields = fields; return empty;
    }
    if (section === ProfileSection.Account) {
      const response: UserResponseWire = this.parse<UserResponseWire>(await this.get(`/u/${path}.json`, cancellation));
      if (!response.user) { throw new ForumApiError(ForumErrorKind.InvalidResponse, 0, '社区未返回账号信息'); }
      const user: UserWire = response.user;
      const emails: EmailsWire = this.parse<EmailsWire>(await this.get(`/u/${path}/emails.json`, cancellation));
      empty.fields = [
        { label: '用户名', value: text(user.username, username) }, { label: '显示名称', value: text(user.name) || '未设置' },
        { label: '信任等级', value: typeof user.trust_level === 'number' ? 'Lv' + user.trust_level : '—' }, { label: '注册日期', value: text(user.created_at).slice(0, 10) || '—' },
        { label: '个人简介', value: plainText(text(user.bio_raw) || text(user.bio_cooked)) || '未设置' },
        { label: '主邮箱', value: text(emails.email) || text(user.email) || '服务端未返回' },
        { label: '备用邮箱', value: list(emails.secondary_emails).filter((value: string): boolean => typeof value === 'string').join('\n') || '未设置' }
      ];
      return empty;
    }
    if (section === ProfileSection.Notifications) {
      const page: NotificationPage = await this.fetchNotifications(cursor, filter, cancellation);
      const entries: ProfileEntry[] = page.notifications.map((notice: ForumNotification): ProfileEntry => {
        return { id: String(notice.id), title: notice.title, subtitle: [notice.label, notice.actor, notice.createdAt.slice(0, 10)].filter((value: string): boolean => value.length > 0).join(' · '),
          topicId: notice.topicId, unread: !notice.read, notificationType: notice.type, avatarUrl: notice.avatarUrl, actor: notice.actor, postNumber: notice.postNumber };
      });
      return { fields: [], entries: entries, hasMore: page.hasMore, nextCursor: page.nextOffset };
    }
    if (section === ProfileSection.Bookmarks) {
      // UsersController returns { bookmarks: [] } for an empty list, and the
      // UserBookmarkListSerializer root for a populated page. Never infer empty
      // from an absent list, or follow a server-provided URL with credentials.
      const response: BookmarksResponseWire = this.parse<BookmarksResponseWire>(await this.get(`/u/${path}/bookmarks.json?page=${cursor}`, cancellation));
      const bookmarks: BookmarkWire[] | undefined = response.user_bookmark_list?.bookmarks ?? response.bookmarks;
      if (!Array.isArray(bookmarks)) { throw new ForumApiError(ForumErrorKind.InvalidResponse, 0, '社区未返回收藏列表'); }
      const entries: ProfileEntry[] = bookmarks.map((bookmark: BookmarkWire): ProfileEntry => {
        if (!Number.isSafeInteger(bookmark.id) || numberValue(bookmark.id) <= 0) {
          throw new ForumApiError(ForumErrorKind.InvalidResponse, 0, '社区返回了无效收藏');
        }
        const topicId: number = numberValue(bookmark.topic_id);
        const available: boolean = topicId > 0 && !bookmark.deleted && !bookmark.hidden;
        const lastRead: number = Math.max(0, numberValue(bookmark.last_read_post_number));
        const linked: number = Math.max(1, numberValue(bookmark.linked_post_number, 1));
        const floor: number = bookmark.bookmarkable_type === 'Topic' ? lastRead + 1 : linked;
        const highest: number = numberValue(bookmark.highest_post_number, floor);
        return { id: `bookmark:${bookmark.id}`, title: plainText(text(bookmark.title) || text(bookmark.fancy_title)) || '收藏',
          subtitle: [text(bookmark.name), plainText(text(bookmark.excerpt)),
            !available ? (bookmark.deleted || bookmark.hidden ? '原内容暂不可用' : '此类收藏请在社区网页查看') : '',
            text(bookmark.created_at).slice(0, 10)].filter((part: string): boolean => part.length > 0).join(' · '),
          topicId: available ? topicId : 0, unread: false, notificationType: 0,
          avatarUrl: bookmark.user ? avatarUrlOf(text(bookmark.user.avatar_template), 72) : '',
          actor: text(bookmark.user?.username), postNumber: Math.max(1, Math.min(floor, highest)) };
      });
      return { fields: [], entries: entries,
        hasMore: bookmarks.length > 0 && text(response.user_bookmark_list?.more_bookmarks_url).length > 0,
        nextCursor: cursor + 1 };
    }
    if (section === ProfileSection.Messages || section === ProfileSection.Read) {
      // /read is the authenticated user's server-side history, ordered by
      // TopicQuery.list_read's last_visited_at, not a local synthetic log.
      const endpoint: string = section === ProfileSection.Read ? `/read.json?page=${cursor}` : `/topics/private-messages/${path}.json?page=${cursor}`;
      const response: TopicListResponseWire = this.parse<TopicListResponseWire>(await this.get(endpoint, cancellation));
      const page: TopicPage = this.topicPage(response);
      const entries: ProfileEntry[] = page.items.map((item: TopicListItem): ProfileEntry => {
        const lastRead: number = numberValue(response.topic_list?.topics?.find((wire: TopicWire): boolean => wire.id === item.topic.id)?.last_read_post_number, 1);
        return { id: String(item.topic.id), title: item.topic.title, subtitle: `${item.topic.replyCount} 回复 · ${item.topic.lastPostedAt.slice(0, 10)}`,
          topicId: item.topic.id, unread: item.topic.unseen, notificationType: 0, avatarUrl: item.avatarUrl, actor: item.authorUsername,
          postNumber: section === ProfileSection.Read ? Math.max(1, lastRead) : 1 };
      });
      return { fields: [], entries: entries, hasMore: page.hasMore, nextCursor: cursor + 1 };
    }
    // Official Discourse UserAction: LIKE=1, NEW_TOPIC=4 and REPLY=5.
    // The filter is server-side so each view has its own complete pagination.
    const actionFilter: string = section === ProfileSection.Likes ? '&filter=1' :
      section === ProfileSection.Topics ? '&filter=4' : section === ProfileSection.Replies ? '&filter=5' : '';
    const response: ActionsResponseWire = this.parse<ActionsResponseWire>(await this.get(`/user_actions.json?username=${path}&offset=${cursor * 30}&limit=30${actionFilter}`, cancellation));
    if (!Array.isArray(response.user_actions)) {
      throw new ForumApiError(ForumErrorKind.InvalidResponse, 0,
        section === ProfileSection.Likes ? '社区未返回点赞记录，请刷新后重试' : '社区未返回个人活动，请刷新后重试');
    }
    const actions: ActionWire[] = list(response.user_actions);
    const entries: ProfileEntry[] = actions.map((action: ActionWire, index: number): ProfileEntry => {
      const labels: Record<string, string> = { '1': '点赞', '2': '收到赞', '4': '发表话题', '5': '回复', '6': '收到回复', '7': '被提及', '9': '引用', '11': '消息', '12': '消息' };
      const label: string = labels[String(numberValue(action.action_type))] ?? '活动';
      return { id: section === ProfileSection.Likes ? `like:${numberValue(action.post_id)}:${text(action.created_at)}` :
          section === ProfileSection.Topics || section === ProfileSection.Replies ? `${section}:${numberValue(action.post_id)}:${text(action.created_at)}` :
          `${cursor * 30 + index}:${numberValue(action.post_id)}`, title: plainText(text(action.title)) || '社区活动',
        subtitle: [label, plainText(text(action.excerpt)), text(action.created_at).slice(0, 10)].filter((value: string): boolean => value.length > 0).join(' · '),
        topicId: numberValue(action.topic_id), unread: false, notificationType: 0, avatarUrl: '', actor: '', postNumber: numberValue(action.post_number) };
    });
    return { fields: [], entries: entries, hasMore: actions.length >= 30, nextCursor: cursor + 1 };
  }
  async emojiUrls(cancellation?: RequestCancellation): Promise<Map<string, string>> {
    const generation: number = this.sessionGeneration;
    if (cancellation?.isCancelled) { throw cancelledError(); }
    if (this.emojiCache) { return new Map<string, string>(this.emojiCache); }
    if (this.emojiInFlight && !cancellation) {
      const shared: Map<string, string> = await this.emojiInFlight;
      this.ensureSessionGeneration(generation);
      return new Map<string, string>(shared);
    }
    const operation: Promise<Map<string, string>> = this.loadEmojiUrls(cancellation);
    if (!cancellation) { this.emojiInFlight = operation; }
    try {
      const result: Map<string, string> = await operation;
      this.ensureSessionGeneration(generation);
      if (cancellation?.isCancelled) { throw cancelledError(); }
      return new Map<string, string>(result);
    }
    finally { if (this.emojiInFlight === operation) { this.emojiInFlight = undefined; } }
  }
  private async loadEmojiUrls(cancellation?: RequestCancellation): Promise<Map<string, string>> {
    const generation: number = this.sessionGeneration;
    const raw: string = await this.get('/emojis.json', cancellation);
    this.ensureSessionGeneration(generation);
    if (cancellation?.isCancelled) { throw cancelledError(); }
    const result: Map<string, string> = new Map<string, string>();
    const add: (emoji: EmojiWire) => void = (emoji: EmojiWire): void => {
      const name: string = text(emoji.name) || text(emoji.id);
      const url: string = emojiImageUrl(text(emoji.url));
      if (name && url) { result.set(name, url); }
    };
    if (raw.trim().startsWith('[')) { decodeArray<EmojiWire>(raw).forEach(add); }
    else {
      const groups: Record<string, EmojiWire[]> = this.parse<Record<string, EmojiWire[]>>(raw);
      Object.keys(groups).forEach((key: string): void => { list(groups[key]).forEach(add); });
    }
    this.emojiCache = result;
    return result;
  }
}

export const forumApi: ForumApi = new ForumApi();

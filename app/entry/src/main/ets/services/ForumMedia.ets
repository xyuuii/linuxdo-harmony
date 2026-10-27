import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { webview } from '@kit.ArkWeb';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { util, url as urlUtils } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { forumSession } from '../models/ForumSession';
import { forumApi, RequestCancellation, ForumApiError, ForumErrorKind, BrowserMediaResponse } from './ForumApi';
import { browserMediaUrl } from './BrowserMediaPolicy';

const MAX_MEDIA_BYTES: number = 20 * 1024 * 1024;
const MAX_CACHE_BYTES: number = 100 * 1024 * 1024;
const MAX_PARALLEL_REQUESTS: number = 3;
const PROCESS_ID: string = util.generateRandomUUID();

interface MediaScope { ownerId: number; generation: number; }
interface CacheEntry { path: string; uri: string; bytes: number; }
interface MediaTask { cancellation: RequestCancellation; promise: Promise<string>; consumers: number; }
interface QueueEntry { resolve: () => void; reject: (error: ForumApiError) => void;
  cancellation: RequestCancellation; handler: () => void; }
const cache: Map<string, CacheEntry> = new Map<string, CacheEntry>();
const inFlight: Map<string, MediaTask> = new Map<string, MediaTask>();
const cacheRoots: Map<string, Promise<string>> = new Map<string, Promise<string>>();
const scopeDirectories: Set<string> = new Set<string>();
const queue: QueueEntry[] = [];
let cacheBytes: number = 0;
let activeCount: number = 0;

function cancellationError(): ForumApiError { return new ForumApiError(ForumErrorKind.Cancelled, 0, '图片加载已取消'); }
function currentScope(): MediaScope {
  return { ownerId: forumSession.user?.id || 0, generation: forumApi.getSessionGeneration() };
}
function ensureScope(scope: MediaScope, cancellation?: RequestCancellation): void {
  if (cancellation?.isCancelled || scope.ownerId !== (forumSession.user?.id || 0) ||
    scope.generation !== forumApi.getSessionGeneration()) { throw cancellationError(); }
}
function normalizedUrl(value: string): urlUtils.URL {
  if (!value || /[\u0000-\u0020\u007F\\]/.test(value)) {
    throw new ForumApiError(ForumErrorKind.Rejected, 0, '无效的图片地址');
  }
  const parsed: urlUtils.URL = new urlUtils.URL(value, 'https://linux.do');
  if (parsed.protocol !== 'https:' || parsed.username || parsed.password || (parsed.port && parsed.port !== '443')) {
    throw new ForumApiError(ForumErrorKind.Rejected, 0, '图片地址必须使用 HTTPS');
  }
  parsed.hash = '';
  return parsed;
}
function cacheKey(url: string, context: common.UIAbilityContext, scope: MediaScope): string {
  return `${context.cacheDir}:${scope.ownerId}:${scope.generation}:${url}`;
}
async function removeFile(path: string): Promise<void> {
  try { await fileIo.unlink(path); } catch { /* An invalidated or evicted cache file may already be absent. */ }
}
function clearEntry(key: string): void {
  const entry: CacheEntry | undefined = cache.get(key);
  if (entry) {
    cacheBytes -= entry.bytes;
    cache.delete(key);
    void removeFile(entry.path);
  }
}
function evictCache(): void {
  while (cacheBytes > MAX_CACHE_BYTES) {
    let oldest: string = '';
    cache.forEach((_entry: CacheEntry, key: string): void => { if (!oldest) { oldest = key; } });
    if (!oldest) { break; }
    clearEntry(oldest);
  }
}
function resetMediaContext(): void {
  inFlight.forEach((task: MediaTask): void => task.cancellation.cancel());
  inFlight.clear();
  cache.clear();
  cacheBytes = 0;
  scopeDirectories.forEach((directory: string): void => {
    void fileIo.rmdir(directory).catch((): void => {});
  });
  scopeDirectories.clear();
}
forumApi.onSessionReset(resetMediaContext);

async function acquire(cancellation: RequestCancellation): Promise<void> {
  if (cancellation.isCancelled) { throw cancellationError(); }
  if (activeCount < MAX_PARALLEL_REQUESTS) { activeCount++; return; }
  await new Promise<void>((resolve: () => void, reject: (error: ForumApiError) => void): void => {
    const entry: QueueEntry = { resolve: resolve, reject: reject, cancellation: cancellation, handler: (): void => {} };
    entry.handler = (): void => {
      const index: number = queue.indexOf(entry);
      if (index >= 0) { queue.splice(index, 1); }
      cancellation.offCancel(entry.handler);
      reject(cancellationError());
    };
    queue.push(entry);
    cancellation.onCancel(entry.handler);
  });
}
function release(): void {
  activeCount = Math.max(0, activeCount - 1);
  while (queue.length > 0 && activeCount < MAX_PARALLEL_REQUESTS) {
    const entry: QueueEntry | undefined = queue.shift();
    if (!entry) { break; }
    entry.cancellation.offCancel(entry.handler);
    if (entry.cancellation.isCancelled) { entry.reject(cancellationError()); continue; }
    activeCount++;
    entry.resolve();
  }
}
async function digestUrl(value: string): Promise<string> {
  const digest: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
  const data: cryptoFramework.DataBlob = { data: new util.TextEncoder('utf-8').encodeInto(value) };
  await digest.update(data);
  const result: cryptoFramework.DataBlob = await digest.digest();
  const hex: string[] = [];
  result.data.forEach((byte: number): void => { hex.push(byte.toString(16).padStart(2, '0')); });
  return hex.join('');
}
async function createRoot(cacheDir: string): Promise<string> {
  const root: string = cacheDir + '/forum-media';
  // This is only this loader's disposable cache. Do not reuse an unknown owner's
  // files left by an earlier process before /session/current is confirmed.
  if (await fileIo.access(root)) { await fileIo.rmdir(root); }
  const processRoot: string = root + '/' + PROCESS_ID;
  await fileIo.mkdir(processRoot, true);
  return processRoot;
}
async function directoryFor(context: common.UIAbilityContext, scope: MediaScope, cancellation: RequestCancellation): Promise<string> {
  let root: Promise<string> | undefined = cacheRoots.get(context.cacheDir);
  if (!root) {
    const created: Promise<string> = createRoot(context.cacheDir);
    cacheRoots.set(context.cacheDir, created);
    void created.catch((): void => {
      if (cacheRoots.get(context.cacheDir) === created) { cacheRoots.delete(context.cacheDir); }
    });
    root = created;
  }
  const base: string = await root;
  ensureScope(scope, cancellation);
  const directory: string = `${base}/owner-${scope.ownerId}/generation-${scope.generation}`;
  if (!await fileIo.access(directory)) {
    try { await fileIo.mkdir(directory, true); }
    catch { if (!await fileIo.access(directory)) { throw new ForumApiError(ForumErrorKind.Rejected, 0, '暂时无法创建图片缓存'); } }
  }
  ensureScope(scope, cancellation);
  scopeDirectories.add(directory);
  return directory;
}
function headerValue(headers: Record<string, string | string[]>, name: string): string {
  const keys: string[] = Object.keys(headers);
  const key: string | undefined = keys.find((value: string): boolean => value.toLowerCase() === name);
  if (!key) { return ''; }
  const value: string | string[] = headers[key];
  return typeof value === 'string' ? value : Array.isArray(value) ? value.join('\n') : '';
}
async function requestMedia(parsed: urlUtils.URL, scope: MediaScope, cancellation: RequestCancellation): Promise<ArrayBuffer> {
  ensureScope(scope, cancellation);
  if (forumApi.canUseBrowserMedia() && browserMediaUrl(parsed.href)) {
    const response: BrowserMediaResponse = await forumApi.requestBrowserMedia(parsed.href, cancellation);
    ensureScope(scope, cancellation);
    checkMediaHeaders(response.status, response.headers);
    return checkMediaBytes(response.bytes, response.status);
  }
  const headers: Record<string, string> = { 'Accept': 'image/*', 'User-Agent': forumApi.getUserAgent() };
  if (parsed.hostname === 'linux.do') {
    headers['Referer'] = 'https://linux.do/';
    try {
      const cookies: string = await webview.WebCookieManager.fetchCookie(parsed.href, false, true);
      if (cookies) { headers['Cookie'] = cookies; }
    } catch (error) {
      if ((error as BusinessError).code !== 17100002) {
        throw new ForumApiError(ForumErrorKind.VerificationRequired, 0, '请先打开网页确认图片访问会话');
      }
    }
  }
  ensureScope(scope, cancellation);
  const request: http.HttpRequest = http.createHttp();
  let timer: number = -1;
  let settled: boolean = false;
  let cancel: () => void = (): void => {};
  try {
    const response: http.HttpResponse = await new Promise<http.HttpResponse>(
      (resolve: (value: http.HttpResponse) => void, reject: (error: ForumApiError) => void): void => {
        cancel = (): void => {
          if (settled) { return; }
          settled = true;
          try { request.destroy(); } catch { /* Released during session reset. */ }
          reject(cancellationError());
        };
        cancellation.onCancel(cancel);
        if (settled) { return; }
        timer = setTimeout((): void => {
          if (settled) { return; }
          settled = true;
          try { request.destroy(); } catch { /* Already released. */ }
          reject(new ForumApiError(ForumErrorKind.Timeout, 0, '图片加载超时，请稍后重试'));
        }, 25000);
        request.request(parsed.href, {
          method: http.RequestMethod.GET, header: headers, expectDataType: http.HttpDataType.ARRAY_BUFFER,
          usingCache: false, maxRedirects: 0, maxLimit: MAX_MEDIA_BYTES, connectTimeout: 6000, readTimeout: 20000
        }).then((value: http.HttpResponse): void => {
          if (!settled) { settled = true; resolve(value); }
        }).catch((error: BusinessError): void => {
          if (settled) { return; }
          settled = true;
          reject(new ForumApiError(error.code === 2300028 ? ForumErrorKind.Timeout : ForumErrorKind.Network,
            0, error.code === 2300063 ? '图片超过 20 MB 上限' : '暂时无法加载图片'));
        });
      });
    ensureScope(scope, cancellation);
    const responseHeaders: Record<string, string | string[]> = response.header as Record<string, string | string[]>;
    const status: number = response.responseCode;
    checkMediaHeaders(status, responseHeaders);
    if (!(response.result instanceof ArrayBuffer)) {
      throw new ForumApiError(ForumErrorKind.InvalidResponse, status, '图片文件为空或超过 20 MB 上限');
    }
    return checkMediaBytes(response.result, status);
  } finally {
    if (timer >= 0) { clearTimeout(timer); }
    cancellation.offCancel(cancel);
    try { request.destroy(); } catch { /* Released by cancellation or timeout. */ }
  }
}
function checkMediaHeaders(status: number, headers: Record<string, string | string[]>): void {
  if (headerValue(headers, 'cf-mitigated') || status === 403) {
    throw new ForumApiError(ForumErrorKind.VerificationRequired, status, '图片访问需要网页验证');
  }
  if (status === 401) { throw new ForumApiError(ForumErrorKind.AuthenticationRequired, status, '图片登录会话已过期'); }
  if (status === 429) { throw new ForumApiError(ForumErrorKind.RateLimited, status, '图片请求过于频繁，请稍后重试'); }
  if (status < 200 || status >= 300) {
    throw new ForumApiError(ForumErrorKind.Rejected, status,
      status >= 300 && status < 400 ? '图片需要跳转，请使用网页查看' : '图片暂不可用');
  }
  const type: string = headerValue(headers, 'content-type').toLowerCase();
  if (type && !type.startsWith('image/') && !type.startsWith('application/octet-stream')) {
    throw new ForumApiError(ForumErrorKind.InvalidResponse, status, '社区没有返回图片内容');
  }
}
function checkMediaBytes(bytes: ArrayBuffer, status: number): ArrayBuffer {
  if (!(bytes instanceof ArrayBuffer) || bytes.byteLength === 0 || bytes.byteLength > MAX_MEDIA_BYTES) {
    throw new ForumApiError(ForumErrorKind.InvalidResponse, status, '图片文件为空或超过 20 MB 上限');
  }
  return bytes;
}
async function writeMedia(path: string, bytes: ArrayBuffer, scope: MediaScope, cancellation: RequestCancellation): Promise<void> {
  ensureScope(scope, cancellation);
  const file: fileIo.File = await fileIo.open(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
  try {
    ensureScope(scope, cancellation);
    const written: number = await fileIo.write(file.fd, bytes);
    if (written !== bytes.byteLength) { throw new ForumApiError(ForumErrorKind.Rejected, 0, '图片缓存没有完整写入'); }
  } finally { await fileIo.close(file); }
  ensureScope(scope, cancellation);
}
async function requestMediaWithRecovery(parsed: urlUtils.URL, scope: MediaScope,
  cancellation: RequestCancellation): Promise<ArrayBuffer> {
  const recoveredBeforeRequest: number = forumApi.getReadRecoveryVersion();
  try { return await requestMedia(parsed, scope, cancellation); }
  catch (error) {
    // External images never trigger forum navigation or receive forum credentials.
    if (!(error instanceof ForumApiError)) { throw new ForumApiError(ForumErrorKind.Network, 0, '图片请求未完成，请稍后重试'); }
    if (error.kind !== ForumErrorKind.VerificationRequired || parsed.hostname !== 'linux.do') { throw error; }
    // Another read may already have recovered while this old native challenge was in flight.
    if (!(forumApi.canUseBrowserMedia() && forumApi.getReadRecoveryVersion() !== recoveredBeforeRequest) &&
      !await forumApi.recoverReadSession(cancellation)) { throw error; }
    ensureScope(scope, cancellation);
    return requestMedia(parsed, scope, cancellation);
  }
}
async function fetchAndCache(parsed: urlUtils.URL, context: common.UIAbilityContext, scope: MediaScope,
  cancellation: RequestCancellation, key: string): Promise<string> {
  let path: string = '';
  let acquired: boolean = false;
  try {
    await acquire(cancellation); acquired = true;
    ensureScope(scope, cancellation);
    const bytes: ArrayBuffer = await requestMediaWithRecovery(parsed, scope, cancellation);
    const digest: string = await digestUrl(parsed.href);
    const directory: string = await directoryFor(context, scope, cancellation);
    // No URL, query, cookie or credentials are included in a cache filename.
    path = `${directory}/${digest}-${util.generateRandomUUID()}.${mediaFileExtension(bytes)}`;
    await writeMedia(path, bytes, scope, cancellation);
    const uri: string = fileUri.getUriFromPath(path);
    ensureScope(scope, cancellation);
    clearEntry(key);
    cache.set(key, { path: path, uri: uri, bytes: bytes.byteLength });
    cacheBytes += bytes.byteLength;
    evictCache();
    return uri;
  } catch (error) {
    if (path) { await removeFile(path); }
    if (error instanceof ForumApiError) { throw error; }
    throw new ForumApiError(ForumErrorKind.Network, 0, '图片加载或缓存失败，请稍后重试');
  } finally { if (acquired) { release(); } }
}
function mediaFileExtension(bytes: ArrayBuffer): string {
  const header: Uint8Array = new Uint8Array(bytes, 0, Math.min(bytes.byteLength, 12));
  if (header.length >= 6 && header[0] === 0x47 && header[1] === 0x49 && header[2] === 0x46 &&
    header[3] === 0x38 && (header[4] === 0x37 || header[4] === 0x39) && header[5] === 0x61) { return 'gif'; }
  if (header.length >= 12 && header[0] === 0x52 && header[1] === 0x49 && header[2] === 0x46 && header[3] === 0x46 &&
    header[8] === 0x57 && header[9] === 0x45 && header[10] === 0x42 && header[11] === 0x50) { return 'webp'; }
  return 'image';
}
async function awaitShared(task: MediaTask, scope: MediaScope, cancellation?: RequestCancellation): Promise<string> {
  ensureScope(scope, cancellation);
  task.consumers++;
  let handler: () => void = (): void => {};
  try {
    const result: string = await new Promise<string>((resolve: (value: string) => void, reject: (error: ForumApiError) => void): void => {
      handler = (): void => reject(cancellationError());
      cancellation?.onCancel(handler);
      task.promise.then(resolve).catch((error: ForumApiError): void => reject(error));
    });
    ensureScope(scope, cancellation);
    return result;
  } finally {
    cancellation?.offCancel(handler);
    task.consumers--;
    if (task.consumers <= 0) { task.cancellation.cancel(); }
  }
}

/** Download using the app's shared UA/session and return an account-scoped sandbox URI. */
export async function loadForumMedia(value: string, context: common.UIAbilityContext,
  cancellation?: RequestCancellation): Promise<string> {
  const scope: MediaScope = currentScope();
  ensureScope(scope, cancellation);
  let parsed: urlUtils.URL;
  try { parsed = normalizedUrl(value); }
  catch { throw new ForumApiError(ForumErrorKind.Rejected, 0, '无效的 HTTPS 图片地址'); }
  const key: string = cacheKey(parsed.href, context, scope);
  const cached: CacheEntry | undefined = cache.get(key);
  if (cached) {
    let exists: boolean = false;
    try { exists = await fileIo.access(cached.path); } catch { /* The OS may evict cache files. */ }
    ensureScope(scope, cancellation);
    if (exists) { cache.delete(key); cache.set(key, cached); return cached.uri; }
    clearEntry(key);
  }
  let task: MediaTask | undefined = inFlight.get(key);
  if (!task || task.cancellation.isCancelled) {
    const request: RequestCancellation = new RequestCancellation();
    const promise: Promise<string> = fetchAndCache(parsed, context, scope, request, key);
    task = { cancellation: request, promise: promise, consumers: 0 };
    inFlight.set(key, task);
    const created: MediaTask = task;
    void promise.then((): void => {
      if (inFlight.get(key) === created) { inFlight.delete(key); }
    }).catch((): void => {
      if (inFlight.get(key) === created) { inFlight.delete(key); }
    });
  }
  return awaitShared(task, scope, cancellation);
}

export async function invalidateForumMedia(value: string, context: common.UIAbilityContext): Promise<void> {
  try {
    const parsed: urlUtils.URL = normalizedUrl(value);
    const key: string = cacheKey(parsed.href, context, currentScope());
    inFlight.get(key)?.cancellation.cancel();
    inFlight.delete(key);
    clearEntry(key);
  } catch { /* Malformed or stale image URLs do not own a reusable cache entry. */ }
}

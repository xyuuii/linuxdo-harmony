import { util } from '@kit.ArkTS';
import { BrowserMediaResponse, ForumApiError, ForumErrorKind } from './ForumApi';
import { MAX_BROWSER_MEDIA_BYTES, BROWSER_MEDIA_CHUNK_BYTES, MAX_BROWSER_MEDIA_FRAME_CHARS } from './BrowserMediaPolicy';

interface MediaHeaders { contentType?: string; mitigated?: string; retryAfter?: string; }
interface MediaFrame {
  type?: string; status?: number; headers?: MediaHeaders; index?: number; offset?: number;
  data?: string; total?: number; error?: string;
}

function invalidMedia(): ForumApiError {
  return new ForumApiError(ForumErrorKind.InvalidResponse, 0, '图片传输不完整，请重试');
}

/** One bounded image, tied by the adapter to a native-generated request token. */
export class BrowserMediaTransfer {
  private started: boolean = false;
  private finished: boolean = false;
  private tailSeen: boolean = false;
  private status: number = 0;
  private headers: Record<string, string> = {};
  private chunks: Uint8Array[] = [];
  private total: number = 0;

  accept(serialized: string): BrowserMediaResponse | undefined {
    if (this.finished || typeof serialized !== 'string' || serialized.length > MAX_BROWSER_MEDIA_FRAME_CHARS) { throw invalidMedia(); }
    let frame: MediaFrame;
    try { frame = JSON.parse(serialized) as MediaFrame; } catch { throw invalidMedia(); }
    if (!frame || typeof frame !== 'object' || Array.isArray(frame)) { throw invalidMedia(); }
    if (frame.type === 'error') {
      if (frame.error === 'too_large') {
        throw new ForumApiError(ForumErrorKind.InvalidResponse, 0, '图片超过 20 MB 上限');
      }
      if (frame.error === 'wrong_origin') {
        throw new ForumApiError(ForumErrorKind.VerificationRequired, 0, '网页图片会话已变化，请重新验证');
      }
      throw new ForumApiError(frame.error === 'timeout' ? ForumErrorKind.Timeout : ForumErrorKind.Network, 0,
        frame.error === 'timeout' ? '图片加载超时，请稍后重试' : '图片请求未完成，请稍后重试');
    }
    if (frame.type === 'start') { this.start(frame); return undefined; }
    if (!this.started) { throw invalidMedia(); }
    if (frame.type === 'chunk') { this.chunk(frame); return undefined; }
    if (frame.type !== 'done' || !Number.isSafeInteger(frame.total) || frame.total !== this.total || this.total === 0) { throw invalidMedia(); }
    const buffer: ArrayBuffer = new ArrayBuffer(this.total);
    const bytes: Uint8Array = new Uint8Array(buffer);
    let offset: number = 0;
    this.chunks.forEach((chunk: Uint8Array): void => { bytes.set(chunk, offset); offset += chunk.byteLength; });
    this.finished = true;
    this.chunks = [];
    const response: BrowserMediaResponse = { status: this.status, headers: this.headers, bytes: buffer };
    return response;
  }

  private start(frame: MediaFrame): void {
    if (this.started || typeof frame.status !== 'number' || !Number.isInteger(frame.status) ||
      frame.status < 100 || frame.status > 599 || !frame.headers || typeof frame.headers !== 'object' || Array.isArray(frame.headers)) { throw invalidMedia(); }
    const headers: MediaHeaders = frame.headers;
    const status: number = frame.status;
    if ((typeof headers.mitigated === 'string' && headers.mitigated.length > 0) || status === 403) {
      throw new ForumApiError(ForumErrorKind.VerificationRequired, status, '图片访问需要网页验证');
    }
    if (status === 401) { throw new ForumApiError(ForumErrorKind.AuthenticationRequired, status, '图片登录会话已过期'); }
    if (status === 429) { throw new ForumApiError(ForumErrorKind.RateLimited, status, '图片请求过于频繁，请稍后重试'); }
    if (status < 200 || status >= 300) { throw new ForumApiError(ForumErrorKind.Rejected, status, '图片暂不可用'); }
    const type: string = typeof headers.contentType === 'string' ? headers.contentType.slice(0, 1024).toLowerCase() : '';
    if (!type.startsWith('image/') && !type.startsWith('application/octet-stream')) {
      throw new ForumApiError(ForumErrorKind.InvalidResponse, status, '社区没有返回图片内容');
    }
    this.status = status;
    this.headers = { 'content-type': type };
    this.started = true;
  }

  private chunk(frame: MediaFrame): void {
    if (this.tailSeen || !Number.isSafeInteger(frame.index) || frame.index !== this.chunks.length ||
      !Number.isSafeInteger(frame.offset) || frame.offset !== this.total ||
      typeof frame.data !== 'string' || frame.data.length === 0 || frame.data.length > 64 * 1024 ||
      frame.data.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(frame.data)) { throw invalidMedia(); }
    let bytes: Uint8Array;
    try { bytes = new util.Base64Helper().decodeSync(frame.data); } catch { throw invalidMedia(); }
    const padding: number = frame.data.endsWith('==') ? 2 : frame.data.endsWith('=') ? 1 : 0;
    if (bytes.byteLength === 0 || bytes.byteLength > BROWSER_MEDIA_CHUNK_BYTES ||
      bytes.byteLength !== frame.data.length / 4 * 3 - padding || this.total + bytes.byteLength > MAX_BROWSER_MEDIA_BYTES) { throw invalidMedia(); }
    this.tailSeen = bytes.byteLength < BROWSER_MEDIA_CHUNK_BYTES;
    this.chunks.push(bytes);
    this.total += bytes.byteLength;
  }

  dispose(): void { this.finished = true; this.chunks = []; }
}

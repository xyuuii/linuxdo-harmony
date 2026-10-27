import { url } from '@kit.ArkTS';

export const MAX_BROWSER_MEDIA_BYTES: number = 20 * 1024 * 1024;
export const BROWSER_MEDIA_CHUNK_BYTES: number = 48 * 1024;
export const MAX_BROWSER_MEDIA_FRAME_CHARS: number = 68 * 1024;

/** Only the forum and its observed public CDN use the page's image fetch path. */
export function browserMediaUrl(value: string): string {
  if (!value || value.length > 8192 || /[\\\u0000-\u0020\u007F]/.test(value)) { return ''; }
  try {
    const parsed: url.URL = new url.URL(value, 'https://linux.do');
    if (parsed.protocol !== 'https:' || parsed.username || parsed.password ||
      (parsed.port && parsed.port !== '443') ||
      !['linux.do', 'cdn3.ldstatic.com'].includes(parsed.hostname)) { return ''; }
    parsed.hash = '';
    return parsed.href;
  } catch { return ''; }
}

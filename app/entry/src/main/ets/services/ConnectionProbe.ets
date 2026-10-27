import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { RequestCancellation } from './ForumApi';

export const CONNECTION_PROBE_URL: string = 'https://linux.do/cdn-cgi/trace';
export const CONNECTION_CONTROL_URL: string = 'https://crypto.cloudflare.com/cdn-cgi/trace';
export const CONNECTION_PROBE_DOH: string = 'https://dns.alidns.com/dns-query';

/** Only these public connection fields leave the probe; never retain trace IPs or cookies. */
export function connectionTraceSummary(body: string, control: boolean = false): string {
  let host: string = '';
  let sni: string = '';
  let tls: string = '';
  body.slice(0, 8192).split('\n').forEach((line: string): void => {
    if (line.startsWith('h=')) { host = line.slice(2).trim(); }
    if (line.startsWith('sni=')) { sni = line.slice(4).trim(); }
    if (line.startsWith('tls=')) { tls = line.slice(4).trim(); }
  });
  if (host !== (control ? 'crypto.cloudflare.com' : 'linux.do') || !/^TLSv1\.[23]$/.test(tls) || !['encrypted', 'plaintext', 'off'].includes(sni)) {
    return '未取得有效握手回执（可能需要网页验证）';
  }
  return `${tls} · ${sni === 'encrypted' ? '服务端确认域名已加密' : '本次连接未加密目标域名'}`;
}

export function browserTraceSummary(raw: string, control: boolean = false): string {
  try {
    const decoded: string = JSON.parse(raw) as string;
    return connectionTraceSummary(typeof decoded === 'string' ? decoded : '', control);
  } catch { return connectionTraceSummary(raw, control); }
}

// Filter inside the page as well: no address, IP, URL parameters or account data cross into the UI/log.
export function connectionTraceScript(control: boolean = false): string {
  const origin: string = control ? 'https://crypto.cloudflare.com' : 'https://linux.do';
  return `(() => {
  if (location.origin !== '${origin}') return '';
  return (document.body ? document.body.textContent : '').slice(0, 8192)
    .split('\\n').filter(line => /^(h|sni|tls)=/.test(line)).join('\\n');
})();`;
}

/** Per-request DoH, no Cookie headers, no redirects and no changes to the normal forum client. */
export async function probeNativeConnection(doh: boolean, cancellation: RequestCancellation, control: boolean = false): Promise<string> {
  if (cancellation.isCancelled) { return '检测已取消'; }
  const request: http.HttpRequest = http.createHttp();
  let timer: number = 0;
  let cancel: () => void = (): void => {};
  try {
    return await new Promise<string>((resolve: (value: string) => void): void => {
      let finished: boolean = false;
      const finish: (value: string) => void = (value: string): void => {
        if (finished) { return; }
        finished = true;
        resolve(value);
      };
      cancel = (): void => {
        try { request.destroy(); } catch { /* Already released. */ }
        finish('检测已取消');
      };
      cancellation.onCancel(cancel);
      if (finished) { return; }
      timer = setTimeout((): void => {
        try { request.destroy(); } catch { /* Already released. */ }
        finish('连接超时');
      }, 10000);
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET, expectDataType: http.HttpDataType.STRING,
        header: { 'Accept': 'text/plain' }, usingCache: false, maxRedirects: 0,
        connectTimeout: 4000, readTimeout: 6000, maxLimit: 8192
      };
      if (doh) { options.dnsOverHttps = CONNECTION_PROBE_DOH; }
      request.request(control ? CONNECTION_CONTROL_URL : CONNECTION_PROBE_URL, options).then((response: http.HttpResponse): void => {
        finish(response.responseCode === 200 && typeof response.result === 'string' ?
          connectionTraceSummary(response.result, control) : `HTTP ${response.responseCode} · 未取得有效握手回执`);
      }).catch((error: BusinessError): void => {
        const code: number = error.code;
        finish(Number.isSafeInteger(code) ? `连接未完成（错误码 ${code}）` : '连接未完成');
      });
    });
  } finally {
    clearTimeout(timer);
    cancellation.offCancel(cancel);
    try { request.destroy(); } catch { /* Already released. */ }
  }
}

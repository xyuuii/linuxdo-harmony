export function plainText(html: string): string {
  return html.replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, '')
    .replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, '')
    .replace(/<[^>]+>/g, ' ').replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'").replace(/\s+/g, ' ').trim();
}

export function relativeTime(value: string): string {
  const millis: number = Date.parse(value);
  if (!Number.isFinite(millis)) { return ''; }
  const minutes: number = Math.max(0, Math.floor((Date.now() - millis) / 60000));
  if (minutes < 1) { return '刚刚'; }
  if (minutes < 60) { return `${minutes} 分钟前`; }
  if (minutes < 1440) { return `${Math.floor(minutes / 60)} 小时前`; }
  if (minutes < 10080) { return `${Math.floor(minutes / 1440)} 天前`; }
  const date: Date = new Date(millis);
  return `${date.getMonth() + 1} 月 ${date.getDate()} 日`;
}

export function formatCount(value: number): string {
  return value > 9999 ? `${(value / 10000).toFixed(1)} 万` : String(value);
}

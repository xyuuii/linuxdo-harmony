export interface ForumSearchCriteria {
  query: string; titleOnly: boolean; categoryId: number; categoryName: string; tags: string; author: string;
}
export interface ForumSearchQuery { query: string; error: string; }
export interface ForumSearchHistoryEntry extends ForumSearchCriteria { orderIndex: number; }

export function buildForumSearchQuery(criteria: ForumSearchCriteria, topicScopeId: number = 0): ForumSearchQuery {
  const parts: string[] = [];
  const query: string = criteria.query.trim();
  const author: string = criteria.author.trim().replace(/^@/, '');
  const tags: string[] = criteria.tags.trim().split(/[,，\s]+/).filter((tag: string): boolean => tag.length > 0)
    .map((tag: string): string => tag.replace(/^#/, ''));
  if (query.length > 1000) { return { query: '', error: '搜索内容过长，请缩短后再试' }; }
  if (!Number.isSafeInteger(topicScopeId) || topicScopeId < 0) { return { query: '', error: '话题搜索范围无效' }; }
  if (!Number.isSafeInteger(criteria.categoryId) || criteria.categoryId < 0) {
    return { query: '', error: '请选择有效的分类' };
  }
  if (tags.length > 10 || tags.some((tag: string): boolean => !/^[\p{L}\p{M}0-9_-]{1,100}$/u.test(tag))) {
    return { query: '', error: '请输入有效标签，多个标签用逗号分隔' };
  }
  if (author && !/^[\p{L}\p{N}_.-]{1,60}$/u.test(author)) {
    return { query: '', error: '请输入一位发帖人的用户名' };
  }
  if (!query && criteria.categoryId === 0 && tags.length === 0 && !author) {
    return { query: '', error: '请输入关键词，或选择分类、标签、发帖人' };
  }
  if (query) { parts.push(query); }
  if (criteria.titleOnly) { parts.push('in:title'); }
  if (criteria.categoryId > 0) { parts.push(`category:${criteria.categoryId}`); }
  if (tags.length > 0) {
    const unique: Set<string> = new Set<string>(tags);
    parts.push(`tags:${Array.from<string>(unique).join(',')}`);
  }
  if (author) { parts.push(`@${author}`); }
  // Last topic context wins in Discourse. Keep the page's explicit scope last.
  if (topicScopeId > 0) { parts.push(`topic:${topicScopeId}`); }
  const combined: string = parts.join(' ');
  if (combined.length > 1000) { return { query: '', error: '搜索条件过长，请减少筛选条件' }; }
  return { query: combined, error: '' };
}

export function forumSearchCriteriaSummary(criteria: ForumSearchCriteria): string {
  const labels: string[] = [];
  if (criteria.titleOnly) { labels.push('仅标题'); }
  if (criteria.categoryId > 0) { labels.push(criteria.categoryName || '指定分类'); }
  if (criteria.tags.trim()) { labels.push('#' + criteria.tags.trim().replace(/^#/, '')); }
  if (criteria.author.trim()) { labels.push('@' + criteria.author.trim().replace(/^@/, '')); }
  return labels.join(' · ');
}

export function forumSearchHistoryId(entry: ForumSearchHistoryEntry): string {
  return JSON.stringify([entry.query.trim().toLocaleLowerCase(), entry.titleOnly, entry.categoryId,
    entry.tags.trim().toLocaleLowerCase(), entry.author.trim().replace(/^@/, '').toLocaleLowerCase(), entry.orderIndex]);
}

export function normalizeForumSearchHistory(entries: ForumSearchHistoryEntry[]): ForumSearchHistoryEntry[] {
  const result: ForumSearchHistoryEntry[] = [];
  const seen: Set<string> = new Set<string>();
  entries.forEach((entry: ForumSearchHistoryEntry): void => {
    if (entry === null || typeof entry !== 'object' || typeof entry.query !== 'string' ||
      typeof entry.titleOnly !== 'boolean' || typeof entry.categoryName !== 'string' || typeof entry.tags !== 'string' ||
      typeof entry.author !== 'string' || !Number.isInteger(entry.orderIndex) || entry.orderIndex < 0 || entry.orderIndex > 5 ||
      entry.categoryName.length > 200 || entry.tags.length > 500 || buildForumSearchQuery(entry).error) { return; }
    const clean: ForumSearchHistoryEntry = { query: entry.query.trim(), titleOnly: entry.titleOnly,
      categoryId: entry.categoryId, categoryName: entry.categoryName, tags: entry.tags.trim(),
      author: entry.author.trim().replace(/^@/, ''), orderIndex: entry.orderIndex };
    const id: string = forumSearchHistoryId(clean);
    if (seen.has(id) || result.length >= 12) { return; }
    seen.add(id); result.push(clean);
  });
  return result;
}

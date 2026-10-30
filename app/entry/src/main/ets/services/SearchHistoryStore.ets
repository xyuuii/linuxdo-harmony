import { ForumSearchHistoryEntry, normalizeForumSearchHistory, forumSearchHistoryId } from './SearchPolicy';

export interface ForumSearchHistoryStorage {
  read(key: string): Promise<string>;
  write(key: string, value: string): Promise<void>;
}

/** Each operation carries its account ID; late I/O can never adopt the visible account. */
export class ForumSearchHistoryStore {
  private storage: ForumSearchHistoryStorage;
  private cached: Map<number, ForumSearchHistoryEntry[]> = new Map<number, ForumSearchHistoryEntry[]>();
  private reads: Map<number, Promise<ForumSearchHistoryEntry[]>> = new Map<number, Promise<ForumSearchHistoryEntry[]>>();
  private writes: Map<number, Promise<void>> = new Map<number, Promise<void>>();
  private revisions: Map<number, number> = new Map<number, number>();
  private clearVersions: Map<number, number> = new Map<number, number>();

  constructor(storage: ForumSearchHistoryStorage) { this.storage = storage; }

  private key(ownerId: number): string {
    if (!Number.isSafeInteger(ownerId) || ownerId < 0) { throw new Error('无效的搜索记录账号'); }
    return `search_history_${ownerId}`;
  }
  async read(ownerId: number): Promise<ForumSearchHistoryEntry[]> {
    const key: string = this.key(ownerId);
    const cached: ForumSearchHistoryEntry[] | undefined = this.cached.get(ownerId);
    if (cached !== undefined) { return cached.slice(); }
    const pending: Promise<ForumSearchHistoryEntry[]> | undefined = this.reads.get(ownerId);
    if (pending !== undefined) { return (await pending).slice(); }
    const revision: number = this.revisions.get(ownerId) ?? 0;
    const task: Promise<ForumSearchHistoryEntry[]> = this.load(ownerId, key, revision);
    this.reads.set(ownerId, task);
    try { return (await task).slice(); }
    finally { if (this.reads.get(ownerId) === task) { this.reads.delete(ownerId); } }
  }
  private async load(ownerId: number, key: string, revision: number): Promise<ForumSearchHistoryEntry[]> {
    const raw: string = await this.storage.read(key);
    if ((this.revisions.get(ownerId) ?? 0) !== revision) { return this.cached.get(ownerId) ?? []; }
    let entries: ForumSearchHistoryEntry[] = [];
    try {
      const decoded: ForumSearchHistoryEntry[] = JSON.parse(raw || '[]') as ForumSearchHistoryEntry[];
      if (Array.isArray(decoded)) { entries = normalizeForumSearchHistory(decoded); }
    } catch { /* A damaged history must not prevent searching. */ }
    this.cached.set(ownerId, entries);
    return entries;
  }
  private async save(ownerId: number, entries: ForumSearchHistoryEntry[]): Promise<void> {
    const key: string = this.key(ownerId);
    const payload: string = JSON.stringify(entries);
    const previous: Promise<void> = this.writes.get(ownerId) ?? Promise.resolve();
    const task: Promise<void> = previous.catch((): void => {}).then(async (): Promise<void> => {
      await this.storage.write(key, payload);
    });
    this.writes.set(ownerId, task);
    try { await task; }
    finally { if (this.writes.get(ownerId) === task) { this.writes.delete(ownerId); } }
  }
  async remember(ownerId: number, entry: ForumSearchHistoryEntry): Promise<ForumSearchHistoryEntry[]> {
    const clearVersion: number = this.clearVersions.get(ownerId) ?? 0;
    await this.read(ownerId);
    if ((this.clearVersions.get(ownerId) ?? 0) !== clearVersion) { return (this.cached.get(ownerId) ?? []).slice(); }
    const entries: ForumSearchHistoryEntry[] = normalizeForumSearchHistory([entry].concat(this.cached.get(ownerId) ?? []));
    this.cached.set(ownerId, entries);
    this.revisions.set(ownerId, (this.revisions.get(ownerId) ?? 0) + 1);
    await this.save(ownerId, entries);
    return (this.cached.get(ownerId) ?? []).slice();
  }
  async remove(ownerId: number, entry: ForumSearchHistoryEntry): Promise<ForumSearchHistoryEntry[]> {
    await this.read(ownerId);
    const id: string = forumSearchHistoryId(entry);
    const entries: ForumSearchHistoryEntry[] = (this.cached.get(ownerId) ?? [])
      .filter((candidate: ForumSearchHistoryEntry): boolean => forumSearchHistoryId(candidate) !== id);
    this.cached.set(ownerId, entries);
    this.revisions.set(ownerId, (this.revisions.get(ownerId) ?? 0) + 1);
    await this.save(ownerId, entries);
    return (this.cached.get(ownerId) ?? []).slice();
  }
  async clear(ownerId: number): Promise<void> {
    this.key(ownerId);
    this.cached.set(ownerId, []);
    this.revisions.set(ownerId, (this.revisions.get(ownerId) ?? 0) + 1);
    this.clearVersions.set(ownerId, (this.clearVersions.get(ownerId) ?? 0) + 1);
    await this.save(ownerId, []);
  }
}

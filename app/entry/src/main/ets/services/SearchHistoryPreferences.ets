import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { ForumSearchHistoryStorage } from './SearchHistoryStore';

export class ForumSearchHistoryPreferences implements ForumSearchHistoryStorage {
  private context: common.UIAbilityContext;
  private scopeSuffix: string;
  private store: preferences.Preferences | undefined = undefined;
  private opening: Promise<preferences.Preferences> | undefined = undefined;
  constructor(context: common.UIAbilityContext, topicScopeId: number = 0) {
    if (!Number.isSafeInteger(topicScopeId) || topicScopeId < 0) { throw new Error('无效的话题搜索范围'); }
    this.context = context; this.scopeSuffix = topicScopeId > 0 ? `_topic_${topicScopeId}` : '';
  }
  private async open(): Promise<preferences.Preferences> {
    if (this.store !== undefined) { return this.store; }
    const pending: Promise<preferences.Preferences> = this.opening ?? preferences.getPreferences(this.context, { name: 'forum_search_history_v1' });
    this.opening = pending;
    try { this.store = await pending; return this.store; }
    finally { if (this.opening === pending) { this.opening = undefined; } }
  }
  async read(key: string): Promise<string> {
    const store: preferences.Preferences = await this.open();
    const value: preferences.ValueType = await store.get(key + this.scopeSuffix, '[]');
    return typeof value === 'string' ? value : '[]';
  }
  async write(key: string, value: string): Promise<void> {
    const store: preferences.Preferences = await this.open();
    await store.put(key + this.scopeSuffix, value); await store.flush();
  }
}

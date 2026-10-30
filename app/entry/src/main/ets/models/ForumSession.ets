import { DiscourseUser } from './ForumModels';
import { forumApi, RequestCancellation, ForumApiError } from '../services/ForumApi';

@ObservedV2
export class ForumSession {
  @Trace foreground: boolean = false;
  @Trace user: DiscourseUser | undefined = undefined;
  @Trace unread: number = 0;
  @Trace loading: boolean = false;
  @Trace revision: number = 0;
  @Trace lastError: string = '';
  private pollingTimer: number = -1;
  private unreadBusy: boolean = false;
  private failures: number = 0;
  private nextPollAt: number = 0;
  private request: RequestCancellation | undefined = undefined;
  private unreadRequest: RequestCancellation | undefined = undefined;

  private resetUnread(): void {
    this.unreadRequest?.cancel();
    this.unreadRequest = undefined;
    this.unreadBusy = false;
    this.unread = 0;
    this.failures = 0;
    this.nextPollAt = 0;
  }

  async refresh(): Promise<boolean> {
    this.request?.cancel();
    const token: RequestCancellation = new RequestCancellation();
    this.request = token;
    this.loading = true;
    try {
      const user: DiscourseUser | undefined = await forumApi.fetchCurrentUser(token);
      if (this.request !== token) { return false; }
      if ((this.user?.id || 0) !== (user?.id || 0)) {
        this.resetUnread();
        forumApi.resetSessionContext();
      }
      this.user = user;
      this.lastError = '';
      this.revision++;
      if (user !== undefined) { await this.refreshUnread(); }
      else { this.unread = 0; }
      return true;
    } catch (error) {
      if (this.request === token) {
        this.lastError = error instanceof ForumApiError ? error.message : '暂时无法确认登录状态';
      }
      return false;
    } finally {
      if (this.request === token) { this.loading = false; }
    }
  }

  async refreshUnread(): Promise<void> {
    if (this.user === undefined || this.unreadBusy || Date.now() < this.nextPollAt) { return; }
    this.unreadBusy = true;
    const ownerId: number = this.user.id;
    const revision: number = this.revision;
    const request: RequestCancellation = new RequestCancellation();
    this.unreadRequest = request;
    try {
      const result = await forumApi.fetchUnreadSummary(request);
      if (this.unreadRequest !== request || this.user?.id !== ownerId || this.revision !== revision) { return; }
      this.unread = result.count;
      this.failures = 0;
    } catch {
      if (this.unreadRequest !== request || this.user?.id !== ownerId || this.revision !== revision) { return; }
      this.failures++;
      this.nextPollAt = Date.now() + Math.min(300000, 10000 * Math.pow(2, this.failures));
    } finally { if (this.unreadRequest === request) { this.unreadBusy = false; } }
  }

  startPolling(): void {
    this.stopPolling();
    this.pollingTimer = setInterval(() => { void this.refreshUnread(); }, 10000);
  }

  stopPolling(): void {
    if (this.pollingTimer >= 0) { clearInterval(this.pollingTimer); this.pollingTimer = -1; }
  }

  async logout(): Promise<void> {
    this.request?.cancel();
    this.resetUnread();
    await forumApi.logout();
    this.user = undefined;
    this.unread = 0;
    this.lastError = '';
    this.revision++;
  }

  dispose(): void { this.stopPolling(); this.request?.cancel(); this.unreadRequest?.cancel(); }
}

export const forumSession: ForumSession = new ForumSession();

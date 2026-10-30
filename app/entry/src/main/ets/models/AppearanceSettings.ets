import { PersistenceV2 } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { defaultTopicFeedIndex, defaultTopicFeedValue } from '../services/ReadingPreferences';

const APPEARANCE_STORAGE_KEY: string = 'appearance_settings_v1';
const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'AppearanceSettings';

@ObservedV2
export class AppearanceSettings {
  @Trace effectLevel: number = 2;
  @Trace reduceMotion: boolean = false;
  @Trace highContrast: boolean = false;
  @Trace themeMode: number = 0;
  @Trace treeView: boolean = true;
  @Trace autoRefresh: boolean = false;
  @Trace defaultFeed: string = 'latest';
  @Trace immersiveTopics: boolean = false;
  @Trace openAtUnread: boolean = true;
}

// Runtime storage status is separate from the persisted preferences.
@ObservedV2
export class AppearanceStorageStatus {
  @Trace available: boolean = true;
  @Trace message: string = '';
}

export const appearanceStorageStatus: AppearanceStorageStatus = new AppearanceStorageStatus();
let currentSettings: AppearanceSettings | undefined = undefined;

function storageFailed(reason: string): void {
  appearanceStorageStatus.available = false;
  appearanceStorageStatus.message = '外观设置暂时无法保存，当前选择仍可使用。';
  hilog.warn(LOG_DOMAIN, LOG_TAG, 'Appearance persistence failed: %{public}s', reason);
}

function onPersistenceError(key: string, reason: string): void {
  if (key === APPEARANCE_STORAGE_KEY) {
    storageFailed(reason);
  }
}

function validateSettings(settings: AppearanceSettings): void {
  if (typeof settings.effectLevel !== 'number' || !Number.isInteger(settings.effectLevel) ||
    settings.effectLevel < 0 || settings.effectLevel > 3) {
    settings.effectLevel = 2;
  }
  if (typeof settings.reduceMotion !== 'boolean') {
    settings.reduceMotion = false;
  }
  if (typeof settings.highContrast !== 'boolean') {
    settings.highContrast = false;
  }
  if (!Number.isInteger(settings.themeMode) || settings.themeMode < 0 || settings.themeMode > 2) {
    settings.themeMode = 0;
  }
  if (typeof settings.treeView !== 'boolean') { settings.treeView = true; }
  if (typeof settings.autoRefresh !== 'boolean') { settings.autoRefresh = false; }
  settings.defaultFeed = defaultTopicFeedValue(defaultTopicFeedIndex(settings.defaultFeed));
  if (typeof settings.immersiveTopics !== 'boolean') { settings.immersiveTopics = false; }
  if (typeof settings.openAtUnread !== 'boolean') { settings.openAtUnread = true; }
}

/**
 * Call from a ComponentV2 field initializer after UI creation, never before
 * WindowStage.loadContent. Keep this instance and mutate its Trace fields;
 * PersistenceV2 automatically saves these changes and restores them next launch.
 */
export function loadAppearanceSettings(): AppearanceSettings {
  if (currentSettings !== undefined) {
    return currentSettings;
  }

  try {
    PersistenceV2.notifyOnError(onPersistenceError);
    const restored: AppearanceSettings | undefined = PersistenceV2.globalConnect({
      type: AppearanceSettings,
      key: APPEARANCE_STORAGE_KEY,
      defaultCreator: (): AppearanceSettings => new AppearanceSettings()
    });
    if (restored !== undefined) {
      validateSettings(restored);
      currentSettings = restored;
      return restored;
    }
    storageFailed('unavailable');
  } catch {
    storageFailed('initialization');
  }

  // In-memory preferences keep the UI usable if storage cannot be connected.
  const fallback: AppearanceSettings = new AppearanceSettings();
  currentSettings = fallback;
  return fallback;
}

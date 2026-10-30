import { uiMaterial } from '@kit.ArkUI';
import { AppearanceSettings, appearanceStorageStatus } from '../models/AppearanceSettings';
import { EffectPreset, effectPresets, materialFor } from '../services/MaterialPolicy';
import { MaterialPreview } from '../components/MaterialPreview';
import { TopicFeedFilterOption, topicFeedFilters } from '../models/ForumModels';
import { defaultTopicFeedIndex, defaultTopicFeedValue } from '../services/ReadingPreferences';

@ComponentV2
export struct AppearancePage {
  @Param appearance: AppearanceSettings = new AppearanceSettings();

  @Builder
  effectOption(preset: EffectPreset) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 16 }) {
        Column({ space: 5 }) {
          Text(preset.label).fontSize(17).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
          Text(preset.description).fontSize(13).fontColor($r('app.color.text_secondary')).lineHeight(20)
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        SymbolGlyph(this.appearance.effectLevel === preset.id ? $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.circle'))
          .fontSize(23).fontColor([this.appearance.effectLevel === preset.id ? $r('app.color.accent') : $r('app.color.text_secondary')])
      }.width('100%').padding(18)
    }.width('100%').constraintSize({ minHeight: 76 }).borderRadius(22)
      .backgroundColor(this.appearance.effectLevel === preset.id ? $r('app.color.selected_background') : $r('app.color.surface'))
      .id(`effect_level_${preset.id}`)
      .accessibilityText(`${preset.label}，${preset.description}${this.appearance.effectLevel === preset.id ? '，已选中' : ''}`)
      .onClick(() => { this.appearance.effectLevel = preset.id; }).systemMaterial(uiMaterial.Material.empty)
  }

  build() {
    Scroll() {
      Column({ space: 24 }) {
        Column({ space: 8 }) {
          Text('外观与阅读').fontSize(32).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
          Text('让交流，以你喜欢的方式呈现。').fontSize(16).fontColor($r('app.color.text_secondary'))
        }.alignItems(HorizontalAlign.Start).width('100%').padding({ top: 24 })
        Column({ space: 12 }) {
          Text('主题').fontSize(20).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
          Row({ space: 8 }) {
            Button('跟随系统', { type: ButtonType.Capsule }).layoutWeight(1).height(42)
              .fontSize(14).backgroundColor(this.appearance.themeMode === 0 ? $r('app.color.accent') : $r('app.color.surface'))
              .fontColor(this.appearance.themeMode === 0 ? $r('app.color.on_accent') : $r('app.color.text_primary'))
              .onClick(() => { this.appearance.themeMode = 0; })
            Button('浅色', { type: ButtonType.Capsule }).layoutWeight(1).height(42)
              .fontSize(14).backgroundColor(this.appearance.themeMode === 1 ? $r('app.color.accent') : $r('app.color.surface'))
              .fontColor(this.appearance.themeMode === 1 ? $r('app.color.on_accent') : $r('app.color.text_primary'))
              .onClick(() => { this.appearance.themeMode = 1; })
            Button('深色', { type: ButtonType.Capsule }).layoutWeight(1).height(42)
              .fontSize(14).backgroundColor(this.appearance.themeMode === 2 ? $r('app.color.accent') : $r('app.color.surface'))
              .fontColor(this.appearance.themeMode === 2 ? $r('app.color.on_accent') : $r('app.color.text_primary'))
              .onClick(() => { this.appearance.themeMode = 2; })
          }.width('100%')
        }.width('100%').alignItems(HorizontalAlign.Start)
        MaterialPreview({ appearance: this.appearance })
        Column({ space: 12 }) {
          Text('效果等级').fontSize(20).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary')).margin({ bottom: 4 })
          ForEach(effectPresets, (preset: EffectPreset) => { this.effectOption(preset); },
            (preset: EffectPreset): string => preset.id.toString())
          Text('效果随设备能力和系统光感设置自动适配。')
            .fontSize(13).lineHeight(20).fontColor($r('app.color.text_secondary'))
        }.alignItems(HorizontalAlign.Start).width('100%')
        Column({ space: 20 }) {
          Row({ space: 16 }) {
            Column({ space: 6 }) {
              Text('减少动态效果').fontSize(17).fontColor($r('app.color.text_primary'))
              Text('减少弹性形变和切换动画，保留跟随触点的高光。')
                .fontSize(13).lineHeight(20).fontColor($r('app.color.text_secondary'))
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.appearance.reduceMotion })
              .selectedColor($r('app.color.accent')).id('reduce_motion').accessibilityText('减少动态效果')
              .onChange((value: boolean) => { this.appearance.reduceMotion = value; })
              .systemMaterial(materialFor(this.appearance))
          }
          Divider().color($r('app.color.divider'))
          Row({ space: 16 }) {
            Column({ space: 6 }) {
              Text('高对比度').fontSize(17).fontColor($r('app.color.text_primary'))
              Text('使用实色背景，优先保证内容清晰。')
                .fontSize(13).lineHeight(20).fontColor($r('app.color.text_secondary'))
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.appearance.highContrast })
              .selectedColor($r('app.color.accent')).id('high_contrast').accessibilityText('高对比度')
              .onChange((value: boolean) => { this.appearance.highContrast = value; })
              .systemMaterial(materialFor(this.appearance))
          }
        }.width('100%').padding(20).backgroundColor($r('app.color.surface')).borderRadius(24)
        Column({ space: 20 }) {
          Text('阅读').fontSize(20).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).width('100%')
          Row({ space: 14 }) {
            Column({ space: 6 }) {
              Text('默认话题列表').fontSize(17).fontColor($r('app.color.text_primary'))
              Text('下次打开应用时显示的列表。').fontSize(13)
                .fontColor($r('app.color.text_secondary')).lineHeight(20)
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            Select(topicFeedFilters.map((option: TopicFeedFilterOption): SelectOption => { return { value: option.label }; }))
              .selected(defaultTopicFeedIndex(this.appearance.defaultFeed))
              .value(topicFeedFilters[defaultTopicFeedIndex(this.appearance.defaultFeed)].label)
              .font({ size: 14 }).fontColor($r('app.color.accent')).backgroundColor(Color.Transparent)
              .onSelect((index: number): void => { this.appearance.defaultFeed = defaultTopicFeedValue(index); })
              .id('default_topic_feed').accessibilityText('默认话题列表')
              .systemMaterial(uiMaterial.Material.empty)
          }
          Divider().color($r('app.color.divider'))
          Row({ space: 14 }) {
            Column({ space: 6 }) {
              Text('沉浸话题').fontSize(17).fontColor($r('app.color.text_primary'))
              Text('向下阅读时收起操作栏，反向滚动时展开。').fontSize(13)
                .fontColor($r('app.color.text_secondary')).lineHeight(20)
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.appearance.immersiveTopics })
              .selectedColor($r('app.color.accent')).id('immersive_topics').accessibilityText('沉浸话题')
              .onChange((value: boolean): void => { this.appearance.immersiveTopics = value; })
              .systemMaterial(materialFor(this.appearance))
          }
          Divider().color($r('app.color.divider'))
          Row({ space: 14 }) {
            Column({ space: 6 }) {
              Text('打开首个未读').fontSize(17).fontColor($r('app.color.text_primary'))
              Text('从话题列表进入时，继续上次阅读的位置。').fontSize(13)
                .fontColor($r('app.color.text_secondary')).lineHeight(20)
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.appearance.openAtUnread })
              .selectedColor($r('app.color.accent')).id('open_at_unread').accessibilityText('打开首个未读')
              .onChange((value: boolean): void => { this.appearance.openAtUnread = value; })
              .systemMaterial(materialFor(this.appearance))
          }
          Divider().color($r('app.color.divider'))
          Row({ space: 14 }) {
            Column({ space: 6 }) {
              Text('楼中楼').fontSize(17).fontColor($r('app.color.text_primary'))
              Text('按回复关系排列，默认预览 3 条子回复。').fontSize(13)
                .fontColor($r('app.color.text_secondary')).lineHeight(20)
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.appearance.treeView }).selectedColor($r('app.color.accent'))
              .onChange((value: boolean) => { this.appearance.treeView = value; }).id('tree_view')
              .systemMaterial(materialFor(this.appearance))
          }
          Divider().color($r('app.color.divider'))
          Row({ space: 14 }) {
            Column({ space: 6 }) {
              Text('自动刷新最新话题').fontSize(17).fontColor($r('app.color.text_primary'))
              Text('浏览最新页时每 10 分钟刷新一次。').fontSize(13)
                .fontColor($r('app.color.text_secondary')).lineHeight(20)
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.appearance.autoRefresh }).selectedColor($r('app.color.accent'))
              .onChange((value: boolean) => { this.appearance.autoRefresh = value; }).id('auto_refresh')
              .systemMaterial(materialFor(this.appearance))
          }
        }.width('100%').padding(20).backgroundColor($r('app.color.surface')).borderRadius(24)
        if (!appearanceStorageStatus.available) {
          Text('设置暂时无法保存，重新打开应用后可能恢复默认。')
            .fontSize(13).lineHeight(20).fontColor($r('app.color.text_secondary')).id('storage_unavailable')
        }
        Button('恢复默认设置', { type: ButtonType.Capsule })
          .height(48).width('100%').fontSize(15).fontColor($r('app.color.accent'))
          .backgroundColor($r('app.color.surface')).id('reset_appearance')
          .onClick(() => {
            this.appearance.effectLevel = 2;
            this.appearance.reduceMotion = false;
            this.appearance.highContrast = false;
            this.appearance.themeMode = 0;
            this.appearance.treeView = true;
            this.appearance.autoRefresh = false;
            this.appearance.defaultFeed = 'latest';
            this.appearance.immersiveTopics = false;
            this.appearance.openAtUnread = true;
          }).systemMaterial(uiMaterial.Material.empty)
      }.width('100%').constraintSize({ maxWidth: 600 }).padding({ left: 24, right: 24, bottom: 112 })
    }.width('100%').height('100%').scrollBar(BarState.Off)
  }
}

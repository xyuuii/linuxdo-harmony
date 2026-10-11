import { uiMaterial } from '@kit.ArkUI';
import { hdsMaterial, SystemMaterialParams } from '@kit.UIDesignKit';
import { AppearanceSettings } from '../models/AppearanceSettings';

export interface EffectPreset {
  id: number;
  label: string;
  description: string;
}

export const effectPresets: EffectPreset[] = [
  { id: 0, label: '关闭', description: '使用实色表面，关闭沉浸式材质。' },
  { id: 1, label: '轻柔', description: '柔和通透，减少装饰与动态反馈。' },
  { id: 2, label: '标准', description: '平衡清晰度、层次与触摸光感。' },
  { id: 3, label: '丰富', description: '更通透的材质与更丰富的交互反馈。' }
];

export function materialSupported(): boolean {
  try {
    return uiMaterial.isImmersiveMaterialSupported();
  } catch {
    return false;
  }
}

/** Use with a component's systemMaterial(materialFor(settings)) attribute. */
export function materialFor(settings: AppearanceSettings): uiMaterial.Material {
  if (settings.effectLevel < 1 || settings.effectLevel > 3 || settings.highContrast || !materialSupported()) {
    return uiMaterial.Material.empty;
  }

  try {
    if (settings.effectLevel === 1) {
      return new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.REGULAR,
        materialColor: $r('app.color.material_tint'),
        applyShadow: false,
        interactive: false,
        lightEffect: null
      });
    }

    if (settings.effectLevel === 2) {
      return new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.REGULAR,
        materialColor: $r('app.color.material_tint'),
        applyShadow: true,
        interactive: false,
        // Direct touch illumination stays usable when transition/elastic motion is reduced.
        lightEffect: {}
      });
    }

    return new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.THIN,
      materialColor: $r('app.color.material_tint'),
      applyShadow: true,
      interactive: !settings.reduceMotion,
      lightEffect: {}
    });
  } catch {
    return uiMaterial.Material.empty;
  }
}

/** HdsTabs uses SystemMaterialParams, independently of ArkUI Material objects. */
export function tabMaterialFor(settings: AppearanceSettings): SystemMaterialParams {
  const disabled: SystemMaterialParams = { materialType: hdsMaterial.MaterialType.NONE };
  if (settings.effectLevel < 1 || settings.effectLevel > 3 || settings.highContrast || settings.reduceMotion) {
    // HDS exposes no explicit switch for light feedback or interactive distortion.
    return disabled;
  }

  try {
    const types: hdsMaterial.MaterialType[] = hdsMaterial.getSystemMaterialTypes();
    if (types.indexOf(hdsMaterial.MaterialType.IMMERSIVE) < 0) {
      return disabled;
    }
    let level: hdsMaterial.MaterialLevel = hdsMaterial.MaterialLevel.SMOOTH;
    if (settings.effectLevel === 2) {
      level = hdsMaterial.MaterialLevel.GENTLE;
    } else if (settings.effectLevel === 3) {
      level = hdsMaterial.MaterialLevel.EXQUISITE;
    }
    return { materialType: hdsMaterial.MaterialType.IMMERSIVE, materialLevel: level };
  } catch {
    return disabled;
  }
}

import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor } from '@kit.ArkData';

/** Share only the canonical forum link, without session or redirect parameters. */
export function canonicalPostUrl(topicId: number, postNumber: number): string {
  if (!Number.isSafeInteger(topicId) || topicId <= 0 || !Number.isSafeInteger(postNumber) || postNumber <= 0) {
    throw new Error('楼层链接无效，请刷新帖子后重试。');
  }
  return `https://linux.do/t/${topicId}/${postNumber}`;
}

export async function copyPostLink(topicId: number, postNumber: number): Promise<void> {
  const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN,
    canonicalPostUrl(topicId, postNumber));
  await pasteboard.getSystemPasteboard().setData(data);
}

/** Opening the system panel is not a completed share; the user chooses the destination. */
export async function sharePostLink(context: common.UIAbilityContext, topicId: number, postNumber: number,
  title: string, anchorId: string, onDismiss: () => void = (): void => {}): Promise<void> {
  const link: string = canonicalPostUrl(topicId, postNumber);
  if (!canIUse('SystemCapability.Collaboration.SystemShare')) {
    throw new Error('当前设备暂不支持系统分享，可以复制楼层链接。');
  }
  const data: systemShare.SharedData = new systemShare.SharedData({
    utd: uniformTypeDescriptor.UniformDataType.HYPERLINK,
    content: link,
    title: title.trim().slice(0, 200) || 'LINUX DO',
    description: postNumber === 1 ? 'LINUX DO 话题' : `LINUX DO · 第 ${postNumber} 楼`
  });
  const controller: systemShare.ShareController = new systemShare.ShareController(data);
  const dismissed: () => void = (): void => {
    controller.off('dismiss', dismissed);
    onDismiss();
  };
  controller.on('dismiss', dismissed);
  try {
    await controller.show(context, {
      anchor: anchorId,
      selectionMode: systemShare.SelectionMode.SINGLE,
      previewMode: systemShare.SharePreviewMode.DEFAULT
    });
  } catch (error) {
    controller.off('dismiss', dismissed);
    throw new Error(error instanceof Error ? error.message : '暂时无法打开系统分享面板。');
  }
}

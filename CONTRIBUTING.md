# 参与贡献

欢迎提交 Issue 和 Pull Request。此仓库是独立的鸿蒙原生实现，Android 参考项目及归属见 [THIRD_PARTY.md](THIRD_PARTY.md)。

## 开发与验证

1. 安装 DevEco Studio、HarmonyOS API 26 SDK 和 devecocli，执行 `./scripts/build.sh`。
2. 执行 `node --test tests/*.test.mjs`；其他安装路径用 `DEVECO_TYPESCRIPT_PATH` 指向 TypeScript 的 `lib/typescript.js`。无需 SDK 的离线测试方式见 README。
3. UI 改动用模拟器或真机验证，并提供可复现步骤及不含账号资料的截图。GitHub Actions 只检查离线逻辑，不能替代完整 SDK 构建和设备测试。
4. 在 PR 中说明问题、结果和验证范围。请保留原生 ArkUI V2、系统光感、可访问性和现有数据边界。

## 代码与数据边界

- 不提交签名配置、证书、密码、Cookie、OAuth 参数、私信或完整设备日志。`app/build-profile.json5` 是本机配置，模板为 `app/build-profile.example.json5`。
- 论坛 API/原生桥限 linux.do 同源，身份提供方导航只使用精确的 HTTPS 主机名单。公开外域图片不能携带论坛凭据。
- 写请求不自动重放；缺失权限视为未授权，换账号取消旧请求并清理显示数据。
- 只贡献你有权提交的代码与资源。原 Android 仓库未声明许可证，不直接复制其源码和资产；保留 Apache-2.0 版权及 NOTICE。

提交的贡献按本仓库 Apache-2.0 许可处理，除非明确说明其他条款并由维护者确认。安全问题请按 [SECURITY.md](SECURITY.md) 处理。

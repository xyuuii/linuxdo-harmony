# 鸿蒙 ECH 直连方案验证

验证开始：2026-10-18；结果整理：2026-10-19。设备：Pura X View / HarmonyOS API26。早期验证为 Wi-Fi、VPN/代理关闭；后续用户保持 5G、VPN/代理关闭，新增结果见下方专项记录。工具没有切换系统网络、安装证书或清除账号数据。

用户曾要求停止真机操作、改用模拟器，该暂停阶段只操作 CodexPhone。随后用户明确表示手机重新连接、可以验证，并再次确认 Wi-Fi、VPN/代理关闭；本页新增的真机业务与重启结果来自这次重新授权后的实际操作。

## 当前结论

**在早期 Wi-Fi 及本次手机 5G 条件下，真机均已跑通 ArkWeb ECH、论坛读取和保留登录会话后的自动重启恢复。** 10月19日补齐基础图片读取并取得用户恢复确认；5G 当前采用 edge DoH，三次启动恢复为 2.394、2.711、2.242 秒。正常源码尚未默认开启试验 DoH；上传、论坛写入和长期过盾恢复仍未验收，当前交付为本地签名原型。

采用开源 Rustls 0.23.45 + AWS-LC HPKE，保留 WebPKI 证书及主机名校验。探针在签名应用的原型副本内通过 N-API 异步执行，使用应用自己的 INTERNET 权限；没有改变设备安全策略。原项目的日常网络层没有接入实验库。

## 5G 启动恢复专项（2026-10-19）

同一手机 5G 下，kudo DoH 原生查询未完成，返回 EAGAIN 超时类错误；edge DoH 则取得 71 字节 ECHConfigList。对两条目标地址，普通 TLS 均连接重置，强制 ECH 均证书校验通过、ECH Accepted、HTTP200 且 trace 确认 sni=encrypted。该结果区分了本次 DoH 可用性与目标 ECH 能力，不能据此宣称某个服务永久故障或某运营商普遍不支持。

ArkWeb 基线捕获主框架 -101（连接重置）后仍提交同网址的错误文档；旧恢复仅看 controller URL 和 page-end，误发 CSRF 并立即退出。另有页面第 12 秒才就绪、恢复第 10 秒已退出的记录。现改为确认本次新文档提交与实际同源、顶层、交互就绪、桥可用，统一 25 秒总预算；仅对主框架 -101 自动重连一次，临时只读探测最多三次。兼容 Commit 先于 PageBegin 的实际事件顺序，Cookie 保存后复核文档及导航代次；取消、销毁、账号代际与写请求保护继续有效。账号代际重置不再继承上一代冷却。

只修恢复、仍用 kudo 的手机启动再次捕获两次 -101；切换 `--edge-doh` 后三次启动/进程重启均自动获得有效 JSON CSRF200、服务端域名加密回执及真实业务读取，无需手动重试。301 项回归（会话专项 33 项）、普通版及 ECH 原型编译签名通过。最终签名原型保留数据安装到手机，证据、HAP、SHA256 和诊断在本机忽略目录 `artifacts/session-startup-fix-20261019/`。

复现构建使用 `python3 experiments/ech-probe/prepare-prototype.py --browser-trial --edge-doh`；添加 `--startup-diagnostics` 可记录不含账号、URL、Cookie 和正文的阶段/就绪分类/数字错误码。省略 `--edge-doh` 保留 kudo 对照。未部署或据以归因关闭自动预连接的实验。当前结论只覆盖本机网络和当时服务状态，仍不保证长期可用性或所有运营商。

## 真机已取得的证据

手机自行使用 `https://kudo.ddd.oaifree.com/query-dns` 查询 A 与 HTTPS 记录，取得 71 字节的 ECHConfigList。对 `104.20.16.234` 和 `172.66.166.61`，普通 TLS 1.3 对照均被连接重置；相同 IP 的强制 ECH 请求均得到：

```json
{
  "certificate_verified": true,
  "ech_status": "Accepted",
  "http_status": 200,
  "trace": { "h": "linux.do", "sni": "encrypted", "tls": "TLSv1.3" },
  "ech_trace_confirmed": true
}
```

这组成功不依赖电脑提供 DNS 配置。更早的短期配置对照也曾得到相同的成功回执，但该路径仅用于隔离握手问题，不能作为手机独立解析的证明。配置按 DNS TTL 过期，探针不会延长 TTL 或把过期配置当成功。

第二个社区入口 `https://edge.1molchuan.top/linuxdo` 也独立完成了 DoH → ECH：本次选取其返回的前两个 IP（`172.64.146.198`、`172.64.229.42`），普通 TLS 对照均被重置，强制 ECH 均通过证书校验、返回 HTTP200 和 `sni=encrypted`。该结果仅证明本次节点可用，不是长期可用性保证。

**ArkWeb 也已取得真机成功回执。** kudo DoH 下，私密 Web 返回 `TLSv1.3 · 服务端确认域名已加密`，见 `phone-arkweb-final.log`。同次 NetworkKit 原生请求仍返回 2300999，说明仅给 NetworkKit 配置 DoH 并不等于启用 ECH。

## 仍未通过的部分

- `cloudflare-dns.com` 通过本次选定的 `1.1.1.1:443` DoH 入口请求超时；不代表其全部地址或所有网络均不可用。
- 使用 ECH 请求 `/latest.json` 可以完成证书校验与 TLS 握手，但返回 HTTP 403 且 `cf-mitigated: challenge`。采用当前 ArkWeb 的 User-Agent 和常规请求头、仍不带 Cookie 的对照，同样返回挑战。不能把 TLS 成功当作论坛接口可用。
- 带 UA 的无 Cookie 原生接口仍被挑战。后续真机已通过现有 ArkWeb 登录会话的论坛读取，但新登录、图片、上传、论坛写入和长期 clearance 过期恢复仍未验收。

## 验证约束与必要修正

探针只允许两个公开目标和只读 trace/公开话题路径，不发送账号 Cookie、密码或授权令牌。ECH 被拒绝时不会继续用明文 SNI 发送业务请求。摘要不保留 trace 中的本机 IP，不记录网页正文、TLS 会话密钥或 Cookie。

DNS 响应的问题最初被探针误判：Hickory 将线上的域名表示为完整域名，而最初的请求名未带根标签。已规范为 FQDN，并增加序列化往返的回归检查；修复后才取得上述手机独立 DoH 成功证据。另修正了不完整 HTTP chunk 的检查，避免把截断响应当成功。

隐藏 Web 的探测原来依赖渲染后的 `innerText`。现改为 `textContent` 读取 DOM 原始文本，并增加“innerText 为空但正文存在”的回归场景。之前的无回执不能用来判定 ArkWeb 不支持 ECH；修正后的真机探测已得到有效回执。

## 后续接入路径

### 重新授权后的真机业务与冷启动验证

同签名覆盖安装保留数据，未重新输入密码、清 Cookie 或修改系统网络。先通过现有“打开网页登录或验证 → 已完成登录或验证，返回应用”流程，取得浏览器请求通道的实际 HTTP200；首页话题、帖子主楼及已有账号显示均正常。

随后定位并修复了三处启动问题：

1. 原型在 Web 绑定后才配置 HttpDNS；仅把调用提前到 Ability 创建阶段又遇到 `SetHttpDns: web engine is nullptr`，接口没有抛异常。原型现先 `initializeWebEngine()`，再配置 HttpDNS，最后创建 Web。此配置仅在实验副本中启用。
2. 应用恢复刚打开论坛首页，组件随后加载初始 `about:blank`，导致首页导航 `ERR_ABORTED(-3)`。正常源码将初始 `src` 改为空，由 controller 统一导航；日志中的实际覆盖时序保存在 `startup-navigation-race.log`。
3. 只等整页 `onPageEnd` 会错过已可用的文档；本机一次整页完成远晚于10秒恢复窗口。正常适配器现在允许同源、顶层、`interactive/complete` 的文档发起只读 CSRF 探测，仍要求 HTTP200、JSON、有效 CSRF 和无挑战标记才恢复。取消后的探测仍被阻止；没有放宽会话确认或写请求重放规则。

最终原型首次启动，注册恢复至有效 CSRF 回执约2.6秒，得到 `Automatic recovery=1`。实际请求使用同一个普通 ArkWeb 会话，trace 返回 HTTP200、正确 host、TLSv1.3 与 `sni=encrypted`，随后首页/账号读取均为 `browser=1 read=1 status=200`。UI 核对到5个可见普通话题行、3个置顶行，帖子标题、主楼和阅读工具栏正常。

再次停止并启动应用进程（PID实际变化、保留数据），约3.3秒自动恢复，再次取得同会话的 ECH 回执及浏览器通道 HTTP200。此次没有打开手动验证页；首页4个普通话题行、3个置顶行可见，原有账号仍显示。数量反映当时屏内布局，不作为接口总数。

新增两项文档就绪/取消回归；受影响的会话、启动、认证回归共24项通过，正常工程与原型均通过 API26 SDK 编译和调试签名。原型静态检查无诊断；主源码 MCP 检查曾使用旧的依赖类型产生不一致结果，本次以磁盘源码的完整 SDK 编译及运行验证为准，未将该 MCP 结果计为通过。

证据与当前安装包在本机 `artifacts/ech-native-20261018/phone-browser-trial/`，关键文件为 `document-ready-routes.log`、`final-restart-routes.log`、`final-ui-validation.json`、`validation.json` 和 `packages.json`。日志只记录阶段、通道、状态、字节数和经过筛选的 TLS/SNI 摘要，不保留账号标识、正文、Cookie 或 trace IP。普通会话的 trace 复核复用现有同源请求适配器；独立隐私诊断仍不带论坛凭据。

旧调试目录 `/data/local/tmp/linuxdo-ech-probe-20261018-01` 已删除并确认不存在；手机保留已验证的原型，停在首页。没有向论坛发帖、点赞、上传或删除，未对外发布。

### 2026-10-19 图片通道补验

论坛与已验证CDN图片复用既有浏览器会话和受限响应桥，二进制分块传输到原有账号隔离缓存；普通API目的域未扩大。保留20MiB总上限、取消、导航和账号代际检查，外域不发送论坛凭据。真机取得多次图片HTTP200和解码回执，用户确认图片恢复。表情/小图尺寸、材质投影与灰团、楼中楼默认底色也作了修正；具体边界与验证见[验收记录](acceptance.md)。此补验不涵盖所有外部图片来源或上传。

### 模拟器浏览器请求通道试验

用户要求暂停真机操作后，后续只使用 CodexPhone。原型副本开启 ArkWeb kudo DoH，并尝试复用现有 BrowserTransportAdapter；没有把该设置接入正常源码的默认网络层。

冷启动时采集到的最初读取仍为 `browser=0`，因此未将它计作自动切换成功。通过现有“打开网页登录或验证 → 已完成登录或验证，返回应用”流程后，实际通道日志出现多次 `browser=1 read=1 status=200`：包括首页刷新、话题详情和未读读取。UI 核对到 6 个可见普通话题、3 个置顶话题，详情主楼、标题及阅读工具栏正常渲染，原有账号在个人页可见。日志仅保留通道、读写标志、HTTP 状态和字节数，不含账号标识、接口参数或正文。

这是当时的模拟器结果，不代替真机；自动冷启动问题随后已按上节修复并在真机验证。图片/上传、写操作，以及 clearance 过期后恢复尚未完成专门验收。

### 下一阶段

1. 在已通过的现有登录/读取路径上，继续验收新登录、clearance 过期、账号切换与不同网络。保持同一 UA、Cookie 所有权与账号代际，不自动解验证码或重放论坛写入。
2. 在基础图片路径已通过的基础上继续验证更多外部图片来源和附件上传的一致性；暂不引入另一套拦截器。
3. 完成功能验收后再接入正常应用的设置、DoH 失效处理和发行流程。第三方解析入口本次可用，不代表长期可用。

本轮结论是：真机已验证 ECH 与现有登录会话的论坛读取，修复后也可在进程重启时自动恢复。当前正常调试版仍未默认开启 ECH，原型也不能标为“全功能免代理”或“长期不掉盾”。

## 复现与来源

- [实验源码及复现步骤](../experiments/ech-probe/README.md)。精确依赖见 Cargo.lock。
- [Rustls 官方 ECH 示例](https://github.com/rustls/rustls/blob/v/0.23.35/examples/src/bin/ech-client.rs)；[EchStatus 定义](https://docs.rs/rustls/0.23.45/rustls/client/enum.EchStatus.html)：只有 Accepted 表示服务端接受，GREASE 不算成功。
- [Rust 官方 OpenHarmony 目标说明](https://doc.rust-lang.org/rustc/platform-support/openharmony.html)。
- [OpenHarmony 官方 WebviewController 文档](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-arkweb/arkts-apis-webview-WebviewController.md)：引擎加载、HttpDNS 及 controller 导航 API；具体启动覆盖与空引擎行为由本机日志确认。
- 社区 DoH 地址来自原 Android 项目提交 `a7e6c81bccee1eec8f75542a91fcd6c0f24e11b5` 的公开预设元数据；未复用其闭源 AAR 或原生库。

构建、安装、Rust 回归、设备日志、截图和原型 HAP 保存在本机忽略目录 `artifacts/ech-native-20261018/`。其中 `phone-kudo-fixed.log` 是独立 DoH + ECH 成功证据，`phone-ua-latest.log` 是带当前 UA 的接口 403 对照。未对外上传或发布。

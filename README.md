# HAo Movie

HAo Movie — 影视应用，基于映匣（Yingxia, [jo32/tvbox-silicon](https://github.com/jo32/tvbox-silicon)）改写：以映匣的 Swift + SwiftUI + AVPlayer 代码为底座，按 HAo 的需要删改（见下），不是从零重写。本仓库同样以 **GPL-3.0** 开源（见 `LICENSE`）。

- 当前版本：0.1.0 build 10（2026-11-28）

## 版本历史

- **0.1.0 build 10（2026-11-28）：** 搜索改成映匣的海报网格（136pt 玻璃卡、底部 48pt 玻璃搜索条、历史 chips 上限 12、漂移渐变氛围）；首页 PosterWall 接豆瓣热门电影封面、卡片换映匣的 `.tmdbCardButton()`；详情页做成映匣的标题页（画布背景、居中标题、自动搜源、选集打开内嵌播放器）；播放器弹幕页按映匣移植（弹幕查找、设置页、自动匹配、透明度设置生效）；设置扫了一遍（删死掉的搜索入口、补漫画/小说/云盘/隐私/软件更新入口、TMDB 开关拿掉、DLNA/Emby 改名 HAoMovie）；音乐彻底拿掉（HAoMovie 只做影视）。仍未接：TMDB 详情富化（Worker 未部署）；弹幕官方源要 HAoMovie 自己的 Dandanplay 凭证（未注册），未配时官方源显示不可用。

- **0.1.0 build 9（2026-11-28）：** 发现页按映匣的豆瓣数值重做（2 列海报墙、116 最小列宽、标题 13pt/副标题 11pt、caption "年份 · 豆瓣 x.x"）；历史/收藏顺序按映匣调回；播放器右滑音量按映匣补回来。
- **0.1.0 build 8（2026-11-28）：** 欢迎页按映匣（云盘 + 添加订阅，不自动装源）+ 漫画小说做成可见可用（QuickJS 运行时 + Venera/Legado + 12 个漫画/小说页）。
- **0.1.0 build 6 及更早：** 见 git 历史。

## 参照与许可

- 底座：映匣 Yingxia — Swift + SwiftUI + AVPlayer，原生 TVBox 播放器（直播 + 点播片库 + 全源搜索），GPL-3.0。
- 本仓库基于映匣代码改写，同样 GPL-3.0；署名与协议见 `LICENSE`，第三方声明见应用内「设置 → 开源许可」。
- 不内置任何片源、不内置账号：订阅、历史、收藏只存本机。

## 相对映匣删掉的东西（本版没有）

- 音乐模块；JAR / DEX 插件运行时（只支持 TVBox JSON type 1/4 与 M3U，jar 源不支持）。漫画 / 小说模块在 build 8 已按映匣加上（QuickJS 运行时 + Venera/Legado）。
- 云盘与投屏都在：云盘（Cloud Files / AList / 百度 / 115 / 123 / Quark / 天翼 / WebDAV / 飞牛 / 光芽）与投屏（DLNA、PlayOn）保留，云盘账号在设置里登录。
- TMDB 富化（海报/剧照/演职员/标题 logo 一律用源站自己的图）；Bilibili / 抖音账号登录；Updates（Sparkle）与 Announcements。
- 弹幕查找服务（Dandanplay 未接，无 AppId）：源站自带弹幕与直播间弹幕仍可显示，弹幕样式设置保留。
- 播放链：MKV/AVI/FLV/WMV 重打包（remux）、DASH、容器嗅探、过期链接续期、Apple TV 的 HDR→SDR、哔哩哔哩分段章节——这些格式在 AVPlayer 上播不了会直接失败。
- 订阅文件导入（`ImportedFiles`）保留；内置直播平台（`LivePlatform.all` 为空）：直播只走用户订阅 / M3U 播放列表。
- 压缩的 XMLTV 节目单不支持（会直接报错）。

## 第一版范围（0.1.0）

- 订阅导入：TVBox JSON（URL / 粘贴 / `haomovie://import?url=` 链接），多订阅合并、停用、失败冷却 10 分钟；只支持 JSON 源（type 1/4）。
- 片库：继续观看横轨、源站 chips、分类 chips、海报墙（3 列 + 分页加载）。
- 详情：16:9 大图 + 渐变、简介展开、大播放键、选集数字格、线路分段切换、收藏、断点续播。
- 播放器：AVPlayer，0.5x–4x 倍速、手势（点按显隐、双击 ±10 秒、左滑亮度/右滑音量）、画中画、断点续播、自动连播、跳过片头/片尾（可配）、播放失败不丢历史。
- 全源搜索：并行跑遍各源，结果陆续出现，失败的源可单独重试；搜索历史本机 20 条。
- 直播：M3U / M3U8 分组浏览、频道搜索、收藏（地址由用户在设置里自填）。
- 我的：继续观看、收藏、订阅管理、设置。
- 无启动动画：进应用直接到主界面（chen 2026-11-26 决定）。

## HAo 自己的改动（与映匣不同的地方）

- 页签顺序：首页 / 直播 / 搜索 / 源站 / 收藏 / 历史 / 下载 / 设置（+ 更多）。
- 应用名与链接 scheme：HAo Movie，`haomovie://`；版权行改为 © 2026 HAo Studio。
- 播放规则照映匣的来：断点续播、自动连播、失败不丢历史、倍速范围（chen 2026-11-26：播放规则用他们的，别自己发明）。
- 其余界面只做小幅调整，不整体重设计。

## 结构

```
Sources/HAoMovie/
  App/            入口（HAoMovieApp）、Store、Tab 栏、设置、播放器、详情、直播、下载等界面
  TVCore/         TVBox 订阅/影片/直播/历史/弹幕/字幕等核心模型与网络层
  Resources/      Info.plist、Assets（含 AppIcon）
```

## 构建

- Xcode 26+，iOS 17.0+，Swift 6；首次构建需在 Xcode 里选自己的 Team 签名。
- 图标：黑场记板 + 白播放键（chen 2026-11-26 选定），1024 图在 `Sources/HAoMovie/Resources/Assets.xcassets/AppIcon.appiconset/`。
- 工程文件由 `~/workspace/.tmp/gen_haomovie_pbx.py` 从 `Sources/HAoMovie` 递归扫描生成；改动后重跑并用 `~/workspace/.tmp/pbx_strict_parse.py` 校验。
- 本机无 Xcode 时的验证：`swiftc -parse -swift-version 6` 全文件（只验语法，不验类型；类型检查靠 Xcode 构建）。

## 还没验证（下一腿）

- 真机 / Xcode 构建验证（本机无 Xcode，未验；`swiftc -parse` 只验语法）。
- tvOS / macOS 的条件编译分支：iOS 构建排除在外，但其中引用了已删的成员，改 tvOS/macOS 前要先修。
- 弹幕查找、外挂字幕在线搜索、投屏、下载离线续传。
- 登录（Bilibili/抖音扫码、云盘账号）全部后置；第一版无账号。

# AGENTS.md

macOS 浮层通知工具。常驻进程监听 unix socket，收到一行 JSON 就在屏幕上弹一张卡片，N 秒后淡出。
不用系统通知，所以免打扰模式下照样出现。仓库名 `rote`，运行时标识符仍叫 `toast`（见「命名」）。

## 常用命令

```bash
./build.sh                  # 编译 → build/Toast.app（build/toast 是指向内部二进制的软链）
./install.sh                # 编译 + 若不存在则写 ~/Library/Application Support/Toast/config.json
./smoke.sh                  # 冒烟测试：确保 server 在跑、发三条、数屏上窗口数、失败退出非 0

./build/Toast.app/Contents/MacOS/toast serve &    # 起常驻服务
./build/toast send --json '{"title":"T","body":"B","duration":10}'
./build/toast config                              # 命中的配置文件 + socket 状态 + 关键参数
./build/toast preview --title T --body B --out /tmp/x.png   # 离屏渲染，调样式用

./integrations/pi/install.sh --test    # 装 pi 扩展 + 合并配置 + 发测试通知
```

改完配置**必须重启 server**：配置只在启动时读一次。扩展相反，每次发送都重读。

## 结构

| 路径 | 职责 |
|---|---|
| `Sources/main.m` | 入口，只调 `RunCLI` |
| `Sources/CLI.{h,m}` | 参数解析 + `serve`/`send`/`preview`/`config` 四个子命令 |
| `Sources/Config.{h,m}` | 配置模型、内置默认值、路径搜索链、颜色与类型解析 |
| `Sources/CardView.{h,m}` | 卡片绘制：材质、强调件、文字排版、悬停变换 |
| `Sources/ToastItem.{h,m}` | 单条通知的 `NSPanel`、淡入淡出、停留计时 |
| `Sources/ToastCenter.{h,m}` | 通知队列、选屏、堆叠布局、生命周期 |
| `Sources/Socket.{h,m}` | unix socket：服务端监听与客户端发送 |
| `Sources/Payload.{h,m}` | 一行 JSON → 通知内容 |
| `Info.plist` | `Toast.app` 的 bundle 描述（`LSUIElement`，无 Dock 图标） |
| `build.sh` | 选择 SDK + clang 编译 + ad-hoc 签名 |
| `config.example.json` | 全部配置项与默认值，同时是文档 |
| `integrations/<tool>/` | 每个外部工具一个目录，含 `install.sh` 与钩子代码 |
| `smoke.sh` | 端到端冒烟测试 |

模块之间只通过头文件里的接口往来，需要新能力时先想清楚属于哪个模块；跨模块的公共
helper 放 `Config.h`（配置值解析）或各自模块的 `.m` 里做 static。

## 配置

搜索顺序，**第一个存在的文件整个生效**，不做合并：

| 顺位 | 路径 |
|---|---|
| 显式 | `--config PATH` |
| 显式 | `$PI_TOAST_CONFIG` |
| 1 | `~/Library/Application Support/Toast/config.json` |
| 2 | `~/.config/pi-toast/config.json`（旧位置，保留兼容） |
| 3 | `/Library/Application Support/Toast/config.json` |

一个都不存在时用 `Config.m` 里的内置默认值。`toast config` 会打印命中的文件，没命中时列出
找过的路径。改配置要重启 server：只在启动时读一次；pi 扩展相反，每次发送都重读。

## 构建约束

**需要 macOS 26 SDK。** Liquid Glass（`NSGlassEffectView`）按链接的 SDK 版本门控：用旧 SDK 编译
只能拿到老式 vibrancy，材质、折射、边缘收光都到不了系统效果。`build.sh` 依次尝试：`TOAST_SDK` → `~/Library/Developer/SDKs/MacOSX26.5.sdk` → `xcrun --show-sdk-path`。
未找到 26.x 时构建仍会成功，但只会得到旧版 vibrancy。编译后自检：

```bash
otool -l build/Toast.app/Contents/MacOS/toast | grep -A3 LC_BUILD_VERSION   # sdk 应为 26.x
```

`minos` 保持 14.0：`NSGlassEffectView` 用 `@available(macOS 26.0, *)` 运行时判断，旧系统自动退回
`NSVisualEffectView`。

**源码是 Objective-C + Cocoa，不依赖 Swift 工具链。** clang 直接编译，无包管理器、无第三方依赖。
`build.sh` 编译 `Sources/*.m`，新增模块直接放进目录即可，不用改脚本。不要引入 Swift。

**默认值有三处，改一处要同步另外两处：** `Sources/Config.m` 里的 fallback、`config.example.json`、
`integrations/pi/toast-notify.ts` 的 `DEFAULTS`。配置位置同理：`Config.m` 的搜索链、
`integrations/pi/install.sh`、`toast-notify.ts` 的 `CONFIG_CANDIDATES` 要一致。

**窗口必须是 `NSPanel` + `.nonactivatingPanel` + 透明背景。** 抢焦点或背景不透明都会让玻璃失效。

## 注释

- 一律用中文，代码里的标识符、CLI 输出、日志保持英文
- 不复读函数名或变量名，注释要讲调用方看不出来的东西：为什么这么写、不这么写会坏在哪
- 一句话能说清的就不写两句；删掉「用于……」「这里我们……」「注意：」这类填充
- 句尾不加句号，段落型多行注释也一样
- 公开头文件只写用途和约束；实现细节留在 `.m` 里对应位置
- 宁多勿少：非平凡的控制流、魔数、协议帧格式、配置项的语义、平台的怪癖都要有注释，
  让别人只读代码就能知道为什么，不用去翻 git log 或猜

```objc
// 好：说明取舍
// 收得紧的一道光才像玻璃，铺开的渐变只会把整张卡涂灰

// 不好：复读名字 + 废话 + 句号
// 这个函数用来初始化渐变图层，设置渐变的颜色。
- (void)setupGradientLayer;
```

## 改代码时容易踩的地方

- **`glass.contentView` 的内容不能被重新 parent。** `NSGlassEffectView` 拿到 nil 的 contentView
  就完全不渲染玻璃。内容视图只能挂一次——先判断走的是 glass 还是 fallback 路径。
- **圆角与遮罩用 `maskImage`，不要用 layer 的 `cornerRadius + masksToBounds`**，后者会吞掉
  `NSVisualEffectView` 的背景模糊。
- **`NSScreen.mainScreen` 会跟着 key window 跑**，accessory app 没有 key window 时会退化成跟鼠标。
  取主屏一律用 `NSScreen.screens[0]`。
- **`accept()` 在 macOS 上继承监听 fd 的 `O_NONBLOCK`**，读循环把 `EAGAIN` 当 EOF 会立刻断开客户端。
  接受连接后要清掉 `O_NONBLOCK`；监听 fd 本身必须非阻塞，否则 drain 循环会永久阻塞队列。
- **动画不要用 `NSWindow` 的 `animator`**（在非激活 app 里不生效），也不要用 `dispatch_source`
  （handler 与 source 自引用成环）。用 `NSTimer` 并在回调里 `invalidate`。
- **`cornerRadius` 写 `"capsule"` 表示等于卡片高度一半**；写数字是绝对值。字符串一旦被
  `ConfigNum` 判为无效就会静默落到默认值，改这一块时注意。

## 验证方式

截图不一定可用（未授权屏幕录制会得到全黑图），所以验证优先走这两条不需要授权的路径：

```bash
# 1. 窗口确实出现了、位置和尺寸对不对
python3 -c "import Quartz; print([(w['kCGWindowBounds'],w['kCGWindowAlpha']) for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly,Quartz.kCGNullWindowID) if 'toast' in (w.get('kCGWindowOwnerName','') or '').lower()])"

# 2. 卡片长什么样（离屏渲染，同一套绘制代码）
./build/toast preview --title T --body B --theme dark --bg "#0A0A0A" --out /tmp/x.png

# 3. 像素级核对圆角/渐变
python3 -c "from PIL import Image; im=Image.open('/tmp/x.png').convert('RGB'); print(im.getpixel((340,6)), im.getpixel((340,im.size[1]-6)))"
```

`preview` 会强制关掉 `material`（离屏渲染画不出毛玻璃，只会画成一块灰）并合成到 `--bg` 底色上，
所以它反映形状、排版、渐变，不反映最终质感——材质和玻璃效果只能用眼睛看。

调试开关：`TOAST_DEBUG=1` 让 app 打背景路径/圆角/socket 收包；`PI_TOAST_DEBUG=1` 让扩展打
settle 耗时、payload、未知占位符、发送结果。

## 扩展开发

`integrations/` 下每个工具一个目录，脚本要满足：只合并自己那段配置、不覆盖用户其他键、
提供 `--remove`、有 `--test` 时能自己验证连通性。接入方式只有两种——往 socket 写一行 JSON，
或者 shell out 调 `build/toast send`。

## 命名

仓库叫 `rote`，但运行时标识符是 `toast`：bundle id `dev.rote.toast`、配置目录
`~/Library/Application Support/Toast`（旧 `~/.config/pi-toast` 仍认）、socket `~/.pi-toast/toast.sock`、
launchd 标签 `dev.rote.toast`。
改名会破坏已部署的 socket 路径、配置目录和用户已装的扩展，因此要改就整体迁移并写迁移脚本，
不要只改一半。

## 不要做

- 不要往本文件写进度、状态、待办、变更记录，也不要写任何个人环境的描述（路径、权限、已装的工具）。
- 不要引入系统通知（`UNUserNotificationCenter`）——免打扰下会被吞掉，这正是本项目存在的原因。
- 不要在仓库里提交绝对路径。`launchd/` 下的 plist 是模板，安装时替换占位符。

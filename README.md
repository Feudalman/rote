# rote

macOS 上的浮层通知，第一版（v1 demo）。

一个常驻进程 + unix socket，收一行 JSON，在屏幕上弹一张卡片，N 秒后淡出。不用系统通知，
所以免打扰、专注模式下也照样出现。不是给某个工具专用的，任何程序往 socket 里写 JSON 就能弹。

```
rote/
├── Sources/              Objective-C + Cocoa，按职责分文件
│   ├── main.m            入口，只做子命令分发
│   ├── CLI.{h,m}         参数解析 + serve / send / preview / config
│   ├── Config.{h,m}      配置模型、默认值、路径搜索链、颜色解析
│   ├── CardView.{h,m}    卡片绘制：材质、强调件、排版、悬停
│   ├── ToastItem.{h,m}   单条通知的面板、动画、停留计时
│   ├── ToastCenter.{h,m} 队列、屏幕选择、堆叠布局
│   ├── Socket.{h,m}      unix socket 收发
│   └── Payload.{h,m}     一行 JSON → 通知内容
├── Info.plist           打包成 Toast.app 的 bundle 描述
├── build.sh             编译（需要 macOS 26 SDK，见下）
├── config.example.json  全部配置项 + 默认值
├── install.sh           编译 + 铺配置
├── smoke.sh             冒烟测试：弹三条并校验窗口真的出现了
├── launchd/             登录自启模板（install.sh 会生成填好路径的版本）
└── integrations/        外部工具接入脚本，每个工具一个目录
    └── pi/              pi coding agent 的接入
```

## 安装

```bash
./install.sh                          # 编译 + 写 ~/Library/Application Support/Toast/config.json
./build/Toast.app/Contents/MacOS/toast serve &
./smoke.sh                            # 冒烟测试：弹三条并校验
```

没有设置页面，一切走配置文件，逐项 fallback 到内置默认值，改完要重启 server 才生效。

### 配置文件位置

按顺序找，**第一个存在的整个文件生效**（不做合并）：

| 顺位 | 路径 | 说明 |
|---|---|---|
| — | `--config PATH` | 显式指定；缺了也只用默认值，不回落到下面的路径 |
| — | `$PI_TOAST_CONFIG` | 环境变量，同上 |
| 1 | `~/Library/Application Support/Toast/config.json` | 用户级主位置，`install.sh` 写这里 |
| 2 | `~/.config/pi-toast/config.json` | 旧位置，保留兼容 |
| 3 | `/Library/Application Support/Toast/config.json` | 全机默认，可选 |

一个都不存在时全部用内置默认值，`toast config` 会把找过的路径列出来：

```bash
toast config                            # 命中的文件、socket 状态、关键参数
toast config --config /tmp/try.json     # 试一份候选配置，不动现场的
```

### macOS 26 SDK

`build.sh` 依次尝试：`TOAST_SDK` → `~/Library/Developer/SDKs/MacOSX26.5.sdk` → `xcrun --show-sdk-path`。

这个 SDK 是**外观的门控**：只有链接 macOS 26 SDK 编译，`NSGlassEffectView`
（Liquid Glass）才会生效；用旧 SDK 编译，系统只给兼容模式下的老式 vibrancy，
怎么调都到不了苹果那个质感。SDK 可以从 Apple 公开更新源拿到，不需要 root：

```bash
curl -s -o cat.gz https://swscan.apple.com/content/catalogs/others/index-26.merged-1.sucatalog.gz
gunzip -c cat.gz > cat.plist     # 在 Products 里找 CLTools_macOSNMOS_SDK.pkg 的 URL
curl -sL -o sdk.pkg "<上面的 URL>"
pkgutil --expand-full sdk.pkg out
mkdir -p ~/Library/Developer/SDKs
mv out/Payload/Library/Developer/CommandLineTools/SDKs/MacOSX26.*.sdk ~/Library/Developer/SDKs/
```

## 协议

unix stream socket，一行一个 JSON 对象：

```json
{"title": "Pi · rote", "body": "会话完成 · 42s", "duration": 10, "source": "pi"}
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `title` | 否 | 主标题，`content.showTitle` 为 false 时不显示 |
| `body` | 否 | 正文，`content.showBody` 为 false 时不显示 |
| `duration` | 否 | 本条停留秒数，覆盖 `behavior.duration`（默认 10） |
| `source` | 否 | 来源标签，v1 只透传 |
| `screen` | 否 | 指定落在哪块屏，覆盖 `behavior.screen` |

未知字段忽略；不是 JSON 的行当作 `body` 原样显示。socket 权限 0600，默认
`~/.pi-toast/toast.sock`。

## 配置

完整可选项见 `config.example.json`，四块：

- `appearance` — 尺寸、圆角、内外边距、强调件（`accentStyle`: `dot`/`bar`/`none`，
  `accentInset` 距左边距、`accentAlign`: `center`/`title`）、背景材质
  （`material`: `hudWindow`/`clear`/`popover`/`menu`/`sidebar`/`none`，
  前缀 `classic:` 强制走旧版 vibrancy）、主题（`theme`: `dark`/`light`/`system`）、
  边框/文字颜色、字号字重、行距、最多行数
- `behavior` — 停留时长、淡入淡出时长、最多同时几条、点击是否关闭、窗口层级、
  显示在哪块屏、水平对齐（`align`: `center`/`left`/`right`）
- `content` — 标题/正文各自是否展示
- `pi` — pi 扩展自己的配置，server 不读

颜色值可以写单个 hex（两种模式共用），也可以写 `{"light": "#..", "dark": "#.."}`。
`cornerRadius` 写数字是绝对圆角，写 `"capsule"` 则始终等于卡片高度的一半。

`screen` 取值：`"main"`（有菜单栏那块，默认）、`"mouse"`（鼠标所在屏）、
屏序号 `"0"/"1"/"2"`、或屏名字片段（如 `"Built-in"`）。

> **关于玻璃**：桌面是纯黑时 behind-window 毛玻璃没有东西可模糊，所以卡片自带一层
> 顶部向下的白色渐变（`sheen`）和一层薄膜（`background`）。这是手工近似，不是真折射。
> 链接 macOS 26 SDK 后 `material` 生效，玻璃由系统渲染，就不再需要这些补偿。

## 命令

```
toast serve                                  常驻服务
toast send --title T --body B [--duration N] 发一条
toast send --json '{...}'                    发原始 JSON
echo '{...}' | toast send                    从 stdin 读 JSON
toast send ... --screen 2                    发到指定屏
toast preview --title T --body B --out x.png 用同一套绘制代码离屏渲染成 PNG
toast preview ... --theme light --bg "#F5F5F7"  看浅色模式
toast config                                 打印命中的配置文件、socket 状态、关键参数
```

`preview` 是调样式用的：截图权限没开时也能看到卡片长什么样。它会强制关掉 `material`
（离屏渲染画不出毛玻璃，只会画成一块灰），所以看的是形状和排版，不是最终质感。

## 接入

`integrations/` 下每个工具一个目录。目前有 pi：

```bash
./integrations/pi/install.sh --test   # 装扩展 + 合并配置 + 弹一条测试通知
./integrations/pi/install.sh --remove
```

装完在 pi 里 `/reload`，之后每个会话结束都会弹一条。扩展订阅的是 `agent_settled`
（不是 `agent_end`——后者在自动重试/压缩前就会触发）。

模板变量：`{project}` `{cwd}` `{session}` `{sessionFile}` `{duration}` `{tools}`
`{model}` `{summary}`。未定义的占位符会被丢掉，不会把 `{xxx}` 原样印出来。

`{summary}` 是会话总结。pi 自己只在压缩上下文（`/compact`）或切换分支时产 summary，
不会给每个会话自动总结，所以这个由扩展现做，`pi.summaryMode` 控制：

| 值 | 行为 | 成本 |
|---|---|---|
| `"lastMessage"` | 取最后一条 assistant 回复，去掉 markdown/代码块，压成一行并截到 `summaryMaxChars` | 0 |
| `"model"` | 把会话摘要发给模型，让它一句话概括（超时 `summaryTimeoutMs` 后回退） | 一次小模型调用 |
| `"off"` | 不生成，`{summary}` 退化成 `{session} · {duration}s` | 0 |

## 已知边界

- **没有历史**。要做就得上 SQLite + 查询界面。
- **单渲染器**：只有「屏幕上某个位置的一张卡片」。多渲染器、规则路由、刘海适配都还没有。
- **hover 效果关着**（`hover.enabled` 默认 false）。3D 倾斜代码还在，想开改配置即可。
- **socket 没有鉴权**，同一用户下的任何进程都能弹通知。单用户机器可接受。
- 标识符还叫 `toast`（bundle id `dev.rote.toast`、配置目录 `~/Library/Application Support/Toast`），
  仓库名是 rote；统一命名留到下一版，避免破坏已在运行的 socket 路径。

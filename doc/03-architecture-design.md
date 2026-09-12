# 架构设计

## 1. 总体结构

```text
AppDelegate / HotKeyManager
            │
            ▼
      CaptureService ────────────── ScrollingCaptureService
            │
            ├── AreaSelectionController / ScreenCaptureKit
            │
            ├── Clipboard
            ├── ThumbnailPreviewController
            ├── HistoryManager
            └── Background Auto Save

ThumbnailPreviewController
    ├── EditorWindowController
    ├── OCRService
    ├── PinService
    └── Manual Save / Clipboard
```

架构采用菜单栏 App Shell、截图编排、具体工具服务和独立界面控制器的轻量分层。当前规模不需要引入外部依赖或复杂容器，但用户可见状态必须有唯一数据来源。

## 2. 组件职责

### 2.1 App Shell

`AppDelegate`

- 建立菜单栏入口。
- 打开设置和历史窗口并复用已有窗口。
- 根据设置切换 accessory/regular 激活策略。
- 首次启动请求屏幕录制权限。
- 监听快捷键和语言变更，重建菜单。

`HotKeyManager`

- 保存、注册和注销 Carbon 全局快捷键。
- 检查系统保留组合与应用内冲突。
- 区分“没有保存值”和“用户明确禁用”。
- 将动作分发到截图、滚动截图或取色服务。

### 2.2 截图域

`CaptureService`

- 普通截图的应用层编排器。
- 统一权限检查、ScreenCaptureKit 配置、截图模式记录和错误展示。
- 生成截图后的执行选项快照。
- 保证剪贴板、预览、历史和自动保存的执行顺序。
- 将 ScreenCaptureKit 坐标转换为预览所需的 AppKit 全局坐标。

`AreaSelectionController` / `AreaSelectionView`

- 为每个显示器创建遮罩。
- 处理鼠标、三指拖动、Esc 取消、Space 前方窗口快照、十字线和选区绘制。
- 以 `AreaSelectionResult` 输出区域、前方窗口或取消三种互斥结果。
- 清理多个遮罩、键盘监听和光标栈后才回调截图服务；重复启动时旧会话先取消。
- 区域结果包含显示器内的 ScreenCaptureKit source rectangle 和 display ID。

`ScrollingCaptureService`

- 以固定间隔采集主屏幕帧。
- 根据重叠行拼接长图。
- 管理捕获中的状态窗口、Esc 监听和停止按钮。
- 当前完成后直接进入编辑器，与普通截图完成管线保持显式隔离。

### 2.3 截图后能力

`ThumbnailPreviewController`

- 管理唯一的浮动预览窗口、生命周期和工具动作。
- 根据截图锚点、显示器可见范围和光标计算窗口位置。
- 不负责历史持久化和自动保存。

`PreviewPlacement`

- 纯坐标计算，无窗口副作用。
- 输入预览尺寸、截图锚点、屏幕 visible frame 和光标位置。
- 输出完全位于目标可见屏幕内的 AppKit 窗口 frame。
- 通过单元测试覆盖换边、越界、重叠和全屏回退。

`HistoryManager`

- 维护历史元数据和最多 200 条的保留策略。
- 后台编码、写入图片，成功后在主执行域提交元数据。

`CapturedImageSnapshot`

- 从 `NSImage` 提取不可变 `CGImage` 和逻辑尺寸。
- 在后台按 PNG、JPEG 或 TIFF 编码，避免依赖主线程绘图上下文。

`OCRService`、`PinService`、编辑器组件

- 分别负责文字识别、图片置顶和标注编辑。
- 由预览动作调用，不反向控制截图生命周期。

`EditorShortcutManager`

- 管理编辑器内单字母快捷键，与 `HotKeyManager` 的 Carbon 全局快捷键完全隔离。
- 使用动作枚举映射到 `AnnotationTool`，保存键位字典和显式禁用集合。
- 录制时只接受 A 到 Z；加载时校正无效值并避免重复键。
- 工具栏提示和编辑窗口事件处理读取同一份绑定。

`EditorView` / `CanvasNSView` / `EditorViewModel`

- `EditorView` 安装本地键盘事件监视器，并用窗口引用把事件限制在所属编辑窗口。
- 当窗口 field editor 为第一响应者时，字母事件原样交给文本输入和 IME。
- `CanvasNSView` 负责鼠标绘制、选择、移动、缩放、Shift 几何约束和即时预览。
- `EditorViewModel` 持有原图、标注对象、工具状态，并负责最终合成、模糊和像素化输出。

## 3. 普通截图数据流

```text
菜单/快捷键
  → CaptureService
  → ScreenCapturePermission.ensureAccess
  → ScreenCaptureKit captureImage
  → NSImage + CaptureMode + PreviewAnchor
  → MainActor: copy clipboard
  → MainActor: ThumbnailPreviewController.show
  → immutable CapturedImageSnapshot
  → utility task: history encode/write
  → utility task: optional auto-save encode/write
```

区域遮罩中的空格分支为：

```text
Space
  → AreaSelectionController.finish(.frontmostWindow)
  → 关闭所有遮罩并移除事件监听
  → CaptureService.performWindowCapture
  → 选择第一个可见、足够大且不属于 Ashot 的前方窗口
  → 普通窗口截图完成管线
```

关键约束：

- 捕获 API 可以异步等待，但 UI 和 AppKit 对象操作回到主执行域。
- 剪贴板和预览不等待文件编码。
- 背景任务只持有不可变图片快照、URL、格式等值，不读取变化中的 SwiftUI 状态。
- 后台失败不能把已经展示给用户的截图伪装成整体失败；错误标题需要说明失败范围。
- 所有 event-derived 矩形先经过 `CaptureGeometry`，无效、越界或超过 32768 像素边长的输出不进入 ScreenCaptureKit。

## 4. 预览空间上下文与坐标系

Ashot 同时使用三种相关坐标：

1. 区域遮罩 View：显示器局部、AppKit 左下角原点。
2. ScreenCaptureKit `sourceRect`：显示器局部、左上角方向。
3. 预览窗口 frame：桌面全局、AppKit 左下角原点。

区域截图在遮罩完成时先将 View 选区翻转为 ScreenCaptureKit source rectangle。截图成功后，`CaptureService.appKitCaptureFrame` 再根据目标 `NSScreen.frame` 转回全局 AppKit 矩形：

```text
globalX = screen.minX + source.minX
globalY = screen.maxY - source.maxY
```

该转换必须保留负数屏幕原点，不能假设主显示器位于所有显示器左下角。

不同截图模式提供不同锚点：

| 模式 | 预览锚点 |
| --- | --- |
| 区域 | 转换后的全局选区 |
| 窗口 | ScreenCaptureKit 返回的窗口 frame |
| 全屏/延时 | 被截取屏幕的 frame |
| 无锚点调用 | 光标所在屏幕与光标位置 |

目标显示器优先按锚点相交面积确定，避免选区在副屏时预览跑回主屏。

## 5. 状态与持久化

### 5.1 UserDefaults

适合保存小型用户偏好：截图后策略、保存格式、显示选项、语言和快捷键。截图开始后应读取一次并形成当次执行快照，避免异步流程中用户修改设置造成同一张截图行为不一致。

快捷键采用两套命名空间：

- `shortcutBindings` / `disabledShortcutActions`：全局截图动作。
- `editorShortcutBindings` / `disabledEditorShortcutActions`：编辑器本地工具动作。

两者不能合并注册。编辑器字母键如果进入 Carbon 全局注册，会抢占其他应用的正常输入。

### 5.2 历史目录

- 图片文件和 `history_metadata.json` 共同构成历史数据。
- 只有图片原子写入成功后才提交元数据。
- 删除历史时同时删除文件和元数据项。
- 当前元数据写入是本地单进程模型，不支持多个 Ashot 实例同时写入；开发和验收时应避免并行启动多个实例。

## 6. 依赖方向

```text
Views / Window Controllers
          ↓
Application Services
          ↓
ScreenCaptureKit / AppKit / Vision / File System
```

维护约束：

- 设置页面只修改偏好，不直接执行截图编码或文件写入。
- 预览定位算法保持纯函数，不读取全局 `NSScreen` 或 `NSEvent`。
- `ThumbnailPreviewController` 负责把运行时屏幕和光标信息注入定位算法。
- `CaptureService` 不直接构造预览子控件，只传递图像和空间上下文。
- 页面不得自行推导截图成功状态；普通截图完成顺序由 `CaptureService` 统一控制。

## 7. 后续演进

当截图类型和输出目标继续增加时，可将 `NSImage + CaptureMode + previewAnchor` 收口为 `CaptureResult` 值对象，并把剪贴板、历史和保存抽象为完成策略。但在现有规模下，不应为了形式分层而增加协议数量。

优先演进项：

1. 将滚动截图接入统一 `CaptureResult`，同时制定长图内存限制。
2. 为窗口截图增加悬停高亮和显式目标切换；当前空格路径只捕获最前方窗口。
3. 为后台历史和自动保存增加可观察的失败诊断记录。
4. 为多显示器和不同 Dock 位置增加自动化 UI 场景。
5. 将标注移动、缩放和样式变化收口为统一命令历史，使撤销/重做覆盖对象的全部变更。

# CodexBar

一个简约的 macOS **状态栏应用**，用于显示 Codex 当前的剩余用量。

当前显示：

- 5 小时窗口剩余用量
- 1 周窗口剩余用量
- 两个窗口的重置时间

## 下载

已发布版本：

- [v0.1.2](https://github.com/l445698714/codexbar/releases/tag/v0.1.2)

发布附件：

- `CodexBar-v0.1.2-macos.zip`

## 本地运行

源码入口：

- `src/main.m`
- `Support/Info.plist`

本地编译：

```bash
mkdir -p build
clang -fobjc-arc -fmodules -framework Cocoa -framework ServiceManagement -lsqlite3 -mmacosx-version-min=13.0 -o build/CodexBar src/main.m
```

生成 `.app`：

```bash
mkdir -p dist/CodexBar.app/Contents/MacOS dist/CodexBar.app/Contents/Resources
cp build/CodexBar dist/CodexBar.app/Contents/MacOS/CodexBar
cp Support/Info.plist dist/CodexBar.app/Contents/Info.plist
codesign --force --deep --sign - dist/CodexBar.app
```

命令行查看当前快照：

```bash
./build/CodexBar --snapshot
```

## 说明

当前实现读取本机 `~/.codex/sessions` 下的会话快照，并结合 `~/.codex/logs_2.sqlite` 中的本地事件日志，展示最近一次可用的用量信息。

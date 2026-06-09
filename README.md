# Global Vocal Remover

Global Vocal Remover 是一个 macOS 菜单栏小工具，可以把系统里正在播放的声音实时处理后再输出，去除人声。

| Menu bar menu | Control page | 
| -------- | -------- | 
| <img alt="image" src="https://github.com/user-attachments/assets/9c407ee3-dae5-4567-bda2-b7db8a2af66e" />  | <img alt="image" src="https://github.com/user-attachments/assets/69e63407-b22a-443c-9641-be52bd38728d" /> | 

## 下载和使用

1. 在 GitHub Releases 页面下载最新的 `GlobalVocalRemover.app.zip`。
2. 解压后打开 `GlobalVocalRemover.app`。
3. 按系统提示授予音频捕获权限。
4. 播放音乐、视频或其他系统声音，应用会在后台处理全局音频。

## 系统要求

- macOS 14.2 或更新版本。
- 首次打开如果被 Gatekeeper 拦截，请在“系统设置”里允许打开，或右键应用选择“打开”。

## 注意事项

- 神经网络处理音频需要时间，打开后系统音频会有一定延迟
- 第一批处理结果还没出来时，会放原声。

开发和调试说明见 [HACKING.md](HACKING.md)。

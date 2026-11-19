# 独立纯净代理

macOS 上的独立代理浏览器启动器。用你选择的 Clash 节点启动独立的 Mihomo 进程，通过外网出口和 DNS 地区检查后，打开使用独立资料目录的浏览器窗口。

## 使用

需要 macOS 13 或更新版本、本机的 Mihomo 内核（可使用 Clash Verge Rev 自带的内核）、Chrome 或其他 Chromium 浏览器，以及自己的 Clash 配置。

1. 选择自动发现的 Clash 配置，或导入包含 `proxies` 节点的 YAML 或 JSON 文件。
2. 选择节点，点击「连接并打开」。
3. 用完后点击「断开」，或关闭所有专用浏览器窗口。

每组配置、节点和浏览器使用各自的资料目录。连接检查会向外部检测服务查询出口 IP 和 DNS 地区。

## 构建

安装 Xcode 和 Python 3，在仓库目录运行：

```sh
swift test
./build.sh
```

生成的应用位于 `dist/独立纯净代理.app`，包含 Apple Silicon 和 Intel 两种架构。

## 许可证

本项目采用 [MIT 许可证](LICENSE)。Yams 的许可证见 [Yams-LICENSE.txt](Yams-LICENSE.txt)。

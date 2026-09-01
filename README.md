# Mix Web 部署工具

一个仅面向 macOS 的 SwiftUI 小工具，通过现有 Jumpserver 流程在远程服务器上安全地切换 Git 分支并拉取代码。

## 安全原则

- PEM 私钥始终保留在应用外部，应用只保存文件路径。
- 分支名、SSH 地址和项目路径均经过白名单校验。
- 服务器工作区存在未提交修改时，停止切换分支。
- 使用 `git pull --ff-only`，不自动制造合并提交。
- 使用 `sudo -n`，应用不会请求或保存远程 sudo 密码。

## 构建

当前 Mac 已安装 Swift Command Line Tools，无需完整 Xcode 即可构建：

```bash
chmod +x scripts/build-app.sh
./scripts/build-app.sh
```

生成结果：

```text
dist/Mix Web 部署工具.app
```

## 首次配置

- Jumpserver：填写团队提供的 SSH 主机和端口。
- SSH 用户：填写个人的 Jumpserver 用户名。
- 项目目录：填写服务器上的 Git 仓库绝对路径，例如 `/path/to/project`。
- Jumpserver 菜单：按照实际交互流程填写两次菜单选项。
- PEM：通过文件选择器指定当前 Mac 上的私钥文件。

仓库不包含真实连接信息或私钥。所有配置都在应用界面填写，并保存在当前 Mac 用户的 `UserDefaults` 中。

## 使用顺序

1. 点击“检查连接”。
2. 点击“刷新分支”，或直接输入已知分支。
3. 点击“切换并拉取”，确认后执行。

远程操作顺序为：

```text
git fetch --prune origin
git status --porcelain
git checkout <branch>
git pull --ff-only origin <branch>
```

首次使用建议只执行“检查连接”。如果 Jumpserver 菜单输出与原脚本不同，可根据日志调整 Expect 的等待规则，不要直接尝试部署。

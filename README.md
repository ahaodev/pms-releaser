# PMS Releaser Tool

PMS Releaser 是一款面向 CI/CD 流水线的自动化发布工具，能够从 Git 提交记录自动生成变更日志，并将构建产物上传到指定发布系统。支持脚本、GitHub Actions、Drone CI 和 Docker 四种使用方式。

---

## 功能特性

### 自动变更日志生成

按提交标题前缀（区分大小写）生成分类变更日志：

| 前缀 | 分类 |
|---|---|
| `feat*` / `feature*` | ✨ 新功能 |
| `fix*` / `bugfix*` | 🐛 错误修复 |
| `docs*` / `doc*` | 📚 文档更新 |
| `style*` / `format*` | 💄 样式调整 |
| `refactor*` | ♻️ 代码重构 |
| `perf*` / `performance*` | ⚡ 性能优化 |
| `test*` | 🧪 测试相关 |
| `build*` / `ci*` / `cd*` | 🔧 构建与 CI/CD |
| `chore*` | 🔨 维护 |
| 其他 | 📝 其他变更 |

> GitHub Actions 请设置 `fetch-depth: 0`，确保获取完整提交历史。

### 发布上传

- 多部分表单（multipart）上传，携带完整元数据
- 最多重试 3 次，间隔 5 秒
- 服务端响应校验：自动检测 HTML 误返（防止 SPA 路由干扰）
- 支持 GitHub Actions 与 Drone CI 环境变量

---

## 快速上手

以下是最常见的 GitHub Actions 使用方式，推送 tag 时自动触发发布：

```yaml
name: Release

on:
  push:
    tags:
      - 'v*'

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - uses: ahaodev/pms-releaser@main  # 生产环境建议固定到具体 tag，如 @v1.0.0
        with:
          file_path: './app.apk'
          version: ${{ github.ref_name }}
          project_name: ${{ vars.PROJECT_NAME }}
          package_name: ${{ vars.PACKAGE_NAME }}
          access_token: ${{ secrets.ACCESS_TOKEN }}
          release_url: ${{ secrets.RELEASE_URL }}
```

> 在仓库的 **Settings → Secrets and variables → Actions** 中配置：
> - **Secrets**：`ACCESS_TOKEN`、`RELEASE_URL`
> - **Variables**：`PROJECT_NAME`、`PACKAGE_NAME`

---

## 命令参数

```bash
pms-releaser <file_path> <version> <project_name> <package_name> [artifact_name] [os] [arch]
```

### 运行依赖

| 依赖 | 必需 | 说明 |
|---|---|---|
| `bash` | ✅ | 脚本解释器 |
| `curl` | ✅ | 上传制品 |
| `git` | — | 生成 changelog；不在 Git 仓库时回退为最小化 changelog |
| `jq` 或 `python3` | ✅ | 校验服务端返回是否为合法 JSON（二者其一即可） |

> Docker 镜像已内置以上依赖，无需额外安装。

### 必需参数

| 参数 | 说明 |
|---|---|
| `file_path` | 待发布文件路径 |
| `version` | 版本号，如 `v1.0.0` |
| `project_name` | 发布系统中的项目名称 |
| `package_name` | 项目下的包名称 |

### 可选参数

| 参数 | 默认值 | 说明 |
|---|---|---|
| `artifact_name` | 文件名 | 在发布系统中显示的制品名称 |
| `os` | `android` | 目标操作系统/平台 |
| `arch` | `universal` | 目标架构 |

### 环境变量

| 变量 | 必需 | 说明 |
|---|---|---|
| `ACCESS_TOKEN` | ✅ | 发布系统访问令牌 |
| `RELEASE_URL` | ✅ | 发布系统 API 地址 |
| `DRONE_TAG` | — | Drone CI 当前 tag |
| `DRONE_COMMIT` | — | Drone CI 当前 commit hash |
| `DRONE_BRANCH` | — | Drone CI 当前分支 |
| `GITHUB_REF` | — | GitHub Actions ref |
| `GITHUB_REF_NAME` | — | GitHub Actions tag 或分支名 |
| `GITHUB_SHA` | — | GitHub Actions commit SHA |

> `ACCESS_TOKEN`、`RELEASE_URL` 必填。GitHub Actions 中，`GITHUB_REF` 为 tag 时，`GITHUB_REF_NAME` → `DRONE_TAG`；`GITHUB_SHA` → `DRONE_COMMIT`；`GITHUB_REF_NAME` → `DRONE_BRANCH`。已设置的 `DRONE_*` 值优先。

---

## 使用方式

### 1. 直接运行脚本

```bash
chmod +x scripts/pms-releaser.sh

export ACCESS_TOKEN="your-token"
export RELEASE_URL="https://your-release-system.com/access/release"

./scripts/pms-releaser.sh ./app.apk v1.0.0 my-project my-package
```

使用 `.env` 文件管理本地配置（推荐）：

```bash
# .env（请确保已加入 .gitignore，避免 token 泄漏）
export RELEASE_URL=https://your-release-system.com/access/release
export ACCESS_TOKEN=your-token
export PROJECT_NAME=my-project
export PACKAGE_NAME=my-package
```

```bash
source .env && ./scripts/pms-releaser.sh ./app.apk v1.0.0 $PROJECT_NAME $PACKAGE_NAME
```

### 2. GitHub Actions

**方式一：使用内置 Action（推荐）**

```yaml
- uses: ahaodev/pms-releaser@main  # 生产环境建议固定到具体 tag，如 @v1.0.0
  with:
    file_path: './app.apk'
    version: ${{ github.ref_name }}
    project_name: ${{ vars.PROJECT_NAME }}
    package_name: ${{ vars.PACKAGE_NAME }}
    artifact_name: 'MyApp'
    os: 'android'
    arch: 'universal'
    access_token: ${{ secrets.ACCESS_TOKEN }}
    release_url: ${{ secrets.RELEASE_URL }}
```

**方式二：使用 Docker 容器**

```yaml
jobs:
  release:
    runs-on: ubuntu-latest
    container:
      image: ghcr.io/ahaodev/pms-releaser:latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Publish release
        env:
          ACCESS_TOKEN: ${{ secrets.ACCESS_TOKEN }}
          RELEASE_URL: ${{ secrets.RELEASE_URL }}
        run: |
          pms-releaser ./app.apk ${{ github.ref_name }} \
            ${{ vars.PROJECT_NAME }} ${{ vars.PACKAGE_NAME }} \
            MyApp android universal
```

### 3. Drone CI

```yaml
kind: pipeline
type: docker
name: release

trigger:
  event:
    - tag

steps:
  - name: release
    image: ghcr.io/ahaodev/pms-releaser:latest
    environment:
      ACCESS_TOKEN:
        from_secret: ACCESS_TOKEN
      RELEASE_URL:
        from_secret: RELEASE_URL
    commands:
      - pms-releaser /drone/src/app.apk ${DRONE_TAG} my-project my-package
```

### 4. Docker

> 镜像由本仓库的 tag 流水线发布到 GitHub Container Registry：`ghcr.io/ahaodev/pms-releaser:latest`。

```bash
# 基本发布
docker run --rm -v "$PWD:/workspace" -w /workspace \
  -e ACCESS_TOKEN=your-token \
  -e RELEASE_URL=https://your-release-system.com/access/release \
  ghcr.io/ahaodev/pms-releaser:latest \
  /workspace/app.apk v1.0.0 my-project my-package

# 指定 artifact 名称、平台和架构
docker run --rm -v "$PWD:/workspace" -w /workspace \
  -e ACCESS_TOKEN=your-token \
  -e RELEASE_URL=https://your-release-system.com/access/release \
  ghcr.io/ahaodev/pms-releaser:latest \
  ./build/MyApp.apk v2.1.0 my-project my-package "MyApplication" "android" "arm64"
```

---

## 常见问题

| 现象 | 原因与处理 |
|---|---|
| `Error: ACCESS_TOKEN is required` | 未设置 `ACCESS_TOKEN` 或其值为空 |
| `Error: RELEASE_URL is required` | 未设置 `RELEASE_URL`，脚本不再回退到占位地址 |
| `Error: jq or python3 is required ...` | 安装 `jq` 或 `python3` 后重试 |
| `server returned HTML instead of JSON` | `RELEASE_URL` 指向了前端页面而非 API，应指向 `.../access/release` |
| `server returned an invalid JSON response` | 服务端未返回合法 JSON，检查接口路径与网关配置 |
| `Network/Connection error` | 网络不可达；上传前会做一次连通性探测，失败仅告警 |
| changelog 内容不符合预期或落入「其他变更」 | 提交信息未遵循约定式提交；分类使用**前缀匹配且大小写敏感**，并确认 checkout 使用 `fetch-depth: 0` |


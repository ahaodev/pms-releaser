# PMS Releaser

从 Git 提交记录生成分类变更日志，并将制品上传到 PMS 发布接口。支持 GitHub Actions、Docker 和直接运行脚本。

## GitHub Actions

推送 `v*` 标签时发布。先配置仓库 Secrets：`ACCESS_TOKEN`、`RELEASE_URL`，以及 Variables：`PROJECT_NAME`、`PACKAGE_NAME`。发布前需构建或下载 `app.apk`。

```yaml
name: Release
on:
  push:
    tags: ['v*']

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      # 在此构建或下载 app.apk
      - uses: ahaodev/pms-releaser@main
        with:
          file_path: './app.apk'
          version: ${{ github.ref_name }}
          project_name: ${{ vars.PROJECT_NAME }}
          package_name: ${{ vars.PACKAGE_NAME }}
          access_token: ${{ secrets.ACCESS_TOKEN }}
          release_url: ${{ secrets.RELEASE_URL }}
```

生产环境建议将 `@main` 固定为已发布的 tag 或提交 SHA。可选输入见下表。

## 参数与配置

```text
pms-releaser <file_path> <version> <project_name> <package_name> [artifact_name] [os] [arch]
```

| 参数 / Action 输入 | 说明 | 默认值 |
|---|---|---|
| `file_path` | 制品文件路径 | 必填 |
| `version` | 发布版本，如 `v1.0.0` | 必填 |
| `project_name` | 项目名称 | 必填 |
| `package_name` | 包名称 | 必填 |
| `artifact_name` | 制品显示名称 | 文件名 |
| `os` | 目标平台 | `android` |
| `arch` | 目标架构 | `universal` |
| `access_token` | 访问令牌；脚本使用环境变量 `ACCESS_TOKEN` | 必填 |
| `release_url` | 发布 API 地址；脚本使用环境变量 `RELEASE_URL` | 必填 |

## 脚本与 Docker

直接运行需 Bash 3.2+、curl（支持 `--fail-with-body`）以及 jq 或 Python 3；Git 用于生成变更日志。Docker 镜像已内置依赖。

```bash
export ACCESS_TOKEN='your-token'
export RELEASE_URL='https://your-release-system.com/access/release'

# 直接运行
bash scripts/pms-releaser.sh ./app.apk v1.0.0 my-project my-package

# Docker（沿用上面的环境变量）
docker run --rm -v "$PWD:/workspace" -w /workspace \
  -e ACCESS_TOKEN -e RELEASE_URL \
  ghcr.io/ahaodev/pms-releaser:latest \
  ./app.apk v1.0.0 my-project my-package
```

如需指定可选参数，在命令末尾追加，例如 `MyApp android arm64`。镜像默认使用 root，以访问 CI 制品；也可用 `--user` 指定有相应文件权限的用户。

## 发布行为与排错

- **日志范围**：目标提交依次取版本标签、`GITHUB_SHA`、`HEAD`。基线取完整祖先图中的最近标签（含合并分支），排除目标提交自身的标签，不按版本号排序。
- **提交分类**：按标题前缀匹配，区分大小写。支持 `feat/feature`、`fix/bugfix`、`docs/doc`、`style/format`、`refactor`、`perf/performance`、`test`、`build/ci/cd`、`chore`；其余归入其他变更。
- **Git 历史**：建议 `fetch-depth: 0`。浅克隆会尝试从 `origin` 补齐历史及标签，失败则停止发布。缺少 Git 或不在仓库中时使用最小化日志，其他 Git 错误会停止发布。
- **仓库权限**：镜像信任 `/workspace` 和 `/github/workspace`。其他挂载路径出现所有权错误时，请使用匹配仓库所有者的用户，或为可信仓库配置 `safe.directory`。
- **上传结果**：仅接受 HTTP 2xx 且包含单个 JSON 值的响应。HTML、空响应或无效 JSON 请先检查 `RELEASE_URL` 是否指向 API。上传不自动重试，避免重复创建发布。

GitHub 的标签、提交和引用名称会写入发布元数据；服务端兼容字段 `drone_tag`、`drone_commit`、`drone_branch` 保留，但不再读取 `DRONE_*` 环境变量。

## 开发验证

```bash
python3 -m unittest discover -s tests -v
```

测试使用临时 Git 仓库和本地 HTTP 服务；安装 jq 可同时验证 jq 和 Python 两条 JSON 校验路径。GitHub CI 在 Linux/macOS 上测试，Linux 还会构建和检查镜像。Tag 的源码与镜像发布均需测试通过，源码发布使用当前 checkout 的本地 Action。

# PMS Releaser

两个独立功能：收集 Git 提交并生成 Markdown 变更日志；将制品和已有日志上传到 PMS。保留 `pms-releaser.sh` 作为组合入口。

## 独立使用

```bash
# 1. 收集 Git 记录；省略文件路径则输出到 stdout，无需 PMS 凭据
bash scripts/collect-changelog.sh v1.0.0 changelog.md

# 2. 上传制品和已有日志，不访问 Git
export ACCESS_TOKEN='your-token'
export RELEASE_URL='https://your-release-system.com/access/release'
bash scripts/pms-publish.sh ./app.apk v1.0.0 my-project my-package changelog.md

# 兼容旧入口：自动收集，再发布
bash scripts/pms-releaser.sh ./app.apk v1.0.0 my-project my-package
```

上传脚本在日志路径后接受可选参数 `[artifact_name] [os] [arch]`，默认分别为文件名、`android`、`universal`。组合入口的可选参数仍在项目和包名之后，第八个参数可传入已有日志以跳过收集。

收集只需 Bash 3.2+ 和 Git；无 Git 或不在仓库中时会生成最小化日志。上传需要 Bash 3.2+、curl（支持 `--fail-with-body`）以及 jq 或 Python 3。

## GitHub Actions

独立收集 Action 输出 `changelog_file`，可供 PMS Action 或 `gh release --notes-file` 使用。使用前需完整 checkout；PMS 发布还需先构建或下载制品。

```yaml
steps:
  - uses: actions/checkout@v4
    with:
      fetch-depth: 0
  - uses: ahaodev/pms-releaser/actions/changelog@main
    id: notes
    with:
      version: ${{ github.ref_name }}
  # 如需上传到 PMS，继续执行下面这一步
  - uses: ahaodev/pms-releaser@main
    with:
      file_path: './app.apk'
      version: ${{ github.ref_name }}
      changelog_file: ${{ steps.notes.outputs.changelog_file }}
      project_name: ${{ vars.PROJECT_NAME }}
      package_name: ${{ vars.PACKAGE_NAME }}
      access_token: ${{ secrets.ACCESS_TOKEN }}
      release_url: ${{ secrets.RELEASE_URL }}
```

生产环境建议将 `@main` 固定为已发布的 tag 或提交 SHA。

| PMS Action 输入 | 说明 | 默认值 |
|---|---|---|
| `file_path` | 制品文件路径 | 必填 |
| `version` | 发布版本，如 `v1.0.0` | 必填 |
| `project_name` / `package_name` | PMS 项目和包名称 | 必填 |
| `changelog_file` | 工作区内的 Markdown 文件路径 | 自动收集 Git 记录 |
| `artifact_name` | 制品显示名称 | 文件名 |
| `os` / `arch` | 目标平台和架构 | `android` / `universal` |
| `access_token` / `release_url` | PMS 令牌和 API 地址 | 必填 |

仓库内的发布工作流均由 `v*` 标签触发，并等待测试通过：

- `github-release.yml`：收集日志，创建或更新 GitHub Release，并附上源码包。使用内置 `GITHUB_TOKEN`，无需 PMS 配置；带 `-` 的版本标为预发布。
- `docker-publish.yml`：发布 GHCR 镜像。
- `release.yml`：可选的 PMS 源码包发布。未设置 Variables `PROJECT_NAME`、`PACKAGE_NAME` 时跳过；启用时还需配置 Secrets `ACCESS_TOKEN`、`RELEASE_URL`。

## Docker

镜像内置所有运行依赖和三个命令：`collect-changelog`、`pms-publish`、`pms-releaser`（默认入口）。

```bash
# 独立收集到挂载的工作区
docker run --rm -v "$PWD:/workspace" -w /workspace \
  --entrypoint collect-changelog ghcr.io/ahaodev/pms-releaser:latest \
  v1.0.0 changelog.md

# 收集并上传；沿用前面的环境变量
docker run --rm -v "$PWD:/workspace" -w /workspace \
  -e ACCESS_TOKEN -e RELEASE_URL ghcr.io/ahaodev/pms-releaser:latest \
  ./app.apk v1.0.0 my-project my-package
```

镜像默认使用 root，以访问 CI 制品；可用 `--user` 指定有相应文件权限的用户。Git 信任路径为 `/workspace` 和 `/github/workspace`。

## 行为说明

- **日志范围**：目标依次取版本标签、`GITHUB_SHA`、`HEAD`；基线取完整祖先图中的最近标签，排除目标自身标签，不按版本号排序。
- **分类**：按标题前缀匹配，区分大小写。支持 `feat/feature`、`fix/bugfix`、`docs/doc`、`style/format`、`refactor`、`perf/performance`、`test`、`build/ci/cd`、`chore`；其余归入其他变更。
- **历史不完整**：浅克隆尝试从 `origin` 补齐历史和标签，失败则停止；权限、所有权和其他 Git 错误也会停止收集。建议 `fetch-depth: 0`。
- **上传校验**：仅接受 HTTP 2xx、非 HTML 且包含单个 JSON 值的响应；不自动重试，避免重复发布。

上传保留服务端兼容字段 `drone_tag`、`drone_commit`、`drone_branch`，由 GitHub 环境变量填充；不读取 `DRONE_*` 变量。

## 测试

```bash
python3 -m unittest discover -s tests -v
```

`test_changelog.py` 验证 Git 收集，`test_pms_publish.py` 用真实 curl 和本地 HTTP 服务验证上传，`test_integration.py` 验证组合入口。安装 jq 可同时测试 jq/Python 两条校验路径。CI 在 Linux/macOS 测试，Linux 还会构建和检查镜像。

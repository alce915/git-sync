# Codex Git Sync Tool

这个工具可以放在任意目录使用，不要求固定放在 `D:\codex`。

## 用途
给任意本地项目提供统一的 GitHub HTTPS 公开/私有同步工具。

## 目录约定
- 工具根目录：`sync-project.ps1` 所在目录
- 目标项目目录：运行时通过 `-ProjectPath` 指定；不传时默认使用当前目录
- 运行时配置和登记文件都保存在工具根目录，而不是写死某个磁盘路径

## 文件
- `sync-project.ps1`：主脚本
- `sync-project.bat`：双击/命令行入口
- `git-sync.env`：可提交的默认配置，只放非敏感值和参考格式
- `git-sync.local.env`：本机私有覆盖配置，专门保存明文 Token 等敏感值
- `projects.json`：本机运行时登记文件，不提交到公开仓库
- `repo-name-overrides.json`：本机仓库名覆盖表，可把中文项目目录映射成你想要的英文仓库名
- `scripts/suggest_repo_name.py`：基于项目内容调用 AI 生成英文仓库名的辅助脚本

## 配置文件
脚本会按下面顺序解析配置：
1. 命令行显式参数
2. `<工具根目录>\git-sync.local.env`
3. `<工具根目录>\git-sync.env`
4. 当前 PowerShell / 用户环境变量

推荐把公开默认值和本地密钥拆开保存。

`git-sync.env` 示例：
```env
GITHUB_USER=alce915
```

`git-sync.local.env` 示例：
```env
GITHUB_TOKEN=YOUR_PAT
OPENAI_API_KEY=YOUR_OPENAI_API_KEY
# OPENAI_MODEL=gpt-4.1-mini
# OPENAI_BASE_URL=https://api.openai.com/v1
# REPO_NAME_LOCAL_AI_CMD=ollama run qwen2.5:7b
```

### Token 配置方式
优先推荐放在 `git-sync.local.env`：
```env
GITHUB_TOKEN=你的PAT
```

只在当前 PowerShell 会话中使用：
```powershell
$env:GITHUB_TOKEN='你的PAT'
powershell -ExecutionPolicy Bypass -File .\sync-project.ps1 -ProjectPath "D:\your-project"
```

保存到当前用户环境变量（设置后重开 PowerShell 生效）：
```powershell
[System.Environment]::SetEnvironmentVariable('GITHUB_TOKEN', '你的PAT', 'User')
```

不写环境变量，直接在命令行临时传入：
```powershell
powershell -ExecutionPolicy Bypass -File .\sync-project.ps1 -ProjectPath "D:\your-project" -GitHubToken "你的PAT"
```

## 公开同步前会做什么
- 修正项目 `.gitignore`
- 检查敏感文件和敏感关键字
- 阻止把真实 API、Token、密码推到公开仓库
- 支持 `-PublicInit` 在校验通过后重建干净 Git 历史；失败时会恢复原 `.git`
- 同步成功后写入：
  - `<工具根目录>\projects.json`
  - `<项目根目录>\git-remote.json`

说明：`projects.json`、`git-remote.json`、`git-sync.local.env` 都是本地运行状态或敏感配置，默认加入 `.gitignore`，不会进入公开仓库。

## 中文项目名转仓库名
如果你没有显式传 `-RepoName`，脚本会按下面顺序决定 GitHub 仓库名：
1. 已有 `origin` / `git-remote.json` / `projects.json` 中登记的仓库名
2. `<工具根目录>\repo-name-overrides.json` 中的手工映射
3. 如果配置了 `OPENAI_API_KEY`，根据项目目录名、README 和项目清单自动生成英文仓库名
4. 如果没有 `OPENAI_API_KEY`，但配置了本地 AI 命令，会把项目摘要发送给本地命令起英文名
5. 对中文项目目录名自动生成拼音 slug，例如 `币安自动开单系统` -> `bi-an-zi-dong-kai-dan-xi-tong`
6. 如果仍然无法生成，则退回安全的 ASCII 名称或时间戳名称

如果你希望某个项目使用更自然的英文仓库名，可以创建本地文件 `<工具根目录>\repo-name-overrides.json`：
```json
{
  "币安自动开单系统": "binance-paired-opener",
  "亢龙监控": "monitoring-dashboard"
}
```

说明：
- `repo-name-overrides.json` 默认不会提交到公开仓库
- AI 命名依赖本机可用的 `py -3`、`OPENAI_API_KEY`，以及可访问的 OpenAI 兼容接口
- AI 命名会优先读取项目目录名、`README.md` 和 `package.json` / `pyproject.toml` / `*.csproj` 等项目清单来起名
- 如果没有 OpenAI key，可以在 `git-sync.local.env` 中配置 `REPO_NAME_LOCAL_AI_CMD`，脚本会把命名提示词通过标准输入发送给该命令，并读取标准输出作为仓库名
- `REPO_NAME_LOCAL_AI_CMD` 支持普通命令，或带 `{project_path}` / `{project_name}` 占位符的命令模板
- 自动拼音转换依赖本机可用的 `py -3` 和 `pypinyin`

## 默认会忽略的敏感文件
- `.env`
- `config/active_account.json`
- `config/binance_accounts.json`
- `git-sync.local.env`
- `projects.json`
- `git-remote.json`
- `repo-name-overrides.json`
- 数据库、日志、虚拟环境等

说明：`config/binance_api.env` 不会被忽略，因为公开仓库需要保留模板文件；但脚本会扫描文本文件中的真实密钥、Token、密码赋值并阻止继续同步。

## 常用用法
### 1. 首次公开初始化并推送
```powershell
powershell -ExecutionPolicy Bypass -File .\sync-project.ps1 -ProjectPath "D:\your-project" -RepoName "your-repo" -Visibility public -CreateRemote -PublicInit
```

### 2. 后续增量同步
```powershell
powershell -ExecutionPolicy Bypass -File .\sync-project.ps1 -ProjectPath "D:\your-project"
```

说明：如果不传 `-RepoName`，脚本会优先沿用项目已有的 `origin`、`git-remote.json` 或 `projects.json` 中登记的仓库名，不会再默认把远端改成目录名。

### 2.1 工具自身首次公开同步
```powershell
powershell -ExecutionPolicy Bypass -File .\sync-project.ps1 -ProjectPath "<工具根目录>" -RepoName "git-sync" -Visibility public -CreateRemote
```

### 3. 先预演不真正执行
```powershell
powershell -ExecutionPolicy Bypass -File .\sync-project.ps1 -ProjectPath "D:\your-project" -DryRun -SkipPush
```

## 参数说明
- `-ProjectPath`：项目路径，默认当前目录
- `-GitHubUser`：GitHub 用户名；不传时按“本地覆盖 -> 公共配置 -> 环境变量”解析
- `-RepoName`：远程仓库名；不传时默认等于项目目录名，若目录名包含中文则会优先尝试转成 ASCII 仓库名
- `-Visibility public|private`：创建远程仓库时使用
- `-CreateRemote`：如果 GitHub 上仓库不存在，则自动创建
- `-GitHubToken`：可直接传 PAT；不传时按“本地覆盖 -> 公共配置 -> 环境变量”解析
- `-SkipCommit`：跳过提交
- `-SkipPush`：跳过推送
- `-DryRun`：只打印动作，不真正执行
- `-PublicInit`：在校验通过后临时替换现有 `.git`，基于当前脱敏工作树重建干净历史；失败时自动恢复

## Git 地址登记
### 中心登记文件
`<工具根目录>\projects.json`

字段：
- `project_name`
- `project_path`
- `git_remote_url`
- `visibility`
- `last_synced_at`

### 项目本地登记文件
`<项目根目录>\git-remote.json`

字段：
- `project_name`
- `project_path`
- `git_remote_url`
- `visibility`
- `default_branch`

## 说明
- 第一次用 HTTPS 推送时，如果本机没有缓存 GitHub 凭据，脚本会优先使用 `git-sync.local.env`、命令行参数或用户环境变量中的 PAT。
- 公开仓库中应只保留干净的 `git-sync.env`，不要把真实 Token 写回可提交文件。
- 已经写入过磁盘或公开历史的 API Key / PAT，请先轮换后再同步。

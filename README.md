# Codex Git Sync Tool

位置：`D:\codex\git-sync`

## 用途
给 `D:\codex` 下任意项目提供统一的 GitHub HTTPS 公开/私有同步工具。

## 文件
- `sync-project.ps1`：主脚本
- `sync-project.bat`：双击/命令行入口
- `git-sync.env`：可提交的默认配置，只放非敏感值和参考格式
- `git-sync.local.env`：本机私有覆盖配置，专门保存明文 Token 等敏感值
- `projects.json`：本机运行时登记文件，不提交到公开仓库

## 配置文件
脚本会按下面顺序解析配置：
1. 命令行显式参数
2. `D:\codex\git-sync\git-sync.local.env`
3. `D:\codex\git-sync\git-sync.env`
4. 当前 PowerShell / 用户环境变量

推荐把公开默认值和本地密钥拆开保存。

`git-sync.env` 示例：
```env
GITHUB_USER=alce915
```

`git-sync.local.env` 示例：
```env
GITHUB_TOKEN=YOUR_PAT
```

### Token 配置方式
优先推荐放在 `git-sync.local.env`：
```env
GITHUB_TOKEN=你的PAT
```

只在当前 PowerShell 会话中使用：
```powershell
$env:GITHUB_TOKEN='你的PAT'
powershell -ExecutionPolicy Bypass -File D:\codex\git-sync\sync-project.ps1 -ProjectPath "D:\codex\币安自动开单系统"
```

保存到当前用户环境变量（设置后重开 PowerShell 生效）：
```powershell
[System.Environment]::SetEnvironmentVariable('GITHUB_TOKEN', '你的PAT', 'User')
```

不写环境变量，直接在命令行临时传入：
```powershell
powershell -ExecutionPolicy Bypass -File D:\codex\git-sync\sync-project.ps1 -ProjectPath "D:\codex\币安自动开单系统" -GitHubToken "你的PAT"
```

## 公开同步前会做什么
- 修正项目 `.gitignore`
- 检查敏感文件和敏感关键字
- 阻止把真实 API、Token、密码推到公开仓库
- 支持 `-PublicInit` 在校验通过后重建干净 Git 历史；失败时会恢复原 `.git`
- 同步成功后写入：
  - `D:\codex\git-sync\projects.json`
  - `<项目根目录>\git-remote.json`

说明：`projects.json`、`git-remote.json`、`git-sync.local.env` 都是本地运行状态或敏感配置，默认加入 `.gitignore`，不会进入公开仓库。

## 默认会忽略的敏感文件
- `.env`
- `config/active_account.json`
- `config/binance_accounts.json`
- `git-sync.local.env`
- `projects.json`
- `git-remote.json`
- 数据库、日志、虚拟环境等

说明：`config/binance_api.env` 不会被忽略，因为公开仓库需要保留模板文件；但脚本会扫描文本文件中的真实密钥、Token、密码赋值并阻止继续同步。

## 常用用法
### 1. 首次公开初始化并推送
```powershell
powershell -ExecutionPolicy Bypass -File D:\codex\git-sync\sync-project.ps1 -ProjectPath "D:\codex\币安自动开单系统" -RepoName "币安自动开单系统" -Visibility public -CreateRemote -PublicInit
```

### 2. 后续增量同步
```powershell
powershell -ExecutionPolicy Bypass -File D:\codex\git-sync\sync-project.ps1 -ProjectPath "D:\codex\币安自动开单系统"
```

说明：如果不传 `-RepoName`，脚本会优先沿用项目已有的 `origin`、`git-remote.json` 或 `projects.json` 中登记的仓库名，不会再默认把远端改成目录名。

### 2.1 工具自身首次公开同步
```powershell
powershell -ExecutionPolicy Bypass -File D:\codex\git-sync\sync-project.ps1 -ProjectPath "D:\codex\git-sync" -RepoName "git-sync" -Visibility public -CreateRemote
```

### 3. 先预演不真正执行
```powershell
powershell -ExecutionPolicy Bypass -File D:\codex\git-sync\sync-project.ps1 -ProjectPath "D:\codex\币安自动开单系统" -DryRun -SkipPush
```

## 参数说明
- `-ProjectPath`：项目路径，默认当前目录
- `-GitHubUser`：GitHub 用户名；不传时按“本地覆盖 -> 公共配置 -> 环境变量”解析
- `-RepoName`：远程仓库名，默认等于项目目录名
- `-Visibility public|private`：创建远程仓库时使用
- `-CreateRemote`：如果 GitHub 上仓库不存在，则自动创建
- `-GitHubToken`：可直接传 PAT；不传时按“本地覆盖 -> 公共配置 -> 环境变量”解析
- `-SkipCommit`：跳过提交
- `-SkipPush`：跳过推送
- `-DryRun`：只打印动作，不真正执行
- `-PublicInit`：在校验通过后临时替换现有 `.git`，基于当前脱敏工作树重建干净历史；失败时自动恢复

## Git 地址登记
### 中心登记文件
`D:\codex\git-sync\projects.json`

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

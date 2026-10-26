# Scoop Local Extensions

为 Scoop 保存和重放的本地功能补丁。此项目不是软件 bucket，也不是 Scoop 官方发行版。
仅包含源码补丁、应用脚本、回归测试和文档，不包含用户配置、凭据、缓存或已安装应用。

## 功能

1. **可选的自动结束进程**：保留 `kill_running_processes` 本地扩展。显式启用后，Scoop 可结束目标应用安装目录下的进程；该选项优先于 `ignore_running_processes`，不默认结束其他应用。
2. **更新先下载、再停止**：普通下载和 aria2 均先完成下载及启用的哈希校验，再检查或结束旧版进程，最后卸载旧版、安装新版。下载或校验失败时，不执行结束进程和卸载步骤。卸载、重置命令原有的进程检查时机不变。
3. **容错清理旧版本**：某个旧版本删除失败时报告未完成项，继续处理其他版本和应用。部分失败返回非零状态，不会仍宣称全部清理成功。当前版本和持久化数据不作为旧版本清理目标。
4. **修改操作互斥**：有副作用的 Scoop 命令串行进入，超时报告持锁进程而不是强杀；帮助、查询及 `cleanup --dry-run` 不等待写锁。
5. **清理保留与预演**：`--keep N` 保留当前版本及最近安装的 N-1 个旧版本；`--dry-run` 只展示删除/保留计划，不修改联接、属性、缓存或应用文件。
6. **Git 网络超时与失败汇总**：给 clone/fetch/pull/ls-remote 设置可配置的时间上限；单个 bucket 失败不妨碍其他 bucket 检查，但不会把不完整同步报告成成功。
7. **批量准备与预下载**：`update --prefetch` 只准备本批更新；`update -b`（也可用 `--batch`）在所有目标及缺失依赖下载校验通过后，再串行执行更新。
8. **缓存离线安装/更新**：`install --offline` / `update --offline` 使用本地清单及已校验缓存；缺少文件、无哈希或存在不允许的安装脚本时，在改变应用前拒绝执行。
9. **显式更新后恢复**：`update --restart` 仅在成功后尝试重新启动本次确实停止且符合策略的普通 GUI 主程序，不恢复系统进程、服务、参数或工作会话。

清理失败时会尽力查询 Windows Restart Manager，显示可识别占用者的 PID、进程名、程序路径及诊断来源；只显示手动操作提示，不自动执行停止命令。诊断不能保证准确识别所有占用者；权限不足、资源管理器加载 DLL、杀毒软件或其他原因都可能使删除失败。补丁不会为了清理而强杀进程、重启 Explorer、修改 ACL、取得所有权或安排重启删除。

## 兼容基线

- Windows PowerShell 5.1 或 PowerShell 7，以及 Git。
- Scoop v0.6.0，基准提交为 `e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f`。
- 精确来源和补丁文件见 [`upstream.json`](upstream.json)。
- 其他 Scoop 修订只有在完整补丁预检通过时才能应用；不保证未来上游版本自动兼容。

当前补丁包版本为 **0.3.0**：完整补丁修改八个已有源码文件。已完整应用时再次运行不会重复修改；完整的 v1 或 0.2.0 补丁通过独立增量补丁升级，先做完整预检，不先撤销正在使用的旧功能。只有部分功能存在、存在冲突或上游上下文变化时，脚本拒绝写入，而不是强行覆盖本地修改。

## 应用

先关闭其他正在修改 Scoop 核心的命令。不要与 `scoop update` 同时运行补丁脚本。

```powershell
git clone https://github.com/LeeXieXie/scoop-local-extensions.git
cd scoop-local-extensions
$scoopRoot = scoop prefix scoop

# 只检查兼容性，不修改 Scoop 源码。
.\scripts\Apply-LocalExtensions.ps1 -ScoopRoot $scoopRoot -Check

# 预检通过后应用；脚本会报告源文件备份目录。
.\scripts\Apply-LocalExtensions.ps1 -ScoopRoot $scoopRoot
```

`-ScoopRoot` 必须指向实际的 Git 源码目录；如果 `scoop prefix scoop` 返回的路径或其父目录是 Junction / 符号链接，请先核对目标，再改用其物理路径。脚本会拒绝通过重解析点修改源码，不自动绕过此检查。

### 保存目标 Scoop 仓库中的修改

应用脚本只修改八个明确允许的源码文件，**不会自动创建 Git 提交**。补丁仓库已经推送到 GitHub，不等于目标 Scoop 仓库中的修改也已提交；默认 Scoop 遇到未提交的源码变更会提示 `Uncommitted changes detected. Update aborted.` 并拒绝自更新。

先检查差异，确认要保留的本地修改，再在目标 Scoop 仓库提交。不要在未审核的情况下提交其他文件：

```powershell
git -C $scoopRoot status --short
git -C $scoopRoot diff -- lib/install.ps1 libexec/scoop-config.ps1 libexec/scoop-update.ps1 libexec/scoop-cleanup.ps1 bin/scoop.ps1 lib/core.ps1 lib/download.ps1 libexec/scoop-install.ps1
git -C $scoopRoot add -- lib/install.ps1 libexec/scoop-config.ps1 libexec/scoop-update.ps1 libexec/scoop-cleanup.ps1 bin/scoop.ps1 lib/core.ps1 lib/download.ps1 libexec/scoop-install.ps1
git -C $scoopRoot commit -m "Keep reviewed local extensions during Scoop updates" -m "Scope-risk: moderate"
```

提交后确认 `git -C $scoopRoot diff HEAD --name-only` 没有输出。正常同源、同分支更新会通过 Git pull 保留本地提交；未来仍可能发生需要人工审核的合并冲突。不要为了消除提示而丢弃修改或把扩展临时藏入 stash。

**不要把 `SCOOP_REPO` 设置为本补丁仓库**，这里不是完整 Scoop 源码。更换 Scoop 更新源或分支可能触发其重置路径，应另行备份和审核。

应用脚本不更改 Scoop 的配置、远程仓库或更新通道，也不安装、更新、卸载或清理任何应用。
如果需要自动结束目标应用进程，由用户另行显式启用：

```powershell
scoop config kill_running_processes true
```

强制结束进程可能丢失未保存的数据。它也可能中断使用该应用的终端、代理或其他工作，启用前应确认可以接受。没有启用该选项时，原有的阻止更新或忽略运行中进程策略继续适用。

补丁应用后，下次 Scoop 命令加载新脚本即可生效，不需要重启电脑。

## cleanup 的边界

```powershell
# 预览：当前版本加两个最近安装的旧版本，共保留三份。
scoop cleanup '*' --keep 3 --dry-run

# 确认计划后再实际清理。
scoop cleanup '*' --keep 3

# 缓存清理同样保护保留版本，预览不会删除缓存。
scoop cleanup '*' --keep 3 --cache --dry-run
```

`--keep` 的默认值为 1，不能是 0、负数或小数。排序采用 Scoop 安装记录的时间顺序，不按文件夹名称的字典顺序；回退后当前版本仍受保护。启用额外保留时，无法确认安装顺序的备份/未知目录保守保留并说明原因。预演不通过试删判断占用或权限，实际执行时会重新验证当前版本和路径，因此预演不是后续删除成功的保证。

旧 PowerToys 的 Shell 扩展 DLL 仍被资源管理器加载时，管理员权限也不一定能删除它。
补丁会保留未删除的残留并提示，而不是静默绕过 Windows 锁或误报成功。
Scoop 的只读持久化 Junction 与真实文件占用分别处理：只移除旧版本中的联接，不删除其指向的 `persist` 数据。
只读持久化文件或可识别的只读硬链接会保守地跳过该旧版本并报告失败，避免 `-Force` 改动共享文件属性；不会为了消除警告而清除目标文件的只读属性。
确认没有未保存工作后，可自行正常关闭相关应用和资源管理器窗口，再重试；必要时重启系统后清理。
PID 可能被系统复用，手动停止前应重新核对名称和路径；结束 Explorer 会中断桌面及资源管理器窗口，关键系统进程或承载服务的进程不应按普通应用直接结束。
这不是磁盘清理器，也不会清空 `persist`、用户目录或已安装应用的当前版本。

递归删除前检查目标路径边界。遇到意外的路径、版本根重解析点或无法安全确认的目标，应拒绝删除并继续报告失败。

## 操作互斥与网络超时

```powershell
# 最多等待其他修改操作 30 秒；0 表示忙时立即失败。
scoop config operation_lock_timeout 30

# Git 网络操作默认最多 120 秒；0 显式关闭该时间限制。
scoop config git_network_timeout 120
```

不需要设置这两项即可采用上述默认值。锁只记录命令名、PID 和启动时间，不记录可能含凭据的完整参数。锁释放不依赖删除锁文件，残留文件不代表还有持锁进程。global 操作也需要共享全局锁目录的访问权限，扩展不会自动修改 ACL 取得权限。

同一进程内的嵌套调用可重入；检测到子进程等待持锁祖先时会拒绝执行，避免无限等待。global 范围不能在已经持有的 local 嵌套操作中临时升级，应单独运行。写命令仍可能因超时失败，不代表具备 FIFO 调度或安装事务保证。

`import` 根据本地 Scoopfile 中的 `Global install` 标记决定是否需要全局锁；仅含用户级应用的导入不要求全局目录存在。为在执行前固定锁范围，0.2.0 要求先把 URL/UNC 来源的 Scoopfile 保存到本地文件再导入，不直接接受远程导入地址。解析期间保留文件只读句柄，避免计划与实际导入内容在等待锁时被替换。

网络超时只针对本次启动的 Git 子进程树，不结束其他 Git 工作、不重置源码、不更换远程地址。某个 bucket 同步失败会汇总显示，不更新“上次成功同步”时间，也不打印整体成功。该限制不是应用下载超时，不影响已有下载器的独立设置。

## 批量准备、离线模式与恢复

以下选项均显式启用，不改变普通 `scoop update` 的默认流程：

```powershell
# 只为整批待更新应用及缺失依赖准备缓存，不停止或更新应用。
scoop update '*' --prefetch

# 整批文件全部下载校验成功后，才开始逐个更新。
scoop update '*' -b
# 等价简写：-a 表示全部应用，-b 表示整批准备。
scoop update -ab

# 使用当前本地 bucket 清单和缓存，不同步 Scoop/bucket，不下载缺失文件。
scoop update '*' --offline
scoop install personal/example-portable --offline

# 显式要求在成功更新后恢复本次实际停止的合格 GUI 主程序。
scoop update magpie-ai -b --restart
```

`-b` 与 `--batch` 完全等价；`-ab` 等价于 `'*' -b`。已安装早期 0.3.0、仅缺少短参数的用户，可在审核后用 [`upgrade-v3-batch-alias.patch`](patches/upgrade-v3-batch-alias.patch) 做单文件增量更新：先对目标 Scoop 执行 `git apply --check`，再应用；之后用本库 `-Check` 核对完整状态并提交目标仓库中的修改。

早期 0.3.0 的批量安装曾因旧 `check_hash` 隐式依赖调用者的下载 URL，在 bucket 来源为空时触发 URI 构造异常。现已在独立校验作用域传递实际下载 URL，同时保留原清单来源；回归测试使用真实哈希及 URI 格式化函数，不再用模拟哈希掩盖该依赖。已经安装早期版本的用户可审核并应用 [`upgrade-v3-prepared-hash.patch`](patches/upgrade-v3-prepared-hash.patch)，再核对和提交本机源码；不要用强制重新安装来掩盖源码问题。

`example-portable` 只是语法示例，需替换为真实、符合离线策略且已缓存的包。预下载不是导出包，也不会把所有历史版本下载到缓存。准备阶段固定本次的清单、版本、来源与架构；缺失依赖也必须先就绪，不能在关闭应用后才临时联网。安装仍串行，某个安装失败时不承诺整批原子性或自动回滚。

**离线模式不等于网络沙箱。** 它禁止 Scoop 自身的远程清单解析、同步及有效载荷下载，仅使用已有本地清单及带有效哈希的完整缓存。为避免任意脚本或安装器绕过下载路径，离线模式保守拒绝安装/卸载钩子、外部安装器、`env_set` 动态展开、MSI、nightly 或无哈希包，也不接受跳过哈希、绕过缓存等冲突选项。远程/UNC/网络盘来源、`@version` 生成以及含未完成下载标记或联接/硬链接的缓存同样不支持。大多数带自定义钩子的 GUI 包可能因此不能离线安装；不静默放宽此限制。外部解压工具及安装后由用户运行的程序不受本扩展的操作系统级网络隔离。

**恢复不是会话还原。** 仅记录并去重本次由更新停止、且可核对为清单 GUI 快捷方式目标的主程序相对路径，不保存完整命令行、环境、凭据或工作目录。只在确认新版本安装成功、目标路径位于新安装目录内且不是重解析点逃逸后启动，不带原始参数；不会恢复未保存的内容。服务、Explorer、终端、当前工作进程及其祖先链、关键系统进程和后台子助手不作为自动恢复对象。没有可确认的主程序快捷方式时保守跳过。未开启 `--restart`、程序原本没运行、更新被跳过或失败时不会自动启动新版；此选项本身不自动启用 `kill_running_processes`。

## 测试

对已应用补丁的 Scoop 源码运行聚焦测试：

```powershell
.\scripts\Test-LocalExtensions.ps1 -ScoopRoot (scoop prefix scoop)
```

测试使用隔离夹具；更新顺序测试提取真正的 `update` 函数，但替换下载、进程结束和安装边界，不操作真实应用。文件占用测试仅使用临时目录中的独占打开文件。CI 在固定上游修订的临时源码树中应用补丁，验证再次应用的幂等性，并在 Windows PowerShell 与 PowerShell 7 下运行测试。

测试不会通过运行真实 `scoop cleanup '*'`、结束用户进程或更新应用来证明行为。
通过测试不代表任意真实占用文件都能删除，也不代表未来 Scoop 更新一定兼容。

## 维护与恢复

- Scoop 核心升级后先运行 `-Check`，确认完整补丁是否仍适用，不要跳过兼容性检查。
- 部分应用或冲突需要人工审核差异。不要用 `git reset --hard` 或覆盖整个安装目录来解决。
- 备份只用于恢复本次涉及的源码文件。恢复前比对当前差异，避免覆盖后来新增的修改。
- 每次修改补丁时同步更新本 README、设计说明、基准信息和回归测试。
- 发布仓库不等于自动把这些功能合入上游，也不会使所有人的 Scoop 自动获得补丁。

设计和安全约束见 [`DESIGN.md`](DESIGN.md)，初版执行记录见 [`docs/PLAN.md`](docs/PLAN.md)，互斥/保留策略见 [`docs/MILESTONE-2.md`](docs/MILESTONE-2.md)，本轮范围见 [`docs/MILESTONE-3.md`](docs/MILESTONE-3.md)，网上方案的借鉴与取舍见 [`docs/REFERENCES.md`](docs/REFERENCES.md)。

## 许可

补丁涉及的 Scoop 代码以及本仓库新增脚本和测试采用 Unlicense 或 MIT 双许可，可任选其一，详见保留的上游 [`LICENSE`](LICENSE)。Scoop 名称及上游归属不因本地修改而改变。

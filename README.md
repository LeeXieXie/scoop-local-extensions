# Scoop Local Extensions

为 Scoop 保存和重放的本地功能补丁。此项目不是软件 bucket，也不是 Scoop 官方发行版。
仅包含源码补丁、应用脚本、回归测试和文档，不包含用户配置、凭据、缓存或已安装应用。

## 功能

1. **可选的自动结束进程**：保留 `kill_running_processes` 本地扩展。显式启用后，Scoop 可结束目标应用安装目录下的进程；该选项优先于 `ignore_running_processes`，不默认结束其他应用。
2. **更新先下载、再停止**：普通下载和 aria2 均先完成下载及启用的哈希校验，再检查或结束旧版进程，最后卸载旧版、安装新版。下载或校验失败时，不执行结束进程和卸载步骤。卸载、重置命令原有的进程检查时机不变。
3. **容错清理旧版本**：某个旧版本删除失败时报告未完成项，继续处理其他版本和应用。部分失败返回非零状态，不会仍宣称全部清理成功。当前版本和持久化数据不作为旧版本清理目标。

清理失败时会尽力查询 Windows Restart Manager，显示可识别占用者的 PID、进程名、程序路径及诊断来源；只显示手动操作提示，不自动执行停止命令。诊断不能保证准确识别所有占用者；权限不足、资源管理器加载 DLL、杀毒软件或其他原因都可能使删除失败。补丁不会为了清理而强杀进程、重启 Explorer、修改 ACL、取得所有权或安排重启删除。

## 兼容基线

- Windows PowerShell 5.1 或 PowerShell 7，以及 Git。
- Scoop v0.6.0，基准提交为 `e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f`。
- 精确来源和补丁文件见 [`upstream.json`](upstream.json)。
- 其他 Scoop 修订只有在完整补丁预检通过时才能应用；不保证未来上游版本自动兼容。

这是**单个组合补丁**。已完整应用时再次运行不会重复修改；只有部分功能存在、存在冲突或上游上下文变化时，脚本应拒绝写入，而不是强行覆盖本地修改。

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

应用脚本不更改 Scoop 的配置、远程仓库或更新通道，也不安装、更新、卸载或清理任何应用。
如果需要自动结束目标应用进程，由用户另行显式启用：

```powershell
scoop config kill_running_processes true
```

强制结束进程可能丢失未保存的数据。它也可能中断使用该应用的终端、代理或其他工作，启用前应确认可以接受。没有启用该选项时，原有的阻止更新或忽略运行中进程策略继续适用。

补丁应用后，下次 Scoop 命令加载新脚本即可生效，不需要重启电脑。

## cleanup 的边界

```powershell
scoop cleanup '*'
```

旧 PowerToys 的 Shell 扩展 DLL 仍被资源管理器加载时，管理员权限也不一定能删除它。
补丁会保留未删除的残留并提示，而不是静默绕过 Windows 锁或误报成功。
Scoop 的只读持久化 Junction 与真实文件占用分别处理：只移除旧版本中的联接，不删除其指向的 `persist` 数据。
只读持久化文件或可识别的只读硬链接会保守地跳过该旧版本并报告失败，避免 `-Force` 改动共享文件属性；不会为了消除警告而清除目标文件的只读属性。
确认没有未保存工作后，可自行正常关闭相关应用和资源管理器窗口，再重试；必要时重启系统后清理。
PID 可能被系统复用，手动停止前应重新核对名称和路径；结束 Explorer 会中断桌面及资源管理器窗口，关键系统进程或承载服务的进程不应按普通应用直接结束。
这不是磁盘清理器，也不会清空 `persist`、用户目录或已安装应用的当前版本。

递归删除前检查目标路径边界。遇到意外的路径、版本根重解析点或无法安全确认的目标，应拒绝删除并继续报告失败。

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

设计和安全约束见 [`DESIGN.md`](DESIGN.md)，执行记录见 [`docs/PLAN.md`](docs/PLAN.md)。

## 许可

补丁涉及的 Scoop 代码以及本仓库新增脚本和测试采用 Unlicense 或 MIT 双许可，可任选其一，详见保留的上游 [`LICENSE`](LICENSE)。Scoop 名称及上游归属不因本地修改而改变。

# SamCutout 部署与使用说明

## 发布文件

请把下面 4 个文件放在同一个文件夹中：

```text
SamCutout.exe
InstallRuntime.cmd
InstallModels.cmd
README.md
```

首次运行安装脚本后会自动创建：

```text
_internal\   公共 Python 运行环境和公开依赖库
models\      官方模型文件
logs\        安装和运行日志
```

不要手动移动或删除 `_internal`、`models`、`logs` 与 `SamCutout.exe` 的相对位置。

## 电脑要求

- Windows 10/11 x64
- NVIDIA 显卡和可用的 NVIDIA 驱动
- 能联网下载依赖和模型
- 建议预留 20 GB 以上磁盘空间

`InstallRuntime.cmd` 会自动检测 NVIDIA GPU：

- RTX 50 系或 `compute_cap >= 12.0`：安装 PyTorch `cu128` 线路
- 其他受支持 NVIDIA GPU：安装 PyTorch `cu124` 线路
- 无 NVIDIA GPU、驱动过旧或 `nvidia-smi` 不可用：脚本会停止并提示原因

## 首次安装

1. 双击 `InstallRuntime.cmd`，等待公共依赖安装完成。
2. 双击 `InstallModels.cmd`，按提示输入 Hugging Face Token 下载官方模型。
3. 双击 `SamCutout.exe` 启动软件。

PyTorch 依赖体积很大。脚本会先对 PyTorch 官方源、阿里云镜像和 PyTorch R2 源做小段测速，然后自动选择最快可用源下载。普通 PyPI 依赖也会对官方 PyPI、阿里云、清华和腾讯镜像测速排序，不会固定使用单一镜像。

下载 PyTorch 大包时，控制台只刷新一条进度，日志只记录测速结果、选中源、关键节点和低频进度，避免日志刷屏。

如果测速低于 `0.5 MB/s`，脚本会提示当前网络较慢。此时仍可继续在线安装，但更建议使用离线 runtime 包。

## 模型文件

`InstallModels.cmd` 会下载并放入 `models`：

- `sam3.pt`
- `sam_vit_h_4b8939.pth`
- `bpe_simple_vocab_16e6.txt.gz`

其中 `sam3.pt` 来自 Hugging Face `facebook/sam3`，需要用户提前申请访问权限，并提供自己的 Hugging Face Token。

## 日常使用

依赖和模型安装完成后，平时只需要双击 `SamCutout.exe`。

软件内可以设置默认保存目录。每次下载 PNG、ZIP 或训练样本时，都会弹出系统“另存为”窗口，可以修改保存位置和文件名。

## 常见问题

- 提示 runtime 缺失：先运行 `InstallRuntime.cmd`。
- 提示模型缺失：先运行 `InstallModels.cmd`。
- 提示没有 NVIDIA GPU：确认电脑有 NVIDIA 显卡，并已安装官方驱动。
- 提示驱动 CUDA 版本不足：升级 NVIDIA 驱动后重新运行 `InstallRuntime.cmd`。
- 依赖下载很慢：查看 `logs\runtime_install.log` 中的测速结果；也可以尝试打开或关闭 VPN 后重新运行。
- 安装中途失败或关闭窗口：重新运行对应脚本即可，已完成的 wheel 会优先复用。
- 重复双击安装脚本：第二个安装进程会被锁拦截，避免破坏环境；旧安装卡死时新版脚本会自动清理 stale lock。
- SAM3 下载失败：确认 Hugging Face Token 有 `facebook/sam3` 访问权限。
- 被安全软件拦截：允许当前目录下的 `SamCutout.exe` 和安装脚本创建文件。

## 日志位置

```text
logs\runtime_install.log
logs\model_install.log
logs\launcher.log
logs\launcher_child.log
logs\desktop_runtime.log
```

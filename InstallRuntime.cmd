@echo off
setlocal
set "SAMCUTOUT_SELF=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p=$env:SAMCUTOUT_SELF; $s=[IO.File]::ReadAllText($p); iex ($s.Substring($s.LastIndexOf('#>')+2))"
exit /b %ERRORLEVEL%
#>
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$Root = Split-Path -Parent $env:SAMCUTOUT_SELF
$Internal = Join-Path $Root "_internal"
$Downloads = Join-Path $Internal "downloads"
$WheelsDir = Join-Path $Downloads "wheels"
$MambaDir = Join-Path $Internal "micromamba"
$EnvDir = Join-Path $Internal "env"
$PrivateDir = Join-Path $Internal "private"
$Logs = Join-Path $Root "logs"
$Log = Join-Path $Logs "runtime_install.log"
$StateFile = Join-Path $Internal "runtime_state.json"
$LockFile = Join-Path $Internal "install.lock"
$InstallerVersion = "20260717-gpu-adaptive-triton"
$RuntimeSchemaVersion = "runtime-schema-20260717-gpu-adaptive-triton"
$RuntimeVersion = "unselected"
$SupportedTorchFlavors = @("cu124", "cu128")
$LockMaxHours = 2
$LockStaleMinutes = 20
$PipRetryArgs = @("--timeout", "60", "--retries", "5")
$GpuInfo = $null
$TorchConfig = $null
$InstallLockOwned = $false
$PypiSourceRanking = $null

New-Item -ItemType Directory -Force $Internal, $Downloads, $WheelsDir, $MambaDir, $Logs | Out-Null
Remove-Item Env:\PYTHONPATH -ErrorAction SilentlyContinue
Remove-Item Env:\PYTHONHOME -ErrorAction SilentlyContinue
$env:PIP_DISABLE_PIP_VERSION_CHECK = "1"

function Write-Log([string]$Message) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -Path $Log -Value $line -Encoding UTF8
    Write-Host $Message
    if ($InstallLockOwned -and (Test-Path $LockFile)) {
        try {
            [IO.File]::SetLastWriteTime($LockFile, (Get-Date))
        } catch {
        }
    }
}

function Touch-InstallLock {
    if ($InstallLockOwned -and (Test-Path $LockFile)) {
        try {
            [IO.File]::SetLastWriteTime($LockFile, (Get-Date))
        } catch {
        }
    }
}

function ConvertTo-InvariantDouble([string]$Value, [string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "$Name is empty."
    }
    return [double]::Parse($Value.Trim(), [Globalization.CultureInfo]::InvariantCulture)
}

function Test-MinVersion([double]$Actual, [double]$Minimum) {
    return ($Actual + 0.0001) -ge $Minimum
}

function Get-NvidiaSmiPath {
    $command = Get-Command "nvidia-smi.exe" -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    $fallback = Join-Path $env:WINDIR "System32\nvidia-smi.exe"
    if (Test-Path $fallback) { return $fallback }

    throw "No NVIDIA GPU runtime detected: nvidia-smi.exe was not found. SamCutout currently requires an NVIDIA GPU and a working NVIDIA driver."
}

function Infer-ComputeCapFromName([string]$GpuName) {
    $nameText = if ($null -eq $GpuName) { "" } else { $GpuName }
    $name = $nameText.ToUpperInvariant()
    if ($name -match "RTX\s*50|RTX\s*5090|RTX\s*5080|RTX\s*5070|BLACKWELL") { return 12.0 }
    if ($name -match "RTX\s*40|RTX\s*4090|RTX\s*4080|RTX\s*4070|RTX\s*4060|ADA") { return 8.9 }
    if ($name -match "RTX\s*30|RTX\s*3090|RTX\s*3080|RTX\s*3070|RTX\s*3060|AMPERE") { return 8.6 }
    if ($name -match "RTX\s*20|RTX\s*2080|RTX\s*2070|RTX\s*2060|TURING|GTX\s*16") { return 7.5 }
    if ($name -match "GTX\s*10|GTX\s*1080|GTX\s*1070|GTX\s*1060|PASCAL") { return 6.1 }
    throw "Could not determine GPU compute capability from name '$GpuName'. Update the NVIDIA driver so nvidia-smi can report compute_cap."
}

function Get-NvidiaCudaVersion([string]$SmiPath) {
    $override = $env:SAMCUTOUT_CUDA_VERSION
    if (![string]::IsNullOrWhiteSpace($override)) {
        return ConvertTo-InvariantDouble $override "SAMCUTOUT_CUDA_VERSION"
    }

    $plain = & $SmiPath 2>&1
    $text = ($plain | Out-String)
    if ($text -match "CUDA Version:\s*([0-9]+(?:\.[0-9]+)?)") {
        return ConvertTo-InvariantDouble $Matches[1] "nvidia-smi CUDA Version"
    }

    throw "Could not read supported CUDA runtime version from nvidia-smi output. Update the NVIDIA driver and run InstallRuntime.cmd again."
}

function Get-GpuInfo {
    $overrideCap = $env:SAMCUTOUT_GPU_COMPUTE_CAP
    if (![string]::IsNullOrWhiteSpace($overrideCap)) {
        if ($overrideCap.Trim().ToLowerInvariant() -in @("none", "nogpu", "no-gpu", "0")) {
            throw "No NVIDIA GPU selected by SAMCUTOUT_GPU_COMPUTE_CAP=$overrideCap."
        }
        $compute = ConvertTo-InvariantDouble $overrideCap "SAMCUTOUT_GPU_COMPUTE_CAP"
        $cuda = if (![string]::IsNullOrWhiteSpace($env:SAMCUTOUT_CUDA_VERSION)) {
            ConvertTo-InvariantDouble $env:SAMCUTOUT_CUDA_VERSION "SAMCUTOUT_CUDA_VERSION"
        } elseif ($compute -ge 12.0) {
            12.8
        } else {
            12.4
        }
        return [ordered]@{
            gpu_name = if (![string]::IsNullOrWhiteSpace($env:SAMCUTOUT_GPU_NAME)) { $env:SAMCUTOUT_GPU_NAME } else { "Override NVIDIA GPU" }
            compute_cap = $compute
            cuda_version = $cuda
            source = "environment"
        }
    }

    $smi = Get-NvidiaSmiPath
    $queryOutput = & $smi "--query-gpu=name,compute_cap" "--format=csv,noheader" 2>&1
    $queryExit = $LASTEXITCODE
    $first = ($queryOutput | Where-Object { $_ } | Select-Object -First 1)
    $gpuName = $null
    $compute = $null

    if ($queryExit -eq 0 -and $first) {
        $parts = ([string]$first).Split(",")
        if ($parts.Count -ge 2) {
            $gpuName = $parts[0].Trim()
            $computeText = $parts[1].Trim()
            try {
                $compute = ConvertTo-InvariantDouble $computeText "nvidia-smi compute_cap"
            } catch {
                $compute = $null
            }
        }
    }

    if ($null -eq $compute) {
        $nameOutput = & $smi "--query-gpu=name" "--format=csv,noheader" 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "nvidia-smi failed to query GPU information: $($nameOutput | Out-String)"
        }
        $gpuName = [string]($nameOutput | Where-Object { $_ } | Select-Object -First 1)
        $compute = Infer-ComputeCapFromName $gpuName
        Write-Log "nvidia-smi compute_cap unavailable; inferred compute capability $compute from GPU name '$gpuName'."
    }

    $cudaVersion = Get-NvidiaCudaVersion $smi
    return [ordered]@{
        gpu_name = $gpuName
        compute_cap = $compute
        cuda_version = $cudaVersion
        source = "nvidia-smi"
    }
}

function Select-TorchConfig($Info) {
    $compute = [double]$Info.compute_cap
    $cuda = [double]$Info.cuda_version

    if ($compute -ge 12.0) {
        if (!(Test-MinVersion $cuda 12.8)) {
            throw ("GPU '{0}' requires the cu128 runtime, but the installed NVIDIA driver reports CUDA {1}. Upgrade the NVIDIA driver until nvidia-smi reports CUDA Version 12.8 or newer." -f $Info.gpu_name, $Info.cuda_version)
        }
        return [ordered]@{
            runtime_version = "py310-cu128-20260717-gpu-adaptive-triton"
            torch_flavor = "cu128"
            torch = "torch==2.11.0+cu128"
            torchvision = "torchvision==0.26.0+cu128"
            torch_version = "2.11.0+cu128"
            torchvision_version = "0.26.0+cu128"
            index_url = "https://download.pytorch.org/whl/cu128"
            mirror_base_url = "https://mirrors.aliyun.com/pytorch-wheels/cu128"
            official_base_url = "https://download.pytorch.org/whl/cu128"
            r2_base_url = "https://download-r2.pytorch.org/whl/cu128"
            extra_packages = @("triton-windows==3.7.1.post27")
        }
    }

    if (!(Test-MinVersion $cuda 12.4)) {
        throw ("GPU '{0}' can use the cu124 runtime, but the installed NVIDIA driver reports CUDA {1}. Upgrade the NVIDIA driver until nvidia-smi reports CUDA Version 12.4 or newer." -f $Info.gpu_name, $Info.cuda_version)
    }
        return [ordered]@{
            runtime_version = "py310-cu124-20260717-gpu-adaptive-triton"
            torch_flavor = "cu124"
            torch = "torch==2.6.0+cu124"
            torchvision = "torchvision==0.21.0+cu124"
            torch_version = "2.6.0+cu124"
            torchvision_version = "0.21.0+cu124"
        index_url = "https://download.pytorch.org/whl/cu124"
        mirror_base_url = "https://mirrors.aliyun.com/pytorch-wheels/cu124"
        official_base_url = "https://download.pytorch.org/whl/cu124"
        r2_base_url = "https://download-r2.pytorch.org/whl/cu124"
        extra_packages = @("triton-windows==3.7.1.post27")
    }
}

function Test-RuntimeState {
    if (!(Test-Path $StateFile)) { return $false }
    if (!(Test-Path (Join-Path $EnvDir "python.exe"))) { return $false }
    if ($null -eq $TorchConfig) { return $false }
    try {
        $state = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        return (
            ($state.runtime_schema -eq $RuntimeSchemaVersion) -and
            ($state.runtime_version -eq $TorchConfig.runtime_version) -and
            ($state.install_status -eq "complete") -and
            ($SupportedTorchFlavors -contains $state.torch_flavor)
        )
    } catch {
        return $false
    }
}

function Get-ProcessCommandLine([int]$ProcessId) {
    try {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop
        if ($proc) { return [string]$proc.CommandLine }
    } catch {
    }
    return ""
}

function Test-InstallerProcess([int]$ProcessId) {
    $commandLine = Get-ProcessCommandLine $ProcessId
    if ([string]::IsNullOrWhiteSpace($commandLine)) { return $false }

    $normCommand = $commandLine.ToLowerInvariant()
    $markers = @(
        $Root.ToLowerInvariant(),
        $Internal.ToLowerInvariant(),
        $EnvDir.ToLowerInvariant(),
        "installruntime.cmd",
        "samcutout"
    )
    foreach ($marker in $markers) {
        if ($marker -and $normCommand.Contains($marker)) { return $true }
    }
    return $false
}

function Get-ChildProcessIds([int]$ProcessId) {
    $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$ProcessId" -ErrorAction SilentlyContinue)
    foreach ($child in $children) {
        foreach ($grandChildId in Get-ChildProcessIds ([int]$child.ProcessId)) {
            $grandChildId
        }
        [int]$child.ProcessId
    }
}

function Stop-InstallerProcessTree([int]$ProcessId, [string]$Reason) {
    if (!(Test-InstallerProcess $ProcessId)) {
        Write-Log "Lock PID $ProcessId is running but does not look like a SamCutout installer process; removing lock without killing it."
        return
    }

    $ids = @()
    $ids += @(Get-ChildProcessIds $ProcessId)
    $ids += $ProcessId
    $ids = @($ids | Select-Object -Unique)
    Write-Log "Stopping stale SamCutout installer process tree. reason=$Reason, pids=$($ids -join ',')"
    foreach ($id in $ids) {
        try {
            Stop-Process -Id $id -Force -ErrorAction Stop
            Write-Log "Stopped stale installer process PID=$id"
        } catch {
            Write-Log "Could not stop stale installer process PID=${id}: $($_.Exception.Message)"
        }
    }
}

function Stop-OrphanRuntimeInstallProcesses([string]$Reason) {
    $escapedInternal = $Internal.Replace("\", "\\")
    $escapedEnv = $EnvDir.Replace("\", "\\")
    $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $cmd = [string]$_.CommandLine
        $cmd -and (
            $cmd.IndexOf($Internal, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $cmd.IndexOf($EnvDir, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $cmd.IndexOf($escapedInternal, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $cmd.IndexOf($escapedEnv, [StringComparison]::OrdinalIgnoreCase) -ge 0
        )
    })
    foreach ($proc in $processes) {
        $procId = [int]$proc.ProcessId
        if ($procId -eq $PID) { continue }
        Write-Log "Stopping orphan SamCutout runtime install process. reason=$Reason, pid=$procId, name=$($proc.Name)"
        try {
            Stop-Process -Id $procId -Force -ErrorAction Stop
        } catch {
            Write-Log "Could not stop orphan install process PID=${procId}: $($_.Exception.Message)"
        }
    }
}

function Acquire-InstallLock {
    $script:InstallLockOwned = $false
    if (Test-Path $LockFile) {
        $lockItem = Get-Item $LockFile
        $age = (Get-Date) - $lockItem.LastWriteTime
        $lockPid = $null
        $lockStarted = $null
        $lockInstallerVersion = $null

        try {
            $lockState = Get-Content $LockFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($lockState.pid) { $lockPid = [int]$lockState.pid }
            if ($lockState.started_at) { $lockStarted = [string]$lockState.started_at }
            if ($lockState.installer_version) { $lockInstallerVersion = [string]$lockState.installer_version }
        } catch {
            Write-Log "Install lock exists but cannot be parsed: $($_.Exception.Message)"
        }

        if ($lockPid) {
            $process = Get-Process -Id $lockPid -ErrorAction SilentlyContinue
            if ($process) {
                $ageText = ("{0:N1} minutes" -f $age.TotalMinutes)
                if ($age.TotalMinutes -ge $LockStaleMinutes) {
                    Write-Log "Install lock heartbeat is stale: PID=$lockPid, started_at=$lockStarted, lock_age=$ageText, installer_version=$lockInstallerVersion."
                    Stop-InstallerProcessTree $lockPid "stale lock heartbeat"
                    Stop-OrphanRuntimeInstallProcesses "stale lock heartbeat"
                    Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
                } else {
                    throw "InstallRuntime.cmd is already running. Active installer PID=$lockPid, started_at=$lockStarted, lock_age=$ageText. The lock heartbeat is still fresh, so a second installer will not start."
                }
            } else {
                Write-Log "Removing stale install lock because PID $lockPid is no longer running."
                Stop-OrphanRuntimeInstallProcesses "lock pid no longer running"
                Remove-Item $LockFile -Force
            }
        } elseif ($age.TotalHours -ge $LockMaxHours) {
            Write-Log "Removing stale unparsable install lock older than $LockMaxHours hours."
            Stop-OrphanRuntimeInstallProcesses "old unparsable lock"
            Remove-Item $LockFile -Force
        } else {
            throw "InstallRuntime.cmd lock exists but has no usable PID. Lock age is under $LockMaxHours hours. Close any installer windows first, then delete _internal\install.lock if no installer is running."
        }
    }

    if (Test-Path $LockFile) {
        Remove-Item $LockFile -Force
    }

    $lockState = [ordered]@{
        pid = $PID
        started_at = (Get-Date).ToString("s")
        installer_version = $InstallerVersion
        runtime_schema = $RuntimeSchemaVersion
        runtime_version = $RuntimeVersion
        torch_flavor = if ($TorchConfig) { $TorchConfig.torch_flavor } else { "unselected" }
    }
    $lockState | ConvertTo-Json | Set-Content -Path $LockFile -Encoding UTF8
    $script:InstallLockOwned = $true
}

function Release-InstallLock {
    $script:InstallLockOwned = $false
    Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
}

function Remove-PathRobust([string]$Path) {
    if (!(Test-Path $Path)) { return }
    Write-Log "Removing incomplete path: $Path"
    try {
        Remove-Item $Path -Recurse -Force -ErrorAction Stop
        return
    } catch {
        $stamp = Get-Date -Format "yyyyMMddHHmmss"
        $trash = "$Path.stale.$stamp"
        try {
            Rename-Item -Path $Path -NewName (Split-Path -Leaf $trash) -ErrorAction Stop
            Remove-Item $trash -Recurse -Force -ErrorAction Stop
            return
        } catch {
            throw "Cannot remove incomplete runtime path: $Path. Close Python/pip/micromamba processes or reboot, then run InstallRuntime.cmd again. Original error: $($_.Exception.Message)"
        }
    }
}

function Test-PythonEnvUsable {
    $py = Join-Path $EnvDir "python.exe"
    if (!(Test-Path $py)) { return $false }
    try {
        $output = & $py -V 2>&1
        return ($LASTEXITCODE -eq 0) -and ([string]$output -match "Python 3\.10")
    } catch {
        return $false
    }
}

function Prepare-RuntimeEnvironment {
    Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
    Remove-PathRobust $PrivateDir
    Remove-Item (Join-Path $Downloads "*.part") -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $WheelsDir "*\*.part") -Force -ErrorAction SilentlyContinue
    Remove-PathRobust (Join-Path $Downloads "micromamba_extract")

    if (Test-PythonEnvUsable) {
        Write-Log "Existing Python runtime is usable; continuing repair install without rebuilding env."
        return
    }

    if (Test-Path $EnvDir) {
        Write-Log "Existing Python runtime is missing or broken; rebuilding env."
        Remove-PathRobust $EnvDir
    }
}

function Invoke-ExternalStep(
    [string]$Name,
    [string]$FilePath,
    [string[]]$Arguments,
    [int]$TimeoutMinutes,
    [string]$RuntimeEnvDir = $EnvDir
) {
    Write-Log "STEP START: $Name"
    Write-Log ("COMMAND: {0} {1}" -f $FilePath, ($Arguments -join " "))

    $started = Get-Date
    $job = Start-Job -ScriptBlock {
        param(
            [string]$JobFilePath,
            [string[]]$JobArguments,
            [string]$JobWorkingDirectory,
            [string]$JobRuntimeEnvDir
        )

        Set-Location $JobWorkingDirectory
        Remove-Item Env:\PYTHONPATH -ErrorAction SilentlyContinue
        Remove-Item Env:\PYTHONHOME -ErrorAction SilentlyContinue
        $env:PIP_DISABLE_PIP_VERSION_CHECK = "1"

        $runtimePathEntries = @(
            $JobRuntimeEnvDir,
            (Join-Path $JobRuntimeEnvDir "Scripts"),
            (Join-Path $JobRuntimeEnvDir "Library\bin"),
            (Join-Path $JobRuntimeEnvDir "Library\cmd"),
            (Join-Path $JobRuntimeEnvDir "Library\mingw64\bin"),
            (Join-Path $JobRuntimeEnvDir "Library\usr\bin"),
            (Join-Path $JobRuntimeEnvDir "DLLs")
        ) | Where-Object { $_ -and (Test-Path $_) }
        if ($runtimePathEntries.Count -gt 0) {
            $env:PATH = (($runtimePathEntries + @($env:PATH)) -join [System.IO.Path]::PathSeparator)
        }

        & $JobFilePath @JobArguments 2>&1 | ForEach-Object { $_ }
        [pscustomobject]@{ SamCutoutExitCode = $LASTEXITCODE }
    } -ArgumentList $FilePath, $Arguments, $Root, $RuntimeEnvDir

    $timeoutMs = [Math]::Max(1, $TimeoutMinutes) * 60 * 1000
    $deadline = (Get-Date).AddMilliseconds($timeoutMs)
    $exitCode = $null

    while ($job.State -eq "Running" -and (Get-Date) -lt $deadline) {
        $items = Receive-Job $job
        foreach ($item in $items) {
            if ($item.PSObject.Properties.Name -contains "SamCutoutExitCode") {
                $exitCode = [int]$item.SamCutoutExitCode
            } elseif ($null -ne $item) {
                Add-Content -Path $Log -Value ([string]$item) -Encoding UTF8
                Write-Host ([string]$item)
                Touch-InstallLock
            }
        }
        Start-Sleep -Milliseconds 250
    }

    if ($job.State -eq "Running") {
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        throw "$Name timed out after $TimeoutMinutes minutes. Run InstallRuntime.cmd again after checking network stability."
    }

    $items = Receive-Job $job
    foreach ($item in $items) {
        if ($item.PSObject.Properties.Name -contains "SamCutoutExitCode") {
            $exitCode = [int]$item.SamCutoutExitCode
        } elseif ($null -ne $item) {
            Add-Content -Path $Log -Value ([string]$item) -Encoding UTF8
            Write-Host ([string]$item)
            Touch-InstallLock
        }
    }
    $jobState = $job.State
    Remove-Job $job -Force -ErrorAction SilentlyContinue

    $elapsed = [int]((Get-Date) - $started).TotalSeconds
    if ($null -eq $exitCode) {
        throw "$Name finished without an exit code. Job state: $jobState"
    }
    Write-Log "STEP END: $Name, exit_code=$exitCode, elapsed=${elapsed}s"
    if ($exitCode -ne 0) {
        throw "$Name failed with exit code $exitCode"
    }
}

function Invoke-DownloadWithRetry(
    [string]$Name,
    [string]$Uri,
    [string]$OutFile,
    [int]$Retries = 5,
    [int]$TimeoutSec = 120
) {
    $part = "$OutFile.part"
    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        try {
            Write-Log "Downloading $Name, attempt $attempt/$Retries"
            Remove-Item $part -Force -ErrorAction SilentlyContinue
            $started = Get-Date
            Invoke-WebRequest -Uri $Uri -OutFile $part -TimeoutSec $TimeoutSec -UseBasicParsing
            $elapsed = [Math]::Round(((Get-Date) - $started).TotalSeconds, 2)
            $bytes = (Get-Item $part).Length
            Move-Item $part $OutFile -Force
            Write-Log "Downloaded $Name, bytes=$bytes, elapsed=${elapsed}s"
            return
        } catch {
            Write-Log ("Download failed for {0} on attempt {1}/{2}: {3}" -f $Name, $attempt, $Retries, $_.Exception.Message)
            Remove-Item $part -Force -ErrorAction SilentlyContinue
            if ($attempt -eq $Retries) { throw }
            Start-Sleep -Seconds ([Math]::Min(30, 5 * $attempt))
        }
    }
}

function Format-DownloadSize([long]$Bytes) {
    if ($Bytes -lt 0) { return "unknown" }
    return ("{0:N1} MB" -f ($Bytes / 1MB))
}

function Format-DownloadEta([double]$Seconds) {
    if ([double]::IsNaN($Seconds) -or [double]::IsInfinity($Seconds) -or $Seconds -lt 0) {
        return "unknown"
    }
    $ts = [TimeSpan]::FromSeconds([Math]::Round($Seconds))
    if ($ts.TotalHours -ge 1) {
        return ("{0}h {1}m" -f [int]$ts.TotalHours, $ts.Minutes)
    }
    return ("{0}m {1}s" -f $ts.Minutes, $ts.Seconds)
}

function Write-ProgressLine([string]$Message) {
    Write-Host ("`r{0}" -f $Message) -NoNewline
}

function Complete-ProgressLine {
    Write-Host ""
}

function Get-RemoteFileLength([string]$Uri) {
    if ($Uri.StartsWith("file:", [StringComparison]::OrdinalIgnoreCase)) {
        $path = ([Uri]$Uri).LocalPath
        if (!(Test-Path $path)) { throw "Local test file not found: $path" }
        return (Get-Item $path).Length
    }

    $request = [Net.HttpWebRequest]([Net.WebRequest]::Create($Uri))
    $request.Method = "HEAD"
    $request.UserAgent = "SamCutoutRuntimeInstaller/1.0"
    $request.Timeout = 30000
    $request.ReadWriteTimeout = 30000
    $response = $null
    try {
        $response = $request.GetResponse()
        return [long]$response.ContentLength
    } finally {
        if ($response) { $response.Close() }
    }
}

function Get-RemoteFileLengthFromRange([string]$Uri) {
    if ($Uri.StartsWith("file:", [StringComparison]::OrdinalIgnoreCase)) {
        return Get-RemoteFileLength $Uri
    }

    $request = [Net.HttpWebRequest]([Net.WebRequest]::Create($Uri))
    $request.Method = "GET"
    $request.UserAgent = "SamCutoutRuntimeInstaller/1.0"
    $request.Timeout = 30000
    $request.ReadWriteTimeout = 30000
    $request.AddRange(0, 0)
    $response = $null
    try {
        $response = $request.GetResponse()
        $contentRange = [string]$response.Headers["Content-Range"]
        if ($contentRange -match "/(\d+)$") {
            return [long]$Matches[1]
        }
        if ($response.ContentLength -gt 0) {
            return [long]$response.ContentLength
        }
        return -1L
    } finally {
        if ($response) { $response.Close() }
    }
}

function Test-DownloadSourceSpeed(
    [string]$Name,
    [string]$Uri,
    [int]$MaxSeconds = 15,
    [int]$MaxBytes = 8388608
) {
    $started = Get-Date
    $bytes = 0L
    $errorText = ""
    try {
        if ($Uri.StartsWith("file:", [StringComparison]::OrdinalIgnoreCase)) {
            $source = ([Uri]$Uri).LocalPath
            $buffer = New-Object byte[] (1024 * 1024)
            $stream = [IO.File]::OpenRead($source)
            try {
                while ($bytes -lt $MaxBytes -and ((Get-Date) - $started).TotalSeconds -lt $MaxSeconds) {
                    $remaining = [Math]::Min($buffer.Length, $MaxBytes - $bytes)
                    $read = $stream.Read($buffer, 0, $remaining)
                    if ($read -le 0) { break }
                    $bytes += $read
                }
            } finally {
                $stream.Close()
            }
        } else {
            $request = [Net.HttpWebRequest]([Net.WebRequest]::Create($Uri))
            $request.Method = "GET"
            $request.UserAgent = "SamCutoutRuntimeInstaller/1.0"
            $request.Timeout = 15000
            $request.ReadWriteTimeout = 15000
            $request.AddRange(0, $MaxBytes - 1)
            $response = $null
            $stream = $null
            try {
                $response = $request.GetResponse()
                $stream = $response.GetResponseStream()
                $buffer = New-Object byte[] (1024 * 1024)
                while ($bytes -lt $MaxBytes -and ((Get-Date) - $started).TotalSeconds -lt $MaxSeconds) {
                    $remaining = [Math]::Min($buffer.Length, $MaxBytes - $bytes)
                    $read = $stream.Read($buffer, 0, $remaining)
                    if ($read -le 0) { break }
                    $bytes += $read
                }
            } finally {
                if ($stream) { $stream.Close() }
                if ($response) { $response.Close() }
            }
        }
    } catch {
        $errorText = $_.Exception.Message
    }

    $elapsed = [Math]::Max(0.1, ((Get-Date) - $started).TotalSeconds)
    $speed = $bytes / $elapsed
    return [pscustomobject]@{
        Name = $Name
        Uri = $Uri
        Bytes = $bytes
        Seconds = [Math]::Round($elapsed, 2)
        MBps = [Math]::Round(($speed / 1MB), 2)
        BytesPerSecond = [long]$speed
        Error = $errorText
        Ok = ($bytes -gt 0 -and [string]::IsNullOrWhiteSpace($errorText))
    }
}

function Select-FastestDownloadSources(
    [string]$Name,
    [object[]]$Sources
) {
    Write-Log "Testing download sources for $Name..."
    $results = @()
    foreach ($source in $Sources) {
        $result = Test-DownloadSourceSpeed $source.name $source.uri 15 8388608
        $results += $result
        if ($result.Ok) {
            Write-Log ("Speed test {0}: {1:N1} MB in {2}s, {3} MB/s" -f $result.Name, ($result.Bytes / 1MB), $result.Seconds, $result.MBps)
        } else {
            Write-Log ("Speed test {0}: failed, bytes={1}, error={2}" -f $result.Name, $result.Bytes, $result.Error)
        }
    }

    $ranked = @($results | Where-Object { $_.Bytes -gt 0 } | Sort-Object BytesPerSecond -Descending)
    if ($ranked.Count -eq 0) {
        throw "No usable download source for $Name. Last errors: $(($results | ForEach-Object { $_.Name + '=' + $_.Error }) -join '; ')"
    }

    $winner = $ranked[0]
    Write-Log ("Selected download source for {0}: {1}, speed={2} MB/s" -f $Name, $winner.Name, $winner.MBps)
    if ($winner.MBps -lt 0.5) {
        Write-Log ("WARNING: selected source for {0} is slow ({1} MB/s). Consider using an offline runtime package." -f $Name, $winner.MBps)
        Write-Host ("WARNING: download source is slow ({0} MB/s). Offline runtime package is recommended." -f $winner.MBps)
    }
    return $ranked
}

function New-PypiSources {
    return @(
        [pscustomobject]@{
            Name = "Official PyPI"
            TestUri = "https://pypi.org/simple/pip/"
            Args = @("-i", "https://pypi.org/simple/")
        },
        [pscustomobject]@{
            Name = "Aliyun PyPI"
            TestUri = "https://mirrors.aliyun.com/pypi/simple/pip/"
            Args = @("-i", "https://mirrors.aliyun.com/pypi/simple/", "--trusted-host", "mirrors.aliyun.com")
        },
        [pscustomobject]@{
            Name = "Tsinghua PyPI"
            TestUri = "https://pypi.tuna.tsinghua.edu.cn/simple/pip/"
            Args = @("-i", "https://pypi.tuna.tsinghua.edu.cn/simple/", "--trusted-host", "pypi.tuna.tsinghua.edu.cn")
        },
        [pscustomobject]@{
            Name = "Tencent PyPI"
            TestUri = "https://mirrors.cloud.tencent.com/pypi/simple/pip/"
            Args = @("-i", "https://mirrors.cloud.tencent.com/pypi/simple/", "--trusted-host", "mirrors.cloud.tencent.com")
        }
    )
}

function Select-FastestPypiSources {
    if ($script:PypiSourceRanking) { return $script:PypiSourceRanking }

    Write-Log "Testing PyPI sources for public dependency installation..."
    $results = @()
    foreach ($source in (New-PypiSources)) {
        $result = Test-DownloadSourceSpeed $source.Name $source.TestUri 8 524288
        $result | Add-Member -NotePropertyName Args -NotePropertyValue $source.Args
        $results += $result
        if ($result.Ok) {
            Write-Log ("PyPI speed test {0}: {1:N1} KB in {2}s, {3} MB/s" -f $result.Name, ($result.Bytes / 1KB), $result.Seconds, $result.MBps)
        } else {
            Write-Log ("PyPI speed test {0}: failed, bytes={1}, error={2}" -f $result.Name, $result.Bytes, $result.Error)
        }
    }

    $ranked = @($results | Where-Object { $_.Bytes -gt 0 } | Sort-Object BytesPerSecond -Descending)
    if ($ranked.Count -eq 0) {
        Write-Log "No PyPI source passed speed test; falling back to built-in order."
        $ranked = New-PypiSources | ForEach-Object {
            [pscustomobject]@{
                Name = $_.Name
                Args = $_.Args
                BytesPerSecond = 0
                MBps = 0
            }
        }
    }

    Write-Log ("Selected PyPI source order: {0}" -f (($ranked | ForEach-Object { "{0}({1} MB/s)" -f $_.Name, $_.MBps }) -join " -> "))
    $script:PypiSourceRanking = $ranked
    return $ranked
}

function Invoke-ProgressFileCopy(
    [string]$Name,
    [string]$SourcePath,
    [string]$OutFile
) {
    $part = "$OutFile.part"
    Remove-Item $part -Force -ErrorAction SilentlyContinue
    $total = (Get-Item $SourcePath).Length
    $buffer = New-Object byte[] (1024 * 1024)
    $downloaded = 0L
    $started = Get-Date
    $lastLog = $started.AddSeconds(-10)
    $inputStream = [IO.File]::OpenRead($SourcePath)
    $outputStream = New-Object IO.FileStream($part, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $outputStream.Write($buffer, 0, $read)
            $downloaded += $read
            $now = Get-Date
            if (($now - $lastLog).TotalSeconds -ge 5 -or $downloaded -eq $total) {
                $elapsed = [Math]::Max(0.1, ($now - $started).TotalSeconds)
                $speed = $downloaded / $elapsed
                $percent = if ($total -gt 0) { [Math]::Round(($downloaded * 100.0) / $total, 1) } else { 0 }
                $eta = if ($speed -gt 0) { ($total - $downloaded) / $speed } else { [double]::NaN }
                Write-ProgressLine ("{0} | {1}/{2} | {3}% | {4}/s | ETA {5} | local" -f $Name, (Format-DownloadSize $downloaded), (Format-DownloadSize $total), $percent, (Format-DownloadSize ([long]$speed)), (Format-DownloadEta $eta))
                $lastLog = $now
            }
        }
    } finally {
        $outputStream.Close()
        $inputStream.Close()
    }
    Complete-ProgressLine
    Move-Item $part $OutFile -Force
}

function Invoke-LargeFileDownloadWithProgress(
    [string]$Name,
    [object[]]$Sources,
    [string]$OutFile,
    [int]$RetriesPerUri = 2,
    [int]$NoProgressTimeoutSec = 300
) {
    New-Item -ItemType Directory -Force (Split-Path -Parent $OutFile) | Out-Null
    $part = "$OutFile.part"
    $lastError = $null

    foreach ($source in $Sources) {
        $uri = [string]$source.Uri
        $sourceName = [string]$source.Name
        for ($attempt = 1; $attempt -le $RetriesPerUri; $attempt++) {
            try {
                Write-Log "Downloading $Name from $sourceName ($uri), attempt $attempt/$RetriesPerUri"

                if ($uri.StartsWith("file:", [StringComparison]::OrdinalIgnoreCase)) {
                    Invoke-ProgressFileCopy $Name ([Uri]$uri).LocalPath $OutFile
                    Write-Log "Downloaded $Name, bytes=$((Get-Item $OutFile).Length), source=file"
                    return
                }

                $expectedLength = -1L
                try {
                    $expectedLength = Get-RemoteFileLengthFromRange $uri
                } catch {
                    Write-Log "Could not read remote size for $Name before download: $($_.Exception.Message)"
                }

                if ((Test-Path $OutFile) -and $expectedLength -gt 0 -and (Get-Item $OutFile).Length -eq $expectedLength) {
                    Write-Log "Using cached ${Name}: $OutFile, bytes=$expectedLength"
                    return
                }

                $resumeBytes = if (Test-Path $part) { (Get-Item $part).Length } else { 0L }
                if ($expectedLength -gt 0 -and $resumeBytes -gt $expectedLength) {
                    Remove-Item $part -Force -ErrorAction SilentlyContinue
                    $resumeBytes = 0L
                }

                $request = [Net.HttpWebRequest]([Net.WebRequest]::Create($uri))
                $request.Method = "GET"
                $request.UserAgent = "SamCutoutRuntimeInstaller/1.0"
                $request.Timeout = 60000
                $request.ReadWriteTimeout = 60000
                if ($resumeBytes -gt 0) {
                    $request.AddRange($resumeBytes)
                    Write-Log "Resuming $Name from byte $resumeBytes"
                }

                $response = $null
                $inputStream = $null
                $outputStream = $null
                try {
                    $response = $request.GetResponse()
                    $statusCode = [int]$response.StatusCode
                    $append = $resumeBytes -gt 0 -and $statusCode -eq 206
                    if ($resumeBytes -gt 0 -and !$append) {
                        Write-Log "Server did not honor resume for $Name; restarting download."
                        $resumeBytes = 0L
                    }

                    $mode = if ($append) { [IO.FileMode]::Append } else { [IO.FileMode]::Create }
                    $downloaded = $resumeBytes
                    $total = if ($expectedLength -gt 0) { $expectedLength } elseif ($response.ContentLength -gt 0) { $downloaded + [long]$response.ContentLength } else { -1L }
                    $inputStream = $response.GetResponseStream()
                    $outputStream = New-Object IO.FileStream($part, $mode, [IO.FileAccess]::Write, [IO.FileShare]::None)
                    $buffer = New-Object byte[] (1024 * 1024)
                    $started = Get-Date
                    $lastConsole = $started.AddSeconds(-10)
                    $lastLog = $started
                    $nextLogPercent = 10
                    $lastProgress = Get-Date
                    $lastBytes = $downloaded

                    while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                        $outputStream.Write($buffer, 0, $read)
                        $downloaded += $read
                        $now = Get-Date
                        if ($downloaded -gt $lastBytes) {
                            $lastBytes = $downloaded
                            $lastProgress = $now
                        }
                        if (($now - $lastProgress).TotalSeconds -gt $NoProgressTimeoutSec) {
                            throw "$Name download made no progress for $NoProgressTimeoutSec seconds."
                        }
                        $elapsed = [Math]::Max(0.1, ($now - $started).TotalSeconds)
                        $speed = [Math]::Max(1, ($downloaded - $resumeBytes) / $elapsed)
                        $percent = if ($total -gt 0) { [Math]::Round(($downloaded * 100.0) / $total, 1) } else { 0 }
                        $eta = if ($total -gt 0 -and $speed -gt 0) { ($total - $downloaded) / $speed } else { [double]::NaN }
                        if (($now - $lastConsole).TotalSeconds -ge 2 -or ($total -gt 0 -and $downloaded -eq $total)) {
                            Write-ProgressLine ("{0} | {1}/{2} | {3}% | {4}/s | ETA {5} | {6}" -f $Name, (Format-DownloadSize $downloaded), (Format-DownloadSize $total), $percent, (Format-DownloadSize ([long]$speed)), (Format-DownloadEta $eta), $sourceName)
                            $lastConsole = $now
                        }
                        if (($now - $lastLog).TotalMinutes -ge 5 -or ($percent -ge $nextLogPercent) -or ($total -gt 0 -and $downloaded -eq $total)) {
                            Write-Log ("Progress {0}: {1}/{2}, {3}%, speed={4}/s, eta={5}, source={6}" -f $Name, (Format-DownloadSize $downloaded), (Format-DownloadSize $total), $percent, (Format-DownloadSize ([long]$speed)), (Format-DownloadEta $eta), $sourceName)
                            $lastLog = $now
                            while ($percent -ge $nextLogPercent) { $nextLogPercent += 10 }
                        }
                    }

                    if ($total -gt 0 -and $downloaded -lt $total) {
                        throw "$Name download incomplete: downloaded $downloaded of $total bytes."
                    }
                } finally {
                    if ($outputStream) { $outputStream.Close() }
                    if ($inputStream) { $inputStream.Close() }
                    if ($response) { $response.Close() }
                }

                Complete-ProgressLine
                Move-Item $part $OutFile -Force
                Write-Log "Downloaded $Name, bytes=$((Get-Item $OutFile).Length), source=$sourceName, path=$OutFile"
                return
            } catch {
                Complete-ProgressLine
                $lastError = $_.Exception.Message
                Write-Log ("Download failed for {0} from {1} on attempt {2}/{3}: {4}" -f $Name, $sourceName, $attempt, $RetriesPerUri, $lastError)
                if ($attempt -lt $RetriesPerUri) {
                    Start-Sleep -Seconds ([Math]::Min(30, 5 * $attempt))
                }
            }
        }
    }

    throw "Failed to download $Name from all configured sources. Last error: $lastError"
}

function Get-WheelFileName([string]$Requirement) {
    $parts = $Requirement.Split(@("=="), [StringSplitOptions]::None)
    if ($parts.Count -ne 2) { throw "Invalid wheel requirement: $Requirement" }
    return ("{0}-{1}-cp310-cp310-win_amd64.whl" -f $parts[0], $parts[1])
}

function Join-DownloadUrl([string]$BaseUrl, [string]$FileName) {
    return ($BaseUrl.TrimEnd("/") + "/" + [Uri]::EscapeDataString($FileName))
}

function New-WheelSources($Config, [string]$FileName) {
    return @(
        [pscustomobject]@{
            Name = "PyTorch official"
            Uri = Join-DownloadUrl $Config.official_base_url $FileName
        },
        [pscustomobject]@{
            Name = "Aliyun mirror"
            Uri = Join-DownloadUrl $Config.mirror_base_url $FileName
        },
        [pscustomobject]@{
            Name = "PyTorch R2"
            Uri = Join-DownloadUrl $Config.r2_base_url $FileName
        }
    )
}

function Save-TorchWheels($Config) {
    $flavorWheelDir = Join-Path $WheelsDir $Config.torch_flavor
    New-Item -ItemType Directory -Force $flavorWheelDir | Out-Null

    $torchWheel = Get-WheelFileName $Config.torch
    $torchvisionWheel = Get-WheelFileName $Config.torchvision
    $torchPath = Join-Path $flavorWheelDir $torchWheel
    $torchvisionPath = Join-Path $flavorWheelDir $torchvisionWheel

    $torchSources = New-WheelSources $Config $torchWheel
    $rankedTorchSources = Select-FastestDownloadSources "PyTorch wheel $($Config.torch)" $torchSources
    $rankedSourceNames = @($rankedTorchSources | ForEach-Object { $_.Name })
    $torchvisionSources = @()
    foreach ($sourceName in $rankedSourceNames) {
        $base = switch ($sourceName) {
            "PyTorch official" { $Config.official_base_url }
            "Aliyun mirror" { $Config.mirror_base_url }
            "PyTorch R2" { $Config.r2_base_url }
        }
        if ($base) {
            $torchvisionSources += [pscustomobject]@{
                Name = $sourceName
                Uri = Join-DownloadUrl $base $torchvisionWheel
            }
        }
    }

    Invoke-LargeFileDownloadWithProgress "PyTorch wheel $($Config.torch)" $rankedTorchSources $torchPath 2 300
    Invoke-LargeFileDownloadWithProgress "TorchVision wheel $($Config.torchvision)" $torchvisionSources $torchvisionPath 2 300

    return [ordered]@{
        torch = $torchPath
        torchvision = $torchvisionPath
        wheel_dir = $flavorWheelDir
    }
}

function Invoke-PipInstallWithMirrorFallback(
    [string]$Name,
    [string]$PythonExe,
    [string[]]$Packages,
    [int]$TimeoutMinutes
) {
    $rankedSources = Select-FastestPypiSources
    $lastError = $null
    foreach ($source in $rankedSources) {
        $sourceArgs = @($source.Args)
        $pipArgs = @("-m", "pip", "install") + $PipRetryArgs + $sourceArgs + $Packages
        try {
            Invoke-ExternalStep "$Name via $($source.Name)" $PythonExe $pipArgs $TimeoutMinutes
            return
        } catch {
            $lastError = $_.Exception.Message
            Write-Log "$Name via $($source.Name) failed; trying next PyPI source if available. Error: $lastError"
        }
    }

    throw "$Name failed on all PyPI sources. Last error: $lastError"
}

function Ensure-Micromamba {
    $mambaExe = Join-Path $MambaDir "micromamba.exe"
    if (Test-Path $mambaExe) { return $mambaExe }

    $archive = Join-Path $Downloads "micromamba.tar.bz2"
    $extract = Join-Path $Downloads "micromamba_extract"
    Invoke-DownloadWithRetry `
        -Name "micromamba" `
        -Uri "https://micro.mamba.pm/api/micromamba/win-64/latest" `
        -OutFile $archive `
        -Retries 5 `
        -TimeoutSec 180

    Remove-PathRobust $extract
    New-Item -ItemType Directory -Force $extract | Out-Null
    Invoke-ExternalStep "Extracting micromamba" "tar.exe" @("-xjf", $archive, "-C", $extract) 10
    $found = Get-ChildItem $extract -Recurse -Filter "micromamba.exe" | Select-Object -First 1
    if (!$found) { throw "micromamba.exe not found after extraction." }
    Copy-Item $found.FullName $mambaExe -Force
    return $mambaExe
}

function Write-RuntimeState {
    $state = [ordered]@{
        runtime_schema = $RuntimeSchemaVersion
        runtime_version = $TorchConfig.runtime_version
        install_status = "complete"
        installed_at = (Get-Date).ToString("s")
        python = "3.10"
        torch_flavor = $TorchConfig.torch_flavor
        torch = $TorchConfig.torch_version
        torchvision = $TorchConfig.torchvision_version
        torch_index_url = $TorchConfig.index_url
        gpu_name = $GpuInfo.gpu_name
        compute_cap = [string]$GpuInfo.compute_cap
        cuda_version = [string]$GpuInfo.cuda_version
        gpu_detection_source = $GpuInfo.source
    }
    $state | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8
}

function Invoke-InstallerSelfTest {
    Write-Log "Installer self-test started."
    $selfTestRoot = Join-Path $env:TEMP ("samcutout_installer_selftest_" + [Guid]::NewGuid().ToString("N"))
    $src = Join-Path $selfTestRoot "src"
    $dst = Join-Path $selfTestRoot "dst"
    $archive = Join-Path $selfTestRoot "selftest.tar"
    $fakeEnv = Join-Path $selfTestRoot "fake_env"
    $oldCap = $env:SAMCUTOUT_GPU_COMPUTE_CAP
    $oldCuda = $env:SAMCUTOUT_CUDA_VERSION
    $oldName = $env:SAMCUTOUT_GPU_NAME

    try {
        New-Item -ItemType Directory -Force $src, $dst | Out-Null
        Set-Content -Path (Join-Path $src "hello.txt") -Value "hello" -Encoding UTF8
        & tar.exe -cf $archive -C $src "hello.txt"
        if ($LASTEXITCODE -ne 0) {
            throw "Self-test could not create tar archive. Exit code: $LASTEXITCODE"
        }

        Invoke-ExternalStep "Self-test tar extraction" "tar.exe" @("-xf", $archive, "-C", $dst) 2

        $extracted = Join-Path $dst "hello.txt"
        if (!(Test-Path $extracted)) {
            throw "Self-test extraction did not create expected file: $extracted"
        }

        $fakeBin = Join-Path $fakeEnv "Library\bin"
        New-Item -ItemType Directory -Force $fakeBin | Out-Null
        $fakeTool = Join-Path $fakeBin "samcutout_fake_tool.cmd"
        "@echo off`r`necho FAKE_TOOL_OK`r`nexit /b 0`r`n" | Set-Content -Path $fakeTool -Encoding ASCII
        Invoke-ExternalStep "Self-test runtime PATH" "cmd.exe" @("/c", "samcutout_fake_tool.cmd") 2 $fakeEnv

        $downloadSource = Join-Path $selfTestRoot "download_source.txt"
        $downloadTarget = Join-Path $selfTestRoot "download_target.txt"
        Set-Content -Path $downloadSource -Value "download-ok" -Encoding UTF8
        Invoke-DownloadWithRetry `
            -Name "self-test download" `
            -Uri ([Uri]$downloadSource).AbsoluteUri `
            -OutFile $downloadTarget `
            -Retries 1 `
            -TimeoutSec 10
        if (!(Test-Path $downloadTarget)) {
            throw "Self-test download did not create expected file: $downloadTarget"
        }

        $largeSource = Join-Path $selfTestRoot "large_source.bin"
        $largeTarget = Join-Path $selfTestRoot "large_target.bin"
        $bytes = New-Object byte[] (3 * 1024 * 1024)
        [byte]7 | ForEach-Object { for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = $_ } }
        [IO.File]::WriteAllBytes($largeSource, $bytes)
        Invoke-LargeFileDownloadWithProgress `
            -Name "self-test large download" `
            -Sources @([pscustomobject]@{ Name = "local self-test source"; Uri = ([Uri]$largeSource).AbsoluteUri }) `
            -OutFile $largeTarget `
            -RetriesPerUri 1 `
            -NoProgressTimeoutSec 30
        if (!(Test-Path $largeTarget) -or (Get-Item $largeTarget).Length -ne $bytes.Length) {
            throw "Self-test large download did not create expected file: $largeTarget"
        }

        $missingSource = Join-Path $selfTestRoot "missing.bin"
        $rankedSources = Select-FastestDownloadSources "self-test source ranking" @(
            [pscustomobject]@{ Name = "missing source"; Uri = ([Uri]$missingSource).AbsoluteUri },
            [pscustomobject]@{ Name = "local source"; Uri = ([Uri]$largeSource).AbsoluteUri }
        )
        if ($rankedSources[0].Name -ne "local source") {
            throw "Self-test expected local source to win speed ranking, got $($rankedSources[0].Name)."
        }

        $env:SAMCUTOUT_GPU_NAME = "SelfTest RTX 5080"
        $env:SAMCUTOUT_GPU_COMPUTE_CAP = "12.0"
        $env:SAMCUTOUT_CUDA_VERSION = "12.8"
        $cu128 = Select-TorchConfig (Get-GpuInfo)
        if ($cu128.torch_flavor -ne "cu128") { throw "Self-test expected cu128, got $($cu128.torch_flavor)." }

        $env:SAMCUTOUT_GPU_NAME = "SelfTest RTX 3080"
        $env:SAMCUTOUT_GPU_COMPUTE_CAP = "8.6"
        $env:SAMCUTOUT_CUDA_VERSION = "12.4"
        $cu124 = Select-TorchConfig (Get-GpuInfo)
        if ($cu124.torch_flavor -ne "cu124") { throw "Self-test expected cu124, got $($cu124.torch_flavor)." }

        $env:SAMCUTOUT_GPU_COMPUTE_CAP = "none"
        try {
            [void](Get-GpuInfo)
            throw "Self-test expected no-GPU detection to fail."
        } catch {
            if ($_.Exception.Message -notmatch "No NVIDIA GPU") { throw }
        }

        Write-Log "Installer self-test complete."
    } finally {
        if ($null -eq $oldCap) { Remove-Item Env:\SAMCUTOUT_GPU_COMPUTE_CAP -ErrorAction SilentlyContinue } else { $env:SAMCUTOUT_GPU_COMPUTE_CAP = $oldCap }
        if ($null -eq $oldCuda) { Remove-Item Env:\SAMCUTOUT_CUDA_VERSION -ErrorAction SilentlyContinue } else { $env:SAMCUTOUT_CUDA_VERSION = $oldCuda }
        if ($null -eq $oldName) { Remove-Item Env:\SAMCUTOUT_GPU_NAME -ErrorAction SilentlyContinue } else { $env:SAMCUTOUT_GPU_NAME = $oldName }
        Remove-Item $selfTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($env:SAMCUTOUT_INSTALLER_SELFTEST -eq "1") {
    try {
        Invoke-InstallerSelfTest
        exit 0
    } catch {
        Write-Log "ERROR: $($_.Exception.Message)"
        exit 1
    }
}

try {
    Write-Log "SamCutout runtime installer started."
    $GpuInfo = Get-GpuInfo
    $TorchConfig = Select-TorchConfig $GpuInfo
    $RuntimeVersion = $TorchConfig.runtime_version
    Write-Log ("Detected GPU: name='{0}', compute_cap={1}, driver_cuda={2}, source={3}" -f $GpuInfo.gpu_name, $GpuInfo.compute_cap, $GpuInfo.cuda_version, $GpuInfo.source)
    Write-Log ("Selected PyTorch runtime: flavor={0}, torch={1}, torchvision={2}, index={3}" -f $TorchConfig.torch_flavor, $TorchConfig.torch, $TorchConfig.torchvision, $TorchConfig.index_url)

    if (Test-RuntimeState) {
        Write-Log "Runtime already installed: $RuntimeVersion"
        exit 0
    }

    Acquire-InstallLock
    try {
        if (Test-RuntimeState) {
            Write-Log "Runtime already installed after lock acquisition: $RuntimeVersion"
            exit 0
        }

        Write-Log "Runtime state is missing, invalid, or incomplete. Repair install will be performed."
        Prepare-RuntimeEnvironment

        Write-Log "Installing SamCutout public runtime into $EnvDir"
        $MambaExe = Ensure-Micromamba

        if (!(Test-PythonEnvUsable)) {
            Invoke-ExternalStep "Creating Python 3.10 environment" $MambaExe @(
                "create", "-y", "-p", $EnvDir, "-c", "conda-forge", "python=3.10", "pip"
            ) 45
        } else {
            Write-Log "Skipping Python environment creation; existing env will be reused."
        }

        $Py = Join-Path $EnvDir "python.exe"

        $upgradePipArgs = @("-m", "pip", "install", "--upgrade") + $PipRetryArgs + @("pip")
        Invoke-ExternalStep "Upgrading pip" $Py $upgradePipArgs 15

        $torchWheels = Save-TorchWheels $TorchConfig
        Invoke-PipInstallWithMirrorFallback `
            -Name ("Installing local PyTorch {0} wheels" -f $TorchConfig.torch_flavor) `
            -PythonExe $Py `
            -Packages @($torchWheels.torch, $torchWheels.torchvision) `
            -TimeoutMinutes 80

        $commonPackages = @(
            "PySide6==6.11.1",
            "opencv-python==4.10.0.84",
            "fastapi==0.136.3",
            "uvicorn==0.49.0",
            "numpy==1.26.4",
            "pillow==12.2.0",
            "requests==2.34.2",
            "timm==1.0.27",
            "huggingface_hub==0.36.2",
            "ftfy==6.1.1",
            "regex",
            "tqdm",
            "iopath",
            "portalocker",
            "pycocotools",
            "python-multipart",
            "kornia",
            "einops",
            "safetensors",
            "transformers==4.35.2",
            "tokenizers==0.15.2",
            "psutil==7.2.2",
            "segment-anything==1.0",
            "sam3==0.1.4"
        )
        Invoke-PipInstallWithMirrorFallback `
            -Name "Installing desktop and API dependencies" `
            -PythonExe $Py `
            -Packages ($commonPackages + $TorchConfig.extra_packages) `
            -TimeoutMinutes 140

        $verifyScript = Join-Path $env:TEMP ("samcutout_verify_runtime_" + [Guid]::NewGuid().ToString("N") + ".py")
        @'
import os
import sys

env_dir = os.path.normcase(os.path.abspath(sys.argv[1]))
expected_compute = float(sys.argv[2])
torch_flavor = sys.argv[3]
bad_roots = [os.path.normcase(os.path.abspath(r)) for r in (r"E:\SAM",)]

def check_public_module(name):
    module = __import__(name)
    path = os.path.abspath(getattr(module, "__file__", "") or "")
    norm = os.path.normcase(path)
    if not norm.startswith(env_dir):
        raise RuntimeError(f"{name} resolved outside runtime env: {path}")
    for bad in bad_roots:
        if norm.startswith(bad):
            raise RuntimeError(f"{name} resolved to local source path: {path}")
    print(f"{name}: {path}")
    return module

import torch
import PySide6
import cv2
import fastapi
import uvicorn
import pycocotools
import psutil
from PySide6.QtWebEngineWidgets import QWebEngineView

print(f"torch.__version__={torch.__version__}")
print(f"torch.version.cuda={torch.version.cuda}")
arch_list = torch.cuda.get_arch_list()
print(f"torch.cuda.get_arch_list()={arch_list}")
if not torch.cuda.is_available():
    raise RuntimeError("torch.cuda.is_available() is False. Check NVIDIA driver and PyTorch CUDA wheel installation.")
device_name = torch.cuda.get_device_name(0)
device_cap = torch.cuda.get_device_capability(0)
print(f"torch.cuda.device_name={device_name}")
print(f"torch.cuda.device_capability={device_cap[0]}.{device_cap[1]}")
if expected_compute >= 12.0 and "sm_120" not in arch_list:
    raise RuntimeError(f"GPU compute capability {expected_compute} requires sm_120 support, but PyTorch arch list is {arch_list}")
torch.zeros(1, device="cuda")

check_public_module("segment_anything")
check_public_module("triton")
check_public_module("sam3")
check_public_module("psutil")
from sam3.model_builder import build_sam3_image_model
from sam3.model.sam3_image_processor import Sam3Processor
print(f"runtime ok, torch_flavor={torch_flavor}")
'@ | Set-Content -Path $verifyScript -Encoding UTF8
        try {
            Invoke-ExternalStep "Verifying public runtime imports and CUDA smoke test" $Py @($verifyScript, $EnvDir, ([string]$GpuInfo.compute_cap), $TorchConfig.torch_flavor) 15
        } finally {
            Remove-Item $verifyScript -Force -ErrorAction SilentlyContinue
        }

        Write-RuntimeState
        Write-Log "Runtime installation complete."
    } finally {
        Release-InstallLock
    }
} catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    Write-Host ""
    Write-Host "Runtime installation failed. Please check logs\runtime_install.log"
    exit 1
}

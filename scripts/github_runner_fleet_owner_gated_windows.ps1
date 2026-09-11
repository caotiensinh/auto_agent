param(
    [string]$Owner = "caotiensinh",
    [string]$Repo = "",
    [ValidateRange(1,64)][int]$Workers = 1,
    [switch]$IncludePublic,
    [switch]$NoReinstall,
    [string]$Root = "C:\actions-runners"
)
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
function Write-Info($m){Write-Host "[INFO] $m" -ForegroundColor Cyan}
function Write-Ok($m){Write-Host "[ OK ] $m" -ForegroundColor Green}
function Write-Warn($m){Write-Host "[WARN] $m" -ForegroundColor Yellow}
function Fail($m){Write-Host "[ERR ] $m" -ForegroundColor Red; exit 1}
$id=[Security.Principal.WindowsIdentity]::GetCurrent();$p=New-Object Security.Principal.WindowsPrincipal($id)
if(-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){Fail "Open PowerShell as Administrator and run again."}
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$SecurityRoot=Join-Path $env:ProgramData "GitHubRunnerSecurity";$HookRoot=Join-Path $SecurityRoot "hooks";$CacheRoot=Join-Path $Root ".cache"
$Labels="trusted,owner-gated,windows-pool";$ServiceAccount="NT AUTHORITY\NETWORK SERVICE"
Write-Host "";Write-Host "============================================================";Write-Host " GitHub Windows Self-Hosted Runner Pool Installer";Write-Host "============================================================"
Write-Host "Owner             : $Owner";Write-Host "Root              : $Root";Write-Host "Workers/repo      : $Workers";Write-Host "Runner account    : $ServiceAccount";Write-Host "Security gate     : Actor ID + repository binding";Write-Host ("Repository policy : "+$(if($IncludePublic){"private + PUBLIC"}else{"PRIVATE ONLY"}));Write-Host "============================================================";Write-Host ""
if($IncludePublic){Write-Warn "PUBLIC repositories are enabled.";$ack=Read-Host "Type I_ACCEPT_PUBLIC_RUNNER_RISK to continue";if($ack -ne "I_ACCEPT_PUBLIC_RUNNER_RISK"){Fail "Cancelled."}}
Write-Host "Paste a GitHub PAT with repository Administration write access.";$securePat=Read-Host "GitHub PAT" -AsSecureString;$ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePat);try{$Pat=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)};if([string]::IsNullOrWhiteSpace($Pat)){Fail "Empty token."}
$Headers=@{Accept="application/vnd.github+json";Authorization="Bearer $Pat";"X-GitHub-Api-Version"="2022-11-28"}
function Api([string]$Method,[string]$Uri){Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers}
try{$me=Api GET "https://api.github.com/user"}catch{Fail "GitHub authentication failed: $($_.Exception.Message)"}
$login=[string]$me.login;$ownerActorId=[string]$me.id;if($login -ne $Owner){Fail "Authenticated account '$login' does not match '$Owner'."};if($ownerActorId -notmatch '^\d+$'){Fail "Could not resolve GitHub numeric actor ID."};Write-Ok "Authenticated as $login (ID $ownerActorId)"
New-Item -ItemType Directory -Force -Path $Root,$CacheRoot,$SecurityRoot,$HookRoot|Out-Null
& icacls.exe $SecurityRoot /inheritance:r|Out-Null;& icacls.exe $SecurityRoot /grant:r "BUILTIN\Administrators:(OI)(CI)F" "NT AUTHORITY\SYSTEM:(OI)(CI)F" "NT AUTHORITY\NETWORK SERVICE:(OI)(CI)RX"|Out-Null
Write-Info "Resolving latest GitHub Actions runner release...";$release=Invoke-RestMethod -Uri "https://api.github.com/repos/actions/runner/releases/latest" -Headers @{Accept="application/vnd.github+json"};$version=([string]$release.tag_name).TrimStart('v');if(-not [Environment]::Is64BitOperatingSystem){Fail "32-bit Windows is not supported."};$asset="actions-runner-win-x64-$version.zip";$downloadUrl="https://github.com/actions/runner/releases/download/v$version/$asset";$archive=Join-Path $CacheRoot $asset
if(-not(Test-Path $archive)){Write-Info "Downloading runner v$version...";Invoke-WebRequest -Uri $downloadUrl -OutFile $archive -UseBasicParsing}else{Write-Ok "Using cached runner archive: $archive"}
function Get-Repos{$all=@();$page=1;while($true){$batch=@(Api GET "https://api.github.com/user/repos?per_page=100&page=$page&affiliation=owner&sort=full_name");if($batch.Count -eq 0){break};foreach($r in $batch){if([string]$r.owner.login -ne $Owner -or [bool]$r.archived){continue};if($Repo -and [string]$r.name -ne $Repo){continue};if(-not $IncludePublic -and -not [bool]$r.private){continue};$all+=$r};$page++};return $all}
$repos=@(Get-Repos);if($repos.Count -eq 0){Fail "No matching repositories found."};Write-Info "Selected repositories:";foreach($r in $repos){$vis=if($r.private){"private"}else{"public"};Write-Host ("  - {0,-42} {1}" -f $r.name,$vis)};$go=Read-Host "Proceed with installation/reinstallation? [y/N]";if($go.ToLowerInvariant() -ne 'y'){Fail "Cancelled."}
function RegToken([string]$R){[string](Api POST "https://api.github.com/repos/$Owner/$R/actions/runners/registration-token").token}
function RemoveToken([string]$R){try{return [string](Api POST "https://api.github.com/repos/$Owner/$R/actions/runners/remove-token").token}catch{return ""}}
function Make-Gate([string]$RunnerName,[string]$ExpectedRepo){$safe=$RunnerName -replace '[^A-Za-z0-9._-]','-';$hook=Join-Path $HookRoot "$safe.cmd";$c=@"
@echo off
setlocal EnableExtensions
if not "%GITHUB_ACTIONS%"=="true" goto deny_context
if not "%RUNNER_ENVIRONMENT%"=="self-hosted" goto deny_context
if not "%GITHUB_ACTOR_ID%"=="$ownerActorId" goto deny_actor
if not "%GITHUB_REPOSITORY%"=="$ExpectedRepo" goto deny_repo
if /I "%GITHUB_ACTOR%"=="dependabot[bot]" goto deny_bot
if /I "%GITHUB_ACTOR%"=="github-actions[bot]" goto deny_bot
if /I "%GITHUB_ACTOR%"=="renovate[bot]" goto deny_bot
echo [OWNER-GATE] ALLOW actor_id=%GITHUB_ACTOR_ID% repository=%GITHUB_REPOSITORY% event=%GITHUB_EVENT_NAME% runner=%RUNNER_NAME%
exit /b 0
:deny_actor
echo [OWNER-GATE] DENY unauthorized actor %GITHUB_ACTOR% ^(%GITHUB_ACTOR_ID%^) 1>&2
exit /b 97
:deny_repo
echo [OWNER-GATE] DENY unexpected repository %GITHUB_REPOSITORY% 1>&2
exit /b 97
:deny_bot
echo [OWNER-GATE] DENY bot actor %GITHUB_ACTOR% 1>&2
exit /b 97
:deny_context
echo [OWNER-GATE] DENY invalid GitHub Actions context 1>&2
exit /b 97
"@;Set-Content -LiteralPath $hook -Value $c -Encoding ASCII -Force;& icacls.exe $hook /inheritance:r|Out-Null;& icacls.exe $hook /grant:r "BUILTIN\Administrators:F" "NT AUTHORITY\SYSTEM:F" "NT AUTHORITY\NETWORK SERVICE:RX"|Out-Null;return $hook}
function Remove-Runner([string]$R,[string]$Dir){if(-not(Test-Path $Dir)){return};if(Test-Path (Join-Path $Dir '.runner')){if($NoReinstall){throw 'SKIP'};$sf=Join-Path $Dir '.service';if(Test-Path $sf){$sn=(Get-Content $sf -Raw).Trim();if($sn){Stop-Service -Name $sn -Force -ErrorAction SilentlyContinue}};$rt=RemoveToken $R;$cc=Join-Path $Dir 'config.cmd';if($rt -and(Test-Path $cc)){Push-Location $Dir;try{& .\config.cmd remove --token $rt|Out-Host}catch{}finally{Pop-Location}}};Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue}
$success=0;$failed=0;$skipped=0;$hostShort=$env:COMPUTERNAME
foreach($r in $repos){$repoName=[string]$r.name;$vis=if($r.private){'private'}else{'public'};for($i=1;$i -le $Workers;$i++){$wid='{0:D2}' -f $i;$runnerDir=Join-Path (Join-Path $Root $repoName) "worker-$wid";$runnerName="$hostShort-$repoName-w$wid" -replace '[^A-Za-z0-9._-]','-';if($runnerName.Length -gt 63){$runnerName=$runnerName.Substring(0,63)};Write-Host "";Write-Host "------------------------------------------------------------";Write-Info "Repository : $Owner/$repoName ($vis)";Write-Info "Worker     : $wid/$Workers";Write-Info "Runner name: $runnerName";Write-Info "Directory  : $runnerDir";try{Remove-Runner $repoName $runnerDir}catch{if($_.Exception.Message -eq 'SKIP'){Write-Warn "$repoName/worker-$wid skipped.";$skipped++;continue}else{throw}}
try{New-Item -ItemType Directory -Force -Path $runnerDir|Out-Null;Expand-Archive -LiteralPath $archive -DestinationPath $runnerDir -Force;if(-not(Test-Path (Join-Path $runnerDir 'config.cmd')) -or -not(Test-Path (Join-Path $runnerDir 'run.cmd'))){throw 'Runner archive extraction incomplete.'};$hook=Make-Gate $runnerName "$Owner/$repoName";Set-Content -LiteralPath (Join-Path $runnerDir '.env') -Encoding ASCII -Value "ACTIONS_RUNNER_HOOK_JOB_STARTED=$hook";$token=RegToken $repoName;if(-not $token){throw 'Empty registration token.'};Push-Location $runnerDir;try{Write-Info 'Configuring Windows service runner...';& .\config.cmd --unattended --url "https://github.com/$Owner/$repoName" --token $token --name $runnerName --work '_work' --labels $Labels --replace --runasservice --windowslogonaccount $ServiceAccount;if($LASTEXITCODE -ne 0){throw "config.cmd failed with exit code $LASTEXITCODE"}}finally{Pop-Location};$sf=Join-Path $runnerDir '.service';if(-not(Test-Path $sf)){throw 'Runner configured but .service was not created.'};$sn=(Get-Content $sf -Raw).Trim();if(-not $sn){throw 'Empty runner service name.'};& sc.exe failure $sn reset= 86400 actions= restart/5000/restart/15000/restart/60000|Out-Null;& sc.exe failureflag $sn 1|Out-Null;Start-Service -Name $sn -ErrorAction SilentlyContinue;Start-Sleep 2;$svc=Get-Service -Name $sn -ErrorAction Stop;if($svc.Status -ne 'Running'){throw "Windows service '$sn' is $($svc.Status), not Running."};Write-Ok "$repoName/worker-$wid ACTIVE ($sn)";$success++}catch{Write-Host "[ERR ] $repoName/worker-$wid : $($_.Exception.Message)" -ForegroundColor Red;$failed++}}}
Write-Host "";Write-Host "============================================================";Write-Host " RESULT";Write-Host "============================================================";Write-Host "Success : $success";Write-Host "Skipped : $skipped";Write-Host "Failed  : $failed";Write-Host "Workers : $Workers per selected repository";Write-Host "Root    : $Root";Write-Host "Version : $version";Write-Host "============================================================";Write-Host "";Write-Host 'Check services:';Write-Host '  Get-Service "actions.runner.*" | Format-Table Status,Name,DisplayName -Auto';Write-Host 'Workflow selector:';Write-Host '  runs-on: [self-hosted, Windows, X64]';Write-Host 'Strict selector:';Write-Host '  runs-on: [self-hosted, Windows, X64, trusted, owner-gated, windows-pool]';$Pat=$null;$securePat=$null;[GC]::Collect();if($failed -gt 0){exit 2};Write-Ok 'Windows runner pool installation completed.'

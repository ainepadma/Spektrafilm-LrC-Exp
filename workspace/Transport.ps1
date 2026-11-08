# File transport for the WPF workspace. This file is dot-sourced by Main.ps1.
$script:WorkspaceBus = $null
$script:WorkspaceUtf8 = [Text.UTF8Encoding]::new($false,$true)

function Write-WorkspaceFile([string]$Path, [byte[]]$Bytes) {
    $part = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllBytes($part,$Bytes)
        [IO.File]::Move($part,$Path)
    } finally {
        if ([IO.File]::Exists($part)) { [IO.File]::Delete($part) }
    }
}

function Test-WorkspacePacket([string]$Path) {
    [IO.File]::Exists($Path) -or [IO.Directory]::Exists([IO.Path]::Combine($Path,'complete'))
}

function Read-WorkspaceBytes([string]$Path) {
    if ([IO.File]::Exists($Path)) { return ,([IO.File]::ReadAllBytes($Path)) }
    if (-not [IO.Directory]::Exists([IO.Path]::Combine($Path,'complete'))) { throw 'Incomplete workspace packet.' }
    $chunks = [IO.Directory]::GetDirectories($Path)
    [Array]::Sort($chunks,[StringComparer]::Ordinal)
    $text = [Text.StringBuilder]::new()
    $next = 1
    foreach ($dir in $chunks) {
        $name = [IO.Path]::GetFileName($dir)
        if ($name -eq 'complete') { continue }
        if ($name -cnotmatch '^([0-9]{8})_([A-Za-z0-9_=-]{1,112})$' -or [int]$Matches[1] -ne $next) {
            throw 'Invalid workspace packet fragment.'
        }
        $null = $text.Append($Matches[2])
        $next = $text.Length + 1
    }
    return ,([Convert]::FromBase64String($text.ToString().Replace('-','+').Replace('_','/')))
}

function Read-WorkspaceJson([string]$Path) {
    $text = $script:WorkspaceUtf8.GetString((Read-WorkspaceBytes $Path))
    return ($text | ConvertFrom-Json -ErrorAction Stop)
}

function Remove-WorkspacePacket([string]$Path) {
    if ([IO.File]::Exists($Path)) { [IO.File]::Delete($Path) }
    elseif ([IO.Directory]::Exists($Path)) { [IO.Directory]::Delete($Path,$true) }
}

function Send-WorkspaceAction([string]$Action, $Payload) {
    $bus = $script:WorkspaceBus
    if (-not $bus -or $bus.Closing) { return }
    if ([string]::IsNullOrWhiteSpace($Action)) { throw 'Missing workspace action.' }
    if ($null -eq $Payload) { $Payload = @{} }
    $next = $bus.Sent + 1
    $record = @{id=$next; action=$Action; payload=$Payload} | ConvertTo-Json -Depth 64 -Compress -ErrorAction Stop
    $target = [IO.Path]::Combine($bus.Path,'events',('{0:D8}.json' -f $next))
    Write-WorkspaceFile $target ($script:WorkspaceUtf8.GetBytes($record))
    $bus.Sent = $next
    return $next
}

function Sync-WorkspaceAssets($Bus) {
    $folder = [IO.Path]::Combine($Bus.Path,'assets')
    foreach ($packet in [IO.Directory]::GetDirectories($folder,'*.payload')) {
        if (-not (Test-WorkspacePacket $packet)) { continue }
        $name = [IO.Path]::GetFileName($packet)
        if ($name -cnotmatch '^image-[0-9]{8}\.(png|jpeg|jpg)\.payload$') { throw 'Invalid staged image.' }
        $dest = $packet.Substring(0,$packet.Length-8)
        if (-not [IO.File]::Exists($dest)) { Write-WorkspaceFile $dest (Read-WorkspaceBytes $packet) }
        Remove-WorkspacePacket $packet
    }
}

function Invoke-WorkspaceTick {
    $bus = $script:WorkspaceBus
    if (-not $bus -or $bus.Closing -or $bus.InTick) { return }
    $bus.InTick = $true
    try {
        $beat = [IO.Path]::Combine($bus.Path,'heartbeat')
        if ((-not [IO.Directory]::Exists($bus.Path)) -or [IO.Directory]::Exists([IO.Path]::Combine($bus.Path,'stop')) -or
            ((-not $bus.NoWatchdog) -and ([DateTime]::UtcNow - [IO.Directory]::GetLastWriteTimeUtc($beat)).TotalSeconds -gt 90)) {
            $bus.Window.Close()
            return
        }
        $focus = [IO.Path]::Combine($bus.Path,'focus')
        if ([IO.Directory]::Exists($focus)) {
            [IO.Directory]::Delete($focus)
            if ($bus.Window.WindowState -eq 'Minimized') { $bus.Window.WindowState = 'Normal' }
            if (-not $bus.Window.Activate() -and -not $bus.Window.Topmost) {
                # The request came from the LrC menu. Raise an existing window
                # when Windows declines foreground activation across processes.
                $bus.Window.Topmost=$true
                $bus.Window.Topmost=$false
                $null=$bus.Window.Activate()
            }
            $null = $bus.Window.Focus()
        }
        # Keep the UI on the latest complete snapshot. Images are published
        # before their state packet, including on Unicode project paths.
        $latest = $bus.State
        do {
            $path = [IO.Path]::Combine($bus.Path,'state',('{0:D8}.json' -f ($latest+1)))
            if (-not (Test-WorkspacePacket $path)) { break }
            $latest++
        } while ($true)
        if ($latest -gt $bus.State) {
            Sync-WorkspaceAssets $bus
            $path = [IO.Path]::Combine($bus.Path,'state',('{0:D8}.json' -f $latest))
            $first = $bus.State+1
            $bus.State = $latest
            try {
                $state = Read-WorkspaceJson $path
                $null = & $bus.OnState $state
            } finally {
                for ($i=$first;$i -le $latest;$i++) {
                    Remove-WorkspacePacket ([IO.Path]::Combine($bus.Path,'state',('{0:D8}.json' -f $i)))
                }
            }
        }
        while ($bus.Received -lt $bus.Sent) {
            $next = $bus.Received+1
            $path = [IO.Path]::Combine($bus.Path,'replies',('{0:D8}.json' -f $next))
            if (-not (Test-WorkspacePacket $path)) { break }
            $bus.Received=$next
            try {
                $reply = Read-WorkspaceJson $path
                if ([int64]$reply.id -ne $next) { throw 'Unexpected workspace reply ID.' }
                if ($bus.OnReply) { $null = & $bus.OnReply $reply }
            }
            finally { Remove-WorkspacePacket $path }
        }
    } catch {
        $message=$_.Exception.Message
        [Console]::Error.WriteLine("Workspace: "+$message)
        if ($bus.OnReply) {
            try { $null = & $bus.OnReply ([pscustomobject]@{id=0;ok=$false;error=$message}) }
            catch { [Console]::Error.WriteLine($_.Exception.Message) }
        }
    } finally {
        $bus.InTick=$false
    }
}

function Initialize-WorkspaceTransport {
    param([string]$Session,$Window,[scriptblock]$OnState,[scriptblock]$OnReply,[switch]$NoWatchdog)
    $parent=[IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot,'..','.runtime','workspaces'))
    $path=[IO.Path]::GetFullPath($Session)
    if (([IO.Path]::GetDirectoryName($path) -ne $parent) -or (-not [IO.Directory]::Exists($path))) {
        throw 'The workspace transport requires a fresh project session directory.'
    }
    $hash=[Security.Cryptography.SHA256]::Create()
    try { $key=[BitConverter]::ToString($hash.ComputeHash($script:WorkspaceUtf8.GetBytes($parent.ToUpperInvariant()))).Replace('-','') }
    finally { $hash.Dispose() }
    $created=$false
    $mutex=[Threading.Mutex]::new($true,("Local\Spektrafilm-Workspace-"+$key),[ref]$created)
    $owner=[IO.Path]::Combine($parent,'active-session.txt')
    if (-not $created) {
        try {
            for ($i=0;$i -lt 20;$i++) {
                if ([IO.File]::Exists($owner)) {
                    $active=[IO.File]::ReadAllText($owner)
                    if ([IO.Path]::GetDirectoryName($active) -eq $parent -and [IO.Directory]::Exists($active)) {
                        $null=[IO.Directory]::CreateDirectory([IO.Path]::Combine($active,'focus'))
                        break
                    }
                }
                [Threading.Thread]::Sleep(50)
            }
            $null=[IO.Directory]::CreateDirectory([IO.Path]::Combine($path,'redirected'))
        } finally { $mutex.Dispose() }
        throw 'An existing workspace owns this project. Focus was requested.'
    }
    try {
        [IO.File]::WriteAllText($owner,$path,$script:WorkspaceUtf8)
        $timer=[Windows.Threading.DispatcherTimer]::new()
        $timer.Interval=[TimeSpan]::FromMilliseconds(60)
        $script:WorkspaceBus=[pscustomobject]@{Path=$path;Window=$Window;OnState=$OnState;OnReply=$OnReply;
            Received=[long]0;Sent=[long]0;State=[long]0;Timer=$timer;Mutex=$mutex;OwnerFile=$owner;
            Closing=$false;InTick=$false;NoWatchdog=$NoWatchdog.IsPresent}
        $timer.Add_Tick({ Invoke-WorkspaceTick })
        $Window.Add_Closed({
            $b=$script:WorkspaceBus
            if (-not $b -or $b.Closing) { return }
            $b.Closing=$true
            try {
                $b.Timer.Stop()
                if ([IO.Directory]::Exists($b.Path)) { $null=[IO.Directory]::CreateDirectory([IO.Path]::Combine($b.Path,'closed')) }
                if ([IO.File]::Exists($b.OwnerFile) -and [IO.File]::ReadAllText($b.OwnerFile) -ceq $b.Path) {
                    [IO.File]::Delete($b.OwnerFile)
                }
            } finally {
                $b.Mutex.ReleaseMutex(); $b.Mutex.Dispose()
                $script:WorkspaceBus=$null
            }
        })
        $null=[IO.Directory]::CreateDirectory([IO.Path]::Combine($path,'ready'))
        $timer.Start()
    } catch {
        $script:WorkspaceBus=$null
        $mutex.ReleaseMutex(); $mutex.Dispose()
        throw
    }
}

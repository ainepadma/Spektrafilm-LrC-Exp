[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Session,
    [string]$SnapshotPath,
    [string]$SnapshotState
)
$ErrorActionPreference='Stop'
if ([IO.Directory]::Exists($Session)) {
    $env:TEMP=[IO.Path]::GetFullPath($Session); $env:TMP=$env:TEMP
}
# Establish a per-monitor DPI context on THIS UI thread before creating WPF
# handles. Older Windows builds can still use the scale reported by WPF.
[AppContext]::SetSwitch('Switch.System.Windows.DoNotScaleForDpiChanges',$false)
try {
    Add-Type -Namespace SpektrafilmUI -Name Display -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr SetThreadDpiAwarenessContext(System.IntPtr context);'
    $null=[SpektrafilmUI.Display]::SetThreadDpiAwarenessContext([IntPtr]::new(-4))
} catch { [Diagnostics.Debug]::WriteLine($_.Exception.Message) }
Add-Type -AssemblyName PresentationCore,PresentationFramework,WindowsBase
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') { throw 'The workspace requires an STA process.' }
. (Join-Path $PSScriptRoot 'Fields.ps1')
. (Join-Path $PSScriptRoot 'OutputControls.ps1')
. (Join-Path $PSScriptRoot 'RecipeControls.ps1')
$script:QaMode = ![string]::IsNullOrEmpty($SnapshotPath)
$script:Fields = New-Object Collections.ArrayList
$script:Listeners = New-Object Collections.ArrayList
$script:Controls=@{}; $script:Optimistic=@{}; $script:RangeQueue=@{}; $script:ImageCache=@{}
$script:State=$null; $script:Applying=$true; $script:Category='all'; $script:DisplayedPhoto=''
$script:Inspect=@{enabled=$false;mode='after';zoom='fit';divider=50;x=50;y=50}
$script:ShowChart=$false; $script:ImagePath=''; $script:ChartPath=''; $script:StripSignature=''
$script:LastViewport=''; $script:PendingInspect=0
$script:NoticeUntil=[datetime]::MinValue
$app = [Windows.Application]::Current
if (!$app) { $app=New-Object Windows.Application }
$app.ShutdownMode='OnExplicitShutdown'
function Load-Xaml([string]$Name) {
    $file=Join-Path $PSScriptRoot $Name
    return [Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText($file,[Text.Encoding]::UTF8))
}
$app.Resources.MergedDictionaries.Add((Load-Xaml 'Theme.xaml'))
$script:Window=Load-Xaml 'Main.xaml'
$names='TitleBar','Minimize','Maximize','Close','Rail','RailScroll','FileName','Position','Stage','Empty','Preview',
       'Previous','Next','Fit','Loupe','Before','After','Split','Histogram','Refresh','Divider','DividerRow','RoiX','RoiY','RoiRow',
       'Chart','HistogramPanel','Filmstrip','BackPage','NextPage','Queue','Export','Stop','Status',
       'Pin','ReferenceLayer','ReferenceImage','ReferenceLine','CompareTools','ComparePosition'
foreach ($name in $names) { $script:Controls[$name]=$script:Window.FindName($name) }
$controls=$script:Controls
$controls.Stage.Focusable=$true
$area=[Windows.SystemParameters]::WorkArea
$script:Window.Width=[Math]::Min(1400,[Math]::Floor($area.Width*.92))
$script:Window.Height=[Math]::Min(920,[Math]::Floor($area.Height*.91))
$script:Window.MinWidth=[Math]::Min(770,$script:Window.Width)
$script:Window.MinHeight=[Math]::Min(505,$script:Window.Height)
if ($script:Window.Width -lt 980) { $script:Window.FindName('RailWidth').Width=[Windows.GridLength]::new(275) }

function Add-StateListener([scriptblock]$Listener) { [void]$script:Listeners.Add($Listener) }
function New-UiTimer([int]$Milliseconds,[scriptblock]$Action) {
    $timer=New-Object Windows.Threading.DispatcherTimer
    $timer.Interval=[TimeSpan]::FromMilliseconds($Milliseconds)
    $timer.Add_Tick($Action)
    return $timer
}
function Show-Notice([string]$Message) {
    $script:Controls.Status.Text=$Message
    $script:NoticeUntil=[datetime]::UtcNow.AddSeconds(4)
}
function Set-ChoiceListIfChanged($Box,$Items) {
    $Items=@($Items | Where-Object { $null -ne $_ })
    $same=$Box.Items.Count -eq $Items.Count
    if ($same) {
        for ($i=0;$i -lt $Items.Count;$i++) {
            if ([string]$Box.Items[$i].Tag -cne [string]$Items[$i].value -or
                [string]$Box.Items[$i].Content -cne [string]$Items[$i].title) { $same=$false;break }
        }
    }
    if (!$same) { Set-Choices $Box $Items }
}
function Get-DpiScale {
    try { $dpi=[Windows.Media.VisualTreeHelper]::GetDpi($script:Controls.Stage); return [double]$dpi.DpiScaleX }
    catch { return 1.0 }
}
function Get-Viewport {
    $stage=$script:Controls.Stage
    $dpi=Get-DpiScale
    return @{
        width=[int][Math]::Max(1,[Math]::Round(($stage.ActualWidth-$stage.Padding.Left-$stage.Padding.Right)*$dpi));
        height=[int][Math]::Max(1,[Math]::Round(($stage.ActualHeight-$stage.Padding.Top-$stage.Padding.Bottom)*$dpi))
    }
}
function Size-Preview {
    $view=$script:Controls.Preview
    if (!$view.Source) { return }
    $viewport=Get-Viewport
    $w=$view.Source.PixelWidth; $h=$view.Source.PixelHeight
    $scale=if ($script:Inspect.enabled -and $script:Inspect.zoom -eq 'roi') { 1.0 } else {
        $fit=[math]::Min($viewport.width/$w,$viewport.height/$h)
        if ($script:State.draft) { $fit } else { [math]::Min(1.0,$fit) }
    }
    $dpi=Get-DpiScale
    $view.Width=$w*$scale/$dpi;$view.Height=$h*$scale/$dpi
}
function Read-PreviewImage([string]$Path) {
    if (!$Path) { return $null }
    if ($script:ImageCache.ContainsKey($Path)) { return $script:ImageCache[$Path] }
    try {
        $stream=[IO.File]::Open($Path,'Open','Read',[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        try {
            $bitmap=New-Object Windows.Media.Imaging.BitmapImage
            $bitmap.BeginInit(); $bitmap.CacheOption='OnLoad'; $bitmap.StreamSource=$stream; $bitmap.EndInit(); $bitmap.Freeze()
        } finally { $stream.Dispose() }
        # The stage itself retains the current full-resolution bitmap. Cache
        # only small strip/chart bitmaps, not a sequence of previous previews.
        if ([long]$bitmap.PixelWidth * $bitmap.PixelHeight -le 65536) {
            if ($script:ImageCache.Count -ge 48) { $script:ImageCache.Clear() }
            $script:ImageCache[$Path]=$bitmap
        }
        return $bitmap
    } catch { return $null }
}
function Clear-Reference {
    $script:ReferencePhoto=$null
    $controls.ReferenceImage.Source=$null
    $controls.Pin.Content='固定为 A'
    $controls.Pin.IsEnabled=([bool]$script:State.canPin -and !$script:Inspect.enabled -and [bool]$controls.Preview.Source)
    foreach ($element in @($controls.ReferenceLayer,$controls.ReferenceLine,$controls.CompareTools)) {
        $element.Visibility='Collapsed'
    }
}
function Size-Reference {
    $image=$controls.ReferenceImage
    if (!$image.Source) { return }
    $stage=$controls.Stage
    $w=[math]::Max(0,$stage.ActualWidth-$stage.Padding.Left-$stage.Padding.Right)
    $h=[math]::Max(0,$stage.ActualHeight-$stage.Padding.Top-$stage.Padding.Bottom)
    $dpi=Get-DpiScale
    $scale=[math]::Min(1/$dpi,[math]::Min($w/$image.Source.PixelWidth,$h/$image.Source.PixelHeight))
    $image.Width=$image.Source.PixelWidth*$scale
    $image.Height=$image.Source.PixelHeight*$scale
    $x=$w*$controls.ComparePosition.Value/100
    $controls.ReferenceLayer.Clip=[Windows.Media.RectangleGeometry]::new([Windows.Rect]::new(0,0,$x,$h))
    $controls.ReferenceLine.Margin=[Windows.Thickness]::new($x,0,0,0)
}
function Set-StageImage($State) {
    if ($script:ReferencePhoto -and ($script:ReferencePhoto -ne $State.photoId -or
        $script:ReferencePartner -ne $State.partnerId -or $State.inspection.enabled)) { Clear-Reference }
    $path=[string](Read-Member $State 'preview' '')
    if ($path -cne $script:ImagePath -or (!$script:Controls.Preview.Source -and $path)) {
        $bitmap=Read-PreviewImage $path
        $script:ImagePath=$path
        $script:Controls.Preview.Source=$bitmap
    }
    if ($script:Controls.Preview.Source) { $script:Controls.Empty.Visibility='Collapsed';Size-Preview }
    else {
        $script:Controls.Empty.Text=$(if ($State.photoId) {'正在生成预览…'}else{'在 Lightroom Classic 中选择照片'})
        $script:Controls.Empty.Visibility='Visible'
    }
    $controls.Pin.IsEnabled=([bool]$script:ReferencePhoto -or ($State.canPin -and $controls.Preview.Source -and !$script:Inspect.enabled))
    Size-Reference
    $chart=[string](Read-Member $State histogram '')
    if ($chart -cne $script:ChartPath -or (!$script:Controls.Chart.Source -and $chart)) {
        $script:ChartPath=$chart;$script:Controls.Chart.Source=Read-PreviewImage $chart
    }
}
function Update-Filmstrip($State) {
    $list=Get-Items $State 'thumbs'
    $signature=($list | ForEach-Object { "$($_.index)|$($_.label)|$($_.path)|$($_.selected)" }) -join "`n"
    if ($signature -ceq $script:StripSignature) {return}
    $script:StripSignature=$signature
    $strip=$script:Controls.Filmstrip
    $strip.Children.Clear()
    foreach ($item in $list) {
        $b=New-Object Windows.Controls.Button;$b.Width=85;$b.Padding='2';$b.Margin='2,0';$b.Tag=[int]$item.index
        $b.Background='#25272A'
        if ($item.selected) { $b.BorderBrush='#9DC0F3';$b.BorderThickness='2' } else { $b.BorderBrush='#383B40' }
        $stack=New-Object Windows.Controls.StackPanel
        $img=New-Object Windows.Controls.Image;$img.Height=43;$img.Stretch='Uniform'
        $img.Source=Read-PreviewImage ([string]$item.path)
        [void]$stack.Children.Add($img)
        $caption=New-Object Windows.Controls.TextBlock;$caption.FontSize=10;$caption.TextAlignment='Center'
        $caption.TextTrimming='CharacterEllipsis'
        $caption.Text=if ($item.label) {[string]$item.label} else {[string]$item.index}
        [Windows.Automation.AutomationProperties]::SetName($b,$caption.Text)
        [void]$stack.Children.Add($caption);$b.Content=$stack
        $b.Add_Click({param($button,$e)Flush-Ranges;[void](Send-UiAction navigate @{index=[int]$button.Tag})})
        [void]$strip.Children.Add($b)
    }
}
function Paint-Inspection {
    $i=$script:Inspect
    $controls=$script:Controls
    $controls.DividerRow.Visibility=$(if($i.enabled -and $i.mode -eq 'split'){'Visible'}else{'Collapsed'})
    $controls.RoiRow.Visibility=$(if($i.enabled -and $i.zoom -eq 'roi'){'Visible'}else{'Collapsed'})
    $controls.HistogramPanel.Visibility=$(if($script:ShowChart){'Visible'}else{'Collapsed'})
    foreach($pair in @(,@('Fit',($i.zoom -eq 'fit'));,@('Loupe',($i.zoom -eq 'roi'));
                          ,@('After',($i.mode -eq 'after'));,@('Before',($i.mode -eq 'before'));
                          ,@('Split',($i.mode -eq 'split'));,@('Histogram',$script:ShowChart))) {
        $controls[$pair[0]].BorderBrush=$(if($pair[1]){'#98ABC4'}else{'#52555B'})
    }
    Size-Preview
}
function Send-Inspection {
    $script:InspectTimer.Stop()
    $i=$script:Inspect
    $i.enabled=($i.mode -ne 'after' -or $i.zoom -ne 'fit' -or $script:ShowChart)
    if ($i.enabled -and $script:ReferencePhoto) { Clear-Reference }
    $i.divider=[int]$script:Controls.Divider.Value
    $i.x=[int]$script:Controls.RoiX.Value; $i.y=[int]$script:Controls.RoiY.Value
    Paint-Inspection
    if (!$script:State.photoId) { return }
    $script:PendingInspect = [long](Send-UiAction inspect ($i.Clone()))
}
function Set-InspectChoice([string]$Key,[string]$Value) {
    $script:Inspect[$Key]=$Value
    Send-Inspection
}
function Paint-Fields($State) {
    $busy=([string]$State.busy -eq 'export');$hasPhoto=[bool]$State.photoId
    foreach ($f in $script:Fields) {
        if ($f.group -eq 'local') { continue }
        $value=Get-FieldValue $State $f.group $f.key $f.default
        $enabled=!$busy -and ($hasPhoto -or $f.group -eq 'export')
        $direct=[bool](Read-Member $State 'directScan' $false)
        if ($f.key -in @('instantFrame','instantPosition','paperCaption','captionFont')) {
            $enabled=$enabled -and (Get-FieldValue $State printing paperLayout 'even') -eq 'instant'
            if ($f.key -eq 'instantPosition') { $enabled=$enabled -and (Get-FieldValue $State printing instantFrame 'original') -eq 'square' }
            if ($f.key -in @('paperCaption','captionFont')) {
                $border=Get-FieldValue $State printing paperBorder 'auto'
                $enabled=$enabled -and $border -ne 'none' -and !($direct -and $border -eq 'auto') -and (Get-FieldValue $State printing paperMargin .035) -gt 0
            }
        }
        if ($f.key -like 'watermark*') {
            $wm=Get-FieldValue $State printing watermark 'off'
            $enabled=$enabled -and (Get-FieldValue $State export format 'jpg') -ne 'di'
            if ($f.key -in @('watermarkText','watermarkFont','watermarkColor')) { $enabled=$enabled -and $wm -eq 'text' }
            elseif ($f.key -eq 'watermarkPng') { $enabled=$enabled -and $wm -eq 'png' }
            elseif ($f.key -ne 'watermark') { $enabled=$enabled -and $wm -ne 'off' }
        }
        if ($f.key -in @('paperMargin','paperColor')) {
            $border=Get-FieldValue $State printing paperBorder 'auto'
            if ($f.key -eq 'paperColor' -and $border -ne 'custom') {$enabled=$false}
            if ($f.key -eq 'paperMargin' -and ($border -eq 'none' -or ($border -eq 'auto' -and $direct))) {$enabled=$false}
        }
        if ($f.key -in @('print_ev','yellow','magenta','preflash','glare','glare_on','paper') -and $direct) {$enabled=$false}
        if ($f.key -in @('grain','grain_on','halation','halation_on','scatter','boost','glare','glare_on','antihalation') -and $State.recipe.mode -eq 'fast-color') {$enabled=$false}
        if ($f.key -eq 'paper') {$enabled = $enabled -and [bool](Read-Member $State 'canPaper' $true)}
        if ($f.key -eq 'scan') {
            $enabled = $enabled -and [bool](Read-Member $State 'canScan' $true)
            if ([bool](Read-Member $State 'forcedScan' $false)) { $value=$true }
        }
        $f.control.IsEnabled=$enabled
        switch($f.type) {
            choice { Select-Value $f.control $value }
            check { $f.control.IsChecked=[bool]$value }
            text { if (!$f.control.IsKeyboardFocusWithin) { $f.control.Text=[string]$value } }
            range {
                $f.number.IsEnabled=$enabled
                if (!$f.control.IsMouseCaptureWithin -and !$script:RangeQueue.ContainsKey("$($f.group)/$($f.key)") -and !$f.number.IsKeyboardFocusWithin) {
                    $number=[Math]::Max([double]$f.min,[Math]::Min([double]$f.max,([double]$value*$f.scale)))
                    $f.control.Value=$number
                    $f.number.Text=([Math]::Round($number,4)).ToString([CultureInfo]::InvariantCulture)
                }
            }
        }
    }
}
function Apply-WorkspaceState($State) {
    if ($null -eq $State) {return}
    $script:State=$State
    $script:Applying=$true
    try {
        foreach ($key in @($script:Optimistic.Keys)) {
            if ($script:Optimistic[$key].acknowledged -or
                !$key.StartsWith(([string]$State.photoId+'/'),[StringComparison]::Ordinal)) { $script:Optimistic.Remove($key) }
        }
        Update-StockChoices $State
        Paint-Fields $State
        $c=$script:Controls
        $c.FileName.Text=[string](Read-Member $State 'fileName' '照片预览')
        $c.Position.Text=(@($State.position,$State.selection) | Where-Object {$_}) -join '   ·   '
        $busy=([string]$State.busy -eq 'export')
        $c.Previous.IsEnabled=[bool](Read-Member $State canPrevious (([int]$State.index -gt 1) -and !$busy))
        $c.Next.IsEnabled=[bool](Read-Member $State canNext (([int]$State.index -lt [int]$State.total) -and !$busy))
        $c.BackPage.IsEnabled=[bool](Read-Member $State canBackPage (!$busy -and [int]$State.total -gt 1))
        $c.NextPage.IsEnabled=[bool](Read-Member $State canNextPage (!$busy -and [int]$State.total -gt 1))
        foreach ($name in @('Refresh','Fit','Loupe','After','Before','Split','Histogram')) { $c[$name].IsEnabled=[bool]$State.photoId -and !$busy }
        $c.Export.Content=[string](Read-Member $State exportTitle '导出当前照片')
        $c.Export.IsEnabled=[bool](Read-Member $State canExport ([bool]$State.photoId -and !$busy))
        $c.Stop.IsEnabled=[bool](Read-Member $State canStop $busy)
        if ([datetime]::UtcNow -gt $script:NoticeUntil) { $c.Status.Text=[string]$State.status }
        if ($State.inspection -and !$script:PendingInspect) {
            foreach($key in @('enabled','mode','zoom','divider','x','y')) { $script:Inspect[$key]=Read-Member $State.inspection $key $script:Inspect[$key] }
            $c.Divider.Value=[double]$script:Inspect.divider;$c.RoiX.Value=[double]$script:Inspect.x;$c.RoiY.Value=[double]$script:Inspect.y
        }
        Paint-Inspection
        Set-StageImage $State
        Update-Filmstrip $State
        $script:ResultsText.Text=if ($State.results) { @($State.results) -join "`n" } else {'尚无记录。'}
        $items=@((Get-Items $State 'presets') | ForEach-Object {[pscustomobject]@{title=[string]$_;value=[string]$_}})
        Set-ChoiceListIfChanged $script:PresetBox $items
        $filmItems=@((Get-Items $State 'filmPresets') | ForEach-Object {[pscustomobject]@{title=[string]$_;value=[string]$_}})
        Set-ChoiceListIfChanged $script:FilmPresetBox $filmItems
        $script:DisplayedPhoto=[string]$State.photoId
        foreach ($listener in $script:Listeners) { & $listener $State }
    } finally { $script:Applying=$false }
}
function On-WorkspaceReply($Reply) {
    if ([long]$Reply.id -eq $script:PendingInspect) { $script:PendingInspect=0 }
    foreach ($key in @($script:Optimistic.Keys)) {
        if ($script:Optimistic[$key].sequence -eq $Reply.id) {
            if ($Reply.ok) { $script:Optimistic[$key].acknowledged=$true } else {$script:Optimistic.Remove($key)}
        }
    }
    if (!$Reply.ok) { Show-Notice ([string]$Reply.error) }
}

$script:RangeTimer=New-UiTimer 150 {
    if (([datetime]::UtcNow-$script:LastRangeChange).TotalMilliseconds -ge 150) { Flush-Ranges }
    elseif ($script:State.busy -ne 'preview' -and !$script:Inspect.enabled) { Flush-Ranges $true }
}
$script:InspectTimer=New-UiTimer 140 {Send-Inspection}
$script:ViewportTimer=New-UiTimer 160 {
    $script:ViewportTimer.Stop()
    $size=Get-Viewport
    $signature="$($size.width)x$($size.height)"
    if ($signature -ne $script:LastViewport -and $size.width -gt 10 -and $size.height -gt 10) {
        $script:LastViewport=$signature
        [void](Send-UiAction viewport $size)
    }
}
Add-StockSection $controls.Rail
Add-FilmPresetSection $controls.Rail
$script:FontChoices=@(Get-FontChoices)
Add-PaperSection $controls.Rail
Add-WatermarkSection $controls.Rail
Initialize-RecipeControls $controls.Rail
Add-OutputSections $controls.Rail
$script:Applying=$false
$controls.TitleBar.Add_MouseLeftButtonDown({param($source,$e)
    if ($e.OriginalSource -is [Windows.Controls.Button]) {return}
    if ($e.ClickCount -eq 2) {
        $script:Window.WindowState=if ($script:Window.WindowState -eq 'Maximized'){'Normal'}else{'Maximized'}
    } elseif ($e.LeftButton -eq 'Pressed') { $script:Window.DragMove() }
})
$controls.Minimize.Add_Click({$script:Window.WindowState='Minimized'})
$controls.Maximize.Add_Click({$script:Window.WindowState=if ($script:Window.WindowState -eq 'Maximized'){'Normal'}else{'Maximized'}})
$controls.Close.Add_Click({$script:Window.Close()})
$controls.Previous.Add_Click({ Flush-Ranges; [void](Send-UiAction navigate @{delta=-1}) })
$controls.Next.Add_Click({ Flush-Ranges; [void](Send-UiAction navigate @{delta=1}) })
$controls.BackPage.Add_Click({ [void](Send-UiAction thumbPage @{delta=-1}) })
$controls.NextPage.Add_Click({ [void](Send-UiAction thumbPage @{delta=1}) })
$controls.Refresh.Add_Click({ Flush-Ranges; [void](Send-UiAction refresh) })
$controls.Export.Add_Click({ Flush-Ranges; [void](Send-UiAction export) })
$controls.Stop.Add_Click({ [void](Send-UiAction stop) })
$controls.Queue.Add_Click({ $script:ResultsBody.Parent.IsExpanded=$true; $script:ResultsBody.BringIntoView() })
$controls.After.Add_Click({
    if ($script:ReferencePhoto) { Clear-Reference }
    $script:ShowChart=$false; $script:Inspect.mode='after'; $script:Inspect.zoom='fit'
    Send-Inspection
})
$controls.Before.Add_Click({Set-InspectChoice mode before})
$controls.Split.Add_Click({Set-InspectChoice mode split})
$controls.Fit.Add_Click({Set-InspectChoice zoom fit})
$controls.Loupe.Add_Click({Set-InspectChoice zoom roi})
$controls.Histogram.Add_Click({$script:ShowChart=!$script:ShowChart;Send-Inspection})
foreach ($name in @('Divider','RoiX','RoiY')) {
    $controls[$name].Add_ValueChanged({if (!$script:Applying) {$script:InspectTimer.Stop();$script:InspectTimer.Start()}})
}
$controls.Stage.Add_SizeChanged({Size-Preview;$script:ViewportTimer.Stop();$script:ViewportTimer.Start()})
$controls.ReferenceLayer.Add_SizeChanged({Size-Reference})
$controls.ComparePosition.Add_ValueChanged({Size-Reference})
$controls.Pin.Add_Click({
    if ($script:ReferencePhoto) { Clear-Reference;return }
    if (!$script:State.canPin -or $script:Inspect.enabled -or !$controls.Preview.Source) { return }
    $script:ReferencePhoto=$script:State.photoId
    $script:ReferencePartner=$script:State.partnerId
    $controls.ReferenceImage.Source=$controls.Preview.Source
    $controls.Pin.Content='结束 A/B'
    $controls.ComparePosition.Value=50
    foreach ($element in @($controls.ReferenceLayer,$controls.ReferenceLine,$controls.CompareTools)) {
        $element.Visibility='Visible'
    }
    Size-Reference
})
$script:Window.Add_LocationChanged({$script:ViewportTimer.Stop();$script:ViewportTimer.Start()})
if ($script:Window.PSObject.Methods['add_DpiChanged']) {
    $script:Window.Add_DpiChanged({Size-Preview;Size-Reference;$script:ViewportTimer.Stop();$script:ViewportTimer.Start()})
}
$script:Window.Add_Closing({ Flush-Ranges })
$script:Window.Add_PreviewKeyDown({param($source,$e)
    $focus=[Windows.Input.Keyboard]::FocusedElement
    if ($focus -is [Windows.Controls.TextBox] -or $focus -is [Windows.Controls.ComboBox] -or $focus -is [Windows.Controls.Primitives.RangeBase]) { return }
    if ($e.Key -eq 'Left' -and $script:Controls.Previous.IsEnabled) {[void](Send-UiAction navigate @{delta=-1});$e.Handled=$true}
    if ($e.Key -eq 'Right' -and $script:Controls.Next.IsEnabled) {[void](Send-UiAction navigate @{delta=1});$e.Handled=$true}
    if ($e.Key -eq 'F5' -and $script:Controls.Refresh.IsEnabled) {[void](Send-UiAction refresh);$e.Handled=$true}
})
if ($script:QaMode) {
    if (!$SnapshotState) { throw 'SnapshotState is required for offscreen rendering.' }
    $state=ConvertFrom-Json ([IO.File]::ReadAllText($SnapshotState,[Text.Encoding]::UTF8))
    $root=$script:Window.Content
    $script:Window.Content=$null
    $size=[Windows.Size]::new(1220,780)
    $root.Measure($size);$root.Arrange([Windows.Rect]::new($size));$root.UpdateLayout()
    Apply-WorkspaceState $state
    $root.Measure($size);$root.Arrange([Windows.Rect]::new($size));$root.UpdateLayout()
    Size-Preview
    $root.UpdateLayout()
    $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new(1220,780,96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($root)
    $encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream=[IO.File]::Create($SnapshotPath)
    try {$encoder.Save($stream)} finally {$stream.Dispose()}
} else {
    . (Join-Path $PSScriptRoot 'Transport.ps1')
    Initialize-WorkspaceTransport $Session $script:Window {param($state) Apply-WorkspaceState $state} {param($reply) On-WorkspaceReply $reply}
    $app.MainWindow=$script:Window
    $app.ShutdownMode='OnMainWindowClose'
    [void]$app.Run($script:Window)
}

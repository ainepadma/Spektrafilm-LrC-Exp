$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$testFolder = Join-Path $project ('.runtime/sidebar-test-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testFolder)
$testStatePath = Join-Path $testFolder 'state.json'
$testSnapshot = Join-Path $testFolder 'window.png'
try {
    $fixture = @{
        photoId='42'; fileName='test.tif'; index=1; total=1; canEdit=$true; canExport=$true
        filmItems=@(@{value='stock';title='Film';channel='color';type='negative'})
        paperItems=@(@{value='paper';title='Paper';channel='color'})
        recipe=@{film='stock';paper='paper';mode='full';options=@{};printing=@{paperMargin=.035;paperBorder='warm'}}
        export=@{}; inspection=@{enabled=$false;zoom='fit';mode='after';divider=50;x=50;y=50}
    }
    [IO.File]::WriteAllText($testStatePath,($fixture | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    . (Join-Path $project 'workspace/Main.ps1') -Session $testFolder -SnapshotState $testStatePath -SnapshotPath $testSnapshot
    # WPF coerces IsDropDownOpen to false until the control is loaded.
    $parameters=[Windows.Interop.HwndSourceParameters]::new('Spektrafilm sidebar test')
    $parameters.WindowStyle=-2147483648
    $parameters.SetPosition(-30000,-30000)
    $parameters.SetSize(1220,780)
    $testSource=[Windows.Interop.HwndSource]::new($parameters)
    $testSource.RootVisual=$root
    $dispatcher=[Windows.Threading.Dispatcher]::CurrentDispatcher
    $dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Loaded)
    $script:QaMode=$false
    $script:Actions=[Collections.ArrayList]::new()
    function Send-WorkspaceAction($kind,$payload) {
        [void]$script:Actions.Add(@{kind=$kind;payload=$payload.Clone()})
        return $script:Actions.Count
    }
    function Click-Control($button) {
        $button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    }
    $borderField=$script:Fields | Where-Object key -eq 'paperBorder'
    $box=$borderField.control
    $box.ApplyTemplate() | Out-Null
    $box.IsDropDownOpen=$true
    $root.UpdateLayout()
    $choices=$box.Template.FindName('Choices',$box)
    if (!$choices -or $choices.Visibility -ne 'Visible' -or !$controls.Rail.IsAncestorOf($choices)) {
        throw 'Paper options did not expand inside the existing sidebar.'
    }
    Select-Value $box 'black'
    if ($script:Actions[-1].payload.value -ne 'black' -or $script:Actions[-1].payload.photoId -ne '42') {
        throw 'Paper selection did not target the displayed photo.'
    }
    $box.IsDropDownOpen=$false
    $marginField=$script:Fields | Where-Object key -eq 'paperMargin'
    if ([Math]::Abs($marginField.control.Value-3.5) -gt .000001) { throw 'Paper fraction did not appear as a percentage.' }
    $marginField.control.Value=7.5; Flush-Ranges
    if ($script:Actions[-1].payload.value -ne .075) { throw 'Paper percentage did not round trip to the renderer.' }
    Click-Control $controls.Split
    if (!$script:Actions[-1].payload.enabled -or $controls.DividerRow.Visibility -ne 'Visible' -or
        !$controls.Rail.IsAncestorOf($controls.DividerRow)) { throw 'Comparison settings escaped the sidebar.' }
    Click-Control $controls.Loupe
    Click-Control $controls.Histogram
    Click-Control $controls.After
    $action=$script:Actions[-1]
    if ($action.kind -ne 'inspect' -or $action.payload.enabled -or $action.payload.zoom -ne 'fit' -or
        $controls.HistogramPanel.Visibility -ne 'Collapsed') { throw 'Finished print did not restore the framed overview.' }
    Write-Output 'Passed inline paper selection, percentage editing, inspection and return to the finished print.'
} finally {
    if ($testSource) { $testSource.Dispose() }
    foreach ($file in @($testStatePath,$testSnapshot)) { if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) } }
    [IO.Directory]::Delete($testFolder)
}

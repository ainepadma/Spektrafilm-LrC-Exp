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
    $marginField.control.Value=7.5; Flush-Ranges $true
    if (!$script:Actions[-1].payload.draft) { throw 'Drag did not request a draft.' }
    Flush-Ranges
    if ($script:Actions[-1].payload.draft) { throw 'Settled slider did not request a full preview.' }
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
    $fixture.preview=Join-Path $project 'Spektrafilm.lrplugin/preview/640x384.png'
    $fixture.canPin=$true
    Apply-WorkspaceState $fixture
    Click-Control $controls.Pin
    $original=$controls.ReferenceImage.Source
    if (!$original -or $controls.CompareTools.Visibility -ne 'Visible') { throw 'Cannot pin the finished photo.' }
    $fixture.preview=Join-Path $project 'Spektrafilm.lrplugin/preview/832x468.png'
    Apply-WorkspaceState $fixture
    $controls.ComparePosition.Value=0
    if ($controls.ReferenceLayer.Clip.Rect.Width -ne 0 -or $controls.ReferenceImage.Source -ne $original -or
        $controls.Preview.Source -eq $original) { throw 'Adjusting B changed A or failed to move the divider.' }
    $fixture.photoId='43';$fixture.canPin=$false
    $fixture.filmPresets=@('暖彩')
    Apply-WorkspaceState $fixture
    if ($controls.ReferenceImage.Source -or $controls.Pin.IsEnabled) { throw 'Stale reference survived navigation.' }
    $section=$script:FilmPresetName.Parent.Parent
    $script:FilmPresetName.Text='暖彩'
    Click-Control ($section.Children | Where-Object Content -eq '保存当前配方（同名更新）')
    if ($script:Actions[-1].kind -ne 'filmPreset' -or $script:Actions[-1].payload.operation -ne 'save') {
        throw 'Film preset save button did not dispatch.'
    }
    Select-Value $script:FilmPresetBox '暖彩'
    $applyRow=$section.Children[1]
    Click-Control ($applyRow.Children | Where-Object Tag -eq 'selection')
    if ($script:Actions[-1].payload.operation -ne 'selection' -or $script:Actions[-1].payload.name -ne '暖彩') {
        throw 'Film preset selection action did not target the chosen preset.'
    }
    $fixture.recipe.printing.paperLayout='instant'
    $fixture.recipe.printing.watermark='text'
    Apply-WorkspaceState $fixture
    foreach ($key in @('captionFont','watermarkFont')) {
        $field=$script:Fields | Where-Object key -eq $key
        if (!$field.control.IsEnabled -or $field.control.Items.Count -lt 2) { throw "No installed font choices for $key" }
        $field.control.SelectedIndex=1
        if ($script:Actions[-1].payload.key -ne $key) { throw "Font selection did not update $key" }
    }
    $fixture.recipe.printing.watermark='png'
    Apply-WorkspaceState $fixture
    if (!($script:Fields | Where-Object key -eq 'watermarkPng').control.IsEnabled) { throw 'PNG watermark path disabled' }
    Write-Output 'Passed sidebar edits, inspection and same-photo A/B comparison.'
} finally {
    if ($testSource) { $testSource.Dispose() }
    foreach ($file in @($testStatePath,$testSnapshot)) { if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) } }
    [IO.Directory]::Delete($testFolder)
}

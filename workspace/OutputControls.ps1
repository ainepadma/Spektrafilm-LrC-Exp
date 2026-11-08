function Add-StockSection($Rail) {
    $panel=New-WorkspaceSection $Rail '胶片与相纸' $true
    $row=New-FieldRow $panel '胶片类型'
    $script:CategoryBox=New-Object Windows.Controls.ComboBox
    [void]$row.Children.Add($script:CategoryBox)
    $script:CategoryBox.Add_SelectionChanged({param($source,$e)
        if ($script:Applying -or !$source.SelectedItem) { return }
        $script:Category = [string]$source.SelectedItem.Tag
        $script:Applying=$true
        try { Update-StockChoices $script:State } finally { $script:Applying=$false }
        $film=$script:FilmBox
        if ($film.SelectedIndex -lt 0 -and $film.Items.Count -gt 0) {
            $film.SelectedIndex=0
        }
    })
    Add-ChoiceField $panel '胶片' 'recipe' 'film' @() ''
    $script:FilmBox=$script:Fields[$script:Fields.Count-1].control
    Add-ChoiceField $panel '相纸' 'recipe' 'paper' @() ''
    $script:PaperBox=$script:Fields[$script:Fields.Count-1].control
    Add-CheckField $panel '直接扫描胶片' 'options' 'scan' $false
    $script:DirectScan=$script:Fields[$script:Fields.Count-1].control
    $script:StockHint=Add-PanelText $panel ''
    $modes=Make-Choices @(,@('full','完整模拟'); ,@('fast-color','快速色彩（无颗粒和光晕）'))
    Add-ChoiceField $panel '模拟模式' 'recipe' 'mode' $modes 'full'
}
function Update-StockChoices($State) {
    $filmId=Get-FieldValue $State recipe film ''
    $all=Get-Items $State 'filmItems'
    $categories=Get-Items $State 'categories'
    if (!$categories.Count) { $categories=@([pscustomobject]@{value='all';title='所有胶片'}) }
    Set-ChoiceListIfChanged $script:CategoryBox $categories
    $current=$all | Where-Object { $_.value -ceq $filmId } | Select-Object -First 1
    $newPhoto = [string]$State.photoId -cne $script:DisplayedPhoto
    if ($newPhoto -and $current -and $script:Category -ne 'all' -and
        "$($current.channel)-$($current.type)" -ne $script:Category) { $script:Category='all' }
    Select-Value $script:CategoryBox $script:Category
    $filtered=@($all | Where-Object { $script:Category -eq 'all' -or "$($_.channel)-$($_.type)" -eq $script:Category })
    Set-ChoiceListIfChanged $script:FilmBox $filtered
    Select-Value $script:FilmBox $filmId
    $papers=Get-Items $State 'paperItems'
    if ($current.channel) { $papers=@($papers | Where-Object { !$_.channel -or $_.channel -eq $current.channel }) }
    Set-ChoiceListIfChanged $script:PaperBox $papers
    Select-Value $script:PaperBox (Get-FieldValue $State recipe paper '')
    $script:StockHint.Text=[string](Read-Member $State 'stockHint' '')
}
function Add-PaperSection($Rail) {
    $p=New-WorkspaceSection $Rail '相纸留白' $true
    Add-ChoiceField $p '纸色' printing paperBorder (Make-Choices @(,@('auto','印相时自动');,@('none','关闭');,@('white','白色');,@('warm','暖白');,@('black','黑色');,@('custom','自定义'))) 'auto'
    Add-RangeField $p '留白 / 短边 %' printing paperMargin 0 30 .035 .1 $null 100
    Add-TextField $p '自定义颜色' printing paperColor '#F7F3E9'
}
function Add-OutputSections($Rail) {
    $p=New-WorkspaceSection $Rail '胶片片边' $false
    $gates=Make-Choices @(,@('none','无片边');,@('135','135 · 36 × 24');,@('half','半格 · 18 × 24');,@('xpan','XPan');,@('645','120 · 6×4.5');,@('66','120 · 6×6');,@('67','120 · 6×7');,@('69','120 · 6×9');,@('612','120 · 6×12');,@('617','120 · 6×17'))
    Add-ChoiceField $p '片门' printing gate $gates 'none'
    Add-CheckField $p '保留 35 mm 齿孔' printing holes $true
    Add-CheckField $p '印胶片名称与帧号' printing markings $true
    Add-RangeField $p '帧号' printing frameNumber 0 9999 1 1
    Add-RangeField $p '片边起雾' printing fog 0 1 0 .01
    Add-RangeField $p '漏光' printing leak 0 1 0 .01
    $p=New-WorkspaceSection $Rail '日期背' $false
    Add-ChoiceField $p '文字' printing dateFace (Make-Choices @(,@('none','关闭');,@('date','拍摄日期');,@('data','快门、光圈与焦距'))) 'none'
    Add-ChoiceField $p '位置' printing datePosition (Make-Choices @(,@('br','右下');,@('bl','左下');,@('tr','右上');,@('tl','左上'))) 'br'
    Add-RangeField $p '字号 / 短边' printing dateSize .01 .25 .043 .001
    Add-RangeField $p '边距 / 短边' printing dateMargin 0 .4 .04 .005
    Add-RangeField $p '亮度' printing dateBrightness 0 1 .85 .01
    $p=New-WorkspaceSection $Rail '半格双拼' $false
    Add-CheckField $p '将相邻两张照片组成一组' export pair $false
    Add-ChoiceField $p '排列' printing pairDirection (Make-Choices @(,@('horizontal','横排');,@('vertical','竖排'))) 'horizontal'
    Add-RangeField $p '片间距 mm' printing pairGap .5 2 1 .05
    foreach ($side in @('first','second')) {
        $caption=if ($side -eq 'first') {'第一张'} else {'第二张'}
        Add-RangeField $p "$caption 曝光 EV" printing ($side+'Ev') -3 3 0 .05
        Add-RangeField $p "$caption 缩放" printing ($side+'Scale') 1 4 1 .05
        Add-RangeField $p "$caption 水平位置" printing ($side+'X') -1 1 0 .02
        Add-RangeField $p "$caption 垂直位置" printing ($side+'Y') -1 1 0 .02
    }
    $p=New-WorkspaceSection $Rail '复制与同步' $false
    $script:PasteGroups=@()
    foreach ($name in @('胶片、相纸与扫描','胶片曝光与放大机','画幅与胶片效果','冲印后调色与场景定位','成片外观与模拟模式')) {
        $box=New-Object Windows.Controls.CheckBox; $box.Content=$name;$box.IsChecked=$true
        [void]$p.Children.Add($box);$script:PasteGroups+=,$box
    }
    $row=New-Object Windows.Controls.WrapPanel;[void]$p.Children.Add($row)
    [void](Add-PanelButton $row '复制设置' { [void](Send-UiAction 'copy') })
    foreach ($pair in @(,@('paste','粘贴到当前');,@('sync','同步到选区'))) {
        $b=Add-PanelButton $row $pair[1] {param($button,$e)
            $selected=@(for($i=0;$i -lt $script:PasteGroups.Count;$i++){if ($script:PasteGroups[$i].IsChecked){$i+1}})
            if (!$selected.Count) { Show-Notice '请选择要复制的设置组。';return }
            [void](Send-UiAction ([string]$button.Tag) @{groups=$selected})
        }
        $b.Tag=$pair[0]
    }
    $p=New-WorkspaceSection $Rail '输出设置' $false
    Add-ChoiceField $p '文件格式' export format (Make-Choices @(,@('jpg','JPEG');,@('png','PNG');,@('tif','TIFF');,@('di','Cineon 对数 TIFF'))) 'jpg'
    Add-ChoiceField $p '色彩空间' export space (Make-Choices @(,@('srgb','sRGB');,@('p3','Display P3');,@('prophoto','ProPhoto RGB'))) 'srgb'
    Add-RangeField $p 'JPEG 品质' export quality 1 100 90 1
    Add-ChoiceField $p 'TIFF 位深' export bits (Make-Choices @(,@(8,'8 位');,@(16,'16 位'))) 16
    Add-RangeField $p '长边 px · 0 原始' export edge 0 65535 0 1
    Add-TextField $p '文件命名' export nameTemplate '{name}-film'
    [void](Add-PanelText $p '{name} 原名   {film} 胶片   {paper} 相纸   {date} 日期')
    Add-ChoiceField $p '同名文件' export collision (Make-Choices @(,@('unique','添加后缀');,@('skip','跳过');,@('overwrite','覆盖输出文件'))) 'unique'
    Add-TextField $p '输出目录' export folder ''
    $script:FolderEditor=$script:Fields[$script:Fields.Count-1].control
    Add-FolderBrowser $p
    $p=New-WorkspaceSection $Rail '输出配方' $false
    $row=New-FieldRow $p '已保存';$script:PresetBox=New-Object Windows.Controls.ComboBox
    [void]$row.Children.Add($script:PresetBox)
    $row=New-FieldRow $p '配方名称';$script:PresetName=New-Object Windows.Controls.TextBox
    [void]$row.Children.Add($script:PresetName)
    $row=New-Object Windows.Controls.WrapPanel;[void]$p.Children.Add($row)
    [void](Add-PanelButton $row '载入配方' {
        if ($script:PresetBox.SelectedItem) {[void](Send-UiAction preset @{operation='load';name=[string]$script:PresetBox.SelectedItem.Tag})}
    })
    [void](Add-PanelButton $row '保存配方' {
        $name=$script:PresetName.Text.Trim()
        if (!$name) { Show-Notice '请输入配方名称。'; return }
        [void](Send-UiAction preset @{operation='save';name=$name})
    })
    $script:ResultsBody=New-WorkspaceSection $Rail '导出记录' $false
    $script:ResultsText=Add-PanelText $script:ResultsBody '尚无记录。'
}
function Add-FolderBrowser($Panel) {
    $script:FolderPane=New-Object Windows.Controls.StackPanel
    [void](Add-PanelButton $Panel '浏览目录…' {
        if ($script:FolderPane.Visibility -eq 'Visible') { $script:FolderPane.Visibility='Collapsed'; return }
        $script:FolderPane.Visibility='Visible'
        $path=$script:FolderEditor.Text
        if (![IO.Directory]::Exists($path)) { $path=Split-Path -Parent $PSScriptRoot }
        Show-Folder $path
    })
    $script:FolderPane.Visibility='Collapsed';[void]$Panel.Children.Add($script:FolderPane)
    $script:FolderCaption=Add-PanelText $script:FolderPane ''
    $row=New-Object Windows.Controls.WrapPanel;[void]$script:FolderPane.Children.Add($row)
    [void](Add-PanelButton $row '上一级' {
        $parent=[IO.Directory]::GetParent($script:FolderPath)
        if ($parent) { Show-Folder $parent.FullName } else { Show-Folder '' }
    })
    [void](Add-PanelButton $row '采用此目录' {
        if ($script:FolderPath) { $script:FolderEditor.Text=$script:FolderPath;Send-Edit export folder $script:FolderPath;$script:FolderPane.Visibility='Collapsed' }
    })
    $scroll=New-Object Windows.Controls.ScrollViewer;$scroll.MaxHeight=150;$scroll.VerticalScrollBarVisibility='Auto'
    $script:FolderList=New-Object Windows.Controls.StackPanel;$scroll.Content=$script:FolderList;[void]$script:FolderPane.Children.Add($scroll)
}
function Show-Folder([string]$Path) {
    try {
        $folders=if (!$Path) { [IO.Directory]::GetLogicalDrives() } else { [IO.Directory]::EnumerateDirectories($Path) }
        $script:FolderList.Children.Clear()
        foreach ($directory in ($folders | Sort-Object)) {
            $name=[IO.Path]::GetFileName($directory)
            $b=Add-PanelButton $script:FolderList $(if($name){$name}else{$directory}) {param($button,$e) Show-Folder $button.Tag}
            $b.Tag=$directory;$b.HorizontalContentAlignment='Left'
        }
        $script:FolderPath=$Path;$script:FolderCaption.Text=$(if($Path){$Path}else{'磁盘'})
    } catch { Show-Notice $_.Exception.Message }
}

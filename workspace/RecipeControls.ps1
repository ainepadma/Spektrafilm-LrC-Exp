# Per-photo film recipe editors; all parameter changes go through Send-Edit.
function New-RecipeSelector($Panel, [string]$Caption, $Choices, [scriptblock]$Changed) {
    $row = New-FieldRow $Panel $Caption
    $box = New-Object Windows.Controls.ComboBox
    [Windows.Automation.AutomationProperties]::SetName($box,$Caption)
    Set-Choices $box (Make-Choices $Choices)
    $box.SelectedIndex = 0
    $box.Add_SelectionChanged($Changed)
    [void]$row.Children.Add($box)
    return $box
}

function Read-CurvePoints {
    $curves = Get-FieldValue $script:State 'options' 'curves' @{}
    $data = Read-Member $curves $script:RecipeUi.channel
    $points = New-Object Collections.ArrayList
    foreach ($point in $data) { [void]$points.Add([double[]]@($point[0],$point[1])) }
    if ($points.Count -lt 2) {
        $points.Clear()
        [void]$points.Add([double[]]@(0,0))
        [void]$points.Add([double[]]@(1,1))
    }
    return ,$points
}

function Save-RecipeCurve {
    $ui = $script:RecipeUi
    $all = Copy-Map (Get-FieldValue $script:State 'options' 'curves' @{})
    $all[$ui.channel] = $ui.points.ToArray()
    Send-Edit 'options' 'curves' $all
}

function Select-RecipePoint([int]$Index) {
    $ui = $script:RecipeUi
    $ui.index = [math]::Max(0,[math]::Min($ui.points.Count-1,$Index))
    Draw-RecipeCurve
}

function Draw-RecipeCurve {
    $ui = $script:RecipeUi
    $c = $ui.canvas
    $i = $ui.index
    $pt = $ui.points[$i]
    $ui.pointLabel.Text = '{0} / {1}' -f ($i+1),$ui.points.Count
    if (!$ui.inputX.IsKeyboardFocused) { $ui.inputX.Text = $pt[0].ToString('0.####',[cultureinfo]::InvariantCulture) }
    if (!$ui.inputY.IsKeyboardFocused) { $ui.inputY.Text = $pt[1].ToString('0.####',[cultureinfo]::InvariantCulture) }
    $interior = $i -gt 0 -and $i -lt $ui.points.Count-1
    $ui.inputX.IsEnabled = $interior
    $ui.remove.IsEnabled = $interior
    $ui.previous.IsEnabled = $i -gt 0
    $ui.next.IsEnabled = $i -lt $ui.points.Count-1
    $w = $c.ActualWidth-14
    $h = $c.ActualHeight-14
    if ($w -lt 1 -or $h -lt 1) { return }
    $c.Children.Clear()
    for ($j=0; $j -le 4; $j++) {
        $sx = 7 + $w*$j/4
        $sy = 7 + $h*$j/4
        $v = New-Object Windows.Shapes.Line
        $v.X1=$sx; $v.X2=$sx; $v.Y1=7; $v.Y2=$h+7; $v.Stroke='#44484C'
        $u = New-Object Windows.Shapes.Line
        $u.X1=7; $u.X2=$w+7; $u.Y1=$sy; $u.Y2=$sy; $u.Stroke='#44484C'
        [void]$c.Children.Add($v)
        [void]$c.Children.Add($u)
    }
    $colors = @{rgb='#E8E9EC';luma='#C8CAD1';red='#F28F8D';green='#8FCC97';blue='#99BAF5'}
    $line = New-Object Windows.Shapes.Polyline
    $line.Stroke=$colors[$ui.channel]; $line.StrokeThickness=2
    foreach ($p in $ui.points) {
        $line.Points.Add([Windows.Point]::new((7+$p[0]*$w),(7+(1-$p[1])*$h)))
    }
    [void]$c.Children.Add($line)
    for ($n=0; $n -lt $ui.points.Count; $n++) {
        $p=$ui.points[$n]
        $dot=New-Object Windows.Shapes.Ellipse
        $dot.Width=9; $dot.Height=9; $dot.Stroke=$colors[$ui.channel]; $dot.StrokeThickness=1.5
        $dot.Fill=if ($n -eq $i) { $colors[$ui.channel] } else { '#242629' }
        [Windows.Controls.Canvas]::SetLeft($dot,7+$p[0]*$w-4.5)
        [Windows.Controls.Canvas]::SetTop($dot,7+(1-$p[1])*$h-4.5)
        [void]$c.Children.Add($dot)
    }
}

function Move-RecipePoint([double]$X,[double]$Y) {
    $ui=$script:RecipeUi
    $i=$ui.index
    if ($i -eq 0) { $X=0 }
    elseif ($i -eq $ui.points.Count-1) { $X=1 }
    else {
        $X=[math]::Max($ui.points[$i-1][0]+.0001,[math]::Min($ui.points[$i+1][0]-.0001,$X))
    }
    $coords=[double[]]@([math]::Round($X,5),[math]::Round([math]::Max(0.0,[math]::Min(1.0,$Y)),5))
    if ($ui.dragging -and ($ui.points[$i][0] -ne $coords[0] -or $ui.points[$i][1] -ne $coords[1])) { $ui.dragEdited=$true }
    $ui.points[$i]=$coords
    Draw-RecipeCurve
}

function Insert-RecipePoint([double]$X,[double]$Y) {
    $ui=$script:RecipeUi
    if ($ui.points.Count -ge 256 -or $X -le 0 -or $X -ge 1) { return $false }
    $i=1
    while ($i -lt $ui.points.Count -and $ui.points[$i][0] -lt $X) { $i++ }
    if ($X-$ui.points[$i-1][0] -lt .0002 -or $ui.points[$i][0]-$X -lt .0002) { return $false }
    $ui.points.Insert($i,[double[]]@($X,$Y))
    $ui.index=$i
    Move-RecipePoint $X $Y
    return $true
}

function Submit-RecipeCoordinate {
    $ui=$script:RecipeUi
    if ($script:Applying -or !$ui.points) { return }
    $x=0.0; $y=0.0
    $okX=[double]::TryParse($ui.inputX.Text,[Globalization.NumberStyles]::Float,[cultureinfo]::InvariantCulture,[ref]$x)
    $okY=[double]::TryParse($ui.inputY.Text,[Globalization.NumberStyles]::Float,[cultureinfo]::InvariantCulture,[ref]$y)
    if ($okX -and $okY -and $x -ge 0 -and $x -le 1 -and $y -ge 0 -and $y -le 1) {
        $old = $ui.points[$ui.index]
        if ($old[0] -ne $x -or $old[1] -ne $y) { Move-RecipePoint $x $y; Save-RecipeCurve }
    }
    Draw-RecipeCurve
}

function Initialize-RecipeCurve($Parent) {
    $ui=$script:RecipeUi
    $ui.channelBox=New-RecipeSelector $Parent '通道' @(@('rgb','RGB'),@('luma','亮度'),@('red','红'),@('green','绿'),@('blue','蓝')) {
        param($source,$e)
        if ($null -eq $source.SelectedItem) { return }
        $script:RecipeUi.channel=$source.SelectedItem.Tag
        $script:RecipeUi.points=Read-CurvePoints
        Select-RecipePoint 0
    }
    $c=New-Object Windows.Controls.Canvas
    $c.Height=142; $c.Margin='0,5,0,5'; $c.Background='#232528'; $c.ClipToBounds=$true
    $c.Focusable=$true; $c.ToolTip='单击添加控制点，拖动调整曲线。'
    [Windows.Automation.AutomationProperties]::SetName($c,'曲线控制点')
    $ui.canvas=$c
    [void]$Parent.Children.Add($c)
    $tools=New-Object Windows.Controls.WrapPanel
    [void]$Parent.Children.Add($tools)
    $ui.previous=Add-PanelButton $tools '‹' { Select-RecipePoint ($script:RecipeUi.index-1) }
    $ui.previous.ToolTip='上一个控制点'
    $ui.pointLabel=Add-PanelText $tools ''
    $ui.next=Add-PanelButton $tools '›' { Select-RecipePoint ($script:RecipeUi.index+1) }
    $ui.next.ToolTip='下一个控制点'
    [void](Add-PanelButton $tools '加点' {
        $u=$script:RecipeUi
        $i=[math]::Min($u.index,$u.points.Count-2)
        $x=($u.points[$i][0]+$u.points[$i+1][0])/2
        $y=($u.points[$i][1]+$u.points[$i+1][1])/2
        if (Insert-RecipePoint $x $y) { Save-RecipeCurve }
    })
    $ui.remove=Add-PanelButton $tools '删点' {
        $u=$script:RecipeUi
        if ($u.index -gt 0 -and $u.index -lt $u.points.Count-1) {
            $u.points.RemoveAt($u.index)
            Select-RecipePoint ($u.index-1)
            Save-RecipeCurve
        }
    }
    [void](Add-PanelButton $tools '重置通道' {
        $u=$script:RecipeUi
        $u.points.Clear(); [void]$u.points.Add([double[]]@(0,0)); [void]$u.points.Add([double[]]@(1,1))
        Select-RecipePoint 0
        Save-RecipeCurve
    })
    foreach ($k in 'X','Y') {
        $row=New-FieldRow $Parent ('控制点 '+$k)
        $box=New-Object Windows.Controls.TextBox
        $ui['input'+$k]=$box
        [Windows.Automation.AutomationProperties]::SetName($box,('控制点 '+$k))
        $box.Add_LostKeyboardFocus({ Submit-RecipeCoordinate })
        $box.Add_PreviewKeyDown({param($source,$e) if ($e.Key -eq 'Return') {
            $e.Handled=$true
            [void]$script:RecipeUi.canvas.Focus()
        }})
        [void]$row.Children.Add($box)
    }
    $c.Add_SizeChanged({ Draw-RecipeCurve })
    $c.Add_MouseLeftButtonDown({param($source,$e)
        $pos=$e.GetPosition($source)
        $u=$script:RecipeUi
        $w=$source.ActualWidth-14; $h=$source.ActualHeight-14
        if ($w -lt 1 -or $h -lt 1) { return }
        $dist=100.; $nearest=-1
        for ($i=0; $i -lt $u.points.Count; $i++) {
            $dx=$pos.X-(7+$u.points[$i][0]*$w); $dy=$pos.Y-(7+(1-$u.points[$i][1])*$h)
            $test=$dx*$dx+$dy*$dy
            if ($test -lt $dist) { $dist=$test; $nearest=$i }
        }
        if ($nearest -ge 0) { Select-RecipePoint $nearest }
        elseif (!(Insert-RecipePoint (($pos.X-7)/$w) (1-($pos.Y-7)/$h))) { return }
        $u.dragEdited=($nearest -lt 0)
        $u.dragging=$true
        $u.dragPhoto=[string]$script:State.photoId
        [void]$source.Focus(); [void]$source.CaptureMouse()
        $e.Handled=$true
    })
    $c.Add_MouseMove({param($source,$e)
        if (!$script:RecipeUi.dragging -or $e.LeftButton -ne 'Pressed') { return }
        $pos=$e.GetPosition($source)
        Move-RecipePoint (($pos.X-7)/($source.ActualWidth-14)) (1-($pos.Y-7)/($source.ActualHeight-14))
    })
    $c.Add_MouseLeftButtonUp({param($source,$e)
        if ($script:RecipeUi.dragging) {
            $script:RecipeUi.dragging=$false
            if ($script:RecipeUi.dragEdited -and $script:RecipeUi.dragPhoto -ceq [string]$script:State.photoId) { Save-RecipeCurve }
            $source.ReleaseMouseCapture()
            $e.Handled=$true
        }
    })
    $c.Add_LostMouseCapture({ if ($script:RecipeUi.dragging) {
        $script:RecipeUi.dragging=$false; $script:RecipeUi.points=Read-CurvePoints; Select-RecipePoint 0
    }})
}

function Sync-RecipeZone {
    $ui=$script:RecipeUi
    $all=Get-FieldValue $script:State 'options' 'zones' @{}
    $zone=Read-Member $all $ui.zone @{}
    $was=$script:Applying
    $script:Applying=$true
    try {
        foreach ($f in $ui.zoneFields) {
            $value=[double](Read-Member $zone $f.key $f.default)
            if ($f.control.IsMouseCaptureWithin -or $f.number.IsKeyboardFocusWithin -or
                $script:RangeQueue.ContainsKey("local/$($f.key)")) { continue }
            $f.control.Value=$value
            if (!$f.number.IsKeyboardFocused) { $f.number.Text=$value.ToString('0.###',[cultureinfo]::InvariantCulture) }
        }
    } finally { $script:Applying=$was }
}

function Set-RecipeZone([string]$Key,[double]$Value) {
    $all=Copy-Map (Get-FieldValue $script:State 'options' 'zones' @{})
    $zone=Copy-Map (Read-Member $all $script:RecipeUi.zone @{})
    $zone[$Key]=$Value
    $all[$script:RecipeUi.zone]=$zone
    Send-Edit 'options' 'zones' $all
}

function Sync-RecipeControls($State) {
    $ui=$script:RecipeUi
    $editable=[bool](Read-Member $State 'canEdit' $true) -and [bool](Read-Member $State 'photoId' '')
    foreach ($panel in $ui.panels) { $panel.IsEnabled=$editable }
    $scan=[bool](Read-Member $State 'directScan' $false)
    $full = (Get-FieldValue $State recipe mode 'full') -ne 'fast-color'
    foreach ($f in $ui.options) {
        $key=$f.key
        $enabled=$editable
        if ($key -in @('print_ev','yellow','magenta','preflash','glare_on','glare')) { $enabled=$enabled -and !$scan }
        if ($key -in @('format_mm','grain_on','grain','halation_on','antihalation','halation','scatter','boost','glare_on','glare')) {
            $enabled=$enabled -and $full
        }
        $toggle=@{grain='grain_on';antihalation='halation_on';halation='halation_on';scatter='halation_on';boost='halation_on';couplers='couplers_on';glare='glare_on'}
        if ($toggle.ContainsKey($key)) { $enabled=$enabled -and (Get-FieldValue $State options $toggle[$key] $true) }
        $f.control.IsEnabled=$enabled
        if ($f.number) { $f.number.IsEnabled=$enabled }
    }
    if ($ui.dragging -and $ui.dragPhoto -cne [string]$State.photoId) {
        $ui.dragging=$false; $ui.canvas.ReleaseMouseCapture()
    }
    if (!$ui.dragging) { $ui.points=Read-CurvePoints; Select-RecipePoint $ui.index }
    Sync-RecipeZone
    $d=Read-Member $State 'diagnostics'
    if ($null -eq $d) {
        $ui.measure.Text='等待当前照片的预览测量。'
        $ui.suggest.IsEnabled=$false
    } else {
        $ui.measure.Text=(
            '胶片直扫   {0:F1} 至 {1:F1} EV' -f $d.film_low,$d.film_high
        ),('印相范围   {0:F1} 至 {1:F1} EV' -f $d.medium_low,$d.medium_high),
        ('场景范围   {0:F1} 至 {1:F1} EV' -f $d.scene_low,$d.scene_high),
        ('调整后   {0:F1} 至 {1:F1} EV' -f $d.placed_low,$d.placed_high),
        ('超出范围   暗部 {0:F1}% · 高光 {1:F1}%' -f $d.shadow_pct,$d.highlight_pct) -join [Environment]::NewLine
        $ui.suggest.IsEnabled=$editable
    }
}

function Initialize-RecipeControls($Rail) {
    $script:RecipeUi=@{channel='rgb';zone='master';index=0;dragging=$false;panels=@();options=@();zoneFields=@()}
    $ui=$script:RecipeUi
    $ui.points=Read-CurvePoints
    $start=$script:Fields.Count
    $exposure = New-WorkspaceSection $Rail '曝光与印相' $true
    $ui.panels += $exposure
    foreach ($row in @(@('胶片曝光 EV','film_ev',-4,4,0,.05),@('印相亮度 EV','print_ev',-3,3,0,.05),
        @('黄色滤色','yellow',-1,1,0,.01),@('品红滤色','magenta',-1,1,0,.01),@('相纸预闪','preflash',0,.03,0,.001))) {
        Add-RangeField $exposure $row[0] options $row[1] $row[2] $row[3] $row[4] $row[5]
    }
    $effects=New-WorkspaceSection $Rail '画幅与胶片效果'
    $ui.panels += $effects
    Add-RangeField $effects '画幅长边 mm' options format_mm 4 200 35 .1
    Add-CheckField $effects '胶片颗粒' options grain_on $true
    Add-RangeField $effects '颗粒强度' options grain 0 2 1 .01
    Add-CheckField $effects '胶片光晕' options halation_on $true
    Add-CheckField $effects '保留防光晕层' options antihalation $true
    Add-RangeField $effects '光晕强度' options halation 0 4 1 .01
    Add-RangeField $effects '乳剂散射' options scatter 0 4 1 .01
    Add-RangeField $effects '亮部增强 EV' options boost 0 8 0 .1
    Add-CheckField $effects '染料层间偶合' options couplers_on $true
    Add-RangeField $effects '偶合强度' options couplers 0 4 1 .01
    Add-CheckField $effects '相纸眩光' options glare_on $true
    Add-RangeField $effects '眩光强度' options glare 0 30 1 .1
    $post=New-WorkspaceSection $Rail '成片调色'
    $ui.panels += $post
    foreach ($row in @(@('后期曝光 EV','exposure',-3,3,.05),@('对比度','contrast',-100,100,1),@('亮度','brightness',-100,100,1),
        @('饱和度','saturation',-100,100,1),@('高光','highlights',-100,100,1),@('阴影','shadows',-100,100,1),
        @('黑位','black',0,50,1),@('白位','white',0,50,1))) { Add-RangeField $post $row[0] options $row[1] $row[2] $row[3] 0 $row[4] }
    $latitude=New-WorkspaceSection $Rail '宽容度与曝光位置'
    $ui.panels += $latitude
    $ui.measure=Add-PanelText $latitude '等待当前照片的预览测量。'
    Add-RangeField $latitude '阴影回收 EV' options shadow_pull 0 8 0 .05
    Add-RangeField $latitude '高光回收 EV' options highlight_pull 0 8 0 .05
    $ui.suggest=Add-PanelButton $latitude '应用测量建议' {
        $d=Read-Member $script:State 'diagnostics'
        if ($d) {
            Send-Edit 'options' 'shadow_pull' ([double]$d.suggest_shadow)
            Send-Edit 'options' 'highlight_pull' ([double]$d.suggest_highlight)
        }
    }
    $ui.suggest.IsEnabled=$false
    for ($i=$start;$i -lt $script:Fields.Count;$i++) { $ui.options += $script:Fields[$i] }
    $curve=New-WorkspaceSection $Rail '曲线'
    $ui.panels += $curve
    Initialize-RecipeCurve $curve
    $zones=New-WorkspaceSection $Rail '分区调色'
    $ui.panels += $zones
    $ui.zoneBox=New-RecipeSelector $zones '范围' @(@('master','整体'),@('shadows','阴影'),@('midtones','中间调'),@('highlights','高光')) {
        param($source,$e)
        if ($source.SelectedItem) {
            if (!$script:Applying) { Flush-Ranges }
            $script:RecipeUi.zone=$source.SelectedItem.Tag
            Sync-RecipeZone
        }
    }
    foreach ($row in @(@('色相 °','hue',0,360,1),@('饱和度','saturation',0,1,.01),@('亮度','luminance',-1,1,.01))) {
        Add-RangeField $zones $row[0] local $row[1] $row[2] $row[3] 0 $row[4] { param($key,$value) Set-RecipeZone $key $value }
        $ui.zoneFields += $script:Fields[$script:Fields.Count-1]
    }
    Add-StateListener { param($state) Sync-RecipeControls $state }
}

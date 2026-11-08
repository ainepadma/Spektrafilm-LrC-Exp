# Controls share the same dark WPF resources and send edits through the session transport.
function New-WorkspaceSection($Parent, [string]$Title, [bool]$Expanded=$false) {
    $section = New-Object Windows.Controls.Expander
    $section.Header = $Title
    $section.IsExpanded = $Expanded
    $body = New-Object Windows.Controls.StackPanel
    $section.Content = $body
    [void]$Parent.Children.Add($section)
    return $body
}
function Add-PanelText($Parent, [string]$Text) {
    $label = New-Object Windows.Controls.TextBlock
    $label.Text = $Text
    $label.Foreground = $script:Window.FindResource('Muted')
    $label.TextWrapping = 'Wrap'
    $label.Margin = '0,3,0,4'
    [void]$Parent.Children.Add($label)
    return $label
}
function Add-PanelButton($Parent, [string]$Text, [scriptblock]$Click) {
    $button = New-Object Windows.Controls.Button
    $button.Content = $Text
    $button.Margin = '0,3,4,2'
    $button.Add_Click($Click)
    [void]$Parent.Children.Add($button)
    return $button
}
function New-FieldRow($Panel,[string]$Label) {
    $row = New-Object Windows.Controls.DockPanel
    $row.Margin = '0,3,0,3'
    $caption = New-Object Windows.Controls.TextBlock
    $caption.Text = $Label
    $caption.Width = 100
    $caption.Foreground = $script:Window.FindResource('Muted')
    [void]$row.Children.Add($caption)
    [void]$Panel.Children.Add($row)
    return $row
}
function Read-Member($Object, [string]$Key, $Default=$null) {
    if ($null -eq $Object) { return $Default }
    if ($Object -is [Collections.IDictionary]) {
        if ($Object.Contains($Key) -and $null -ne $Object[$Key]) { return ,$Object[$Key] }
    } else {
        $property = $Object.PSObject.Properties[$Key]
        if ($property -and $null -ne $property.Value) { return ,$property.Value }
    }
    return ,$Default
}
function Get-FieldValue($State,[string]$Group,[string]$Key,$Default=$null) {
    $photoId = [string](Read-Member $State 'photoId' '')
    $pending = $script:Optimistic["$photoId/$Group/$Key"]
    if ($pending) { return ,$pending.value }
    $data = switch ($Group) {
        recipe { Read-Member $State recipe }
        options { Read-Member (Read-Member $State recipe) options }
        printing { Read-Member (Read-Member $State recipe) printing }
        export { Read-Member $State export }
    }
    return ,(Read-Member $data $Key $Default)
}
function Copy-Map($Value) {
    $map = @{}
    if ($Value -is [Collections.IDictionary]) {
        foreach ($k in $Value.Keys) { $map[$k]=$Value[$k] }
    } elseif ($null -ne $Value -and $Value -isnot [Array]) {
        foreach ($property in $Value.PSObject.Properties) {
            if ($property.MemberType -eq 'NoteProperty') { $map[$property.Name]=$property.Value }
        }
    }
    return $map
}
function Get-Items($State,[string]$Key) {
    $items=Read-Member $State $Key
    if ($items -is [Array] -or $items -is [Collections.IList]) { return ,$items }
    return ,@()
}
function Send-UiAction([string]$Kind,[hashtable]$Payload=@{}) {
    if ($script:Applying -or $script:QaMode) { return }
    $Payload.photoId = [string](Read-Member $script:State 'photoId' '')
    Send-WorkspaceAction $Kind $Payload
}
function Send-Edit([string]$Group,[string]$Key,$Value) {
    if ($script:Applying -or $null -eq $script:State -or $script:QaMode) { return }
    $id = [string](Read-Member $script:State 'photoId' '')
    if (!$id -and $Group -ne 'export') { return }
    $sequence = Send-UiAction edit @{group=$Group; key=$Key; value=$Value; draft=[bool]$script:SendingDraft}
    $script:Optimistic["$id/$Group/$Key"] = @{value=$Value; sequence=$sequence; acknowledged=$false}
}
function New-Field($Parent,[string]$Group,[string]$Key,$Default,[string]$Label,[string]$Type) {
    $field = @{key=$Key; group=$Group; default=$Default; label=$Label; type=$Type; parent=$Parent}
    [void]$script:Fields.Add($field)
    return $field
}
function Make-Choices($Pairs) {
    $output = foreach ($pair in $Pairs) { [pscustomobject]@{value=$pair[0];title=$pair[1]} }
    return ,@($output)
}
function Set-Choices($Box, $Items) {
    $Box.Items.Clear()
    foreach ($it in $Items) {
        $option = New-Object Windows.Controls.ComboBoxItem
        $option.Content = [string]$it.title
        $option.Tag = $it.value
        [void]$Box.Items.Add($option)
    }
}
function Select-Value($Box, $Value) {
    for ($i=0; $i -lt $Box.Items.Count; $i++) {
        if ([string]$Box.Items[$i].Tag -ceq [string]$Value) {
            if ($Box.SelectedIndex -ne $i) { $Box.SelectedIndex=$i }
            return
        }
    }
    $Box.SelectedIndex=-1
}
function Add-ChoiceField($Panel,[string]$Label,[string]$Group,[string]$Key,$Items,$Default) {
    $row = New-FieldRow $Panel $Label
    $f = New-Field $Panel $Group $Key $Default $Label choice
    $box = New-Object Windows.Controls.ComboBox
    [Windows.Automation.AutomationProperties]::SetName($box,$Label)
    $box.Tag = $f; $f.control = $box
    Set-Choices $box $Items
    $box.Add_SelectionChanged({param($source,$e)
        if (!$script:Applying -and $null -ne $source.SelectedItem) {
            Send-Edit $source.Tag.group $source.Tag.key $source.SelectedItem.Tag
        }
    })
    [void]$row.Children.Add($box)
}
function Add-CheckField($Panel,[string]$Label,[string]$Group,[string]$Key,[bool]$Default) {
    $f = New-Field $Panel $Group $Key $Default $Label check
    $box = New-Object Windows.Controls.CheckBox
    $box.Content=$Label; $box.Tag=$f; $f.control=$box
    $box.Add_Click({param($source,$e) Send-Edit $source.Tag.group $source.Tag.key ([bool]$source.IsChecked)})
    [void]$Panel.Children.Add($box)
}
function Send-NumericField($Field,[double]$Number) {
    if ($Number -lt $Field.min -or $Number -gt $Field.max) { return }
    $value = [math]::Round($Number, 5)
    if ($Field.step -ge 1) { $value = [int][math]::Round($Number) }
    $Field.number.Text = $value.ToString([Globalization.CultureInfo]::InvariantCulture)
    if ($Field.ContainsKey('handler')) { & $Field.handler $Field.key $value }
    else { Send-Edit $Field.group $Field.key ($value/$Field.scale) }
}
function Add-RangeField($Panel,[string]$Label,[string]$Group,[string]$Key,[double]$Min,[double]$Max,[double]$Default,[double]$Step,$Handler=$null,[double]$DisplayScale=1) {
    $row = New-FieldRow $Panel $Label
    $f = New-Field $Panel $Group $Key $Default $Label range
    $f.min=$Min; $f.max=$Max; $f.step=$Step; $f.scale=$DisplayScale
    if ($Handler) { $f.handler=$Handler }
    $num=New-Object Windows.Controls.TextBox
    $num.Width=64; $num.Padding='4,2'; $num.TextAlignment='Right'
    $num.Margin='6,0,0,0'; $num.Tag=$f; $f.number=$num
    [Windows.Automation.AutomationProperties]::SetName($num,$Label)
    [Windows.Controls.DockPanel]::SetDock($num,'Right'); [void]$row.Children.Add($num)
    $slider=New-Object Windows.Controls.Slider
    $slider.Minimum=$Min; $slider.Maximum=$Max; $slider.SmallChange=$Step; $slider.LargeChange=$Step*5
    $slider.TickFrequency=$Step; $slider.IsSnapToTickEnabled=$true; $slider.IsMoveToPointEnabled=$true
    $slider.Tag=$f; $f.control=$slider
    [Windows.Automation.AutomationProperties]::SetName($slider,$Label)
    $slider.Add_ValueChanged({param($source,$e)
        if (!$script:Applying) {
            $field=$source.Tag
            $field.number.Text = ([math]::Round($source.Value,4)).ToString([Globalization.CultureInfo]::InvariantCulture)
            Queue-RangeEdit $field $source.Value
        }
    })
    $num.Add_LostKeyboardFocus({param($source,$e)
        if ($script:Applying) { return }
        $f=$source.Tag; $value=0.0
        if ([double]::TryParse($source.Text,[Globalization.NumberStyles]::Float,[CultureInfo]::InvariantCulture,[ref]$value) -and
            $value -ge $f.min -and $value -le $f.max) {
            $script:Applying=$true; try { $f.control.Value=$value } finally { $script:Applying=$false }
            Send-NumericField $f $value
        } else { $source.Text=[string]([math]::Round($f.control.Value,4)) }
    })
    $num.Add_PreviewKeyDown({param($source,$e)
        if ($e.Key -eq 'Return') { $e.Handled=$true; [void]$source.Tag.control.Focus() }
    })
    [void]$row.Children.Add($slider)
}
function Add-TextField($Panel,[string]$Label,[string]$Group,[string]$Key,[string]$Default) {
    $row=New-FieldRow $Panel $Label
    $f=New-Field $Panel $Group $Key $Default $Label text
    $box=New-Object Windows.Controls.TextBox; $box.Tag=$f; $f.control=$box
    [Windows.Automation.AutomationProperties]::SetName($box,$Label)
    $box.Add_LostKeyboardFocus({param($source,$e)
        if (!$script:Applying -and $source.Text -cne [string](Get-FieldValue $script:State $source.Tag.group $source.Tag.key $source.Tag.default)) {
            Send-Edit $source.Tag.group $source.Tag.key $source.Text
        }
    })
    $box.Add_PreviewKeyDown({param($source,$e)
        if ($e.Key -eq 'Return') { $e.Handled=$true; [void]$script:Controls.Stage.Focus() }
    })
    [void]$row.Children.Add($box)
}
function Queue-RangeEdit($Field,[double]$Value) {
    $script:RangeQueue["$($Field.group)/$($Field.key)"] = @{field=$Field; value=$Value;photoId=[string]$script:State.photoId}
    $script:LastRangeChange=[datetime]::UtcNow
    if (!$script:RangeTimer.IsEnabled) { $script:RangeTimer.Start() }
}
function Flush-Ranges([bool]$Draft=$false) {
    $entries=@($script:RangeQueue.Values)
    if (!$Draft) { $script:RangeTimer.Stop(); $script:RangeQueue.Clear() }
    $script:SendingDraft=$Draft
    try {
        foreach($record in $entries) {
            if ($record.photoId -ceq [string]$script:State.photoId -and (!$Draft -or !$record.sent)) {
                Send-NumericField $record.field $record.value
                $record.sent=$true
            }
        }
    } finally {
        $script:SendingDraft=$false
    }
}

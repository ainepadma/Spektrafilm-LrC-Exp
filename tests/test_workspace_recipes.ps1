$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'workspace/Fields.ps1')
. (Join-Path $root 'workspace/RecipeControls.ps1')
$script:Window=New-Object Windows.Window
$script:Window.Resources['Muted']=[Windows.Media.Brushes]::Silver
$script:Fields=New-Object Collections.ArrayList
$script:Optimistic=@{}
$script:RangeQueue=@{}
$script:RangeTimer=New-Object Windows.Threading.DispatcherTimer
$script:Applying=$true
$script:Edits=New-Object Collections.ArrayList
function Add-StateListener($Action) { $script:RecipeListener=$Action }
function Send-Edit($Group,$Key,$Value) {
    if ($script:Applying) { return }
    $script:Optimistic["$($script:State.photoId)/$Group/$Key"]=@{value=$Value}
    [void]$script:Edits.Add(@{group=$Group;key=$Key;value=$Value})
}
function Check([bool]$Condition,[string]$Message) { if (!$Condition) { throw $Message } }
$script:State=@{photoId='photo-A';canEdit=$true;canGrain=$true;directScan=$false;
    recipe=@{options=@{curves=@{blue=@(@(0,0),@(.4,.6),@(1,1))};
                         zones=@{shadows=@{hue=230;saturation=.5;luminance=.1}}}};
    diagnostics=@{film_low=-4;film_high=5;medium_low=-2;medium_high=2;scene_low=-3;scene_high=3;
                  placed_low=-2;placed_high=2;shadow_pct=2;highlight_pct=4;suggest_shadow=1.5;suggest_highlight=.5}}
$rail=New-Object Windows.Controls.StackPanel
$script:Window.Content=$rail
Initialize-RecipeControls $rail
& $script:RecipeListener $script:State
Check ($rail.Children.Count -eq 6) 'Missing film, curve, latitude or zone section.'
Check ($script:RecipeUi.measure.Text.Contains('5.0 EV')) 'Latitude did not display measured film range.'
Check ($script:RecipeUi.suggest.IsEnabled) 'Available diagnostics should enable suggestions.'
$script:Applying=$false
$ui=$script:RecipeUi
Select-Value $ui.channelBox 'blue'
Check ($ui.points.Count -eq 3) 'Blue curve did not hydrate with three points.'
Check (Insert-RecipePoint .7 .86) 'Could not add an interior point.'
Move-RecipePoint .72 .8
Save-RecipeCurve
$edited=$script:Edits[$script:Edits.Count-1].value['blue']
Check ($edited.Count -eq 4 -and $edited[2][0] -eq .72 -and $edited[2][1] -eq .8) 'Curve transport lost points or coordinates.'
Select-RecipePoint 0
Move-RecipePoint .45 .1
Check ($ui.points[0][0] -eq 0 -and $ui.points[0][1] -eq .1) 'Curve endpoint moved off the valid domain.'
Select-Value $ui.zoneBox 'shadows'
Check ($ui.zoneFields[0].control.Value -eq 230) 'Zone values did not synchronize.'
Set-RecipeZone 'luminance' -.3
$edited=$script:Edits[$script:Edits.Count-1].value['shadows']
Check ($edited.hue -eq 230 -and $edited.saturation -eq .5 -and $edited.luminance -eq -.3) 'Zone edit overwrote other axes.'
$script:State.directScan=$true
$script:State.recipe.options.grain_on=$false
$script:State.canGrain=$false  # Lua uses this to describe the grain slider, not all optics.
$script:State.recipe.mode='full'
$script:Applying=$true
& $script:RecipeListener $script:State
Check (-not (($ui.options | Where-Object key -eq 'print_ev').control.IsEnabled)) 'Direct scan should disable paper exposure.'
$grain=($ui.options | Where-Object key -eq 'grain_on').control
Check ($grain.IsEnabled) 'A disabled grain effect must remain switchable in full mode.'
Check (-not (($ui.options | Where-Object key -eq 'grain').control.IsEnabled)) 'Grain strength should follow the effect toggle.'
Check (($ui.options | Where-Object key -eq 'halation_on').control.IsEnabled) 'Turning off grain disabled an independent optical effect.'
$script:Applying=$false
$grain.IsChecked=$true
$grain.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
$script:Applying=$true
& $script:RecipeListener $script:State
Check (($ui.options | Where-Object key -eq 'grain').control.IsEnabled) 'Switching grain back on should restore its strength slider.'
$script:State.recipe.mode='fast-color'
& $script:RecipeListener $script:State
Check (!$grain.IsEnabled) 'Fast color should disable physical grain.'
$script:State.photoId='photo-B'
$script:State.recipe.options=@{}
$script:State.diagnostics=$null
& $script:RecipeListener $script:State
Check ($ui.points.Count -eq 2 -and !$ui.suggest.IsEnabled) 'Photo change retained another photo recipe or diagnosis.'
$script:Window.Close()
'Recipe controls passed'

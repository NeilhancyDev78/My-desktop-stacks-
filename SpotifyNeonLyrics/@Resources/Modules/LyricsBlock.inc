; ==============================
; LYRICS MODULE (LRCLIB + Lua)
; ==============================

[MeasureTitle]
Measure=Plugin
Plugin=WebNowPlaying
PlayerType=Title

[MeasureArtist]
Measure=Plugin
Plugin=WebNowPlaying
PlayerType=Artist

[MeasurePosition]
Measure=Plugin
Plugin=WebNowPlaying
PlayerType=Position

[MeasureLyricsBaseY]
Measure=Calc
DynamicVariables=1
Formula=(#PanelH#/2)

[MeasureLyricsFetch]
Measure=Plugin
Plugin=RunCommand
Program=curl.exe
Parameter=-s -G --data-urlencode "artist_name=[MeasureArtist]" --data-urlencode "track_name=[MeasureTitle]" https://lrclib.net/api/search
OutputType=UTF8
State=Hide
DynamicVariables=1
StartInThread=1
UpdateDivider=20
OnUpdateAction=[!CommandMeasure MeasureLyricsFetch "Run"]
FinishAction=[!UpdateMeasure MeasureLyrics][!UpdateMeterGroup Lyrics][!Redraw]

[MeasureLyrics]
Measure=Script
ScriptFile=#@#Scripts\LyricsParser.lua
UpdateDivider=1
DynamicVariables=1

[MeterLyricCurrent]
Meter=String
Group=Lyrics
Text=[&MeasureLyrics:GetLine(0)]
X=(#LY_X#+(#LY_W#/2))
Y=([MeasureLyricsBaseY])
W=#LY_W#
H=120
FontFace=#FontMain#
FontSize=#CurSize#
FontColor=#TextMain#
StringAlign=CenterCenter
AntiAlias=1
ClipString=2
DynamicVariables=1
Hidden=(1-#ShowLyrics#)
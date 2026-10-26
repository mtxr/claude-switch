Output manage.gif

Set Shell "bash"
Set FontSize 18
Set Width 1100
Set Height 640
Set Padding 20
Set Theme "Catppuccin Mocha"
Set TypingSpeed 45ms

Hide
Type `export PS1='$ ' && eval "$(csw hook bash)" && clear` Enter
Show

Type "csw whoami | head -n 8" Enter
Sleep 3s
Type "clear" Enter

Type "csw new sandbox" Enter
Sleep 2s
Type "csw list" Enter
Sleep 2s
Type "csw use work" Enter
Sleep 2s
Type "csw delete sandbox" Enter
Sleep 2s
Type "csw list" Enter
Sleep 3s

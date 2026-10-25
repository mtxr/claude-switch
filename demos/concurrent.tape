Output concurrent.gif

Set Shell "bash"
Set FontSize 18
Set Width 1100
Set Height 360
Set Padding 20
Set Theme "Catppuccin Mocha"
Set TypingSpeed 45ms

Hide
Type `export PS1='$ ' && tmux -f /dev/null new-session "env PS1='$ ' bash --norc --noprofile" \; set -g default-command "env PS1='$ ' bash --norc --noprofile" \; set status off \; split-window -h` Enter
Sleep 1s
Type "clear" Enter
Ctrl+B
Left
Type "clear" Enter
Show

Type "csw run work" Enter
Sleep 1500ms
Ctrl+B
Right
Type "csw run personal" Enter
Sleep 4s

Output demo.gif

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

Type "csw list" Enter
Sleep 2s
Type "claude" Enter
Sleep 2s

Type "csw use personal" Enter
Sleep 2s
Type "claude" Enter
Sleep 2s

Type "csw run work" Enter
Sleep 2s
Type "clear" Enter

Type "mkdir -p ~/projects/acme && cd ~/projects/acme && csw bind work" Enter
Sleep 1s
Type "claude" Enter
Sleep 2s
Type "cd ~" Enter
Sleep 1s
Type "claude" Enter
Sleep 3s

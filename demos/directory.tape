Output directory.gif

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

Type "mkdir -p ~/code/api ~/code/blog" Enter
Type "(cd ~/code/api && csw bind work) && (cd ~/code/blog && csw bind personal)" Enter
Sleep 1500ms
Type "clear" Enter

Type "cd ~/code/api && cat .csw" Enter
Sleep 1s
Type "claude" Enter
Sleep 2s
Type "cd ../blog && cat .csw" Enter
Sleep 1s
Type "claude" Enter
Sleep 2s
Type "clear" Enter

Type "echo ghost > .csw" Enter
Sleep 2500ms
Type "claude" Enter
Sleep 3s

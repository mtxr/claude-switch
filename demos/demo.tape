Output demo.gif

Set Shell "bash"
Set FontSize 18
Set Width 1100
Set Height 720
Set Padding 20
Set Theme "Catppuccin Mocha"
Set TypingSpeed 45ms

Hide
Type `export PS1='$ ' && eval "$(csw hook bash)" && mkdir -p ~/code/acme-api ~/code/blog && clear` Enter
Show

Type "csw list" Enter
Sleep 2s
Type "csw use personal" Enter
Sleep 1s
Type "claude" Enter
Sleep 2s
Type "clear" Enter

Type "cd ~/code/acme-api && csw bind work" Enter
Sleep 1s
Type "cd ~/code/blog && csw bind personal" Enter
Sleep 1s
Type "clear" Enter

Type "cd ~/code/acme-api" Enter
Sleep 1s
Type "claude" Enter
Sleep 2500ms
Type "clear" Enter

Type "cd ~/code/blog" Enter
Sleep 1s
Type "claude" Enter
Sleep 2500ms
Type "clear" Enter

Type "csw run oss" Enter
Sleep 3s

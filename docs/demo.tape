Output docs/demo.gif
Require npx

Set Shell "bash"
Set FontSize 14
Set Width 940
Set Height 860
Set Padding 24
Set Theme "Catppuccin Mocha"
Set TypingSpeed 55ms
Set Framerate 15

Hide
Type@5ms "stty -echo; clear"
Enter
Type@5ms "D=$(mktemp -d) && cp -R examples/d1-toml $D/app && mkdir $D/bin && cp zig-out/bin/qenome $D/bin/qenome && export PATH=$D/bin:$PATH"
Enter
Type@5ms "cd $D/app && npx --yes wrangler@4.152.0 d1 execute DEMO_DB --local --file schema.sql > /dev/null 2>&1 && echo ready"
Enter
Wait+Screen@180s /ready/
Type@5ms "stty echo && clear"
Enter
Sleep 1s
Show

Sleep 1s
Type "qenome --d1 DEMO_DB select.sql index.sql --runs 40"
Sleep 600ms
Enter
Wait+Screen@60s /production D1/
Sleep 4s

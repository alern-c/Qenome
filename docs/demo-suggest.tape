Output docs/demo-suggest.gif
Require npx

Set Shell "bash"
Set FontSize 24
Set Width 1200
Set Height 460
Set Padding 24
Set Theme "Catppuccin Mocha"
Set TypingSpeed 15ms
Set Framerate 15

Hide
Type@5ms "stty -echo; export PS1='$ '; clear"
Enter
Type@5ms "D=$(mktemp -d) && cp -R examples/d1-toml $D/app && cp docs/demo/* $D/app && mkdir $D/bin && cp zig-out/bin/qenome $D/bin/qenome && export PATH=$D/bin:$PATH TMPDIR=/tmp"
Enter
Type@5ms "cd $D/app && npx --yes wrangler@4.152.0 d1 execute DEMO_DB --local --file schema.sql > /dev/null 2>&1 && npx --yes wrangler@4.152.0 d1 execute DEMO_DB --local --command ANALYZE > /dev/null 2>&1 && echo ready"
Enter
Wait+Screen@180s /ready/
Type@5ms "stty echo && clear"
Enter
Sleep 1s
Show

Sleep 200ms
Type "cat select.sql"
Enter
Sleep 1s
Type "qenome --d1 DEMO_DB select.sql --suggest | sed -n '/^Suggested/,$p'"
Sleep 200ms
Enter
Wait+Screen@60s /Recommendation/
Sleep 6s

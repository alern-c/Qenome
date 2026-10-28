Output docs/demo-migration.gif
Require npx

Set Shell "bash"
Set FontSize 14
Set Width 1400
Set Height 520
Set Padding 24
Set Theme "Catppuccin Mocha"
Set TypingSpeed 45ms
Set Framerate 15

Hide
Type@5ms "stty -echo; export PS1='$ '; clear"
Enter
Type@5ms "D=$(mktemp -d) && cp -R examples/d1-toml $D/app && cp docs/demo/* $D/app && mkdir $D/bin && cp zig-out/bin/qenome $D/bin/qenome && export PATH=$D/bin:$PATH TMPDIR=/tmp"
Enter
Type@5ms "cd $D/app && npx --yes wrangler@4.152.0 d1 execute DEMO_DB --local --file schema.sql > /dev/null 2>&1 && npx --yes wrangler@4.152.0 d1 execute DEMO_DB --local --file index.sql > /dev/null 2>&1 && echo ready"
Enter
Wait+Screen@180s /ready/
Type@5ms "stty echo && clear"
Enter
Sleep 1s
Show

Sleep 800ms
Type "cat 0002_reindex.sql"
Enter
Sleep 2500ms
Type `qenome --d1 DEMO_DB --batch queries.json --migration 0002_reindex.sql; echo "exit=$?"`
Sleep 600ms
Enter
Wait+Screen@60s /exit=[0-9]/
Sleep 5s

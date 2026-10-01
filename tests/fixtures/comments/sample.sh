#!/bin/bash
# header
n=${#arr[@]}; echo $# "x # y" 'it # s' \'# escaped
echo hi # trailing
cat <<'EOF'
# a heading inside a heredoc
EOF
# shellcheck disable=SC2016
echo done

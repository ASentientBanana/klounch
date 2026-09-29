

## build an executable
curl -LO https://raw.githubusercontent.com/ers35/luastatic/master/luastatic.lua

CC=gcc lua luastatic.lua gridlauncher.lua \
    -I/usr/include/lua5.4 -llua5.4 -rdynamic -ldl -lm


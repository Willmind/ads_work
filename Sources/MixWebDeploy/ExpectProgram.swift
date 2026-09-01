import Foundation

enum ExpectProgram {
    static let source = #"""
#!/usr/bin/env expect

proc fail {code message} {
    puts "\n__MWD_ERROR__:$message"
    exit $code
}

if {$argc < 8} {
    fail 2 "启动参数不完整"
}

set action [lindex $argv 0]
set host [lindex $argv 1]
set port [lindex $argv 2]
set username [lindex $argv 3]
set pem [lindex $argv 4]
set project [lindex $argv 5]
set menu1 [lindex $argv 6]
set menu2 [lindex $argv 7]
set branch ""
if {$argc >= 9} {
    set branch [lindex $argv 8]
}

if {![regexp {^[A-Za-z0-9.-]+$} $host]} {
    fail 3 "SSH 主机名格式不正确"
}
if {![regexp {^[0-9]+$} $port]} {
    fail 3 "SSH 端口格式不正确"
}
if {![regexp {^[A-Za-z0-9._@+-]+$} $username]} {
    fail 3 "SSH 用户名格式不正确"
}
if {![regexp {^/[A-Za-z0-9._/-]+$} $project] || [string first ".." $project] >= 0} {
    fail 3 "项目目录格式不正确"
}
if {$action eq "deploy" && ![regexp {^[A-Za-z0-9._/-]+$} $branch]} {
    fail 3 "Git 分支名格式不正确"
}

log_user 1
set timeout 35

set sshCommand [list /usr/bin/ssh -tt \
    -o BatchMode=yes \
    -o ConnectTimeout=15 \
    -o ServerAliveInterval=10 \
    -o ServerAliveCountMax=2 \
    -o StrictHostKeyChecking=accept-new \
    -p $port \
    -i $pem \
    "$username@$host"]

puts "正在连接 Jumpserver..."
spawn {*}$sshCommand

expect {
    -re {(?i)permission denied} { fail 20 "SSH 身份验证失败" }
    -re {(?i)(enter passphrase|password).*:} { fail 21 "私钥需要密码，或服务器要求输入密码" }
    -re {.+} { }
    timeout { fail 22 "等待 Jumpserver 第一级菜单超时" }
    eof { fail 23 "SSH 连接提前关闭" }
}

after 300
send -- "$menu1\r"

expect {
    -re {(?i)permission denied} { fail 20 "SSH 身份验证失败" }
    -re {(?i)(enter passphrase|password).*:} { fail 21 "服务器要求输入密码" }
    -re {.+} { }
    timeout { fail 24 "等待 Jumpserver 第二级菜单超时" }
    eof { fail 23 "SSH 连接提前关闭" }
}

after 300
send -- "$menu2\r"

expect {
    -re {(?i)permission denied} { fail 20 "目标服务器身份验证失败" }
    -re {(?i)(enter passphrase|password).*:} { fail 21 "目标服务器要求输入密码" }
    -re {(?m)[#>$] ?$} { }
    timeout { fail 25 "等待目标服务器命令提示符超时" }
    eof { fail 23 "SSH 连接提前关闭" }
}

# 关闭远程终端回显，防止命令本身被误识别为完成标记。
send -- "stty -echo\r"
after 150
send -- "printf '\n__MWD_SHELL_READY__\n'\r"

expect {
    "__MWD_SHELL_READY__" { }
    timeout { fail 26 "目标服务器 Shell 未就绪" }
    eof { fail 23 "SSH 连接提前关闭" }
}

if {$action eq "test"} {
    puts "\n连接测试成功。"
    send -- "exit\r"
    exit 0
}

set cdCommand [format {cd -- '%s' && printf '\n__MWD_CD_OK__\n' || printf '\n__MWD_CD_FAIL__\n'} $project]
send -- "$cdCommand\r"
expect {
    "__MWD_CD_OK__" { }
    "__MWD_CD_FAIL__" { fail 30 "无法进入服务器项目目录" }
    timeout { fail 31 "进入服务器项目目录超时" }
    eof { fail 23 "SSH 连接提前关闭" }
}

set timeout 120
send -- "sudo -n git fetch --prune origin && printf '\n__MWD_FETCH_OK__\n' || printf '\n__MWD_FETCH_FAIL__\n'\r"
expect {
    "__MWD_FETCH_OK__" { }
    "__MWD_FETCH_FAIL__" { fail 32 "git fetch 失败；请检查 Git 权限或远程 sudo 配置" }
    -re {(?i)sudo:.*password.*required} { fail 33 "远程 sudo 需要密码，工具不会保存明文密码" }
    timeout { fail 34 "git fetch 执行超时" }
    eof { fail 23 "SSH 连接提前关闭" }
}

if {$action eq "branches"} {
    send -- "printf '\n__MWD_BRANCHES_BEGIN__\n'; sudo -n git for-each-ref --format='%(refname:short)' refs/remotes/origin | sed 's#^origin/##' | grep -v '^HEAD$' | sort -u; printf '__MWD_BRANCHES_END__\n'\r"
    expect {
        "__MWD_BRANCHES_END__" { }
        -re {(?i)sudo:.*password.*required} { fail 33 "远程 sudo 需要密码" }
        timeout { fail 35 "读取远程分支超时" }
        eof { fail 23 "SSH 连接提前关闭" }
    }
    send -- "exit\r"
    exit 0
}

if {$action ne "deploy"} {
    fail 4 "不支持的操作"
}

set statusCommand {if status_output=$(sudo -n git status --porcelain); then if test -z "$status_output"; then printf '\n__MWD_CLEAN__\n'; else printf '\n__MWD_DIRTY__\n'; fi; else printf '\n__MWD_STATUS_FAIL__\n'; fi}
send -- "$statusCommand\r"
expect {
    "__MWD_CLEAN__" { }
    "__MWD_DIRTY__" { fail 40 "服务器工作区存在未提交修改，已停止操作" }
    "__MWD_STATUS_FAIL__" { fail 41 "无法检查服务器 Git 状态" }
    -re {(?i)sudo:.*password.*required} { fail 33 "远程 sudo 需要密码" }
    timeout { fail 42 "检查服务器 Git 状态超时" }
    eof { fail 23 "SSH 连接提前关闭" }
}

set checkoutCommand [format {if sudo -n git show-ref --verify --quiet 'refs/heads/%s'; then sudo -n git checkout '%s'; elif sudo -n git show-ref --verify --quiet 'refs/remotes/origin/%s'; then sudo -n git checkout --track 'origin/%s'; else false; fi && printf '\n__MWD_CHECKOUT_OK__\n' || printf '\n__MWD_CHECKOUT_FAIL__\n'} $branch $branch $branch $branch]
send -- "$checkoutCommand\r"
expect {
    "__MWD_CHECKOUT_OK__" { }
    "__MWD_CHECKOUT_FAIL__" { fail 43 "切换分支失败，请确认远程分支存在" }
    -re {(?i)sudo:.*password.*required} { fail 33 "远程 sudo 需要密码" }
    timeout { fail 44 "切换分支超时" }
    eof { fail 23 "SSH 连接提前关闭" }
}

set pullCommand [format {sudo -n git pull --ff-only origin '%s' && printf '\n__MWD_PULL_OK__\n' || printf '\n__MWD_PULL_FAIL__\n'} $branch]
send -- "$pullCommand\r"
expect {
    "__MWD_PULL_OK__" { }
    "__MWD_PULL_FAIL__" { fail 45 "git pull --ff-only 失败，服务器分支可能已产生分叉" }
    -re {(?i)sudo:.*password.*required} { fail 33 "远程 sudo 需要密码" }
    timeout { fail 46 "git pull 执行超时" }
    eof { fail 23 "SSH 连接提前关闭" }
}

send -- "printf '\n当前提交：'; sudo -n git rev-parse --short HEAD; printf '__MWD_DEPLOY_OK__\n'\r"
expect {
    "__MWD_DEPLOY_OK__" { }
    timeout { fail 47 "读取当前提交信息超时" }
    eof { fail 23 "SSH 连接提前关闭" }
}

send -- "exit\r"
exit 0
"""#
}

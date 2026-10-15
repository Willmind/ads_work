import Foundation

enum ExpectProgram {
    static let source = #"""
#!/usr/bin/env expect

proc fail {code message} {
    puts "\n__MWD_ERROR__:$message"
    exit $code
}

proc stage {name} {
    puts "__MWD_STAGE__:$name"
    flush stdout
}

# Interpret diagnostics here instead of forwarding private repository paths/users.
proc branchFailure {status diagnostic} {
    set diagnostic [string tolower $diagnostic]
    if {[regexp {sudo:.*(password|terminal|tty)} $diagnostic]} {
        fail 33 "远程 sudo 需要密码或交互终端，请确认该 Git 命令的免密授权"
    } elseif {[regexp {(not in the sudoers|not allowed to execute|may not run sudo)} $diagnostic]} {
        fail 36 "当前 SSH 用户没有执行此 sudo Git 命令的权限"
    } elseif {[string first "not a git repository" $diagnostic] >= 0} {
        fail 36 "项目目录不是 Git 仓库，或 Git 无法识别该目录下的仓库"
    } elseif {[string first "dubious ownership" $diagnostic] >= 0} {
        fail 36 "Git 拒绝访问属主不匹配的仓库，请管理员核对仓库属主和信任配置"
    } elseif {[regexp {(unknown field name|unrecognized.*argument|unknown.*refname|unrecognized.*refname)} $diagnostic]} {
        fail 36 "服务器 Git 不支持当前的分支格式参数，请确认已打开最新版本工具"
    } elseif {[string first "permission denied" $diagnostic] >= 0} {
        fail 36 "Git 读取仓库文件时被拒绝访问，请检查目录及文件权限"
    } elseif {[regexp {(command not found|git: not found|git: no such file)} $diagnostic]} {
        fail 36 "sudo 执行环境中找不到 Git，请管理员检查 Git 安装与命令路径"
    }
    fail 36 "git for-each-ref 返回错误（退出码 $status）；请管理员在目标目录核查该只读命令"
}

proc complete {} {
    global spawn_id
    puts "__MWD_DONE__"
    flush stdout
    send -- "exit\r"
    exit 0
}

trap {exit 130} {SIGTERM SIGINT}

if {$argc < 8} {
    fail 2 "启动参数不完整"
}

set action [lindex $argv 0]
if {$action ni {test branches syncBranches deploy}} {
    fail 4 "不支持的操作"
}
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

# Only explicit progress/results are forwarded, never banners, menus or prompts.
log_user 0
match_max -d 1048576
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

stage connect
spawn -noecho {*}$sshCommand

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
    complete
}

stage project
set cdCommand [format {cd -- '%s' && printf '\n__MWD_CD_OK__\n' || printf '\n__MWD_CD_FAIL__\n'} $project]
send -- "$cdCommand\r"
expect {
    "__MWD_CD_OK__" { }
    "__MWD_CD_FAIL__" { fail 30 "无法进入服务器项目目录" }
    timeout { fail 31 "进入服务器项目目录超时" }
    eof { fail 23 "SSH 连接提前关闭" }
}

set timeout 120
if {$action in {syncBranches deploy}} {
    stage fetch
    send -- "sudo -n git fetch --prune origin && printf '\n__MWD_FETCH_OK__\n' || printf '\n__MWD_FETCH_FAIL__\n'\r"
    expect {
        "__MWD_FETCH_OK__" { }
        "__MWD_FETCH_FAIL__" { fail 32 "git fetch 失败；请检查 Git 远端访问和 sudo 权限" }
        -re {(?i)sudo:.*password.*required} { fail 33 "远程 sudo 需要密码，工具不会保存明文密码" }
        timeout { fail 34 "git fetch 执行超时" }
        eof { fail 23 "SSH 连接提前关闭" }
    }
}

if {$action in {branches syncBranches}} {
    stage branches
    # Use plain refname for older Git; strip the exact remote prefix locally.
    # Capture the exit status and diagnostics, never turn a failed read into an empty list.
    set branchesCommand {if refs=$(sudo -n git for-each-ref --format='%(refname)' refs/remotes/origin 2>&1); then printf '\n__MWD_BRANCHES_BEGIN__\n%s\n__MWD_BRANCHES_END__\n' "$refs"; else status=$?; printf '\n__MWD_BRANCHES_FAIL_BEGIN__:%s\n%s\n__MWD_BRANCHES_FAIL_END__\n' "$status" "$refs"; fi}
    send -- "$branchesCommand\r"
    expect {
        -re {\r?\n__MWD_BRANCHES_BEGIN__\r?\n(.*?)\r?\n__MWD_BRANCHES_END__\r?\n} {
            puts "__MWD_BRANCHES_BEGIN__"
            foreach ref [split $expect_out(1,string) "\n"] {
                set ref [string trim $ref "\r"]
                set prefix "refs/remotes/origin/"
                if {[string first $prefix $ref] != 0} { continue }
                set name [string range $ref [string length $prefix] end]
                if {$name ne "HEAD" && $name ne ""} { puts $name }
            }
            puts "__MWD_BRANCHES_END__"
        }
        -re {\r?\n__MWD_BRANCHES_FAIL_BEGIN__:([0-9]+)\r?\n(.*?)\r?\n__MWD_BRANCHES_FAIL_END__\r?\n} {
            branchFailure $expect_out(1,string) $expect_out(2,string)
        }
        timeout { fail 35 "读取远程分支超时" }
        eof { fail 23 "SSH 连接提前关闭" }
    }
    complete
}

stage check
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

stage checkout
set checkoutCommand [format {if sudo -n git show-ref --verify --quiet 'refs/heads/%s'; then sudo -n git checkout '%s'; elif sudo -n git show-ref --verify --quiet 'refs/remotes/origin/%s'; then sudo -n git checkout --track 'origin/%s'; else false; fi && printf '\n__MWD_CHECKOUT_OK__\n' || printf '\n__MWD_CHECKOUT_FAIL__\n'} $branch $branch $branch $branch]
send -- "$checkoutCommand\r"
expect {
    "__MWD_CHECKOUT_OK__" { }
    "__MWD_CHECKOUT_FAIL__" { fail 43 "切换分支失败，请确认远程分支存在" }
    -re {(?i)sudo:.*password.*required} { fail 33 "远程 sudo 需要密码" }
    timeout { fail 44 "切换分支超时" }
    eof { fail 23 "SSH 连接提前关闭" }
}

stage pull
set pullCommand [format {sudo -n git pull --ff-only origin '%s' && printf '\n__MWD_PULL_OK__\n' || printf '\n__MWD_PULL_FAIL__\n'} $branch]
send -- "$pullCommand\r"
expect {
    "__MWD_PULL_OK__" { }
    "__MWD_PULL_FAIL__" { fail 45 "git pull --ff-only 失败，服务器分支可能已产生分叉" }
    -re {(?i)sudo:.*password.*required} { fail 33 "远程 sudo 需要密码" }
    timeout { fail 46 "git pull 执行超时" }
    eof { fail 23 "SSH 连接提前关闭" }
}

set commitCommand {if commit=$(sudo -n git rev-parse --short HEAD); then printf '\n__MWD_COMMIT__:%s\n' "$commit"; else printf '\n__MWD_COMMIT_FAIL__\n'; fi}
send -- "$commitCommand\r"
expect {
    -re {\r?\n__MWD_COMMIT__:([0-9a-f]{7,40})\r?\n} { puts "__MWD_COMMIT__:$expect_out(1,string)" }
    "__MWD_COMMIT_FAIL__" { fail 48 "代码已拉取，但读取提交号失败，请检查服务器状态" }
    timeout { fail 47 "读取当前提交信息超时" }
    eof { fail 23 "SSH 连接提前关闭" }
}

complete
"""#
}

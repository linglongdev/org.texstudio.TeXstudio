#!/bin/bash
set -e

function help() {
    echo "usage:"
    echo "$(basename $0) -i -d DEB -p PATH [-I INCLUDE] [-E EXCLUDE] [-L LOGS]"
    echo "$(basename $0) -u -r REGEX [-L LOG] [-D]"
    echo "    -i 安装deb包"
    echo "    -u 删除已安装的deb包"
    echo "    -d DIR 待安装deb包目录"
    echo "    -r '\-dev|pkg1|pkg2...' 需要删除的deb包的正则表达式"
    echo "    -p PATH 安装路径"
    echo "    -I 'pkg1,pkg2...' 需要强制安装的deb包列表, 以逗号分隔, 不受-E影响"
    echo "    -E 'pkg1,pkg2...' 需要排除的deb包列表, 以逗号分隔"
    echo "    -L LOGS 安装记录存放目录"
    echo "    -D 删除安装记录"
    echo "    -h 打印帮助信息"
    exit
}

function install() {
    if [ -z "$logs" ]; then
        logs="$PREFIX/pkg_contents"
    fi

    # 临时目录
    temp_dir="$(mktemp -d)"
    cd "$temp_dir"
    # 临时文件, 用于记录deb文件列表
    deb_list_file="$temp_dir/deb.list"
    # 临时文件, 用于记录强制安装的包名
    include_list_file="$temp_dir/include.packages.list"
    # 临时文件, 用于记录跳过安装的包名
    exclude_list_file="$temp_dir/exclude.packages.list"
    # 临时目录, 用于存放包数据
    data_list_dir="$temp_dir/data"
    # 临时目录, 用于存放文件安装记录
    deb_trace_dir="$temp_dir/trace"
    skipped_list="$deb_trace_dir/0_skipped.list"
    mkdir $deb_trace_dir
    touch $skipped_list
    # 生成文件列表
    find "$deb_dir" -type f -name "*.deb" >"$deb_list_file"
    echo "$include" | tr ',' '\n' >"$include_list_file"
    echo "$exclude" | tr ',' '\n' >"$exclude_list_file"

    # 如果base和runtime已安装则跳过, 旧版本base没有/packages.list文件就使用/var/lib/dpkg/status
    grep 'Package: ' /var/lib/dpkg/status | sed 's/Package: //g' >>"$exclude_list_file" || true
    cat /packages.list /runtime/packages.list | sed 's/Package: //g' >>"$exclude_list_file" || true
    # 在旧的base里面这些包需要强制安装, 因为base中没有他们的dev包, 如果dev包被安装到/opt目录, 而lib包在/usr 会有问题
    # TODO update
    echo "libarchive13,libasan5,libasm1,libbabeltrace1,libcairo-script-interpreter2,libcc1-0,libcurl4,libdpkg-perl,libdw1,libevent-2.1-6,libgdbm-compat4,libgdbm6,libgirepository-1.0-1,libgles1,libgles2,libglib2.0-data,libgmpxx4ldbl,libgnutls-dane0,libgnutls-openssl27,libgnutlsxx28,libharfbuzz-gobject0,libharfbuzz-icu0,libipt2,libisl19,libitm1,libjsoncpp1,libldap-2.4-2,libldap-common,liblsan0,liblzo2-2,libmpc3,libmpdec2,libmpfr6,libmpx2,libncurses6,libnghttp2-14,libpcrecpp0v5,libperl5.28,libpopt0,libprocps7,libpython3-stdlib,libpython3.7,libpython3.7-minimal,libpython3.7-stdlib,libquadmath0,libreadline7,librhash0,librtmp1,libsasl2-2,libsasl2-modules-db,libssh2-1,libtiffxx5,libtsan0,libubsan1,libunbound8,libuv1" | tr ',' '\n' >>"$include_list_file"

    # 遍历文件列表
    while IFS= read -r file; do
        # 安装路径
        ins_path="$path"
        # 输出deb名, 但不换行, 便于在包名后面加skip
        echo -n "$file"
        # 提取control文件
        control_file=$(ar -t "$file" | grep control.tar)
        ar -x "$file" "$control_file"
        # 获取包名
        pkg=$(tar -xf "$control_file" ./control -O | grep '^Package:' | awk '{print $2}')
        rm "$control_file"
        # 如果包含在exclude列表, 并且不包含在include列表则跳过安装
        if grep -q "^$pkg$" "$exclude_list_file" && ! grep -q "^$pkg$" "$include_list_file"; then
            echo " skip"
            echo "$file" >>$skipped_list
        else
            # 否则安装到$ins_path目录
            # 换行
            echo ""
            # 查找data.tar文件, 文件会因为压缩格式不同, 有不同的后缀, 例如data.tar.xz、data.tar.gz
            data_file=$(ar -t "$file" | grep data.tar)
            # 提取data.tar文件
            ar -x "$file" "$data_file"
            # 解压data.tar文件到输出目录
            mkdir "$data_list_dir"
            tar -xvf "$data_file" -C "$data_list_dir" | sed 's#^./usr#./#' | sed "s#^./#$ins_path/#" >>"$deb_trace_dir/$(basename "$file").list"
            rm "$data_file"

            # 清理不需要复制的目录
            rm -r "${data_list_dir:?}/usr/share/applications"* 2>/dev/null || true
            # 修改pc文件的prefix
            sed -i "s#/usr#$ins_path#g" "$data_list_dir"/usr/lib/"$TRIPLET"/pkgconfig/*.pc 2>/dev/null || true
            sed -i "s#/usr#$ins_path#g" "$data_list_dir"/usr/share/pkgconfig/*.pc 2>/dev/null || true
            # 修改指向/lib的绝对路径的软链接
            find "$data_list_dir" -type l | while IFS= read -r file; do
                linkTarget=$(readlink "$file")
                # 如果指向的路径以/lib开头, 并且文件不存在, 则添加 $ins_path 前缀
                # 部分 dev 包会创建 so 文件的绝对链接指向 /lib 目录下
                # + 处理 /etc
                if echo "$linkTarget" | grep -q '^/lib\|^/etc' && ! [ -f "$linkTarget" ]; then
                    ln -sf "$ins_path$linkTarget" "$file"
                    echo "    FIX LINK" "$linkTarget" "=>" "$ins_path$linkTarget"
                fi
            done
            # 修复动态库的RUNPATH
            find "$data_list_dir" -type f -exec file {} \; | grep 'shared object\|ELF.*executable' | awk -F: '{print $1}' | while IFS= read -r file; do
                runpath=$(readelf -d "$file" | grep RUNPATH | awk '{print $NF}')
                # 如果RUNPATH使用绝对路径, 则添加/runtime前缀
                if echo "$runpath" | grep -q '^\[/'; then
                    runpath=${runpath#[}
                    runpath=${runpath%]}
                    newRunpath=${runpath//usr\/lib/runtime\/lib}
                    newRunpath=${newRunpath//usr/runtime}
                    patchelf --set-rpath "$newRunpath" "$file"
                    echo "    FIX RUNPATH" "$file" "$runpath" "=>" "$newRunpath"
                fi
            done
            # +
            # 修复引入 kf5doctools 及其依赖后 SGML xsl XML等文件
            # 暂时仅在引入 libkf5doctools-dev 时启用
            if grep -q 'libkf5doctools-dev' "$deb_list_file"; then
                find "$data_list_dir" -type f -exec file {} \; | grep 'SGML document\|.xsl: ASCII text\|XML\|.cmake: ASCII text' | awk -F: '{print $1}' | while IFS= read -r file; do
                    sed -i "s#/usr#$ins_path#g" $file
                    echo "    FIX PATH IN TEXT" "$file"
                done
            fi
            # +/
            # 复制/lib,/bin,/usr目录
            # + 复制/etc目录
            mkdir -p "$ins_path"
            cp -rP "$data_list_dir"/lib   "$ins_path" 2>/dev/null || true
            cp -rP "$data_list_dir"/bin   "$ins_path" 2>/dev/null || true
            cp -rP "$data_list_dir"/etc   "$ins_path" 2>/dev/null || true
            cp -rP "$data_list_dir"/usr/* "$ins_path" || true
            rm -r "$data_list_dir"
        fi
    done <"$deb_list_file"

    # 复制安装记录
    cp -r "$deb_trace_dir" "$logs"
    # 清理临时目录
    rm -r "$temp_dir"
}

function uninstall() {
    if [ -z "$logs" ]; then
        logs="$PREFIX/pkg_contents"
    fi
    cd "$logs"

    ls -A | grep '.deb.list$' | grep -E "$regex" | while IFS= read -r log; do
        echo "REMOVE ${log%.deb.list*}"
        # 删除文件和符号链接
        cat "$log" | while IFS= read -r f; do
            if [ -f "$f" ] || [ -L "$f" ]; then
                rm "$f"
            fi
        done
        # 删除空文件夹
        cat "$log" | while IFS= read -r d; do
            if [ -d "$d" ]; then
                while [ "$(find "$d" -type d -empty)" ]; do
                    find "$d" -type d -empty -print0 | xargs -0 rm -r
                done
            fi
        done
    done
    # 如果启用 -D 选项则删除 logs
    if [ -n "$del_log" ]; then
        rm -r "$logs"
    fi
}

unset -v mode deb_dir path include exclude logs regex del_log

while getopts 'hiud:p:I:E:L:r:D' OPT; do
    case $OPT in
    i) mode="install" ;;
    u) mode="uninstall" ;;
    d) deb_dir="$OPTARG" ;;
    p) path="$OPTARG" ;;
    I) include="${OPTARG//\"/}" ;;
    E) exclude="${OPTARG//\"/}" ;;
    L) logs="$OPTARG" ;;
    r) regex="$OPTARG" ;;
    D) del_log="true" ;;
    h) help ;;
    ?) help ;;
    esac
done

if [ "$mode" = "install" ]; then
    install
elif [ "$mode" = "uninstall" ]; then
    uninstall
else
    help
    exit
fi

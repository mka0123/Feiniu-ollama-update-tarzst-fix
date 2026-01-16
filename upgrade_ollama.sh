#!/bin/bash

set -e
set -o pipefail

echo "🔄 Ollama 升级脚本 for FnOS（适配 tar.zst 格式）, 脚本v2.1.2"

# 0. 安装 zstd 依赖（群晖/软路由适配）
install_zstd() {
    echo "📦 检查 zstd 解压工具..."
    if ! command -v zstd &>/dev/null; then
        echo "⬇️ 安装 zstd 依赖..."
        # 适配不同系统的包管理器
        if command -v apt &>/dev/null; then
            apt update && apt install -y zstd
        elif command -v opkg &>/dev/null; then
            opkg update && opkg install zstd
        elif command -v pkg &>/dev/null; then
            pkg install -y zstd
        else
            echo "❌ 无法自动安装 zstd，请手动安装后重试"
            exit 1
        fi
    fi
    echo "✅ zstd 已就绪"
}

# 1. 查找 Ollama 安装路径
echo "🔍 查找 Ollama 安装路径..."
VOL_PREFIXES=(/vol1 /vol2 /vol3 /vol4 /vol5 /vol6 /vol7 /vol8 /vol9)
AI_INSTALLER=""

for vol in "${VOL_PREFIXES[@]}"; do
    if [ -d "$vol/@appcenter/ai_installer/ollama" ]; then
        AI_INSTALLER="$vol/@appcenter/ai_installer"
        echo "✅ 找到安装路径：$AI_INSTALLER"
        break
    fi
done

if [ -z "$AI_INSTALLER" ]; then
    for vol in "${VOL_PREFIXES[@]}"; do
        testdir="$vol/@appcenter/ai_installer"
        if [ -d "$testdir" ]; then
            cd "$testdir"
            LAST_BK=$(ls -td ollama_bk_* 2>/dev/null | head -n 1)
            if [ -n "$LAST_BK" ] && [ ! -d "ollama" ]; then
                echo "⚠️ 检测到未完成的升级，恢复备份..."
                mv "$LAST_BK" ollama
                echo "✅ 已恢复备份，请重新执行脚本"
                [ -x "./ollama/bin/ollama" ] && ./ollama/bin/ollama --version
                exit 0
            fi
        fi
    done
    echo "❌ 未找到 Ollama 安装路径"
    exit 1
fi

cd "$AI_INSTALLER"
install_zstd  # 安装解压依赖

# 2. 打印当前版本
echo "📦 检测当前 Ollama 版本..."
OLLAMA_BIN="./ollama/bin/ollama"
CLIENT_VER=""
if [ -x "$OLLAMA_BIN" ]; then
    VERSION_RAW=$($OLLAMA_BIN --version 2>&1)
    CLIENT_VER=$(echo "$VERSION_RAW" | grep -i "client version" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
    [ -n "$CLIENT_VER" ] && echo "📦 当前版本：v$CLIENT_VER" || echo "⚠️ 无法获取版本号：$VERSION_RAW"
else
    echo "❌ 未找到 ollama 可执行文件"
fi

# 3. 获取最新版本 + 适配 tar.zst 下载
FILENAME="ollama-linux-amd64.tar.zst"
echo "🌐 获取 Ollama 最新版本号..."
LATEST_TAG=$(curl -s --connect-timeout 10 --retry 3 https://github.com/ollama/ollama/releases | grep -oP '/ollama/ollama/releases/tag/\K[^"]+' | head -n 1)

if [ -z "$LATEST_TAG" ]; then
    echo "❌ 无法获取最新版本，请检查网络/代理"
    exit 1
fi
echo "📦 最新版本：$LATEST_TAG"
URL="https://github.com/ollama/ollama/releases/download/$LATEST_TAG/$FILENAME"

# 版本一致则退出
if [ "$CLIENT_VER" = "${LATEST_TAG#v}" ]; then
    echo "✅ 当前已是最新版本（v$CLIENT_VER）"
    [ -f "$FILENAME" ] && rm -f "$FILENAME"
    exit 0
fi

# 验证本地文件完整性
if [ -f "$FILENAME" ]; then
    echo "🔍 验证本地压缩包..."
    if ! zstd -t "$FILENAME" 2>/dev/null; then
        echo "❌ 本地文件损坏，重新下载"
        rm -f "$FILENAME"
    else
        echo "✅ 本地包完整，跳过下载"
    fi
fi

# 下载（多线程+重试）
if [ ! -f "$FILENAME" ]; then
    echo "⬇️ 下载 $LATEST_TAG 版本（tar.zst 格式）..."
    DOWNLOAD_SUCCESS=0
    # 优先 aria2c
    if command -v aria2c >/dev/null; then
        echo "🚀 使用 aria2c 多线程下载..."
        aria2c -x 16 -s 16 -k 1M -o "$FILENAME" --retry-wait 3 --max-tries 3 "$URL" && DOWNLOAD_SUCCESS=1
    fi
    # 备用 curl
    if [ $DOWNLOAD_SUCCESS -ne 1 ]; then
        echo "⬇️ 使用 curl 单线程下载..."
        curl -L --connect-timeout 10 --retry 3 -o "$FILENAME" "$URL" || {
            echo "❌ 下载失败！请设置代理后重试："
            echo "   export https_proxy=http://你的代理IP:端口"
            rm -f "$FILENAME"
            exit 1
        }
    fi
fi

# 4. 备份旧版本
BACKUP_NAME="ollama_bk_$(date +%Y%m%d_%H%M%S)"
mv ollama "$BACKUP_NAME"
echo "📦 已备份旧版本为：$BACKUP_NAME"

# 5. 解压 tar.zst（核心修复：替换解压命令）
echo "📦 解压 tar.zst 包..."
mkdir -p ollama
tar -I zstd -xf "$FILENAME" -C ollama --strip-components=1
rm -f "$FILENAME"  # 清理压缩包

# 6. 升级 pip 和 open-webui（容错处理）
echo "⬆️ 升级 pip 和 Open-WebUI..."
PYTHON_EXEC=""
# 适配群晖 Python 路径
if [ -d "$AI_INSTALLER/python/bin" ]; then
    PYTHON_EXEC=$(find "$AI_INSTALLER/python/bin" -name "python3.*" -executable | head -n 1)
fi
[ -z "$PYTHON_EXEC" ] && PYTHON_EXEC=$(command -v python3 || command -v python)

if [ -x "$PYTHON_EXEC" ]; then
    $PYTHON_EXEC -m pip install --upgrade pip --timeout 30 --retries 2 || echo "⚠️ pip 升级失败（不影响核心功能）"
    $PYTHON_EXEC -m pip install --upgrade open_webui --timeout 30 --retries 2 || echo "⚠️ Open-WebUI 升级失败，可手动升级"
else
    echo "⚠️ 未找到 Python，跳过 Open-WebUI 升级"
fi

# 7. 验证新版本
if [ -x "$OLLAMA_BIN" ]; then
    VERSION_RAW=$($OLLAMA_BIN --version 2>&1)
    NEW_VER=$(echo "$VERSION_RAW" | grep -i "client version" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
    [ -n "$NEW_VER" ] && echo "✅ 升级完成！新版本：v$NEW_VER" || echo "✅ 升级完成，版本信息：$VERSION_RAW"
else
    echo "❌ 解压失败，自动回滚备份..."
    mv "$BACKUP_NAME" ollama
    exit 1
fi

echo "🎉 Ollama 升级完成！请重启 Ollama 服务生效。"

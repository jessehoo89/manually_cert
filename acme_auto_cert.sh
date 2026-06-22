#!/bin/bash
#
# ACME.sh 自动申请 SSL 证书脚本
# 支持手动 DNS 验证方式申请通配符证书
#
# 使用方法:
#   ./acme_auto_cert.sh
#   或预先设置变量后执行:
#   DOMAIN="*.example.com" CERT_DEST="/path/to/cert" ./acme_auto_cert.sh
#

#############################################
# 用户配置区域 (可在此处预设值，留空则交互式输入)
#############################################

# 域名配置 (支持多个域名，用空格分隔，例如："*.example.com example.com")
DOMAIN=""

# 证书归档目录 (证书申请成功后复制到此目录)
CERT_DEST=""

# ACME 注册邮箱
ACME_EMAIL=""

# ACME 安装目录 (默认为 /opt/acme)
ACME_INSTALL_DIR="/opt/acme"

# acme.sh 默认安装路径 (acme.sh --install 的默认目标)
ACME_HOME="${ACME_HOME:-/root/.acme.sh}"

#############################################
# 脚本主体
#############################################

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查 root 权限
check_root() {
    if [ "$EUID" -ne 0 ]; then 
        log_error "此脚本需要 root 权限才能执行"
        log_error "原因:"
        log_error "  1. acme.sh 需要安装到 /root/.acme.sh"
        log_error "  2. 需要安装 cron 定时任务用于自动续期"
        log_error "  3. 证书目录可能需要 root 权限写入"
        log_error ""
        log_error "请使用以下方式运行:"
        log_error "  sudo ./acme_auto_cert.sh"
        log_error "或切换到 root 用户后运行"
        exit 1
    fi
    log_info "Root 权限检查通过 ✓"
}

# 检查并获取用户输入
get_user_input() {
    local var_name="$1"
    local prompt="$2"
    local current_value="${!var_name}"
    
    if [ -z "$current_value" ]; then
        read -p "$prompt" input_value
        if [ -z "$input_value" ]; then
            log_error "输入不能为空，请重新运行脚本并提供有效值"
            exit 1
        fi
        eval "$var_name='$input_value'"
    else
        log_info "$prompt (已预设: $current_value)"
    fi
}

# 检查依赖
check_dependencies() {
    log_info "检查系统依赖..."
    
    if ! command -v git &> /dev/null; then
        log_error "git 未安装，请先安装: apt update && apt install -y git"
        exit 1
    fi
    
    if ! command -v curl &> /dev/null; then
        log_error "curl 未安装，请先安装: apt update && apt install -y curl"
        exit 1
    fi
    
    if ! command -v socat &> /dev/null; then
        log_warn "socat 未安装，acme.sh 可能需要它，建议安装: apt update && apt install -y socat"
    fi
    
    log_info "依赖检查完成"
}

# 安装 acme.sh
install_acme() {
    # 检查 acme.sh 是否已安装 (检查默认安装路径)
    if [ -x "$ACME_HOME/acme.sh" ]; then
        log_info "检测到 acme.sh 已安装在：$ACME_HOME/acme.sh ✓"
        log_info "跳过安装步骤，使用现有环境"
        
        # 确保 acme.sh 命令可用
        export PATH="$ACME_HOME:$PATH"
        
        # 切换到 acme.sh 目录以便执行后续命令
        cd "$ACME_HOME"
        return 0
    fi
    
    # acme.sh 未安装，执行安装流程
    log_warn "未检测到 acme.sh，开始安装..."
    
    if [ -d "$ACME_INSTALL_DIR/acme.sh" ]; then
        log_info "acme.sh 源码已存在于 $ACME_INSTALL_DIR/acme.sh"
        cd "$ACME_INSTALL_DIR/acme.sh"
    else
        log_info "克隆 acme.sh 到 $ACME_INSTALL_DIR..."
        mkdir -p "$ACME_INSTALL_DIR"
        cd "$ACME_INSTALL_DIR"
        
        # 尝试使用 Gitee 镜像（国内更快），如果失败则使用 GitHub
        if ! git clone https://gitee.com/neilpang/acme.sh.git 2>/dev/null; then
            log_warn "Gitee 克隆失败，尝试 GitHub..."
            git clone https://github.com/acmesh-official/acme.sh.git
        fi
        
        cd acme.sh
    fi
    
    # 安装 acme.sh
    log_info "执行 acme.sh --install..."
    if [ -n "$ACME_EMAIL" ]; then
        ./acme.sh --install -m "$ACME_EMAIL"
    else
        ./acme.sh --install
    fi
    
    # 加载环境变量
    source ~/.bashrc 2>/dev/null || true
    
    log_info "acme.sh 安装完成 ✓"
}

# 申请证书
issue_certificate() {
    log_info "开始申请证书..."
    
    # 构建域名参数
    local domain_params=""
    for d in $DOMAIN; do
        domain_params="$domain_params -d \"$d\""
    done
    
    log_info "申请的域名: $DOMAIN"
    log_warn "============================================================"
    log_warn "请在您的 DNS 服务商处添加以下 TXT 记录:"
    log_warn "============================================================"
    
    # 首次运行，获取 DNS TXT 记录信息
    # shellcheck disable=SC2086
    ./acme.sh --issue --dns \
        --yes-i-know-dns-manual-mode-enough-go-ahead-please \
        $domain_params || true
    
    echo ""
    log_warn "============================================================"
    log_warn "请按照上述提示在 DNS 中添加 TXT 记录"
    log_warn "添加完成后，按回车键继续验证..."
    log_warn "============================================================"
    read -p "按回车键继续..."
    
    # 重新运行进行验证
    log_info "开始验证 DNS 记录..."
    # shellcheck disable=SC2086
    ./acme.sh --renew --dns \
        --yes-i-know-dns-manual-mode-enough-go-ahead-please \
        $domain_params
    
    log_info "证书申请成功!"
}

# 获取证书路径并复制到指定位置
copy_certificate() {
    log_info "获取证书路径..."
    
    # 获取第一个主域名作为证书目录标识
    local main_domain
    main_domain=$(echo "$DOMAIN" | awk '{print $1}')
    
    # 查找证书目录 (可能是 RSA 或 ECC)
    local cert_dir=""
    if [ -d "/root/.acme.sh/${main_domain}_ecc" ]; then
        cert_dir="/root/.acme.sh/${main_domain}_ecc"
        log_info "找到 ECC 证书目录: $cert_dir"
    elif [ -d "/root/.acme.sh/${main_domain}" ]; then
        cert_dir="/root/.acme.sh/${main_domain}"
        log_info "找到 RSA 证书目录: $cert_dir"
    else
        log_error "未找到证书目录，请检查证书是否申请成功"
        exit 1
    fi
    
    # 显示证书文件
    log_info "证书文件列表:"
    ls -la "$cert_dir"/*.cer "$cert_dir"/*.key 2>/dev/null || true
    
    # 复制证书到指定目录
    if [ -n "$CERT_DEST" ]; then
        log_info "复制证书到: $CERT_DEST"
        mkdir -p "$CERT_DEST"
        
        # 复制所有证书相关文件
        cp -r "$cert_dir"/* "$CERT_DEST"/
        
        log_info "证书复制完成!"
        log_info "证书文件位置: $CERT_DEST"
        echo ""
        log_info "通常包含以下文件:"
        log_info "  - *.cer (域名证书)"
        log_info "  - *.key (私钥)"
        log_info "  - ca.cer (中间证书)"
        log_info "  - fullchain.cer (完整证书链)"
    else
        log_warn "未设置证书归档目录，证书保留在: $cert_dir"
    fi
}

# 主函数
main() {
    echo "========================================"
    echo "  ACME.sh 自动证书申请脚本"
    echo "========================================"
    echo ""
    
    # 检查 root 权限
    check_root
    
    # 获取用户输入
    get_user_input "DOMAIN" "请输入要申请证书的域名 (支持多个，用空格分隔，如: *.example.com example.com): "
    get_user_input "ACME_EMAIL" "请输入 ACME 注册邮箱 (可选，直接回车跳过): "
    get_user_input "CERT_DEST" "请输入证书归档目录 (可选，直接回车跳过): "
    
    echo ""
    log_info "配置确认:"
    log_info "  域名: $DOMAIN"
    log_info "  邮箱: ${ACME_EMAIL:-未设置}"
    log_info "  证书归档目录: ${CERT_DEST:-未设置}"
    log_info "  ACME 安装目录: $ACME_INSTALL_DIR"
    log_info "  acme.sh 路径：$ACME_HOME"
    echo ""
    
    read -p "确认以上配置并开始申请？(y/n): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        log_info "已取消操作"
        exit 0
    fi
    
    # 执行流程
    check_dependencies
    install_acme
    issue_certificate
    copy_certificate
    
    echo ""
    echo "========================================"
    log_info "证书申请流程完成!"
    echo "========================================"
}

# 运行主函数
main

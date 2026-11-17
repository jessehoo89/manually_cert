#!/usr/bin/env bash
#
# ACME 手动 DNS 验证证书申请 / 续期脚本（acme.sh 封装）
#
# 适用场景：域名没有 DNS API 凭证（如 PassNAT、代理商托管域名），
#           需要泛域名证书（*.example.com），只能手动加 DNS TXT 记录验证。
#
# 用法：
#   ./acme_auto_cert.sh                                    # 交互式
#   DOMAIN="*.odn.cc *.3q.hair" CERT_DEST=/vol2/1000/cert ./acme_auto_cert.sh
#   ./acme_auto_cert.sh --renew                            # 复用上次域名/目录，只做续期
#
# 环境变量（都可省略）：
#   DOMAIN            域名，空格分隔；第一个为主域名（决定 acme.sh 目录名和续期 -d 参数）
#   CERT_DEST         证书归档目录；留空则只留在 acme.sh 目录
#   ACME_EMAIL        注册邮箱，可选（仅首次注册 ACME 账户时用）
#   ACME_SERVER       letsencrypt（默认）| zerossl
#   KEY_LENGTH        ec-256（默认）| 2048 | 4096
#   ACME_HOME         acme.sh 工作目录，默认 $HOME/.acme.sh
#   ACME_SRC          acme.sh 源码克隆目录，默认 /opt/acme，不可写时回落 ~/.acme-src
#   DNS_WAIT          等待 TXT 生效的上限秒数，默认 300
#   ALLOW_OTHER_READ=1  归档目录 755、私钥 644（给别的系统用户的服务读，如 frp/PassNAT）
#   ACME_DEBUG=1      打开 acme.sh --debug 2
#
# 退出码：0 成功；1 配置/依赖/签发失败；2 参数错误
#

set -uo pipefail

DOMAIN="${DOMAIN:-}"
CERT_DEST="${CERT_DEST:-}"
ACME_EMAIL="${ACME_EMAIL:-}"
ACME_SERVER="${ACME_SERVER:-letsencrypt}"
KEY_LENGTH="${KEY_LENGTH:-ec-256}"
ACME_HOME="${ACME_HOME:-$HOME/.acme.sh}"
ACME_SRC="${ACME_SRC:-/opt/acme}"
DNS_WAIT="${DNS_WAIT:-300}"
ALLOW_OTHER_READ="${ALLOW_OTHER_READ:-0}"
ACME_DEBUG="${ACME_DEBUG:-0}"
RENEW_ONLY=0
ACME_BIN=""

if [ -t 1 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; NC=''
fi

log_info()  { printf "${GREEN}[INFO]${NC} %s\n" "$*"; }
log_warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }
die()       { log_error "$*"; exit 1; }

usage() {
  sed -n '3,24p' "$0" | sed 's/^# *//'
}

#############################################
# 参数与配置
#############################################

parse_args() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --renew)  RENEW_ONLY=1 ;;
      -h|--help) usage; exit 0 ;;
      *) printf '未知参数：%s\n' "$arg" >&2; usage >&2; exit 2 ;;
    esac
  done
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

# 安全赋值：不用 eval，避免输入里的引号/分号被当成代码执行
prompt_value() {
  local var="$1" prompt="$2" optional="${3:-0}"
  local current="${!var:-}"
  local input=""

  if [ -n "$current" ]; then
    log_info "$prompt（已预设：$current）"
    return 0
  fi
  if ! read -r -p "$prompt" input; then
    input=""
  fi
  if [ -z "$input" ]; then
    if [ "$optional" = "1" ]; then
      printf -v "$var" '%s' ""
      return 0
    fi
    die "该项不能为空"
  fi
  printf -v "$var" '%s' "$input"
}

main_domain() { printf '%s' "${DOMAIN%% *}"; }

is_ecc() {
  case "$KEY_LENGTH" in
    ec*) return 0 ;;
    *)   return 1 ;;
  esac
}

cert_dir() {
  local m; m="$(main_domain)"
  if is_ecc; then
    printf '%s/%s_ecc\n' "$ACME_HOME" "$m"
  else
    printf '%s/%s\n' "$ACME_HOME" "$m"
  fi
}

state_file() { printf '%s\n' "$ACME_HOME/.manual_cert_state"; }

save_state() {
  mkdir -p "$ACME_HOME" || die "无法创建 $ACME_HOME"
  {
    printf 'DOMAIN=%q\n' "$DOMAIN"
    printf 'CERT_DEST=%q\n' "$CERT_DEST"
    printf 'ACME_SERVER=%q\n' "$ACME_SERVER"
    printf 'KEY_LENGTH=%q\n' "$KEY_LENGTH"
  } > "$(state_file)"
}

load_state() {
  local f; f="$(state_file)"
  [ -f "$f" ] || return 1
  # shellcheck disable=SC1090
  . "$f"
  return 0
}

#############################################
# acme.sh 安装 / 复用
#############################################

setup_acme() {
  if [ -x "$ACME_HOME/acme.sh" ]; then
    ACME_BIN="$ACME_HOME/acme.sh"
    log_info "复用已安装的 acme.sh：$ACME_BIN"
    return 0
  fi

  log_info "未检测到 acme.sh，准备安装到 $ACME_HOME"
  local src="$ACME_SRC"
  if ! mkdir -p "$src" 2>/dev/null; then
    src="$HOME/.acme-src"
    mkdir -p "$src" || die "无法创建源码目录（$ACME_SRC 与 $src 都不可写）"
    log_warn "$ACME_SRC 不可写，改用 $src"
  fi

  local repo_dir="$src/acme.sh"
  if [ ! -d "$repo_dir/.git" ]; then
    [ -e "$repo_dir" ] && die "$repo_dir 已存在但不是 git 仓库，请先清理"
    has_cmd git || die "git 未安装：apt install -y git"
    log_info "克隆 acme.sh（优先 Gitee 镜像，失败回落 GitHub 官方）"
    if ! git clone -q --depth 1 https://gitee.com/neilpang/acme.sh.git "$repo_dir" 2>/dev/null; then
      git clone -q --depth 1 https://github.com/acmesh-official/acme.sh.git "$repo_dir" \
        || die "克隆 acme.sh 失败（Gitee 与 GitHub 都不可达）"
    fi
  fi

  local -a iargs=(--install --nocron --no-profile)
  [ -n "$ACME_EMAIL" ] && iargs+=(-m "$ACME_EMAIL")

  log_info "执行 acme.sh 安装（不装 cron：手动 DNS 模式本来就不能自动续期）"
  ( cd "$repo_dir" && LE_WORKING_DIR="$ACME_HOME" ./acme.sh "${iargs[@]}" ) \
    || die "acme.sh 安装失败"

  if [ -x "$ACME_HOME/acme.sh" ]; then
    ACME_BIN="$ACME_HOME/acme.sh"
  elif [ -x "$HOME/.acme.sh/acme.sh" ]; then
    ACME_HOME="$HOME/.acme.sh"
    ACME_BIN="$ACME_HOME/acme.sh"
    log_warn "安装落到了 $ACME_HOME，已改用该路径"
  else
    die "安装后仍找不到 acme.sh"
  fi
}

#############################################
# 申请：手动 DNS 两步法
#############################################

print_records() {
  local log="$1"
  awk -F"'" '
    /Domain: /   { name=$2 }
    /TXT value:/ { if (name != "") printf "  %s\n    → TXT 值：%s\n", name, $2 }
  ' "$log"
}

wait_one_record() {
  local name="$1" want="$2" waited=0 step=5
  if ! has_cmd dig; then
    log_warn "无 dig，跳过 $name 的 TXT 生效检查"
    return 0
  fi
  while [ "$waited" -lt "$DNS_WAIT" ]; do
    if dig +short TXT "$name" 2>/dev/null | tr -d '"' | grep -Fxq "$want"; then
      log_info "TXT 已生效：$name"
      return 0
    fi
    sleep "$step"
    waited=$((waited + step))
    [ "$waited" -eq 20 ] && log_warn "仍在等待 $name 的 TXT 生效…"
  done
  log_error "$name 的 TXT 在 ${DNS_WAIT}s 内未生效"
  return 1
}

check_records() {
  local log="$1" rc=0 name value
  while IFS=$'\t' read -r name value; do
    [ -n "$name" ] || continue
    wait_one_record "$name" "$value" || rc=1
  done < <(awk -F"'" '/Domain: /{name=$2} /TXT value:/{print name "\t" $2}' "$log")
  return "$rc"
}

issue_cert() {
  local -a dargs=() cargs=()
  local d
  # 注意：这里 $DOMAIN 故意不整体加引号，按空格切分；每个域名单独成数组元素，
  #       绝不能拼成 "-d \"$d\"" 再展开——那样引号会变成域名字符串的一部分。
  for d in $DOMAIN; do
    dargs+=(-d "$d")
  done

  cargs=(--server "$ACME_SERVER" --keylength "$KEY_LENGTH" --dns
         --yes-I-know-dns-manual-mode-enough-go-ahead-please)
  [ "$ACME_DEBUG" = "1" ] && cargs+=(--debug 2)
  [ "$RENEW_ONLY" = "1" ] && cargs+=(--force)

  local log; log="$(mktemp -t acme_issue.XXXXXX)"
  local rc
  log_info "运行：$ACME_BIN --issue ${dargs[*]} ${cargs[*]}"
  "$ACME_BIN" --issue "${dargs[@]}" "${cargs[@]}" 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}

  case "$rc" in
    0) log_info "证书已签发（acme.sh 退出码 0）" ;;
    3)
      log_warn "手动 DNS 模式：退出码 3 = 正常，等待你添加 TXT 记录"
      echo
      log_warn "====== 请在 DNS 服务商处添加以下 TXT 记录 ======"
      print_records "$log"
      log_warn "================================================"
      printf '添加完成后按回车继续（Ctrl-C 放弃）：'
      read -r _ || true
      if ! check_records "$log"; then
        printf 'TXT 尚未生效，仍要继续验证？(y/N) '
        read -r ans || ans=""
        case "$ans" in y|Y) ;; *) die "已取消（记录未生效）" ;; esac
      fi
      ;;
    *) die "acme.sh 申请失败（退出码 $rc），完整日志：$log" ;;
  esac
  echo
}

renew_cert() {
  local -a cargs=(--renew -d "$(main_domain)" --force --server "$ACME_SERVER"
                  --yes-I-know-dns-manual-mode-enough-go-ahead-please)
  is_ecc && cargs+=(--ecc)
  log_info "运行：$ACME_BIN ${cargs[*]}"
  "$ACME_BIN" "${cargs[@]}" || die "续期/验证失败"
  echo
}

#############################################
# 校验与归档
#############################################

verify_cert() {
  local dir; dir="$(cert_dir)"
  local m; m="$(main_domain)"

  [ -f "$dir/fullchain.cer" ] || die "没找到 $dir/fullchain.cer，签发可能未完成"
  [ -f "$dir/$m.key" ] || die "没找到私钥 $dir/$m.key"
  if ! has_cmd openssl; then
    log_warn "无 openssl，跳过证书自检"
    return 0
  fi

  log_info "证书自检"
  openssl x509 -in "$dir/fullchain.cer" -noout -subject -issuer -dates \
    -ext subjectAltName 2>/dev/null | sed 's/^/  /'

  local a b
  a="$(openssl x509 -in "$dir/$m.cer" -noout -pubkey 2>/dev/null | openssl md5 2>/dev/null)"
  b="$(openssl pkey -in "$dir/$m.key" -pubout 2>/dev/null | openssl md5 2>/dev/null)"
  if [ -n "$a" ] && [ "$a" = "$b" ]; then
    log_info "私钥与证书匹配 ✓"
  else
    log_error "私钥与证书不匹配 ✗"
    return 1
  fi
  return 0
}

copy_out() {
  local dir; dir="$(cert_dir)"
  local m; m="$(main_domain)"

  if [ -z "$CERT_DEST" ]; then
    log_warn "未设置 CERT_DEST，证书保留在：$dir"
    return 0
  fi

  mkdir -p "$CERT_DEST" || die "无法创建 $CERT_DEST"
  local bdir="$CERT_DEST/Backup" today f
  today="$(date +%F)"

  for f in "$m.cer" "$m.leaf.cer" "$m.key" "fullchain.cer" "ca.cer"; do
    if [ -f "$CERT_DEST/$f" ]; then
      mkdir -p "$bdir"
      cp -a "$CERT_DEST/$f" "$bdir/${f}_$today" && log_info "备份旧文件：${f}_$today"
    fi
  done

  cp -f "$dir/$m.cer"        "$CERT_DEST/$m.leaf.cer" || die "复制叶子证书失败"
  cp -f "$dir/fullchain.cer" "$CERT_DEST/$m.cer"      || die "复制证书链失败"
  cp -f "$dir/fullchain.cer" "$CERT_DEST/fullchain.cer" || die "复制 fullchain 失败"
  cp -f "$dir/ca.cer"        "$CERT_DEST/ca.cer"      || die "复制中间证书失败"
  cp -f "$dir/$m.key"        "$CERT_DEST/$m.key"      || die "复制私钥失败"

  if [ "$ALLOW_OTHER_READ" = "1" ]; then
    chmod 755 "$CERT_DEST"
    chmod 644 "$CERT_DEST/$m.key"
    log_info "已按 ALLOW_OTHER_READ=1 放开：目录 755、私钥 644"
  else
    chmod 700 "$CERT_DEST"
    chmod 600 "$CERT_DEST/$m.key"
  fi
  chmod 644 "$CERT_DEST/$m.cer" "$CERT_DEST/$m.leaf.cer" \
            "$CERT_DEST/fullchain.cer" "$CERT_DEST/ca.cer" 2>/dev/null

  log_info "已归档到 $CERT_DEST"
  ls -l "$CERT_DEST" | sed 's/^/  /'
}

summary() {
  local m; m="$(main_domain)"
  echo
  log_info "完成。文件名说明（归档目录内）："
  echo "  $m.cer        完整证书链（含中间证书，frp / nginx 直接指这个）"
  echo "  $m.leaf.cer   仅叶子证书（有客户端只接受单张证书时才用）"
  echo "  $m.key        私钥"
  echo "  ca.cer        中间 CA"
  echo "  fullchain.cer 与 $m.cer 内容相同"
  echo
  log_warn "手动 DNS 模式无法自动续期；到期前重跑：$(basename "$0") --renew（或指定同一 DOMAIN/CERT_DEST）"
}

#############################################
# 主流程
#############################################

main() {
  parse_args "$@"

  if [ "$RENEW_ONLY" = "1" ]; then
    load_state || die "没有上次配置记录（$ACME_HOME/.manual_cert_state），无法只续期"
    log_info "复用上次配置：DOMAIN=$DOMAIN CERT_DEST=${CERT_DEST:-<空>}"
  else
    prompt_value DOMAIN "要申请的域名（多个用空格分隔，例：*.odn.cc *.3q.hair）：" 0
    prompt_value ACME_EMAIL "ACME 注册邮箱（可留空）：" 1
    prompt_value CERT_DEST "证书归档目录（可留空）：" 1
    echo
    log_info "配置确认："
    echo "  域名：$DOMAIN"
    echo "  邮箱：${ACME_EMAIL:-<未设置>}"
    echo "  归档目录：${CERT_DEST:-<未设置>}"
    echo "  CA：$ACME_SERVER   密钥：$KEY_LENGTH   acme.sh：$ACME_HOME"
    printf '确认并开始？(y/N) '
    read -r confirm || confirm=""
    case "$confirm" in y|Y) ;; *) log_info "已取消"; exit 0 ;; esac
    save_state
  fi

  setup_acme
  if [ "$RENEW_ONLY" = "1" ]; then
    renew_cert
  else
    issue_cert
    renew_cert
  fi

  verify_cert || die "证书自检未通过"
  copy_out
  summary
}

main "$@"

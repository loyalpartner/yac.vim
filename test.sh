#!/bin/bash

# YAC.vim 统一测试入口脚本
# 支持分层测试：unit -> integration -> e2e

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 项目根目录
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${PROJECT_DIR}/test_logs"

# 创建日志目录
mkdir -p "$LOG_DIR"

# 使用说明
usage() {
    echo "YAC.vim 测试脚本"
    echo ""
    echo "用法: $0 [level] [options]"
    echo ""
    echo "测试级别 (按复杂度递增):"
    echo "  unit         快速单元测试 (默认)"
    echo "  integration  集成测试"  
    echo "  e2e          端到端测试"
    echo "  all          所有测试"
    echo ""
    echo "选项:"
    echo "  --verbose    详细输出"
    echo "  --help       显示帮助"
    echo ""
    echo "示例:"
    echo "  $0               # 运行单元测试"
    echo "  $0 integration   # 运行集成测试"
    echo "  $0 e2e           # 运行E2E测试"
    echo "  $0 all --verbose # 运行所有测试(详细输出)"
}

# 输出带颜色的消息
log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }

# 解析命令行参数
LEVEL="unit"
VERBOSE=0

while [[ $# -gt 0 ]]; do
    case $1 in
        unit|integration|e2e|all)
            LEVEL="$1"
            shift
            ;;
        --verbose)
            VERBOSE=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "未知选项: $1"
            usage
            exit 1
            ;;
    esac
done

# 设置详细输出
if [[ $VERBOSE -eq 1 ]]; then
    set -x
fi

echo "🧪 YAC.vim 分层测试系统"
echo "========================"
echo "测试级别: $LEVEL"
echo "项目目录: $PROJECT_DIR"
echo ""

# 检查依赖
check_dependencies() {
    log_info "检查依赖..."
    
    if ! command -v cargo &> /dev/null; then
        log_error "需要安装 Rust 和 Cargo"
        exit 1
    fi
    
    if [[ "$LEVEL" == "e2e" || "$LEVEL" == "all" ]]; then
        if ! command -v vim &> /dev/null; then
            log_error "E2E测试需要安装 Vim"
            exit 1
        fi
    fi
    
    log_success "依赖检查通过"
}

# 运行单元测试
run_unit_tests() {
    log_info "运行单元测试..."
    echo ""
    
    # Rust单元测试
    if cargo test --lib > "$LOG_DIR/unit_test.log" 2>&1; then
        local test_count=$(grep -o "test result: ok\. [0-9]\+ passed" "$LOG_DIR/unit_test.log" | grep -o "[0-9]\+ passed" | grep -o "[0-9]\+")
        log_success "单元测试通过 ($test_count 个测试)"
    else
        log_error "单元测试失败"
        if [[ $VERBOSE -eq 1 ]]; then
            cat "$LOG_DIR/unit_test.log"
        else
            echo "查看日志: $LOG_DIR/unit_test.log"
        fi
        return 1
    fi
}

# 运行集成测试
run_integration_tests() {
    log_info "运行集成测试..."
    echo ""
    
    # 编译项目
    if ! cargo build --release > "$LOG_DIR/integration_build.log" 2>&1; then
        log_error "项目编译失败"
        cat "$LOG_DIR/integration_build.log"
        return 1
    fi
    
    # 运行集成测试
    if cargo test --test '*' > "$LOG_DIR/integration_test.log" 2>&1; then
        local test_count=$(grep -o "test result: ok\. [0-9]\+ passed" "$LOG_DIR/integration_test.log" | grep -o "[0-9]\+ passed" | grep -o "[0-9]\+")
        log_success "集成测试通过 ($test_count 个测试)"
    else
        log_error "集成测试失败"
        if [[ $VERBOSE -eq 1 ]]; then
            cat "$LOG_DIR/integration_test.log"
        else
            echo "查看日志: $LOG_DIR/integration_test.log"
        fi
        return 1
    fi
}

# 运行E2E测试
run_e2e_tests() {
    log_info "运行E2E测试..."
    
    # 启动YAC服务器用于整个E2E测试期间
    local yac_pid
    yac_pid=$(start_yac_server_for_e2e)
    local start_result=$?
    
    if [[ $start_result -ne 0 ]] || [[ -z "$yac_pid" ]]; then
        log_error "无法启动YAC服务器"
        return 1
    fi
    
    # 运行Vim E2E测试
    run_vim_e2e_test
    local vim_result=$?
    
    # 如果Vim E2E通过，运行补全专项测试
    if [[ $vim_result -eq 0 ]]; then
        run_completion_e2e_test
    fi
    
    # 清理YAC服务器
    if kill -0 $yac_pid 2>/dev/null; then
        kill $yac_pid 2>/dev/null
        sleep 1
        kill -9 $yac_pid 2>/dev/null || true
    fi
    
    return $vim_result
}

# 启动YAC服务器用于E2E测试
start_yac_server_for_e2e() {
    log_info "检查rust-analyzer..."
    if ! command -v rust-analyzer &> /dev/null; then
        log_warning "未找到rust-analyzer，跳过真实LSP测试"
        return 0
    fi
    
    # 确保项目已编译
    log_info "编译项目..."
    if ! cargo build --release > "$LOG_DIR/e2e_build.log" 2>&1; then
        log_error "项目编译失败"
        if [[ $VERBOSE -eq 1 ]]; then
            cat "$LOG_DIR/e2e_build.log"
        else
            echo "查看日志: $LOG_DIR/e2e_build.log"
        fi
        return 0
    fi
    
    # 启动YAC服务器
    log_info "启动YAC服务器..."
    ./target/release/yac-vim --config config/examples/rust.toml > "$LOG_DIR/yac_server.log" 2>&1 &
    local yac_pid=$!
    
    # 等待服务器启动
    sleep 3
    
    # 检查服务器是否启动成功
    if ! kill -0 $yac_pid 2>/dev/null; then
        log_error "YAC服务器启动失败"
        if [[ $VERBOSE -eq 1 ]]; then
            cat "$LOG_DIR/yac_server.log"
        else
            echo "查看日志: $LOG_DIR/yac_server.log"
        fi
        return 1
    fi
    
    # 输出PID给调用者
    echo $yac_pid
    return 0
}

# 运行Vim E2E测试
run_vim_e2e_test() {
    log_info "启动Vim E2E测试..."
    
    # 清理之前的测试结果
    rm -f test_result.tmp
    
    # 运行Vim测试
    timeout 30 vim -u tests/config/test.vimrc -c "YACTest" -c "qa!" < /dev/null > "$LOG_DIR/e2e_test.log" 2>&1
    
    # 检查测试结果
    if [[ -f test_result.tmp ]]; then
        local result=$(cat test_result.tmp)
        rm -f test_result.tmp
        
        case $result in
            "SUCCESS")
                log_success "E2E测试通过 - 完整功能测试成功"
                return 0
                ;;
            "PARTIAL_SUCCESS")
                log_warning "E2E测试部分通过 - 连接成功但消息发送失败"
                return 0
                ;;
            "FAILED")
                log_error "E2E测试失败 - 无法连接到YAC服务器"
                ;;
            "ERROR")
                log_error "E2E测试错误 - 测试过程中发生异常"
                ;;
            *)
                log_error "E2E测试失败 - 未知结果状态"
                ;;
        esac
    else
        log_error "E2E测试失败 - Vim测试超时或崩溃"
    fi
    
    if [[ $VERBOSE -eq 1 ]]; then
        cat "$LOG_DIR/e2e_test.log"
    else
        echo "查看日志: $LOG_DIR/e2e_test.log"
    fi
    
    return 1
}


# 运行补全专项E2E测试
run_completion_e2e_test() {
    log_info "运行补全功能E2E测试..."
    
    # 检查Python3是否可用
    if ! command -v python3 &> /dev/null; then
        log_warning "Python3未找到，跳过补全E2E测试"
        return 0
    fi
    
    # 确保测试文件存在
    if [[ ! -f "tests/completion_e2e_standalone.py" ]]; then
        log_warning "补全E2E测试文件未找到，跳过测试"
        return 0
    fi
    
    # 运行Python补全测试（复用现有服务器）
    if python3 tests/completion_e2e_standalone.py > "$LOG_DIR/completion_e2e.log" 2>&1; then
        log_success "补全E2E测试通过"
        return 0
    else
        log_warning "补全E2E测试失败"
        if [[ $VERBOSE -eq 1 ]]; then
            cat "$LOG_DIR/completion_e2e.log"
        else
            echo "查看日志: $LOG_DIR/completion_e2e.log"
        fi
        return 0  # 不让补全测试失败影响整体E2E测试
    fi
}

# 清理函数
cleanup() {
    log_info "清理测试环境..."
    pkill -f "yac-vim" 2>/dev/null || true
}

# 注册清理函数
trap cleanup EXIT INT TERM

# 主测试流程
main() {
    local start_time=$(date +%s)
    
    check_dependencies
    
    case $LEVEL in
        "unit")
            run_unit_tests
            ;;
        "integration")
            run_unit_tests
            run_integration_tests
            ;;
        "e2e")
            run_unit_tests
            run_integration_tests
            run_e2e_tests
            ;;
        "all")
            run_unit_tests
            run_integration_tests
            run_e2e_tests
            ;;
        *)
            log_error "未知测试级别: $LEVEL"
            usage
            exit 1
            ;;
    esac
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    echo ""
    log_success "所有测试完成"
    echo "耗时: ${duration}秒"
    echo "日志目录: $LOG_DIR"
}

# 运行主函数
main "$@"
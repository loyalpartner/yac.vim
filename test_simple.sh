#!/bin/bash

# YAC.vim 快速测试脚本
# 调用统一测试入口的单元测试级别

echo "🚀 YAC.vim 快速测试 (调用统一测试系统)"
echo "======================================="
echo ""

# 调用主测试脚本的单元测试级别
exec $(dirname "$0")/test.sh unit "$@"
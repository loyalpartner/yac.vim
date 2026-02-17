#!/usr/bin/env python3
"""
YAC E2E Test Runner

驱动无头 Vim 执行 E2E 测试并收集结果。

用法:
    python3 tests/run_e2e.py                    # 运行所有测试
    python3 tests/run_e2e.py test_goto          # 运行特定测试
    python3 tests/run_e2e.py --list             # 列出所有测试
    python3 tests/run_e2e.py --verbose          # 详细输出
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional


@dataclass
class TestResult:
    """单个测试结果"""
    name: str
    status: str  # 'pass', 'fail', 'skip', 'error'
    reason: Optional[str] = None
    duration: float = 0.0


@dataclass
class SuiteResult:
    """测试套件结果"""
    suite: str
    tests: list
    passed: int
    failed: int
    skipped: int
    duration: float
    success: bool
    output: str = ""


class VimE2ERunner:
    """Vim E2E 测试运行器"""

    def __init__(self, project_root: Path, verbose: bool = False):
        self.project_root = project_root
        self.verbose = verbose
        self.vim_cmd = self._find_vim()
        self.test_dir = project_root / "tests" / "vim"

    def _find_vim(self) -> str:
        """查找 Vim 可执行文件"""
        for cmd in ["vim", "/usr/bin/vim", "/usr/local/bin/vim"]:
            try:
                result = subprocess.run(
                    [cmd, "--version"],
                    capture_output=True,
                    timeout=5
                )
                if result.returncode == 0:
                    return cmd
            except (subprocess.SubprocessError, FileNotFoundError):
                continue
        raise RuntimeError("Vim not found")

    def _check_prerequisites(self) -> bool:
        """检查测试先决条件"""
        # 检查 lsp-bridge 是否已编译（Zig 主路径）
        bridge_path = self.project_root / "zig-out" / "bin" / "lsp-bridge"
        if not bridge_path.exists():
            print("WARNING: lsp-bridge not built, run 'zig build' first")
            return False

        return True

    def list_tests(self) -> list:
        """列出所有测试文件"""
        tests = []
        for f in self.test_dir.glob("test_*.vim"):
            tests.append(f.stem)
        return sorted(tests)

    def run_test(self, test_name: str, timeout: int = 60) -> SuiteResult:
        """运行单个测试"""
        test_file = self.test_dir / f"{test_name}.vim"
        if not test_file.exists():
            return SuiteResult(
                suite=test_name,
                tests=[],
                passed=0,
                failed=1,
                skipped=0,
                duration=0,
                success=False,
                output=f"Test file not found: {test_file}"
            )

        start_time = time.time()

        # 输出文件
        output_file = Path(f"/tmp/yac_test_{test_name}_{os.getpid()}.txt")

        # 构建 Vim 命令（使用 -es 静默模式）
        vimrc = self.project_root / "vimrc"
        cmd = [
            self.vim_cmd,
            "-N",                       # nocompatible
            "-u", str(vimrc),           # 使用项目 vimrc
            "-U", "NONE",               # 无 gvimrc
            "-es",                      # 静默 ex 模式
            "-c", "set noswapfile",
            "-c", "set nobackup",
            "-c", f"source {test_file}",
            "-c", "qa!",                # 测试完成后退出
        ]

        env = os.environ.copy()
        env["YAC_TEST_OUTPUT"] = str(output_file)

        if self.verbose:
            print(f"Running: {' '.join(cmd)}")

        try:
            result = subprocess.run(
                cmd,
                cwd=self.project_root,
                capture_output=True,
                text=True,
                timeout=timeout,
                env=env
            )
            # 从输出文件读取结果
            if output_file.exists():
                output = output_file.read_text()
                output_file.unlink()  # 清理
            else:
                output = result.stdout + result.stderr
        except subprocess.TimeoutExpired:
            if output_file.exists():
                output_file.unlink()
            return SuiteResult(
                suite=test_name,
                tests=[],
                passed=0,
                failed=1,
                skipped=0,
                duration=timeout,
                success=False,
                output=f"Test timed out after {timeout}s"
            )
        except Exception as e:
            if output_file.exists():
                output_file.unlink()
            return SuiteResult(
                suite=test_name,
                tests=[],
                passed=0,
                failed=1,
                skipped=0,
                duration=time.time() - start_time,
                success=False,
                output=str(e)
            )

        duration = time.time() - start_time

        # 解析测试结果
        return self._parse_output(test_name, output, duration)

    def _parse_output(self, suite: str, output: str, duration: float) -> SuiteResult:
        """解析测试输出"""
        # 查找 JSON 结果标记
        match = re.search(r'::YAC_TEST_RESULT::(.+)$', output, re.MULTILINE)
        if match:
            try:
                data = json.loads(match.group(1))
                return SuiteResult(
                    suite=data.get("suite", suite),
                    tests=data.get("tests", []),
                    passed=data.get("passed", 0),
                    failed=data.get("failed", 0),
                    skipped=0,
                    duration=data.get("duration", duration),
                    success=data.get("success", False),
                    output=output
                )
            except json.JSONDecodeError:
                pass

        # 回退：从输出文本解析
        passed = len(re.findall(r'\[PASS\]', output))
        failed = len(re.findall(r'\[FAIL\]', output))

        return SuiteResult(
            suite=suite,
            tests=[],
            passed=passed,
            failed=failed,
            skipped=0,
            duration=duration,
            success=failed == 0 and passed > 0,
            output=output
        )

    def run_all(self, pattern: Optional[str] = None) -> list:
        """运行所有测试"""
        tests = self.list_tests()
        if pattern:
            tests = [t for t in tests if pattern in t]

        results = []
        for test in tests:
            print(f"\n{'='*60}")
            print(f"Running: {test}")
            print('='*60)

            result = self.run_test(test)
            results.append(result)

            if self.verbose:
                print(result.output)

            status = "PASS" if result.success else "FAIL"
            print(f"Result: {status} (passed={result.passed}, failed={result.failed})")

        return results

    def print_summary(self, results: list) -> bool:
        """打印测试摘要"""
        total_passed = sum(r.passed for r in results)
        total_failed = sum(r.failed for r in results)
        total_duration = sum(r.duration for r in results)
        all_success = all(r.success for r in results)

        print("\n" + "="*60)
        print("E2E TEST SUMMARY")
        print("="*60)
        print(f"Suites:   {len(results)}")
        print(f"Passed:   {total_passed}")
        print(f"Failed:   {total_failed}")
        print(f"Duration: {total_duration:.1f}s")
        print("="*60)

        if all_success:
            print("ALL TESTS PASSED")
        else:
            print("SOME TESTS FAILED")
            for r in results:
                if not r.success:
                    print(f"  - {r.suite}: {r.failed} failures")

        return all_success


def main():
    parser = argparse.ArgumentParser(description="YAC E2E Test Runner")
    parser.add_argument("tests", nargs="*", help="Specific tests to run")
    parser.add_argument("--list", action="store_true", help="List available tests")
    parser.add_argument("--verbose", "-v", action="store_true", help="Verbose output")
    parser.add_argument("--timeout", type=int, default=60, help="Test timeout in seconds")
    args = parser.parse_args()

    # 确定项目根目录
    script_dir = Path(__file__).parent
    project_root = script_dir.parent

    runner = VimE2ERunner(project_root, verbose=args.verbose)

    if args.list:
        tests = runner.list_tests()
        print("Available tests:")
        for t in tests:
            print(f"  - {t}")
        return 0

    # 检查先决条件
    runner._check_prerequisites()

    # 运行测试
    if args.tests:
        results = []
        for test in args.tests:
            result = runner.run_test(test, timeout=args.timeout)
            results.append(result)
            if args.verbose:
                print(result.output)
    else:
        results = runner.run_all()

    # 打印摘要
    success = runner.print_summary(results)

    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())

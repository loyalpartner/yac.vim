#!/usr/bin/env python3
"""
独立的补全E2E测试 - 复用现有的YAC服务器
"""

import json
import socket
import time
import os

def test_completion_with_existing_server():
    """测试与现有YAC服务器的补全功能"""
    print("🧪 补全E2E测试（复用服务器）")
    
    # 检查服务器是否运行
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(2)
        sock.connect(("127.0.0.1", 9527))
        print("✅ 连接到现有YAC服务器")
    except Exception as e:
        print(f"❌ 无法连接到YAC服务器: {e}")
        return False
    
    def send_lsp_message(message):
        content = json.dumps(message)
        lsp_message = f"Content-Length: {len(content)}\r\n\r\n{content}"
        sock.send(lsp_message.encode())
    
    def receive_lsp_message():
        try:
            headers = b""
            while b"\r\n\r\n" not in headers:
                chunk = sock.recv(1)
                if not chunk:
                    return None
                headers += chunk
            
            header_text = headers.decode().strip()
            content_length = 0
            for line in header_text.split("\r\n"):
                if line.startswith("Content-Length:"):
                    content_length = int(line.split(":")[1].strip())
                    break
            
            content = b""
            while len(content) < content_length:
                chunk = sock.recv(content_length - len(content))
                if not chunk:
                    return None
                content += chunk
            
            return json.loads(content.decode())
        except Exception:
            return None
    
    try:
        # 1. 客户端连接
        send_lsp_message({
            "jsonrpc": "2.0",
            "method": "client_connect",
            "params": {
                "client_info": {"name": "e2e_test", "version": "1.0", "pid": os.getpid()},
                "capabilities": {"completion": True}
            }
        })
        print("📡 客户端连接已发送")
        
        # 2. 打开测试文件
        project_root = os.path.abspath(".")
        file_uri = f"file://{project_root}/tests/fixtures/src/lib.rs"
        
        with open("tests/fixtures/src/lib.rs", "r") as f:
            content = f.read()
        
        send_lsp_message({
            "jsonrpc": "2.0",
            "method": "file_opened",
            "params": {
                "uri": file_uri,
                "language_id": "rust",
                "version": 1,
                "content": content
            }
        })
        print("📁 文件打开已发送")
        
        time.sleep(2)  # 等待LSP分析
        
        # 3. 发送补全请求
        send_lsp_message({
            "jsonrpc": "2.0",
            "id": "e2e_completion_test",
            "method": "completion",
            "params": {
                "uri": file_uri,
                "position": {"line": 9, "character": 8},  # vec.push(1)行的vec.位置
                "context": {"trigger_kind": 2, "trigger_character": "."}
            }
        })
        print("🔍 补全请求已发送")
        
        # 4. 等待响应
        start_time = time.time()
        while time.time() - start_time < 5:
            response = receive_lsp_message()
            if response and response.get("method") == "show_completion":
                items = response.get("params", {}).get("items", [])
                print(f"✅ 收到补全响应：{len(items)} 个项目")
                
                if len(items) > 0:
                    # 检查是否包含期望的Vec方法
                    labels = [item.get("label", "") for item in items]
                    vec_methods = ["push", "len", "capacity", "pop"]
                    found_methods = [method for method in vec_methods if any(method in label for label in labels)]
                    
                    print(f"🎯 找到Vec方法: {found_methods}")
                    if len(found_methods) >= 2:  # 至少找到2个Vec方法
                        print("✅ 补全测试通过")
                        return True
                    else:
                        print("⚠️ 补全项目不符合预期")
                        return False
                else:
                    print("❌ 无补全项")
                    return False
        
        print("⏰ 补全请求超时")
        return False
        
    finally:
        sock.close()

if __name__ == "__main__":
    success = test_completion_with_existing_server()
    exit(0 if success else 1)
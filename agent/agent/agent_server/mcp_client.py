import os
from pathlib import Path
from dotenv import load_dotenv
from langchain_mcp_adapters.client import MultiServerMCPClient

BASE_DIR = Path(__file__).resolve().parent.parent
load_dotenv(BASE_DIR / ".env")

MCP_TRANSPORT = os.getenv("MCP_TRANSPORT", "stdio").lower()
MCP_SERVER_URL = os.getenv("MCP_SERVER_URL", "http://127.0.0.1:8002/sse")
MCP_PATH = os.getenv("MCP_PATH", r"C:\Users\AISW-509-206\anaconda3\envs\mcp\python.exe")

MCP_MAIN_SCRIPT = os.path.join(BASE_DIR.parent, "MCP_server", "main.py")

# 전역 클라이언트 인스턴스
_mcp_client = None

async def get_mcp_tools():
    """
    설정된 통신 방식(MCP_TRANSPORT)에 따라 Tools를 반환합니다.
    """
    global _mcp_client
    
    if _mcp_client is not None:
        return await _mcp_client.get_tools()

    if MCP_TRANSPORT == "sse":
        config = {
            "desktop-pet-tools": {
                "url": MCP_SERVER_URL,
                "transport": "sse",
            }
        }
    else:
        # stdio 방식을 위해 mcp 파이썬 환경 절대 경로 사용 (Windows conda run IO 버퍼링 문제 회피)
        config = {
            # "desktop-pet-tools": {
            #     "command": MCP_PATH,
            #     "args": [MCP_MAIN_SCRIPT],
            #     "transport": "stdio",
            # }
            "windows-mcp": {
                "command": MCP_PATH,
                "args": ["-m", "windows_mcp"],
                "transport": "stdio",
                "env": {
                    "ANONYMIZED_TELEMETRY": "false"
                }
            }
        }

    _mcp_client = MultiServerMCPClient(config)
    
    return await _mcp_client.get_tools()

def get_mcp_client():
    """현재 유지되고 있는 클라이언트를 반환합니다. (직접 호출할 때 필요)"""
    return _mcp_client

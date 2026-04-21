import json
import base64
from io import BytesIO

import pyautogui
from mcp.server.fastmcp import FastMCP

from tools.monitor_tool import get_screen_info, capture_and_ocr
from tools.filesystem_tool import list_directory, read_file, write_file, delete_file
from tools.system_monitor import get_cpu_usage, get_memory_usage, get_disk_usage, list_processes
from tools.web_serch_tool import search_web

# ==========================================
# MCP_server/main.py — MCP 서버 진입점
#
# FastMCP(stdio 방식)로 구현된 툴 서버입니다.
# Agent Server가 langchain-mcp-adapters의 MultiServerMCPClient를 통해
# 이 서버를 실행하고, stdio로 통신합니다.
#
# 각 @mcp.tool() 함수는 tools/ 디렉터리의 순수 Python 모듈에 구현된
# 로직 함수를 호출하여 결과를 반환합니다.
# ==========================================

mcp = FastMCP("desktop-pet-tools")


# ==========================================
# Monitor 툴
# ==========================================

# ------------------------------------------
# screenshot_tool
#
# 화면 전체를 캡처합니다.
# - save_path 지정: 파일로 저장 후 경로 반환
# - save_path 미지정: PNG를 base64로 인코딩하여 반환
#   (LLM Vision 모델이 화면 내용을 직접 분석할 때 사용합니다)
# ------------------------------------------

@mcp.tool()
def screenshot_tool(save_path: str = "") -> str:
    """
    현재 화면 전체를 캡처합니다.
    save_path를 지정하면 파일로 저장하고 경로를 반환합니다.
    비워두면 PNG 이미지를 base64로 인코딩하여 반환하며,
    LLM(Vision 모델)이 화면 내용을 직접 분석할 수 있습니다.
    """
    try:
        screenshot = pyautogui.screenshot()

        if save_path:
            screenshot.save(save_path)
            return json.dumps({"status": "saved", "path": save_path}, ensure_ascii=False)

        buffer = BytesIO()
        screenshot.save(buffer, format="PNG")
        encoded = base64.b64encode(buffer.getvalue()).decode("utf-8")
        return json.dumps({"status": "ok", "base64_png": encoded}, ensure_ascii=False)

    except Exception as e:
        return json.dumps({"error": str(e)}, ensure_ascii=False)


# ------------------------------------------
# screen_info_tool
#
# 현재 화면의 논리/물리 해상도, DPI 배율, 활성 창 제목을 반환합니다.
# 실제 구현은 monitor_tool.get_screen_info()에 위임합니다.
# ------------------------------------------

@mcp.tool()
def screen_info_tool() -> str:
    """
    현재 화면의 논리/물리 해상도, DPI 배율, 활성 창 제목을 JSON으로 반환합니다.
    OCR이나 마우스 이동 전 화면 상태와 배율을 파악할 때 사용합니다.
    """
    return get_screen_info()


# ------------------------------------------
# ocr_tool
#
# 지정한 화면 영역을 캡처하고 EasyOCR로 텍스트와 논리 픽셀 절대 좌표를 추출합니다.
# 실제 구현은 monitor_tool.capture_and_ocr()에 위임합니다.
# ------------------------------------------

@mcp.tool()
def ocr_tool(x: int, y: int, width: int, height: int, lang: str = "ko,en") -> str:
    """
    지정한 화면 영역을 캡처하고 EasyOCR로 텍스트와 논리 픽셀 절대 좌표를 추출합니다.
    x, y는 캡처 영역 좌측 상단 좌표(논리 픽셀), width/height는 영역 크기입니다.
    DPI 배율을 자동 보정하므로 screen_info_tool에서 받은 논리 픽셀 좌표를 그대로 입력하면 됩니다.
    반환값의 center 좌표를 마우스 이동 툴에 직접 사용할 수 있습니다.
    lang은 쉼표로 구분된 언어 코드입니다 (기본값: 'ko,en').
    """
    return capture_and_ocr(x, y, width, height, lang)


# ==========================================
# File System 툴
# ==========================================

# ------------------------------------------
# list_directory_tool
# ------------------------------------------

@mcp.tool()
def list_directory_tool(path: str) -> str:
    """
    주어진 경로의 디렉토리 및 파일 목록을 반환합니다.
    (예: "D드라이브의 파일들을 보여줘" -> path="D:\\")
    """
    return str(list_directory(path))


# ------------------------------------------
# read_file_tool
# ------------------------------------------

@mcp.tool()
def read_file_tool(path: str) -> str:
    """주어진 경로의 파일 내용을 읽습니다."""
    return read_file(path)


# ------------------------------------------
# write_file_tool
#
# 파괴적 작업: Agent 레벨에서 사용자 승인을 받아야 합니다.
# ------------------------------------------

@mcp.tool()
def write_file_tool(path: str, content: str) -> str:
    """
    파일에 내용을 씁니다. (기존 내용이 있다면 덮어씁니다.)
    파괴적 작업이므로 사용자의 승인이 필요합니다.
    """
    return write_file(path, content)


# ------------------------------------------
# delete_file_tool
#
# 파괴적 작업: Agent 레벨에서 사용자 승인을 받아야 합니다.
# ------------------------------------------

@mcp.tool()
def delete_file_tool(path: str) -> str:
    """
    파일을 영구적으로 삭제합니다.
    파괴적 작업이므로 사용자의 승인이 필요합니다.
    """
    return delete_file(path)


# ==========================================
# System Monitor 툴
# ==========================================

# ------------------------------------------
# get_cpu_usage_tool
# ------------------------------------------

@mcp.tool()
def get_cpu_usage_tool() -> str:
    """CPU 사용률을 퍼센테이지로 반환합니다."""
    return get_cpu_usage()


# ------------------------------------------
# get_memory_usage_tool
# ------------------------------------------

@mcp.tool()
def get_memory_usage_tool() -> str:
    """메모리 사용 현황(사용량/전체/비율)을 반환합니다."""
    return get_memory_usage()


# ------------------------------------------
# get_disk_usage_tool
# ------------------------------------------

@mcp.tool()
def get_disk_usage_tool(path: str = "C:\\") -> str:
    """지정된 경로의 디스크 사용량을 반환합니다."""
    return get_disk_usage(path)


# ------------------------------------------
# list_processes_tool
# ------------------------------------------

@mcp.tool()
def list_processes_tool(limit: int = 10) -> str:
    """CPU를 많이 사용하는 상위 프로세스를 반환합니다."""
    return list_processes(limit)


# ==========================================
# Web Search 툴
# ==========================================

# ------------------------------------------
# search_web_tool
# ------------------------------------------

@mcp.tool()
def search_web_tool(query: str) -> str:
    """DuckDuckGo를 사용하여 웹에서 정보를 검색합니다. 최대 5개 결과를 반환합니다."""
    return search_web(query)


# ==========================================
# 실행 진입점
#
# 다음 명령으로 서버를 수동으로 실행해야 합니다:
#   python -m MCP_server.main
#
# transport="sse": 네트워크(HTTP) 통신을 통해 MCP JSON-RPC 통신을 수행합니다.
# 기본적으로 localhost 네트워크 환경의 8002번 포트를 사용합니다.
# ==========================================

if __name__ == "__main__":
    mcp.run(transport="stdio")
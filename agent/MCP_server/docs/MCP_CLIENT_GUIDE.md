# MCP 클라이언트 연동 가이드

# 최종 수정일 : 2026.04.02

## 참고
- 이 방식은 LangChain에 종속시키지 않고 순수 파이썬 함수로 구현된 툴을 main.py에서 MCP로 감싸서 사용하는 방식입니다.
- 각 툴의 세부 파라미터와 반환 형식은 [TOOLS_GUID.md](./TOOLS_GUID.md)를 참조하세요.

## 개요

`MCP_server/` 패키지는 **FastMCP(HTTP 방식)** 기반의 MCP 서버입니다.

총 12개 툴을 제공합니다.

| 분류 | 툴 | 소스 모듈 |
|---|---|---|
| Monitor | `screenshot_tool`, `screen_info_tool`, `ocr_tool` | `tools/monitor_tool.py` |
| File System | `list_directory_tool`, `read_file_tool`, `write_file_tool`, `delete_file_tool` | `tools/filesystem_tool.py` |
| System | `get_cpu_usage_tool`, `get_memory_usage_tool`, `get_disk_usage_tool`, `list_processes_tool` | `tools/system_monitor.py` |
| Web | `search_web_tool` | `tools/web_serch_tool.py` |

---

## 통신 구조

```
[Agent Server]
    |
    | HTTP Request - http://localhost:8002/sse
    v
[MCP_server/main.py — FastMCP 서버 (Port: 8002)]
    |
    |-- Monitor 툴 (screenshot, screen_info, ocr)
    |-- File System 툴 (list_directory, read_file, write_file, delete_file)
    |-- System Monitor 툴 (cpu, memory, disk, processes)
    `-- Web Search 툴 (search_web)
```

### 현재 MCP_server의 HTTP 방식 (SSE JSON-RPC)

>  FastAPI 기반의 일반적인 REST API 방식보다 이거 쓰는게 훨씬 편할거라 변경했습니다. 

- **구조:** 공식 MCP(Model Context Protocol) 규격의 HTTP 하위 프로토콜인 SSE(Server-Sent Events)를 사용합니다. 
- **통신:** Agent가 `http://127.0.0.1:8002/sse`로 지속적인 단방향(스트림) 연결을 열어두고, 별도의 API 통신 경로를 통해 JSON-RPC 규격의 메시지를 실시간으로 주고받습니다. Agent Server와 별개로 백그라운드 터미널에서 MCP 서버를 먼저 실행해두어야 합니다.
- **장점:** `LangChain`, `Claude Desktop` 등 최신 AI 에이전트 프레임워크가 이 프로토콜을 네이티브로 지원합니다. 즉, Agent 코드 단 6줄(`MultiServerMCPClient` 사용)만 쓰면 12개의 툴 전체가 자동으로 파싱되고 등록되어 AI가 바로 쓸 수 있게 됩니다.

---

## Agent Server 연동 방법

### 1단계 — 패키지 설치

```bash
pip install langchain-mcp-adapters
```

### 2단계 — Agent Server보다 먼저 MCP 서버 실행

새로운 터미널을 열고 MCP 서버를 백그라운드에서 실행해둡니다.

```bash
python -m MCP_server.main
```

> 서버가 구동되면 `8002`번 포트에서 요청을 대기합니다.

### 3단계 — `agent_server/mcp_client.py` 신규 생성

```python
from langchain_mcp_adapters.client import MultiServerMCPClient

async def get_mcp_tools():
    """
    HTTP(SSE)를 통해 로컬의 8002 포트로 접속하여
    LangChain StructuredTool 형식으로 변환된 툴 목록을 반환합니다.
    """
    async with MultiServerMCPClient({
        "desktop-pet-tools": {
            "url": "http://127.0.0.1:8002/sse",
            "transport": "sse",
        }
    }) as client:
        return client.get_tools()
```

### 3단계 — Agent Server에서 툴 목록에 합산

```python
# agent_server/app/__init__.py (또는 graph 초기화 위치)

import asyncio
from agent_server.mcp_client import get_mcp_tools

# MCP 툴 비동기 초기화 후 합산
mcp_tools = asyncio.run(get_mcp_tools())

tools = mcp_tools

llm_with_tools = llm.bind_tools(tools)
```

---

## 위험 툴 처리

`write_file_tool`과 `delete_file_tool`은 로컬 파일을 수정/삭제하는 작업입니다.
MCP 프로토콜 자체에는 승인 메커니즘이 없으므로, Agent 레벨에서 사용자 확인을 받아야 합니다.

```python
# Agent Graph에서 위험 툴 실행 전 사용자 확인 예시
DANGEROUS_TOOLS = {"write_file_tool", "delete_file_tool"}

def should_continue(state):
    """위험 툴 호출 시 사용자 승인 노드로 분기합니다."""
    last_message = state["messages"][-1]
    if hasattr(last_message, "tool_calls"):
        for tc in last_message.tool_calls:
            if tc["name"] in DANGEROUS_TOOLS:
                return "await_approval"
    return "execute_tool"
```

---

## 필요 패키지

```bash
pip install mcp fastmcp easyocr numpy pyautogui pygetwindow psutil duckduckgo-search langchain-mcp-adapters uvicorn starlette sse-starlette
```

- `ctypes`, `os`, `json`, `base64`는 Python 내장 모듈로 별도 설치 불필요합니다.
- EasyOCR은 첫 실행 시 언어별 모델 파일을 자동 다운로드합니다 (한국어 약 100MB).

---

## 파일 구조 요약

```
MCP_server/
│
├── __init__.py                # mcp 인스턴스를 패키지 외부로 노출
├── main.py                    # FastMCP 서버 + 12개 툴 MCP 등록 (진입점)
│
├── tools/
│   ├── __init__.py            # 패키지 초기화 (main.py에서 import 시 필요)
│   ├── monitor_tool.py        # 화면 캡처, OCR, DPI 보정 로직
│   ├── filesystem_tool.py     # 파일/디렉토리 CRUD 로직
│   ├── system_monitor.py      # CPU, 메모리, 디스크, 프로세스 모니터링 로직
│   └── web_serch_tool.py      # DuckDuckGo 웹 검색 로직
│
└── docs/
    ├── MCP_CLIENT_GUIDE.md    # 이 문서 (클라이언트 연동 가이드)
    └── TOOLS_GUID.md          # 개별 툴 상세 설명서
```

| 파일 | 역할 |
|---|---|
| `main.py` | `@mcp.tool()` 등록 레이어. `python -m MCP_server.main`으로 실행하면 8002 포트 오픈 |
| `tools/*.py` | 순수 Python 로직 모듈. 프레임워크 무관하게 어디서든 가져다 쓸 수 있음 |
| `__init__.py` | `from MCP_server import mcp` 형태로 외부 참조 |

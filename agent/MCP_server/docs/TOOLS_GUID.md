# MCP 툴 설명서

## 참고
- 이 문서는 MCP_server에 등록된 모든 툴의 기능, 입력 파라미터, 반환 형식을 정리합니다.
- 각 툴의 순수 로직은 `tools/` 디렉터리의 개별 모듈에 구현되어 있고, `main.py`에서 `@mcp.tool()`로 등록합니다.

---

## Monitor 툴

> 소스: `tools/monitor_tool.py`

### `screenshot_tool`

현재 화면 전체를 캡처합니다.

| 파라미터 | 타입 | 필수 | 기본값 | 설명 |
|---|---|---|---|---|
| `save_path` | `str` | X | `""` | 저장할 파일 절대 경로. 비워두면 base64 PNG로 반환 |

**반환 형식**

- `save_path` 지정 시
```json
{"status": "saved", "path": "C:/tmp/shot.png"}
```

- `save_path` 미지정 시 (base64 PNG)
```json
{"status": "ok", "base64_png": "<base64 인코딩 문자열>"}
```

**LLM Vision 모델에 이미지를 입력하는 예시**

`screenshot_tool`의 base64 반환값을 LangChain의 `HumanMessage`에 실어
Vision 모델(예: `qwen3-vl:8b`, `gpt-4o`)에 전달할 수 있습니다.

```python
import json
from langchain_core.messages import HumanMessage

# 1. MCP 툴 호출 결과 수신 (Agent 내부에서 tool_result로 전달됨)
result = json.loads(screenshot_tool_result)
base64_png = result["base64_png"]

# 2. 이미지 + 텍스트를 함께 Vision 모델에 전달
message = HumanMessage(content=[
    {
        "type": "text",
        "text": "화면에 무엇이 보이나요? 현재 실행 중인 앱의 이름을 알려주세요.",
    },
    {
        "type": "image_url",
        "image_url": {
            # data URI 형식: 브라우저나 LLM API 모두 이 형식을 지원합니다
            "url": f"data:image/png;base64,{base64_png}",
        },
    },
])

# 3. Vision 모델 호출
response = llm.invoke([message])
print(response.content)
```

> `ocr_tool`이 텍스트만 추출한다면, `screenshot_tool`은 화면 전체를 LLM 눈에 보여주는 역할입니다.

---

### `screen_info_tool`

현재 화면의 논리/물리 해상도, DPI 배율, 활성 창 제목을 반환합니다.

| 파라미터 | 없음 |
|---|---|

**반환 형식**

```json
{
  "resolution": {
    "logical":  {"width": 1920, "height": 1080},
    "physical": {"width": 2560, "height": 1440},
    "scale":    {"x": 1.333, "y": 1.333}
  },
  "active_window": "Visual Studio Code"
}
```

---

### `ocr_tool`

지정한 화면 영역을 캡처하고 EasyOCR로 텍스트와 논리 픽셀 절대 좌표를 추출합니다.

| 파라미터 | 타입 | 필수 | 기본값 | 설명 |
|---|---|---|---|---|
| `x` | `int` | O | - | 캡처 영역 좌측 상단 X 좌표 (논리 픽셀) |
| `y` | `int` | O | - | 캡처 영역 좌측 상단 Y 좌표 (논리 픽셀) |
| `width` | `int` | O | - | 캡처 영역 너비 |
| `height` | `int` | O | - | 캡처 영역 높이 |
| `lang` | `str` | X | `"ko,en"` | OCR 인식 언어 (쉼표 구분) |

**반환 형식**

```json
[
  {
    "text": "확인",
    "center": {"x": 960, "y": 720},
    "bbox": {
      "top_left":     {"x": 940, "y": 710},
      "top_right":    {"x": 980, "y": 710},
      "bottom_right": {"x": 980, "y": 730},
      "bottom_left":  {"x": 940, "y": 730}
    },
    "confidence": 0.98
  }
]
```

`center` 좌표는 **논리 픽셀 절대 좌표**입니다.
DPI 배율 보정이 내부에서 자동 처리되므로 마우스 이동 툴에 `center` 값을 그대로 전달하면 됩니다.

**DPI 배율 보정 원리**

```
논리 픽셀 (입력) x scale → 물리 픽셀 (캡처)
EasyOCR 결과 (물리 픽셀 상대 좌표) / scale + 시작점 → 논리 픽셀 절대 좌표 (반환)
```

---

## File System 툴

> 소스: `tools/filesystem_tool.py`

### `list_directory_tool`

주어진 경로의 디렉토리 및 파일 목록을 반환합니다.

| 파라미터 | 타입 | 필수 | 기본값 | 설명 |
|---|---|---|---|---|
| `path` | `str` | O | - | 스캔할 디렉토리 절대 경로 (예: `"D:\\"`) |

**반환 형식**

```
"['file1.txt', 'folder1', 'image.png']"
```

---

### `read_file_tool`

주어진 경로의 파일 내용을 텍스트로 읽습니다.

| 파라미터 | 타입 | 필수 | 기본값 | 설명 |
|---|---|---|---|---|
| `path` | `str` | O | - | 읽을 파일의 절대 경로 |

**반환 형식**: 파일 텍스트 내용 또는 `"Error: ..."` 문자열

---

### `write_file_tool`

파일에 내용을 씁니다. 기존 내용이 있다면 덮어씁니다.

| 파라미터 | 타입 | 필수 | 기본값 | 설명 |
|---|---|---|---|---|
| `path` | `str` | O | - | 작성할 파일의 절대 경로 |
| `content` | `str` | O | - | 파일에 쓸 내용 |

**반환 형식**: `"Success: {path} 파일이 작성되었습니다."` 또는 `"Error: ..."`

> **위험 작업**: Agent 레벨에서 사용자 승인을 받아야 합니다.

---

### `delete_file_tool`

파일을 영구적으로 삭제합니다. 휴지통을 거치지 않습니다.

| 파라미터 | 타입 | 필수 | 기본값 | 설명 |
|---|---|---|---|---|
| `path` | `str` | O | - | 삭제할 파일의 절대 경로 |

**반환 형식**: `"Success: {path} 파일이 삭제되었습니다."` 또는 `"Error: ..."`

> **위험 작업**: Agent 레벨에서 사용자 승인을 받아야 합니다.

---

## System Monitor 툴

> 소스: `tools/system_monitor.py`

### `get_cpu_usage_tool`

현재 CPU 사용률을 측정합니다.

| 파라미터 | 없음 |
|---|---|

**반환 형식**: `"CPU Usage: 23.5%"`

---

### `get_memory_usage_tool`

전체 RAM 크기와 현재 사용량을 반환합니다.

| 파라미터 | 없음 |
|---|---|

**반환 형식**: `"Memory Usage: 8.32GB / 16.0GB (52.0%)"`

---

### `get_disk_usage_tool`

지정된 드라이브의 용량 현황을 반환합니다.

| 파라미터 | 타입 | 필수 | 기본값 | 설명 |
|---|---|---|---|---|
| `path` | `str` | X | `"C:\\"` | 디스크 경로 (예: `"D:\\"`) |

**반환 형식**: `"Disk Usage (C:\): 120.5GB / 500.0GB (24.1%)"`

---

### `list_processes_tool`

CPU 점유율이 높은 프로세스를 정렬하여 반환합니다.

| 파라미터 | 타입 | 필수 | 기본값 | 설명 |
|---|---|---|---|---|
| `limit` | `int` | X | `10` | 표시할 프로세스 수 |

**반환 형식**

```
Top Processes by CPU:
PID: 1234, Name: chrome.exe, CPU: 15.2%
PID: 5678, Name: python.exe, CPU: 8.7%
...
```

---

## Web Search 툴

> 소스: `tools/web_serch_tool.py`

### `search_web_tool`

DuckDuckGo 검색엔진으로 웹 검색을 수행합니다.

| 파라미터 | 타입 | 필수 | 기본값 | 설명 |
|---|---|---|---|---|
| `query` | `str` | O | - | 검색할 질의 문자열 |

**반환 형식**

```
[1] 위키피디아 - 파이썬
URL: https://ko.wikipedia.org/wiki/파이썬
요약: 파이썬은 1991년에 만들어진 프로그래밍 언어로...

[2] 파이썬 공식 사이트
URL: https://www.python.org/
요약: The official home of the Python Programming Language...
```

최대 5개 결과를 반환합니다.

---

## 전체 툴 요약

| 분류 | 툴 이름 | 설명 | 위험 |
|---|---|---|---|
| Monitor | `screenshot_tool` | 전체 화면 캡처 (base64 PNG / 파일 저장) | - |
| Monitor | `screen_info_tool` | 해상도, DPI 배율, 활성 창 정보 | - |
| Monitor | `ocr_tool` | 영역 캡처 + EasyOCR 텍스트 추출 | - |
| File System | `list_directory_tool` | 디렉토리 파일 목록 | - |
| File System | `read_file_tool` | 파일 읽기 | - |
| File System | `write_file_tool` | 파일 쓰기 | 파괴적 |
| File System | `delete_file_tool` | 파일 삭제 | 파괴적 |
| System | `get_cpu_usage_tool` | CPU 사용률 | - |
| System | `get_memory_usage_tool` | 메모리 사용 현황 | - |
| System | `get_disk_usage_tool` | 디스크 용량 현황 | - |
| System | `list_processes_tool` | 상위 프로세스 목록 | - |
| Web | `search_web_tool` | DuckDuckGo 웹 검색 | - |

import json
import ctypes
from io import BytesIO

import numpy as np
import pyautogui
import pygetwindow as gw
import easyocr

# ==========================================
# MCP_server/tools/monitor_tool.py — 유틸리티 모듈
#
# 화면 정보 조회, 영역 캡처, EasyOCR 텍스트 추출 로직을 담당합니다.
# ==========================================


# ==========================================
# DPI 배율 계산
#
# pyautogui.size()는 논리 픽셀을 반환하지만
# pyautogui.screenshot()은 환경에 따라 물리 픽셀로 캡처합니다.
# 화면 배율(125%, 150% 등)이 설정된 환경에서는 두 값이 달라 좌표 어긋남이 발생합니다.
# ctypes(Windows 내장)로 물리 픽셀을 조회하여 배율을 계산합니다.
# ==========================================

def _get_dpi_info() -> dict:
    """
    논리 픽셀, 물리 픽셀, 배율(scale)을 반환합니다.
    비-Windows 환경(Mac, Linux)에서는 AttributeError를 catch하여
    배율을 1.0으로 처리합니다.
    """
    logical_w, logical_h = pyautogui.size()

    try:
        # Windows API — 물리 해상도 조회
        physical_w = ctypes.windll.user32.GetSystemMetrics(0)  # SM_CXSCREEN
        physical_h = ctypes.windll.user32.GetSystemMetrics(1)  # SM_CYSCREEN
        scale_x = physical_w / logical_w
        scale_y = physical_h / logical_h
    except AttributeError:
        # 비-Windows 환경 — 배율 1.0 처리
        physical_w, physical_h = logical_w, logical_h
        scale_x, scale_y = 1.0, 1.0

    return {
        "logical":  {"width": logical_w,  "height": logical_h},
        "physical": {"width": physical_w, "height": physical_h},
        "scale":    {"x": scale_x,        "y": scale_y},
    }


# ==========================================
# EasyOCR Reader 싱글턴 캐시
#
# EasyOCR Reader는 초기화 시 딥러닝 모델을 로드합니다.
# 동일한 언어 조합의 Reader를 매번 새로 생성하지 않고 딕셔너리에 캐싱하여 재사용합니다.
# ==========================================

_reader_cache: dict = {}

def _get_reader(lang: str) -> easyocr.Reader:
    """
    언어 조합에 해당하는 EasyOCR Reader를 반환합니다.
    이미 초기화된 Reader는 캐시에서 재사용합니다.
    """
    lang_list = [l.strip() for l in lang.split(",")]
    cache_key = ",".join(sorted(lang_list))

    if cache_key not in _reader_cache:
        # gpu=False: GPU 없는 환경에서도 동작하도록 CPU 모드 고정
        _reader_cache[cache_key] = easyocr.Reader(lang_list, gpu=False)

    return _reader_cache[cache_key]


# ==========================================
# 화면 정보 조회
# ==========================================

def get_screen_info() -> str:
    """
    현재 화면의 논리/물리 해상도, DPI 배율, 활성 창 제목을 JSON 문자열로 반환합니다.
    """
    dpi = _get_dpi_info()

    try:
        active = gw.getActiveWindow()
        window_title = active.title if active else "활성 창 없음"
    except Exception:
        window_title = "조회 불가"

    return json.dumps(
        {"resolution": dpi, "active_window": window_title},
        ensure_ascii=False
    )


# ==========================================
# 영역 캡처 + EasyOCR 텍스트 추출
#
# 좌표 보정 흐름:
#   1. 입력 좌표(논리 픽셀) × DPI 배율 → 물리 픽셀로 변환 후 캡처
#   2. EasyOCR 결과 좌표(캡처 영역 내 상대 물리 픽셀)
#      → 캡처 시작점 더하고 배율로 나누기 → 논리 픽셀 절대 좌표로 역변환
#   3. 반환된 center 좌표를 마우스 이동 툴에 직접 사용 가능
#
# 반환 형식 (JSON 문자열):
#   [
#     {
#       "text": "확인",
#       "center": {"x": 960, "y": 720},
#       "bbox": {
#         "top_left":     {"x": 940, "y": 710},
#         "top_right":    {"x": 980, "y": 710},
#         "bottom_right": {"x": 980, "y": 730},
#         "bottom_left":  {"x": 940, "y": 730}
#       },
#       "confidence": 0.98
#     }
#   ]
# ==========================================

def capture_and_ocr(x: int, y: int, width: int, height: int, lang: str) -> str:
    """
    지정한 화면 영역을 캡처하고 EasyOCR로 텍스트와 절대 좌표를 추출합니다.
    """
    if width <= 0 or height <= 0:
        return json.dumps(
            {"error": "width와 height는 0보다 커야 합니다."},
            ensure_ascii=False
        )

    try:
        # [1] DPI 배율 조회
        dpi = _get_dpi_info()
        scale_x = dpi["scale"]["x"]
        scale_y = dpi["scale"]["y"]

        # [2] 논리 픽셀 → 물리 픽셀 변환 후 캡처
        phys_x = int(x * scale_x)
        phys_y = int(y * scale_y)
        phys_w = int(width  * scale_x)
        phys_h = int(height * scale_y)

        screenshot = pyautogui.screenshot(region=(phys_x, phys_y, phys_w, phys_h))

        # [3] PIL Image → numpy array (EasyOCR 입력 형식)
        img_array = np.array(screenshot)

        # [4] EasyOCR로 텍스트 + 바운딩 박스 + 신뢰도 추출
        reader = _get_reader(lang)
        results = reader.readtext(img_array)

        # [5] 물리 픽셀 상대 좌표 → 논리 픽셀 절대 좌표로 역변환
        def to_logical(px: float, py: float) -> dict:
            return {
                "x": round(x + px / scale_x),
                "y": round(y + py / scale_y),
            }

        output = []
        for bbox_phys, text, confidence in results:
            tl, tr, br, bl = bbox_phys  # 각각 [x, y]

            tl_l = to_logical(tl[0], tl[1])
            tr_l = to_logical(tr[0], tr[1])
            br_l = to_logical(br[0], br[1])
            bl_l = to_logical(bl[0], bl[1])

            center = {
                "x": round((tl_l["x"] + br_l["x"]) / 2),
                "y": round((tl_l["y"] + br_l["y"]) / 2),
            }

            output.append({
                "text": text,
                "center": center,
                "bbox": {
                    "top_left":     tl_l,
                    "top_right":    tr_l,
                    "bottom_right": br_l,
                    "bottom_left":  bl_l,
                },
                "confidence": round(float(confidence), 4),
            })

        return json.dumps(output, ensure_ascii=False)

    except Exception as e:
        return json.dumps({"error": str(e)}, ensure_ascii=False)

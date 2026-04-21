import os
from typing import List

# ==========================================
# MCP_server/tools/filesystem_tool.py
# File System Tool: OS의 디렉토리와 파일을 직접 제어하는 도구입니다.
# AI 모델이 로컬 환경의 폴더를 스캔하거나 내용을 읽고 쓰는 역할을 담당합니다.
# ==========================================


def list_directory(path: str) -> List[str]:
    """
    지정된 경로의 파일과 폴더 목록을 반환합니다.
    (예: "D드라이브의 파일들을 보여줘" 
     -> 에이전트가 path="D:\\" 를 전달하여 이 함수를 실행)
    """
    try:
        return os.listdir(path)
    except Exception as e:
        return [f"Error: {str(e)}"]


def read_file(path: str) -> str:
    """
    특정 파일의 내용을 텍스트 형식으로 모두 읽어옵니다.
    """
    try:
        with open(path, 'r', encoding='utf-8') as f:
            return f.read()
    except Exception as e:
        return f"Error: {str(e)}"


# ========================================================
# 경고: 아래 두 함수는 로컬 파일 시스템을 파괴(수정/삭제)할 수 있습니다.
# MCP 서버에서 호출 시 Agent 레벨에서 사용자 승인을 받아야 합니다.
# ========================================================

def write_file(path: str, content: str) -> str:
    """
    파일의 내용을 새로 작성합니다. (기존 내용이 있다면 덮어씁니다.)
    """
    try:
        with open(path, 'w', encoding='utf-8') as f:
            f.write(content)
        return f"Success: {path} 파일이 작성되었습니다."
    except Exception as e:
        return f"Error: {str(e)}"


def delete_file(path: str) -> str:
    """
    파일을 바탕화면이나 휴지통을 거치지 않고 영구적으로 삭제합니다.
    """
    try:
        os.remove(path)
        return f"Success: {path} 파일이 삭제되었습니다."
    except Exception as e:
        return f"Error: {str(e)}"

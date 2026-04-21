import psutil

# ==========================================
# MCP_server/tools/system_monitor.py
# System Monitor Tool: 사용자의 PC 하드웨어와 리소스 현황을 모니터링합니다.
# "내 컴퓨터 CPU 너무 많이 써?", "쓸데없이 돌아가는 프로세스 꺼줘" 등의 
# 요청을 처리하기 위한 기반 데이터를 수집합니다.
# ==========================================


def get_cpu_usage() -> str:
    """현재 CPU 사용률을 측정하여 몇 퍼센트인지 문자열로 반환합니다."""
    usage = psutil.cpu_percent(interval=1)
    return f"CPU Usage: {usage}%"


def get_memory_usage() -> str:
    """전체 RAM 크기와 현재 사용 중인 메모리 양, 그리고 비율(%)을 반환합니다."""
    mem = psutil.virtual_memory()
    total = round(mem.total / (1024 ** 3), 2)  # 바이트를 기가바이트(GB)로 변환
    used = round(mem.used / (1024 ** 3), 2)
    return f"Memory Usage: {used}GB / {total}GB ({mem.percent}%)"


def get_disk_usage(path: str = "C:\\") -> str:
    """
    특정 드라이브(예: C드라이브)의 용량 현황을 반환합니다.
    자료 저장 전 남은 디스크를 확인할 때 유용합니다.
    """
    try:
        disk = psutil.disk_usage(path)
        total = round(disk.total / (1024 ** 3), 2)
        used = round(disk.used / (1024 ** 3), 2)
        return f"Disk Usage ({path}): {used}GB / {total}GB ({disk.percent}%)"
    except Exception as e:
        return f"Error accessing disk info for {path}: {str(e)}"


def list_processes(limit: int = 10) -> str:
    """
    지금 컴퓨터에서 실행 중인 프로세스 목록을 가져옵니다.
    CPU 점유율이 가장 높은 순서대로 {limit}개까지만 표시합니다.
    """
    processes = []
    # psutil을 통해 프로세스의 PID값, 이름, CPU퍼센트를 함께 반복 스캔
    for proc in psutil.process_iter(['pid', 'name', 'cpu_percent']):
        try:
            processes.append(proc.info)
        except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
            pass  # 권한 부족이나 이미 꺼진 프로세스는 무시
    
    # CPU 사용률 순으로 내림차순 정렬 (가장 많이 쓰는 것부터)
    processes.sort(key=lambda x: x['cpu_percent'] or 0.0, reverse=True)
    
    result = "Top Processes by CPU:\n"
    for p in processes[:limit]:
        result += f"PID: {p['pid']}, Name: {p['name']}, CPU: {p['cpu_percent']}%\n"
    return result

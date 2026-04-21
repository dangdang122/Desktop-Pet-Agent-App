from typing import TypedDict, Annotated, List
from langchain_core.messages import AnyMessage
import operator


class AgentState(TypedDict):
    """LangGraph 에이전트의 전역 상태를 정의합니다."""

    # ============ messages ============
    # operator.add: 대화 기록이 매 턴마다 누적됩니다.
    messages: Annotated[List[AnyMessage], operator.add]

    # ============ original_request ============
    # Planner가 저장하는 최초 사용자 요청.
    # Aggregator가 항상 올바른 원본 요청을 참조하기 위해 사용합니다.
    original_request: str

    # ============ Orchestrator Fields ============
    # plan: Router가 태스크를 하나씩 빼서 줄여나갑니다. (단순 할당, 덮어쓰기)
    plan: List[str]
    # current_task: Router가 현재 Worker에게 할당한 단일 태스크
    current_task: str
    # past_results: 각 Worker가 태스크 완료 후 누적하는 중간 결과물 (단순 할당, Worker가 직접 누적)
    past_results: List[str]
    # active_worker: 현재 활성 Worker 이름 (도구 완료 후 복귀 경로로 사용)
    active_worker: str

    # ============ tool_call_count ============
    # Worker의 무한 도구 호출 루프를 방지하기 위한 카운터.
    # Router가 새 태스크를 배정할 때마다 0으로 초기화합니다.
    tool_call_count: int

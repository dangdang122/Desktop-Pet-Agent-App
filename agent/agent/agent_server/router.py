"""
agent/agent_server/router.py

FastAPI 라우터 - 에이전트와 Web UI 간의 인터페이스를 제공합니다.

세션 관리:
  - session_id: HttpOnly 쿠키로 자동 발급/관리 (Web UI 코드 변경 불필요)
  - thread_id: f"{user_id}:{session_id}" 형태로 구성
      - 지금(MVP): user_id = "default" 고정
      - 나중(멀티유저): JWT 토큰에서 user_id를 추출하여 교체

사용자 승인 흐름 (LangGraph interrupt 방식):
  [Worker 내부] interrupt() 발동
    → ainvoke가 즉시 반환, result에 "__interrupt__" 키 포함
    → API가 프론트엔드에 approval_required 반환
  [사용자 승인/거절]
    → /approve API에서 Command(resume=True/False) 전달
    → 그래프가 interrupt() 바로 다음부터 재개
"""

import uuid
import logging

from fastapi import APIRouter, Cookie, Response
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from langchain_core.messages import HumanMessage
from langgraph.types import Command

logger = logging.getLogger(__name__)

router = APIRouter()


class ChatRequest(BaseModel):
    message: str
    images: list[str] = []         # base64 인코딩된 이미지 문자열 리스트 (최대 3개 제한)
    session_id: str | None = None  # 쿠키가 유실됐을 때를 대비한 이중 안전장치

class ApprovalRequest(BaseModel):
    approve: bool                  # True: 허용 / False: 거절
    session_id: str | None = None  # 쿠키가 유실됐을 때를 대비한 이중 안전장치


# ==========================================
# 에이전트 지연 초기화 (순환 임포트 방지)
# ==========================================
_agent = None

async def _get_or_create_agent():
    global _agent
    if _agent is None:
        from graph import create_agent
        _agent = await create_agent()
    return _agent


def _make_config(session_id: str) -> dict:
    """
    LangGraph 실행 설정을 생성합니다.
    thread_id = "{user_id}:{session_id}" 형태로 구성합니다.

    나중에 로그인 기능 도입 시, user_id를 JWT 토큰에서 추출하여 교체하세요.
    예: user_id = get_current_user(request).id
    """
    user_id = "default"  # MVP: 단일 사용자 고정
    return {"configurable": {"thread_id": f"{user_id}:{session_id}"}}


def _initial_state(request: ChatRequest) -> dict:
    """새 대화 턴 시작 시 전달할 초기 State를 반환합니다."""
    # 이미지가 있는 경우 멀티모달 포맷으로 구성
    if request.images:
        content = [{"type": "text", "text": request.message}]
        # 최대 3개까지만 제한
        for img in request.images[:3]:
            content.append({"type": "image_url", "image_url": {"url": img}})
    else:
        content = request.message

    return {
        "messages":        [HumanMessage(content=content)],
        "original_request": request.message, # Planner 및 Aggregator에서 사용할 순수 텍스트 요청
        "plan":            [],
        "current_task":    "",
        "past_results":    [],
        "active_worker":   "",
        "tool_call_count": 0,
    }


# ==========================================
# /chat
# ==========================================

@router.post("/chat")
async def chat_endpoint(
    request:    ChatRequest,
    response:   Response,
    session_id: str = Cookie(default=None),
):
    """
    사용자 메시지를 받아 에이전트를 실행합니다.

    - 일반 요청: 에이전트가 계획/실행/취합 후 최종 응답 반환
    - 위험 도구 감지: interrupt()로 일시정지, approval_required 상태 반환
    """
    # 세션 ID 우선순위: 쿠키 → 요청 바디 → 신규 발급
    # (httpx 쿠키 중계 과정에서 쿠키가 유실되더라도 바디의 session_id로 보완)
    session_id = session_id or request.session_id or str(uuid.uuid4())
    logger.info(f"[Chat] thread_id=default:{session_id[:8]}...")

    # 쿠키 갱신 (응답마다 재세팅 → 만료 방지)
    response.set_cookie(key="session_id", value=session_id, httponly=True, samesite="lax")

    agent  = await _get_or_create_agent()
    config = _make_config(session_id)
    state  = _initial_state(request)

    try:
        result = await agent.ainvoke(state, config=config)

        # ---- 위험 도구로 인한 일시정지 ----
        if "__interrupt__" in result:
            interrupt_data = result["__interrupt__"][0].value
            logger.info(f"[Chat] interrupt 발동: {interrupt_data['tool_name']}")
            return JSONResponse(content={
                "status":       "approval_required",
                "message":      (
                    f"⚠️ 위험한 작업 감지\n"
                    f"도구: {interrupt_data['tool_name']}\n"
                    f"내용: {interrupt_data['tool_args']}\n\n"
                    f"실행을 허용하시겠습니까?"
                ),
                "tool_call_id": interrupt_data["tool_call_id"],
            })

        last_msg = result["messages"][-1]
        return JSONResponse(content={"status": "success", "message": last_msg.content, "session_id": session_id})

    except Exception as e:
        import traceback
        trace = traceback.format_exc()
        logger.error(f"[Chat] 에이전트 실행 오류:\n{trace}")
        return JSONResponse(
            content={"status": "error", "message": f"에이전트 실행 실패: {e}\n{trace}"},
            status_code=500,
        )


# ==========================================
# /approve
# ==========================================

@router.post("/approve")
async def approve_endpoint(
    request:    ApprovalRequest,
    response:   Response,
    session_id: str = Cookie(default=None),
):
    """
    Web UI의 승인/거절 결과를 받아 중단된 에이전트를 재개합니다.

    LangGraph의 Command(resume=bool)를 사용해 interrupt() 위치에서 정확히 재개합니다.
    - approve=True  → Worker가 도구를 실행하고 계속 진행
    - approve=False → Worker가 거절 메시지를 기록하고 다음 계획으로 복귀
    """
    # 세션 ID 우선순위: 쿠키 → 요청 바디 → 에러
    session_id = session_id or request.session_id
    if not session_id:
        return JSONResponse(
            content={"status": "error", "message": "세션이 없습니다. 새로 대화를 시작해주세요."},
            status_code=400,
        )
    logger.info(f"[Approve] thread_id=default:{session_id[:8]}...")

    response.set_cookie(key="session_id", value=session_id, httponly=True, samesite="lax")

    agent  = await _get_or_create_agent()
    config = _make_config(session_id)

    try:
        # Command(resume=True/False) → interrupt() 위치에서 재개
        result = await agent.ainvoke(Command(resume=request.approve), config=config)

        # 재개 후 또 다른 위험 도구가 등장한 경우
        if "__interrupt__" in result:
            interrupt_data = result["__interrupt__"][0].value
            return JSONResponse(content={
                "status":       "approval_required",
                "message":      (
                    f"⚠️ 또 다른 위험 작업이 감지되었습니다.\n"
                    f"도구: {interrupt_data['tool_name']}\n"
                    f"내용: {interrupt_data['tool_args']}"
                ),
                "tool_call_id": interrupt_data["tool_call_id"],
            })

        last_msg = result["messages"][-1]
        status   = "success" if request.approve else "rejected"
        return JSONResponse(content={"status": status, "message": last_msg.content})

    except Exception as e:
        import traceback
        trace = traceback.format_exc()
        logger.error(f"[Approve] 재개 오류:\n{trace}")
        return JSONResponse(
            content={"status": "error", "message": f"재개 중 오류 발생: {e}"},
            status_code=500,
        )

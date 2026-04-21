"""
agent/graph/nodes.py

LangGraph 그래프를 구성하는 모든 노드 및 조건부 엣지 함수를 정의합니다.

노드 구조:
  [Planner] → [Master Router] → [Vision / General Worker] ↔ [ToolNode]
                                                         ↓
                                                    [Aggregator] → END

사용자 승인 흐름:
  Worker가 위험 도구를 감지하면 interrupt()로 그래프를 일시정지합니다.
  /approve API에서 Command(resume=True/False)로 재개하면 Worker가 이어서 실행됩니다.
"""

import json
import logging
from typing import Literal

from pydantic import BaseModel
from langchain_core.runnables import Runnable
from langchain_core.messages import SystemMessage, ToolMessage, HumanMessage
from langgraph.types import interrupt

from .state import AgentState
from prompts.agents_prompts import (
    PLANNER_PROMPT,
    ROUTER_PROMPT,
    VISION_WORKER_PROMPT,
    WINDOWS_MCP_WORKER_PROMPT,
    AGGREGATOR_PROMPT,
)

logger = logging.getLogger(__name__)

# ==========================================
# 상수
# ==========================================

# Structured Output 모델: Master Router가 반환할 worker 이름
class WorkerDecision(BaseModel):
    worker: Literal["vision_worker", "windows_mcp_worker"]

# 실행 계획 모델
class ExecutionPlan(BaseModel):
    plan: list[str]

# 실행 전 사용자 승인이 필요한 위험 도구 목록
DANGEROUS_TOOLS = ["write_file_tool", "delete_file_tool"]

# Worker 1회 태스크당 최대 도구 호출 횟수 (무한 루프 방지)
MAX_TOOL_CALLS = 10

# ==========================================
# 1. Planner Node
# ==========================================

def make_planner_node(llm: Runnable):
    """
    사용자의 요청을 분석해 단계별 실행 계획(Plan)을 수립합니다.
    """
    planner_llm = llm.with_structured_output(ExecutionPlan)

    def planner_node(state: AgentState):
        # 가장 마지막 HumanMessage를 원본 요청으로 저장 (Aggregator에서 정확하게 참조)
        chat_history = _get_plain_chat_history(state["messages"])
        original_request = state.get("original_request", "")
        # Fallback if original_request is empty
        if not original_request:
            for msg in reversed(chat_history):
                if isinstance(msg, HumanMessage):
                    if isinstance(msg.content, str):
                        original_request = msg.content
                    elif isinstance(msg.content, list):
                        # 모든 텍스트 조각을 합쳐서 추출
                        texts = [item.get("text", "") for item in msg.content if isinstance(item, dict) and item.get("type") == "text"]
                        original_request = " ".join(t.strip() for t in texts if t.strip())
                    break

        # 이미지 존재 여부 확인 및 플래너 힌트 생성
        image_count = 0
        for m in state["messages"]:
            if isinstance(m, HumanMessage) and isinstance(m.content, list):
                image_count += sum(1 for item in m.content if isinstance(item, dict) and item.get("type") == "image_url")
        
        hint = f"\n\n[System Hint: User has uploaded {image_count} image(s).]" if image_count > 0 else ""
        
        # 메시지 조합 (SystemMessage + History + optional Hint)
        input_msgs = [SystemMessage(content=PLANNER_PROMPT)] + chat_history
        if hint:
            input_msgs.append(HumanMessage(content=hint))

        try:
            # Pydantic 모델을 사용해 직접 객체로 수신 (파싱 에러 해결)
            res_obj: ExecutionPlan = planner_llm.invoke(input_msgs)
            plan = res_obj.plan if res_obj and res_obj.plan else []
        except Exception as e:
            logger.error(f"[Planner] 구조화 출력 생성 실패: {e!r}")
            plan = []

        logger.info(f"[Planner] Plan created (length: {len(plan)}): {plan}")
        return {
            "plan": plan,
            "past_results": [],
            "tool_call_count": 0,
            "original_request": original_request,
        }
    return planner_node


# ==========================================
# 2. Master Router Node (LLM Structured Output 기반)
# ==========================================

def make_master_router_node(llm: Runnable):
    """
    Plan에서 다음 태스크를 꺼내고, LLM이 어느 Worker가 적합한지 판단합니다.
    """
    router_llm = llm.with_structured_output(WorkerDecision)

    def master_router_node(state: AgentState):
        plan = state.get("plan", [])
        if not plan:
            # 모든 계획 완료 → Aggregator로
            return {"current_task": "", "active_worker": ""}

        current_task = plan[0]
        remaining_plan = plan[1:]

        decision: WorkerDecision = router_llm.invoke([
            SystemMessage(content=ROUTER_PROMPT),
            HumanMessage(content=current_task),
        ])

        logger.info(f"[Router] '{current_task}' → {decision.worker}")
        return {
            "plan": remaining_plan,
            "current_task": current_task,
            "active_worker": decision.worker,
            "tool_call_count": 0,  # 새 태스크 시작 시 카운터 초기화
        }
    return master_router_node


# ==========================================
# Worker & Chat History 유틸리티
# ==========================================

def _get_plain_chat_history(messages: list) -> list:
    """
    Graph 상태(messages)에서 순수 대화 내용(HumanMessage + Aggregator의 응답)만 추출합니다.
    - ToolMessage 제외 (이미지, 대용량 로그 토큰 낭비 방지)
    - 도구 호출을 포함한 AIMessage 제외
    - Planner/Router의 JSON 응답(AIMessage) 제외
    - HumanMessage에 포함된 Base64 이미지 제거 (텍스트만 전달하여 토큰 절약 및 오류 방지)
    """
    from langchain_core.messages import AIMessage
    chat_history = []
    for msg in messages:
        if isinstance(msg, HumanMessage):
            if isinstance(msg.content, list):
                # 멀티모달(이미지 포함) 메시지인 경우 모든 텍스트 조각을 합쳐서 추출
                texts = [item.get("text", "") for item in msg.content if isinstance(item, dict) and item.get("type") == "text"]
                text_content = " ".join(t.strip() for t in texts if t.strip())
                chat_history.append(HumanMessage(content=text_content))
            else:
                chat_history.append(msg)
        elif isinstance(msg, AIMessage) and not getattr(msg, "tool_calls", None):
            content = msg.content.strip() if isinstance(msg.content, str) else ""
            if not (content.startswith("{") and content.endswith("}")):
                chat_history.append(msg)
    return chat_history

def _build_worker_messages(state: AgentState, system_prompt: str, include_images: bool = False) -> list:
    """Worker LLM에 전달할 메시지 목록을 구성합니다."""
    msgs = [
        SystemMessage(content=system_prompt),
        HumanMessage(content=(
            f"Sub-task: {state.get('current_task', '')}\n"
            f"Past Results: {state.get('past_results', [])}"
        )),
    ]

    # 사용자가 직접 업로드한 이미지 포함 (Vision Worker 등에서 필요)
    if include_images:
        user_images = []
        for msg in state["messages"]:
            if isinstance(msg, HumanMessage) and isinstance(msg.content, list):
                for item in msg.content:
                    if isinstance(item, dict) and item.get("type") == "image_url":
                        user_images.append(item)
        if user_images:
            msgs.append(HumanMessage(content=user_images))

    # 최근 도구 호출 / 결과 메시지 덧붙이기
    recent = []
    for msg in reversed(state["messages"]):
        if isinstance(msg, ToolMessage):
            recent.insert(0, msg)
        elif getattr(msg, "tool_calls", None):
            recent.insert(0, msg)
            break
    return msgs + recent


# ==========================================
# 3. 공통 Worker 팩토리
#    Vision/General이 동일한 구조를 공유합니다.
#    Vision만 postprocess(이미지 압축 변환)를 추가로 적용합니다.
# ==========================================

def _make_base_worker(llm_with_tools: Runnable, system_prompt: str, worker_label: str, postprocess=None):
    def worker_node(state: AgentState):
        msgs = _build_worker_messages(state, system_prompt)
        if postprocess:
            msgs = postprocess(msgs)

        # ---- OpenAI ToolMessage Image Fix ----
        # OpenAI API는 role이 'tool'인 메시지에 image_url을 허용하지 않습니다.
        # 따라서 ToolMessage 안의 image(또는 image_url) 블록을 찾아 추출한 뒤,
        # 바로 이어지는 HumanMessage로 분리해 줍니다.
        fixed_msgs = []
        for msg in msgs:
            if isinstance(msg, ToolMessage) and isinstance(msg.content, list):
                new_content = []
                extracted_images = []
                for item in msg.content:
                    is_image = False
                    if isinstance(item, dict):
                        itype = item.get("type", "")
                        if "image" in itype: 
                            is_image = True
                    elif hasattr(item, "type"):
                        if "image" in getattr(item, "type", ""):
                            is_image = True

                    if is_image:
                        # MCP Adapter가 "image" 타입으로 넘긴 경우 openai가 이해할 수 있는 "image_url" 형식으로 변환해야 할 수도 있습니다.
                        # 다만 일단 추출하는 것 자체가 목적이므로 그대로 분리합니다.
                        # 만약 item이 'image'이고 data를 가지고 있다면 변환
                        if isinstance(item, dict) and item.get("type") == "image" and "source" in item:
                            # MCP image to OpenAI image_url format
                            source = item["source"]
                            mime = source.get("media_type", "image/png")
                            data = source.get("data", "")
                            extracted_images.append({
                                "type": "image_url",
                                "image_url": {"url": f"data:{mime};base64,{data}"}
                            })
                        else:
                            extracted_images.append(item)
                    else:
                        new_content.append(item)
                
                # 이미지 블록이 제거된 순수 Text 기반 ToolMessage 추가
                fixed_msgs.append(ToolMessage(
                    content=new_content or "Image captured and provided in the next message.", 
                    name=msg.name, 
                    tool_call_id=msg.tool_call_id
                ))
                
                # 추출한 이미지가 있다면 HumanMessage로 전환하여 바로 뒤에 이어붙임
                if extracted_images:
                    fixed_msgs.append(HumanMessage(content=extracted_images))
            else:
                fixed_msgs.append(msg)
                
        msgs = fixed_msgs

        # ---- 무한 루프 방지 ----
        count = state.get("tool_call_count", 0)
        if count >= MAX_TOOL_CALLS:
            logger.warning(f"[{worker_label}] 최대 도구 호출 횟수({MAX_TOOL_CALLS}) 초과. 강제 종료.")
            return {
                "past_results": state.get("past_results", []) + [
                    f"[{worker_label}] 최대 도구 호출 횟수를 초과하여 작업이 중단되었습니다."
                ],
                "tool_call_count": 0,
            }

        response = llm_with_tools.invoke(msgs)

        if response.tool_calls:
            logger.info(f"[{worker_label}] Tool Calls requested: {response.tool_calls}")
            # ---- 위험 도구 전수 스캔 ----
            # LLM이 한 번에 여러 tool_call을 반환할 수 있으므로 [0]만 보면 안 됩니다.
            dangerous_calls = [
                tc for tc in response.tool_calls if tc["name"] in DANGEROUS_TOOLS
            ]

            if dangerous_calls:
                logger.info(
                    f"[{worker_label}] 위험 도구 감지 {len(dangerous_calls)}개 → interrupt() 발동"
                )
                # 위험 도구 전체 목록을 한 번에 사용자에게 표시
                approved = interrupt({
                    "tool_name":  dangerous_calls[0]["name"],          # UI 표시용 대표 이름
                    "tool_args":  [tc["args"] for tc in dangerous_calls],  # 전체 인자 목록
                    "tool_call_id": dangerous_calls[0]["id"],
                    "total_count": len(dangerous_calls),               # 총 개수 표시
                })
                if not approved:
                    # 거절: 위험 도구 전체에 대해 ToolMessage 생성 후 router 복귀
                    rejections = [
                        ToolMessage(
                            content="사용자가 명령 실행을 거절하였습니다.",
                            name=tc["name"],
                            tool_call_id=tc["id"],
                        )
                        for tc in dangerous_calls
                    ]
                    return {
                        "messages": [response] + rejections,
                        "past_results": state.get("past_results", []) + [
                            f"[{worker_label}] '{dangerous_calls[0]['name']}' 외 "
                            f"{len(dangerous_calls)}건 실행이 거절되었습니다."
                        ],
                        "tool_call_count": 0,
                    }
                # 승인 → Tools 노드로 이동 (route_worker가 tool_calls 유무로 판단)

            # 일반 도구 (또는 승인된 위험 도구) → ToolNode로 전달
            return {"messages": [response], "tool_call_count": count + 1}


        # 도구 호출 없음 → 태스크 완료, Master Router로 복귀
        final_answer = getattr(response, "content", "No content")
        logger.info(f"[{worker_label}] Task completed. Sub-task result: {str(final_answer)}...")
        return {
            "messages": [response],
            "past_results": state.get("past_results", []) + [

                f"[{worker_label}] {response.content}"
            ],
            "tool_call_count": 0,
        }
    return worker_node


# ==========================================
# 3-1. Windows MCP Worker Node
# ==========================================

def make_windows_mcp_worker(llm_with_tools: Runnable):
    """windows-mcp의 모든 도구를 담당하는 단일 Worker."""
    return _make_base_worker(
        llm_with_tools,
        system_prompt=WINDOWS_MCP_WORKER_PROMPT,
        worker_label="windows_mcp_worker",
    )


# ==========================================
# 3-2. Vision Worker Node
# ==========================================

def make_vision_worker(llm: Runnable):
    """사용자가 업로드한 이미지를 분석하는 전용 Worker."""
    def vision_worker_node(state: AgentState):
        msgs = _build_worker_messages(state, VISION_WORKER_PROMPT, include_images=True)
        
        response = llm.invoke(msgs)
        final_answer = getattr(response, "content", "No content")
        logger.info(f"[Vision Worker] Task completed: {str(final_answer)[:50]}...")
        
        return {
            "messages": [response],
            "past_results": state.get("past_results", []) + [
                f"[vision_worker] {response.content}"
            ],
            "tool_call_count": 0,
        }
    return vision_worker_node


# ==========================================
# 5. Aggregator Node
# ==========================================

def make_aggregator_node(llm: Runnable):
    """모든 Worker 결과를 취합해 사용자에게 최종 답변을 생성합니다.

    [대화 기억 구현 방식]
    state["messages"]에서 순수 대화 메시지(HumanMessage + Aggregator의 AIMessage)만 추출해
    LLM에 히스토리로 제공합니다. 이를 통해 이전 대화 내용을 기억하면서 현재 요청에 답변합니다.

    Worker 내부 메시지(ToolMessage, tool_calls 포함 AIMessage)는 대화 맥락과 무관하므로 제외합니다.
    """
    def aggregator_node(state: AgentState):
        from langchain_core.messages import AIMessage

        original_request = state.get("original_request")
        if not original_request:
            for msg in reversed(state["messages"]):
                if isinstance(msg, HumanMessage):
                    if isinstance(msg.content, str):
                        original_request = msg.content
                    elif isinstance(msg.content, list):
                        # 모든 텍스트 조각을 합쳐서 추출
                        texts = [item.get("text", "") for item in msg.content if isinstance(item, dict) and item.get("type") == "text"]
                        original_request = " ".join(t.strip() for t in texts if t.strip())
                    break
        
        current_request = original_request or ""
        past = state.get("past_results", [])

        # ---- 순수 대화 히스토리 추출 ----
        chat_history = _get_plain_chat_history(state["messages"])

        # ---- 현재 요청 제거 ----
        # 마지막 HumanMessage는 current_request와 동일하므로 중복 방지를 위해 히스토리에서 뺍니다.
        # (current_request를 별도의 마지막 메시지로 명시적으로 추가할 예정)
        if chat_history and isinstance(chat_history[-1], HumanMessage):
            chat_history = chat_history[:-1]

        # ---- 메시지 목록 구성 ----
        msgs = [SystemMessage(content=AGGREGATOR_PROMPT)]

        # 과거 대화 이력을 그대로 주입 (멀티턴 기억)
        if chat_history:
            msgs.extend(chat_history)

        # ---- 이미지 존재 여부 힌트 (Aggregator 인지력 강화) ----
        image_count = 0
        for m in state["messages"]:
            if isinstance(m, HumanMessage) and isinstance(m.content, list):
                image_count += sum(1 for item in m.content if isinstance(item, dict) and item.get("type") == "image_url")
        
        image_hint = f"\n(Note: User has uploaded {image_count} image(s). Relevant analysis is in the Worker Results above.)" if image_count > 0 else ""

        # 현재 사용자 요청 + Worker 작업 결과를 마지막 메시지로 추가
        if past:
            final_prompt = (
                f"Current user request: {current_request}\n"
                f"Worker Results:\n" + "\n".join(f"- {r}" for r in past) +
                image_hint
            )
        else:
            final_prompt = (
                f"Current user request: {current_request}\n"
                f"(No tool results — direct conversation)" +
                image_hint
            )
        msgs.append(HumanMessage(content=final_prompt))

        response = llm.invoke(msgs)
        final_reply = getattr(response, "content", "")
        logger.info(f"[Aggregator] Final response: {final_reply}")
        return {"messages": [response]}
    return aggregator_node


# ==========================================
# Conditional Edge Parsers
# ==========================================

def route_planner(state: AgentState) -> Literal["master_router", "aggregator"]:
    """Plan이 있으면 Router로, 없으면 단순 대화이므로 Aggregator로."""
    return "master_router" if state.get("plan") else "aggregator"


def route_master_router(state: AgentState) -> Literal["vision_worker", "windows_mcp_worker", "aggregator"]:
    """Router가 선택한 worker로 이동. active_worker가 없으면 모든 계획 완료."""
    worker = state.get("active_worker", "")
    if worker in ("vision_worker", "windows_mcp_worker"):
        return worker
    return "aggregator"


def route_worker(state: AgentState) -> Literal["tools", "master_router"]:
    """
    마지막 메시지에 tool_calls가 있으면 ToolNode로, 없으면 Master Router로 복귀.
    next_step 필드 없이 메시지 타입만으로 분기하므로 human_approval 경로가 불필요합니다.
    (위험 도구는 Worker 내부에서 interrupt()로 처리)
    """
    last_msg = state["messages"][-1] if state["messages"] else None
    if last_msg and getattr(last_msg, "tool_calls", None):
        return "tools"
    return "master_router"


def route_tools(state: AgentState) -> Literal["vision_worker", "windows_mcp_worker"]:
    """도구 실행 완료 후 original_request한 Worker로 정확히 복귀."""
    return state.get("active_worker", "windows_mcp_worker")


def route_entry(state: AgentState) -> Literal["planner", "master_router", "vision_worker", "windows_mcp_worker"]:

    """
    진입점 라우터.
    MemorySaver가 이전 상태를 복원하므로, 현재 상태를 보고 어느 노드부터 재개할지 결정합니다.

    우선순위:
    1. 마지막 메시지가 ToolMessage + active_worker 있음 → Worker로 복귀 (도구 실행 후)
    2. 진행 중인 plan/active_worker 있음 → master_router로 (계획 진행 중)
    3. 그 외 → planner (새 대화 시작)
    """
    last_msg = state["messages"][-1] if state.get("messages") else None
    if isinstance(last_msg, ToolMessage) and state.get("active_worker"):
        return state["active_worker"]
    if state.get("plan") or state.get("active_worker"):
        return "master_router"
    return "planner"

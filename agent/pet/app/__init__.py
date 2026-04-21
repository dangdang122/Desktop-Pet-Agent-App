import os
import uuid
import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
AGENT_SERVER_URL = os.getenv("AGENT_SERVER_URL", "http://localhost:8001")


def create_app() -> FastAPI:
    # ==========================================
    # Pet App Server (port 8000)
    # PySide6 UI와 Agent Server(8001) 사이의 중간 계층입니다.
    # 향후 로컬 Tool 실행 명령을 수신/중계하는 역할도 담당하게 됩니다.
    #
    # [세션 관리 방식]
    # Pet App Server가 session_id를 직접 발급하고 PySide6에 쿠키로 내려줍니다.
    # Agent Server의 쿠키를 중계하는 방식은 httpx 헤더 처리 특성상 불안정하므로
    # Pet App Server가 세션을 독립적으로 관리하는 것이 더 안정적입니다.
    # ==========================================
    app = FastAPI(
        title="Desktop Pet - App Server",
        description="PySide6 UI와 Agent Server 사이의 중간 계층.",
    )

    # ==========================================
    # 요청/응답 스키마
    # ==========================================
    class ChatRequest(BaseModel):
        message: str

    class ApprovalRequest(BaseModel):
        approve: bool
        tool_call_id: str

    @app.post("/chat")
    async def chat_endpoint(request: ChatRequest, req: Request):
        """
        사용자 메시지를 Agent Server로 전달하고 응답을 반환합니다.

        세션 관리:
        - PySide6가 보낸 쿠키에서 session_id를 읽습니다.
        - session_id가 없으면 Pet App Server가 직접 발급합니다.
        - 발급된 session_id를 PySide6에 쿠키로 내려주고, Agent Server로도 전달합니다.
        """
        # PySide6 requests.Session이 보유한 session_id 읽기 (없으면 신규 발급)
        session_id = req.cookies.get("session_id") or str(uuid.uuid4())

        try:
            async with httpx.AsyncClient() as client:
                agent_resp = await client.post(
                    f"{AGENT_SERVER_URL}/chat",
                    json={
                        "message": request.message,
                        "session_id": session_id,  # 쿠키 유실 대비 이중 안전장치
                    },
                    cookies={"session_id": session_id},
                    timeout=180.0,
                )

            # Pet App Server가 직접 Set-Cookie를 발급 (Agent Server의 쿠키 중계 불필요)
            response = JSONResponse(content=agent_resp.json())
            response.set_cookie(
                key="session_id",
                value=session_id,
                httponly=True,
                samesite="lax",
            )
            return response

        except httpx.ConnectError:
            return JSONResponse(
                content={
                    "status": "error",
                    "message": f"Agent Server({AGENT_SERVER_URL})에 연결할 수 없습니다. Agent Server가 실행 중인지 확인하세요.",
                },
                status_code=503,
            )
        except Exception as e:
            return JSONResponse(
                content={"status": "error", "message": str(e)},
                status_code=500,
            )

    @app.post("/approve")
    async def approve_endpoint(request: ApprovalRequest, req: Request):
        """
        사용자의 승인/거절 결과를 Agent Server로 전달합니다.

        세션 관리:
        - PySide6 requests.Session이 자동으로 보내는 session_id 쿠키를 읽습니다.
        - 해당 session_id를 Agent Server로 전달하여 중단된 그래프를 재개합니다.
        """
        session_id = req.cookies.get("session_id")
        if not session_id:
            return JSONResponse(
                content={"status": "error", "message": "세션이 없습니다. 새로 대화를 시작해주세요."},
                status_code=400,
            )

        try:
            async with httpx.AsyncClient() as client:
                agent_resp = await client.post(
                    f"{AGENT_SERVER_URL}/approve",
                    json={
                        "approve": request.approve,
                        "tool_call_id": request.tool_call_id,
                        "session_id": session_id,  # 쿠키 유실 대비 이중 안전장치
                    },
                    cookies={"session_id": session_id},
                    timeout=180.0,
                )

            response = JSONResponse(content=agent_resp.json())
            # 쿠키 만료 방지: 매 응답마다 갱신
            response.set_cookie(
                key="session_id",
                value=session_id,
                httponly=True,
                samesite="lax",
            )
            return response

        except httpx.ConnectError:
            return JSONResponse(
                content={
                    "status": "error",
                    "message": "Agent Server에 연결할 수 없습니다.",
                },
                status_code=503,
            )
        except Exception as e:
            return JSONResponse(
                content={"status": "error", "message": str(e)},
                status_code=500,
            )

    return app

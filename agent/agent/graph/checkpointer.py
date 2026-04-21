import os
import logging

logger = logging.getLogger(__name__)


def get_checkpointer():
    """
    환경변수 DATABASE_URL에 따라 적합한 체크포인터를 반환합니다.

    [지금  MVP] DATABASE_URL 미설정 → MemorySaver (메모리 기반, 재시작 시 초기화)
    [나중 운영] DATABASE_URL 설정    → PostgresSaver (DB 영구 저장, 다중 사용자 지원)

    나중에 다중 사용자/영구 저장이 필요할 때, .env에 DATABASE_URL을 추가하는 것만으로
    코드 변경 없이 자동 전환됩니다.
    """
    db_url = os.getenv("DATABASE_URL")

    if db_url:
        try:
            from langgraph.checkpoint.postgres import PostgresSaver
            logger.info("[Checkpointer] PostgresSaver 사용 (DB 영구 저장 모드)")
            return PostgresSaver.from_conn_string(db_url)
        except ImportError:
            logger.warning(
                "[Checkpointer] langgraph-checkpoint-postgres 패키지가 없습니다. "
                "MemorySaver로 대체합니다. (pip install langgraph-checkpoint-postgres)"
            )

    from langgraph.checkpoint.memory import MemorySaver
    logger.info("[Checkpointer] MemorySaver 사용 (메모리 기반 MVP 모드)")
    return MemorySaver()

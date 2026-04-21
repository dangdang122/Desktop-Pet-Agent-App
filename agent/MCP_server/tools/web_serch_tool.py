from duckduckgo_search import DDGS

# ==========================================
# MCP_server/tools/web_serch_tool.py
# Web Search Tool: AI 모델이 외부의 최신 정보를 검색하여 답변할 수 있게 해주는 기능입니다.
# DDGS(DuckDuckGo Search) 라이브러리를 사용하여 빠르고 제약 없는 검색을 수행합니다.
# ==========================================


def search_web(query: str) -> str:
    """
    주어진 질의(query)를 바탕으로 DuckDuckGo 무료 검색엔진을 돌려 5개의 결과를 받아옵니다.
    """
    try:
        # 1. 실제 검색 요청 날리기
        results = DDGS().text(query, max_results=5)
        if not results:
            return "검색 결과가 없습니다."
        
        # 2. AI 언어 모델이 보기 좋게 텍스트로 요약 (제목, 링크 주소, 내용 발췌문)
        formatted = ""
        for i, res in enumerate(results):
            title = res.get('title', 'No Title')
            href = res.get('href', '')
            body = res.get('body', '')
            
            # [1] 위키피디아 제목 \n URL: https://... \n 요약: 파이썬은 어쩌구저쩌구 \n\n
            formatted += f"[{i+1}] {title}\nURL: {href}\n요약: {body}\n\n"
            
        return formatted.strip()
    except Exception as e:
        return f"Search Error: {str(e)}"

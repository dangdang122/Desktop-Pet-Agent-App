# Desktop Pet Agent

<img width="1536" height="1024" alt="프로젝트logo" src="https://github.com/user-attachments/assets/485706df-908c-4873-96da-6db80db1f082" />

Desktop Pet Agent는 데스크톱 화면 위에서 동작하는 캐릭터 기반 인터페이스와 고성능 AI Agent 기능을 결합한 프로그램입니다. LangGraph 기반의 멀티 에이전트 아키텍처를 사용하여 복잡한 작업을 계획하고 실행하며, 사용자와의 자연스러운 상호작용을 지원합니다.

<br>

# 프로그램 작동 예시
|항목|사진|
|--|--|
|Text 명령 입력|<img width="553" height="311" alt="예시1" src="https://github.com/user-attachments/assets/a8f52a12-718e-4a8a-86c8-9069198c666f" />|
|클릭 시 표시 메뉴|<img width="334" height="189" alt="예시2" src="https://github.com/user-attachments/assets/bca6ee3b-73cb-416b-9d43-a4b89a054970" />|

---
<br>

## 🚀 시작하기

### 1. 환경 요구 사양
- **OS**: Windows 10/11 (필수, Windows 기반 MCP 사용)
- **Python**: 3.11 이상
- **Conda**: 다중 시스템 환경 관리를 위해 필수

<br>

### 2. 설치 방법

프로젝트는 Agent 서버, Pet UI, 그리고 MCP 서버를 위해 총 3개의 분리된 Conda 환경을 사용합니다. 

```bash
# 1. MCP 서버 환경 설정 (스크린샷, 마우스/키보드 제어 등 OS 상호작용)
cd mcp
conda env create -f environment.yml
conda activate mcp

# 2. Agent 서버 환경 설정 (LangGraph 기반 AI 모델 서버)
cd agent
conda env create -f environment.yml
conda activate desktop-pet-agent

# 3. Pet UI 환경 설정 (사용자 인터페이스)
cd pet
conda env create -f environment.yml
conda activate pet-ui
```

<br>

### 3. 환경 변수 설정 (`.env`)

`agent/` 디렉토리에 `.env.example` 파일 이름을 `env`로 수정하고, 사용자 환경에 맞게 수정합니다.

<br>

## 🖥️ 실행 방법

프로그램을 실행하려면 **Agent 서버**를 먼저 실행한 후, **Pet UI**를 실행해야 합니다.

### Step 1: Agent 서버 실행
```bash
cd agent
conda activate desktop-pet-agent
python main.py
```
- Agent 서버는 `localhost:8001`에서 대기하며 요청을 처리합니다.

### Step 2: Pet UI & App 서버 실행
```bash
cd pet
conda activate pet-ui
python main.py
```
- UI가 별도 스레드에서 실행되며, App 서버는 `localhost:8000`에서 실행되어 UI와 Agent 사이의 중계 역할을 합니다.

<br>

## 🏗️ 시스템 아키텍처

이 프로젝트는 **Plan-and-Execute** 모델을 기반으로 하는 멀티 에이전트 구조를 채택하고 있습니다.

- **Planner**: 사용자 요청을 분석하여 단계별 실행 계획을 수립합니다.
- **Master Router**: 현재 작업을 처리할 워커로 적절하게 태스크를 라우팅합니다.
- **Windows MCP Worker**: `windows-mcp`를 통해 화면 캡처, OCR, 윈도우 파일 시스템 조작, 파워쉘 제어, 브라우저 관리 및 데스크탑 상호작용의 모든 역할을 수행하는 전문가 노드입니다.
- **Aggregator**: 모든 작업 결과를 취합하여 사용자에게 친절한 답변을 생성합니다.
- **MemorySaver**: 대화 내용 및 에이전트의 상태를 스레드별로 유지하여 멀티 턴 대화를 지원합니다.

<br>

## ✨ 주요 기능
- **캐릭터 기반 GUI**: 화면 위를 자유롭게 이동하며 상호작용하는 펫 캐릭터.
- **MCP 기반 OS 제어 (Windows MCP)**: 마우스/키보드 직접 입력, 스크린샷 바탕의 시각적 인식, 쉘(Shell) 조작 등을 통한 완벽한 데스크탑 제어.
- **지능형 작업 실행**: 복잡한 명령(예: "브라우저를 켜서 닐슨 노먼 그룹 홈페이지에 들어가줘")을 언어 모델이 인지하고 단계별 분할 실행.
- **Human-in-the-Loop**: 위험한 파워쉘 명령어 작동 등 파괴적 행동 수행 전 Agent UI를 통한 사전 승인 체계.
- **상태 최적화 기술**: 이미지 전송 토큰 비용을 줄이기 위한 Context History 최적화 (순수 텍스트 히스토리 필터링).

<br>

## 🛠️ 기술 스택
- **Backend (Agent)**: FastAPI, LangChain, LangGraph
- **Backend (MCP)**: windows-mcp (Model Context Protocol 표준)
- **Frontend (UI)**: PySide6 (Python Qt)
- **Database**: MemorySaver (MVP), PostgresSaver (Production ready)

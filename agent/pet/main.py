import sys
import threading
import time
import uvicorn

from app import create_app
from app.pet_window import PetWindow, QApplication
from app.chat_window import ChatWindow, ChatSignaler

def run_ui():
    """별도 스레드에서 UI 실행"""
    app = QApplication(sys.argv)
    pet = PetWindow()
    pet.show()
    sys.exit(app.exec())

if __name__ == "__main__":
    # UI를 별도 스레드에서 먼저 실행
    print("[1/2] Starting Pet UI in thread...")
    ui_thread = threading.Thread(target=run_ui, daemon=False)
    ui_thread.start()
    
    # UI가 시작될 때까지 대기
    time.sleep(2)
    
    # 이후 서버를 메인 스레드에서 실행
    print("[2/2] Starting Pet App Server...")
    app = create_app()
    uvicorn.run(app, host="0.0.0.0", port=8000)
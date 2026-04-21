import threading
import requests
import html

from PySide6.QtWidgets import QWidget, QTextEdit, QVBoxLayout, QPushButton, QHBoxLayout, QApplication, QFrame, QGraphicsDropShadowEffect
from PySide6.QtCore import Qt, Signal, QObject, QRectF
from PySide6.QtGui import QColor, QPainter, QPainterPath, QPen

from app.chat_style import (
    CHAT_HISTORY_STYLE, 
    APPROVE_BTN_STYLE, 
    REJECT_BTN_STYLE, 
    INPUT_FIELD_STYLE, 
    CLOSE_BTN_STYLE,
    WINDOW_WIDTH,
    WINDOW_HEIGHT,
    USER_MSG_FORMAT,
    PET_MSG_FORMAT,
    ERROR_MSG_FORMAT
)

class ChatSignaler(QObject):
    response_received = Signal(dict)
    error_occurred = Signal(str)

class ChatInputField(QTextEdit):
    returnPressed = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setFixedHeight(50)
        self.setAcceptRichText(False)

    def keyPressEvent(self, event):
        if event.key() == Qt.Key_Return and not event.modifiers() & Qt.ShiftModifier:
            self.returnPressed.emit()
            event.accept()
        else:
            super().keyPressEvent(event)

class BubbleFrame(QFrame):
    def __init__(self, parent=None):
        super().__init__(parent)

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.Antialiasing)
        
        rect = self.rect()
        tail_height = 15
        tail_width = 20
        radius = 15
        
        body_rect = QRectF(1, 1, rect.width() - 2, rect.height() - tail_height - 2)
        
        path = QPainterPath()
        path.moveTo(body_rect.left() + radius, body_rect.top())
        path.lineTo(body_rect.right() - radius, body_rect.top())
        path.arcTo(body_rect.right() - 2*radius, body_rect.top(), 2*radius, 2*radius, 90, -90)
        
        path.lineTo(body_rect.right(), body_rect.bottom() - radius)
        path.arcTo(body_rect.right() - 2*radius, body_rect.bottom() - 2*radius, 2*radius, 2*radius, 0, -90)
        
        center_x = body_rect.center().x()
        path.lineTo(center_x + tail_width/2, body_rect.bottom())
        path.lineTo(center_x, body_rect.bottom() + tail_height) 
        path.lineTo(center_x - tail_width/2, body_rect.bottom())
        
        path.lineTo(body_rect.left() + radius, body_rect.bottom())
        path.arcTo(body_rect.left(), body_rect.bottom() - 2*radius, 2*radius, 2*radius, -90, -90)
        
        path.lineTo(body_rect.left(), body_rect.top() + radius)
        path.arcTo(body_rect.left(), body_rect.top(), 2*radius, 2*radius, 180, -90)
        
        path.closeSubpath()
        
        painter.fillPath(path, QColor(255, 255, 255, 245))

        pen = QPen(QColor("#e0e0e0"))
        pen.setWidth(2)
        painter.setPen(pen)
        painter.drawPath(path)

class ChatWindow(QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowFlags(Qt.Tool | Qt.FramelessWindowHint)
        self.setAttribute(Qt.WA_TranslucentBackground)
        
        main_layout = QVBoxLayout(self)
        main_layout.setContentsMargins(15, 15, 15, 15)
        
        self.container = BubbleFrame(self)
        self.container.setObjectName("main_container")
        
        shadow = QGraphicsDropShadowEffect(self)
        shadow.setBlurRadius(15)
        shadow.setColor(QColor(0, 0, 0, 80))
        shadow.setOffset(0, 5)
        self.container.setGraphicsEffect(shadow)
        
        layout = QVBoxLayout(self.container)
        layout.setContentsMargins(15, 15, 15, 30)

        self.is_shutting_down = False

        self.message_history = []
        
        self.chat_history = QTextEdit()
        self.chat_history.setReadOnly(True)
        self.chat_history.setStyleSheet(CHAT_HISTORY_STYLE)
        
        self.btn_area = QWidget()
        self.btn_layout = QHBoxLayout(self.btn_area)
        self.btn_layout.setContentsMargins(5, 2, 5, 2)
        
        self.approve_btn = QPushButton("승인")
        self.reject_btn = QPushButton("거절")
        
        self.approve_btn.setStyleSheet(APPROVE_BTN_STYLE)
        self.reject_btn.setStyleSheet(REJECT_BTN_STYLE)
        
        self.approve_btn.clicked.connect(lambda: self.process_btn("approved"))
        self.reject_btn.clicked.connect(lambda: self.process_btn("rejected"))
        
        self.btn_layout.addWidget(self.approve_btn)
        self.btn_layout.addWidget(self.reject_btn)
        self.btn_area.hide()

        self.input_field = ChatInputField()
        self.input_field.setPlaceholderText("무엇을 도와드릴까요? (Shift+Enter: 줄바꿈)")
        self.input_field.setStyleSheet(INPUT_FIELD_STYLE)
        self.input_field.returnPressed.connect(self.send_message)
        
        bottom_layout = QHBoxLayout()
        self.close_btn = QPushButton("종료")
        self.close_btn.setStyleSheet(CLOSE_BTN_STYLE)
            
        self.close_btn.clicked.connect(self.close_program)
        
        bottom_layout.addStretch()
        bottom_layout.addWidget(self.close_btn)

        layout.addWidget(self.chat_history)
        layout.addWidget(self.btn_area)
        layout.addWidget(self.input_field)
        layout.addLayout(bottom_layout)
        
        main_layout.addWidget(self.container)
        self.resize(WINDOW_WIDTH, WINDOW_HEIGHT)
        
        self.signaler = ChatSignaler()
        self.signaler.response_received.connect(self.on_response_received)
        self.signaler.error_occurred.connect(self.on_error_occurred)

        self.pending_tool_call_id = None
        self.session_id = None
        self.web_ui_url = "http://localhost:8000"
        self.session = requests.Session()

    def send_message(self):
        text = self.input_field.toPlainText().strip()
        if text:
            formatted_text = text.replace('\n', '<br>')
            
            user_html = USER_MSG_FORMAT.format(text=formatted_text)
            self.message_history.append(user_html)
            
            thinking_html = PET_MSG_FORMAT.format(text="생각 중...")
            full_html = "".join(self.message_history) + thinking_html
            self.chat_history.setHtml(full_html)
            
            self.scrollToBottom()
            
            self.input_field.clear()
            self.input_field.setEnabled(False)
            
            thread = threading.Thread(target=self.send_to_api, args=(text,))
            thread.daemon = True
            thread.start()
            
    def scrollToBottom(self):
        scrollbar = self.chat_history.verticalScrollBar()
        scrollbar.setValue(scrollbar.maximum())
    
    def send_to_api(self, data_input, endpoint="/chat"):
        try:
            json_data = {"message": data_input} if isinstance(data_input, str) else data_input
            if self.session_id:
                json_data["session_id"] = self.session_id
            
            response = self.session.post(
                f"{self.web_ui_url}{endpoint}",
                json=json_data
            )
            
            if response.status_code == 200:
                data = response.json()
                self.signaler.response_received.emit(data)
            else:
                self.signaler.error_occurred.emit(f"서버 오류 ({response.status_code})")
        except Exception:
            self.signaler.error_occurred.emit(f"연결 오류 발생")
    
    def on_response_received(self, data: dict):
        if self.is_shutting_down:
            QApplication.instance().quit()
            return
            
        reply = data.get("response") or data.get("message") or str(data)
        formatted_reply = reply.replace('\n', '<br>')
        
        pet_html = PET_MSG_FORMAT.format(text=formatted_reply)
        self.message_history.append(pet_html)
        
        self.chat_history.setHtml("".join(self.message_history))
        self.scrollToBottom()
        
        if data.get("session_id"): self.session_id = data["session_id"]
        self.pending_tool_call_id = data.get("tool_call_id")
        
        is_waiting = (data.get("status") == "approval_required")
        self.btn_area.setVisible(is_waiting)
        self.input_field.setEnabled(not is_waiting)
        if not is_waiting: self.input_field.setFocus()

    def process_btn(self, choice: str):
        self.btn_area.hide()
        is_approved = (choice == "approved")
        choice_text = "승인" if is_approved else "거절"
        
        user_msg = USER_MSG_FORMAT.format(text=f"[{choice_text}] 하겠어.")
        self.message_history.append(user_msg)
        
        thinking_html = PET_MSG_FORMAT.format(text="결과를 서버에 전달하는 중...")
        full_html = "".join(self.message_history) + thinking_html
        self.chat_history.setHtml(full_html)
        self.scrollToBottom()

        payload = {
            "approve": is_approved,
            "tool_call_id": self.pending_tool_call_id
        }

        thread = threading.Thread(target=self.send_to_api, args=(payload, "/approve"))
        thread.daemon = True
        thread.start()

    def on_error_occurred(self, error: str):
        safe_error = html.escape(error)
        
        error_msg = ERROR_MSG_FORMAT.format(text=safe_error)
        self.message_history.append(error_msg)
        self.chat_history.setHtml("".join(self.message_history))
        self.scrollToBottom()
        
        self.input_field.setEnabled(True)
        self.input_field.setFocus()

    def close_program(self):
        self.is_shutting_down = True
        
        if hasattr(self, 'session') and self.session:
            self.session.close()
            
        QApplication.instance().quit()
        
        import os
        os._exit(0)
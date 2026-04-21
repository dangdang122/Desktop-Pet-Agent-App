import random
from PySide6.QtWidgets import QWidget, QLabel, QApplication
from PySide6.QtCore import Qt, QTimer
from PySide6.QtGui import QMovie

from app.chat_window import ChatWindow
from app.pet_style import (
    PET_WIDTH, 
    PET_HEIGHT, 
    PET_MOVIE_PATH, 
    CHAT_WIN_OFFSET_X, 
    CHAT_WIN_OFFSET_Y,
    MOVEMENT_X_MIN_RATIO,
    MOVEMENT_X_MAX_RATIO,
    MOVEMENT_Y_MIN_RATIO,
    MOVEMENT_Y_MAX_RATIO
)

class PetWindow(QWidget):
    def __init__(self):
        super().__init__()

        self.setWindowFlags(Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint | Qt.SplashScreen) 
        self.setAttribute(Qt.WA_TranslucentBackground) 
        self.resize(PET_WIDTH, PET_HEIGHT) 

        self.pet_label = QLabel(self)
        self.pet_label.setAttribute(Qt.WA_TransparentForMouseEvents) 
        self.pet_label.setGeometry(0, 0, PET_WIDTH, PET_HEIGHT) 
        self.pet_label.setAlignment(Qt.AlignCenter)  
        self.pet_label.setScaledContents(True) 
        
        self.movie = QMovie(PET_MOVIE_PATH) 
        self.pet_label.setMovie(self.movie)
        self.movie.start()

        screen_geo = self.screen().availableGeometry()
        width, height = screen_geo.width(), screen_geo.height()
        
        self.min_x, self.max_x = width * MOVEMENT_X_MIN_RATIO, width * MOVEMENT_X_MAX_RATIO - self.width()
        self.min_y, self.max_y = height * MOVEMENT_Y_MIN_RATIO, height * MOVEMENT_Y_MAX_RATIO - self.height()

        self.curr_x = random.uniform(self.min_x, self.max_x)
        self.curr_y = random.uniform(self.min_y, self.max_y)
        self.move(int(self.curr_x), int(self.curr_y))

        self.timer = QTimer(self)
        self.timer.timeout.connect(self.update_logic)
        self.timer.start(16) 
        
        self.x_speed, self.y_speed = 0.5, 0.5
        self.change_dir_timer = 0 
        self.is_interacting = False 
        self.chat_win = ChatWindow()

    def update_logic(self):
        if self.is_interacting: return 
        
        self.change_dir_timer += 1
        if self.change_dir_timer > 100: 
            self.x_speed = random.uniform(-1.0, 1.0)
            self.y_speed = random.uniform(-1.0, 1.0)
            self.change_dir_timer = 0

        self.curr_x += self.x_speed
        self.curr_y += self.y_speed

        if self.curr_x <= self.min_x or self.curr_x >= self.max_x:
            self.x_speed *= -1
        if self.curr_y <= self.min_y or self.curr_y >= self.max_y:
            self.y_speed *= -1
            
        self.curr_x = max(self.min_x, min(self.curr_x, self.max_x))
        self.curr_y = max(self.min_y, min(self.curr_y, self.max_y))
        self.move(int(self.curr_x), int(self.curr_y))

    def mousePressEvent(self, event):
        if event.button() == Qt.LeftButton:
            self.interact_with_pet()

    def interact_with_pet(self):
        self.is_interacting = not self.is_interacting
        if self.is_interacting:
            pet_center_x = self.x() + (self.width() // 2)

            chat_x = pet_center_x - (self.chat_win.width() // 2)

            chat_y = self.y() - self.chat_win.height() - 15
            
            self.chat_win.move(chat_x, chat_y)
            self.chat_win.show()
            self.chat_win.input_field.setFocus()
        else:
            self.chat_win.hide()
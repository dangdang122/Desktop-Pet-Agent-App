MAIN_CONTAINER_STYLE = """
QFrame#main_container {
    background-color: #FFFFFF;
    border: 1px solid #D1D1D1;
    border-radius: 20px;
}
"""

FONT_FAMILY = "'Pretendard', 'Apple SD Gothic Neo', 'Malgun Gothic', '맑은 고딕', sans-serif"

CHAT_HISTORY_STYLE = f"""
QTextEdit {{
    background-color: transparent;
    border: none;
    color: #333333;
    font-family: {FONT_FAMILY};
    line-height: 150%;
}}
"""

BTN_BASE_STYLE = "color: white; border-radius: 8px; font-weight: bold; padding: 6px; font-size: 12px;"
APPROVE_BTN_STYLE = f"background-color: #5cb85c; {BTN_BASE_STYLE}"
REJECT_BTN_STYLE = f"background-color: #d9534f; {BTN_BASE_STYLE}"

INPUT_FIELD_STYLE = """
QLineEdit {
    background-color: #F2F2F2;
    color: black;
    border-radius: 15px;
    border: 1px solid #E0E0E0;
    padding: 8px 12px;
    font-size: 13px;
}
QLineEdit:focus {
    border: 1px solid #A0A0A0;
}
"""

CLOSE_BTN_STYLE = "background-color: #FF5F56; color: white; border-radius: 10px; font-weight: bold; font-size: 11px;"

WINDOW_WIDTH = 300
WINDOW_HEIGHT = 400

USER_MSG_FORMAT = f"""
<table width='100%' border='0' cellspacing='0' cellpadding='0' style='margin-bottom: 15px;'>
    <tr>
        <td width='20%'></td> <td width='80%' align='right'>
            <div style='color: #888888; font-size: 11px; margin-bottom: 4px; margin-right: 2px;'>나</div>
            <table border='0' cellspacing='0' cellpadding='10' style='background-color: #FEE500; border-radius: 14px;'>
                <tr>
                    <td>
                        <span style='color: #111111; font-family: {FONT_FAMILY}; font-size: 13px; font-weight: 500;'>{{text}}</span>
                    </td>
                </tr>
            </table>
        </td>
    </tr>
</table>
"""

PET_MSG_FORMAT = f"""
<table width='100%' border='0' cellspacing='0' cellpadding='0' style='margin-bottom: 15px;'>
    <tr>
        <td width='80%' align='left'>
            <div style='color: #888888; font-size: 11px; margin-bottom: 4px; margin-left: 2px;'>🐾 펫</div>
            <table border='0' cellspacing='0' cellpadding='10' style='background-color: #E3F2FD; border-radius: 14px;'>
                <tr>
                    <td>
                        <span style='color: #111111; font-family: {FONT_FAMILY}; font-size: 13px; font-weight: 500; line-height: 1.4;'>{{text}}</span>
                    </td>
                </tr>
            </table>
        </td>
        <td width='20%'></td> </tr>
</table>
"""

ERROR_MSG_FORMAT = f"""
<div align='center' style='margin: 10px 0;'>
    <table border='0' cellspacing='0' cellpadding='5' style='background-color: #FFEBEB; border-radius: 10px;'>
        <tr><td><span style='color: #FF0000; font-family: {FONT_FAMILY}; font-size: 11px;'>⚠️ {{text}}</span></td></tr>
    </table>
</div>
"""
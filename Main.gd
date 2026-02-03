extends Control

# --- 節點引用 ---
@onready var ui_layer = $UI_Layer
@onready var ui_editor = $UI_Layer/Editor
@onready var ui_runtime = $UI_Layer/RuntimeVisual # 這是我們要搬運的視覺總成
@onready var start_btn = $UI_Layer/Editor/Split/Left_Visual/StartVisualBtn # 引用按鈕以便改文字

# 視覺節點
@onready var photo_rect = $UI_Layer/RuntimeVisual/PhotoRect
# 音訊節點
@onready var audio_list_container = $UI_Layer/Editor/Split/Right_Audio/Scroll/AudioListContainer
# 計時器
@onready var audio_player: AudioStreamPlayer = $AudioPlayer
@onready var photo_timer = $PhotoTimer
@onready var sys_timer = $SystemTimer

# UI 元件
@onready var path_label = $UI_Layer/Editor/Split/Left_Visual/PathLabel
@onready var interval_spin = $UI_Layer/Editor/Split/Left_Visual/HBox/IntervalSpin
@onready var auto_check = $UI_Layer/Editor/Split/Right_Audio/TopBar/AutoCheck

# Dialogs
@onready var photo_dialog = $PhotoDialog
@onready var audio_dialog = $AudioDialog

# --- 資料變數 ---
var config_path = "user://multimedia_console_config.json"
var visual_files: Array = [] 
var visual_index: int = 0
var current_visual_dir: String = ""
var last_triggered_time_str: String = ""

# --- 多視窗變數 ---
var projection_window: Window = null # 用來參照第二個視窗

func _ready():
    # 1. 視覺部分連接
    $UI_Layer/Editor/Split/Left_Visual/PhotoDirBtn.pressed.connect(func(): photo_dialog.popup())
    
    # 修改：按鈕按下時，判斷是開啟還是關閉
    start_btn.pressed.connect(_toggle_projection)
    
    photo_dialog.dir_selected.connect(_on_visual_dir_selected)
    
    photo_timer.timeout.connect(_play_next_visual_item)

    
    # 2. 運行時輸入偵測 (這個改為僅偵測該節點的輸入)
    ui_runtime.gui_input.connect(_on_runtime_gui_input)
    
    # 3. 音訊部分連接
    $UI_Layer/Editor/Split/Right_Audio/AddFilesBtn.pressed.connect(func(): audio_dialog.popup())
    audio_dialog.files_selected.connect(_on_audio_files_batch_selected)
    sys_timer.timeout.connect(_on_system_timer_tick)
    $UI_Layer/Editor/Split/Right_Audio/TopBar/AutoCheck.toggled.connect(func(t): save_config())

    # 停止按鈕(音量淡出)
    # 假設你有 StopBtn (原本在 Runtime 介面，現在 Editor 應該也要有，或直接用音訊列的控制)
    # 這裡保留基本的邏輯
    
    load_config()

# --- 雙螢幕視窗控制系統 (核心修改) ---

func _toggle_projection():
    if projection_window == null:
        _start_projection()
    else:
        _stop_projection()

func _start_projection():
    if visual_files.size() == 0: 
        print("沒有檔案可播放")
        return

    save_config()
    
    # 1. 建立新視窗
    projection_window = Window.new()
    projection_window.title = "Projector Output"
    
    # 2. 偵測螢幕
    var screen_count = DisplayServer.get_screen_count()
    print("偵測到螢幕數量: ", screen_count)
    
    # 設定視窗模式
    if screen_count > 1:
        # 有第二個螢幕，丟到螢幕 1 (通常 0 是主螢幕)
        projection_window.current_screen = 1
        projection_window.mode = Window.MODE_EXCLUSIVE_FULLSCREEN
    else:
        # 只有一個螢幕，用視窗模式測試 (方便你開發)
        projection_window.mode = Window.MODE_WINDOWED
        projection_window.size = Vector2(960, 540)
    
    # 3. 關鍵：搬運節點 (Reparenting)
    # 先把 ui_runtime 從原本的 UI_Layer 移除 (但不要 free 釋放記憶體)
    ui_layer.remove_child(ui_runtime)
    # 加到新視窗
    projection_window.add_child(ui_runtime)
    
    # 4. 把新視窗加到場景樹
    add_child(projection_window)
    
    # 5. 初始化顯示狀態
    ui_runtime.show()
    # 確保在全螢幕下填滿
    ui_runtime.set_anchors_preset(Control.PRESET_FULL_RECT)
    
    # 監聽視窗關閉請求 (比如按了 Alt+F4)
    projection_window.close_requested.connect(_stop_projection)
    
    # 6. 開始播放邏輯
    photo_timer.wait_time = interval_spin.value
    photo_rect.texture = null
    photo_rect.hide()
    
    # UI 狀態更新
    start_btn.text = "停止投影 (投影中...)"
    start_btn.modulate = Color(1, 0.5, 0.5) # 變紅色提醒
    
    visual_index = -1
    _play_next_visual_item()

func _stop_projection():
    if projection_window:
        # 1. 把小孩抱回家 (搬回主視窗)
        projection_window.remove_child(ui_runtime)
        ui_layer.add_child(ui_runtime)
        
        # 2. 隱藏並重置
        ui_runtime.hide()
        photo_timer.stop()
        
        # 3. 銷毀視窗
        projection_window.queue_free()
        projection_window = null
    
    # UI 狀態還原
    start_btn.text = "開始全螢幕輪播"
    start_btn.modulate = Color(1, 1, 1)

# 支援在新視窗雙擊退出
func _on_runtime_gui_input(event):
    if event is InputEventMouseButton:
        if event.button_index == MOUSE_BUTTON_LEFT and event.double_click:
            _stop_projection()
    # 支援在新視窗按 ESC 退出
    if event is InputEventKey:
        if event.pressed and event.keycode == KEY_ESCAPE:
            _stop_projection()

# --- 視覺輪播邏輯 (保持不變) ---

func _on_visual_dir_selected(path: String):
    current_visual_dir = path
    path_label.text = "路徑: " + path
    visual_files.clear()
    var dir = DirAccess.open(path)
    if dir:
        dir.list_dir_begin()
        var file = dir.get_next()
        while file != "":
            if not dir.current_is_dir():
                var ext = file.get_extension().to_lower()
                if ext in ["jpg", "png", "jpeg", "mp4", "webm", "ogv"]:
                    visual_files.append(path + "/" + file)
            file = dir.get_next()
    print("已載入視覺檔案: ", visual_files.size())

func _play_next_visual_item():
    if visual_files.size() == 0: return
    
    visual_index = (visual_index + 1) % visual_files.size()
    var path = visual_files[visual_index]
    var ext = path.get_extension().to_lower()
    
    # print("播放視覺: ", path.get_file())
    
    if ext in ["jpg", "png", "jpeg"]:
        photo_rect.show()
        
        var img = Image.load_from_file(path)
        if img:
            var tex = ImageTexture.create_from_image(img)
            var tw = create_tween()
            tw.tween_property(photo_rect, "modulate:a", 0.0, 0.5)
            tw.tween_callback(func(): photo_rect.texture = tex)
            tw.tween_property(photo_rect, "modulate:a", 1.0, 0.5)
        
        if photo_timer.is_stopped():
            photo_timer.start()
            
    elif ext in ["mp4", "webm", "ogv"]:
        photo_timer.stop()
        photo_rect.hide()


# --- 音訊控制台邏輯 (含緩進緩出與 Bug 修復) ---

func _on_audio_files_batch_selected(paths: PackedStringArray):
    for path in paths:
        _create_audio_row(path)
    save_config()

func _create_audio_row(path: String, saved_time = null, saved_loop = false):
    var row = HBoxContainer.new()
    audio_list_container.add_child(row)
    row.set_meta("file_path", path)
    
    # 刪除按鈕 (修復存檔問題)
    var del_btn = Button.new()
    del_btn.text = "X"
    del_btn.custom_minimum_size.x = 30
    del_btn.pressed.connect(func(): 
        audio_list_container.remove_child(row)
        row.queue_free()
        save_config()
    )
    row.add_child(del_btn)
    
    # 檔名
    var name_lbl = Label.new()
    name_lbl.text = path.get_file()
    name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    name_lbl.clip_text = true
    row.add_child(name_lbl)
    
    # 時間
    var now = Time.get_time_dict_from_system()
    if saved_time: now = saved_time
    
    var spin_h = SpinBox.new()
    spin_h.max_value = 23
    spin_h.value = now.hour
    spin_h.alignment = HORIZONTAL_ALIGNMENT_CENTER
    spin_h.set_meta("type", "hour")
    # 當數值改變時自動存檔
    spin_h.value_changed.connect(func(v): save_config()) 
    row.add_child(spin_h)
    
    var sep = Label.new()
    sep.text = ":"
    row.add_child(sep)
    
    var spin_m = SpinBox.new()
    spin_m.max_value = 59
    spin_m.value = now.minute
    spin_m.alignment = HORIZONTAL_ALIGNMENT_CENTER
    spin_m.set_meta("type", "minute")
    spin_m.value_changed.connect(func(v): save_config())
    row.add_child(spin_m)
    
    # 控制按鈕
    var play_btn = Button.new()
    play_btn.text = "▶"
    row.add_child(play_btn)
    
    var pause_btn = Button.new()
    pause_btn.text = "||"
    row.add_child(pause_btn)
    
    var loop_chk = CheckBox.new()
    loop_chk.text = "Loop"
    loop_chk.button_pressed = saved_loop
    loop_chk.set_meta("type", "loop")
    loop_chk.toggled.connect(func(t): save_config())
    row.add_child(loop_chk)
    
    play_btn.pressed.connect(func(): _play_row_audio(row))
    pause_btn.pressed.connect(func(): 
        if audio_player.playing and audio_player.get_meta("current_row") == row:
            audio_player.stream_paused = not audio_player.stream_paused
    )

# 緩進緩出播放
func _play_row_audio(row: Control):
    var path = row.get_meta("file_path")
    if not FileAccess.file_exists(path): return
        
    var file = FileAccess.open(path, FileAccess.READ)
    var sound = AudioStreamMP3.new()
    sound.data = file.get_buffer(file.get_length())
    
    for child in row.get_children():
        if child.has_meta("type") and child.get_meta("type") == "loop":
            sound.loop = child.button_pressed
    
    if audio_player.playing:
        var tween = create_tween()
        tween.tween_property(audio_player, "volume_db", -80.0, 0.5)
        tween.tween_callback(func(): _start_new_stream(sound, row))
    else:
        _start_new_stream(sound, row)

func _start_new_stream(sound: AudioStream, row: Control):
    audio_player.stop()
    audio_player.stream = sound
    audio_player.volume_db = -80.0
    audio_player.play()
    
    audio_player.set_meta("current_row", row)
    for c in audio_list_container.get_children():
        c.modulate = Color.WHITE
    row.modulate = Color.GREEN
    
    var tween = create_tween()
    tween.tween_property(audio_player, "volume_db", 0.0, 1.0)

# --- 自動排程 ---

func _on_system_timer_tick():
    if not auto_check.button_pressed: return
    
    var now = Time.get_time_dict_from_system()
    var current_time_str = "%02d:%02d" % [now.hour, now.minute]
    
    if current_time_str == last_triggered_time_str: return
    
    for row in audio_list_container.get_children():
        var h = 0
        var m = 0
        for child in row.get_children():
            if child.has_meta("type"):
                if child.get_meta("type") == "hour": h = child.value
                if child.get_meta("type") == "minute": m = child.value
        
        if "%02d:%02d" % [h, m] == current_time_str:
            print("自動觸發: ", row.get_meta("file_path"))
            _play_row_audio(row)
            last_triggered_time_str = current_time_str
            return 

# --- 存檔 ---

func save_config():
    var audio_data = []
    for row in audio_list_container.get_children():
        var h = 0
        var m = 0
        var loop = false
        for child in row.get_children():
            if child.has_meta("type"):
                if child.get_meta("type") == "hour": h = child.value
                if child.get_meta("type") == "minute": m = child.value
                if child.get_meta("type") == "loop": loop = child.button_pressed
        audio_data.append({ "path": row.get_meta("file_path"), "hour": h, "minute": m, "loop": loop })
    
    var data = {
        "visual_dir": current_visual_dir,
        "interval": interval_spin.value,
        "is_auto": auto_check.button_pressed,
        "audio_list": audio_data
    }
    var f = FileAccess.open(config_path, FileAccess.WRITE)
    f.store_string(JSON.stringify(data))

func load_config():
    if not FileAccess.file_exists(config_path): return
    var f = FileAccess.open(config_path, FileAccess.READ)
    var json = JSON.new()
    if json.parse(f.get_as_text()) == OK:
        var data = json.data
        current_visual_dir = data.get("visual_dir", "")
        interval_spin.value = data.get("interval", 5.0)
        auto_check.button_pressed = data.get("is_auto", false)
        if current_visual_dir != "":
            path_label.text = "路徑: " + current_visual_dir
            _on_visual_dir_selected(current_visual_dir)
        for item in data.get("audio_list", []):
            _create_audio_row(item.path, {"hour": item.hour, "minute": item.minute}, item.loop)

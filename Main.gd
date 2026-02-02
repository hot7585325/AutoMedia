extends Control

# --- 節點引用 ---
@onready var ui_editor = $UI_Layer/Editor
@onready var ui_runtime = $UI_Layer/RuntimeVisual
@onready var photo_rect = $UI_Layer/RuntimeVisual/PhotoRect
@onready var audio_list_container = $UI_Layer/Editor/Split/Right_Audio/Scroll/AudioListContainer
@onready var photo_timer = $PhotoTimer
@onready var sys_timer = $SystemTimer
@onready var audio_player: AudioStreamPlayer = $AudioPlayer

# UI 元件
@onready var path_label = $UI_Layer/Editor/Split/Left_Visual/PathLabel
@onready var interval_spin = $UI_Layer/Editor/Split/Left_Visual/HBox/IntervalSpin
@onready var auto_check = $UI_Layer/Editor/Split/Right_Audio/TopBar/AutoCheck

# Dialogs
@onready var photo_dialog = $PhotoDialog
@onready var audio_dialog = $AudioDialog

# --- 資料變數 ---
var config_path = "user://audio_console_config.json"
var photo_files: Array = []
var photo_index: int = 0
var current_photo_dir: String = ""

# 記錄最後一次自動觸發的時間字串，避免一分鐘內重複觸發
var last_triggered_time_str: String = ""

func _ready():
	# 1. 視覺部分連接
	$UI_Layer/Editor/Split/Left_Visual/PhotoDirBtn.pressed.connect(func(): photo_dialog.popup())
	$UI_Layer/Editor/Split/Left_Visual/StartVisualBtn.pressed.connect(_enter_runtime_visual)
	photo_dialog.dir_selected.connect(_on_photo_dir_selected)
	photo_timer.timeout.connect(_next_photo)
	
	# 2. 運行時輸入偵測 (雙擊/ESC)
	ui_runtime.gui_input.connect(_on_runtime_gui_input)
	
	# 3. 音訊部分連接
	$UI_Layer/Editor/Split/Right_Audio/AddFilesBtn.pressed.connect(func(): audio_dialog.popup())
	audio_dialog.files_selected.connect(_on_audio_files_batch_selected)
	sys_timer.timeout.connect(_on_system_timer_tick)
	
	# 4. 載入存檔
	load_config()

func _input(event):
	# 全域偵測 ESC 鍵，用於離開全螢幕播放
	if ui_runtime.visible and event.is_action_pressed("ui_cancel"):
		_exit_runtime_visual()

# --- 視覺輪播邏輯 ---

func _on_photo_dir_selected(path: String):
	current_photo_dir = path
	path_label.text = "路徑: " + path
	# 掃描檔案
	photo_files.clear()
	var dir = DirAccess.open(path)
	if dir:
		dir.list_dir_begin()
		var file = dir.get_next()
		while file != "":
			if not dir.current_is_dir():
				var ext = file.get_extension().to_lower()
				if ext in ["jpg", "png", "jpeg"]:
					photo_files.append(path + "/" + file)
			file = dir.get_next()
	print("已載入照片: ", photo_files.size(), " 張")

func _enter_runtime_visual():
	# 儲存設定
	save_config()
	
	# 切換介面
	ui_editor.hide()
	ui_runtime.show()
	
	# 啟動 Timer
	photo_timer.wait_time = interval_spin.value
	if photo_files.size() > 0:
		photo_index = -1
		photo_timer.start()
		_next_photo()

func _exit_runtime_visual():
	ui_runtime.hide()
	ui_editor.show()
	photo_timer.stop()
	photo_rect.texture = null # 清空畫面

func _on_runtime_gui_input(event):
	# 偵測雙擊滑鼠左鍵
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.double_click:
			_exit_runtime_visual()

func _next_photo():
	if photo_files.size() == 0: return
	
	photo_index = (photo_index + 1) % photo_files.size()
	var path = photo_files[photo_index]
	var img = Image.load_from_file(path)
	
	if img:
		var tex = ImageTexture.create_from_image(img)
		# 簡單淡入淡出
		var tw = create_tween()
		tw.tween_property(photo_rect, "modulate:a", 0.0, 0.3)
		tw.tween_callback(func(): photo_rect.texture = tex)
		tw.tween_property(photo_rect, "modulate:a", 1.0, 0.3)

# --- 音訊控制台邏輯 (核心更新) ---

func _on_audio_files_batch_selected(paths: PackedStringArray):
	for path in paths:
		_create_audio_row(path)
	save_config() # 新增完自動存檔

# 動態建立每一列的控制器
func _create_audio_row(path: String, saved_time = null, saved_loop = false):
	var row = HBoxContainer.new()
	audio_list_container.add_child(row)
	
	# 1. 儲存路徑 (隱藏數據)
	row.set_meta("file_path", path)
	
# 2. 刪除按鈕 (修改版)
	var del_btn = Button.new()
	del_btn.text = "X"
	del_btn.custom_minimum_size.x = 30
	# --- 修改開始 ---
	del_btn.pressed.connect(func(): 
		# 關鍵步驟 1: 先立刻從容器中「移除」這個節點
		# 如果只用 queue_free，它在當前影格還會算在容器內，存檔會存到錯的
		audio_list_container.remove_child(row)
		
		# 關鍵步驟 2: 標記釋放記憶體
		row.queue_free()
		
		# 關鍵步驟 3: 立即執行存檔，這樣下次打開就不見了
		save_config()
	)
	# --- 修改結束 ---
	row.add_child(del_btn)
	
	# 3. 檔名顯示
	var name_lbl = Label.new()
	name_lbl.text = path.get_file()
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.clip_text = true
	row.add_child(name_lbl)
	
	# 4. 時間設定 (時:分)
	# 預設為當前時間
	var now = Time.get_time_dict_from_system()
	if saved_time: now = saved_time # 如果有存檔讀取存檔
	
	var spin_h = SpinBox.new()
	spin_h.max_value = 23
	spin_h.value = now.hour
	spin_h.alignment = HORIZONTAL_ALIGNMENT_CENTER
	spin_h.set_meta("type", "hour") # 標記以便搜尋
	row.add_child(spin_h)
	
	var sep = Label.new()
	sep.text = ":"
	row.add_child(sep)
	
	var spin_m = SpinBox.new()
	spin_m.max_value = 59
	spin_m.value = now.minute
	spin_m.alignment = HORIZONTAL_ALIGNMENT_CENTER
	spin_m.set_meta("type", "minute")
	row.add_child(spin_m)
	
	# 5. 播放控制按鈕
	var play_btn = Button.new()
	play_btn.text = "▶"
	row.add_child(play_btn)
	
	var pause_btn = Button.new()
	pause_btn.text = "||"
	row.add_child(pause_btn)
	
	# 6. Loop 選項
	var loop_chk = CheckBox.new()
	loop_chk.text = "Loop"
	loop_chk.button_pressed = saved_loop
	loop_chk.set_meta("type", "loop")
	row.add_child(loop_chk)
	
	# --- 訊號連接 (閉包綁定 row 變數) ---
	play_btn.pressed.connect(func(): _play_row_audio(row))
	pause_btn.pressed.connect(func(): 
		# 如果正在播這首，就暫停
		if audio_player.playing and audio_player.get_meta("current_row") == row:
			audio_player.stream_paused = not audio_player.stream_paused
	)


func _play_row_audio(row: Control):
	var path = row.get_meta("file_path")
	if not FileAccess.file_exists(path):
		print("檔案遺失: ", path)
		return
		
	# 讀取檔案
	var file = FileAccess.open(path, FileAccess.READ)
	var sound = AudioStreamMP3.new()
	sound.data = file.get_buffer(file.get_length())
	
	# 取得該列的 Loop 設定
	for child in row.get_children():
		if child.has_meta("type") and child.get_meta("type") == "loop":
			sound.loop = child.button_pressed
	
	audio_player.stream = sound
	audio_player.play()
	
	# 標記目前正在播哪一列 (用於暫停或高亮)
	audio_player.set_meta("current_row", row)
	
	# 視覺回饋 (選擇性): 還原其他列顏色，高亮這一列
	for c in audio_list_container.get_children():
		c.modulate = Color.WHITE
	row.modulate = Color.GREEN

# --- 自動排程系統邏輯 ---

func _on_system_timer_tick():
	if not auto_check.button_pressed: return
	
	var now = Time.get_time_dict_from_system()
	var current_time_str = "%02d:%02d" % [now.hour, now.minute]
	
	# 防止同分鐘重複觸發
	if current_time_str == last_triggered_time_str: return
	
	# 遍歷所有音訊列
	for row in audio_list_container.get_children():
		var h = 0
		var m = 0
		# 抓取 SpinBox 數值
		for child in row.get_children():
			if child.has_meta("type"):
				if child.get_meta("type") == "hour": h = child.value
				if child.get_meta("type") == "minute": m = child.value
		
		# 比對
		var row_time_str = "%02d:%02d" % [h, m]
		if row_time_str == current_time_str:
			print("自動觸發: ", row.get_meta("file_path"))
			_play_row_audio(row)
			last_triggered_time_str = current_time_str
			# 一次只觸發一個，若同時設定則排上面的優先
			return 

# --- 存檔系統 ---

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
		
		audio_data.append({
			"path": row.get_meta("file_path"),
			"hour": h,
			"minute": m,
			"loop": loop
		})
	
	var data = {
		"photo_dir": current_photo_dir,
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
	var res = json.parse(f.get_as_text())
	if res == OK:
		var data = json.data
		current_photo_dir = data.get("photo_dir", "")
		interval_spin.value = data.get("interval", 5.0)
		auto_check.button_pressed = data.get("is_auto", false)
		
		if current_photo_dir != "":
			path_label.text = "路徑: " + current_photo_dir
			_on_photo_dir_selected(current_photo_dir)
			
		var list = data.get("audio_list", [])
		for item in list:
			_create_audio_row(
				item.path, 
				{"hour": item.hour, "minute": item.minute}, 
				item.loop
			)

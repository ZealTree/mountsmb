#!/bin/bash

# Скрипт для монтирования SMB-шаров с интерактивным интерфейсом

# Функция проверки доступности хоста
check_host() {
    ping -c 2 "$1" &> /dev/null
    return $?
}

# Функция преобразования имени в безопасный формат для папки
get_safe_name() {
    local name="$1"
    echo "$name" | sed 's/[^a-zA-Z0-9_-]/_/g'
}

# Функция создания файла с учетными данными
create_credentials() {
    local cred_file="$1"
    
    # Запрос имени пользователя
    TEMP_FILE=$(mktemp)
    dialog --inputbox "Введите имя пользователя SMB:" 8 40 2>"$TEMP_FILE"
    dialog_exit_code=$?
    USERNAME=$(cat "$TEMP_FILE")
    rm "$TEMP_FILE"
    
    [ "$dialog_exit_code" -ne 0 ] && return 1
    [ -z "$USERNAME" ] && return 1
    
    # Запрос пароля
    TEMP_FILE=$(mktemp)
    dialog --passwordbox "Введите пароль для $USERNAME:" 8 40 2>"$TEMP_FILE"
    dialog_exit_code=$?
    PASSWORD=$(cat "$TEMP_FILE")
    rm "$TEMP_FILE"
    
    [ "$dialog_exit_code" -ne 0 ] && return 1
    [ -z "$PASSWORD" ] && return 1
    
    # Создание файла с учетными данными
    echo -e "username=$USERNAME\npassword=$PASSWORD" > "$cred_file"
    chmod 600 "$cred_file"
    
    return 0
}

# Основной цикл ввода хоста
while true; do
    TEMP_FILE=$(mktemp)
    dialog --inputbox "Введите IP-адрес или hostname SMB-сервера:" 8 40 2>"$TEMP_FILE"
    dialog_exit_code=$?
    REMOTE_HOST=$(cat "$TEMP_FILE")
    rm "$TEMP_FILE"
    
    # Проверка отмены ввода
    if [ "$dialog_exit_code" -ne 0 ]; then
        exit 1
    fi
    
    [ -z "$REMOTE_HOST" ] && continue
    
    # Проверка доступности хоста
    if check_host "$REMOTE_HOST"; then
        break
    else
        dialog --msgbox "Хост $REMOTE_HOST недоступен. Проверьте адрес и попробуйте снова." 6 40
    fi
done

# Ввод имени папки для монтирования
DEFAULT_NAME=$(get_safe_name "$REMOTE_HOST")
TEMP_FILE=$(mktemp)
dialog --inputbox "Введите имя папки для монтирования (по умолчанию $DEFAULT_NAME):" 8 40 "$DEFAULT_NAME" 2>"$TEMP_FILE"
dialog_exit_code=$?
MOUNT_BASE_DIR=$(cat "$TEMP_FILE")
rm "$TEMP_FILE"

# Проверка отмены ввода
if [ "$dialog_exit_code" -ne 0 ]; then
    exit 1
fi

[ -z "$MOUNT_BASE_DIR" ] && MOUNT_BASE_DIR="$DEFAULT_NAME"

# Выбор метода авторизации
while true; do
    TEMP_FILE=$(mktemp)
    dialog --menu "Авторизация в SMB" 12 40 3 \
        1 "Использовать ~/.cifs" \
        2 "Создать свой файл credentials" \
        3 "Использовать логин/пароль" 2>"$TEMP_FILE"
    
    dialog_exit_code=$?
    choice=$(cat "$TEMP_FILE")
    rm "$TEMP_FILE"
    
    # Обработка отмены выбора
    if [ "$dialog_exit_code" -ne 0 ]; then
        exit 0
    fi
    
    case $choice in
        1) # Использование существующего файла .cifs
            CREDENTIALS="$HOME/.cifs"
            if [ ! -f "$CREDENTIALS" ]; then
                dialog --yesno "Файл $CREDENTIALS не найден. Создать?" 6 40
                if [ $? -ne 0 ]; then
                    exit 1
                fi
                create_credentials "$CREDENTIALS" || exit 1
            fi
            break
            ;;
        2) # Создание нового файла с учетными данными
            CREDENTIALS="$HOME/.${MOUNT_BASE_DIR}-credentials"
            if [ -f "$CREDENTIALS" ]; then
                dialog --yesno "Файл $CREDENTIALS существует. Перезаписать?" 6 40
                [ $? -ne 0 ] && continue
            fi
            create_credentials "$CREDENTIALS" || continue
            break
            ;;
        3) # Использование логина/пароля напрямую
            TEMP_FILE=$(mktemp)
            dialog --inputbox "Введите имя пользователя SMB:" 8 40 2>"$TEMP_FILE"
            dialog_exit_code=$?
            USERNAME=$(cat "$TEMP_FILE")
            rm "$TEMP_FILE"
            
            [ "$dialog_exit_code" -ne 0 ] && continue
            [ -z "$USERNAME" ] && continue
            
            TEMP_FILE=$(mktemp)
            dialog --passwordbox "Введите пароль для $USERNAME:" 8 40 2>"$TEMP_FILE"
            dialog_exit_code=$?
            PASSWORD=$(cat "$TEMP_FILE")
            rm "$TEMP_FILE"
            
            [ "$dialog_exit_code" -ne 0 ] && continue
            [ -z "$PASSWORD" ] && continue
            
            CREDENTIALS=""
            break
            ;;
        *)
            exit 1
            ;;
    esac
done

# Создание директории для монтирования
MOUNT_DIR="$HOME/$MOUNT_BASE_DIR"
mkdir -p "$MOUNT_DIR" || exit 1

# Получение списка доступных шар
if [ -z "$CREDENTIALS" ]; then
    SHARES=$(smbclient -L "//$REMOTE_HOST" -m SMB3 -U "$USERNAME%$PASSWORD" 2>/dev/null | grep -i disk | awk '{print $1}')
else
    SHARES=$(smbclient -A "$CREDENTIALS" -L "//$REMOTE_HOST" -m SMB3 2>/dev/null | grep -i disk | awk '{print $1}')
fi

if [ -z "$SHARES" ]; then
    dialog --msgbox "Не удалось найти доступные шары. Проверьте авторизацию и подключение." 8 40
    exit 1
fi

# Формирование списка для выбора шар
IFS=$'\n' read -d '' -r -a shares_array <<< "$SHARES"
MENU_FILE=$(mktemp)

# Добавление обычных шар в меню
for i in "${!shares_array[@]}"; do
    printf '%d "%s" off\n' "$((i+1))" "${shares_array[i]}" >> "$MENU_FILE"
done

# Добавление пункта для скрытых шар
hidden_index=$(( ${#shares_array[@]} + 1 ))
printf '%d "Скрытые" off\n' "$hidden_index" >> "$MENU_FILE"

# Удаление возможных символов возврата каретки
sed -i 's/\r$//' "$MENU_FILE"

# Выбор шар для монтирования
TEMP_FILE=$(mktemp)
dialog --checklist "Выберите шары для монтирования:" 15 50 8 $(cat "$MENU_FILE") 2>"$TEMP_FILE"
dialog_exit_code=$?
SELECTED_ITEMS=$(cat "$TEMP_FILE")
rm "$TEMP_FILE"
rm "$MENU_FILE"

# Проверка выбора пользователя
if [ "$dialog_exit_code" -ne 0 ]; then
    exit 0
fi

if [ -z "$SELECTED_ITEMS" ]; then
    dialog --msgbox "Не выбрано ни одной шары для монтирования." 6 40
    exit 0
fi

# Обработка скрытых шар
HIDDEN_SHARES=""
for item in $SELECTED_ITEMS; do
    if [ "$item" -eq "$hidden_index" ]; then
        while true; do
            TEMP_FILE=$(mktemp)
            dialog --inputbox "Введите имя скрытой шары (оставьте пустым для завершения):" 8 40 2>"$TEMP_FILE"
            dialog_exit_code=$?
            HIDDEN_SHARE=$(cat "$TEMP_FILE")
            rm "$TEMP_FILE"
            
            if [ "$dialog_exit_code" -ne 0 ] || [ -z "$HIDDEN_SHARE" ]; then
                break
            fi
            
            HIDDEN_SHARES="$HIDDEN_SHARES $HIDDEN_SHARE"
        done
    fi
done

# Монтирование выбранных шар
for item in $SELECTED_ITEMS; do
    # Пропуск пункта "Скрытые"
    if [ "$item" -eq "$hidden_index" ]; then
        continue
    fi
    
    # Монтирование обычных шар
    index=$((item-1))
    share="${shares_array[index]}"
    
    # Проверка, не смонтирована ли уже шара
    if mount | grep -q "//$REMOTE_HOST/$share"; then
        dialog --msgbox "$share уже смонтирована!" 6 30
        continue
    fi
    
    # Создание директории и монтирование
    share_dir="$MOUNT_DIR/$share"
    mkdir -p "$share_dir"
    
    # Формирование параметров монтирования
    if [ -z "$CREDENTIALS" ]; then
        mount_options="username=$USERNAME,password=$PASSWORD,uid=$(id -u),gid=$(id -g),file_mode=0660,dir_mode=0770"
    else
        mount_options="credentials=$CREDENTIALS,uid=$(id -u),gid=$(id -g),file_mode=0660,dir_mode=0770"
    fi
    
    # Выполнение монтирования
    if sudo mount.cifs "//$REMOTE_HOST/$share" "$share_dir" -o "$mount_options"; then
        dialog --infobox "Шара $share успешно смонтирована в $share_dir!" 5 50
        sleep 2
    else
        dialog --msgbox "Ошибка монтирования $share в $share_dir!" 6 50
    fi
done

# Монтирование скрытых шар
for hidden_share in $HIDDEN_SHARES; do
    share_dir="$MOUNT_DIR/$hidden_share"
    mkdir -p "$share_dir"
    
    if [ -z "$CREDENTIALS" ]; then
        mount_options="username=$USERNAME,password=$PASSWORD,uid=$(id -u),gid=$(id -g),file_mode=0660,dir_mode=0770"
    else
        mount_options="credentials=$CREDENTIALS,uid=$(id -u),gid=$(id -g),file_mode=0660,dir_mode=0770"
    fi
    
    if sudo mount.cifs "//$REMOTE_HOST/$hidden_share" "$share_dir" -o "$mount_options"; then
        dialog --infobox "Скрытая шара $hidden_share смонтирована в $share_dir!" 5 50
        sleep 2
    else
        dialog --msgbox "Ошибка монтирования скрытой шары $hidden_share!" 6 50
    fi
done

clear
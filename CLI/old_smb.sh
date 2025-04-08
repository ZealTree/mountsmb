#!/bin/bash

# Проверка наличия dialog
if ! command -v dialog &> /dev/null; then
    echo "Для работы скрипта требуется утилита 'dialog'. Установите её (например, 'sudo apt install dialog') и попробуйте снова."
    exit 1
fi

# Функция проверки доступности хоста
check_host() {
    local host=$1
    if ping -c 2 "$host" &> /dev/null; then
        return 0  # Хост доступен
    else
        return 1  # Хост недоступен
    fi
}

# Запрос хоста у пользователя
while true; do
    REMOTE_HOST=$(dialog --inputbox "Введите IP-адрес или hostname SMB-сервера:" 8 40 3>&1 1>&2 2>&3)
    if [ -z "$REMOTE_HOST" ]; then
        dialog --msgbox "Вы не ввели адрес. Попробуйте снова." 6 40
    elif check_host "$REMOTE_HOST"; then
        break
    else
        dialog --msgbox "Хост $REMOTE_HOST недоступен. Проверьте адрес и попробуйте снова." 6 40
    fi
done

# Определяем hostname по IP или запрашиваем имя папки
if [[ "$REMOTE_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    HOSTNAME=$(host "$REMOTE_HOST" | awk '/domain name pointer/ {print $5}' | sed 's/\.$//')
    if [ -n "$HOSTNAME" ]; then
        MOUNT_BASE_DIR="$HOSTNAME"
    else
        MOUNT_BASE_DIR=$(dialog --inputbox "Не удалось определить hostname для $REMOTE_HOST.\nВведите имя папки (оставьте пустым для использования IP):" 10 40 3>&1 1>&2 2>&3)
        if [ -z "$MOUNT_BASE_DIR" ]; then
            MOUNT_BASE_DIR="$REMOTE_HOST"
        fi
    fi
else
    MOUNT_BASE_DIR="$REMOTE_HOST"
fi

# Параметры
CREDENTIALS="/home/$USER/.cifs"

# Создаем базовую директорию
mkdir -p "$MOUNT_BASE_DIR"
cd "$MOUNT_BASE_DIR" || exit

# Получаем список шар
SHARES=$(smbclient -A "$CREDENTIALS" -L "//$REMOTE_HOST" -m SMB3 | grep -i disk | awk '{print $1}')
if [ -z "$SHARES" ]; then
    dialog --msgbox "Не удалось найти доступные шары на $REMOTE_HOST. Проверьте credentials и настройки сервера." 8 40
    exit 1
fi

# Создаем временный файл для TUI-меню
MENU_FILE=$(mktemp)
i=1
for share in $SHARES; do
    echo "$i \"$share\" off" >> "$MENU_FILE"
    ((i++))
done

# TUI-меню для выбора шар
SELECTED_SHARES=$(dialog --checklist "Выберите шары для монтирования:" 15 40 8 $(cat "$MENU_FILE") 3>&1 1>&2 2>&3)
rm -f "$MENU_FILE"

# Преобразуем выбор в список имен шар
SHARE_LIST=""
for num in $SELECTED_SHARES; do
    SHARE_NAME=$(echo "$SHARES" | sed -n "${num}p")
    SHARE_LIST="$SHARE_LIST $SHARE_NAME"
done

# Монтируем выбранные шары
for share in $SHARE_LIST; do
    mkdir -p "$share"
    sudo mount.cifs "//$REMOTE_HOST/$share" "$share/" -o rw,credentials="$CREDENTIALS",file_mode=0777,dir_mode=0777
done

# Запрос на добавление скрытых шар
dialog --yesno "Хотите вручную добавить скрытые шары?" 6 40
if [ $? -eq 0 ]; then
    while true; do
        HIDDEN_SHARE=$(dialog --inputbox "Введите имя скрытой шары (или оставьте пустым для завершения):" 8 40 3>&1 1>&2 2>&3)
        if [ -z "$HIDDEN_SHARE" ]; then
            break
        fi
        mkdir -p "$HIDDEN_SHARE"
        sudo mount.cifs "//$REMOTE_HOST/$HIDDEN_SHARE" "$HIDDEN_SHARE/" -o rw,credentials="$CREDENTIALS",file_mode=0777,dir_mode=0777
    done
fi

dialog --msgbox "Монтирование завершено!" 6 40
clear
#!/bin/bash

# Функции
check_host() { ping -c 2 "$1" &> /dev/null; return $?; }
get_safe_name() { echo "$1" | sed 's/[^a-zA-Z0-9_-]/_/g'; }

create_credentials() {
    local credentials_file="$1"
    local username
    local password

    username=$(zenity --entry --title="SMB Authentication" --text="Enter SMB username:") || return 1
    password=$(zenity --password --title="SMB Authentication" --text="Enter password for $username:") || return 1

    cat <<EOF > "$credentials_file"
username=$username
password=$password
EOF

    chmod 600 "$credentials_file"
}

# Объединённый диалог ввода хоста и имени папки
HOST_DATA=$(zenity --width=800 --height=200 --forms --title="Подключение к SMB" \
    --text="Введите параметры подключения" \
    --add-entry="IP-адрес или hostname сервера:" \
    --add-entry="Имя папки для монтирования (необязательно):")

[ -z "$HOST_DATA" ] && exit 0

# Разбираем введённые данные
REMOTE_HOST=$(echo "$HOST_DATA" | cut -d'|' -f1)
MOUNT_BASE_DIR=$(echo "$HOST_DATA" | cut -d'|' -f2)

# Проверка хоста
if ! check_host "$REMOTE_HOST"; then
    zenity --error --text="Хост $REMOTE_HOST недоступен. Проверьте подключение."
    exit 1
fi

# Установка имени папки по умолчанию
[ -z "$MOUNT_BASE_DIR" ] && MOUNT_BASE_DIR=$(get_safe_name "$REMOTE_HOST")

# Авторизация
AUTH_METHOD=$(zenity --width=400 --height=400 --list --title="SMB Auth" \
    --column="Method" --column="Description" \
    "Existing" "Использовать ~/.cifs" \
    "New" "Создать файл credentials" \
    "Manual" "Ввести логин/пароль") || exit 1

case "$AUTH_METHOD" in
    "Existing")
        CREDENTIALS="$HOME/.cifs"
        [ ! -f "$CREDENTIALS" ] && { zenity --question --text="Файл не найден. Создать?" && create_credentials "$CREDENTIALS" || exit 1; }
        ;;
    "New")
        CREDENTIALS="$HOME/.${MOUNT_BASE_DIR}-credentials"
        [ -f "$CREDENTIALS" ] && { zenity --question --text="Перезаписать файл?" || exit 1; }
        create_credentials "$CREDENTIALS" || exit 1
        ;;
    "Manual")
        USERNAME=$(zenity --entry --title="SMB Auth" --text="Введите имя пользователя:") || exit 1
        PASSWORD=$(zenity --password --title="SMB Auth" --text="Введите пароль:") || exit 1
        CREDENTIALS=""
        ;;
    *) exit 1 ;;
esac

# Получение списка шар
if [ -z "$CREDENTIALS" ]; then
    SHARES=$(smbclient -L "//$REMOTE_HOST" -m SMB3 -U "$USERNAME%$PASSWORD" 2>/dev/null | grep -i disk | awk '{print $1}')
else
    SHARES=$(smbclient -A "$CREDENTIALS" -L "//$REMOTE_HOST" -m SMB3 2>/dev/null | grep -i disk | awk '{print $1}')
fi

[ -z "$SHARES" ] && { zenity --error --text="Нет доступных шар"; exit 1; }

# Подготовка списка с пунктом для скрытых папок
IFS=$'\n' read -d '' -r -a shares_array <<< "$SHARES"
shares_array+=("+ Добавить скрытую папку")

# Выбор шар
SELECTED_SHARES=$(zenity --list --title="Выберите шары" --text="Доступные шары:" \
    --column="Шара" "${shares_array[@]}" --multiple --separator=$'\n' --height=700) || exit 0

[ -z "$SELECTED_SHARES" ] && exit 0

# Обработка выбора
MOUNT_DIR="$HOME/$MOUNT_BASE_DIR"
mkdir -p "$MOUNT_DIR" || exit 1

declare -a ALL_SHARES=()
while IFS= read -r share; do
    if [ "$share" == "+ Добавить скрытую папку" ]; then
        HIDDEN_SHARE=$(zenity --entry --title="Скрытая папка" --text="Введите имя скрытой папки (например, share$):")
        [ -n "$HIDDEN_SHARE" ] && ALL_SHARES+=("$HIDDEN_SHARE")
    else
        ALL_SHARES+=("$share")
    fi
done <<< "$SELECTED_SHARES"

# Подготовка отчёта
REPORT="Результаты монтирования:\n\n"
MOUNT_SUCCESS=0
MOUNT_FAILED=0

# Монтирование всех выбранных шар
for share in "${ALL_SHARES[@]}"; do
    share_dir="$MOUNT_DIR/$(get_safe_name "$share")"
    mkdir -p "$share_dir"

    if [ -z "$CREDENTIALS" ]; then
        mount_options="username=$USERNAME,password=$PASSWORD,uid=$(id -u),gid=$(id -g),file_mode=0660,dir_mode=0770"
    else
        mount_options="credentials=$CREDENTIALS,uid=$(id -u),gid=$(id -g),file_mode=0660,dir_mode=0770"
    fi

    # Проверка на уже смонтированную шару
    if mount | grep -q "//$REMOTE_HOST/$share"; then
        REPORT+="⚠️ $share уже смонтирована в $share_dir\n"
        continue
    fi

    # Попытка монтирования
    if udisksctl mount -t cifs -b "//$REMOTE_HOST/$share" -o "$mount_options" >/dev/null 2>&1; then
        REPORT+="✅ Успешно: $share → $share_dir\n"
        ((MOUNT_SUCCESS++))
    elif sudo mount.cifs "//$REMOTE_HOST/$share" "$share_dir" -o "$mount_options"; then
        REPORT+="✅ Успешно: $share → $share_dir (через sudo)\n"
        ((MOUNT_SUCCESS++))
    else
        REPORT+="❌ Ошибка: $share\n"
        ((MOUNT_FAILED++))
    fi
done

# Вывод сводного отчёта
REPORT+="\nИтого: успешно $MOUNT_SUCCESS, ошибок $MOUNT_FAILED"

if [ $MOUNT_FAILED -eq 0 ]; then
    zenity --info --title="Готово" --text="$REPORT" --width=500
elif [ $MOUNT_SUCCESS -eq 0 ]; then
    zenity --error --title="Ошибка" --text="$REPORT" --width=500
else
    zenity --info --title="Результат" --text="$REPORT" --width=500
fi

exit 0

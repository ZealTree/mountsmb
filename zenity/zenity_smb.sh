#!/bin/bash

# Функции
check_host() { ping -c 2 "$1" &> /dev/null; return $?; }
get_safe_name() { echo "$1" | sed 's/[^a-zA-Z0-9_-]/_/g'; }

# Функция для получения пароля sudo через графический интерфейс
get_sudo_password() {
    zenity --password --title="Требуются права администратора" --text="Введите ваш пароль sudo:" 2>/dev/null
}

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

# Объединённый диалог ввода
AUTH_DATA=$(zenity --width=800 --height=300 --forms --title="Подключение к SMB" \
    --text="Введите параметры подключения" \
    --add-entry="IP-адрес или hostname сервера:" \
    --add-entry="Имя папки для монтирования:" "smbshares" \
    --add-combo="Метод авторизации:" \
    --combo-values="Existing .cifs|New credentials|Manual login" \
    --add-entry="Имя пользователя (если Manual):" \
    --add-password="Пароль (если Manual):")

[ -z "$AUTH_DATA" ] && exit 0

# Разбираем введённые данные
REMOTE_HOST=$(echo "$AUTH_DATA" | cut -d'|' -f1)
MOUNT_BASE_DIR=$(echo "$AUTH_DATA" | cut -d'|' -f2)
AUTH_METHOD=$(echo "$AUTH_DATA" | cut -d'|' -f3)
MANUAL_USER=$(echo "$AUTH_DATA" | cut -d'|' -f4)
MANUAL_PASS=$(echo "$AUTH_DATA" | cut -d'|' -f5)

# Проверка хоста
if ! check_host "$REMOTE_HOST"; then
    zenity --error --text="Хост $REMOTE_HOST недоступен. Проверьте подключение."
    exit 1
fi

# Обработка авторизации
case "$AUTH_METHOD" in
    "Existing .cifs")
        CREDENTIALS="$HOME/.cifs"
        [ ! -f "$CREDENTIALS" ] && {
            zenity --question --text="Файл $CREDENTIALS не найден. Создать?" &&
            create_credentials "$CREDENTIALS" || exit 1
        }
        ;;
    "New credentials")
        CREDENTIALS="$HOME/.${MOUNT_BASE_DIR}-credentials"
        [ -f "$CREDENTIALS" ] && {
            zenity --question --text="Файл $CREDENTIALS существует. Перезаписать?" || exit 1
        }
        create_credentials "$CREDENTIALS" || exit 1
        ;;
    "Manual login")
        [ -z "$MANUAL_USER" ] && {
            zenity --error --text="Имя пользователя не может быть пустым!"
            exit 1
        }
        [ -z "$MANUAL_PASS" ] && {
            zenity --error --text="Пароль не может быть пустым!"
            exit 1
        }
        USERNAME="$MANUAL_USER"
        PASSWORD="$MANUAL_PASS"
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

# Получаем пароль sudo один раз
SUDO_PASSWORD=$(get_sudo_password)
[ -z "$SUDO_PASSWORD" ] && exit 1

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

    # Попытка монтирования через udisksctl (без sudo)
    if udisksctl mount -t cifs -b "//$REMOTE_HOST/$share" -o "$mount_options" >/dev/null 2>&1; then
        REPORT+="✅ Успешно: $share → $share_dir\n"
        ((MOUNT_SUCCESS++))
    else
        # Монтирование через sudo с графическим вводом пароля
        echo "$SUDO_PASSWORD" | sudo -S mount.cifs "//$REMOTE_HOST/$share" "$share_dir" -o "$mount_options" 2>/dev/null
        if [ $? -eq 0 ]; then
            REPORT+="✅ Успешно: $share → $share_dir (через sudo)\n"
            ((MOUNT_SUCCESS++))
        else
            REPORT+="❌ Ошибка: $share\n"
            ((MOUNT_FAILED++))
        fi
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

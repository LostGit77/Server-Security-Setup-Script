#!/bin/bash

# ================================
# Color palette
# ================================

CLR_RED="\e[31m"
CLR_GREEN="\e[32m"
CLR_YELLOW="\e[33m"
CLR_BLUE="\e[34m"
CLR_MAGENTA="\e[35m"
CLR_CYAN="\e[36m"
CLR_WHITE="\e[37m"
CLR_RESET="\e[0m"

# ================================
# Message output helper
# ================================

print_msg() {

    local level="$1"
    local message="$2"
    case "$level" in
        info)
            echo -e "${CLR_BLUE}[--INFO--]${CLR_RESET} ${message}"
        ;;
        ok)
            echo -e "${CLR_GREEN}[---OK---]${CLR_RESET} ${message}"
        ;;
        warn)
            echo -e "${CLR_YELLOW}[WARNING!]${CLR_RESET} ${message}"
        ;;
        error)
            echo -e "${CLR_RED}[-ERROR!-]${CLR_RESET} ${message}"
        ;;
        *)
            echo -e "${CLR_WHITE}${message}${CLR_RESET}"
        ;;
    esac
}

LOG_FILE="/var/log/server_setup.log"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

# ================================
# Function to wait for apt/dpkg lock release.
# ================================

wait_for_dpkg_lock() {
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
          fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
          fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
        sleep 5
    done
}

# ================================
# Root permission check
# ================================

require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        print_msg error "Этот скрипт должен быть запущен с правами root."
        exit 1
    fi
}

install_dependencies() {
    print_msg info "Проверка зависимостей..."
    packages=(curl wget gnupg ufw)
    wait_for_dpkg_lock
    apt-get update
    for pkg in "${packages[@]}"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            print_msg warn "Устанавливаем пакет: $pkg"
            apt-get install -y "$pkg"
        fi
    done
}
require_root
install_dependencies

# ================================
# Backup utility
# ================================

create_backup() {

    local target="$1"
    if [[ ! -f "$target" ]]; then
        print_msg warn "Файл $target не найден. Резервная копия пропущена."
        return
    fi
    local stamp
    stamp=$(date +"%Y%m%d_%H%M%S")
    local backup_name="${target}.backup_${stamp}"
    cp "$target" "$backup_name"
    print_msg ok "Backup создан: $backup_name"
}

# ================================
# Root SSH key setup
# ================================

ROOT_AUTH_KEYS="/root/.ssh/authorized_keys"

is_ssh_key_present() {
    [[ -s "$ROOT_AUTH_KEYS" ]] && \
    grep -Eq '^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) ' "$ROOT_AUTH_KEYS" 2>/dev/null
}

ask_replace_key() {
    local answer=""
    while true; do
        read -r -p "$(echo -e "${CLR_CYAN}Заменить существующий SSH ключ root? (y/n): ${CLR_RESET}")" answer </dev/tty
        answer=$(echo "$answer" | tr 'A-Z' 'a-z' | xargs)
        case "$answer" in
            y) return 0 ;;
            n) return 1 ;;
        esac
        print_msg warn "Введите только y или n"
    done
}

ask_copy_key() {
    local answer=""
    while true; do
        read -r -p "$(echo -e "${CLR_CYAN}Добавить SSH ключ для root? (y/n): ${CLR_RESET}")" answer </dev/tty
        answer=$(echo "$answer" | tr 'A-Z' 'a-z')
        case "$answer" in
            y) return 0 ;;
            n) return 1 ;;
        esac
        print_msg warn "Введите y или n"
    done
}

install_root_key() {
    local user_key=""
    while [[ -z "$user_key" ]]; do
        read -r -p "$(echo -e "${CLR_CYAN}Введите публичный SSH ключ для root: ${CLR_RESET}")" user_key </dev/tty
        user_key=$(echo "$user_key" | xargs)
        if [[ -z "$user_key" ]]; then
            print_msg warn "Ключ не может быть пустым"
        fi
    done
    if ! echo "$user_key" | grep -Eq '^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp(256|384|521)) '; then
        print_msg error "Неверный формат SSH ключа"
        exit 1
    fi

    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    echo "$user_key" > "$ROOT_AUTH_KEYS"
    chmod 600 "$ROOT_AUTH_KEYS"
    print_msg ok "SSH ключ успешно добавлен/заменён"
}

# ================================
# Execution
# ================================

if is_ssh_key_present; then
    print_msg ok "SSH ключ root уже установлен"
    if ask_replace_key; then
        install_root_key
    else
        print_msg info "Замена ключа пропущена пользователем"
    fi
else
    print_msg info "SSH ключ root отсутствует"
    if ask_copy_key; then
        install_root_key
    else
        print_msg info "Добавление SSH ключа пропущено пользователем"
    fi
fi

# ================================
# SSH security configuration
# ================================

SSHD_CONFIG_FILE="/etc/ssh/sshd_config"

detect_ssh_port() {
    local detected
    detected=$(grep -Ei "^Port " "$SSHD_CONFIG_FILE" | awk '{print $2}' | head -n1)
    if [[ -z "$detected" ]]; then
        detected=22
    fi
    print_msg info "Текущий SSH порт: $detected"
}

request_new_port() {
    local input=""
    while true; do
        read -r -p "$(echo -e "${CLR_CYAN}Введите новый порт SSH (по умолчанию 2222): ${CLR_RESET}")" input </dev/tty
        input=${input:-2222}
        if [[ "$input" =~ ^[0-9]+$ ]]; then
            TARGET_SSH_PORT="$input"
            print_msg ok "Будет использован порт: $TARGET_SSH_PORT"
            break
        fi
        print_msg warn "Введите корректный номер порта"
    done
}

apply_sshd_option() {

    local file="$1"
    local key="$2"
    local value="$3"
    if grep -Eq "^[#[:space:]]*$key" "$file"; then
        sed -i "s|^[#[:space:]]*$key.*|$key $value|" "$file"
    else
        echo "$key $value" >> "$file"
    fi
}

configure_ssh_security() {

    print_msg info "Настройка параметров SSH..."
    create_backup "$SSHD_CONFIG_FILE"
    if [[ ! -s "$ROOT_AUTH_KEYS" ]]; then
        print_msg warn "SSH ключ не найден. Нельзя отключить пароль."
        apply_password_auth="no"   
    else
        apply_password_auth="yes"
    fi
    apply_sshd_option "$SSHD_CONFIG_FILE" "Port" "$TARGET_SSH_PORT"
  if [[ "$apply_password_auth" == "yes" ]]; then
    apply_sshd_option "$SSHD_CONFIG_FILE" "PermitRootLogin" "prohibit-password"
    apply_sshd_option "$SSHD_CONFIG_FILE" "PasswordAuthentication" "no"
    apply_sshd_option "$SSHD_CONFIG_FILE" "PermitEmptyPasswords" "no"
    apply_sshd_option "$SSHD_CONFIG_FILE" "PubkeyAuthentication" "yes"
    apply_sshd_option "$SSHD_CONFIG_FILE" "MaxAuthTries" "3"
    apply_sshd_option "$SSHD_CONFIG_FILE" "LoginGraceTime" "30"
    apply_sshd_option "$SSHD_CONFIG_FILE" "ClientAliveInterval" "300"
    apply_sshd_option "$SSHD_CONFIG_FILE" "ClientAliveCountMax" "2"
  else
      print_msg info "Оставляем текущие настройки пароля без изменений."
  fi
}

open_port_if_firewall_active() {

    if ufw status | grep -q "Status: active"; then
        ufw allow "${TARGET_SSH_PORT}/tcp"
        print_msg ok "Порт ${TARGET_SSH_PORT}/tcp добавлен в UFW"
    fi
}

# ================================
# BBR configuration
# ================================

check_bbr_status() {
    local cc
    cc=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')

    if [[ "$cc" == "bbr" ]]; then
        print_msg ok "BBR уже активирован"
        return 0
    fi

    return 1
}

enable_bbr_feature() {
    print_msg info "Активируем TCP BBR..."
    cat <<EOF >/etc/sysctl.d/99-bbr.conf
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl --system >/dev/null 2>&1
    local cc
    local qdisc
    cc=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    qdisc=$(sysctl net.core.default_qdisc | awk '{print $3}')
    if [[ "$cc" == "bbr" && "$qdisc" == "fq" ]]; then
        print_msg ok "BBR успешно включён"
    else
        print_msg warn "BBR может быть не активирован"
    fi
}

ask_bbr() {

    local ans=""
    while true; do
        read -r -p "$(echo -e "${CLR_CYAN}Включить BBR (TCP BBR + fq) для улучшения сетевого трафика? (y/n): ${CLR_RESET}")" ans </dev/tty
        ans=$(echo "$ans" | tr 'A-Z' 'a-z')
        case "$ans" in
            y) enable_bbr_feature; break ;;
            n) print_msg info "Включение BBR пропущено"; break ;;
        esac
        print_msg warn "Введите y или n"
    done
}

restart_ssh_service() {

    print_msg info "Перезапуск SSH сервиса..."
    if systemctl restart ssh; then
        print_msg ok "SSH успешно перезапущен"
    else
        print_msg error "Ошибка перезапуска SSH"
        exit 1
    fi
}

# ================================
# Execution
# ================================

detect_ssh_port
request_new_port
open_port_if_firewall_active
configure_ssh_security
if check_bbr_status; then
    print_msg info "Включение BBR пропущено"
else
    ask_bbr
fi
restart_ssh_service

# ================================
# Firewall configuration (UFW)
# ================================

enable_firewall_if_needed() {
    local status
    status=$(ufw status 2>/dev/null)
    if echo "$status" | grep -qi "inactive"; then
        local reply=""
        while true; do
            read -r -p "$(echo -e "${CLR_CYAN}Активировать Firewall (UFW)? (y/n): ${CLR_RESET}")" reply </dev/tty
            reply=$(echo "$reply" | tr 'A-Z' 'a-z')
            case "$reply" in
                y)
                    ufw --force enable
                    print_msg ok "Firewall успешно включён"
                    return 0
                ;;
                n)
                    print_msg info "Firewall не был активирован"
                    return 1
                ;;
                *)
                    print_msg warn "Введите y или n"
                ;;
            esac
        done
    else
        print_msg ok "Firewall уже активирован"
        return 0
    fi
}

ask_extra_ports() {

    local extra_ports=""
    read -r -p "$(echo -e "${CLR_CYAN}Введите дополнительные порты или диапазоны (пример: 80,443,10000:20000). Enter чтобы пропустить: ${CLR_RESET}")" extra_ports </dev/tty
    extra_ports=$(echo "$extra_ports" | xargs)
    if [[ -z "$extra_ports" ]]; then
        PORT_LIST="$TARGET_SSH_PORT"
    else
        PORT_LIST="$TARGET_SSH_PORT,$extra_ports"
    fi
}

open_ports_in_firewall() {

    IFS=',' read -ra PORT_ARRAY <<< "$PORT_LIST"
    for entry in "${PORT_ARRAY[@]}"; do
        entry=$(echo "$entry" | xargs)
        if [[ "$entry" =~ ^[0-9]+$ ]]; then
            ufw allow "${entry}/tcp"
            ufw allow "${entry}/udp"
            print_msg ok "Открыт порт ${entry} (TCP/UDP)"
        elif [[ "$entry" =~ ^[0-9]+:[0-9]+$ ]]; then
            ufw allow "${entry}/tcp"
            ufw allow "${entry}/udp"
            print_msg ok "Открыт диапазон ${entry} (TCP/UDP)"
        else
            print_msg warn "Пропущено: неверный формат порта ($entry)"
        fi
    done
}

reload_firewall() {
    ufw reload >/dev/null 2>&1
    print_msg info "Текущие правила Firewall:"
    ufw status numbered
}


# ================================
# Execution
# ================================

if enable_firewall_if_needed; then  # ← Вызов функции
    ask_extra_ports
    open_ports_in_firewall
    reload_firewall
else
    print_msg info "Настройка портов пропущена (Firewall не активирован)"
fi

# ================================
# ICMP / Ping restrictions
# ================================

UFW_BEFORE_RULES="/etc/ufw/before.rules"

icmp_rules_present() {
    grep -Eq "^-A ufw-before-input -p icmp --icmp-type (destination-unreachable|time-exceeded|parameter-problem|echo-request) -j ACCEPT" \
    "$UFW_BEFORE_RULES" 2>/dev/null
}

ask_icmp_block() {
    local reply=""
    while true; do
        read -r -p "$(echo -e "${CLR_CYAN}Отключить ICMP ping сервера? (y/n): ${CLR_RESET}")" reply </dev/tty
        reply=$(echo "$reply" | tr 'A-Z' 'a-z')
        case "$reply" in
            y) return 0 ;;
            n) return 1 ;;
        esac
        print_msg warn "Введите y или n"
    done
}

apply_icmp_drop_rules() {
    create_backup "$UFW_BEFORE_RULES"
    
    # INPUT правила
    sed -i \
    '/^-A ufw-before-input -p icmp --icmp-type \(destination-unreachable\|time-exceeded\|parameter-problem\|echo-request\) -j ACCEPT$/s/ACCEPT/DROP/' \
    "$UFW_BEFORE_RULES"

    # FORWARD правила
    sed -i \
    '/^-A ufw-before-forward -p icmp --icmp-type \(destination-unreachable\|time-exceeded\|parameter-problem\|echo-request\) -j ACCEPT$/s/ACCEPT/DROP/' \
    "$UFW_BEFORE_RULES"

    # Добавляем source-quench DROP если нет
    if ! grep -q "icmp --icmp-type source-quench -j DROP" "$UFW_BEFORE_RULES"; then
        sed -i '/# ok icmp codes for INPUT/a\-A ufw-before-input -p icmp --icmp-type source-quench -j DROP' "$UFW_BEFORE_RULES"
        print_msg ok "# Добавлено правило DROP для (ICMP) в INPUT и FORWARD"
    fi
    ufw reload
    print_msg ok "ICMP правила обновлены (DROP)"
}

check_icmp_status() {
    if grep -q "echo-request -j DROP" "$UFW_BEFORE_RULES"; then
        print_msg ok "ICMP ping уже отключён"
    else
        print_msg info "ICMP правила уже изменены или отличаются"
    fi
}

# ================================
# Execution
# ================================

if icmp_rules_present; then
    if ask_icmp_block; then
        apply_icmp_drop_rules
    else
        print_msg info "Изменение ICMP правил пропущено"
    fi
else
    check_icmp_status
fi

# ================================
# Swap configuration
# ================================

show_swap_status() {
    if swapon --show | grep -q "/swapfile"; then
        print_msg ok "Swap уже активирован"
        swapon --show
        return
    fi
    print_msg info "Проверка. Текущее состояние swap:"
    free -h
    return 1
}

ask_swap_creation() {
    local answer=""
    while true; do
        read -r -p "$(echo -e "${CLR_CYAN}Создать swap файл? (y/n): ${CLR_RESET}")" answer </dev/tty
        answer=$(echo "$answer" | tr 'A-Z' 'a-z')
        case "$answer" in
            y) 
              CREATE_SWAP_CHOICE="y"
              return 0 ;;
            n) 
              CREATE_SWAP_CHOICE="n"
              return 1 ;;
        esac
        print_msg warn "Введите y или n"
    done
}

ask_swap_size() {
    local input=""
    while true; do
        read -r -p "$(echo -e "${CLR_CYAN}Размер swap (ГБ) [1 / 2 / 3]: ${CLR_RESET}")" input </dev/tty
        if [[ "$input" =~ ^[123]$ ]]; then
            SWAP_GB="$input"
            SWAP_MB=$((SWAP_GB * 1024))
            print_msg ok "Выбран размер swap: ${SWAP_GB}GB"
            break
        fi
        print_msg warn "Допустимые значения: 1, 2 или 3"
    done
}

create_swap_file() {
    if [[ -f /swapfile ]]; then
        print_msg warn "/swapfile уже существует"
        return
    fi
    print_msg info "Создание swap файла (${SWAP_GB}GB)..."
    if dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_MB" status=progress; then
        print_msg ok "Файл /swapfile создан"
    else
        print_msg error "Ошибка создания swap файла"
        return
    fi
    chmod 600 /swapfile
    if mkswap /swapfile; then
        print_msg ok "Swap подготовлен"
    else
        print_msg error "Ошибка mkswap"
    fi
    if swapon /swapfile; then
        print_msg ok "Swap активирован"
    else
        print_msg error "Ошибка swapon"
    fi
}

add_swap_to_fstab() {
    if ! grep -q "/swapfile swap swap" /etc/fstab; then
        echo "/swapfile swap swap defaults 0 0" >> /etc/fstab
        print_msg ok "Swap добавлен в автозагрузку"
    else
        print_msg warn "Swap уже присутствует в fstab"
    fi
}

verify_swap() {
    print_msg info "Проверяем статус swap"
    swapon --show
    free -h
}

# ================================
# Execution
# ================================

show_swap_status
if swapon --show | grep -q "/swapfile"; then
    print_msg info "Создание swap пропущено"
else
    if ask_swap_creation; then
        ask_swap_size
        create_swap_file
        verify_swap
        add_swap_to_fstab
    else
        print_msg info "Создание swap пропущено"
    fi
fi

# ================================
# Automatic security updates
# ================================

check_auto_updates() {

    if dpkg -l unattended-upgrades 2>/dev/null | grep -q "^ii" \
    && grep -q 'APT::Periodic::Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null \
    && systemctl is-enabled unattended-upgrades >/dev/null 2>&1; then

        if grep -m 1 '^Unattended-Upgrade::Automatic-Reboot "true";' /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null | grep -qv "^[[:space:]]*//"; then
            print_msg ok "Автоматические обновления уже активированы"
            return 0
        else
            print_msg warn "Автоматические обновления включены, но перезагрузка НЕ настроена"
            return 1
        fi
    fi
    return 1
}

ask_auto_updates() {
    local reply=""
    while true; do
        read -r -p "$(echo -e "${CLR_CYAN}Включить автоматические обновления безопасности? (y/n): ${CLR_RESET}")" reply </dev/tty
        reply=$(echo "$reply" | tr 'A-Z' 'a-z')
        case "$reply" in
            y) return 0 ;;
            n) return 1 ;;
        esac
        print_msg warn "Введите y или n"
    done
}

setup_auto_updates() {
    print_msg info "Настройка автоматических обновлений системы..."
    if ! dpkg -l unattended-upgrades 2>/dev/null | grep -q "^ii"; then
        print_msg info "Пакет unattended-upgrades отсутствует. Устанавливаем..."
        if ! apt-get update || ! apt-get install -y unattended-upgrades; then
            print_msg error "Ошибка установки unattended-upgrades"
            return 1
        fi
        print_msg ok "Пакет установлен."
    fi

    local main_conf="/etc/apt/apt.conf.d/50unattended-upgrades"
    local auto_conf="/etc/apt/apt.conf.d/20auto-upgrades"
    create_backup "$main_conf"
    create_backup "$auto_conf"
    
    # Включаем автоматическую перезагрузку после обновлений
    if grep -q "Automatic-Reboot" "$main_conf"; then
        sed -i 's|//\?\s*Unattended-Upgrade::Automatic-Reboot.*|Unattended-Upgrade::Automatic-Reboot "true";|' "$main_conf"
    else
        sed -i '/};/i\  Unattended-Upgrade::Automatic-Reboot "true";' "$main_conf"
    fi
    
    # Устанавливаем время автоматической перезагрузки
    if grep -q "Automatic-Reboot-Time" "$main_conf"; then
        sed -i 's|//\?\s*Unattended-Upgrade::Automatic-Reboot-Time.*|Unattended-Upgrade::Automatic-Reboot-Time "03:00";|' "$main_conf"
    else
        sed -i '/Unattended-Upgrade::Automatic-Reboot/a\  Unattended-Upgrade::Automatic-Reboot-Time "03:00";' "$main_conf"
    fi
    
    # Включаем ежедневную проверку обновлений
    sed -i 's/^APT::Periodic::Update-Package-Lists.*/APT::Periodic::Update-Package-Lists "1";/' "$auto_conf" 2>/dev/null
    sed -i 's/^APT::Periodic::Unattended-Upgrade.*/APT::Periodic::Unattended-Upgrade "1";/' "$auto_conf" 2>/dev/null
    grep -q "Update-Package-Lists" "$auto_conf" || echo 'APT::Periodic::Update-Package-Lists "1";' >> "$auto_conf"
    grep -q "Unattended-Upgrade" "$auto_conf" || echo 'APT::Periodic::Unattended-Upgrade "1";' >> "$auto_conf"
    systemctl enable unattended-upgrades >/dev/null 2>&1
    systemctl restart unattended-upgrades
    if systemctl is-active --quiet unattended-upgrades; then
        print_msg ok "Автоматические обновления успешно активированы."
    else
        print_msg warn "Служба unattended-upgrades не запущена."
    fi
}

install_auto_updates() {

    print_msg info "Установка и настройка автоматических обновлений..."
    wait_for_dpkg_lock
    apt-get update
    apt-get install -y unattended-upgrades
    print_msg ok "Пакет unattended-upgrades установлен"
    setup_auto_updates
}

# ================================
# Execution
# ================================

if check_auto_updates; then
    print_msg info "Настройка автоматических обновлений пропущена"
else
    if ask_auto_updates; then
        install_auto_updates
    else
        print_msg info "Автоматические обновления отключены пользователем"
    fi
fi

# ================================
# Fail2ban installation and setup
# ================================

check_fail2ban_status() {
    if ! dpkg -l fail2ban 2>/dev/null | grep -q "^ii"; then
        return 1
    fi
    if ! systemctl is-active --quiet fail2ban; then
        return 1
    fi
    if ! fail2ban-client status 2>/dev/null | grep -q "sshd"; then
        return 1
    fi
    print_msg ok "Fail2ban уже установлен и работает"
    fail2ban-client status
    return 0
}

ask_fail2ban() {
    local reply=""
    while true; do
        read -r -p "$(echo -e "${CLR_CYAN}Установить Fail2ban для защиты SSH? (y/n): ${CLR_RESET}")" reply </dev/tty
        reply=$(echo "$reply" | tr 'A-Z' 'a-z')
        case "$reply" in
            y) return 0 ;;
            n) return 1 ;;
        esac
        print_msg warn "Введите y или n"
    done
}

ask_email_notifications() {
    local reply=""
    while true; do
        read -r -p "$(echo -e "${CLR_CYAN}Включить email уведомления Fail2ban? (y/n): ${CLR_RESET}")" reply </dev/tty
        reply=$(echo "$reply" | tr 'A-Z' 'a-z')
        case "$reply" in
            y) return 0 ;;
            n) return 1 ;;
        esac
        print_msg warn "Введите y или n"
    done
}

ask_email_address() {
    local email=""
    while true; do
        read -r -p "$(echo -e "${CLR_CYAN}Введите email для уведомлений: ${CLR_RESET}")" email </dev/tty
        email=$(echo "$email" | xargs)
        if [[ -n "$email" ]]; then
            echo "$email"
            return
        fi
        print_msg warn "Email не может быть пустым"
    done
}

install_fail2ban() {
    if command -v fail2ban-client >/dev/null 2>&1; then
        print_msg info "Fail2ban уже установлен"
        return
    fi
    print_msg info "Устанавливаем Fail2ban..."
    wait_for_dpkg_lock
    apt-get update
    if ! apt-get install -y fail2ban; then
        print_msg error "Ошибка установки Fail2ban"
        exit 1
    fi
    print_msg ok "Fail2ban установлен"
}

install_mail_server() {
    if dpkg -s sendmail >/dev/null 2>&1; then
        return
    fi
    print_msg info "Устанавливаем sendmail и mailutils..."
    wait_for_dpkg_lock
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y sendmail mailutils
    systemctl enable sendmail >/dev/null 2>&1
    systemctl restart sendmail
}

get_ssh_port() {
    local port
    port=$(grep -m1 "^Port " /etc/ssh/sshd_config | awk '{print $2}')
    [[ -z "$port" ]] && port=22
    echo "$port"
}

generate_fail2ban_config() {
    local ssh_port="$1"
    local email="$2"
    local config="/etc/fail2ban/jail.local"
    mkdir -p /etc/fail2ban
    touch "$config"
    create_backup "$config"
    cat > "$config" <<EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1
EOF

    if [[ -n "$email" ]]; then
cat >> "$config" <<EOF
destemail = $email
sender = fail2ban@$(hostname)
mta = sendmail
action = %(action_mwl)s
EOF
    else
        echo "action = %(action_)s" >> "$config"
    fi
    
cat >> "$config" <<EOF

[sshd]
enabled = true
port = $ssh_port
logpath = /var/log/auth.log
maxretry = 3
bantime = 24h

[recidive]
enabled = true
logpath = /var/log/fail2ban.log
filter = recidive
action = iptables-allports[name=recidive]
bantime = -1
findtime = 24h
maxretry = 3
EOF
}

restart_fail2ban() {
    print_msg info "Перезапускаем Fail2ban..."
    systemctl restart fail2ban
    fail2ban-client reload >/dev/null 2>&1
    if systemctl is-active --quiet fail2ban; then
        print_msg ok "Fail2ban работает"
    else
        print_msg error "Fail2ban не запущен"
    fi
}

setup_fail2ban() {
    print_msg info "Настройка Fail2ban..."
    local ssh_port
    ssh_port=$(get_ssh_port)
    local email=""
    if ask_email_notifications; then
        install_mail_server
        email=$(ask_email_address)
    fi
    generate_fail2ban_config "$ssh_port" "$email"
    print_msg ok "Конфигурация Fail2ban создана"
    restart_fail2ban
}

# ================================
# Execution
# ================================

if check_fail2ban_status; then
    print_msg info "Установка Fail2ban пропущена"
else
    if ask_fail2ban; then
        install_fail2ban
        setup_fail2ban
    else
        print_msg info "Установка Fail2ban пропущена"
    fi
fi

# ================================
# Cloudflare WARP installation
# ================================

check_warp_status() {
    if dpkg -l cloudflare-warp 2>/dev/null | grep -q "^ii" && command -v warp-cli >/dev/null 2>&1; then
        print_msg ok "Cloudflare WARP уже установлен"
        warp-cli status 2>/dev/null || true
        return 0
    fi
    return 1
}

ask_warp_install() {
    local reply=""
    while true; do
        read -r -p "$(echo -e "${CLR_CYAN}Установить Cloudflare WARP? (y/n): ${CLR_RESET}")" reply </dev/tty
        reply=$(echo "$reply" | tr 'A-Z' 'a-z')
        case "$reply" in
            y) return 0 ;;
            n) return 1 ;;
        esac
        print_msg warn "Введите y или n"
    done
}

ask_warp_proxy_mode() {
    local reply=""
    while true; do
        read -r -p "$(echo -e "${CLR_CYAN}Использовать WARP как SOCKS-прокси для панели 3x-ui (или 'n' для VPN режима) (y/n): ${CLR_RESET}")" reply </dev/tty
        reply=$(echo "$reply" | tr 'A-Z' 'a-z')
        case "$reply" in
            y) return 0 ;;
            n) return 1 ;;
        esac
        print_msg warn "Введите y или n"
    done
}

install_warp_repo() {
    print_msg info "Добавляем ключ репозитория Cloudflare..."
    if ! curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg; then
        print_msg error "Ошибка добавления ключа Cloudflare"
        exit 1
    fi
    print_msg ok "Ключ Cloudflare добавлен"
    print_msg info "Добавляем репозиторий..."
    if ! echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list; then
        print_msg error "Ошибка добавления репозитория"
        exit 1
    fi
    print_msg ok "Репозиторий Cloudflare добавлен"
}

install_warp_package() {
    print_msg info "Устанавливаем WARP..."
    wait_for_dpkg_lock
    apt-get update
    if ! apt-get install -y cloudflare-warp; then
        print_msg error "Ошибка установки WARP"
        exit 1
    fi
    print_msg ok "WARP установлен"
}

register_warp() {
    print_msg info "Регистрируем WARP клиент..."
        if ! warp-cli status | grep -q "Registered"; then
        if ! echo y | script -q -c "warp-cli registration new" /dev/null; then
            print_msg error "Ошибка регистрации WARP"
            exit 1
        fi
        print_msg ok "WARP успешно зарегистрирован"
    else
        print_msg info "WARP уже зарегистрирован"
    fi
}

enable_warp_proxy() {
    print_msg info "Переключаем WARP в режим прокси..."
    if ! warp-cli mode proxy; then
        print_msg error "Не удалось включить proxy режим"
        exit 1
    fi
    warp-cli connect
    print_msg ok "WARP подключен в режиме прокси"
    echo
    print_msg warn "Настройки SOCKS для WARP в Outbounds в 3x-ui панели:"
    echo "IP:   127.0.0.1"
    echo "PORT: 40000"
    echo
}

enable_warp_vpn() {
    print_msg info "Подключаем WARP в VPN режиме..."
    if ! warp-cli connect; then
        print_msg error "Ошибка подключения WARP"
        exit 1
    fi
    print_msg ok "WARP подключен"
}

show_warp_status() {
    print_msg info "Статус WARP (проверяем, установлен ли warp-cli Если: command not found значит не установлен):"
    warp-cli status
}

setup_warp() {
    if check_warp_status; then
        print_msg info "Установка Cloudflare WARP пропущена"
        return
    fi

    if ! ask_warp_install; then
        print_msg info "Установка WARP пропущена пользователем"
        return
    fi

    install_warp_repo
    install_warp_package
    register_warp
    if ask_warp_proxy_mode; then
        enable_warp_proxy
    else
        enable_warp_vpn
    fi
    show_warp_status
}

# ================================
# Execution
# ================================

setup_warp

# ================================
# 3x-ui installation
# ================================



ask_3xui_install() {
    local reply=""
    while true; do
        read -r -p "$(echo -e "${CLR_CYAN}Установить панель 3x-ui? (y/n): ${CLR_RESET}")" reply </dev/tty
        reply=$(echo "$reply" | tr 'A-Z' 'a-z')
        case "$reply" in
            y) return 0 ;;
            n) return 1 ;;
        esac
        print_msg warn "Введите y или n"
    done
}

disable_firewall_temp() {
    if ufw status 2>/dev/null | grep -q "Status: active"; then
        print_msg info "Временно отключаем UFW..."
        ufw disable >/dev/null 2>&1
        declare -g FIREWALL_WAS_ACTIVE=true
    else
        declare -g FIREWALL_WAS_ACTIVE=false
    fi
}

restore_firewall() {
    if [[ "$FIREWALL_WAS_ACTIVE" == true ]]; then
        print_msg info "Включаем UFW обратно..."
        ufw --force enable >/dev/null 2>&1
        print_msg warn "Не забудьте открыть порт панели 3x-ui"
        echo -e "${CLR_WHITE}Команда: ufw allow <PORT>/tcp${CLR_RESET}"
    fi
}

install_3xui() {
    print_msg info "Устанавливаем 3x-ui..."
    if ! bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh); then
        print_msg error "Ошибка установки 3x-ui"
        exit 1
    fi
    print_msg ok "3x-ui успешно установлен"
}

fix_acme_cron() {
    print_msg info "Исправляем cron задачу acme.sh..."
    local OPEN="ufw allow 80/tcp"
    local CLOSE="ufw deny 80/tcp"
    (crontab -l 2>/dev/null || true) | while IFS= read -r line; do
        if ! echo "$line" | grep -q 'acme.sh --cron'; then
            echo "$line"
            continue
        fi
        if echo "$line" | grep -q 'ufw allow 80/tcp.*acme.sh --cron.*ufw deny 80/tcp'; then
            echo "$line"
            continue
        fi
        schedule=$(echo "$line" | awk '{print $1,$2,$3,$4,$5}')
        command=$(echo "$line" | cut -d' ' -f6-)
        echo "$schedule $OPEN && $command ; $CLOSE"
    done | crontab -
    print_msg ok "Cron acme.sh исправлен"
}

setup_3xui() {
    if command -v x-ui >/dev/null 2>&1; then
        print_msg ok "3x-ui уже установлен"
        return
    fi
    if ! ask_3xui_install; then
        print_msg info "Установка 3x-ui пропущена"
        return
    fi
    disable_firewall_temp
    install_3xui
    fix_acme_cron
    restore_firewall

}

# ================================
# Execution
# ================================

setup_3xui

# ================================
# Final summary
# ================================
print_msg info "Очистка системы..."

apt-get autoremove -y >/dev/null 2>&1
apt-get autoclean >/dev/null 2>&1

show_summary() {
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    local counter=1
    if [[ -n "$TARGET_SSH_PORT" ]]; then
        print_msg ok "$counter. SSH настроен. Порт: $TARGET_SSH_PORT"
    else
        print_msg warn "$counter. SSH настройка НЕ завершена"
    fi
    ((counter++))

    if [[ -s "$ROOT_AUTH_KEYS" ]] && \
       grep -Eq '^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) ' "$ROOT_AUTH_KEYS" 2>/dev/null
    then
        print_msg ok "$counter. SSH ключ добавлен"
    else
        print_msg warn "$counter. SSH ключ НЕ добавлен"
    fi
    ((counter++))

    if ufw status 2>/dev/null | grep -q "Status: active"; then
        print_msg ok "$counter. Firewall (UFW) активирован"
    else
        print_msg warn "$counter. Firewall (UFW) НЕ активирован"
    fi
    ((counter++))

    if [[ -f "$UFW_BEFORE_RULES" ]] && grep -q "echo-request.*DROP" "$UFW_BEFORE_RULES" 2>/dev/null; then
        print_msg ok "$counter. ICMP ping отключён"
    else
        print_msg warn "$counter. ICMP ping НЕ отключён"
    fi
    ((counter++))

    if systemctl is-active --quiet unattended-upgrades 2>/dev/null; then
        if grep -m 1 '^Unattended-Upgrade::Automatic-Reboot "true";' /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null | grep -qv "^[[:space:]]*//"; then
            print_msg ok "$counter. Автоматические обновления включены и настроены"
        else
            print_msg warn "$counter. Автоматические обновления включены, но перезагрузка НЕ настроена"
        fi
    else
        print_msg warn "$counter. Автоматические обновления отключены"
    fi
    ((counter++))

    if command -v fail2ban-client >/dev/null 2>&1; then
        print_msg ok "$counter. Fail2ban установлен"
    else
        print_msg warn "$counter. Fail2ban НЕ установлен"
    fi
    ((counter++))

    if command -v warp-cli >/dev/null 2>&1; then
        print_msg ok "$counter. Cloudflare WARP установлен"
    else
        print_msg warn "$counter. WARP НЕ установлен"
    fi
    ((counter++))

    if command -v x-ui >/dev/null 2>&1; then
        print_msg ok "$counter. Панель 3x-ui установлена"
    else
        print_msg warn "$counter. Панель 3x-ui НЕ установлена"
    fi
    ((counter++))

    if swapon --show | grep -q "/swapfile"; then
    SWAP_SIZE=$(swapon --show --noheadings | grep "/swapfile" | awk '{print $3}')
    print_msg ok "$counter. Swap создан (${SWAP_SIZE})"
    else
    print_msg warn "$counter. Swap НЕ создан"
    fi
    
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    echo -e "${CLR_WHITE}                    НАСТРОЙКА СЕРВЕРА ЗАВЕРШЕНА${CLR_RESET}"
    echo
    echo -e "${CLR_YELLOW}Подключайтесь к серверу по новому SSH-порту $TARGET_SSH_PORT после перезагрузки${CLR_RESET}"
    echo
    echo -e "${CLR_YELLOW}Для применения настроек требуется перезагрузить сервер${CLR_RESET}"
    echo
    echo -e "${CLR_WHITE}Команда: reboot${CLR_RESET}"

    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

}

# ================================
# Execution
# ================================

show_summary